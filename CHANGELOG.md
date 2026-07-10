# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/). See
[`VERSIONING.md`](VERSIONING.md) for the canonical bump rules and what each
tier signals.

Pre-1.0, the breaking signal rides the CHANGELOG, not the version number: a
release that changes the contract surface in a way an overlay must adapt to
**tags its section `BREAKING`** and includes a migration note. `update-kernel`
reads that marker; a stranger greps for it before pulling.

## [Unreleased]

Additive — the D1 config precedence ladder (temperloop#164/#169). **Contract
surface grows: a new optional machine-conf rung, an existing bug fixed.**
Deliberately **not** tagged `BREAKING` (nothing existing changes shape).

### Added

- A new **machine conf** rung in `build.config.sh`'s config precedence
  ladder: an optional `$XDG_CONFIG_HOME/temperloop/build.config.sh`, sourced
  before any checkout-local override, for a host-wide knob override that
  applies across every checkout on that host. Template:
  `workflows/scripts/build/build.config.machine.sh.example`. The full
  six-rung ladder (CLI flag > env var > machine conf > untracked repo-local
  conf > tracked repo conf > kernel built-in default) is documented in the
  new [`docs/config-precedence.md`](docs/config-precedence.md).

- The **kernel knob registry** (temperloop#164/#169, design decision D2): a
  new grep/cut-parseable `workflows/scripts/config/knob-registry.tsv`
  cataloging every existing tunable knob (162 rows) with its current shell
  default, plus `workflows/scripts/config/knob-registry-lib.sh`, a
  union-aware parse helper that reads the kernel table and unions an
  optional overlay extension TSV when present (mirroring
  `validate-live-drain.sh`'s kernel-table + overlay-extension pattern). A
  reserved `TEMPERLOOP_PROFILE` row (not yet read anywhere) holds the name
  for a later profile mechanism. This is populate-only: no caller routes
  through the registry yet, and no equality lint exists yet (a later item,
  registry-config-lints).

### Fixed

- `build.config.local.sh` (and its `.example` template) now use the `:=`
  set-only-if-unset idiom instead of plain assignments. Previously, because
  `build.config.sh` sourced it LAST with plain assignments, a value set in
  `build.config.local.sh` could silently beat an exported environment
  variable — inverting the intended precedence. Fixed together with
  reordering `build.config.sh` to source its conf-file rungs before applying
  its own built-in defaults, so source order now matches precedence order
  end to end.

