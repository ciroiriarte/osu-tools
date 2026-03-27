#!/usr/bin/env bash

# Script Name: osu-retype-vdisk.sh
# Description: Retype (migrate) OpenStack volumes between Ceph pools via
#              volume type changes. Provides both an interactive wizard and
#              a one-shot CLI mode with pre-flight checks, volume/type
#              listing, and migration progress monitoring.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-27
# Version: 0.1
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Changelog:
#   - 2026-03-27: v0.1 - Initial release. Interactive wizard and one-shot
#                         retype modes, volume listing with server filtering,
#                         volume type listing, pre-flight checks (state
#                         validation, snapshot detection), interactive volume
#                         selection, and migration progress monitoring.

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.1"

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
declare -a RETYPE_VOLUMES=()

# Counters
RETYPE_OK=0
RETYPE_FAIL=0
RETYPE_SKIP=0

# Caches
declare -A SERVER_NAME_CACHE=()
VOLUME_TYPES_JSON=""

# Resolved server state (populated by resolve_server)
RESOLVED_SERVER_ID=""
RESOLVED_SERVER_NAME=""
RESOLVED_SERVER_STATUS=""
declare -a RESOLVED_VOL_IDS=()

# Interactive selection result
declare -a SELECTED_VOL_IDS=()

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
  - Volume has no snapshots (migration blocker)
  - Target type exists and differs from current type

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

    local vol_name
    vol_name=$(echo "$vjson" | jq -r '.name // .id')
    status=$(echo "$vjson" | jq -r '.status // "unknown"')
    vol_type=$(echo "$vjson" | jq -r '.type // .volume_type // "unknown"')

    # Check valid state
    if [[ "$status" != "in-use" && "$status" != "available" ]]; then
        err "Volume '${vol_name}' is in state '${status}' (must be 'in-use' or 'available')."
        return 1
    fi

    # Check snapshots
    snap_json=$(fetch_volume_snapshots "$vol_id")
    snap_count=$(echo "$snap_json" | jq 'length')
    if (( snap_count > 0 )); then
        err "Volume '${vol_name}' has ${snap_count} snapshot(s). Remove snapshots before retype."
        return 1
    fi

    # Check target differs from current
    if [[ "$vol_type" == "$target_type" ]]; then
        warn "Volume '${vol_name}' is already type '${vol_type}'. Skipping."
        return 2
    fi

    ok "Pre-flight passed: ${vol_name} (${vol_type} → ${target_type})"
    return 0
}

execute_retype() {
    local vol_id="$1" target_type="$2"
    run openstack volume set --type "$target_type" "$RETYPE_FLAG" on-demand "$vol_id"
}

monitor_volume() {
    local vol_id="$1" vol_name="${2:-$1}"
    local start_time elapsed status migration_status vol_type
    local spin_chars='|/-\'
    local spin_idx=0

    start_time=$(date +%s)
    msg "Monitoring ${vol_name}..."

    # Clean exit on Ctrl+C during monitoring
    trap 'printf "\n" >&2; warn "Interrupted. Migration may still be in progress."; trap - INT; return 130' INT

    while true; do
        local vjson
        vjson=$(fetch_volume_detail "$vol_id")
        status=$(echo "$vjson" | jq -r '.status // "unknown"')
        migration_status=$(echo "$vjson" | jq -r '.migration_status // "none"')
        vol_type=$(echo "$vjson" | jq -r '.type // .volume_type // "unknown"')

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

        if [[ "$migration_status" == "error" ]] || [[ "$status" == error* ]]; then
            printf "\r%-100s\r" "" >&2
            err "Migration failed after ${el_str}"
            err "Final: status=${status}  type=${vol_type}  migration=${migration_status}"
            trap - INT
            return 1
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
        vname=$(echo "$vjson" | jq -r '.name // "—"')
        vtype=$(echo "$vjson" | jq -r '.type // .volume_type // "—"')
        vstatus=$(echo "$vjson" | jq -r '.status // "—"')
        printf "   %-36s  %-22s  %-18s  %-10s\n" \
            "$vid" "${vname:0:22}" "${vtype:0:18}" "$vstatus" >&2
    done

    echo "" >&2
    echo "   Target type : ${target_type}" >&2
    echo "   Policy      : on-demand (via ${RETYPE_FLAG})" >&2
    echo "   Volumes     : ${#vol_ids[@]}" >&2
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
        vname=$(echo "$vjson" | jq -r '.name // "—"')
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
    local vid pf_rc
    for vid in "${vol_ids[@]}"; do
        pf_rc=0
        preflight_retype "$vid" "$target_type" || pf_rc=$?
        if (( pf_rc == 0 )); then
            VALID_VOLS+=("$vid")
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

    local vid vol_json vol_name
    for vid in "${vol_ids[@]}"; do
        (( current++ )) || true
        vol_json=$(fetch_volume_detail "$vid")
        vol_name=$(echo "$vol_json" | jq -r '.name // .id')

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
            monitor_volume "$vid" "$vol_name" || mon_rc=$?
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
    echo "" >&2
    msg "Step 3: Pre-flight checks"
    run_preflight "$target_type" "${SELECTED_VOL_IDS[@]}"

    if (( ${#VALID_VOLS[@]} == 0 )); then
        err "No volumes eligible for retype."
        exit 1
    fi

    # Step 4: Confirm and execute
    echo "" >&2
    msg "Step 4: Confirm and execute"
    if ! confirm_prompt "$target_type" "${VALID_VOLS[@]}"; then
        exit 0
    fi

    execute_retype_batch "$target_type" "${VALID_VOLS[@]}"

    if (( RETYPE_FAIL > 0 )); then
        exit 1
    fi
}

# --- Argument Parsing ---------------------------------------------------------
OPTIONS=$(getopt -o hvilr:T:tmns:f:y \
    --long help,version,interactive,list,retype:,type:,types,monitor,dry-run,server:,format:,yes,no-monitor,interval:,timeout: \
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

        # Execute
        execute_retype_batch "$TARGET_TYPE" "${VALID_VOLS[@]}"

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
        MON_NAME=$(echo "$MON_JSON" | jq -r '.name // .id')
        monitor_volume "$MON_VOL" "$MON_NAME"
        ;;
esac
