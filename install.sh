#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALL_ROOT="/opt/asiphone"
readonly CONFIG_ROOT="/etc/asiphone"
readonly BACKUP_ROOT="/var/backups/asiphone"
readonly SERVICE_NAME="asiphone.service"
readonly DEFAULT_IMAGE_REPOSITORY="ghcr.io/stefanjust79/asiphone-server"

IMAGE_TAG="${ASIPHONE_VERSION:-main}"
SERVER_IMAGE="${ASIPHONE_IMAGE:-${DEFAULT_IMAGE_REPOSITORY}:${IMAGE_TAG}}"
CHECK_ONLY=false
NEW_INSTALL=false
INITIAL_PASSWORD=""
PREVIOUS_IMAGE=""
INSTALLED_VERSION=""

usage() {
    cat <<'EOF'
ASIPhone Server installieren oder aktualisieren

Verwendung:
  sudo bash asiphone.sh [--version VERSION] [--check]

Optionen:
  --version VERSION  Serverversion installieren (Standard: main)
  --image IMAGE      Alternatives Containerabbild verwenden
  --check            Voraussetzungen prüfen, nichts verändern
  --help             Diese Hilfe anzeigen
EOF
}

log() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

success() {
    printf '\033[1;32m%s\033[0m\n' "$*"
}

fail() {
    printf '\033[1;31mFehler: %s\033[0m\n' "$*" >&2
    exit 1
}

on_error() {
    printf '\n\033[1;31mDie Installation wurde in Zeile %s abgebrochen.\033[0m\n' "$1" >&2
    printf 'Vorhandene ASIPhone-Kundendaten wurden nicht gelöscht.\n' >&2
}

trap 'on_error "$LINENO"' ERR

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "Nach --version fehlt die Versionsnummer."
            IMAGE_TAG="$2"
            SERVER_IMAGE="${DEFAULT_IMAGE_REPOSITORY}:${IMAGE_TAG}"
            shift 2
            ;;
        --image)
            [[ $# -ge 2 ]] || fail "Nach --image fehlt der Abbildname."
            SERVER_IMAGE="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unbekannte Option: $1"
            ;;
    esac
done

[[ "${EUID}" -eq 0 ]] || fail "Bitte mit sudo ausführen."
[[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Ungültige Versionsnummer."
[[ "${SERVER_IMAGE}" =~ ^[A-Za-z0-9./:_-]+$ ]] || fail "Ungültiger Abbildname."
[[ -r /etc/os-release ]] || fail "Die Linux-Distribution konnte nicht erkannt werden."

# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *) fail "Unterstützt werden derzeit Debian und Ubuntu." ;;
esac

case "$(dpkg --print-architecture 2>/dev/null || true)" in
    amd64|arm64) ;;
    *) fail "Unterstützt werden derzeit x86-64 und ARM64." ;;
esac

command -v systemctl >/dev/null 2>&1 || fail "systemd wird benötigt."
[[ -d /proc/sys/net ]] || fail "Die Linux-Netzwerkfunktionen sind nicht verfügbar."

available_kib=$(df -Pk / | awk 'NR == 2 {print $4}')
if [[ -n "${available_kib}" && "${available_kib}" -lt 6291456 ]]; then
    fail "Mindestens 6 GB freier Speicher werden benötigt."
fi

if [[ "${CHECK_ONLY}" == true ]]; then
    success "Der Server erfüllt die grundlegenden Voraussetzungen für ASIPhone."
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /run/lock
exec 9>/run/lock/asiphone-update.lock
flock -n 9 || fail "Ein ASIPhone-Update läuft bereits. Bitte später erneut versuchen."
[[ ! -f /var/lib/asiphone-updater/journal.json ]] || fail "Ein unterbrochenes Update muss zuerst vom Update-Dienst wiederhergestellt werden."

install_docker() {
    log "Systempakete werden geprüft"
    apt-get update
    apt-get install -y ca-certificates curl kmod openssl tar python3 tzdata

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log "Vorhandene Docker-Installation wird verwendet"
        systemctl enable --now docker
    else
        log "Docker Engine wird aus dem offiziellen Paketarchiv eingerichtet"
        apt-get install -y gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl --proto '=https' --tlsv1.2 -fsSL \
            "https://download.docker.com/linux/${ID}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local suite architecture
        suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
        architecture=$(dpkg --print-architecture)
        [[ -n "${suite}" ]] || fail "Die Distributionsversion konnte nicht ermittelt werden."

        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${ID}
Suites: ${suite}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        apt-get update
        apt-get install -y \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
    fi

    docker compose version >/dev/null
    if [[ ! -c /dev/net/tun ]]; then
        modprobe tun || fail "Das TUN-Netzwerkmodul für WireGuard konnte nicht geladen werden."
    fi
    [[ -c /dev/net/tun ]] || fail "/dev/net/tun ist für WireGuard nicht verfügbar."
}

pull_server_image() {
    log "ASIPhone Serverabbild ${SERVER_IMAGE} wird geladen"
    docker pull "${SERVER_IMAGE}"
}

set_env_value() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    fi
}

create_configuration() {
    install -d -m 0750 "${CONFIG_ROOT}"
    local environment_file="${CONFIG_ROOT}/asiphone.env"
    if [[ ! -f "${environment_file}" ]]; then
        NEW_INSTALL=true
        INITIAL_PASSWORD=$(openssl rand -hex 16)
        umask 077
        cat > "${environment_file}" <<EOF
TZ=Europe/Vienna
ASIPHONE_LOG_LEVEL=INFO
ASIPHONE_HTTP_PORT=8090
ASIPHONE_HTTP_HOST=0.0.0.0
ASIPHONE_HTTPS_ENABLED=true
ASIPHONE_DATA_DIR=/data
ASIPHONE_LOCAL_PKI_DIR=/data/pki
ASIPHONE_AGFEO_HOST=
ASIPHONE_AGFEO_PORT=80
ASIPHONE_AGFEO_SIP_PORT=5060
ASIPHONE_ALLOW_PUBLIC_PBX=false
ASIPHONE_CREDENTIAL_KEY_FILE=/data/secrets/credential_vault.key
ASIPHONE_AGFEO_REFRESH_SECONDS=5
ASIPHONE_AGFEO_PHONEBOOK_REFRESH_SECONDS=300
ASIPHONE_ASTERISK_AUTOSTART=true
ASIPHONE_ASTERISK_CONFIG_DIR=/run/asiphone/asterisk
ASIPHONE_PUBLIC_HOST=
ASIPHONE_ADMIN_TOKEN=${INITIAL_PASSWORD}
ASIPHONE_APNS_KEY_FILE=/data/secrets/AuthKey.p8
ASIPHONE_APNS_KEY_ID=
ASIPHONE_APNS_TEAM_ID=
ASIPHONE_APNS_TOPIC=at.justnet.asiphone.voip
ASIPHONE_APNS_ENVIRONMENT=production
ASIPHONE_PUSH_RELAY_TOKEN_FILE=/data/secrets/push-relay.token
ASIPHONE_PUSH_RELAY_CLIENT_ID_FILE=/data/secrets/push-relay-client-id
ASIPHONE_WIREGUARD_ENABLED=true
ASIPHONE_WIREGUARD_INTERFACE=wg-asiphone
ASIPHONE_WIREGUARD_PORT=51820
ASIPHONE_WIREGUARD_SUBNET=10.77.0.0/24
ASIPHONE_WIREGUARD_PRIVATE_KEY_FILE=/data/secrets/wireguard_private.key
ASIPHONE_SERVER_IMAGE=${SERVER_IMAGE}
EOF
    else
        set_env_value "${environment_file}" ASIPHONE_SERVER_IMAGE "${SERVER_IMAGE}"
        set_env_value "${environment_file}" ASIPHONE_HTTPS_ENABLED "true"
        set_env_value "${environment_file}" ASIPHONE_LOCAL_PKI_DIR "/data/pki"
    fi
    chmod 0600 "${environment_file}"
}

install_runtime_files() {
    install -d -m 0755 "${INSTALL_ROOT}"
    install -d -m 0700 /var/lib/asiphone-updater /var/lib/asiphone-updater/requests /var/lib/asiphone-updater/status
    cat > "${INSTALL_ROOT}/compose.yaml" <<'EOF'
name: asiphone

services:
  asiphone:
    image: ${ASIPHONE_SERVER_IMAGE}
    container_name: asiphone
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    env_file:
      - .env
    volumes:
      - asiphone-data:/data
      - asiphone-backup:/backup
      - /var/lib/asiphone-updater/requests:/updates/requests
      - /var/lib/asiphone-updater/status:/updates/status:ro
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "http://127.0.0.1:8090/api/v1/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

volumes:
  asiphone-data:
    name: ${ASIPHONE_DATA_VOLUME:-asiphone_asiphone-data}
  asiphone-backup:
EOF
    ln -sfn "${CONFIG_ROOT}/asiphone.env" "${INSTALL_ROOT}/.env"

    cat > "/etc/systemd/system/${SERVICE_NAME}" <<'EOF'
[Unit]
Description=ASIPhone Kommunikationsdienst
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/asiphone
ExecStart=/usr/bin/docker compose --project-directory /opt/asiphone up -d --remove-orphans
ExecStop=/usr/bin/docker compose --project-directory /opt/asiphone stop
TimeoutStartSec=0
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${INSTALL_ROOT}/compose.yaml" "/etc/systemd/system/${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    docker compose --project-directory "${INSTALL_ROOT}" config --quiet
}

backup_existing_data() {
    local data_volume
    data_volume=$(sed -n 's/^ASIPHONE_DATA_VOLUME=//p' "${CONFIG_ROOT}/asiphone.env" | tail -n 1)
    data_volume="${data_volume:-asiphone_asiphone-data}"
    [[ "${data_volume}" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "Ungültige Datenablage."
    if ! docker volume inspect "${data_volume}" >/dev/null 2>&1; then
        return
    fi
    PREVIOUS_IMAGE=$(docker inspect --format '{{.Image}}' asiphone 2>/dev/null || true)
    [[ -n "${PREVIOUS_IMAGE}" ]] || return

    install -d -m 0700 "${BACKUP_ROOT}"
    local backup
    backup="${BACKUP_ROOT}/pre-update-$(date +%Y%m%d-%H%M%S).tgz"
    log "Vorhandene Kundendaten werden gesichert"
    docker run --rm --entrypoint /bin/tar \
        -v "${data_volume}:/source:ro" \
        "${PREVIOUS_IMAGE}" -czf - -C /source . > "${backup}"
    chmod 0600 "${backup}"
}

rollback_image() {
    [[ -n "${PREVIOUS_IMAGE}" ]] || return
    printf '\nVorheriges Serverabbild wird wiederhergestellt.\n' >&2
    docker image tag "${PREVIOUS_IMAGE}" "${SERVER_IMAGE}" || true
    systemctl restart "${SERVICE_NAME}" || true
}

start_asiphone() {
    log "ASIPhone wird gestartet"
    if ! systemctl restart "${SERVICE_NAME}"; then
        rollback_image
        fail "Der ASIPhone-Dienst konnte nicht gestartet werden."
    fi

    local port ready=false
    port=$(sed -n 's/^ASIPHONE_HTTP_PORT=//p' "${CONFIG_ROOT}/asiphone.env" | tail -n 1)
    port="${port:-8090}"
    for _ in $(seq 1 45); do
        if curl -fsS "http://127.0.0.1:${port}/api/v1/health" >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 2
    done
    if [[ "${ready}" != true ]]; then
        docker compose --project-directory "${INSTALL_ROOT}" logs --tail=100 || true
        rollback_image
        fail "ASIPhone hat den Bereitschaftstest nicht bestanden."
    fi
    # Read the running image, not a possibly stale installer version label.
    INSTALLED_VERSION=$(docker exec asiphone python -c 'from app import __version__; print(__version__)')
    [[ -n "${INSTALLED_VERSION}" ]] || fail "Die gestartete Serverversion konnte nicht bestätigt werden."
}

configure_firewall() {
    if ! command -v ufw >/dev/null 2>&1 || ! ufw status | grep -q '^Status: active'; then
        return
    fi
    log "ASIPhone-Regeln werden in der aktiven Firewall eingerichtet"
    for subnet in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        ufw allow from "${subnet}" to any port 8090 proto tcp comment 'ASIPhone Verwaltung' >/dev/null
    done
    ufw allow 51820/udp comment 'ASIPhone WireGuard' >/dev/null
    ufw allow in on wg-asiphone to any port 443 proto tcp comment 'ASIPhone App' >/dev/null
    ufw allow in on wg-asiphone to any port 5061 proto tcp comment 'ASIPhone SIP' >/dev/null
    ufw allow in on wg-asiphone to any port 20000:20100 proto udp comment 'ASIPhone Audio' >/dev/null
}

show_result() {
    local address
    address=$(hostname -I 2>/dev/null | awk '{print $1}')
    address="${address:-SERVER-IP}"
    printf '\n'
    success "ASIPhone wurde erfolgreich installiert."
    printf 'Gestartete Serverversion: %s\n' "${INSTALLED_VERSION}"
    printf '\nWebkonfiguration:  http://%s:8090\n' "${address}"
    if [[ "${NEW_INSTALL}" == true ]]; then
        printf 'Erstes Admin-Kennwort: %s\n' "${INITIAL_PASSWORD}"
        printf '\nBitte das Kennwort sicher aufbewahren und nach der Anmeldung ändern.\n'
    else
        printf 'Admin-Kennwort und sämtliche Kundendaten wurden beibehalten.\n'
    fi
    printf '\nNach der WireGuard-Einrichtung muss UDP 51820 am Router weitergeleitet werden.\n'
}

# BEGIN GENERATED UPDATER
install_update_service() {
    install -d -m 0755 /usr/local/lib/asiphone-updater
    cat > /usr/local/lib/asiphone-updater/update_protocol.py <<'ASIPHONE_UPDATE_PROTOCOL'
"""Small, shared protocol for the web app and the privileged host updater."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

DEFAULT_SCHEDULE = {"enabled": False, "time": "03:00", "day": -1, "timezone": "Europe/Vienna"}
BUSY_PHASES = {"checking", "downloading", "backing_up", "starting", "rolling_back"}


def validate_schedule(value):
    if not isinstance(value, dict) or set(value) != set(DEFAULT_SCHEDULE):
        raise ValueError("Bitte einen vollständigen Update-Zeitplan angeben.")
    if type(value["enabled"]) is not bool or type(value["day"]) is not int or not -1 <= value["day"] <= 6:
        raise ValueError("Ungültiger Update-Rhythmus.")
    if not isinstance(value["time"], str) or not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", value["time"]):
        raise ValueError("Die Uhrzeit muss zwischen 00:00 und 23:59 liegen.")
    if not isinstance(value["timezone"], str) or not 1 <= len(value["timezone"]) <= 64:
        raise ValueError("Ungültige Zeitzone.")
    try:
        ZoneInfo(value["timezone"])
    except (ZoneInfoNotFoundError, ValueError):
        raise ValueError("Unbekannte Zeitzone.") from None
    return dict(value)


def due_slot(schedule, now: datetime, previous: str | None):
    """30-minute start window; no late catch-up or double run at DST fallback."""
    schedule = validate_schedule(schedule)
    if not schedule["enabled"]:
        return None
    zone = ZoneInfo(schedule["timezone"])
    local = now.astimezone(zone)
    # Include yesterday for a 23:xx window extending past midnight.
    for date in (local.date(), local.date() - timedelta(days=1)):
        if schedule["day"] != -1 and date.weekday() != schedule["day"]:
            continue
        hour, minute = map(int, schedule["time"].split(":"))
        wall = datetime(date.year, date.month, date.day, hour, minute, tzinfo=zone)
        start = wall.astimezone(timezone.utc)
        # Nonexistent spring-forward times are skipped, not shifted silently.
        if start.astimezone(zone).replace(tzinfo=None) != wall.replace(tzinfo=None):
            continue
        slot = date.isoformat()  # At most one scheduled attempt per local date.
        if slot != previous and start <= now.astimezone(timezone.utc) < start + timedelta(minutes=30):
            return slot
    return None


def read_json(path: Path, default=None):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except FileNotFoundError:
        return default
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Update-Steuerdatei ist keine reguläre Datei.")
        text = stream.read(65537)
    if len(text) > 65536:
        raise ValueError("Update-Steuerdatei ist zu groß.")
    return json.loads(text)


def atomic_json(path: Path, value):
    fd, name = tempfile.mkstemp(prefix=".update-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        if os.name == "posix":
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)
ASIPHONE_UPDATE_PROTOCOL
    cat > /usr/local/lib/asiphone-updater/asiphone-updater.py <<'ASIPHONE_UPDATE_WORKER'
#!/usr/bin/env python3
"""Host-only updater. No Docker socket or arbitrary commands are exposed to the web app."""
from __future__ import annotations

from datetime import datetime, timezone
from contextlib import contextmanager
import fcntl
import json
import logging
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid

from update_protocol import DEFAULT_SCHEDULE, BUSY_PHASES, atomic_json, due_slot, read_json, validate_schedule

IMAGE = "ghcr.io/stefanjust79/asiphone-server:main"
ROOT = Path("/var/lib/asiphone-updater")
ENV = Path("/etc/asiphone/asiphone.env")
COMPOSE = ["docker", "compose", "--project-directory", "/opt/asiphone"]
LOG = logging.getLogger("asiphone-updater")


@contextmanager
def installation_lock():
    with open("/run/lock/asiphone-update.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


class Updater:
    def __init__(self, root=ROOT, env=ENV, backups=Path("/var/backups/asiphone")):
        self.root, self.env, self.backups = Path(root), Path(env), Path(backups)
        self.state = read_json(self.root / "state.json", {})
        self.view = read_json(self.root / "status/status.json", {})
        self.view_lock = threading.Lock()

    def publish(self, phase=None, message=None, **fields):
        with self.view_lock:
            self.view.update(fields)
            if phase is not None:
                self.view.update(phase=phase, message=message or "", changed_at=time.time())
            self.view.update(protocol=1, check_before_install=True, heartbeat=time.time(), source=IMAGE,
                             handled_request=self.state.get("last_request"))
            atomic_json(self.root / "status/status.json", self.view)

    def save_state(self):
        atomic_json(self.root / "state.json", self.state)

    def run(self, args, timeout=120):
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            # Command output is for root-only journal diagnostics, not the public status.
            LOG.error("Command failed (%s): %s", args[0], result.stderr[-2000:])
            raise RuntimeError("Ein Update-Schritt ist fehlgeschlagen. Details stehen im Systemprotokoll.")
        return result.stdout.strip()

    def env_values(self):
        return dict(line.split("=", 1) for line in self.env.read_text().splitlines()
                    if "=" in line and not line.lstrip().startswith("#"))

    def set_runtime(self, image, volume):
        if not re.fullmatch(r"[A-Za-z0-9./:@_-]+", image) or not re.fullmatch(r"[A-Za-z0-9_.-]+", volume):
            raise ValueError("Ungültige lokale Laufzeitkonfiguration.")
        replacements = {"ASIPHONE_SERVER_IMAGE": image, "ASIPHONE_DATA_VOLUME": volume}
        lines = []
        for line in self.env.read_text().splitlines():
            key = line.split("=", 1)[0]
            if key not in replacements:
                lines.append(line)
        lines.extend(key + "=" + value for key, value in replacements.items())
        fd, name = tempfile.mkstemp(dir=self.env.parent, prefix=".update-env-")
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write("\n".join(lines) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(name, self.env)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def active_calls(self):
        output = self.run(["docker", "exec", "asiphone", "asterisk", "-rx", "core show channels count"], timeout=15)
        match = re.search(r"(?m)^\s*(\d+) active channels?\s*$", output)
        if match is None:
            raise RuntimeError("Der Gesprächsstatus konnte nicht sicher ermittelt werden. Update nicht gestartet.")
        return int(match[1])

    def wait_healthy(self):
        port = int(self.env_values().get("ASIPHONE_HTTP_PORT", "8090"))
        if not 1 <= port <= 65535:
            raise ValueError("Ungültiger Verwaltungsport.")
        for _ in range(60):
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/api/v1/health" % port, timeout=3) as response:
                    if json.load(response).get("status") == "ok":
                        return True
            except (OSError, ValueError):
                pass
            time.sleep(2)
        return False

    def recover(self):
        journal = read_json(self.root / "journal.json")
        if not journal:
            return
        if journal.get("committed"):
            (self.root / "journal.json").unlink()
            self.publish("success", "Der letzte Versionswechsel wurde erfolgreich abgeschlossen.", finished_at=time.time())
            return
        self.publish("rolling_back", "Vorherige Version und bisheriger Datenbestand werden wiederhergestellt.")
        self.run(COMPOSE + ["stop"], timeout=150)
        self.set_runtime(journal["old_image"], journal["old_volume"])
        self.run(COMPOSE + ["up", "-d", "--force-recreate", "--pull", "never"], timeout=180)
        if not self.wait_healthy():
            raise RuntimeError("Auch die vorherige Version ist nicht erreichbar. Die ursprünglichen Daten bleiben erhalten; Support erforderlich.")
        (self.root / "journal.json").unlink()
        self.publish("rolled_back", "Das Update wurde zurückgenommen. Die vorherige Version läuft wieder.", finished_at=time.time())

    def check(self):
        self.publish("checking", "Die veröffentlichte Serverversion wird geprüft.", offer=None, update_available=False)
        self.run(["docker", "pull", IMAGE], timeout=1800)
        old = json.loads(self.run(["docker", "inspect", "asiphone"]))[0]
        new = json.loads(self.run(["docker", "image", "inspect", IMAGE]))[0]
        if old["Image"] == new["Id"]:
            self.publish("up_to_date", "Die aktuelle Serverversion ist bereits installiert.", finished_at=time.time())
            return
        digest = next((x for x in new.get("RepoDigests", []) if re.fullmatch(r"ghcr\.io/stefanjust79/asiphone-server@sha256:[a-f0-9]{64}", x)), None)
        if digest is None:
            raise RuntimeError("Das Serverabbild besitzt keine überprüfbare Registry-Kennung.")
        version = self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "python", digest,
                            "-c", "from app import __version__; print(__version__)"], timeout=30)
        offer = {"id": str(uuid.uuid4()), "digest": digest, "version": version, "checked_at": time.time()}
        self.publish("update_available", "Eine neue Serverversion ist verfügbar. Installation erst nach Bestätigung.",
                     offer=offer, update_available=True, finished_at=time.time())

    def update(self, expected_digest=None):
        self.publish("downloading", "Die aktuelle veröffentlichte Serverversion wird heruntergeladen.")
        image = expected_digest or IMAGE
        self.run(["docker", "pull", image], timeout=1800)
        old = json.loads(self.run(["docker", "inspect", "asiphone"]))[0]
        new = json.loads(self.run(["docker", "image", "inspect", image]))[0]
        if old["Image"] == new["Id"]:
            self.publish("up_to_date", "Die aktuelle Serverversion ist bereits installiert.", finished_at=time.time())
            return
        if self.active_calls():
            self.publish("deferred", "Inzwischen läuft ein Gespräch. Das Update wurde ohne Unterbrechung verschoben.", finished_at=time.time())
            return
        mount = next((item for item in old["Mounts"] if item["Destination"] == "/data" and item["Type"] == "volume"), None)
        if not mount or not re.fullmatch(r"[A-Za-z0-9_.-]+", mount["Name"]):
            raise RuntimeError("Diese Datenablage wird vom automatischen Updater nicht unterstützt.")
        digest = next((item for item in new.get("RepoDigests", [])
                       if re.fullmatch(r"ghcr\.io/stefanjust79/asiphone-server@sha256:[a-f0-9]{64}", item)), None)
        if digest is None:
            raise RuntimeError("Das heruntergeladene Serverabbild besitzt keine überprüfbare Registry-Kennung.")
        if expected_digest is not None and digest != expected_digest:
            raise RuntimeError("Das Serverabbild stimmt nicht mit dem bestätigten Update überein.")
        self.backups.mkdir(mode=0o700, parents=True, exist_ok=True)
        size = sum(item.stat().st_size for item in Path(mount["Source"]).rglob("*") if item.is_file() and not item.is_symlink())
        for path in (self.backups, Path(mount["Source"])):
            if shutil.disk_usage(path).free < 2 * size + 1024 ** 3:
                raise RuntimeError("Zu wenig freier Speicher für Datensicherung und Update-Kopie.")
        ident = uuid.uuid4().hex
        old_tag = "asiphone/server:rollback-" + ident
        candidate_volume = "asiphone-data-update-" + ident
        backup_name = "pre-update-" + ident + ".tgz"
        self.run(["docker", "tag", old["Image"], old_tag])
        journal = {"old_image": old_tag, "old_volume": mount["Name"], "new_volume": candidate_volume,
                   "backup": backup_name, "committed": False}
        if self.active_calls():
            self.publish("deferred", "Es läuft ein Gespräch. Kein Versionswechsel durchgeführt.", finished_at=time.time())
            return
        # Persist before stopping anything: recovery also works after host reboot.
        atomic_json(self.root / "journal.json", journal)
        try:
            self.publish("backing_up", "Server wird kurz angehalten und die Daten werden gesichert.")
            self.run(COMPOSE + ["stop"], timeout=150)
            self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "/bin/tar",
                      "-v", mount["Name"] + ":/source:ro", "-v", str(self.backups) + ":/backup",
                      old_tag, "-czf", "/backup/" + backup_name, "-C", "/source", "."], timeout=1800)
            self.run(["docker", "volume", "create", candidate_volume])
            self.run(["docker", "run", "--rm", "--network", "none", "--entrypoint", "/bin/tar",
                      "-v", candidate_volume + ":/target", "-v", str(self.backups) + ":/backup:ro",
                      old_tag, "-xzf", "/backup/" + backup_name, "-C", "/target"], timeout=1800)
            self.set_runtime(digest, candidate_volume)
            self.publish("starting", "Neue Serverversion wird gestartet und geprüft.")
            self.run(COMPOSE + ["up", "-d", "--force-recreate", "--pull", "never"], timeout=180)
            if not self.wait_healthy():
                raise RuntimeError("Die neue Version hat den Bereitschaftstest nicht bestanden.")
            journal["committed"] = True
            atomic_json(self.root / "journal.json", journal)
            (self.root / "journal.json").unlink()
            self.publish("success", "Die neue Serverversion wurde erfolgreich gestartet.",
                         finished_at=time.time(), installed_digest=digest, backup=backup_name, offer=None, update_available=False)
        except Exception:
            LOG.exception("Update failed; restoring previous runtime and original data")
            self.recover()

    def tick(self, now=None):
        now = now or datetime.now(timezone.utc)
        request = read_json(self.root / "requests/request.json", {})
        request_id = request.get("id")
        manual = request_id and request_id != self.state.get("last_request")
        if manual:
            if (not isinstance(request_id, str) or not re.fullmatch(r"[a-f0-9-]{36}", request_id)
                    or type(request.get("created_at")) not in (int, float)):
                raise ValueError("Ungültiger Update-Auftrag.")
            age = now.timestamp() - request["created_at"]
            if not 0 <= age < 3600:
                self.state["last_request"] = request_id
                self.save_state()
                self.publish("expired", "Der manuelle Update-Auftrag ist abgelaufen. Bitte bei Bedarf erneut starten.")
                return
        schedule = validate_schedule(read_json(self.root / "requests/schedule.json", DEFAULT_SCHEDULE))
        slot = due_slot(schedule, now, self.state.get("last_slot"))
        if not manual and not slot:
            if self.view.get("phase") == "waiting_calls":
                self.publish("deferred", "Das Zeitfenster ist abgelaufen. Nächster Versuch zum nächsten geplanten Termin.")
            return
        kind = request.get("kind") if manual else "scheduled"
        if manual and kind not in ("check", "install"):
            raise ValueError("Update-Aufträge benötigen eine Prüfung oder eine bestätigte Installation.")
        expected_digest = None
        if kind == "install":
            offer = self.view.get("offer") or {}
            expected_digest = request.get("digest")
            if (not self.view.get("update_available") or request.get("offer_id") != offer.get("id")
                    or expected_digest != offer.get("digest")
                    or not isinstance(expected_digest, str)
                    or not re.fullmatch(r"ghcr\.io/stefanjust79/asiphone-server@sha256:[a-f0-9]{64}", expected_digest)
                    or not 0 <= time.time() - offer.get("checked_at", 0) < 3600):
                self.state["last_request"] = request_id
                self.save_state()
                self.publish("expired", "Die bestätigte Update-Prüfung ist abgelaufen. Bitte erneut prüfen.")
                return
        if kind != "check" and self.active_calls():
            self.publish("waiting_calls", "Es läuft ein Gespräch. Der Server wartet mit dem Update.")
            return
        if manual:
            self.state["last_request"] = request_id
        if slot:
            self.state["last_slot"] = slot
        self.save_state()  # Failed attempts are not retried endlessly or across restarts.
        self.publish("checking", "Update wird geprüft.", started_at=now.timestamp(), trigger="manual" if manual else "scheduled")
        if kind == "check":
            self.check()
        else:
            self.update(expected_digest)

    def serve(self):
        def heartbeat():
            while True:
                self.publish()
                time.sleep(20)
        threading.Thread(target=heartbeat, daemon=True).start()
        try:
            with installation_lock():
                self.recover()
        except BlockingIOError:
            # The installer owns the lock. systemd retries after it finishes.
            return
        except Exception as exc:
            LOG.exception("Recovery failed")
            self.publish("recovery_failed", str(exc))
            # Do not attempt further updates over an unresolved recovery journal.
            while True:
                time.sleep(60)
        if self.view.get("phase") in BUSY_PHASES:
            self.publish("interrupted", "Update-Dienst ist wieder bereit. Der letzte Versuch wurde unterbrochen; bitte Serverstatus prüfen.")
        if self.view.get("phase") is None:
            self.publish("idle", "Update-Dienst ist bereit.")
        while True:
            try:
                with installation_lock():
                    self.tick()
            except BlockingIOError:
                pass
            except Exception as exc:
                LOG.exception("Update control failed")
                self.publish("failed", str(exc), finished_at=time.time())
                if (self.root / "journal.json").exists():
                    try:
                        with installation_lock():
                            self.recover()
                    except Exception:
                        self.publish("recovery_failed", "Wiederherstellung fehlgeschlagen. Support erforderlich; keine weiteren Updates.")
                        while True:
                            time.sleep(60)
            time.sleep(10)


if __name__ == "__main__":
    os.umask(0o077)
    logging.basicConfig(level=logging.INFO)
    with (ROOT / "worker.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        Updater().serve()
ASIPHONE_UPDATE_WORKER
    cat > /etc/systemd/system/asiphone-updater.service <<'ASIPHONE_UPDATE_UNIT'
[Unit]
Description=ASIPhone Server Updates
Requires=docker.service
After=docker.service network-online.target asiphone.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/asiphone-updater/asiphone-updater.py
Restart=always
RestartSec=15
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ReadWritePaths=/etc/asiphone

[Install]
WantedBy=multi-user.target
ASIPHONE_UPDATE_UNIT
    chmod 0644 /usr/local/lib/asiphone-updater/*.py /etc/systemd/system/asiphone-updater.service
    systemctl daemon-reload
    systemctl enable asiphone-updater.service
    systemctl restart asiphone-updater.service
}
# END GENERATED UPDATER

install_docker
pull_server_image
create_configuration
backup_existing_data
install_runtime_files
configure_firewall
start_asiphone
install_update_service
show_result
