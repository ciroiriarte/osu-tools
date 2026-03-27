# OSU Tools — OpenStack User Tools

A collection of Bash wrappers and tools to simplify OpenStack usage via the openstack CLI and APIs.

[![License: GPL v3](https://img.shields.io/github/license/ciroiriarte/osu-tools)](LICENSE)
[![Shell](https://img.shields.io/badge/language-Bash-green)](https://www.gnu.org/software/bash/)

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Getting Started](#-getting-started)
- [Scripts](#-scripts)
  - [osu-import-cloud-images.sh](#-osu-import-cloud-imagessh)
  - [osu-memory-usage-report.sh](#-osu-memory-usage-reportsh)
  - [osu-retype-vdisk.sh](#-osu-retype-vdisksh)
- [Documentation](#-documentation)
- [Contributing](#-contributing)
- [License](#-license)
- [Author](#-author)

---

## 🔍 Overview

| Script | Version | Created | Updated |
|---|---|---|---|
| `osu-import-cloud-images.sh` | ![v1.2](https://img.shields.io/badge/version-1.2-blue) | 2026-03-12 | 2026-03-26 |
| `osu-memory-usage-report.sh` | ![v0.2](https://img.shields.io/badge/version-0.2-orange) | 2025-12-24 | 2026-03-26 |
| `osu-retype-vdisk.sh` | ![v0.1](https://img.shields.io/badge/version-0.1-orange) | 2026-03-27 | 2026-03-27 |

All scripts support `--version` / `-v` and `--help` / `-h` flags.

---

## 🚀 Getting Started

### Prerequisites

- Bash (modern version with associative array support)
- `openstack` CLI (python-openstackclient) configured with appropriate credentials
- Script-specific dependencies are listed in each script section below

### Installation

Clone the repository:

```bash
git clone https://github.com/ciroiriarte/osu-tools.git
cd osu-tools
```

Scripts are standalone and can be run directly or copied to a directory in your `PATH`:

```bash
chmod +x <script-name>.sh
cp <script-name>.sh /usr/local/bin/
```

---

## 📜 Scripts

### 🔍 `osu-import-cloud-images.sh`

Imports upstream cloud images into OpenStack Glance with standardized metadata properties optimized for virtio/UEFI/q35 environments. Dynamically discovers the latest releases from distribution mirrors, optionally customizes them, converts to the target disk format, and uploads with full Glance metadata.

Supported distributions: **Debian**, **Ubuntu LTS**, **Rocky Linux** (plain and LVM), **openSUSE Leap**, **Oracle Linux**.

Default disk format is **raw** (recommended for Ceph RBD backends).

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient, configured with admin credentials)
  - `qemu-img` (qemu-utils / qemu-tools)
  - `jq`
  - `curl` or `wget`
- Optional:
  - `virt-customize` (libguestfs-tools) — for image customization (see below)
- A sourced OpenStack credentials file (e.g., `openrc.sh`)

#### 🔧 Per-Distribution Customizations

When `virt-customize` is available (and `--no-customize` is not used), the following customizations are applied:

| Distribution | Customization | Details |
|---|---|---|
| Debian, Ubuntu | `guest-agent` | Installs `qemu-guest-agent` package (not included by default) |
| openSUSE Leap | `ptp-fix` | Injects `/etc/modules-load.d/ptp_kvm.conf` to load the `ptp_kvm` kernel module |
| Rocky Linux (LVM) | `lvm-pvresize` | Injects a cloud-init bootcmd (`/etc/cloud/cloud.cfg.d/99-pvresize.cfg`) that runs `pvresize` on all PVs at every boot, so the VG gains free space after a volume resize. LV allocation (`lvresize`/`lvcreate`) is left to the user. |
| Rocky Linux, Oracle Linux | — | No customization needed (guest-agent already included) |

All customized images have `/etc/machine-id` truncated to avoid duplicate IDs on clone.

#### 📋 Glance Image Properties

Every imported image is tagged with standardized hardware metadata:

| Property | Value | Purpose |
|---|---|---|
| `os_type` | `linux` | OS family |
| `hw_machine_type` | `q35` | Modern PCIe-native machine type |
| `hw_firmware_type` | `uefi` | UEFI boot |
| `hw_scsi_model` | `virtio-scsi` | Paravirtualized SCSI controller |
| `hw_disk_bus` | `scsi` | Disk attached via virtio-scsi |
| `hw_vif_model` | `virtio` | Paravirtualized NIC |
| `hw_vif_multiqueue_enabled` | `true` | Multi-queue for better network throughput |
| `hw_virtio_packed_ring` | `true` | Packed virtqueue for lower overhead |
| `hw_video_model` | `virtio` | Paravirtualized GPU |
| `hw_serial_port_count` | `1` | Serial console access |
| `hw_qemu_guest_agent` | `true` | Enables guest agent communication |
| `os_require_quiesce` | `true` | Quiesced snapshots for consistent backups |
| `hw_require_fsfreeze` | `true` | Filesystem freeze before snapshots |

Per-distribution properties are also set: `os_distro`, `os_version`, `os_admin_user`, `has_auto_disk_config`, and `os_license`.

| Distribution | `os_distro` | `os_admin_user` | `has_auto_disk_config` | `os_license` |
|---|---|---|---|---|
| Debian | `debian` | `debian` | `true` | `opensource` |
| Ubuntu | `ubuntu` | `ubuntu` | `true` | `opensource` |
| Rocky Linux | `rocky` | `rocky` | `true` | `opensource` |
| Rocky Linux (LVM) | `rocky` | `rocky` | `false` | `opensource` |
| openSUSE Leap | `opensuse` | `opensuse` | `true` | `opensource` |
| Oracle Linux | `oel` | `oracle` | `false` | `opensource` |

The `os_license` property defaults to `opensource` for all discovered distributions and can be overridden with `--os-license` (e.g. `--os-license rhel` for RHEL images).

#### 🌐 Proxy Support

The script honours `http_proxy`, `https_proxy` and `no_proxy` environment variables. When set, proxy settings are automatically forwarded to the guest package manager during image customization (guest-agent injection).

The `virt-customize` step runs inside a QEMU SLIRP virtual machine with its own built-in DHCP server, so it works regardless of the host's LAN configuration. Proxy environment variables are stripped from the `virt-customize` invocation to prevent routing failures inside the appliance, and injected into the guest's package manager config instead (e.g. `/etc/apt/apt.conf.d/99proxy` for Debian/Ubuntu). All transient files are cleaned up after installation.

```bash
export http_proxy=http://proxy:3128
export https_proxy=http://proxy:3128
export no_proxy=localhost,127.0.0.1,.internal.lan
./osu-import-cloud-images.sh -b -d debian
```

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Use `raw` disk format (default) when your Glance backend is Ceph RBD to leverage copy-on-write cloning.
- Use `--no-customize` if guest-agent installation will be handled via cloud-init user-data instead.
- For LVM images, after booting a VM with a larger volume, the PV is already resized. Use `vgs` to see free space, then `lvresize`/`lvcreate` as needed.

#### 🚀 Usage

```bash
# List available images
./osu-import-cloud-images.sh -l

# Interactive selection
./osu-import-cloud-images.sh -i

# Import all images in batch
./osu-import-cloud-images.sh -b

# Import Debian images only
./osu-import-cloud-images.sh -b -d debian

# Import as private images
./osu-import-cloud-images.sh -b --visibility private

# Use qcow2 format (non-Ceph backends)
./osu-import-cloud-images.sh -b -f qcow2

# Override os_license property
./osu-import-cloud-images.sh -b --os-license rhel

# Dry run
./osu-import-cloud-images.sh -n -b

# Display version
./osu-import-cloud-images.sh --version

# Display help
./osu-import-cloud-images.sh --help

# Behind a proxy
export http_proxy=http://proxy:3128 https_proxy=http://proxy:3128
export no_proxy=localhost,127.0.0.1,.internal.lan
./osu-import-cloud-images.sh -b -d debian
```

---

### 🔍 `osu-memory-usage-report.sh`

Provides an accurate summary of OpenStack resources per domain, with a per-project breakdown. It reports:

- Instance count per project
- vCPU and RAM allocation per project
- Volume count and total volume size per project
- Domain-wide totals

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (configured with admin or domain admin scope)
  - `jq`
- A sourced OpenStack credentials file (e.g., `openrc.sh`)

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- For large domains with many projects, execution may take time due to API queries per project and server.

#### 🚀 Usage

```bash
# Summarize resources for a specific domain
./osu-memory-usage-report.sh my-domain

# Display version
./osu-memory-usage-report.sh --version

# Display help
./osu-memory-usage-report.sh --help
```

---

### 🔍 `osu-retype-vdisk.sh`

Retypes (migrates) OpenStack Cinder volumes between Ceph pools by changing the volume type. Provides both an interactive wizard and a one-shot CLI mode with pre-flight validation (state checks, snapshot detection), interactive volume selection, and automated migration progress monitoring.

- **Author:** Ciro Iriarte
- **Created:** 2026-03-27
- **Updated:** 2026-03-27

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `jq`
- A sourced OpenStack credentials file (e.g., `openrc.sh`)
- No admin privileges required for normal operations

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Plan retype operations during low-usage windows — migration increases I/O latency and network traffic on the Ceph backend.
- Ensure volumes have no snapshots before retyping. Use `openstack volume snapshot list --volume <VOL_ID>` to check.
- Use `--dry-run` to preview operations before executing.
- For large batch operations, consider using `--no-monitor` and manually checking progress with `-m` to avoid long wait times.

#### 🚀 Usage

```bash
# Interactive wizard (default on TTY)
./osu-retype-vdisk.sh -i

# List all volumes
./osu-retype-vdisk.sh -l

# List volumes attached to a VM
./osu-retype-vdisk.sh -l -s web-server-01

# List volumes as JSON
./osu-retype-vdisk.sh -l -f json

# List available volume types (retype targets)
./osu-retype-vdisk.sh -t

# One-shot: retype a single volume
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool

# One-shot: retype multiple volumes (repeated -r)
./osu-retype-vdisk.sh -r VOL1_ID -r VOL2_ID -T ssd-pool

# One-shot: retype multiple volumes (comma-separated)
./osu-retype-vdisk.sh -r VOL1_ID,VOL2_ID -T ssd-pool

# One-shot: retype volumes of a VM (interactive pick)
./osu-retype-vdisk.sh -s web-server-01 -T ssd-pool

# One-shot: retype all VM volumes non-interactively
./osu-retype-vdisk.sh -s web-server-01 -T ssd-pool -y

# Dry run
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool -n

# Monitor an in-progress migration
./osu-retype-vdisk.sh -m VOL_ID

# Monitor with custom polling interval
./osu-retype-vdisk.sh -m VOL_ID --interval 5

# Display version
./osu-retype-vdisk.sh --version

# Display help
./osu-retype-vdisk.sh --help
```

---

## 📖 Documentation

Man pages are available under `man/man1/` for detailed reference.

**Preview locally** (no installation required):

```bash
man -l man/man1/osu-import-cloud-images.1
```

**Install system-wide:**

```bash
sudo make install-man
```

After installation, use `man <script-name>` to view the man page (e.g., `man osu-import-cloud-images`).

**Uninstall:**

```bash
sudo make uninstall-man
```

---

## 🤝 Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 📄 License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

---

## 👤 Author

**Ciro Iriarte** &mdash; [GitHub](https://github.com/ciroiriarte)
