#!/usr/bin/env bash
#
# Tests for init.sh — `temperloop init` (foundation #765 Epic D "newcomer
# experience", item foundation-init / #854). Board/proposal-toolkit fixture
# style: a throwaway real-git bare upstream + clone, a stubbed `gh` on
# PATH that LOGS every call it sees (the write-intercepting-wrapper proof:
# a denied/dry-run action must leave ZERO mutating gh calls in the log),
# zero network, structured-output assertions via jq.
#
# SCOPE-DOWN (temperloop#796): `init` no longer applies ANY API state. Its
# job is bootstrap `.temperloop/config` (+ its proposal PR) -> offer/file the
# first epic -> print the handoff -> stop. The flags that used to gate the
# retired applies (--yes/--no-required-check, --yes/--no-labels,
# --yes/--no-board, --provision-board, --tracker-mode projects) are RETAINED
# as deprecated no-ops, each with a named removal window — an ADOPTER's own
# wrapper script may pass any of them (VERSIONING.md's CLI-surface contract
# row covers `bin/subcommands/*`), and init.sh exits 2 on an unknown arg, so
# removing one early would hard-fail callers that cannot be enumerated from
# inside this repo. Several cases below therefore assert the INVERSE of what
# they once did: the flag parses, a deprecation notice fires, and ZERO
# mutating gh calls result.
#
# Covers:
#   - --dry-run + --no-network: tree-only preview, zero gh calls of any
#     kind (no api/label/project/pr create), config committed locally only
#   - non-interactive: no --yes-* flag + closed stdin -> the first-epic
#     offer skips, zero mutating gh calls, and a handoff line still prints
#   - deprecated apply flags (--yes-required-check --yes-labels): each
#     emits a deprecation notice naming where the step went, and NEITHER
#     fires a single mutating gh call; installs[] carries only the
#     proposal_pr entry
#   - round-trip: re-running against the same repo re-reads the prior
#     .temperloop/config (schema 1) and carries a PRE-SCOPE-DOWN adopter's
#     recorded label/required_check/board installs forward untouched, so
#     `temperloop eject` can still revert them
#   - boards.conf integration: when workflows/scripts/board/ exists in the
#     target repo, the rendered board.<N>.* entry is proposed into its
#     boards.conf; a second run with the entry already present leaves it
#     untouched (idempotent)
#   - REGRESSION PIN (temperloop#793/#796): the rendered boards.conf entry
#     is COMPLETE — `board.<N>.backend=issues` present, the literal
#     "FILL IN" absent — in BOTH .tracker.boards_conf_entry and the
#     proposed boards.conf. The retired `projects` arm emitted a commented
#     `# board.<N>.project=<FILL IN ...>` placeholder before the apply step
#     and never reassigned it, so a fully-consented run still shipped a
#     dangling contract past a green suite.
#   - --tracker-mode projects --provision-board --yes-board: all three are
#     deprecated no-ops — ZERO `gh project create` calls, the notices fire,
#     and tracker.mode is coerced to "issues"
#   - --provision-board without --tracker-mode projects: same no-op
#   - the scoped-down contract end to end: --yes-first-epic files the epic,
#     applies zero API state, and hands off with the `next step:` marker
#   - the decline floor is the durable re-offer pointer ALONE — no inline
#     principles interview (it is the epic's own L0 now, deferred)
#   - HANDOFF PREREQUISITE PROBE: a `prerequisite:` line appears when
#     ~/.claude/commands/assess.md is absent and not when it is present,
#     while the `next step:` marker itself stays byte-identical in both
#     states (install-tier2.yml greps it on a runner that has no ~/.claude/)
#   - invalid --tracker-mode -> usage error, exit 2 (still refused)
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
      *search/issues*"design-brief: docs/adr/0010-onboarding-as-first-executed-epic.md"*)
        # Idempotency probe for an already-filed first epic (temperloop#781
        # handoff-lastness test). Real gh applies the caller's own --jq
        # '.items[0].number // empty' to the raw search response; since this
        # fake never runs jq, it just prints the number directly — the same
        # thing that filter would have produced.
        [ -n "${FAKE_EXISTING_EPIC_NUM:-}" ] && printf '%s' "$FAKE_EXISTING_EPIC_NUM"
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
  issue)
    case "$2" in
      create)
        echo "https://github.com/${FAKE_GH_REPO:-acme/widget}/issues/${FAKE_ISSUE_NUM:-77}"
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
    FAKE_ISSUE_NUM="${FAKE_ISSUE_NUM:-77}" \
    FAKE_EXISTING_EPIC_NUM="${FAKE_EXISTING_EPIC_NUM:-}" \
    HOME="${FAKE_HOME:-$HOME}" \
    CALL_LOG="$CALL_LOG" \
    bash "$INIT" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for: $* -- output:\n$out"
}

call_count() {
  # call_count PATTERN — how many logged gh calls match (grep -c, fixed string)
  grep -Fc "$1" "$CALL_LOG" 2>/dev/null || true
}

# assert_no_mutating_gh LABEL — the scope-down's central invariant: `init`
# writes ZERO API state, whatever deprecated apply flags it was handed. A
# read-shaped `gh pr create` (the tree-only proposal step) and the
# first-epic `search/issues` idempotency probes are not API-state writes and
# are deliberately not covered here.
assert_no_mutating_gh() {
  local label="$1"
  grep -q "^label create" "$CALL_LOG" \
    && fail "$label: created a label (init applies no API state since temperloop#796)"
  grep -q "required_status_checks" "$CALL_LOG" \
    && fail "$label: wrote a required status check (init applies no API state since temperloop#796)"
  grep -q "^project create" "$CALL_LOG" \
    && fail "$label: provisioned a Projects-v2 board (dropped outright, temperloop#793)"
  return 0
}

# assert_complete_boards_entry LABEL ENTRY BOARD — the temperloop#793/#796
# regression pin. Every line the renderer emits must be a real,
# adapter-readable assignment; a commented `<FILL IN>` placeholder is
# exactly the dangling contract that survived a green suite before.
assert_complete_boards_entry() {
  local label="$1" entry="$2" board="$3"
  printf '%s\n' "$entry" | grep -q "board\.$board\.backend=issues" \
    || fail "$label: rendered entry missing board.$board.backend=issues (got: $entry)"
  printf '%s\n' "$entry" | grep -q "FILL IN" \
    && fail "$label: rendered entry still carries a 'FILL IN' placeholder (temperloop#793) (got: $entry)"
  return 0
}

# =============================================================================
# 1. --dry-run + --no-network: GENUINELY ZERO-WRITE (temperloop#413) — no
#    baseline.jsonl write, no .temperloop/config write, no commit, no
#    branch switch, and the target checkout is bit-identical (HEAD,
#    current branch, `git status --porcelain`, and the tree's file
#    listing all unchanged) before vs. after the dry run. Also zero gh
#    calls of any kind (unchanged from before this fix).
# =============================================================================
REPO1="$(new_fixture_repo repo1)"
BEFORE_HEAD="$(git -C "$REPO1" rev-parse HEAD)"
BEFORE_BRANCH="$(git -C "$REPO1" branch --show-current)"
BEFORE_STATUS="$(git -C "$REPO1" status --porcelain)"
BEFORE_FIND="$(find "$REPO1" -mindepth 1 -not -path '*/.git*' | sort)"

run 0 --dir "$REPO1" --gh-repo acme/widget --no-network --dry-run \
  --yes-required-check --yes-labels

[ ! -s "$CALL_LOG" ] || fail "dry-run made gh calls (should be zero):\n$(cat "$CALL_LOG")"
echo "$out" | grep -q 'would create: .temperloop/config' \
  || fail "dry-run did not print a tree-only preview of what it would write (got: $out)"
echo "$out" | grep -q 'skipped (--dry-run — tree-only preview, no baseline write)' \
  || fail "dry-run did not report the baseline snapshot as skipped (got: $out)"

AFTER_HEAD="$(git -C "$REPO1" rev-parse HEAD)"
AFTER_BRANCH="$(git -C "$REPO1" branch --show-current)"
AFTER_STATUS="$(git -C "$REPO1" status --porcelain)"
AFTER_FIND="$(find "$REPO1" -mindepth 1 -not -path '*/.git*' | sort)"

[ "$AFTER_HEAD" = "$BEFORE_HEAD" ] || fail "dry-run moved HEAD ($BEFORE_HEAD -> $AFTER_HEAD)"
[ "$AFTER_BRANCH" = "$BEFORE_BRANCH" ] || fail "dry-run switched branches ($BEFORE_BRANCH -> $AFTER_BRANCH)"
[ "$AFTER_STATUS" = "$BEFORE_STATUS" ] \
  || fail "dry-run left the working tree dirty (before status=[$BEFORE_STATUS] after status=[$AFTER_STATUS])"
[ "$AFTER_FIND" = "$BEFORE_FIND" ] \
  || fail "dry-run changed the tree's file listing (before:\n$BEFORE_FIND\nafter:\n$AFTER_FIND)"
[ ! -e "$REPO1/.temperloop/config" ] || fail "dry-run wrote .temperloop/config to disk"
[ ! -e "$REPO1/.temperloop/baseline.jsonl" ] \
  || fail "dry-run wrote .temperloop/baseline.jsonl (baseline snapshot must be gated by --dry-run)"
git -C "$REPO1" show HEAD:.temperloop/config >/dev/null 2>&1 \
  && fail "dry-run committed .temperloop/config locally (must be zero-write)"
echo "PASS: --dry-run + --no-network is genuinely zero-write — no baseline.jsonl, no .temperloop/config, no commit, HEAD/branch/tree bit-identical before vs. after, zero gh calls"

# =============================================================================
# 2. Non-interactive: no --yes-* flag, closed stdin -> the first-epic offer
#    skips (nobody answered, so nothing beyond the notice happens), zero
#    MUTATING gh calls, and the run still prints its handoff line. A
#    read-shaped `gh pr create` call still fires (the tree-only proposal
#    step is independent of the offer).
# =============================================================================
REPO2="$(new_fixture_repo repo2)"
FAKE_PR_NUM=20 run 0 --dir "$REPO2" --gh-repo acme/widget
assert_no_mutating_gh "non-interactive run"
echo "$out" | grep -q "first-epic: skipped — no interactive operator detected" \
  || fail "first-epic did not report the non-interactive skip (got: $out)"
echo "$out" | grep -q "^next step: " \
  || fail "run printed no handoff line (got: $out)"
echo "PASS: non-interactive, no --yes-* flags -> the first-epic offer skips, zero mutating gh calls, handoff still printed"

# =============================================================================
# 3. Deprecated apply flags: --yes-required-check --yes-labels still PARSE
#    (exit 0, never the exit-2 unknown-arg path), each emits a deprecation
#    notice naming where the step went, and NEITHER applies anything. The
#    only install this run mints is the proposal_pr self-record.
# =============================================================================
REPO3="$(new_fixture_repo repo3)"
FAKE_PR_NUM=21 run 0 --dir "$REPO3" --gh-repo acme/widget \
  --yes-required-check --yes-labels
assert_no_mutating_gh "deprecated --yes-required-check/--yes-labels"
echo "$out" | grep -q "DEPRECATED — --yes-required-check" \
  || fail "--yes-required-check fired no deprecation notice (got: $out)"
echo "$out" | grep -q "DEPRECATED — --yes-labels" \
  || fail "--yes-labels fired no deprecation notice (got: $out)"
echo "$out" | grep -q "first epic" \
  || fail "the required-check deprecation notice does not name where the step went (got: $out)"
echo "$out" | grep -q '"outcome": "PR_OPENED"' || fail "expected PR_OPENED outcome (got: $out)"

cfg="$(cat "$REPO3/.temperloop/config")"
[ "$(jq -r '.schema' <<<"$cfg")" = "1" ] || fail "landed config schema is not 1"
[ "$(jq -r '.tracker.mode' <<<"$cfg")" = "issues" ] || fail "landed config tracker.mode wrong"
[ "$(jq '[.installs[] | select(.type=="label" or .type=="required_check" or .type=="board")] | length' <<<"$cfg")" -eq 0 ] \
  || fail "installs[] recorded an API-state entry init no longer applies (got: $(jq -c '.installs' <<<"$cfg"))"
[ "$(jq -r '.installs[] | select(.type=="proposal_pr") | .pr_number' <<<"$cfg")" = "21" ] \
  || fail "installs[] missing/wrong proposal_pr entry (self-record second pass) (got: $(jq -c '.installs' <<<"$cfg"))"
assert_complete_boards_entry "deprecated-flags run" "$(jq -r '.tracker.boards_conf_entry' <<<"$cfg")" 1
echo "PASS: the deprecated apply flags parse, report where their step went, and apply nothing — installs[] carries only the proposal_pr self-record"

# =============================================================================
# 4. Round-trip + PRE-SCOPE-DOWN manifest carry-forward. A repo initialised
#    before temperloop#796 has real `label`/`required_check`/`board` entries
#    in its installs[]; `.temperloop/config`'s schema stays 1 and those
#    entries MUST survive a re-run untouched, because `temperloop eject`
#    still keeps all four handlers and is the only thing that can revert
#    that API state. Dropping them here would silently strand it.
# =============================================================================
legacy_cfg="$(jq -c '.installs = [
    {type:"label", repo:"acme/widget", name:"fnd:status:backlog"},
    {type:"required_check", repo:"acme/widget", branch:"main", name:"checks"},
    {type:"board", owner:"acme", project_number:99, url:"https://example.invalid/p/99"}
  ] + .installs' "$REPO3/.temperloop/config")"
printf '%s\n' "$legacy_cfg" > "$REPO3/.temperloop/config"
# Commit it: proposal-pr.sh re-creates the proposal branch fresh off the base
# tip on every run, which would refuse to run over an uncommitted change to a
# tracked file. init reads the config from the working tree before that.
git -C "$REPO3" add .temperloop/config
git -C "$REPO3" commit -q -m "seed a pre-scope-down install manifest"

FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=21 \
  run 0 --dir "$REPO3" --gh-repo acme/widget --yes-required-check --yes-labels
echo "$out" | grep -q "Found existing .temperloop/config (schema 1)" \
  || fail "round-trip did not detect+re-read the existing config (got: $out)"
assert_no_mutating_gh "round-trip re-run"
cfg2="$(cat "$REPO3/.temperloop/config")"
[ "$(jq -r '.schema' <<<"$cfg2")" = "1" ] || fail "round-trip changed the config schema (must stay 1)"
[ "$(jq '[.installs[] | select(.type=="label")] | length' <<<"$cfg2")" -eq 1 ] \
  || fail "round-trip dropped the pre-scope-down label install (got: $(jq -c '.installs' <<<"$cfg2"))"
[ "$(jq '[.installs[] | select(.type=="required_check")] | length' <<<"$cfg2")" -eq 1 ] \
  || fail "round-trip dropped the pre-scope-down required_check install (got: $(jq -c '.installs' <<<"$cfg2"))"
[ "$(jq -r '.installs[] | select(.type=="board") | .project_number' <<<"$cfg2")" = "99" ] \
  || fail "round-trip dropped the pre-scope-down board install (got: $(jq -c '.installs' <<<"$cfg2"))"
echo "PASS: round-trip re-reads schema 1 and carries a PRE-SCOPE-DOWN adopter's label/required_check/board installs forward, so eject can still revert them"

# =============================================================================
# 5. boards.conf integration: board toolkit present -> proposes the entry;
#    a second run with it already present leaves boards.conf untouched.
#    Real (non-dry-run) runs, since --dry-run is now zero-write (#413) and
#    no longer commits anything locally to inspect via `git show` — that
#    invariant is covered by test 1 above; this test's own job is the
#    boards.conf proposal + idempotent-re-run logic, unrelated to dry-run.
# =============================================================================
REPO5="$(new_fixture_repo repo5)"
mkdir -p "$REPO5/workflows/scripts/board"
echo "# marker" > "$REPO5/workflows/scripts/board/marker.txt"
git -C "$REPO5" add -A && git -C "$REPO5" commit -q -m "seed board toolkit"
FAKE_PR_NUM=22 run 0 --dir "$REPO5" --gh-repo acme/widget --no-network
proposed_conf="$(git -C "$REPO5" show HEAD:workflows/scripts/board/boards.conf 2>/dev/null || true)"
printf '%s\n' "$proposed_conf" | grep -q "board.1.repo=acme/widget" \
  || fail "boards.conf entry was not proposed when the board toolkit is present"
# REGRESSION PIN (temperloop#793/#796) — the PROPOSED boards.conf half.
assert_complete_boards_entry "proposed boards.conf" "$proposed_conf" 1
# ...and the .temperloop/config half, the surface an operator hand-applies
# from when the board toolkit is NOT present. Both are pinned because the
# retired projects arm poisoned both at once.
assert_complete_boards_entry "config tracker.boards_conf_entry" \
  "$(jq -r '.tracker.boards_conf_entry' "$REPO5/.temperloop/config")" 1

FAKE_PR_EXISTS=1 FAKE_PR_BRANCH="foundation-init/config" FAKE_PR_NUM=22 \
  run 0 --dir "$REPO5" --gh-repo acme/widget --no-network
echo "$out" | grep -q "already present — leaving" \
  || fail "second run did not detect the already-present boards.conf entry (got: $out)"
echo "PASS: boards.conf integration proposes a COMPLETE rendered entry (backend=issues, no 'FILL IN') into both the proposed boards.conf and .temperloop/config, idempotent on re-run"

# =============================================================================
# 6. --tracker-mode projects --provision-board --yes-board: ALL THREE are
#    deprecated no-ops (temperloop#793 dropped board provisioning from init
#    outright). The flags still parse — exit 0, never the exit-2 unknown-arg
#    path — each reports its deprecation, ZERO `gh project create` calls
#    fire, `projects` is coerced to `issues`, and the rendered entry is
#    complete. This is the case that used to provision a board AND emit a
#    `<FILL IN>` placeholder in the same run.
# =============================================================================
REPO6="$(new_fixture_repo repo6)"
FAKE_PR_NUM=23 FAKE_OWNER=acme FAKE_PROJECT_NUM=99 \
  run 0 --dir "$REPO6" --gh-repo acme/widget --tracker-mode projects --provision-board --yes-board
[ "$(call_count 'project create')" -eq 0 ] \
  || fail "board provisioning still fired: $(call_count 'project create') 'project create' call(s) (temperloop#793 dropped it)"
assert_no_mutating_gh "--tracker-mode projects --provision-board --yes-board"
echo "$out" | grep -q "DEPRECATED — --tracker-mode projects" \
  || fail "--tracker-mode projects fired no deprecation notice (got: $out)"
echo "$out" | grep -q "DEPRECATED — --provision-board" \
  || fail "--provision-board fired no deprecation notice (got: $out)"
echo "$out" | grep -q "DEPRECATED — --yes-board" \
  || fail "--yes-board fired no deprecation notice (got: $out)"
cfg6="$(cat "$REPO6/.temperloop/config")"
[ "$(jq -r '.tracker.mode' <<<"$cfg6")" = "issues" ] \
  || fail "--tracker-mode projects was not coerced to issues (got: $(jq -r '.tracker.mode' <<<"$cfg6"))"
[ "$(jq '[.installs[] | select(.type=="board")] | length' <<<"$cfg6")" -eq 0 ] \
  || fail "a board install entry was recorded (got: $(jq -c '.installs' <<<"$cfg6"))"
assert_complete_boards_entry "coerced projects run" "$(jq -r '.tracker.boards_conf_entry' <<<"$cfg6")" 1
echo "PASS: --tracker-mode projects / --provision-board / --yes-board all parse, report their deprecation, provision nothing, and coerce to a complete issues-only entry"

# =============================================================================
# 7. --provision-board WITHOUT --tracker-mode projects: same no-op
# =============================================================================
REPO7="$(new_fixture_repo repo7)"
FAKE_PR_NUM=24 run 0 --dir "$REPO7" --gh-repo acme/widget --provision-board --yes-board
[ "$(call_count 'project create')" -eq 0 ] || fail "board provisioning fired on the issues-only path"
echo "$out" | grep -q "DEPRECATED — --provision-board" \
  || fail "--provision-board fired no deprecation notice (got: $out)"
echo "PASS: --provision-board on the issues-only path is the same legible no-op"

# =============================================================================
# 8. THE SCOPED-DOWN CONTRACT END TO END (temperloop#796): --yes-first-epic
#    -> the epic is filed, the run HANDS OFF to /assess and STOPS. It must
#    apply zero API state on the way, and the `next step:` handoff marker
#    (what .github/workflows/install-tier2.yml greps for) must name the
#    filed epic number.
# =============================================================================
REPO8="$(new_fixture_repo repo8)"
FAKE_PR_NUM=25 FAKE_ISSUE_NUM=77 \
  run 0 --dir "$REPO8" --gh-repo acme/widget --yes-first-epic
[ "$(call_count 'issue create')" -eq 1 ] \
  || fail "expected exactly 1 'issue create' (the first epic), got $(call_count 'issue create')"
assert_no_mutating_gh "--yes-first-epic"
echo "$out" | grep -q "first-epic: filed .*#77" \
  || fail "first-epic was not reported as filed (got: $out)"
echo "$out" | grep -q "^next step: /assess --epic 77" \
  || fail "handoff line missing or does not name the filed epic (got: $out)"
echo "$out" | grep -q "temperloop init: done" || fail "run did not reach its closing line (got: $out)"
echo "PASS: --yes-first-epic files the epic, applies zero API state, and hands off with 'next step: /assess --epic <N>'"

# =============================================================================
# 8b. THE HANDOFF BOX IS THE TRUE LAST THING PRINTED (temperloop#781):
#     `temperloop init: done` now prints BEFORE the closing handoff box, not
#     after — so the operator's scrollback ends on the actionable handoff
#     (a visually distinct "not finished" banner + the exact launch-Claude
#     command + the exact `/assess --epic N` invocation + the full,
#     never-truncated epic URL), never on the bare done marker. This
#     inspects the actual TAIL of $out (reused from test 8 above, before
#     any later run() call overwrites it) rather than just asserting
#     presence anywhere in the output.
# =============================================================================
last_nonblank="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1)"
[ "$last_nonblank" != "temperloop init: done" ] \
  || fail "'temperloop init: done' is the LAST line printed — the handoff box must be last (got tail: $last_nonblank)"
printf '%s\n' "$last_nonblank" | grep -qF '====' \
  || fail "the last non-blank line is not the handoff box's closing border (got: $last_nonblank)"
done_line="$(printf '%s\n' "$out" | grep -n '^temperloop init: done$' | tail -1 | cut -d: -f1)"
handoff_hdr_line="$(printf '%s\n' "$out" | grep -n '^-- 5\. Handoff --$' | tail -1 | cut -d: -f1)"
[ -n "$done_line" ] && [ -n "$handoff_hdr_line" ] \
  || fail "could not locate both 'temperloop init: done' and the Handoff header in output (got: $out)"
[ "$done_line" -lt "$handoff_hdr_line" ] \
  || fail "'temperloop init: done' (output line $done_line) does not precede the Handoff block (output line $handoff_hdr_line) — it must print BEFORE, never after"
echo "$out" | grep -qF "    claude" \
  || fail "handoff box missing the exact command to launch Claude Code in this repo (got: $out)"
echo "$out" | grep -qF "Epic: https://github.com/acme/widget/issues/77" \
  || fail "handoff box missing the full (never-truncated) epic URL (got: $out)"
echo "$out" | grep -qi "NOT FINISHED" \
  || fail "handoff box does not state that configuration is not finished (got: $out)"
echo "PASS: the handoff box is the LAST thing printed — 'temperloop init: done' now precedes it, and the box carries the not-finished framing, the launch command, the exact /assess invocation, and the full epic URL"

# =============================================================================
# 9. Decline floor is the POINTER ALONE (temperloop#796, ADR 0010 amended):
#    --no-first-epic files the durable re-offer pointer and runs NO inline
#    principles interview — the interview is the epic's own L0, deferred.
#    Closed stdin proves it: the retired inline interview read from stdin,
#    so a run that still attempted it would take the empty-answer path and
#    print its own interview banner.
# =============================================================================
REPO9="$(new_fixture_repo repo9)"
FAKE_PR_NUM=26 FAKE_ISSUE_NUM=88 \
  run 0 --dir "$REPO9" --gh-repo acme/widget --no-first-epic
echo "$out" | grep -q "first-epic: declined" || fail "decline was not reported (got: $out)"
echo "$out" | grep -q "filed durable re-offer pointer .*#88" \
  || fail "decline did not file the durable re-offer pointer (got: $out)"
echo "$out" | grep -q "Inline principles interview" \
  && fail "decline still ran the retired INLINE principles interview banner (got: $out)"
echo "$out" | grep -q "Do you have existing engineering conventions" \
  && fail "decline still asked the retired inline A1 principles question (got: $out)"
echo "$out" | grep -q "^next step: " || fail "decline printed no handoff line (got: $out)"
echo "PASS: declining files the durable re-offer pointer as the WHOLE floor — no inline principles interview, handoff still printed"

# =============================================================================
# 10. HANDOFF PREREQUISITE PROBE. `/assess` and `/build` only exist on a
#     machine that ran `temperloop install` (which symlinks claude/* into
#     ~/.claude/), but the try -> try --demo -> init ladder otherwise needs
#     no machine-wide setup — so a stranger can reach the handoff with no
#     ~/.claude/commands/ at all. init probes for it and adds a
#     `prerequisite:` line when it's missing.
#
#     The load-bearing assertion is the one that holds in BOTH states: the
#     `next step: /assess --epic <N>` line is byte-identical either way.
#     .github/workflows/install-tier2.yml greps exactly that line on a CI
#     runner (where ~/.claude/ does NOT exist), so a probe that rewrote the
#     marker instead of adding a line would silently break that gate.
# =============================================================================
REPO10A="$(new_fixture_repo repo10a)"
FAKE_HOME="$WORK/home-no-install" && mkdir -p "$FAKE_HOME"
FAKE_HOME="$FAKE_HOME" FAKE_PR_NUM=27 FAKE_ISSUE_NUM=91 \
  run 0 --dir "$REPO10A" --gh-repo acme/widget --yes-first-epic
handoff_uninstalled="$(printf '%s\n' "$out" | grep '^next step: ' || true)"
printf '%s\n' "$out" | grep -q '^next step: /assess --epic 91' \
  || fail "uninstalled probe changed the stable handoff marker (got: $out)"
printf '%s\n' "$out" | grep -q '^prerequisite: .*temperloop install' \
  || fail "no prerequisite line when ~/.claude/commands/assess.md is absent (got: $out)"

REPO10B="$(new_fixture_repo repo10b)"
FAKE_HOME_INSTALLED="$WORK/home-installed"
mkdir -p "$FAKE_HOME_INSTALLED/.claude/commands"
echo "# assess" > "$FAKE_HOME_INSTALLED/.claude/commands/assess.md"
FAKE_HOME="$FAKE_HOME_INSTALLED" FAKE_PR_NUM=28 FAKE_ISSUE_NUM=91 \
  run 0 --dir "$REPO10B" --gh-repo acme/widget --yes-first-epic
handoff_installed="$(printf '%s\n' "$out" | grep '^next step: ' || true)"
printf '%s\n' "$out" | grep -q '^prerequisite: ' \
  && fail "prerequisite line printed even though ~/.claude/commands/assess.md exists (got: $out)"
[ "$handoff_installed" = "$handoff_uninstalled" ] \
  || fail "the 'next step:' marker differs between the installed and uninstalled probe states — install-tier2.yml greps it on a runner with no ~/.claude/:\n  installed:   $handoff_installed\n  uninstalled: $handoff_uninstalled"
echo "PASS: the handoff names its \`temperloop install\` prerequisite when /assess isn't installed, and the 'next step:' marker itself is byte-identical in both states"

# =============================================================================
# 11. invalid --tracker-mode -> usage error, exit 2
# =============================================================================
REPO10="$(new_fixture_repo repo10)"
run 2 --dir "$REPO10" --tracker-mode bogus
echo "$out" | grep -qi "tracker-mode must be" || fail "invalid --tracker-mode error message unclear (got: $out)"
echo "PASS: invalid --tracker-mode is refused with exit 2 (validation survives the deprecation)"

# =============================================================================
# 12. --dir not a git repo -> exit 1
# =============================================================================
mkdir -p "$WORK/not-a-repo"
run 1 --dir "$WORK/not-a-repo"
echo "$out" | grep -qi "not a git working tree" || fail "non-repo --dir error message unclear (got: $out)"
echo "PASS: --dir pointing outside a git working tree is refused with exit 1"

# =============================================================================
# 13. THE HANDOFF RECOVERS ON THE IDEMPOTENT ALREADY-FILED PATH (temperloop
#     #781): an operator who lost the first run's scrollback re-runs `init`
#     and must get the SAME actionable handoff — not just a bare "already
#     filed" notice. The search/issues idempotency probe (design-brief
#     marker) reports the epic as already filed via FAKE_EXISTING_EPIC_NUM;
#     `init` must recover the full epic URL (constructed from $gh_repo,
#     since the idempotency probe only ever returns a NUMBER) and print the
#     identical handoff box, with zero new 'issue create' calls.
# =============================================================================
REPO13="$(new_fixture_repo repo13)"
FAKE_EXISTING_EPIC_NUM=77 FAKE_PR_NUM=29 \
  run 0 --dir "$REPO13" --gh-repo acme/widget
[ "$(call_count 'issue create')" -eq 0 ] \
  || fail "idempotent already-filed path re-filed the epic: $(call_count 'issue create') 'issue create' call(s)"
echo "$out" | grep -q "first-epic: already filed as #77" \
  || fail "the already-filed idempotency notice did not fire (got: $out)"
echo "$out" | grep -q "^next step: /assess --epic 77" \
  || fail "idempotent re-run's handoff marker missing or does not name the existing epic (got: $out)"
echo "$out" | grep -qF "Epic: https://github.com/acme/widget/issues/77" \
  || fail "idempotent re-run did not recover the full epic URL for the recovery handoff (got: $out)"
echo "$out" | grep -qF "    claude" \
  || fail "idempotent re-run's handoff box missing the launch-Claude-Code command (got: $out)"
last_nonblank13="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1)"
[ "$last_nonblank13" != "temperloop init: done" ] \
  || fail "idempotent re-run: 'temperloop init: done' is the LAST line printed — the handoff box must be last"
printf '%s\n' "$last_nonblank13" | grep -qF '====' \
  || fail "idempotent re-run: the last non-blank line is not the handoff box's closing border (got: $last_nonblank13)"
echo "PASS: the idempotent already-filed path recovers the same actionable handoff (full epic URL + launch command), last, with zero re-filed issues"

echo
echo "ALL PASS: test_init.sh"
