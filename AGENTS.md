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
make format          # format opp's own source with opp
make install         # copy Opp to ~/local/bin as opp, opp.1 to ~/local/share/man/man1
make -f pocGNUmakefile test-poc   # build with poc in poc-build/, then test
make -f pocGNUmakefile install    # install the poc build as opp
make -f vaxGNUmakefile            # cross-compile for VAX/VMS with poc in vax-build/
make -f vaxGNUmakefile test-vax   # run the fixtures and the in-place checks on the VAX guest
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
- **The VAX/VMS port** is planned, and recorded step by step, in
  `VAX-VMS-PORT.md`. `vaxGNUmakefile` cross-compiles `Opp` and
  `OppDocTest` for `vax-dec-vms` in `vax-build/`, with ArgParser from its
  source (`ARGPARSER_SRC`), writing MACRO-32 and a DCL procedure for each;
  it needs poc's VAX runtime (the `peaseblossom-vax` package) and runs
  nothing on a VAX. There `OppHost.Mod` is `vms/OppHost.Mod`, the VMS
  implementation of `OppHost`: keep the two modules' interfaces the same,
  and check a change to either with `make -f vaxGNUmakefile` too.
- **`tools/vax-tests`** (`make -f vaxGNUmakefile test-vax`) runs every
  fixture on the VAX/VMS guest, through poc's `tools/vax-do`, and
  compares what it prints with what the host's `Opp` prints; then checks
  of `--in-place` (new versions) and `--output-dir`, after
  `tests/in-place.sh`. It needs the guest (`VAX_HOST`, `VAX_NETRC`) and
  poc's source (`POC_SRC`), and takes a few minutes. Where the guest must
  differ, `tests/vax/NAME.err` (or `.out`, `.status`) is what it prints
  instead, copied from `vax-tests/results/` after a real run and read;
  `tests/vax/NAME.skip` says why a fixture cannot be run there. A change
  to `vms/OppHost.Mod` or to how opp uses `OppHost` is checked with it
  too.
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
- **A user's config file must never reach the tests.** `run-tests.sh`
  and `in-place.sh` point `XDG_CONFIG_HOME` at a directory that does not
  exist, and `make format` and `tools/corpus.py` pass `--no-config`. A
  fixture that tests config files sets `env` and `dir` itself. Do not put
  a `.opp.conf` in the repository's top directory: the fixtures run there.
- `tests/in-place.sh` checks `--in-place` and `--output-dir` on copies
  in a temporary directory, which a fixture cannot; `make test` and
  `test-poc` run it after the fixtures.
- `make corpus` runs `tools/corpus.py` over `CORPUS_DIRS` (see the
  `GNUmakefile`); `tools/corpus-known-errors` lists the corpus files that
  are not valid Oberon. Any failure it prints is a bug in opp; the long
  lines it lists are worth a look.
- **opp's own source is formatted by opp** (`make format`, with
  `-k --no-module-indent`); the fixture `opp-own-source` fails until it
  is. Run `make format` after editing, and read what it changed.
- **`opp.1` is the manual.** Keep it, `README.md` and the usage in
  `Opp.Mod` in step when an option changes.
- Where authors' styles differ, opp keeps what the author wrote by default
  and offers options to force it either way (as `--case-bar` and
  `--align`; PLAN.md, "Decisions").
- A change is checked with `make test`, `make -f pocGNUmakefile test-poc`
  and `make corpus` before it is committed.

## Source must build with both compilers

opp's own source is plain Oberon-2 that both voc (`-O2`, its default) and
poc accept:

- **No poc extensions** in opp's source: no `_` or `$` in identifiers, no
  variable or field initializers, no record or array literals, no
  declarations after procedures, no read-only parameters.
- **No voc-only features** either: no code procedures, no sysflags.
- `vms/OppHost.Mod` is the one exception: it is built only by poc, for
  the VAX, and imports poc's `Directories`, which voc does not have.
  Otherwise it keeps these rules.
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
- **Make at most one parsing call in each expression.** voc compiles to C,
  which evaluates a call's arguments in any order, so in
  `D.Cat(Tok(p), Expr(p))` the expression may be parsed before the token
  is taken. Assign each parsing call's result to a variable first. poc
  evaluates left to right, so only the voc build goes wrong.
- **voc's garbage collector misses pointers held in callee-saved
  registers** and frees objects still in use. The voc build links
  dynamically (`VOCMAIN=-m`) with `tools/voc-heap-gc-spill.c`, which
  replaces `Heap_GC`; the `GNUmakefile` checks that the executable defines
  it. Keep both.
- Strings are `OppText.Text` (`POINTER TO ARRAY OF CHAR`, allocated to
  fit), never fixed arrays that could truncate a long comment or string.

## Module structure

| Module           | Job |
| ---              | --- |
| `OppText.Mod`    | `Text` and growable `Buffer`; display width of UTF-8 text |
| `OppScanner.Mod` | Lossless lexer: tokens with their comments, blank lines and columns |
| `OppDoc.Mod`     | Layout documents and the renderer that fits them to a width |
| `OppFormat.Mod`  | Recursive-descent parser for poc + voc that builds a document |
| `OppCheck.Mod`   | The safety check: the output has the input's tokens and comments |
| `OppHost.Mod`    | What the host decides: file names, wildcards, option case, config file names, how `--in-place` replaces a file (Unix; VMS in `VAX-VMS-PORT.md`) |
| `Opp.Mod`        | Command line, config files, file handling, `--in-place`, `--output-dir` and `--check` |

Each module's header comment says what it does; keep them current.

## Invariants that must never break

- **opp never changes a program's meaning.** Before writing anything, opp
  rescans its own output and compares it with the input: the same tokens
  with the same text, the same comments (their text compared after
  re-indentation), and the same text after `END M.`. A mismatch is an
  internal error (exit 3), and nothing is written. Never weaken or bypass
  this check to make a test pass. (`OppCheck`; the output must also parse.)
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
