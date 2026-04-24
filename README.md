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
  - [Cloud Images Provisioning Guide](#-cloud-images-provisioning-guide)
  - [osu-memory-usage-report.sh](#-osu-memory-usage-reportsh)
  - [osu-capacity-report.sh](#-osu-capacity-reportsh)
  - [osu-retype-vdisk.sh](#-osu-retype-vdisksh)
  - [osu-track-az-requirement.sh](#-osu-track-az-requirementsh)
  - [osu-track-qemu-agents.sh](#-osu-track-qemu-agentssh)
  - [osu-unpin-vm-from-az.sh](#-osu-unpin-vm-from-azsh)
- [Documentation](#-documentation)
- [Contributing](#-contributing)
- [License](#-license)
- [Author](#-author)

---

## 🔍 Overview

| Script | Version | Created | Updated |
|---|---|---|---|
| `osu-import-cloud-images.sh` | ![v1.2.1](https://img.shields.io/badge/version-1.2.1-blue) | 2026-03-12 | 2026-03-27 |
| `osu-memory-usage-report.sh` | ![v0.2](https://img.shields.io/badge/version-0.2-orange) | 2025-12-24 | 2026-03-26 |
| `osu-capacity-report.sh` | ![v0.1](https://img.shields.io/badge/version-0.1-orange) | 2026-03-27 | 2026-03-27 |
| `osu-retype-vdisk.sh` | ![v0.2.0](https://img.shields.io/badge/version-0.2.0-orange) | 2026-03-27 | 2026-03-27 |
| `osu-track-az-requirement.sh` | ![v0.4.1](https://img.shields.io/badge/version-0.4.1-orange) | 2026-04-23 | 2026-04-24 |
| `osu-track-qemu-agents.sh` | ![v0.2.1](https://img.shields.io/badge/version-0.2.1-orange) | 2026-04-23 | 2026-04-24 |
| `osu-unpin-vm-from-az.sh` | ![v0.1.0](https://img.shields.io/badge/version-0.1.0-orange) | 2026-04-24 | 2026-04-24 |

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

### 📖 Cloud Images Provisioning Guide

Step-by-step procedures for launching VMs from images imported by
`osu-import-cloud-images.sh`, covering all four combinations of network
configuration and authentication method:

| Scenario | Network | Auth |
|---|---|---|
| 1 | DHCP | SSH key |
| 2 | DHCP | Password |
| 3 | Static IP | SSH key |
| 4 | Static IP | Password |

Each scenario creates a `cloudadmin` user with passwordless sudo.
Hostname is sourced from the OpenStack instance name via the metadata service.

➡️ **[cloud-init-usage.md](cloud-init-usage.md)**

Standalone user-data files ready for `--user-data` are in [`samples/`](samples/):

| File | Network | Auth |
|---|---|---|
| [`cloud-init-dhcp-sshkey.yaml`](samples/cloud-init-dhcp-sshkey.yaml) | DHCP | SSH key |
| [`cloud-init-dhcp-password.yaml`](samples/cloud-init-dhcp-password.yaml) | DHCP | Password |
| [`cloud-init-static-sshkey.yaml`](samples/cloud-init-static-sshkey.yaml) | Static IP | SSH key |
| [`cloud-init-static-password.yaml`](samples/cloud-init-static-password.yaml) | Static IP | Password |

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

### 🔍 `osu-capacity-report.sh`

Reports OpenStack resource allocation and efficiency per project. For each VM, shows assigned vCPU, RAM, root disk, and Cinder volume usage alongside real CPU and memory utilisation from Nova diagnostics. Flags unreliable memory data when the virtio-balloon driver or qemu-guest-agent is absent.

- **Author:** Ciro Iriarte
- **Created:** 2026-03-27
- **Updated:** 2026-03-27

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `curl` (for Nova diagnostics REST API)
  - `jq`
- A sourced OpenStack credentials file (e.g., `openrc.sh`)
- Admin or domain admin scope for cross-project reports

#### ⚠️ Known Limitations

- **CPU% is a lifetime average**, not real-time. Derived from cumulative CPU time counters vs uptime. A VM idle 29 days then busy 1 day shows ~3%. Real-time CPU monitoring requires Gnocchi/Ceilometer.
- **RAM% requires virtio-balloon / qemu-guest-agent.** Without it, the hypervisor always reports `used == maximum` (shown as `~100%`). Installing `qemu-guest-agent` in the guest enables accurate memory reporting.
- **Diagnostics only for ACTIVE VMs.** Stopped, shelved, or error-state instances show `—` for efficiency columns.

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Install `qemu-guest-agent` in guest VMs for accurate memory efficiency reporting.
- Use `--no-diagnostics` for faster allocation-only reports in large environments.
- Use `--format csv` to export data for spreadsheet analysis.

#### 🚀 Usage

```bash
# Report all projects in a domain
./osu-capacity-report.sh my-domain

# Report a single project
./osu-capacity-report.sh -p my-project

# Report all accessible projects
./osu-capacity-report.sh -a

# CSV output for spreadsheets
./osu-capacity-report.sh -f csv my-domain > report.csv

# JSON output
./osu-capacity-report.sh -f json -p my-project

# Allocation-only report (faster, no diagnostics)
./osu-capacity-report.sh --no-diagnostics my-domain

# Display version
./osu-capacity-report.sh --version

# Display help
./osu-capacity-report.sh --help
```

---

### 🔍 `osu-retype-vdisk.sh`

Retypes (migrates) OpenStack Cinder volumes between Ceph pools by changing the volume type. Provides both an interactive wizard and a one-shot CLI mode with pre-flight validation (state checks, snapshot detection, stopped VM detection), interactive volume selection, and automated migration progress monitoring.

- **Author:** Ciro Iriarte
- **Created:** 2026-03-27
- **Updated:** 2026-03-27

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `jq`
- A sourced OpenStack credentials file (e.g., `openrc.sh`)
- No admin privileges required for normal operations

#### ⚠️ Known Limitations

- **Stopped VMs block cross-backend retypes.** When a volume is attached to a SHUTOFF instance and the retype requires data migration between different storage backends (e.g. `slow` to `fast` pool), Nova refuses the volume swap (`Cannot 'swap_volume' while vm_state stopped`). Use `--handle-vm-state` to resolve this automatically:
  - `start-stop` — Starts the VM, retypes normally, then stops the VM. Works for **all volumes** including boot disks.
  - `detach-reattach` — Detaches the volume, retypes it as available, then reattaches at the original device path. **Only for non-root data volumes** (boot disks cannot be detached). In interactive mode, the wizard prompts for a strategy.
- **Snapshots block retype.** Volumes with snapshots cannot be retyped. Use `--handle-snapshots` to resolve this automatically.

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- For volumes on stopped VMs, use `--handle-vm-state start-stop` (universal) or `--handle-vm-state detach-reattach` (data volumes only) to handle the retype automatically.
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

# Handle snapshots blocking retype (delete)
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool --handle-snapshots delete

# Handle snapshots blocking retype (backup then delete)
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool --handle-snapshots backup-delete --backup-container vol-snap-backups

# Handle volumes on stopped VMs (start VM, retype, stop VM)
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool --handle-vm-state start-stop

# Handle data volumes on stopped VMs (detach, retype, reattach)
./osu-retype-vdisk.sh -r VOL_ID -T ssd-pool --handle-vm-state detach-reattach

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

### 🔍 `osu-track-az-requirement.sh`

Reports OpenStack VMs with their host placement, effective Availability Zone, and whether an AZ was explicitly requested at creation time. Queries the `nova_api.request_specs` table via juju for **authoritative** AZ request data.

- **Author:** Ciro Iriarte
- **Created:** 2026-04-23
- **Updated:** 2026-04-23

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `jq`
  - `juju` CLI with SSH access to mysql-innodb-cluster unit
- A sourced OpenStack credentials file (e.g., `openrc.sh`)

#### 🔐 Permissions

| Scope | OpenStack | Juju |
|---|---|---|
| Default (own project) | Regular user | SSH access to MySQL unit |
| `--all-projects` | Admin | SSH access to MySQL unit |
| `-d <domain>` | Admin or domain-admin | SSH access to MySQL unit |
| `-p <other-project>` | Admin | SSH access to MySQL unit |

#### 📋 AZ Request Detection (Authoritative)

| Indicator | Meaning |
|---|---|
| `<az-name>` | AZ was explicitly requested at creation (shows the requested AZ) |
| `—` | No AZ was requested (scheduler chose placement freely) |
| `n/a` | VM not found in request_specs table |

**Note:** The Nova API does not expose `request_spec`. This script queries the database directly for authoritative information.

#### 📊 Interpreting Results

| Scenario | Current AZ | Requested | Match | Interpretation |
|---|---|---|---|---|
| Explicit AZ, not moved | `az1` | `az1` | ✓ | VM requested az1 and is still there |
| Explicit AZ, was moved | `az1` | `nova` | ✗ | VM requested nova but was migrated to az1 |
| No AZ requested | `az2` | `—` | — | Scheduler placed VM freely; can migrate anywhere |
| Pinned to AZ | `az1` | `az1` | ✓ | Future migrations constrained to az1 |

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Use `--all-projects` for a platform-wide inventory.
- Use `-d <domain>` for domain-scoped reports.
- Use `--mismatch-only` to find VMs that have been migrated.
- VMs with `Requested = —` can be freely live-migrated across AZs.
- VMs with `Requested = <az>` are constrained to that AZ for migrations/evacuations.
- Export to CSV for spreadsheet analysis or JSON for scripting.

#### 🚀 Usage

```bash
# Report VMs in current project
./osu-track-az-requirement.sh

# Query a specific VM
./osu-track-az-requirement.sh -s my-vm-name

# Report all VMs across all projects
./osu-track-az-requirement.sh --all-projects

# Report all VMs in a specific domain
./osu-track-az-requirement.sh -d my-domain

# Report VMs in a specific project
./osu-track-az-requirement.sh -p my-project

# Report VMs in a project within a specific domain
./osu-track-az-requirement.sh -d my-domain -p my-project

# Show only VMs that have been migrated (mismatch between current and requested AZ)
./osu-track-az-requirement.sh --mismatch-only --all-projects

# CSV output for spreadsheet analysis
./osu-track-az-requirement.sh -f csv --all-projects > az-report.csv

# JSON output for scripting
./osu-track-az-requirement.sh -f json -p my-project

# Use a different MySQL unit
./osu-track-az-requirement.sh --mysql-unit mysql-innodb-cluster/1 --all-projects

# Suppress progress indicators
./osu-track-az-requirement.sh --all-projects -q

# Display version
./osu-track-az-requirement.sh --version

# Display help
./osu-track-az-requirement.sh --help
```

---

### 🔍 `osu-track-qemu-agents.sh`

Reports OpenStack VMs with their QEMU guest agent configuration and communication status. For each VM, shows whether the agent bus is configured (`hw_qemu_guest_agent` in the source image) and whether the agent is actually responding.

- **Author:** Ciro Iriarte
- **Created:** 2026-04-23
- **Updated:** 2026-04-23

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `curl` (for Nova diagnostics API)
  - `jq`
- A sourced OpenStack credentials file (e.g., `openrc.sh`)

#### 🔐 Permissions

| Scope | Requirement |
|---|---|
| Default (own project) | Regular OpenStack user |
| `--all-projects` | OpenStack admin |
| `-d <domain>` | Admin or domain-admin |
| `-p <other-project>` | OpenStack admin |

#### 📋 Detection Methods (CLI/API Only)

| Check | Method | Notes |
|---|---|---|
| **Agent Bus** | Image properties via CLI | Checks `hw_qemu_guest_agent` in image or volume_image_metadata |
| **Agent Responding** | Nova diagnostics API | Presence of `memory-unused`/`memory-available` indicates balloon/agent communication |

#### 📊 Status Indicators

| Symbol | Agent Bus | Responding |
|---|---|---|
| ✓ | Configured in image | Agent communicating |
| ✗ | Not configured | Agent not responding |
| ? | Couldn't determine (image deleted) | Couldn't determine (VM not active) |

#### 📊 Interpreting Results

| Bus | Responding | Interpretation |
|---|---|---|
| ✓ | ✓ | Fully operational — agent installed and communicating |
| ✓ | ✗ | Bus configured but agent not responding — install `qemu-guest-agent` in guest |
| ✗ | ? | No agent support — live migration features limited |
| ? | ? | Unable to determine (VM off or image deleted) |

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Use `--issues-only` to focus on VMs that need attention.
- Install `qemu-guest-agent` in VMs where the bus is configured but agent is not responding.
- VMs without agent support (`✗` for bus) cannot use features like quiesced snapshots or filesystem freeze.
- Export to CSV for spreadsheet analysis or JSON for scripting.

#### 🚀 Usage

```bash
# Report VMs in current project
./osu-track-qemu-agents.sh

# Report all VMs across all projects
./osu-track-qemu-agents.sh --all-projects

# Report all VMs in a specific domain
./osu-track-qemu-agents.sh -d my-domain

# Report VMs in a specific project
./osu-track-qemu-agents.sh -p my-project

# Show only VMs with agent issues
./osu-track-qemu-agents.sh --issues-only --all-projects

# CSV output for spreadsheet analysis
./osu-track-qemu-agents.sh -f csv --all-projects > agents.csv

# JSON output for scripting (filter VMs without responding agent)
./osu-track-qemu-agents.sh -f json --all-projects | jq '.[] | select(.agent_responding == false)'

# Suppress progress indicators
./osu-track-qemu-agents.sh --all-projects -q

# Display version
./osu-track-qemu-agents.sh --version

# Display help
./osu-track-qemu-agents.sh --help
```

---

### 🔓 `osu-unpin-vm-from-az.sh`

Removes the Availability Zone (AZ) hard request from an OpenStack VM to enable cross-AZ cold migration. Uses the shelve/unshelve workflow with `--no-availability-zone` flag.

- **Author:** Ciro Iriarte
- **Created:** 2026-04-24
- **Updated:** 2026-04-24

#### ⚙️ Requirements

- Required tools:
  - `openstack` CLI (python-openstackclient)
  - `jq`
  - `python3` with venv support
- A sourced OpenStack credentials file (e.g., `openrc.sh`)

#### 🔐 Permissions

| Scope | Requirement |
|---|---|
| Any VM | OpenStack admin |

#### 📋 How It Works

1. Stop the instance (if running)
2. Shelve the instance
3. Wait for `SHELVED_OFFLOADED` state
4. Unshelve with `--no-availability-zone` (and optionally `--host`)

#### 🔧 Automatic Client Setup

The `--no-availability-zone` flag requires `python-openstackclient >= 9.0.0`. If the system client is outdated, the script **automatically**:
1. Creates a Python venv at `~/.osu-tools/osc-venv`
2. Installs the required client version
3. Uses the venv for operations

This is a one-time setup that happens transparently.

#### 💡 Recommendations

- Source your OpenStack credentials before running:
  ```bash
  source ~/openrc.sh
  ```
- Plan for VM downtime during the procedure (stop → shelve → unshelve).
- Use `--dry-run` to preview operations before executing.
- After unpinning, verify with `osu-track-az-requirement.sh` that the AZ constraint is removed.
- The VM can then be cold-migrated to any AZ using standard `openstack server migrate`.

#### 🚀 Usage

```bash
# Unpin a VM (scheduler chooses new host)
./osu-unpin-vm-from-az.sh my-vm

# Unpin and place on specific host
./osu-unpin-vm-from-az.sh --target-host compute-node-05 my-vm

# Dry run to see what would happen
./osu-unpin-vm-from-az.sh --dry-run my-vm

# Skip confirmation prompt
./osu-unpin-vm-from-az.sh --force my-vm

# Allow insecure SSL connections
./osu-unpin-vm-from-az.sh --insecure my-vm

# Display version
./osu-unpin-vm-from-az.sh --version

# Display help
./osu-unpin-vm-from-az.sh --help
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

### Bash Completion

Tab completion is available for all scripts, providing automatic completion of options, enumerated values (e.g., `--format`, `--handle-vm-state`), and live OpenStack resources (volume IDs, server names, volume types).

**Load for the current session:**

```bash
source completions/osu-tools.bash
```

**Install system-wide** (persists across sessions):

```bash
sudo make install-completions
```

**Uninstall:**

```bash
sudo make uninstall-completions
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
