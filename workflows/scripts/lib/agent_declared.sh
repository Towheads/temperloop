#!/usr/bin/env bash
#
# agent_declared.sh — the SUBAGENT half of the kernel's capability probe
# (temperloop#1462), the sibling `command_declared.sh` (ADR 0008) explicitly
# said it did not cover. Answers "is review subagent <name> available here"
# from static file state, across the SAME THREE FILE SURFACES, IN THE SAME
# ORDER, as `command_declared` — with `agents/` in place of `commands/` —
# plus the canonical predicate's other half, the project's own
# `CLAUDE.md § Subagents` declaration, which is probed FIRST because the
# canonical statement names it first ([[Decisions/foundation - Project
# capability probes]]: "available iff the project declares it in
# `CLAUDE.md § Subagents` or `.claude/agents/`").
#
# ── THE FALSE NEGATIVE THIS EXISTS TO KILL ────────────────────────────────
# Read literally, that canonical predicate names only two surfaces, and the
# kernel's own dogfooding checkout has NEITHER: no `.claude/agents/`
# directory (it is gitignored — `project-agents.sh` deploys it per-checkout,
# and a fresh clone has not run it), and no `## Subagents` heading in
# `CLAUDE.md`. Yet every agent is installed and spawnable from
# `$HOME/.claude/agents/`. So the literal predicate reported EVERY reviewer
# unavailable on the exact checkout the kernel is built in — and `build.md`
# §3e's MANDATORY `workflow-reviewer` pass and `/workshop` §3.3's panel
# emitted all-skip lines for agents that would have spawned fine. A skip
# line that fires for an AVAILABLE agent is itself a mandatory step silently
# not running: the same all-skip outcome as temperloop#1387, reached by a
# second, independent route.
#
# ── THE THREE-VALUED ANSWER: installed / source-only / absent ─────────────
# A boolean cannot carry this predicate's job, because the kernel's
# degradation notice has TWO forms and they are selected by WHICH surface
# answered (`claude/message-schema.md` § Degradation notice;
# `CLAUDE.kernel.md` § Legible agent-gate degradation):
#
#   installed    a LIVE surface carries it — the project declares it in
#                `CLAUDE.md § Subagents`, or a `<name>.md` sits in
#                `$PWD/.claude/agents/` or `$HOME/.claude/agents/`.
#                => spawn it. No skip line.
#   source-only  ONLY the checkout's own `claude/agents/` tree carries it.
#                It SHIPS but is not live here.
#                => the remedy-bearing line: `skipped — <agent> available as
#                   source; run workflows/scripts/install/project-agents.sh
#                   to enable`.
#   absent       no surface carries it at all. Nothing to install.
#                => the bare line: `skipped — <agent> unavailable`.
#
# ABSENT AND SOURCE-ONLY MUST STAY DISTINGUISHABLE. A fix that makes every
# agent look available is exactly as wrong as one that makes every agent
# look absent: the first fabricates a review that never ran, the second is
# the bug above. `absent` still returns FALSE from `agent_declared` and
# still fires the bare degradation notice — that is load-bearing, not a
# leftover.
#
# ── SEMANTICS ARE LOAD-BEARING, SAME AS ADR 0008's ────────────────────────
# `agent_declared` answers "source-or-installed PRESENT", never
# "runtime-resolvable". Surface 2 (`<checkout>/claude/agents/`) is the
# kernel's COMPOSE INPUT — the tracked source `project-agents.sh` deploys
# FROM, not a path Claude Code resolves an agent from at run time. So
# `agent_declared` reads TRUE for an agent that ships but is not installed.
# THAT IS WHY IT MUST NEVER, ALONE, GATE A SPAWN:
#
#   agent_declared <name>              -> "is it worth mentioning at all"
#   agent_declared_state <name>         -> the three-valued answer above;
#                                          `installed` is the SPAWN gate
#
# A caller that spawns on bare `agent_declared` will try to spawn a
# source-only agent. Branch on `agent_declared_state`.
#
# ── THE SURFACES, IN ORDER ────────────────────────────────────────────────
#   0. `$PWD/CLAUDE.md` § Subagents names <name>   -> installed
#        The canonical predicate's own first clause. A consuming repo that
#        declares its reviewers in prose rather than as files (the shape
#        `build.md` §3e's "If project CLAUDE.md `## Subagents` lists a review
#        subagent" assumes) resolves here. Section match is exact-title
#        (`## Subagents` / `### Subagents`), closed by the next heading at
#        the same or shallower level; the name must appear as a WHOLE TOKEN
#        inside it, so `docs-reviewer` is not matched by `docs-reviewer-v2`.
#   1. `$PWD/.claude/agents/<name>.md`             -> installed
#        The project-scoped live agent dir Claude Code discovers, and
#        `project-agents.sh`'s deploy target.
#   2. `<checkout>/claude/agents/<name>.md`        -> source-only
#      `<checkout>/claude/agents/reviewers/<name>.md`
#        The tracked kernel source. `<checkout>` is resolved from THIS LIB
#        FILE'S own location via `git rev-parse --show-toplevel`, never
#        `$PWD` (which may be another repo or a subdirectory). The
#        `reviewers/` sub-probe is not a new surface — it is the same one:
#        the per-language reviewer catalog deliberately lives one directory
#        down and is inert until opted in (ADR 0007), which is precisely
#        what `source-only` means.
#   3. `$HOME/.claude/agents/<name>.md`            -> installed
#        The machine-scoped live agent dir. THIS is the surface the literal
#        two-surface predicate omitted, and the one that carries every agent
#        on the kernel's own dogfooding host.
#
# The first surface that carries <name> decides the answer — EXCEPT that a
# `source-only` hit at surface 2 never suppresses a later `installed` hit at
# surface 3. Surface 2 is source and surface 3 is live; an agent that is
# BOTH shipped and installed is INSTALLED, and reporting it source-only
# would re-introduce a skip line for a spawnable agent — this bug, one layer
# in. So surface 2's answer is provisional: it is returned only once
# surface 3 has been checked and found empty.
#
# ── ENV OVERRIDE (for fixtures) ───────────────────────────────────────────
# AGENT_DECLARED_OVERRIDE, when SET (including set-but-empty), answers
# ENTIRELY from this variable — no filesystem probe of any surface runs.
# Its value is a space-separated list of tokens, each `<name>` or
# `<name>:<state>` where <state> is `installed` or `source-only`:
#
#   AGENT_DECLARED_OVERRIDE="workflow-reviewer"                  # -> installed
#   AGENT_DECLARED_OVERRIDE="workflow-reviewer:source-only"      # -> source-only
#   AGENT_DECLARED_OVERRIDE="other-agent"                        # -> absent for workflow-reviewer
#   AGENT_DECLARED_OVERRIDE=""                                   # -> absent for everything
#
# A token carrying an UNRECOGNIZED state suffix warns on stderr and is
# treated as no match (fail-closed): a fixture typo must not silently
# manufacture an availability answer.
#
# Sourced, not executed:
#   source ".../workflows/scripts/lib/agent_declared.sh"
#   case "$(agent_declared_state workflow-reviewer)" in
#     installed)   ... spawn it ... ;;
#     source-only) echo "skipped — workflow-reviewer available as source; run workflows/scripts/install/project-agents.sh to enable" ;;
#     absent)      echo "skipped — workflow-reviewer unavailable" ;;
#   esac
#
# This file sets no shell options of its own (the caller owns set -euo).
# Depends on: awk (surface 0 only) and git (surface 2 resolution only;
# degrades gracefully if unavailable or the lib isn't inside a git checkout).
#
# shellcheck shell=bash

# -> stdout: the checkout root containing this lib file, or nothing if it
# cannot be determined (git absent, or this file isn't inside a git checkout
# -- e.g. a standalone copy). Never fails loudly; a caller that gets empty
# output simply has no surface-2 candidate to check.
_agent_declared_checkout_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true
}

# <name> -> rc 0 if <name> is a syntactically acceptable agent name. Rejects
# anything with a path separator or a leading dash, so a surface probe can
# never be steered outside its own directory by the argument.
_agent_declared_name_ok() {
  case "$1" in
    ""|-*|*/*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# <name> -> rc 0 if $PWD/CLAUDE.md has a `## Subagents` (or `### Subagents`)
# section naming <name> as a whole token. Surface 0: the canonical
# predicate's own first clause. rc 1 when the file, the section, or the name
# is missing -- and when awk is unavailable, which degrades this surface to
# "no answer" rather than failing the whole probe.
_agent_declared_in_claude_md() {
  local name="$1" file="$PWD/CLAUDE.md"
  [ -f "$file" ] || return 1
  command -v awk >/dev/null 2>&1 || return 1
  awk -v want="$name" '
    /^#+[ \t]+/ {
      hashes = $0; sub(/[^#].*$/, "", hashes); lvl = length(hashes)
      title = $0; sub(/^#+[ \t]+/, "", title); sub(/[ \t]+$/, "", title)
      if (title == "Subagents") { inside = 1; openlvl = lvl; next }
      if (inside && lvl <= openlvl) { inside = 0 }
    }
    inside {
      n = split($0, toks, /[^A-Za-z0-9_.-]+/)
      for (i = 1; i <= n; i++) if (toks[i] == want) { found = 1 }
    }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null
}

# <name> -> stdout: the state the override says <name> is in (`installed`,
# `source-only`, or `absent`). Only call this after confirming
# AGENT_DECLARED_OVERRIDE is set -- it does not itself check "is the
# variable set". An unrecognized state suffix warns and yields `absent`.
_agent_declared_state_via_override() {
  local name="$1" tok
  # shellcheck disable=SC2086  # intentional word-splitting: space-separated list contract
  for tok in $AGENT_DECLARED_OVERRIDE; do
    case "$tok" in
      "$name")             printf 'installed\n';   return 0 ;;
      "$name:installed")   printf 'installed\n';   return 0 ;;
      "$name:source-only") printf 'source-only\n'; return 0 ;;
      "$name:"*)
        echo "agent_declared: AGENT_DECLARED_OVERRIDE token '$tok' names an unknown state; treating as no match" >&2
        ;;
    esac
  done
  printf 'absent\n'
}

# agent_declared_state <name> -> stdout exactly one of `installed`,
# `source-only`, or `absent`, per the surface table in this file's header.
# ALWAYS rc 0 (rc 2 on a usage error): the answer is the STRING, so a caller
# branches on it rather than on an exit code that cannot carry three values.
# `installed` is the SPAWN gate; `source-only` and `absent` select the two
# degradation-notice forms.
agent_declared_state() {
  local name="${1:-}" root
  if ! _agent_declared_name_ok "$name"; then
    echo "agent_declared_state: usage: agent_declared_state <name>   (name: [A-Za-z0-9._-], no path separators)" >&2
    return 2
  fi

  if [ -n "${AGENT_DECLARED_OVERRIDE+set}" ]; then
    _agent_declared_state_via_override "$name"
    return 0
  fi

  # Surface 0: the project's own CLAUDE.md § Subagents declaration.
  if _agent_declared_in_claude_md "$name"; then
    printf 'installed\n'; return 0
  fi

  # Surface 1: the project-scoped live agent dir.
  if [ -f "$PWD/.claude/agents/$name.md" ]; then
    printf 'installed\n'; return 0
  fi

  # Surface 2: the checkout's own tracked source. PROVISIONAL -- a live hit
  # at surface 3 outranks it, because an agent that both ships and is
  # installed is installed. See this file's header.
  local shipped=0
  root="$(_agent_declared_checkout_root)"
  if [ -n "$root" ]; then
    if [ -f "$root/claude/agents/$name.md" ] || [ -f "$root/claude/agents/reviewers/$name.md" ]; then
      shipped=1
    fi
  fi

  # Surface 3: the machine-scoped live agent dir.
  if [ -f "$HOME/.claude/agents/$name.md" ]; then
    printf 'installed\n'; return 0
  fi

  if [ "$shipped" -eq 1 ]; then
    printf 'source-only\n'; return 0
  fi

  printf 'absent\n'
}

# agent_declared <name> -> rc 0 if <name> is declared at ANY surface
# (`installed` OR `source-only`), rc 1 when it is `absent`, rc 2 on a usage
# error. This is the direct analogue of `command_declared`: it answers
# "source-or-installed PRESENT", NOT "spawnable". Do not gate a spawn on it
# -- branch on `agent_declared_state` and require `installed`.
agent_declared() {
  local name="${1:-}" state
  if ! _agent_declared_name_ok "$name"; then
    echo "agent_declared: usage: agent_declared <name>   (name: [A-Za-z0-9._-], no path separators)" >&2
    return 2
  fi
  state="$(agent_declared_state "$name")" || return 2
  [ "$state" != "absent" ]
}
