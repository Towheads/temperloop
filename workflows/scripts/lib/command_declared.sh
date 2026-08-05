#!/usr/bin/env bash
#
# command_declared.sh — ADR 0008: a shared helper, `command_declared <name>`,
# answering "is slash command <name> available" by checking the three
# surfaces a headless `claude -p` invocation's supporting tooling actually
# reads or writes, IN ORDER:
#   1. $PWD/.claude/commands/<name>.md   — a project-local command
#   2. <checkout>/claude/commands/<name>.md — the kernel's SOURCE OF TRUTH
#      (the checkout containing this lib, resolved via `git rev-parse
#      --show-toplevel` from the lib's own location — never $PWD, which may
#      be a different repo or a subdirectory)
#   3. $HOME/.claude/commands/<name>.md  — the composed-install deployment
#      target (`make install-claude`'s output)
# TRUE (rc 0) the moment any surface has a `<name>.md` file; FALSE (rc 1)
# when none does. Kernel surfaces that reference an optional command should
# cite this helper rather than improvise their own file check.
#
# ── SEMANTICS ARE LOAD-BEARING: "source-or-installed present", NOT
#    "runtime-resolvable" ──────────────────────────────────────────────────
# This predicate answers "does a `<name>.md` file exist somewhere in the
# source-or-installed chain" — it does NOT answer "would a headless
# `claude -p` invocation actually resolve `/<name>` right now". Surface 2
# (`<checkout>/claude/commands/`) is the kernel's COMPOSE INPUT — the source
# tree `make install-claude` reads FROM, not a path `claude -p` itself
# resolves slash-commands from at runtime. Consequently, on an UNINSTALLED
# checkout (no `make install-claude` ever run, so `~/.claude/commands/` is
# still missing or stale), this predicate can read TRUE for a kernel command
# that a real `claude -p` invocation cannot yet invoke — a latent
# false-positive, by design, because checking "installed" would require
# shelling out to inspect a live harness rather than answering from static
# file state.
#
# This false-positive is INERT for every caller as of this writing: every
# current call site probes the OVERLAY-ONLY `/retro` command, which has no
# file anywhere under this (kernel) checkout's `claude/commands/` — so
# surface 2 never fires for them, and the true/false answer these callers
# see today is always driven by surfaces 1 or 3 only. A FUTURE caller that
# probes a KERNEL-source command name (one that genuinely lives under
# `claude/commands/` in this checkout) is the case that would first observe
# the latent false-positive described above — that caller should treat a
# surface-2-only TRUE as "declared in source, not necessarily installed" if
# that distinction matters to it.
#
# ── THE SECOND PREDICATE: command_declared_capability ──────────────────────
# `command_declared` answers PRESENCE. It deliberately says nothing about
# what the command can DO — and presence is not enough for a kernel surface
# that SPAWNS a command unattended. temperloop#1150 is the worked failure:
# the funnel's Phase R retro-judge trigger gated on `command_declared retro`
# alone, so on a host where `/retro` was installed but implemented no
# headless `--pending` mode, the tick spawned `claude -p "/retro --pending"`,
# the nested session ended its turn without judging anything, and the run
# exited `subtype: success` / `is_error: false` having produced ZERO
# judgments and zero stream rows — 13m and ~$7.60 of silence, indistinguishable
# from a healthy tick.
#
# `command_declared_capability <name> <capability>` closes that: it answers
# "does the resolved `<name>.md` DECLARE that it can do <capability>". The
# declaration grammar is one marker line, ALONE on its line (leading/trailing
# whitespace allowed), anywhere in the command file:
#
#     <!-- capability: headless-unattended -->
#
# A marker may carry several tokens, comma- and/or space-separated:
#
#     <!-- capability: headless-unattended, no-merge -->
#
# The line-alone anchor is load-bearing: it lets prose (this header, a feature
# doc, a command spec explaining the grammar) mention the marker INLINE inside
# a sentence or backticks without accidentally declaring the capability.
#
# SEMANTICS: FIRST-RESOLVED FILE WINS, and the answer is FAIL-CLOSED.
# The three surfaces are walked in the SAME order as command_declared, and
# the FIRST file that exists is authoritative — the same file a runtime
# resolution would land on. If that file carries no matching marker, the
# answer is FALSE even if a later surface's copy would declare it; if no
# surface has the file at all, the answer is FALSE. A caller therefore never
# spawns on an ASSUMED capability: an undeclared capability is refused, and
# the refusal is the caller's job to make legible.
#
# The declaration is an ASSERTION BY THE COMMAND'S AUTHOR, not a proof. The
# kernel cannot execute an overlay command to find out whether it completes
# unattended; what it can do is refuse to spawn one that never claimed it
# could. That is the whole contract: presence is discovered, capability is
# declared.
#
# ── ENV OVERRIDE (for fixtures) ────────────────────────────────────────────
# COMMAND_CAPABILITY_OVERRIDE, when SET (including set-but-empty), answers
# ENTIRELY from this variable — no filesystem probe runs. Its value is a
# space-separated list of `<name>:<capability>` pairs:
#
#   COMMAND_CAPABILITY_OVERRIDE="retro:headless-unattended"   # -> true for that pair only
#   COMMAND_CAPABILITY_OVERRIDE=""                            # -> false for every pair
#
# When COMMAND_CAPABILITY_OVERRIDE is UNSET but COMMAND_DECLARED_OVERRIDE is
# set, the capability probe answers FALSE without touching the filesystem —
# a fixture that has taken control of the presence answer must not have the
# capability answer silently decided by whatever real command files happen to
# exist on the machine running the test. Fail-closed, hermetic, and it keeps
# the two overrides independent: a fixture opts INTO a capability explicitly.
#
# This is a DISTINCT predicate from the subagent capability-probe
# (`Decisions/foundation - Project capability probes`, the CLAUDE.md-or-
# .claude/agents/ declaration check a review-gate step runs before trusting
# a named subagent): that probe checks whether a CAPABILITY IS DECLARED for
# a project; this probe checks whether a FILE EXISTS across three mixed
# source-and-runtime surfaces. Do not conflate the two or use one to answer
# the other's question.
#
# ── ENV OVERRIDE (for fixtures) ────────────────────────────────────────────
# COMMAND_DECLARED_OVERRIDE, when SET (including set-but-empty), makes
# command_declared answer ENTIRELY from this variable — no filesystem probe
# of any of the three surfaces runs at all. Its value is a space-separated
# list of command names considered declared:
#
#   COMMAND_DECLARED_OVERRIDE="retro build"   command_declared retro   # -> true  (rc 0)
#   COMMAND_DECLARED_OVERRIDE="retro build"   command_declared triage  # -> false (rc 1)
#   COMMAND_DECLARED_OVERRIDE=""              command_declared retro   # -> false (rc 1) -- set but empty means nothing is declared
#
# This lets a fixture force BOTH a deterministic true AND a deterministic
# false answer for the same name, independent of whatever real files happen
# to exist on the machine running the test. Unset (the default) means "use
# the real three-surface probe" — the override is opt-in per invocation.
#
# Sourced, not executed:
#   source ".../workflows/scripts/lib/command_declared.sh"
#   command_declared retro && ...
#   command_declared_capability retro headless-unattended && ...
#
# This file sets no shell options of its own (the caller owns set -euo).
# Depends on: git (surface 2 resolution only; degrades gracefully if
# unavailable or the lib isn't inside a git checkout -- see
# _command_declared_checkout_root below).
#
# shellcheck shell=bash

# -> stdout: the checkout root containing this lib file, or nothing if it
# cannot be determined (git absent, or this file isn't inside a git
# checkout -- e.g. a standalone copy). Never fails loudly; a caller that
# gets empty output simply has no surface-2 candidate to check.
_command_declared_checkout_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true
}

# <name> -> rc 0 if the override says <name> is declared, rc 1 if the
# override says it is not. Only call this after confirming
# COMMAND_DECLARED_OVERRIDE is set (see command_declared below) -- this
# function does not itself check "is the variable set".
_command_declared_via_override() {
  local name="$1" tok
  # shellcheck disable=SC2086  # intentional word-splitting: space-separated list contract
  for tok in $COMMAND_DECLARED_OVERRIDE; do
    [ "$tok" = "$name" ] && return 0
  done
  return 1
}

# command_declared <name> -> rc 0 if a "<name>.md" file exists at any of the
# three surfaces documented in this file's header (checked in that order),
# rc 1 if none does. See the header's ENV OVERRIDE section for the fixture
# escape hatch.
command_declared() {
  local name="$1" root
  if [ -z "$name" ]; then
    echo "command_declared: usage: command_declared <name>" >&2
    return 2
  fi

  if [ -n "${COMMAND_DECLARED_OVERRIDE+set}" ]; then
    _command_declared_via_override "$name"
    return $?
  fi

  # Surface 1: project-local override.
  [ -f "$PWD/.claude/commands/$name.md" ] && return 0

  # Surface 2: the kernel checkout's own source of truth.
  root="$(_command_declared_checkout_root)"
  if [ -n "$root" ] && [ -f "$root/claude/commands/$name.md" ]; then
    return 0
  fi

  # Surface 3: the composed-install deployment target.
  [ -f "$HOME/.claude/commands/$name.md" ] && return 0

  return 1
}

# <name> -> stdout: the path of the FIRST of the three surfaces (same order as
# command_declared) that actually carries "<name>.md"; nothing (rc 1) when none
# does. This is the file a runtime resolution would land on, and the ONLY file
# command_declared_capability reads — see this file's header, § FIRST-RESOLVED
# FILE WINS.
_command_declared_path() {
  local name="$1" root
  [ -n "$name" ] || return 1
  [ -f "$PWD/.claude/commands/$name.md" ] && { printf '%s\n' "$PWD/.claude/commands/$name.md"; return 0; }
  root="$(_command_declared_checkout_root)"
  if [ -n "$root" ] && [ -f "$root/claude/commands/$name.md" ]; then
    printf '%s\n' "$root/claude/commands/$name.md"; return 0
  fi
  [ -f "$HOME/.claude/commands/$name.md" ] && { printf '%s\n' "$HOME/.claude/commands/$name.md"; return 0; }
  return 1
}

# <file> -> stdout: one capability token per line, parsed from every
# `<!-- capability: … -->` marker that is ALONE on its line. Tokens may be
# separated by commas and/or whitespace inside one marker. Emits nothing for a
# file with no markers (and never fails loudly — an unreadable file is simply
# a file that declares nothing).
_command_capability_tokens() {
  local file="$1"
  [ -f "$file" ] || return 0
  # BSD/GNU-portable: grep -E for the line-anchored marker, sed -E to strip the
  # comment wrapper, then split the payload on commas/whitespace.
  grep -E '^[[:space:]]*<!--[[:space:]]*capability:[^>]*-->[[:space:]]*$' "$file" 2>/dev/null \
    | sed -E 's/^[[:space:]]*<!--[[:space:]]*capability:[[:space:]]*//; s/[[:space:]]*-->[[:space:]]*$//; s/,/ /g' \
    | awk '{for (i = 1; i <= NF; i++) print $i}' || true
}

# <name> <capability> -> rc 0 iff the resolved "<name>.md" DECLARES <capability>
# via the marker grammar in this file's header; rc 1 otherwise (no marker, no
# file, or an override that says no). rc 2 on a usage error. Fail-closed by
# construction: every "I can't tell" answer is rc 1, so a caller never spawns a
# command on an assumed capability.
command_declared_capability() {
  local name="$1" capability="${2:-}" file tok
  if [ -z "$name" ] || [ -z "$capability" ]; then
    echo "command_declared_capability: usage: command_declared_capability <name> <capability>" >&2
    return 2
  fi

  if [ -n "${COMMAND_CAPABILITY_OVERRIDE+set}" ]; then
    # shellcheck disable=SC2086  # intentional word-splitting: space-separated list contract
    for tok in $COMMAND_CAPABILITY_OVERRIDE; do
      [ "$tok" = "$name:$capability" ] && return 0
    done
    return 1
  fi

  # A fixture that took control of the PRESENCE answer must not have the
  # CAPABILITY answer decided by whatever real files exist on the test host.
  [ -n "${COMMAND_DECLARED_OVERRIDE+set}" ] && return 1

  file="$(_command_declared_path "$name")" || return 1
  while IFS= read -r tok; do
    [ "$tok" = "$capability" ] && return 0
  done <<EOF
$(_command_capability_tokens "$file")
EOF
  return 1
}
