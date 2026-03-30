#!/usr/bin/env bash

# Script Name: osu-resource-efficiency-report.sh
# Description: Reports OpenStack resource allocation and efficiency per project.
#              Shows each VM's assigned vCPU, RAM, root disk, and Cinder volume
#              usage alongside real CPU and memory utilisation from Gnocchi
#              metrics (with fallback to Nova diagnostics), Ceph RBD actual
#              storage consumption, and guest-agent filesystem/load data.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-27
# Version: 0.2.0
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - curl (for Nova diagnostics REST API)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#   - Admin or domain admin scope for cross-project reports
#
# Optional:
#   - juju (for Ceph RBD storage and guest-agent queries)
#   - Gnocchi metrics service (for recent CPU/memory data)
#
# Changelog:
#   - 2026-03-27: v0.2.0 - Add Gnocchi metrics (CPU%, RAM used), Ceph RBD
#                           actual storage via juju/rbd, guest-agent filesystem
#                           and load data via juju/virsh, two-line table output
#                           with per-VM filesystem details, --no-ceph and
#                           --no-agent options.
#   - 2026-03-27: v0.1   - Initial release. Per-VM allocation and efficiency
#                           report with Nova diagnostics integration, CPU time
#                           estimation, balloon-aware memory reporting, CSV/JSON
#                           output, and multi-project/domain support.

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.3.0"

# Operational defaults
OUTPUT_FORMAT="table"
PROJECT_FILTER=""
DOMAIN_FILTER=""
NO_DIAGNOSTICS=0
NO_CEPH=0
NO_AGENT=0
DRY_RUN=0

# API cache
AUTH_TOKEN=""
NOVA_ENDPOINT=""

# Juju availability flag (set during init)
JUJU_AVAILABLE=0

# Gnocchi metric window (5 minutes)
GNOCCHI_WINDOW=300

# Associative arrays for batch-built lookup tables
declare -A CEPH_RBD_USED=()          # key: "pool/volume-UUID" -> used bytes
declare -A CEPH_POOLS_FETCHED=()     # key: pool name -> 1 (already fetched)
declare -A NOVA_HOST_TO_UNIT=()      # key: hostname -> juju unit (e.g. nova-compute/3)
declare -A CEPH_BACKEND_POOL=()      # key: backend name -> pool name

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
  real CPU and memory utilisation from Gnocchi metrics (with fallback to Nova
  diagnostics lifetime average), Ceph RBD actual storage consumption, and
  guest-agent filesystem/load data.

  CPU% uses the most recent 5-minute Gnocchi rate:mean metric when available,
  falling back to Nova diagnostics lifetime average.

  Memory usage comes from Gnocchi memory.usage metric (actual MiB consumed),
  falling back to Nova diagnostics balloon-reported values.

  RBD actual storage is queried via juju ssh to ceph-mon (batch per pool).
  Guest-agent data (filesystem usage, load) is queried via juju ssh to
  nova-compute units using virsh qemu-agent-command.

Scope:
  (default)               Report all projects across all accessible domains
  DOMAIN                  Limit to projects in the given domain
  -p, --project PROJECT   Limit to a single project (by name or ID)

Options:
  -f, --format FMT        Output format: table (default), csv, json
      --no-diagnostics    Skip Nova diagnostics (faster, allocation only)
      --no-ceph           Skip Ceph RBD storage queries
      --no-agent          Skip guest agent queries
  -n, --dry-run           Show what would be queried without making API calls
  -h, --help              Show this help message
  -v, --version           Show version

Output columns (table):
  VM Name     Instance name (or ID if unnamed)
  Status      Nova instance state (ACTIVE, SHUTOFF, etc.)
  Agent       Guest agent: yes / no / — (not running)
  vCPU        Assigned virtual CPUs (from flavor)
  RAM(M)      Assigned RAM in MiB (from flavor)
  RAM%        Memory utilisation from Gnocchi or diagnostics
  CPU%        Recent CPU utilisation (Gnocchi 5min) or lifetime avg
  Load        1-minute load average from guest agent
  vDisk(G)    Total attached Cinder volume size in GiB
  RBD(G)      Actual Ceph storage used (from rbd du)
  FS%         Root filesystem usage from guest agent
  Uptime      VM uptime from diagnostics

  When guest agent data is available, a second line shows per-filesystem
  details (mountpoint, total size, used size, usage percentage).

Requirements:
  - openstack CLI (python-openstackclient) with valid credentials
  - curl (for Nova diagnostics API)
  - jq

Optional:
  - juju (for Ceph RBD storage and guest-agent queries)

Examples:
  # Report all domains and projects (default)
  $0

  # Report all projects in a specific domain
  $0 my-domain

  # Report a single project
  $0 -p my-project

  # CSV output (for spreadsheets/scripts)
  $0 -f csv my-domain

  # JSON output
  $0 -f json -p my-project

  # Allocation only (skip all enrichment)
  $0 --no-diagnostics --no-ceph --no-agent my-domain

  # Skip Ceph queries but keep agent and diagnostics
  $0 --no-ceph my-domain
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

check_juju() {
    if command -v juju &>/dev/null; then
        # Quick check: can we reach a juju controller?
        if juju status --format json &>/dev/null; then
            JUJU_AVAILABLE=1
        else
            warn "juju is installed but controller is unreachable; skipping juju features"
        fi
    else
        if (( ! NO_CEPH )) || (( ! NO_AGENT )); then
            warn "juju not available; Ceph RBD and guest-agent features disabled"
        fi
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

# --- Gnocchi metrics ----------------------------------------------------------

fetch_gnocchi_cpu() {
    local resource_id="$1" num_cpus="$2"
    local start_time
    start_time=$(date -u -d "-${GNOCCHI_WINDOW} seconds" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) || \
        start_time=$(date -u -v-${GNOCCHI_WINDOW}S '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) || \
        return 1

    local measures_json
    measures_json=$(openstack --insecure metric measures show \
        --resource-id "$resource_id" cpu \
        --aggregation rate:mean \
        --start "$start_time" \
        -f json 2>/dev/null) || return 1

    local count
    count=$(echo "$measures_json" | jq 'length')
    (( count == 0 )) && return 1

    # Get the most recent measurement value (rate:mean gives ns/s)
    local rate_mean
    rate_mean=$(echo "$measures_json" | jq '.[-1][2] // 0')

    # rate:mean is nanoseconds consumed per second over granularity window
    # CPU% = rate_mean / (granularity * num_cpus * 1e9) * 100
    # But rate:mean from Gnocchi rate aggregation is already rate per second,
    # so: CPU% = rate_mean / (num_cpus * 1e9) * 100
    local cpu_pct
    cpu_pct=$(awk "BEGIN { v = ($rate_mean / ($num_cpus * 1000000000)) * 100; if (v > 100) v = 100; printf \"%.1f\", v }")
    echo "$cpu_pct"
}

fetch_gnocchi_memory() {
    local resource_id="$1"
    local start_time
    start_time=$(date -u -d "-${GNOCCHI_WINDOW} seconds" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) || \
        start_time=$(date -u -v-${GNOCCHI_WINDOW}S '+%Y-%m-%dT%H:%M:%S' 2>/dev/null) || \
        return 1

    local measures_json
    measures_json=$(openstack --insecure metric measures show \
        --resource-id "$resource_id" memory.usage \
        --aggregation mean \
        --start "$start_time" \
        -f json 2>/dev/null) || return 1

    local count
    count=$(echo "$measures_json" | jq 'length')
    (( count == 0 )) && return 1

    # Returns MiB used
    local mem_used
    mem_used=$(echo "$measures_json" | jq '.[-1][2] // 0')
    echo "$mem_used"
}

# --- Ceph RBD storage ---------------------------------------------------------

# Extract pool name from volume host attribute
resolve_ceph_pool() {
    local vol_host="$1"
    # vol_host looks like: cinder@cinder-ceph#cinder-ceph or cinder@cinder-ceph-fast#fast
    local backend_section="${vol_host%%#*}"   # cinder@cinder-ceph-fast
    local backend_name="${backend_section#*@}" # cinder-ceph-fast
    local pool_hint="${vol_host##*#}"          # fast or cinder-ceph

    # Check cache first
    if [[ -n "${CEPH_BACKEND_POOL[$backend_name]+x}" ]]; then
        echo "${CEPH_BACKEND_POOL[$backend_name]}"
        return
    fi

    # Default pool: the part after #
    local pool_name="$pool_hint"

    # For non-default backends, query juju config for the actual pool name
    if [[ "$backend_name" != "cinder-ceph" ]]; then
        local configured_pool
        configured_pool=$(juju config "$backend_name" rbd-pool-name 2>/dev/null) || true
        if [[ -n "$configured_pool" ]]; then
            pool_name="$configured_pool"
        fi
    fi

    CEPH_BACKEND_POOL["$backend_name"]="$pool_name"
    echo "$pool_name"
}

# Fetch all RBD images in a pool (batch) and populate CEPH_RBD_USED
fetch_ceph_pool_rbd() {
    local pool="$1"

    # Skip if already fetched
    [[ -n "${CEPH_POOLS_FETCHED[$pool]+x}" ]] && return 0

    local rbd_json
    rbd_json=$(juju ssh ceph-mon/0 -- sudo rbd du -p "$pool" --format json 2>/dev/null) || {
        warn "Could not query Ceph pool '${pool}' via juju"
        CEPH_POOLS_FETCHED["$pool"]=1
        return 1
    }

    # Parse each image entry
    local entries
    entries=$(echo "$rbd_json" | jq -c '.images[]? // empty' 2>/dev/null) || true

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local img_name used_size
        img_name=$(echo "$entry" | jq -r '.name // ""')
        used_size=$(echo "$entry" | jq '.used_size // 0')
        [[ -z "$img_name" ]] && continue
        CEPH_RBD_USED["${pool}/${img_name}"]="$used_size"
    done <<< "$entries"

    CEPH_POOLS_FETCHED["$pool"]=1
}

# Lookup RBD used size for a specific volume
lookup_rbd_used() {
    local pool="$1" volume_rbd_name="$2"
    local key="${pool}/${volume_rbd_name}"
    if [[ -n "${CEPH_RBD_USED[$key]+x}" ]]; then
        echo "${CEPH_RBD_USED[$key]}"
    else
        echo ""
    fi
}

# --- Nova-compute host to juju unit mapping -----------------------------------

build_nova_host_map() {
    (( ! JUJU_AVAILABLE )) && return

    local unit_count
    unit_count=$(juju status nova-compute --format json 2>/dev/null \
        | jq '.applications["nova-compute"].units | length' 2>/dev/null) || return

    (( unit_count == 0 )) && return

    msg "Building nova-compute host map (${unit_count} units)"

    local i=0
    while (( i < unit_count )); do
        local hostname
        hostname=$(juju ssh "nova-compute/${i}" -- hostname 2>/dev/null) || {
            (( i++ )) || true
            continue
        }
        # Strip trailing whitespace/newline
        hostname="${hostname%%[[:space:]]}"
        hostname="${hostname%$'\r'}"
        if [[ -n "$hostname" ]]; then
            NOVA_HOST_TO_UNIT["$hostname"]="nova-compute/${i}"
            # Also map the FQDN variant — Nova may report either
            local fqdn
            fqdn=$(juju ssh "nova-compute/${i}" -- hostname -f 2>/dev/null) || true
            fqdn="${fqdn%%[[:space:]]}"
            fqdn="${fqdn%$'\r'}"
            if [[ -n "$fqdn" && "$fqdn" != "$hostname" ]]; then
                NOVA_HOST_TO_UNIT["$fqdn"]="nova-compute/${i}"
            fi
        fi
        (( i++ )) || true
    done

    ok "Mapped ${#NOVA_HOST_TO_UNIT[@]} nova-compute host(s)"
}

# --- Guest agent queries ------------------------------------------------------

# Check if guest agent is reachable
# Note: JSON must be triple-escaped to survive: script -> juju ssh -> virsh
guest_agent_ping() {
    local unit="$1" instance_name="$2"
    juju ssh "$unit" -- \
        "sudo virsh qemu-agent-command $instance_name '{\"execute\":\"guest-ping\"}'" \
        < /dev/null &>/dev/null
}

# Get filesystem info from guest agent
guest_agent_fsinfo() {
    local unit="$1" instance_name="$2"
    juju ssh "$unit" -- \
        "sudo virsh qemu-agent-command $instance_name '{\"execute\":\"guest-get-fsinfo\"}'" \
        < /dev/null 2>/dev/null
}

# Get load averages from guest agent (QEMU 8.x+)
guest_agent_load() {
    local unit="$1" instance_name="$2"
    juju ssh "$unit" -- \
        "sudo virsh qemu-agent-command $instance_name '{\"execute\":\"guest-get-load\"}'" \
        < /dev/null 2>/dev/null
}

# Parse filesystem info into structured data
# Returns JSON array: [{"mountpoint":"/","total_bytes":N,"used_bytes":N},...]
parse_fsinfo() {
    local fsinfo_json="$1"
    echo "$fsinfo_json" | jq -c '
        [.return[]? |
         select(.mountpoint != null and .mountpoint != "") |
         select(.type != "squashfs" and .type != "tmpfs" and .type != "devtmpfs") |
         {
           mountpoint: .mountpoint,
           total_bytes: (.["total-bytes"] // 0),
           used_bytes: (.["used-bytes"] // 0),
           type: (.type // "unknown")
         }
        ] | sort_by(.mountpoint)' 2>/dev/null || echo '[]'
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

fetch_volume_details() {
    local vol_id="$1"
    openstack volume show "$vol_id" -f json 2>/dev/null || echo '{}'
}

# --- Report data collection ---------------------------------------------------

# Collect per-VM data for a project. Outputs one JSON object per VM to stdout.
collect_project_vms() {
    # Disable errexit for this function — many API calls can fail
    # without invalidating the rest of the report
    set +e
    local project_id="$1"
    local servers_json
    servers_json=$(openstack server list --project "$project_id" -f json 2>/dev/null || echo '[]')
    local count
    count=$(echo "$servers_json" | jq 'length')

    if (( count == 0 )); then
        return
    fi

    # Pre-collect all volume hosts for Ceph pool batch fetching
    if (( ! NO_CEPH )) && (( JUJU_AVAILABLE )); then
        prefetch_ceph_pools "$project_id" "$servers_json"
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

        # Extract host for agent queries
        local server_host instance_name
        server_host=$(echo "$sjson" | jq -r '
            .["OS-EXT-SRV-ATTR:host"] // .compute_host // ""')
        instance_name=$(echo "$sjson" | jq -r '
            .["OS-EXT-SRV-ATTR:instance_name"] // ""')

        # Collect volume info and calculate totals + RBD usage
        local vol_ids vol_total=0 rbd_total_bytes=0 has_rbd_data=0
        mapfile -t vol_ids < <(echo "$sjson" | jq -r '
            if (.volumes_attached | type) == "array" then
                .volumes_attached[].id
            else
                empty
            end' 2>/dev/null)

        local vid
        for vid in "${vol_ids[@]}"; do
            [[ -z "$vid" ]] && continue
            local vol_json vsize vol_host vol_name_id vol_rbd_name
            vol_json=$(fetch_volume_details "$vid")

            vsize=$(echo "$vol_json" | jq '.size // 0')
            vol_total=$((vol_total + vsize))

            # RBD lookup
            if (( ! NO_CEPH )) && (( JUJU_AVAILABLE )); then
                vol_host=$(echo "$vol_json" | jq -r '.["os-vol-host-attr:host"] // ""')
                vol_name_id=$(echo "$vol_json" | jq -r '.["os-vol-mig-status-attr:name_id"] // ""')

                # Determine RBD image name
                if [[ -n "$vol_name_id" && "$vol_name_id" != "null" && "$vol_name_id" != "None" ]]; then
                    vol_rbd_name="volume-${vol_name_id}"
                else
                    vol_rbd_name="volume-${vid}"
                fi

                if [[ -n "$vol_host" && "$vol_host" != "null" ]]; then
                    local pool
                    pool=$(resolve_ceph_pool "$vol_host")
                    if [[ -n "$pool" ]]; then
                        local used_bytes
                        used_bytes=$(lookup_rbd_used "$pool" "$vol_rbd_name")
                        if [[ -n "$used_bytes" ]]; then
                            rbd_total_bytes=$((rbd_total_bytes + used_bytes))
                            has_rbd_data=1
                        fi
                    fi
                fi
            fi
        done

        # RBD used in GiB (float)
        local rbd_used_gib="null"
        if (( has_rbd_data )); then
            rbd_used_gib=$(awk "BEGIN { printf \"%.1f\", $rbd_total_bytes / (1024*1024*1024) }")
        fi

        # --- Gnocchi metrics (CPU% and RAM used) ---
        local cpu_pct="null" ram_pct="null" ram_used_mib="null"
        local ram_reliable="null" uptime_sec="null"
        local gnocchi_cpu_ok=0 gnocchi_mem_ok=0

        if (( ! NO_DIAGNOSTICS )); then
            # Try Gnocchi first (works for ACTIVE and recently-stopped VMs)
            local gnocchi_cpu_val gnocchi_mem_val
            gnocchi_cpu_val=$(fetch_gnocchi_cpu "$sid" "$vcpus" 2>/dev/null) || true
            if [[ -n "$gnocchi_cpu_val" ]]; then
                cpu_pct="$gnocchi_cpu_val"
                gnocchi_cpu_ok=1
            fi

            gnocchi_mem_val=$(fetch_gnocchi_memory "$sid" 2>/dev/null) || true
            if [[ -n "$gnocchi_mem_val" ]]; then
                ram_used_mib="$gnocchi_mem_val"
                gnocchi_mem_ok=1
                if (( ram > 0 )); then
                    ram_pct=$(awk "BEGIN { printf \"%.0f\", ($gnocchi_mem_val / $ram) * 100 }")
                fi
                ram_reliable="true"
            fi

            # Fall back to Nova diagnostics for ACTIVE VMs if Gnocchi unavailable
            if [[ "$sstatus" == "ACTIVE" ]] && (( ! gnocchi_cpu_ok || ! gnocchi_mem_ok )); then
                local diag_json
                diag_json=$(fetch_server_diagnostics "$sid")

                local diag_state
                diag_state=$(echo "$diag_json" | jq -r '.state // ""')

                if [[ "$diag_state" == "running" ]]; then
                    uptime_sec=$(echo "$diag_json" | jq '.uptime // 0')
                    local num_cpus
                    num_cpus=$(echo "$diag_json" | jq '.num_cpus // 1')

                    # CPU fallback: lifetime average
                    if (( ! gnocchi_cpu_ok )); then
                        local total_cpu_ns
                        total_cpu_ns=$(echo "$diag_json" | jq \
                            '[.cpu_details[]?.time // 0] | add // 0')
                        if (( uptime_sec > 0 && num_cpus > 0 )); then
                            cpu_pct=$(awk "BEGIN { printf \"%.1f\", ($total_cpu_ns / ($uptime_sec * $num_cpus * 1000000000)) * 100 }")
                        fi
                    fi

                    # Memory fallback: balloon-reported
                    if (( ! gnocchi_mem_ok )); then
                        local mem_max mem_used
                        mem_max=$(echo "$diag_json" | jq '.memory_details.maximum // 0')
                        mem_used=$(echo "$diag_json" | jq '.memory_details.used // 0')
                        if (( mem_max > 0 )); then
                            ram_used_mib="$mem_used"
                            ram_pct=$(awk "BEGIN { printf \"%.0f\", ($mem_used / $mem_max) * 100 }")
                            if (( mem_used >= mem_max )); then
                                ram_reliable="false"
                            else
                                ram_reliable="true"
                            fi
                        fi
                    fi
                fi
            fi
        fi

        # --- Guest agent data ---
        local agent_status="null" fs_root_pct="null"
        local load_1m="null" load_5m="null" load_15m="null"
        local fs_details_json="[]"

        if (( ! NO_AGENT )) && (( JUJU_AVAILABLE )) && [[ "$sstatus" == "ACTIVE" ]]; then
            local unit="${NOVA_HOST_TO_UNIT[${server_host}]:-}"
            if [[ -n "$unit" && -n "$instance_name" ]]; then
                # Check agent presence
                local _agent_rc=0
                guest_agent_ping "$unit" "$instance_name" 2>/dev/null || _agent_rc=$?
                if (( _agent_rc == 0 )); then
                    agent_status="\"yes\""

                    # Filesystem info
                    local fsinfo_raw
                    fsinfo_raw=$(guest_agent_fsinfo "$unit" "$instance_name" 2>/dev/null) || true
                    if [[ -n "$fsinfo_raw" ]]; then
                        fs_details_json=$(parse_fsinfo "$fsinfo_raw")

                        # Extract root filesystem usage percentage
                        fs_root_pct=$(echo "$fs_details_json" | jq '
                            [.[] | select(.mountpoint == "/")] |
                            if length > 0 then
                                (.[0].used_bytes / .[0].total_bytes * 100) |
                                floor
                            else
                                null
                            end' 2>/dev/null) || fs_root_pct="null"
                    fi

                    # Load averages (QEMU 8.x+, may not be available)
                    local load_raw
                    load_raw=$(guest_agent_load "$unit" "$instance_name" 2>/dev/null) || true
                    if [[ -n "$load_raw" ]]; then
                        local load_return
                        load_return=$(echo "$load_raw" | jq -r '.return // ""' 2>/dev/null) || true
                        if [[ -n "$load_return" && "$load_return" != "null" ]]; then
                            # guest-get-load returns "0.01 0.02 0.00" or similar
                            load_1m=$(echo "$load_return" | awk '{print $1}')
                            load_5m=$(echo "$load_return" | awk '{print $2}')
                            load_15m=$(echo "$load_return" | awk '{print $3}')
                            # Validate they are numeric
                            [[ "$load_1m" =~ ^[0-9.]+$ ]] || load_1m="null"
                            [[ "$load_5m" =~ ^[0-9.]+$ ]] || load_5m="null"
                            [[ "$load_15m" =~ ^[0-9.]+$ ]] || load_15m="null"
                        fi
                    fi
                else
                    agent_status="\"no\""
                fi
            else
                agent_status="null"
            fi
        elif [[ "$sstatus" != "ACTIVE" ]]; then
            agent_status="null"
        fi

        # Emit JSON record
        local name_json
        name_json=$(printf '%s' "$sname" | jq -Rs .)

        # Build the fs_details as a proper JSON string
        local fs_json_escaped
        fs_json_escaped=$(printf '%s' "$fs_details_json" | jq -c '.')

        printf '{"name":%s,"id":"%s","status":"%s","vcpus":%d,"ram":%d,"disk":%d,"vdisk":%d,"cpu_pct":%s,"ram_pct":%s,"ram_used_mib":%s,"ram_reliable":%s,"uptime":%s,"agent":%s,"rbd_used_gib":%s,"fs_root_pct":%s,"load_1m":%s,"load_5m":%s,"load_15m":%s,"fs_details":%s}\n' \
            "$name_json" "$sid" "$sstatus" "$vcpus" "$ram" "$disk" "$vol_total" \
            "$cpu_pct" "$ram_pct" "$ram_used_mib" "$ram_reliable" "$uptime_sec" \
            "$agent_status" "$rbd_used_gib" "$fs_root_pct" \
            "$load_1m" "$load_5m" "$load_15m" "$fs_json_escaped"
    done < <(echo "$servers_json" | jq -c '.[]')

    # Clear progress line
    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        printf "\r%-80s\r" "" >&2
    fi
    set -e
}

# Pre-fetch Ceph pools for all volumes in a project's servers
prefetch_ceph_pools() {
    local project_id="$1" servers_json="$2"
    local pools_needed=()

    # Collect all volume IDs across all servers
    local all_vol_ids
    mapfile -t all_vol_ids < <(echo "$servers_json" | jq -r '
        .[].ID' 2>/dev/null)

    local sid
    for sid in "${all_vol_ids[@]}"; do
        [[ -z "$sid" ]] && continue
        local server_vols
        server_vols=$(openstack server show "$sid" -f json 2>/dev/null \
            | jq -r 'if (.volumes_attached | type) == "array" then
                .volumes_attached[].id else empty end' 2>/dev/null) || continue

        local vid
        while IFS= read -r vid; do
            [[ -z "$vid" ]] && continue
            local vol_json vol_host
            vol_json=$(fetch_volume_details "$vid")
            vol_host=$(echo "$vol_json" | jq -r '.["os-vol-host-attr:host"] // ""')
            if [[ -n "$vol_host" && "$vol_host" != "null" ]]; then
                local pool
                pool=$(resolve_ceph_pool "$vol_host")
                if [[ -n "$pool" && -z "${CEPH_POOLS_FETCHED[$pool]+x}" ]]; then
                    pools_needed+=("$pool")
                fi
            fi
        done <<< "$server_vols"
    done

    # Deduplicate and fetch each pool
    local seen_pool
    declare -A seen_pool=()
    local p
    for p in "${pools_needed[@]}"; do
        [[ -n "${seen_pool[$p]+x}" ]] && continue
        seen_pool["$p"]=1
        msg "Fetching Ceph RBD data for pool: ${p}"
        fetch_ceph_pool_rbd "$p"
    done
}

# --- Output formatting --------------------------------------------------------

format_table_header() {
    local sep
    sep=$(printf '%*s' 130 '' | tr ' ' '-')
    printf "  %-20s %-8s %5s %5s %7s %5s %5s %5s %8s %7s %4s  %s\n" \
        "VM Name" "Status" "Agent" "vCPU" "RAM(M)" "RAM%" "CPU%" "Load" "vDisk(G)" "RBD(G)" "FS%" "Uptime"
    echo "  ${sep}"
}

format_table_row() {
    local json="$1"
    local name status vcpus ram vdisk cpu_pct ram_pct uptime
    local agent rbd_used_gib fs_root_pct load_1m

    name=$(echo "$json" | jq -r '.name // ""')
    [[ -z "$name" ]] && name=$(echo "$json" | jq -r '.id')
    status=$(echo "$json" | jq -r '.status')
    vcpus=$(echo "$json" | jq '.vcpus')
    ram=$(echo "$json" | jq '.ram')
    vdisk=$(echo "$json" | jq '.vdisk')
    cpu_pct=$(echo "$json" | jq -r '.cpu_pct')
    ram_pct=$(echo "$json" | jq -r '.ram_pct')
    local ram_reliable
    ram_reliable=$(echo "$json" | jq -r '.ram_reliable')
    uptime=$(echo "$json" | jq -r '.uptime')
    agent=$(echo "$json" | jq -r '.agent')
    rbd_used_gib=$(echo "$json" | jq -r '.rbd_used_gib')
    fs_root_pct=$(echo "$json" | jq -r '.fs_root_pct')
    load_1m=$(echo "$json" | jq -r '.load_1m')

    # Format strings
    local cpu_str ram_str uptime_str agent_str rbd_str fs_str load_str

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

    if [[ "$agent" == "yes" ]]; then
        agent_str="yes"
    elif [[ "$agent" == "no" ]]; then
        agent_str="no"
    else
        agent_str="—"
    fi

    if [[ "$rbd_used_gib" == "null" ]]; then
        rbd_str="—"
    else
        rbd_str="$rbd_used_gib"
    fi

    if [[ "$fs_root_pct" == "null" ]]; then
        fs_str="—"
    else
        fs_str="${fs_root_pct}%"
    fi

    if [[ "$load_1m" == "null" ]]; then
        load_str="—"
    else
        load_str="$load_1m"
    fi

    # Line 1: main metrics
    printf "  %-20s %-8s %5s %5d %7d %5s %5s %5s %8d %7s %4s  %s\n" \
        "${name:0:20}" "$status" "$agent_str" "$vcpus" "$ram" \
        "$ram_str" "$cpu_str" "$load_str" "$vdisk" \
        "$rbd_str" "$fs_str" "$uptime_str"

    # Line 2+: filesystem details (only if agent available)
    if [[ "$agent" == "yes" ]]; then
        local fs_details
        fs_details=$(echo "$json" | jq -c '.fs_details[]?' 2>/dev/null)
        while IFS= read -r fs_entry; do
            [[ -z "$fs_entry" ]] && continue
            local mp total_bytes used_bytes
            mp=$(echo "$fs_entry" | jq -r '.mountpoint')
            total_bytes=$(echo "$fs_entry" | jq '.total_bytes // 0')
            used_bytes=$(echo "$fs_entry" | jq '.used_bytes // 0')

            local total_h used_h pct_used
            total_h=$(awk "BEGIN { printf \"%.1fG\", $total_bytes / (1024*1024*1024) }")
            used_h=$(awk "BEGIN { printf \"%.1fG\", $used_bytes / (1024*1024*1024) }")
            if (( total_bytes > 0 )); then
                pct_used=$(awk "BEGIN { printf \"%d\", ($used_bytes / $total_bytes) * 100 }")
            else
                pct_used=0
            fi

            printf "  %-20s %9s %-14s %5s  used=%s (%d%%)\n" \
                "" "" "$mp" "$total_h" "$used_h" "$pct_used"
        done <<< "$fs_details"
    fi
}

format_table_totals() {
    local total_vms="$1" total_vcpus="$2" total_ram="$3" total_vdisk="$4"
    local sep
    sep=$(printf '%*s' 130 '' | tr ' ' '-')
    echo "  ${sep}"
    printf "  %-20s %-8s %5s %5d %7d %5s %5s %5s %8d\n" \
        "Totals (${total_vms} VMs)" "" "" "$total_vcpus" "$total_ram" \
        "" "" "" "$total_vdisk"
}

format_csv_header() {
    echo "project_id,project_name,vm_id,vm_name,status,agent,vcpus,ram_mib,disk_gib,vdisk_gib,cpu_pct,ram_pct,ram_used_mib,ram_reliable,uptime_sec,rbd_used_gib,fs_root_pct,load_1m,load_5m,load_15m"
}

format_csv_row() {
    local project_id="$1" project_name="$2" json="$3"
    echo "$json" | jq -r --arg pid "$project_id" --arg pname "$project_name" '
        [$pid, $pname, .id, .name, .status,
         (if .agent == null then "" else (.agent|tostring) end),
         (.vcpus|tostring), (.ram|tostring), (.disk|tostring), (.vdisk|tostring),
         (if .cpu_pct == null then "" else (.cpu_pct|tostring) end),
         (if .ram_pct == null then "" else (.ram_pct|tostring) end),
         (if .ram_used_mib == null then "" else (.ram_used_mib|tostring) end),
         (if .ram_reliable == null then "" else (.ram_reliable|tostring) end),
         (if .uptime == null then "" else (.uptime|tostring) end),
         (if .rbd_used_gib == null then "" else (.rbd_used_gib|tostring) end),
         (if .fs_root_pct == null then "" else (.fs_root_pct|tostring) end),
         (if .load_1m == null then "" else (.load_1m|tostring) end),
         (if .load_5m == null then "" else (.load_5m|tostring) end),
         (if .load_15m == null then "" else (.load_15m|tostring) end)
        ] | @csv'
}

# --- Report orchestration -----------------------------------------------------

report_project() {
    local project_id="$1" project_name="$2"
    local vm_records=()
    local total_vms=0 total_vcpus=0 total_ram=0 total_vdisk=0

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
        local v_vcpus v_ram v_vdisk
        v_vcpus=$(echo "$record" | jq '.vcpus')
        v_ram=$(echo "$record" | jq '.ram')
        v_vdisk=$(echo "$record" | jq '.vdisk')

        total_vcpus=$((total_vcpus + v_vcpus))
        total_ram=$((total_ram + v_ram))
        total_vdisk=$((total_vdisk + v_vdisk))

        case "$OUTPUT_FORMAT" in
            table) format_table_row "$record" ;;
            csv)   format_csv_row "$project_id" "$project_name" "$record" ;;
            json)  echo "$record" | jq -c --arg pid "$project_id" --arg pname "$project_name" \
                       '. + {project_id: $pid, project_name: $pname} | del(.fs_details)' ;;
        esac
    done

    if [[ "$OUTPUT_FORMAT" == "table" ]]; then
        format_table_totals "$total_vms" "$total_vcpus" "$total_ram" "$total_vdisk"
    fi
}

# --- Argument parsing ---------------------------------------------------------

OPTIONS=$(getopt -o hvp:f:n \
    --long help,version,project:,format:,no-diagnostics,no-ceph,no-agent,dry-run \
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
        --no-diagnostics)
            NO_DIAGNOSTICS=1
            shift
            ;;
        --no-ceph)
            NO_CEPH=1
            shift
            ;;
        --no-agent)
            NO_AGENT=1
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

# No validation needed — default (no args) reports all domains

# --- Main execution -----------------------------------------------------------

check_deps

if (( DRY_RUN )); then
    msg "Dry run — would query:"
    if [[ -n "$PROJECT_FILTER" ]]; then
        echo "  Scope: project ${PROJECT_FILTER}" >&2
    elif [[ -n "$DOMAIN_FILTER" ]]; then
        echo "  Scope: domain ${DOMAIN_FILTER} (all projects)" >&2
    else
        echo "  Scope: all domains and projects" >&2
    fi
    echo "  Diagnostics: $(( ! NO_DIAGNOSTICS ? 1 : 0 ))" >&2
    echo "  Ceph RBD:    $(( ! NO_CEPH ? 1 : 0 ))" >&2
    echo "  Agent:       $(( ! NO_AGENT ? 1 : 0 ))" >&2
    echo "  Format: ${OUTPUT_FORMAT}" >&2
    exit 0
fi

# Check for juju availability (needed for Ceph and agent features)
if (( ! NO_CEPH )) || (( ! NO_AGENT )); then
    check_juju
fi

# Build nova-compute host-to-unit map (once, at startup)
if (( ! NO_AGENT )) && (( JUJU_AVAILABLE )); then
    build_nova_host_map
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

else
    # Default: iterate all accessible domains and their projects
    msg "Fetching accessible domains"
    DOMAINS_JSON=$(openstack domain list -f json 2>/dev/null || echo '[]')
    DOM_COUNT=$(echo "$DOMAINS_JSON" | jq 'length')
    ok "Found ${DOM_COUNT} domain(s)"

    if (( DOM_COUNT == 0 )); then
        warn "No accessible domains."
    else
        DIDX=0
        while IFS= read -r dline; do
            (( DIDX++ )) || true
            DOM_ID=$(echo "$dline" | jq -r '.ID')
            DOM_NAME=$(echo "$dline" | jq -r '.Name')

            PROJECTS_JSON=$(openstack project list --domain "$DOM_NAME" -f json 2>/dev/null || echo '[]')
            PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')

            if (( PROJ_COUNT == 0 )); then
                continue
            fi

            if [[ "$OUTPUT_FORMAT" == "table" ]]; then
                echo "" >&2
                msg "Domain: ${DOM_NAME} (${PROJ_COUNT} project(s))"
            fi

            PIDX=0
            while IFS= read -r pline; do
                (( PIDX++ )) || true
                PID_CUR=$(echo "$pline" | jq -r '.ID')
                PNAME_CUR=$(echo "$pline" | jq -r '.Name')
                msg "[${DIDX}/${DOM_COUNT}] ${DOM_NAME} / ${PNAME_CUR}"
                run_report_for_project "$PID_CUR" "$PNAME_CUR"
            done < <(echo "$PROJECTS_JSON" | jq -c '.[]')
        done < <(echo "$DOMAINS_JSON" | jq -c '.[]')
    fi
fi

# Close JSON array
if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "]"
fi

# Legend for table mode
if [[ "$OUTPUT_FORMAT" == "table" ]]; then
    echo ""
    echo -e "  ${C_DIM}Legend: CPU%  = recent 5min avg (Gnocchi) or lifetime avg (Nova diagnostics)${C_RESET}"
    echo -e "  ${C_DIM}        RAM%  = Gnocchi memory.usage or balloon-reported (~ = no balloon)${C_RESET}"
    echo -e "  ${C_DIM}        RBD   = actual Ceph storage used (from rbd du)${C_RESET}"
    echo -e "  ${C_DIM}        FS%   = root filesystem usage from guest agent${C_RESET}"
    echo -e "  ${C_DIM}        Load  = 1-minute load average from guest agent${C_RESET}"
    echo -e "  ${C_DIM}        Agent = yes (responding) / no (not responding) / — (N/A)${C_RESET}"
    echo -e "  ${C_DIM}        —     = not available${C_RESET}"
    echo ""
fi
