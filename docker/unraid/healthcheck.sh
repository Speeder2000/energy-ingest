#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Container health: embedded MariaDB answers and the API health probe is OK.
set -euo pipefail

mariadb-admin --protocol=socket --user=root ping --silent >/dev/null 2>&1
curl -fsS -o /dev/null --max-time 5 \
    "http://127.0.0.1:${ENGY_API_PORT:-8080}/healthz"
