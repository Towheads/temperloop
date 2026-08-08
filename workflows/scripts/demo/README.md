# `workflows/scripts/demo/` — the testbed seed-content home

This directory holds the **seed** the `materialize-from-seed` testbed source
provider materializes: a small, prepared project plus a set of issue
definitions, tracked here as ordinary files.

It used to hold a *generator* (`seed-demo-repo.sh`) that pushed synthetic
one-file defects into a repository this project owned and maintained. That
shape is retired: per [ADR 0025](../../../docs/adr/0025-evaluation-artifacts-live-in-the-operators-own-account.md),
any artifact this toolkit creates for evaluation purposes is materialized into
**the operator's own account**, from content tracked in this repository. No
repository owned by this project exists at any point, so removing the feature
is `git rm` plus the existing manifest validators — there is no external state
to strand.

## Layout

```
seed/
  seed.json            metadata the provider's describe() reads (zero network)
  project/             materialized verbatim as the testbed repository's tree
  issues/              one Markdown file per issue the provider files
```

## Editing the seed

- `seed/project/` is copied verbatim into a fresh git repository and pushed to
  the destination. Anything you add there ships.
- `seed/issues/*.md` are filed in filename order. The first line is `# <title>`;
  everything after it is the issue body. No provenance line is stamped —
  `materialize-from-seed` has no upstream issue to cite, which is exactly why
  its `describe()` reports `provenance_capable: false` and `promotable: false`.
- The seed ships **green**: its own test suite passes as committed. Each issue
  names a behaviour the suite does not yet cover, so a reader's first `/triage`
  and `/build` pass has real work to do rather than a single tick.

`tests/test_seed_content.sh` (run by `make test-demo`) holds the seed honest:
it asserts the layout, the issue-file grammar, that every defect an issue
claims is actually present in `seed/project/`, and that the shipped suite is
green.
