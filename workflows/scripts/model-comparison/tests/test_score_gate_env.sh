#!/usr/bin/env bash
#
# test_score_gate_env.sh — the quality-gate CHILD's constructed environment
# (temperloop#1378 primary symptom, temperloop#1377 second symptom; epic
# #1225 "model comparison harness").
#
# ── WHAT WENT WRONG, AND WHY A SEPARATE SUITE PINS IT ─────────────────────
# score.sh sources workflows/scripts/build/build.config.sh for its own two
# settings. That file first sources the operator's MACHINE CONF (precedence
# layer 3) and the repo-local conf (layer 4), then `export`s ~83 pipeline
# settings — so before the fix the gate child simply INHERITED all of them
# (measured: 127 vars in the child vs. 10 after). Two distinct symptoms, one
# seam:
#
#   #1378 — build.config.sh's `:=` idiom makes an already-set ENV value win
#     over every lower layer, so any suite that asserts the precedence ladder
#     itself resolves differently under score.sh than bare.
#     bin/subcommands/tests/test_config.sh case 2 is exactly that suite: its
#     `machine-conf-set BUILD_MERGE_GATE_WINDOW` assertion read `layer=env`
#     under score.sh and `layer=machine-conf` bare. Consequence: EVERY
#     replay's `gate_result.passed` was deterministically false regardless of
#     candidate quality — a model that fixed its issue perfectly and one that
#     changed nothing scored identically, and the mechanical outcome scorer
#     (#1258) contributed zero discriminating signal.
#
#   #1377 — the leaked set included KNOWLEDGE_STORE_ROOT, pointing at the
#     operator's REAL knowledge store. workflows/scripts/tests/
#     test_install_lifecycle.sh step 4b runs its sync-init leg through the
#     DEFAULT root seam under a sandboxed XDG_DATA_HOME; an explicit
#     KNOWLEDGE_STORE_ROOT overrides that seam, so the leg `git init`-ed the
#     operator's live store. Operator data damage from an environment
#     variable — which is why the absence of that ONE name is asserted on its
#     own, not merely folded into a prefix sweep.
#
# test_replay_score.sh cannot observe either: its fixture gates are trivial
# scripts that never read a setting and never report their own environment.
# The defect is invisible to a gate that does not look — hence this suite,
# whose fixture gates DO look.
#
# ── THE ANTI-VACUITY CONTROL (section A0) ─────────────────────────────────
# An "absent from the child" assertion is worthless if the leak was never
# armed in the first place — on a host with no machine conf, KNOWLEDGE_STORE_
# ROOT is simply unset and `export` of an unset name adds nothing, so the
# assertion would pass for the wrong reason. So this suite SUPPLIES its own
# machine conf through an XDG_CONFIG_HOME fixture and first PROVES, by
# sourcing build.config.sh exactly the way score.sh does, that the three
# fixture values really are exported into a would-be parent process. Only
# then does absence in the child mean anything.
#
# ── HERMETIC, AND STRUCTURALLY UNABLE TO TOUCH A REAL STORE ───────────────
# XDG_CONFIG_HOME and XDG_DATA_HOME are pointed at fixture dirs under $WORK
# for every invocation, so the machine conf this suite reads is its OWN and
# any default-root store resolution lands under $WORK. The fixture
# KNOWLEDGE_STORE_ROOT value is a path under $WORK that this suite never
# creates. No network, no `gh`, no `claude`, no writes outside $TMPDIR.
#
# Sections:
#   A0  control: the fixture machine conf really does arm the leak
#   A   the gate child's environment is CONSTRUCTED, not inherited
#   B   the primary symptom, measured against the REAL config-ladder suite:
#       score.sh's verdict equals the bare verdict
#   C   `score.sh score` (not just `gates`) gets the same clean child
#
# Usage: bash workflows/scripts/model-comparison/tests/test_score_gate_env.sh

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
REPO_ROOT="$(cd -P "$MC_DIR/../../.." && pwd)"
SCORE="$MC_DIR/score.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$SCORE" ] || fail "score.sh not found at $SCORE"
[ -f "$REPO_ROOT/workflows/scripts/build/build.config.sh" ] \
  || fail "build.config.sh not found under \$REPO_ROOT ($REPO_ROOT) — the leak source this suite pins"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-score-gate-env-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE MACHINE CONF — precedence layer 3, supplied by this suite so
# the leak is armed identically on every host (an operator's Mac with a real
# conf, and a CI runner with none).
# ═══════════════════════════════════════════════════════════════════════════
XDGC="$WORK/xdg-config"
XDGD="$WORK/xdg-data"
mkdir -p "$XDGC/temperloop" "$XDGD"

# A path this suite deliberately NEVER creates: standing in for the
# operator's real knowledge store, whose git-init was #1377's damage.
FIXTURE_STORE="$WORK/fixture-knowledge-store"

cat >"$XDGC/temperloop/build.config.sh" <<EOF
# fixture machine conf (precedence layer 3) — see test_score_gate_env.sh
: "\${KNOWLEDGE_STORE_ROOT:=$FIXTURE_STORE}"
: "\${BUILD_MERGE_GATE_WINDOW:=999}"
: "\${REPLAY_SCORE_GATE_TIMEOUT_SECS:=1234}"
EOF

# Every invocation below runs under the fixture XDG roots. Nothing else about
# the caller's environment is altered: PATH/HOME stay real, because the point
# is what score.sh does with a REAL, populated environment.
fixture_env() { env XDG_CONFIG_HOME="$XDGC" XDG_DATA_HOME="$XDGD" "$@"; }

# The names build.config.sh exports. A child carrying ANY of these inherited
# the pipeline's configuration it has no business reading.
LEAK_PREFIX_RE='^(KNOWLEDGE_STORE_|BUILD_|PIPELINE_|REPLAY_|MODEL_COMPARISON_|SWEEP_|RETRO_|SPEND_|ASSESS_POLL_|TIDY_|NEXT_SEQ_|CHECKIN_|FIX_WORKER_|EPIC_MIN_|DISPLAY_TZ|PROSE_BUDGET_|REVIEWER_SCAN_|CONFIGURE_AI_)'

# mk_recorder_gate <dir> <env-dump-path> — writes a gate entry point that
# reports its OWN process environment and exits 0.
mk_recorder_gate() {
  local d="$1" dump="$2"
  mkdir -p "$d/scripts"
  cat >"$d/scripts/quality-gates.sh" <<EOF
#!/usr/bin/env bash
env >"$dump"
exit 0
EOF
  chmod +x "$d/scripts/quality-gates.sh"
}

# ═══════════════════════════════════════════════════════════════════════════
# A0. CONTROL — the fixture machine conf really does arm the leak.
#     Sources build.config.sh exactly as score.sh line ~102 does. If this
#     section fails, every "absent from the child" assertion below would be
#     vacuously true and the suite would be testing nothing.
# ═══════════════════════════════════════════════════════════════════════════
PARENT_DUMP="$WORK/parent-env.txt"
fixture_env bash -c '
  set -u
  . "$1/workflows/scripts/build/build.config.sh"
  env
' _ "$REPO_ROOT" >"$PARENT_DUMP" 2>/dev/null

count
if grep -q "^KNOWLEDGE_STORE_ROOT=$FIXTURE_STORE\$" "$PARENT_DUMP"; then
  ok "A0a sourcing build.config.sh DOES export KNOWLEDGE_STORE_ROOT into the process (the leak is armed)"
else
  fail "A0a the fixture machine conf did not arm the leak — build.config.sh exported no KNOWLEDGE_STORE_ROOT=$FIXTURE_STORE.
       Without this, every absence assertion below is vacuous.
       got: $(grep -c . "$PARENT_DUMP" 2>/dev/null || echo 0) vars, KNOWLEDGE_STORE_ROOT=$(grep '^KNOWLEDGE_STORE_ROOT=' "$PARENT_DUMP" || echo '<unset>')"
fi

count
if grep -q '^BUILD_MERGE_GATE_WINDOW=999$' "$PARENT_DUMP"; then
  ok "A0b sourcing build.config.sh DOES export BUILD_MERGE_GATE_WINDOW=999 (the #1378 ladder-poisoning value)"
else
  fail "A0b the fixture machine conf did not arm BUILD_MERGE_GATE_WINDOW=999 (got: $(grep '^BUILD_MERGE_GATE_WINDOW=' "$PARENT_DUMP" || echo '<unset>'))"
fi

# ═══════════════════════════════════════════════════════════════════════════
# A. The gate child's environment is CONSTRUCTED, not inherited.
# ═══════════════════════════════════════════════════════════════════════════
WT_A="$WORK/wt-a"
CHILD_DUMP="$WORK/child-env.txt"
mk_recorder_gate "$WT_A" "$CHILD_DUMP"

out_a="$(fixture_env bash "$SCORE" gates --worktree "$WT_A" 2>"$WORK/err-a.txt")"
rc_a=$?

count
if [ "$rc_a" -eq 0 ] && printf '%s' "$out_a" | jq -e '.outcome == "GATES" and .passed == true' >/dev/null 2>&1; then
  ok "A1 \`score.sh gates\` ran the worktree's own gate entry point and reported it passed"
else
  fail "A1 \`score.sh gates\` did not report a passing gate (rc=$rc_a): $out_a
       stderr: $(head -c 400 "$WORK/err-a.txt")"
fi

count
[ -f "$CHILD_DUMP" ] || fail "A2 the gate child never ran — no environment was recorded (rc=$rc_a)"
child_n="$(grep -c . "$CHILD_DUMP")"
ok "A2 the gate child ran and recorded its own environment ($child_n variables)"

# ── #1377, asserted ALONE: the one name whose leak damaged operator data ──
count
if grep -q '^KNOWLEDGE_STORE_ROOT=' "$CHILD_DUMP"; then
  fail "A3 KNOWLEDGE_STORE_ROOT REACHED the gate child — this is temperloop#1377: an explicit root overrides
       test_install_lifecycle.sh step 4b's sandboxed default-root seam, and its sync-init leg then
       \`git init\`s whatever that value points at.
       got: $(grep '^KNOWLEDGE_STORE_ROOT=' "$CHILD_DUMP")"
fi
ok "A3 KNOWLEDGE_STORE_ROOT is ABSENT from the gate child's environment (temperloop#1377)"

count
if [ -e "$FIXTURE_STORE" ]; then
  fail "A4 the fixture knowledge-store path was created by the gate run: $FIXTURE_STORE"
fi
ok "A4 the fixture knowledge-store path was never created by the gate run"

# ── #1378, the ladder-poisoning name ──────────────────────────────────────
count
if grep -q '^BUILD_MERGE_GATE_WINDOW=' "$CHILD_DUMP"; then
  fail "A5 BUILD_MERGE_GATE_WINDOW REACHED the gate child — inside it, build.config.sh's \`:=\` idiom makes
       this env value outrank the machine-conf layer, which is temperloop#1378's primary symptom.
       got: $(grep '^BUILD_MERGE_GATE_WINDOW=' "$CHILD_DUMP")"
fi
ok "A5 BUILD_MERGE_GATE_WINDOW is ABSENT from the gate child's environment (temperloop#1378)"

# ── the whole exported set, not just the two named symptoms ───────────────
count
leaked="$(grep -E "$LEAK_PREFIX_RE" "$CHILD_DUMP" 2>/dev/null | cut -d= -f1 | sort -u)"
if [ -n "$leaked" ]; then
  fail "A6 pipeline settings reached the gate child — the environment is inherited, not constructed:
$(printf '%s\n' "$leaked" | sed 's/^/         /')"
fi
ok "A6 NO build.config.sh-exported pipeline setting reached the gate child (absent by construction, not by denylist)"

# ── SUFFICIENCY: an allowlist that starves the gate trades one false signal
#    for another. The floor a `make`-driven suite cannot start without. ────
count
missing=""
for name in PATH HOME; do
  grep -q "^$name=" "$CHILD_DUMP" || missing="$missing $name"
done
if [ -n "$missing" ]; then
  fail "A7 the allowlist is too tight — the gate child received no$missing, which a \`make\`-driven suite cannot start without"
fi
ok "A7 the allowlist is SUFFICIENT at the floor: the gate child still receives PATH and HOME"

# ── score.sh may still read its OWN config: the fix is about the CHILD ────
count
if printf '%s' "$out_a" | jq -e '.timeout_secs == 1234' >/dev/null 2>&1; then
  ok "A8 score.sh still resolved its OWN setting from build.config.sh (REPLAY_SCORE_GATE_TIMEOUT_SECS=1234 from the fixture machine conf)"
else
  fail "A8 score.sh stopped reading its own config — the fix must constrain the CHILD, never make score.sh go without
       REPLAY_SCORE_GATE_RELPATH / REPLAY_SCORE_GATE_TIMEOUT_SECS.
       got timeout_secs: $(printf '%s' "$out_a" | jq -c '.timeout_secs // "?"')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# B. THE PRIMARY SYMPTOM, measured against the REAL config-ladder suite.
#    bin/subcommands/tests/test_config.sh asserts the six-layer precedence
#    ladder itself, so it is the suite the leak actually flipped. The
#    property: score.sh's verdict EQUALS the bare verdict.
# ═══════════════════════════════════════════════════════════════════════════
LADDER_SUITE="$REPO_ROOT/bin/subcommands/tests/test_config.sh"
count
[ -f "$LADDER_SUITE" ] \
  || fail "B0 the real config-ladder suite is missing at $LADDER_SUITE — this section cannot measure the primary symptom"
ok "B0 the real config-ladder suite is present ($LADDER_SUITE)"

WT_B="$WORK/wt-b"
mkdir -p "$WT_B/scripts"
LADDER_OUT_SCORED="$WORK/ladder-out-scored.txt"
LADDER_OUT_BARE="$WORK/ladder-out-bare.txt"
# The gate entry point IS the real ladder suite. Its output path is baked in
# as a literal, because the child runs under `env -i` + a named allowlist —
# a fixture env var would not survive that boundary.
cat >"$WT_B/scripts/quality-gates.sh" <<EOF
#!/usr/bin/env bash
bash "$LADDER_SUITE" >"\${SCORE_GATE_LADDER_OUT:-$LADDER_OUT_SCORED}" 2>&1
exit \$?
EOF
chmod +x "$WT_B/scripts/quality-gates.sh"

out_b="$(fixture_env bash "$SCORE" gates --worktree "$WT_B" 2>"$WORK/err-b.txt")"
rc_b=$?

# The BARE baseline: the identical entry point, invoked directly, under the
# identical fixture environment. The ONLY difference is score.sh.
# NEVER measured through a pipe or a wrapper — a pipe's exit code is the
# reader's, and this repo has already had a failing gate report exit 0 that way.
fixture_env env SCORE_GATE_LADDER_OUT="$LADDER_OUT_BARE" bash "$WT_B/scripts/quality-gates.sh"
rc_bare=$?

count
if [ "$rc_bare" -eq 0 ]; then
  ok "B1 the bare baseline is green: the real config-ladder suite passes when invoked directly (exit 0)"
else
  fail "B1 the bare baseline is NOT green (exit $rc_bare) — this section cannot distinguish the leak from a
       genuinely failing ladder suite: $(tail -c 600 "$LADDER_OUT_BARE" 2>/dev/null)"
fi

count
scored_passed="$(printf '%s' "$out_b" | jq -r '.passed // "?"' 2>/dev/null)"
if [ "$rc_b" -eq 0 ] && [ "$scored_passed" = "true" ]; then
  ok "B2 score.sh's verdict EQUALS the bare verdict (both pass) — the gate is a discriminating signal again"
else
  fail "B2 score.sh reported the gate FAILED while the identical entry point passes bare — temperloop#1378.
       score.sh: rc=$rc_b passed=$scored_passed
       the ladder suite's output UNDER score.sh:
$(tail -c 900 "$LADDER_OUT_SCORED" 2>/dev/null | sed 's/^/         /')"
fi

# The named case the whole defect turns on.
count
if grep -q 'PASS: a machine-conf file setting a var wins over its tracked-repo default (layer=machine-conf)' "$LADDER_OUT_SCORED" 2>/dev/null; then
  ok "B3 under score.sh, \`machine-conf-set BUILD_MERGE_GATE_WINDOW\` resolves layer=machine-conf (not layer=env)"
else
  fail "B3 under score.sh, the machine-conf case did not resolve to layer=machine-conf — the leaked env value outranked it:
$(grep -E 'machine-conf|FAIL' "$LADDER_OUT_SCORED" 2>/dev/null | head -5 | sed 's/^/         /')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# C. `score.sh score` — not only `gates` — gets the same clean child. The
#    scoring path is the one every replay actually takes.
# ═══════════════════════════════════════════════════════════════════════════
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name T
git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/src"
printf 'at base\n' >"$REPO/src/thing.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"
printf 'at truth\n' >"$REPO/src/thing.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm truth
TRUTH="$(git -C "$REPO" rev-parse HEAD)"

WT_C="$WORK/wt-c"
git -C "$REPO" worktree add -q -b cand-c "$WT_C" "$BASE" >/dev/null 2>&1 \
  || fail "C0 could not prepare a candidate worktree"
WT_C="$(cd -P "$WT_C" && pwd)"
printf 'candidate edit\n' >"$WT_C/src/thing.txt"
CHILD_DUMP_C="$WORK/child-env-c.txt"
mk_recorder_gate "$WT_C" "$CHILD_DUMP_C"

RECORD="$WORK/record.json"
jq -cn --arg base "$BASE" --arg head "$TRUTH" \
  '{schema_version:"replay-record-v1", pr:1378, issue:"#1378",
    base:$base, head:$head, flags:[],
    acceptance:["The gate child runs under a constructed environment."],
    buckets:{N:["src/thing.txt"], T:[], X:[], R:[]}}' >"$RECORD"

out_c="$(fixture_env bash "$SCORE" score --repo-root "$REPO" \
           --candidate-worktree "$WT_C" --record "$RECORD" 2>"$WORK/err-c.txt")"
rc_c=$?

count
if [ "$rc_c" -eq 0 ] && printf '%s' "$out_c" | jq -e '.outcome == "SCORED" and .gate_result.passed == true' >/dev/null 2>&1; then
  ok "C1 \`score.sh score\` produced a SCORED record whose gate_result.passed is true"
else
  fail "C1 \`score.sh score\` did not produce a passing-gate SCORED record (rc=$rc_c): $(printf '%s' "$out_c" | head -c 400)
       stderr: $(head -c 400 "$WORK/err-c.txt")"
fi

count
[ -f "$CHILD_DUMP_C" ] || fail "C2 the scoring path's gate child never ran — no environment was recorded"
if grep -q '^KNOWLEDGE_STORE_ROOT=' "$CHILD_DUMP_C"; then
  fail "C2 KNOWLEDGE_STORE_ROOT reached the SCORING path's gate child: $(grep '^KNOWLEDGE_STORE_ROOT=' "$CHILD_DUMP_C")"
fi
leaked_c="$(grep -E "$LEAK_PREFIX_RE" "$CHILD_DUMP_C" 2>/dev/null | cut -d= -f1 | sort -u)"
if [ -n "$leaked_c" ]; then
  fail "C2 pipeline settings reached the SCORING path's gate child:
$(printf '%s\n' "$leaked_c" | sed 's/^/         /')"
fi
ok "C2 the scoring path's gate child is equally clean (\`score\` and \`gates\` share ONE gate runner)"

git -C "$REPO" worktree remove --force "$WT_C" >/dev/null 2>&1

echo
echo "test_score_gate_env.sh: $pass/$total passed"
[ "$pass" -eq "$total" ] || exit 1
exit 0
