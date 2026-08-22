- **`worktree.sh` no longer destroys work that preservation failed to capture**
  (#1730). #1729 taught both destroying primitives to preserve unlanded work to
  a local-only `refs/parked/*` ref first — but each then ran
  `preserve_unlanded … || true` and destroyed **unconditionally**, so the guard
  only ever protected the happy path: on `capture-failed:snapshot`,
  `capture-failed:no-commit`, `capture-failed:ref-mint` or
  `unclassifiable:no-default-branch` the worktree was force-removed and
  `build/<slug>` was `git branch -D`'d with **nothing captured**.

  `preserve_unlanded`'s **return value is now the destruction gate**: `0` means
  the loss window is closed (nothing to preserve, not needed, or preserved),
  non-zero means preservation was needed and failed. The `|| true` is gone from
  both call sites, and the two callers deliberately **diverge**, because their
  constraints do:

  - **`remove` refuses.** A leaked worktree is recoverable by hand; a
    force-deleted branch is not. It now emits
    `{"outcome":"REMOVE_REFUSED", …}` carrying the verbatim `preserved_detail`
    and the **still-standing** path, exits **non-zero**, and destroys nothing.
  - **`create` sidelines and still `CREATED`s.** A refusing `create` would turn
    `/build`'s prelude batch from *created* into *escalated*, so instead of
    destroying, the un-preservable occupant is **moved aside** — `git worktree
    move` to `<path>.unpreserved-<sha8>`, `git branch -m` to
    `<branch>.unpreserved-<sha8>` — which frees the deterministic path for a
    fresh worktree. The work survives **and** `create` still returns `CREATED`,
    with the verdict riding that line as the new
    `sidelined` / `sidelined_path` / `sidelined_branch` **fields** (never a new
    `outcome` string — `SPINE_OUTCOME_SCHEMA` is a closed enum).

  **`prune` owns the sidelined worktree's disposal**, reporting it as
  `SIDELINED_WT` / `SIDELINED_WT_REAPED` on the same two-gate contract it
  already applies to a preservation ref: ancestry of `origin/<default>` **or** a
  terminal (CLOSED) originating issue, with an unevaluable check treated as
  FALSE, an OPEN issue never reaped, a dirty tree never passing the ancestry
  gate, and `--force` deliberately not plumbed in. The outcome strings stay
  distinct from `PRUNED` so `deploy-mini.sh`'s counter is unaffected.

  `workflows/scripts/build/tests/test_worktree.sh` extends #1729's cases with
  the failure path: `remove`'s refusal is asserted against **each** of the four
  capture-failure details (worktree *and* branch intact, named outcome, verbatim
  detail, standing path, non-zero exit), `create`'s sideline is asserted to leave
  the prior work recoverable at both halves while still returning `CREATED`, the
  `prune` gates are asserted in all three dispositions, and an activation check
  asserts the `|| true` is gone from both destroying primitives.
