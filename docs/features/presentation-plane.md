---
title: Presentation plane and the message-template layer
slug: presentation-plane
---

## Problem

A style pass that "helpfully" reformats an operator-facing message can
silently break a downstream parser reading that exact text — GitHub's
closing-keyword scanner, the build orchestrator, a shell script's `jq`
caller, a CI validator — because to a human editor, prose and machine-read
grammar look identical with no marked boundary between them. Without an
explicit index of which output surfaces are frozen, a well-intentioned
rewrite ships, looks fine in review, and only fails once whatever depended
on the exact bytes trips over it later — the same failure shape whether the
break is caught immediately or weeks on.

## How it works

**The index.** `claude/presentation-plane.md` classifies every output
surface as **frozen** (a parser reads it — do not change its literal bytes)
or **style-free** (human prose, safe to restyle). It is deliberately not a
second copy of any contract: each row names a surface, classifies it, and
points at the one place that surface's real shape is owned, so a contract
change never requires editing this index — only the pointer has to keep
resolving. The kernel table's frozen rows include: bare `Closes #N`/
`Fixes #N` lines, plan-note status sentinels and orchestrator sub-line
fields (`pr:`, `pushed_sha:`, `gh_issue:`, ...), the `speculative:`/
`escalated:` sentinels, the decision-queue reply grammar (fenced
` ```decision ` block, `/choose`, `/approve`), the `plan-approval-poll:`
marker line, the closed `.outcome` enums of `gate.sh`/`pr.sh`/`worktree.sh`/
`ci-poll.sh`, the `.build-guard` marker file, telemetry/raw-lake record
shapes, board-adapter field names/values, the `Operational`/`Foundational`
work-class labels, and the Live/Drain pairing registry table itself. Most
frozen surfaces are not whole documents but exact lines or fields embedded
inside an otherwise free-form one — a PR body is mostly style-free prose
*except* its bare `Closes #N` line and its Verification section's resolved
content; restyle the document, leave the embedded frozen line byte-for-byte
alone.

**The template layer.** `claude/message-schema.md` is the peer contract for
the kernel's **named message templates** — the recurring shapes a
template-driven output takes (the PR-body skeleton, the parking note, the
digest entry, the question block, the degradation notice), keyed to who is
reading and when. It does not re-litigate which surfaces are safe to
restyle (presentation-plane.md's job) or whether a change actually reads
better (a separate measurement-proxies concern) — it only answers what a
well-formed message contains for a given reader state. Its five named
templates are the one sanctioned surface an overlay may override: an
overlay overrides a template by writing the entire template out again under
the same name (whole-template redeclaration, never a structured delta,
since a delta needs a second drift guard tracking whether it still applies
and redeclaration needs none), later-definition-wins at compose time
(kernel content first, overlay concatenated after — the same order
`install-claude-md.sh` already composes `CLAUDE.md` in), a checkout with no
overlay override is byte-identical to the kernel definition by construction,
and an overlay override whose name matches no real kernel template is a
dangling override — a lint failure, not a silent no-op.

**The gate.** `workflows/scripts/validate-template-refs.sh` is three
independent static checks — no runtime message rendering is inspected,
since that would be a false floor, not something CI can check
mechanically:

1. **Reference-integrity** — every by-name mention of a template (a bolded
   name immediately followed by "template") in `CLAUDE.kernel.md` or
   `claude/commands/*.md` must name a template actually defined under
   `message-schema.md`'s `## Templates` section. A renamed, typo'd, or
   retired template name still referenced elsewhere is caught here.
2. **Dangling-override** — every redeclaration in the optional overlay file
   (`MESSAGE_SCHEMA_OVERLAY`, default `claude/message-schema.overlay.md`,
   absent in a bare kernel checkout — absent means zero overrides to check,
   a trivial pass, not an error) must match a kernel-defined template name.
3. **Registry-completeness** — every frozen row in
   `presentation-plane.md`'s kernel table must name a resolvable owner:
   every backticked, path-shaped token in its "Owning contract / parser"
   column must exist on disk, and every single `§ <Section>` pointer must
   resolve to a real heading or bold-label anchor in the file it follows.

## Integration

Consumes: `claude/CLAUDE.kernel.md`, `claude/commands/*.md`,
`claude/message-schema.md`, `claude/presentation-plane.md`, and (when
present) the overlay's `claude/message-schema.overlay.md`. Produces: a
pass/fail verdict wired into `scripts/quality-gates.sh` as a `checks` gate
(the `validate-template-refs` Makefile target). Consumed by:
`install-claude-md.sh`, which deploys these markdown files to `~/.claude/`
via the same `claude/*` install glob used for `plan-schema.md`; and by any
command-spec or style-template author, who is expected to consult this
index before restyling an output surface.

## Resource impact

Runtime: pure bash text-scanning over a handful of markdown files, well
under a second, no network, no subprocess beyond the shell itself. Storage:
none beyond the tracked markdown files. API/network budget: zero — a purely
static lint.

## Telemetry

None dedicated. Observable via the `validate-template-refs` gate's own exit
code and printed failure list (frozen-surface reference mismatches,
dangling overrides, unresolved registry pointers). A break here means
someone edited a frozen surface's wording and the mechanical check refused
the change, rather than the change failing silently further downstream.
