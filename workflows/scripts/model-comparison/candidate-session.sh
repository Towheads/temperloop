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
#      host-secrets file (workflows/scripts/build/build.config.local.sh, its
#      build.config.machine.sh sibling, and its .env-shaped siblings) from
#      the reachable tool surface — denied as a direct Read/Edit/Write/Grep
#      target AND as a Bash command substring, so `cat`/`less`/`grep`-style
#      indirection through the broadly-allowed Bash tool is blocked too.
#      JSON carries no comments, so this file is that overlay's documentation
#      of record. `resolve` below is a REAL deny-over-allow glob matcher
#      against the JSON (not a grep for key presence), so a fixture can
#      assert the EFFECTIVE surface a candidate session actually reaches, not
#      merely that the JSON documents an intent to narrow it.
#
#      THE MATCHER IS SHELL `case`, WHICH HAS NO GLOBSTAR (temperloop#1252
#      review, BLOCKING 5). In a `case` pattern `**` is just `*`, so a
#      `**/`-anchored pattern (`Read(**/.env)`) collapses to `*/` and
#      therefore REQUIRES a literal `/` in the subject — `Read(.env)` and
#      `Read(build.config.local.sh)` measured ALLOW under the original
#      patterns, i.e. the deny list did not deny the two files it exists for.
#      Every deny entry is now written as a plain `*<needle>*` substring glob,
#      which matches the bare-filename, `./`-relative, nested-relative and
#      absolute forms alike. Do NOT reintroduce `**` anywhere in that file.
#
#      Containment also survives the PASSTHROUGH. A caller's `-- <claude
#      args…>` are forwarded verbatim to the child, so a permission-affecting
#      CLI flag in that tail (a second `--settings`, an allow/deny-tools
#      override, a permission-mode or skip-permissions switch, an extra
#      `--add-dir`, an alternate MCP/setting-source config) would override
#      the very overlay this script installs. `spawn` REFUSES such an
#      argument (exit 2, naming the flag) rather than forwarding it — see
#      _CS_FORBIDDEN_PASSTHROUGH below. Those flag names appear there as
#      DATA describing the hole being closed; nothing here enables them.
#
#   2. KEY ISOLATION. `preflight` fails LOUDLY, at pre-flight, naming the exact
#      env var AND the concrete host-supply file, when a non-default
#      provider's key is unset — a runtime health check, never a silent
#      no-op. (This item exists because a sibling project once shipped wiring
#      that only NAMED where a token should go without gating on whether it
#      was set, and that ran as a silent no-op for ~19 hours — the bar here is
#      "confirmed set", not "location named".)
#
#      `spawn` then hands the child an EXPLICITLY CONSTRUCTED environment —
#      `env -i` plus a named allowlist plus exactly ONE provider key (the
#      selected provider's) — never an inherited one. This is the
#      temperloop#1252-review BLOCKING 1 fix and it matters: this script
#      sources the host config ladder (below), whose documented `:=`-then-
#      `export` idiom exports EVERY provider key and every other host secret
#      (SENTRY_AUTH_TOKEN, …) into THIS process. `env VAR=value cmd` ADDS to
#      the inherited environment — it does not replace it — so the previous
#      `env "$var=$val" claude …` construction read as isolation while an
#      OpenAI candidate session still received the Anthropic and Gemini keys,
#      and vice versa. `env -i` inverts the default from "everything the host
#      exported, minus nothing" to "nothing, plus what is named here", so a
#      credential added to build.config.local.sh LATER cannot silently start
#      leaking: it is excluded by construction rather than by a hand-kept
#      denylist. The forwarded provider key is chosen from
#      _CS_PROVIDER_TABLE, the one place providers are registered, so the
#      "every OTHER provider key is absent" property likewise follows a
#      single-source-of-truth table rather than a guessed list.
#
# ── NEVER SOURCE THIS FILE ───────────────────────────────────────────────────
# It is a script, always invoked as a subprocess (`bash candidate-session.sh
# …`), exactly like the sibling machinery scripts in workflows/scripts/build/
# (worktree.sh, pipeline-retro-judge-spawn.sh). Sourcing it would run its CLI
# dispatch against the SOURCING script's own "$@", and — more importantly —
# would leave every host secret the config ladder exports (via
# build.config.local.sh's own `:=`-then-`export` idiom, sourced below)
# `export`ed into the CALLER's shell, which is exactly the parent-process leak
# guarantee #2 above exists to prevent. Running as a subprocess is what makes
# "not exported into the parent process" true by construction: a child
# process's environment can never write back into its parent's.
#
# ── THE DEFAULT PATH IS STILL A NO-OP FOR THE *CHECK* ───────────────────────
# With no candidate provider selected (provider "anthropic", or omitted),
# `preflight` returns 0 immediately with NO key requirement — the default
# provider is exempt from the unset-key gate, because the ordinary host
# authenticates by subscription session, not by an env key. It is NOT exempt
# from the environment construction: the default path spawns under the same
# `env -i` allowlist and forwards ANTHROPIC_API_KEY only if the host has one
# set, so an Anthropic candidate session no longer receives OPENAI_API_KEY /
# GEMINI_API_KEY. Nothing here changes /sweep, /build, or /fix's existing
# default-provider behavior — this script has no caller yet (that lands with
# replay-execute-and-score and judge-rotation-mode).
#
# Usage:
#   candidate-session.sh preflight --provider <name>
#       Exit 0, silent — default provider (or provider omitted), or a
#       non-default provider whose key IS set.
#       Exit 1, legible message on stderr — a non-default provider whose key
#       is UNSET, or an unregistered provider name.
#       Exit 2 — a flag given with no value (e.g. a trailing `--provider`).
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
#       spawns), validates the overlay (fail-closed: see the exit codes
#       below — an absent, unreadable or malformed overlay never spawns),
#       rejects any permission-overriding passthrough argument, then invokes
#       `${CLAUDE_BIN:-claude} --settings <file> <claude args...>` under an
#       explicitly constructed environment (`env -i` + _CS_ENV_PASSTHROUGH +
#       the selected provider's key alone).
#
# ── EXIT CODES (the fail-CLOSED contract) ────────────────────────────────────
# "I could not determine the restriction" is NEVER reported as "no restriction
# applies at exit 0" (temperloop#1252 review, BLOCKING 6). `resolve` and
# `spawn` share one overlay validator with distinct, documented codes:
#
#   0  success — `resolve` printed deny | allow | unspecified; `spawn` ran the
#      child (and then propagates the CHILD's own status).
#   1  a preflight failure — an unset non-default provider key, or an
#      unregistered provider name.
#   2  a usage error — unknown subcommand, missing <tool-call>, a flag with no
#      value, or a refused permission-overriding passthrough argument.
#   3  the containment overlay is ABSENT. Deliberately fail-closed rather than
#      "no overlay configured": `spawn` has always refused to run a candidate
#      session uncontained, so an absent overlay is never a legitimate
#      operating state for this script, and `resolve` reporting `unspecified`/0
#      for it would answer a question it cannot actually answer.
#   4  the containment overlay is UNREADABLE (present but not readable).
#   5  the containment overlay is MALFORMED — not parseable JSON, or missing a
#      `.permissions` object, or carrying a non-array `.permissions.deny` /
#      `.permissions.allow`.
#
# Config (env overrides win; CLAUDE_BIN mirrors the test-double seam name
# every other spawn site in workflows/scripts/build/ already uses):
#   CANDIDATE_SETTINGS   the containment overlay path (default: this
#                        directory's own candidate.settings.json)
#   CLAUDE_BIN           the claude binary / test-double seam (default: claude)
#   CANDIDATE_ENV_PASSTHROUGH_EXTRA
#                        space-separated ADDITIONAL env-var names to forward
#                        into the child, for a host whose `claude` needs a var
#                        _CS_ENV_PASSTHROUGH does not carry. Naming any
#                        registered provider key var here is REFUSED (exit 2)
#                        — the escape hatch cannot be used to re-open the
#                        cross-provider leak this file's guarantee #2 closes.
#
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "candidate-session.sh: jq not found" >&2; exit 1; }

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the host config ladder OURSELVES (mirrors pipeline-retro-judge-spawn.sh's
# re-derive rationale) — whatever the caller's environment did or did not
# carry, a provider key living in build.config.local.sh reaches THIS process.
# NOTE the blast radius this creates, and which guarantee #2's `env -i`
# construction is what actually contains: the ladder `export`s EVERY secret it
# defines into this process, not merely the one provider key we asked for.
# shellcheck source=../build/build.config.sh
[ -f "$HERE/../build/build.config.sh" ] && . "$HERE/../build/build.config.sh"

: "${CANDIDATE_SETTINGS:=$HERE/candidate.settings.json}"
: "${CLAUDE_BIN:=claude}"
: "${CANDIDATE_ENV_PASSTHROUGH_EXTRA:=}"

_CS_DEFAULT_PROVIDER='anthropic'

# ── Provider → required env var (the host-supply seam) ───────────────────────
# The ONE table the preflight check, spawn's key FORWARDING, and spawn's
# "every other provider key is absent" property all read from — registering a
# provider means editing exactly this table, and a provider added here is
# automatically (a) gated by preflight, (b) forwardable when selected, and
# (c) EXCLUDED from every other provider's child environment. There is no
# second, hand-kept list to fall out of sync with it.
#
# `anthropic` is the DEFAULT provider and is listed here for the FORWARDING
# half only: it is exempt from preflight's unset-key gate (the default host
# authenticates by subscription session, not by an env key), so its key is
# forwarded when set and simply absent when not.
_CS_PROVIDER_TABLE='anthropic:ANTHROPIC_API_KEY
openai:OPENAI_API_KEY
google:GEMINI_API_KEY
gemini:GEMINI_API_KEY'

# ── The child's environment allowlist ────────────────────────────────────────
# `env -i` gives the child NOTHING; these names are added back when (and only
# when) they are set in this process. Chosen as what a `claude` CLI child
# genuinely needs to start and to run its own Bash tool: an executable search
# path, a home directory (its own ~/.claude config and credentials), a shell
# and terminal, a scratch dir, locale/timezone, and the proxy/TLS vars a
# corporate host needs for egress. Deliberately ABSENT, by construction rather
# than by denylist: every *_API_KEY / *_TOKEN, every SENTRY_*/AWS_*/GH_*
# credential the config ladder exports, and every BUILD_*/PIPELINE_* pipeline
# setting — none of which a contained candidate session has any business
# reading. Add a name here (or via CANDIDATE_ENV_PASSTHROUGH_EXTRA) only after
# verifying the child actually requires it.
_CS_ENV_PASSTHROUGH='PATH HOME USER LOGNAME SHELL TERM TMPDIR TZ
LANG LC_ALL LC_CTYPE
HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
NODE_EXTRA_CA_CERTS SSL_CERT_FILE SSL_CERT_DIR
XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME'

# ── Passthrough arguments that would defeat the containment overlay ──────────
# Compared after normalization (lowercased, hyphens stripped), so both the
# camelCase and kebab-case spellings of a flag match one entry. These names are
# DATA describing the hole being closed — `spawn` refuses them; nothing here
# passes, enables, or documents how to use them.
_CS_FORBIDDEN_PASSTHROUGH='settings
adddir
allowedtools
disallowedtools
permissionmode
permissionprompttool
dangerouslyskippermissions
mcpconfig
settingsources'

_cs_provider_env_var() {  # $1 = provider name -> prints its env var, or fails
  local p="$1" name var
  while IFS=: read -r name var; do
    [ "$name" = "$p" ] && { printf '%s\n' "$var"; return 0; }
  done <<<"$_CS_PROVIDER_TABLE"
  return 1
}

_cs_provider_key_vars() {  # -> prints every registered provider key var, deduped
  local name var
  while IFS=: read -r name var; do
    [ -n "$var" ] && printf '%s\n' "$var"
  done <<<"$_CS_PROVIDER_TABLE" | sort -u
}

_cs_need_operand() {  # $1 = flag, $2 = remaining arg count ($#) at the flag
  [ "$2" -ge 2 ] && return 0
  printf 'candidate-session.sh: %s requires a value\n' "$1" >&2
  return 2
}

# candidate_session_preflight <provider>
candidate_session_preflight() {
  local provider="${1:-$_CS_DEFAULT_PROVIDER}"
  if [ -z "$provider" ] || [ "$provider" = "$_CS_DEFAULT_PROVIDER" ]; then
    return 0
  fi
  local var
  if ! var="$(_cs_provider_env_var "$provider")"; then
    printf 'candidate-session: unknown provider %s — no env-var mapping registered in candidate-session.sh (_CS_PROVIDER_TABLE)\n' "$provider" >&2
    return 1
  fi
  if [ -z "${!var-}" ]; then
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

# ── Overlay validation (fail-CLOSED; see the exit-code table in the header) ──
_cs_settings_check() {  # $1 = settings path -> 0 ok / 3 absent / 4 unreadable / 5 malformed
  local settings="$1"
  if [ ! -e "$settings" ]; then
    printf 'candidate-session: containment overlay ABSENT at %s — failing closed (an absent overlay is not "no restriction")\n' "$settings" >&2
    return 3
  fi
  if [ ! -f "$settings" ] || [ ! -r "$settings" ]; then
    printf 'candidate-session: containment overlay UNREADABLE at %s — failing closed (cannot determine the restriction)\n' "$settings" >&2
    return 4
  fi
  if ! jq -e '(type == "object")
              and has("permissions") and (.permissions | type == "object")
              and ((.permissions.deny  // []) | type == "array")
              and ((.permissions.allow // []) | type == "array")' \
        "$settings" >/dev/null 2>&1; then
    printf 'candidate-session: containment overlay MALFORMED at %s — failing closed (expected parseable JSON with a .permissions object whose .deny/.allow are arrays)\n' "$settings" >&2
    return 5
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
      # match directly, glob-style, against the whole call string. This is a
      # shell `case` glob: `*` matches any run of characters INCLUDING `/`,
      # and there is no `**` globstar (see the header's BLOCKING 5 note).
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
  local call="$1" settings="${2:-$CANDIDATE_SETTINGS}" pattern rc
  _cs_settings_check "$settings" || { rc=$?; return "$rc"; }
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
  return 0
}

# ── Passthrough hygiene ──────────────────────────────────────────────────────
_cs_normalize_flag() {  # --Allowed-Tools=x -> allowedtools
  printf '%s' "${1%%=*}" | tr '[:upper:]' '[:lower:]' | tr -d '-'
}

_cs_check_passthrough() {  # "$@" = the claude args to forward -> 0 ok / 2 refused
  local a norm f
  for a in "$@"; do
    case "$a" in
      --*) ;;
      *) continue ;;
    esac
    norm="$(_cs_normalize_flag "$a")"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ "$norm" = "$f" ]; then
        printf 'candidate-session: refusing to forward %s to the candidate child — it would override the containment overlay this script installs (--settings %s)\n' \
          "${a%%=*}" "$CANDIDATE_SETTINGS" >&2
        return 2
      fi
    done <<<"$_CS_FORBIDDEN_PASSTHROUGH"
  done
  return 0
}

# ── The child's environment, constructed rather than inherited ───────────────
# Prints one NAME=VALUE line per forwarded variable. Callers read it into an
# array. Values never reach this script's own stdout/stderr — the caller feeds
# them straight into `env -i`'s argv.
_cs_build_child_env() {  # $1 = the ONE provider key var to forward ("" for none)
  local key_var="${1:-}" name
  for name in $_CS_ENV_PASSTHROUGH; do
    [ -n "${!name+x}" ] && printf '%s=%s\n' "$name" "${!name}"
  done
  for name in $CANDIDATE_ENV_PASSTHROUGH_EXTRA; do
    [ -n "${!name+x}" ] && printf '%s=%s\n' "$name" "${!name}"
  done
  if [ -n "$key_var" ] && [ -n "${!key_var-}" ]; then
    printf '%s=%s\n' "$key_var" "${!key_var}"
  fi
}

_cs_check_extra_passthrough() {  # refuse re-opening the cross-provider leak
  local name keyvar
  for name in $CANDIDATE_ENV_PASSTHROUGH_EXTRA; do
    while IFS= read -r keyvar; do
      if [ "$name" = "$keyvar" ]; then
        printf 'candidate-session: refusing CANDIDATE_ENV_PASSTHROUGH_EXTRA=%s — %s is a registered provider key var, and the escape hatch may not re-open the cross-provider leak\n' \
          "$name" "$name" >&2
        return 2
      fi
    done <<<"$(_cs_provider_key_vars)"
  done
  return 0
}

candidate_session_spawn() {
  local provider="$_CS_DEFAULT_PROVIDER" settings="$CANDIDATE_SETTINGS" rc
  local -a claude_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) _cs_need_operand --provider $# || return 2; provider="$2"; shift 2 ;;
      --settings) _cs_need_operand --settings $# || return 2; settings="$2"; shift 2 ;;
      --) shift; claude_args=(${1+"$@"}); break ;;
      *) claude_args+=("$1"); shift ;;
    esac
  done

  candidate_session_preflight "$provider" || return 1

  _cs_settings_check "$settings" || { rc=$?; return "$rc"; }

  _cs_check_extra_passthrough || return 2
  _cs_check_passthrough ${claude_args[@]+"${claude_args[@]}"} || return 2

  # The ONE provider key this child gets — the selected provider's, and only
  # if it is actually set. The default provider is never key-REQUIRED (its
  # preflight exemption above), so an unset ANTHROPIC_API_KEY simply forwards
  # nothing. An unregistered provider cannot reach here: preflight already
  # failed it.
  local key_var=""
  key_var="$(_cs_provider_env_var "$provider" 2>/dev/null)" || key_var=""

  # `env -i` + a named allowlist + that one key. NOT `env VAR=value`, which
  # ADDS to the inherited environment and would hand this child every other
  # provider key the config ladder exported into this process (the
  # temperloop#1252-review BLOCKING 1 leak). Nothing here captures the child's
  # stdio, so there is no output for a key to leak into either.
  # (A forwarded value containing a literal newline would not survive this
  # line-oriented read; none of the allowlisted names above ever carries one.)
  local -a child_env=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && child_env+=("$line")
  done < <(_cs_build_child_env "$key_var")

  env -i ${child_env[@]+"${child_env[@]}"} \
    "$CLAUDE_BIN" --settings "$settings" ${claude_args[@]+"${claude_args[@]}"}
  return $?
}

# ── CLI dispatch ─────────────────────────────────────────────────────────────
_cs_usage() {  # the whole leading comment block, minus the shebang
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  preflight)
    provider="$_CS_DEFAULT_PROVIDER"
    while [ $# -gt 0 ]; do
      case "$1" in
        --provider) _cs_need_operand --provider $# || exit 2; provider="$2"; shift 2 ;;
        *) printf 'candidate-session.sh: preflight: unknown argument %s\n' "$1" >&2; exit 2 ;;
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
        --settings) _cs_need_operand --settings $# || exit 2; settings="$2"; shift 2 ;;
        *) printf 'candidate-session.sh: resolve: unknown argument %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [ -n "$call" ] || { printf 'candidate-session.sh: resolve requires a <tool-call> argument\n' >&2; exit 2; }
    candidate_session_resolve "$call" "$settings"
    exit $?
    ;;
  spawn)
    candidate_session_spawn ${1+"$@"}
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
