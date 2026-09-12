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

install_docker() {
    log "Systempakete werden geprüft"
    apt-get update
    apt-get install -y ca-certificates curl kmod openssl tar

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
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "http://127.0.0.1:8090/api/v1/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

volumes:
  asiphone-data:
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
    if ! docker volume inspect asiphone_asiphone-data >/dev/null 2>&1; then
        return
    fi
    PREVIOUS_IMAGE=$(docker inspect --format '{{.Image}}' asiphone 2>/dev/null || true)
    [[ -n "${PREVIOUS_IMAGE}" ]] || return

    install -d -m 0700 "${BACKUP_ROOT}"
    local backup
    backup="${BACKUP_ROOT}/pre-update-$(date +%Y%m%d-%H%M%S).tgz"
    log "Vorhandene Kundendaten werden gesichert"
    docker run --rm --entrypoint /bin/tar \
        -v asiphone_asiphone-data:/source:ro \
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
    printf '\nWebkonfiguration:  http://%s:8090\n' "${address}"
    if [[ "${NEW_INSTALL}" == true ]]; then
        printf 'Erstes Admin-Kennwort: %s\n' "${INITIAL_PASSWORD}"
        printf '\nBitte das Kennwort sicher aufbewahren und nach der Anmeldung ändern.\n'
    else
        printf 'Admin-Kennwort und sämtliche Kundendaten wurden beibehalten.\n'
    fi
    printf '\nNach der WireGuard-Einrichtung muss UDP 51820 am Router weitergeleitet werden.\n'
}

install_docker
pull_server_image
create_configuration
backup_existing_data
install_runtime_files
configure_firewall
start_asiphone
show_result
