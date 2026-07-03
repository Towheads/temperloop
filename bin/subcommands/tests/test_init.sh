#!/usr/bin/env bash
#
# Tests for init.sh — `foundation init` (foundation #765 Epic D "newcomer
# experience", item foundation-init / #854). Board/proposal-toolkit fixture
# style: a throwaway real-git bare upstream + clone, a stubbed `gh` on
# PATH that LOGS every call it sees (the write-intercepting-wrapper proof:
# a denied/dry-run action must leave ZERO mutating gh calls in the log),
# zero network, structured-output assertions via jq.
#
# Covers:
#   - --dry-run + --no-network: tree-only preview, zero gh calls of any
#     kind (no api/label/project/pr create), config committed locally only
#   - non-interactive default-deny: no --yes-* flag + closed stdin ->
#     every consented-apply action declines, zero mutating gh calls
#   - consented apply (--yes-required-check --yes-labels): the exact gh
#     calls fire, and every side effect lands in .foundation/config's
#     installs array (the "install manifest" acceptance criterion)
#   - round-trip: re-running against the same repo re-reads the prior
#     .foundation/config (schema 1), carries its installs forward, and
#     skips re-creating a label gh already reports present (no duplicate
#     `label create` calls)
#   - boards.conf integration: when workflows/scripts/board/ exists in the
#     target repo, the rendered board.<N>.* entry is proposed into its
#     boards.conf; a second run with the entry already present leaves it
#     untouched (idempotent)
#   - --tracker-mode projects --provision-board (opt-in): the board
#     action is OFFERED only then, and a consented run provisions +
#     records it
#   - --provision-board without --tracker-mode projects: board action is
#     never offered (no gh project call)
#   - invalid --tracker-mode -> usage error, exit 2
#   - --dir not a git repo -> exit 1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$HERE/../init.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-test-XXXXXX")"
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

# --- fake gh: logs every call; a caller sets FAKE_GH_MODE to steer replies -
BIN="$WORK/bin"
mkdir -p "$BIN"
CALL_LOG="$WORK/gh-calls.log"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  api)
    case "$*" in
      *branches/*/protection*required_status_checks*)
        exit "${FAKE_REQUIRED_CHECK_RC:-0}"
        ;;
      */branches/*/protection*)
        echo "HTTP 404" >&2
        exit 1
        ;;
      */labels*)
        printf '[]'
        exit 0
        ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      list)
        printf '%s\n' $FAKE_EXISTING_LABELS
        exit 0
        ;;
      create)
        exit 0
        ;;
    esac
    exit 0
    ;;
  project)
    case "$2" in
      create)
        echo "https://github.com/orgs/${FAKE_OWNER:-acme}/projects/${FAKE_PROJECT_NUM:-42}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  pr)
    case "$2" in
      create)
        if [ -n "${FAKE_PR_EXISTS:-}" ]; then
          echo "a pull request for branch \"$FAKE_PR_BRANCH\" into branch \"main\" already exists: https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}" >&2
          exit 1
        fi
        echo "https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

export CALL_LOG

# run WANT_RC ARGS... — invoke init.sh with the fake gh on PATH, closed
# stdin (proves the non-interactive default-deny path unless a test
# explicitly wants otherwise), asserts exit code. Sets $out.
run() {
  local want="$1"
  shift
  : > "$CALL_LOG"
  local rc=0
  out="$(PATH="$BIN:$PATH" \
    FAKE_GH_REPO="${FAKE_GH_REPO:-acme/widget}" \
    FAKE_PR_NUM="${FAKE_PR_NUM:-}" \
    FAKE_PR_EXISTS="${FAKE_PR_EXISTS:-}" \
    FAKE_PR_BRANCH="${FAKE_PR_BRANCH:-}" \
    FAKE_REQUIRED_CHECK_RC="${FAKE_REQUIRED_CHECK_RC:-0}" \
    FAKE_EXISTING_LABELS="${FAKE_EXISTING_LABELS:-}" \
    FAKE_OWNER="${FAKE_OWNER:-acme}" \
    FAKE_PROJECT_NUM="${FAKE_PROJECT_NUM:-42}" \
    CALL_LOG="$CALL_LOG" \
    bash "$INIT" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for: $* -- output:\n$out"
}

call_count() {
  # call_count PATTERN — how many logged gh calls match (grep -c, fixed string)
  grep -Fc "$1" "$CALL_LOG" 2>/dev/null || true
}

# =============================================================================
# 1. --dry-run + --no-network: tree-only, ZERO gh calls of any kind
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
run 0 --dir "$REPO1" --gh-repo acme/widget --no-network --dry-run \
  --yes-required-check --yes-labels
[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q '"outcome": "DRY_RUN"' || fail "dry-run did not report DRY_RUN outcome (got: $out)"
git -C "$REPO1" show HEAD:.foundation/config >/dev/null 2>&1 \
  || fail "dry-run did not commit .foundation/config locally"
[ "$(jq -r '.schema' < <(git -C "$REPO1" show HEAD:.foundation/config))" = "1" ] \
  || fail "dry-run config schema is not 1"
echo "PASS: --dry-run + --no-network is tree-only (zero gh calls), commits config locally, schema 1"

# =============================================================================
# 2. Non-interactive default-deny: no --yes-* flag, closed stdin -> every
#    action declines, zero MUTATING gh calls (api PATCH / label create /
#    project create). A read-shaped `gh pr create` call still fires (the
#    proposal step is independent of the consented-apply gate).
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
FAKE_PR_NUM=20 run 0 --dir "$REPO2" --gh-repo acme/widget
grep -q "^label create" "$CALL_LOG" && fail "default-deny still created a label"
grep -q "required_status_checks" "$CALL_LOG" && fail "default-deny still wrote required-check"
grep -q "^project create" "$CALL_LOG" && fail "default-deny still provisioned a board"
echo "$out" | grep -q "required-check: no (skipped" || fail "required-check did not report default-deny (got: $out)"
echo "$out" | grep -q "labels: no (skipped" || fail "labels did not report default-deny (got: $out)"
echo "PASS: non-interactive, no --yes-* flags -> every consented-apply action defaults to no, zero mutating gh calls"

# =============================================================================
# 3. Consented apply: --yes-required-check --yes-labels -> the calls fire,
#    every side effect lands in .foundation/config's installs[]
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
FAKE_PR_NUM=21 run 0 --dir "$REPO3" --gh-repo acme/widget \
  --yes-required-check --yes-labels
[ "$(call_count 'required_status_checks')" -ge 1 ] || fail "required-check gh call missing"
[ "$(call_count 'label create')" -eq 6 ] || fail "expected 6 label create calls, got $(call_count 'label create')"
echo "$out" | grep -q '"outcome": "PR_OPENED"' || fail "expected PR_OPENED outcome (got: $out)"

cfg="$(cat "$REPO3/.foundation/config")"
[ "$(jq -r '.schema' <<<"$cfg")" = "1" ] || fail "landed config schema is not 1"
[ "$(jq -r '.tracker.mode' <<<"$cfg")" = "issues" ] || fail "landed config tracker.mode wrong"
[ "$(jq '[.installs[] | select(.type=="label")] | length' <<<"$cfg")" -eq 6 ] \
  || fail "installs[] missing the 6 label entries (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq '[.installs[] | select(.type=="required_check")] | length' <<<"$cfg")" -eq 1 ] \
  || fail "installs[] missing the required_check entry"
[ "$(jq -r '.installs[] | select(.type=="proposal_pr") | .pr_number' <<<"$cfg")" = "21" ] \
  || fail "installs[] missing/wrong proposal_pr entry (self-record second pass) (got: $(jq -c '.installs' <<<"$cfg"))"
echo "PASS: consented apply fires the right gh calls; every side effect (labels, required-check, the PR itself) is recorded in .foundation/config installs[]"

# =============================================================================
# 4. Round-trip: re-run against the SAME repo (now on the proposal branch
#    with .foundation/config present) — schema-1 re-read succeeds, prior
#    installs are carried forward, and gh reporting the labels as already
#    present means NO duplicate `label create` calls this time.
# =============================================================================
FAKE_EXISTING_LABELS="fnd:status:backlog fnd:status:ready fnd:status:in-progress needs-clarification funnel-escalated decision" \
FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=21 \
  run 0 --dir "$REPO3" --gh-repo acme/widget --yes-required-check --yes-labels
echo "$out" | grep -q "Found existing .foundation/config (schema 1)" \
  || fail "round-trip did not detect+re-read the existing config (got: $out)"
grep -q "^label create" "$CALL_LOG" && fail "round-trip re-created a label gh already reported present"
cfg2="$(cat "$REPO3/.foundation/config")"
[ "$(jq '[.installs[] | select(.type=="label")] | length' <<<"$cfg2")" -eq 6 ] \
  || fail "round-trip lost the carried-forward label installs (got: $(jq -c '.installs' <<<"$cfg2"))"
echo "PASS: round-trip (probe -> config -> init re-reads it) — schema-1 re-read, installs carried forward, no duplicate creates"

# =============================================================================
# 5. boards.conf integration: board toolkit present -> proposes the entry;
#    a second run with it already present leaves boards.conf untouched
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
mkdir -p "$REPO5/workflows/scripts/board"
echo "# marker" > "$REPO5/workflows/scripts/board/marker.txt"
git -C "$REPO5" add -A && git -C "$REPO5" commit -q -m "seed board toolkit"
FAKE_PR_NUM=22 run 0 --dir "$REPO5" --gh-repo acme/widget --no-network --dry-run
git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null | grep -q "board.1.repo=acme/widget" \
  || fail "boards.conf entry was not proposed when the board toolkit is present"
git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null | grep -q "board.1.backend=issues" \
  || fail "boards.conf entry missing backend=issues (issues-only default)"

FAKE_PR_NUM=22 run 0 --dir "$REPO5" --gh-repo acme/widget --no-network --dry-run
echo "$out" | grep -q "already present — leaving" \
  || fail "second run did not detect the already-present boards.conf entry (got: $out)"
echo "PASS: boards.conf integration proposes the rendered entry when the toolkit is present, idempotent on re-run"

# =============================================================================
# 6. --tracker-mode projects --provision-board (opt-in, consented): board
#    action IS offered and, on consent, provisions + records it
# =============================================================================
REPO6="$(new_fixture_repo repo6)"
FAKE_PR_NUM=23 FAKE_OWNER=acme FAKE_PROJECT_NUM=99 \
  run 0 --dir "$REPO6" --gh-repo acme/widget --tracker-mode projects --provision-board --yes-board
[ "$(call_count 'project create')" -eq 1 ] || fail "opt-in board provisioning did not call gh project create"
cfg6="$(cat "$REPO6/.foundation/config")"
[ "$(jq -r '.installs[] | select(.type=="board") | .project_number' <<<"$cfg6")" = "99" ] \
  || fail "board install entry missing/wrong project_number (got: $(jq -c '.installs' <<<"$cfg6"))"
[ "$(jq -r '.tracker.mode' <<<"$cfg6")" = "projects" ] || fail "tracker.mode not recorded as projects"
echo "PASS: --tracker-mode projects --provision-board (consented) provisions a board and records it in installs[]"

# =============================================================================
# 7. --provision-board WITHOUT --tracker-mode projects: never even offered
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
FAKE_PR_NUM=24 run 0 --dir "$REPO7" --gh-repo acme/widget --provision-board --yes-board
[ "$(call_count 'project create')" -eq 0 ] || fail "board provisioning fired despite tracker-mode staying issues"
echo "$out" | grep -q "nothing to provision" || fail "expected a 'nothing to provision' skip message (got: $out)"
echo "PASS: --provision-board is a no-op skip without --tracker-mode projects (issues-only stays the default)"

# =============================================================================
# 8. invalid --tracker-mode -> usage error, exit 2
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
run 2 --dir "$REPO8" --tracker-mode bogus
echo "$out" | grep -qi "tracker-mode must be" || fail "invalid --tracker-mode error message unclear (got: $out)"
echo "PASS: invalid --tracker-mode is refused with exit 2"

# =============================================================================
# 9. --dir not a git repo -> exit 1
# =============================================================================
mkdir -p "$WORK/not-a-repo"
run 1 --dir "$WORK/not-a-repo"
echo "$out" | grep -qi "not a git working tree" || fail "non-repo --dir error message unclear (got: $out)"
echo "PASS: --dir pointing outside a git working tree is refused with exit 1"

echo
echo "ALL PASS: test_init.sh"
