# AGENTS.md

Working notes for an agent in this repo, which holds **opp**, the Oberon
pretty printer. opp reformats Oberon-2 source written for **poc** (the
Peaseblossom Oberon Compiler) or **voc** (Vishap Oberon), with all of
both compilers' syntax extensions, to a maximum line length, in one of
three modes: one statement per line (`-1`, the default), short statements
and declarations packed onto shared lines (`-p`), or the author's own
grouping kept while it fits (`-k`).
`PLAN.md` is the roadmap and the record of design decisions.

## Where the language comes from

- **poc**: `~/Repos/Oberon/Peaseblossom-main/` (the `main` branch) and
  `~/Repos/Oberon/Peaseblossom/` (the `vax` branch). Their front ends
  accept the same syntax (only a comment differs in `src/front/Lexer.Mod`),
  so one grammar covers both. The authorities are `src/front/Lexer.Mod`,
  `src/front/Parser.Mod`, and poc's `AGENTS.md`, "Language extensions
  beyond Oberon2.pdf" (full text in `doc/developer/language-extensions.md`).
  Read them before changing what opp accepts, and check both branches
  again when either changes its front end.
- **voc**: read-only source at `/usr/local/sw/src/lang/Oberon/vishap/compiler`.
  The scanner is `src/compiler/OPS.Mod`, the parser `src/compiler/OPP.Mod`.
  `doc/Features.md` lists voc's extensions, but its syntax extensions are
  only in `OPP.Mod`.
- Where poc and voc differ, opp accepts the union: anything either compiler
  parses, opp should parse and reproduce. opp does **no** semantic checks
  and never needs a symbol table: a type guard and a call, or a qualident
  and a field selection, print the same way.

## Build / test

opp follows the layout of `~/Repos/Oberon/Ropes` and `oberon-tools`:

```sh
make                 # build Opp with voc
make test            # build, then run tests/*.test; ends "N ok, M failed"
make corpus          # format large bodies of real Oberon and check them (PLAN.md)
make install         # copy Opp to ~/local/bin as opp (BINDIR to change)
make -f pocGNUmakefile test-poc   # build with poc in poc-build/, then test
make -f pocGNUmakefile install    # install the poc build as opp
tests/run-tests.sh -o NAME ...    # selected fixtures, with their real output
```

- The program module is `Opp.Mod`, so voc and poc build an executable
  named `Opp`; `make install` installs it as `opp`, as `oberon-tools`
  installs `OModPath` as `omodpath`. Both builds install to the same
  place under the same name, so the last one installed wins.
- `ArgParser` and `Err` are shared modules, not in this repo. The voc
  build finds `ArgParser.Mod` and `Err.Mod` through `vpath` in
  `VOC_OBERON_MODULES` (default `/usr/local/sw/versions/oberon/voc/include`);
  the poc build takes ArgParser from the poc library `argparser` under
  `POC_OBERON_LIBRARIES` (default `/usr/local/sw/versions/oberon/poc/lib`)
  and `Err` from poc's runtime. Change them in `~/Repos/Oberon/ArgParser`,
  never here. Reinstall the `argparser` library after upgrading poc: poc
  refuses a library another version built.
- opp deliberately does **not** use `Ropes.Mod`: it reads a file once and
  scans it left to right, and its output only grows at the end, so a flat
  buffer (`OppText`) is simpler and faster, and opp needs no third shared
  library (PLAN.md, "Decisions").
- `pocGNUmakefile` builds in `poc-build/`, where the sources are symlinked,
  so poc's symbol files do not overwrite voc's and poc does not mistake
  voc's generated `.c` files for modules' C parts.
- **`OppDocTest` is the in-process check battery** of the layout engine,
  run by `tests/opp-doc-selftest.test`, which embeds its output: after
  adding a check, regenerate that fixture from a real run. Prove a new
  check can fail by planting the bug it targets.
- **Fixtures** are `tests/NAME.test` in Ropes' format (`program`, `arg`,
  `env`, `dir`, `input`, `status`, `output`); the harness is
  `tests/run-tests.sh`, copied from Ropes. Inputs a fixture formats live
  in `tests/data/`. **Regenerate expected output from real runs, then read
  it carefully before committing it**; never hand-edit generated text.
  Build fixture argument lists in Python (`subprocess` with a list), not
  with a shell `eval`.
- A change is checked with `make test`, `make -f pocGNUmakefile test-poc`
  and `make corpus` before it is committed.

## Source must build with both compilers

opp's own source is plain Oberon-2 that both voc (`-O2`, its default) and
poc accept:

- **No poc extensions** in opp's source: no `_` or `$` in identifiers, no
  variable or field initializers, no record or array literals, no
  declarations after procedures, no read-only parameters.
- **No voc-only features** either: no code procedures, no sysflags.
- **`INTEGER` is 16 bits under voc `-O2`.** Use `LONGINT` for every length,
  position, column, line number and width.
- **`Out` never flushes at program exit under voc**; call `Out.Flush`
  before exiting, and before `Platform.Exit`.
- **`HALT` makes voc print `Terminated by Halt(N).`**; exit with
  `Platform.Exit` for opp's own error statuses.
- **A procedure must be declared before it is used**; use `PROCEDURE ^`
  forward declarations for the parser's mutual recursion.
- **Assigning a record that holds a pointer shares what it points to**;
  copy explicitly when a copy must be independent.
- **Never pass a row of an `ARRAY OF ARRAY OF ...` parameter** (`a[i]`) as
  an open array: voc passes the wrong elements (vishap-bugs 11). poc is
  right, so only the voc build goes wrong.
- **Comments nest in Oberon.** A comment in opp's source that mentions
  the comment delimiters in quotes opens a nested comment and swallows the
  rest of the module; describe them in words instead.
- Strings are `OppText.Text` (`POINTER TO ARRAY OF CHAR`, allocated to
  fit), never fixed arrays that could truncate a long comment or string.

## Module structure

| Module           | Job |
| ---              | --- |
| `OppText.Mod`    | `Text` and growable `Buffer`; display width of UTF-8 text |
| `OppScanner.Mod` | Lossless lexer: tokens with their comments, blank lines and columns |
| `OppDoc.Mod`     | Layout documents and the renderer that fits them to a width |
| `OppFormat.Mod`  | Recursive-descent parser for poc + voc that builds a document |
| `Opp.Mod`        | Command line, file handling, the safety check |

Each module's header comment says what it does; keep them current.

## Invariants that must never break

- **opp never changes a program's meaning.** Before writing anything, opp
  rescans its own output and compares it with the input: the same tokens
  with the same text, the same comments (their text compared after
  re-indentation), and the same text after `END M.`. A mismatch is an
  internal error (exit 3), and nothing is written. Never weaken or bypass
  this check to make a test pass.
- **No comment is ever lost or moved past a token.** A token opp drops
  (an empty statement's `;`, an empty `CASE` arm's `|`) hands its comments
  to the next token.
- **Formatting is idempotent**: formatting opp's output again changes
  nothing. `make corpus` checks it.
- **Text after the module's closing period is copied verbatim**, as poc
  and voc ignore it (an Oberon system text keeps its fonts there).
- **On a syntax error opp writes nothing for that file**, reports
  `file:line:column: message` on standard error, and exits 1; with
  `--in-place` the file is left untouched.
- **No output line has trailing white space**, and blank lines have no
  indentation.

## Exit statuses

0 success; 1 a syntax error or an unreadable file, or with `--check` a
file that is not already formatted; 2 a command line mistake (ArgParser's
`UsageErrorStatus`); 3 an internal error (the safety check failed).
