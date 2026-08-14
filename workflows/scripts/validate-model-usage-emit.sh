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
#   6. SPAWN-SITE COVERAGE (temperloop#1255) — proving that every emit-feasible
#      seat the L0 spike named actually calls emit-model-usage.sh (via the
#      shared workflows/scripts/lib/model-usage-envelope.sh extraction), and
#      that the un-emittable seats are named here with the spike's own
#      reason rather than silently absent. Two layers:
#        a. NAMED PER-SEAT WIRING — a direct check, mirroring
#           validate-issue-touch-emit.sh's check_kind_wiring: for each of A7
#           (pipeline-drive.sh safe-tier spawn), A8 (pipeline-drive.sh
#           merge-tier spawn), A9 (pipeline-retro-judge-spawn.sh), grep a
#           context window after the literal spawn call for a
#           model_usage_emit_from_envelope call naming that seat. Comment-only
#           lines are stripped BEFORE matching, so a string surviving only in
#           a comment after the real call is deleted does not pass.
#        b. GENERIC FORWARD NET — every *.sh file directly under
#           workflows/scripts/build/ (the scan dir; overridable via
#           --scan-dir for fixture tests) that captures a
#           `--output-format json` envelope on a non-comment line must ALSO
#           call model_usage_emit_from_envelope somewhere in that same file.
#           This is what makes "a newly added spawn site with no emission
#           fails the gate" mechanical: a brand-new file introducing its own
#           captured-envelope spawn is caught by NAME (it need not be
#           enumerated), not merely the two files (a) already knows about.
#      GATE SCOPE stays the emit-feasible subset ONLY (A7/A8/A9 today) — an
#      un-emittable seat (the A1-A6/A2/B1/B2/C1-C3 exclusion list this script
#      also prints) never participates in either coverage layer, so it can
#      never accidentally fail this gate.
#
# An EMPTY or ABSENT raw-lake stream is still LEGAL for the CONTENT checks
# above (1-5) — a fresh checkout that has never run the pipeline has nothing
# to scan yet, exactly like validate-provider-disclosure.sh's own
# "absent/empty disclosure log is legal" precedent. Coverage (6) is a
# SEPARATE, always-on check of the WIRING ITSELF (source code, not the lake)
# and runs regardless of whether the lake happens to be empty.
#
# Usage:
#   workflows/scripts/validate-model-usage-emit.sh
#     (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh;
#     resolves the repo itself and scans $MODEL_USAGE_RAW_DIR, default
#     <repo>/meta/data/raw)
#   workflows/scripts/validate-model-usage-emit.sh --file <path>
#     CONTENT-ONLY mode: validate exactly one JSONL file (or "-" for stdin)
#     instead of scanning the raw lake, and SKIP spawn-site coverage (6)
#     entirely — the fixture-test seam test_model_usage_emit.sh's many
#     single-record checks use this, pointed at throwaway fixture trees with
#     no build/ directory beside them at all; coverage has nothing to do
#     with one record's schema. --scan-dir is ignored when --file is given.
#   workflows/scripts/validate-model-usage-emit.sh --scan-dir <dir>
#     run the spawn-site coverage checks (6) against <dir> instead of the
#     real workflows/scripts/build/ (content checks 1-5 still run against
#     the real raw lake as usual) — the fixture-test seam a coverage
#     mutation test uses to tamper a COPY of the production files without
#     touching the real checkout.
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
scan_dir_override=""
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
    --scan-dir)
      # Same ARG-ARITY GUARD shape as --file above (BLOCKING 1 class).
      if [ $# -lt 2 ]; then
        echo "validate-model-usage-emit: CANNOT EVALUATE — --scan-dir requires a value" >&2
        exit 1
      fi
      case "$2" in
        --*)
          echo "validate-model-usage-emit: CANNOT EVALUATE — --scan-dir requires a value, got flag-like '$2'" >&2
          exit 1
          ;;
      esac
      scan_dir_override="$2"; shift 2 ;;
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

# Absent/empty stream is LEGAL (see GATE SCOPE) — a fresh checkout that has
# never run the pipeline has nothing to scan yet. This still respects $fail
# from the presence-lint above: a missing/non-executable emit-model-usage.sh
# must FAIL even when there is nothing to content-validate — an empty lake
# never masks a broken presence check. Unlike before temperloop#1255, this no
# longer exits here: check 6 (spawn-site coverage, below) is a SEPARATE
# check of the wiring itself and must still run even when the lake is empty.
if [ "${#files[@]}" -eq 0 ]; then
  echo "ok    no model-usage-*.jsonl records found — legal on a fresh/quiet lake"
else

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
  # Scoped command group — NOT a bare `exec 3<... 2>/dev/null`. A bare `exec`
  # with no command word applies ALL its redirects PERMANENTLY to the current
  # shell once the open succeeds, which would silently redirect this script's
  # own stderr to /dev/null for the rest of the run and swallow every later
  # diagnostic (temperloop#1370). Wrapping in a `{ }` command group scopes the
  # `2>/dev/null` to just this open attempt (bash saves/restores the group's
  # fds), while `exec 3<...` inside it still opens fd 3 in the CURRENT shell
  # (no subshell), so the descriptor survives for the read loop below exactly
  # as intended. Same idiom as workflows/scripts/model-comparison/tagging.sh.
  if ! { exec 3< "$src"; } 2>/dev/null; then
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
fi   # end: files non-empty branch (content-level checks 2-5)

# ---------------------------------------------------------------------------
# 6. SPAWN-SITE COVERAGE (temperloop#1255) — see the header's "GATE SCOPE"
# item 6 for the full design rationale. Runs whenever this is a WHOLE-GATE
# invocation (no --file) — independent of whether the raw lake above was
# empty, since this checks the WIRING (source code), not the lake. SKIPPED
# when --file is given: --file is the CONTENT-ONLY fixture-test seam (one
# JSONL record's schema in isolation), and its many callers point this
# script at throwaway fixture trees with no build/ directory beside them at
# all — coverage has nothing to do with a single record's schema and must
# not fail those invocations for an unrelated reason. A dedicated coverage
# fixture test drives coverage via --scan-dir instead (never --file).
# ---------------------------------------------------------------------------
if [ -n "$single_file" ]; then
  echo "---"
  if [ "$fail" -ne 0 ]; then
    echo "validate-model-usage-emit: FAIL"
    exit 1
  fi
  echo "validate-model-usage-emit: OK"
  exit 0
fi

# ---- 6a. the exclusion list — named, never silently skipped ---------------
# Every seat the L0 spike (Context/temperloop - per-seat usage capture
# feasibility.md) marked STRUCTURALLY UN-EMITTABLE, with the spike's own
# reason, verbatim. This is documentation output (never toggles $fail) — its
# job is to make the exclusion visible on every run, not to assert anything
# mechanically checkable about code that, by construction, has no shell seam
# to check.
echo "── spawn-site coverage: the un-emittable exclusion list (never silently skipped) ──"
echo "excluded A1 (/build 3c per-item worker, build-level.mjs): .mjs agent() returns no usage; harness drops the label; no legal join key"
echo "excluded A2 (/sweep Phase-1 detection fan-out): harness-native Task fan-out from command prose; no shell seam, no usage return"
echo "excluded A3 (/sweep Phase-2 fix worker, build-level.mjs): .mjs agent() returns no usage; harness drops the label; no legal join key"
echo "excluded A4 (/fix Step-4 single-issue worker, build-level.mjs): .mjs agent() returns no usage; harness drops the label; no legal join key"
echo "excluded A5 (build-level.mjs runMachinery): same as A1/A3/A4, and additionally the file is documented as unable to source shell config"
echo "excluded A6 (build-level.mjs runMachineryBatch): same as A1/A3/A4, and additionally the file is documented as unable to source shell config"
echo "excluded B1 (interactive command sessions: /build /assess /triage /workshop /sweep /fix /check-in /next /tidy): not spawned by this repo at all; SessionEnd gives session-granularity only, with no seat name and no outcome ref"
echo "excluded B2 (claude/agents/** reviewer/lens/persona seats): harness-native agent-frontmatter spawn; no kernel code in the spawn path"
echo "excluded C1 (try.sh Step-3 shadow triage): no captured envelope (--output-format text), tracked as temperloop#1264"
echo "excluded C2 (try.sh --demo fix call): no captured envelope (--output-format text), tracked as temperloop#1264"
echo "excluded C3 (configure.sh AI-guided suggestion): no captured envelope (--output-format text), tracked as temperloop#1264"

# ---- 6b. resolve the scan dir ----------------------------------------------
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
if [ -n "$scan_dir_override" ]; then
  scan_dir="$scan_dir_override"
elif [ -n "$REPO_ROOT" ]; then
  scan_dir="$REPO_ROOT/workflows/scripts/build"
else
  echo "validate-model-usage-emit: CANNOT EVALUATE — cannot resolve the repo root above $SCRIPT_DIR for spawn-site coverage, and --scan-dir was not given" >&2
  exit 1
fi
if [ ! -d "$scan_dir" ]; then
  echo "validate-model-usage-emit: CANNOT EVALUATE — spawn-site coverage scan dir does not exist: $scan_dir" >&2
  exit 1
fi
if [ ! -r "$scan_dir" ]; then
  echo "validate-model-usage-emit: CANNOT EVALUATE — spawn-site coverage scan dir is not readable: $scan_dir" >&2
  exit 1
fi
PIPELINE_DRIVE_SH="$scan_dir/pipeline-drive.sh"
RETRO_JUDGE_SPAWN_SH="$scan_dir/pipeline-retro-judge-spawn.sh"

# ---- 6c. layer (a): named per-seat wiring, mirroring validate-issue-touch- -
# emit.sh's check_kind_wiring. $1=file $2=label $3=literal anchor (the spawn
# call itself) $4=literal expected nearby call (the emission).
check_seat_wiring() {
  local file="$1" label="$2" anchor="$3" expect="$4"
  if [ ! -f "$file" ]; then
    echo "FAIL  spawn-site coverage: $label — expected file is missing: $file"
    fail=1
    return
  fi
  if [ ! -r "$file" ]; then
    echo "validate-model-usage-emit: CANNOT EVALUATE — spawn-site coverage cannot read $file" >&2
    exit 1
  fi
  # Strip comment-only lines FIRST — a string surviving only in a comment
  # after the real call was deleted must NOT count as wired (the recurring
  # "grepped a string that lives in a comment" trap this item's own testing
  # bar names).
  local code anchor_block
  code="$(grep -v '^[[:space:]]*#' "$file" 2>/dev/null || true)"
  anchor_block="$(printf '%s\n' "$code" | grep -A6 -F -- "$anchor" || true)"
  if [ -z "$anchor_block" ]; then
    echo "FAIL  spawn-site coverage: $label — spawn call not found in $file (expected: $anchor) — has the spawn site moved or been removed?"
    fail=1
    return
  fi
  if ! grep -F -q -- "$expect" <<<"$anchor_block"; then
    echo "FAIL  spawn-site coverage: $label ($file) spawns a captured envelope but the nearby emission call is missing (expected: $expect)"
    fail=1
    return
  fi
  echo "ok    spawn-site coverage: $label wires $expect"
}

echo "── spawn-site coverage: named per-seat wiring (A7/A8/A9) ──"
# Every anchor/expect pair below is a LITERAL string to grep for in ANOTHER
# file (pipeline-drive.sh / pipeline-retro-judge-spawn.sh) — deliberately
# single-quoted so $co/$pf/$board etc. are never expanded HERE; they must
# stay as literal text matching that other file's own source.
# shellcheck disable=SC2016
check_seat_wiring "$PIPELINE_DRIVE_SH" "A7 pipeline-drive.sh safe-tier driver" \
  '_spawn_in_checkout "$co" 1 "/pipeline-drive $pf"' \
  'model_usage_emit_from_envelope "pipeline-drive-safe"'
# shellcheck disable=SC2016
check_seat_wiring "$PIPELINE_DRIVE_SH" "A8 pipeline-drive.sh merge-tier driver" \
  '_spawn_in_checkout "$co" 1 "/pipeline-drive-merge $pf"' \
  'model_usage_emit_from_envelope "pipeline-drive-merge"'
# shellcheck disable=SC2016
check_seat_wiring "$RETRO_JUDGE_SPAWN_SH" "A9 retro-judge spawn" \
  '"$CLAUDE_BIN" -p "/retro --pending --board $board" --model "$model" --output-format json' \
  'model_usage_emit_from_envelope "retro-judge"'

# ---- 6d. layer (b): the generic forward net --------------------------------
# ANY *.sh file directly under $scan_dir (maxdepth 1 — deliberately excludes
# tests/ fixtures/ lib/ subdirs, which can legitimately carry the literal
# string in fixture data or doc comments without being a real spawn site)
# that captures a `--output-format json` envelope on a non-comment line MUST
# also call model_usage_emit_from_envelope somewhere in that same file. This
# is what makes "a newly added spawn site with no emission fails the gate"
# mechanical rather than remembered: a brand-new file is caught by NAME (the
# literal signature), never requiring this validator to have been told about
# it in advance.
echo "── spawn-site coverage: generic net for any FUTURE captured-envelope spawn site ──"
generic_hit=0
for f in "$scan_dir"/*.sh; do
  [ -e "$f" ] || continue
  [ -f "$f" ] || continue
  if [ ! -r "$f" ]; then
    echo "validate-model-usage-emit: CANNOT EVALUATE — spawn-site coverage cannot read $f" >&2
    exit 1
  fi
  code="$(grep -v '^[[:space:]]*#' "$f" 2>/dev/null || true)"
  # `grep -F ... >/dev/null` (never `-Fq`) piped from a writer — a piped `-q`
  # exits at its first match, SIGPIPEing the upstream writer nondeterministically
  # under pipefail (temperloop#1050; scripts/lint-pipe-grep-q.sh enforces this).
  if printf '%s\n' "$code" | grep -F -- '--output-format json' >/dev/null; then
    # Comment-stripped $code again here (never the raw $f) — a
    # model_usage_emit_from_envelope mention surviving only in a comment
    # after the real call was deleted must NOT count as wired (same trap
    # check_seat_wiring's anchor_block guards against above).
    if ! printf '%s\n' "$code" | grep -F -- 'model_usage_emit_from_envelope' >/dev/null; then
      echo "FAIL  spawn-site coverage: $f captures a claude -p --output-format json envelope but never calls model_usage_emit_from_envelope anywhere in the file — an unwired spawn site"
      fail=1
      generic_hit=1
    fi
  fi
done
if [ "$generic_hit" -eq 0 ]; then
  echo "ok    spawn-site coverage: every --output-format json capture site directly under $scan_dir wires model_usage_emit_from_envelope somewhere in its own file"
fi

echo "---"
if [ "$fail" -ne 0 ]; then
  echo "validate-model-usage-emit: FAIL"
  exit 1
fi
echo "validate-model-usage-emit: OK"
