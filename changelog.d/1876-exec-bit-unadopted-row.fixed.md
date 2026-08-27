- **The exec-bit registry gate no longer fails a vendoring consumer for kernel
  rows naming content that consumer never adopted** (#1876). A consumer adopts
  a SUBSET of the kernel's hooks and scripts by design, so `claude/hooks/` in
  a downstream tree carries compat symlinks only for what it actually
  installed. `workflows/scripts/validate-exec-bit-registry.sh` inherited the
  registry+allowlist design from
  `validate-check-surface-degenerate-coverage.sh` but not the unadopted-row
  tolerance added to it in #1740, so the v0.37.0 vendor bump was red on
  arrival on 5 of 28 registered paths. It now tolerates such a row when
  **both** hold: the repo is a vendoring consumer (a repo-root `.kernel-pin`),
  **and** the row came from a kernel-owned source file. Each tolerated row is
  reported as a `note: … skipped (temperloop#1876)` line — never silently
  dropped.
- **`exec-bit-registry.overlay.tsv` is the new overlay-extension seam for the
  same gate** (#1876). A consumer's own directly-executable scripts now have a
  home that a subtree pull cannot overwrite, matching the
  `<base>.overlay.<ext>` seam `check-surface-registry.overlay.tsv` (#1738) and
  `setting-registry.overlay.tsv` already use. It is absent in a kernel-only
  checkout and its absence is never an error; an unreadable one is CANNOT
  EVALUATE rather than a silent pass. This is also what makes the tolerance's
  second condition real rather than vacuous: an overlay-authored row naming an
  absent path is genuine ledger rot and still fails `PATH-NOT-FOUND`, even
  under a `.kernel-pin`. The grandfather allowlist deliberately gets no
  overlay twin — it is a shrink-only ratchet, and an overlay copy would be a
  hole straight through it.
- **`PATH-NOT-FOUND` now carries a remediation line naming the adopted-subset
  case** (#1876), and explicitly warns off symlinking kernel content into a
  consumer to satisfy a row. That is the wrong remedy, and the analogous
  `WATERMARK-NOT-TRACKED` wording walked an operator straight into it — see
  temperloop#1840 for that incident.
