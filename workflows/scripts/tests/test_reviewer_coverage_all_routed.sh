#!/usr/bin/env bash
#
# test_reviewer_coverage_all_routed.sh — hermetic tests for the
# temperloop#1446 generalization: workflow-reviewer-coverage.sh's
# `by_reviewer` rollup, which derives the reviewer SET
# reviewer-routing.tsv (+ the claude/commands/*.md -> workflow-reviewer
# override) routes for each merged PR's changed files, and reports
# per-reviewer coverage over the whole window — not only workflow-reviewer
# over command-doc PRs (that axis stays covered by
# test_workflow_reviewer_coverage.sh, unmodified by this change).
#
# Zero network: a stubbed `gh` and a fixture routing tsv (via
# WFR_COVERAGE_ROUTING_TSV) make the whole run hermetic and independent of
# the repo's live reviewer-routing.tsv, so it can't drift with that file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../workflow-reviewer-coverage.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
mark=0
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
at()   { mark="$fails"; }
ok()   { if [ "$fails" -eq "$mark" ]; then printf '  ok    %s\n' "$1"; fi; mark="$fails"; }

# --- gh double ----------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  jq -c '.' "$GH_FIXTURE_DIR/pr-list.json"; exit 0
fi
exit 0
FAKEGH
chmod +x "$TMP/bin/gh"

# --- fixture routing tsv (small, deterministic roster) -------------------------
cat > "$TMP/routing.tsv" <<'TSV'
# fixture routing tsv — mirrors the shape of the real
# workflows/scripts/config/reviewer-routing.tsv but kept small and
# independent so this test never drifts with the live file.
.py	python-reviewer	claude/agents/reviewers/python-reviewer.md
.sh	shell-reviewer	claude/agents/reviewers/shell-reviewer.md
.ts	typescript-reviewer	claude/agents/reviewers/typescript-reviewer.md
.js	typescript-reviewer	claude/agents/reviewers/typescript-reviewer.md
.mjs	typescript-reviewer	claude/agents/reviewers/typescript-reviewer.md
.rs	rust-reviewer	claude/agents/reviewers/rust-reviewer.md
docs/**	docs-reviewer	claude/agents/docs-reviewer.md
TSV

# --- PR fixtures -----------------------------------------------------------
#  # | touches                          | body carries                                          | expected
# ---|-----------------------------------|--------------------------------------------------------|----------------------------------
#  1 | svc/app.py                        | emitted tally: python-reviewer                          | python-reviewer PASS
#  2 | workflows/scripts/deploy.sh        | nothing                                                 | shell-reviewer NO RECORD
#  3 | docs/readme.md, web/app.ts         | tally docs-reviewer, same-line skip clause naming ts    | docs-reviewer PASS, typescript-reviewer SKIP
#  4 | claude/commands/build.md           | `## Review notes` / `### workflow-reviewer` block       | workflow-reviewer PASS (override, no tsv row)
#  5 | svc/other.py, workflows/x2.sh      | emitted tally: python-reviewer, shell-reviewer          | both PASS
#  6 | lib/mod.rs                         | nothing                                                 | rust-reviewer NO RECORD (routed, zero signal)
# go-reviewer never appears in any tsv row here and no path routes to it —
# it is not part of THIS fixture's roster; rust-reviewer instead plays the
# "routed but zero execution signal" role case 6 exists for.
mkdir -p "$TMP/fix"
jq -n '
def pr($n; $body; $paths): {number:$n, body:$body, files:[$paths[] | {path:.}]};
[
  pr(1; "Add a helper.\n\n§3e review — ran: python-reviewer\n"; ["svc/app.py"]),
  pr(2; "Deploy script tweak.\n"; ["workflows/scripts/deploy.sh"]),
  pr(3; "Docs + a ts touch.\n\n§3e review — ran: docs-reviewer · skipped — typescript-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable\n"; ["docs/readme.md", "web/app.ts"]),
  pr(4; "Rework build.md wording.\n\n## Review notes\n\n### workflow-reviewer\n\n### [LOW] wording\nConsider naming the axis.\n"; ["claude/commands/build.md"]),
  pr(5; "Two-language change.\n\n§3e review — ran: python-reviewer, shell-reviewer\n"; ["svc/other.py", "workflows/x2.sh"]),
  pr(6; "Rust helper, no review record.\n"; ["lib/mod.rs"])
]' > "$TMP/fix/pr-list.json"

run() { env PATH="$TMP/bin:$PATH" WFR_COVERAGE_GH_BIN="$TMP/bin/gh" GH_FIXTURE_DIR="$TMP/fix" \
            WFR_COVERAGE_ROUTING_TSV="$TMP/routing.tsv" bash "$SCRIPT" "$@"; }
jqf() { printf '%s' "$1" | jq -r "$2"; }
by_reviewer() { jqf "$1" ".by_reviewer[] | select(.reviewer==\"$2\")"; }

at
# --- 1. workflow-reviewer's own axis (via the override, no tsv row) -----------
j="$(run --days 28 --json)"
wr="$(by_reviewer "$j" workflow-reviewer)"
[ "$(jqf "$wr" '.routed')" = "true" ]        || bad "workflow-reviewer: expected routed=true; got $wr"
[ "$(jqf "$wr" '.routed_prs')" = "1" ]       || bad "workflow-reviewer: expected routed_prs=1; got $wr"
[ "$(jqf "$wr" '.documented_pass')" = "1" ]  || bad "workflow-reviewer: expected documented_pass=1 (review-notes block, PR4); got $wr"
[ "$(jqf "$wr" '.coverage_pct')" = "100" ]   || bad "workflow-reviewer: expected coverage_pct=100; got $wr"
ok "workflow-reviewer routes via the claude/commands/*.md override even though it has no tsv row"

at
# --- 2. python-reviewer: two routed PRs, both documented as passed ------------
pr="$(by_reviewer "$j" python-reviewer)"
[ "$(jqf "$pr" '.routed_prs')" = "2" ]       || bad "python-reviewer: expected routed_prs=2 (PR1, PR5); got $pr"
[ "$(jqf "$pr" '.documented_pass')" = "2" ]  || bad "python-reviewer: expected documented_pass=2; got $pr"
[ "$(jqf "$pr" '.coverage_pct')" = "100" ]   || bad "python-reviewer: expected coverage_pct=100; got $pr"
ok "python-reviewer (.py) coverage aggregates correctly across two routed PRs"

at
# --- 3. shell-reviewer: routed twice, documented once (PR2 no record) ---------
sr="$(by_reviewer "$j" shell-reviewer)"
[ "$(jqf "$sr" '.routed_prs')" = "2" ]       || bad "shell-reviewer: expected routed_prs=2 (PR2, PR5); got $sr"
[ "$(jqf "$sr" '.documented_pass')" = "1" ]  || bad "shell-reviewer: expected documented_pass=1 (PR5 only); got $sr"
[ "$(jqf "$sr" '.no_record')" = "1" ]        || bad "shell-reviewer: expected no_record=1 (PR2); got $sr"
[ "$(jqf "$sr" '.coverage_pct')" = "50" ]    || bad "shell-reviewer: expected coverage_pct=50; got $sr"
ok "shell-reviewer (.sh) mixes a documented pass and a no-record PR into a partial rate"

at
# --- 4. typescript-reviewer: the SAME-LINE skip clause must not score as ran --
# REGRESSION (temperloop#1450, generalized). The emitted line on PR3 joins the
# ran-tally and the skip note with ` · ` — `ran: docs-reviewer · skipped —
# typescript-reviewer …`. A capture that does not stop at the separator would
# swallow the skip clause into the ran-tally and score typescript-reviewer as
# having run. It must not, for ANY reviewer, not only workflow-reviewer.
tr="$(by_reviewer "$j" typescript-reviewer)"
[ "$(jqf "$tr" '.routed_prs')" = "1" ]        || bad "typescript-reviewer: expected routed_prs=1 (PR3); got $tr"
[ "$(jqf "$tr" '.documented_pass')" = "0" ]   || bad "typescript-reviewer: same-line skip clause must NOT count as a pass; got $tr"
[ "$(jqf "$tr" '.skip_notice')" = "1" ]       || bad "typescript-reviewer: expected skip_notice=1; got $tr"
[ "$(jqf "$tr" '.coverage_pct')" = "0" ]      || bad "typescript-reviewer: expected coverage_pct=0; got $tr"
ok "the same-line skip-clause termination applies to a non-workflow-reviewer reviewer too"

at
# --- 5. docs-reviewer: passed via the docs/** glob row -------------------------
dr="$(by_reviewer "$j" docs-reviewer)"
[ "$(jqf "$dr" '.routed_prs')" = "1" ]       || bad "docs-reviewer: expected routed_prs=1 (PR3); got $dr"
[ "$(jqf "$dr" '.documented_pass')" = "1" ]  || bad "docs-reviewer: expected documented_pass=1; got $dr"
ok "docs-reviewer routes via the docs/** path-glob tsv row"

at
# --- 6. THE TWO ZERO STATES ARE DISTINGUISHABLE (acceptance criterion) --------
# rust-reviewer WAS routed (PR6 touches a .rs file) but the PR emitted no
# review record at all -> explicit zero-coverage, `routed:true`.
rr="$(by_reviewer "$j" rust-reviewer)"
[ "$(jqf "$rr" '.routed')" = "true" ]        || bad "rust-reviewer: expected routed=true (PR6 touched .rs); got $rr"
[ "$(jqf "$rr" '.routed_prs')" = "1" ]       || bad "rust-reviewer: expected routed_prs=1; got $rr"
[ "$(jqf "$rr" '.documented_pass')" = "0" ]  || bad "rust-reviewer: expected documented_pass=0; got $rr"
[ "$(jqf "$rr" '.no_record')" = "1" ]        || bad "rust-reviewer: expected no_record=1; got $rr"
[ "$(jqf "$rr" '.coverage_pct')" = "0" ]     || bad "rust-reviewer: routed-but-silent must report explicit 0, not omission; got $rr"
# go-reviewer never appears as a tsv reviewer in this fixture at all, so it is
# not even in the roster -- prove the roster itself is exactly what the tsv +
# override name, nothing more, nothing less (workflow-reviewer plus the 6 tsv
# reviewers above = 7 rows total).
names="$(jqf "$j" '[.by_reviewer[].reviewer] | sort | join(",")')"
[ "$names" = "docs-reviewer,python-reviewer,rust-reviewer,shell-reviewer,typescript-reviewer,workflow-reviewer" ] \
  || bad "roster mismatch: expected exactly the fixture tsv reviewers + workflow-reviewer; got $names"
ok "a routed-but-silent reviewer (rust-reviewer, explicit 0%) is distinguishable from one absent from the roster entirely"

at
# --- 7. text mode renders both states distinctly -------------------------------
out="$(run --days 28)"
grep -F "rust-reviewer: routed 1  ·  documented pass 0 (0%)" <<<"$out" >/dev/null \
  || bad "text mode: rust-reviewer zero-coverage line not rendered as expected; got:\n$out"
ok "text-mode per-reviewer section renders the routed-but-zero-coverage line"

at
# --- 8. DISCRIMINATION: neuter the per-reviewer derivation itself --------------
# Prove the by_reviewer rollup actually DEPENDS on `routed_set` deriving the
# tsv+override reviewer set — not that it happens to look right by accident.
# A mutated copy of the script with `routed_set` forced to always return `[]`
# (i.e. "nothing is ever routed to anything") must turn every reviewer's
# routed_prs to 0 -- flipping python-reviewer's known PASS (case 2 above) to
# an incorrect "not routed" -- RED. Restoring the real derivation (the
# unmodified script) must return it to routed_prs=2/documented_pass=2 -- GREEN.
mut="$TMP/mutated-coverage.sh"
sed 's/def routed_set(\$paths; \$rules): (\[ \$paths\[\] as \$p | routed_for_path(\$p; \$rules)\[\] \]) | unique;/def routed_set($paths; $rules): [];/' \
  "$SCRIPT" > "$mut"
chmod +x "$mut"
# Sanity: the substitution must actually have applied, or this whole check is
# a no-op that would pass vacuously.
# shellcheck disable=SC2016  # the $paths/$rules below are literal jq source text being grepped for, not shell expansions
grep -qF 'def routed_set($paths; $rules): [];' "$mut" \
  || bad "discrimination setup: the routed_set neutering substitution did not match — test would be vacuous"

jred="$(env PATH="$TMP/bin:$PATH" WFR_COVERAGE_GH_BIN="$TMP/bin/gh" GH_FIXTURE_DIR="$TMP/fix" \
            WFR_COVERAGE_ROUTING_TSV="$TMP/routing.tsv" bash "$mut" --days 28 --json)"
pr_red="$(by_reviewer "$jred" python-reviewer)"
[ "$(jqf "$pr_red" '.routed')" = "false" ] \
  || bad "RED case: neutering routed_set must make python-reviewer read routed=false; got $pr_red"
[ "$(jqf "$pr_red" '.documented_pass')" = "0" ] \
  || bad "RED case: neutering routed_set must drop documented_pass to 0; got $pr_red"

pr_green="$(by_reviewer "$j" python-reviewer)"
[ "$(jqf "$pr_green" '.routed')" = "true" ] && [ "$(jqf "$pr_green" '.documented_pass')" = "2" ] \
  || bad "GREEN case: the real (unmutated) script must still report python-reviewer routed with 2 passes; got $pr_green"
ok "discrimination: by_reviewer is RED when routed_set is neutered and GREEN with the real derivation restored"

if [ "$fails" -eq 0 ]; then
  echo "reviewer-coverage-all-routed tests: ALL PASS"
else
  echo "reviewer-coverage-all-routed tests: $fails FAILED"; exit 1
fi
