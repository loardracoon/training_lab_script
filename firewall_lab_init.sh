#!/bin/bash
set -euo pipefail

# ========== Config ==========
NODES=( "minipc1" "minipc2" "minipc3" )
TEMPLATE_IDS=( 9001 9002 9003 )
SNAPSHOT_NAME="base-clean"
STDNT_MIN=3
STDNT_MAX=21

# ===== Filtro opcional por nó (preserva posição no round-robin global) =====
ALL_NODES=( "minipc1" "minipc2" "minipc3" )
ALL_TEMPLATE_IDS=( 9001 9002 9003 )
SINGLE_NODE_MODE=0
NODE_INDEX=0

if [[ $# -gt 0 ]]; then
  case "$1" in
    minipc1|minipc2|minipc3)
      # Descobre o índice do nó dentro do conjunto global
      for i in "${!ALL_NODES[@]}"; do
        if [[ "${ALL_NODES[$i]}" == "$1" ]]; then
          NODE_INDEX=$i
          break
        fi
      done
      # Mantém NODES com apenas o alvo, mas guardamos índice global para os passos
      NODES=("$1")
      SINGLE_NODE_MODE=1
      ;;
    *)
      echo "[ERROR] Invalid node name. Use: minipc1, minipc2 or minipc3."
      exit 1
      ;;
  esac
fi


# ========== Utils ==========
log()   { echo -e "[INFO] $*"; }
error() { echo -e "[ERROR] $*" >&2; exit 1; }

parallel_ssh() {
  local cmd=$1
  for node in "${NODES[@]}"; do
    ssh root@"$node" "$cmd" &
  done
  wait
}

confirm() {
  local msg="$1"
  read -p "$msg (y/N): " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ========== Step 1: Download firewall image ==========
download_firewall_image() {
  confirm "Do you want to download the firewall image?" || return
  read -p "Enter the URL of the image (.zip): " image_url
  [[ "$image_url" =~ \.zip$ ]] || error "URL must end with .zip"

  log "Starting parallel download of image on all nodes..."

  for node in "${NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -euo pipefail

      # Verificar se unzip estÃ¡ instalado
      if ! command -v unzip >/dev/null 2>&1; then
        echo "Installing unzip..."
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -qq && apt-get install -y -qq unzip
        elif command -v yum >/dev/null 2>&1; then
          yum install -y -q unzip
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y -q unzip
        else
          echo "Error: Package manager not supported. Install unzip manually." >&2
          exit 1
        fi
      fi

      mkdir -p /images/firewall && cd /images/firewall
      rm -f firewall.zip

      echo "Downloading image..."
      if ! wget -q --show-progress -O firewall.zip "$image_url"; then
        echo "Error downloading file." >&2
        exit 1
      fi

      # Verificar se o arquivo foi baixado e tem tamanho maior que 0
      if [[ ! -s firewall.zip ]]; then
        echo "Error: Downloaded file is empty or missing." >&2
        exit 1
      fi

      echo "Extracting..."
      if ! unzip -o firewall.zip -d /images/firewall; then
        echo "Error extracting the zip file." >&2
        exit 1
      fi

      rm -f firewall.zip
EOF
  done

  wait
  log "Download and extraction completed on all nodes."
}


# ========== Step 2: SDN Setup ==========
setup_sdn() {
  confirm "Do you want to configure the SDN?" || return
  local bridge
  bridge=$(bridge link | awk '/master/{print $2}' | sort -u | head -n1)
  [[ -z "$bridge" ]] && error "Default bridge not detected."

  log "Creating SDN zone on bridge $bridge..."
  pvesh create /cluster/sdn/zones --zone Private --type vlan --bridge "$bridge"

  for i in {1..15}; do
    pvesh create /cluster/sdn/vnets \
      --vnet STDNT$(printf "%02d" "$i") \
      --alias student$(printf "%02d" "$i") \
      --zone Private --tag $((1000+i)) --vlanaware 1
  done

  for i in 1 2; do
    pvesh create /cluster/sdn/vnets \
      --vnet WAN0$i --alias wan0$i \
      --zone Private --tag $((2000+i)) --vlanaware 1
  done

  pvesh set /cluster/sdn
  log "SDN successfully configured."
}

# ========== Step 3: Create base templates ==========
create_base_templates() {
  confirm "Do you want to create base templates?" || return

  log "Creating base VMs in parallel..."
  for idx in "${!NODES[@]}"; do
    local node=${NODES[idx]}
    local vmid=${TEMPLATE_IDS[idx]}
    ssh root@"$node" bash -s <<EOF &
      set -e
      qm create $vmid --name STDNTFWBASE --memory 4096 --cores 2 --agent enabled=1 --ostype l26
      qm set $vmid --net1 virtio,bridge=STDNT01,firewall=0 \
                   --net2 virtio,bridge=WAN01,firewall=0 \
                   --net3 virtio,bridge=WAN02,firewall=0
      PRIMARY=\$(find /images/firewall -iname 'PRIMARY*.qcow2' | head -1)
      AUX=\$(find /images/firewall -iname 'AUXILIARY*.qcow2' | head -1)
      [[ -f "\$PRIMARY" && -f "\$AUX" ]] || exit 1
      qm importdisk $vmid "\$PRIMARY" local-lvm --format qcow2
      qm importdisk $vmid "\$AUX" local-lvm --format qcow2
      qm set $vmid --scsihw virtio-scsi-pci \
                   --scsi0 local-lvm:vm-${vmid}-disk-0 \
                   --scsi1 local-lvm:vm-${vmid}-disk-1 \
                   --boot order=scsi0
EOF
  done
  wait
  log "Base VMs created."

  confirm "Do you want to convert the base VMs into templates?" || return

  for node in "${NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF
      set -e
      vmid=\$(qm list | awk '/STDNTFWBASE/ {print \$1}')
      [[ -n "\$vmid" ]] && qm template "\$vmid"
EOF
    log "$node: Template created."
  done
}

# ========== Step 4: Create student VMs ==========
create_students() {
  confirm "Do you want to create student VMs?" || return

  read -p "How many students? [$STDNT_MIN-$STDNT_MAX, default=15]: " count
  count=${count:-15}
  if ! ((count >= STDNT_MIN && count <= STDNT_MAX)); then
    error "Value out of allowed range."
  fi

  log "Creating $count VMs in round-robin..."

  if (( SINGLE_NODE_MODE == 1 )); then
    # Cria somente as VMs que pertenceriam a este nó no round-robin global:
    # Índices 1..count mapeados: 1->minipc1, 2->minipc2, 3->minipc3, 4->minipc1, ...
    # Portanto, para minipc2 (NODE_INDEX=1), criamos 2,5,8,... (i = NODE_INDEX, passo 3)
    target_node="${ALL_NODES[$NODE_INDEX]}"
    tpl="${ALL_TEMPLATE_IDS[$NODE_INDEX]}"

    for ((i=NODE_INDEX; i<count; i+=3)); do
      vmid=$((1000 + i + 1))
      name=$(printf "STDNTFW%02d" $((i+1)))
      net=$(printf "STDNT%02d" $((i+1)))

      ssh root@"$target_node" bash -s <<EOF &
set -e
qm clone "$tpl" "$vmid" --name "$name"
qm set "$vmid" \
  --net0 virtio,bridge="$net",firewall=0 \
  --net1 virtio,bridge=WAN01,firewall=0 \
  --net2 virtio,bridge=WAN02,firewall=0 \
  --boot order=scsi0
EOF
    done
    wait
  else
    # Comportamento original (todos os nós)
    for ((i=0; i<count; i++)); do
      local ni=$((i % ${#NODES[@]}))
      local node=${NODES[ni]}
      local tpl=${TEMPLATE_IDS[ni]}
      local vmid=$((1001 + i))
      local name=$(printf "STDNTFW%02d" $((i+1)))
      local net=$(printf "STDNT%02d" $((i+1)))

      ssh root@"$node" bash -s <<EOF &
set -e
qm clone "$tpl" "$vmid" --name "$name"
qm set "$vmid" \
  --net0 virtio,bridge="$net",firewall=0 \
  --net1 virtio,bridge=WAN01,firewall=0 \
  --net2 virtio,bridge=WAN02,firewall=0 \
  --boot order=scsi0
EOF
    done
    wait
  fi

  log "All student VMs have been created."
}

# ========== Step 5: Snapshots ==========
create_snapshots() {
  confirm "Do you want to take snapshots of the student VMs?" || return
  log "Creating snapshots ($SNAPSHOT_NAME)..."

  for node in "${NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -e
      for vmid in \$(qm list | awk '/STDNTFW[0-9]+/{print \$1}'); do
        qm snapshot "\$vmid" "$SNAPSHOT_NAME" --description "Clean state"
      done
EOF
  done
  wait
  log "Snapshots created successfully."
}

# ========== Main Execution ==========
download_firewall_image || true
setup_sdn || true
create_base_templates || true
create_students
create_snapshots

log "Script completed successfully."
