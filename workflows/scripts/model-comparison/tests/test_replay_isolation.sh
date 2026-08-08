#!/usr/bin/env bash
#
# test_replay_isolation.sh — fixture suite for
# workflows/scripts/model-comparison/replay.sh (temperloop#1254, epic #1225
# "model comparison harness"): corpus selection (resolve-base, diff-scope,
# corpus), the isolated replay worktree (worktree-prepare/-teardown,
# verify-clean-parent), and the versioned scored-record schema.
#
# Hermetic: `corpus`'s real `gh` reads are replaced by a stub `gh` on PATH
# that replays canned JSON fixtures (zero network); every git fact (fork
# points, merge commits, diffs) is exercised against small THROWAWAY git
# fixture repos built under $TMPDIR — never this repo, never a linked
# worktree. No mapfile / associative arrays / GNU-only flags (bash 3.2).
#
# Sections (mirrors replay.sh's own subcommand order):
#   1-3  resolve-base   — the TRUE fork point (not <merge>^1), a non-2-parent
#                          merge commit REJECTED, a bad sha ERRORs
#   4-9  diff-scope     — N/T/X buckets, unnamed-code-residue REJECTS (wins
#                          over an md-only residue present in the SAME diff),
#                          md-only residue FLAGS (never silently drops), and
#                          an unresolvable base/head FAILS CLOSED (the fix
#                          this suite ships: the inherited script silently
#                          reported {"status":"eligible"} at exit 0 for input
#                          it never read)
#   10-11 corpus        — end-to-end: eligible/flagged/rejected classification
#                          across every rejection reason and both contamination
#                          traps (escalation-resume, post-cut body edit, and
#                          the FLAGGED-not-silently-accepted-or-dropped
#                          unverified case), acceptance-recap extraction +
#                          em-dash-risk flagging, the single-purpose-preferring
#                          rank order, and the REPLAY_CORPUS_SAMPLE_MULTIPLIER
#                          setting wiring
#   12-17 worktree-*    — PREPARED + rewound to the item's OWN base; the three
#                          isolation properties each independently and
#                          DIRECTLY asserted (no push remote — proved by an
#                          actual failed push, not just a config read; the
#                          write-guard class marker; the deterministic
#                          per-repo scratch path); teardown; and the
#                          mid-run-FAILURE cleanup guarantee
#   18   verify-clean-parent — CLEAN/DIRTY, and documented as a BACKSTOP
#   19   schema          — the versioned, fixed scored-record shape, and that
#                          `schema` and `corpus` share the SAME schema_version
#   20   hard constraint — a trailing flag with no value fails fast, bounded,
#                          never hangs
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_isolation.sh
#
# shellcheck disable=SC2016,SC1003
# Many strings below are DELIBERATELY single-quoted and non-expanding: exact
# mutate_file() literal-match source text (must equal replay.sh's real
# source verbatim, including its own $var/${...} tokens and, in a couple of
# cases, a trailing backslash line-continuation), and PR/issue-body fixture
# text carrying literal `backtick-path` markers the diff-scope named-path
# regex is meant to match. Expansion here would be the actual bug.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd "$HERE/.." && pwd)"
SUT="$MC_DIR/replay.sh"

# shellcheck source=../../lib/portable-timeout.sh
. "$HERE/../../lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-isolation-XXXXXX")"
# Physical-path resolve (macOS: $TMPDIR is a symlink into /private/...) —
# replay.sh's own resolve_repo uses `cd -P` too, so every path THIS suite
# builds must already be physical or later string-equality checks against
# replay.sh's JSON output (which always reports the physical path) mismatch.
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

gitc() { git -c user.name="Replay Test" -c user.email="replay-test@example.com" -c commit.gpgsign=false "$@"; }

# mutate_file <file> <old-literal-text> <new-literal-text> — an exact,
# literal (never regex-metacharacter-interpreted) single-occurrence
# replacement, used to temporarily break a mechanism for a mutation proof.
# Dies loudly (non-zero, caller must check) if the old text is missing OR
# appears more than once — never a silent no-op that would let a "mutation
# proof" pass without actually mutating anything.
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — fixture repo for resolve-base (fork-point) tests
# ═══════════════════════════════════════════════════════════════════════════
FP_FIX="$WORK/fp-fixture"
mkdir -p "$FP_FIX"
gitc -C "$FP_FIX" init -q
git -C "$FP_FIX" symbolic-ref HEAD refs/heads/main
printf 'base\n' >"$FP_FIX/README.md"
gitc -C "$FP_FIX" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$FP_FIX" commit -q -m "base"
FP_C0="$(git -C "$FP_FIX" rev-parse HEAD)"

# A feature branch forked from C0 — one commit, touches README.md only.
gitc -C "$FP_FIX" checkout -q -b feat "$FP_C0"
printf 'base\nfeature change\n' >"$FP_FIX/README.md"
gitc -C "$FP_FIX" add -A
GIT_AUTHOR_DATE="2024-01-02T00:00:00Z" GIT_COMMITTER_DATE="2024-01-02T00:00:00Z" \
  gitc -C "$FP_FIX" commit -q -m "feature work"
FP_F1="$(git -C "$FP_FIX" rev-parse HEAD)"

# main ADVANCES independently (a sibling PR landing while this one was open)
# — a DIFFERENT file, so the later merge is conflict-free.
gitc -C "$FP_FIX" checkout -q main
printf 'unrelated\n' >"$FP_FIX/main-advance.txt"
gitc -C "$FP_FIX" add -A
GIT_AUTHOR_DATE="2024-01-03T00:00:00Z" GIT_COMMITTER_DATE="2024-01-03T00:00:00Z" \
  gitc -C "$FP_FIX" commit -q -m "unrelated main advance"
FP_C2="$(git -C "$FP_FIX" rev-parse HEAD)"

# Merge feat into main (now at C2) — parents = [C2, F1]; merge-base is C0,
# NOT C2 (which is what a naive `<merge>^1` read would wrongly return).
GIT_AUTHOR_DATE="2024-01-04T00:00:00Z" GIT_COMMITTER_DATE="2024-01-04T00:00:00Z" \
  gitc -C "$FP_FIX" merge -q --no-ff -m "Merge feat" feat
FP_M="$(git -C "$FP_FIX" rev-parse HEAD)"
FP_M_PARENT1="$(git -C "$FP_FIX" rev-parse "${FP_M}^1")"
[ "$FP_M_PARENT1" = "$FP_C2" ] || fail "fixture setup: M^1 should be C2, got $FP_M_PARENT1"

# ---------------------------------------------------------------------------
# 1. resolve-base returns the TRUE FORK POINT (merge-base of the two
#    parents), never <merge>^1 — the case that made 21/60 merged PRs
#    disagree across candidate base-resolution strategies (spike fact 1).
# ---------------------------------------------------------------------------
count
out="$(bash "$SUT" resolve-base "$FP_FIX" "$FP_M")"
[ "$(jq -r .outcome <<<"$out")" = "BASE_RESOLVED" ] || fail "1: expected BASE_RESOLVED, got: $out"
resolved_base="$(jq -r .base <<<"$out")"
resolved_head="$(jq -r .head <<<"$out")"
[ "$resolved_base" = "$FP_C0" ] || fail "1: base should be the fork point C0 ($FP_C0), got $resolved_base"
[ "$resolved_base" != "$FP_C2" ] || fail "1: base must NOT be C2 (that is what a naive <merge>^1 read would wrongly return)"
[ "$resolved_head" = "$FP_F1" ] || fail "1: head should be the feature tip F1 ($FP_F1), got $resolved_head"
ok "1 resolve-base returns the true fork point, not <merge>^1"

# --- mutation proof: swap merge-base for a naive <merge>^1 read -----------
count
cp "$SUT" "$WORK/replay.sh.orig-1"
mutate_file "$SUT" \
  'base="$(git -C "$repo" merge-base "${mc}^1" "${mc}^2" 2>/dev/null)"' \
  'base="$(git -C "$repo" rev-parse "${mc}^1" 2>/dev/null)"' \
  || fail "1m: mutation apply failed"
mut_out="$(bash "$SUT" resolve-base "$FP_FIX" "$FP_M")"
mut_base="$(jq -r .base <<<"$mut_out" 2>/dev/null)"
cp "$WORK/replay.sh.orig-1" "$SUT"
[ "$mut_base" = "$FP_C2" ] || fail "1m: mutation (naive ^1) should have produced base=C2 ($FP_C2), got $mut_base — mutation didn't take effect as expected"
ok "1m MUTATION PROOF: reverting merge-base to a naive <merge>^1 flips the resolved base to C2 (wrong) — restored, the real script gave C0 (test 1 above)"

# ---------------------------------------------------------------------------
# 2. resolve-base REJECTS a non-2-parent commit (squash/rebase-merge shape).
# ---------------------------------------------------------------------------
count
out="$(bash "$SUT" resolve-base "$FP_FIX" "$FP_C2")"
[ "$(jq -r .outcome <<<"$out")" = "REJECTED" ] || fail "2: expected REJECTED for a 1-parent commit, got: $out"
[ "$(jq -r .reason <<<"$out")" = "squash-or-rebase-merge" ] || fail "2: expected reason squash-or-rebase-merge, got: $out"
[ "$(jq -r .parents <<<"$out")" = "1" ] || fail "2: expected parents:1, got: $out"
ok "2 resolve-base rejects a non-2-parent commit as squash-or-rebase-merge"

# ---------------------------------------------------------------------------
# 3. resolve-base ERRORs (non-zero) on a merge commit sha that doesn't exist.
# ---------------------------------------------------------------------------
count
rc=0
out="$(bash "$SUT" resolve-base "$FP_FIX" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "3: resolve-base should fail on a nonexistent merge commit sha"
[ "$(jq -r .outcome <<<"$out" 2>/dev/null)" = "ERROR" ] || fail "3: expected ERROR outcome, got: $out"
ok "3 resolve-base errors (non-zero) on a nonexistent merge commit sha"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — fixture repo for diff-scope (N/T/X/R partition) tests
# ═══════════════════════════════════════════════════════════════════════════
DS_FIX="$WORK/ds-fixture"
mkdir -p "$DS_FIX/src" "$DS_FIX/tests"
gitc -C "$DS_FIX" init -q
git -C "$DS_FIX" symbolic-ref HEAD refs/heads/main
printf 'v0\n' >"$DS_FIX/src/named.sh"
printf 'v0\n' >"$DS_FIX/tests/test_thing.sh"
printf 'v0\n' >"$DS_FIX/CHANGELOG.md"
gitc -C "$DS_FIX" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$DS_FIX" commit -q -m "base"
DS_C0="$(git -C "$DS_FIX" rev-parse HEAD)"

ISSUE_NAMED="$WORK/issue-named.txt"
printf 'Please update `src/named.sh`.\n' >"$ISSUE_NAMED"

# C1: clean N + T + X edit, no residue at all.
gitc -C "$DS_FIX" checkout -q -b c1 "$DS_C0"
printf 'v1\n' >>"$DS_FIX/src/named.sh"
printf 'v1\n' >>"$DS_FIX/tests/test_thing.sh"
printf 'v1\n' >>"$DS_FIX/CHANGELOG.md"
gitc -C "$DS_FIX" add -A
GIT_AUTHOR_DATE="2024-01-02T00:00:00Z" GIT_COMMITTER_DATE="2024-01-02T00:00:00Z" \
  gitc -C "$DS_FIX" commit -q -m "c1"
DS_C1="$(git -C "$DS_FIX" rev-parse HEAD)"

# C2: unnamed CODE residue AND unnamed MD residue in the SAME diff, no named
# edits at all — proves code-residue rejection wins even when md residue is
# also present (the `elif` ordering).
gitc -C "$DS_FIX" checkout -q -b c2 "$DS_C0"
printf 'new\n' >"$DS_FIX/src/unnamed.sh"
printf 'new\n' >"$DS_FIX/docs-unnamed.md"
gitc -C "$DS_FIX" add -A
GIT_AUTHOR_DATE="2024-01-02T00:00:00Z" GIT_COMMITTER_DATE="2024-01-02T00:00:00Z" \
  gitc -C "$DS_FIX" commit -q -m "c2"
DS_C2="$(git -C "$DS_FIX" rev-parse HEAD)"

# C3: unnamed MD residue ONLY (no code residue) — flagged-eligible.
gitc -C "$DS_FIX" checkout -q -b c3 "$DS_C0"
printf 'new\n' >"$DS_FIX/docs-unnamed2.md"
gitc -C "$DS_FIX" add -A
GIT_AUTHOR_DATE="2024-01-02T00:00:00Z" GIT_COMMITTER_DATE="2024-01-02T00:00:00Z" \
  gitc -C "$DS_FIX" commit -q -m "c3"
DS_C3="$(git -C "$DS_FIX" rev-parse HEAD)"

# ---------------------------------------------------------------------------
# 4-6. N/T/X buckets: a named+base-existing+changed path lands in N, a test
#      path lands in T, a policy-churn path lands in X and stays NEUTRAL
#      (status stays eligible with all three buckets populated).
# ---------------------------------------------------------------------------
count
out="$(bash "$SUT" diff-scope "$DS_FIX" "$DS_C0" "$DS_C1" --issue-text-file "$ISSUE_NAMED")"
[ "$(jq -r .status <<<"$out")" = "eligible" ] || fail "4-6: expected eligible, got: $out"
[ "$(jq -c .buckets.N <<<"$out")" = '["src/named.sh"]' ] || fail "4: N bucket wrong: $out"
[ "$(jq -c .buckets.T <<<"$out")" = '["tests/test_thing.sh"]' ] || fail "5: T bucket wrong: $out"
[ "$(jq -c .buckets.X <<<"$out")" = '["CHANGELOG.md"]' ] || fail "6: X bucket wrong: $out"
[ "$(jq -c .buckets.R <<<"$out")" = '[]' ] || fail "4-6: R bucket should be empty: $out"
ok "4-6 diff-scope: N/T/X buckets correctly classified; policy-churn (X) stays neutral (status still eligible)"

# ---------------------------------------------------------------------------
# 7. Unnamed CODE residue -> REJECTED (unnamed-code-residue), even with an
#    unnamed MD file ALSO present in the same diff — code-residue rejection
#    takes precedence over the md-only flag path.
# ---------------------------------------------------------------------------
count
out="$(bash "$SUT" diff-scope "$DS_FIX" "$DS_C0" "$DS_C2" --issue-text-file "$ISSUE_NAMED")"
[ "$(jq -r .status <<<"$out")" = "rejected" ] || fail "7: expected rejected, got: $out"
[ "$(jq -r .reason <<<"$out")" = "unnamed-code-residue" ] || fail "7: expected unnamed-code-residue, got: $out"
case "$(jq -c .buckets.R <<<"$out")" in
  *docs-unnamed.md*src/unnamed.sh*|*src/unnamed.sh*docs-unnamed.md*) ;;
  *) fail "7: R bucket should carry BOTH the code and md residue paths: $out" ;;
esac
ok "7 diff-scope: unnamed code residue rejects (wins over an md-only residue present in the same diff)"

# ---------------------------------------------------------------------------
# 8. Unnamed MD-ONLY residue -> FLAGGED-eligible (residue-md-only), never
#    silently included as clean nor silently dropped as rejected.
# ---------------------------------------------------------------------------
count
out="$(bash "$SUT" diff-scope "$DS_FIX" "$DS_C0" "$DS_C3" --issue-text-file "$ISSUE_NAMED")"
[ "$(jq -r .status <<<"$out")" = "flagged-eligible" ] || fail "8: expected flagged-eligible, got: $out"
[ "$(jq -c .flags <<<"$out")" = '["residue-md-only"]' ] || fail "8: expected residue-md-only flag, got: $out"
[ "$(jq -c .buckets.R <<<"$out")" = '["docs-unnamed2.md"]' ] || fail "8: R bucket wrong: $out"
ok "8 diff-scope: an md-only residue FLAGS as flagged-eligible, never silently accepted or dropped"

# ---------------------------------------------------------------------------
# 9. FAIL CLOSED on an unresolvable base/head. Before the fix this suite
#    ships, diff-scope silently printed {"outcome":"SCOPED","status":
#    "eligible",...} at exit 0 for input it never actually read (`git diff`
#    on a bad rev prints nothing to stdout and is swallowed by 2>/dev/null),
#    the exact "validator says OK when it can't read its input" shape.
# ---------------------------------------------------------------------------
count
rc=0
out="$(bash "$SUT" diff-scope "$DS_FIX" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef cafebabecafebabecafebabecafebabecafebabe 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "9: diff-scope should fail (non-zero) on an unresolvable base/head"
[ "$(jq -r .outcome <<<"$out" 2>/dev/null)" = "ERROR" ] || fail "9: expected ERROR outcome, got: $out"
case "$out" in *'"status":"eligible"'*) fail "9: FAIL-OPEN — diff-scope reported a false eligible verdict for unreadable input: $out" ;; esac
ok "9 diff-scope fails CLOSED (ERROR, non-zero) on an unresolvable base/head — never a false eligible verdict"

# --- mutation proof: restore the fail-open behavior, confirm RED, restore -
count
cp "$SUT" "$WORK/replay.sh.orig-9"
mutate_file "$SUT" \
  'if ! git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null; then' \
  'if false; then' \
  || fail "9m: mutation apply (base check) failed"
mutate_file "$SUT" \
  'if ! git -C "$repo" cat-file -e "${head}^{commit}" 2>/dev/null; then' \
  'if false; then' \
  || fail "9m: mutation apply (head check) failed"
rc=0
mut_out="$(bash "$SUT" diff-scope "$DS_FIX" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef cafebabecafebabecafebabecafebabecafebabe 2>&1)" || rc=$?
cp "$WORK/replay.sh.orig-9" "$SUT"
[ "$rc" -eq 0 ] || fail "9m: expected the mutated (pre-fix) script to exit 0 (fail-open), got rc=$rc"
case "$mut_out" in
  *'"status":"eligible"'*) ;;
  *) fail "9m: expected the mutated script to reproduce the false-eligible bug, got: $mut_out" ;;
esac
ok "9m MUTATION PROOF: removing the fail-closed base/head check reproduces the false-eligible-at-exit-0 bug — restored, test 9 above is green again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — fixture repo + stub gh for the `corpus` end-to-end pipeline
# ═══════════════════════════════════════════════════════════════════════════
CORPUS_FIX="$WORK/corpus-fixture"
mkdir -p "$CORPUS_FIX/src" "$CORPUS_FIX/tests" "$CORPUS_FIX/claude/workflows"
gitc -C "$CORPUS_FIX" init -q
git -C "$CORPUS_FIX" symbolic-ref HEAD refs/heads/main
printf 'base\n' >"$CORPUS_FIX/README.md"
printf 'v0\n' >"$CORPUS_FIX/src/foot3-a.sh"
printf 'v0\n' >"$CORPUS_FIX/src/foot3-b.sh"
printf 'v0\n' >"$CORPUS_FIX/src/foot3-c.sh"
printf 'v0\n' >"$CORPUS_FIX/src/foot2-a.sh"
printf 'v0\n' >"$CORPUS_FIX/src/foot2-b.sh"
printf 'v0\n' >"$CORPUS_FIX/src/foot1-a.sh"
printf 'v0\n' >"$CORPUS_FIX/src/pr308.sh"
printf 'v0\n' >"$CORPUS_FIX/src/pr309.sh"
printf 'v0\n' >"$CORPUS_FIX/tests/test_placeholder.sh"
printf '// build-level dummy\n' >"$CORPUS_FIX/claude/workflows/build-level.mjs"
gitc -C "$CORPUS_FIX" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$CORPUS_FIX" commit -q -m "base"
CORPUS_BASE="$(git -C "$CORPUS_FIX" rev-parse HEAD)"
TEMPLATE_SHA_EXPECTED="$(git -C "$CORPUS_FIX" rev-parse "${CORPUS_BASE}:claude/workflows/build-level.mjs")"

T1="2024-02-01T00:00:00Z"      # every PR's single feature commit — uniform t_cut
PR_CREATED="2024-02-02T00:00:00Z"

# mk_pr_branch <branch> <path> <line> [<path> <line> ...] — forks from
# CORPUS_BASE, appends (or creates) each path with one line, commits at T1.
mk_pr_branch() {
  local branch="$1"; shift
  git -C "$CORPUS_FIX" checkout -q -b "$branch" "$CORPUS_BASE"
  while [ $# -ge 2 ]; do
    local path="$1" line="$2"; shift 2
    mkdir -p "$(dirname "$CORPUS_FIX/$path")"
    printf '%s\n' "$line" >>"$CORPUS_FIX/$path"
  done
  gitc -C "$CORPUS_FIX" add -A
  GIT_AUTHOR_DATE="$T1" GIT_COMMITTER_DATE="$T1" gitc -C "$CORPUS_FIX" commit -q -m "feature: $branch"
}

# mk_pr_merge <branch> — merges into main (--no-ff), prints the merge sha.
mk_pr_merge() {
  git -C "$CORPUS_FIX" checkout -q main
  GIT_AUTHOR_DATE="2024-03-01T00:00:00Z" GIT_COMMITTER_DATE="2024-03-01T00:00:00Z" \
    gitc -C "$CORPUS_FIX" merge -q --no-ff -m "Merge $1" "$1"
  git -C "$CORPUS_FIX" rev-parse HEAD
}

# PR 301 — largest footprint (3 named files); ranks LAST among the eligible
# tier despite being the FIRST PR emitted (proves ranking is by file_count,
# not insertion/PR-number order).
mk_pr_branch pr301 src/foot3-a.sh "edit a" src/foot3-b.sh "edit b" src/foot3-c.sh "edit c"
MC301="$(mk_pr_merge pr301)"
# PR 302 — mid footprint (2 named files); carries a double-em-dash acceptance
# bullet (criterion-embedded-em-dash flag), still status=eligible.
mk_pr_branch pr302 src/foot2-a.sh "edit a" src/foot2-b.sh "edit b"
MC302="$(mk_pr_merge pr302)"
# PR 303 — smallest footprint (1 named file); its issue's post-cut-edit
# GraphQL probe FAILS (simulated API hiccup) -> flagged, never rejected and
# never silently accepted.
mk_pr_branch pr303 src/foot1-a.sh "edit a"
MC303="$(mk_pr_merge pr303)"
# PR 304 — a lone unnamed .md residue file -> flagged-eligible.
mk_pr_branch pr304 docs/notes-304.md "unrelated note"
MC304="$(mk_pr_merge pr304)"
# PR 307 — a lone unnamed .sh residue file -> rejected unnamed-code-residue.
mk_pr_branch pr307 src/scratch-307.sh "unnamed new file"
MC307="$(mk_pr_merge pr307)"
# PR 308 — clean named edit, but its issue carries a POST-CUT escalation
# comment ("Parked by /sweep") -> rejected escalation-resume-at-or-after-cut.
mk_pr_branch pr308 src/pr308.sh "edit"
MC308="$(mk_pr_merge pr308)"
# PR 309 — clean named edit, but GraphQL reports the issue body was edited
# AFTER t_cut -> rejected post-cut-issue-body-edit.
mk_pr_branch pr309 src/pr309.sh "edit"
MC309="$(mk_pr_merge pr309)"

git -C "$CORPUS_FIX" checkout -q main

# --- fake `gh` on PATH ------------------------------------------------------
STUBBIN="$WORK/bin"
mkdir -p "$STUBBIN"
GH_CALL_LOG="$WORK/gh-calls.log"
: >"$GH_CALL_LOG"
FIXDIR="$WORK/gh-fixtures"
mkdir -p "$FIXDIR"
PR_LIST_FILE="$WORK/pr-list.json"

cat >"$STUBBIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  cat "$GH_PR_LIST_FILE"
  exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  f="$GH_FIXTURE_DIR/pr-$3.json"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  f="$GH_FIXTURE_DIR/issue-$3.json"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  num=""
  for a in "$@"; do
    case "$a" in
      number=*) num="${a#number=}" ;;
    esac
  done
  case "$num" in
    2303) exit 1 ;;   # simulated API hiccup: no output, non-zero
  esac
  f="$GH_FIXTURE_DIR/graphql-$num.json"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
exit 1
FAKE_GH
chmod +x "$STUBBIN/gh"

# --- gh fixture bodies -------------------------------------------------------
mk_pr_view() {
  local num="$1" body="$2"
  jq -cn --arg body "$body" --arg title "PR $num" --arg created "$PR_CREATED" \
    '{body:$body, title:$title, baseRefName:"main", createdAt:$created}' \
    >"$FIXDIR/pr-$num.json"
}
mk_issue_view() {
  local num="$1" body="$2" comments="$3"
  jq -cn --arg body "$body" --argjson comments "$comments" --arg title "Issue $num" \
    --arg created "2024-01-01T00:00:00Z" \
    '{body:$body, comments:$comments, createdAt:$created, title:$title}' \
    >"$FIXDIR/issue-$num.json"
}
mk_graphql() {
  local num="$1" last_edited="$2"
  jq -cn --arg le "$last_edited" '{data:{repository:{issue:{lastEditedAt:$le}}}}' \
    >"$FIXDIR/graphql-$num.json"
}

SAFE_EDIT="2024-01-10T00:00:00Z"   # well before t_cut
LATE_EDIT="2024-02-15T00:00:00Z"   # well after t_cut

mk_pr_view 301 "$(printf '## Acceptance\n- [x] Foo behaves correctly — verified manually\n')"
mk_issue_view 2301 'Please update `src/foot3-a.sh`, `src/foot3-b.sh`, and `src/foot3-c.sh`.' '[]'
mk_graphql 2301 "$SAFE_EDIT"

mk_pr_view 302 "$(printf '## Acceptance\n- [x] Bar and baz updated — first note — second note\n')"
mk_issue_view 2302 'Please update `src/foot2-a.sh` and `src/foot2-b.sh`.' '[]'
mk_graphql 2302 "$SAFE_EDIT"

mk_pr_view 303 "$(printf '## Acceptance\n- [x] Small file updated — verified\n')"
mk_issue_view 2303 'Please update `src/foot1-a.sh`.' '[]'
# no graphql-2303.json — the stub deliberately fails this call

mk_pr_view 304 "$(printf '## Acceptance\n- [x] Docs note added — fyi\n')"
mk_issue_view 2304 'General docs cleanup, no specific file named.' '[]'
mk_graphql 2304 "$SAFE_EDIT"

mk_pr_view 307 "$(printf '## Acceptance\n- [x] Scratch added — oops\n')"
mk_issue_view 2308 'Investigate and fix the reported issue.' '[]'
mk_graphql 2308 "$SAFE_EDIT"

mk_pr_view 308 "$(printf '## Acceptance\n- [x] 308 edit — done\n')"
mk_issue_view 2309 'Please update `src/pr308.sh`.' \
  '[{"createdAt":"2024-02-10T00:00:00Z","body":"Parked by /sweep — needs scope clarification."}]'
# no graphql-2309.json — the escalation reject fires before the GraphQL call

mk_pr_view 309 "$(printf '## Acceptance\n- [x] 309 edit — done\n')"
mk_issue_view 2310 'Please update `src/pr309.sh`.' '[]'
mk_graphql 2310 "$LATE_EDIT"

# --- gh pr list ---------------------------------------------------------------
pr_obj() {
  local num="$1" mc="$2" cir="$3" title="$4"
  if [ -n "$mc" ]; then
    jq -cn --argjson num "$num" --arg mc "$mc" --argjson cir "$cir" --arg title "$title" --arg created "$PR_CREATED" \
      '{number:$num, mergeCommit:{oid:$mc}, closingIssuesReferences:$cir, title:$title,
        url:("https://example.invalid/pr/"+($num|tostring)), createdAt:$created}'
  else
    jq -cn --argjson num "$num" --argjson cir "$cir" --arg title "$title" --arg created "$PR_CREATED" \
      '{number:$num, mergeCommit:null, closingIssuesReferences:$cir, title:$title,
        url:("https://example.invalid/pr/"+($num|tostring)), createdAt:$created}'
  fi
}
{
  pr_obj 301 "$MC301" '[{"number":2301}]' "Fix pr301"
  pr_obj 302 "$MC302" '[{"number":2302}]' "Fix pr302"
  pr_obj 303 "$MC303" '[{"number":2303}]' "Fix pr303"
  pr_obj 304 "$MC304" '[{"number":2304}]' "Fix pr304"
  pr_obj 305 "$CORPUS_BASE" '[{"number":2305}]' "Fix pr305"           # squash/rebase: 0-parent root commit
  pr_obj 306 "$CORPUS_BASE" '[{"number":2306},{"number":2307}]' "Fix pr306"  # multi-issue
  pr_obj 307 "$MC307" '[{"number":2308}]' "Fix pr307"
  pr_obj 308 "$MC308" '[{"number":2309}]' "Fix pr308"
  pr_obj 309 "$MC309" '[{"number":2310}]' "Fix pr309"
  pr_obj 310 "" '[{"number":2311}]' "Fix pr310"                        # no merge commit at all
} | jq -s '.' >"$PR_LIST_FILE"

run_corpus() {
  env GH_CALL_LOG="$GH_CALL_LOG" GH_PR_LIST_FILE="$PR_LIST_FILE" GH_FIXTURE_DIR="$FIXDIR" \
      PATH="$STUBBIN:$PATH" bash "$SUT" corpus "$@"
}

# ---------------------------------------------------------------------------
# 10. corpus end-to-end: classification, contamination traps, acceptance
#     extraction + em-dash flagging, and the single-purpose-preferring rank.
# ---------------------------------------------------------------------------
count
OUT="$WORK/corpus-out.jsonl"
corpus_rc=0
run_corpus --repo fixture-org/fixture-repo --repo-root "$CORPUS_FIX" --limit 20 --out "$OUT" || corpus_rc=$?
[ "$corpus_rc" -eq 0 ] || fail "10: corpus command failed unexpectedly (rc=$corpus_rc); log:
$(cat "$GH_CALL_LOG")"

n_records="$(grep -c . "$OUT")"
[ "$n_records" -eq 10 ] || fail "10: expected 10 records (one per gh-pr-list entry), got $n_records"

record_of() { jq -c --argjson pr "$1" 'select(.pr==$pr)' "$OUT"; }

# 301: eligible, largest footprint (3), template_sha resolves, base is the
# true fork point (not main's post-merge tip — several other PRs merged
# after it), acceptance evidence tail stripped, no em-dash flag (single dash).
r="$(record_of 301)"
[ "$(jq -r .status <<<"$r")" = "eligible" ] || fail "10.301: expected eligible: $r"
[ "$(jq -r .file_count <<<"$r")" = "3" ] || fail "10.301: expected file_count 3: $r"
[ "$(jq -r .base <<<"$r")" = "$CORPUS_BASE" ] || fail "10.301: base should be the true fork point $CORPUS_BASE: $r"
[ "$(jq -r .template_sha <<<"$r")" = "$TEMPLATE_SHA_EXPECTED" ] || fail "10.301: template_sha wrong: $r"
[ "$(jq -r '.acceptance[0]' <<<"$r")" = "Foo behaves correctly" ] || fail "10.301: acceptance evidence tail should be stripped: $r"
[ "$(jq -c .flags <<<"$r")" = "[]" ] || fail "10.301: expected no flags: $r"

# 302: eligible, mid footprint (2), em-dash-risk FLAGGED (2 embedded dashes),
# acceptance split at the LAST em-dash.
r="$(record_of 302)"
[ "$(jq -r .status <<<"$r")" = "eligible" ] || fail "10.302: expected eligible: $r"
[ "$(jq -r .file_count <<<"$r")" = "2" ] || fail "10.302: expected file_count 2: $r"
[ "$(jq -r '.acceptance[0]' <<<"$r")" = "Bar and baz updated — first note" ] || fail "10.302: split-at-last-em-dash wrong: $r"
case "$(jq -c .flags <<<"$r")" in *criterion-embedded-em-dash*) ;; *) fail "10.302: expected criterion-embedded-em-dash flag: $r" ;; esac

# 303: eligible, smallest footprint (1), post-cut-edit-unverified FLAGGED
# (graphql failed) — never silently rejected, never silently accepted clean.
r="$(record_of 303)"
[ "$(jq -r .status <<<"$r")" = "eligible" ] || fail "10.303: expected eligible (flagged, not rejected): $r"
[ "$(jq -r .file_count <<<"$r")" = "1" ] || fail "10.303: expected file_count 1: $r"
case "$(jq -c .flags <<<"$r")" in *post-cut-edit-unverified*) ;; *) fail "10.303: expected post-cut-edit-unverified flag: $r" ;; esac

# 304: flagged-eligible (residue-md-only).
r="$(record_of 304)"
[ "$(jq -r .status <<<"$r")" = "flagged-eligible" ] || fail "10.304: expected flagged-eligible: $r"
[ "$(jq -c .flags <<<"$r")" = '["residue-md-only"]' ] || fail "10.304: expected residue-md-only flag: $r"

# 305: rejected, squash-or-rebase-merge (the base commit has 0 parents).
r="$(record_of 305)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.305: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "squash-or-rebase-merge" ] || fail "10.305: expected squash-or-rebase-merge: $r"

# 306: rejected, multi-or-zero-issue-pr (closingIssuesReferences length 2).
r="$(record_of 306)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.306: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "multi-or-zero-issue-pr" ] || fail "10.306: expected multi-or-zero-issue-pr: $r"

# 307: rejected, unnamed-code-residue.
r="$(record_of 307)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.307: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "unnamed-code-residue" ] || fail "10.307: expected unnamed-code-residue: $r"

# 308: rejected, escalation-resume-at-or-after-cut (trap D first half).
r="$(record_of 308)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.308: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "escalation-resume-at-or-after-cut" ] || fail "10.308: expected escalation-resume-at-or-after-cut: $r"

# 309: rejected, post-cut-issue-body-edit (trap D second half, via graphql).
r="$(record_of 309)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.309: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "post-cut-issue-body-edit" ] || fail "10.309: expected post-cut-issue-body-edit: $r"

# 310: rejected, no-merge-commit.
r="$(record_of 310)"
[ "$(jq -r .status <<<"$r")" = "rejected" ] || fail "10.310: expected rejected: $r"
[ "$(jq -r .reject_reason <<<"$r")" = "no-merge-commit" ] || fail "10.310: expected no-merge-commit: $r"

# Every record carries the same, current schema_version.
while IFS= read -r line; do
  sv="$(jq -r .schema_version <<<"$line")"
  [ "$sv" = "replay-record-v1" ] || fail "10: record carries wrong schema_version $sv: $line"
done <"$OUT"

ok "10 corpus: every status/reject_reason/flag classification correct across all ten fixture PRs"

# ---------------------------------------------------------------------------
# 10b. Ranking: eligible tier precedes flagged-eligible precedes rejected;
#      WITHIN the eligible tier, ascending by file_count (303 < 302 < 301) —
#      note this is the OPPOSITE of PR-number/insertion order (301,302,303
#      were emitted in that order but have footprints 3,2,1), so a sort that
#      merely preserved insertion order would NOT satisfy this.
# ---------------------------------------------------------------------------
count
prs=()
statuses=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  prs+=("$(jq -r .pr <<<"$line")")
  statuses+=("$(jq -r .status <<<"$line")")
done <"$OUT"

tier_of() {
  case "$1" in
    eligible) echo 0 ;;
    flagged-eligible) echo 1 ;;
    *) echo 2 ;;
  esac
}
prev_tier=0
tier_monotonic=1
for i in "${!statuses[@]}"; do
  t="$(tier_of "${statuses[$i]}")"
  [ "$t" -lt "$prev_tier" ] && tier_monotonic=0
  prev_tier="$t"
done
[ "$tier_monotonic" -eq 1 ] || fail "10b: tiers are not monotonic (eligible, then flagged-eligible, then rejected): ${statuses[*]}"

pos_of() {
  local target="$1" i
  for i in "${!prs[@]}"; do
    [ "${prs[$i]}" = "$target" ] && { echo "$i"; return 0; }
  done
  echo "-1"
}
p301="$(pos_of 301)"; p302="$(pos_of 302)"; p303="$(pos_of 303)"
[ "$p303" -ge 0 ] && [ "$p302" -ge 0 ] && [ "$p301" -ge 0 ] || fail "10b: fixture PRs missing from output: $p301 $p302 $p303"
[ "$p303" -lt "$p302" ] || fail "10b: 303 (file_count 1) should rank before 302 (file_count 2); positions: 303=$p303 302=$p302"
[ "$p302" -lt "$p301" ] || fail "10b: 302 (file_count 2) should rank before 301 (file_count 3); positions: 302=$p302 301=$p301"
ok "10b corpus ranking: eligible < flagged-eligible < rejected tiers, and within eligible ascending by file_count (single-purpose preferred over insertion order)"

# --- mutation proof: drop the file_count secondary sort key ---------------
count
cp "$SUT" "$WORK/replay.sh.orig-10b"
mutate_file "$SUT" \
  '      (if .status=="eligible" then 0 elif .status=="flagged-eligible" then 1 else 2 end),
      (.file_count // 999999)
    ) | .[]' \
  '      (if .status=="eligible" then 0 elif .status=="flagged-eligible" then 1 else 2 end)
    ) | .[]' \
  || fail "10bm: mutation apply failed"
MUT_OUT="$WORK/corpus-out-mut.jsonl"
run_corpus --repo fixture-org/fixture-repo --repo-root "$CORPUS_FIX" --limit 20 --out "$MUT_OUT" >/dev/null
mut_prs=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  st="$(jq -r .status <<<"$line")"
  [ "$st" = "eligible" ] || continue
  mut_prs+=("$(jq -r .pr <<<"$line")")
done <"$MUT_OUT"
cp "$WORK/replay.sh.orig-10b" "$SUT"
# With the secondary key gone, jq's stable sort preserves EMISSION order
# (301,302,303 — ascending PR number, i.e. DESCENDING file_count) instead of
# ascending file_count (303,302,301).
[ "${mut_prs[0]}" = "301" ] || fail "10bm: expected the mutated (insertion-order) output to start with 301, got ${mut_prs[*]}"
ok "10bm MUTATION PROOF: dropping the file_count secondary sort key falls back to insertion order (301 first) — restored, test 10b above is green again"

# ---------------------------------------------------------------------------
# 11. REPLAY_CORPUS_SAMPLE_MULTIPLIER wiring: --target N with no --limit
#     computes limit = N * multiplier (default multiplier 2) and passes it
#     to `gh pr list`.
# ---------------------------------------------------------------------------
count
: >"$GH_CALL_LOG"
run_corpus --repo fixture-org/fixture-repo --repo-root "$CORPUS_FIX" --target 5 --out "$WORK/corpus-target.jsonl" >/dev/null
# A single alternation (never two `grep -q` calls joined by `||` — the
# lint-pipe-grep-q.sh scanner's naive `\|` match mistakes the SECOND `|` of
# `||` for a pipe) matching "--limit 10" followed by a space or end of line.
grep -Eq -- '--limit 10( |$)' "$GH_CALL_LOG" \
  || fail "11: expected gh pr list to be called with --limit 10 (5 * REPLAY_CORPUS_SAMPLE_MULTIPLIER=2); calls:
$(cat "$GH_CALL_LOG")"
ok "11 corpus --target N sizes --limit via the registered REPLAY_CORPUS_SAMPLE_MULTIPLIER setting"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — fixture repo WITH an origin remote, for worktree-prepare /
# worktree-teardown (worktree.sh's `create` requires resolving origin/HEAD).
# ═══════════════════════════════════════════════════════════════════════════
WT_ORIGIN="$WORK/wt-origin.git"
git init -q --bare "$WT_ORIGIN"
git -C "$WT_ORIGIN" symbolic-ref HEAD refs/heads/main

WT_FIX="$WORK/wt-fixture"
mkdir -p "$WT_FIX"
gitc -C "$WT_FIX" init -q
git -C "$WT_FIX" symbolic-ref HEAD refs/heads/main
printf 'wt fixture base\n' >"$WT_FIX/README.md"
gitc -C "$WT_FIX" add -A
GIT_AUTHOR_DATE="2024-01-01T00:00:00Z" GIT_COMMITTER_DATE="2024-01-01T00:00:00Z" \
  gitc -C "$WT_FIX" commit -q -m "base"
WT_BASE="$(git -C "$WT_FIX" rev-parse HEAD)"
gitc -C "$WT_FIX" remote add origin "$WT_ORIGIN"
git -C "$WT_FIX" push -q origin main
git -C "$WT_FIX" remote set-head origin -a >/dev/null

PREP_SLUG="replay-test-slug"
WT_PATH_EXPECTED="${WT_FIX}.wt/${PREP_SLUG}"

# ---------------------------------------------------------------------------
# 12. worktree-prepare: PREPARED, and rewound to the ITEM'S OWN base (not
#     origin/<default>'s tip).
# ---------------------------------------------------------------------------
count
PREP_OUT="$(bash "$SUT" worktree-prepare "$WT_FIX" "$PREP_SLUG" "$WT_BASE")"
[ "$(jq -r .outcome <<<"$PREP_OUT")" = "PREPARED" ] || fail "12: expected PREPARED, got: $PREP_OUT"
wt_path="$(jq -r .path <<<"$PREP_OUT")"
[ -d "$wt_path" ] || fail "12: prepared worktree path does not exist: $wt_path"
wt_head="$(git -C "$wt_path" rev-parse HEAD)"
[ "$wt_head" = "$WT_BASE" ] || fail "12: worktree HEAD should be rewound to the item's own base $WT_BASE, got $wt_head"
ok "12 worktree-prepare: PREPARED and rewound to the item's own base"

# ---------------------------------------------------------------------------
# 13. Property 1 — NO PUSH REMOTE. Structural: a real `git push` issued from
#     inside the worktree must actually FAIL, not just report a config value.
# ---------------------------------------------------------------------------
count
[ "$(jq -r '.isolation.no_push_remote' <<<"$PREP_OUT")" = "true" ] || fail "13: isolation.no_push_remote should be true: $PREP_OUT"
actual_pushurl="$(git -C "$wt_path" config --worktree --get remote.origin.pushurl)"
[ "$actual_pushurl" = "replay-worktree-push-disabled://no-remote" ] || fail "13: worktree-scoped pushurl wrong: $actual_pushurl"
push_rc=0
push_out="$(git -C "$wt_path" push origin HEAD:refs/heads/replay-probe 2>&1)" || push_rc=$?
[ "$push_rc" -ne 0 ] || fail "13: a push from inside the isolated replay worktree SUCCEEDED — isolation is not structural: $push_out"
# The parent checkout's own origin is untouched — worktree-scoped config
# never leaks to the shared repo-wide config.
parent_pushurl="$(git -C "$WT_FIX" config --get remote.origin.pushurl 2>/dev/null || true)"
[ "$parent_pushurl" != "replay-worktree-push-disabled://no-remote" ] || fail "13: the sentinel leaked into the PARENT checkout's config"
ok "13 property 1 (no push remote): structural — an actual push from the worktree fails, parent checkout unaffected"

# ---------------------------------------------------------------------------
# 14. Property 2 — WRITE-GUARD CLASS. The `.build-guard` marker (the actual
#     per-worktree mechanism that arms the PreToolUse write-jail hook) is
#     present, and replay.sh's own JSON forwards worktree.sh's real create()
#     verdict rather than hardcoding one.
# ---------------------------------------------------------------------------
count
[ -f "$wt_path/.build-guard" ] || fail "14: .build-guard marker missing — the worktree is not armed for the write-jail hook"
guard_marker_slug="$(jq -r .slug <"$wt_path/.build-guard")"
[ "$guard_marker_slug" = "$PREP_SLUG" ] || fail "14: .build-guard marker carries the wrong slug: $guard_marker_slug"
# The write-jail hook's registration is host/settings-scoped (guard_probe
# falls back to the operator's global ~/.claude/settings.json when the
# fixture repo has no project-local one), so the actual verdict (ARMED vs
# UNARMED) varies by host — asserting a specific value here would be
# environment-dependent, not deterministic (kernel principle 3). Instead,
# independently invoke worktree.sh create a SECOND time (a fresh slug, same
# repo/host) and confirm replay.sh's own isolation.guard field EQUALS that
# real, independently-observed verdict — proving it is FORWARDED, not
# hardcoded, whatever the value happens to be on this host.
INDEP_SLUG="replay-indep-guard-probe"
indep_create_out="$(bash "$MC_DIR/../build/worktree.sh" create "$WT_FIX" "$INDEP_SLUG" 2>/dev/null)"
indep_guard="$(jq -r .guard <<<"$indep_create_out" 2>/dev/null)"
bash "$MC_DIR/../build/worktree.sh" remove "$WT_FIX" "$INDEP_SLUG" >/dev/null 2>&1 || true
reported_guard="$(jq -r '.isolation.guard' <<<"$PREP_OUT")"
case "$reported_guard" in ARMED|UNARMED|UNKNOWN) ;; *) fail "14: isolation.guard is not one of the closed outcome values: $reported_guard" ;; esac
[ "$reported_guard" = "$indep_guard" ] || fail "14: isolation.guard ($reported_guard) does not match an independently-observed real create() verdict ($indep_guard) for the same repo/host — not being forwarded correctly"
ok "14 property 2 (write-guard class): .build-guard marker present, and replay.sh forwards worktree.sh's REAL guard verdict ($reported_guard on this host), not a hardcoded one"

# --- mutation proof: worktree.sh drops the .build-guard marker ------------
count
WORKTREE_SH_REAL="$MC_DIR/../build/worktree.sh"
cp "$WORKTREE_SH_REAL" "$WORK/worktree.sh.orig"
mutate_file "$WORKTREE_SH_REAL" \
  '> "$wt_path/.build-guard"' \
  '> "$wt_path/.build-guard.DISABLED-BY-MUTATION"' \
  || fail "14m: mutation apply failed"
MUT_SLUG="replay-mut-slug-14"
mut_prep_out="$(bash "$SUT" worktree-prepare "$WT_FIX" "$MUT_SLUG" "$WT_BASE" 2>&1)"
mut_wt_path="${WT_FIX}.wt/${MUT_SLUG}"
marker_present=1
[ -f "$mut_wt_path/.build-guard" ] || marker_present=0
bash "$SUT" worktree-teardown "$WT_FIX" "$MUT_SLUG" >/dev/null 2>&1 || true
cp "$WORK/worktree.sh.orig" "$MC_DIR/../build/worktree.sh"
[ "$marker_present" -eq 0 ] || fail "14m: expected the mutated worktree.sh to omit .build-guard, but it was present: $mut_prep_out"
ok "14m MUTATION PROOF: removing worktree.sh's .build-guard write leaves the worktree unarmed — restored, test 14 above is green again"

# ---------------------------------------------------------------------------
# 15. Property 3 — PER-REPO-DERIVED SCRATCH PATH. Deterministic
#     `<repo-root>.wt/<slug>`, reported honestly (not a literal reused from
#     elsewhere).
# ---------------------------------------------------------------------------
count
[ "$wt_path" = "$WT_PATH_EXPECTED" ] || fail "15: worktree path should be $WT_PATH_EXPECTED, got $wt_path"
[ "$(jq -r '.isolation.scratch_root' <<<"$PREP_OUT")" = "${WT_FIX}.wt" ] || fail "15: scratch_root wrong: $PREP_OUT"
ok "15 property 3: deterministic per-repo-derived scratch path (<repo-root>.wt/<slug>)"

# --- mutation proof: the JSON lies about the path --------------------------
count
cp "$SUT" "$WORK/replay.sh.orig-15"
mutate_file "$SUT" \
  '--arg path "$wt_path" --arg branch "$branch" --arg base "$base_sha" \' \
  '--arg path "/tmp/WRONG-PATH-MUTATION" --arg branch "$branch" --arg base "$base_sha" \' \
  || fail "15m: mutation apply failed"
MUT_SLUG2="replay-mut-slug-15"
mut_prep_out2="$(bash "$SUT" worktree-prepare "$WT_FIX" "$MUT_SLUG2" "$WT_BASE")"
bash "$SUT" worktree-teardown "$WT_FIX" "$MUT_SLUG2" >/dev/null 2>&1 || true
cp "$WORK/replay.sh.orig-15" "$SUT"
mut_reported_path="$(jq -r .path <<<"$mut_prep_out2")"
[ "$mut_reported_path" = "/tmp/WRONG-PATH-MUTATION" ] || fail "15m: mutation should have made .path report the wrong literal, got $mut_reported_path"
[ "$mut_reported_path" != "${WT_FIX}.wt/${MUT_SLUG2}" ] || fail "15m: mutation had no effect"
ok "15m MUTATION PROOF: a JSON that lies about .path is caught by the exact-path assertion — restored, test 15 above is green again"

# ---------------------------------------------------------------------------
# 16. worktree-teardown removes the worktree AND the branch cleanly.
# ---------------------------------------------------------------------------
count
teardown_out="$(bash "$SUT" worktree-teardown "$WT_FIX" "$PREP_SLUG")"
[ "$(jq -r .outcome <<<"$teardown_out")" = "REMOVED" ] || fail "16: expected REMOVED, got: $teardown_out"
[ ! -e "$wt_path" ] || fail "16: worktree path still exists after teardown: $wt_path"
git -C "$WT_FIX" show-ref --verify --quiet "refs/heads/build/${PREP_SLUG}" \
  && fail "16: branch build/${PREP_SLUG} still exists after teardown"
ok "16 worktree-teardown removes both the worktree directory and its branch"

# ---------------------------------------------------------------------------
# 17. FAILURE-PATH CLEANUP. A mid-run failure (an unreachable base sha, AFTER
#     `worktree.sh create` already succeeded) must tear the worktree back
#     down before returning — never leave residue.
# ---------------------------------------------------------------------------
count
FAIL_SLUG="replay-fail-slug"
FAIL_WT_PATH="${WT_FIX}.wt/${FAIL_SLUG}"
fail_rc=0
fail_out="$(bash "$SUT" worktree-prepare "$WT_FIX" "$FAIL_SLUG" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>/dev/null)" || fail_rc=$?
[ "$fail_rc" -ne 0 ] || fail "17: worktree-prepare should fail on an unreachable base sha"
[ "$(jq -r .outcome <<<"$fail_out" 2>/dev/null)" = "ERROR" ] || fail "17: expected ERROR outcome, got: $fail_out"
[ ! -e "$FAIL_WT_PATH" ] || fail "17: RESIDUE — worktree directory still exists after a mid-run failure: $FAIL_WT_PATH"
case "$(git -C "$WT_FIX" worktree list)" in
  *"$FAIL_SLUG"*) fail "17: RESIDUE — git still has the failed worktree registered" ;;
esac
git -C "$WT_FIX" show-ref --verify --quiet "refs/heads/build/${FAIL_SLUG}" \
  && fail "17: RESIDUE — branch build/${FAIL_SLUG} still exists after a mid-run failure"
ok "17 worktree-prepare tears down cleanly on the FAILURE path (unreachable base) — no directory, no worktree registration, no branch residue"

# --- mutation proof: skip the failure-path teardown ------------------------
count
cp "$SUT" "$WORK/replay.sh.orig-17"
mutate_file "$SUT" \
  '  if [ "$failed" -eq 1 ]; then
    bash "$WORKTREE_SH" remove "$repo_root" "$slug" >/dev/null 2>&1 || true
    jq -cn --arg e "$fail_reason"' \
  '  if [ "$failed" -eq 1 ]; then
    jq -cn --arg e "$fail_reason"' \
  || fail "17m: mutation apply failed"
FAIL_SLUG_M="replay-fail-slug-mut"
FAIL_WT_PATH_M="${WT_FIX}.wt/${FAIL_SLUG_M}"
mut_fail_rc=0
bash "$SUT" worktree-prepare "$WT_FIX" "$FAIL_SLUG_M" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1 || mut_fail_rc=$?
residue_present=0
[ -e "$FAIL_WT_PATH_M" ] && residue_present=1
cp "$WORK/replay.sh.orig-17" "$SUT"
# manual cleanup of the residue the mutation deliberately left behind
git -C "$WT_FIX" worktree remove --force "$FAIL_WT_PATH_M" >/dev/null 2>&1 || rm -rf "$FAIL_WT_PATH_M"
git -C "$WT_FIX" worktree prune >/dev/null 2>&1 || true
git -C "$WT_FIX" branch -D "build/${FAIL_SLUG_M}" >/dev/null 2>&1 || true
[ "$mut_fail_rc" -ne 0 ] || fail "17m: fixture sanity: mutated script should still exit non-zero"
[ "$residue_present" -eq 1 ] || fail "17m: expected the mutation to LEAVE residue (that's the point of this proof) but none was found"
ok "17m MUTATION PROOF: removing the failure-path teardown call leaves worktree residue behind — restored and manually cleaned, test 17 above is green again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — verify-clean-parent (BACKSTOP, not the primary control)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 18. verify-clean-parent: CLEAN on a pristine repo, DIRTY (with detail, non-
#     zero) on an uncommitted change — and it is DOCUMENTED as a backstop,
#     never the primary control (the primary controls are properties 1-3,
#     each independently and directly asserted in tests 13-15 above).
# ---------------------------------------------------------------------------
count
clean_out="$(bash "$SUT" verify-clean-parent "$WT_FIX")"
clean_rc=$?
[ "$clean_rc" -eq 0 ] || fail "18: verify-clean-parent should exit 0 on a pristine repo"
[ "$(jq -r .outcome <<<"$clean_out")" = "CLEAN" ] || fail "18: expected CLEAN, got: $clean_out"

printf 'dirty\n' >"$WT_FIX/dirty-file.txt"
dirty_rc=0
dirty_out="$(bash "$SUT" verify-clean-parent "$WT_FIX")" || dirty_rc=$?
rm -f "$WT_FIX/dirty-file.txt"
[ "$dirty_rc" -ne 0 ] || fail "18: verify-clean-parent should exit non-zero on an uncommitted change"
[ "$(jq -r .outcome <<<"$dirty_out")" = "DIRTY" ] || fail "18: expected DIRTY, got: $dirty_out"

grep -q "BACKSTOP, not the primary control" "$SUT" \
  || fail "18: verify-clean-parent is no longer documented as a BACKSTOP (not the primary isolation control) — the three structural properties (tests 13-15) must stay primary"
ok "18 verify-clean-parent: CLEAN/DIRTY behave correctly, and it stays documented as a backstop (the structural properties 1-3 are the primary control, independently asserted)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — schema (versioned scored-record shape)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 19. schema: fixed, versioned shape; and `schema`'s schema_version matches
#     what `corpus` actually stamped on its records (tests 10/10b above) —
#     the same constant, not two independently-hardcoded literals that can
#     drift apart.
# ---------------------------------------------------------------------------
count
schema_out="$(bash "$SUT" schema)"
[ "$(jq -r .schema_version <<<"$schema_out")" = "replay-record-v1" ] || fail "19: unexpected schema_version: $schema_out"
[ "$(jq -c .worktree <<<"$schema_out")" = '{"path":null,"branch":null,"prepared_at":null}' ] || fail "19: worktree shape wrong: $schema_out"
[ "$(jq -c .candidate <<<"$schema_out")" = '{"provider":null,"model":null,"diff_ref":null}' ] || fail "19: candidate shape wrong: $schema_out"
[ "$(jq -c .score <<<"$schema_out")" = '{"verdict":null,"acceptance_results":null,"gate_result":null}' ] || fail "19: score shape wrong: $schema_out"
[ "$(jq -c .buckets <<<"$schema_out")" = '{"N":[],"T":[],"X":[],"R":[]}' ] || fail "19: buckets shape wrong: $schema_out"

corpus_record_sv="$(jq -r .schema_version "$OUT" | head -1)"
schema_sv="$(jq -r .schema_version <<<"$schema_out")"
[ "$corpus_record_sv" = "$schema_sv" ] || fail "19: schema's schema_version ($schema_sv) does not match a corpus record's ($corpus_record_sv)"
ok "19 schema: fixed versioned shape, and schema_version matches what corpus actually stamps (same constant, not two drift-prone literals)"

# --- mutation proof: schema's own schema_version silently drifts ----------
count
cp "$SUT" "$WORK/replay.sh.orig-19"
mutate_file "$SUT" \
  'jq -cn --arg sv "$REPLAY_RECORD_SCHEMA_VERSION" '"'"'{' \
  'jq -cn --arg sv "replay-record-v2-DRIFTED" '"'"'{' \
  || fail "19m: mutation apply failed"
mut_schema_out="$(bash "$SUT" schema)"
mut_sv="$(jq -r .schema_version <<<"$mut_schema_out")"
cp "$WORK/replay.sh.orig-19" "$SUT"
[ "$mut_sv" != "$corpus_record_sv" ] || fail "19m: mutation had no visible effect (schema_version still matched)"
ok "19m MUTATION PROOF: hardcoding a divergent schema_version in cmd_schema is caught by the schema/corpus consistency check — restored, test 19 above is green again"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — hard constraint: no shift-2-no-op infinite loop on a trailing
# flag with no value (fleet-wide #1342). Already guarded by need_operand in
# both corpus's and diff-scope's arg loops — this proves it, BOUNDED so a
# regression shows up as a failed assertion, never a hung suite.
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 20. A trailing operand-taking flag with no value fails fast (bounded by a
#     short timeout — an unbounded assertion for this defect would hang the
#     suite instead of failing it).
# ---------------------------------------------------------------------------
count
rc=0
run_with_timeout 5 bash "$SUT" corpus --repo >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "20: corpus --repo (trailing, no value) should fail, got rc=0"
[ "$rc" -ne 137 ] || fail "20: corpus --repo (trailing, no value) HUNG (timed out) instead of failing fast"

rc=0
run_with_timeout 5 bash "$SUT" diff-scope "$DS_FIX" "$DS_C0" "$DS_C1" --issue-text-file >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "20: diff-scope --issue-text-file (trailing, no value) should fail, got rc=0"
[ "$rc" -ne 137 ] || fail "20: diff-scope --issue-text-file (trailing, no value) HUNG (timed out) instead of failing fast"
ok "20 a trailing operand-taking flag with no value fails fast and bounded, never an infinite shift-2-no-op loop"

echo "---"
echo "$pass/$total tests passed"
[ "$pass" -eq "$total" ] || fail "only $pass of $total tests passed"
