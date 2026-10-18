MODULE Opp;

(* opp, the Oberon pretty printer: the command line.

   opp [options] [file ...] formats Oberon-2 modules written for poc or voc
   (PLAN.md, "Command line"), writing each to standard output, or with
   --in-place back to its file, or with --output-dir to a file of the same
   name in a directory, or with --check only naming the files that would
   change. --tokens, a debugging aid, lists each file's tokens and
   comments as OppScanner sees them instead.

   Nothing is written for a file until its formatted text passes the safety
   check: OppCheck finds the input's tokens and comments in it, and it
   parses again. A failure is an internal error, exit status 3. --damage,
   for opp's own tests, spoils the formatted text first, to show that the
   check catches it.

   Before the command line, opp reads its options from the config files,
   each line an option as the command line gives it: the user's
   (OppHost.UserConfig: on Unix $XDG_CONFIG_HOME/opp/opp.conf, or
   ~/.config/opp/opp.conf), then the current directory's
   (OppHost.directoryConfig: on Unix .opp.conf), so the command line
   overrides both and the directory's overrides the user's. --config names
   the one file to read instead, and --no-config reads none.

   What depends on the host system - file names, wildcards, the case of
   options, config files, and how --in-place replaces a file - is
   OppHost's, which has one implementation for Unix and one for VAX/VMS
   (VAX-VMS-PORT.md). *)

IMPORT SYSTEM, ArgParser, Args, Err, In, Out, Platform, OppText, OppScanner,
    OppFormat, OppCheck, OppHost;

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
  outDir: OppText.Text; (* --output-dir's directory, or NIL *)
  damage: LONGINT;
  caseBarOK, parenSpaceOK, alignOK, cuddleOK: BOOLEAN; (* --case-bar's,
      --paren-space's, --align's and the --cuddle options' values were ones
      they take *)
  configFile: OppText.Text; (* --config's file, or NIL *)
  noConfig: BOOLEAN; (* --no-config *)
  status: INTEGER; (* the exit status so far *)
  files, lastFile: FileName;
  fileArgs: BOOLEAN; (* whether the command line names a file, or - *)
  input: OppText.Buffer;
  stdin: ARRAY 2 OF CHAR;
  alignHelp: OppText.Buffer; (* --align's help, made of parts so that no
                               line of opp's source is longer than the
                               255 characters VMS's CREATE takes *)

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

PROCEDURE SetParenSpace(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF val = "keep" THEN opts.parenSpace := OppFormat.keepSpace
  ELSIF val = "add" THEN opts.parenSpace := OppFormat.addSpace
  ELSIF val = "drop" THEN opts.parenSpace := OppFormat.dropSpace
  ELSE parenSpaceOK := FALSE
  END;
  RETURN TRUE
END SetParenSpace;

(* A --cuddle option's value as a constant of OppFormat's, in c. *)
PROCEDURE Cuddle(VAR val: ARRAY OF CHAR; VAR c: INTEGER);
BEGIN
  IF val = "allow" THEN c := OppFormat.cuddleAllow
  ELSIF val = "force" THEN c := OppFormat.cuddleForce
  ELSIF val = "disallow" THEN c := OppFormat.cuddleDisallow
  ELSE cuddleOK := FALSE
  END
END Cuddle;

PROCEDURE SetCuddleBegin(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  Cuddle(val, opts.cuddleBegin); RETURN TRUE
END SetCuddleBegin;

PROCEDURE SetCuddleEnd(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  Cuddle(val, opts.cuddleEnd); RETURN TRUE
END SetCuddleEnd;

(* The kinds of alignment word names, as a set: all of them for all, none
   if it names none. *)
PROCEDURE AlignKinds(VAR word: ARRAY OF CHAR): SET;
BEGIN
  IF word = "const" THEN RETURN {OppFormat.alignConst}
  ELSIF word = "type" THEN RETURN {OppFormat.alignType}
  ELSIF word = "var" THEN RETURN {OppFormat.alignVar}
  ELSIF word = "field" THEN RETURN {OppFormat.alignField}
  ELSIF word = "init" THEN RETURN {OppFormat.alignInit}
  ELSIF word = "comment" THEN RETURN {OppFormat.alignComment}
  ELSIF word = "case" THEN RETURN {OppFormat.alignCase}
  ELSIF word = "assign" THEN RETURN {OppFormat.alignAssign}
  ELSIF word = "all" THEN
    RETURN {OppFormat.alignConst..OppFormat.alignAssign}
  END;
  RETURN {}
END AlignKinds;

(* One word of --align: keep or drop, for the author's spaces; a kind, or
   all, for opp to line up; no and a kind, or noall, for one space. *)
PROCEDURE AlignWord(VAR word: ARRAY OF CHAR);
  VAR rest: ARRAY 32 OF CHAR; i: LONGINT; k: SET;
BEGIN
  IF word = "keep" THEN opts.align := OppFormat.keepAlign
  ELSIF word = "drop" THEN opts.align := OppFormat.dropAlign
  ELSE
    k := AlignKinds(word);
    IF k # {} THEN
      opts.lineUp := opts.lineUp + k; opts.single := opts.single - k
    ELSIF (word[0] = "n") & (word[1] = "o") THEN
      i := 2;
      WHILE (word[i] # 0X) & (i - 2 < LEN(rest) - 1) DO
        rest[i - 2] := word[i]; INC(i)
      END;
      rest[i - 2] := 0X;
      k := AlignKinds(rest);
      IF k = {} THEN alignOK := FALSE END;
      opts.single := opts.single + k; opts.lineUp := opts.lineUp - k
    ELSE
      alignOK := FALSE
    END
  END
END AlignWord;

(* --align's value: words separated by commas, each overriding those
   before it. *)
PROCEDURE SetAlign(VAR val: ARRAY OF CHAR): BOOLEAN;
  VAR word: ARRAY 32 OF CHAR; i, j: LONGINT;
BEGIN
  i := 0;
  REPEAT
    j := 0;
    WHILE (i < LEN(val)) & (val[i] # 0X) & (val[i] # ",") DO
      IF j < LEN(word) - 1 THEN word[j] := val[i]; INC(j) END;
      INC(i)
    END;
    word[j] := 0X;
    AlignWord(word);
    IF (i < LEN(val)) & (val[i] = ",") THEN INC(i) ELSE i := -1 END
  UNTIL i < 0;
  RETURN TRUE
END SetAlign;

PROCEDURE SetModuleIndent(): BOOLEAN;
BEGIN
  opts.moduleIndent := TRUE; RETURN TRUE
END SetModuleIndent;

(* --config and --no-config, which FindConfigOptions has read already. *)
PROCEDURE SetConfig(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN TRUE
END SetConfig;

PROCEDURE SetNoConfig(): BOOLEAN;
BEGIN
  RETURN TRUE
END SetNoConfig;

PROCEDURE SetNoModuleIndent(): BOOLEAN;
BEGIN
  opts.moduleIndent := FALSE; RETURN TRUE
END SetNoModuleIndent;

PROCEDURE SetOutputDir(VAR val: ARRAY OF CHAR): BOOLEAN;
BEGIN
  outDir := OppText.New(val); RETURN TRUE
END SetOutputDir;

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

(* A file to format, or "-" for standard input, kept in order. *)
PROCEDURE Add(name: OppText.Text);
  VAR f: FileName;
BEGIN
  NEW(f); f.name := name; f.next := NIL;
  IF lastFile = NIL THEN files := f ELSE lastFile.next := f END;
  lastFile := f
END Add;

(* A file argument: "-" for standard input, or the files it names; one
   that names none is a failure, exit status 1. *)
PROCEDURE AddFile(startIdx: INTEGER; VAR arg: ARRAY OF CHAR): BOOLEAN;
BEGIN
  fileArgs := TRUE;
  IF arg = "-" THEN
    Add(OppText.New(arg))
  ELSIF ~OppHost.Expand(arg, Add) THEN
    Out.Flush;
    Err.String("opp: no file matches "); Err.String(arg); Err.Ln;
    SetStatus(failureStatus)
  END;
  RETURN TRUE
END AddFile;

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

(* out written to a new file target, or on VMS a new version of it, which
   is removed if it cannot be written whole. *)
PROCEDURE WriteNew(target: OppText.Text; out: OppText.Buffer);
  VAR h: Platform.FileHandle;
BEGIN
  Out.Flush;
  IF Platform.New(target^, h) # 0 THEN
    Err.String("opp: cannot write "); Err.String(target^); Err.Ln;
    SetStatus(failureStatus)
  ELSIF ~WriteAll(target^, h, out) THEN
    Err.String("opp: cannot write "); Err.String(target^); Err.Ln;
    IF Platform.Unlink(target^) # 0 THEN END;
    SetStatus(failureStatus)
  END
END WriteNew;

(* out as the new content of the file name, written over it so that it
   keeps its permissions, owner and links. Once the file is open, its old
   content is copied to name.opp-backup, which is deleted when the file is
   written, and which a failure leaves for the user to restore. *)
PROCEDURE WriteOver(name: OppText.Text; old, out: OppText.Buffer);
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
END WriteOver;

(* out as the new content of the file name: with OppHost.newVersions, as
   VMS does, a new version of it, the old one left as it was; otherwise
   written over it. *)
PROCEDURE WriteFile(name: OppText.Text; old, out: OppText.Buffer);
BEGIN
  IF OppHost.newVersions THEN
    WriteNew(OppHost.WithoutVersion(name), out)
  ELSE
    WriteOver(name, old, out)
  END
END WriteFile;

(* The file --output-dir writes name's formatted text to: the file of the
   same base name in the directory. *)
PROCEDURE OutputName(name: OppText.Text): OppText.Text;
BEGIN
  RETURN OppHost.InDirectory(outDir, OppHost.BaseName(name))
END OutputName;

(* out written to the file of name's base name in --output-dir's directory,
   created or replaced, unless that is the file name itself. *)
PROCEDURE WriteOutput(name: OppText.Text; out: OppText.Buffer);
  VAR target: OppText.Text; a, b: Platform.FileIdentity;
BEGIN
  target := OutputName(name);
  IF (Platform.IdentifyByName(target^, a) = 0)
      & (Platform.IdentifyByName(name^, b) = 0) & Platform.SameFile(a, b) THEN
    Out.Flush;
    Err.String("opp: --output-dir would write over "); Err.String(name^);
    Err.String(
        " itself, so nothing is written for it (--in-place formats a file in place)");
    Err.Ln;
    SetStatus(failureStatus)
  ELSE
    WriteNew(target, out)
  END
END WriteOutput;

(* --output-dir's checks, before any file is formatted: the directory
   exists, and no two files would be written to the same name in it. *)
PROCEDURE CheckOutputDir;
  VAR f, g: FileName; t: OppText.Text;
BEGIN
  IF ~OppHost.IsDirectory(outDir) THEN
    Out.Flush;
    Err.String("opp: --output-dir: there is no directory ");
    Err.String(outDir^); Err.Ln;
    Platform.Exit(ArgParser.UsageErrorStatus)
  END;
  f := files;
  WHILE f # NIL DO
    g := f.next;
    WHILE g # NIL DO
      IF OppText.Equal(OppHost.BaseName(f.name), OppHost.BaseName(g.name)) THEN
        Out.Flush;
        Err.String("opp: --output-dir: "); Err.String(f.name^);
        Err.String(" and "); Err.String(g.name^);
        Err.String(" would both be written to ");
        t := OutputName(f.name); Err.String(t^); Err.Ln;
        Platform.Exit(ArgParser.UsageErrorStatus)
      END;
      g := g.next
    END;
    f := f.next
  END
END CheckOutputDir;

(* ---- Config files ---- *)

(* --config and --no-config, found on the command line before ArgParser
   reads it, as they say which config files to read before it. The last
   one wins; nothing after -- is an option. *)
PROCEDURE FindConfigOptions;
  VAR i, j: INTEGER; arg: ArgParser.String;
BEGIN
  configFile := NIL; noConfig := FALSE; i := 1;
  WHILE i < Args.argc DO
    Args.Get(i, arg); OppHost.FoldOption(arg);
    IF arg = "--" THEN
      i := Args.argc
    ELSIF arg = "--no-config" THEN
      noConfig := TRUE; configFile := NIL
    ELSIF arg = "--config" THEN
      IF i + 1 < Args.argc THEN
        INC(i); Args.Get(i, arg); OppHost.FoldOption(arg);
        configFile := OppText.New(arg);
        noConfig := FALSE
      END
    ELSIF (arg[0] = "-") & (arg[1] = "-") & (arg[2] = "c") & (arg[3] = "o")
        & (arg[4] = "n") & (arg[5] = "f") & (arg[6] = "i") & (arg[7] = "g")
        & (arg[8] = "=") THEN
      j := 0;
      WHILE arg[j + 9] # 0X DO arg[j] := arg[j + 9]; INC(j) END;
      arg[j] := 0X;
      configFile := OppText.New(arg); noConfig := FALSE
    END;
    INC(i)
  END
END FindConfigOptions;

(* Starts the report of a mistake on line n of the config file name. *)
PROCEDURE ConfigError(name: OppText.Text; n: LONGINT);
BEGIN
  Out.Flush;
  Err.String("opp: "); Err.String(name^); Err.Char(":"); ErrNumber(n);
  Err.String(": ")
END ConfigError;

(* Ends that report, with exit status 2. *)
PROCEDURE EndConfigError;
BEGIN
  Err.Ln;
  Platform.Exit(ArgParser.UsageErrorStatus)
END EndConfigError;

PROCEDURE IsBlank(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch = " ") OR (ch = 9X) OR (ch = 0DX)
END IsBlank;

(* Whether the option named key may be in a config file: those that say
   how to format, not what to do. *)
PROCEDURE Configurable(VAR key: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (key # "in-place") & (key # "check") & (key # "tokens")
      & (key # "damage") & (key # "help") & (key # "config")
      & (key # "no-config") & (key # "output-dir")
END Configurable;

(* Line n of the config file name, t[from .. to - 1]: blank, or an
   option's long name, with or without --, then its value, if it takes
   one, after white space or =; # starts a comment. *)
PROCEDURE ConfigLine(name: OppText.Text; n: LONGINT; VAR t: ARRAY OF CHAR;
                     from, to: LONGINT);
  VAR
    k, e, m, v: LONGINT; key: ARRAY 64 OF CHAR; val: ArgParser.String;
    opt: ArgParser.Option;
BEGIN
  e := from;
  WHILE (e < to) & (t[e] # "#") DO INC(e) END;
  WHILE (e > from) & IsBlank(t[e - 1]) DO DEC(e) END;
  k := from;
  WHILE (k < e) & IsBlank(t[k]) DO INC(k) END;
  IF k = e THEN RETURN END;
  IF (k + 1 < e) & (t[k] = "-") & (t[k + 1] = "-") THEN INC(k, 2) END;
  m := 0;
  WHILE (k < e) & ~IsBlank(t[k]) & (t[k] # "=") DO
    IF m < LEN(key) - 1 THEN key[m] := t[k]; INC(m) END;
    INC(k)
  END;
  key[m] := 0X;
  WHILE (k < e) & IsBlank(t[k]) DO INC(k) END;
  IF (k < e) & (t[k] = "=") THEN
    INC(k);
    WHILE (k < e) & IsBlank(t[k]) DO INC(k) END
  END;
  m := 0;
  WHILE k < e DO
    IF m < LEN(val) - 1 THEN val[m] := t[k]; INC(m) END;
    INC(k)
  END;
  val[m] := 0X;
  opt := parser.options;
  WHILE (opt # NIL) & (opt.longName # key) DO opt := opt.next END;
  IF (opt = NIL) OR (key = "") THEN
    ConfigError(name, n); Err.String("unknown option "); Err.String(key);
    EndConfigError
  ELSIF ~Configurable(key) THEN
    ConfigError(name, n); Err.String("--"); Err.String(key);
    Err.String(" cannot be in a config file"); EndConfigError
  ELSIF opt.kind = ArgParser.NoArgOption THEN
    IF val # "" THEN
      ConfigError(name, n); Err.String("--"); Err.String(key);
      Err.String(" takes no value"); EndConfigError
    END;
    IF opt.handler() THEN END
  ELSIF val = "" THEN
    ConfigError(name, n); Err.String("--"); Err.String(key);
    Err.String(" needs a value"); EndConfigError
  ELSIF opt.kind = ArgParser.StringOption THEN
    IF opt.stringHandler(val) THEN END;
    IF ~caseBarOK OR ~parenSpaceOK OR ~alignOK OR ~cuddleOK THEN
      ConfigError(name, n); Err.String("--"); Err.String(key);
      Err.String(" does not take "); Err.String(val); EndConfigError
    END
  ELSIF ~ArgParser.StrToInt(val, v) OR (v < opt.minInt) OR (v > opt.maxInt) THEN
    ConfigError(name, n); Err.String("--"); Err.String(key);
    Err.String(" takes a number from "); ErrNumber(opt.minInt);
    Err.String(" to "); ErrNumber(opt.maxInt); EndConfigError
  ELSE
    IF opt.intHandler(v) THEN END
  END
END ConfigLine;

(* The options in the config file name; if it does not exist, nothing,
   unless required. *)
PROCEDURE ReadConfig(name: OppText.Text; required: BOOLEAN);
  VAR h: Platform.FileHandle; text: OppText.Buffer; i, j, n: LONGINT;
BEGIN
  IF Platform.OldRO(name^, h) # 0 THEN
    IF required THEN
      Out.Flush;
      Err.String("opp: cannot open config file "); Err.String(name^); Err.Ln;
      Platform.Exit(ArgParser.UsageErrorStatus)
    END;
    RETURN
  END;
  IF Platform.Close(h) # 0 THEN END;
  IF ~ReadInput(name, text) THEN
    Out.Flush; Platform.Exit(ArgParser.UsageErrorStatus)
  END;
  i := 0; n := 1;
  WHILE i < text.len DO
    j := i;
    WHILE (j < text.len) & (text.chars[j] # 0AX) DO INC(j) END;
    ConfigLine(name, n, text.chars^, i, j);
    i := j + 1; INC(n)
  END
END ReadConfig;

(* Reads the config files the command line asks for. *)
PROCEDURE ReadConfigs;
  VAR user: OppText.Text;
BEGIN
  FindConfigOptions;
  IF noConfig THEN
  ELSIF configFile # NIL THEN
    ReadConfig(configFile, TRUE)
  ELSE
    user := OppHost.UserConfig();
    IF user # NIL THEN ReadConfig(user, FALSE) END;
    ReadConfig(OppText.New(OppHost.directoryConfig), FALSE)
  END
END ReadConfigs;

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
    ELSIF outDir # NIL THEN
      WriteOutput(name, out)
    ELSE
      FOR i := 0 TO out.len - 1 DO
        IF out.chars[i] = 0AX THEN Out.Ln ELSE Out.Char(out.chars[i]) END
      END
    END
  END
END FormatFile;

BEGIN
  opts.width := 80; opts.indent := 2; opts.mode := OppFormat.onePerLine;
  opts.moduleIndent := TRUE; opts.caseBar := OppFormat.keepBar;
  opts.parenSpace := OppFormat.keepSpace;
  opts.align := OppFormat.keepAlign; opts.lineUp := {}; opts.single := {};
  opts.cuddleBegin := OppFormat.cuddleAllow;
  opts.cuddleEnd := OppFormat.cuddleAllow;
  caseBarOK := TRUE; parenSpaceOK := TRUE; alignOK := TRUE;
  cuddleOK := TRUE;
  inPlace := FALSE; check := FALSE; tokens := FALSE; outDir := NIL;
  damage := noDamage;
  status := 0;
  files := NIL; lastFile := NIL; fileArgs := FALSE;

  parser := ArgParser.NewParser(
      "opp [options] [file ...]: format Oberon-2 modules for poc or voc; with no file, or -, standard input",
      AddFile);
  parser.filter := OppHost.FoldOption;
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
      ArgParser.MakeOption(0X, "module-indent",
                           "Indent a module's declarations (the default).",
                           SetModuleIndent));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "case-bar",
                                 "A bar before a CASE's first arm: keep it as written (keep, the default), add one to every CASE (add), or drop it (drop).",
                                 SetCaseBar));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "paren-space",
                                 "A blank before the parenthesis of a call, a type guard or a procedure's parameters, as P (x): keep it as written (keep, the default), add one to every one (add), or drop it (drop).",
                                 SetParenSpace));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "cuddle-begin",
                                 "A body's first line on BEGIN's line, as BEGIN RETURN x: where the source has it there (allow, the default), always (force), or never (disallow); only while it fits.",
                                 SetCuddleBegin));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "cuddle-end",
                                 "END on that line too, when the whole body is on it, as BEGIN RETURN x END Get: where the source has it there (allow, the default), always (force), or never (disallow); only while it fits.",
                                 SetCuddleEnd));
  alignHelp := OppText.NewBuffer();
  OppText.Append(alignHelp,
                 "What to line up, as words separated by commas: const, type, var, field, init, comment, case and assign have opp line up the = of constants or types, ");
  OppText.Append(alignHelp,
                 "the types of variables or fields, the := of initializers, trailing comments, CASE bodies, or the := of assignments; all, all of them; no before one of those gives it one space; ");
  OppText.Append(alignHelp,
                 "keep (the default) or drop keeps the author's spaces elsewhere while the line fits, or gives one space. With -p or -k, const, ");
  OppText.Append(alignHelp,
                 "type and var put declarations that share lines in a grid of straight columns.");
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "align", alignHelp.chars^, SetAlign));
  parser.AddOption(
      ArgParser.MakeOption(0X, "in-place",
                           "Replace each file with its formatted text.",
                           SetInPlace));
  parser.AddOption(
      ArgParser.MakeStringOption(0X, "output-dir",
                                 "Write each file's formatted text to the file of the same name in this directory, which must exist.",
                                 SetOutputDir));
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
      ArgParser.MakeStringOption(0X, "config", OppHost.configHelp, SetConfig));
  parser.AddOption(
      ArgParser.MakeOption(0X, "no-config", "Read no config file.",
                           SetNoConfig));
  parser.AddOption(
      ArgParser.MakeOption("h", "help", "Show this help and exit.", Help));
  ReadConfigs;
  parser.ParseArguments(1);

  IF ~fileArgs THEN
    stdin := "-";
    IF AddFile(0, stdin) THEN END
  END;
  IF ~caseBarOK THEN UsageError("--case-bar takes keep, add or drop") END;
  IF ~parenSpaceOK THEN
    UsageError("--paren-space takes keep, add or drop")
  END;
  IF ~cuddleOK THEN
    UsageError("--cuddle-begin and --cuddle-end take allow, force or disallow")
  END;
  IF ~alignOK THEN
    UsageError(
        "--align takes words separated by commas: keep, drop, all, const, type, var, field, init, comment, case or assign, each of the last nine with or without no before it")
  END;
  IF inPlace & check THEN
    UsageError("--in-place and --check cannot be used together")
  END;
  IF tokens & (inPlace OR check) THEN
    UsageError("--tokens cannot be used with --in-place or --check")
  END;
  IF (outDir # NIL) & (inPlace OR check OR tokens) THEN
    UsageError(
        "--output-dir cannot be used with --in-place, --check or --tokens")
  END;
  IF inPlace OR (outDir # NIL) THEN
    lastFile := files;
    WHILE lastFile # NIL DO
      IF lastFile.name^ = "-" THEN
        IF inPlace THEN
          UsageError("--in-place needs files, not standard input")
        ELSE
          UsageError("--output-dir needs files, not standard input")
        END
      END;
      lastFile := lastFile.next
    END
  END;
  IF outDir # NIL THEN CheckOutputDir END;
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
