#!/usr/bin/env bash
#
# Regression test for the zsh special-parameter tie (temperloop#40, surfaced
# from <org>/foundation#987). Under zsh the lowercase array `path` is tied to
# `PATH`, so a `local path=…` in a *sourced* function silently rebinds `PATH` for
# that scope — which made `_ks_bm_project_add` (knowledge_search.sh) clobber
# `PATH` to the vault root and lose `uvx` (exit 127 -> ks exit 4). bash treats
# `path` as an ordinary variable, so the existing bash suite + shellcheck are
# blind to it; this test therefore shells out to ZSH to reproduce, with a fake
# `uvx` on PATH, and asserts the fake was reachable — i.e. PATH survived the
# dispatch. Skips cleanly where zsh is not installed (e.g. some CI runners).
#
# Verified: PASS on the fix, FAIL on the pre-fix `local path=` code.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-zsh-tie-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
MARKER="$TMP/uvx-was-reached"
VAULT="$TMP/vault"; mkdir -p "$VAULT"

# Fake `uvx`: if PATH survived the sourced dispatch, zsh finds this and it
# stamps the marker. If a tied `path` local clobbered PATH, it is unreachable.
cat > "$BIN/uvx" <<EOF
#!/usr/bin/env bash
echo reached > "$MARKER"
exit 0
EOF
chmod +x "$BIN/uvx"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -n "${out:-}" ] && printf '  output: %s\n' "$out" >&2
  exit 1
}

set +e
out="$(PATH="$BIN:$PATH" KNOWLEDGE_STORE_ROOT="$VAULT" KNOWLEDGE_SEARCH_BM_PROJECT=proj \
  KNOWLEDGE_SEARCH_BM_HOME="$TMP/bm-home" \
  zsh -c "source '$STORE_LIB'; source '$SEARCH_LIB'; _ks_bm_project_add proj '$VAULT'" 2>&1)"
rc=$?
set -e

[ -f "$MARKER" ] || fail "fake uvx never reached under zsh — PATH clobbered by a tied \`path\` local (temperloop#40 / F#987)"
[ "$rc" -eq 0 ]   || fail "_ks_bm_project_add exited $rc under zsh (expected 0)"
echo "PASS: knowledge_search dispatch preserves PATH under zsh (temperloop#40 / F#987)"
