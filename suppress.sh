#!/usr/bin/env bash
# suppress.sh — má se na tenhle nález volat model, nebo je to už vyřízené?
#
#   ./suppress.sh "<brief>"    → exit 0 = volat model, 1 = potlačit
#
# Bez tohohle by vyvrácená anomálie spálila cyklus každých 15 minut donekonečna.
# Našel to sám agent v prvním ostrém cyklu: "triage vyvolá ANOMALY:<služba> znovu
# každých 15 min, i když je uzavřený jako false_positive".
#
# Potlačuje se podle `dedupe_key` (tvar VERDICT:subject, tedy přesně to, co
# triage vypisuje) a stavu incidentu:
#   closed | false_positive | resolved   → potlačit, dokud se stav nezhorší
#   escalated                            → potlačit, čeká se na člověka
#   ostatní                              → volat model
#
# Zhoršení potlačení ruší: DEGRADED:x potlačené neznamená potlačené ANOMALY:x.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INC="$ROOT/state/incidents"
BRIEF="${1:-}"
[ -n "$BRIEF" ] || { echo "chybí brief" >&2; exit 0; }
[ -d "$INC" ] || exit 0

SUPPRESSED_STATES="closed false_positive resolved escalated"
# Stav `validating` čeká na outcome, který se pozná až za hodiny nebo dny.
# Potlačuje se do času v `recheck_after` — pak se model zavolá, aby ověřil,
# jestli oprava skutečně zabrala. Bez toho by buď mlel dokola každých 15 min,
# nebo by ověření nikdo neudělal (a "zelený rollout" by prošel jako hotovo).

# Nálezy v briefu, tvar "VERDICT  subject"
mapfile -t findings < <(printf '%s' "$BRIEF" \
  | grep -oE '^(DEGRADED|ANOMALY) +[A-Za-z0-9/_.-]+' \
  | awk '{print $1":"$2}' | sort -u)

[ ${#findings[@]} -eq 0 ] && exit 0

live=0
for f in "${findings[@]}"; do
  hit=""
  for y in "$INC"/*.yaml; do
    [ -f "$y" ] || continue
    # sed, ne awk -F': *' — hodnota sama obsahuje dvojtečku (DEGRADED:<služba>)
    key=$(sed -n 's/^dedupe_key: *//p' "$y" | head -1 | tr -d '"' | tr -d '\r')
    [ "$key" = "$f" ] || continue
    st=$(sed -n 's/^state: *//p' "$y" | head -1 | tr -d '"' | tr -d '\r')
    for s in $SUPPRESSED_STATES; do
      [ "$st" = "$s" ] && { hit="$st"; break; }
    done
    if [ "$st" = "validating" ]; then
      ra=$(sed -n 's/^ *recheck_after: *//p' "$y" | head -1 | tr -d '"' | tr -d "\r")
      if [ -n "$ra" ]; then
        now_e=$(date -u +%s); ra_e=$(date -u -d "$ra" +%s 2>/dev/null || echo 0)
        if [ "$now_e" -lt "$ra_e" ]; then
          hit="validating do $ra"
        else
          echo "  → $f: stabilizační okno uplynulo, čas ověřit outcome" >&2
        fi
      fi
    fi
    break
  done
  if [ -n "$hit" ]; then
    echo "potlačeno: $f (incident ve stavu $hit)"
  else
    echo "k řešení: $f"
    live=1
  fi
done

[ "$live" = "1" ] && exit 0 || exit 1
