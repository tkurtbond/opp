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

**Status: under construction.** Phase 0 (the repository, the builds and the
command line) is done; opp does not format yet. `PLAN.md` has the design
and the phases.

## Usage

```
opp [options] [file ...]
```

With no files, or `-`, opp reads standard input. Formatted text goes to
standard output, unless `--in-place` or `--check` is given.

| Option | Meaning |
| --- | --- |
| `-w N`, `--width N` | maximum line length (default 80; 20..1000) |
| `-i N`, `--indent N` | columns per indentation level (default 2; 1..16) |
| `-1`, `--one-per-line` | every statement on its own line (the default) |
| `-p`, `--pack` | pack short statements and declarations onto shared lines |
| `-k`, `--keep-lines` | keep statements and declarations on shared lines where the source has them, while they fit |
| `--no-module-indent` | start a module's declarations and statements at column 1 |
| `--in-place` | replace each file with its formatted text |
| `-c`, `--check` | write nothing; exit 1 and name each file that would change |
| `-h`, `--help` | show the usage and exit |

Exit status: 0 success; 1 a syntax error, an unreadable file, or (with
`--check`) a file that would change; 2 a command line mistake; 3 an
internal error.

## Building, testing and installing

opp is written in Oberon-2 and builds with either compiler. It needs
`ArgParser` from [oberon-argparser](https://github.com/tkurtbond/oberon-argparser)
(`~/Repos/Oberon/ArgParser`): `make install` there for voc, and
`make -f pocGNUmakefile install` there for poc.

```sh
make                 # build Opp with voc, statically linked
make test            # build, then run the fixtures in tests/
make install         # copy Opp to ~/local/bin as opp (BINDIR to change)
make uninstall       # remove ~/local/bin/opp
make -f pocGNUmakefile test-poc   # build with poc instead, then run the fixtures
make -f pocGNUmakefile install    # copy poc's Opp to ~/local/bin as opp
```

The poc and voc builds install to the same place under the same name, so
whichever was installed last replaces the other.
