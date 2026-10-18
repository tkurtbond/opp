opp, the Oberon pretty printer, for VAX/VMS 5.5-2
@VERSION@

opp reformats Oberon-2 modules written for poc (the Peaseblossom Oberon
Compiler) or voc (Vishap Oberon), to a maximum line length. Before it
writes anything for a file, it checks that the formatted text has
exactly the file's tokens and comments.

This directory is the kit @KIT@.COM unpacked:

  README.TXT    this file
  BUILD.COM     builds [.BIN]OPP.EXE and the help library OPP.HLB
  SETUP.COM     defines the command OPP, and HELP OPP
  OPP.HLP       the help library's text
  OPP.TXT       opp's manual, as text
  LICENSE.TXT   opp's license, BSD 3-Clause
  VERSION.TXT   which opp this is, and the poc that compiled it
  [.KIT]        opp's MACRO-32, with poc's runtime's, and OPP.COM, which
                BUILD.COM runs to assemble and link it
  [.SRC]        opp's Oberon-2 source, for building it again with poc
  [.BIN]        where BUILD.COM puts OPP.EXE

To install it:

  1. Copy @KIT@.COM to VMS in ASCII mode (with FTP, "ascii" before
     "put"), make an empty directory for opp, and unpack the kit there:

       $ CREATE/DIRECTORY [.OPP]
       $ SET DEFAULT [.OPP]
       $ @[-]@KIT@

  2. Build opp. This needs MACRO, LINK and LIBRARY alone, not poc:

       $ @BUILD

  3. In each process that uses opp, once a session or from LOGIN.COM:

       $ @dev:[dir.OPP]SETUP

     which defines the command OPP and makes HELP OPP work.

Then, for example:

  $ OPP --IN-PLACE -P *.MOD
  $ HELP OPP

OPP.EXE is linked with all it needs, so once it is built it runs without
the kit's other files; SETUP.COM shows how to define the command for it.
DCL turns what is not quoted into capitals, and opp lowercases its
options, so they may be typed in either case. --in-place writes a new
version of each file and leaves the old one as the backup. The user's
config file is the one the logical name OPP$CONFIG names, or else
SYS$LOGIN:OPP.CONF, and the current directory's is OPP.CONF. HELP OPP,
and the VAX/VMS section of OPP.TXT, say more.

To build opp from [.SRC] with poc on VMS instead, with poc's kit of the
version VERSION.TXT names installed and set up:

  $ SET DEFAULT [.SRC]
  $ POC OPP.MOD
  $ @OPP
