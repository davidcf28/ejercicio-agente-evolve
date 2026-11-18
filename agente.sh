#!/usr/bin/env bash
# agente.sh - recoge el estado de los recursos y lo envía por webhook al canal "monitor".
# Uso: ./agente.sh [-i segundos] [-u url_webhook]

export LC_ALL=C

INTERVALO=10
URL="${MONITOR_URL:-http://localhost:8080/webhook/monitor}"
LOG="agente.log"

while getopts "i:u:h" op; do
  case $op in
    i) INTERVALO=$OPTARG ;;
    u) URL=$OPTARG ;;
    *) echo "Uso: $0 [-i segundos] [-u url]"; exit 1 ;;
  esac
done

[[ $INTERVALO =~ ^[0-9]+$ ]] || {
  echo "-i debe ser un entero" >&2
  exit 1
}

log() {
  echo "$(date -u +%FT%TZ) $*" >> "$LOG"
}

# --- CPU ---
leer_cpu() {
  awk '/^cpu /{
    idle=$5+$6
    total=0
    for(i=2;i<=9;i++) total+=$i
    print idle, total
  }' /proc/stat
}

recoger() {

  # --- CPU: dos lecturas separadas 1 segundo ---
  read -r i1 t1 < <(leer_cpu)
  sleep 1
  read -r i2 t2 < <(leer_cpu)

  cpu=$(awk -v i1="$i1" -v t1="$t1" -v i2="$i2" -v t2="$t2" \
    'BEGIN{
      dt=t2-t1
      di=i2-i1
      printf "%.1f", (dt>0) ? 100*(dt-di)/dt : 0
    }')

  # --- Memoria (kB -> MB) ---
  read -r mt mu mp < <(
    awk '
      /^MemTotal/{t=$2}
      /^MemAvailable/{a=$2}
      END{
        printf "%d %d %.1f\n",
        t/1024,
        (t-a)/1024,
        (t>0)?100*(t-a)/t:0
      }' /proc/meminfo
  )

  # --- Disco ---
  disco=$(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null |
    awk 'NR>1{
      gsub("%","",$5)
      print $6, $5
    }' |
    jq -R -s -c '
      split("\n")
      | map(select(length>0)
      | split(" ")
      | {montaje:.[0], pct:(.[1]|tonumber)})
    ')

  # --- Carga y uptime ---
  read -r l1 l2 l3 _ < /proc/loadavg
  up=$(awk '{ print int($1) }' /proc/uptime)

  # --- Top 3 procesos por CPU ---
  # Se utilizan tabuladores para conservar nombres con espacios.
  top=$(ps -eo pid=,pcpu=,comm= --sort=-pcpu |
    awk 'NR<=3 {
      pid=$1
      cpu=$2
      $1=$2=""
      sub(/^ +/, "")
      printf "%s\t%s\t%s\n", pid, $0, cpu
    }' |
    jq -R -s -c '
      split("\n")
      | map(select(length>0)
      | split("\t")
      | {pid:(.[0]|tonumber), cmd:.[1], cpu:(.[2]|tonumber)})
    ')

  # --- Construcción del JSON ---
  jq -n -c \
    --arg host "$(hostname)" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cpu "$cpu" \
    --argjson mt "$mt" \
    --argjson mu "$mu" \
    --argjson mp "$mp" \
    --argjson disco "${disco:-[]}" \
    --argjson l1 "$l1" \
    --argjson l2 "$l2" \
    --argjson l3 "$l3" \
    --argjson up "$up" \
    --argjson top "${top:-[]}" \
    '{
      host:$host,
      ts:$ts,
      cpu_pct:$cpu,
      mem:{
        total_mb:$mt,
        usada_mb:$mu,
        pct:$mp
      },
      disco:$disco,
      carga:[$l1,$l2,$l3],
      uptime_s:$up,
      top_procesos:$top
    }'
}

# --- Control de interrupciones ---
trap 'log "agente detenido"; exit 0' INT TERM

log "agente iniciado (intervalo=${INTERVALO}s, url=$URL)"

# --- Bucle principal ---
while true; do

  inicio=$(date +%s)

  json=$(recoger)

  if [[ -z $json ]]; then
    log "ERROR: no se pudo construir el JSON"

  elif ! err=$(curl -sS -f -m 5 -X POST \
    -H 'Content-Type: application/json' \
    -d "$json" "$URL" 2>&1 >/dev/null); then

    log "ERROR de envío: $err"
  fi

  # Descontamos el tiempo que ha tardado la recogida.
  resto=$(( INTERVALO - ($(date +%s) - inicio) ))

  (( resto > 0 )) && sleep "$resto"

done
