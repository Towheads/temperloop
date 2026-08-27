- **`deploy-mini.sh` now auto-heals only cron/kernel-role checkouts** (#1828).
  Each checkout's role resolves through `env-reconcile.sh`'s role registry (the
  kernel's detection substrate, honoring `ENV_RECONCILE_CRON_CHECKOUTS` /
  `ENV_RECONCILE_OPERATOR_CHECKOUTS`); the mutating operations (HEAD switch,
  ff-merge, merged-branch prune, worktree prune) run only on cron/kernel-role
  checkouts. An operator/consumer-role checkout — or one in neither registry —
  gets its drift (non-main branch, dirty tree, behind-ness) printed on a
  `DRIFT (operator role — report-only)` line and is never mutated, conforming
  the session-start sweep to CLAUDE.kernel.md § Environment hygiene's
  aggressive-in-lane / report-cross-lane policy.
