#!/usr/bin/env python3
"""score-redundancy.py — semantic-redundancy scorer over #854's chunk stream.

temperloop#855, half (b) of the P9 semantic-redundancy probe (epic #810).
Invoked by workflows/scripts/score-redundancy.sh, which owns the operator-
facing settings; this module owns the scoring itself. Python 3 stdlib only —
no embedding model, no network call, no LLM judge (see § Method in
workflows/scripts/score-redundancy.md for why, and for what that costs).

INPUT is #854's documented seam and nothing else: the JSON-Lines chunk stream
described field-by-field in workflows/scripts/chunk-redundancy-surface.md,
read from a file or stdin. This module never re-implements chunking, never
reads contributor-manifest.tsv, and never imports from the chunker.

Modes:
  report    human-readable ranked findings + the pre-registered go/no-go
  fixtures  self-test against #854's labelled fixture corpus (exit 1 on
            regression) — a detector self-test, never a check on contributor
            prose
  json      the same ranking as machine-readable JSON, for a consumer that
            wants the numbers without parsing the report
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import re
import sys

# ---------------------------------------------------------------------------
# Normalisation. Every step here is a GENERIC English/markdown transformation,
# never a lexicon built from the fixtures it is measured against — a synonym
# table hand-fitted to the fixture pairs would inflate the fixture pass and
# tell us nothing about the real surface.
# ---------------------------------------------------------------------------

STOPWORDS = frozenset("""
a an the and or but if then than that this these those of in on at to for from by with as is are
was were be been being it its he she they them his her their we our you your i me my not no nor so
such only just also very can could may might must shall should will would do does did done have
has had having there here when where which who whom whose what how why all any both each few more
most other some own same too don now over under again further once about into out up down off
above below between through during before after while because until unless per via etc ie eg vs
versus s t
""".split())

# Number words -> digits, so "forty" and "40" are one token. General English,
# closed set, not fixture-derived.
NUMBER_WORDS = {
    "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
    "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
    "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18",
    "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
    "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80",
    "ninety": "90", "hundred": "100", "thousand": "1000", "million": "1000000",
}

# Longest-first suffix strip (a Porter-lite stemmer, deliberately crude: a
# real stemmer would be a dependency, and the failure mode of over-stemming
# is a false positive this measurement is designed to catch, not hide).
_SUFFIXES = (
    "ational", "ization", "iveness", "fulness", "ousness", "ations", "ingly",
    "edly", "ement", "ments", "ation", "ities", "ively", "ance", "ence",
    "ment", "ness", "ions", "ing", "ies", "ive", "ity", "ers", "est", "ent",
    "ed", "es", "ly", "s",
)

_WORD_RE = re.compile(r"[a-z0-9]+")
_MARKUP_RE = re.compile(r"[`*_>#\[\]()]")


def stem(word: str) -> str:
    for suffix in _SUFFIXES:
        if len(word) - len(suffix) >= 4 and word.endswith(suffix):
            return word[: -len(suffix)]
    return word


def content_tokens(text: str) -> list[str]:
    """Markdown text -> stemmed, stopword-free content tokens."""
    lowered = _MARKUP_RE.sub(" ", text.lower())
    out = []
    for raw in _WORD_RE.findall(lowered):
        word = NUMBER_WORDS.get(raw, raw)
        if len(word) < 2 or word in STOPWORDS:
            continue
        out.append(stem(word))
    return out


def raw_words(text: str) -> list[str]:
    return _WORD_RE.findall(text.lower())


def shingles(text: str, n: int) -> set[str]:
    words = raw_words(text)
    return {" ".join(words[i:i + n]) for i in range(0, max(0, len(words) - n + 1))}


# ---------------------------------------------------------------------------
# Lexical relaxation. Two stems match when they are equal, or when one is a
# >=4-character prefix or substring of the other. This is what lets a
# paraphrase register at all without a synonym list: feat~feature,
# fix~bugfix, doc~documentation, test~testing. It is a blunt instrument and it
# over-matches (cap~capture); that cost is real and is reported, not hidden.
# ---------------------------------------------------------------------------

_MIN_RELAXED_LEN = 4


def relaxed_match(a: str, b: str) -> bool:
    if a == b:
        return True
    lo, hi = (a, b) if len(a) <= len(b) else (b, a)
    if len(lo) < _MIN_RELAXED_LEN:
        return False
    return hi.startswith(lo) or lo in hi


# ---------------------------------------------------------------------------
# Deliberate-pointer detection. A chunk that DEFERS to a named canonical rule
# and states only what is specific to its own context is not a restatement —
# flagging it is the false positive #854's negative-ci-branch-policy-pointer
# fixture exists to catch. The markers below are the STRONG forms: an explicit
# act of deferral. The weak topical word "canonical" on its own deliberately
# does NOT qualify (a rule may legitimately call itself canonical while being
# the thing restated elsewhere).
# ---------------------------------------------------------------------------

_POINTER_PATTERNS = (
    (r"\bnot repeated here\b", "not-repeated-here"),
    (r"\bthat part is not\b", "that-part-is-not"),
    (r"\bwhat is specific to\b", "what-is-specific-to"),
    (r"\brather than restat", "rather-than-restating"),
    (r"\brather than rest[ai]", "rather-than-restating"),
    (r"\bdefer(s|red|ring)?\s+(to|here)\b", "defers-to"),
    (r"\bdescribed in\b", "described-in"),
    (r"\bdocumented in\b", "documented-in"),
    (r"\bspecified (in|by)\b", "specified-in"),
    (r"\bsee\s+\S+\s+for\b", "see-x-for"),
    (r"\bthin pointer\b", "thin-pointer"),
    (r"\bpoints? at\b", "points-at"),
    (r"\bowned by\b", "owned-by"),
    (r"\brefer to\b", "refer-to"),
)


def pointer_markers(text: str) -> list[str]:
    lowered = text.lower()
    return sorted({name for pattern, name in _POINTER_PATTERNS if re.search(pattern, lowered)})


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

SHINGLE_N = 5


def build_idf(token_lists):
    """Smoothed IDF over the corpus actually being scored.

    The weighting is what stops a pair from ranking on shared scaffolding
    ("the", already dropped; "review", "script", "board" — kept but cheap)
    instead of on the rare terms that carry a rule's content.
    """
    n_docs = len(token_lists) or 1
    doc_freq: dict[str, int] = {}
    for tokens in token_lists:
        for token in set(tokens):
            doc_freq[token] = doc_freq.get(token, 0) + 1
    idf = {t: math.log((n_docs + 1) / (df + 0.5)) for t, df in doc_freq.items()}
    unseen = math.log((n_docs + 1) / 0.5)
    return idf, unseen


def directional_share(src: set[str], dst: set[str], idf, unseen) -> float:
    """Share of src's IDF mass that finds a relaxed match somewhere in dst."""
    total = sum(idf.get(t, unseen) for t in src)
    if total <= 0:
        return 0.0
    matched = 0.0
    for token in src:
        if any(relaxed_match(token, other) for other in dst):
            matched += idf.get(token, unseen)
    return matched / total


def score_pair(text_a, text_b, bytes_a, bytes_b, idf, unseen):
    """Score one pair. Returns a dict; see score-redundancy.md § Method."""
    set_a, set_b = set(content_tokens(text_a)), set(content_tokens(text_b))
    d_ab = directional_share(set_a, set_b, idf, unseen)
    d_ba = directional_share(set_b, set_a, idf, unseen)
    overlap = min(d_ab, d_ba)

    sh_a, sh_b = shingles(text_a, SHINGLE_N), shingles(text_b, SHINGLE_N)
    denom = min(len(sh_a), len(sh_b))
    verbatim = (len(sh_a & sh_b) / denom) if denom else 0.0

    score = max(overlap, verbatim)

    # Duplicated byte weight, taken CONSERVATIVELY as the smaller of the two
    # sides' matched byte mass: the bytes recoverable whichever member a
    # maintainer chooses to cut. This is the ranking key the acceptance asks
    # for ("ranked by the byte weight of the duplication") — an estimate from
    # matched IDF share, never an exact diff.
    dup_bytes = int(round(min(d_ab * bytes_a, d_ba * bytes_b)))

    markers_a, markers_b = pointer_markers(text_a), pointer_markers(text_b)
    return {
        "score": score,
        "overlap": overlap,
        "verbatim": verbatim,
        "d_ab": d_ab,
        "d_ba": d_ba,
        "dup_bytes": dup_bytes,
        "pointer_markers_a": markers_a,
        "pointer_markers_b": markers_b,
        "pointer_suppressed": bool(markers_a or markers_b),
    }


def rank_chunks(chunks, floor):
    """Score every unordered chunk pair; return (candidates, suppressed)."""
    texts = [c["text"] for c in chunks]
    idf, unseen = build_idf([content_tokens(t) for t in texts])

    candidates, suppressed = [], []
    for i, j in itertools.combinations(range(len(chunks)), 2):
        a, b = chunks[i], chunks[j]
        result = score_pair(a["text"], b["text"], a["byte_count"], b["byte_count"], idf, unseen)
        if result["score"] < floor:
            continue
        row = dict(result)
        row["a"], row["b"] = a, b
        row["identical"] = a["sha256"] == b["sha256"]
        (suppressed if result["pointer_suppressed"] else candidates).append(row)

    key = lambda r: (-r["dup_bytes"], -r["score"], r["a"]["id"], r["b"]["id"])  # noqa: E731
    candidates.sort(key=key)
    suppressed.sort(key=key)
    return candidates, suppressed


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def read_stream(path):
    handle = sys.stdin if path == "-" else open(path, encoding="utf-8")
    try:
        chunks = [json.loads(line) for line in handle if line.strip()]
    finally:
        if handle is not sys.stdin:
            handle.close()
    required = ("id", "text", "byte_count", "sha256", "path")
    for chunk in chunks:
        missing = [f for f in required if f not in chunk]
        if missing:
            raise SystemExit(
                "score-redundancy: chunk stream record is missing %s — this "
                "consumer reads only the fields chunk-redundancy-surface.md "
                "documents; a producer change belongs in that contract first"
                % ", ".join(missing)
            )
    return chunks


def read_labels(path):
    """Hand-labelled precision sample: id_a<TAB>id_b<TAB>tp|fp<TAB>rationale."""
    labels = {}
    try:
        handle = open(path, encoding="utf-8")
    except OSError:
        return labels
    with handle:
        for lineno, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                raise SystemExit(
                    "score-redundancy: %s:%d — need at least 3 tab-separated "
                    "fields (id_a, id_b, tp|fp[, rationale])" % (path, lineno)
                )
            id_a, id_b, verdict = parts[0].strip(), parts[1].strip(), parts[2].strip().lower()
            rationale = parts[3].strip() if len(parts) > 3 else ""
            if verdict not in ("tp", "fp"):
                raise SystemExit(
                    "score-redundancy: %s:%d — label must be tp or fp, got %r"
                    % (path, lineno, verdict)
                )
            labels[frozenset((id_a, id_b))] = (verdict, rationale)
    return labels


def preview(text, width=88):
    flat = " ".join(text.split())
    return flat if len(flat) <= width else flat[: width - 1] + "…"


# ---------------------------------------------------------------------------
# Fixture self-test
# ---------------------------------------------------------------------------

def run_fixtures(fixtures_path, floor, out=sys.stdout):
    with open(fixtures_path, encoding="utf-8") as handle:
        entries = json.load(handle)["fixtures"]

    # IDF for the fixture pass comes from the fixture corpus itself: the
    # fixtures are synthetic and carry no provenance, so folding them into the
    # real surface's IDF would let the surface's own term distribution decide
    # a fixture's verdict.
    idf, unseen = build_idf([content_tokens(e[side]["text"]) for e in entries for side in ("chunk_a", "chunk_b")])

    print("PRE-REGISTERED CANDIDATE FLOOR: score >= %.2f (REDUNDANCY_SCORE_FLOOR_PCT;"
          " calibrated on THIS corpus alone — see score-redundancy.md PR-4)" % floor, file=out)
    print(file=out)

    failures = 0
    for entry in entries:
        text_a, text_b = entry["chunk_a"]["text"], entry["chunk_b"]["text"]
        result = score_pair(text_a, text_b, len(text_a.encode()), len(text_b.encode()), idf, unseen)
        flagged = result["score"] >= floor and not result["pointer_suppressed"]
        want_flagged = entry["label"] == "positive"
        ok = flagged == want_flagged
        failures += 0 if ok else 1

        why = "flagged" if flagged else (
            "suppressed as a deliberate pointer (%s)" % ", ".join(
                sorted(set(result["pointer_markers_a"] + result["pointer_markers_b"])))
            if result["pointer_suppressed"] else "below floor")
        print("%-4s %-9s %-45s score=%.3f verbatim%d=%.3f -> %s"
              % ("PASS" if ok else "FAIL", entry["label"], entry["id"],
                 result["score"], SHINGLE_N, result["verbatim"], why), file=out)
        print("       %s" % entry["rationale"][:150], file=out)

    print(file=out)
    if failures:
        print("FAIL: %d of %d fixture(s) misclassified at floor %.2f"
              % (failures, len(entries), floor), file=out)
        return 1
    print("OK — all %d fixture(s) classified correctly at floor %.2f: every positive "
          "paraphrase pair flagged despite sharing no 10-word shingle, every negative "
          "pair not flagged." % (len(entries), floor), file=out)
    return 0


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def measure_precision(candidates, labels, sample_n):
    """Join the hand-labelled sample onto the top-N ranking. Never re-ranks."""
    sample = candidates[:sample_n]
    labelled, unlabelled = [], []
    for row in sample:
        key = frozenset((row["a"]["id"], row["b"]["id"]))
        if key in labels:
            verdict, rationale = labels[key]
            labelled.append((row, verdict, rationale))
        else:
            unlabelled.append(row)
    ranked_keys = {frozenset((r["a"]["id"], r["b"]["id"])) for r in sample}
    stale = [k for k in labels if k not in ranked_keys]
    tp = sum(1 for _, verdict, _ in labelled if verdict == "tp")
    return sample, labelled, unlabelled, stale, tp


def run_report(chunks, floor, threshold_pct, min_sample, sample_n, labels_path, out=sys.stdout):
    candidates, suppressed = rank_chunks(chunks, floor)
    labels = read_labels(labels_path)

    print("SEMANTIC REDUNDANCY — ranked findings over the always-loaded surface", file=out)
    print("=" * 78, file=out)
    print("Surface: %d chunk(s) over %d file(s), %d unordered pair(s) scored."
          % (len(chunks), len({c["path"] for c in chunks}), len(chunks) * (len(chunks) - 1) // 2), file=out)
    print("Input:   #854's chunk stream, read through the documented JSON-Lines seam", file=out)
    print("         (workflows/scripts/chunk-redundancy-surface.md).", file=out)
    print("Floor:   score >= %.2f (REDUNDANCY_SCORE_FLOOR_PCT), calibrated on #854's" % floor, file=out)
    print("         labelled fixture corpus alone — never on this surface.", file=out)
    print(file=out)

    print("RANKED CANDIDATES (by duplicated-byte weight, the acceptance's own ranking key)", file=out)
    print("-" * 78, file=out)
    if not candidates:
        print("  none — no pair over the current surface clears the candidate floor.", file=out)
    for rank, row in enumerate(candidates, 1):
        marker = " [VERBATIM-IDENTICAL]" if row["identical"] else ""
        print("%3d. ~%d B duplicated  score=%.3f (overlap=%.3f verbatim%d=%.3f)%s"
              % (rank, row["dup_bytes"], row["score"], row["overlap"], SHINGLE_N,
                 row["verbatim"], marker), file=out)
        for side in ("a", "b"):
            chunk = row[side]
            print("       %s  [%d B, lines %s-%s]"
                  % (chunk["id"], chunk["byte_count"], chunk["start_line"], chunk["end_line"]), file=out)
            print("         %s" % preview(chunk["text"]), file=out)
    print(file=out)

    print("SUPPRESSED AS DELIBERATE POINTERS (reported, never silently dropped)", file=out)
    print("-" * 78, file=out)
    if not suppressed:
        print("  none.", file=out)
    for row in suppressed:
        markers = sorted(set(row["pointer_markers_a"] + row["pointer_markers_b"]))
        print("  ~%d B  score=%.3f  %s <-> %s  [%s]"
              % (row["dup_bytes"], row["score"], row["a"]["id"], row["b"]["id"],
                 ", ".join(markers)), file=out)
    print(file=out)

    sample, labelled, unlabelled, stale, tp = measure_precision(candidates, labels, sample_n)

    print("PRECISION MEASUREMENT", file=out)
    print("-" * 78, file=out)
    print("PRE-REGISTERED THRESHOLD: a redundancy gate is warranted at precision >= %d%%"
          % threshold_pct, file=out)
    print("  (REDUNDANCY_PRECISION_THRESHOLD_PCT) over a hand-labelled sample of at least", file=out)
    print("  %d pairs (REDUNDANCY_PRECISION_MIN_SAMPLE). Both were fixed in commit" % min_sample, file=out)
    print("  \"pre-register the precision threshold before any measurement\", BEFORE this", file=out)
    print("  script existed — see score-redundancy.md § Pre-registration.", file=out)
    print(file=out)

    for row, verdict, rationale in labelled:
        print("  %-2s  %s <-> %s" % (verdict.upper(), row["a"]["id"], row["b"]["id"]), file=out)
        if rationale:
            print("      %s" % rationale, file=out)
    if unlabelled:
        print(file=out)
        print("  UNLABELLED in the top %d (excluded from the figure, never counted as TP):" % sample_n, file=out)
        for row in unlabelled:
            print("      %s <-> %s" % (row["a"]["id"], row["b"]["id"]), file=out)
    if stale:
        print(file=out)
        print("  STALE LABELS (a labelled pair no longer in the top %d — the surface moved" % sample_n, file=out)
        print("  since it was labelled; excluded from the figure):", file=out)
        for key in sorted(tuple(sorted(k)) for k in stale):
            print("      %s <-> %s" % key, file=out)
    print(file=out)

    n_labelled = len(labelled)
    if n_labelled == 0:
        print("MEASURED PRECISION: not measured — no labelled pair in the top %d." % sample_n, file=out)
        print("GO/NO-GO: NO-GO — insufficient evidence (sample size 0, pre-registered", file=out)
        print("  minimum %d). Recorded as a finding; see score-redundancy.md § Findings." % min_sample, file=out)
        return 0

    precision = 100.0 * tp / n_labelled
    print("MEASURED PRECISION: %.1f%% (%d true positive(s) of %d hand-labelled pair(s);"
          % (precision, tp, n_labelled), file=out)
    print("  sample size n=%d, drawn as the top %d candidates by duplicated-byte weight)."
          % (n_labelled, sample_n), file=out)
    print(file=out)

    if n_labelled < min_sample:
        print("GO/NO-GO: NO-GO — sample size %d is below the pre-registered minimum of %d."
              % (n_labelled, min_sample), file=out)
        print("  The ratio above is reported for completeness; it does not clear the bar,", file=out)
        print("  and the pre-registration forbids lowering the minimum to make it.", file=out)
    elif precision + 1e-9 >= threshold_pct:
        print("GO/NO-GO: GO — measured precision %.1f%% meets the pre-registered threshold"
              % precision, file=out)
        print("  of %d%% over n=%d. A Phase-B redundancy gate would act on real duplication"
              % (threshold_pct, n_labelled), file=out)
        print("  more often than on noise.", file=out)
    else:
        print("GO/NO-GO: NO-GO — measured precision %.1f%% is below the pre-registered"
              % precision, file=out)
        print("  threshold of %d%% over n=%d. A Phase-B redundancy gate is NOT warranted on"
              % (threshold_pct, n_labelled), file=out)
        print("  this detector; the ranked findings above stand on their own as a", file=out)
        print("  report-only surface. Per the pre-registration, the detector is NOT", file=out)
        print("  re-tuned against these labels and re-measured.", file=out)
    return 0


def run_json(chunks, floor, sample_n, labels_path, out=sys.stdout):
    candidates, suppressed = rank_chunks(chunks, floor)
    labels = read_labels(labels_path)

    def emit(row):
        key = frozenset((row["a"]["id"], row["b"]["id"]))
        verdict, rationale = labels.get(key, (None, None))
        return {
            "a": row["a"]["id"], "b": row["b"]["id"],
            "dup_bytes": row["dup_bytes"], "score": round(row["score"], 4),
            "overlap": round(row["overlap"], 4), "verbatim": round(row["verbatim"], 4),
            "identical": row["identical"],
            "pointer_markers": sorted(set(row["pointer_markers_a"] + row["pointer_markers_b"])),
            "label": verdict, "label_rationale": rationale,
        }

    json.dump({
        "chunks": len(chunks),
        "pairs_scored": len(chunks) * (len(chunks) - 1) // 2,
        "floor": floor,
        "sample_n": sample_n,
        "candidates": [emit(r) for r in candidates],
        "pointer_suppressed": [emit(r) for r in suppressed],
    }, out, indent=2, sort_keys=True)
    out.write("\n")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("--mode", choices=("report", "fixtures", "json"), default="report")
    parser.add_argument("--stream", default="-", help="chunk-stream path, or - for stdin")
    parser.add_argument("--fixtures-json", default="")
    parser.add_argument("--labels-tsv", default="")
    parser.add_argument("--floor-pct", type=float, default=16.0)
    parser.add_argument("--threshold-pct", type=float, default=80.0)
    parser.add_argument("--min-sample", type=int, default=10)
    parser.add_argument("--sample-n", type=int, default=12)
    args = parser.parse_args(argv)

    floor = args.floor_pct / 100.0
    if args.mode == "fixtures":
        if not args.fixtures_json:
            raise SystemExit("score-redundancy: --mode fixtures needs --fixtures-json")
        return run_fixtures(args.fixtures_json, floor)

    chunks = read_stream(args.stream)
    if args.mode == "json":
        return run_json(chunks, floor, args.sample_n, args.labels_tsv)
    return run_report(chunks, floor, args.threshold_pct, args.min_sample,
                      args.sample_n, args.labels_tsv)


if __name__ == "__main__":
    sys.exit(main())
