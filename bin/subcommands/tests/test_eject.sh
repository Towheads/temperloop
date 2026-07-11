#!/usr/bin/env bash
#
# Tests for eject.sh — `foundation eject` (foundation #765 Epic D "newcomer
# experience", item foundation-eject / #855). Same fixture style as
# test_init.sh: a throwaway real-git bare upstream + clone, a stubbed `gh`
# on PATH that LOGS every call it sees (the write-intercepting-wrapper
# proof — a declined/dry-run/offline run must leave ZERO gh calls in the
# log), zero network, structured-output assertions via jq.
#
# Covers:
#   - no .foundation/config -> no-op, exit 0, zero gh calls, prints the
#     machine-level uninstall bullet
#   - --dry-run: zero gh calls, .foundation/config left untouched
#   - non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#     .foundation/config left untouched
#   - consented full revert (--yes): the exact gh calls fire for each
#     install type (label/required_check/board), .foundation/ removed
#   - idempotency: re-running after a full revert is a no-op (no config,
#     zero gh calls)
#   - proposal_pr MERGED: left alone (no close/delete-branch call, branch
#     kept), still counts as reverted
#   - proposal_pr OPEN, branch currently checked out: switches off the
#     branch first, then closes + deletes it
#   - partial failure (a label delete fails and the label still exists):
#     .foundation/config is rewritten with only the unresolved entry,
#     exit 1, and a re-run retries only that entry
#   - offline (--no-network): every install skipped with a reason, zero gh
#     calls, .foundation/config left in place (all entries still recorded)
#   - a label that already existed before init (no matching installs[]
#     entry) is never touched — proves manifest-driven, not namespace grep
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EJECT="$HERE/../eject.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eject-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- fixture: a BARE upstream (push-able) + a clone, origin/main real ------
new_fixture_repo() {
  local name="$1"
  local bare="$WORK/$name-upstream.git"
  local repo="$WORK/$name"
  git init -q --bare --initial-branch=main "$bare"
  git clone -q "$bare" "$repo" 2>/dev/null
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" push -q origin main 2>/dev/null
  git -C "$repo" fetch -q origin
  printf '%s\n' "$(cd "$repo" && pwd -P)"
}

seed_config() {
  # seed_config REPO_DIR INSTALLS_JSON — writes + commits .foundation/config
  local repo="$1" installs="$2"
  mkdir -p "$repo/.foundation"
  jq -n --argjson installs "$installs" \
    '{schema:1, generated_at:"2026-01-01T00:00:00Z",
      probe:{repo:{gh_repo:"acme/widget", default_branch:"main"}},
      tracker:{mode:"issues", board:1, boards_conf_path:"workflows/scripts/board/boards.conf", boards_conf_entry:""},
      installs:$installs}' > "$repo/.foundation/config"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed .foundation/config"
}

# --- fake gh: logs every call; env vars steer replies ----------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
CALL_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  api)
    case "$*" in
      *required_status_checks*)
        # GET (no --method) probes existence; --method DELETE reverts.
        case "$*" in
          *"--method DELETE"*) exit "${FAKE_REQUIRED_CHECK_DELETE_RC:-0}" ;;
          *) exit "${FAKE_REQUIRED_CHECK_GET_RC:-0}" ;;
        esac
        ;;
      *"git/refs/heads/"*) exit 0 ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      delete) exit "${FAKE_LABEL_DELETE_RC:-0}" ;;
      # mirrors the real `gh label list --json name -q '.[].name'` output
      # shape: plain names, one per line.
      list) printf '%s\n' ${FAKE_EXISTING_LABELS:-} ;;
    esac
    exit 0
    ;;
  project)
    case "$2" in
      delete) exit "${FAKE_PROJECT_DELETE_RC:-0}" ;;
      view) exit "${FAKE_PROJECT_VIEW_RC:-0}" ;;
    esac
    exit 0
    ;;
  pr)
    case "$2" in
      view) printf '%s' "${FAKE_PR_STATE:-MERGED}" ;;
      close) exit "${FAKE_PR_CLOSE_RC:-0}" ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

export CALL_LOG

# run WANT_RC ARGS... — invoke eject.sh with the fake gh on PATH, closed
# stdin (proves the non-interactive default-deny path unless a test
# explicitly wants otherwise), asserts exit code. Sets $out.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    EJECT_GH_BIN=gh \
    FAKE_PR_STATE="${FAKE_PR_STATE:-MERGED}" \
    FAKE_PR_CLOSE_RC="${FAKE_PR_CLOSE_RC:-0}" \
    FAKE_LABEL_DELETE_RC="${FAKE_LABEL_DELETE_RC:-0}" \
    FAKE_EXISTING_LABELS="${FAKE_EXISTING_LABELS:-}" \
    FAKE_REQUIRED_CHECK_DELETE_RC="${FAKE_REQUIRED_CHECK_DELETE_RC:-0}" \
    FAKE_REQUIRED_CHECK_GET_RC="${FAKE_REQUIRED_CHECK_GET_RC:-0}" \
    FAKE_PROJECT_DELETE_RC="${FAKE_PROJECT_DELETE_RC:-0}" \
    FAKE_PROJECT_VIEW_RC="${FAKE_PROJECT_VIEW_RC:-0}" \
    CALL_LOG="$CALL_LOG" \
    bash "$EJECT" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for: $* -- output:\n$out"
}

call_count() {
  grep -Fc "$1" "$CALL_LOG" 2>/dev/null || true
}

# =============================================================================
# 1. No .foundation/config -> no-op, exit 0, zero gh calls, uninstall bullet
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
run 0 --dir "$REPO1" --yes
[ ! -s "$CALL_LOG" ] || fail "no-config run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q "nothing to eject" || fail "no-config run did not report nothing-to-eject (got: $out)"
echo "$out" | grep -q "Three separate removal scopes" || fail "no-config run did not print the uninstall bullet (got: $out)"
echo "PASS: no .foundation/config -> no-op, zero gh calls, uninstall bullet printed"

# =============================================================================
# 2. --dry-run: zero gh calls, config left untouched
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
seed_config "$REPO2" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO2" --dry-run
[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO2/.foundation/config" ] || fail "dry-run removed .foundation/config (should be untouched)"
echo "PASS: --dry-run makes zero gh calls, leaves .foundation/config untouched"

# =============================================================================
# 3. Non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#    config left untouched
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
seed_config "$REPO3" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO3"
[ ! -s "$CALL_LOG" ] || fail "default-deny made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO3/.foundation/config" ] || fail "default-deny removed .foundation/config (should be untouched)"
echo "$out" | grep -q "aborted — nothing reverted" || fail "default-deny did not report the abort (got: $out)"
echo "PASS: non-interactive, no --yes -> aborts, zero gh calls, config untouched"

# =============================================================================
# 4. Consented full revert (--yes): label + required_check + board all
#    revert via the exact gh calls, .foundation/ removed. Then a SECOND run
#    is idempotent: no config, zero gh calls.
# =============================================================================
REPO4="$(new_fixture_repo repo4)"
seed_config "$REPO4" '[
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"},
  {"type":"required_check","repo":"acme/widget","branch":"main","name":"checks"},
  {"type":"board","owner":"acme","project_number":42,"url":"https://github.com/orgs/acme/projects/42"}
]'
run 0 --dir "$REPO4" --yes
[ "$(call_count 'label delete fnd:status:backlog')" -ge 1 ] || fail "label delete call missing"
[ "$(call_count 'required_status_checks')" -ge 1 ] || fail "required-check revert call missing"
[ "$(call_count 'project delete 42')" -ge 1 ] || fail "board delete call missing"
[ ! -e "$REPO4/.foundation" ] || fail "full revert did not remove .foundation/"
echo "$out" | grep -q "foundation eject: done" || fail "full revert did not report done (got: $out)"

run 0 --dir "$REPO4" --yes
[ ! -s "$CALL_LOG" ] || fail "second run made gh calls (should be zero — idempotent):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q "no-op" || fail "second run did not report no-op (got: $out)"
echo "PASS: consented full revert fires the exact gh calls per install type, removes .foundation/; re-run is a zero-call no-op"

# =============================================================================
# 5. proposal_pr MERGED: left alone (no close/delete-branch call), still
#    counts as reverted (config removed)
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
seed_config "$REPO5" '[{"type":"proposal_pr","branch":"foundation-init/config","pr_number":21,"url":"https://github.com/acme/widget/pull/21"}]'
FAKE_PR_STATE=MERGED run 0 --dir "$REPO5" --yes
grep -q "^pr close" "$CALL_LOG" && fail "MERGED proposal_pr should never be closed"
[ ! -e "$REPO5/.foundation" ] || fail "MERGED proposal_pr revert did not remove .foundation/"
echo "$out" | grep -q "merged — left in tree" || fail "did not report the merged/left-in-tree outcome (got: $out)"
echo "PASS: proposal_pr MERGED is left alone (no close call), still counts as reverted"

# =============================================================================
# 6. proposal_pr OPEN, branch currently checked out: switches off the
#    branch first, then closes + deletes it
# =============================================================================
REPO6="$(new_fixture_repo repo6)"
git -C "$REPO6" checkout -q -B foundation-init/config origin/main
seed_config "$REPO6" '[{"type":"proposal_pr","branch":"foundation-init/config","pr_number":21,"url":"https://github.com/acme/widget/pull/21"}]'
[ "$(git -C "$REPO6" symbolic-ref --short HEAD)" = "foundation-init/config" ] \
  || fail "test setup: expected to be on the proposal branch"
FAKE_PR_STATE=OPEN run 0 --dir "$REPO6" --yes
[ "$(call_count 'pr close 21')" -ge 1 ] || fail "OPEN proposal_pr was not closed"
grep -q -- "--delete-branch" "$CALL_LOG" || fail "OPEN proposal_pr close did not pass --delete-branch"
[ "$(git -C "$REPO6" symbolic-ref --short HEAD)" = "main" ] \
  || fail "did not switch off the proposal branch before closing it (on: $(git -C "$REPO6" symbolic-ref --short HEAD))"
echo "PASS: proposal_pr OPEN switches off a currently-checked-out branch, then closes + deletes it"

# =============================================================================
# 7. Partial failure: label delete fails AND the label still exists ->
#    .foundation/config is rewritten with only that unresolved entry,
#    exit 1; a re-run retries only it.
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
seed_config "$REPO7" '[
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"},
  {"type":"label","repo":"acme/widget","name":"fnd:status:ready"}
]'
FAKE_LABEL_DELETE_RC=1 FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready" \
  run 1 --dir "$REPO7" --yes
echo "$out" | grep -q "foundation eject: incomplete" || fail "partial failure did not report incomplete (got: $out)"
[ -f "$REPO7/.foundation/config" ] || fail "partial failure removed .foundation/config (should be kept for retry)"
cfg="$(cat "$REPO7/.foundation/config")"
[ "$(jq '.installs | length' <<<"$cfg")" -eq 2 ] || fail "partial-failure config should keep both unresolved label entries (got: $(jq -c '.installs' <<<"$cfg"))"

# Re-run: now the deletes succeed -> fully resolved this time
FAKE_LABEL_DELETE_RC=0 run 0 --dir "$REPO7" --yes
[ ! -e "$REPO7/.foundation" ] || fail "retry after partial failure did not fully revert"
echo "PASS: a failed revert keeps only the unresolved entries in .foundation/config, exit 1; retry resolves them"

# =============================================================================
# 8. Offline (--no-network): every install skipped, zero gh calls, config
#    left in place with every entry still recorded
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
seed_config "$REPO8" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 1 --dir "$REPO8" --yes --no-network
[ ! -s "$CALL_LOG" ] || fail "--no-network made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO8/.foundation/config" ] || fail "--no-network removed .foundation/config (should be kept)"
echo "$out" | grep -q -- "--no-network" || fail "--no-network skip reason not reported (got: $out)"
echo "PASS: --no-network skips every install with a reason, zero gh calls, config kept for a later retry"

# =============================================================================
# 9. A pre-existing label with NO matching installs[] entry is never
#    touched — manifest-driven, not a namespace grep.
# =============================================================================
REPO9="$(new_fixture_repo repo9)"
seed_config "$REPO9" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready needs-clarification" \
  run 0 --dir "$REPO9" --yes
grep -q "label delete fnd:status:ready" "$CALL_LOG" && fail "eject deleted a label with no installs[] entry (namespace-grep behavior, not manifest-driven)"
grep -q "label delete needs-clarification" "$CALL_LOG" && fail "eject deleted a label with no installs[] entry (namespace-grep behavior, not manifest-driven)"
[ "$(call_count 'label delete fnd:status:backlog')" -eq 1 ] || fail "the one recorded label was not deleted exactly once"
echo "PASS: only manifest-recorded labels are ever deleted — a pre-existing sibling label is untouched"

echo
echo "ALL PASS: test_eject.sh"
