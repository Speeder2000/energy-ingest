<!-- SPDX-License-Identifier: MIT -->

# Green Button electricity flow foundations

**Purpose:** Document foundational Green Button solar import/export handling, measurement-direction safeguards, and regression testing.

**Intended Audience:** Energy Ingest developers, contributors, and maintainers.

## Scope

Energy Ingest serves electricity consumption, electricity exported to the
grid (for example by solar panels on a net-metered meter), and natural gas
usage. Onsite solar *production* is not reported by the utility and is not
derived.

## Existing preservation

The Green Button parser and MariaDB `reading_type` already preserve
`flow_direction`. Accepted revisions and reading-type provenance are retained.
No database migration is needed for flow selection.

## Flow selection

A stream is resolved for one flow (`energy_store::EnergyFlow`):

- `delivered` (default): electricity with `flow_direction = 1` (forward),
  and all natural gas.
- `received`: electricity with `flow_direction = 19` (reverse, export).

Readings of the opposite known direction are excluded before resolution, so
a meter that has both a delivered and a received resource resolves both
streams. Exported kWh is never mixed into consumption, and the reverse.
Total (`20`), unspecified (`0`) and other electricity directions still
produce an explicit `unsupported_electricity_flow` issue in both flows; when
any issue exists the resolver returns no intervals for that window. Stored
readings are never deleted or reclassified.

The API selects a flow with `?flow=received` on the `validation`, `stream`,
`window` and `history/plan` endpoints; the CLI uses
`meter validate METER_ID --flow received`. See
[`CANONICAL_METER_VALIDATION.md`](CANONICAL_METER_VALIDATION.md).

### Export meter profiles

A physical meter profile records the flow it reports
(`physical_meter.flow_direction`, migration 0009): `1` (delivered, the
default) or `19` (received; electricity only, enforced by a check
constraint). A net-metered site can register its export as a second
electricity profile (`meter ensure CUSTODIAN 1 NAME --export`, or
`ENGY_SOLAR_EXPORT_METER_NAME` in the all-in-one image). Then:

- Requests without `flow` resolve the profile's own flow, so clients that
  read one stream per meter, such as the current Home Assistant
  integration, receive export from the export profile.
- An export profile accepts only resources whose reading type is
  `flowDirection = 19`, through both CLI and HTTP association.
- `meter attach-compatible` matches by commodity and flow. While an export
  profile exists, the delivered profile skips export resources. Export
  data already associated with the delivered profile is reported as a
  conflict and is never moved automatically; `meter detach` removes the
  association explicitly (ADR-0032).

Two profiles for one physical meter are a modelling convenience for
per-meter clients; the export profile does not represent separate
hardware. `flow=received` on the consumption profile remains available.

Verified with an SDG&E Green Button Download export (January to November
2026) containing 15-minute delivered and received channels; both resolve
without issues. That file is customer data and is not a repository fixture.

## Remaining follow-up

- Add source-derived and synthetic Green Button XML fixtures and tests
  for export gaps, updates, duplicate streams, and mixed cadence.
- Decide whether net (`20`) readings should be served as a third flow.
- The Home Assistant integration labels an export profile as electricity
  usage. Reading `flow` from `/v1/meters` would let it present the profile
  as grid return.
- Never synthesize missing observations or monetary sell-back amounts.
