# PLAN.md: opp, the Oberon pretty printer

opp reads Oberon-2 modules written for poc or voc and writes them back
laid out consistently, within a maximum line length, with every comment
kept. `AGENTS.md` has the standing rules; this file has the design, the
decisions behind it, and the phases of work.

## Goals

1. Parse everything poc (both branches) and voc parse, as source text, and
   reproduce it token for token.
2. Lay it out within `--width` columns wherever a line can be broken.
3. Three statement modes: **one statement per line**; **packed**, where
   runs of short simple statements and declarations share a line and short
   structured statements fit on one line; and **kept**, which keeps
   together on a line what the author put on one line, as long as it fits.
4. Keep every comment, and keep the author's blank lines (collapsed to one).
5. Never change a program's meaning; prove it on every run.
6. Build and run with both voc and poc, on every host poc supports.

Not goals: semantic checks, renaming, reordering declarations, changing
the case of identifiers, rewriting numbers or strings, and formatting
`.sym` files or voc's `DEFINITION` listings.

## Command line

```
opp [options] [file ...]
```

With no files, opp formats standard input to standard output. With files,
it writes each formatted file to standard output in turn, unless
`--in-place`, `--output-dir` or `--check` is given.

| Option | Meaning |
| --- | --- |
| `-w N`, `--width N` | maximum line length (default 80; 20..1000) |
| `-i N`, `--indent N` | columns per indentation level (default 2; 1..16) |
| `-1`, `--one-per-line` | every statement on its own line (the default) |
| `-p`, `--pack` | pack short statements and declarations onto shared lines |
| `-k`, `--keep-lines` | keep statements and declarations on shared lines where the source has them, while they fit |
| `--no-module-indent` | start a module's declarations at column 1; its statements stay indented |
| `--module-indent` | indent a module's declarations (the default; to undo a config file's `no-module-indent`) |
| `--case-bar WHAT` | a bar before a `CASE`'s first arm: `keep` it as written (default), `add` one, or `drop` it |
| `--cuddle-begin WHAT` | a body's first statement on `BEGIN`'s line (`BEGIN RETURN x`): `allow` it where the source has it (default), `force` it, or `disallow` it; only when all of that statement fits |
| `--cuddle-end WHAT` | `END` on that line too, when the whole body is on it (`BEGIN RETURN x END Get;`): `allow` (default), `force` or `disallow`, likewise; only when all of it fits |
| `--align WORDS` | what to line up, as words separated by commas: `const`, `type`, `var`, `field`, `init`, `comment`, `case`, `assign`, or `all`, for opp to line up; `no` before one (`nocomment`, `noall`) for one space; `keep` (default) or `drop` for the author's spaces elsewhere; later words win |
| `--in-place` | replace each file with its formatted text |
| `--output-dir DIR` | write each file's formatted text to `DIR/` under the file's own name; `DIR` must exist |
| `-c`, `--check` | write nothing; exit 1 and name each file that would change |
| `--tokens` | list each file's tokens and comments instead (a debugging aid) |
| `--damage N` | for opp's tests: spoil the formatted text (1 a token, 2 a comment, 3 the text after the module) so the safety check fails |
| `--config FILE` | read options from `FILE` instead of the config files |
| `--no-config` | read no config file |
| `-h`, `--help` | show the usage and exit 0 |

`--one-per-line`, `--pack` and `--keep-lines` choose the statement mode;
when more than one is given, the last one wins.

**Config files.** Before the command line, opp reads the user's config
file, `$XDG_CONFIG_HOME/opp/opp.conf` (or `~/.config/opp/opp.conf`), then
the current directory's, `.opp.conf`: one option to a line, as the command
line gives it, its `--` optional, its value after white space or `=`; `#`
starts a comment. Later settings win, so the directory's file overrides
the user's, and the command line both. Only options that say how to format
may be there. `--config FILE` reads `FILE` instead; `--no-config` reads
none; of the two, the last given wins. A mistake is `opp: file:line:
message`, exit status 2. ArgParser parses only the command line, so opp
finds each option in the parser's exported list and calls its handler
itself; `--config` and `--no-config` are found by a scan of the command
line before the files are read.

## The syntax opp accepts

The grammar of `Oberon2.pdf` Appendix B, plus the following.

**poc extensions** (from poc's `src/front/Lexer.Mod`, `Parser.Mod` and
`doc/developer/language-extensions.md`):

- `_` and `$` anywhere a letter may be in an identifier.
- `CONST`, `TYPE` and `VAR` sections after procedures.
- Variable initializers: `VAR a, b: T := e;`.
- Record field initializers: `RECORD x, y: INTEGER := e END`.
- Read-only parameters: `PROCEDURE P(x-: T)`.
- External procedures: `PROCEDURE ["C"] Name*(...): T;` and
  `PROCEDURE ["C", "linkname"] Name(...);`, with no body.
- Record and array literals: `Point{x := 1, y := 2}`, `Vector{1, 2, 3}`,
  `T{[48..57]: 1}`, and nested literals without a type name `{...}`.
- `ASSERT`, `HUGEINT`, `SYSTEM.*` and 64-bit hexadecimal constants need
  nothing from a pretty printer: they are ordinary identifiers, calls and
  numbers.
- Text after the module's closing period is not read.

**voc extensions** (from voc's `OPS.Mod` and `OPP.Mod`):

- System flags: `RECORD [n]`, `ARRAY [n] OF`, `ARRAY [n] len OF`,
  `POINTER [n] TO`, `PROCEDURE [n] (...)` (a procedure type).
- Code procedures: `PROCEDURE -Name(...): T "C text";` and the older form
  with a list of byte values, `PROCEDURE -Name 0E8H, 12H;`.
- Interrupt procedures `PROCEDURE +Name` and the `PROCEDURE *Name` mark.
- Read-only parameters `x-` (also poc's) and read-only export marks `x-`.
- `(** ... *)` exported comments, which are ordinary comments to opp.

Both: `IMPORT A := B`, forward declarations `PROCEDURE ^ P`, type-bound
procedures and super calls `r.P^`, type guards anywhere in a designator.

## Architecture

### OppText

`Text` (`POINTER TO ARRAY OF CHAR`, 0X-terminated, allocated to fit) and
`Buffer`, a Text that doubles as it grows. `Width` counts the columns UTF-8
text takes. Written.

### OppScanner: a lossless lexer

The scanner is pulled one token at a time by the parser, so it never reads
past the module's closing period. Each token has its kind, its exact text
(a string keeps its quotes, a number its suffix), its line and column, and:

- `blankBefore`: a blank line separates it from what came before it;
- `lead`: the comments on lines of their own before it;
- `trail`: the comments after it on the same line, each noting whether a
  line break follows it;
- `gap`: the columns between it and what ends before it on its line (a
  token or a comment), or 0 at the start of a line; a comment has one too.

A comment that begins on the same line as the token before it is a
trailing comment of that token; any other comment leads the next token.
Each comment keeps its text, its visual starting column (tabs expanded to
multiples of 8) and whether a blank line precedes it. Nested comments are
kept whole. Carriage returns are dropped.

Errors: an unterminated comment or string, an invalid character, an
invalid number.

### OppDoc: the layout engine

A document is a tree of nodes, rendered within a width by the algorithm of
Wadler's "A prettier printer" [1], with Leijen's `align` and `fill` [2]
and Prettier's way of running it with an explicit stack and of checking
what follows a group [3]; "References" below has the sources:

| Node | Flat | Broken |
| --- | --- | --- |
| `Text s` | `s` | `s` |
| `Line` | a space | a line break and the indentation |
| `SoftLine` | nothing | a line break and the indentation |
| `HardLine` | (forces its groups broken) | a line break |
| `BlankLine` | (forces its groups broken) | a line break and one empty line |
| `FillLine` | a space | a space if the next item fits, else a line break |
| `Nest n d` | `d` indented `n` more after its line breaks | |
| `Align d` | `d` indented to the current column | |
| `AlignOrNest n d` | `Align d`, or `Nest n d` when the column is past a limit, or when an item of the fill `d` fits only nested | |
| `KeptLine c` | as `ChoiceLine c` while `c` is soft | once `c` is hard, a line break only if what follows does not fit |
| `Group d` | `d` flat if it fits, else broken | |
| `Concat` | its children in order | |
| `Comment` | a comment, its later lines re-indented | |
| `TrailBreak` | (a trailing comment's line break) | a line break; breaks its group only if something follows it there |
| `SoftBreak f` | nothing | a line break if the first item of the fill `f` after it does not fit, and the break moves it left |
| `Choice`, `ChoiceLine` | spaces | line breaks; the parser decides each choice before rendering |
| `Widen n` | after one space on the line, that space made `n` wide unless that makes a line too long | |
| `Pad run gap` | after one space on the line, that space widened to line up with the other pads of `run`, unless that makes a line too long | |

- A group is laid out flat when it, and what follows it up to the next
  possible line break, fits in the rest of the line. A comment that ends
  the line is not counted: code is never broken to make room for a
  trailing comment, which could not move anyway. A fill separator does
  count it, so a statement whose trailing comment would overflow starts
  the next line instead of joining this one.
- `SoftBreak` goes after the `(` of a parameter or argument list: when the
  first item does not fit after the `(`, the list starts on the next line,
  nested, instead of breaking inside that item. A group holding a
  `HardLine`, a `BlankLine` or a multi-line comment is always broken; this
  is worked out once, before rendering.
- `FillLine` gives Prettier's `fill`: each separator breaks only when the
  item after it does not fit on the current line. It packs argument lists,
  identifier lists, operand chains and, in `--pack` mode, statements.
- Line breaks are lazy: a break is recorded and written only when text
  follows, so breaks requested twice in a row make one, a `BlankLine`
  never makes two empty lines, no line ends in spaces, and blank lines
  have no indentation.
- A multi-line comment's later lines move by as many columns as its first
  line moved, never left of column 1.
- `Widen` and `Pad` give alignment's extra spaces. Every layout decision
  uses the column without them, so the lines are the same with or without
  them and they only move text right; a frame records the extra spaces
  before its indentation, so an aligned continuation moves with its first
  line. `Render` renders again until no line is too long because of them:
  first with the author's gaps (`Widen`), turning off on each line too
  long because of them the last that shifts it; then with opp's runs
  (`Pad`), turning off such a run and recomputing each run's column (the
  furthest column any of its pads starts at) until the columns settle.
  The author's gaps settle first so that formatting the output again
  changes nothing. A line too long without its extra spaces, for a comment
  or string that cannot break, keeps them.
- A run of pads is one run of the parser's (a section's or a record's
  declarations, or a `CASE`'s arms, up to a blank line), less the pads on
  a line holding another of the run, which keep the author's gap; or, for
  trailing comments, those on lines next to each other, less a comment
  with text after it on its line.
- The renderer writes into an `OppText.Buffer`.
- The stack is a linked list of frames, each holding an indentation, a
  mode and a chain of sibling nodes, so no array limits the depth of
  nesting.

### OppFormat: the parser that builds the document

Recursive descent, one procedure per production, following poc's
`Parser.Mod`, extended with voc's productions. It needs one token of
lookahead past the current one, to tell `field := value` in a literal from
an expression. `(...)` after a designator is always parsed as a selector, a
call or a guard alike, so `p(T).f` and `F(x)` need no symbol table.

Comments are turned into document nodes by one procedure, `Tok`, which
emits a token with its leading comments (each on its own line, after a
blank line if it had one) and its trailing comments (after a space, then a
forced line break if one followed in the source). At the end of a
statement sequence, field list or declaration section, the comments
leading the closing keyword (`END`, `ELSE`, `ELSIF`, `UNTIL`, `|`) are
emitted inside the body, at the body's indentation.

A token's `blankBefore` is honored where an item starts: a statement, a
declaration, a field list, a `CASE` arm, a procedure, an import list. Blank
lines inside an expression are dropped.

### Opp and OppCheck: the program and the safety check

`Opp` parses the command line with `ArgParser`, reads each file (or
standard input) into memory, formats it, runs the **safety check**, and
writes the result: to standard output, back to the file with
`--in-place`, or with `--check` only the names of the files that would
change. `--in-place` writes only a file that changed, and writes over it,
so that it keeps its permissions, owner and hard links (neither compiler's
library can set a new file's permissions): once the file is open for
writing, its old text is copied to `NAME.opp-backup`, which is deleted
once the file is written and is left, and named, if writing it fails. A
file opp cannot open, or whose backup it cannot write, is left as it was.
`--output-dir DIR` writes every file's formatted text, changed or not, to
the file of the same base name in `DIR`, which must exist (neither
compiler's library can make a directory), creating or replacing it. Two
inputs of the same base name are a command line mistake, found before
anything is formatted; a file whose output would be the input itself
(`Platform.SameFile`) is refused, exit 1, as `--in-place` is the way to
format a file in place. It cannot be used with `--in-place`, `--check`,
`--tokens` or standard input, nor in a config file.

The safety check is `OppCheck`. It scans the input and the output up to
the module's closing period, each as one sequence of tokens and comments
in order, and the output's must be the input's, except for semicolons and
bars the input has and the output leaves out (empty statements, field
lists and `CASE` arms). Tokens are compared by kind and text; comments by
text, with the white space at the start and end of each line removed. The
text after the period must be the same, or white space in both. Then the
output must parse. A comment moved past a token, or lost, is a difference.
A failure is reported as an internal error, with the position in the
output and what differs, and nothing is written for that file.

opp reads and writes files with `Platform`, not `Files`, which both
compilers' `Platform` modules make possible with the same procedures:
`Files.Register` replaces a file with a new one (losing its permissions),
and voc's `Files` renames a file it still has open, as one read for
formatting would be, to a temporary name that is deleted only if the
collector ever finalizes it.

## Layout rules

These describe the default style, close to poc's and Wirth's own. `s` is
the `--indent` step.

**Module**

```
MODULE M;  (* trailing comment kept *)

  IMPORT Lexer, D := Diagnostics;

  CONST
    max = 10;
  ...
BEGIN
  ...
END M.
```

The module's contents are nested `s`; with `--no-module-indent` its
declarations start at column 1, but the statements after `BEGIN` are still
nested `s`, as a procedure's are.
`BEGIN` and `END M.` are at the module's column. The import list fills
its lines, continued at `2s`.

**Declaration sections.** A section holding one declaration that fits
goes on the keyword's line (`VAR c: CHAR;`). Otherwise the keyword stands
alone and its declarations follow, nested `s`, one per line. With
`--pack` they fill lines instead, as in `VAR i, j: INTEGER; c: CHAR;`, and
stay on the keyword's line if they all fit. With `--keep-lines` they share
a line, the keyword's included, where the source has them on one line and
they still fit; see "Kept" below.

**Types.** A record's field lists go one per line, nested `s` from the
line the record starts on, and its `END` aligns with that line; an empty
record is `RECORD END`. `ARRAY a, b OF T`, `POINTER TO T`, and procedure
types as in a procedure heading. System flags follow their keyword:
`RECORD [1]`, `POINTER [1] TO`.

**Procedures.**

```
  PROCEDURE (VAR p: Parser) Name*(a, b: INTEGER; VAR c: ARRAY OF CHAR;
                                  d-: T): BOOLEAN;
    VAR i: LONGINT;
  BEGIN
    ...
  END Name;
```

Formal parameter sections fill their lines aligned after `(`; when the
first section does not fit after the `(`, they start on the next line,
nested `2s`, as in `PROCEDURE ^ Forward(` then `    x: INTEGER): INTEGER;`.
A code procedure's text moves to the next line, nested `2s`, when it does
not fit. The
procedure's declarations are nested `s`; `BEGIN` and `END Name;` are at the
procedure's column; its statements are nested `s`. A procedure's or
module's first statement goes on `BEGIN`'s line (`BEGIN RETURN x`, or
Wirth's `BEGIN x := 1;` with the rest below) as `--cuddle-begin` says:
where the source has it there (`allow`, the default, in every mode),
always (`force`), or never (`disallow`); and only when all of that
statement fits there, so never a statement broken over lines. `END` goes on
that line too (`BEGIN RETURN x END Get;`) as `--cuddle-end` says, likewise,
when the whole of `BEGIN ... END Name` fits on one line; otherwise it has
a line of its own. (A `KeptLineItem` measures the body's first statement
flat; a group around the body, a line, and `END Name` puts `END` on the
line.) Forward declarations
print as `PROCEDURE ^ Name(...);`, with a space after the `^` as poc
writes it, so the mark that makes it a forward declaration stands out;
external ones as
`PROCEDURE ["C", "name"] Name(...);`, code procedures as
`PROCEDURE -Name(...) "text";`, and `+`/`*` marks as `PROCEDURE +Name`.

**Blank lines between procedures.** opp keeps the author's blank lines,
and adds one between two consecutive procedure declarations at the same
level when the source has none, if either of them has a body, and between
a procedure with a body and a declaration section after it (poc allows
declarations after procedures). A run of
forward or external declarations is left as written. When a procedure has
comments on lines of their own before it, the blank line goes before the
comments, which belong to the procedure.

**Statements.** Statement sequences are nested `s`. Structured statements:

```
IF a THEN            WHILE c DO          REPEAT
  ...                  ...                 ...
ELSIF b THEN         END                 UNTIL c
  ...
ELSE                 FOR i := 0 TO n - 1 BY 2 DO      LOOP
  ...                  ...                              ...
END                  END                              END

CASE ch OF                       WITH v: T DO
  "a": x := 1                      ...
| "b", "c" .. "e":               | v: U DO
    IF ... END;                    ...
    y := 2                       ELSE
ELSE z := 3                        ...
END                              END
```

A `CASE` arm's labels are at the column after `|` and its padding; a body
that is one statement and fits goes on the labels' line, any other body is
nested `s` below them. The `ELSE` of a `CASE` takes its body on its own line
by the same rule: `ELSE z := 3` when it is one statement that fits.
`CASE` and a `WITH` with more than one guard are always broken.

A bar before a `CASE`'s first arm, as voc's sources write `CASE`
(`CASE ch OF` then `| "a": ...` then `| "b": ...`), is kept where the
author wrote one; `--case-bar add` puts one before every first arm, and
`--case-bar drop` takes them away. Its labels line up with the other
arms' either way. Comments on lines of their own before a `|` stay with
it, before the arm or guard they describe.

**One per line** (`-1`, the default): every statement starts its own line,
and every structured statement is broken as shown.

**Packed** (`-p`): consecutive simple statements (assignments, calls,
`RETURN`, `EXIT`) share a line while they fit, as in
`Advance(s); Advance(s); INC(depth)`. A structured statement always starts
its own line and the statement after it starts a new line, but the
structured statement itself goes on one line when it all fits:
`IF ch = 0X THEN RETURN 0X ELSE RETURN s.text[s.pos] END`. A statement
with a comment on a line of its own before it, or a blank line before it,
starts a new line; so does the statement after a trailing comment that
ended its line in the source.

**Kept** (`-k`): a statement starts a new line where it started one in the
source, and shares the line of the statement before it where the author
wrote them on one line; a run that no longer fits is filled onto as many
lines as it needs. A structured statement the author wrote on one line
stays on one line if it fits, and is broken as shown above if it does not;
one the author broke stays broken, but a body the author wrote on its
keyword's line (`IF a THEN x := 1` then `ELSE x := 2` then `END`) stays
there while it fits; so does a `CASE` arm's, and one the author put on the
next line stays there (and see `--cuddle-begin` for a body on `BEGIN`'s
line). Declarations follow the same rule (a section's one
declaration goes on the keyword's line only if the author put it there),
and comments before a declaration or statement do not stop the ones after
it sharing its line. This
is idempotent: what opp splits, it never joins again. Whether two
statements were on one line is decided from their tokens' line numbers in
the source.

**Expressions.** Spaces around `:=`, relations and binary operators, none
inside parentheses or brackets, one after each comma. A chain of operands
at one precedence level fills its lines, breaking *before* an operator and
continuing at `2s` from the statement's indentation. A parenthesized
expression breaks aligned after its `(`. Argument lists, index lists, sets
and literals fill their lines aligned after the opening bracket, or nested
`2s` when that column is too far right (past two thirds of the width) or
when an item would fit only nested.

**Kept as written:** identifiers, numbers, strings and their quote
characters, comments' text, the export marks, a trailing `;` before `END`
(an empty last statement or field list), a bar before a `CASE`'s first
arm (see `--case-bar`). Empty statements elsewhere and empty `CASE` arms
are dropped (their comments are kept).

**Alignment.** By default opp keeps the author's: where two tokens, or a
token and its trailing comment, stay next to each other on a line and the
source has more than one space between them, opp keeps that many columns,
unless that makes too long a line that fits without them. So voc's
`| "#":      s := neq` and columns of `CONST` values and trailing comments
survive. `--align` takes words separated by commas, later ones winning:

| Word | Lines up |
| --- | --- |
| `const`, `type` | the `=` of constants, of types |
| `var`, `field` | the types of variables, of fields |
| `init` | the `:=` of poc's initializers |
| `comment` | trailing comments on lines next to each other |
| `case` | the bodies of `CASE` arms on their labels' lines, and `ELSE`'s |
| `assign` | the `:=` of assignments, in a run of them that each start a line |
| `all` | all of these |

`no` before a word (`nocomment`, `noall`) makes those spaces one space;
`keep` (the default) and `drop` keep the author's spaces, or make them one
space, where no word says otherwise. A run of declarations is those of a
section or record up to a blank line; a line holding several of them
(`-p`, `-k`) is left out of its run and keeps the author's spacing. A run
of assignments is a statement sequence's consecutive assignments, up to a
blank line or another kind of statement; one that does not start its line
(after another statement in `-p`, or on `BEGIN`'s line) is left out, as an
`Anchor` at its start records. A run that would make too long a line is
not lined up.

## Decisions

- **Written in Oberon-2, built with both voc and poc**, like `Ropes` and
  `oberon-tools`, so opp is itself a test of both compilers and can follow
  poc to VAX/VMS. Its own source must format cleanly with opp.
- **No `Ropes.Mod`** (2026-10-12, with the user): opp reads a file once and
  scans it sequentially, and its output only grows at the end, so a flat
  `OppText.Buffer` is simpler and faster than a rope, and avoids a third
  shared library to install and keep in step with poc.
- **A layout engine, not ad hoc line breaking**: Wadler/Prettier documents
  ([1], [3]; [4] argues the case for a code formatter)
  make the width rule and the statement modes properties of a few
  node kinds instead of special cases scattered through the parser.
- **The parser builds the document directly**, without an intermediate
  syntax tree: opp needs no analysis that a tree would make easier, and the
  comments ride on the tokens.
- **One per line is the default**: it is the predictable choice, and
  `--pack` and `--keep-lines` are one option away.
- **`--pack` packs declarations too** (2026-10-12, with the user).
- **A third mode, `--keep-lines`** (2026-10-12, with the user), that keeps
  the author's grouping of statements and declarations.
- **A blank line between procedures** (2026-10-12, with the user): opp
  adds one where the source has none.
- **`PROCEDURE ^ Name`, poc's spelling** (2026-10-12, with the user): the
  space makes the `^`, and so the forward declaration, more obvious.
- **The safety check always runs**: it is cheap next to parsing, and
  `--in-place` must never damage a file. It parses the output again too, so
  that leaving out a semicolon or bar can never go unnoticed.
- **opp's own source is formatted `-k --no-module-indent`** (`make
  format`; the fixture `opp-own-source` checks it): it keeps the source's
  grouping, and its declarations at column 1 as in Ropes and oberon-tools.
- **A `CASE`'s leading bar is kept as written by default, with
  `--case-bar add` and `drop` to make every `CASE` alike** (2026-10-12,
  with the user). In general, where authors' styles differ, opp keeps what
  the author wrote and offers options to force either way.
- **An author's tabular alignment is kept by default** (2026-10-12, with
  the user), and **`--align` takes a list of what opp lines up itself**
  (2026-10-12, with the user, from `000-todo.org`): `const`, `type`,
  `var`, `field`, `init`, `comment`, `case` and `all` (and `assign`,
  added later from `000-todo.org`); `no` before one
  gives it one space; `keep` and `drop` say what happens to the author's
  spaces elsewhere. One option, so a configuration file can hold it as
  one line. Only runs with one declaration to a line are lined up, not
  the grids of packed lines.
- **`--output-dir DIR`** (2026-10-12, from `000-todo.org`): the formatted
  files go flat into `DIR` under their base names, every file named, as
  "new versions of all the files"; `DIR` must exist.
- **Config files** (2026-10-12, with the user, from `000-todo.org`):
  `.opp.conf` in the current directory and `opp.conf` in
  `~/.config/opp/` (or `$XDG_CONFIG_HOME/opp/`); both are read, the
  directory's after the user's, then the command line, each later setting
  winning, as git's configuration layers. `--module-indent` was added so
  the command line can undo a config file's `no-module-indent`. The test
  scripts point `XDG_CONFIG_HOME` at a directory that does not exist, and
  `make format` and `make corpus` pass `--no-config`, so a user's config
  never changes them.
- **`--cuddle-begin` and `--cuddle-end`, `force`, `allow` or `disallow`**
  (2026-10-12, with the user, from `000-todo.org`): `allow`, the default,
  keeps the author's cuddling in every mode, so `-1` and `-p` no longer
  break `BEGIN RETURN x` that the source wrote so (before, only `-k` kept
  it). A first statement goes on `BEGIN`'s line only when all of it fits
  there.
- **Extra spaces never change where lines break**: layout ignores them,
  and a line they would make too long loses them, unless it is too long
  without them.
- **A man page, `opp.1`**, installed to `MANDIR` (default
  `~/local/share/man/man1`) by both makefiles' `install`.
- **`--damage N`** is in the usage, as ArgParser lists every option: it
  exists only so the fixtures can show that the safety check catches a
  changed token, comment or trailing text.

## Open questions

- Lining up packed declarations in grid columns, as voc's `OPS.Mod`
  does by hand (see "Later").

## Phases

Each phase ends with `make test`, `make -f pocGNUmakefile test-poc` and
(from Phase 4) `make corpus` passing, and a commit.

### Phase 0: repository (done 2026-10-12)

- `AGENTS.md`, `PLAN.md`, `README.md`, `GNUmakefile`, `pocGNUmakefile`,
  `.gitignore` (`/Opp`, `*.c`, `*.h`, `*.o`, `*.sym`, `/poc-build/`).
- `tests/run-tests.sh` from Ropes; `tests/data/`.
- `OppText.Mod`.
- A skeleton `Opp.Mod` that takes every option of "Command line" through
  ArgParser (the range checks on `--width` and `--indent` are ArgParser's)
  and its file names, then says formatting is not implemented and exits 1.
- Fixtures `opp-help`, `opp-width-range`, `opp-indent-range`,
  `opp-unknown-option` and `opp-not-implemented`; the last goes when
  Phase 3 makes opp format. Both builds pass them.

### Phase 1: scanner (done 2026-10-12)

- `OppScanner.Mod` as described, with poc's identifier characters and all
  of voc's and poc's number forms. A letter may follow a number at once
  (`1THEN` is `1` and `THEN` to both compilers; voc's `vbeautify.Mod` has
  one).
- `opp --tokens` lists tokens with their comments and flags, one to a line,
  control characters escaped. ArgParser lists every option in the usage,
  so it is documented there as a debugging aid rather than hidden.
- Fixtures `scan-*` on inputs in `tests/data/`: comments leading, trailing
  and between tokens, multi-line and nested, before the module and after
  its end; blank lines, tabs, CRLF and a form feed; both quote characters
  and UTF-8; every number form; poc's identifiers; every symbol; and the
  errors (unterminated comment and string, invalid character and number).
- Checked over 644 `.Mod` files (poc's both branches, voc's compiler,
  library and tools, and the other repos in `~/Repos/Oberon`): every
  token and comment in order, white space aside, rebuilds each file
  exactly; the voc and poc builds list identical tokens for all of them;
  the only errors are in text after `END M.`, which formatting never
  scans (`OPT.Mod`, `MultiArrays.Mod`, `MultiArrayRiders.Mod`,
  `ethUnicode.Mod`).

### Phase 2: layout engine (done 2026-10-12)

- `OppDoc.Mod` with every node kind above, plus `Space` (a lazy space, so
  no line ends in white space) and a `FillBuilder` that assembles fills:
  each item is a concatenation of its own, so a separator measures the
  whole item after it, and begins with a mark recording the line it starts
  on, so a separator after an item that did not stay on one line breaks.
- `OppDocTest.Mod`, in the style of `RopeTest` (`ok -`/`not ok -` lines,
  `N/M tests passed.`, exit 1 on a failure), run by the fixture
  `opp-doc-selftest`: 43 checks of groups, nesting, alignment, fill, lazy
  and blank lines, trailing white space, UTF-8 widths and comment
  re-indentation, each width boundary checked on both sides.
- Each of six bugs planted in a copy of `OppDoc.Mod` (Fits ignoring what
  follows a group, blank lines not collapsed, fill ignoring a broken item,
  comments not re-indented, hard breaks not propagated, line breaks not
  lazy) makes at least one check fail.
- Found on the way: voc passes a row of an open two-dimensional array
  wrongly (vishap-bugs 11; `AGENTS.md`).

### Phase 3: parser and printer (done 2026-10-12)

Planned, in this order, each with fixtures in `tests/data/` formatted at
a narrow and a wide width, in all three statement modes:

1. Modules, imports, declaration sections, types.
2. Procedures: headings, receivers, forward, external and code
   procedures, nested procedures.
3. Statements, in all three modes, and the blank lines opp adds between
   procedures.
4. Expressions, designators, sets and literals.
5. Comments and blank lines everywhere; trailing semicolons; empty
   statements and arms.
6. Syntax errors: position and message, nothing written, exit 1.

Done:

- `OppFormat.Mod`, a recursive-descent parser for the union of poc's and
  voc's syntax that builds the document as it goes, and `Opp.Mod`
  formatting each file to standard output. Fixtures `fmt-*` format seven
  inputs (declarations, procedures, statements, expressions, comments,
  poc's and voc's extensions) one per line, packed, kept and at width 40;
  `fmt-indent-4`, `fmt-no-module-indent` and `fmt-stdin` the options and
  standard input; `fmt-error-*` five syntax errors. `opp-not-implemented`
  went; `opp-in-place-not-implemented` stands until Phase 4.
- Structured statements are `Choice`s: the parser decides before rendering
  whether each is on one line (fits, and the mode allows it) or broken, so
  a body's layout does not depend on the renderer's guesses.
- `TrailBreak` for a trailing comment's line break, which breaks only the
  groups something follows it in; comments that lead an item go outside
  its groups (`ItemLead`), so they never force the item itself broken.
- `SoftBreak` (above), and trailing comments not counted when fitting
  code; `OppDocTest` has 58 checks, each new one proved by planting the
  bug it targets.
- **voc's garbage collector freed objects in use** (callee-saved registers
  not scanned), garbling or crashing opp on large files. The voc build now
  links dynamically with `tools/voc-heap-gc-spill.c`, Peaseblossom's
  replacement `Heap_GC` (`GNUmakefile`; `AGENTS.md`).
- **One parsing call per expression**: voc's C evaluates a call's
  arguments in any order, so `D.Cat(Tok(p), Expr(p))` can consume tokens
  out of order; each parsing call is its own statement (`AGENTS.md`).
- Checked over the 644-file corpus at widths 30 to 120 in all three modes:
  the same tokens and comments as the input, idempotent, the voc and poc
  builds byte-identical; the only errors are three invalid sources
  (`TryExtension.Mod`, `TryLinkedList.Mod`, voc's `HeapDump.Mod`, which
  voc rejects too). At width 80 the lines still too long are long strings,
  comments, and code followed by a trailing comment.

### Phase 4: the program and the safety check (done 2026-10-12)

Planned:

- `Opp.Mod`: options, standard input, several files, `--in-place`,
  `--check`, the exit statuses.
- The safety check, with a fixture that proves it can fail (a debugging
  option that deliberately damages the output, used only by that fixture).
- `make corpus`: format every `.Mod` in poc's `src/` and `rtl/` (both
  branches), voc's `src/compiler/` and `src/library/`, and the user's other
  Oberon repos, at widths 60, 80 and 120, in all three modes, checking for
  each: no syntax error, the safety check passes, the output is idempotent,
  and no line is longer than the width except where it cannot be broken
  (one token, a string or a comment that is too long); report those lines.
- Format opp's own source with opp and commit the result.

Done:

- `OppCheck.Mod` and the program as described above. `--in-place` and
  `--check` together, `--tokens` with either, and `--in-place` on standard
  input are command line mistakes (exit 2); with several files the worst
  status wins and every file is still tried.
- Fixtures: `opp-damage-*` (each kind of damage, and with `--check`),
  `opp-check*`, `opp-several-files`, `opp-stdin-dash`, the command line
  mistakes, `fmt-keep*`, and `opp-own-source`. `tests/in-place.sh`, run by
  `make test` and `test-poc`, checks `--in-place` on copies: the file
  formatted, a formatted file not rewritten (its time kept), files with a
  syntax error or a failed check untouched, no temporary file left,
  permissions and hard links kept, a read-only file or one whose backup
  cannot be written untouched. Each new kind of check was shown to fail by
  planting its bug.
- `make corpus` (`tools/corpus.py`, `tools/corpus-known-errors`): the
  files git tracks in poc's both branches, voc, ArgParser, Ropes,
  oberon-tools, polibfyaml, pofltk and oberon-experiments, 643 in all, in
  17 seconds. All pass in all nine configurations; an independent token
  comparison in Python agrees with the safety check. Lines still too long
  that hold no string or comment: none at widths 80 and 120, about 130 at
  60 (long type declarations and designators, and assignments, which opp
  does not break after `:=`).
- Layout changes the corpus prompted: `AlignOrNest` nests a list whose
  items would overflow aligned (headings of external procedures with long
  names); comments before an item no longer stop the next item sharing its
  line; `--keep-lines` keeps bodies on their keyword's line (`KeptLine`)
  and `CASE` bodies on their own line where the source has them.
- opp's own source formatted (`make format`).

### Phase 5: real-code polish (done 2026-10-12)

- Review the corpus output for poc's sources against their hand
  formatting, and adjust the rules where opp's layout reads worse.
- Settle any questions real code raises with the user.
- `README.md` and a man page `opp.1`; `make install`/`uninstall` for both
  builds.

Done (2026-10-12):

- Compared opp's output with poc's hand-formatted `src/` and `rtl/`
  (35,000 lines) at width 130, so that only style differs, not width.
  Apart from lines joined or broken for width, the differences were:
  bodies on `BEGIN`'s line (`BEGIN RETURN x`) and sections whose one
  declaration is on the line after the keyword, both of which `-k` now
  keeps; a bar before a `CASE`'s first arm, now `--case-bar`; and places
  where opp corrects the source's indentation.
- Fixed: a list broken after its first item indented its continuation
  `4s`, not `2s` (the `SoftBreak` nest and `AlignOrNest`'s both applied).
- Fixed: a comment before a `|` went into the arm above on a second
  formatting, so formatting was not idempotent for it; it now stays with
  the bar. `make corpus` missed it because it did not format opp's own
  test inputs; it now includes opp's repository and runs `--case-bar add`
  and `drop` too: 676 files, 15 configurations, all pass.
- `opp.1`, the man page, and `install`/`uninstall` of it in both
  makefiles; `README.md` brought up to date.
- `--align`: an author's tabular alignment kept (the scanner's `gap`,
  OppDoc's `Widen`), and opp's own lining up of declarations, trailing
  comments and `CASE` bodies (OppDoc's `Pad` and the renderer's passes);
  `make corpus` runs `--align drop`, `all` and `all,drop` too: 24
  configurations, all pass.
- Config files, `~/.config/opp/opp.conf` and `./.opp.conf`, with
  `--config`, `--no-config` and `--module-indent`.
- `--output-dir DIR`; `tests/in-place.sh` checks it too.
- `--cuddle-begin` and `--cuddle-end`. `Fits` counts a kept line in a
  flat group as a space, which changed no existing output (checked over
  the corpus in four configurations); `make corpus` runs `-p` with both
  `force`: 27 configurations.

### Later

- Breaking after `:=` when the right side cannot break well, for the
  assignments that still overflow at narrow widths.
- Lining up packed declarations (`-p`, `-k`) in grid columns.
- Formatting a range of lines, for editor integration.
- Building and running opp on VAX/VMS once poc's VMS backend can.

## References

The layout engine (`OppDoc`):

1. Philip Wadler, "A prettier printer", in Jeremy Gibbons and Oege de Moor
   (eds.), *The Fun of Programming*, Palgrave Macmillan, 2003, pp. 223-243.
   <https://homepages.inf.ed.ac.uk/wadler/papers/prettier/prettier.pdf>.
   The document algebra (`text`, `line`, `nest`, `group`) and the
   rule that a group is flat when it fits, judged up to the next line break.
2. Daan Leijen, `wl-pprint`, the Haskell library that implements [1] and
   adds `align`, `hang`, `fill` and `softline`.
   <https://hackage.haskell.org/package/wl-pprint>. Where opp's `Align`
   and `FillLine` come from.
3. Prettier's documents and printer: "Prettier's intermediate
   representation: Doc",
   <https://github.com/prettier/prettier/blob/main/commands.md>, and the
   printer itself, <https://github.com/prettier/prettier/tree/main/src/document/printer>.
   An imperative version of [1] driven by a stack of (indentation, mode,
   document) commands; groups that a hard line forces broken
   (`propagateBreaks`); `fill`'s rule of checking each separator against
   the item after it; and `fits`, which measures past the end of a group
   into what follows it. opp's renderer follows this, in Oberon.
4. James Long, "A Prettier JavaScript Formatter", 2017.
   <https://archive.jlongster.com/A-Prettier-Formatter>. Why Prettier
   chose [1] over ad hoc line breaking: background for this plan's
   "A layout engine" decision.

Background only:

5. Derek C. Oppen, "Prettyprinting", *ACM Transactions on Programming
   Languages and Systems* 2(4), October 1980, pp. 465-483.
   <https://doi.org/10.1145/357114.357115>. The original linear-time
   algorithm with blocks and breaks, which [1] reformulates.
6. John Hughes, "The Design of a Pretty-printing Library", in *Advanced
   Functional Programming*, LNCS 925, Springer, 1995. The combinator
   library that [1] improves on.

The languages opp formats:

7. H. Mössenböck and N. Wirth, *The Programming Language Oberon-2*
   (`Oberon2.pdf`, `~/Reference/Computer/Languages/Oberon/`), Appendix B,
   the grammar, as poc reads it.
8. poc: `src/front/Lexer.Mod`, `src/front/Parser.Mod` and
   `doc/developer/language-extensions.md` in `~/Repos/Oberon/Peaseblossom-main`
   and `~/Repos/Oberon/Peaseblossom`.
9. voc: `src/compiler/OPS.Mod`, `src/compiler/OPP.Mod` and `doc/Features.md`
   in `/usr/local/sw/src/lang/Oberon/vishap/compiler`.
