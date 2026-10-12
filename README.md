# opp - the Oberon pretty printer

This software is developed with the aid of AI.

opp reformats Oberon-2 modules written for
[poc](https://github.com/tkurtbond/peaseblossom) (the Peaseblossom Oberon
Compiler) or [voc](https://github.com/vishapoberon/compiler) (Vishap
Oberon), including both compilers' extensions to the language. It keeps
every comment, lays the code out within a maximum line length, and puts
statements one per line, packs short ones onto shared lines, or keeps the
author's own grouping. Before it writes anything it checks that its output
has exactly the tokens and comments of its input.

**Status: working.** opp formats files to standard output or in place,
and checks them with `--check`; every formatted text is checked against
its input before it is written. `opp.1` is the manual; `PLAN.md` has the
design, the decisions, and what may come later.

## Usage

```
opp [options] [file ...]
```

With no files, or `-`, opp reads standard input. Formatted text goes to
standard output, unless `--in-place`, `--output-dir` or `--check` is
given.

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
| `--align WORDS` | what to line up, as words separated by commas: `const`, `type`, `var`, `field`, `init`, `comment`, `case`, `assign`, or `all`, for opp to line up; `no` before one (`nocomment`, `noall`) for one space; `keep` (default) or `drop` for the author's spaces elsewhere; later words win. With `-p` or `-k`, `const` puts constants in a grid of straight columns |
| `--in-place` | replace each file with its formatted text |
| `--output-dir DIR` | write each file's formatted text to `DIR/` under the file's own name; `DIR` must exist |
| `-c`, `--check` | write nothing; exit 1 and name each file that would change |
| `--tokens` | list each file's tokens and comments instead (a debugging aid) |
| `--damage N` | for opp's tests: spoil the formatted text (1 a token, 2 a comment, 3 the text after the module) so the safety check fails |
| `--config FILE` | read options from `FILE` instead of the config files |
| `--no-config` | read no config file |
| `-h`, `--help` | show the usage and exit |

Exit status: 0 success; 1 a syntax error, an unreadable file, or (with
`--check`) a file that would change; 2 a command line or config file
mistake; 3 an internal error.

## Config files

Before the command line, opp reads options from config files: the user's,
`$XDG_CONFIG_HOME/opp/opp.conf` (or `~/.config/opp/opp.conf`), then the
current directory's, `.opp.conf`. Each line is an option as the command
line gives it, without its `--` if you like, its value after a space or
`=`; `#` starts a comment:

```
# ~/.config/opp/opp.conf
width = 100
pack
align all,nocomment
```

A later setting wins over an earlier one: the directory's file over the
user's, and the command line over both. Only options that say how to
format may be in a config file; `--in-place`, `--output-dir`, `--check`,
`--tokens` and `--damage` may not. `--config FILE` reads `FILE` instead, and
`--no-config` reads none. A mistake in a config file is reported as
`file:line: message`, with exit status 2.

## Building, testing and installing

opp is written in Oberon-2 and builds with either compiler. It needs
`ArgParser` from [oberon-argparser](https://github.com/tkurtbond/oberon-argparser)
(`~/Repos/Oberon/ArgParser`): `make install` there for voc, and
`make -f pocGNUmakefile install` there for poc.

```sh
make                 # build Opp with voc
make test            # build, then run the fixtures in tests/
make corpus          # format poc, voc and other Oberon repos, and check it
make format          # format opp's own source with opp
make install         # copy Opp to ~/local/bin as opp, opp.1 to ~/local/share/man/man1
make uninstall       # remove them (BINDIR and MANDIR to change the places)
make -f pocGNUmakefile test-poc   # build with poc instead, then run the fixtures
make -f pocGNUmakefile install    # copy poc's Opp to ~/local/bin as opp
```

The poc and voc builds install to the same place under the same name, so
whichever was installed last replaces the other.

The voc build links dynamically, with `tools/voc-heap-gc-spill.c` (from
Peaseblossom) in place of voc's `Heap_GC`: without it, voc's garbage
collector can free objects still in use, and opp garbled or crashed on
large files.
