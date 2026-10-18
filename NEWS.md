# NEWS

What changed in each release of opp, newest first.

## 0.1.0 (2026-10-18)

The first release. opp, the Oberon pretty printer, reformats Oberon-2
modules written for poc (the Peaseblossom Oberon Compiler) or voc
(Vishap Oberon), with both compilers' extensions to the language, to a
maximum line length.

- **Three modes**: every statement on its own line (`-1`, the default);
  short statements and declarations packed onto shared lines (`-p`); or
  the author's own grouping kept while it fits (`-k`). `--width` (default
  80) and `--indent` (default 2) set the line length and the indentation
  step; `--no-module-indent` starts a module's declarations at column 1.
- **Nothing is lost.** Every comment is kept, with the author's blank
  lines, and the text after the module's closing period is copied as it
  is. Before it writes anything, opp rescans its output and checks that
  it has the input's tokens and comments, and parses; if not, it reports
  an internal error and writes nothing. Formatting its own output again
  changes nothing.
- **Style kept as written**, where authors differ, with options to force
  it either way: a bar before a `CASE`'s first arm (`--case-bar`), a
  blank before the parenthesis of a call or a procedure's parameters
  (`--paren-space`), a body's first statement on `BEGIN`'s line and `END`
  after it (`--cuddle-begin`, `--cuddle-end`), and the author's tabular
  alignment (`--align`, which also lines up the `=` of constants and
  types, the types of variables and fields, trailing comments, `CASE`
  bodies and assignments' `:=`, or puts packed declarations in a grid).
- **Files**: standard input to standard output, or files formatted in
  place (`--in-place`), or written to another directory (`--output-dir`);
  `--check` names each file that is not formatted and exits 1, for a
  build or a commit hook. A syntax error is reported as
  `file:line:column: message`, and nothing is written for that file.
- **Config files**: the user's (`~/.config/opp/opp.conf`) and the current
  directory's (`.opp.conf`) hold options that say how to format, under
  the command line's; `--config` and `--no-config` choose others or none.
- **Builds** with voc or with poc; `make install` installs `opp` and its
  manual, `opp.1`. It needs ArgParser 0.1.0 or later
  (`tkurtbond/oberon-argparser`). `opp --version` prints opp's version.
- **VAX/VMS 5.5-2**: built by poc and cross-compiled on Unix, opp runs on
  VMS with the same options and the same output. It comes as a kit,
  `OPP-0-1-0.COM`, a DCL procedure that unpacks itself; `@BUILD` builds it
  with MACRO, LINK and LIBRARY alone, and `@SETUP` defines the command
  `OPP` and `HELP OPP`. Options may be typed in either case, wildcards are
  expanded, and `--in-place` writes a new version of each file.
