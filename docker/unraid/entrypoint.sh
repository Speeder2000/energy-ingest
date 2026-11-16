#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# All-in-one start-up: embedded MariaDB, schema bootstrap, optional
# utility/meter registration, API token, folder import loop and the API.
#
# Every step is idempotent. Restarting never regenerates credentials,
# recreates the database or rotates a working API token.
set -Eeuo pipefail

# shellcheck source=docker/unraid/engy-common.sh
. /usr/local/lib/energy-ingest/engy-common.sh

db_pid=''
api_pid=''
loop_pid=''

# One exit path for success, failure and signals: stop the API and the
# import loop first, then let MariaDB flush InnoDB and exit cleanly.
on_exit() {
    local status=$?
    trap - EXIT TERM INT
    set +e
    for pid in "$api_pid" "$loop_pid"; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
    done
    for pid in "$api_pid" "$loop_pid"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null
    done
    if [ -n "$db_pid" ] && kill -0 "$db_pid" 2>/dev/null; then
        engy_log 'Stopping MariaDB...'
        kill -TERM "$db_pid" 2>/dev/null
        wait "$db_pid" 2>/dev/null
    fi
    engy_log "Stopped (status $status)."
    exit "$status"
}
trap on_exit EXIT
trap 'exit 0' TERM INT

[ "$(id -u)" -eq 0 ] ||
    engy_die 'start the container as root; use PUID/PGID for the runtime user'

# --- Runtime identity (Unraid: PUID=99, PGID=100) -------------------------

PUID="${PUID:-99}"
PGID="${PGID:-100}"
case "$PUID$PGID" in
    *[!0-9]*|'') engy_die 'PUID and PGID must be numeric' ;;
esac
[ "$PUID" -ne 0 ] || engy_die 'PUID must not be 0; the application never runs as root'

if [ "$(id -g "$ENGY_RUN_USER")" != "$PGID" ]; then
    groupmod --non-unique --gid "$PGID" "$ENGY_RUN_USER"
fi
if [ "$(id -u "$ENGY_RUN_USER")" != "$PUID" ]; then
    usermod --non-unique --uid "$PUID" --gid "$PGID" "$ENGY_RUN_USER"
fi

# --- Time zone: gas daily reporting uses local time -------------------------

if [ -n "${TZ:-}" ]; then
    [ -f "/usr/share/zoneinfo/$TZ" ] || engy_die "unknown TZ: $TZ"
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    printf '%s\n' "$TZ" >/etc/timezone
else
    engy_log 'WARNING: TZ is not set; using UTC. Set TZ to the utility'"'"'s'
    engy_log 'time zone (e.g. America/Los_Angeles) or gas days may shift.'
fi

# --- Configuration ----------------------------------------------------------

ENGY_DB_NAME="${ENGY_DB_NAME:-energy_ingest}"
ENGY_DB_USER="${ENGY_DB_USER:-energy_ingest}"
ENGY_API_PORT="${ENGY_API_PORT:-8080}"
ENGY_IMPORT_INTERVAL="${ENGY_IMPORT_INTERVAL:-300}"
engy_require_identifier ENGY_DB_NAME "$ENGY_DB_NAME"
engy_require_identifier ENGY_DB_USER "$ENGY_DB_USER"
engy_require_identifier ENGY_DB_ADMIN_USER "$ENGY_DB_ADMIN_USER"
[ "$ENGY_DB_USER" != "$ENGY_DB_ADMIN_USER" ] ||
    engy_die 'ENGY_DB_USER and ENGY_DB_ADMIN_USER must differ'
case "$ENGY_API_PORT" in
    ''|*[!0-9]*) engy_die 'ENGY_API_PORT must be numeric' ;;
esac
case "$ENGY_IMPORT_INTERVAL" in
    ''|*[!0-9]*) engy_die 'ENGY_IMPORT_INTERVAL must be numeric seconds' ;;
esac
[ "$ENGY_IMPORT_INTERVAL" -ge 30 ] ||
    engy_die 'ENGY_IMPORT_INTERVAL must be at least 30 seconds'
export ENGY_DB_NAME ENGY_DB_USER ENGY_API_PORT ENGY_IMPORT_INTERVAL

# --- Persistent storage -------------------------------------------------------

mkdir -p "$ENGY_CONFIG_DIR" "$ENGY_SECRETS_DIR" "$ENGY_STATE_DIR" \
    "$ENGY_DATA_DIR" /run/mysqld
# Recursive chown only when ownership differs (e.g. PUID changed).
for path in "$ENGY_CONFIG_DIR" "$ENGY_SECRETS_DIR" "$ENGY_STATE_DIR" \
    "$ENGY_DATA_DIR"; do
    if [ "$(stat -c %u:%g "$path")" != "$PUID:$PGID" ]; then
        chown -R "$PUID:$PGID" "$path"
    fi
done
chown "$PUID:$PGID" /run/mysqld
chmod 0700 "$ENGY_SECRETS_DIR" "$ENGY_DATA_DIR"

app_password="$(engy_secret ENGY_DB_PASSWORD db_password generate)"
admin_password="$(engy_secret ENGY_DB_ADMIN_PASSWORD db_admin_password generate)"
[ -n "$app_password" ] && [ -n "$admin_password" ] ||
    engy_die 'database credentials are empty'
chown "$PUID:$PGID" "$ENGY_SECRETS_DIR"/* 2>/dev/null || true
chmod 0600 "$ENGY_SECRETS_DIR"/* 2>/dev/null || true

if [ ! -d "$ENGY_IMPORT_DIR" ]; then
    engy_log "WARNING: $ENGY_IMPORT_DIR is not mounted; folder import is off."
elif ! gosu "$ENGY_RUN_USER" test -r "$ENGY_IMPORT_DIR" -a -x "$ENGY_IMPORT_DIR"; then
    engy_log "WARNING: $ENGY_IMPORT_DIR is not readable by UID $PUID."
fi

# --- Embedded MariaDB ---------------------------------------------------------

root_sql() {
    mariadb --protocol=socket --user=root --batch --skip-column-names "$@"
}

if [ ! -d "$ENGY_DATA_DIR/mysql" ]; then
    engy_log 'Initializing MariaDB data directory (first start)...'
    # Root authenticates only through the local socket as OS root; it has
    # no password and no network access.
    mariadb-install-db \
        --datadir="$ENGY_DATA_DIR" \
        --user="$ENGY_RUN_USER" \
        --auth-root-authentication-method=socket \
        --skip-test-db \
        >/dev/null
fi

engy_log 'Starting MariaDB...'
# Critical settings are repeated on the command line so distribution
# config files read later cannot move the data directory or listener.
mariadbd \
    --user="$ENGY_RUN_USER" \
    --datadir="$ENGY_DATA_DIR" \
    --bind-address=127.0.0.1 \
    --port="$ENGY_DB_PORT" \
    --socket=/run/mysqld/mysqld.sock \
    --pid-file=/run/mysqld/mysqld.pid \
    --skip-name-resolve &
db_pid=$!

for _ in $(seq 1 120); do
    kill -0 "$db_pid" 2>/dev/null || engy_die 'MariaDB exited during start-up'
    if mariadb-admin --protocol=socket --user=root ping --silent \
        >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
mariadb-admin --protocol=socket --user=root ping --silent >/dev/null 2>&1 ||
    engy_die 'MariaDB did not become ready'

# Adjust system tables after a MariaDB version change; fast when current.
if ! mariadb-upgrade --protocol=socket --user=root --silent >/dev/null 2>&1; then
    engy_log 'WARNING: mariadb-upgrade reported a problem; continuing.'
fi

# Accounts and grants are re-applied every start so configuration is the
# source of truth. The runtime account can only read and write rows.
app_sql="$(engy_sql_string "$app_password")"
admin_sql="$(engy_sql_string "$admin_password")"
root_sql <<SQL
CREATE DATABASE IF NOT EXISTS \`${ENGY_DB_NAME}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${ENGY_DB_USER}'@'127.0.0.1'
    IDENTIFIED BY '${app_sql}';
ALTER USER '${ENGY_DB_USER}'@'127.0.0.1' IDENTIFIED BY '${app_sql}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ENGY_DB_USER}'@'127.0.0.1';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${ENGY_DB_NAME}\`.*
    TO '${ENGY_DB_USER}'@'127.0.0.1';
CREATE USER IF NOT EXISTS '${ENGY_DB_ADMIN_USER}'@'127.0.0.1'
    IDENTIFIED BY '${admin_sql}';
ALTER USER '${ENGY_DB_ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${admin_sql}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${ENGY_DB_ADMIN_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${ENGY_DB_NAME}\`.*
    TO '${ENGY_DB_ADMIN_USER}'@'127.0.0.1';
DROP USER IF EXISTS '${ENGY_RUN_USER}'@'localhost';
DROP USER IF EXISTS 'mysql'@'localhost';
FLUSH PRIVILEGES;
SQL
unset app_sql admin_sql

engy_log 'Applying and verifying database schema...'
(
    ENGY_DB_ADMIN_URL="$(engy_db_url "$ENGY_DB_ADMIN_USER" "$admin_password")"
    export ENGY_DB_ADMIN_URL
    exec gosu "$ENGY_RUN_USER" energy-store-admin database bootstrap
)
unset admin_password app_password

# --- Optional unattended registration -----------------------------------------

source_id=''
electric_meter_id=''
gas_meter_id=''

id_from() {
    sed -n 's/.*id=\([0-9][0-9]*\).*/\1/p' | tail -n 1
}

ensure_meter() {
    local custodian="$1" commodity="$2" label="$3" name="$4" number_var="$5"
    local output meter number

    output="$(engy_as_app energy-store-admin meter ensure \
        "$custodian" "$commodity" "$name")" ||
        engy_die "could not register the $label meter"
    meter="$(printf '%s\n' "$output" | id_from)"
    [ -n "$meter" ] || engy_die "unexpected response registering $label meter"

    number="$(engy_secret "$number_var" "__unused__")"
    if [ -n "$number" ]; then
        # Passed on stdin; never on a command line or in logs.
        printf '%s\n' "$number" |
            engy_as_app energy-store-admin meter set-number "$meter" --stdin \
            >/dev/null || engy_die "could not save the $label meter number"
    fi
    unset number
    engy_log "$label meter ready: $name"
    printf '%s' "$meter"
}

if [ -n "${ENGY_UTILITY_NAME:-}" ]; then
    output="$(engy_as_app energy-store-admin custodian ensure \
        "$ENGY_UTILITY_NAME")" || engy_die 'could not register the utility'
    custodian_id="$(printf '%s\n' "$output" | id_from)"
    [ -n "$custodian_id" ] || engy_die 'unexpected utility registration response'

    output="$(engy_as_app energy-store-admin source create \
        "$custodian_id" "${ENGY_SOURCE_NAME:-Green Button Download}")" ||
        engy_die 'could not register the import source'
    source_id="$(printf '%s\n' "$output" | id_from)"
    [ -n "$source_id" ] || engy_die 'unexpected source registration response'
    engy_log "Utility and import source ready: $ENGY_UTILITY_NAME"

    if [ -n "${ENGY_ELECTRIC_METER_NAME:-}" ]; then
        electric_meter_id="$(ensure_meter "$custodian_id" 1 Electricity \
            "$ENGY_ELECTRIC_METER_NAME" ENGY_ELECTRIC_METER_NUMBER)"
    fi
    if [ -n "${ENGY_GAS_METER_NAME:-}" ]; then
        gas_meter_id="$(ensure_meter "$custodian_id" 7 'Natural gas' \
            "$ENGY_GAS_METER_NAME" ENGY_GAS_METER_NUMBER)"
    fi
else
    engy_log 'ENGY_UTILITY_NAME is not set; skipping registration and'
    engy_log 'folder import. The API still runs; use engy-admin to manage.'
fi

# --- API ------------------------------------------------------------------------

engy_log "Starting API on port $ENGY_API_PORT..."
(
    ENGY_API_LISTEN="0.0.0.0:${ENGY_API_PORT}"
    export ENGY_API_LISTEN
    unset ENGY_API_DEV_DOCS
    ENGY_DB_URL="$(engy_app_db_url)"
    export ENGY_DB_URL
    exec gosu "$ENGY_RUN_USER" energy-api
) &
api_pid=$!

api_ready=false
for _ in $(seq 1 60); do
    kill -0 "$api_pid" 2>/dev/null || break
    if curl -fs -o /dev/null --max-time 2 \
        "http://127.0.0.1:${ENGY_API_PORT}/healthz"; then
        api_ready=true
        break
    fi
    sleep 1
done
[ "$api_ready" = true ] || engy_die 'the API did not become ready'

# --- API token for Home Assistant -------------------------------------------------

token_file="$ENGY_SECRETS_DIR/api_token"

token_status() {
    local header code
    header="$(mktemp)"
    chmod 600 "$header"
    printf 'Authorization: Bearer %s\n' "$(cat -- "$token_file")" >"$header"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "@$header" "http://127.0.0.1:${ENGY_API_PORT}/v1/meters")" ||
        code=000
    rm -f -- "$header"
    printf '%s' "$code"
}

client_name="${ENGY_API_CLIENT_NAME:-home-assistant}"
if [ -s "$token_file" ] && [ "$(token_status)" = 200 ]; then
    engy_log "API token: present and valid ($token_file)"
else
    # Client names are unique even after revocation; suffix replacements.
    if engy_as_app energy-api-token list |
        cut -f2 | grep -Fxq -- "$client_name"; then
        client_name="${client_name}-$(date -u +%Y%m%d%H%M%S)"
    fi
    temp="$(mktemp "$ENGY_SECRETS_DIR/.token.XXXXXXXX")"
    if ! engy_as_app energy-api-token create "$client_name" \
        >"$temp" 2>/dev/null ||
        ! grep -Eq '^ei_[A-Za-z0-9_-]+$' "$temp" ||
        [ "$(wc -l <"$temp")" -ne 1 ]; then
        rm -f -- "$temp"
        engy_die 'could not create the API token'
    fi
    chown "$PUID:$PGID" "$temp"
    chmod 0600 "$temp"
    mv -f -- "$temp" "$token_file"
    engy_log "API token: created for client '$client_name'."
    engy_log "Read it from $token_file (appdata); it is not logged."
fi

# --- Folder import --------------------------------------------------------------------

if [ -n "$source_id" ] && [ -d "$ENGY_IMPORT_DIR" ]; then
    (
        export ENGY_RT_SOURCE_ID="$source_id"
        export ENGY_RT_METER_IDS="$electric_meter_id $gas_meter_id"
        ENGY_DB_URL="$(engy_app_db_url)"
        export ENGY_DB_URL
        exec gosu "$ENGY_RUN_USER" /usr/local/bin/engy-import-loop
    ) &
    loop_pid=$!
fi

engy_log 'Energy Ingest is running.'

# --- Supervise: stop everything if any component exits ----------------------------------

pids=("$db_pid" "$api_pid")
[ -z "$loop_pid" ] || pids+=("$loop_pid")
# A TERM/INT signal interrupts wait and runs the exit path with status 0.
while :; do
    wait -n "${pids[@]}" || true
    for pid in "${pids[@]}"; do
        kill -0 "$pid" 2>/dev/null ||
            engy_die "a component exited unexpectedly (pid $pid)"
    done
done
