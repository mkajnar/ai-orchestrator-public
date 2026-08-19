#!/usr/bin/env bash
# watchdog.sh — hlídá, že běží PRÁVĚ JEDNA session agenta.
#
#   ./watchdog.sh            kontrola + případný start (tohle volá cron)
#   ./watchdog.sh --status   jen řekne, jak to vypadá
#
# Řeší dvě věci:
#   1. session spadla     → nastartuje ji a pošle ntfy
#   2. sessions je víc    → nechá nejstarší, ostatní zabije, pošle ntfy
#
# Unikátnost stojí na `flock`. Sám watchdog se nespustí dvakrát (cron může
# překrýt běhy) a start agenta je pod stejným zámkem jako v start-agent.sh,
# takže ani ruční spuštění vedle cronu druhou session nevyrobí.
#
# state/STOP je respektován: zastavenou smyčku watchdog nekřísí a mlčí.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${ORCH_SESSION:-orchestrator}"
SOCK="${ORCH_SOCK:-/tmp/orchestrator.sock}"
LOCK="${ORCH_LOCK:-$ROOT/state/start.lock}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
LOG="$ROOT/state/watchdog.log"
T=(tmux -S "$SOCK")

log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
notify(){ curl -s --max-time 10 -X POST "https://ntfy.sh/${NTFY_TOPIC}" \
            -H "Title: orchestrátor" -H "Priority: ${2:-default}" -H "Tags: robot" \
            -d "$1" >/dev/null 2>&1 || true; }

# Claude procesy agenta = ty, které mají v příkazové řádce jeho pracovní adresář.
# Podle jména procesu to nejde — vlastník má claude i jinde a ten se nesmí zabít.
agent_pids(){
  pgrep -u ubuntu -f -- "--mcp-config $ROOT/mcp-servers.json" 2>/dev/null || true
}

status(){
  local s p
  "${T[@]}" has-session -t "$SESSION" 2>/dev/null && s=ANO || s=NE
  p=$(agent_pids | wc -l)
  echo "session=$s  claude_procesů=$p  stop=$([ -f "$ROOT/state/STOP" ] && echo ANO || echo NE)"
  [ "$p" -gt 0 ] && ps -o pid,etime,cmd -p $(agent_pids | tr '\n' ',' | sed 's/,$//') 2>/dev/null | tail -n +2 | cut -c1-90
}

[ "${1:-}" = "--status" ] && { status; exit 0; }

mkdir -p "$ROOT/state"

# Jeden watchdog v jednu chvíli. Bez toho by dva překryté cron běhy
# mohly nastartovat dvě session.
exec 9>"$LOCK"
if ! flock -n 9; then
  log "SKIP jiný watchdog/start běží"
  exit 0
fi

if [ -f "$ROOT/state/STOP" ]; then
  log "SKIP state/STOP"
  exit 0
fi

# ── 1. víc procesů než jeden? ────────────────────────────────────────────────
mapfile -t pids < <(agent_pids)
if [ "${#pids[@]}" -gt 1 ]; then
  # nejstarší podle času startu zůstává, zbytek pryč
  keep=$(ps -o pid= -o lstart= -p "$(printf '%s,' "${pids[@]}" | sed 's/,$//')" 2>/dev/null \
         | sort -k2 | head -1 | awk '{print $1}')
  killed=()
  for p in "${pids[@]}"; do
    [ "$p" = "$keep" ] && continue
    kill "$p" 2>/dev/null && killed+=("$p")
  done
  log "DUPLICITA ${#pids[@]} procesů, ponechán $keep, zabito: ${killed[*]:-nic}"
  notify "Běželo ${#pids[@]} agentů, ponechán PID $keep, ostatní zabity." high
fi

# ── 2. běží session? ─────────────────────────────────────────────────────────
if "${T[@]}" has-session -t "$SESSION" 2>/dev/null && [ "$(agent_pids | wc -l)" -ge 1 ]; then
  log "OK session žije"
  exit 0
fi

# Session bez claude procesu je zombie — tmux okno zůstalo, agent umřel.
if "${T[@]}" has-session -t "$SESSION" 2>/dev/null; then
  log "ZOMBIE session bez claude procesu, ruším"
  "${T[@]}" kill-session -t "$SESSION" 2>/dev/null
fi

log "START session chybí, startuji"
# flock drží tenhle skript, takže start-agent.sh pustíme s vlastním deskriptorem
"$ROOT/run.sh" >>"$LOG" 2>&1
rc=$?
if [ $rc -eq 0 ] && "${T[@]}" has-session -t "$SESSION" 2>/dev/null; then
  log "OK nastartováno"
  notify "Agent spadl a byl restartován." default
else
  log "CHYBA start selhal rc=$rc"
  notify "Agent spadl a NEPODAŘILO se ho nastartovat (rc=$rc)." urgent
fi
exit 0
