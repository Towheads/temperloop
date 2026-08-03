#!/usr/bin/env bash
#
# test_quality_gates_scoped.sh — tests for scripts/quality-gates.sh's `--scoped`
# mode (temperloop#957): the CHANGED-FILE-scoped run a /build item worker uses
# for its ITERATIVE, mid-work verification.
#
# WHY THIS MODE EXISTS. Verification is 79% of all item-worker Bash wall-clock
# (10.4h of 13.2h measured across 141 workers, temperloop#953) and gates are 85%
# of that, with a p90 of 122s and a max of 600s — the full suite, run to check a
# three-file change. The worker's only previous lever was to hand-pick a subset
# out of `--list` output by judgment, which is exactly the kind of unwritten
# selection this repo already has a validated map for.
#
# WHAT MUST BE TRUE FOR THAT TO BE SAFE — the assertions below, in one line
# each: the bare invocation (CI's `checks`, /build §3e.5) is UNCHANGED; a scoped
# run NAMES what it skipped, twice, and stamps its own verdict line so a green
# scoped run cannot be read as a green full run; every resolution failure widens
# to the full set instead of narrowing; an uncommitted or brand-new file is in
# scope (this runs MID-work, not after a commit); and a red gate is still red.
#
# HERMETIC. Every case runs a PATCHED COPY of the real quality-gates.sh in a
# throwaway git repo whose gate list is four synthetic scripts and whose
# gate-path map is a four-row fixture — so the REAL flag parsing, selector
# wiring, skip reporting and exit codes are exercised, and none of this repo's
# actual (minutes-scale) gates run. No network; never this repo's own checkout.
#
# Usage: scripts/tests/test_quality_gates_scoped.sh

set -uo pipefail

# Same hermeticity guard as the sibling slice suite: this file may itself run AS
# A GATE inside a sliced/scoped parent run, which exports its own state.
unset QUALITY_GATES_START_AT QUALITY_GATES_BUDGET_SECS QUALITY_GATES_SCOPE
unset GATE_SELECTION_CHANGED GITHUB_EVENT_NAME LEAK_GUARD_BASE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/scripts/quality-gates.sh"

[ -f "$SRC" ] || { echo "FAIL: quality-gates.sh not found at $SRC" >&2; exit 1; }

fail_count=0
fail() { echo "FAIL: $1" >&2; fail_count=$((fail_count + 1)); }
pass() { echo "PASS: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qg-scoped-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKE="$WORK/repo"
mkdir -p "$FAKE/scripts" "$FAKE/workflows/scripts/lib" "$FAKE/workflows/scripts/config" \
         "$FAKE/src/lib" "$FAKE/src/cli" "$FAKE/docs"
for lib in checkout-freshness.sh gate-retry.sh gate-selection.sh gate-pool.sh; do
  cp "$REPO_ROOT/workflows/scripts/lib/$lib" "$FAKE/workflows/scripts/lib/"
done

# Four synthetic gates. g4 goes red when the $FAKE/g4.red sentinel exists.
for i in 1 2 3 4; do
  cat >"$FAKE/g$i.sh" <<EOF
#!/usr/bin/env bash
echo "g$i" >> "\$QG_SCOPED_MARK"
if [ "$i" = 4 ] && [ -f "\$(dirname "\$0")/g4.red" ]; then echo "g4 is red"; exit 1; fi
exit 0
EOF
  chmod +x "$FAKE/g$i.sh"
done

# The fixture map, at the path quality-gates.sh hardcodes. g1 is the ALWAYS
# floor (the "global by nature" class); g2/g3/g4 are path-scoped.
cat >"$FAKE/workflows/scripts/config/gate-paths.tsv" <<'EOF'
# fixture map
ALL	scripts/quality-gates.sh
none	LICENSE
bash g1.sh	ALWAYS
bash g2.sh	src/lib/**
bash g3.sh	docs/**
bash g4.sh	src/cli/**
EOF

# Patch the real script: same splice the sibling slice suite uses — replace the
# hardcoded gate-list region with the synthetic list, leaving the flag parsing,
# the selector wiring, the skip reporting, the run loop and the exit codes as
# the production code under test, byte for byte.
awk '
  /^KERNEL_GATES=\($/ { skipping = 1;
    print "KERNEL_GATES=("
    print "  \"bash g1.sh\""
    print "  \"bash g2.sh\""
    print "  \"bash g3.sh\""
    print "  \"bash g4.sh\""
    print ")"
    print "SKIPPED_KERNEL_GATES=()"
    next }
  skipping && /^# The overlay gate set/ { skipping = 0 }
  !skipping { print }
' "$SRC" >"$FAKE/scripts/quality-gates.sh"
chmod +x "$FAKE/scripts/quality-gates.sh"
bash -n "$FAKE/scripts/quality-gates.sh" \
  || { echo "FAIL: patched fixture does not parse — the awk splice needs updating" >&2; exit 1; }

# A real git repo, because the mode under test resolves its own base.
git -C "$FAKE" init -q
git -C "$FAKE" config user.email t@example.com
git -C "$FAKE" config user.name t
echo base >"$FAKE/README.md"
echo lib >"$FAKE/src/lib/thing.sh"
echo cli >"$FAKE/src/cli/main.sh"
echo doc >"$FAKE/docs/guide.md"
echo lic >"$FAKE/LICENSE"
# The red-gate sentinel and the per-run mark files are test scaffolding, not
# changes to the tree under test — ignore them so they never enter the changed
# set (and so case 8 tests a RED GATE rather than an unmapped-path escalation).
printf 'g4.red\n' >"$FAKE/.gitignore"
git -C "$FAKE" add -A
git -C "$FAKE" commit -qm base
git -C "$FAKE" branch -M main
git -C "$FAKE" checkout -qb feature

RUN_OUT=""; RUN_RC=0
run_qg() {
  local mark="$1"; shift
  RUN_RC=0
  RUN_OUT="$(env QG_SCOPED_MARK="$mark" QUALITY_GATES_SKIP_FRESHNESS=1 \
    GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 \
    bash "$FAKE/scripts/quality-gates.sh" "$@" 2>&1)" || RUN_RC=$?
}
ran() { grep -qx "$2" "$1" 2>/dev/null; }
# NB: an if/else, not `[ -f ] && … || …`. Under `set -o pipefail` a `grep -c`
# that counts ZERO exits 1, so the `||` arm would fire on top of the already-
# printed count and yield "00".
ran_count() { if [ -f "$1" ]; then grep -c . "$1" | tr -d ' '; else printf '0'; fi; }
reset_tree() {
  git -C "$FAKE" checkout -q -- . 2>/dev/null
  rm -f "$FAKE/src/cli/new.sh" "$FAKE/g4.red"
}

# --------------------------------------------------------------------------
# 1. BARE invocation is UNCHANGED — the whole safety case rests on this.
#    /build §3e.5 and CI's `checks` job call the script with no flags; they
#    must still get all four gates and a verdict with no scope qualifier.
# --------------------------------------------------------------------------
reset_tree
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m1"; : >"$M"
run_qg "$M"
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 4 ] \
   && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT" \
   && ! grep -q 'SCOPED SUBSET' <<<"$RUN_OUT" \
   && grep -q 'OK — all 4 quality gate(s) passed' <<<"$RUN_OUT"; then
  pass "bare run is unchanged: all 4 gates, no scope qualifier on the verdict"
else
  fail "bare run: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 2. --scoped narrows to the ALWAYS floor + the gates the change reaches, and
#    the change here is UNCOMMITTED — the mid-work case the mode exists for.
# --------------------------------------------------------------------------
M="$WORK/m2"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 0 ] && ran "$M" g1 && ran "$M" g2 \
   && ! ran "$M" g3 && ! ran "$M" g4; then
  pass "--scoped on an UNCOMMITTED edit runs the ALWAYS floor + the reached gate only"
else
  fail "--scoped narrowing: rc=$RUN_RC ran='$(cat "$M")'
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 3. It NAMES what it skipped, and why — the anti-false-green requirement.
#    Both un-run gates by name, the map named as the authority, and the
#    disclosure repeated at the verdict (a long run scrolls the first one off
#    screen, which is the same reason the staleness banner is repeated).
# --------------------------------------------------------------------------
disclosures="$(grep -c 'SCOPED RUN — ' <<<"$RUN_OUT")"
if grep -q 'not run (out of scope): bash g3.sh' <<<"$RUN_OUT" \
   && grep -q 'not run (out of scope): bash g4.sh' <<<"$RUN_OUT" \
   && grep -q 'gate-paths.tsv' <<<"$RUN_OUT" \
   && [ "$disclosures" -ge 2 ]; then
  pass "--scoped names every skipped gate and why, before the run AND at the verdict"
else
  fail "skip disclosure (found $disclosures):
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 4. The VERDICT LINE ITSELF is stamped. A one-line grep of a worker's log is
#    how this result actually gets read, so "OK — all N gates passed" must not
#    be greppable as a full-suite pass on a scoped run.
# --------------------------------------------------------------------------
if grep -q 'OK — all .* quality gate(s) passed .*\[SCOPED SUBSET — NOT a full-suite pass\]' <<<"$RUN_OUT"; then
  pass "--scoped stamps the verdict line itself with the scope"
else
  fail "verdict line is not scope-stamped:
$(grep 'OK — ' <<<"$RUN_OUT")"
fi

# --------------------------------------------------------------------------
# 5. A brand-new, never-added file is IN SCOPE. Without the untracked source
#    a worker's new file would select nothing and the run would silently
#    under-cover exactly the code most likely to be wrong.
# --------------------------------------------------------------------------
reset_tree
echo new >"$FAKE/src/cli/new.sh"
M="$WORK/m5"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 0 ] && ran "$M" g1 && ran "$M" g4 && ! ran "$M" g2; then
  pass "--scoped puts an UNTRACKED new file in scope"
else
  fail "untracked file scoping: rc=$RUN_RC ran='$(cat "$M")'
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 6. An ALL-escalation path widens to the FULL set even under --scoped.
# --------------------------------------------------------------------------
reset_tree
echo '# touched' >>"$FAKE/scripts/quality-gates.sh"
M="$WORK/m6"; : >"$M"
run_qg "$M" --scoped
if [ "$(ran_count "$M")" = 4 ] && ! grep -q 'SCOPED RUN' <<<"$RUN_OUT"; then
  pass "--scoped still escalates an ALL path to the full set"
else
  fail "ALL escalation under --scoped: ran=$(ran_count "$M")
$RUN_OUT"
fi
git -C "$FAKE" checkout -q -- scripts/quality-gates.sh 2>/dev/null || true
# The commit above restored the tracked copy; re-apply the patched fixture.
awk '
  /^KERNEL_GATES=\($/ { skipping = 1;
    print "KERNEL_GATES=("
    print "  \"bash g1.sh\""
    print "  \"bash g2.sh\""
    print "  \"bash g3.sh\""
    print "  \"bash g4.sh\""
    print ")"
    print "SKIPPED_KERNEL_GATES=()"
    next }
  skipping && /^# The overlay gate set/ { skipping = 0 }
  !skipping { print }
' "$SRC" >"$FAKE/scripts/quality-gates.sh"
chmod +x "$FAKE/scripts/quality-gates.sh"

# --------------------------------------------------------------------------
# 7. An UNMAPPED path widens to the FULL set. The map's headline defense,
#    re-proved through this entry point rather than assumed from the lib's.
# --------------------------------------------------------------------------
reset_tree
mkdir -p "$FAKE/nowhere"
echo x >"$FAKE/nowhere/x.txt"
M="$WORK/m7"; : >"$M"
run_qg "$M" --scoped
if [ "$(ran_count "$M")" = 4 ] && grep -q 'matches no glob' <<<"$RUN_OUT"; then
  pass "--scoped widens to the full set on an unmapped path, naming it"
else
  fail "unmapped-path escalation: ran=$(ran_count "$M")
$RUN_OUT"
fi
rm -rf "$FAKE/nowhere"

# --------------------------------------------------------------------------
# 8. A RED selected gate is still RED, and the FAILED line carries the scope.
#    Scoping must never be able to convert a failure into a pass.
# --------------------------------------------------------------------------
reset_tree
echo new >"$FAKE/src/cli/new.sh"
touch "$FAKE/g4.red"
M="$WORK/m8"; : >"$M"
run_qg "$M" --scoped
if [ "$RUN_RC" -eq 1 ] && grep -q 'FAILED 1/.*\[SCOPED SUBSET — NOT a full-suite pass\]' <<<"$RUN_OUT" \
   && grep -q 'QUALITY_GATES_FAILED=1' <<<"$RUN_OUT"; then
  pass "a red gate inside a --scoped run still exits non-zero, scope-stamped"
else
  fail "red gate under --scoped: rc=$RUN_RC
$RUN_OUT"
fi
reset_tree

# --------------------------------------------------------------------------
# 9. --list-selected --scoped is a DRY RUN: it prints the selection and the
#    skip list and runs NOTHING.
# --------------------------------------------------------------------------
echo edited >>"$FAKE/src/lib/thing.sh"
M="$WORK/m9"; : >"$M"
run_qg "$M" --list-selected --scoped
if [ "$RUN_RC" -eq 0 ] && [ "$(ran_count "$M")" = 0 ] \
   && grep -q '^bash g2.sh$' <<<"$RUN_OUT" \
   && grep -q 'not run (out of scope): bash g3.sh' <<<"$RUN_OUT"; then
  pass "--list-selected --scoped previews the selection and the skips without running a gate"
else
  fail "dry run: rc=$RUN_RC ran=$(ran_count "$M")
$RUN_OUT"
fi
reset_tree

# --------------------------------------------------------------------------
# 10. NO RESOLVABLE BASE -> the FULL set, out loud. A worktree with no
#     default-branch base must never narrow on its working-tree half alone.
# --------------------------------------------------------------------------
ORPHAN="$WORK/orphan"
cp -R "$FAKE" "$ORPHAN"
rm -rf "$ORPHAN/.git"
git -C "$ORPHAN" init -q
git -C "$ORPHAN" config user.email t@example.com
git -C "$ORPHAN" config user.name t
git -C "$ORPHAN" checkout -qb sidetrack 2>/dev/null || true
git -C "$ORPHAN" add -A && git -C "$ORPHAN" commit -qm x
echo edited >>"$ORPHAN/src/lib/thing.sh"
M="$WORK/m10"; : >"$M"
RUN_RC=0
RUN_OUT="$(env QG_SCOPED_MARK="$M" QUALITY_GATES_SKIP_FRESHNESS=1 \
  GATE_MAX_ATTEMPTS=1 GATE_RETRY_BACKOFF=0 \
  bash "$ORPHAN/scripts/quality-gates.sh" --scoped 2>&1)" || RUN_RC=$?
if [ "$(ran_count "$M")" = 4 ] && grep -q 'could not resolve a local changed set' <<<"$RUN_OUT"; then
  pass "--scoped with no resolvable base runs the FULL set and says why"
else
  fail "no-base fallback: ran=$(ran_count "$M")
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 11. An unknown flag is still a usage error (exit 2), and the usage line
#     advertises --scoped.
# --------------------------------------------------------------------------
M="$WORK/m11"; : >"$M"
run_qg "$M" --nope
if [ "$RUN_RC" -eq 2 ] && grep -q -- '--scoped' <<<"$RUN_OUT"; then
  pass "an unknown flag exits 2 and the usage line advertises --scoped"
else
  fail "flag parsing: rc=$RUN_RC
$RUN_OUT"
fi

# --------------------------------------------------------------------------
# 12. --list is untouched by all of this: still the FULL set, never scoped.
# --------------------------------------------------------------------------
M="$WORK/m12"; : >"$M"
run_qg "$M" --list
if [ "$RUN_RC" -eq 0 ] && [ "$(grep -c '^\[kernel\]' <<<"$RUN_OUT")" = 4 ] \
   && [ "$(ran_count "$M")" = 0 ]; then
  pass "--list still prints the FULL gate set and runs nothing"
else
  fail "--list: rc=$RUN_RC
$RUN_OUT"
fi

echo
if [ "$fail_count" -eq 0 ]; then
  echo "OK — quality-gates.sh --scoped: all cases passed"
  exit 0
fi
echo "FAILED $fail_count case(s)" >&2
exit 1
