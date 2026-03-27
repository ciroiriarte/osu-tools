#!/usr/bin/env bash

# Script Name: osu-import-cloud-images.sh
# Description: Import upstream cloud images into OpenStack Glance with
#              standardized metadata properties optimized for virtio/UEFI/q35.
#
# Author: Ciro Iriarte <ciro.iriarte+software@gmail.com>
# Created: 2026-03-12
# Version: 1.2.1
#
# Requirements:
#   - openstack CLI (python-openstackclient) configured with admin credentials
#   - qemu-img (qemu-utils / qemu-tools)
#   - virt-customize (libguestfs-tools) — optional, for guest-agent injection
#   - curl or wget
#   - jq
#
# Changelog:
#   - 2026-03-27: v1.2.1 - Add xz to dependency checks (required for .xz
#                           image decompression). Run check_import_deps
#                           unconditionally so dry-run mode also validates
#                           required tools.
#   - 2026-03-26: v1.2   - Fix guest-agent injection in proxy-only and
#                         restricted-network environments. The libguestfs
#                         appliance SLIRP interface is now brought up via
#                         DHCP before package installation. Proxy env vars
#                         (http_proxy, https_proxy, no_proxy) are forwarded
#                         to the guest package manager, and stripped from the
#                         virt-customize environment to prevent routing
#                         failures inside the appliance. Closes #2.
#   - 2026-03-25: v1.1 - Include point release in os_version property:
#                         Rocky Linux via mirror filename parsing, all
#                         distros via image probing with virt-cat (reads
#                         /etc/debian_version or /etc/os-release). Update
#                         Rocky filename patterns for GenericCloud-Base
#                         naming (Rocky 10+). Closes #1.
#   - 2026-03-12: v1.0 - Initial release. Supports Debian, Ubuntu LTS,
#                         Rocky Linux, openSUSE Leap, Oracle Linux, and RHEL
#                         (manual download). Dynamic mirror discovery, parallel
#                         scanning, RAW conversion for Ceph RBD backends,
#                         and standardized Glance image properties.

set -euo pipefail

# --- Configuration ---
SCRIPT_VERSION="1.2.1"
TIMESTAMP=$(date '+%Y%m%d.%H%M')
CACHE_DIR="/var/tmp/os-cloud-images"
MAX_VERSIONS=2
ARCH="x86_64"

# Glance defaults
DISK_FORMAT="raw"
CONTAINER_FORMAT="bare"
VISIBILITY="public"
OS_LICENSE=""
CUSTOMIZE=1

# Operational defaults
DRY_RUN=0
FORCE=0
ERRORS=0
MODE=""
DISTRO_FILTER=""
DISCOVERY_TMPDIR=""

# --- Colors (disabled when stdout is not a terminal) --------------------------
if [[ -t 1 ]]; then
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
msg()  { echo -e "${C_BOLD}${C_CYAN}::${C_RESET} $*"; }
ok()   { echo -e "   ${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "   ${C_YELLOW}[!]${C_RESET} $*" >&2; }
err()  { echo -e "   ${C_RED}[-]${C_RESET} $*" >&2; }

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
    if [[ -d "$CACHE_DIR" ]]; then
        rm -f "$CACHE_DIR"/*.part
        rm -f "$CACHE_DIR"/*.work.*
    fi
    if [[ -n "$DISCOVERY_TMPDIR" && -d "$DISCOVERY_TMPDIR" ]]; then
        rm -rf "$DISCOVERY_TMPDIR"
    fi
}
trap cleanup EXIT

run() {
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} $*"
    else
        "$@"
    fi
}

# --- Functions ----------------------------------------------------------------

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Version: $SCRIPT_VERSION

Description:
  Import upstream cloud images into OpenStack Glance with standardized
  metadata properties optimized for virtio/UEFI/q35 environments.

  Images are discovered dynamically from distribution mirrors. The last
  $MAX_VERSIONS releases are offered for each distribution family.

  Supported distributions:
    Debian, Ubuntu LTS, Rocky Linux, openSUSE Leap, Oracle Linux

  Workflow per image:
    1. Scan public mirrors for available versions
    2. Download cloud image (cached in $CACHE_DIR)
    3. Optionally inject qemu-guest-agent via virt-customize
    4. Convert to target disk format (default: raw for Ceph RBD)
    5. Upload to Glance with standardized metadata properties

Modes:
  -i, --interactive     Select images interactively (default on TTY)
  -b, --batch           Import all discovered images non-interactively
  -l, --list            List discovered images and exit

Options:
  -f, --format FMT      Disk format: raw (default), qcow2
  -d, --distro NAME     Filter by family: debian ubuntu rocky opensuse oracle
      --visibility VIS  Image visibility: public (default) or private
      --os-license LIC  Override os_license image property (default: "opensource")
      --force           Replace existing images with same name
      --no-customize    Skip virt-customize (guest-agent injection, etc.)
      --arch ARCH       Target architecture (default: x86_64)
  -n, --dry-run         Show what would be done without making changes
  -h, --help            Show this help message
  -v, --version         Show version

Proxy support:
  The script honours http_proxy, https_proxy and no_proxy environment
  variables.  When set, proxy settings are automatically forwarded to the
  guest package manager during image customization (guest-agent injection).
  The libguestfs appliance network is brought up via QEMU SLIRP (built-in
  DHCP), which works regardless of the host's LAN configuration.

Requirements:
  - openstack CLI configured with admin credentials (source openrc.sh)
  - qemu-img
  - virt-customize (optional, for guest-agent injection)
  - curl or wget
  - jq

Examples:
  $0 -l                         List available images
  $0 -i                         Interactive selection
  $0 -b                         Import all discovered images
  $0 -b -d debian               Debian images only
  $0 -b -f qcow2               Use qcow2 format (non-Ceph backends)
  $0 -b --visibility private    Import as private images
  $0 -b --os-license rhel       Override os_license property
  $0 -n -b                      Dry run, all images

  # Behind a proxy:
  export http_proxy=http://proxy:3128 https_proxy=http://proxy:3128
  export no_proxy=localhost,127.0.0.1,.internal.lan
  $0 -b -d debian
EOF
}

# --- Image catalog (populated dynamically by mirror discovery) ----------------
declare -a IMG_KEY=() IMG_NAME=() IMG_URL=() IMG_FAMILY=() IMG_CUSTOMIZE=()
declare -a IMG_DISTRO=() IMG_VERSION=() IMG_ADMIN_USER=() IMG_AUTO_DISK=()
declare -a IMG_LICENSE=()
IMG_COUNT=0

_reg() {
    IMG_KEY+=("$1")
    IMG_NAME+=("$2")
    IMG_URL+=("$3")
    IMG_FAMILY+=("$4")
    IMG_CUSTOMIZE+=("${5:-}")
    IMG_DISTRO+=("${6:-}")
    IMG_VERSION+=("${7:-}")
    IMG_ADMIN_USER+=("${8:-}")
    IMG_AUTO_DISK+=("${9:-true}")
    IMG_LICENSE+=("${10:-opensource}")
    (( IMG_COUNT++ )) || true
}

# --- HTTP / HTML utilities ----------------------------------------------------
fetch_page() {
    local url="$1"
    if command -v curl &>/dev/null; then
        curl -sfL --max-time 15 "$url" 2>/dev/null
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=15 "$url" 2>/dev/null
    fi
}

extract_hrefs() {
    grep -o 'href="[^"]*"' | sed 's/href="//;s/"$//;s|/$||;s|^\./||'
}

# --- Mirror discovery functions -----------------------------------------------
# Each outputs pipe-separated fields:
# KEY|NAME|URL|FAMILY|CUSTOMIZE|OS_DISTRO|OS_VERSION|ADMIN_USER|AUTO_DISK

discover_debian() {
    local base="https://cdimage.debian.org/images/cloud"
    local page
    page=$(fetch_page "$base/") || return 1

    local codenames
    codenames=$(echo "$page" | extract_hrefs | grep -xE '[a-z]+' | grep -vE '^sid$' | sort -u)

    local entries=()
    for codename in $codenames; do
        local listing filename ver
        listing=$(fetch_page "$base/$codename/latest/") || continue
        filename=$(echo "$listing" | extract_hrefs \
            | grep -E '^debian-[0-9]+-generic-amd64\.qcow2$' | head -1)
        if [[ -z "$filename" ]]; then
            filename=$(echo "$listing" | extract_hrefs \
                | grep -E '^debian-[0-9]+-genericcloud-amd64\.qcow2$' | head -1)
        fi
        [[ -n "$filename" ]] || continue
        ver=$(echo "$filename" | sed 's/debian-\([0-9]*\).*/\1/')
        entries+=("${ver}|${codename}|${filename}")
    done

    printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn | head -"$MAX_VERSIONS" \
    | while IFS='|' read -r ver codename filename; do
        echo "debian-${ver}|Debian ${ver} (${codename})|${base}/${codename}/latest/${filename}|debian|guest-agent|debian|${ver}|debian|true|opensource"
    done
}

discover_ubuntu() {
    local base="https://cloud-images.ubuntu.com/releases"
    local page
    page=$(fetch_page "$base/") || return 1

    local versions
    versions=$(echo "$page" | extract_hrefs \
        | grep -xE '[0-9]+\.[0-9]+' \
        | awk -F. '$2=="04" && $1%2==0' \
        | sort -Vr | head -"$MAX_VERSIONS")

    for ver in $versions; do
        local listing filename
        listing=$(fetch_page "$base/$ver/release/") || continue
        filename=$(echo "$listing" | extract_hrefs \
            | grep -E "^ubuntu-${ver}(\.[0-9]+)?-server-cloudimg-amd64\.img$" \
            | sort -V | tail -1)
        [[ -n "$filename" ]] || continue
        local key_ver=${ver//.}
        echo "ubuntu-${key_ver}|Ubuntu ${ver} LTS|${base}/${ver}/release/${filename}|ubuntu|guest-agent|ubuntu|${ver}|ubuntu|true|opensource"
    done
}

discover_rocky() {
    local base="https://dl.rockylinux.org/pub/rocky"
    local page
    page=$(fetch_page "$base/") || return 1

    local versions
    versions=$(echo "$page" | extract_hrefs | grep -xE '[0-9]+' | sort -rn | head -"$MAX_VERSIONS")

    for ver in $versions; do
        local listing
        listing=$(fetch_page "$base/$ver/images/x86_64/") || continue

        # Determine the minor version from versioned filenames in the listing
        # Matches both GenericCloud-Base-9.7-... and GenericCloud-9.7-... patterns
        local minor_ver full_ver
        minor_ver=$(echo "$listing" | extract_hrefs \
            | grep -E "^Rocky-${ver}-GenericCloud(-Base)?-${ver}\.[0-9]+-" \
            | sed "s/Rocky-${ver}-GenericCloud\(-Base\)\?-\(${ver}\.[0-9]\+\)-.*/\2/" \
            | sort -V | tail -1)
        full_ver="${minor_ver:-$ver}"

        # GenericCloud (no LVM) — plain partitioned disk
        # Prefer GenericCloud-Base.latest (Rocky 10+), fall back to GenericCloud.latest (Rocky 9)
        local filename
        filename=$(echo "$listing" | extract_hrefs \
            | grep -E "^Rocky-${ver}-GenericCloud-Base\.latest\.x86_64\.qcow2$" | head -1)
        if [[ -z "$filename" ]]; then
            filename=$(echo "$listing" | extract_hrefs \
                | grep -E "^Rocky-${ver}-GenericCloud\.latest\.x86_64\.qcow2$" | head -1)
        fi
        if [[ -z "$filename" ]]; then
            filename=$(echo "$listing" | extract_hrefs \
                | grep -E "^Rocky-${ver}-GenericCloud(-Base)?-[0-9].*\.x86_64\.qcow2$" \
                | grep -v '\-LVM' \
                | sort -V | tail -1)
        fi
        [[ -n "$filename" ]] && \
            echo "rocky-${ver}|Rocky Linux ${full_ver}|${base}/${ver}/images/x86_64/${filename}|rocky||rocky|${full_ver}|rocky|true|opensource"

        # GenericCloud-LVM — LVM-based root disk
        local lvm_filename
        lvm_filename=$(echo "$listing" | extract_hrefs \
            | grep -E "^Rocky-${ver}-GenericCloud-LVM\.latest\.x86_64\.qcow2$" | head -1)
        if [[ -z "$lvm_filename" ]]; then
            lvm_filename=$(echo "$listing" | extract_hrefs \
                | grep -E "^Rocky-${ver}-GenericCloud-LVM-.*\.x86_64\.qcow2$" \
                | sort -V | tail -1)
        fi
        [[ -n "$lvm_filename" ]] && \
            echo "rocky-${ver}-lvm|Rocky Linux ${full_ver} (LVM)|${base}/${ver}/images/x86_64/${lvm_filename}|rocky|lvm-pvresize|rocky|${full_ver}|rocky|false|opensource"
    done
}

discover_opensuse() {
    local base="https://download.opensuse.org/distribution/leap"
    local page
    page=$(fetch_page "$base/") || return 1

    local versions
    versions=$(echo "$page" | extract_hrefs \
        | sed -n 's|^[0-9]*\.[0-9]*$|&|p' \
        | awk -F. '$1 >= 15 && $1 < 42' \
        | sort -Vr)

    local found=0
    for ver in $versions; do
        (( found >= MAX_VERSIONS )) && break
        local url=""

        local listing filename=""
        listing=$(fetch_page "$base/$ver/appliances/") 2>/dev/null || true
        if [[ -n "$listing" ]]; then
            filename=$(echo "$listing" | extract_hrefs \
                | grep -E "x86_64-.*Cloud-Build.*\.qcow2$" | grep -v 'encrypt\|xen' | head -1)
            if [[ -z "$filename" ]]; then
                for pattern in \
                    "openSUSE-Leap-${ver}-Minimal-VM.x86_64-Cloud.qcow2" \
                    "Leap-${ver}-Minimal-VM.x86_64-Cloud.qcow2"; do
                    filename=$(echo "$listing" | extract_hrefs | grep -F "$pattern" | head -1)
                    [[ -n "$filename" ]] && break
                done
            fi
            [[ -n "$filename" ]] && url="${base}/${ver}/appliances/${filename}"
        fi

        # Fall back to Cloud:Images OBS repo
        if [[ -z "$url" ]]; then
            local ci_base="https://download.opensuse.org/repositories/Cloud:/Images:/Leap_${ver}/images"
            local ci_listing
            ci_listing=$(fetch_page "$ci_base/") 2>/dev/null || true
            if [[ -n "$ci_listing" ]]; then
                local ci_filename
                ci_filename=$(echo "$ci_listing" | extract_hrefs \
                    | grep -E 'x86_64-.*-NoCloud-Build.*\.qcow2$' | head -1)
                if [[ -z "$ci_filename" ]]; then
                    ci_filename=$(echo "$ci_listing" | extract_hrefs \
                        | grep -F "x86_64-NoCloud.qcow2" | grep -v '\.sha256' | head -1)
                fi
                [[ -n "$ci_filename" ]] && url="${ci_base}/${ci_filename}"
            fi
        fi

        [[ -n "$url" ]] || continue
        echo "opensuse-${ver}|openSUSE Leap ${ver}|${url}|opensuse|ptp-fix|opensuse|${ver}|opensuse|true|opensource"
        (( found++ )) || true
    done
}

discover_oracle() {
    local base="https://yum.oracle.com"
    local found=0

    for major in 10 9 8; do
        (( found >= MAX_VERSIONS )) && break
        local json
        json=$(fetch_page "$base/templates/OracleLinux/ol${major}-template.json") || continue

        local filename
        filename=$(echo "$json" | grep -o '"OL[0-9]*U[0-9]*_x86_64-kvm-b[0-9]*\.qcow2"' | tr -d '"' | head -1)
        [[ -n "$filename" ]] || continue

        local basepath
        basepath=$(echo "$json" | grep -o '"/templates/OracleLinux/OL'"$major"'/[^"]*"' | tr -d '"' | head -1)
        [[ -n "$basepath" ]] || continue

        local update
        update=$(echo "$filename" | sed 's/OL[0-9]*U\([0-9]*\).*/\1/')

        echo "oracle-${major}|Oracle Linux ${major}.${update}|${base}${basepath}/${filename}|oracle||oel|${major}.${update}|oracle|false|opensource"
        (( found++ )) || true
    done
}

# --- Build catalog from mirrors (parallel) ------------------------------------
build_catalog() {
    local families
    if [[ -n "$DISTRO_FILTER" ]]; then
        families=("$DISTRO_FILTER")
    else
        families=(debian ubuntu rocky opensuse oracle)
    fi

    DISCOVERY_TMPDIR=$(mktemp -d)

    msg "Scanning distribution mirrors..."

    for family in "${families[@]}"; do
        ( set +eo pipefail; discover_"${family}" ) > "$DISCOVERY_TMPDIR/$family" 2>/dev/null &
    done
    wait

    for family in "${families[@]}"; do
        if [[ -s "$DISCOVERY_TMPDIR/$family" ]]; then
            local count=0
            while IFS='|' read -r key name url fam customize distro version admin_user auto_disk license; do
                [[ -n "$url" ]] || continue
                _reg "$key" "$name" "$url" "$fam" "$customize" "$distro" "$version" "$admin_user" "$auto_disk" "$license"
                (( count++ )) || true
            done < "$DISCOVERY_TMPDIR/$family"
            ok "${family}: ${count} image(s)"
        else
            warn "${family}: no images found"
        fi
    done
    echo

    rm -rf "$DISCOVERY_TMPDIR"
    DISCOVERY_TMPDIR=""
}

# --- Dependency checks --------------------------------------------------------
check_fetch_deps() {
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        err "curl or wget is required for mirror scanning."
        exit 1
    fi
}

check_import_deps() {
    local missing=()
    for cmd in openstack qemu-img jq xz; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        exit 1
    fi
    if (( CUSTOMIZE )); then
        if ! command -v virt-customize &>/dev/null; then
            warn "virt-customize not found — image customization disabled"
            warn "Install libguestfs-tools for guest-agent injection"
            CUSTOMIZE=0
        fi
    fi
}

# --- Download -----------------------------------------------------------------
download_image() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        ok "Cached: $(basename "$dest")"
        return 0
    fi
    msg "Downloading $(basename "$dest")..."
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} download → $(basename "$dest")"
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    local attempt rc=1
    for attempt in 1 2 3; do
        if (( attempt > 1 )); then
            warn "Retry ${attempt}/3: $(basename "$dest")"
            rm -f "${dest}.part"
            sleep 2
        fi
        if command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "${dest}.part" "$url" && { rc=0; break; }
        elif command -v wget &>/dev/null; then
            wget -q --show-progress -O "${dest}.part" "$url" && { rc=0; break; }
        fi
    done
    if (( rc )); then
        rm -f "${dest}.part"
        return 1
    fi
    mv "${dest}.part" "$dest"
}

# --- Customize ----------------------------------------------------------------

# Run virt-customize with proxy env vars stripped from the environment.
# Prevents http_proxy/https_proxy from leaking into the libguestfs appliance
# where they cause "Network is unreachable" errors (the appliance cannot route
# to the host's proxy IP directly).
run_virt_customize() {
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} sudo virt-customize $*"
    else
        sudo env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
            -u no_proxy -u NO_PROXY \
            virt-customize "$@"
    fi
}

# Build a shell snippet that brings up networking inside the libguestfs
# appliance (QEMU SLIRP) and optionally configures the guest's package
# manager to use a proxy.
#
# The libguestfs appliance relies on QEMU user-mode (SLIRP) networking,
# which provides a built-in DHCP server regardless of the host's LAN.
# However, the appliance may fail to auto-configure the interface (e.g.
# missing systemd-network user), so we bring it up explicitly via dhclient.
#
# Once SLIRP is up, outbound traffic is NAT-ed through the host, so the
# proxy IP is reachable from inside the guest.
_build_guest_net_setup() {
    local family="$1"
    local script=""

    # Bring up SLIRP networking via DHCP
    script+="ip link set eth0 up && dhclient eth0"

    # Inject proxy configuration for the guest's package manager
    if [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}" ]]; then
        local proxy_url="${http_proxy:-${HTTP_PROXY:-}}"
        local proxy_https="${https_proxy:-${HTTPS_PROXY:-${proxy_url}}}"
        local no_proxy_val="${no_proxy:-${NO_PROXY:-}}"

        case "$family" in
            debian|ubuntu)
                script+=" && printf '"
                [[ -n "$proxy_url" ]] && \
                    script+="Acquire::http::Proxy \"${proxy_url}\";\n"
                [[ -n "$proxy_https" ]] && \
                    script+="Acquire::https::Proxy \"${proxy_https}\";\n"
                if [[ -n "$no_proxy_val" ]]; then
                    # Convert comma-separated no_proxy to apt Direct rules
                    local IFS=','
                    for host in $no_proxy_val; do
                        host=$(echo "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        [[ -z "$host" ]] && continue
                        script+="Acquire::http::Proxy::${host} \"DIRECT\";\n"
                        script+="Acquire::https::Proxy::${host} \"DIRECT\";\n"
                    done
                fi
                script+="' > /etc/apt/apt.conf.d/99proxy"
                ;;
        esac
    fi

    printf '%s' "$script"
}

# Build the cleanup snippet that removes transient files written into the
# guest during customization (proxy config, DHCP-generated resolv.conf).
_build_guest_net_cleanup() {
    local family="$1"
    local script="rm -f /etc/resolv.conf"

    case "$family" in
        debian|ubuntu)
            script+=" /etc/apt/apt.conf.d/99proxy"
            ;;
    esac

    printf '%s' "$script"
}

customize_image() {
    local image="$1" action="$2" family="$3"
    (( CUSTOMIZE )) || return 0
    [[ -n "$action" ]] || return 0
    case "$action" in
        guest-agent)
            msg "Injecting qemu-guest-agent..."
            local net_setup net_cleanup install_cmd
            net_setup=$(_build_guest_net_setup "$family")
            net_cleanup=$(_build_guest_net_cleanup "$family")

            case "$family" in
                debian|ubuntu)
                    install_cmd="export DEBIAN_FRONTEND=noninteractive"
                    install_cmd+=" && apt-get -q -y update"
                    install_cmd+=" && apt-get -q -y -o Dpkg::Options::=--force-confnew install qemu-guest-agent"
                    ;;
                *)
                    install_cmd="command -v dnf &>/dev/null && dnf -y install qemu-guest-agent"
                    install_cmd+=" || command -v yum &>/dev/null && yum -y install qemu-guest-agent"
                    install_cmd+=" || command -v zypper &>/dev/null && zypper -n install qemu-guest-agent"
                    ;;
            esac

            run_virt_customize -a "$image" \
                --run-command "${net_setup} && ${install_cmd} && ${net_cleanup}"
            ;;
        lvm-pvresize)
            msg "Injecting cloud-init pvresize bootcmd..."
            local ci_cfg
            ci_cfg=$(cat <<'CIEOF'
# Grow the PV to fill available disk space after volume resize.
# LV allocation is left to the user (lvresize/lvcreate).
bootcmd:
  - |
    for pv in $(pvs --noheadings -o pv_name 2>/dev/null); do
      pvresize "$pv" 2>/dev/null || true
    done
CIEOF
)
            run_virt_customize -a "$image" \
                --write /etc/cloud/cloud.cfg.d/99-pvresize.cfg:"$ci_cfg"
            ;;
        ptp-fix)
            msg "Enabling ptp_kvm module..."
            run_virt_customize -a "$image" \
                --write /etc/modules-load.d/ptp_kvm.conf:ptp_kvm
            ;;
    esac

    # virt-customize populates /etc/machine-id during its "Setting the
    # machine ID" phase.  Truncate it back to zero so cloud-init / systemd
    # regenerate a unique ID on first boot.  Cloud images ship with an
    # empty machine-id by default, so this is only needed after
    # virt-customize has touched the image.
    msg "Truncating /etc/machine-id..."
    run_virt_customize -a "$image" \
        --run-command '[ -f /etc/machine-id ] && truncate -s 0 /etc/machine-id || true'
}

# --- Probe image for OS version ----------------------------------------------
probe_image_version() {
    local image="$1" distro="$2"
    local version=""

    # Debian: /etc/debian_version has the precise point release (e.g. 12.13)
    if [[ "$distro" == "debian" ]]; then
        version=$(sudo virt-cat -a "$image" /etc/debian_version 2>/dev/null \
            | tr -d '[:space:]')
        if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
            echo "$version"
            return 0
        fi
    fi

    # Generic: parse VERSION_ID from /etc/os-release
    local os_release
    os_release=$(sudo virt-cat -a "$image" /etc/os-release 2>/dev/null) || return 1
    version=$(echo "$os_release" | sed -n 's/^VERSION_ID="\?\([^"]*\)"\?$/\1/p' | head -1)

    if [[ -n "$version" ]]; then
        echo "$version"
        return 0
    fi

    return 1
}

# --- Convert image to target format ------------------------------------------
convert_image() {
    local src="$1" dest="$2" src_format="$3" dest_format="$4"
    if [[ "$src_format" == "$dest_format" ]]; then
        cp "$src" "$dest"
        return 0
    fi
    msg "Converting $(basename "$src") → ${dest_format}..."
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} qemu-img convert -f ${src_format} -O ${dest_format} $(basename "$src") $(basename "$dest")"
        return 0
    fi
    qemu-img convert -f "$src_format" -O "$dest_format" "$src" "$dest"
}

# --- Check if Glance image exists by name ------------------------------------
glance_image_exists() {
    local name="$1"
    local result
    result=$(openstack image list --name "$name" -f json 2>/dev/null || echo '[]')
    local count
    count=$(echo "$result" | jq 'length')
    (( count > 0 ))
}

# --- Delete existing Glance image by name ------------------------------------
glance_image_delete() {
    local name="$1"
    local ids
    ids=$(openstack image list --name "$name" -f json 2>/dev/null \
        | jq -r '.[].ID' 2>/dev/null || true)
    for id in $ids; do
        openstack image delete "$id" 2>/dev/null || true
    done
}

# --- Build Glance property arguments -----------------------------------------
build_glance_properties() {
    local idx="$1"
    local -a props=()

    # Standard hardware properties (virtio/UEFI/q35 optimized)
    props+=(--property os_type='linux')
    props+=(--property hw_qemu_guest_agent='true')
    props+=(--property os_require_quiesce='true')
    props+=(--property hw_require_fsfreeze='true')
    props+=(--property hw_machine_type='q35')
    props+=(--property hw_firmware_type='uefi')
    props+=(--property hw_serial_port_count='1')
    props+=(--property hw_vif_model='virtio')
    props+=(--property hw_vif_multiqueue_enabled='true')
    props+=(--property hw_virtio_packed_ring='true')
    props+=(--property hw_scsi_model='virtio-scsi')
    props+=(--property hw_disk_bus='scsi')
    props+=(--property hw_video_model='virtio')

    # Per-distro properties
    if [[ -n "${IMG_DISTRO[$idx]}" ]]; then
        props+=(--property os_distro="${IMG_DISTRO[$idx]}")
    fi
    if [[ -n "${IMG_VERSION[$idx]}" ]]; then
        props+=(--property os_version="${IMG_VERSION[$idx]}")
    fi
    if [[ -n "${IMG_ADMIN_USER[$idx]}" ]]; then
        props+=(--property os_admin_user="${IMG_ADMIN_USER[$idx]}")
    fi
    props+=(--property has_auto_disk_config="${IMG_AUTO_DISK[$idx]:-true}")

    # os_license: CLI override takes precedence, otherwise per-distro default
    if [[ -n "$OS_LICENSE" ]]; then
        props+=(--property os_license="$OS_LICENSE")
    else
        props+=(--property os_license="${IMG_LICENSE[$idx]:-opensource}")
    fi

    printf '%s\n' "${props[@]}"
}

# --- Import a single image ----------------------------------------------------
import_single() {
    local idx="$1"
    local key="${IMG_KEY[$idx]}"
    local name="${IMG_NAME[$idx]}"
    local url="${IMG_URL[$idx]}"
    local customize="${IMG_CUSTOMIZE[$idx]}"
    local safe_arch="${ARCH//_/-}"
    local image_name="ci-${key}-${safe_arch}-${TIMESTAMP}"
    local filename
    filename=$(basename "$url")

    msg "Importing ${C_BOLD}${name}${C_RESET} → ${image_name}"

    # Check for existing image
    if glance_image_exists "$image_name"; then
        if (( FORCE )); then
            warn "Image '${image_name}' exists — deleting (--force)"
            if (( ! DRY_RUN )); then
                glance_image_delete "$image_name"
            fi
        else
            warn "Image '${image_name}' exists — skipping (use --force to replace)"
            return 0
        fi
    fi

    # Download
    download_image "$url" "${CACHE_DIR}/${filename}" || {
        err "Download failed: ${name}"; return 1
    }

    local image_file="${CACHE_DIR}/${filename}"

    # Decompress if needed
    if [[ "$filename" == *.xz ]]; then
        local decompressed="${image_file%.xz}"
        if [[ ! -f "$decompressed" ]]; then
            msg "Decompressing $(basename "$filename")..."
            if (( DRY_RUN )); then
                echo -e "   ${C_YELLOW}[dry-run]${C_RESET} xz -dk ${image_file}"
            else
                xz -dk "$image_file"
            fi
        else
            ok "Cached: $(basename "$decompressed")"
        fi
        image_file="$decompressed"
    fi

    # Work on a copy
    local src_format="qcow2"
    local work_ext="qcow2"
    local work_image="${CACHE_DIR}/${key}.work.${work_ext}"
    if (( ! DRY_RUN )); then
        cp "$image_file" "$work_image"
    fi

    # Probe image for precise OS version (e.g. Debian point release)
    if (( ! DRY_RUN )) && command -v virt-cat &>/dev/null; then
        local probed_ver
        probed_ver=$(probe_image_version "$work_image" "${IMG_DISTRO[$idx]}") || true
        if [[ -n "$probed_ver" && "$probed_ver" != "${IMG_VERSION[$idx]}" ]]; then
            ok "Detected os_version: ${probed_ver} (was ${IMG_VERSION[$idx]})"
            IMG_VERSION[$idx]="$probed_ver"
        fi
    fi

    # Customize (guest-agent injection, ptp_kvm, etc.)
    customize_image "$work_image" "$customize" "${IMG_FAMILY[$idx]}"

    # Convert to target format
    local upload_file="$work_image"
    if [[ "$DISK_FORMAT" != "$src_format" ]]; then
        upload_file="${CACHE_DIR}/${key}.work.${DISK_FORMAT}"
        convert_image "$work_image" "$upload_file" "$src_format" "$DISK_FORMAT"
    fi

    # Build property arguments
    local -a prop_args=()
    while IFS= read -r line; do
        prop_args+=("$line")
    done < <(build_glance_properties "$idx")

    # Upload to Glance
    msg "Uploading to Glance (format: ${DISK_FORMAT}, visibility: ${VISIBILITY})..."
    if (( DRY_RUN )); then
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET} openstack image create \\"
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET}   --file $(basename "$upload_file") \\"
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET}   --disk-format ${DISK_FORMAT} --container-format ${CONTAINER_FORMAT} \\"
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET}   --${VISIBILITY} \\"
        local i
        for (( i=0; i<${#prop_args[@]}; i+=2 )); do
            echo -e "   ${C_YELLOW}[dry-run]${C_RESET}   ${prop_args[$i]} ${prop_args[$((i+1))]} \\"
        done
        echo -e "   ${C_YELLOW}[dry-run]${C_RESET}   ${image_name}"
    else
        local -a cmd=(openstack image create
            --file "$upload_file"
            --disk-format "$DISK_FORMAT"
            --container-format "$CONTAINER_FORMAT"
            "--${VISIBILITY}"
            --progress
            "${prop_args[@]}"
            "$image_name"
        )

        local result
        result=$("${cmd[@]}" 2>&1) || {
            err "Glance upload failed for ${name}"
            echo "$result" >&2
            rm -f "$work_image" "$upload_file"
            return 1
        }
        ok "Uploaded successfully"

        # Show image ID
        local image_id
        image_id=$(openstack image show "$image_name" -f json 2>/dev/null \
            | jq -r '.id // empty' 2>/dev/null || true)
        if [[ -n "$image_id" ]]; then
            ok "Image ID: ${image_id}"
        fi
    fi

    # Cleanup work files
    rm -f "$work_image"
    [[ "$upload_file" != "$work_image" ]] && rm -f "$upload_file"

    ok "Image ${C_BOLD}${image_name}${C_RESET} ready"
}

# --- Catalog display ----------------------------------------------------------
list_catalog() {
    if (( IMG_COUNT == 0 )); then
        err "No images discovered."
        exit 1
    fi
    local safe_arch="${ARCH//_/-}"
    printf "\n  ${C_BOLD}%-4s  %-28s  %-42s  %s${C_RESET}\n" \
        "#" "NAME" "IMAGE NAME" "URL"
    printf "  %-4s  %-28s  %-42s  %s\n" \
        "---" "----------------------------" "------------------------------------------" "---"
    for (( i=0; i<IMG_COUNT; i++ )); do
        printf "  %-4d  %-28s  %-42s  %s\n" \
            $(( i + 1 )) "${IMG_NAME[$i]}" \
            "ci-${IMG_KEY[$i]}-${safe_arch}-${TIMESTAMP}" "${IMG_URL[$i]}"
    done
    echo
}

# --- Interactive selection ----------------------------------------------------
interactive_select() {
    list_catalog
    echo -e "  ${C_BOLD}Select images (space-separated numbers," \
            "${C_CYAN}a${C_RESET}${C_BOLD}=all," \
            "${C_CYAN}q${C_RESET}${C_BOLD}=quit):${C_RESET}"
    read -r -p "  > " selection

    case "$selection" in
        q|Q) echo "Aborted."; exit 0 ;;
        a|A)
            for (( i=0; i<IMG_COUNT; i++ )); do
                SELECTED+=("$i")
            done
            return
            ;;
    esac

    for num in $selection; do
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= IMG_COUNT )); then
            SELECTED+=("$(( num - 1 ))")
        else
            warn "Invalid selection: $num"
        fi
    done

    if (( ${#SELECTED[@]} == 0 )); then
        err "No valid images selected."
        exit 1
    fi
}

# --- Argument Parsing ---------------------------------------------------------
OPTIONS=$(getopt -o hvibld:f:n \
    --long help,version,interactive,batch,list,distro:,format:,visibility:,os-license:,force,no-customize,arch:,dry-run \
    -n "$0" -- "$@")
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
        -i|--interactive)
            MODE="interactive"
            shift
            ;;
        -b|--batch)
            MODE="batch"
            shift
            ;;
        -l|--list)
            MODE="list"
            shift
            ;;
        -d|--distro)
            DISTRO_FILTER="$2"
            shift 2
            ;;
        -f|--format)
            DISK_FORMAT="$2"
            shift 2
            ;;
        --visibility)
            VISIBILITY="$2"
            shift 2
            ;;
        --os-license)
            OS_LICENSE="$2"
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --no-customize)
            CUSTOMIZE=0
            shift
            ;;
        --arch)
            ARCH="$2"
            shift 2
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

# --- Validation ---------------------------------------------------------------
if [[ -z "$MODE" ]]; then
    [[ -t 0 && -t 1 ]] && MODE="interactive" || MODE="batch"
fi

if [[ -n "$DISTRO_FILTER" ]]; then
    case "$DISTRO_FILTER" in
        debian|ubuntu|rocky|opensuse|oracle) ;;
        *) err "Unknown distro family: $DISTRO_FILTER"; exit 1 ;;
    esac
fi

case "$DISK_FORMAT" in
    raw|qcow2) ;;
    *) err "Unsupported disk format: $DISK_FORMAT (use raw or qcow2)"; exit 1 ;;
esac

case "$VISIBILITY" in
    public|private) ;;
    *) err "Invalid visibility: $VISIBILITY (use public or private)"; exit 1 ;;
esac

case "$ARCH" in
    x86_64) ;;
    *) err "Unsupported architecture: $ARCH (currently only x86_64)"; exit 1 ;;
esac

# --- Main execution -----------------------------------------------------------
check_fetch_deps
build_catalog

if [[ "$MODE" == "list" ]]; then
    list_catalog
    exit 0
fi

check_import_deps

declare -a SELECTED=()

case "$MODE" in
    interactive) interactive_select ;;
    batch)
        for (( i=0; i<IMG_COUNT; i++ )); do
            SELECTED+=("$i")
        done
        ;;
esac

if (( ${#SELECTED[@]} == 0 )); then
    err "No images to import."
    exit 1
fi

(( DRY_RUN )) && echo -e "${C_YELLOW}=== DRY RUN MODE ===${C_RESET}\n"

msg "Importing ${#SELECTED[@]} image(s)..."
echo

IMPORT_CURRENT=0
IMPORT_TOTAL=${#SELECTED[@]}

for idx in "${SELECTED[@]}"; do
    (( IMPORT_CURRENT++ )) || true
    progress "$IMPORT_CURRENT" "$IMPORT_TOTAL" "${IMG_NAME[$idx]}"
    echo >&2
    import_single "$idx" || (( ERRORS++ )) || true
    echo
done

if (( ERRORS )); then
    err "${ERRORS} image(s) failed."
    exit 1
else
    msg "Done. All images imported successfully."
fi
