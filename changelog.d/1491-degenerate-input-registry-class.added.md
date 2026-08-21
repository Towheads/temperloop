- **The degenerate-input check-surface registry stopped being opt-in: an
  unregistered check surface is now detected, not silently unchecked**
  (temperloop#1491). `validate-check-surface-degenerate-coverage.sh` gained a
  §5 **discovery pass** that enumerates the candidate set MECHANICALLY from
  the tree — every tracked file whose basename matches this repo's three
  check-script name families (`validate-*.sh`, `check-*.sh`, `lint-*.sh`),
  with `tests/`/`fixtures/`/`node_modules/` and a composed overlay's vendored
  `kernel/` pruned — and fails `UNREGISTERED-SURFACE` on any candidate that
  is in none of its three legal homes: the registry, the shrink-only
  allowlist, or the new `check-surface-discovery.tsv` disposition ledger.
  Silence is no longer a disposition. The ledger's `pending` set carries its
  own shrink-only ratchet (`PENDING-GREW`), so a newly discovered surface
  cannot be parked behind a one-line excuse instead of registered, and an
  enumeration that finds nothing fails `EMPTY-DISCOVERY` rather than passing
  vacuously. The registry's bulk growth — 4 registered surfaces to 21, with
  51 new fixtures in
  `workflows/scripts/tests/test_check_surface_degenerate_backfill.sh` — is
  the assertion's first OUTPUT, not the fix: a longer hand-written list is
  still a list somebody sampled. Of the 37 surfaces the enumeration found, 17
  carry a reasoned non-registration, three of them recording a MEASURED
  fail-open (`check-setting-prose.sh`, `check-gitleaks-kernel.sh`,
  `check-producer-egress.sh` each reported success on absent/unreadable/empty
  input) that needs its own fix before it can be registered.
