A new gate catches a script that has lost its executable bit. Every gate invokes
scripts as `bash <path>` or through a make target, so the bit is invisible to CI
and a script could ship non-executable indefinitely and stay green — it was
caught twice by hand, both times surfacing only as an incidental `mode change`
line in rebase output.

Keyed to an explicit registry (`workflows/scripts/config/exec-bit-registry.tsv`)
rather than the shebang rule the originating issue proposed. Measured against
this tree, that rule fired on 96 files — roughly 35 sourced libraries, 58 test
harnesses invoked as `bash test_x.sh`, 2 sourced config files, and 15 others —
of which exactly one was a genuine defect. The registry lists the files that must
carry the bit, so absence of an entry is not a finding.

A grandfather allowlist exists with a shrink-only ratchet, and is currently
empty: an opt-in registry needs nothing grandfathered. The gate fails closed on
an absent, unreadable or empty registry rather than passing with nothing checked.
