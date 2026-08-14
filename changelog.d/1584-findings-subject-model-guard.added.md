- **`findings_integrity.py` now catches a null `subject_model` that should
  have been populated** (#1584). Findings records have carried
  `subject_model: null` while `analyst_model` is populated, collapsing the
  attribution split that exists so a defect is credited to the model that
  *produced* it rather than the one that *found* it. A new `--check-subject-model`
  mode scans every `findings-*.jsonl` record with `subject_model: null`,
  resolves its `session_id` to the archived session stub
  (`meta/sessions/archive/`, matched on the same leading-8-char `id8` the
  archiver's own filename convention uses), and flags the record with the
  literal token `SUBJECT_MODEL_MISSING` only when that stub's frontmatter
  actually carried a `model:` line — a stub that genuinely had no `model:`
  line (38% of archived stubs, 312 of 814, measured) is never flagged, since
  a false-positive-happy guard here is worse than no guard. Extends the
  single findings-integrity checker (`workflows/scripts/drain/findings_integrity.py`,
  #1576) rather than adding a parallel mechanism.
