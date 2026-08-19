#!/usr/bin/env bash
# triage.sh — deterministická brána před modelem.
#
# Pustí všechny checky. Když je flotila v normě, skončí jedním řádkem a model
# se NEVOLÁ VŮBEC. Teprve když něco nesedí, složí brief — jen problémy, s doklady
# a s tím, co by je vyvrátilo — a doporučí nejlevnější tier, který na to stačí.
#
#   ./triage.sh            # lidský výstup + brief, když je co řešit
#   ./triage.sh --line     # jeden řádek (cron)
#   ./triage.sh --brief    # jen brief pro model; prázdný výstup = není o čem přemýšlet
#
# Exit: 0 v normě · 1 degraded · 2 anomaly · 4 chyba měření
#
# Proč to existuje Naměřeno v reálném provozu:
#   docker ps + kubectl get pods + 4× logy   ≈ 29 000 tok   ← co by model přečetl sám
#   triage --line                            ≈     30 tok
#   triage --brief při problému              ≈    400 tok
# Rutinní tick tedy stojí zhruba tisícinu toho, co stojí „podívej se, jak to jede".
set -uo pipefail

# Konfigurace provozu — viz config.sh (zkopíruj z config.example.sh).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$ROOT/config.sh" ] && . "$ROOT/config.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-full}"
STATE="$ROOT/state"
mkdir -p "$STATE"

CHECKS=(
  "checks/outcome.py"     # peníze — rozhoduje o zdraví
  "checks/fleet_snapshot.py"    # infrastruktura — zužuje příčinu
)

# Exit kódy checků NEJSOU seřazené podle závažnosti (NO_DATA=3 není horší než
# ANOMALY=2). Řadíme podle jména verdiktu, ne podle čísla — první verze triage
# na tomhle spadla a jeden nedostupný log přebil skutečnou anomálii.
severity_of() {
  case "$1" in
    HEALTHY|OK) echo 0 ;;
    UNKNOWN|NO_DATA) echo 1 ;;
    DEGRADED) echo 2 ;;
    ANOMALY) echo 3 ;;
    CHECK_ERROR) echo 4 ;;
    *) echo 1 ;;
  esac
}

worst_sev=0
verdict="OK"
worst=0
lines=()
briefs=()

for c in "${CHECKS[@]}"; do
  line=$(cd "$ROOT" && timeout 120 python3 "$c" --quiet 2>&1); rc=$?
  lines+=("$line")
  v="${line%% *}"
  sev=$(severity_of "$v")
  if [ "$sev" -gt "$worst_sev" ]; then
    worst_sev=$sev; verdict="$v"; worst=$rc
  fi
  if [ "$sev" -ge 2 ]; then
    b=$(cd "$ROOT" && timeout 120 python3 "$c" --brief 2>&1)
    [ -n "$b" ] && briefs+=("$b")
  fi
done

[ "$verdict" = "HEALTHY" ] && verdict="OK"

ts=$(date -u +%FT%TZ)
printf '%s %s\n' "$ts" "$verdict ${lines[*]}" >> "$STATE/triage.log"

# Tier se nevybírá úvahou, ale pravidlem. Opus stojí nejvíc a platí se za něj
# jen tam, kde je potřeba myšlení přes víc systémů nebo neznámá příčina.
systems=0
for l in "${lines[@]}"; do [[ "$l" =~ ^(DEGRADED|ANOMALY) ]] && systems=$((systems+1)); done
case "$verdict" in
  OK|NO_DATA)   tier="" ;;
  DEGRADED)     tier=$([ $systems -gt 1 ] && echo opus || echo sonnet) ;;
  ANOMALY)      tier=$([ $systems -gt 1 ] && echo opus || echo sonnet) ;;
  CHECK_ERROR)  tier="sonnet" ;;
esac

if [ "$MODE" = "--line" ]; then
  echo "$verdict ${lines[*]}"
  exit $worst
fi

if [ "$MODE" = "--brief" ]; then
  [ ${#briefs[@]} -eq 0 ] && exit $worst          # ticho = model se nevolá
  printf '%s\n\n' "${briefs[@]}"
  cat <<EOF
## Zadání
Doporučený tier: ${tier:-žádný}. Postupuj podle ORCHESTRATOR.md — §10 root cause,
§11 change contract, §14 správná deploy cesta, §15 rollback gate, §16 lock.
Než z čísla uděláš závěr, přečti u něj řádek "vyvrátí" — je tam proto,
abys neplatila tokeny za ověřování, které už proběhlo.
Mantinely: sdílená data a cokoli viditelného navenek = eskalace, ne akce.
EOF
  exit $worst
fi

echo "── triage $ts ──"
for l in "${lines[@]}"; do echo "   $l"; done
echo
if [ ${#briefs[@]} -eq 0 ]; then
  echo "✓ $verdict — model se nevolá, nic k řešení."
else
  echo "▲ $verdict — je co řešit, tier: ${tier:-?}"
  echo
  printf '%s\n\n' "${briefs[@]}"
  echo "Brief pro model:  ./triage.sh --brief"
fi
exit $worst
