- **A hard-killed test run no longer strands its sandbox in `$TMPDIR`**
  (#1667). `sandbox_up` now reaps orphaned sandbox roots itself — once per
  shell, before it creates its own — instead of leaving that to an operator
  who remembers to run `sandbox-sweep.sh`. SIGKILL runs no handler, so the
  existing `trap cleanup EXIT` is structurally incapable of covering a killed
  run: 97 orphans and 84GB accumulated in one week, each a full `file://`
  clone plus a complete install tree. Reclaiming stays safe against a
  concurrent peer — a root is removed only if it carries `sandbox_up`'s marker
  or directory signature, is older than `SANDBOX_REAP_AGE_MIN` minutes
  (default 120), and records no live pid; never by wildcard. `SANDBOX_REAP=0`
  disables the automatic reap, and `SANDBOX_KEEP` suppresses it too.
  `sandbox-sweep.sh` gains `--quiet` (no banner, no per-root lines, no `du`
  accounting; one stderr line only when something was removed) and a `SCOPES`
  header block naming what it covers — `$TMPDIR`, one level deep — and what it
  does not: `~/.claude/jobs/*/tmp/` is a different location with a different
  producer, tracked by #1111 and not fixed here.
