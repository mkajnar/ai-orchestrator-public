#!/usr/bin/env bash
# cycle.sh — stav smyčky na disku. Jediné místo, odkud se po restartu obnovuje.
#
#   ./cycle.sh number          číslo posledního dokončeného cyklu
#   ./cycle.sh done "<co>"     zapíše dokončený cyklus
#   ./cycle.sh show            přehled pro člověka i pro model
#
# Existuje proto, že kontext agenta je záměrně prázdný — každý cyklus dostane
# čistou instanci. Co má přežít, musí být tady, ne v hlavě.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$ROOT/state"
F="$STATE/last-cycle.json"
HIST="$STATE/cycles.log"
mkdir -p "$STATE"

case "${1:-show}" in
  number)
    [ -f "$F" ] && jq -r '.cycle // 0' "$F" 2>/dev/null || echo 0
    ;;

  done)
    note="${2:-}"
    n=$(( $( [ -f "$F" ] && jq -r '.cycle // 0' "$F" 2>/dev/null || echo 0 ) + 1 ))
    ts=$(date -u +%FT%TZ)
    open=$(ls "$STATE/incidents" 2>/dev/null | wc -l)
    mode=$([ -f "$STATE/AUTOFIX" ] && echo AUTOFIX || echo DIAGNOSE)
    jq -n --argjson c "$n" --arg t "$ts" --arg note "$note" \
          --argjson open "$open" --arg mode "$mode" \
      '{cycle:$c, finished_at:$t, note:$note, open_incidents:$open, mode:$mode}' > "$F"
    printf '%s cyklus %s: %s\n' "$ts" "$n" "$note" >> "$HIST"
    echo "cyklus $n zapsán"
    ;;

  show)
    if [ -f "$F" ]; then
      jq -r '"poslední cyklus: \(.cycle)  \(.finished_at)  režim \(.mode)\nco se stalo: \(.note)\notevřených incidentů: \(.open_incidents)"' "$F"
    else
      echo "žádný cyklus zatím neproběhl"
    fi
    echo "---"
    tail -5 "$HIST" 2>/dev/null || true
    ;;

  *) echo "použití: $0 number|done \"<co>\"|show" >&2; exit 64 ;;
esac
