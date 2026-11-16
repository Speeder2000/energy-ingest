<!-- SPDX-License-Identifier: MIT -->

# Install on Unraid (single container)

**Purpose:** Run Energy Ingest on Unraid, or any Docker host, as one
container with an embedded MariaDB database, configured only through
environment variables and with no interactive setup scripts.

**Intended Audience:** Unraid users and home-lab operators.

## What the container does

The image `ghcr.io/speeder2000/energy-ingest-unraid` (linux/amd64 and
linux/arm64) does the following on every start. Each step is idempotent:

1. Applies `PUID`/`PGID` and `TZ`.
2. Generates database credentials on first start and keeps them in
   `/config/secrets`. They are never rotated automatically.
3. Initializes MariaDB in `/config/mysql` on first start, then starts it
   bound to `127.0.0.1` inside the container. Port 3306 is never published.
4. Re-applies database accounts and grants. The runtime account can only
   read and write rows. A separate migration account owns schema changes.
   MariaDB `root` has no password and is reachable only from inside the
   container as root.
5. Applies pending schema migrations (`database bootstrap`).
6. Registers the utility, import source and meters named in the
   configuration, unless they already exist.
7. Starts the authenticated API and creates a Home Assistant token on first
   start, or when the saved token no longer works.
8. Imports new `*.xml` files from `/imports` and matches imported data to the
   configured meters.

If the database or the API stops, the container exits so that Docker's
restart policy can restart it.

## Install

### From the template

1. In Unraid, open **Docker → Add Container** and enter this template URL:
   `https://raw.githubusercontent.com/Speeder2000/energy-ingest/main/deploy/unraid/energy-ingest.xml`.
2. Set **Utility name**, the meter names, and **Time zone**.
3. Apply. The first start takes about a minute while MariaDB initializes.

The template sets `--stop-timeout=60`. Keep it, because Docker's default
10 seconds can interrupt the database shutdown.

### With `docker run`

```bash
docker run -d --name energy-ingest \
  --restart unless-stopped --stop-timeout 60 \
  -p 8080:8080 \
  -e TZ=America/Los_Angeles -e PUID=99 -e PGID=100 \
  -e ENGY_UTILITY_NAME='SDG&E' \
  -e ENGY_ELECTRIC_METER_NAME='Home Electric' \
  -e ENGY_GAS_METER_NAME='Home Gas' \
  -v /mnt/user/appdata/energy-ingest:/config \
  -v /mnt/user/appdata/energy-ingest/imports:/imports:ro \
  ghcr.io/speeder2000/energy-ingest-unraid:latest
```

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `TZ` | UTC (with warning) | Utility time zone. Natural gas daily totals use local time, so set it. |
| `PUID` / `PGID` | `99` / `100` | Owner of `/config` files, and the account MariaDB and the API run as. Must not be 0. |
| `ENGY_UTILITY_NAME` | unset | Utility name, for example `SDG&E`. Without it, registration and folder import are skipped, and only the API runs. |
| `ENGY_SOURCE_NAME` | `Green Button Download` | Import source label. |
| `ENGY_ELECTRIC_METER_NAME` | unset | Electricity meter. Solar (NEM) delivered and received channels both belong to this meter. |
| `ENGY_ELECTRIC_METER_NUMBER` | unset | Optional utility meter number. Stored in the database; never logged. |
| `ENGY_SOLAR_EXPORT_METER_NAME` | unset | Solar export meter, for electricity your panels send back to the grid. Requires `ENGY_ELECTRIC_METER_NAME`. See [Solar export](#solar-export). |
| `ENGY_GAS_METER_NAME` | unset | Natural gas meter. |
| `ENGY_GAS_METER_NUMBER` | unset | Optional utility meter number. |
| `ENGY_AUTO_ATTACH` | `true` | Match imported data to the meter of the same type. |
| `ENGY_IMPORT_INTERVAL` | `300` | Seconds between checks of `/imports` (minimum 30). |
| `ENGY_API_CLIENT_NAME` | `home-assistant` | Name recorded for the generated API token. |
| `ENGY_API_PORT` | `8080` | API port inside the container. |
| `ENGY_API_DEFAULT_RESOLUTION` | `hour` | `hour` sums 15-minute utility readings into complete hours, which the Home Assistant integration requires; an hour with a missing reading is left out, never estimated. `native` serves readings as supplied. Clients can override it per request with `?resolution=`. |
| `ENGY_DB_NAME` / `ENGY_DB_USER` | `energy_ingest` | Embedded database and runtime account names. |
| `ENGY_DB_PASSWORD`, `ENGY_DB_ADMIN_PASSWORD` | generated | Optional overrides. If you set them, the database account is updated to match on the next start. |

Each secret, including both meter numbers and both database passwords, can
instead be read from a file named by the same variable with `_FILE`
appended, for example `ENGY_DB_PASSWORD_FILE=/run/secrets/db`. Generated
values are preferred, because values in plain environment variables are
visible through `docker inspect`.

Changing `ENGY_DB_NAME` or `ENGY_DB_USER` later starts an empty database.
Changing the utility or a meter name registers a new record; existing
records are not renamed.

### Meters

This image assumes at most **one meter per type**: one electricity meter,
optionally one solar export meter, and one natural gas meter. With
`ENGY_AUTO_ATTACH=true`, imported data is matched to the meter of the same
type when the container starts and after each import. Matching is refused,
with a log message, when more than one meter of a type is registered, or
when data already belongs to another meter. Data of a type with no
configured meter stays unmatched and does not appear in Home Assistant
until you add that meter.

### Solar export

A solar (NEM) electricity meter reports two channels: energy taken from the
grid and energy sent back to it. Without `ENGY_SOLAR_EXPORT_METER_NAME`,
both channels belong to the electricity meter; Home Assistant receives
consumption, and API clients can request export with `?flow=received`.

Set `ENGY_SOLAR_EXPORT_METER_NAME`, for example `Home Solar Export`, to
register export as its own meter. Each meter then serves one stream by
default, so the Home Assistant integration imports export without changes.
In Home Assistant's Energy Dashboard, choose the electricity meter for
**Grid consumption** and the solar export meter for **Return to grid**.
The export meter is labeled as electricity in the integration; it holds
only exported energy.

If export data was already imported to the electricity meter before you
set the variable, the log shows a matching warning that names the IDs.
Move the export data once, then restart the container:

```bash
docker exec energy-ingest engy-admin meter list
docker exec energy-ingest engy-admin meter detach ELECTRIC_METER_ID RESOURCE_ID
```

To check either stream:

```bash
docker exec energy-ingest engy-admin meter validate METER_ID
```

## Import Green Button XML

Copy `*.xml` exports from your utility into the imports share. Within the
check interval, the container:

- waits until a file has not changed for 15 seconds;
- imports it in its own transaction (a failure rolls back that file only);
- matches the new data to your meters; and
- records the file's SHA-256 so it is not processed again.

Renaming or copying the same file again is harmless. A file that fails is
not retried until its content changes; check `docker logs energy-ingest`.
Original files are never modified, and you may delete them after import.

## Connect Home Assistant

The token is created on first start and is **not** printed to the logs.
Read it from appdata:

```bash
cat /mnt/user/appdata/energy-ingest/secrets/api_token
```

Configure the `ha_energy_usage` integration with
`http://UNRAID_IP:8080` and that token. The API uses plain HTTP, so keep
it on a trusted LAN and never forward the port from your router.

## Administration

Run administration commands inside the container with `engy-admin`. It
uses the restricted runtime account:

```bash
docker exec energy-ingest engy-admin meter list
docker exec energy-ingest engy-admin stream analyze --details
docker exec energy-ingest engy-admin meter validate METER_ID
docker exec energy-ingest engy-admin meter detach METER_ID RESOURCE_ID
docker exec energy-ingest engy-admin api-token list
docker exec energy-ingest engy-admin api-token create another-client
```

To set a meter number without putting it in the container configuration:

```bash
docker exec -i energy-ingest engy-admin meter set-number METER_ID --stdin
```

To issue a new Home Assistant token, delete
`/config/secrets/api_token` and restart the container. Revoke the old
client with `engy-admin api-token revoke CLIENT_ID`.

## Backup, restore and upgrade

All state is in `/config`. Back it up while the container is **stopped**,
for example with the Unraid appdata backup plugin. Copying a running
database's files is not safe. For an online backup:

```bash
docker exec energy-ingest sh -c \
  'mariadb-dump --protocol=socket -uroot --single-transaction energy_ingest' \
  > energy_ingest.sql
```

Restore by putting the `/config` backup back in place, with the same
`PUID`/`PGID`, and starting the container.

To upgrade, pull the new image and recreate the container. Schema
migrations and MariaDB system-table upgrades run automatically at start.
Use a version tag instead of `latest` if you want to choose when to upgrade.

## Differences from the Compose deployment

The [Compose deployment](INSTALL_LINUX.md) runs MariaDB as a separate
container and is set up with the interactive `setup-prod.sh` and
`energy-import.sh` scripts. This image replaces those scripts with
environment configuration, and its meter matching assumes one meter per
type. Both use the same application binaries, migrations and API. Their
data is not shared automatically.

## Troubleshooting

- **Container restarts repeatedly:** run `docker logs energy-ingest`. An
  `ERROR:` line names the failed step. Credentials and data are never reset
  automatically.
- **`unknown TZ`:** use a name from the IANA time zone database, such as
  `America/Los_Angeles`.
- **Imports never happen:** check that `ENGY_UTILITY_NAME` is set and that
  the imports folder is readable by `PUID`.
- **Data imported but not in Home Assistant:** run
  `docker exec energy-ingest engy-admin meter list`. A meter whose resource
  count is 0 has no matched data; check the logs for matching messages.
