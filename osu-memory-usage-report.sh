#!/usr/bin/env bash

# Script Name: osu-memory-usage-report.sh
# Description: Accurate summary of OpenStack resources per domain with per-project
#              breakdown: instances, vCPUs, RAM, and volumes.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2025-12-24
# Version: 0.2
#
# Requirements:
#   - openstack CLI configured with admin or domain admin scope
#   - jq installed
#   - A sourced OpenStack credentials file (e.g., openrc.sh)
#
# Changelog:
#   - 2025-12-24: v0.1 - Initial release.
#   - 2026-02-17: v0.2 - Renamed to memory-usage-report-openstack.sh
#                        (later renamed to osu-memory-usage-report.sh).
#                        Added help option (-h/--help).
#                        Fixed separator line width to match table (60 → 77 chars).
#                        Fixed server_ids array population to use mapfile -t.
#                        Fixed duplicate .id alternative in jq flavor extraction.
#                        Added error resilience for server/volume API calls.
#                        Moved progress messages to stderr for clean stdout.
#                        Added per-project progress output to stderr.
#                        Fixed column labels: RAM (MiB), Size (GiB).
#                        Added domain name to table header.

set -euo pipefail

SCRIPT_VERSION="0.2"

# --- Functions ---

show_help() {
    echo "Usage: $0 [-h|--help] [-v|--version] <domain_name>"
    echo ""
    echo "Version: $SCRIPT_VERSION"
    echo ""
    echo "Description:"
    echo " Provides an accurate summary of OpenStack resources per domain,"
    echo " with a per-project breakdown. Reports:"
    echo "   - Instance count, vCPU and RAM allocation per project"
    echo "   - Volume count and total volume size per project"
    echo "   - Domain-wide totals"
    echo ""
    echo "Arguments:"
    echo " domain_name    Name of the OpenStack domain to summarize"
    echo ""
    echo "Options:"
    echo " -h, --help     Display this help message"
    echo " -v, --version  Display version information"
    echo ""
    echo "Requirements:"
    echo " - openstack CLI configured with admin or domain admin scope"
    echo " - jq"
    echo " - Sourced OpenStack credentials (e.g.: source ~/openrc.sh)"
}

# --- Argument Parsing ---
OPTIONS=$(getopt -o hv --long help,version -n "$0" -- "$@")
if [ $? -ne 0 ]; then
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

DOMAIN_NAME="${1:-}"
if [[ -z "$DOMAIN_NAME" ]]; then
    show_help >&2
    exit 1
fi

# --- Dependency Checks ---
command -v openstack >/dev/null 2>&1 || { echo "ERROR: 'openstack' CLI not found." >&2; exit 1; }
command -v jq        >/dev/null 2>&1 || { echo "ERROR: 'jq' not found."            >&2; exit 1; }

# --- Flavor cache (maps flavor_id → vcpus / ram) ---
declare -A FLAVOR_VCPUS
declare -A FLAVOR_RAM

get_flavor_info() {
    local flavor_id="$1"
    if [[ -z "${FLAVOR_VCPUS[$flavor_id]:-}" ]]; then
        local fjson
        fjson=$(openstack flavor show "$flavor_id" -f json 2>/dev/null || true)
        if [[ -z "$fjson" ]]; then
            FLAVOR_VCPUS["$flavor_id"]=0
            FLAVOR_RAM["$flavor_id"]=0
            return
        fi
        FLAVOR_VCPUS["$flavor_id"]=$(echo "$fjson" | jq '.vcpus // 0')
        FLAVOR_RAM["$flavor_id"]=$(echo "$fjson" | jq '.ram // 0')
    fi
}

sum_project_compute() {
    local project_id="$1"
    local servers_json
    # Tolerate projects that are inaccessible (returns empty list)
    servers_json=$(openstack server list --project "$project_id" -f json 2>/dev/null || echo '[]')
    local instance_count
    instance_count=$(echo "$servers_json" | jq 'length')
    local total_vcpus=0
    local total_ram=0

    if [[ "$instance_count" -gt 0 ]]; then
        local server_ids
        mapfile -t server_ids < <(echo "$servers_json" | jq -r '.[].ID')
        for sid in "${server_ids[@]}"; do
            local sjson flavor_id
            sjson=$(openstack server show "$sid" -f json 2>/dev/null || echo '{}')
            [[ "$sjson" == '{}' ]] && continue

            # Extract flavor identifier; OpenStack clouds vary in how they expose it
            flavor_id=$(echo "$sjson" | jq -r '.flavor | .id? // .ID? // .FlavorID? // empty')
            if [[ -z "$flavor_id" || "$flavor_id" == "null" ]]; then
                flavor_id=$(echo "$sjson" | jq -r '.flavor | .original_name? // empty')
            fi
            if [[ -z "$flavor_id" || "$flavor_id" == "null" ]]; then
                flavor_id=$(echo "$sjson" | jq -r '.Flavor? // .flavor? // empty')
            fi
            [[ -z "$flavor_id" || "$flavor_id" == "null" ]] && continue

            get_flavor_info "$flavor_id"
            total_vcpus=$((total_vcpus + ${FLAVOR_VCPUS[$flavor_id]:-0}))
            total_ram=$((total_ram + ${FLAVOR_RAM[$flavor_id]:-0}))
        done
    fi

    echo "${instance_count},${total_vcpus},${total_ram}"
}

sum_project_volumes() {
    local project_id="$1"
    local vjson
    # Tolerate projects that are inaccessible (returns empty list)
    vjson=$(openstack volume list --project "$project_id" -f json 2>/dev/null || echo '[]')
    local vcount vsum
    vcount=$(echo "$vjson" | jq 'length')
    vsum=$(echo "$vjson" | jq '[.[].Size] | add // 0')
    echo "${vcount},${vsum}"
}

# --- Main ---

echo "Fetching projects for domain: $DOMAIN_NAME ..." >&2
PROJECTS_JSON=$(openstack project list --domain "$DOMAIN_NAME" -f json)
PROJECT_COUNT=$(echo "$PROJECTS_JSON" | jq 'length')

if [[ "$PROJECT_COUNT" -eq 0 ]]; then
    echo "No projects found in domain '$DOMAIN_NAME'." >&2
    exit 0
fi

mapfile -t PROJECT_IDS   < <(echo "$PROJECTS_JSON" | jq -r '.[].ID')
mapfile -t PROJECT_NAMES < <(echo "$PROJECTS_JSON" | jq -r '.[].Name')

# Table widths: 30+1+10+1+10+1+10+1+10+1+12 = 77
SEP_DASH=$(printf '%*s' 77 '' | tr ' ' '-')
SEP_EQ=$(printf '%*s' 77 '' | tr ' ' '=')

echo ""
echo "Domain: $DOMAIN_NAME"
echo "$SEP_DASH"
printf "%-30s %-10s %-10s %-10s %-10s %-12s\n" \
    "Project" "Instances" "vCPUs" "RAM (MiB)" "Volumes" "Size (GiB)"
echo "$SEP_DASH"

TOTAL_INSTANCES=0
TOTAL_VCPUS=0
TOTAL_RAM=0
TOTAL_VOLUMES=0
TOTAL_VOLUME_SIZE=0

for idx in "${!PROJECT_IDS[@]}"; do
    PROJECT_ID="${PROJECT_IDS[$idx]}"
    PROJECT_NAME="${PROJECT_NAMES[$idx]}"

    echo "  [$((idx + 1))/$PROJECT_COUNT] $PROJECT_NAME ..." >&2

    IFS=',' read -r INSTANCES VCPUS RAM <<< "$(sum_project_compute "$PROJECT_ID")"
    IFS=',' read -r VOLS VSIZE         <<< "$(sum_project_volumes  "$PROJECT_ID")"

    printf "%-30s %-10s %-10s %-10s %-10s %-12s\n" \
        "$PROJECT_NAME" "$INSTANCES" "$VCPUS" "$RAM" "$VOLS" "$VSIZE"

    TOTAL_INSTANCES=$((TOTAL_INSTANCES + INSTANCES))
    TOTAL_VCPUS=$((TOTAL_VCPUS + VCPUS))
    TOTAL_RAM=$((TOTAL_RAM + RAM))
    TOTAL_VOLUMES=$((TOTAL_VOLUMES + VOLS))
    TOTAL_VOLUME_SIZE=$((TOTAL_VOLUME_SIZE + VSIZE))
done

echo "$SEP_DASH"
printf "%-30s %-10s %-10s %-10s %-10s %-12s\n" \
    "TOTAL" "$TOTAL_INSTANCES" "$TOTAL_VCPUS" "$TOTAL_RAM" "$TOTAL_VOLUMES" "$TOTAL_VOLUME_SIZE"
echo "$SEP_EQ"
