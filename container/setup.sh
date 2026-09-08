#!/usr/bin/env bash
#
# VROOM Container-Setup (laeuft IM LXC als root).
# Wird vom Host-Installer via pct exec von $SETUP_URL gezogen.
# Idempotent: kann beliebig oft laufen (Update-Pfad).
#
# Installiert:
#   - Build-Deps + VROOM (Source-Build, Tag $VROOM_VERSION) nach /usr/local/bin/vroom
#   - Node.js ($NODE_MAJOR) + vroom-express ($VROOM_EXPRESS_VERSION) auf 127.0.0.1:$API_PORT
#   - Web-Gateway (reines Node-Core, keine Extra-Deps) auf 0.0.0.0:$WEB_PORT
#   - systemd-Units vroom-api + vroom-web (enable, Restart=always, After=network-online.target)
#
# Debugging (Anforderung #4): bei jedem Fehler volle Kette
#   (Befehl, Exit-Code, Zeile, Stack, stdout/stderr-Hinweis, Journal-Auszuege).

set -euo pipefail

VROOM_VERSION="${VROOM_VERSION:-v1.15.0}"
VROOM_EXPRESS_VERSION="${VROOM_EXPRESS_VERSION:-v0.12.0}"
NODE_MAJOR="${NODE_MAJOR:-20}"
API_PORT="${API_PORT:-3000}"
WEB_PORT="${WEB_PORT:-8080}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

APP_DIR="/opt/vroom"
SRC_DIR="$APP_DIR/src"
EXPRESS_DIR="$APP_DIR/vroom-express"
WEB_DIR="$APP_DIR/web"
LOG_DIR="/var/log/vroom"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()  { printf "${BLU}[vroom-setup]${NC} %s\n" "$*"; }
ok()   { printf "${GRN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[WARN]${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}[FEHLER]${NC} %s\n" "$*" >&2; exit 1; }

error_trap() {
  local ec=$? cmd="${BASH_COMMAND:-?}" line="${BASH_LINENO[0]:-?}"
  printf '\n%s\n' "============================ FEHLER (im LXC) ============================" >&2
  printf 'Befehl    : %s\nExit-Code : %s\nZeile     : %s\n' "$cmd" "$ec" "$line" >&2
  printf 'Env       : VROOM_VERSION=%s EXPRESS=%s NODE=%s API=%s WEB=%s\n' \
    "$VROOM_VERSION" "$VROOM_EXPRESS_VERSION" "$NODE_MAJOR" "$API_PORT" "$WEB_PORT" >&2
  printf 'Stacktrace:\n' >&2
  local i=0
  while caller $i >&2; do i=$((i + 1)); done
  printf '\nRelevante Logs (Auszuege):\n' >&2
  systemctl --no-pager status vroom-api vroom-web 2>&1 | tail -n 40 >&2 || true
  journalctl -u vroom-api --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  journalctl -u vroom-web --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  ls -l /usr/local/bin/vroom "$EXPRESS_DIR/src/index.js" "$WEB_DIR/server.js" 2>&1 >&2 || true
  printf '\nTipp: mit Trace erneut laufen lassen:\n' >&2
  printf '  curl -fsSL "%s" -o /tmp/vroom-setup.sh && bash -x /tmp/vroom-setup.sh\n' "${SETUP_URL:-$0}" >&2
  printf '%s\n' "=========================================================================" >&2
}
trap error_trap ERR

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Benoetigt '$1' im Container."; }

fetch() { # $1=url $2=dest — mit Retry + kompletter Fehlermeldung bei Misserfolg
  local url="$1" dest="$2" out ec
  log "Lade $url -> $dest"
  mkdir -p "$(dirname "$dest")"
  if out=$(retry 3 5 wget -O "$dest" "$url" 2>&1); then
    ok "Geladen: $dest"
  else
    ec=$?
    printf '%s\n' "----- wget stdout/stderr (Exit $ec, nach 3 Versuchen) -----" >&2
    printf '%s\n' "$out" >&2
    printf '%s\n' "------------------------------------------------------------" >&2
    die "Download fehlgeschlagen: $url (Exit $ec). RAW_BASE=$RAW_BASE — Repo schon gepusht?"
  fi
}

run_step() { # $1=Beschreibung $2=Logdatei, Rest=Befehl mit Args
  # Befehl mit Log in Datei; bei Fehler: letzte 40 Zeilen + die().
  # (Direktes "cmd | tail" wuerde im ERR-Trap nur "tail" als Befehl zeigen.)
  local desc="$1" logf="$2"; shift 2
  log "$desc ..."
  if "$@" >"$logf" 2>&1; then
    tail -n 3 "$logf" || true
    return 0
  else
    local ec=$?
    printf '%s\n' "----- letzte 40 Zeilen aus $logf (Exit $ec) -----" >&2
    tail -n 40 "$logf" >&2 || true
    printf '%s\n' "------------------------------------------------" >&2
    die "$desc fehlgeschlagen (Exit $ec). Volles Log: $logf"
  fi
}

pick_cxx() { # gibt C++20-<format>-faehigen Compiler aus (VROOM braucht GCC>=13)
  local cand
  cat > /tmp/vroom-format-probe.cpp <<'EOF'
#include <format>
#include <string>
int main(){ return (int)std::format("v{}", 15).size() == 0; }
EOF
  for cand in g++ g++-14 g++-13 g++-15; do
    if command -v "$cand" >/dev/null 2>&1 \
      && "$cand" -std=c++20 -fsyntax-only /tmp/vroom-format-probe.cpp >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  log "Kein <format>-faehiger Compiler da — versuche g++-14 aus den Paketquellen ..."
  if apt-get install -y gcc-14 g++-14 >/dev/null 2>&1; then
    for cand in g++-14 g++-13 g++ g++-15; do
      if command -v "$cand" >/dev/null 2>&1 \
        && "$cand" -std=c++20 -fsyntax-only /tmp/vroom-format-probe.cpp >/dev/null 2>&1; then
        printf '%s' "$cand"
        return 0
      fi
    done
  fi
  return 1
}

retry() { # $1=Versuche $2=Pause_Sek, Rest=Befehl — gegen wackelige Netze im LXC
  local tries="$1" pause="$2"; shift 2
  local i=1 ec=1
  while [[ "$i" -le "$tries" ]]; do
    if "$@"; then
      return 0
    else
      ec=$?
      if [[ "$i" -lt "$tries" ]]; then
        warn "Versuch $i/$tries fehlgeschlagen (Exit $ec), retry in ${pause}s: $*"
        sleep "$pause"
      fi
    fi
    i=$((i + 1))
  done
  return "$ec"
}

wait_for_http() { # $1=URL $2=Timeout_Sek — wartet auf HTTP 2xx/3xx (langsamer Start)
  local url="$1" timeout="${2:-60}" start now code
  start="$(date +%s)"
  while true; do
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^[23] ]]; then return 0; fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      warn "Timeout ${timeout}s beim Warten auf $url (letzter Code: ${code:-kein Connect})"
      return 1
    fi
    sleep 3
  done
}

ensure_service() { # $1=Unit — enable + restart + warte auf active, sonst Logs + die
  local unit="$1" i state
  systemctl daemon-reload
  systemctl enable "$unit" \
    || die "systemctl enable $unit fehlgeschlagen."
  systemctl restart "$unit" \
    || { systemctl --no-pager status "$unit" 2>&1 | tail -n 30 >&2 || true
         die "$unit startet nicht (restart fehlgeschlagen)."; }
  for ((i = 1; i <= 10; i++)); do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    if [[ "$state" == "active" ]]; then
      ok "$unit ist active."
      return 0
    fi
    sleep 3
  done
  printf '%s\n' "----- systemctl status $unit -----" >&2
  systemctl --no-pager status "$unit" 2>&1 | tail -n 30 >&2 || true
  printf '%s\n' "----- journalctl -u $unit -----" >&2
  journalctl -u "$unit" --no-pager -n 60 2>&1 | tail -n 60 >&2 || true
  die "$unit wurde nicht active (Timeout 30s)."
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Bitte als root im Container ausfuehren."
export DEBIAN_FRONTEND=noninteractive
# pct exec setzt ein minimales PATH ohne /usr/local/bin — dort liegt aber
# unser vroom-Binary. Ohne diese Zeile scheitert 'command -v vroom' (need_cmd),
# obwohl die Datei existiert.
export PATH="/usr/local/bin:$PATH"

# ---------------------------------------------------------------------------
# 1. Basis + Build-Deps (idempotent)
# ---------------------------------------------------------------------------
log "apt update ..."
apt-get update 2>&1 | tail -n 3
run_step "Installiere Basis + Build-Deps" /tmp/vroom-apt.log \
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg git iproute2 procps systemd-sysv \
    build-essential g++ pkg-config libssl-dev libasio-dev libglpk-dev
ok "Basis + Build-Deps vorhanden."

# ---------------------------------------------------------------------------
# 2. Node.js (idempotent, nur wenn fehlend oder Major zu alt)
# ---------------------------------------------------------------------------
NEED_NODE=0
if command -v node >/dev/null 2>&1; then
  NODE_VER="$(node --version 2>/dev/null | sed 's/^v//; s/\..*//' || true)"
  [[ "$NODE_VER" =~ ^[0-9]+$ ]] || NODE_VER=0
  if [[ "$NODE_VER" -lt 18 ]]; then NEED_NODE=1; fi
else
  NEED_NODE=1
fi
if [[ "$NEED_NODE" -eq 1 ]]; then
  mkdir -p /etc/apt/keyrings
  retry 3 5 curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
      -o /tmp/nodesource.gpg.key \
    || die "NodeSource-Key Download fehlgeschlagen (Netz/DNS pruefen)."
  gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg /tmp/nodesource.gpg.key \
    || die "GPG-Keyring schreiben fehlgeschlagen."
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update 2>&1 | tail -n 3
  run_step "Installiere Node.js $NODE_MAJOR" /tmp/vroom-node.log \
    retry 3 10 apt-get install -y nodejs
else
  log "Node bereits vorhanden: $(node --version)"
fi
need_cmd node; need_cmd npm
ok "Node $(node --version) / npm $(npm --version)."

# ---------------------------------------------------------------------------
# 3. VROOM Source-Build (idempotent, Skip wenn Binary vorhanden)
# ---------------------------------------------------------------------------
mkdir -p "$APP_DIR" "$LOG_DIR"
# Versions-Stempel: Rebuild nur bei Versionswechsel oder FORCE_REBUILD=1,
# sonst bleibt ein Re-Run (Update) in Sekunden fertig statt Minuten.
STAMP="$APP_DIR/.installed-vroom-version"
INSTALLED_VER=""
[[ -f "$STAMP" ]] && INSTALLED_VER="$(cat "$STAMP" 2>/dev/null || true)"
if [[ "$FORCE_REBUILD" != "1" ]] && [[ -x /usr/local/bin/vroom ]] && [[ "$INSTALLED_VER" == "$VROOM_VERSION" ]]; then
  log "vroom $INSTALLED_VER bereits installiert, ueberspringe Build: $(/usr/local/bin/vroom --version 2>&1 | head -n 2 || true)"
else
  if [[ -d "$SRC_DIR/.git" ]]; then
    log "Update vroom-Source auf $VROOM_VERSION ..."
    retry 3 10 git -C "$SRC_DIR" fetch --depth 1 origin tag "$VROOM_VERSION" > /tmp/vroom-fetch.log 2>&1 \
      || retry 3 10 git -C "$SRC_DIR" fetch --tags --recurse-submodules > /tmp/vroom-fetch.log 2>&1 \
      || { tail -n 20 /tmp/vroom-fetch.log >&2 || true; die "git fetch vroom fehlgeschlagen (Netz pruefen)."; }
    tail -n 3 /tmp/vroom-fetch.log
    git -C "$SRC_DIR" checkout "$VROOM_VERSION" 2>&1 | tail -n 3
    git -C "$SRC_DIR" submodule update --init --recursive 2>&1 | tail -n 3
  else
    rm -rf "$SRC_DIR"
    run_step "Klone vroom $VROOM_VERSION (mit Submodulen)" /tmp/vroom-clone.log \
      retry 3 10 git clone --branch "$VROOM_VERSION" --recurse-submodules --depth 1 \
        https://github.com/VROOM-Project/vroom.git "$SRC_DIR"
  fi
  CXX_USED="$(pick_cxx)" \
    || die "Kein C++20-<format>-Compiler (GCC>=13) verfuegbar. Distro: $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null || echo unbekannt). Loesung: LXC neu erstellen mit Debian 13 (TEMPLATE=auto): alten CT per 'pct destroy <CTID>' entfernen + Installer erneut laufen lassen."
  log "Compiler: $CXX_USED $("$CXX_USED" --version | head -n 1)"
  # clean zuerst: alte .o-Dateien eines frueheren (GCC-12-)Builds duerfen
  # nicht mit neuem Compiler gemischt gelinkt werden.
  run_step "Bereinige alte Build-Artefakte" /tmp/vroom-clean.log \
    make -C "$SRC_DIR/src" clean
  run_step "Baue vroom mit $CXX_USED ($(nproc) Threads, dauert wenige Minuten)" /tmp/vroom-build.log \
    make -C "$SRC_DIR/src" -j"$(nproc)" "CXX=$CXX_USED"
  [[ -x "$SRC_DIR/bin/vroom" ]] || die "Build fertig, aber $SRC_DIR/bin/vroom fehlt."
  cp "$SRC_DIR/bin/vroom" /usr/local/bin/vroom
  chmod +x /usr/local/bin/vroom
  printf '%s' "$VROOM_VERSION" > "$STAMP"
  ok "vroom gebaut: $(/usr/local/bin/vroom --version 2>&1 | head -n 2 || true)"
fi
need_cmd vroom

# ---------------------------------------------------------------------------
# 4. vroom-express (idempotent)
# ---------------------------------------------------------------------------
if [[ -d "$EXPRESS_DIR/.git" ]]; then
  log "Update vroom-express auf $VROOM_EXPRESS_VERSION ..."
  retry 3 10 git -C "$EXPRESS_DIR" fetch --depth 1 origin tag "$VROOM_EXPRESS_VERSION" > /tmp/vroom-express-fetch.log 2>&1 \
    || retry 3 10 git -C "$EXPRESS_DIR" fetch --tags > /tmp/vroom-express-fetch.log 2>&1 \
    || { tail -n 20 /tmp/vroom-express-fetch.log >&2 || true; die "git fetch vroom-express fehlgeschlagen."; }
  tail -n 3 /tmp/vroom-express-fetch.log
  git -C "$EXPRESS_DIR" checkout "$VROOM_EXPRESS_VERSION" 2>&1 | tail -n 3
else
  rm -rf "$EXPRESS_DIR"
  run_step "Klone vroom-express $VROOM_EXPRESS_VERSION" /tmp/vroom-express-clone.log \
    retry 3 10 git clone --branch "$VROOM_EXPRESS_VERSION" --depth 1 \
      https://github.com/VROOM-Project/vroom-express.git "$EXPRESS_DIR"
fi
# --ignore-scripts ist Pflicht: sonst laeuft das dev-only 'prepare' (husky install)
# auch mit --omit=dev und bricht den Install mit Exit 127 ab, obwohl alle
# Prod-Deps (reines JS: express, helmet, morgan, ...) schon installiert sind.
# --no-audit/--no-fund: weniger Registry-Roundtrips = weniger Flakiness.
run_step "npm install vroom-express" /tmp/vroom-npm.log \
  retry 2 10 npm --prefix "$EXPRESS_DIR" install --omit=dev --ignore-scripts --no-audit --no-fund
[[ -f "$EXPRESS_DIR/src/index.js" ]] || die "vroom-express unvollstaendig: $EXPRESS_DIR/src/index.js fehlt."
ok "vroom-express bereit."

# Healthcheck-Input im v1.15-Format: Upstream-v0.12.0 nutzt noch das alte
# Top-Level-"matrix"-Format, das vroom >= 1.9 ablehnt -> /health lieferte HTTP 500.
# (Muss NACH git checkout stehen, der die Upstream-Datei zurueckholt.)
fetch "$RAW_BASE/container/healthchecks/vroom_custom_matrix.json" \
  "$EXPRESS_DIR/healthchecks/vroom_custom_matrix.json"
# Sofort validieren: vroom muss code 0 liefern — sonst gaebe es spaeter nur
# opakes HTTP 500 statt einer klaren Fehlermeldung.
VROOM_PRE_OUT="$(/usr/local/bin/vroom -i "$EXPRESS_DIR/healthchecks/vroom_custom_matrix.json" 2>&1)" \
  || die "vroom scheitert am Health-Input. Ausgabe: $VROOM_PRE_OUT"
echo "$VROOM_PRE_OUT" | grep -q '"code":0' \
  || die "vroom-Health-Input unerwartet (kein code 0): $VROOM_PRE_OUT"
ok "Health-Input validiert (vroom code 0)."

# config.yml: NUR cliArgs-Port anpassen (Rest = Upstream-Defaults).
# WICHTIG: 0,/.../ adressiert nur das ERSTE port:-Vorkommen (cliArgs) —
# ein globales s/// wuerde auch die routingServers-Ports (5000/5001/...) zerschiesen.
# logdir wird NICHT angefasst: config.js konkateniert __dirname + logdir, daher muss
# der Logpfad absolut ueber Env VROOM_LOG kommen (siehe vroom-api.service).
log "Schreibe $EXPRESS_DIR/config.yml (Port $API_PORT) ..."
fetch "$RAW_BASE/container/config.yml" "$EXPRESS_DIR/config.yml"
sed -i "0,/^[[:space:]]*port:[[:space:]]*[0-9]/s/port:[[:space:]]*[0-9]\+/port: $API_PORT/" "$EXPRESS_DIR/config.yml"
grep -E "port:|logdir:|router:" "$EXPRESS_DIR/config.yml" | head -n 8 || true

# ---------------------------------------------------------------------------
# 5. Web-Gateway + Beispiel + systemd-Units aus dem Repo
# ---------------------------------------------------------------------------
fetch "$RAW_BASE/container/web/server.js" "$WEB_DIR/server.js"
fetch "$RAW_BASE/container/web/public/index.html" "$WEB_DIR/public/index.html"
fetch "$RAW_BASE/container/example-matrix.json" "$APP_DIR/example-matrix.json"
fetch "$RAW_BASE/container/vroom-api.service" /etc/systemd/system/vroom-api.service
fetch "$RAW_BASE/container/vroom-web.service" /etc/systemd/system/vroom-web.service
node --check "$WEB_DIR/server.js" || die "Syntaxfehler in $WEB_DIR/server.js (node --check)."

# Platzhalter in Units ersetzen (__API_PORT__ / __WEB_PORT__)
sed -i "s/__API_PORT__/$API_PORT/g; s/__WEB_PORT__/$WEB_PORT/g" \
  /etc/systemd/system/vroom-api.service /etc/systemd/system/vroom-web.service
grep -E "ExecStart|Environment" /etc/systemd/system/vroom-api.service /etc/systemd/system/vroom-web.service || true

# ---------------------------------------------------------------------------
# 6. systemd: reboot-sicher (enable + Restart=always + After=network-online.target)
# ---------------------------------------------------------------------------
log "Aktiviere + starte vroom-api + vroom-web (reboot-sicher) ..."
ensure_service vroom-api
ensure_service vroom-web

# ---------------------------------------------------------------------------
# 7. Verifikation (Anforderung #7): Service + HTTP + Solve
# ---------------------------------------------------------------------------
log "Verifiziere ..."
[[ "$(systemctl is-active vroom-api 2>/dev/null)" == "active" ]] \
  || die "vroom-api ist nicht active."
[[ "$(systemctl is-active vroom-web 2>/dev/null)" == "active" ]] \
  || die "vroom-web ist nicht active."

wait_for_http "http://127.0.0.1:${API_PORT}/health" 90 \
  || { printf '%s\n' "----- journalctl -u vroom-api (letzte 30) -----" >&2
       journalctl -u vroom-api --no-pager -n 30 2>&1 | tail -n 30 >&2 || true
       die "API antwortet nicht auf http://127.0.0.1:${API_PORT}/health."; }
ok "API-Health OK (Port $API_PORT)."
wait_for_http "http://127.0.0.1:${WEB_PORT}/health" 60 \
  || die "Web-Gateway antwortet nicht auf http://127.0.0.1:${WEB_PORT}/health — journalctl -u vroom-web pruefen."
wait_for_http "http://127.0.0.1:${WEB_PORT}/" 60 \
  || die "Web-UI antwortet nicht auf http://127.0.0.1:${WEB_PORT}/."
ok "Web-Health + Web-UI OK (Port $WEB_PORT)."

log "Solve-Test (Matrix-Modus, voll lokal, ohne OSRM) ..."
API_OUT="$(curl -fsS -m 60 -H 'Content-Type: application/json' \
  --data @"$APP_DIR/example-matrix.json" "http://127.0.0.1:${API_PORT}/" 2>&1)" \
  || die "Solve via API fehlgeschlagen. Ausgabe: $API_OUT"
echo "$API_OUT" | grep -q '"code":0' || die "Solve-Antwort unerwartet (kein code 0): $API_OUT"
WEB_OUT="$(curl -fsS -m 60 -H 'Content-Type: application/json' \
  --data @"$APP_DIR/example-matrix.json" "http://127.0.0.1:${WEB_PORT}/solve" 2>&1)" \
  || die "Solve via Web-Gateway fehlgeschlagen. Ausgabe: $WEB_OUT"
echo "$WEB_OUT" | grep -q '"code":0' || die "Gateway-Solve-Antwort unerwartet: $WEB_OUT"
ok "Solve-Test OK (code 0 via API + Gateway)."

ss -tlnp | grep -E ":${API_PORT}|:${WEB_PORT}" || warn "ss zeigt Ports nicht (laeuft trotzdem per curl)."

CIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n%s\n' "==================== SETUP FERTIG ===================="
printf 'API    : http://%s:%s/  (GET /health, POST / mit VROOM-JSON)\n' "${CIP:-<LXC-IP>}" "$API_PORT"
printf 'Web UI : http://%s:%s/\n' "${CIP:-<LXC-IP>}" "$WEB_PORT"
printf 'Version: vroom %s | express %s | node %s\n' \
  "$(vroom --version 2>&1 | head -n 1)" "$VROOM_EXPRESS_VERSION" "$(node --version)"
printf 'Reboot : systemctl reboot -> beide Services starten automatisch (enable + onboot)\n'
printf '%s\n' "======================================================="
