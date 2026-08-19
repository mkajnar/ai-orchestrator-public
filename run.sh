#!/usr/bin/env bash
# run.sh — JEDINÝ skript na spuštění agenta. Vždy čistý start.
#
#   ./run.sh            zabije všechno a spustí znovu
#   ./run.sh --stop     zabije všechno a nespustí
#   ./run.sh --status   co běží
#
# Bezpodmínečný restart je záměr: "běží to, tak nic nedělám" byl zdroj stavu,
# kdy session žila, ale agent v ní nepracoval — instrukce spadla do prázdna
# a nikdo to nepoznal (18.-19. 8.: session restartována, poslední cyklus starý
# 34 hodin). Skript proto na konci OVĚŘÍ, že agent skutečně odpovídá, a když ne,
# pokus zopakuje.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pozor: až PO načtení config.sh a s ${VAR:-} — přiřazení natvrdo by
# konfiguraci zahodilo a dvě nasazení na jednom stroji by si sáhla na
# tentýž socket, takže start jednoho by zabil druhé.
SESSION="${SESSION:-orchestrator}"
SOCK="${SOCK:-/tmp/orchestrator.sock}"
LOCK="$ROOT/state/start.lock"
RUN_AS="${AGENT_USER:-$(id -un)}"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
MODEL="${AGENT_MODEL:-opus}"
T=(tmux -S "$SOCK")

INSTRUKCE='Přečti AGENT-LOOP.md a pracuj přesně podle něj. Piš výhradně česky. Na konci každého cyklu spusť ./next-cycle.sh & — bez toho se smyčka zastaví. Čisté cykly nekomentuj.'

# Pod rootem se přepni: claude odmítá --dangerously-skip-permissions pod rootem.
if [ "$(id -u)" = 0 ]; then
  exec sudo -u "$RUN_AS" -H env ORCH_FROM_ROOT=1 "$0" "$@"
fi

# Podle pracovního adresáře procesu, ne podle argumentů: MCP konfigurace je
# volitelná, takže se v příkazové řádce nemusí objevit vůbec.
pids(){
  pgrep -u "$RUN_AS" -x claude 2>/dev/null | while read -r p; do
    [ "$(readlink -f "/proc/$p/cwd" 2>/dev/null)" = "$ROOT" ] && echo "$p"
  done
}

if [ "${1:-}" = "--status" ]; then
  "${T[@]}" has-session -t "$SESSION" 2>/dev/null && s=ANO || s=NE
  echo "session=$s  procesů=$(pids | wc -l)  stop=$([ -f "$ROOT/state/STOP" ] && echo ANO || echo NE)"
  "$ROOT/cycle.sh" show 2>/dev/null | head -2
  exit 0
fi

# ── 1. zabít všechno ─────────────────────────────────────────────────────────
echo "── zabíjím ──"
"${T[@]}" kill-session -t "$SESSION" 2>/dev/null && echo "   session zabita" || echo "   session neběžela"
p=$(pids)
if [ -n "$p" ]; then
  echo "   procesy: $(echo "$p" | tr '\n' ' ')"
  echo "$p" | xargs -r kill 2>/dev/null; sleep 2
  echo "$p" | xargs -r kill -9 2>/dev/null
fi
rm -f "$ROOT/state/WAKE"

if [ "${1:-}" = "--stop" ]; then
  touch "$ROOT/state/STOP"
  echo "   state/STOP založen — agent se nespustí ani z hlídače."
  echo "   zrušit: rm $ROOT/state/STOP"
  exit 0
fi
rm -f "$ROOT/state/STOP"

# ── 2. spustit ───────────────────────────────────────────────────────────────
echo "── startuji ──"
if ! timeout 60 "$CLAUDE" -p ok --model haiku >/dev/null 2>&1; then
  echo "   CHYBA: uživatel $RUN_AS nemá platnou claude session." >&2
  echo "   přihlas se:  sudo -u $RUN_AS -H $CLAUDE" >&2
  exit 78
fi

MCP=""; [ -r "$ROOT/mcp-servers.json" ] && MCP="--mcp-config $ROOT/mcp-servers.json --strict-mcp-config"
UNUSED="CronCreate CronDelete CronList DesignSync EndConversation EnterPlanMode ExitPlanMode \
EnterWorktree ExitWorktree ListMcpResourcesTool Monitor NotebookEdit PushNotification \
ReadMcpResourceTool ReadMcpResourceDirTool RemoteTrigger SendMessage ListAgents TaskOutput \
TaskStop WebFetch WebSearch Workflow ReportFindings ScheduleWakeup Artifact Task Skill"

"${T[@]}" new-session -d -s "$SESSION" -c "$ROOT"
chmod 660 "$SOCK" 2>/dev/null
"${T[@]}" send-keys -t "$SESSION" \
  "cd $ROOT && $CLAUDE --model $MODEL --dangerously-skip-permissions $MCP --disable-slash-commands --setting-sources project --disallowed-tools $UNUSED" Enter

# ── 3. poslat instrukci a OVĚŘIT, že agent pracuje ───────────────────────────
# Tohle je jádro. Čekat na vykreslení rámečku nestačí — prompt přijímá vstup
# později a instrukce se pak ztratí. Ověřuje se proto výsledek, ne vzhled.
pracuje(){ "${T[@]}" capture-pane -t "$SESSION" -p 2>/dev/null \
             | grep -qiE 'triage|AGENT-LOOP|wait\.sh|Read |Bash\(' ; }

for pokus in 1 2 3; do
  n=0
  until "${T[@]}" capture-pane -t "$SESSION" -p 2>/dev/null | grep -qE 'bypass permissions|for shortcuts'; do
    sleep 2; n=$((n+1)); [ $n -ge 40 ] && break
  done
  sleep 3
  "${T[@]}" send-keys -t "$SESSION" "$INSTRUKCE"
  sleep 2
  "${T[@]}" send-keys -t "$SESSION" Enter
  n=0
  until pracuje; do
    sleep 3; n=$((n+1)); [ $n -ge 20 ] && break
  done
  if pracuje; then
    echo "   agent pracuje (pokus $pokus)"
    break
  fi
  echo "   pokus $pokus: agent nereaguje, zkouším znovu" >&2
  [ "$pokus" = 3 ] && { echo "   CHYBA: agent nezačal pracovat ani na 3. pokus." >&2; exit 1; }
done

cat <<EOF

Agent běží. Model $MODEL, uživatel $RUN_AS.

  připojit se:    ./attach.sh
  co dělá:        ./run.sh --status
  zastavit:       ./run.sh --stop
  restart:        ./run.sh
  probudit hned:  touch state/WAKE
EOF
