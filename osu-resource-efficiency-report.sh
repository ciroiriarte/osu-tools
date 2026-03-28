#!/usr/bin/env bash

# Script Name: osu-resource-efficiency-report.sh
# Description: Reports OpenStack resource allocation and efficiency per project.
#              Shows each VM's assigned vCPU, RAM, root disk, and Cinder volume
#              usage alongside real CPU and memory utilisation from Nova
#              diagnostics. Flags unreliable memory data when the virtio-balloon
#              driver or qemu-guest-agent is absent.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-27
# Version: 0.1
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - curl (for Nova diagnostics REST API)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#   - Admin or domain admin scope for cross-project reports
#
# Changelog:
#   - 2026-03-27: v0.1 - Initial release. Per-VM allocation and efficiency
#                        report with Nova diagnostics integration, CPU time
#                        estimation, balloon-aware memory reporting, CSV/JSON
#                        output, and multi-project/domain support.

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.1"

# Operational defaults
OUTPUT_FORMAT="table"
PROJECT_FILTER=""
DOMAIN_FILTER=""
ALL_PROJECTS=0
NO_DIAGNOSTICS=0
DRY_RUN=0

# API cache
AUTH_TOKEN=""
NOVA_ENDPOINT=""

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

elapsed_human() {
    local secs="$1"
    if (( secs >= 86400 )); then
        printf '%dd %dh' $((secs / 86400)) $(( (secs % 86400) / 3600 ))
    elif (( secs >= 3600 )); then
        printf '%dh %dm' $((secs / 3600)) $(( (secs % 3600) / 60 ))
    elif (( secs >= 60 )); then
        printf '%dm %ds' $((secs / 60)) $((secs % 60))
    else
        printf '%ds' "$secs"
    fi
}

progress() {
    local current="$1" total="$2" label="$3"
    local pct=$(( current * 100 / total ))
    local filled=$(( pct / 5 ))
    local empty=$(( 20 - filled ))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')
    printf "\r   [%s] %3d%% (%d/%d) %s" "$bar" "$pct" "$current" "$total" "$label" >&2
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] [DOMAIN]

Version: $SCRIPT_VERSION

Description:
  Reports OpenStack resource allocation and efficiency per project. For each
  VM, shows assigned vCPU, RAM, root disk, and Cinder volume usage alongside
  real CPU and memory utilisation from Nova diagnostics.

  CPU efficiency is estimated as average utilisation over the VM's lifetime
  from cumulative CPU time vs uptime. Memory efficiency uses the hypervisor's
  balloon-reported usage (requires virtio-balloon / qemu-guest-agent for
  accurate readings).

Modes:
  DOMAIN                  Report all projects in the given domain
  -p, --project PROJECT   Report a single project (by name or ID)
  -a, --all-projects      Report across all accessible projects

Options:
  -f, --format FMT        Output format: table (default), csv, json
      --no-diagnostics    Skip Nova diagnostics (faster, allocation only)
  -n, --dry-run           Show what would be queried without making API calls
  -h, --help              Show this help message
  -v, --version           Show version

Output columns:
  VM Name     Instance name (or ID if unnamed)
  Status      Nova instance state (ACTIVE, SHUTOFF, etc.)
  vCPU        Assigned virtual CPUs (from flavor)
  RAM(M)      Assigned RAM in MiB (from flavor)
  Disk(G)     Root disk in GiB (from flavor)
  vDisk(G)    Total attached Cinder volume size in GiB
  CPU%        Estimated average CPU utilisation (diagnostics)
  RAM%        Memory utilisation (diagnostics, balloon-reported)
  Uptime      VM uptime from diagnostics

  CPU% and RAM% are only available for ACTIVE VMs with diagnostics enabled.
  RAM% is flagged with '~' when used == maximum (no balloon driver detected,
  value is unreliable).

Requirements:
  - openstack CLI (python-openstackclient) with valid credentials
  - curl (for Nova diagnostics API)
  - jq

Examples:
  # Report all projects in a domain
  $0 my-domain

  # Report a single project
  $0 -p my-project

  # All accessible projects
  $0 -a

  # CSV output (for spreadsheets/scripts)
  $0 -f csv my-domain

  # JSON output
  $0 -f json -p my-project

  # Allocation only (skip diagnostics for speed)
  $0 --no-diagnostics my-domain
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

# --- API helpers --------------------------------------------------------------

ensure_token() {
    if [[ -z "$AUTH_TOKEN" ]]; then
        AUTH_TOKEN=$(openstack token issue -f value -c id 2>/dev/null) || {
            err "OpenStack authentication failed."
            err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
            exit 1
        }
    fi
}

ensure_nova_endpoint() {
    if [[ -z "$NOVA_ENDPOINT" ]]; then
        local catalog_json
        catalog_json=$(openstack catalog show nova -f json 2>/dev/null) || {
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
            err "No Nova endpoint found in service catalog."
            exit 1
        fi
    fi
}

# --- Data collection ----------------------------------------------------------

fetch_server_diagnostics() {
    local server_id="$1"
    ensure_token
    ensure_nova_endpoint
    curl -sk --max-time 15 \
        "${NOVA_ENDPOINT}/servers/${server_id}/diagnostics" \
        -H "X-Auth-Token: ${AUTH_TOKEN}" \
        -H "OpenStack-API-Version: compute 2.48" \
        2>/dev/null || echo '{}'
}

fetch_volume_size() {
    local vol_id="$1"
    openstack volume show "$vol_id" -f json 2>/dev/null \
        | jq '.size // 0' || echo 0
}

# --- Report data collection ---------------------------------------------------

# Collect per-VM data for a project. Outputs one JSON object per VM to stdout.
collect_project_vms() {
    local project_id="$1"
    local servers_json
    servers_json=$(openstack server list --project "$project_id" -f json 2>/dev/null || echo '[]')
    local count
    count=$(echo "$servers_json" | jq 'length')

    if (( count == 0 )); then
        return
    fi

    local idx=0
    while IFS= read -r server_line; do
        (( idx++ )) || true
        local sid sname sstatus
        sid=$(echo "$server_line" | jq -r '.ID')
        sname=$(echo "$server_line" | jq -r '.Name // ""')
        sstatus=$(echo "$server_line" | jq -r '.Status // "UNKNOWN"')

        # Show progress for table format
        if [[ "$OUTPUT_FORMAT" == "table" ]]; then
            progress "$idx" "$count" "${sname:0:30}"
        fi

        # Get detailed server info (flavor is embedded)
        local sjson
        sjson=$(openstack server show "$sid" -f json 2>/dev/null || echo '{}')
        [[ "$sjson" == '{}' ]] && continue

        # Extract flavor data
        local vcpus ram disk
        vcpus=$(echo "$sjson" | jq '.flavor.vcpus // 0')
        ram=$(echo "$sjson" | jq '.flavor.ram // 0')
        disk=$(echo "$sjson" | jq '.flavor.disk // 0')

        # Calculate total Cinder volume size
        local vol_ids vol_total=0
        mapfile -t vol_ids < <(echo "$sjson" | jq -r '
            if (.volumes_attached | type) == "array" then
                .volumes_attached[].id
            else
                empty
            end' 2>/dev/null)

        local vid
        for vid in "${vol_ids[@]}"; do
            [[ -z "$vid" ]] && continue
            local vsize
            vsize=$(fetch_volume_size "$vid")
            vol_total=$((vol_total + vsize))
        done

        # Diagnostics (ACTIVE VMs only, unless disabled)
        local cpu_pct="null" ram_pct="null" ram_reliable="null" uptime_sec="null"

        if (( ! NO_DIAGNOSTICS )) && [[ "$sstatus" == "ACTIVE" ]]; then
            local diag_json
            diag_json=$(fetch_server_diagnostics "$sid")

            # Check we got valid diagnostics (not an error response)
            local diag_state
            diag_state=$(echo "$diag_json" | jq -r '.state // ""')

            if [[ "$diag_state" == "running" ]]; then
                uptime_sec=$(echo "$diag_json" | jq '.uptime // 0')
                local num_cpus
                num_cpus=$(echo "$diag_json" | jq '.num_cpus // 1')

                # CPU: sum of cpu_time (nanoseconds) / (uptime * num_cpus * 1e9)
                local total_cpu_ns
                total_cpu_ns=$(echo "$diag_json" | jq '[.cpu_details[]?.time // 0] | add // 0')
                if (( uptime_sec > 0 && num_cpus > 0 )); then
                    # Use awk for floating point
                    cpu_pct=$(awk "BEGIN { printf \"%.1f\", ($total_cpu_ns / ($uptime_sec * $num_cpus * 1000000000)) * 100 }")
                fi

                # Memory: used / maximum
                local mem_max mem_used
                mem_max=$(echo "$diag_json" | jq '.memory_details.maximum // 0')
                mem_used=$(echo "$diag_json" | jq '.memory_details.used // 0')
                if (( mem_max > 0 )); then
                    ram_pct=$(awk "BEGIN { printf \"%.0f\", ($mem_used / $mem_max) * 100 }")
                    if (( mem_used >= mem_max )); then
                        ram_reliable="false"
                    else
                        ram_reliable="true"
                    fi
                fi
            fi
        fi

        # Emit JSON record
        local name_json
        name_json=$(printf '%s' "$sname" | jq -Rs .)
        printf '{"name":%s,"id":"%s","status":"%s","vcpus":%d,"ram":%d,"disk":%d,"vdisk":%d,"cpu_pct":%s,"ram_pct":%s,"ram_reliable":%s,"uptime":%s}\n' \
            "$name_json" "$sid" "$sstatus" "$vcpus" "$ram" "$disk" "$vol_total" \
            "$cpu_pct" "$ram_pct" "$ram_reliable" "$uptime_sec"
    done < <(echo "$servers_json" | jq -c '.[]')

    # Clear progress line
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "\r%-80s\r" "" >&2
    fi
}

# --- Output formatting --------------------------------------------------------

format_table_header() {
    local sep
    sep=$(printf '%*s' 107 '' | tr ' ' '-')
    printf "  %-22s %-9s %5s %7s %7s %8s %5s %5s  %s\n" \
        "VM Name" "Status" "vCPU" "RAM(M)" "Disk(G)" "vDisk(G)" "CPU%" "RAM%" "Uptime"
    echo "  ${sep}"
}

format_table_row() {
    local json="$1"
    local name status vcpus ram disk vdisk cpu_pct ram_pct ram_reliable uptime

    name=$(echo "$json" | jq -r '.name // ""')
    [[ -z "$name" ]] && name=$(echo "$json" | jq -r '.id')
    status=$(echo "$json" | jq -r '.status')
    vcpus=$(echo "$json" | jq '.vcpus')
    ram=$(echo "$json" | jq '.ram')
    disk=$(echo "$json" | jq '.disk')
    vdisk=$(echo "$json" | jq '.vdisk')
    cpu_pct=$(echo "$json" | jq -r '.cpu_pct')
    ram_pct=$(echo "$json" | jq -r '.ram_pct')
    ram_reliable=$(echo "$json" | jq -r '.ram_reliable')
    uptime=$(echo "$json" | jq -r '.uptime')

    local cpu_str ram_str uptime_str
    if [[ "$cpu_pct" == "null" ]]; then
        cpu_str="—"
    else
        cpu_str="${cpu_pct}%"
    fi

    if [[ "$ram_pct" == "null" ]]; then
        ram_str="—"
    elif [[ "$ram_reliable" == "false" ]]; then
        ram_str="~${ram_pct}%"
    else
        ram_str="${ram_pct}%"
    fi

    if [[ "$uptime" == "null" || "$uptime" == "0" ]]; then
        uptime_str="—"
    else
        uptime_str=$(elapsed_human "$uptime")
    fi

    printf "  %-22s %-9s %5d %7d %7d %8d %5s %5s  %s\n" \
        "${name:0:22}" "$status" "$vcpus" "$ram" "$disk" "$vdisk" \
        "$cpu_str" "$ram_str" "$uptime_str"
}

format_table_totals() {
    local total_vms="$1" total_vcpus="$2" total_ram="$3" total_disk="$4" total_vdisk="$5"
    local sep
    sep=$(printf '%*s' 107 '' | tr ' ' '-')
    echo "  ${sep}"
    printf "  %-22s %-9s %5d %7d %7d %8d\n" \
        "Totals (${total_vms} VMs)" "" "$total_vcpus" "$total_ram" "$total_disk" "$total_vdisk"
}

format_csv_header() {
    echo "project_id,project_name,vm_id,vm_name,status,vcpus,ram_mib,disk_gib,vdisk_gib,cpu_pct,ram_pct,ram_reliable,uptime_sec"
}

format_csv_row() {
    local project_id="$1" project_name="$2" json="$3"
    echo "$json" | jq -r --arg pid "$project_id" --arg pname "$project_name" '
        [$pid, $pname, .id, .name, .status,
         (.vcpus|tostring), (.ram|tostring), (.disk|tostring), (.vdisk|tostring),
         (if .cpu_pct == null then "" else (.cpu_pct|tostring) end),
         (if .ram_pct == null then "" else (.ram_pct|tostring) end),
         (if .ram_reliable == null then "" else (.ram_reliable|tostring) end),
         (if .uptime == null then "" else (.uptime|tostring) end)
        ] | @csv'
}

# --- Report orchestration -----------------------------------------------------

report_project() {
    local project_id="$1" project_name="$2"
    local vm_records=()
    local total_vms=0 total_vcpus=0 total_ram=0 total_disk=0 total_vdisk=0

    # Collect VM data
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        vm_records+=("$record")
    done < <(collect_project_vms "$project_id")

    total_vms=${#vm_records[@]}

    if (( total_vms == 0 )); then
        if [[ "$OUTPUT_FORMAT" == "table" ]]; then
            msg "Project: ${project_name} (${project_id}) — no instances"
        fi
        return
    fi

    # Table: print project header
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        echo ""
        msg "Project: ${project_name} (${project_id})"
        echo ""
        format_table_header
    fi

    local record
    for record in "${vm_records[@]}"; do
        local v_vcpus v_ram v_disk v_vdisk
        v_vcpus=$(echo "$record" | jq '.vcpus')
        v_ram=$(echo "$record" | jq '.ram')
        v_disk=$(echo "$record" | jq '.disk')
        v_vdisk=$(echo "$record" | jq '.vdisk')

        total_vcpus=$((total_vcpus + v_vcpus))
        total_ram=$((total_ram + v_ram))
        total_disk=$((total_disk + v_disk))
        total_vdisk=$((total_vdisk + v_vdisk))

        case "$OUTPUT_FORMAT" in
            table) format_table_row "$record" ;;
            csv)   format_csv_row "$project_id" "$project_name" "$record" ;;
            json)  echo "$record" | jq -c --arg pid "$project_id" --arg pname "$project_name" \
                       '. + {project_id: $pid, project_name: $pname}' ;;
        esac
    done

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        format_table_totals "$total_vms" "$total_vcpus" "$total_ram" "$total_disk" "$total_vdisk"
    fi
}

# --- Argument parsing ---------------------------------------------------------

OPTIONS=$(getopt -o hvp:f:an \
    --long help,version,project:,format:,all-projects,no-diagnostics,dry-run \
    -n "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    echo "Failed to parse options." >&2
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
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -a|--all-projects)
            ALL_PROJECTS=1
            shift
            ;;
        --no-diagnostics)
            NO_DIAGNOSTICS=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
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

# Positional: domain name
DOMAIN_FILTER="${1:-}"

# --- Validation ---------------------------------------------------------------

case "$OUTPUT_FORMAT" in
    table|csv|json) ;;
    *) err "Invalid format '${OUTPUT_FORMAT}'. Use: table, csv, json"; exit 1 ;;
esac

# Must specify at least one scope
if [[ -z "$PROJECT_FILTER" && -z "$DOMAIN_FILTER" ]] && (( ! ALL_PROJECTS )); then
    show_help >&2
    exit 1
fi

# --- Main execution -----------------------------------------------------------

check_deps

if (( DRY_RUN )); then
    msg "Dry run — would query:"
    if [[ -n "$PROJECT_FILTER" ]]; then
        echo "  Project: ${PROJECT_FILTER}" >&2
    elif [[ -n "$DOMAIN_FILTER" ]]; then
        echo "  Domain: ${DOMAIN_FILTER} (all projects)" >&2
    else
        echo "  All accessible projects" >&2
    fi
    echo "  Diagnostics: $(( ! NO_DIAGNOSTICS ? 1 : 0 ))" >&2
    echo "  Format: ${OUTPUT_FORMAT}" >&2
    exit 0
fi

# CSV/JSON headers
if [[ "$OUTPUT_FORMAT" == "csv" ]]; then
    format_csv_header
elif [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "["
fi

JSON_FIRST=1

run_report_for_project() {
    local pid="$1" pname="$2"
    if [[ "$OUTPUT_FORMAT" == "json" && "$JSON_FIRST" -eq 0 ]]; then
        # JSON array separator handled by jq output
        :
    fi
    JSON_FIRST=0
    report_project "$pid" "$pname"
}

if [[ -n "$PROJECT_FILTER" ]]; then
    # Single project mode
    msg "Resolving project: ${PROJECT_FILTER}"
    PROJ_JSON=$(openstack project show "$PROJECT_FILTER" -f json 2>/dev/null) || {
        err "Project '${PROJECT_FILTER}' not found or not accessible."
        exit 1
    }
    PROJ_ID=$(echo "$PROJ_JSON" | jq -r '.id')
    PROJ_NAME=$(echo "$PROJ_JSON" | jq -r '.name')
    ok "Project: ${PROJ_NAME} (${PROJ_ID})"
    run_report_for_project "$PROJ_ID" "$PROJ_NAME"

elif [[ -n "$DOMAIN_FILTER" ]]; then
    # Domain mode — iterate projects
    msg "Fetching projects for domain: ${DOMAIN_FILTER}"
    PROJECTS_JSON=$(openstack project list --domain "$DOMAIN_FILTER" -f json 2>/dev/null) || {
        err "Domain '${DOMAIN_FILTER}' not found or not accessible."
        exit 1
    }
    PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')
    ok "Found ${PROJ_COUNT} project(s)"

    if (( PROJ_COUNT == 0 )); then
        warn "No projects in domain '${DOMAIN_FILTER}'."
    else
        PIDX=0
        while IFS= read -r pline; do
            (( PIDX++ )) || true
            PID_CUR=$(echo "$pline" | jq -r '.ID')
            PNAME_CUR=$(echo "$pline" | jq -r '.Name')
            msg "[${PIDX}/${PROJ_COUNT}] ${PNAME_CUR}"
            run_report_for_project "$PID_CUR" "$PNAME_CUR"
        done < <(echo "$PROJECTS_JSON" | jq -c '.[]')
    fi

elif (( ALL_PROJECTS )); then
    # All accessible projects
    msg "Fetching all accessible projects"
    PROJECTS_JSON=$(openstack project list -f json 2>/dev/null || echo '[]')
    PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')
    ok "Found ${PROJ_COUNT} project(s)"

    if (( PROJ_COUNT == 0 )); then
        warn "No accessible projects."
    else
        PIDX=0
        while IFS= read -r pline; do
            (( PIDX++ )) || true
            PID_CUR=$(echo "$pline" | jq -r '.ID')
            PNAME_CUR=$(echo "$pline" | jq -r '.Name')
            msg "[${PIDX}/${PROJ_COUNT}] ${PNAME_CUR}"
            run_report_for_project "$PID_CUR" "$PNAME_CUR"
        done < <(echo "$PROJECTS_JSON" | jq -c '.[]')
    fi
fi

# Close JSON array
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "]"
fi

# Legend for table mode
if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    echo ""
    echo -e "  ${C_DIM}Legend: CPU% = avg CPU utilisation (lifetime estimate from cumulative CPU time)${C_RESET}"
    echo -e "  ${C_DIM}        RAM% = balloon-reported memory usage (~ = unreliable, no balloon detected)${C_RESET}"
    echo -e "  ${C_DIM}        —    = not available (VM not running or diagnostics disabled)${C_RESET}"
    echo ""
fi
