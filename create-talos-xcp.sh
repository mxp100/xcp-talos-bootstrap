#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CLUSTER_NAME="talos-xcp"
NETWORK_NAME="vnic"                         # name-label сети в XCP-ng (меняйте при необходимости)
SR_NAME=""                                  # оставить пустым чтобы выбрать default SR
ISO_URL="https://github.com/siderolabs/talos/releases/download/v1.7.6/talos-amd64.iso"
ISO_LOCAL_PATH="/var/iso/talos-amd64.iso"
ISO_SR_NAME="ISO SR"
VM_BASE_NAME_CP="${CLUSTER_NAME}-cp"
VM_BASE_NAME_WK="${CLUSTER_NAME}-wk"
CP_COUNT=3
WK_COUNT=3

# IP-параметры
GATEWAY="192.168.10.1"
CIDR_PREFIX="24"
DNS_SERVER="1.1.1.1"

# Диапазоны IP
CP_IPS=("192.168.10.2" "192.168.10.3" "192.168.10.4")
WK_IPS=("192.168.10.10" "192.168.10.11" "192.168.10.12")

# Talos endpoint (можно указать VIP/адрес первого CP)
TALOS_ENDPOINT="https://192.168.10.2:6443"

# Пути к machineconfig-шаблонам (должны существовать до запуска)
# Содержимое — стандартные talos machineconfig для controlplane/worker, без секции network (ниже вставим сеть).
TEMPLATE_DIR="$(pwd)/seeds/templates"
CP_TEMPLATE="${TEMPLATE_DIR}/controlplane.yaml"
WK_TEMPLATE="${TEMPLATE_DIR}/worker.yaml"

# Папка для генерации индивидуальных сидов
SEEDS_DIR="$(pwd)/seeds"
ISO_DIR="/var/iso"

# Если используете talos.config.url вместо сидов, можно указать тут:
KERNEL_ARGS=""  # пример: "talos.platform=metal talos.config.url=http://your/http/<name>.yaml"

# ========= Helpers =========
xe_must() { xe "$@" >/dev/null; }

get_default_sr() {
  xe sr-list other-config:i18n-key=local-storage --minimal
}

get_pool_master() {
  xe pool-list --minimal | xargs -I{} xe pool-param-get uuid={} param-name=master
}

ensure_iso_sr() {
  local iso_sr
  iso_sr=$(xe sr-list name-label="${ISO_SR_NAME}" type=iso --minimal || true)
  if [[ -z "$iso_sr" ]]; then
    echo "Creating ISO SR..."
    local host_uuid sr_uuid pbd_uuid
    host_uuid=$(get_pool_master)
    mkdir -p "$ISO_DIR"
    sr_uuid=$(xe sr-create name-label="${ISO_SR_NAME}" type=iso device-config:location="$ISO_DIR" device-config:legacy_mode=true content-type=iso)
    pbd_uuid=$(xe pbd-list sr-uuid="$sr_uuid" host-uuid="$host_uuid" --minimal)
    if [[ -z "$pbd_uuid" ]]; then
      pbd_uuid=$(xe pbd-create sr-uuid="$sr_uuid" host-uuid="$host_uuid" device-config:location="$ISO_DIR" device-config:legacy_mode=true)
    fi
    xe_must pbd-plug uuid="$pbd_uuid"
  fi
}

import_iso_if_needed() {
  mkdir -p "$ISO_DIR"
  if [[ ! -f "$ISO_LOCAL_PATH" ]]; then
    echo "Downloading Talos ISO..."
    wget -O "$ISO_LOCAL_PATH" "$ISO_URL"
  fi
  ensure_iso_sr
  echo "Talos ISO ready at $ISO_LOCAL_PATH"
}

find_network_uuid() {
  local name="$1"
  xe network-list name-label="$name" --minimal
}

create_seed_iso_from_mc() {
  # Генерирует seed ISO (cidata) для Talos c network статикой и machineconfig
  # user-data: talos machineconfig с вшитой сетью
  # meta-data: уникальные hostname/instance-id
  local vmname="$1"
  local ip="$2"
  local role="$3"          # cp | wk
  local out_iso="${ISO_DIR}/${vmname}-seed.iso"

  local src_dir="${SEEDS_DIR}/${vmname}"
  mkdir -p "$src_dir"

  # Выбор шаблона machineconfig
  local template_file
  if [[ "$role" == "cp" ]]; then
    template_file="$CP_TEMPLATE"
  else
    template_file="$WK_TEMPLATE"
  fi

  if [[ ! -f "$template_file" ]]; then
    echo "Template not found: $template_file"
    exit 1
  fi

  # Собираем user-data: вставляем сеть в machineconfig
  # Пример блока сети Talos (metal):
  #   network:
  #     interfaces:
  #       - interface: eth0
  #         addresses:
  #           - 192.168.10.2/24
  #         routes:
  #           - network: 0.0.0.0/0
  #             gateway: 192.168.10.1
  #         dhcp: false
  #     dns:
  #       servers:
  #         - 1.1.1.1
  cat > "${src_dir}/user-data" <<'EOF'
#cloud-config
EOF

  {
    echo "# talos machineconfig follows"
    # Вставляем содержимое шаблона
    cat "$template_file"
    echo ""
    echo "network:"
    echo "  interfaces:"
    echo "    - interface: eth0"
    echo "      dhcp: false"
    echo "      addresses:"
    echo "        - ${IP_CIDR}"
    echo "      routes:"
    echo "        - network: 0.0.0.0/0"
    echo "          gateway: ${GW}"
    echo "  dns:"
    echo "    servers:"
    echo "      - ${DNS}"
    echo ""
    echo "cluster:"
    echo "  endpoint: ${ENDPOINT}"
  } | IP_CIDR="${ip}/${CIDR_PREFIX}" GW="${GATEWAY}" DNS="${DNS_SERVER}" ENDPOINT="${TALOS_ENDPOINT}" tee -a "${src_dir}/user-data" >/dev/null

  # meta-data
  cat > "${src_dir}/meta-data" <<EOF
instance-id: ${vmname}
local-hostname: ${vmname}
EOF

  # Сборка ISO
  echo "Creating seed ISO for $vmname at $out_iso"
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -volid cidata -joliet -rock -o "$out_iso" -graft-points "user-data=${src_dir}/user-data" "meta-data=${src_dir}/meta-data"
  else
    mkisofs -quiet -V cidata -J -R -o "$out_iso" -graft-points "user-data=${src_dir}/user-data" "meta-data=${src_dir}/meta-data"
  fi

  echo "$out_iso"
}

attach_iso() {
  local vm_uuid="$1"
  local iso_path="$2"
  local iso_name
  iso_name=$(basename "$iso_path")
  local cd_vbd
  cd_vbd=$(xe vbd-list vm-uuid="$vm_uuid" type=CD --minimal)
  if [[ -z "$cd_vbd" ]]; then
    cd_vbd=$(xe vbd-create vm-uuid="$vm_uuid" type=CD device=3 bootable=true mode=RO empty=true)
  fi
  xe_must vbd-param-set uuid="$cd_vbd" userdevice=3
  xe_must vm-cd-add vm="$vm_uuid" cd-name="$iso_name" device=3
}

attach_second_iso() {
  local vm_uuid="$1"
  local iso_path="$2"
  local iso_name
  iso_name=$(basename "$iso_path")
  local cd_vbd2
  cd_vbd2=$(xe vbd-create vm-uuid="$vm_uuid" type=CD device=4 bootable=false mode=RO empty=true)
  xe_must vbd-param-set uuid="$cd_vbd2" userdevice=4
  xe_must vm-cd-add vm="$vm_uuid" cd-name="$iso_name" device=4
}

create_vm() {
  local name="$1"
  local vcpu="$2"
  local ram_gib="$3"
  local disk_gib="$4"
  local net_uuid="$5"
  local sr_uuid="$6"
  local kernel_args="$7"

  echo "Creating VM $name"
  local template_uuid vm_uuid vdi_uuid vbduuid vif_uuid

  template_uuid=$(xe template-list name-label="Other install media" --minimal)
  vm_uuid=$(xe vm-clone new-name-label="$name" uuid="$template_uuid")
  xe_must vm-param-set uuid="$vm_uuid" is-a-template=false
  xe_must vm-param-set uuid="$vm_uuid" name-description="Talos Linux node"

  xe_must vm-param-set uuid="$vm_uuid" VCPUs-max="$vcpu" VCPUs-at-startup="$vcpu"
  local bytes=$((ram_gib*1024*1024*1024))
  xe_must vm-memory-set uuid="$vm_uuid" static-min=$bytes dynamic-min=$bytes dynamic-max=$bytes static-max=$bytes

  # vNIC
  vif_uuid=$(xe vif-create vm-uuid="$vm_uuid" network-uuid="$net_uuid" device=0)
  xe_must vif-param-set uuid="$vif_uuid" other-config:ethtool-gso="off"

  # Диск
  vdi_uuid=$(xe vdi-create name-label="${name}-disk" sr-uuid="$sr_uuid" type=User virtual-size=$((disk_gib*1024*1024*1024)))
  vbduuid=$(xe vbd-create vm-uuid="$vm_uuid" vdi-uuid="$vdi_uuid" device=0 bootable=true type=Disk mode=RW)
  xe_must vbd-param-set uuid="$vbduuid" userdevice=0

  # PV boot
  xe_must vm-param-set uuid="$vm_uuid" HVM-boot-policy=""
  xe_must vm-param-set uuid="$vm_uuid" PV-bootloader="pygrub"
  if [[ -n "$kernel_args" ]]; then
    xe_must vm-param-set uuid="$vm_uuid" PV-args="$kernel_args"
  fi

  echo "$vm_uuid"
}

main() {
  echo "Preparing..."
  local net_uuid sr_uuid default_sr
  net_uuid=$(find_network_uuid "$NETWORK_NAME")
  if [[ -z "$net_uuid" ]]; then
    echo "Network '$NETWORK_NAME' not found."
    exit 1
  fi

  if [[ -z "$SR_NAME" ]]; then
    default_sr=$(get_default_sr)
    if [[ -z "$default_sr" ]]; then
      echo "Default SR not found. Set SR_NAME."
      exit 1
    fi
    sr_uuid="$default_sr"
  else
    sr_uuid=$(xe sr-list name-label="$SR_NAME" --minimal)
    if [[ -z "$sr_uuid" ]]; then
      echo "SR '$SR_NAME' not found."
      exit 1
    fi
  fi

  import_iso_if_needed

  # Control-plane
  for i in $(seq 1 "$CP_COUNT"); do
    local name="${VM_BASE_NAME_CP}${i}"
    local ip="${CP_IPS[$((i-1))]}"
    local vm_uuid
    vm_uuid=$(create_vm "$name" 2 4 20 "$net_uuid" "$sr_uuid" "$KERNEL_ARGS")
    attach_iso "$vm_uuid" "$ISO_LOCAL_PATH"
    local seed_iso
    seed_iso=$(create_seed_iso_from_mc "$name" "$ip" "cp")
    attach_second_iso "$vm_uuid" "$seed_iso"
    echo "Created CP VM: $name ($ip) uuid=$vm_uuid"
  done

  # Workers
  for i in $(seq 1 "$WK_COUNT"); do
    local name="${VM_BASE_NAME_WK}${i}"
    local ip="${WK_IPS[$((i-1))]}"
    local vm_uuid
    vm_uuid=$(create_vm "$name" 4 16 100 "$net_uuid" "$sr_uuid" "$KERNEL_ARGS")
    attach_iso "$vm_uuid" "$ISO_LOCAL_PATH"
    local seed_iso
    seed_iso=$(create_seed_iso_from_mc "$name" "$ip" "wk")
    attach_second_iso "$vm_uuid" "$seed_iso"
    echo "Created WK VM: $name ($ip) uuid=$vm_uuid"
  done

  echo "Done. Start VMs when ready, e.g.:"
  echo "xe vm-start name-label=${VM_BASE_NAME_CP}1"
}

main "$@"