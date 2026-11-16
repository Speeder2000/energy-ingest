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
