# Semantic redundancy scoring — pre-registration, method, and findings

Companion document to `workflows/scripts/score-redundancy.sh` (temperloop#855,
half (b) of the P9 semantic-redundancy probe split from #830; epic #810,
contract amendment P9). Half (a) is temperloop#854 — the rule-sized chunker
(`chunk-redundancy-surface.sh`), its format contract
(`chunk-redundancy-surface.md`), and the labelled fixture corpus
(`workflows/scripts/config/redundancy-fixtures.json`). This half consumes all
three **through their documented interfaces** and never reaches into the
chunker's internals.

Three things live here, in the order they were produced — and the order is the
point:

1. **§ Pre-registration** — the precision threshold, the sample size, and the
   labelling protocol, all fixed **before any precision figure was computed**.
2. **§ Method** — how the detector scores a pair, once it existed.
3. **§ Findings** — the ranked redundancy candidates over the current
   always-loaded surface, the hand-labelled sample, the measured precision, and
   the resulting go/no-go.

Sections 2 and 3 are appended by later commits. Section 1 is committed **first,
alone**, so the ordering is verifiable from `git log` rather than asserted in
prose. That is not ceremony: epic #810 exists because three prior attempts each
enforced against a metric before establishing that the metric tracked the cost,
and a precision threshold chosen after seeing the precision figure would repeat
exactly that error inside the one item whose job is deciding whether the
redundancy gate happens.

---

## Pre-registration

*Committed before the detector existed and before any pair over the real
surface was scored or labelled. Nothing below may be revised after a precision
figure is known; a later change to any of it is a new pre-registration for a
new measurement, recorded as such.*

### PR-1 — The decision this measurement informs

Whether Phase B is warranted in adding a **redundancy gate** — a check that can
fail a contributor's build when the always-loaded surface restates a rule it
already states. Phase A ships no gate either way (see ADR
`0018-measure-session-cost-before-gating.md`); this measurement only decides
whether building one is justified.

### PR-2 — The pre-registered precision threshold

> **A redundancy gate is warranted iff the detector's measured precision over a
> hand-labelled sample of its own top-ranked output is ≥ 80%.**

Registered as `REDUNDANCY_PRECISION_THRESHOLD_PCT` in
`workflows/scripts/config/setting-registry.tsv`.

Why 80, argued **without reference to any measured value** (none existed):

- A gate that blocks a merge is only obeyed if it is trusted. At 4-in-5 flags
  genuine, a contributor disposing of a flag spends most of that time removing
  real duplication.
- Below that, the reviewer time spent triaging false flags starts to rival the
  waste the gate removes, and the predictable outcome is the gate being
  bypassed, exempted, or deleted — worse than never shipping it, because the
  bypass habit generalises.
- 80% is deliberately **not** the ≥95% one would demand of a mechanical lint
  (a shellcheck rule, a schema validator). Semantic redundancy is a judgment
  call at the margin, and a bar set where no plausible detector could reach it
  would make the pre-registration decorative.

### PR-3 — The pre-registered minimum sample size

> **The measurement requires at least 10 hand-labelled pairs. Below that, the
> verdict is NO-GO by insufficient evidence, whatever the ratio reads.**

Registered as `REDUNDANCY_PRECISION_MIN_SAMPLE`. A precision figure over 3
pairs is not a precision figure; reporting one without its sample size beside
it is the failure this item's acceptance explicitly names.

The sample is the **top `REDUNDANCY_LABEL_SAMPLE_N` = 12 candidate pairs by
ranked duplicated-byte weight** (or every candidate, if fewer than 12 clear the
candidate floor). Twelve, so the sample clears the minimum of 10 with a small
margin for a pair going stale as the surface changes.

### PR-4 — The candidate floor is calibrated on the fixture corpus, not on the
### surface being measured

The score at or above which a pair is reported as a candidate
(`REDUNDANCY_SCORE_FLOOR_PCT`) is fixed by calibration against #854's labelled
fixture corpus **alone** — 2 known-positive paraphrase pairs, 2 known-negative
pairs. That corpus exists for exactly this purpose, and it is disjoint from the
real always-loaded surface the precision figure is measured over, so
calibrating on it is not the same act as tuning on the thing being scored.

Explicitly forbidden by this pre-registration: moving the floor after seeing
the real surface's ranked output or its labels, in order to move the precision
figure.

### PR-5 — The labelling protocol, fixed before any pair was labelled

A candidate pair is a **TRUE POSITIVE** iff **both** hold:

1. **Same content.** The overlapping portion states the same rule, constraint,
   or fact in both chunks — not merely the same subject, and not merely a
   shared sentence frame whose slots differ.
2. **Removable.** A maintainer could delete the overlapping content from one
   member — outright, or by replacing it with a reference to the other — and
   the surface would still carry every rule, constraint, and fact it carries
   today.

Otherwise it is a **FALSE POSITIVE**. Four recurring cases are disposed here,
in advance, so that none of them is decided after a number is visible:

- **Deliberate pointer** — one member defers by name to the other and states
  only what is specific to its own context. **FALSE POSITIVE**: nothing is
  restated. (#854's `negative-ci-branch-policy-pointer` is the fixture form.)
- **Same subject, different rule** — both chunks concern one topic but govern
  two different actions. **FALSE POSITIVE**. (#854's
  `negative-token-rules-near-miss`.)
- **Shared frame, differing slots** — the same sentence template instantiated
  for different subjects. Decided by criterion 2 and nothing else: if the
  shared text is boilerplate that itself carries a rule or fact, and a
  maintainer could cut it from one member and point at the other, it is a
  **TRUE POSITIVE**; if the members share only a frame, function words, and a
  subject noun, it is a **FALSE POSITIVE**. The differing slots neither rescue
  nor condemn the pair on their own.
- **Adjacent chunks of one continued thought** in the same file (a paragraph
  and its own following list item). **FALSE POSITIVE**: continuation is not
  restatement.

Every label ships with a one-line rationale in
`workflows/scripts/config/redundancy-precision-labels.tsv`, so the measurement
is auditable rather than resting on a bare verdict.

### PR-6 — A negative result is a result

If the measured precision is below `REDUNDANCY_PRECISION_THRESHOLD_PCT`, or the
sample is below `REDUNDANCY_PRECISION_MIN_SAMPLE`, the recorded outcome is
**NO-GO**, the finding is shipped as-is, and no attempt is made to reach the
bar by re-tuning the detector against the labels and re-measuring. temperloop
#831 (declared-expiry check) is the worked precedent: a pre-registered NO-GO
routed a re-scope and was a useful, legitimate outcome.

If a later, differently-designed detector is worth measuring, it gets its own
pre-registration section here and its own labelled sample. It does not inherit
this one.

### PR-7 — What was already known when this section was written

Stated so a reader can audit the pre-registration rather than take it on faith.

**Known:**

- The always-loaded surface, as `chunk-redundancy-surface.sh` emits it today,
  is **32 chunks over 29 manifest rows** — 4 chunks from the root `CLAUDE.md`
  plus one `frontmatter:description` chunk from each of 28 command/agent files.
  That is 496 unordered pairs. This was checked because the minimum sample size
  in PR-3 is meaningless if the surface cannot produce 10 candidates.
- A throwaway prototype was run to confirm the fixture corpus is separable at
  all (otherwise there would be nothing to pre-register a threshold *for*), and
  its unlabelled top-20 pair ranking was inspected — pair identifiers only.

**Not known:** any label, any true/false-positive verdict on any real-surface
pair, and any precision figure. No pair over the real surface had been labelled
under PR-5's protocol when PR-2 and PR-3 were fixed.

---

## Method

*Written after § Pre-registration was committed and before the labels were
applied. Nothing here changes a pre-registered parameter; it records how the
detector arrived at a score.*

### M-1 — What the approach is, and what it deliberately is not

The acceptance left the approach unspecified — "embedding similarity, an
LLM-judge pass, or a hybrid ... discoverable only by trying". What shipped is
**none of those**: a deterministic, offline, stdlib-only lexical-semantic
scorer. The reason is a constraint the epic's other Phase-A tooling already
lives under and this half inherits — `count-prose.sh`, the chunker, and the
declared-expiry check are all byte-identical across macOS and Linux CI, run
with no network, and add no model dependency. An embedding or LLM-judge pass
would have bought a better paraphrase signal at the cost of a non-deterministic,
network-bound, credential-bearing dependency in a measurement whose entire
purpose is to decide whether a *gate* is warranted. That trade is recorded here
rather than hidden, because it plausibly explains part of the result in
§ Findings: **a stronger detector might clear the bar this one missed.** What
that would take is named in F-6.

### M-2 — Normalisation

Each chunk's `text` becomes a token multiset: lowercased, markdown punctuation
stripped, split on non-alphanumerics, English number-words folded to digits
(`forty` → `40`), stopwords dropped, and a crude longest-suffix-first stem
applied. Every step is a generic English/markdown transformation. There is **no
synonym table** — one hand-fitted to the fixture pairs would inflate the fixture
pass and say nothing about the real surface.

### M-3 — Relaxed matching, which is what makes paraphrase register at all

Two stems match when they are equal, **or** when one is a ≥4-character prefix
or substring of the other. That single relaxation is what lets a paraphrase
score above noise without a synonym list: `feat`~`feature`, `fix`~`bugfix`,
`doc`~`documentation`, `test`~`testing`. It is blunt and it over-matches
(`cap`~`capture`), which is a real contributor to the false-positive rate in
§ Findings rather than a footnote.

### M-4 — The pair score

- `d(A→B)` = the share of A's **IDF-weighted** token mass that finds a relaxed
  match in B; `d(B→A)` likewise. IDF is computed over the corpus being scored,
  so a pair cannot rank on shared house vocabulary alone.
- `overlap` = `min(d(A→B), d(B→A))` — symmetric and deliberately conservative.
- `verbatim` = 5-gram shingle containment, which catches straight copy-paste
  that the IDF path could under-rate.
- `score` = `max(overlap, verbatim)`.
- **`dup_bytes` = `min(d(A→B)·bytes(A), d(B→A)·bytes(B))`** — the duplicated
  byte mass, taken as the smaller of the two sides' matched mass: the bytes
  recoverable whichever member a maintainer chooses to cut. **This, not the
  score, is the ranking key**, per the acceptance's "ranked by the byte weight
  of the duplication". It is an estimate from matched IDF share, not an exact
  diff — F-4 reports how close the estimate actually landed.

### M-5 — Deliberate-pointer suppression

A chunk that **defers by name** to a canonical rule and states only what is
specific to its own context is not a restatement. A pair either of whose
members carries a *strong* deference marker (`not repeated here`, `rather than
restating`, `described in`, `defers to`, `see X for`, `thin pointer`, …) is
moved to a **reported** suppressed bucket, never silently dropped. The weak
topical word "canonical" alone does **not** qualify — a rule may legitimately
call itself canonical while being the thing restated elsewhere.

This is a separate mechanism from the score, because the deliberate-pointer
negative is not a *low-similarity* case: on #854's corpus it scores 0.185,
**above** the lower of the two positives (0.181). Ranking alone cannot separate
them; naming the deferral can.

### M-6 — Fixture calibration of the candidate floor (PR-4's calibration, done)

Scored against #854's corpus alone, at fixture-corpus IDF:

| fixture | label | score | outcome |
|---|---|---|---|
| `positive-branch-naming-paraphrase` | positive | 0.181 | flagged |
| `positive-board-adapter-budget-paraphrase` | positive | 0.228 | flagged |
| `negative-ci-branch-policy-pointer` | negative | 0.185 | suppressed as a deliberate pointer |
| `negative-token-rules-near-miss` | negative | 0.134 | below floor |

The floor is set by a **stated rule**, not a hand-picked number: the midpoint
between the highest-scoring *unsuppressed* negative (0.134) and the
lowest-scoring positive (0.181), rounded to the nearest whole percent → **16%**
(`REDUNDANCY_SCORE_FLOOR_PCT`). All four fixtures classify correctly there, and
every positive pair does so with a **verbatim 5-gram score of exactly 0.000** —
they are carried entirely by the paraphrase path, which is the acceptance
bullet "paraphrase, not just copy-paste" in its checkable form.

**A stated limit of this calibration:** the fixture corpus is 8 short synthetic
documents and the real surface is 32 real ones, so the two IDF distributions
differ. The floor transfers as a ratio, not as a guarantee — the same pair
scores somewhat differently under the two corpora. Calibrating on the surface
instead would be the tuning PR-4 forbids, so this is an accepted, disclosed
imprecision rather than a fixed one.

---

## Findings

*Measured 2026-08-02 against the always-loaded surface at this commit. The
threshold and protocol these are judged against were fixed before the detector
existed — see § Pre-registration and `git log` on this file.*

### F-1 — The recorded verdict

> **NO-GO.** Measured precision **58.3% (7 true positives of 12 hand-labelled
> pairs, n=12)**, against a pre-registered threshold of 80% over a minimum
> sample of 10.
>
> A Phase-B redundancy gate is **not warranted on this detector**. Per PR-6 the
> detector was **not** re-tuned against these labels and re-measured.

This is the outcome PR-6 and the acceptance both anticipated ("if no approach
reaches the threshold, that is recorded as a finding and passes"), and it is
the same shape as temperloop#831's pre-registered NO-GO. The ranked findings
below are shipped regardless: they are useful as a **report**, which is exactly
the disposition a sub-threshold precision figure supports.

### F-2 — The surface, and what the detector found on it

32 chunks over 29 files, **14,624 B** total — 496 unordered pairs scored. Of
those: **46 candidates** above the 16% floor, **2 pointer-suppressed**, **0
verbatim-identical** pairs (nothing on this surface is a straight copy-paste;
every finding is a paraphrase or template finding).

Both suppressed pairs are inside the root `CLAUDE.md`, which is by its own
first sentence "a thin pointer, not the contract itself" — suppressing pairs
within it is the mechanism working, not a miss.

### F-3 — The ranked findings (top 12, the hand-labelled sample)

Rank / duplicated bytes / score / verdict under PR-5. Rationales for each are
in `workflows/scripts/config/redundancy-precision-labels.tsv`; the live listing
is `workflows/scripts/score-redundancy.sh`.

| # | ~dup B | score | pair | PR-5 |
|---|---|---|---|---|
| 1 | 502 | 0.734 | `consultant-persona` ↔ `team-member-persona` | **TP** |
| 2 | 472 | 0.730 | `hobbyist-persona` ↔ `team-member-persona` | **TP** |
| 3 | 464 | 0.730 | `consultant-persona` ↔ `hobbyist-persona` | **TP** |
| 4 | 210 | 0.415 | `pipeline-drive-merge` ↔ `pipeline-drive` | FP |
| 5 | 174 | 0.242 | `fix` ↔ `sweep` | FP |
| 6 | 162 | 0.460 | `go-reviewer` ↔ `swift-reviewer` | **TP** |
| 7 | 154 | 0.194 | `assess` ↔ `workshop` | FP |
| 8 | 150 | 0.182 | `assess` ↔ `triage` | FP |
| 9 | 149 | 0.180 | `sweep` ↔ `triage` | FP |
| 10 | 146 | 0.481 | `go-reviewer` ↔ `java-reviewer` | **TP** |
| 11 | 144 | 0.410 | `java-reviewer` ↔ `swift-reviewer` | **TP** |
| 12 | 142 | 0.404 | `java-reviewer` ↔ `typescript-reviewer` | **TP** |

**The two real duplication clusters, which are worth acting on whatever the
gate decision is** (Phase B subtraction, and per #855's own note not blocked
behind `phase-b-backtest` — a rule stated twice is waste under any policy):

- **The three customer-persona descriptions** (1,970 B, 13.5% of the surface).
  Any two of them share **507 bytes of byte-identical text in runs of ≥20
  characters, the longest a single unbroken 318-character run**: the two-variant
  EXECUTING/OPINING contract, the `/workshop` Step 3.2/3.3 routing, the
  value-set provenance rule, and executing-outranks-opining — four rules stated
  three times over. Only the archetype clause is genuinely per-file.
- **The seven language-reviewer descriptions** (2,436 B, 16.7% of the surface).
  Each restates the same four rules — independent/read-only/advisory, scored
  against the language's own idioms and tooling never taste, an inert catalog
  reviewer an adopter opts into, scoped to a PR touching the extension — with
  148–190 bytes of identical runs between any two.

Together those two clusters are **30.2% of everything a stranger's session
loads before typing a word**, and most of that share is one contract stated
three or seven times.

### F-4 — The ranking key is sound even though the classifier is not

Worth separating, because it decides what the NO-GO does and does not condemn.
Against an exact longest-common-substring measurement, the estimated
`dup_bytes` was close on the true positives: 502 estimated vs 507 actual for
the top persona pair, 146 vs 148 for `go`↔`java`. **Ranking by duplicated-byte
weight put the genuinely largest duplication first** — ranks 1–3 are the
biggest real duplication on the surface, and a reader handed this report reads
the right rows first.

What failed is **discrimination in the middle of the ranking**, not the
ordering.

### F-5 — Where the five false positives came from

All five are the same error, and PR-5 disposed of that error class in advance
(cases 2 and 3): **two chunks about one subject, stating different rules**.
Ranks 4, 5, 7, 8 and 9 are all pairs of sibling pipeline commands — `assess`↔
`triage`, `sweep`↔`triage`, `fix`↔`sweep`, `assess`↔`workshop`, and the two
`pipeline-drive` tiers — that share house vocabulary (board, epic, claim,
isolated worker, PR, CI) and frequently name each other as peers, while
governing genuinely different actions. Rank 4 is the sharpest case: 5b
**structurally cannot merge** and 5c **merges only via `/build`'s gated path**,
which is close to the opposite rule, scored at 0.415.

IDF weighting was supposed to prevent exactly this and did not: on a 32-chunk
corpus where most chunks *are* pipeline-command descriptions, "board" and
"epic" are not rare enough to be discounted, and M-3's relaxed prefix matching
widens the collision. A cross-reference between two commands — the thing a
well-linked surface is *supposed* to have — is indistinguishable to this
detector from a restatement.

### F-6 — What would have to change for a future GO

Named so this NO-GO routes a re-scope rather than closing the question, and so
a later attempt gets its own pre-registration (PR-6) instead of inheriting this
one:

1. **A predicate-level signal, not a bag of terms.** Every false positive
   shares a subject and differs in the *action* governed. A detector that
   compared the deontic clause (what is required, forbidden, permitted) rather
   than the term distribution would separate all five without touching the
   seven true positives.
2. **An embedding or LLM-judge pass** would very likely clear 80% here — the
   cases are easy for a reader — at the determinism and dependency cost M-1
   declined. If Phase B ever wants the gate, that trade is the decision to
   revisit, and it should be measured, not assumed.
3. **A bigger labelled sample.** n=12 is the pre-registered minimum plus two.
   The surface only affords 46 candidates in total, so a materially larger
   sample needs a larger surface — which the consumer-checkout measurement
   (`contributor-manifest.tsv`'s own "future work, not yet built") would supply.

### F-7 — Stated limits of this measurement

- **Precision only, no recall.** Nothing here measures what the detector
  *missed*. A pair that states one rule twice in wholly unrelated vocabulary
  scores below the floor and is invisible to this figure.
- **One surface, one point in time.** 32 chunks of a kernel-only checkout. A
  consumer checkout carrying an installed overlay and its own project
  `CLAUDE.md` is roughly an order of magnitude larger and is **not** measured
  here (`contributor-manifest.tsv` § coverage claim).
- **One labeller, one pass.** No second rater, so no inter-rater agreement
  figure. PR-5's protocol and the per-row rationales are what make the labels
  auditable instead; a reader who disagrees with a verdict can see exactly
  which criterion it turned on.
- **The floor transfers imprecisely between the two corpora** (M-6).
