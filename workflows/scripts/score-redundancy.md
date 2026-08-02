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
