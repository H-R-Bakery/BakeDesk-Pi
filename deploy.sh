#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
APP_DIR=${BAKEDESK_APP_DIR:-$(cd -- "$DEPLOY_DIR/../app" && pwd)}

# shellcheck source=scripts/env.sh
source "$SCRIPT_DIR/scripts/env.sh"
# shellcheck source=scripts/timers.sh
source "$SCRIPT_DIR/scripts/timers.sh"

log() {
    printf '[BakeDesk-Pi] %s\n' "$*"
}

die() {
    printf '[BakeDesk-Pi] ERROR: %s\n' "$*" >&2
    exit 1
}

require_root_for_zerotier() {
    [[ ${EUID} -eq 0 ]] || die 'ZeroTier membership requires root privileges; run this script with sudo, for example: sudo ./deploy.sh'
}

read_zerotier_network_id() {
    ZEROTIER_NETWORK_ID=''
    if env_read "$DEPLOY_DIR/.env" ZEROTIER_NETWORK_ID; then
        ZEROTIER_NETWORK_ID=$ENV_VALUE
    fi
}

verify_zerotier_network_id() {
    read_zerotier_network_id
    [[ -n $ZEROTIER_NETWORK_ID ]] \
        || die "ZEROTIER_NETWORK_ID is not configured in $DEPLOY_DIR/.env. Set the ZeroTier network ID before running deploy.sh."
    [[ $ZEROTIER_NETWORK_ID =~ ^[0-9A-Fa-f]{16}$ ]] \
        || die "Invalid ZEROTIER_NETWORK_ID in $DEPLOY_DIR/.env. Expected exactly 16 hexadecimal characters."
    ZEROTIER_NETWORK_ID=${ZEROTIER_NETWORK_ID,,}
}

zerotier_network_is_joined() {
    local networks=$1
    awk -v network_id="$ZEROTIER_NETWORK_ID" \
        '$1 == "200" && $2 == "listnetworks" && $3 == network_id {found=1} END {exit !found}' \
        <<<"$networks"
}

configure_zerotier() {
    require_root_for_zerotier
    verify_zerotier_network_id
    command -v zerotier-cli >/dev/null 2>&1 \
        || die 'zerotier-cli is unavailable. Run sudo ./setup.sh first.'
    command -v systemctl >/dev/null 2>&1 \
        || die 'systemctl is unavailable; run this on the supported systemd host after sudo ./setup.sh.'
    systemctl is-active --quiet zerotier-one \
        || die 'zerotier-one is not active. Run sudo ./setup.sh and check: systemctl status zerotier-one'

    local networks network_line network_status node_info node_id
    networks=$(zerotier-cli listnetworks) \
        || die 'Could not inspect ZeroTier memberships. Check: systemctl status zerotier-one'
    if zerotier_network_is_joined "$networks"; then
        log "ZeroTier network $ZEROTIER_NETWORK_ID is already joined."
    else
        log "Joining ZeroTier network $ZEROTIER_NETWORK_ID."
        zerotier-cli join "$ZEROTIER_NETWORK_ID" \
            || die "Could not join ZeroTier network $ZEROTIER_NETWORK_ID."
        networks=$(zerotier-cli listnetworks) \
            || die 'The ZeroTier join succeeded but membership could not be verified.'
        zerotier_network_is_joined "$networks" \
            || die "The ZeroTier join command succeeded, but network $ZEROTIER_NETWORK_ID was not listed afterward."
    fi

    network_line=$(awk -v network_id="$ZEROTIER_NETWORK_ID" \
        '$1 == "200" && $2 == "listnetworks" && $3 == network_id {print; exit}' \
        <<<"$networks")
    network_status=$(awk '{print $5}' <<<"$network_line")
    node_info=$(zerotier-cli info) || die 'Could not query ZeroTier node information.'
    node_id=$(awk '$1 == "200" && $2 == "info" {print $3; exit}' <<<"$node_info")

    log 'ZeroTier:'
    log "  node: ${node_id:-unknown}"
    log "  network: $ZEROTIER_NETWORK_ID"
    if [[ $network_status == OK ]]; then
        log '  status: joined'
    else
        log "  status: joined (${network_status:-unknown})"
    fi
    case $network_status in
        ACCESS_DENIED|REQUESTING_CONFIGURATION)
            log 'The ZeroTier member may still need authorization in ZeroTier Central.'
            ;;
    esac
}

compose() {
    BAKEDESK_ENV_FILE="$DEPLOY_DIR/.env" docker compose \
        --project-directory "$DEPLOY_DIR" \
        --env-file "$DEPLOY_DIR/.env" \
        -f "$DEPLOY_DIR/compose.yaml" "$@"
}

[[ -f $DEPLOY_DIR/.env ]] || die "Missing $DEPLOY_DIR/.env. Run setup.sh or copy .env.example."
[[ -f $APP_DIR/composer.json && -f $APP_DIR/symfony.lock && -x $APP_DIR/bin/console ]] \
    || die "$APP_DIR does not look like a BakeDesk checkout."
command -v docker >/dev/null 2>&1 || die 'Docker is not installed or is not on PATH.'
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_BACKUP_ENABLED 1
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_BACKUP_SCHEDULE '"Sun *-*-* 02:00:00 America/Indiana/Indianapolis"'
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_BACKUP_RETENTION_DAYS 90
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_BACKUP_DIRECTORY /opt/bakedesk/backups
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_CLEANUP_ENABLED 1
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_CLEANUP_SCHEDULE '"*-*-* 03:00:00 America/Indiana/Indianapolis"'
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_PRINT_JOB_RETENTION_DAYS 90
env_append_default "$DEPLOY_DIR/.env" BAKEDESK_ORDER_RETENTION_DAYS 730
validate_runtime_configuration "$DEPLOY_DIR/.env"
ensure_backup_directory "$BAKEDESK_BACKUP_DIRECTORY"
configure_zerotier

if [[ ${BAKEDESK_REFRESH_PUBLIC_ASSETS:-0} == 1 ]]; then
    log 'Stopping the stack so the generated public-assets volume can be refreshed.'
    compose down --remove-orphans
    docker volume rm bakedesk_public_assets >/dev/null 2>&1 || true
fi

log 'Validating Docker Compose configuration.'
compose config --quiet
reconcile_timers "$DEPLOY_DIR/.env" "$DEPLOY_DIR"
log 'Building the production BakeDesk PHP image.'
compose build php
log 'Starting infrastructure services.'
compose up -d database valkey mercure gotenberg

log 'Waiting for PostgreSQL to accept connections.'
ready=0
for attempt in $(seq 1 60); do
    if compose exec -T database pg_isready >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
[[ $ready -eq 1 ]] || die 'PostgreSQL did not become ready within 120 seconds.'

log 'Applying Doctrine migrations.'
compose run --rm --no-deps php php bin/console doctrine:migrations:migrate --no-interaction
log 'Starting PHP-FPM, the print worker, and Nginx.'
compose up -d --no-build php worker nginx
log 'Deployment complete. Open http://bakedesk.local on the bakery LAN.'
