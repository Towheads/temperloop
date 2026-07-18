#!/usr/bin/env bash
#
# test_update_subcommand.sh — hermetic, deterministic, no-network end-to-end
# fixture test for `temperloop update` (bin/subcommands/update.sh,
# temperloop#429, ADR 0002 "Managed-clone state ownership").
#
# Builds a SYNTHETIC "upstream" clone of this repo's own committed tree
# (never the real public kernel remote — see the SAFETY note below) carrying
# four fixture tags, each an intentionally small, controlled change on top
# of the last:
#
#   v9.1.0  baseline — a deterministic, self-contained CHANGELOG.md replaces
#           the real one, so this suite never depends on (or is broken by)
#           this repo's own evolving release history. The starting managed
#           clone (a `git clone --depth 1` of THIS tag, tagless — mirrors
#           bin/bootstrap.sh's current shape exactly) is cut HERE.
#   v9.2.0  a CHANGELOG-only change, its section marked BREAKING with a
#           migration note — proves the delta-surfacing + BREAKING-banner
#           path (acceptance criterion 1).
#   v9.3.0  a CHANGELOG-only, purely additive change — proves the
#           non-interactive/no-consent REFUSAL path (no BREAKING banner,
#           clean "additive" run once consented).
#   v9.4.0  workflows/scripts/install/manifest.sh's own
#           MANIFEST_SCHEMA_VERSION / MANIFEST_READABLE_SCHEMA_VERSIONS
#           bumped to "2" (dropping "1") — proves the schema gate halts
#           BEFORE moving HEAD when the on-disk install manifest (schema 1,
#           recorded by the v9.2.0 run's install) is unreadable by the
#           target tag's own manifest.sh (acceptance criterion 4).
#
# One continuous managed clone drives all four legs in sequence (state
# carries forward across `update` invocations, exactly like a real machine
# over time):
#   A. --to v9.2.0 --yes   -> unshallow+fetch (crit. 2), BREAKING surfaced
#                             (crit. 1), install+doctor green.
#   B. --to v9.3.0 </dev/null (no --yes) -> REFUSED, HEAD untouched (no
#                             timeout-as-consent).
#   C. --to v9.3.0 --yes   -> succeeds, NO BREAKING banner (additive-only),
#                             install+doctor green.
#   D. --to v9.4.0 --yes   -> schema gate REFUSES before touching HEAD
#                             (crit. 4) — HEAD stays at v9.3.0.
#
# A decoy "target repo" (an unrelated tracked file, standing in for a user's
# own project — never something update.sh has any reason to touch) is
# snapshotted before/after the whole run to help prove acceptance criterion
# 3 ("never writes a repo-tracked path in any target repo").
#
# SAFETY (temperloop#429 build-time incident — see this item's own PR body):
# `update.sh` moves the HEAD of the checkout it is INVOKED FROM — running it
# directly against a real dev checkout (this repo, or any worktree of it)
# detaches that checkout's HEAD onto a release tag. This suite NEVER invokes
# update.sh against $REPO_ROOT itself; every invocation below targets
# $CLONE_DIR, a throwaway clone living entirely under the sandbox root. The
# tripwire in section 8 asserts $REPO_ROOT's own HEAD/branch/status are
# byte-identical before and after the whole run, as a mechanical guard
# against exactly that mistake recurring.
#
# No network (the fixture "upstream" is a local clone; `origin` for the
# throwaway managed clone resolves to a local filesystem path). No real
# HOME/XDG mutation — everything lives under the sandbox root
# (workflows/scripts/tests/lib/sandbox.sh).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

# shellcheck source=lib/sandbox.sh
source "$HERE/lib/sandbox.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# ===========================================================================
# 0. Tripwire on $REPO_ROOT's own git state (see the SAFETY note above) —
#    snapshotted BEFORE any fixture setup, checked at the very end.
# ===========================================================================
repo_root_head_before="$(git -C "$REPO_ROOT" rev-parse HEAD)"
repo_root_branch_before="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
repo_root_status_before="$(git -C "$REPO_ROOT" status --porcelain)"

# ===========================================================================
# 1. Fixture upstream: a --no-tags clone of THIS repo's own committed tree
#    (never a bare checkout of the real public remote), then a deterministic,
#    self-contained CHANGELOG.md + three small follow-on commits/tags.
# ===========================================================================
sandbox_up test-update-subcommand

FIXTURE_UPSTREAM="$SANDBOX_ROOT/fixture-upstream"
git clone -q --no-tags "$REPO_ROOT" "$FIXTURE_UPSTREAM" \
  || fail "0: could not clone $REPO_ROOT (--no-tags) to build the fixture upstream"

cat > "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'
# Changelog (fixture — test_update_subcommand.sh)

## [Unreleased]

## [9.1.0] - 2026-01-01

### Added

- Fixture baseline release. Deterministic and self-contained — this
  fixture's CHANGELOG never depends on this repo's own evolving history.
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: baseline changelog (v9.1.0)"
git -C "$FIXTURE_UPSTREAM" tag -a v9.1.0 -m v9.1.0

# One more, UNTAGGED commit on top of v9.1.0 — a real repo's default-branch
# tip is essentially never exactly a release tag (tags land on a release
# commit; more commits land on main afterward), and a --depth 1 clone
# auto-follows a tag that happens to point at the exact commit fetched. This
# extra commit keeps the starting managed clone's tip genuinely tagless,
# matching bin/bootstrap.sh's real-world shape rather than an artifact of
# this fixture's own construction order.
echo "post-v9.1.0 mainline change" >> "$FIXTURE_UPSTREAM/.fixture-mainline"
git -C "$FIXTURE_UPSTREAM" add .fixture-mainline
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: untagged mainline commit after v9.1.0"

# --- The starting managed clone: --depth 1 (shallow), tagless — the EXACT
#     shape bin/bootstrap.sh's own `git clone --depth 1 ...` produces today,
#     cut at the untagged mainline tip BEFORE any of the later fixture tags
#     exist upstream.
CLONE_DIR="$SANDBOX_HOME/.local/share/temperloop"
mkdir -p "$(dirname "$CLONE_DIR")"
# NOTE: --depth is silently ignored on a plain local-path clone ("use
# file:// instead" — git's own warning); file:// forces the real smart-
# protocol path so the shallow-clone semantics under test are genuine.
git clone -q --depth 1 "file://$FIXTURE_UPSTREAM" "$CLONE_DIR" \
  || fail "0: could not create the starting shallow/tagless managed clone"
[ "$(git -C "$CLONE_DIR" rev-parse --is-shallow-repository)" = "true" ] \
  || fail "0: starting managed clone should be shallow (--depth 1)"
[ -z "$(git -C "$CLONE_DIR" tag -l)" ] \
  || fail "0: starting managed clone should be tagless"
pass "0: built a --no-tags fixture upstream (v9.1.0) and a --depth 1, tagless starting managed clone — mirrors bin/bootstrap.sh's current shape exactly"

# --- v9.2.0: CHANGELOG-only, BREAKING-marked, with a migration note.
#
# Simply APPENDED at the end of the file, never reordered to keep
# [Unreleased] "on top" (the human-readability convention the real
# CHANGELOG.md follows) — changelog_sections_in_range()/
# changelog_breaking_sections() (workflows/scripts/lib/changelog.sh) key
# purely off each `## [x.y.z]` heading's SEMVER NUMBER, never file position,
# so append-only is functionally equivalent and far simpler for a fixture.
cat >> "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'

## [9.2.0] - 2026-01-02 — BREAKING

### BREAKING — fixture contract change

- Renamed `fixture_foo` to `fixture_bar`. MIGRATION: update every caller of
  `fixture_foo` before pulling this tag.
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: BREAKING changelog entry (v9.2.0)"
git -C "$FIXTURE_UPSTREAM" tag -a v9.2.0 -m v9.2.0

# --- v9.3.0: CHANGELOG-only, purely additive (no BREAKING marker).
cat >> "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'

## [9.3.0] - 2026-01-03

### Added

- A purely additive fixture capability; nothing existing changes.
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: additive changelog entry (v9.3.0)"
git -C "$FIXTURE_UPSTREAM" tag -a v9.3.0 -m v9.3.0

# --- v9.4.0: an incompatible install-manifest schema bump (manifest.sh's
#     own MANIFEST_SCHEMA_VERSION / MANIFEST_READABLE_SCHEMA_VERSIONS), plus
#     its own (non-breaking) CHANGELOG entry.
MANIFEST_SH_FIXTURE="$FIXTURE_UPSTREAM/workflows/scripts/install/manifest.sh"
[ -f "$MANIFEST_SH_FIXTURE" ] || fail "0: fixture upstream missing workflows/scripts/install/manifest.sh"
sed -i.bak \
  -e 's/^MANIFEST_SCHEMA_VERSION=1$/MANIFEST_SCHEMA_VERSION=2/' \
  -e 's/^MANIFEST_READABLE_SCHEMA_VERSIONS="1"$/MANIFEST_READABLE_SCHEMA_VERSIONS="2"/' \
  "$MANIFEST_SH_FIXTURE"
rm -f "$MANIFEST_SH_FIXTURE.bak"
grep -q '^MANIFEST_SCHEMA_VERSION=2$' "$MANIFEST_SH_FIXTURE" \
  || fail "0: fixture edit of MANIFEST_SCHEMA_VERSION did not take (sed pattern stale?)"
grep -q '^MANIFEST_READABLE_SCHEMA_VERSIONS="2"$' "$MANIFEST_SH_FIXTURE" \
  || fail "0: fixture edit of MANIFEST_READABLE_SCHEMA_VERSIONS did not take (sed pattern stale?)"
cat >> "$FIXTURE_UPSTREAM/CHANGELOG.md" <<'EOF'

## [9.4.0] - 2026-01-04

### Changed

- Fixture install-manifest schema bump (schema_version 1 -> 2), simulating a
  future incompatible manifest shape for this suite's schema-gate leg.
EOF
git -C "$FIXTURE_UPSTREAM" add CHANGELOG.md workflows/scripts/install/manifest.sh
git -C "$FIXTURE_UPSTREAM" commit -q -m "fixture: incompatible manifest schema bump (v9.4.0)"
git -C "$FIXTURE_UPSTREAM" tag -a v9.4.0 -m v9.4.0

pass "1: fixture upstream carries v9.1.0 (baseline) -> v9.2.0 (BREAKING changelog) -> v9.3.0 (additive changelog) -> v9.4.0 (incompatible manifest schema)"

# ===========================================================================
# 2. Decoy "target repo" — an unrelated tracked file, standing in for a
#    user's own project (acceptance criterion 3: update.sh never writes a
#    repo-tracked path in ANY target repo). Snapshotted now; re-checked at
#    the very end.
# ===========================================================================
DECOY="$SANDBOX_ROOT/decoy-target-repo"
mkdir -p "$DECOY"
git init -q --initial-branch=main "$DECOY"
echo "a user's own project — update.sh has no reason to ever touch this" > "$DECOY/README.md"
git -C "$DECOY" add README.md
git -C "$DECOY" commit -q -m "decoy target repo baseline"
decoy_head_before="$(git -C "$DECOY" rev-parse HEAD)"
decoy_content_before="$(cat "$DECOY/README.md")"

UPDATE_SH="$CLONE_DIR/bin/subcommands/update.sh"
[ -x "$UPDATE_SH" ] || fail "0: $UPDATE_SH not present/executable in the starting managed clone"

# ===========================================================================
# 3. RUN A — --to v9.2.0 --yes: unshallow+fetch tags (criterion 2), the
#    delta surfaced BEFORE consent with a BREAKING banner (criterion 1),
#    install+doctor green.
# ===========================================================================
out_a="$(sandbox_run bash "$UPDATE_SH" --to v9.2.0 --yes 2>&1)"
rc_a=$?
[ "$rc_a" -eq 0 ] || fail "A: update --to v9.2.0 --yes exited $rc_a (output: $out_a)"
grep -qF "Converting shallow clone to full history" <<<"$out_a" \
  || fail "A: expected the shallow->full-history conversion to run (output: $out_a)"
grep -qF "## [9.2.0]" <<<"$out_a" \
  || fail "A: expected the v9.2.0 CHANGELOG section to be surfaced in the delta preview"
grep -qF "update every caller of" <<<"$out_a" \
  || fail "A: expected the v9.2.0 migration note text to be surfaced"
grep -qF "WARNING: BREAKING section(s) detected in this range" <<<"$out_a" \
  || fail "A: expected the BREAKING banner for a BREAKING-marked delta"
grep -qF "temperloop update: done — now at v9.2.0" <<<"$out_a" \
  || fail "A: expected a 'done — now at v9.2.0' completion line"
[ "$(git -C "$CLONE_DIR" rev-parse --is-shallow-repository)" = "false" ] \
  || fail "A: managed clone should no longer be shallow after update"
[ "$(git -C "$CLONE_DIR" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.2.0" ] \
  || fail "A: managed clone HEAD should be exactly v9.2.0 after update"
MANIFEST_FILE="$SANDBOX_XDG_STATE_HOME/temperloop/install-manifest.json"
[ -f "$MANIFEST_FILE" ] || fail "A: expected an install manifest after the re-run install"
[ "$(jq -r '.schema_version' "$MANIFEST_FILE")" = "1" ] \
  || fail "A: expected the recorded install-manifest schema_version to be 1 (v9.2.0's own manifest.sh)"
pass "A: 'update --to v9.2.0 --yes' converts the shallow/tagless clone (criterion 2), surfaces the CHANGELOG delta with its BREAKING section BEFORE consent (criterion 1), and finishes with a green install+doctor"

# ===========================================================================
# 4. RUN B — --to v9.3.0, non-interactive, NO --yes: REFUSED, HEAD untouched
#    (no timeout-as-consent).
# ===========================================================================
out_b="$(sandbox_run bash "$UPDATE_SH" --to v9.3.0 </dev/null 2>&1)"
rc_b=$?
[ "$rc_b" -eq 0 ] || fail "B: a declined/refused consent should exit 0 (legible no-op), got $rc_b (output: $out_b)"
grep -qF "REFUSED — non-interactive with no --yes" <<<"$out_b" \
  || fail "B: expected the non-interactive consent refusal message (output: $out_b)"
grep -qF "temperloop update: aborted — HEAD not moved, nothing written" <<<"$out_b" \
  || fail "B: expected the 'aborted — HEAD not moved' line"
[ "$(git -C "$CLONE_DIR" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.2.0" ] \
  || fail "B: HEAD must remain at v9.2.0 after a refused consent gate"
pass "B: a non-interactive run with no --yes REFUSES (no timeout-as-consent) and leaves HEAD exactly where it was"

# ===========================================================================
# 5. RUN C — --to v9.3.0 --yes: succeeds, NO BREAKING banner (purely
#    additive delta), install+doctor green.
# ===========================================================================
out_c="$(sandbox_run bash "$UPDATE_SH" --to v9.3.0 --yes 2>&1)"
rc_c=$?
[ "$rc_c" -eq 0 ] || fail "C: update --to v9.3.0 --yes exited $rc_c (output: $out_c)"
if grep -qF "BREAKING section(s) detected" <<<"$out_c"; then
  fail "C: an additive-only delta (v9.2.0 -> v9.3.0) must NOT print a BREAKING banner"
fi
grep -qF "temperloop update: done — now at v9.3.0" <<<"$out_c" \
  || fail "C: expected a 'done — now at v9.3.0' completion line"
[ "$(git -C "$CLONE_DIR" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.3.0" ] \
  || fail "C: managed clone HEAD should be exactly v9.3.0 after update"
pass "C: a consented, purely-additive update (v9.2.0 -> v9.3.0) succeeds with no BREAKING banner"

# ===========================================================================
# 6. RUN D — --to v9.4.0 --yes: the install-manifest schema gate REFUSES
#    BEFORE moving HEAD (criterion 4) — HEAD stays at v9.3.0.
# ===========================================================================
out_d="$(sandbox_run bash "$UPDATE_SH" --to v9.4.0 --yes 2>&1)"
rc_d=$?
[ "$rc_d" -eq 1 ] || fail "D: a schema-gate refusal should exit 1, got $rc_d (output: $out_d)"
grep -qF "REFUSED — install-manifest schema mismatch, halting BEFORE moving HEAD" <<<"$out_d" \
  || fail "D: expected the schema-mismatch refusal message (output: $out_d)"
grep -qF "schema_version=1" <<<"$out_d" \
  || fail "D: expected the refusal to name the on-disk schema_version (1)"
[ "$(git -C "$CLONE_DIR" describe --tags --exact-match HEAD 2>/dev/null)" = "v9.3.0" ] \
  || fail "D: HEAD must remain at v9.3.0 — the schema gate must halt BEFORE any checkout"
pass "D: an incompatible install-manifest schema bump (v9.4.0) HALTS legibly before touching HEAD (criterion 4) — HEAD stays at v9.3.0"

# ===========================================================================
# 7. Decoy target-repo untouched throughout (criterion 3).
# ===========================================================================
decoy_head_after="$(git -C "$DECOY" rev-parse HEAD)"
decoy_content_after="$(cat "$DECOY/README.md")"
[ "$decoy_head_before" = "$decoy_head_after" ] \
  || fail "7: the decoy target repo's HEAD changed — update.sh must never touch another repo"
[ "$decoy_content_before" = "$decoy_content_after" ] \
  || fail "7: the decoy target repo's tracked content changed — update.sh must never write a repo-tracked path in any target repo"
pass "7: the decoy target repo (standing in for a user's own project) is byte-for-byte untouched across all four runs (criterion 3)"

# ===========================================================================
# 8. Tripwire: $REPO_ROOT's own git state (HEAD, branch, working-tree
#    status) is byte-identical before and after the whole run — see the
#    SAFETY note in this file's header.
# ===========================================================================
repo_root_head_after="$(git -C "$REPO_ROOT" rev-parse HEAD)"
repo_root_branch_after="$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD || echo DETACHED)"
repo_root_status_after="$(git -C "$REPO_ROOT" status --porcelain)"
[ "$repo_root_head_before" = "$repo_root_head_after" ] \
  || fail "8: \$REPO_ROOT's own HEAD commit changed during this suite — see the header's SAFETY note"
[ "$repo_root_branch_before" = "$repo_root_branch_after" ] \
  || fail "8: \$REPO_ROOT's own branch changed during this suite (before: $repo_root_branch_before, after: $repo_root_branch_after) — see the header's SAFETY note"
[ "$repo_root_status_before" = "$repo_root_status_after" ] \
  || fail "8: \$REPO_ROOT's own working-tree status changed during this suite — see the header's SAFETY note"
pass "8: \$REPO_ROOT's own HEAD/branch/working-tree status are byte-identical before and after this suite (this test never runs update.sh against a real dev checkout)"

sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down
[ ! -e "$sandbox_root_snapshot" ] || fail "sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"

echo
echo "ALL PASS: test_update_subcommand.sh"
