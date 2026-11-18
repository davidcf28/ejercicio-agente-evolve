#!/usr/bin/env bash
# panel.sh - lee el canal "monitor" y muestra el último informe de cada host.
# Fase 2 incluida: umbrales.json, mini-gráfica de CPU (20 informes) y alertas al cambiar de estado.
# Uso: ./panel.sh [-c url_canal] [-a url_alertas] [-u umbrales.json] [-r segundos]
export LC_ALL=C

CANAL_URL="${MONITOR_CANAL_URL:-http://localhost:8080/canal/monitor}"      # <-- ajusta a la URL real
ALERTAS_URL="${MONITOR_ALERTAS_URL:-http://localhost:8080/webhook/alertas}" # <-- ajusta a la URL real
UMBRALES="umbrales.json"
REFRESCO=5
LOG="panel.log"

while getopts "c:a:u:r:h" op; do
  case $op in
    c) CANAL_URL=$OPTARG ;;
    a) ALERTAS_URL=$OPTARG ;;
    u) UMBRALES=$OPTARG ;;
    r) REFRESCO=$OPTARG ;;
    *) echo "Uso: $0 [-c url_canal] [-a url_alertas] [-u umbrales.json] [-r segundos]"; exit 1 ;;
  esac
done

COL=($'\033[32m' $'\033[33m' $'\033[31m' $'\033[90m')   # verde, amarillo, rojo, gris
RST=$'\033[0m'
NOMBRE=(OK AMARILLO ROJO CAIDO)
declare -A ESTADO   # último nivel conocido por host (para alertar solo al cambiar)

log() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

cargar_umbrales() {
  U_AMA=60; U_ROJO=85; U_CAIDO=30
  if [[ -r $UMBRALES ]]; then
    read -r a r c < <(jq -r '[(.amarillo // 60), (.rojo // 85), (.caido_s // 30)] | @tsv' "$UMBRALES" 2>/dev/null)
    U_AMA=${a:-60}; U_ROJO=${r:-85}; U_CAIDO=${c:-30}
  fi
}

# 0 = verde (< amarillo), 1 = amarillo (hasta rojo), 2 = rojo (> rojo)
nivel() {
  awk -v v="$1" -v a="$U_AMA" -v r="$U_ROJO" 'BEGIN{ print (v<a) ? 0 : ((v<=r) ? 1 : 2) }'
}

alertar() {  # host anterior nuevo cpu mem
  local json
  json=$(jq -n -c --arg host "$1" --arg ant "${NOMBRE[$2]}" --arg nue "${NOMBRE[$3]}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cpu "$4" --argjson mem "$5" \
    '{host:$host, anterior:$ant, nuevo:$nue, ts:$ts, cpu_pct:$cpu, mem_pct:$mem}')
  curl -sS -f -m 5 -X POST -H 'Content-Type: application/json' -d "$json" "$ALERTAS_URL" \
    >/dev/null 2>>"$LOG" || log "ERROR enviando alerta de $1"
}

# Último informe por host + sparkline de CPU de los últimos 20 informes.
FILTRO='
def spark: ["▁","▂","▃","▄","▅","▆","▇","█"] as $c
  | map($c[([((. / 12.5) | floor), 7] | min)]) | join("");
map(select(.datos.host != null))
| group_by(.datos.host)
| .[]
| sort_by(.datos.ts) as $g
| $g[-1].datos as $d
| [ $d.host, $d.cpu_pct, $d.mem.pct,
    ([$d.disco[] | select(.montaje == "/") | .pct] | first // 0),
    $d.carga[0], $d.ts,
    ($now - ($d.ts | fromdateiso8601)),
    ($g | map(.datos.cpu_pct) | .[-20:] | spark) ]
| @tsv'

render() {
  printf 'MONITOR DE RECURSOS   %s   (umbrales: amarillo>=%s%% rojo>%s%% caido>%ss)\n\n' \
    "$(date '+%H:%M:%S')" "$U_AMA" "$U_ROJO" "$U_CAIDO"
  printf '%-14s %7s %7s %7s %6s  %-8s %6s  %s\n' HOST CPU MEM "DISCO /" CARGA HORA EDAD "CPU(20)"
  printf -- '------------------------------------------------------------------------------\n'
  local host cpu mem disco carga ts edad graf n_cpu n_mem n_dis n_glob prev
  while IFS=$'\t' read -r host cpu mem disco carga ts edad graf; do
    [[ -z $host ]] && continue
    n_cpu=$(nivel "$cpu"); n_mem=$(nivel "$mem"); n_dis=$(nivel "$disco")
    n_glob=$n_cpu; (( n_mem > n_glob )) && n_glob=$n_mem; (( n_dis > n_glob )) && n_glob=$n_dis
    (( edad > U_CAIDO )) && n_glob=3

    # alerta solo si cambia el estado
    prev=${ESTADO[$host]:-0}
    if [[ $prev != "$n_glob" ]]; then
      alertar "$host" "$prev" "$n_glob" "$cpu" "$mem" &
      ESTADO[$host]=$n_glob
    fi

    if (( n_glob == 3 )); then
      printf '%s%-14s CAIDO  (ultimo informe hace %ss, a las %s)%s\n' "${COL[3]}" "$host" "$edad" "${ts:11:8}" "$RST"
    else
      printf '%-14s %s%6.1f%%%s %s%6.1f%%%s %s%6.0f%%%s %6.2f  %-8s %5ss  %s%s%s  %s%s%s\n' \
        "$host" \
        "${COL[$n_cpu]}" "$cpu" "$RST" \
        "${COL[$n_mem]}" "$mem" "$RST" \
        "${COL[$n_dis]}" "$disco" "$RST" \
        "$carga" "${ts:11:8}" "$edad" \
        "${COL[$n_cpu]}" "$graf" "$RST" \
        "${COL[$n_glob]}" "${NOMBRE[$n_glob]}" "$RST"
    fi
  done <<< "$1"
}

trap 'tput cnorm; echo; exit 0' INT TERM
tput civis

while true; do
  cargar_umbrales
  if ! datos=$(curl -sS -f -m 5 "$CANAL_URL" 2>&1); then
    log "ERROR consultando el canal: $datos"
    salida="No se puede leer el canal ($CANAL_URL). Reintentando..."
  else
    filas=$(jq -r --argjson now "$(date +%s)" "$FILTRO" <<< "$datos" 2>>"$LOG")
    salida=$(render "$filas")
  fi
  printf '\033[H\033[J%s\n' "$salida"
  sleep "$REFRESCO"
done
