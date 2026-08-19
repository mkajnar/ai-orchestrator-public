#!/usr/bin/env bash
# attach.sh — připojení k běžícímu agentovi.
#
#   ./attach.sh            připojí se (můžeš agentovi i psát)
#   ./attach.sh -r         jen kouká, klávesy neprojdou — na letmý pohled
#   ./attach.sh --tail     posledních 40 řádků bez připojení (funguje i bez TTY)
#   ./attach.sh --log      sleduje state/agent.log
#
# Odpojení: Ctrl-b  pak  d      (session i agent běží dál)
# Scroll:   Ctrl-b  pak  PgUp   (ven z historie: q)
#
# Funguje pro roota i ubuntu — socket je 660 a root práva ignoruje.
# POZOR: attach potřebuje terminál. Z Claude Code přes "!" to nepůjde,
# skončí to na "open terminal failed: not a terminal". Spusť to v SSH.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCK="${SOCK:-${ORCH_SOCK:-/tmp/$(basename "$ROOT").sock}}"
SESSION="${SESSION:-${ORCH_SESSION:-$(basename "$ROOT")}}"
T=(tmux -S "$SOCK")

if ! "${T[@]}" has-session -t "$SESSION" 2>/dev/null; then
  cat >&2 <<EOF
Agent neběží (session '$SESSION' na $SOCK neexistuje).

  nastartovat:  $ROOT/run.sh
  proč stojí:   ls $ROOT/state/STOP     (existuje = úmyslně zastaven)
EOF
  exit 1
fi

case "${1:-attach}" in
  --tail|-t)
    "${T[@]}" capture-pane -t "$SESSION" -p | grep -vE '^\s*$' | tail -40
    exit 0 ;;
  --log|-l)
    exec tail -f "$ROOT/state/agent.log" ;;
  -r|--read-only)
    exec "${T[@]}" attach -t "$SESSION" -r ;;
  attach|-a) ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "neznámý argument: $1  (zkus --help)" >&2; exit 64 ;;
esac

if [ ! -t 0 ] || [ ! -t 1 ]; then
  cat >&2 <<EOF
Nejsi v terminálu, attach by skončil na "open terminal failed".

  Z Claude Code použij:   ./attach.sh --tail
  Živě se připoj z SSH:   cd $ROOT && ./attach.sh
EOF
  exit 1
fi

echo "připojuji se k '$SESSION' — odpojení: Ctrl-b pak d"
exec "${T[@]}" attach -t "$SESSION"
