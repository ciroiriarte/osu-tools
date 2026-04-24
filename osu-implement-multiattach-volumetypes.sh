#!/usr/bin/env bash

# Script Name: osu-implement-multiattach-volumetypes.sh
# Description: Creates multi-attach enabled volume type variants for existing
#              Cinder volume types. Multi-attach allows simultaneous attachment
#              to multiple VMs for clustered filesystems (GFS2, OCFS2).
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-04-24
# Version: 0.1.0
#
# Requirements:
#   - openstack CLI (python-openstackclient)
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Permissions:
#   - OpenStack admin with volume-type management privileges

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.1.0"
MA_SUFFIX="-multiattach"

# Operational defaults
DRY_RUN=0
LIST_ONLY=0
FORCE=0
INSECURE=0
QUIET=0

# Counters
CREATED=0
SKIPPED=0
FAILED=0

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
step() { echo -e "   ${C_CYAN}[>]${C_RESET} $*" >&2; }

osc() {
    if (( INSECURE )); then
        openstack --insecure "$@"
    else
        openstack "$@"
    fi
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Version: $SCRIPT_VERSION

Description:
  Creates multi-attach enabled volume type variants for existing Cinder
  volume types backed by Ceph. Multi-attach allows a single volume to be
  attached to multiple VMs simultaneously, required for clustered filesystems
  (GFS2, OCFS2) and shared storage workloads.

  For each volume type with a volume_backend_name, creates a variant named
  <original-type>$MA_SUFFIX with the same backend and multiattach enabled.

Modes:
  (default)         Create multi-attach variants for all eligible volume types
  -l, --list        List volume types grouped by backend (regular vs multiattach)

Options:
  -n, --dry-run     Show what would be done without making changes
  -f, --force       Skip confirmation prompt
      --insecure    Allow insecure SSL connections
  -q, --quiet       Suppress progress output
  -h, --help        Show this help message
  -v, --version     Show version

Output (--list):
  Backend           Cinder backend name (maps to Ceph pool)
  Regular Type      Standard volume type name
  Multi-Attach Type Multi-attach enabled variant (or "—" if not created)
  Status            ✓ (both exist), ⚠ (missing multiattach variant)

Examples:
  # List current volume types by backend
  $0 --list

  # Dry run to see what would be created
  $0 --dry-run

  # Create multi-attach variants (interactive)
  $0

  # Create without confirmation
  $0 --force

Notes:
  - Requires OpenStack admin privileges
  - Volume types with no volume_backend_name are skipped
  - Existing multiattach variants are not modified
  - Multi-attach property: multiattach="<is> True"

EOF
}

check_dependencies() {
    local missing=()
    for cmd in openstack jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_auth() {
    if ! osc token issue &>/dev/null; then
        err "OpenStack authentication failed."
        err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
        exit 1
    fi
}

get_volume_types() {
    osc volume type list -f json 2>/dev/null | jq -c '.[]'
}

get_type_properties() {
    local type_name="$1"
    osc volume type show "$type_name" -f json 2>/dev/null | jq -r '.properties // {}'
}

get_backend_name() {
    local type_name="$1"
    local props
    props=$(get_type_properties "$type_name")
    echo "$props" | jq -r '.volume_backend_name // ""'
}

is_multiattach_enabled() {
    local type_name="$1"
    local props
    props=$(get_type_properties "$type_name")
    local ma_value
    ma_value=$(echo "$props" | jq -r '.multiattach // ""')
    [[ "$ma_value" == "<is> True" ]]
}

type_exists() {
    local type_name="$1"
    osc volume type show "$type_name" &>/dev/null
}

list_volume_types() {
    msg "Discovering volume types..."

    declare -A backends=()
    declare -A regular_types=()
    declare -A ma_types=()

    # Collect all volume types (avoid subshell by using here-string)
    local all_types
    all_types=$(get_volume_types)

    while IFS= read -r type_line; do
        [[ -z "$type_line" ]] && continue

        local name
        name=$(echo "$type_line" | jq -r '.Name')

        # Skip __DEFAULT__
        [[ "$name" == "__DEFAULT__" ]] && continue

        local backend
        backend=$(get_backend_name "$name")

        # Skip types without backend
        [[ -z "$backend" ]] && continue

        # Track backends
        backends["$backend"]=1

        # Categorize by suffix
        if [[ "$name" == *"$MA_SUFFIX" ]]; then
            ma_types["$backend"]="$name"
        else
            regular_types["$backend"]="$name"
        fi
    done <<< "$all_types"

    echo ""

    # Print header
    printf "%-25s  %-25s  %-30s  %s\n" \
        "Backend" "Regular Type" "Multi-Attach Type" "Status"
    printf "%s\n" "$(printf '=%.0s' {1..95})"

    # Print each backend
    local backend
    for backend in $(printf '%s\n' "${!backends[@]}" | sort); do
        local reg_type="${regular_types[$backend]:-—}"
        local ma_type="${ma_types[$backend]:-—}"
        local status

        if [[ "$reg_type" != "—" ]] && [[ "$ma_type" != "—" ]]; then
            status="✓"
        elif [[ "$reg_type" != "—" ]] && [[ "$ma_type" == "—" ]]; then
            status="⚠ missing multiattach"
        else
            status="?"
        fi

        printf "%-25s  %-25s  %-30s  %s\n" \
            "$backend" "$reg_type" "$ma_type" "$status"
    done

    echo ""

    # Summary
    local total_backends=${#backends[@]}
    local with_ma=0
    for backend in "${!backends[@]}"; do
        [[ -n "${ma_types[$backend]:-}" ]] && ((with_ma++)) || true
    done

    echo -e "${C_DIM}Summary: $total_backends backend(s), $with_ma with multiattach variant${C_RESET}"
}

confirm_action() {
    local count="$1"

    (( FORCE )) && return 0

    echo "" >&2
    echo "This will create $count multi-attach volume type variant(s)." >&2
    echo "" >&2

    read -rp "Proceed? [y/N] " answer
    case "$answer" in
        [Yy]*) return 0 ;;
        *)
            msg "Aborted by user"
            exit 0
            ;;
    esac
}

create_multiattach_variants() {
    msg "Discovering volume types..."

    local to_create=()
    declare -A type_backends=()

    # First pass: identify types needing multiattach variants
    local all_types
    all_types=$(get_volume_types)

    while IFS= read -r type_line; do
        [[ -z "$type_line" ]] && continue

        local name
        name=$(echo "$type_line" | jq -r '.Name')

        # Skip __DEFAULT__ and existing multiattach types
        [[ "$name" == "__DEFAULT__" ]] && continue
        [[ "$name" == *"$MA_SUFFIX" ]] && continue

        local backend
        backend=$(get_backend_name "$name")

        # Skip types without backend
        if [[ -z "$backend" ]]; then
            (( ! QUIET )) && warn "$name: no volume_backend_name, skipping"
            continue
        fi

        local ma_name="${name}${MA_SUFFIX}"

        # Check if multiattach variant already exists
        if type_exists "$ma_name"; then
            (( ! QUIET )) && ok "$ma_name: already exists"
            ((SKIPPED++)) || true
            continue
        fi

        to_create+=("$name")
        type_backends["$name"]="$backend"
    done <<< "$all_types"

    if (( ${#to_create[@]} == 0 )); then
        echo ""
        ok "No new multiattach variants to create"
        return 0
    fi

    echo ""
    msg "Volume types to create multiattach variants for:"
    for name in "${to_create[@]}"; do
        local backend="${type_backends[$name]}"
        echo "   - ${name}${MA_SUFFIX} (backend: $backend)"
    done
    echo ""

    if (( DRY_RUN )); then
        msg "DRY-RUN: The following actions would be performed:"
        echo ""
        for name in "${to_create[@]}"; do
            local backend="${type_backends[$name]}"
            local ma_name="${name}${MA_SUFFIX}"
            step "[DRY-RUN] Create volume type: $ma_name"
            echo "          - Set volume_backend_name=$backend"
            echo "          - Set multiattach=\"<is> True\""
            echo ""
        done
        echo "Total: ${#to_create[@]} volume type(s) would be created"
        return 0
    fi

    confirm_action "${#to_create[@]}"

    # Second pass: create the variants
    msg "Creating multiattach variants..."
    echo ""

    for name in "${to_create[@]}"; do
        local backend="${type_backends[$name]}"
        local ma_name="${name}${MA_SUFFIX}"

        step "Creating $ma_name..."

        # Create the volume type
        if ! osc volume type create "$ma_name" \
            --public \
            --description "Multi-attach enabled variant of $name" &>/dev/null; then
            err "Failed to create $ma_name"
            ((FAILED++)) || true
            continue
        fi

        # Set the backend
        if ! osc volume type set "$ma_name" \
            --property "volume_backend_name=$backend" &>/dev/null; then
            err "Failed to set backend for $ma_name"
            ((FAILED++)) || true
            continue
        fi

        # Enable multiattach
        if ! osc volume type set "$ma_name" \
            --property "multiattach=<is> True" &>/dev/null; then
            err "Failed to enable multiattach for $ma_name"
            ((FAILED++)) || true
            continue
        fi

        ok "Created $ma_name (backend: $backend)"
        ((CREATED++)) || true
    done

    echo ""
    msg "Summary: Created=$CREATED, Skipped=$SKIPPED, Failed=$FAILED"

    if (( FAILED > 0 )); then
        return 1
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    while (( $# )); do
        case "$1" in
            -l|--list)
                LIST_ONLY=1
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            --insecure)
                INSECURE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$0 $SCRIPT_VERSION"
                exit 0
                ;;
            -*)
                err "Unknown option: $1"
                echo "Use --help for usage information" >&2
                exit 1
                ;;
            *)
                err "Unexpected argument: $1"
                exit 1
                ;;
        esac
    done

    check_dependencies
    check_auth

    if (( LIST_ONLY )); then
        list_volume_types
    else
        create_multiattach_variants
    fi
}

main "$@"
