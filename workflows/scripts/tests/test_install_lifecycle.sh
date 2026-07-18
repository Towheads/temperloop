#!/usr/bin/env bash
#
# test_install_lifecycle.sh — Tier-1 hermetic install-lifecycle CI suite
# (temperloop#267, ADR K164 D6). The END-TO-END lifecycle leg: bootstrap from
# the local checkout over file:// -> `temperloop install` (consented) ->
# `doctor.sh` green -> a second install converges (idempotent) ->
# `temperloop uninstall` (consented) -> a tree-manifest diff of the machine
# surface (before-install vs after-uninstall) proves no UNEXPLAINED residue
# against a declared, commented exclusion set. One script; local run =
# CI run (scripts/quality-gates.sh).
#
# NOT a re-run of the per-CLI unit suites already covering the same seams in
# depth — this file deliberately does not duplicate:
#   - workflows/scripts/tests/test_install_cli.sh (dry-run/consent legs,
#     preexisting-path backup verbatim, per-kind classification detail)
#   - bin/subcommands/tests/test_uninstall.sh (partial-failure retry,
#     schema_version refusal, decoy-path survival at the library level)
# This suite's OWN job is the full round-trip end to end, through the real
# `temperloop` CLI, with the sandbox-integrity layer (temperloop#266)
# wrapped around the whole run — the thing neither of those two suites
# attempts on its own.
#
# SELF-SCOPING (acceptance criterion 4): this suite hard-codes assumptions
# specific to a KERNEL-ONLY checkout (temperloop itself) — the exact set of
# managed paths links_enumerate() emits with no env/*, no
# claude/settings.json, no claude/CLAUDE.overlay.md present (see
# test_install_cli.sh's own header for the identical scoping note), and the
# declared tree-diff exclusion set below is sized for exactly that surface.
# A COMPOSED overlay checkout (foundation, stageFind, ssmobile, subsetwiki —
# claude/CLAUDE.kernel.md + claude/CLAUDE.overlay.md both present, per
# workflows/scripts/validate-live-drain.sh's own KERNEL_ONLY_MD detection
# idiom) additionally enumerates env/* dotfiles, a real settings.json, and a
# composed CLAUDE.md — a different managed-path surface this suite's
# exclusion set does not model, so it self-scopes out with a legible SKIP
# rather than either (a) silently mis-asserting against a surface it wasn't
# built for, or (b) trying to be a superset suite that models every overlay
# repo's surface from inside the kernel repo. Whether/how a lifecycle leg
# like this one propagates DOWNSTREAM into a composed tree is temperloop#255's
# decision — out of scope here; this item only had to make sure this kernel
# checkout's own suite degrades legibly instead of guessing at a repo that
# isn't present at kernel-CI time.
#
# PORTABILITY notes (both are load-bearing, not stylistic):
#   (a) Every "read a possibly-large variable" check below uses a herestring
#       (`<<<"$var"`) into `grep -q`/`read`, never a pipe into an
#       early-exiting reader under `set -uo pipefail` (mirrors
#       sandbox_preflight_links's own documented idiom in sandbox.sh) — a
#       pipe into `grep -q`/`head -1` can SIGPIPE the writer mid-write and
#       intermittently misreport a real pass as a pipefail-tainted failure.
#   (b) No assertion anywhere depends on an exact time-derived value (mtime,
#       a formatted timestamp) — every comparison is content-hash (sha256,
#       via sandbox_tree_manifest) or structural (jq -S canonical JSON,
#       path-count), so this suite is deterministic across macOS (bash 3.2)
#       and Linux CI runners with no clock-skew or format-quirk flakiness.
#
# No network beyond the file:// bootstrap. No real HOME/XDG mutation at any
# point (sandbox_tripwire_check proves it at the end).
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

# ---------------------------------------------------------------------------
# Self-scoping gate (acceptance criterion 4) — MUST run before sourcing
# anything else, so a composed-tree run exits 0 fast with zero sandbox setup.
#
# Detection, two independent signals (either fires -> composed):
#   1. claude/CLAUDE.overlay.md present beside claude/CLAUDE.kernel.md — the
#      same idiom workflows/scripts/validate-live-drain.sh's own
#      KERNEL_ONLY_MD check already uses (composed = overlay present).
#   2. A kernel/ subtree present at the repo root, itself recognizably a
#      vendored kernel checkout (carries its own bin/temperloop or
#      claude/CLAUDE.kernel.md) — the "vendored at foundation/kernel/"
#      layout workflows/scripts/kernel/check-producer-egress.sh's own header
#      names as a possibility this repo's scripts must tolerate. Gated on a
#      recognizable marker file (not bare directory presence) so an
#      unrelated repo that happens to have its own top-level `kernel/`
#      directory for other reasons doesn't false-positive.
#   3. This script IS the vendored copy: $REPO_ROOT (derived from
#      BASH_SOURCE, so it points at the kernel subtree itself when this
#      file lives at <overlay>/kernel/workflows/scripts/tests/) is not its
#      own git toplevel — i.e. the kernel tree is embedded inside a larger
#      (composed) repo. Neither arm 1 nor 2 can see this case from inside
#      the subtree. Also a hard precondition, not just scoping:
#      sandbox_bootstrap_checkout bare-clones $REPO_ROOT, which requires a
#      real repo root — a subtree path isn't clonable. Fail-open: if `git`
#      is unavailable or errors, this arm stays silent and the suite runs
#      (a standalone kernel checkout in CI is always its own toplevel).
# ---------------------------------------------------------------------------

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

# shellcheck source=workflows/scripts/tests/lib/sandbox.sh
source "$HERE/lib/sandbox.sh"

# The detection itself now lives in the shared harness (sandbox.sh) — #363
# found its three sibling suites had never inherited this guard and were
# failing in composed trees. Extracted rather than re-copied; the rationale
# below is this suite's own and stays here.
sandbox_skip_if_composed_tree "test_install_lifecycle.sh" "$REPO_ROOT" \
  "its declared tree-diff exclusion set is sized for links_enumerate()'s
  kernel-only surface (no env/*, no settings.json, no composed CLAUDE.md) and
  would either miss or misreport residue on a composed checkout's larger
  managed-path surface. Whether/how this lifecycle leg propagates downstream
  into a composed tree (foundation, stageFind, ssmobile, subsetwiki) is
  temperloop#255's decision, not this item's."

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# manifest_file_for <sandbox_xdg_state_home> — mirrors manifest.sh's own
# manifest_file() derivation without sourcing the lib (same idiom
# test_install_cli.sh already uses).
manifest_file_for() { printf '%s/temperloop/install-manifest.json' "$1"; }

# ===========================================================================
# Setup: sandbox + tripwire (spans the WHOLE run) + a real bootstrapped CLI.
# ===========================================================================
sandbox_up test-install-lifecycle
sandbox_stub_gh
sandbox_stub_claude

# Tripwire snapshot BEFORE anything else — watches the REAL, non-sandboxed
# machine surface across the entire lifecycle below.
#
# TARGETED watch set, not sandbox_tripwire_snapshot's bare defaults
# ($HOME/.claude + $HOME/.local/bin/temperloop wholesale): on a live dev
# machine, $HOME/.claude is a large, CONTINUOUSLY-MUTATING tree (session
# transcripts, shell snapshots, todo state — tens of GB, hundreds of
# thousands of files, written by any concurrently-running Claude session),
# so hashing it wholesale twice per gate run is (a) hours of sha256 work
# incompatible with a per-PR CI gate, and (b) guaranteed false drift the
# moment any unrelated session writes a transcript mid-run. Instead we
# watch exactly the real paths an isolation ESCAPE from this lifecycle
# could actually write: every links_enumerate() target resolved against
# the REAL $HOME (the precise bug class the tripwire exists for is "a
# managed-path write used the real HOME instead of the sandbox HOME" —
# those writes land on exactly these names), plus the real
# $HOME/.local/bin/temperloop bootstrap target. The real-$HOME/.claude
# and ~/.local/bin surfaces are therefore still asserted untouched — at
# every path this run could plausibly reach — without hashing unrelated
# live session state the install lifecycle has no code path toward. (On a
# CI runner, where ~/.claude barely exists, the watch set is near-free and
# each absent path is recorded/checked as its own "absent" record.)
#
# The enumeration below is READ-ONLY and runs in this caller shell (a
# subshell, NOT sandbox_run) precisely so links_enumerate's $HOME-relative
# target computation resolves against the REAL home.
real_watch_paths=()
while IFS=$'\t' read -r _t _k _s; do
  [ -n "$_t" ] || continue
  real_watch_paths+=("$_t")
done < <(
  # shellcheck disable=SC1091
  source "$REPO_ROOT/workflows/scripts/install/links.sh"
  links_enumerate "$REPO_ROOT"
)
[ "${#real_watch_paths[@]}" -gt 0 ] \
  || fail "real-home links_enumerate emitted no targets (broken checkout?)"
real_watch_paths+=("$HOME/.local/bin/temperloop")
sandbox_tripwire_snapshot lifecycle "${real_watch_paths[@]}"

sandbox_bootstrap_checkout "$REPO_ROOT" || fail "sandbox_bootstrap_checkout failed"
[ -x "${SANDBOX_TEMPERLOOP:-}" ] || fail "SANDBOX_TEMPERLOOP not set/executable after bootstrap"
pass "0: bootstrapped a working temperloop binary over file:// (hermetic newcomer-install stand-in, no network)"

# Physically resolved (cd -P), not a bare $SANDBOX_HOME/... string — mirrors
# test_install_cli.sh's own note: bin/temperloop's dispatcher resolves its
# symlink chain via `cd -P`, and on macOS $TMPDIR sits under a symlinked
# /var, so a non-physical comparison would spuriously mismatch there.
CHECKOUT="$(cd -P "$SANDBOX_HOME/.local/share/temperloop" && pwd)"
[ -d "$CHECKOUT" ] || fail "expected bootstrapped checkout at $CHECKOUT"

MANIFEST="$(manifest_file_for "$SANDBOX_XDG_STATE_HOME")"
BACKUPS_DIR="$SANDBOX_XDG_STATE_HOME/temperloop/backups"

# ===========================================================================
# 1. Write PREFLIGHT (acceptance criterion 2) — before the first write of
#    the simulated install.
# ===========================================================================
sandbox_preflight_links "$CHECKOUT" \
  || fail "sandbox_preflight_links: a links_enumerate target escapes the sandbox root — see stderr above"
pass "1: sandbox_preflight_links — every links_enumerate target resolves inside the sandbox root before any write happens"

# ===========================================================================
# Seed an operator-authored ("wizard-written") machine conf under
# XDG_CONFIG_HOME/temperloop BEFORE the before-install snapshot — the
# bin/README.md § Uninstall worked example of a hand-edited machine conf
# that is NEVER manifest-recorded and must survive the whole lifecycle
# untouched. Proves that contract end-to-end through the real CLI (test
# 6 below), not just at the manifest-library level test_uninstall.sh
# already covers.
# ===========================================================================
WIZARD_CONF_DIR="$SANDBOX_XDG_CONFIG_HOME/temperloop"
WIZARD_CONF="$WIZARD_CONF_DIR/config.toml"
mkdir -p "$WIZARD_CONF_DIR"
printf 'operator-authored config, never recorded by any install manifest\n' > "$WIZARD_CONF"

# ===========================================================================
# Before-install snapshot of the machine surface — one manifest per real
# machine-analog root (HOME + the four XDG dirs), diffed independently below
# so a failure names exactly which root regressed.
# ===========================================================================
BEFORE_DIR="$SANDBOX_ROOT/manifests-before"
mkdir -p "$BEFORE_DIR"
sandbox_tree_manifest "$SANDBOX_HOME"            > "$BEFORE_DIR/home.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_CONFIG_HOME" > "$BEFORE_DIR/xdg-config.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_STATE_HOME"  > "$BEFORE_DIR/xdg-state.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_DATA_HOME"   > "$BEFORE_DIR/xdg-data.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_CACHE_HOME"  > "$BEFORE_DIR/xdg-cache.tsv"

# ===========================================================================
# 2. `temperloop install --yes` (consented).
# ===========================================================================
install_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --yes 2>&1)"
install_rc=$?
[ "$install_rc" -eq 0 ] || fail "install --yes exited $install_rc (output: $install_out)"
[ -f "$MANIFEST" ] || fail "install manifest should exist after a real install run"
pass "2: 'temperloop install --yes' completed (exit 0), install manifest written"

# ===========================================================================
# 3. doctor.sh green.
# ===========================================================================
doctor_out="$(sandbox_run bash "$CHECKOUT/workflows/scripts/install/doctor.sh" "$CHECKOUT" 2>&1)"
doctor_rc=$?
[ "$doctor_rc" -eq 0 ] || fail "doctor.sh exited $doctor_rc after install (output: $doctor_out)"
grep -q 'Non-OK: 0' <<<"$doctor_out" || fail "doctor.sh should report 'Non-OK: 0' after install (got: $doctor_out)"
pass "3: doctor.sh is green (exit 0, Non-OK: 0) after 'temperloop install'"

# ===========================================================================
# 4. Idempotent re-install — manifest byte-comparable (jq -S canonical JSON,
#    both sides), no spurious backups.
# ===========================================================================
manifest_json_1="$(jq -S '.' "$MANIFEST")"
n_recorded_1="$(jq '[.paths|keys[]]|length' "$MANIFEST")"
n_backups_1="$(find "$BACKUPS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"

install_out2="$(sandbox_run "$SANDBOX_TEMPERLOOP" install --yes 2>&1)"
install_rc2=$?
[ "$install_rc2" -eq 0 ] || fail "second install --yes exited $install_rc2 (output: $install_out2)"
grep -q 'already linked' <<<"$install_out2" || fail "second install should report at least one already-linked entry (got: $install_out2)"

manifest_json_2="$(jq -S '.' "$MANIFEST")"
n_recorded_2="$(jq '[.paths|keys[]]|length' "$MANIFEST")"
n_backups_2="$(find "$BACKUPS_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"

[ "$manifest_json_1" = "$manifest_json_2" ] || fail "second install should leave the manifest byte-comparable (jq -S canonical form differs before/after)"
[ "$n_recorded_1" -eq "$n_recorded_2" ] || fail "second install should not change the recorded path count (before=$n_recorded_1, after=$n_recorded_2)"
[ "$n_backups_1" -eq "$n_backups_2" ] || fail "second install should not create any new backup files (before=$n_backups_1, after=$n_backups_2)"
pass "4: idempotent re-install — manifest byte-comparable (jq -S canonical JSON identical), path count unchanged, zero spurious backups"

# ===========================================================================
# 4b. Knowledge-store SYNC state seeded before uninstall (temperloop#430,
#     ADR 0003): initialize the sandbox's knowledge store as a git-backed
#     sync store (local bare "remote" under $SANDBOX_ROOT — outside every
#     diffed machine root), write a note through the seam, push. The store
#     is USER DATA: uninstall must keep it — including its .git and remote
#     config — and no sync-specific state may land anywhere OUTSIDE the
#     store dir (asserted by the 7a–7e tree-diffs below, whose only new
#     exclusion is the store dir itself).
# ===========================================================================
SYNC_REMOTE="$SANDBOX_ROOT/sync-remote.git"
git init --bare -q "$SYNC_REMOTE" || fail "4b: could not create the bare sync-remote fixture"

# The store resolves through the DEFAULT root seam (no KNOWLEDGE_STORE_ROOT
# override): ${XDG_DATA_HOME}/temperloop/knowledge (temperloop#165) under the sandbox. The
# read-log (temperloop#229) is pointed OUTSIDE the diffed roots so the sync
# leg's telemetry can't muddy the residue diff it exists to sharpen. The lib
# is sourced from $REPO_ROOT (this working tree), NOT the bootstrapped
# $CHECKOUT — the bootstrap bare-clones committed state only, so a
# working-tree change to knowledge_store.sh would be invisible there; every
# WRITE still lands inside the sandbox (env-scoped via sandbox_run).
STORE_DIR="$SANDBOX_XDG_DATA_HOME/temperloop/knowledge"
sync_out="$(sandbox_run env "KNOWLEDGE_READ_LOG=$SANDBOX_ROOT/knowledge-reads.log" \
  bash -c '
    set -euo pipefail
    source "$1/workflows/scripts/lib/knowledge_store.sh"
    ks_sync init "$2"
    printf "note that must survive uninstall\n" | ks_write "Decisions/sync-survivor"
    ks_sync push
  ' _ "$REPO_ROOT" "$SYNC_REMOTE" 2>&1)"
sync_rc=$?
[ "$sync_rc" -eq 0 ] || fail "4b: sync init/write/push leg exited $sync_rc (output: $sync_out)"
[ -d "$STORE_DIR/.git" ] || fail "4b: the store should be a git repo after ks_sync init"
[ "$(git -C "$SYNC_REMOTE" rev-list --count refs/heads/main)" -eq 1 ] \
  || fail "4b: the sync remote should hold the pushed store commit"
pass "4b: knowledge store sync-initialized through the ks_ seam (git repo at the default store root, note pushed to a local bare remote)"

# ===========================================================================
# 5. `temperloop uninstall --yes` (consented).
# ===========================================================================
uninstall_out="$(sandbox_run "$SANDBOX_TEMPERLOOP" uninstall --yes 2>&1)"
uninstall_rc=$?
[ "$uninstall_rc" -eq 0 ] || fail "uninstall --yes exited $uninstall_rc (output: $uninstall_out)"
grep -q 'temperloop uninstall: done' <<<"$uninstall_out" || fail "expected a done status line (got: $uninstall_out)"
pass "5: 'temperloop uninstall --yes' completed (exit 0, 'temperloop uninstall: done')"

# ===========================================================================
# 6. The operator-authored (wizard-style) machine conf must survive,
#    byte-for-byte, since it was never manifest-recorded.
# ===========================================================================
[ -f "$WIZARD_CONF" ] || fail "the operator-authored config under \$XDG_CONFIG_HOME/temperloop/ must survive uninstall"
[ "$(cat "$WIZARD_CONF")" = "operator-authored config, never recorded by any install manifest" ] \
  || fail "the operator-authored config's content must be byte-for-byte untouched by uninstall"
pass "6: an operator-authored machine conf under \$XDG_CONFIG_HOME/temperloop/ (never manifest-recorded) survives uninstall byte-for-byte"

# ===========================================================================
# 6b. The knowledge store — including its sync state (.git + remote config,
#     temperloop#430 / ADR 0003) — is USER DATA and must survive uninstall
#     intact: repo present, remote still wired, note content untouched.
# ===========================================================================
[ -d "$STORE_DIR" ] || fail "6b: the knowledge store dir must survive uninstall"
[ -d "$STORE_DIR/.git" ] || fail "6b: the store's .git must survive uninstall (sync state is user data)"
[ "$(git -C "$STORE_DIR" remote get-url origin)" = "$SYNC_REMOTE" ] \
  || fail "6b: the store's sync remote config must survive uninstall unchanged"
[ "$(cat "$STORE_DIR/Decisions/sync-survivor.md")" = "note that must survive uninstall" ] \
  || fail "6b: the store's note content must survive uninstall byte-for-byte"
pass "6b: the knowledge store survives uninstall intact — dir, .git, remote origin URL, and note content all untouched (uninstall never deletes or de-remotes the store)"

# ===========================================================================
# 7. After-uninstall snapshot + tree-diff against the declared, commented
#    exclusion set (acceptance criterion 1) — one diff per real machine-
#    analog root.
# ===========================================================================
AFTER_DIR="$SANDBOX_ROOT/manifests-after"
mkdir -p "$AFTER_DIR"
sandbox_tree_manifest "$SANDBOX_HOME"            > "$AFTER_DIR/home.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_CONFIG_HOME" > "$AFTER_DIR/xdg-config.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_STATE_HOME"  > "$AFTER_DIR/xdg-state.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_DATA_HOME"   > "$AFTER_DIR/xdg-data.tsv"
sandbox_tree_manifest "$SANDBOX_XDG_CACHE_HOME"  > "$AFTER_DIR/xdg-cache.tsv"

# --- Declared exclusion set, one variable per root, EACH commented with why.
# Empty = "must be byte-identical, zero exclusions" (the strongest possible
# claim for that root, and the actual expectation for three of the five).

# $HOME: install.sh's ENTIRE managed surface for a kernel-only checkout
# (kind=symlink + kind=gh-shim — no env/*, no real/claude-md kinds here,
# see this file's own header) is manifest-tracked, so a full uninstall must
# restore it exactly to the pre-install state. Zero exclusions.
EXCL_HOME=""

# $XDG_CONFIG_HOME: nothing in the install/uninstall flow itself writes
# here — the only content ever present is the operator-authored wizard-style
# conf seeded above (test 6), which is present, unchanged, in BOTH the
# before and after snapshots, so it already matches with zero exclusions.
# (No config-wizard leg runs in this suite — see docs/features/
# configure-config-cli.md for that separate surface — so there is nothing
# ELSE this pattern needs to cover today; kept as an explicit empty rather
# than omitted so a future config-wizard leg has an obvious place to add
# one.)
EXCL_XDG_CONFIG=""

# $XDG_STATE_HOME: `temperloop uninstall` (manifest.sh's
# manifest_restore_from_record / manifest_remove_path_entry) removes every
# PATH ENTRY from the manifest on a full successful run, but never deletes
# the manifest FILE itself — install-manifest.json is left on disk holding
# {"schema_version":1,"paths":{}} after uninstall, where it did not exist at
# all before install. This is manifest.sh's own documented contract (see
# its header's "Re-install convergence" note and manifest_remove_path_entry
# — it deletes a KEY, never the file), not a leak: a future re-install
# should find, not recreate, this same state file. Declared here as the one
# expected exclusion for this root.
EXCL_XDG_STATE="temperloop/install-manifest.json"

# $XDG_DATA_HOME: nothing in links_enumerate(), manifest.sh, or the
# cache-store provisioning step targets XDG_DATA_HOME at all. The ONE
# expected occupant is the knowledge STORE this suite's own sync leg (4b)
# seeds at the default store root — user data (notes + the git-backed sync
# state: .git, the origin remote config) that `temperloop uninstall` must
# keep, per ADR 0003 ("the store is user data — uninstall never deletes or
# de-remotes it"; asserted positively in 6b). Declaring EXACTLY the store
# dir here is what makes this diff the residue proof for sync: any
# sync-specific state landing OUTSIDE the explicitly-kept store dir — in
# this root or in any of the other four (e.g. a stray global gitconfig
# write under $HOME) — still fails its root's diff.
EXCL_XDG_DATA="temperloop/knowledge/*"

# $XDG_CACHE_HOME: install.sh's own "Best-effort cache-store provisioning"
# step (links_provision_cache_stores, F#988/#1026) unconditionally
# mkdir -p's a cache-store ROOT directory here on every install run — see
# install.sh's own header: "not a managed path doctor.sh's own OK/non-OK
# gate tracks (it is informational only)". Because it is deliberately NOT
# manifest-recorded, `temperloop uninstall` has no entry for it and, by the
# manifest's own "a path with no entry is invisible" discipline, correctly
# never removes it. An empty provisioned directory contributes zero records
# to sandbox_tree_manifest (it walks files/symlinks only, never bare
# directories — see that function's own header), so this pattern is
# declared for documentation/forward-compatibility (a future cache-store
# write that drops a FILE here would need it) rather than because today's
# run produces a matchable record; the diagnostic check further down proves
# the directory itself is real, expected, undeleted residue regardless.
EXCL_XDG_CACHE="temperloop/*"

sandbox_tree_diff "$BEFORE_DIR/home.tsv" "$AFTER_DIR/home.tsv" "$EXCL_HOME" \
  || fail "7a: unexplained diff under \$HOME between before-install and after-uninstall (see the unified diff above) — expected byte-identical, zero exclusions"
pass "7a: \$HOME machine surface is byte-identical before-install vs after-uninstall (zero exclusions — full round-trip)"

sandbox_tree_diff "$BEFORE_DIR/xdg-config.tsv" "$AFTER_DIR/xdg-config.tsv" "$EXCL_XDG_CONFIG" \
  || fail "7b: unexplained diff under \$XDG_CONFIG_HOME between before-install and after-uninstall"
pass "7b: \$XDG_CONFIG_HOME is byte-identical before-install vs after-uninstall (the operator-authored wizard-style conf is present and unchanged in both — see test 6)"

sandbox_tree_diff "$BEFORE_DIR/xdg-state.tsv" "$AFTER_DIR/xdg-state.tsv" "$EXCL_XDG_STATE" \
  || fail "7c: unexplained residue under \$XDG_STATE_HOME beyond the declared install-manifest.json exclusion (see the unified diff above)"
pass "7c: \$XDG_STATE_HOME residue after uninstall is exactly the declared exclusion (the empty install-manifest.json a full uninstall legitimately leaves behind) — no unexplained residue"

sandbox_tree_diff "$BEFORE_DIR/xdg-data.tsv" "$AFTER_DIR/xdg-data.tsv" "$EXCL_XDG_DATA" \
  || fail "7d: unexplained residue under \$XDG_DATA_HOME beyond the explicitly-kept knowledge store dir (see the unified diff above)"
pass "7d: \$XDG_DATA_HOME residue after uninstall is exactly the explicitly-kept knowledge store (user data incl. its git-backed sync state) — no sync-specific residue outside the store dir"

sandbox_tree_diff "$BEFORE_DIR/xdg-cache.tsv" "$AFTER_DIR/xdg-cache.tsv" "$EXCL_XDG_CACHE" \
  || fail "7e: unexplained residue under \$XDG_CACHE_HOME beyond the declared cache-store-root exclusion (see the unified diff above)"
pass "7e: \$XDG_CACHE_HOME residue after uninstall is exactly the declared exclusion (the best-effort cache-store root install.sh provisions, never manifest-tracked, never removed by uninstall) — no unexplained residue"

# Diagnostic (not a pass/fail gate): confirms in the suite's own output that
# the cache-store root really is left behind by uninstall, as EXCL_XDG_CACHE
# above documents — belt-and-suspenders since sandbox_tree_manifest itself
# cannot see an empty directory (see that variable's own comment).
if [ -d "$SANDBOX_XDG_CACHE_HOME/temperloop" ]; then
  echo "  (info) \$XDG_CACHE_HOME/temperloop still present after uninstall, as declared/expected"
fi

# ===========================================================================
# 8. Tripwire CHECK — every REAL (non-sandboxed) machine path this lifecycle
#    could have touched on an isolation escape (all real-$HOME
#    links_enumerate targets + ~/.local/bin/temperloop — see the snapshot's
#    own comment above) must be byte-for-byte untouched across the ENTIRE
#    lifecycle.
# ===========================================================================
sandbox_tripwire_check lifecycle \
  || fail "8: a real machine path (a real-\$HOME managed target or ~/.local/bin/temperloop) drifted during the sandboxed lifecycle run (see stderr above)"
pass "8: every real-machine managed target (real \$HOME/.claude/* + ~/.local/bin/* surface) is byte-for-byte untouched across the whole sandboxed install/doctor/reinstall/uninstall lifecycle"

sandbox_root_snapshot="$SANDBOX_ROOT"
sandbox_down
[ ! -e "$sandbox_root_snapshot" ] || fail "sandbox_down did not remove the throwaway root ($sandbox_root_snapshot still exists)"

echo
echo "ALL PASS: test_install_lifecycle.sh"
