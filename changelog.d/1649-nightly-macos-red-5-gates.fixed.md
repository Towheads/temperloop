- **The five macOS-only quality gates that had been red on `main` for eight
  nights now pass, and the shell-version footgun behind them is guarded
  mechanically** (#1649). `nightly-macos.yml` failed on every scheduled run from
  2026-08-14 onward — deterministically, byte-identically on retry — while the
  `ubuntu-timing` leg of the same workflow stayed green. Two distinct causes, one
  shared shape: **a bash-VERSION difference, not the BSD-vs-GNU userland dialect
  family** (#1549 / #1422) that this repo's macOS regressions usually belong to.
  The macos-latest runner's `bash scripts/quality-gates.sh` resolves to the
  system `/bin/bash`, which on macOS is **3.2.57**; ubuntu-latest ships bash 5.x.

  **(a)** `validate-check-surface-degenerate-coverage.sh` and
  `validate-exec-bit-registry.sh` (and therefore both of their test suites — four
  of the five gates) parsed their TSV registries by re-joining fields on `\x01`
  and reading them back with `IFS=$'\x01'`. **0x01 is bash's own CTLESC marker
  byte** (0x7f is CTLNUL), and bash 3.2's word splitting is not 8-bit clean for
  either: `read` returns the whole line — marker bytes included — in the *first*
  variable and leaves the rest empty. Every registry row therefore parsed as one
  field, and the gates reported `Checked 0 registered surface(s)` plus a
  `BAD-CASE` per row. Both now join on `\x1f` (ASCII US), which splits correctly
  on 3.2 and 5.x alike. The awk stage was never at fault: it emits byte-identical
  output under BSD and GNU awk, and holding awk fixed while swapping only the
  bash binary flips the result — which is how the dialect hypothesis was ruled
  out rather than assumed.

  **(b)** `test_model_usage_emit.sh`'s §47 mutation check asserted that removing
  `set +o posix` from `validate-model-usage-emit.sh` makes its CANNOT EVALUATE
  diagnostic vanish under `POSIXLY_CORRECT=1`. That is a bash 4+ behaviour: only
  bash 4+ aborts a posix-mode shell on a special-builtin redirection error inside
  an `if !` condition. Bash 3.2 does not, so the guard is provably *inert* there
  and the assertion was simply false. The check now **measures the host shell**
  with a minimal reproduction of the production shape, prints the verdict, and
  asserts the correct claim for that shell — the original strict "diagnostic is
  lost" on a bash that aborts, and the equally falsifiable inverse "diagnostic
  survives" on one that does not. Nothing is skipped or exempted, and the
  production guard is unchanged.

  **The structural half.** `scripts/lint-bash32-ctlesc-ifs.sh` is a new static
  lint — third member of the family alongside `lint-bash32-cmdsubst-comment.sh`
  and `lint-pipe-grep-q.sh` — that fails the build on any `IFS=` assignment
  naming byte 0x01 or 0x7f, in every spelling bash accepts. A static lint is the
  only detector that fires on *both* CI legs: shellcheck and `bash -n` exit 0 on
  the shape, and a runtime test only catches it under a bash 3.2 that the
  ubuntu-only pre-merge leg (#963) does not have. It deliberately does **not**
  flag the awk side (`awk -F'\1'`, `OFS="\x01"`) — measured 8-bit clean on both
  bashes, and live-and-correct in `validate-activation-registry.sh`, which an
  earlier, wider cut of the rule false-positived on. Its regression suite fires
  the lint at the verbatim pre-fix lines, fences the false positives, and — on
  any host that actually has a bash 3.2 — re-measures the lint's own premise so
  the claim cannot rot into folklore.
