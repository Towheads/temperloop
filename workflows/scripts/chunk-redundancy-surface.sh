#!/usr/bin/env bash
#
# chunk-redundancy-surface.sh — rule-sized chunker for the always-loaded
# prose surface (temperloop#854, half (a) of the P9 semantic-redundancy
# probe split from #830; epic #810, contract amendment P9).
#
# WHAT THIS IS. Splits the always-loaded surface — the SAME tracked set
# workflows/scripts/config/contributor-manifest.tsv already defines for
# count-prose.sh's SESSION-START CONTRIBUTORS report — into rule-sized
# chunks and prints them as a JSON-Lines stream on stdout. This script does
# NOT score redundancy, compute similarity, or call an embedding/LLM-judge —
# that is #855's job, deliberately out of scope here (see the epic's own
# framing: "the scoring approach ... belongs to half (b) — this half must
# not presuppose it"). This script's only jobs are (1) decide where one rule
# ends and the next begins, and (2) emit that decision in a stable,
# documented, machine-readable form.
#
# THE SURFACE IS DATA, NOT CODE. Every row of contributor-manifest.tsv is
# one input to this script — adding a contributor later (a new command file,
# a new agent charter, a future full-file row) is a manifest-row edit, never
# a change to this script, exactly as it already is for count-prose.sh. See
# that file's own header for the manifest's row shape (path, unit, label,
# load) and the closed `unit` set (full | frontmatter:description) this
# script implements identically to count-prose.sh's own case arms.
#
# THE CHUNK-BOUNDARY RULE ("rule-sized units"). For a `unit=full` row, the
# tracked file's body is split wherever a NEW rule plausibly begins:
#   - a blank line ends the current chunk (a paragraph boundary);
#   - a markdown ATX heading (`#`..`######`) ends the current chunk and is
#     never itself emitted as a chunk — it updates the SECTION breadcrumb
#     (" > "-joined heading path) attached to every following chunk instead;
#   - a TOP-LEVEL list marker (a `-`/`*`/`+` bullet or `N.` numbered item
#     starting at column 0 — no leading whitespace) always starts a NEW
#     chunk, even with no preceding blank line, since these prose docs
#     routinely stack list items with no blank line between them (see
#     claude/CLAUDE.kernel.md's own bulleted rules). An INDENTED sub-bullet
#     is NOT a new chunk boundary — it is swept into its parent bullet's
#     chunk as a continuation line, mirroring the citation-marker convention
#     (claude/citation-schema.md): one marker per TOP-LEVEL rule, with any
#     indented elaboration considered part of that same rule.
#   - a fenced code block (``` or ~~~, optionally indented) is opaque: lines
#     inside it are never inspected for heading/list/blank-boundary shape,
#     so an example bullet or heading INSIDE a code sample can never
#     fracture a chunk it belongs to.
# For a `unit=frontmatter:description` row, the extracted single-line scalar
# IS the chunk — it is already an atomic, rule-sized unit (a whole command
# or agent's one-line self-description), so no further splitting applies.
#
# This is a deliberately GENERIC content-shape rule, not a per-file special
# case — it needs no code change when a future manifest row points at a
# structurally similar file (e.g. a `unit=full` row over claude/
# CLAUDE.kernel.md itself, which the manifest does not carry today per its
# own "Explicitly EXCLUDED" section — TIER-1 is count-prose.sh's concern,
# not this script's; this chunker is ready for that row the day it is
# added, with zero code change).
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO (scope discipline, Phase A):
#   - no similarity score, no shingle/embedding comparison BETWEEN chunks —
#     purely a segmentation pass over EACH file independently;
#   - no cap, no threshold, no exit-1 on any content property — this
#     script's own exit code reflects only "did chunking run to completion",
#     never a judgment about the prose it chunked (Phase A ships no gate:
#     nothing here can turn a contributor's PR red);
#   - no YAML-frontmatter stripping for a `unit=full` row — no row using
#     that unit carries frontmatter today (CLAUDE.md, the only such row,
#     has none); adding that generality with no row to exercise it would be
#     untested code (subtraction over mechanism) — a future full-unit row
#     over a frontmatter-carrying file is expected to need a small,
#     independently-tested follow-up, not a speculative stub landed here.
#
# OUTPUT CONTRACT (the seam #855 consumes — see the companion doc
# workflows/scripts/chunk-redundancy-surface.md for the authoritative,
# field-by-field schema reference). One compact JSON object per stdout line
# (NDJSON/JSON-Lines), UTF-8, keys sorted (`jq -S`), rows in
# contributor-manifest.tsv order, chunks in document order within a row.
# Human-facing diagnostics (a one-line summary, any warning) go to STDERR
# only — stdout is a pure, directly-parseable JSONL stream, never a mixed
# report+data surface.
#
# DETERMINISM (same input -> byte-identical output on macOS and Linux CI,
# matching count-prose.sh's own host-determinism contract — the technique
# is reused directly, not reinvented):
#   - `export LC_ALL=C`, exactly as count-prose.sh does, so awk/sed/sort
#     byte-comparisons never depend on the host's locale.
#   - Enumeration order is the manifest file's own row order (a tracked,
#     committed file) — never a filesystem glob or directory listing whose
#     order can vary by OS/filesystem.
#   - `wc -c`/`wc -w` counts are trimmed of the BSD-vs-GNU leading-whitespace
#     padding difference exactly as count-prose.sh's own bytes_in/words_in
#     helpers do (duplicated here rather than sourced — see the citation-
#     schema.md rationale note below on independent duplication).
#   - sha256 is computed via the same portable sha256sum/shasum fallback
#     idiom already established by workflows/scripts/tests/lib/sandbox.sh's
#     _sandbox_sha256 (GNU coreutils sha256sum preferred, BSD/macOS shasum
#     -a 256 fallback).
#   - JSON construction goes through `jq -n -S -c` (sorted keys, compact,
#     one object per line) so string escaping (backslash, quote, embedded
#     newline, any non-ASCII prose byte) is never hand-rolled in shell —
#     jq's own encoder is what is byte-identical across hosts, not a
#     bespoke sed pipeline reinventing JSON escaping.
#   - The awk chunk-boundary regexes below deliberately avoid `{n,m}`
#     interval-expression syntax (portability risk: BWK awk/mawk/gawk have
#     historically diverged on interval-expression support — see
#     lint-pr-body.sh's own note on avoiding gawk-only IGNORECASE for the
#     same reason) — every regex here uses only `^`, `$`, `+`, `*`, `|`,
#     `()`, and bracket classes, the portable ERE subset this repo's other
#     awk snippets already rely on.
#
# Independent-duplication note (mirrors check-contributor-manifest.sh's own
# stated rationale for NOT sourcing count-prose.sh's frontmatter extractor):
# this script re-implements the frontmatter_description() extraction and the
# bytes_in/words_in trimming helpers locally rather than sourcing
# count-prose.sh, so a lint and the report/stream it feeds never share a
# single point of failure.
#
# Usage:
#   workflows/scripts/chunk-redundancy-surface.sh
#   workflows/scripts/chunk-redundancy-surface.sh > chunks.jsonl
#
# Env overrides (fixture-driven tests only — same class as count-prose.sh's
# own COUNT_PROSE_ROOT/CONTRIBUTOR_MANIFEST_TSV, a test/fixture-root
# override, not an operator-facing config-precedence default):
#   REDUNDANCY_CHUNK_ROOT           repo root to read the manifest/files from
#                                   (default: this repo's own root)
#   REDUNDANCY_CHUNK_MANIFEST_TSV   path to the contributor manifest
#                                   (default: $REDUNDANCY_CHUNK_ROOT/workflows/
#                                   scripts/config/contributor-manifest.tsv)
#
# Dependency: jq (already a pervasive dependency across this repo's board/
# build/probe scripts — see e.g. workflows/scripts/emit-command-run.sh's own
# `jq -nc` construction idiom, mirrored here). Preinstalled on both the
# ubuntu-latest and macos-latest GitHub Actions runner images; no install
# step is added to ci.yml.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${REDUNDANCY_CHUNK_ROOT:=$REPO_ROOT}"  # setting:exempt — test/fixture root override, mirrors count-prose.sh's COUNT_PROSE_ROOT
: "${REDUNDANCY_CHUNK_MANIFEST_TSV:=$REDUNDANCY_CHUNK_ROOT/workflows/scripts/config/contributor-manifest.tsv}"  # setting:exempt — same fixture-root class as REDUNDANCY_CHUNK_ROOT itself

self="$(basename "$0")"

if ! command -v jq >/dev/null 2>&1; then
  echo "$self: jq not found on PATH — required for JSON construction" >&2
  exit 1
fi

if [ ! -f "$REDUNDANCY_CHUNK_MANIFEST_TSV" ]; then
  echo "$self: contributor manifest not found: $REDUNDANCY_CHUNK_MANIFEST_TSV" >&2
  exit 1
fi

if [ ! -d "$REDUNDANCY_CHUNK_ROOT/.git" ] && [ ! -f "$REDUNDANCY_CHUNK_ROOT/.git" ]; then
  echo "$self: $REDUNDANCY_CHUNK_ROOT is not a git checkout" >&2
  exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/chunk-redundancy-surface.XXXXXX")"
_crs_cleanup() {
  local rc=$?
  rm -rf "$scratch"
  exit "$rc"
}
trap _crs_cleanup EXIT

# bytes_in/words_in <file> — same BSD/GNU `wc` padding-trim contract as
# count-prose.sh's own helpers (duplicated deliberately — see header note).
bytes_in() { wc -c <"$1" | tr -d '[:space:]'; }
words_in() { wc -w <"$1" | tr -d '[:space:]'; }

# _crs_sha256 <file> — portable sha256, same fallback idiom as
# workflows/scripts/tests/lib/sandbox.sh's _sandbox_sha256.
_crs_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# frontmatter_description <file> — identical extraction shape to
# count-prose.sh's own function of the same name (independently
# duplicated — see header note). Echoes the single-line `description:`
# scalar value from a file's YAML frontmatter block, trailing whitespace
# trimmed; empty if absent.
frontmatter_description() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^description:/ {
      sub(/^description: ?/, "")
      sub(/[ \t]+$/, "")
      print
      exit
    }
  ' "$1"
}

# _crs_description_line_no <file> — the 1-based line number of the
# `description:` field inside the frontmatter block, for this row's
# start_line/end_line provenance (both equal, since it is a single line).
_crs_description_line_no() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm && /^description:/ { print NR; exit }
  ' "$1"
}

# ---------------------------------------------------------------------------
# The rule-sized body chunker (unit=full). Emits, to stdout, one
# tab-separated metadata line per chunk:
#   chunk_index<TAB>start_line<TAB>end_line<TAB>section
# and writes the chunk's exact text (lines joined by real newlines, no
# trailing blank line) to "<out_dir>/chunk-<chunk_index>.txt".
#
# See the script header for the full boundary-rule rationale. Regexes here
# deliberately avoid `{n,m}` interval syntax for BWK-awk/mawk/gawk
# portability (header note).
# ---------------------------------------------------------------------------
_crs_chunk_body() {
  local file="$1" out_dir="$2"
  awk -v out_dir="$out_dir" '
    function build_section(   i, out) {
      out = ""
      for (i = 1; i <= 20; i++) {
        if (sec[i] != "") {
          out = (out == "") ? sec[i] : out " > " sec[i]
        }
      }
      return out
    }
    function flush(   i, outfile) {
      if (nlines == 0) return
      chunk_count++
      outfile = out_dir "/chunk-" sprintf("%04d", chunk_count) ".txt"
      # No trailing newline in the written file: printf (not print) on the
      # LAST line only, so a chunk file exact bytes are "lines joined by a
      # newline, no final newline", matching the frontmatter:description
      # case own printf-percent-s call (no appended newline). Keeping the
      # two unit types byte-shape-consistent is what lets
      # byte_count/word_count/sha256 and the --rawfile text read below mean
      # the same thing for either unit. (No single-quote characters in this
      # comment block: it lives inside the outer single-quoted awk-program
      # string this script hands to `awk`, and one would terminate that
      # bash string early.)
      for (i = 1; i <= nlines; i++) {
        if (i < nlines) printf "%s\n", lines[i] > outfile
        else printf "%s", lines[i] > outfile
      }
      close(outfile)
      printf "%d\t%d\t%d\t%s\n", chunk_count, start_line, end_line, build_section()
      nlines = 0
      start_line = 0
      delete lines
    }
    {
      line = $0
      sub(/\r$/, "", line)

      # Fenced code block: opaque. Toggle on any line that opens/closes one;
      # never inspect fence-interior lines for heading/list/blank shape.
      if (match(line, /^[ \t]*(```+|~~~+)/)) {
        if (start_line == 0) start_line = NR
        nlines++; lines[nlines] = line
        end_line = NR
        in_fence = !in_fence
        next
      }
      if (in_fence) {
        if (start_line == 0) start_line = NR
        nlines++; lines[nlines] = line
        end_line = NR
        next
      }

      # Blank line: paragraph/list-item boundary.
      if (line ~ /^[ \t]*$/) { flush(); next }

      # ATX heading: boundary; updates the section breadcrumb; never itself
      # a chunk.
      if (match(line, /^#+[ \t]+/)) {
        flush()
        hashes = substr(line, RSTART, RLENGTH)
        gsub(/[ \t]+$/, "", hashes)
        level = length(hashes)
        title = line
        sub(/^#+[ \t]+/, "", title)
        gsub(/[ \t]+$/, "", title)
        for (i = level; i <= 20; i++) sec[i] = ""
        sec[level] = hashes " " title
        next
      }

      # Top-level list marker (column 0 only — an indented sub-bullet is a
      # continuation of its parent chunk, never its own boundary).
      is_list = 0
      if (match(line, /^(-|\*|\+)[ \t]+[^ \t]/)) is_list = 1
      else if (match(line, /^[0-9]+\.[ \t]+[^ \t]/)) is_list = 1
      if (is_list && nlines > 0) flush()

      if (start_line == 0) start_line = NR
      nlines++; lines[nlines] = line
      end_line = NR
    }
    END { flush() }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Main: walk the manifest, emit one JSONL chunk record per chunk.
# ---------------------------------------------------------------------------
row_num=0
chunk_total=0

while IFS=$'\t' read -r m_path m_unit m_label m_load || [ -n "${m_path:-}" ]; do
  [ -z "${m_path:-}" ] && continue
  case "$m_path" in \#*) continue ;; esac

  # Same CR/trailing-whitespace trim as count-prose.sh's own manifest
  # parser (a CRLF-saved manifest must not silently misroute a field).
  m_path="${m_path%$'\r'}"; m_path="${m_path%"${m_path##*[![:space:]]}"}"
  m_unit="${m_unit%$'\r'}"; m_unit="${m_unit%"${m_unit##*[![:space:]]}"}"
  m_label="${m_label%$'\r'}"; m_label="${m_label%"${m_label##*[![:space:]]}"}"
  m_load="${m_load%$'\r'}"; m_load="${m_load%"${m_load##*[![:space:]]}"}"

  if [ -z "${m_unit:-}" ] || [ -z "${m_label:-}" ] || [ -z "${m_load:-}" ]; then
    echo "$self: malformed contributor-manifest row (need 4 tab-separated fields): $m_path" >&2
    exit 1
  fi

  full_path="$REDUNDANCY_CHUNK_ROOT/$m_path"
  if [ ! -f "$full_path" ]; then
    echo "$self: contributor row '$m_path' does not exist under $REDUNDANCY_CHUNK_ROOT" >&2
    exit 1
  fi

  row_num=$((row_num + 1))
  row_dir="$scratch/row-$row_num"
  mkdir -p "$row_dir"

  case "$m_unit" in
    frontmatter:description)
      val="$(frontmatter_description "$full_path")"
      if [ -z "$val" ]; then
        echo "$self: contributor row '$m_path' has no description: frontmatter field" >&2
        exit 1
      fi
      line_no="$(_crs_description_line_no "$full_path")"
      chunk_file="$row_dir/chunk-0001.txt"
      printf '%s' "$val" >"$chunk_file"
      meta_lines="1"$'\t'"$line_no"$'\t'"$line_no"$'\t'""
      ;;
    full)
      meta_lines="$(_crs_chunk_body "$full_path" "$row_dir")"
      ;;
    *)
      echo "$self: contributor row '$m_path' has unknown unit '$m_unit' (want: full | frontmatter:description)" >&2
      exit 1
      ;;
  esac

  chunk_count_this_row="$(printf '%s\n' "$meta_lines" | grep -c . || true)"

  while IFS=$'\t' read -r c_idx c_start c_end c_section; do
    [ -z "${c_idx:-}" ] && continue
    chunk_total=$((chunk_total + 1))
    chunk_file="$row_dir/chunk-$(printf '%04d' "$c_idx").txt"
    byte_count="$(bytes_in "$chunk_file")"
    word_count="$(words_in "$chunk_file")"
    sha="$(_crs_sha256 "$chunk_file")"
    section_arg="$c_section"

    jq -n -S -c \
      --arg id "${m_path}#${c_idx}" \
      --arg path "$m_path" \
      --arg unit "$m_unit" \
      --arg label "$m_label" \
      --arg load "$m_load" \
      --argjson chunk_index "$c_idx" \
      --argjson chunk_count "$chunk_count_this_row" \
      --arg section "$section_arg" \
      --argjson start_line "$c_start" \
      --argjson end_line "$c_end" \
      --argjson byte_count "$byte_count" \
      --argjson word_count "$word_count" \
      --arg sha256 "$sha" \
      --rawfile text "$chunk_file" \
      '{
        id: $id,
        path: $path,
        unit: $unit,
        label: $label,
        load: $load,
        chunk_index: $chunk_index,
        chunk_count: $chunk_count,
        section: (if $section == "" then null else $section end),
        start_line: $start_line,
        end_line: $end_line,
        byte_count: $byte_count,
        word_count: $word_count,
        sha256: $sha256,
        text: $text
      }'
  done <<<"$meta_lines"
done <"$REDUNDANCY_CHUNK_MANIFEST_TSV"

if [ "$row_num" -eq 0 ]; then
  echo "$self: zero contributor rows parsed from $REDUNDANCY_CHUNK_MANIFEST_TSV" >&2
  exit 1
fi

echo "$self: $row_num row(s), $chunk_total chunk(s) emitted" >&2
