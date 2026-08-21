- **The changelog gate no longer stops enforcing — while reporting success —
  when `VERSIONING.md` is absent** (temperloop#1494; epic #1620).
  `check-changelog-entry.sh` probes three files it needs, and two of them
  already discriminated an absent input from a clean one: no `CHANGELOG.md` and
  no `changelog.d/` each **fail loudly** in a tree carrying no `.kernel-pin`
  (the kernel's own checkout, which has lost one of its own files) and skip
  **legibly** in a tree that has one (a vendoring consumer that genuinely keeps
  neither). The `VERSIONING.md` probe was the odd one out: a bare
  `say "skipped …"; exit 0`, taken regardless of the pin.

  That is the "quietly narrows to zero" failure the script's own header refuses
  twice, applied to the one file whose absence causes it most directly.
  `VERSIONING.md § The contract surface` is the table this gate **parses** to
  decide what a PR owes a changelog entry for — it *is* the enforced surface
  set. Rename, move or lose that file in the kernel's own checkout and the set
  is empty, so every PR passes property (1) by default while the gate prints a
  skip and exits 0.

  The probe now carries the siblings' `.kernel-pin` discriminator verbatim in
  shape: **absent and unpinned FAILS** (naming the missing file, the
  discriminator, why an empty surface set is not a pass, and how to restore or
  repoint it); **absent and pinned still skips**, now naming the pinned kernel
  tag the way its two siblings do. The pinned arm is load-bearing, not a
  hedge — a composed overlay checkout legitimately carries no `VERSIONING.md`
  at its repo root, since it does not run the kernel's release workflow there,
  and breaking that layout was the one thing this fix had to avoid.

  Two cases pin the pair (36, 37), and both fail against the previous
  implementation: the unpinned tree exited 0 with `skipped —` where it now
  exits 1.
