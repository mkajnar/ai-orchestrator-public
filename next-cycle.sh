#!/usr/bin/env bash
# next-cycle.sh — agent si tímhle sám naplánuje další cyklus s čistým kontextem.
#
# Volá se na KONCI každého cyklu, po wait.sh:
#     ./next-cycle.sh &
#
# Běží na pozadí, takže agent stihne dokončit svůj tah, a pak jeho vlastní
# session dostane nový pokyn. Je to pořád jedna živá session v tmuxu.
#
# Proč takhle: model si /clear zavolat nemůže (je to uživatelský příkaz), ale
# MÁ Bash — takže si ho pošle do vlastního tmuxu.
#
# /clear NE PO KAŽDÉM CYKLU, ale po CLEAR_EVERY cyklech. Naměřeno v reálném provozu:
# nabootování čisté session stojí 85-99 tisíc tokenů (systémový prompt, nástroje,
# MCP, CLAUDE.md), zatímco vlastní práce cyklu jen 1 400-2 700. Čistit kontext
# po každém cyklu je tedy dražší než ho chvíli držet — cache read je řádově
# levnější než cache write. Stav přežívá na disku, takže vyčištění nic neztratí.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCK="${SOCK:-${ORCH_SOCK:-/tmp/orchestrator.sock}}"
SESSION="${SESSION:-${ORCH_SESSION:-orchestrator}}"
T="tmux -S $SOCK"

[ -f "$ROOT/state/STOP" ] && exit 0

CLEAR_EVERY="${CLEAR_EVERY:-3}"
n=$("$ROOT/cycle.sh" number 2>/dev/null || echo 0)

sleep 3
if [ "$CLEAR_EVERY" -gt 0 ] && [ $(( n % CLEAR_EVERY )) -eq 0 ] && [ "$n" -gt 0 ]; then
  $T send-keys -t "$SESSION" '/clear' Enter 2>/dev/null
  sleep 4
  msg='Další cyklus podle AGENT-LOOP.md. Kontext je čistý záměrně — stav si načti z state/last-cycle.json a state/incidents/. Piš česky.'
else
  msg='Další cyklus podle AGENT-LOOP.md. Piš česky.'
fi

$T send-keys -t "$SESSION" "$msg" 2>/dev/null
sleep 1
$T send-keys -t "$SESSION" Enter 2>/dev/null
