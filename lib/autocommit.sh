#!/usr/bin/env bash
# autocommit.sh — commit a push toho, co změnil agent. Nic víc.
#
#   ./lib/autocommit.sh snap   <repo> <run_dir>
#   ./lib/autocommit.sh commit <repo> <run_dir> <incident_id> "<zpráva>"
#
# PROČ NE `git add -A`
# -------------------
# Stromy jsou od  čisté (tools/clean-tree.sh), takže by `add -A`
# dnes většinou prošlo. To ale není záruka: vlastník i jiný agent do repozitářů
# commitují dál — do některých píše ještě někdo — a stačí jedna
# rozpracovaná změna, aby se smetla do commitu agenta a nikdo to nerozlišil
# (ORCHESTRATOR.md §12: cizí změny nikdy nestashuj ani nepřepisuj).
#
# Před úklidem to byl doložený stav: všech 7 repozitářů mělo rozpracované
# změny staré 3 až 9 dní. Ochrana zůstává, protože se ten stav vrátí.
#
# Stav se proto zaznamená PŘED zásahem (`snap`) a commitne se jen to, co proti
# tomu snapshotu přibylo. Deterministicky, bez důvěry v to, co agent tvrdí,
# že změnil.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"; REPO="${2:-}"; RUN_DIR="${3:-}"

[ -n "$MODE" ] && [ -n "$REPO" ] && [ -n "$RUN_DIR" ] || {
  echo "použití: $0 snap|commit <repo> <run_dir> [incident] [zpráva]" >&2; exit 64; }
[ -d "$REPO/.git" ] || { echo "není git repo: $REPO" >&2; exit 66; }

NAME=$(basename "$REPO")
SNAP="$RUN_DIR/${NAME}.pre-status"
mkdir -p "$RUN_DIR"

status_of() { cd "$REPO" && git status --porcelain --untracked-files=all 2>/dev/null; }

if [ "$MODE" = "snap" ]; then
  status_of > "$SNAP"
  cd "$REPO"
  git rev-parse HEAD > "$RUN_DIR/${NAME}.pre-head"
  # Hash obsahu, ne jen stav: rozpracovaný soubor zůstane ' M' i poté, co do něj
  # agent sáhne, takže samotný status změnu neodhalí. Bez hashů by se tiché
  # přepsání cizí práce neprojevilo vůbec — a to je horší než hlasitá chyba.
  : > "$RUN_DIR/${NAME}.pre-hashes"
  while IFS= read -r l; do
    p="${l:3}"
    [ -f "$p" ] && printf '%s  %s\n' "$(md5sum < "$p" | cut -d' ' -f1)" "$p" \
      >> "$RUN_DIR/${NAME}.pre-hashes"
  done < "$SNAP"
  echo "[autocommit] snapshot $NAME: $(wc -l < "$SNAP") rozpracovaných souborů"
  exit 0
fi

[ "$MODE" = "commit" ] || { echo "neznámý režim: $MODE" >&2; exit 64; }
INCIDENT="${4:-none}"; MSG="${5:-}"
[ -n "$MSG" ] || { echo "chybí zpráva commitu" >&2; exit 64; }
[ -f "$SNAP" ] || { echo "chybí snapshot $SNAP — 'snap' se nespustil před zásahem" >&2; exit 65; }

cd "$REPO"

# Soubory, které agent skutečně změnil = rozdíl proti snapshotu.
# Porovnává se celý řádek (stav + cesta), takže i změna už rozpracovaného
# souboru se pozná — ale ta se ZÁMĚRNĚ nekomituje, viz níž.
mapfile -t before < "$SNAP"
mapfile -t after < <(status_of)

declare -A pre_paths=()
for l in "${before[@]}"; do pre_paths["${l:3}"]=1; done

new_files=(); touched_foreign=()
for l in "${after[@]}"; do
  p="${l:3}"
  if [ -z "${pre_paths[$p]:-}" ]; then
    new_files+=("$p")
  else
    # Soubor byl rozpracovaný UŽ PŘED zásahem. I když do něj agent sáhl,
    # commit by odnesl i cizí část. Takové soubory se hlásí, ne commitují.
    for b in "${before[@]}"; do
      if [ "${b:3}" = "$p" ] && [ "$b" != "$l" ]; then touched_foreign+=("$p"); fi
    done
  fi
done

if [ ${#touched_foreign[@]} -gt 0 ]; then
  printf '[autocommit] POZOR: agent sáhl do souborů, které už byly rozpracované:\n' >&2
  printf '   %s\n' "${touched_foreign[@]}" >&2
  printf '   Necommituji je — commit by odnesl i cizí práci. Vyřeš ručně.\n' >&2
fi

if [ ${#new_files[@]} -eq 0 ]; then
  echo "[autocommit] $NAME: agent nic nezměnil, není co commitovat"
  exit 0
fi

# Pojistka na secrets. Naměřeno v reálném provozu: heslo k Mongo je v plaintextu
# v HEAD pěti repozitářů a PAT sedí v remote URL — nezhoršovat.
git add -- "${new_files[@]}"
leak=$(git diff --cached -- "${new_files[@]}" \
       | grep -nEi 'ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|password\s*=\s*["'"'"'][^"'"'"']{6,}' \
       | head -3)
if [ -n "$leak" ]; then
  git reset -q -- "${new_files[@]}"
  echo "[autocommit] ZASTAVENO: v diffu vypadá secret. Necommituji, necpushuji." >&2
  echo "$leak" | sed -E 's/(ghp_[A-Za-z0-9]{4}).*/\1…[MASKED]/' >&2
  exit 70
fi

git -c user.name="ai-orchestrator" -c user.email="${GIT_EMAIL:-agent@localhost}" \
    commit -q -m "$MSG

incident: $INCIDENT
run: $(basename "$RUN_DIR")
změněno agentem: ${#new_files[@]} souborů (rozpracované cizí změny ponechány)" || {
  echo "[autocommit] commit selhal" >&2; exit 71; }

sha=$(git rev-parse --short HEAD)
echo "[autocommit] $NAME: commit $sha — ${new_files[*]}"

branch=$(git branch --show-current)
if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  echo "[autocommit] $NAME: branch '$branch' nemá upstream, push přeskočen" >&2
  exit 0
fi

# Nikdy force. Když se vzdálená větev rozešla (do repozitáře může psát
# i někdo jiný), je to k řešení, ne k přepsání.
if git push -q origin "HEAD:$branch" 2>/dev/null; then
  echo "[autocommit] $NAME: pushnuto do origin/$branch"
else
  echo "[autocommit] $NAME: PUSH SELHAL (nejspíš divergence) — commit je lokálně, $sha" >&2
  echo "[autocommit] vyřeš merge ručně; force push je zakázaný" >&2
  exit 72
fi
