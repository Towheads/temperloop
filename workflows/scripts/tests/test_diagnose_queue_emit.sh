#!/usr/bin/env bash
#
# test_diagnose_queue_emit.sh — tests for workflows/scripts/emit-diagnose-queue.sh
# and workflows/scripts/validate-diagnose-queue-emit.sh (temperloop#1192,
# "give diagnose-queue a durable lake stream via its own emit sibling").
#
# gate.sh's `cmd_diagnose_queue` computes a merge-queue verdict that /build and
# /fix branch merge decisions on — until this stream existed, that verdict was
# computed and then discarded, with no durable record of which verdicts fire
# in practice. This test covers:
#
#   A. emit-diagnose-queue.sh's own record shape, arg validation, and the
#      WARN-don't-drop infrastructure arm (bad args, invalid outcome, a
#      malformed --detail-json).
#   B. cmd_diagnose_queue routes EVERY verdict through the emit — a fixture
#      per outcome in the CURRENT full verdict set (QUEUED, MERGED,
#      MERGE_GROUP_FAILED, MERGE_GROUP_INFRA, DEQUEUED, QUEUE_STALLED, ERROR)
#      — and does so as a SUBPROCESS call, so it fires from cmd_poll's own
#      internal TIMEOUT-path probe as well as a standalone
#      cmd_diagnose_queue call (the two call sites #1192 requires coverage
#      on).
#   C. validate-diagnose-queue-emit.sh (the presence-lint) passes on the real
#      tree and goes red on each of: the emit script disappearing, a verdict
#      losing its _dq_finish wiring, and a bare die() reappearing.
#   D. the canonical sink spec (meta/data/raw/README.md) documents the
#      stream, and the emit script's header points back at it.
#
# Deterministic, zero network: gate.sh's `_gate_gh` / `_gate_now` fixture
# seams (the same ones workflows/scripts/build/tests/test_gate.sh uses) stand
# in for gh and the wall clock; every lake write lands under a throwaway
# tmpdir via DIAGNOSE_QUEUE_RAW_DIR, never the real repo's meta/data/raw/.

set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -P "$HERE/../../.." && pwd)"
EMIT="$REPO/workflows/scripts/emit-diagnose-queue.sh"
LINT="$REPO/workflows/scripts/validate-diagnose-queue-emit.sh"
GATE="$REPO/workflows/scripts/build/gate.sh"
README="$REPO/meta/data/raw/README.md"

[ -f "$EMIT" ] || { echo "FATAL: emit-diagnose-queue.sh not found at $EMIT" >&2; exit 1; }
[ -f "$LINT" ] || { echo "FATAL: validate-diagnose-queue-emit.sh not found at $LINT" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FATAL: gate.sh not found at $GATE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/diagnose-queue-emit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s: %s\n' "$1" "$2"; }
check_eq() { # <desc> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}
check() { # <desc> <cmd...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d" "command failed: $*"; fi
}

# ============================================================================
# A. emit-diagnose-queue.sh direct behavior
# ============================================================================
echo "── A. emit-diagnose-queue.sh: record shape + arg validation ──"

lake_lines() { cat "$TMP/$1"/diagnose-queue-*.jsonl 2>/dev/null | wc -l | tr -d ' '; }

emit() { # <lake-subdir> <args...> → EMIT_OUT / EMIT_ERR / EMIT_RC
  local sub="$1"; shift
  local dir="$TMP/$sub"
  mkdir -p "$dir"
  EMIT_OUT="$(DIAGNOSE_QUEUE_RAW_DIR="$dir" CLAUDE_CODE_SESSION_ID=sess-1 \
    bash "$EMIT" "$@" 2>"$TMP/err.txt")"
  EMIT_RC=$?
  EMIT_ERR="$(cat "$TMP/err.txt")"
}

emit a1 --repo acme/widgets --pr 42 --outcome QUEUED --detail-json '{"queueState":"ENQUEUED"}'
check_eq "exit 0 on a valid QUEUED record" "0" "$EMIT_RC"
check_eq "outcome carries verbatim" "QUEUED" "$(printf '%s' "$EMIT_OUT" | jq -r '.outcome')"
check_eq "pr carries as an integer" "42" "$(printf '%s' "$EMIT_OUT" | jq -r '.pr')"
check_eq "repo carries verbatim" "acme/widgets" "$(printf '%s' "$EMIT_OUT" | jq -r '.repo')"
check_eq "detail carries the caller's JSON verbatim" "ENQUEUED" "$(printf '%s' "$EMIT_OUT" | jq -r '.detail.queueState')"
check_eq "schema_version is \"1\"" "1" "$(printf '%s' "$EMIT_OUT" | jq -r '.schema_version')"
check_eq "session_id carries the raw, untruncated value" "sess-1" "$(printf '%s' "$EMIT_OUT" | jq -r '.session_id')"
check_eq "one line appended to the lake" "1" "$(lake_lines a1)"

echo "── every outcome in the closed set is accepted ──"
for o in QUEUED MERGED MERGE_GROUP_FAILED MERGE_GROUP_INFRA DEQUEUED QUEUE_STALLED ERROR; do
  emit "a2-$o" --repo acme/widgets --pr 1 --outcome "$o"
  check_eq "outcome=$o accepted (exit 0)" "0" "$EMIT_RC"
  check_eq "outcome=$o carried verbatim" "$o" "$(printf '%s' "$EMIT_OUT" | jq -r '.outcome')"
done

echo "── omitted --detail-json defaults to {} (not a missing/null field) ──"
emit a3 --repo acme/widgets --pr 1 --outcome DEQUEUED
check_eq "detail defaults to an empty object" "{}" "$(printf '%s' "$EMIT_OUT" | jq -c '.detail')"

echo "── malformed --detail-json falls back to {} rather than dropping the record ──"
emit a4 --repo acme/widgets --pr 1 --outcome DEQUEUED --detail-json 'not-json{{'
check_eq "still exits 0" "0" "$EMIT_RC"
check_eq "detail falls back to {}" "{}" "$(printf '%s' "$EMIT_OUT" | jq -c '.detail')"
check_eq "record is still appended (WARN-don't-drop extends to a bad detail payload)" "1" "$(lake_lines a4)"

echo "── WARN-don't-drop: bad args warn to stderr, exit 0, write NO record ──"
emit b1 --repo acme/widgets --pr 1 --outcome BOGUS_OUTCOME
check_eq "invalid --outcome exits 0 (never fails the caller)" "0" "$EMIT_RC"
check "...naming the closed outcome set" \
  bash -c "grep -Fq -- '--outcome must be one of' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record" "0" "$(lake_lines b1)"

emit b2 --repo acme/widgets --pr abc --outcome QUEUED
check_eq "non-numeric --pr exits 0" "0" "$EMIT_RC"
check "...naming the offending flag" \
  bash -c "grep -Fq -- '--pr must be a number' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record" "0" "$(lake_lines b2)"

emit b3 --pr 1 --outcome QUEUED
check_eq "missing --repo exits 0" "0" "$EMIT_RC"
check "...naming all three required flags" \
  bash -c "grep -Fq -- '--repo, --pr, and --outcome are all required' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record" "0" "$(lake_lines b3)"

echo "── an unrecognised flag warns but does not abort the whole call ──"
emit b4 --repo acme/widgets --pr 1 --outcome QUEUED --bogus-flag xyz
check_eq "unknown flag still emits (ignored, not fatal)" "0" "$EMIT_RC"
check_eq "record still written" "1" "$(lake_lines b4)"

echo "── jq missing → WARN + exit 0, no record (infra failure, never blocks caller) ──"
NOJQ="$TMP/nojq-path"
mkdir -p "$NOJQ"
for tool in bash date mkdir cat basename hostname printf; do
  real="$(command -v "$tool" 2>/dev/null)" && [ -n "$real" ] && ln -sf "$real" "$NOJQ/$tool"
done
dir="$TMP/b5"; mkdir -p "$dir"
EMIT_OUT="$(PATH="$NOJQ" DIAGNOSE_QUEUE_RAW_DIR="$dir" bash "$EMIT" --repo acme/widgets --pr 1 --outcome QUEUED 2>"$TMP/err5.txt")"
EMIT_RC=$?
EMIT_ERR="$(cat "$TMP/err5.txt")"
check_eq "jq-not-found path exits 0" "0" "$EMIT_RC"
check "...naming jq as missing" bash -c "grep -Fq 'jq not found' <<<\"\$1\"" _ "$EMIT_ERR"
check_eq "...and writes no record" "0" "$(lake_lines b5)"

# ============================================================================
# B. cmd_diagnose_queue routes every verdict through the emit — including
#    cmd_poll's own internal TIMEOUT-path probe (the second call site).
# ============================================================================
echo "── B. cmd_diagnose_queue emits a lake record on every verdict ──"

export GATE_REPOLL_DELAY=0
# shellcheck source=workflows/scripts/build/gate.sh
# shellcheck disable=SC1091
source "$GATE"

# NOT a `d="$(dq_dir …)"` command-substitution call — that would run the
# `export` inside a subshell and never propagate DIAGNOSE_QUEUE_RAW_DIR back
# to this script's own environment (the real bug this comment guards:
# _dq_emit's subprocess would then silently fall through to the emit
# script's default sink, the checkout's OWN meta/data/raw/, polluting the
# real repo tree). Call it directly; it sets the global DQ_DIR.
dq_dir() { # <name> → sets DQ_DIR (global) + exports DIAGNOSE_QUEUE_RAW_DIR
  DQ_DIR="$TMP/dq-$1"
  mkdir -p "$DQ_DIR"
  export DIAGNOSE_QUEUE_RAW_DIR="$DQ_DIR"
}
dq_record() { # <dir> → the single JSONL line written there (empty if none/many)
  local files=("$1"/diagnose-queue-*.jsonl)
  [ -f "${files[0]}" ] || { echo ""; return; }
  cat "${files[@]}" 2>/dev/null
}

echo "── B1. MERGED (a race — probe short-circuited) ──"
dq_dir merged; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"MERGED","merged":true,"mergedAt":"2026-07-02T08:00:00Z","mergeQueueEntry":null}}}}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 0" "0" "$rc"
check_eq "exactly one lake line" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=MERGED" "MERGED" "$(jq -r '.outcome' <<<"$rec")"
check_eq "pr carried" "42" "$(jq -r '.pr' <<<"$rec")"
check_eq "repo carried" "Towheads/foundation" "$(jq -r '.repo' <<<"$rec")"
check_eq "detail carries mergedAt, NOT outcome/pr again" \
  '{"mergedAt":"2026-07-02T08:00:00Z"}' "$(jq -c '.detail' <<<"$rec")"

echo "── B2. QUEUE_STALLED ──"
dq_dir stalled; d="$DQ_DIR"
_gate_now() { _gate_epoch_of "2026-01-01T00:00:00Z"; }
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 10" "10" "$rc"
check_eq "exactly one lake line" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=QUEUE_STALLED" "QUEUE_STALLED" "$(jq -r '.outcome' <<<"$rec")"
check_eq "detail.enqueued_secs carried" "3600" "$(jq -r '.detail.enqueued_secs' <<<"$rec")"
check_eq "detail.merge_group_runs carried" "0" "$(jq -r '.detail.merge_group_runs' <<<"$rec")"

echo "── B3. DEQUEUED (no referencing merge_group run) ──"
dq_dir dequeued; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 8" "8" "$rc"
check_eq "exactly one lake line" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=DEQUEUED" "DEQUEUED" "$(jq -r '.outcome' <<<"$rec")"

echo "── B4. MERGE_GROUP_FAILED (a workflow-defined step failed) ──"
dq_dir failed; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs/*/jobs*) echo '{"jobs":[{"steps":[{"number":1,"conclusion":"success"},{"number":2,"conclusion":"failure"}]}]}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-x","conclusion":"failure","status":"completed","id":77,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 7" "7" "$rc"
check_eq "exactly one lake line" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=MERGE_GROUP_FAILED" "MERGE_GROUP_FAILED" "$(jq -r '.outcome' <<<"$rec")"
check_eq "detail.run_id carried" "77" "$(jq -r '.detail.run_id' <<<"$rec")"

echo "── B5. MERGE_GROUP_INFRA (failure never reached a workflow-defined step) ──"
dq_dir infra; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":null}}}}' ;;
    *actions/runs/*/jobs*) echo '{"jobs":[{"steps":[{"number":1,"conclusion":"failure"}]}]}' ;;
    *actions/runs*) echo '{"workflow_runs":[{"head_branch":"gh-readonly-queue/main/pr-42-x","conclusion":"failure","status":"completed","id":88,"created_at":"2026-07-01T10:00:00Z"}]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 11" "11" "$rc"
check_eq "outcome=MERGE_GROUP_INFRA" "MERGE_GROUP_INFRA" "$(jq -r '.outcome' <<<"$rec")"
check_eq "detail.run_id carried" "88" "$(jq -r '.detail.run_id' <<<"$rec")"

echo "── B6. QUEUED (still enqueued) ──"
dq_dir queued; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:59:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0; cmd_diagnose_queue Towheads/foundation 42 >/dev/null || rc=$?
rec="$(dq_record "$d")"
check_eq "exit 0" "0" "$rc"
check_eq "outcome=QUEUED" "QUEUED" "$(jq -r '.outcome' <<<"$rec")"

echo "── B7. ERROR — cmd_diagnose_queue's OWN die() path also emits a record ──"
dq_dir error; d="$DQ_DIR"
_gate_gh() { return 1; }  # the graphql membership query itself fails
rc=0
( cmd_diagnose_queue Towheads/foundation 42 >/dev/null 2>/dev/null 3>/dev/null ) || rc=$?
rec="$(dq_record "$d")"
check_eq "the die() path exits non-zero" "1" "$rc"
check_eq "exactly one lake line despite the die()" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=ERROR" "ERROR" "$(jq -r '.outcome' <<<"$rec")"
check_eq "detail.error carries the die() message" "true" "$(jq -r '.detail | has("error")' <<<"$rec")"

echo "── B8. cmd_poll's internal TIMEOUT-path probe ALSO fires the emit ──"
# The second call site #1192 explicitly requires coverage on: cmd_poll calls
# cmd_diagnose_queue internally (in a subshell that redirects fd3/stderr) when
# its own deadline runs out. That redirection must not suppress the emit —
# emit-diagnose-queue.sh is an independent subprocess writing to a file, not
# to fd3/stderr.
dq_dir poll-timeout; d="$DQ_DIR"
_gate_gh() {
  case "$*" in
    *"pr view"*) echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}' ;;
    *graphql*) echo '{"data":{"repository":{"pullRequest":{"state":"OPEN","merged":false,"mergedAt":null,"mergeQueueEntry":{"state":"QUEUED","position":1,"enqueuedAt":"2025-12-31T23:00:00Z"}}}}}' ;;
    *actions/runs*) echo '{"workflow_runs":[]}' ;;
    *) echo '{}' ;;
  esac
}
rc=0
( cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0 >/dev/null 2>/dev/null ) || rc=$?
rec="$(dq_record "$d")"
check_eq "poll TIMEOUT exits 4" "4" "$rc"
check_eq "the internal probe call wrote exactly one lake line" "1" "$(printf '%s\n' "$rec" | grep -c .)"
check_eq "outcome=QUEUE_STALLED (the probe's own verdict, not a bare TIMEOUT)" \
  "QUEUE_STALLED" "$(jq -r '.outcome' <<<"$rec")"

unset -f _gate_gh _gate_now
unset DIAGNOSE_QUEUE_RAW_DIR

# ============================================================================
# C. validate-diagnose-queue-emit.sh: green on the real tree, red on tampering
# ============================================================================
echo "── C. validate-diagnose-queue-emit.sh presence-lint ──"
check "passes on the real tree" bash "$LINT"

FIXR="$TMP/fixture"
mkdir -p "$FIXR/workflows/scripts/build"
cp "$EMIT" "$FIXR/workflows/scripts/emit-diagnose-queue.sh"
cp "$LINT" "$FIXR/workflows/scripts/validate-diagnose-queue-emit.sh"
cp "$GATE" "$FIXR/workflows/scripts/build/gate.sh"
chmod +x "$FIXR/workflows/scripts/"*.sh "$FIXR/workflows/scripts/build/gate.sh"
check "the fixture copy is green before tampering" bash "$FIXR/workflows/scripts/validate-diagnose-queue-emit.sh"

echo "── the emit script disappearing is caught ──"
rm -f "$FIXR/workflows/scripts/emit-diagnose-queue.sh"
if bash "$FIXR/workflows/scripts/validate-diagnose-queue-emit.sh" >"$TMP/lint1.out" 2>&1; then
  bad "lint fails when emit-diagnose-queue.sh is missing" "lint passed"
else
  ok "lint fails when emit-diagnose-queue.sh is missing"
fi
check "...naming the missing script" grep -Fq 'emit-diagnose-queue.sh is missing' "$TMP/lint1.out"
cp "$EMIT" "$FIXR/workflows/scripts/emit-diagnose-queue.sh"
chmod +x "$FIXR/workflows/scripts/emit-diagnose-queue.sh"

echo "── a verdict losing its _dq_finish wiring is caught ──"
# Targeted, line-exact tamper: the QUEUE_STALLED return site's own
# `_dq_finish "$owner_repo" "$pr" \` line becomes a bare `printf '%s\n' \` —
# same stdout output (the jq -cn command substitution is still its argument),
# but the emit call is gone. Anchored on the QUEUE_STALLED jq literal one
# line below, so this can't accidentally match a sibling return site.
QS_LINE="$(grep -n 'outcome:"QUEUE_STALLED"' "$GATE" | head -1 | cut -d: -f1)"
[ -n "$QS_LINE" ] || { bad "QUEUE_STALLED tamper setup" "could not locate the QUEUE_STALLED jq literal in gate.sh"; QS_LINE=0; }
FINISH_LINE=$((QS_LINE - 2))
sed "${FINISH_LINE}s/_dq_finish \"\$owner_repo\" \"\$pr\" \\\\/printf '%s\\\\n' \\\\/" \
  "$GATE" > "$FIXR/workflows/scripts/build/gate.sh"
chmod +x "$FIXR/workflows/scripts/build/gate.sh"
if diff -q "$GATE" "$FIXR/workflows/scripts/build/gate.sh" >/dev/null 2>&1; then
  bad "QUEUE_STALLED tamper sed" "line $FINISH_LINE substitution did not change gate.sh — fixture not exercised"
else
  bash -n "$FIXR/workflows/scripts/build/gate.sh" \
    && ok "tampered gate.sh fixture is still valid bash (a clean single-line swap)" \
    || bad "QUEUE_STALLED tamper sed" "tampered gate.sh no longer parses"
  if bash "$FIXR/workflows/scripts/validate-diagnose-queue-emit.sh" >"$TMP/lint2.out" 2>&1; then
    bad "lint fails when QUEUE_STALLED loses its _dq_finish wiring" "lint passed"
  else
    ok "lint fails when QUEUE_STALLED loses its _dq_finish wiring"
  fi
  check "...naming the unwired verdict" grep -Fq 'QUEUE_STALLED' "$TMP/lint2.out"
  check "...saying it is printed and discarded" grep -Fq 'printed and discarded' "$TMP/lint2.out"
fi
cp "$GATE" "$FIXR/workflows/scripts/build/gate.sh"
chmod +x "$FIXR/workflows/scripts/build/gate.sh"

echo "── a bare die() reappearing (bypassing _dq_die) is caught ──"
sed 's/_dq_die "\$owner_repo" "\$pr" "merge-queue membership query failed for #\$pr: \$cj"/die "merge-queue membership query failed for #$pr: $cj"/' \
  "$GATE" > "$FIXR/workflows/scripts/build/gate.sh"
chmod +x "$FIXR/workflows/scripts/build/gate.sh"
if grep -Eq '(^| )die "merge-queue membership' "$FIXR/workflows/scripts/build/gate.sh"; then
  if bash "$FIXR/workflows/scripts/validate-diagnose-queue-emit.sh" >"$TMP/lint3.out" 2>&1; then
    bad "lint fails when a bare die() bypasses _dq_die" "lint passed"
  else
    ok "lint fails when a bare die() bypasses _dq_die"
  fi
  check "...naming the bare-die defect" grep -Fq 'bare' "$TMP/lint3.out"
else
  bad "bare-die tamper sed" "sed substitution did not match — fixture not exercised"
fi

# ============================================================================
# D. canonical sink spec documents the stream; emit script points back at it
# ============================================================================
DQ_HEADING='### `diagnose-queue`'
echo "── D. meta/data/raw/README.md documents the diagnose-queue stream ──"
check "README has a diagnose-queue section" grep -Fq "$DQ_HEADING" "$README"
check "README's record-shape line lists the seven fields" \
  grep -Fq '{schema_version, ts, repo, pr, outcome, detail, session_id, host}' "$README"
check "README documents the closed outcome set" \
  grep -Fq 'QUEUE_STALLED' "$README"
check "README shows an example record with a QUEUE_STALLED outcome" \
  grep -Fq '"outcome":"QUEUE_STALLED"' "$README"
check "emit-diagnose-queue.sh header points at the canonical sink spec" \
  grep -Fq 'canonical sink spec: meta/data/raw/README.md' "$EMIT"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_diagnose_queue_emit: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_diagnose_queue_emit: OK — all %d checks passed\n' "$pass"
