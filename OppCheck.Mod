MODULE OppCheck;

(* The safety check of opp: whether a formatted text says what its source
   says (PLAN.md, "Opp: the program").

   Both texts are scanned up to the period that ends the module, as a
   sequence of tokens and comments in order. The output's sequence must be
   the source's, except that the source may have semicolons and bars the
   output leaves out (an empty statement's or field list's semicolon, an
   empty CASE arm's bar). Tokens are compared by kind and text; comments by
   their text, with the white space at the start and end of each line
   removed, since opp re-indents a comment's later lines. Then the text
   after the period must be the same, or white space in both.

   Since a comment is compared where it falls among the tokens, one moved
   past a token is a difference, as is one lost. Whether the output still
   parses is the caller's to check. *)

IMPORT OppText, S := OppScanner;

CONST commentItem = -1; (* Item.kind of a comment *)

TYPE
  Item = POINTER TO ItemDesc;
  ItemDesc = RECORD
    kind: INTEGER; (* a token's kind, or commentItem *)
    text: OppText.Text; (* a comment's with each line trimmed *)
    line, column: LONGINT;
    next: Item
  END;

  Stream = RECORD
    first, last: Item;
    rest: LONGINT; (* where the text after the period starts, or -1
                      if there is no such period *)
    error: BOOLEAN; (* the scanner found an error *)
    errorMessage: ARRAY 80 OF CHAR
  END;

PROCEDURE Add(VAR st: Stream; kind: INTEGER; text: OppText.Text;
              line, column: LONGINT);
  VAR it: Item;
BEGIN
  NEW(it); it.kind := kind; it.text := text; it.line := line;
  it.column := column; it.next := NIL;
  IF st.last = NIL THEN st.first := it ELSE st.last.next := it END;
  st.last := it
END Add;

PROCEDURE IsBlank(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch = " ") OR (ch = 9X) OR (ch = 0DX)
END IsBlank;

(* t with the blanks at the start and end of each line removed. *)
PROCEDURE Trim(t: OppText.Text): OppText.Text;
  VAR b: OppText.Buffer; i, j, end: LONGINT;
BEGIN
  b := OppText.NewBuffer(); i := 0;
  LOOP
    WHILE IsBlank(t[i]) DO INC(i) END;
    end := i;
    WHILE (t[end] # 0X) & (t[end] # 0AX) DO INC(end) END;
    j := end;
    WHILE (j > i) & IsBlank(t[j - 1]) DO DEC(j) END;
    WHILE i < j DO OppText.AppendChar(b, t[i]); INC(i) END;
    IF t[end] = 0X THEN EXIT END;
    OppText.AppendChar(b, 0AX); i := end + 1
  END;
  RETURN OppText.Slice(b.chars^, 0, b.len)
END Trim;

PROCEDURE AddComments(VAR st: Stream; c: S.Comment);
BEGIN
  WHILE c # NIL DO
    Add(st, commentItem, Trim(c.text), c.line, c.column); c := c.next
  END
END AddComments;

(* The items of src[0 .. len - 1] up to the period that ends the module:
   the first period that follows END and an identifier. *)
PROCEDURE Scan(src: OppText.Text; len: LONGINT; VAR st: Stream);
  VAR s: S.Scanner; t, prev: S.Token; k1, k2: INTEGER;
BEGIN
  st.first := NIL; st.last := NIL; st.rest := -1; st.error := FALSE;
  s := S.New(src, len);
  k1 := S.eof; k2 := S.eof; prev := NIL;
  LOOP
    t := S.Next(s);
    (* the comments trailing a token are known once the next is scanned *)
    IF prev # NIL THEN AddComments(st, prev.trail) END;
    AddComments(st, t.lead);
    IF t.kind = S.eof THEN EXIT END;
    Add(st, t.kind, t.text, t.line, t.column);
    IF (t.kind = S.period) & (k1 = S.ident) & (k2 = S.end) THEN
      st.rest := t.end; EXIT
    END;
    k2 := k1; k1 := t.kind; prev := t
  END;
  IF s.error THEN st.error := TRUE; COPY(s.errorMessage, st.errorMessage) END
END Scan;

PROCEDURE Same(a, b: Item): BOOLEAN;
BEGIN
  RETURN (a.kind = b.kind) & OppText.Equal(a.text, b.text)
END Same;

(* Whether src[from ..] and out[outFrom ..] are the same text, or both only
   white space. *)
PROCEDURE SameRest(src: OppText.Text; len, from: LONGINT; out: OppText.Text;
                   outLen, outFrom: LONGINT): BOOLEAN;
  VAR i: LONGINT; blank: BOOLEAN;
BEGIN
  IF len - from = outLen - outFrom THEN
    i := 0;
    WHILE (from + i < len) & (src[from + i] = out[outFrom + i]) DO INC(i) END;
    IF from + i = len THEN RETURN TRUE END
  END;
  blank := TRUE;
  FOR i := from TO len - 1 DO IF ~IsBlank(src[i]) & (src[i] # 0AX) THEN
      blank := FALSE
    END
  END;
  FOR i := outFrom TO outLen - 1 DO IF ~IsBlank(out[i]) & (out[i] # 0AX) THEN
      blank := FALSE
    END
  END;
  RETURN blank
END SameRest;

PROCEDURE Append(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i, j: LONGINT;
BEGIN
  i := 0; WHILE dst[i] # 0X DO INC(i) END;
  j := 0;
  WHILE (src[j] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := src[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END Append;

(* A description of it in msg: its text, shortened to its first line and
   40 characters, or "the end". *)
PROCEDURE Describe(it: Item; VAR msg: ARRAY OF CHAR);
  VAR s: ARRAY 48 OF CHAR; i: LONGINT;
BEGIN
  IF it = NIL THEN Append(msg, "the end")
  ELSE
    i := 0;
    WHILE (it.text[i] # 0X) & (it.text[i] # 0AX) & (i < 40) DO
      s[i] := it.text[i]; INC(i)
    END;
    s[i] := 0X;
    IF it.text[i] # 0X THEN Append(s, "...") END;
    IF it.kind = commentItem THEN Append(msg, "the comment ")
    ELSE Append(msg, "the token ")
    END;
    Append(msg, s)
  END
END Describe;

(* Whether out[0 .. outLen - 1] is a faithful formatting of src[0 ..
   len - 1]. If not, line and column give the first difference in out,
   and msg describes it. *)
PROCEDURE Check*(src: OppText.Text; len: LONGINT; out: OppText.Text;
                 outLen: LONGINT; VAR line, column: LONGINT;
                 VAR msg: ARRAY OF CHAR): BOOLEAN;
  VAR a, b: Stream; x, y: Item;
BEGIN
  msg[0] := 0X; line := 1; column := 1;
  Scan(src, len, a); Scan(out, outLen, b);
  IF b.error THEN
    Append(msg, "the output does not scan: "); Append(msg, b.errorMessage);
    RETURN FALSE
  END;
  x := a.first; y := b.first;
  LOOP
    IF (x # NIL) & (y # NIL) & Same(x, y) THEN
      x := x.next; y := y.next
    ELSIF (x # NIL) & ((x.kind = S.semicolon) OR (x.kind = S.bar)) THEN
      x := x.next
    ELSIF (x = NIL) & (y = NIL) THEN
      EXIT
    ELSE
      IF y # NIL THEN line := y.line; column := y.column
      ELSIF b.last # NIL THEN line := b.last.line; column := b.last.column
      END;
      Append(msg, "the output has "); Describe(y, msg);
      Append(msg, " where the input has "); Describe(x, msg);
      RETURN FALSE
    END
  END;
  IF (a.rest >= 0) & (b.rest >= 0)
      & ~SameRest(src, len, a.rest, out, outLen, b.rest) THEN
    IF b.last # NIL THEN line := b.last.line; column := b.last.column END;
    Append(msg, "the text after the module's end differs");
    RETURN FALSE
  END;
  RETURN TRUE
END Check;

END OppCheck.
