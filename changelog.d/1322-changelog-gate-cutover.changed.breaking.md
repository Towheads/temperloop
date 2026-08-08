- **The changelog completeness gate now requires a `changelog.d/` fragment
  rather than a line under `## [Unreleased]`** (#1322).
  `workflows/scripts/check-changelog-entry.sh` fails a PR that changes contract
  surface without adding a conforming
  `changelog.d/<slug>.<category>[.breaking].md` present at HEAD; a direct
  `## [Unreleased]` line no longer satisfies it. That is what removes the merge
  collision at its source rather than routing around it — a mandatory entry in
  one file at one anchor meant 25 of the last 25 commits touched `CHANGELOG.md`
  and any two concurrent PRs conflicted by construction, while two PRs writing
  two distinct new files share no line and cannot conflict.

  Unchanged: the escape-hatch grammar (`Changelog: none|amend — <reason>`, via
  a PR label, a PR-body line or a commit trailer, reason still required), and
  the released-section-scope property with its merge-base discriminator —
  though the latter's reason to exist now narrows to the release-cut PR, the
  only PR that still edits `CHANGELOG.md` at all.

  `VERSIONING.md` § Cutting a release is rewritten to the assembler-based flow.
  Its old merge-walking `^CHANGELOG.md$` backfill loop is replaced by
  `scripts/assemble-changelog.sh --assert-empty <rev>`, a deterministic
  assertion that no unassembled fragment survives at the tagged commit. That is
  both cheaper than the loop and catches what the loop never could: the
  cut-vs-sibling **omission** race, where a cut PR deleting fragments and a
  sibling PR adding one touch disjoint files, so git merges them clean and the
  sibling's entry goes missing — not wrong — from the shipped section.

  **Migration.** A vendoring overlay must create the directory at its **own**
  repo root, not `kernel/changelog.d/`: `mkdir -p changelog.d && touch
  changelog.d/.gitkeep && git add changelog.d/.gitkeep`, then author one
  fragment per contract-surface PR. Until it does, the gate degrades legibly
  rather than breaking the build: a tree carrying `.kernel-pin` gets an
  actionable skip of the completeness property — naming its pinned kernel tag
  and that exact command — while the section-scope property keeps running. A
  tree with **neither** `changelog.d/` nor `.kernel-pin` is not a vendoring
  consumer but a kernel checkout that lost the directory, and there the gate
  fails loudly: a bare skip would let the kernel silently disable its own gate,
  which is worse than having no gate.
