#!/usr/bin/env bash
#
# Tests for config.sh — `temperloop config list` (temperloop#262, item
# configure-config-cli — ADR K164 D7). Exercises the PINNED clean-subshell
# layer-probe mechanism (config.sh's own header comment) against the REAL
# kernel registry (workflows/scripts/config/setting-registry.tsv) and the
# REAL build.config.sh — deliberately, not a synthetic fixture registry:
# the point of `config list` is to reflect THIS repo's actual precedence
# resolution, so testing against real rows also catches real drift.
#
# Covers:
#   - an exported env var wins (layer "env"), value reflects the export
#   - a machine-conf file (XDG_CONFIG_HOME fixture) setting a var wins
#     over its tracked-repo default (layer "machine-conf")
#   - a repo-local file (BUILD_CONFIG_LOCAL fixture) setting a var wins
#     over its tracked-repo default (layer "repo-local")
#   - an untouched tracked-repo-layer setting resolves to build.config.sh's
#     own default, layer "tracked-repo"
#   - an untouched kernel-layer setting (owned by a script OTHER than
#     build.config.sh) resolves to the registry default, layer "kernel"
#   - --format text prints the layer-1 "n/a at list-time" note once
#   - --format tsv header row is exact
#   - unknown subcommand / no args -> exit 2; -h/--help -> exit 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/../config.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/config-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# tsv_field <tsv-output> <name> <field#> (1=name 2=layer 3=value 4=owning 5=doc)
#
# Herestring input, NOT `printf | awk`: awk's early `exit` closes the pipe
# while the writer may still be flushing, so under this suite's
# `set -o pipefail` a pipeline here can report SIGPIPE (rc 141) on a
# perfectly good match — a scheduling race that fires readily on Linux CI
# runners and almost never on macOS (the temperloop#262 CI-only failure).
# A herestring has no writer process to kill, so it is race-free.
tsv_field() {
  awk -F'\t' -v n="$2" -v f="$3" '$1==n{print $f; exit}' <<<"$1"
}

# =============================================================================
# 1. env layer: an exported var wins, value reflects the export.
# =============================================================================
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL \
  BUILD_QUOTA_PAUSE_PCT=77 bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 2)" = "env" ] \
  || fail "env-set BUILD_QUOTA_PAUSE_PCT did not report layer=env (got: $(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 2))"
[ "$(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 3)" = "77" ] \
  || fail "env-set BUILD_QUOTA_PAUSE_PCT did not report the exported value (got: $(tsv_field "$out" BUILD_QUOTA_PAUSE_PCT 3))"
echo "PASS: an exported env var wins (layer=env, correct value)"

# =============================================================================
# 2. machine-conf layer: a machine-conf file setting a var wins over its
#    tracked-repo default.
# =============================================================================
XDG="$WORK/xdg"
mkdir -p "$XDG/temperloop"
cat > "$XDG/temperloop/build.config.sh" <<'EOF'
: "${BUILD_MERGE_GATE_WINDOW:=999}"
export BUILD_MERGE_GATE_WINDOW
EOF
out="$(env -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL XDG_CONFIG_HOME="$XDG" bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 2)" = "machine-conf" ] \
  || fail "machine-conf-set BUILD_MERGE_GATE_WINDOW did not report layer=machine-conf (got: $(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 2))"
[ "$(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 3)" = "999" ] \
  || fail "machine-conf-set BUILD_MERGE_GATE_WINDOW did not report the machine-conf value (got: $(tsv_field "$out" BUILD_MERGE_GATE_WINDOW 3))"
echo "PASS: a machine-conf file setting a var wins over its tracked-repo default (layer=machine-conf)"

# =============================================================================
# 3. repo-local layer: a BUILD_CONFIG_LOCAL fixture setting a var wins over
#    its tracked-repo default (and is itself outranked by machine-conf,
#    tested implicitly by using a DIFFERENT setting than test 2 above).
# =============================================================================
LOCAL_CONF="$WORK/build.config.local.sh"
cat > "$LOCAL_CONF" <<'EOF'
: "${TIDY_SYNC_WAIT:=555}"
export TIDY_SYNC_WAIT
EOF
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE BUILD_CONFIG_LOCAL="$LOCAL_CONF" bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" TIDY_SYNC_WAIT 2)" = "repo-local" ] \
  || fail "repo-local-set TIDY_SYNC_WAIT did not report layer=repo-local (got: $(tsv_field "$out" TIDY_SYNC_WAIT 2))"
[ "$(tsv_field "$out" TIDY_SYNC_WAIT 3)" = "555" ] \
  || fail "repo-local-set TIDY_SYNC_WAIT did not report the repo-local value (got: $(tsv_field "$out" TIDY_SYNC_WAIT 3))"
echo "PASS: a repo-local (BUILD_CONFIG_LOCAL) file setting a var wins over its tracked-repo default (layer=repo-local)"

# =============================================================================
# 4. untouched tracked-repo-layer setting -> build.config.sh's own default,
#    layer=tracked-repo.
# =============================================================================
out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL bash "$CONFIG" list --format tsv)"
[ "$(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 2)" = "tracked-repo" ] \
  || fail "untouched PIPELINE_DRIVE_CONCURRENCY did not report layer=tracked-repo (got: $(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 2))"
[ "$(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 3)" = "3" ] \
  || fail "untouched PIPELINE_DRIVE_CONCURRENCY did not report build.config.sh's default of 3 (got: $(tsv_field "$out" PIPELINE_DRIVE_CONCURRENCY 3))"
echo "PASS: an untouched tracked-repo-layer setting resolves to build.config.sh's own default (layer=tracked-repo)"

# =============================================================================
# 5. untouched kernel-layer setting (owned by a script other than
#    build.config.sh) -> registry default, layer=kernel.
# =============================================================================
[ "$(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 2)" = "kernel" ] \
  || fail "untouched BASELINE_SNAPSHOT_TIMEOUT did not report layer=kernel (got: $(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 2))"
[ "$(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 3)" = "20" ] \
  || fail "untouched BASELINE_SNAPSHOT_TIMEOUT did not report its registry default of 20 (got: $(tsv_field "$out" BASELINE_SNAPSHOT_TIMEOUT 3))"
echo "PASS: an untouched kernel-layer setting resolves to the registry default (layer=kernel)"

# =============================================================================
# 6. --format text prints the layer-1 n/a note + header once; --format tsv
#    header row is exact.
# =============================================================================
text_out="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL bash "$CONFIG" list)"
# Herestrings, not `echo "$text_out" | grep -q` / `printf | head -1`: -q and
# -1 stop reading at the first match/line, and under `set -euo pipefail` the
# still-writing left side then dies of SIGPIPE (rc 141), failing the pipeline
# — and, for the head-1 assignment, killing the whole suite — on a run whose
# output was CORRECT. This is the Linux-CI-only failure this suite shipped
# with (temperloop#262): the race all but never fires on macOS, so it looked
# platform-dependent. See tsv_field's comment above.
grep -q 'layer 1 .cli. is never resolved at list-time' <<<"$text_out" \
  || fail "text format did not print the layer-1 n/a note"
grep -q '^NAME' <<<"$text_out" || fail "text format did not print a NAME header"

tsv_header="$(head -1 <<<"$out")"
[ "$tsv_header" = "$(printf 'name\tlayer\tvalue\towning-script\tdoc')" ] \
  || fail "tsv header row is not exact (got: $tsv_header)"
echo "PASS: --format text prints the layer-1 n/a note; --format tsv header row is exact"

# =============================================================================
# 7. CLI usage errors.
# =============================================================================
set +e
bash "$CONFIG" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "no args did not exit 2 (got: $rc)"

set +e
bash "$CONFIG" bogus >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown subcommand did not exit 2 (got: $rc)"

set +e
bash "$CONFIG" -h >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "-h did not exit 0 (got: $rc)"

set +e
bash "$CONFIG" list --format bogus >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --format did not exit 2 (got: $rc)"
echo "PASS: CLI usage errors (no args / unknown subcommand / invalid --format exit 2; -h exits 0)"

# =============================================================================
# 8. an overlay row whose NAME is not a legal shell identifier is rejected
#    upstream by registry validation: `config list` refuses loudly (exit 1,
#    diagnostics naming the row and its source file) instead of silently
#    dropping the row and exiting 0 (temperloop#1825). Fixture uses the real
#    overlay basename an operator would author.
# =============================================================================
BADOV_DIR="$WORK/badname-overlay"
mkdir -p "$BADOV_DIR"
printf 'SWEEP-FANOUT-WIDTH\t3\tint\tkernel\tscripts/a.sh\thyphenated name, illegal\tadd\n' \
  > "$BADOV_DIR/setting-registry.overlay.tsv"
set +e
badname_err="$(env -u XDG_CONFIG_HOME -u BUILD_CONFIG_MACHINE -u BUILD_CONFIG_LOCAL \
  SETTING_REGISTRY_OVERLAY_FILE="$BADOV_DIR/setting-registry.overlay.tsv" \
  bash "$CONFIG" list --format tsv 2>&1 >/dev/null)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an illegal-name overlay row did not make config list exit non-zero"
grep -q "not a legal shell identifier" <<<"$badname_err" \
  || fail "config list stderr did not carry the illegal-name diagnostic (got: $badname_err)"
grep -q "SWEEP-FANOUT-WIDTH" <<<"$badname_err" \
  || fail "config list stderr did not name the offending row (got: $badname_err)"
grep -q "setting-registry.overlay.tsv" <<<"$badname_err" \
  || fail "config list stderr did not name the offending source file (got: $badname_err)"
echo "PASS: an illegal-name overlay row is rejected upstream — config list exits non-zero and names the row + file"

echo
echo "ALL PASS: test_config.sh"
