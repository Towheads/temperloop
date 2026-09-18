- **`doctor` no longer reports every managed symlink as `DRIFT` when `$HOME`
  resolves through a symlink** (#1909). A clean install into a scratch home on
  macOS — where `/var` and `/tmp` are themselves symlinks, so a `mktemp -d`
  home always resolves — was followed by `workflows/scripts/install/doctor.sh`
  calling all 24 links drifted, even though every link pointed at exactly the
  right file. It was comparing the link's target as a *string* against the
  expected source path, so two correct spellings of the same file disagreed. It
  now compares whether the two paths are the same file on disk, which is the
  question the `DRIFT` verdict was always asking. A link pointing at a
  genuinely different file is still `DRIFT`, and a broken link is still
  `DANGLING` — the check got more accurate, not more permissive.
