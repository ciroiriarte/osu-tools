#!/usr/bin/env bash

# Script Name: osu-track-qemu-agents.sh
# Description: Reports OpenStack VMs with QEMU guest agent configuration and
#              communication status. Shows whether the agent bus is configured
#              (hw_qemu_guest_agent) and if the agent is actually responding.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-04-23
# Version: 0.2.0
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - curl (for Nova diagnostics API)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Permissions:
#   - Default (own project): regular user
#   - --all-projects or -p <other>: OpenStack admin
#   - --domain: OpenStack admin or domain admin

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.2.0"

# Operational defaults
OUTPUT_FORMAT="table"
PROJECT_FILTER=""
DOMAIN_FILTER=""
ALL_PROJECTS=0
SHOW_PROGRESS=1
ISSUES_ONLY=0
FILTER_RESPONDING=""
INSECURE=0

# API cache
AUTH_TOKEN=""
NOVA_ENDPOINT=""

# Caches
declare -A IMAGE_AGENT_CACHE=()
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
  Reports OpenStack VMs with QEMU guest agent configuration and communication
  status. For each VM, shows:

  1. Agent Bus: Whether hw_qemu_guest_agent is enabled in the source image
  2. Agent Responding: Whether the agent is actually communicating with the host

  Detection Methods (CLI/API only, no database access):
  - Agent Bus: Checks image properties (hw_qemu_guest_agent) via CLI
  - Agent Responding: Checks Nova diagnostics API for detailed memory stats
    (presence of memory-unused, memory-available indicates active balloon/agent)

  Status Indicators:
  - "✓"     Agent bus configured / Agent responding
  - "✗"     Agent bus not configured / Agent not responding
  - "?"     Couldn't determine (VM not running, image deleted, etc.)

Scope:
  (default)               Report VMs in the current project
  -a, --all-projects      Report all VMs across all accessible projects
  -d, --domain DOMAIN     Report all VMs in projects of the specified domain
  -p, --project PROJECT   Limit to a single project (by name or ID)

Options:
  -f, --format FMT        Output format: table (default), csv, json
  -i, --issues-only       Show only VMs with agent issues (bus not configured
                          or agent not responding)
      --filter-responding VALUE
                          Filter by agent responding status: yes, no, undetermined
      --insecure          Allow insecure SSL connections (skip certificate verification)
  -q, --quiet             Suppress progress indicators
  -h, --help              Show this help message
  -v, --version           Show version

Output columns:
  ID            Instance UUID
  Name          Instance name
  Project       Project name (when --all-projects or --domain)
  Status        Nova instance state (ACTIVE, SHUTOFF, etc.)
  Agent Bus     Whether hw_qemu_guest_agent is set in source image (✓/✗/—)
  Responding    Whether agent is actually communicating (✓/✗/—)
  Image/Volume  Source image name or "volume:<id>" for boot-from-volume

Examples:
  # Report VMs in current project
  $0

  # Report all VMs across all projects
  $0 --all-projects

  # Report all VMs in a specific domain
  $0 -d my-domain

  # Show only VMs with agent issues
  $0 --issues-only --all-projects

  # CSV output for spreadsheet analysis
  $0 -f csv --all-projects > agents.csv

  # JSON output for scripting
  $0 -f json --all-projects

  # Display version
  $0 --version
EOF
}

# --- Dependency checks --------------------------------------------------------

check_deps() {
    local missing=()
    for cmd in openstack curl jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_auth() {
    local insecure_flag=""
    (( INSECURE )) && insecure_flag="--insecure"
    if ! openstack $insecure_flag token issue -f value -c id &>/dev/null; then
        err "OpenStack authentication failed."
        err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
        exit 1
    fi
}

# Build openstack command with optional --insecure flag
osc() {
    if (( INSECURE )); then
        openstack --insecure "$@"
    else
        openstack "$@"
    fi
}

# --- API helpers --------------------------------------------------------------

ensure_token() {
    if [[ -z "$AUTH_TOKEN" ]]; then
        AUTH_TOKEN=$(osc token issue -f value -c id 2>/dev/null) || {
            err "Failed to obtain auth token."
            exit 1
        }
    fi
}

ensure_nova_endpoint() {
    if [[ -z "$NOVA_ENDPOINT" ]]; then
        local catalog_json
        catalog_json=$(osc catalog show nova -f json 2>/dev/null) || {
            err "Cannot discover Nova endpoint from service catalog."
            exit 1
        }
        NOVA_ENDPOINT=$(echo "$catalog_json" | jq -r '
            .endpoints[] | select(.interface == "public") | .url' | head -1)
        if [[ -z "$NOVA_ENDPOINT" ]]; then
            NOVA_ENDPOINT=$(echo "$catalog_json" | jq -r '
                .endpoints[] | select(.interface == "internal") | .url' | head -1)
        fi
        if [[ -z "$NOVA_ENDPOINT" ]]; then
            err "No Nova endpoint found in catalog."
            exit 1
        fi
    fi
}

# --- Agent detection ----------------------------------------------------------

# Check if image has hw_qemu_guest_agent set
# Returns: "true", "false", or "" (unknown)
get_image_agent_config() {
    local image_id="$1"

    # Check cache first
    if [[ -n "${IMAGE_AGENT_CACHE[$image_id]:-}" ]]; then
        echo "${IMAGE_AGENT_CACHE[$image_id]}"
        return
    fi

    local agent_prop
    agent_prop=$(osc image show "$image_id" -f json 2>/dev/null | \
        jq -r '.properties.hw_qemu_guest_agent // ""') || agent_prop=""

    # Normalize to true/false
    case "${agent_prop,,}" in
        true|yes|1) IMAGE_AGENT_CACHE["$image_id"]="true" ;;
        false|no|0) IMAGE_AGENT_CACHE["$image_id"]="false" ;;
        *) IMAGE_AGENT_CACHE["$image_id"]="" ;;
    esac

    echo "${IMAGE_AGENT_CACHE[$image_id]}"
}

# Check volume image metadata for hw_qemu_guest_agent
get_volume_agent_config() {
    local volume_id="$1"

    local vol_json
    vol_json=$(osc volume show "$volume_id" -f json 2>/dev/null) || {
        echo ""
        return
    }

    # Check volume_image_metadata for the property
    local agent_prop
    agent_prop=$(echo "$vol_json" | jq -r '.volume_image_metadata.hw_qemu_guest_agent // ""')

    case "${agent_prop,,}" in
        true|yes|1) echo "true" ;;
        false|no|0) echo "false" ;;
        *) echo "" ;;
    esac
}

# Get image name from image ID or volume
get_image_source() {
    local image_id="$1"
    local image_name="$2"
    local volume_id="$3"

    if [[ -n "$image_id" ]] && [[ "$image_id" != "null" ]] && [[ "$image_id" != "" ]]; then
        # Use provided image name or lookup
        if [[ -n "$image_name" ]] && [[ "$image_name" != "null" ]]; then
            echo "${image_name:0:40}"
        else
            local img_name
            img_name=$(osc image show "$image_id" -f value -c name 2>/dev/null) || img_name="$image_id"
            echo "${img_name:0:40}"
        fi
    elif [[ -n "$volume_id" ]] && [[ "$volume_id" != "null" ]]; then
        # Get image name from volume metadata
        local vol_img_name
        vol_img_name=$(osc volume show "$volume_id" -f json 2>/dev/null | \
            jq -r '.volume_image_metadata.image_name // ""')
        if [[ -n "$vol_img_name" ]]; then
            echo "vol:${vol_img_name:0:35}"
        else
            echo "vol:${volume_id:0:35}"
        fi
    else
        echo "—"
    fi
}

# Check if agent is responding via Nova diagnostics API
# Returns: "true" (responding), "false" (not responding), "" (unknown/VM not active)
check_agent_responding() {
    local server_id="$1"
    local status="$2"

    # Agent can only respond if VM is active
    if [[ "$status" != "ACTIVE" ]]; then
        echo ""
        return
    fi

    ensure_token
    ensure_nova_endpoint

    local diag_json
    diag_json=$(curl -sk \
        -H "X-Auth-Token: $AUTH_TOKEN" \
        "${NOVA_ENDPOINT}/servers/${server_id}/diagnostics" 2>/dev/null) || {
        echo ""
        return
    }

    # Check if we got valid JSON
    if ! echo "$diag_json" | jq -e '.' &>/dev/null; then
        echo ""
        return
    fi

    # Check for detailed memory stats (indicates balloon/agent is working)
    # If memory-unused or memory-available exists, agent is communicating
    local has_detailed_memory
    has_detailed_memory=$(echo "$diag_json" | jq -r '
        if (."memory-unused" != null) or (."memory-available" != null) or (."memory-usable" != null)
        then "true"
        else "false"
        end
    ')

    echo "$has_detailed_memory"
}

# --- Data collection ----------------------------------------------------------

get_servers_cli() {
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

    osc server list "${scope_args[@]}" --long \
        -f json \
        -c ID \
        -c Name \
        -c Status \
        -c "Image ID" \
        -c "Image Name" \
        -c "Project ID" \
        2>/dev/null
}

get_servers_by_domain() {
    local domain="$1"
    local all_servers="[]"

    local projects
    projects=$(osc project list --domain "$domain" -f value -c ID 2>/dev/null) || {
        err "Failed to list projects in domain '$domain'"
        echo "[]"
        return
    }

    local project_count
    project_count=$(echo "$projects" | grep -c . || echo 0)
    msg "Querying $project_count project(s) in domain '$domain'..."

    local i=0
    while IFS= read -r project_id; do
        [[ -z "$project_id" ]] && continue
        ((i++)) || true
        progress "$i" "$project_count" "Querying projects..."

        local servers
        servers=$(osc server list --project "$project_id" --long \
            -f json \
            -c ID \
            -c Name \
            -c Status \
            -c "Image ID" \
            -c "Image Name" \
            -c "Project ID" \
            2>/dev/null) || continue

        all_servers=$(echo "$all_servers" | jq --argjson new "$servers" '. + $new')
    done <<< "$projects"

    progress_done
    echo "$all_servers"
}

get_server_volumes() {
    local server_id="$1"
    osc server show "$server_id" -f json 2>/dev/null | \
        jq -r '.volumes_attached[0].id // ""'
}

get_project_name() {
    local project_id="$1"
    osc project show "$project_id" -f value -c name 2>/dev/null || echo "$project_id"
}

cache_project_name() {
    local project_id="$1"
    if [[ -z "${PROJECT_NAMES[$project_id]:-}" ]]; then
        PROJECT_NAMES[$project_id]=$(get_project_name "$project_id")
    fi
    echo "${PROJECT_NAMES[$project_id]}"
}

# --- Status formatting --------------------------------------------------------

format_bool_status() {
    local value="$1"
    case "$value" in
        true) echo "✓" ;;
        false) echo "✗" ;;
        *) echo "?" ;;
    esac
}

# Check if VM should be included based on filters
should_include_vm() {
    local agent_bus="$1"
    local agent_responding="$2"

    # Apply issues-only filter
    if (( ISSUES_ONLY )); then
        # Include if bus not configured OR agent not responding
        if [[ "$agent_bus" == "true" ]] && [[ "$agent_responding" != "false" ]]; then
            return 1
        fi
    fi

    # Apply filter-responding filter
    if [[ -n "$FILTER_RESPONDING" ]]; then
        case "$FILTER_RESPONDING" in
            yes)
                [[ "$agent_responding" == "true" ]] || return 1
                ;;
            no)
                [[ "$agent_responding" == "false" ]] || return 1
                ;;
            undetermined)
                [[ "$agent_responding" != "true" ]] && [[ "$agent_responding" != "false" ]] || return 1
                ;;
        esac
    fi

    return 0
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

    msg "Analyzing $count server(s) for QEMU agent status..."
    echo ""

    local show_project=0
    if (( ALL_PROJECTS )) || [[ -n "$DOMAIN_FILTER" ]]; then
        show_project=1
    fi

    if (( show_project )); then
        printf "%-36s  %-20s  %-15s  %-17s  %-9s  %-10s  %s\n" \
            "ID" "Name" "Project" "Status" "Agent Bus" "Responding" "Image/Volume"
        printf "%s\n" "$(printf '=%.0s' {1..150})"
    else
        printf "%-36s  %-25s  %-17s  %-9s  %-10s  %s\n" \
            "ID" "Name" "Status" "Agent Bus" "Responding" "Image/Volume"
        printf "%s\n" "$(printf '=%.0s' {1..140})"
    fi

    local i=0
    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Checking agent status..."

        local id name status image_id image_name project_id
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name')
        status=$(echo "$server" | jq -r '.Status // .status')
        image_id=$(echo "$server" | jq -r '."Image ID" // ""')
        image_name=$(echo "$server" | jq -r '."Image Name" // ""')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // "—"')

        # Determine if boot-from-volume (empty or N/A image ID)
        local volume_id=""
        if [[ -z "$image_id" ]] || [[ "$image_id" == "null" ]] || [[ "$image_id" == "" ]] || [[ "$image_id" == *"booted from volume"* ]]; then
            image_id=""
            image_name=""
            volume_id=$(get_server_volumes "$id")
        fi

        # Check agent bus configuration
        local agent_bus=""
        if [[ -n "$image_id" ]]; then
            agent_bus=$(get_image_agent_config "$image_id")
        elif [[ -n "$volume_id" ]]; then
            agent_bus=$(get_volume_agent_config "$volume_id")
        fi

        # Check if agent is responding
        local agent_responding
        agent_responding=$(check_agent_responding "$id" "$status")

        # Skip if issues-only filter active and no issues
        should_include_vm "$agent_bus" "$agent_responding" || continue

        # Get image source name
        local image_source
        image_source=$(get_image_source "$image_id" "$image_name" "$volume_id")

        # Format for display
        local bus_status resp_status
        bus_status=$(format_bool_status "$agent_bus")
        resp_status=$(format_bool_status "$agent_responding")

        # Clear progress bar before printing data row
        (( SHOW_PROGRESS )) && [[ -t 2 ]] && printf "\r%80s\r" "" >&2

        if (( show_project )); then
            local project_name
            project_name=$(cache_project_name "$project_id")
            printf "%-36s  %-20s  %-15s  %-17s  %-9s  %-10s  %s\n" \
                "$id" "${name:0:20}" "${project_name:0:15}" "$status" "$bus_status" "$resp_status" "$image_source"
        else
            printf "%-36s  %-25s  %-17s  %-9s  %-10s  %s\n" \
                "$id" "${name:0:25}" "$status" "$bus_status" "$resp_status" "$image_source"
        fi
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done

    echo ""
    echo -e "${C_DIM}Legend: Agent Bus = hw_qemu_guest_agent in source image${C_RESET}"
    echo -e "${C_DIM}        Responding = agent communicating (detected via Nova diagnostics)${C_RESET}"
    echo -e "${C_DIM}        ✓ = yes, ✗ = no, ? = couldn't determine (VM off or image deleted)${C_RESET}"
}

output_csv() {
    local servers_json="$1"
    local count
    count=$(echo "$servers_json" | jq 'length')

    local show_project=0
    if (( ALL_PROJECTS )) || [[ -n "$DOMAIN_FILTER" ]]; then
        show_project=1
    fi

    if (( show_project )); then
        echo "ID,Name,Project,Status,Agent_Bus,Responding,Image_Source"
    else
        echo "ID,Name,Status,Agent_Bus,Responding,Image_Source"
    fi

    local i=0
    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Checking agent status..."

        local id name status image_id image_name project_id
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name' | sed 's/,/;/g')
        status=$(echo "$server" | jq -r '.Status // .status')
        image_id=$(echo "$server" | jq -r '."Image ID" // ""')
        image_name=$(echo "$server" | jq -r '."Image Name" // ""')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // "—"')

        # Determine if boot-from-volume (empty or N/A image ID)
        local volume_id=""
        if [[ -z "$image_id" ]] || [[ "$image_id" == "null" ]] || [[ "$image_id" == "" ]] || [[ "$image_id" == *"booted from volume"* ]]; then
            image_id=""
            image_name=""
            volume_id=$(get_server_volumes "$id")
        fi

        # Check agent bus configuration
        local agent_bus=""
        if [[ -n "$image_id" ]]; then
            agent_bus=$(get_image_agent_config "$image_id")
        elif [[ -n "$volume_id" ]]; then
            agent_bus=$(get_volume_agent_config "$volume_id")
        fi

        # Check if agent is responding
        local agent_responding
        agent_responding=$(check_agent_responding "$id" "$status")

        # Skip if issues-only filter active and no issues
        should_include_vm "$agent_bus" "$agent_responding" || continue

        # Get image source name
        local image_source
        image_source=$(get_image_source "$image_id" "$image_name" "$volume_id" | sed 's/,/;/g')

        local bus_status resp_status
        bus_status=$(format_bool_status "$agent_bus")
        resp_status=$(format_bool_status "$agent_responding")

        if (( show_project )); then
            local project_name
            project_name=$(cache_project_name "$project_id" | sed 's/,/;/g')
            echo "$id,$name,$project_name,$status,$bus_status,$resp_status,$image_source"
        else
            echo "$id,$name,$status,$bus_status,$resp_status,$image_source"
        fi
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done
}

output_json() {
    local servers_json="$1"
    local count
    count=$(echo "$servers_json" | jq 'length')

    local show_project=0
    if (( ALL_PROJECTS )) || [[ -n "$DOMAIN_FILTER" ]]; then
        show_project=1
    fi

    local result="[]"
    local i=0

    while IFS= read -r server; do
        ((i++)) || true
        progress "$i" "$count" "Checking agent status..."

        local id name status image_id image_name project_id
        id=$(echo "$server" | jq -r '.ID // .id')
        name=$(echo "$server" | jq -r '.Name // .name')
        status=$(echo "$server" | jq -r '.Status // .status')
        image_id=$(echo "$server" | jq -r '."Image ID" // ""')
        image_name=$(echo "$server" | jq -r '."Image Name" // ""')
        project_id=$(echo "$server" | jq -r '."Project ID" // .tenant_id // null')

        # Determine if boot-from-volume (empty or N/A image ID)
        local volume_id=""
        if [[ -z "$image_id" ]] || [[ "$image_id" == "null" ]] || [[ "$image_id" == "" ]] || [[ "$image_id" == *"booted from volume"* ]]; then
            image_id=""
            image_name=""
            volume_id=$(get_server_volumes "$id")
        fi

        # Check agent bus configuration
        local agent_bus=""
        if [[ -n "$image_id" ]]; then
            agent_bus=$(get_image_agent_config "$image_id")
        elif [[ -n "$volume_id" ]]; then
            agent_bus=$(get_volume_agent_config "$volume_id")
        fi

        # Check if agent is responding
        local agent_responding
        agent_responding=$(check_agent_responding "$id" "$status")

        # Skip if issues-only filter active and no issues
        should_include_vm "$agent_bus" "$agent_responding" || continue

        # Get image source name
        local image_source
        image_source=$(get_image_source "$image_id" "$image_name" "$volume_id")

        # Convert to JSON booleans
        local bus_json="null" resp_json="null"
        [[ "$agent_bus" == "true" ]] && bus_json="true"
        [[ "$agent_bus" == "false" ]] && bus_json="false"
        [[ "$agent_responding" == "true" ]] && resp_json="true"
        [[ "$agent_responding" == "false" ]] && resp_json="false"

        local entry
        if (( show_project )); then
            local project_name
            project_name=$(cache_project_name "$project_id")
            entry=$(jq -n \
                --arg id "$id" \
                --arg name "$name" \
                --arg project "$project_name" \
                --arg status "$status" \
                --argjson agent_bus "$bus_json" \
                --argjson agent_responding "$resp_json" \
                --arg image_source "$image_source" \
                '{id: $id, name: $name, project: $project, status: $status, agent_bus: $agent_bus, agent_responding: $agent_responding, image_source: $image_source}')
        else
            entry=$(jq -n \
                --arg id "$id" \
                --arg name "$name" \
                --arg status "$status" \
                --argjson agent_bus "$bus_json" \
                --argjson agent_responding "$resp_json" \
                --arg image_source "$image_source" \
                '{id: $id, name: $name, status: $status, agent_bus: $agent_bus, agent_responding: $agent_responding, image_source: $image_source}')
        fi

        result=$(echo "$result" | jq --argjson entry "$entry" '. += [$entry]')
    done < <(echo "$servers_json" | jq -c '.[]')

    progress_done
    echo "$result" | jq '.'
}

# --- Argument parsing ---------------------------------------------------------

OPTIONS=$(getopt -o hvp:f:ad:qi \
    --long help,version,project:,domain:,format:,all-projects,issues-only,filter-responding:,insecure,quiet \
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
        -i|--issues-only)
            ISSUES_ONLY=1
            shift
            ;;
        --filter-responding)
            FILTER_RESPONDING="$2"
            shift 2
            ;;
        --insecure)
            INSECURE=1
            shift
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
    exit 1
fi

# --- Validation ---------------------------------------------------------------

case "$OUTPUT_FORMAT" in
    table|csv|json) ;;
    *) err "Invalid format '${OUTPUT_FORMAT}'. Use: table, csv, json"; exit 1 ;;
esac

if [[ -n "$FILTER_RESPONDING" ]]; then
    case "$FILTER_RESPONDING" in
        yes|no|undetermined) ;;
        *) err "Invalid filter-responding value '${FILTER_RESPONDING}'. Use: yes, no, undetermined"; exit 1 ;;
    esac
fi

# Disable progress for non-table output
if [[ "$OUTPUT_FORMAT" != "table" ]]; then
    SHOW_PROGRESS=0
fi

# --- Main execution -----------------------------------------------------------

check_deps
check_auth

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
