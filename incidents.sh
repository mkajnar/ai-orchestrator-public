#!/usr/bin/env bash
# incidents.sh — přehled incidentů za pár tokenů místo `cat state/incidents/*.yaml`.
#
#   ./incidents.sh            jeden řádek na incident (id, stav, klíč, stáří)
#   ./incidents.sh <id>       celý incident, když ho fakt potřebuješ
#
# Naměřeno v reálném provozu: agent utratil 14 848 tokenů za `cat` a `sed` nad soubory,
# z toho velkou část za incidenty s dlouhými evidence bloky. Souhrn stačí
# k rozhodnutí, detail se čte až když je proč.
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INC="$ROOT/state/incidents"
[ -d "$INC" ] || { echo "žádné incidenty"; exit 0; }

if [ $# -gt 0 ]; then
  f="$INC/$1.yaml"; [ -f "$f" ] || { echo "incident $1 neexistuje" >&2; exit 1; }
  cat "$f"; exit 0
fi

now=$(date -u +%s); found=0
for y in "$INC"/*.yaml; do
  [ -f "$y" ] || continue
  found=1
  id=$(basename "$y" .yaml)
  st=$(sed -n 's/^state: *//p' "$y" | head -1)
  key=$(sed -n 's/^dedupe_key: *//p' "$y" | head -1)
  last=$(sed -n 's/^last_seen_epoch: *//p' "$y" | head -1)
  age=""
  [ -n "$last" ] && age="$(( (now - last) / 3600 ))h"
  printf '%s  %-14s %-18s %s\n' "$id" "$st" "$key" "$age"
done
[ "$found" = 0 ] && echo "žádné incidenty"
exit 0
