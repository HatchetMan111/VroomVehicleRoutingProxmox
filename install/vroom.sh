#!/usr/bin/env bash
#
# VROOM LXC One-Shot Installer im Stil der Proxmox VE Community Scripts.
#
# Einzeiler (auf dem Proxmox-Host als root):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main/install/vroom.sh)"
# Mit Debug-Log bei Fehlern:
#   bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main/install/vroom.sh)"
#
# Was das Script tut:
#   1. Erstellt einen LXC-Container (CT-ID wählbar, Default: naechste freie ID)
#   2. Baut VROOM v1.15.0 aus Source + installiert vroom-express v0.12.0 (Node 20) im Container
#   3. Richtet Web-Gateway (UI auf 8080) + API (3000) als systemd-Services ein
#      (enable, Restart=always, After=network-online.target)
#   4. Setzt onboot: 1, verifiziert Services + HTTP und gibt finale URLs aus
#
# Idempotent: erneut laufen lassen updated statt neu zu installieren.
# Lokal: Matrix-Modus funktioniert ohne externe Routing-Engine / Cloud.
#        OSRM/ORS/Valhalla optional per config.yml dazu.
#
# License: MIT | Stil-Vorbild: https://github.com/community-scripts/ProxmoxVE
# Upstream: https://github.com/VROOM-Project/vroom | https://github.com/VROOM-Project/vroom-express

set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, alle per ENV ueberschreibbar, z. B. CTID=150 bash .../vroom.sh)
# ---------------------------------------------------------------------------
APP="${APP:-vroom}"                                     # App-Name
APP_HUMAN="${APP_HUMAN:-VROOM}"                         # Anzeigename
VROOM_VERSION="${VROOM_VERSION:-v1.15.0}"               # vroom Git-Tag (Source-Build)
VROOM_EXPRESS_VERSION="${VROOM_EXPRESS_VERSION:-v0.12.0}" # vroom-express Git-Tag
NODE_MAJOR="${NODE_MAJOR:-20}"                          # Node.js Major-Version
API_PORT="${API_PORT:-3000}"                            # vroom-express API-Port
WEB_PORT="${WEB_PORT:-8080}"                            # Web-UI-Gateway-Port

CTID="${CTID:-}"                                        # leer = naechste freie ID (pvesh)
# HINWEIS: bewusst CT_HOSTNAME (nicht HOSTNAME) — $HOSTNAME ist in bash immer
# schon gesetzt (System-Hostname) und wuerde sonst den CT-Namen ueberschreiben.
CT_HOSTNAME="${CT_HOSTNAME:-VroomVehicle}"
CPU="${CPU:-2}"                                         # VROOM skaliert mit Threads; 2 = guter Default
RAM="${RAM:-2048}"                                      # MiB
SWAP="${SWAP:-512}"                                     # MiB
DISK="${DISK:-8}"                                       # GB (Source-Build braucht ~2 GB temporaer)
STORAGE="${STORAGE:-local-lvm}"                         # Container-Storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"           # Template-Storage
# "auto" = neuestes debian-13-Template, sonst neuestes ubuntu-24.04.
# Hintergrund: VROOM >= 1.15 braucht GCC >= 13 (C++20 <format>); Debian 12
# (GCC 12) kann es NICHT bauen. Expliziter Name = exakt dieser wird verwendet.
TEMPLATE="${TEMPLATE:-auto}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_MODE="${IP_MODE:-dhcp}"                              # "dhcp" oder statisch "192.168.1.50/24"
GATEWAY="${GATEWAY:-}"                                  # nur bei statischer IP noetig
NAMESERVER="${NAMESERVER:-1.1.1.1}"
PASSWORD="${PASSWORD:-}"                                # leer = kein Passwort (nur Keys/Root-Ticket)
SSH_KEYS="${SSH_KEYS:-}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
ONBOOT="${ONBOOT:-1}"
START_ON_CREATE="${START_ON_CREATE:-1}"

# GitHub-first: alles Weitere wird im Container von hier gezogen.
GITHUB_USER="${GITHUB_USER:-HatchetMan111}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-VroomVehicleRoutingProxmox}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO_NAME}/${GITHUB_BRANCH}}"
SETUP_URL="${SETUP_URL:-${RAW_BASE}/container/setup.sh}"
INSTALL_URL="${INSTALL_URL:-${RAW_BASE}/install/vroom.sh}"

# ---------------------------------------------------------------------------
# Helpers: Farben, Logging, komplette Fehlerkette (Anforderung #4)
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLU}[vroom-install]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[WARN]${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}[FEHLER]${NC} %s\n" "$*" >&2; exit 1; }

# Volle Fehlerkette: Befehl, Exit-Code, Zeile, Stack, Log-Hinweise.
error_trap() {
  local ec=$? cmd="${BASH_COMMAND:-?}" line="${BASH_LINENO[0]:-?}"
  printf '\n%s\n' "================================ FEHLER ==================================" >&2
  printf 'Befehl    : %s\nExit-Code : %s\nZeile     : %s\n' "$cmd" "$ec" "$line" >&2
  printf 'Stacktrace:\n' >&2
  local i=0
  while caller $i >&2; do i=$((i + 1)); done
  printf '\nRelevante Logs (Host):\n' >&2
  printf '  pct status %s; pct config %s\n' "${CTID:-?}" "${CTID:-?}" >&2
  printf '  pct exec %s -- systemctl status vroom-api vroom-web --no-pager\n' "${CTID:-?}" >&2
  printf '  pct exec %s -- journalctl -u vroom-api --no-pager -n 100\n' "${CTID:-?}" >&2
  printf '  pct exec %s -- journalctl -u vroom-web --no-pager -n 100\n' "${CTID:-?}" >&2
  printf '\nTipp: erneut mit bash -x starten fuer ein volles Trace-Log:\n' >&2
  printf '  bash -x -c "$(wget -qLO - %s)"\n' "$INSTALL_URL" >&2
  printf '%s\n' "============================================================================" >&2
}
trap error_trap ERR

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benoetigt '$1' auf dem Proxmox-Host (als root ausfuehren)."; }

next_id() { pvesh get /cluster/nextid; }

ct_ip() { # $1=ctid -> erste IPv4 via pct exec
  local ctid="$1" ip=""
  ip=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  printf '%s' "$ip"
}

wait_for_ct() { # wartet bis pct exec geht (sagt NICHTS ueber Container-Netz!)
  local ctid="$1" tries=30
  for ((i = 1; i <= tries; i++)); do
    if pct exec "$ctid" -- true >/dev/null 2>&1; then return 0; fi
    sleep 5
  done
  die "Container $ctid antwortet nicht auf 'pct exec' (Timeout ~150s)."
}

wait_for_net() { # wartet bis der CT wirklich ins Netz kommt (DNS + HTTPS)
  # pct exec funktioniert per lxc-attach auch OHNE Container-Netz — deshalb
  # reicht wait_for_ct nicht: der Setup-Download waere der erste Netz-Zugriff.
  local ctid="$1" tries="${WAIT_TRIES:-18}" pause="${WAIT_SLEEP:-5}" i
  log "Warte auf CT-Netz (DNS/HTTPS, max ~$((tries * (pause + 10)))s) ..."
  for ((i = 1; i <= tries; i++)); do
    if pct exec "$ctid" -- wget -q --timeout=10 --tries=1 --spider "$SETUP_URL" >/dev/null 2>&1; then
      ok "CT-Netz bereit (Versuch $i/$tries)."
      return 0
    fi
    sleep "$pause"
  done
  # Kein Netz nach ~4,5 Min: Diagnose direkt einsammeln (alle Befehle mit
  # || true, damit die Diagnose selbst nie den Trap ausloest).
  printf '%s\n' "----- Netzwerk-Diagnose aus CT $ctid -----" >&2
  printf '%s\n' "$ pct exec $ctid -- ip -4 addr show eth0" >&2
  pct exec "$ctid" -- ip -4 addr show eth0 2>&1 | tail -n 10 >&2 || true
  printf '%s\n' "$ pct exec $ctid -- ip route" >&2
  pct exec "$ctid" -- ip route 2>&1 | tail -n 10 >&2 || true
  printf '%s\n' "$ pct exec $ctid -- cat /etc/resolv.conf" >&2
  pct exec "$ctid" -- cat /etc/resolv.conf 2>&1 | tail -n 10 >&2 || true
  printf '%s\n' "$ pct exec $ctid -- getent hosts raw.githubusercontent.com" >&2
  pct exec "$ctid" -- getent hosts raw.githubusercontent.com 2>&1 | tail -n 5 >&2 || true
  printf '%s\n' "$ pct exec $ctid -- ping -c1 -W3 8.8.8.8  (L3 ohne DNS)" >&2
  pct exec "$ctid" -- ping -c1 -W3 8.8.8.8 2>&1 | tail -n 5 >&2 || true
  printf '%s\n' "$ pct config $ctid | grep -i net" >&2
  pct config "$ctid" 2>/dev/null | grep -i net >&2 || true
  printf '%s\n' "------------------------------------------" >&2
  die "Container $ctid kommt nicht ins Netz (wget --spider $SETUP_URL schlug ${tries}x fehl). Deutung: kein ping -> Route/Firewall/DHCP (pct config pruefen); ping OK aber getent leer -> DNS (resolv.conf). Oder reconnect: Einzeiler erneut laufen lassen."
}

ct_curl() { # $1=ctid $2=url — curl im CT mit Retry + letzte Ausgabe bei Misserfolg
  local ctid="$1" url="$2" i out
  for ((i = 1; i <= 5; i++)); do
    if out=$(pct exec "$ctid" -- curl -fsS -m 10 "$url" -o /dev/null 2>&1); then
      return 0
    fi
    sleep 5
  done
  printf '%s\n' "----- letzter curl-Versuch im CT $ctid ($url, nach 5 Versuchen) -----" >&2
  printf '%s\n' "$out" >&2
  printf '%s\n' "---------------------------------------------------------------------" >&2
  return 1
}

# ---------------------------------------------------------------------------
# 0. Preflight (muss auf dem Proxmox-Host als root laufen)
# ---------------------------------------------------------------------------
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausfuehren."
need_cmd pct; need_cmd pvesm; need_cmd wget
[[ -d /etc/pve ]] || die "Kein Proxmox-Host erkannt (/etc/pve fehlt). Script auf dem Proxmox-Host ausfuehren."

if [[ -z "$GITHUB_USER" || "$GITHUB_USER" == "DEIN_GITHUB_USER" ]]; then
  warn "GITHUB_USER ist leer oder noch Platzhalter. Setze z. B.: GITHUB_USER=deinname bash .../vroom.sh"
  warn "Fahre trotzdem fort (Setup-Download wird erst mit echtem Repo klappen)."
  GITHUB_USER="HatchetMan111"
fi

if [[ -z "$CTID" ]]; then
  CTID="$(next_id | tr -d '"[:space:]')"
  log "Keine CTID vorgegeben -> nutze naechste freie ID: $CTID"
fi
[[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID muss numerisch sein (bekommen: '$CTID'). Beispiel: CTID=150 ..."
[[ "$CT_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
  || die "CT_HOSTNAME ungueltig: '$CT_HOSTNAME' (erlaubt: Buchstaben, Ziffern, Bindestrich)."

if pct status "$CTID" >/dev/null 2>&1; then
  log "Container $CTID existiert bereits -> idempotenter Update-Pfad."
  CT_EXISTS=1
else
  CT_EXISTS=0
fi

# ---------------------------------------------------------------------------
# 1. Template sicherstellen + LXC erstellen (nur wenn neu)
# ---------------------------------------------------------------------------
# Loest TEMPLATE="auto" auf: neuestes debian-13, sonst neuestes
# ubuntu-24.04 (beide haben GCC>=13). Debian 12 ist absichtlich NICHT dabei.
resolve_auto_template() {
  local avail cand pat
  avail="$(pveam available --section system 2>/dev/null || true)"
  for pat in 'debian-13-standard_[^[:space:]]*amd64\.tar\.zst' \
             'ubuntu-24\.04-standard_[^[:space:]]*amd64\.tar\.zst'; do
    cand="$(printf '%s\n' "$avail" | grep -oE "$pat" | sort -V | tail -n 1 || true)"
    if [[ -n "$cand" ]]; then
      TEMPLATE="$cand"
      log "Auto-Template: $TEMPLATE"
      return 0
    fi
  done
  die "Kein debian-13- oder ubuntu-24.04-Template verfuegbar (VROOM braucht GCC>=13). Siehe: pveam available --section system"
}

# Stellt sicher, dass TEMPLATE lokal vorliegt (mit Fallback bei altem Pin).
ensure_template() {
  if [[ "$TEMPLATE" == "auto" ]]; then
    resolve_auto_template
  fi
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    log "Template $TEMPLATE bereits auf $TEMPLATE_STORAGE vorhanden."
    return 0
  fi
  log "Aktualisiere Template-Liste ..."
  pveam update || warn "pveam update meldete Fehler, versuche Download trotzdem."
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    return 0
  fi
  if pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" 2>/dev/null; then
    ok "Template $TEMPLATE geladen."
    return 0
  fi
  warn "Template $TEMPLATE nicht verfuegbar -> suche neuestes debian-13-Standard-Template."
  local newest=""
  newest="$(pveam available --section system 2>/dev/null \
    | grep -oE 'debian-13-standard_[^[:space:]]*amd64\.tar\.zst' \
    | sort -V | tail -n 1 || true)"
  [[ -n "$newest" ]] || die "Kein debian-13-Template gefunden. Siehe: pveam available --section system"
  TEMPLATE="$newest"
  log "Nutze stattdessen: $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" \
    || die "Template-Download fehlgeschlagen ($TEMPLATE)."
  ok "Template $TEMPLATE geladen."
}

if [[ "$CT_EXISTS" -eq 0 ]]; then
  ensure_template
  # Debian <= 12 hat nur GCC <= 12 und kann VROOM >= 1.15 nicht bauen.
  # Frueh abbrechen statt 10 Minuten spaeter im Compiler-Fehler zu landen.
  # (Escape Hatch: ALLOW_OLD_TEMPLATE=1, z. B. fuer aeltere VROOM_VERSION.)
  if [[ "${ALLOW_OLD_TEMPLATE:-0}" != "1" ]] \
    && [[ "$TEMPLATE" == debian-1[12]-* || "$TEMPLATE" == debian-1[01]-* \
          || "$TEMPLATE" == ubuntu-2[02].04-* ]]; then
    die "TEMPLATE=$TEMPLATE ist zu alt (VROOM $VROOM_VERSION braucht GCC>=13, C++20 <format>). Nutze TEMPLATE=auto (Debian 13 / Ubuntu 24.04)."
  fi

  NET="name=eth0,bridge=${BRIDGE}"
  if [[ "$IP_MODE" == "dhcp" ]]; then
    NET="${NET},ip=dhcp"
  else
    [[ -n "$GATEWAY" ]] || die "Statische IP gewaehlt (IP_MODE=$IP_MODE) aber GATEWAY ist leer."
    NET="${NET},ip=${IP_MODE},gw=${GATEWAY}"
  fi

  FEATURES="nesting=1,keyctl=1"
  # Optionale Args nur bei Bedarf anhängen. WICHTIG: leere Arrays duerfen
  # NICHT als "${ARR[@]:-}" expandiert werden — das erzeugt je ein leeres
  # Argument ("") und pct create bricht mit "400 too many arguments" ab.
  # Das :+-Idiom expandiert zu null Argumenten, wenn das Array leer ist.
  EXTRA_ARGS=()
  [[ -n "$PASSWORD" ]] && EXTRA_ARGS+=(--password "$PASSWORD")
  [[ -n "$SSH_KEYS" ]] && EXTRA_ARGS+=(--ssh-public-keys "$SSH_KEYS")

  log "Erstelle LXC $CTID ($CT_HOSTNAME): cpu=$CPU ram=${RAM}MB disk=${DISK}G ..."
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CPU" --memory "$RAM" --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "$NET" --nameserver "$NAMESERVER" \
    --features "$FEATURES" \
    --unprivileged "$UNPRIVILEGED" \
    --onboot "$ONBOOT" \
    --start "$START_ON_CREATE" \
    "${EXTRA_ARGS[@]:+"${EXTRA_ARGS[@]}"}" \
    || die "pct create fehlgeschlagen (siehe Ausgabe oben + pct config)."

  pct set "$CTID" --onboot "$ONBOOT" || warn "pct set --onboot schlug fehl."
  ok "LXC $CTID erstellt (onboot=$ONBOOT, nesting=1)."
else
  pct set "$CTID" --onboot "$ONBOOT" || warn "pct set --onboot schlug fehl."
  if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
    log "Starte bestehenden Container $CTID ..."
    pct start "$CTID" || die "pct start $CTID fehlgeschlagen."
  fi
fi

wait_for_ct "$CTID"
wait_for_net "$CTID"

# ---------------------------------------------------------------------------
# 2. Setup im Container (GitHub-first: setup.sh wird von RAW_BASE gezogen)
# ---------------------------------------------------------------------------
log "Installiere/Update ${APP_HUMAN} in LXC $CTID (API :$API_PORT, UI :$WEB_PORT, $VROOM_VERSION) ..."
pct exec "$CTID" -- bash -euo pipefail <<EOF
export DEBIAN_FRONTEND=noninteractive
export VROOM_VERSION="$VROOM_VERSION"
export VROOM_EXPRESS_VERSION="$VROOM_EXPRESS_VERSION"
export NODE_MAJOR="$NODE_MAJOR"
export API_PORT="$API_PORT"
export WEB_PORT="$WEB_PORT"
export RAW_BASE="$RAW_BASE"
export SETUP_URL="$SETUP_URL"
echo "[in-lxc] Lade Setup: \$SETUP_URL"
DL_OK=0
for DL_TRY in 1 2 3; do
  if wget -q --timeout=20 --tries=2 -O /tmp/vroom-setup.sh "\$SETUP_URL"; then DL_OK=1; break; fi
  echo "[in-lxc] Download-Versuch \$DL_TRY/3 fehlgeschlagen, retry in 5s ..." >&2
  sleep 5
done
if [[ "\$DL_OK" != "1" ]]; then
  echo "[in-lxc] FEHLER: Setup-Download fehlgeschlagen von \$SETUP_URL" >&2
  echo "[in-lxc] Pruefe DNS/Netz im Container: getent hosts raw.githubusercontent.com; ip route" >&2
  exit 1
fi
chmod +x /tmp/vroom-setup.sh
bash /tmp/vroom-setup.sh
EOF
ok "Setup im Container abgeschlossen."

# ---------------------------------------------------------------------------
# 3. Verifikation vom Host aus (Anforderung #7)
# ---------------------------------------------------------------------------
log "Verifiziere Services + Web UI ..."
pct exec "$CTID" -- systemctl is-active vroom-api \
  || die "vroom-api ist nicht active (pct exec $CTID -- journalctl -u vroom-api -n 100)."
pct exec "$CTID" -- systemctl is-active vroom-web \
  || die "vroom-web ist nicht active (pct exec $CTID -- journalctl -u vroom-web -n 100)."
ct_curl "$CTID" "http://127.0.0.1:${API_PORT}/health" \
  || die "API-Healthcheck fehlgeschlagen (curl localhost:${API_PORT}/health im Container)."
ct_curl "$CTID" "http://127.0.0.1:${WEB_PORT}/health" \
  || die "Web-Healthcheck fehlgeschlagen (curl localhost:${WEB_PORT}/health im Container)."
ct_curl "$CTID" "http://127.0.0.1:${WEB_PORT}/" \
  || die "Web-UI antwortet nicht (curl localhost:${WEB_PORT}/ im Container)."
ok "Services laufen, API + Web UI antworten."

CIP="$(ct_ip "$CTID")"
if [[ -z "$CIP" ]]; then
  warn "Container-IP konnte nicht gelesen werden (pct exec hostname -I leer). Siehe 'pct config $CTID'."
  CIP="<LXC-IP>"
fi

printf '\n%s\n' "==================== FERTIG ===================="
printf '%s Web UI : http://%s:%s/\n' "$APP_HUMAN" "$CIP" "$WEB_PORT"
printf '%s API   : http://%s:%s/  (POST JSON, GET /health)\n' "$APP_HUMAN" "$CIP" "$API_PORT"
printf 'Container : CT %s (%s), onboot=%s\n' "$CTID" "$CT_HOSTNAME" "$ONBOOT"
printf 'Test lokal im Container:\n'
printf '  pct exec %s -- curl -s http://127.0.0.1:%s/health -w " HTTP:%%{http_code}\\n"\n' "$CTID" "$API_PORT"
printf 'Update : Script erneut laufen lassen (idempotent)\n'
printf 'Reboot : pct reboot %s -> danach beide URLs erneut erreichbar\n' "$CTID"
printf '%s\n' "=================================================="
