#!/usr/bin/env bash

# Script Name: osu-track-az-requirement.sh
# Description: Reports OpenStack VMs with their host placement, effective AZ,
#              and whether an Availability Zone was explicitly requested at
#              creation time. Queries nova_api.request_specs via juju for
#              authoritative AZ request data.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-04-23
# Version: 0.4.1
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - jq
#   - juju CLI with SSH access to mysql-innodb-cluster unit
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Permissions:
#   - Default (own project): regular user + juju SSH access
#   - --all-projects or -p <other>: OpenStack admin + juju SSH access

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.4.1"

# Operational defaults
OUTPUT_FORMAT="table"
PROJECT_FILTER=""
DOMAIN_FILTER=""
SERVER_FILTER=""
ALL_PROJECTS=0
SHOW_PROGRESS=1
MYSQL_UNIT=""
MISMATCH_ONLY=0

# Caches
declare -A AZ_REQUESTED_CACHE=()
declare -A PROJECT_NAMES=()

# --- Colors (disabled when stderr is not a terminal) --------------------------
if [[ -t 2 ]]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

# --- Helpers ------------------------------------------------------------------
msg()  { echo -e "${C_BOLD}${C_CYAN}::${C_RESET} $*" >&2; }
ok()   { echo -e "   ${C_GREEN}[+]${C_RESET} $*" >&2; }
warn() { echo -e "   ${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()  { echo -e "   ${C_RED}[-]${C_RESET} $*" >&2; }

progress() {
    (( SHOW_PROGRESS )) || return 0
    [[ -t 2 ]] || return 0  # Only show progress if stderr is a TTY
    local current="$1" total="$2" label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))
    local empty=$(( 20 - filled ))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf "\r   [%s] %3d%% (%d/%d) %s" "$bar" "$pct" "$current" "$total" "$label" >&2
}

progress_done() {
    (( SHOW_PROGRESS )) || return 0
    [[ -t 2 ]] || return 0  # Only if stderr is a TTY
    printf "\r%80s\r" "" >&2
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Version: $SCRIPT_VERSION

Description:
  Reports OpenStack VMs with host placement, effective Availability Zone, and
  whether an AZ was explicitly requested at creation time.

  This script queries the nova_api.request_specs table via juju to obtain
  authoritative AZ request data. If an AZ is present in the request_spec,
  it was explicitly requested at VM creation time.

  AZ Request Detection (authoritative from database):
  - "<az-name>"   AZ was explicitly requested at creation (shows requested AZ)
  - "—"           No AZ was requested (scheduler chose placement)
  - "n/a"         Unable to query database (VM may be missing from request_specs)

Scope:
  (default)               Report VMs in the current project
  -s, --server SERVER     Query a specific VM (by name or ID)
  -a, --all-projects      Report all VMs across all accessible projects
  -d, --domain DOMAIN     Report all VMs in projects of the specified domain
  -p, --project PROJECT   Limit to a single project (by name or ID)
                          Can be combined with -d for cross-domain project lookup

Options:
  -f, --format FMT        Output format: table (default), csv, json
  -m, --mismatch-only     Show only VMs where current AZ differs from requested AZ
      --mysql-unit UNIT   Juju mysql unit to query (default: auto-detect leader)
  -q, --quiet             Suppress progress indicators
  -h, --help              Show this help message
  -v, --version           Show version

Output columns:
  ID          Instance UUID
  Name        Instance name
  Project     Project name (when --all-projects)
  Status      Nova instance state (ACTIVE, SHUTOFF, etc.)
  Host        Hypervisor hostname
  Current AZ  Availability Zone where VM currently resides
  Requested   AZ explicitly requested at boot (from request_specs), or "—" if none
  Match       Whether current AZ matches requested (✓ = match, ✗ = mismatch, — = n/a)

Examples:
  # Report VMs in current project
  $0

  # Query a specific VM
  $0 -s my-vm-name
  $0 --server 12345678-1234-1234-1234-123456789abc

  # Report all VMs across all projects
  $0 --all-projects

  # Report VMs in a specific project
  $0 -p my-project

  # Report all VMs in a specific domain
  $0 -d my-domain

  # Report VMs in a specific project within a domain
  $0 -d my-domain -p my-project

  # CSV output for spreadsheet analysis
  $0 -f csv --all-projects > az-report.csv

  # JSON output for scripting
  $0 -f json -p my-project

  # Use a different mysql unit
  $0 --mysql-unit mysql-innodb-cluster/1 --all-projects

  # Show only VMs that have been migrated (current AZ != requested AZ)
  $0 --mismatch-only --all-projects

  # Suppress progress indicators
  $0 --all-projects -q

  # Display version
  $0 --version
EOF
}

# --- Dependency checks --------------------------------------------------------

check_deps() {
    local missing=()
    for cmd in openstack jq juju; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_auth() {
    if ! openstack token issue -f value -c id &>/dev/null; then
        err "OpenStack authentication failed."
        err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
        exit 1
    fi
}

detect_mysql_leader() {
    local leader
    leader=$(juju status mysql-innodb-cluster --format json 2>/dev/null | \
        jq -r '.applications["mysql-innodb-cluster"].units | to_entries[] | select(.value.leader == true) | .key') || {
        err "Failed to query juju for mysql-innodb-cluster status."
        exit 1
    }

    if [[ -z "$leader" ]]; then
        err "Could not detect mysql-innodb-cluster leader unit."
        err "Ensure mysql-innodb-cluster is deployed and accessible."
        exit 1
    fi

    echo "$leader"
}

check_juju() {
    # Auto-detect leader if not specified
    if [[ -z "$MYSQL_UNIT" ]]; then
        MYSQL_UNIT=$(detect_mysql_leader)
        ok "Detected MySQL leader: $MYSQL_UNIT"
    fi

    if ! juju status "$MYSQL_UNIT" --format=short &>/dev/null; then
        err "Cannot reach juju unit '$MYSQL_UNIT'."
        err "Ensure juju is configured and the mysql unit is accessible."
        exit 1
    fi
}

# --- Database queries ---------------------------------------------------------

fetch_all_az_requests() {
    msg "Querying nova_api.request_specs for AZ requirements..."

    local query="SELECT instance_uuid, JSON_UNQUOTE(JSON_EXTRACT(spec, '\$.\\\"nova_object.data\\\".availability_zone')) as requested_az FROM nova_api.request_specs;"

    local result
    result=$(juju ssh "$MYSQL_UNIT" "sudo mysql -N -e \"$query\"" 2>/dev/null) || {
        warn "Failed to query database; AZ request data will be unavailable"
        return 1
    }

    while IFS=$'\t' read -r uuid az; do
        if [[ -n "$uuid" ]]; then
            if [[ "$az" == "null" ]] || [[ -z "$az" ]]; then
                AZ_REQUESTED_CACHE["$uuid"]="—"
            else
                AZ_REQUESTED_CACHE["$uuid"]="$az"
            fi
        fi
    done <<< "$result"

    ok "Loaded ${#AZ_REQUESTED_CACHE[@]} request_spec records"
    return 0
}

get_az_requested() {
    local instance_uuid="$1"
    echo "${AZ_REQUESTED_CACHE[$instance_uuid]:-n/a}"
}

# Determine match status between current AZ and requested AZ
# Returns: "✓" (match), "✗" (mismatch), "—" (no AZ requested or n/a)
get_match_status() {
    local current_az="$1"
    local requested_az="$2"

    # If no AZ was requested or n/a, no comparison possible
    if [[ "$requested_az" == "—" ]] || [[ "$requested_az" == "n/a" ]] || [[ -z "$requested_az" ]]; then
        echo "—"
        return
    fi

    # Compare current with requested
    if [[ "$current_az" == "$requested_az" ]]; then
        echo "✓"
    else
        echo "✗"
    fi
}

# Check if this VM should be included based on mismatch filter
should_include_vm() {
    local match_status="$1"

    if (( MISMATCH_ONLY )); then
        [[ "$match_status" == "✗" ]]
    else
        return 0
    fi
}

# --- Data collection ----------------------------------------------------------

get_single_server() {
    local server_id="$1"
    openstack server show "$server_id" \
        -f json \
        -c id \
        -c name \
        -c status \
        -c "OS-EXT-SRV-ATTR:host" \
        -c "OS-EXT-AZ:availability_zone" \
        -c project_id \
        2>/dev/null | jq '[{
            ID: .id,
            Name: .name,
            Status: .status,
            Host: ."OS-EXT-SRV-ATTR:host",
            "Availability Zone": ."OS-EXT-AZ:availability_zone",
            "Project ID": .project_id
        }]'
}

get_servers_cli() {
    # If a specific server is requested, query just that one
    if [[ -n "$SERVER_FILTER" ]]; then
        get_single_server "$SERVER_FILTER"
        return
    fi

    local scope_args=()

    if (( ALL_PROJECTS )); then
        scope_args+=("--all-projects")
    fi

    if [[ -n "$PROJECT_FILTER" ]]; then
        scope_args+=("--project" "$PROJECT_FILTER")
    fi

    # If domain filter is set (without --all-projects), get servers from all projects in that domain
    if [[ -n "$DOMAIN_FILTER" ]] && (( ! ALL_PROJECTS )) && [[ -z "$PROJECT_FILTER" ]]; then
        get_servers_by_domain "$DOMAIN_FILTER"
        return
    fi

    openstack server list "${scope_args[@]}" --long \
        -f json \
        -c ID \
        -c Name \
        -c Status \
        -c Host \
        -c "Availability Zone" \
        -c "Project ID" \
        2>/dev/null
}

get_servers_by_domain() {
    local domain="$1"
    local all_servers="[]"

    # Get all projects in the domain
    local projects
    projects=$(openstack project list --domain "$domain" -f value -c ID 2>/dev/null) || {
        err "Failed to list projects in domain '$domain'"
        echo "[]"
        return
    }

    local project_count
    project_count=$(echo "$projects" | wc -l)
    msg "Querying $project_count project(s) in domain '$domain'..."

    local i=0
    while IFS= read -r project_id; do
        [[ -z "$project_id" ]] && continue
        ((i++)) || true
        progress "$i" "$project_count" "Querying projects..."

        local servers
        servers=$(openstack server list --project "$project_id" --long \
            -f json \
            -c ID \
            -c Name \
            -c Status \
            -c Host \
            -c "Availability Zone" \
            -c "Project ID" \
            2>/dev/null) || continue

        all_servers=$(echo "$all_servers" | jq --argjson new "$servers" '. + $new')
    done <<< "$projects"

    progress_done
    echo "$all_servers"
}

get_project_name() {
    local project_id="$1"
    openstack project show "$project_id" -f value -c name 2>/dev/null || echo "$project_id"
}

cache_project_name() {
    local project_id="$1"
    if [[ -z "${PROJECT_NAMES[$project_id]:-}" ]]; then
        PROJECT_NAMES[$project_id]=$(get_project_name "$project_id")
    fi
    echo "${PROJECT_NAMES[$project_id]}"
}

# --- Output formatting --------------------------------------------------------

output_table() {
    local servers_json="$1"
    local count
    count=$(echo "$servers_json" | jq 'length')

    if (( count == 0 )); then
        msg "No servers found."
        return
    fi

    msg "Found $count server(s)"
    echo ""

    if (( ALL_PROJECTS )); then
        printf "%-36s  %-25s  %-15s  %-8s  %-30s  %-10s  %-10s  %s\n" \
            "ID" "Name" "Project" "Status" "Host" "Current AZ" "Requested" "Match"
        printf "%s\n" "$(printf '=%.0s' {1..155})"
    else
        printf "%-36s  %-30s  %-8s  %-35s  %-10s  %-10s  %s\n" \
            "ID" "Name" "Status" "Host" "Current AZ" "Requested" "Match"
        printf "%s\n" "$(printf '=%.0s' {1..145})"
    fi

    local i=0
    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Processing servers..."

        local id name status host az project_id az_requested
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name')
        status=$(echo "$server" | jq -r '.Status // .status')
        host=$(echo "$server" | jq -r '.Host // ."OS-EXT-SRV-ATTR:host" // "—"')
        az=$(echo "$server" | jq -r '."Availability Zone" // ."OS-EXT-AZ:availability_zone" // "—"')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // "—"')

        [[ "$host" == "null" ]] && host="—"
        [[ "$az" == "null" ]] && az="—"

        az_requested=$(get_az_requested "$id")
        local match_status
        match_status=$(get_match_status "$az" "$az_requested")

        # Skip if mismatch-only filter is active and this is not a mismatch
        should_include_vm "$match_status" || continue

        if (( ALL_PROJECTS )); then
            local project_name
            project_name=$(cache_project_name "$project_id")
            printf "%-36s  %-25s  %-15s  %-8s  %-30s  %-10s  %-10s  %s\n" \
                "$id" "${name:0:25}" "${project_name:0:15}" "$status" "${host:0:30}" "$az" "$az_requested" "$match_status"
        else
            printf "%-36s  %-30s  %-8s  %-35s  %-10s  %-10s  %s\n" \
                "$id" "${name:0:30}" "$status" "${host:0:35}" "$az" "$az_requested" "$match_status"
        fi
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done

    echo ""
    echo -e "${C_DIM}Legend: Requested = AZ explicitly set at boot (from nova_api.request_specs)${C_RESET}"
    echo -e "${C_DIM}        \"—\" = no AZ requested (scheduler chose placement)${C_RESET}"
    echo -e "${C_DIM}        \"n/a\" = VM not found in request_specs table${C_RESET}"
    echo -e "${C_DIM}        Match: ✓ = current AZ matches requested, ✗ = mismatch (VM was moved), — = n/a${C_RESET}"
}

output_csv() {
    local servers_json="$1"
    local count
    count=$(echo "$servers_json" | jq 'length')

    if (( ALL_PROJECTS )); then
        echo "ID,Name,Project,Status,Host,Current_AZ,Requested_AZ,Match"
    else
        echo "ID,Name,Status,Host,Current_AZ,Requested_AZ,Match"
    fi

    local i=0
    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Processing servers..."

        local id name status host az project_id az_requested
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name' | sed 's/,/;/g')
        status=$(echo "$server" | jq -r '.Status // .status')
        host=$(echo "$server" | jq -r '.Host // ."OS-EXT-SRV-ATTR:host" // "—"')
        az=$(echo "$server" | jq -r '."Availability Zone" // ."OS-EXT-AZ:availability_zone" // "—"')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // "—"')

        [[ "$host" == "null" ]] && host="—"
        [[ "$az" == "null" ]] && az="—"

        az_requested=$(get_az_requested "$id")
        local match_status
        match_status=$(get_match_status "$az" "$az_requested")

        # Skip if mismatch-only filter is active and this is not a mismatch
        should_include_vm "$match_status" || continue

        if (( ALL_PROJECTS )); then
            local project_name
            project_name=$(cache_project_name "$project_id")
            echo "$id,$name,$project_name,$status,$host,$az,$az_requested,$match_status"
        else
            echo "$id,$name,$status,$host,$az,$az_requested,$match_status"
        fi
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done
}

output_json() {
    local servers_json="$1"
    local count
    count=$(echo "$servers_json" | jq 'length')

    local result="[]"
    local i=0

    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Processing servers..."

        local id name status host az project_id az_requested
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name')
        status=$(echo "$server" | jq -r '.Status // .status')
        host=$(echo "$server" | jq -r '.Host // ."OS-EXT-SRV-ATTR:host" // null')
        az=$(echo "$server" | jq -r '."Availability Zone" // ."OS-EXT-AZ:availability_zone" // null')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // null')

        az_requested=$(get_az_requested "$id")
        local match_status
        match_status=$(get_match_status "$az" "$az_requested")

        # Skip if mismatch-only filter is active and this is not a mismatch
        should_include_vm "$match_status" || continue

        local az_req_json="$az_requested"
        [[ "$az_req_json" == "—" ]] && az_req_json=""
        [[ "$az_req_json" == "n/a" ]] && az_req_json=""

        local is_match="null"
        [[ "$match_status" == "✓" ]] && is_match="true"
        [[ "$match_status" == "✗" ]] && is_match="false"

        local entry
        if (( ALL_PROJECTS )); then
            local project_name
            project_name=$(cache_project_name "$project_id")
            entry=$(jq -n \
                --arg id "$id" \
                --arg name "$name" \
                --arg project "$project_name" \
                --arg status "$status" \
                --arg host "$host" \
                --arg az "$az" \
                --arg az_req "$az_req_json" \
                --argjson match "$is_match" \
                '{id: $id, name: $name, project: $project, status: $status, host: $host, current_az: $az, requested_az: ($az_req | if . == "" then null else . end), match: $match}')
        else
            entry=$(jq -n \
                --arg id "$id" \
                --arg name "$name" \
                --arg status "$status" \
                --arg host "$host" \
                --arg az "$az" \
                --arg az_req "$az_req_json" \
                --argjson match "$is_match" \
                '{id: $id, name: $name, status: $status, host: $host, current_az: $az, requested_az: ($az_req | if . == "" then null else . end), match: $match}')
        fi

        result=$(echo "$result" | jq --argjson entry "$entry" '. += [$entry]')
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done
    echo "$result" | jq '.'
}

# --- Argument parsing ---------------------------------------------------------

OPTIONS=$(getopt -o hvp:f:aqmd:s: \
    --long help,version,project:,domain:,format:,all-projects,mismatch-only,mysql-unit:,quiet,server: \
    -n "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    echo "Failed to parse options. Use --help for usage." >&2
    exit 1
fi

eval set -- "$OPTIONS"

while true; do
    case "$1" in
        -v|--version)
            echo "$0 $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--project)
            PROJECT_FILTER="$2"
            shift 2
            ;;
        -s|--server)
            SERVER_FILTER="$2"
            shift 2
            ;;
        -d|--domain)
            DOMAIN_FILTER="$2"
            shift 2
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -a|--all-projects)
            ALL_PROJECTS=1
            shift
            ;;
        -m|--mismatch-only)
            MISMATCH_ONLY=1
            shift
            ;;
        --mysql-unit)
            MYSQL_UNIT="$2"
            shift 2
            ;;
        -q|--quiet)
            SHOW_PROGRESS=0
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unexpected option: $1" >&2
            exit 1
            ;;
    esac
done

# Check for unexpected positional arguments
if [[ -n "${1:-}" ]]; then
    err "Unexpected argument: $1"
    err "Use --domain to specify a domain filter."
    exit 1
fi

# --- Validation ---------------------------------------------------------------

case "$OUTPUT_FORMAT" in
    table|csv|json) ;;
    *) err "Invalid format '${OUTPUT_FORMAT}'. Use: table, csv, json"; exit 1 ;;
esac

# Disable progress for non-table output
if [[ "$OUTPUT_FORMAT" != "table" ]]; then
    SHOW_PROGRESS=0
fi

# --- Main execution -----------------------------------------------------------

check_deps
check_auth
check_juju

# Fetch all AZ requests from database first (batch query)
fetch_all_az_requests

msg "Collecting server data from OpenStack..."
servers_json=$(get_servers_cli)

case "$OUTPUT_FORMAT" in
    table)
        output_table "$servers_json"
        ;;
    csv)
        output_csv "$servers_json"
        ;;
    json)
        output_json "$servers_json"
        ;;
esac
