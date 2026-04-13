# Cloud Images — Provisioning Guide

Examples for launching VMs from images imported by
[`osu-import-cloud-images.sh`](osu-import-cloud-images.sh) using the
OpenStack CLI and cloud-init.

Standalone user-data files ready for `--user-data` are in [`samples/`](samples/).

---

## 📋 Table of Contents

- [Image Naming & Admin Users](#-image-naming--admin-users)
- [Prerequisites](#-prerequisites)
- [Scenario 1 — DHCP + SSH Key](#-scenario-1--dhcp--ssh-key)
- [Scenario 2 — DHCP + Password](#-scenario-2--dhcp--password)
- [Scenario 3 — Static IP + SSH Key](#-scenario-3--static-ip--ssh-key)
- [Scenario 4 — Static IP + Password](#-scenario-4--static-ip--password)
- [Post-Launch Verification](#-post-launch-verification)
- [Notes](#-notes)

---

## 🏷️ Image Naming & Admin Users

Images are named: **`ci-<distro>-<version>-x86-64-<YYYYMMDD.HHMM>`**

| Image name (example)                        | Default admin user |
|---------------------------------------------|--------------------|
| `ci-ubuntu-2404-x86-64-20260413.1000`       | `ubuntu`           |
| `ci-debian-12-x86-64-20260413.1000`         | `debian`           |
| `ci-rocky-9-x86-64-20260413.1000`           | `rocky`            |
| `ci-rocky-9-lvm-x86-64-20260413.1000`       | `rocky`            |
| `ci-opensuse-15.6-x86-64-20260413.1000`     | `opensuse`         |
| `ci-oracle-9-x86-64-20260413.1000`          | `oracle`           |

The default admin user is stored in the `os_admin_user` Glance property:

```bash
openstack image show ci-ubuntu-2404-x86-64-20260413.1000 \
  -f value -c properties | grep os_admin_user
```

All images are pre-configured for: **q35** machine type · **UEFI** firmware ·
**virtio-scsi** disk · **virtio-net** NIC · **qemu-guest-agent** installed.

---

## ⚙️ Prerequisites

### List available images

```bash
openstack image list --name 'ci-' --property os_type=linux \
  -c Name -c ID -c Status -f table
```

### Register an SSH key pair (skip if already done)

```bash
openstack keypair create --public-key ~/.ssh/id_ed25519.pub my-key
```

### Create a security group that allows SSH ingress

```bash
openstack security group create ssh-access \
  --description "Allow SSH inbound"

openstack security group rule create ssh-access \
  --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0
```

### Generate a hashed password (required for password scenarios)

```bash
# Using openssl (available on most systems)
openssl passwd -6 'MySecureP@ss!'

# Alternative using Python
python3 -c "import getpass,crypt; print(crypt.crypt(getpass.getpass(), crypt.mksalt(crypt.METHOD_SHA512)))"
```

The output looks like: `$6$rounds=4096$<salt>$<hash>`  
Copy it into the `passwd:` field of the user-data below.

---

## 🖧 Scenario 1 — DHCP + SSH Key

The NIC receives its IP via DHCP. Authentication uses an SSH public key.
A `cloudadmin` user with passwordless sudo is created alongside the default
distro admin user.

Standalone file: [`samples/cloud-init-dhcp-sshkey.yaml`](samples/cloud-init-dhcp-sshkey.yaml)

### user-data

Save as `user-data.yaml` and replace the `ssh_authorized_keys` entry with
your actual public key:

```yaml
#cloud-config

users:
  # Preserve the default distro admin user (ubuntu, debian, rocky, etc.)
  # as a fallback. Remove if not needed.
  - default
  - name: cloudadmin
    gecos: Cloud Administrator
    # 'sudo'  grants sudo on Debian / Ubuntu
    # 'wheel' grants sudo on Rocky / Oracle / openSUSE
    # cloud-init silently ignores groups that do not exist on the target distro
    groups: [sudo, wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceThisWithYourActualPublicKeyContent user@workstation

network:
  version: 2
  ethernets:
    ens3:
      # ens3 is the typical interface name on q35/virtio-net VMs.
      # Rocky Linux and Oracle Linux cloud images commonly use eth0 instead.
      dhcp4: true
      dhcp6: false

# Hostname is set from the OpenStack instance name via the metadata service.
# Do NOT set 'hostname:' or 'fqdn:' here — let the platform provide it.
package_update: true
package_upgrade: false
timezone: UTC

final_message: |
  cloud-init completed in $UPTIME seconds.
  Connect: ssh cloudadmin@<IP>
```

### Launch

```bash
openstack server create \
  --image    ci-ubuntu-2404-x86-64-20260413.1000 \
  --flavor   m1.small \
  --network  my-network \
  --security-group ssh-access \
  --key-name my-key \
  --user-data user-data.yaml \
  vm-dhcp-sshkey
```

### Connect

```bash
ssh -i ~/.ssh/id_ed25519 cloudadmin@<FLOATING_IP>
```

---

## 🔑 Scenario 2 — DHCP + Password

The NIC receives its IP via DHCP. Authentication uses a password.

Standalone file: [`samples/cloud-init-dhcp-password.yaml`](samples/cloud-init-dhcp-password.yaml)

### user-data

Replace the `passwd` value with the hash generated in
[Prerequisites](#-prerequisites):

```yaml
#cloud-config

users:
  # Preserve the default distro admin user (ubuntu, debian, rocky, etc.)
  # as a fallback. Remove if not needed.
  - default
  - name: cloudadmin
    gecos: Cloud Administrator
    # 'sudo'  grants sudo on Debian / Ubuntu
    # 'wheel' grants sudo on Rocky / Oracle / openSUSE
    # cloud-init silently ignores groups that do not exist on the target distro
    groups: [sudo, wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    # SHA-512 hashed password — generate with: openssl passwd -6 'yourpassword'
    passwd: "$6$rounds=4096$REPLACETHISSALT$REPLACETHISHASHWITHTHEOUTPUTOFOPENSSLPASSWD6YourActualPassword"

# Enable password authentication over SSH
ssh_pwauth: true

network:
  version: 2
  ethernets:
    ens3:
      # ens3 is the typical interface name on q35/virtio-net VMs.
      # Rocky Linux and Oracle Linux cloud images commonly use eth0 instead.
      dhcp4: true
      dhcp6: false

# Hostname is set from the OpenStack instance name via the metadata service.
# Do NOT set 'hostname:' or 'fqdn:' here — let the platform provide it.
package_update: true
package_upgrade: false
timezone: UTC

# Prevent password expiry on first login
chpasswd:
  expire: false

final_message: |
  cloud-init completed in $UPTIME seconds.
  Connect: ssh cloudadmin@<IP>
```

### Launch

```bash
openstack server create \
  --image    ci-ubuntu-2404-x86-64-20260413.1000 \
  --flavor   m1.small \
  --network  my-network \
  --security-group ssh-access \
  --user-data user-data.yaml \
  vm-dhcp-password
```

### Connect

```bash
ssh cloudadmin@<FLOATING_IP>
# Enter the plain-text password that corresponds to the hash in the YAML.
```

---

## 📌 Scenario 3 — Static IP + SSH Key

The NIC is configured with a fixed IP — no DHCP client runs inside the VM.
Authentication uses an SSH public key.

Static IP assignment requires a Neutron port with a pre-allocated fixed IP.
cloud-init then configures the interface directly via network config v2.

Standalone file: [`samples/cloud-init-static-sshkey.yaml`](samples/cloud-init-static-sshkey.yaml)

### Step 1 — Create a port with the desired fixed IP

```bash
openstack port create \
  --network  my-network \
  --fixed-ip subnet=my-subnet,ip-address=192.168.1.50 \
  port-vm-static-sshkey

PORT_ID=$(openstack port show port-vm-static-sshkey -f value -c id)
```

### Step 2 — user-data

Adjust `addresses`, `via`, and `nameservers` to match your subnet:

```yaml
#cloud-config

users:
  # Preserve the default distro admin user (ubuntu, debian, rocky, etc.)
  # as a fallback. Remove if not needed.
  - default
  - name: cloudadmin
    gecos: Cloud Administrator
    # 'sudo'  grants sudo on Debian / Ubuntu
    # 'wheel' grants sudo on Rocky / Oracle / openSUSE
    # cloud-init silently ignores groups that do not exist on the target distro
    groups: [sudo, wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceThisWithYourActualPublicKeyContent user@workstation

network:
  version: 2
  ethernets:
    ens3:
      # ens3 is the typical interface name on q35/virtio-net VMs.
      # Rocky Linux and Oracle Linux cloud images commonly use eth0 instead.
      dhcp4: false
      dhcp6: false
      addresses:
        - 192.168.1.50/24
      routes:
        - to: 0.0.0.0/0
          via: 192.168.1.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8

# Hostname is set from the OpenStack instance name via the metadata service.
# Do NOT set 'hostname:' or 'fqdn:' here — let the platform provide it.
package_update: true
package_upgrade: false
timezone: UTC

final_message: |
  cloud-init completed in $UPTIME seconds.
  Connect: ssh cloudadmin@192.168.1.50
```

### Step 3 — Launch

```bash
openstack server create \
  --image    ci-ubuntu-2404-x86-64-20260413.1000 \
  --flavor   m1.small \
  --nic      port-id="${PORT_ID}" \
  --security-group ssh-access \
  --key-name my-key \
  --user-data user-data.yaml \
  vm-static-sshkey
```

### Connect

```bash
ssh -i ~/.ssh/id_ed25519 cloudadmin@192.168.1.50
```

---

## 🔒 Scenario 4 — Static IP + Password

The NIC is configured with a fixed IP. Authentication uses a password.

Standalone file: [`samples/cloud-init-static-password.yaml`](samples/cloud-init-static-password.yaml)

### Step 1 — Create a port with the desired fixed IP

```bash
openstack port create \
  --network  my-network \
  --fixed-ip subnet=my-subnet,ip-address=192.168.1.51 \
  port-vm-static-password

PORT_ID=$(openstack port show port-vm-static-password -f value -c id)
```

### Step 2 — user-data

Replace `passwd` with the hash generated in [Prerequisites](#-prerequisites)
and adjust the network settings:

```yaml
#cloud-config

users:
  # Preserve the default distro admin user (ubuntu, debian, rocky, etc.)
  # as a fallback. Remove if not needed.
  - default
  - name: cloudadmin
    gecos: Cloud Administrator
    # 'sudo'  grants sudo on Debian / Ubuntu
    # 'wheel' grants sudo on Rocky / Oracle / openSUSE
    # cloud-init silently ignores groups that do not exist on the target distro
    groups: [sudo, wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    # SHA-512 hashed password — generate with: openssl passwd -6 'yourpassword'
    passwd: "$6$rounds=4096$REPLACETHISSALT$REPLACETHISHASHWITHTHEOUTPUTOFOPENSSLPASSWD6YourActualPassword"

# Enable password authentication over SSH
ssh_pwauth: true

network:
  version: 2
  ethernets:
    ens3:
      # ens3 is the typical interface name on q35/virtio-net VMs.
      # Rocky Linux and Oracle Linux cloud images commonly use eth0 instead.
      dhcp4: false
      dhcp6: false
      addresses:
        - 192.168.1.51/24
      routes:
        - to: 0.0.0.0/0
          via: 192.168.1.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8

# Hostname is set from the OpenStack instance name via the metadata service.
# Do NOT set 'hostname:' or 'fqdn:' here — let the platform provide it.
package_update: true
package_upgrade: false
timezone: UTC

# Prevent password expiry on first login
chpasswd:
  expire: false

final_message: |
  cloud-init completed in $UPTIME seconds.
  Connect: ssh cloudadmin@192.168.1.51
```

### Step 3 — Launch

```bash
openstack server create \
  --image    ci-ubuntu-2404-x86-64-20260413.1000 \
  --flavor   m1.small \
  --nic      port-id="${PORT_ID}" \
  --security-group ssh-access \
  --user-data user-data.yaml \
  vm-static-password
```

### Connect

```bash
ssh cloudadmin@192.168.1.51
# Enter the plain-text password that corresponds to the hash in the YAML.
```

---

## ✅ Post-Launch Verification

```bash
# Wait for the instance to become ACTIVE
openstack server show vm-dhcp-sshkey -f value -c status

# Watch the cloud-init console log for completion
openstack console log show vm-dhcp-sshkey | tail -40

# Assign a floating IP (if needed)
FLOAT=$(openstack floating ip create public -f value -c floating_ip_address)
openstack server add floating ip vm-dhcp-sshkey "${FLOAT}"
```

On the instance:

```bash
# Verify sudo access
sudo -l
sudo whoami       # expected output: root

# Check cloud-init completion status
cloud-init status --long
```

---

## 📝 Notes

- **Hostname:** set automatically from the OpenStack instance name via the
  metadata service. Do not set `hostname:` or `fqdn:` in user-data.

- **Network interface name:** `ens3` is the typical name on q35/virtio-net VMs.
  Rocky Linux and Oracle Linux cloud images commonly use `eth0` instead.
  If networking fails, verify with `ip link` via the OpenStack console and
  adjust the interface name in the user-data accordingly.

- **sudo groups:** `wheel` is used on Rocky / Oracle / openSUSE; `sudo` on
  Debian / Ubuntu. Both groups are specified in all examples — cloud-init
  silently ignores groups that do not exist on the target distro.

- **Password authentication:** requires `PasswordAuthentication yes` in sshd.
  The user-data files set `ssh_pwauth: true` which cloud-init writes to the
  sshd configuration automatically.

- **Default distro admin user:** the `- default` entry in the `users:` list
  preserves the per-distro admin user (`ubuntu`, `rocky`, etc.) alongside
  `cloudadmin`, providing a fallback login if `cloudadmin` setup fails.

- **Timezone:** set to `UTC` in all examples. Adjust `timezone:` to a valid
  tz database name (e.g., `America/New_York`, `Europe/Berlin`) as needed.

- **Rocky Linux LVM images** (`ci-rocky-*-lvm-*`): the PV is automatically
  resized to the full disk on first boot. Use `vgs` to inspect free space,
  then `lvresize` / `lvextend` to grow a logical volume.
