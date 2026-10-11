#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
APP_DIR=${BAKEDESK_APP_DIR:-$(cd -- "$DEPLOY_DIR/../app" && pwd)}
DATA_DIR=${BAKEDESK_DATA_DIR:-$DEPLOY_DIR/../data}
ENV_FILE=$DEPLOY_DIR/.env
DOCUMENTS_DIR=$DATA_DIR/documents
LOCK_FILE=/run/lock/bakedesk-backup-restore.lock

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

require_root() {
    [[ ${EUID} -eq 0 ]] || die 'Run this script with root privileges, for example: sudo ./backup.sh'
}

compose() {
    BAKEDESK_ENV_FILE="$ENV_FILE" docker compose \
        --project-directory "$DEPLOY_DIR" \
        --env-file "$ENV_FILE" \
        -f "$DEPLOY_DIR/compose.yaml" "$@"
}

service_is_running() {
    local service=$1
    local container_id

    container_id=$(compose ps -q "$service")
    [[ -n $container_id ]] \
        && [[ $(docker inspect --format '{{.State.Running}}' "$container_id") == true ]]
}

wait_for_service() {
    local service=$1
    local attempt

    for attempt in $(seq 1 60); do
        if service_is_running "$service"; then
            return 0
        fi
        sleep 2
    done
    die "The Compose service $service did not become running within 120 seconds."
}

restore_worker() {
    if [[ ${WORKER_RESTORE_NEEDED:-0} == 1 ]]; then
        log 'Restarting the BakeDesk print worker.'
        if compose start worker >/dev/null; then
            WORKER_RESTORE_NEEDED=0
        else
            log 'WARNING: the worker could not be restarted automatically.'
            return 1
        fi
    fi
}

cleanup_on_exit() {
    local exit_status=$?
    trap - EXIT

    if ! restore_worker; then
        exit_status=1
    fi
    [[ -z ${STAGING_DIR:-} ]] || rm -rf -- "$STAGING_DIR"
    [[ -z ${TEMP_ARCHIVE:-} ]] || rm -f -- "$TEMP_ARCHIVE"
    exit "$exit_status"
}

select_archive_name() {
    local base=$1
    local candidate=$BACKUP_DIRECTORY/$base.tar.gz
    local suffix=1

    while [[ -e $candidate ]]; do
        candidate=$BACKUP_DIRECTORY/${base}-${suffix}.tar.gz
        suffix=$((suffix + 1))
    done
    FINAL_ARCHIVE=$candidate
}

run_retention() {
    local retention_age=$((BAKEDESK_BACKUP_RETENTION_DAYS - 1))
    local removed=0
    local candidate basename

    while IFS= read -r -d '' candidate; do
        basename=${candidate##*/}
        [[ $basename =~ ^bakedesk-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}(-[0-9]+)?\.tar\.gz$ ]] || continue
        if rm -f -- "$candidate"; then
            removed=$((removed + 1))
        else
            log "WARNING: could not remove expired archive $basename."
        fi
    done < <(find "$BACKUP_DIRECTORY" -mindepth 1 -maxdepth 1 -type f -mtime +"$retention_age" -print0)

    log "Removed $removed expired BakeDesk backup archive(s)."
}

main() {
    require_root
    [[ -f $ENV_FILE ]] || die "Missing $ENV_FILE. Run setup.sh or copy .env.example."
    [[ -f $DEPLOY_DIR/compose.yaml ]] || die "Missing $DEPLOY_DIR/compose.yaml."
    [[ -d $DOCUMENTS_DIR ]] || die "Missing documents directory: $DOCUMENTS_DIR"
    command -v docker >/dev/null 2>&1 || die 'Docker is not installed or is not on PATH.'
    command -v flock >/dev/null 2>&1 || die 'flock is required for backup locking.'

    validate_runtime_configuration "$ENV_FILE"
    BACKUP_DIRECTORY=$BAKEDESK_BACKUP_DIRECTORY
    ensure_backup_directory "$BACKUP_DIRECTORY"

    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE"
    flock -n 9 \
        || die 'Another BakeDesk backup or restore is already running.'

    local pg_database pg_user postgres_version app_commit deploy_commit timestamp base_name relative_file database_ready attempt worker_container_id worker_was_running
    env_read_or_default "$ENV_FILE" POSTGRES_DB bakery
    pg_database=$ENV_VALUE
    env_read_or_default "$ENV_FILE" POSTGRES_USER baker
    pg_user=$ENV_VALUE
    env_read_or_default "$ENV_FILE" POSTGRES_VERSION 18
    postgres_version=$ENV_VALUE

    STAGING_DIR=$(mktemp -d "$BACKUP_DIRECTORY/.bakedesk-backup.XXXXXX")
    TEMP_ARCHIVE=''
    WORKER_RESTORE_NEEDED=0
    trap cleanup_on_exit EXIT

    wait_for_service database
    worker_container_id=$(compose ps -q worker)
    [[ -n $worker_container_id ]] || die 'The BakeDesk worker Compose service has not been created.'
    worker_was_running=0
    if service_is_running worker; then
        worker_was_running=1
    fi
    database_ready=0
    for attempt in $(seq 1 60); do
        if compose exec -T database pg_isready -U "$pg_user" -d "$pg_database" >/dev/null 2>&1; then
            database_ready=1
            break
        fi
        sleep 2
    done
    [[ $database_ready -eq 1 ]] || die 'PostgreSQL did not become ready within 120 seconds.'

    log 'Stopping the BakeDesk print worker for a consistent documents snapshot.'
    compose stop worker >/dev/null
    WORKER_RESTORE_NEEDED=$worker_was_running

    log 'Creating the PostgreSQL logical dump.'
    if ! compose exec -T database pg_dump -Fc -U "$pg_user" -d "$pg_database" > "$STAGING_DIR/database.dump"; then
        die 'pg_dump failed; the backup was not completed.'
    fi
    [[ -s $STAGING_DIR/database.dump ]] || die 'pg_dump produced an empty dump.'

    log 'Archiving the documents directory.'
    if find "$DOCUMENTS_DIR" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        die 'The documents directory contains an unsupported special file or symlink.'
    fi
    mkdir -p -- "$STAGING_DIR/documents"
    tar -C "$DOCUMENTS_DIR" -cf - . | tar -C "$STAGING_DIR/documents" -xf -

    cp -- "$ENV_FILE" "$STAGING_DIR/deploy.env"
    chmod 0600 "$STAGING_DIR/deploy.env"

    app_commit=$(git -C "$APP_DIR" rev-parse HEAD 2>/dev/null) \
        || die 'Could not determine the BakeDesk Git commit.'
    deploy_commit=$(git -C "$DEPLOY_DIR" rev-parse HEAD 2>/dev/null) \
        || die 'Could not determine the BakeDesk-Pi Git commit.'
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    {
        printf '%s\n' 'BakeDesk backup format: 1'
        printf 'Created at (UTC): %s\n' "$timestamp"
        printf 'Hostname: %s\n' "$(hostname)"
        printf 'POSTGRES_VERSION: %s\n' "$postgres_version"
        printf 'POSTGRES_DB: %s\n' "$pg_database"
        printf 'BakeDesk Git commit: %s\n' "$app_commit"
        printf 'BakeDesk-Pi Git commit: %s\n' "$deploy_commit"
        printf '%s\n' 'Payload: database.dump, documents/, deploy.env'
    } > "$STAGING_DIR/manifest.txt"

    (
        cd -- "$STAGING_DIR"
        sha256sum database.dump deploy.env
    ) > "$STAGING_DIR/checksums.sha256"
    while IFS= read -r -d '' file; do
        relative_file=${file#"$STAGING_DIR/"}
        (cd -- "$STAGING_DIR" && sha256sum -- "$relative_file") >> "$STAGING_DIR/checksums.sha256"
    done < <(find "$STAGING_DIR/documents" -type f -print0 | sort -z)

    [[ -s $STAGING_DIR/manifest.txt && -s $STAGING_DIR/checksums.sha256 ]] \
        || die 'The backup metadata was not created.'

    timestamp=$(date -u '+%Y-%m-%d_%H%M%S')
    base_name=bakedesk-$timestamp
    select_archive_name "$base_name"
    TEMP_ARCHIVE=$(mktemp "$BACKUP_DIRECTORY/.bakedesk-archive.XXXXXX")
    log "Creating $FINAL_ARCHIVE."
    tar -C "$STAGING_DIR" -czf "$TEMP_ARCHIVE" .
    tar -tzf "$TEMP_ARCHIVE" >/dev/null
    chmod 0600 "$TEMP_ARCHIVE"
    restore_worker || die 'The backup completed but the print worker could not be restarted.'
    mv -- "$TEMP_ARCHIVE" "$FINAL_ARCHIVE"
    TEMP_ARCHIVE=''
    run_retention
    log "Backup completed: $FINAL_ARCHIVE"
}

main "$@"
