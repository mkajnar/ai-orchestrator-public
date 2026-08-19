"""
evidence — společný tvar výstupu pro všechny checky.

Smysl: přenést disciplínu ultrathink-engineer do DAT, ne do promptu.
Model, který dostane Finding, nemusí utrácet tokeny na otázky
„čím je to podloženo" a „jak bych to vyvrátil" — nese si to zjištění samo.

Každý Finding povinně odpovídá na čtyři věci:
  verdict       co to je
  source        čím to dokládám (příkaz / dotaz — ověřitelné, ne parafráze)
  reason        proč ten verdikt, s čísly
  falsified_by  co by tenhle závěr vyvrátilo

`falsified_by` není ozdoba. Je to nejlevnější obrana proti chybě, která
tenhle systém stála nejvíc času: závěr postavený na neověřeném přístroji
(ORCHESTRATOR.md §3). Kdo píše nový check a neumí falsified_by vyplnit,
ještě neví, co měří.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone

VERDICTS = ("HEALTHY", "DEGRADED", "ANOMALY", "UNKNOWN", "NO_DATA", "CHECK_ERROR")

# Závažnost. UNKNOWN a NO_DATA znamenají „nevím", ne „problém" — nesmějí
# přebít zdravé zjištění. Jeden nedostupný log nedělá z celé flotily NO_DATA.
# Propagují se až tehdy, když není žádné tvrdší zjištění (viz CheckResult.verdict).
_RANK = {"HEALTHY": 1, "DEGRADED": 2, "ANOMALY": 3, "CHECK_ERROR": 4}
_SOFT = ("UNKNOWN", "NO_DATA")

# Exit kódy: stabilní kontrakt pro cron a shell, ať se nemusí parsovat text.
# Pozor: nejsou monotónní podle závažnosti — 3 (NO_DATA) není horší než
# 2 (ANOMALY). Kdo je porovnává, musí použít SEVERITY, ne číslo.
EXIT = {"HEALTHY": 0, "UNKNOWN": 0, "DEGRADED": 1, "ANOMALY": 2,
        "NO_DATA": 3, "CHECK_ERROR": 4}

# Pořadí pro shell: čím vyšší, tím naléhavější.
SEVERITY = {"HEALTHY": 0, "UNKNOWN": 1, "NO_DATA": 1,
            "DEGRADED": 2, "ANOMALY": 3, "CHECK_ERROR": 4}


@dataclass
class Finding:
    subject: str                     # čeho se týká (služba, workload, komponenta)
    verdict: str                     # jeden z VERDICTS
    reason: str                      # proč, s čísly
    source: str                      # příkaz nebo dotaz, kterým to jde zopakovat
    falsified_by: str                # co by tenhle závěr vyvrátilo
    numbers: dict = field(default_factory=dict)
    suggested_tier: str = ""         # haiku | sonnet | opus — viz suggest_tier()

    def __post_init__(self):
        if self.verdict not in VERDICTS:
            raise ValueError(f"neznámý verdict {self.verdict!r}")

    def line(self) -> str:
        """Jeden řádek pro brief. Tohle vidí model — drž to hutné."""
        nums = " ".join(f"{k}={v}" for k, v in self.numbers.items())
        return f"{self.verdict:<8} {self.subject:<14} {self.reason}" + (f"  [{nums}]" if nums else "")


@dataclass
class CheckResult:
    check_id: str
    check_version: str
    findings: list = field(default_factory=list)
    unknowns: list = field(default_factory=list)   # co check vědomě NEMĚŘÍ
    error: str = ""

    @property
    def verdict(self) -> str:
        if self.error:
            return "CHECK_ERROR"
        if not self.findings:
            return "NO_DATA"
        hard = [f.verdict for f in self.findings if f.verdict not in _SOFT]
        if hard:
            return max(hard, key=lambda v: _RANK[v])
        # Samá „nevím" — pak teprve nevím i jako celek.
        return "NO_DATA" if any(f.verdict == "NO_DATA" for f in self.findings) else "UNKNOWN"

    @property
    def exit_code(self) -> int:
        return EXIT[self.verdict]

    def problems(self) -> list:
        return [f for f in self.findings if f.verdict in ("DEGRADED", "ANOMALY")]

    def to_json(self) -> str:
        return json.dumps({
            "check_id": self.check_id,
            "check_version": self.check_version,
            "measured_at": datetime.now(timezone.utc).isoformat(),
            "verdict": self.verdict,
            "findings": [asdict(f) for f in self.findings],
            "unknowns": self.unknowns,
            "error": self.error or None,
        }, ensure_ascii=False, indent=2)

    def to_line(self) -> str:
        """Nejlevnější tvar — pro cron a pro tick, který skončí bez zásahu."""
        bad = " ".join(f"{f.subject}:{f.verdict}" for f in self.problems())
        return f"{self.verdict} {self.check_id} {bad}".strip()

    def to_brief(self) -> str:
        """Kompaktní vstup pro model. Jen problémy — zdravé řádky model nepotřebuje.
        Prázdný string = není o čem přemýšlet, model se nevolá."""
        probs = self.problems()
        if not probs and not self.error:
            return ""
        out = [f"## {self.check_id} v{self.check_version} → {self.verdict}"]
        if self.error:
            out.append(f"CHECK_ERROR: {self.error}")
            out.append("Pozn.: selhalo měření, ne nutně služba.")
        for f in probs:
            out.append(f.line())
            out.append(f"    doklad:   {f.source}")
            out.append(f"    vyvrátí:  {f.falsified_by}")
        if self.unknowns:
            out.append("nezměřeno: " + "; ".join(self.unknowns))
        return "\n".join(out)


def suggest_tier(verdict: str, known_cause: bool, systems: int = 1) -> str:
    """Deterministický sorting hat — model se nevybírá úvahou, ale pravidlem.

    haiku   mechanická akce podle hotového postupu
    sonnet  jeden systém, příčina zúžená
    opus    víc systémů nebo neznámá příčina — jediný případ, kdy se platí za myšlení
    """
    if verdict in ("HEALTHY", "UNKNOWN", "NO_DATA"):
        return ""
    if verdict == "CHECK_ERROR":
        return "sonnet"
    if systems > 1 or not known_cause:
        return "opus"
    return "sonnet" if verdict == "ANOMALY" else "haiku"
