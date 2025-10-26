#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CLUSTER_NAME="talos-xcp"
NETWORK_NAME="vnic"                         # name-label сети в XCP-ng (меняйте при необходимости)
SR_NAME=""                                  # оставить пустым чтобы выбрать default SR
ISO_URL="https://factory.talos.dev/image/53b20d86399013eadfd44ee49804c1fef069bfdee3b43f3f3f5a2f57c03338ac/v1.11.3/metal-amd64.iso"
ISO_LOCAL_PATH="/opt/iso/metal-amd64.iso"
ISO_SR_NAME="ISO SR"
VM_BASE_NAME_CP="${CLUSTER_NAME}-cp"
VM_BASE_NAME_WK="${CLUSTER_NAME}-wk"
CP_COUNT=3
WK_COUNT=3
RECONCILE=true   # если true — добавляем недостающие и удаляем лишние ВМ для соответствия CP_COUNT/WK_COUNT

# IP-параметры
GATEWAY="192.168.10.1"
CIDR_PREFIX="24"
DNS_SERVER="1.1.1.1"

# Диапазоны IP
CP_IPS=("192.168.10.2" "192.168.10.3" "192.168.10.4")
WK_IPS=("192.168.10.10" "192.168.10.11" "192.168.10.12")

# Пути к machineconfig-шаблонам (должны существовать до запуска)
# Содержимое — стандартные talos machineconfig для controlplane/worker, без секции network (ниже вставим сеть).
TEMPLATE_DIR="$(pwd)/seeds/templates"
CP_TEMPLATE="${TEMPLATE_DIR}/controlplane.yaml"
WK_TEMPLATE="${TEMPLATE_DIR}/worker.yaml"

# Папка для генерации индивидуальных сидов
SEEDS_DIR="$(pwd)/seeds"
ISO_DIR="/opt/iso"

# Optional kernel args
KERNEL_ARGS=""

# ========= Helpers =========
xe_must() {
  xe "$@" >/dev/null;
}

get_default_sr() {
  xe pool-list --minimal | xargs -I{} xe pool-param-get uuid={} param-name=default-SR
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
    if [[ -z "$host_uuid" ]]; then
      echo "Pool master UUID is empty. Check your pool configuration."
      exit 1
    fi
    mkdir -p "$ISO_DIR"
    sr_uuid=$(xe sr-create name-label="${ISO_SR_NAME}" type=iso device-config:location="$ISO_DIR" device-config:legacy_mode=true content-type=iso)
    if [[ -z "$sr_uuid" ]]; then
      echo "Failed to create ISO SR at ${ISO_DIR}"
      exit 1
    fi
    pbd_uuid=$(xe pbd-list sr-uuid="$sr_uuid" host-uuid="$host_uuid" --minimal)
    if [[ -z "$pbd_uuid" ]]; then
      pbd_uuid=$(xe pbd-create sr-uuid="$sr_uuid" host-uuid="$host_uuid" device-config:location="$ISO_DIR" device-config:legacy_mode=true)
    fi
    if [[ -z "$pbd_uuid" ]]; then
      echo "Failed to create/locate PBD for ISO SR"
      exit 1
    fi
    xe_must pbd-plug uuid="$pbd_uuid"
    xe_must sr-scan uuid="$sr_uuid"
  else
    xe_must sr-scan uuid="$iso_sr"
  fi
}

lookup_iso_vdi_by_name() {
  local iso_name="$1"
  local iso_sr_uuid
  iso_sr_uuid=$(xe sr-list name-label="${ISO_SR_NAME}" type=iso --minimal)
  if [[ -z "$iso_sr_uuid" ]]; then
    echo ""
    return 0
  fi
  xe vdi-list sr-uuid="$iso_sr_uuid" name-label="$iso_name" --minimal
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
  local res
  res=$(xe network-list name-label="$name" --minimal)
  # Disallow multiple or empty
  if [[ -z "$res" ]]; then
    echo ""
  elif [[ "$res" == *,* ]]; then
    echo ""
  else
    echo "$res"
  fi
}

create_seed_iso_from_mc() {
  local vmname="$1"
  local ip="$2"
  local role="$3"
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

  local ip_cidr="${ip}/${CIDR_PREFIX}"
  
  # Создаем полный machineconfig с правильной секцией network
  cat "$template_file" > "${src_dir}/user-data"
  
  # Добавляем секцию network (если её еще нет в шаблоне)
  cat >> "${src_dir}/user-data" <<EOF
machine:
  network:
    hostname: ${vmname}
    interfaces:
      - interface: eth0
        dhcp: false
        addresses:
          - ${ip_cidr}
        routes:
          - network: 0.0.0.0/0
            gateway: ${GATEWAY}
    nameservers:
      - ${DNS_SERVER}
cluster:
  network: {}
EOF

  # meta-data
  cat > "${src_dir}/meta-data" <<EOF
instance-id: ${vmname}
local-hostname: ${vmname}
EOF

  # Check and install genisoimage if needed
  if ! command -v genisoimage >/dev/null 2>&1; then
    yum install -y genisoimage >/dev/null
  fi

  # Сборка ISO
  genisoimage -quiet -volid cidata -joliet -rock -o "$out_iso" -graft-points "user-data=${src_dir}/user-data" "meta-data=${src_dir}/meta-data"

  echo "$out_iso"
}

attach_iso() {
  local vm_uuid="$1"
  local iso_path="$2"
  echo "VM: $vm_uuid"
  if [[ -z "$vm_uuid" ]]; then
    echo "attach_iso: VM uuid is empty"
    exit 1
  fi
  if [[ ! -f "$iso_path" ]]; then
    echo "attach_iso: ISO not found at $iso_path"
    exit 1
  fi
  local iso_name iso_vdi cd_vbd
  iso_name=$(basename "$iso_path")
  iso_vdi=$(lookup_iso_vdi_by_name "$iso_name")
  if [[ -z "$iso_vdi" ]]; then
    echo "ISO '$iso_name' not found in ISO SR index. Running SR scan..."
    ensure_iso_sr
    iso_vdi=$(lookup_iso_vdi_by_name "$iso_name")
    if [[ -z "$iso_vdi" ]]; then
      echo "Failed to locate ISO '$iso_name' in ISO SR at ${ISO_DIR}. Ensure the ISO SR location matches ISO_DIR."
      exit 1
    fi
  fi
  cd_vbd=$(xe vbd-list vm-uuid="$vm_uuid" type=CD --minimal)
  if [[ -z "$cd_vbd" ]]; then
    cd_vbd=$(xe vbd-create vm-uuid="$vm_uuid" type=CD device=3 bootable=true mode=RO empty=true)
  fi
  if [[ -z "$cd_vbd" ]]; then
    echo "attach_iso: failed to create/list CD VBD"
    exit 1
  fi
  xe_must vbd-param-set uuid="$cd_vbd" userdevice=3
  xe_must vbd-insert uuid="$cd_vbd" vdi-uuid="$iso_vdi"
}

attach_second_iso() {
  local vm_uuid="$1"
  local iso_path="$2"
  if [[ -z "$vm_uuid" ]]; then
    echo "attach_second_iso: VM uuid is empty"
    exit 1
  fi
  if [[ ! -f "$iso_path" ]]; then
    echo "attach_second_iso: seed ISO not found at $iso_path"
    exit 1
  fi
  local iso_name iso_vdi cd_vbd2 iso_sr_uuid
  iso_name=$(basename "$iso_path")
  iso_vdi=$(lookup_iso_vdi_by_name "$iso_name")
  if [[ -z "$iso_vdi" ]]; then
    iso_sr_uuid=$(xe sr-list name-label="${ISO_SR_NAME}" type=iso --minimal)
    if [[ -z "$iso_sr_uuid" ]]; then
      echo "ISO SR not found. Check ISO_SR_NAME='${ISO_SR_NAME}'"
      exit 1
    fi
    xe_must sr-scan uuid="$iso_sr_uuid"
    iso_vdi=$(lookup_iso_vdi_by_name "$iso_name")
    if [[ -z "$iso_vdi" ]]; then
      echo "Failed to import seed ISO '$iso_name' to ISO SR at ${ISO_DIR}"
      exit 1
    fi
  fi
  cd_vbd2=$(xe vbd-create vm-uuid="$vm_uuid" type=CD device=4 bootable=false mode=RO empty=true)
  if [[ -z "$cd_vbd2" ]]; then
    echo "attach_second_iso: failed to create CD VBD2"
    exit 1
  fi
  xe_must vbd-param-set uuid="$cd_vbd2" userdevice=4
  xe_must vbd-insert uuid="$cd_vbd2" vdi-uuid="$iso_vdi"
}

vm_exists_by_name() {
  local name="$1"
  local uuid
  uuid=$(xe vm-list name-label="$name" is-control-domain=false --minimal)
  [[ -n "$uuid" ]]
}

get_vm_uuid_by_name() {
  local name="$1"
  xe vm-list name-label="$name" is-control-domain=false --minimal
}

destroy_vm_by_uuid() {
  local uuid="$1"
  local power_state
  power_state=$(xe vm-param-get uuid="$uuid" param-name=power-state || true)
  if [[ "$power_state" == "running" ]]; then
    xe vm-shutdown uuid="$uuid" force=true >/dev/null 2>&1 || xe vm-reset-powerstate uuid="$uuid" >/dev/null 2>&1 || true
  fi
  # detach/destroy VBDs
  local vbds
  vbds=$(xe vbd-list vm-uuid="$uuid" --minimal || true)
  if [[ -n "$vbds" ]]; then
    IFS=, read -r -a vbd_arr <<< "$vbds"
    for vbd in "${vbd_arr[@]}"; do
      xe vbd-unplug uuid="$vbd" >/dev/null 2>&1 || true
      xe_must vbd-destroy uuid="$vbd"
    done
  fi
  # destroy VIFs
  local vifs
  vifs=$(xe vif-list vm-uuid="$uuid" --minimal || true)
  if [[ -n "$vifs" ]]; then
    IFS=, read -r -a vif_arr <<< "$vifs"
    for vif in "${vif_arr[@]}"; do
      xe_must vif-destroy uuid="$vif"
    done
  fi
  # collect VDIs via VBDs (before uninstall)
  local vdi_list
  vdi_list=$(xe vbd-list vm-uuid="$uuid" params=vdi-uuid --minimal 2>/dev/null || true)

  xe_must vm-uninstall uuid="$uuid" force=true

  if [[ -n "$vdi_list" ]]; then
    IFS=, read -r -a vdi_arr <<< "$vdi_list"
    for vdi in "${vdi_arr[@]}"; do
      [[ -n "$vdi" ]] && xe_must vdi-destroy uuid="$vdi"
    done
  fi
}

reconcile_group() {
  # $1 base name prefix, $2 desired count, $3 net_uuid, $4 sr_uuid, $5 kargs, $6 role(cp|wk), $7 vcpu, $8 ramGiB, $9 diskGiB
  local base="$1"
  local desired="$2"
  local net_uuid="$3"
  local sr_uuid="$4"
  local kargs="$5"
  local role="$6"
  local vcpu="$7"
  local ram="$8"
  local disk="$9"

  # Создадим недостающие 1..desired
  for i in $(seq 1 "$desired"); do
    local name="${base}${i}"
    if vm_exists_by_name "$name"; then
      echo "VM exists: $name"
      continue
    fi

    # Определяем IP из соответствующего массива
    local ip=""
    if [[ "$role" == "cp" ]]; then
      ip="${CP_IPS[$((i-1))]}"
    else
      ip="${WK_IPS[$((i-1))]}"
    fi
    if [[ -z "$ip" ]]; then
      echo "No IP configured for $name, skip."
      continue
    fi

    local vm_uuid
    vm_uuid=$(create_vm "$name" "$vcpu" "$ram" "$disk" "$net_uuid" "$sr_uuid" "$kargs")
    echo "VM UUID: $vm_uuid"
    attach_iso "$vm_uuid" "$ISO_LOCAL_PATH"
    echo "Disk source attached"
    local seed_iso
    seed_iso=$(create_seed_iso_from_mc "$name" "$ip" "$role")
    echo "Seed ISO: $seed_iso"
    attach_second_iso "$vm_uuid" "$seed_iso"
    echo "Created VM: $name ($ip) uuid=$vm_uuid"
  done

  # Если нужно — удалим лишние (индексы > desired)
  if [[ "${RECONCILE}" == "true" ]]; then
    # Найдем все ВМ по префиксу base
    local names
    names=$(xe vm-list is-control-domain=false params=name-label --minimal | tr , '\n' | grep -E "^${base}[0-9]+$" || true)
    if [[ -n "$names" ]]; then
      while IFS= read -r existing; do
        [[ -z "$existing" ]] && continue
        local idx
        idx=$(echo "$existing" | sed -E "s/^${base}([0-9]+)$/\1/")
        if [[ "$idx" -gt "$desired" ]]; then
          local uuid
          uuid=$(get_vm_uuid_by_name "$existing")
          echo "Removing extra VM: $existing uuid=$uuid"
          destroy_vm_by_uuid "$uuid"
        fi
      done <<< "$names"
    fi
  fi
}

create_vm() {
  local name="$1"
  local vcpu="$2"
  local ram_gib="$3"
  local disk_gib="$4"
  local net_uuid="$5"
  local sr_uuid="$6"

  local template_uuid vm_uuid vdi_uuid vbd_uuid vif_uuid

  # Use HVM template instead
  template_uuid=$(xe template-list name-label="Other install media" --minimal)
  if [[ -z "$template_uuid" ]]; then
    echo "Template 'Other install media' not found. Run 'xe template-list' and adjust the name."
    exit 1
  fi
  if [[ -z "$net_uuid" ]]; then
    echo "Network UUID is empty. Check NETWORK_NAME."
    exit 1
  fi
  if [[ -z "$sr_uuid" ]]; then
    echo "SR UUID is empty. Check SR_NAME or default SR."
    exit 1
  fi
  vm_uuid=$(xe vm-clone new-name-label="$name" uuid="$template_uuid")
  xe_must vm-param-set uuid="$vm_uuid" is-a-template=false
  xe_must vm-param-set uuid="$vm_uuid" name-description="Talos Linux node"

  # Set HVM mode
  xe_must vm-param-set uuid="$vm_uuid" HVM-boot-policy="BIOS order"
  xe_must vm-param-set uuid="$vm_uuid" HVM-boot-params:order="dc"
  
  # Remove PV bootloader settings
  xe_must vm-param-remove uuid="$vm_uuid" param-name=PV-bootloader 2>/dev/null || true
  xe_must vm-param-remove uuid="$vm_uuid" param-name=PV-args 2>/dev/null || true

  # Platform flags for HVM mode
  xe_must vm-param-set uuid="$vm_uuid" platform:acpi=1
  xe_must vm-param-set uuid="$vm_uuid" platform:apic=true
  xe_must vm-param-set uuid="$vm_uuid" platform:pae=true
  xe_must vm-param-set uuid="$vm_uuid" platform:viridian=true
  xe_must vm-param-set uuid="$vm_uuid" platform:nx=true
  xe_must vm-param-set uuid="$vm_uuid" platform:device-model=qemu-upstream-compat

  # Set memory with proper static and dynamic values
  local bytes=$((ram_gib*1024*1024*1024))
  xe_must vm-memory-set uuid="$vm_uuid" memory="$bytes"

  # Set shadow multiplier for HVM domain
  xe_must vm-param-set uuid="$vm_uuid" HVM-shadow-multiplier=1.0

  # vCPU
  xe_must vm-param-set uuid="$vm_uuid" VCPUs-max="$vcpu" VCPUs-at-startup="$vcpu"

  # vNIC
  vif_uuid=$(xe vif-create vm-uuid="$vm_uuid" network-uuid="$net_uuid" device=0)
  xe_must vif-param-set uuid="$vif_uuid" other-config:ethtool-gso="off"

  # Disk
  vdi_uuid=$(xe vdi-create name-label="${name}-disk" sr-uuid="$sr_uuid" type=user virtual-size=$((disk_gib*1024*1024*1024)))
  vbd_uuid=$(xe vbd-create vm-uuid="$vm_uuid" vdi-uuid="$vdi_uuid" device=0 bootable=true type=Disk mode=RW)
  xe_must vbd-param-set uuid="$vbd_uuid" userdevice=0

  echo "$vm_uuid"
}

main() {
  echo "Preparing..."
  local net_uuid sr_uuid default_sr
  net_uuid=$(find_network_uuid "$NETWORK_NAME")
  if [[ -z "$net_uuid" ]]; then
    echo "Network '$NETWORK_NAME' not found or ambiguous. Use a unique name-label."
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
    if [[ -z "$sr_uuid" || "$sr_uuid" == *,* ]]; then
      echo "SR '$SR_NAME' not found or ambiguous."
      exit 1
    fi
  fi

  import_iso_if_needed

  # Reconcile Control-plane
  reconcile_group "$VM_BASE_NAME_CP" "$CP_COUNT" "$net_uuid" "$sr_uuid" "$KERNEL_ARGS" "cp" 2 4 20

  # Reconcile Workers
  reconcile_group "$VM_BASE_NAME_WK" "$WK_COUNT" "$net_uuid" "$sr_uuid" "$KERNEL_ARGS" "wk" 4 16 100

  echo "Done. Start/stop as needed, e.g.: xe vm-start name-label=${VM_BASE_NAME_CP}1"
}

main "$@"