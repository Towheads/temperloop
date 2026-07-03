#!/usr/bin/env bash
#
# Regression test for foundation #82: board.sh must source AND run its accessors
# cleanly under zsh. 'status' is zsh's read-only alias for $?, so the pre-fix
# 'local … status' inside board_capture_item aborted with
#   board_capture_item:…: read-only variable: status
# under the Claude Code Bash tool (which runs zsh). The fix renames the local to
# 'item_status'. Skips cleanly where zsh is not installed (CI runners may lack it).
set -euo pipefail

if ! command -v zsh >/dev/null 2>&1; then
  echo "SKIP: zsh not installed"
  exit 0
fi

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/board.sh"

# 1) The adapter must source cleanly under zsh (the documented '$BOARD_LIB at the
#    top of every board bash block' pattern assumes this).
zsh -c "source '$LIB'" 2>&1 \
  || { echo "FAIL: board.sh does not source under zsh"; exit 1; }

# 2) board_capture_item must RUN under zsh — the collision is a runtime error at
#    the function's 'local' line, not a parse error. Stub the network seams so the
#    function exercises the 'local … item_status' declaration + the
#    BOARD_ITEMS_JSON status read offline. Pre-fix this aborts at function entry.
out="$(zsh -c '
  source "'"$LIB"'"
  board_resolve_item() { :; }                              # no network
  board_item_id() { print -r -- "PVTI_test"; }             # pretend item is indexed
  board_set_status() { print -r -- "set_status called"; }  # must NOT fire (already statused)
  BOARD_ITEMS_JSON='\''{"items":[{"content":{"number":1},"status":"Backlog"}]}'\''
  board_capture_item 4 "https://example/1" 1 && print -r -- "OK"
' 2>&1)" || { echo "FAIL: board_capture_item errored under zsh:"; echo "$out"; exit 1; }

case "$out" in
  *"read-only variable"*) echo "FAIL: zsh \$status collision still present:"; echo "$out"; exit 1 ;;
  *"set_status called"*)  echo "FAIL: board_set_status fired though item already statused:"; echo "$out"; exit 1 ;;
  *OK*)                   echo "PASS: board.sh runs cleanly under zsh (foundation #82)" ;;
  *)                      echo "FAIL: unexpected output:"; echo "$out"; exit 1 ;;
esac
