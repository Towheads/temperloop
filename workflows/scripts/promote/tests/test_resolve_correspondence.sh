#!/usr/bin/env bash
#
# Tests for workflows/scripts/promote/resolve-correspondence.sh — the
# mechanical half of `/promote`'s issue correspondence (temperloop#1235,
# epic #1117 Produces 5 continued).
#
# THIS SUITE IS THE POINT OF THE SPLIT (same rationale as
# test_push_testbed_branch.sh's own header): a test can assert what this
# script resolves; no test can assert against a prose lookup step in a
# markdown spec. Zero network throughout — the classification core takes a
# body directly (`--body-file`, no gh at all), and every `gh` touch point is
# a fake `gh` on PATH answering from fixture JSON or from argv it captured.
#
#   Part A  the four classification outcomes, driven via --body-file:
#           resolved (present-and-valid), absent, malformed, edited (two
#           distinct edited shapes: appended-after and missing-separator)
#   Part B  argument refusals (the testbed repo and issue are never inferred)
#   Part C  `resolve` wired to a fake `gh issue view` (resolved + a refusal)
#   Part D  `report` wired to a fake `gh issue list`: one row per issue,
#           mixed outcomes, and the aggregate exit code
#   Part E  EXACT-FORMAT INTEROP: sources the REAL
#           workflows/scripts/testbed/source.sh writer, drives its actual
#           `produce_issues` against a fake `gh issue create` that captures
#           the real --body argument, and feeds THAT captured body straight
#           into this script — proving the parser matches the writer's
#           actual output, not a second invented format.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/resolve-correspondence.sh"
SOURCE_LIB="$(cd "$HERE/../../testbed" && pwd)/source.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/resolve-correspondence-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

OUT=""; RC=0
run() {  # run <script args...>
  set +e
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

# <name> <content> -> writes $TMP/<name>, echoes its path.
body_file() {
  local f="$TMP/$1"
  printf '%s' "$2" > "$f"
  printf '%s' "$f"
}

# =============================================================================
# Part A -- the four classification outcomes, via --body-file (no gh at all).
# =============================================================================

# A1: present-and-valid -- exactly the shape the writer produces.
good="$(printf '%s\n\n---\n%s\n' 'Some issue text.' 'copied from acme/proj#42')"
f="$(body_file a1 "$good")"
run resolve --testbed-repo acme/proj-testbed --issue 42 --body-file "$f"
[ "$RC" -eq 0 ] || fail "A1: a present-and-valid provenance line should resolve (got rc=$RC: $OUT)"
case "$OUT" in
  "RESOLVED"*"acme/proj-testbed#42"*"acme/proj#42") ;;
  *) fail "A1: expected a RESOLVED row naming acme/proj#42 (got: $OUT)" ;;
esac
echo "PASS: A1 resolves a present-and-valid provenance line by exact lookup, exit 0"

# A2: absent -- no provenance line anywhere.
f="$(body_file a2 "$(printf '%s\n' 'Just a body.' 'No stamp here.')")"
run resolve --testbed-repo acme/proj-testbed --issue 43 --body-file "$f"
[ "$RC" -eq 2 ] || fail "A2: an absent provenance line should exit 2 (got rc=$RC: $OUT)"
case "$OUT" in "ABSENT"*) ;; *) fail "A2: expected an ABSENT row (got: $OUT)" ;; esac
echo "PASS: A2 refuses (exit 2, ABSENT) when no provenance line exists — never guesses"

# A3: malformed -- a "copied from " line exists but does not parse.
f="$(body_file a3 "$(printf '%s\n\n---\n%s\n' 'body' 'copied from acme#42')")"
run resolve --testbed-repo acme/proj-testbed --issue 44 --body-file "$f"
[ "$RC" -eq 3 ] || fail "A3a: a malformed line (no repo) should exit 3 (got rc=$RC: $OUT)"
case "$OUT" in "MALFORMED"*) ;; *) fail "A3a: expected a MALFORMED row (got: $OUT)" ;; esac
echo "PASS: A3a refuses (exit 3, MALFORMED) a 'copied from' line missing the repo segment"

f="$(body_file a3b "$(printf '%s\n\n---\n%s\n' 'body' 'copied from acme/proj#abc')")"
run resolve --testbed-repo acme/proj-testbed --issue 44 --body-file "$f"
[ "$RC" -eq 3 ] || fail "A3b: a non-numeric issue number should exit 3 (got rc=$RC: $OUT)"
case "$OUT" in "MALFORMED"*) ;; *) fail "A3b: expected a MALFORMED row (got: $OUT)" ;; esac
echo "PASS: A3b refuses (exit 3, MALFORMED) a 'copied from' line with a non-numeric issue number"

# A4: edited -- a well-formed line exists but the body was touched after the
# stamp, in each of the two distinct ways that can happen.
f="$(body_file a4a "$(printf '%s\n\n---\n%s\n%s\n' 'body' 'copied from acme/proj#42' 'someone appended this afterward')")"
run resolve --testbed-repo acme/proj-testbed --issue 45 --body-file "$f"
[ "$RC" -eq 4 ] || fail "A4a: content appended after the stamp should exit 4 (got rc=$RC: $OUT)"
case "$OUT" in "EDITED"*) ;; *) fail "A4a: expected an EDITED row (got: $OUT)" ;; esac
echo "PASS: A4a refuses (exit 4, EDITED) when the stamp is no longer the body's last line"

f="$(body_file a4b "$(printf '%s\n%s\n' 'body' 'copied from acme/proj#42')")"
run resolve --testbed-repo acme/proj-testbed --issue 46 --body-file "$f"
[ "$RC" -eq 4 ] || fail "A4b: a missing '---' separator should exit 4 (got rc=$RC: $OUT)"
case "$OUT" in "EDITED"*) ;; *) fail "A4b: expected an EDITED row (got: $OUT)" ;; esac
echo "PASS: A4b refuses (exit 4, EDITED) when the '---' separator immediately before the stamp is gone"

# =============================================================================
# Part B -- argument refusals. Neither the testbed repo nor the issue is
# ever inferred.
# =============================================================================
run resolve --issue 1 --body-file "$(body_file b1 "$good")"
[ "$RC" -ne 0 ] || fail "B1: resolve with no --testbed-repo should refuse"
case "$OUT" in *"--testbed-repo"*) ;; *) fail "B1: refusal should name --testbed-repo (got: $OUT)" ;; esac
echo "PASS: B1 refuses resolve with no --testbed-repo"

run resolve --testbed-repo not-a-slug --issue 1 --body-file "$(body_file b2 "$good")"
[ "$RC" -ne 0 ] || fail "B2: a malformed --testbed-repo should refuse"
echo "PASS: B2 refuses a --testbed-repo that is not owner/name"

run resolve --testbed-repo acme/proj-testbed --body-file "$(body_file b3 "$good")"
[ "$RC" -ne 0 ] || fail "B3: resolve with no --issue should refuse"
case "$OUT" in *"--issue"*) ;; *) fail "B3: refusal should name --issue (got: $OUT)" ;; esac
echo "PASS: B3 refuses resolve with no --issue"

run resolve --testbed-repo acme/proj-testbed --issue not-a-number --body-file "$(body_file b4 "$good")"
[ "$RC" -ne 0 ] || fail "B4: a non-numeric --issue should refuse"
echo "PASS: B4 refuses a non-numeric --issue"

run report --testbed-repo not-a-slug
[ "$RC" -ne 0 ] || fail "B5: report with a malformed --testbed-repo should refuse"
echo "PASS: B5 refuses report with a malformed --testbed-repo"

run report --testbed-repo acme/proj-testbed --state bogus
[ "$RC" -ne 0 ] || fail "B6: report with an invalid --state should refuse"
echo "PASS: B6 refuses report with a --state outside open|closed|all"

# =============================================================================
# Part C -- `resolve` wired to a fake `gh issue view`.
# =============================================================================
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_ARGV_LOG:-}" ]; then
  { printf -- '--CALL--\n'; printf '%s\n' "$@"; } >> "$GH_ARGV_LOG"
fi
case "$1 $2" in
  "issue view")
    printf '%s' "${FAKE_ISSUE_BODY:-}"
    exit "${FAKE_ISSUE_VIEW_RC:-0}"
    ;;
  "issue list")
    printf '%s' "${FAKE_ISSUE_LIST_JSON:-[]}"
    exit "${FAKE_ISSUE_LIST_RC:-0}"
    ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

ARGV="$TMP/gh-argv.log"
: > "$ARGV"
RC=0
OUT="$(PATH="$BIN:$PATH" GH_ARGV_LOG="$ARGV" FAKE_ISSUE_BODY="$good" \
  bash "$SCRIPT" resolve --testbed-repo acme/proj-testbed --issue 42 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || fail "C1: resolve via gh should succeed (got rc=$RC: $OUT)"
case "$OUT" in "RESOLVED"*"acme/proj#42") ;; *) fail "C1: expected a RESOLVED row (got: $OUT)" ;; esac
grep -Fxq -- '42' "$ARGV" || fail "C1: gh issue view was not called with the right issue number"
grep -Fxq -- 'acme/proj-testbed' "$ARGV" || fail "C1: gh issue view was not called with the right --repo"
echo "PASS: C1 resolve calls gh issue view and resolves from its body"

RC=0
OUT="$(PATH="$BIN:$PATH" FAKE_ISSUE_BODY='no stamp at all' \
  bash "$SCRIPT" resolve --testbed-repo acme/proj-testbed --issue 43 2>&1)" || RC=$?
[ "$RC" -eq 2 ] || fail "C2: an absent stamp via gh should exit 2 (got rc=$RC: $OUT)"
case "$OUT" in "ABSENT"*) ;; *) fail "C2: expected an ABSENT row (got: $OUT)" ;; esac
echo "PASS: C2 resolve via gh refuses (ABSENT) exactly like the --body-file path"

RC=0
OUT="$(PATH="$BIN:$PATH" FAKE_ISSUE_VIEW_RC=1 \
  bash "$SCRIPT" resolve --testbed-repo acme/proj-testbed --issue 44 2>&1)" || RC=$?
[ "$RC" -eq 1 ] || fail "C3: a failing gh issue view should exit 1, not a classification code (got rc=$RC: $OUT)"
echo "PASS: C3 a gh issue view failure is a usage/gh error (exit 1), distinct from a classification refusal"

# =============================================================================
# Part D -- `report` wired to a fake `gh issue list`: one row per issue,
# mixed outcomes, and the aggregate exit code.
# =============================================================================
list_json=$(cat <<JSON
[
  {"number": 101, "body": "text\n\n---\ncopied from acme/proj#1\n"},
  {"number": 102, "body": "no stamp here"},
  {"number": 103, "body": "body\n\n---\ncopied from acme#7\n"},
  {"number": 104, "body": "body\n\n---\ncopied from acme/proj#8\nappended after\n"}
]
JSON
)

RC=0
OUT="$(PATH="$BIN:$PATH" FAKE_ISSUE_LIST_JSON="$list_json" \
  bash "$SCRIPT" report --testbed-repo acme/proj-testbed --state all 2>&1)" || RC=$?
[ "$RC" -eq 1 ] || fail "D1: report with 3 unresolved of 4 should exit 1 (got rc=$RC)"
echo "$OUT" | grep -Fxq $'RESOLVED\tacme/proj-testbed#101\tacme/proj#1' \
  || fail "D1: expected a RESOLVED row for #101 (out: $OUT)"
echo "$OUT" | grep -q $'^ABSENT\tacme/proj-testbed#102\t' \
  || fail "D1: expected an ABSENT row for #102 (out: $OUT)"
echo "$OUT" | grep -q $'^MALFORMED\tacme/proj-testbed#103\t' \
  || fail "D1: expected a MALFORMED row for #103 (out: $OUT)"
echo "$OUT" | grep -q $'^EDITED\tacme/proj-testbed#104\t' \
  || fail "D1: expected an EDITED row for #104 (out: $OUT)"
echo "PASS: D1 report emits one distinct row per issue, mixing all four outcomes, and exits 1 when any is unresolved"

RC=0
OUT="$(PATH="$BIN:$PATH" FAKE_ISSUE_LIST_JSON='[{"number":1,"body":"t\n\n---\ncopied from acme/proj#9\n"}]' \
  bash "$SCRIPT" report --testbed-repo acme/proj-testbed 2>&1)" || RC=$?
[ "$RC" -eq 0 ] || fail "D2: report with everything resolved should exit 0 (got rc=$RC: $OUT)"
echo "PASS: D2 report exits 0 when every issue in scope resolved"

# =============================================================================
# Part E -- EXACT-FORMAT INTEROP with the REAL writer
# (workflows/scripts/testbed/source.sh's own produce_issues). Proves this
# script's parser matches what mirror-from-repo ACTUALLY writes, not a
# second invented format.
# =============================================================================
(
  # shellcheck source=/dev/null
  source "$SOURCE_LIB"

  SRC="$TMP/e-src"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" checkout -q -b main
  echo hello > "$SRC/f.txt"
  git -C "$SRC" add f.txt
  git -C "$SRC" -c user.name=t -c user.email=t@example.com commit -qm init >/dev/null
  git -C "$SRC" remote add origin git@github.com:acme/widgets.git

  EBIN="$TMP/e-bin"
  mkdir -p "$EBIN"
  BODY_CAPTURE="$TMP/e-captured-body"
  cat > "$EBIN/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
  "issue list")
    printf '%s' '[{"number":501,"title":"Real bug","body":"The real original body."}]'
    exit 0
    ;;
  "issue create")
    shift 2
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --body) printf '%s' "\$2" > "$BODY_CAPTURE"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'https://github.com/acme/widgets-testbed/issues/1\n'
    exit 0
    ;;
esac
exit 0
GH
  chmod +x "$EBIN/gh"

  out="$(PATH="$EBIN:$PATH" _testbed_provider_mirror_from_repo_produce_issues acme/widgets-testbed "$SRC" 2>&1)" \
    || fail "E1: the real produce_issues should succeed against the fake gh (out: $out)"
  [ -f "$BODY_CAPTURE" ] || fail "E1: produce_issues never called gh issue create with --body"

  RC=0
  OUT="$(bash "$SCRIPT" resolve --testbed-repo acme/widgets-testbed --issue 1 --body-file "$BODY_CAPTURE" 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] || fail "E2: resolving the REAL writer's own output should succeed (got rc=$RC: $OUT)"
  case "$OUT" in "RESOLVED"*"acme/widgets#501") ;; *) fail "E2: expected RESOLVED naming acme/widgets#501 (got: $OUT)" ;; esac
  echo "PASS: E2 resolve-correspondence.sh parses the REAL mirror-from-repo produce_issues output byte-for-byte, resolving to acme/widgets#501"
)

echo
