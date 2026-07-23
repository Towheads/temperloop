#!/usr/bin/env bash
#
# test_version_embedding.sh — the release version is EMBEDDED in the shipped
# files, not derived from git at runtime (temperloop#677).
#
# A release artifact must contain its own version: a fresh tag-pinned install
# reports its number, not "dev". This guards the four legs of that contract:
#
#   1. WELL-FORMED: a committed repo-root VERSION file exists and holds a bare
#      SemVer `X.Y.Z` (optionally a `-prerelease` suffix), no `v` prefix.
#   2. EMBEDDED: with the env override unset, `temperloop version` prints
#      exactly `temperloop <VERSION>` — the shipped file is the source of
#      truth, so an install that carries the files carries the version.
#   3. ENV STILL WINS: an explicit TEMPERLOOP_VERSION override is unchanged
#      (the seam CI and test fixtures rely on) — file is a fallback, not a
#      clamp.
#   4. NO TAG DRIFT: when HEAD is exactly a release tag `vX.Y.Z`, VERSION must
#      equal `X.Y.Z`. This is what makes "bump VERSION in the tagged commit"
#      (kernel-repo-layout.md § Release-tag convention) mechanically enforced
#      rather than a discipline a cut can silently skip. Off a tag this leg is
#      a legible no-op — the guard fires only where drift is possible.
#
# Zero network, no sandbox: invokes the in-tree bin/temperloop directly.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

VERSION_FILE="$REPO_ROOT/VERSION"
TL_BIN="$REPO_ROOT/bin/temperloop"

# ── Leg 1: VERSION exists and is well-formed ────────────────────────────────
[ -f "$VERSION_FILE" ] || fail "no VERSION file at repo root ($VERSION_FILE)"
version="$(sed -e 's/[[:space:]]//g' -e '/^$/d' "$VERSION_FILE" | head -n1)"
[ -n "$version" ] || fail "VERSION file is empty"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' \
  || fail "VERSION '$version' is not a bare SemVer X.Y.Z (no 'v' prefix)"
pass "VERSION file present and well-formed: $version"

# ── Leg 2: `temperloop version` embeds the shipped VERSION (env unset) ───────
[ -x "$TL_BIN" ] || fail "bin/temperloop not executable at $TL_BIN"
out="$(env -u TEMPERLOOP_VERSION -u FOUNDATION_VERSION "$TL_BIN" version 2>/dev/null)" \
  || fail "temperloop version exited non-zero"
[ "$out" = "temperloop $version" ] \
  || fail "temperloop version printed '$out', expected 'temperloop $version' — version not embedded from the shipped VERSION file"
pass "temperloop version reports the embedded VERSION, not 'dev'"

# ── Leg 3: an explicit env override still wins ──────────────────────────────
out_override="$(env -u FOUNDATION_VERSION TEMPERLOOP_VERSION=9.9.9-test "$TL_BIN" version 2>/dev/null)" \
  || fail "temperloop version (with override) exited non-zero"
[ "$out_override" = "temperloop 9.9.9-test" ] \
  || fail "TEMPERLOOP_VERSION override printed '$out_override', expected 'temperloop 9.9.9-test' — env no longer wins"
pass "TEMPERLOOP_VERSION env override still wins over the VERSION file"

# ── Leg 4: no VERSION↔tag drift when HEAD is exactly a release tag ───────────
head_tag="$(git -C "$REPO_ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
if printf '%s' "$head_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'; then
  tag_version="${head_tag#v}"
  [ "$tag_version" = "$version" ] \
    || fail "HEAD is release tag $head_tag but VERSION says '$version' — bump VERSION in the tagged commit (kernel-repo-layout.md § Release-tag convention)"
  pass "HEAD tag $head_tag matches VERSION $version — no drift"
else
  pass "HEAD is not a release tag (VERSION↔tag drift check n/a here)"
fi

echo "OK: version-embedding contract holds (temperloop#677)"
