# Autonomní orchestrátor

Jeden živý agent, který v pravidelném cyklu měří výsledek tvého systému.
Když je co řešit, řeší to. Když ne, mlčí a spí — a to je většina cyklů.

Použitelné na cokoli s měřitelným výsledkem: sběr dat z cizích webů, e-shop,
SaaS, ETL, CI/CD, mikroslužby, dávkové zpracování. Konkrétní nasazení ukazuje **[EXAMPLES.md](EXAMPLES.md)**.

## Proč vzniklo

Agent, kterému řekneš „hlídej mi produkci", tě bude stát jmění a stejně ti ujde
to podstatné. Dělá totiž dvě věci špatně: platíš mu za to, že ti každých pár
minut napíše, že je všechno v pořádku, a když se něco pokazí, hlásí, že proces
běží — místo aby změřil, jestli z něj něco leze.

Tahle šablona řeší obojí:

**Deterministická brána před modelem.** Rozhodnutí „je vůbec co řešit" dělá
skript, ne model. Většina cyklů tak stojí nulu.

**Měří se výsledek, ne proces.** Zelený health check neznamená, že systém
funguje. Zdroj pravdy je vždycky vzniklá data.

## Jak to jede

```
tmux session (živý agent, dá se k němu kdykoli připojit)
   └─ smyčka podle AGENT-LOOP.md:
        1. ./triage.sh --line       deterministicky, ~30 tokenů
        2. ./suppress.sh            vyřízené nálezy model znovu nevolají
        3. brief → diagnóza / oprava → autocommit
        4. ./cycle.sh done          stav na disk
        5. ./wait.sh                TADY SE NESPALUJÍ TOKENY
        6. ./next-cycle.sh &        další pokyn; každý N-tý cyklus i /clear
```

`wait.sh` je běžný tool call — model po celou dobu čeká na jeho výsledek
a nevolá se. Během spánku běží levná kontrola v bashi a probudí agenta dřív
jen **zhoršení** stavu, ne jeho trvání. S otevřenou eskalací se spí dál, jinak
by smyčka nikdy nespala.

## Start

```bash
cp config.example.sh config.sh   # uživatel, interval, notifikace
$EDITOR checks/outcome.py        # doplň, co je tvůj výsledek (TODO)
./run.sh                         # spustí agenta
```

`run.sh` je jediný způsob spuštění a je **bezpodmínečný** — opakované spuštění
znamená zabít všechno a spustit čistě. Na konci ověří, že agent skutečně
odpovídá, a když ne, pokus zopakuje. „Běží to, tak nic nedělám" je totiž přesně
ten stav, kdy session žije, ale nic nepracuje, a nikdo to nepozná.

## Ovládání

```bash
./attach.sh                # živý pohled (odpojení: Ctrl-b pak d)
./attach.sh --tail         # posledních 40 řádků, funguje i bez terminálu
./run.sh --status          # session, procesy, poslední cyklus
./run.sh --stop            # zabije vše a založí STOP
./watchdog.sh              # z cronu po 5 min: hlídá PRÁVĚ JEDNU session
touch state/WAKE           # probudit ze spánku hned
```

| Soubor | Účinek |
|---|---|
| výchozí (nic) | `DIAGNOSE` — agent měří a čte, na produkci nesahá |
| `state/AUTOFIX` | agent smí opravovat, a co změní, se commitne |
| `state/STOP` | agent doběhne cyklus a skončí; watchdog ho nekřísí |

Začni v `DIAGNOSE`. `AUTOFIX` zapni, až uvidíš na pár incidentech, že diagnózy sedí.

## Co je uvnitř

| Soubor | Role |
|---|---|
| `run.sh` | jediný skript na spuštění, vždy čistý restart s ověřením |
| `watchdog.sh` | právě jedna session, restart po pádu, `flock` |
| `AGENT-LOOP.md` | tělo smyčky — co agent dělá v každém cyklu |
| `ORCHESTRATOR.md` | kontrakt: mantinely, prahy, rollback, autonomie |
| `CLAUDE.md` | boot instrukce, které přežijí vyčištění kontextu |
| `EXAMPLES.md` | úloha od průzkumu cizího webu po evidenci v DB |
| `skills/ultrathink-engineer.md` | inženýrská disciplína, kterou agent čte před zásahem do kódu |
| `triage.sh` | brána — hlásí jen to, co existuje |
| `suppress.sh` | vyřízený nález nevolá model znovu |
| `rules` | vydá z kontraktu jen potřebnou sekci |
| `checks/outcome.py` | **šablona** — měří výsledek, na kterém záleží |
| `checks/fleet_snapshot.py` | **šablona** — stav infrastruktury agregovaně |
| `lib/evidence.py` | tvar zjištění: verdikt, doklad, čím se vyvrátí |
| `lib/with_lock.sh` | production lock |
| `lib/autocommit.sh` | commit jen toho, co změnil agent |
| `cycle.sh` `incidents.sh` | stav a incidenty na disku, ne v kontextu |

## Jak agent opravuje

Před každým zásahem do kódu si načte `skills/ultrathink-engineer.md` — první
principy, důkaz místo dojmu, kořenová příčina místo záplaty, nejmenší dostačující
změna a adversarial review vlastního řešení dřív, než ho prohlásí za hotové.

Skill je **soubor v repozitáři**, ne nainstalovaný slash command. Šablona tak
nezávisí na tom, co má uživatel v prostředí, a funguje i s vypnutými skilly
(`config.sh: UNUSED_TOOLS`). Stojí ~3 000 tokenů — proti ceně jedné opravy
zanedbatelné.

## Tři principy

**Agregace patří na hostitele**, kde je zadarmo — ne do kontextu modelu. Log má
tisíce tokenů, ale signál v něm jsou jednotky řádků. Komprimuje se jen to, co je
zdravé; nezdravé se vypisuje jmenovitě, protože zdravý řádek nese nula informace
a stojí stejně jako nemocný.

**Deterministické rozhodnutí se nedělá modelem.** `triage.sh` je brána: když je
vše v normě, model se nespustí vůbec.

**Disciplína patří do dat, ne do promptu.** Každé zjištění (`lib/evidence.py`)
povinně nese: co to je, **čím to dokládám** (příkaz k zopakování), proč (s čísly)
a **co by to vyvrátilo**. To poslední není ozdoba — je to nejlevnější obrana
proti závěru postavenému na špatném měřidle.

Fungovalo to hned při stavbě: první verze `fleet_snapshot` hlásila `ANOMALY`
kvůli dvěma instancím ve stavu Error. Pole `falsified_by` si vynutilo otázku
„co by ten závěr vyvrátilo" — odpověď zněla „existence zdravé náhrady", a ta
existovala. Byly to zbytky po nasazení. Poplach zmizel dřív, než se dostal
k člověku.

## Náklady

Naměřeno na reálném provozu (4h interval, `/clear` po 3 cyklech):

| typ cyklu | tokenů |
|---|---|
| čistý (nic k řešení) | ~28 000 |
| diagnóza bez zásahu | ~150 000 |
| oprava kódu včetně buildu a nasazení | 330 000 – 680 000 |

Většina cyklů je prvního typu. Vypnutí nepotřebných nástrojů a skillů
(`config.sh: UNUSED_TOOLS`) zmenšilo vstupní kontext o 43 % — z 200 nástrojů
na 84.

Dvě věci, které stojí nejvíc a nejsou vidět: **boot session** (systémový prompt,
definice nástrojů, seznam skillů) a **výstupy nástrojů**, které si agent tahá do
kontextu. Na obojí je v šabloně odpověď — `UNUSED_TOOLS` na první,
agregační checky na druhé.

## Co si doplnit

1. `config.sh` — uživatel, interval, notifikace, spravované repozitáře
2. `checks/outcome.py` — funkce `fetch()` a prahy z **vlastního** měření
3. `checks/fleet_snapshot.py` — jména kontejnerů, namespaců, logů, vzory chyb
4. `ORCHESTRATOR.md` — sekce `TODO`: mise, mantinely, doménová sémantika,
   data, cesty nasazení

Prahy nikdy nepřebírej odjinud. Postup, jak je odvodit z vlastní historie, je
v `ORCHESTRATOR.md` §8; rozepsané na konkrétní úloze v `EXAMPLES.md`.

## Licence

MIT.
