#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/gate.sh — the build 4a/4b/4c
# merge-gate mechanics (epic #253, spike #245). ONE fixture system: this test
# `source`s gate.sh (whose source guard skips the dispatch), which in turn
# sources board.sh — and overrides the `_gate_gh` / `_gate_git` seams exactly
# the way the board replay tests override `_board_gh` (no second mock layer, no
# PATH shim, zero network). Each case redefines the seam, then calls the cmd_*
# function directly and asserts on the structured JSON it prints.
#
# Covers:
#   - read: stable MERGEABLE/CLEAN read; UNKNOWN/BEHIND triggers exactly one
#     re-poll, then classifies on the second (settled) value
#   - strict: required_status_checks.strict==true → STRICT; gh 404 → NON_STRICT
#   - risk: RISKY on overlapping files; RISKY on a hold/risky label; RISKY on a
#     not-CLEAN mergeStateStatus; a clean, pairwise-disjoint, unflagged set →
#     CLEAN_DISJOINT_INDEPENDENT
#   - queue: canonical --auto incantation → QUEUED (a real merge is never run)
#   - nudge: BEHIND → NUDGED (update-branch called); not-BEHIND → NUDGE_NOOP
#   - poll: ONE fixture per terminal outcome — MERGED (exit 0, the SOLE success
#     check), CONFLICTING/DIRTY (exit 3), TIMEOUT (exit 4); a CLOSED-not-merged
#     PR never reads MERGED (the #130 premature-close guard)
#   - backend: auto probe → NATIVE (merge_queue rule present) / MANAGED (rule
#     absent) / MANAGED+probe_failed:true (gh error, the fail-safe direction);
#     an explicit BUILD_MERGE_BACKEND=native|managed override short-circuits
#     WITHOUT calling the probe at all
#   - managed-merge: strict (default) → update-branch called, SHA-pinned CI
#     re-poll green, merge, confirmed MERGED; --non-strict → update-branch
#     NEVER called, merges directly; CI red after update-branch → EJECTED, no
#     merge attempted; `gh pr merge` itself rejected (e.g. queue-armed repo) →
#     MERGE_REJECTED, distinct non-silent outcome; an existing subcommand's
#     JSON is asserted BYTE-IDENTICAL (no-behavior-change-on-native guarantee)
#
# The seams are redefined mid-file per case (the library calls them
# indirectly), so shellcheck's "never invoked"/"unreachable" checks are false
# positives — disabled file-wide like the sibling board replay tests.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script under test. Its source-guard ([ BASH_SOURCE = $0 ]) skips
# the CLI dispatch, exposing cmd_* and the _gate_* seams; it also sources
# board.sh, so the shared fixture system is in scope. No re-poll wait in tests.
export GATE_REPOLL_DELAY=0
# shellcheck source=workflows/scripts/build/gate.sh
source "$HERE/../gate.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Confirm the shared fixture system is live: board.sh's _board_gh seam is in
# scope (same harness gate.sh + the board tests share).
declare -F _board_gh >/dev/null || fail "board.sh not sourced — shared fixture system missing"
echo "PASS: gate.sh sources board.sh — one shared fixture system (_board_gh in scope)"

# --- read: stable MERGEABLE/CLEAN -------------------------------------------
_gate_gh() {
  # $1=pr $2=view ... emit the --json payload as gh would (raw via --jq).
  cat <<'JSON'
{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN",
 "statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}
out="$(cmd_read Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "READ" ] || fail "read outcome (got: $out)"
[ "$(jq -r .mergeable <<<"$out")" = "MERGEABLE" ] || fail "read mergeable (got: $out)"
[ "$(jq -r .mergeStateStatus <<<"$out")" = "CLEAN" ] || fail "read mss (got: $out)"
[ "$(jq -r .checks <<<"$out")" = "PASS" ] || fail "read checks digest (got: $out)"
echo "PASS: read → mergeable/mergeStateStatus/state/checks digest on a CLEAN PR"

# --- read: UNKNOWN then settled → exactly one re-poll -----------------------
# A file-backed counter, because _gate_view runs inside a process-substitution
# subshell — an in-memory counter would reset each call.
echo 0 > "$TMP/reads"
_gate_gh() {
  local n; n=$(<"$TMP/reads"); n=$((n + 1)); echo "$n" > "$TMP/reads"
  if [ "$n" -eq 1 ]; then
    echo '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","state":"OPEN","statusCheckRollup":[]}'
  else
    echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
  fi
}
out="$(cmd_read Towheads/foundation 42)"
[ "$(jq -r .mergeable <<<"$out")" = "MERGEABLE" ] || fail "re-poll did not settle (got: $out)"
[ "$(<"$TMP/reads")" -eq 2 ] || fail "expected exactly one re-poll (2 reads), got $(<"$TMP/reads")"
echo "PASS: read re-polls ONCE on UNKNOWN and classifies on the settled value"

# --- strict: protection strict==true → STRICT -------------------------------
_gate_gh() { echo "true"; }
out="$(cmd_strict Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "STRICT" ] || fail "strict-true not STRICT (got: $out)"
echo "PASS: strict → STRICT when required_status_checks.strict == true"

# --- strict: gh 404 (not protected) → NON_STRICT ----------------------------
_gate_gh() { return 1; }   # gh non-zero == 404 / not protected
out="$(cmd_strict Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NON_STRICT" ] || fail "404 not NON_STRICT (got: $out)"
echo "PASS: strict → NON_STRICT on a 404 (branch not protected)"

# --- risk: CLEAN, pairwise-disjoint, unflagged set → passes -----------------
# _gate_gh dispatches on the requested --json field; _gate_git returns each
# PR's disjoint file set keyed off the headRef encoded as origin/main..pr-<n>.
_gate_gh() {
  local pr field=""; local -a a=("$@")
  pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    headRefName) echo "pr-$pr" ;;
    labels)      echo "" ;;   # no labels
    *) echo "{}" ;;
  esac
}
_gate_git() {  # diff --name-only origin/main..pr-<n>
  local spec="${*: -1}"; local pr="${spec##*pr-}"
  echo "src/file_$pr.sh"   # one unique file per PR → disjoint
}
out="$(cmd_risk Towheads/foundation 10 11 12)"
[ "$(jq -r .outcome <<<"$out")" = "CLEAN_DISJOINT_INDEPENDENT" ] \
  || fail "clean disjoint set not CLEAN_DISJOINT_INDEPENDENT (got: $out)"
echo "PASS: risk → CLEAN_DISJOINT_INDEPENDENT on a CLEAN, disjoint, unflagged set"

# --- risk: overlapping changed files → RISKY --------------------------------
_gate_git() { echo "src/shared.sh"; }   # every PR touches the SAME file → overlap
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "overlap not RISKY (got: $out)"
jq -e '.reasons[] | select(test("overlapping files"))' <<<"$out" >/dev/null \
  || fail "overlap reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when changed-file sets are not pairwise disjoint"

# --- risk: a hold/risky label → RISKY ---------------------------------------
_gate_git() { local spec="${*: -1}"; local pr="${spec##*pr-}"; echo "src/file_$pr.sh"; }  # disjoint again
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}' ;;
    headRefName) echo "pr-$pr" ;;
    labels)      [ "$pr" = "11" ] && echo "hold" || echo "" ;;
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "label not RISKY (got: $out)"
jq -e '.reasons[] | select(test("hold/risky label"))' <<<"$out" >/dev/null \
  || fail "label reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when any PR carries a hold/risky label"

# --- risk: a not-CLEAN mergeStateStatus → RISKY -----------------------------
_gate_gh() {
  local pr field=""; local -a a=("$@"); pr="${a[2]}"
  for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
  case "$field" in
    mergeable,mergeStateStatus,state,statusCheckRollup)
      if [ "$pr" = "11" ]; then
        echo '{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","state":"OPEN","statusCheckRollup":[]}'
      else
        echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
      fi ;;
    headRefName) echo "pr-$pr" ;;
    labels)      echo "" ;;
    *) echo "{}" ;;
  esac
}
out="$(cmd_risk Towheads/foundation 10 11)"
[ "$(jq -r .outcome <<<"$out")" = "RISKY" ] || fail "not-CLEAN mss not RISKY (got: $out)"
jq -e '.reasons[] | select(test("not CLEAN"))' <<<"$out" >/dev/null \
  || fail "not-CLEAN reason not surfaced (got: $out)"
echo "PASS: risk → RISKY when any PR's mergeStateStatus is not CLEAN"

# --- queue: canonical --auto incantation → QUEUED ---------------------------
# Assert gate.sh queues via --auto --merge --delete-branch (never a bare
# merge-now), and records the strict flag. The seam logs the argv so we can
# prove the incantation; it never performs a real merge.
_gate_gh() { echo "$*" > "$TMP/merge_argv"; return 0; }
out="$(cmd_queue Towheads/foundation 42 --strict)"
[ "$(jq -r .outcome <<<"$out")" = "QUEUED" ] || fail "queue outcome (got: $out)"
[ "$(jq -r .strict <<<"$out")" = "true" ] || fail "queue strict flag (got: $out)"
argv="$(<"$TMP/merge_argv")"
grep -q -- '--auto' <<<"$argv" || fail "queue did not use --auto (argv: $argv)"
grep -q -- '--merge' <<<"$argv" || fail "queue did not use --merge (argv: $argv)"
grep -q -- '--delete-branch' <<<"$argv" || fail "queue did not use --delete-branch"
echo "PASS: queue → QUEUED via the canonical --auto --merge --delete-branch (no bare merge)"

# --- nudge: BEHIND → NUDGED (update-branch invoked) -------------------------
rm -f "$TMP/nudge_called"
_gate_gh() {
  local -a a=("$@")
  if [ "${a[0]}" = "pr" ] && [ "${a[1]}" = "update-branch" ]; then
    touch "$TMP/nudge_called"; return 0
  fi
  echo '{"mergeable":"UNKNOWN","mergeStateStatus":"BEHIND","state":"OPEN","statusCheckRollup":[]}'
}
out="$(cmd_nudge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "NUDGED" ] || fail "BEHIND not NUDGED (got: $out)"
[ -f "$TMP/nudge_called" ] || fail "update-branch not invoked for a BEHIND PR"
echo "PASS: nudge → NUDGED (gh pr update-branch) for a still-BEHIND PR (#83 nudge)"

# --- nudge: not-BEHIND → NUDGE_NOOP -----------------------------------------
_gate_gh() {
  local -a a=("$@")
  [ "${a[1]}" = "update-branch" ] && fail "update-branch called on a CLEAN PR (should NOOP)"
  echo '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","statusCheckRollup":[]}'
}
out="$(cmd_nudge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "NUDGE_NOOP" ] || fail "CLEAN not NUDGE_NOOP (got: $out)"
echo "PASS: nudge → NUDGE_NOOP (no update-branch) when the PR is not BEHIND"

# --- poll: MERGED is the SOLE success check (exit 0) ------------------------
_gate_gh() { echo '{"state":"MERGED","mergedAt":"2026-06-10T12:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 5)" || rc=$?
[ "$rc" -eq 0 ] || fail "MERGED did not exit 0 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "poll MERGED outcome (got: $out)"
[ "$(jq -r .mergedAt <<<"$out")" = "2026-06-10T12:00:00Z" ] || fail "poll mergedAt (got: $out)"
echo "PASS: poll → MERGED + exit 0 ONLY on state==MERGED with a confirmed mergedAt"

# --- poll: CLOSED-without-merge NEVER reads MERGED (the #130 guard) ----------
# A PR closed but never merged: state=CLOSED, mergedAt=null. It must NOT exit 0
# as MERGED; here it has no conflict, so it runs to TIMEOUT (exit 4) — the point
# is that MERGED (exit 0) is unreachable for a closed-not-merged PR.
_gate_gh() { echo '{"state":"CLOSED","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -ne 0 ] || fail "CLOSED-not-merged exited 0 (premature-close #130 regression!)"
[ "$(jq -r .outcome <<<"$out")" != "MERGED" ] || fail "CLOSED-not-merged read as MERGED (#130!)"
echo "PASS: poll → a CLOSED-but-unmerged PR never reads MERGED (the #130 premature-close guard)"

# --- poll: CONFLICTING/DIRTY → distinct exit 3 ------------------------------
_gate_gh() { echo '{"state":"OPEN","mergedAt":null,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 5)" || rc=$?
[ "$rc" -eq 3 ] || fail "CONFLICTING/DIRTY did not exit 3 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "CONFLICTING" ] || fail "poll CONFLICTING outcome (got: $out)"
echo "PASS: poll → CONFLICTING + distinct exit 3 on a conflicting/dirty PR"

# --- poll: timeout/stall → distinct exit 4 ----------------------------------
_gate_gh() { echo '{"state":"OPEN","mergedAt":null,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}'; }
rc=0; out="$(cmd_poll Towheads/foundation 42 --interval 0.1 --timeout 0)" || rc=$?
[ "$rc" -eq 4 ] || fail "stall did not exit 4 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "TIMEOUT" ] || fail "poll TIMEOUT outcome (got: $out)"
echo "PASS: poll → TIMEOUT + distinct exit 4 on a stalled (never-terminal) PR"

# --- error: bad inputs → structured ERROR + non-zero exit -------------------
# die() emits on fd 3 (the script's real-stdout seam); when sourced, fd 3 is the
# test's stdout, so capture it back into the command substitution with 3>&1.
rc=0; out="$( (cmd_read not-a-repo 42) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "bad owner/repo not structured ERROR (got: $out)"
rc=0; out="$( (cmd_read Towheads/foundation abc) 3>&1 2>/dev/null)" || rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r .outcome <<<"$out")" = "ERROR" ] \
  || fail "bad pr not structured ERROR (got: $out)"
echo "PASS: bad owner/repo or pr → structured ERROR + non-zero exit"

# --- backend: auto probe, merge_queue rule present → NATIVE -----------------
# _gate_gh here stands in for `gh api ... --jq '...'`, so the fixture emits the
# ALREADY-PROJECTED boolean the real --jq would produce (same style as the
# cmd_strict fixtures above), not the raw rules array.
unset BUILD_MERGE_BACKEND
_gate_gh() { echo "true"; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NATIVE" ] || fail "merge_queue rule present not NATIVE (got: $out)"
echo "PASS: backend → NATIVE when the branch ruleset carries a merge_queue rule"

# --- backend: auto probe, merge_queue rule absent → MANAGED ------------------
_gate_gh() { echo "false"; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "no merge_queue rule not MANAGED (got: $out)"
[ "$(jq -r 'has("probe_failed")' <<<"$out")" = "false" ] || fail "clean MANAGED should not carry probe_failed (got: $out)"
echo "PASS: backend → MANAGED when the branch ruleset has no merge_queue rule"

# --- backend: probe error (gh non-zero / empty) → MANAGED + probe_failed:true
_gate_gh() { return 1; }
out="$(cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "probe error not MANAGED (got: $out)"
[ "$(jq -r .probe_failed <<<"$out")" = "true" ] || fail "probe error missing probe_failed:true (got: $out)"
echo "PASS: backend → MANAGED + probe_failed:true on a probe error (fail-safe direction)"

# --- backend: explicit override wins WITHOUT probing -------------------------
_gate_gh() { fail "gh called under an explicit BUILD_MERGE_BACKEND override (should short-circuit)"; }
BUILD_MERGE_BACKEND=native out="$(BUILD_MERGE_BACKEND=native cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "NATIVE" ] || fail "override=native not NATIVE (got: $out)"
echo "PASS: backend → NATIVE on BUILD_MERGE_BACKEND=native, no probe call"

out="$(BUILD_MERGE_BACKEND=managed cmd_backend Towheads/foundation)"
[ "$(jq -r .outcome <<<"$out")" = "MANAGED" ] || fail "override=managed not MANAGED (got: $out)"
[ "$(jq -r 'has("probe_failed")' <<<"$out")" = "false" ] || fail "override MANAGED should not carry probe_failed (got: $out)"
echo "PASS: backend → MANAGED on BUILD_MERGE_BACKEND=managed, no probe call"
unset BUILD_MERGE_BACKEND

# --- managed-merge: green STRICT path ----------------------------------------
# update-branch called → new head sha resolved → SHA-pinned CI re-poll GREEN →
# merge → confirmed MERGED. Zero-delay poll knobs (mirrors GATE_REPOLL_DELAY).
export GATE_CI_POLL_INTERVAL=0 GATE_CI_POLL_TIMEOUT=5
export GATE_MERGE_POLL_INTERVAL=0 GATE_MERGE_POLL_TIMEOUT=5
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") return 0 ;;
    "pr view")
      local field="" k
      for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
      case "$field" in
        headRefOid) echo "deadbeef1" ;;
        state,mergedAt,mergeable,mergeStateStatus)
          echo '{"state":"MERGED","mergedAt":"2026-07-04T00:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
        *) echo "{}" ;;
      esac
      return 0 ;;
    "pr merge") return 0 ;;
    "run list") echo "[]"; return 0 ;;
    *)
      if [ "${a[0]:-}" = "api" ]; then
        echo '[{"status":"completed","conclusion":"success"}]'
      fi ;;
  esac
}
out="$(cmd_managed_merge Towheads/foundation 42)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "managed-merge green-strict outcome (got: $out)"
[ "$(jq -r .mergedAt <<<"$out")" = "2026-07-04T00:00:00Z" ] || fail "managed-merge green-strict mergedAt (got: $out)"
grep -q "^pr update-branch " "$TMP/mm_calls" || fail "managed-merge strict did not call update-branch"
echo "PASS: managed-merge (strict, default) → update-branch + SHA-pinned CI re-poll + merge + confirmed MERGED"

# --- managed-merge: green NON-STRICT path ------------------------------------
# --non-strict must NEVER call update-branch (or the CI re-poll) — straight to
# merge → confirmed MERGED, preserving a non-strict repo's immediate-merge
# cost profile.
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") fail "update-branch called under --non-strict (must be skipped entirely)" ;;
    "pr view")
      echo '{"state":"MERGED","mergedAt":"2026-07-04T01:00:00Z","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
      return 0 ;;
    "pr merge") return 0 ;;
  esac
  case "${a[0]:-}" in
    api) fail "CI re-poll (gh api) called under --non-strict (must be skipped entirely)" ;;
  esac
}
out="$(cmd_managed_merge Towheads/foundation 42 --non-strict)"
[ "$(jq -r .outcome <<<"$out")" = "MERGED" ] || fail "managed-merge green-non-strict outcome (got: $out)"
! grep -q "update-branch" "$TMP/mm_calls" || fail "managed-merge non-strict seam saw update-branch"
! grep -q "^api" "$TMP/mm_calls" || fail "managed-merge non-strict seam saw a CI re-poll call"
echo "PASS: managed-merge --non-strict → NO update-branch, NO CI re-poll, straight to merge + confirmed MERGED"

# --- managed-merge: CI red after update-branch → EJECTED, no merge attempted
rm -f "$TMP/mm_calls"
_gate_gh() {
  local -a a=("$@")
  echo "$*" >> "$TMP/mm_calls"
  case "${a[0]:-} ${a[1]:-}" in
    "pr update-branch") return 0 ;;
    "pr view")
      local field="" k
      for ((k=0; k<${#a[@]}; k++)); do [ "${a[$k]}" = "--json" ] && field="${a[$((k+1))]}"; done
      case "$field" in
        headRefOid) echo "deadbeef2" ;;
        *) echo "{}" ;;
      esac
      return 0 ;;
    "pr merge") fail "merge attempted after CI red on the updated head (eject must not merge)" ;;
    "run list") echo "[987]"; return 0 ;;
  esac
  case "${a[0]:-}" in
    api) echo '[{"status":"completed","conclusion":"failure"}]' ;;
  esac
}
rc=0; out="$(cmd_managed_merge Towheads/foundation 42)" || rc=$?
[ "$rc" -eq 5 ] || fail "managed-merge eject did not exit 5 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "EJECTED" ] || fail "managed-merge eject outcome (got: $out)"
[ "$(jq -c .failed_run_ids <<<"$out")" = "[987]" ] || fail "managed-merge eject failed_run_ids (got: $out)"
! grep -q "^pr merge " "$TMP/mm_calls" || fail "managed-merge eject seam saw a merge call"
echo "PASS: managed-merge → CI red after update-branch → EJECTED (exit 5), failed_run_ids surfaced, no merge attempted"

# --- managed-merge: gh pr merge itself rejected (e.g. queue-armed repo) ------
# --non-strict path (fewer preconditions) with the merge call itself failing —
# a distinct, non-silent MERGE_REJECTED outcome rather than a bare ERROR.
_gate_gh() {
  local -a a=("$@")
  case "${a[0]:-} ${a[1]:-}" in
    "pr merge") echo "GraphQL: Pull request is not mergeable via the UI or API (mergePullRequest)"; return 1 ;;
  esac
  echo "{}"
}
rc=0; out="$(cmd_managed_merge Towheads/foundation 42 --non-strict)" || rc=$?
[ "$rc" -eq 6 ] || fail "managed-merge merge-rejected did not exit 6 (rc=$rc)"
[ "$(jq -r .outcome <<<"$out")" = "MERGE_REJECTED" ] || fail "managed-merge merge-rejected outcome (got: $out)"
jq -e '.error | test("not mergeable")' <<<"$out" >/dev/null \
  || fail "managed-merge merge-rejected error message not surfaced (got: $out)"
echo "PASS: managed-merge → a merge the platform itself rejects surfaces as MERGE_REJECTED (exit 6), not silently"
unset GATE_CI_POLL_INTERVAL GATE_CI_POLL_TIMEOUT GATE_MERGE_POLL_INTERVAL GATE_MERGE_POLL_TIMEOUT

# --- no-behavior-change-on-native guarantee: an existing subcommand's JSON is
# BYTE-IDENTICAL after adding managed-merge (acceptance criterion 3) ---------
_gate_gh() { echo "true"; }
out="$(cmd_strict Towheads/foundation)"
[ "$out" = '{"outcome":"STRICT"}' ] \
  || fail "cmd_strict output changed byte-for-byte after adding managed-merge (got: $out)"
echo "PASS: cmd_strict output is byte-identical after adding managed-merge (no behavior change on existing subcommands)"

echo "ALL GATE TESTS PASSED"
