# Ansible Automation for Hammerspace Tier 0 / LSS Storage Setup

This Ansible project automates the setup of RAID arrays, filesystems, NFS exports, and firewall configuration for **Hammerspace Tier 0** and **Linux Storage Server (LSS)** deployments, based on the [Hammerspace Tier 0 Deployment Guide v1.0](https://hammerspace.com).

## What is Tier 0?

Tier 0 transforms existing local NVMe storage on GPU servers into ultra-fast, persistent shared storage managed by Hammerspace. It delivers data directly to GPUs at local NVMe speeds, reducing checkpoint times and improving AI workload performance by up to 10x compared to networked storage.

## Features

### Storage & NFS
- **Dynamic NVMe Discovery**: Automatically discovers NVMe drives and groups them by NUMA node for optimal performance
- **Boot Drive Exclusion**: Automatically detects and excludes the boot drive from RAID configuration
- **Comprehensive Health Checks**: Validates drive count, mount status, NUMA balance, 4K sector size, MTU connectivity, and package availability
- **4K Sector Size Detection**: Identifies drives not using recommended 4096-byte sectors with optional formatting
- **RAID Configuration**: Creates mdadm arrays with Hammerspace-recommended settings (power-of-2 sizes, NUMA-aware grouping)
- **UUID-Based Mounts**: Uses filesystem UUIDs in `/etc/fstab` for reliable boot persistence
- **mdadm Persistence**: Generates `/etc/mdadm.conf` with proper settings and updates initramfs
- **Filesystem Setup**: Creates XFS filesystems with `agcount=512` per Hammerspace recommendations
- **NFS Server Configuration**: Deploys `/etc/nfs.conf` with 128 threads, NFSv4.2, and optional RDMA support
- **Export Management**: Configures exports with proper `no_root_squash` for Hammerspace nodes and `root_squash` for clients
- **Firewall Setup**: Opens required ports for NFS, including RDMA port 20049
- **iptables Flush**: Automatically flushes iptables rules at playbook start to prevent connectivity issues
- **Mount Point Protection**: systemd guard services and auto-remount watchdog to prevent accidental unmounts

### Hammerspace Integration
- **Node Registration**: Automatically registers storage servers via Anvil REST API
- **Volume Management**: Adds storage volumes with configurable thresholds and protection settings
- **Task Queue Throttling**: Prevents API overload by monitoring queued tasks (configurable min/max thresholds)
- **Volume Groups**: Creates volume groups for organizing volumes by AZ or location
- **Share Management**: Creates shares with configurable export options
- **Share Objectives**: Applies availability/durability objectives to shares
- **AZ Mapping**: Parses availability zone from node names and applies labels

### S3/Object Storage
- **S3 Node Integration**: Add AWS S3 or S3-compatible storage nodes
- **Object Storage Volumes**: Add S3 buckets as Hammerspace volumes
- **S3 Server**: Create internal S3 server for S3 protocol access
- **S3 Users**: Create and manage S3 users for authentication

### Cluster Configuration
- **DNS Configuration**: Update cluster DNS servers and search domains
- **Active Directory**: Join Hammerspace cluster to Active Directory
- **Site Name**: Configure cluster site name
- **Physical Location**: Set datacenter, room, rack, and position metadata
- **Prometheus Monitoring**: Enable Prometheus exporters for metrics collection

### Platform Support
- **Multi-Distribution Support**: Works on Debian, Ubuntu, RHEL, Rocky Linux, CentOS
- **Firewall Auto-Detection**: Automatically detects firewalld, UFW, or iptables

## Directory Structure

```
ansible-storage-setup/
├── ansible.cfg              # Ansible configuration
├── inventory.yml            # Static server inventory (manual)
├── inventory_oci.yml        # OCI dynamic inventory (auto-discovery)
├── site.yml                 # Main playbook
├── verify_nfs.yml           # NFS verification playbook
├── vars/
│   └── main.yml             # Main variables (customize this!)
└── roles/
    ├── nvme_discovery/          # Dynamic NVMe discovery by NUMA node
    ├── precheck/                # Pre-setup validation
    ├── raid_setup/              # RAID configuration with mdadm.conf persistence
    ├── filesystem_setup/        # Filesystem creation with UUID-based fstab
    ├── nfs_setup/               # NFS server configuration
    ├── firewall_setup/          # Firewall configuration (firewalld/ufw/iptables)
    └── hammerspace_integration/ # Anvil API integration
        ├── tasks/
        │   ├── main.yml             # Main integration orchestration
        │   ├── add_node.yml         # Register storage node
        │   ├── add_volume.yml       # Add storage volumes
        │   ├── create_share.yml     # Create shares
        │   ├── task_queue_wait.yml  # API throttling
        │   ├── volume_group_create.yml  # Volume groups
        │   ├── az_map.yml           # AZ label mapping
        │   ├── share_apply_objective.yml  # Share objectives
        │   ├── s3/                  # S3/Object storage tasks
        │   │   ├── add_s3_node.yml
        │   │   ├── add_object_storage_volume.yml
        │   │   ├── create_s3_server.yml
        │   │   └── create_s3_user.yml
        │   └── cluster/             # Cluster configuration tasks
        │       ├── dns_update.yml
        │       ├── ad_join.yml
        │       ├── change_site_name.yml
        │       ├── set_location.yml
        │       └── prometheus_enable.yml
        └── defaults/main.yml    # Default variables
```

## Quick Start

### 1. Prerequisites

Install Ansible on your control machine (laptop, workstation, or bastion):

```bash
# macOS
brew install ansible

# Linux/pip
pip install ansible --break-system-packages

# Install required collections
ansible-galaxy collection install -r requirements.yml
```

### 2. Configure Inventory

You can use either **static inventory** (manual) or **OCI dynamic inventory** (auto-discovery).

#### Option A: Static Inventory (Manual)

Edit `inventory.yml` to add your Tier 0 / LSS servers:

```yaml
all:
  children:
    storage_servers:
      hosts:
        tier0-node-01:
          ansible_host: 10.200.100.101
        tier0-node-02:
          ansible_host: 10.200.100.102
```

**Running locally on target server** (no SSH needed):
```yaml
all:
  children:
    storage_servers:
      hosts:
        localhost:
          ansible_connection: local
```

#### Option B: OCI Dynamic Inventory (Recommended for OCI)

Auto-discover instances from Oracle Cloud Infrastructure.

**1. Install OCI CLI:**
```bash
# Interactive install (prompts for directories)
sudo bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Non-interactive install (uses defaults)
sudo bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults

# Verify installation
oci --version
```

**2. Install OCI Ansible collection and Python SDK:**
```bash
# Install OCI Ansible collection
ansible-galaxy collection install oracle.oci

# Install OCI Python SDK
pip3 install oci
```

**3. Configure OCI authentication:**
```bash
# Create OCI config directory
mkdir -p ~/.oci

# Interactive setup (creates config file and API key)
oci setup config

# Or copy existing config from another machine
# scp user@source:~/.oci/config ~/.oci/
# scp user@source:~/.oci/oci_api_key.pem ~/.oci/
```

**4. Edit `inventory.oci.yml`:**

Note: The file MUST be named with `.oci.yml` extension for the OCI plugin to recognize it.

```yaml
---
plugin: oracle.oci.oci
regions:
  - us-sanjose-1  # Your region
fetch_hosts_from_subcompartments: true

hostname_format_preferences:
  - "private_ip"
  - "display_name"

# Filter to only running instances with specific shape
include_filters:
  - lifecycle_state: "RUNNING"
    shape: "VM.DenseIO.E5.Flex"  # Or BM.GPU.GB200-v3.4

# Create storage_servers group
groups:
  storage_servers: "'VM.DenseIO.E5.Flex' in shape"

# Set connection variables
compose:
  ansible_host: private_ip
  ansible_user: ubuntu
  ansible_python_interpreter: /usr/bin/python3
  ansible_become: true
```

**5. Update `ansible.cfg` to use dynamic inventory and SSH key:**
```ini
[defaults]
inventory = inventory.oci.yml
private_key_file = /home/ubuntu/.ssh/ansible_admin_key
```

**6. Test the inventory:**
```bash
# List discovered hosts
ansible-inventory -i inventory.oci.yml --list

# Show as graph
ansible-inventory -i inventory.oci.yml --graph

# Ping all storage servers
ansible storage_servers -m ping
```

**Find your compartment OCID:**
```bash
oci iam compartment list --query "data[].{name:name, id:id}" --output table
```

### 3. Configure Variables

Edit `vars/main.yml` to match your environment:

#### Dynamic Discovery (Recommended)

```yaml
# Enable automatic NVMe discovery grouped by NUMA node
use_dynamic_discovery: true

# RAID level (0=stripe, 1=mirror, 5=parity, 10=stripe+mirror)
raid_level: 0

# Mount point base path
mount_base_path: /hammerspace
```

With dynamic discovery enabled, the playbook will:
1. Discover all NVMe devices on the system
2. Identify and exclude the boot drive automatically
3. Group remaining drives by NUMA node
4. Create one RAID array per NUMA node for optimal performance

#### Hammerspace API Integration (Optional)

```yaml
# Anvil management IP (enables automatic cluster registration)
hammerspace_api_host: "10.1.2.3"
hammerspace_api_user: "admin"
hammerspace_api_password: "your_password"

# Node naming (use AZ prefix for availability zones)
hammerspace_node_name: "AZ1:tier0-node01"
```

#### Manual Configuration (Alternative)

```yaml
use_dynamic_discovery: false

raid_arrays:
  - name: md0
    device: /dev/md0
    level: 0
    drives:
      - /dev/nvme0n1
      - /dev/nvme1n1
      - /dev/nvme2n1
      - /dev/nvme3n1

mount_points:
  - path: /hammerspace/hsvol0
    device: /dev/md0
    fstype: xfs
    label: hammerspace-hsvol0
    mount_opts: defaults,nofail,discard
```

#### NFS Export Settings

```yaml
# Hammerspace Node IPs (require no_root_squash)
hammerspace_nodes:
  - "10.1.2.3"  # Anvil cluster management floating IP

mover_nodes:
  - "10.1.2.10"  # DI/Mover node IPs

# Client Subnets (use root_squash)
client_subnets:
  - "10.200.104.0/24"
  - "10.200.105.0/24"
```

### 4. Run the Playbook

```bash
# Discovery and pre-checks only (see what will be configured)
ansible-playbook site.yml --tags discovery,precheck

# Dry run (check mode)
ansible-playbook site.yml --check

# Full deployment (storage + NFS + optional Hammerspace integration)
ansible-playbook site.yml

# Run specific components
ansible-playbook site.yml --tags raid
ansible-playbook site.yml --tags nfs
ansible-playbook site.yml --tags firewall
ansible-playbook site.yml --tags hammerspace
```

## Running Ansible

You have several options for running this playbook:

| Method | Command | Use Case |
|--------|---------|----------|
| From workstation | `ansible-playbook -i inventory.yml site.yml` | Direct SSH access to targets |
| Locally on target | `ansible-playbook -i localhost, -c local site.yml` | No SSH, run on storage server |
| Via bastion/jump host | Configure `ansible_ssh_common_args` in inventory | Servers behind firewall |

### Using a Bastion Host

```yaml
# inventory.yml
storage_servers:
  hosts:
    plsm221h-01:
      ansible_host: 10.200.104.10
  vars:
    ansible_ssh_common_args: '-o ProxyJump=user@bastion.example.com'
```

## Dynamic NVMe Discovery

When `use_dynamic_discovery: true`, the playbook automatically:

1. **Detects boot device**: Uses `findmnt` to identify which NVMe contains the root filesystem
2. **Discovers NVMe devices**: Scans `/sys/class/nvme/` for all NVMe controllers
3. **Groups by NUMA node**: Reads `/sys/class/nvme/nvmeX/device/numa_node` for each device
4. **Creates RAID arrays**: One array per NUMA node for optimal memory locality

### Example Discovery Output

```
Boot device (excluded): nvme8

Devices by NUMA node:
NUMA 0: /dev/nvme4n1, /dev/nvme5n1, /dev/nvme6n1, /dev/nvme7n1
NUMA 1: /dev/nvme0n1, /dev/nvme1n1, /dev/nvme2n1, /dev/nvme3n1

DYNAMIC RAID CONFIGURATION:
md0 (/dev/md0):
  NUMA Node: 0
  RAID Level: 0
  Drives (4): /dev/nvme4n1, /dev/nvme5n1, /dev/nvme6n1, /dev/nvme7n1

md1 (/dev/md1):
  NUMA Node: 1
  RAID Level: 0
  Drives (4): /dev/nvme0n1, /dev/nvme1n1, /dev/nvme2n1, /dev/nvme3n1
```

## Pre-Setup Validation (Health Checks)

The `precheck` role performs comprehensive environment validation per Hammerspace Tier 0 Deployment Guide recommendations. Run with `--tags precheck` to validate before deployment.

### Health Checks Performed

| Check | Description | Configurable |
|-------|-------------|--------------|
| **NVMe Drive Count** | Validates expected number of drives present | `expected_nvme_count`, `enforce_drive_count` |
| **Drive Status** | Ensures drives aren't already mounted/in RAID/LVM | `fail_on_drives_in_use` |
| **NUMA Balance** | Warns if drives are unevenly distributed across NUMA nodes | `warn_on_numa_imbalance` |
| **4K Sector Size** | Checks if drives use recommended 4096-byte sectors | `expected_sector_size`, `require_4k_sectors` |
| **MTU / Jumbo Frames** | Tests network connectivity with jumbo frames | `expected_mtu`, `network_test_targets` |
| **Package Availability** | Checks for mdadm, xfsprogs, nvme-cli, etc. | `fail_on_missing_packages` |

### Configuration Options

```yaml
# vars/main.yml

# --- NVMe Drive Count ---
expected_nvme_count: 9        # Expected drives (including boot)
enforce_drive_count: false    # Set true to fail on mismatch

# --- Drive Status ---
fail_on_drives_in_use: true   # Fail if drives already mounted

# --- NUMA Balance ---
warn_on_numa_imbalance: true  # Warn on imbalanced NUMA nodes

# --- 4K Sector Size (per Tier 0 Guide Page 14) ---
expected_sector_size: 4096    # Recommended by Hammerspace
require_4k_sectors: false     # Set true to enforce

# --- MTU Testing ---
expected_mtu: 9000
network_test_targets:
  - "10.1.2.3"                # Anvil IP
  - "10.200.100.101"          # Other Tier 0 nodes
enforce_mtu_test: false       # Set true to fail on MTU issues
```

### 4K NVMe Sector Formatting

Per Hammerspace Tier 0 Deployment Guide (Page 14), NVMe drives should use 4096-byte sectors for optimal performance. The precheck role can optionally format drives:

```yaml
# Enable 4K formatting (DESTRUCTIVE!)
format_nvme_to_4k: true
nvme_format_confirm: "YES_I_UNDERSTAND_THIS_IS_DESTRUCTIVE"
```

**Warning**: This erases all data on the drives. Only use on new deployments.

### Example Precheck Output

```
PRE-SETUP VALIDATION SUMMARY
============================================
NVMe Drives:
  - Total found: 9
  - Expected: 9
  - In use (non-boot): 0
  - Boot device: nvme8

NUMA Balance:
  - NUMA 0: 4 drives
  - NUMA 1: 4 drives
  - Status: BALANCED

Sector Size:
  - Expected: 4096 bytes
  - Drives needing format: 0

Network:
  - MTU tests: 2/2 passed

Packages:
  - Missing: none
============================================
```

## Hammerspace API Integration

The playbook can automatically register the storage server with a Hammerspace cluster via the Anvil REST API. This eliminates the need for manual CLI commands.

Reference: [Hammerspace Ansible Examples](https://github.com/hammer-space/ansible)

### Enable API Integration

Add these variables to `vars/main.yml`:

```yaml
# Anvil management IP (required to enable integration)
hammerspace_api_host: "10.1.2.3"

# API credentials (admin role required)
hammerspace_api_user: "admin"
hammerspace_api_password: "your_secure_password"

# Skip SSL validation for self-signed certificates
hammerspace_api_validate_certs: false

# Node name (use AZ prefix for availability zones)
hammerspace_node_name: "AZ1:tier0-node01"
```

### Volume Settings

Configure volume thresholds and protection settings per Tier 0 Deployment Guide:

```yaml
# Threshold settings (values are decimals, e.g., 0.98 = 98%)
hammerspace_volume_high_threshold: 0.98    # utilizationThreshold - triggers evacuation
hammerspace_volume_low_threshold: 0.90     # utilizationEvacuationThreshold - target after evacuation

# Protection settings
hammerspace_volume_online_delay: 0         # --max-suspected-time (seconds)
hammerspace_volume_unavailable_multiplier: 1  # 0=--availability-drop-disabled, 1=--availability-drop-enabled
hammerspace_volume_availability: 2         # target availability level
hammerspace_volume_durability: 3           # target durability level
```

| Setting | CLI Equivalent | Description |
|---------|----------------|-------------|
| `hammerspace_volume_high_threshold` | `--high-threshold` | Utilization % that triggers data evacuation |
| `hammerspace_volume_low_threshold` | `--low-threshold` | Target utilization % after evacuation |
| `hammerspace_volume_online_delay` | `--max-suspected-time` | Seconds before volume goes suspected |
| `hammerspace_volume_unavailable_multiplier` | `--availability-drop-*` | 0=disabled, 1=enabled |

### What Gets Automated

When `hammerspace_api_host` is defined, the playbook will:

| Operation | API Endpoint | Description |
|-----------|--------------|-------------|
| Add Storage System | `POST /mgmt/v1.2/rest/nodes` | Registers server as type "OTHER" (NFS) |
| Add Storage Volumes | `POST /mgmt/v1.2/rest/storage-volumes` | Adds each mount point as a volume |
| Create Shares | `POST /mgmt/v1.2/rest/shares` | Optional: Creates Hammerspace shares |

### API Integration Output

```
HAMMERSPACE INTEGRATION COMPLETE
============================================
Anvil API: 10.1.2.3
Storage System: AZ1:tier0-node01
Volumes Added: 2
  - AZ1:tier0-node01::/hammerspace/hsvol0
  - AZ1:tier0-node01::/hammerspace/hsvol1

Verify in Hammerspace GUI or CLI:
  anvil> node-list
  anvil> storage-volume-list
============================================
```

### Creating Shares via API

To automatically create Hammerspace shares:

```yaml
hammerspace_create_shares: true

hammerspace_shares:
  - name: checkpoints
    path: /checkpoints
    export_options:
      - subnet: "10.200.104.0/24"
        accessPermissions: "RW"
        rootSquash: true

  - name: models
    path: /models
    export_options:
      - subnet: "*"
        accessPermissions: "RW"
        rootSquash: false
```

### Run Integration Only

If storage is already set up and you just need to register with Hammerspace:

```bash
ansible-playbook site.yml --tags hammerspace
```

## Persistence Configuration

### mdadm.conf

The playbook generates `/etc/mdadm.conf` with:

```conf
# mdadm.conf - Generated by Ansible
MAILADDR root
AUTO +all

ARRAY /dev/md0 metadata=1.2 UUID=abc123... name=server:md0
ARRAY /dev/md1 metadata=1.2 UUID=def456... name=server:md1
```

- Creates symlink `/etc/mdadm.conf` -> `/etc/mdadm/mdadm.conf` for RedHat compatibility
- Enables `mdmonitor` service for RAID health monitoring
- Updates initramfs to include RAID configuration

### fstab (UUID-based)

The playbook uses filesystem UUIDs in `/etc/fstab`:

```
UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890  /hammerspace/hsvol0  xfs  defaults,nofail,discard  0 0
UUID=f9e8d7c6-b5a4-3210-fedc-ba0987654321  /hammerspace/hsvol1  xfs  defaults,nofail,discard  0 0
```

UUID-based mounts ensure reliability even if device names change across reboots.

## Mount Point Protection

The playbook can deploy systemd-based mount protection to prevent accidental unmounting and ensure mounts automatically recover. Based on Hammerspace engineering guide "Protecting Linux Mount Points with systemd".

### Features

| Feature | Description |
|---------|-------------|
| **Boot Safety** | `nofail` and `x-systemd.automount` options ensure system boots even if storage is unavailable |
| **Guard Services** | Keeps a process with cwd on each mount point, preventing `umount` |
| **Auto-Remount Watchdog** | Timer checks every minute and remounts if accidentally unmounted |
| **RefuseManualStop** | Guard services cannot be stopped via `systemctl stop` |

### Enable Mount Protection

Add to `vars/main.yml`:

```yaml
# Enable all mount protection features
hammerspace_mount_protection: true

# Individual feature toggles (all default to true when protection is enabled)
hammerspace_mount_guard_enabled: true      # Guard services (busy-lock)
hammerspace_remount_watchdog_enabled: true # Auto-remount timer
hammerspace_remount_watchdog_interval: "1min"  # Check frequency
hammerspace_automount_timeout: 10          # Device timeout in seconds
```

### What Gets Deployed

When `hammerspace_mount_protection: true`:

**fstab options** (added automatically):
```
UUID=xxx  /hammerspace/hsvol0  xfs  defaults,nofail,x-systemd.automount,x-systemd.device-timeout=10  0 0
```

**systemd units**:
```
/etc/systemd/system/
├── hammerspace-guards.target           # Target for all guard services
├── hammerspace-hsvol0-guard.service    # Guard service per mount
├── hammerspace-hsvol1-guard.service
├── hammerspace-remount.service         # Remount check service
└── hammerspace-remount.timer           # Watchdog timer (runs every 1min)

/usr/local/bin/
└── hammerspace-remount-check.sh        # Script to check and remount
```

### How Guard Services Work

Each guard service runs `sleep infinity` with its working directory set to the mount point:

```ini
[Service]
ExecStart=/bin/bash -lc 'cd /hammerspace/hsvol0 && exec sleep infinity'
RefuseManualStop=yes
```

This makes the mount "busy" - attempting to unmount will fail:
```bash
$ umount /hammerspace/hsvol0
umount: /hammerspace/hsvol0: target is busy.
```

### Managing Protected Mounts

To intentionally unmount a protected mount point:

```bash
# 1. Stop the guard service (requires killing the process)
systemctl kill hammerspace-hsvol0-guard.service

# 2. Now unmount is possible
umount /hammerspace/hsvol0
```

To check protection status:
```bash
# View all guard services
systemctl list-units 'hammerspace-*-guard.service'

# Check watchdog timer
systemctl status hammerspace-remount.timer

# View recent remount activity
journalctl -t hammerspace-remount
```

## Hammerspace-Specific Configuration

### NFS Settings (per Tier 0 Deployment Guide)

The playbook configures `/etc/nfs.conf` with:

```ini
[nfsd]
threads=128
vers3=y
vers4.0=n
vers4.1=n
vers4.2=y
rdma=y          # If RDMA enabled
rdma-port=20049
```

### Export Options

Per Hammerspace recommendations:

| Client Type | Export Options |
|-------------|----------------|
| Hammerspace nodes (Anvil, DSX, Movers) | `rw,no_root_squash,sync,secure,mp,no_subtree_check` |
| Tier 0 / LSS clients | `rw,root_squash,sync,secure,mp,no_subtree_check` |

The `mp` (mountpoint) option prevents accidentally exporting empty directories if a filesystem isn't mounted.

### XFS Filesystem Options

```bash
mkfs.xfs -d agcount=512 -L <label> <device>
```

## Manual Hammerspace Integration

If not using API integration, you can manually register after running the playbook:

### 1. Add Node to Cluster

```bash
# From Hammerspace Anvil CLI
anvil> node-add --type OTHER --name AZ1:tier0-node01 --ip 10.200.100.101 --create-placement-objectives
```

### 2. Add Volumes

```bash
# Add each export as a volume (use AZ prefix for availability zones)
anvil> volume-add --name AZ1:tier0-node01::/hsvol0 \
  --node-name AZ1:tier0-node01 \
  --access-type read_write \
  --logical-volume-name /hsvol0 \
  --low-threshold 90 \
  --high-threshold 95 \
  --skip-performance-test
```

### 3. Create Shares

```bash
anvil> share-create --name checkpoints --path /checkpoints \
  --export-option "10.200.104.0/24,rw,root-squash"
```

### 4. Mount on Clients

```bash
mkdir /mnt/checkpoints
mount -o vers=4.2,nconnect=8,noatime <anvil_IP>:/checkpoints /mnt/checkpoints
```

## Availability Zones

For data protection, use the `AZx:` prefix naming convention:

```yaml
# Node and volume names should be prefixed with availability zone
hammerspace_node_name: "AZ1:tier0-node01"

# Results in volumes like:
# AZ1:tier0-node01::/hammerspace/hsvol0
# AZ1:tier0-node01::/hammerspace/hsvol1
```

Hammerspace recommends:
- Minimum 4 AZs when data is stored only on Tier 0
- 6 AZs recommended for optimal redundancy
- Symmetric design (same number of nodes/volumes per AZ)

## Troubleshooting

### Volume Goes "Suspected"

Common causes:
- Node was rebuilt
- NVMe reformatted or remounted to different path
- `mp` export option missing (exports empty directory)

Check:
```bash
# Verify exports
exportfs -v

# Check mount points
mount | grep hsvol

# Verify Hammerspace comb structure exists
ls -la /hsvol0/PrimaryData/
```

### RAID Array Not Assembling at Boot

```bash
# Check mdadm.conf exists and has correct UUIDs
cat /etc/mdadm.conf

# Verify arrays are defined
mdadm --detail --scan

# Regenerate initramfs
dracut --force        # RHEL/Rocky
update-initramfs -u   # Debian/Ubuntu
```

### Hammerspace API Errors

```bash
# Test API connectivity
curl -k -u admin:password https://10.1.2.3:8443/mgmt/v1.2/rest/nodes

# Check if node exists
curl -k -u admin:password https://10.1.2.3:8443/mgmt/v1.2/rest/nodes/AZ1%3Atier0-node01

# View API task status
curl -k -u admin:password https://10.1.2.3:8443/mgmt/v1.2/rest/tasks
```

### Mobility Failures

If file instances aren't being placed correctly:
- Verify DI/Mover nodes have `no_root_squash` access to all exports
- Check mover status in Hammerspace GUI
- Verify firewall ports 9095/9096 are open for DI nodes

## Requirements

- Ansible 2.9+
- Target servers running Debian/Ubuntu or RHEL/Rocky/CentOS
- SSH access with sudo privileges (or run locally with `ansible_connection: local`)
- Required collections: `ansible.posix`, `community.general`
- For API integration: Network access to Anvil management IP on port 8443

## References

- [Hammerspace Tier 0 Deployment Guide](https://hammerspace.com)
- [Hammerspace Ansible Examples](https://github.com/hammer-space/ansible)
- [Hammerspace Objectives Guide](https://hammerspace.com)
- [Hammerspace Toolkit (HSTK)](https://github.com/hammer-space/hstk)
- [Hammerspace Grafana Dashboards](https://github.com/hammer-space/grafana-dashboards)

## License

MIT
