#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC2155
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly BAKEDESK_ROOT=${BAKEDESK_ROOT:-/opt/bakedesk}
readonly DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$BAKEDESK_ROOT/deploy}
readonly APP_DIR=${BAKEDESK_APP_DIR:-$BAKEDESK_ROOT/app}
readonly DATA_DIR=${BAKEDESK_DATA_DIR:-$BAKEDESK_ROOT/data}
readonly APP_REPOSITORY=https://github.com/H-R-Bakery/BakeDesk.git

log() {
    printf '[BakeDesk-Pi] %s\n' "$*"
}

die() {
    printf '[BakeDesk-Pi] ERROR: %s\n' "$*" >&2
    exit 1
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die 'Run this script with root privileges, for example: sudo ./setup.sh'
}

check_host() {
    [[ $(uname -s) == Linux ]] || die "Unsupported operating system: $(uname -s). This host must run Linux."
    [[ $(uname -m) == aarch64 ]] || die "Unsupported architecture: $(uname -m). This deployment targets ARM64/aarch64."
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system because /etc/os-release is missing.'
    # shellcheck disable=SC1091
    . /etc/os-release
    local os_id=${ID:-unknown}
    local os_like=${ID_LIKE:-}
    if [[ $os_id != debian && $os_id != raspbian && $os_like != *debian* ]]; then
        die "Unsupported operating system: ${PRETTY_NAME:-$os_id}. Use Debian or Raspberry Pi OS ARM64."
    fi
    [[ -x $(command -v apt-get) ]] || die 'apt-get is required on Debian/Raspberry Pi OS.'
    [[ -n ${VERSION_CODENAME:-} ]] || die 'The OS has no VERSION_CODENAME; cannot safely select the Docker Debian repository.'
    log "Detected ${PRETTY_NAME:-$os_id} on ARM64."
}

configure_hostname() {
    log 'Configuring host name bakedesk.'
    if command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname bakedesk
    else
        printf 'bakedesk\n' > /etc/hostname
        hostname bakedesk
    fi
    if ! grep -Eq '(^|[[:space:]])bakedesk([[:space:]]|$)' /etc/hosts; then
        printf '127.0.1.1 bakedesk\n' >> /etc/hosts
        log 'Added bakedesk to /etc/hosts without changing existing entries.'
    fi
}

install_base_packages() {
    log 'Installing host prerequisites, Avahi, Git, OpenSSL, and CUPS.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        avahi-daemon \
        ca-certificates \
        cups \
        curl \
        git \
        gnupg \
        libnss-mdns \
        openssl
}

install_docker() {
    log 'Configuring Docker`s official Debian apt repository.'
    install -d -m 0755 /etc/apt/keyrings
    curl --fail --silent --show-error --location \
        https://download.docker.com/linux/debian/gpg \
        --output /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable
EOF
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        containerd.io \
        docker-buildx-plugin \
        docker-ce \
        docker-ce-cli \
        docker-compose-plugin
}

enable_services() {
    log 'Enabling Docker, Avahi, and host CUPS.'
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
        systemctl enable --now avahi-daemon
        systemctl enable --now cups
        systemctl is-active --quiet docker || die 'Docker did not become active.'
        systemctl is-active --quiet avahi-daemon || die 'Avahi did not become active.'
        systemctl is-active --quiet cups || die 'CUPS did not become active.'
    else
        log 'systemctl is unavailable; packages were installed but services could not be enabled automatically.'
    fi
}

prepare_directories() {
    log "Preparing persistent directories under $DATA_DIR."
    install -d -o root -g root -m 0755 "$BAKEDESK_ROOT"
    install -d -o root -g root -m 0750 "$DATA_DIR"
    install -d -o root -g root -m 0750 "$DATA_DIR/postgres"
    # The PHP image runs as www-data (UID/GID 33) and needs document storage.
    install -d -o 33 -g 33 -m 0750 "$DATA_DIR/documents"
}

clone_application() {
    if [[ -e $APP_DIR ]]; then
        [[ -d $APP_DIR ]] || die "$APP_DIR exists but is not a directory; refusing to replace it."
        [[ -f $APP_DIR/composer.json && -f $APP_DIR/symfony.lock && -x $APP_DIR/bin/console ]] \
            || die "$APP_DIR exists but does not look like a BakeDesk checkout; refusing to modify it."
        log "Existing BakeDesk checkout found at $APP_DIR; leaving it intact."
        return
    fi
    log "Cloning BakeDesk into $APP_DIR."
    install -d -o root -g root -m 0755 "$(dirname -- "$APP_DIR")"
    git clone "$APP_REPOSITORY" "$APP_DIR"
    log 'BakeDesk was cloned. The deployment image will use this sibling checkout as its build source.'
}

prepare_environment() {
    [[ -f $DEPLOY_DIR/.env.example ]] || die "Missing $DEPLOY_DIR/.env.example. Run setup from the BakeDesk-Pi checkout."
    if [[ ! -f $DEPLOY_DIR/.env ]]; then
        log 'Creating a private deployment environment file from .env.example.'
        cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
        local app_secret postgres_password mercure_secret
        app_secret=$(openssl rand -hex 32)
        postgres_password=$(openssl rand -hex 24)
        mercure_secret=$(openssl rand -hex 32)
        sed -i \
            -e "s|^APP_SECRET=.*|APP_SECRET=$app_secret|" \
            -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" \
            -e "s|^DATABASE_URL=.*|DATABASE_URL=\"postgresql://baker:$postgres_password@database:5432/bakery?serverVersion=18\\&charset=utf8\"|" \
            -e "s|^MERCURE_JWT_SECRET=.*|MERCURE_JWT_SECRET=$mercure_secret|" \
            "$DEPLOY_DIR/.env"
        chmod 0640 "$DEPLOY_DIR/.env"
        if [[ -n ${SUDO_USER:-} ]] && id "$SUDO_USER" >/dev/null 2>&1; then
            chown "$SUDO_USER":root "$DEPLOY_DIR/.env"
        fi
    else
        log "Keeping existing $DEPLOY_DIR/.env."
    fi
}

add_docker_group_membership() {
    local original_user=${SUDO_USER:-}
    if [[ -n $original_user && $original_user != root ]] && id "$original_user" >/dev/null 2>&1; then
        usermod -aG docker "$original_user"
        log "Added $original_user to the docker group. This grants powerful host access; log out and back in before using Docker without sudo."
    fi
}

main() {
    require_root
    check_host
    [[ $SCRIPT_DIR == "$DEPLOY_DIR" ]] || die "Run setup.sh from $DEPLOY_DIR (the expected deployment checkout location)."
    configure_hostname
    install_base_packages
    install_docker
    enable_services
    prepare_directories
    clone_application
    prepare_environment
    add_docker_group_membership
    log 'Bootstrap complete.'
    log 'A reboot may be needed before every process observes the new host name.'
    log "Review $DEPLOY_DIR/.env, then run $DEPLOY_DIR/deploy.sh."
}

main "$@"
