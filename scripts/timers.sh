#!/usr/bin/env bash

# Shared validation and systemd timer reconciliation. The caller must source
# scripts/env.sh first and provide log() and die() functions.

load_runtime_configuration() {
    local env_file=$1

    env_read_or_default "$env_file" BAKEDESK_BACKUP_ENABLED 1
    BAKEDESK_BACKUP_ENABLED=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_BACKUP_SCHEDULE 'Sun *-*-* 02:00:00 America/Indiana/Indianapolis'
    BAKEDESK_BACKUP_SCHEDULE=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_BACKUP_RETENTION_DAYS 90
    BAKEDESK_BACKUP_RETENTION_DAYS=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_BACKUP_DIRECTORY /opt/bakedesk/backups
    BAKEDESK_BACKUP_DIRECTORY=$ENV_VALUE

    env_read_or_default "$env_file" BAKEDESK_CLEANUP_ENABLED 1
    BAKEDESK_CLEANUP_ENABLED=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_CLEANUP_SCHEDULE '*-*-* 03:00:00 America/Indiana/Indianapolis'
    BAKEDESK_CLEANUP_SCHEDULE=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_PRINT_JOB_RETENTION_DAYS 90
    BAKEDESK_PRINT_JOB_RETENTION_DAYS=$ENV_VALUE
    env_read_or_default "$env_file" BAKEDESK_ORDER_RETENTION_DAYS 730
    BAKEDESK_ORDER_RETENTION_DAYS=$ENV_VALUE
}

validate_binary_flag() {
    local name=$1
    local value=$2
    [[ $value == 0 || $value == 1 ]] \
        || die "$name must be exactly 0 or 1."
}

validate_positive_integer() {
    local name=$1
    local value=$2
    [[ $value =~ ^[1-9][0-9]*$ ]] \
        || die "$name must be a positive integer."
}

validate_calendar_expression() {
    local name=$1
    local value=$2

    command -v systemd-analyze >/dev/null 2>&1 \
        || die 'systemd-analyze is required to validate systemd timer schedules.'
    if ! systemd-analyze calendar "$value" >/dev/null; then
        die "Invalid $name systemd calendar expression: $value"
    fi
}

validate_runtime_configuration() {
    local env_file=$1

    load_runtime_configuration "$env_file"
    validate_binary_flag BAKEDESK_BACKUP_ENABLED "$BAKEDESK_BACKUP_ENABLED"
    validate_binary_flag BAKEDESK_CLEANUP_ENABLED "$BAKEDESK_CLEANUP_ENABLED"
    validate_positive_integer BAKEDESK_BACKUP_RETENTION_DAYS "$BAKEDESK_BACKUP_RETENTION_DAYS"
    validate_positive_integer BAKEDESK_PRINT_JOB_RETENTION_DAYS "$BAKEDESK_PRINT_JOB_RETENTION_DAYS"
    validate_positive_integer BAKEDESK_ORDER_RETENTION_DAYS "$BAKEDESK_ORDER_RETENTION_DAYS"

    [[ $BAKEDESK_BACKUP_DIRECTORY == /* && $BAKEDESK_BACKUP_DIRECTORY != / ]] \
        || die 'BAKEDESK_BACKUP_DIRECTORY must be an absolute path other than /. '
    [[ $BAKEDESK_BACKUP_DIRECTORY != *$'\n'* && $BAKEDESK_BACKUP_DIRECTORY != *$'\r'* ]] \
        || die 'BAKEDESK_BACKUP_DIRECTORY must not contain a newline.'

    validate_calendar_expression BAKEDESK_BACKUP_SCHEDULE "$BAKEDESK_BACKUP_SCHEDULE"
    validate_calendar_expression BAKEDESK_CLEANUP_SCHEDULE "$BAKEDESK_CLEANUP_SCHEDULE"
}

ensure_backup_directory() {
    local backup_directory=$1

    install -d -o root -g root -m 0700 "$backup_directory"
    chown root:root "$backup_directory"
    chmod 0700 "$backup_directory"
    [[ $(stat -c '%u' "$backup_directory") == 0 ]] \
        || die "Backup directory is not root-owned: $backup_directory"
    [[ $(( $(stat -c '%a' "$backup_directory") & 077 )) -eq 0 ]] \
        || die "Backup directory permissions are too broad: $backup_directory"
}

write_managed_unit() {
    local unit_path=$1
    shift
    local temporary_unit

    temporary_unit=$(mktemp)
    printf '%s\n' "$@" > "$temporary_unit"
    install -o root -g root -m 0644 "$temporary_unit" "$unit_path"
    rm -f -- "$temporary_unit"
}

reconcile_timers() {
    local env_file=$1
    local deploy_dir=$2
    local systemd_directory=/etc/systemd/system

    load_runtime_configuration "$env_file"
    install -d -o root -g root -m 0755 "$systemd_directory"

    write_managed_unit "$systemd_directory/bakedesk-backup.service" \
        '[Unit]' \
        'Description=BakeDesk PostgreSQL and documents backup' \
        'Requires=docker.service' \
        'After=docker.service network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'User=root' \
        'Group=root' \
        'TimeoutStartSec=infinity' \
        'ExecStart='"$deploy_dir"'/backup.sh' \
        'UMask=0077'

    write_managed_unit "$systemd_directory/bakedesk-backup.timer" \
        '[Unit]' \
        'Description=Schedule BakeDesk backup' \
        '' \
        '[Timer]' \
        'OnCalendar='"$BAKEDESK_BACKUP_SCHEDULE" \
        'Persistent=true' \
        'Unit=bakedesk-backup.service' \
        '' \
        '[Install]' \
        'WantedBy=timers.target'

    write_managed_unit "$systemd_directory/bakedesk-cleanup.service" \
        '[Unit]' \
        'Description=Run the BakeDesk domain cleanup command' \
        'Requires=docker.service' \
        'After=docker.service network-online.target' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'User=root' \
        'Group=root' \
        'TimeoutStartSec=180' \
        'ExecStart='"$deploy_dir"'/cleanup.sh' \
        'UMask=0077'

    write_managed_unit "$systemd_directory/bakedesk-cleanup.timer" \
        '[Unit]' \
        'Description=Schedule BakeDesk domain cleanup' \
        '' \
        '[Timer]' \
        'OnCalendar='"$BAKEDESK_CLEANUP_SCHEDULE" \
        'Persistent=true' \
        'Unit=bakedesk-cleanup.service' \
        '' \
        '[Install]' \
        'WantedBy=timers.target'

    systemctl daemon-reload
    if [[ $BAKEDESK_BACKUP_ENABLED == 1 ]]; then
        systemctl enable --now bakedesk-backup.timer
        log 'Scheduled backups enabled.'
    else
        systemctl disable --now bakedesk-backup.timer >/dev/null 2>&1 || true
        log 'Scheduled backups disabled by BAKEDESK_BACKUP_ENABLED=0.'
    fi

    if [[ $BAKEDESK_CLEANUP_ENABLED == 1 ]]; then
        systemctl enable --now bakedesk-cleanup.timer
        log 'Scheduled application cleanup enabled.'
    else
        systemctl disable --now bakedesk-cleanup.timer >/dev/null 2>&1 || true
        log 'Scheduled application cleanup disabled by BAKEDESK_CLEANUP_ENABLED=0.'
    fi

    log 'Timer schedule status:'
    systemctl list-timers --no-pager --no-legend bakedesk-backup.timer bakedesk-cleanup.timer || true
}
