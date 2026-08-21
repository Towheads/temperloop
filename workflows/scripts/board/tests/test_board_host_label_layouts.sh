#!/usr/bin/env bash
#
# Regression test for temperloop#1422 — test_board_host_label.sh's structural
# check ("exactly one site inlines the SUBSET_HOST_LABEL fallback chain")
# used a recursive grep, so its VERDICT was a function of the host's grep and
# of how the tree was vendored rather than of the code it audits:
#
#   * board dir IS a symlink (foundation and every other vendoring overlay:
#     workflows/scripts/board -> ../../kernel/workflows/scripts/board):
#     GNU grep -r descends into a symlinked top-level argument, real
#     macOS/BSD grep does not (`-R` does not help either). Green on Linux
#     CI, red on every operator's Mac, same tree same commit.
#   * board dir is a REAL dir whose FILES are per-file symlinks into a
#     vendored kernel/ copy: `-r` on NEITHER grep follows a symlink met
#     during the walk, so that layout was red on BOTH platforms.
#
# The fix enumerates with `find -L` and hands grep real files by name. This
# suite is the lock on that: it materializes all three layouts and proves the
# subject test gives the SAME verdict in each, under EVERY distinct grep
# reachable on this host — and, crucially, that the verdict is still
# DISCRIMINATING in each (a second inlining site turns it red, removing that
# site turns it green again). A portability fix that merely made the check
# stop failing — by hollowing the assertion out — would pass the first half
# and fail the second.
#
# NOTE ON THIS FILE'S OWN TEXT: it deliberately never spells the inlined
# fallback expression literally, in prose or in code. The subject test walks
# every file under the board dir except ITSELF, so a literal here would make
# this suite register as a genuine second inlining site and turn the subject
# permanently red. The decoy fixture is therefore assembled at run time from
# CHAIN_HEAD below rather than written out as a heredoc.
#
# No network, no gh call: everything runs against a scratch copy of the board
# toolkit under $TMPDIR.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BOARD_DIR="$(cd "$HERE/.." && pwd -P)"
SUBJECT_NAME="test_board_host_label.sh"
BUILD_MIRROR_SRC="$(cd "$HERE/../../build" && pwd -P)/board-mirror.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/board-host-label-layouts-XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- grep flavors -----------------------------------------------------------
# The bug's whole point is that two greps disagree, so run every distinct one
# this host can reach: whatever `grep` PATH currently resolves to; the SYSTEM
# grep at /usr/bin/grep (real BSD grep on macOS — the flavor that produced
# the bug — and the same GNU binary on Linux); and a `ggrep` if one is
# installed (GNU grep under its Homebrew name, so a macOS run covers BOTH
# sides of the divergence rather than only the BSD side). Duplicates collapse
# by resolved path, so on Linux CI this is one flavor and on a Homebrew Mac
# it is two.
# Each flavor is forced by prepending a shim dir whose only entry is a `grep`
# symlink — shrinking PATH instead would strip the `hostname`/`mktemp` the
# subject test itself needs.
flavor_names=()
flavor_shims=()
seen_greps=""
add_flavor() {
  local label="$1" bin="$2" shim
  [ -x "$bin" ] || return 0
  case " $seen_greps " in *" $bin "*) return 0 ;; esac
  seen_greps="$seen_greps $bin"
  shim="$TMP/shim-$label"
  mkdir -p "$shim"
  ln -s "$bin" "$shim/grep"
  flavor_names+=("$label ($bin)")
  flavor_shims+=("$shim")
}
default_grep="$(command -v grep || true)"
[ -n "$default_grep" ] || fail "no grep on PATH"
add_flavor "path" "$(cd "$(dirname "$default_grep")" && pwd -P)/$(basename "$default_grep")"
add_flavor "system" "/usr/bin/grep"
gnu_grep="$(command -v ggrep || true)"
if [ -n "$gnu_grep" ]; then
  add_flavor "gnu" "$gnu_grep"
fi

# --- layout fixtures --------------------------------------------------------
# Every fixture holds a physical `kernel/` copy of the board toolkit; the
# layouts differ only in HOW the entry path reaches it, which is exactly the
# axis the bug lived on.
#
#   real     — the kernel repo's own shape: the entry IS the physical dir.
#   dirlink  — the live overlay shape: workflows/scripts/board is a SYMLINK
#              to the kernel copy.
#   perfile  — the other vendoring shape: real directories, every regular
#              file a relative symlink into the kernel copy.
mk_layout() {
  local layout="$1" root="$2" kbase
  kbase="$root/kernel/workflows/scripts"
  mkdir -p "$kbase"
  cp -R "$BOARD_DIR" "$kbase/board"
  mkdir -p "$kbase/build"
  cp "$BUILD_MIRROR_SRC" "$kbase/build/board-mirror.sh"
  case "$layout" in
    real)
      printf '%s\n' "$kbase/board"
      ;;
    dirlink)
      mkdir -p "$root/workflows/scripts"
      ln -s "../../kernel/workflows/scripts/board" "$root/workflows/scripts/board"
      ln -s "../../kernel/workflows/scripts/build" "$root/workflows/scripts/build"
      printf '%s\n' "$root/workflows/scripts/board"
      ;;
    perfile)
      mkdir -p "$root/workflows/scripts/board"
      ln -s "../../kernel/workflows/scripts/build" "$root/workflows/scripts/build"
      ( cd "$kbase/board" && find . -type d -print ) | while IFS= read -r d; do
        mkdir -p "$root/workflows/scripts/board/${d#./}"
      done
      ( cd "$kbase/board" && find . -type f -print ) | while IFS= read -r f; do
        rel="${f#./}"
        depth="$(printf '%s' "$rel" | tr -cd '/' | wc -c | tr -d ' ')"
        up=""
        i=0
        while [ "$i" -lt $((depth + 3)) ]; do
          up="../$up"
          i=$((i + 1))
        done
        ln -sf "${up}kernel/workflows/scripts/board/$rel" "$root/workflows/scripts/board/$rel"
      done
      [ -f "$root/workflows/scripts/board/lib/board.sh" ] || \
        fail "perfile fixture produced DANGLING symlinks — the layout under test would be untested, not tested"
      printf '%s\n' "$root/workflows/scripts/board"
      ;;
    *) fail "unknown layout $layout" ;;
  esac
}

# Run the subject test through $entry_board under one grep flavor; echo its
# exit status. Its output is captured to $TMP/out so a red run does not get
# mistaken for this suite's own output.
run_subject() {
  local entry_board="$1" shim="$2" rc=0
  PATH="$shim:$PATH" bash "$entry_board/tests/$SUBJECT_NAME" >"$TMP/out" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# The decoy is a SECOND site inlining the chain — the exact thing the subject
# test exists to catch. CHAIN_HEAD is split so this file never carries the
# literal (see NOTE ON THIS FILE'S OWN TEXT above); the emitted decoy line is
# the pre-fix board-mirror.sh variant, verbatim.
DECOY_REL="zz_decoy_second_inline_site.sh"
# shellcheck disable=SC2016  # single quotes are the point: these are literals
# written INTO the decoy file, not expressions to expand here.
CHAIN_HEAD='${SUBSET_HOST_LABEL'
add_decoy() {
  # shellcheck disable=SC2016
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'host_label="%s:-${STAGEFIND_HOST_LABEL:-$(hostname -s)}}"\n' "$CHAIN_HEAD"
    printf '%s\n' 'printf "%s\\n" "$host_label"'
  } >"$1/$DECOY_REL"
}
rm_decoy() { rm -f "$1/$DECOY_REL"; }

# --- the matrix -------------------------------------------------------------
checked=0
for layout in real dirlink perfile; do
  root="$TMP/$layout"
  mkdir -p "$root"
  entry="$(mk_layout "$layout" "$root")"

  fi=0
  while [ "$fi" -lt "${#flavor_names[@]}" ]; do
    flavor="${flavor_names[$fi]}"
    shim="${flavor_shims[$fi]}"
    fi=$((fi + 1))

    rc="$(run_subject "$entry" "$shim")"
    [ "$rc" -eq 0 ] || fail "layout=$layout grep=$flavor: clean tree should be GREEN, got exit $rc:
$(cat "$TMP/out")"

    add_decoy "$entry"
    rc="$(run_subject "$entry" "$shim")"
    if [ "$rc" -eq 0 ]; then
      rm_decoy "$entry"
      fail "layout=$layout grep=$flavor: a SECOND inlining site ($DECOY_REL) did NOT turn the check red — the assertion is hollow there, not portable:
$(cat "$TMP/out")"
    fi
    if ! grep -F "$DECOY_REL" "$TMP/out" >/dev/null; then
      rm_decoy "$entry"
      fail "layout=$layout grep=$flavor: went red but did not NAME $DECOY_REL — red for the wrong reason:
$(cat "$TMP/out")"
    fi

    rm_decoy "$entry"
    rc="$(run_subject "$entry" "$shim")"
    [ "$rc" -eq 0 ] || fail "layout=$layout grep=$flavor: removing $DECOY_REL should return to GREEN, got exit $rc:
$(cat "$TMP/out")"

    checked=$((checked + 1))
  done
done

[ "$checked" -ge 3 ] || fail "expected at least 3 layout x grep cells, ran $checked"

echo "OK — $SUBJECT_NAME: identical, still-discriminating verdict across ${#flavor_names[@]} grep flavor(s) x 3 layouts (real, dirlink, perfile) = $checked cells"
