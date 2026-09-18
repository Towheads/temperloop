#!/usr/bin/env bash
#
# test_judge_pairwise.sh — fixture suite for the PAIRWISE judge mode
# (temperloop#2065, epic #2065 "dual-build"): `judge.sh pairwise`.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE (same shape as test_judge.sh /
#    test_judge_rotation.sh) ──────────────────────────────────────────────
#   1. THE SEAM. Every `pairwise` invocation below drives a RECORDED judge
#      runner (`--judge-runner "bash $JSTUB"`) whose stdout is a canned
#      `claude -p --output-format json`-shaped envelope on disk. `--live`
#      is never passed by any test in this file.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to `$WORK/CANARY`.
#      Section G asserts that file never came into existence.
#
# No network, no `gh`, no git worktree at all (pairwise, like judge.sh's
# single-judge path, operates purely on two already-executed JSON records —
# no repo, no candidate worktree needed), no writes outside $TMPDIR.
#
# Sections:
#   A  the judge≠EITHER-arm guard — REFUSED before any spend, for a match
#      against arm A and, independently, against arm B
#   B  the happy path: orders AGREE (normalize to the same real candidate
#      despite different raw position answers) — preference resolved,
#      order_agreement:true, margin is the mean of the two orders' margins
#   C  a genuine, order-consistent TIE (both orders independently answer
#      "tie") resolves to preference:"tie", order_agreement:true — a real
#      verdict, not a degradation
#   D  orders DISAGREE (pure position bias: both orders pick "position 1"
#      regardless of content) -> preference:"tie", order_agreement:false,
#      margin:0 — distinguishable from C's genuine tie by order_agreement
#   E  UNAVAILABLE: one order's call fails -> exit 4, a NAMED
#      degradation_notice on that order, no fabricated preference; the
#      OTHER order's genuine JUDGED result is still visible on the row
#   F  fail-closed: missing --record-a/--record-b, unreadable record,
#      no candidate.model, no runner configured, --judge-runner/--live
#      mutual exclusivity, malformed args
#   G  the suite-wide no-live-call canary verdict
#   H  the emitted object is never merged onto either input record (both
#      files are read-only inputs)
#
# Usage: bash workflows/scripts/model-comparison/tests/test_judge_pairwise.sh
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-judge-pairwise-XXXXXX")"
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
# it. Section G fails the whole suite if this file exists at the end.
printf 'INVOKED %s\n' "\$*" >>"$CANARY"
exit 0
EOF
chmod +x "$WORK/bin/claude"
PATH="$WORK/bin:$PATH"
export PATH

# ═══════════════════════════════════════════════════════════════════════════
# FIXTURES
# ═══════════════════════════════════════════════════════════════════════════

# mk_record <file> <candidate-model> [--no-candidate]
mk_record() {
  local file="$1" cmodel="$2"
  if [ "${3:-}" = "--no-candidate" ]; then
    jq -cn '{schema_version:"replay-record-v1", pr:999, issue:"#4242",
      title:"Fix the thing", scope:"the scope",
      acceptance:["A named path is fixed."],
      candidate:{provider:null, model:null, diff_ref:null},
      score:{verdict:null, diff:null, gate_result:null}}' >"$file"
    return 0
  fi
  jq -cn --arg cm "$cmodel" \
    '{schema_version:"replay-record-v1", pr:999, issue:"#4242",
      title:"Fix the thing", scope:"the scope",
      acceptance:["A named path is fixed."],
      candidate:{provider:"anthropic", model:$cm, diff_ref:"deadbeef"},
      score:{verdict:"pass", diff:{n:{total:1,changed:1}}, gate_result:{passed:true}}}' >"$file"
}

RECORD_A="$WORK/record-a.json"; mk_record "$RECORD_A" "claude-sonnet-5"
RECORD_B="$WORK/record-b.json"; mk_record "$RECORD_B" "claude-haiku-5"

# ── the RECORDED judge runner. Invoked as `<cmd> <prompt-file>`. Each call's
#    PREFERENCE/MARGIN is picked by call ORDER (via a counter file), so a
#    two-call pairwise comparison can be driven to a deterministic
#    known-answer outcome. JSTUB_POSITIONS/JSTUB_MARGINS are explicit
#    COMMA-separated per-call lists (the N-th call gets the N-th value; a
#    call past the list's end gets the default). Comma-, not space-,
#    separated for the same reason test_judge_rotation.sh's JSTUB_SCORES is:
#    the runner is a command STRING split on IFS whitespace by judge.sh's
#    own `$runner "$prompt_file"` (unquoted). JSTUB_FAIL_AT forces one
#    specific call to fail (a runner-spawn error).
JSTUB="$WORK/judge-stub.sh"
cat >"$JSTUB" <<'STUBEOF'
#!/usr/bin/env bash
set -u
prompt="$1"
COUNT_FILE="${JSTUB_COUNT_FILE:-/tmp/jstub-pw-count}"
n=0
[ -f "$COUNT_FILE" ] && n="$(cat "$COUNT_FILE")"
n=$((n + 1))
echo "$n" >"$COUNT_FILE"
if [ -n "${JSTUB_PROMPT_LOG:-}" ]; then
  { printf -- '--- call %s ---\n' "$n"; cat "$prompt"; } >>"$JSTUB_PROMPT_LOG"
fi

if [ -n "${JSTUB_FAIL_AT:-}" ] && [ "$n" -eq "${JSTUB_FAIL_AT}" ]; then
  echo "jstub: forced failure at call $n" >&2
  exit 5
fi

pref="1"
margin=60
if [ -n "${JSTUB_POSITIONS:-}" ]; then
  i=1
  positions_spaced="$(printf '%s' "$JSTUB_POSITIONS" | tr ',' ' ')"
  for p in $positions_spaced; do
    if [ "$i" -eq "$n" ]; then pref="$p"; fi
    i=$((i + 1))
  done
fi
if [ -n "${JSTUB_MARGINS:-}" ]; then
  i=1
  margins_spaced="$(printf '%s' "$JSTUB_MARGINS" | tr ',' ' ')"
  for m in $margins_spaced; do
    if [ "$i" -eq "$n" ]; then margin="$m"; fi
    i=$((i + 1))
  done
fi

body="$(jq -cn --arg pref "$pref" --argjson margin "$margin" \
  '{preference:$pref, margin:$margin, rationale:"stub rationale", concerns:[]}')"
jq -cn --arg body "$body" \
  '{result:$body, modelUsage:{"stub-model":{inputTokens:5,outputTokens:5,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:5, is_error:false}'
STUBEOF
chmod +x "$JSTUB"

# ── env every pairwise run gets: the disclosure log, allowlist, attribution
#    lake, and per-test call counter all point INTO $WORK, never at the
#    checkout. ────────────────────────────────────────────────────────────
LAKE="$WORK/lake"
ALLOW="$WORK/allow.txt"
NOLOCAL="$WORK/no-such-local-override.txt"
printf 'anthropic\nopenai\n' >"$ALLOW"
mkdir -p "$LAKE"

# run_pairwise <positions> <margins> <fail-at-or-empty> <judge.sh args...>
run_pairwise() {
  local positions="$1" margins="$2" failat="$3"; shift 3
  local countfile; countfile="$(mktemp "$WORK/count.XXXXXX")"; rm -f "$countfile"
  local -a extra=()
  [ -n "$failat" ] && extra=(JSTUB_FAIL_AT="$failat")
  env JSTUB_POSITIONS="$positions" JSTUB_MARGINS="$margins" \
      "${extra[@]+"${extra[@]}"}" \
      JSTUB_COUNT_FILE="$countfile" \
      MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$JUDGE" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — the judge≠EITHER-arm guard
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_pairwise "1,2" "60,80" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-sonnet-5 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 2 ] || fail "A1: judge==arm-A must REFUSE (rc 2), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "REFUSED" ] || fail "A1: expected outcome REFUSED, got: $out"
[ "$(jq -r .reason <<<"$out")" = "judge-equals-arm" ] || fail "A1: expected reason judge-equals-arm, got: $out"
ok "A1 judge model identical to ARM A's model REFUSES before any spend"

count
out="$(run_pairwise "1,2" "60,80" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-haiku-5 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 2 ] || fail "A2: judge==arm-B must REFUSE (rc 2), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "REFUSED" ] || fail "A2: expected outcome REFUSED, got: $out"
ok "A2 judge model identical to ARM B's model ALSO REFUSES — the guard checks both arms independently"

count
COUNT_A3="$WORK/count-a3"
env JSTUB_POSITIONS="1,2" JSTUB_MARGINS="60,80" JSTUB_COUNT_FILE="$COUNT_A3" \
    bash "$JUDGE" pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
      --model claude-sonnet-5 --provider anthropic --judge-runner "bash $JSTUB" >/dev/null 2>&1
[ "$(cat "$COUNT_A3" 2>/dev/null || echo 0)" = "0" ] || fail "A3: the guard refusal must spend NO judge call"
[ ! -e "$CANARY" ] || fail "A3: the guard refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "A3 a REFUSED comparison spends zero judge calls"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — the happy path: orders AGREE despite different raw positions
# ═══════════════════════════════════════════════════════════════════════════
#
# Order AB: A is position 1, B is position 2. The stub's first call answers
# "1" (margin 60) -> normalizes to A.
# Order BA: B is position 1, A is position 2. The stub's second call answers
# "2" (margin 80) -> normalizes to A too.
# Both orders independently land on A: a genuine, order-independent
# preference, NOT a position artifact.

count
out="$(run_pairwise "1,2" "60,80" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-opus-4-8 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B1: an agreeing 2-order comparison must exit 0, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "COMPARED" ] || fail "B1: expected outcome COMPARED, got: $out"
[ "$(jq -r .preference <<<"$out")" = "A" ] || fail "B1: expected preference A (both orders normalize to A), got: $out"
[ "$(jq -r .order_agreement <<<"$out")" = "true" ] || fail "B1: expected order_agreement true, got: $out"
[ "$(jq -r .margin <<<"$out")" = "70" ] || fail "B1: expected margin 70 (mean of 60 and 80), got: $out"
ok "B1 orders that normalize to the SAME real candidate (A) despite DIFFERENT raw position answers (1 then 2) resolve to preference:A, order_agreement:true, margin = mean(60,80) = 70"

count
[ "$(jq -r '.orders | length' <<<"$out")" = "2" ] || fail "B2: expected 2 per-order entries, got: $out"
[ "$(jq -r '.orders[0].order' <<<"$out")" = "AB" ] || fail "B2: expected first order entry to be AB, got: $out"
[ "$(jq -r '.orders[1].order' <<<"$out")" = "BA" ] || fail "B2: expected second order entry to be BA, got: $out"
[ "$(jq -r '.candidate_a.model' <<<"$out")" = "claude-sonnet-5" ] || fail "B2: expected candidate_a.model claude-sonnet-5, got: $out"
[ "$(jq -r '.candidate_b.model' <<<"$out")" = "claude-haiku-5" ] || fail "B2: expected candidate_b.model claude-haiku-5, got: $out"
ok "B2 the emitted object carries both per-order rows and both arms' own provider/model"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — a genuine, order-consistent TIE
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_pairwise "tie,tie" "0,0" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-opus-4-8 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "C1: a consistent-tie comparison must exit 0 (a real verdict), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "COMPARED" ] || fail "C1: expected outcome COMPARED, got: $out"
[ "$(jq -r .preference <<<"$out")" = "tie" ] || fail "C1: expected preference tie, got: $out"
[ "$(jq -r .order_agreement <<<"$out")" = "true" ] || fail "C1: expected order_agreement true (BOTH orders independently said tie), got: $out"
ok "C1 both orders independently answering 'tie' resolves to preference:tie, order_agreement:true — a genuine verdict, distinct from D's position-sensitive tie below"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — orders DISAGREE: pure position bias
# ═══════════════════════════════════════════════════════════════════════════
#
# Both calls answer "1" — i.e. the judge always prefers whichever candidate
# is shown FIRST, regardless of content. Order AB normalizes "1" -> A; order
# BA normalizes "1" -> B. The two disagree, which is exactly the position
# artifact running both orders exists to catch.

count
out="$(run_pairwise "1,1" "60,80" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-opus-4-8 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "D1: a disagreeing comparison is still a valid COMPARED outcome (exit 0), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "COMPARED" ] || fail "D1: expected outcome COMPARED, got: $out"
[ "$(jq -r .preference <<<"$out")" = "tie" ] || fail "D1: expected preference tie (position-sensitive disagreement), got: $out"
[ "$(jq -r .order_agreement <<<"$out")" = "false" ] || fail "D1: expected order_agreement false, got: $out"
[ "$(jq -r .margin <<<"$out")" = "0" ] || fail "D1: expected margin 0 on a position-sensitive disagreement (never a fabricated confidence figure), got: $out"
ok "D1 a judge that answers 'position 1' in BOTH orders (pure position bias, not content) resolves to preference:tie, order_agreement:false, margin:0 — distinguishable from C1's genuine, order-consistent tie by order_agreement alone"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — UNAVAILABLE: one order's call fails
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_pairwise "1,2" "60,80" "2" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-opus-4-8 --provider anthropic --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "E1: one degraded order must exit 4, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "UNAVAILABLE" ] || fail "E1: expected outcome UNAVAILABLE, got: $out"
[ "$(jq -r .preference <<<"$out")" = "null" ] || fail "E1: expected preference null — never a fabricated preference when a call degraded, got: $out"
[ "$(jq -r .margin <<<"$out")" = "null" ] || fail "E1: expected margin null, got: $out"
[ "$(jq -r .order_agreement <<<"$out")" = "null" ] || fail "E1: expected order_agreement null, got: $out"
ok "E1 one order call failing UNAVAILABLEs the whole comparison (exit 4) — never a preference synthesized from the one order that DID succeed"

count
[ "$(jq -r '.orders[0].outcome' <<<"$out")" = "JUDGED" ] || fail "E2: expected the FIRST order (AB) to still show JUDGED, got: $out"
[ "$(jq -r '.orders[1].outcome' <<<"$out")" = "UNAVAILABLE" ] || fail "E2: expected the SECOND order (BA) to show UNAVAILABLE, got: $out"
case "$(jq -r '.orders[1].degradation_notice' <<<"$out")" in
  judge-spawn:*) ;;
  *) fail "E2: expected the failed order's degradation_notice to be NAMED (judge-spawn:...), got: $out" ;;
esac
ok "E2 the per-order breakdown is preserved: the genuinely-judged order still shows its real answer, and the failed order carries a NAMED degradation_notice"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — fail-closed
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-b "$RECORD_B" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F1: missing --record-a must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"no --record-a given"*) ;; *) fail "F1: expected the refusal to name --record-a, got: $out" ;; esac
ok "F1 a missing --record-a CANNOT_EVALUATEs, naming the missing flag"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$RECORD_A" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F2: missing --record-b must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"no --record-b given"*) ;; *) fail "F2: expected the refusal to name --record-b, got: $out" ;; esac
ok "F2 a missing --record-b CANNOT_EVALUATEs, naming the missing flag"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$WORK/nope.json" --record-b "$RECORD_B" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F3: an unreadable --record-a must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"not found or not a readable regular file"*) ;; *) fail "F3: expected the refusal to name the unreadable file, got: $out" ;; esac
ok "F3 an unreadable --record-a CANNOT_EVALUATEs"

count
NOCAND="$WORK/no-candidate.json"; mk_record "$NOCAND" "" --no-candidate
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$NOCAND" --record-b "$RECORD_B" --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F4: --record-a with no .candidate.model must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"carries no .candidate.model"*) ;; *) fail "F4: expected the refusal to name the missing candidate.model, got: $out" ;; esac
ok "F4 a record with no .candidate.model CANNOT_EVALUATEs rather than comparing against an unresolved arm"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F5: no judge runner configured must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"no judge runner configured"*) ;; *) fail "F5: expected the refusal to name the missing seam, got: $out" ;; esac
[ ! -e "$CANARY" ] || fail "F5: the unset-seam refusal reached a 'claude' binary: $(cat "$CANARY")"
ok "F5 an UNSET judge-runner seam REFUSES pairwise too — no fallback to a 'claude' on PATH, no call"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" --judge-runner "bash $JSTUB" --live 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "F6: --judge-runner and --live together must CANNOT_EVALUATE, got $rc: $out"
case "$out" in *"mutually exclusive"*) ;; *) fail "F6: expected the refusal to name the mutual exclusivity, got: $out" ;; esac
ok "F6 --judge-runner and --live together CANNOT_EVALUATEs (mutually exclusive)"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" --bogus-flag 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "F7: an unknown flag must fail fast (rc 2), got $rc: $out"
[ "$rc" -ne 137 ] || fail "F7: an unknown flag HUNG instead of failing fast"
ok "F7 an unknown flag fails fast under a bounded timeout, never hangs"

count
out="$(run_with_timeout 5 bash "$JUDGE" pairwise --record-a 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "F8: a trailing --record-a with no value must fail fast (rc 2), got $rc: $out"
[ "$rc" -ne 137 ] || fail "F8: a trailing --record-a with no value HUNG instead of failing fast"
ok "F8 a trailing --record-a with no value fails fast under a bounded timeout"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — the suite-wide no-live-call canary verdict
# ═══════════════════════════════════════════════════════════════════════════

count
[ ! -e "$CANARY" ] || fail "G1: NO LIVE MODEL CALL invariant violated somewhere in sections A-F — the 'claude' canary on PATH was invoked: $(cat "$CANARY")"
ok "G1 NO LIVE MODEL CALL: the 'claude' canary on PATH was never invoked by any test in this suite"

count
"$WORK/bin/claude" --self-test-only >/dev/null 2>&1 || true
[ -e "$CANARY" ] || fail "G2: the canary itself does not fire when invoked directly — G1 proves nothing"
rm -f "$CANARY"
ok "G2 the canary is functional — G1 is a measurement, not a tautology"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — the emitted object is never merged onto either input record
# ═══════════════════════════════════════════════════════════════════════════

count
BEFORE_A="$(jq -Sc . "$RECORD_A")"
BEFORE_B="$(jq -Sc . "$RECORD_B")"
run_pairwise "1,2" "60,80" "" \
  pairwise --record-a "$RECORD_A" --record-b "$RECORD_B" \
    --model claude-opus-4-8 --provider anthropic --judge-runner "bash $JSTUB" >/dev/null
AFTER_A="$(jq -Sc . "$RECORD_A")"
AFTER_B="$(jq -Sc . "$RECORD_B")"
[ "$BEFORE_A" = "$AFTER_A" ] || fail "H1: --record-a must be read-only — its content changed after a pairwise call"
[ "$BEFORE_B" = "$AFTER_B" ] || fail "H1: --record-b must be read-only — its content changed after a pairwise call"
ok "H1 pairwise never mutates either input record file — the comparison is emitted as its own standalone object"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "test_judge_pairwise.sh: $pass/$total assertions passed"
[ "$pass" -eq "$total" ] || fail "not all assertions passed"
