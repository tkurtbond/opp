MODULE OppHost;

(* What opp's command line needs of the host system, for Unix: the voc
   build and poc's LLVM build. VAX-VMS-PORT.md plans a module of the same
   interface for VAX/VMS, vms/OppHost.Mod, which the VAX build uses
   instead: so Opp.Mod is the same for every build, and asks this module
   how the host names files, finds config files and replaces a file.

   On Unix the shell expands wildcards and keeps an argument's case, a
   file name's last part follows its last slash, and the user's config
   file is $XDG_CONFIG_HOME/opp/opp.conf, or ~/.config/opp/opp.conf. *)

IMPORT Platform, OppText;

CONST
  (* whether --in-place writes the formatted text as a new version of the
     file, as VMS does, rather than over the file itself *)
  newVersions* = FALSE;
  (* the config file of the current directory *)
  directoryConfig* = ".opp.conf";
  (* --config's help *)
  configHelp* = "Read options from this file, instead of from ~/.config/opp/opp.conf and ./.opp.conf.";

TYPE
  (* a procedure that takes a file's name from the command line *)
  AddProc* = PROCEDURE (name: OppText.Text);

(* An argument as opp reads it: arg as it is. *)
PROCEDURE FoldOption*(VAR arg: ARRAY OF CHAR);
END FoldOption;

(* The files a file argument names, each given to add; whether there are
   any. On Unix the shell has expanded it already, so it is one file. *)
PROCEDURE Expand*(VAR arg: ARRAY OF CHAR; add: AddProc): BOOLEAN;
BEGIN
  add(OppText.New(arg)); RETURN TRUE
END Expand;

(* The last part of the file name name: what follows its last slash. *)
PROCEDURE BaseName*(name: OppText.Text): OppText.Text;
  VAR i, start: LONGINT;
BEGIN
  i := 0; start := 0;
  WHILE name[i] # 0X DO
    IF name[i] = "/" THEN start := i + 1 END;
    INC(i)
  END;
  RETURN OppText.Slice(name^, start, i - start)
END BaseName;

(* name without a version: on Unix, name. *)
PROCEDURE WithoutVersion*(name: OppText.Text): OppText.Text;
BEGIN
  RETURN name
END WithoutVersion;

(* The file name in the directory dir: dir, a slash unless dir ends in one,
   and name. *)
PROCEDURE InDirectory*(dir, name: OppText.Text): OppText.Text;
  VAR b: OppText.Buffer;
BEGIN
  b := OppText.NewBuffer(); OppText.AppendText(b, dir);
  IF (b.len > 0) & (b.chars[b.len - 1] # "/") THEN
    OppText.AppendChar(b, "/")
  END;
  OppText.AppendText(b, name);
  RETURN OppText.Slice(b.chars^, 0, b.len)
END InDirectory;

(* Whether there is a directory dir. *)
PROCEDURE IsDirectory*(dir: OppText.Text): BOOLEAN;
  VAR id: Platform.FileIdentity;
BEGIN
  RETURN Platform.IdentifyByName(dir^, id) = 0
END IsDirectory;

(* The user's config file: opp/opp.conf in $XDG_CONFIG_HOME, or else in
   ~/.config; NIL if neither variable is set. *)
PROCEDURE UserConfig*(): OppText.Text;
  VAR dir: ARRAY 4096 OF CHAR; b: OppText.Buffer;
BEGIN
  b := OppText.NewBuffer();
  IF Platform.getEnv("XDG_CONFIG_HOME", dir) & (dir # "") THEN
    OppText.Append(b, dir)
  ELSIF Platform.getEnv("HOME", dir) & (dir # "") THEN
    OppText.Append(b, dir); OppText.Append(b, "/.config")
  ELSE
    RETURN NIL
  END;
  OppText.Append(b, "/opp/opp.conf");
  RETURN OppText.Slice(b.chars^, 0, b.len)
END UserConfig;

END OppHost.
