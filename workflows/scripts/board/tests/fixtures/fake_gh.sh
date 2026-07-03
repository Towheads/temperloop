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
# It deliberately understands BOTH gh calling styles the scripts use:
#   - `gh project ... --format json`            (caller pipes to its own jq)
#   - `gh project ... --format json -q <filter>` (gh applies the jq filter)
# so it can stand in for the pre-refactor capture.sh (which used -q) and the
# post-refactor scripts (which jq locally) without either noticing a difference.
#
# Env (PATH-binary form only):
#   GH_LOG        path to append the argv transcript to (required)
#   GH_FIXTURES   dir holding project_view.json / field_list.json / item_list.json

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
    pcmd="${2:-}"
    case "$pcmd" in
      view)       emit project_view.json "$@" ;;
      field-list) emit field_list.json "$@" ;;
      item-list)  emit item_list.json "$@" ;;
      item-add)   : ;;                       # write: record only (logged above)
      item-edit)  : ;;                       # write: record only
      *) echo "fake_gh: unhandled project subcommand: $pcmd" >&2; exit 3 ;;
    esac
    ;;
  issue)
    icmd="${2:-}"
    case "$icmd" in
      create) printf 'https://github.com/Towheads/stageFind/issues/999\n' ;;
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
      *) echo "fake_gh: unhandled issue subcommand: $icmd" >&2; exit 3 ;;
    esac
    ;;
  api)
    # board_resolve_item's single-issue GraphQL lookup (`gh api graphql ...`).
    case "${2:-}" in
      graphql) emit issue_project_item.json "$@" ;;
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
