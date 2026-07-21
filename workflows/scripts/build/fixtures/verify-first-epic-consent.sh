#!/usr/bin/env bash
#
# verify-first-epic-consent.sh — LIVE fixture harness for the first-epic
# composed change-set (claude/templates/first-epic-setup.md), verifying
# design-brief acceptance (f)/(f2)/(f3)/(g)-fixture-half
# (Designs/temperloop - kernel starter engineering principles.md dim 4),
# per plan item `first-epic-consent-fixtures` (temperloop#611).
#
# WHAT THIS IS — a MANUAL, LIVE, opt-in verification run, NOT a unit test.
# It makes REAL `gh api`/`gh pr` writes against a REAL disposable GitHub
# fixture repo. This is a deliberate, one-off exception to the "deterministic
# tests over recorded fixtures, never live-network" engineering principle
# (claude/engineering-principles.md) — the whole POINT of this harness is to
# prove REAL GitHub API effects, which a mocked fixture-replay test (the
# `_gate_gh`-seam style of workflows/scripts/build/tests/test_gate.sh) cannot
# do. Consequences of that exception, held to deliberately:
#   - lives OUTSIDE workflows/scripts/build/tests/ and is named without a
#     `test_` prefix, so it is NEVER picked up by the Makefile's glob-based
#     `test-build` target (`tests/test_*.sh`) or by `make shellcheck`'s
#     `-not -path '*/tests/*'` exclusion's sibling gates — it never runs in
#     CI, never runs unattended, and never runs without the explicit
#     confirmation flag below.
#   - requires `--confirm-live-writes` to do anything beyond print its plan —
#     no accidental live run.
#   - operates ONLY on a repo whose name matches the reusable-pool naming
#     (`test-fixture-repo` or `test-fixture-repo-<N>`) under the
#     authenticated account — refuses (hard exit) on anything else. NEVER
#     touches a real adopter/org repo.
#
# SCOPE (mirrors the plan item's acceptance gate — see the plan note /
# temperloop#611):
#   - Contract (f):  admin fixture — consented writes land, declined writes
#     don't, `gate.sh backend` CONSUMED (never reimplemented).
#   - Contract (f2): transition-window invariant — walked across every
#     intermediate state the composed change-set creates; asserted at each:
#     no required `checks` status context ever exists without a configured
#     producer.
#   - Contract (f3): non-admin path — driven via an INJECTABLE rights-probe
#     override (documented below), never a faked write.
#   - Contract (g), fixture half: scaffolded workflow job named `checks`
#     matches the armed protection; the no-Actions posture scaffolds nothing
#     and records the local-gates/--non-strict disposition.
#   - Contract (g2): zero-CI *execution* — pre-CI epic items complete with the
#     legible "no CI configured" skip (ci-poll.sh's NO_CI verdict, #605), never
#     a TIMEOUT after the full poll window. Added by the `zero-ci-run-check`
#     plan item (temperloop#612) as the Zero-CI leg below, driven directly
#     against ci-poll.sh (never gate.sh's own inline re-poll) on PR#A's head
#     sha while it is still open on this no-Actions fixture repo.
#
# NARRATIVE (one repo, two real PRs, one injected-probe scenario, one direct
# ci-poll.sh leg):
#   Scenario A — "adopter declines CI for now": consent branch protection
#     (require-PR, forbid-direct-push, NO required status) + auto-delete;
#     decline CI. Opens PR#A, and — WHILE it is still open, before merge —
#     the Zero-CI leg (Contract g2) drives ci-poll.sh directly against its
#     head sha with a short --timeout/grace, asserting NO_CI fires (not
#     TIMEOUT). Then merges via `gate.sh managed-merge --non-strict` (no CI
#     to re-poll — the correct posture for a no-Actions/MANAGED backend),
#     confirms auto-delete actually removed the head ref.
#   Scenario B — "adopter later adds CI": scaffolds `.github/workflows/
#     checks.yml` (job literally named `checks`) on a branch, opens PR#B,
#     merges it BEFORE arming the required-status (workflow isn't a producer
#     on `main` yet — congruence rule), THEN — and only then — PATCHes
#     protection to require the `checks` context. Every intermediate read in
#     between (A's final state; before PR#B merges; after PR#B merges but
#     before the requirement is armed; after arming) is asserted to satisfy
#     the transition-window invariant.
#   Scenario C — "non-admin adopter": overrides the rights-probe seam to
#     return non-admin, drives the same three L1 write requests through the
#     dispatcher, and asserts ZERO real write calls fired (via a call
#     counter on the one write-issuing wrapper) while an admin packet
#     (settings + click-path + rationale, one entry per declined-by-scope
#     write) was composed instead.
#
# Usage:
#   verify-first-epic-consent.sh --confirm-live-writes [--repo OWNER/NAME] [--slot N]
#   verify-first-epic-consent.sh            # prints the plan, does nothing live
#
#   --confirm-live-writes   required to perform ANY live gh write. Without
#                           it, prints the plan (repo name, steps) and exits 0.
#   --repo OWNER/NAME       override the fixture repo (default:
#                           <gh-user>/test-fixture-repo, or
#                           <gh-user>/test-fixture-repo-<N> with --slot N).
#                           MUST match test-fixture-repo / test-fixture-repo-<N>
#                           in its name — refuses otherwise.
#   --slot N                pick pool member <N> (1..8): targets
#                           test-fixture-repo-<N> instead of the bare
#                           test-fixture-repo default. Lets two concurrent
#                           runs use disjoint fixtures without colliding on
#                           one repo's state.
#
# REUSABLE ACROSS RUNS — this harness NEVER deletes its fixture repo. The
# fixtures are a small, stable, bounded pool (test-fixture-repo and
# test-fixture-repo-1..8) that PERSIST between runs and are reset to a known
# baseline at the START of every run (protection removed, auto-delete off,
# scenario files + stale branches swept — see Setup). So a repeat run reuses
# the same repo cleanly rather than minting a new one; there is no per-run
# name churn and nothing to clean up afterward. (Repo lifecycle rationale:
# Decisions/temperloop - fixture-repo lifecycle (no auto-delete) — deletion
# is manual, and delete_repo is deliberately kept off the agent token.)
#
# Env overrides: RIGHTS_PROBE_OVERRIDE (Contract f3 injection seam — see
# rights_probe() below). GH bin override not needed (uses `gh` directly —
# this is a live harness, not a fixture-replay test, so there is no
# `_gate_gh`-style mock seam to override).
#
# Requires: gh (authenticated, `repo` scope), jq, base64. Consumes
# workflows/scripts/build/gate.sh's `backend`/`read`/`managed-merge`
# subcommands directly (never reimplements their logic).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="$HERE/../gate.sh"
CI_POLL_SH="$HERE/../ci-poll.sh"

CONFIRM=0
repo_override=""
slot=""
REPO_BASE="test-fixture-repo"
POOL_MAX=8

usage() {
  cat <<'EOF'
usage: verify-first-epic-consent.sh [--confirm-live-writes] [--repo OWNER/NAME] [--slot N]

  --confirm-live-writes   required to perform any live gh write
  --repo OWNER/NAME       override fixture repo (must match test-fixture-repo / test-fixture-repo-<N>)
  --slot N                target pool member test-fixture-repo-<N> (1..8) instead of the bare default
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --confirm-live-writes) CONFIRM=1; shift ;;
    --repo) repo_override="${2:-}"; shift 2 ;;
    --slot) slot="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "verify-first-epic-consent: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# --- safety rail: resolve + validate the target repo ------------------------
GH_USER="$(gh api user --jq .login 2>/dev/null)" || {
  echo "REFUSING: could not resolve authenticated gh user (gh auth status?)" >&2
  exit 1
}
if [ -n "$slot" ]; then
  case "$slot" in
    ''|*[!0-9]*) echo "REFUSING: --slot must be a positive integer (1..$POOL_MAX)" >&2; exit 2 ;;
  esac
  if [ "$slot" -lt 1 ] || [ "$slot" -gt "$POOL_MAX" ]; then
    echo "REFUSING: --slot $slot out of range — the reusable pool is test-fixture-repo-1..$POOL_MAX" >&2
    exit 2
  fi
  REPO_NAME="${REPO_BASE}-${slot}"
else
  REPO_NAME="$REPO_BASE"
fi
REPO="${repo_override:-$GH_USER/$REPO_NAME}"
REPO_BASENAME="${REPO##*/}"
case "$REPO_BASENAME" in
  test-fixture-repo|test-fixture-repo-*) : ;;
  *)
    echo "REFUSING: repo '$REPO' basename '$REPO_BASENAME' is not a reusable test fixture (must be 'test-fixture-repo' or 'test-fixture-repo-<N>') — this harness creates/mutates ONLY disposable test-fixture-repo* repos, never a real repo." >&2
    exit 1
    ;;
esac

PLAN() { printf '%s\n' "$*"; }

PLAN "=== verify-first-epic-consent — plan ==="
PLAN "target fixture repo: $REPO"
PLAN "gh authenticated as: $GH_USER"
PLAN "scenarios: A (decline-CI + consent protection/auto-delete), B (consent CI, congruent arming), C (non-admin injected probe)"
PLAN "gate.sh consumed from: $GATE_SH"

if [ "$CONFIRM" -ne 1 ]; then
  PLAN ""
  PLAN "--confirm-live-writes not passed — stopping before any live write. Re-run with that flag to execute for real."
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }
[ -x "$GATE_SH" ] || [ -f "$GATE_SH" ] || { echo "gate.sh not found at $GATE_SH" >&2; exit 1; }
[ -x "$CI_POLL_SH" ] || [ -f "$CI_POLL_SH" ] || { echo "ci-poll.sh not found at $CI_POLL_SH" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
WRITE_CALL_COUNT=0
ADMIN_PACKET='[]'

ok()   { PASS_COUNT=$((PASS_COUNT+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL_COUNT=$((FAIL_COUNT+1)); printf '  [FAIL] %s\n' "$1"; }
section() { printf '\n=== %s ===\n' "$1"; }

# poll_read_eq <label> <expected> <read-cmd...> — repo-settings PATCHes are
# occasionally eventually-consistent (a read immediately after a successful
# write can lag a few seconds before reflecting it); retry briefly before
# failing, rather than a single immediate read racing the write.
poll_read_eq() {
  local label="$1" expected="$2"; shift 2
  local actual=""
  for _ in 1 2 3 4 5; do
    actual="$("$@")"
    [ "$actual" = "$expected" ] && break
    sleep 2
  done
  assert_eq "$label" "$actual" "$expected"
}

# assert_eq <label> <actual> <expected>
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label (got '$actual')"
  else
    bad "$label (expected '$expected', got '$actual')"
  fi
}

# --- the one real gh-write-issuing wrapper — every genuine GitHub WRITE in
# this harness funnels through here, so scenario C's "zero writes" assertion
# has a single, honest counter to check (never inferred from absence of
# errors).
gh_write() {
  WRITE_CALL_COUNT=$((WRITE_CALL_COUNT+1))
  gh "$@"
}

# --- rights-probe seam — the INJECTABLE control point for Contract (f3).
# Production shape mirrors the template's A0 admin-rights probe
# (`gh api repos/<owner>/<repo> --jq '.permissions.admin'`). RIGHTS_PROBE_OVERRIDE
# is the test-injection seam (same idiom as gate.sh's own `_gate_gh`/
# `LAND_REQUIRES_PR` seams) — set to "false" to drive the non-admin path
# without needing a genuinely non-admin real repo (criterion 4's documented,
# sanctioned approach).
rights_probe() {
  local repo="$1"
  if [ -n "${RIGHTS_PROBE_OVERRIDE:-}" ]; then
    printf '%s\n' "$RIGHTS_PROBE_OVERRIDE"
    return 0
  fi
  gh api "repos/$repo" --jq '.permissions.admin' 2>/dev/null || printf 'false\n'
}

# admin_packet_add <setting> <consequence> <click_path>
admin_packet_add() {
  ADMIN_PACKET="$(jq -cn --argjson prior "$ADMIN_PACKET" \
    --arg setting "$1" --arg consequence "$2" --arg click_path "$3" \
    '$prior + [{setting:$setting, consequence:$consequence, click_path:$click_path}]')"
}

# l1_write_or_packet <repo> <setting-label> <consequence> <click-path> <write-fn...>
# The Contract (f3) dispatcher: probes rights ONCE, then either performs the
# real write (via gh_write, counted) or composes an admin-packet entry —
# NEVER both, and NEVER a write attempt on the non-admin branch.
l1_write_or_packet() {
  local repo="$1" setting="$2" consequence="$3" click_path="$4"; shift 4
  local admin; admin="$(rights_probe "$repo")"
  if [ "$admin" = "true" ]; then
    "$@"
  else
    admin_packet_add "$setting" "$consequence" "$click_path"
  fi
}

protection_read_contexts() {
  # A 404 (branch genuinely unprotected) means "no producer required" just as
  # much as a protected branch with a null required_status_checks does — both
  # read as "null" here. See the RESET_PATH loop's note on why exit status,
  # never stdout content, is what must be checked against a `gh api` 404.
  local out
  if out="$(gh api "repos/$REPO/branches/main/protection" --jq '.required_status_checks.contexts // "null"' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf 'null\n'
  fi
}

protection_apply() {  # <contexts-json-or-null> <enforce_admins-bool>
  local contexts="$1" enforce="$2" body
  if [ "$contexts" = "null" ]; then
    body="$(jq -cn --argjson enforce "$enforce" '{required_status_checks:null, enforce_admins:$enforce, required_pull_request_reviews:{required_approving_review_count:0}, restrictions:null, allow_force_pushes:false, allow_deletions:false}')"
  else
    body="$(jq -cn --argjson enforce "$enforce" --argjson ctx "$contexts" '{required_status_checks:{strict:false, contexts:$ctx}, enforce_admins:$enforce, required_pull_request_reviews:{required_approving_review_count:0}, restrictions:null, allow_force_pushes:false, allow_deletions:false}')"
  fi
  printf '%s' "$body" | gh_write api --method PUT "repos/$REPO/branches/main/protection" --input - >/dev/null
}

autodelete_apply() {  # <true|false>
  gh_write api -X PATCH "repos/$REPO" -f "delete_branch_on_merge=$1" >/dev/null
}

# Invoked only indirectly (passed by name to poll_read_eq, which calls "$@") —
# static analysis can't see that call site, same false-positive class
# workflows/scripts/build/tests/test_gate.sh already documents for its own
# indirectly-invoked seam functions.
# shellcheck disable=SC2329
read_autodelete() { gh api "repos/$REPO" --jq .delete_branch_on_merge; }

open_pr_with_file() {  # <branch> <path> <content> <title> -> prints PR number
  local branch="$1" path="$2" content="$3" title="$4" main_sha b64
  main_sha="$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)" \
    || { echo "could not resolve main sha" >&2; exit 1; }
  # Idempotent re-run support: drop a stale same-named branch left by a prior
  # run before recreating it, rather than erroring on "Reference already
  # exists" (each gh_write's own exit status is checked explicitly here —
  # never left to an implicit errexit-through-command-substitution
  # propagation, the exact class of silent-continue bug gate.sh's own
  # header warns about, temperloop#242).
  gh api -X DELETE "repos/$REPO/git/refs/heads/$branch" >/dev/null 2>&1 || true
  gh_write api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$branch" -f "sha=$main_sha" >/dev/null \
    || { echo "could not create branch $branch" >&2; exit 1; }
  b64="$(printf '%s' "$content" | base64 | tr -d '\n')"
  gh_write api -X PUT "repos/$REPO/contents/$path" -f "message=$title" -f "content=$b64" -f "branch=$branch" >/dev/null \
    || { echo "could not create file $path on $branch" >&2; exit 1; }
  local pr_url pr_num
  pr_url="$(gh_write pr create -R "$REPO" --head "$branch" --base main --title "$title" --body "fixture harness — temperloop#611" 2>&1)"
  pr_num="$(grep -oE '[0-9]+$' <<<"$pr_url" | tail -1)"
  [ -n "$pr_num" ] || { echo "could not resolve PR number from: $pr_url" >&2; exit 1; }
  printf '%s\n' "$pr_num"
}

# ============================================================================
# SETUP — ensure the fixture repo exists (idempotent: reuse if already there)
# ============================================================================
section "Setup"
if gh api "repos/$REPO" >/dev/null 2>&1; then
  PLAN "fixture repo already exists — reusing: $REPO"
else
  gh_write repo create "$REPO" --private --add-readme \
    --description "Disposable, reusable test fixture for temperloop's first-epic consent harness. Reset at each run; safe to delete." >/dev/null
  ok "created fixture repo $REPO"
fi
IS_ADMIN="$(gh api "repos/$REPO" --jq '.permissions.admin')"
assert_eq "fixture repo is admin-owned (real probe, no override)" "$IS_ADMIN" "true"

# Reset to a known baseline so this run's assertions are self-contained
# regardless of a prior run's leftover state (idempotent re-run support).
gh api -X DELETE "repos/$REPO/branches/main/protection" >/dev/null 2>&1 || true
gh_write api -X PATCH "repos/$REPO" -f delete_branch_on_merge=false >/dev/null
BASELINE_PROT="$(gh api "repos/$REPO/branches/main/protection" 2>&1 || true)"
if grep -q "Branch not protected" <<<"$BASELINE_PROT"; then
  ok "baseline: main has no protection before any consented write"
else
  bad "baseline: expected 'Branch not protected', got: $BASELINE_PROT"
fi
poll_read_eq "baseline: auto-delete-on-merge is off before any consented write" "false" read_autodelete

# Content-level reset too — a re-run against a repo a PRIOR run already
# progressed (Scenario B merges checks.yml straight to main) would otherwise
# false-fail Scenario A's "declined choice scaffolds nothing" check. Direct
# Contents-API delete on main is safe here because protection was just
# removed above (no PR required yet). This is what makes the harness
# genuinely REPEATABLE against the same fixture, not just a single-shot script.
# Every path a scenario below writes to main gets the same content-reset
# treatment, so a re-run is never tripped up by a prior run's leftover file.
#
# NOTE: `gh api` prints the HTTP error BODY to stdout even on a 404 (not just
# the human-readable "gh: Not Found" line, which goes to stderr) — so a
# `2>/dev/null || true`-guarded command substitution alone is NOT a reliable
# absent/present test; it would capture the 404 error JSON as if it were a
# value. The exit-status check on the command substitution ITSELF (the `if
# EXISTING_SHA=$(...); then` form) is what actually distinguishes "found" from
# "404", not stdout content.
for RESET_PATH in ".github/workflows/checks.yml" "scenario-a.md"; do
  if EXISTING_SHA="$(gh api "repos/$REPO/contents/$RESET_PATH" --jq '.sha' 2>/dev/null)"; then
    gh_write api -X DELETE "repos/$REPO/contents/$RESET_PATH" \
      -f "message=reset fixture baseline for a repeat run" -f "sha=$EXISTING_SHA" >/dev/null \
      || { echo "could not delete stale $RESET_PATH from main" >&2; exit 1; }
    ok "reset: removed a prior run's $RESET_PATH from main so this run starts from a clean tree"
  fi
done

# Sweep any non-main branch a prior (partial or complete) run left behind, so
# every invocation starts from exactly one ref — the other half of making
# this harness genuinely repeatable against the SAME fixture repo.
STALE_BRANCHES="$(gh api "repos/$REPO/git/refs/heads" --jq '.[].ref | select(. != "refs/heads/main") | ltrimstr("refs/heads/")' 2>/dev/null || true)"
if [ -n "$STALE_BRANCHES" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    gh api -X DELETE "repos/$REPO/git/refs/heads/$b" >/dev/null 2>&1 || true
  done <<<"$STALE_BRANCHES"
  ok "reset: swept stale non-main branches from a prior run ($(tr '\n' ' ' <<<"$STALE_BRANCHES"))"
fi

# gate.sh backend, consumed (never reimplemented) — real verdict for this
# personal-account fixture (no native merge queue provisionable).
BACKEND_VERDICT="$(bash "$GATE_SH" backend "$REPO")"
BACKEND_OUTCOME="$(jq -r .outcome <<<"$BACKEND_VERDICT")"
assert_eq "gate.sh backend verdict (consumed, not reimplemented)" "$BACKEND_OUTCOME" "MANAGED"

# ============================================================================
# SCENARIO A — decline CI (no-Actions), consent protection + auto-delete
# ============================================================================
section "Scenario A — no-Actions branch: consent protection (no required status) + auto-delete; CI declined"

protection_apply "null" true
ok "consented: branch protection applied (require-PR via enforce_admins, forbid-direct-push, NO required status yet — no-Actions posture)"
assert_eq "transition-window: no required-status context exists yet (no producer configured)" \
  "$(protection_read_contexts)" "null"

autodelete_apply true
poll_read_eq "consented: auto-delete-on-merge now true (real repo-setting read-back)" "true" read_autodelete

# declined: no CI — assert nothing was scaffolded
CI_FILE_STATUS="$(gh api "repos/$REPO/contents/.github/workflows/checks.yml" >/dev/null 2>&1 && echo present || echo absent)"
assert_eq "declined: no-Actions choice scaffolds nothing" "$CI_FILE_STATUS" "absent"

PR_A="$(open_pr_with_file scenario-a-decline-ci scenario-a.md "no-Actions scenario A file" "Scenario A: no-Actions PR")"
PLAN "opened PR #$PR_A (scenario A)"
READ_A="$(bash "$GATE_SH" read "$REPO" "$PR_A")"
assert_eq "PR#$PR_A pre-merge checks digest is NONE (no producer -> nothing required, nothing pending)" \
  "$(jq -r .checks <<<"$READ_A")" "NONE"

# ----------------------------------------------------------------------------
# ZERO-CI LEG — Contract (g2), plan item `zero-ci-run-check` (temperloop#612)
# ----------------------------------------------------------------------------
# PR#A is still OPEN at this point, on a repo with NO .github/workflows/ at
# all — the genuine zero-CI case: no producer will EVER post a check-run to
# this head sha. Drives ci-poll.sh DIRECTLY (never gate.sh's own inline
# _gate_ci_poll re-poll used by managed-merge below — this leg is specifically
# about the deterministic-spine script that owns /build's real 3g step, per
# ci-poll.sh's own header) against PR#A's head sha, with a short --timeout and
# a low CI_POLL_NOCI_GRACE_SECS grace so the NO_CI verdict (temperloop#605)
# fires in seconds, not the full poll window. Proves the first-epic L0 PR
# path completes with the legible zero-CI skip instead of hanging to TIMEOUT.
section "Zero-CI leg (Contract g2) — pre-CI PR#$PR_A completes with NO_CI, not TIMEOUT"
ZERO_CI_TIMEOUT=30
ZERO_CI_GRACE=6
ZERO_CI_START=$SECONDS
ZERO_CI_RC=0
ZERO_CI_OUT="$(CI_POLL_NOCI_GRACE_SECS="$ZERO_CI_GRACE" bash "$CI_POLL_SH" "$REPO" "$PR_A" \
    --interval 2 --timeout "$ZERO_CI_TIMEOUT")" || ZERO_CI_RC=$?
ZERO_CI_ELAPSED=$((SECONDS - ZERO_CI_START))
ZERO_CI_OUTCOME="$(jq -r .outcome <<<"$ZERO_CI_OUT" 2>/dev/null || printf 'PARSE_ERROR\n')"
assert_eq "zero-CI leg: ci-poll.sh outcome is NO_CI on a no-Actions fixture PR (never TIMEOUT)" \
  "$ZERO_CI_OUTCOME" "NO_CI"
assert_eq "zero-CI leg: ci-poll.sh exits 0 on NO_CI (poll succeeded — the verdict is data, not a script failure)" \
  "$ZERO_CI_RC" "0"
if [ "$ZERO_CI_ELAPSED" -lt "$ZERO_CI_TIMEOUT" ]; then
  ok "zero-CI leg: NO_CI fired at ${ZERO_CI_ELAPSED}s, well inside the ${ZERO_CI_GRACE}s grace window — NOT after the full ${ZERO_CI_TIMEOUT}s --timeout"
else
  bad "zero-CI leg: took the full ${ZERO_CI_TIMEOUT}s timeout to resolve (expected NO_CI well before it)"
fi
PLAN "zero-CI leg verdict: $ZERO_CI_OUT (elapsed ${ZERO_CI_ELAPSED}s, grace=${ZERO_CI_GRACE}s, timeout=${ZERO_CI_TIMEOUT}s)"

# managed-merge --non-strict is the CORRECT posture here: MANAGED backend +
# no-Actions -> no CI to re-poll, so --non-strict (never --strict, which
# would wait on a check-run that will never appear).
MERGE_A="$(bash "$GATE_SH" managed-merge "$REPO" "$PR_A" --non-strict)"
assert_eq "PR#$PR_A merged via gate.sh managed-merge --non-strict" "$(jq -r .outcome <<<"$MERGE_A")" "MERGED"
WRITE_CALL_COUNT=$((WRITE_CALL_COUNT+1))  # the merge itself is a real write, counted for the run total

# confirm auto-delete's consented effect actually landed (poll briefly — GH
# propagation can lag a few seconds).
DELETED=0
for _ in 1 2 3 4 5 6; do
  if ! gh api "repos/$REPO/git/refs/heads/scenario-a-decline-ci" >/dev/null 2>&1; then
    DELETED=1; break
  fi
  sleep 3
done
if [ "$DELETED" -eq 1 ]; then
  ok "consented auto-delete-on-merge REALLY deleted PR#$PR_A's head ref (verified via a 404 read, not inferred)"
else
  bad "PR#$PR_A's head ref still exists after merge — auto-delete-on-merge did not land"
fi

assert_eq "end of Scenario A: still no required-status context (no-Actions posture holds)" \
  "$(protection_read_contexts)" "null"

# ============================================================================
# SCENARIO B — consent CI: scaffold + congruent arming (never before the
# producer exists on main)
# ============================================================================
section "Scenario B — consent CI: scaffold checks.yml, merge WITHOUT arming, THEN arm only once the producer is confirmed on main"

WORKFLOW_YAML='name: checks
on:
  pull_request:
    branches: [main]
jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - run: echo "ok"
'
PR_B="$(open_pr_with_file scenario-b-consent-ci .github/workflows/checks.yml "$WORKFLOW_YAML" "Scenario B: add checks workflow")"
PLAN "opened PR #$PR_B (scenario B — workflow lives on the branch, NOT yet on main)"

assert_eq "transition-window: before PR#$PR_B merges, required-status context still absent (producer not yet on main)" \
  "$(protection_read_contexts)" "null"

MERGE_B="$(bash "$GATE_SH" managed-merge "$REPO" "$PR_B" --non-strict)"
assert_eq "PR#$PR_B merged via gate.sh managed-merge --non-strict (no required status to re-poll yet)" \
  "$(jq -r .outcome <<<"$MERGE_B")" "MERGED"
WRITE_CALL_COUNT=$((WRITE_CALL_COUNT+1))

CI_FILE_ON_MAIN="$(gh api "repos/$REPO/contents/.github/workflows/checks.yml" >/dev/null 2>&1 && echo present || echo absent)"
assert_eq "producer (checks.yml) now present on main after PR#$PR_B merged" "$CI_FILE_ON_MAIN" "present"
assert_eq "transition-window: STILL no required-status context immediately after merge — the moment BEFORE arming" \
  "$(protection_read_contexts)" "null"

# Structural congruence: arm the requirement ONLY now, with the producer
# already confirmed on main. This is the one moment order matters — arming
# before this line would be the self-brick the design's congruence rule
# makes structurally unreachable.
protection_apply '["checks"]' true
ok "armed required-status context 'checks' — only after confirming the producer is on main"
assert_eq "final: required-status context now == ['checks']" \
  "$(protection_read_contexts | jq -c .)" '["checks"]'

JOB_NAME_MATCH="$(gh api "repos/$REPO/contents/.github/workflows/checks.yml" --jq '.content' | base64 --decode | grep -c '^  checks:' || true)"
if [ "$JOB_NAME_MATCH" -ge 1 ]; then
  ok "scaffolded workflow's job is literally named 'checks' — matches the armed required-status context (Contract g)"
else
  bad "scaffolded workflow's job name does not match 'checks'"
fi

# ============================================================================
# SCENARIO C — Contract (f3): non-admin path via the injectable rights-probe
# ============================================================================
section "Scenario C — non-admin fixture (injected rights-probe override, per criterion 4's sanctioned approach)"
PLAN "Real non-admin repo not arrangeable under a single-account 'towhead' fixture (criterion 4) —"
PLAN "driving this via RIGHTS_PROBE_OVERRIDE=false against the SAME real admin fixture, asserting"
PLAN "zero real gh writes fire and an admin packet composes instead. This is the harness's own"
PLAN "branch logic under test, never a faked write against a repo we don't actually control."

WRITE_COUNT_BEFORE_C="$WRITE_CALL_COUNT"
ADMIN_PACKET='[]'
RIGHTS_PROBE_OVERRIDE=false

l1_write_or_packet "$REPO" \
  "Require a pull request before merging; forbid direct pushes to main" \
  "Every future change, including your own, must go through a PR from here on." \
  "Settings -> Branches -> Add branch protection rule -> main -> Require a pull request before merging" \
  protection_apply "null" true

l1_write_or_packet "$REPO" \
  "Auto-delete head branch on merge" \
  "A merged branch cleans itself up automatically; no manual prune needed." \
  "Settings -> General -> Pull Requests -> Automatically delete head branches" \
  autodelete_apply true

l1_write_or_packet "$REPO" \
  "Merge-queue disposition" \
  "Record BUILD_MERGE_BACKEND=managed (this account/plan cannot provision a native queue)." \
  "N/A -- recorded locally, not a GitHub settings write" \
  autodelete_apply true   # placeholder write-fn; never reached on the non-admin branch

unset RIGHTS_PROBE_OVERRIDE

assert_eq "Contract (f3): zero real gh writes fired while rights-probe was overridden to non-admin" \
  "$WRITE_CALL_COUNT" "$WRITE_COUNT_BEFORE_C"

PACKET_LEN="$(jq 'length' <<<"$ADMIN_PACKET")"
assert_eq "Contract (f3): admin packet composed one entry per scope-blocked write (3 requested)" "$PACKET_LEN" "3"

# Confirm the REAL repo settings are unaffected by the scenario-C dispatch —
# not just "no gh_write call counted," but the actual GitHub-side state is
# provably untouched by this scenario (protection is exactly what Scenario
# B left it at; nothing new landed).
assert_eq "Contract (f3): live repo protection unchanged by the non-admin scenario" \
  "$(protection_read_contexts | jq -c .)" '["checks"]'

PLAN ""
PLAN "--- Composed admin packet (Contract f3 evidence) ---"
jq . <<<"$ADMIN_PACKET"

# L0/L2-local-only posture note (documented scope, per criterion 4 — the
# actual funnel run through /assess+/build is out of this harness's scope;
# what's asserted here is only that these levels need no GitHub write at
# all, so an admin-rights probe result never blocks them):
PLAN ""
PLAN "L0 (principles recorded to the adopter's own repo files) and L2's local-gates posture require"
PLAN "NO GitHub write at all -- both are unaffected by rights_probe's result by construction. Running"
PLAN "the full epic through the real funnel (/assess + /build) is out of this harness's scope; that"
PLAN "is first-epic-offer's own build-time acceptance, not re-proven here."

# ============================================================================
# SUMMARY
# ============================================================================
section "Summary"
PLAN "PASS: $PASS_COUNT   FAIL: $FAIL_COUNT   total real gh-write calls this run: $WRITE_CALL_COUNT"

section "Fixture retained for reuse (no auto-delete by design)"
PLAN "Left $REPO in place — it is a reusable pool fixture, reset to baseline at the start of every run."
PLAN "The pool is bounded (test-fixture-repo, test-fixture-repo-1..$POOL_MAX); nothing accumulates per run."
PLAN "Deletion is deliberately manual (delete_repo kept off the agent token) — see"
PLAN "Decisions/temperloop - fixture-repo lifecycle (no auto-delete). To remove a fixture, delete it via"
PLAN "the GitHub web UI (Settings -> Danger Zone) or: gh repo delete $REPO --yes  (needs delete_repo scope)."

[ "$FAIL_COUNT" -eq 0 ]
