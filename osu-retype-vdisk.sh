#!/usr/bin/env bash

# Script Name: osu-retype-vdisk.sh
# Description: Retype (migrate) OpenStack volumes between Ceph pools via
#              volume type changes. Provides both an interactive wizard and
#              a one-shot CLI mode with pre-flight checks, volume/type
#              listing, and migration progress monitoring.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-27
# Version: 0.2.0
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Changelog:
#   - 2026-03-27: v0.2.0 - Add --handle-vm-state (start-stop, detach-reattach) to
#                          resolve stopped-VM retype blocker automatically. Supports
#                          interactive prompt and one-shot CLI mode. Detach-reattach
#                          preserves original device path; blocked for boot disks.
#   - 2026-03-27: v0.1.4 - Add pre-flight check for stopped VMs with cross-backend
#                          retypes. Nova refuses swap_volume on stopped instances
#                          (HTTP 409), so the script now detects this early and
#                          advises starting the instance or detaching the volume.
#   - 2026-03-27: v0.1.3 - Fix monitor infinite loop on instant same-backend
#                          retype where Cinder changes type without migration
#                          (migration_status stays none). Monitor now detects
#                          target type match and declares success immediately.
#   - 2026-03-27: v0.1.2 - Fix monitor infinite loop when Cinder fails retype
#                          instantly (pre-retype migration_status now captured
#                          before execute_retype to avoid race condition).
#   - 2026-03-27: v0.1.1 - Fix monitor reacting to stale migration_status=error
#                          from previous attempts. Add migration_status check
#                          to pre-flight. Fix empty volume name display. Add
#                          --handle-snapshots (delete, backup-delete) to resolve
#                          snapshot blockers automatically.
#   - 2026-03-27: v0.1   - Initial release. Interactive wizard and one-shot
#                          retype modes, volume listing with server filtering,
#                          volume type listing, pre-flight checks (state
#                          validation, snapshot detection), interactive volume
#                          selection, and migration progress monitoring.

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.2.0"

# Operational defaults
MODE=""
DRY_RUN=0
AUTO_YES=0
NO_MONITOR=0
OUTPUT_FORMAT="table"
SERVER_FILTER=""
POLL_INTERVAL=10
POLL_TIMEOUT=3600
RETYPE_FLAG=""
TARGET_TYPE_ARG=""
HANDLE_SNAPSHOTS=""
BACKUP_CONTAINER=""
HANDLE_VM_STATE=""
declare -a RETYPE_VOLUMES=()

# Counters
RETYPE_OK=0
RETYPE_FAIL=0
RETYPE_SKIP=0

# Caches
declare -A SERVER_NAME_CACHE=()
declare -A SERVER_STATE_CACHE=()
VOLUME_TYPES_JSON=""

# Resolved server state (populated by resolve_server)
RESOLVED_SERVER_ID=""
RESOLVED_SERVER_NAME=""
RESOLVED_SERVER_STATUS=""
declare -a RESOLVED_VOL_IDS=()

# Interactive selection result
declare -a SELECTED_VOL_IDS=()

# Snapshot cleanup tracking
declare -a NEEDS_SNAP_DELETE=()
declare -A VOL_SNAP_COUNT=()

# VM state handling tracking
declare -a NEEDS_VM_HANDLE=()
declare -A VOL_VM_INFO=()    # vol_id -> "server_id|device|vm_state|bootable"

# --- Colors (disabled when stderr is not a terminal) --------------------------
if [[ -t 2 ]]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_BOLD='' C_RESET=''
fi

# --- Helpers ------------------------------------------------------------------
msg()  { echo -e "${C_BOLD}${C_CYAN}::${C_RESET} $*" >&2; }
ok()   { echo -e "   ${C_GREEN}[+]${C_RESET} $*" >&2; }
warn() { echo -e "   ${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()  { echo -e "   ${C_RED}[-]${C_RESET} $*" >&2; }

elapsed_human() {
    local secs="$1"
    if (( secs >= 3600 )); then
        printf '%dh %dm %ds' $((secs / 3600)) $(( (secs % 3600) / 60 )) $((secs % 60))
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

cleanup() {
    :
}
trap cleanup EXIT

run() {
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} $*" >&2
    else
        "$@"
    fi
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [MODE] [OPTIONS] [ARGS]

Version: $SCRIPT_VERSION

Description:
  Retype (migrate) OpenStack volumes between Ceph pools by changing the
  volume type. Provides an interactive wizard and a one-shot CLI mode with
  pre-flight validation and migration progress monitoring.

  The retype operation triggers a backend-assisted data copy between Ceph
  pools. It works on both attached (in-use) and detached (available) volumes.

Modes:
  -i, --interactive     Guided wizard: discover volumes, pick target type,
                        execute retype with monitoring (default on TTY)
  -l, --list            List volumes (optionally filtered by --server)
  -t, --types           List available volume types (retype targets)
  -m, --monitor VOL_ID  Monitor an in-progress migration

One-shot retype:
  -r, --retype VOL_ID   Volume to retype (repeatable, or comma-separated)
  -T, --type TYPE        Target volume type (required for one-shot retype)
  -s, --server NAME|ID   Discover volumes from a server (instead of -r)

  Use -r to specify volumes explicitly, or -s to discover them from a
  server. Combine either with -T to set the destination type.

Snapshot handling:
      --handle-snapshots MODE  How to handle snapshots blocking retype:
                               delete         Delete all snapshots
                               backup-delete  Backup each snapshot then delete
      --backup-container NAME  Target container for snapshot backups
                               (required with backup-delete in one-shot mode;
                               prompted interactively in wizard mode)

Stopped VM handling:
      --handle-vm-state MODE   How to handle volumes on stopped VMs:
                               start-stop       Start VM, retype, stop VM
                               detach-reattach  Detach, retype, reattach
                               (start-stop works for all volumes including boot
                               disks; detach-reattach only for non-root data
                               volumes — root devices cannot be detached)

Options:
  -f, --format FMT      Output format: table (default), csv, json
  -y, --yes             Skip confirmation prompts (selects all with --server)
  -n, --dry-run         Show what would be done without making changes
      --no-monitor      Skip automatic progress monitoring after retype
      --interval SEC    Polling interval in seconds (default: ${POLL_INTERVAL})
      --timeout SEC     Maximum wait time in seconds (default: ${POLL_TIMEOUT})
  -h, --help            Show this help message
  -v, --version         Show version

Pre-flight checks (automatic):
  - Volume exists and is accessible
  - Volume is in a valid state (in-use or available)
  - Volume has no snapshots (see --handle-snapshots)
  - Target type exists and differs from current type
  - In-use volumes on stopped VMs cannot retype across backends
    (see --handle-vm-state)

Requirements:
  - openstack CLI (python-openstackclient) with valid credentials
  - jq

Examples:
  # Interactive wizard
  $0 -i

  # One-shot retype (explicit volumes)
  $0 -r VOL_ID -T ssd-pool
  $0 -r VOL1 -r VOL2 -T ssd-pool
  $0 -r VOL1,VOL2 -T ssd-pool

  # One-shot retype (server volume discovery)
  $0 -s myvm -T ssd-pool
  $0 -s myvm -T ssd-pool -y          Select all, skip confirmation

  # Dry run
  $0 -r VOL_ID -T ssd-pool -n

  # Handle snapshots blocking retype
  $0 -r VOL_ID -T ssd-pool --handle-snapshots delete
  $0 -r VOL_ID -T ssd-pool --handle-snapshots backup-delete --backup-container my-backups

  # Handle volumes on stopped VMs
  $0 -r VOL_ID -T ssd-pool --handle-vm-state start-stop
  $0 -r VOL_ID -T ssd-pool --handle-vm-state detach-reattach

  # Listing
  $0 -l                               List all volumes
  $0 -l -s myvm                       List volumes attached to a VM
  $0 -l -f json                       List volumes as JSON
  $0 -t                               List available volume types

  # Monitoring
  $0 -m VOL_ID                        Monitor an in-progress migration
  $0 -m VOL_ID --interval 5           Monitor with 5s polling
EOF
}

# --- Pre-flight functions -----------------------------------------------------

check_deps() {
    local missing=()
    for cmd in openstack jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_auth() {
    local token_json
    if ! token_json=$(openstack token issue -f json 2>&1); then
        err "OpenStack authentication failed."
        err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
        exit 1
    fi
    local project_id
    project_id=$(echo "$token_json" | jq -r '.project_id // "unknown"')
    ok "Authenticated (project: ${project_id})"
}

detect_retype_flag() {
    local help_text
    help_text=$(openstack volume set --help 2>&1 || true)
    if echo "$help_text" | grep -q -- '--retype-policy'; then
        RETYPE_FLAG="--retype-policy"
    elif echo "$help_text" | grep -q -- '--migration-policy'; then
        RETYPE_FLAG="--migration-policy"
    else
        err "Cannot determine retype policy flag."
        err "Your OpenStack CLI may not support volume retype via 'volume set'."
        exit 1
    fi
}

# --- Data retrieval functions -------------------------------------------------

resolve_server() {
    local server="$1"
    local sjson
    if ! sjson=$(openstack server show "$server" -f json 2>&1); then
        err "Server '${server}' not found or not accessible."
        exit 1
    fi

    RESOLVED_SERVER_ID=$(echo "$sjson" | jq -r '.id // empty')
    RESOLVED_SERVER_NAME=$(echo "$sjson" | jq -r '.name // empty')
    RESOLVED_SERVER_STATUS=$(echo "$sjson" | jq -r '.status // "unknown"')

    # Extract volume IDs — handle both array-of-objects and string formats
    local va_type
    va_type=$(echo "$sjson" | jq -r '.volumes_attached | type')

    RESOLVED_VOL_IDS=()
    if [[ "$va_type" == "array" ]]; then
        mapfile -t RESOLVED_VOL_IDS < <(
            echo "$sjson" | jq -r '.volumes_attached[].id // empty'
        )
    else
        # Fall back to string parsing: id='xxx'
        local va_str
        va_str=$(echo "$sjson" | jq -r '.volumes_attached // ""')
        if [[ -n "$va_str" && "$va_str" != "null" && "$va_str" != "[]" ]]; then
            mapfile -t RESOLVED_VOL_IDS < <(
                echo "$va_str" | grep -oP "id='[^']*'" | sed "s/id='//;s/'//"
            )
        fi
    fi

    if (( ${#RESOLVED_VOL_IDS[@]} == 0 )); then
        warn "Server '${RESOLVED_SERVER_NAME}' has no attached volumes."
    fi
}

fetch_volume_detail() {
    local vol_id="$1"
    openstack volume show "$vol_id" -f json 2>/dev/null || echo '{}'
}

ensure_volume_types() {
    if [[ -z "$VOLUME_TYPES_JSON" ]]; then
        VOLUME_TYPES_JSON=$(openstack volume type list -f json 2>/dev/null || echo '[]')
    fi
}

resolve_volume_type() {
    local target="$1"
    ensure_volume_types

    local match
    match=$(echo "$VOLUME_TYPES_JSON" | jq -r --arg t "$target" \
        '.[] | select(.Name == $t or .ID == $t) | .Name' | head -1)

    if [[ -z "$match" ]]; then
        err "Volume type '${target}' not found."
        err "Use '$0 -t' to list available types."
        return 1
    fi
    echo "$match"
}

# Check if retyping between two types requires cross-backend data migration.
# Returns 0 (true) if backends differ, 1 (false) if same or indeterminate.
requires_backend_migration() {
    local from_type="$1" to_type="$2"

    # Fetch extra specs (properties) for both types
    local from_backend to_backend
    from_backend=$(openstack volume type show "$from_type" -f json 2>/dev/null \
        | jq -r '.properties.volume_backend_name // ""')
    to_backend=$(openstack volume type show "$to_type" -f json 2>/dev/null \
        | jq -r '.properties.volume_backend_name // ""')

    # If either is empty (like __DEFAULT__), we can't be sure — assume possible
    if [[ -z "$from_backend" || -z "$to_backend" ]]; then
        return 0
    fi

    [[ "$from_backend" != "$to_backend" ]]
}

# Get the VM status for a volume's first attachment.
# Prints the vm_state (active, stopped, etc.) or empty if not attached.
get_attached_server_state() {
    local vjson="$1"
    local server_id
    server_id=$(echo "$vjson" | jq -r '
        if (.attachments | type) == "array" and (.attachments | length) > 0 then
            .attachments[0].server_id
        else
            ""
        end')

    if [[ -z "$server_id" ]]; then
        echo ""
        return
    fi

    # Use cache if available
    if [[ -n "${SERVER_STATE_CACHE[$server_id]:-}" ]]; then
        echo "${SERVER_STATE_CACHE[$server_id]}"
        return
    fi

    local sjson vm_state
    sjson=$(openstack server show "$server_id" -f json 2>/dev/null || echo '{}')
    vm_state=$(echo "$sjson" | jq -r '."OS-EXT-STS:vm_state" // .status // ""' | tr '[:upper:]' '[:lower:]')
    SERVER_STATE_CACHE["$server_id"]="$vm_state"
    echo "$vm_state"
}

fetch_volume_snapshots() {
    local vol_id="$1"
    openstack volume snapshot list --volume "$vol_id" -f json 2>/dev/null || echo '[]'
}

# --- Formatting functions -----------------------------------------------------

format_volumes_table() {
    local json="$1"
    local count
    count=$(echo "$json" | jq 'length')

    if [[ -n "$SERVER_FILTER" && -n "$RESOLVED_SERVER_NAME" ]]; then
        msg "Server: ${RESOLVED_SERVER_NAME} (${RESOLVED_SERVER_ID})  Status: ${RESOLVED_SERVER_STATUS}"
        echo "" >&2
    fi

    local sep
    sep=$(printf '%*s' 112 '' | tr ' ' '-')

    printf "  %-4s %-36s  %-22s  %-10s  %5s  %-18s  %s\n" \
        "#" "ID" "Name" "Status" "Size" "Type" "Attached"
    echo "  ${sep}"

    local idx=0
    while IFS= read -r line; do
        (( idx++ )) || true
        local vid vname vstatus vsize vtype vattach

        vid=$(echo "$line" | jq -r '.id // .ID // "—"')
        vname=$(echo "$line" | jq -r '.name // .Name // "—"')
        vstatus=$(echo "$line" | jq -r '.status // .Status // "—"')
        vsize=$(echo "$line" | jq -r '.size // .Size // 0')
        vtype=$(echo "$line" | jq -r '.type // .volume_type // ."Volume Type" // "—"')

        if [[ -n "$SERVER_FILTER" ]]; then
            vattach=$(echo "$line" | jq -r '
                if (.attachments | type) == "array" and (.attachments | length) > 0 then
                    .attachments[0].device // "—"
                else
                    "—"
                end')
        else
            vattach=$(echo "$line" | jq -r '
                if (."Attached to" // "") != "" then
                    ."Attached to"
                elif (.attachments | type) == "array" and (.attachments | length) > 0 then
                    (.attachments[0].server_id // "?")[0:13] + " " + (.attachments[0].device // "")
                else
                    "—"
                end')
        fi

        printf "  %-4s %-36s  %-22s  %-10s  %4dG  %-18s  %s\n" \
            "${idx}" "$vid" "${vname:0:22}" "$vstatus" "$vsize" "${vtype:0:18}" "${vattach:0:36}"
    done < <(echo "$json" | jq -c '.[]')

    echo "  ${sep}"
    echo "  Total: ${count} volume(s)"
}

format_volumes_csv() {
    local json="$1"
    echo "ID,Name,Status,Size,Type,Attached"
    echo "$json" | jq -r '.[] |
        [
            (.id // .ID // ""),
            (.name // .Name // ""),
            (.status // .Status // ""),
            (.size // .Size // 0 | tostring),
            (.type // .volume_type // ."Volume Type" // ""),
            (if (."Attached to" // "") != "" then
                ."Attached to"
            elif (.attachments | type) == "array" and (.attachments | length) > 0 then
                .attachments[0].server_id + " " + (.attachments[0].device // "")
            else
                ""
            end)
        ] | @csv'
}

format_volumes_json() {
    local json="$1"
    echo "$json" | jq '.'
}

format_types_table() {
    local json="$1"
    local count
    count=$(echo "$json" | jq 'length')

    local sep
    sep=$(printf '%*s' 95 '' | tr ' ' '-')

    printf "  %-4s %-36s  %-24s  %-10s  %s\n" "#" "ID" "Name" "Public" "Description"
    echo "  ${sep}"

    local idx=0
    while IFS= read -r line; do
        (( idx++ )) || true
        local tid tname tdesc tpub
        tid=$(echo "$line" | jq -r '.ID // "—"')
        tname=$(echo "$line" | jq -r '.Name // "—"')
        tdesc=$(echo "$line" | jq -r '.Description // "—"')
        tpub=$(echo "$line" | jq -r '."Is Public" // "—"')
        printf "  %-4s %-36s  %-24s  %-10s  %s\n" \
            "${idx}" "$tid" "${tname:0:24}" "$tpub" "${tdesc:0:40}"
    done < <(echo "$json" | jq -c '.[]')

    echo "  ${sep}"
    echo "  Total: ${count} type(s)"
}

format_types_csv() {
    local json="$1"
    echo "ID,Name,Is Public,Description"
    echo "$json" | jq -r '.[] |
        [.ID, .Name, (."Is Public" | tostring), (.Description // "")] | @csv'
}

format_types_json() {
    local json="$1"
    echo "$json" | jq '.'
}

# --- Core operation functions -------------------------------------------------

list_volumes() {
    local volumes_json

    if [[ -n "$SERVER_FILTER" ]]; then
        resolve_server "$SERVER_FILTER"
        if (( ${#RESOLVED_VOL_IDS[@]} == 0 )); then
            return 0
        fi

        # Fetch details for each volume
        volumes_json="["
        local first=1 vid vjson
        for vid in "${RESOLVED_VOL_IDS[@]}"; do
            (( first )) || volumes_json+=","
            first=0
            vjson=$(fetch_volume_detail "$vid")
            volumes_json+="$vjson"
        done
        volumes_json+="]"
    else
        volumes_json=$(openstack volume list -f json 2>/dev/null || echo '[]')

        # Check if type info is present; retry with --long if missing
        local has_type
        has_type=$(echo "$volumes_json" | jq '
            if length > 0 then
                (.[0] | has("Volume Type") or has("type") or has("volume_type"))
            else
                true
            end')

        if [[ "$has_type" == "false" ]]; then
            volumes_json=$(openstack volume list --long -f json 2>/dev/null || echo '[]')
        fi
    fi

    case "$OUTPUT_FORMAT" in
        table) format_volumes_table "$volumes_json" ;;
        csv)   format_volumes_csv "$volumes_json" ;;
        json)  format_volumes_json "$volumes_json" ;;
    esac
}

list_types() {
    ensure_volume_types

    case "$OUTPUT_FORMAT" in
        table) format_types_table "$VOLUME_TYPES_JSON" ;;
        csv)   format_types_csv "$VOLUME_TYPES_JSON" ;;
        json)  format_types_json "$VOLUME_TYPES_JSON" ;;
    esac
}

preflight_retype() {
    local vol_id="$1" target_type="$2"
    local vjson status vol_type snap_json snap_count

    vjson=$(fetch_volume_detail "$vol_id")
    if [[ "$vjson" == "{}" || -z "$vjson" ]]; then
        err "Volume '${vol_id}' not found or not accessible."
        return 1
    fi

    local vol_name migration_status
    vol_name=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id else .name end')
    status=$(echo "$vjson" | jq -r '.status // "unknown"')
    vol_type=$(echo "$vjson" | jq -r '.type // .volume_type // "unknown"')
    migration_status=$(echo "$vjson" | jq -r '.migration_status // "none"')

    # Check valid state
    if [[ "$status" != "in-use" && "$status" != "available" ]]; then
        err "Volume '${vol_name}' is in state '${status}' (must be 'in-use' or 'available')."
        return 1
    fi

    # Check migration state
    if [[ "$migration_status" == "migrating" ]]; then
        err "Volume '${vol_name}' is already migrating. Use -m to monitor it."
        return 1
    fi
    if [[ "$migration_status" == "error" ]]; then
        warn "Volume '${vol_name}' has a stale migration_status=error from a previous attempt."
    fi

    # Check snapshots
    snap_json=$(fetch_volume_snapshots "$vol_id")
    snap_count=$(echo "$snap_json" | jq 'length')
    if (( snap_count > 0 )); then
        if [[ -n "$HANDLE_SNAPSHOTS" ]]; then
            warn "Volume '${vol_name}' has ${snap_count} snapshot(s) — will ${HANDLE_SNAPSHOTS}"
            VOL_SNAP_COUNT["$vol_id"]=$snap_count
            return 3
        fi
        err "Volume '${vol_name}' has ${snap_count} snapshot(s). Remove snapshots before retype."
        err "Hint: use --handle-snapshots delete or --handle-snapshots backup-delete"
        return 1
    fi

    # Check target differs from current
    if [[ "$vol_type" == "$target_type" ]]; then
        warn "Volume '${vol_name}' is already type '${vol_type}'. Skipping."
        return 2
    fi

    # Check for SHUTOFF VM with cross-backend retype (Nova cannot swap_volume
    # on a stopped instance, so cross-pool retypes will always fail)
    if [[ "$status" == "in-use" ]]; then
        local vm_state
        vm_state=$(get_attached_server_state "$vjson")
        if [[ "$vm_state" == "stopped" ]] && requires_backend_migration "$vol_type" "$target_type"; then
            local server_id device bootable
            server_id=$(echo "$vjson" | jq -r '.attachments[0].server_id // "unknown"')
            device=$(echo "$vjson" | jq -r '.attachments[0].device // ""')
            bootable=$(echo "$vjson" | jq -r '.bootable // "false"')

            if [[ -n "$HANDLE_VM_STATE" ]]; then
                # Validate detach-reattach is not used on boot volumes
                if [[ "$HANDLE_VM_STATE" == "detach-reattach" && "$bootable" == "true" ]]; then
                    err "Volume '${vol_name}' is a boot disk — cannot use detach-reattach."
                    err "Use --handle-vm-state start-stop for root volumes."
                    return 1
                fi
                warn "Volume '${vol_name}' is on stopped VM (${server_id:0:13}...) — will ${HANDLE_VM_STATE}"
                VOL_VM_INFO["$vol_id"]="${server_id}|${device}|${vm_state}|${bootable}"
                return 4
            fi
            err "Volume '${vol_name}' is attached to a stopped instance (${server_id})."
            err "Nova cannot swap volumes on stopped VMs. Start the instance first,"
            err "or detach the volume before retyping across backends."
            err "Hint: use --handle-vm-state start-stop or --handle-vm-state detach-reattach"
            return 1
        fi
    fi

    ok "Pre-flight passed: ${vol_name} (${vol_type} → ${target_type})"
    return 0
}

execute_retype() {
    local vol_id="$1" target_type="$2"
    run openstack volume set --type "$target_type" "$RETYPE_FLAG" on-demand "$vol_id"
}

# --- Snapshot handling functions -----------------------------------------------

delete_volume_snapshots() {
    local vol_id="$1"
    local snap_json
    snap_json=$(fetch_volume_snapshots "$vol_id")

    local snap_id snap_status
    while IFS= read -r line; do
        snap_id=$(echo "$line" | jq -r '.ID // .id')
        snap_status=$(echo "$line" | jq -r '.Status // .status // "unknown"')

        if [[ "$snap_status" == "deleting" ]]; then
            ok "Snapshot ${snap_id:0:13}... already deleting"
            continue
        fi
        if [[ "$snap_status" == "error_deleting" || "$snap_status" == "error" ]]; then
            err "Snapshot ${snap_id:0:13}... is in '${snap_status}' state"
            return 1
        fi
        run openstack volume snapshot delete "$snap_id"
        (( DRY_RUN )) || ok "Deleted snapshot ${snap_id:0:13}..."
    done < <(echo "$snap_json" | jq -c '.[]')
}

backup_volume_snapshots() {
    local vol_id="$1" container="$2"
    local snap_json
    snap_json=$(fetch_volume_snapshots "$vol_id")

    local snap_id snap_name backup_name
    while IFS= read -r line; do
        snap_id=$(echo "$line" | jq -r '.ID // .id')
        snap_name=$(echo "$line" | jq -r '.Name // .name // "unnamed"')
        backup_name="snap-backup-${snap_name}-$(date +%Y%m%d%H%M%S)"

        msg "Backing up snapshot ${snap_name} (${snap_id:0:13}...)..."
        if ! run openstack volume backup create \
                --container "$container" \
                --snapshot "$snap_id" \
                --name "$backup_name" \
                "$vol_id"; then
            err "Backup failed for snapshot ${snap_id:0:13}..."
            return 1
        fi

        if (( ! DRY_RUN )); then
            ok "Backup created: ${backup_name}"
            if ! wait_backup_ready "$backup_name"; then
                return 1
            fi
        fi
    done < <(echo "$snap_json" | jq -c '.[]')
}

wait_backup_ready() {
    local backup_name="$1"
    local start_time elapsed status
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)

    while true; do
        local bjson
        bjson=$(openstack volume backup show "$backup_name" -f json 2>/dev/null || echo '{}')
        status=$(echo "$bjson" | jq -r '.status // "unknown"')

        elapsed=$(( $(date +%s) - start_time ))
        local el_str
        el_str=$(elapsed_human "$elapsed")
        local spin_char="${spin_chars:spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        printf "\r   [%s] %-8s  backup: %-20s  status: %s" \
            "$spin_char" "$el_str" "${backup_name:0:20}" "$status" >&2

        if [[ "$status" == "available" ]]; then
            printf "\r%-100s\r" "" >&2
            ok "Backup ready: ${backup_name} (${el_str})"
            return 0
        fi

        if [[ "$status" == "error" ]]; then
            printf "\r%-100s\r" "" >&2
            err "Backup failed: ${backup_name}"
            return 1
        fi

        if (( elapsed >= POLL_TIMEOUT )); then
            printf "\r%-100s\r" "" >&2
            warn "Backup timeout: ${backup_name}"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

wait_snapshots_deleted() {
    local vol_id="$1"
    local start_time elapsed
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)

    while true; do
        local snap_json remaining
        snap_json=$(fetch_volume_snapshots "$vol_id")
        remaining=$(echo "$snap_json" | jq 'length')

        if (( remaining == 0 )); then
            ok "All snapshots removed"
            return 0
        fi

        local error_count
        error_count=$(echo "$snap_json" | jq \
            '[.[] | select(.Status == "error_deleting" or .status == "error_deleting")] | length')
        if (( error_count > 0 )); then
            err "Snapshot deletion failed (${error_count} in error_deleting state)"
            return 1
        fi

        elapsed=$(( $(date +%s) - start_time ))
        local el_str
        el_str=$(elapsed_human "$elapsed")
        local spin_char="${spin_chars:spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        printf "\r   [%s] %-8s  snapshots remaining: %d" \
            "$spin_char" "$el_str" "$remaining" >&2

        if (( elapsed >= POLL_TIMEOUT )); then
            printf "\r%-100s\r" "" >&2
            warn "Timeout waiting for snapshot deletion"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

cleanup_snapshots() {
    if (( ${#NEEDS_SNAP_DELETE[@]} == 0 )); then
        return 0
    fi

    msg "Cleaning up snapshots..."

    declare -A _snap_failed=()
    local vol_id vjson vol_name

    for vol_id in "${NEEDS_SNAP_DELETE[@]}"; do
        vjson=$(fetch_volume_detail "$vol_id")
        vol_name=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id else .name end')

        msg "Handling snapshots for ${vol_name} (${VOL_SNAP_COUNT[$vol_id]:-?} snapshot(s))..."

        # Backup first if requested
        if [[ "$HANDLE_SNAPSHOTS" == "backup-delete" ]]; then
            if ! backup_volume_snapshots "$vol_id" "$BACKUP_CONTAINER"; then
                err "Backup failed for ${vol_name} — skipping retype"
                _snap_failed["$vol_id"]=1
                (( RETYPE_FAIL++ )) || true
                continue
            fi
        fi

        # Delete snapshots
        if ! delete_volume_snapshots "$vol_id"; then
            err "Snapshot deletion failed for ${vol_name} — skipping retype"
            _snap_failed["$vol_id"]=1
            (( RETYPE_FAIL++ )) || true
            continue
        fi

        # Wait for deletion to complete
        if (( ! DRY_RUN )); then
            printf "\r%-100s\r" "" >&2
            if ! wait_snapshots_deleted "$vol_id"; then
                err "Snapshot cleanup incomplete for ${vol_name} — skipping retype"
                _snap_failed["$vol_id"]=1
                (( RETYPE_FAIL++ )) || true
                continue
            fi
        fi

        ok "Snapshots cleared for ${vol_name}"
    done

    # Remove failed volumes from VALID_VOLS
    if (( ${#_snap_failed[@]} > 0 )); then
        local _cleaned=()
        local _v
        for _v in "${VALID_VOLS[@]}"; do
            if [[ -z "${_snap_failed[$_v]:-}" ]]; then
                _cleaned+=("$_v")
            fi
        done
        VALID_VOLS=("${_cleaned[@]}")
    fi
}

select_backup_container_interactive() {
    msg "Available backup containers:"
    echo "" >&2

    local containers_json
    containers_json=$(openstack container list -f json 2>/dev/null || echo '[]')
    local container_count
    container_count=$(echo "$containers_json" | jq 'length')

    if (( container_count > 0 )); then
        local sep
        sep=$(printf '%*s' 50 '' | tr ' ' '-')
        printf "   %-4s %s\n" "#" "Name" >&2
        echo "   ${sep}" >&2

        local idx=0
        while IFS= read -r line; do
            (( idx++ )) || true
            local cname
            cname=$(echo "$line" | jq -r '.Name // .name // "—"')
            printf "   %-4s %s\n" "${idx}" "$cname" >&2
        done < <(echo "$containers_json" | jq -c '.[]')

        echo "   ${sep}" >&2
    else
        echo "   (no existing containers found)" >&2
    fi
    echo "" >&2

    local container_input
    read -rp "   Enter number or container name (new containers are auto-created): " container_input

    if [[ "$container_input" =~ ^[0-9]+$ ]] && (( container_input >= 1 && container_input <= container_count )); then
        BACKUP_CONTAINER=$(echo "$containers_json" | jq -r ".[$((container_input - 1))].Name // .[$((container_input - 1))].name")
    else
        BACKUP_CONTAINER="$container_input"
    fi

    if [[ -z "$BACKUP_CONTAINER" ]]; then
        err "No container specified."
        return 1
    fi

    ok "Backup container: ${BACKUP_CONTAINER}"
}

# --- VM state handling functions -----------------------------------------------

wait_server_status() {
    local server_id="$1" target_status="$2"
    local start_time elapsed status
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)

    while true; do
        local sjson
        sjson=$(openstack server show "$server_id" -f json 2>/dev/null || echo '{}')
        status=$(echo "$sjson" | jq -r '.status // "unknown"' | tr '[:upper:]' '[:lower:]')

        elapsed=$(( $(date +%s) - start_time ))
        local el_str
        el_str=$(elapsed_human "$elapsed")
        local spin_char="${spin_chars:spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        printf "\r   [%s] %-8s  server: %-13s  status: %s" \
            "$spin_char" "$el_str" "${server_id:0:13}" "$status" >&2

        if [[ "$status" == "$target_status" ]]; then
            printf "\r%-100s\r" "" >&2
            ok "Server ${server_id:0:13}... is ${target_status} (${el_str})"
            SERVER_STATE_CACHE["$server_id"]=$(echo "$sjson" | jq -r '."OS-EXT-STS:vm_state" // ""' | tr '[:upper:]' '[:lower:]')
            return 0
        fi

        if [[ "$status" == "error" ]]; then
            printf "\r%-100s\r" "" >&2
            err "Server ${server_id:0:13}... entered error state"
            return 1
        fi

        if (( elapsed >= POLL_TIMEOUT )); then
            printf "\r%-100s\r" "" >&2
            warn "Timeout waiting for server ${target_status}"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

wait_volume_status() {
    local vol_id="$1" target_status="$2"
    local start_time elapsed status
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)

    while true; do
        local vjson
        vjson=$(fetch_volume_detail "$vol_id")
        status=$(echo "$vjson" | jq -r '.status // "unknown"')

        elapsed=$(( $(date +%s) - start_time ))
        local el_str
        el_str=$(elapsed_human "$elapsed")
        local spin_char="${spin_chars:spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        printf "\r   [%s] %-8s  volume: %-13s  status: %s" \
            "$spin_char" "$el_str" "${vol_id:0:13}" "$status" >&2

        if [[ "$status" == "$target_status" ]]; then
            printf "\r%-100s\r" "" >&2
            ok "Volume ${vol_id:0:13}... is ${target_status} (${el_str})"
            return 0
        fi

        if [[ "$status" == error* ]]; then
            printf "\r%-100s\r" "" >&2
            err "Volume ${vol_id:0:13}... entered ${status} state"
            return 1
        fi

        if (( elapsed >= POLL_TIMEOUT )); then
            printf "\r%-100s\r" "" >&2
            warn "Timeout waiting for volume ${target_status}"
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

handle_vm_state_pre() {
    if (( ${#NEEDS_VM_HANDLE[@]} == 0 )); then
        return 0
    fi

    msg "Handling stopped VM state (pre-retype)..."

    declare -A _vm_failed=()
    local vol_id info server_id device vm_state bootable

    if [[ "$HANDLE_VM_STATE" == "detach-reattach" ]]; then
        for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
            info="${VOL_VM_INFO[$vol_id]}"
            IFS='|' read -r server_id device vm_state bootable <<< "$info"

            local vjson vol_name
            vjson=$(fetch_volume_detail "$vol_id")
            vol_name=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id else .name end')

            msg "Detaching ${vol_name} from ${server_id:0:13}... (device: ${device})"
            if ! run openstack server remove volume "$server_id" "$vol_id"; then
                err "Detach failed for ${vol_name}"
                _vm_failed["$vol_id"]=1
                (( RETYPE_FAIL++ )) || true
                continue
            fi
            if (( ! DRY_RUN )); then
                if ! wait_volume_status "$vol_id" "available"; then
                    err "Volume ${vol_name} did not reach available state after detach"
                    _vm_failed["$vol_id"]=1
                    (( RETYPE_FAIL++ )) || true
                    continue
                fi
            fi
            ok "Detached ${vol_name}"
        done
    elif [[ "$HANDLE_VM_STATE" == "start-stop" ]]; then
        # Group by server_id to start each VM only once
        declare -A _servers_to_start=()
        for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
            IFS='|' read -r server_id _ _ _ <<< "${VOL_VM_INFO[$vol_id]}"
            _servers_to_start["$server_id"]=1
        done

        for server_id in "${!_servers_to_start[@]}"; do
            msg "Starting server ${server_id:0:13}..."
            if ! run openstack server start "$server_id"; then
                err "Failed to start server ${server_id}"
                for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
                    local _sid
                    IFS='|' read -r _sid _ _ _ <<< "${VOL_VM_INFO[$vol_id]}"
                    if [[ "$_sid" == "$server_id" ]]; then
                        _vm_failed["$vol_id"]=1
                        (( RETYPE_FAIL++ )) || true
                    fi
                done
                continue
            fi
            if (( ! DRY_RUN )); then
                if ! wait_server_status "$server_id" "active"; then
                    err "Server ${server_id} did not reach ACTIVE state"
                    for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
                        local _sid
                        IFS='|' read -r _sid _ _ _ <<< "${VOL_VM_INFO[$vol_id]}"
                        if [[ "$_sid" == "$server_id" ]]; then
                            _vm_failed["$vol_id"]=1
                            (( RETYPE_FAIL++ )) || true
                        fi
                    done
                    continue
                fi
            fi
        done
    fi

    # Remove failed volumes from VALID_VOLS and NEEDS_VM_HANDLE
    if (( ${#_vm_failed[@]} > 0 )); then
        local _cleaned=() _cleaned_vm=() _v
        for _v in "${VALID_VOLS[@]}"; do
            [[ -z "${_vm_failed[$_v]:-}" ]] && _cleaned+=("$_v")
        done
        VALID_VOLS=("${_cleaned[@]}")
        for _v in "${NEEDS_VM_HANDLE[@]}"; do
            [[ -z "${_vm_failed[$_v]:-}" ]] && _cleaned_vm+=("$_v")
        done
        NEEDS_VM_HANDLE=("${_cleaned_vm[@]}")
    fi
}

handle_vm_state_post() {
    if (( ${#NEEDS_VM_HANDLE[@]} == 0 )); then
        return 0
    fi

    msg "Handling stopped VM state (post-retype)..."

    local vol_id info server_id device vm_state bootable

    if [[ "$HANDLE_VM_STATE" == "detach-reattach" ]]; then
        for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
            info="${VOL_VM_INFO[$vol_id]}"
            IFS='|' read -r server_id device vm_state bootable <<< "$info"

            local vjson vol_name
            vjson=$(fetch_volume_detail "$vol_id")
            vol_name=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id else .name end')

            msg "Reattaching ${vol_name} to ${server_id:0:13}... at ${device}"
            if ! run openstack server add volume "$server_id" "$vol_id" --device "$device"; then
                err "Reattach failed for ${vol_name} — manual reattach needed:"
                err "  openstack server add volume ${server_id} ${vol_id} --device ${device}"
                continue
            fi
            if (( ! DRY_RUN )); then
                if ! wait_volume_status "$vol_id" "in-use"; then
                    warn "Volume ${vol_name} did not reach in-use state after reattach"
                    continue
                fi
            fi
            ok "Reattached ${vol_name} at ${device}"
        done
    elif [[ "$HANDLE_VM_STATE" == "start-stop" ]]; then
        # Stop each unique server that was started
        declare -A _servers_to_stop=()
        for vol_id in "${NEEDS_VM_HANDLE[@]}"; do
            IFS='|' read -r server_id _ _ _ <<< "${VOL_VM_INFO[$vol_id]}"
            _servers_to_stop["$server_id"]=1
        done

        for server_id in "${!_servers_to_stop[@]}"; do
            msg "Stopping server ${server_id:0:13}..."
            if ! run openstack server stop "$server_id"; then
                err "Failed to stop server ${server_id} — manual stop needed"
                continue
            fi
            if (( ! DRY_RUN )); then
                if ! wait_server_status "$server_id" "shutoff"; then
                    warn "Server ${server_id} did not reach SHUTOFF state"
                    continue
                fi
            fi
            ok "Server ${server_id:0:13}... stopped"
        done
    fi
}

# --- Monitoring ---------------------------------------------------------------

monitor_volume() {
    local vol_id="$1" vol_name="${2:-$1}" pre_retype_mig="${3:-}" target_type="${4:-}"
    local start_time elapsed status migration_status vol_type
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)
    msg "Monitoring ${vol_name}..."

    # Clean exit on Ctrl+C during monitoring
    trap 'printf "\n" >&2; warn "Interrupted. Migration may still be in progress."; trap - INT; return 130' INT

    # Use pre-retype migration_status if provided (avoids race with fast failures),
    # otherwise capture current state (standalone -m mode).
    local initial_mig_status
    if [[ -n "$pre_retype_mig" ]]; then
        initial_mig_status="$pre_retype_mig"
    else
        initial_mig_status=$(echo "$(fetch_volume_detail "$vol_id")" | jq -r '.migration_status // "none"')
    fi
    local state_changed=0

    # Give Cinder time to accept the retype before first poll
    sleep "$POLL_INTERVAL"

    while true; do
        local vjson
        vjson=$(fetch_volume_detail "$vol_id")
        status=$(echo "$vjson" | jq -r '.status // "unknown"')
        migration_status=$(echo "$vjson" | jq -r '.migration_status // "none"')
        vol_type=$(echo "$vjson" | jq -r '.type // .volume_type // "unknown"')

        # Detect that state has actually changed from initial
        if [[ "$migration_status" != "$initial_mig_status" ]]; then
            state_changed=1
        fi

        elapsed=$(( $(date +%s) - start_time ))
        local el_str
        el_str=$(elapsed_human "$elapsed")

        local spin_char="${spin_chars:spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % 4 ))

        printf "\r   [%s] %-8s  status: %-12s  migration: %-12s  type: %s" \
            "$spin_char" "$el_str" "$status" "$migration_status" "$vol_type" >&2

        if [[ "$migration_status" == "success" ]]; then
            printf "\r%-100s\r" "" >&2
            ok "Migration completed in ${el_str}"
            ok "Final: status=${status}  type=${vol_type}  migration=${migration_status}"
            trap - INT
            return 0
        fi

        # Detect instant retype: type already matches target, retype succeeded.
        # Covers same-backend relabels where Cinder changes the type without
        # data movement (migration_status stays none or remains stale).
        if [[ -n "$target_type" && "$vol_type" == "$target_type" ]] \
           && [[ "$status" == "in-use" || "$status" == "available" ]]; then
            printf "\r%-100s\r" "" >&2
            ok "Retype completed in ${el_str} (no migration needed)"
            ok "Final: status=${status}  type=${vol_type}"
            trap - INT
            return 0
        fi

        if [[ "$migration_status" == "error" ]] || [[ "$status" == error* ]]; then
            if (( state_changed )); then
                # Error occurred AFTER state transition — real failure
                printf "\r%-100s\r" "" >&2
                err "Migration failed after ${el_str}"
                err "Final: status=${status}  type=${vol_type}  migration=${migration_status}"
                trap - INT
                return 1
            fi
            # Stale error from previous attempt — keep waiting for transition
        fi

        if (( elapsed >= POLL_TIMEOUT )); then
            printf "\r%-100s\r" "" >&2
            warn "Timeout after ${el_str}"
            warn "Last: status=${status}  migration=${migration_status}"
            warn "Migration may still be in progress. Resume with: $0 -m ${vol_id}"
            trap - INT
            return 1
        fi

        sleep "$POLL_INTERVAL"
    done
}

confirm_prompt() {
    local target_type="$1"
    shift
    local vol_ids=("$@")

    msg "Retype plan:" >&2
    echo "" >&2

    local sep
    sep=$(printf '%*s' 100 '' | tr ' ' '-')
    printf "   %-36s  %-22s  %-18s  %-10s\n" "ID" "Name" "Current Type" "Status" >&2
    echo "   ${sep}" >&2

    local vid vjson vname vtype vstatus
    for vid in "${vol_ids[@]}"; do
        vjson=$(fetch_volume_detail "$vid")
        vname=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id[0:12] + "..." else .name end')
        vtype=$(echo "$vjson" | jq -r '.type // .volume_type // "—"')
        vstatus=$(echo "$vjson" | jq -r '.status // "—"')
        printf "   %-36s  %-22s  %-18s  %-10s\n" \
            "$vid" "${vname:0:22}" "${vtype:0:18}" "$vstatus" >&2
    done

    echo "" >&2
    echo "   Target type : ${target_type}" >&2
    echo "   Policy      : on-demand (via ${RETYPE_FLAG})" >&2
    echo "   Volumes     : ${#vol_ids[@]}" >&2

    # Show snapshot cleanup warnings
    if (( ${#NEEDS_SNAP_DELETE[@]} > 0 )); then
        echo "" >&2
        local action_desc="delete"
        [[ "$HANDLE_SNAPSHOTS" == "backup-delete" ]] && action_desc="backup then delete"
        echo "   Snapshot cleanup (${action_desc}):" >&2
        local _sv _sname
        for _sv in "${NEEDS_SNAP_DELETE[@]}"; do
            _sname=$(echo "$(fetch_volume_detail "$_sv")" | jq -r 'if (.name // "") == "" then .id else .name end')
            printf "     %-36s  %-22s  %d snapshot(s)\n" \
                "$_sv" "${_sname:0:22}" "${VOL_SNAP_COUNT[$_sv]:-0}" >&2
        done
        if [[ "$HANDLE_SNAPSHOTS" == "backup-delete" ]]; then
            echo "   Backup container: ${BACKUP_CONTAINER}" >&2
        fi
    fi

    # Show VM state handling warnings
    if (( ${#NEEDS_VM_HANDLE[@]} > 0 )); then
        echo "" >&2
        echo "   VM state handling (${HANDLE_VM_STATE}):" >&2
        local _vv _vn _vi _sid _dev _bflag
        for _vv in "${NEEDS_VM_HANDLE[@]}"; do
            _vn=$(echo "$(fetch_volume_detail "$_vv")" | jq -r 'if (.name // "") == "" then .id else .name end')
            IFS='|' read -r _sid _dev _ _bflag <<< "${VOL_VM_INFO[$_vv]}"
            printf "     %-36s  %-22s  server: %s  device: %s\n" \
                "$_vv" "${_vn:0:22}" "${_sid:0:13}" "$_dev" >&2
        done
    fi

    echo "" >&2

    if (( AUTO_YES )); then
        ok "Auto-confirmed (--yes)"
        return 0
    fi

    local answer
    read -rp "   Proceed? [y/N]: " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) msg "Aborted."; return 1 ;;
    esac
}

# select_volumes_interactive LABEL VOL_ID [VOL_ID...]
# Displays numbered volume table and prompts user to select.
# Result is stored in SELECTED_VOL_IDS array.
select_volumes_interactive() {
    local label="$1"
    shift
    local vol_ids=("$@")
    local count=${#vol_ids[@]}

    msg "${label} (${count} total):"
    echo "" >&2

    local sep
    sep=$(printf '%*s' 108 '' | tr ' ' '-')
    printf "   %-4s %-36s  %-22s  %5s  %-18s  %-10s  %s\n" \
        "#" "ID" "Name" "Size" "Type" "Status" "Device" >&2
    echo "   ${sep}" >&2

    local idx=0 vid vjson vname vsize vtype vstatus vdevice
    for vid in "${vol_ids[@]}"; do
        (( idx++ )) || true
        vjson=$(fetch_volume_detail "$vid")
        vname=$(echo "$vjson" | jq -r 'if (.name // "") == "" then .id[0:12] + "..." else .name end')
        vsize=$(echo "$vjson" | jq -r '.size // 0')
        vtype=$(echo "$vjson" | jq -r '.type // .volume_type // "—"')
        vstatus=$(echo "$vjson" | jq -r '.status // "—"')
        vdevice=$(echo "$vjson" | jq -r '
            if (.attachments | type) == "array" and (.attachments | length) > 0 then
                .attachments[0].device // "—"
            else
                "—"
            end')
        printf "   %-4s %-36s  %-22s  %4dG  %-18s  %-10s  %s\n" \
            "${idx}" "$vid" "${vname:0:22}" "$vsize" "${vtype:0:18}" "$vstatus" "$vdevice" >&2
    done

    echo "   ${sep}" >&2
    echo "" >&2

    if (( AUTO_YES )); then
        ok "Auto-selected all ${count} volume(s) (--yes)"
        SELECTED_VOL_IDS=("${vol_ids[@]}")
        return 0
    fi

    local answer
    read -rp "   Select volumes to retype [1-${count}, all, or comma-separated]: " answer

    SELECTED_VOL_IDS=()
    if [[ "$answer" == "all" || "$answer" == "ALL" ]]; then
        SELECTED_VOL_IDS=("${vol_ids[@]}")
    else
        IFS=',' read -ra selections <<< "$answer"
        local sel
        for sel in "${selections[@]}"; do
            sel="${sel// /}"
            if [[ "$sel" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local from="${BASH_REMATCH[1]}" to="${BASH_REMATCH[2]}"
                local i
                for (( i = from; i <= to; i++ )); do
                    if (( i >= 1 && i <= count )); then
                        SELECTED_VOL_IDS+=("${vol_ids[$((i - 1))]}")
                    fi
                done
            elif [[ "$sel" =~ ^[0-9]+$ ]]; then
                if (( sel >= 1 && sel <= count )); then
                    SELECTED_VOL_IDS+=("${vol_ids[$((sel - 1))]}")
                fi
            fi
        done
    fi

    if (( ${#SELECTED_VOL_IDS[@]} == 0 )); then
        warn "No volumes selected."
        return 1
    fi

    ok "Selected ${#SELECTED_VOL_IDS[@]} volume(s)"
    return 0
}

# select_type_interactive
# Displays numbered type table and prompts user to select.
# Prints the resolved type name to stdout.
select_type_interactive() {
    ensure_volume_types

    local type_count
    type_count=$(echo "$VOLUME_TYPES_JSON" | jq 'length')

    if (( type_count == 0 )); then
        err "No volume types available."
        return 1
    fi

    msg "Available volume types:"
    echo "" >&2

    local sep
    sep=$(printf '%*s' 70 '' | tr ' ' '-')
    printf "   %-4s %-36s  %s\n" "#" "ID" "Name" >&2
    echo "   ${sep}" >&2

    local idx=0
    while IFS= read -r line; do
        (( idx++ )) || true
        local tid tname
        tid=$(echo "$line" | jq -r '.ID // "—"')
        tname=$(echo "$line" | jq -r '.Name // "—"')
        printf "   %-4s %-36s  %s\n" "${idx}" "$tid" "$tname" >&2
    done < <(echo "$VOLUME_TYPES_JSON" | jq -c '.[]')

    echo "   ${sep}" >&2
    echo "" >&2

    local type_input target_type=""
    read -rp "   Enter number or type name: " type_input

    if [[ "$type_input" =~ ^[0-9]+$ ]] && (( type_input >= 1 && type_input <= type_count )); then
        target_type=$(echo "$VOLUME_TYPES_JSON" | jq -r ".[$((type_input - 1))].Name")
    else
        if ! target_type=$(resolve_volume_type "$type_input"); then
            return 1
        fi
    fi

    echo "$target_type"
}

# run_preflight VOL_ID... -- TARGET_TYPE
# Runs pre-flight checks on all volumes. Populates VALID_VOLS with passing IDs.
# Updates RETYPE_SKIP and RETYPE_FAIL counters.
declare -a VALID_VOLS=()

run_preflight() {
    local target_type="$1"
    shift
    local vol_ids=("$@")

    msg "Running pre-flight checks..."
    VALID_VOLS=()
    NEEDS_SNAP_DELETE=()
    NEEDS_VM_HANDLE=()
    local vid pf_rc
    for vid in "${vol_ids[@]}"; do
        pf_rc=0
        preflight_retype "$vid" "$target_type" || pf_rc=$?
        if (( pf_rc == 0 )); then
            VALID_VOLS+=("$vid")
        elif (( pf_rc == 3 )); then
            VALID_VOLS+=("$vid")
            NEEDS_SNAP_DELETE+=("$vid")
        elif (( pf_rc == 4 )); then
            VALID_VOLS+=("$vid")
            NEEDS_VM_HANDLE+=("$vid")
        elif (( pf_rc == 2 )); then
            (( RETYPE_SKIP++ )) || true
        else
            (( RETYPE_FAIL++ )) || true
        fi
    done
}

# execute_retype_batch TARGET_TYPE VOL_ID [VOL_ID...]
# Executes retype for each volume, with optional monitoring.
# Updates RETYPE_OK and RETYPE_FAIL counters.
execute_retype_batch() {
    local target_type="$1"
    shift
    local vol_ids=("$@")
    local total=${#vol_ids[@]}
    local current=0

    local vid vol_json vol_name pre_mig_status
    for vid in "${vol_ids[@]}"; do
        (( current++ )) || true
        vol_json=$(fetch_volume_detail "$vid")
        vol_name=$(echo "$vol_json" | jq -r 'if (.name // "") == "" then .id else .name end')
        pre_mig_status=$(echo "$vol_json" | jq -r '.migration_status // "none"')

        if (( total > 1 )); then
            echo "" >&2
            msg "[${current}/${total}] Retyping ${vol_name}..."
        else
            echo "" >&2
            msg "Retyping ${vol_name}..."
        fi

        if ! execute_retype "$vid" "$target_type"; then
            err "Retype command failed for ${vol_name}"
            (( RETYPE_FAIL++ )) || true
            continue
        fi

        if (( DRY_RUN )); then
            (( RETYPE_OK++ )) || true
            continue
        fi

        ok "Retype initiated for ${vol_name}"

        if (( ! NO_MONITOR )); then
            local mon_rc=0
            monitor_volume "$vid" "$vol_name" "$pre_mig_status" "$target_type" || mon_rc=$?
            if (( mon_rc == 0 )); then
                (( RETYPE_OK++ )) || true
            else
                (( RETYPE_FAIL++ )) || true
            fi
        else
            (( RETYPE_OK++ )) || true
        fi
    done

    # Summary
    if (( total > 1 || RETYPE_SKIP > 0 || RETYPE_FAIL > 0 )); then
        echo "" >&2
        msg "Summary: ${RETYPE_OK} succeeded, ${RETYPE_FAIL} failed, ${RETYPE_SKIP} skipped"
    fi
}

# --- Interactive wizard -------------------------------------------------------

interactive_mode() {
    check_auth
    detect_retype_flag
    ok "Using flag: ${RETYPE_FLAG}"

    # Step 1: Volume discovery
    echo "" >&2
    msg "Step 1: Select volumes to retype"
    echo "" >&2

    local server_input
    read -rp "   Server name or ID [Enter to list all volumes]: " server_input

    local vol_ids=()
    if [[ -n "$server_input" ]]; then
        resolve_server "$server_input"
        if (( ${#RESOLVED_VOL_IDS[@]} == 0 )); then
            err "Server '${server_input}' has no attached volumes."
            exit 1
        fi
        vol_ids=("${RESOLVED_VOL_IDS[@]}")
        echo "" >&2
        if ! select_volumes_interactive \
            "Volumes attached to ${RESOLVED_SERVER_NAME}" "${vol_ids[@]}"; then
            exit 0
        fi
    else
        msg "Fetching volume list..."
        local volumes_json
        volumes_json=$(openstack volume list -f json 2>/dev/null || echo '[]')
        local vol_count
        vol_count=$(echo "$volumes_json" | jq 'length')
        if (( vol_count == 0 )); then
            err "No volumes found."
            exit 1
        fi
        mapfile -t vol_ids < <(echo "$volumes_json" | jq -r '.[].ID')
        echo "" >&2
        if ! select_volumes_interactive "Available volumes" "${vol_ids[@]}"; then
            exit 0
        fi
    fi

    # Step 2: Select target type
    echo "" >&2
    msg "Step 2: Select target volume type"
    echo "" >&2

    local target_type
    if ! target_type=$(select_type_interactive); then
        exit 1
    fi
    ok "Target type: ${target_type}"

    # Step 3: Pre-flight checks
    # Allow snapshots and stopped VMs to be detected (resolved interactively below)
    [[ -z "$HANDLE_SNAPSHOTS" ]] && HANDLE_SNAPSHOTS="ask"
    [[ -z "$HANDLE_VM_STATE" ]] && HANDLE_VM_STATE="ask"

    echo "" >&2
    msg "Step 3: Pre-flight checks"
    run_preflight "$target_type" "${SELECTED_VOL_IDS[@]}"

    if (( ${#VALID_VOLS[@]} == 0 )); then
        err "No volumes eligible for retype."
        exit 1
    fi

    # Step 3b: Handle snapshots interactively
    if (( ${#NEEDS_SNAP_DELETE[@]} > 0 )) && [[ "$HANDLE_SNAPSHOTS" == "ask" ]]; then
        echo "" >&2
        msg "Some volumes have snapshots that block retype:"
        local _sv _sn
        for _sv in "${NEEDS_SNAP_DELETE[@]}"; do
            _sn=$(echo "$(fetch_volume_detail "$_sv")" | jq -r 'if (.name // "") == "" then .id else .name end')
            echo "     ${_sn} — ${VOL_SNAP_COUNT[$_sv]:-?} snapshot(s)" >&2
        done
        echo "" >&2
        echo "   How to handle snapshots?" >&2
        echo "   1) delete         — Delete snapshots (data lost)" >&2
        echo "   2) backup-delete  — Backup snapshots then delete" >&2
        echo "   3) skip           — Skip these volumes" >&2
        echo "" >&2

        local snap_choice
        read -rp "   Select [1-3]: " snap_choice
        case "$snap_choice" in
            1)
                HANDLE_SNAPSHOTS="delete"
                ;;
            2)
                HANDLE_SNAPSHOTS="backup-delete"
                echo "" >&2
                if ! select_backup_container_interactive; then
                    exit 1
                fi
                ;;
            *)
                HANDLE_SNAPSHOTS=""
                # Remove snapshot-blocked volumes from VALID_VOLS
                declare -A _skip_snaps=()
                for _sv in "${NEEDS_SNAP_DELETE[@]}"; do
                    _skip_snaps["$_sv"]=1
                    (( RETYPE_SKIP++ )) || true
                done
                local _cleaned=()
                local _cv
                for _cv in "${VALID_VOLS[@]}"; do
                    [[ -z "${_skip_snaps[$_cv]:-}" ]] && _cleaned+=("$_cv")
                done
                VALID_VOLS=("${_cleaned[@]}")
                NEEDS_SNAP_DELETE=()
                if (( ${#VALID_VOLS[@]} == 0 )); then
                    err "No volumes eligible for retype."
                    exit 1
                fi
                ;;
        esac
    fi

    # Step 3c: Handle stopped VMs interactively
    if (( ${#NEEDS_VM_HANDLE[@]} > 0 )) && [[ "$HANDLE_VM_STATE" == "ask" ]]; then
        echo "" >&2
        msg "Some volumes are attached to stopped VMs (cross-backend retype blocked):"
        local _vv _vn _vi _sid _dev _bflag
        for _vv in "${NEEDS_VM_HANDLE[@]}"; do
            _vn=$(echo "$(fetch_volume_detail "$_vv")" | jq -r 'if (.name // "") == "" then .id else .name end')
            IFS='|' read -r _sid _dev _ _bflag <<< "${VOL_VM_INFO[$_vv]}"
            local _boot_note=""
            [[ "$_bflag" == "true" ]] && _boot_note=" [boot disk]"
            echo "     ${_vn} — server ${_sid:0:13}... device ${_dev}${_boot_note}" >&2
        done
        echo "" >&2
        echo "   How to handle stopped VMs?" >&2
        echo "   1) start-stop       — Start VM, retype, stop VM (works for all volumes)" >&2
        echo "   2) detach-reattach  — Detach, retype as available, reattach (data volumes only)" >&2
        echo "   3) skip             — Skip these volumes" >&2
        echo "" >&2

        local vm_choice
        read -rp "   Select [1-3]: " vm_choice
        case "$vm_choice" in
            1)
                HANDLE_VM_STATE="start-stop"
                ;;
            2)
                HANDLE_VM_STATE="detach-reattach"
                # Validate no boot disks in the set
                local _has_boot=0
                for _vv in "${NEEDS_VM_HANDLE[@]}"; do
                    IFS='|' read -r _ _ _ _bflag <<< "${VOL_VM_INFO[$_vv]}"
                    if [[ "$_bflag" == "true" ]]; then
                        _has_boot=1
                        _vn=$(echo "$(fetch_volume_detail "$_vv")" | jq -r 'if (.name // "") == "" then .id else .name end')
                        err "Volume ${_vn} is a boot disk — cannot detach-reattach."
                    fi
                done
                if (( _has_boot )); then
                    err "Switch to start-stop or skip boot disk volumes."
                    exit 1
                fi
                ;;
            *)
                HANDLE_VM_STATE=""
                declare -A _skip_vm=()
                for _vv in "${NEEDS_VM_HANDLE[@]}"; do
                    _skip_vm["$_vv"]=1
                    (( RETYPE_SKIP++ )) || true
                done
                local _cleaned=()
                local _cv
                for _cv in "${VALID_VOLS[@]}"; do
                    [[ -z "${_skip_vm[$_cv]:-}" ]] && _cleaned+=("$_cv")
                done
                VALID_VOLS=("${_cleaned[@]}")
                NEEDS_VM_HANDLE=()
                if (( ${#VALID_VOLS[@]} == 0 )); then
                    err "No volumes eligible for retype."
                    exit 1
                fi
                ;;
        esac
    fi

    # Step 4: Confirm and execute
    echo "" >&2
    msg "Step 4: Confirm and execute"
    if ! confirm_prompt "$target_type" "${VALID_VOLS[@]}"; then
        exit 0
    fi

    cleanup_snapshots
    if (( ${#VALID_VOLS[@]} == 0 )); then
        err "No volumes remaining after snapshot cleanup."
        exit 1
    fi

    handle_vm_state_pre
    if (( ${#VALID_VOLS[@]} == 0 )); then
        err "No volumes remaining after VM state handling."
        exit 1
    fi

    execute_retype_batch "$target_type" "${VALID_VOLS[@]}"

    handle_vm_state_post

    if (( RETYPE_FAIL > 0 )); then
        exit 1
    fi
}

# --- Argument Parsing ---------------------------------------------------------
OPTIONS=$(getopt -o hvilr:T:tmns:f:y \
    --long help,version,interactive,list,retype:,type:,types,monitor,dry-run,server:,format:,yes,no-monitor,interval:,timeout:,handle-snapshots:,backup-container:,handle-vm-state: \
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
        -i|--interactive)
            MODE="interactive"
            shift
            ;;
        -l|--list)
            MODE="list"
            shift
            ;;
        -t|--types)
            MODE="types"
            shift
            ;;
        -r|--retype)
            RETYPE_VOLUMES+=("$2")
            shift 2
            ;;
        -T|--type)
            TARGET_TYPE_ARG="$2"
            shift 2
            ;;
        -m|--monitor)
            MODE="monitor"
            shift
            ;;
        -s|--server)
            SERVER_FILTER="$2"
            shift 2
            ;;
        -f|--format)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-monitor)
            NO_MONITOR=1
            shift
            ;;
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --timeout)
            POLL_TIMEOUT="$2"
            shift 2
            ;;
        --handle-snapshots)
            HANDLE_SNAPSHOTS="$2"
            shift 2
            ;;
        --backup-container)
            BACKUP_CONTAINER="$2"
            shift 2
            ;;
        --handle-vm-state)
            HANDLE_VM_STATE="$2"
            shift 2
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

# Collect positional arguments (used by --monitor)
POSITIONAL_ARGS=("$@")

# Expand comma-separated volume IDs from -r
EXPANDED_VOLS=()
for _entry in "${RETYPE_VOLUMES[@]}"; do
    IFS=',' read -ra _parts <<< "$_entry"
    EXPANDED_VOLS+=("${_parts[@]}")
done
RETYPE_VOLUMES=("${EXPANDED_VOLS[@]}")
unset EXPANDED_VOLS _entry _parts

# --- Mode inference -----------------------------------------------------------

# -r or (-s + -T) implies retype mode
if [[ -z "$MODE" ]]; then
    if (( ${#RETYPE_VOLUMES[@]} > 0 )); then
        MODE="retype"
    elif [[ -n "$SERVER_FILTER" && -n "$TARGET_TYPE_ARG" ]]; then
        MODE="retype"
    elif [[ -t 0 ]] && (( ${#POSITIONAL_ARGS[@]} == 0 )); then
        MODE="interactive"
    else
        show_help >&2
        exit 1
    fi
fi

# --- Validation ---------------------------------------------------------------

case "$OUTPUT_FORMAT" in
    table|csv|json) ;;
    *) err "Invalid format '${OUTPUT_FORMAT}'. Use: table, csv, json"; exit 1 ;;
esac

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || (( POLL_INTERVAL < 1 )); then
    err "Invalid interval '${POLL_INTERVAL}'. Must be a positive integer."
    exit 1
fi

if ! [[ "$POLL_TIMEOUT" =~ ^[0-9]+$ ]] || (( POLL_TIMEOUT < 1 )); then
    err "Invalid timeout '${POLL_TIMEOUT}'. Must be a positive integer."
    exit 1
fi

if [[ -n "$HANDLE_SNAPSHOTS" && "$HANDLE_SNAPSHOTS" != "ask" ]]; then
    case "$HANDLE_SNAPSHOTS" in
        delete|backup-delete) ;;
        *) err "Invalid --handle-snapshots mode '${HANDLE_SNAPSHOTS}'. Use: delete, backup-delete"; exit 1 ;;
    esac
    if [[ "$HANDLE_SNAPSHOTS" == "backup-delete" && -z "$BACKUP_CONTAINER" && "$MODE" != "interactive" ]]; then
        err "--backup-container is required with --handle-snapshots backup-delete"
        exit 1
    fi
fi

if [[ -n "$HANDLE_VM_STATE" && "$HANDLE_VM_STATE" != "ask" ]]; then
    case "$HANDLE_VM_STATE" in
        start-stop|detach-reattach) ;;
        *) err "Invalid --handle-vm-state mode '${HANDLE_VM_STATE}'. Use: start-stop, detach-reattach"; exit 1 ;;
    esac
fi

case "$MODE" in
    retype)
        if [[ -z "$TARGET_TYPE_ARG" ]]; then
            err "Target type is required. Use -T / --type to specify."
            err "Usage: $0 -r VOL_ID -T TARGET_TYPE"
            exit 1
        fi
        if (( ${#RETYPE_VOLUMES[@]} > 0 )) && [[ -n "$SERVER_FILTER" ]]; then
            err "Use -r (explicit volumes) or -s (server discovery), not both."
            exit 1
        fi
        if (( ${#RETYPE_VOLUMES[@]} == 0 )) && [[ -z "$SERVER_FILTER" ]]; then
            err "Provide volumes via -r or a server via -s."
            err "Usage: $0 -r VOL_ID -T TYPE  or  $0 -s SERVER -T TYPE"
            exit 1
        fi
        ;;
    monitor)
        if (( ${#POSITIONAL_ARGS[@]} != 1 )); then
            err "Provide exactly one volume ID to monitor."
            err "Usage: $0 -m VOL_ID"
            exit 1
        fi
        ;;
esac

# --- Main Execution -----------------------------------------------------------

check_deps

case "$MODE" in
    interactive)
        interactive_mode
        ;;

    list)
        check_auth
        list_volumes
        ;;

    types)
        check_auth
        list_types
        ;;

    retype)
        check_auth
        detect_retype_flag
        ok "Using flag: ${RETYPE_FLAG}"

        # Resolve target type
        TARGET_TYPE=""
        if ! TARGET_TYPE=$(resolve_volume_type "$TARGET_TYPE_ARG"); then
            exit 1
        fi
        ok "Target type: ${TARGET_TYPE}"

        # Build volume list
        RETYPE_VOLS=()
        if [[ -n "$SERVER_FILTER" ]]; then
            # Server discovery mode
            resolve_server "$SERVER_FILTER"
            if (( ${#RESOLVED_VOL_IDS[@]} == 0 )); then
                err "No volumes found for server '${SERVER_FILTER}'."
                exit 1
            fi
            if ! select_volumes_interactive \
                "Volumes attached to ${RESOLVED_SERVER_NAME}" "${RESOLVED_VOL_IDS[@]}"; then
                exit 0
            fi
            RETYPE_VOLS=("${SELECTED_VOL_IDS[@]}")
        else
            # Explicit volume IDs from -r flags
            RETYPE_VOLS=("${RETYPE_VOLUMES[@]}")
        fi

        if (( ${#RETYPE_VOLS[@]} == 0 )); then
            err "No volumes to retype."
            exit 1
        fi

        # Pre-flight checks
        run_preflight "$TARGET_TYPE" "${RETYPE_VOLS[@]}"

        if (( ${#VALID_VOLS[@]} == 0 )); then
            err "No volumes eligible for retype."
            exit 1
        fi

        # Confirmation
        if ! confirm_prompt "$TARGET_TYPE" "${VALID_VOLS[@]}"; then
            exit 0
        fi

        # Snapshot cleanup
        cleanup_snapshots
        if (( ${#VALID_VOLS[@]} == 0 )); then
            err "No volumes remaining after snapshot cleanup."
            exit 1
        fi

        # VM state handling (pre-retype)
        handle_vm_state_pre
        if (( ${#VALID_VOLS[@]} == 0 )); then
            err "No volumes remaining after VM state handling."
            exit 1
        fi

        # Execute
        execute_retype_batch "$TARGET_TYPE" "${VALID_VOLS[@]}"

        # VM state handling (post-retype)
        handle_vm_state_post

        if (( RETYPE_FAIL > 0 )); then
            exit 1
        fi
        ;;

    monitor)
        check_auth
        MON_VOL="${POSITIONAL_ARGS[0]}"
        MON_JSON=$(fetch_volume_detail "$MON_VOL")
        if [[ "$MON_JSON" == "{}" || -z "$MON_JSON" ]]; then
            err "Volume '${MON_VOL}' not found or not accessible."
            exit 1
        fi
        MON_NAME=$(echo "$MON_JSON" | jq -r 'if (.name // "") == "" then .id else .name end')
        monitor_volume "$MON_VOL" "$MON_NAME"
        ;;
esac
