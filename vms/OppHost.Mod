MODULE OppHost;

(* What opp's command line needs of the host system, for VAX/VMS: the
   interface of ../OppHost.Mod, which is Unix's, built by poc for
   vax-dec-vms only (vaxGNUmakefile, VAX-VMS-PORT.md). Directories is
   poc's, over RMS, which voc does not have.

   On VMS, DCL makes what is not quoted capitals, so an option is
   lowercased; DCL does not expand wildcards, so opp does, with
   LIB$FIND_FILE; a file's name follows its device and directory, its
   last ":", "]" or ">", and may end in a version, ";n"; --in-place writes
   a new version of a file, which leaves the old one as it was; and the
   user's config file is the one the logical name OPP$CONFIG names, or
   else SYS$LOGIN:OPP.CONF. *)

IMPORT Platform, Directories, OppText;

CONST
  (* whether --in-place writes the formatted text as a new version of the
     file, rather than over the file itself *)
  newVersions* = TRUE;
  (* the config file of the current directory *)
  directoryConfig* = "OPP.CONF";
  (* --config's help *)
  configHelp* = "Read options from this file, instead of from OPP$CONFIG, or else SYS$LOGIN:OPP.CONF, and OPP.CONF.";

  nameLength = 256; (* the longest name RMS takes, and its 0X *)

TYPE
  (* a procedure that takes a file's name from the command line *)
  AddProc* = PROCEDURE (name: OppText.Text);

(* An argument as opp reads it: an option, which starts with "-", in
   lowercase, as DCL has made it capitals unless it was quoted; anything
   else as it is. *)
PROCEDURE FoldOption*(VAR arg: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  IF arg[0] = "-" THEN
    i := 0;
    WHILE (i < LEN(arg)) & (arg[i] # 0X) DO
      IF (arg[i] >= "A") & (arg[i] <= "Z") THEN
        arg[i] := CHR(ORD(arg[i]) - ORD("A") + ORD("a"))
      END;
      INC(i)
    END
  END
END FoldOption;

(* Whether arg has a wildcard: "*" or "%" in a name, or "..." in a
   directory. *)
PROCEDURE HasWildcard(VAR arg: ARRAY OF CHAR): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(arg)) & (arg[i] # 0X) DO
    IF (arg[i] = "*") OR (arg[i] = "%") THEN RETURN TRUE END;
    IF (arg[i] = ".") & (i + 2 < LEN(arg)) & (arg[i + 1] = ".")
        & (arg[i + 2] = ".") THEN
      RETURN TRUE
    END;
    INC(i)
  END;
  RETURN FALSE
END HasWildcard;

(* The files a file argument names, each given to add; whether there are
   any. A name without a wildcard is the one file, as it was given, so
   that a file that is not there is reported when opp opens it; a pattern
   gives each file it finds (Directories.NextFile), its whole
   specification without its version. *)
PROCEDURE Expand*(VAR arg: ARRAY OF CHAR; add: AddProc): BOOLEAN;
  VAR
    search: Directories.Search; name: ARRAY nameLength OF CHAR;
    found: BOOLEAN;
BEGIN
  IF ~HasWildcard(arg) THEN add(OppText.New(arg)); RETURN TRUE END;
  found := FALSE;
  Directories.StartSearch(search);
  WHILE Directories.NextFile(search, arg, name) DO
    add(OppText.New(name)); found := TRUE
  END;
  RETURN found
END Expand;

(* Where the version of the file name name starts, its ";", after its
   device and directory; the length of name if it has none. *)
PROCEDURE VersionStart(name: OppText.Text): LONGINT;
  VAR i: LONGINT;
BEGIN
  i := Directories.NameStart(name^);
  WHILE (name[i] # 0X) & (name[i] # ";") DO INC(i) END;
  RETURN i
END VersionStart;

(* The last part of the file name name, in capitals, as ODS-2 keeps it:
   what follows its device and directory, without its version. *)
PROCEDURE BaseName*(name: OppText.Text): OppText.Text;
  VAR start, i: LONGINT; t: OppText.Text;
BEGIN
  start := Directories.NameStart(name^);
  t := OppText.Slice(name^, start, VersionStart(name) - start);
  i := 0;
  WHILE t[i] # 0X DO
    IF (t[i] >= "a") & (t[i] <= "z") THEN
      t[i] := CHR(ORD(t[i]) - ORD("a") + ORD("A"))
    END;
    INC(i)
  END;
  RETURN t
END BaseName;

(* name without its version. *)
PROCEDURE WithoutVersion*(name: OppText.Text): OppText.Text;
BEGIN
  RETURN OppText.Slice(name^, 0, VersionStart(name))
END WithoutVersion;

(* The file name in the directory dir: dir and name joined
   (Directories.MakePath), [.OUT] and FOO.MOD giving [.OUT]FOO.MOD. *)
PROCEDURE InDirectory*(dir, name: OppText.Text): OppText.Text;
  VAR path: ARRAY nameLength OF CHAR;
BEGIN
  Directories.MakePath(dir^, name^, path);
  RETURN OppText.New(path)
END InDirectory;

(* Whether there is a directory dir. *)
PROCEDURE IsDirectory*(dir: OppText.Text): BOOLEAN;
BEGIN
  RETURN Directories.IsDirectory(dir^)
END IsDirectory;

(* The user's config file: the one the logical name OPP$CONFIG names, or
   else OPP.CONF in the login directory. *)
PROCEDURE UserConfig*(): OppText.Text;
  VAR name: ARRAY nameLength OF CHAR;
BEGIN
  IF Platform.getEnv("OPP$CONFIG", name) & (name # "") THEN
    RETURN OppText.New(name)
  END;
  RETURN OppText.New("SYS$LOGIN:OPP.CONF")
END UserConfig;

END OppHost.
