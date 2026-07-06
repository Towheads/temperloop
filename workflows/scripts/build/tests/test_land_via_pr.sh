#!/usr/bin/env bash
#
# Tests for the shared protected-main kernel (../lib/land-on-protected-main.sh),
# focused on the two #27 root-cause halves observed at epic #13 close:
#
#   (b) The PR path is taken (protected / merge-queue main) but the PR open/adopt
#       step must CONVERGE — never strand the run as
#       "could not open or find the PR for branch". Two adopt paths are exercised:
#         5. `gh pr create` refuses to duplicate and prints the existing PR's URL
#            on stderr ("... already exists: <url>") -> adopt that number.
#         6. Both `pr list` (search-index lag) and `pr create` yield nothing
#            parseable -> `gh pr view <branch>` resolves the PR by head ref.
#
#   (a) On a genuinely UNPROTECTED main (empty branch-rules array),
#       land__requires_pr must read FALSE so the lander takes the direct
#       commit-in-place path; a merge_queue / pull_request rule reads TRUE.
#
# Zero network, fully hermetic: a local bare repo stands in for origin and a fake
# gh drives each adopt branch. Runs archive-plan.sh (the #408 caller) for the PR
# convergence cases and sources the kernel directly for the predicate case.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/archive-plan.sh"
LIB="$(cd "$HERE/../.." && pwd)/lib/land-on-protected-main.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-via-pr-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

PLAN_SRC="$WORK/2026-07-04 temperloop - test epic.md"
printf -- '---\nstatus: done\nepic: 13\n---\n# Test plan\n\n- [x] item one\n' > "$PLAN_SRC"

# Build a protected-style repo (bare origin + seeded main) whose Plans-archive/ is
# empty, so the snapshot is a real diff and the PR-open path is actually reached.
mk_repo() {  # <repo-dir>
  local repo="$1" bare="$1.git"
  git init -q --bare "$bare"
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git -C "$repo" -c init.defaultBranch=main init -q
  git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
  ( cd "$repo" && : > .keep && git add -A && git commit -qm seed )
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
}

# --- 5. adopt via `pr create` "already exists: <url>" on stderr --------------
REPO5="$WORK/repo5"; mkdir -p "$REPO5"; mk_repo "$REPO5"
FB5="$WORK/fb5"; mkdir -p "$FB5"; LOG5="$WORK/gh5.log"
cat > "$FB5/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG5"
case "\$1 \$2" in
  "pr list")   exit 0 ;;                                   # search index lags -> empty
  "pr create") echo 'a pull request for branch "chore/plan-archive" into branch "main" already exists: https://github.com/Towheads/temperloop/pull/25' >&2; exit 1 ;;
  "pr merge")  exit 0 ;;
  *)           exit 0 ;;
esac
EOF
chmod +x "$FB5/gh"
out="$( PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$FB5/gh" \
        bash "$SCRIPT" "$PLAN_SRC" 13 "$REPO5" )"
[[ "$out" == *"plan-archive-pr-queued: 25"* ]] \
  || fail "case 5: expected convergence to adopted PR 25, got: $out"
[[ "$out" == *"could not open or find the PR"* ]] \
  && fail "case 5: run stranded despite an existing PR the create step named"
grep -q "pr merge 25 --auto" "$LOG5" || fail "case 5: auto-merge not armed on the adopted PR"

# --- 6. adopt via `pr view <branch>` when list + create both come up empty ----
REPO6="$WORK/repo6"; mkdir -p "$REPO6"; mk_repo "$REPO6"
FB6="$WORK/fb6"; mkdir -p "$FB6"; LOG6="$WORK/gh6.log"
cat > "$FB6/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG6"
case "\$1 \$2" in
  "pr list")   exit 0 ;;                                   # search index lags -> empty
  "pr create") echo "pull request create failed: transient" >&2; exit 1 ;;   # no URL to parse
  "pr view")   echo 42 ;;                                  # --json number -q .number
  "pr merge")  exit 0 ;;
  *)           exit 0 ;;
esac
EOF
chmod +x "$FB6/gh"
out="$( PLAN_ARCHIVE_REQUIRES_PR=1 PLAN_ARCHIVE_GH="$FB6/gh" \
        bash "$SCRIPT" "$PLAN_SRC" 13 "$REPO6" )"
[[ "$out" == *"plan-archive-pr-queued: 42"* ]] \
  || fail "case 6: expected convergence via pr view to PR 42, got: $out"
grep -q "pr view chore/plan-archive" "$LOG6" \
  || fail "case 6: the pr view head-ref fallback was never consulted"

# --- (a) predicate: land__requires_pr false on empty rules, true on a block ---
# shellcheck source=../../lib/land-on-protected-main.sh
. "$LIB"
REPOA="$WORK/repoA"; mkdir -p "$REPOA"; mk_repo "$REPOA"
FBA="$WORK/fbA"; mkdir -p "$FBA"
# Fake gh that emulates `repo view` and runs the real jq the predicate passes to
# `gh api --jq`, against the canned rules body in $RULES_JSON — so the actual
# any(.[]; .type=="merge_queue" or .type=="pull_request") filter is exercised.
cat > "$FBA/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "Towheads/temperloop"; exit 0 ;;             # repo view --json ... -q ...
  api)
    jqexpr="" prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jqexpr="$a"; prev="$a"; done
    printf '%s' "${RULES_JSON:-[]}" | jq -r "$jqexpr"
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$FBA/gh"

export LAND_ROOT="$REPOA" LAND_GH="$FBA/gh" LAND_DEFAULT_BRANCH="main"
unset LAND_REQUIRES_PR

RULES_JSON='[]' land__requires_pr \
  && fail "(a): land__requires_pr read TRUE on an unprotected main (empty rules) — must be false"
RULES_JSON='[{"type":"merge_queue"}]' land__requires_pr \
  || fail "(a): land__requires_pr read FALSE on a merge_queue-ruled main — must be true"
RULES_JSON='[{"type":"pull_request"}]' land__requires_pr \
  || fail "(a): land__requires_pr read FALSE on a pull_request-ruled main — must be true"
RULES_JSON='[{"type":"non_fast_forward"}]' land__requires_pr \
  && fail "(a): land__requires_pr read TRUE on a non-blocking (non_fast_forward-only) rule set"

echo "PASS: test_land_via_pr.sh"
