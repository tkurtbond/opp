MODULE Opp;

(* opp, the Oberon pretty printer: the command line.

   opp [options] [file ...] formats Oberon-2 modules written for poc or voc
   (PLAN.md, "Command line"). This is Phase 0's skeleton: it takes every
   option and its file names, but does not format yet. *)

IMPORT ArgParser, Err, Out, Platform, OppText;

CONST
  (* statement modes *)
  onePerLine = 0; pack = 1; keepLines = 2;

  (* exit statuses (AGENTS.md, "Exit statuses") *)
  failureStatus = 1;

TYPE
  FileName = POINTER TO FileNameDesc;
  FileNameDesc = RECORD
    name: OppText.Text;
    next: FileName
  END;

VAR
  parser: ArgParser.Parser;
  width, indent: LONGINT;
  mode: INTEGER;
  moduleIndent, inPlace, check: BOOLEAN;
  files, lastFile: FileName;

PROCEDURE SetWidth(val: LONGINT): BOOLEAN;
BEGIN
  width := val; RETURN TRUE
END SetWidth;

PROCEDURE SetIndent(val: LONGINT): BOOLEAN;
BEGIN
  indent := val; RETURN TRUE
END SetIndent;

PROCEDURE SetOnePerLine(): BOOLEAN;
BEGIN
  mode := onePerLine; RETURN TRUE
END SetOnePerLine;

PROCEDURE SetPack(): BOOLEAN;
BEGIN
  mode := pack; RETURN TRUE
END SetPack;

PROCEDURE SetKeepLines(): BOOLEAN;
BEGIN
  mode := keepLines; RETURN TRUE
END SetKeepLines;

PROCEDURE SetNoModuleIndent(): BOOLEAN;
BEGIN
  moduleIndent := FALSE; RETURN TRUE
END SetNoModuleIndent;

PROCEDURE SetInPlace(): BOOLEAN;
BEGIN
  inPlace := TRUE; RETURN TRUE
END SetInPlace;

PROCEDURE SetCheck(): BOOLEAN;
BEGIN
  check := TRUE; RETURN TRUE
END SetCheck;

PROCEDURE Help(): BOOLEAN;
BEGIN
  parser.Usage; Out.Flush;
  Platform.Exit(0);
  RETURN FALSE
END Help;

(* A file name, or "-" for standard input, kept in order. *)
PROCEDURE AddFile(startIdx: INTEGER; VAR arg: ARRAY OF CHAR): BOOLEAN;
VAR f: FileName;
BEGIN
  NEW(f); f.name := OppText.New(arg); f.next := NIL;
  IF lastFile = NIL THEN files := f ELSE lastFile.next := f END;
  lastFile := f;
  RETURN TRUE
END AddFile;

PROCEDURE Fail(msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Err.String("opp: "); Err.String(msg); Err.Ln;
  Platform.Exit(failureStatus)
END Fail;

BEGIN
  width := 80; indent := 2; mode := onePerLine;
  moduleIndent := TRUE; inPlace := FALSE; check := FALSE;
  files := NIL; lastFile := NIL;

  parser := ArgParser.NewParser(
    "opp [options] [file ...]: format Oberon-2 modules for poc or voc; with no file, or -, standard input",
    AddFile);
  parser.AddOption(ArgParser.MakeIntOption("w", "width",
    "The maximum line length (20 to 1000; default 80).", SetWidth, 20, 1000));
  parser.AddOption(ArgParser.MakeIntOption("i", "indent",
    "Columns per indentation level (1 to 16; default 2).", SetIndent, 1, 16));
  parser.AddOption(ArgParser.MakeOption("1", "one-per-line",
    "Put every statement on its own line (the default).", SetOnePerLine));
  parser.AddOption(ArgParser.MakeOption("p", "pack",
    "Pack short statements and declarations onto shared lines.", SetPack));
  parser.AddOption(ArgParser.MakeOption("k", "keep-lines",
    "Keep statements and declarations on shared lines where the source has them, while they fit.",
    SetKeepLines));
  parser.AddOption(ArgParser.MakeOption(0X, "no-module-indent",
    "Start a module's declarations and statements at column 1.", SetNoModuleIndent));
  parser.AddOption(ArgParser.MakeOption(0X, "in-place",
    "Replace each file with its formatted text.", SetInPlace));
  parser.AddOption(ArgParser.MakeOption("c", "check",
    "Write nothing; exit 1 and name each file that would change.", SetCheck));
  parser.AddOption(ArgParser.MakeOption("h", "help",
    "Show this help and exit.", Help));
  parser.ParseArguments(1);

  Fail("formatting is not implemented yet (PLAN.md, Phase 3)")
END Opp.
