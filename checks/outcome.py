#!/usr/bin/env python3
"""
outcome — ŠABLONA. Měří to, na čem záleží, ne to, jestli běží proces.

Tohle je jediný check, který rozhoduje o zdraví. Doplň do něj svůj zdroj pravdy
(řádky označené TODO) — u obchodního provozu je to typicky tabulka, kam se
zapisuje výsledek každého pokusu: přijato / odmítnuto / duplicita / chyba.

PROČ SE NEMĚŘÍ PROCES
---------------------
    Running proces      != zdravá služba
    HTTP 200            != zdravá služba
    prázdný error log   != zdravá služba
    neprázdná fronta    != zdravá služba

Zdravá služba = výsledek dorazil tam, kam měl, v očekávaném množství.

JAK VOLIT PRÁH
--------------
NEPŘEBÍREJ číslo odjinud. Práh typu „pokles o 20 %" bývá naměřený proti jinému
oknu a v jiném režimu; použitý jinde označí za poruchu polovinu zdravých oken.

Postup, který funguje:
  1. vezmi historii aspoň 30 dní
  2. rozděl ji na okna stejné délky jako to, které budeš měřit
  3. spočítej poměr okna k mediánu STEJNÉHO bloku denní doby
     (provoz mívá denní cyklus; srovnávat s předchozím oknem je nesmysl)
  4. práh = percentil, který jsi ochoten obětovat jako falešný poplach
     (p05 -> ~5 % zdravých oken falešně, p10 -> ~10 %)

Konstanty níž jsou PŘÍKLAD z jednoho reálného provozu. Přepiš je vlastním
měřením a napiš k nim, odkud pocházejí — jinak je za rok nikdo neumí obhájit.

Exit: 0 HEALTHY  1 DEGRADED  2 ANOMALY  3 NO_DATA  4 CHECK_ERROR
CHECK_ERROR není selhání služby, je to selhání měření — ale nesmí se skrýt.
"""

import argparse
import statistics
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lib.evidence import CheckResult, Finding, suggest_tier  # noqa: E402

CHECK_ID = "outcome"
VERSION = "1"

# TODO: co sledovat — služby, služby, pipeline, cokoli má vlastní outcome
SUBJECTS = ["sluzba-a", "sluzba-b"]

# TODO: přepiš vlastním měřením (viz JAK VOLIT PRÁH výše)
ANOMALY_RATIO = 0.10       # příklad: p05
DEGRADED_RATIO = 0.34      # příklad: p10
MIN_BASELINE_DAYS = 7      # míň dní = medián není medián
MIN_BASELINE_MEDIAN = 10   # pod tím je procento šum
BASELINE_DAYS = 14
BLOCK_HOURS = 4            # okno; ať odpovídá tomu, jak rychle se výsledek pozná
VALUE_PER_ITEM = 0.0       # TODO: kolik je jedna položka, ať jde říct cena výpadku

SOURCE = "TODO: dotaz nebo příkaz, kterým to jde zopakovat"
FALSIFY = ("TODO: co by tenhle závěr vyvrátilo. Bez toho check jen hlásí čísla. "
           "Např.: nižší výsledek může být menší nabídka na vstupu, ne porucha — "
           "rozliší to poměr odmítnutých k přijatým.")


def fetch(subject, start, end):
    """TODO: vrať {'ok': int, 'rejected': int, 'error': int} za okno.

    Sem patří dotaz do tvé DB, API nebo logu. Drž ho levný — tenhle check
    běží často. Když zdroj není dostupný, vyhoď výjimku; volající z toho
    udělá CHECK_ERROR a nezamění to za nulu.
    """
    raise NotImplementedError("doplň fetch() — bez něj check nemá co měřit")


def baseline(subject, block_index, days, now):
    """Medián `ok` ve stejném bloku denní doby za předchozí CELÉ dny.

    Dnešek se nezapočítává — neúplný den by medián stlačil dolů a check by
    hlásil propad tam, kde je jen půlka okna.
    """
    vals = []
    for d in range(1, days + 1):
        day = now - timedelta(days=d)
        start = day.replace(hour=block_index * BLOCK_HOURS, minute=0, second=0, microsecond=0)
        try:
            vals.append(fetch(subject, start, start + timedelta(hours=BLOCK_HOURS)).get("ok", 0))
        except NotImplementedError:
            raise
        except Exception:
            continue
    return (statistics.median(vals) if vals else 0.0), len(vals)


def verdict(now_ok, expected, n_days):
    if n_days < MIN_BASELINE_DAYS:
        return "UNKNOWN", f"baseline má jen {n_days} dní (< {MIN_BASELINE_DAYS})"
    if expected < MIN_BASELINE_MEDIAN:
        return "UNKNOWN", f"medián baseline jen {expected:.0f} (< {MIN_BASELINE_MEDIAN})"
    if now_ok == 0:
        return "ANOMALY", f"nula proti očekávaným {expected:.0f} — kolaps, ne šum"
    ratio = now_ok / expected
    if ratio < ANOMALY_RATIO:
        return "ANOMALY", f"{ratio:.0%} očekávaného (práh {ANOMALY_RATIO:.0%})"
    if ratio < DEGRADED_RATIO:
        return "DEGRADED", f"{ratio:.0%} očekávaného (práh {DEGRADED_RATIO:.0%})"
    return "HEALTHY", f"{ratio:.0%} očekávaného"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-days", type=int, default=BASELINE_DAYS)
    ap.add_argument("--subject", action="append")
    ap.add_argument("--quiet", action="store_true", help="jeden řádek (nejlevnější)")
    ap.add_argument("--brief", action="store_true", help="jen problémy, vstup pro model")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    blk = now.hour // BLOCK_HOURS
    block_start = now.replace(hour=blk * BLOCK_HOURS, minute=0, second=0, microsecond=0)
    elapsed = (now - block_start).total_seconds() / 3600
    scale = max(elapsed / BLOCK_HOURS, 0.01)   # probíhající blok se porovnává poměrně

    res = CheckResult(check_id=CHECK_ID, check_version=VERSION, unknowns=[
        "kvalita a úplnost výsledků (měří se jen počet)",
        "zda pokles není menší nabídkou na vstupu",
    ])

    try:
        for subj in (args.subject or SUBJECTS):
            cur = fetch(subj, block_start, now)
            med, n_days = baseline(subj, blk, args.baseline_days, now)
            expected = med * scale
            v, why = verdict(cur.get("ok", 0), expected, n_days)
            res.findings.append(Finding(
                subject=subj, verdict=v, reason=why,
                source=f"{SOURCE} | subject={subj} block={blk * BLOCK_HOURS:02d}h",
                falsified_by=FALSIFY,
                numbers={"ok": cur.get("ok", 0), "expected": round(expected),
                         "rejected": cur.get("rejected", 0),
                         "value": round(cur.get("ok", 0) * VALUE_PER_ITEM, 2)},
                suggested_tier=suggest_tier(v, known_cause=False, systems=1),
            ))
    except NotImplementedError as exc:
        res.error = f"šablona není doplněná: {exc}"
    except Exception as exc:
        res.error = f"{type(exc).__name__}: {exc}"

    print(res.to_line() if args.quiet else (res.to_brief() if args.brief else res.to_json()))
    return res.exit_code


if __name__ == "__main__":
    sys.exit(main())
