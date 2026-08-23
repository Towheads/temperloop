- **`validate-mandatory-step-signal.sh`'s pending ratchet now reads a
  symlinked ledger's *content* instead of its link target.** In a composed
  overlay the disposition ledgers are compat symlinks into the vendored
  `kernel/` subtree, and `git show <ref>:<symlink-path>` returns the link's
  target text — while exiting 0, so the script's `|| fallback` never fired. The
  base-ref side parsed to zero rows, every current `pending` row read as newly
  added, and the shrink-only ratchet false-failed on every run. The gate broke
  **on merge, not in the PR that introduced it**: the vendor that created the
  symlinks hit the bootstrap exemption and went green, and the exemption stopped
  applying once it landed — which took `foundation`'s `main` red and blocked
  every PR there. Both path seams are now physicalized before the ratchet math,
  and the vendored-kernel subtree arm from
  `validate-check-surface-degenerate-coverage.sh` (temperloop#1559) is ported
  across, so an upstream-owned row also passes when present in the kernel
  subtree's own pulled content. #1559 had fixed exactly this in one of the two
  sibling ratchets and not the other. The shrink-only intent is unchanged: a
  genuinely new `pending` row through a symlinked ledger still fails, and an
  unreachable subtree squash degrades fail-closed with an announced notice
  rather than reading as fully checked. Four regression cases cover the
  symlinked-ledger path, which the previous suite could not see because every
  fixture used a real file.
