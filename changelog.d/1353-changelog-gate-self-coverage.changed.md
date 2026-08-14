The contract-surface table in `VERSIONING.md` now carries a row for the changelog
machinery itself — `check-changelog-entry.sh`, `lib/changelog.sh`,
`assemble-changelog.sh` and `VERSIONING.md`. The gate parses that table at run
time to decide what counts as contract surface, and the table did not previously
cover the gate, so a change to the release-entry contract resolved to no
contract-surface path and required no entry. A breaking change to that machinery
shipped an entry only because its author volunteered one.

Categorised `changed` rather than `.breaking`: a vendoring overlay need do
nothing to keep working. The effect is that a pull request touching those paths
now owes an entry like any other contract-surface change, and the existing
opt-out marker still applies. Measured against the last ten merged pull
requests, none would newly owe an entry.
