#!/usr/bin/env bash
#
# Tests for workflows/scripts/install/doctor.sh's check_bm_tool_install()
# (temperloop#1113) — the DOCTOR half of the hybrid uv-tool install design.
#
# The other half (the availability gate's lazy install-on-first-use) is
# covered by workflows/scripts/lib/tests/test_knowledge_search.sh cases 18a-f.
# Both halves ship together, deliberately: doctor gives an installed checkout
# a predictable, pre-warmed state; the lazy gate keeps a stranger who never
# runs doctor from hitting a permanent silent skip.
#
# Covers, one state per case:
#   1. ABSENT   — nothing installed, `uv` present -> doctor INSTALLS it and
#                 reports INSTALLED, and the entry point + pin stamp exist.
#   2. warm     — already installed at the configured pin -> reported
#                 INSTALLED without invoking `uv` again.
#   3. PIN DRIFT— an entry point installed at a different pin -> re-installed
#                 and re-stamped, never left serving the old build.
#   4. no `uv`  — reported UNAVAILABLE, and doctor still exits on its OWN
#                 verdict (this check is advisory and never a gate).
#   5. install failure -> reported INSTALL FAILED, still advisory.
#   6. SKIPPED  — the libraries are absent from the target tree (a stranger's
#                 clone with no knowledge-store pieces wired up).
#
# Hermetic (kernel principle 3): every case runs against a FAKE `uv` on PATH
# under a throwaway tmpdir with an isolated HOME/XDG root. No network, no real
# `uv tool install`, no real basic-memory, and the operator's real
# ~/.local/{share,bin} is never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DOCTOR_SH="${REPO_ROOT}/workflows/scripts/install/doctor.sh"
STORE_LIB_REAL="${REPO_ROOT}/workflows/scripts/lib/knowledge_store.sh"
SEARCH_LIB_REAL="${REPO_ROOT}/workflows/scripts/lib/knowledge_search.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor-bm-tool-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

[ -f "$DOCTOR_SH" ]       || fail "0: doctor.sh not found at $DOCTOR_SH"
[ -f "$STORE_LIB_REAL" ]  || fail "0: knowledge_store.sh not found at $STORE_LIB_REAL"
[ -f "$SEARCH_LIB_REAL" ] || fail "0: knowledge_search.sh not found at $SEARCH_LIB_REAL"

# A minimal fake FOUNDATION tree carrying REAL copies of both libraries at
# their real relative paths, so check_bm_tool_install's own
# "${FOUNDATION}/workflows/scripts/lib/..." lookups resolve exactly as they
# would in a real checkout (same fixture shape as test_doctor_knowledge_root).
FOUND="${TMP}/found"
mkdir -p "${FOUND}/workflows/scripts/lib"
cp "$STORE_LIB_REAL"  "${FOUND}/workflows/scripts/lib/knowledge_store.sh"
cp "$SEARCH_LIB_REAL" "${FOUND}/workflows/scripts/lib/knowledge_search.sh"

FOUND_EMPTY="${TMP}/empty"
mkdir -p "$FOUND_EMPTY"

HOME_FIX="${TMP}/home"
XDG_CONFIG_FIX="${TMP}/xdgconf"
XDG_DATA_FIX="${TMP}/xdgdata"
STORE_FIX="${TMP}/store"
BM_HOME="${TMP}/bm-home"
BIN="${TMP}/bin"
UV_LOG="${TMP}/uv-calls.log"
mkdir -p "$HOME_FIX" "$XDG_CONFIG_FIX" "$XDG_DATA_FIX" "$STORE_FIX" "$BIN"

TOOL_BIN_DIR="${BM_HOME}/uv-tool-bin"
BM_BIN="${TOOL_BIN_DIR}/basic-memory"
PIN_STAMP="${TOOL_BIN_DIR}/.ks-installed-pin"

# The fake `uv` — the ONLY thing this test puts on PATH under that name. It
# requires UV_TOOL_BIN_DIR to be pinned by the adapter, which is itself the
# assertion that doctor's install never escapes into the operator's real
# ~/.local/bin.
cat > "${BIN}/uv" <<'FAKEUV'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_UV_LOG:?}"
printf 'ARGS: %s\n' "$*" >> "$FAKE_UV_LOG"
[ "${1:-}" = "tool" ] && [ "${2:-}" = "install" ] || { echo "fake-uv: unsupported: $*" >&2; exit 9; }
if [ "${FAKE_UV_MODE:-ok}" = "install_fail" ]; then
  echo "fake-uv: simulated resolution failure" >&2
  exit 1
fi
: "${UV_TOOL_BIN_DIR:?fake-uv: UV_TOOL_BIN_DIR must be pinned by the adapter}"
mkdir -p "$UV_TOOL_BIN_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' > "$UV_TOOL_BIN_DIR/basic-memory"
chmod +x "$UV_TOOL_BIN_DIR/basic-memory"
exit 0
FAKEUV
chmod +x "${BIN}/uv"

# _run_doctor [VAR=value ...] — fully isolated subprocess env (env -i) plus
# whatever extra pairs the caller appends. `$BIN` is prepended to PATH so the
# fake `uv` wins; a real one on the host is never reached.
_run_doctor() {
  env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" XDG_DATA_HOME="$XDG_DATA_FIX" \
    PATH="${BIN}:${PATH}" \
    FAKE_UV_LOG="$UV_LOG" \
    KNOWLEDGE_STORE_ROOT="$STORE_FIX" \
    KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME" \
    "$@" bash "$DOCTOR_SH" "$FOUND" 2>&1
}

# _section <doctor-output> — just the check's own block.
_section() { printf '%s\n' "$1" | sed -n '/knowledge_search basic-memory tool/,/^$/p'; }

# ---------------------------------------------------------------------------
# 1. ABSENT -> doctor installs the pin and reports INSTALLED.
# ---------------------------------------------------------------------------
rm -rf "$BM_HOME"; rm -f "$UV_LOG"
set +e
out1="$(_run_doctor)"
set -e
sec1="$(_section "$out1")"
grep -q 'state       ABSENT — installing' <<<"$sec1" \
  || fail "1: expected the ABSENT state to be reported before installing — got: $sec1"
grep -q 'state       INSTALLED (matches the configured pin)' <<<"$sec1" \
  || fail "1: expected INSTALLED after the install — got: $sec1"
grep -q "entry point ${BM_BIN}\$" <<<"$sec1" \
  || fail "1: the report must name the entry-point path — got: $sec1"
grep -qE '^  pin         basic-memory==[0-9]' <<<"$sec1" \
  || fail "1: the report must name the pin — got: $sec1"
[ -x "$BM_BIN" ]   || fail "1: doctor did not install an entry point at $BM_BIN"
[ -f "$PIN_STAMP" ] || fail "1: doctor did not record the installed pin at $PIN_STAMP"
grep -q '^ARGS: tool install ' "$UV_LOG" \
  || fail "1: doctor did not invoke 'uv tool install' (log: $(cat "$UV_LOG" 2>/dev/null))"
pass "1: an absent pin is INSTALLED and reported by doctor (the pre-warm half of the hybrid)"

# ---------------------------------------------------------------------------
# 2. already installed -> reported INSTALLED, uv never invoked again.
# ---------------------------------------------------------------------------
rm -f "$UV_LOG"
set +e
out2="$(_run_doctor)"
set -e
sec2="$(_section "$out2")"
grep -q 'state       INSTALLED (matches the configured pin)' <<<"$sec2" \
  || fail "2: expected INSTALLED for an already-installed pin — got: $sec2"
grep -q 'installing' <<<"$sec2" \
  && fail "2: an already-installed pin must not re-install — got: $sec2"
[ ! -s "$UV_LOG" ] \
  || fail "2: an already-installed pin must not invoke uv at all (log: $(cat "$UV_LOG"))"
pass "2: an already-installed pin is reported INSTALLED without touching uv"

# ---------------------------------------------------------------------------
# 3. PIN DRIFT -> re-installed and re-stamped.
# ---------------------------------------------------------------------------
rm -f "$UV_LOG"
printf 'basic-memory==0.0.1 python=3.9\n' > "$PIN_STAMP"
set +e
out3="$(_run_doctor)"
set -e
sec3="$(_section "$out3")"
grep -q 'state       PIN DRIFT (installed at a different pin) — re-installing' <<<"$sec3" \
  || fail "3: expected PIN DRIFT to be reported — got: $sec3"
grep -q 'state       INSTALLED (matches the configured pin)' <<<"$sec3" \
  || fail "3: expected INSTALLED after the re-install — got: $sec3"
grep -q '^ARGS: tool install ' "$UV_LOG" \
  || fail "3: a drifted pin must trigger a re-install (log: $(cat "$UV_LOG" 2>/dev/null))"
grep -q 'python=3.9' "$PIN_STAMP" \
  && fail "3: the stale pin stamp survived the re-install — an upgrade would silently keep the old build"
pass "3: a pin the installed tool no longer matches is re-installed and re-stamped"

# ---------------------------------------------------------------------------
# 4. no `uv` on PATH -> UNAVAILABLE, advisory only.
# ---------------------------------------------------------------------------
# doctor itself needs a working userland (sed/grep/readlink), so "no uv" is
# expressed as the base system PATH rather than an empty one — and the case
# is SKIPPED, not silently weakened, on a host that ships uv in /usr/bin.
rm -rf "$BM_HOME"; rm -f "$UV_LOG"
NO_UV_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
if PATH="$NO_UV_PATH" command -v uv >/dev/null 2>&1; then
  echo "SKIP: 4 (this host ships uv inside the base system PATH)"
else
  set +e
  out4="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" XDG_DATA_HOME="$XDG_DATA_FIX" \
    PATH="$NO_UV_PATH" FAKE_UV_LOG="$UV_LOG" \
    KNOWLEDGE_STORE_ROOT="$STORE_FIX" KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME" \
    bash "$DOCTOR_SH" "$FOUND" 2>&1)"
  set -e
  sec4="$(_section "$out4")"
  grep -q 'state       UNAVAILABLE (uv is not on PATH' <<<"$sec4" \
    || fail "4: expected UNAVAILABLE with no uv on PATH — got: $sec4"
  [ ! -e "$BM_BIN" ] || fail "4: nothing may be installed when uv is absent"
  pass "4: no uv on PATH is reported UNAVAILABLE with the remedy named, never a crash"
fi

# ---------------------------------------------------------------------------
# 5. install failure -> INSTALL FAILED, still advisory (never a doctor gate).
#    The reference verdict is doctor's exit code on the SAME tree with the
#    install succeeding: this check must not change it either way.
# ---------------------------------------------------------------------------
rm -rf "$BM_HOME"; rm -f "$UV_LOG"
set +e
_run_doctor >/dev/null
rc_ok=$?
rm -rf "$BM_HOME"; rm -f "$UV_LOG"
out5="$(_run_doctor FAKE_UV_MODE=install_fail)"
rc_fail=$?
set -e
sec5="$(_section "$out5")"
grep -q 'state       INSTALL FAILED' <<<"$sec5" \
  || fail "5: expected INSTALL FAILED when uv exits non-zero — got: $sec5"
[ "$rc_fail" -eq "$rc_ok" ] \
  || fail "5: a failed install changed doctor's exit code ($rc_fail vs $rc_ok) — this check must stay advisory"
pass "5: a failed install is reported, and doctor's own verdict is unchanged (advisory, never a gate)"

# ---------------------------------------------------------------------------
# 6. libraries absent -> SKIPPED, never a hard failure.
# ---------------------------------------------------------------------------
set +e
out6="$(env -i HOME="$HOME_FIX" XDG_CONFIG_HOME="$XDG_CONFIG_FIX" XDG_DATA_HOME="$XDG_DATA_FIX" \
  PATH="${BIN}:${PATH}" FAKE_UV_LOG="$UV_LOG" \
  bash "$DOCTOR_SH" "$FOUND_EMPTY" 2>&1)"
set -e
sec6="$(_section "$out6")"
grep -q 'SKIPPED (knowledge_store.sh / knowledge_search.sh not found' <<<"$sec6" \
  || fail "6: expected SKIPPED when the libraries are absent — got: $sec6"
pass "6: a tree with no knowledge-store pieces degrades to SKIPPED"

echo "All doctor basic-memory-tool tests passed."
