# Listing OpenStack VMs with AZ Requirements

> Source: https://gemini.google.com/share/5e25a0bc6cca
> Created: April 22, 2026 at 09:32 PM
> Published: April 23, 2026 at 09:54 AM

## Question

In a Charmed Openstack platform, how do you list VMs that explicitly asked for an Availability zone and currently have it as a scheduling requirement?

## Answer

In a Charmed OpenStack environment, finding VMs with explicit Availability Zone (AZ) requirements involves querying the Nova database or the API for the availability_zone attribute. When a user requests a specific AZ during boot, that value is stored in the request_spec and the instance properties.

Here is how you can filter these instances using the CLI and identify those with "hard" scheduling requirements.

### 1. Identify Instances with an Explicit AZ Request

Using the standard OpenStack CLI, you can list instances and include the Availability Zone field. However, to see which ones explicitly requested one (rather than being assigned the default), you should look for instances where the AZ field is not empty or set to the default (usually nova).

```bash
openstack server list --all-projects --long -f value -c ID -c Name -c "Availability Zone" | awk '$3 != "" && $3 != "nova" {print $0}'
```

### 2. Deep Dive with Nova API (Request Spec)

To be certain the AZ is a scheduling requirement (and not just where the VM happens to live now), you can inspect the request_spec. This is useful if you suspect a VM was pinned to an AZ at boot.

On a Charmed OpenStack deployment, you can run this from a unit with access to the nova-cloud-controller or any machine with admin credentials:

```bash
# Get the UUIDs of servers
for vm_id in $(openstack server list --all-projects -f value -c ID); do
    # Check the request_spec for the availability_zone requirement
    AZ=$(openstack server show $vm_id -f json | jq -r '."OS-EXT-AZ:availability_zone"')
    
    # If you need to verify it was a boot-time requirement:
    echo "VM: $vm_id | Current AZ: $AZ"
done
```

### 3. Using Juju to Inspect the Database (The "Hard" Way)

If you need to audit the entire platform and the CLI is too slow, you can query the Nova database directly via the mysql unit in your Juju model. Explicit requests are often stored in the request_specs table.

```bash
# Access the mysql leader
juju run-action --wait mysql/leader get-root-password

# Run a query against the nova_api database
juju ssh mysql/leader "mysql -u root -p -e \"
SELECT instance_uuid, spec 
FROM nova_api.request_specs 
WHERE spec LIKE '%availability_zone%';\""
```

### Key Differences in Scheduling

- **Targeted AZ**: If the VM shows a specific AZ in openstack server show, the scheduler was forced to find a host in that specific aggregate.
- **Default AZ**: If the field is blank or "nova," it likely used the default scheduling logic without an explicit constraint.

### Summary Table of AZ Attributes

| Method | Attribute | Meaning |
|--------|-----------|---------|
| CLI Show | OS-EXT-AZ:availability_zone | The AZ the VM is currently residing in. |
| Request Spec | requested_destination | The specific AZ/Host requested by the user at boot. |
| Server List | --availability-zone <az> | Filter to find VMs already in a specific zone. |

**Pro-tip for Charmed Users**: If you are using OpenStack Charms with Vault/Barbican, ensure your environment variables are sourced correctly, as some "long" queries across all projects may be throttled by Keystone rate-limiting if your deployment is particularly large.

---

## Follow-up Question

Is it possible to change that requirement to another AZ or remove it altogether?

## Answer

Changing or removing the Availability Zone (AZ) requirement on an existing VM is tricky because OpenStack treats the request_spec (the original boot requirements) as largely immutable for the life of the instance. You cannot simply run an `openstack server set --az` command on a running VM.

However, there are two primary ways to achieve this in a Charmed OpenStack environment, depending on whether you want to move the VM or just "fix" the metadata.

### Method 1: The "Clean" Way (Cold Migration / Resize)

To change the AZ requirement via the API, you must essentially trigger a new scheduling event.

**Remove or Change the AZ:**
In newer versions of OpenStack (Nova API 2.34+), you can use the migrate or resize command while specifying a new target.

```bash
# To move to a new AZ
openstack server resize --flavor <current_flavor> --availability-zone <new_az> <server_id>

# To confirm the move
openstack server resize confirm <server_id>
```

**Note:** Removing the requirement entirely to let it land "anywhere" via resize is not natively supported in a single CLI flag. You usually have to pick a new target.

### Method 2: The "Database Surgery" (Forced Removal)

If you need to remove the requirement altogether so that the VM can be evacuated or migrated to any host in the future without being blocked by the original AZ constraint, you have to modify the nova_api database.

**Warning:** Always back up your database before manual edits.

**Locate the Request Spec:**
The requirement is stored in a serialized JSON blob in the nova_api database.

```bash
juju ssh mysql/leader
mysql -u root -p
USE nova_api;
SELECT spec FROM request_specs WHERE instance_uuid = 'YOUR_VM_UUID';
```

**Edit the JSON:**
You would need to update that row to remove the `"availability_zone": "your_zone"` entry from the requested_destination or availability_zone keys within the JSON blob.

**Update the Instance Record:**
In the main nova database, the instances table also has an availability_zone column. Updating this to NULL or the default nova zone allows the scheduler more flexibility.

### Method 3: Snapshot and Recreate (Safest)

If the VM is not mission-critical and can handle a few minutes of downtime, this is the most "supported" way to clear all sticky scheduling metadata:

1. **Snapshot the VM:** `openstack server image create --name backup_vm <server_id>`
2. **Delete the old VM:** `openstack server delete <server_id>`
3. **Launch New VM:** Boot from the snapshot without specifying the `--availability-zone` flag.

### Summary of Constraints

| Action | Method | Risk Level |
|--------|--------|------------|
| Change AZ | `openstack server resize --availability-zone <new>` | Low (Requires downtime during resize) |
| Remove AZ Requirement | Database Update (request_specs table) | High (Manual DB manipulation) |
| Complete Reset | Snapshot → Delete → Re-create | Zero (Safe, but changes UUID/IP) |

### Recommendation for Charmed OpenStack

If you are managing this via a CI/CD pipeline or Terraform, it is almost always better to recreate the instance. If you must keep the VM alive, use the resize method to point it to a new zone, which updates the request_spec correctly through the API.

**Note:** The migration/resize speed depends significantly on whether the VM has local disk (ephemeral) or is boot-from-volume.
