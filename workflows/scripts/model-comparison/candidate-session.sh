#!/usr/bin/env bash
#
# candidate-session.sh — the restricted candidate-model session spawner and
# provider-key health check (temperloop#1252, epic #1225 "model comparison
# harness"). This is the ONE reusable host-supply seam for every non-default-
# provider credential in this plan: `replay-execute-and-score` and
# `judge-rotation-mode` both route their candidate/rotated-judge spawns
# through this script rather than re-implementing the check — see this
# plan item's own `notes` field in the epic's plan note.
#
# ── THE TWO STRUCTURAL GUARANTEES THIS FILE OWNS ────────────────────────────
#
#   1. CONTAINMENT. A candidate-model session runs under candidate.settings.json
#      (--settings), a deny-over-allow permission overlay (same convention as
#      the sibling workflows/scripts/build/pipeline-drive.settings.json —
#      deny wins over allow) that removes every knowledge-store/vault MCP
#      tool (mcp__obsidian__*, mcp__obsidian-builtin__*, plus the personal
#      mcp__things__* surface) and every path/command reaching the
#      host-secrets file (workflows/scripts/build/build.config.local.sh, and
#      its .env-shaped siblings) from the reachable tool surface — denied
#      both as a direct Read/Edit target and as a Bash command substring, so
#      `cat`/`less`/`grep`-style indirection through the broadly-allowed Bash
#      tool is blocked too. JSON carries no comments, so this file is that
#      overlay's documentation of record. `resolve` below is a REAL
#      deny-over-allow glob matcher against the JSON (not a grep for key
#      presence), so a fixture can assert the EFFECTIVE surface a candidate
#      session actually reaches, not merely that the JSON documents an intent
#      to narrow it.
#
#   2. KEY ISOLATION. `preflight` fails LOUDLY, at pre-flight, naming the exact
#      env var AND the concrete host-supply file, when a non-default
#      provider's key is unset — a runtime health check, never a silent
#      no-op. (This item exists because a sibling project once shipped wiring
#      that only NAMED where a token should go without gating on whether it
#      was set, and that ran as a silent no-op for ~19 hours — the bar here is
#      "confirmed set", not "location named".) `spawn` then scopes the
#      resolved key to the ONE spawned `claude` child process via
#      `env VAR=value <bin> …` — it is never `export`ed into this script's own
#      shell beyond that single spawn line, so it can never reach a LATER
#      subprocess this script (or its caller) launches, and `spawn` never
#      captures or relays the child's own stdio, so there is nothing here for
#      the key to leak into.
#
# ── NEVER SOURCE THIS FILE ───────────────────────────────────────────────────
# It is a script, always invoked as a subprocess (`bash candidate-session.sh
# …`), exactly like the sibling machinery scripts in workflows/scripts/build/
# (worktree.sh, pipeline-retro-judge-spawn.sh). Sourcing it would run its CLI
# dispatch against the SOURCING script's own "$@", and — more importantly —
# would leave any resolved provider key `export`ed (via build.config.local.sh's
# own `:=`-then-`export` idiom, sourced below) into the CALLER's shell, which
# is exactly the parent-process leak guarantee #2 above exists to prevent.
# Running as a subprocess is what makes "not exported into the parent
# process" true by construction: a child process's environment can never
# write back into its parent's.
#
# ── THE DEFAULT PATH IS A NO-OP ─────────────────────────────────────────────
# With no candidate provider selected (provider "anthropic", or omitted),
# `preflight` returns 0 immediately with no env requirement, and `spawn` runs
# the ordinary `claude --settings …` invocation with no key handling at all.
# Nothing here changes /sweep, /build, or /fix's existing default-provider
# behavior — this script has no caller yet (that lands with
# replay-execute-and-score and judge-rotation-mode).
#
# Usage:
#   candidate-session.sh preflight --provider <name>
#       Exit 0, silent — default provider (or provider omitted), or a
#       non-default provider whose key IS set.
#       Exit 1, legible message on stderr — a non-default provider whose key
#       is UNSET, or an unregistered provider name.
#
#   candidate-session.sh resolve <tool-call> [--settings <file>]
#       Prints exactly one of: deny | allow | unspecified — the overlay's
#       resolution for <tool-call>, via deny-over-allow glob matching against
#       the settings JSON (permissions.deny checked first, then
#       permissions.allow), the same precedence Claude Code's own permission
#       engine applies (see candidate.settings.json's own header). <tool-call>
#       is a bare tool name ("Read", "Task"), an MCP tool id
#       ("mcp__obsidian__search_vault_smart"), or a "Tool(argument-string)"
#       form ("Bash(cat some/path)") — whichever shape the matching deny/allow
#       entry itself uses. A bare pattern with no "(" or "*" matches ANY
#       invocation of that tool (Claude Code's own "Read" == "Read on any
#       path" semantics); a pattern carrying "(" or "*" is matched directly,
#       glob-style, against the whole call string.
#
#   candidate-session.sh spawn --provider <name> [--settings <file>] -- <claude args...>
#       Runs `preflight` first (fail-closed: a failed preflight never
#       spawns), then a missing overlay file also refuses to spawn
#       (never runs a candidate session uncontained). Then invokes
#       `${CLAUDE_BIN:-claude} --settings <file> <claude args...>`, with the
#       resolved provider key (non-default provider only) passed via
#       `env VAR=value <bin> …` — visible to that one child process only.
#
# Config (env overrides win; CLAUDE_BIN mirrors the test-double seam name
# every other spawn site in workflows/scripts/build/ already uses):
#   CANDIDATE_SETTINGS   the containment overlay path (default: this
#                        directory's own candidate.settings.json)
#   CLAUDE_BIN           the claude binary / test-double seam (default: claude)
#
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "candidate-session.sh: jq not found" >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the host config ladder OURSELVES (mirrors pipeline-retro-judge-spawn.sh's
# re-derive rationale) — whatever the caller's environment did or did not
# carry, a provider key living in build.config.local.sh reaches THIS process.
# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"

: "${CANDIDATE_SETTINGS:=$HERE/candidate.settings.json}"
: "${CLAUDE_BIN:=claude}"

# ── Provider → required env var (the host-supply seam) ───────────────────────
# The ONE table both the preflight check and spawn's key-scoping read from —
# adding a provider means editing exactly this line. "anthropic" (or an
# empty/unset provider) is the DEFAULT and is handled by the caller BEFORE
# this table is ever consulted (bullet 4) — it carries no entry here.
_CS_PROVIDER_TABLE='openai:OPENAI_API_KEY
google:GEMINI_API_KEY
gemini:GEMINI_API_KEY'

_cs_provider_env_var() {  # $1 = provider name -> prints its env var, or fails
  local p="$1" name var
  while IFS=: read -r name var; do
    [ "$name" = "$p" ] && { printf '%s\n' "$var"; return 0; }
  done <<<"$_CS_PROVIDER_TABLE"
  return 1
}

# candidate_session_preflight <provider>
candidate_session_preflight() {
  local provider="${1:-anthropic}"
  if [ -z "$provider" ] || [ "$provider" = "anthropic" ]; then
    return 0
  fi
  local var
  if ! var="$(_cs_provider_env_var "$provider")"; then
    printf 'candidate-session: unknown provider %s — no env-var mapping registered in candidate-session.sh (_CS_PROVIDER_TABLE)\n' "$provider" >&2
    return 1
  fi
  local val
  val="$(eval "printf '%s' \"\${$var:-}\"")"
  if [ -z "$val" ]; then
    cat >&2 <<EOF
candidate-session: provider '$provider' selected but its API key is unset — refusing to spawn.
  Missing environment variable: $var
  Host-supply location: workflows/scripts/build/build.config.local.sh
  Set $var there (the gitignored, checkout-local secrets convention — see
  that file's own header comment and its .example template) and re-run. This
  is a pre-flight health check, not a warning: no candidate session is
  spawned while $var is unset.
EOF
    return 1
  fi
  return 0
}

# ── Effective-surface resolver (asserts the NARROWED surface, not the JSON) ──
_cs_tool_name() {  # everything before the first '(' , else the whole string
  case "$1" in
    *\(*) printf '%s\n' "${1%%(*}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

_cs_glob_match() {  # $1 = candidate tool-call string, $2 = settings pattern
  case "$2" in
    *\(*|*\**)
      # Pattern carries explicit scoping (parens) or an explicit wildcard —
      # match directly, glob-style, against the whole call string.
      # shellcheck disable=SC2254  # $2 is deliberately unquoted: it's a glob
      case "$1" in
        $2) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      # Bare tool name — matches ANY invocation of that tool, scoped or not
      # (Claude Code's own "Read" == "Read on any path" semantics).
      [ "$(_cs_tool_name "$1")" = "$2" ]
      ;;
  esac
}

candidate_session_resolve() {  # $1 = tool-call string, $2 = settings file
  local call="$1" settings="${2:-$CANDIDATE_SETTINGS}" pattern
  [ -f "$settings" ] || { printf 'unspecified\n'; return 0; }
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if _cs_glob_match "$call" "$pattern"; then
      printf 'deny\n'
      return 0
    fi
  done < <(jq -r '.permissions.deny[]? // empty' "$settings" 2>/dev/null)
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if _cs_glob_match "$call" "$pattern"; then
      printf 'allow\n'
      return 0
    fi
  done < <(jq -r '.permissions.allow[]? // empty' "$settings" 2>/dev/null)
  printf 'unspecified\n'
}

candidate_session_spawn() {
  local provider="anthropic" settings="$CANDIDATE_SETTINGS"
  local -a claude_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-anthropic}"; shift 2 ;;
      --settings) settings="${2:-}"; shift 2 ;;
      --) shift; claude_args=("$@"); break ;;
      *) claude_args+=("$1"); shift ;;
    esac
  done

  candidate_session_preflight "$provider" || return 1

  [ -f "$settings" ] || {
    printf 'candidate-session: containment overlay missing at %s — refusing to spawn uncontained\n' "$settings" >&2
    return 1
  }

  if [ -z "$provider" ] || [ "$provider" = "anthropic" ]; then
    "$CLAUDE_BIN" --settings "$settings" "${claude_args[@]}"
    return $?
  fi

  local var val
  var="$(_cs_provider_env_var "$provider")"
  val="$(eval "printf '%s' \"\${$var:-}\"")"
  # Scoped to exactly this one child process via env(1) — never `export`ed
  # into this script's own shell, so it cannot leak into any later
  # subprocess this script (or its caller) launches afterward. Nothing here
  # captures the child's stdio, so there is no output for the key to leak
  # into either.
  env "$var=$val" "$CLAUDE_BIN" --settings "$settings" "${claude_args[@]}"
  return $?
}

# ── CLI dispatch ─────────────────────────────────────────────────────────────
_cs_usage() {
  sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd="${1:-}"; shift || true
case "$cmd" in
  preflight)
    provider="anthropic"
    while [ $# -gt 0 ]; do
      case "$1" in
        --provider) provider="${2:-anthropic}"; shift 2 ;;
        *) shift ;;
      esac
    done
    candidate_session_preflight "$provider"
    exit $?
    ;;
  resolve)
    call="${1:-}"; shift || true
    settings="$CANDIDATE_SETTINGS"
    while [ $# -gt 0 ]; do
      case "$1" in
        --settings) settings="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$call" ] || { printf 'candidate-session.sh: resolve requires a <tool-call> argument\n' >&2; exit 2; }
    candidate_session_resolve "$call" "$settings"
    exit 0
    ;;
  spawn)
    candidate_session_spawn "$@"
    exit $?
    ;;
  -h|--help|"")
    _cs_usage
    [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ] && exit 0
    exit 2
    ;;
  *)
    printf 'candidate-session.sh: unknown subcommand %s\n' "$cmd" >&2
    _cs_usage
    exit 2
    ;;
esac
