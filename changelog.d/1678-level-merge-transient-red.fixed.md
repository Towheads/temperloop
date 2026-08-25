- **The Step-4a.5 combined-tree pre-check no longer false-fails under a
  symlinked `$TMPDIR`** (#773, #1678). `combined-tree-precheck.sh` built its
  throwaway worktree at the *logical* `mktemp -d` name, so on macOS — where
  `$TMPDIR` is `/var/folders/…` and `/var` is a symlink to `/private/var` — the
  gate suite ran with a cwd whose spelling differed from what any script inside
  it resolved with `pwd -P`. A test comparing the two spellings of the same file
  failed on string inequality alone, producing a `GATE_FAILED` for every
  multi-PR level; `/build` risk trigger (d) treats that verdict as unappealable,
  so batch merge was blocked and levels merged one PR at a time — leaving `main`
  transiently red whenever a level's members were only jointly consistent. The
  worktree root is now resolved physically before it is registered, added or
  used, so the whole suite sees one spelling and no individual test has to
  normalize defensively to survive this worktree.
