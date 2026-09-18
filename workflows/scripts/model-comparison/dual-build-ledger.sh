#!/usr/bin/env bash
#
# dual-build-ledger.sh — append-only row ledger + per-arm patch archive
# library for the dual-build harness (temperloop#2072, epic #2065 "new-work
# dual-build harness"). See [[Decisions/temperloop - model comparison harness
# (design ratified)]] and the epic's Contract item #5.
#
# ── WHAT THIS OWNS ──────────────────────────────────────────────────────────
# One append-only `rows.jsonl` (one row per item per arm — tier, model,
# base/head sha, gate result, cost, judge verdict, level pick, override,
# loss reason, cross-read/guard state, operator/host, a monotonic `seq`) plus
# one `git format-patch`-shaped archive per (slug, arm) under
# `.temperloop/model-comparison/dual-build/archives/`. Both live in the
# already-gitignored `.temperloop/model-comparison/` tree (see
# `.temperloop/.gitignore`'s `model-comparison/` line) — never git-tracked,
# single-host scope, declared (no cross-host reconciliation).
#
# This script does NOT drive builds, judge diffs, or delete git branches —
# those are `build-level.mjs` / `judge.sh` concerns (sibling epic items). It
# is a pure data-plane library: write a row, read them back with a
# consistency check, save/inspect a patch archive, and reclaim disk.
#
# ── ROW SCHEMA (schema_version 1) ───────────────────────────────────────────
#   schema_version, seq, created_at,
#   tier, model, slug, arm ∈ {baseline,candidate},
#   base_sha, head_sha, start_order, gate ∈ {pass,fail},
#   cost { tokens_in, tokens_out, wall_clock_ms, retry_tokens, retry_count,
#          recovery },
#   judge (null | { preference, margin, order_agreement }),
#   pick  (null | { arm, reason }),
#   override { applied, scope, reason },
#   loss_reason ∈ {gate,judge,infra,incomplete,null},
#   cross_read_attempted, guard_armed ∈ {ARMED,UNARMED,UNKNOWN},
#   machinery_version, operator, host
#
# `machinery_version` rides every row — not itself a dual-build field, but
# kept per the epic Contract's "Supersedes D12 (K#1924 piggyback) ... rows
# keep K#1924's key fields so the two can be joined later" clause (K#1924's
# per-step resume ledger keys on slug/head_sha/base_sha/machinery_version). A
# machinery-version bump between two appends is legal and non-destructive —
# each row is self-describing, immutable once written, and a later bump never
# rewrites an earlier row's value (see `test_dual_build_ledger.sh` § the
# machinery_version-bump fixture).
#
# `schema_version` and `seq` are ASSIGNED BY THIS SCRIPT, never accepted from
# a caller — `append`'s caller payload must not (and need not) supply them.
#
# ── EXPECTED-COUNT CHECK (temperloop#2072 acceptance) ───────────────────────
# `read` always self-checks: every seq in 1..max(seq) must appear exactly
# once, and every line must parse. A caller that additionally knows how many
# rows it expects (e.g. a level's in-scope item count) can pass `--expect N`
# for a second, caller-scoped check. Either failure prints "records missing"
# on stderr and exits non-zero — the read never silently returns a truncated
# array as if it were complete.
#
# ── NAMED-SETTING CONVENTION ─────────────────────────────────────────────────
# `DUAL_BUILD_ARCHIVE_RETENTION_DAYS` is declared (name + default) by the
# sibling `dual-build-settings` item (temperloop#2071) in
# `workflows/scripts/build/build.config.sh` — this script only ever
# REFERENCES it symbolically (a bare `${NAME:-}` read, never a `${NAME:=...}`
# / `${NAME:-<value>}` default-assignment seam), so it carries no local
# default of its own for check-setting-registry.sh's UNREGISTERED scan to
# flag or drift from. `prune` refuses cleanly if neither `--retention-days`
# nor the setting is available — see `cmd_prune`.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   dual-build-ledger.sh append --row '<json>'|- [--dir DIR]
#   dual-build-ledger.sh read [--dir DIR] [--expect N]
#   dual-build-ledger.sh archive <slug> <arm> --from <patch-file>|- [--dir DIR]
#   dual-build-ledger.sh archive-check <slug> <arm> [--base SHA] [--repo PATH] [--dir DIR]
#   dual-build-ledger.sh purge [--dir DIR] [--yes]
#   dual-build-ledger.sh prune [--dir DIR] [--retention-days N] [--apply]
#
# `--dir` (or env `DUAL_BUILD_LEDGER_DIR`) overrides the ledger root; default
# is `<repo-root>/.temperloop/model-comparison/dual-build`, `<repo-root>`
# derived from this script's own on-disk location (same convention as the
# sibling `lake-sweep.sh`'s `MODEL_USAGE_RAW_DIR`/`REPO_ROOT` derivation).
#
# Exit 0 on success. `read`/`archive-check` exit non-zero on a real negative
# verdict (records missing / patch does not apply) as well as on usage error.
#
# `set -e` posture: deliberately OMITTED, not forgotten. Every mutating call
# is followed by an explicit `|| die` (or, where the exit status itself is
# meaningful rather than just pass/fail, an explicit `rc=$?` capture right
# after the assignment — see `_validate_row`'s caller and `_lock_acquire`'s
# use). Preserve that invariant in any new code path: a bare command whose
# failure matters needs its own `|| die`/`rc=$?`, since `-e` will not do it.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../../.." && pwd)"

BUILD_CONFIG="${BUILD_CONFIG:-$REPO_ROOT/workflows/scripts/build/build.config.sh}"  # setting:exempt — fixture-isolation override point (lets a test point this at an absent path to assert the genuinely-unconfigured-environment refusal, independent of what build.config.sh happens to declare); not a project-configurable setting
# shellcheck source=../build/build.config.sh
[ -f "$BUILD_CONFIG" ] && . "$BUILD_CONFIG"

SCHEMA_VERSION=1
ROWS_FILE_NAME="rows.jsonl"
ARCHIVES_SUBDIR="archives"
LEDGER_DIR="${DUAL_BUILD_LEDGER_DIR:-$REPO_ROOT/.temperloop/model-comparison/dual-build}"

die() { echo "dual-build-ledger.sh: $1" >&2; exit 1; }

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v git >/dev/null 2>&1 || die "git not found"

_operator_default() { echo "${USER:-${LOGNAME:-unknown}}"; }  # setting:exempt — OS-identity passthrough (who is running this process), not a project-configurable override point
_host_default() { hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown; }

# GNU stat (Linux CI) vs BSD stat (macOS) — guarded capture, GNU first, each
# branch emitting ONLY on a non-empty success (#1024's own "check the
# platform's dialect" lesson: neither flag set is universal). A bare
# `stat -f %m X || stat -c %Y X` fallback chain is NOT safe: on GNU
# coreutils, `-f` means `--file-system`, so `%m` is parsed as a FILE operand
# — stat exits 1 but still prints a multi-line filesystem blob to stdout,
# so the captured value becomes that blob concatenated with the real epoch
# from the `||` branch. Same guarded-capture idiom as
# workflows/scripts/build/env-reconcile.sh's `file_mtime` and
# workflows/scripts/install/doctor.sh's `_doctor_stat_mtime`.
_mtime_epoch() {
  local m
  if m="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  if m="$(stat -f %m "$1" 2>/dev/null)" && [ -n "$m" ]; then printf '%s\n' "$m"; return 0; fi
  return 1
}

# _ledger_max_seq <rows-file> — highest well-formed `.seq` seen, 0 if none/absent.
# Malformed lines and lines with a non-integer/absent seq are silently
# skipped here (they are read.sh's job to flag, not append's) so a corrupt
# tail never blocks new appends from getting a correct next seq.
_ledger_max_seq() {
  local file="$1" max=0 line s
  [ -f "$file" ] || { echo 0; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    s="$(jq -r '.seq // empty' <<<"$line" 2>/dev/null)" || continue
    case "$s" in ''|*[!0-9]*) continue ;; esac
    [ "$s" -gt "$max" ] && max="$s"
  done <"$file"
  echo "$max"
}

# Single-host, mkdir-based spinlock (atomic mkdir, portable — no flock(1)
# dependency, which util-linux ships but macOS does not). Bounds two
# concurrent arms' appends racing the same rows.jsonl (single-host scope,
# declared — no cross-host coordination attempted).
_lock_acquire() {
  local dir="$1" lockdir="$1/.append.lock" tries=0
  mkdir -p "$dir" || return 1
  while ! mkdir "$lockdir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || { echo "dual-build-ledger.sh: could not acquire append lock at $lockdir after $tries tries" >&2; return 1; }
    sleep 0.05
  done
  return 0
}
_lock_release() { rmdir "$1/.append.lock" 2>/dev/null || true; }

# _validate_row — reads the candidate row JSON on stdin, prints an error
# string (empty on success). Presence-of-key + closed-enum checks only; the
# nested cost/judge/pick/override shapes are checked for the sub-keys the
# schema requires, not exhaustively typed, matching this repo's existing
# model-comparison validators' presence-plus-enum depth (validate-model-
# usage-emit.sh is the deeper, dedicated content validator for its own
# stream; this one row-shape is simple enough not to need a second script).
_validate_row() {
  # NOTE: every `as $name` binding lives in the PIPELINE, before the single
  # if/elif chain — jq does not allow `expr as $x | ...` inline inside an
  # elif condition (a real compile error this function used to hit
  # silently: the compile failure made `jq` exit non-zero with empty
  # stdout, which the caller read as "no error string" — i.e. validation
  # vacuously PASSED every row. See test_dual_build_ledger.sh's own
  # regression case for this exact failure mode.)
  jq -r '
    . as $r
    | (if ($r | type) == "object" then $r else {} end) as $ro
    | (["tier","model","slug","arm","base_sha","head_sha","start_order","gate",
        "cost","judge","pick","override","cross_read_attempted","guard_armed",
        "machinery_version"]
       # `. as $k | ($ro | has($k))`, NOT `($ro | has(.))` — piping $ro into
       # `has(.)` reassigns `.` to $ro for the ARGUMENT too, so `has(.)` would
       # ask "does $ro have itself as a key" instead of testing the mapped
       # array element. Binding $k first keeps the element independent of the
       # `.` the `has` call rebinds.
       | map(select(. as $k | ($ro | has($k)) | not))) as $missing
    | (if ($ro | has("cost")) and (($ro.cost // null) | type) == "object"
       then (["tokens_in","tokens_out","wall_clock_ms","retry_tokens","retry_count","recovery"]
             | map(select(. as $k | ($ro.cost | has($k)) | not)))
       else [] end) as $cost_missing
    | if ($r | type) != "object" then "row must be a JSON object"
      elif ($missing | length) > 0 then "missing required field(s): " + ($missing | join(", "))
      elif ($r.arm != "baseline" and $r.arm != "candidate") then "arm must be \"baseline\" or \"candidate\""
      elif ($r.gate != "pass" and $r.gate != "fail") then "gate must be \"pass\" or \"fail\""
      elif ($r.guard_armed != "ARMED" and $r.guard_armed != "UNARMED" and $r.guard_armed != "UNKNOWN") then "guard_armed must be ARMED, UNARMED or UNKNOWN"
      elif (($r.loss_reason // null) != null and (["gate","judge","infra","incomplete"] | index($r.loss_reason)) == null) then "loss_reason must be gate, judge, infra, incomplete or null"
      elif (($r.slug | type) != "string" or ($r.slug | length) == 0) then "slug must be a non-empty string"
      elif (($r.slug | type) == "string" and (($r.slug | test("^[A-Za-z0-9._-]+$")) | not)) then "slug must match [A-Za-z0-9._-]+ (it becomes a filesystem path component)"
      elif (($r.base_sha | type) != "string" or ($r.base_sha | length) == 0) then "base_sha must be a non-empty string"
      elif (($r.head_sha | type) != "string" or ($r.head_sha | length) == 0) then "head_sha must be a non-empty string"
      elif (($r.machinery_version | type) != "string" or ($r.machinery_version | length) == 0) then "machinery_version must be a non-empty string"
      elif ($r.start_order | type) != "number" then "start_order must be a number"
      elif ($r.cost | type) != "object" then "cost must be an object"
      elif ($cost_missing | length) > 0 then "cost missing field(s): " + ($cost_missing | join(", "))
      elif ($r.judge != null and ($r.judge | type) != "object") then "judge must be null or an object"
      elif ($r.pick != null and ($r.pick | type) != "object") then "pick must be null or an object"
      elif ($r.override | type) != "object" then "override must be an object"
      elif (($r.override | has("applied")) | not) then "override must carry an \"applied\" key"
      else empty
      end
  '
}

cmd_append() {
  local dir="$LEDGER_DIR" row_json=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "append: --dir requires a path"; dir="$2"; shift 2 ;;
      --row) [ $# -ge 2 ] || die "append: --row requires a JSON payload (or '-' for stdin)"; row_json="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "append: unknown argument $1" ;;
    esac
  done
  [ -n "$row_json" ] || die "append: --row <json>|- is required"
  [ "$row_json" != "-" ] || row_json="$(cat)"
  jq -e . >/dev/null 2>&1 <<<"$row_json" || die "append: --row is not valid JSON"

  local err rc
  err="$(_validate_row <<<"$row_json")"; rc=$?
  # Fail CLOSED on a validator internal error (a jq compile/runtime failure)
  # rather than reading its empty stdout as "no error" — see the note atop
  # _validate_row for the exact silent-pass regression this guards.
  [ "$rc" -eq 0 ] || die "append: row validator failed internally (rc $rc) — refusing to append an unvalidated row"
  [ -z "$err" ] || die "append: $err"

  mkdir -p "$dir" || die "append: cannot create ledger dir $dir"
  local rows_file="$dir/$ROWS_FILE_NAME"

  _lock_acquire "$dir" || die "append: lock failed"
  # A SIGINT/SIGTERM (or a driver's `timeout`) between acquire and the
  # explicit releases below must not leave `.append.lock` on disk — that
  # would wedge every future append behind the 100x0.05s spin until a
  # manual `rmdir`. Deliberately INT/TERM only, not EXIT: a signal fires
  # while this function is still live on the call stack, so `$dir` is a
  # valid local here — but an EXIT trap set in a function fires at the
  # SCRIPT's eventual exit, by which point (on the normal, non-`exit`
  # return path below) this function has already returned and `$dir` no
  # longer exists, which under `set -u` dies "dir: unbound variable" on
  # every ordinary append. `_lock_release` is idempotent (`|| true`), so
  # this composes harmlessly with the explicit releases below; the
  # trailing `exit 1` reproduces the terminate-on-signal behavior a bare
  # (untrapped) SIGINT/SIGTERM would otherwise have had.
  trap '_lock_release "$dir"; exit 1' INT TERM
  local next_seq max
  max="$(_ledger_max_seq "$rows_file")"
  next_seq=$((max + 1))

  local created_at op host final_row
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  op="$(_operator_default)"
  host="$(_host_default)"

  final_row="$(jq -c --argjson seq "$next_seq" --arg schema_version "$SCHEMA_VERSION" \
    --arg created_at "$created_at" --arg op "$op" --arg host "$host" '
    . as $r
    | {
        schema_version: ($schema_version | tonumber),
        seq: $seq,
        created_at: $created_at,
        tier: $r.tier,
        model: $r.model,
        slug: $r.slug,
        arm: $r.arm,
        base_sha: $r.base_sha,
        head_sha: $r.head_sha,
        start_order: $r.start_order,
        gate: $r.gate,
        cost: $r.cost,
        judge: $r.judge,
        pick: $r.pick,
        override: $r.override,
        loss_reason: ($r.loss_reason // null),
        cross_read_attempted: $r.cross_read_attempted,
        guard_armed: $r.guard_armed,
        machinery_version: $r.machinery_version,
        operator: ($r.operator // $op),
        host: ($r.host // $host)
      }' <<<"$row_json")" || { _lock_release "$dir"; die "append: could not build final row"; }

  printf '%s\n' "$final_row" >>"$rows_file" || { _lock_release "$dir"; die "append: write failed to $rows_file"; }
  _lock_release "$dir"
  printf '%s\n' "$final_row"
}

cmd_read() {
  local dir="$LEDGER_DIR" expect=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "read: --dir requires a path"; dir="$2"; shift 2 ;;
      --expect) [ $# -ge 2 ] || die "read: --expect requires a count"; expect="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "read: unknown argument $1" ;;
    esac
  done
  case "${expect:-0}" in ''|*[!0-9]*) die "read: --expect must be a non-negative integer" ;; esac

  local rows_file="$dir/$ROWS_FILE_NAME"
  if [ ! -f "$rows_file" ]; then
    if [ -n "$expect" ] && [ "$expect" -gt 0 ]; then
      printf 'dual-build-ledger.sh: records missing — no ledger at %s, expected %s record(s)\n' "$rows_file" "$expect" >&2
      exit 1
    fi
    echo "[]"
    exit 0
  fi

  local tmp total_lines=0 malformed=0 max_seq=0 seen_seqs="" line s
  tmp="$(mktemp "${TMPDIR:-/tmp}/dual-build-ledger-read.XXXXXX")" || die "read: mktemp failed"
  # Cleanup via trap, not a duplicated `rm -f "$tmp"` on every exit path.
  # Every path out of this function below calls `exit`, not bare `return` —
  # deliberately: a function-local EXIT trap fires live (locals still in
  # scope) when `exit` is called from inside the function, but fires LATER,
  # after the local has already gone out of scope, if the function instead
  # returns normally and the trap only runs at the whole script's eventual
  # exit — which under `set -u` dies "tmp: unbound variable" on every
  # ordinary read. See cmd_append's `_lock_release` trap note for the same
  # trap-scoping rule from the other direction (INT/TERM there, EXIT here).
  trap 'rm -f "$tmp"' EXIT
  : >"$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    total_lines=$((total_lines + 1))
    if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
      malformed=$((malformed + 1))
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
    s="$(jq -r '.seq // empty' <<<"$line")"
    case "$s" in
      ''|*[!0-9]*) : ;;
      *) [ "$s" -gt "$max_seq" ] && max_seq="$s"; seen_seqs="$seen_seqs $s " ;;
    esac
  done <"$rows_file"

  local valid_count
  valid_count="$(wc -l <"$tmp" | tr -d ' ')"

  local gap=0 i
  if [ "$max_seq" -gt 0 ]; then
    i=1
    while [ "$i" -le "$max_seq" ]; do
      case "$seen_seqs" in *" $i "*) : ;; *) gap=1 ;; esac
      i=$((i + 1))
    done
  fi

  local target="$max_seq"
  [ -z "$expect" ] || target="$expect"

  if [ "$malformed" -gt 0 ] || [ "$gap" -eq 1 ] || [ "$valid_count" -lt "$target" ]; then
    printf 'dual-build-ledger.sh: records missing — %s valid record(s), %s malformed line(s), expected %s (max seq %s) in %s\n' \
      "$valid_count" "$malformed" "$target" "$max_seq" "$rows_file" >&2
    exit 1
  fi

  local rc
  jq -cs 'sort_by(.seq)' <"$tmp"; rc=$?
  exit "$rc"
}

cmd_archive() {
  local dir="$LEDGER_DIR" slug="" arm="" from=""
  if [ $# -ge 2 ]; then
    case "$1" in --*) : ;; *) slug="$1"; shift ;; esac
    if [ -n "$slug" ]; then
      case "$1" in --*) die "archive: usage: archive <slug> <arm> --from <patch-file>|-" ;; *) arm="$1"; shift ;; esac
    fi
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "archive: --dir requires a path"; dir="$2"; shift 2 ;;
      --from) [ $# -ge 2 ] || die "archive: --from requires a path or -"; from="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "archive: unknown argument $1" ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$arm" ] || die "archive: usage: archive <slug> <arm> --from <patch-file>|-"
  case "$slug" in ''|*[!A-Za-z0-9._-]*) die "archive: slug must match [A-Za-z0-9._-]+ (it becomes a filesystem path component)" ;; esac
  case "$arm" in baseline|candidate) : ;; *) die "archive: arm must be baseline or candidate" ;; esac
  [ -n "$from" ] || die "archive: --from <patch-file>|- is required"

  local archdir="$dir/$ARCHIVES_SUBDIR"
  mkdir -p "$archdir" || die "archive: cannot create $archdir"
  local dest="$archdir/${slug}@${arm}.patch"
  if [ "$from" = "-" ]; then
    cat >"$dest" || die "archive: failed writing $dest from stdin"
  else
    [ -f "$from" ] || die "archive: no such patch file $from"
    cp "$from" "$dest" || die "archive: failed copying $from to $dest"
  fi
  jq -cn --arg path "$dest" --arg slug "$slug" --arg arm "$arm" \
    '{outcome:"ARCHIVED", slug:$slug, arm:$arm, path:$path}'
}

cmd_archive_check() {
  local dir="$LEDGER_DIR" slug="" arm="" repo="$REPO_ROOT" base=""
  if [ $# -ge 2 ]; then
    case "$1" in --*) : ;; *) slug="$1"; shift ;; esac
    if [ -n "$slug" ]; then
      case "$1" in --*) die "archive-check: usage: archive-check <slug> <arm> [--base SHA] [--repo PATH]" ;; *) arm="$1"; shift ;; esac
    fi
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "archive-check: --dir requires a path"; dir="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "archive-check: --repo requires a path"; repo="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || die "archive-check: --base requires a sha"; base="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "archive-check: unknown argument $1" ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$arm" ] || die "archive-check: usage: archive-check <slug> <arm> [--base SHA] [--repo PATH]"
  case "$slug" in ''|*[!A-Za-z0-9._-]*) die "archive-check: slug must match [A-Za-z0-9._-]+ (it becomes a filesystem path component)" ;; esac
  local patch="$dir/$ARCHIVES_SUBDIR/${slug}@${arm}.patch"
  [ -f "$patch" ] || die "archive-check: no archived patch at $patch"
  patch="$(cd -P "$(dirname "$patch")" && pwd)/$(basename "$patch")"

  if [ -z "$base" ]; then
    local rows_file="$dir/$ROWS_FILE_NAME"
    if [ -f "$rows_file" ]; then
      base="$(jq -R -r --arg slug "$slug" --arg arm "$arm" '
        (fromjson? // empty) as $r
        | select($r != null and $r.slug == $slug and $r.arm == $arm)
        | $r.base_sha' "$rows_file" 2>/dev/null | tail -n1)"
    fi
  fi
  [ -n "$base" ] || die "archive-check: no base_sha given (--base) and none found in the ledger for $slug@$arm"

  [ -d "$repo" ] || die "archive-check: no repo at $repo"

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dual-build-archive-check.XXXXXX")" || die "archive-check: mktemp -d failed"
  # Trap, not a duplicated `rm -rf "$tmp"` on every die/exit path below — an
  # interrupt (or a future `die` added between clone and cleanup) must not
  # leak a whole throwaway `--shared` clone under $TMPDIR.
  trap 'rm -rf "$tmp"' EXIT

  # A throwaway, object-sharing clone (not a `git worktree add` on the real
  # repo) sidesteps the `.git/config` write-lock a worktree add would contend
  # for (temperloop#1171's hazard) — this check runs read-only against the
  # real repo either way, so a genuinely separate repo is strictly simpler.
  if ! git clone --quiet --no-checkout --shared "$repo" "$tmp/clone" >/dev/null 2>&1; then
    die "archive-check: could not clone $repo"
  fi
  if ! git -C "$tmp/clone" checkout --quiet --detach "$base" >/dev/null 2>&1; then
    die "archive-check: base sha $base not found in $repo"
  fi

  local applies=1 detail=""
  if ! detail="$(git -C "$tmp/clone" -c user.name="dual-build-ledger" -c user.email="dual-build-ledger@localhost" am --quiet "$patch" 2>&1)"; then
    applies=0
    git -C "$tmp/clone" am --abort >/dev/null 2>&1 || true
  fi

  if [ "$applies" -eq 1 ]; then
    jq -cn --arg slug "$slug" --arg arm "$arm" --arg base "$base" \
      '{outcome:"APPLIES", slug:$slug, arm:$arm, base_sha:$base}'
    exit 0
  fi
  jq -cn --arg slug "$slug" --arg arm "$arm" --arg base "$base" --arg detail "$detail" \
    '{outcome:"REJECTED", slug:$slug, arm:$arm, base_sha:$base, detail:$detail}'
  exit 1
}

cmd_purge() {
  local dir="$LEDGER_DIR" apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "purge: --dir requires a path"; dir="$2"; shift 2 ;;
      --yes) apply=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "purge: unknown argument $1" ;;
    esac
  done
  if [ ! -e "$dir" ]; then
    printf 'dual-build-ledger.sh: purge: nothing at %s (already clean)\n' "$dir"
    exit 0
  fi
  if [ "$apply" -ne 1 ]; then
    printf 'dual-build-ledger.sh: purge: DRY RUN — would remove %s (re-run with --yes to actually delete)\n' "$dir"
    exit 0
  fi
  rm -rf "$dir" || die "purge: failed removing $dir"
  printf 'dual-build-ledger.sh: purge: removed %s\n' "$dir"
}

cmd_prune() {
  local dir="$LEDGER_DIR" retention="" apply=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) [ $# -ge 2 ] || die "prune: --dir requires a path"; dir="$2"; shift 2 ;;
      --retention-days) [ $# -ge 2 ] || die "prune: --retention-days requires a number"; retention="$2"; shift 2 ;;
      --apply) apply=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "prune: unknown argument $1" ;;
    esac
  done
  # See § NAMED-SETTING CONVENTION above — bare reference only, no local default.
  [ -n "$retention" ] || retention="${DUAL_BUILD_ARCHIVE_RETENTION_DAYS:-}"  # setting:exempt — declared/owned/registered by the sibling dual-build-settings item (temperloop#2071) in build.config.sh; this is a defensive, no-default read of a setting this script does not own (order-independent of which of the two sibling PRs merges first)
  case "$retention" in
    ''|*[!0-9]*) die "no retention window configured — pass --retention-days N or set DUAL_BUILD_ARCHIVE_RETENTION_DAYS (workflows/scripts/build/build.config.sh)" ;;
  esac

  local archdir="$dir/$ARCHIVES_SUBDIR"
  if [ ! -d "$archdir" ]; then
    printf 'dual-build-ledger.sh: prune: no archives at %s (nothing to do)\n' "$archdir"
    exit 0
  fi

  local now cutoff removed=0 kept=0 f mtime
  now="$(date -u +%s)"
  # `10#$retention` forces base-10: a leading-zero value (e.g. "08") passes
  # the digit-only guard above but bash arithmetic otherwise parses it as
  # invalid octal ("value too great for base"), which under `set -uo
  # pipefail` (no `-e`) would leave `cutoff` unset and error the loop's
  # `-lt` test once per file instead of failing this command outright.
  cutoff=$((now - 10#$retention * 86400))
  for f in "$archdir"/*.patch; do
    [ -e "$f" ] || continue
    mtime="$(_mtime_epoch "$f")" || { kept=$((kept + 1)); continue; }
    case "$mtime" in *[!0-9]*|'') kept=$((kept + 1)); continue ;; esac
    if [ "$mtime" -lt "$cutoff" ]; then
      [ "$apply" -ne 1 ] || rm -f "$f" || die "prune: failed removing $f"
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
    fi
  done

  if [ "$apply" -eq 1 ]; then
    printf 'dual-build-ledger.sh: prune: removed %s archive(s) older than %s day(s), kept %s\n' "$removed" "$retention" "$kept"
  else
    printf 'dual-build-ledger.sh: prune: DRY RUN — %s archive(s) older than %s day(s) would be removed, %s would be kept (re-run with --apply)\n' "$removed" "$retention" "$kept"
  fi
}

cmd="${1:-}"
[ $# -eq 0 ] || shift

case "$cmd" in
  append) cmd_append "$@" ;;
  read) cmd_read "$@" ;;
  archive) cmd_archive "$@" ;;
  archive-check) cmd_archive_check "$@" ;;
  purge) cmd_purge "$@" ;;
  prune) cmd_prune "$@" ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 1 ;;
  *) echo "dual-build-ledger.sh: unknown subcommand '$cmd'" >&2; usage >&2; exit 1 ;;
esac
