- **The tier-2 install round trip now runs on release tags, not weekly.**
  `.github/workflows/install-tier2.yml` drops its `schedule` (Mondays 05:00 UTC)
  and triggers on a `v*.*.0` tag push — minor and major cuts; a patch tag
  deliberately does not fire it. `workflow_dispatch` remains, for an ad-hoc
  drift probe during a release gap or a pre-tag dry run against `main`. The
  timing now matches semantics that were already there: `bin/bootstrap.sh` pins
  a fresh install to the newest `v*` tag rather than the checked-out ref, so the
  weekly run was already testing the last release tag, at an arbitrary moment.
  On a tag-triggered run the version leg additionally asserts that the tag
  bootstrap pinned to *is* the tag that triggered the run, so a green run proves
  the release being cut was the one tested. **If you cut kernel releases:**
  `VERSIONING.md` § Cutting a release step 4 now blocks propagation
  (`make update-kernel KERNEL_TAG=v<new>`) on that run being green — the tag is
  pushed by hand, so the gate lands on propagation rather than on tagging.
  Accepted trade-off: the weekly cron was the only thing catching drift external
  to the repo (a GitHub API change, a `gh` update, the demo repo rotting) with no
  commit involved; that now surfaces at cut time, and a long release gap should
  be covered by a manual `workflow_dispatch`.
