#!/usr/bin/env bash
# USB Monitor & Sophos Scanner for Linux (Ubuntu/Debian)
# Optimized version using udisks2 monitor
# Author: Adapted from Windows PowerShell logic
# Date: 2025-08-08

###
#
# This script monitors for USB devices being mounted and automatically scans them
# using Sophos avscanner. It's designed to run as a systemd service.
#
# ---
#
# Prerequisites
#
# Before running this script, ensure you have the following packages installed:
# - udisks2: For monitoring USB device events.
# - jq: A command-line JSON processor, used for managing the scan cache.
#
# To install them on Ubuntu/Debian:
# sudo apt update
# sudo apt install udisks2 jq
#
# ---
#
# How to Run
#
# For manual testing with debug logging, run the script with the --debug flag:
# sudo ./usb-monitor.sh --debug
#
# To test without using the scan cache:
# sudo ./usb-monitor.sh --no-cache
#
# ---
#
# How to Configure as a Systemd Service
#
# 1. Save this script to a directory like `/usr/local/bin/usb-monitor.sh`
#    and make it executable:
#    sudo chmod +x /usr/local/bin/usb-monitor.sh
#
# 2. Create a systemd service file at `/etc/systemd/system/usb-monitor.service`
#    with the following content:
#
#    [Unit]
#    Description=USB Mount and Scan Service
#    Wants=network-online.target
#
#    [Service]
#    Type=simple
#    ExecStart=/usr/local/bin/usb-monitor.sh
#    Restart=always
#    RestartSec=3
#    User=root
#
#    [Install]
#    WantedBy=multi-user.target
#
# 3. Enable and start the service:
#    sudo systemctl daemon-reload
#    sudo systemctl enable --now usb-monitor.service
#
# 4. Check the service status and logs:
#    sudo systemctl status usb-monitor.service
#    journalctl -u usb-monitor.service -f
#
###

# ----- CONFIGURATION VARIABLES -----
LOG_FILE="/var/log/usb-monitor.log"
CACHE_FILE="/var/lib/usb-monitor-cache.json"
SOPHOS_SCANNER="/opt/sophos-spl/plugins/av/bin/avscanner"
MAX_CACHE=10
CACHE_TTL=86400  # 24 hours

DEBUG=false
USE_CACHE=true

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --debug) DEBUG=true ;;
        --no-cache) USE_CACHE=false ;;
    esac
done

# ----- SCRIPT FUNCTIONS -----

# Function to log messages
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    if $DEBUG; then
        echo "$msg"
    fi
}

# Function to load the cache file
load_cache() {
    if [[ -f "$CACHE_FILE" ]]; then
        CACHE_CONTENT=$(cat "$CACHE_FILE")
    else
        CACHE_CONTENT="[]"
    fi
}

# Function to save the cache file
save_cache() {
    echo "$CACHE_CONTENT" > "$CACHE_FILE"
}

# Function to check if a device is in the cache
is_in_cache() {
    local serial="$1"
    if ! $USE_CACHE; then
        return 1
    fi
    local now=$(date +%s)
    local found_time=$(echo "$CACHE_CONTENT" | jq -r --arg s "$serial" '.[] | select(.serial==$s) | .time')
    if [[ -n "$found_time" ]]; then
        local age=$((now - found_time))
        if (( age < CACHE_TTL )); then
            return 0
        fi
    fi
    return 1
}

# Function to add a device to the cache
add_to_cache() {
    local serial="$1"
    local now=$(date +%s)
    CACHE_CONTENT=$(echo "$CACHE_CONTENT" | jq --arg s "$serial" --argjson t "$now" \
        '[{"serial":$s,"time":$t}] + . | sort_by(.time) | reverse | .[0:'"$MAX_CACHE"']')
    save_cache
}

# Function to scan the USB device
scan_usb() {
    local mount_point="$1"
    if [[ ! -x "$SOPHOS_SCANNER" ]]; then
        log "ERROR: Sophos scanner not found at $SOPHOS_SCANNER"
        return 1
    fi
    log "Starting scan on $mount_point..."
    if output=$("$SOPHOS_SCANNER" "$mount_point" 2>&1); then
        log "Scan successful for $mount_point"
        log "Output: $output"
        return 0
    else
        log "ERROR: Scan failed for $mount_point"
        log "Output: $output"
        return 1
    fi
}


# ----- MAIN SCRIPT LOGIC -----

log "Service started."
load_cache

# Ensure required dependencies are installed
if ! command -v jq &>/dev/null || ! command -v udisksctl &>/dev/null; then
    log "ERROR: jq and udisks2 are required. Install with: sudo apt install jq udisks2"
    exit 1
fi

log "DEBUG: Starting udisksctl monitor loop..."

device_path=""

# Monitor udisksd events
udisksctl monitor | while read -r line; do
    log "DEBUG: Received line from udisksctl: '$line'"

    # 1. Detect a block device event line, which contains the D-Bus path
    if [[ "$line" =~ "/org/freedesktop/UDisks2/block_devices/" ]]; then
        device_path=$(echo "$line" | grep -o '/org/freedesktop/UDisks2/block_devices/s[a-z][a-z0-9]*')
        log "DEBUG: Detected new block device event: $device_path"
        continue
    fi
    
    # 2. If a device path was found, check for the MountPoints line
    if [[ -n "$device_path" ]] && echo "$line" | grep -q "MountPoints:"; then
        mount_point=$(echo "$line" | awk -F': ' '{print $2}' | sed 's/^ *//;s/ *$//')
        
        # Ensure a valid mount point was found
        if [[ -n "$mount_point" ]]; then
            log "DEBUG: Mount point found: $mount_point"
            
            dev_name=$(basename "$device_path")
            serial=$(udevadm info --query=all --name="$dev_name" | grep "ID_SERIAL=" | cut -d= -f2)
            [[ -z "$serial" ]] && serial="$dev_name"
            log "DEBUG: Identified device name: $dev_name, serial: $serial"
            
            if is_in_cache "$serial"; then
                log "Bypassing scan for $serial (recently scanned)"
            else
                if scan_usb "$mount_point"; then
                    add_to_cache "$serial"
                fi
            fi
        else
            log "WARNING: Device $device_path has no valid mount point"
        fi
        
        # Reset the device path for the next event
        device_path=""
    fi
done

log "Service stopped."
