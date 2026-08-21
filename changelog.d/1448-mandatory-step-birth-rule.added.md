- **Declaring a pipeline step mandatory now requires shipping its execution
  signal in the same change, and CI enforces it** (temperloop#1448). A workflow
  spec could declare a step MANDATORY in prose while nothing observable proved
  it ever ran: `/build` §3e's command-doc reviewer pass read "mandatory" for
  ~a month while the default path structurally could not spawn a reviewer at
  all, and was found only when somebody wrote a coverage script after the fact.
  `claude/CLAUDE.kernel.md` § Mandatory-step birth rule states the contract and
  `workflows/scripts/validate-mandatory-step-signal.sh` enforces it, on the
  `validate-capture-backstop.sh` mold: every mandatory declaration in
  `claude/commands/*.md` is paired, in `mandatory-step-registry.tsv`, with an
  execution signal — a per-run tally, a gate-wired static guard, a runtime
  refusal, or a coverage rollup — and a HALF-PRESENT pair fails the build. The
  gate does not rely on anyone remembering to register: it enumerates every
  mandatory-marker line mechanically and fails any with no disposition, and its
  `pending` debt ledger is a shrink-only ratchet, so a NEW mandatory declaration
  cannot be parked as debt.
