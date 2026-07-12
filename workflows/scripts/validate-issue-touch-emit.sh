#!/usr/bin/env bash
#
# validate-issue-touch-emit.sh — presence-lint for the build.md issue-touch
# emit (foundation #916/#919, epic #916 "issue-touch-stream").
#
# build.md's Step 3f (PR opened) and Step 4d (PR confirmed MERGED) are the
# only places a `pr-open` / `merge` touch happens for a plan item.
# emit-issue-touch.sh is the concrete emit — but a prose orchestrator step in
# a skill doc can silently rot (the June silent-failure class: an
# LLM-executed markdown step gets skipped or paraphrased away and nobody
# notices, because the failure mode is an ABSENT record, not an error). This
# script is the mechanical owner that makes that rot loud: it FAILS CI (exit
# 1) if either half of the wiring goes missing —
#
#   1. the script itself (workflows/scripts/emit-issue-touch.sh) is absent or
#      not executable, or
#   2. its invocation is removed from claude/commands/build.md — i.e. the
#      3f step no longer calls emit-issue-touch.sh with `--kind pr-open`, or
#      the 4d step no longer calls it with `--kind merge`.
#
# Both call sites live in the SAME file (build.md), unlike
# validate-command-run-emit.sh's two-file (sweep.md/triage.md) case — so this
# checks for the presence of BOTH --kind values within the file rather than
# one value per file. This mirrors the validate-live-drain.sh /
# validate-command-run-emit.sh shape (same script style, same
# hard-fail-on-half-present contract, wired into scripts/quality-gates.sh the
# same way).
#
# Usage: workflows/scripts/validate-issue-touch-emit.sh   (resolves the repo itself)

set -euo pipefail

SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$SCRIPTS_DIR/../.." && pwd)"
EMIT_SCRIPT="$SCRIPTS_DIR/emit-issue-touch.sh"
BUILD_MD="$REPO/claude/commands/build.md"

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-issue-touch.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-issue-touch.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-issue-touch.sh present and executable"
fi

# --- 2. build.md must still invoke it with BOTH --kind values ---------------
if [ ! -f "$BUILD_MD" ]; then
  echo "FAIL  build.md doc missing entirely ($BUILD_MD)"
  fail=1
elif ! grep -Fq 'emit-issue-touch.sh' "$BUILD_MD"; then
  echo "FAIL  build.md ($BUILD_MD) no longer invokes emit-issue-touch.sh anywhere — the issue-touch emit was removed from the executable path"
  fail=1
else
  check_kind_wiring() {  # $1=step label (for the message) $2=expected --kind value
    local label="$1" kindval="$2"
    # Materialize the -A4 context block via command substitution FIRST, then
    # scan the captured text — never pipe it live into a second grep. A live
    # `grep -A4 ... | grep -Eq ...` pipeline is a false-failure trap under
    # `set -o pipefail` (foundation #287): `grep -Eq` exits the instant it
    # finds a match, closing its read end while the upstream `grep -A4` may
    # still have buffered context lines queued to write; the upstream then
    # dies with "grep: write error: Broken pipe" (EPIPE) and a nonzero exit,
    # which — even though the match WAS found — makes the pipeline's
    # pipefail-computed status nonzero and reads as "pattern absent". This is
    # timing-dependent (depends on pipe-buffer/scheduling), so it flakes
    # rather than failing deterministically. Command substitution has no such
    # race: `grep -A4` runs to completion and its full output is captured
    # before the second grep ever looks at it, so there is no live pipe to
    # close early. `|| true` on the capture keeps `set -e` from tripping when
    # the emit-issue-touch.sh line simply has no match at all (a genuine
    # absence, not an EPIPE) — the subsequent `grep -Eq` on the captured text
    # (possibly empty) still correctly reports FAIL for that case.
    local block
    block="$(grep -A4 -F 'emit-issue-touch.sh' "$BUILD_MD" || true)"
    if ! grep -Eq -- "--kind[[:space:]]+${kindval}\b" <<<"$block"; then
      echo "FAIL  build.md invokes emit-issue-touch.sh but never with --kind ${kindval} (expected at $label) — wiring drifted"
      fail=1
      return
    fi
    echo "ok    build.md wires emit-issue-touch.sh --kind $kindval ($label)"
  }
  check_kind_wiring "3f, PR open" "pr-open"
  check_kind_wiring "4d, confirmed merge" "merge"
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-issue-touch-emit: FAIL"
  exit 1
fi
echo "validate-issue-touch-emit: OK"
