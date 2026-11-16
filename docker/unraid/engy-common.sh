# SPDX-License-Identifier: MIT
# Shared helpers for the all-in-one image. Sourced by bash scripts.
#
# Secrets are never printed, never placed on a command line, and are only
# exported inside subshells that exec the program needing them.

ENGY_CONFIG_DIR=/config
ENGY_SECRETS_DIR=/config/secrets
ENGY_STATE_DIR=/config/state
ENGY_DATA_DIR=/config/mysql
ENGY_IMPORT_DIR=/imports
ENGY_RUN_USER=energy
ENGY_DB_HOST=127.0.0.1
ENGY_DB_PORT=3306
# Migration account: full rights on the application database only.
ENGY_DB_ADMIN_USER="${ENGY_DB_ADMIN_USER:-energy_ingest_admin}"

# Logs go to stderr so command substitutions never capture them.
engy_log() {
    printf '%s [energy-ingest] %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

engy_die() {
    engy_log "ERROR: $*"
    exit 1
}

# Database and account names are interpolated into SQL identifiers.
engy_require_identifier() {
    local label="$1" value="$2"
    case "$value" in
        ''|*[!A-Za-z0-9_]*)
            engy_die "$label must contain only letters, digits and _"
            ;;
    esac
    [ "${#value}" -le 64 ] || engy_die "$label is longer than 64 characters"
}

engy_random_hex() {
    head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n'
}

# Resolve a secret: NAME, then NAME_FILE, then a persisted file under
# /config/secrets. With "generate", a missing value is created once and
# persisted; it is never rotated on later starts.
engy_secret() {
    local var="$1" file="$2" mode="${3:-}"
    local file_var="${var}_FILE"
    local path="$ENGY_SECRETS_DIR/$file"
    local value=''

    if [ -n "${!var:-}" ]; then
        value="${!var}"
    elif [ -n "${!file_var:-}" ]; then
        [ -r "${!file_var}" ] || engy_die "$file_var is not readable"
        value="$(cat -- "${!file_var}")"
    elif [ -s "$path" ]; then
        value="$(cat -- "$path")"
    elif [ "$mode" = generate ]; then
        (umask 077 && engy_random_hex >"$path")
        value="$(cat -- "$path")"
    fi
    # Tolerate a trailing newline in files written by editors.
    value="${value%$'\n'}"
    value="${value%$'\r'}"
    printf '%s' "$value"
}

# Percent-encode every byte so any password is safe inside a URL.
engy_urlencode() {
    printf '%s' "$1" | od -An -v -tx1 | tr -s ' \n' ' ' |
        sed 's/^ *//; s/ *$//; s/ /%/g; s/^/%/; s/^%$//'
}

# Escape a value for a single-quoted SQL string literal.
engy_sql_string() {
    printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g"
}

engy_db_url() {
    local user="$1" password="$2"
    printf 'mysql://%s:%s@%s:%s/%s' \
        "$user" "$(engy_urlencode "$password")" \
        "$ENGY_DB_HOST" "$ENGY_DB_PORT" "$ENGY_DB_NAME"
}

# Application (least-privilege) connection URL.
engy_app_db_url() {
    engy_db_url "$ENGY_DB_USER" \
        "$(engy_secret ENGY_DB_PASSWORD db_password)"
}

# Run a command as the unprivileged account with ENGY_DB_URL set.
engy_as_app() {
    (
        ENGY_DB_URL="$(engy_app_db_url)"
        export ENGY_DB_URL
        if [ "$(id -u)" -eq 0 ]; then
            exec gosu "$ENGY_RUN_USER" "$@"
        fi
        exec "$@"
    )
}
