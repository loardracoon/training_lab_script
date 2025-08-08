#!/usr/bin/env bash
# USB Monitor & Sophos Scanner for Linux (Ubuntu/Debian)
# Optimized version using udisks2 monitor
# Author: Adapted from Windows PowerShell logic
# Date: 2025-08-08

LOG_FILE="/var/log/usb-monitor.log"
CACHE_FILE="/var/lib/usb-monitor-cache.json"
SOPHOS_SCANNER="/opt/sophos-spl/plugins/av/bin/avscanner"
MAX_CACHE=10
CACHE_TTL=86400  # 24 hours

DEBUG=false
USE_CACHE=true

# Parse arguments
for arg in "$@"; do
    case $arg in
        --debug) DEBUG=true ;;
        --no-cache) USE_CACHE=false ;;
    esac
done

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    if $DEBUG; then
        echo "$msg"
    fi
}

load_cache() {
    if [[ -f "$CACHE_FILE" ]]; then
        CACHE_CONTENT=$(cat "$CACHE_FILE")
    else
        CACHE_CONTENT="[]"
    fi
}

save_cache() {
    echo "$CACHE_CONTENT" > "$CACHE_FILE"
}

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

add_to_cache() {
    local serial="$1"
    local now=$(date +%s)
    CACHE_CONTENT=$(echo "$CACHE_CONTENT" | jq --arg s "$serial" --argjson t "$now" \
        '[{"serial":$s,"time":$t}] + . | sort_by(.time) | reverse | .[0:'"$MAX_CACHE"']')
    save_cache
}

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

log "Service started."
load_cache

# Ensure jq and udisks2 are installed
if ! command -v jq &>/dev/null || ! command -v udisksctl &>/dev/null; then
    log "ERROR: jq and udisks2 are required. Install with: sudo apt install jq udisks2"
    exit 1
fi

# Monitor only "mounted" events
udisksctl monitor | while read -r line; do
    if echo "$line" | grep -q "Mounted"; then
        dev=$(echo "$line" | awk '{print $2}' | tr -d ':')
        mount_point=$(lsblk -no MOUNTPOINT "$dev" | grep -v '^$' | head -n 1)
        if [[ -n "$mount_point" ]]; then
            serial=$(udevadm info --query=all --name="$dev" | grep "ID_SERIAL=" | cut -d= -f2)
            [[ -z "$serial" ]] && serial="$dev"

            if is_in_cache "$serial"; then
                log "Bypassing scan for $serial (recently scanned)"
            else
                if scan_usb "$mount_point"; then
                    add_to_cache "$serial"
                fi
            fi
        else
            log "WARNING: Device $dev mounted but no mount point found"
        fi
    fi
done

log "Service stopped."
