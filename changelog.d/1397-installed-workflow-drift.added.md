- **`make doctor` now detects when the INSTALLED `~/.claude/workflows/*.mjs`
  has drifted from the checkout's own `claude/workflows/*.mjs`, instead of
  leaving it discoverable only by hand-diffing the two** (temperloop#1397).
  `/build` Step 3, `/sweep` Step 0.3 and `/fix` Step 3 all invoke the
  orchestrator by `scriptPath` at `"$HOME/.claude/workflows/build-level.mjs"`,
  so the INSTALLED copy is what executes — not the one being edited. Nothing
  compared them. Two live reproductions: 2026-08-10 (installed 153,468 bytes
  dated Aug 7 vs a repo copy of 169,056, 154 commits of machinery that never
  ran) and 2026-08-21, when an entire overnight run executed a six-day-stale
  orchestrator — including the batches that merged temperloop#1587's
  escalation-payload fix, whose payloads still showed the pre-fix
  contradiction because the installed copy never changed. Both were caught
  only because a session happened to diff by hand first. The existing surfaces
  structurally could not see it: `classify_entry()` compares a symlink's
  TARGET STRING and `check_cross_checkout_split()` compares PATH IDENTITY, so
  a correctly-targeted path whose CONTENT is weeks stale reads `OK` in both.
  The new `check_installed_workflow_drift()` compares CONTENT by sha256 (byte
  compare when no hasher is on PATH) and reports five distinct outcomes:
  `OK` (byte-identical, digest shown); `DRIFT`, which prints BOTH sizes, BOTH
  mtimes and BOTH digests, names which side is NEWER and by how much, and
  names the physical directory the installed copy really lives in; `ABSENT`,
  printed as its own outcome and explicitly neither drift nor in-sync, for a
  host that never installed; `UNKNOWN` for an installed path that exists but
  cannot be compared (dangling symlink, directory, unreadable) — indeterminate
  and non-zero, never a silent pass; and `SKIPPED` for a checkout shipping no
  workflows at all. `DRIFT` and `UNKNOWN` fail `make doctor`. It compares every
  `*.mjs` the checkout ships, not just `build-level.mjs`. **Detect and report
  only — it never writes to `~/.claude`**: installing is global shared state
  and a deliberately operator-run action, so the check names the remedy and
  leaves the decision to a human.
