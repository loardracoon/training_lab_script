#!/usr/bin/env bash

set -Eeuo pipefail



# === Parmetros padro (edite conforme o seu ambiente) ===

HOST="https://10.100.100.1"

API_KEY="${VYOS_API_KEY:-MY-HTTPS-API-PLAINTEXT-KEY}"   # export VYOS_API_KEY=... se preferir

INSECURE=1   # 1 = usa -k (cert self-signed); 0 = exige TLS vlido



LINK=""

PROFILE=""

DO_SAVE=0



usage() {

  cat >&2 <<USAGE

Uso: $0 --link <ethX> --profile <POLICY> [--save] [--host https://IP] [--key <APIKEY>] [--no-insecure]

Ex.: $0 --link eth1 --profile HIGHDELAY --save

USAGE

  exit 2

}



# Parse bsico

while [[ $# -gt 0 ]]; do

  case "$1" in

    --link)     LINK="${2:-}"; shift 2 ;;

    --profile)  PROFILE="${2:-}"; shift 2 ;;

    --save)     DO_SAVE=1; shift ;;

    --host)     HOST="${2:-}"; shift 2 ;;

    --key)      API_KEY="${2:-}"; shift 2 ;;

    --no-insecure) INSECURE=0; shift ;;

    *) echo "Arg invlido: $1" >&2; usage ;;

  esac

done

[[ -n "$LINK" && -n "$PROFILE" ]] || usage



# Validaes mnimas (reduz risco de injeo)

[[ "$LINK" =~ ^[A-Za-z0-9./_-]+$ ]]   || { echo "ERRO: --link invlido"; exit 2; }

[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERRO: --profile invlido"; exit 2; }



CURL_OPTS=(-sS --location)

[[ $INSECURE -eq 1 ]] && CURL_OPTS+=(-k)



# Monta payload como LISTA de operaes (delete + set em um nico commit)

PAYLOAD=$(cat <<JSON

[

  {"op":"delete","path":["qos","interface","$LINK","egress"]},

  {"op":"set","path":["qos","interface","$LINK","egress"],"value":"$PROFILE"}

]

JSON

)



# === 1) /configure: aplica mudanas (commit implcito) ===

resp=$(curl "${CURL_OPTS[@]}" --request POST "$HOST/configure" --form "data=$PAYLOAD" --form "key=$API_KEY")

ok=$(printf '%s' "$resp" | grep -o '"success": *true' || true)

if [[ -z "$ok" ]]; then

  echo "Falha no /configure. Resposta: $resp" >&2

  exit 1

fi



# === 2) /config-file: salva (opcional) ===

if [[ $DO_SAVE -eq 1 ]]; then

  resp2=$(curl "${CURL_OPTS[@]}" --request POST "$HOST/config-file" --form 'data={"op":"save"}' --form "key=$API_KEY")

  ok2=$(printf '%s' "$resp2" | grep -o '"success": *true' || true)

  if [[ -z "$ok2" ]]; then

    echo "Commit OK, mas save falhou. Resposta: $resp2" >&2

    exit 1

  fi

fi



echo "OK: QoS em $LINK => egress '$PROFILE' aplicado$( [[ $DO_SAVE -eq 1 ]] && echo ' e salvo' )."
