#!/usr/bin/env bash
#
# workflow-reviewer-coverage.sh — reporting rollup for temperloop#1007,
# generalized to every ROUTED reviewer by temperloop#1446.
#
# Reports the COVERAGE RATE of §3e pre-push review: of the merged PRs in a
# window, what fraction of the reviewers `workflows/scripts/config/
# reviewer-routing.tsv` routes for each PR's changed files carry
# MACHINE-EMITTED EVIDENCE THAT THE REVIEWER ACTUALLY RAN.
#
# ── temperloop#1446 — every routed reviewer, not just workflow-reviewer ────
# The §3e gap (#1387/#1430) stayed invisible for ~a month because nothing
# measured whether reviews executed. #1450 fixed that for exactly ONE
# reviewer (workflow-reviewer) over exactly ONE path class (command-doc
# PRs) — every OTHER routed reviewer (shell-reviewer, docs-reviewer,
# python-reviewer, typescript-reviewer, …) still had no execution signal at
# all: the same defect class, just uncovered by the fix that caught it once.
#
# This script now ALSO derives, for every merged PR in the window, the full
# reviewer SET `/build`'s §3e step would route for that PR's changed files —
# `reviewer-routing.tsv`'s extension/path-glob axis, plus the one in-prose
# override build.md 3e states outside the tsv: a `claude/commands/*.md`
# workflow spec always routes to `workflow-reviewer`, regardless of any tsv
# row (foundation#1007). (build.md 3e's OTHER non-tsv routes — a `review:`
# item override, the `architectural` change-kind route, and the generic
# "any other stranger-facing `*.md` -> docs-reviewer" prose fallback — carry
# no file-glob a PR's `files` list alone can reproduce, so they are
# deliberately OUT of scope here; the tsv + the one md override are the
# routes this script can derive purely from `gh pr list --json files`.)
#
# For each reviewer that tsv/override names ANYWHERE (the roster), across
# every merged PR that reviewer is routed to in the window, the SAME
# machine-emitted-evidence classification #1450 built is reused/generalized
# (see `reviewer_ran`/`reviewer_skipped` below) — no new false-positive
# surface, and the same same-line skip-clause termination (a `§3e review —
# ran: docs-reviewer · skipped — workflow-reviewer …` line must not score
# `workflow-reviewer` as ran) applies to every reviewer, not only
# workflow-reviewer.
#
# The result is reported PER REVIEWER, in the `by_reviewer` array/section —
# a reviewer with ZERO routed PRs this window ("nothing to review") is
# listed with `routed: false` and a null rate; a reviewer that WAS routed
# but has no execution signal at all is listed with `routed: true` and
# `coverage_pct: 0` — the two are never conflated, and no roster reviewer is
# ever silently omitted from the table.
#
# ── What changed for workflow-reviewer specifically, and why (temperloop#1450) ──
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
# --json shape (all counts over the command-doc denominator, PLUS by_reviewer):
#   {since, command_doc_prs, with_workflow_reviewer, any_reviewer_ran,
#    skip_notice_only, no_review_record, coverage_pct, by_reviewer}
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
#   by_reviewer             ONE ROW PER REVIEWER in the tsv+override roster
#                           (temperloop#1446), over ALL merged PRs in the
#                           window (not just command-doc PRs): {reviewer,
#                           routed, routed_prs, documented_pass, skip_notice,
#                           no_record, coverage_pct}. `routed:false`
#                           (routed_prs==0, coverage_pct:null) means nothing
#                           was routed to that reviewer this window;
#                           `routed:true` with `coverage_pct:0` means it WAS
#                           routed and never documented as having run — the
#                           two states are always distinguishable, and every
#                           roster reviewer is always present in the array.
#
# ── temperloop#1705 — the UNROUTED-PATH figure ─────────────────────────────
# `by_reviewer` above measures reviewers. It cannot see a changed path that
# NO routing rule matches: such a path produces no routed-reviewer entry, so
# it is absent from the denominator entirely — neither covered nor uncovered.
# That is the mirror image of the very gap #1446's acceptance criterion
# eliminated for reviewers ("an absent reviewer must be distinguishable from
# a reviewer with nothing to review"), and it is how `Makefile` — the 7th
# highest-churn reviewable file in this repo, 41 changes in 90 days — stayed
# unrouted and invisible until a human read the tsv by hand (temperloop#1705).
#
# So the window's changed paths are ALSO partitioned and reported, as their
# own figure independent of any reviewer:
#   changed_paths            distinct paths across every merged PR in window.
#   routed_paths             matched by a tsv row, or by the
#                            claude/commands/*.md -> workflow-reviewer override.
#   prose_md_fallback_paths  matched by no tsv row but ending in `.md`, i.e.
#                            claimed by build.md 3e's in-prose "any other
#                            stranger-facing prose *.md -> docs-reviewer"
#                            fallback. Counted separately, NOT as unrouted:
#                            build.md does route them, this script just can't
#                            tell WHICH are stranger-facing (ADR 0008's
#                            reason for keeping that route in prose).
#   unrouted_paths           NEITHER. No rule of any kind reaches these — the
#                            actionable number, and the one a new high-churn
#                            unrouted file shows up in.
#   unrouted_path_examples   up to 20 of them, so the figure names names
#                            rather than only counting.
#   The three buckets partition changed_paths:
#   routed_paths + prose_md_fallback_paths + unrouted_paths == changed_paths.
#
# Test seam: WFR_COVERAGE_GH_BIN overrides the gh binary (hermetic; see
# test_workflow_reviewer_coverage.sh and test_reviewer_coverage_all_routed.sh).
# WFR_COVERAGE_ROUTING_TSV overrides the routing tsv path (hermetic fixtures).
# Fail-open: an unreadable PR list yields a zero-row report and exit 0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GH="${WFR_COVERAGE_GH_BIN:-gh}"
DAYS=28
REPO=""
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,146p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "workflow-reviewer-coverage: unknown arg: $1" >&2; exit 2 ;;
  esac
done

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

# ── Load the routing roster (temperloop#1446) ───────────────────────────────
# reviewer-routing.tsv is the single source of truth for the extension/glob
# axis (ADR 0008); the ONE non-tsv route this script can derive from a PR's
# `files` list alone — claude/commands/*.md -> workflow-reviewer (foundation
# #1007) — is added below as a literal roster member, since it never appears
# as a tsv row. Parsed bash-3.2-portable, same read-loop shape as
# workflows/scripts/config/check-reviewer-routing.sh.
TSV="${WFR_COVERAGE_ROUTING_TSV:-$SCRIPT_DIR/config/reviewer-routing.tsv}"
routing_rows=()
# AN ABSENT OR UNREADABLE ROUTING TABLE IS NOT AN EMPTY ONE (temperloop#1446
# review, MEDIUM). Without this guard the `if [ -f ]` falls through with no
# `else`, the roster collapses to the single hardcoded workflow-reviewer
# member, and the report renders a confident per-reviewer table that silently
# OMITS every reviewer the table would have named. That reads exactly like
# "those reviewers were never routed" -- the same false all-clear the regex
# escaping above exists to prevent, arriving through a different door.
if [ ! -e "$TSV" ]; then
  printf %s\\n "workflow-reviewer-coverage: WARNING - routing table not found at $TSV; the per-reviewer roster is DEGRADED to workflow-reviewer only. Every other reviewer is OMITTED, not measured as zero." >&2
elif [ ! -r "$TSV" ]; then
  printf %s\\n "workflow-reviewer-coverage: WARNING - routing table at $TSV exists but is UNREADABLE; the per-reviewer roster is DEGRADED to workflow-reviewer only. Every other reviewer is OMITTED, not measured as zero." >&2
fi
if [ -r "$TSV" ]; then
  while IFS=$'\t' read -r pattern reviewer _agent_path || [ -n "${pattern:-}" ]; do
    [ -z "${pattern:-}" ] && continue
    case "$pattern" in \#*) continue ;; esac
    [ -z "${reviewer:-}" ] && continue
    routing_rows+=("$pattern"$'\t'"$reviewer")
  done <"$TSV"
fi
if [ "${#routing_rows[@]}" -gt 0 ]; then
  routing_rules_json="$(printf '%s\n' "${routing_rows[@]}" | jq -R -s -c \
    'split("\n") | map(select(length > 0)) | map(split("\t")) | map({pattern: .[0], reviewer: .[1]})')"
else
  routing_rules_json='[]'
fi
reviewer_roster_json="$(printf '%s' "$routing_rules_json" \
  | jq -c '([.[].reviewer] + ["workflow-reviewer"]) | unique')"

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
#
# `reviewer_ran`/`reviewer_skipped` (temperloop#1446) generalize the same
# three shapes to ANY reviewer name, so the identical same-line-separator
# protection applies uniformly across the whole roster, not only to
# workflow-reviewer.
jq_err="$(mktemp "${TMPDIR:-/tmp}/wfr-cov-jqerr-XXXXXX")"
report="$(printf '%s' "$prs_json" | jq -c --arg since "$since" --argjson rules "$routing_rules_json" --argjson roster "$reviewer_roster_json" '
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

  # ── temperloop#1446: the same three shapes, generalized to ANY reviewer ────
  # `ran_tally_names($body)` mirrors the `[ran_tally.names]` array-collection
  # idiom above (a `capture` that does not match yields NO output, so it must
  # be collected into an array before `any(...)` can be applied safely).
  def ran_tally_names($body): [ $body | capture("(^|\n)§3e review[ \t]*[—–-][ \t]*ran:[ \t]*(?<names>[^\n·]*)").names ];

  # A REVIEWER NAME IS DATA, NOT A PATTERN (temperloop#1446 review, HIGH).
  # `$r` arrives verbatim from reviewer-routing.tsv column 2. Concatenated raw
  # into a regex, a name carrying a metacharacter (`bad(reviewer`) makes the jq
  # `test` builtin THROW — and the whole pipeline fail-open (`2>/dev/null ||
  # echo ""`) then renders that throw as the zero-row report: every count 0,
  # `by_reviewer` empty, exit 0. A false all-clear indistinguishable from a
  # genuinely quiet window, on the one tool whose entire job is making an
  # invisible gap visible. It would also take the legacy temperloop#1450
  # workflow-reviewer metric down with it, since both share this single jq
  # invocation.
  #
  # Escape rather than trust the input. The sibling consumer of this same tsv
  # already does exactly this (`_rr_ere_escape` in
  # workflows/scripts/config/check-reviewer-routing.sh) — matching that
  # precedent rather than inventing a second convention. NOTE: no apostrophes
  # anywhere in this block; the jq program is a single-quoted shell string and
  # one apostrophe ends it (a trap this repo has paid for before).
  def re_escape($v): $v | gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\/-])"; "\\" + .c);

  def reviewer_ran($r; $body):
    (ran_tally_names($body) | any(test("\\b" + re_escape($r) + "\\b")))
    or ($body | test("(^|\n)###[ \t]+" + re_escape($r) + "[ \t\r]*(\n|$)"));
  def reviewer_skipped($r; $body): $body | test("skipped[ \t]*[—–-][ \t]*`?" + re_escape($r) + "\\b");

  # Extension rows match by suffix (`.py`); dir-glob rows (`docs/**`) match by
  # prefix on the glob stripped of its trailing `**`; basename rows
  # (`**/Makefile`, temperloop#1705) match the bare path or any `<dir>/<base>`
  # at any depth — an EXACT basename, never a suffix, so `**/Makefile` cannot
  # claim `NotAMakefile`. These three shapes are the tsv key grammar
  # (reviewer-routing.tsv header) and must stay in lockstep with
  # build-level.mjs reviewGlobMatch(), the copy §3e actually routes through.
  # A `claude/commands/*.md`
  # path always routes to workflow-reviewer, overriding any tsv match for that
  # SAME path (foundation#1007) — no tsv row currently claims `.md`, so this is
  # additive today, but the override wins by construction if one ever did.
  def is_workflow_md($p): $p | test("^claude/commands/.*\\.md$");
  def match_rule($p; $rule):
    if ($rule.pattern | startswith("**/")) then
      ($rule.pattern[3:]) as $base | ($p == $base or ($p | endswith("/" + $base)))
    elif ($rule.pattern | startswith(".")) then ($p | endswith($rule.pattern))
    elif ($rule.pattern | endswith("/**")) then ($p | startswith($rule.pattern[0:-2]))
    else false end;
  def routed_for_path($p; $rules):
    if is_workflow_md($p) then ["workflow-reviewer"]
    else [ $rules[] | select(match_rule($p; .)) | .reviewer ]
    end;
  def routed_set($paths; $rules): ([ $paths[] as $p | routed_for_path($p; $rules)[] ]) | unique;

  ([ .[] | select(any(.paths[]?; test("^claude/commands/.*\\.md$"))) ]
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
  ) as $legacy
  | (. | map(. + {routed: routed_set(.paths; $rules)})) as $prs_routed
  | ($roster | map(
       . as $r
       | ($prs_routed | map(select(.routed | index($r)))) as $matching
       | ($matching | map(select(reviewer_ran($r; .body)))) as $passed
       | ($matching | map(select((reviewer_ran($r; .body) | not) and reviewer_skipped($r; .body)))) as $skipped
       | ($matching | map(select((reviewer_ran($r; .body) | not) and (reviewer_skipped($r; .body) | not)))) as $norecord
       | {
           reviewer: $r,
           routed: (($matching | length) > 0),
           routed_prs: ($matching | length),
           documented_pass: ($passed | length),
           skip_notice: ($skipped | length),
           no_record: ($norecord | length),
           coverage_pct: (if ($matching | length) > 0
                          then (($passed | length) * 100 / ($matching | length) | floor)
                          else null end)
         })
     | sort_by(.reviewer)) as $by_reviewer

  # ── temperloop#1705: the UNROUTED-PATH partition ──────────────────────────
  # Reviewer-keyed rollups structurally cannot see a path NO rule matches --
  # it contributes to no reviewer row, so it is absent from the denominator
  # rather than counted as uncovered. Partition the distinct changed paths in
  # the window instead, so an unrouted file is a FIGURE with a name attached.
  # `prose_md_fallback` is split out rather than folded into unrouted: those
  # paths ARE routed, by the in-prose stranger-facing `*.md` -> docs-reviewer
  # fallback in build.md 3e that ADR 0008 deliberately keeps out of the tsv.
  # Folding them in would bury the actionable number under every README.
  | ([ .[] | .paths[]? ] | unique) as $all_paths
  | ($all_paths | map(select((routed_for_path(.; $rules) | length) == 0))) as $unmatched
  | ($unmatched | map(select(test("\\.md$")))) as $prose_md
  | ($unmatched | map(select(test("\\.md$") | not))) as $unrouted
  | $legacy + {
      by_reviewer: $by_reviewer,
      changed_paths: ($all_paths | length),
      routed_paths: (($all_paths | length) - ($unmatched | length)),
      prose_md_fallback_paths: ($prose_md | length),
      unrouted_paths: ($unrouted | length),
      unrouted_path_examples: ($unrouted[0:20])
    }
' 2>"$jq_err" || true)"
# NARROW THE FAIL-OPEN (temperloop#1446 review, HIGH aggravator). This was
# `2>/dev/null || echo ""`, which rendered ANY jq error -- a thrown regex, a
# malformed body, a bad filter -- as the all-zeros fallback below: a report that
# looks like a quiet window and is actually a crashed one. The fallback stays (a
# report beats nothing), but it can no longer be SILENT.
if [ -s "$jq_err" ]; then
  printf %s\\n "workflow-reviewer-coverage: WARNING - the coverage query FAILED; the figures below are the ZERO FALLBACK and measure nothing. jq said:" >&2
  sed "s/^/  /" "$jq_err" >&2
fi
rm -f "$jq_err"
# The zero fallback carries EVERY reported field, the temperloop#1705 path
# figures included — a fallback missing a key renders it as a literal `null`
# in the text summary, which reads like a measured value rather than the
# crashed-query sentinel the WARNING above just named.
[ -n "$report" ] || report='{"since":"'"$since"'","command_doc_prs":0,"with_workflow_reviewer":0,"any_reviewer_ran":0,"skip_notice_only":0,"no_review_record":0,"skipped_prs":[],"unrecorded_prs":[],"coverage_pct":0,"by_reviewer":[],"changed_paths":0,"routed_paths":0,"prose_md_fallback_paths":0,"unrouted_paths":0,"unrouted_path_examples":[]}'

if [ "$JSON" = 1 ]; then
  printf '%s' "$report" | jq -c 'del(.skipped_prs, .unrecorded_prs)'
  echo
else
  printf '%s' "$report" | jq -r '
    "workflow-reviewer coverage (merged PRs since \(.since)):",
    "  command-doc PRs: \(.command_doc_prs)  ·  workflow-reviewer RAN (machine-recorded): \(.with_workflow_reviewer)  ·  coverage: \(.coverage_pct)%",
    "  any reviewer ran: \(.any_reviewer_ran)  ·  legible skip notice (did NOT run): \(.skip_notice_only)  ·  no machine record: \(.no_review_record)",
    (if (.skipped_prs | length) > 0 then "  skip-notice PRs: \(.skipped_prs | map(tostring) | join(" "))" else empty end),
    (if (.unrecorded_prs | length) > 0 then "  no-record PRs: \(.unrecorded_prs | map(tostring) | join(" "))" else empty end),
    "",
    "per-reviewer coverage (every reviewer reviewer-routing.tsv + the claude/commands/*.md override route, all merged PRs since \(.since)):",
    (.by_reviewer[] |
      if .routed then
        "  \(.reviewer): routed \(.routed_prs)  ·  documented pass \(.documented_pass) (\(.coverage_pct)%)  ·  skip notice \(.skip_notice)  ·  no record \(.no_record)"
      else
        "  \(.reviewer): not routed this window (nothing to review)"
      end),
    "",
    "changed-path routing (temperloop#1705 — every distinct path in the window, so an unrouted file is visible):",
    "  changed paths: \(.changed_paths)  ·  routed: \(.routed_paths)  ·  prose *.md fallback: \(.prose_md_fallback_paths)  ·  UNROUTED (no rule matches): \(.unrouted_paths)",
    (if (.unrouted_path_examples | length) > 0
       then "  unrouted paths: \(.unrouted_path_examples | join(" "))"
       else empty end)
  '
fi

exit 0
