# Talos Linux on XCP-ng Cluster Automation

A Bash script to automate the deployment of Talos Linux clusters on XCP-ng/XenServer hypervisor with configurable control plane and worker nodes.

## Features

- **Automated VM Creation**: Creates and configures VMs for Talos Linux control plane and worker nodes
- **Static IP Configuration**: Assigns static IPs to all nodes with customizable network settings
- **Seed ISO Generation**: Automatically generates machine configuration seed ISOs for each node
- **HVM Mode**: Uses hardware-assisted virtualization for better performance
- **Flexible Configuration**: Supports custom CPU, RAM, disk sizes via environment variables
- **Reconciliation**: Automatically removes excess VMs when scaling down
- **Bootstrap Support**: Optional cluster bootstrapping and Cilium CNI installation
- **Seeds-only Mode**: Generate configuration files without creating VMs

## Prerequisites

The script will automatically install required tools on XCP-ng host:
- `talosctl` - Talos Linux CLI
- `kubectl` - Kubernetes CLI
- `helm` - Kubernetes package manager
- `yq` - YAML processor
- `genisoimage` - ISO creation tool
- `curl` (static build for XCP-ng)

## Quick Start

### 1. Clone or download the script

```shell script
chmod +x create-talos-xcp.sh
```


### 2. Create a `.env` file (optional)

```shell script
# Cluster configuration
CLUSTER_NAME=talos-xcp
NETWORK_NAME=vnic
SR_NAME=

# Control plane nodes
CP_COUNT=3
CP_CPU=2
CP_RAM=4
CP_DISK=20

# Worker nodes
WK_COUNT=3
WK_CPU=4
WK_RAM=16
WK_DISK=100

# Network configuration
GATEWAY=192.168.10.1
CIDR_PREFIX=24
DNS_SERVER=8.8.8.8,1.1.1.1
CP_IPS=192.168.10.2,192.168.10.3,192.168.10.4
WK_IPS=192.168.10.10,192.168.10.11,192.168.10.12
VIP_IP=192.168.10.50

# Talos image URLs
ISO_URL=https://factory.talos.dev/image/f2aa06dc76070d9c9fbec2d5fee1abf452f7fccd91637337e3d868c074242fae/v1.11.3/metal-amd64.iso
ISO_INSTALLER_URL=factory.talos.dev/metal-installer/f2aa06dc76070d9c9fbec2d5fee1abf452f7fccd91637337e3d868c074242fae:v1.11.3
```


### 3. Run the script

```shell script
# Generate configs and create VMs (but don't start them)
./create-talos-xcp.sh

# Create VMs and start them
./create-talos-xcp.sh --start-vms

# Full deployment: create, start, and bootstrap cluster
./create-talos-xcp.sh --bootstrap

# Generate seed configs only (no VM creation)
./create-talos-xcp.sh --seeds-only
```


## Usage Options

```shell script
./create-talos-xcp.sh [OPTIONS]

Options:
  --seeds-only    Generate seed configuration files only, skip VM creation
  --start-vms     Start all VMs after creation
  --bootstrap     Start VMs and bootstrap the Talos cluster (includes Cilium installation)
```


## Configuration Options

### Cluster Settings
- `CLUSTER_NAME` - Cluster name (default: `talos-xcp`)
- `NETWORK_NAME` - XCP-ng network name to use (default: `vnic`)
- `SR_NAME` - Storage repository name (default: pool default SR)

### Control Plane Configuration
- `CP_COUNT` - Number of control plane nodes (default: `3`)
- `CP_CPU` - vCPUs per control plane node (default: `2`)
- `CP_RAM` - RAM in GiB per control plane node (default: `4`)
- `CP_DISK` - Disk size in GiB per control plane node (default: `20`)

### Worker Configuration
- `WK_COUNT` - Number of worker nodes (default: `3`)
- `WK_CPU` - vCPUs per worker node (default: `4`)
- `WK_RAM` - RAM in GiB per worker node (default: `16`)
- `WK_DISK` - Disk size in GiB per worker node (default: `100`)
- `WK_EXTRA_DISK_ENABLED` - Enable additional disk for workers (default: `false`)
- `WK_EXTRA_DISK_SIZE` - Size of additional disk in GiB (default: `100`)

### Network Configuration
- `GATEWAY` - Network gateway IP (default: `192.168.10.1`)
- `CIDR_PREFIX` - Network prefix length (default: `24`)
- `DNS_SERVER` - Comma-separated DNS servers (default: `8.8.8.8,1.1.1.1`)
- `CP_IPS` - Comma-separated control plane IPs (default: `192.168.10.2,192.168.10.3,192.168.10.4`)
- `WK_IPS` - Comma-separated worker IPs (default: `192.168.10.10,192.168.10.11,192.168.10.12`)
- `EXTERNAL_IPS` - Comma-separated external IPs for API server SANs
- `VIP_IP` - Virtual IP for control plane HA (default: `192.168.10.50`)

### Advanced Settings
- `RECONCILE` - Remove excess VMs when scaling down (default: `true`)
- `SEEDS_DIR` - Directory for seed configs (default: `./seeds`)
- `ISO_DIR` - Directory for ISO files (default: `/opt/iso`)

## Generated Files

After running the script, the following structure is created:

```
./
├── config/
│   ├── controlplane.yaml    # Control plane machine config template
│   ├── worker.yaml          # Worker machine config template
│   ├── talosconfig          # Talos CLI configuration
│   └── kubeconfig           # Kubernetes CLI configuration (after bootstrap)
└── seeds/
    ├── talos-xcp-cp1/       # Individual node configs
    │   └── config.yaml
    ├── talos-xcp-cp2/
    │   └── config.yaml
    └── ...
```


## Accessing the Cluster

After successful bootstrap:

```shell script
# Set kubeconfig
export KUBECONFIG=$(pwd)/config/kubeconfig

# Check cluster status
kubectl get nodes

# Use talosctl
export TALOSCONFIG=$(pwd)/config/talosconfig
talosctl --nodes <node-ip> health
```


## Scaling

To scale the cluster, modify `CP_COUNT` or `WK_COUNT` in `.env` and re-run the script:

```shell script
# Scale up workers to 5
echo "WK_COUNT=5" >> .env
./create-talos-xcp.sh --start-vms

# Scale down (with RECONCILE=true, excess VMs will be removed)
echo "WK_COUNT=2" >> .env
./create-talos-xcp.sh
```


## Cilium CNI

The script automatically installs Cilium CNI when using `--bootstrap`. Configuration:
- IPAM mode: kubernetes
- kube-proxy replacement: disabled
- Version: 1.18.3

## Troubleshooting

### VMs won't start
- Check SR availability: `xe sr-list`
- Verify network exists: `xe network-list name-label=<NETWORK_NAME>`

### Talos API not responding
- Verify VMs are running: `xe vm-list`
- Check VM console: `xe console uuid=<vm-uuid>`
- Ensure seed ISO was properly attached

### Bootstrap fails
- Verify all control plane nodes are healthy
- Check Talos logs: `talosctl --nodes <node-ip> logs`
- Ensure VIP is accessible

## License

This script is provided as-is for deploying Talos Linux on XCP-ng environments.