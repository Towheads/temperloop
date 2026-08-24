- **`plan-schema.md` § Optional `model:` field gains Carve-out (b) — silent
  failure mode** (#1286). An `S`/`M` `kind: code` item whose own failure mode is
  invisible to CI and to its own acceptance gates — a guard that can fail open, a
  detector that can fail to detect — now leaves `model:` absent (inherits the
  session model) instead of being stamped `sonnet`. The carve-out ships its own
  two-limb trigger condition, so `/assess` applies it uniformly rather than
  re-deriving the judgment per plan. The default S/M→`sonnet` stamp and the
  existing spec-prose Carve-out (a) are unchanged; the K#671 anti-pattern note now
  names a carve-out in this section as the *only* sanctioned route to a tier
  deviation, keeping inline per-plan exceptions discouraged.
