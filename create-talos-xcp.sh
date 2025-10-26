#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CLUSTER_NAME="talos-xcp"
NETWORK_NAME="vnic"                         # name-label сети в XCP-ng (меняйте при необходимости)
SR_NAME=""                                  # оставить пустым чтобы выбрать default SR
ISO_URL="https://factory.talos.dev/image/af0f260ca05688ef5c94894566b3b3c73a35ad272f64a8c3e5b0e48e0a0cac6a/v1.11.3/nocloud-amd64.raw.xz"
ISO_LOCAL_PATH="/opt/iso/talos-amd64.iso"
ISO_SR_NAME="ISO SR"
CURL_BINARY=""
STATIC_CURL_PATH="/usr/local/bin/curl-static"
STATIC_CURL_URL="https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64"
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

setup_static_curl() {
  # Check if static curl already exists
  if [[ -x "$STATIC_CURL_PATH" ]]; then
    echo "Static curl already available at $STATIC_CURL_PATH"
    CURL_BINARY="$STATIC_CURL_PATH"
    return 0
  fi

  # Try system curl first (for downloading static curl)
  if command -v curl >/dev/null 2>&1; then
    echo "Downloading static curl..."
    curl -L -o "$STATIC_CURL_PATH" "$STATIC_CURL_URL" 2>/dev/null || {
      echo "Failed to download static curl with system curl"
      return 1
    }
  elif command -v wget >/dev/null 2>&1; then
    echo "Downloading static curl with wget..."
    wget --no-check-certificate -O "$STATIC_CURL_PATH" "$STATIC_CURL_URL" 2>/dev/null || {
      echo "Failed to download static curl with wget"
      return 1
    }
  else
    echo "Neither curl nor wget available to download static curl"
    return 1
  fi

  chmod +x "$STATIC_CURL_PATH"
  
  if [[ -x "$STATIC_CURL_PATH" ]]; then
    echo "Static curl installed successfully at $STATIC_CURL_PATH"
    CURL_BINARY="$STATIC_CURL_PATH"
    
    # Verify it works
    "$CURL_BINARY" --version >/dev/null 2>&1 || {
      echo "Static curl binary doesn't work properly"
      rm -f "$STATIC_CURL_PATH"
      return 1
    }
    return 0
  fi
  
  return 1
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
    echo "Downloading Talos ISO with static curl..."
    "$CURL_BINARY" --cacert /etc/ssl/certs/ca-bundle.crt -L -o "$ISO_LOCAL_PATH" "$ISO_URL" || {
      echo "Failed to download Talos ISO"
      exit 1
    }
  else
    echo "Talos ISO already exists at $ISO_LOCAL_PATH"
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
  local template_file config_file
  if [[ "$role" == "cp" ]]; then
    template_file="$CP_TEMPLATE"
    config_file="$(pwd)/config/controlplane.yaml"
  else
    template_file="$WK_TEMPLATE"
    config_file="$(pwd)/config/worker.yaml"
  fi

  if [[ ! -f "$template_file" ]]; then
    echo "Template not found: $template_file"
    exit 1
  fi

  if [[ ! -f "$config_file" ]]; then
    echo "Config not found: $config_file"
    exit 1
  fi

  local ip_cidr="${ip}/${CIDR_PREFIX}"
  
  # Создаем полный machineconfig с правильной секцией network
  yq '.cluster.id=load("'"$config_file"'").cluster.id' "$template_file" | \
  yq '.cluster.secret=load("'"$config_file"'").cluster.secret' | \
  yq '.machine.token=load("'"$config_file"'").machine.token' | \
  yq '.machine.network.hostname = "'"${vmname}"'"' | \
  yq '.machine.network.interfaces[0].routes[0].gateway = "'"${GATEWAY}"'"' | \
  yq '.machine.network.nameservers[0] = "'"${DNS_SERVER}"'"' | \
  yq '.machine.network.interfaces[0].addresses[0] = "'"$ip_cidr"'"' > "${src_dir}/user-data"

  # meta-data
  cat > "${src_dir}/meta-data" <<EOF
instance-id: ${vmname}
local-hostname: ${vmname}
EOF

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

  # Get SR from VM's existing disk
  local vm_sr vdi_uuid vbd_uuid iso_name
  local existing_vbd existing_vdi
  existing_vbd=$(xe vbd-list vm-uuid="$vm_uuid" type=Disk --minimal | cut -d',' -f1)
  if [[ -n "$existing_vbd" ]]; then
    existing_vdi=$(xe vbd-param-get uuid="$existing_vbd" param-name=vdi-uuid 2>/dev/null || true)
    if [[ -n "$existing_vdi" ]]; then
      vm_sr=$(xe vdi-param-get uuid="$existing_vdi" param-name=sr-uuid 2>/dev/null || true)
    fi
  fi

  # Fallback to default SR
  if [[ -z "$vm_sr" ]]; then
    if [[ -n "$SR_NAME" ]]; then
      vm_sr=$(xe sr-list name-label="$SR_NAME" --minimal)
    else
      vm_sr=$(get_default_sr)
    fi
  fi

  if [[ -z "$vm_sr" ]]; then
    echo "Error: Cannot determine SR for VM"
    exit 1
  fi

  iso_name=$(basename "$iso_path")
  echo "Using SR: $vm_sr"

  # Create VDI and import ISO content
  echo "Creating VDI for seed ISO (read-only disk)..."
  local iso_size
  iso_size=$(stat -c %s "$iso_path" 2>/dev/null || stat -f %z "$iso_path" 2>/dev/null)

  if [[ -z "$iso_size" ]] || [[ ! "$iso_size" =~ ^[0-9]+$ ]]; then
    echo "Error: Cannot determine seed ISO size"
    exit 1
  fi

  echo "Seed ISO size: $iso_size bytes"

  vdi_uuid=$(xe vdi-create sr-uuid="$vm_sr" name-label="$iso_name" type=user virtual-size="$iso_size" read-only=false)

  # Import ISO data into VDI
  echo "Importing seed ISO data into VDI..."
  xe vdi-import uuid="$vdi_uuid" filename="$iso_path" format=raw

  # Attach as disk device (not CD)
  vbd_uuid=$(xe vbd-create vm-uuid="$vm_uuid" vdi-uuid="$vdi_uuid" device=2 type=Disk mode=RO bootable=false)
  xe_must vbd-param-set uuid="$vbd_uuid" userdevice=2

  echo "Attached seed ISO as read-only disk: $iso_name"
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
  local role="$5"
  local vcpu="$6"
  local ram="$7"
  local disk="$8"

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
    vm_uuid=$(create_vm "$name" "$vcpu" "$ram" "$disk" "$net_uuid" "$sr_uuid")
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

check_and_install() {
  setup_static_curl || {
    echo "Warning: Could not setup static curl, falling back to system curl"
    if command -v curl >/dev/null 2>&1; then
      CURL_BINARY="curl"
    else
      echo "Error: No curl available"
      exit 1
    fi
  }

  if ! command -v talosctl >/dev/null 2>&1; then
    curl -sL https://talos.dev/install | sh
  fi

  if ! command -v genisoimage >/dev/null 2>&1; then
    yum install -y genisoimage >/dev/null
  fi

  if ! command -v yq >/dev/null 2>&1; then
    wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  fi
}

generate_config() {
    local config_dir
    config_dir="$(pwd)/config"
    mkdir -p "$config_dir"

    if [[ ! -f "$config_dir/controlplane.yaml" ]] || [[ ! -f "$config_dir/worker.yaml" ]]; then
        talosctl gen config "$CLUSTER_NAME" "https://${CP_IPS[0]}:6443" -o "$config_dir"
        echo "Generated new Talos config files in $config_dir"
    else
        echo "Config files already exist in $config_dir, skipping generation"
        echo "To regenerate, delete the directory or add --force flag to talosctl"
    fi
}

clean_seeds() {
  rm -rf "$(pwd)/seeds/${CLUSTER_NAME}*"
  rm -f "${ISO_DIR}/${CLUSTER_NAME}*"
}

main() {
  echo "Preparing..."

  while getopts ":n:h" opt; do
    case ${opt} in
      n )
        NETWORK_NAME="$OPTARG"
        ;;
      h )
        echo "Usage: $0 [-n NETWORK_NAME]"
        echo "  -n NETWORK_NAME  : Name of the XCP-ng network to use (default: vnic)"
        echo "  -h               : Display this help message"
        exit 0
        ;;
      \? )
        echo "Invalid option: -$OPTARG" >&2
        echo "Usage: $0 [-n NETWORK_NAME]"
        exit 1
        ;;
      : )
        echo "Option -$OPTARG requires an argument" >&2
        exit 1
        ;;
    esac
  done
  shift $((OPTIND -1))

  check_and_install
  clean_seeds
  generate_config

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
  reconcile_group "$VM_BASE_NAME_CP" "$CP_COUNT" "$net_uuid" "$sr_uuid" "cp" 2 4 20

  # Reconcile Workers
  reconcile_group "$VM_BASE_NAME_WK" "$WK_COUNT" "$net_uuid" "$sr_uuid" "wk" 4 16 100

  echo "Done. Start/stop as needed, e.g.: xe vm-start name-label=${VM_BASE_NAME_CP}1"
}

main "$@"
