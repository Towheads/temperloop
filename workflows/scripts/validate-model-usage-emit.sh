#!/usr/bin/env bash
#
# validate-model-usage-emit.sh — content-level schema validator for the
# model-usage attribution stream (temperloop#1253, epic #1225, ADR 0026:
# docs/adr/0026-attribution-telemetry-coexists-with-transcript-cost.md).
#
# GATE SCOPE — read this before extending it. This validator owns RECORD
# SCHEMA VALIDATION ONLY, at CONTENT level, not merely presence:
#
#   1. PRESENCE — emit-model-usage.sh exists and is executable.
#   2. STRICT PARSE — every line of every model-usage-*.jsonl file in the raw
#      lake is valid JSON under a STRICT parser (python3's json.loads with a
#      parse_constant hook that REJECTS `NaN`/`Infinity`/`-Infinity`). `jq -e .`
#      is deliberately NOT used for this check: jq accepts and silently
#      coerces bare NaN/Infinity to `null`, so a `jq`-based validity check
#      cannot catch a non-finite-corrupted record (a real trap hit and named
#      by this item's own testing bar).
#   3. SHAPE — every record has EXACTLY the required field set (a CLOSED
#      schema / allowlist, not merely a missing-field check — an unknown key
#      not in the required set is itself a FAIL, SCHEMA-CLOSED, whatever it's
#      named), correctly typed, with the usage_source/tokens/provider pairing
#      enforced (tokens and provider are BOTH present iff usage_source is
#      "cli-envelope", BOTH null iff "unavailable" — a mismatch is a shape
#      violation, not merely a missing field). This closed-schema check is
#      what makes check 5 below (no cross-repo identifier) a real guarantee
#      rather than a one-name denylist: `host` gets its own named message
#      (checked first, so that specific case keeps a specific, ADR-0028-
#      quoting reason), but ANY other unexpected field — `hostname`,
#      `operator`, `machine_id`, or a future copy-paste's own invented name —
#      is caught by the same generic check, not enumerated one at a time.
#   4. CONTENT-LEVEL ENUMS — not merely presence-checked:
#        * `model` must name a known Claude model FAMILY (opus/sonnet/haiku)
#          — the family token is the stable, enumerable part of a model id;
#          the numeric suffix revs too often to enumerate exhaustively.
#        * `provider` must be a member of the ADR 0028 COMMITTED provider
#          allowlist (workflows/scripts/model-comparison/allowlist.sh,
#          `pa_is_allowed` — reused, not re-parsed, so this validator and the
#          module's own consent gate can never silently disagree about which
#          providers are real). Today that set is Anthropic-only, so a
#          fixture record naming e.g. `provider: "openai"` FAILS here even
#          though its shape is otherwise valid — the acceptance-mandated
#          demonstration case.
#   5. NO CROSS-REPO IDENTIFIER — a record MUST NOT carry a `host` key (ADR
#      0028: "records carry seat role names rather than any cross-repo
#      operator identifier"). Every sibling emit stream in this repo DOES
#      carry `host`; this one deliberately does not, and this check is what
#      keeps that divergence from silently regressing if a future edit
#      copy-pastes the sibling shape.
#
# EXPLICITLY OUT OF SCOPE (owned by a LATER item, attribution-spawn-site-wiring,
# temperloop#1255): SPAWN-SITE COVERAGE — proving that every emit-feasible
# seat (A7 pipeline-drive-safe, A8 pipeline-drive-merge, A9 retro-judge, per
# the L0 spike) actually calls emit-model-usage.sh. No spawn site is wired
# yet, so an EMPTY or ABSENT raw-lake stream is LEGAL here, exactly like
# validate-provider-disclosure.sh's "absent/empty disclosure log is legal"
# precedent — never a failure this gate reports.
#
# Usage:
#   workflows/scripts/validate-model-usage-emit.sh
#     (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh;
#     resolves the repo itself and scans $MODEL_USAGE_RAW_DIR, default
#     <repo>/meta/data/raw)
#   workflows/scripts/validate-model-usage-emit.sh --file <path>
#     validate exactly one JSONL file (or "-" for stdin) instead of scanning
#     the raw lake — the fixture-test seam test_model_usage_emit.sh uses.
#
# FAIL-CLOSED DISCIPLINE (mirroring validate-provider-disclosure.sh): a
# genuine "this record is malformed/out-of-enum" verdict is a FAIL; an
# inability to evaluate at all (jq/python3 missing, an unreadable file) is a
# hard abort (exit 1, CANNOT EVALUATE), never a silently-reported pass.
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT_SCRIPT="$SCRIPT_DIR/emit-model-usage.sh"
ALLOWLIST_LIB="$SCRIPT_DIR/model-comparison/allowlist.sh"

single_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      # ARG-ARITY GUARD (BLOCKING 1): a trailing `--file` with no following
      # argument used to fall through to `shift 2` with only 1 positional
      # param left — `shift 2` then fails and shifts NOTHING, and since this
      # script deliberately does not run under `set -e`, `$#` never
      # decreases and the loop spins at 100% CPU forever instead of
      # returning. Guard the arity before shifting, and reject a value that
      # itself looks like another flag (e.g. `--file --other`) rather than
      # silently consuming it as the path.
      if [ $# -lt 2 ]; then
        echo "validate-model-usage-emit: CANNOT EVALUATE — --file requires a value" >&2
        exit 1
      fi
      case "$2" in
        --*)
          echo "validate-model-usage-emit: CANNOT EVALUATE — --file requires a value, got flag-like '$2'" >&2
          exit 1
          ;;
      esac
      single_file="$2"; shift 2 ;;
    *) echo "validate-model-usage-emit: CANNOT EVALUATE — unknown argument $1" >&2; exit 1 ;;
  esac
done

fail=0

# --- 1. the emit script itself must exist and be executable -----------------
if [ ! -f "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-model-usage.sh is missing (expected at $EMIT_SCRIPT)"
  fail=1
elif [ ! -x "$EMIT_SCRIPT" ]; then
  echo "FAIL  emit-model-usage.sh exists but is not executable ($EMIT_SCRIPT)"
  fail=1
else
  echo "ok    emit-model-usage.sh present and executable"
fi

if [ ! -f "$ALLOWLIST_LIB" ]; then
  echo "validate-model-usage-emit: CANNOT EVALUATE — $ALLOWLIST_LIB is missing" >&2
  exit 1
fi
# shellcheck source=workflows/scripts/model-comparison/allowlist.sh
source "$ALLOWLIST_LIB"

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-model-usage-emit: CANNOT EVALUATE — jq not found" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "validate-model-usage-emit: CANNOT EVALUATE — python3 not found (needed for a STRICT JSON parse that rejects NaN/Infinity — jq -e . silently accepts them)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Resolve which file(s) to scan.
# ---------------------------------------------------------------------------
files=()
if [ -n "$single_file" ]; then
  if [ "$single_file" != "-" ] && [ ! -f "$single_file" ]; then
    echo "validate-model-usage-emit: CANNOT EVALUATE — --file $single_file does not exist" >&2
    exit 1
  fi
  files=("$single_file")
else
  # NO foreign-path guess (advisory 9a): a prior version of this line fell
  # back to a hardcoded $HOME/dev/foundation when the repo-root resolution
  # failed. In temperloop that is a different repo entirely, and a
  # stranger's checkout has no such directory — scanning (or silently
  # skipping) a foreign, unrelated tree is worse than a hard abort.
  raw_root="$(cd -P "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
  # `${MODEL_USAGE_RAW_DIR:+x}` (not `${MODEL_USAGE_RAW_DIR:-}`) — see the
  # matching comment in emit-model-usage.sh: a second `:-`-shaped seam here
  # would trip the setting-registry lint's per-seam equality check.
  if [ -z "${MODEL_USAGE_RAW_DIR:+x}" ] && [ -z "$raw_root" ]; then
    echo "validate-model-usage-emit: CANNOT EVALUATE — cannot resolve the repo root above $SCRIPT_DIR, and MODEL_USAGE_RAW_DIR is unset — no fallback path guessed" >&2
    exit 1
  fi
  raw_dir="${MODEL_USAGE_RAW_DIR:-$raw_root/meta/data/raw}"
  if [ -d "$raw_dir" ]; then
    # BLOCKING 3: distinguish "glob found nothing" (legal, see below) from
    # "the dir exists but this process can't read it" (e.g. a
    # container-mounted raw lake owned by a different uid) — the latter must
    # CANNOT EVALUATE, never silently read as an empty, legal lake.
    if [ ! -r "$raw_dir" ]; then
      echo "validate-model-usage-emit: CANNOT EVALUATE — $raw_dir exists but is not readable" >&2
      exit 1
    fi
    for f in "$raw_dir"/model-usage-*.jsonl; do
      [ -e "$f" ] || continue
      # advisory A4: skip a DIRECTORY that happens to match the glob (`-e`
      # alone is true for a directory too) — treat only regular files as
      # scannable lines to read, or the per-line read loop below reads a
      # directory as its input source and, under `set -u`, can dereference
      # an unset `line` before the read loop's first successful assignment.
      [ -f "$f" ] || continue
      files+=("$f")
    done
  fi
fi

# Absent/empty stream is LEGAL — no spawn site is wired yet (see GATE SCOPE).
# This still respects $fail from the presence-lint above: a missing/
# non-executable emit-model-usage.sh must FAIL even when there is nothing to
# content-validate — an empty lake never masks a broken presence check.
if [ "${#files[@]}" -eq 0 ]; then
  echo "ok    no model-usage-*.jsonl records found — legal (no spawn site wired yet, temperloop#1255)"
  echo "---"
  if [ "$fail" -ne 0 ]; then
    echo "validate-model-usage-emit: FAIL"
    exit 1
  fi
  echo "validate-model-usage-emit: OK"
  exit 0
fi

# ---------------------------------------------------------------------------
# The committed provider allowlist (ADR 0028), resolved ONCE, reused for
# every record. `pa_is_allowed` is the exact function validate-provider-
# disclosure.sh's own membership check uses — no independent re-parsing.
# ---------------------------------------------------------------------------
committed_providers="$(pa_committed_list 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# 3+4+5. Per-line: strict parse, then shape + enum + no-host checks.
# The heavy lifting is one python3 process per line (schema, not JSON
# validity per se — that is checked first via json.loads with parse_constant
# rejecting non-finite constants). Provider-allowlist membership is checked
# in bash (pa_is_allowed) since that function is bash-native; python reports
# everything else and prints one PASS/FAIL verdict line python parses.
# ---------------------------------------------------------------------------
validate_record_py() {
  # $1 = the raw JSON line. Prints "OK" or "FAIL <reason>" on stdout.
  python3 - "$1" <<'PYEOF'
import json, sys

line = sys.argv[1]

def reject_nonfinite(x):
    raise ValueError("non-finite JSON constant: " + x)

try:
    rec = json.loads(line, parse_constant=reject_nonfinite)
except Exception as e:
    print("FAIL STRICT-PARSE: " + str(e))
    sys.exit(0)

if not isinstance(rec, dict):
    print("FAIL SHAPE: top-level record is not a JSON object")
    sys.exit(0)

required = ["schema_version", "ts", "session_id", "repo", "seat", "model",
            "provider", "usage_source", "tokens", "weighted_units",
            "duration_ms", "outcome_ref"]
missing = [k for k in required if k not in rec]
if missing:
    print("FAIL SHAPE: missing required field(s): " + ", ".join(missing))
    sys.exit(0)

if "host" in rec:
    print("FAIL NO-HOST: record carries a 'host' field — ADR 0028 forbids a "
          "cross-repo operator/machine identifier on this stream")
    sys.exit(0)

# BLOCKING 2: CLOSED schema, not a one-key denylist. The `host` check above
# has its own specific, ADR-0028-quoting message and stays first so that
# named case keeps its named reason — but `host` is not the only possible
# cross-repo identifier a future copy-paste could introduce (`hostname`,
# `operator`, `machine_id`, ...). Reject ANY field outside the required set,
# by name, generically, rather than enumerating denylist entries one at a
# time forever.
extra = sorted(k for k in rec if k not in required)
if extra:
    print("FAIL SCHEMA-CLOSED: unexpected field(s) not in the required schema: "
          + ", ".join(extra))
    sys.exit(0)

if rec["schema_version"] != "1":
    print("FAIL SHAPE: schema_version must be the string \"1\", got " + repr(rec["schema_version"]))
    sys.exit(0)

if not isinstance(rec["ts"], str) or not rec["ts"].endswith("Z") or "T" not in rec["ts"]:
    print("FAIL SHAPE: ts must be an ISO-8601 UTC string with a Z suffix, got " + repr(rec["ts"]))
    sys.exit(0)

if rec["session_id"] is not None and not isinstance(rec["session_id"], str):
    print("FAIL SHAPE: session_id must be a string or null")
    sys.exit(0)

if rec["repo"] is not None and not isinstance(rec["repo"], str):
    print("FAIL SHAPE: repo must be a string or null")
    sys.exit(0)

if not isinstance(rec["seat"], str) or rec["seat"].strip() == "":
    print("FAIL SHAPE: seat must be a non-empty string")
    sys.exit(0)

model = rec["model"]
if not isinstance(model, str) or model.strip() == "":
    print("FAIL SHAPE: model must be a non-empty string")
    sys.exit(0)

# CONTENT-LEVEL model-family enum: the family token (opus/sonnet/haiku) is
# the stable, enumerable part of a Claude model id; the numeric suffix revs
# too often to enumerate exhaustively. Real ids observed in this repo's own
# build.config.sh: claude-sonnet-5, claude-opus-4-8, claude-haiku-4-5.
KNOWN_FAMILIES = ("opus", "sonnet", "haiku")
segments = model.split("-")
if segments[0] != "claude" or not any(seg in KNOWN_FAMILIES for seg in segments[1:]):
    print("FAIL MODEL-ENUM: model '" + model + "' does not name a known Claude "
          "family (" + "/".join(KNOWN_FAMILIES) + ") — want a claude-<family>-... id")
    sys.exit(0)

usage_source = rec["usage_source"]
if usage_source not in ("cli-envelope", "unavailable"):
    print("FAIL SHAPE: usage_source must be 'cli-envelope' or 'unavailable', got " + repr(usage_source))
    sys.exit(0)

provider = rec["provider"]
tokens = rec["tokens"]
weighted_units = rec["weighted_units"]

if usage_source == "cli-envelope":
    if provider is None or not isinstance(provider, str) or provider.strip() == "":
        print("FAIL SHAPE: usage_source is cli-envelope but provider is null/empty")
        sys.exit(0)
    if not isinstance(tokens, dict):
        print("FAIL SHAPE: usage_source is cli-envelope but tokens is not an object")
        sys.exit(0)
    for k in ("input", "output", "cache_read", "cache_creation"):
        if k not in tokens:
            print("FAIL SHAPE: tokens is missing '" + k + "'")
            sys.exit(0)
        v = tokens[k]
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            print("FAIL SHAPE: tokens." + k + " must be a non-negative integer, got " + repr(v))
            sys.exit(0)
    if weighted_units is not None:
        if isinstance(weighted_units, bool) or not isinstance(weighted_units, int) or weighted_units < 0:
            print("FAIL SHAPE: weighted_units must be a non-negative integer or null, got " + repr(weighted_units))
            sys.exit(0)
    # Emit "OK-PROVIDER <provider>" so the bash wrapper can content-check the
    # provider against the ADR 0028 committed allowlist (bash-native check).
    print("OK-PROVIDER " + provider)
    sys.exit(0)
else:
    if provider is not None:
        print("FAIL SHAPE: usage_source is unavailable but provider is not null")
        sys.exit(0)
    if tokens is not None:
        print("FAIL SHAPE: usage_source is unavailable but tokens is not null")
        sys.exit(0)
    if weighted_units is not None:
        print("FAIL SHAPE: usage_source is unavailable but weighted_units is not null")
        sys.exit(0)

duration_ms = rec["duration_ms"]
if duration_ms is not None:
    if isinstance(duration_ms, bool) or not isinstance(duration_ms, int) or duration_ms < 0:
        print("FAIL SHAPE: duration_ms must be a non-negative integer or null, got " + repr(duration_ms))
        sys.exit(0)

outcome_ref = rec["outcome_ref"]
import re
if not isinstance(outcome_ref, str) or not re.match(r'^(issue|pr):\S+$', outcome_ref):
    print("FAIL SHAPE: outcome_ref must match '(issue|pr):<ref>', got " + repr(outcome_ref))
    sys.exit(0)

print("OK")
PYEOF
}

n_records=0
n_files=0
# advisory A4 (bash-3.2 empty-array trap): "${files[@]}" on a genuinely empty
# array can itself trip `set -u` on old bash. Unreachable today because the
# empty-files case above already exits before this loop — but this stays
# correct even if that guard is ever refactored out from under it.
for f in ${files[@]+"${files[@]}"}; do
  n_files=$((n_files + 1))
  if [ "$f" = "-" ]; then
    src="/dev/stdin"
    # BLOCKING 3 (the stdin half): `-r` on a CLOSED stdin correctly reads
    # false (its backing /dev/fd/0 entry is gone), so this catches the
    # closed-stdin case the old code missed entirely (it only ever checked
    # readability for the != "-" branch).
    if [ ! -r "$src" ]; then
      echo "validate-model-usage-emit: CANNOT EVALUATE — stdin (--file -) is not readable (closed?)" >&2
      exit 1
    fi
  else
    src="$f"
    if [ ! -r "$f" ]; then
      echo "validate-model-usage-emit: CANNOT EVALUATE — $f exists but is not readable" >&2
      exit 1
    fi
  fi
  # BLOCKING 3 (the redirect half): the `-r` test above is a point-in-time
  # check, not proof the redirect itself will succeed (a container-mounted
  # dir can pass `-r` on the dir yet still fail to open a specific entry, and
  # `-r` on a symlink doesn't guarantee its target opens). Actually open the
  # fd and check ITS exit status — `done < "$src"` alone never surfaced this:
  # a failed redirect on a `while` loop still enters the loop with `read`
  # immediately returning EOF, so it silently "succeeds" at 0 records read.
  if ! exec 3< "$src" 2>/dev/null; then
    if [ "$f" = "-" ]; then
      echo "validate-model-usage-emit: CANNOT EVALUATE — could not open stdin for reading" >&2
    else
      echo "validate-model-usage-emit: CANNOT EVALUATE — could not open $f for reading" >&2
    fi
    exit 1
  fi
  lineno=0
  # advisory A4 (set -u crash): initialise `line` before the loop so a `read`
  # that fails before its first successful assignment (e.g. an immediately
  # empty/EOF fd) doesn't dereference an unset variable in the `|| [ -n
  # "$line" ]` arm under `set -u` — that used to dump a raw bash "unbound
  # variable" trace instead of the promised CANNOT EVALUATE / clean handling.
  line=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ -z "$line" ] && continue
    n_records=$((n_records + 1))
    verdict="$(validate_record_py "$line")"
    case "$verdict" in
      OK)
        : ;;
      OK-PROVIDER\ *)
        prov="${verdict#OK-PROVIDER }"
        if ! pa_is_allowed "$prov" 2>/dev/null; then
          echo "FAIL  $f:$lineno — PROVIDER-ENUM: provider '$prov' is not in the ADR 0028 committed allowlist (${committed_providers:-<none>})"
          fail=1
        fi
        ;;
      FAIL*)
        echo "FAIL  $f:$lineno — ${verdict#FAIL }"
        fail=1
        ;;
      *)
        echo "FAIL  $f:$lineno — validator produced no verdict (got: $verdict)"
        fail=1
        ;;
    esac
  done <&3
  exec 3<&-
done

echo "Checked $n_files file(s), $n_records record(s)."

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-model-usage-emit: FAIL"
  exit 1
fi
echo "validate-model-usage-emit: OK"
