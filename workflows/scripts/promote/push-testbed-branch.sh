#!/usr/bin/env bash
#
# push-testbed-branch.sh — the MECHANICAL half of `/promote` (temperloop#1233,
# epic #1117 Produces 6): carry a testbed's REAL commits into the reader's own
# repository as a branch, then optionally open the pull request that proposes
# them.
#
# ── Why this exists as a script at all (ADR 0023) ──────────────────────────
# ADR 0023 splits a capability with a mechanical half and a judgment half at
# that seam: the judgment ("which work is worth promoting") is a slash command
# (claude/commands/promote.md), and the mechanism ("carry these commits over
# there, and only there") is this script. The whole point of paying for that
# interface is that the mechanical half becomes structurally testable — a test
# can assert what this script pushes; no test can assert against a prose step
# in a markdown spec. Its own suite lives at tests/test_push_testbed_branch.sh.
#
# ── Why NOT workflows/scripts/proposal/proposal-pr.sh ──────────────────────
# proposal-pr.sh is the TREE-PROPOSAL generator: it takes a JSON files
# manifest and REBUILDS the branch fresh off the base tip
# (`git checkout -q -B "$branch" "$base_ref"`, proposal-pr.sh:284, guarded at
# :265-266) before writing the manifest's file contents into it. That is
# exactly right for proposing a synthesized diff, and exactly wrong here: a
# testbed SHARES HISTORY with the original, and promotion's whole value is
# that it carries what the pipeline actually did — the real commits, their
# real messages, and their real authorship. Rebuilding off the base tip would
# squash all of that into one synthetic commit authored by whoever ran the
# promotion. So promotion transfers OBJECTS (fetch + push), never file
# contents, and therefore needs its OWN structural guarantee rather than an
# inherited one — see the refs contract below.
#
# ── The refs contract (the guarantee this script owns) ─────────────────────
# There is exactly ONE push in this file, and its refspec is always the
# literal `refs/promote/source:refs/heads/<branch>`:
#   * never `--mirror`, `--all`, `--tags`, or a bare `git push`, each of which
#     can move refs the caller never named;
#   * never the target's default branch — `<branch>` is refused up front when
#     it equals the resolved base branch, and the base branch is resolved from
#     the TARGET ITSELF (`git ls-remote --symref <url> HEAD`), not assumed;
#   * never a force push — an existing `refs/heads/<branch>` on the target is
#     refused in pre-flight rather than overwritten.
# tests/test_push_testbed_branch.sh asserts this by logging every `git`
# invocation the script makes and reading the refspecs back out of that log.
#
# ── Working-directory contract ─────────────────────────────────────────────
# NEITHER repository is inferred from an ambiguous cwd, and NEITHER checkout
# has its remotes mutated. The testbed is named by `--testbed-dir` (a real
# checkout, whose own `origin` names its owner/repo) and the real repository
# is named explicitly by `--to <owner>/<name>` — there is no code path that
# guesses a promotion target. The fetch-and-push itself happens in a
# throwaway bare repository under $TMPDIR: the testbed is added as a remote
# THERE, so this script never writes to the testbed checkout's config and
# never touches an operator's checkout of the real repository at all
# (§ Working-tree ownership — only the session that owns a checkout may move
# its HEAD or edit its remotes).
#
# ── The source-kind refusal ────────────────────────────────────────────────
# A `materialize-from-seed` testbed has no original to promote to (ADR 0025:
# its content is materialized from seed content tracked in this repository,
# not duplicated from a repo the operator owns). Promotion refuses against
# one — keyed on the `source_kind` field READ from the artifact record
# (workflows/scripts/testbed/record.sh), never inferred from a name, a
# remote, or the absence of history.
#
# Usage:
#   push-testbed-branch.sh preflight <options>   # all reads, zero writes
#   push-testbed-branch.sh push <options>        # pre-flight, then push
#
#   --to OWNER/NAME       REQUIRED. The reader's real repository. Never
#                         inferred — promotion always names its target.
#   --branch NAME         REQUIRED. The branch to create on the target. Must
#                         differ from the target's base branch, and must not
#                         already exist there.
#   --testbed-dir DIR     The testbed checkout the commits come from
#                         (default: `.`, i.e. run this from inside it).
#   --testbed-ref REF     Which ref of the testbed to promote (default: HEAD).
#   --testbed-repo OWNER/NAME
#                         The testbed's own owner/name, used to look its entry
#                         up in the artifact record. Default: derived from the
#                         testbed checkout's `origin` remote.
#   --target-url URL      Explicit git URL/path to push to. Default:
#                         https://github.com/OWNER/NAME.git. (This is also the
#                         seam the test suite uses to drive the whole script
#                         against local bare repositories with zero network.)
#   --base BRANCH         The target's base branch. Default: resolved from the
#                         target itself via `git ls-remote --symref`.
#   --allow-unrecorded    Proceed when this machine's artifact record has no
#                         entry for the testbed (e.g. it was created on a
#                         different machine). The source-kind refusal cannot
#                         run without a record, so this is opt-in and loud.
#   --open-pr             After a successful push, open the pull request.
#   --pr-title TITLE      Title for --open-pr (default: the branch name).
#   --pr-body TEXT        Body for --open-pr. The one-line provenance note is
#                         ALWAYS appended to whatever is passed here — a
#                         reviewer with no context on this process must be
#                         able to tell where the change came from, so the note
#                         is owned by this script rather than by a prose step
#                         a caller can forget.
#   --dry-run             Alias for `preflight` when passed to `push`.
#
# Dependencies: bash 3.2+, git, jq (for the record read), and gh for the
# access pre-check and --open-pr. No network is required to TEST it.

set -euo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../testbed/record.sh
. "$HERE/../testbed/record.sh"

PROG="push-testbed-branch.sh"

die() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

usage() {
  sed -n '/^# Usage:/,/^# Dependencies:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# slug_from_remote <url> — best-effort github.com "owner/repo" extraction.
# Same shape as testbed/source.sh's own private helper; re-derived here rather
# than sourced, because that file is a provider library whose two providers
# pull in seed/gh machinery this script has no use for.
# ---------------------------------------------------------------------------
slug_from_remote() {
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

# <value> -> 0 when it is exactly "<owner>/<name>".
is_owner_name() {
  case "$1" in
    */*/*) return 1 ;;
    */*) [ -n "${1%%/*}" ] && [ -n "${1#*/}" ] ;;
    *) return 1 ;;
  esac
}

# <branch> -> refuse anything that is not a plain, pushable branch name.
validate_branch_name() {
  local b="$1" what="$2"
  [ -n "$b" ] || die "$what is required"
  case "$b" in
    -* | /* | */ | *' '* | *..* | *'~'* | *'^'* | *':'* | *'?'* | *'*'* | *'['* | *\\* | refs/*)
      die "$what '$b' is not a plain branch name (no refs/ prefix, no leading '-', no whitespace or git revision syntax)"
      ;;
  esac
  git check-ref-format "refs/heads/$b" \
    || die "$what '$b' is not a valid git branch name"
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
MODE=""
TARGET=""
BRANCH=""
TESTBED_DIR="."
TESTBED_REF="HEAD"
TESTBED_REPO=""
TARGET_URL=""
BASE=""
ALLOW_UNRECORDED=0
OPEN_PR=0
PR_TITLE=""
PR_BODY=""

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) TARGET="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --branch) BRANCH="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --testbed-dir) TESTBED_DIR="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --testbed-ref) TESTBED_REF="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --testbed-repo) TESTBED_REPO="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --target-url) TARGET_URL="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --base) BASE="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --allow-unrecorded) ALLOW_UNRECORDED=1; shift ;;
      --open-pr) OPEN_PR=1; shift ;;
      --pr-title) PR_TITLE="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --pr-body) PR_BODY="${2:-}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
      --dry-run) MODE="preflight"; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1 (run --help)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Pre-flight — ALL READS. Every precondition this script depends on is checked
# HERE, before anything is created, so an access problem is reported as a
# refusal with a remedy rather than discovered as a failed push half way
# through. Sets the resolved globals the push step then uses.
# ---------------------------------------------------------------------------
SOURCE_KIND=""
SOURCE_REPO=""
TESTBED_SHA=""

preflight() {
  command -v git >/dev/null 2>&1 || die "git not found on PATH"
  command -v jq >/dev/null 2>&1 || die "jq not found on PATH (needed to read the testbed artifact record)"

  [ -n "$TARGET" ] || die "--to <owner>/<name> is required — promotion never infers the target repository from the current directory"
  is_owner_name "$TARGET" || die "--to must be exactly \"<owner>/<name>\", got: $TARGET"
  validate_branch_name "$BRANCH" "--branch"

  # --- the testbed checkout -------------------------------------------------
  git -C "$TESTBED_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "--testbed-dir '$TESTBED_DIR' is not a git working tree (run /promote from inside the testbed checkout, or pass --testbed-dir)"

  if [ -z "$TESTBED_REPO" ]; then
    local origin_url
    origin_url="$(git -C "$TESTBED_DIR" remote get-url origin 2>/dev/null || true)"
    TESTBED_REPO="$(slug_from_remote "$origin_url")"
    [ -n "$TESTBED_REPO" ] \
      || die "cannot resolve the testbed's owner/name from '$TESTBED_DIR''s origin remote (${origin_url:-none configured}) — pass --testbed-repo <owner>/<name> explicitly"
  fi
  is_owner_name "$TESTBED_REPO" || die "--testbed-repo must be exactly \"<owner>/<name>\", got: $TESTBED_REPO"

  TESTBED_SHA="$(git -C "$TESTBED_DIR" rev-parse --verify "$TESTBED_REF^{commit}" 2>/dev/null || true)"
  [ -n "$TESTBED_SHA" ] \
    || die "--testbed-ref '$TESTBED_REF' does not resolve to a commit in '$TESTBED_DIR'"

  [ "$TESTBED_REPO" != "$TARGET" ] \
    || die "the testbed and the target repository are the same ($TARGET) — promotion carries work OUT of a testbed, so refusing rather than pushing a repo into itself"

  # --- the source-kind refusal, READ from the artifact record --------------
  local entries entry
  entries="$(testbed_record_list "$TESTBED_REPO")" \
    || die "could not read the testbed artifact record (see the message above)"
  entry="$(printf '%s' "$entries" | jq -c '.[-1] // empty')"

  if [ -z "$entry" ]; then
    if [ "$ALLOW_UNRECORDED" -eq 1 ]; then
      note "  ! no artifact record for $TESTBED_REPO on this machine — proceeding under --allow-unrecorded; the source-kind refusal could NOT be evaluated"
      SOURCE_KIND="unrecorded"
      SOURCE_REPO=""
    else
      die "no artifact record for $TESTBED_REPO in $(testbed_record_file) — this machine has no record of creating that testbed, so promotion cannot confirm it is promotable. Re-run on the machine that created it, or pass --allow-unrecorded to proceed without the source-kind check."
    fi
  else
    SOURCE_KIND="$(printf '%s' "$entry" | jq -r '.source_kind // "unknown"')"
    SOURCE_REPO="$(printf '%s' "$entry" | jq -r '.source_repo // ""')"
    local promotable
    promotable="$(printf '%s' "$entry" | jq -r '.promotable')"

    if [ "$SOURCE_KIND" = "materialize-from-seed" ]; then
      die "refusing to promote $TESTBED_REPO: its recorded source_kind is 'materialize-from-seed', which has no original to promote to. That testbed was materialized from seed content tracked in the temperloop repository into your own account (ADR 0025) — it was never a duplicate of a repository of yours, so there is no upstream for these commits to land in. Promotion applies to a 'mirror-from-repo' testbed only."
    fi
    if [ "$promotable" = "false" ]; then
      die "refusing to promote $TESTBED_REPO: its artifact record says promotable=false (source_kind '$SOURCE_KIND'). The record, not this script, is the authority on whether a testbed has an original to promote to."
    fi
    if [ -n "$SOURCE_REPO" ] && [ "$SOURCE_REPO" != "$TARGET" ]; then
      note "  ! the record says this testbed was mirrored from $SOURCE_REPO, but --to names $TARGET — promoting across repositories, which is allowed but rarely intended"
    fi
  fi

  # --- the target repository ------------------------------------------------
  [ -n "$TARGET_URL" ] || TARGET_URL="https://github.com/${TARGET}.git"

  local symref
  if ! symref="$(git ls-remote --symref "$TARGET_URL" HEAD 2>&1)"; then
    die "cannot reach the target repository at $TARGET_URL — check it exists and that your git credentials can read it: $symref"
  fi

  if [ -z "$BASE" ]; then
    BASE="$(printf '%s\n' "$symref" | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n 1)"
    [ -n "$BASE" ] \
      || die "could not resolve $TARGET's base branch from its HEAD symref — pass --base <branch> explicitly rather than let promotion guess which branch it must not push"
  fi
  validate_branch_name "$BASE" "--base"

  [ "$BRANCH" != "$BASE" ] \
    || die "--branch '$BRANCH' is the target's base branch — promotion opens a pull request, it never pushes to $TARGET's default branch"

  local existing
  existing="$(git ls-remote --heads "$TARGET_URL" "refs/heads/$BRANCH" 2>/dev/null || true)"
  [ -z "$existing" ] \
    || die "refs/heads/$BRANCH already exists on $TARGET — choose another --branch. This script never force-pushes, so it will not overwrite a branch someone else may be using."

  # --- the access precondition, checked HERE and not at failure time -------
  check_access

  cat <<EOF
promote plan
  testbed        $TESTBED_REPO  (dir: $TESTBED_DIR)
  source kind    $SOURCE_KIND${SOURCE_REPO:+  (mirrored from $SOURCE_REPO)}
  ref            $TESTBED_REF -> $TESTBED_SHA
  target repo    $TARGET
  target url     $TARGET_URL
  base branch    $BASE  (never pushed)
  push refspec   refs/promote/source:refs/heads/$BRANCH
EOF
}

# ---------------------------------------------------------------------------
# check_access — the branch-create/push precondition on the target, with its
# fallback documented in the refusal itself rather than left to be discovered
# when the push is rejected.
# ---------------------------------------------------------------------------
check_access() {
  if ! command -v gh >/dev/null 2>&1; then
    die "gh CLI not found on PATH, so promotion cannot confirm you may create a branch on $TARGET before it tries. Install gh and run 'gh auth login'. Fallback if you cannot: fork $TARGET, re-run with --to <your-fork>, and open the pull request from the fork."
  fi
  if ! gh auth status >/dev/null 2>&1; then
    die "gh is not authenticated, so promotion cannot confirm you may create a branch on $TARGET before it tries. Run 'gh auth login'. Fallback if you cannot: fork $TARGET, re-run with --to <your-fork>, and open the pull request from the fork."
  fi

  local perm
  if ! perm="$(gh api "repos/$TARGET" --jq '.permissions.push // empty' 2>/dev/null)"; then
    die "gh could not read $TARGET's permissions (repository missing, or your token cannot see it), so the branch-create precondition cannot be confirmed. Fallback: fork $TARGET, re-run with --to <your-fork>, and open the pull request from the fork."
  fi
  if [ "$perm" != "true" ]; then
    die "your account cannot push to $TARGET (permissions.push is '${perm:-unset}'), so a promotion branch cannot be created there. Fallback: run 'gh repo fork $TARGET', re-run this with --to <your-fork> --branch $BRANCH, and open the pull request from the fork into $TARGET."
  fi
  note "  ok access: gh reports push permission on $TARGET"
}

# ---------------------------------------------------------------------------
# provenance_line — the one-line note every pull request this script opens
# carries. Owned here, not by a prose step, so it cannot be forgotten: a
# reviewer with no context on this process has to be able to tell, from the
# pull request alone, that these commits came out of a temperloop evaluation
# testbed rather than out of nowhere.
# ---------------------------------------------------------------------------
provenance_line() {
  printf 'Promoted from the temperloop evaluation testbed %s (%s) at %s — these are the testbed'"'"'s own commits and authorship, transferred as-is, not a rebuilt diff.\n' \
    "$TESTBED_REPO" "$SOURCE_KIND" "$TESTBED_SHA"
}

# ---------------------------------------------------------------------------
# do_push — the ONE push in this file. Everything happens in a throwaway bare
# repository: the testbed is added as a remote THERE and fetched, so neither
# the testbed checkout nor any checkout of the target repository has its
# remotes or HEAD touched.
# ---------------------------------------------------------------------------
do_push() {
  local work out
  work="$(mktemp -d "${TMPDIR:-/tmp}/promote-push-XXXXXX")" \
    || die "could not create a temp working directory"

  # shellcheck disable=SC2064  # $work is intentionally expanded now, not later.
  trap "rm -rf '$work'" EXIT

  git init -q --bare "$work" || die "could not initialise the transfer workspace at $work"

  # Add the testbed as a remote and FETCH its real objects. A fetch transfers
  # commits verbatim — messages, parents, author and committer identities all
  # survive, which is the entire reason promotion does this instead of
  # replaying a files manifest.
  git -C "$work" remote add testbed "$(cd "$TESTBED_DIR" && pwd)" \
    || die "could not add the testbed as a remote in the transfer workspace"
  if ! out="$(git -C "$work" fetch --no-tags testbed "+${TESTBED_REF}:refs/promote/source" 2>&1)"; then
    die "fetching $TESTBED_REF from the testbed failed: $out"
  fi
  note "  ok fetched $TESTBED_REF from $TESTBED_REPO -> refs/promote/source ($TESTBED_SHA)"

  # Best-effort: how far ahead of the base this is, for the report. A failure
  # here is never fatal — it is reporting, not a precondition.
  local ahead=""
  if git -C "$work" fetch --no-tags "$TARGET_URL" "+refs/heads/${BASE}:refs/promote/base" >/dev/null 2>&1; then
    ahead="$(git -C "$work" rev-list --count refs/promote/base..refs/promote/source 2>/dev/null || true)"
  fi

  # THE push. One refspec, spelled out in full, every time.
  if ! out="$(git -C "$work" push "$TARGET_URL" "refs/promote/source:refs/heads/$BRANCH" 2>&1)"; then
    die "pushing refs/heads/$BRANCH to $TARGET failed: $out"
  fi
  note "  ok pushed refs/heads/$BRANCH to $TARGET at $TESTBED_SHA${ahead:+ (${ahead} commit(s) ahead of $BASE)}"

  if [ "$OPEN_PR" -eq 1 ]; then
    open_pr
  else
    note ""
    note "Branch pushed. Open the pull request with the provenance note:"
    note "  $(provenance_line)"
  fi
}

open_pr() {
  local title body out
  if [ -n "$PR_TITLE" ]; then title="$PR_TITLE"; else title="$BRANCH"; fi
  if [ -n "$PR_BODY" ]; then
    body="$(printf '%s\n\n---\n%s' "$PR_BODY" "$(provenance_line)")"
  else
    body="$(provenance_line)"
  fi
  if ! out="$(gh pr create --repo "$TARGET" --head "$BRANCH" --base "$BASE" \
    --title "$title" --body "$body" 2>&1)"; then
    die "pushed refs/heads/$BRANCH, but opening the pull request failed: $out. The branch is on $TARGET — open the pull request by hand and include: $(provenance_line)"
  fi
  note "  ok opened pull request: $out"
}

# ---------------------------------------------------------------------------
main() {
  [ $# -gt 0 ] || { usage; exit 2; }
  case "$1" in
    preflight | push) MODE="$1"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown subcommand: $1 (expected 'preflight' or 'push')" ;;
  esac

  local requested="$MODE"
  parse_args "$@"
  # --dry-run downgrades `push` to `preflight`; it can never upgrade.
  [ "$MODE" = "preflight" ] || MODE="$requested"

  preflight
  if [ "$MODE" = "preflight" ]; then
    note ""
    note "Pre-flight only — nothing was pushed. Re-run with 'push' to carry these commits over."
    return 0
  fi
  do_push
}

main "$@"
