#!/usr/bin/env bash
#
# Reconcile ~/.claude/settings.json from the tracked template WITHOUT clobbering
# the machine-local `model` field (foundation #292).
#
# Unlike every other claude/* file, settings.json must NOT be a symlink to the
# tracked source. Claude Code's `/model` and `/fast` persist the chosen model by
# writing it back into ~/.claude/settings.json; if that path is a symlink to the
# tracked claude/settings.json, the write goes THROUGH the symlink and dirties the
# tracked file — shifting the default model GLOBALLY across every checkout/machine
# (and tripping build's dirty-tree guard). So we generate a REAL file instead:
#
#   * every field comes from the tracked template — so hooks / permissions /
#     statusLine / etc. changes still propagate on `make install-claude`, exactly
#     like the symlinked files do;
#   * EXCEPT `model`, which is preserved from the existing local file when present
#     — making the model a per-machine setting that `/model` can mutate freely
#     without ever touching the tracked source.
#
# The tracked `model` is therefore only a SEED: it sets the model on a fresh
# machine (no local file yet) and is preserved-over by whatever the machine later
# selects. Idempotent: re-running reconciles to the same result.
#
# PATH RENDERING (foundation #773, kernel-readiness; generalized temperloop
# #164/#169): the tracked template hardcodes the maintainer dev machine's
# absolute paths (e.g. `/Users/<some-user>/.claude/hooks/*.sh`). This script
# sed-patches every such literal to derive from the ACTUAL `$HOME` at render
# time, so the rendered settings.json never carries a hardcoded machine path
# on any checkout/user other than the one the template happened to be
# authored on.
#
# No hardcoded username constant: the sed pattern matches ANY `/Users/<name>`
# path structurally (one path-segment username, `[^/"[:space:]]+`) rather
# than a specific literal — so this script names no personal identity at
# all, and needs no denylist exemption for one. It renders correctly for the
# machine the template WAS authored on (that literal is one of the ones the
# generic pattern matches, same as any other) and for any other `$HOME` a
# stranger's checkout runs under.
#
#   install-settings.sh <tracked-settings.json> <target-path>
set -euo pipefail

tracked="${1:?usage: install-settings.sh <tracked-settings.json> <target-path>}"
target="${2:?usage: install-settings.sh <tracked-settings.json> <target-path>}"
[ -f "$tracked" ] || { echo "install-settings: tracked file not found: $tracked" >&2; exit 1; }

# Preserve the local model if a settings file already exists. `[ -e ]` is false for
# a broken symlink, so also test `[ -L ]`. On the very first run the target is still
# the symlink-to-tracked, so this reads the tracked model — a harmless no-op that
# yields an identical file; thereafter it reads the machine's real local file.
local_model=""
if [ -e "$target" ] || [ -L "$target" ]; then
  local_model="$(jq -r '.model // empty' "$target" 2>/dev/null || true)"
fi

tmp="$(mktemp "${TMPDIR:-/tmp}/install-settings.XXXXXX")"
tmp_rendered="$(mktemp "${TMPDIR:-/tmp}/install-settings.XXXXXX")"
trap 'rm -f "$tmp" "$tmp_rendered"' EXIT
if [ -n "$local_model" ]; then
  jq --arg m "$local_model" '.model = $m' "$tracked" >"$tmp"
else
  jq '.' "$tracked" >"$tmp"
fi

# Rewrite every literal /Users/<user> path to the ACTUAL $HOME so the rendered
# output never carries a hardcoded machine path (foundation #773). Matches the
# username structurally (no specific name baked in) — a no-op when $HOME
# already IS /Users/<that-user> (the machine the template was authored on).
sed -E "s|/Users/[^/\"[:space:]]+|$HOME|g" "$tmp" >"$tmp_rendered"

# Replace as a REAL file — drop any prior symlink first so the move can't write
# through it back into the tracked source.
rm -f "$target"
mv "$tmp_rendered" "$target"
rm -f "$tmp"
trap - EXIT
