- **`test_board_host_label.sh`'s "exactly one inlining site" check no longer
  depends on which `grep` is on `PATH` or on how the board toolkit was
  vendored** (#1422). The check enumerated its file set with `grep -rlE …
  "$BOARD_DIR"`, and a recursive grep's treatment of symlinks is not portable,
  so the *verdict* was a function of the host rather than of the code being
  audited. Two distinct failures, both measured:

  - **Board dir reached through a directory symlink** — the shape every
    vendoring overlay uses (`workflows/scripts/board -> ../../kernel/workflows/
    scripts/board` in foundation since 2026-07-03). GNU `grep -r` descends into
    a symlinked top-level argument; real macOS/BSD `grep` (`/usr/bin/grep`)
    does not, and `-R` does not help there either. The v0.29.0 test was
    therefore **green on Linux CI and red on every operator's Mac at the same
    commit**, reporting `found:` with an empty list — which reads as "the
    helper was deleted" when the truth is "the walk never entered the
    directory". `d3163bf` (#1490) had already made this particular arm pass by
    resolving `BOARD_DIR` with `pwd -P`, but only as a side effect of path
    resolution: the enumeration itself was still non-portable, and nothing
    tested that it stayed fixed.
  - **Board dir is a real directory whose *files* are per-file symlinks** into
    a vendored `kernel/` copy — the other shape in the fleet. `-r` on *neither*
    grep follows a symlink met during the walk, so this layout found **zero**
    sites on **both** platforms, which `pwd -P` cannot rescue. This arm was
    still red.

  The file set is now enumerated with `find -L` (which follows symlinks at the
  argument *and* during the walk) and grep is handed real files by name — the
  direct-file form that already matched on both platforms, which is exactly
  what made the recursive form's divergence look impossible at first read. Both
  sides of the "is this the one permitted site?" identity comparison are also
  canonicalized through a single `phys_path` helper, so a layout that reaches
  `lib/` or `tests/` through a symlink cannot make two spellings of the same
  file read as two sites.

  **The assertion is sharpened, not hollowed out.** A new sibling suite,
  `test_board_host_label_layouts.sh`, materializes all three layouts (real
  directory, directory symlink, per-file symlinks) and runs the subject test in
  each under every distinct `grep` the host can reach — the system `/usr/bin/
  grep` (BSD on macOS) and a `ggrep` if installed (GNU). For every
  layout × grep cell it proves three things in sequence: the clean tree is
  green, **adding a second inlining site turns it red and names that file**,
  and removing that site returns it to green. A portability fix that worked by
  weakening the check would pass the first assertion and fail the second. On a
  Homebrew Mac that is 6 cells; on Linux CI, where the flavors collapse, 3.
