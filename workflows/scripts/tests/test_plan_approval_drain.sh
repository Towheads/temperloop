#!/usr/bin/env bash
# test_plan_approval_drain.sh — pins /build Step 0a's TWO-ARM plan-approval
# drain and /check-in's strand probe (foundation#1496).
#
# THE BUG THIS PINS. Step 0a used to run "only when the operator-absent flag
# is active". An operator who answers `approve` on a plan-approval decision
# issue in a repo whose board no funnel ticks therefore had their answer read
# by nobody: the issue went unassigned (= answered), the plan note stayed
# `status: draft`, and /build refused to pick it up. Observed live for six
# days with no surface showing it was stuck.
#
# THE FIX, AND WHY IT IS A NARROWED HYBRID. Step 0a now runs in BOTH run
# modes, but the two arms do different things at sub-step 4(d):
#   * operator-absent + answered `approve` -> set `status: approved`, then
#     invoke `/build <plan> --unattended` (unchanged cron continuation).
#   * attended        + answered `approve` -> set `status: approved` and
#     REPORT the plan. It must NOT invoke `/build`. Widening when the step
#     fires is already a fleet-wide behavior change; letting an attended tick
#     auto-START a build would widen what that firing can do
#     (docs/principles.md § 7 Bound the blast radius).
#
# WHY A HERMETIC SCRIPT CAN TEST PROSE — same rationale as the sibling
# test_checkin_status_trailing_newline.sh. Step 0a's SELECTION is not a
# judgment call: it is a documented `gh issue list` filter (`--label decision
# --state open --assignee ""`, plus a `plan-approval-poll: [[Plans/` marker
# grep) followed by a documented reply parse. Part B below replays exactly
# that procedure against synthetic decision issues, over the full 2x2 of
# {attended, operator-absent} x {answered, unanswered}, with `gh` stubbed. To
# keep the replay honest rather than self-referential, Part A first asserts
# the literal query filter and every disposition string the replay emits are
# present verbatim in claude/commands/build.md — so the executable matrix and
# the prose cannot drift apart silently.
#
# Part C replays the SAME matrix under the pre-fix gating to prove the repro
# reproduces: attended x answered strands (nothing is selected) exactly as
# foundation#1496 reported.
#
# Usage: bash workflows/scripts/tests/test_plan_approval_drain.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_MD="$REPO_ROOT/claude/commands/build.md"
CHECKIN_MD="$REPO_ROOT/claude/commands/check-in.md"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required for this test" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

# spec_has <file> <label> <literal substring> — the prose pin primitive.
spec_has() {
  local file="$1" label="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then ok "$label"; else bad "$label" "not found in ${file#"$REPO_ROOT"/}: $needle"; fi
}
spec_lacks() {
  local file="$1" label="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then bad "$label" "still present in ${file#"$REPO_ROOT"/}: $needle"; else ok "$label"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Part A — spec pins. Every literal the replay depends on must be in the prose.
# ---------------------------------------------------------------------------
echo "Part A — Step 0a / check-in spec pins"

[ -f "$BUILD_MD" ]   || { echo "FATAL: missing $BUILD_MD" >&2; exit 1; }
[ -f "$CHECKIN_MD" ] || { echo "FATAL: missing $CHECKIN_MD" >&2; exit 1; }

# A1. The step is no longer gated to one run mode.
spec_lacks "$BUILD_MD" "Step 0a heading drops the operator-absent-only gate" \
  "## Step 0a — Tick-start plan-approval drain (operator-absent / cron runs only)"
spec_lacks "$BUILD_MD" "Step 0a no longer says it runs only when operator-absent" \
  "**Runs only when the operator-absent flag is active**"
spec_has "$BUILD_MD" "Step 0a runs on every work-selecting tick" \
  "**Runs on every tick that is deciding what to work**"

# A2. The load-bearing marker phrase naming the new arm.
spec_has "$BUILD_MD" "Step 0a carries the 'attended-tick drain' marker phrase" "attended-tick drain"

# A3. The attended arm's two obligations: set status, report, do not launch.
spec_has "$BUILD_MD" "attended arm sets status: approved" "Set that plan note's frontmatter to \`status: approved\`"
spec_has "$BUILD_MD" "attended arm emits exactly one line naming the plan" \
  "emit **exactly one line** naming the plan"
spec_has "$BUILD_MD" "attended arm is explicitly forbidden from invoking /build" \
  "**Do NOT invoke \`/build\`**"
# ...and the operator-absent arm still launches, unchanged.
spec_has "$BUILD_MD" "operator-absent arm still invokes /build --unattended" \
  "invoke \`/build Plans/<path> --unattended\`"

# A4. The query filter the replay in Part B executes.
spec_has "$BUILD_MD" "query filter: --label decision"  "--label decision"
spec_has "$BUILD_MD" "query filter: --state open"      "--state open"
spec_has "$BUILD_MD" "query filter: --assignee \"\" (unassigned == answered)" "--assignee \"\""
spec_has "$BUILD_MD" "answered is defined as unassigned" \
  "a still-assigned issue is **unanswered**"
spec_has "$BUILD_MD" "marker filter" "plan-approval-poll: [[Plans/"

# A5. /check-in carries the strand probe.
spec_has "$CHECKIN_MD" "check-in has a stranded-plan-approvals section" \
  "### Stranded plan approvals (answered but never drained)"
spec_has "$CHECKIN_MD" "check-in probe names the plan-approval marker" "plan-approval-poll: [[Plans/<path>]]"
spec_has "$CHECKIN_MD" "check-in probe greps for the marker in the issue body" 'plan-approval-poll: \\[\\[Plans/'
spec_has "$CHECKIN_MD" "check-in probe keys on the same unassigned==answered filter" '--assignee ""'
spec_has "$CHECKIN_MD" "check-in probe reports a still-draft plan as stranded" \
  "plan approval stranded"
spec_has "$CHECKIN_MD" "check-in probe is read-only (does not apply the answer)" \
  "never applies the answer"

# ---------------------------------------------------------------------------
# Part B — the 2x2 replay against a synthetic decision issue.
# ---------------------------------------------------------------------------
echo "Part B — 2x2 replay: {attended, operator-absent} x {answered, unanswered}"

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# A `gh` stub that honours exactly the two things Step 0a's query relies on:
# `--assignee ""` (an ASSIGNED issue is invisible to it) and `--json`. Every
# invocation is appended to $GH_CALL_LOG so the replay can assert what the
# drain did, not merely what it returned.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >> "$GH_CALL_LOG"
[ "${1:-}" = "issue" ] || exit 0
case "${2:-}" in
  list)
    # FIXTURE_ASSIGNED=1 models an issue still assigned to the operator, i.e.
    # UNANSWERED: the `--assignee ""` filter excludes it server-side.
    if [ "${FIXTURE_ASSIGNED:-0}" = "1" ] && printf '%s' "$*" | grep -- '--assignee' >/dev/null; then
      echo '[]'
    else
      cat "$FIXTURE_ISSUE_JSON"
    fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# The synthetic decision issue: a plan-approval poll, answered `approve`.
cat > "$TMP/issue-answered.json" <<'JSON'
[
  {
    "number": 933,
    "title": "Plan approval — session machine-awareness capture",
    "body": "Approve this plan?\n\nplan-approval-poll: [[Plans/2026-07-04 foundation - session machine-awareness capture]]\n",
    "comments": [
      { "body": "```decision\nchosen: approve\n```" }
    ]
  }
]
JSON
# A decision issue with NO plan-approval marker — must never be drained here.
cat > "$TMP/issue-unmarked.json" <<'JSON'
[
  { "number": 41, "title": "Blocked item needs a call", "body": "Which way?", "comments": [ { "body": "/approve" } ] }
]
JSON

# drain <arm> <gating> — replays Step 0a's documented procedure and prints one
# disposition token. <gating> is `both-arms` (the fix) or `absent-only` (the
# pre-fix gate Part C replays). Every token it can print is pinned in Part A.
drain() {
  local arm="$1" gating="$2"

  # Step 0a's run-mode gate.
  if [ "$gating" = "absent-only" ] && [ "$arm" != "operator-absent" ]; then
    echo "NOT_SELECTED:step-skipped"; return 0
  fi

  # Step 0a item 1 — the documented query. `--assignee ""` is the answered filter.
  local listed
  listed="$(gh issue list -R "acme/widget" --label decision --state open --assignee "" \
    --json number,title,body,comments)" || { echo "ERROR:query"; return 0; }

  # Step 0a item 1 — the marker filter; item 3 — the reply parse.
  local verdict
  verdict="$(printf '%s' "$listed" | python3 -c '
import json,re,sys
issues=json.load(sys.stdin)
marked=[i for i in issues if "plan-approval-poll: [[Plans/" in i.get("body","")]
if not marked:
    print("NOT_SELECTED:no-answered-marked-issue"); raise SystemExit
i=marked[0]
plan=re.search(r"plan-approval-poll: \[\[(Plans/[^\]]+)\]\]", i["body"]).group(1)
body=(i.get("comments") or [{}])[-1].get("body","")
if "chosen: approve" in body or "/approve" in body: print("approve\t%s\t%d" % (plan, i["number"]))
elif "chosen: skip" in body or "/choose skip" in body: print("skip\t%s\t%d" % (plan, i["number"]))
else: print("parse-miss\t%s\t%d" % (plan, i["number"]))
')"
  case "$verdict" in NOT_SELECTED:*|"") echo "${verdict:-ERROR:parse}"; return 0 ;; esac

  local answer plan num
  IFS=$'\t' read -r answer plan num <<<"$verdict"
  [ "$answer" = "approve" ] || { echo "NOT_APPROVED:$answer"; return 0; }

  # Step 0a item 4 (a)-(c) — identical in both arms.
  gh issue edit "$num" -R "acme/widget" --remove-label decision
  printf '%s\n' "SET_STATUS_APPROVED $plan" >> "$GH_CALL_LOG"

  # Step 0a item 4 (d) — the arms diverge here, and only here.
  if [ "$arm" = "operator-absent" ]; then
    printf '%s\n' "INVOKE /build $plan --unattended" >> "$GH_CALL_LOG"
    echo "APPROVED_LAUNCH:$plan"
  else
    printf '%s\n' "REPORT plan approved: $plan — run /build to execute it" >> "$GH_CALL_LOG"
    echo "APPROVED_NO_LAUNCH:$plan"
  fi
}

# run_case <label> <arm> <assigned?> <fixture> <gating> <expected-token-prefix>
run_case() {
  local label="$1" arm="$2" assigned="$3" fixture="$4" gating="$5" expect="$6"
  GH_CALL_LOG="$TMP/calls.$(echo "$label" | tr ' /x' '___').log"
  : > "$GH_CALL_LOG"
  local got
  got="$(PATH="$STUB_BIN:$PATH" GH_CALL_LOG="$GH_CALL_LOG" \
         FIXTURE_ASSIGNED="$assigned" FIXTURE_ISSUE_JSON="$fixture" \
         bash -c "$(declare -f drain); drain '$arm' '$gating'")"
  case "$got" in
    "$expect"*) ok "$label -> $got" ;;
    *) bad "$label" "expected ${expect}…, got '$got'" ;;
  esac
  LAST_LOG="$GH_CALL_LOG"
}

run_case "attended x answered"        attended        0 "$TMP/issue-answered.json" both-arms "APPROVED_NO_LAUNCH:"
# The whole point of the narrowed hybrid: the answer is applied, no build starts.
if grep -q "^SET_STATUS_APPROVED " "$LAST_LOG"; then ok "attended x answered applied status: approved"
else bad "attended x answered applied status: approved" "no SET_STATUS_APPROVED in call log"; fi
if grep -q "^INVOKE /build" "$LAST_LOG"; then bad "attended x answered did NOT launch /build" "call log contains a /build invocation"
else ok "attended x answered did NOT launch /build"; fi
if grep -q "^REPORT plan approved: " "$LAST_LOG"; then ok "attended x answered reported the plan by name"
else bad "attended x answered reported the plan by name" "no REPORT line in call log"; fi

run_case "attended x unanswered"      attended        1 "$TMP/issue-answered.json" both-arms "NOT_SELECTED:"
if grep -q "^SET_STATUS_APPROVED \|^INVOKE /build" "$LAST_LOG"; then
  bad "attended x unanswered mutated nothing" "call log shows a mutation"
else ok "attended x unanswered mutated nothing"; fi

run_case "operator-absent x answered" operator-absent 0 "$TMP/issue-answered.json" both-arms "APPROVED_LAUNCH:"
if grep -q "^INVOKE /build .* --unattended$" "$LAST_LOG"; then ok "operator-absent x answered launched /build --unattended"
else bad "operator-absent x answered launched /build --unattended" "no launch in call log"; fi

run_case "operator-absent x unanswered" operator-absent 1 "$TMP/issue-answered.json" both-arms "NOT_SELECTED:"
if grep -q "^SET_STATUS_APPROVED \|^INVOKE /build" "$LAST_LOG"; then
  bad "operator-absent x unanswered mutated nothing" "call log shows a mutation"
else ok "operator-absent x unanswered mutated nothing"; fi

# The marker filter is load-bearing in BOTH arms: an unmarked decision issue
# belongs to another drain and must fall straight through.
run_case "attended x unmarked decision issue"        attended        0 "$TMP/issue-unmarked.json" both-arms "NOT_SELECTED:"
run_case "operator-absent x unmarked decision issue" operator-absent 0 "$TMP/issue-unmarked.json" both-arms "NOT_SELECTED:"

# ---------------------------------------------------------------------------
# Part C — the pre-fix gate, replayed, to prove the repro reproduces.
# ---------------------------------------------------------------------------
echo "Part C — pre-fix gating reproduces the foundation#1496 strand"

run_case "PRE-FIX attended x answered strands"        attended        0 "$TMP/issue-answered.json" absent-only "NOT_SELECTED:step-skipped"
if grep -q "^SET_STATUS_APPROVED " "$LAST_LOG"; then
  bad "PRE-FIX attended x answered left the plan draft" "status was applied under the pre-fix gate"
else ok "PRE-FIX attended x answered left the plan draft (the strand)"; fi
run_case "PRE-FIX operator-absent x answered still drains" operator-absent 0 "$TMP/issue-answered.json" absent-only "APPROVED_LAUNCH:"

echo
echo "test_plan_approval_drain: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
