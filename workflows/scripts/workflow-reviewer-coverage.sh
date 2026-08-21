#!/usr/bin/env bash
#
# workflow-reviewer-coverage.sh — reporting rollup for temperloop#1007.
#
# Reports the COVERAGE RATE of the workflow-reviewer gate: of the merged PRs in a
# window that TOUCHED a `claude/commands/*.md` workflow spec, what fraction carry
# MACHINE-EMITTED EVIDENCE THAT THE REVIEWER ACTUALLY RAN.
#
# ── What changed, and why (temperloop#1450) ────────────────────────────────
# This script used to classify a PR as covered when its body matched, case-
# insensitively, `workflow-reviewer|BLOCKING|MAJOR`. That measured PROSE, not
# execution, and it was wrong in BOTH directions:
#
#   * FALSE POSITIVE — any changelog line, risk note, or quoted finding
#     containing the word "MAJOR" or "BLOCKING" scored as a documented pass.
#     Worse, the ONE shape the #1007 gate exists to make visible — the legible
#     `skipped — workflow-reviewer …` degradation notice, i.e. the reviewer
#     provably did NOT run — contains the string `workflow-reviewer` and so
#     scored as COVERED. Before #1430 that skip was structurally guaranteed on
#     every Workflow-path command-doc PR (temperloop#1429), so the metric read
#     highest exactly when the gate was most broken.
#   * FALSE NEGATIVE — a real pass whose verdict reached the PR body in any
#     other wording scored as uncovered.
#
# The fix: count only what the RUN ITSELF EMITS. `claude/workflows/build-level.mjs`
# (§3e, temperloop#1430) writes two structured, machine-generated shapes into the
# PR body via the verdict `summary` that `pr.sh open` renders:
#
#   1. the tally line, at line start:   `§3e review — ran: <reviewer>[, <reviewer>…]`
#   2. the spliced findings section:    `## Review notes` / `### <reviewer>`
#
# Both are emitted by the driver, never typed by a human writing prose about the
# review. A `## The §3e review caught …` narrative HEADING does not match (1):
# the tally is anchored to line start and must carry the literal `ran:` list.
#
# CONSEQUENCE, stated plainly: a PR whose review ran but left NO machine record
# (e.g. driven conversationally, with the outcome narrated in prose only) is
# reported as `no_review_record` — NOT as covered. That is deliberate. The point
# of this rollup is to measure emitted evidence; a run that emitted none is
# indistinguishable from a run that never reviewed, and the honest report says
# "no record" rather than crediting prose. `no_review_record` is therefore the
# actionable number: it names the PRs whose review path emits nothing.
#
# It is a REPORTING rollup, NOT a merge gate: LLM-judgment gates are deliberately
# excluded from the deterministic `checks` set (see build.md 3e), so this NEVER
# blocks a merge — it surfaces a trend for `/check-in` or a retro to read.
#
# Usage: workflow-reviewer-coverage.sh [--days N] [--repo owner/repo] [--json]
#   --days N   window length in days ending now (default 28 — the 4-week window)
#   --repo R   owner/repo (default: gh's resolved default for the cwd)
#   --json     machine-readable output instead of the text summary
#
# --json shape (all counts over the command-doc denominator):
#   {since, command_doc_prs, with_workflow_reviewer, any_reviewer_ran,
#    skip_notice_only, no_review_record, coverage_pct}
#   with_workflow_reviewer  the numerator: `workflow-reviewer` named in an
#                           emitted `ran:` tally, or its own `### workflow-reviewer`
#                           review-notes block. coverage_pct is this / denominator.
#   any_reviewer_ran        an emitted §3e record naming ANY reviewer that ran
#                           (>= with_workflow_reviewer).
#   skip_notice_only        no run record, but a legible `skipped — workflow-reviewer …`
#                           notice — the gate degraded legibly. NOT covered.
#   no_review_record        neither. The build path emitted nothing at all.
#   The three buckets partition the denominator:
#   any_reviewer_ran + skip_notice_only + no_review_record == command_doc_prs.
#
# Test seam: WFR_COVERAGE_GH_BIN overrides the gh binary (hermetic; see test_workflow_reviewer_coverage.sh).
# Fail-open: an unreadable PR list yields a zero-row report and exit 0.
set -euo pipefail

GH="${WFR_COVERAGE_GH_BIN:-gh}"
DAYS=28
REPO=""
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "workflow-reviewer-coverage: unknown arg: $1" >&2; exit 2 ;;
  esac
done

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

# Window start: N days ago, portable across BSD (macOS) and GNU date.
since="$(date -u -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null || date -u -d "-${DAYS} days" '+%Y-%m-%d')"

# Merged PRs in the window. Preferred shape: ONE list call carrying number, body
# AND files — `gh pr list --json files` collapses what used to be an N+1 fan-out
# of `gh pr view` calls (one per merged PR in the window, ~200 on a busy month)
# into a single request, which matters against the shared GraphQL budget.
# A gh too old to accept `files` on `pr list` exits non-zero ("Unknown JSON
# field"); that arm falls back to the original two-call path, so a vendoring
# consumer on an older gh keeps working with no probing beyond this one retry.
prs_json=""
if prs_json="$("$GH" pr list "${repo_args[@]+"${repo_args[@]}"}" --state merged --search "merged:>=$since" \
                 --limit 200 --json number,body,files 2>/dev/null)"; then
  prs_json="$(printf '%s' "$prs_json" \
    | jq -c '[ .[] | {number, body: (.body // ""), paths: [ (.files // [])[] | .path ]} ]' 2>/dev/null || echo '')"
fi
if [ -z "$prs_json" ] || [ "$prs_json" = "null" ]; then
  # Fallback: list without `files`, then one `pr view` per PR for its paths.
  list_json="$("$GH" pr list "${repo_args[@]+"${repo_args[@]}"}" --state merged --search "merged:>=$since" \
                --limit 200 --json number,body 2>/dev/null || echo '[]')"
  [ -n "$list_json" ] || list_json='[]'
  rows=""
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    files="$("$GH" pr view "$n" "${repo_args[@]+"${repo_args[@]}"}" --json files --jq '.files[].path' 2>/dev/null || true)"
    row="$(printf '%s' "$list_json" | jq -c --argjson n "$n" --arg files "$files" \
      '(.[] | select(.number==$n)) as $pr
       | {number: $n, body: ($pr.body // ""),
          paths: ($files | split("\n") | map(select(length > 0)))}')"
    rows="$rows$row
"
  done < <(printf '%s' "$list_json" | jq -r '.[].number')
  prs_json="$(printf '%s' "$rows" | jq -sc '.' 2>/dev/null || echo '[]')"
fi
[ -n "$prs_json" ] || prs_json='[]'

# ── Classification ─────────────────────────────────────────────────────────
# Every pattern below matches a shape build-level.mjs EMITS, never free prose.
#
#   RAN_TALLY   line-anchored `§3e review — ran: <names>` (runReviewers()'s
#               summary; the dash is matched permissively, the anchor and the
#               literal `ran:` list are not). A prose heading such as
#               `## The §3e review caught …` cannot match: it is not at line
#               start and carries no `ran:`.
#   NOTES_BLOCK line-anchored `### <reviewer>` inside the spliced `## Review
#               notes` section — the second, independent emitted structure.
#   SKIP_NOTICE the legible degradation line (`skipped — workflow-reviewer …`),
#               matched leniently because it is only a REPORTING bucket, never
#               the numerator. Matching it is what stops the old regex's worst
#               false positive: a provable non-run scoring as a pass.
report="$(printf '%s' "$prs_json" | jq -c --arg since "$since" '
  # NAMES STOP AT THE ` · ` SEPARATOR, not at end-of-line. build-level.mjs
  # joins the ran-tally and the skip notes into ONE summary string with
  # `parts.join(" · ")`, so a real emitted line reads:
  #
  #   §3e review — ran: docs-reviewer · skipped — workflow-reviewer available …
  #
  # A greedy `[^\n]*` capture swallows that whole skip clause into `names`, and
  # the `\bworkflow-reviewer\b` test below then matches the SKIP — scoring a
  # provable non-run as covered. That is precisely the false positive this
  # rewrite exists to remove, reintroduced one layer down; caught by the §3e
  # shell-reviewer, which reproduced it hermetically.
  #
  # `\r?` throughout: a body with CRLF endings must not silently drop out of
  # the numerator while still counting in the denominator.
  def ran_tally: capture("(^|\n)§3e review[ \t]*[—–-][ \t]*ran:[ \t]*(?<names>[^\n·]*)");
  def any_ran:   test("(^|\n)§3e review[ \t]*[—–-][ \t]*ran:[ \t]*\\S")
               or test("(^|\n)###[ \t]+[A-Za-z][A-Za-z0-9-]*-reviewer[ \t\r]*(\n|$)")
               or test("(^|\n)###[ \t]+(congruence-lens|requirements-auditor)[ \t\r]*(\n|$)");
  # `capture` yields NOTHING (not null) when it does not match, so its result is
  # collected into an ARRAY first: an `empty` reaching the enclosing `map` below
  # would silently DROP that PR from the object being built, shrinking the
  # DENOMINATOR instead of scoring the PR uncovered.
  def wfr_ran:   ([ran_tally.names] | any(test("\\bworkflow-reviewer\\b")))
               or test("(^|\n)###[ \t]+workflow-reviewer[ \t\r]*(\n|$)");
  def skip_notice: test("skipped[ \t]*[—–-][ \t]*`?workflow-reviewer\\b");

  [ .[] | select(any(.paths[]?; test("^claude/commands/.*\\.md$"))) ]
  | map(. + {ran: (.body | any_ran), wfr: (.body | wfr_ran), skip: (.body | skip_notice)})
  | {
      since: $since,
      command_doc_prs: length,
      with_workflow_reviewer: (map(select(.wfr)) | length),
      any_reviewer_ran:       (map(select(.ran)) | length),
      skip_notice_only:       (map(select(.ran | not) | select(.skip)) | length),
      no_review_record:       (map(select(.ran | not) | select(.skip | not)) | length),
      skipped_prs:            (map(select(.ran | not) | select(.skip) | .number)),
      unrecorded_prs:         (map(select(.ran | not) | select(.skip | not) | .number))
    }
  | . + {coverage_pct: (if .command_doc_prs > 0
                        then (.with_workflow_reviewer * 100 / .command_doc_prs | floor)
                        else 0 end)}
' 2>/dev/null || echo '')"
[ -n "$report" ] || report='{"since":"'"$since"'","command_doc_prs":0,"with_workflow_reviewer":0,"any_reviewer_ran":0,"skip_notice_only":0,"no_review_record":0,"skipped_prs":[],"unrecorded_prs":[],"coverage_pct":0}'

if [ "$JSON" = 1 ]; then
  printf '%s' "$report" | jq -c 'del(.skipped_prs, .unrecorded_prs)'
  echo
else
  printf '%s' "$report" | jq -r '
    "workflow-reviewer coverage (merged PRs since \(.since)):",
    "  command-doc PRs: \(.command_doc_prs)  ·  workflow-reviewer RAN (machine-recorded): \(.with_workflow_reviewer)  ·  coverage: \(.coverage_pct)%",
    "  any reviewer ran: \(.any_reviewer_ran)  ·  legible skip notice (did NOT run): \(.skip_notice_only)  ·  no machine record: \(.no_review_record)",
    (if (.skipped_prs | length) > 0 then "  skip-notice PRs: \(.skipped_prs | map(tostring) | join(" "))" else empty end),
    (if (.unrecorded_prs | length) > 0 then "  no-record PRs: \(.unrecorded_prs | map(tostring) | join(" "))" else empty end)
  '
fi

exit 0
