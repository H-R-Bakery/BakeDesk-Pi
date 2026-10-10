#!/usr/bin/env bash
set -Eeuo pipefail

# This helper is intentionally separate from setup.sh because the JADENS
# package and queue are optional, hardware-specific deployment choices.

# shellcheck disable=SC2155
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly DEPLOY_DIR=${BAKEDESK_DEPLOY_DIR:-$SCRIPT_DIR}
readonly DRIVER_PACKAGE=${JADENS_DRIVER_DEB:-$SCRIPT_DIR/vendor/jadens/jadens-printer-driver_linux_3.3.6.506.deb}
readonly DRIVER_VERSION=3.3.6.506
readonly DRIVER_PACKAGE_NAME=jadens-printer-driver
readonly JADENS_FILTER=/usr/lib/cups/filter/jadens_printer_filter
readonly JADENS_PPD=/usr/share/cups/model/Jadens/JD-668BT.ppd
readonly JADENS_RUNTIME_PACKAGE=libcupsimage2t64
readonly QUEUE_NAME=bakedesk-label
readonly IPP_URI="ipp://host.docker.internal:631/printers/$QUEUE_NAME"
readonly DOCKER_SUBNET=${BAKEDESK_DOCKER_SUBNET:-172.30.42.0/24}
readonly CUPSD_CONF=/etc/cups/cupsd.conf
readonly CUPSD_MARKER_BEGIN='# BEGIN BakeDesk JADENS access'
readonly CUPSD_MARKER_END='# END BakeDesk JADENS access'
readonly CUPSD_SOCKET_DROPIN_DIR=/etc/systemd/system/cups.socket.d
readonly CUPSD_SOCKET_DROPIN=$CUPSD_SOCKET_DROPIN_DIR/bakedesk.conf
readonly COMPOSE_FILE=$DEPLOY_DIR/compose.yaml
readonly CUPS_IPPTOOL_TEST=/usr/share/cups/ipptool/get-printer-attributes.test

TEST_PRINT=0
HOST_GATEWAY_IP=''
CONTAINER_HTTP_STATUS=''
FILTER_DEPENDENCIES_STATUS=''
MEDIA_SUMMARY=''

log() {
    printf '[BakeDesk-Pi] %s\n' "$*"
}

die() {
    printf '[BakeDesk-Pi] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: sudo ./setup-jadens.sh [--test]

The default run configures the JADENS CUPS queue without submitting a print
job. --test submits one short diagnostic text job to the queue.

Environment overrides:
  JADENS_DRIVER_DEB       Path to the operator-supplied JADENS .deb
  JADENS_DEVICE_URI       Exact URI selected from lpinfo -v
  JADENS_MODEL             Exact model identifier selected from lpinfo -m
  BAKEDESK_DEPLOY_DIR      BakeDesk-Pi checkout directory
  BAKEDESK_DOCKER_SUBNET   Must match the Compose backend subnet
EOF
}

require_root() {
    [[ ${EUID} -eq 0 ]] || die 'Run this script with root privileges, for example: sudo ./setup-jadens.sh'
}

check_host() {
    [[ $(uname -s) == Linux ]] || die "Unsupported operating system: $(uname -s). This host must run Linux."
    [[ $(uname -m) == aarch64 ]] || die "Unsupported architecture: $(uname -m). This helper targets ARM64/aarch64."
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system because /etc/os-release is missing.'
    # shellcheck disable=SC1091
    . /etc/os-release
    local os_id=${ID:-unknown}
    local os_like=${ID_LIKE:-}
    if [[ $os_id != debian && $os_id != raspbian && $os_like != *debian* ]]; then
        die "Unsupported operating system: ${PRETTY_NAME:-$os_id}. Use Debian or Raspberry Pi OS ARM64."
    fi
    command -v apt-get >/dev/null 2>&1 || die 'apt-get is required on Debian/Raspberry Pi OS.'
    log "Detected ${PRETTY_NAME:-$os_id} on ARM64."
}

ensure_cups() {
    local required_commands=(lp lpinfo lpadmin lpoptions lpstat cupsenable cupsaccept cupsctl ipptool)
    local missing=()
    local command_name

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done

    if ((${#missing[@]} > 0)); then
        log 'CUPS command-line tools are missing; installing the minimal cups package.'
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y cups
    fi

    for command_name in "${required_commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 \
            || die "Required CUPS command is unavailable after installation: $command_name"
    done

    command -v systemctl >/dev/null 2>&1 || die 'systemctl is required to verify and activate host CUPS.'
    systemctl enable --now cups
    systemctl is-active --quiet cups || die 'CUPS is not active.'
    log 'CUPS is installed and active.'
}

ensure_jadens_runtime_dependencies() {
    log "Installing the JADENS filter runtime dependency: $JADENS_RUNTIME_PACKAGE."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$JADENS_RUNTIME_PACKAGE"
}

inspect_driver_package() {
    [[ -f $DRIVER_PACKAGE ]] || die "JADENS driver package not found: $DRIVER_PACKAGE"
    [[ -r $DRIVER_PACKAGE ]] || die "JADENS driver package is not readable: $DRIVER_PACKAGE"

    local package_name package_version package_arch package_contents
    package_name=$(dpkg-deb -f "$DRIVER_PACKAGE" Package)
    package_version=$(dpkg-deb -f "$DRIVER_PACKAGE" Version)
    package_arch=$(dpkg-deb -f "$DRIVER_PACKAGE" Architecture)

    [[ $package_name == "$DRIVER_PACKAGE_NAME" ]] \
        || die "Unexpected JADENS package name: $package_name"
    [[ $package_version == "$DRIVER_VERSION" ]] \
        || die "Unexpected JADENS driver version: $package_version (expected $DRIVER_VERSION)"
    [[ $package_arch == all ]] \
        || die "Unexpected JADENS package architecture: $package_arch (expected all)"
    package_contents=$(dpkg-deb --contents "$DRIVER_PACKAGE")
    grep -Fq './opt/jadens-printer-driver/arm64/rastertolabel' <<<"$package_contents" \
        || die 'The JADENS package does not contain its ARM64 raster filter.'
    grep -Fq './usr/share/cups/model/Jadens/JD-668BT.ppd' <<<"$package_contents" \
        || die 'The JADENS package does not contain the JD-668BT PPD.'

    log "Using JADENS Linux Driver $package_version from $DRIVER_PACKAGE."
}

install_driver() {
    local installed_version
    installed_version=$(dpkg-query -W -f='${Version}' "$DRIVER_PACKAGE_NAME" 2>/dev/null || true)

    if [[ $installed_version == "$DRIVER_VERSION" ]]; then
        log "JADENS Linux Driver $DRIVER_VERSION is already installed; continuing."
    else
        log "Installing JADENS Linux Driver $DRIVER_VERSION with apt and dependency resolution."
        apt-get update
        apt-get install -y "$DRIVER_PACKAGE"
    fi

    [[ -x $JADENS_FILTER ]] \
        || die 'The JADENS CUPS raster filter was not installed.'
    [[ -f $JADENS_PPD ]] \
        || die "The JADENS JD-668BT PPD was not installed: $JADENS_PPD"
}

verify_filter_dependencies() {
    local dependency_output unresolved

    [[ -x $JADENS_FILTER ]] \
        || die "The JADENS CUPS raster filter is missing or not executable: $JADENS_FILTER"

    if ! dependency_output=$(ldd "$JADENS_FILTER" 2>&1); then
        printf '%s\n' "$dependency_output" >&2
        die 'Could not inspect the JADENS filter shared-library dependencies.'
    fi

    unresolved=$(grep -F 'not found' <<<"$dependency_output" || true)
    if [[ -n $unresolved ]]; then
        printf '%s\n' "$dependency_output" >&2
        die 'The JADENS filter has unresolved shared-library dependencies.'
    fi

    FILTER_DEPENDENCIES_STATUS=OK
    log 'JADENS filter dependencies: OK'
}

select_model() {
    local model_output
    model_output=$(lpinfo -m)

    log 'JADENS models exposed by the installed CUPS driver:'
    printf '%s\n' "$model_output" | awk 'tolower($0) ~ /jadens/ {print "  " $0}'

    if [[ -n ${JADENS_MODEL:-} ]]; then
        awk -v model="$JADENS_MODEL" '$1 == model {found=1} END {exit !found}' <<<"$model_output" \
            || die "JADENS_MODEL was not exposed by lpinfo -m: $JADENS_MODEL"
        SELECTED_MODEL=$JADENS_MODEL
    else
        mapfile -t jd668_models < <(
            awk 'tolower($0) ~ /jadens/ && tolower($1) ~ /(^|\/)jd-668bt\.ppd$/ {print $1}' <<<"$model_output"
        )
        if ((${#jd668_models[@]} != 1)); then
            die "Expected exactly one installed JD-668BT model in lpinfo -m; found ${#jd668_models[@]}. Set JADENS_MODEL to one of the displayed identifiers."
        fi
        SELECTED_MODEL=${jd668_models[0]}
    fi

    log "Selected CUPS model: $SELECTED_MODEL"
}

select_device() {
    local device_output
    device_output=$(lpinfo -v)

    mapfile -t jadens_devices < <(
        awk 'tolower($0) ~ /usb:\/\// && (tolower($0) ~ /jadens/ || tolower($0) ~ /jd[-_ ]?668/) {print $NF}' <<<"$device_output" | sort -u
    )

    if [[ -n ${JADENS_DEVICE_URI:-} ]]; then
        grep -Fq -- "$JADENS_DEVICE_URI" <<<"$device_output" \
            || die "JADENS_DEVICE_URI was not reported by lpinfo -v: $JADENS_DEVICE_URI"
        SELECTED_DEVICE=$JADENS_DEVICE_URI
    elif ((${#jadens_devices[@]} == 1)); then
        SELECTED_DEVICE=${jadens_devices[0]}
    elif ((${#jadens_devices[@]} > 1)); then
        printf '%s\n' 'Multiple plausible JADENS USB devices were found:' >&2
        printf '  %s\n' "${jadens_devices[@]}" >&2
        die 'Set JADENS_DEVICE_URI to the exact URI to make the choice deterministic.'
    else
        printf '%s\n' 'No plausible JADENS USB printer was found by lpinfo -v.' >&2
        printf '%s\n' '--- lpinfo -v ---' >&2
        printf '%s\n' "$device_output" >&2
        if command -v lsusb >/dev/null 2>&1; then
            printf '%s\n' '--- lsusb ---' >&2
            lsusb >&2 || true
        else
            printf '%s\n' 'lsusb is unavailable; install usbutils for additional USB diagnostics.' >&2
        fi
        die 'Connect the JADENS printer locally and rerun setup-jadens.sh.'
    fi

    log "Selected device URI: $SELECTED_DEVICE"
}

configure_queue() {
    log "Creating or updating CUPS queue $QUEUE_NAME."
    lpadmin \
        -p "$QUEUE_NAME" \
        -v "$SELECTED_DEVICE" \
        -m "$SELECTED_MODEL" \
        -o printer-is-shared=true
    cupsenable "$QUEUE_NAME"
    cupsaccept "$QUEUE_NAME"
}

configure_media() {
    local options line option values token value normalized is_default
    options=$(lpoptions -p "$QUEUE_NAME" -l)
    SELECTED_MEDIA_OPTION=''
    SELECTED_MEDIA_VALUE=''
    SELECTED_MEDIA_IS_DEFAULT=0

    while IFS= read -r line; do
        [[ $line == *:* ]] || continue
        option=${line%%:*}
        option=${option%%/*}
        option=${option//[[:space:]]/}
        values=${line#*:}
        for token in $values; do
            value=${token%%/*}
            is_default=0
            if [[ $value == \** ]]; then
                is_default=1
                value=${value#\*}
            fi
            normalized=${value,,}
            case $normalized in
                4x6|4x6in|4x6inch|4x6inches|w288h432)
                    SELECTED_MEDIA_OPTION=$option
                    SELECTED_MEDIA_VALUE=$value
                    SELECTED_MEDIA_IS_DEFAULT=$is_default
                    break 2
                    ;;
            esac
        done
    done <<<"$options"

    if [[ -n $SELECTED_MEDIA_OPTION ]]; then
        if ((SELECTED_MEDIA_IS_DEFAULT)); then
            log "4x6 media is already selected: $SELECTED_MEDIA_OPTION=$SELECTED_MEDIA_VALUE"
        else
            lpadmin -p "$QUEUE_NAME" -o "$SELECTED_MEDIA_OPTION=$SELECTED_MEDIA_VALUE"
            log "Configured the driver-exposed 4x6 media option: $SELECTED_MEDIA_OPTION=$SELECTED_MEDIA_VALUE"
        fi
    else
        log 'The installed driver does not expose an exact 4x6 media option; leaving the queue valid for manual media verification.'
    fi

    verify_media_selection
}

verify_media_selection() {
    local options line option values token value normalized is_default
    local media_found=0 media_selected=0

    options=$(lpoptions -p "$QUEUE_NAME" -l)
    while IFS= read -r line; do
        [[ $line == *:* ]] || continue
        option=${line%%:*}
        option=${option%%/*}
        option=${option//[[:space:]]/}
        values=${line#*:}
        for token in $values; do
            value=${token%%/*}
            is_default=0
            if [[ $value == \** ]]; then
                is_default=1
                value=${value#\*}
            fi
            normalized=${value,,}
            case $normalized in
                4x6|4x6in|4x6inch|4x6inches|w288h432)
                    media_found=1
                    if ((is_default)); then
                        media_selected=1
                        MEDIA_SUMMARY="$option=$value"
                    fi
                    ;;
            esac
        done
    done <<<"$options"

    if (( ! media_found )); then
        MEDIA_SUMMARY='not exposed by the installed driver'
        log 'The installed driver does not expose an exact 4x6 media option.'
    elif ((media_selected)); then
        log "4x6 media selected: $MEDIA_SUMMARY"
    else
        die 'The installed driver exposes 4x6 media, but the queue did not select it.'
    fi
}

validate_cups_listener_scope() {
    local config_without_managed managed_block unsafe_listeners
    config_without_managed=$(mktemp)
    managed_block=$(mktemp)

    if ! awk \
        -v begin="$CUPSD_MARKER_BEGIN" \
        -v end="$CUPSD_MARKER_END" \
        -v outside="$config_without_managed" \
        -v managed="$managed_block" '
        $0 == begin {
            if (inside || seen) {
                invalid=1
            }
            inside=1
            seen=1
            print > managed
            next
        }
        $0 == end {
            if (!inside) {
                invalid=1
            }
            print > managed
            inside=0
            next
        }
        inside {
            print > managed
            next
        }
        {
            print > outside
        }
        END {
            if (inside) {
                invalid=1
            }
            exit invalid
        }
    ' "$CUPSD_CONF"; then
        rm -f "$config_without_managed" "$managed_block"
        return 2
    fi

    unsafe_listeners=$(grep -Ein \
        '^[[:space:]]*(Port[[:space:]]+631|Listen[[:space:]]+(\*|0\.0\.0\.0|::|\[::\])(:631)?)([[:space:]]*(#.*)?)$' \
        "$config_without_managed" "$managed_block" || true)
    rm -f "$config_without_managed" "$managed_block"

    if [[ -n $unsafe_listeners ]]; then
        printf '%s\n' "$unsafe_listeners" >&2
        return 1
    fi
}

apply_managed_cups_config() {
    local config_tmp config_without_old_block combined_config

    config_tmp=$(mktemp)
    printf '%s\n' \
        "$CUPSD_MARKER_BEGIN" \
        '# Managed by BakeDesk-Pi setup-jadens.sh.' \
        "# host.docker.internal resolves to the Docker host gateway: $HOST_GATEWAY_IP" \
        '# The Compose backend network is the only non-local client allowed to print.' \
        'ServerAlias host.docker.internal' \
        "Listen $HOST_GATEWAY_IP:631" \
        '<Location /printers>' \
        '  Order allow,deny' \
        '  Allow from 127.0.0.1' \
        '  Allow from ::1' \
        "  Allow from $DOCKER_SUBNET" \
        '</Location>' \
        "$CUPSD_MARKER_END" \
        >"$config_tmp"

    config_without_old_block=$(mktemp)
    awk -v begin="$CUPSD_MARKER_BEGIN" -v end="$CUPSD_MARKER_END" '
        $0 == begin { skipping=1; next }
        skipping && $0 == end { skipping=0; next }
        !skipping && $0 ~ /^[[:space:]]*ServerAlias[[:space:]]+host\.docker\.internal[[:space:]]*$/ { next }
        !skipping { print }
    ' "$CUPSD_CONF" >"$config_without_old_block"
    combined_config=$(mktemp)
    {
        cat "$config_without_old_block"
        printf '\n'
        cat "$config_tmp"
    } >"$combined_config"
    install -o root -g root -m 0644 "$combined_config" "$CUPSD_CONF"
    rm -f "$config_tmp" "$config_without_old_block" "$combined_config"
}

verify_managed_cups_access() {
    local managed_config required_line
    managed_config=$(awk -v begin="$CUPSD_MARKER_BEGIN" -v end="$CUPSD_MARKER_END" '
        $0 == begin { inside=1 }
        inside { print }
        $0 == end { inside=0 }
    ' "$CUPSD_CONF")

    [[ -n $managed_config ]] \
        || die 'The BakeDesk-managed CUPS access block is missing.'

    local required_lines=(
        "$CUPSD_MARKER_BEGIN"
        'ServerAlias host.docker.internal'
        "Listen $HOST_GATEWAY_IP:631"
        '<Location /printers>'
        '  Order allow,deny'
        '  Allow from 127.0.0.1'
        '  Allow from ::1'
        "  Allow from $DOCKER_SUBNET"
        '</Location>'
        "$CUPSD_MARKER_END"
    )
    for required_line in "${required_lines[@]}"; do
        grep -Fqx -- "$required_line" <<<"$managed_config" \
            || die "The BakeDesk-managed CUPS access block is incomplete: $required_line"
    done
}

enable_cups_printer_sharing() {
    local settings share_printers remote_any remote_admin

    cupsctl --share-printers \
        || die 'Could not enable CUPS server-side printer sharing.'
    settings=$(cupsctl) \
        || die 'Could not inspect CUPS server sharing settings.'

    share_printers=$(awk -F= '$1 == "_share_printers" {print $2}' <<<"$settings")
    remote_any=$(awk -F= '$1 == "_remote_any" {print $2}' <<<"$settings")
    remote_admin=$(awk -F= '$1 == "_remote_admin" {print $2}' <<<"$settings")

    [[ $share_printers == 1 ]] \
        || die 'CUPS server-side printer sharing is not enabled after cupsctl --share-printers.'
    [[ $remote_any != 1 ]] \
        || die 'CUPS remote-any access is enabled; refusing to continue with unrestricted printing.'
    [[ $remote_admin != 1 ]] \
        || die 'CUPS remote administration is enabled; refusing to continue.'

    log 'CUPS server-side printer sharing: enabled.'
    log 'CUPS remote-any printing and remote administration remain disabled.'
}

configure_cups_access() {
    [[ -f $CUPSD_CONF ]] || die "CUPS configuration file is missing: $CUPSD_CONF"
    command -v docker >/dev/null 2>&1 || die 'Docker is required to determine the host-gateway address for container CUPS access.'

    HOST_GATEWAY_IP=$(docker network inspect bridge --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null || true)
    [[ $HOST_GATEWAY_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die 'Could not determine Docker host-gateway IPv4 address from the default bridge.'

    if ! validate_cups_listener_scope; then
        die 'CUPS has a malformed BakeDesk-managed block or a genuinely broad pre-existing port-631 listener. Refusing to change or broaden that configuration automatically.'
    fi

    if [[ ! -e ${CUPSD_CONF}.bakedesk-jadens-preinclude ]]; then
        cp -a "$CUPSD_CONF" "${CUPSD_CONF}.bakedesk-jadens-preinclude"
    fi

    apply_managed_cups_config

    cupsd -t || die 'The generated CUPS configuration failed validation; CUPS was not restarted.'
    configure_cups_socket_activation
    enable_cups_printer_sharing

    if ! validate_cups_listener_scope; then
        die 'cupsctl --share-printers introduced or exposed a broad CUPS listener; refusing to continue.'
    fi
    apply_managed_cups_config
    verify_managed_cups_access
    cupsd -t || die 'The final CUPS configuration failed validation; CUPS was not restarted.'
    configure_cups_socket_activation
    systemctl is-active --quiet cups || die 'CUPS did not become active after applying Docker access rules.'
    verify_cups_tcp_listener
    verify_managed_cups_access
    log "Printer access is limited to $DOCKER_SUBNET and localhost."
    log 'CUPS administration remains governed by the existing local/admin access rules.'
}

configure_cups_socket_activation() {
    local dropin_tmp

    install -d -o root -g root -m 0755 "$CUPSD_SOCKET_DROPIN_DIR"
    dropin_tmp=$(mktemp)
    printf '%s\n' \
        '[Socket]' \
        'ListenStream=127.0.0.1:631' \
        "ListenStream=$HOST_GATEWAY_IP:631" \
        >"$dropin_tmp"
    install -o root -g root -m 0644 "$dropin_tmp" "$CUPSD_SOCKET_DROPIN"
    rm -f "$dropin_tmp"

    systemctl daemon-reload
    systemctl restart cups.socket
    systemctl restart cups.service
    systemctl is-active --quiet cups.socket || die 'CUPS socket activation did not become active.'
}

verify_cups_tcp_listener() {
    command -v ss >/dev/null 2>&1 || die 'The ss command is required to verify the CUPS TCP listener.'

    if ! ss -ltnH | awk -v endpoint="$HOST_GATEWAY_IP:631" '$4 == endpoint {found=1} END {exit !found}'; then
        die "CUPS TCP listener $HOST_GATEWAY_IP:631 is not present after socket activation. Inspect cups.socket and ss -ltn."
    fi

    log "CUPS TCP listener: $HOST_GATEWAY_IP:631"
}

verify_queue() {
    local printer_status accepting_status

    log 'Final CUPS queue verification:'
    printer_status=$(lpstat -p "$QUEUE_NAME") \
        || die "CUPS queue does not exist: $QUEUE_NAME"
    accepting_status=$(lpstat -a "$QUEUE_NAME") \
        || die "CUPS queue is not accepting jobs: $QUEUE_NAME"

    grep -Eiq '[[:space:]]enabled([[:space:]]|$)' <<<"$printer_status" \
        || die "CUPS queue is not enabled: $QUEUE_NAME"
    grep -Eiq 'accepting requests' <<<"$accepting_status" \
        || die "CUPS queue is not accepting jobs: $QUEUE_NAME"

    printf '%s\n' "$printer_status" "$accepting_status"
    lpoptions -p "$QUEUE_NAME" -l
    verify_queue_sharing
    log 'CUPS queue status: enabled and accepting jobs.'
}

verify_queue_sharing() {
    local attributes

    [[ -f $CUPS_IPPTOOL_TEST ]] \
        || die "The CUPS IPP attribute test is unavailable: $CUPS_IPPTOOL_TEST"

    if ! attributes=$(ipptool -4 -t -v -T 10 \
        "ipp://127.0.0.1:631/printers/$QUEUE_NAME" \
        "$CUPS_IPPTOOL_TEST" 2>&1); then
        printf '%s\n' "$attributes" >&2
        die "Could not query CUPS state for queue sharing: $QUEUE_NAME"
    fi

    if ! grep -Eiq 'printer-is-shared.*(true|1)' <<<"$attributes"; then
        printf '%s\n' "$attributes" >&2
        die "CUPS queue $QUEUE_NAME is not shared."
    fi

    log 'CUPS queue sharing:'
    log "  $QUEUE_NAME: shared"
}

verify_container_connectivity() {
    command -v docker >/dev/null 2>&1 \
        || die 'Docker is required for container-to-host CUPS HTTP verification.'
    [[ -f $COMPOSE_FILE ]] \
        || die "Compose file is unavailable at $COMPOSE_FILE; cannot verify container HTTP access."

    local running_service http_status
    running_service=''
    for service in php worker; do
        if docker compose --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" ps --status running --services 2>/dev/null \
            | grep -Fxq "$service"; then
            running_service=$service
            break
        fi
    done

    [[ -n $running_service ]] \
        || die 'BakeDesk PHP or worker container is not running; start the Compose stack before running setup-jadens.sh.'

    if ! http_status=$(docker compose --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" exec -T "$running_service" php -r '
        $url = "http://host.docker.internal:631/printers/bakedesk-label";
        $curl = curl_init($url);
        curl_setopt_array($curl, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 10,
        ]);
        $body = curl_exec($curl);
        if ($body === false) {
            fwrite(STDERR, "CUPS HTTP request failed: " . curl_error($curl) . "\n");
            curl_close($curl);
            exit(1);
        }
        $status = curl_getinfo($curl, CURLINFO_HTTP_CODE);
        curl_close($curl);
        printf("%d\n", $status);
    '); then
        die "Container $running_service could not connect to host.docker.internal:631 or complete the CUPS HTTP request."
    fi

    http_status=${http_status//$'\r'/}
    http_status=${http_status//$'\n'/}
    [[ $http_status =~ ^[0-9]{3}$ ]] \
        || die "Container $running_service returned an invalid HTTP status while checking the CUPS printer endpoint: ${http_status:-empty}."
    [[ $http_status == 200 ]] \
        || die "Container $running_service reached the CUPS printer endpoint, but it returned HTTP $http_status (expected HTTP 200)."

    CONTAINER_HTTP_STATUS=$http_status
    log "Container HTTP access: HTTP $CONTAINER_HTTP_STATUS"
}

submit_test_job() {
    local test_file job_id
    test_file=$(mktemp --suffix=.txt)
    printf 'BakeDesk JADENS diagnostic\nQueue: %s\nMedia target: 4x6\n' "$QUEUE_NAME" >"$test_file"
    if ! job_id=$(lp -d "$QUEUE_NAME" -o copies=1 "$test_file"); then
        rm -f "$test_file"
        die 'CUPS did not accept the diagnostic test job.'
    fi
    rm -f "$test_file"
    log "Submitted a non-destructive diagnostic text job: $job_id"
    log 'CUPS accepted the job; this does not by itself confirm physical printing.'
}

main() {
    case ${1:-} in
        '') ;;
        --test)
            TEST_PRINT=1
            ;;
        --help|-h)
            usage
            return 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1"
            ;;
    esac

    require_root
    check_host
    inspect_driver_package
    ensure_cups
    ensure_jadens_runtime_dependencies
    install_driver
    verify_filter_dependencies
    select_model
    select_device
    configure_queue
    configure_media
    configure_cups_access
    verify_queue
    verify_container_connectivity

    if ((TEST_PRINT)); then
        submit_test_job
    fi

    printf '\nJADENS printer setup complete.\n\n'
    printf 'Driver:\n  JADENS Linux Driver %s\n\n' "$DRIVER_VERSION"
    printf 'Filter dependencies:\n  %s\n\n' "$FILTER_DEPENDENCIES_STATUS"
    printf 'Device:\n  %s\n\n' "$SELECTED_DEVICE"
    printf 'CUPS queue:\n  %s\n\n' "$QUEUE_NAME"
    printf 'Queue sharing:\n  shared\n\n'
    printf 'Media:\n  %s\n\n' "$MEDIA_SUMMARY"
    printf 'CUPS TCP listener:\n  %s:631\n\n' "$HOST_GATEWAY_IP"
    printf 'Container HTTP access:\n  HTTP %s\n\n' "$CONTAINER_HTTP_STATUS"
    printf 'Queue status:\n'
    lpstat -p "$QUEUE_NAME"
    lpstat -a "$QUEUE_NAME"
    printf '\nIPP address for BakeDesk:\n  %s\n\n' "$IPP_URI"
    printf 'Configure this URI in:\n  BakeDesk → Admin → Printers\n'
}

main "$@"
