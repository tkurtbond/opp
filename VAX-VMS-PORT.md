# Porting opp to VAX/VMS 5.5-2

A plan for running opp on VAX/VMS 5.5-2, built by poc, the Peaseblossom
Oberon Compiler (`~/Repos/Oberon/Peaseblossom-main`, 0.7.0). All seven
steps below are done, each with what it found. The authority on VMS is poc's *VAX/VMS Guide*
(`doc/vax-vms-guide.md` in poc's tree, "the guide" below) and the VAX
runtime's source, `rtl/vax`.

## Where things stand

opp already **compiles for the VAX unchanged**. With the
`peaseblossom-vax` package installed, cross-compiling copies of the
sources (with `ArgParser.Mod` beside them) succeeds with no diagnostics:

    poc -target vax-dec-vms -build Opp.Mod          # and OppDocTest.Mod

This writes a `.mar` for each module (about 46,000 lines of MACRO-32 for
both programs) and `Opp.com`, which assembles them and links `OPP.EXE`
against the object library `POCRTL`. opp's source rules (plain Oberon-2,
`LONGINT` for every length, `Platform.Exit` rather than `HALT`, explicit
`Out.Flush`) already suit the VAX runtime, which has `Platform`, `Args`,
`In`, `Out` and `Err` with voc's interfaces.

So the port is not about the language. It is about where opp touches the
host system, nearly all of it in `Opp.Mod`, and on VMS the effects range
from wrong output to options that do nothing. What follows is what has to
change, how to do it without harming the Unix builds, and how to test it on
the VAX.

## What breaks on VMS, and why

Each item names the code and the runtime behaviour it meets.

1. **Standard output loses its line structure.** `FormatFile` writes the
   formatted text with `Out.Char` for every byte, line feeds included. On
   VMS, `Out` writes `SYS$OUTPUT` a record at a time: only `Out.Ln` ends a
   record, and `Out.Char(0AX)` puts a line feed *inside* the current line
   (`rtl/vax/LineOutput.Mod`), which is written in 1024-character records.
   The output would be one long record broken every 1024 bytes. This
   matters most, since writing to standard output is opp's default.
2. **Options in capitals.** DCL capitalizes everything that is not quoted,
   so `opp --pack --align=const FOO.MOD` arrives as `--PACK
   --ALIGN=CONST`. ArgParser doesn't recognize these options, and
   `FindConfigOptions` misses `--NO-CONFIG`. poc solves this for itself by
   lowercasing every argument that starts with `-` (`OptionOnVms` in
   `src/driver/Poc.Mod`).
3. **No wildcards.** DCL does not expand `*.MOD`, so
   `opp --in-place *.MOD` names one file that does not exist. VMS programs
   expand wildcards themselves, as poc does, through `LIB$FIND_FILE`.
   `rtl/vax/Directories.Mod` has that as `StartSearch` and `NextFile`.
4. **`--in-place` fails on most VMS text files, and its backup name is
   not a VMS name.** `WriteFile` opens the file with `Platform.OldRW`,
   which refuses (`RMS$_ORG`) any file that is not Stream_LF, fixed-length
   or undefined. That includes the variable-length-record files EDT, EVE
   and FTP make, which is to say most source files on VMS. Its backup,
   `FOO.MOD.opp-backup`, is not a valid ODS-2 name either: a second period
   starts the version number.
5. **`--output-dir` file names are Unix paths.** `BaseName` cuts at the
   last `/` and `OutputName` joins with `/`. On VMS the name follows the
   last `:`, `]` or `>` and may end in `;version`, and a directory is
   joined to a name with nothing between them (`[.OUT]FOO.MOD`).
   `CheckOutputDir` asks `Platform.IdentifyByName` whether the directory
   exists, but on VMS that opens the name as a file, so a directory is
   never found.
6. **Config files are found by Unix rules.** `UserConfig` reads
   `XDG_CONFIG_HOME` or `HOME`, neither of which VMS has (on VMS,
   `Platform.getEnv` translates a logical name or reads a DCL symbol).
   `.opp.conf` is not a valid ODS-2 name.
7. **Text and help that name Unix paths**: `--config`'s help and the
   comments on config files say `~/.config/opp/opp.conf`.

These already work on VMS without changes:

- **Reading input.** `Platform.OldRO` reads a file of any record format,
  one LF after each record (`rtl/vax/Platform.Mod`), so the scanner sees
  Unix-style text. A record-format file always ends in a line feed, which
  only affects the text after `END M.`, and opp copies that verbatim.
- **Standard input.** `In.Char` reads `SYS$INPUT` a record at a time, with
  an LF after each record.
- **Exit statuses.** `Platform.Exit(n)` ends with `SS$_NORMAL` for 0 and
  `%X10000000 + 8 * n + 2` otherwise, an error that DCL does not print
  its own message for. A procedure recovers `n` as `($STATUS .AND.
  %XFFF8) / 8` (guide, chapter 5). opp's 1, 2 and 3 stay distinguishable.
- **Writing a new file.** `Platform.New` makes a new version, Stream_LF,
  written byte for byte by block I/O. `Truncate`, `Size` and `Unlink`
  work.
- **`Err`** writes `SYS$ERROR`, and `file:line:column: message` reads well
  enough with a VMS file specification in front.
- **The safety check, the scanner, the layout engine** and everything else
  that only computes.

## Design

### One host module, two implementations

The host-specific code moves from `Opp.Mod` into a new module, `OppHost`,
with one interface and two source files:

- `OppHost.Mod` for Unix: the code `Opp.Mod` has now, used by the voc
  build and by poc's LLVM build.
- `vms/OppHost.Mod` for VMS, which imports poc's `Directories`. voc does
  not have that module, so this file can't go in the shared one.

The build chooses the file. The VAX build works in its own directory,
`vax-build/` (as `poc-build/` keeps poc's files away from voc's), where
`vms/OppHost.Mod` is linked under the name `OppHost.Mod`. This avoids
deciding the host at run time, which neither voc nor poc offers in a
portable way. It also keeps VMS code out of the Unix executables, and
`Opp.Mod` remains a single file shared by every build. `vms/OppHost.Mod`
follows the rules in AGENTS.md, "Source must build with both compilers",
apart from importing `Directories`. It is only ever built with poc.

A first cut of `OppHost`'s interface:

| Procedure | Unix | VMS |
| --- | --- | --- |
| `FoldOption(VAR arg)` | nothing | lowercase an argument that starts with `-` |
| `Expand(name, add)` | `add(name)` | each file `Directories.NextFile` finds, or an error if none |
| `BaseName(name)` | after the last `/` | after the last `:`, `]` or `>` (`Directories.NameStart`), without `;n` |
| `WithoutVersion(name)` | `name` | `name` without `;n` |
| `InDirectory(dir, name)` | `dir/name` | `Directories.MakePath` |
| `IsDirectory(dir)` | `Platform.IdentifyByName` (as before) | `Directories.IsDirectory` |
| `UserConfig()` | `$XDG_CONFIG_HOME/opp/opp.conf`, `~/.config/opp/opp.conf` | `OPP$CONFIG`, else `SYS$LOGIN:OPP.CONF` |
| `directoryConfig` | `.opp.conf` | `OPP.CONF` |
| `newVersions` | `FALSE`: `--in-place` writes over the file | `TRUE`: a new version (below) |
| `configHelp` | the `--config` help text | the same, with VMS names |

The writing of files stays in `Opp.Mod`, which uses only `Platform`, the
same on both hosts. `newVersions`, a constant, picks between writing over
the file and writing a new one, so the VMS module needs no code of its
own for it. The Unix build never takes the new-version branch.

### `--in-place` on VMS: a new version

On VMS, `--in-place` writes the formatted text as a **new version** of the
file, with `Platform.New` on the name without its version. The previous
version stays where it is, and it is the backup. This is how every VMS
editor saves a file, so a VMS user would expect it, and `PURGE` cleans up
afterwards.

- It works for files of every record format, since nothing is opened for
  writing.
- No `.opp-backup` file is needed: if the write fails, the new version is
  deleted and the old one is untouched.
- RMS gives a new version the previous version's protection.
- The new version is Stream_LF even if the old one was variable-length.
  EDT, EVE, TYPE and both compilers read it the same way. This needs
  writing in `opp.1` and the VMS notes.
- A file that is already formatted gets no new version, since
  `SameText` already skips it.
- A file named with an explicit version (`FOO.MOD;3`) is read from that
  version, and the new version goes above the file's highest one.

The Unix variant keeps the current scheme that overwrites the file in
place, which keeps the file's links, owner and permissions.

### Standard output: one record per line

`FormatFile`'s loop calls `Out.Ln` for a line feed and `Out.Char` for
everything else. This is the same on Unix (`Out.Ln` writes a line feed
under both voc and poc), so it goes in `Opp.Mod` for every build, and
`make test` shows it changes nothing on Unix.

What remains is a VMS limitation: `LineOutput` splits a line longer than
1024 characters into several records. opp keeps a line that long only
when a comment or string in the source is that long. Through standard
output, such a line would come out broken in two. `--in-place` and
`--output-dir` write files byte for byte and are not affected. opp will
document this rather than work around it, unless a corpus run shows such
lines happen.

### Options in capitals

opp folds each argument before reading it: `OppHost.FoldOption` is called
by `FindConfigOptions` in `Opp.Mod`, and must be called by ArgParser too.
ArgParser reads `Args` itself, so this needs a small change **in
`~/Repos/Oberon/ArgParser`, not here** (AGENTS.md). One option is a hook
on the parser, a procedure that ArgParser applies to each argument before
it parses it, which opp sets to `OppHost.FoldOption`. ArgParser itself
stays portable, and its other users are not affected.

Lowercasing the whole argument is safe for opp. Every option name and
every word `--case-bar`, `--cuddle-*` and `--align` take is lowercase,
and the only other values are file names, which VMS does not
distinguish by case, and numbers. Short options are all lowercase or
digits (`-1 -c -h -i -k -p -w`), so there is no `-P` that folding would
merge with `-p`.

Two DCL hazards to document, not fix: a `-` at the end of a command line
continues the line (so standard input is `"-"`, or no file at all), and
`!` starts a comment.

### Running it

Like any program that takes arguments, `OPP.EXE` runs as a foreign
command:

    $ OPP :== $DISK$USER:[TOOLS]OPP.EXE
    $ OPP --IN-PLACE -P *.MOD

A DCL verb with qualifiers (`OPP/PACK/WIDTH=72`, through a command table,
the guide's chapter 10) would be more natural to a VMS user. It is
**left for later**: it means a second command-line front end, and
foreign commands with folded options are enough to make opp useful.

## Steps

Each step ends with `make test`, `make -f pocGNUmakefile test-poc` and
`make corpus` passing on Unix, and from step 3 on, the VAX tests too.

1. **Portable changes, on Unix alone** (done 2026-10-18). Write the
   formatted text a line at a time (`Out.Ln`). Move the host code into
   `OppHost.Mod` with the interface above, Unix implementations only, and
   route `Opp.Mod` through it. No output changes. `make format` and the
   `opp-own-source` fixture now cover `OppHost.Mod`. A file argument now
   goes through `OppHost.Expand`, and one that names no file is reported
   as `opp: no file matches NAME`, exit status 1. On Unix that never
   happens, since the Unix `Expand` passes every name on.
2. **ArgParser's argument hook**, in its own repository, with its own
   tests (done 2026-10-18). A parser's `filter`, an `ArgumentFilter`, is
   given every argument the parser reads, options, their values and
   ordinary arguments alike, before it parses it; a command's parser
   without one uses the one above it. The example program `Folded.Mod`
   and the fixtures `tests/filter-*.test` test it. Reinstall the voc
   module and the poc library. opp sets the filter to
   `OppHost.FoldOption`, which on Unix does nothing.
3. **`vms/OppHost.Mod` and a VAX build on Unix** (done 2026-10-18). A
   `vaxGNUmakefile` (on the model of `pocGNUmakefile`) builds `Opp` and
   `OppDocTest` in `vax-build/` with `poc -target vax-dec-vms`, ArgParser
   compiled from its source (`ARGPARSER_SRC`, default
   `~/Repos/Oberon/ArgParser`), and gathers what VMS needs: the `.mar`
   files and the `.com` file. `make -f vaxGNUmakefile` also checks that
   the VMS module compiles, which can run without a VAX. `make format`
   and the `opp-own-source` fixture cover `vms/OppHost.Mod`. Its
   procedures cannot run on Unix: poc's `Directories` there follows Unix's
   rules for names. They are first tried on the VAX, in steps 4 and 5.
4. **First runs on the VAX.** Use `tools/vax-do` from poc's tree to build
   `OPP.EXE` on the guest and run `OppDocTest`. Its output must match
   `tests/opp-doc-selftest.test`. Then format a few files and compare
   them with the host's output. Measure the time and memory a large file
   takes (`OppFormat.Mod` takes 0.04 s on the host). opp holds the whole
   file and its layout document, and the heap is limited to three
   quarters of the paging-file quota (guide, chapter 6), so note the
   `PGFLQUOTA` it needs.

   Done 2026-10-18, in one `tools/vax-do` run, with the runtime
   compiled from `rtl/vax` (`-clear-library-path -import-path`) and
   `PocRtl.mar` sent as `POCRTL.MAR`, as poc's `tools/vax-suite` does, so
   that nothing had to be installed on the guest first:

   - Assembling and linking `OPP.EXE` and `OPPDOCTEST.EXE` and the
     runtime took 12.5 seconds (10.4 of CPU).
   - `OppDocTest` passed all 96 checks, its output that of
     `tests/opp-doc-selftest.test`.
   - `OppFormat.Mod` (1401 lines) formatted in each of `-1`, `-p` and
     `-k --no-module-indent`, and a fixture input at `-p -w 60
     --align=all`, came out byte for byte as the host's, with options
     given unquoted, so in capitals. A syntax error gave the host's
     message and exit status 1, `%X1000000A`, the file named in capitals
     as it was typed.
   - `OppFormat.Mod` takes about 13.3 seconds of CPU in each mode, where
     the host takes 0.04: about 330 times as long. `--check` over the 8
     sources, `OPP*.MOD`, takes 38 seconds. The peak virtual size was
     19,322 pages (about 10 MB), against a `PGFLQUOTA` of 300,000.
   - `OPP*.MOD` expanded to the 8 sources, named by their whole
     specifications (`DUA1:[USERS.POC]OPPDOC.MOD`). A pattern that
     matched nothing showed a bug: opp then found no files and read
     standard input instead. It now reads standard input only when the
     command line names no file at all.
   - Building on VMS itself was not tried: the guest's only poc,
     `[.BIN]POC.EXE`, is 0.5.0, a stage of poc's bootstrap, which cannot
     be expected to build 0.7.0's runtime. It needs the 0.7.0 kit
     installed there, which a build from the kit's source needs too (step 7).

5. **The fixtures on the VAX** (`tools/vax-tests`, below), then a VMS
   version of `tests/in-place.sh` for `--in-place` (versions) and
   `--output-dir` (VMS directories). Done 2026-10-18: `make -f
   vaxGNUmakefile test-vax` runs `tools/vax-tests`, which runs 117 of the
   118 fixtures and 22 checks of `--in-place` and `--output-dir` on the
   guest, all passing, in one `vax-do` run of a few minutes. Only
   `opp-output-dir-clash` prints something else there, its output name
   VMS's (`tests/vax/opp-output-dir-clash.err`), and `opp-output-dir-own`
   cannot be made for the guest (`tests/vax/opp-output-dir-own.skip`); the
   usage's `--config` help, VMS's, is substituted in what the host prints.
   The checks show that on VMS `--in-place` writes a Stream_LF new version
   of a variable-length file and leaves the old one as it was, gives none
   to a file that is formatted already, has a syntax error or fails the
   safety check, keeps the protection, reads a version that is named and
   writes above the highest, and expands a wildcard; and that
   `--output-dir` takes `[.OUT]`, refuses the input's own directory, a
   directory that is not there, and two files of one name in different
   case. A bug planted in `vms/OppHost.Mod` (a version kept on the name
   written) fails its check.
6. **Documentation.** A VMS section in `opp.1` and `README.md`: the
   foreign command, folded options, versions with `--in-place`, the config
   file names, the 1024-character record limit and the DCL hazards. Also
   a `VAX/VMS` section in `AGENTS.md`: `vms/OppHost.Mod`, `vax-build/`,
   and how to run the VAX tests. Optionally, an `OPP.HLP` for a VMS help
   library, so that `HELP OPP` works. Done 2026-10-18: the manual has a
   `VAX/VMS` section, and `README.md` one too, with the VAX build;
   `vms/OPP.HLP` is the help library's text, built on the guest with
   `LIBRARY/CREATE/HELP` and read with `HELP/LIBRARY` (its topics, and
   abbreviations of them, found).
7. **A kit.** `make -f vaxGNUmakefile kit` writes the `.mar` files,
   `OPP.COM` and a `SETUP.COM` that defines the foreign command. The kit
   builds against the `POCRTL` of the poc kit of the same version (LINK
   checks this, guide chapter 4), and the resulting `OPP.EXE`, linked
   against the object library, runs without poc installed. Building on
   VMS from source (`POC OPP.MOD` with `ArgParser.Mod` on `POC$IMPORT`)
   should also work, since poc on VMS uses the same front end. Step 4
   should try it once.

   Done 2026-10-18, with one change of design: the kit carries poc's
   runtime too, so that it needs no poc kit on VMS at all, only MACRO,
   LINK and LIBRARY. `tools/make-vax-kit` writes `vax-kit/OPP-KIT.COM`,
   one DCL procedure of about 1.3 MB that unpacks itself, after poc's own
   kit (`$ CREATE`, `$ DECK/DOLLARS=`, the lines, the marker), into the
   directory it is run in:

   - `README.TXT` (from `vms/README.TXT`, with the version in it),
     `BUILD.COM`, `SETUP.COM`, `OPP.HLP`, `OPP.TXT` (the manual, from
     `man`), `LICENSE.TXT` and `VERSION.TXT` (the commit, the date and
     the poc that compiled it; opp has no version number);
   - `[.KIT]`: opp's MACRO-32, compiled with the runtime from `rtl/vax`'s
     source as in step 4, poc's `OPP.COM`, and the runtime's
     `PocRtl.mar` as `POCRTL.MAR`;
   - `[.SRC]`: the Oberon-2 source, with `vms/OppHost.Mod` as
     `OPPHOST.MOD` and `ArgParser.Mod`, for building with poc on VMS;
   - `[.BIN]`, empty, for `OPP.EXE`.

   It refuses to unpack where a kit has been unpacked. `BUILD.COM`
   assembles `POCRTL.MAR`, points `POC$RTL` at `[.KIT]` while `OPP.COM`
   runs (putting back a definition of the process's own after), moves
   `OPP.EXE` to `[.BIN]`, deletes the objects, and makes `OPP.HLB`; it
   builds only what is not there. `SETUP.COM` defines `OPP` and the first
   free one of `HLP$LIBRARY`, `HLP$LIBRARY_1`, ... as `OPP.HLB`, unless
   one names it already, so that `HELP OPP` needs no `/LIBRARY`.

   `CREATE` takes lines of at most 255 characters, which `make-vax-kit`
   checks of every file; one line of `Opp.Mod`, `--align`'s help, had 565,
   and is now built from parts (AGENTS.md has the rule).

   `make -f vaxGNUmakefile check-kit` runs `tools/check-vax-kit`, which
   unpacks the kit in `[.OPPT_KIT]` on the guest, builds and sets it up
   twice each, and runs `HELP OPP EXIT_STATUS`, `OPP --CHECK` over the
   kit's own source and `OPP -P` on `OPPTEXT.MOD`, compared with the
   host's; then deletes all it made. All 9 checks pass, in a few
   minutes; a `SETUP.COM` planted to define the help library twice fails
   its check.

   Building from `[.SRC]` with poc on VMS is still not tried: the
   guest's poc is 0.5.0 (step 4), and needs poc's 0.7.0 kit installed
   first.

## Testing on the VAX

(As planned before step 5; `tools/vax-tests`'s own header says how it
is done now. The fixtures are compared with the host's `Opp`, so their
mixed output need not be reproduced on the guest.)

The model is poc's `tools/vax-suite`: build for the host and for the VAX,
run both, compare. It drives the guest through `tools/vax-do` (FTP and
telnet, the login in `~/.netrc-poc-vax`, `VAX_HOST`), which holds
`tools/vax-lock.sh`'s lock, so opp's runs and poc's take turns. opp's
script would call poc's tools by `POC_SRC`
(default `~/Repos/Oberon/Peaseblossom-main`) rather than copy them.

`tools/vax-tests` reads the fixtures in `tests/*.test` (118 of them, all
of `Opp` but one) and writes one DCL procedure that runs each one as a
foreign command, with every argument quoted so DCL keeps its case.
Standard output and standard error go to files, and the procedure
records the status. Everything is sent in one `vax-do` call with the 31
input files in `tests/data`, all of which are valid ODS-2 names. On the
host, the results are compared with each fixture's `output` and
`status`, converting `$STATUS` back to the Unix code as `vax-suite` does.

Where the VAX must differ, an `expected-vax` file next to the fixture
gives what the VAX should print, as in poc. The expected differences:

- the 7 config fixtures (`env` and `dir`), which use `XDG_CONFIG_HOME`,
  `HOME` and `.opp.conf`. They need VMS counterparts that define
  `OPP$CONFIG` and use `OPP.CONF`;
- messages that name a file, which on the VAX print the file name in
  capitals (or its full specification, if a wildcard found it);
- `--in-place` and `--output-dir`, which `tests/in-place.sh` covers on
  Unix and which a DCL counterpart covers on VMS.

A broader check is to run the corpus on the guest. Formatting is pure
computation, so for the same input and options, the VAX must produce
exactly the host's output. Format a selection of the corpus on the guest
with `--output-dir`, bring the results back, and `cmp` them with the
host's. Any difference is a bug, in opp or in poc's VAX back end. Report
the second kind to poc, the way voc's go to vishap-bugs. How much of the
corpus fits in one run depends on step 4's timings.

## Decisions

Settled 2026-10-18:

1. **Config file names on VMS**: `OPP$CONFIG` (a logical name naming the
   user's file), else `SYS$LOGIN:OPP.CONF`, plus `OPP.CONF` in the
   default directory.
2. **`--in-place` writes a new version**, rather than overwriting the
   version in place. Overwriting works only on Stream_LF files and would
   need a valid backup name.
3. **The 1024-character record limit on standard output is documented**,
   not worked around. `--output-dir` and `--in-place` are not affected.
4. **A DCL verb** (`OPP/PACK`) comes later, if at all; foreign commands
   come first.
5. **Display width of DEC MCS text stays as it is.** `OppText.Width`
   assumes UTF-8 and gives bytes 80X to 0BFX no width, but VMS text is
   often DEC MCS, where some of those bytes are printable characters
   (`£`, `§`, `«`, a non-breaking space). This only affects how lines
   fit, never the meaning, since the safety check compares bytes. It is
   revisited only if a VMS user's comments show the problem.

## Left out

- voc on VMS: there is none. On the VAX, opp is built by poc only.
- VMS versions after 5.5-2 and Alpha or Itanium: poc's VAX back end is
  VAX MACRO-32 only. Extended DCL parsing (VMS 7.3-2), which keeps the
  case of arguments, does not exist on 5.5-2, so folding is always
  needed there.
- ODS-5 file names: VMS 5.5-2 has only ODS-2.
