- **A `/build` worker whose item carries a class-A `activation:` block now sees
  its own reachability check spelled out verbatim in its brief**
  (temperloop#1934). Previously the worker never saw the check it would be
  gated on, so a correctly built and wired feature could still fail the gate
  over a name only the check's author had chosen.
