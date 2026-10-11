#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
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
    [[ ${EUID} -eq 0 ]] || die 'Run this script with root privileges, for example: sudo ./restore.sh /path/to/archive.tar.gz'
}

usage() {
    printf 'Usage: sudo %s [--yes] /path/to/bakedesk-YYYY-MM-DD_HHMMSS.tar.gz\n' "$0" >&2
    exit 2
}

compose_with_env() {
    local env_file=$1
    shift
    BAKEDESK_ENV_FILE="$env_file" docker compose \
        --project-directory "$DEPLOY_DIR" \
        --env-file "$env_file" \
        -f "$DEPLOY_DIR/compose.yaml" "$@"
}

service_is_running() {
    local env_file=$1
    local service=$2
    local container_id

    container_id=$(compose_with_env "$env_file" ps -q "$service")
    [[ -n $container_id ]] \
        && [[ $(docker inspect --format '{{.State.Running}}' "$container_id") == true ]]
}

archive_entry_allowed() {
    local entry=$1
    while [[ $entry == ./* ]]; do
        entry=${entry#./}
    done
    [[ -n $entry ]] || return 0
    [[ $entry != /* && $entry != *$'\n'* && $entry != *$'\r'* ]] || return 1
    [[ $entry != *'/../'* && $entry != ../* && $entry != */.. && $entry != .. ]] || return 1
    case $entry in
        manifest.txt|checksums.sha256|database.dump|deploy.env|documents|documents/*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_archive_structure() {
    local archive=$1
    local listing=$2
    local entry normalized
    local have_manifest=0 have_checksums=0 have_dump=0 have_env=0 have_documents=0

    if ! tar --null --list --file "$archive" > "$listing"; then
        die 'The backup archive is not a readable gzip tar archive.'
    fi
    while IFS= read -r -d '' entry; do
        archive_entry_allowed "$entry" \
            || die "The backup contains an unexpected or unsafe archive path: $entry"
        normalized=$entry
        while [[ $normalized == ./* ]]; do
            normalized=${normalized#./}
        done
        case $normalized in
            manifest.txt) have_manifest=1 ;;
            checksums.sha256) have_checksums=1 ;;
            database.dump) have_dump=1 ;;
            deploy.env) have_env=1 ;;
            documents|documents/*) have_documents=1 ;;
        esac
    done < "$listing"

    [[ $have_manifest -eq 1 ]] || die 'The backup is missing manifest.txt.'
    [[ $have_checksums -eq 1 ]] || die 'The backup is missing checksums.sha256.'
    [[ $have_dump -eq 1 ]] || die 'The backup is missing database.dump.'
    [[ $have_env -eq 1 ]] || die 'The backup is missing deploy.env.'
    [[ $have_documents -eq 1 ]] || die 'The backup is missing the documents payload.'
}

validate_manifest() {
    local manifest=$1

    grep -Fqx 'BakeDesk backup format: 1' "$manifest" \
        || die 'Unsupported or missing BakeDesk backup format version.'
    if grep -Eiq '(password|secret|app_secret|database_url)' "$manifest"; then
        die 'The backup manifest contains a prohibited secret-like field.'
    fi
}

validate_checksum_paths() {
    local extract_dir=$1
    local checksums=$extract_dir/checksums.sha256
    local line hash path
    declare -A checksum_paths=()

    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^([0-9a-fA-F]{64})\ \ (.+)$ ]] \
            || die 'The backup checksum metadata is malformed.'
        hash=${BASH_REMATCH[1],,}
        path=${BASH_REMATCH[2]}
        [[ $path != /* && $path != *$'\n'* && $path != *$'\r'* ]] \
            || die 'The backup checksum metadata contains an unsafe path.'
        [[ $path != *'/../'* && $path != ../* && $path != */.. && $path != .. ]] \
            || die 'The backup checksum metadata contains a traversal path.'
        case $path in
            database.dump|deploy.env|documents/*) ;;
            *) die "The backup checksum metadata references an unexpected path: $path" ;;
        esac
        [[ -f $extract_dir/$path ]] || die "The backup checksum path is missing: $path"
        [[ -z ${checksum_paths[$path]+present} ]] || die "The backup contains duplicate checksum metadata: $path"
        checksum_paths[$path]=$hash
    done < "$checksums"

    [[ -n ${checksum_paths[database.dump]+present} ]] || die 'database.dump has no checksum.'
    [[ -n ${checksum_paths[deploy.env]+present} ]] || die 'deploy.env has no checksum.'

    local file relative actual
    while IFS= read -r -d '' file; do
        relative=${file#"$extract_dir/"}
        [[ -n ${checksum_paths[$relative]+present} ]] \
            || die "The documents payload has no checksum: $relative"
    done < <(find "$extract_dir/documents" -type f -print0)

    while IFS= read -r line || [[ -n $line ]]; do
        path=${line#*  }
        actual=$(sha256sum "$extract_dir/$path" | awk '{print $1}')
        [[ $actual == "${checksum_paths[$path]}" ]] \
            || die "Checksum verification failed for $path."
    done < "$checksums"
}

read_required_env_value() {
    local env_file=$1
    local name=$2

    env_read "$env_file" "$name" \
        || die "The restored deploy.env is missing $name."
    [[ -n $ENV_VALUE ]] || die "$name in the restored deploy.env must not be empty."
    RESTORE_ENV_VALUE=$ENV_VALUE
}

validate_identifier() {
    local name=$1
    local value=$2
    [[ $value =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || die "$name must be a simple PostgreSQL identifier for safe restore: $value"
}

validate_database_url() {
    local env_file=$1
    local user=$2
    local database=$3
    local password=$4
    local database_url rest url_password database_target

    env_read "$env_file" DATABASE_URL \
        || die 'The restored deploy.env is missing DATABASE_URL.'
    database_url=$ENV_VALUE
    rest=${database_url#"postgresql://$user:"}
    url_password=${rest%%@*}
    database_target=${rest#*@database:5432/}
    [[ $database_url == "postgresql://$user:"*"@database:5432/"* ]] \
        || die 'The restored DATABASE_URL does not target the configured BakeDesk PostgreSQL user/database.'
    [[ $database_target == "$database" || $database_target == "$database?"* ]] \
        || die 'The restored DATABASE_URL does not target the configured BakeDesk PostgreSQL user/database.'
    [[ $url_password == "$password" ]] \
        || die 'The restored DATABASE_URL password does not match POSTGRES_PASSWORD; refusing a mismatched restore.'
}

sql_literal() {
    local value=$1
    value=${value//\'/\'\'}
    printf "'%s'" "$value"
}

reset_role_password() {
    local current_env=$1
    local user=$2
    local password=$3
    local password_literal

    password_literal=$(sql_literal "$password")
    printf 'ALTER ROLE "%s" WITH LOGIN PASSWORD %s;\n' "$user" "$password_literal" \
        | compose_with_env "$current_env" exec -T database psql -v ON_ERROR_STOP=1 -U "$user" -d postgres >/dev/null
}

reset_database_credentials() {
    local current_env=$1
    local restored_user=$2
    local restored_password=$3
    local restored_database=$4
    local current_user=$5
    local role_exists password_literal database_literal

    password_literal=$(sql_literal "$restored_password")
    database_literal=$(sql_literal "$restored_user")
    role_exists=$(compose_with_env "$current_env" exec -T database psql \
        -v ON_ERROR_STOP=1 -U "$current_user" -d postgres -Atqc \
        "SELECT 1 FROM pg_roles WHERE rolname = $database_literal")

    if [[ $role_exists == 1 ]]; then
        printf 'ALTER ROLE "%s" WITH LOGIN PASSWORD %s;\n' "$restored_user" "$password_literal" \
            | compose_with_env "$current_env" exec -T database psql -v ON_ERROR_STOP=1 -U "$current_user" -d postgres >/dev/null
    else
        printf 'CREATE ROLE "%s" LOGIN PASSWORD %s;\n' "$restored_user" "$password_literal" \
            | compose_with_env "$current_env" exec -T database psql -v ON_ERROR_STOP=1 -U "$current_user" -d postgres >/dev/null
    fi

    database_literal=$(sql_literal "$restored_database")
    {
        printf 'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = %s AND pid <> pg_backend_pid();\n' "$database_literal"
        printf 'DROP DATABASE IF EXISTS "%s";\n' "$restored_database"
        printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$restored_database" "$restored_user"
    } | compose_with_env "$current_env" exec -T database psql -v ON_ERROR_STOP=1 -U "$current_user" -d postgres >/dev/null
}

restore_database() {
    local current_env=$1
    local dump_file=$2
    local restored_user=$3
    local restored_database=$4
    local current_user=$5

    compose_with_env "$current_env" exec -T database pg_restore \
        --exit-on-error --no-owner --no-privileges \
        -U "$current_user" -d "$restored_database" < "$dump_file"
    local owner
    owner=$(compose_with_env "$current_env" exec -T database psql \
        -v ON_ERROR_STOP=1 -U "$current_user" -d postgres -Atqc \
        "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$(printf '%s' "$restored_database" | sed "s/'/''/g")'")
    [[ $owner == "$restored_user" ]] \
        || die "Restored database owner is $owner; expected $restored_user."
}

verify_restored_credentials() {
    local env_file=$1
    local user=$2
    local database=$3
    local password=$4

    printf '%s\n' "$password" \
        | compose_with_env "$env_file" exec -T database sh -c \
            'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -h 127.0.0.1 -U "$1" -d "$2" -Atqc "SELECT 1"' \
            bakedesk-credential-check "$user" "$database" >/dev/null
}

confirm_restore() {
    local archive=$1
    if [[ ${ASSUME_YES:-0} == 1 ]]; then
        log 'Destructive restore confirmed by --yes.'
        return
    fi
    [[ -t 0 ]] || die 'Restore is non-interactive. Re-run with the deliberate destructive --yes option.'
    printf 'This will replace the current BakeDesk database, documents, and .env from:\n%s\n' "$archive" >&2
    printf 'Type RESTORE to continue: ' >&2
    local confirmation
    read -r confirmation
    [[ $confirmation == RESTORE ]] \
        || die 'Restore cancelled; confirmation did not match RESTORE.'
}

restore_on_exit() {
    local exit_status=$?
    trap - EXIT

    if [[ $exit_status -ne 0 ]]; then
        if [[ ${DOCUMENTS_SWAPPED:-0} == 1 && -d ${DOCUMENTS_ROLLBACK_DIR:-} ]]; then
            rm -rf -- "$DOCUMENTS_DIR"
            mv -- "$DOCUMENTS_ROLLBACK_DIR" "$DOCUMENTS_DIR"
            log 'Restore failed; the previous documents tree was put back.'
        fi
        if [[ ${ENV_REPLACED:-0} == 1 && -f ${CURRENT_ENV_COPY:-} ]]; then
            if reset_role_password "$CURRENT_ENV_COPY" "$CURRENT_DB_USER" "$CURRENT_DB_PASSWORD"; then
                log 'Restore failed; the PostgreSQL role password was put back to match the previous .env.'
            else
                log 'WARNING: the previous PostgreSQL role password could not be restored.'
            fi
            if install -o "$CURRENT_ENV_UID" -g "$CURRENT_ENV_GID" -m 0640 \
                "$CURRENT_ENV_COPY" "$ENV_FILE"; then
                log 'Restore failed; the previous deployment .env was put back.'
            else
                log 'WARNING: the previous deployment .env could not be restored.'
            fi
        fi
    fi
    rm -rf -- "$RESTORE_ROOT"
    exit "$exit_status"
}

main() {
    require_root
    [[ $# -ge 1 && $# -le 2 ]] || usage
    ASSUME_YES=0
    if [[ $1 == --yes ]]; then
        ASSUME_YES=1
        shift
    fi
    [[ $# -eq 1 ]] || usage
    local archive=$1
    [[ -f $archive ]] || die "Backup archive does not exist: $archive"
    archive=$(cd -- "$(dirname -- "$archive")" && pwd -P)/$(basename -- "$archive")
    [[ -r $archive ]] || die "Backup archive is not readable: $archive"
    command -v docker >/dev/null 2>&1 || die 'Docker is not installed or is not on PATH.'
    command -v flock >/dev/null 2>&1 || die 'flock is required for restore locking.'
    [[ -f $ENV_FILE ]] || die "Missing current deployment environment: $ENV_FILE"
    [[ -d $DATA_DIR ]] || die "Missing data directory: $DATA_DIR"

    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE"

    local restore_root listing extract_dir backup_env current_env
    restore_root=$(mktemp -d "$DATA_DIR/.bakedesk-restore.XXXXXX")
    listing=$restore_root/archive.list
    extract_dir=$restore_root/payload
    current_env=$restore_root/current.env
    backup_env=$extract_dir/deploy.env
    mkdir -p -- "$extract_dir"
    RESTORE_ROOT=$restore_root
    DOCUMENTS_SWAPPED=0
    ENV_REPLACED=0
    CURRENT_ENV_COPY=''
    CURRENT_ENV_UID=''
    CURRENT_ENV_GID=''
    DOCUMENTS_ROLLBACK_DIR=''
    trap restore_on_exit EXIT

    flock -n 9 \
        || die 'Another BakeDesk backup or restore is already running.'
    validate_archive_structure "$archive" "$listing"
    tar --extract --gzip --file "$archive" --directory "$extract_dir" \
        --no-same-owner --no-same-permissions --no-overwrite-dir
    if find "$extract_dir" \( -type l -o -type b -o -type c -o -type p \) -print -quit | grep -q .; then
        die 'The backup contains an unsupported special file or symlink.'
    fi
    [[ -f $extract_dir/database.dump && -s $extract_dir/database.dump ]] \
        || die 'The backup database.dump is missing or empty.'
    [[ -d $extract_dir/documents ]] || die 'The backup documents payload is not a directory.'
    validate_manifest "$extract_dir/manifest.txt"
    validate_checksum_paths "$extract_dir"

    validate_runtime_configuration "$backup_env"
    read_required_env_value "$backup_env" POSTGRES_DB
    local restored_database=$RESTORE_ENV_VALUE
    read_required_env_value "$backup_env" POSTGRES_USER
    local restored_user=$RESTORE_ENV_VALUE
    read_required_env_value "$backup_env" POSTGRES_PASSWORD
    local restored_password=$RESTORE_ENV_VALUE
    validate_identifier POSTGRES_DB "$restored_database"
    validate_identifier POSTGRES_USER "$restored_user"
    validate_database_url "$backup_env" "$restored_user" "$restored_database" "$restored_password"

    env_read "$ENV_FILE" POSTGRES_USER \
        || die 'The current deployment environment is missing POSTGRES_USER.'
    local current_user=$ENV_VALUE
    validate_identifier POSTGRES_USER "$current_user"
    env_read "$ENV_FILE" POSTGRES_PASSWORD \
        || die 'The current deployment environment is missing POSTGRES_PASSWORD.'
    local current_password=$ENV_VALUE
    [[ -n $current_password ]] || die 'The current deployment POSTGRES_PASSWORD must not be empty.'
    cp -- "$ENV_FILE" "$current_env"
    chmod 0660 "$current_env"
    confirm_restore "$archive"

    local current_env_uid current_env_gid documents_rollback_dir
    current_env_uid=$(stat -c '%u' "$ENV_FILE")
    current_env_gid=$(stat -c '%g' "$ENV_FILE")
    documents_rollback_dir=$restore_root/documents-current
    CURRENT_ENV_COPY=$current_env
    CURRENT_ENV_UID=$current_env_uid
    CURRENT_ENV_GID=$current_env_gid
    CURRENT_DB_USER=$current_user
    CURRENT_DB_PASSWORD=$current_password
    DOCUMENTS_ROLLBACK_DIR=$documents_rollback_dir

    service_is_running "$current_env" database \
        || compose_with_env "$current_env" up -d database
    local database_ready=0
    for attempt in $(seq 1 60); do
        if compose_with_env "$current_env" exec -T database pg_isready >/dev/null 2>&1; then
            database_ready=1
            break
        fi
        sleep 2
    done
    [[ $database_ready -eq 1 ]] || die 'The current PostgreSQL service did not become ready.'

    log 'Stopping application writers before replacing production data.'
    compose_with_env "$current_env" stop nginx php worker >/dev/null
    log 'Installing the restored private deployment environment.'
    install -o "$current_env_uid" -g "$current_env_gid" -m 0640 "$backup_env" "$ENV_FILE"
    ENV_REPLACED=1

    log 'Resetting the PostgreSQL role password to match the restored .env.'
    reset_database_credentials "$current_env" "$restored_user" "$restored_password" "$restored_database" "$current_user"
    log 'Restoring the PostgreSQL logical dump.'
    restore_database "$current_env" "$extract_dir/database.dump" "$restored_user" "$restored_database" "$current_user"
    verify_restored_credentials "$current_env" "$restored_user" "$restored_database" "$restored_password"

    log 'Replacing the documents tree with the restored snapshot.'
    mkdir -p -- "$(dirname -- "$DOCUMENTS_DIR")"
    if [[ -e $DOCUMENTS_DIR ]]; then
        mv -- "$DOCUMENTS_DIR" "$documents_rollback_dir"
    fi
    DOCUMENTS_SWAPPED=1
    mv -- "$extract_dir/documents" "$DOCUMENTS_DIR"
    chown -R 33:33 "$DOCUMENTS_DIR"
    find "$DOCUMENTS_DIR" -type d -exec chmod 0770 {} +
    find "$DOCUMENTS_DIR" -type f -exec chmod 0660 {} +

    log 'Running deploy.sh to apply current migrations, reconcile timers, and start the application.'
    "$DEPLOY_DIR/deploy.sh"
    rm -rf -- "$documents_rollback_dir"
    DOCUMENTS_SWAPPED=0
    ENV_REPLACED=0

    log 'Restore status:'
    compose_with_env "$ENV_FILE" ps
    if ! compose_with_env "$ENV_FILE" exec -T database pg_isready >/dev/null; then
        die 'The restore completed but PostgreSQL health verification failed.'
    fi
    if command -v curl >/dev/null 2>&1 && ! curl --fail --silent --show-error --max-time 10 http://127.0.0.1/healthz >/dev/null; then
        log 'WARNING: the application health endpoint did not respond; inspect the Compose and service logs.'
    fi
    log 'BakeDesk restore completed.'
}

main "$@"
