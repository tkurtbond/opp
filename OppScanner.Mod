MODULE OppScanner;

(* The lexer of opp: Oberon-2's vocabulary, as poc and voc read it, without
   losing anything a pretty printer must keep.

   Each token keeps its exact text (a string with its quotes, a number with
   its suffix), its position, whether a blank line comes before it, and the
   comments around it. A comment that begins on the line of the token
   before it is a trailing comment of that token (Token.trail); any other
   comment leads the next token (Token.lead). A comment notes whether a
   blank line comes before it and whether a line break follows it. Tokens
   and comments note the columns between them and what ends before them on
   their line (gap), the spaces an author may have lined things up with.

   The parser pulls tokens one at a time (Next), with one token of
   lookahead (Peek), so the scanner never reads past what the parser asks
   for: nothing after the period that ends a module is scanned, since poc
   and voc do not read it either (PLAN.md, "OppScanner").

   Identifiers take poc's "_" and "$" anywhere a letter may be. Numbers take
   every form poc and voc do: decimal and hexadecimal integers (0FFH),
   characters (41X) and reals with an E or D scale factor (1.5D10).
   Columns are visual: a tab moves to the next multiple of 8, and a byte
   that continues a UTF-8 sequence takes no column. Carriage returns are
   white space, and are dropped from comments.

   The first error is kept (error, errorLine, errorColumn, errorMessage);
   scanning goes on after it, so the parser can report it in order. *)

IMPORT OppText;

CONST
  tabWidth = 8;

  (* token kinds, as poc's Lexer, with one kind for every number *)
  eof* = 0; ident* = 1; number* = 2; string* = 5; invalid* = 6;

  plus* = 7; minus* = 8; times* = 9; slash* = 10; tilde* = 11;
  ampersand* = 12; period* = 13; comma* = 14; semicolon* = 15;
  bar* = 16; lparen* = 17; rparen* = 18;
  lbrak* = 19; rbrak* = 20; lbrace* = 21; rbrace* = 22;
  becomes* = 23; arrow* = 24; eql* = 25; neq* = 26;
  lss* = 27; gtr* = 28; leq* = 29; geq* = 30;
  upto* = 31; colon* = 32;

  array* = 33; begin* = 34; by* = 35; case* = 36;
  const* = 37; div* = 38; do* = 39; else* = 40;
  elsif* = 41; end* = 42; exit* = 43; for* = 44;
  if* = 45; import* = 46; in* = 47; is* = 48;
  loop* = 49; mod* = 50; module* = 51; nil* = 52;
  of* = 53; or* = 54; pointer* = 55; procedure* = 56;
  record* = 57; repeat* = 58; return* = 59; then* = 60;
  to* = 61; type* = 62; until* = 63; var* = 64;
  while* = 65; with* = 66;

  firstKeyword* = array; lastKeyword* = with;

TYPE
  Comment* = POINTER TO CommentDesc;
  CommentDesc* = RECORD
    text*: OppText.Text; (* the whole comment, its delimiters included, carriage returns dropped *)
    line*, column*: LONGINT; (* where the comment starts; column is visual *)
    blankBefore*: BOOLEAN; (* a blank line separates it from what precedes it *)
    newlineAfter*: BOOLEAN; (* a line break (or the end of the text) follows it *)
    multiLine*: BOOLEAN; (* its text holds a line break *)
    gap*: LONGINT; (* the columns between it and the token or comment before
                      it on its line, or 0 if it starts its line *)
    next*: Comment
  END;

  Token* = POINTER TO TokenDesc;
  TokenDesc* = RECORD
    kind*: INTEGER;
    text*: OppText.Text; (* exactly as written *)
    line*, column*: LONGINT; (* where it starts; column is visual *)
    endLine*: LONGINT; (* the line it ends on *)
    start*, end*: LONGINT; (* its text is src[start .. end - 1] *)
    blankBefore*: BOOLEAN; (* a blank line separates it from what precedes it *)
    gap*: LONGINT; (* as Comment.gap *)
    lead*: Comment; (* comments on lines of their own before it *)
    trail*: Comment; (* comments after it on its own line *)
    next: Token (* the lookahead token, in Scanner.ahead *)
  END;

  Scanner* = POINTER TO ScannerDesc;
  ScannerDesc* = RECORD
    src: OppText.Text;
    len, pos: LONGINT;
    line, column: LONGINT;
    prev: Token; (* the last token scanned *)
    lastComment: Comment; (* the last comment scanned since prev *)
    itemLine, itemColumn: LONGINT; (* where the last token or comment ended;
                                      line 0 before the first *)
    ahead: Token; (* a token Peek scanned, which Next returns next *)
    error*: BOOLEAN;
    errorLine*, errorColumn*: LONGINT;
    errorMessage*: ARRAY 80 OF CHAR
  END;

PROCEDURE IsLetter(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "a") & (ch <= "z") OR (ch >= "A") & (ch <= "Z") OR (ch = "_")
      OR (ch = "$")
END IsLetter;

PROCEDURE IsDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "0") & (ch <= "9")
END IsDigit;

PROCEDURE IsHexDigit(ch: CHAR): BOOLEAN;
BEGIN
  RETURN IsDigit(ch) OR (ch >= "A") & (ch <= "F")
END IsHexDigit;

PROCEDURE Error(s: Scanner; line, column: LONGINT; msg: ARRAY OF CHAR);
BEGIN
  IF ~s.error THEN
    s.error := TRUE; s.errorLine := line; s.errorColumn := column;
    COPY(msg, s.errorMessage)
  END
END Error;

PROCEDURE Ch(s: Scanner): CHAR;
BEGIN
  IF s.pos < s.len THEN RETURN s.src[s.pos] ELSE RETURN 0X END
END Ch;

PROCEDURE PeekCh(s: Scanner; offset: LONGINT): CHAR;
BEGIN
  IF s.pos + offset < s.len THEN RETURN s.src[s.pos + offset] ELSE RETURN 0X END
END PeekCh;

(* Moves past the current character, keeping line and visual column. *)
PROCEDURE Advance(s: Scanner);
  VAR ch: CHAR;
BEGIN
  IF s.pos < s.len THEN
    ch := s.src[s.pos]; INC(s.pos);
    IF ch = 0AX THEN
      INC(s.line); s.column := 1
    ELSIF ch = 9X THEN
      s.column := ((s.column - 1) DIV tabWidth + 1) * tabWidth + 1
    ELSIF ch = 0DX THEN
      (* no column *)
    ELSIF (ch < 80X) OR (ch >= 0C0X) THEN
      INC(s.column)
    END
  END
END Advance;

(* The text from start to the current position, without carriage returns. *)
PROCEDURE TextFrom(s: Scanner; start: LONGINT): OppText.Text;
  VAR t: OppText.Text; i, n: LONGINT;
BEGIN
  n := 0;
  FOR i := start TO s.pos - 1 DO
    IF s.src[i] # 0DX THEN INC(n) END
  END;
  NEW(t, n + 1); n := 0;
  FOR i := start TO s.pos - 1 DO
    IF s.src[i] # 0DX THEN t[n] := s.src[i]; INC(n) END
  END;
  t[n] := 0X;
  RETURN t
END TextFrom;

PROCEDURE New*(src: OppText.Text; len: LONGINT): Scanner;
  VAR s: Scanner;
BEGIN
  NEW(s);
  s.src := src; s.len := len; s.pos := 0; s.line := 1; s.column := 1;
  s.itemLine := 0; s.itemColumn := 0;
  s.prev := NIL; s.lastComment := NIL; s.ahead := NIL;
  s.error := FALSE; s.errorLine := 0; s.errorColumn := 0; s.errorMessage := "";
  RETURN s
END New;

(* The gap before a token or comment that starts at line and column: the
   columns since the last token or comment ended, if it ended on that line,
   and otherwise 0. *)
PROCEDURE Gap(s: Scanner; line, column: LONGINT): LONGINT;
BEGIN
  IF s.itemLine = line THEN RETURN column - s.itemColumn END;
  RETURN 0
END Gap;

(* The comment that starts here, nested comments included. *)
PROCEDURE ScanComment(s: Scanner): Comment;
  VAR c: Comment; start, depth: LONGINT; ch: CHAR;
BEGIN
  NEW(c); c.line := s.line; c.column := s.column; c.next := NIL;
  c.blankBefore := FALSE; c.newlineAfter := FALSE; c.multiLine := FALSE;
  start := s.pos;
  Advance(s); Advance(s); depth := 1;
  WHILE depth > 0 DO
    ch := Ch(s);
    IF s.pos >= s.len THEN
      Error(s, c.line, c.column, "unterminated comment"); depth := 0
    ELSIF (ch = "(") & (PeekCh(s, 1) = "*") THEN
      Advance(s); Advance(s); INC(depth)
    ELSIF (ch = "*") & (PeekCh(s, 1) = ")") THEN
      Advance(s); Advance(s); DEC(depth)
    ELSE
      IF ch = 0AX THEN c.multiLine := TRUE END;
      Advance(s)
    END
  END;
  c.text := TextFrom(s, start);
  RETURN c
END ScanComment;

PROCEDURE Keyword(VAR name: ARRAY OF CHAR): INTEGER;
  VAR k: INTEGER;
BEGIN
  CASE name[0] OF
    "A": IF name = "ARRAY" THEN k := array ELSE k := ident END
  | "B":
      IF name = "BEGIN" THEN k := begin
      ELSIF name = "BY" THEN k := by
      ELSE k := ident
      END
  | "C":
      IF name = "CASE" THEN k := case
      ELSIF name = "CONST" THEN k := const
      ELSE k := ident
      END
  | "D":
      IF name = "DIV" THEN k := div
      ELSIF name = "DO" THEN k := do
      ELSE k := ident
      END
  | "E":
      IF name = "ELSE" THEN k := else
      ELSIF name = "ELSIF" THEN k := elsif
      ELSIF name = "END" THEN k := end
      ELSIF name = "EXIT" THEN k := exit
      ELSE k := ident
      END
  | "F": IF name = "FOR" THEN k := for ELSE k := ident END
  | "I":
      IF name = "IF" THEN k := if
      ELSIF name = "IMPORT" THEN k := import
      ELSIF name = "IN" THEN k := in
      ELSIF name = "IS" THEN k := is
      ELSE k := ident
      END
  | "L": IF name = "LOOP" THEN k := loop ELSE k := ident END
  | "M":
      IF name = "MOD" THEN k := mod
      ELSIF name = "MODULE" THEN k := module
      ELSE k := ident
      END
  | "N": IF name = "NIL" THEN k := nil ELSE k := ident END
  | "O":
      IF name = "OF" THEN k := of
      ELSIF name = "OR" THEN k := or
      ELSE k := ident
      END
  | "P":
      IF name = "POINTER" THEN k := pointer
      ELSIF name = "PROCEDURE" THEN k := procedure
      ELSE k := ident
      END
  | "R":
      IF name = "RECORD" THEN k := record
      ELSIF name = "REPEAT" THEN k := repeat
      ELSIF name = "RETURN" THEN k := return
      ELSE k := ident
      END
  | "T":
      IF name = "THEN" THEN k := then
      ELSIF name = "TO" THEN k := to
      ELSIF name = "TYPE" THEN k := type
      ELSE k := ident
      END
  | "U": IF name = "UNTIL" THEN k := until ELSE k := ident END
  | "V": IF name = "VAR" THEN k := var ELSE k := ident END
  | "W":
      IF name = "WHILE" THEN k := while
      ELSIF name = "WITH" THEN k := with
      ELSE k := ident
      END
  ELSE k := ident
  END;
  RETURN k
END Keyword;

PROCEDURE ScanIdent(s: Scanner; t: Token);
BEGIN
  WHILE IsLetter(Ch(s)) OR IsDigit(Ch(s)) DO Advance(s) END;
  t.text := TextFrom(s, t.start);
  t.kind := Keyword(t.text^)
END ScanIdent;

(* digit {hexDigit} ["H" | "X"], or digit {digit} "." {digit}
   [("E" | "D") ["+" | "-"] digit {digit}]; "1..2" is a number and "..". *)
PROCEDURE ScanNumber(s: Scanner; t: Token);
  VAR allDecimal: BOOLEAN;
BEGIN
  allDecimal := TRUE;
  WHILE IsHexDigit(Ch(s)) DO
    IF ~IsDigit(Ch(s)) THEN allDecimal := FALSE END;
    Advance(s)
  END;
  IF (Ch(s) = "H") OR (Ch(s) = "X") THEN
    Advance(s)
  ELSIF allDecimal & (Ch(s) = ".") & (PeekCh(s, 1) # ".") THEN
    Advance(s);
    WHILE IsDigit(Ch(s)) DO Advance(s) END;
    IF (Ch(s) = "E") OR (Ch(s) = "D") THEN
      Advance(s);
      IF (Ch(s) = "+") OR (Ch(s) = "-") THEN Advance(s) END;
      IF ~IsDigit(Ch(s)) THEN Error(s, t.line, t.column, "invalid number") END;
      WHILE IsDigit(Ch(s)) DO Advance(s) END
    END
  ELSIF ~allDecimal THEN
    Error(s, t.line, t.column, "invalid number")
  END;
  (* A letter may follow at once: "1THEN" is "1" and THEN to poc and voc. *)
  t.text := TextFrom(s, t.start);
  t.kind := number
END ScanNumber;

(* A string ends at its closing quote, on its own line. *)
PROCEDURE ScanString(s: Scanner; t: Token);
  VAR quote: CHAR;
BEGIN
  quote := Ch(s); Advance(s);
  WHILE (s.pos < s.len) & (Ch(s) # quote) & (Ch(s) # 0AX) DO Advance(s) END;
  IF Ch(s) = quote THEN
    Advance(s)
  ELSE
    Error(s, t.line, t.column, "unterminated string")
  END;
  t.text := TextFrom(s, t.start);
  t.kind := string
END ScanString;

PROCEDURE ScanSymbol(s: Scanner; t: Token);
  VAR ch, next: CHAR;
BEGIN
  ch := Ch(s); Advance(s); next := Ch(s);
  CASE ch OF
    "+": t.kind := plus
  | "-": t.kind := minus
  | "*": t.kind := times
  | "/": t.kind := slash
  | "~": t.kind := tilde
  | "&": t.kind := ampersand
  | ",": t.kind := comma
  | ";": t.kind := semicolon
  | "|": t.kind := bar
  | "(": t.kind := lparen
  | ")": t.kind := rparen
  | "[": t.kind := lbrak
  | "]": t.kind := rbrak
  | "{": t.kind := lbrace
  | "}": t.kind := rbrace
  | "^": t.kind := arrow
  | "=": t.kind := eql
  | "#": t.kind := neq
  | ".": IF next = "." THEN Advance(s); t.kind := upto ELSE t.kind := period END
  | ":":
      IF next = "=" THEN Advance(s); t.kind := becomes ELSE t.kind := colon END
  | "<": IF next = "=" THEN Advance(s); t.kind := leq ELSE t.kind := lss END
  | ">": IF next = "=" THEN Advance(s); t.kind := geq ELSE t.kind := gtr END
  ELSE
    Error(s, t.line, t.column, "invalid character");
    t.kind := invalid
  END;
  t.text := TextFrom(s, t.start)
END ScanSymbol;

(* The next token, with the comments before it: those on the previous
   token's line become its trailing comments, the rest this token's
   leading ones. *)
PROCEDURE Scan(s: Scanner): Token;
  VAR
    t: Token; c, leadTail: Comment; ch: CHAR;
    newlines: LONGINT; (* line breaks since the last token or comment *)
    sinceToken: BOOLEAN; (* a line break since the last token *)
BEGIN
  NEW(t); t.lead := NIL; t.trail := NIL; t.next := NIL; leadTail := NIL;
  newlines := 0; sinceToken := FALSE;
  LOOP
    ch := Ch(s);
    IF s.pos >= s.len THEN EXIT
    ELSIF ch = 0AX THEN
      INC(newlines); sinceToken := TRUE;
      IF s.lastComment # NIL THEN s.lastComment.newlineAfter := TRUE END;
      Advance(s)
    ELSIF (ch = " ") OR (ch = 9X) OR (ch = 0DX) OR (ch = 0CX) THEN
      Advance(s)
    ELSIF (ch = "(") & (PeekCh(s, 1) = "*") THEN
      c := ScanComment(s); c.gap := Gap(s, c.line, c.column);
      s.itemLine := s.line; s.itemColumn := s.column;
      c.blankBefore := (newlines >= 2)
          & ((s.prev # NIL) OR (s.lastComment # NIL) OR (leadTail # NIL));
      IF (s.prev # NIL) & ~sinceToken THEN
        IF s.prev.trail = NIL THEN
          s.prev.trail := c
        ELSE
          s.lastComment.next := c
        END
      ELSE
        IF leadTail = NIL THEN t.lead := c ELSE leadTail.next := c END;
        leadTail := c
      END;
      s.lastComment := c; newlines := 0
    ELSE
      EXIT
    END
  END;
  IF (s.pos >= s.len) & (s.lastComment # NIL) THEN
    s.lastComment.newlineAfter := TRUE
  END;
  t.blankBefore := (newlines >= 2) & ((s.prev # NIL) OR (leadTail # NIL));
  t.line := s.line; t.column := s.column; t.start := s.pos;
  t.gap := Gap(s, t.line, t.column);
  ch := Ch(s);
  IF s.pos >= s.len THEN
    t.kind := eof; t.text := OppText.New("")
  ELSIF IsLetter(ch) THEN ScanIdent(s, t)
  ELSIF IsDigit(ch) THEN ScanNumber(s, t)
  ELSIF (ch = 22X) OR (ch = 27X) THEN ScanString(s, t)
  ELSE ScanSymbol(s, t)
  END;
  t.end := s.pos; t.endLine := s.line;
  s.itemLine := s.line; s.itemColumn := s.column;
  s.prev := t; s.lastComment := NIL;
  RETURN t
END Scan;

(* The next token. *)
PROCEDURE Next*(s: Scanner): Token;
  VAR t: Token;
BEGIN
  IF s.ahead # NIL THEN
    t := s.ahead; s.ahead := NIL
  ELSE
    t := Scan(s)
  END;
  RETURN t
END Next;

(* The token Next will return, without consuming it. *)
PROCEDURE Peek*(s: Scanner): Token;
BEGIN
  IF s.ahead = NIL THEN s.ahead := Scan(s) END;
  RETURN s.ahead
END Peek;

(* The kind's name, for messages and the --tokens listing: a keyword or a
   symbol as written, otherwise a word. *)
PROCEDURE KindName*(kind: INTEGER; VAR name: ARRAY OF CHAR);
BEGIN
  CASE kind OF
    eof: COPY("end of text", name)
  | ident: COPY("identifier", name)
  | number: COPY("number", name)
  | string: COPY("string", name)
  | invalid: COPY("invalid character", name)
  | plus: COPY("+", name)
  | minus: COPY("-", name)
  | times: COPY("*", name)
  | slash: COPY("/", name)
  | tilde: COPY("~", name)
  | ampersand: COPY("&", name)
  | period: COPY(".", name)
  | comma: COPY(",", name)
  | semicolon: COPY(";", name)
  | bar: COPY("|", name)
  | lparen: COPY("(", name)
  | rparen: COPY(")", name)
  | lbrak: COPY("[", name)
  | rbrak: COPY("]", name)
  | lbrace: COPY("{", name)
  | rbrace: COPY("}", name)
  | becomes: COPY(":=", name)
  | arrow: COPY("^", name)
  | eql: COPY("=", name)
  | neq: COPY("#", name)
  | lss: COPY("<", name)
  | gtr: COPY(">", name)
  | leq: COPY("<=", name)
  | geq: COPY(">=", name)
  | upto: COPY("..", name)
  | colon: COPY(":", name)
  | array: COPY("ARRAY", name)
  | begin: COPY("BEGIN", name)
  | by: COPY("BY", name)
  | case: COPY("CASE", name)
  | const: COPY("CONST", name)
  | div: COPY("DIV", name)
  | do: COPY("DO", name)
  | else: COPY("ELSE", name)
  | elsif: COPY("ELSIF", name)
  | end: COPY("END", name)
  | exit: COPY("EXIT", name)
  | for: COPY("FOR", name)
  | if: COPY("IF", name)
  | import: COPY("IMPORT", name)
  | in: COPY("IN", name)
  | is: COPY("IS", name)
  | loop: COPY("LOOP", name)
  | mod: COPY("MOD", name)
  | module: COPY("MODULE", name)
  | nil: COPY("NIL", name)
  | of: COPY("OF", name)
  | or: COPY("OR", name)
  | pointer: COPY("POINTER", name)
  | procedure: COPY("PROCEDURE", name)
  | record: COPY("RECORD", name)
  | repeat: COPY("REPEAT", name)
  | return: COPY("RETURN", name)
  | then: COPY("THEN", name)
  | to: COPY("TO", name)
  | type: COPY("TYPE", name)
  | until: COPY("UNTIL", name)
  | var: COPY("VAR", name)
  | while: COPY("WHILE", name)
  | with: COPY("WITH", name)
  ELSE COPY("?", name)
  END
END KindName;

END OppScanner.
