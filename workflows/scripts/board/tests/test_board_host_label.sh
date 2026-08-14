#!/usr/bin/env bash
#
# Regression test for temperloop#1455 — board claim stamps derived the host
# label inconsistently across call sites (session 15297bb9 stamped some
# issues `mini` and others `Mac-mini` on the SAME machine because claim.sh /
# release.sh / capture.sh / reconcile.sh / board-mirror.sh each inlined their
# own copy of the `${SUBSET_HOST_LABEL:-...}` fallback chain — three
# different variants — and the build.md prose spec documented a FOURTH
# variant none of the shell code implemented).
#
# The fix: ONE helper, board_host_label() in lib/board.sh, that every site
# (script and prose) now calls instead of inlining its own chain. This suite
# proves the three load-bearing properties the fix issue's contract calls
# for:
#   1. every site resolves identically (structural: no site still inlines
#      the chain — only lib/board.sh may; a re-divergence would fail this)
#   2. the resolution is context-agnostic — a "profile loaded" (normal
#      inherited-env) invocation and a "bare launchd/cron" (env -i, no
#      profile, minimal environment) invocation agree given the same inputs
#   3. the helper never returns an empty label, even when neither override
#      is set AND the `hostname` binary itself fails/returns nothing
#
# No network, no gh call — board_host_label touches only env vars and the
# `hostname` binary.
set -euo pipefail

# All four paths below resolve PHYSICAL (`pwd -P`, not plain `pwd`), and
# consistently so — every one of them, not just BOARD_DIR — per
# temperloop#1490. In a consumer that vendors this board toolkit through a
# compat symlink (foundation: workflows/scripts/board -> ../../kernel/
# workflows/scripts/board), a logical `pwd` here would keep that symlink in
# HERE/LIB_DIR/BOARD_DIR, and the structural check below (grep -rlE over
# BOARD_DIR) would silently find NOTHING: real macOS/BSD grep
# (/usr/bin/grep — NOT a GNU-compatible grep some shells alias onto)
# refuses to descend into a symlinked TOP-LEVEL directory argument, unlike
# GNU grep, which follows it. That is a false failure (empty "found:" list),
# not evidence the class ever re-diverged — confirmed by reproducing the
# identical grep call directly against both the symlinked and physical
# path. Resolving physical is the fix; it must apply to HERE too (not just
# BOARD_DIR), because the self-exclusion filter on line ~44 below compares
# grep's (now-physical) output against "$HERE/test_board_host_label.sh" —
# a stale logical HERE would stop matching and the test would wrongly count
# itself as a second inline site.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$(cd "$HERE/../lib" && pwd -P)"
BOARD_DIR="$(cd "$HERE/.." && pwd -P)"
BOARD_SH="$LIB_DIR/board.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- 1: structural — the chain must live in EXACTLY ONE place -------------
# A grep-based regression guard: if any script under workflows/scripts/board/
# (other than lib/board.sh itself, where the helper is defined) ever again
# inlines `${SUBSET_HOST_LABEL:-...}` directly, this fails loudly instead of
# silently reintroducing the divergence. Test fixtures that merely EXPORT
# SUBSET_HOST_LABEL=... (setting the variable) don't match this pattern —
# only an inlined `${SUBSET_HOST_LABEL:-` fallback expression does.
sites_with_inline_chain="$(grep -rlE '\$\{SUBSET_HOST_LABEL:-' "$BOARD_DIR" 2>/dev/null | grep -v "$HERE/test_board_host_label.sh" || true)"
site_count="$(printf '%s\n' "$sites_with_inline_chain" | grep -c . || true)"
if [ "$site_count" -ne 1 ] || [ "$sites_with_inline_chain" != "$BOARD_SH" ]; then
  fail "expected exactly lib/board.sh to inline the chain, found: $sites_with_inline_chain"
fi

# board-mirror.sh (workflows/scripts/build/) used a THIRD variant
# (${SUBSET_HOST_LABEL:-${STAGEFIND_HOST_LABEL:-$(hostname -s)}}) before this
# fix — assert it too now calls the shared helper instead of inlining.
BUILD_MIRROR="$(cd "$HERE/../../build" && pwd -P)/board-mirror.sh"
if [ -f "$BUILD_MIRROR" ] && grep -qE '\$\{SUBSET_HOST_LABEL:-' "$BUILD_MIRROR"; then
  fail "board-mirror.sh still inlines the chain instead of calling board_host_label"
fi
if [ -f "$BUILD_MIRROR" ] && ! grep -q 'board_host_label' "$BUILD_MIRROR"; then
  fail "board-mirror.sh does not call board_host_label at all"
fi

# --- 2: every documented call site actually calls the helper --------------
for f in claim.sh release.sh capture.sh reconcile.sh; do
  grep -q 'board_host_label' "$BOARD_DIR/$f" || fail "$f does not call board_host_label"
done

# --- load the helper for the behavioral tests below ------------------------
# shellcheck source=scripts/lib/board.sh
# shellcheck disable=SC1091
source "$BOARD_SH"

# --- 3: unset/empty override still yields a usable, non-empty label -------
(
  unset SUBSET_HOST_LABEL STAGEFIND_HOST_LABEL 2>/dev/null || true
  out="$(board_host_label)"
  [ -n "$out" ] || fail "board_host_label returned empty with no override set"
  real_hostname="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  [ "$out" = "$real_hostname" ] || fail "no-override fallback ($out) != hostname -s ($real_hostname)"
)

# --- 4: SUBSET_HOST_LABEL (current name) wins over everything -------------
# shellcheck disable=SC2030,SC2031
(
  export SUBSET_HOST_LABEL="primary-label"
  export STAGEFIND_HOST_LABEL="legacy-label"
  out="$(board_host_label)"
  [ "$out" = "primary-label" ] || fail "SUBSET_HOST_LABEL override not honored (got '$out')"
)

# --- 5: STAGEFIND_HOST_LABEL (legacy name) is a nested fallback -----------
# This is the property the setting-registry documents ("nested inside
# SUBSET_HOST_LABEL's own fallback") — a machine that only ever set the OLD
# name must still resolve consistently instead of silently falling through
# past it to the bare hostname.
# shellcheck disable=SC2030,SC2031
(
  unset SUBSET_HOST_LABEL 2>/dev/null || true
  export STAGEFIND_HOST_LABEL="legacy-only-label"
  out="$(board_host_label)"
  [ "$out" = "legacy-only-label" ] || fail "STAGEFIND_HOST_LABEL legacy fallback not honored (got '$out')"
)

# --- 6: fail-safe — even a broken `hostname` binary yields a non-empty label
# Stub `hostname` on PATH to fail/emit nothing (the worst case: no override
# set AND the OS hostname lookup itself is broken, e.g. a stripped-down
# launchd environment). board_host_label must still return something usable.
STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/board-host-label-stub-XXXXXX")"
cleanup() { rm -rf "$STUB_DIR"; }
trap cleanup EXIT
cat >"$STUB_DIR/hostname" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "$STUB_DIR/hostname"
# shellcheck disable=SC2030,SC2031
(
  unset SUBSET_HOST_LABEL STAGEFIND_HOST_LABEL 2>/dev/null || true
  export PATH="$STUB_DIR:$PATH"
  out="$(board_host_label)"
  [ -n "$out" ] || fail "board_host_label returned EMPTY when hostname itself failed — would corrupt a claim stamp"
  [ "$out" = "unknown" ] || fail "expected the 'unknown' fail-safe fallback, got '$out'"
)

# --- 7: profile-loaded vs bare launchd/cron context agree -----------------
# The regression this issue reports: an interactive shell (profile loaded,
# SUBSET_HOST_LABEL exported by e.g. .zshrc) and a bare launchd/cron
# invocation (no profile, minimal inherited environment) resolved to
# DIFFERENT labels on the same machine. board_host_label is context-agnostic
# by construction (a plain env-var check + the `hostname` binary — nothing
# that depends on interactive-shell-only state like aliases or a login-shell
# PATH), so given the SAME inputs, both contexts must agree.
#
# "profile loaded" is simulated as a normal subshell that inherited the
# override via `export` (exactly what a sourced ~/.zshrc does). "bare
# launchd/cron" is simulated with `env -i` — a minimal environment with only
# PATH and the override explicitly passed, the shape a launchd plist's own
# EnvironmentVariables dict produces (no inherited shell profile at all).
# shellcheck disable=SC2030,SC2031
profile_out="$(
  export SUBSET_HOST_LABEL="parity-label"
  bash -c "source '$BOARD_SH'; board_host_label"
)"
# shellcheck disable=SC2031
bare_out="$(env -i PATH="$PATH" SUBSET_HOST_LABEL="parity-label" \
  bash -c "source '$BOARD_SH'; board_host_label")"
[ "$profile_out" = "$bare_out" ] || \
  fail "profile-loaded ($profile_out) and bare-env ($bare_out) contexts disagree given the identical override"
[ "$profile_out" = "parity-label" ] || fail "unexpected resolved value '$profile_out'"

# Same parity check for the NO-override case (both contexts fall through to
# hostname -s identically — the fallback path doesn't secretly depend on
# anything only present in an interactive/profile-loaded shell).
profile_fallback="$(bash -c "unset SUBSET_HOST_LABEL STAGEFIND_HOST_LABEL 2>/dev/null; source '$BOARD_SH'; board_host_label")"
# shellcheck disable=SC2031
bare_fallback="$(env -i PATH="$PATH" bash -c "source '$BOARD_SH'; board_host_label")"
[ "$profile_fallback" = "$bare_fallback" ] || \
  fail "profile-loaded fallback ($profile_fallback) and bare-env fallback ($bare_fallback) disagree with no override set"

echo "OK — board_host_label: single site, fail-safe, and profile/bare-env parity all hold"
