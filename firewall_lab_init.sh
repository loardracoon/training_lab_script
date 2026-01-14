#!/bin/bash
set -euo pipefail

# ========== Configuration ==========
# Global definition of infrastructure
ALL_NODES=("minipc1" "minipc2" "minipc3")
ALL_TEMPLATE_IDS=(9001 9002 9003)

# Image Configuration
# Updated path and URL as requested
IMAGE_PATH="/home/images/firewall/21_5"
IMAGE_URL="https://storage.googleapis.com/lab-images-bucket-se-latam-enablement-dev/firewall/21_5/firewall.zip"

# Operational variables
TARGET_NODES=("${ALL_NODES[@]}")
SNAPSHOT_NAME="base-clean"
STDNT_MIN=3
STDNT_MAX=21

# Single node mode flag
SINGLE_NODE_MODE=0
TARGET_NODE_INDEX=-1

# ========== Argument Parsing (Optional Node Filter) ==========
if [[ $# -gt 0 ]]; then
  case "$1" in
    minipc1|minipc2|minipc3)
      for i in "${!ALL_NODES[@]}"; do
        if [[ "${ALL_NODES[$i]}" == "$1" ]]; then
          TARGET_NODE_INDEX=$i
          break
        fi
      done
      TARGET_NODES=("$1")
      SINGLE_NODE_MODE=1
      ;;
    *)
      echo "[ERROR] Invalid node name. Use: minipc1, minipc2, or minipc3."
      exit 1
      ;;
  esac
fi

# ========== Utils ==========
log()   { echo -e "[INFO] $*"; }
warn()  { echo -e "[WARN] $*"; }
error() { echo -e "[ERROR] $*" >&2; exit 1; }

confirm() {
  local msg="$1"
  read -p "$msg (y/N): " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ========== Availability Check ==========
check_node_availability() {
  log "Checking connectivity to nodes..."
  local available_nodes=()
  local offline_nodes=()

  for node in "${TARGET_NODES[@]}"; do
    # Check SSH connectivity with a timeout of 3 seconds
    if ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@"$node" "true" &>/dev/null; then
      available_nodes+=("$node")
    else
      offline_nodes+=("$node")
    fi
  done

  if [[ ${#offline_nodes[@]} -gt 0 ]]; then
    warn "The following nodes are UNREACHABLE/OFFLINE: ${offline_nodes[*]}"
    
    if [[ ${#available_nodes[@]} -eq 0 ]]; then
      error "No nodes are available to proceed. Exiting."
    fi

    if confirm "Do you want to proceed ONLY with the available nodes (${available_nodes[*]})?"; then
      TARGET_NODES=("${available_nodes[@]}")
    else
      error "Operation aborted by user due to offline nodes."
    fi
  else
    log "All target nodes are online."
  fi
}

# ========== Step 1: Download firewall image ==========
download_firewall_image() {
  confirm "Do you want to download the firewall image (v21.5)?" || return
  
  log "Starting parallel download on active nodes..."
  log "Target Path: $IMAGE_PATH"
  log "Source URL: $IMAGE_URL"

  for node in "${TARGET_NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -euo pipefail

      echo "[$node] Installing required packages (zip/unzip)..."
      # Using standard logic to detect package manager, prioritizing apt as per request
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq zip unzip
      elif command -v yum >/dev/null 2>&1; then
        yum install -y -q zip unzip
      else
        echo "[$node] Error: Package manager not supported." >&2
        exit 1
      fi

      echo "[$node] Creating directory $IMAGE_PATH..."
      mkdir -p "$IMAGE_PATH"
      cd "$IMAGE_PATH"

      # Cleanup previous files if any
      rm -f firewall.zip

      echo "[$node] Downloading image..."
      if ! wget -q --show-progress -O firewall.zip "$IMAGE_URL"; then
        echo "[$node] Error downloading file." >&2
        exit 1
      fi

      if [[ ! -s firewall.zip ]]; then
        echo "[$node] Error: Downloaded file is empty." >&2
        exit 1
      fi

      echo "[$node] Extracting..."
      # Using -o to overwrite without prompting
      if ! unzip -o firewall.zip; then
        echo "[$node] Error extracting the zip file." >&2
        exit 1
      fi

      echo "[$node] Cleaning up zip file..."
      rm -f firewall.zip
      echo "[$node] Download and extraction complete."
EOF
  done

  wait
  log "Step 1 completed on all active nodes."
}

# ========== Step 2: SDN Setup ==========
setup_sdn() {
  confirm "Do you want to configure the SDN?" || return
  
  for node in "${TARGET_NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -e
      bridge=\$(bridge link | awk '/master/{print \$2}' | sort -u | head -n1)
      [[ -z "\$bridge" ]] && echo "[$node] Default bridge not detected." && exit 1

      echo "[$node] Creating SDN zone on bridge \$bridge..."
      pvesh create /cluster/sdn/zones --zone Private --type vlan --bridge "\$bridge" 2>/dev/null || true

      for i in {1..15}; do
        pvesh create /cluster/sdn/vnets \
          --vnet STDNT\$(printf "%02d" "\$i") \
          --alias student\$(printf "%02d" "\$i") \
          --zone Private --tag \$((1000+i)) --vlanaware 1 2>/dev/null || true
      done

      for i in 1 2; do
        pvesh create /cluster/sdn/vnets \
          --vnet WAN0\$i --alias wan0\$i \
          --zone Private --tag \$((2000+i)) --vlanaware 1 2>/dev/null || true
      done

      pvesh set /cluster/sdn
      echo "[$node] SDN successfully configured."
EOF
  done
  wait
  log "SDN configuration process finished."
}

# ========== Step 3: Create base templates ==========
create_base_templates() {
  confirm "Do you want to create base templates?" || return

  log "Creating base VMs in parallel on active nodes..."
  
  for node in "${TARGET_NODES[@]}"; do
    local tpl_id=""
    for i in "${!ALL_NODES[@]}"; do
      if [[ "${ALL_NODES[$i]}" == "$node" ]]; then
        tpl_id="${ALL_TEMPLATE_IDS[$i]}"
        break
      fi
    done

    if [[ -z "$tpl_id" ]]; then
      warn "Could not determine Template ID for node $node. Skipping."
      continue
    fi

    # Pass the IMAGE_PATH variable to the remote shell
    ssh root@"$node" bash -s <<EOF &
      set -e
      echo "[$node] Creating VM ID $tpl_id..."
      qm create $tpl_id --name STDNTFWBASE --memory 4096 --cores 2 --agent enabled=1 --ostype l26 --scsihw virtio-scsi-pci
      qm set $tpl_id --net1 virtio,bridge=STDNT01,firewall=0 \
                     --net2 virtio,bridge=WAN01,firewall=0 \
                     --net3 virtio,bridge=WAN02,firewall=0
      
      # Searching in the NEW path defined in configuration
      PRIMARY=\$(find "$IMAGE_PATH" -iname 'PRIMARY*.qcow2' | head -1)
      AUX=\$(find "$IMAGE_PATH" -iname 'AUXILIARY*.qcow2' | head -1)
      
      if [[ -f "\$PRIMARY" && -f "\$AUX" ]]; then
        echo "[$node] Importing disks from $IMAGE_PATH..."
        qm importdisk $tpl_id "\$PRIMARY" local-lvm --format qcow2
        qm importdisk $tpl_id "\$AUX" local-lvm --format qcow2
        qm set $tpl_id --scsi0 local-lvm:vm-${tpl_id}-disk-0 \
                       --scsi1 local-lvm:vm-${tpl_id}-disk-1 \
                       --boot order=scsi0
      else
         echo "[$node] Error: Images (PRIMARY/AUXILIARY) not found in $IMAGE_PATH." >&2; exit 1
      fi
EOF
  done
  wait
  log "Base VMs created."

  confirm "Do you want to convert the base VMs into templates?" || return

  for node in "${TARGET_NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -e
      vmid=\$(qm list | awk '/STDNTFWBASE/ {print \$1}')
      if [[ -n "\$vmid" ]]; then 
        qm template "\$vmid"
        echo "[$node] Template created for VM \$vmid."
      fi
EOF
  done
  wait
}

# ========== Step 4: Create student VMs ==========
create_students() {
  confirm "Do you want to create student VMs?" || return

  read -p "How many students? [$STDNT_MIN-$STDNT_MAX, default=15]: " count
  count=${count:-15}
  if ! ((count >= STDNT_MIN && count <= STDNT_MAX)); then
    error "Value out of allowed range."
  fi

  log "Creating $count VMs (Logic: Round-Robin)..."

  for ((i=0; i<count; i++)); do
    local global_idx=$((i % ${#ALL_NODES[@]}))
    local target_node="${ALL_NODES[$global_idx]}"
    local tpl="${ALL_TEMPLATE_IDS[$global_idx]}"
    
    local is_active=0
    for active_node in "${TARGET_NODES[@]}"; do
      [[ "$active_node" == "$target_node" ]] && is_active=1 && break
    done

    if [[ $SINGLE_NODE_MODE -eq 1 ]]; then
       if [[ "$target_node" != "${TARGET_NODES[0]}" ]]; then
         continue
       fi
    elif [[ $is_active -eq 0 ]]; then
       warn "Skipping Student $((i+1)) because designated node '$target_node' is offline/excluded."
       continue
    fi

    local vmid=$((1001 + i))
    local name=$(printf "STDNTFW%02d" $((i+1)))
    local net=$(printf "STDNT%02d" $((i+1)))

    log "Deploying $name (ID $vmid) on $target_node..."
    
    ssh root@"$target_node" bash -s <<EOF &
      set -e
      if qm status $vmid >/dev/null 2>&1; then
        echo "[$target_node] VM $vmid already exists, skipping."
      else
        qm clone "$tpl" "$vmid" --name "$name"
        qm set "$vmid" \
          --net0 virtio,bridge="$net",firewall=0 \
          --net1 virtio,bridge=WAN01,firewall=0 \
          --net2 virtio,bridge=WAN02,firewall=0 \
          --boot order=scsi0
      fi
EOF
  done
  wait
  log "Student VM creation cycle completed."
}

# ========== Step 5: Snapshots ==========
create_snapshots() {
  confirm "Do you want to take snapshots of the student VMs?" || return
  log "Creating snapshots ($SNAPSHOT_NAME) on active nodes..."

  for node in "${TARGET_NODES[@]}"; do
    ssh root@"$node" bash -s <<EOF &
      set -e
      for vmid in \$(qm list | awk '/STDNTFW[0-9]+/{print \$1}'); do
        echo "[$node] Snapshotting \$vmid..."
        qm snapshot "\$vmid" "$SNAPSHOT_NAME" --description "Clean state" 2>/dev/null || echo "[$node] Failed to snapshot \$vmid"
      done
EOF
  done
  wait
  log "Snapshots process completed."
}

# ========== Main Execution ==========
check_node_availability
download_firewall_image || true
setup_sdn || true
create_base_templates || true
create_students
create_snapshots

log "Script execution finished."
