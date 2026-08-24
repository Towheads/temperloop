#!/usr/bin/env bash
#
# Tests for testbed.sh — `temperloop testbed` (epic temperloop#1117, item
# testbed-command / #1229).
#
# Zero network. A fake `gh` AND a fake `git` sit on PATH ahead of the real
# ones, following bin/subcommands/tests/test_try.sh's wrapper pattern — this
# is the WRITE-INTERCEPTING WRAPPER the item's `--dry-run` acceptance
# criterion asks for, extended to `git` because this command's mutating step
# is a `git push --mirror`, not only a `gh` call:
#   - the fake `gh` logs every call it sees; a dry run's log is asserted to
#     contain ONLY read-shaped calls (`auth status`, `api user`,
#     `repo view`) and never `repo create` / `issue create` / `-X POST`.
#   - the fake `git` logs every call it sees and DELEGATES read-shaped calls
#     to the real binary, but never delegates a mutating verb (`push`,
#     `clone`, `commit`, ...) — so a dry-run leg cannot mutate the fixture
#     even by accident, and the log proves no such call was attempted.
#   - the fixture repo's file tree AND the XDG state dir that holds the
#     testbed record are diffed byte-for-byte before/after every zero-write
#     leg (proves testbed.sh itself writes nothing, anywhere).
#
# PER-STEP FLUSH IS PROVEN STRUCTURALLY, NOT BY READING THE FINAL FILE. The
# fakes SNAPSHOT the record file at the exact moment the mirror push and the
# issue copy are invoked, so T6 can assert the record already carried
# `repo_created` (and only that) when the push ran, and `mirror_pushed` (and
# not yet `issues_copied`) when the issue copy ran. A record written once at
# the end would pass a final-state assertion and fail these.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED="$HERE/../testbed.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
DISPATCHER="$REPO_ROOT/bin/temperloop"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/testbed-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REAL_GIT="$(command -v git)"
export REAL_GIT

# --- fixture git repo (built with the REAL git, before PATH is shadowed) ---
REPO="$WORK/test-repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" remote add origin "https://github.com/test-owner/test-repo.git"
echo one > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "chore: seed fixture"

# A plain, non-git directory — used to drive the PROVIDER's own pre-flight
# check to failure (its `skipped —` wording, distinct from the driver's
# `cannot proceed —`).
NOTREPO="$WORK/not-a-repo"
mkdir -p "$NOTREPO"

# --- machine-scoped state root the record library writes under ------------
STATE="$WORK/state"
mkdir -p "$STATE"
export XDG_STATE_HOME="$STATE"
RECORD_FILE="$STATE/temperloop/testbed-record.json"
export RECORD_FILE

SNAP_AT_PUSH="$WORK/record-at-push.json"
SNAP_AT_ISSUES="$WORK/record-at-issues.json"
export SNAP_AT_PUSH SNAP_AT_ISSUES

# --- fakes ----------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"
GH_CALL_LOG="$WORK/gh-calls.log"
GIT_CALL_LOG="$WORK/git-calls.log"
export GH_CALL_LOG GIT_CALL_LOG

cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "${1:-}" in
  auth)
    case "${2:-}" in
      status)
        # scope.sh's primary path: `gh auth status --json hosts`. The
        # scopes string is configurable per-test via FAKE_GH_SCOPES so a
        # test can assert both "has delete_repo" and "does not" without two
        # fakes — default has NO delete_repo (the common/unprivileged case).
        if printf '%s\n' "$*" | grep -- '--json' >/dev/null; then
          printf '{"hosts":{"github.com":[{"active":true,"scopes":"%s"}]}}\n' \
            "${FAKE_GH_SCOPES:-gist, repo, workflow}"
          exit 0
        fi
        exit "${FAKE_GH_AUTH_RC:-0}"
        ;;
    esac
    exit "${FAKE_GH_AUTH_RC:-0}"
    ;;
  api)
    case "${2:-}" in
      user) printf '%s\n' "${FAKE_GH_LOGIN:-test-owner}"; exit 0 ;;
    esac
    exit 0
    ;;
  repo)
    case "${2:-}" in
      # rc 1 == "no such repo" == the candidate name is FREE. This is the
      # read the driver's collision-safe uniquification is built on.
      view) exit "${FAKE_GH_REPO_VIEW_RC:-1}" ;;
      create)
        printf 'https://github.com/%s\n' "${3:-}"
        exit "${FAKE_GH_REPO_CREATE_RC:-0}"
        ;;
      delete)
        printf 'deleted %s\n' "${3:-}"
        exit "${FAKE_GH_REPO_DELETE_RC:-0}"
        ;;
    esac
    exit 0
    ;;
  issue)
    case "${2:-}" in
      list)
        # produce_issues' first call — snapshot the record AS IT STANDS at
        # the instant the issue-copy step begins.
        [ -f "$RECORD_FILE" ] && cp "$RECORD_FILE" "$SNAP_AT_ISSUES"
        printf '%s' "${FAKE_GH_ISSUES_JSON:-[]}"
        exit 0
        ;;
      create) printf 'https://github.com/test-owner/test-repo-testbed/issues/1\n'; exit 0 ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

cat > "$BIN/git" <<'FAKE_GIT_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_CALL_LOG"
for a in "$@"; do
  case "$a" in
    push|clone|commit|fetch|remote-add)
      # Mutating-shaped: NEVER delegated to the real binary, so no leg of
      # this suite can mutate anything through it.
      if [ "$a" = push ]; then
        # produce_git — snapshot the record AS IT STANDS at the instant the
        # mirror push begins.
        [ -f "$RECORD_FILE" ] && cp "$RECORD_FILE" "$SNAP_AT_PUSH"
      fi
      exit "${FAKE_GIT_MUTATE_RC:-0}"
      ;;
  esac
done
exec "$REAL_GIT" "$@"
FAKE_GIT_EOF
chmod +x "$BIN/git"

export PATH="$BIN:$PATH"

# --- helpers --------------------------------------------------------------
out=""
rc=0
run() {
  local expected="$1"; shift
  : > "$GH_CALL_LOG"
  : > "$GIT_CALL_LOG"
  set +e
  out="$(bash "$TESTBED" "$@" 2>&1 < /dev/null)"
  rc=$?
  set -e
  if [ "$expected" != "any" ] && [ "$rc" -ne "$expected" ]; then
    fail "expected exit $expected, got $rc\n--- output ---\n$out"
  fi
}

assert_contains() {
  case "$out" in
    *"$1"*) ;;
    *) fail "expected output to contain '$1'\n--- output ---\n$out" ;;
  esac
}

assert_not_contains() {
  case "$out" in
    *"$1"*) fail "expected output NOT to contain '$1'\n--- output ---\n$out" ;;
  esac
}

# The zero-write proof, applied to both logs at once.
assert_no_mutating_calls() {
  local label="$1" line
  while IFS= read -r line; do
    case "$line" in
      *"repo create"*|*"issue create"*|*"repo delete"*|*"-X POST"*|*"-X PATCH"*|*"-X DELETE"*|*"label create"*)
        fail "$label must issue no mutating gh call, got: $line"
        ;;
    esac
  done < "$GH_CALL_LOG"
  while IFS= read -r line; do
    case "$line" in
      *push*|*clone*|*commit*|*" init"*)
        fail "$label must issue no mutating git call, got: $line"
        ;;
    esac
  done < "$GIT_CALL_LOG"
}

tree_of() { (cd "$1" 2>/dev/null && find . -type f -exec shasum {} \; | sort) || true; }

# =============================================================================
# T1 -- REGISTRATION is the file's presence plus its `# description:` line
# under the dispatcher's existing discovery convention. No dispatch-table
# edit exists, and none is needed.
# =============================================================================
grep -q '^# description: ' "$TESTBED" \
  || fail "testbed.sh must carry a '# description: ' header line (the dispatcher's discovery convention)"

# The invariant is that `testbed` is registered by FILE DISCOVERY — never by
# a hand-edited dispatch branch in bin/temperloop. Exactly ONE mention is
# sanctioned: the help banner's `Start here:` pointer, which temperloop#1117
# flipped from `try` to `testbed` when `try` was retired. That line is prose
# inside a heredoc, not a dispatch branch, so it cannot register anything.
# Every OTHER occurrence still fails, which is what keeps a real dispatch-table
# edit (a `testbed)` case arm, a `_foundation_dispatch_testbed` helper, an
# `if [ "$cmd" = testbed ]`) caught here.
stray_testbed="$(grep -n 'testbed' "$DISPATCHER" \
  | grep -v '^[0-9]*:Start here: temperloop testbed$' || true)"
if [ -n "$stray_testbed" ]; then
  fail "bin/temperloop must contain NO reference to 'testbed' beyond the help banner's 'Start here:' line — registration is file discovery, never a dispatch-table edit (found: $stray_testbed)"
fi

help_out="$(bash "$DISPATCHER" help 2>&1)"
case "$help_out" in
  *"testbed"*) ;;
  *) fail "temperloop help must list the discovered 'testbed' subcommand, got:\n$help_out" ;;
esac
case "$help_out" in
  *"evaluation testbed"*) ;;
  *) fail "temperloop help must render testbed.sh's own '# description:' text, got:\n$help_out" ;;
esac
echo "PASS: registration — file presence + '# description:' line, zero dispatcher edits"

# =============================================================================
# T2 -- the driver is PROVIDER-AGNOSTIC: no `case` on provider kind anywhere.
# That per-provider branch is exactly what source.sh's four-function seam
# exists to eliminate downstream, so its absence is asserted structurally
# rather than left to review.
# =============================================================================
# Comments are stripped first: this file's own header DESCRIBES the branch it
# refuses to contain, and prose that names a construct is not that construct
# (the same comment-stripping convention check-setting-registry.sh applies to
# its own seam sweep).
if sed 's/[[:space:]]*#.*$//' "$TESTBED" \
    | grep -nE 'case[[:space:]]+"?\$\{?(source_kind|resolved_kind|kind)'; then
  fail "testbed.sh must contain no 'case' on the provider kind — the seam exists to eliminate it"
fi
for fn in testbed_source_describe testbed_source_preflight_checks \
          testbed_source_produce_git testbed_source_produce_issues \
          testbed_record_add testbed_record_mark_step; do
  grep -q "$fn" "$TESTBED" || fail "testbed.sh must call the landed seam function $fn, not reimplement it"
done
if grep -q '_testbed_provider_' "$TESTBED"; then
  fail "testbed.sh must never name a provider's own functions directly — it dispatches through the seam"
fi
echo "PASS: provider-agnostic driver — no kind branch, both seams consumed by their public API"

# =============================================================================
# T3 -- --dry-run performs ZERO WRITES: proven by the fake gh/git call logs
# plus a before/after file-tree diff of BOTH the source checkout and the XDG
# state dir. Runs with a non-tty stdin and NO --yes, which a real run would
# refuse — a preview must stay runnable unattended.
# =============================================================================
repo_before="$(tree_of "$REPO")"
state_before="$(tree_of "$STATE")"

run 0 --dir "$REPO" --dry-run

repo_after="$(tree_of "$REPO")"
state_after="$(tree_of "$STATE")"
[ "$repo_before" = "$repo_after" ] || fail "--dry-run must never write to the source checkout"
[ "$state_before" = "$state_after" ] || fail "--dry-run must never write the testbed record (XDG state dir changed)"
[ ! -f "$RECORD_FILE" ] || fail "--dry-run must not create $RECORD_FILE"
assert_no_mutating_calls "--dry-run"
assert_contains "[dry-run] would run: gh repo create test-owner/test-repo-testbed --private"
assert_contains "[dry-run] would run: produce_git"
assert_contains "[dry-run] would run: produce_issues"
assert_contains "nothing is created, so there is nothing to consent to"
# The read-shaped calls it DID make are the pre-flight reads, and they ran.
grep -q "auth status" "$GH_CALL_LOG" || fail "--dry-run should still run the all-reads pre-flight (gh auth status)"
grep -q "repo view" "$GH_CALL_LOG" || fail "--dry-run should still resolve a collision-free name (gh repo view)"
echo "PASS: --dry-run — zero writes (fake gh/git logs + before/after tree diff), pre-flight still ran"

# =============================================================================
# T4 -- the CONSENT GATE refuses on a non-tty stdin with no --yes. The guard
# `try --demo` established, carried to a command that now creates REAL remote
# repositories — so the refusal must also leave nothing behind.
# =============================================================================
run 1 --dir "$REPO"
assert_contains "refusing to run non-interactively without --yes"
assert_contains "Nothing was created."
assert_no_mutating_calls "a refused consent gate"
[ ! -f "$RECORD_FILE" ] || fail "a refused consent gate must not create $RECORD_FILE"
echo "PASS: consent gate — refuses a non-tty stdin with no --yes, zero writes"

# =============================================================================
# T5 -- PRE-FLIGHT IS ALL READS, and either half of the union refuses
# legibly and writes nothing:
#   (a) a DRIVER check fails with `cannot proceed — <fix>`
#   (b) a PROVIDER check fails with `skipped — <fix>`
# =============================================================================
FAKE_GH_AUTH_RC=1 run 1 --dir "$REPO" --yes
assert_contains "cannot proceed — gh is not authenticated (run: gh auth login)"
assert_contains "pre-flight failed; nothing was created"
assert_no_mutating_calls "a failed driver pre-flight check"
[ ! -f "$RECORD_FILE" ] || fail "a failed pre-flight must not create $RECORD_FILE"
echo "PASS: pre-flight (driver half) — 'cannot proceed —' names the fix, zero writes"

run 1 --dir "$NOTREPO" --yes
assert_contains "skipped —"
assert_contains "is not a git working tree"
assert_contains "pre-flight failed; nothing was created"
assert_no_mutating_calls "a failed provider pre-flight check"
[ ! -f "$RECORD_FILE" ] || fail "a failed pre-flight must not create $RECORD_FILE"
echo "PASS: pre-flight (provider half) — 'skipped —' names the fix, zero writes"

# =============================================================================
# T6 -- the FIXED DRIVER, end to end: create repo -> flush -> produce_git ->
# flush -> produce_issues -> flush -> handoff. Asserted by the record's state
# AT each step (snapshotted by the fakes), not just its final state.
# =============================================================================
export FAKE_GH_ISSUES_JSON='[{"number":7,"title":"seed bug","body":"the body"}]'
rm -f "$SNAP_AT_PUSH" "$SNAP_AT_ISSUES"

run 0 --dir "$REPO" --yes

[ -f "$RECORD_FILE" ] || fail "a completed run must write $RECORD_FILE"
key="test-owner/test-repo-testbed"

entry="$(jq -c --arg k "$key" '.testbeds[$k][0]' "$RECORD_FILE")"
[ "$entry" != "null" ] || fail "record must carry an entry keyed by the CREATED testbed's own owner/name ($key), got: $(cat "$RECORD_FILE")"
[ "$(jq -r '.source_kind' <<<"$entry")" = "mirror-from-repo" ] || fail "source_kind must come from describe(), got: $entry"
[ "$(jq -r '.source_repo' <<<"$entry")" = "test-owner/test-repo" ] || fail "source_repo must be the source's own slug, got: $entry"
[ "$(jq -r '.promotable' <<<"$entry")" = "true" ] || fail "promotable must come from describe(), got: $entry"
[ "$(jq -r '.artifacts | .repo_created and .mirror_pushed and .issues_copied' <<<"$entry")" = "true" ] \
  || fail "every artifact must be flushed true by the end, got: $entry"

# --- the per-step flush proof ---------------------------------------------
[ -f "$SNAP_AT_PUSH" ] || fail "the mirror push must run AFTER the record exists (no snapshot was taken)"
at_push="$(jq -c --arg k "$key" '.testbeds[$k][0].artifacts' "$SNAP_AT_PUSH")"
[ "$(jq -r '.repo_created' <<<"$at_push")" = "true" ] || fail "repo_created must already be flushed when produce_git runs, got: $at_push"
[ "$(jq -r '.mirror_pushed' <<<"$at_push")" = "false" ] || fail "mirror_pushed must NOT be flushed before produce_git runs, got: $at_push"
[ "$(jq -r '.issues_copied' <<<"$at_push")" = "false" ] || fail "issues_copied must NOT be flushed before produce_git runs, got: $at_push"

[ -f "$SNAP_AT_ISSUES" ] || fail "the issue copy must run AFTER the record exists (no snapshot was taken)"
at_issues="$(jq -c --arg k "$key" '.testbeds[$k][0].artifacts' "$SNAP_AT_ISSUES")"
[ "$(jq -r '.mirror_pushed' <<<"$at_issues")" = "true" ] || fail "mirror_pushed must be flushed BEFORE produce_issues runs, got: $at_issues"
[ "$(jq -r '.issues_copied' <<<"$at_issues")" = "false" ] || fail "issues_copied must NOT be flushed before produce_issues runs, got: $at_issues"

# --- the provider, not the driver, stamps provenance ----------------------
grep -q "copied from test-owner/test-repo#7" "$GH_CALL_LOG" \
  || fail "produce_issues must stamp its own 'copied from <owner>/<repo>#<N>' provenance line; log: $(cat "$GH_CALL_LOG")"

# --- the handoff block ----------------------------------------------------
assert_contains "https://github.com/test-owner/test-repo-testbed"
assert_contains "    cd test-repo-testbed"
assert_contains "    temperloop init"
assert_contains "next step: temperloop init"
assert_contains "YOUR EVALUATION TESTBED IS READY"
# Nothing is printed after the handoff (temperloop#781): its closing rule is
# the very last non-empty line of the run.
last_line="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n1)"
case "$last_line" in
  ================================================================) ;;
  *) fail "the handoff must be the LAST thing printed, got last line: $last_line" ;;
esac
echo "PASS: fixed driver end to end — per-step flush proven at each step, handoff prints URL + cd + next command"

# =============================================================================
# T7 -- --teardown WITHOUT the delete_repo scope degrades LEGIBLY (epic
# #1117 Produces 7, temperloop#1231): exits 0, prints the one-line
# `gh auth refresh -s delete_repo` remedy, issues NO mutating gh call, and
# leaves the T6 record entry untouched. `gh auth login`'s default scope set
# does not include delete_repo, so this is the common case, not an edge one.
# =============================================================================
key="test-owner/test-repo-testbed"
[ -f "$RECORD_FILE" ] || fail "T7 setup: expected the T6 record entry to still exist at $key"
record_before="$(cat "$RECORD_FILE")"

export FAKE_GH_SCOPES="gist, repo, workflow"   # no delete_repo
run 0 --teardown --repo "$key" --yes
assert_contains "gh auth refresh -s delete_repo"
assert_no_mutating_calls "--teardown without the delete_repo scope"
[ "$(cat "$RECORD_FILE")" = "$record_before" ] || fail "T7: teardown without delete_repo scope must not modify the record, got: $(cat "$RECORD_FILE")"
echo "PASS: --teardown without delete_repo scope — exits 0, prints the 'gh auth refresh -s delete_repo' remedy, zero mutating calls, record untouched"

# =============================================================================
# T8 -- --teardown WITH the delete_repo scope. --dry-run first (same
# zero-write proof style as T3), then a real run that resolves the target
# from a cwd with NO relation to the checkout that created the testbed — a
# bare directory whose only connection is its 'origin' remote — proving
# resolution is via the MACHINE-scoped record (record.sh), never a
# tree-relative path.
# =============================================================================
TBCLONE="$WORK/tb-checkout"
mkdir -p "$TBCLONE"
git -C "$TBCLONE" init -q -b main
git -C "$TBCLONE" remote add origin "https://github.com/test-owner/test-repo-testbed.git"

export FAKE_GH_SCOPES="gist, delete_repo, repo"

record_before="$(cat "$RECORD_FILE")"
run 0 --teardown --dir "$TBCLONE" --dry-run
assert_contains "[dry-run] would run: gh repo delete test-owner/test-repo-testbed --yes"
assert_no_mutating_calls "--teardown --dry-run (delete_repo scope present)"
[ "$(cat "$RECORD_FILE")" = "$record_before" ] || fail "T8: --teardown --dry-run must not modify the record, got: $(cat "$RECORD_FILE")"
echo "PASS: --teardown --dry-run — zero writes even with the scope present"

run 0 --teardown --dir "$TBCLONE" --yes
assert_contains "Deleted test-owner/test-repo-testbed"
grep -q "^repo delete test-owner/test-repo-testbed --yes" "$GH_CALL_LOG" \
  || fail "T8: expected a 'gh repo delete test-owner/test-repo-testbed --yes' call, log: $(cat "$GH_CALL_LOG")"
[ "$(jq -c --arg k "$key" '.testbeds[$k] // []' "$RECORD_FILE")" = "[]" ] \
  || fail "T8: record entry for $key must be removed after teardown, got: $(cat "$RECORD_FILE")"
echo "PASS: --teardown with delete_repo scope — resolved from a DIFFERENT cwd than the source checkout (via --dir's origin remote, never a tree-relative path), repo deleted, record entry removed"

# =============================================================================
# T9 -- --teardown removes a PARTIAL-FAILURE entry too: artifacts.
# repo_created=true is the only artifact ever guaranteed by
# testbed_record_add ("creation IS the repo-created mutating step"), and
# that alone is enough — teardown never requires a complete artifacts map,
# since the record's own repo_created=true already means a real repo exists
# to delete.
# =============================================================================
# shellcheck source=../../../workflows/scripts/testbed/record.sh
. "$REPO_ROOT/workflows/scripts/testbed/record.sh"
partial_key="test-owner/partial-testbed"
partial_id="$(testbed_record_add "$partial_key" "mirror-from-repo" "test-owner/test-repo" "true")"
[ -n "$partial_id" ] || fail "T9 setup: testbed_record_add failed"
entry_before="$(jq -c --arg k "$partial_key" --arg i "$partial_id" '.testbeds[$k][] | select(.id==$i)' "$RECORD_FILE")"
[ "$(jq -r '.artifacts.mirror_pushed' <<<"$entry_before")" = "false" ] || fail "T9 setup: expected mirror_pushed=false, got: $entry_before"
[ "$(jq -r '.artifacts.issues_copied' <<<"$entry_before")" = "false" ] || fail "T9 setup: expected issues_copied=false, got: $entry_before"

run 0 --teardown --repo "$partial_key" --id "$partial_id" --yes
assert_contains "Deleted $partial_key"
[ "$(jq -c --arg k "$partial_key" '.testbeds[$k] // []' "$RECORD_FILE")" = "[]" ] \
  || fail "T9: a partial-failure record entry must still be removed by teardown, got: $(cat "$RECORD_FILE")"
echo "PASS: --teardown removes a partial-failure record entry (repo_created only) without requiring a complete artifacts map"

# =============================================================================
# T10 -- teardown is a MODE on `temperloop testbed`, never a second
# subcommand: no separate bin/subcommands/teardown.sh (or similar) exists,
# and the dispatcher — file-discovery only, per T1 — has nothing new to
# discover, so `temperloop help`'s output is byte-for-byte unchanged.
# =============================================================================
[ ! -f "$REPO_ROOT/bin/subcommands/teardown.sh" ] \
  || fail "T10: teardown must be a --teardown MODE on testbed.sh, not its own bin/subcommands/teardown.sh"
help_out2="$(bash "$DISPATCHER" help 2>&1)"
[ "$help_out2" = "$help_out" ] \
  || fail "T10: --teardown must add NO new dispatcher-discovered subcommand; \`temperloop help\` changed:\n$help_out2"
echo "PASS: --teardown is a mode on testbed.sh, not a second subcommand — no new subcommand file, 'temperloop help' unchanged"

# =============================================================================
# T11 -- the DRIVER's seed-dir PASS-THROUGH, through the MUTATING steps
# (temperloop#1288). `--source-kind materialize-from-seed` must complete
# produce_git AND produce_issues against the IN-TREE default seed
# (workflows/scripts/demo/seed), from a `--dir` that is some other checkout
# entirely.
#
# WHY THIS TEST EXISTS AND WHY IT LIVES HERE. #1288's defect was a DRIVER
# argument bug: the driver handed materialize-from-seed's produce_git /
# produce_issues its own `--dir` value (always `.` after the cd to the
# source toplevel), and `_testbed_seed_dir` takes any non-empty argument
# LITERALLY — so the provider's in-tree default was never reached and every
# real run died at step 5 with "seed project tree not found at ./project".
# Nothing caught it: test_testbed_source.sh calls the provider's functions
# DIRECTLY with no argument (the default resolves correctly, the driver is
# never involved); test_provider_equivalence.sh drives the real driver but
# substitutes DOUBLE providers for produce_git/produce_issues; and
# test_seed_source_dir_seam.sh drives the real driver with the real provider
# but only through `--dry-run`, which stops before the mutating steps this
# bug lived in. This leg closes exactly that hole — the real driver, the
# real provider, past the consent gate, through both mutating seam calls.
#
# It DISCRIMINATES: `--dir` is the fixture repo, which has no `project/`
# tree, so a driver that re-passed `.` (or any `--dir`-derived value) here
# would fail step 5 outright rather than pass by coincidence.
# =============================================================================
SEED_DIR="$REPO_ROOT/workflows/scripts/demo/seed"
[ -d "$SEED_DIR/project" ] || fail "T11 setup: the in-tree seed is missing at $SEED_DIR"
seed_name="$(jq -r '.name' "$SEED_DIR/seed.json")"
seed_issue_count="$(find "$SEED_DIR/issues" -name '*.md' -type f | wc -l | tr -d ' ')"
[ "$seed_issue_count" -gt 0 ] || fail "T11 setup: the in-tree seed defines no issues"
first_seed_title="$(head -n 1 "$(find "$SEED_DIR/issues" -name '*.md' -type f | sort | head -n1)" | sed -E 's/^#[[:space:]]*//')"

run 0 --source-kind materialize-from-seed --dir "$REPO" --yes

# The two mutating seam calls both completed against the in-tree seed.
assert_contains "-- 5. Mirror the git history (provider seam: produce_git) --"
assert_contains "-- 6. Copy the open issues (provider seam: produce_issues) --"
assert_contains "created $seed_issue_count issue(s) on"
assert_contains "from the in-tree seed"
assert_contains "YOUR EVALUATION TESTBED IS READY"
# The pre-fix failure mode, named explicitly so a regression reads as itself.
assert_not_contains "seed project tree not found"
assert_not_contains "./project"

# produce_git actually pushed, and produce_issues actually filed one issue
# per seed definition — with the SEED's titles, not the fixture repo's.
grep -q "push --mirror" "$GIT_CALL_LOG" \
  || fail "T11: produce_git must reach a mirror push; git log: $(cat "$GIT_CALL_LOG")"
created="$(grep -c "^issue create" "$GH_CALL_LOG" || true)"
[ "$created" = "$seed_issue_count" ] \
  || fail "T11: expected $seed_issue_count 'gh issue create' calls (one per seed issue), got $created; log: $(cat "$GH_CALL_LOG")"
grep -qF -- "$first_seed_title" "$GH_CALL_LOG" \
  || fail "T11: the created issues must carry the SEED's own titles (expected '$first_seed_title'); log: $(cat "$GH_CALL_LOG")"
# provenance_capable:false means this provider never stamps a "copied from"
# line — there is no upstream issue to cite.
grep -q "copied from" "$GH_CALL_LOG" \
  && fail "T11: materialize-from-seed must stamp NO provenance line; log: $(cat "$GH_CALL_LOG")"

# The record is keyed by the SEED's own name (not the --dir checkout's), and
# carries a null source_repo — there is no upstream repository to name.
seed_key="test-owner/${seed_name}-testbed"
seed_entry="$(jq -c --arg k "$seed_key" '.testbeds[$k][0]' "$RECORD_FILE")"
[ "$seed_entry" != "null" ] \
  || fail "T11: record must carry an entry keyed by the SEED-derived name ($seed_key), got: $(cat "$RECORD_FILE")"
[ "$(jq -r '.source_kind' <<<"$seed_entry")" = "materialize-from-seed" ] \
  || fail "T11: source_kind must be materialize-from-seed, got: $seed_entry"
[ "$(jq -r '.source_repo' <<<"$seed_entry")" = "null" ] \
  || fail "T11: source_repo must be null for materialize-from-seed, got: $seed_entry"
[ "$(jq -r '.artifacts | .repo_created and .mirror_pushed and .issues_copied' <<<"$seed_entry")" = "true" ] \
  || fail "T11: every artifact must be flushed true by the end of a seed run, got: $seed_entry"
echo "PASS: driver pass-through — materialize-from-seed completes produce_git AND produce_issues against the in-tree default seed from an unrelated --dir"

echo "OK: test_testbed.sh"
