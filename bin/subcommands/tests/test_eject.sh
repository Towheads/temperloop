#!/usr/bin/env bash
#
# Tests for eject.sh — `temperloop eject` (foundation #765 Epic D "newcomer
# experience", item foundation-eject / #855). Same fixture style as
# test_init.sh: a throwaway real-git bare upstream + clone, a stubbed `gh`
# on PATH that LOGS every call it sees (the write-intercepting-wrapper
# proof — a declined/dry-run/offline run must leave ZERO gh calls in the
# log), zero network, structured-output assertions via jq.
#
# Covers:
#   - no .temperloop/config -> no-op, exit 0, zero gh calls, prints the
#     machine-level uninstall bullet
#   - --dry-run: zero gh calls, .temperloop/config left untouched
#   - non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#     .temperloop/config left untouched
#   - consented full revert (--yes): the exact gh calls fire for each
#     install type (label/required_check/board), .temperloop/ removed
#   - idempotency: re-running after a full revert is a no-op (no config,
#     zero gh calls)
#   - proposal_pr MERGED: left alone (no close/delete-branch call, branch
#     kept), still counts as reverted
#   - proposal_pr OPEN, branch currently checked out: switches off the
#     branch first, then closes + deletes it
#   - partial failure (a label delete fails and the label still exists):
#     .temperloop/config is rewritten with only the unresolved entry,
#     exit 1, and a re-run retries only that entry
#   - offline (--no-network): every install skipped with a reason, zero gh
#     calls, .temperloop/config left in place (all entries still recorded)
#   - a label that already existed before init (no matching installs[]
#     entry) is never touched — proves manifest-driven, not namespace grep
#   - temperloop#414 partial/failed-init recovery:
#     - .temperloop/ residue with NO .temperloop/config (init.sh Step 0's
#       baseline.jsonl, written before config exists) is recognized and
#       cleaned up — zero gh calls, no branch change (the old config-gated
#       "nothing to eject" no-op used to miss this entirely)
#     - that same residue path honors --dry-run and non-interactive
#       default-deny exactly like the config-manifest path
#     - end-to-end: a REAL 'temperloop init' run that dies after its branch
#       switch (proposal-pr.sh's `git checkout -B`) leaves .temperloop/config
#       committed on the stray branch plus a recovery marker; `foundation
#       eject` restores the original branch, deletes the stray unmerged
#       local branch, and removes .temperloop/ — byte-identical to before
#       init ran
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EJECT="$HERE/../eject.sh"
INIT="$HERE/../init.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eject-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- config-hermetic git env, no background gc/maintenance (temperloop#400) --
# This suite was flaking intermittently on the macos-latest CI runner while
# passing everywhere else and locally. The suspected cause is git's automatic
# background `maintenance` / `gc --auto`, which git fires after commit/fetch/
# push and which — under a loaded runner's I/O contention — can race the NEXT
# fixture git command for the repo's index/ref locks. Pin an isolated global +
# empty system config with auto-maintenance OFF so no git process runs in the
# background, and so the fixtures depend on ZERO ambient config (identity still
# comes from the GIT_*_NAME/EMAIL vars above). GIT_OPTIONAL_LOCKS=0 stops read
# commands from taking optional locks / refreshing the index behind our back.
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_OPTIONAL_LOCKS=0
cat > "$GIT_CONFIG_GLOBAL" <<'GITCFG'
[gc]
	auto = 0
[maintenance]
	auto = false
[fetch]
	writeCommitGraph = false
[init]
	defaultBranch = main
GITCFG

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
  # seed_config REPO_DIR INSTALLS_JSON — writes + commits .temperloop/config
  local repo="$1" installs="$2"
  mkdir -p "$repo/.temperloop"
  jq -n --argjson installs "$installs" \
    '{schema:1, generated_at:"2026-01-01T00:00:00Z",
      probe:{repo:{gh_repo:"acme/widget", default_branch:"main"}},
      tracker:{mode:"issues", board:1, boards_conf_path:"workflows/scripts/board/boards.conf", boards_conf_entry:""},
      installs:$installs}' > "$repo/.temperloop/config"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "seed .temperloop/config"
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

# run_init ARGS... — invoke the REAL init.sh with the same fake gh on PATH,
# closed stdin. Sets $init_out; the caller reads $init_rc itself (test 11
# below deliberately drives init.sh to a NON-zero exit — a broken push,
# standing in for a killed/failed run — and inspects the resulting repo
# state, not init.sh's own gh-call accounting).
run_init() {
  init_rc=0
  init_out="$(PATH="$BIN:$PATH" INIT_GH_BIN=gh bash "$INIT" "$@" </dev/null 2>&1)" || init_rc=$?
}

# =============================================================================
# 1. No .temperloop/config -> no-op, exit 0, zero gh calls, uninstall bullet
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
run 0 --dir "$REPO1" --yes
[ ! -s "$CALL_LOG" ] || fail "no-config run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q "nothing to eject" || fail "no-config run did not report nothing-to-eject (got: $out)"
echo "$out" | grep -q "Three separate removal scopes" || fail "no-config run did not print the uninstall bullet (got: $out)"
echo "PASS: no .temperloop/config -> no-op, zero gh calls, uninstall bullet printed"

# =============================================================================
# 2. --dry-run: zero gh calls, config left untouched
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
seed_config "$REPO2" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO2" --dry-run
[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO2/.temperloop/config" ] || fail "dry-run removed .temperloop/config (should be untouched)"
echo "PASS: --dry-run makes zero gh calls, leaves .temperloop/config untouched"

# =============================================================================
# 3. Non-interactive default-deny (no --yes, closed stdin): zero gh calls,
#    config left untouched
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
seed_config "$REPO3" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 0 --dir "$REPO3"
[ ! -s "$CALL_LOG" ] || fail "default-deny made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO3/.temperloop/config" ] || fail "default-deny removed .temperloop/config (should be untouched)"
echo "$out" | grep -q "aborted — nothing reverted" || fail "default-deny did not report the abort (got: $out)"
echo "PASS: non-interactive, no --yes -> aborts, zero gh calls, config untouched"

# =============================================================================
# 4. Consented full revert (--yes): label + required_check + board all
#    revert via the exact gh calls, .temperloop/ removed. Then a SECOND run
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
[ ! -e "$REPO4/.temperloop" ] || fail "full revert did not remove .temperloop/"
echo "$out" | grep -q "temperloop eject: done" || fail "full revert did not report done (got: $out)"

run 0 --dir "$REPO4" --yes
[ ! -s "$CALL_LOG" ] || fail "second run made gh calls (should be zero — idempotent):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q "no-op" || fail "second run did not report no-op (got: $out)"
echo "PASS: consented full revert fires the exact gh calls per install type, removes .temperloop/; re-run is a zero-call no-op"

# =============================================================================
# 5. proposal_pr MERGED: left alone (no close/delete-branch call), still
#    counts as reverted (config removed)
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
seed_config "$REPO5" '[{"type":"proposal_pr","branch":"foundation-init/config","pr_number":21,"url":"https://github.com/acme/widget/pull/21"}]'
FAKE_PR_STATE=MERGED run 0 --dir "$REPO5" --yes
grep -q "^pr close" "$CALL_LOG" && fail "MERGED proposal_pr should never be closed"
[ ! -e "$REPO5/.temperloop" ] || fail "MERGED proposal_pr revert did not remove .temperloop/"
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
#    .temperloop/config is rewritten with only that unresolved entry,
#    exit 1; a re-run retries only it.
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
seed_config "$REPO7" '[
  {"type":"label","repo":"acme/widget","name":"fnd:status:backlog"},
  {"type":"label","repo":"acme/widget","name":"fnd:status:ready"}
]'
FAKE_LABEL_DELETE_RC=1 FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready" \
  run 1 --dir "$REPO7" --yes
echo "$out" | grep -q "temperloop eject: incomplete" || fail "partial failure did not report incomplete (got: $out)"
[ -f "$REPO7/.temperloop/config" ] || fail "partial failure removed .temperloop/config (should be kept for retry)"
cfg="$(cat "$REPO7/.temperloop/config")"
[ "$(jq '.installs | length' <<<"$cfg")" -eq 2 ] || fail "partial-failure config should keep both unresolved label entries (got: $(jq -c '.installs' <<<"$cfg"))"

# Re-run: now the deletes succeed -> fully resolved this time
FAKE_LABEL_DELETE_RC=0 run 0 --dir "$REPO7" --yes
[ ! -e "$REPO7/.temperloop" ] || fail "retry after partial failure did not fully revert"
echo "PASS: a failed revert keeps only the unresolved entries in .temperloop/config, exit 1; retry resolves them"

# =============================================================================
# 8. Offline (--no-network): every install skipped, zero gh calls, config
#    left in place with every entry still recorded
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
seed_config "$REPO8" '[{"type":"label","repo":"acme/widget","name":"fnd:status:backlog"}]'
run 1 --dir "$REPO8" --yes --no-network
[ ! -s "$CALL_LOG" ] || fail "--no-network made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -f "$REPO8/.temperloop/config" ] || fail "--no-network removed .temperloop/config (should be kept)"
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

# =============================================================================
# 10. temperloop#414 — .temperloop/ residue with NO .temperloop/config
#     (init.sh Step 0 writes baseline.jsonl BEFORE config ever exists) is
#     recognized and cleaned up: the old config-gated no-op used to miss
#     this entirely ("nothing to eject" over real residue). Zero gh calls
#     (nothing was ever recorded), no branch change (never switched off the
#     original branch — Step 0 never touches branches).
# =============================================================================
REPO10="$(new_fixture_repo repo10)"
mkdir -p "$REPO10/.temperloop"
printf 'baseline.jsonl\n' > "$REPO10/.temperloop/.gitignore"
printf '{"schema":1,"generated_at":"2026-01-01T00:00:00Z","metrics":{"available":false}}\n' \
  > "$REPO10/.temperloop/baseline.jsonl"
BEFORE_BRANCH10="$(git -C "$REPO10" branch --show-current)"
run 0 --dir "$REPO10" --yes
[ ! -s "$CALL_LOG" ] || fail "partial-residue cleanup made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ ! -e "$REPO10/.temperloop" ] || fail "partial-residue cleanup did not remove .temperloop/"
[ "$(git -C "$REPO10" branch --show-current)" = "$BEFORE_BRANCH10" ] \
  || fail "partial-residue cleanup switched branches unexpectedly"
echo "$out" | grep -q "Partial-init residue" || fail "did not report the partial-init-residue path (got: $out)"
echo "PASS: .temperloop/ residue with no config (Step-0 baseline.jsonl only) is recognized and cleaned up, zero gh calls, no branch change"

# --- same residue path honors --dry-run and non-interactive default-deny --
REPO10B="$(new_fixture_repo repo10b)"
mkdir -p "$REPO10B/.temperloop"
printf 'baseline.jsonl\n' > "$REPO10B/.temperloop/baseline.jsonl"
run 0 --dir "$REPO10B" --dry-run
[ ! -s "$CALL_LOG" ] || fail "dry-run on partial residue made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -e "$REPO10B/.temperloop" ] || fail "dry-run removed partial residue (should be untouched)"
echo "$out" | grep -q "Dry run: would remove" || fail "dry-run did not report what it would remove (got: $out)"

run 0 --dir "$REPO10B"
[ ! -s "$CALL_LOG" ] || fail "non-interactive default-deny on partial residue made gh calls (should be zero):\n$(cat "$CALL_LOG")"
[ -e "$REPO10B/.temperloop" ] || fail "non-interactive default-deny removed partial residue (should be untouched)"
echo "$out" | grep -q "aborted — nothing removed" || fail "non-interactive default-deny on partial residue did not report the abort (got: $out)"
echo "PASS: partial-init residue honors --dry-run and non-interactive default-deny exactly like the config-manifest path"

# =============================================================================
# 11. End-to-end partial-init -> eject recovery (temperloop#414): a REAL
#     'temperloop init' run that dies AFTER its branch switch
#     (proposal-pr.sh's `git checkout -B`) — simulated deterministically by
#     breaking the push (removing the bare upstream after cloning) rather
#     than a literal kill, so the test is hermetic/portable; the resulting
#     on-disk state (checked out on the stray proposal branch,
#     .temperloop/config committed there, .temperloop/.recovery.json
#     present, nothing ever pushed) is identical to what an interrupting
#     kill mid-push would leave. 'temperloop eject' must then restore the
#     original branch, delete the stray unmerged local branch, and remove
#     .temperloop/ — leaving the checkout byte-identical to before init ran.
# =============================================================================
BARE11="$WORK/repo11-upstream.git"
REPO11="$WORK/repo11"
git init -q --bare --initial-branch=main "$BARE11"
git clone -q "$BARE11" "$REPO11" 2>/dev/null
git -C "$REPO11" commit -q --allow-empty -m init
git -C "$REPO11" push -q origin main 2>/dev/null
git -C "$REPO11" fetch -q origin

BEFORE_HEAD11="$(git -C "$REPO11" rev-parse HEAD)"
BEFORE_BRANCH11="$(git -C "$REPO11" branch --show-current)"
BEFORE_FIND11="$(find "$REPO11" -mindepth 1 -not -path '*/.git*' | sort)"

# Break the push deterministically: remove the bare upstream AFTER cloning
# (the local refs/remotes/origin/main ref already exists, so base-branch
# resolution inside proposal-pr.sh still succeeds; only the push fails).
rm -rf "$BARE11"

run_init --dir "$REPO11" --gh-repo acme/widget --no-network
[ "$init_rc" -ne 0 ] || fail "test setup: expected the broken-push init run to fail (got rc=0): $init_out"
echo "$init_out" | grep -q "proposal-pr.sh failed" || fail "test setup: init did not fail at the expected proposal-pr step (got: $init_out)"
[ "$(git -C "$REPO11" branch --show-current)" = "foundation-init/config" ] \
  || fail "test setup: expected the failed init run to leave the checkout on foundation-init/config"
[ -f "$REPO11/.temperloop/config" ] || fail "test setup: expected .temperloop/config committed locally despite the push failure"
[ -f "$REPO11/.temperloop/.recovery.json" ] || fail "test setup: expected the recovery marker to survive the failed run"
[ "$(jq -r '.original_branch' "$REPO11/.temperloop/.recovery.json")" = "main" ] \
  || fail "test setup: recovery marker original_branch wrong (got: $(cat "$REPO11/.temperloop/.recovery.json"))"

run 0 --dir "$REPO11" --yes
echo "$out" | grep -q "restored 'main'" || fail "eject did not report restoring the original branch (got: $out)"
echo "$out" | grep -q "deleted stray 'foundation-init/config'" || fail "eject did not report deleting the stray branch (got: $out)"
[ "$(git -C "$REPO11" branch --show-current)" = "$BEFORE_BRANCH11" ] \
  || fail "eject did not restore the original branch (on: $(git -C "$REPO11" branch --show-current))"
git -C "$REPO11" show-ref --verify --quiet refs/heads/foundation-init/config \
  && fail "eject did not delete the stray local branch"
[ ! -e "$REPO11/.temperloop" ] || fail "eject did not remove .temperloop/ residue"
[ "$(git -C "$REPO11" rev-parse HEAD)" = "$BEFORE_HEAD11" ] \
  || fail "eject left HEAD different from before the failed init run"
[ -z "$(git -C "$REPO11" status --porcelain)" ] \
  || fail "eject left an uncommitted/dirty tree (status: $(git -C "$REPO11" status --porcelain))"
AFTER_FIND11="$(find "$REPO11" -mindepth 1 -not -path '*/.git*' | sort)"
[ "$AFTER_FIND11" = "$BEFORE_FIND11" ] \
  || fail "eject left extra files behind (before:\n$BEFORE_FIND11\nafter:\n$AFTER_FIND11)"
echo "PASS: a real 'temperloop init' run that dies after its branch switch (broken push, standing in for a killed process) leaves .temperloop/config committed + a recovery marker on the stray branch; 'temperloop eject' restores the original branch, deletes the stray unmerged branch, and removes .temperloop/ — byte-identical to before init ran"

echo
echo "ALL PASS: test_eject.sh"
