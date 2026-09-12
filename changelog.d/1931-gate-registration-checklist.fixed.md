- **A `/build` worker adding a new gate or validator script is now told to
  register it before running its own gate check** (temperloop#1931).
  Previously a worker could add a new check script without registering it
  anywhere the gate system would notice, so the omission surfaced only later,
  in the slower full-suite gate.
