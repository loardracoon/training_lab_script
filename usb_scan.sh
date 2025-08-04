#!/bin/bash

# Path to Sophos avscanner binary (per docs)
AVSCANNER="/opt/sophos-spl/plugins/av/bin/avscanner"
# Default scan options (adjust as needed, e.g., add --follow-symlinks)
SCAN_OPTIONS="--scan-archives"
# Log file
LOG_FILE="/var/log/usb_scan.log"
# Cache file for seen device serials (persistent across runs)
CACHE_FILE="/var/cache/usb_scan_seen.txt"
# Max wait time for auto-mount (seconds)
MAX_WAIT=30
# Temporary mount point for servers without auto-mount (optional)
TEMP_MOUNT="/mnt/usb_temp"

# Create cache file if it doesn't exist
if [ ! -f "$CACHE_FILE" ]; then
    touch "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
fi

# Function to log messages (to file, and console if debug)
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    if [ "$DEBUG" = 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    fi
}

# Parse arguments
DEBUG=0
NO_CACHE=0
DEV=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG=1
            shift
            ;;
        --no-cache)
            NO_CACHE=1
            shift
            ;;
        *)
            DEV="$1"
            shift
            ;;
    esac
done

# If no device provided, exit with error
if [ -z "$DEV" ]; then
    log "Error: No device provided (e.g., /dev/sda1). Usage: $0 [--debug] [--no-cache] /dev/sdX"
    exit 1
fi

# Check if device exists
if [ ! -b "$DEV" ]; then
    log "Error: Device $DEV does not exist or is not a block device."
    exit 1
fi

log "Detected USB partition: $DEV"

# Get device serial for caching (unique identifier)
SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | grep -v '^$')

if [ -z "$SERIAL" ]; then
    log "Warning: No serial found for $DEV. Caching disabled for this device."
    NO_CACHE=1
fi

# Check cache if not disabled
if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
    if grep -q "^$SERIAL$" "$CACHE_FILE"; then
        log "Device $DEV (serial: $SERIAL) already scanned previously. Skipping scan."
        exit 0
    fi
fi

# Wait for auto-mount and get mount point
MOUNT_POINT=""
for ((i=0; i<MAX_WAIT; i+=5)); do
    MOUNT_POINT=$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | grep -v '^$')
    if [ -n "$MOUNT_POINT" ]; then
        break
    fi
    sleep 5
done

if [ -n "$MOUNT_POINT" ]; then
    log "Mount point found: $MOUNT_POINT. Starting scan."
    if "$AVSCANNER" "$MOUNT_POINT" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1; then
        # On success, add to cache if caching enabled
        if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
            echo "$SERIAL" >> "$CACHE_FILE"
            log "Scan completed successfully. Added $SERIAL to cache."
        else
            log "Scan completed successfully (no cache used)."
        fi
    else
        log "Error during scan of $MOUNT_POINT (code $?). Not caching."
    fi
else
    # Optional: For server environments without auto-mount, attempt manual mount
    # Uncomment the block below if needed for headless servers
    # if [ ! -d "$TEMP_MOUNT" ]; then mkdir -p "$TEMP_MOUNT"; fi
    # if mount "$DEV" "$TEMP_MOUNT" 2>> "$LOG_FILE"; then
    #     MOUNT_POINT="$TEMP_MOUNT"
    #     log "Manually mounted $DEV to $MOUNT_POINT. Starting scan."
    #     if "$AVSCANNER" "$MOUNT_POINT" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1; then
    #         if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
    #             echo "$SERIAL" >> "$CACHE_FILE"
    #             log "Scan completed successfully. Added $SERIAL to cache."
    #         else
    #             log "Scan completed successfully (no cache used)."
    #         fi
    #     else
    #         log "Error during scan of $MOUNT_POINT (code $?). Not caching."
    #     fi
    #     umount "$TEMP_MOUNT" || log "Error unmounting $TEMP_MOUNT."
    # else
    #     log "Error: Could not find or mount $DEV after $MAX_WAIT seconds. Skipping scan."
    # fi
    log "Error: No mount point found for $DEV after $MAX_WAIT seconds. Skipping scan."
fi
