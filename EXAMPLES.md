# EXAMPLES — jeden příběh od průzkumu webu po evidenci v DB

Zadání, na kterém se dá všechno ukázat naráz, protože ho každý zná:

> **Sbíráme inzeráty ze tří typů zdrojů — z aukčního portálu, z inzertních
> bazarů a z e-shopů — a vedeme je v databázi. Chceme vědět, kolik úplných
> záznamů denně přibude a kdy se to zlomí.**

Tři zdroje záměrně: každý se chová jinak, každý se rozbíjí jinak a každý
vyžaduje jinou odpověď na otázku, kterou musíte zodpovědět dřív než cokoli
naprogramujete — **co je tady vlastně výsledek**.

Postup je vždycky stejný a jde v tomhle pořadí:

```
   průzkum webu  →  co je výsledek  →  jak ho změřím  →  prahy z vlastních dat
       část 1            část 2              část 3                část 4
```

---

# 1. Průzkum cílového webu

Tohle je práce pro agenta, ne pro vás. Zadáte mu doménu a on ji má **doložit
změřenými odpověďmi**, ne odhadem. Výstup průzkumu je krátký zápis, ze kterého
se pak píše `fetch()` a mantinely.

Sedm otázek, které musí zodpovědět, každou příkazem, který jde zopakovat:

### 1.1 Existuje pod HTML datové rozhraní?

Nejlevnější nález průzkumu. Většina moderních výpisů se plní z JSON endpointu,
který vrací čistá data — a je stabilnější než HTML, protože se u něj nemění
vzhled.

```bash
# co si stránka sama tahá na pozadí
curl -s "$URL" | grep -oE '"[^"]*/(api|graphql|v[0-9])/[^"]*"' | sort -u | head
```

Když takový endpoint existuje, zbytek průzkumu se dělá na něm.
Pokud ne, průzkum pokračuje na HTML.

### 1.2 Jak vypadá stránkování a kde končí?

Nejde o „kolik je stránek", ale **jestli výpis nemá strop**. Spousta webů
odmítne jít za stránku 50 nebo za 1 000 položek a tiše vrátí prázdno.
To pak vypadá jako vyčerpaný zdroj.

```bash
for p in 1 10 50 100 500; do
  n=$(curl -s "$URL?page=$p" | grep -c "$ITEM_SELECTOR")
  echo "strana $p → $n položek"
done
```

Když od nějaké strany chodí nula, máte strop výpisu. Řešením je rozdělit
dotaz podle kategorie, ceny nebo data — ne zvyšovat číslo strany.

### 1.3 Co znamená autorizace na tomhle webu?

Čtyři možnosti a každá vyžaduje jinou obsluhu:

| Co web vyžaduje | Jak se pozná | Co si drží agent |
|---|---|---|
| nic | detail jde bez cookies | nic |
| jen cookie ze vstupní stránky | první požadavek nastaví `Set-Cookie` | cookie jar |
| přihlášení formulářem | detail redirectuje na `/login` | jar + obnovovací postup |
| token / API klíč | `401` bez hlavičky | tajemství mimo repo (ORCHESTRATOR §23) |

Zjištění je jednoduché — **stejný detail dvakrát, jednou s přihlášením
a jednou bez**:

```bash
curl -s -o /dev/null -w "bez přihlášení: %{http_code}\n" "$DETAIL"
curl -s -o /dev/null -w "s přihlášením: %{http_code}\n" -b cookies.txt "$DETAIL"
```

Když se liší jen počet polí a ne stavový kód, je to ten nejzrádnější případ:
bez přihlášení dostanete `200` a **neúplný záznam**. Viz část 2.

### 1.4 Jak poznám, že session vypršela?

Tohle je nejčastější příčina toho, že sběr přes noc tiše umře.
Přihlášení nevydrží věčně a jeho konec **skoro nikdy nevypadá jako chyba**.

Průzkum musí najít konkrétní signál a zapsat ho:

```python
def session_zije(resp):
    if resp.status_code in (401, 403):        return False
    if "/login" in resp.url:                  return False   # redirect
    if 'name="password"' in resp.text:        return False   # login form pod 200
    if not resp.json().get("items"):          return False   # prázdno pod 200
    return True
```

Ten třetí a čtvrtý řádek jsou ty důležité. `200` s přihlašovacím formulářem
v těle je pořád `200` a každá naivní metrika ho spočítá jako úspěch.

### 1.5 Jak vypadá konec života položky?

Bez téhle odpovědi bude agent donekonečna zkoušet položky, které už neexistují,
a bude to hlásit jako poruchu.

```bash
# vezmi položku, o které víte, že je pryč, a podívejte se, co web vrátí
curl -s -o /dev/null -w "%{http_code} → %{redirect_url}\n" "$MRTVA_POLOZKA"
```

Odpověď bývá jedna z těchhle a **každá znamená něco jiného**:

| Odpověď | Význam | Co s tím |
|---|---|---|
| `404` | položka smazána | terminální, odepsat |
| `410` | položka smazána, web to říká výslovně | terminální, odepsat |
| `500` u aukcí | aukce skončila | **normální konec života**, ne porucha |
| `200` + „inzerát byl ukončen" | totéž, jen slušněji | terminální, ale pozná se jen z obsahu |
| redirect na výpis | položka pryč | terminální |
| `403` / login | dočasně zamčeno | **nikdy neodepisovat trvale** |

Ten poslední řádek je pravidlo, které stálo nejvíc: dočasný zámek vypadá
v logu stejně jako smrt. Když ho odepíšete natrvalo, ztratíte položku, která
se za dva dny vrátí.

### 1.6 Kdy protistrana řekne dost?

Ne kolik požadavků „se sluší" — **co web skutečně odpoví**. Odhad není důkaz
(ORCHESTRATOR §14).

```bash
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "%{http_code} " "$URL"
done; echo
```

Zajímají vás `429`, `403`, náhlé `503` a stránka s ověřením místo obsahu.
Dokud nepřijdou, není co zpomalovat. Až přijdou, řídíte se **tím, co přišlo** —
`Retry-After` má přednost před jakýmkoli vymyšleným intervalem.

### 1.7 Jaká pole detail vůbec má?

Poslední krok průzkumu, a ten určí, co bude znamenat „úplný záznam":

```bash
curl -s "$DETAIL" | python3 -c 'import sys,json;print(sorted(json.load(sys.stdin)))'
```

Rozdělte je na **povinné** (bez nich záznam nemá cenu), **volitelné** a
**odvozené**. Ta hranice je celé měření — viz hned další sekce.

### Co z průzkumu vypadne

Krátký zápis, který je vstup pro všechno ostatní:

```
zdroj:          aukce.example.cz
rozhraní:       JSON /api/v2/items (HTML jen fallback)
stránkování:    strop 100 stran, dělí se podle kategorie
autorizace:     login formulářem, session ~4 h
konec session:  redirect na /login, nebo 200 s name="password"
konec položky:  500 = skončená aukce (normální), 403 = zamčeno (dočasné)
rychlost:       429 od ~8 req/s, Retry-After 30
povinná pole:   id, nazev, cena, kategorie, cas_konce
```

---

# 2. Co je výsledek: úplný záznam, ne stažená stránka

Nejdůležitější rozhodnutí v celé úloze. Nabízí se čtyři metriky a tři z nich
lžou:

| Metrika | Proč nefunguje |
|---|---|
| stažených stránek | stáhnout se dá i chybová hláška |
| HTTP 200 | přihlašovací stránka je taky 200 |
| řádků v DB | uloží se i záznam bez ceny a bez názvu |
| **úplných záznamů v DB** | ← tohle |

„Úplný" definujete vy, podle části 1.7. A hlavně: definujte to **v SQL**, ne
v hlavě, protože se podle toho bude měřit každý cyklus.

```sql
-- co považujeme za výsledek
CREATE VIEW polozky_uplne AS
SELECT * FROM polozky
WHERE nazev IS NOT NULL
  AND cena  IS NOT NULL
  AND kategorie IS NOT NULL
  AND jsonb_array_length(fotky) > 0;
```

Tohle je přímo ORCHESTRATOR §2: *zdraví určují data, ne proces*. Sběr, který
vesele běží a osm hodin ukládá záznamy bez ceny, je rozbitý — i když v logu
není jediná chyba.

---

# 3. Jak to změřit: `checks/outcome.py`

```python
SUBJECTS = ["aukce", "bazary", "obchody"]
BLOCK_HOURS = 4

def fetch(subject, start, end):
    row = db.query_one("""
        SELECT
          COUNT(*) FILTER (WHERE uplny)                     AS ok,
          COUNT(*) FILTER (WHERE NOT uplny AND duvod IS NOT NULL) AS rejected,
          COUNT(*) FILTER (WHERE duvod = 'chyba')           AS error
        FROM sber_audit
        WHERE zdroj = %s AND ts >= %s AND ts < %s
    """, (subject, start, end))
    return {"ok": row.ok, "rejected": row.rejected, "error": row.error}
```

Tři subjekty místo jednoho jsou záměr: `triage.sh` pak rovnou ukáže,
**který zdroj** se zlomil, aniž by se musel volat model (ORCHESTRATOR §10). Když spadne
jen aukční portál, není důvod platit tokeny za analýzu bazarů.

Podstatné je, že `fetch()` se ptá **databáze**, ne crawleru. Kdyby se ptal
procesu, měřili byste znovu proces (ORCHESTRATOR §2).

---

# 4. Prahy, které nesmíte opsat odsud

Postup je v ORCHESTRATOR §8 a je nutné ho projít, protože sběr inzerce má **denní i týdenní
cyklus** — v noci se inzeruje míň a v neděli večer nejvíc.

```sql
-- 30 dní zpět, okna po 4 h, poměr k mediánu stejného bloku denní doby
SELECT blok, percentile_cont(0.05) WITHIN GROUP (ORDER BY pomer) AS p05,
             percentile_cont(0.10) WITHIN GROUP (ORDER BY pomer) AS p10
FROM (…) t GROUP BY blok;
```

Až tohle číslo znáte, je to váš práh. Do té doby žádný práh nemáte —
a check, který rozhoduje podle vymyšleného čísla, je horší než žádný check.

---

# 5. Tři zdroje, tři různé pasti

## 5.1 Aukční portál — položky mizí a to je v pořádku

Aukce žije pár dní. Pak detail zmizí a **to není porucha**. Kdo si tohle
nezapíše do ORCHESTRATOR §7 jako doménovou sémantiku, uvidí v logu lavinu chyb a bude
opravovat něco, co funguje.

**Mantinely:**

- agent nikdy nepřihazuje, nekupuje ani nezasahuje do účtu
- přihlašovací údaje jsou mimo repozitář (ORCHESTRATOR §23) a agent je nečte, jen používá
- zamčená položka se **nikdy** neodepisuje trvale (část 1.5)

| Vypadá jako | Ve skutečnosti |
|---|---|
| lavina `500` na detailech | skončené aukce — normální konec života |
| propad v pondělí ráno | týdenní cyklus, u aukcí extrémní |
| „přestali jsme sbírat" | vypršela session, sběr běží dál naprázdno (část 1.4) |
| 40 % položek zamčeno | vyžadují přihlášení, ne poruchu |

## 5.2 Bazary — inzerát se vrací pořád dokola

Veřejná inzerce většinou nepotřebuje přihlášení, zato je plná duplicit: tentýž
předmět inzerovaný pětkrát, přeposazený po týdnu znovu, s jiným ID.

Klíčové rozhodnutí je **klíč totožnosti**. Ne URL, ne ID zdroje — něco, co
přežije přeposazení:

```sql
ALTER TABLE polozky ADD COLUMN otisk text
  GENERATED ALWAYS AS (md5(lower(nazev) || cena || prodejce)) STORED;
CREATE UNIQUE INDEX ON polozky (zdroj, otisk);
```

**Pozor na časově omezenou deduplikaci.** Když stejný inzerát zahodíte
navždycky, přijdete o legitimní opakování. Když ho neodfiltrujete vůbec,
zaplníte DB šumem. Správná odpověď je **změřená**: jaký podíl opakování po
N dnech přinese nová data. Ne odhad.

| Vypadá jako | Ve skutečnosti |
|---|---|
| skok o 300 % | jeden prodejce nahrál celý sklad |
| nula nových položek | výpis narazil na strop stránkování (část 1.2) |
| „duplicit je 60 %" | správně — bazar je jich plný, otázka je jen jak je poznat |
| propad o víkendu | naopak vrchol; baseline musí být podle bloku denní doby |

## 5.3 E-shopy — cena, která není číslo

Katalog je nejstabilnější ze tří, ale má vlastní zradu: pole, které někdy není
pole. `cena: null` u položky „na dotaz" je legitimní stav, ne chyba parsování —
a když ji zahrnete do povinných polí (část 1.7), zahodíte platné záznamy.

**Mantinely:**

- ceny a dostupnost se **jen čtou**; agent nikdy nic neobjedná ani nevloží
  do košíku
- když e-shop nabízí feed (XML/CSV), používá se feed — je to jeho vlastní
  a schválená cesta k týmž datům

| Vypadá jako | Ve skutečnosti |
|---|---|
| „30 % položek bez ceny" | „cena na dotaz" — legitimní stav |
| katalog se zmenšil o polovinu | sezónní stažení nabídky |
| všechny ceny se změnily naráz | jiná měna nebo DPH v odpovědi, ne skutečná změna |
| feed je prázdný | generuje se v noci; ráno je platný (ORCHESTRATOR §19) |

---

# 6. Když se to rozbije: od symptomu ke kořeni

Modelový průběh podle ORCHESTRATOR §10, na nejčastějším případu — **přes noc přestaly
přibývat úplné záznamy**:

```
symptom     outcome check: ok = 0 od 02:00, error = 0
            (nula chyb je podezřelejší než tisíc chyb)
   ↓
mechanismus proces běží, požadavky odcházejí, odpovědi jsou 200,
            ale v odpovědi je přihlašovací formulář (část 1.4)
   ↓
kořen       session vypršela ve 02:00 a nikdo to nedetekoval,
            protože se měřil stavový kód místo obsahu
   ↓
oprava      session_zije() z části 1.4 + obnovení přihlášení při jeho selhání
   ↓
ověření     ok > 0 v následujícím okně, a záměrně vypršelá session
            v testu vede k obnovení, ne k tichému nulovému sběru
```

Všimněte si, že oprava nesměřuje na sběr, ale **na měření**. To je typické:
kdyby check od začátku hlídal obsah, incident by trval minuty, ne noc.

---

# 7. Jak si ověřit, že je to nastavené správně

```bash
python3 checks/outcome.py            # projde? vrací čísla, ne prázdno?
python3 checks/outcome.py --quiet    # jeden řádek — tohle uvidí cron
./triage.sh --line                   # ~30 tokenů, tohle běží každý cyklus
./triage.sh --brief                  # co dostane model, když je co řešit
```

Tři testy, které odhalí většinu chyb v nastavení:

**Test slepého měřidla.** Nasměrujte `fetch()` na okno, o kterém víte, že
v něm sběr pracoval. Když vrátí nulu, měříte špatnou věc — a to je horší
než neměřit nic (ORCHESTRATOR §3).

**Test falešného poplachu.** Pusťte check proti třiceti dnům historie
a spočítejte, kolik oken by označil za `ANOMALY`. Když jich je víc než pár
procent, je práh moc přísný a agent bude budit člověka pro nic.

**Test vypršelé session.** Smažte cookie jar a nechte proběhnout jeden cyklus.
Správný výsledek je hlášená porucha do minuty. Když check zůstane zelený,
neměříte výsledek — měříte, že program běží.

---

# Co si z toho odnést

**Průzkum je součást úlohy, ne příprava na ni.** Sedm otázek z části 1 se zodpoví
jednou a ušetří většinu pozdějších incidentů — protože skoro každý falešný
poplach je jedna z nich nezodpovězená.

**Výsledek se počítá v datech, která zůstala.** Ne ve stránkách, ne v požadavcích,
ne v návratových kódech.

**Prahy si změřte.** Čísla v tomhle souboru jsou ilustrativní a v jiném provozu
budou jinak.

**`falsified_by` u každého zjištění.** Nejlevnější obrana proti falešnému
poplachu je otázka „co by tenhle závěr vyvrátilo" položená dřív, než se poplach
dostane k člověku.
