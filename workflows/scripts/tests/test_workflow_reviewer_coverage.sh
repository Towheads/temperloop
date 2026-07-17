#!/usr/bin/env bash
#
# test_workflow_reviewer_coverage.sh — hermetic tests for the #1007 coverage rollup.
# Stubs `gh` via WFR_COVERAGE_GH_BIN: `pr list` returns a fixed merged-PR set, `pr view <n>
# --json files` returns that PR's touched paths. Zero network.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../workflow-reviewer-coverage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# --- gh double ----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# pr list ... --json number,body   -> the merged-PR fixture array
# pr view <n> ... --json files ...  -> that PR's touched paths (one per line)
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  cat "$GH_FIXTURE_DIR/pr-list.json"; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n="$3"; cat "$GH_FIXTURE_DIR/files-$n.txt" 2>/dev/null || true; exit 0
fi
exit 0
FAKEGH
chmod +x "$TMP/bin/gh"

# --- fixture: 3 merged PRs ----------------------------------------------------
# #1 touches a command doc AND documents a workflow-reviewer pass  -> covered
# #2 touches a command doc but has NO reviewer mention            -> uncovered
# #3 touches only a non-command file                              -> not counted
mkdir -p "$TMP/fix"
cat > "$TMP/fix/pr-list.json" <<'JSON'
[
  {"number":1,"body":"Refactor build.md 3e.\n\nworkflow-reviewer pass: 2 BLOCKING fixed pre-merge."},
  {"number":2,"body":"Tweak tidy.md wording. No review recorded."},
  {"number":3,"body":"Bump a dependency in package.json."}
]
JSON
printf 'claude/commands/build.md\n'  > "$TMP/fix/files-1.txt"
printf 'claude/commands/tidy.md\n'   > "$TMP/fix/files-2.txt"
printf 'package.json\n'              > "$TMP/fix/files-3.txt"

run() { env PATH="$TMP/bin:$PATH" WFR_COVERAGE_GH_BIN="$TMP/bin/gh" GH_FIXTURE_DIR="$TMP/fix" bash "$SCRIPT" "$@"; }

# --- 1. text summary: 1 of 2 command-doc PRs covered = 50% --------------------
out="$(run --days 28)"
echo "$out" | grep -q "command-doc PRs: 2" || bad "denominator: expected 2 command-doc PRs; got: $out"
echo "$out" | grep -q "workflow-reviewer pass: 1" || bad "numerator: expected 1 covered; got: $out"
echo "$out" | grep -q "coverage: 50%" || bad "rate: expected 50%; got: $out"
echo "$out" | grep -q "uncovered PRs: 2" || bad "uncovered list: expected PR 2; got: $out"
[ "$fails" -eq 0 ] && ok "text summary: 1/2 command-doc PRs documented -> 50% (PR 3 correctly excluded)"

# --- 2. --json shape ----------------------------------------------------------
j="$(run --days 28 --json)"
[ "$(printf '%s' "$j" | jq -r '.command_doc_prs')" = "2" ]      || bad "json.command_doc_prs != 2 ($j)"
[ "$(printf '%s' "$j" | jq -r '.with_workflow_reviewer')" = "1" ] || bad "json.with_workflow_reviewer != 1 ($j)"
[ "$(printf '%s' "$j" | jq -r '.coverage_pct')" = "50" ]       || bad "json.coverage_pct != 50 ($j)"
ok "--json emits {command_doc_prs, with_workflow_reviewer, coverage_pct}"

# --- 3. empty PR set -> zero-row report, exit 0 (fail-open) --------------------
printf '[]\n' > "$TMP/fix/pr-list.json"
rc=0; out0="$(run --days 28)" || rc=$?
[ "$rc" -eq 0 ] || bad "empty set: expected exit 0, got $rc"
echo "$out0" | grep -q "command-doc PRs: 0" || bad "empty set: expected 0 PRs; got: $out0"
echo "$out0" | grep -q "coverage: 0%"       || bad "empty set: expected 0% (no divide-by-zero); got: $out0"
ok "empty PR set -> zero-row report, exit 0, no divide-by-zero"

if [ "$fails" -eq 0 ]; then
  echo "workflow-reviewer-coverage tests: ALL PASS"
else
  echo "workflow-reviewer-coverage tests: $fails FAILED"; exit 1
fi
