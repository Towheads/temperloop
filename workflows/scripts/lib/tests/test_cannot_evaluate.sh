#!/usr/bin/env bash
#
# Tests for cannot-evaluate.sh's cannot_evaluate_emit (temperloop#1475,
# epic #1409) — the ONE shared "cannot evaluate" idiom hoisted out of five
# independently reinvented `*_cannot_evaluate()` functions across
# workflows/scripts/model-comparison/{batch,judge,score,replay}.sh.
#
# Coverage:
#   1. Both output shapes: the machine `{outcome:"CANNOT_EVALUATE",error:…}`
#      JSON object on stdout, and the distinct human `CANNOT EVALUATE` line
#      on stderr, carrying the given prefix.
#   2. THE LOAD-BEARING PROPERTY (the whole point of the hoist): the
#      function's OWN return status is RC_CANNOT_EVALUATE (2), not 0 — a
#      caller that forgets to branch on it fails CLOSED. Proven directly
#      against the function, and by DISCRIMINATION: every prior local
#      reimplementation had this exact defect (a bare `jq`+`printf` body
#      with no explicit `return`, so the function's status was whatever
#      `printf` happened to return — success). This test reconstructs that
#      old shape as a throwaway mutant and shows it goes GREEN on a `&&`
#      chain that should refuse — the mutation this hoist fixes.
#   3. BEHAVIORAL proof, per wrapper — not textual. An earlier version of
#      this test asserted only that a wrapper's SOURCE TEXT contained the
#      substring "cannot_evaluate_emit", which a comment satisfies; three
#      real mutants (a wrapper reverted verbatim to its pre-hoist fail-open
#      body with the delegation demoted to a comment; a wrapper that
#      delegates but swallows the status with `|| true`; every wrapper's
#      prefix flipped to a shared "WRONG") all passed that check GREEN. This
#      test instead extracts each wrapper's REAL body text from the real
#      file, defines it as a real function, CALLS it, and asserts on what
#      actually happened: the real exit status, the real JSON, and the
#      real, DISTINCT stderr prefix each of the five wrappers must carry
#      (batch.sh / judge.sh / score.sh / "replay.sh preflight" / "replay.sh
#      execute" — presentation-plane.md freezes this prefix, and the
#      realistic drift is preflight and execute both collapsing to a bare
#      "replay.sh"). A renamed function still yields an empty extracted
#      body and fails loudly via the explicit non-empty check below.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
LIB="$LIB_DIR/cannot-evaluate.sh"
MC_DIR="$(cd "$LIB_DIR/../model-comparison" && pwd)"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -f "$LIB" ] || fail "cannot-evaluate.sh not found at $LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../cannot-evaluate.sh
. "$LIB"

# --- 1. both output shapes, and RC_CANNOT_EVALUATE is 2 (converged value) ---
[ "$RC_CANNOT_EVALUATE" -eq 2 ] || fail "1: RC_CANNOT_EVALUATE should converge on 2 (the existing KERNEL_LIB_RC_CANNOT_EVALUATE / PA_RC_CANNOT_EVALUATE / FD_RC_CANNOT_EVALUATE value), got $RC_CANNOT_EVALUATE"

out1="$(cannot_evaluate_emit "widget.sh" "no --thing given" 2>"$TMP/stderr1.tmp")"
err1="$(cat "$TMP/stderr1.tmp")"
[ "$(jq -r .outcome <<<"$out1" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "1: expected outcome CANNOT_EVALUATE on stdout, got: $out1"
[ "$(jq -r .error <<<"$out1" 2>/dev/null)" = "no --thing given" ] || fail "1: expected .error to carry the message, got: $out1"
case "$err1" in
  "widget.sh: CANNOT EVALUATE — no --thing given") ;;
  *) fail "1: expected the exact human line on stderr, got: $err1" ;;
esac
echo "PASS: 1 both output shapes — machine JSON on stdout, distinct human line on stderr"

# --- 2. the function's OWN return status is RC_CANNOT_EVALUATE, not 0 -------
# (no set -e in this script, so a non-zero status here never aborts the run —
# see the note on test 2m below for the one place that distinction matters)
rc2=0
cannot_evaluate_emit "widget.sh" "x" >/dev/null 2>&1 || rc2=$?
[ "$rc2" -eq 2 ] || fail "2: cannot_evaluate_emit's own return status should be RC_CANNOT_EVALUATE (2), got $rc2"
echo "PASS: 2 the helper's own return status is RC_CANNOT_EVALUATE (2), not 0"

# --- 2m. MUTATION PROOF: a caller that forgets to branch fails CLOSED with
# the real helper, but fell through to the OK path under every prior local
# reimplementation (bare jq+printf, no explicit return -> implicit 0).
forgetful_caller_new() {
  cannot_evaluate_emit "widget.sh" "x" >/dev/null 2>&1 && echo "REACHED-OK-PATH"
}
out2m="$(forgetful_caller_new)"
[ -z "$out2m" ] || fail "2m: a caller that forgot to branch should NOT reach the OK path with the real (fixed) helper, but got: $out2m"
echo "PASS: 2m a caller that forgets to branch fails CLOSED against the real helper"

old_shape_cannot_evaluate() {  # reconstructs the pre-#1475 body verbatim
  jq -cn --arg e "$1" '{outcome:"CANNOT_EVALUATE",error:$e}'
  printf 'widget.sh: CANNOT EVALUATE — %s\n' "$1" >&2
}
forgetful_caller_old() {
  old_shape_cannot_evaluate "x" >/dev/null 2>&1 && echo "REACHED-OK-PATH"
}
out2m_old="$(forgetful_caller_old)"
[ "$out2m_old" = "REACHED-OK-PATH" ] || fail "2m: the reconstructed OLD (pre-hoist) shape was expected to fall through to the OK path (proving the mutant is a faithful reconstruction of the defect), got: $out2m_old"
echo "PASS: 2m (discrimination) the pre-hoist shape genuinely falls through — the mutant reproduces the real historical defect, so test 2m's fix is proven load-bearing"

# --- 3. BEHAVIORAL proof, per real wrapper — extract, define, CALL, assert -
#
# probe_wrapper <file-under-MC_DIR> <function> <expected-stderr-prefix>
# Extracts <function>'s exact body text from the REAL file on disk, `eval`s
# it as a real function (alongside the real, sourced cannot_evaluate_emit),
# calls it with "x", and asserts on the REAL exit status / REAL stdout /
# REAL stderr — never on the presence of a substring in the source. A
# renamed or restructured function yields an empty extracted body, caught
# by the explicit non-empty check below.
probe_wrapper() {
  local f="$1" fn="$2" expected_prefix="$3"
  local body
  body="$(awk -v fn="$fn" '
    $0 ~ "^"fn"\\(\\) \\{" { grab=1; next }
    grab && /^}/ { exit }
    grab { print }
  ' "$MC_DIR/$f")"
  [ -n "$body" ] || fail "3: could not extract ${fn}() body from $f (renamed or restructured?)"

  local out="$TMP/probe-out.json" err="$TMP/probe-err.txt" rc
  rc=0
  ( set -uo pipefail
    # shellcheck source=../cannot-evaluate.sh
    . "$LIB"
    eval "$fn() {
$body
}"
    "$fn" "x"
  ) >"$out" 2>"$err" || rc=$?

  [ "$rc" -eq 2 ] || fail "3: $f's ${fn}(\"x\") should return RC_CANNOT_EVALUATE (2), got $rc — extracted body was:$body"
  [ "$(jq -r .outcome <"$out" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "3: $f's $fn should print {outcome:CANNOT_EVALUATE,...} on stdout, got: $(cat "$out")"
  [ "$(jq -r .error <"$out" 2>/dev/null)" = "x" ] || fail "3: $f's $fn should carry the message through .error, got: $(cat "$out")"
  local expected_line="${expected_prefix}: CANNOT EVALUATE — x"
  [ "$(cat "$err")" = "$expected_line" ] || fail "3: $f's $fn should print '$expected_line' on stderr, got: $(cat "$err")"
}

for pair in "batch.sh:bd_cannot_evaluate:batch.sh" \
            "judge.sh:_je_cannot_evaluate:judge.sh" \
            "score.sh:cannot_evaluate:score.sh" \
            "replay.sh:preflight_cannot_evaluate:replay.sh preflight" \
            "replay.sh:execute_cannot_evaluate:replay.sh execute"; do
  IFS=: read -r wf wfn wprefix <<<"$pair"
  probe_wrapper "$wf" "$wfn" "$wprefix"
done
echo "PASS: 3 all five wrapper functions are BEHAVIORALLY proven: each really returns RC_CANNOT_EVALUATE (2), really emits the machine JSON, and really prints its own DISTINCT stderr prefix (batch.sh / judge.sh / score.sh / replay.sh preflight / replay.sh execute) — not just textually mentions cannot_evaluate_emit"

echo "All cannot-evaluate.sh tests passed."
