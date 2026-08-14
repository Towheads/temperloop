- **`temperloop testbed` no longer misattributes source identity on a
  `materialize-from-seed` run** (#1357). `source_slug` — the value feeding
  the handoff banner, the consent block's `source :` line, and
  `testbed_record_add`'s persisted `.source_repo` — was computed ONCE in the
  driver as a bare `git remote get-url origin` read in the DRIVER's own
  cwd, identically for both providers, rather than from either provider's
  own `describe()`. record.sh's own documented schema says `.source_repo`
  is null for a seed testbed — but running `materialize-from-seed` from
  inside any git checkout that happened to have an `origin` remote (the
  likely case for someone trying the demo from a real clone) silently
  captured that UNRELATED repository's slug instead: a schema violation,
  persisted, and — since `temperloop uninstall` (#1358) now prints teardown
  guidance sourced from that same record — not merely cosmetic. temperloop
  #1356's provider-scoped directory argument fix did not fix this on its
  own: `source_slug` was never derived from a provider's resolved directory
  at all.

  The fix folds source identity into `describe()`, the seam member the
  driver already calls exactly once, already dispatched by provider kind:
  `describe()`'s JSON payload now carries a `source_repo` field —
  `mirror-from-repo`'s own implementation resolves it from ITS OWN resolved
  source directory (the same read `base_name` already derived a slug from);
  `materialize-from-seed`'s implementation returns `null` unconditionally,
  since there is no upstream repository to name, ever, regardless of the
  cwd the command happens to run from. The driver reads `.source_repo` off
  the already-resolved `describe()` payload instead of re-deriving
  anything itself — no `case` on provider kind, no second slug parser (the
  existing structural guard against a provider-kind `case` in
  `bin/subcommands/testbed.sh` still holds). The handoff's "your real repo
  (...) is never touched" reassurance is now printed only when
  `describe()` actually resolved a real source repository — a seed run
  makes no claim about a real repo at all, rather than falsely reassuring
  about one. `mirror-from-repo` is unchanged in behavior: `--dir` still
  names the source repository, and the handoff/consent/record all still
  carry its slug.
