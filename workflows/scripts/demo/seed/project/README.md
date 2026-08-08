# linkrot

A tiny Markdown link checker. Point it at a directory and it walks every
`.md` file under it, pulls out the inline links, and prints the ones whose
target does not resolve to a file that exists.

```
$ python3 linkrot.py .
broken: ./docs/getting-started.md -> ../README.md
broken: ./docs/getting-started.md -> #an-example-run
broken: ./docs/getting-started.md -> ./CONTRIBUTE.md
broken: ./docs/getting-started.md -> https://commonmark.org/
```

Exactly one of those four findings is a real broken link. The open issues are
about the other three.

## Usage

```
python3 linkrot.py [DIRECTORY]     # defaults to the current directory
python3 linkrot.py --json .        # machine-readable output
```

`linkrot` exits non-zero when it finds a broken link, so it drops into a
pre-commit hook or a CI step without any glue.

## Running the tests

```
python3 -m unittest discover -s . -p 'test_*.py'
```

The suite is green as committed. The open issues describe behaviour it does
**not** cover yet — that is the work, and each issue names the check that
proves it done.

## Where things live

- `linkrot.py` — the whole checker: link extraction, target classification,
  the file walk, and the CLI entry point.
- `test_linkrot.py` — the unit suite.
- `docs/getting-started.md` — a short walkthrough, and a realistic corpus for
  `linkrot` to scan against itself.
- [Contributing](CONTRIBUTING.md) — how to propose a change.
