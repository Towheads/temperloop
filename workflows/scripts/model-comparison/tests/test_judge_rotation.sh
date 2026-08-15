#!/usr/bin/env bash
#
# test_judge_rotation.sh — fixture suite for optional cross-family judge
# rotation (temperloop#1260, epic #1225 "model comparison harness"):
# `judge.sh judge-rotate`.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE (same shape as test_judge.sh) ──
#   1. THE SEAM. Every `judge-rotate` invocation below drives a RECORDED
#      judge runner (`--judge-runner "... bash $JSTUB"`) whose stdout is a
#      canned `claude -p --output-format json`-shaped envelope on disk.
#      `--live` is never passed by any test in this file.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to `$WORK/CANARY`.
#      Section H asserts that file never came into existence.
#
# No network, no `gh`, no git worktree at all (judge-rotate, like judge.sh's
# single-judge path, operates purely on an already-executed JSON record — no
# repo, no candidate worktree needed), no writes outside $TMPDIR.
#
# Sections:
#   A  rotation is OFF by default — judge-rotate CANNOT_EVALUATEs before
#      touching the record or spawning anything, with the setting explicitly
#      unset AND explicitly "0"
#   B  BYTE-IDENTICAL default behaviour — `judge`/`judge-batch` are
#      untouched by this file's rotation additions (a full-record diff
#      against output captured from the pre-rotation judge.sh, modulo the
#      two inherently-volatile timestamp/duration fields)
#   C  the happy path — >=2 judges from >=2 provider families, a
#      known-answer variance figure computed via stats.sh, never a second
#      implementation
#   D  the allowlist + disclosure requirement for a non-default-provider
#      rotated judge, functional in both directions, + two INDEPENDENT
#      mutation proofs (the allowlist gate; the disclosure append)
#   E  the cross-family requirement, at BOTH the configured level (fail
#      fast, no spend) and the JUDGED level (post-hoc, after some members
#      degrade)
#   F  MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES is genuinely wired (a
#      non-default value changes the outcome)
#   G  partial degradation: some rotation members REFUSED/CANNOT_EVALUATE,
#      variance still computed over the rest — exit 4, never silently 0
#   H  fail-closed: unset runner seam, malformed --judges, a genuine
#      stats.sh failure -> CANNOT_EVALUATE + non-zero, never a fabricated
#      variance; the suite-wide no-live-call canary verdict
#   I  the overclaim discipline: the emitted record never claims rotation
#      PROVES neutrality
#
# Usage: bash workflows/scripts/model-comparison/tests/test_judge_rotation.sh
#
# shellcheck disable=SC2016

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
JUDGE="$MC_DIR/judge.sh"

# shellcheck source=../../lib/portable-timeout.sh
. "$SCRIPTS_DIR/lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-judge-rotation-XXXXXX")"
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
# it. Section H fails the whole suite if this file exists at the end.
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

# mutate_file <file> <old-literal> <new-literal> — exact, literal,
# single-occurrence replacement (same helper, same rationale, as
# test_judge.sh / test_replay_score.sh). Dies loudly if the old text is
# missing or not unique, so a mutation proof can never silently become a
# no-op that "passes".
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

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts
# under <dest>, so a mutation proof can edit ONE real copy of a file (judge.sh
# OR allowlist.sh) without ever writing into the checkout. Absolute symlink
# targets throughout (never relative) so the mirror works regardless of cwd.
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
  local p="$1" target
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  local real; real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# ═══════════════════════════════════════════════════════════════════════════
# FIXTURES
# ═══════════════════════════════════════════════════════════════════════════

RECORD="$WORK/record.json"
jq -cn '{schema_version:"replay-record-v1", pr:999, issue:"#4242",
  title:"Fix the thing", scope:"the scope",
  acceptance:["A named path is fixed."],
  candidate:{provider:"anthropic", model:"claude-sonnet-5", diff_ref:"deadbeef"},
  score:{verdict:"pass", diff:{n:{total:1,changed:1}}, gate_result:{passed:true}}}' >"$RECORD"

# ── the RECORDED judge runner. Invoked as `<cmd> <prompt-file>`. Each call's
#    SCORE is picked by call ORDER (via a counter file, $JSTUB_COUNT_FILE) so
#    a rotation panel's members deterministically disagree — needed to prove
#    a real, known-answer variance rather than a degenerate zero.
#    JSTUB_SCORES is an explicit COMMA-separated per-call score list (the
#    N-th call gets the N-th score; a call past the list's end gets 85).
#    Comma-, not space-, separated: the runner is a command STRING split on
#    IFS whitespace by judge.sh's own `$runner "$prompt_file"` (unquoted,
#    exactly like replay.sh execute's --candidate-runner) — a quoted
#    space-bearing value in that string is NOT re-parsed by a shell, so its
#    quotes would survive as literal characters and break word-splitting.
#    JSTUB_FAIL_AT forces one specific call to fail (a runner-spawn error).
JSTUB="$WORK/judge-stub.sh"
cat >"$JSTUB" <<'STUBEOF'
#!/usr/bin/env bash
set -u
prompt="$1"
COUNT_FILE="${JSTUB_COUNT_FILE:-/tmp/jstub-rot-count}"
n=0
[ -f "$COUNT_FILE" ] && n="$(cat "$COUNT_FILE")"
n=$((n + 1))
echo "$n" >"$COUNT_FILE"

if [ -n "${JSTUB_FAIL_AT:-}" ] && [ "$n" -eq "${JSTUB_FAIL_AT}" ]; then
  echo "jstub: forced failure at call $n" >&2
  exit 5
fi

score=85
if [ -n "${JSTUB_SCORES:-}" ]; then
  i=1
  scores_spaced="$(printf '%s' "$JSTUB_SCORES" | tr ',' ' ')"
  for s in $scores_spaced; do
    if [ "$i" -eq "$n" ]; then score="$s"; fi
    i=$((i + 1))
  done
fi

body="$(jq -cn --argjson qs "$score" \
  '{quality_score:$qs,
    dimensions:{correctness:$qs, acceptance_coverage:$qs, test_quality:$qs,
                portability_robustness:$qs, simplicity_reuse:$qs},
    rationale:"stub rationale", concerns:[]}')"
jq -cn --arg body "$body" \
  '{result:$body, modelUsage:{"stub-model":{inputTokens:5,outputTokens:5,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:5, is_error:false}'
STUBEOF
chmod +x "$JSTUB"

# ── env every judge-rotate run gets: the disclosure log, allowlist, and
#    attribution lake all point INTO $WORK, never at the checkout. ─────────
LAKE="$WORK/lake"
ALLOW_BOTH="$WORK/allow-both.txt"       # anthropic + openai
ALLOW_ANTHROPIC="$WORK/allow-anthropic.txt"  # anthropic only
NOLOCAL="$WORK/no-such-local-override.txt"
printf 'anthropic\nopenai\n' >"$ALLOW_BOTH"
printf 'anthropic\n' >"$ALLOW_ANTHROPIC"
mkdir -p "$LAKE"

# run_rotate <allow-file> <disclosure-log> <count-file> <rotation-enabled 0|1> <min-judges-or-empty> <cmd...>
# A thin wrapper so every call points the disclosure log / allowlist /
# count-file / lake at fresh, per-test files (never shared across
# assertions), and turns rotation on/off + the min-judges override into ONE
# `env` invocation — never a broken `$(helper ...)` splice (a real bug this
# suite had in an earlier draft: command-substituting a helper that itself
# ran a bare `env` printed the WHOLE inherited environment as literal
# argv words). A leading shell-variable assignment (e.g. `PATH=... \
# run_rotate ...`) still reaches everything this function execs, per bash's
# ordinary simple-command assignment semantics — verified on both bash 5.3
# and /bin/bash 3.2.
run_rotate() {
  local allow="$1" dlog="$2" countfile="$3" enabled="$4" minj="$5"; shift 5
  rm -f "$countfile"
  local -a extra=()
  [ -n "$minj" ] && extra=(MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES="$minj")
  env MODEL_COMPARISON_JUDGE_ROTATION_ENABLED="$enabled" \
      "${extra[@]+"${extra[@]}"}" \
      JSTUB_COUNT_FILE="$countfile" \
      MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$allow" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$dlog" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      "$@"
}

DEFAULT_JUDGES="anthropic:claude-opus-4-8,openai:gpt-5"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — rotation is OFF by default
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_A1="$WORK/dlog-a1.jsonl"; COUNT_A1="$WORK/count-a1"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_A1" "$COUNT_A1" 0 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "A1: with MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=0 (its documented default), judge-rotate must CANNOT_EVALUATE (rc 1), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "A1: expected outcome CANNOT_EVALUATE, got: $out"
case "$(jq -r .error <<<"$out")" in
  *"rotation mode is disabled"*) ;;
  *) fail "A1: expected the refusal to name rotation as disabled, got: $out" ;;
esac
ok "A1 with the setting at its documented default (0), judge-rotate refuses before doing anything"

count
[ "$(cat "$COUNT_A1" 2>/dev/null || echo 0)" = "0" ] || fail "A2: the OFF-by-default refusal reached the judge-runner stub — no spend should have happened"
[ ! -e "$CANARY" ] || fail "A2: the OFF-by-default refusal reached a 'claude' binary: $(cat "$CANARY")"
[ ! -s "$DLOG_A1" ] || fail "A2: the OFF-by-default refusal wrote a disclosure-log entry"
ok "A2 OFF by default means no call was ever made and no disclosure was ever written"

count
DLOG_A3="$WORK/dlog-a3.jsonl"; COUNT_A3="$WORK/count-a3"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_A3" "$COUNT_A3" 0 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "A3: MODEL_COMPARISON_JUDGE_ROTATION_ENABLED explicitly '0' must also refuse, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "A3: expected CANNOT_EVALUATE, got: $out"
ok "A3 an EXPLICIT MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=0 refuses identically to A1"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — BYTE-IDENTICAL default behaviour: judge/judge-batch untouched
# ═══════════════════════════════════════════════════════════════════════════
#
# This is a COMPARISON, not a mutation: GOLDEN was captured from the
# committed pre-rotation judge.sh (temperloop#1259, PR #1373 — before this
# file's rotation edits landed), on this exact fixture record + stub, with
# the two inherently-volatile fields (duration_ms, evaluated_at) normalized
# to fixed placeholders. If judge.sh's single-judge path changed ANY other
# byte, this diff catches it.

count
DLOG_B="$WORK/dlog-b.jsonl"; COUNT_B="$WORK/count-b"
GOLDEN='{"acceptance":["A named path is fixed."],"candidate":{"diff_ref":"deadbeef","model":"claude-sonnet-5","provider":"anthropic"},"issue":"#4242","judge":{"concerns":[],"dimensions":{"acceptance_coverage":85,"correctness":85,"portability_robustness":85,"simplicity_reuse":85,"test_quality":85},"disclosed":false,"duration_ms":0,"evaluated_at":"X","guard":{"candidate_model":"claude-sonnet-5","candidate_provider":"anthropic","enforced":true,"scope":"prevents self-grading only; does NOT neutralize model-family style bias"},"judge_model":"stub-model","judge_provider":"anthropic","outcome":"JUDGED","prompt_sha256":"c08bef7b67cac9e2a34344700492f10d4dae74e904a0bdb9cd076eb88686c787","quality_score":85,"rationale":"stub rationale","scored":true,"tokens":{"cache_creation":0,"cache_read":0,"input":5,"output":5}},"pr":999,"schema_version":"replay-record-v1","scope":"the scope","score":{"diff":{"n":{"changed":1,"total":1}},"gate_result":{"passed":true},"verdict":"pass"},"title":"Fix the thing"}'
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_B" "$COUNT_B" 0 "" \
      bash "$JUDGE" judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B1: single-judge 'judge' with rotation off must still exit 0, got $rc: $out"
norm="$(jq -Sc '.judge.duration_ms = 0 | .judge.evaluated_at = "X"' <<<"$out")"
golden_norm="$(jq -Sc . <<<"$GOLDEN")"
[ "$norm" = "$golden_norm" ] || fail "B1: BYTE-IDENTICAL PROOF FAILED — single-judge output differs from the pre-rotation golden (modulo duration_ms/evaluated_at). Golden: $golden_norm  Got: $norm"
ok "B1 BYTE-IDENTICAL PROOF: judge.sh 'judge' output is byte-for-byte identical to the pre-rotation golden capture (modulo the two inherently-volatile timestamp/duration fields)"

count
[ "$(jq -r '.judge_rotation // "absent"' <<<"$out")" = "absent" ] || fail "B2: a plain 'judge' call must never carry a judge_rotation key, got: $out"
ok "B2 a plain 'judge' call carries no judge_rotation key at all"

count
REC_B3="$WORK/rec-b3.json"; jq -c '.issue = "#7001"' "$RECORD" >"$REC_B3"
BATCH_B3="$WORK/batch-b3.jsonl"; jq -c . "$REC_B3" >"$BATCH_B3"
DLOG_B3="$WORK/dlog-b3.jsonl"; COUNT_B3="$WORK/count-b3"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_B3" "$COUNT_B3" 0 "" \
      bash "$JUDGE" judge-batch --records-file "$BATCH_B3" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B3: judge-batch with rotation off must exit 0, got $rc: $out"
[ "$(jq -r '.judge.outcome' <<<"$out")" = "JUDGED" ] || fail "B3: expected JUDGED, got: $out"
[ "$(jq -r '.judge_rotation // "absent"' <<<"$out")" = "absent" ] || fail "B3: judge-batch output must never carry a judge_rotation key"
ok "B3 judge-batch also remains untouched by the rotation additions"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — the happy path: known-answer variance via stats.sh, never a
# second implementation
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_C="$WORK/dlog-c.jsonl"; COUNT_C="$WORK/count-c"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_C" "$COUNT_C" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "C1: a clean 2-family rotation must exit 0, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "ROTATED" ] || fail "C1: expected judge_rotation.outcome ROTATED, got: $out"
[ "$(jq -r .judge_rotation.n_configured <<<"$out")" = "2" ] || fail "C1: expected n_configured 2, got: $out"
[ "$(jq -r .judge_rotation.n_judged <<<"$out")" = "2" ] || fail "C1: expected n_judged 2, got: $out"
[ "$(jq -r .judge_rotation.n_families_judged <<<"$out")" = "2" ] || fail "C1: expected n_families_judged 2, got: $out"
# Known answer: sample stdev of [70,90] = sqrt(((70-80)^2+(90-80)^2)/(2-1)) = sqrt(200) ≈ 14.142135623730951; variance = 200.
variance_val="$(jq -r .judge_rotation.variance.value <<<"$out")"
awk -v v="$variance_val" 'BEGIN { d = v - 200.0; if (d < 0) d = -d; exit !(d < 0.001) }' \
  || fail "C1: expected variance.value ≈ 200 (sample stdev of [70,90] squared), got $variance_val: $out"
[ "$(jq -r .judge_rotation.variance.n_judged <<<"$out")" = "2" ] || fail "C1: expected variance.n_judged 2, got: $out"
case "$(jq -r .judge_rotation.variance.computed_by <<<"$out")" in
  *"stats.sh"*) ;;
  *) fail "C1: expected variance.computed_by to name stats.sh, got: $out" ;;
esac
ok "C1 a 2-family rotation panel with scores [70,90] reports variance ≈ 200 — stats.sh's own stddev, squared"

count
[ "$(jq -r '.judge_rotation.judges | length' <<<"$out")" = "2" ] || fail "C2: expected 2 per-judge entries, got: $out"
[ "$(jq -r '.judge_rotation.judges[0].rotation_provider' <<<"$out")" = "anthropic" ] || fail "C2: expected first judges[] entry to be the anthropic member, got: $out"
[ "$(jq -r '.judge_rotation.judges[0].quality_score' <<<"$out")" = "70" ] || fail "C2: expected the anthropic member's quality_score 70, got: $out"
[ "$(jq -r '.judge_rotation.judges[1].rotation_provider' <<<"$out")" = "openai" ] || fail "C2: expected second judges[] entry to be the openai member, got: $out"
[ "$(jq -r '.judge_rotation.judges[1].quality_score' <<<"$out")" = "90" ] || fail "C2: expected the openai member's quality_score 90, got: $out"
ok "C2 each rotation member's own quality_score is reported per-judge, tagged with its provider/model"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — allowlist + disclosure requirement, functional + mutation-proven
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_D1="$WORK/dlog-d1.jsonl"; COUNT_D1="$WORK/count-d1"
out="$(run_rotate "$ALLOW_ANTHROPIC" "$DLOG_D1" "$COUNT_D1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
openai_entry="$(jq -c '.judge_rotation.judges[] | select(.rotation_provider=="openai")' <<<"$out")"
[ "$(jq -r '.outcome' <<<"$openai_entry")" = "CANNOT_EVALUATE" ] || fail "D1: a rotated non-default judge with NO allowlist entry must be refused (CANNOT_EVALUATE), got: $openai_entry"
case "$(jq -r '.error' <<<"$openai_entry")" in
  *"pa_disclose"*) ;;
  *) fail "D1: expected the openai member's refusal to name pa_disclose (the allowlist+disclosure gate), got: $openai_entry" ;;
esac
[ ! -s "$DLOG_D1" ] || fail "D1: an allowlist-refused non-default judge must never leave a disclosure-log entry, got: $(cat "$DLOG_D1")"
ok "D1 a rotated non-default judge (openai) with NO committed allowlist entry is REFUSED — no call, no disclosure entry"

count
DLOG_D2="$WORK/dlog-d2.jsonl"; COUNT_D2="$WORK/count-d2"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_D2" "$COUNT_D2" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "D2: with BOTH providers allowlisted, rotation must succeed, got $rc: $out"
[ -s "$DLOG_D2" ] || fail "D2: an allowlisted non-default judge (openai) must append to the SAME disclosure log a candidate replay uses"
[ "$(grep -c . "$DLOG_D2")" = "1" ] || fail "D2: expected exactly ONE disclosure entry (only the non-default provider discloses), got: $(cat "$DLOG_D2")"
[ "$(jq -r '.provider' "$DLOG_D2")" = "openai" ] || fail "D2: expected the disclosure entry's provider to be openai, got: $(cat "$DLOG_D2")"
[ "$(jq -r '.item_ref' "$DLOG_D2")" = "issue:4242" ] || fail "D2: expected the disclosure entry's item_ref to name the record's issue, got: $(cat "$DLOG_D2")"
openai_entry2="$(jq -c '.judge_rotation.judges[] | select(.rotation_provider=="openai")' <<<"$out")"
[ "$(jq -r '.outcome' <<<"$openai_entry2")" = "JUDGED" ] || fail "D2: expected the allowlisted openai member to reach JUDGED, got: $openai_entry2"
[ "$(jq -r '.disclosed' <<<"$openai_entry2")" = "true" ] || fail "D2: expected the openai member's own record to report disclosed:true, got: $openai_entry2"
ok "D2 an allowlisted non-default judge (openai) is JUDGED and appends exactly ONE entry to the disclosure log — the SAME log a candidate replay uses"

# --- MUTATION PROOF D3: the allowlist requirement is load-bearing -----------
count
MIRROR_D3="$WORK/mirror-d3"
mk_mirror "$MIRROR_D3"
unlink_and_copy "$MIRROR_D3/workflows/scripts/model-comparison/allowlist.sh"
mutate_file "$MIRROR_D3/workflows/scripts/model-comparison/allowlist.sh" \
  'if ! pa_is_allowed "$provider"; then
    echo "allowlist.sh: pa_disclose REFUSED — '"'"'$provider'"'"' is not in the current effective allowlist; a disclosure entry is only ever written for an allowed provider (ADR 0028 decision 2 pairing) — no entry written" >&2
    return 1
  fi' \
  'if false; then
    echo "MUTATED: allowlist gate disabled" >&2
    return 1
  fi'
DLOG_D3="$WORK/dlog-d3.jsonl"; COUNT_D3="$WORK/count-d3"
MUT_JUDGE_D3="$MIRROR_D3/workflows/scripts/model-comparison/judge.sh"
out="$(env MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 \
      JSTUB_COUNT_FILE="$COUNT_D3" MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW_ANTHROPIC" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG_D3" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$MUT_JUDGE_D3" judge-rotate \
        --record "$RECORD" --judges "$DEFAULT_JUDGES" --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
openai_entry3="$(jq -c '.judge_rotation.judges[] | select(.rotation_provider=="openai")' <<<"$out")"
[ "$(jq -r '.outcome' <<<"$openai_entry3")" = "JUDGED" ] || fail "D3: MUTATION PROOF did not fire — with the allowlist gate disabled, openai (NOT on the committed allowlist) should have been let through to JUDGED, got: $openai_entry3"
rm -rf "$MIRROR_D3"
ok "D3 MUTATION PROOF: disabling allowlist.sh's pa_is_allowed gate inside pa_disclose DOES let a non-allowlisted rotated judge (openai) through to JUDGED — D1's refusal is load-bearing"

count
DLOG_D4="$WORK/dlog-d4.jsonl"; COUNT_D4="$WORK/count-d4"
out="$(run_rotate "$ALLOW_ANTHROPIC" "$DLOG_D4" "$COUNT_D4" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
openai_entry4="$(jq -c '.judge_rotation.judges[] | select(.rotation_provider=="openai")' <<<"$out")"
[ "$(jq -r '.outcome' <<<"$openai_entry4")" = "CANNOT_EVALUATE" ] || fail "D4: RESTORED behaviour should refuse the non-allowlisted openai member again, got: $openai_entry4"
ok "D4 RESTORED: the unmutated allowlist gate refuses a non-allowlisted rotated judge again"

# --- MUTATION PROOF D5: the disclosure append is load-bearing ---------------
count
MIRROR_D5="$WORK/mirror-d5"
mk_mirror "$MIRROR_D5"
unlink_and_copy "$MIRROR_D5/workflows/scripts/model-comparison/allowlist.sh"
mutate_file "$MIRROR_D5/workflows/scripts/model-comparison/allowlist.sh" \
  'printf '"'"'%s\n'"'"' "$record" >>"$log" || {
    echo "allowlist.sh: pa_disclose: failed to append to $log — no entry written" >&2
    return 1
  }' \
  'true # MUTATED: append intentionally skipped'
DLOG_D5="$WORK/dlog-d5.jsonl"; COUNT_D5="$WORK/count-d5"
MUT_JUDGE_D5="$MIRROR_D5/workflows/scripts/model-comparison/judge.sh"
out="$(env MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 \
      JSTUB_COUNT_FILE="$COUNT_D5" MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW_BOTH" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG_D5" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$MUT_JUDGE_D5" judge-rotate \
        --record "$RECORD" --judges "$DEFAULT_JUDGES" --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
openai_entry5="$(jq -c '.judge_rotation.judges[] | select(.rotation_provider=="openai")' <<<"$out")"
[ "$(jq -r '.outcome' <<<"$openai_entry5")" = "JUDGED" ] || fail "D5: MUTATION PROOF setup failed — the allowlisted openai member should still reach JUDGED (only the WRITE is mutated, not the gate), got: $openai_entry5"
[ ! -s "$DLOG_D5" ] || fail "D5: MUTATION PROOF did not fire — with the append skipped, the disclosure log should have STAYED EMPTY for an openai send that nonetheless happened, got: $(cat "$DLOG_D5")"
rm -rf "$MIRROR_D5"
ok "D5 MUTATION PROOF: skipping allowlist.sh's own log-append write DOES let a rotated non-default judge's call proceed with NO disclosure entry recorded — D2's disclosure-log assertion is load-bearing (it would have caught this)"

count
DLOG_D6="$WORK/dlog-d6.jsonl"; COUNT_D6="$WORK/count-d6"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_D6" "$COUNT_D6" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
[ -s "$DLOG_D6" ] || fail "D6: RESTORED behaviour should append a disclosure entry again"
[ "$(grep -c . "$DLOG_D6")" = "1" ] || fail "D6: RESTORED behaviour should append exactly one entry again"
ok "D6 RESTORED: the unmutated disclosure append writes a log entry again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — the cross-family requirement, configured AND judged level
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_E1="$WORK/dlog-e1.jsonl"; COUNT_E1="$WORK/count-e1"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_E1" "$COUNT_E1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "anthropic:model-a,anthropic:model-b" \
        --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "E1: two CONFIGURED judges from the SAME provider family must CANNOT_EVALUATE before any spend, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "E1: expected CANNOT_EVALUATE, got: $out"
case "$(jq -r .error <<<"$out")" in
  *"more than one provider family"*) ;;
  *) fail "E1: expected the refusal to name the cross-family requirement, got: $out" ;;
esac
[ "$(cat "$COUNT_E1" 2>/dev/null || echo 0)" = "0" ] || fail "E1: the configured-level family check must fail BEFORE any judge call — no spend should have happened"
ok "E1 two configured judges from the same provider family CANNOT_EVALUATE up front — cheap fail, no spend"

count
DLOG_E2="$WORK/dlog-e2.jsonl"; COUNT_E2="$WORK/count-e2"
# 4 configured members, spanning 2 families (passes the E1-style up-front
# check): claude-sonnet-5 == the record's own candidate -> REFUSED
# (self-grading); openai is not on ALLOW_ANTHROPIC -> CANNOT_EVALUATE. The
# TWO remaining members (claude-opus-4-8, claude-haiku-5) both reach JUDGED —
# meeting the default MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES=2 floor —
# but both are anthropic, so n_families_judged collapses to 1. This isolates
# the FAMILY-diversity failure from the SAMPLE-SIZE failure E1 exercises.
SELF_JUDGES="anthropic:claude-sonnet-5,anthropic:claude-opus-4-8,anthropic:claude-haiku-5,openai:gpt-5"
out="$(run_rotate "$ALLOW_ANTHROPIC" "$DLOG_E2" "$COUNT_E2" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$SELF_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "E2: a panel that collapses to JUDGED scores from only one family post-hoc must CANNOT_EVALUATE, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "E2: expected judge_rotation.outcome CANNOT_EVALUATE, got: $out"
[ "$(jq -r .judge_rotation.n_configured_families <<<"$out")" = "2" ] || fail "E2: the CONFIGURED panel spans 2 families (this must pass the up-front check), got: $out"
[ "$(jq -r .judge_rotation.n_judged <<<"$out")" = "2" ] || fail "E2: expected n_judged 2 (meeting the default MIN_JUDGES floor — this must NOT be the sample-size failure), got: $out"
[ "$(jq -r .judge_rotation.n_families_judged <<<"$out")" = "1" ] || fail "E2: the JUDGED subset should collapse to exactly 1 family, got: $out"
case "$(jq -r .judge_rotation.variance_unavailable_reason <<<"$out")" in
  *"more than one provider family"*) ;;
  *) fail "E2: expected the post-hoc reason to name the family requirement (not the sample-size floor), got: $out" ;;
esac
ok "E2 a configured 2-family panel that DEGRADES to 2 JUDGED scores from only one family post-hoc CANNOT_EVALUATEs the variance on FAMILY grounds — distinct from E1's up-front check and from the sample-size floor"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES is genuinely wired
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_F1="$WORK/dlog-f1.jsonl"; COUNT_F1="$WORK/count-f1"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_F1" "$COUNT_F1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "F1 (baseline, default MIN_JUDGES=2, 2 configured): expected success, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "ROTATED" ] || fail "F1: expected ROTATED at the default threshold, got: $out"
ok "F1 baseline: at the DEFAULT MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES (2), a 2-JUDGED panel computes variance"

count
DLOG_F2="$WORK/dlog-f2.jsonl"; COUNT_F2="$WORK/count-f2"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_F2" "$COUNT_F2" 1 3 \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F2: raising MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES to a NON-DEFAULT 3 (with only 2 configured judges) must CANNOT_EVALUATE the variance, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "F2: expected CANNOT_EVALUATE, got: $out"
case "$(jq -r .judge_rotation.variance_unavailable_reason <<<"$out")" in
  *"MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES"*) ;;
  *) fail "F2: expected the reason to name the setting, got: $out" ;;
esac
ok "F2 raising MODEL_COMPARISON_JUDGE_ROTATION_MIN_JUDGES to a NON-DEFAULT value (3) genuinely changes the outcome — the setting is wired, not read-and-ignored"

count
DLOG_F3="$WORK/dlog-f3.jsonl"; COUNT_F3="$WORK/count-f3"
THREE_JUDGES="anthropic:claude-opus-4-8,openai:gpt-5,openai:gpt-5-mini"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_F3" "$COUNT_F3" 1 3 \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$THREE_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90,80 bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "F3: 3 configured judges at MIN_JUDGES=3 (also NON-DEFAULT) must succeed, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "ROTATED" ] || fail "F3: expected ROTATED once n_judged reaches the raised threshold, got: $out"
ok "F3 with n_judged raised to meet the NON-DEFAULT MIN_JUDGES=3 threshold, variance computes again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — partial degradation: variance still computed, exit 4
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_G1="$WORK/dlog-g1.jsonl"; COUNT_G1="$WORK/count-g1"
G_JUDGES="anthropic:claude-sonnet-5,anthropic:claude-opus-4-8,openai:gpt-5"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_G1" "$COUNT_G1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$G_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90,80 bash $JSTUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "G1: a panel where one of three configured members is REFUSED (self-grading) but variance still computes over the rest must exit 4, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "ROTATED" ] || fail "G1: expected judge_rotation.outcome ROTATED (variance WAS computed), got: $out"
[ "$(jq -r .judge_rotation.n_configured <<<"$out")" = "3" ] || fail "G1: expected n_configured 3, got: $out"
[ "$(jq -r .judge_rotation.n_judged <<<"$out")" = "2" ] || fail "G1: expected n_judged 2 (the self-grading member excluded), got: $out"
[ "$(jq -r '[.judge_rotation.judges[] | select(.outcome=="REFUSED")] | length' <<<"$out")" = "1" ] || fail "G1: expected exactly one REFUSED member, got: $out"
[ "$(jq -r .judge_rotation.variance.value <<<"$out")" != "null" ] || fail "G1: variance must still be reported despite the degraded member — never null when it WAS computable, got: $out"
ok "G1 one degraded (REFUSED) rotation member never blocks a variance the remaining members can still support — exit 4, variance present, degradation named per-member"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — fail-closed + the suite-wide no-live-call canary
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_H1="$WORK/dlog-h1.jsonl"; COUNT_H1="$WORK/count-h1"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_H1" "$COUNT_H1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES")"
rc=$?
[ "$rc" -eq 1 ] || fail "H1: judge-rotate with NO runner and NO --live must refuse, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "H1: expected CANNOT_EVALUATE, got: $out"
case "$(jq -r .error <<<"$out")" in
  *"no judge runner configured"*) ;;
  *) fail "H1: expected the refusal to name the missing seam, got: $out" ;;
esac
[ ! -e "$CANARY" ] || fail "H1: the unset-seam refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "H1 an UNSET judge-runner seam REFUSES judge-rotate too — no fallback to a 'claude' on PATH, no call"

count
DLOG_H2="$WORK/dlog-h2.jsonl"; COUNT_H2="$WORK/count-h2"
out="$(run_with_timeout 5 env MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 \
      JSTUB_COUNT_FILE="$COUNT_H2" MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW_BOTH" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG_H2" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "anthropic:model-a" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "H2: fewer than 2 --judges entries must CANNOT_EVALUATE, got $rc: $out"
[ "$rc" -ne 137 ] || fail "H2: a single --judges entry HUNG instead of failing fast"
case "$out" in
  *"at least 2 configured judges"*) ;;
  *) fail "H2: expected the refusal to name the minimum, got: $out" ;;
esac
ok "H2 fewer than 2 configured judges CANNOT_EVALUATEs (rc 1), under a bounded timeout, never hangs"

count
out="$(run_with_timeout 5 bash "$JUDGE" judge-rotate --record "$RECORD" --judges "malformed-no-colon,openai:gpt-5" \
      --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
# MODEL_COMPARISON_JUDGE_ROTATION_ENABLED is unset in THIS call, so the
# rotation-mode gate fires before argument shape is even inspected — proving
# the malformed-entry path needs a SEPARATE assertion with the gate enabled
# (H4 below).
[ "$rc" -eq 1 ] || fail "H3 (gate-off sanity): expected CANNOT_EVALUATE, got $rc: $out"
ok "H3 sanity: with the rotation gate off, a malformed --judges spec still resolves to CANNOT_EVALUATE via the gate itself (never reaches the parser)"

count
out="$(run_with_timeout 5 env MODEL_COMPARISON_JUDGE_ROTATION_ENABLED=1 bash "$JUDGE" judge-rotate \
      --record "$RECORD" --judges "malformed-no-colon,openai:gpt-5" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "H4: a malformed --judges entry (no colon) must CANNOT_EVALUATE, got $rc: $out"
[ "$rc" -ne 137 ] || fail "H4: a malformed --judges entry HUNG instead of failing fast"
case "$out" in
  *"malformed --judges entry"*) ;;
  *) fail "H4: expected the refusal to name the malformed entry, got: $out" ;;
esac
ok "H4 a malformed '--judges' entry (missing the ':' separator) CANNOT_EVALUATEs under a bounded timeout"

count
out="$(run_with_timeout 5 bash "$JUDGE" judge-rotate --record "$RECORD" --judges 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "H5: a trailing --judges with no value must fail fast (rc 2), got $rc: $out"
[ "$rc" -ne 137 ] || fail "H5: a trailing --judges with no value HUNG instead of failing fast"
ok "H5 a trailing --judges with no value fails fast under a bounded timeout, never hangs"

# --- a GENUINE stats.sh failure -> CANNOT_EVALUATE, never a fabricated
#     variance (fail-closed: temperloop#1365 class). A fake `python3` ahead
#     of the real one on PATH for THIS call only breaks stats.sh's own
#     numeric core, which judge-rotate must surface as CANNOT_EVALUATE
#     rather than silently reporting no variance / a zero variance.
count
FAKEPY_BIN="$WORK/fakepy-bin"
mkdir -p "$FAKEPY_BIN"
cat >"$FAKEPY_BIN/python3" <<'EOF'
#!/usr/bin/env bash
echo "fakepy: python3 unavailable (test fixture)" >&2
exit 1
EOF
chmod +x "$FAKEPY_BIN/python3"
DLOG_H6="$WORK/dlog-h6.jsonl"; COUNT_H6="$WORK/count-h6"
out="$(PATH="$FAKEPY_BIN:$PATH" run_rotate "$ALLOW_BOTH" "$DLOG_H6" "$COUNT_H6" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "H6: a genuine stats.sh failure (python3 unavailable) must CANNOT_EVALUATE the variance, got $rc: $out"
[ "$(jq -r .judge_rotation.outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "H6: expected judge_rotation.outcome CANNOT_EVALUATE, got: $out"
[ "$(jq -r .judge_rotation.variance <<<"$out")" = "null" ] || fail "H6: variance must be null, never a fabricated figure, when stats.sh itself failed, got: $out"
case "$(jq -r .judge_rotation.variance_unavailable_reason <<<"$out")" in
  *"stats.sh"*) ;;
  *) fail "H6: expected the reason to name stats.sh's own failure, got: $out" ;;
esac
[ "$(jq -r '[.judge_rotation.judges[] | select(.outcome=="JUDGED")] | length' <<<"$out")" = "2" ] || fail "H6: both rotation members should still have reached JUDGED individually — only the AGGREGATE variance step failed, got: $out"
ok "H6 fail-closed: a genuine stats.sh failure (python3 unavailable) CANNOT_EVALUATEs the variance — never a silent pass, never a fabricated or zero-standing-in figure, even though both individual judges DID score"

count
[ ! -e "$CANARY" ] || fail "H7: NO LIVE MODEL CALL invariant violated somewhere in sections A-H — the 'claude' canary on PATH was invoked: $(cat "$CANARY")"
ok "H7 NO LIVE MODEL CALL: the 'claude' canary on PATH was never invoked by any test in this suite"

count
"$WORK/bin/claude" --self-test-only >/dev/null 2>&1 || true
[ -e "$CANARY" ] || fail "H8: the canary itself does not fire when invoked directly — H7 proves nothing"
rm -f "$CANARY"
ok "H8 the canary is functional — H7 is a measurement, not a tautology"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — the overclaim discipline: REPORTS, never PROVES
# ═══════════════════════════════════════════════════════════════════════════

count
DLOG_I1="$WORK/dlog-i1.jsonl"; COUNT_I1="$WORK/count-i1"
out="$(run_rotate "$ALLOW_BOTH" "$DLOG_I1" "$COUNT_I1" 1 "" \
      bash "$JUDGE" judge-rotate --record "$RECORD" --judges "$DEFAULT_JUDGES" \
        --judge-runner "env JSTUB_SCORES=70,90 bash $JSTUB")"
disclaimer="$(jq -r .judge_rotation.disclaimer <<<"$out")"
[ -n "$disclaimer" ] && [ "$disclaimer" != "null" ] || fail "I1: expected a non-empty judge_rotation.disclaimer, got: $out"
case "$disclaimer" in
  *"REPORTS"*"does NOT PROVE"*) ;;
  *) fail "I1: expected the disclaimer to state REPORTS ... does NOT PROVE, got: $disclaimer" ;;
esac
# The disclaimer must never itself claim the OPPOSITE — belt-and-suspenders
# against a future edit accidentally inverting the sentence.
case "$disclaimer" in
  *"proves"*"free of"*) fail "I1: the disclaimer appears to CLAIM neutrality rather than disclaim it: $disclaimer" ;;
  *"guarantees no bias"*) fail "I1: the disclaimer appears to CLAIM neutrality rather than disclaim it: $disclaimer" ;;
  *"eliminates bias"*) fail "I1: the disclaimer appears to CLAIM neutrality rather than disclaim it: $disclaimer" ;;
  *) ;;
esac
ok "I1 the emitted judge_rotation.disclaimer states rotation REPORTS variance and does NOT PROVE neutrality — every ROTATED/CANNOT_EVALUATE record carries it"

count
# Structural corroboration only (not the primary proof — I1's functional
# check above is): no line in judge.sh (comments included, since even a
# comment must never assert the false claim unqualified) may claim rotation
# proves/guarantees an unbiased judgment.
if grep -nE '(proves|guarantees) (rotation is|the judgment is|it is) (unbiased|bias-free|free of bias)' "$JUDGE" >/dev/null 2>&1; then
  fail "I2: judge.sh contains a line that appears to claim rotation proves/guarantees an unbiased judgment: $(grep -nE '(proves|guarantees) (rotation is|the judgment is|it is) (unbiased|bias-free|free of bias)' "$JUDGE")"
fi
ok "I2 (structural corroboration) judge.sh carries no line claiming rotation proves/guarantees an unbiased judgment"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "test_judge_rotation.sh: $pass/$total assertions passed"
[ "$pass" -eq "$total" ] || fail "not all assertions passed"
