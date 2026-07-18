#!/usr/bin/env bash
#
# Tests for uninstall.sh — `temperloop uninstall` (temperloop#265, ADR K164
# D7 "install manifest" amendment). Same fixture posture as
# workflows/scripts/tests/test_install_manifest.sh (the library this script
# wraps) but exercises the CLI file itself, invoked directly (bypassing the
# `temperloop` dispatcher's claude/gh prereq gate — the same idiom
# test_eject.sh already uses, since this subcommand never calls either
# tool).
#
# SIBLING-COORDINATION NOTE: a parallel worker is building `temperloop
# install` in the same epic. This suite NEVER runs install.sh or depends on
# it in any way — every fixture manifest entry is seeded directly via the
# manifest library's own write helper, manifest_backup_and_record(), inside
# the hermetic sandbox (workflows/scripts/tests/lib/sandbox.sh). That is the
# pinned fixture strategy for this item.
#
# Covers (acceptance criteria 1, 3, 4 of temperloop#265):
#   1. A "created" entry is removed, a "preexisting" entry is restored from
#      its recorded backup, a decoy file with NO manifest entry survives
#      untouched, and a machine conf under $XDG_CONFIG_HOME/temperloop/
#      (also absent from the manifest) survives untouched.
#   2. --dry-run performs zero writes: every file and the manifest itself
#      are byte-identical before/after.
#   3. Consent mirrors eject.sh's --yes/interactive pattern: --yes proceeds;
#      non-interactive with no --yes aborts (zero writes).
#   4. An unreadable/newer manifest schema_version produces manifest.sh's
#      own legible refusal (uninstall.sh surfaces it, exit 1) rather than
#      any partial deletion.
#   5. A partial failure (a "preexisting" entry whose recorded backup file
#      is missing) leaves that one entry recorded for a retry, resolves
#      every other entry, and reports exit 1 — a bare bash-array-mechanics
#      check that isn't already covered by the library's own test suite.
#
# No network. Every test runs inside a throwaway sandbox HOME/XDG root —
# nothing touches real machine state.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
UNINSTALL="$HERE/../uninstall.sh"
MANIFEST_SH="$REPO_ROOT/workflows/scripts/install/manifest.sh"
SANDBOX_LIB="$REPO_ROOT/workflows/scripts/tests/lib/sandbox.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# shellcheck source=../../../workflows/scripts/tests/lib/sandbox.sh
source "$SANDBOX_LIB"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# seed_created <path> — records <path> as a "created" entry (nothing exists
# there yet), THEN simulates an install actually writing it. Uses
# manifest_backup_and_record — the library's own write helper — never a
# live install run (sibling-coordination pin, see header).
seed_created() {
  local path="$1" content="$2"
  sandbox_bash '
    source "'"$MANIFEST_SH"'"
    mkdir -p "$(dirname "'"$path"'")"
    manifest_backup_and_record "'"$path"'" >/dev/null
  ' || fail "seed_created: recording $path failed"
  printf '%s' "$content" > "$path"
}

# seed_preexisting <path> <original-content> — writes <original-content> to
# <path>, THEN records it via manifest_backup_and_record (which backs up
# that original content), THEN simulates install overwriting it.
seed_preexisting() {
  local path="$1" original="$2" replacement="$3"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$original" > "$path"
  sandbox_bash '
    source "'"$MANIFEST_SH"'"
    manifest_backup_and_record "'"$path"'" >/dev/null
  ' || fail "seed_preexisting: recording $path failed"
  printf '%s' "$replacement" > "$path"
}

manifest_path_count() {
  sandbox_bash '
    source "'"$MANIFEST_SH"'"
    manifest_load | jq "[.paths|keys[]]|length"
  '
}

run_uninstall() {
  sandbox_run bash "$UNINSTALL" "$@" </dev/null
}

# =============================================================================
# Test 1: created removed, preexisting restored, decoy survives, XDG_CONFIG
#         machine conf survives — the core manifest-scoping guarantee.
# =============================================================================
sandbox_up uninstall-test1

created1="$SANDBOX_HOME/.local/bin/claim"
seed_created "$created1" "installed content"
[ -f "$created1" ] || fail "1: setup — created path should exist before uninstall"

preexisting1="$SANDBOX_HOME/.zshrc"
seed_preexisting "$preexisting1" "operator original" "managed replacement"
[ "$(cat "$preexisting1")" = "managed replacement" ] || fail "1: setup — preexisting path should hold the replacement before uninstall"

decoy1="$SANDBOX_HOME/.never-recorded"
printf 'decoy content, never in the manifest\n' > "$decoy1"

confdir1="$SANDBOX_XDG_CONFIG_HOME/temperloop"
mkdir -p "$confdir1"
conf1="$confdir1/config.toml"
printf 'user-edited machine conf, never in the manifest\n' > "$conf1"

[ "$(manifest_path_count)" = "2" ] || fail "1: setup — manifest should have exactly 2 entries before uninstall"

out1="$(run_uninstall --yes 2>&1)" && rc1=0 || rc1=$?
[ "$rc1" -eq 0 ] || fail "1: uninstall --yes should exit 0 (got rc=$rc1, out: $out1)"
echo "$out1" | grep -q "temperloop uninstall: done" || fail "1: expected a done status line (got: $out1)"

[ ! -e "$created1" ] || fail "1: a 'created' entry's path must be removed after uninstall"
[ -f "$preexisting1" ] || fail "1: a 'preexisting' entry's path must still exist after uninstall (restored, not removed)"
[ "$(cat "$preexisting1")" = "operator original" ] || fail "1: a 'preexisting' entry must be restored to its ORIGINAL content"

[ -f "$decoy1" ] || fail "1: a decoy path with NO manifest entry must survive uninstall"
[ "$(cat "$decoy1")" = "decoy content, never in the manifest" ] || fail "1: the decoy path's content must be untouched"

[ -f "$conf1" ] || fail "1: a machine conf under \$XDG_CONFIG_HOME/temperloop/ (absent from the manifest) must survive uninstall"
[ "$(cat "$conf1")" = "user-edited machine conf, never in the manifest" ] || fail "1: the machine conf's content must be untouched"

[ "$(manifest_path_count)" = "0" ] || fail "1: manifest should have 0 entries after a fully successful uninstall"

echo "$out1" | grep -q "Bootstrap footprint" || fail "1: expected the bootstrap-footprint guidance bullet (got: $out1)"
echo "$out1" | grep -q "Issue-cache store root" || fail "1: expected the cache-store-root guidance bullet (got: $out1)"
echo "$out1" | grep -q "temperloop init" || fail "1: expected the eject reminder (got: $out1)"

sandbox_down
echo "PASS: 1 (created removed, preexisting restored from backup, decoy + XDG_CONFIG_HOME conf survive)"

# =============================================================================
# Test 2: --dry-run performs zero writes.
# =============================================================================
sandbox_up uninstall-test2

created2="$SANDBOX_HOME/.local/bin/claim"
seed_created "$created2" "installed content"
preexisting2="$SANDBOX_HOME/.zshrc"
seed_preexisting "$preexisting2" "operator original" "managed replacement"

before_manifest2="$(sandbox_bash 'source "'"$MANIFEST_SH"'"; manifest_load')"

out2="$(run_uninstall --dry-run 2>&1)" && rc2=0 || rc2=$?
[ "$rc2" -eq 0 ] || fail "2: --dry-run should exit 0 (got rc=$rc2, out: $out2)"
echo "$out2" | grep -q "dry run" || fail "2: expected dry-run to be reported (got: $out2)"

[ -f "$created2" ] || fail "2: --dry-run must not remove a 'created' path"
[ "$(cat "$created2")" = "installed content" ] || fail "2: --dry-run must not alter a 'created' path's content"
[ "$(cat "$preexisting2")" = "managed replacement" ] || fail "2: --dry-run must not restore a 'preexisting' path (still the managed replacement)"

after_manifest2="$(sandbox_bash 'source "'"$MANIFEST_SH"'"; manifest_load')"
[ "$before_manifest2" = "$after_manifest2" ] || fail "2: --dry-run must leave the manifest byte-identical"

sandbox_down
echo "PASS: 2 (--dry-run performs zero writes: files and manifest byte-identical before/after)"

# =============================================================================
# Test 3: consent mirrors eject.sh — --yes proceeds (covered by test 1);
#         non-interactive with no --yes aborts, zero writes.
# =============================================================================
sandbox_up uninstall-test3

created3="$SANDBOX_HOME/.local/bin/claim"
seed_created "$created3" "installed content"

out3="$(run_uninstall 2>&1)" && rc3=0 || rc3=$?
[ "$rc3" -eq 0 ] || fail "3: a declined/non-interactive run should exit 0 (legible no-op, got rc=$rc3)"
echo "$out3" | grep -q "aborted — nothing touched" || fail "3: expected the abort message (got: $out3)"
[ -f "$created3" ] || fail "3: a declined uninstall must not remove any path"
[ "$(manifest_path_count)" = "1" ] || fail "3: a declined uninstall must leave the manifest untouched"

sandbox_down
echo "PASS: 3 (non-interactive, no --yes -> aborts, zero writes, manifest untouched)"

# =============================================================================
# Test 4: an unreadable/newer manifest schema_version -> legible refusal,
#         exit 1, no partial deletion (a decoy survives).
# =============================================================================
sandbox_up uninstall-test4

mkdir -p "$SANDBOX_XDG_STATE_HOME/temperloop"
printf '{"schema_version":99,"paths":{"%s":{"state":"created","backup_path":null}}}' \
  "$SANDBOX_HOME/should-never-be-touched" > "$SANDBOX_XDG_STATE_HOME/temperloop/install-manifest.json"

decoy4="$SANDBOX_HOME/should-never-be-touched"
printf 'must survive — the manifest that would have named this is unreadable\n' > "$decoy4"

out4="$(run_uninstall --yes 2>&1)" && rc4=0 || rc4=$?
[ "$rc4" -ne 0 ] || fail "4: an unknown schema_version must be refused (nonzero exit)"
echo "$out4" | grep -q "schema_version=99" || fail "4: refusal must name the exact version found (got: $out4)"
echo "$out4" | grep -q "refusing to proceed" || fail "4: expected uninstall.sh's own refusal framing (got: $out4)"
[ -f "$decoy4" ] || fail "4: a refused manifest load must leave every path untouched (no partial deletion)"
[ "$(cat "$decoy4")" = "must survive — the manifest that would have named this is unreadable" ] || fail "4: the path's content must be untouched"

sandbox_down
echo "PASS: 4 (unreadable/newer schema_version -> legible refusal naming the version, exit 1, zero deletion)"

# =============================================================================
# Test 5: partial failure — a 'preexisting' entry whose recorded backup is
#         missing is left recorded for a retry; every OTHER entry still
#         resolves; overall exit 1.
# =============================================================================
sandbox_up uninstall-test5

ok5="$SANDBOX_HOME/.local/bin/claim"
seed_created "$ok5" "installed content"

broken5="$SANDBOX_HOME/.gitconfig"
seed_preexisting "$broken5" "operator original" "managed replacement"
backup5="$(sandbox_bash '
  source "'"$MANIFEST_SH"'"
  manifest_get_path_entry "'"$broken5"'" | jq -r ".backup_path"
')"
rm -f "$backup5"   # simulate a corrupted/lost backup

out5="$(run_uninstall --yes 2>&1)" && rc5=0 || rc5=$?
[ "$rc5" -eq 1 ] || fail "5: a partial failure should exit 1 (got rc=$rc5, out: $out5)"
echo "$out5" | grep -q "temperloop uninstall: incomplete" || fail "5: expected the incomplete summary (got: $out5)"

[ ! -e "$ok5" ] || fail "5: the OTHER (resolvable) entry should still be uninstalled despite the broken one"
[ -f "$broken5" ] || fail "5: the path whose backup is missing must be left untouched (refused, not deleted)"
[ "$(cat "$broken5")" = "managed replacement" ] || fail "5: the untouched path's content should be unchanged"
[ "$(manifest_path_count)" = "1" ] || fail "5: only the unresolved entry should remain recorded after a partial failure"

sandbox_down
echo "PASS: 5 (partial failure: unresolved entry stays recorded for a retry, every other entry still resolves, exit 1)"

# =============================================================================
# Test 6: an emptied ~/.claude is rmdir'd; a ~/.claude left non-empty by an
#         unrecorded file survives (rmdir only, never rm -rf).
# =============================================================================
sandbox_up uninstall-test6

created6="$SANDBOX_HOME/.claude/settings.json"
seed_created "$created6" "installed content"
[ -d "$SANDBOX_HOME/.claude" ] || fail "6: setup — \$HOME/.claude should exist before uninstall"

out6="$(run_uninstall --yes 2>&1)" && rc6=0 || rc6=$?
[ "$rc6" -eq 0 ] || fail "6: uninstall --yes should exit 0 (got rc=$rc6, out: $out6)"
[ ! -e "$SANDBOX_HOME/.claude" ] || fail "6: an emptied \$HOME/.claude must be rmdir'd after uninstall"
echo "$out6" | grep -q '\.claude removed (was left empty)' || fail "6: expected the empty-dir removal line (got: $out6)"

sandbox_down
echo "PASS: 6a (an emptied \$HOME/.claude is rmdir'd)"

sandbox_up uninstall-test6b

created6b="$SANDBOX_HOME/.claude/settings.json"
seed_created "$created6b" "installed content"
unrecorded6b="$SANDBOX_HOME/.claude/hand-edited-notes.md"
printf 'never in the manifest\n' > "$unrecorded6b"

out6b="$(run_uninstall --yes 2>&1)" && rc6b=0 || rc6b=$?
[ "$rc6b" -eq 0 ] || fail "6b: uninstall --yes should exit 0 (got rc=$rc6b, out: $out6b)"
[ -d "$SANDBOX_HOME/.claude" ] || fail "6b: \$HOME/.claude must survive when a non-recorded file still lives in it"
[ -f "$unrecorded6b" ] || fail "6b: the unrecorded file itself must survive untouched"

sandbox_down
echo "PASS: 6b (a \$HOME/.claude left non-empty by an unrecorded path survives — rmdir only, never rm -rf)"

# =============================================================================
# Test 7: the printed cache-store-root guidance honors an explicit
#         CACHE_STORE_ROOT override — the same precedence links.sh
#         (links_provision_cache_stores) and board/lib/cache.sh resolve the
#         real store root with. A guidance line built from the
#         XDG_CACHE_HOME/$HOME/.cache fallback alone, ignoring an operator's
#         CACHE_STORE_ROOT, would print the wrong rm -rf path.
# =============================================================================
sandbox_up uninstall-test7

override_root7="$SANDBOX_ROOT/custom-cache-root"
out7="$(CACHE_STORE_ROOT="$override_root7" run_uninstall --yes 2>&1)" && rc7=0 || rc7=$?
[ "$rc7" -eq 0 ] || fail "7: uninstall --yes should exit 0 (got rc=$rc7, out: $out7)"
echo "$out7" | grep -qF "$override_root7" || fail "7: expected the guidance to print the CACHE_STORE_ROOT override path (got: $out7)"
echo "$out7" | grep -qF "${SANDBOX_XDG_CACHE_HOME}/temperloop" && fail "7: guidance must NOT print the XDG_CACHE_HOME fallback when CACHE_STORE_ROOT is set (got: $out7)"

sandbox_down
echo "PASS: 7 (cache-store-root guidance honors an explicit CACHE_STORE_ROOT override)"

echo
echo "ALL PASS: test_uninstall.sh"
