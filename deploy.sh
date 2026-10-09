#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
APP_DIR=${BAKEDESK_APP_DIR:-$(cd -- "$DEPLOY_DIR/../app" && pwd)}

log() {
    printf '[BakeDesk-Pi] %s\n' "$*"
}

die() {
    printf '[BakeDesk-Pi] ERROR: %s\n' "$*" >&2
    exit 1
}

compose() {
    docker compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/compose.yaml" "$@"
}

[[ -f $DEPLOY_DIR/.env ]] || die "Missing $DEPLOY_DIR/.env. Run setup.sh or copy .env.example."
[[ -f $APP_DIR/composer.json && -f $APP_DIR/symfony.lock && -x $APP_DIR/bin/console ]] \
    || die "$APP_DIR does not look like a BakeDesk checkout."
command -v docker >/dev/null 2>&1 || die 'Docker is not installed or is not on PATH.'

if [[ ${BAKEDESK_REFRESH_PUBLIC_ASSETS:-0} == 1 ]]; then
    log 'Stopping the stack so the generated public-assets volume can be refreshed.'
    compose down --remove-orphans
    docker volume rm bakedesk_public_assets >/dev/null 2>&1 || true
fi

log 'Validating Docker Compose configuration.'
compose config --quiet
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
