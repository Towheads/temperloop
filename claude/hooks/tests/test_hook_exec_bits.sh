#!/usr/bin/env bash
# Every INVOKED hook under claude/hooks/ must be committed executable
# (git mode 100755) — temperloop#1836.
#
# WHY THIS IS ITS OWN CHECK, and why no other test can stand in for it:
# `make test-hooks` runs each suite as `bash "$t"`, and every hook suite in
# turn drives its hook as `bash "$HOOK"`. An explicit interpreter IGNORES the
# exec bit entirely, so a hook committed 100644 passes its whole behavioural
# suite while being structurally dead in production. The install path is what
# makes that fatal: `~/.claude/hooks` is a SYMLINK to the tracked checkout
# (workflows/scripts/install/links.sh § claude/* entries), a symlink carries
# its TARGET's mode, and settings.json registers each hook as a BARE ABSOLUTE
# PATH with no interpreter prefix. A non-executable hook therefore exits 126 on
# every matching tool call and the guard silently never fires. That is exactly
# how claude-p-spawn-guard.sh shipped in its first review round: 44/44 green,
# and inert once installed.
#
# So this asserts the one property `bash "$HOOK"` can never observe: the mode
# recorded in GIT, which is what a fresh clone and the install symlink resolve.
#
# RELATIONSHIP TO workflows/scripts/validate-exec-bit-registry.sh — these are
# complements, not duplicates, and #1836 registered claude/hooks/ there in the
# same change (correcting that registry's standing note that hooks "do not
# qualify"). The registry is the repo-sanctioned, `checks`-wired gate; it is
# OPT-IN PER PATH and checks the FILESYSTEM bit. This file is auto-discovering
# (a new hook is covered with no registry row to remember) and checks the GIT
# INDEX mode — which the filesystem predicate cannot see in a dirty local
# checkout, where a `chmod +x` without a staged mode change passes locally and
# still lands 100644 for every fresh clone.
#
# SOURCED vs INVOKED is derived MECHANICALLY, not hand-listed: a hook is
# "sourced" iff some sibling hook has a `. …/<name>` or `source …/<name>` line.
# eval-guard.sh is the only such file today, and it is legitimately 100644.
# A hand-maintained exclusion list would rot the moment a second shared helper
# lands; this cannot.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOKS_DIR=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$HOOKS_DIR/../.." && pwd)

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  ✗ %s\n' "$1"; }

echo "== hook exec bits =="

# Is <basename> sourced by a sibling hook? (`. …/name` or `source …/name`)
is_sourced() {
  local name="$1" f
  for f in "$HOOKS_DIR"/*.sh; do
    [ "$(basename "$f")" = "$name" ] && continue
    if grep -qE "^[[:space:]]*(\.|source)[[:space:]]+.*/${name}\"?[[:space:]]*$" "$f"; then
      return 0
    fi
  done
  return 1
}

# git index mode for a tracked path, empty if untracked or git unavailable.
index_mode() {
  git -C "$ROOT" ls-files -s -- "claude/hooks/$1" 2>/dev/null | awk '{print $1}'
}

have_git=0
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && have_git=1
[ "$have_git" -eq 1 ] || printf '  ! git unavailable — checking filesystem mode only\n'

checked=0
for f in "$HOOKS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  name=$(basename "$f")

  if is_sourced "$name"; then
    ok "$name — sourced helper, exec bit not required"
    continue
  fi

  checked=$((checked + 1))

  # (a) filesystem bit — what an exec of the working copy needs.
  if [ -x "$f" ]; then ok "$name — filesystem +x"
  else bad "$name — NOT executable on disk (chmod +x claude/hooks/$name)"; fi

  # (b) git index mode — what a fresh clone and the install symlink resolve.
  #     This is the half a `bash "$HOOK"` test structurally cannot see.
  if [ "$have_git" -eq 1 ]; then
    mode=$(index_mode "$name")
    if [ -z "$mode" ]; then
      ok "$name — untracked, no git mode to assert"
    elif [ "$mode" = "100755" ]; then
      ok "$name — git mode 100755"
    else
      bad "$name — git mode $mode, want 100755 (git update-index --chmod=+x claude/hooks/$name)"
    fi
  fi
done

# A guard on the guard: if the glob or the sourced-detection ever went wrong and
# excluded everything, the loop above would pass vacuously. Require real work.
if [ "$checked" -ge 2 ]; then
  ok "checked $checked invoked hooks (non-vacuous)"
else
  bad "only $checked invoked hooks found — enumeration is broken, not clean"
fi

# The specific regression this file was born for (temperloop#1836): assert the
# guard by NAME as well as by the glob, so deleting it from the glob's reach
# cannot quietly retire the check.
if [ "$have_git" -eq 1 ] && [ -f "$HOOKS_DIR/claude-p-spawn-guard.sh" ]; then
  m=$(index_mode "claude-p-spawn-guard.sh")
  if [ "$m" = "100755" ]; then ok "claude-p-spawn-guard.sh committed 100755 (named regression)"
  else bad "claude-p-spawn-guard.sh git mode '$m', want 100755 (named regression)"; fi
fi

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d hook exec-bit checks passed\n' "$pass"
