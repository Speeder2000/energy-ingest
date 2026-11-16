<!-- AI provenance: annotated 2026-10-08; origin not asserted. -->

# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Added

- All-in-one container image for Unraid (`docker/Dockerfile.unraid`,
  published as `ghcr.io/speeder2000/energy-ingest-unraid` for amd64 and
  arm64) with embedded MariaDB, environment-only configuration, automatic
  schema bootstrap, utility and meter registration, API token provisioning,
  folder-based XML import and automatic matching to one meter per type. See
  `docs/INSTALL_UNRAID.md` and the template in `deploy/unraid/`.
- Solar export: the API `validation`, `stream`, `window` and
  `history/plan` endpoints accept `?flow=received` to serve electricity
  exported to the grid, and `meter validate` accepts `--flow received`.
  Consumption remains the default. Previously, a net-metered (NEM) meter's
  export channel made its whole consumption stream unresolved; it is now
  excluded from consumption and served separately. Ambiguous (net)
  electricity flows are still reported as issues.
- Hourly presentation: `stream` and `window` accept `?resolution=hour` to
  sum sub-hour (for example 15-minute) readings into complete UTC hours;
  incomplete hours are omitted, never estimated. `ENGY_API_DEFAULT_RESOLUTION`
  sets the server default; the all-in-one image defaults to `hour`, because
  the Home Assistant integration rejected 15-minute electricity data with
  "Incompatible utility reading".
- Solar export meters: `meter ensure CUSTODIAN 1 NAME --export` (or
  `ENGY_SOLAR_EXPORT_METER_NAME` in the all-in-one image) registers an
  export profile whose streams default to received energy. Automatic
  matching sends export data to it, so per-meter clients such as the Home
  Assistant integration import solar export without changes.
  `GET /v1/meters` reports each meter's `flow`. Adds migration 0009
  (`physical_meter.flow_direction`) and `meter detach` for explicitly
  moving data that was associated with the wrong meter.
- Idempotent `custodian ensure` and `meter ensure` administration commands
  for unattended registration.

- Authenticated resource-association responses include the canonical
  Green Button commodity code, allowing clients to present only compatible
  physical meters without guessing from filenames or resource IDs.

### Verification

- The maintainer reported 214 passing tests in the isolated Docker test
  environment on November 2, 2026. The feature remains unreleased.

## 0.1.8 — 2026-10-30

### Added

- Authenticated acquisition-source API responses now include
  `utility_company`, resolved from the registered data custodian.
- Rust dependency auditing in CI and the pre-push workflow.
- Docker Hub publication verification for the expected image digest and
  both `linux/amd64` and `linux/arm64` platforms.
- A GitHub Actions publication summary emitted only after verification.

### Verification

- 209 tests passed in the isolated Docker verification environment.
- RustSec dependency audit completed without reported vulnerabilities.
- PR #31 passed CI and secret scanning and was merged into `main`.
- GitHub release `energy-ingest-v0.1.8` was verified as published on
  November 3, 2026. Docker Hub manifests and production deployment were
  not independently reverified during this documentation update.
