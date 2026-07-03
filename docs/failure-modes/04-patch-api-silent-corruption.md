---
title: A "success" response that hides a structural corruption
---

## The failure

A note-taking tool's REST API exposes a "patch" operation for inserting
content relative to a heading, in addition to whole-file read/write. The
appeal is obvious: patch a specific section without re-sending the entire
document. Automation built against this API used the patch operation
routinely — appending a bullet under a named heading, or replacing a
section's contents — and trusted the tool's success response as
confirmation the edit landed where intended.

It didn't, reliably. Two independent failure shapes showed up on the same
API surface:

1. **Appending to a heading target sometimes created a brand-new, wrongly-
   nested heading at the end of the file instead of inserting inside the
   existing section.** The response still said the patch succeeded. The
   original section was left completely untouched, and a duplicate heading
   — with the new content under it — appeared appended at the very end of
   the document, silently forking the "same" section into two places.
2. **Replacing a section's content, under sustained repeated use, exhibited
   the identical failure**: the original section survived unchanged *and* a
   duplicate section was appended at end-of-file, rather than the original
   being replaced in place. This corrupted any document that depended on
   there being exactly one instance of that section — a later reader,
   or a later patch targeting the same heading, would now find two.

In both cases the tool's response was indistinguishable from a correct
patch. The only way to know something had gone wrong was to read the file
back afterward and check.

## The mechanism

The patch API accepted a bare heading name as its target and resolved it
against the document's heading structure at request time. When that
resolution failed to find (or mis-resolved) the intended section — for
reasons never fully isolated on that surface, but reproducible on demand —
it fell back to *synthesizing* a heading and appending, rather than erroring
out. That fallback is the actual bug: a partial-match or no-match condition
that should have been a loud failure was instead silently treated as "create
this section fresh," which is a completely different operation from the one
requested, executed under the same "success" status.

Trusting a mutation API's response code as proof of the mutation's *effect*
— rather than just proof the *call* didn't error — is the general trap.
Success/failure of the request and correctness of the resulting state are
two different claims, and an API can conflate them by treating "I did
something and didn't crash" as success even when what it did wasn't what was
asked for.

A second, independent API on the same underlying document store — one that
first fetches a fully-qualified nested path to the target section rather
than accepting a bare heading name, and returns a **hard error** ("target
not found") instead of a silent fallback when the target can't be resolved
unambiguously — did not exhibit the bug at all under the same repro steps.
That comparison is what pinned the failure to the fallback behavior of the
first API rather than to the underlying document format or store.

## The guard

- **Prefer the API that fails loudly over the one that fails silently**,
  even when it requires an extra lookup first (resolving the exact, fully-
  qualified target path before patching) rather than a convenient bare
  name.
- **Never treat a mutation's success response as proof of correct
  placement** for an operation whose target resolution is anything less
  than exact-match. Where the stakes are real (a document another process
  depends on being well-formed), read the affected section back after the
  patch and confirm the change landed where intended before moving on.
- **For structural changes whose targeting is uncertain — a freshly created
  section, an ambiguous or duplicated heading name — skip the incremental
  patch entirely and do a full-document rewrite.** A full rewrite can't
  mis-resolve a target because there's no target resolution involved; it's
  a strictly less efficient but strictly more correct operation, and the
  right default whenever the patch surface's failure mode has already been
  observed on the shape of edit being attempted.

The general lesson: an incremental "patch this part of a larger document"
API is a convenience with a hidden dependency on correct target resolution,
and any resolution ambiguity it doesn't turn into a hard error becomes a
silent corruption risk. When two APIs are available over the same
underlying data — one fuzzy-matching-and-fallback, one exact-match-or-error
— prefer the one that errs, and reserve the convenient one for cases where
you've already verified its failure mode isn't in play.
