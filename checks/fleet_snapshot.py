#!/usr/bin/env python3
"""
fleet_snapshot — ŠABLONA. Stav infrastruktury za zlomek tokenů, které stojí
syrové výpisy.

Princip: agregace patří na hostitele, kde je zadarmo, ne do kontextu modelu.
`docker ps` nad stovkou kontejnerů nebo `kubectl logs --tail=200` stojí desítky
tisíc tokenů, přestože skutečný signál v nich jsou jednotky řádků. Zdravý řádek
nese nula informace a stojí stejně jako nemocný.

Komprimuje se proto JEN to, co je v pořádku — nezdravé se vypisuje jmenovitě.

TODO: doplň názvy svých kontejnerů, namespaců a logů (konstanty níž).
Tenhle check NIKDY nerozhoduje o zdraví sám — od toho je outcome.py.
Prahy chybovosti v logu jsou schválně hrubé, protože distribuci nikdo neměřil;
kdo ji změří, ať je nahradí a napíše k nim odkud jsou.
"""

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from lib.evidence import CheckResult, Finding, suggest_tier  # noqa: E402

CHECK_ID = "fleet_snapshot"
VERSION = "2"

# Hromadné kontejnery: u nich stačí vědět, kolik jich běží, ne který.
BULK_PREFIXES = ("worker-",)   # TODO: prefix hromadných kontejnerů, u kterých stačí počet
EPHEMERAL_IMAGES = ()          # TODO: image, které vznikají a zanikají (browser gridy apod.)

NAMED_CONTAINERS = ()          # TODO: kontejnery, na kterých záleží jmenovitě
NAMESPACES = ()                # TODO: k8s namespaces, prázdné = k8s se přeskočí

# TODO: logy, které stojí za agregaci. Např.:
#   ("api", ["kubectl", "logs", "-n", "prod", "deploy/api", "--tail=200"]),
#   ("worker", ["docker", "logs", "--tail", "200", "worker-1"]),
LOG_TARGETS = []


def sh(cmd, timeout=30):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0 and not r.stdout:
        raise RuntimeError(f"{' '.join(cmd[:3])}… → rc={r.returncode}: {r.stderr.strip()[:200]}")
    return r.stdout


def check_docker(res):
    out = sh(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}"])
    bulk = Counter()
    unhealthy = []
    named = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, image, state, status = parts[0], parts[1], parts[2], parts[3]
        if any(image.startswith(p) for p in EPHEMERAL_IMAGES):
            continue
        if any(name.startswith(p) for p in BULK_PREFIXES):
            bulk[state] += 1
            if state != "running" or "unhealthy" in status:
                unhealthy.append(f"{name}({state})")
            continue
        named[name] = (state, status)

    running = bulk.get("running", 0)
    total = sum(bulk.values())
    if total:
        res.findings.append(Finding(
            subject="bulk",
            verdict="HEALTHY" if not unhealthy else "DEGRADED",
            reason=(f"{running}/{total} kontejnerů běží"
                    + (f", nezdravé: {', '.join(unhealthy[:5])}" if unhealthy else "")),
            source="docker ps -a --format '{{.Names}}\\t{{.State}}'",
            falsified_by="běžící proces != produkovaný výsledek; ověř outcome.py"
                         "ověř výsledek přes outcome.py",
            numbers={"running": running, "total": total},
        ))

    for name in NAMED_CONTAINERS:
        state, status = named.get(name, ("missing", "not found"))
        healthy = state == "running" and "unhealthy" not in status
        res.findings.append(Finding(
            subject=name,
            verdict="HEALTHY" if healthy else "ANOMALY",
            reason=status if name in named else "kontejner neexistuje",
            source=f"docker ps -a --filter name={name}",
            falsified_by="běžící proces != produkuje výsledek; potvrzuje až outcome.py",
            numbers={},
            suggested_tier="" if healthy else suggest_tier("ANOMALY", known_cause=True),
        ))


# Stavy, které znamenají aktivní potíž bez ohledu na zbytek deploymentu.
ACTIVE_FAIL = ("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull",
               "Pending", "OOMKilled", "Evicted")


def check_k8s(res):
    """Mrtvý pod není totéž co rozbitý služba.

    # TODO: doplň vlastní měření, ať je čím prahy obhájit.
    a 15. 8. — zbytky starých ReplicaSetů po redeployi — zatímco aktuální pod
    běží 45 h jako 1/1. První verze tohoto checku z toho udělala ANOMALY.
    Rozhoduje proto dostupnost deploymentu, ne existence mrtvého podu.
    """
    deploys = sh(["kubectl", "get", "deploy", "-A", "--no-headers"], timeout=45)
    degraded_deploys = []
    for line in deploys.splitlines():
        f = line.split()
        if len(f) < 3 or f[0] not in NAMESPACES:
            continue
        ns, name, ready = f[0], f[1], f[2]
        have, want = (ready.split("/") + ["0"])[:2]
        if want != "0" and have != want:
            degraded_deploys.append(f"{name}={ready}")

    pods = sh(["kubectl", "get", "pods", "-A", "--no-headers"], timeout=45)
    active, stale_failed, restarts, running = [], 0, [], 0
    for line in pods.splitlines():
        f = line.split()
        if len(f) < 5 or f[0] not in NAMESPACES:
            continue
        pod, status, restart = f[1], f[3], f[4]
        if status in ("Running", "Completed", "Succeeded"):
            running += 1
            n = int(restart) if restart.isdigit() else 0
            if n >= 5:
                restarts.append(f"{pod}(r={n})")
        elif any(s in status for s in ACTIVE_FAIL):
            active.append(f"{pod}={status}")
        else:
            stale_failed += 1     # Error/Failed s živou náhradou = zbytek po redeployi

    if degraded_deploys or active:
        verdict = "ANOMALY"
        parts = []
        if degraded_deploys:
            parts.append("deployment bez replik: " + ", ".join(degraded_deploys[:4]))
        if active:
            parts.append("pody v potíži: " + ", ".join(active[:4]))
        reason = "; ".join(parts)
    elif restarts:
        verdict, reason = "DEGRADED", "vysoké restarty: " + ", ".join(restarts[:6])
    else:
        verdict = "HEALTHY"
        reason = f"{running} podů Running/Completed, všechny deploymenty plné"
        if stale_failed:
            reason += f" ({stale_failed} mrtvých podů po redeployi — neuklizeno, ne porucha)"

    res.findings.append(Finding(
        subject="k8s",
        verdict=verdict,
        reason=reason,
        source="kubectl get deploy,pods -A --no-headers (jen sledované namespaces)",
        falsified_by="plný deployment není zdravý služba — outcome měří outcome.py; "
                     "suspended cronjob se tu neprojeví vůbec",
        numbers={"running": running, "deploy_degraded": len(degraded_deploys),
                 "active_fail": len(active), "stale_failed": stale_failed},
        suggested_tier=suggest_tier(verdict, known_cause=bool(active), systems=1),
    ))


# Úroveň je pole hlavičky, ne slovo kdekoli na řádku. Původní `" error " in low`
# počítalo <služba> řádek "WARNING | is_valid_page — Chrome error page detected" jako
# ERROR: 39 z 200 řádků při skutečných 0 ERROR Naměřeno v reálném provozu:.
# Tři formáty logů, které umí rozeznat. Doplň si vlastní, když máš jiný:
#   loguru:   2026-01-01 12:00:00.000 | WARNING  | modul:fn:577 - zpráva
#   varianta 1: 21:38:12 [INFO] [Modul] zprava
#   varianta 2: 2026-01-01T12:00:00.000+0100 INFO [MODUL] zprava
LEVEL_RE = re.compile(
    r"[^|\[]{0,40}(?:"
    r"\|\s*(critical|error|warning)\s*\|"
    r"|\[(critical|error|warning)\]"
    r"|\s(critical|error|warning)\s)")


def check_logs(res, tail):
    """Log se needituje do kontextu — agreguje se na počty podle úrovně a typu."""
    # TODO: doplň své logy. Formát: (jméno, příkaz jako pole).
    # Prázdný seznam = logy se přeskočí a check hlásí jen kontejnery/k8s.
    targets = LOG_TARGETS
    # Holý podřetězec tu nestačí — Naměřeno v reálném provozu: na živých logech:
    # TODO: vzory, které v TVÝCH logách znamenají potíž. Klíč je jméno signálu,
    # hodnota je n-tice podřetězců nebo zkompilovaných regexů.
    #
    # Holý podřetězec často nestačí — třímístné číslo se trefí do ID i do názvů.
    # Kde hrozí falešná shoda, použij regex s kontextem.
    signals = {
        "timeout":     ("timeout", "timed out"),
        "refused":     ("connection refused", "econnrefused"),
        "auth":        (re.compile(r"\b401\b|\b403\b|unauthorized|forbidden"),),
        "rate_limit":  (re.compile(r"\b429\b|rate limit|too many requests"),),
        "server_err":  (re.compile(r"\b5\d\d\b(?!\s*ms)|internal server error"),),
        "traceback":   ("traceback", "stack trace"),
        "oom":         ("out of memory", "oomkilled"),
    }
    for name, cmd in targets:
        try:
            raw = sh(cmd, timeout=45)
        except Exception as exc:
            res.findings.append(Finding(
                subject=f"log/{name}", verdict="UNKNOWN",
                reason=f"log nedostupný: {str(exc)[:80]}",
                source=" ".join(cmd[:4]),
                falsified_by="nedostupný log neznamená rozbitý služba",
            ))
            continue

        lines = raw.splitlines()
        levels = Counter()
        hits = Counter()
        for ln in lines:
            low = ln.lower()
            m = LEVEL_RE.match(low)
            if m:
                levels[m.group(m.lastindex)] += 1
            for key, needles in signals.items():
                if any(n.search(low) if hasattr(n, "search") else n in low
                       for n in needles):
                    hits[key] += 1

        n = len(lines)
        err = levels.get("error", 0) + levels.get("critical", 0)
        err_ratio = err / n if n else 0.0
        blocked = hits.get("auth", 0) + hits.get("rate_limit", 0)

        # Prahy níž jsou PROVIZORNÍ — distribuce chybovosti v logu změřená
        # není. Proto jsou schválně hrubé a tenhle check nikdy nerozhoduje
        # sám: verdikt o zdraví patří outcome.py,
        # tohle je podpůrný signál pro zúžení příčiny.
        # Blokace samy o sobě verdikt nemění — jedna 403 z 200 řádků je normální
        # provoz Naměřeno v reálném provozu: na <služba>). Reportují se jako číslo a poplach
        # spouští až jejich dominance.
        blocked_ratio = blocked / n if n else 0.0
        if n == 0:
            verdict, reason = "NO_DATA", "log prázdný"
        elif blocked_ratio > 0.20:
            verdict = "ANOMALY"
            reason = f"blokace dominují: {blocked}/{n} řádků"
        elif err_ratio > 0.20:
            verdict = "ANOMALY"
            reason = f"{err} chyb z {n} řádků"
        elif err_ratio > 0.05:
            verdict = "DEGRADED"
            reason = f"{err} chyb z {n} řádků"
        else:
            verdict = "HEALTHY"
            reason = f"{n} řádků, {err} chyb, {blocked} blokací"

        res.findings.append(Finding(
            subject=f"log/{name}",
            verdict=verdict,
            reason=reason + (f"; {dict(hits)}" if hits else ""),
            source=" ".join(cmd),
            falsified_by="okno je posledních %d řádků, ne časové okno — rychlý služba "
                         "pokryje minuty, pomalý hodiny; čistý log nevylučuje nulový outcome" % tail,
            numbers={"lines": n, **{k: v for k, v in hits.items()}},
            suggested_tier=suggest_tier(verdict, known_cause=bool(blocked), systems=1),
        ))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tail", type=int, default=200)
    ap.add_argument("--quiet", action="store_true", help="jeden řádek (nejlevnější)")
    ap.add_argument("--brief", action="store_true", help="jen problémy, vstup pro model")
    args = ap.parse_args()

    res = CheckResult(check_id=CHECK_ID, check_version=VERSION, unknowns=[
        "skutečný výsledek (tady jen stav procesů)",
        "pozastavené úlohy a jejich verze",
        "kvalita a úplnost dat",
        "prahy chybovosti v logu jsou provizorní — distribuce nezměřena",
    ])

    try:
        check_docker(res)
        check_k8s(res)
        check_logs(res, args.tail)
    except Exception as exc:
        res.error = f"{type(exc).__name__}: {exc}"

    if args.quiet:
        print(res.to_line())
    elif args.brief:
        print(res.to_brief())
    else:
        print(res.to_json())
    return res.exit_code


if __name__ == "__main__":
    sys.exit(main())
