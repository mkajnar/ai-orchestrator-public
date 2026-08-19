#!/usr/bin/env bash
# with_lock.sh — serializuje produkční zápisy (ORCHESTRATOR.md §16).
#
#   ./lib/with_lock.sh <incident_id> <cíl> -- <příkaz...>
#
# Read-only diagnostika lock nepotřebuje. Cokoli, co mutuje produkci
# (build, deploy, kubectl apply, prepare.sh varianty B/C, zápis do Mongo),
# musí projít tudy.
#
# Lock drží flock na deskriptoru — spadne-li proces jakkoli, zámek zmizí
# s ním. Žádný stale lock k ručnímu úklidu.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/state"
LOCK="$STATE/lock"
META="$STATE/lock.meta"
STOP="$STATE/STOP"

usage() { echo "použití: $0 <incident_id> <cíl> -- <příkaz...>" >&2; exit 64; }

[ $# -ge 4 ] || usage
INCIDENT="$1"; TARGET="$2"; shift 2
[ "$1" = "--" ] || usage
shift

mkdir -p "$STATE"

if [ -f "$STOP" ]; then
  echo "STOP switch aktivní ($STOP) — mutace se neprovádí." >&2
  exit 75
fi

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Lock drží jiný běh:" >&2
  [ -f "$META" ] && cat "$META" >&2
  echo "Neuvolňuj ho ručně — nejdřív ověř, že původní operace opravdu neběží." >&2
  exit 75
fi

cat > "$META" <<EOF
run_id:      $RUN_ID
incident_id: $INCIDENT
target:      $TARGET
command:     $*
pid:         $$
acquired_at: $(date -u +%FT%TZ)
host:        $(hostname)
recovery:    lock je flock na deskriptoru; po pádu procesu zaniká sám
EOF

cleanup() {
  rc=$?
  printf 'released_at: %s\nexit_code:   %s\n' "$(date -u +%FT%TZ)" "$rc" >> "$META"
  exit $rc
}
trap cleanup EXIT

echo "[lock] run=$RUN_ID incident=$INCIDENT target=$TARGET" >&2
"$@"
