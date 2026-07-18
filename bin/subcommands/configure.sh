#!/usr/bin/env bash
# description: AI-guided config wizard (plain-prompt fallback) — writes ONLY the machine-conf file
#
# configure.sh — `temperloop configure` (temperloop#262, item
# configure-config-cli — ADR K164 D7).
#
# WHAT THIS IS: a short wizard over a small CURATED set of operator-facing
# knobs (CONFIGURE_KNOBS below) that writes its answers to exactly ONE
# file: the machine-conf file at precedence rung 3 of the six-rung ladder
# (docs/config-precedence.md) — $XDG_CONFIG_HOME/temperloop/build.config.sh
# (the SAME discovery path build.config.sh itself resolves via
# BUILD_CONFIG_MACHINE, so anything this wizard writes takes effect the
# next time any spine script sources build.config.sh, with zero further
# wiring). It NEVER writes anywhere else — no prose, no docs, no other
# config file, no tree change, no API call. `temperloop config list`
# (config.sh, this item's sibling) is the read-side complement: it shows
# what this wizard (or a higher rung) actually resolved to.
#
# TWO MODES, chosen automatically (no flag needed) by whether `claude` is
# on PATH — this is a DEGRADATION, not a feature gate: every knob the
# wizard can set, it can set in EITHER mode; only the source of each
# knob's suggested value differs.
#
#   AI-GUIDED (claude on PATH): ONE non-interactive `claude -p` call,
#     `--tools ""` (structurally zero tool access — the model can only
#     return text; this SCRIPT is what ever touches the filesystem,
#     exactly like try.sh's shadow-triage/--demo judgment calls),
#     `--no-session-persistence`. It is handed the curated knobs' name/
#     type/current-default/doc and asked to return one JSON object of
#     suggested values + one-line rationales. "Keep the prompt minimal"
#     (the item's own acceptance framing) is deliberate: this is a single
#     turn producing a starting point for operator review, not a
#     multi-turn interview.
#   PLAIN PROMPTS (claude absent, or --no-ai): the same curated knobs are
#     resolved via `--set NAME=VALUE` (if given), else an interactive
#     y/N-style per-knob prompt on a real tty, else the current/registry
#     default on a non-interactive run.
#
# Either mode's result is a set of candidate values which the SCRIPT
# validates (type-appropriate charset — see _configure_validate_value,
# which also closes off shell-metacharacter injection into the written
# `: "${VAR:=...}"` line) before ever writing anything, and which is
# subject to the SAME consent gate eject.sh/init.sh use: --dry-run prints
# and writes nothing; --yes writes without an extra confirm; otherwise an
# interactive tty gets one final y/N before the write, and a
# non-interactive run with no --yes writes NOTHING (default-deny, exactly
# like init.sh's consented-apply step).
#
# CONFIGURE_KNOBS is a small, hardcoded starter set (FUNNEL_OPERATOR,
# FUNNEL_DRIVE_CONCURRENCY, BUILD_MERGE_GATE_WINDOW, BUILD_QUOTA_PAUSE_PCT) chosen
# for type diversity (label/int/seconds/pct) and first-install relevance —
# NOT an attempt to cover the whole registry (`temperloop config list`
# already shows every registry knob for manual override via any rung; this
# wizard is a fast on-ramp for the handful most worth tuning up front, not
# a second UI onto the full ~150-row registry). This is a plain hardcoded
# list, not an operator-overridable `${VAR:-default}` seam, so it carries
# no knob-registry.tsv row of its own.
#
# WRITE SAFETY: the machine-conf file is upserted line-by-line — an
# existing `: "${NAME:=...}"` line for a knob this run touches is REPLACED
# in place (awk, value passed via -v so no sed-metacharacter risk); every
# other line in the file (including any knob a PRIOR configure run or the
# operator's own hand-edit set) is left byte-identical. A brand-new file
# gets a short header comment; every write ends `chmod 600` (the file may
# later hold host secrets, same guidance as
# build.config.machine.sh.example).
#
# NOTE on the CLI dispatcher's prereq gate: per-subcommand prereq scoping
# (temperloop#412) means `bin/temperloop`'s dispatcher checks a subcommand
# only against what its own `# prereqs: ...` header declares (see that
# script's own header) — this file declares none, so the plain-prompt
# degradation this script implements (see AI-GUIDED / PLAIN PROMPTS above)
# is fully reachable through `temperloop configure` with `claude` absent
# from PATH, no dispatcher-level check standing in front of it. It is
# still exercised directly in tests too, exactly like the existing
# eject.sh/init.sh/try.sh test suites already do.
#
# Usage:
#   configure.sh [--set NAME=VALUE ...] [--no-ai] [--yes] [--dry-run]
#
#   --set NAME=VALUE   Pre-answer one of CONFIGURE_KNOBS (repeatable).
#                      Skips BOTH the AI suggestion and the interactive
#                      prompt for that knob — the primary non-interactive
#                      / test seam (same shape as init.sh's --yes-<action>
#                      flags).
#   --no-ai            Force plain-prompt mode even if `claude` is on
#                      PATH — useful for a deterministic run without
#                      stubbing PATH.
#   --yes              Skip the final interactive confirm-before-write.
#                      REQUIRED (together with --set covering every
#                      still-open knob, or accepting the non-interactive
#                      default) to write anything on a non-tty stdin.
#   --dry-run          Print what would be written; never touches the
#                      machine-conf file (or any file).
#
# Exit codes: 0 = ran to completion, even if nothing was written (a
# declined/non-consented write is a legible no-op, not a failure). 1 =
# fatal usage/environment error (broken kernel checkout). 2 = invalid CLI
# usage.
#
# Dependencies: bash (3.2+), awk. `claude` is optional (degrades to plain
# prompts). No `gh`, no network, ever.
#
# shellcheck shell=bash

set -uo pipefail

SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"

# run_with_timeout SECS cmd... — portable bounded-subprocess watchdog, the
# ONE shared shim every such call site sources rather than re-deriving
# (temperloop#256).
# shellcheck source=../../workflows/scripts/lib/portable-timeout.sh
source "$KERNEL_ROOT/workflows/scripts/lib/portable-timeout.sh"

REGISTRY_LIB="$KERNEL_ROOT/workflows/scripts/config/knob-registry-lib.sh"

if [ ! -f "$REGISTRY_LIB" ]; then
  echo "configure.sh: knob-registry-lib.sh not found at $REGISTRY_LIB (broken kernel checkout)" >&2
  exit 1
fi
# shellcheck source=../../workflows/scripts/config/knob-registry-lib.sh
source "$REGISTRY_LIB"

# Test-double seam (mirrors funnel-drive.sh's CLAUDE_BIN convention — same
# registry row, "byte-identical duplicate fallback", already covers this
# site; see knob-registry.tsv's own header on why that means no new row).
: "${CLAUDE_BIN:=claude}"

# Non-flag-configurable — a single suggestion turn, deliberately short
# (mirrors try.sh's TRY_CLAUDE_TIMEOUT_SECS: a fixed constant, not a CLI
# knob, so a first-run stranger never has to discover a timeout flag).
CONFIGURE_CLAUDE_TIMEOUT_SECS=60
CONFIGURE_CLAUDE_MAX_BUDGET_USD="0.25"

# The curated starter set (see header comment). Order is the prompt/
# summary order.
CONFIGURE_KNOBS="FUNNEL_OPERATOR FUNNEL_DRIVE_CONCURRENCY BUILD_MERGE_GATE_WINDOW BUILD_QUOTA_PAUSE_PCT"

usage() {
  cat <<'EOF'
usage: configure.sh [--set NAME=VALUE ...] [--no-ai] [--yes] [--dry-run]
EOF
}

set_overrides=""
no_ai=0
do_yes=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      kv="${2:?--set needs a NAME=VALUE value}"
      case "$kv" in
        *=*) : ;;
        *)
          echo "configure.sh: --set value must be NAME=VALUE (got: $kv)" >&2
          exit 2
          ;;
      esac
      set_overrides="$set_overrides$kv"$'\n'
      shift 2
      ;;
    --no-ai) no_ai=1; shift ;;
    --yes) do_yes=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "configure.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# _configure_set_lookup <name> -> prints the --set-provided value for
# <name>, rc 1 if none was given.
_configure_set_lookup() {
  local name="$1" line lname lval
  [ -n "$set_overrides" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lname="${line%%=*}"
    lval="${line#*=}"
    if [ "$lname" = "$name" ]; then
      printf '%s' "$lval"
      return 0
    fi
  done <<EOF
$set_overrides
EOF
  return 1
}

# _configure_registry_field <name> <field#> -> field 2=default 3=type
# 6=doc, off the UNIONED registry row for <name>. Errors loudly (broken
# kernel checkout) if the curated set names a knob the registry doesn't
# have — this should never happen absent a typo in CONFIGURE_KNOBS.
_configure_registry_field() {
  local name="$1" field="$2" row
  row="$(knob_registry_rows | awk -F'\t' -v n="$name" '$1==n{print; exit}')"
  if [ -z "$row" ]; then
    echo "configure.sh: '$name' (in CONFIGURE_KNOBS) has no knob-registry.tsv row — broken kernel checkout" >&2
    exit 1
  fi
  cut -f"$field" <<<"$row"
}

# _configure_seed_value <name> <registry-default> -> the value to show/use
# as this knob's starting point: whatever the machine-conf file ALREADY
# sets for it (round-trip — a second `configure` run edits, not
# reintroduces), else the registry default.
_configure_seed_value() {
  local name="$1" registry_default="$2" v
  if [ -f "$machine_conf_file" ]; then
    v="$(
      unset "$name" 2>/dev/null
      # shellcheck disable=SC1090
      source "$machine_conf_file" >/dev/null 2>&1
      if [ -n "${!name+x}" ]; then printf '%s' "${!name}"; fi
    )"
    if [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  fi
  printf '%s' "$registry_default"
}

# _configure_validate_value <type> <value> -> rc 0 iff <value> is a safe,
# type-appropriate literal to embed in `: "${NAME:=<value>}"`. Deliberately
# restrictive (rejects quotes/backticks/`$`/whitespace/slashes-in-non-path
# types) — this is what makes the awk-based upsert below injection-safe
# without a heavier shell-quoting scheme.
_configure_validate_value() {
  local type="$1" value="$2"
  case "$type" in
    int | seconds)
      case "$value" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    pct)
      case "$value" in
        '' | *[!0-9]*) return 1 ;;
      esac
      [ "$value" -ge 0 ] && [ "$value" -le 100 ]
      ;;
    label)
      case "$value" in
        '' | *[!A-Za-z0-9@._-]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *)
      case "$value" in
        '' | *[!A-Za-z0-9@._:/-]*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The machine-conf target (rung 3's discovery path). Honors
# BUILD_CONFIG_MACHINE (already a knob-registry.tsv row) so this wizard
# writes to whatever path a host has actually pointed build.config.sh at —
# never a second, disagreeing default.
# ---------------------------------------------------------------------------
machine_conf_file="${BUILD_CONFIG_MACHINE:-${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"

echo "== temperloop configure =="
echo
echo "Target (rung 3 of the six-rung ladder, docs/config-precedence.md):"
echo "  $machine_conf_file"
echo

# ---------------------------------------------------------------------------
# Resolve each curated knob's seed (current-or-default) + registry
# metadata up front — needed by both modes below.
# ---------------------------------------------------------------------------
resolved=""   # accumulates "NAME<TAB>VALUE<TAB>SOURCE" lines
unresolved=""  # space-separated names still needing AI/prompt resolution

for name in $CONFIGURE_KNOBS; do
  if v="$(_configure_set_lookup "$name")"; then
    type="$(_configure_registry_field "$name" 3)"
    registry_default="$(_configure_registry_field "$name" 2)"
    seed="$(_configure_seed_value "$name" "$registry_default")"
    if ! _configure_validate_value "$type" "$v"; then
      echo "configure.sh: --set $name=$v is not a valid $type value — falling back to $seed" >&2
      v="$seed"
    fi
    resolved="$resolved$name"$'\t'"$v"$'\t'"--set"$'\n'
  else
    unresolved="$unresolved $name"
  fi
done
unresolved="${unresolved# }"

ai_available=0
if [ "$no_ai" -ne 1 ] && [ -n "$unresolved" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  ai_available=1
fi

# ---------------------------------------------------------------------------
# AI-GUIDED mode: one non-interactive claude -p call over every still-
# unresolved knob. Falls back to plain prompts for whatever it can't
# parse/complete (never a hard failure of the whole wizard).
# ---------------------------------------------------------------------------
if [ "$ai_available" -eq 1 ]; then
  echo "-- AI-guided suggestions (claude on PATH; one non-interactive, --tools \"\""
  echo "   call — zero tool access; this script applies the output, never the"
  echo "   model) --"

  prompt_knobs=""
  for name in $unresolved; do
    type="$(_configure_registry_field "$name" 3)"
    registry_default="$(_configure_registry_field "$name" 2)"
    doc="$(_configure_registry_field "$name" 6)"
    seed="$(_configure_seed_value "$name" "$registry_default")"
    prompt_knobs="$prompt_knobs- $name (type: $type, current default: $seed) — $doc
"
  done

  prompt="$(cat <<PROMPT_EOF
You are suggesting starting values for a small set of local shell config
knobs on the operator's own machine. You have NO tools (--tools ""); your
ONLY output is a single JSON object, applied by the calling script, never
by you.

Knobs:
$prompt_knobs
For each knob: if its current default already looks like a real, usable
value, suggest it unchanged. If it looks like an unfilled placeholder that
needs the OPERATOR's own identity (e.g. contains the literal text
"REPLACE"), you cannot know the real value — return the placeholder
UNCHANGED and say so in "why", so the operator knows to fill it in by
hand. Never invent a plausible-looking real value for a placeholder.

Output ONLY a single JSON object on stdout, nothing else — no markdown
fences, no commentary:
{"KNOB_NAME": {"value": "<suggested value, as a plain string>", "why": "<one line>"}, ...}
PROMPT_EOF
)"

  # No `set -e` toggle here — this script's top-level mode is `-uo
  # pipefail` only (`-e` was never on), so `ai_rc` is checked explicitly
  # below rather than relying on errexit (mirrors try.sh's own rationale
  # for its analogous judgment-call capture).
  ai_out="$(run_with_timeout "$CONFIGURE_CLAUDE_TIMEOUT_SECS" \
    "$CLAUDE_BIN" -p "$prompt" \
    --tools "" \
    --output-format text \
    --no-session-persistence \
    --max-budget-usd "$CONFIGURE_CLAUDE_MAX_BUDGET_USD" \
    2>/dev/null)"
  ai_rc=$?

  if [ "$ai_rc" -ne 0 ]; then
    if [ "$ai_rc" -eq 137 ]; then
      echo "  skipped — claude call timed out after ${CONFIGURE_CLAUDE_TIMEOUT_SECS}s; falling back to plain prompts"
    else
      echo "  skipped — claude call failed (exit $ai_rc); falling back to plain prompts"
    fi
    ai_out=""
  fi

  still_unresolved=""
  for name in $unresolved; do
    type="$(_configure_registry_field "$name" 3)"
    registry_default="$(_configure_registry_field "$name" 2)"
    seed="$(_configure_seed_value "$name" "$registry_default")"

    v=""
    why=""
    if command -v jq >/dev/null 2>&1 && [ -n "$ai_out" ]; then
      v="$(printf '%s' "$ai_out" | jq -r --arg k "$name" '.[$k].value // empty' 2>/dev/null)"
      why="$(printf '%s' "$ai_out" | jq -r --arg k "$name" '.[$k].why // empty' 2>/dev/null)"
    fi

    if [ -n "$v" ] && _configure_validate_value "$type" "$v"; then
      resolved="$resolved$name"$'\t'"$v"$'\t'"ai"$'\n'
      printf '  %-24s -> %s' "$name" "$v"
      [ -n "$why" ] && printf '  (%s)' "$why"
      printf '\n'
    else
      still_unresolved="$still_unresolved $name"
    fi
  done
  unresolved="$still_unresolved"
  echo
fi

# ---------------------------------------------------------------------------
# PLAIN-PROMPT mode (claude absent, --no-ai, or an AI suggestion that
# didn't parse): interactive on a real tty, else the seed/default.
# ---------------------------------------------------------------------------
if [ -n "$unresolved" ]; then
  if [ "$ai_available" -eq 0 ]; then
    echo "-- Plain prompts (claude not on PATH$( [ "$no_ai" -eq 1 ] && printf ' — --no-ai' )) --"
  else
    echo "-- Plain prompts (remaining knobs) --"
  fi

  for name in $unresolved; do
    type="$(_configure_registry_field "$name" 3)"
    registry_default="$(_configure_registry_field "$name" 2)"
    doc="$(_configure_registry_field "$name" 6)"
    seed="$(_configure_seed_value "$name" "$registry_default")"

    v="$seed"
    if [ -t 0 ]; then
      printf '%s (%s) — %s\n  [%s]: ' "$name" "$type" "$doc" "$seed"
      ans=""
      read -r ans || ans=""
      [ -n "$ans" ] && v="$ans"
      while ! _configure_validate_value "$type" "$v"; do
        printf '  not a valid %s value: %s — try again\n  [%s]: ' "$type" "$v" "$seed"
        ans=""
        read -r ans || ans=""
        if [ -z "$ans" ]; then v="$seed"; break; fi
        v="$ans"
      done
    else
      echo "  $name: no tty — using $v (non-interactive default)"
    fi
    resolved="$resolved$name"$'\t'"$v"$'\t'"prompt"$'\n'
  done
  echo
fi

# ---------------------------------------------------------------------------
# Summary + consent gate.
# ---------------------------------------------------------------------------
echo "-- Summary --"
n=0
while IFS=$'\t' read -r name value source; do
  [ -n "$name" ] || continue
  n=$((n + 1))
  printf '  %-24s = %-20s (%s)\n' "$name" "$value" "$source"
done <<EOF
$resolved
EOF
echo

if [ "$dry_run" -eq 1 ]; then
  echo "-- Dry run: would write the $n value(s) above to $machine_conf_file — nothing done --"
  echo
  echo "temperloop configure: done (dry run)"
  exit 0
fi

proceed=0
if [ "$do_yes" -eq 1 ]; then
  proceed=1
  echo "write: yes (--yes)"
elif [ -t 0 ]; then
  printf 'Write the %s value(s) above to %s? [y/N] ' "$n" "$machine_conf_file"
  ans=""
  read -r ans || ans=""
  case "$ans" in
    y | Y | yes | YES) proceed=1; echo "write: yes (operator confirmed)" ;;
    *) echo "write: no (operator declined)" ;;
  esac
else
  echo "write: no (skipped — no explicit consent; non-interactive; pass --yes to opt in)"
fi
echo

if [ "$proceed" -ne 1 ]; then
  echo "temperloop configure: aborted — nothing written"
  exit 0
fi

# ---------------------------------------------------------------------------
# The write itself: per-knob upsert (replace an existing `: "${NAME:=...}"`
# line in place, else append one), never touching any other line/file.
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$machine_conf_file")"

content=""
if [ -f "$machine_conf_file" ]; then
  content="$(cat "$machine_conf_file")"
else
  content="$(cat <<EOF
#!/usr/bin/env bash
#
# $machine_conf_file — temperloop machine-level config override (rung 3 of
# the six-rung precedence ladder, docs/config-precedence.md). Generated by
# \`temperloop configure\`; hand edits are preserved — configure only ever
# upserts the ONE line for a knob it manages, never anything else in this
# file. See build.config.machine.sh.example for the full idiom/rationale.
EOF
)"
fi

while IFS=$'\t' read -r name value source; do
  [ -n "$name" ] || continue
  found="$(printf '%s\n' "$content" | awk -v n="$name" 'BEGIN{p="^: \"\\$\\{" n ":="} $0 ~ p {print "1"; exit}')"
  if [ "$found" = "1" ]; then
    content="$(printf '%s\n' "$content" | awk -v n="$name" -v v="$value" '
      BEGIN { pat = "^: \"\\$\\{" n ":=" }
      $0 ~ pat { print ": \"${" n ":=" v "}\""; next }
      { print }
    ')"
  else
    # shellcheck disable=SC2016  # literal printf format ${...}, not shell expansion
    content="$(printf '%s\n\n: "${%s:=%s}"\nexport %s\n' "$content" "$name" "$value" "$name")"
  fi
done <<EOF
$resolved
EOF

printf '%s\n' "$content" > "$machine_conf_file"
chmod 600 "$machine_conf_file" 2>/dev/null || true

echo "-- Written --"
echo "  $machine_conf_file ($n knob(s))"
echo
echo "See the result with: temperloop config list"
echo
echo "temperloop configure: done"
exit 0
