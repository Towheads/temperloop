#!/usr/bin/env bash
#
# Tests for workflows/scripts/install-settings.sh — the settings.json reconcile
# that keeps the `model` field machine-local instead of symlinking it back into
# the tracked source (foundation #292). No network, throwaway tmpdir, jq asserts.
#
# Covers:
#   1. fresh (no target)      -> copies tracked verbatim, target is a REAL file
#   2. existing local model   -> model preserved, other fields taken from tracked
#   3. symlink target         -> replaced with a real file (model read through it)
#   4. tracked field change   -> propagates (non-model fields always win from tracked)
#   5. idempotent             -> second run yields byte-identical output
#   6. no model in tracked    -> no model in output, still valid
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/install-settings.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/install-settings-test-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

tracked="$TMP/tracked.json"
target="$TMP/target.json"

# --- 1. fresh: no target -> verbatim copy, REAL file -------------------------
printf '{"model":"opus","hooks":{"a":1},"permissions":{"allow":["x"]}}' >"$tracked"
rm -f "$target"
bash "$SCRIPT" "$tracked" "$target"
[ -f "$target" ] && [ ! -L "$target" ] || fail "1: target must be a real (non-symlink) file"
[ "$(jq -r .model "$target")" = "opus" ] || fail "1: fresh install should seed tracked model (got $(jq -r .model "$target"))"
[ "$(jq -c .hooks "$target")" = '{"a":1}' ] || fail "1: fresh install should copy tracked hooks"
echo "PASS: fresh install copies tracked verbatim as a real file"

# --- 2. existing local model preserved; other fields from tracked ------------
printf '{"model":"claude-fable-5","hooks":{"a":1},"permissions":{"allow":["x"]}}' >"$target"
# tracked changed: model seed differs AND a non-model field changed
printf '{"model":"opus","hooks":{"a":2},"permissions":{"allow":["x","y"]}}' >"$tracked"
bash "$SCRIPT" "$tracked" "$target"
[ "$(jq -r .model "$target")" = "claude-fable-5" ] || fail "2: local model must be preserved (got $(jq -r .model "$target"))"
[ "$(jq -c .hooks "$target")" = '{"a":2}' ] || fail "2: non-model field must take tracked's new value"
[ "$(jq -c '.permissions.allow' "$target")" = '["x","y"]' ] || fail "2: permissions must propagate from tracked"
echo "PASS: re-install preserves local model, propagates every other field from tracked"

# --- 3. symlink target replaced with a real file -----------------------------
printf '{"model":"claude-haiku-4-5","hooks":{"a":3}}' >"$TMP/real-source.json"
ln -sf "$TMP/real-source.json" "$target"
[ -L "$target" ] || fail "3: setup — target should be a symlink"
bash "$SCRIPT" "$tracked" "$target"
[ ! -L "$target" ] || fail "3: symlink target must be replaced with a real file"
[ "$(jq -r .model "$target")" = "claude-haiku-4-5" ] || fail "3: model read through the symlink must be preserved"
# the original symlink source must NOT have been written through
[ "$(jq -r .model "$TMP/real-source.json")" = "claude-haiku-4-5" ] || fail "3: must NOT write through the old symlink into its source"
echo "PASS: symlink target is replaced by a real file, source never written through"

# --- 4. tracked field change always propagates (non-model) -------------------
printf '{"model":"opus","statusLine":"OLD"}' >"$target"
printf '{"model":"opus","statusLine":"NEW"}' >"$tracked"
bash "$SCRIPT" "$tracked" "$target"
[ "$(jq -r .statusLine "$target")" = "NEW" ] || fail "4: tracked non-model change must propagate"
echo "PASS: tracked non-model changes propagate on reconcile"

# --- 5. idempotent: second run is byte-identical -----------------------------
cp "$target" "$TMP/first.json"
bash "$SCRIPT" "$tracked" "$target"
diff -q "$TMP/first.json" "$target" >/dev/null || fail "5: reconcile is not idempotent"
echo "PASS: reconcile is idempotent"

# --- 6. tracked with no model -> output has no model, still valid -------------
printf '{"hooks":{"a":1}}' >"$tracked"
rm -f "$target"
bash "$SCRIPT" "$tracked" "$target"
jq -e . "$target" >/dev/null || fail "6: output must be valid JSON"
[ "$(jq -r '.model // "NONE"' "$target")" = "NONE" ] || fail "6: no model in tracked -> no model in output"
echo "PASS: tracked with no model yields valid model-less output"

# --- 7. literal canonical-user paths render from $HOME, not hardcoded (#773) --
FAKEHOME="$TMP/fakehome-xdg-test"
mkdir -p "$FAKEHOME"
printf '{"model":"opus","hooks":{"h":"/Users/travis/.claude/hooks/x.sh"},"statusLine":{"command":"/Users/travis/.claude/status-line.sh"}}' >"$tracked"
rm -f "$target"
HOME="$FAKEHOME" bash "$SCRIPT" "$tracked" "$target"
! grep -q '/Users/travis' "$target" || fail "7: rendered output must not contain a literal /Users/travis path"
[ "$(jq -r '.hooks.h' "$target")" = "$FAKEHOME/.claude/hooks/x.sh" ] || fail "7: hook path must derive from the render-time \$HOME"
[ "$(jq -r '.statusLine.command' "$target")" = "$FAKEHOME/.claude/status-line.sh" ] || fail "7: statusLine path must derive from the render-time \$HOME"
echo "PASS: literal canonical-user (/Users/travis) paths render from \$HOME at install time"

# --- 8. path rendering is idempotent under a fake \$HOME ----------------------
cp "$target" "$TMP/second-first.json"
HOME="$FAKEHOME" bash "$SCRIPT" "$tracked" "$target"
diff -q "$TMP/second-first.json" "$target" >/dev/null || fail "8: path-rendered reconcile is not idempotent"
echo "PASS: path rendering is idempotent under a fake \$HOME"

echo "PASS: install-settings.sh reconciles settings.json keeping model machine-local while propagating every other field from the tracked template (#292), and renders every canonical-user path from \$HOME at install time (#773)"
