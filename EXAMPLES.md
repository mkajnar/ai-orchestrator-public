# EXAMPLES — jak to nasadit na svůj provoz

Čtyři různé domény, čtyři různé odpovědi na tutéž otázku: **co je výsledek,
na kterém záleží, a jak ho změřím levně.**

Každý příklad ukazuje minimum, které stačí k rozjetí: metriku, `fetch()`,
mantinely a to, co si v dané doméně snadno spletete za poruchu.

---

## 1. E-shop

**Výsledek:** zaplacená objednávka. Ne návštěvnost, ne přidání do košíku.

```python
# checks/outcome.py
SUBJECTS = ["checkout", "platba", "sklad"]
VALUE_PER_ITEM = 0.0          # průměrná marže na objednávku, když ji znáš
BLOCK_HOURS = 1               # e-shop reaguje rychle, hodina stačí

def fetch(subject, start, end):
    if subject == "checkout":
        rows = db.query("""
            SELECT status, COUNT(*) FROM objednavky
            WHERE created_at >= %s AND created_at < %s GROUP BY status
        """, (start, end))
        m = dict(rows)
        return {"ok": m.get("paid", 0),
                "rejected": m.get("payment_failed", 0),
                "error": m.get("error", 0)}
    ...
```

**Mantinely (§5):**

- objednávky a platby jsou **read-only** — agent nikdy nemění stav objednávky,
  ani „jen opravu překlepu ve stavu"
- ceny, slevy a dostupnost jsou eskalace, ne akce
- e-maily zákazníkům neodesílá agent

**Co si spletete za poruchu:**

| Vypadá jako | Ve skutečnosti |
|---|---|
| propad objednávek v noci | denní cyklus — proto medián **stejného bloku denní doby** (§8) |
| propad v pondělí ráno | týdenní cyklus, u B2B extrémní |
| nula plateb 20 minut | výpadek platební brány, ne váš kód — pozná se podle §19 |
| „objednávek je málo" po marketingové akci | vrchol skončil, baseline je zkreslený nahoru |

**Doménová sémantika (§7), kterou musíte napsat:** `pending` je dočasný stav,
který se sám vyřeší · `payment_failed` se opakuje a část z nich nakonec projde ·
`cancelled` je terminální · testovací objednávky ze staging IP se nepočítají.

---

## 2. ETL / datová pipeline

**Výsledek:** záznam, který doputoval do cílového úložiště validní a úplný.
Ne „job doběhl".

```python
SUBJECTS = ["extract", "transform", "load"]
BLOCK_HOURS = 4               # dávky chodí po hodinách, kratší okno je šum

def fetch(subject, start, end):
    r = warehouse.query("""
        SELECT stage, outcome, COUNT(*) AS n FROM etl_audit
        WHERE ts >= %s AND ts < %s AND stage = %s
        GROUP BY stage, outcome
    """, (start, end, subject))
    m = {row["outcome"]: row["n"] for row in r}
    return {"ok": m.get("loaded", 0),
            "rejected": m.get("schema_mismatch", 0),
            "error": m.get("failed", 0)}
```

Tři subjekty místo jednoho jsou tu záměr: díky nim `triage.sh` rovnou ukáže,
**ve které vrstvě** se to zlomilo, aniž by se musel volat model (§10).

**Mantinely:**

- zdrojové systémy jsou read-only, i když do nich technicky zapsat jde
- schéma cílové tabulky se nemění bez souhlasu — závisí na něm reporty
- backfill je samostatný change contract, ne vedlejší efekt opravy

**Co si spletete za poruchu:**

| Vypadá jako | Ve skutečnosti |
|---|---|
| nula záznamů v neděli | zdroj dávky o víkendu neposílá |
| skok o 300 % | backfill, ne růst — a zkreslí baseline na týdny |
| „všechno failuje" | jeden odstavec se změněným formátem, zbytek běží |
| pipeline zelená, dat nula | job doběhl s prázdným vstupem a nikdo to nekontroluje |

Ten poslední řádek je přesně §2: úspěšný běh není zpracovaná data.

---

## 3. CI/CD a build farma

**Výsledek:** build, který prošel a je nasaditelný. Ne „pipeline zelená".

```python
SUBJECTS = ["build", "test", "deploy"]
BLOCK_HOURS = 4
ANOMALY_RATIO = 0.10
DEGRADED_RATIO = 0.40         # ve firmě s málo commity je rozptyl větší

def fetch(subject, start, end):
    runs = ci_api.list_runs(stage=subject, since=start, until=end)
    return {"ok":       sum(1 for r in runs if r.conclusion == "success"),
            "rejected": sum(1 for r in runs if r.conclusion == "failure"),
            "error":    sum(1 for r in runs if r.conclusion in ("timed_out", "cancelled"))}
```

**Mantinely:**

- agent nikdy nemění branch protection ani required checks
- neretryuje cizí buildy — cizí selhání je informace, ne úloha
- secrets a runner tokeny nečte

**Co si spletete za poruchu:**

| Vypadá jako | Ve skutečnosti |
|---|---|
| nula buildů | nikdo necommitoval — u malého týmu normální stav |
| chybovost 100 % | jeden vývojář nahrál rozbitou větev a opakuje pokusy |
| build trvá 3× déle | studená cache po úklidu, ne regrese |
| „deploy prošel" | prošel do staging; produkce běží pořád starou verzi (§15) |

**Užitečný detail:** v CI je `NO_DATA` běžný a legitimní stav. Šablona ho proto
odlišuje od `ANOMALY` — nula buildů v noci není porucha, ale nula buildů
v úterý v deset dopoledne je.

---

## 4. SaaS API

**Výsledek:** obsloužený požadavek, který zákazníkovi vrátil užitečnou odpověď.
Ne HTTP 200.

```python
SUBJECTS = ["api", "webhooky", "fronta"]
BLOCK_HOURS = 1

def fetch(subject, start, end):
    if subject == "api":
        m = metrics.range(f'sum by (status) (rate(http_requests_total[1m]))', start, end)
        ok  = sum(v for s, v in m.items() if s.startswith("2"))
        rej = sum(v for s, v in m.items() if s.startswith("4"))
        err = sum(v for s, v in m.items() if s.startswith("5"))
        return {"ok": round(ok), "rejected": round(rej), "error": round(err)}
    ...
```

**Pozor na past:** `2xx` samo o sobě není výsledek. Když endpoint vrátí `200`
s prázdným polem, protože upstream mlčí, metrika je zelená a zákazník nemá nic.
To je **měkké selhání** z tabulky v §19 a stojí za to ho měřit zvlášť — třeba
podílem odpovědí s prázdným tělem.

**Mantinely:**

- rate limity a kvóty zákazníků se nemění bez souhlasu (§14 — je to limit
  v produkci)
- agent nikdy nemění autentizaci ani autorizaci
- data jednoho tenanta se nikdy nečtou kvůli diagnostice jiného

**Co si spletete za poruchu:**

| Vypadá jako | Ve skutečnosti |
|---|---|
| nárůst 4xx | jeden zákazník nasadil rozbitého klienta |
| propad provozu v pátek večer | denní i týdenní cyklus dohromady |
| latence vzrostla 5× | jeden pomalý tenant, ne systém |
| „API je dole" | health endpoint chodí, ale závislost mlčí (§19) |

---

## Co je společné

Ať děláte cokoli, tyhle čtyři kroky jsou vždycky stejné:

**1. Pojmenujte výsledek v jednotkách, které mají cenu.** Když se metrika nedá
převést na peníze nebo aspoň na „tohle by zákazníka naštvalo", je to metrika
stroje, ne výsledku.

**2. Změřte si vlastní práh.** Postup je v §8: 30 dní historie, okna stejné
délky, poměr k mediánu stejného bloku denní doby, práh na percentilu.
Nepřebírejte čísla z těchto příkladů — jsou ilustrativní.

**3. Napište doménovou sémantiku (§7).** Které stavy jsou dočasné, které
terminální, co je záměrný skip. Bez toho hlásí každý zdravý systém katastrofu.

**4. Vyplňte `falsified_by` u každého zjištění.** Nejlevnější obrana proti
falešnému poplachu je otázka „co by tenhle závěr vyvrátilo" položená dřív,
než se poplach dostane k člověku.

---

## Jak si ověřit, že je to nastavené správně

```bash
python3 checks/outcome.py            # projde? vrací čísla, ne prázdno?
python3 checks/outcome.py --quiet    # jeden řádek — tohle uvidí cron
./triage.sh --line                   # ~30 tokenů, tohle běží každý cyklus
./triage.sh --brief                  # co dostane model, když je co řešit
```

Dva testy, které odhalí většinu chyb v nastavení:

**Test slepého měřidla.** Dočasně nasměrujte `fetch()` na okno, o kterém víte,
že v něm systém pracoval. Když vrátí nulu, měříte špatnou věc — a to je horší
než neměřit nic (§3).

**Test falešného poplachu.** Pusťte check proti třiceti dnům historie
a spočítejte, kolik dnů by označil za `ANOMALY`. Když jich je víc než pár
procent, máte moc přísný práh a agent bude chodit budit člověka pro nic.
