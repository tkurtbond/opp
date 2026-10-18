# Releasing opp

A plan for making releases of opp, and, once it is carried out, the
record of how one is made. Nothing here is done yet. The model is poc's
own process (`~/Repos/Oberon/Peaseblossom-main/doc/developer/DEVELOPER.md`,
section 7, "Making a release"), cut down to what opp needs: one program, a
man page, and a kit for VAX/VMS, with no packages yet.

## Where things stand

opp has no version number, no tags, no changelog and no `make dist`. It
is published only as its GitHub repository (`tkurtbond/opp`), which a
user clones and builds. The one version-like thing is the VMS kit's
`VERSION.TXT`, which `tools/make-vax-kit` writes from `git describe` and
the date ("opp 5e34921 of 2026-10-18, compiled by poc 0.7.0 ...").

Building opp needs ArgParser, from its own repository
(`tkurtbond/oberon-argparser`, `~/Repos/Oberon/ArgParser`), and opp needs
its argument filter (VAX-VMS-PORT.md step 2). **ArgParser 0.1.0**, the
first release with the filter, was released on 2026-10-18 (tag `v0.1.0`,
a GitHub release with its tarball, `.sha256` and `.asc`; its AGENTS.md,
"Making a release", says how), so opp needs ArgParser 0.1.0 or later.
Its release is the model for opp's, on a smaller scale: `VERSION` in its
`GNUmakefile`, `NEWS.md`, and `make dist`, `distcheck` and `dist-sign`.

## What a release is

A release `x.y.z` is:

- **The version in the program**: `opp --version` prints `opp x.y.z`,
  and the manual's header, `README.md` and the VMS help name it.
- **A signed tag** `vx.y.z` on the commit, pushed to GitHub.
- **A tarball** `opp-x.y.z.tar.gz`, which unpacks into `opp-x.y.z/`: what
  git tracks at the tag (the sources, `GNUmakefile`, `pocGNUmakefile`,
  `vaxGNUmakefile`, `vms/`, `tools/`, `tests/`, the documents), with its
  `.sha256` and, signed, its `.asc`. It does not hold ArgParser (below).
- **The VMS kit** `OPP-x-y-z.COM`, the periods made hyphens, as poc names
  its kits (`POC-0-7-0.COM`): a VMS name, which may have one period only.
  Its `VERSION.TXT` gives the version as well as the commit.
- **A GitHub release** `vx.y.z`, titled "opp x.y.z", with the tarball,
  its `.sha256` and `.asc`, and the kit, and notes taken from `NEWS.md`.
- **An entry in `NEWS.md`**, a new file: one section per release, newest
  first, saying what changed for a user (new options, changed output,
  fixes), not every commit.

## Version numbers

- Semantic versions, `major.minor.patch`. While the major is 0, a minor
  release may change the default output; a patch release only fixes bugs,
  and changes output only where it was wrong (a lost comment, a crash, a
  line too long that could have been broken).
- **A change of the default output is always in the notes**, since a user
  who runs `opp --check` in a build sees every file fail after upgrading.
  `--paren-space keep` is such a change: code written `P (x)` no longer
  closes up.
- The first release is **0.1.0**.
- Between releases the version stays that of the last release. A build
  from a commit after it is not a release; `VERSION.TXT` in a kit, and
  `git describe`, say which commit it is.

## Pieces to build

1. **Push ArgParser** (`19ede65`), so that opp's `main` builds from
   GitHub. Done 2026-10-18.
2. **The version in opp.** A constant `version` in `Opp.Mod`, `--version`
   printing `opp x.y.z` and exiting 0, like `--help` (ArgParser's
   `MakeOption`, a handler that prints and exits). Its usage line, and an
   entry in `opp.1`, `README.md` and `vms/OPP.HLP`, kept in step as
   AGENTS.md says. The manual's `.TH` line takes the version as its
   source field: `.TH OPP 1 <date> "opp x.y.z" "User Commands"`. A fixture
   `opp-version` checks the output, regenerated from a real run each time
   the version changes, never edited by hand. The help fixtures change
   once, for the new line, as they did for `--paren-space`.

   Done 2026-10-18. `version` is `0.0.0` until the first release, so that
   `make set-version VERSION=0.1.0` raises it. `--version` cannot be in a
   config file, like `--help` (fixture `opp-config-bad-version`). The
   README's and `vms/OPP.HLP`'s entries for `--version` show the version
   (`opp 0.0.0`), which is where `set-version` changes it there.
3. **`make set-version VERSION=x.y.z`** (`tools/set-version`, Python):
   sets `version` in `Opp.Mod`, the `.TH` line of `opp.1` (version and
   today's date), and the version `README.md` and `vms/OPP.HLP` name; adds
   a heading for `x.y.z` to the top of `NEWS.md` if it has none, for the
   notes to be written under; then builds `Opp` and regenerates
   `tests/opp-version.test` from a real run. It refuses a version that is
   not `x.y.z`, or not greater than the current one.
4. **`NEWS.md`**, begun with 0.1.0: what opp does, as of its first
   release (the three modes, the safety check, the style options, config
   files, the VAX/VMS port).
5. **The kit's version.** `tools/make-vax-kit` reads `version` from
   `Opp.Mod` and puts it in `VERSION.TXT` and the kit's first line with
   the commit ("opp 0.1.0, 5e34921, of 2026-10-18, compiled by ..."). It
   takes `-o NAME` for the kit's name, so that `make dist` can write
   `OPP-x-y-z.COM`; without it the kit stays `vax-kit/OPP-KIT.COM`.
6. **`make dist`, `make distcheck` and `make dist-sign`**, in
   `GNUmakefile`, writing into `dist/` (ignored by git):
   - `dist` refuses a working tree that differs from `HEAD`, and a `HEAD`
     whose `version` already has a tag on another commit. It writes
     `opp-x.y.z.tar.gz` with `git archive --prefix=opp-x.y.z/ HEAD` (so
     only what git tracks, and nothing built), its `.sha256`, and the kit,
     `OPP-x-y-z.COM`, through `make -f vaxGNUmakefile` and
     `tools/make-vax-kit -o`.
   - `distcheck` runs `dist`, then unpacks the tarball in a fresh
     temporary directory and there runs `make test` and `make -f
     pocGNUmakefile test-poc`, with `VOC_OBERON_MODULES` and the poc
     library as installed, so that a tarball missing a file fails. `make
     corpus` is not run there: it needs the other repositories.
   - `dist-sign` writes `opp-x.y.z.tar.gz.asc` with gpg's default key
     (`GPG_KEY=` for another).
   - `make clean` removes `dist/`.
7. **The process written down**: a "Making a release" section in this
   file, replacing the plan, and a line in AGENTS.md pointing to it.
8. **Release 0.1.0**, by the steps below.

Each piece ends as every change does: `make test`, `make -f
pocGNUmakefile test-poc` and `make corpus` passing, and for 5 and 6
`make -f vaxGNUmakefile check-kit` as well.

## Making a release

Once the pieces are built, a release `x.y.z` is made in these steps, on
`main`:

1. **The version.** `make set-version VERSION=x.y.z`, then write the
   notes in `NEWS.md` under its new heading: what changed since the last
   release (`git log v<last>..`), for a user, with every change of the
   default output said plainly.
2. **Check**, all of it:

       make test
       make -f pocGNUmakefile test-poc
       make corpus
       make -f vaxGNUmakefile test-vax
       make -f vaxGNUmakefile check-kit

   The last two need the VAX/VMS guest (`VAX_HOST`, `VAX_NETRC`) and
   poc's source (`POC_SRC`). Compare the long-line counts `make corpus`
   prints with the last release's: `corpus: ok` alone does not show a
   line that has grown too long.
3. **Commit** ("opp x.y.z"), and **push** `main`. If opp now needs
   something of ArgParser's that is in no ArgParser release, release
   ArgParser first (its AGENTS.md, "Making a release"), and say in
   `NEWS.md` which version opp needs.
4. **The tarball and the kit**, from that commit:

       make distcheck
       make dist-sign

   Run `make dist` once, through `distcheck`, and sign and publish what it
   wrote: each run writes a new tarball (tar and gzip record times), whose
   sum differs.
5. **Tag** the commit, signed, and push the tag:

       git tag -s vx.y.z -m "opp x.y.z"
       git tag -v vx.y.z
       git push origin vx.y.z

   gpg asks for the key's passphrase for the tag and for `dist-sign`.
   Over ssh its graphical pinentry appears on the machine's own screen;
   in a terminal, set `GPG_TTY=$(tty)` and use `--pinentry-mode loopback`,
   as poc's DEVELOPER.md says.
6. **Publish**:

       gh release create vx.y.z dist/opp-x.y.z.tar.gz{,.sha256,.asc} \
         dist/OPP-x-y-z.COM --title "opp x.y.z" --notes-file <notes>

   The notes are `NEWS.md`'s section for `x.y.z`, then how to install:
   from the tarball, ArgParser first (the ArgParser release it needs,
   0.1.0 or later, linked; `make install` there for voc, `make -f
   pocGNUmakefile install` for poc), then `make`
   and `make install`, or the poc build; on VAX/VMS, the kit copied in
   ASCII mode, `@OPP-x-y-z` in an empty directory, `@BUILD`, `@SETUP`.
7. **Record** the release: its date and what it held, in `PLAN.md` (as
   poc's AGENTS.md records each of its releases), and check the release
   page's files download and the tarball's sum matches.

A patch release from an older minor is not planned for: while opp is
0.x, the next release comes from `main`.

## Decisions to make

The plan assumes these; each is the user's to change.

- **The first version is 0.1.0**: opp is young, and 0.x leaves room to
  change its default output in a minor release.
- **ArgParser is not bundled** in the tarball: it is a shared module, kept
  in its own repository (AGENTS.md), with releases of its own (settled
  2026-10-18, with ArgParser 0.1.0). opp's release notes name the
  oldest ArgParser release opp builds with, now 0.1.0. The VMS kit
  carries its own copy of `ArgParser.Mod`, compiled in, as before.
- **Releases are signed**: the tag and the tarball, with the user's gpg
  key, as poc's are.
- **`--version`, not `-V`**: opp's short options are few, and `-V` is
  taken to mean verbose by some tools.
- **No packages yet** (RPM, FreeBSD and OpenBSD ports, pkgsrc): poc has
  them because it is installed system-wide by others; opp can follow when
  someone needs it. `make install`'s `BINDIR` and `MANDIR` are enough for
  a package to use later.

## Left out

- Packages for any system (above).
- A project web site beyond the GitHub release page.
- Release automation in CI: the checks need the VAX guest and the
  corpus's repositories, which only the user's machines have.
- A DCL verb for VMS (VAX-VMS-PORT.md, "Decisions").
