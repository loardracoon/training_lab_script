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
# Polling interval (seconds)
POLL_INTERVAL=10
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
MANUAL_DEV=""
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
            MANUAL_DEV="$1"
            shift
            ;;
    esac
done

# Function to scan a device
scan_device() {
    local DEV="$1"
    if [ ! -b "$DEV" ]; then
        log "Erro: Dispositivo $DEV não existe ou não é um dispositivo de bloco."
        return 1
    fi

    log "Detectado dispositivo USB: $DEV"

    # Get device serial for caching (unique identifier)
    SERIAL=$(lsblk -no SERIAL "$DEV" 2>/dev/null | grep -v '^$')
    if [ -z "$SERIAL" ]; then
        log "Aviso: Serial não encontrado para $DEV. Cache desativado para este dispositivo."
        NO_CACHE=1
    fi

    # Check cache if not disabled
    if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
        if grep -q "^$SERIAL$" "$CACHE_FILE"; then
            log "Dispositivo $DEV (serial: $SERIAL) já foi escaneado anteriormente. Ignorando scan."
            return 0
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
        log "Ponto de montagem encontrado: $MOUNT_POINT. Iniciando scan."
        if "$AVSCANNER" "$MOUNT_POINT" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1; then
            if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
                echo "$SERIAL" >> "$CACHE_FILE"
                log "Scan concluído com sucesso. Adicionado $SERIAL ao cache."
            else
                log "Scan concluído com sucesso (sem cache)."
            fi
        else
            log "Erro durante scan de $MOUNT_POINT (código $?). Não adicionado ao cache."
        fi
    else
        log "Erro: Ponto de montagem não encontrado para $DEV após $MAX_WAIT segundos. Ignorando scan."
        # Optional: Manual mount for servers (uncomment if needed)
        # if [ ! -d "$TEMP_MOUNT" ]; then mkdir -p "$TEMP_MOUNT"; fi
        # if mount "$DEV" "$TEMP_MOUNT" 2>> "$LOG_FILE"; then
        #     MOUNT_POINT="$TEMP_MOUNT"
        #     log "Montado manualmente $DEV em $MOUNT_POINT. Iniciando scan."
        #     if "$AVSCANNER" "$MOUNT_POINT" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1; then
        #         if [ "$NO_CACHE" = 0 ] && [ -n "$SERIAL" ]; then
        #             echo "$SERIAL" >> "$CACHE_FILE"
        #             log "Scan concluído com sucesso. Adicionado $SERIAL ao cache."
        #         else
        #             log "Scan concluído com sucesso (sem cache)."
        #         fi
        #     else
        #         log "Erro durante scan de $MOUNT_POINT (código $?). Não adicionado ao cache."
        #     fi
        #     umount "$TEMP_MOUNT" || log "Erro ao desmontar $TEMP_MOUNT."
        # else
        #     log "Erro: Não foi possível montar $DEV após $MAX_WAIT segundos. Ignorando scan."
        # fi
    fi
}

# If a manual device is provided, scan it and exit
if [ -n "$MANUAL_DEV" ]; then
    scan_device "$MANUAL_DEV"
    exit $?
fi

# Main loop for background monitoring
log "Iniciando monitoramento de dispositivos USB (intervalo: ${POLL_INTERVAL}s)"
while true; do
    # List USB block devices (partitions, e.g., /dev/sda1)
    mapfile -t devices < <(lsblk -dpno NAME,TRAN | grep ' usb$' | grep -E '[0-9]$' | cut -d' ' -f1)
    
    for dev in "${devices[@]}"; do
        scan_device "$dev"
    done

    sleep "$POLL_INTERVAL"
done
