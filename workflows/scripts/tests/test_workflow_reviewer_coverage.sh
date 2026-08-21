#!/usr/bin/env bash
#
# test_workflow_reviewer_coverage.sh — hermetic tests for the #1007 coverage
# rollup, rewritten for temperloop#1450 (measure EXECUTION, not prose).
#
# The stubbed `gh` runs in two modes so BOTH data paths of the script are
# covered with the same fixtures and must agree:
#   GH_MODE=oneshot  `pr list --json number,body,files` succeeds (the modern path)
#   GH_MODE=legacy   that call FAILS ("Unknown JSON field: files", an older gh);
#                    the script must fall back to `pr list --json number,body`
#                    plus one `pr view --json files` per PR.
# Zero network either way.
#
# THE DEFECT UNDER TEST (temperloop#1450). The old rollup classified a PR as
# covered when its body matched `workflow-reviewer|BLOCKING|MAJOR`. The fixtures
# below are built so that regex gets 3 of the 7 command-doc PRs WRONG — in both
# directions — and the discrimination block at the end proves the new
# classification is what drives every count, not something incidental.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../workflow-reviewer-coverage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
mark=0
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# `ok` reports the block that just ran, and stays SILENT if that block recorded
# a failure — an unconditional "ok" beside its own FAIL lines is exactly the
# false-green shape this whole item is about. `at` opens a block.
at()   { mark="$fails"; }
ok()   { if [ "$fails" -eq "$mark" ]; then printf '  ok    %s\n' "$1"; fi; mark="$fails"; }

# --- gh double ----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# pr list --json number,body,files -> the full fixture (oneshot mode only)
# pr list --json number,body       -> the fixture with `files` stripped
# pr view <n> --json files         -> that PR's touched paths, one per line
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  if printf '%s\n' "$@" | grep -F 'number,body,files' >/dev/null; then
    if [ "${GH_MODE:-oneshot}" = "legacy" ]; then
      echo 'unknown JSON field: "files"' >&2; exit 1
    fi
    jq -c '.' "$GH_FIXTURE_DIR/pr-list.json"; exit 0
  fi
  jq -c 'map(del(.files))' "$GH_FIXTURE_DIR/pr-list.json"; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  n="$3"; jq -r --argjson n "$n" '.[] | select(.number==$n) | .files[].path' "$GH_FIXTURE_DIR/pr-list.json"; exit 0
fi
exit 0
FAKEGH
chmod +x "$TMP/bin/gh"

# --- fixtures -----------------------------------------------------------------
# The `§3e review — ran:` tally line and the `## Review notes` / `### <reviewer>`
# blocks are the shapes claude/workflows/build-level.mjs EMITS into the PR body
# (temperloop#1430). Everything else below is human prose.
#
#  # | touches cmd doc | body carries                                  | old regex | correct
# ---|-----------------|-----------------------------------------------|-----------|--------
#  1 | yes             | "MAJOR"/"BLOCKING" prose only, no marker      | covered   | NOT covered
#  2 | yes             | emitted tally naming workflow-reviewer        | covered   | covered
#  3 | yes             | emitted `skipped — workflow-reviewer …` notice| covered   | NOT covered (skip)
#  4 | yes             | nothing                                       | uncovered | NOT covered
#  5 | NO              | emitted tally                                 | n/a       | excluded
#  6 | yes             | prose NARRATIVE about the §3e review          | covered   | NOT covered
#  7 | yes             | `## Review notes` + `### workflow-reviewer`   | covered   | covered
#  8 | yes             | emitted tally naming docs-reviewer ONLY       | uncovered | ran, but NOT workflow-reviewer
mkdir -p "$TMP/fix"
write_fixture() {
  jq -n '
  def pr($n; $body; $paths): {number:$n, body:$body, files:[$paths[] | {path:.}]};
  [
    pr(1;
       "Refactor build.md 3e.\n\n## Changelog\n- MAJOR: the merge gate now batches.\n- Quoted from an old retro: \"BLOCKING findings loop back to 3c\".\n";
       ["claude/commands/build.md"]),
    pr(2;
       "Tighten the tidy.md drain wording.\n\n§3e review — ran: docs-reviewer, workflow-reviewer\n\n## Verification\n- [x] tests pass\n";
       ["claude/commands/tidy.md"]),
    pr(3;
       "Adjust sweep.md fanout.\n\nskipped — workflow-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable\n";
       ["claude/commands/sweep.md"]),
    pr(4;
       "Fix a typo in assess.md.\n";
       ["claude/commands/assess.md"]),
    pr(5;
       "Bump a dependency.\n\n§3e review — ran: shell-reviewer\n";
       ["package.json"]),
    pr(6;
       "## BLUF\n\nSomething was broken.\n\n## The §3e review caught a destructive default, twice over\n\nBoth shell-reviewer and workflow-reviewer independently flagged the same HIGH.\n";
       ["claude/commands/tidy.md"]),
    pr(7;
       "Rework triage.md routing.\n\n## Review notes\n\n### workflow-reviewer\n\n### [LOW] wording in claude/commands/triage.md\nConsider naming the axis.\n";
       ["claude/commands/triage.md"]),
    pr(8;
       "Docs pass over fix.md.\n\n§3e review — ran: docs-reviewer\n";
       ["claude/commands/fix.md"])
  ]' > "$TMP/fix/pr-list.json"
}
write_fixture

run() { env PATH="$TMP/bin:$PATH" WFR_COVERAGE_GH_BIN="$TMP/bin/gh" GH_FIXTURE_DIR="$TMP/fix" \
            GH_MODE="${GH_MODE:-oneshot}" bash "$SCRIPT" "$@"; }
jqf() { printf '%s' "$1" | jq -r "$2"; }

at
# --- 1. the core counts, in BOTH gh modes -------------------------------------
# 7 command-doc PRs (PR 5 excluded). workflow-reviewer demonstrably RAN on 2
# (#2 via the tally, #7 via its review-notes block) -> 2*100/7 = 28%.
for mode in oneshot legacy; do
  j="$(GH_MODE="$mode" run --days 28 --json)"
  [ "$(jqf "$j" '.command_doc_prs')"        = "7" ] || bad "[$mode] denominator != 7 ($j)"
  [ "$(jqf "$j" '.with_workflow_reviewer')" = "2" ] || bad "[$mode] numerator != 2 ($j)"
  [ "$(jqf "$j" '.any_reviewer_ran')"       = "3" ] || bad "[$mode] any_reviewer_ran != 3 ($j)"
  [ "$(jqf "$j" '.skip_notice_only')"       = "1" ] || bad "[$mode] skip_notice_only != 1 ($j)"
  [ "$(jqf "$j" '.no_review_record')"       = "3" ] || bad "[$mode] no_review_record != 3 ($j)"
  [ "$(jqf "$j" '.coverage_pct')"           = "28" ] || bad "[$mode] coverage_pct != 28 ($j)"
  # The three run-state buckets partition the denominator — a PR cannot be
  # counted twice, and none may fall through unclassified.
  [ "$(jqf "$j" '.any_reviewer_ran + .skip_notice_only + .no_review_record')" \
    = "$(jqf "$j" '.command_doc_prs')" ] || bad "[$mode] buckets do not partition the denominator ($j)"
done
ok "counts agree across the oneshot and legacy gh data paths; buckets partition the denominator"

at
# --- 2. DIRECTION 1 — 'MAJOR'/'BLOCKING' prose with no reviewer run ------------
# PR 1 is a changelog line and a quoted finding; PR 6 is a prose NARRATIVE about
# a review, naming workflow-reviewer in a heading. The old regex scored BOTH
# covered. Neither carries anything the run emitted, so both must land in the
# no-machine-record bucket and NEITHER may reach the numerator.
out="$(run --days 28)"
rec="$(printf '%s\n' "$out" | sed -n 's/^  no-record PRs: //p')"
for n in 1 6; do
  printf '%s\n' " $rec " | grep -F " $n " >/dev/null \
    || bad "direction 1: PR $n ('MAJOR'/prose-narrative, no run) must be no-machine-record; got: $rec"
done
# ...and the emitted SKIP notice (PR 3) — the old regex's worst false positive,
# since a provable NON-run contains the literal string `workflow-reviewer`.
skp="$(printf '%s\n' "$out" | sed -n 's/^  skip-notice PRs: //p')"
printf '%s\n' " $skp " | grep -F " 3 " >/dev/null \
  || bad "direction 1: PR 3 (legible skip notice = reviewer did NOT run) must be skip-notice, not covered; got: $skp"
ok "direction 1: prose 'MAJOR'/'BLOCKING', a review NARRATIVE, and a skip notice all score NOT covered"

at
# --- 3. DIRECTION 2 — the run emitted a record, the prose says nothing ---------
# PR 2's and PR 7's bodies contain no review narrative at all: their ONLY
# reviewer evidence is what build-level.mjs emitted. Both must score covered,
# and neither may appear in the not-covered lists.
for n in 2 7; do
  printf '%s\n' " $rec $skp " | grep -F " $n " >/dev/null \
    && bad "direction 2: PR $n (emitted §3e record, no prose) must score covered; it was listed not-covered"
done
[ "$(jqf "$(run --days 28 --json)" '.with_workflow_reviewer')" = "2" ] \
  || bad "direction 2: expected exactly PRs 2 and 7 in the numerator"
ok "direction 2: an emitted §3e record scores covered even when the body says nothing in prose"

at
# --- 4. the mandatory reviewer is counted specifically -------------------------
# PR 8 emitted a real tally, but it names docs-reviewer only — a review ran,
# the foundation#1007 MANDATORY workflow-reviewer pass did not.
j="$(run --days 28 --json)"
[ "$(jqf "$j" '.any_reviewer_ran')" -gt "$(jqf "$j" '.with_workflow_reviewer')" ] \
  || bad "PR 8: a tally naming only docs-reviewer must raise any_reviewer_ran without raising the numerator ($j)"
ok "a §3e record naming a non-mandatory reviewer counts as 'ran' but not as workflow-reviewer coverage"

at
# --- 4b. A SKIP CLAUSE ON THE SAME LINE IS NOT A RUN ---------------------------
# REGRESSION (§3e shell-reviewer, HIGH). build-level.mjs joins the ran-tally and
# the skip notes into ONE line with `parts.join(" · ")`, so a real emitted body
# reads:
#
#   §3e review — ran: docs-reviewer · skipped — workflow-reviewer available as …
#
# The names capture ran to end-of-line, swallowing the skip clause, and the
# workflow-reviewer test then matched the SKIP — scoring a PROVABLE non-run as
# covered. That is the exact false positive this rewrite exists to remove,
# reintroduced one layer down.
#
# ISOLATED FIXTURE on purpose: adding a ninth PR to the shared set would shift
# every count-based assertion above, so this case brings its own one-PR world.
mkdir -p "$TMP/fix4b"
jq -n '
  def pr($n; $body; $paths): {number:$n, body:$body, files:[$paths[] | {path:.}]};
  [ pr(1;
       "Adjust next.md wording.\n\n§3e review — ran: docs-reviewer · skipped — workflow-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable\n";
       ["claude/commands/next.md"]) ]' > "$TMP/fix4b/pr-list.json"
j4b="$(env PATH="$TMP/bin:$PATH" WFR_COVERAGE_GH_BIN="$TMP/bin/gh" GH_FIXTURE_DIR="$TMP/fix4b" \
        bash "$SCRIPT" --days 28 --json)"
[ "$(jqf "$j4b" '.command_doc_prs')" = "1" ] \
  || bad "4b: fixture did not load ($j4b)"
[ "$(jqf "$j4b" '.with_workflow_reviewer')" = "0" ] \
  || bad "4b: a same-line workflow-reviewer SKIP must not enter the numerator ($j4b)"
[ "$(jqf "$j4b" '.any_reviewer_ran')" = "1" ] \
  || bad "4b: docs-reviewer DID run on that line, so any_reviewer_ran must be 1 ($j4b)"
ok "4b: a same-line skip clause naming workflow-reviewer does not score as a run"

at
# --- 5. DISCRIMINATION: the marker is what drives the verdict ------------------
# Both directions are re-run against MUTATED fixtures. If the classification
# were keyed on anything other than the emitted marker, these two would not move.
#
# 5a. Strip the emitted tally line from PR 2, leaving its prose untouched ->
#     the numerator must DROP, and PR 2 must become no-machine-record.
jq '(.[] | select(.number==2) | .body) |= (split("\n") | map(select(test("§3e review") | not)) | join("\n"))' \
   "$TMP/fix/pr-list.json" > "$TMP/fix/pr-list.mut" && mv "$TMP/fix/pr-list.mut" "$TMP/fix/pr-list.json"
j2="$(run --days 28 --json)"
[ "$(jqf "$j2" '.with_workflow_reviewer')" = "1" ] \
  || bad "discrimination 5a: removing PR 2's emitted tally must drop the numerator 2 -> 1; got $j2"
[ "$(jqf "$j2" '.no_review_record')" = "4" ] \
  || bad "discrimination 5a: PR 2 must become no-machine-record; got $j2"

# 5b. Give PR 1 — the 'MAJOR' prose PR — a genuine emitted tally. It must flip
#     from no-machine-record to covered, with nothing else about it changed.
write_fixture
jq '(.[] | select(.number==1) | .body) |= (. + "\n§3e review — ran: workflow-reviewer\n")' \
   "$TMP/fix/pr-list.json" > "$TMP/fix/pr-list.mut" && mv "$TMP/fix/pr-list.mut" "$TMP/fix/pr-list.json"
j3="$(run --days 28 --json)"
[ "$(jqf "$j3" '.with_workflow_reviewer')" = "3" ] \
  || bad "discrimination 5b: adding an emitted tally to PR 1 must raise the numerator 2 -> 3; got $j3"
[ "$(jqf "$j3" '.no_review_record')" = "2" ] \
  || bad "discrimination 5b: PR 1 must leave the no-machine-record bucket; got $j3"
write_fixture
ok "discrimination: the numerator moves ONLY with the emitted marker — both directions, same fixtures"

at
# --- 6. empty PR set -> zero-row report, exit 0 (fail-open) --------------------
printf '[]\n' > "$TMP/fix/pr-list.json"
rc=0; out0="$(run --days 28)" || rc=$?
[ "$rc" -eq 0 ] || bad "empty set: expected exit 0, got $rc"
grep -F "command-doc PRs: 0" <<<"$out0" >/dev/null || bad "empty set: expected 0 PRs; got: $out0"
grep -F "coverage: 0%" <<<"$out0"       >/dev/null || bad "empty set: expected 0% (no divide-by-zero); got: $out0"
ok "empty PR set -> zero-row report, exit 0, no divide-by-zero"

if [ "$fails" -eq 0 ]; then
  echo "workflow-reviewer-coverage tests: ALL PASS"
else
  echo "workflow-reviewer-coverage tests: $fails FAILED"; exit 1
fi
