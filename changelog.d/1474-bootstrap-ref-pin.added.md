- **`bin/bootstrap.sh` gains `TEMPERLOOP_KERNEL_REF`, so a CI dry run can
  finally test the ref it was dispatched against** (#1474). Bootstrap pins a
  fresh install to the newest `v*` tag it can see, never to the ref its caller
  checked out — which is exactly right for a newcomer's `curl … | sh`, and
  exactly wrong for `install-tier2`'s documented "pre-tag dry run against
  `main`". That second use silently reinstalled the *last release* and
  reported on it: a dispatch carrying a just-merged fix reproduced the very
  bug it fixed, because the fix was not in any tag yet. The new override is a
  sibling of `TEMPERLOOP_KERNEL_REPO` — `REPO` says which clone URL to install
  from, `REF` says which ref inside it to land on — and accepts any commit-ish
  (a SHA, tag, branch, `origin/main`). Two properties are deliberate: it
  applies to a **first install only**, never the re-run path (which still
  delegates entirely to `temperloop update`); and a set-but-unresolvable ref
  is a **hard failure naming the ref**, never a quiet demotion to the newest
  tag — a fallback would recreate the same "claims to test one thing, tests
  another" confusion. Unset *or empty* is the unchanged default. **If you
  install via bootstrap:** nothing changes unless you set the variable.
  `install-tier2` sets it to the checked-out commit on a `workflow_dispatch`
  run only; a tag-triggered release-gate run leaves it unset, so the gate
  keeps the exact newcomer code path with no CI-only knob in it.
