MODULE OppText;

(* Character text for opp: a Text is a 0X-terminated string allocated to
   fit, and a Buffer is a Text that grows as characters are appended to it.
   Lengths and positions are LONGINT, so that voc's -O2 size model, where
   INTEGER has 16 bits, can hold the length of a large source file. *)

TYPE
  Text* = POINTER TO ARRAY OF CHAR;

  Buffer* = POINTER TO BufferDesc;
  BufferDesc* = RECORD
    chars*: Text; (* chars[0 .. len - 1]; chars[len] = 0X *)
    len*: LONGINT
  END;

(* The length of s, up to its first 0X. *)
PROCEDURE Length*(VAR s: ARRAY OF CHAR): LONGINT;
  VAR n: LONGINT;
BEGIN
  n := 0;
  WHILE (n < LEN(s)) & (s[n] # 0X) DO INC(n) END;
  RETURN n
END Length;

(* A Text holding s up to its first 0X. *)
PROCEDURE New*(s: ARRAY OF CHAR): Text;
  VAR t: Text; n, i: LONGINT;
BEGIN
  n := Length(s);
  NEW(t, n + 1);
  FOR i := 0 TO n - 1 DO t[i] := s[i] END;
  t[n] := 0X;
  RETURN t
END New;

(* A Text holding s[start .. start + len - 1]. *)
PROCEDURE Slice*(VAR s: ARRAY OF CHAR; start, len: LONGINT): Text;
  VAR t: Text; i: LONGINT;
BEGIN
  NEW(t, len + 1);
  FOR i := 0 TO len - 1 DO t[i] := s[start + i] END;
  t[len] := 0X;
  RETURN t
END Slice;

PROCEDURE NewBuffer*(): Buffer;
  VAR b: Buffer;
BEGIN
  NEW(b); NEW(b.chars, 1024); b.chars[0] := 0X; b.len := 0;
  RETURN b
END NewBuffer;

PROCEDURE Grow(b: Buffer; need: LONGINT);
  VAR new: Text; size, i: LONGINT;
BEGIN
  size := LEN(b.chars^);
  IF need >= size THEN
    WHILE need >= size DO size := size * 2 END;
    NEW(new, size);
    FOR i := 0 TO b.len DO new[i] := b.chars[i] END;
    b.chars := new
  END
END Grow;

PROCEDURE AppendChar*(b: Buffer; ch: CHAR);
BEGIN
  Grow(b, b.len + 1);
  b.chars[b.len] := ch; INC(b.len); b.chars[b.len] := 0X
END AppendChar;

PROCEDURE Append*(b: Buffer; s: ARRAY OF CHAR);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO AppendChar(b, s[i]); INC(i) END
END Append;

PROCEDURE AppendText*(b: Buffer; t: Text);
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE t[i] # 0X DO AppendChar(b, t[i]); INC(i) END
END AppendText;

(* The number of columns s takes: one for each character, where the bytes
   that continue a UTF-8 sequence (80X .. 0BFX) take none. *)
PROCEDURE Width*(VAR s: ARRAY OF CHAR): LONGINT;
  VAR i, w: LONGINT;
BEGIN
  i := 0; w := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) DO
    IF (s[i] < 80X) OR (s[i] >= 0C0X) THEN INC(w) END;
    INC(i)
  END;
  RETURN w
END Width;

PROCEDURE Equal*(a, b: Text): BOOLEAN;
  VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE (a[i] # 0X) & (a[i] = b[i]) DO INC(i) END;
  RETURN a[i] = b[i]
END Equal;

END OppText.
