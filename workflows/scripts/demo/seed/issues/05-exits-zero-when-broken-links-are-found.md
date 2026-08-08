# `linkrot` exits 0 even when it reports broken links

`main()` returns `0` unconditionally. Every finding is printed and then the
process reports success, so the documented "drops into a pre-commit hook or a
CI step without any glue" is not true today — the step is green no matter
what the tool found.

Repro:

```
$ python3 linkrot.py . | wc -l
       4
$ python3 linkrot.py . >/dev/null ; echo "exit=$?"
exit=0
```

Expected: a clean scan exits `0`; a scan with at least one finding exits
non-zero. A crash (an unreadable file, a bad argument) has to stay
distinguishable from "found problems" rather than collapsing into the same
code.

Acceptance (falsifiable):

- a tree with no broken links exits `0`
- a tree with one or more broken links exits non-zero
- the exit code for a scan failure is not the same as the exit code for
  findings
- the suite gains a case for each and stays green

Note this one is independent of the classification issues — but landing it
first means every later fix is verified by the exit code rather than by
eyeballing the output.
