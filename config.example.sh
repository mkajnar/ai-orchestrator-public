#!/usr/bin/env bash
# config.sh — jediné místo, kde se popisuje TVŮJ provoz.
#
# Zkopíruj config.example.sh na config.sh a vyplň. Všechno ostatní ve smyčce
# je doménově neutrální a nemusíš na to sahat.

# ── kde to běží ──────────────────────────────────────────────────────────────
AGENT_USER="${AGENT_USER:-$(id -un)}"      # uživatel, pod kterým běží agent
AGENT_MODEL="${AGENT_MODEL:-opus}"
# SESSION a SOCK se odvozují od názvu adresáře nasazení, takže se dvě kopie
# na jednom stroji nesrazí. Odkomentuj jen když potřebuješ jiné jméno.
# SESSION="muj-agent"
# SOCK="/tmp/muj-agent.sock"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

# ── jak často ────────────────────────────────────────────────────────────────
INTERVAL="${INTERVAL:-14400}"              # spánek mezi cykly (s)
POLL_SEC="${POLL_SEC:-300}"                # jak často se během spánku kontroluje
CLEAR_EVERY="${CLEAR_EVERY:-3}"            # po kolika cyklech vyčistit kontext

# ── kam hlásit ───────────────────────────────────────────────────────────────
NTFY_TOPIC="${NTFY_TOPIC:-}"               # prázdné = notifikace vypnuté

# ── co agent smí ─────────────────────────────────────────────────────────────
# Skill se čte jako SOUBOR (skills/), ne přes Skill tool — šablona tak nezávisí
# na tom, co má uživatel nainstalované, a funguje i s vypnutými slash commandy.
#
# Nástroje, které smyčka nepotřebuje. Vyhozením se zmenší kontext při startu
# (naměřeno: 200 -> 84 nástrojů = vstupní kontext o 43 % menší).
UNUSED_TOOLS="${UNUSED_TOOLS:-CronCreate CronDelete CronList DesignSync EndConversation \
EnterPlanMode ExitPlanMode EnterWorktree ExitWorktree ListMcpResourcesTool Monitor \
NotebookEdit PushNotification ReadMcpResourceTool ReadMcpResourceDirTool RemoteTrigger \
SendMessage ListAgents TaskOutput TaskStop WebFetch WebSearch Workflow ReportFindings \
ScheduleWakeup Artifact Task Skill}"

# MCP konfigurace jen s tím, co agent opravdu potřebuje (nepovinné).
# Bez toho se načtou všechny servery, které má uživatel nastavené.
MCP_CONFIG="${MCP_CONFIG:-}"               # cesta k mcp.json, prázdné = výchozí

# ── repozitáře, do kterých smí agent commitovat (nepovinné) ──────────────────
# Mezerami oddělené absolutní cesty. Prázdné = commituje jen do vlastního.
MANAGED_REPOS="${MANAGED_REPOS:-}"
