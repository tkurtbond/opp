# Releasing opp

How a release of opp is made. The model is poc's own process
(`~/Repos/Oberon/Peaseblossom-main/doc/developer/DEVELOPER.md`, section
7, "Making a release"), cut down to what opp needs: one program, a man
page, and a kit for VAX/VMS, with no packages; ArgParser's release
(its AGENTS.md, "Making a release") is the same process at a smaller
scale. The last section, "How the process was built", records the steps
that made it, in 2026-10.

## What a release is

A release `x.y.z` is:

- **The version in the program**: `opp --version` prints `opp x.y.z`.
  The manual's header and `--version` entry, and the `--version` entries
  of `README.md` and `vms/OPP.HLP`, show it.
- **A section in `NEWS.md`**, `## x.y.z (date)`: what changed for a user
  (options, output, fixes), not every commit, newest first.
- **A signed tag** `vx.y.z` on the release's commit, pushed to GitHub.
- **A tarball** `opp-x.y.z.tar.gz`, which unpacks into `opp-x.y.z/`:
  what git tracks at the tag, and nothing built. It does not hold
  ArgParser, which has releases of its own; opp needs ArgParser 0.1.0 or
  later.
- **The VMS kit** `OPP-x-y-z.COM`, the periods made hyphens (a VMS name
  has one period), as poc's kits are named. Its `VERSION.TXT` gives the
  version and the commit, and it carries its own `ArgParser.Mod`.
- **A `.sha256` and a signature, `.asc`,** for each of the tarball and
  the kit.
- **A GitHub release** `vx.y.z`, "opp x.y.z", with those six files, and
  notes from `NEWS.md`.

## Version numbers

- Semantic versions, `major.minor.patch`. While the major is 0, a minor
  release may change the default output; a patch release only fixes bugs,
  and changes output only where it was wrong (a lost comment, a crash, a
  line too long that could have been broken).
- **A change of the default output is always in the notes**, said
  plainly: a user who runs `opp --check` in a build sees every such file
  fail after upgrading. `--paren-space keep` is such a change: code
  written `P (x)` no longer closes up.
- Between releases the version stays that of the last release; `0.0.0`
  is the version before the first. A build from a later commit is not a
  release: `git describe`, and a kit's `VERSION.TXT`, say which commit it
  is.
- A patch release from an older minor is not planned for: while opp is
  0.x, the next release comes from `main`.

## The tools

- **`make set-version VERSION=x.y.z`** (`tools/set-version`) sets the
  version everywhere it is written: `version` in `Opp.Mod`, the manual's
  `.TH` line (with today's date) and `--version` entry, and the
  `--version` entries of `README.md` and `vms/OPP.HLP`. It dates the
  heading `## x.y.z (unreleased)` in `NEWS.md`, or adds `## x.y.z (date)`
  if there is none; then builds `Opp` and regenerates
  `tests/opp-version.test` from a real run. It refuses a version that is
  not `x.y.z` or not greater than the current one, and changes nothing
  unless each place holds the current version exactly once.
- **`make dist`** writes, in `dist/`, `opp-x.y.z.tar.gz` (`git archive`
  of `HEAD`) and `OPP-x-y-z.COM` (`make -f vaxGNUmakefile kit
  KIT=dist/...`), each with its `.sha256`. It refuses the version 0.0.0,
  a working tree that differs from `HEAD`, a `NEWS.md` without a dated
  section for the version, and a tag `vx.y.z` on another commit.
- **`make distcheck`** runs `make dist`, then unpacks the tarball in a new
  temporary directory and runs `make test` and `make -f pocGNUmakefile
  test-poc` there, so that a file git does not track, or a test that
  needs this tree, fails it.
- **`make dist-sign`** writes the `.asc` of the tarball and of the kit,
  with gpg's default key (`GPG_KEY=` for another).
- **`tools/check-vax-kit dist/OPP-x-y-z.COM`** unpacks, builds, sets up
  and uses that kit on the VAX/VMS guest (`VAX_HOST`, `VAX_NETRC`;
  `POC_SRC` is poc's source tree). It checks the very file that is
  published; `make -f vaxGNUmakefile check-kit` makes a kit again first.
- `make clean` removes `dist/`.

`NEWS.md` is kept as changes are made (AGENTS.md): a change a user would
notice adds a line under `## x.y.z (unreleased)`, so the notes are mostly
written by release time.

## Making a release

On `main`, with a clean working tree:

1. **The version.** `make set-version VERSION=x.y.z`. Then finish
   `NEWS.md`'s section for it: read `git log v<last>..` against what the
   section already says, add what it lacks, and say every change of the
   default output plainly. `set-version` dates the section and the
   manual today; if the release slips to another day, fix both dates by
   hand before committing.
2. **Check**, all of it:

       make test
       make -f pocGNUmakefile test-poc
       make corpus
       make -f vaxGNUmakefile test-vax

   Compare the long-line counts `make corpus` prints with the last
   release's: `corpus: ok` alone does not show a line that has grown too
   long. `test-vax` needs the guest and takes a few minutes.
3. **Commit**, "opp x.y.z", and do not push yet. If opp needs something
   of ArgParser's that no ArgParser release has, release ArgParser first,
   and say in `NEWS.md` which version opp needs.
4. **The tarball and the kit**, from that commit:

       make distcheck
       tools/check-vax-kit dist/OPP-x-y-z.COM
       make dist-sign

   Make them once and publish those: each `make dist` writes a new
   tarball (tar and gzip record times), with another sum. If a check
   fails, fix it in a new commit (or amend the unpushed one), and start
   this step again.
5. **Push and tag**: push `main`, then tag the commit, signed, and push
   the tag:

       git push origin main
       git tag -s vx.y.z -m "opp x.y.z"
       git tag -v vx.y.z
       git push origin vx.y.z

   gpg asks for the key's passphrase, for the tag here and for
   `dist-sign` above. Over ssh its graphical pinentry appears on the
   machine's own screen; in a terminal, set `GPG_TTY=$(tty)` and use
   `--pinentry-mode loopback`, as poc's DEVELOPER.md says.
6. **Publish**, with the notes below in a file:

       gh release create vx.y.z dist/opp-x.y.z.tar.gz{,.sha256,.asc} \
         dist/OPP-x-y-z.COM{,.sha256,.asc} --title "opp x.y.z" --notes-file <notes>

7. **Check the release**: download its files into an empty directory
   (`gh release download vx.y.z -R tkurtbond/opp`), check both sums
   (`sha256sum -c *.sha256`) and both signatures (`gpg --verify`), and
   compare the unpacked tarball with `git archive` of the tag.

### The notes

The release's notes are `NEWS.md`'s section for `x.y.z`, without its
heading:

    awk '/^## /{p = ($2 == "x.y.z")} p' NEWS.md | sed 1d

then how to install it, with this release's names:

    ## Installing

    opp needs ArgParser 0.1.0 or later
    (https://github.com/tkurtbond/oberon-argparser/releases): install it
    first, with `make install` for voc, or `make -f pocGNUmakefile
    install` for poc.

    Check the tarball (`sha256sum -c opp-x.y.z.tar.gz.sha256`, `gpg
    --verify opp-x.y.z.tar.gz.asc`), unpack it, and in `opp-x.y.z/`:

        make && make test && make install                  # with voc
        make -f pocGNUmakefile test-poc && make -f pocGNUmakefile install   # with poc

    `make install` copies `opp` to `~/local/bin` and `opp.1` to
    `~/local/share/man/man1` (`BINDIR`, `MANDIR` for others).

    On VAX/VMS 5.5-2: copy `OPP-x-y-z.COM` to VMS in ASCII mode, and in
    an empty directory run `@[-]OPP-x-y-z`, then `@BUILD`, which needs
    MACRO, LINK and LIBRARY but not poc, and `@SETUP`, in each process
    that uses opp. The kit's `README.TXT` says more.

## Decisions

Settled 2026-10-18, with the user:

- **The first version is 0.1.0**: opp is young, and 0.x leaves room to
  change its default output in a minor release.
- **ArgParser is not bundled** in the tarball: it is a shared module, kept
  in its own repository (AGENTS.md), with releases of its own, beginning
  with 0.1.0. opp's notes name the oldest ArgParser release opp builds
  with. The VMS kit carries its own `ArgParser.Mod`, compiled in.
- **Releases are signed**, the tag and both files, with the user's gpg
  key, as poc's are.
- **`--version`, not `-V`**: opp's short options are few, and `-V` is
  taken to mean verbose by some tools.
- **No packages yet** (RPM, FreeBSD and OpenBSD ports, pkgsrc): poc has
  them because others install it system-wide; opp can follow when
  someone needs it. `make install`'s `BINDIR` and `MANDIR` are enough for
  a package to use later.
- **`NEWS.md` and the GitHub release are the record** of each release;
  `PLAN.md` does not repeat it.

## Left out

- Packages for any system (above).
- A project web site beyond the GitHub release page.
- Release automation in CI: the checks need the VAX guest and the
  corpus's repositories, which only the user's machines have.
- A DCL verb for VMS (VAX-VMS-PORT.md, "Decisions").

## How the process was built

Planned on 2026-10-18, when opp had no version, no tags, no changelog and
no `make dist`, and was published only as its repository, then built in
these pieces, each checked as every change is (`make test`, `make -f
pocGNUmakefile test-poc`, `make corpus`):

1. **ArgParser's filter pushed** (`19ede65`), which opp needs: until then
   a clone of both repositories from GitHub did not build. ArgParser 0.1.0
   followed, its first release, made by its own `make dist`, `distcheck`
   and `dist-sign`.
2. **`--version`** and the constant `version`, `0.0.0` before the first
   release. Like `--help`, it cannot be in a config file (fixture
   `opp-config-bad-version`).
3. **`make set-version`**, tried in a fresh clone: 0.1.0 set in all five
   places, the fixtures passing; 0.1.0 again, 0.0.0, 0.1 and 01.0.0
   refused; 0.1.1 after it put its heading above 0.1.0's. It showed that a
   `make` run under another (`set-version`'s `make Opp`) linked `Heap_GC`
   twice, since the `GNUmakefile` put its exported `LDFLAGS` before what
   it inherited, its own included; it now takes them out first.
4. **`NEWS.md`**, begun with the section for 0.1.0, `(unreleased)`, which
   `set-version` dates.
5. **The kit's version and name**: `tools/make-vax-kit` puts `Opp.Mod`'s
   version in `VERSION.TXT` with the commit, and takes `-o` for its path;
   the kit's `README.TXT` and header name it (`vms/README.TXT`'s `@KIT@`);
   `tools/check-vax-kit` takes the kit's path, and `vaxGNUmakefile` gives
   both `KIT=`. A kit `OPP-0-0-0.COM` passed `check-kit` on the guest.
6. **`make dist`, `distcheck` and `dist-sign`**, tried in a clone at 0.1.0:
   each refusal; `distcheck`, 124 ok and 30 in-place ok with voc and with
   poc in the unpacked tarball, which held exactly what `git ls-files`
   lists; both sums; and `dist-sign` with a throwaway key. The make in the
   unpacked tarball runs with `LDFLAGS` unset: this make exports them with
   its own path to the spill object, which the other's filter would not
   take out. The kit has a `.sha256` and an `.asc` as the tarball does.
7. **This file**, the plan made the process. Writing the steps down
   changed three things: `main` is pushed after `distcheck` and the kit's
   check pass, not before, so a failure is fixed before anything is
   published; step 7 checks what GitHub serves; and the release is
   recorded in `NEWS.md` and on GitHub, not in `PLAN.md` too.
