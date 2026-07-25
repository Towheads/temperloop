#!/usr/bin/env bash
# rename-compat-0170.sh — legacy-env read window for the v0.17.0 terminology
# consolidation (temperloop#729, ADR 0017; the FOUNDATION_*->TEMPERLOOP_*
# precedent, temperloop#165, applied to the coined-prefix renames).
#
# READ-OLD-WRITE-NEW: a pre-rename env var still drives the renamed setting
# through the legacy window — precedence NEW > OLD > default:
#
#   FUNNEL_<NAME>  -> PIPELINE_<NAME>   (autonomous-pipeline settings)
#   KNOB_<NAME>    -> SETTING_<NAME>    (setting-registry / prose-lint seams)
#
# For each legacy var that is SET while its renamed counterpart is UNSET, the
# value is copied to the new name and ONE deprecation NOTE is printed to
# stderr naming the replacement and the removal version. When the new name is
# already set, the legacy var is ignored with zero noise (new > old). The
# legacy window closes in v0.19.0 — this file and the forwarding stubs at the
# old script paths are deleted together then (CHANGELOG 0.17.0 BREAKING
# migration note enumerates the full map).
#
# Persisted-state literal VALUES are deliberately NOT remapped here (the
# `funnel-merge-pending` / `funnel-escalated` labels, the
# `<!-- funnel:clarification-drained -->` / `<!-- funnel:decision-applied -->`
# issue markers, `~/.claude/funnel/*` state paths, `/tmp/funnel-tick` lock
# dir): they are live external state on boards/machines, kept stable exactly
# like the committed `.foundation/` per-repo dir in the #165 rename.
#
# Sourced (never executed) by build.config.sh, setting-registry-lib.sh, the
# setting lints, and the pipeline entry scripts. bash 3.2 compatible.
#
# shellcheck shell=bash

if [[ "${_TEMPERLOOP_RENAME_COMPAT_0170_LOADED:-}" == "1" ]]; then
  return 0
fi
_TEMPERLOOP_RENAME_COMPAT_0170_LOADED=1

_rename_compat_0170_apply() {
  local old_prefix="$1" new_prefix="$2" old new val
  # compgen -A variable lists every shell variable with the given prefix
  # (bash 3.2 builtin — no assoc arrays needed).
  for old in $(compgen -A variable "$old_prefix" 2>/dev/null || true); do
    new="${new_prefix}${old#"$old_prefix"}"
    # Skip when the new name is already set (new > old, zero noise).
    if [ -n "${!new+x}" ]; then
      continue
    fi
    val="${!old}"
    export "$new=$val"
    printf 'NOTE: %s is deprecated — renamed %s in v0.17.0 (terminology consolidation, temperloop#729); legacy env reads close in v0.19.0.\n' \
      "$old" "$new" >&2
  done
}

_rename_compat_0170_apply "FUNNEL_" "PIPELINE_"
_rename_compat_0170_apply "KNOB_" "SETTING_"
