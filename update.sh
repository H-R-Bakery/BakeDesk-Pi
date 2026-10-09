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

[[ -d $APP_DIR/.git ]] || die "$APP_DIR is not a Git checkout."
[[ -f $DEPLOY_DIR/deploy.sh ]] || die "Missing $DEPLOY_DIR/deploy.sh."

if ! git -C "$APP_DIR" diff --quiet || ! git -C "$APP_DIR" diff --cached --quiet; then
    die "The BakeDesk checkout has local changes; refusing to overwrite them."
fi

branch=$(git -C "$APP_DIR" symbolic-ref --quiet --short HEAD) \
    || die 'The BakeDesk checkout is in detached HEAD state; update it deliberately before deploying.'
upstream=$(git -C "$APP_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || die "Branch $branch has no upstream; configure one before using update.sh."

log "Fetching BakeDesk updates for $upstream."
git -C "$APP_DIR" fetch --prune origin
git -C "$APP_DIR" merge --ff-only "$upstream"

log 'Rebuilding and deploying the updated application.'
BAKEDESK_REFRESH_PUBLIC_ASSETS=1 "$DEPLOY_DIR/deploy.sh"
