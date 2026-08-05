#!/usr/bin/env bash
#
# Fake `gh` for the board-adapter tests — shared replay component.
#
# TWO ACCESS POINTS (Contract version: argv-log-v1):
#
#   1. PATH-binary form (executed as `gh`):
#      Set GH_LOG + GH_FIXTURES, place this file on PATH as `gh`.
#      Records argv + emits canned fixture JSON for read subcommands.
#
#   2. In-process sourced form:
#      FAKE_GH_SOURCE=1 source fake_gh.sh
#      Defines _fake_gh_log_argv for use by _board_gh overrides in test files,
#      without any exec-time side-effects. Tests call:
#        _fake_gh_log_argv "$@" >>"$CALLS"
#      to record argv using the canonical shell-quoted format (argv-log-v1).
#
# TWO JOBS in PATH-binary form:
#   1) record this invocation's full argv (one shell-quoted line) to $GH_LOG,
#      so a test can diff the OLD vs NEW board call sequences;
#   2) emit canned fixture JSON for the read subcommands, so the scripts run
#      end-to-end with zero network.
#
# ISSUES-ONLY (ADR 0004). The PATH-binary form speaks the issues-only REST/CLI
# verbs the board adapter actually uses — `gh issue create/list/edit/close/reopen`,
# `gh api repos/<owner>/<repo>/issues/<n>`, `gh label create`. The former
# Projects-v2 routes (`gh project …`, `gh api graphql`) are now HARD ERRORS
# rather than canned responses: with that arm removed, any script reaching them
# is a regression, and failing loudly here is what surfaces it. That makes this
# fixture a guard as well as a stand-in.
#
# It still understands both output styles the scripts use:
#   - `--format json` / `--json <fields>`  (caller pipes to its own jq)
#   - `-q <filter>` / `--jq <filter>`      (gh applies the jq filter)
#
# NOTE: `test_capture.sh` is the ONLY consumer of this PATH-binary form; every
# other board test sources this file for `_fake_gh_log_argv` alone
# (FAKE_GH_SOURCE=1) and is unaffected by the routing below.
#
# Env (PATH-binary form only):
#   GH_LOG        path to append the argv transcript to (required)
#   GH_FIXTURES   dir holding the canned JSON fixtures

# ---------------------------------------------------------------------------
# Sourceable helper — the ONE owner of the argv-log-v1 quoting logic.
# Both access points converge here; zero inline copies elsewhere.
# ---------------------------------------------------------------------------

# _fake_gh_log_argv "$@"
#   Prints one shell-quoted line to stdout: `gh <q-arg1> <q-arg2> ...\n`
#   Callers redirect to their log file:  _fake_gh_log_argv "$@" >>"$CALLS"
_fake_gh_log_argv() {
  printf 'gh'
  local a
  for a in "$@"; do printf ' %q' "$a"; done
  printf '\n'
}

# When sourced (FAKE_GH_SOURCE=1), stop here — only the helper is needed.
[ "${FAKE_GH_SOURCE:-}" = "1" ] && return 0

# ---------------------------------------------------------------------------
# PATH-binary form (executed as `gh`)
# ---------------------------------------------------------------------------
set -euo pipefail

FIX="${GH_FIXTURES:?fake_gh needs GH_FIXTURES}"
LOG="${GH_LOG:?fake_gh needs GH_LOG}"

# --- record argv (shell-quoted, one line) — uses the shared helper ----------
_fake_gh_log_argv "$@" >>"$LOG"

# --- helpers ----------------------------------------------------------------
# Pull the value of `-q <filter>` out of the argv, if present. Echoes the
# filter on stdout and returns 0; returns 1 when there is no -q.
extract_q() {
  local prev=""
  local a
  for a in "$@"; do
    if [ "$prev" = "-q" ] || [ "$prev" = "--jq" ]; then printf '%s' "$a"; return 0; fi
    prev="$a"
  done
  return 1
}

# Emit a fixture file, applying gh's own -q jq filter if the caller passed one.
emit() {
  local fixture="$1"; shift
  local q
  if q="$(extract_q "$@")"; then
    jq -r "$q" "$FIX/$fixture"
  else
    cat "$FIX/$fixture"
  fi
}

# --- route by subcommand ----------------------------------------------------
sub="${1:-}"
case "$sub" in
  project)
    # The Projects-v2 arm was REMOVED (ADR 0004). Nothing may build this argv.
    echo "fake_gh: REGRESSION — a script built a 'gh project' argv, but the Projects-v2 arm was removed (ADR 0004): $*" >&2
    exit 3
    ;;
  issue)
    icmd="${2:-}"
    case "$icmd" in
      create) printf 'https://github.com/Towheads/stageFind/issues/999\n' ;;
      list)
        # Whole-board read on the issues-only path. Serve issue_list.json when
        # provided; otherwise an empty set, which is a valid board.
        if [ -f "$FIX/issue_list.json" ]; then emit issue_list.json "$@"; else printf '[]\n'; fi
        ;;
      view)
        # Serve issue_view.json if present in the fixture dir; fall back to a
        # minimal synthetic issue so `gh issue view <N> --json ...` never hard-
        # errors in a scenario that has not provided the fixture.
        if [ -f "$FIX/issue_view.json" ]; then
          emit issue_view.json "$@"
        else
          printf '{"number":0,"title":"(fake issue)","body":"","labels":[],"url":""}\n'
        fi
        ;;
      edit | close | reopen) : ;;            # write: record only (logged above)
      *) echo "fake_gh: unhandled issue subcommand: $icmd" >&2; exit 3 ;;
    esac
    ;;
  api)
    case "${2:-}" in
      graphql)
        echo "fake_gh: REGRESSION — a script built a 'gh api graphql' argv; the tracking flow issues no GraphQL call (ADR 0004): $*" >&2
        exit 3
        ;;
      repos/*/issues/*)
        # The single-issue read every issues-only resolve/write does first.
        # Serve issue_api.json when provided; else a synthetic OPEN, unlabeled
        # issue — the state a freshly-created capture target is actually in.
        if [ -f "$FIX/issue_api.json" ]; then
          emit issue_api.json "$@"
        else
          printf '{"number":999,"title":"(fake issue)","body":"","state":"open","labels":[]}\n'
        fi
        ;;
      repos/*/milestones*)
        if [ -f "$FIX/milestones.json" ]; then emit milestones.json "$@"; else printf '[]\n'; fi
        ;;
      *) echo "fake_gh: unhandled api subcommand: ${2:-}" >&2; exit 3 ;;
    esac
    ;;
  label)
    lcmd="${2:-}"
    case "$lcmd" in
      create) : ;;                           # write: record only (logged above)
      *) echo "fake_gh: unhandled label subcommand: $lcmd" >&2; exit 3 ;;
    esac
    ;;
  *) echo "fake_gh: unhandled subcommand: $sub" >&2; exit 3 ;;
esac
