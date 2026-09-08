# VROOM lokal auf Proxmox (LXC, Einzeiler)

Repo: `HatchetMan111/VroomVehicleRoutingProxmox` (per Env `GITHUB_USER`/`GITHUB_REPO_NAME`/`GITHUB_BRANCH` überschreibbar).

Lokale Routenoptimierung mit [VROOM](https://github.com/VROOM-Project/vroom) (C++20, `v1.15.0`)
+ [vroom-express](https://github.com/VROOM-Project/vroom-express) (`v0.12.0`, Node 20) als LXC-Container
im Stil der **Proxmox VE Community Scripts**. Keine Cloud nötig: der Matrix-Modus rechnet
vollständig lokal; ein Routing-Server (OSRM/ORS/Valhalla) ist nur für echte lon/lat-Koordinaten optional.

- **Web UI:** `http://<LXC-IP>:8080/` (Gateway, bind `0.0.0.0`, statische UI + Proxy)
- **API:** `http://<LXC-IP>:3000/` (`POST` VROOM-JSON, `GET /health`)
- **Systemd:** `vroom-api` + `vroom-web` (`enable`, `Restart=always`, `After=network-online.target`), Container `onboot: 1`
- **Default-Ressourcen:** 2 vCPU, 2 GB RAM, 8 GB Disk, Debian 12, unprivilegiert

## Einzeiler (Proxmox-Host, als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main/install/vroom.sh)"
```

Mit Env-Overrides (Beispiel):

```bash
CTID=150 CPU=4 RAM=4096 DISK=10 GITHUB_USER=meinuser \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/meinuser/VroomVehicleRoutingProxmox/main/install/vroom.sh)"
```

Bei Fehlern mit Trace (volle Fehlerkette, Anforderung #4):

```bash
bash -x -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main/install/vroom.sh)"
```

Alle Variablen stehen oben in `install/vroom.sh` (`CTID`, `CT_HOSTNAME` (Default `VroomVehicle`),
`CPU`, `RAM`, `DISK`, `STORAGE`, `TEMPLATE` (mit Fallback aufs neueste Debian-12-Template),
`BRIDGE`, `IP_MODE`, `API_PORT`, `WEB_PORT`, `VROOM_VERSION`, …). Container-Name
überschreiben mit z. B. `CT_HOSTNAME=mein-name`.

## Erwartete Ausgabe (Erfolg)

```
[vroom-install] LXC 123 erstellt (onboot=1, nesting=1).
[vroom-setup] vroom gebaut: vroom v1.15.0 ...
[OK] vroom-express bereit.
[OK] Solve-Test OK (code 0 via API + Gateway).
[OK] Services laufen, API + Web UI antworten.

==================== FERTIG ====================
VROOM Web UI : http://192.168.1.123:8080/
VROOM API   : http://192.168.1.123:3000/  (POST JSON, GET /health)
...
```

## Test (im Container / vom Host)

```bash
# Services
pct exec <CTID> -- systemctl is-active vroom-api vroom-web
pct exec <CTID> -- curl -s http://127.0.0.1:3000/health -w " HTTP:%{http_code}\n"
pct exec <CTID> -- curl -s http://127.0.0.1:8080/health
pct exec <CTID> -- curl -s http://127.0.0.1:8080/ -o /dev/null -w "UI HTTP:%{http_code}\n"

# Solve (Matrix, lokal, ohne OSRM)
pct exec <CTID> -- curl -s -H 'Content-Type: application/json' \
  --data @/opt/vroom/example-matrix.json http://127.0.0.1:3000/

# Reboot-Test (Anforderung)
pct reboot <CTID> && sleep 20 && pct exec <CTID> -- systemctl is-active vroom-api vroom-web
curl -s http://<LXC-IP>:8080/health && curl -s http://<LXC-IP>:8080/ -o /dev/null -w "UI HTTP:%{http_code}\n"
```

Browser: `http://<LXC-IP>:8080/` → Beispiel ist vorausgefüllt → **Optimieren** → `"code": 0` + Routen.

`curl` von außen:

```bash
curl -H 'Content-Type: application/json' --data @container/example-matrix.json http://<LXC-IP>:8080/solve
```

## Update / Deinstallation

```bash
# Update (idempotent, gleiche Version oder neue per Env):
VROOM_VERSION=v1.15.0 VROOM_EXPRESS_VERSION=v0.12.0 \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/VroomVehicleRoutingProxmox/main/install/vroom.sh)"

# Rebuild des C++-Binary erzwingen:
pct exec <CTID> -- env FORCE_REBUILD=1 VROOM_VERSION=v1.15.0 bash /tmp/vroom-setup.sh

# Deinstallation:
pct stop <CTID> && pct destroy <CTID>
```

## Struktur

```
install/vroom.sh            # Host-Installer (Community-Scripts-Stil, Variablen oben)
container/setup.sh          # Setup IM LXC (idempotent, volle Fehlerkette)
container/config.yml        # vroom-express Config (Port/Logdir werden gesetzt)
container/example-matrix.json
container/vroom-api.service # systemd API :3000
container/vroom-web.service # systemd Web-Gateway :8080
container/web/server.js     # Gateway (nur Node-Core, Proxy + Static)
container/web/index.html    # Web UI (Beispiel + Solve + Health)
```

## LXC oder VM?

LXC reicht (VROOM ist ein normales C++-Binary, braucht keine Kernel-Module; Threads skalieren
mit `CPU`). Mehr Dampf: `CPU=4 RAM=4096` setzen. Eine VM ist nur sinnvoll bei strikter
Isolation oder eigenem Kernel – dann Debian-12-Cloud-Image per `qm create` aufsetzen und
`container/setup.sh` dort identisch ausführen (Pfad/Ports gleich, `RAW_BASE` zeigt aufs Repo).

## Hinweis zu Routing-Engines

Ohne OSRM/ORS/Valhalla funktionieren: `/health`, Custom-Matrix-Solves (Distanzen/Dauern als
Matrix im JSON, siehe `example-matrix.json`). Für `location: [lon, lat]` einen Router
hosten und in `/opt/vroom/vroom-express/config.yml` (`routingServers`) eintragen, dann
`systemctl restart vroom-api`.
