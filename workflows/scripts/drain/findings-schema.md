# Findings Record Schema — v2

## Purpose

A **findings record** is one row emitted per extraction that `/tidy` produces
during Step 3. Every extraction — whether it came from a lexicon tell or from the
model skimming `report.user_turns[]` — writes one record here so the full
extraction history is queryable and the lexicon's measured miss-rate is visible.

This schema is the **SSOT** for the findings record. Downstream consumers (e.g.
the telemetry epic) MUST reference this file, not define their own shape. When the
schema evolves, bump `schema_version` and add a migration note below.

---

## Schema — v2

| Field            | Type                                    | R/O      | Description |
|------------------|-----------------------------------------|----------|-------------|
| `schema_version` | string                                  | required | Always `"2"` for this revision. (Readers also accept `"1"` for legacy records — see § Schema evolution.) |
| `ts`             | string                                  | required | ISO-8601 timestamp of the drain run (e.g. `"2026-06-12T14:30:00Z"`). |
| `session_id`     | string                                  | required | Session UUID from `report.stub.session_id`. |
| `project`        | string                                  | required | Project name from `report.stub.project`. |
| `method`         | `drain-lexicon` \| `drain-model-skim`   | required | How the extraction was found. `drain-lexicon` = a tell in `report.lexicon_matches[]` triggered it. `drain-model-skim` = the model found it in `report.user_turns[]` with no matching lexicon tell. |
| `sub_method`     | string \| null                          | required | For `drain-lexicon`: the specific tell (`lexicon_match.tell`) that fired. For `drain-model-skim`: `null`. |
| `finding_type`   | enum (see below)                        | required | Semantic category of the extraction. |
| `finding_ref`    | string                                  | required | Durable artifact reference. For vault notes: path relative to vault root (e.g. `"Decisions/foundation - Foo.md"`). For GitHub issues/PRs: `"#N"` or `"owner/repo#N"`. For auto-memory files: the memory filename (e.g. `"feedback_topic.md"`). For Things tasks: `"things:<title>"`. |
| `accepted`       | boolean                                 | required | `true` if the extraction became a real tracked artifact. `false` if adjudicated as noise, duplicate, or already-captured-live and skipped. |
| `subject_model`  | string \| null                          | required (v2) | **The analyzed-session model** — the model whose behavior the extraction is about, taken from the stub's `model:` field (`report.stub.model`). This is the same value a curated note stamps as `source_model`. `null` when the stub carried no `model:` line or it is otherwise unknown. |
| `analyst_model`  | string \| null                          | required (v2) | **The drain-runner model** — the model that ran `/tidy` and produced this record (the curated-note `extracted_by_model`). On a live capture these two are the same model; in `/tidy` they differ when the drain runs under a different model than the analyzed session. `null` when unknown. |

### `finding_type` values

| Value          | Meaning |
|----------------|---------|
| `decision`     | Architectural, product, or process choice written to `Decisions/`. |
| `defect`       | Unfiled defect filed to the board via `capture.sh`. |
| `pattern`      | Reusable approach written to `Patterns/`. |
| `mistake`      | Pitfall written to `Mistakes/`. |
| `feedback`     | User correction or confirmation saved to auto-memory (`feedback_*.md`). |
| `friction`     | Tooling-friction event appended to the friction ledger. |
| `optimization` | Session optimization tool appended to the toolkit. |
| `deferral`     | Pending decision backfilled to the pending-decisions surface. |

---

## Storage

Findings records are **append-only**. Each drain run appends its records (one JSON
object per line, newline-delimited) to:

```
meta/data/raw/findings-<YYYY-MM>.jsonl
```

One file per calendar month, rotated on the first drain run of a new month. This
matches the append-only convention of `meta/data/raw/` (documented in
`foundation/CLAUDE.md` § Raw data in `meta/data/raw/` is append-only).

Example record:

```json
{"schema_version":"2","ts":"2026-06-12T14:30:00Z","session_id":"abc123","project":"foundation","method":"drain-model-skim","sub_method":null,"finding_type":"decision","finding_ref":"Decisions/foundation - Foo.md","accepted":true,"subject_model":"claude-opus-4-8","analyst_model":"claude-opus-4-8"}
```

---

## Model-skim miss tracking

Records with `method: "drain-model-skim"` and `accepted: true` are the lexicon's
**measured misses** — the model caught something the lexicon did not. These flow
into the candidate-tells file (see `candidate-tells-format.md` in this directory)
so the lexicon can grow from its own misses. `check-in` reviews the
candidate-tells file and the operator promotes or discards each candidate.

Because v2 records also carry `subject_model`, tell firings and miss rates are
**model-segmentable** — "which model exhibits tell X" — via the
`findings-tell-daily.jsonl` rollup, which buckets per `(date, tell, subject_model)`.

---

## Schema evolution

| Version | Date       | Change |
|---------|------------|--------|
| 1       | 2026-06-12 | Initial definition. |
| 2       | 2026-06-17 | Added `subject_model` (analyzed-session model, from the stub `model:` field) and `analyst_model` (drain-runner model) for model-segmented candidate-tell aggregation (F#465, follow-up to F#464's vault provenance schema). **Migration:** legacy v1 records (no model fields) remain valid on read — `findings.py` / `validate_telemetry.check_findings_quality` accept both `"1"` and `"2"`, requiring the two model fields **only** on v2 records and rejecting them on v1 records. The current writer emits v2 (the model fields default to `null` when the caller supplies no model). No back-fill of existing v1 rows is performed; the `findings-tell-daily` rollup treats a missing/null `subject_model` as the empty-string segment. |
