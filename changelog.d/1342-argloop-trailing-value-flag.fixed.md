- **112 argument loops that spun at 100% CPU forever when a value-taking flag
  was the final argument are fixed, and the shape is now a build-failing lint**
  (#1342). Bash's `shift n` **fails** (`shift count out of range`) when `n > $#`,
  and a **failed shift does not shift** — the positional parameters are left
  completely untouched. So the ubiquitous
  `--format) format="${2:-brief}"; shift 2 ;;` inside `while [ $# -gt 0 ]`
  never terminates when the script is invoked with `--format` last: `$#` stays
  at 1, the same case arm re-matches, and the loop pins a core until something
  kills it. The `${2:-…}` default is precisely what makes it a **hang** rather
  than a crash — it removes the `set -u` unset-variable error that would
  otherwise have ended the loop, and these scripts deliberately run without
  `set -e`, so the non-zero shift is swallowed.

  **Blast radius, both halves live.** A hung script that *is* a `KERNEL_GATES`
  entry does **not fail** the gate — it burns the CI runner to the job timeout,
  so the signal reads as "slow", not "broken". Worse for the `emit-*.sh`
  telemetry family, whose own headers promise *"a telemetry emit must never fail
  or block the calling spawn site"*: a hang is strictly worse than the failure
  that contract exists to prevent, and the conventional `emit-… || true` call
  shape cannot save a caller from it — an unset trailing variable at a spawn
  site hangs the **spawn site** forever. `emit-item-efficiency.sh --slug` was
  confirmed hanging for >8s before being killed.

  **The sweep.** 112 sites across 26 files — the five `emit-*.sh` emitters the
  issue names, plus `promote/`, `probe/`, `drain/`, `build/`, `kernel/` and the
  telemetry/report scripts — now shift the **flag** first and the value only if
  one is actually there: `shift; if [ $# -gt 0 ]; then shift; fi`. No shift can
  be out of range, so no loop can spin.

  **The structural half.** `scripts/lint-argloop-shift2.sh` is a new static lint
  — fourth member of the family alongside `lint-bash32-ctlesc-ifs.sh`,
  `lint-bash32-cmdsubst-comment.sh` and `lint-pipe-grep-q.sh` — that fails the
  build on a `shift N` (N ≥ 2) reached inside a `$#`-conditioned loop with no
  preceding `$#` guard and a non-fatal `$2` expansion. A **lint** and not only a
  sweep because the defect was **independently re-derived in brand-new code**
  (`async-workflow-health.sh`, #1297) by a worker that had never seen the
  `emit-*.sh` sites: a sweep closes the instances, only a lint closes the class.
  Nothing already in the gate set catches it — shellcheck exits 0 (every
  affected file was shellcheck-clean), `bash -n` exits 0 (the line is
  syntactically perfect), and merely *running* the code is not detection either,
  because a hang does not fail a gate.

  The rule is deliberately narrow, and the narrowing is **measured, not
  assumed**: `${2:?…}` exits with its own message, and a bare `$2` under `set -u`
  exits `$2: unbound variable`, so neither can spin and neither is flagged — an
  earlier, wider cut would have false-positived ~58 live, correct
  `bin/subcommands/` sites. Also exempt: a loop whose *condition* already
  guarantees the arity (`while [ "$#" -ge 2 ]`, live in `board.sh`), and an
  `if [ $# -lt 2 ]; then … continue; fi` preflight (live in
  `emit-session-context.sh`) — a different, equally correct fix for the same
  defect, which it would be perverse to punish.

  **The runtime half.** `workflows/scripts/tests/test_argloop_trailing_flag.sh`
  extracts every repaired loop verbatim from its shipped file and runs it with
  each flag **last** (195 invocations across 27 files), plus the five `emit-*.sh`
  scripts end-to-end with their raw-lake sink in a tmpdir. Coverage is *derived*
  by grep from the fix idiom, so a new adopter is covered without anyone editing
  a registry. Every run is **bounded by a watchdog** — an unbounded assertion for
  this defect would hang the suite instead of failing it, which is worse than no
  test at all — and the suite carries its own discrimination control: a
  reintroduced `shift 2` must be killed by the watchdog *and* turn the lint red.
