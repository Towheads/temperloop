- **The testbed source seam now resolves each provider's directory argument
  itself, instead of the driver forcing its own `--dir` default on every
  provider** (#1356): `workflows/scripts/testbed/source.sh` gains a fifth
  seam member, `dir_arg(dir, seed_dir)`, dispatched by provider kind exactly
  like the existing four, and `temperloop testbed` gains a `--seed-dir`
  flag. Before this, one positional argument meant "source repo directory"
  to `mirror-from-repo` and "seed directory" to `materialize-from-seed`, so
  the driver's `source_dir="."` default silently overrode the correctly
  computed in-tree seed default and a seed run produced the repo name
  `.-testbed` instead of `linkrot-testbed`. The defect was at the call site,
  not in either provider — `_TESTBED_SEED_DIR_DEFAULT` already resolved the
  in-tree seed correctly. The driver stays provider-agnostic: it resolves
  one provider-scoped value through the seam, with no `case` on provider
  kind anywhere in `bin/subcommands/testbed.sh` (the existing structural
  guard test still holds). `mirror-from-repo` is unchanged — `--dir` still
  selects the source repository directory.

  Worth recording next to the existing provider-equivalence test (#1232):
  that test drives two doubles and asserts an identical call sequence, and
  is **structurally incapable** of catching this defect — the call sequence
  genuinely *is* identical for both providers; only the argument's meaning
  differed. That is the honest limit of equivalence-by-doubles, not a flaw
  in how it was written. The new regression test therefore drives the
  **real** providers through the real driver, from two different working
  directories (including from inside an unrelated git checkout), and pins
  what "valid repository name" means — matches `^[A-Za-z0-9_.-]+$`, is
  neither `.` nor `..`, at most 100 characters — a constraint no validator
  in the tree asserted before now.
