#!/usr/bin/env bash
#
# test_cli_entrypoint_no_graphql.sh — Zero-GraphQL CLI-entrypoint test
# (temperloop plan item `no-graphql-cli-test`).
#
# SCOPE (deliberately narrow — see "what this does NOT cover" below): this
# suite owns the CLI ENTRYPOINT surface — worklist.sh, claim.sh, capture.sh,
# reconcile.sh invoked AS COMMANDS (real subprocesses, `bash <script>.sh …`,
# not sourced) against a `backend=issues` board — and asserts, at the PROCESS
# level, that the cumulative `gh` invocation log carries ZERO `gh project …`
# and ZERO `gh api graphql …` calls across the whole run.
#
# THE GAP THIS CLOSES: board.sh's own issues-only branch points
# (board_resolve / board_resolve_item / board_item_list / board_set_status /
# board_stamp / board_create_many / board_capture_item) are already proven,
# at FUNCTION level, to route through plain REST (`gh issue …` / `gh api
# repos/…`) instead of Projects-v2 GraphQL:
#   - test_issues_backend.sh      lines ~139, 239, 309, 335
#   - test_issues_claim_edges.sh  line  ~109
#   - test_capture.sh             line  ~303
# Those suites source board.sh and override its `_board_gh` seam directly —
# they prove the LIBRARY never calls Projects-v2/GraphQL. They do NOT prove
# the four CLI SCRIPTS (as invoked by a human or an orchestrator: `bash
# worklist.sh …`) stay on that path end-to-end as real subprocesses — a CLI
# script could, in principle, bypass the board.sh adapter entirely and shell
# out to `gh project` or `gh api graphql` directly, and none of the
# function-level suites above would ever see it (they never exec the script
# as a command). reconcile.sh is the sharpest instance: test_reconcile.sh
# SOURCES reconcile.sh and drives reconcile_main/status_reconcile_main
# in-process — it carries ZERO assertions about which backend/call-shape a
# real `bash reconcile.sh …` invocation makes. This suite is that missing
# process-level proof, for reconcile.sh and its three siblings.
#
# What this does NOT cover (by design, not oversight — see the plan item's
# acceptance criteria): function-level behavior (label round-tripping, status
# semantics, contention handling) is the job of the suites listed above; this
# suite only asserts the CALL SHAPE a real CLI invocation makes, not the
# correctness of what the library does with that data.
#
# HARNESS: the PATH-shadowing "logging shim" pattern already established by
# test_board_dual_adapter.sh (the dual-adapter SAFE-TIER funnel-tick suite)
# and test_capture.sh's `--repo kernel` section — a fake `gh` binary placed
# first on PATH that appends every invocation's shell-quoted argv to a log
# file and serves canned JSON for the small, closed set of REST calls the
# issues-only backend issues. No new fake-gh convention: this file reuses
# that exact shape (one PATH-binary shim, log-then-serve, hard-fail on any
# unhandled or forbidden call) rather than inventing a third.
#
# `gh project *` and `gh api graphql` are additionally hard-refused BY THE
# FAKE ITSELF (not just absent from the canned-response menu) — belt and
# suspenders alongside the log-grep assertions below: if a CLI entrypoint
# ever regresses onto the Projects-v2 path, the fake gh refuses to serve it
# and the calling script fails loudly (non-zero exit) right there, not only
# via a downstream grep.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"

pass=0
fail_n=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail_n=$((fail_n + 1)); }

REPO="Acme/cli-entrypoint-test"   # denylist:allow — generic placeholder org/repo, no personal token

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cli-entrypoint-no-graphql-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- boards.conf: one issues-only board, a fresh logical number ------------
# (distinct from every other test fixture's board number in this dir — 3-10,
# 20-21, 30, 40-41, 60-61 are all spoken for; 25 is unused).
CONF="$TMP/boards.conf"
cat > "$CONF" <<EOF
board.25.repo=$REPO
board.25.owner=Acme
board.25.backend=issues
EOF
BOARD=25
NEW_ISSUE_NUM=503

GH_LOG="$TMP/gh.log"
: > "$GH_LOG"

# ---------------------------------------------------------------------------
# Fake gh (PATH-binary form). Two fixed issues (#501 Ready, #502 also Ready —
# the claim target) back `gh issue list`; #502/#503 back the single-issue
# `gh api repos/<repo>/issues/<n>` reads claim.sh/capture.sh's board.sh calls
# make. State is intentionally STATIC across calls within one invocation
# (this suite proves CALL SHAPE, not label/state round-tripping — that's
# test_issues_backend.sh / test_issues_claim_edges.sh's job) — every write
# (`issue edit` / `label create` / `issue close` / `issue reopen`) is a
# logged no-op.
# ---------------------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
: "${GH_LOG:?fake gh needs GH_LOG}"
: "${REPO:?fake gh needs REPO}"
: "${NEW_ISSUE_NUM:?fake gh needs NEW_ISSUE_NUM}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$GH_LOG"

sub="${1:-}"

# Hard-refuse the two forbidden call shapes THIS SUITE exists to catch — a
# structural belt-and-suspenders on top of the log-grep assertions below.
if [ "$sub" = "project" ]; then
  echo "fake gh: REFUSING 'gh project $*' — an issues-only-board CLI entrypoint must NEVER call gh project" >&2
  exit 3
fi
if [ "$sub" = "api" ] && [ "${2:-}" = "graphql" ]; then
  echo "fake gh: REFUSING 'gh api graphql' — an issues-only-board CLI entrypoint must NEVER call GraphQL" >&2
  exit 3
fi

ISSUE_LIST_JSON='[
  {"number":501,"title":"Ready item for worklist","labels":[{"name":"fnd:status:ready"},{"name":"spike"}],"milestone":null,"state":"OPEN","updatedAt":"2026-07-01T00:00:00Z"},
  {"number":502,"title":"Claim target","labels":[{"name":"fnd:status:ready"}],"milestone":null,"state":"OPEN","updatedAt":"2026-07-01T00:00:00Z"}
]'

case "$sub" in
  issue)
    icmd="${2:-}"
    case "$icmd" in
      list)   printf '%s' "$ISSUE_LIST_JSON" ;;
      create)
        prev=""
        for a in "$@"; do
          [ "$prev" = "--body" ] && : # body content unused by this suite
          prev="$a"
        done
        printf 'https://github.com/%s/issues/%s\n' "$REPO" "$NEW_ISSUE_NUM"
        ;;
      edit)   : ;;   # write no-op, already logged above
      close)  : ;;   # write no-op, already logged above
      reopen) : ;;   # write no-op, already logged above
      *) echo "fake gh: unhandled 'issue $icmd' (argv: $*)" >&2; exit 3 ;;
    esac
    ;;
  api)
    rest="${2:-}"
    case "$rest" in
      repos/*/issues/502) printf '{"number":502,"title":"Claim target","state":"open","labels":[{"name":"fnd:status:ready"}]}' ;;
      repos/*/issues/503) printf '{"number":503,"title":"fresh","state":"open","labels":[]}' ;;
      *) echo "fake gh: unhandled 'api $rest' (argv: $*)" >&2; exit 3 ;;
    esac
    ;;
  label)
    lcmd="${2:-}"
    case "$lcmd" in
      create) : ;;   # write no-op, already logged above
      *) echo "fake gh: unhandled 'label $lcmd' (argv: $*)" >&2; exit 3 ;;
    esac
    ;;
  pr)
    pcmd="${2:-}"
    case "$pcmd" in
      list) printf '[]' ;;
      *) echo "fake gh: unhandled 'pr $pcmd' (argv: $*)" >&2; exit 3 ;;
    esac
    ;;
  *) echo "fake gh: unexpected top-level subcommand '$sub' (argv: $*)" >&2; exit 3 ;;
esac
GHSCRIPT
chmod +x "$BIN/gh"

# Isolated sinks for the two side-channel logs claim.sh/capture.sh append to,
# so this suite never touches a real $HOME/dev/foundation raw lake.
CLAIMS_DIR="$TMP/claims-raw"
TOUCHES_DIR="$TMP/issue-touches-raw"
CACHE_DIR="$TMP/board-cache"
mkdir -p "$CLAIMS_DIR" "$TOUCHES_DIR" "$CACHE_DIR"

OUTLOG="$TMP/last-cli-output"
run_cli() {  # run_cli <label> -- <script-relative-path> <args...>
  local label="$1"; shift
  [ "$1" = "--" ] && shift
  local script="$1"; shift
  local rc=0
  PATH="$BIN:$PATH" \
    GH_LOG="$GH_LOG" REPO="$REPO" NEW_ISSUE_NUM="$NEW_ISSUE_NUM" \
    BOARDS_CONF_REPO_LOCAL="$CONF" BOARDS_CONF_MACHINE="$TMP/no-such-machine-conf" \
    BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$CACHE_DIR" BOARD_BUDGET_GUARD_THRESHOLD=0 \
    SUBSET_HOST_LABEL="testhost" CLAUDE_CODE_SESSION_ID="deadbeef-0000-0000-0000-000000000000" \
    CLAIMS_RAW_DIR="$CLAIMS_DIR" ISSUE_TOUCHES_RAW_DIR="$TOUCHES_DIR" \
    bash "$SCRIPTS_DIR/$script" "$@" >"$OUTLOG" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$label exits 0"
  else
    bad "$label" "exited $rc — output: $(cat "$OUTLOG")"
  fi
}

echo "--- test: CLI entrypoints against a backend=issues board (board $BOARD) ---"

run_cli "worklist.sh --board $BOARD"           -- worklist.sh --board "$BOARD"
run_cli "worklist.sh --board $BOARD --all"     -- worklist.sh --board "$BOARD" --all
run_cli "claim.sh 502 --board $BOARD"          -- claim.sh 502 --board "$BOARD"
run_cli "capture.sh --board $BOARD"            -- capture.sh "A captured item" --board "$BOARD"
run_cli "reconcile.sh --board $BOARD"          -- reconcile.sh --board "$BOARD"
run_cli "reconcile.sh --board $BOARD --status" -- reconcile.sh --board "$BOARD" --status

echo
echo "--- assert: cumulative gh-invocation log carries zero forbidden calls ---"

N_CALLS="$(grep -c '^gh ' "$GH_LOG" || true)"
if [ "$N_CALLS" -gt 0 ]; then
  ok "gh was invoked at least once across the run ($N_CALLS calls) — the fake wasn't simply bypassed"
else
  bad "sanity" "the gh log is empty — the CLI entrypoints made zero gh calls, which cannot be right"
fi

if grep -Eq '^gh project' "$GH_LOG"; then
  bad "zero gh project" "found: $(grep -E '^gh project' "$GH_LOG")"
else
  ok "zero 'gh project …' calls across worklist/claim/capture/reconcile (both lenses)"
fi

if grep -Eq '^gh api graphql' "$GH_LOG"; then
  bad "zero gh api graphql" "found: $(grep -E '^gh api graphql' "$GH_LOG")"
else
  ok "zero 'gh api graphql …' calls across worklist/claim/capture/reconcile (both lenses)"
fi

echo
if [ "$fail_n" -gt 0 ]; then
  echo "FAILED $fail_n/$((pass + fail_n)) checks in test_cli_entrypoint_no_graphql.sh"
  echo "--- full gh-invocation log ---"
  cat "$GH_LOG"
  exit 1
fi
echo "ALL PASS: test_cli_entrypoint_no_graphql.sh ($pass checks; $N_CALLS gh calls logged, zero gh project/graphql)"
