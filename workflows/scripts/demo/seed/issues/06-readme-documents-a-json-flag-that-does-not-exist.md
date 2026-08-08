# The README documents a `--json` flag that does not exist

`README.md` § Usage advertises:

```
python3 linkrot.py --json .        # machine-readable output
```

There is no argument parsing in `main()` at all — the first argument is taken
as the directory to scan, so `--json` is treated as a path, `os.walk()` finds
nothing under it, and the tool prints nothing and exits successfully. A
reader following the README concludes the repository is clean.

Two honest resolutions, and the choice is the interesting part:

- implement `--json`, emitting the findings as a machine-readable document
  (and then `format_report()` is one of two renderers, not the only one), or
- delete the line from the README and stop promising it.

Either is acceptable; silently leaving both the promise and the gap is not.

Acceptance (falsifiable):

- `python3 linkrot.py --json .` either produces parseable machine-readable
  output, or fails with a usage error naming the unknown option — it never
  silently scans nothing and exits 0
- `README.md` and `docs/getting-started.md` describe only flags the tool
  actually accepts
- the suite gains a case pinning whichever behaviour was chosen
