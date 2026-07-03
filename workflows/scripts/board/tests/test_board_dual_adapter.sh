#!/usr/bin/env bash
#
# test_board_dual_adapter.sh — the dual-adapter SAFE-TIER funnel-tick
# integration suite (foundation #801, split 3/3 of the issues-only tracker
# adapter, Epic B #763). This is the "D3 seam" proof.
#
# THE SEAM: funnel-tick.sh's LIVE (non `--dry-run`) board read
# (read_ready_items -> sources board.sh -> board_resolve) must classify Ready
# work IDENTICALLY no matter which tracker backend the board is configured
# for (boards.conf's `backend` axis, foundation #799/#800). funnel-tick.sh
# itself carries zero backend branching — the whole seam lives inside
# board.sh's board_resolve/board_item_list dispatch. This suite is the
# end-to-end proof that the seam actually holds, by running ONE scenario
# through the REAL (live-mode) code path TWICE — once against a
# `backend=projects` board, once against a `backend=issues` board — and
# asserting parity: the identical SAFE-TIER action set comes out either way.
#
# Why LIVE mode, not `--dry-run --fixture`: funnel-tick's dry-run path reads
# PRE-PROJECTED fixture files directly (ready.json / decisions.json) and never
# touches board.sh at all — see funnel-tick.sh's own read_ready_items, which
# only sources board.sh on the live branch. A dry-run test can never catch a
# board.sh reshape gap because it never calls board.sh. This suite fills that
# blind spot: it shadows `gh` on PATH and runs `funnel-tick.sh --board 30`
# for real (no --dry-run), so the ACTUAL board_resolve dispatch executes.
#
# THE GAP THIS CAUGHT (and now pins): board.sh's issues-only `issue_item()`
# reshape (#799) carried status/component/host-Session but silently DROPPED
# every ordinary GitHub label (spike / Foundational / needs-clarification /
# funnel-escalated / funnel-merge-pending — none of them `fnd:`-namespaced).
# funnel-tick.sh's classify_item/needs_clarification/funnel_escalated/
# pending_merge all read a Ready item's raw `.labels` array; on the
# Projects-v2 path this was always present for free (gh's own `project
# item-list --format json` output already carries a top-level `labels` array
# for Issue content, and board.sh passes it through unmodified). Against a
# live issues-only board, every Ready item's labels read back empty and
# EVERY item silently misclassified as a fresh Operational kind:code drive —
# spikes would never route to the safe verdict path, Foundational items would
# never gate to the decision queue, needs-clarification items would never
# park. Fixed by adding a `labels` passthrough to `issue_item()` (see
# board.sh's own comment there, and ISSUES-ONLY-BACKEND.md § Funnel
# integration). This suite is the regression lock: run it against a
# pre-fix checkout and the `issues` arm fails on drive-ready/route assertions.
#
# SAFE-TIER, no merges: the scenario below exercises exactly the action set
# funnel-drive.sh's rung-5b executor auto-runs (route-*/drain-*/a kind:spike
# drive — never a merge, foundation #604's SAFE/MERGING split) — and this
# suite asserts, directly against the recorded gh call log, that NOT ONE
# PR/merge/write-capable gh call ever fires in either arm. That is the
# structural proof of "no merges", not just an absence of assertions about
# merging.
#
# Zero network: a PATH-shadowing fake `gh` (this file's own — the shared
# fixtures/fake_gh.sh helper's PATH form doesn't understand `issue list
# --search`/`--state` or `issue view --jq`, which this scenario needs) serves
# canned JSON and appends every invocation's argv to a log this suite greps.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK="$HERE/../../build/funnel-tick.sh"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="Acme/dual-adapter-test"   # denylist:allow — generic placeholder org/repo, no personal token

# ---------------------------------------------------------------------------
# Fake gh (PATH-binary form). Logs every invocation's argv to $GH_LOG; serves
# canned JSON from $FIXDIR for the reads this scenario needs. Any subcommand
# outside that closed set (pr *, issue edit/close/reopen, project item-add/
# item-edit, label create, api …) is a hard error — this scenario must never
# reach a mutating or PR/merge-capable call.
# ---------------------------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$GH_LOG"

sub="${1:-}"; shift || true
case "$sub" in
  issue)
    icmd="${1:-}"; shift || true
    case "$icmd" in
      list)
        search="" state=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --search) search="$2"; shift 2 ;;
            --state)  state="$2";  shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -n "$search" ]; then
          case "$search" in
            *label:decision*)            cat "$FIXDIR/decisions.json" ;;
            *label:needs-clarification*) cat "$FIXDIR/clarifications.json" ;;
            *) echo '[]' ;;
          esac
        elif [ "$state" = "open" ]; then
          cat "$FIXDIR/issues-open.json"
        else
          echo '[]'
        fi
        ;;
      view) echo 0 ;;   # gh issue view <n> -R <repo> --json assignees --jq '.assignees | length'
      *) echo "fake gh: unhandled 'issue $icmd'" >&2; exit 3 ;;
    esac
    ;;
  project)
    pcmd="${1:-}"; shift || true
    case "$pcmd" in
      view)       cat "$FIXDIR/project_view.json" ;;
      field-list) cat "$FIXDIR/field_list.json" ;;
      item-list)  cat "$FIXDIR/item_list.json" ;;
      *) echo "fake gh: unhandled 'project $pcmd'" >&2; exit 3 ;;
    esac
    ;;
  *)
    echo "fake gh: unexpected subcommand '$sub' — this SAFE-TIER scenario must never call pr/api/label/write subcommands" >&2
    exit 3
    ;;
esac
GHSCRIPT
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Shared scenario — the SAME five items feed BOTH backend arms:
#   #900 answered decision            -> drain-answer
#   #901 answered clarification       -> drain-clarification
#   #902 Ready, label spike           -> drive-ready kind:spike (SAFE, no PR)
#   #903 Ready, label Foundational    -> route-foundational
#   #904 Ready, label needs-clarification -> route-already-assigned (parked)
# ---------------------------------------------------------------------------
FIXDIR="$TMP/fixtures"; mkdir -p "$FIXDIR"

cat > "$FIXDIR/decisions.json" <<'JSON'
[{"number":900,"title":"merge-gate policy","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-07-01T10:00:00Z","body":"```decision\nchosen: some-choice\n```"}]}]
JSON

cat > "$FIXDIR/clarifications.json" <<'JSON'
[{"number":901,"title":"clarify the approach","body":"x","assignees":[],
  "comments":[{"createdAt":"2026-07-01T10:00:00Z","body":"operator's free-text answer"}]}]
JSON

# Projects-v2 arm: gh's own `project item-list --format json` already carries a
# top-level `labels` array for Issue content — board.sh passes it through
# UNMODIFIED (board_item_list / _board_item_list_fresh reshape nothing but PR
# cards + control chars). This fixture models that real gh shape directly.
cat > "$FIXDIR/item_list.json" <<'JSON'
{"items":[
  {"id":"PVTI_902","content":{"number":902,"title":"investigate seam"},"status":"Ready","labels":["spike"]},
  {"id":"PVTI_903","content":{"number":903,"title":"design a new axis"},"status":"Ready","labels":["Foundational"]},
  {"id":"PVTI_904","content":{"number":904,"title":"ambiguous fix"},"status":"Ready","labels":["needs-clarification"]}
],"totalCount":3}
JSON
cat > "$FIXDIR/project_view.json" <<'JSON'
{"id":"PVT_kwDUALADAPTER"}
JSON
cat > "$FIXDIR/field_list.json" <<'JSON'
{"fields":[]}
JSON

# Issues-only arm: raw `gh issue list --json number,title,labels` — the SAME
# three Ready items, but as plain GitHub issues carrying BOTH the fnd:status:*
# machinery label AND the ordinary work-class label board.sh's issue_item()
# must pass through raw (the #801 fix this suite pins).
cat > "$FIXDIR/issues-open.json" <<'JSON'
[
  {"number":902,"title":"investigate seam","labels":[{"name":"fnd:status:ready"},{"name":"spike"}]},
  {"number":903,"title":"design a new axis","labels":[{"name":"fnd:status:ready"},{"name":"Foundational"}]},
  {"number":904,"title":"ambiguous fix","labels":[{"name":"fnd:status:ready"},{"name":"needs-clarification"}]}
]
JSON

# ---------------------------------------------------------------------------
# boards.conf — ONE board number (30), rewritten per arm. Read by BOTH
# board.sh's _board_conf_get AND funnel-tick.sh's own _tick_conf_repo (same
# BOARDS_CONF_REPO_LOCAL / BOARDS_CONF_MACHINE env names, same discovery
# order) — so the two never disagree on which repo board 30 is.
# ---------------------------------------------------------------------------
CONF="$TMP/boards.conf"
write_conf() {  # $1 = backend (projects|issues)
  cat > "$CONF" <<EOF
board.30.repo=$REPO
board.30.owner=Acme
board.30.project=1
board.30.backend=$1
EOF
}

# A stub intake command (Phase 0). This is a LIVE (non --dry-run) tick, so
# funnel-tick's dry-run intake skip does not apply — Phase 0 would otherwise
# try to run the real crash-convergence signal-intake.sh. Stub exits 0, no
# side effects, so it never disturbs the SAFE-TIER action count below.
INTAKE_STUB="$TMP/intake-stub.sh"
cat > "$INTAKE_STUB" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$INTAKE_STUB"

run_arm() {  # $1 = backend (projects|issues)  ->  prints the tick-plan JSON on stdout
  local backend="$1"
  local log="$TMP/gh-$backend.log"
  local cache
  cache="$(mktemp -d "$TMP/cache-$backend-XXXXXX")"
  : > "$log"
  write_conf "$backend"
  GH_LOG="$log" FIXDIR="$FIXDIR" \
  PATH="$BIN:$PATH" \
  BOARDS_CONF_REPO_LOCAL="$CONF" BOARDS_CONF_MACHINE="$TMP/no-such-machine-conf" \
  BOARD_CACHE_TTL=0 BOARD_BUDGET_GUARD_THRESHOLD=0 BOARD_CACHE_DIR="$cache" \
  FUNNEL_ENABLED_BOARDS=30 FUNNEL_INTAKE_CMD="$INTAKE_STUB" \
  FUNNEL_LOCK_DIR="$TMP/lock-$backend" \
  bash "$TICK" --board 30
}

for BACKEND in projects issues; do
  echo "--- test: SAFE-TIER live funnel tick against backend=$BACKEND ---"
  PLAN="$(run_arm "$BACKEND")"
  LOG="$TMP/gh-$BACKEND.log"

  [ "$(jq -r '.tick' <<<"$PLAN")" = "done" ] && ok "[$BACKEND] tick completed" || bad "[$BACKEND] tick" "got: $PLAN"

  DRAIN="$(jq -c 'first(.actions[]|select(.action=="drain-answer")) // empty' <<<"$PLAN")"
  [ "$(jq -r '.issue' <<<"$DRAIN")" = "900" ] && ok "[$BACKEND] drain-answer #900" || bad "[$BACKEND] drain-answer" "$PLAN"
  [ "$(jq -r '.chosen' <<<"$DRAIN")" = "some-choice" ] && ok "[$BACKEND] parsed chosen=some-choice" || bad "[$BACKEND] chosen" "$DRAIN"

  CLAR="$(jq -c 'first(.actions[]|select(.action=="drain-clarification")) // empty' <<<"$PLAN")"
  [ "$(jq -r '.issue' <<<"$CLAR")" = "901" ] && ok "[$BACKEND] drain-clarification #901" || bad "[$BACKEND] drain-clarification" "$PLAN"

  DRIVE="$(jq -c 'first(.actions[]|select(.action=="drive-ready")) // empty' <<<"$PLAN")"
  [ "$(jq -r '.issue' <<<"$DRIVE")" = "902" ] && ok "[$BACKEND] drive-ready #902" || bad "[$BACKEND] drive-ready.issue" "$PLAN"
  [ "$(jq -r '.kind' <<<"$DRIVE")" = "spike" ] && ok "[$BACKEND] kind=spike (SAFE, opens no PR)" || bad "[$BACKEND] drive-ready.kind" "$DRIVE"
  [ "$(jq -r '.route' <<<"$DRIVE")" = "spike" ] && ok "[$BACKEND] route=spike (singleton verdict path)" || bad "[$BACKEND] drive-ready.route" "$DRIVE"

  ROUTE_F="$(jq -c 'first(.actions[]|select(.action=="route-foundational")) // empty' <<<"$PLAN")"
  [ "$(jq -r '.issue' <<<"$ROUTE_F")" = "903" ] && ok "[$BACKEND] route-foundational #903" || bad "[$BACKEND] route-foundational" "$PLAN"

  ROUTE_C="$(jq -c 'first(.actions[]|select(.action=="route-already-assigned" and .issue==904)) // empty' <<<"$PLAN")"
  [ "$(jq -r '.label' <<<"$ROUTE_C")" = "needs-clarification" ] && ok "[$BACKEND] route-already-assigned #904 (parked on needs-clarification)" || bad "[$BACKEND] route-already-assigned" "$PLAN"

  # Exactly the SAFE-TIER action set above — no stray drive/route (would
  # signal a misclassification, e.g. #902 driven as kind:code instead of
  # kind:spike, which is exactly the pre-fix issues-only failure mode).
  N_ACTIONS="$(jq '.actions|length' <<<"$PLAN")"
  [ "$N_ACTIONS" = "5" ] && ok "[$BACKEND] exactly 5 actions (no stray drive/route)" || bad "[$BACKEND] action-count" "got $N_ACTIONS: $PLAN"

  # SAFE-TIER = no merges, proven structurally against the gh call log: no
  # PR/merge/write-capable call (pr *, issue edit/close/reopen, project
  # item-add/item-edit, label create) fires in EITHER arm.
  if grep -Eq '^gh (pr |issue edit|issue close|issue reopen|project item-add|project item-edit|label create)' "$LOG"; then
    bad "[$BACKEND] no-merge invariant" "a mutating/PR gh call fired: $(grep -E '^gh (pr |issue edit|issue close|issue reopen|project item-add|project item-edit|label create)' "$LOG")"
  else
    ok "[$BACKEND] zero PR/merge/write gh calls (SAFE-TIER structurally proven)"
  fi
done

# ---------------------------------------------------------------------------
# Cross-arm parity: strip {backend-varying keys removed} and diff the two
# plans' action SHAPES directly — the strongest form of "the seam holds":
# not just "both arms produced the right actions" (above) but "both arms
# produced the SAME actions", byte for byte, modulo nothing.
# ---------------------------------------------------------------------------
PLAN_P="$(run_arm projects)"
PLAN_I="$(run_arm issues)"
NORM='[.actions[] | {phase,board,issue,action,class,kind,route,label,chosen}]'
NORM_P="$(jq -c "$NORM" <<<"$PLAN_P")"
NORM_I="$(jq -c "$NORM" <<<"$PLAN_I")"
[ "$NORM_P" = "$NORM_I" ] && ok "cross-arm parity: identical action set (repo/emit/detail text aside) on projects vs issues" \
  || bad "cross-arm parity" "projects=$NORM_P${nl:-\n}issues=$NORM_I"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED $fail/$((pass + fail)) checks in test_board_dual_adapter.sh"
  exit 1
fi
echo "ALL PASS: test_board_dual_adapter.sh ($pass checks, both adapters)"
