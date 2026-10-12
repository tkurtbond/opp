MODULE Opp;

(* opp, the Oberon pretty printer: the command line.

   opp [options] [file ...] formats Oberon-2 modules written for poc or voc
   (PLAN.md, "Command line"), writing each to standard output, or with
   --in-place back to its file, or with --check only naming the files that
   would change. --tokens, a debugging aid, lists each file's tokens and
   comments as OppScanner sees them instead.

   Nothing is written for a file until its formatted text passes the safety
   check: OppCheck finds the input's tokens and comments in it, and it
   parses again. A failure is an internal error, exit status 3. --damage,
   for opp's own tests, spoils the formatted text first, to show that the
   check catches it. *)

IMPORT SYSTEM, ArgParser, Err, In, Out, Platform, OppText, OppScanner,
    OppFormat, OppCheck;

CONST
  (* exit statuses (AGENTS.md, "Exit statuses") *)
  failureStatus = 1; internalStatus = 3;
  (* --damage: what to spoil *)
  noDamage = 0; damageToken = 1; damageComment = 2; damageRest = 3;

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
  damage: LONGINT;
  caseBarOK, alignOK: BOOLEAN; (* --case-bar's and --align's values were
                                   ones they take *)
  status: INTEGER; (* the exit status so far *)
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

PROCEDURE SetCaseBar(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF val = "keep" THEN opts.caseBar := OppFormat.keepBar
  ELSIF val = "add" THEN opts.caseBar := OppFormat.addBar
  ELSIF val = "drop" THEN opts.caseBar := OppFormat.dropBar
  ELSE caseBarOK := FALSE
  END;
  RETURN TRUE
END SetCaseBar;

PROCEDURE SetAlign(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF val = "keep" THEN opts.align := OppFormat.keepAlign
  ELSIF val = "drop" THEN opts.align := OppFormat.dropAlign
  ELSE alignOK := FALSE
  END;
  RETURN TRUE
END SetAlign;

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

PROCEDURE SetDamage(val: LONGINT): BOOLEAN;
BEGIN
  damage := val; RETURN TRUE
END SetDamage;

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

(* A command line mistake: msg, and exit status 2. *)
PROCEDURE UsageError(msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Err.String("opp: "); Err.String(msg); Err.Ln;
  Platform.Exit(ArgParser.UsageErrorStatus)
END UsageError;

(* The exit status becomes s, unless it is already worse. *)
PROCEDURE SetStatus(s: INTEGER);
BEGIN
  IF s > status THEN status := s END
END SetStatus;

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
PROCEDURE ReportError(name: OppText.Text; line, column: LONGINT;
                      msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Err.String(name^); Err.Char(":"); ErrNumber(line); Err.Char(":");
  ErrNumber(column); Err.String(": "); Err.String(msg); Err.Ln;
  SetStatus(failureStatus)
END ReportError;

(* An internal error: the formatted text of name failed the safety check,
   at line and column of it; the exit status becomes 3. *)
PROCEDURE ReportInternal(name: OppText.Text; line, column: LONGINT;
                         msg: ARRAY OF CHAR);
BEGIN
  Out.Flush;
  Err.String("opp: internal error: "); Err.String(name^);
  Err.String(": the formatted text, at ");
  ErrNumber(line); Err.Char(":"); ErrNumber(column); Err.String(": ");
  Err.String(msg); Err.String("; nothing written"); Err.Ln;
  SetStatus(internalStatus)
END ReportInternal;

(* The whole of the file name, or of standard input for "-", in text. A
   file is read with Platform, not Files: voc's Files keeps a file it has
   opened in a list, and when --in-place registers the new text under its
   name, renames the old one to a temporary file that is deleted only when
   the collector finalizes it, which may be never. *)
PROCEDURE ReadInput(name: OppText.Text; VAR text: OppText.Buffer): BOOLEAN;
  VAR
    h: Platform.FileHandle; ch: CHAR; n, i: LONGINT; chunk: ARRAY 8192 OF CHAR;
BEGIN
  text := OppText.NewBuffer();
  IF name^ = "-" THEN
    In.Char(ch);
    WHILE In.Done DO OppText.AppendChar(text, ch); In.Char(ch) END
  ELSE
    IF Platform.OldRO(name^, h) # 0 THEN
      Out.Flush;
      Err.String("opp: cannot open "); Err.String(name^); Err.Ln;
      SetStatus(failureStatus);
      RETURN FALSE
    END;
    LOOP
      IF Platform.ReadBuf(h, chunk, n) # 0 THEN
        Out.Flush;
        Err.String("opp: cannot read "); Err.String(name^); Err.Ln;
        SetStatus(failureStatus);
        IF Platform.Close(h) # 0 THEN END;
        RETURN FALSE
      END;
      IF n = 0 THEN EXIT END;
      FOR i := 0 TO n - 1 DO OppText.AppendChar(text, chunk[i]) END
    END;
    IF Platform.Close(h) # 0 THEN END
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
      Out.String("\x"); Out.Char(digits[ORD(t[i]) DIV 16]);
      Out.Char(digits[ORD(t[i]) MOD 16])
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
    Out.String("  "); Out.String(label); Out.Char(" ");
    WritePosition(c.line, c.column);
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
    IF t.kind # OppScanner.eof THEN
      next := OppScanner.Next(s)
    ELSE
      next := NIL
    END;
    WriteComments("lead", t.lead);
    WritePosition(t.line, t.column); Out.Char(" ");
    IF (t.kind >= OppScanner.firstKeyword)
        & (t.kind <= OppScanner.lastKeyword) THEN
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
  IF s.error THEN
    ReportError(name, s.errorLine, s.errorColumn, s.errorMessage)
  END
END ListTokens;

(* The position of the first occurrence of s in b at or after from, or -1. *)
PROCEDURE Find(b: OppText.Buffer; s: ARRAY OF CHAR; from: LONGINT): LONGINT;
  VAR i, j: LONGINT;
BEGIN
  i := from;
  WHILE i < b.len DO
    j := 0;
    WHILE (s[j] # 0X) & (i + j < b.len) & (b.chars[i + j] = s[j]) DO INC(j) END;
    IF s[j] = 0X THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END Find;

(* --damage: out spoiled as damage says: the first letter of the module's
   name changed, the first letter of the first comment that starts with a
   space changed, or text added after the module's end. *)
PROCEDURE Damage(out: OppText.Buffer);
  VAR i: LONGINT;
BEGIN
  IF damage = damageToken THEN
    i := Find(out, "MODULE ", 0);
    IF i >= 0 THEN
      INC(i, 7);
      IF out.chars[i] = "X" THEN out.chars[i] := "Y"
      ELSE out.chars[i] := "X"
      END
    END
  ELSIF damage = damageComment THEN
    i := Find(out, "(* ", 0);
    IF i >= 0 THEN
      INC(i, 3);
      IF out.chars[i] = "X" THEN out.chars[i] := "Y"
      ELSE out.chars[i] := "X"
      END
    END
  ELSIF damage = damageRest THEN
    OppText.AppendChar(out, "X")
  END
END Damage;

(* Whether a and b hold the same text. *)
PROCEDURE SameText(a, b: OppText.Buffer): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  IF a.len # b.len THEN RETURN FALSE END;
  i := 0;
  WHILE (i < a.len) & (a.chars[i] = b.chars[i]) DO INC(i) END;
  RETURN i = a.len
END SameText;

(* Whether the file name now holds text exactly: it is emptied and written
   through h, opened for writing, which is closed. The size is checked, as
   voc's Platform.Write does not report writing less than it was asked. *)
PROCEDURE WriteAll(VAR name: ARRAY OF CHAR; h: Platform.FileHandle;
                   text: OppText.Buffer): BOOLEAN;
  VAR ok: BOOLEAN; size: LONGINT;
BEGIN
  ok := (Platform.Truncate(h, 0) = 0)
      & (Platform.Write(h, SYSTEM.ADR(text.chars[0]), text.len) = 0)
      & (Platform.Size(h, size) = 0) & (size = text.len);
  RETURN (Platform.Close(h) = 0) & ok
END WriteAll;

(* out as the new content of the file name, written over it so that it
   keeps its permissions, owner and links. Once the file is open, its old
   content is copied to name.opp-backup, which is deleted when the file is
   written, and which a failure leaves for the user to restore. *)
PROCEDURE WriteFile(name: OppText.Text; old, out: OppText.Buffer);
  VAR backup: OppText.Buffer; h, hb: Platform.FileHandle;
BEGIN
  backup := OppText.NewBuffer();
  OppText.AppendText(backup, name); OppText.Append(backup, ".opp-backup");
  Out.Flush;
  IF Platform.OldRW(name^, h) # 0 THEN
    Err.String("opp: cannot write "); Err.String(name^); Err.Ln;
    SetStatus(failureStatus)
  ELSIF (Platform.New(backup.chars^, hb) # 0)
      OR ~WriteAll(backup.chars^, hb, old) THEN
    IF Platform.Close(h) # 0 THEN END;
    Err.String("opp: cannot write "); Err.String(backup.chars^);
    Err.String(", so "); Err.String(name^); Err.String(" is left as it was");
    Err.Ln;
    SetStatus(failureStatus)
  ELSIF ~WriteAll(name^, h, out) THEN
    Err.String("opp: cannot write "); Err.String(name^);
    Err.String("; its old text is in "); Err.String(backup.chars^); Err.Ln;
    SetStatus(failureStatus)
  ELSIF Platform.Unlink(backup.chars^) # 0 THEN
    Err.String("opp: cannot remove "); Err.String(backup.chars^); Err.Ln;
    SetStatus(failureStatus)
  END
END WriteFile;

(* Formats a file, name its name and display its name in messages, and
   checks the result; then writes it to standard output, or back to the
   file with --in-place, or with --check names the file if it would
   change. *)
PROCEDURE FormatFile(name, display: OppText.Text; text: OppText.Buffer);
  VAR
    out, again: OppText.Buffer; line, column, i: LONGINT;
    msg: ARRAY 200 OF CHAR;
BEGIN
  IF ~OppFormat.Format(text.chars, text.len, opts, out, line, column, msg) THEN
    ReportError(display, line, column, msg)
  ELSE
    IF damage # noDamage THEN Damage(out) END;
    IF ~OppCheck.Check(text.chars, text.len, out.chars, out.len, line, column,
                       msg) THEN
      ReportInternal(display, line, column, msg)
    ELSIF ~OppFormat.Format(out.chars, out.len, opts, again, line, column,
                            msg) THEN
      ReportInternal(display, line, column, msg)
    ELSIF check THEN
      IF ~SameText(text, out) THEN
        Out.String(display^); Out.Ln; SetStatus(failureStatus)
      END
    ELSIF inPlace THEN
      IF ~SameText(text, out) THEN WriteFile(name, text, out) END
    ELSE
      FOR i := 0 TO out.len - 1 DO Out.Char(out.chars[i]) END
    END
  END
END FormatFile;

BEGIN
  opts.width := 80; opts.indent := 2; opts.mode := OppFormat.onePerLine;
  opts.moduleIndent := TRUE; opts.caseBar := OppFormat.keepBar;
  opts.align := OppFormat.keepAlign; caseBarOK := TRUE; alignOK := TRUE;
  inPlace := FALSE; check := FALSE; tokens := FALSE;
  damage := noDamage;
  status := 0;
  files := NIL; lastFile := NIL;

  parser := ArgParser.NewParser(
      "opp [options] [file ...]: format Oberon-2 modules for poc or voc; with no file, or -, standard input",
      AddFile);
  parser.AddOption(
      ArgParser.MakeIntOption("w", "width",
          "The maximum line length (20 to 1000; default 80).", SetWidth, 20,
          1000));
  parser.AddOption(
      ArgParser.MakeIntOption("i", "indent",
          "Columns per indentation level (1 to 16; default 2).", SetIndent, 1,
          16));
  parser.AddOption(
      ArgParser.MakeOption("1", "one-per-line",
                           "Put every statement on its own line (the default).",
                           SetOnePerLine));
  parser.AddOption(
      ArgParser.MakeOption("p", "pack",
          "Pack short statements and declarations onto shared lines.",
          SetPack));
  parser.AddOption(
      ArgParser.MakeOption("k", "keep-lines",
                           "Keep statements and declarations on shared lines where the source has them, while they fit.",
                           SetKeepLines));
  parser.AddOption(
      ArgParser.MakeOption(0X, "no-module-indent",
                           "Start a module's declarations at column 1; its statements stay indented.",
                           SetNoModuleIndent));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "case-bar",
                                 "A bar before a CASE's first arm: keep it as written (keep, the default), add one to every CASE (add), or drop it (drop).",
                                 SetCaseBar));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "align",
                                 "The spaces an author lines things up with: keep them while the line fits (keep, the default), or make each one space (drop).",
                                 SetAlign));
  parser.AddOption(
      ArgParser.MakeOption(0X, "in-place",
                           "Replace each file with its formatted text.",
                           SetInPlace));
  parser.AddOption(
      ArgParser.MakeOption("c", "check",
          "Write nothing; exit 1 and name each file that would change.",
          SetCheck));
  parser.AddOption(
      ArgParser.MakeOption(0X, "tokens",
                           "List each file's tokens and comments instead of formatting it (a debugging aid).",
                           SetTokens));
  parser.AddOption(
      ArgParser.MakeIntOption(0X, "damage",
                              "For opp's tests: spoil the formatted text (1 a token, 2 a comment, 3 the text after the module) to show that the safety check catches it.",
                              SetDamage, 1, 3));
  parser.AddOption(
      ArgParser.MakeOption("h", "help", "Show this help and exit.", Help));
  parser.ParseArguments(1);

  IF files = NIL THEN
    stdin := "-";
    IF AddFile(0, stdin) THEN END
  END;
  IF ~caseBarOK THEN UsageError("--case-bar takes keep, add or drop") END;
  IF ~alignOK THEN UsageError("--align takes keep or drop") END;
  IF inPlace & check THEN
    UsageError("--in-place and --check cannot be used together")
  END;
  IF tokens & (inPlace OR check) THEN
    UsageError("--tokens cannot be used with --in-place or --check")
  END;
  IF inPlace THEN
    lastFile := files;
    WHILE lastFile # NIL DO
      IF lastFile.name^ = "-" THEN
        UsageError("--in-place needs files, not standard input")
      END;
      lastFile := lastFile.next
    END
  END;
  WHILE files # NIL DO
    IF ReadInput(files.name, input) THEN
      IF tokens THEN ListTokens(DisplayName(files.name), input)
      ELSE FormatFile(files.name, DisplayName(files.name), input)
      END
    END;
    files := files.next
  END;
  Out.Flush;
  Platform.Exit(status)
END Opp.
