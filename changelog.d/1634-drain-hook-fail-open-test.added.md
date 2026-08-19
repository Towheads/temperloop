- **`session-start-drain.sh`'s seam-unavailable fail-open branch is now
  covered by a test** (#1634). The hook exits 0 without draining when the
  knowledge_store seam was never sourced — a hooks-only vendor drop with no
  `workflows/scripts/lib/` two directories up — but no case in
  `claude/hooks/tests/test_session_start_drain.sh` could reach it, because
  `make_fixture` always copied both libs in. The new case removes `workflows/`
  from the fixture and pins all the properties a SessionStart hook owes: rc=0,
  the `.mind/` stub still on disk byte-identical, nothing written into the
  store, the session-id `hookSpecificOutput` JSON still on stdout, and the
  "knowledge_store seam unavailable" line in the log. It goes red if that
  branch ever exits non-zero — the regression would present as a broken
  session start on a vendored checkout, not as a skipped drain.
