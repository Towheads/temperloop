#!/usr/bin/env bash
#
# test_replay_batch.sh — fixture suite for the replay BATCH DRIVER
# (temperloop#1401, epic #1225 "model comparison harness"): batch.sh, the
# operator-invoked thing that turns a corpus file into the two arm files
# workflows/scripts/report-producers/model-comparison reads.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE ───────────────────────────────
# This is the file that would spend a whole BATCH of real money if it ever
# reached a model by accident — one mistake here multiplies by the corpus
# size. Two independent mechanisms, both asserted:
#
#   1. THE SEAM. Every batch below drives BOTH arms (and the judge) through
#      RECORDED runners on disk. `--live` is never passed by any test in this
#      file, and batch.sh refuses — before it prepares a worktree and before
#      it even consults the spend gate — when an arm has no seam.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to `$WORK/CANARY`.
#      Section I asserts that file never came into existence, and section I2
#      proves the canary is genuinely capable of firing. Section H MUTATES
#      the driver's candidate-arm seam selection (in a throwaway mirror of
#      the module) to force `--live`, and proves the canary DOES fire — so
#      "no live call" is a MEASUREMENT of the whole run rather than a claim
#      about the tests someone remembered to check.
#
# No network, no `gh`, no model call, no writes outside $TMPDIR.
#
# ── WHAT EACH SECTION PINS ─────────────────────────────────────────────────
#   A  THE SEAM — every un-seamed arm refuses BEFORE anything is spent
#   B  THE GATE RUNS FIRST — a stopped pre-flight, and an unconfirmed batch,
#      execute NOTHING (+ MUTATION PROOF that neutering the stop check does
#      execute, i.e. the gate is load-bearing)
#   C  THE TWO-ARM UNIT CONTRACT + THE BATCH CAP (temperloop#1379) — the cap
#      binds CORPUS RECORDS, every selected record is replayed in BOTH arms,
#      and the driver's authorized figures are the GATE's own (+ two
#      MUTATION PROOFS: a one-arm loop, and a cap taken from anywhere but
#      the gate)
#   D  ONE RECORD'S FAILURE DOES NOT ABORT THE BATCH, and the completion rate
#      falls out of the driver's own output (+ MUTATION PROOF that counting a
#      failed leg as completed reports 1.0 — the temperloop#1365 "could not
#      evaluate rendered as evaluated, and fine" class)
#   E  RESUMABILITY — a re-invocation re-spends nothing (+ MUTATION PROOF
#      that neutering the resume check DOES re-spend), and a state dir bound
#      to a different batch is refused
#   F  ISOLATION — every prepared worktree is torn down on the success AND
#      the failure path, and verify-clean-parent passes (+ MUTATION PROOF)
#   G  THE REPORT PRODUCER CONSUMES THE OUTPUT UNCHANGED — the real producer
#      is run on the driver's own fixture output
#   H  JUDGING — wired, resumable, and a skip is NAMED rather than silent
#      (+ the live-arm MUTATION PROOF)
#   I  the suite-wide no-live-call canary verdict
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_batch.sh
#
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/batch.sh"
PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-batch-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
# THE CANARY — a `claude` on PATH that no test may ever reach.
# ═══════════════════════════════════════════════════════════════════════════
CANARY="$WORK/CANARY"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
# Suite canary: if anything under test invokes a bare 'claude', this records
# it. Section I fails the whole suite if this file exists at the end.
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

# mutate_file <file> <old-literal> <new-literal> — exact, literal,
# single-occurrence replacement (the same helper, and the same rationale, as
# test_replay_score.sh's). Dies loudly if the old text is missing or not
# unique, so a mutation proof can never silently become a no-op that passes.
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts,
# so a mutation proof edits ONE real copy of a script and never writes into
# the checkout. Relative resolution ($HERE/../build, $HERE/replay.sh) still
# works because the DIRECTORIES are real and only the leaves are links.
mk_mirror() {
  local d="$1" f b
  mkdir -p "$d/workflows/scripts/model-comparison"
  for f in "$SCRIPTS_DIR"/*; do
    b="$(basename "$f")"
    [ "$b" = "model-comparison" ] && continue
    ln -s "$f" "$d/workflows/scripts/$b"
  done
  for f in "$MC_DIR"/*; do
    ln -s "$f" "$d/workflows/scripts/model-comparison/$(basename "$f")"
  done
}

# unlink_and_copy <mirror-path> — swap one mirrored symlink for a real,
# editable copy of its target.
unlink_and_copy() {
  local p="$1" target real
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# ═══════════════════════════════════════════════════════════════════════════
# THE FIXTURE REPO — an origin remote (worktree.sh create resolves
# origin/HEAD), a base commit, a merged "truth" commit, and an in-tree gate
# script so score.sh runs the WORKTREE'S OWN gate (trap C, "never mix trees").
# ═══════════════════════════════════════════════════════════════════════════
ORIGIN="$WORK/origin.git"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name  T
git -C "$REPO" config commit.gpgsign false

mkdir -p "$REPO/workflows/scripts/drain" "$REPO/scripts" "$REPO/claude/workflows" "$REPO/.temperloop"
cat >"$REPO/workflows/scripts/drain/scan_stub.py" <<'PY'
def _is_command_expansion_turn(turn_text):
    return False
PY
printf '# changelog\n' >"$REPO/CHANGELOG.md"
printf '// build-level at base\n' >"$REPO/claude/workflows/build-level.mjs"
# The driver's default output directory is MODEL_COMPARISON_REPORT_RECORDS_DIR
# under the repo root, and the real kernel checkout gitignores it. The fixture
# repo carries the same ignore, because `replay.sh verify-clean-parent` is a
# REAL assertion here: an un-ignored output directory would (correctly) leave
# the parent dirty and the isolation backstop would (correctly) say so.
printf 'model-comparison/\n' >"$REPO/.temperloop/.gitignore"
cat >"$REPO/scripts/quality-gates.sh" <<'GATE'
#!/usr/bin/env bash
# fixture gate: red iff a GATE_FAIL marker exists in the tree it runs against
if [ -f "GATE_FAIL" ]; then
  echo "fixture gate: FAIL"
  exit 1
fi
echo "fixture gate: OK"
exit 0
GATE
chmod +x "$REPO/scripts/quality-gates.sh"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"

git -C "$REPO" checkout -qb truth
cat >"$REPO/workflows/scripts/drain/scan_stub.py" <<'PY'
import re

_CMD_INVOCATION_PATTERN = re.compile(r'<command-name>', re.IGNORECASE)


def _is_command_expansion_turn(turn_text):
    return bool(_CMD_INVOCATION_PATTERN.search(turn_text))
PY
mkdir -p "$REPO/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho truth-test\n' >"$REPO/workflows/scripts/drain/tests/test_scan_stub.sh"
printf '# changelog\n\n- entry\n' >"$REPO/CHANGELOG.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "truth"
TRUTH="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main
git -C "$REPO" remote set-head origin -a >/dev/null

TEMPLATE_SHA="$(git -C "$REPO" rev-parse "$BASE:claude/workflows/build-level.mjs")"
TRUTH_PY="$WORK/truth-scan_stub.py"
git -C "$REPO" show "$TRUTH:workflows/scripts/drain/scan_stub.py" >"$TRUTH_PY"
BOGUS_BASE="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# ── corpus records ─────────────────────────────────────────────────────────
# mk_corpus_line <pr> <status> <base-sha>
mk_corpus_line() {
  jq -cn --argjson pr "$1" --arg st "$2" --arg base "$3" --arg head "$TRUTH" --arg tpl "$TEMPLATE_SHA" \
    '{schema_version:"replay-record-v1", pr:$pr, issue:("#" + ($pr|tostring)),
      merge_commit:null, base:$base, head:$head,
      title:"Exclude the expanded command-spec turn", scope:"drain scan_stub.py",
      acceptance:["A named path is fixed."], notes:"", status:$st, reject_reason:"", flags:[],
      buckets:{N:["workflows/scripts/drain/scan_stub.py"],
               T:["workflows/scripts/drain/tests/test_scan_stub.sh"],
               X:["CHANGELOG.md"], R:[]},
      template_sha:$tpl, file_count:2,
      worktree:{path:null,branch:null,prepared_at:null},
      candidate:{provider:null,model:null,diff_ref:null},
      score:{verdict:null,acceptance_results:null,gate_result:null}}'
}

# CORPUS_A — the happy path: 2 eligible records, 1 rejected (never replayed).
CORPUS_A="$WORK/corpus-a.jsonl"
{ mk_corpus_line 101 eligible "$BASE"
  mk_corpus_line 102 rejected "$BASE"
  mk_corpus_line 103 flagged-eligible "$BASE"; } >"$CORPUS_A"

# CORPUS_CAP — 3 eligible records, exercised under a batch cap of 2.
CORPUS_CAP="$WORK/corpus-cap.jsonl"
{ mk_corpus_line 201 eligible "$BASE"
  mk_corpus_line 202 eligible "$BASE"
  mk_corpus_line 203 eligible "$BASE"; } >"$CORPUS_CAP"

# CORPUS_FAIL — 3 eligible records, the MIDDLE one carrying an unreachable
# base so its worktree can never be prepared. Both of its legs fail; the
# batch must carry on and still produce the other two records in both arms.
CORPUS_FAIL="$WORK/corpus-fail.jsonl"
{ mk_corpus_line 301 eligible "$BASE"
  mk_corpus_line 302 eligible "$BOGUS_BASE"
  mk_corpus_line 303 eligible "$BASE"; } >"$CORPUS_FAIL"

# ── the RECORDED candidate runners (the test seam) ─────────────────────────
# Invoked as `<cmd> <prompt-file> <worktree>`. They reach no network: each
# replays a canned envelope and makes a fixed set of edits in the worktree.
# Each also APPENDS to a call log, which is how section E measures that a
# resumed run re-spent nothing.
mk_stub() {  # mk_stub <path> <model-key> <log>
  local p="$1" modelkey="$2" log="$3"
  cat >"$p" <<STUBEOF
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$modelkey" "\$1" >>"$log"
wt="\$2"
cp "$TRUTH_PY" "\$wt/workflows/scripts/drain/scan_stub.py"
mkdir -p "\$wt/workflows/scripts/drain/tests"
printf '#!/usr/bin/env bash\necho candidate-test\n' >"\$wt/workflows/scripts/drain/tests/test_scan_stub.sh"
jq -cn --arg m "$modelkey" '{type:"result", subtype:"success", is_error:false, duration_ms:4242,
  modelUsage:{(\$m):{inputTokens:1200, outputTokens:340,
                     cacheReadInputTokens:9000, cacheCreationInputTokens:120,
                     provider:"firstParty"}}}'
STUBEOF
  chmod +x "$p"
}
CAND_LOG="$WORK/candidate-calls.log"; : >"$CAND_LOG"
BASE_STUB="$WORK/stub-baseline.sh"
CAND_STUB="$WORK/stub-candidate.sh"
mk_stub "$BASE_STUB" "recorded-baseline-model" "$CAND_LOG"
mk_stub "$CAND_STUB" "recorded-candidate-model" "$CAND_LOG"

# ── the RECORDED judge runner ──────────────────────────────────────────────
# Invoked as `<cmd> <prompt-file>` (judge.sh's own contract — no worktree).
JUDGE_LOG="$WORK/judge-calls.log"; : >"$JUDGE_LOG"
JUDGE_STUB="$WORK/stub-judge.sh"
cat >"$JUDGE_STUB" <<JEOF
#!/usr/bin/env bash
set -u
printf 'judge %s\n' "\$1" >>"$JUDGE_LOG"
resp='{"quality_score":72,"dimensions":{"correctness":70,"scope":74},"rationale":"recorded","concerns":[]}'
jq -cn --arg r "\$resp" '{type:"result", subtype:"success", is_error:false, duration_ms:77,
  result:\$r,
  modelUsage:{"recorded-judge-model":{inputTokens:10, outputTokens:5,
                                      cacheReadInputTokens:0, cacheCreationInputTokens:0}}}'
JEOF
chmod +x "$JUDGE_STUB"

# ── env every batch run gets: the quota gate deterministically "unavailable"
#    (fail open — it can never be the reason anything below stops), the
#    attribution lake and the disclosure log pointed INTO $WORK, never at the
#    checkout. ────────────────────────────────────────────────────────────
NOCACHE="$WORK/no-such-quota-cache.json"
LAKE="$WORK/lake"; mkdir -p "$LAKE"
DLOG="$WORK/disclosure-log.jsonl"
ALLOW="$WORK/allow.txt"; printf 'anthropic\nopenai\n' >"$ALLOW"
NOLOCAL="$WORK/no-such-local-override.txt"

# drive <sut-or-empty> <env-assignments-as-one-string> <args...> — runs the
# driver, captures stdout in $OUT and the exit code in $RC.
OUT=""; RC=0
drive() {
  local sut="$1"; shift
  [ -n "$sut" ] || sut="$SUT"
  RC=0
  OUT="$(env BUILD_QUOTA_CACHE="$NOCACHE" \
             MODEL_USAGE_RAW_DIR="$LAKE" \
             PROVIDER_ALLOWLIST_TEST_SEAM=1 \
             PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
             PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
             PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
             "$@" bash "$sut" run "${DRIVE_ARGS[@]}" 2>"$WORK/last-stderr.txt")" || RC=$?
}

lines() {  # line count of a file that may legitimately be empty or absent
  [ -f "$1" ] || { printf '0'; return 0; }
  wc -l <"$1" | tr -d ' '
}

wt_count() {  # how many mc-replay-* worktrees the fixture repo currently has
  local n=0 d
  for d in "${REPO}.wt"/mc-replay-*; do
    [ -e "$d" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — THE SEAM. Every un-seamed arm refuses, before ANY spend.
# ═══════════════════════════════════════════════════════════════════════════
A_OUT="$WORK/out-a"; A_STATE="$WORK/state-a"

# A1 — no runner at all, no --live.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE" --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A1: a batch with NO candidate runner and NO --live must refuse, got exit 0: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A1: expected CANNOT_EVALUATE, got: $OUT"
grep -q 'NO implicit fallback' <<<"$OUT" || fail "A1: the refusal must name the absent seam: $OUT"
[ ! -e "$A_OUT/baseline.jsonl" ] || fail "A1: a refused batch wrote an arm file"
[ "$(wt_count)" = "0" ] || fail "A1: a refused batch prepared a worktree"
[ ! -e "$CANARY" ] || fail "A1: the refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "A1 no candidate runner and no --live: CANNOT EVALUATE, non-zero, nothing prepared, nothing written"

# A2 — only ONE arm seamed. A batch is two arms; half a seam is no seam.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A2: a batch with only the baseline arm seamed must refuse: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A2: expected CANNOT_EVALUATE, got: $OUT"
ok "A2 only one arm seamed: CANNOT EVALUATE (a two-arm run needs two seams)"

# A3 — --live AND a recorded runner: mutually exclusive, refused.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --live --confirm)
drive ""
[ "$RC" -ne 0 ] || fail "A3: --live plus a recorded runner must refuse: $OUT"
grep -q 'mutually exclusive' <<<"$OUT" || fail "A3: expected a mutual-exclusion refusal, got: $OUT"
[ ! -e "$CANARY" ] || fail "A3: the refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "A3 --live plus a recorded runner: mutually exclusive, refused before any spend"

# A4 — an unreadable corpus file is CANNOT EVALUATE, never an empty batch
#      reported as a completed one.
count
DRIVE_ARGS=(--corpus-file "$WORK/no-such-corpus.jsonl" --repo-root "$REPO" --out-dir "$A_OUT"
            --state-dir "$A_STATE" --baseline-runner "bash $BASE_STUB"
            --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 1 ] || fail "A4: an absent corpus file should be CANNOT_EVALUATE exit 1, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "A4: expected CANNOT_EVALUATE, got: $OUT"
ok "A4 absent corpus file: CANNOT EVALUATE, never a vacuous 'complete' batch"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — THE GATE RUNS FIRST, and it is load-bearing.
# ═══════════════════════════════════════════════════════════════════════════

# B1 — --preflight-only prints the gate's own verdict and executes nothing.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --confirm --preflight-only)
drive ""
[ "$RC" -eq 0 ] || fail "B1: --preflight-only should exit 0 on an un-stopped gate, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "PREFLIGHT" ] || fail "B1: expected the gate's own PREFLIGHT object, got: $OUT"
[ "$(jq -r '.planned_records_n' <<<"$OUT")" = "2" ] || fail "B1: expected 2 planned corpus records, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B1: --preflight-only invoked a candidate runner"
ok "B1 --preflight-only: the gate's verdict, and not one replay executed"

# B2 — NO --confirm: STOPPED, spent:false, nothing prepared, nothing written.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB")
drive ""
[ "$RC" -eq 3 ] || fail "B2: an unconfirmed batch should STOP with exit 3, got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "STOPPED" ] || fail "B2: expected STOPPED, got: $OUT"
[ "$(jq -r '.stop_reason' <<<"$OUT")" = "confirmation_required" ] || fail "B2: expected stop_reason confirmation_required, got: $OUT"
[ "$(jq -r '.spent' <<<"$OUT")" = "false" ] || fail "B2: an unconfirmed batch must report spent:false: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B2: an unconfirmed batch invoked a candidate runner"
[ ! -e "$A_OUT/baseline.jsonl" ] || fail "B2: an unconfirmed batch wrote an arm file"
ok "B2 no --confirm: STOPPED, spent:false, no runner invoked, no arm file"

# B3 — the gate itself says stop (a ceiling this batch cannot fit under).
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" REPLAY_PREFLIGHT_CEILING_TOKENS=1
[ "$RC" -eq 3 ] || fail "B3: a ceiling-exceeded gate should STOP with exit 3, got $RC: $OUT"
[ "$(jq -r '.stop_reason' <<<"$OUT")" = "ceiling_exceeded" ] || fail "B3: expected stop_reason ceiling_exceeded, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "B3: a STOPPED batch invoked a candidate runner — it started spending on an un-gated batch"
[ "$(wt_count)" = "0" ] || fail "B3: a STOPPED batch prepared a worktree"
ok "B3 gate stop (ceiling exceeded): nothing prepared, nothing spent"

# B4 — MUTATION PROOF. The gate is what stopped B3, not luck: neuter the stop
#      check in a mirrored copy and the very same input DOES execute replays.
count
MUT_B="$WORK/mut-gate"; mk_mirror "$MUT_B"
MUT_B_SUT="$MUT_B/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_B_SUT"
mutate_file "$MUT_B_SUT" \
  '  if [ "$(jq -r '"'"'.stop'"'"' <<<"$pf_json")" = "true" ]; then' \
  '  if false; then'
MUT_B_OUT="$WORK/out-mut-b"; MUT_B_STATE="$WORK/state-mut-b"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_B_OUT" --state-dir "$MUT_B_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_B_SUT" REPLAY_PREFLIGHT_CEILING_TOKENS=1
mut_b_calls="$(wc -l <"$CAND_LOG" | tr -d ' ')"
[ "$mut_b_calls" -gt 0 ] || fail "B4: the mutation proof did not fire — with the stop check neutered the batch should have executed replays, so B3 proves nothing. stderr: $(head -c 400 "$WORK/last-stderr.txt")"
: >"$CAND_LOG"
ok "B4 MUTATION PROOF: neutering the gate's stop check DOES execute replays ($mut_b_calls candidate calls) — B3's refusal is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — THE TWO-ARM UNIT CONTRACT (temperloop#1379) + THE BATCH CAP.
# ═══════════════════════════════════════════════════════════════════════════

# C1 — the happy path over CORPUS_A: 2 eligible records, BOTH arms.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "C1: the happy-path batch should exit 0, got $RC: $OUT / $(head -c 600 "$WORK/last-stderr.txt")"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_COMPLETE" ] || fail "C1: expected BATCH_COMPLETE, got: $OUT"
[ "$(jq -r '.selection.selected_records_n' <<<"$OUT")" = "2" ] || fail "C1: expected 2 selected corpus records (the rejected one is never replayed), got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "4" ] || fail "C1: 2 records x 2 arms = 4 executed replays, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "C1: expected 4 completed legs, got: $OUT"
[ "$(wc -l <"$CORPUS_A" | tr -d ' ')" = "3" ] || fail "C1: corpus fixture changed shape"
ok "C1 happy path: 2 eligible corpus records -> 4 executed replays, BATCH_COMPLETE"

# C2 — every selected record appears in BOTH arm files, keyed by outcome ref.
count
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "C2: baseline.jsonl should carry 2 records: $(cat "$A_OUT/baseline.jsonl")"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "C2: candidate.jsonl should carry 2 records"
for ref in 101 103; do
  jq -e --argjson pr "$ref" 'select(.pr == $pr)' <"$A_OUT/baseline.jsonl" >/dev/null \
    || fail "C2: pr:$ref missing from the baseline arm"
  jq -e --argjson pr "$ref" 'select(.pr == $pr)' <"$A_OUT/candidate.jsonl" >/dev/null \
    || fail "C2: pr:$ref missing from the candidate arm"
done
A_PAIRED="$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT")"
[ "$A_PAIRED" = "2" ] || fail "C2: expected 2 paired outcomes, got: $OUT"
ok "C2 both arms carry every selected record — 2 paired outcomes, the unit the report's floor is applied to"

# C3 — the two arms really are two DIFFERENT arms (the models differ), and the
#      driver's authorized figures are the GATE's own, in the GATE's own unit.
count
base_models="$(jq -r '.candidate.model' <"$A_OUT/baseline.jsonl" | sort -u | tr '\n' ',')"
cand_models="$(jq -r '.candidate.model' <"$A_OUT/candidate.jsonl" | sort -u | tr '\n' ',')"
[ "$base_models" = "recorded-baseline-model," ] || fail "C3: baseline arm models: $base_models"
[ "$cand_models" = "recorded-candidate-model," ] || fail "C3: candidate arm models: $cand_models"
pf_cost="$(jq -r '.preflight.estimated_cost' <<<"$OUT")"
pf_basis="$(jq -r '.preflight.cost_basis' <<<"$OUT")"
[ "$(jq -r '.authorized.estimated_cost' <<<"$OUT")" = "$pf_cost" ] || fail "C3: authorized.estimated_cost is not the gate's own figure: $OUT"
[ "$(jq -r '.authorized.cost_basis' <<<"$OUT")" = "$pf_basis" ] || fail "C3: authorized.cost_basis is not the gate's own unit: $OUT"
[ "$pf_basis" = "cost-weighted-token-units" ] || fail "C3: the cost unit is not the shared cost-weighted unit (temperloop#1380): $pf_basis"
[ "$(jq -r '.authorized.replays_n' <<<"$OUT")" = "4" ] || fail "C3: authorized.replays_n should be the gate's two-arm figure: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "$(jq -r '.authorized.replays_n' <<<"$OUT")" ] \
  || fail "C3: the legs this driver PLANNED and the replays the gate AUTHORIZED must be the same number: $OUT"
ok "C3 the arms differ, and the authorized cost/records/replays are the gate's own figures in the gate's own unit"

# C4 — the BATCH CAP binds CORPUS RECORDS, and it comes from the gate.
count
CAP_OUT="$WORK/out-cap"; CAP_STATE="$WORK/state-cap"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$CAP_OUT" --state-dir "$CAP_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "" REPLAY_PREFLIGHT_BATCH_CAP=2
[ "$RC" -eq 0 ] || fail "C4: the capped batch should exit 0, got $RC: $OUT / $(head -c 600 "$WORK/last-stderr.txt")"
[ "$(jq -r '.selection.selected_records_n' <<<"$OUT")" = "2" ] || fail "C4: the cap binds CORPUS RECORDS (3 eligible, cap 2), got: $OUT"
[ "$(jq -r '.authorized.batch_cap' <<<"$OUT")" = "2" ] || fail "C4: expected the gate's own batch_cap of 2, got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "4" ] || fail "C4: 2 capped records x 2 arms = 4 replays, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "4" ] || fail "C4: expected exactly 4 candidate-runner calls, got $(wc -l <"$CAND_LOG")"
ok "C4 REPLAY_PREFLIGHT_BATCH_CAP honoured in CORPUS RECORDS, and read off the gate that authorized the spend"

# C5 — MUTATION PROOF (two-arm): a driver that replays only one arm produces
#      an empty candidate arm and ZERO paired outcomes.
count
MUT_C="$WORK/mut-onearm"; mk_mirror "$MUT_C"
MUT_C_SUT="$MUT_C/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_C_SUT"
mutate_file "$MUT_C_SUT" \
  '    for arm in "$BATCH_ARM_BASELINE" "$BATCH_ARM_CANDIDATE"; do
      local leg_key leg_rec leg_state' \
  '    for arm in "$BATCH_ARM_BASELINE"; do
      local leg_key leg_rec leg_state'
MUT_C_OUT="$WORK/out-mut-c"; MUT_C_STATE="$WORK/state-mut-c"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_C_OUT" --state-dir "$MUT_C_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_C_SUT"
mut_c_paired="$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT" 2>/dev/null)"
[ "$mut_c_paired" = "0" ] || fail "C5: the mutation proof did not fire — a one-arm driver should produce 0 paired outcomes, got '$mut_c_paired': $OUT"
[ "$(lines "$MUT_C_OUT/candidate.jsonl")" = "0" ] || fail "C5: a one-arm driver still wrote a candidate arm"
ok "C5 MUTATION PROOF: a one-arm driver yields an EMPTY candidate arm and 0 paired outcomes — C2's two-arm assertion is load-bearing"

# C6 — MUTATION PROOF (the cap's provenance): a cap taken from anywhere but
#      the gate makes the executed batch disagree with the authorized one, and
#      the driver REFUSES rather than spending on the difference.
count
MUT_D="$WORK/mut-cap"; mk_mirror "$MUT_D"
MUT_D_SUT="$MUT_D/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_D_SUT"
mutate_file "$MUT_D_SUT" \
  '    [ "$idx" -lt "$batch_cap" ] || break' \
  '    [ "$idx" -lt 9999 ] || break'
MUT_D_OUT="$WORK/out-mut-d"; MUT_D_STATE="$WORK/state-mut-d"
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$MUT_D_OUT" --state-dir "$MUT_D_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_D_SUT" REPLAY_PREFLIGHT_BATCH_CAP=2
[ "$RC" -ne 0 ] || fail "C6: the mutation proof did not fire — ignoring the gate's cap should be refused, got exit 0: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "CANNOT_EVALUATE" ] || fail "C6: expected CANNOT_EVALUATE, got: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "C6: a batch that disagreed with its authorization still spent"
ok "C6 MUTATION PROOF: a selection that ignores the gate's cap is REFUSED before any spend, never silently over-spent"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — one record's failure does not abort the batch, and the
# completion rate falls out of the driver's own output.
# ═══════════════════════════════════════════════════════════════════════════
FAIL_OUT="$WORK/out-fail"; FAIL_STATE="$WORK/state-fail"

# D1 — the middle record cannot be prepared; the batch carries on.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$FAIL_OUT" --state-dir "$FAIL_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 4 ] || fail "D1: a batch with a failed leg should exit 4 (BATCH_DEGRADED), got $RC: $OUT"
[ "$(jq -r '.outcome' <<<"$OUT")" = "BATCH_DEGRADED" ] || fail "D1: expected BATCH_DEGRADED, got: $OUT"
[ "$(jq -r '.legs.planned_n' <<<"$OUT")" = "6" ] || fail "D1: 3 records x 2 arms = 6 planned replays, got: $OUT"
[ "$(jq -r '.legs.failed_n' <<<"$OUT")" = "2" ] || fail "D1: the unpreparable record fails in BOTH arms, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "D1: the other two records must still have completed, got: $OUT"
[ "$(jq -r '[.failures[] | select(.outcome_ref == "pr:302")] | length' <<<"$OUT")" = "2" ] \
  || fail "D1: both failed legs must be NAMED in failures[] with their ref: $OUT"
jq -e '[.failures[] | select((.reason // "") | length > 0)] | length == 2' <<<"$OUT" >/dev/null \
  || fail "D1: every failure must carry a reason: $OUT"
[ "$(lines "$FAIL_OUT/baseline.jsonl")" = "2" ] || fail "D1: the surviving records must still reach the baseline arm"
[ "$(lines "$FAIL_OUT/candidate.jsonl")" = "2" ] || fail "D1: the surviving records must still reach the candidate arm"
jq -e 'select(.pr == 302)' <"$FAIL_OUT/baseline.jsonl" >/dev/null 2>&1 \
  && fail "D1: the failed record must not appear in an arm file"
ok "D1 a record that cannot be replayed is recorded as failed WITH its reason, and the batch continues"

# D2 — the completion rate is the driver's own output, not a hand count.
count
[ "$(jq -r '.completion.replay_completion_rate' <<<"$OUT")" = "0.6667" ] \
  || fail "D2: 4 of 6 executed replays completed -> 0.6667, got: $(jq -r '.completion.replay_completion_rate' <<<"$OUT")"
jq -e '.completion.basis | type == "string" and (length > 0)' <<<"$OUT" >/dev/null \
  || fail "D2: the completion rate must state its own basis: $OUT"
[ "$(jq -r '.units.replay_completion_rate' <<<"$OUT")" = "executed_replays completed / executed_replays planned" ] \
  || fail "D2: the completion rate must NAME its unit: $OUT"
ok "D2 replay completion rate (0.6667 = 4/6 executed replays) falls out of the driver's own output, unit named"

# D3 — MUTATION PROOF. A driver that counts a failed leg as completed reports
#      a perfect 1.0 — "could not evaluate" rendered as "evaluated, and fine".
count
MUT_E="$WORK/mut-rate"; mk_mirror "$MUT_E"
MUT_E_SUT="$MUT_E/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_E_SUT"
mutate_file "$MUT_E_SUT" \
  '        legs_failed=$((legs_failed + 1))
        jq -cn --arg a "$arm" --arg r "$sel_ref" \
          --arg reason "worktree-prepare failed: $(printf '"'"'%s'"'"' "$prep_out" | head -c 200)" \' \
  '        legs_done=$((legs_done + 1))
        jq -cn --arg a "$arm" --arg r "$sel_ref" \
          --arg reason "worktree-prepare failed: $(printf '"'"'%s'"'"' "$prep_out" | head -c 200)" \'
MUT_E_OUT="$WORK/out-mut-e"; MUT_E_STATE="$WORK/state-mut-e"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$MUT_E_OUT" --state-dir "$MUT_E_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_E_SUT"
mut_e_rate="$(jq -r '.completion.replay_completion_rate' <<<"$OUT" 2>/dev/null)"
[ "$mut_e_rate" = "1" ] || fail "D3: the mutation proof did not fire — counting a failed leg as completed should report a perfect rate, got '$mut_e_rate': $OUT"
ok "D3 MUTATION PROOF: counting an unreplayable leg as completed reports 1.0 — D2's rate is a measurement, not a formality"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — RESUMABILITY. A re-invocation re-spends nothing.
# ═══════════════════════════════════════════════════════════════════════════

# E1 — re-run the SAME batch against the SAME state dir.
count
: >"$CAND_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "E1: the resumed batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "0" ] || fail "E1: a resumed batch RE-SPENT $(wc -l <"$CAND_LOG") replays"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "4" ] || fail "E1: expected all 4 legs resumed, got: $OUT"
[ "$(jq -r '.legs.completed_n' <<<"$OUT")" = "4" ] || fail "E1: a resumed batch must still report its completed legs, got: $OUT"
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "E1: a resumed run must re-emit COMPLETE arm files, not just its own share"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "E1: a resumed run must re-emit COMPLETE arm files"
ok "E1 re-invocation: 0 replays re-spent, 4 legs resumed, arm files still complete"

# E2 — an interrupted batch: delete ONE leg's state and its record, then
#      resume. Exactly that one leg is re-executed — no more, no less.
count
: >"$CAND_LOG"
rm -f "$A_STATE/legs/candidate/002-pr-103.state.json" "$A_STATE/legs/candidate/002-pr-103.json"
drive ""
[ "$RC" -eq 0 ] || fail "E2: the partially-resumed batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$CAND_LOG" | tr -d ' ')" = "1" ] || fail "E2: exactly ONE leg should have been re-executed, got $(wc -l <"$CAND_LOG"): $(cat "$CAND_LOG")"
[ "$(jq -r '.legs.resumed_n' <<<"$OUT")" = "3" ] || fail "E2: expected 3 resumed legs, got: $OUT"
[ "$(lines "$A_OUT/candidate.jsonl")" = "2" ] || fail "E2: the re-executed leg must rejoin a COMPLETE candidate arm"
ok "E2 an interrupted leg is re-executed and ONLY that leg — the other three are not re-spent"

# E3 — MUTATION PROOF. Neuter the resume check and the same re-invocation
#      re-spends every leg.
count
MUT_F="$WORK/mut-resume"; mk_mirror "$MUT_F"
MUT_F_SUT="$MUT_F/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_F_SUT"
mutate_file "$MUT_F_SUT" '      if [ -f "$leg_state" ]; then' '      if false; then'
: >"$CAND_LOG"
drive "$MUT_F_SUT"
mut_f_calls="$(wc -l <"$CAND_LOG" | tr -d ' ')"
[ "$mut_f_calls" = "4" ] || fail "E3: the mutation proof did not fire — with the resume check neutered all 4 legs should re-spend, got $mut_f_calls"
: >"$CAND_LOG"
ok "E3 MUTATION PROOF: neutering the resume check re-spends all 4 legs — E1's 'nothing re-spent' is a measurement"

# E4 — a state dir is bound to ONE batch: a different corpus is refused, never
#      silently mixed into the same arm files.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_CAP" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 1 ] || fail "E4: resuming a state dir against a DIFFERENT corpus should be CANNOT_EVALUATE, got $RC: $OUT"
grep -q 'DIFFERENT batch' <<<"$OUT" || fail "E4: the refusal must name the mismatch: $OUT"
[ "$(lines "$A_OUT/baseline.jsonl")" = "2" ] || fail "E4: the refused run corrupted the existing arm file"
ok "E4 a state dir bound to another batch is REFUSED — two batches never merge into one arm file"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — ISOLATION: teardown on both paths, and a clean parent.
# ═══════════════════════════════════════════════════════════════════════════

# F1 — after the DEGRADED batch of section D (a run with both a success and a
#      failure path), no replay worktree survives and the parent is clean.
count
[ "$(wt_count)" = "0" ] || fail "F1: $(wt_count) replay worktree(s) survived the batch: $(ls -d "${REPO}.wt"/mc-replay-* 2>/dev/null)"
[ "$(git -C "$REPO" worktree list | grep -c 'mc-replay')" = "0" ] || fail "F1: a replay worktree is still registered with git"
[ "$(git -C "$REPO" branch --list 'build/mc-replay-*' | wc -l | tr -d ' ')" = "0" ] || fail "F1: a replay branch survived teardown"
DRIVE_ARGS=(--corpus-file "$CORPUS_FAIL" --repo-root "$REPO" --out-dir "$FAIL_OUT" --state-dir "$FAIL_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$(jq -r '.isolation.verify_clean_parent' <<<"$OUT")" = "CLEAN" ] \
  || fail "F1: replay.sh verify-clean-parent should pass after the batch, got: $(jq -c '.isolation' <<<"$OUT")"
ok "F1 every prepared worktree torn down on BOTH the success and the failure path; verify-clean-parent CLEAN"

# F2 — MUTATION PROOF. With teardown (and the end-of-batch sweep) neutered,
#      the worktrees survive — so F1 is measuring something real.
count
MUT_G="$WORK/mut-teardown"; mk_mirror "$MUT_G"
MUT_G_SUT="$MUT_G/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_G_SUT"
mutate_file "$MUT_G_SUT" \
  '      bash "$REPLAY_SH" worktree-teardown "$repo_root" "$slug" >/dev/null 2>&1 || true' \
  '      : "$slug"'
mutate_file "$MUT_G_SUT" \
  '        bash "$REPLAY_SH" worktree-teardown "$repo_root" "$sweep_slug" >/dev/null 2>&1 || true' \
  '        : "$sweep_slug"'
MUT_G_OUT="$WORK/out-mut-g"; MUT_G_STATE="$WORK/state-mut-g"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_G_OUT" --state-dir "$MUT_G_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_G_SUT"
mut_g_wt="$(wt_count)"
[ "$mut_g_wt" -gt 0 ] || fail "F2: the mutation proof did not fire — with teardown removed a replay worktree should survive, got $mut_g_wt"
# ...and clean the mutation's residue up so it cannot leak into later sections.
for d in "${REPO}.wt"/mc-replay-*; do
  [ -e "$d" ] || continue
  bash "$MC_DIR/replay.sh" worktree-teardown "$REPO" "$(basename "$d")" >/dev/null 2>&1 || true
done
[ "$(wt_count)" = "0" ] || fail "F2: could not clean up the mutation proof's leaked worktrees"
ok "F2 MUTATION PROOF: removing teardown leaks $mut_g_wt worktree(s) — F1's clean sweep is load-bearing"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — THE REPORT PRODUCER CONSUMES THE DRIVER'S OUTPUT UNCHANGED.
# ═══════════════════════════════════════════════════════════════════════════

# G1 — the real producer, on the driver's real fixture output, with no edits.
count
prod_out="$(cd "$WORK" && env MODEL_COMPARISON_REPORT_RECORDS_DIR="$A_OUT" bash "$PRODUCER" 2>/dev/null)"
prod_rc=$?
[ "$prod_rc" -eq 0 ] || fail "G1: the report producer must exit 0 (it is a report drop-in), got $prod_rc"
case "$prod_out" in
  "skipped -- "*) fail "G1: the producer SKIPPED the driver's own output — the driver is not producing that producer's input: $prod_out" ;;
esac
jq -e 'type == "object"' <<<"$prod_out" >/dev/null 2>&1 || fail "G1: the producer did not print one JSON object: $(head -c 400 <<<"$prod_out")"
[ "$(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out")" = "2" ] \
  || fail "G1: the producer paired $(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out") outcomes, the driver claimed 2"
[ "$(jq -r '.comparison.paired_outcomes_n' <<<"$prod_out")" = "$(jq -r '.pairing.paired_outcomes_n' <<<"$OUT")" ] \
  || fail "G1: the driver'"'"'s paired-outcome count and the producer'"'"'s disagree"
[ "$(jq -r '.arms.baseline.records_n' <<<"$prod_out")" = "2" ] || fail "G1: the producer read the wrong baseline arm size"
[ "$(jq -r '.arms.candidate.records_n' <<<"$prod_out")" = "2" ] || fail "G1: the producer read the wrong candidate arm size"
ok "G1 workflows/scripts/report-producers/model-comparison consumes the driver's arm files UNCHANGED (2 paired outcomes, both arms read)"

# G2 — the cost unit the driver authorized and the unit the report publishes
#      are the same string (temperloop#1380's identity, end to end).
count
case "$(jq -r '.arms.baseline.cost.unit' <<<"$prod_out")" in
  "cost-weighted token units"*) ;;
  *) fail "G2: unexpected report cost unit: $(jq -r '.arms.baseline.cost.unit' <<<"$prod_out")" ;;
esac
[ "$(jq -r '.cost_basis.unit' <<<"$prod_out")" = "$pf_basis" ] \
  || fail "G2: the report's cost_basis.unit ($(jq -r '.cost_basis.unit' <<<"$prod_out")) and the batch the driver authorized ($pf_basis) are different units"
ok "G2 the unit the driver authorized the batch in is byte-identically the unit the report publishes"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — JUDGING: wired, resumable, and a skip is NAMED.
# ═══════════════════════════════════════════════════════════════════════════

# H1 — the judge pass annotated every record in both arms.
count
[ "$(jq -s '[.[] | select(.judge.outcome == "JUDGED")] | length' <"$A_OUT/baseline.jsonl")" = "2" ] \
  || fail "H1: the baseline arm is not fully judged: $(jq -c '[.judge.outcome]' <"$A_OUT/baseline.jsonl")"
[ "$(jq -s '[.[] | select(.judge.outcome == "JUDGED")] | length' <"$A_OUT/candidate.jsonl")" = "2" ] \
  || fail "H1: the candidate arm is not fully judged"
[ "$(jq -r '.arms.baseline.judge_quality.judged_n' <<<"$prod_out")" = "2" ] \
  || fail "H1: the report did not see the driver's judge annotations: $(jq -c '.arms.baseline.judge_quality' <<<"$prod_out")"
ok "H1 the judge pass annotated both arms, and the report reads those annotations"

# H2 — a judge seam is REQUIRED to judge: with none, the arm files are written
#      UNJUDGED and the skip is NAMED, never silent.
count
NOJ_OUT="$WORK/out-nojudge"; NOJ_STATE="$WORK/state-nojudge"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$NOJ_OUT" --state-dir "$NOJ_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "H2: an unjudged batch is still a complete batch, got $RC: $OUT"
[ "$(jq -r '.judge.ran' <<<"$OUT")" = "false" ] || fail "H2: expected judge.ran false, got: $(jq -c .judge <<<"$OUT")"
jq -e '.judge.reason | type == "string" and (length > 20)' <<<"$OUT" >/dev/null \
  || fail "H2: a skipped judge pass must carry a NAMED reason: $(jq -c .judge <<<"$OUT")"
[ "$(jq -s '[.[] | select(has("judge"))] | length' <"$NOJ_OUT/baseline.jsonl")" = "0" ] \
  || fail "H2: an unjudged arm must carry no judge sub-object at all"
ok "H2 no judge seam: the arms are written UNJUDGED and the skip is NAMED, never presented as judged"

# H3 — the judge pass is resumable too: a re-invocation makes no judge call.
count
: >"$JUDGE_LOG"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$A_OUT" --state-dir "$A_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB"
            --judge-runner "bash $JUDGE_STUB" --confirm)
drive ""
[ "$RC" -eq 0 ] || fail "H3: the resumed judged batch should exit 0, got $RC: $OUT"
[ "$(wc -l <"$JUDGE_LOG" | tr -d ' ')" = "0" ] || fail "H3: a resumed batch RE-SPENT $(wc -l <"$JUDGE_LOG") judge calls"
[ "$(jq -r '[.judge.per_arm[] | select(.outcome == "RESUMED")] | length' <<<"$OUT")" = "2" ] \
  || fail "H3: both arms should report a RESUMED judge pass: $(jq -c .judge <<<"$OUT")"
ok "H3 the judge pass is resumable: 0 judge calls re-spent on re-invocation"

# H4 — MUTATION PROOF, and the live-arm canary. Force the candidate arm to
#      `--live` in a mirrored copy and the canary `claude` DOES fire.
count
[ ! -e "$CANARY" ] || fail "H4: the canary fired before its own mutation proof: $(cat "$CANARY")"
MUT_H="$WORK/mut-live"; mk_mirror "$MUT_H"
MUT_H_SUT="$MUT_H/workflows/scripts/model-comparison/batch.sh"
unlink_and_copy "$MUT_H_SUT"
mutate_file "$MUT_H_SUT" \
  '          *) xa+=(--candidate-runner "$candidate_runner") ;;' \
  '          *) xa+=(--live) ;;'
MUT_H_OUT="$WORK/out-mut-h"; MUT_H_STATE="$WORK/state-mut-h"
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_H_OUT" --state-dir "$MUT_H_STATE"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive "$MUT_H_SUT"
[ -e "$CANARY" ] || fail "H4: the mutation proof did not fire — forcing the candidate arm live should have reached the canary 'claude', so the canary cannot detect a real live leak either"
rm -f "$CANARY"
ok "H4 MUTATION PROOF: forcing the candidate arm to --live DOES reach a bare 'claude' — the recorded seam is what keeps this suite hermetic"

# ...and the restored driver does not.
count
DRIVE_ARGS=(--corpus-file "$CORPUS_A" --repo-root "$REPO" --out-dir "$MUT_H_OUT" --state-dir "$WORK/state-mut-h2"
            --baseline-runner "bash $BASE_STUB" --candidate-runner "bash $CAND_STUB" --confirm)
drive ""
[ ! -e "$CANARY" ] || fail "H5: the unmutated driver reached a 'claude' binary: $(cat "$CANARY")"
ok "H5 the unmutated driver, on the same input, reaches no 'claude' at all"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — the suite-wide no-live-call verdict.
# ═══════════════════════════════════════════════════════════════════════════
count
if [ -e "$CANARY" ]; then
  fail "I1: A LIVE MODEL CALL WAS ATTEMPTED during this suite: $(cat "$CANARY")"
fi
ok "I1 no test in this suite ever invoked a 'claude' binary"

count
"$WORK/bin/claude" --self-test >/dev/null 2>&1
[ -e "$CANARY" ] || fail "I2: the canary itself does not work, so I1 proves nothing"
rm -f "$CANARY"
ok "I2 the canary is genuinely capable of firing (so I1 is a measurement, not a tautology)"

echo
echo "test_replay_batch.sh: $pass/$total checks passed"
[ "$pass" -eq "$total" ] || exit 1
