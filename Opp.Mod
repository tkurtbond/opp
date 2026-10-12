MODULE Opp;

(* opp, the Oberon pretty printer: the command line.

   opp [options] [file ...] formats Oberon-2 modules written for poc or voc
   (PLAN.md, "Command line"), writing each to standard output; --tokens,
   a debugging aid, lists each file's tokens and comments as OppScanner sees
   them instead. --in-place and --check, and the check that the output has
   the input's tokens and comments, are Phase 4's. *)

IMPORT ArgParser, Err, Files, In, Out, Platform, OppText, OppScanner, OppFormat;

CONST
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
  opts: OppFormat.Options;
  inPlace, check, tokens: BOOLEAN;
  status: INTEGER;   (* the exit status so far *)
  files, lastFile: FileName;
  input: OppText.Buffer;
  stdin: ARRAY 2 OF CHAR;

PROCEDURE SetWidth(val: LONGINT): BOOLEAN;
BEGIN
  opts.width := val; RETURN TRUE
END SetWidth;

PROCEDURE SetIndent(val: LONGINT): BOOLEAN;
BEGIN
  opts.indent := val; RETURN TRUE
END SetIndent;

PROCEDURE SetOnePerLine(): BOOLEAN;
BEGIN
  opts.mode := OppFormat.onePerLine; RETURN TRUE
END SetOnePerLine;

PROCEDURE SetPack(): BOOLEAN;
BEGIN
  opts.mode := OppFormat.pack; RETURN TRUE
END SetPack;

PROCEDURE SetKeepLines(): BOOLEAN;
BEGIN
  opts.mode := OppFormat.keepLines; RETURN TRUE
END SetKeepLines;

PROCEDURE SetNoModuleIndent(): BOOLEAN;
BEGIN
  opts.moduleIndent := FALSE; RETURN TRUE
END SetNoModuleIndent;

PROCEDURE SetInPlace(): BOOLEAN;
BEGIN
  inPlace := TRUE; RETURN TRUE
END SetInPlace;

PROCEDURE SetCheck(): BOOLEAN;
BEGIN
  check := TRUE; RETURN TRUE
END SetCheck;

PROCEDURE SetTokens(): BOOLEAN;
BEGIN
  tokens := TRUE; RETURN TRUE
END SetTokens;

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

(* The name of a file in messages: "(stdin)" for standard input. *)
PROCEDURE DisplayName(name: OppText.Text): OppText.Text;
BEGIN
  IF name^ = "-" THEN RETURN OppText.New("(stdin)") ELSE RETURN name END
END DisplayName;

(* n, not negative, in decimal on standard error: the shared Err that voc
   builds with has only Char, String and Ln. *)
PROCEDURE ErrNumber(n: LONGINT);
BEGIN
  IF n >= 10 THEN ErrNumber(n DIV 10) END;
  Err.Char(CHR(ORD("0") + n MOD 10))
END ErrNumber;

(* "name:line:column: message" on standard error; the exit status becomes 1. *)
PROCEDURE ReportError(name: OppText.Text; line, column: LONGINT; msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Err.String(name^); Err.Char(":"); ErrNumber(line); Err.Char(":");
  ErrNumber(column); Err.String(": "); Err.String(msg); Err.Ln;
  status := failureStatus
END ReportError;

(* The whole of the file name, or of standard input for "-", in text. *)
PROCEDURE ReadInput(name: OppText.Text; VAR text: OppText.Buffer): BOOLEAN;
VAR f: Files.File; r: Files.Rider; ch: CHAR; n, i: LONGINT;
BEGIN
  text := OppText.NewBuffer();
  IF name^ = "-" THEN
    In.Char(ch);
    WHILE In.Done DO OppText.AppendChar(text, ch); In.Char(ch) END
  ELSE
    f := Files.Old(name^);
    IF f = NIL THEN
      Out.Flush;
      Err.String("opp: cannot open "); Err.String(name^); Err.Ln;
      status := failureStatus;
      RETURN FALSE
    END;
    n := Files.Length(f); Files.Set(r, f, 0);
    FOR i := 1 TO n DO Files.Read(r, ch); OppText.AppendChar(text, ch) END;
    Files.Close(f)
  END;
  RETURN TRUE
END ReadInput;

(* t on standard output, with a line break, a tab and a backslash written
   as \n, \t and \\, and any other control character as \x and two
   hexadecimal digits, so each token or comment takes one printable line. *)
PROCEDURE WriteEscaped(t: OppText.Text);
VAR i: LONGINT; digits: ARRAY 17 OF CHAR;
BEGIN
  digits := "0123456789ABCDEF";
  i := 0;
  WHILE t[i] # 0X DO
    IF t[i] = 0AX THEN Out.String("\n")
    ELSIF t[i] = 9X THEN Out.String("\t")
    ELSIF t[i] = "\" THEN Out.String("\\")
    ELSIF (t[i] < " ") OR (t[i] = 7FX) THEN
      Out.String("\x"); Out.Char(digits[ORD(t[i]) DIV 16]); Out.Char(digits[ORD(t[i]) MOD 16])
    ELSE Out.Char(t[i])
    END;
    INC(i)
  END
END WriteEscaped;

PROCEDURE WritePosition(line, column: LONGINT);
BEGIN
  Out.Int(line, 0); Out.Char(":"); Out.Int(column, 0)
END WritePosition;

PROCEDURE WriteComments(label: ARRAY OF CHAR; c: OppScanner.Comment);
BEGIN
  WHILE c # NIL DO
    Out.String("  "); Out.String(label); Out.Char(" "); WritePosition(c.line, c.column);
    IF c.blankBefore THEN Out.String(" blank") END;
    IF c.newlineAfter THEN Out.String(" newline") END;
    IF c.multiLine THEN Out.String(" multiline") END;
    Out.Char(" "); WriteEscaped(c.text); Out.Ln;
    c := c.next
  END
END WriteComments;

(* --tokens: every token of text, one to a line, as "line:column kind
   text", "blank" when a blank line comes before it, and its comments on
   the lines after it, "lead" before and "trail" after. A token's trailing
   comments are complete only once the next token is scanned, so each
   token is written when the next one has been. *)
PROCEDURE ListTokens(name: OppText.Text; text: OppText.Buffer);
VAR s: OppScanner.Scanner; t, next: OppScanner.Token; kind: ARRAY 32 OF CHAR;
BEGIN
  s := OppScanner.New(text.chars, text.len);
  t := OppScanner.Next(s);
  REPEAT
    IF t.kind # OppScanner.eof THEN next := OppScanner.Next(s) ELSE next := NIL END;
    WriteComments("lead", t.lead);
    WritePosition(t.line, t.column); Out.Char(" ");
    IF (t.kind >= OppScanner.firstKeyword) & (t.kind <= OppScanner.lastKeyword) THEN
      Out.String("keyword")
    ELSIF t.kind >= OppScanner.plus THEN
      Out.String("symbol")
    ELSE
      OppScanner.KindName(t.kind, kind); Out.String(kind)
    END;
    IF t.kind # OppScanner.eof THEN Out.Char(" "); WriteEscaped(t.text) END;
    IF t.blankBefore THEN Out.String(" blank") END;
    Out.Ln;
    WriteComments("trail", t.trail);
    t := next
  UNTIL t = NIL;
  IF s.error THEN ReportError(name, s.errorLine, s.errorColumn, s.errorMessage) END
END ListTokens;

(* The formatted text of a file on standard output, or its error. *)
PROCEDURE FormatFile(name: OppText.Text; text: OppText.Buffer);
VAR out: OppText.Buffer; line, column, i: LONGINT; msg: ARRAY 120 OF CHAR;
BEGIN
  IF OppFormat.Format(text.chars, text.len, opts, out, line, column, msg) THEN
    FOR i := 0 TO out.len - 1 DO Out.Char(out.chars[i]) END
  ELSE
    ReportError(name, line, column, msg)
  END
END FormatFile;

BEGIN
  opts.width := 80; opts.indent := 2; opts.mode := OppFormat.onePerLine;
  opts.moduleIndent := TRUE; inPlace := FALSE; check := FALSE; tokens := FALSE;
  status := 0;
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
    "Start a module's declarations at column 1; its statements stay indented.", SetNoModuleIndent));
  parser.AddOption(ArgParser.MakeOption(0X, "in-place",
    "Replace each file with its formatted text.", SetInPlace));
  parser.AddOption(ArgParser.MakeOption("c", "check",
    "Write nothing; exit 1 and name each file that would change.", SetCheck));
  parser.AddOption(ArgParser.MakeOption(0X, "tokens",
    "List each file's tokens and comments instead of formatting it (a debugging aid).",
    SetTokens));
  parser.AddOption(ArgParser.MakeOption("h", "help",
    "Show this help and exit.", Help));
  parser.ParseArguments(1);

  IF files = NIL THEN
    stdin := "-";
    IF AddFile(0, stdin) THEN END
  END;
  IF inPlace OR check THEN Fail("--in-place and --check are not implemented yet (PLAN.md, Phase 4)") END;
  WHILE files # NIL DO
    IF ReadInput(files.name, input) THEN
      IF tokens THEN ListTokens(DisplayName(files.name), input)
      ELSE FormatFile(DisplayName(files.name), input)
      END
    END;
    files := files.next
  END;
  Out.Flush;
  Platform.Exit(status)
END Opp.
