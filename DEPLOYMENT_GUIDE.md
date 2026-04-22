# Hammerspace Tier 0 Deployment Guide for OCI

Step-by-step guide for deploying Hammerspace Tier 0 storage on Oracle Cloud Infrastructure (OCI) GPU instances.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Control Machine Setup](#2-control-machine-setup)
3. [OCI Authentication Setup](#3-oci-authentication-setup)
4. [Configure Inventory](#4-configure-inventory)
5. [Configure Variables](#5-configure-variables)
6. [Run Preflight Check](#6-run-preflight-check)
7. [Deploy to New Instances](#7-deploy-to-new-instances)
8. [Verify Deployment](#8-verify-deployment)
9. [Availability Zone (AZ) Configuration](#9-availability-zone-az-configuration-with-gpu-fabric)
10. [Adding New Instances (Future Deployments)](#10-adding-new-instances-future-deployments)
11. [Data Instantiator (DI) Deployment](#11-data-instantiator-di-deployment)
12. [Troubleshooting](#12-troubleshooting)
13. [Decommissioning Instances](#13-decommissioning-instances)

---

## 1. Prerequisites

Before starting, ensure you have:

| Requirement | Description |
|-------------|-------------|
| OCI Tenancy | Access to OCI with compute instances running |
| GPU Instances | BM.GPU.GB200-v3.4 or similar bare metal instances |
| SSH Access | SSH key configured for instance access |
| Hammerspace Cluster | Anvil management IP and admin credentials |
| Network | Instances can reach Hammerspace Anvil on port 8443 |

---

## 2. Control Machine Setup

Run these commands on your control machine (laptop, bastion host, or workstation).

### 2.1 Install Ansible

**macOS:**
```bash
brew install ansible
```

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install -y ansible python3-pip
```

**Linux (RHEL/Rocky):**
```bash
sudo dnf install -y ansible python3-pip
```

### 2.2 Install OCI Python SDK

```bash
pip3 install oci
```

### 2.3 Clone the Repository

```bash
git clone <repository-url> ansible-tier0
cd ansible-tier0
```

### 2.4 Install Ansible Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

**Expected output:**
```
Installing 'ansible.posix:>=1.4.0' ...
Installing 'community.general:>=6.0.0' ...
Installing 'oracle.oci:>=5.0.0' ...
```

---

## 3. OCI Authentication Setup

### 3.1 Install OCI CLI (if not installed)

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### 3.2 Configure OCI Authentication

```bash
oci setup config
```

Follow the prompts:
1. Enter your OCI user OCID
2. Enter your tenancy OCID
3. Enter your region (e.g., `us-sanjose-1`)
4. Generate a new API key or use existing

**Verify configuration:**
```bash
oci iam user get --user-id <your-user-ocid>
```

### 3.3 Verify OCI Connectivity

```bash
# List compartments
oci iam compartment list --query "data[].{name:name, id:id}" --output table

# List instances in your compartment
oci compute instance list --compartment-id <your-compartment-ocid> --output table
```

---

## 4. Configure Inventory

### 4.1 Update ansible.cfg

Edit `ansible.cfg` to use OCI dynamic inventory and SSH key:

```ini
[defaults]
inventory = inventory.oci.yml
private_key_file = /path/to/your/ssh/key    # <-- Path to your SSH private key
```

**Important:** The SSH public key must be configured on all GPU instances. Ensure:

1. The SSH key pair exists on your control machine
2. The public key is added to the `~/.ssh/authorized_keys` file on each GPU instance
3. The key was added during instance provisioning, or add it manually:

```bash
# Option 1: If you have existing access, copy the key
ssh-copy-id -i /path/to/your/ssh/key.pub ubuntu@<instance-ip>

# Option 2: Add via OCI Console
# Navigate to: Compute > Instances > Instance Details > Console Connection
# Or add SSH key during instance creation

# Option 3: Add manually on each instance
echo "ssh-rsa AAAA...your-public-key... user@host" >> ~/.ssh/authorized_keys
```

**Verify SSH access:**
```bash
ssh -i /path/to/your/ssh/key ubuntu@<instance-ip> "hostname"
```

### 4.2 Configure OCI Inventory

Edit `inventory.oci.yml` to match your environment:

```yaml
---
plugin: oracle.oci.oci
regions:
  - us-sanjose-1    # <-- Update to your region

fetch_hosts_from_subcompartments: true

hostname_format_preferences:
  - "display_name"
  - "private_ip"

# Filter to running GPU instances
filters:
  lifecycle_state: "RUNNING"

include_host_filters:
  - "shape == 'BM.GPU.GB200-v3.4'"    # <-- Update to your instance shape

# Create storage_servers group
groups:
  storage_servers: "shape == 'BM.GPU.GB200-v3.4'"

compose:
  ansible_host: private_ip
  ansible_user: "'ubuntu'"              # <-- Update if using different OS user
  ansible_python_interpreter: "'/usr/bin/python3'"
  ansible_become: true
  oci_fault_domain: fault_domain
  oci_availability_domain: availability_domain
  hammerspace_volume_az_prefix: fault_domain | regex_replace('FAULT-DOMAIN-', 'AZ') ~ ":"

keyed_groups:
  - key: fault_domain
    prefix: az
    separator: "_"
```

### 4.3 Test Inventory Discovery

```bash
# List all discovered hosts
ansible-inventory -i inventory.oci.yml --list

# Show as graph
ansible-inventory -i inventory.oci.yml --graph

# Ping all storage servers
ansible -i inventory.oci.yml storage_servers -m ping
```

**Expected output:**
```
instance20260127011850 | SUCCESS => {
    "ping": "pong"
}
instance20260127011851 | SUCCESS => {
    "ping": "pong"
}
```

---

## 5. Configure Variables

### 5.1 Edit vars/main.yml

Update the following sections in `vars/main.yml`:

#### Hammerspace API Configuration (Required)

```yaml
# Anvil management IP
hammerspace_api_host: "10.241.0.105"    # <-- Update to your Anvil IP

# API credentials
hammerspace_api_user: "admin"
hammerspace_api_password: "your-password"    # <-- Update password

# Skip SSL validation (for self-signed certs)
hammerspace_api_validate_certs: false
```

#### NFS Export Configuration

```yaml
# Hammerspace node IPs (require no_root_squash)
hammerspace_nodes:
  - "10.241.0.105"    # <-- Anvil cluster IP

mover_nodes:
  - "10.241.0.10"     # <-- DI/Mover node IPs
  - "10.241.0.11"

# Client subnets (use root_squash)
client_subnets:
  - "10.200.104.0/24"
  - "10.200.105.0/24"
```

#### Storage Configuration (Usually No Changes Needed)

```yaml
# Dynamic NVMe discovery (recommended)
use_dynamic_discovery: true

# RAID level (0 for Tier 0)
raid_level: 0

# Mount point base path
mount_base_path: /hammerspace
```

---

## 6. Run Preflight Check

The preflight check compares your OCI inventory with Hammerspace to identify new instances that need deployment.

### 6.1 Run Preflight Check

```bash
ansible-playbook preflight_check.yml -i inventory.oci.yml
```

### 6.2 Review the Report

**Example output:**
```
================================================================================
PREFLIGHT CHECK REPORT
================================================================================
Hammerspace API: 10.241.0.105

SUMMARY
--------------------------------------------------------------------------------
Inventory hosts (storage_servers): 10
Hammerspace registered nodes:      7
Already registered:                7
New instances to deploy:           3

NEW INSTANCES (need deployment)
--------------------------------------------------------------------------------
- instance20260201011850
- instance20260201011851
- instance20260201011852

================================================================================
RECOMMENDED COMMANDS
================================================================================
# Deploy to new instances only:
ansible-playbook site.yml --limit "instance20260201011850,instance20260201011851,instance20260201011852"
================================================================================
```

### 6.3 Output Files

| File | Description |
|------|-------------|
| `.new_instances_limit` | List of new instance names for `--limit` |
| `preflight_report.txt` | Full report saved to disk |

---

## 7. Deploy to New Instances

### Option A: Using the Deployment Script (Recommended)

```bash
# Interactive mode - prompts for confirmation
./deploy_new_instances.sh -i inventory.oci.yml

# Dry run first (recommended)
./deploy_new_instances.sh -i inventory.oci.yml --check

# Auto mode (no confirmation)
./deploy_new_instances.sh -i inventory.oci.yml --auto
```

### Option B: Manual Commands

```bash
# Step 1: Dry run to verify changes
ansible-playbook site.yml -i inventory.oci.yml --limit @.new_instances_limit --check

# Step 2: Run precheck only
ansible-playbook site.yml -i inventory.oci.yml --limit @.new_instances_limit --tags precheck

# Step 3: Full deployment
ansible-playbook site.yml -i inventory.oci.yml --limit @.new_instances_limit
```

### Option C: Deploy to Specific Instances

```bash
# Single instance
ansible-playbook site.yml -i inventory.oci.yml --limit "instance20260201011850"

# Multiple instances
ansible-playbook site.yml -i inventory.oci.yml --limit "instance20260201011850,instance20260201011851"

# Pattern matching
ansible-playbook site.yml -i inventory.oci.yml --limit "instance202602*"
```

### Option D: Throttled Deployment (Large Clusters)

For deployments with many nodes (10+), throttle API calls to avoid overwhelming Anvil:

```bash
# Process 2 nodes at a time (serial play)
ansible-playbook site.yml -i inventory.oci.yml -e hammerspace_serial=2
```

Or set persistently in `vars/main.yml`:
```yaml
hammerspace_serial: 2                  # Process 2 nodes at a time (0 = all parallel)
```

### Deployment Progress

The playbook will execute these roles in order:

| Step | Role | Description |
|------|------|-------------|
| 1 | `nvme_discovery` | Discover NVMe drives, group by NUMA |
| 2 | `precheck` | Validate drives, network, packages |
| 3 | `raid_setup` | Create mdadm RAID arrays |
| 4 | `filesystem_setup` | Create XFS filesystems |
| 5 | `nfs_setup` | Configure NFS server and exports |
| 6 | `firewall_setup` | Open NFS and RDMA ports |
| 7 | `hammerspace_integration` | Register node and volumes via API |

---

## 8. Verify Deployment

### 8.1 Verify on Target Instances

SSH to a deployed instance and check:

```bash
# Check RAID arrays
cat /proc/mdstat

# Check mounts
df -h | grep hammerspace

# Check NFS exports
exportfs -v

# Check NFS service
systemctl status nfs-server

# Test local mount
showmount -e localhost
```

### 8.2 Verify in Hammerspace

**Via Anvil CLI:**
```bash
anvil> node-list
anvil> volume-list
anvil> volume-list --node-name instance20260201011850
```

**Via API:**
```bash
# List all nodes
curl -sk -u admin:password https://10.241.0.105:8443/mgmt/v1.2/rest/nodes | jq '.[].name'

# List volumes for a node
curl -sk -u admin:password https://10.241.0.105:8443/mgmt/v1.2/rest/storage-volumes | jq '.[] | select(.nodeName | contains("instance20260201"))'
```

### 8.3 Run Verification Playbook

```bash
ansible-playbook verify_nfs.yml -i inventory.oci.yml --limit @.new_instances_limit
```

---

## 9. Availability Zone (AZ) Configuration with GPU Fabric

For multi-AZ deployments, Hammerspace uses AZ prefixes (e.g., `AZ1:`, `AZ2:`) to ensure data placement and redundancy across failure domains. On OCI GPU instances, the **GPU Memory Fabric** determines which instances share the same high-speed interconnect and should be grouped in the same AZ.

### 9.1 Understanding GPU Memory Fabric

| Concept | Description |
|---------|-------------|
| **GPU Memory Fabric** | OCI's high-bandwidth interconnect linking GPUs within a cluster |
| **Fabric OCID** | Unique identifier for each GPU fabric (e.g., `ocid1.computegpumemoryfabric.oc1...`) |
| **AZ Mapping** | Instances sharing the same GPU fabric OCID = Same AZ |

**Why GPU Fabric for AZ?**
- Instances on the same GPU fabric have ultra-low latency between them
- GPU fabric boundaries represent natural failure domains
- Distributing data across fabrics provides true redundancy

### 9.2 AZ Mapping Logic

```
GPU Fabric OCID                                    → AZ
─────────────────────────────────────────────────────────
ocid1.computegpumemoryfabric.oc1...aaaa (1st unique) → AZ1
ocid1.computegpumemoryfabric.oc1...bbbb (2nd unique) → AZ2
ocid1.computegpumemoryfabric.oc1...cccc (3rd unique) → AZ3
...
```

**Example:**
```
Instance              GPU Fabric (last 12 chars)    AZ
──────────────────────────────────────────────────────────
instance-001          ...slutj7sca                   AZ1
instance-002          ...slutj7sca                   AZ1  (same fabric)
instance-003          ...xk8m2pqrs                   AZ2
instance-004          ...xk8m2pqrs                   AZ2  (same fabric)
instance-005          ...abc123xyz                   AZ3
```

### 9.3 Collect GPU Fabric Data

**Step 1:** Run the GPU fabric collection playbook:
```bash
ansible-playbook collect_gpu_fabric.yml -i inventory.oci.yml
```

**Output:**
```
============================================
GPU FABRIC DATA COLLECTED
============================================
Output file: gpu_fabric_data.txt
Instances: 10
Unique GPU fabrics (AZs): 3
============================================
```

**Step 2:** Review the collected data:
```bash
cat gpu_fabric_data.txt
```

**Example output:**
```
# GPU Fabric Data - Generated by collect_gpu_fabric.yml
# Format: gpu_fabric_ocid instance_name private_ip
ocid1.computegpumemoryfabric.oc1.us-sanjose-1.anqwyl...slutj7sca instance20260127011850 10.241.36.58
ocid1.computegpumemoryfabric.oc1.us-sanjose-1.anqwyl...slutj7sca instance20260127011851 10.241.36.59
ocid1.computegpumemoryfabric.oc1.us-sanjose-1.anqwyl...xk8m2pqrs instance20260127011852 10.241.36.60
```

### 9.4 Assign AZ Prefixes to Volumes

After collecting GPU fabric data, assign AZ prefixes to Hammerspace volumes:

> **Credential setup (all scripts):** Use `--password-file` (recommended), `HAMMERSPACE_PASSWORD` env var, or interactive prompt. The `--password` flag still works for backward compatibility.
> ```bash
> echo 'your-password' > ~/.hs_password && chmod 600 ~/.hs_password
> ```

**Dry run (recommended first):**
```bash
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt \
  --dry-run
```

**Apply changes:**
```bash
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt
```

**Generate report only (CSV output):**
```bash
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt \
  --report-only
```

**Force a specific GPU fabric to a specific AZ (`--az-map`):**

Use `--az-map` to explicitly map a GPU fabric OCID to an AZ. This is useful when replacing an old GPU fabric with a new one and you want the new fabric to take over the same AZ number. Can be used multiple times. Explicit mappings override both learned and auto-assigned mappings.

```bash
# Dry run
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt \
  --az-map "ocid1.computegpumemoryfabric.oc1...newid=AZ3" \
  --dry-run

# Multiple explicit mappings
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt \
  --az-map "ocid1...fabric_a=AZ3" \
  --az-map "ocid1...fabric_b=AZ5"
```

### 9.5 Replacing a GPU Fabric AZ

When you need to replace an old GPU fabric (and its nodes) with a new one while keeping the same AZ number:

```bash
# 1. Check current AZ assignments
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 --user admin --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt --report-only

# 2. Collect GPU fabric for new replacement nodes
ansible-playbook collect_gpu_fabric.yml -i inventory.oci.yml \
  --limit "new-instance1,new-instance2,..."
# Note the new GPU fabric OCID from gpu_fabric_data.txt

# 3. Clean up old nodes and volumes from Hammerspace
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 --user admin --password-file ~/.hs_password \
  --node old-instance1 --node old-instance2 \
  --parallel 5

# 4. Deploy new nodes
ansible-playbook site.yml -i inventory.oci.yml \
  --limit "new-instance1,new-instance2,..."

# 5. Assign the old AZ number to the new GPU fabric
python3 assign_az_to_volumes.py \
  --host 10.241.0.105 --user admin --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt \
  --az-map "ocid1.computegpumemoryfabric.oc1...new_fabric_id=AZ3" \
  --dry-run
```

### 9.6 On-Premises AZ via Inventory Groups

For on-premises deployments without cloud metadata, define AZ groups directly in your static inventory:

```yaml
# inventory.yml
all:
  children:
    storage_servers:
      children:
        AZ1:
          hosts:
            node101:
              ansible_host: 10.200.101.216
            node102:
              ansible_host: 10.200.101.182
        AZ2:
          hosts:
            node201:
              ansible_host: 10.200.103.188
            node202:
              ansible_host: 10.200.103.228
        AZ3:
          hosts:
            node301:
              ansible_host: 10.200.100.135
            node302:
              ansible_host: 10.200.103.24
```

Enable AZ prefix in `vars/main.yml`:
```yaml
hammerspace_volume_az_prefix_enabled: true
```

The playbook automatically detects `AZ<N>` group names from `group_names` and uses them as volume prefixes. No per-host variables or prefix mode needed — this is a built-in fallback in the AZ detection chain.

**Result:** Volume names like `AZ1:node101::/hammerspace/hsvol0`, `AZ2:node201::/hammerspace/hsvol0`, etc.

### 9.7 Alternative: Fault Domain-Based AZ

For non-GPU instances or simpler deployments, use OCI Fault Domains instead:

| OCI Fault Domain | Hammerspace AZ |
|------------------|----------------|
| FAULT-DOMAIN-1 | AZ1 |
| FAULT-DOMAIN-2 | AZ2 |
| FAULT-DOMAIN-3 | AZ3 |

This mapping is **automatic** when using the OCI dynamic inventory. The `hammerspace_volume_az_prefix` is set based on fault domain:

```yaml
# In inventory.oci.yml (already configured)
compose:
  hammerspace_volume_az_prefix: fault_domain | regex_replace('FAULT-DOMAIN-', 'AZ') ~ ":"
```

### 9.8 Verify AZ Assignment

**Check volume names in Hammerspace:**
```bash
# Via Anvil CLI
anvil> volume-list

# Via API
curl -sk -u admin:password https://10.241.0.105:8443/mgmt/v1.2/rest/storage-volumes | \
  jq -r '.[] | "\(.name) -> \(.nodeName)"'
```

**Expected output with AZ prefixes:**
```
AZ1:instance20260127011850::/hammerspace/hsvol0
AZ1:instance20260127011851::/hammerspace/hsvol0
AZ2:instance20260127011852::/hammerspace/hsvol0
AZ3:instance20260127011853::/hammerspace/hsvol0
```

### 9.9 AZ Best Practices

| Recommendation | Description |
|----------------|-------------|
| **Minimum 4 AZs** | When data is stored only on Tier 0 |
| **6 AZs Recommended** | For optimal redundancy |
| **Symmetric Design** | Same number of nodes/volumes per AZ |
| **Re-run on New Instances** | Collect GPU fabric and assign AZ after adding instances |

---

## 10. Adding New Instances (Future Deployments)

When new GPU instances are added to OCI, follow these steps:

### 10.1 Quick Deployment

```bash
# One command to check and deploy new instances
./deploy_new_instances.sh -i inventory.oci.yml
```

### 10.2 Step-by-Step

```bash
# 1. Verify new instances are discovered
ansible-inventory -i inventory.oci.yml --graph

# 2. Run preflight check
ansible-playbook preflight_check.yml -i inventory.oci.yml

# 3. Review preflight_report.txt

# 4. Deploy to new instances
ansible-playbook site.yml -i inventory.oci.yml --limit @.new_instances_limit

# 5. Collect GPU fabric and assign AZ (if using GPU fabric-based AZ)
ansible-playbook collect_gpu_fabric.yml -i inventory.oci.yml
python3 assign_az_to_volumes.py --host <ANVIL_IP> --user admin --password-file ~/.hs_password \
  --gpu-fabric-file gpu_fabric_data.txt
```

### 10.3 Workflow Diagram

```
┌─────────────────────┐
│  New OCI Instances  │
│    Provisioned      │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Run Preflight      │
│  ansible-playbook   │
│  preflight_check.yml│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Review Report      │
│  New vs Registered  │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Deploy New Only    │
│  --limit @.new_     │
│  instances_limit    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Verify in          │
│  Hammerspace GUI    │
└─────────────────────┘
```

---

## 11. Data Instantiator (DI) Deployment

The Data Instantiator (DI / NFS Mover) moves file instances between storage volumes. DI nodes are typically separate from Tier 0 storage servers but connect to the same Hammerspace cluster.

### 11.1 Prerequisites

| Requirement | Description |
|-------------|-------------|
| DI Nodes | Linux servers (RHEL/Rocky 9, Ubuntu) with network access to Anvil |
| Packages | pd-di RPMs (from Hammerspace) — via URL, tarball, or `payload/` directory |
| Network | DI nodes must reach Anvil on port 8443 and expose ports 9095/9096 |
| Credentials | Same Hammerspace API credentials as Tier 0 |

### 11.2 Add DI Nodes to Inventory

Add a `di_nodes` group to your inventory file. For AZ distribution, nest DI nodes under AZ groups:

```yaml
# inventory.yml (add alongside storage_servers)
all:
  children:
    storage_servers:
      hosts:
        # ... your Tier 0 storage nodes ...

    di_nodes:
      children:
        AZ1:
          hosts:
            mover101:
              ansible_host: 10.0.12.100
              di_node_ip: 10.0.12.100
              di_node_name: mover101
        AZ2:
          hosts:
            mover201:
              ansible_host: 10.0.12.200
              di_node_ip: 10.0.12.200
              di_node_name: mover201
      vars:
        ansible_user: root
```

The precheck validates that DI nodes span at least `di_min_az_count` AZs (default: 2). Set `di_enforce_az_distribution: true` to make this a hard failure instead of a warning.

### 11.3 Configure DI Variables

Enable DI in `vars/main.yml`:

```yaml
# Master switch
deploy_di: true

# Activation control (false = install only, activate later)
di_activate: true

# Auto-wire DI IPs into Tier 0 NFS exports (eliminates manual mover_nodes editing)
di_auto_export: true

# Deployment mode: "host" (default) or "container"
di_deployment_type: "host"

# Package source: "directory" (default), "url", or "local"
di_rpm_source: "directory"

# Cluster connection (defaults to same as Tier 0 hammerspace_api_host)
hammerspace_cluster_mgmt_ip: "{{ hammerspace_api_host }}"
hammerspace_cluster_hostname: "data-cluster"
```

### 11.4 Prepare DI Packages

**Option A: Payload directory (recommended for air-gapped)**

Drop the RPMs and `add_node.py` into the `payload/` directory. Both x86_64 and aarch64 RPMs can coexist — the playbook selects the correct architecture automatically:

```bash
ls payload/
  pd-di-5.3.0-4321.el9.x86_64.rpm     # x86_64
  pd-di-5.3.0-4321.el9.aarch64.rpm    # ARM (optional)
  jemalloc-5.3.0-6.el9.x86_64.rpm
  lttng-tools-2.12.11-1.el9.x86_64.rpm
  lttng-ust-2.12.0-6.el9.x86_64.rpm
  libtirpc-1.3.3-10.hs.el9.x86_64.rpm
  babeltrace-1.5.8-10.el9.x86_64.rpm
  add_node.py
```

**Option B: URL download**

```yaml
di_rpm_source: "url"
di_tarball_url: "https://trans.doit.hammerspace.com/download/tier0/components/el9-components-5.1.41-452.tar.gz"
```

### 11.5 Deploy DI

```bash
# Deploy Tier 0 + DI together
ansible-playbook site.yml -i inventory.yml -e deploy_di=true

# Deploy only DI (skip Tier 0 roles)
ansible-playbook site.yml -i inventory.yml --tags di -e deploy_di=true

# Target specific DI node
ansible-playbook site.yml -i inventory.yml --tags di --limit "mover101" -e deploy_di=true

# Container mode
ansible-playbook site.yml -i inventory.yml -e deploy_di=true -e di_deployment_type=container
```

### 11.6 Pre-deploy / Activate Later

Pre-stage DI on nodes without starting services or registering. Activate only when needed (e.g., during decommission events):

```bash
# 1. Pre-deploy: install everything but don't start pd-di or register
ansible-playbook site.yml --tags di -i inventory.yml -e deploy_di=true -e di_activate=false

# 2. Later, activate specific nodes:
ansible-playbook site.yml --tags di-activate -i inventory.yml \
  -e deploy_di=true -e di_activate=true --limit "mover101"
```

### 11.7 Verify DI Deployment

```bash
# On the DI node
ssh mover101 "systemctl status pd-di"
ssh mover101 "firewall-cmd --list-all"

# In Hammerspace
anvil> node-list --name mover101
```

### 11.8 Decommission DI Nodes

```bash
# Dry run first
ansible-playbook decommission_di.yml -i inventory.yml --limit "mover101" --check

# Execute (runs serial: 1 — one node at a time)
ansible-playbook decommission_di.yml -i inventory.yml --limit "mover101"
```

The decommission playbook:
1. Evacuates data from volumes (configurable via `di_decommission_evacuate_data`)
2. Deletes volumes from Hammerspace
3. Removes the node from the cluster
4. Stops pd-di services on the host

---

## 12. Troubleshooting

### OCI Inventory Issues

**Problem:** `The oci dynamic inventory plugin requires oci python sdk`
```bash
# Solution: Install OCI SDK
pip3 install oci
```

**Problem:** `Unable to parse inventory`
```bash
# Verify OCI config
oci iam user get --user-id $(grep user ~/.oci/config | cut -d= -f2)

# Test inventory directly
ansible-inventory -i inventory.oci.yml --list
```

**Problem:** No hosts discovered
```bash
# Check filters in inventory.oci.yml
# Verify instance shape matches your filter
oci compute instance list --compartment-id <ocid> --query "data[].shape" --output table
```

### SSH Connection Issues

**Problem:** `Permission denied (publickey)`
```bash
# Verify SSH key path in ansible.cfg
# Test SSH manually
ssh -i /path/to/key ubuntu@<instance-ip>
```

**Problem:** `Connection timed out`
```bash
# Check security lists allow SSH (port 22)
# Verify you're connecting via correct network (VPN, bastion, etc.)
```

### Hammerspace API Issues

**Problem:** `Failed to connect to Hammerspace API`
```bash
# Test API connectivity
curl -sk -u admin:password https://10.241.0.105:8443/mgmt/v1.2/rest/nodes

# Check firewall allows port 8443
nc -zv 10.241.0.105 8443
```

**Problem:** `Node already exists`
```
# This is normal - the playbook skips existing nodes
# Check status: already registered vs newly added
```

### RAID/Storage Issues

**Problem:** `No NVMe drives found`
```bash
# SSH to instance and check
lsblk
ls /dev/nvme*
```

**Problem:** `Drive already in use`
```bash
# Check if drives are already mounted or in RAID
cat /proc/mdstat
mount | grep nvme
```

### Common Commands Reference

```bash
# Re-run specific roles
ansible-playbook site.yml -i inventory.oci.yml --tags precheck
ansible-playbook site.yml -i inventory.oci.yml --tags raid
ansible-playbook site.yml -i inventory.oci.yml --tags nfs
ansible-playbook site.yml -i inventory.oci.yml --tags nfs-exports  # Update /etc/exports only
ansible-playbook site.yml -i inventory.oci.yml --tags hammerspace

# Skip specific roles
ansible-playbook site.yml -i inventory.oci.yml --skip-tags hammerspace

# Verbose output for debugging
ansible-playbook site.yml -i inventory.oci.yml -vvv

# Check mode (dry run)
ansible-playbook site.yml -i inventory.oci.yml --check
```

---

## 13. Decommissioning Instances

When terminating GPU instances, you should first remove them from Hammerspace to avoid orphaned nodes and volumes.

### 13.1 Using the Cleanup Script

The `cleanup_instance_nodes.py` script removes nodes and their volumes from Hammerspace.

**Step 1: Dry run (see what will be deleted)**
```bash
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --dry-run
```

**Example output:**
```
Connecting to Hammerspace at 10.241.0.105...
Fetching nodes...
  Found 15 total nodes

Found 10 nodes starting with 'instance':
  - instance20260127011850 (UUID: abc123...)
  - instance20260127011851 (UUID: def456...)
  ...

Fetching storage volumes...
  Found 20 total volumes

[DRY RUN] Will delete 20 volumes from 10 nodes:

  Node: instance20260127011850
    - Volume: AZ1:instance20260127011850::/hammerspace/hsvol0
    - Volume: AZ1:instance20260127011850::/hammerspace/hsvol1
  ...

[DRY RUN] No changes made.
```

**Step 2: Execute cleanup**
```bash
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password
```

**Step 3: Execute cleanup (with parallel volume deletion)**
```bash
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --parallel 5
```

**Example output:**
```
Type 'yes' to confirm deletion: yes

PHASE 1: Deleting volumes (parallel: 5)...
  [instance20260127011850] Deleting volume: AZ1:instance20260127011850::/hammerspace/hsvol0...
    Volume 'AZ1:instance20260127011850::/hammerspace/hsvol0' still Executing, waiting...
  [instance20260127011850] ✓ Deleted: AZ1:instance20260127011850::/hammerspace/hsvol0
  [instance20260127011851] ✓ Deleted: AZ1:instance20260127011851::/hammerspace/hsvol0
  ...

PHASE 2: Deleting nodes...
  ✓ Deleted: instance20260127011850
  ✓ Deleted: instance20260127011851
  ...

SUMMARY
Volumes: 20 deleted, 0 failed
Nodes:   10 deleted, 0 failed, 0 skipped
```

> **Note:** Each volume deletion is a blocking operation — the script waits indefinitely for Hammerspace to fully remove the volume before the worker picks up the next one. With `--parallel 5`, up to 5 volumes are deleted concurrently. If any volume fails to delete, the corresponding node is skipped to prevent data loss.

### 13.2 Cleanup Options

| Option | Description |
|--------|-------------|
| `--host` | Hammerspace Anvil IP (required) |
| `--user` | API username (required) |
| `--password` | API password (or use `--password-file` / `HAMMERSPACE_PASSWORD` env) |
| `--list-nodes` | List all nodes and exit (no deletion) |
| `--prefix` | Match nodes starting with prefix |
| `--contains` | Match nodes containing string |
| `--pattern` | Match nodes using regex pattern |
| `--node NAME` | Match specific node name (repeatable) |
| `--parallel N` | Delete N volumes concurrently, each waiting for full removal (default: 1) |
| `--dry-run` | Show what would be deleted without deleting |
| `--yes`, `-y` | Skip confirmation prompt |

**List all nodes first:**
```bash
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --list-nodes
```

**Filter examples:**
```bash
# Delete nodes STARTING WITH "bu-test"
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --prefix "bu-test" \
  --dry-run

# Delete nodes CONTAINING "test"
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --contains "test" \
  --dry-run

# Delete nodes matching REGEX pattern
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --pattern "^bu-.*-01$" \
  --dry-run

# Delete SPECIFIC nodes by name
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --node bu-test-01 \
  --node bu-test-02 \
  --dry-run

# Parallel volume deletion (5 at a time)
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --contains "test" \
  --parallel 5

# Skip confirmation (for automation)
python3 cleanup_instance_nodes.py \
  --host 10.241.0.105 \
  --user admin \
  --password-file ~/.hs_password \
  --contains "test" \
  --parallel 5 \
  --yes
```

### 13.3 Decommission Workflow

```
┌─────────────────────────┐
│  Identify instances     │
│  to decommission        │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│  Run cleanup script     │
│  with --dry-run         │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│  Review volumes/nodes   │
│  to be deleted          │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│  Run cleanup script     │
│  (confirm deletion)     │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│  Terminate OCI          │
│  instances              │
└─────────────────────────┘
```

### 13.4 Important Notes

| Warning | Description |
|---------|-------------|
| **Order matters** | Always remove from Hammerspace BEFORE terminating instances |
| **Data loss** | Deleting volumes removes data from Hammerspace metadata (NFS data on instance is lost when terminated) |
| **No undo** | Deletion is permanent - always use `--dry-run` first |
| **Prefix matching** | Script matches node names starting with prefix (case-insensitive) |

---

## Quick Reference Card

| Task | Command |
|------|---------|
| Test inventory | `ansible-inventory -i inventory.oci.yml --graph` |
| Ping all hosts | `ansible -i inventory.oci.yml storage_servers -m ping` |
| Preflight check | `ansible-playbook preflight_check.yml -i inventory.oci.yml` |
| Deploy new instances | `./deploy_new_instances.sh -i inventory.oci.yml` |
| Dry run | `ansible-playbook site.yml -i inventory.oci.yml --check` |
| Precheck only | `ansible-playbook site.yml -i inventory.oci.yml --tags precheck` |
| Full deploy | `ansible-playbook site.yml -i inventory.oci.yml` |
| Update NFS exports only | `ansible-playbook site.yml -i inventory.oci.yml --tags nfs-exports` |
| Verify NFS | `ansible-playbook verify_nfs.yml -i inventory.oci.yml` |
| Deploy DI (host mode) | `ansible-playbook site.yml -i inventory.yml --tags di -e deploy_di=true` |
| Deploy DI (container) | `ansible-playbook site.yml -i inventory.yml --tags di -e deploy_di=true -e di_deployment_type=container` |
| Decommission DI node | `ansible-playbook decommission_di.yml -i inventory.yml --limit "mover101"` |
| Reset Tier 0 host | `ansible-playbook reset-tier0-host.yml -i inventory.yml --limit "node01" -e reset_confirm=true` |
| Reset + blkdiscard | `ansible-playbook reset-tier0-host.yml -i inventory.yml --limit "node01" -e reset_confirm=true -e reset_run_blkdiscard=true` |
| Collect GPU fabric | `ansible-playbook collect_gpu_fabric.yml -i inventory.oci.yml` |
| Assign AZ to volumes | `python3 assign_az_to_volumes.py --host <IP> --gpu-fabric-file gpu_fabric_data.txt` |
| Assign AZ (explicit) | `python3 assign_az_to_volumes.py --host <IP> --gpu-fabric-file gpu_fabric_data.txt --az-map "FABRIC_OCID=AZ3"` |
| List all nodes | `python3 cleanup_instance_nodes.py --host <IP> --user admin --password-file ~/.hs_password --list-nodes` |
| Cleanup (dry run) | `python3 cleanup_instance_nodes.py --host <IP> --user admin --password-file ~/.hs_password --contains "name" --dry-run` |
| Cleanup (execute) | `python3 cleanup_instance_nodes.py --host <IP> --user admin --password-file ~/.hs_password --contains "name"` |
| Cleanup (parallel) | `python3 cleanup_instance_nodes.py --host <IP> --user admin --password-file ~/.hs_password --contains "name" --parallel 5` |
| Avail-drop check | `python3 set_availability_drop.py --host <IP> --user admin --password-file ~/.hs_password --node <NAME> --check` |
| Avail-drop disable (pre-RMA) | `python3 set_availability_drop.py --host <IP> --user admin --password-file ~/.hs_password --node <NAME> --disable` |
| Avail-drop enable (post-RMA) | `python3 set_availability_drop.py --host <IP> --user admin --password-file ~/.hs_password --node <NAME> --enable` |
| Health check (post-restart) | `python3 set_availability_drop.py --host <IP> --user admin --password-file ~/.hs_password --node <NAME> --health-check` |
| Add volumes to group | `python3 add_volumes_to_group.py --host <IP> --user admin --password-file ~/.hs_password --group "group-name" --instances-file tier0_instances_limit` |
| List volume group members | `python3 add_volumes_to_group.py --host <IP> --user admin --password-file ~/.hs_password --group "group-name" --list` |
| Rename OCI instances (pattern) | `python3 rename_oci_instances_az.py --host <IP> --user admin --password-file ~/.hs_password --compartment-id <OCID> --name-pattern "^instance2026"` |
| Rename OCI instances (file) | `python3 rename_oci_instances_az.py --host <IP> --user admin --password-file ~/.hs_password --compartment-id <OCID> --instances-file tier0_instances_limit` |

---

## Support

For issues or questions:
- Check the main [README.md](README.md) for detailed configuration options
- Review `vars/main.yml` for all available settings
- Contact Hammerspace support for cluster-related issues
