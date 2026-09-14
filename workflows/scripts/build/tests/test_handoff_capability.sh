#!/usr/bin/env bash
#
# test_handoff_capability.sh — coverage for handoff-capability.sh, the probe
# that makes a DROPPED orchestrator->engine hand-off key detectable
# (temperloop#2018).
#
# Three states, because those are the three the mechanism must distinguish and
# the middle one is the whole point:
#
#   1. ALL KEYS SUPPORTED        -> CAPABILITIES_OK
#   2. A KEY THE ENGINE DOES NOT UNDERSTAND -> CAPABILITIES_DEGRADED, and the
#      notice must NAME THAT KEY. A generic "your engine is old" line is a
#      fail here, so the assertion is on the key string, not on the outcome.
#   3. CAPABILITY INDETERMINABLE -> CAPABILITIES_INDETERMINATE, with a
#      NON-EMPTY reason. Never CAPABILITIES_OK: collapsing "cannot tell" into
#      "fine" is the typed-state failure the probe exists to end, so §3 asserts
#      the absence of that collapse across all five degenerate inputs (absent,
#      unreadable, no declaration, unterminated declaration, empty declaration).
#
# §4 is the DRIFT LINT that keeps the declaration from becoming a second list:
# the keys declared in build-level.mjs must be EXACTLY the keys its code reads
# as `input.<key>`. This is also the accessor temperloop#2024's hand-off key
# registry lint is meant to reuse (`handoff-capability.sh declared`), so the
# registry derives from the declaration rather than paralleling it.
#
# §5 covers the three drivers' wiring: build.md, sweep.md and fix.md must each
# reference the probe, because a mechanism that reaches only one driver is the
# exact partial-wiring failure #2024 tabulates.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$HERE/../handoff-capability.sh"
ENGINE="$HERE/../../../../claude/workflows/build-level.mjs"
COMMANDS="$HERE/../../../../claude/commands"

pass=0
fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1: $2"; fail=$((fail + 1)); }

[ -f "$PROBE" ]  || { echo "test_handoff_capability: missing $PROBE" >&2; exit 1; }
[ -f "$ENGINE" ] || { echo "test_handoff_capability: missing $ENGINE" >&2; exit 1; }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

probe_json() { bash "$PROBE" check "$1" "$2" 2>/dev/null; }
# The `2>&1 >/dev/null` ORDER is deliberate and is the point: it captures
# stderr ALONE (stdout goes to /dev/null afterwards), which is how these
# assertions test the notice separately from the JSON verdict.
# shellcheck disable=SC2069
probe_notice() { bash "$PROBE" check "$1" "$2" 2>&1 >/dev/null; }
field() { printf '%s' "$1" | jq -r "$2"; }

echo "== handoff-capability.sh =="

# ---------------------------------------------------------------------------
# 1. ALL KEYS SUPPORTED
# ---------------------------------------------------------------------------
out="$(probe_json "$ENGINE" "repoRoot,planLink,reviewerRoutingTsv,onlySlugs")"
if [ "$(field "$out" .outcome)" = "CAPABILITIES_OK" ]; then
  ok "all keys supported -> CAPABILITIES_OK"
else
  bad "all keys supported" "expected CAPABILITIES_OK, got: $out"
fi
if [ "$(field "$out" '.dropped | length')" = "0" ]; then
  ok "all keys supported -> empty dropped[]"
else
  bad "all keys supported" "dropped[] not empty: $out"
fi
if [ "$(field "$out" '.notice // "null"')" = "null" ]; then
  ok "all keys supported -> no degradation notice"
else
  bad "all keys supported" "emitted a notice on a clean pass: $out"
fi
if [ -z "$(probe_notice "$ENGINE" "repoRoot,planLink")" ]; then
  ok "all keys supported -> stderr silent"
else
  bad "all keys supported" "stderr not silent on a clean pass"
fi

# ---------------------------------------------------------------------------
# 2. A KEY THE ENGINE DOES NOT UNDERSTAND — the notice must NAME it
# ---------------------------------------------------------------------------
out="$(probe_json "$ENGINE" "repoRoot,hypotheticalNewKey")"
if [ "$(field "$out" .outcome)" = "CAPABILITIES_DEGRADED" ]; then
  ok "unsupported key -> CAPABILITIES_DEGRADED"
else
  bad "unsupported key" "expected CAPABILITIES_DEGRADED, got: $out"
fi
if [ "$(field "$out" '.dropped | join(",")')" = "hypotheticalNewKey" ]; then
  ok "unsupported key -> dropped[] is exactly the unsupported key"
else
  bad "unsupported key" "dropped[] wrong: $out"
fi
notice="$(field "$out" .notice)"
case "$notice" in
  *hypotheticalNewKey*) ok "unsupported key -> notice NAMES the key" ;;
  *) bad "unsupported key" "notice does not name the key (a generic warning does not satisfy the contract): $notice" ;;
esac
# The supported key must NOT be named — naming everything is as useless as
# naming nothing.
case "$notice" in
  *repoRoot*) bad "unsupported key" "notice names a SUPPORTED key too: $notice" ;;
  *) ok "unsupported key -> notice names only the dropped key" ;;
esac
if [ "$(probe_notice "$ENGINE" "repoRoot,hypotheticalNewKey")" = "$notice" ]; then
  ok "unsupported key -> notice reaches stderr verbatim"
else
  bad "unsupported key" "stderr notice differs from the JSON notice field"
fi
# Two dropped keys are both named, comma-joined (guards the BSD `paste -sd`
# delimiter-cycling trap the script's join_commas comment records).
out2="$(probe_json "$ENGINE" "aaaNewKey,repoRoot,zzzNewKey")"
case "$(field "$out2" .notice)" in
  *"aaaNewKey, zzzNewKey"*) ok "two dropped keys -> both named, comma-joined" ;;
  *) bad "two dropped keys" "join wrong: $(field "$out2" .notice)" ;;
esac

# ---------------------------------------------------------------------------
# 3. CAPABILITY INDETERMINABLE — five degenerate inputs, none collapsing to OK
# ---------------------------------------------------------------------------
printf 'console.log("an engine predating the declaration")\n' > "$TMP/no-decl.mjs"
head -c 200 "$ENGINE" > "$TMP/unterminated.mjs"
printf '\n// HANDOFF-CAPABILITIES-BEGIN\nexport const inputCapabilities = [\n' >> "$TMP/unterminated.mjs"
printf '// HANDOFF-CAPABILITIES-BEGIN\nexport const inputCapabilities = [];\n// HANDOFF-CAPABILITIES-END\n' > "$TMP/empty-decl.mjs"
printf 'anything\n' > "$TMP/unreadable.mjs"
chmod 000 "$TMP/unreadable.mjs" 2>/dev/null || true

for case_name in absent no-decl unterminated empty-decl unreadable; do
  case "$case_name" in
    absent) target="$TMP/does-not-exist.mjs" ;;
    *)      target="$TMP/$case_name.mjs" ;;
  esac
  # The unreadable case is a no-op when the test runs as a user who can read
  # anything (root, or a filesystem ignoring the mode) — skip rather than
  # assert a state the host cannot produce.
  if [ "$case_name" = "unreadable" ] && [ -r "$target" ]; then
    ok "indeterminable/unreadable -> skipped (this host cannot make a file unreadable)"
    continue
  fi

  out="$(probe_json "$target" "repoRoot,reviewerRoutingTsv")"
  got="$(field "$out" .outcome)"
  if [ "$got" = "CAPABILITIES_INDETERMINATE" ]; then
    ok "indeterminable/$case_name -> CAPABILITIES_INDETERMINATE"
  else
    bad "indeterminable/$case_name" "expected CAPABILITIES_INDETERMINATE, got $got: $out"
  fi
  if [ "$got" = "CAPABILITIES_OK" ]; then
    bad "indeterminable/$case_name" "COLLAPSED unknown into OK — the exact failure this probe exists to prevent"
  fi
  reason="$(field "$out" '.reason // ""')"
  if [ -n "$reason" ]; then
    ok "indeterminable/$case_name -> non-empty reason"
  else
    bad "indeterminable/$case_name" "empty reason — a probe that cannot say WHY it could not tell is itself a silent no-op"
  fi
  if [ "$(field "$out" '.declared // "null"')" = "null" ]; then
    ok "indeterminable/$case_name -> declared is null, never a count"
  else
    bad "indeterminable/$case_name" "declared should be null: $out"
  fi
  if [ -n "$(probe_notice "$target" "repoRoot")" ]; then
    ok "indeterminable/$case_name -> notice reaches stderr"
  else
    bad "indeterminable/$case_name" "silent on stderr"
  fi
done

# `declared` reports the same failure through an exit code rather than a
# verdict, so the #2024 registry lint cannot mistake "no declaration" for
# "declares nothing".
set +e
decl_out="$(bash "$PROBE" declared "$TMP/no-decl.mjs" 2>/dev/null)"
decl_rc=$?
set -e
if [ "$decl_rc" -ne 0 ] && [ -z "$decl_out" ]; then
  ok "declared on an undeclared engine -> non-zero exit, empty stdout"
else
  bad "declared on an undeclared engine" "rc=$decl_rc out='$decl_out'"
fi

# A verdict NEVER aborts a `set -e` driver — only ERROR does.
for keys in "repoRoot" "repoRoot,hypotheticalNewKey"; do
  set +e
  bash "$PROBE" check "$ENGINE" "$keys" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "verdict exits 0 (keys: $keys)"
  else
    bad "verdict exit code" "rc=$rc for keys '$keys' — a verdict must not abort a set -e driver"
  fi
done
set +e
bash "$PROBE" bogus-subcommand >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  ok "an unknown subcommand is an ERROR, not a verdict"
else
  bad "unknown subcommand" "exited 0"
fi

# ---------------------------------------------------------------------------
# 4. DRIFT LINT — the declaration == the keys the engine actually reads
# ---------------------------------------------------------------------------
declared_keys="$(bash "$PROBE" declared "$ENGINE")"
read_keys="$(grep -oE 'input\.[A-Za-z_][A-Za-z0-9_]*' "$ENGINE" | sed 's/^input\.//' | sort -u)"

if [ -n "$read_keys" ]; then
  ok "drift lint: extraction found input.* reads in the engine"
else
  bad "drift lint" "found zero input.* reads — the extraction regex is stale"
fi

undeclared="$(comm -13 <(printf '%s\n' "$declared_keys") <(printf '%s\n' "$read_keys"))"
unread="$(comm -23 <(printf '%s\n' "$declared_keys") <(printf '%s\n' "$read_keys"))"

if [ -z "$undeclared" ]; then
  ok "drift lint: every input.<key> the engine reads is declared"
else
  bad "drift lint" "read but NOT declared (add to the HANDOFF-CAPABILITIES block): $(printf '%s' "$undeclared" | tr '\n' ' ')"
fi
if [ -z "$unread" ]; then
  ok "drift lint: every declared key is actually read"
else
  bad "drift lint" "declared but never read (stale declaration): $(printf '%s' "$unread" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 5. ALL THREE DRIVERS WIRE THE PROBE
# ---------------------------------------------------------------------------
for driver in build sweep fix; do
  spec="$COMMANDS/$driver.md"
  if [ ! -f "$spec" ]; then
    bad "driver wiring/$driver" "missing $spec"
    continue
  fi
  if grep -q 'handoff-capability\.sh' "$spec"; then
    ok "driver wiring: $driver.md invokes handoff-capability.sh"
  else
    bad "driver wiring/$driver" "does not reference handoff-capability.sh — a mechanism that reaches one driver is the partial-wiring failure this guards"
  fi
  if grep -q 'CAPABILITIES_INDETERMINATE' "$spec"; then
    ok "driver wiring: $driver.md disposes the INDETERMINATE outcome"
  else
    bad "driver wiring/$driver" "names no INDETERMINATE disposition — unknown would collapse into fine at the driver"
  fi
done

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
