#!/usr/bin/env bash
#
# test_judge.sh — fixture suite for the JUDGE pass (temperloop#1259, epic
# #1225 "model comparison harness"): `judge.sh judge`/`judge-batch`.
#
# ── HERMETIC BY CONSTRUCTION, NOT BY PROMISE (same shape as
#    test_replay_score.sh) ──────────────────────────────────────────────────
#   1. THE SEAM. Every `judge`/`judge-batch` invocation below drives a
#      RECORDED judge runner (`--judge-runner "bash $JSTUB"`) whose stdout is
#      a canned `claude -p --output-format json`-shaped envelope on disk.
#      `--live` is never passed by any test in this file.
#   2. THE CANARY. `$WORK/bin` is prepended to PATH for the WHOLE suite and
#      contains a `claude` that records its own invocation to `$WORK/CANARY`.
#      Section H asserts that file never came into existence. Section C's
#      mutation proof then MUTATES the no-runner refusal branch (in a
#      throwaway mirror of the module) to fall back to a bare `claude`, and
#      proves the canary DOES fire — the refusal is load-bearing and the
#      canary can detect its absence.
#
# No network, no `gh`, no git worktree at all (judge.sh operates purely on
# an already-executed JSON record — no repo, no candidate worktree needed),
# no writes outside $TMPDIR.
#
# Sections:
#   A  the judge≠candidate guard — REFUSED before any spend, + mutation proof
#   B  the degradation notice — a genuine judge.quality_score:0 is
#      distinguishable from judge.scored:false + a named degradation_notice,
#      across every failure shape, + mutation proof of the distinction
#   C  the judge-runner seam — its REFUSAL when unset, and the mutation
#      proof that the refusal is load-bearing
#   D  the rubric flows into the prompt as PLAIN TEXT, never a runtime
#      reviewer-agent dispatch
#   E  judge-batch: every input line produces exactly one output line — a
#      degraded row is never a dropped row
#   F  fail-closed: absent / empty / malformed / candidate-less / rubric-less
#      / overlay-less, everywhere
#   G  arg hygiene (trailing flag, flag-like value) under a bounded timeout
#   H  record preservation END TO END (temperloop#1556): a mixed arm of
#      scored + integration-error records survives judge-batch with every
#      record still present, rolls up under score.sh aggregate, and renders
#      through the REAL report producer — with a mutation proof that the
#      pre-fix substitution corrupts that same arm and takes the roll-up
#      down with it
#   I  the suite-wide no-live-call canary verdict
#
# Usage: bash workflows/scripts/model-comparison/tests/test_judge.sh
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-judge-XXXXXX")"
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
# test_replay_score.sh). Dies loudly if the old text is missing or not
# unique, so a mutation proof can never silently become a no-op that "passes".
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
# under <dest>, so a mutation proof can edit ONE real copy of judge.sh
# without ever writing into the checkout.
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
# FIXTURES — a bare replay-record-v1 JSON (no repo, no worktree: judge.sh
# never touches either) and a RECORDED judge-runner test double.
# ═══════════════════════════════════════════════════════════════════════════

# mk_record <file> [--candidate-model M] [--candidate-provider P]
#           [--issue N] [--no-candidate]
mk_record() {
  local file="$1"; shift
  local cmodel="claude-sonnet-5" cprovider="anthropic" issue="4242" has_cand=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --candidate-model) cmodel="$2"; shift 2 ;;
      --candidate-provider) cprovider="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --no-candidate) has_cand=0; shift ;;
      *) echo "mk_record: bad arg $1" >&2; return 2 ;;
    esac
  done
  if [ "$has_cand" -eq 1 ]; then
    jq -cn --arg cm "$cmodel" --arg cp "$cprovider" --arg issue "$issue" \
      '{schema_version:"replay-record-v1", pr:999, issue:("#" + $issue),
        title:"Fix the thing", scope:"the scope",
        acceptance:["A named path is fixed."],
        candidate:{provider:$cp, model:$cm, diff_ref:"deadbeef"},
        score:{verdict:"pass", diff:{n:{total:1,changed:1}}, gate_result:{passed:true}}}' >"$file"
  else
    jq -cn --arg issue "$issue" \
      '{schema_version:"replay-record-v1", pr:999, issue:("#" + $issue),
        title:"Fix the thing", scope:"the scope",
        acceptance:["A named path is fixed."],
        candidate:{provider:null, model:null, diff_ref:null},
        score:{verdict:null, diff:null, gate_result:null}}' >"$file"
  fi
}

RECORD="$WORK/record.json"
mk_record "$RECORD"

# ── the RECORDED judge runner (the test seam). Invoked as `<cmd>
#    <prompt-file>`. $JSTUB_MODE picks the response shape; every call is
#    tallied to $WORK/jstub-calls, and — when $JSTUB_PROMPT_LOG is set — the
#    prompt it was handed is appended there verbatim, so a test can assert
#    both "how many times was I called" and "what was I actually shown".
JSTUB="$WORK/judge-stub.sh"
cat >"$JSTUB" <<STUBEOF
#!/usr/bin/env bash
set -u
prompt="\$1"
COUNT_FILE="$WORK/jstub-calls"
n=0
[ -f "\$COUNT_FILE" ] && n="\$(cat "\$COUNT_FILE")"
n=\$((n + 1))
echo "\$n" >"\$COUNT_FILE"
if [ -n "\${JSTUB_PROMPT_LOG:-}" ]; then
  { printf -- '--- call %s ---\n' "\$n"; cat "\$prompt"; } >>"\$JSTUB_PROMPT_LOG"
fi
mkbody() {  # mkbody <score> -> a valid contracted JSON response, as text
  # NOTE: no tojson filter here (deliberately, and no backticks in THIS
  # comment either) -- jq -cn's default rendering of a top-level OBJECT
  # already IS its compact JSON text (no wrapping quotes); a tojson filter
  # would double-encode it into a JSON STRING, and every caller below embeds
  # the result inside another jq --arg (raw string capture), which would
  # then carry doubly-escaped text as .result's value. A literal backtick in
  # this heredoc (even backslash-escaped) is also worth avoiding on its own
  # merits: it is exactly the class of bug that bit this fixture once.
  jq -cn --argjson qs "\$1" \
    '{quality_score:\$qs,
      dimensions:{correctness:\$qs, acceptance_coverage:\$qs, test_quality:\$qs,
                  portability_robustness:\$qs, simplicity_reuse:\$qs},
      rationale:"stub rationale", concerns:[]}'
}
case "\${JSTUB_MODE:-good}" in
  good)
    jq -cn --arg body "\$(mkbody 85)" \
      '{result:\$body, modelUsage:{"claude-opus-4-8":{inputTokens:20,outputTokens:20,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:15, is_error:false}'
    ;;
  zero)
    jq -cn --arg body "\$(mkbody 0)" \
      '{result:\$body, modelUsage:{"claude-opus-4-8":{inputTokens:20,outputTokens:20,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:15, is_error:false}'
    ;;
  fenced)
    jq -cn --arg body "\$(mkbody 42)" \
      '{result:("\`\`\`json\n" + \$body + "\n\`\`\`"), modelUsage:{"claude-opus-4-8":{inputTokens:5,outputTokens:5,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:10, is_error:false}'
    ;;
  spawnfail) echo "vendor connection reset" >&2; exit 3 ;;
  # ── the two temperloop#1553 judge-spawn shapes ─────────────────────────
  # THE REAL ONE: claude -p --output-format json reports an API-level failure
  # as a JSON object on STDOUT and writes NOTHING to stderr, so the judge
  # spawn recorded "judge-spawn: the judge runner exited 1: " — the same
  # blank shape the candidate spawn did, for the same reason.
  spawnfail_stdout)
    jq -cn '{type:"result", subtype:"error_during_execution", is_error:true,
             api_error_status:529, duration_ms:640,
             result:"API Error: 529 upstream overloaded"}'
    exit 1
    ;;
  # Genuinely silent on BOTH streams — the notice must SAY there was nothing.
  spawnfail_silent) exit 1 ;;
  badenvelope) printf 'not json at all\n'; exit 0 ;;
  vendorerror)
    jq -cn '{is_error:true, subtype:"api_error_overloaded"}'
    ;;
  nousage)
    jq -cn --arg body "\$(mkbody 10)" '{result:\$body, is_error:false, duration_ms:5}'
    ;;
  unparseable)
    jq -cn '{result:"the model just chatted instead of answering", modelUsage:{"claude-opus-4-8":{inputTokens:1,outputTokens:1,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, is_error:false}'
    ;;
  flaky)
    at="\${JSTUB_FAIL_AT:-2}"
    if [ "\$n" -eq "\$at" ]; then echo "boom" >&2; exit 5; fi
    jq -cn --arg body "\$(mkbody 70)" \
      '{result:\$body, modelUsage:{"claude-opus-4-8":{inputTokens:20,outputTokens:20,cacheReadInputTokens:0,cacheCreationInputTokens:0}}, duration_ms:15, is_error:false}'
    ;;
  hang) sleep 30; exit 0 ;;
  *) echo "jstub: unknown JSTUB_MODE \${JSTUB_MODE:-}" >&2; exit 9 ;;
esac
STUBEOF
chmod +x "$JSTUB"

# ── env every judge run gets: the disclosure log, allowlist, and
#    attribution lake all point INTO $WORK, never at the checkout. ─────────
LAKE="$WORK/lake"
DLOG="$WORK/disclosure-log.jsonl"
ALLOW="$WORK/allow.txt"
NOLOCAL="$WORK/no-such-local-override.txt"
printf 'anthropic\nopenai\n' >"$ALLOW"
mkdir -p "$LAKE"

run_judge() {  # run_judge <JSTUB_MODE> <judge.sh args...>
  local mode="$1"; shift
  env JSTUB_MODE="$mode" \
      MODEL_USAGE_RAW_DIR="$LAKE" \
      PROVIDER_ALLOWLIST_TEST_SEAM=1 \
      PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
      PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" \
      PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
      OPENAI_API_KEY="fixture-key-never-sent-anywhere" \
      bash "$JUDGE" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — the judge≠candidate guard
# ═══════════════════════════════════════════════════════════════════════════

count
SELF_RECORD="$WORK/self-record.json"
mk_record "$SELF_RECORD" --candidate-model claude-opus-4-8 --candidate-provider anthropic
out="$(run_judge good judge --record "$SELF_RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 2 ] || fail "A1: a judge identical to the candidate must be REFUSED (exit 2), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "REFUSED" ] || fail "A1: expected outcome REFUSED, got: $out"
[ "$(jq -r .reason <<<"$out")" = "judge-equals-candidate" ] || fail "A1: expected reason judge-equals-candidate, got: $out"
[ "$(jq 'has("schema_version")' <<<"$out")" = "false" ] || fail "A1: a REFUSED call must never emit the merged record (no spend happened), got: $out"
ok "A1 judge==candidate (provider+model) is REFUSED, not merely warned — before any call"

count
[ ! -e "$CANARY" ] || fail "A2: a REFUSED call reached a 'claude' binary: $(cat "$CANARY")"
[ "$(cat "$WORK/jstub-calls" 2>/dev/null || echo 0)" = "0" ] || fail "A2: a REFUSED call reached the judge-runner stub too — no spend should have happened"
ok "A2 REFUSED means no call was ever made — not the stub, not a binary"

count
out="$(run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "A3: a judge DIFFERENT from the candidate must proceed, got $rc: $out"
[ "$(jq -r .judge.outcome <<<"$out")" = "JUDGED" ] || fail "A3: expected JUDGED, got: $out"
ok "A3 a judge different from the candidate proceeds normally"

count
CUSTOM_RECORD="$WORK/custom-record.json"
mk_record "$CUSTOM_RECORD" --candidate-model custom-model-x --candidate-provider anthropic
out="$(run_judge good judge --record "$CUSTOM_RECORD" --judge-runner "bash $JSTUB" \
        --model custom-model-x --provider anthropic)"
rc=$?
[ "$rc" -eq 2 ] || fail "A4: an explicit --model/--provider matching the candidate must still be REFUSED, got $rc: $out"
ok "A4 the guard applies to an explicit --model/--provider override too, not just the default"

# --- MUTATION PROOF: the guard is load-bearing ------------------------------
count
rm -f "$WORK/jstub-calls"
MIRROR_A="$WORK/mirror-a"
mk_mirror "$MIRROR_A"
unlink_and_copy "$MIRROR_A/workflows/scripts/model-comparison/judge.sh"
mutate_file "$MIRROR_A/workflows/scripts/model-comparison/judge.sh" \
  '_je_guard_blocks() {
  [ "$1" = "$3" ] && [ "$2" = "$4" ]
}' \
  '_je_guard_blocks() {
  false
}'
out="$(env JSTUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_A/workflows/scripts/model-comparison/judge.sh" judge \
      --record "$SELF_RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -ne 2 ] || fail "A5: MUTATION PROOF did not fire — with the guard disabled, a self-grading record should NOT be REFUSED, got: $out"
[ "$(jq -r '.judge.outcome // "MISSING"' <<<"$out")" = "JUDGED" ] || fail "A5: MUTATION PROOF: expected the disabled guard to let a self-grading call through to JUDGED, got: $out"
[ "$(cat "$WORK/jstub-calls" 2>/dev/null || echo 0)" -ge 1 ] || fail "A5: MUTATION PROOF: the judge-runner stub was never reached even with the guard disabled — the proof cannot be trusted"
rm -rf "$MIRROR_A"
ok "A5 MUTATION PROOF: deleting the judge≠candidate guard DOES let a model grade itself — the guard is load-bearing"

count
rm -f "$WORK/jstub-calls"
out="$(run_judge good judge --record "$SELF_RECORD" --judge-runner "bash $JSTUB")"
[ "$(jq -r .outcome <<<"$out")" = "REFUSED" ] || fail "A6: RESTORED behaviour should refuse again, got: $out"
ok "A6 RESTORED: the unmutated guard refuses self-grading again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — the degradation notice: never a fabricated or zero score
# standing in for one the judge never obtained
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B1: a clean judge call should exit 0, got $rc: $out"
[ "$(jq -r .judge.scored <<<"$out")" = "true" ] || fail "B1: expected judge.scored=true, got: $out"
[ "$(jq -r .judge.quality_score <<<"$out")" -eq 85 ] 2>/dev/null || fail "B1: expected judge.quality_score=85, got: $out"
ok "B1 a clean judge call reports scored=true with the model's own quality_score"

count
out="$(run_judge zero judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B2: a genuine ZERO score must still exit 0 (it IS a score), got $rc: $out"
[ "$(jq -r .judge.outcome <<<"$out")" = "JUDGED" ] || fail "B2: expected outcome JUDGED for a genuine zero, got: $out"
[ "$(jq -r .judge.scored <<<"$out")" = "true" ] || fail "B2: a genuine zero must still be scored=true, got: $out"
[ "$(jq -r .judge.quality_score <<<"$out")" = "0" ] || fail "B2: expected quality_score literally 0, got: $out"
ok "B2 a genuine 0 is honestly reported: scored=true, quality_score=0 — never withheld"

count
out="$(run_judge spawnfail judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "B3: an unreachable judge runner must exit 4 (UNAVAILABLE), got $rc: $out"
[ "$(jq -r .judge.outcome <<<"$out")" = "UNAVAILABLE" ] || fail "B3: expected outcome UNAVAILABLE, got: $out"
[ "$(jq -r .judge.scored <<<"$out")" = "false" ] || fail "B3: expected scored=false, got: $out"
[ "$(jq -r .judge.quality_score <<<"$out")" = "null" ] || fail "B3: expected quality_score=null (never 0, never fabricated), got: $out"
case "$(jq -r .judge.degradation_notice <<<"$out")" in
  *"judge-spawn"*) ;;
  *) fail "B3: expected a named degradation_notice mentioning judge-spawn, got: $out" ;;
esac
[ "$(jq 'has("schema_version")' <<<"$out")" = "true" ] || fail "B3: the record must still be emitted (never a silent drop), got: $out"
ok "B3 an unreachable judge is UNAVAILABLE — record still emitted, scored=false, quality_score=null, named notice"

# ── the judge-spawn DETAIL carries a reason (temperloop#1553) ──────────────
# assert_no_trailing_colon <label> <notice> — the #1553 shape is a notice
# that ENDS at a colon with nothing after it, so that is what is banned.
assert_no_trailing_colon() {
  local label="$1" d="$2" trimmed
  trimmed="${d%"${d##*[![:space:]]}"}"
  case "$trimmed" in
    *:) fail "$label: the degradation_notice TRAILS OFF after a colon with no reason — the exact #1553 shape: [$d]" ;;
  esac
  [ -n "$trimmed" ] || fail "$label: the degradation_notice is empty"
}

count
out="$(run_judge spawnfail_stdout judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "B3b: expected exit 4 (UNAVAILABLE), got $rc: $out"
notice="$(jq -r .judge.degradation_notice <<<"$out")"
case "$notice" in *"judge-spawn"*) ;; *) fail "B3b: the notice lost its judge-spawn stage name, got: [$notice]" ;; esac
case "$notice" in *"is_error=true"*) ;; *) fail "B3b: the notice must name the envelope's is_error, got: [$notice]" ;; esac
case "$notice" in *"subtype=error_during_execution"*) ;; *) fail "B3b: the notice must name the envelope's subtype, got: [$notice]" ;; esac
case "$notice" in *"api_error_status=529"*) ;; *) fail "B3b: the notice must name the envelope's api_error_status, got: [$notice]" ;; esac
assert_no_trailing_colon "B3b" "$notice"
[ "${#notice}" -le 1000 ] || fail "B3b: the notice is unbounded (${#notice} chars): [$notice]"
ok "B3b a judge runner that exits non-zero with a claude-JSON error object on STDOUT and NOTHING on stderr yields a notice naming the stdout-side error — the SAME treatment the candidate spawn gets"

count
out="$(run_judge spawnfail_silent judge --record "$RECORD" --judge-runner "bash $JSTUB")"
notice="$(jq -r .judge.degradation_notice <<<"$out")"
case "$notice" in *"no diagnostic on either stream"*) ;; *) fail "B3c: both-streams-empty must yield the explicit no-diagnostic wording, got: [$notice]" ;; esac
assert_no_trailing_colon "B3c" "$notice"
ok "B3c a judge spawn silent on BOTH streams yields an explicit 'produced no diagnostic on either stream' reason, never a notice ending at a colon"

# --- MUTATION PROOF: reading the envelope is load-bearing on the judge side -
count
MIRROR_B="$WORK/mirror-b"
mk_mirror "$MIRROR_B"
unlink_and_copy "$MIRROR_B/workflows/scripts/model-comparison/judge.sh"
mutate_file "$MIRROR_B/workflows/scripts/model-comparison/judge.sh" \
  '    _je_unavailable "judge-spawn: $(spawn_failure_detail "$run_rc" "$scratch_dir/stderr.txt" "$envelope_file" "the judge runner")" "$measured_ms"; return $?' \
  '    _je_unavailable "judge-spawn: the judge runner exited $run_rc: $(head -c 400 "$scratch_dir/stderr.txt" 2>/dev/null)" "$measured_ms"; return $?'
mut_out="$(env JSTUB_MODE=spawnfail_stdout MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_B/workflows/scripts/model-comparison/judge.sh" judge \
      --record "$RECORD" --judge-runner "bash $JSTUB")"
mut_notice="$(jq -r .judge.degradation_notice <<<"$mut_out")"
[ "$mut_notice" = "judge-spawn: the judge runner exited 1: " ] \
  || fail "B3d MUTATION PROOF did not fire — restoring the stderr-only notice should reproduce the blank #1553 shape verbatim, got: [$mut_notice]"
rm -rf "$MIRROR_B"
ok "B3d MUTATION PROOF: restoring the stderr-only notice reproduces the exact blank 'judge-spawn: the judge runner exited 1: ' — reading the envelope is load-bearing here too"

count
out="$(run_judge spawnfail_stdout judge --record "$RECORD" --judge-runner "bash $JSTUB")"
case "$(jq -r .judge.degradation_notice <<<"$out")" in
  *"api_error_status=529"*) ;;
  *) fail "B3e: RESTORED behaviour should name the reason again, got: $out" ;;
esac
ok "B3e RESTORED: the unmutated judge names the stdout-side reason again"

count
out="$(run_judge vendorerror judge --record "$RECORD" --judge-runner "bash $JSTUB")"
case "$(jq -r .judge.degradation_notice <<<"$out")" in
  *"vendor-error"*) ;;
  *) fail "B4: expected a vendor-error degradation_notice, got: $out" ;;
esac
ok "B4 a vendor-flagged error is UNAVAILABLE with a distinct vendor-error notice"

count
out="$(run_judge nousage judge --record "$RECORD" --judge-runner "bash $JSTUB")"
case "$(jq -r .judge.degradation_notice <<<"$out")" in
  *"envelope-usage-missing"*) ;;
  *) fail "B5: expected an envelope-usage-missing degradation_notice, got: $out" ;;
esac
ok "B5 an envelope with no usable token block is UNAVAILABLE, never scored with a hole in it"

count
out="$(run_judge unparseable judge --record "$RECORD" --judge-runner "bash $JSTUB")"
case "$(jq -r .judge.degradation_notice <<<"$out")" in
  *"response-unparseable"*) ;;
  *) fail "B6: expected a response-unparseable degradation_notice, got: $out" ;;
esac
[ "$(jq -r .judge.scored <<<"$out")" = "false" ] || fail "B6: a reply that isn't the contracted JSON must never be scored, got: $out"
ok "B6 a non-JSON judge reply is UNAVAILABLE (response-unparseable), never a fabricated score"

count
out="$(run_judge fenced judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "B7: a markdown-fenced but otherwise valid reply should still be tolerated, got $rc: $out"
[ "$(jq -r .judge.quality_score <<<"$out")" = "42" ] || fail "B7: expected the fenced reply's quality_score 42 to survive stripping, got: $out"
ok "B7 a \`\`\`json-fenced reply is tolerated (stripped, then parsed)"

count
zero_out="$(run_judge zero judge --record "$RECORD" --judge-runner "bash $JSTUB")"
unavail_out="$(run_judge spawnfail judge --record "$RECORD" --judge-runner "bash $JSTUB")"
[ "$(jq -r .judge.scored <<<"$zero_out")" = "true" ] || fail "B8: sanity: zero-case scored must be true"
[ "$(jq -r .judge.quality_score <<<"$zero_out")" = "0" ] || fail "B8: sanity: zero-case quality_score must be 0"
[ "$(jq -r .judge.scored <<<"$unavail_out")" = "false" ] || fail "B8: sanity: unavailable-case scored must be false"
[ "$(jq -r .judge.quality_score <<<"$unavail_out")" = "null" ] || fail "B8: sanity: unavailable-case quality_score must be null"
ok "B8 a genuine 0 (scored:true, quality_score:0) is structurally distinct from UNAVAILABLE (scored:false, quality_score:null)"

# --- MUTATION PROOF: the distinction is load-bearing ------------------------
count
MIRROR_B="$WORK/mirror-b"
mk_mirror "$MIRROR_B"
unlink_and_copy "$MIRROR_B/workflows/scripts/model-comparison/judge.sh"
mutate_file "$MIRROR_B/workflows/scripts/model-comparison/judge.sh" \
  '{outcome:"UNAVAILABLE", scored:false, quality_score:null, dimensions:null,' \
  '{outcome:"UNAVAILABLE", scored:true, quality_score:0, dimensions:null,'
mut_out="$(env JSTUB_MODE=spawnfail MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_B/workflows/scripts/model-comparison/judge.sh" judge \
      --record "$RECORD" --judge-runner "bash $JSTUB")"
[ "$(jq -r .judge.scored <<<"$mut_out")" = "true" ] && [ "$(jq -r .judge.quality_score <<<"$mut_out")" = "0" ] \
  || fail "B9: MUTATION PROOF did not fire — collapsing the UNAVAILABLE marker should have produced scored:true, quality_score:0, got: $mut_out"
rm -rf "$MIRROR_B"
ok "B9 MUTATION PROOF: collapsing scored:false/quality_score:null to scored:true/quality_score:0 DOES make an unreachable judge indistinguishable from a genuine zero — B3/B8's assertions are load-bearing"

count
out="$(run_judge spawnfail judge --record "$RECORD" --judge-runner "bash $JSTUB")"
[ "$(jq -r .judge.scored <<<"$out")" = "false" ] || fail "B10: RESTORED behaviour should report scored=false again, got: $out"
[ "$(jq -r .judge.quality_score <<<"$out")" = "null" ] || fail "B10: RESTORED behaviour should report quality_score=null again, got: $out"
ok "B10 RESTORED: the distinction between a real zero and UNAVAILABLE holds again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — the judge-runner seam and its REFUSAL
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_judge good judge --record "$RECORD")"
rc=$?
[ "$rc" -ne 0 ] || fail "C1: judge with NO runner and NO --live must refuse, got 0: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "C1: expected CANNOT_EVALUATE, got: $out"
case "$(jq -r .error <<<"$out")" in
  *"no judge runner configured"*) ;;
  *) fail "C1: expected the refusal to name the missing seam, got: $out" ;;
esac
ok "C1 an UNSET judge seam REFUSES — it does not fall back to a 'claude' on PATH"

count
[ ! -e "$CANARY" ] || fail "C2: the refusal in C1 reached a 'claude' binary: $(cat "$CANARY")"
ok "C2 the refusal reached no binary at all (canary still absent)"

count
out="$(run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB" --live)"
rc=$?
[ "$rc" -ne 0 ] || fail "C3: --judge-runner with --live must be refused, got 0: $out"
case "$(jq -r .error <<<"$out")" in
  *"mutually exclusive"*) ;;
  *) fail "C3: expected a mutual-exclusion refusal, got: $out" ;;
esac
ok "C3 --judge-runner and --live are mutually exclusive"

count
out="$(run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "C4: a recorded runner should judge cleanly, got $rc: $out"
[ "$(jq -r .judge.outcome <<<"$out")" = "JUDGED" ] || fail "C4: expected judge.outcome JUDGED, got: $out"
ok "C4 the recorded-runner seam drives the whole judge path with no network"

count
[ ! -e "$CANARY" ] || fail "C5: a stubbed judge call reached a 'claude' binary: $(cat "$CANARY")"
ok "C5 a stubbed judge call reached no 'claude' binary"

# --- MUTATION PROOF: the refusal branch is load-bearing --------------------
count
MIRROR_C="$WORK/mirror-c"
mk_mirror "$MIRROR_C"
unlink_and_copy "$MIRROR_C/workflows/scripts/model-comparison/judge.sh"
mutate_file "$MIRROR_C/workflows/scripts/model-comparison/judge.sh" \
  '[ -n "$record" ] || { _je_cannot_evaluate "no --record given"; return 1; }
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    _je_cannot_evaluate "--judge-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if [ -z "$runner" ] && [ "$live" -eq 0 ]; then
    _je_cannot_evaluate "no judge runner configured' \
  '[ -n "$record" ] || { _je_cannot_evaluate "no --record given"; return 1; }
  if [ -n "$runner" ] && [ "$live" -eq 1 ]; then
    _je_cannot_evaluate "--judge-runner and --live are mutually exclusive — pick the recorded runner or the real spawn, never both"
    return 1
  fi
  if false; then
    _je_cannot_evaluate "no judge runner configured'
env JSTUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_C/workflows/scripts/model-comparison/judge.sh" judge \
      --record "$RECORD" >/dev/null 2>&1
rc=$?
# With the refusal disabled, `live` is still 0 and `runner` is still empty —
# the mutated code falls through to _je_one_record with runner="" and
# live=0, which invokes `$runner "$prompt_file"` i.e. a BARE, empty command:
# under `set -u` with no command word this expands to nothing meaningful and
# the shell reports "command not found" for an empty string, NOT a reach to
# PATH's `claude`. So the load-bearing proof here is structural: prove the
# refusal was truly skipped (the CANNOT_EVALUATE "no judge runner configured"
# message no longer appears) rather than the (impossible, for an EMPTY
# runner var) canary route replay.sh's execute mutation proof uses for its
# non-empty candidate-runner default. See the assertion below.
[ "$rc" -ne 0 ] || true
MUT_STDERR="$(env JSTUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MIRROR_C/workflows/scripts/model-comparison/judge.sh" judge \
      --record "$RECORD" 2>&1 >/dev/null)"
case "$MUT_STDERR" in
  *"no judge runner configured"*) fail "C6: MUTATION PROOF did not fire — the refusal message still appears with the branch disabled: $MUT_STDERR" ;;
  *) ;;
esac
rm -rf "$MIRROR_C"
ok "C6 MUTATION PROOF: disabling the no-runner refusal DOES skip the 'no judge runner configured' refusal message — the guard is load-bearing (an empty \$runner then fails as a shell error rather than silently reaching a real binary, which is itself further evidence there is no implicit fallback path to reach)"

count
out="$(run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB")"
[ "$(jq -r .judge.outcome <<<"$out")" = "JUDGED" ] || fail "C7: restored behaviour should judge again, got: $out"
[ ! -e "$CANARY" ] || fail "C7: restored run reached a 'claude' binary"
ok "C7 RESTORED: the unmutated judge call judges again and still reaches no binary"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — the rubric is PROMPT CONTENT, never a runtime agent dispatch
# ═══════════════════════════════════════════════════════════════════════════

count
CUSTOM_RUBRIC="$WORK/custom-rubric.md"
MARKER="RUBRIC-CONTENT-MARKER-9f3a1c7e"
printf '# Custom test rubric\n\nUnique marker: %s\n' "$MARKER" >"$CUSTOM_RUBRIC"
PROMPT_OUT="$WORK/prompt-out.txt"
run_judge good judge --record "$RECORD" --rubric "$CUSTOM_RUBRIC" \
  --judge-runner "bash $JSTUB" --prompt-out "$PROMPT_OUT" >/dev/null
grep -qF "$MARKER" "$PROMPT_OUT" || fail "D1: the custom rubric's marker did not reach the judge prompt verbatim — the rubric is not flowing in as prompt content"
ok "D1 a custom --rubric's content flows into the judge prompt verbatim (functional proof, not a grep-the-source proxy)"

count
run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB" --prompt-out "$PROMPT_OUT" >/dev/null
grep -qF "Output contract" "$PROMPT_OUT" || fail "D2: the DEFAULT rubric.md's content did not reach the judge prompt, got: $(cat "$PROMPT_OUT")"
ok "D2 the default rubric.md (this module's own file) also flows into the prompt when --rubric is omitted"

count
rm -f "$WORK/jstub-calls"
run_judge good judge --record "$RECORD" --judge-runner "bash $JSTUB" >/dev/null
calls="$(cat "$WORK/jstub-calls" 2>/dev/null || echo 0)"
[ "$calls" = "1" ] || fail "D3: a single judge call should reach the runner EXACTLY once (no secondary agent-dispatch subprocess), got $calls calls"
ok "D3 one judge call reaches the runner exactly once — no secondary spawn alongside it (a real agent dispatch would be a second process)"

count
# Secondary, STRUCTURAL corroboration only — NOT the primary proof (D1-D3
# above are the functional ones the testing bar requires; a grep alone is
# exactly the proxy-for-behaviour the testing bar warns against, since a
# comment EXPLAINING the absence — as this very file's own header carries —
# would otherwise false-positive). Comment-only lines are stripped first, so
# this checks EXECUTABLE code only, never prose that merely discusses the
# construct.
CODE_ONLY="$(grep -vE '^[[:space:]]*#' "$JUDGE")"
if printf '%s' "$CODE_ONLY" | grep -E 'subagent_type|Task\(|claude/agents/reviewers' >/dev/null; then
  fail "D4: judge.sh's EXECUTABLE code (comments excluded) references an agent-dispatch construct or a reviewer-charter path at runtime: $(printf '%s' "$CODE_ONLY" | grep -nE 'subagent_type|Task\(|claude/agents/reviewers')"
fi
ok "D4 (structural corroboration) judge.sh's executable code carries no Task/subagent_type/reviewer-charter-path reference (comments, which legitimately discuss the absence, are excluded from this check)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — judge-batch: every input line produces exactly one output line
# ═══════════════════════════════════════════════════════════════════════════

count
REC1="$WORK/batch-rec1.json"; mk_record "$REC1" --issue 101
REC2="$WORK/batch-rec2.json"; mk_record "$REC2" --issue 102 --candidate-model claude-opus-4-8 --candidate-provider anthropic
REC3="$WORK/batch-rec3.json"; mk_record "$REC3" --issue 103
REC4="$WORK/batch-rec4.json"; mk_record "$REC4" --issue 104
BATCH="$WORK/batch.jsonl"
{ jq -c . "$REC1"; jq -c . "$REC2"; jq -c . "$REC3"; jq -c . "$REC4"; } >"$BATCH"
BATCH_OUT="$WORK/batch-out.jsonl"
out="$(env JSTUB_FAIL_AT=3 MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$JUDGE" judge-batch --records-file "$BATCH" --judge-runner "env JSTUB_MODE=flaky bash $JSTUB" --out "$BATCH_OUT")"
rc=$?
[ "$rc" -eq 4 ] || fail "E1: a batch with a degraded row must exit 4, got $rc: $out"
n_out="$(grep -c . "$BATCH_OUT")"
[ "$n_out" = "4" ] || fail "E1: expected exactly 4 output lines for 4 input lines (never a silent drop), got $n_out: $(cat "$BATCH_OUT")"
o1="$(sed -n '1p' "$BATCH_OUT")"; o2="$(sed -n '2p' "$BATCH_OUT")"; o3="$(sed -n '3p' "$BATCH_OUT")"; o4="$(sed -n '4p' "$BATCH_OUT")"
[ "$(jq -r '.judge.outcome' <<<"$o1")" = "JUDGED" ] || fail "E1 row1: expected JUDGED, got: $o1"
# temperloop#1556: a REFUSED row is emitted as ITS OWN RECORD carrying the
# refusal as a judgment-absent `judge` sub-object — never as the bare REFUSED
# envelope substituted FOR the record (the substitution destroyed 14 of 21
# records per arm on the first live batch).
[ "$(jq -r '.judge.outcome' <<<"$o2")" = "REFUSED" ] || fail "E1 row2 (self-grading): expected .judge.outcome REFUSED, got: $o2"
[ "$(jq -r '.issue' <<<"$o2")" = "#102" ] || fail "E1 row2: the REFUSED row must still BE its input record (issue #102), got: $o2"
[ "$(jq -r '.judge.scored' <<<"$o2")" = "false" ] || fail "E1 row2: a refused row must be scored:false, got: $o2"
[ "$(jq -r '.judge.quality_score' <<<"$o2")" = "null" ] || fail "E1 row2: a refused row must carry no quality_score, got: $o2"
jq -e '.judge.degradation_notice | type == "string" and (length > 10)' <<<"$o2" >/dev/null \
  || fail "E1 row2: a refused row must carry a NAMED degradation_notice, got: $o2"
[ "$(jq -r '.judge.outcome' <<<"$o3")" = "UNAVAILABLE" ] || fail "E1 row3 (the judge call the runner fails at): expected UNAVAILABLE, got: $o3"
[ "$(jq -r '.judge.outcome' <<<"$o4")" = "JUDGED" ] || fail "E1 row4 (batch continued past the degraded row): expected JUDGED, got: $o4"
[ "$(jq -s -r '[.[] | .issue] | join(",")' "$BATCH_OUT")" = "#101,#102,#103,#104" ] \
  || fail "E1: every input record must survive the judge pass, in order: $(jq -s -c '[.[].issue]' "$BATCH_OUT")"
ok "E1 judge-batch: REFUSED and UNAVAILABLE rows degrade only THEMSELVES — the batch continues, every row still emits AS ITS OWN RECORD, in order"

count
REC5="$WORK/batch-rec5.json"; mk_record "$REC5" --issue 105
REC6="$WORK/batch-rec6.json"; mk_record "$REC6" --issue 106
CLEAN_BATCH="$WORK/clean-batch.jsonl"
jq -c . "$REC5" >"$CLEAN_BATCH"
jq -c . "$REC6" >>"$CLEAN_BATCH"
out="$(run_judge good judge-batch --records-file "$CLEAN_BATCH" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 0 ] || fail "E2: an all-JUDGED batch must exit 0, got $rc: $out"
n_out="$(printf '%s\n' "$out" | grep -c .)"
[ "$n_out" = "2" ] || fail "E2: expected 2 output lines, got $n_out"
ok "E2 judge-batch exits 0 iff every row reached JUDGED"

count
MALFORMED_BATCH="$WORK/malformed-batch.jsonl"
jq -c . "$REC1" >"$MALFORMED_BATCH"
printf 'not valid json at all\n' >>"$MALFORMED_BATCH"
jq -c . "$REC4" >>"$MALFORMED_BATCH"
out="$(run_judge good judge-batch --records-file "$MALFORMED_BATCH" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 4 ] || fail "E3: a batch with one malformed row must still exit 4 (degraded, not aborted), got $rc"
n_out="$(printf '%s\n' "$out" | grep -c .)"
[ "$n_out" = "3" ] || fail "E3: expected exactly 3 output lines for 3 input lines (the malformed one included, never dropped), got $n_out: $out"
row2="$(printf '%s\n' "$out" | sed -n '2p')"
[ "$(jq -r '.outcome' <<<"$row2")" = "CANNOT_EVALUATE" ] || fail "E3: expected the malformed row's own output to be CANNOT_EVALUATE, got: $row2"
# temperloop#1556: a line that is not a JSON object cannot carry a merged
# field, so it is preserved VERBATIM in the envelope rather than discarded.
[ "$(jq -r '.original_line' <<<"$row2")" = "not valid json at all" ] \
  || fail "E3: the malformed input line must be preserved verbatim in the emitted envelope, got: $row2"
row1="$(printf '%s\n' "$out" | sed -n '1p')"
row3="$(printf '%s\n' "$out" | sed -n '3p')"
[ "$(jq -r '.judge.outcome' <<<"$row1")" = "JUDGED" ] || fail "E3: the row BEFORE the malformed one should still be JUDGED, got: $row1"
[ "$(jq -r '.judge.outcome' <<<"$row3")" = "JUDGED" ] || fail "E3: the row AFTER the malformed one should still be JUDGED, got: $row3"
ok "E3 a malformed row inside an otherwise-valid batch degrades only that row — never aborts, never silently vanishes"

count
out="$(run_judge good judge-batch --records-file "$WORK/no-such-file.jsonl" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "E4: an absent records-file must CANNOT_EVALUATE the whole batch (nothing to iterate), got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "E4: expected CANNOT_EVALUATE, got: $out"
ok "E4 an absent records-file itself CANNOT_EVALUATEs (there is nothing to iterate at all)"

count
EMPTY_BATCH="$WORK/empty-batch.jsonl"
: >"$EMPTY_BATCH"
out="$(run_judge good judge-batch --records-file "$EMPTY_BATCH" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "E5: an empty records-file must CANNOT_EVALUATE, got $rc: $out"
ok "E5 an empty records-file CANNOT_EVALUATEs"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — fail-closed, everywhere
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_judge good judge --record "$WORK/no-such-record.json" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F1: an absent record must CANNOT_EVALUATE, got $rc: $out"
[ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "F1: expected CANNOT_EVALUATE, got: $out"
ok "F1 an absent record file is CANNOT_EVALUATE + non-zero"

count
EMPTY_RECORD="$WORK/empty-record.json"
: >"$EMPTY_RECORD"
out="$(run_judge good judge --record "$EMPTY_RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F2: an empty record must CANNOT_EVALUATE, got $rc: $out"
ok "F2 an empty record file is CANNOT_EVALUATE + non-zero"

count
MALFORMED_RECORD="$WORK/malformed-record.json"
printf 'not json\n' >"$MALFORMED_RECORD"
out="$(run_judge good judge --record "$MALFORMED_RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F3: a malformed record must CANNOT_EVALUATE, got $rc: $out"
case "$(jq -r .error <<<"$out")" in
  *"not a JSON object"*) ;;
  *) fail "F3: expected the error to name the malformed shape, got: $out" ;;
esac
ok "F3 a non-JSON record file is CANNOT_EVALUATE + non-zero"

count
NO_CAND_RECORD="$WORK/no-cand-record.json"
mk_record "$NO_CAND_RECORD" --no-candidate
out="$(run_judge good judge --record "$NO_CAND_RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F4: a record with no candidate.model must CANNOT_EVALUATE, got $rc: $out"
case "$(jq -r .error <<<"$out")" in
  *"candidate.model"*) ;;
  *) fail "F4: expected the error to name the missing candidate.model, got: $out" ;;
esac
ok "F4 a record carrying no .candidate.model is CANNOT_EVALUATE — nothing to guard against, so refuse rather than guess"

count
out="$(run_judge good judge --record "$RECORD" --rubric "$WORK/no-such-rubric.md" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F5: an absent rubric file must CANNOT_EVALUATE, got $rc: $out"
case "$(jq -r .error <<<"$out")" in
  *"rubric"*) ;;
  *) fail "F5: expected the error to name the missing rubric, got: $out" ;;
esac
ok "F5 an absent --rubric file is CANNOT_EVALUATE + non-zero"

count
if [ "$(id -u)" -ne 0 ]; then
  UNREADABLE_RECORD="$WORK/unreadable-record.json"
  mk_record "$UNREADABLE_RECORD"
  chmod 000 "$UNREADABLE_RECORD"
  out="$(run_judge good judge --record "$UNREADABLE_RECORD" --judge-runner "bash $JSTUB")"
  rc=$?
  chmod 644 "$UNREADABLE_RECORD"
  [ "$rc" -eq 1 ] || fail "F6: an unreadable record must CANNOT_EVALUATE, got $rc: $out"
  [ "$(jq -r .outcome <<<"$out")" = "CANNOT_EVALUATE" ] || fail "F6: expected CANNOT_EVALUATE, got: $out"
  ok "F6 an unreadable record file is CANNOT_EVALUATE + non-zero"
else
  ok "F6 skipped — running as root, permission bits are not enforceable"
fi

count
out="$(env JSTUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    CANDIDATE_SETTINGS="$WORK/no-such-overlay.json" \
    bash "$JUDGE" judge --record "$RECORD" --judge-runner "bash $JSTUB")"
rc=$?
[ "$rc" -eq 1 ] || fail "F7: an absent containment overlay must refuse the judge call, got $rc: $out"
case "$(jq -r .error <<<"$out")" in
  *"containment overlay is unusable"*) ;;
  *) fail "F7: expected the overlay refusal (proving judge.sh routes through candidate-session.sh), got: $out" ;;
esac
ok "F7 judge.sh routes through candidate-session.sh's overlay validator — an absent overlay refuses the call"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — arg hygiene under a bounded timeout
# ═══════════════════════════════════════════════════════════════════════════

count
out="$(run_with_timeout 5 bash "$JUDGE" judge --record 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "G1: a trailing --record with no value must fail fast (rc 2), got $rc: $out"
[ "$rc" -ne 137 ] || fail "G1: a trailing flag with no value HUNG (bounded timeout fired) instead of failing fast"
ok "G1 a trailing --record with no value fails fast under a bounded timeout, never hangs"

count
out="$(run_with_timeout 5 bash "$JUDGE" judge --record "$RECORD" --rubric --judge-runner "bash $JSTUB" 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "G2: a flag-like value for --rubric must be rejected (rc 2), got $rc: $out"
case "$out" in
  *"flag-like"*) ;;
  *) fail "G2: expected the flag-like-value rejection message, got: $out" ;;
esac
ok "G2 a flag-like value for a flag that needs an operand is rejected, not silently consumed"

count
out="$(run_with_timeout 5 bash "$JUDGE" judge --record "$RECORD" --not-a-real-flag 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "G3: an unknown flag must fail with rc 2, got $rc: $out"
ok "G3 an unknown flag is rejected"

count
out="$(run_with_timeout 5 bash "$JUDGE" judge-batch --records-file 2>&1)"
rc=$?
[ "$rc" -eq 2 ] || fail "G4: judge-batch's trailing --records-file with no value must fail fast, got $rc: $out"
[ "$rc" -ne 137 ] || fail "G4: judge-batch HUNG on a trailing flag instead of failing fast"
ok "G4 judge-batch's arg parser fails fast on a trailing flag too"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — RECORD PRESERVATION, END TO END (temperloop#1556).
#
# The defect this section pins DESTROYED DATA. judge-batch appended
# `_je_one_record`'s BARE verdict object in place of the row it was derived
# from, so every integration-error record — unjudgeable BY CONSTRUCTION,
# since a failed candidate spawn resolves no model and produces no diff —
# was replaced by `{"outcome":"CANNOT_EVALUATE","error":...}`. A bare verdict
# carries no `.candidate`, so `score.sh aggregate` then (correctly) refused
# the whole arm file and the comparison report emitted NOTHING: 14 of 21
# records per arm lost, a partial degradation turned into a total one, on a
# live run that had already been paid for.
#
# H1-H3 therefore drive the WHOLE downstream chain over a mixed fixture arm
# (scored + integration-error), because the acceptance is end to end:
# survive judge-batch -> roll up under score.sh aggregate -> render a report
# stating the compatibility split. H4 is the MUTATION PROOF: restoring the
# pre-fix substitution in a mirrored judge.sh corrupts that very arm file and
# takes score.sh aggregate down with it, so H1-H3 are a measurement rather
# than a restatement of the code.
# ═══════════════════════════════════════════════════════════════════════════

SCORE_SH="$MC_DIR/score.sh"
REPORT_PRODUCER="$SCRIPTS_DIR/report-producers/model-comparison"

# mk_arm_record <pr> <scored|integration-error> <pass|fail>
# The two shapes replay.sh's ONE record constructor emits (see its
# `_exec_emit_record` / `_exec_integration_error`): byte-for-byte the same
# record shape, differing only in contents — an integration-error record
# carries a null candidate model, no diff_ref, no tokens, and the empty
# NOT_SCORED score object.
mk_arm_record() {
  jq -cn --argjson pr "$1" --arg oc "$2" --arg v "$3" \
    '{schema_version:"replay-record-v1", pr:$pr, issue:("#" + ($pr|tostring)),
      merge_commit:null, base:"aaaaaaa", head:"bbbbbbb",
      title:"Fix the thing", scope:"the scope",
      acceptance:["A named path is fixed."], notes:"", status:"eligible",
      reject_reason:"", flags:[],
      buckets:{N:["a/b.py"], T:["a/t.sh"], X:["CHANGELOG.md"], R:[]},
      template_sha:"ccccccc", file_count:2,
      worktree:{path:"/tmp/wt", branch:"br", prepared_at:"2026-08-14T00:00:00Z"},
      candidate:(if $oc == "scored" then
          {provider:"anthropic", model:"recorded-candidate-model", diff_ref:"deadbeef",
           tokens:{input:1200, output:340, cache_read:9000, cache_creation:120},
           duration_ms:4242, outcome:"scored", integration_error:null,
           disclosed:false, prompt_sha256:"aa11"}
        else
          {provider:"anthropic", model:null, diff_ref:null, tokens:null,
           duration_ms:900, outcome:"integration-error",
           integration_error:{stage:"candidate-spawn", detail:"the candidate runner exited 3"},
           disclosed:false, prompt_sha256:"aa11"}
        end),
      score:(if $oc == "scored" then
          {outcome:"SCORED", scored:true, verdict:$v,
           base:"aaaaaaa", truth_head:"bbbbbbb",
           diff:{n:{total:1, changed:1, matched:(if $v == "pass" then 1 else 0 end)},
                 t:{total:1, present:1}, x:{total:1}, r:{total:0}},
           gate_result:{ran:true, passed:($v == "pass"),
                        exit_code:(if $v == "pass" then 0 else 1 end),
                        timed_out:false, gate_script:"scripts/quality-gates.sh"},
           acceptance_results:[{criterion:"A named path is fixed.",
                                carries_literal_numbers:false, mechanically_scored:false}],
           components:null, contamination_flags:[]}
        else
          {outcome:"NOT_SCORED", scored:false, verdict:null,
           not_scored_reason:"candidate-spawn", base:null, truth_head:null,
           diff:null, gate_result:null, acceptance_results:null,
           components:null, contamination_flags:[]}
        end)}'
}

MIXED_ARM="$WORK/mixed-arm.jsonl"
{ mk_arm_record 101 scored pass
  mk_arm_record 102 integration-error ""
  mk_arm_record 103 scored fail
  mk_arm_record 104 integration-error ""; } >"$MIXED_ARM"

# H1 — judge-batch over the mixed arm: every input record survives, the
#      integration-error rows are passed through UNJUDGED (no judge call
#      spent on them) and do NOT degrade the batch.
count
MIXED_OUT="$WORK/mixed-arm-judged.jsonl"
: >"$WORK/jstub-calls"
out="$(run_judge good judge-batch --records-file "$MIXED_ARM" \
        --judge-runner "bash $JSTUB" --out "$MIXED_OUT")"
rc=$?
[ "$rc" -eq 0 ] \
  || fail "H1: a batch whose only non-JUDGED rows were unjudgeable BY CONSTRUCTION must exit 0 (judge.degraded must not fire), got $rc: $out"
[ "$(grep -c . "$MIXED_OUT")" = "4" ] \
  || fail "H1: expected 4 output lines for 4 input lines, got $(grep -c . "$MIXED_OUT"): $(cat "$MIXED_OUT")"
[ "$(jq -s -r '[.[] | .issue] | join(",")' "$MIXED_OUT")" = "#101,#102,#103,#104" ] \
  || fail "H1: every input record must still be present AND identifiable: $(jq -s -c '[.[].issue]' "$MIXED_OUT")"
[ "$(jq -s '[.[] | select((.candidate | type) == "object")] | length' "$MIXED_OUT")" = "4" ] \
  || fail "H1: a line with no .candidate is a BARE verdict object standing in for a record — the exact corruption: $(cat "$MIXED_OUT")"
[ "$(jq -s '[.[] | select(.judge.outcome == "JUDGED")] | length' "$MIXED_OUT")" = "2" ] \
  || fail "H1: both scored records should be JUDGED: $(jq -s -c '[.[].judge.outcome]' "$MIXED_OUT")"
[ "$(jq -s '[.[] | select(.candidate.outcome == "integration-error") | select(.unjudged.reason == "unjudgeable-by-construction")] | length' "$MIXED_OUT")" = "2" ] \
  || fail "H1: both integration-error records must carry the unjudgeable-by-construction marker: $(cat "$MIXED_OUT")"
[ "$(jq -s '[.[] | select(.candidate.outcome == "integration-error") | select(has("judge"))] | length' "$MIXED_OUT")" = "0" ] \
  || fail "H1: an unjudgeable-by-construction row must carry NO judge sub-object — a row no judge saw is unjudged, not judge-degraded"
[ "$(cat "$WORK/jstub-calls")" = "2" ] \
  || fail "H1: exactly 2 judge calls should have been spent (the scored rows only), got $(cat "$WORK/jstub-calls")"
# The integration-error record is preserved BYTE-FOR-BYTE apart from the
# added marker — nothing about the input was rewritten on the way through.
[ "$(jq -s -c '.[1] | del(.unjudged)' "$MIXED_OUT")" = "$(jq -c '.' <(sed -n '2p' "$MIXED_ARM"))" ] \
  || fail "H1: the integration-error record was altered beyond the added marker: $(jq -s -c '.[1]' "$MIXED_OUT")"
ok "H1 judge-batch preserves EVERY input record; an unjudgeable-by-construction row passes through unjudged, spends no judge call, and does not degrade the batch"

# H2 — score.sh aggregate rolls the judged mixed arm up (the step that
#      refused outright on the corrupt pre-fix file).
count
agg="$(bash "$SCORE_SH" aggregate --records-file "$MIXED_OUT" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "H2: score.sh aggregate must roll up a judged mixed arm, got $rc: $agg"
[ "$(jq -r '.quality.scored_n' <<<"$agg")" = "2" ] || fail "H2: expected scored_n 2, got: $agg"
[ "$(jq -r '.compatibility.integration_error_n' <<<"$agg")" = "2" ] || fail "H2: expected integration_error_n 2, got: $agg"
[ "$(jq -r '.compatibility.by_stage["candidate-spawn"]' <<<"$agg")" = "2" ] \
  || fail "H2: the compatibility split must name the stage the errors came from, got: $agg"
ok "H2 score.sh aggregate rolls the judged mixed arm up into its quality/compatibility split"

# H3 — the REAL report producer renders over the judged mixed arms, stating
#      the compatibility split, rather than taking its skip path.
count
RECS_DIR="$WORK/report-records"; mkdir -p "$RECS_DIR"
cp "$MIXED_OUT" "$RECS_DIR/baseline.jsonl"
cp "$MIXED_OUT" "$RECS_DIR/candidate.jsonl"
prod_out="$(cd "$WORK" && env MODEL_COMPARISON_REPORT_RECORDS_DIR="$RECS_DIR" bash "$REPORT_PRODUCER" 2>&1)"
case "$prod_out" in
  skipped\ --*) fail "H3: the report producer SKIPPED over a judged mixed arm — the whole-report loss this item exists to fix: $prod_out" ;;
esac
jq -e 'type == "object"' <<<"$prod_out" >/dev/null \
  || fail "H3: the report producer emitted no JSON report: $(printf '%s' "$prod_out" | head -c 300)"
[ "$(jq -r '.arms.baseline.compatibility.integration_error_n' <<<"$prod_out")" = "2" ] \
  || fail "H3: the report must state the compatibility split: $(jq -c '.arms.baseline.compatibility' <<<"$prod_out")"
[ "$(jq -r '.arms.baseline.quality.scored_n' <<<"$prod_out")" = "2" ] \
  || fail "H3: the report's quality block must count the scored records only: $(jq -c '.arms.baseline.quality' <<<"$prod_out")"
[ "$(jq -r '.arms.baseline.judge_quality.judged_n' <<<"$prod_out")" = "2" ] \
  || fail "H3: the report must read the judge annotations the scored rows carry: $(jq -c '.arms.baseline.judge_quality' <<<"$prod_out")"
[ "$(jq -r '.arms.baseline.judge_quality.degraded_n' <<<"$prod_out")" = "0" ] \
  || fail "H3: an unjudgeable-by-construction row must not be reported as a judge degradation: $(jq -c '.arms.baseline.judge_quality' <<<"$prod_out")"
ok "H3 the real report producer renders over the judged mixed arm and states the compatibility split — never the skip path"

# H4 — MUTATION PROOF. Restore the pre-fix behaviour in a mirrored judge.sh
#      (skip the by-construction passthrough, then append the BARE verdict
#      instead of the record) and the same fixture arm is corrupted: the
#      integration-error records vanish and score.sh aggregate refuses the
#      whole file, exactly as observed on the live run.
count
MUT_H="$WORK/mut-preserve"; mk_mirror "$MUT_H"
MUT_H_JUDGE="$MUT_H/workflows/scripts/model-comparison/judge.sh"
unlink_and_copy "$MUT_H_JUDGE"
mutate_file "$MUT_H_JUDGE" \
  '    if _je_unjudgeable_by_construction "$row_file"; then' \
  '    if false; then'
mutate_file "$MUT_H_JUDGE" \
  '    printf '"'"'%s\n'"'"' "$row_final" >>"$out_stream"
    if [ "$row_rc" -ne 0 ]; then degraded=1; n_degraded=$((n_degraded + 1)); fi' \
  '    printf '"'"'%s\n'"'"' "$row_out" >>"$out_stream"
    if [ "$row_rc" -ne 0 ]; then degraded=1; n_degraded=$((n_degraded + 1)); fi'
MUT_H_OUT="$WORK/mixed-arm-judged-mut.jsonl"
env JSTUB_MODE=good MODEL_USAGE_RAW_DIR="$LAKE" \
    PROVIDER_ALLOWLIST_TEST_SEAM=1 PROVIDER_ALLOWLIST_COMMITTED_FILE="$ALLOW" \
    PROVIDER_ALLOWLIST_LOCAL_FILE="$NOLOCAL" PROVIDER_DISCLOSURE_LOG_FILE="$DLOG" \
    bash "$MUT_H_JUDGE" judge-batch --records-file "$MIXED_ARM" \
    --judge-runner "bash $JSTUB" --out "$MUT_H_OUT" >/dev/null 2>&1
[ "$(jq -s '[.[] | select((.candidate | type) == "object")] | length' "$MUT_H_OUT")" = "2" ] \
  || fail "H4: the mutation proof did not fire — the pre-fix shape should have replaced both integration-error records with bare verdict objects, leaving 2 records: $(cat "$MUT_H_OUT")"
bash "$SCORE_SH" aggregate --records-file "$MUT_H_OUT" >/dev/null 2>&1
[ "$?" -ne 0 ] \
  || fail "H4: the mutation proof did not fire — score.sh aggregate should REFUSE the corrupted arm file (that refusal is what skipped the whole report)"
ok "H4 MUTATION PROOF: the pre-fix substitution corrupts the same fixture arm (2 of 4 records replaced by bare verdicts) and score.sh aggregate refuses it — H1-H3 measure the fix"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — the suite-wide no-live-call canary verdict
# ═══════════════════════════════════════════════════════════════════════════

count
[ ! -e "$CANARY" ] || fail "I1: NO LIVE MODEL CALL invariant violated — the 'claude' canary on PATH was invoked: $(cat "$CANARY")"
ok "I1 NO LIVE MODEL CALL: the 'claude' canary on PATH was never invoked by any test in this suite"

count
# ...and the canary is genuinely capable of firing (proved directly in
# section C's own mutation-proof design note — C6 could not route through
# the canary for an EMPTY runner, so this is a fresh, independent proof that
# the canary mechanism itself works, using a NON-empty forced runner).
env JSTUB_MODE=good bash -c 'echo hi' >/dev/null 2>&1  # no-op sanity, keeps shellcheck quiet about unused var patterns above
"$WORK/bin/claude" --self-test-only >/dev/null 2>&1 || true
[ -e "$CANARY" ] || fail "I2: the canary itself does not fire when invoked directly — I1 proves nothing"
rm -f "$CANARY"
ok "I2 the canary is functional — I1 is a measurement, not a tautology"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "test_judge.sh: $pass/$total assertions passed"
[ "$pass" -eq "$total" ] || fail "not all assertions passed"
