- **`env-reconcile.sh` now classifies a worktree from its ACTUAL branch, and
  never hands a consumer a removable verdict it could not establish**
  (temperloop#658). `classify_worktree` computed the branch as
  `build/$(basename "$wt")` — the naming convention `worktree.sh` happens to
  use — so a worktree on any other prefix resolved to a branch name that had
  never existed, missed `show-ref`, and was reported
  `LEAKED_WORKTREE:BRANCH_GONE` while alive. `/tidy`'s env-hygiene auto-heal
  then `git worktree remove --force`d it: on 2026-07-21 a live `fix/` worktree
  — the isolated-worktree flow the kernel's own § Working-tree ownership rule
  *prescribes* — was destroyed along with its uncommitted edit. Two changes.
  **Classify from the real signal:** the branch is read from git's own
  `worktree list --porcelain` record for that path (falling back to the
  worktree's `HEAD` symref), so prefix has nothing to do with the verdict while
  the genuinely-deleted ref is still detected. **Never remove on an
  unestablished verdict:** the emitted class splits into `LEAKED_WORKTREE`
  (leak reason held *and* the tree confirmed clean — the only auto-removable
  one), `DIRTY_WORKTREE` (same reason, but uncommitted work present), and
  `UNCERTAIN_WORKTREE` (the verdict could not be established at all — a
  detached worktree, an unregistered directory, or a branch-gone worktree whose
  deleted ref leaves `git status` no base to diff against). Each finding line
  now carries its disposition, and `/tidy` removes only the clean class, run
  **without `--force`** so git's own refusal is the last belt.
