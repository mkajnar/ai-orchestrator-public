#!/usr/bin/env bash
# wait.sh — čekání mezi kontrolami. Tady agent NESPALUJE TOKENY.
#
#   ./wait.sh [sekundy]      výchozí 14400 (4 h)
#
# Agent tenhle skript zavolá jako běžný tool call a čeká na jeho výsledek.
# Po celou dobu se model nevolá — žádný kontext, žádné tokeny. Proto se
# interval NEŘEŠÍ externím timerem: agent si spánek řídí sám a zůstává
# přitom živý v tmuxu, takže se na něj dá kdykoli podívat.
#
# Probudí se dřív, když:
#   - vznikne state/WAKE          (ruční probuzení: touch state/WAKE)
#   - vznikne state/STOP          (ať agent ví, že má skončit)
#   - stav se ZHORŠÍ proti tomu, jaký byl na začátku spánku
#
# Poslední bod záměrně měří zhoršení, ne absolutní stav. Agent jde spát
# i s otevřenou anomálií (eskaloval ji, čeká se na člověka) — budit ho na
# tentýž stav by znamenalo smyčku, která nikdy nespí a pálí tokeny za nic.
# Naměřeno v reálném provozu: první verze budila okamžitě a pořád.
#
# Deterministická kontrola během spánku je zadarmo — běží v bashi, ne v modelu.
# POLL_SEC=300: triage trvá ~15 s. Při 4h intervalu to je 48 kontrol za cyklus,
# tedy ~12 minut CPU — pořád dost husté na to, aby se kolaps zachytil do 5 minut.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$ROOT/state"
SECS="${1:-14400}"
POLL_SEC="${POLL_SEC:-300}"

mkdir -p "$STATE"
rm -f "$STATE/WAKE"

sev() {
  case "$1" in
    OK|HEALTHY) echo 0 ;; UNKNOWN|NO_DATA) echo 1 ;;
    DEGRADED) echo 2 ;; ANOMALY) echo 3 ;; CHECK_ERROR) echo 4 ;; *) echo 1 ;;
  esac
}

base_v=$("$ROOT/triage.sh" --line 2>/dev/null | awk '{print $1}')
base_s=$(sev "${base_v:-UNKNOWN}")

start=$(date -u +%s)
deadline=$((start + SECS))
printf 'wait: spím do %s (%ss), výchozí stav %s, budím při zhoršení\n' \
  "$(date -u -d "@$deadline" +%H:%M:%S)" "$SECS" "${base_v:-?}"

while :; do
  now=$(date -u +%s)
  [ "$now" -ge "$deadline" ] && { echo "wait: interval doběhl"; exit 0; }

  if [ -f "$STATE/STOP" ]; then
    echo "wait: STOP switch — agent má skončit"
    exit 10
  fi
  if [ -f "$STATE/WAKE" ]; then
    rm -f "$STATE/WAKE"
    echo "wait: ruční probuzení (state/WAKE)"
    exit 0
  fi

  # Levná kontrola: budí jen zhoršení proti výchozímu stavu.
  v=$("$ROOT/triage.sh" --line 2>/dev/null | awk '{print $1}')
  s=$(sev "${v:-UNKNOWN}")
  if [ "$s" -gt "$base_s" ]; then
    echo "wait: probuzeno dřív — zhoršení $base_v → $v"
    exit 0
  fi

  remaining=$((deadline - now))
  [ "$remaining" -lt "$POLL_SEC" ] && sleep "$remaining" || sleep "$POLL_SEC"
done
