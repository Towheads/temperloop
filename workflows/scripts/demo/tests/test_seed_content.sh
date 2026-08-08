#!/usr/bin/env bash
#
# Tests for the testbed SEED CONTENT (temperloop#1230, epic #1117) — the
# in-tree fixture `materialize-from-seed` materializes into the operator's
# own account. Zero network throughout: everything here reads tracked files
# and runs the seed project's own suite locally.
#
# WHAT THIS GATE IS FOR. The seed is fixture content, and ADR 0025 is honest
# that fixture content rots: "a fixture that teaches something today teaches
# less as the pipeline evolves, and no gate detects that." This suite cannot
# detect *staleness*, but it can and does detect the cheaper failure right
# next to it — a seed that has quietly stopped being COHERENT:
#
#   A. the layout the provider resolves against is present and complete
#   B. every issue definition parses to a title + a non-empty body
#   C. every defect an issue CLAIMS is actually present in the project (a
#      seed whose issues describe bugs the code no longer has is worse than
#      no seed — the reader's first epic is unfixable)
#   D. the seed ships GREEN: its own suite passes as committed, so a reader's
#      first `/build` starts from a passing baseline rather than someone
#      else's red
#   E. ADR 0025's structural rule: no repository owned by this project is
#      named anywhere in the seed
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO="$(cd "$HERE/.." && pwd)"
SEED="$DEMO/seed"
PROJECT="$SEED/project"
ISSUES="$SEED/issues"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── A. layout ──────────────────────────────────────────────────────────────
[ -d "$SEED" ] || fail "A1: seed directory missing at $SEED"
[ -f "$SEED/seed.json" ] || fail "A1: seed.json missing at $SEED/seed.json"
[ -d "$PROJECT" ] || fail "A1: seed project tree missing at $PROJECT"
[ -d "$ISSUES" ] || fail "A1: seed issue definitions missing at $ISSUES"
echo "PASS: A1 the seed layout the provider resolves against is present"

if command -v jq >/dev/null 2>&1; then
  jq -e . "$SEED/seed.json" >/dev/null 2>&1 || fail "A2: seed.json is not valid JSON"
  name="$(jq -r '.name // empty' "$SEED/seed.json")"
  [ -n "$name" ] || fail "A2: seed.json has no non-empty .name (describe()'s base_name)"
  branch="$(jq -r '.default_branch // empty' "$SEED/seed.json")"
  [ -n "$branch" ] || fail "A2: seed.json has no non-empty .default_branch"
  echo "PASS: A2 seed.json parses and carries the fields describe()/produce_git read (name=$name, default_branch=$branch)"
else
  echo "skipped — jq not found on PATH (A2 seed.json field checks)"
fi

n_project="$(find "$PROJECT" -type f | wc -l | tr -d ' ')"
[ "$n_project" -ge 3 ] || fail "A3: seed project has only $n_project file(s) — too thin to run a real first epic against"
echo "PASS: A3 the seed project ships $n_project tracked files"

# ── B. issue-definition grammar ────────────────────────────────────────────
# The provider parses `# <title>` from line 1 and takes the rest as the body.
# A file that does not match that shape becomes an issue with an empty title
# or an empty body on the reader's brand-new repository.
n_issues=0
for f in "$ISSUES"/*.md; do
  [ -f "$f" ] || continue
  n_issues=$((n_issues + 1))
  base="$(basename "$f")"
  first="$(head -n 1 "$f")"
  case "$first" in
    '# '*) ;;
    *) fail "B1: $base line 1 must be '# <title>' (got: $first)" ;;
  esac
  title="$(printf '%s' "$first" | sed -E 's/^#[[:space:]]*//')"
  [ -n "$title" ] || fail "B1: $base has an empty title"
  body="$(tail -n +2 "$f" | sed -E '1{/^[[:space:]]*$/d;}')"
  [ -n "$body" ] || fail "B1: $base has an empty body"
  case "$body" in
    *'Acceptance (falsifiable)'*) ;;
    *) fail "B2: $base has no 'Acceptance (falsifiable)' section — a seed issue must be checkable, not a vibe" ;;
  esac
done
[ "$n_issues" -ge 4 ] || fail "B3: only $n_issues seed issue(s) — sized for a single tick, not for a first epic"
echo "PASS: B1-B3 all $n_issues issue definitions parse to a title + a falsifiable body"

# ── C. every claimed defect is really there ────────────────────────────────
# Each assertion below is the ONE line of the project that makes the matching
# issue true. If a well-meaning edit "tidies" one away, the issue it backs
# becomes unfixable and this fails loudly instead of the reader discovering
# it mid-`/build`.
grep -q 'return True' "$PROJECT/linkrot.py" \
  || fail "C1: is_local() no longer returns unconditionally — the anchor/external-URL issues have nothing to fix"
grep -q 'os.path.exists(target)' "$PROJECT/linkrot.py" \
  || fail "C2: check_file() no longer resolves the raw target — the working-directory issue has nothing to fix"
grep -q 'LINK_RE = re.compile' "$PROJECT/linkrot.py" \
  || fail "C3: the inline-only link pattern is gone — the reference-style-links issue has nothing to fix"
grep -q '^\[commonmark\]: ' "$PROJECT/docs/getting-started.md" \
  || fail "C3: the reference-style link the issue points at is gone from docs/getting-started.md"
grep -q 'return 0' "$PROJECT/linkrot.py" \
  || fail "C4: main() no longer returns 0 unconditionally — the exit-code issue has nothing to fix"
grep -q -- '--json' "$PROJECT/README.md" \
  || fail "C5: README no longer advertises --json — the documented-but-missing-flag issue has nothing to fix"
if grep -q -- '--json' "$PROJECT/linkrot.py"; then
  fail "C5: linkrot.py now implements --json — the documented-but-missing-flag issue is already fixed"
fi
grep -q 'CONTRIBUTE.md' "$PROJECT/docs/getting-started.md" \
  || fail "C6: the one genuinely broken link the walkthrough advertises is gone"
echo "PASS: C1-C6 every defect the seed issues claim is present in the seed project"

# ── D. the seed ships green ────────────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
  out=""
  if ! out="$(cd "$PROJECT" && python3 -m unittest discover -s . -p 'test_*.py' 2>&1)"; then
    printf '%s\n' "$out" >&2
    fail "D1: the seed project's own test suite is RED as committed — a reader's first /build would start from someone else's failure"
  fi
  echo "PASS: D1 the seed project's suite passes as committed ($(printf '%s' "$out" | sed -n 's/^Ran \([0-9]*\) test.*/\1/p') tests)"
else
  echo "skipped — python3 not found on PATH (D1 seed suite run)"
fi

# ── E. ADR 0025: no project-owned repository anywhere in the seed ──────────
# The retired generator seeded a repository this project owned. The seed
# replaces it precisely so that no such artifact exists; a project-owned
# slug reappearing in the seed content would reintroduce the leak ADR 0025
# closes, from inside the fixture.
if grep -rniE 'temperloop-demo|SEED_DEMO_REPO' "$SEED" >/dev/null 2>&1; then
  grep -rniE 'temperloop-demo|SEED_DEMO_REPO' "$SEED" >&2
  fail "E1: the seed names a project-owned demo repository — ADR 0025 forbids this project owning any evaluation artifact"
fi
echo "PASS: E1 the seed names no project-owned repository (ADR 0025)"

echo "ALL PASS: seed content"
