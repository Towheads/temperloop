- **`docs-reviewer` now states what makes a finding HIGH, and register/
  shorthand findings can no longer be graded HIGH** (#2136). The agent
  previously carried zero severity criteria, so grading was effectively a
  coin flip per review pass — the same shorthand/reference-token rule
  landed as a blocking HIGH on some PRs and an advisory MEDIUM on others.
  `claude/agents/docs-reviewer.md` now defines HIGH as a factual error a
  stranger would act on (a wrong issue number, a claim the code
  contradicts, a broken invariant statement), and fixes register/shorthand/
  first-mention-hook/reference-token findings at MEDIUM by construction.
- **A new mechanical lint catches the register defects `changelog.d/`
  fragments kept losing to a one-round-late review finding** (#2136).
  `workflows/scripts/config/check-changelog-fragment-register.sh`, wired
  into `scripts/quality-gates.sh`'s `checks` gate, fails a fragment whose
  first issue mention has no bold title hook, that carries bare
  `K<N>`/`S<N>`/`F<N>`/`M<N>`/`W<N>`-style cross-repo shorthand, or that
  names one of two internal-jargon phrases `docs-reviewer` itself lists as
  unexplained-shorthand examples. Deliberately narrower than
  `changelog.d/README.md`'s full register rule — see the checker's own
  header for why its step-letter/section-index pattern (a numbered build
  step, a section-symbol reference) stays a `docs-reviewer` judgment call
  instead of a mechanical ban.
