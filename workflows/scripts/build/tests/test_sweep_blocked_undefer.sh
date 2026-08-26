#!/usr/bin/env bash
#
# Tests for workflows/scripts/build/sweep-blocked-undefer.sh — the
# deterministic un-defer predicate combinator for /sweep's blocked_by-aware
# chunk formation (temperloop#1835, epic #1847 Produces #2).
#
# Entirely OFFLINE: synthetic blocker JSON fixtures on disk, zero `gh`
# calls, zero `git`/worktree.sh calls, zero board reads (mirrors
# test_sweep_answered_exclusion.sh's convention).
#
# Covers:
#   1. an OPEN blocker -> never un-defers (blocker-open), regardless of any
#      other field.
#   2. a CLOSED blocker with NO linked merged PR -> the ambiguity case
#      releases its dependents (closed-no-linked-merged-pr).
#   3. a CLOSED blocker with a linked merged PR whose commit IS an ancestor
#      of origin/<default> (deps_merged=DEPS_MERGED) -> un-defers.
#   4. a CLOSED blocker with a linked merged PR whose commit is NOT yet an
#      ancestor (deps_merged=DEPS_UNMERGED) -> still defers.
#   5. a CLOSED blocker with a linked merged PR but deps_merged not yet
#      supplied (null) -> conservatively still defers (pending), never
#      guesses un-defer.
#   6. a blocker whose OWN sweep_disposition this run is "parked" -> NEVER
#      releases its dependents, even when the state read says CLOSED and a
#      merged PR with a merged ancestor SHA is present (parked wins over
#      every other signal — the explicit precondition-order proof).
#   7. --help / -h / no-args activation proof.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../sweep-blocked-undefer.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }
[ -x "$CLI" ] || { echo "FATAL: sweep-blocked-undefer.sh not found/executable at $CLI" >&2; exit 1; }

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check_field() { # <desc> <fixture-json> <jq-field> <want>
  local desc="$1" file="$2" field="$3" want="$4"
  local out got
  out="$(bash "$CLI" "$file")"
  got="$(jq -r "$field" <<<"$out")"
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    bad "$desc" "want [$want], got [$got] (full: $out)"
  fi
}

# ── 1: open blocker ─────────────────────────────────────────────────────
echo "--- 1: an OPEN blocker never un-defers ---"
OPEN="$TMP/open.json"
cat > "$OPEN" <<'JSON'
{"blocker_number": 100, "state": "OPEN", "linked_merged_prs": [{"number": 200, "mergeCommitOid": "deadbeef"}], "deps_merged": "DEPS_MERGED"}
JSON
check_field "open blocker, even with a merged+ancestor PR -> un_defer=false" "$OPEN" '.un_defer' "false"
check_field "...reason=blocker-open" "$OPEN" '.reason' "blocker-open"

# ── 2: closed, no linked merged PR — the ambiguity case ─────────────────
echo "--- 2: CLOSED with NO linked merged PR releases dependents (ambiguity case) ---"
NOPR="$TMP/no-pr.json"
cat > "$NOPR" <<'JSON'
{"blocker_number": 101, "state": "CLOSED", "linked_merged_prs": []}
JSON
check_field "closed, no linked PR -> un_defer=true" "$NOPR" '.un_defer' "true"
check_field "...reason=closed-no-linked-merged-pr" "$NOPR" '.reason' "closed-no-linked-merged-pr"

# ── 3: closed, merged PR, ancestor confirmed ─────────────────────────────
echo "--- 3: CLOSED + linked merged PR + deps-merged=DEPS_MERGED -> un-defers ---"
ANCESTOR="$TMP/ancestor.json"
cat > "$ANCESTOR" <<'JSON'
{"blocker_number": 102, "state": "CLOSED", "linked_merged_prs": [{"number": 202, "mergeCommitOid": "cafef00d"}], "deps_merged": "DEPS_MERGED"}
JSON
check_field "closed + ancestor confirmed -> un_defer=true" "$ANCESTOR" '.un_defer' "true"
check_field "...reason=merge-commit-is-ancestor" "$ANCESTOR" '.reason' "merge-commit-is-ancestor"

# ── 4: closed, merged PR, NOT yet an ancestor ────────────────────────────
echo "--- 4: CLOSED + linked merged PR + deps-merged=DEPS_UNMERGED -> still defers ---"
NOTYET="$TMP/not-yet.json"
cat > "$NOTYET" <<'JSON'
{"blocker_number": 103, "state": "CLOSED", "linked_merged_prs": [{"number": 203, "mergeCommitOid": "f00dcafe"}], "deps_merged": "DEPS_UNMERGED"}
JSON
check_field "closed + not-yet-ancestor -> un_defer=false" "$NOTYET" '.un_defer' "false"
check_field "...reason=merge-commit-not-yet-ancestor" "$NOTYET" '.reason' "merge-commit-not-yet-ancestor"

# ── 5: closed, merged PR, deps-merged not yet supplied ───────────────────
echo "--- 5: CLOSED + linked merged PR + deps_merged omitted -> conservative defer, never guesses ---"
PENDING="$TMP/pending.json"
cat > "$PENDING" <<'JSON'
{"blocker_number": 104, "state": "CLOSED", "linked_merged_prs": [{"number": 204, "mergeCommitOid": "0ff1ce"}]}
JSON
check_field "closed + deps_merged pending -> un_defer=false" "$PENDING" '.un_defer' "false"
check_field "...reason=deps-merged-check-pending" "$PENDING" '.reason' "deps-merged-check-pending"

# ── 6: a same-run parked blocker never releases, even if it also reads closed+merged+ancestor ──
echo "--- 6: sweep_disposition=parked overrides EVERY other signal ---"
PARKED="$TMP/parked.json"
cat > "$PARKED" <<'JSON'
{"blocker_number": 105, "state": "CLOSED", "linked_merged_prs": [{"number": 205, "mergeCommitOid": "1337"}], "deps_merged": "DEPS_MERGED", "sweep_disposition": "parked"}
JSON
check_field "parked disposition wins over closed+merged+ancestor -> un_defer=false" "$PARKED" '.un_defer' "false"
check_field "...reason=parked-blocker-never-releases" "$PARKED" '.reason' "parked-blocker-never-releases"

echo "--- --help / -h / no-args activation proof ---"
bash "$CLI" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help exits 0" "non-zero exit"
bash "$CLI" -h >/dev/null 2>&1 && ok "-h exits 0" || bad "-h exits 0" "non-zero exit"
bash "$CLI" >/dev/null 2>&1 && ok "no-args exits 0 (prints usage)" || bad "no-args exits 0" "non-zero exit"

echo
if [ "$fail" -gt 0 ]; then
  printf 'test_sweep_blocked_undefer: FAILED %d of %d\n' "$fail" "$((pass + fail))"
  exit 1
fi
printf 'test_sweep_blocked_undefer: OK — all %d checks passed\n' "$pass"
