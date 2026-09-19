- **`build-worktree-guard.sh` no longer false-denies two legitimate writes**
  (#1975, #1974). A redirect target now has any trailing `;`/`&`/`|` stripped
  before the character-device and containment checks, so `cmd 2>/dev/null; next`
  — written with no space before the `;`, which the whitespace tokenizer glues
  into one word — stops being judged as a write to `/dev/null;` outside the
  worktree. And `$HOME/.claude/plans/` joins `/tmp` and `$TMPDIR` on the
  allow-list: it is Claude Code's own plan-persistence directory, so a worker or
  a nested review subagent that enters plan mode inside a guarded worktree could
  not persist a plan at all (six reviewer sessions were blocked in one night).
  The allow-list entry is scoped to `plans/`, never to `$HOME/.claude` as a
  whole, and both reliefs ship with DENY twins in
  `claude/hooks/tests/test_build_worktree_guard.sh` plus declared entries in the
  differential coverage harness.
