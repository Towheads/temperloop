#!/usr/bin/env bash
#
# land-on-protected-main.sh — a SOURCED library that lands a caller-supplied set
# of changes durably onto a repo's default branch, transparently handling the
# case where that branch is PROTECTED (branch-protection / merge-queue ruleset)
# and rejects a direct push (GH013).
#
# Extracted from archive-session.sh's #404 fix so the protected-main landing
# kernel is shared, not copy-pasted: both the session-transcript archive
# (archive-session.sh) and the build plan-snapshot archive
# (build/archive-plan.sh, #408) drive it. The next protected-main lander is
# free — define a populate fn + set the LAND_* contract.
#
# Contract — the caller sets these, defines a populate fn, then calls land_run:
#
#   in (env):
#     LAND_ROOT            target repo root (the repo the change lands in — may be
#                          a CONSUMING repo even though this lib is sourced from
#                          foundation; script location != target repo). REQUIRED.
#     LAND_BRANCH          stable branch name for the PR path (reused across runs
#                          so repeated runs converge on ONE PR). REQUIRED.
#     LAND_PATHS           bash ARRAY of repo-relative paths to `git add`. REQUIRED,
#                          non-empty (e.g. LAND_PATHS=("meta/sessions/archive")).
#     LAND_COMMIT_MSG      commit message. REQUIRED.
#     LAND_PR_TITLE        PR title (PR path only). REQUIRED when main is protected.
#     LAND_PR_BODY         PR body  (PR path only). REQUIRED when main is protected.
#     LAND_GH              gh binary override (default: gh).            [test seam]
#     LAND_DEFAULT_BRANCH  default branch (default: main).
#     LAND_REQUIRES_PR     force the protected path when "1".           [test seam]
#
#   fn:
#     <populate_fn> <root>   place the desired tree state under <root> for the
#                            LAND_PATHS it manages. On the PROTECTED path <root>
#                            is a throwaway worktree checked out from
#                            origin/<default> (so LAND_ROOT's checkout is never
#                            touched); on the DIRECT / no-remote path <root> is
#                            LAND_ROOT itself (in place).
#
#   out (vars set by land_run; caller maps to its own vocabulary):
#     LAND_RESULT  committed | pr-queued | pr-open | uncommitted
#     LAND_REV     short SHA          (committed)
#     LAND_PR      PR number          (pr-queued, pr-open)
#     LAND_DETAIL  pushed | already on origin | already current |
#                  enqueued | already on the open archive PR | <why> | ""
#     LAND_ENQUEUE_ERR  why the queue did not take the PR — set ONLY on the
#                  `pr-open` arm, empty otherwise (#1523). A consuming `case`
#                  that predates the `pr-open` result will fall through its
#                  default arm; see the vendored archive-session.sh note below.
#
# The four results, and what each one PROVES (#1523 — a verdict never outruns its
# own payload; a caller must not fold the middle two into "success"):
#   committed    the payload is ON the default branch. The only landed result.
#   pr-queued    the payload is on the archive BRANCH only, carried by an open PR
#                whose auto-merge IS armed. Pending — it lands when the queue merges.
#   pr-open      same, but arming auto-merge FAILED. The PR may never merge on its
#                own; a human has to. Report it as a failure to land, not as queued.
#   uncommitted  nothing landed anywhere.
#
# land_run ALWAYS returns 0 — the outcome is in LAND_RESULT, never the exit code,
# so a `set -e` caller is never aborted by a "rejected push" control-flow branch.
#
# NEVER-DESTROY guarantee (#1523): the PR path bases its worktree on the PENDING
# archive branch whenever `origin/$LAND_BRANCH` carries commits that are not yet on
# `origin/$LAND_DEFAULT_BRANCH` — so a prior run's un-merged payload is carried
# forward and extended, never force-rebuilt off the default branch and discarded.
# The branch is rebuilt off `origin/$LAND_DEFAULT_BRANCH` only when it has nothing
# unlanded on it (absent, or already merged).
#
# Working-tree guarantee: on the PROTECTED (PR) path the kernel builds the commit in
# a throwaway worktree and NEVER modifies LAND_ROOT's working tree or branch. So a
# caller that dirtied LAND_ROOT *before* calling land_run (e.g. an in-place sweep)
# OWNS reverting it afterward — the kernel won't, because those changes rode the PR
# branch instead. (On the direct path the kernel's own commit/undo leaves LAND_ROOT
# clean, so no caller revert is needed there.)
#
# This file is SOURCED — it sets no shell options (the caller owns set -euo).
#
# Helpers a DRIVER may also call directly (archive-session.sh calls land__requires_pr
# as a standalone predicate before land_run): land__requires_pr, land__nwo,
# land__gh_pr. Every one of them is anchored to $LAND_ROOT, never the caller's cwd.

# Does the target repo have an `origin` remote?
land__has_remote() { git -C "$LAND_ROOT" remote get-url origin >/dev/null 2>&1; }

# --- Target-repo resolution (#873) -------------------------------------------
# `gh` resolves WHICH REPO it acts on from the CALLER's $PWD unless told otherwise,
# but this lib lands into $LAND_ROOT — routinely NOT the caller's cwd (the nightly
# drain invokes the archiver from the knowledge store, which is not a git repo at
# all). So every gh call here is anchored to $LAND_ROOT's own `origin` instead, and
# a probe that cannot answer says so on stderr rather than branching in silence
# (#873: `gh repo view` with no -R failed from a non-repo cwd, land__requires_pr
# returned false, the direct path was taken, and the archive stalled 44h with no
# diagnostic beyond "direct push to main rejected").

# One-line diagnostic on stderr. Advisory only — never changes an exit status, so a
# `set -e` caller is unaffected and the caller's own status line still rules.
land__warn() { printf 'land: %s\n' "$*" >&2; }

# `<owner>/<repo>` for $LAND_ROOT's origin, or "" when origin is not a forge URL
# (a local-path origin — the hermetic tests — or a non-GitHub remote). Parsed from
# the remote URL rather than `gh repo view` so the answer is cwd-independent AND
# free (no API call): a local `git remote get-url` per call, deliberately NOT memoized
# — every caller reads it as `$(land__nwo)`, so any cache the function set would land
# in that command substitution's subshell and never be seen again. A cache here would
# be dead state that merely LOOKS load-bearing.
land__nwo() {
  local url slug="" repo rest
  url="$(git -C "$LAND_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    ""|file://*) ;;                     # local path: no forge slug to resolve
    *://*|*@*:*)                        # scheme URL, or scp-like host:path
      slug="${url%.git}"; slug="${slug%/}"
      slug="${slug#*://}"               # strip scheme
      slug="${slug#*@}"                 # strip user@
      slug="${slug/:/\/}"               # host:port | host:path -> host/...
      case "$slug" in
        */*/*) repo="${slug##*/}"; rest="${slug%/*}"; rest="${rest##*/}"
               slug="$rest/$repo"
               case "$slug" in ""|/*|*/) slug="" ;; esac ;;
        *)     slug="" ;;
      esac
      ;;
  esac
  printf '%s' "$slug"
}

# Run a `gh pr …` call against the TARGET repo instead of the caller's cwd. When the
# slug is unresolvable (local-path origin) the call runs unqualified, as before.
land__gh_pr() {  # <gh args...>
  local nwo; nwo="$(land__nwo)"
  if [ -n "$nwo" ]; then "$LAND_GH" "$@" -R "$nwo"; else "$LAND_GH" "$@"; fi
}

# Does the default branch require a PR (branch protection / merge-queue ruleset),
# i.e. is a direct push rejected? Probe once, read-only, via the branch's effective
# rules, resolved from $LAND_ROOT (#873).
#
# Fail-open, but LOUD. A probe that errors still returns false → the direct path —
# because the direct path SELF-GUARDS (a rejected push is undone and reported as
# `uncommitted`, never a false "committed"), and failing closed would strand every
# legitimate unprotected-main / gh-less repo on a PR path it cannot complete. What
# changes in #873 is that "couldn't tell" is no longer indistinguishable from
# "confirmed unprotected": it names the failure on stderr, the same
# confirmed-vs-couldn't-tell split gate.sh's sibling probe makes with `probe_failed`.
land__requires_pr() {
  : "${LAND_GH:=gh}"                              # callable before land_run's defaults
  : "${LAND_DEFAULT_BRANCH:=main}"
  [ "${LAND_REQUIRES_PR:-}" = "1" ] && return 0   # test seam
  land__has_remote || return 1                    # no remote: nothing to be protected
  local nwo out
  nwo="$(land__nwo)"
  if [ -z "$nwo" ]; then
    land__warn "protection probe: cannot resolve owner/repo from origin in $LAND_ROOT ('$(git -C "$LAND_ROOT" remote get-url origin 2>/dev/null)') — falling back to the DIRECT path; a rejected push will report uncommitted"
    return 1
  fi
  if ! out="$("$LAND_GH" api "repos/$nwo/rules/branches/$LAND_DEFAULT_BRANCH" \
                --jq 'any(.[]; .type=="merge_queue" or .type=="pull_request")' 2>&1)"; then
    out="${out//$'\n'/ }"
    land__warn "protection probe: 'gh api repos/$nwo/rules/branches/$LAND_DEFAULT_BRANCH' failed (${out:0:200}) — falling back to the DIRECT path; a rejected push will report uncommitted"
    return 1
  fi
  case "$out" in
    true)  return 0 ;;                            # answered: protected
    false) return 1 ;;                            # answered: not protected
  esac
  # Exit 0 but no verdict (empty body, an unexpected shape): still a couldn't-tell.
  land__warn "protection probe: unreadable answer from 'gh api repos/$nwo/rules/branches/$LAND_DEFAULT_BRANCH' ('${out:0:200}') — falling back to the DIRECT path; a rejected push will report uncommitted"
  return 1
}

# Set the four output vars in one place. (Assigned here, read by the caller in
# another file — hence the SC2034 directive.)
# shellcheck disable=SC2034
land__set() {  # <result> <rev> <pr> <detail>
  LAND_RESULT="$1"; LAND_REV="$2"; LAND_PR="$3"; LAND_DETAIL="$4"
}

# Stage every managed path under <root>. -A captures additions, modifications,
# AND deletions (e.g. a .md -> .md.gz retention rename).
land__add() {  # <root>
  local root="$1" p
  for p in "${LAND_PATHS[@]}"; do
    git -C "$root" add -A -- "$p" >/dev/null 2>&1 || true
  done
}

# Did the populate + stage actually put the managed payload into the INDEX? (#1523)
#
# An EMPTY staged diff is ambiguous: it means "already present" only when the
# managed paths are genuinely TRACKED here. If populate wrote a file the index
# never took — the path is .gitignore'd, `git add` refused it, or a partial
# populate left it out — the diff is empty because the payload is ABSENT, and the
# short-circuit below would report `committed (already on origin/current)` for
# bytes that never landed. That is the false-success shape this guard closes:
# an absent input must never read as a clean one.
#
# Scope: only paths populate actually produced under <root> are checked. A managed
# path this run did not create (a caller managing several paths and touching some),
# and a managed DIRECTORY holding no files, carry no payload to verify — skip them
# so a legitimately empty managed dir is not misread as a failure.
land__paths_staged() {  # <root>  -> 0 = every produced path is in the index
  local root="$1" p
  for p in "${LAND_PATHS[@]}"; do
    [ -e "$root/$p" ] || continue
    if [ -d "$root/$p" ]; then
      [ -n "$(find "$root/$p" -type f -print -quit 2>/dev/null)" ] || continue
    fi
    git -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || return 1
  done
  return 0
}

# Arm auto-merge on <pr>. Returns non-zero — with the reason in LAND_ENQUEUE_ERR —
# when the queue did NOT take it. (#1523: the result used to be discarded with
# `|| true`, so a failed enqueue reported `enqueued` identically to a successful
# one.) A `gh` that reports the PR is already queued / auto-merge already enabled
# is a SUCCESS: the desired end state holds, the second call was just redundant.
land__enqueue() {  # <pr>
  local pr="$1" out rc=0
  LAND_ENQUEUE_ERR=""
  out="$(land__gh_pr pr merge "$pr" --auto 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  # Re-PROBE the desired end state rather than pattern-matching gh's
  # human-facing prose: that text is not a contract, it is localised and
  # reworded between gh releases, and a glob over it silently turns into a
  # false "enqueued" (or a false failure) the first time the wording moves.
  # Auto-merge armed OR a live queue entry both mean the end state holds,
  # whatever gh chose to say about how it got there.
  if [ -n "$(land__gh_pr pr view "$pr" \
               --json autoMergeRequest,mergeQueueEntry \
               --jq '[.autoMergeRequest, .mergeQueueEntry] | map(select(. != null)) | .[0] // empty' \
               2>/dev/null)" ]; then
    return 0
  fi
  out="${out//$'\n'/ }"
  LAND_ENQUEUE_ERR="${out:0:200}"
  return 1
}

# Resolve the base the archive branch is (re)built on, and say whether it is a
# PENDING branch. (#1523 — the data-loss half.)
#
# `$LAND_BRANCH` is force-pushed every run. Basing it unconditionally on
# `origin/$LAND_DEFAULT_BRANCH` means any prior run's payload that has NOT merged
# yet — CI red, a queue stall, a PR sitting open — is overwritten and gone. So:
# fetch the remote branch, and if it carries commits the default branch does not,
# build ON TOP of it. Prints "<base-ref> <pending 0|1>".
land__pr_base() {
  local rref="refs/remotes/origin/$LAND_BRANCH" rc=0
  LAND__PR_BASE=""; LAND__PR_PENDING=0

  # ABSENT vs INDETERMINATE — the distinction the never-destroy guarantee rests on.
  #
  # This used to branch on `git fetch`'s exit code alone, and treat ANY non-zero
  # as "the remote branch is gone". A transient network/auth/rate-limit failure
  # therefore read as absence: the tracking ref was deleted, pending came back 0,
  # and the caller force-pushed the archive branch rebuilt from the default
  # branch — discarding every un-merged snapshot on it. That is exactly the data
  # loss #1523 exists to prevent, so the guarantee has to be mechanical rather
  # than a comment.
  #
  # `ls-remote --exit-code` separates the two: exit 2 means the ref genuinely
  # does not exist on origin, any other non-zero means we could not find out.
  # Only the first is safe to treat as absence.
  git -C "$LAND_ROOT" ls-remote --exit-code --heads origin "$LAND_BRANCH" >/dev/null 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    # The branch EXISTS. A fetch failure here is never absence — refuse rather
    # than rebuild over a payload we cannot see.
    git -C "$LAND_ROOT" fetch -q origin "+refs/heads/$LAND_BRANCH:$rref" 2>/dev/null || return 1
    # Unlanded commits on the branch => a pending payload to preserve.
    if [ -n "$(git -C "$LAND_ROOT" rev-list -n 1 \
                 "origin/$LAND_DEFAULT_BRANCH..origin/$LAND_BRANCH" 2>/dev/null)" ]; then
      LAND__PR_BASE="origin/$LAND_BRANCH"; LAND__PR_PENDING=1; return 0
    fi
    LAND__PR_BASE="origin/$LAND_DEFAULT_BRANCH"; return 0
  fi

  if [ "$rc" -eq 2 ]; then
    # Genuinely no such branch on origin (merged + auto-deleted, or never
    # existed). Drop the stale tracking ref so a later run cannot base on it.
    git -C "$LAND_ROOT" update-ref -d "$rref" 2>/dev/null || true
    LAND__PR_BASE="origin/$LAND_DEFAULT_BRANCH"; return 0
  fi

  return 1  # could not determine — the caller must not land
}

# Tear down a throwaway worktree + its mktemp parent dir.
land__finish_wt() {  # <wt>
  git -C "$LAND_ROOT" worktree remove --force "$1" >/dev/null 2>&1 || rm -rf "$1"
  rmdir "$(dirname "$1")" 2>/dev/null || true
}

# Protected default branch: build the commit in a throwaway worktree off the base
# land__pr_base picks (so LAND_ROOT's checked-out branch is never touched), push the
# stable branch, adopt-or-open a PR, and arm auto-merge so the queue lands it.
# Idempotent across runs: stable branch + force-push + adopt-open-PR +
# the diff-against-base short-circuit converge repeated runs onto ONE PR, then
# auto-flip to `committed (already on origin)` once it merges.
land__via_pr() {  # <populate_fn>
  local populate_fn="$1" branch wt rev base pending
  branch="$LAND_BRANCH"
  git -C "$LAND_ROOT" worktree prune >/dev/null 2>&1 || true
  git -C "$LAND_ROOT" fetch -q origin "$LAND_DEFAULT_BRANCH" 2>/dev/null || true
  # #1523: extend a PENDING archive branch instead of force-rebuilding over it.
  if ! land__pr_base; then
    land__set uncommitted "" "" "could not determine the state of origin/$LAND_BRANCH — refusing to force-rebuild the archive branch over a payload that may be pending"
    return 0
  fi
  base="$LAND__PR_BASE"; pending="$LAND__PR_PENDING"
  wt="$(mktemp -d "${TMPDIR:-/tmp}/land-wt-XXXXXX")/wt"
  if ! git -C "$LAND_ROOT" worktree add -q -B "$branch" "$wt" "$base" 2>/dev/null; then
    rm -rf "$(dirname "$wt")"
    land__set uncommitted "" "" "could not create worktree off $base"
    return 0
  fi
  "$populate_fn" "$wt"
  land__add "$wt"
  if git -C "$wt" diff --cached --quiet -- "${LAND_PATHS[@]}"; then
    # Empty diff. Three genuinely different states hide behind it — separate them
    # before any of them is allowed to report success (#1523).
    if ! land__paths_staged "$wt"; then
      land__finish_wt "$wt"
      land__warn "nothing staged for ${LAND_PATHS[*]} in $LAND_ROOT and the path is not tracked — the payload never reached the index (ignored by .gitignore, or the populate failed); NOTHING landed"
      land__set uncommitted "" "" "payload for '${LAND_PATHS[*]}' never reached the index — nothing landed"
      return 0
    fi
    if [ "$pending" = "1" ]; then
      # Matches the PENDING branch, not the default branch: still un-landed.
      # Reporting `committed (already on origin)` here would be the exact
      # false-success this issue is about.
      land__finish_wt "$wt"
      land__resolve_pr "$branch" "already on the open archive PR"
      return 0
    fi
    rev="$(git -C "$wt" rev-parse --short HEAD)"
    land__finish_wt "$wt"
    land__set committed "$rev" "" "already on origin"
    return 0
  fi
  git -C "$wt" commit -q -m "$LAND_COMMIT_MSG" -- "${LAND_PATHS[@]}"
  # Plain --force, not --force-with-lease: $branch is orchestrator-owned and its base
  # is chosen by land__pr_base (the pending branch when one exists, so this push is a
  # fast-forward that PRESERVES the pending payload; the default branch otherwise), so
  # there is no local work to protect. A no-value --force-with-lease uses the local
  # refs/remotes/origin/$branch tracking ref as its lease, which goes stale the moment a
  # prior run's PR merges and the remote head auto-deletes on a checkout that never
  # prunes — rejecting every subsequent push with "stale info" (#658).
  if ! git -C "$wt" push -q -u origin "$branch" --force 2>/dev/null; then
    land__finish_wt "$wt"
    land__set uncommitted "" "" "push of branch '$branch' failed"
    return 0
  fi
  land__finish_wt "$wt"
  land__resolve_pr "$branch" "enqueued"
  return 0
}

# Adopt-or-open the PR carrying <branch>, then arm auto-merge, and set the outputs.
# <queued-detail> is the LAND_DETAIL to report when the queue takes it.
land__resolve_pr() {  # <branch> <queued-detail>
  local branch="$1" queued_detail="$2" pr nwo
  nwo="$(land__nwo)"   # for the diagnostics below; land__gh_pr resolves it itself
  # Three-tier PR resolve (#27). $branch is a reused, orchestrator-owned ref, so a
  # PRIOR run's open PR is the common case — the adopt-or-open step has to converge
  # on that one PR rather than dead-end. Each tier is a fallback for the previous
  # tier's specific blind spot:
  #
  #   1. `pr list --head` — cheap, but SEARCH-INDEX backed, and the index lags the
  #      force-push above by seconds. An empty result is NOT proof no PR exists.
  #   2. `pr create` — on a duplicate it REFUSES, exits non-zero, and prints the
  #      existing PR's URL to STDERR. So capture 2>&1 (not 2>/dev/null, which threw
  #      the recoverable number away) and match the `/pull/<n>` URL — not a bare
  #      trailing `[0-9]+$`, which a digit at the end of the title/body can satisfy.
  #   3. `pr view <branch>` — authoritative head-ref lookup with no search index in
  #      the path; adopts a PR tier 1 could not yet see.
  #
  # Every tier goes through land__gh_pr, which appends `-R <owner>/<repo>` resolved
  # from $LAND_ROOT — without it these three calls resolve the CALLER's cwd like the
  # old probe did (#873), so a fixed probe would just move the silent failure one
  # step later, into "could not open or find the PR".
  pr="$(land__gh_pr pr list --head "$branch" --state open --json number -q '.[0].number' 2>/dev/null || true)"
  if [ -z "$pr" ]; then
    pr="$(land__gh_pr pr create --base "$LAND_DEFAULT_BRANCH" --head "$branch" \
            --title "$LAND_PR_TITLE" --body "$LAND_PR_BODY" 2>&1 \
            | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+$' | tail -1 || true)"
  fi
  if [ -z "$pr" ]; then
    pr="$(land__gh_pr pr view "$branch" --json number -q .number 2>/dev/null || true)"
  fi
  if [ -z "$pr" ]; then
    land__warn "PR resolve failed for branch '$branch' in ${LAND_ROOT}${nwo:+ ($nwo)} — the commit is on that branch but no PR carries it"
    land__set uncommitted "" "" "could not open or find the PR for branch '$branch'"
    return 0
  fi
  # Queue-ON incantation (queue owns strategy + branch). Its RESULT is load-bearing:
  # a discarded failure here reported `enqueued` for a PR nothing would ever merge
  # (#1523), so a genuine failure downgrades the verdict to pr-open.
  if land__enqueue "$pr"; then
    land__set pr-queued "" "$pr" "$queued_detail"
  else
    land__warn "auto-merge could NOT be armed on PR #$pr for branch '$branch' in ${LAND_ROOT}${nwo:+ ($nwo)} — the payload is on that PR but nothing will merge it: ${LAND_ENQUEUE_ERR}"
    land__set pr-open "" "$pr" "auto-merge NOT armed on PR #$pr: ${LAND_ENQUEUE_ERR}"
  fi
  return 0
}

# Unprotected branch or no remote (fresh-local / tests): commit in place on
# LAND_ROOT, then push when a remote exists. A rejected push (protection the
# probe missed) undoes its own commit + the managed-path changes and reports
# uncommitted — so a false "committed" can never be reported for a stranded commit.
land__direct() {  # <populate_fn>
  local populate_fn="$1" rev
  "$populate_fn" "$LAND_ROOT"
  land__add "$LAND_ROOT"
  if git -C "$LAND_ROOT" diff --cached --quiet -- "${LAND_PATHS[@]}"; then
    # Same empty-diff ambiguity the PR path resolves above (#1523): "already
    # current" is only true when the payload is actually tracked here.
    if ! land__paths_staged "$LAND_ROOT"; then
      land__warn "nothing staged for ${LAND_PATHS[*]} in $LAND_ROOT and the path is not tracked — the payload never reached the index (ignored by .gitignore, or the populate failed); NOTHING landed"
      land__set uncommitted "" "" "payload for '${LAND_PATHS[*]}' never reached the index — nothing landed"
      return 0
    fi
    rev="$(git -C "$LAND_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
    land__set committed "$rev" "" "already current"
    return 0
  fi
  git -C "$LAND_ROOT" commit -q -m "$LAND_COMMIT_MSG" -- "${LAND_PATHS[@]}"
  rev="$(git -C "$LAND_ROOT" rev-parse --short HEAD)"
  if land__has_remote; then
    if git -C "$LAND_ROOT" push -q origin "$LAND_DEFAULT_BRANCH" 2>/dev/null; then
      land__set committed "$rev" "" "pushed"
      return 0
    fi
    # Push rejected: undo just this commit + the managed-path changes so LAND_ROOT
    # stays at origin, and report uncommitted. The guard that makes the #404
    # false-durability signal impossible even on a bad probe.
    git -C "$LAND_ROOT" reset -q --soft HEAD~1 2>/dev/null || true
    git -C "$LAND_ROOT" restore --staged --worktree -- "${LAND_PATHS[@]}" >/dev/null 2>&1 || true
    git -C "$LAND_ROOT" clean -fdq -- "${LAND_PATHS[@]}" >/dev/null 2>&1 || true
    # Name the contradiction the #873 stall hid: the probe routed here, so it either
    # said "unprotected" or could not tell (it printed its own reason above) — yet the
    # push was rejected. Nothing landed; the change is preserved for the next run.
    land__warn "direct push to $LAND_DEFAULT_BRANCH in $LAND_ROOT was REJECTED though the protection probe routed to the direct path — nothing landed; if a probe diagnostic appeared above, fix that first"
    land__set uncommitted "" "" "direct push to $LAND_DEFAULT_BRANCH rejected (branch likely protected)"
    return 0
  fi
  # No remote: a local commit is the durable end state available here.
  land__set committed "$rev" "" ""
  return 0
}

# Entry point. Routes to the protected (PR) or direct path and sets LAND_RESULT.
land_run() {  # <populate_fn>
  local populate_fn="$1"
  : "${LAND_GH:=gh}"
  : "${LAND_DEFAULT_BRANCH:=main}"
  # The output contract (LAND_RESULT/REV/PR/DETAIL) is set by land__set, which every
  # path below calls before returning — so no explicit reset is needed here.
  if land__requires_pr; then
    land__via_pr "$populate_fn"
  else
    land__direct "$populate_fn"
  fi
  return 0
}
