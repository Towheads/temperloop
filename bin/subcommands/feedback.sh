#!/usr/bin/env bash
# description: consent-gated feedback submission -- opens a GitHub issue on the kernel's own tracker; distinct from `report`'s local metrics renderer
#
# feedback.sh -- `temperloop feedback`: a way to SEND feedback to the kernel
# maintainers, as opposed to `foundation report` (kernel/bin/subcommands/
# report.sh), which only ever RENDERS a stranger's own local before/after
# metrics and never transmits anything anywhere. The two are deliberately
# separate subcommands with separate names precisely so neither is mistaken
# for the other (temperloop#428).
#
# THIS SCRIPT PERFORMS AN EXTERNAL-SYSTEM WRITE (a `gh issue create` against
# the kernel's own tracker) -- the one class of action in this CLI that
# leaves the operator's machine. Per the kernel's own severity taxonomy, an
# external-system write with no live operator present is `blocking-now`: it
# is NEVER auto-taken, and a timeout or a flag can never substitute for a
# real human answering a real prompt. Concretely:
#
#   1. COMPOSE  -- collect the feedback message (via --message/--file, or an
#      interactive multi-line prompt) plus a small amount of non-sensitive
#      local context (temperloop version, sanitized git origin, OS/bash
#      version) into ONE payload artifact file.
#   2. LEAK-SCAN -- run the SAME personal/org-token denylist RULESET that
#      guards this repo's own kernel file set
#      (workflows/scripts/kernel/personal-token-denylist.tsv, the shared
#      source of truth check-personal-token-denylist.sh and
#      check-pr-leak-guard.sh both read) against the COMPOSED PAYLOAD FILE
#      itself -- not "the repo's gates pass" (those never see this payload
#      at all). A hit blocks transmission outright and names the matching
#      pattern; nothing is sent.
#   3. PREVIEW  -- print the exact payload bytes to the terminal.
#   4. CONSENT  -- require an explicit, interactively-typed "y" at a real
#      prompt. There is NO --yes / auto-confirm flag for this step, by
#      design: a flag baked into an unattended invocation would itself be a
#      standing "consent", which is exactly the failure mode this guards
#      against. A closed/non-TTY stdin, or an unattended-environment signal
#      (CI=true / GITHUB_ACTIONS=true), refuses to transmit with a legible
#      message and exits 0 -- the payload was composed and shown, nothing
#      was sent, and re-running interactively is how to actually send it.
#   5. TRANSMIT -- only after (2) passed and (4) was answered "yes": ensure
#      a `feedback` label exists on the target repo (best-effort, mirrors
#      workflows/scripts/board/lib/board.sh's _board_issues_ensure_label
#      idiom) and `gh issue create` the payload. Degrades legibly (a clear
#      stderr message + non-zero exit, still nothing sent) if `gh` is
#      missing or unauthenticated.
#
# DISPATCH MODEL: a discovered subcommand, same as every sibling in this
# directory -- this file's mere presence at bin/subcommands/feedback.sh IS
# `temperloop feedback`.
#
# Usage:
#   feedback.sh [--type bug|idea|question|other] [--message TEXT] [--file PATH] [--dry-run] [-h|--help]
#
#   --type TYPE    one of bug|idea|question|other (default: general).
#   --message TEXT / -m TEXT
#                  the feedback text. If omitted and stdin is a TTY, prompts
#                  interactively (end with a line containing only ".").  If
#                  omitted and stdin is not a TTY, this is a usage error --
#                  there is nothing to compose.
#   --file PATH    read the feedback text from PATH instead of --message.
#   --dry-run      compose + leak-scan + preview, then stop -- never prompts,
#                  never transmits, always exits 0. Useful to see exactly
#                  what would be sent.
#
# Exit codes:
#   0  either sent successfully, or a legible non-transmission (operator
#      declined, no live operator detected, --dry-run).
#   1  leak-scan blocked the payload, or a live-operator transmit attempt
#      failed (gh missing/unauthenticated, or the `gh issue create` call
#      itself failed).
#   2  invalid CLI usage / nothing to compose.
#
# Env overrides (test seams):
#   TEMPERLOOP_FEEDBACK_REPO             target repo (default: below)
#   TEMPERLOOP_FEEDBACK_DENYLIST_FILE    denylist tsv (default: sibling kernel copy)
#   TEMPERLOOP_FEEDBACK_ASSUME_TTY=1     treat stdin as attended even when it
#                                        isn't a real TTY -- ONLY affects the
#                                        TTY half of the attended check; the
#                                        CI/GITHUB_ACTIONS unattended signal
#                                        still refuses regardless. A test-only
#                                        seam (see bin/subcommands/tests/
#                                        test_feedback.sh), not a bypass of
#                                        the consent step itself -- an actual
#                                        "y" still has to arrive on stdin.
#
# Kept bash-3.2 friendly (macOS default shell) -- no mapfile/associative arrays.

set -uo pipefail

SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUBCOMMAND_DIR/../.." && pwd)"

: "${TEMPERLOOP_FEEDBACK_DENYLIST_FILE:=$REPO_ROOT/workflows/scripts/kernel/personal-token-denylist.tsv}"
# The kernel repo's own upstream feedback target -- its identity, the same
# category-1 "this repo's own real value" rationale as try.sh's demo-repo
# default and bootstrap.sh's clone URL (see those files' own markers).
FEEDBACK_TARGET_REPO="${TEMPERLOOP_FEEDBACK_REPO:-Towheads/temperloop}"  # denylist:allow — the kernel repo's own upstream feedback target (its identity, same category-1 rationale as try.sh's demo-repo default)
# TEMPERLOOP_VERSION is canonical (renamed from FOUNDATION_VERSION in
# v0.14.0, temperloop#165); the legacy name is read as a fallback through
# the window and removed in v0.16.0.
TEMPERLOOP_VERSION="${TEMPERLOOP_VERSION:-${FOUNDATION_VERSION:-dev}}"

usage() {
  cat <<'EOF'
usage: feedback.sh [--type bug|idea|question|other] [--message TEXT] [--file PATH] [--dry-run]

Sends feedback to the kernel maintainers via a GitHub issue -- distinct from
`temperloop report`, which only ever renders your own local metrics and
never transmits anything. Nothing is ever sent without an explicit,
interactively-typed "yes" at a real prompt, after you've seen the exact
payload; an unattended/non-interactive run never transmits.

  --type TYPE      bug|idea|question|other (default: general)
  --message TEXT   feedback text (or -m TEXT)
  --file PATH      read feedback text from PATH
  --dry-run        compose + leak-scan + preview only; never prompts or sends
  -h, --help       this help
EOF
}

feedback_type="general"
message=""
message_file=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --type) feedback_type="${2:?--type needs a value}"; shift 2 ;;
    --message|-m) message="${2:?--message needs a value}"; shift 2 ;;
    --file) message_file="${2:?--file needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "feedback.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$feedback_type" in
  bug|idea|question|other|general) : ;;
  *) echo "feedback.sh: --type must be one of bug|idea|question|other" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Resolve the feedback message: --file, else --message, else (TTY only) an
# interactive multi-line prompt terminated by a lone "." line or EOF. A
# non-interactive run with neither flag has nothing to compose -- a usage
# error, not a consent decision.
# ---------------------------------------------------------------------------
if [ -n "$message_file" ]; then
  [ -f "$message_file" ] || { echo "feedback.sh: --file '$message_file' not found" >&2; exit 2; }
  message="$(cat "$message_file")"
fi

if [ -z "$message" ] && [ -t 0 ]; then
  echo "Describe your feedback (end with a line containing only '.', or Ctrl-D):" >&2
  while IFS= read -r _fb_line; do
    [ "$_fb_line" = "." ] && break
    if [ -z "$message" ]; then message="$_fb_line"; else message="$message
$_fb_line"; fi
  done
fi

if [ -z "$message" ]; then
  echo "feedback.sh: no feedback message provided -- pass --message/-m or --file (nothing to compose in a non-interactive run)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Compose the payload artifact -- one self-contained file, so the leak-scan
# below and the preview step both operate on exactly the bytes that would
# transmit. Local-only, zero network: the repo context comes from `git
# remote`, never `gh repo view`, so composing/leak-scanning/previewing a
# payload never itself makes a network call.
# ---------------------------------------------------------------------------
repo_context="(not run inside a git checkout)"
if git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _fb_origin="$(git -C "$PWD" remote get-url origin 2>/dev/null || true)"
  if [ -n "$_fb_origin" ]; then
    # Strip any embedded userinfo (https://user:token@host/... -> https://host/...)
    # before this ever lands in a composed payload.
    repo_context="$(printf '%s' "$_fb_origin" | sed -E 's#^(https?://)[^@/]+@#\1#')"
  else
    repo_context="(no origin remote)"
  fi
fi

os_context="$(uname -sm 2>/dev/null || echo unknown)"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

PAYLOAD_FILE="$(mktemp "${TMPDIR:-/tmp}/temperloop-feedback.XXXXXX")"
# Invoked indirectly via `trap ... EXIT` below -- same idiom (and same
# false-positive) as archive-plan.sh's populate_plan.
# shellcheck disable=SC2317,SC2329
cleanup() { rm -f "$PAYLOAD_FILE"; }
trap cleanup EXIT

{
  echo "## temperloop feedback ($feedback_type)"
  echo
  echo "$message"
  echo
  echo "---"
  echo "temperloop version: $TEMPERLOOP_VERSION"
  echo "source repo (git origin, sanitized): $repo_context"
  echo "platform: $os_context (bash ${BASH_VERSION:-unknown})"  # knob:exempt — BASH_VERSION is a bash builtin special variable, never an operator default
  echo "composed: $ts"
} > "$PAYLOAD_FILE"

# ---------------------------------------------------------------------------
# Leak-scan -- the SAME personal/org-token denylist RULESET as
# check-personal-token-denylist.sh / check-pr-leak-guard.sh (single source
# of truth: personal-token-denylist.tsv), applied to this one payload file.
# A line carrying the same `# denylist:allow` suppression marker those
# scripts honor is skipped here too, for the same reason (a genuinely
# load-bearing literal, not an oversight) -- see that file's own header.
# ---------------------------------------------------------------------------
_feedback_leak_scan() {
  local file="$1" denylist="$2"
  if [ ! -f "$denylist" ]; then
    echo "feedback.sh: denylist not found at $denylist -- refusing to scan (fail closed)" >&2
    return 2
  fi

  local patterns=() descriptions=()
  while IFS=$'\t' read -r pat desc; do
    [ -z "${pat:-}" ] && continue
    case "$pat" in \#*) continue ;; esac
    patterns+=("$pat")
    descriptions+=("$desc")
  done < "$denylist"

  if [ "${#patterns[@]}" -eq 0 ]; then
    echo "feedback.sh: denylist has zero entries -- refusing to scan (fail closed)" >&2
    return 2
  fi

  local violations=0 i pat hit lineno line
  for i in "${!patterns[@]}"; do
    pat="${patterns[$i]}"
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      lineno="${hit%%:*}"
      line="${hit#*:}"
      case "$line" in *denylist:allow*) continue ;; esac
      printf 'LEAK  payload:%s: [%s] %s\n    %s\n' "$lineno" "$pat" "${descriptions[$i]}" "$line"
      violations=$((violations + 1))
    done < <(grep -nE -- "$pat" "$file" 2>/dev/null || true)
  done

  [ "$violations" -eq 0 ]
}

echo "-- Leak-scan (personal-token-denylist RULESET) --"
leak_out="$(_feedback_leak_scan "$PAYLOAD_FILE" "$TEMPERLOOP_FEEDBACK_DENYLIST_FILE")"
leak_rc=$?
if [ "$leak_rc" -eq 2 ]; then
  echo "feedback.sh: leak-scan could not run -- $leak_out" >&2
  exit 1
elif [ "$leak_rc" -ne 0 ]; then
  echo "feedback.sh: BLOCKED -- leak-scan found personal/org token(s) in the composed payload:" >&2
  printf '%s\n' "$leak_out" >&2
  echo "feedback.sh: fix the flagged content (edit your message) and re-run. Nothing was transmitted." >&2
  exit 1
fi
echo "feedback.sh: leak-scan OK -- 0 denylist hits in the composed payload"
echo

# ---------------------------------------------------------------------------
# Preview -- the exact bytes that would transmit.
# ---------------------------------------------------------------------------
echo "-- Preview -- exactly what would be sent to $FEEDBACK_TARGET_REPO --"
cat "$PAYLOAD_FILE"
echo
echo "-- end preview --"
echo

if [ "$dry_run" -eq 1 ]; then
  echo "feedback.sh: dry run -- nothing transmitted"
  exit 0
fi

# ---------------------------------------------------------------------------
# Attended check -- the consent gate's precondition. A closed/non-TTY stdin,
# or an unattended-environment signal, refuses outright: timeout is not
# consent, and there is no flag that overrides this.
# ---------------------------------------------------------------------------
_feedback_attended() {
  case "${CI:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # knob:exempt — standard CI-ecosystem ambient signal, not an operator default this repo defines
  case "${GITHUB_ACTIONS:-}" in [Tt]rue|1|[Yy]es) return 1 ;; esac  # knob:exempt — GitHub Actions' own ambient signal, not an operator default this repo defines
  if [ -t 0 ]; then return 0; fi
  [ "${TEMPERLOOP_FEEDBACK_ASSUME_TTY:-0}" = "1" ] && return 0
  return 1
}

if ! _feedback_attended; then
  echo "feedback.sh: refusing to transmit -- no interactive operator detected (no TTY, or an unattended/CI environment signal is set)." >&2
  echo "feedback.sh: a timeout or a flag is never consent for an external write. Nothing was sent." >&2
  echo "feedback.sh: re-run this interactively to actually send the payload shown above." >&2
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "feedback.sh: 'gh' (GitHub CLI) not found on PATH -- cannot send feedback." >&2
  echo "  Install: https://cli.github.com" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "feedback.sh: 'gh' is installed but not authenticated -- cannot send feedback." >&2
  echo "  Run: gh auth login" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Consent -- an explicit, interactively-typed "y" at a real prompt. No
# --yes / auto-confirm flag exists for this step (see header comment).
# ---------------------------------------------------------------------------
printf 'Send this feedback to %s? [y/N] ' "$FEEDBACK_TARGET_REPO"
ans=""
read -r ans || ans=""
case "$ans" in
  y|Y|yes|YES) : ;;
  *) echo "feedback.sh: declined -- nothing sent"; exit 0 ;;
esac
echo

# ---------------------------------------------------------------------------
# Transmit -- best-effort label ensure (mirrors board.sh's
# _board_issues_ensure_label idiom), then gh issue create.
# ---------------------------------------------------------------------------
gh label create "feedback" -R "$FEEDBACK_TARGET_REPO" --color "c2e0c6" \
  --description "Feedback submitted via 'temperloop feedback'" >/dev/null 2>&1 || true

title="temperloop feedback ($feedback_type): $(printf '%s' "$message" | head -n1 | cut -c1-80)"

if url="$(gh issue create -R "$FEEDBACK_TARGET_REPO" --title "$title" --body-file "$PAYLOAD_FILE" --label "feedback" 2>&1)"; then
  echo "feedback.sh: sent -- $url"
  exit 0
else
  echo "feedback.sh: transmit failed:" >&2
  printf '%s\n' "$url" >&2
  exit 1
fi
