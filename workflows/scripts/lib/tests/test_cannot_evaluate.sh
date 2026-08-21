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
#   4. THE BOOTSTRAP TIER (temperloop#1487): the helper is jq-FREE, and the
#      four `command -v jq` guards in batch/judge/score/replay.sh ride it.
#      Case 4 proves the encoder is byte-identical with and without jq; case
#      5 runs each of the four REAL scripts with jq absent from PATH and
#      asserts the machine JSON lands on STDOUT and the human line on
#      STDERR. Case 5 carries its own DISCRIMINATION mutant: the pre-#1487
#      batch.sh guard (JSON to stderr, no human line) is reconstructed and
#      shown to FAIL the same assertion, so case 5 is proven load-bearing
#      rather than trivially green.
#   5. THE ONE REGISTERED CARVE-OUT (temperloop#1487): tagging.sh's
#      `crosscheck` deliberately does NOT route through the helper, because
#      its stdout is its own human verdict stream. Case 6 pins that
#      carve-out's exact accepted shape — frozen human line on stderr, NO
#      machine JSON on EITHER stream, exit 1 — so a future silent drift into
#      a partial or wrong-stream JSON emitter goes red instead of quietly
#      becoming a seventh reinvention.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
LIB="$LIB_DIR/cannot-evaluate.sh"

# Case 3 reads the five REAL wrapper bodies out of workflows/scripts/
# model-comparison/{batch,judge,score,replay}.sh — a kernel-internal
# consistency check between KERNEL files. Resolve that directory through this
# test file's own SYMLINK-RESOLVED location, never the invoked (root-relative)
# path (temperloop#1543): in a composed overlay checkout this file is reached
# through a compat symlink and the overlay root may legitimately not wire
# model-comparison/ at all, but the wrappers under test always live next to
# the REAL copy of this test. Portable resolution (no GNU readlink -f) — the
# same idiom the board scripts use.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd -P "$(dirname "$_self")" && pwd)"; _self="$(readlink "$_self")"
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
REAL_HERE="$(cd -P "$(dirname "$_self")" && pwd)"
MC_DIR="$(cd -P "$REAL_HERE/../../model-comparison" 2>/dev/null && pwd)" || MC_DIR=""

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

# --- 4. THE ENCODER IS jq-FREE, and byte-identical either way (#1487) -----
# The four bootstrap guards call this helper at the exact moment jq is
# missing, so "works without jq" is not a nicety here — it is the whole
# reason the guards could be converged onto the one path at all.
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for _t in bash sh env printf echo date mkdir rm cat head tail tr cut sed awk \
          grep dirname basename readlink git uname sort wc mktemp chmod ln \
          find id stat pwd expr sleep; do
  _p="$(command -v "$_t" 2>/dev/null || true)"
  [ -n "$_p" ] && ln -sf "$_p" "$NOJQ_BIN/$_t" 2>/dev/null
done
command -v jq >/dev/null 2>&1 && [ ! -e "$NOJQ_BIN/jq" ] || fail "4: setup — the no-jq PATH must not contain jq"

# A message carrying BOTH characters JSON string-escaping must handle, so the
# pure-shell branch is compared against jq on a case that can actually differ.
CE_MSG='he said "hi" and a back\slash'

withjq_out="$(cannot_evaluate_emit "widget.sh" "$CE_MSG" 2>"$TMP/wj.err")"
withjq_err="$(cat "$TMP/wj.err")"

nojq_rc=0
PATH="$NOJQ_BIN" bash -c '. "$1"; cannot_evaluate_emit "widget.sh" "$2"' _ "$LIB" "$CE_MSG" \
  >"$TMP/nj.out" 2>"$TMP/nj.err" || nojq_rc=$?
nojq_out="$(cat "$TMP/nj.out")"
nojq_err="$(cat "$TMP/nj.err")"

[ "$nojq_rc" -eq 2 ] || fail "4: with jq absent, cannot_evaluate_emit should still return RC_CANNOT_EVALUATE (2), got $nojq_rc"
[ "$nojq_out" = "$withjq_out" ] || fail "4: the jq-free encoder must be byte-identical to the jq one.
  with jq: $withjq_out
  no  jq: $nojq_out"
[ "$nojq_err" = "$withjq_err" ] || fail "4: the human line must be identical with and without jq.
  with jq: $withjq_err
  no  jq: $nojq_err"
[ "$(jq -r .error <<<"$nojq_out" 2>/dev/null)" = "$CE_MSG" ] || fail "4: the jq-free encoder produced JSON that does not round-trip through jq: $nojq_out"
echo "PASS: 4 the emission path is jq-FREE — encoder byte-identical with and without jq, message round-trips, still returns 2"

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

if [ -z "$MC_DIR" ] || [ ! -f "$MC_DIR/batch.sh" ]; then
  # Named skip, never a silent one (temperloop#1543): the wrapper sync check
  # is kernel-internal consistency between two kernel files — a tree that
  # does not carry model-comparison/ next to this test's REAL location has no
  # wrappers to probe, and re-proving the kernel's own sync downstream adds
  # nothing over kernel CI. Cases 1-2m above (the adopter-live lib contract)
  # already ran.
  echo "SKIP: 3 wrapper probes — batch.sh not found at ${MC_DIR:-$REAL_HERE/../../model-comparison} (no model-comparison harness in this tree; the five wrappers are kernel-internal surfaces, temperloop#1543). Cases 1-2m ran; exiting 0."
else
  for pair in "batch.sh:bd_cannot_evaluate:batch.sh" \
              "judge.sh:_je_cannot_evaluate:judge.sh" \
              "score.sh:cannot_evaluate:score.sh" \
              "replay.sh:preflight_cannot_evaluate:replay.sh preflight" \
              "replay.sh:execute_cannot_evaluate:replay.sh execute"; do
    IFS=: read -r wf wfn wprefix <<<"$pair"
    probe_wrapper "$wf" "$wfn" "$wprefix"
  done
  echo "PASS: 3 all five wrapper functions are BEHAVIORALLY proven: each really returns RC_CANNOT_EVALUATE (2), really emits the machine JSON, and really prints its own DISTINCT stderr prefix (batch.sh / judge.sh / score.sh / replay.sh preflight / replay.sh execute) — not just textually mentions cannot_evaluate_emit"

  # --- 5. THE BOOTSTRAP TIER, end to end on the REAL scripts (#1487) ------
  # Run each entry point with jq genuinely absent from PATH and assert the
  # two frozen shapes land on the two correct STREAMS. This is the check the
  # #1487 defect would have failed: batch.sh put the JSON on stderr (so a
  # stdout `.outcome` reader saw nothing) and replay.sh emitted
  # `outcome:"ERROR"` there instead of CANNOT_EVALUATE.
  probe_bootstrap() {
    local script="$1" prefix="$2" rc=0
    PATH="$NOJQ_BIN" bash "$MC_DIR/$script" --help \
      >"$TMP/boot.out" 2>"$TMP/boot.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "5: $script with jq absent should refuse non-zero, got $rc"
    [ "$(jq -r .outcome <"$TMP/boot.out" 2>/dev/null)" = "CANNOT_EVALUATE" ] \
      || fail "5: $script must print the machine verdict on STDOUT when jq is missing, got stdout=[$(cat "$TMP/boot.out")] stderr=[$(cat "$TMP/boot.err")]"
    [ "$(jq -r .error <"$TMP/boot.out" 2>/dev/null)" = "jq not found" ] \
      || fail "5: $script's bootstrap verdict should carry .error='jq not found', got: $(cat "$TMP/boot.out")"
    grep -qF "$prefix: CANNOT EVALUATE — jq not found" "$TMP/boot.err" \
      || fail "5: $script must print '$prefix: CANNOT EVALUATE — jq not found' on STDERR, got: $(cat "$TMP/boot.err")"
    grep -qF 'CANNOT_EVALUATE' "$TMP/boot.err" \
      && fail "5: $script must NOT put the machine JSON on stderr (the pre-#1487 batch.sh defect), got: $(cat "$TMP/boot.err")"
    return 0
  }
  for pair in "batch.sh:batch.sh" "judge.sh:judge.sh" "score.sh:score.sh" "replay.sh:replay.sh"; do
    IFS=: read -r bf bprefix <<<"$pair"
    probe_bootstrap "$bf" "$bprefix"
  done
  echo "PASS: 5 all four jq bootstrap guards ride the ONE emission path — machine JSON on STDOUT, human line on STDERR, non-zero exit, with jq genuinely absent"

  # --- 5m. DISCRIMINATION: the pre-#1487 batch.sh guard FAILS case 5 -------
  # Reconstruct the exact removed line and show that the stream assertion
  # above genuinely rejects it — so case 5 is load-bearing, not a check that
  # would pass whatever the guard did.
  cat >"$TMP/old-guard.sh" <<'OLDGUARD'
#!/usr/bin/env bash
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo '{"outcome":"CANNOT_EVALUATE","error":"jq not found"}' >&2; exit 1; }
OLDGUARD
  old_rc=0
  PATH="$NOJQ_BIN" bash "$TMP/old-guard.sh" >"$TMP/old.out" 2>"$TMP/old.err" || old_rc=$?
  [ "$old_rc" -eq 1 ] || fail "5m: the reconstructed pre-#1487 guard should exit 1, got $old_rc"
  [ ! -s "$TMP/old.out" ] || fail "5m: the reconstructed pre-#1487 guard was expected to print NOTHING on stdout (that was the defect), got: $(cat "$TMP/old.out")"
  grep -qF 'CANNOT_EVALUATE' "$TMP/old.err" || fail "5m: the reconstructed pre-#1487 guard should have put the JSON on stderr — the mutant does not reproduce the historical defect"
  echo "PASS: 5m (discrimination) the pre-#1487 guard really did emit nothing on stdout and the JSON on stderr — case 5's stream assertions reject it, so they are load-bearing"

  # --- 6. THE ONE REGISTERED CARVE-OUT: tagging.sh crosscheck (#1487) -----
  # Pinned deliberately: crosscheck's stdout is its own human verdict stream,
  # so it emits the frozen HUMAN line and NO machine JSON at all. Asserting
  # the accepted shape is what stops it from silently drifting back into a
  # partial reinvention — presentation-plane.md's frozen row names this
  # exception, and this case is what keeps that row honest.
  if [ -f "$MC_DIR/tagging.sh" ]; then
    echo "x" >"$TMP/cc-body.txt"
    cc_rc=0
    PATH="$NOJQ_BIN" bash "$MC_DIR/tagging.sh" crosscheck \
      --pr-body "$TMP/cc-body.txt" --run-id pr:1487 \
      >"$TMP/cc.out" 2>"$TMP/cc.err" || cc_rc=$?
    [ "$cc_rc" -eq 1 ] || fail "6: tagging.sh crosscheck's accepted carve-out exit code is 1 (its own documented code, not RC_CANNOT_EVALUATE), got $cc_rc"
    grep -qF 'tagging.sh crosscheck: CANNOT EVALUATE — jq not found' "$TMP/cc.err" \
      || fail "6: the carve-out still owes the frozen HUMAN line verbatim on stderr, got: $(cat "$TMP/cc.err")"
    if grep -qF 'CANNOT_EVALUATE' "$TMP/cc.out" "$TMP/cc.err"; then
      fail "6: the accepted carve-out emits NO machine JSON on either stream — a partial/wrong-stream emitter appeared, which is a seventh reinvention. stdout=[$(cat "$TMP/cc.out")] stderr=[$(cat "$TMP/cc.err")]"
    fi
    echo "PASS: 6 the ONE registered carve-out (tagging.sh crosscheck) holds its stated accepted shape — frozen human line on stderr, no machine JSON on either stream, exit 1"
  else
    echo "SKIP: 6 carve-out probe — tagging.sh not found at $MC_DIR (kernel-internal surface, temperloop#1543)"
  fi
fi

echo "All cannot-evaluate.sh tests passed."
