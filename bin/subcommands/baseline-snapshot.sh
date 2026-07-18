#!/usr/bin/env bash
# description: append one aggregate-only 90-day gh-history snapshot record to .temperloop/baseline.jsonl
#
# baseline-snapshot.sh — `foundation baseline-snapshot`: the 'BEFORE'
# picture for Epic E's value loop (foundation #766, epic #765-adjacent
# "Epic E" value-proof work, item baseline-snapshot / #766). A later item's
# "report" reads this file and never calls `gh` itself — this script is the
# ONLY place in the value loop that talks to the GitHub API for the
# baseline signal.
#
# DISPATCH MODEL: this file is a DISCOVERED subcommand — its mere presence
# at kernel/bin/subcommands/baseline-snapshot.sh next to the dispatcher's
# other subcommand files IS `foundation baseline-snapshot`, executed in its
# own process (see kernel/bin/foundation's header comment). This script
# also has a SECOND call site: kernel/bin/subcommands/init.sh Step 0 shells
# out to it directly (`bash "$BASELINE_SNAPSHOT"`, cwd already set to the
# target repo) as a soft seam — init.sh's own file-existence check on this
# exact path IS its capability probe; this script has no opinion on that
# and adds no code for it. Both call sites use the SAME one-line contract:
#
#     invoked with NO ARGS, cwd = the target repo. Exit 0 = a record was
#     appended to .temperloop/baseline.jsonl. This is a SOFT SEAM: it is
#     designed to never need a non-zero exit to signal "nothing to report"
#     — an unresolvable repo, missing/unauthenticated gh, or a network
#     failure all still produce a legible `metrics.available: false`
#     record and exit 0. Only a genuine local write failure (disk full,
#     permissions) exits 1 — the one case where "a record was appended" is
#     actually false.
#
# Full field-by-field record schema (schema 1):
#   kernel/workflows/scripts/lib/baseline_snapshot.contract.md — also
#   rendered by `make docs` (workflows/scripts/docs/sources/
#   adapter_contracts.py's pinned `workflows/scripts/lib/*.contract.md`
#   glob already covers this file; zero generator changes needed, same
#   precedent as conventions_probe.contract.md).
#
# CONSENT POSTURE — AGGREGATE-ONLY, BY CONSTRUCTION: every metric this
# script computes is a population statistic (a count or a median) over the
# 90-day window. `gh pr list --json reviews` necessarily returns each
# review's author alongside its timestamp (gh's --json flag has no
# sub-field selector), so that identifying data transiently exists in this
# process's memory for one run — but only `.reviews[].submittedAt` is ever
# read out of it; no name, login, or per-person breakdown is computed, held
# past the median calculation below, or written to the record. There is no
# per-author or per-reviewer field anywhere in this script's jq output, by
# construction, not by a redaction step bolted on afterward.
#
# RE-APPENDABLE BY DESIGN: every run uses the exact same population
# definition (see the contract doc's "Population definition" section) —
# merged PRs / open issues as of THIS run's `gh` read, over a rolling
# 90-day window ending "now". A later report reads every line in
# .temperloop/baseline.jsonl and never calls `gh` itself.
#
# GITIGNORE SELF-MANAGEMENT: `.temperloop/baseline.jsonl` is generated,
# per-checkout runtime data — never meant to be committed. init.sh proposes
# `.temperloop/config` via a reviewable PR (proposal-pr.sh); this script has
# no such PR machinery available to it (it must also work standalone, e.g.
# invoked directly with no init.sh in the loop at all) and so is not
# proposing anything — it just writes `.temperloop/.gitignore` straight to
# disk, idempotently (never clobbers an existing entry, never duplicates
# the line on a repeat run).
#
# Usage:
#   baseline-snapshot.sh
#
#   No flags are read. Every knob below is an ENV VAR test seam only (never
#   set in production use, mirroring the INIT_GH_BIN / TRY_GH_BIN /
#   REWORK_SNAPSHOT_NOW conventions already in this codebase):
#     BASELINE_SNAPSHOT_GH_BIN      override the `gh` binary. Default: gh.
#     BASELINE_SNAPSHOT_NOW         override "now" (ISO-8601 UTC), for
#                                   deterministic generated_at/window-math
#                                   in tests. Default: real UTC now.
#     BASELINE_SNAPSHOT_TIMEOUT     per-gh-call watchdog, seconds.
#                                   Default: 20.
#     BASELINE_SNAPSHOT_LOOKBACK_DAYS  window size. Default: 90 (the
#                                   contracted value — do not change this
#                                   in production; the override exists so
#                                   tests aren't forced to fabricate 90
#                                   days of fixture history).
#     BASELINE_SNAPSHOT_PR_LIMIT    max merged PRs sampled per run.
#                                   Default: 500.
#     BASELINE_SNAPSHOT_ISSUE_LIMIT  max open issues sampled per run.
#                                   Default: 500.
#
# Exit codes: 0 = a record was appended (even a metrics.available:false
# one — that is a legible, successful run, not a failure). 1 = the record
# could not be written to disk (mkdir/append failure).
#
# Dependencies: bash (3.2+), git, jq (hard requirements). `gh` is optional
# — its absence (or being unauthenticated, or a network failure) only
# degrades the record to `metrics.available: false`; it never fails the
# run. No egress beyond `gh` itself.
#
# shellcheck shell=bash

set -uo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
usage: baseline-snapshot.sh
Appends one aggregate-only 90-day gh-history snapshot record to
.temperloop/baseline.jsonl in the current working directory's repo root.
Takes no arguments; see this file's header comment for env-var test seams.
EOF
    exit 0
    ;;
  "") ;;
  *)
    echo "baseline-snapshot.sh: unknown arg: $1 (this subcommand takes no arguments)" >&2
    exit 2
    ;;
esac

command -v git >/dev/null 2>&1 || { echo "baseline-snapshot.sh: git not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "baseline-snapshot.sh: jq not found on PATH" >&2; exit 1; }

# Test-double seam (mirrors init.sh's INIT_GH_BIN / try.sh's TRY_GH_BIN /
# funnel-drive.sh's FUNNEL_GH_BIN convention) — never overridden in
# production use.
: "${BASELINE_SNAPSHOT_GH_BIN:=gh}"
GH_BIN="$BASELINE_SNAPSHOT_GH_BIN"

gh_timeout="${BASELINE_SNAPSHOT_TIMEOUT:-20}"
lookback_days="${BASELINE_SNAPSHOT_LOOKBACK_DAYS:-90}"
pr_limit="${BASELINE_SNAPSHOT_PR_LIMIT:-500}"
issue_limit="${BASELINE_SNAPSHOT_ISSUE_LIMIT:-500}"

# run_with_timeout SECS cmd... — portable bounded-subprocess watchdog (no
# `timeout` binary assumed present; macOS dev machines don't ship one), the
# ONE shared shim every such call site sources rather than re-deriving
# (temperloop#256). Path resolved via pure bash parameter expansion (${x%/*}),
# never `dirname` — this script's own gh-absent degrade path is exercised
# under an intentionally minimal PATH (see
# bin/subcommands/tests/test_baseline_snapshot.sh's NOGHBIN allowlist) that
# does not include `dirname`, and this sourcing must not add a new external
# dependency to a script whose header promises only bash/git/jq.
_pt_here="${BASH_SOURCE[0]%/*}"; [ "$_pt_here" = "${BASH_SOURCE[0]}" ] && _pt_here="."
# shellcheck source=../../workflows/scripts/lib/portable-timeout.sh
source "$(cd "$_pt_here/../.." && pwd)/workflows/scripts/lib/portable-timeout.sh"
unset _pt_here

# ---------------------------------------------------------------------------
# Repo root + gh slug — local-only, no network (mirrors conventions-probe.sh's
# slug_from_remote; duplicated here rather than shelled out to the probe so
# this soft-seam script has zero runtime dependency on a sibling script's
# CLI staying byte-identical).
# ---------------------------------------------------------------------------
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root="$(pwd)"

_baseline_slug_from_remote() {
  local url="$1" slug=""
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) slug="" ;;
  esac
  slug="${slug%.git}"
  slug="${slug%/}"
  printf '%s' "$slug"
}

remote_url="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
gh_repo="$(_baseline_slug_from_remote "$remote_url")"

now_iso="${BASELINE_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# --- portable "N days before a YYYY-MM-DD" (GNU coreutils on CI/Linux, BSD
# date on macOS) — same shape as workflows/scripts/rework-snapshot.sh's
# _rs_date_sub_days. ---------------------------------------------------
if date --version >/dev/null 2>&1; then
  _baseline_date_sub_days() { date -u -d "$1 -${2} days" +%Y-%m-%d 2>/dev/null; }        # GNU
else
  _baseline_date_sub_days() { date -u -j -v-"${2}"d -f "%Y-%m-%d" "$1" +%Y-%m-%d 2>/dev/null; }  # BSD
fi
today="${now_iso:0:10}"
since_date="$(_baseline_date_sub_days "$today" "$lookback_days")"

# ---------------------------------------------------------------------------
# Determine metrics availability — degrade legibly, never fatally.
# ---------------------------------------------------------------------------
have_gh=0
command -v "$GH_BIN" >/dev/null 2>&1 && have_gh=1

metrics_available=0
metrics_reason=""

if [ -z "$gh_repo" ]; then
  metrics_reason="skipped — could not determine a GitHub owner/repo (no github.com origin remote)"
elif [ "$have_gh" -ne 1 ]; then
  metrics_reason="skipped — gh CLI not found on PATH"
elif [ -z "$since_date" ]; then
  metrics_reason="skipped — could not compute the lookback window start date"
elif ! run_with_timeout "$gh_timeout" "$GH_BIN" auth status >/dev/null 2>&1; then
  metrics_reason="skipped — gh not authenticated (or the auth check timed out)"
else
  metrics_available=1
fi

pr_json=""
issue_json=""
if [ "$metrics_available" -eq 1 ]; then
  if pr_json="$(run_with_timeout "$gh_timeout" "$GH_BIN" pr list \
      --repo "$gh_repo" --state merged --search "merged:>=${since_date}" \
      --json createdAt,mergedAt,reviews --limit "$pr_limit" 2>/dev/null)" \
      && issue_json="$(run_with_timeout "$gh_timeout" "$GH_BIN" issue list \
        --repo "$gh_repo" --state open \
        --json createdAt --limit "$issue_limit" 2>/dev/null)" \
      && [ -n "$pr_json" ] && [ -n "$issue_json" ]; then
    :
  else
    metrics_available=0
    metrics_reason="skipped — gh pr/issue list call failed or timed out after ${gh_timeout}s"
  fi
fi

# ---------------------------------------------------------------------------
# Assemble the record (schema 1 — see the contract doc for the full
# field-by-field reference).
# ---------------------------------------------------------------------------
if [ "$metrics_available" -eq 1 ]; then
  metrics_json="$(jq -n --argjson prs "$pr_json" --argjson issues "$issue_json" --arg now "$now_iso" '
    def median(sorted_arr):
      (sorted_arr | length) as $n
      | if $n == 0 then null
        elif ($n % 2) == 1 then sorted_arr[($n - 1) / 2 | floor]
        else ((sorted_arr[($n / 2 | floor) - 1] + sorted_arr[$n / 2 | floor]) / 2)
        end;
    def round2: if . == null then null else ((. * 100 | round) / 100) end;

    ($prs | map({
      ttm_hours: (((.mergedAt | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 3600),
      first_review_hours: (
        (((.reviews // []) | map(.submittedAt) | map(select(. != null)) | sort)) as $subs
        | if ($subs | length) > 0
          then (($subs[0] | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 3600
          else null end
      )
    })) as $pr_stats
    | ($pr_stats | map(.ttm_hours) | sort) as $ttm_sorted
    | ($pr_stats | map(.first_review_hours) | map(select(. != null)) | sort) as $review_sorted
    | ($issues | map((($now | fromdateiso8601) - (.createdAt | fromdateiso8601)) / 86400) | sort) as $issue_ages_sorted
    | {
        pr_throughput: { merged_count: ($prs | length) },
        time_to_merge_hours: { median: (median($ttm_sorted) | round2), sample_size: ($ttm_sorted | length) },
        review_latency_hours: { median: (median($review_sorted) | round2), sample_size: ($review_sorted | length) },
        issue_backlog: { open_count: ($issues | length), median_age_days: (median($issue_ages_sorted) | round2) }
      }
  ' 2>/dev/null)"
  if [ -z "$metrics_json" ]; then
    metrics_available=0
    metrics_reason="skipped — metrics computation failed (unexpected gh output shape)"
  fi
fi

if [ "$metrics_available" -eq 1 ]; then
  record="$(jq -n \
    --argjson schema 1 \
    --arg generated_at "$now_iso" \
    --argjson lookback_days "$lookback_days" \
    --arg gh_repo "$gh_repo" \
    --argjson metrics "$metrics_json" \
    '{
      schema: $schema,
      generated_at: $generated_at,
      lookback_days: $lookback_days,
      repo: { gh_repo: $gh_repo },
      metrics: ({ available: true, reason: null } + $metrics)
    }')"
else
  record="$(jq -n \
    --argjson schema 1 \
    --arg generated_at "$now_iso" \
    --argjson lookback_days "$lookback_days" \
    --arg gh_repo "${gh_repo:-}" \
    --arg reason "$metrics_reason" \
    '{
      schema: $schema,
      generated_at: $generated_at,
      lookback_days: $lookback_days,
      repo: { gh_repo: (if $gh_repo == "" then null else $gh_repo end) },
      metrics: {
        available: false,
        reason: $reason,
        pr_throughput: null,
        time_to_merge_hours: null,
        review_latency_hours: null,
        issue_backlog: null
      }
    }')"
fi

# ---------------------------------------------------------------------------
# Write: .temperloop/baseline.jsonl (append) + .temperloop/.gitignore
# (self-managed, idempotent — never committed).
#
# temperloop#165 rename window: an EXISTING legacy .foundation/baseline.jsonl
# keeps accreting IN PLACE through the window — the baseline is one
# append-only before/after history, and splitting it across two dirs
# mid-window would silently truncate every later report's "before" anchor
# (report.sh reads exactly one file). A repo with no legacy baseline writes
# to .temperloop/ from the start. The legacy continue-in-place arm is
# removed in v0.16.0 (move the file: git has never tracked it — plain
# mkdir -p .temperloop && mv .foundation/baseline.jsonl .temperloop/).
# ---------------------------------------------------------------------------
foundation_dir="$repo_root/.temperloop"
if [ ! -f "$foundation_dir/baseline.jsonl" ] && [ -f "$repo_root/.foundation/baseline.jsonl" ]; then
  if [ "${TEMPERLOOP_LEGACY_WINDOW_CLOSED:-0}" = "1" ]; then # knob:exempt — test/simulation-only seam
    echo "baseline-snapshot.sh: ERROR — a legacy .foundation/baseline.jsonl exists, but appending to the legacy dir was removed in v0.16.0 (renamed .temperloop/ in v0.14.0). Move it: mkdir -p .temperloop && mv .foundation/baseline.jsonl .temperloop/ — then re-run." >&2
    exit 1
  fi
  foundation_dir="$repo_root/.foundation"
  echo "baseline-snapshot: NOTE — appending to legacy ${foundation_dir#"$repo_root"/}/baseline.jsonl (dir renamed .temperloop/ in v0.14.0; legacy append removed in v0.16.0 — move the file)." >&2
fi
if ! mkdir -p "$foundation_dir" 2>/dev/null; then
  echo "baseline-snapshot.sh: could not create $foundation_dir" >&2
  exit 1
fi

gitignore_path="$foundation_dir/.gitignore"
if [ -f "$gitignore_path" ]; then
  if ! grep -Fxq "baseline.jsonl" "$gitignore_path" 2>/dev/null; then
    if ! printf '%s\n' "baseline.jsonl" >> "$gitignore_path"; then
      echo "baseline-snapshot.sh: could not update $gitignore_path" >&2
      exit 1
    fi
  fi
else
  if ! printf '%s\n' "baseline.jsonl" > "$gitignore_path"; then
    echo "baseline-snapshot.sh: could not create $gitignore_path" >&2
    exit 1
  fi
fi

baseline_file="$foundation_dir/baseline.jsonl"
if ! printf '%s\n' "$(jq -c '.' <<<"$record")" >> "$baseline_file"; then
  echo "baseline-snapshot.sh: could not append to $baseline_file" >&2
  exit 1
fi

echo "baseline-snapshot: appended 1 record to ${baseline_file#"$repo_root"/} (metrics available: $([ "$metrics_available" -eq 1 ] && echo true || echo false))"
exit 0
