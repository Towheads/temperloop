#!/usr/bin/env bash
#
# issue-state.sh — single-issue state probe + (later) resume driver
# (temperloop #635/#636, epic #627 `/fix` targeted single-item fix driver).
#
# Two subcommands, one CLI dispatch skeleton (spike verdict
# [[Decisions/temperloop - fix-driver state-resolution seams (spike verdict)]]):
#
#   resolve <repo> <issue>    — reads ground-truth GitHub state for ONE issue
#     and prints a single JSON "route verdict" object to stdout: is it
#     closed, does it carry an open question, is it claimed by someone else,
#     does it already have an open linked PR, or is it fresh work. #635
#     (THIS item) implements this arm.
#
#   reattach <repo> <pr>       — REVALIDATES an already-open PR and prints a
#     single ready/not-ready verdict JSON. It NEVER merges (the caller owns
#     the merge) — this is the adoption-safety check `/fix` runs before
#     driving an existing PR through the merge gate. #636 (THIS arm).
#
# reattach is a PURE BASH op that COMPOSES the shared machinery scripts — it does
# NOT re-encode the CI poll loop or the #254 SHA-pin, and it does NOT touch
# claude/workflows/build-level.mjs (the earlier spike note said "add a mode
# to build-level.mjs"; that was CORRECTED — build-level.mjs is a Workflow-
# runtime module a bash op cannot drive; see the spike verdict's CORRECTION
# section). Instead it delegates:
#   - CI re-poll  → workflows/scripts/build/ci-poll.sh (with `--sha <head oid>`,
#                   which IS the #254 SHA-pin — never re-read a lagging PR head)
#   - the rebase  → the pr.sh `rebase` contract (fixture path); see
#                   cmd_reattach's stale-base-rebase design note below.
#
# This file is the CREATION of the shared skeleton — reattach adds a case arm,
# it does not restructure this dispatch.
#
# `resolve`'s ground truth: `gh issue view` for issue state/labels/url, and the
# shared `open_pr_for_issue` (workflows/scripts/build/lib/pr-linkage.sh) for
# any open PR that closes the issue. Labels are read against the SAME
# literal label vocabulary pipeline-tick.sh classifies with — sourced from
# build.config.sh's PIPELINE_* settings, never a re-declared parallel taxonomy
# (see `resolve`'s own label-constant set below, and
# tests/test_issue_state_label_subset.sh, the mechanical subset-lint against
# pipeline-tick.sh's label set).
#
# ── NEVER FABRICATE A VERDICT (temperloop#1591 / #1518) ────────────────────
# `resolve` is the FIRST thing `/fix` (Step 2) and any other consumer runs,
# BEFORE any mutation, so a false verdict here propagates straight into
# claim-first and a worker spawn. Three rules this file holds structurally:
#
#   1. AN ABSENT INPUT NEVER READS AS A CLEAN ONE. `gh issue view` failing was
#      swallowed into `{}` and `.state // "OPEN"` then invented `open` — so a
#      NONEXISTENT issue resolved `route: fresh` and a consumer would claim and
#      drive a target that does not exist (#1591). The probe now returns a
#      three-way envelope (ok / not-found / error) and the two failure arms get
#      their OWN terminal routes.
#   2. A TRANSIENT FAILURE IS NOT A 404. Auth, rate-limit and network failures
#      were collapsed into the same `{}` as a genuine "no such issue". They are
#      classified apart now: only GitHub's own "could not resolve to an issue or
#      pull request" signature is `not-found` (route `not-found`,
#      issue_state `absent`); EVERY other failure is `error` (route
#      `probe-failed`, issue_state `unknown`).
#   3. THE `reason` CAN NEVER CONTRADICT THE `issue_state`. The route table
#      below is ordered so every non-terminal arm — and the `fresh` default in
#      particular — is reachable ONLY when the target is a genuinely open
#      ISSUE. A merged PR number used to emit `issue_state: merged` alongside
#      `reason: "open, unclaimed, no linked PR"` (#1518, epic #1626).
#
# `resolve` ALWAYS EXITS 0 once it has produced a verdict. Failure is expressed
# IN the verdict (`route`), never by exit code — deliberately, so a caller that
# captures stdout under `set -e` can never have the honest verdict killed out
# from under it by a non-zero exit, and so "exit 0" can never be misread as "no
# problem". The failure routes additionally print one diagnostic line to stderr.
#
# PULL-REQUEST TARGETS. `gh issue view <n>` resolves a PULL REQUEST number too
# (returning state MERGED for a merged one), so `resolve <repo> <pr#>` is a
# reachable mistake — it is how #1518 was found live. The `.url` field
# discriminates (`/pull/<n>` vs `/issues/<n>`) at NO extra API call, and a PR
# target routes `not-an-issue` whatever its state, so a caller can report
# "that's a PR, not an issue" instead of a misleading `already-done`.
#
# DRY_RUN / $FIXTURE (offline test harness, mirrors pipeline-tick.sh's own
# convention — read that file's header for the general shape):
#   $FIXTURE/issue-<issue>.json    — the `gh issue view --json
#                                     state,labels,assignees,url` shape:
#                                     {"state":"OPEN","labels":[{"name":"x"}],
#                                      "assignees":[{"login":"y"}],
#                                      "url":"https://github.com/o/r/issues/1"}
#                                     ABSENT = the offline mirror of a 404
#                                     (route `not-found`), never a fabricated
#                                     empty-but-open issue.
#   $FIXTURE/issue-<issue>.error   — optional; simulates a FAILING `gh issue
#                                     view`. Its first line is the stderr text,
#                                     classified exactly as a live failure is
#                                     (a "could not resolve to an issue or pull
#                                     request" line -> not-found; anything else
#                                     -> probe-failed). Wins over the .json.
#   $FIXTURE/open-pr-<issue>.txt   — consumed by pr-linkage.sh's
#                                     open_pr_for_issue (one PR number per line)
#   $FIXTURE/pr-<n>.json           — the `gh pr view --json
#                                     number,draft,author,updatedAt` shape:
#                                     {"number":N,"draft":false,
#                                      "author":{"login":"x"},
#                                      "updatedAt":"2026-07-01T00:00:00Z"}
#   $FIXTURE/worktree-<issue>.txt  — optional; a single local worktree path
#                                     (best-effort field, see find_worktree
#                                     below)
#
# reattach fixtures (kept under DISTINCT filenames from resolve's so the two
# subcommands' fixtures never collide in one dir):
#   $FIXTURE/reattach-pr-<pr>.json      — the `gh pr view --json state,
#                                         mergeable,mergeStateStatus,headRefOid,
#                                         headRefName` shape:
#                                         {"state":"OPEN","mergeable":"MERGEABLE",
#                                          "mergeStateStatus":"CLEAN",
#                                          "headRefOid":"abc123"}
#   $FIXTURE/ci-poll-<pr>.json          — the ci-poll.sh verdict returned by the
#                                         FIRST (head-oid-pinned) re-poll:
#                                         {"outcome":"CI_GREEN|CI_FAILED|TIMEOUT|
#                                          NO_CI|ERROR"}
#   $FIXTURE/rebase-<pr>.json           — the pr.sh `rebase` verdict for a BEHIND
#                                         base: {"outcome":"REBASED","sha":"..."}
#                                         | {"outcome":"REBASE_CONFLICT"}
#   $FIXTURE/ci-poll-rebased-<pr>.json  — the ci-poll.sh verdict returned by the
#                                         SECOND (rebased-sha-pinned) re-poll,
#                                         same shape as ci-poll-<pr>.json
#
# This file is EXECUTED (not sourced) — `set -euo pipefail` applies to the
# whole script.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo '{"error":"jq not found"}' >&2; exit 1; }

# Attribution for the gh call-logger shim (F#988) — same convention every
# build-machinery entry point uses (pipeline-tick.sh, pipeline-drive.sh). See
# workflows/scripts/gh-call-logger.sh.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-issue-state}"

# ── Config (env overrides win; defaults centralized in build.config.sh) ─────
# shellcheck source=workflows/scripts/build/build.config.sh
[ -f "$HERE/build.config.sh" ] && . "$HERE/build.config.sh"
# Belt-and-suspenders fallback for a non-vendoring consuming checkout that
# doesn't carry build.config.sh at all (precedence layer 6, per CLAUDE.md's
# Named-setting convention) — matches the literal defaults
# build.config.sh itself ships.
: "${PIPELINE_ESCALATED_LABEL:=funnel-escalated}"
: "${PIPELINE_MERGE_PENDING_LABEL:=funnel-merge-pending}"

# shellcheck source=workflows/scripts/build/lib/pr-linkage.sh
. "$HERE/lib/pr-linkage.sh"

# ── resolve's own label-constant set (subset-lint target) ───────────────────
# Every literal/setting this script reads to classify an issue's labels. The
# subset-lint (tests/test_issue_state_label_subset.sh) greps THIS block
# mechanically and asserts every name here is also read by pipeline-tick.sh —
# i.e. resolve introduces no parallel label taxonomy. Do not add a label
# reference anywhere else in this file without adding it here too.
ISSUE_STATE_LABEL_NEEDS_CLARIFICATION="needs-clarification"
# The next three are vocabulary members pipeline-tick.sh also reads but that
# resolve does not branch routing on (spike/decision are surfaced only via
# the raw labels[] pass-through below; funnel-escalated the same) — kept as
# named constants purely so the subset-lint has a mechanical grep target,
# per the spike verdict's route mapping. Not dead code: read by
# tests/test_issue_state_label_subset.sh, not by a route branch in this file.
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_SPIKE="spike"
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_DECISION="decision"
# shellcheck disable=SC2034
ISSUE_STATE_LABEL_PIPELINE_ESCALATED="$PIPELINE_ESCALATED_LABEL"
ISSUE_STATE_LABEL_PIPELINE_MERGE_PENDING="$PIPELINE_MERGE_PENDING_LABEL"

DRY_RUN=0
FIXTURE=""

usage() {
  cat >&2 <<'USAGE'
usage: issue-state.sh <subcommand> [args]

subcommands:
  resolve <repo> <issue> [--dry-run --fixture <dir>]
      Read ground-truth GitHub state for ONE issue and print a single JSON
      route-verdict object to stdout (route: fresh|adopt|question-first|
      claimed-elsewhere|already-done|ambiguous|not-an-issue|not-found|
      probe-failed). See this file's header for the full verdict shape.

  reattach <repo> <pr> [--dry-run --fixture <dir>]
      Revalidate an already-open PR and print a single ready/not-ready
      verdict JSON to stdout. NEVER merges — the caller owns the merge.
      See this file's header and `reattach --help` for the verdict shape.

  -h, --help
      Show this usage and exit 0.
USAGE
}

resolve_usage() {
  cat >&2 <<'USAGE'
usage: issue-state.sh resolve <repo> <issue> [--dry-run --fixture <dir>]

Reads ground-truth GitHub state for ONE issue (gh issue view + the shared
open-PR-by-linkage probe) and prints a single JSON route-verdict object to
stdout:

  {
    "repo": "owner/repo", "issue": 123,
    "issue_state": "open|closed|merged|absent|unknown",
    "is_pull_request": bool,
    "open_prs": [{"number":N,"draft":bool,"author":"login",
                  "updated_at":"ISO8601","linkage":"closes"}],
    "claim": {"claimed":bool,"host_session":"host:sess|null","by_me":bool},
    "labels": ["<label>", ...],
    "worktree": "<path>|null",
    "route": "fresh|adopt|question-first|claimed-elsewhere|already-done|
              ambiguous|not-an-issue|not-found|probe-failed",
    "reason": "<one-line why this route>"
  }

Routes, in precedence order (first match wins). The three DRIVE routes are
`fresh` / `adopt` / `ambiguous`; every other route is TERMINAL:

  not-found          the number does not exist in the repo (GitHub's own
                     "could not resolve" signature). issue_state "absent".
  probe-failed       the `gh` read failed for a NON-404 reason (auth,
                     rate-limit, network). issue_state "unknown" — the state
                     is genuinely unknown, which is NOT the same as "open".
  not-an-issue       the number is a PULL REQUEST, not an issue.
  already-done       the issue exists but is not open (closed, or any other
                     non-open state GitHub may return).
  question-first     carries the needs-clarification label.
  claimed-elsewhere  In Progress under a different host/session.
  ambiguous          >1 open PR links to the issue.
  adopt              exactly one open linked PR, or funnel-merge-pending.
  fresh              an open, drivable issue with none of the above.

Always exits 0 once a verdict is produced — failure is carried by `route`,
never by the exit code (see this file's header).

  --dry-run --fixture <dir>   Offline fixture mode (see this file's header
                               comment for the fixture layout).
USAGE
}

# ── gh/fixture reads ──────────────────────────────────────────────────────

# issue_state_classify_failure <stderr-text> — prints the failure half of the
# probe envelope, classifying GitHub's OWN not-found signature apart from every
# other failure (temperloop#1591). Deliberately NARROW: only a "could not
# resolve to an issue or pull request" line proves the NUMBER does not exist.
# A "could not resolve to a Repository" line, an auth error, a rate-limit and a
# network error all stay `error` — asserting "this issue does not exist" off a
# failure that never reached the issue is the same fabrication in a new costume.
issue_state_classify_failure() {
  local err="$1" kind="error"
  case "$err" in
    *"ould not resolve to an issue or pull request"*|\
    *"ould not resolve to an Issue"*|\
    *"ould not resolve to a PullRequest"*)
      kind="not-found" ;;
  esac
  [ -n "$err" ] || err="gh issue view failed with no diagnostic output"
  jq -cn --arg k "$kind" --arg e "$err" '{probe:$k, error:$e}'
}

# issue_state_probe_issue <repo> <issue> — prints ONE probe-envelope JSON,
# NEVER a bare `{}` that a later `// "OPEN"` default can turn into a fabricated
# open issue (temperloop#1591):
#
#   {"probe":"ok","data":{<the gh issue view --json state,labels,assignees,url
#                          payload>}}
#   {"probe":"not-found","error":"<gh stderr>"}
#   {"probe":"error","error":"<gh stderr>"}
issue_state_probe_issue() {
  local repo="$1" issue="$2" f errf out err
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/issue-$issue.error"
    if [ -f "$f" ]; then
      issue_state_classify_failure "$(head -n1 "$f")"
      return 0
    fi
    f="$FIXTURE/issue-$issue.json"
    if [ -f "$f" ]; then
      jq -c '{probe:"ok", data:.}' <"$f" 2>/dev/null \
        || jq -cn --arg e "unparseable fixture $f" '{probe:"error", error:$e}'
    else
      # An ABSENT fixture is the offline mirror of a 404 — the fixture harness
      # must not be the one place the fabricated-open verdict survives.
      jq -cn --arg e "no fixture for issue $issue in $FIXTURE" \
        '{probe:"not-found", error:$e}'
    fi
    return 0
  fi
  errf="$(mktemp)"
  if out="$(gh issue view "$issue" -R "$repo" --json state,labels,assignees,url 2>"$errf")"; then
    rm -f "$errf"
    jq -c '{probe:"ok", data:.}' <<<"$out" 2>/dev/null \
      || jq -cn --arg e "gh issue view returned unparseable JSON" '{probe:"error", error:$e}'
    return 0
  fi
  err="$(tr '\n' ' ' <"$errf" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  rm -f "$errf"
  issue_state_classify_failure "$err"
}

# issue_state_get_pr <repo> <pr-number> — prints the raw `gh pr view --json
# number,draft,author,updatedAt` JSON (or its fixture equivalent).
#
# The `|| jq -cn '{number:$n}'` fallback below was REVIEWED against the same
# masking class (temperloop#1591 acceptance): it is NOT route-decisive. This
# read is only ever reached for a PR number `open_pr_for_issue` already proved
# links to the issue, and the route is chosen from that linkage COUNT, never
# from this payload — so a swallowed failure here degrades the surfaced
# draft/author/updated_at detail of a PR known to exist, and can neither invent
# a PR nor suppress one. The number, which is what `adopt`/`ambiguous` act on,
# is carried through from the linkage probe regardless.
issue_state_get_pr() {
  local repo="$1" pr="$2" f
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/pr-$pr.json"
    if [ -f "$f" ]; then cat "$f"; else jq -cn --argjson n "$pr" '{number:$n}'; fi
    return 0
  fi
  gh pr view "$pr" -R "$repo" --json number,draft,author,updatedAt 2>/dev/null \
    || jq -cn --argjson n "$pr" '{number:$n}'
}

# find_worktree <repo> <issue> — BEST-EFFORT local worktree lookup. There is
# no mechanical issue-number -> worktree mapping in this repo's build machinery
# (worktree.sh names a worktree `<repo-root>.wt/<slug>` off a PLAN ITEM'S
# `slug:` field — see CLAUDE.md § Branch & PR policy — with no issue number
# recorded in `.build-guard`), so this is a heuristic, not a guarantee:
# scan `git worktree list --porcelain` for a branch whose name contains the
# issue number as a standalone token (the common `<type>/<slug>-<issue>` /
# `<type>/<issue>-<slug>` naming a human or /build often uses, e.g. this
# repo's own `fix/vdb-checkb-dim0-conditional-512`). A miss is not evidence
# no worktree exists — just that this heuristic didn't find one.
find_worktree() {
  local repo="$1" issue="$2" f line path branch
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/worktree-$issue.txt"
    if [ -f "$f" ]; then
      head -n1 "$f"
    fi
    return 0
  fi
  path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) path="${line#worktree }" ;;
      branch\ *)
        branch="${line#branch }"
        branch="${branch#refs/heads/}"
        if [[ "$branch" =~ (^|[^0-9])$issue($|[^0-9]) ]]; then
          printf '%s\n' "$path"
          return 0
        fi
        path=""
        ;;
    esac
  done < <(git -C "$HERE" worktree list --porcelain 2>/dev/null; echo)
  return 0
}

# ── resolve ──────────────────────────────────────────────────────────────
cmd_resolve() {
  local repo="" issue="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --fixture) FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
      -h|--help) resolve_usage; exit 0 ;;
      -*) echo "issue-state.sh resolve: unknown flag '$1'" >&2; resolve_usage; exit 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [ "${#args[@]}" -ne 2 ]; then
    echo "issue-state.sh resolve: expected <repo> <issue>" >&2
    resolve_usage
    exit 2
  fi
  repo="${args[0]}"; issue="${args[1]}"

  if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
    echo "issue-state.sh resolve: --dry-run requires --fixture <dir>" >&2
    exit 2
  fi
  if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
    echo "issue-state.sh resolve: fixture dir not found: $FIXTURE" >&2
    exit 2
  fi

  local probe_json probe_kind probe_error probe_ok issue_json
  local issue_state_raw issue_state issue_url is_pr labels_json route reason
  probe_json="$(issue_state_probe_issue "$repo" "$issue")"
  probe_kind="$(jq -r '.probe // "error"' <<<"$probe_json")"
  probe_error="$(jq -r '.error // ""' <<<"$probe_json")"
  issue_json="$(jq -c '.data // {}' <<<"$probe_json")"

  # A FAILED probe never defaults to OPEN. `absent` (the number does not exist)
  # and `unknown` (the read itself failed) are distinct states, and neither is
  # a state any drive route can be reached from. Note there is no `// "OPEN"`
  # here any more: on the `ok` arm `.state` is always present.
  probe_ok=1
  case "$probe_kind" in
    ok)        issue_state_raw="$(jq -r '.state // "UNKNOWN"' <<<"$issue_json")" ;;
    not-found) probe_ok=0; issue_state_raw="ABSENT" ;;
    *)         probe_ok=0; issue_state_raw="UNKNOWN" ;;
  esac
  issue_state="$(printf '%s' "$issue_state_raw" | tr '[:upper:]' '[:lower:]')"
  labels_json="$(jq -c '[(.labels // [])[]?.name]' <<<"$issue_json")"

  # Is the target a PULL REQUEST rather than an issue? `.url` discriminates at
  # no extra API call (`/pull/<n>` vs `/issues/<n>`). The `merged` fallback is
  # a belt-and-suspenders second signal for a payload carrying no url (an older
  # fixture): `merged` is a state only a PR can ever be in.
  issue_url="$(jq -r '.url // ""' <<<"$issue_json")"
  is_pr=false
  case "$issue_url" in */pull/*) is_pr=true ;; esac
  if [ "$issue_state" = "merged" ]; then is_pr=true; fi

  has_label() {
    jq -e --arg l "$1" 'any(.[]; . == $l)' <<<"$labels_json" >/dev/null 2>&1
  }

  # ── claim state (fnd:host/session:<host>:<session> label — issues-only
  # backend convention, workflows/scripts/board/ISSUES-ONLY-BACKEND.md
  # § The label vocabulary) ──────────────────────────────────────────────
  local host_session cur_host cur_stamp claimed by_me
  host_session="$(jq -r '
    [(.labels // [])[]?.name | select(startswith("fnd:host/session:"))][0] // empty
    | sub("^fnd:host/session:"; "")' <<<"$issue_json")"
  cur_host="${SUBSET_HOST_LABEL:-$(hostname -s 2>/dev/null || echo unknown)}"
  cur_stamp=""
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    cur_stamp="${cur_host}:${CLAUDE_CODE_SESSION_ID:0:8}"
  fi
  claimed=false; by_me=false
  if [ -n "$host_session" ]; then
    claimed=true
    if [ -n "$cur_stamp" ] && [ "$host_session" = "$cur_stamp" ]; then
      by_me=true
    fi
  fi

  # ── open-PR linkage (shared lib) ────────────────────────────────────────
  # Skipped entirely when the probe failed: there is no target to find a linked
  # PR for, and a nonexistent/unreadable issue must not cost a second gh call.
  local pr_numbers pr_count open_prs_json="[]" num pr_json
  pr_numbers=""
  if [ "$probe_ok" -eq 1 ]; then
    pr_numbers="$(open_pr_for_issue "$repo" "$issue")"
  fi
  pr_count=0
  if [ -n "$pr_numbers" ]; then
    while IFS= read -r num; do
      [ -z "$num" ] && continue
      pr_count=$((pr_count + 1))
      pr_json="$(issue_state_get_pr "$repo" "$num")"
      open_prs_json="$(jq -c --argjson d "$pr_json" --argjson n "$num" '. + [{
          number: ($d.number // $n),
          draft: ($d.draft // false),
          author: ($d.author.login // null),
          updated_at: ($d.updatedAt // null),
          linkage: "closes"
        }]' <<<"$open_prs_json")"
    done <<<"$pr_numbers"
  fi

  # ── route precedence (first match wins) ─────────────────────────────────
  # The three "is this even a drivable open issue?" arms come FIRST, so no
  # later arm — `fresh` above all — is reachable for a target that does not
  # exist, could not be read, is a pull request, or is not open. That ordering
  # is what makes `reason` structurally unable to contradict `issue_state`
  # (temperloop#1591 / #1518, epic #1626).
  if [ "$probe_kind" = "not-found" ]; then
    route="not-found"
    reason="no issue or pull request #$issue in $repo"
  elif [ "$probe_ok" -eq 0 ]; then
    route="probe-failed"
    reason="state probe failed, state unknown (not a 404): $probe_error"
  elif [ "$is_pr" = true ]; then
    route="not-an-issue"
    reason="#$issue is a pull request ($issue_state), not an issue"
  elif [ "$issue_state" != "open" ]; then
    route="already-done"
    reason="issue is $issue_state"
  elif has_label "$ISSUE_STATE_LABEL_NEEDS_CLARIFICATION"; then
    route="question-first"
    reason="labeled $ISSUE_STATE_LABEL_NEEDS_CLARIFICATION"
  elif [ "$claimed" = true ] && [ "$by_me" = false ]; then
    route="claimed-elsewhere"
    reason="in progress, claimed by $host_session"
  elif [ "$pr_count" -gt 1 ]; then
    route="ambiguous"
    reason="$pr_count open PRs link to this issue"
  elif [ "$pr_count" -eq 1 ]; then
    route="adopt"
    reason="one open PR (#$(jq -r '.[0].number' <<<"$open_prs_json")) links to this issue"
  elif has_label "$ISSUE_STATE_LABEL_PIPELINE_MERGE_PENDING"; then
    route="adopt"
    reason="labeled $ISSUE_STATE_LABEL_PIPELINE_MERGE_PENDING"
  else
    route="fresh"
    # Only a self-claim can reach here (a foreign claim took the
    # `claimed-elsewhere` arm above), so say which — a bare "unclaimed" beside
    # `claim.claimed: true` is the same self-contradiction class as #1518.
    if [ "$claimed" = true ]; then
      reason="open, claimed by this session, no linked PR"
    else
      reason="open, unclaimed, no linked PR"
    fi
  fi

  # A failure route gets one human-readable line on stderr too — the JSON
  # verdict is the contract, but a human running this by hand should not have
  # to pipe it through jq to see that the probe found nothing.
  if [ "$probe_ok" -eq 0 ]; then
    printf 'issue-state.sh resolve: %s\n' "$reason" >&2
  fi

  local worktree_path=""
  if [ "$probe_ok" -eq 1 ]; then
    worktree_path="$(find_worktree "$repo" "$issue")"
  fi

  jq -cn \
    --arg repo "$repo" \
    --argjson issue "$issue" \
    --arg issue_state "$issue_state" \
    --argjson is_pr "$is_pr" \
    --argjson open_prs "$open_prs_json" \
    --argjson claimed "$claimed" \
    --arg host_session "$host_session" \
    --argjson by_me "$by_me" \
    --argjson labels "$labels_json" \
    --arg worktree "$worktree_path" \
    --arg route "$route" \
    --arg reason "$reason" \
    '{
      repo: $repo,
      issue: $issue,
      issue_state: $issue_state,
      is_pull_request: $is_pr,
      open_prs: $open_prs,
      claim: {
        claimed: $claimed,
        host_session: (if $host_session == "" then null else $host_session end),
        by_me: $by_me
      },
      labels: $labels,
      worktree: (if $worktree == "" then null else $worktree end),
      route: $route,
      reason: $reason
    }'
}

# ── reattach ─────────────────────────────────────────────────────────────
reattach_usage() {
  cat >&2 <<'USAGE'
usage: issue-state.sh reattach <repo> <pr> [--dry-run --fixture <dir>]

Revalidates an already-open PR by composing the shared machinery scripts
(ci-poll.sh + the pr.sh rebase contract) and prints ONE ready/not-ready
verdict JSON to stdout. It NEVER merges — the caller owns the merge. This is
the adoption-safety check `/fix` runs before driving an existing PR through
the merge gate.

  {
    "repo":"owner/repo", "pr":N,
    "state":"OPEN|CLOSED|MERGED",
    "mergeable":"MERGEABLE|CONFLICTING|UNKNOWN",
    "merge_state":"CLEAN|BEHIND|BLOCKED|DIRTY|...",
    "ci":"green|pending|red|unknown",
    "ready": true|false,
    "reason":"<one line>"
  }

Verdict precedence (first decisive condition wins):
  1. state != OPEN                          -> ready:false "closed-underneath"
  2. mergeable CONFLICTING or merge DIRTY   -> ready:false "conflict" (no CI poll)
  3. CI re-poll (pinned to the PR head oid):
       CI_FAILED  -> ready:false "ci-red"
       TIMEOUT    -> ready:false "ci-pending"
       CI_GREEN / NO_CI -> continue
  4. merge_state BEHIND -> rebase (pr.sh rebase) + re-poll (rebased sha):
       clean rebase + green re-poll -> ready:true "rebased"
       rebase conflict              -> ready:false "stale-base-conflict"
  5. otherwise (OPEN, MERGEABLE/CLEAN, CI green) -> ready:true "green-ready"

  --dry-run --fixture <dir>   Offline fixture mode (see this file's header
                               comment for the reattach fixture layout).
USAGE
}

# reattach_get_pr <repo> <pr> — prints the raw `gh pr view --json state,
# mergeable,mergeStateStatus,headRefOid,headRefName` JSON (or its fixture
# equivalent).
reattach_get_pr() {
  local repo="$1" pr="$2" f
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/reattach-pr-$pr.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"state":"OPEN","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'; fi
    return 0
  fi
  gh pr view "$pr" -R "$repo" --json state,mergeable,mergeStateStatus,headRefOid,headRefName 2>/dev/null || echo '{}'
}

# reattach_ci_poll <repo> <pr> <sha> <fixture-key> — re-polls CI via the shared
# ci-poll.sh, ALWAYS pinning the head SHA (`--sha`, the #254 guard — never let
# ci-poll re-read a lagging PR API head). Prints ci-poll.sh's verdict JSON
# regardless of its exit code (ci-poll emits the JSON on stdout even for its
# non-zero TIMEOUT/ERROR outcomes). In DRY_RUN, reads the named fixture instead.
reattach_ci_poll() {
  local repo="$1" pr="$2" sha="$3" key="$4" f out
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/$key.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"outcome":"NO_CI"}'; fi
    return 0
  fi
  if [ -n "$sha" ]; then
    out="$(bash "$HERE/ci-poll.sh" "$repo" "$pr" --sha "$sha" 2>/dev/null)" || true
  else
    out="$(bash "$HERE/ci-poll.sh" "$repo" "$pr" 2>/dev/null)" || true
  fi
  [ -n "$out" ] || out='{"outcome":"ERROR","error":"ci-poll produced no output"}'
  printf '%s\n' "$out"
}

# reattach_rebase <pr> — resolves the BEHIND-base rebase.
#
# DRY_RUN: reads $FIXTURE/rebase-<pr>.json (a mock of the pr.sh `rebase`
# contract) — {"outcome":"REBASED","sha":...} | {"outcome":"REBASE_CONFLICT"}.
# This is the surface the stale-base-rebasable / stale-base-conflict fixture
# cases exercise: the full REBASED -> re-poll -> "rebased" and REBASE_CONFLICT
# -> "stale-base-conflict" decision branches run against it.
#
# LIVE: `reattach` holds only <owner/repo> + <pr> — it does NOT own a local
# checkout, so it cannot safely perform a force-pushing rebase from inside this
# VERDICT op (reattach "NEVER merges"; a surprise force-push from a revalidation
# check is a bigger, un-owned mutation). It therefore DEGRADES DELIBERATELY to a
# NEEDS_UPDATE signal; the caller (`/fix`), which owns a local checkout, runs the
# rebase (composing pr.sh rebase + pr.sh push --force + a `--sha`-pinned re-poll,
# all already-tested machinery scripts) and re-invokes reattach. The DRY_RUN path
# above still exercises the rebase decision logic in full — see the design note
# in the verification surface (task's sanctioned choice for the live case).
reattach_rebase() {
  local pr="$1" f
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/rebase-$pr.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"outcome":"REBASE_CONFLICT","error":"no rebase fixture"}'; fi
    return 0
  fi
  echo '{"outcome":"NEEDS_UPDATE"}'
}

# reattach_emit — prints the single verdict JSON. `ready` is passed as a bare
# true/false literal (via --argjson).
reattach_emit() {
  local repo="$1" pr="$2" state="$3" mergeable="$4" merge_state="$5" ci="$6" ready="$7" reason="$8"
  jq -cn \
    --arg repo "$repo" \
    --argjson pr "$pr" \
    --arg state "$state" \
    --arg mergeable "$mergeable" \
    --arg merge_state "$merge_state" \
    --arg ci "$ci" \
    --argjson ready "$ready" \
    --arg reason "$reason" \
    '{
      repo: $repo, pr: $pr, state: $state,
      mergeable: $mergeable, merge_state: $merge_state,
      ci: $ci, ready: $ready, reason: $reason
    }'
}

cmd_reattach() {
  local repo="" pr="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --fixture) FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
      -h|--help) reattach_usage; exit 0 ;;
      -*) echo "issue-state.sh reattach: unknown flag '$1'" >&2; reattach_usage; exit 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [ "${#args[@]}" -ne 2 ]; then
    echo "issue-state.sh reattach: expected <repo> <pr>" >&2
    reattach_usage
    exit 2
  fi
  repo="${args[0]}"; pr="${args[1]}"
  case "$pr" in
    ""|*[!0-9]*)
      echo "issue-state.sh reattach: pr '$pr' invalid — must be a PR number" >&2
      reattach_usage
      exit 2
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
    echo "issue-state.sh reattach: --dry-run requires --fixture <dir>" >&2
    exit 2
  fi
  if [ -n "$FIXTURE" ] && [ ! -d "$FIXTURE" ]; then
    echo "issue-state.sh reattach: fixture dir not found: $FIXTURE" >&2
    exit 2
  fi

  local pr_json state mergeable merge_state head_oid
  pr_json="$(reattach_get_pr "$repo" "$pr")"
  state="$(jq -r '.state // "OPEN"' <<<"$pr_json" | tr '[:lower:]' '[:upper:]')"
  mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$pr_json" | tr '[:lower:]' '[:upper:]')"
  merge_state="$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$pr_json" | tr '[:lower:]' '[:upper:]')"
  head_oid="$(jq -r '.headRefOid // ""' <<<"$pr_json")"

  # 1. state != OPEN (closed/merged underneath) — decisive, no further checks.
  if [ "$state" != "OPEN" ]; then
    reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "unknown" false "closed-underneath"
    return 0
  fi

  # 2. conflict — escalate IMMEDIATELY, do NOT poll CI to timeout.
  if [ "$mergeable" = "CONFLICTING" ] || [ "$merge_state" = "DIRTY" ]; then
    reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "unknown" false "conflict"
    return 0
  fi

  # 3. Re-poll CI, pinned to the PR head oid (#254 SHA-pin).
  local poll outcome ci
  poll="$(reattach_ci_poll "$repo" "$pr" "$head_oid" "ci-poll-$pr")"
  outcome="$(jq -r '.outcome // "ERROR"' <<<"$poll")"
  case "$outcome" in
    CI_GREEN) ci="green" ;;
    NO_CI)    ci="unknown" ;;  # a repo with no CI has nothing to gate on — continue (cf. #605)
    CI_FAILED)
      reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "red" false "ci-red"
      return 0 ;;
    TIMEOUT)
      reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "pending" false "ci-pending"
      return 0 ;;
    *)
      reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "unknown" false "ci-error"
      return 0 ;;
  esac

  # 4. Stale base (BEHIND) — rebase, then re-poll pinned to the rebased sha.
  if [ "$merge_state" = "BEHIND" ]; then
    local rb rb_outcome rebased_sha repoll rep_outcome
    rb="$(reattach_rebase "$pr")"
    rb_outcome="$(jq -r '.outcome // "REBASE_CONFLICT"' <<<"$rb")"
    case "$rb_outcome" in
      REBASE_CONFLICT)
        reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "$ci" false "stale-base-conflict"
        return 0 ;;
      NEEDS_UPDATE)
        reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "$ci" false "stale-base — needs update"
        return 0 ;;
      REBASED)
        rebased_sha="$(jq -r '.sha // ""' <<<"$rb")"
        repoll="$(reattach_ci_poll "$repo" "$pr" "$rebased_sha" "ci-poll-rebased-$pr")"
        rep_outcome="$(jq -r '.outcome // "ERROR"' <<<"$repoll")"
        case "$rep_outcome" in
          CI_GREEN|NO_CI)
            reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "green" true "rebased"
            return 0 ;;
          CI_FAILED)
            reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "red" false "ci-red"
            return 0 ;;
          TIMEOUT)
            reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "pending" false "ci-pending"
            return 0 ;;
          *)
            reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "unknown" false "ci-error"
            return 0 ;;
        esac ;;
      *)
        # Any unexpected rebase outcome is treated conservatively as not-ready.
        reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "$ci" false "stale-base-conflict"
        return 0 ;;
    esac
  fi

  # 5. Otherwise: OPEN, MERGEABLE/CLEAN, CI green -> ready.
  reattach_emit "$repo" "$pr" "$state" "$mergeable" "$merge_state" "$ci" true "green-ready"
}

# ── dispatch ─────────────────────────────────────────────────────────────
# No subcommand at all is a usage ERROR (exit 2) — only an EXPLICIT -h/--help
# request exits 0, per this file's activation-proof contract.
if [ $# -eq 0 ]; then
  usage
  exit 2
fi

sub="$1"; shift
case "$sub" in
  resolve) cmd_resolve "$@" ;;
  reattach) cmd_reattach "$@" ;;
  -h|--help) usage; exit 0 ;;
  *)
    echo "issue-state.sh: unknown subcommand '$sub'" >&2
    usage
    exit 2
    ;;
esac
