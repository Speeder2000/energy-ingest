#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Smoke test for the all-in-one (Unraid) image using sanitized fixtures.
# Starts the container unattended, waits for health, verifies folder import,
# meter association, API authentication, least privilege, restart
# idempotency and clean shutdown. Uses only temporary directories.
#
# Usage: scripts/test-unraid-image.sh [IMAGE]
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-${ENGY_TEST_IMAGE:-energy-ingest-unraid:test}}"
FIXTURES="$ROOT/profiles/sdge/fixtures"
NAME="engy-aio-test-$(openssl rand -hex 4)"
WORK="$(mktemp -d)"
TEST_UID=4242
TEST_GID=4242

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        printf '\n--- container logs ---\n' >&2
        docker logs "$NAME" >&2 2>&1 || true
    fi
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    # Files are owned by the test UID; remove them from inside a container.
    docker run --rm --entrypoint rm -v "$WORK:/work" "$IMAGE" \
        -rf /work/config /work/imports >/dev/null 2>&1 || true
    rm -rf -- "$WORK" 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
in_ctr() { docker exec "$NAME" "$@"; }

wait_healthy() {
    local state
    for _ in $(seq 1 120); do
        state="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" \
            2>/dev/null || echo missing)"
        [ "$state" = healthy ] && return 0
        [ "$state" = unhealthy ] && return 1
        docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null |
            grep -qx true || return 1
        sleep 3
    done
    return 1
}

api_code() {
    local path="$1" auth="${2:-}"
    if [ -n "$auth" ]; then
        in_ctr sh -c 'printf "Authorization: Bearer %s\n" \
            "$(cat /config/secrets/api_token)" >/tmp/h && \
            curl -s -o /dev/null -w "%{http_code}" -H @/tmp/h \
            "http://127.0.0.1:8080'"$path"'"; rm -f /tmp/h'
    else
        in_ctr curl -s -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:8080$path"
    fi
}

proc_uid() {
    in_ctr sh -c 'for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = "'"$1"'" ] || continue
        awk "/^Uid:/ {print \$2}" "$p/status"; exit 0
    done; exit 1'
}

docker image inspect "$IMAGE" >/dev/null || fail "image not found: $IMAGE"

mkdir -p "$WORK/config" "$WORK/imports"
cp "$FIXTURES/sdge-electric-one-day-hourly.xml" \
    "$FIXTURES/sdge-gas-one-day.xml" "$WORK/imports/"
# Synthetic solar export channel: the hourly fixture's readings as a second
# meter reading that uses the fixture's received (flowDirection 19) type.
sed -e 's#MeterReading/01#MeterReading/02#g' \
    -e 's#ReadingType/0701" rel="related"#ReadingType/0702" rel="related"#' \
    "$FIXTURES/sdge-electric-one-day-hourly.xml" \
    >"$WORK/imports/synthetic-electric-export.xml"
# Older than the import loop's settle time so the first pass picks them up.
touch -d '2 minutes ago' "$WORK/imports/"*.xml

docker run -d --name "$NAME" \
    --stop-timeout 60 \
    -e TZ=America/Los_Angeles \
    -e PUID="$TEST_UID" -e PGID="$TEST_GID" \
    -e ENGY_UTILITY_NAME='SDG&E (test)' \
    -e ENGY_ELECTRIC_METER_NAME='Home Electric' \
    -e ENGY_ELECTRIC_METER_NUMBER='TEST-ELECTRIC-0001' \
    -e ENGY_SOLAR_EXPORT_METER_NAME='Home Solar Export' \
    -e ENGY_GAS_METER_NAME='Home Gas' \
    -e ENGY_IMPORT_INTERVAL=30 \
    -v "$WORK/config:/config" \
    -v "$WORK/imports:/imports:ro" \
    "$IMAGE" >/dev/null

wait_healthy || fail 'container did not become healthy'
pass 'container healthy on first start'

[ "$(api_code /healthz)" = 204 ] || fail 'health probe'
[ "$(api_code /v1/meters)" = 401 ] || fail 'anonymous request not rejected'
[ "$(api_code /v1/meters auth)" = 200 ] || fail 'token request rejected'
pass 'API health, authentication and generated token'

associated=false
for _ in $(seq 1 40); do
    list="$(in_ctr engy-admin meter list 2>/dev/null || true)"
    electric="$(printf '%s\n' "$list" | awk '/Home Electric/ {print $NF}')"
    gas="$(printf '%s\n' "$list" | awk '/Home Gas/ {print $NF}')"
    export_count="$(printf '%s\n' "$list" |
        awk '/Home Solar Export/ {print $NF}')"
    if [ "${electric:-0}" -gt 0 ] && [ "${gas:-0}" -gt 0 ] &&
        [ "${export_count:-0}" -gt 0 ]; then
        associated=true
        break
    fi
    sleep 3
done
[ "$associated" = true ] || fail "imports not associated: $list"
pass 'folder import and automatic meter association'

# Each electricity meter holds one direction and serves it by default.
printf '%s\n' "$list" | grep -Eq 'Home Electric +Electricity +delivered +1$' ||
    fail "consumption meter did not get exactly its channel: $list"
printf '%s\n' "$list" |
    grep -Eq 'Home Solar Export +Electricity +received +1$' ||
    fail "export meter did not get exactly its channel: $list"
export_id="$(printf '%s\n' "$list" | awk '/Home Solar Export/ {print $1}')"
electric_id="$(printf '%s\n' "$list" | awk '/Home Electric/ {print $1}')"
for meter in "$electric_id" "$export_id"; do
    in_ctr engy-admin meter validate "$meter" | grep -qx 'Status: validated' ||
        fail "meter $meter stream not validated"
done
in_ctr engy-admin meter validate "$export_id" | grep -qx 'Flow: received' ||
    fail 'export meter does not default to received'
[ "$(api_code "/v1/meters/$export_id/validation?flow=net" auth)" = 400 ] ||
    fail 'invalid flow accepted'
pass 'solar export meter matched and served as received by default'

[ "$(proc_uid mariadbd)" = "$TEST_UID" ] || fail 'MariaDB runs as wrong UID'
[ "$(proc_uid energy-api)" = "$TEST_UID" ] || fail 'API runs as wrong UID'
owner="$(in_ctr stat -c %u:%g /config/mysql /config/secrets/api_token |
    sort -u)"
[ "$owner" = "$TEST_UID:$TEST_GID" ] || fail "unexpected owner: $owner"
mode="$(in_ctr stat -c %a /config/secrets/db_password)"
[ "$mode" = 600 ] || fail "secret mode $mode"
pass 'PUID/PGID applied to processes and /config'

# 3306 (0CEA) may listen only on 127.0.0.1 (0100007F).
if in_ctr sh -c "awk 'NR>1 && \$4==\"0A\" {print \$2}' \
    /proc/net/tcp /proc/net/tcp6" | grep ':0CEA$' |
    grep -v '^0100007F:0CEA$' | grep -q .; then
    fail 'MariaDB listens beyond loopback'
fi
pass 'MariaDB bound to loopback only'

if in_ctr sh -c 'MYSQL_PWD="$(cat /config/secrets/db_password)" \
    mariadb -h127.0.0.1 -uenergy_ingest energy_ingest \
    -e "CREATE TABLE should_fail (id INT)"' >/dev/null 2>&1; then
    fail 'runtime account can change the schema'
fi
pass 'runtime database account cannot change the schema'

[ "$(in_ctr date +%Z)" != UTC ] || fail 'TZ was not applied'
pass 'time zone applied'

token_before="$(in_ctr sha256sum /config/secrets/api_token)"
secret_before="$(in_ctr sha256sum /config/secrets/db_password \
    /config/secrets/db_admin_password)"
imports_before="$(in_ctr wc -l /config/state/imported.sha256)"

docker restart -t 60 "$NAME" >/dev/null
wait_healthy || fail 'container did not become healthy after restart'
[ "$(in_ctr sha256sum /config/secrets/api_token)" = "$token_before" ] ||
    fail 'API token rotated on restart'
[ "$(in_ctr sha256sum /config/secrets/db_password \
    /config/secrets/db_admin_password)" = "$secret_before" ] ||
    fail 'database credentials changed on restart'
[ "$(api_code /v1/meters auth)" = 200 ] || fail 'token invalid after restart'
sleep 5
[ "$(in_ctr wc -l /config/state/imported.sha256)" = "$imports_before" ] ||
    fail 'files were imported again after restart'
[ "$(in_ctr engy-admin meter list | grep -c 'Home ')" = 3 ] ||
    fail 'meters duplicated after restart'
pass 'restart preserves credentials, token, imports and meters'

docker stop -t 60 "$NAME" >/dev/null
logs="$(docker logs "$NAME" 2>&1)"
printf '%s\n' "$logs" | grep -q 'Stopped (status 0)' ||
    fail 'entrypoint did not stop cleanly'
printf '%s\n' "$logs" | grep -qi 'shutdown complete' ||
    fail 'MariaDB did not report a clean shutdown'
if printf '%s\n' "$logs" | grep -Eq 'TEST-ELECTRIC-0001|ei_[A-Za-z0-9_-]{8}'; then
    fail 'meter number or API token appeared in logs'
fi
pass 'clean shutdown; no secrets in logs'

printf '\nAll-in-one image checks passed.\n'
