#!/bin/bash

LOG_FILE="/var/log/usb_scan.log"
AVSCANNER="/opt/sophos-spl/plugins/av/bin/avscanner"  # Caminho completo conforme docs Sophos; ajuste se necessário
SCAN_OPTIONS="--scan-archives"  # Opções extras; adicione mais conforme docs (ex: --follow-symlinks)

# Função para logar mensagens
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Array para dispositivos já vistos (reinicia ao restart do serviço)
seen_devices=()

while true; do
    # Lista dispositivos USB (ex: /dev/sda, /dev/sdb)
    current_devices=$(lsblk -dpno NAME,TRAN | grep ' usb$' | cut -d' ' -f1)

    for dev in $current_devices; do
        dev_name=$(basename "$dev")  # ex: sda
        if ! [[ " ${seen_devices[@]} " =~ " ${dev_name} " ]]; then
            log "Novo pen drive detectado: $dev"
            seen_devices+=("$dev_name")

            # Aguarda montagem automática (até 30s)
            mount_point=""
            for i in {1..6}; do  # 6 tentativas x 5s = 30s
                mount_point=$(lsblk -lnpo MOUNTPOINT "$dev" | grep -v '^$' | head -n1)
                if [ -n "$mount_point" ]; then
                    break
                fi
                sleep 5
            done

            if [ -n "$mount_point" ]; then
                log "Iniciando scan em $mount_point"
                # Executa o scan com tratamento de erro
                "$AVSCANNER" "$mount_point" $SCAN_OPTIONS >> "$LOG_FILE" 2>&1 || log "Erro ao escanear $mount_point (continuando...)"
            else
                log "Erro: Ponto de montagem não encontrado para $dev após aguardar (continuando...)"
            fi
        fi
    done

    sleep 10  # Intervalo de monitoramento
done
