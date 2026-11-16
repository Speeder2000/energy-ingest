#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Administration inside the running all-in-one container, for example:
#
#   docker exec energy-ingest engy-admin meter list
#   docker exec energy-ingest engy-admin stream analyze
#   docker exec energy-ingest engy-admin api-token list
#   docker exec energy-ingest engy-admin import --source-id 1 /imports/x.xml
#   docker exec -i energy-ingest engy-admin meter set-number 2 --stdin
#
# Uses the restricted application account; schema changes are not possible.
set -euo pipefail

# shellcheck source=docker/unraid/engy-common.sh
. /usr/local/lib/energy-ingest/engy-common.sh

ENGY_DB_NAME="${ENGY_DB_NAME:-energy_ingest}"
ENGY_DB_USER="${ENGY_DB_USER:-energy_ingest}"

case "${1:-}" in
    ''|-h|--help)
        exec energy-store-admin --help
        ;;
    database)
        engy_die 'schema bootstrap runs automatically at container start'
        ;;
    api-token)
        shift
        engy_as_app energy-api-token "$@"
        ;;
    import)
        shift
        engy_as_app energy-store-import "$@"
        ;;
    *)
        engy_as_app energy-store-admin "$@"
        ;;
esac
