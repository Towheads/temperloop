- **`differential-guard-vs-ref.sh` no longer fails on clean `main`** — the
  write-jail differential harness is a `KERNEL_GATES` entry, and two of its
  declared relaxations had gone stale, taking the gate (and so every `checks`
  run on `main`) red: `2 REGRESSIONS` reported against a tree with no
  regression in it. A `probe_ratified` entry asserts a DENY→allow *delta*
  between the working copy and the ref; once that relaxation merges there is no
  delta left to assert, and the harness correctly flags the entry as a stale
  ratification. Both entries — the glued trailing `;` on a device sink
  (temperloop#1974) and a write to the harness's own `$HOME/.claude/plans`
  (temperloop#1975) — are retired to plain `probe` calls pinning the allow,
  exactly as the foundation#1354 placeholder exemption was retired before them,
  with each original rationale kept as a comment because the claim outlives the
  delta. No coverage is lost: both behaviours stay pinned in both polarities by
  the ALLOW/DENY corpus in `test_build_worktree_guard.sh`. The harness now
  reports `100 same, 0 tightened, 0 ratified, 0 REGRESSIONS`, and carries no
  live `probe_ratified` entries — a relaxation earns one only while it is a real
  working-copy-vs-ref delta, and loses it the moment it lands.
