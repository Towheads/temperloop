#!/usr/bin/env bash
#
# Regression test for the zsh special-parameter tie (temperloop#40, surfaced
# from <org>/foundation#987). Under zsh the lowercase array `path` is tied to
# `PATH`, so a `local path=…` in a *sourced* function silently rebinds `PATH` for
# that scope — which made `_ks_bm_project_add` (knowledge_search.sh) clobber
# `PATH` and lose the subprocess tooling (exit 127 -> ks exit 4). bash treats
# `path` as an ordinary variable, so the existing bash suite + shellcheck are
# blind to it; this test therefore shells out to ZSH to reproduce and asserts
# that every PATH-resolved step in the dispatch was still reachable. Skips
# cleanly where zsh is not installed (e.g. some CI runners).
#
# WHAT THE PATH-DEPENDENT STEPS ARE, since temperloop#1113. The adapter no
# longer resolves `uvx --from basic-memory==<pin>` per run — it installs the
# pin once as a uv tool and invokes the installed entry point by ABSOLUTE
# path, which is PATH-independent on its own. So this test drives the whole
# cold chain rather than one function: the availability gate's `command -v uv`
# and its `env … uv tool install` (both PATH-resolved), then a search whose
# first attempt MISSES and re-enters `_ks_bm_project_add` — the historical
# bug site — before retrying. A tied `path` local anywhere in that chain makes
# `uv` (or `env`, or `jq`) unresolvable and the run cannot complete.
#
# Verified: PASS on the fix, FAIL on the pre-fix `local path=` code.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$HERE/.." && pwd)"
STORE_LIB="$LIB_DIR/knowledge_store.sh"
SEARCH_LIB="$LIB_DIR/knowledge_search.sh"

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ks-zsh-tie-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
MARKER="$TMP/bm-was-reached"
ADD_MARKER="$TMP/project-add-was-reached"
REGISTERED="$TMP/registered"
VAULT="$TMP/vault"; mkdir -p "$VAULT"
BM_HOME="$TMP/bm-home"
BM_BIN="$BM_HOME/uv-tool-bin/basic-memory"

# The fake ENTRY POINT, written by the fake `uv` below exactly as a real
# `uv tool install` would write it. Stamps a marker on every invocation, and
# reproduces the #996 lazy-on-miss chain: search misses until `project add`
# has run, so `_ks_bm_project_add` (the historical `local path=` site) is
# genuinely exercised inside the zsh run.
cat > "$TMP/basic-memory.template" <<EOF
#!/usr/bin/env bash
echo reached > "$MARKER"
sub="\${1:-}"; shift || true
case "\$sub" in
  project)
    if [ "\${1:-}" = "add" ]; then
      echo reached > "$ADD_MARKER"
      : > "$REGISTERED"
      echo "Project added"
      exit 0
    fi
    ;;
  tool)
    if [ "\${1:-}" = "search-notes" ]; then
      [ -f "$REGISTERED" ] || { echo "project not found" >&2; exit 1; }
      echo '{"results":[{"title":"Foo","score":1.0,"content":"c","matched_chunk":"c","file_path":"Decisions/foo.md"}]}'
      exit 0
    fi
    ;;
esac
echo "fake-bm: unhandled: \$sub \$*" >&2
exit 9
EOF

# Fake `uv`: PATH-resolved by the availability gate. If a tied `path` local
# clobbered PATH, this is unreachable and nothing downstream can run.
cat > "$BIN/uv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "tool" ] && [ "\${2:-}" = "install" ] || { echo "fake-uv: unsupported: \$*" >&2; exit 9; }
: "\${UV_TOOL_BIN_DIR:?fake-uv: UV_TOOL_BIN_DIR must be pinned by the adapter}"
mkdir -p "\$UV_TOOL_BIN_DIR"
cp "$TMP/basic-memory.template" "\$UV_TOOL_BIN_DIR/basic-memory"
chmod +x "\$UV_TOOL_BIN_DIR/basic-memory"
exit 0
EOF
chmod +x "$BIN/uv"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ -n "${out:-}" ] && printf '  output: %s\n' "$out" >&2
  exit 1
}

set +e
out="$(PATH="$BIN:$PATH" KNOWLEDGE_STORE_ROOT="$VAULT" KNOWLEDGE_SEARCH_BM_PROJECT=proj \
  KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME" \
  KNOWLEDGE_READ_LOG="$TMP/knowledge-reads.log" \
  zsh -c "source '$STORE_LIB'; source '$SEARCH_LIB'; ks_search 'orchard' --limit 3" 2>&1)"
rc=$?
set -e

[ -x "$BM_BIN" ] \
  || fail "the availability gate never installed the entry point under zsh — \`uv\` unreachable, PATH clobbered by a tied \`path\` local (temperloop#40 / F#987)"
[ -f "$MARKER" ] \
  || fail "the installed basic-memory entry point was never reached under zsh (temperloop#40 / F#987)"
[ -f "$ADD_MARKER" ] \
  || fail "_ks_bm_project_add — the historical \`local path=\` site — was never reached under zsh"
[ "$rc" -eq 0 ] || fail "ks_search exited $rc under zsh (expected 0)"
echo "PASS: knowledge_search dispatch preserves PATH under zsh across the install gate and the lazy project-add retry (temperloop#40 / F#987)"
