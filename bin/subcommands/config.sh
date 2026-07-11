#!/usr/bin/env bash
# description: config subcommands — `config list` prints resolved value + winning precedence rung per registry knob
#
# config.sh — `temperloop config <subcommand>` (temperloop#262, item
# configure-config-cli — ADR K164 D7). One subcommand today: `list`.
#
# WHY THIS EXISTS: the six-rung config precedence ladder
# (docs/config-precedence.md) means a knob's EFFECTIVE value is never just
# "the registry default" — it's whichever rung's file/env sets it first,
# highest rung wins. An operator staring at knob-registry.tsv has no way to
# see what actually WINS on their own machine/checkout without this.
#
# PINNED MECHANISM (design decision, temperloop#262 — do not redesign): the
# ladder itself deliberately tracks no winner (docs/config-precedence.md is
# a pure "highest-rung-wins by source order + `:=`" design with no runtime
# bookkeeping), and knob_registry_get returns only the static registry
# default. So `config list` RE-DERIVES value + winning rung per knob via
# CLEAN-SUBSHELL RUNG PROBES, cheapest rung first:
#   1. env    — is the knob's var already set in THIS process's real
#               environment (rung 2)? No subshell needed — that's just
#               "was it exported before this script ran".
#   2. machine-conf   — does SOURCING the machine-conf file
#               ($BUILD_CONFIG_MACHINE, i.e. the same
#               $XDG_CONFIG_HOME/temperloop/build.config.sh path
#               build.config.sh itself resolves at rung 3) set the var, in
#               a subshell that never touches this process's real state?
#   3. repo-local     — same probe against $BUILD_CONFIG_LOCAL (rung 4,
#               build.config.sh's untracked sibling).
#   4. tracked-repo   — same probe against build.config.sh itself (rung
#               5/6's one physical file in this repo). Reached only once
#               rungs 1-3 have already been ruled out for this var, so
#               whatever build.config.sh's OWN sourcing pass resolves the
#               var to at this point is unambiguously ITS rung — even
#               though build.config.sh transparently re-sources the same
#               rung-3/4 files internally (see its own header), those
#               inner sources are provably no-ops here (rungs 1-3 already
#               said "unset"), so nothing is double-counted.
#   5. else    — no file set it: use the registry row's own recorded
#               `default` field verbatim, and report ITS `layer` column as
#               the winning rung. The D2 registry↔shell equality lint
#               (registry-config-lints, a later item) is what makes this
#               trustworthy without sourcing every individual OWNING
#               SCRIPT (baseline-snapshot.sh, try.sh, ...) — the registry
#               default is guaranteed to equal that script's real literal.
#
# Rung 1 (CLI flag) is NEVER a candidate winner here — there is no live
# invocation context to inspect at list-time (a flag only exists inside
# some OTHER script's own arg parsing). This is reported once, in the
# output header, rather than per-row.
#
# PERFORMANCE NOTE: probes 2-4 each source ONE file (machine-conf,
# repo-local, tracked-repo) exactly ONCE TOTAL for the whole run — not once
# per knob — capturing every registry-known var's resulting value from
# that single source pass, then looking values up per-row out of that
# captured snapshot. Sourcing build.config.sh (a few hundred lines, pure
# `:=` assignments, no external commands beyond `dirname`/`pwd`/`hostname
# -s`) once is cheap; doing it ~150 times (once per registry row) would not
# be.
#
# Usage:
#   config.sh list [--format text|tsv]
#
#   list             Print every unioned registry row (kernel table +
#                    overlay extension when present — knob-registry-lib.sh)
#                    with its resolved value and winning rung.
#   --format text    Human-readable aligned columns (default).
#   --format tsv     Machine-parseable: name<TAB>rung<TAB>value<TAB>
#                    owning-script<TAB>doc, one row per line — same field
#                    order as the registry's own row shape, with `default`
#                    swapped for the resolved `value` and `layer` swapped
#                    for the resolved `rung`.
#
# Exit codes: 0 = printed successfully. 1 = broken kernel checkout (the
# registry lib or build.config.sh is missing). 2 = invalid CLI usage.
#
# Dependencies: bash (3.2+), awk, grep. No `jq`, no `gh`, no `claude` — this
# subcommand is pure local shell-state introspection, never a network call.
#
# NOTE on the CLI dispatcher's prereq gate: `bin/temperloop`'s dispatcher
# requires `claude` + authenticated `gh` on PATH before invoking ANY
# subcommand file (see that script's own header) — a pre-existing,
# subcommand-agnostic gate this file does not touch or reconsider. In
# practice that means `temperloop config list` currently inherits that
# gate even though this subcommand itself needs neither tool; testing (and
# any caller wanting a truly zero-dependency path) invokes this script
# directly, exactly like the existing eject.sh/init.sh/try.sh test suites
# already do.
#
# shellcheck shell=bash

set -uo pipefail

SUBCOMMAND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SUBCOMMAND_DIR/.." && pwd)"
KERNEL_ROOT="$(cd "$BIN_DIR/.." && pwd)"
REGISTRY_LIB="$KERNEL_ROOT/workflows/scripts/config/knob-registry-lib.sh"
TRACKED_REPO_FILE="$KERNEL_ROOT/workflows/scripts/build/build.config.sh"

if [ ! -f "$REGISTRY_LIB" ]; then
  echo "config.sh: knob-registry-lib.sh not found at $REGISTRY_LIB (broken kernel checkout)" >&2
  exit 1
fi
if [ ! -f "$TRACKED_REPO_FILE" ]; then
  echo "config.sh: build.config.sh not found at $TRACKED_REPO_FILE (broken kernel checkout)" >&2
  exit 1
fi
# shellcheck source=../../workflows/scripts/config/knob-registry-lib.sh
source "$REGISTRY_LIB"

usage() {
  cat <<'EOF'
usage: config.sh list [--format text|tsv]
EOF
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

sub="$1"
shift

case "$sub" in
  -h|--help)
    usage
    exit 0
    ;;
  list)
    ;;
  *)
    echo "config.sh: unknown subcommand '$sub'" >&2
    usage >&2
    exit 2
    ;;
esac

format="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:?--format needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "config.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$format" in
  text|tsv) ;;
  *)
    echo "config.sh: --format must be 'text' or 'tsv' (got: $format)" >&2
    exit 2
    ;;
esac

# ---------------------------------------------------------------------------
# Resolve the three FILE rungs. Reuses the SAME override knobs
# build.config.sh itself already honors (BUILD_CONFIG_MACHINE /
# BUILD_CONFIG_LOCAL, both already knob-registry.tsv rows) rather than
# inventing a new registry knob just for this subcommand's own path
# resolution — so a host/checkout override that already works for
# build.config.sh transparently works for `config list` too.
# ---------------------------------------------------------------------------
machine_conf_file="${BUILD_CONFIG_MACHINE:-${XDG_CONFIG_HOME:-$HOME/.config}/temperloop/build.config.sh}"
repo_local_file="${BUILD_CONFIG_LOCAL:-$(dirname "$TRACKED_REPO_FILE")/build.config.local.sh}"

# _config_list_bulk_source <file> <name...> -> ONE subshell source of
# <file> (silent no-op if absent/unreadable), then name<TAB>value for every
# given <name> that ended up SET after sourcing. One source call per
# candidate file for the WHOLE run (see header perf note), not one per
# knob.
_config_list_bulk_source() {
  local file="$1"
  shift
  [ -f "$file" ] || return 0
  (
    # shellcheck disable=SC1090
    source "$file" >/dev/null 2>&1 || true
    local n
    for n in "$@"; do
      if [ -n "${!n+x}" ]; then
        printf '%s\t%s\n' "$n" "${!n}"
      fi
    done
  )
}

# _config_list_lookup <map> <name> -> prints the value if <name> appears in
# <map> (name<TAB>value lines, one per line), rc 1 if absent. Portable
# line-scan (bash 3.2, no associative arrays) — same `while read <<EOF`
# idiom knob-registry-lib.sh already uses throughout.
_config_list_lookup() {
  local map="$1" name="$2" lname lval
  [ -n "$map" ] || return 1
  while IFS=$'\t' read -r lname lval; do
    [ -n "$lname" ] || continue
    if [ "$lname" = "$name" ]; then
      printf '%s' "$lval"
      return 0
    fi
  done <<EOF
$map
EOF
  return 1
}

if ! knob_registry_validate >/dev/null 2>&1; then
  echo "config.sh: warning — the knob registry reported malformed rows (run" >&2
  echo "  workflows/scripts/config/knob-registry-lib.sh's knob_registry_validate" >&2
  echo "  directly for details) — continuing with a best-effort union" >&2
fi

rows="$(knob_registry_rows)"
all_names="$(printf '%s\n' "$rows" | awk -F'\t' 'NF>0{print $1}' | sort -u)"

# shellcheck disable=SC2086  # intentional word-split: a space-separated name list
machine_conf_map="$(_config_list_bulk_source "$machine_conf_file" $all_names)"
# shellcheck disable=SC2086
repo_local_map="$(_config_list_bulk_source "$repo_local_file" $all_names)"
# shellcheck disable=SC2086
tracked_repo_map="$(_config_list_bulk_source "$TRACKED_REPO_FILE" $all_names)"

if [ "$format" = "tsv" ]; then
  printf 'name\trung\tvalue\towning-script\tdoc\n'
else
  echo "temperloop config list — resolved value + winning precedence rung per knob"
  echo "(rung 1 \"cli\" is never resolved at list-time — always reported n/a here;"
  echo " see docs/config-precedence.md for the full six-rung ladder)"
  echo
  printf '%-42s %-13s %-30s %s\n' "NAME" "RUNG" "VALUE" "OWNING-SCRIPT"
fi

while IFS= read -r row; do
  [ -n "$row" ] || continue
  name="$(cut -f1 <<<"$row")"
  default="$(cut -f2 <<<"$row")"
  layer="$(cut -f4 <<<"$row")"
  owning="$(cut -f5 <<<"$row")"
  doc="$(cut -f6 <<<"$row")"

  value="" rung=""
  if [ -n "${!name+x}" ]; then
    value="${!name}"
    rung="env"
  elif v="$(_config_list_lookup "$machine_conf_map" "$name")"; then
    value="$v"
    rung="machine-conf"
  elif v="$(_config_list_lookup "$repo_local_map" "$name")"; then
    value="$v"
    rung="repo-local"
  elif v="$(_config_list_lookup "$tracked_repo_map" "$name")"; then
    value="$v"
    rung="tracked-repo"
  else
    value="$default"
    rung="$layer"
  fi

  if [ "$format" = "tsv" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rung" "$value" "$owning" "$doc"
  else
    printf '%-42s %-13s %-30s %s\n' "$name" "$rung" "$value" "$owning"
  fi
done <<EOF
$rows
EOF

exit 0
