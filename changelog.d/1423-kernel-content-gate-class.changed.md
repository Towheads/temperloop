- **Kernel gates that assert the kernel's own product content are now a
  class-gated set, so a vendoring overlay can run a release green** (#1423).
  `KERNEL_GATES` had one tier — every gate the kernel declares, every adopter
  runs — but a handful of those gates assert the CONTENT of temperloop's own
  product surfaces and resolve, through a consumer's compat symlink, to the
  consumer's root. `validate-onramp-anchors.sh` asserts this repo's README
  quickstart, installer URL and `bin/temperloop` first-run banner;
  `validate-docs-footer.sh` asserts the AI-authorship footer on this repo's
  product-docs pages. An adopter's README is a different product's README, and
  no overlay wiring makes either pass there.

  These four gates (each validator plus its test) move into a new
  `KERNEL_CONTENT_GATES` array in `scripts/quality-gates.sh`, class-gated on
  the same single signal the existing `SELF_DISTRIBUTION_GATES` class already
  uses (temperloop#691): a repo-root `.kernel-pin`, present in a vendoring
  consumer and absent in the kernel's own checkout. No new signal, no new
  config knob. In this repo all four still run; in a consumer each is named on
  its own `SKIPPED_KERNEL_GATES` line with its reason, never dropped silently.

  Deliberately NOT moved: gates that go red in a vendored tree because of a
  real upstream defect — `lint-pipe-grep-q.sh` flagging its own help text
  (temperloop#1420), and the spend report finding zero agent definitions
  through a symlinked `claude/agents` (temperloop#1424). Those must keep
  failing until they are fixed; class-gating them would bury them. The bar for
  joining the class is a positive argument that an adopter's repo cannot and
  should not satisfy the assertion — never that the gate is currently red.
