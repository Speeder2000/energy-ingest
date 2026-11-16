#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Imports Green Button XML files dropped into /imports, then associates the
# imported data with the configured meters. Runs as the unprivileged user.
#
# Each file is imported in its own transaction. Files are identified by
# SHA-256 content, so renaming or re-copying a file is harmless; the
# database also ignores byte-identical replays. A file that fails is not
# retried until its content changes.
set -Eeuo pipefail

# shellcheck source=docker/unraid/engy-common.sh
. /usr/local/lib/energy-ingest/engy-common.sh

: "${ENGY_RT_SOURCE_ID:?source ID is required}"
: "${ENGY_DB_URL:?database URL is required}"
interval="${ENGY_IMPORT_INTERVAL:-300}"
auto_attach="${ENGY_AUTO_ATTACH:-true}"
# Wait until a file has not changed for this long before importing it.
settle_seconds=15

imported_list="$ENGY_STATE_DIR/imported.sha256"
failed_list="$ENGY_STATE_DIR/failed.sha256"
touch "$imported_list" "$failed_list"

read -r -a meter_ids <<<"${ENGY_RT_METER_IDS:-}"

trap 'exit 0' TERM INT

attach_meters() {
    local meter output
    case "$auto_attach" in
        true|1|yes) ;;
        *) return 0 ;;
    esac
    for meter in "${meter_ids[@]}"; do
        # Refuses when more than one meter shares a commodity, and never
        # moves data that is already associated with another meter.
        if output="$(energy-store-admin meter attach-compatible \
            "$meter" --apply 2>&1)"; then
            printf '%s\n' "$output" | grep -E \
                '^(Meter profile|Already associated|Eligible to associate)' |
                while IFS= read -r line; do engy_log "  $line"; done
        else
            engy_log "WARNING: automatic meter association failed:"
            printf '%s\n' "$output" |
                while IFS= read -r line; do engy_log "  $line"; done
        fi
    done
}

import_pass() {
    local path name sum age output imported=0
    shopt -s nullglob
    for path in "$ENGY_IMPORT_DIR"/*.xml; do
        [ -f "$path" ] && [ ! -L "$path" ] || continue
        name="${path##*/}"
        age=$(( $(date +%s) - $(stat -c %Y -- "$path") ))
        [ "$age" -ge "$settle_seconds" ] || continue
        sum="$(sha256sum -- "$path" | cut -d' ' -f1)"
        if grep -Fxq -- "$sum" "$imported_list" ||
            grep -Fxq -- "$sum" "$failed_list"; then
            continue
        fi
        engy_log "Importing $name..."
        if output="$(energy-store-import --source-id "$ENGY_RT_SOURCE_ID" \
            "$path" 2>&1)"; then
            printf '%s\n' "$sum" >>"$imported_list"
            imported=1
            printf '%s\n' "$output" |
                while IFS= read -r line; do engy_log "  $line"; done
        else
            printf '%s\n' "$sum" >>"$failed_list"
            engy_log "WARNING: import failed for $name (will not retry"
            engy_log "  until the file changes):"
            printf '%s\n' "$output" |
                while IFS= read -r line; do engy_log "  $line"; done
        fi
    done
    return $(( imported == 1 ? 0 : 1 ))
}

engy_log "Watching $ENGY_IMPORT_DIR every ${interval}s for *.xml files."
# Associate anything left unassociated by an earlier run.
attach_meters
while :; do
    if import_pass; then
        attach_meters
    fi
    sleep "$interval" &
    wait $! || true
done
