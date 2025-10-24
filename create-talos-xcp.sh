#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CLUSTER_NAME="talos-xcp"
NETWORK_NAME="vnic"                         # name-label сети в XCP-ng (меняйте при необходимости)
SR_NAME=""                                  # оставить пустым чтобы выбрать default SR
ISO_URL="https://github.com/siderolabs/talos/releases/download/v1.11.3/metal-amd64.iso"
ISO_LOCAL_PATH="/opt/iso/talos-amd64.iso"
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
  # Refresh ISO SR so xe sees the file
  xe-mount-iso-sr() { :; } # placeholder to avoid set -e on subshells
  xe sr-scan uuid="$(xe sr-list name-label="${ISO_SR_NAME}" --minimal)" >/dev/null 2>&1 || true
  echo "Talos ISO ready at $ISO_LOCAL_PATH"
}

find_network_uuid() {
  local name="$1"
  xe network-list name-label="$name" --minimal
}

# Import seed ISO file into ISO SR and return its cd-name
import_seed_into_iso_sr() {
  local iso_path="$1"
  local iso_sr_uuid
  iso_sr_uuid=$(xe sr-list name-label="${ISO_SR_NAME}" --minimal)
  if [[ -z "$iso_sr_uuid" ]]; then
    echo "ISO SR '${ISO_SR_NAME}' not found"
    exit 1
  fi
  # File is already in $ISO_DIR; ensure SR is rescanned
  xe sr-scan uuid="$iso_sr_uuid" >/dev/null 2>&1 || true
  basename "$iso_path"
}

attach_iso() {
  local vm_uuid="$1"
  local iso_name="$2"   # cd-name visible in ISO SR
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
  local iso_name="$2"
  local existing
  existing=$(xe vbd-list vm-uuid="$vm_uuid" type=CD params=userdevice --minimal | tr , '\n' | grep -Fx "4" || true)
  if [[ -z "$existing" ]]; then
    local cd_vbd2
    cd_vbd2=$(xe vbd-create vm-uuid="$vm_uuid" type=CD device=4 bootable=false mode=RO empty=true)
    xe_must vbd-param-set uuid="$cd_vbd2" userdevice=4
  fi
  xe_must vm-cd-add vm="$vm_uuid" cd-name="$iso_name" device=4
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
    xe_must vm-shutdown uuid="$uuid"
  fi
  # Удаляем все VBD/VIF, затем саму ВМ и ее диски
  local vbds vifs
  vbds=$(xe vbd-list vm-uuid="$uuid" --minimal || true)
  if [[ -n "$vbds" ]]; then
    IFS=, read -r -a vbd_arr <<< "$vbds"
    for vbd in "${vbd_arr[@]}"; do
      # попытаться отсоединить, затем уничтожить
      xe vbd-unplug uuid="$vbd" >/dev/null 2>&1 || true
      xe_must vbd-destroy uuid="$vbd"
    done
  fi
  vifs=$(xe vif-list vm-uuid="$uuid" --minimal || true)
  if [[ -n "$vifs" ]]; then
    IFS=, read -r -a vif_arr <<< "$vifs"
    for vif in "${vif_arr[@]}"; do
      xe_must vif-destroy uuid="$vif"
    done
  fi

  # Сохраним список VDI до уничтожения ВМ, чтобы убрать и диски
  local vdis
  vdis=$(xe vdi-list name-label | grep "$uuid-does-not-match" >/dev/null 2>&1 || true) # placeholder to keep shell safe

  # Получим VDI связанные с ВМ через VBD до удаления (еще раз)
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

  if [[ -z "$net_uuid" || -z "$sr_uuid" ]]; then
    echo "Missing network or SR UUID"
    exit 1
  fi

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
    if [[ -z "$vm_uuid" ]]; then
      echo "Failed to create VM $name"
      exit 1
    fi
    # First ISO: Talos installer (file must exist in ISO SR)
    local talos_cd
    talos_cd=$(basename "$ISO_LOCAL_PATH")
    attach_iso "$vm_uuid" "$talos_cd"
    # Second ISO: per-VM seed; create file and rescan SR to expose it
    local seed_iso
    seed_iso=$(create_seed_iso_from_mc "$name" "$ip" "$role")
    xe sr-scan uuid="$(xe sr-list name-label="${ISO_SR_NAME}" --minimal)" >/dev/null 2>&1 || true
    local seed_cd
    seed_cd=$(import_seed_into_iso_sr "$seed_iso")
    attach_second_iso "$vm_uuid" "$seed_cd"
    echo "Created VM: $name ($ip) uuid=$vm_uuid"
  done

  # Если нужно — удалим лишние (индексы > desired)
  if [[ "${RECONCILE}" == "true" ]]; then
    # Найдем все ВМ по префиксу base
    local names
    names=$(xe vm-list is-control-domain=false params=name-label --minimal | tr , '\n' | grep -E "^${base}[0-9]+$" || true)
    if [[ -n "$names" ]]; then
      while IFS= read -r -a existing; do
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
  local vcpu="${2:-}"
  local ram_gib="${3:-}"
  local disk_gib="${4:-}"
  local net_uuid="${5:-}"
  local sr_uuid="${6:-}"
  local kernel_args="${7:-}"

  # Validate inputs to avoid shifted/empty args causing xe errors
  if [[ -z "$name" || -z "$vcpu" || -z "$ram_gib" || -z "$disk_gib" || -z "$net_uuid" || -z "$sr_uuid" ]]; then
    echo "create_vm: missing parameters (name=$name vcpu=$vcpu ram_gib=$ram_gib disk_gib=$disk_gib net=$net_uuid sr=$sr_uuid)"
    exit 1
  fi
  if ! [[ "$vcpu" =~ ^[0-9]+$ && "$ram_gib" =~ ^[0-9]+$ && "$disk_gib" =~ ^[0-9]+$ ]]; then
    echo "create_vm: CPU/RAM/DISK must be integers"
    exit 1
  fi

  echo "Creating VM $name"
  local template_uuid vm_uuid vdi_uuid vbduuid vif_uuid

  template_uuid=$(xe template-list name-label="Other install media" --minimal)
  if [[ -z "$template_uuid" ]]; then
    echo "Template 'Other install media' not found"
    exit 1
  fi
  vm_uuid=$(xe vm-clone new-name-label="$name" uuid="$template_uuid")
  if [[ -z "$vm_uuid" ]]; then
    echo "Failed to clone template for $name"
    exit 1
  fi
  xe_must vm-param-set uuid="$vm_uuid" is-a-template=false
  xe_must vm-param-set uuid="$vm_uuid" name-description="Talos Linux node"

  xe_must vm-param-set uuid="$vm_uuid" VCPUs-max="$vcpu" VCPUs-at-startup="$vcpu"

  # Use printf for 64-bit-safe arithmetic and quote values
  local bytes
  bytes=$(printf '%d' $((ram_gib * 1024 * 1024 * 1024)))
  xe_must vm-memory-set uuid="$vm_uuid" static-min="$bytes" dynamic-min="$bytes" dynamic-max="$bytes" static-max="$bytes"

  # vNIC
  vif_uuid=$(xe vif-create vm-uuid="$vm_uuid" network-uuid="$net_uuid" device=0)
  if [[ -z "$vif_uuid" ]]; then
    echo "Failed to create VIF for $name"
    exit 1
  fi
  xe_must vif-param-set uuid="$vif_uuid" other-config:ethtool-gso="off"

  # Disk
  vdi_uuid=$(xe vdi-create name-label="${name}-disk" sr-uuid="$sr_uuid" type=user virtual-size="$(printf '%d' $((disk_gib * 1024 * 1024 * 1024)))")
  if [[ -z "$vdi_uuid" ]]; then
    echo "Failed to create VDI for $name"
    exit 1
  fi
  vbduuid=$(xe vbd-create vm-uuid="$vm_uuid" vdi-uuid="$vdi_uuid" device=0 bootable=true type=Disk mode=RW)
  if [[ -z "$vbduuid" ]]; then
    echo "Failed to create VBD for $name"
    exit 1
  fi
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
  # Ensure ISO SR sees the Talos ISO and future seed ISOs
  xe sr-scan uuid="$(xe sr-list name-label="${ISO_SR_NAME}" --minimal)" >/dev/null 2>&1 || true

  # Reconcile Control-plane
  reconcile_group "$VM_BASE_NAME_CP" "$CP_COUNT" "$net_uuid" "$sr_uuid" "$KERNEL_ARGS" "cp" 2 4 20
  # Reconcile Workers
  reconcile_group "$VM_BASE_NAME_WK" "$WK_COUNT" "$net_uuid" "$sr_uuid" "$KERNEL_ARGS" "wk" 4 16 100

  echo "Done. Start/stop as needed, e.g.: xe vm-start name-label=${VM_BASE_NAME_CP}1"
}

main "$@"