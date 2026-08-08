# Getting started with linkrot

A five-minute walkthrough. See the [project README](../README.md) for the
short version, or jump straight to [the example run](#an-example-run).

## Install

There is nothing to install. `linkrot` is one module with no dependencies
beyond the Python standard library, so a checkout is enough:

```
git clone <this repository>
cd linkrot
python3 linkrot.py .
```

## An example run

Point it at a directory:

```
$ python3 linkrot.py docs
```

One of the findings is real: this page links to
[the contributing guide](./CONTRIBUTE.md), which does not exist — the file is
called `CONTRIBUTING.md`. Fixing the link is a fine first change, but the more
interesting question is which of the *other* findings `linkrot` should never
have printed.

## What counts as a link

`linkrot` reads the inline link form: a bracketed label followed immediately
by a parenthesised target. That is the common case, and it is the only case
the scanner currently knows about.

[The CommonMark spec](https://commonmark.org/) also defines
[reference-style links][commonmark], which look like this:

```
See [the guide][guide] for details.

[guide]: guide.md
```

[commonmark]: https://commonmark.org/

## Next steps

Run the suite, read the open issues, and pick one:

```
python3 -m unittest discover -s . -p 'test_*.py'
```
