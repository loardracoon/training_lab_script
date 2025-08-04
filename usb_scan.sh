#!/bin/bash

# Path to Sophos AV scanner binary (adjust if necessary)
AVSCANNER="/opt/sophos-spl/plugins/av/bin/avscanner"

# Scan options (can be extended, e.g., --follow-symlinks)
SCAN_OPTIONS="--scan-archives"

# Log file
LOG_FILE="/var/log/usb_scan.log"

# Cache file for previously scanned device serials
CACHE_FILE="/var/cache/usb_scan_seen.txt"

# Maximum wait time for auto-mount detection (in seconds)
MAX_WAIT=30

# Temporary mount point (used only for headless/manual environments)
TEMP_MOUNT="/mnt/usb_temp"

# Create cache file if it doesn't exist
if [ ! -f "$CACHE_FILE" ]; then
    touch "$CACHE_FILE"
    chmod 600 "$CACHE_FILE"
fi

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    if [ "$DEBUG" = 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
    fi
}

# Argument parsing
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

# Check if device is specified
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

# Get device serial number
SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | grep -v '^$')

if [ -z "$SERIAL" ]; then
    log "Warning: Could not retrieve serial for $DEV. Caching will be disabled."
    NO_CACHE=1
fi

# Skip scan if already scanned and caching is enabled
if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
    if grep -q "^$SERIAL$" "$CACHE_FILE"; then
        log "Device $DEV (serial: $SERIAL) was already scanned. Skipping."
        exit 0
    fi
fi

# Try to detect mount point (e.g., /media/$USER/...)
MOUNT_POINT=""
for ((i=0; i<MAX_WAIT; i+=5)); do
    MOUNT_CANDIDATES=$(lsblk -no MOUNTPOINT "$DEV" 2>/dev/null | grep '^/media/')
    if [ -n "$MOUNT_CANDIDATES" ]; then
        MOUNT_POINT="$MOUNT_CANDIDATES"
        break
    fi
    sleep 5
done

if [ -n "$MOUNT_POINT" ]; then
    log "Mount point found: $MOUNT_POINT. Starting scan."
    if "$AVSCANNER" "$MOUNT_POINT" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1; then
        if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
            echo "$SERIAL" >> "$CACHE_FILE"
            log "Scan completed successfully. Added $SERIAL to cache."
        else
            log "Scan completed successfully (caching not used)."
        fi
    else
        log "Error: Scan failed for $MOUNT_POINT (exit code $?)."
    fi
else
    log "Error: Mount point for $DEV not found after $MAX_WAIT seconds. Skipping scan."

    # Optional manual mount logic (for headless environments)
    # Uncomment below to try mounting manually
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
    #     log "Manual mount of $DEV failed. Skipping scan."
    # fi
fi
