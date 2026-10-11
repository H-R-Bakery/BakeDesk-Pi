#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
ENV_FILE=$DEPLOY_DIR/.env

# shellcheck source=scripts/env.sh
source "$SCRIPT_DIR/scripts/env.sh"

log() {
    printf '[BakeDesk-Pi] %s\n' "$*"
}

die() {
    printf '[BakeDesk-Pi] ERROR: %s\n' "$*" >&2
    exit 1
}

[[ ${EUID} -eq 0 ]] || die 'Run this script with root privileges, for example: sudo ./cleanup.sh --dry-run'
[[ -f $ENV_FILE ]] || die "Missing $ENV_FILE."
command -v docker >/dev/null 2>&1 || die 'Docker is not installed or is not on PATH.'

env_read_or_default "$ENV_FILE" BAKEDESK_PRINT_JOB_RETENTION_DAYS 90
[[ $ENV_VALUE =~ ^[1-9][0-9]*$ ]] || die 'BAKEDESK_PRINT_JOB_RETENTION_DAYS must be a positive integer.'
env_read_or_default "$ENV_FILE" BAKEDESK_ORDER_RETENTION_DAYS 730
[[ $ENV_VALUE =~ ^[1-9][0-9]*$ ]] || die 'BAKEDESK_ORDER_RETENTION_DAYS must be a positive integer.'

compose() {
    BAKEDESK_ENV_FILE="$ENV_FILE" docker compose \
        --project-directory "$DEPLOY_DIR" \
        --env-file "$ENV_FILE" \
        -f "$DEPLOY_DIR/compose.yaml" "$@"
}

php_is_running() {
    local container_id
    container_id=$(compose ps -q php)
    [[ -n $container_id ]] \
        && [[ $(docker inspect --format '{{.State.Running}}' "$container_id") == true ]]
}

log 'Waiting for the production PHP service to be running.'
ready=0
for attempt in $(seq 1 60); do
    if php_is_running; then
        ready=1
        break
    fi
    sleep 2
done
[[ $ready -eq 1 ]] || die 'The PHP service did not become available for cleanup within 120 seconds.'

compose exec -T php php bin/console bakedesk:cleanup --no-interaction "$@"
