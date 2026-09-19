#!/usr/bin/env bash
#
# build-config-settings.sh — print the names of the VALUE settings build.config.sh
# defines, one per line (temperloop#1241).
#
# SSOT-derived: the list is parsed from build.config.sh itself — the UNION of
#   (a) its `: "${NAME:=default}"` DECLARATIONS, and
#   (b) the names its top-level `export` statement(s) EXPORT —
# so a newly-added setting is covered here with NO edit to this script, whichever
# of those two shapes it is written in. There is exactly one place setting names
# live, and this script reads both of the shapes that place uses.
#
# WHY THE EXPORT ARM EXISTS (temperloop#1709). A declaration-only parser covers
# only names written in the declaration shape. A name build.config.sh EXPORTS but
# deliberately does NOT declare is invisible to it, so it escapes the 3e.5 scrub
# and the operator's live environment leaks into the acceptance gate.
# `KNOWLEDGE_STORE_ROOT` was the live instance: build.config.sh's own
# "knowledge_store root" comment block argues at length for leaving that var
# unset rather than seeding a layer-5 default, while the file still exports it —
# and its name sits ALONE on a `\`-continued line of the export list, so even a
# grep for `export.*KNOWLEDGE_STORE_ROOT` returns nothing. The export parser
# below is therefore MULTI-LINE by construction: it follows backslash
# continuations and collects every bare name on them. Fix at the class, not the
# instance — no setting name is hardcoded anywhere in this script.
#
# CONSUMER: build-level.mjs's 3e.5 acceptance gate. The gate runs
# `quality-gates.sh` against the worker's worktree, but under the pipeline-drive
# session it inherits that session's ~40 EXPORTED build.config.sh settings. The
# config-precedence tests the gate runs (test_config.sh / test_stranger_config.sh
# / test_pipeline_cron.sh) assert layer precedence (env > machine-conf > repo-local
# > tracked-default); with the settings exported the ENV layer wins and those
# assertions false-fail — GATE_FAIL on a change CI's `checks` passes green.
# The gate `unset`s the names this script prints before running the suite, so it
# runs hermetically at tracked defaults, exactly as CI does.
#
# EXCLUDES the two config-FILE resolvers BUILD_CONFIG_MACHINE / BUILD_CONFIG_LOCAL:
# they govern WHERE config is sourced from (a structurally distinct concern from
# a tunable value), and the machine-local FILE leak they relate to is tracked
# separately as temperloop#1055 — an env scrub cannot fix a file that is read
# regardless of the environment, so #1241 deliberately does not reach into that
# mechanism.
#
# Output: one name per line, deduplicated and sorted.
#
# No args. Reads only the sibling build.config.sh. Writes nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$here/build.config.sh"

[ -r "$config" ] || { echo "build-config-settings.sh: cannot read $config" >&2; exit 1; }

# (a) Declarations — the documented setting idiom `: "${NAME:=...}"`
#     (§ build.config.sh header), anchored at column 0.
declared() {
  sed -nE 's/^: "\$\{([A-Z_][A-Z0-9_]*):=.*/\1/p' "$config"
}

# (b) Exports — every name in a top-level `export` statement, following
#     backslash continuations across lines. Anchored at column 0 for the same
#     reason (a) is: a top-level statement, never one nested inside a function
#     or conditional. Handles `export A B C`, `export A=1`, and the multi-line
#     `export A \` / `       B C \` / `       D` shape the real file uses.
exported() {
  awk '
    {
      line = $0
      if (in_export) {
        # continuation line of the export statement opened above
      } else if (line ~ /^export[ \t]/) {
        in_export = 1
        sub(/^export[ \t]+/, "", line)
      } else {
        next
      }
      cont = (line ~ /\\[ \t]*$/)
      sub(/\\[ \t]*$/, "", line)
      n = split(line, tok, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = tok[i]
        sub(/=.*$/, "", t)          # `export NAME=value` -> NAME
        if (t ~ /^[A-Z_][A-Z0-9_]*$/) print t
      }
      if (!cont) in_export = 0
    }
  ' "$config"
}

# Union, deduplicated and sorted, then drop the two config-file resolvers
# (see EXCLUDES above).
{ declared; exported; } \
  | sort -u \
  | grep -vxE 'BUILD_CONFIG_MACHINE|BUILD_CONFIG_LOCAL'
