#!/usr/bin/env bash
#
# workflow-reviewer-coverage.sh — reporting rollup for temperloop#1007.
#
# Reports the COVERAGE RATE of the workflow-reviewer gate: of the merged PRs in a
# window that TOUCHED a `claude/commands/*.md` workflow spec, what fraction carry a
# documented workflow-reviewer pass (a `workflow-reviewer` / `BLOCKING` / `MAJOR`
# mention in the PR body). This is the leading/lagging metric epic #916's retro
# item (#1007) asked for — the numerator/denominator its baseline named (3 of 4).
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
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "workflow-reviewer-coverage: unknown arg: $1" >&2; exit 2 ;;
  esac
done

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

# Window start: N days ago, portable across BSD (macOS) and GNU date.
since="$(date -u -v-"${DAYS}"d '+%Y-%m-%d' 2>/dev/null || date -u -d "-${DAYS} days" '+%Y-%m-%d')"

# Merged PRs in the window (number + body) — one list call.
prs_json="$("$GH" pr list "${repo_args[@]}" --state merged --search "merged:>=$since" \
             --limit 200 --json number,body 2>/dev/null || echo '[]')"
[ -n "$prs_json" ] || prs_json='[]'

total=0
covered=0
uncovered_list=""
while IFS= read -r n; do
  [ -n "$n" ] || continue
  # Did this PR touch a workflow spec? (per-PR files — not available on `pr list`.)
  files="$("$GH" pr view "$n" "${repo_args[@]}" --json files --jq '.files[].path' 2>/dev/null || true)"
  printf '%s\n' "$files" | grep -qE '^claude/commands/.*\.md$' || continue
  total=$((total + 1))
  body="$(printf '%s' "$prs_json" | jq -r --argjson n "$n" '.[] | select(.number==$n) | .body // ""')"
  if printf '%s' "$body" | grep -qiE 'workflow-reviewer|BLOCKING|MAJOR'; then
    covered=$((covered + 1))
  else
    uncovered_list="$uncovered_list $n"
  fi
done < <(printf '%s' "$prs_json" | jq -r '.[].number')

rate=0
if [ "$total" -gt 0 ]; then rate=$(( covered * 100 / total )); fi

if [ "$JSON" = 1 ]; then
  jq -cn --arg since "$since" --argjson total "$total" --argjson covered "$covered" --argjson rate "$rate" \
    '{since:$since, command_doc_prs:$total, with_workflow_reviewer:$covered, coverage_pct:$rate}'
else
  echo "workflow-reviewer coverage (merged PRs since $since):"
  echo "  command-doc PRs: $total  ·  with a documented workflow-reviewer pass: $covered  ·  coverage: ${rate}%"
  if [ -n "$uncovered_list" ]; then echo "  uncovered PRs:$uncovered_list"; fi
fi

exit 0
