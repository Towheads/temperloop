- **`env-reconcile.sh` now detects a stale composed `~/.claude/CLAUDE.md`**
  (`COMPOSED_STALE`, #1618). The installed `CLAUDE.md` is a real generated
  file (kernel doc + overlay + a rendered knowledge-store-routing section) —
  deliberately not a symlink, so `make doctor`'s symlink classifier cannot
  see it drift. A composed file older, by mtime, than
  `claude/CLAUDE.kernel.md`, `claude/CLAUDE.overlay.md`, or
  `workflows/scripts/build/build.config.sh` under the checkout named by the
  new `ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT` override now reports
  `COMPOSED_STALE:<input>` as operator-checkout-role drift, in both
  `--format report` and `--format entry`. The comparison is mtime,
  deliberately never `cmp` — the composed file has no expected-content
  baseline to diff against without re-running the compose. With
  `ENV_RECONCILE_CLAUDE_MD_SOURCE_CHECKOUT` unset (the default — this script
  never guesses which checkout produced the install), or with the composed
  file / any named input missing, the check reports `UNVERIFIABLE` rather
  than crashing or false-claiming clean. Report-only: never re-runs
  `install-claude-md.sh` / `make install-claude`, never touches `~/.claude/`.
