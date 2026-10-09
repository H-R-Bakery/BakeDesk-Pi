#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
    printf 'Missing %s/.env; run setup.sh or copy .env.example first.\n' "$DEPLOY_DIR" >&2
    exit 1
fi

docker compose --project-directory "$DEPLOY_DIR" -f "$DEPLOY_DIR/compose.yaml" ps
printf '\nApplication health: '
curl --fail --silent --show-error --max-time 5 http://127.0.0.1/healthz
printf 'Avahi: '
if systemctl is-active --quiet avahi-daemon; then
    printf 'active\n'
else
    printf 'inactive\n'
fi
printf 'CUPS: '
if systemctl is-active --quiet cups; then
    printf 'active\n'
else
    printf 'inactive\n'
fi
