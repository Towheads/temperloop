#!/usr/bin/env bash
#
# resolve-correspondence.sh — the MECHANICAL half of `/promote`'s issue
# correspondence (temperloop#1235, epic #1117 Produces 5 continued): resolve
# a testbed issue back to the ORIGINAL issue it was copied from, by EXACT
# lookup on the machine-readable provenance line `mirror-from-repo` stamps
# into every issue it creates
# (workflows/scripts/testbed/source.sh,
# `_testbed_provider_mirror_from_repo_produce_issues`) — never by title
# matching, ordering, or any other inference.
#
# ── Why this exists as a script at all (ADR 0023) ──────────────────────────
# Same split as push-testbed-branch.sh: `/promote`
# (claude/commands/promote.md) is the judgment half — deciding what the
# operator should do with a correspondence result — and this script is the
# mechanism, because an LLM-executed prose lookup gets paraphrased away, and
# the failure mode of a paraphrased lookup is a SILENTLY absent or silently
# WRONG record, not a caught error. A test can assert what this script
# resolves; no test can assert against a prose step in a markdown spec.
#
# ── The provenance line this parses (fixed by the writer, not invented here) ─
# `_testbed_provider_mirror_from_repo_produce_issues` writes, via
# `printf '%s\n\n---\n%s\n' "$body" "$provenance"` with
# `provenance="copied from ${source_slug}#${num}"`:
#
#   <original body>
#
#   ---
#   copied from <owner>/<repo>#<N>
#
# i.e. the provenance line is always the body's own LAST line, immediately
# preceded by a line that is exactly `---`. This script's parser matches
# THAT exact shape — it does not invent a second format, and it does not
# infer from anything the writer didn't itself stamp.
#
# ── Exact lookup, never inference: four distinct outcomes ──────────────────
# Classification is purely structural (no fetch of the original issue, no
# content comparison against it) and yields exactly one of:
#
#   resolved    the body's last non-blank line matches
#               `copied from <owner>/<repo>#<N>` exactly, AND the line
#               immediately before it is `---` — the fixed shape the writer
#               always produces.
#   absent      no line anywhere in the body starts with "copied from ".
#   malformed   a line starting with "copied from " exists, but the
#               remainder does not parse as `<owner>/<repo>#<N>` (missing
#               repo, non-numeric N, wrong case, trailing junk, ...).
#   edited      a line matching the exact `<owner>/<repo>#<N>` format
#               exists, but NOT in the fixed trailing position the writer
#               always produces — either it is not the body's last line
#               (content was appended below the stamp) or the line
#               immediately before it is not `---` (the separator was
#               altered or removed). Either shape means the body was
#               touched after `mirror-from-repo` stamped it, so trusting the
#               line's content alone would be guessing, not looking up.
#
# Only `resolved` exits 0. The other three REFUSE — never guess — with a
# distinct exit code and a message naming which of the three it is, so a
# caller (or `/promote`) can branch on the outcome instead of parsing prose.
#
# Usage:
#   resolve-correspondence.sh resolve --testbed-repo OWNER/NAME --issue N
#                                      [--body-file PATH]
#   resolve-correspondence.sh report  --testbed-repo OWNER/NAME
#                                      [--state open|closed|all]
#
#   --testbed-repo OWNER/NAME  REQUIRED. The testbed repository whose issues
#                              are being resolved — never inferred from cwd
#                              (same discipline as push-testbed-branch.sh's
#                              --to).
#   --issue N                  REQUIRED for `resolve`. The testbed issue
#                              number to resolve back to its original.
#   --body-file PATH           `resolve` only: read the issue body from this
#                              file instead of calling `gh issue view` — the
#                              seam this script's own tests drive the
#                              classification logic through, and usable by a
#                              caller that already has the body in hand.
#   --state STATE               `report` only: open|closed|all
#                              (default: open) — passed straight to
#                              `gh issue list --state`.
#
# Exit codes (resolve):
#   0  resolved   — stdout: one tab-separated `RESOLVED` line.
#   2  absent     — stderr: one tab-separated `ABSENT` line.
#   3  malformed  — stderr: one tab-separated `MALFORMED` line.
#   4  edited     — stderr: one tab-separated `EDITED` line.
#   1  usage / gh error — stderr: "resolve-correspondence.sh: <message>".
#
# `report` never exits non-zero because of an individual issue's
# classification — every issue in scope gets exactly one row on stdout
# (RESOLVED/ABSENT/MALFORMED/EDITED, tab-separated), so a partially-resolved
# repo still gets a complete report. `report` itself exits 1 if ANY issue in
# scope failed to resolve (a summary a caller can gate on), 0 only when
# every issue in scope resolved.
#
# Dependencies: bash 3.2+, gh (for `resolve` without --body-file, and always
# for `report`), jq (for `report`'s issue-list parse). No network is
# required to run `resolve --body-file` directly.

set -euo pipefail

PROG="resolve-correspondence.sh"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^# Dependencies:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# <value> -> 0 when it is exactly "<owner>/<name>".
is_owner_name() {
  case "$1" in
    */*/*) return 1 ;;
    */*) [ -n "${1%%/*}" ] && [ -n "${1#*/}" ] ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# classify_body <body> — the pure classification core, no I/O and no gh.
# This is what the test suite drives directly, and what `resolve` and
# `report` both call underneath their gh plumbing. Sets globals:
#   CLASS         resolved | absent | malformed | edited
#   CLASS_OWNER   (resolved only) the source owner
#   CLASS_REPO    (resolved only) the source repo name
#   CLASS_NUM     (resolved only) the source issue number
#   CLASS_LINE    (malformed/edited/resolved) the matched/offending line
# ---------------------------------------------------------------------------
CLASS=""; CLASS_OWNER=""; CLASS_REPO=""; CLASS_NUM=""; CLASS_LINE=""

classify_body() {
  local body="$1"
  local -a lines=()
  local line
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$body"

  local n="${#lines[@]}"
  # Trim trailing blank lines. This absorbs the herestring's own appended
  # newline (which, on top of the body's own trailing "\n", can add one
  # synthetic empty final array element) down to the body's real last
  # content line — the ONLY thing "last line" should mean here.
  while [ "$n" -gt 0 ] && [ -z "${lines[$((n - 1))]}" ]; do
    n=$((n - 1))
  done

  CLASS=""; CLASS_OWNER=""; CLASS_REPO=""; CLASS_NUM=""; CLASS_LINE=""

  if [ "$n" -eq 0 ]; then
    CLASS="absent"
    return 0
  fi

  local last="${lines[$((n - 1))]}"
  local prev=""
  [ "$n" -ge 2 ] && prev="${lines[$((n - 2))]}"

  # Any "copied from " line anywhere in scope, for the absent-vs-other split.
  # The exact-prefix match is deliberate: only the literal prefix the writer
  # emits counts as a candidate at all — a near-miss casing or phrasing is
  # not a recognized attempt at the stamp, so it falls through to "absent"
  # rather than being upgraded to "malformed".
  local any_candidate=0 i candidate="" is_last=0
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${lines[$i]}" in
      "copied from "*)
        any_candidate=1
        candidate="${lines[$i]}"
        [ "$i" -eq $((n - 1)) ] && is_last=1
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$any_candidate" -eq 0 ]; then
    CLASS="absent"
    return 0
  fi

  # Prefer the body's actual last line when IT is itself a candidate (the
  # writer's own shape); otherwise fall back to the last candidate seen
  # anywhere, purely to name something concrete in the refusal message.
  local subject="$candidate"
  [ "$is_last" -eq 1 ] && subject="$last"

  local re='^copied from ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$'
  if [[ "$subject" =~ $re ]]; then
    if [ "$is_last" -eq 1 ] && [ "$prev" = "---" ]; then
      CLASS="resolved"
      CLASS_OWNER="${BASH_REMATCH[1]}"
      CLASS_REPO="${BASH_REMATCH[2]}"
      CLASS_NUM="${BASH_REMATCH[3]}"
    else
      CLASS="edited"
    fi
  else
    CLASS="malformed"
  fi
  CLASS_LINE="$subject"
}

# ---------------------------------------------------------------------------
# resolve — one testbed issue.
# ---------------------------------------------------------------------------
resolve_cmd() {
  local testbed_repo="" issue="" body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --testbed-repo) testbed_repo="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --issue) issue="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --body-file) body_file="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1 (run --help)" ;;
    esac
  done

  [ -n "$testbed_repo" ] || die "--testbed-repo <owner>/<name> is required"
  is_owner_name "$testbed_repo" || die "--testbed-repo must be exactly \"<owner>/<name>\", got: $testbed_repo"
  [ -n "$issue" ] || die "--issue <N> is required"
  case "$issue" in '' | *[!0-9]*) die "--issue must be a positive integer, got: $issue" ;; esac

  local body
  if [ -n "$body_file" ]; then
    body="$(cat "$body_file" 2>&1)" || die "could not read --body-file $body_file: $body"
  else
    command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
    body="$(gh issue view "$issue" --repo "$testbed_repo" --json body -q .body 2>&1)" \
      || die "gh issue view $issue --repo $testbed_repo failed: $body"
  fi

  classify_body "$body"
  emit_resolve_result "$testbed_repo" "$issue"
}

emit_resolve_result() {
  local testbed_repo="$1" issue="$2"
  case "$CLASS" in
    resolved)
      printf 'RESOLVED\t%s#%s\t%s/%s#%s\n' "$testbed_repo" "$issue" "$CLASS_OWNER" "$CLASS_REPO" "$CLASS_NUM"
      exit 0
      ;;
    absent)
      printf 'ABSENT\t%s#%s\trefusing — no "copied from <owner>/<repo>#<N>" provenance line found in the issue body; cannot resolve by lookup\n' \
        "$testbed_repo" "$issue" >&2
      exit 2
      ;;
    malformed)
      printf 'MALFORMED\t%s#%s\trefusing — a "copied from" line exists but does not match the exact <owner>/<repo>#<N> format mirror-from-repo writes: "%s"\n' \
        "$testbed_repo" "$issue" "$CLASS_LINE" >&2
      exit 3
      ;;
    edited)
      printf 'EDITED\t%s#%s\trefusing — a well-formed provenance line exists ("%s") but not in the fixed trailing position mirror-from-repo writes it in (last line, immediately preceded by "---"); the body was edited after copying, so resolving from it would be guessing\n' \
        "$testbed_repo" "$issue" "$CLASS_LINE" >&2
      exit 4
      ;;
  esac
}

# ---------------------------------------------------------------------------
# report — every issue in scope on the testbed repo, one row each.
# ---------------------------------------------------------------------------
report_cmd() {
  local testbed_repo="" state="open"
  while [ $# -gt 0 ]; do
    case "$1" in
      --testbed-repo) testbed_repo="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --state) state="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1 (run --help)" ;;
    esac
  done

  [ -n "$testbed_repo" ] || die "--testbed-repo <owner>/<name> is required"
  is_owner_name "$testbed_repo" || die "--testbed-repo must be exactly \"<owner>/<name>\", got: $testbed_repo"
  case "$state" in open | closed | all) ;; *) die "--state must be one of open|closed|all, got: $state" ;; esac

  command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
  command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

  local issues_json
  issues_json="$(gh issue list --repo "$testbed_repo" --state "$state" --json number,body 2>&1)" \
    || die "gh issue list --repo $testbed_repo --state $state failed: $issues_json"

  local n i unresolved=0
  n="$(printf '%s' "$issues_json" | jq 'length')"
  i=0
  while [ "$i" -lt "$n" ]; do
    local entry num body
    entry="$(printf '%s' "$issues_json" | jq -c ".[$i]")"
    num="$(printf '%s' "$entry" | jq -r '.number')"
    body="$(printf '%s' "$entry" | jq -r '.body // ""')"
    classify_body "$body"
    case "$CLASS" in
      resolved)
        printf 'RESOLVED\t%s#%s\t%s/%s#%s\n' "$testbed_repo" "$num" "$CLASS_OWNER" "$CLASS_REPO" "$CLASS_NUM"
        ;;
      absent)
        printf 'ABSENT\t%s#%s\tno "copied from <owner>/<repo>#<N>" provenance line found\n' "$testbed_repo" "$num"
        unresolved=$((unresolved + 1))
        ;;
      malformed)
        printf 'MALFORMED\t%s#%s\t%s\n' "$testbed_repo" "$num" "$CLASS_LINE"
        unresolved=$((unresolved + 1))
        ;;
      edited)
        printf 'EDITED\t%s#%s\t%s\n' "$testbed_repo" "$num" "$CLASS_LINE"
        unresolved=$((unresolved + 1))
        ;;
    esac
    i=$((i + 1))
  done

  [ "$unresolved" -eq 0 ]
}

# ---------------------------------------------------------------------------
main() {
  [ $# -gt 0 ] || { usage; exit 2; }
  case "$1" in
    resolve) shift; resolve_cmd "$@" ;;
    report) shift; report_cmd "$@" ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown subcommand: $1 (expected 'resolve' or 'report')" ;;
  esac
}

main "$@"
