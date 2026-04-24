#!/usr/bin/env bash

# Script Name: osu-unpin-vm-from-az.sh
# Description: Removes Availability Zone hard request from an OpenStack VM
#              to enable cross-AZ cold migration. Uses the shelve/unshelve
#              workflow with --no-availability-zone flag (Nova API >= 2.91).
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-04-24
# Version: 0.1.0
#
# Requirements:
#   - openstack CLI (python-openstackclient) with Nova API >= 2.91 support
#   - jq
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Permissions:
#   - OpenStack admin privileges required

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="0.1.0"
REQUIRED_API_VERSION="2.91"

# Operational defaults
TARGET_HOST=""
DRY_RUN=0
FORCE=0
INSECURE=0
QUIET=0
VENV_PATH=""
OSC_CMD="openstack"

# Status tracking
ORIGINAL_STATUS=""
ORIGINAL_HOST=""
ORIGINAL_AZ=""

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

spinner() {
    (( QUIET )) && return 0
    [[ -t 2 ]] || return 0
    local pid=$1 label=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r   [%s] %s" "${spin:i++%${#spin}:1}" "$label" >&2
        sleep 0.1
    done
    printf "\r%80s\r" "" >&2
}

osc() {
    if (( INSECURE )); then
        $OSC_CMD --insecure "$@"
    else
        $OSC_CMD "$@"
    fi
}

osc_api() {
    if (( INSECURE )); then
        $OSC_CMD --insecure --os-compute-api-version "$REQUIRED_API_VERSION" "$@"
    else
        $OSC_CMD --os-compute-api-version "$REQUIRED_API_VERSION" "$@"
    fi
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS] <SERVER>

Version: $SCRIPT_VERSION

Description:
  Removes the Availability Zone (AZ) hard request from an OpenStack VM to
  enable cross-AZ cold migration. This uses the shelve/unshelve workflow
  with the --no-availability-zone flag (requires Nova API >= $REQUIRED_API_VERSION).

  The workflow is:
    1. Stop the instance (if running)
    2. Shelve the instance
    3. Wait for SHELVED_OFFLOADED state
    4. Unshelve with --no-availability-zone [--host TARGET]

  After unpinning, the VM can be cold-migrated to any AZ.

Arguments:
  SERVER                  VM name or UUID to unpin

Options:
  -t, --target-host HOST  Target compute host for unshelve (optional)
                          If not specified, scheduler chooses placement
      --venv PATH         Use specific Python venv (optional, auto-detected)
      --dry-run           Show what would be done without making changes
  -f, --force             Skip confirmation prompt
      --insecure          Allow insecure SSL connections
  -q, --quiet             Suppress progress output
  -h, --help              Show this help message
  -v, --version           Show version

Examples:
  # Unpin a VM (scheduler chooses new host)
  $0 my-vm

  # Unpin and place on specific host
  $0 --target-host compute-node-05 my-vm

  # Dry run to see what would happen
  $0 --dry-run my-vm

Notes:
  - Requires OpenStack admin privileges
  - The VM will experience downtime during the procedure
  - Boot-from-volume instances are supported
  - Requires python-openstackclient >= 9.0.0 for --no-availability-zone support
  - If the system client is outdated, a local venv is created automatically
    in ~/.osu-tools/osc-venv (one-time setup)

EOF
}

check_dependencies() {
    local missing=()
    for cmd in openstack jq python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

check_client_supports_unpin() {
    local osc_path="$1"
    local version major

    # Check both help text AND version >= 9.0.0 (openstacksdk 4.x)
    if ! "$osc_path" server unshelve --help 2>&1 | grep -q -- '--no-availability-zone'; then
        return 1
    fi

    # Verify version is >= 9.0.0 (required for openstacksdk support)
    version=$("$osc_path" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$version" ]]; then
        return 1
    fi

    IFS='.' read -r major _ <<< "$version"
    if (( major < 9 )); then
        return 1
    fi

    return 0
}

setup_openstack_client() {
    local venv_dir="${HOME}/.osu-tools/osc-venv"

    if [[ -n "$VENV_PATH" ]]; then
        if [[ -x "$VENV_PATH/bin/openstack" ]]; then
            OSC_CMD="$VENV_PATH/bin/openstack"
            msg "Using specified venv: $VENV_PATH"
            return 0
        else
            err "Venv does not contain openstack: $VENV_PATH/bin/openstack"
            exit 1
        fi
    fi

    if check_client_supports_unpin "openstack"; then
        OSC_CMD="openstack"
        return 0
    fi

    warn "System openstack client does not support --no-availability-zone"

    if [[ -x "$venv_dir/bin/openstack" ]] && check_client_supports_unpin "$venv_dir/bin/openstack"; then
        msg "Using cached venv: $venv_dir"
        OSC_CMD="$venv_dir/bin/openstack"
        return 0
    fi

    msg "Setting up Python venv with python-openstackclient >= 9.0.0..."
    step "This is a one-time setup, please wait..."

    if ! python3 -m venv --help &>/dev/null; then
        err "python3-venv is not installed"
        err "Install it with: sudo apt install python3-venv"
        exit 1
    fi

    mkdir -p "$(dirname "$venv_dir")"
    rm -rf "$venv_dir"

    if ! python3 -m venv "$venv_dir" 2>&1; then
        err "Failed to create Python venv"
        exit 1
    fi

    step "Installing python-openstackclient (this may take a minute)..."
    if ! "$venv_dir/bin/pip" install --upgrade pip python-openstackclient &>/dev/null; then
        err "Failed to install python-openstackclient"
        rm -rf "$venv_dir"
        exit 1
    fi

    if ! check_client_supports_unpin "$venv_dir/bin/openstack"; then
        err "Installed client still doesn't support required features"
        rm -rf "$venv_dir"
        exit 1
    fi

    ok "Venv ready: $venv_dir"
    OSC_CMD="$venv_dir/bin/openstack"
}

check_auth() {
    if ! osc token issue &>/dev/null; then
        err "OpenStack authentication failed."
        err "Ensure credentials are sourced (e.g.: source ~/openrc.sh)"
        exit 1
    fi
}

get_server_info() {
    local server="$1"
    local info

    info=$(osc server show "$server" -f json 2>/dev/null) || {
        err "Server '$server' not found"
        exit 1
    }

    echo "$info"
}

wait_for_status() {
    local server="$1"
    local target_status="$2"
    local timeout="${3:-300}"
    local interval=5
    local elapsed=0

    while (( elapsed < timeout )); do
        local current_status
        current_status=$(osc server show "$server" -f value -c status 2>/dev/null)

        if [[ "$current_status" == "$target_status" ]]; then
            return 0
        fi

        if [[ "$current_status" == "ERROR" ]]; then
            err "Server entered ERROR state"
            return 1
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))

        if (( ! QUIET )) && [[ -t 2 ]]; then
            printf "\r   [.] Waiting for %s... (%ds)" "$target_status" "$elapsed" >&2
        fi
    done

    (( ! QUIET )) && [[ -t 2 ]] && printf "\r%80s\r" "" >&2
    err "Timeout waiting for status '$target_status'"
    return 1
}

confirm_action() {
    local server="$1"

    (( FORCE )) && return 0

    echo "" >&2
    echo -e "${C_YELLOW}WARNING: This will cause downtime for the VM.${C_RESET}" >&2
    echo "" >&2
    echo "The following actions will be performed:" >&2
    echo "  1. Stop the instance (if running)" >&2
    echo "  2. Shelve the instance" >&2
    echo "  3. Unshelve with AZ constraint removed" >&2
    if [[ -n "$TARGET_HOST" ]]; then
        echo "  4. Place on host: $TARGET_HOST" >&2
    else
        echo "  4. Scheduler will choose new placement" >&2
    fi
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

do_unpin() {
    local server="$1"
    local server_info
    local server_id status host az

    msg "Gathering server information..."
    server_info=$(get_server_info "$server")

    server_id=$(echo "$server_info" | jq -r '.id')
    status=$(echo "$server_info" | jq -r '.status')
    host=$(echo "$server_info" | jq -r '."OS-EXT-SRV-ATTR:host" // "unknown"')
    az=$(echo "$server_info" | jq -r '."OS-EXT-AZ:availability_zone" // "unknown"')
    local name
    name=$(echo "$server_info" | jq -r '.name')

    # shellcheck disable=SC2034  # Reserved for rollback support
    ORIGINAL_STATUS="$status"
    ORIGINAL_HOST="$host"
    ORIGINAL_AZ="$az"

    echo "" >&2
    echo "  Server:      $name ($server_id)" >&2
    echo "  Status:      $status" >&2
    echo "  Current AZ:  $az" >&2
    echo "  Current Host: $host" >&2
    echo "" >&2

    if [[ "$status" == "SHELVED_OFFLOADED" ]]; then
        ok "Server is already SHELVED_OFFLOADED, skipping to unshelve"
    else
        # Step 1: Stop if running
        if [[ "$status" == "ACTIVE" ]]; then
            if (( DRY_RUN )); then
                step "[DRY-RUN] Would stop server"
            else
                step "Stopping server..."
                osc server stop "$server_id"
                wait_for_status "$server_id" "SHUTOFF" 120
                ok "Server stopped"
            fi
        elif [[ "$status" != "SHUTOFF" ]]; then
            err "Server must be ACTIVE or SHUTOFF to proceed (current: $status)"
            exit 1
        fi

        # Step 2: Shelve
        if (( DRY_RUN )); then
            step "[DRY-RUN] Would shelve server"
        else
            step "Shelving server..."
            osc server shelve "$server_id"
            wait_for_status "$server_id" "SHELVED_OFFLOADED" 300
            ok "Server shelved (SHELVED_OFFLOADED)"
        fi
    fi

    # Step 3: Unshelve with --no-availability-zone
    if (( DRY_RUN )); then
        if [[ -n "$TARGET_HOST" ]]; then
            step "[DRY-RUN] Would unshelve with: --no-availability-zone --host $TARGET_HOST"
        else
            step "[DRY-RUN] Would unshelve with: --no-availability-zone"
        fi
    else
        step "Unshelving with AZ constraint removed..."

        local unshelve_args=("server" "unshelve" "--no-availability-zone")
        if [[ -n "$TARGET_HOST" ]]; then
            unshelve_args+=("--host" "$TARGET_HOST")
        fi
        unshelve_args+=("$server_id")

        osc_api "${unshelve_args[@]}"
        wait_for_status "$server_id" "ACTIVE" 300
        ok "Server unshelved and running"
    fi

    # Final status
    if (( ! DRY_RUN )); then
        echo "" >&2
        msg "Final state:"
        server_info=$(get_server_info "$server_id")
        local new_host new_az new_status
        new_status=$(echo "$server_info" | jq -r '.status')
        new_host=$(echo "$server_info" | jq -r '."OS-EXT-SRV-ATTR:host" // "unknown"')
        new_az=$(echo "$server_info" | jq -r '."OS-EXT-AZ:availability_zone" // "unknown"')

        echo "  Status:      $new_status" >&2
        echo "  New AZ:      $new_az" >&2
        echo "  New Host:    $new_host" >&2
        echo "" >&2

        if [[ "$new_az" != "$ORIGINAL_AZ" ]] || [[ "$new_host" != "$ORIGINAL_HOST" ]]; then
            ok "VM successfully unpinned and relocated"
        else
            ok "VM successfully unpinned (placement unchanged)"
        fi

        echo "" >&2
        echo -e "${C_DIM}The VM can now be cold-migrated to any AZ using:${C_RESET}" >&2
        echo -e "${C_DIM}  openstack server migrate $server_id${C_RESET}" >&2
        echo -e "${C_DIM}  openstack server resize confirm $server_id${C_RESET}" >&2
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    local server=""

    while (( $# )); do
        case "$1" in
            -t|--target-host)
                [[ -n "${2:-}" ]] || { err "Missing argument for $1"; exit 1; }
                TARGET_HOST="$2"
                shift 2
                ;;
            --venv)
                [[ -n "${2:-}" ]] || { err "Missing argument for $1"; exit 1; }
                VENV_PATH="$2"
                shift 2
                ;;
            --dry-run)
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
                if [[ -z "$server" ]]; then
                    server="$1"
                else
                    err "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$server" ]]; then
        err "No server specified"
        echo "" >&2
        show_help
        exit 1
    fi

    check_dependencies
    setup_openstack_client
    check_auth

    if (( DRY_RUN )); then
        msg "DRY-RUN mode enabled - no changes will be made"
    fi

    confirm_action "$server"
    do_unpin "$server"
}

main "$@"
