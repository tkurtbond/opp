MODULE OppFormat;

(* The parser of opp, which builds the document OppDoc renders.

   Recursive descent over the grammar of Oberon2.pdf, Appendix B, with
   poc's extensions and voc's (PLAN.md, "The syntax opp accepts"). There is
   no syntax tree: each procedure returns the document of what it parsed.
   Nothing here needs a symbol table, since what poc and voc tell apart by
   one (a qualident or a field, a type guard or a call) prints the same.

   Every token goes through Tok, which puts its comments around it: those
   leading it each on a line of its own, after an empty line if one came
   before it, and those trailing it after a space, with a line break after
   one that ended its line in the source. A token Drop leaves out (an empty
   statement's semicolon, an empty CASE arm's bar) hands its comments to
   the token after it.

   Statement sequences follow the statement mode (PLAN.md, "Layout rules"):
   one per line; packed, where simple statements share lines; or kept,
   where statements share a line when they shared one in the source. A
   structured statement's lines are a choice (OppDoc.NewChoice), decided
   once its END is reached.

   The first error stops the parse: the current token becomes the end of
   the text, so every loop ends, and nothing is written. *)

IMPORT OppText, S := OppScanner, D := OppDoc;

CONST
  (* statement modes *)
  onePerLine* = 0; pack* = 1; keepLines* = 2;
  (* what to do with a bar before a CASE's first arm *)
  keepBar* = 0; addBar* = 1; dropBar* = 2;
  (* whether a body's first line goes on BEGIN's line, and END on it too *)
  cuddleAllow* = 0; cuddleForce* = 1; cuddleDisallow* = 2;
  (* what to do with the spaces an author lined things up with *)
  keepAlign* = 0; dropAlign* = 1;
  (* what --align can line up: the = of constants and of types, the types
     of variables and of fields, the := of initializers, trailing
     comments, the bodies of CASE arms, and the := of assignments *)
  alignConst* = 0; alignType* = 1; alignVar* = 2; alignField* = 3;
  alignInit* = 4; alignComment* = 5; alignCase* = 6; alignAssign* = 7;

  (* what a list holds, for Element *)
  exprs = 0; braceElements = 1; caseLabels = 2;

TYPE
  Options* = RECORD
    width*, indent*: LONGINT;
    mode*: INTEGER;
    moduleIndent*: BOOLEAN;
    caseBar*: INTEGER; (* keepBar, addBar or dropBar *)
    cuddleBegin*, cuddleEnd*: INTEGER; (* cuddleAllow, cuddleForce or
                                          cuddleDisallow *)
    align*: INTEGER; (* keepAlign or dropAlign, for the spaces of what
                        lineUp and single do not hold *)
    lineUp*, single*: SET (* what opp lines up, and what it gives one
                             space *)
  END;

  Parser = POINTER TO ParserDesc;
  ParserDesc = RECORD
    s: S.Scanner;
    tok: S.Token; (* the current token *)
    last: S.Token; (* the token before it *)
    eofTok: S.Token; (* the current token after an error *)
    mode: INTEGER;
    caseBar, align: INTEGER;
    cuddleBegin, cuddleEnd: INTEGER;
    lineUp, single: SET;
    nextKind: INTEGER; (* what the space before the next token taken
                          lines up, or -1 *)
    nextRun: D.Doc; (* the run it lines up in *)
    nextAnchor: D.Doc; (* where what it is in starts, or NIL *)
    comments: D.Doc; (* the run of trailing comments *)
    assigns: D.Doc; (* the run of the current statement sequence's
                       assignments *)
    ind: LONGINT; (* the indentation step *)
    cont: LONGINT; (* the indentation of a continued line *)
    limit: LONGINT; (* the last column to align a list to *)
    error: BOOLEAN;
    errorLine, errorColumn: LONGINT;
    errorMessage: ARRAY 120 OF CHAR
  END;

  (* a statement, declaration or field list, as a sequence assembles it *)
  Item = RECORD
    lead: D.Doc; (* its leading comments and blank line, or NIL *)
    doc: D.Doc;
    simple: BOOLEAN; (* a statement that is not structured *)
    assign: BOOLEAN; (* an assignment *)
    startLine, endLine: LONGINT
  END;

  Seq = RECORD
    fill: D.FillBuilder;
    any: BOOLEAN;
    prev: Item
  END;

(* ---- Errors and tokens ---- *)

PROCEDURE Error(p: Parser; msg: ARRAY OF CHAR);
BEGIN
  IF ~p.error THEN
    p.error := TRUE; p.errorLine := p.tok.line; p.errorColumn := p.tok.column;
    COPY(msg, p.errorMessage);
    p.tok := p.eofTok
  END
END Error;

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

(* How a token of kind is named in a message: "an identifier", "MODULE",
   "':='". *)
PROCEDURE Describe(kind: INTEGER; VAR what: ARRAY OF CHAR);
  VAR name: ARRAY 40 OF CHAR;
BEGIN
  S.KindName(kind, name);
  IF (kind = S.ident) OR (kind = S.invalid) THEN COPY("an ", what)
  ELSIF (kind = S.number) OR (kind = S.string) THEN COPY("a ", what)
  ELSIF kind = S.eof THEN COPY("the ", what)
  ELSIF (kind >= S.firstKeyword) & (kind <= S.lastKeyword) THEN what[0] := 0X
  ELSE COPY("'", what)
  END;
  Append(what, name);
  IF what[0] = "'" THEN Append(what, "'") END
END Describe;

(* "expected what, found ..." at the current token *)
PROCEDURE Expected(p: Parser; what: ARRAY OF CHAR);
  VAR msg: ARRAY 120 OF CHAR; found: ARRAY 40 OF CHAR;
BEGIN
  msg := "expected "; Append(msg, what);
  Describe(p.tok.kind, found);
  Append(msg, ", found "); Append(msg, found);
  Error(p, msg)
END Expected;

PROCEDURE ExpectedKind(p: Parser; kind: INTEGER);
  VAR what: ARRAY 40 OF CHAR;
BEGIN
  Describe(kind, what); Expected(p, what)
END ExpectedKind;

PROCEDURE Advance(p: Parser);
BEGIN
  p.last := p.tok;
  IF p.error THEN
    p.tok := p.eofTok
  ELSE
    p.tok := S.Next(p.s);
    IF p.s.error THEN
      p.error := TRUE; p.errorLine := p.s.errorLine;
      p.errorColumn := p.s.errorColumn;
      COPY(p.s.errorMessage, p.errorMessage);
      p.tok := p.eofTok
    END
  END
END Advance;

(* The comments that lead a token, each on a line of its own. *)
PROCEDURE LeadDoc(c: S.Comment): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := NIL;
  WHILE c # NIL DO
    IF c.blankBefore THEN
      d := D.Cat(d, D.BlankLine())
    ELSE
      d := D.Cat(d, D.HardLine())
    END;
    d := D.Cat(d, D.Comment(c.text, c.column));
    c := c.next
  END;
  RETURN d
END LeadDoc;

(* The spaces of a gap of n columns in the source, kept as the author's
   alignment unless --align drop. *)
PROCEDURE Gap(p: Parser; n: LONGINT): D.Doc;
BEGIN
  IF (p.align = keepAlign) & (n > 1) THEN RETURN D.Widen(n) END;
  RETURN NIL
END Gap;

(* The spaces of a gap of n columns before something of kind, lined up in
   run if --align says so. *)
PROCEDURE KindGap(p: Parser; kind: INTEGER; run: D.Doc; n: LONGINT): D.Doc;
BEGIN
  IF kind IN p.single THEN RETURN NIL
  ELSIF ~(kind IN p.lineUp) THEN RETURN Gap(p, n)
  ELSIF p.align = keepAlign THEN RETURN D.Pad(run, n)
  END;
  RETURN D.Pad(run, 0)
END KindGap;

(* The space before the next token taken is one of kind, in run. *)
PROCEDURE Mark(p: Parser; kind: INTEGER; run: D.Doc);
BEGIN
  p.nextKind := kind; p.nextRun := run; p.nextAnchor := NIL
END Mark;

(* The current token with its comments, which it consumes. item says that
   it starts a statement, declaration or other item, where a blank line
   before it is kept. *)

PROCEDURE TokItem(p: Parser; item: BOOLEAN): D.Doc;
  VAR t: S.Token; d, g: D.Doc; c: S.Comment;
BEGIN
  t := p.tok;
  IF t = p.eofTok THEN RETURN D.Empty() END;
  Advance(p);
  d := LeadDoc(t.lead);
  IF item & t.blankBefore THEN
    d := D.Cat(d, D.BlankLine())
  ELSIF t.lead # NIL THEN
    d := D.Cat(d, D.HardLine())
  END;
  IF p.nextKind >= 0 THEN
    g := KindGap(p, p.nextKind, p.nextRun, t.gap);
    IF (g # NIL) & (p.nextAnchor # NIL) THEN D.SetAnchor(g, p.nextAnchor) END;
    d := D.Cat(d, g);
    p.nextKind := -1; p.nextAnchor := NIL
  ELSE
    d := D.Cat(d, Gap(p, t.gap))
  END;
  d := D.Cat(d, D.TextOf(t.text));
  c := t.trail;
  WHILE c # NIL DO
    d := D.Cat(d, D.Space());
    IF c = t.trail THEN
      d := D.Cat(d, KindGap(p, alignComment, p.comments, c.gap))
    ELSE
      d := D.Cat(d, Gap(p, c.gap))
    END;
    d := D.Cat(d, D.Comment(c.text, c.column));
    IF c.newlineAfter THEN d := D.Cat(d, D.TrailBreak()) END;
    c := c.next
  END;
  RETURN d
END TokItem;

PROCEDURE Tok(p: Parser): D.Doc;
BEGIN
  RETURN TokItem(p, FALSE)
END Tok;

(* The comments leading the current token, and a blank line before it,
   taken from it: what goes before an item that starts with it, outside
   the item's groups, which could not be flat with a line break inside. *)
PROCEDURE ItemLead(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := LeadDoc(p.tok.lead);
  IF p.tok.blankBefore THEN d := D.Cat(d, D.BlankLine())
  ELSIF p.tok.lead # NIL THEN d := D.Cat(d, D.HardLine())
  END;
  p.tok.lead := NIL; p.tok.blankBefore := FALSE;
  RETURN d
END ItemLead;

(* The current token, which must be of kind; an error otherwise. *)
PROCEDURE Expect(p: Parser; kind: INTEGER): D.Doc;
BEGIN
  IF p.tok.kind # kind THEN ExpectedKind(p, kind); RETURN D.Empty() END;
  RETURN Tok(p)
END Expect;

(* Expect for a token that starts an item, as TokItem. *)
PROCEDURE ExpectItem(p: Parser; kind: INTEGER): D.Doc;
BEGIN
  IF p.tok.kind # kind THEN ExpectedKind(p, kind); RETURN D.Empty() END;
  RETURN TokItem(p, TRUE)
END ExpectItem;

(* Leaves the current token out, handing its comments, and a blank line
   before it, to the next token. *)
PROCEDURE Drop(p: Parser);
  VAR t: S.Token; c, tail: S.Comment;
BEGIN
  t := p.tok; Advance(p);
  IF p.tok # p.eofTok THEN
    IF t.blankBefore THEN p.tok.blankBefore := TRUE END;
    IF (t.lead # NIL) OR (t.trail # NIL) THEN
      tail := NIL; c := t.lead;
      WHILE c # NIL DO tail := c; c := c.next END;
      IF tail = NIL THEN t.lead := t.trail ELSE tail.next := t.trail END;
      tail := NIL; c := t.lead;
      WHILE c # NIL DO tail := c; c := c.next END;
      tail.next := p.tok.lead; p.tok.lead := t.lead;
      IF t.trail # NIL THEN t.trail.blankBefore := FALSE END
    END
  END
END Drop;

(* The comments leading the current token, taken from it, so they can go
   at the end of the body it closes, at the body's indentation. *)
PROCEDURE TakeLead(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := LeadDoc(p.tok.lead); p.tok.lead := NIL;
  RETURN d
END TakeLead;

(* The kind of the token after the current one. *)
PROCEDURE PeekKind(p: Parser): INTEGER;
  VAR t: S.Token;
BEGIN
  IF p.error THEN RETURN S.eof END;
  t := S.Peek(p.s);
  RETURN t.kind
END PeekKind;

PROCEDURE Is(p: Parser; kind: INTEGER): BOOLEAN;
BEGIN
  RETURN p.tok.kind = kind
END Is;

(* ---- Sequences ---- *)

PROCEDURE InitSeq(VAR q: Seq);
BEGIN
  D.InitFill(q.fill); q.any := FALSE
END InitSeq;

(* Appends it to q: after a line break, or, as the mode allows, on the
   line of the item before. An item with leading comments or a blank line
   before it starts a line; they come before the line the fill measures it
   from (D.AddLead). *)
PROCEDURE AddItem(p: Parser; VAR q: Seq; VAR it: Item; packable: BOOLEAN);
  VAR share: BOOLEAN;
BEGIN
  IF q.any THEN
    CASE p.mode OF
      onePerLine: share := FALSE
    | pack: share := packable & q.prev.simple & it.simple
    | keepLines: share := it.startLine = q.prev.endLine
    END;
    IF share & (it.lead = NIL) THEN D.Sep(q.fill) ELSE D.Break(q.fill) END
  END;
  IF it.lead # NIL THEN D.AddLead(q.fill, it.lead) END;
  D.Add(q.fill, it.doc);
  q.prev := it; q.any := TRUE
END AddItem;

PROCEDURE SeqDoc(VAR q: Seq): D.Doc;
BEGIN
  IF q.any THEN RETURN D.Fill(q.fill) ELSE RETURN NIL END
END SeqDoc;

(* A choice for a structured statement that started on startLine and has
   just ended: hard in one-per-line mode; in kept mode, hard unless it was
   on one line. *)
PROCEDURE Lines(p: Parser; c: D.Doc; startLine: LONGINT);
BEGIN
  CASE p.mode OF
    onePerLine: D.Decide(c, TRUE)
  | pack: D.Decide(c, FALSE)
  | keepLines: D.Decide(c, startLine # p.last.endLine)
  END
END Lines;

(* d := d followed by x. An expression makes at most one parsing call,
   because the order in which an expression's calls are made is not
   defined, and the C compiler voc uses makes them in any order. *)
PROCEDURE Put(VAR d: D.Doc; x: D.Doc);
BEGIN
  d := D.Cat(d, x)
END Put;

PROCEDURE ^ Expr(p: Parser): D.Doc;
PROCEDURE ^ Type(p: Parser): D.Doc;
PROCEDURE ^ StatementSeq(p: Parser): D.Doc;
PROCEDURE ^ DeclSeq(p: Parser; VAR procs: BOOLEAN): D.Doc;

(* A statement sequence, then the comments leading the keyword that closes
   it, at its indentation; but comments leading a bar stay with the bar,
   before the CASE arm or WITH guard they describe. *)
PROCEDURE BodySeq(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := StatementSeq(p);
  IF Is(p, S.bar) THEN RETURN d END;
  RETURN D.Cat(d, TakeLead(p))
END BodySeq;

(* The body at the current token: Nest(ind, line body), the line the
   choice c's, or nothing when the body is empty. With --keep-lines, a body
   the source has on its keyword's line stays there while it fits when the
   source breaks the statement (c is hard). *)
PROCEDURE Body(p: Parser; c: D.Doc): D.Doc;
  VAR body, br: D.Doc; same: BOOLEAN;
BEGIN
  same := p.tok.line = p.last.endLine;
  body := BodySeq(p);
  IF body = NIL THEN RETURN NIL END;
  IF (p.mode = keepLines) & same THEN br := D.KeptLine(c)
  ELSE br := D.ChoiceLine(c)
  END;
  RETURN D.Nest(p.ind, D.Cat(br, body))
END Body;

(* ---- Lists ---- *)

PROCEDURE ^ Element(p: Parser; kind: INTEGER): D.Doc;

(* elem {"," elem}, filling lines, each comma after its element. *)
PROCEDURE ListFill(p: Parser; kind: INTEGER): D.Doc;
  VAR f: D.FillBuilder;
BEGIN
  D.InitFill(f);
  D.Add(f, Element(p, kind));
  WHILE Is(p, S.comma) DO
    D.Add(f, Tok(p)); D.Sep(f);
    D.Add(f, Element(p, kind))
  END;
  RETURN D.Fill(f)
END ListFill;

(* open list close, the list aligned after open, or nested when that is
   too far right: (a, b), [i, j], {x, y}. open is inside the nest, so a
   comment that ends its line continues the list indented. *)
PROCEDURE Bracketed(p: Parser; close, kind: INTEGER): D.Doc;
  VAR d, list: D.Doc;
BEGIN
  d := Tok(p);
  IF ~Is(p, close) THEN
    list := ListFill(p, kind);
    d := D.Nest(p.cont,
                D.Cat3(d, D.SoftBreak(list), D.AlignOrNest(0, p.limit, list)))
  END;
  RETURN D.Cat(d, Expect(p, close))
END Bracketed;

(* ---- Expressions ---- *)

PROCEDURE Qualident(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := Expect(p, S.ident);
  IF Is(p, S.period) THEN Put(d, Tok(p)); Put(d, Expect(p, S.ident)) END;
  RETURN d
END Qualident;

(* ident {"." ident | "[" ExprList "]" | "^" | "(" [ExprList] ")"}: a call's
   arguments and a type guard alike. *)
PROCEDURE Designator(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := Expect(p, S.ident);
  LOOP
    IF Is(p, S.period) THEN Put(d, Tok(p)); Put(d, Expect(p, S.ident))
    ELSIF Is(p, S.lbrak) THEN d := D.Cat(d, Bracketed(p, S.rbrak, exprs))
    ELSIF Is(p, S.arrow) THEN d := D.Cat(d, Tok(p))
    ELSIF Is(p, S.lparen) THEN d := D.Cat(d, Bracketed(p, S.rparen, exprs))
    ELSE EXIT
    END
  END;
  RETURN d
END Designator;

(* "{" [element {"," element}] "}": a set, or poc's record or array
   literal's elements. *)
PROCEDURE Braces(p: Parser): D.Doc;
BEGIN
  RETURN Bracketed(p, S.rbrace, braceElements)
END Braces;

PROCEDURE Factor(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  CASE p.tok.kind OF
    S.ident:
      d := Designator(p);
      IF Is(p, S.lbrace) THEN d := D.Cat(d, Braces(p)) END
  | S.number, S.string, S.nil: d := Tok(p)
  | S.lbrace: d := Braces(p)
  | S.lparen: d := Tok(p); Put(d, D.Align(Expr(p))); Put(d, Expect(p, S.rparen))
  | S.tilde: d := Tok(p); d := D.Cat(d, Factor(p))
  ELSE
    Expected(p, "an expression"); d := D.Empty()
  END;
  RETURN d
END Factor;

PROCEDURE IsMulOp(kind: INTEGER): BOOLEAN;
BEGIN
  RETURN (kind = S.times) OR (kind = S.slash) OR (kind = S.div)
      OR (kind = S.mod) OR (kind = S.ampersand)
END IsMulOp;

PROCEDURE IsAddOp(kind: INTEGER): BOOLEAN;
BEGIN
  RETURN (kind = S.plus) OR (kind = S.minus) OR (kind = S.or)
END IsAddOp;

PROCEDURE IsRelation(kind: INTEGER): BOOLEAN;
BEGIN
  RETURN (kind >= S.eql) & (kind <= S.geq) OR (kind = S.in) OR (kind = S.is)
END IsRelation;

(* Factor {MulOp Factor}: a fill, breaking before an operator. *)
PROCEDURE Term(p: Parser): D.Doc;
  VAR f: D.FillBuilder; first: D.Doc;
BEGIN
  first := Factor(p);
  IF ~IsMulOp(p.tok.kind) THEN RETURN first END;
  D.InitFill(f); D.Add(f, first);
  WHILE IsMulOp(p.tok.kind) DO
    D.Sep(f); D.Add(f, Tok(p)); D.Add(f, D.Space()); D.Add(f, Factor(p))
  END;
  RETURN D.Nest(p.cont, D.Fill(f))
END Term;

(* ["+" | "-"] Term {AddOp Term} *)
PROCEDURE SimpleExpr(p: Parser): D.Doc;
  VAR f: D.FillBuilder; first: D.Doc;
BEGIN
  first := NIL;
  IF Is(p, S.plus) OR Is(p, S.minus) THEN first := Tok(p) END;
  first := D.Cat(first, Term(p));
  IF ~IsAddOp(p.tok.kind) THEN RETURN first END;
  D.InitFill(f); D.Add(f, first);
  WHILE IsAddOp(p.tok.kind) DO
    D.Sep(f); D.Add(f, Tok(p)); D.Add(f, D.Space()); D.Add(f, Term(p))
  END;
  RETURN D.Nest(p.cont, D.Fill(f))
END SimpleExpr;

(* SimpleExpr [Relation SimpleExpr] *)
PROCEDURE Expr(p: Parser): D.Doc;
  VAR d, rel: D.Doc;
BEGIN
  d := SimpleExpr(p);
  IF IsRelation(p.tok.kind) THEN
    rel := D.Cat(D.Line(), Tok(p)); Put(rel, D.Space());
    Put(rel, SimpleExpr(p));
    d := D.Group(D.Cat(d, D.Nest(p.cont, rel)))
  END;
  RETURN d
END Expr;

(* An element of a list: an expression; a set's or a literal's element,
   "[" labels "]" ":" expression, ident ":=" expression, or expression
   [".." expression]; a CASE label, expression [".." expression]. *)
PROCEDURE Element(p: Parser; kind: INTEGER): D.Doc;
  VAR d: D.Doc;
BEGIN
  IF kind = exprs THEN RETURN Expr(p) END;
  d := NIL;
  IF kind = braceElements THEN
    IF Is(p, S.lbrak) THEN
      d := Bracketed(p, S.rbrak, caseLabels); Put(d, Expect(p, S.colon));
      Put(d, D.Space())
    ELSIF Is(p, S.ident) & (PeekKind(p) = S.becomes) THEN
      d := Tok(p); Put(d, D.Space()); Put(d, Tok(p)); Put(d, D.Space())
    END
  END;
  d := D.Cat(d, Expr(p));
  IF Is(p, S.upto) THEN Put(d, Tok(p)); Put(d, Expr(p)) END;
  RETURN d
END Element;

(* ---- Types ---- *)

(* voc's system flag, "[" ConstExpr "]", after ARRAY, RECORD, POINTER or
   PROCEDURE *)
PROCEDURE SysFlag(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  IF Is(p, S.lbrak) THEN
    d := D.Cat(D.Space(), Tok(p)); Put(d, Expr(p)); Put(d, Expect(p, S.rbrak));
    RETURN d
  END;
  RETURN NIL
END SysFlag;

(* ident ["*" | "-"] *)
PROCEDURE IdentDef(p: Parser; item: BOOLEAN): D.Doc;
  VAR d: D.Doc;
BEGIN
  IF ~Is(p, S.ident) THEN ExpectedKind(p, S.ident); RETURN D.Empty() END;
  d := TokItem(p, item);
  IF Is(p, S.times) OR Is(p, S.minus) THEN d := D.Cat(d, Tok(p)) END;
  RETURN d
END IdentDef;

(* IdentDef {"," IdentDef}, filling lines *)
PROCEDURE IdentList(p: Parser; item: BOOLEAN): D.Doc;
  VAR f: D.FillBuilder;
BEGIN
  D.InitFill(f);
  D.Add(f, IdentDef(p, item));
  WHILE Is(p, S.comma) DO
    D.Add(f, Tok(p)); D.Sep(f); D.Add(f, IdentDef(p, FALSE))
  END;
  RETURN D.Fill(f)
END IdentList;

(* [VAR] ident ["-" | "*"] {"," ...} ":" Type *)
PROCEDURE FPSection(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := NIL;
  IF Is(p, S.var) THEN d := D.Cat(Tok(p), D.Space()) END;
  d := D.Cat(d, IdentList(p, FALSE));
  Put(d, Expect(p, S.colon)); Put(d, D.Space()); Put(d, Type(p));
  RETURN d
END FPSection;

(* "(" [FPSection {";" FPSection}] ")" [":" Qualident], the sections
   filling lines aligned after "(" *)
PROCEDURE FormalPars(p: Parser): D.Doc;
  VAR d: D.Doc; f: D.FillBuilder;
BEGIN
  d := Tok(p);
  IF ~Is(p, S.rparen) THEN
    D.InitFill(f);
    D.Add(f, FPSection(p));
    WHILE Is(p, S.semicolon) DO
      D.Add(f, Tok(p)); D.Sep(f); D.Add(f, FPSection(p))
    END;
    d := D.Nest(p.cont,
        D.Cat3(d, D.SoftBreak(D.Fill(f)), D.AlignOrNest(0, p.limit, D.Fill(f))))
  END;
  d := D.Cat(d, Expect(p, S.rparen));
  IF Is(p, S.colon) THEN
    Put(d, Tok(p)); Put(d, D.Space()); Put(d, Qualident(p))
  END;
  RETURN d
END FormalPars;

(* [IdentList ":" Type [":=" Expr]], its type lined up in types, its
   initializer in inits *)
PROCEDURE FieldList(p: Parser; types, inits: D.Doc): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := IdentList(p, TRUE);
  Put(d, Expect(p, S.colon)); Put(d, D.Space());
  Mark(p, alignField, types); Put(d, Type(p));
  IF Is(p, S.becomes) THEN
    Mark(p, alignInit, inits);
    d := D.Cat3(d, D.Space(), Tok(p)); d := D.Cat3(d, D.Space(), Expr(p))
  END;
  RETURN d
END FieldList;

(* RECORD [flag] ["(" Qualident ")"] FieldList {";" FieldList} END: one
   field list to a line, nested from the line the record starts on. An
   empty field list's semicolon is dropped, but one before END is kept. *)
PROCEDURE RecordType(p: Parser): D.Doc;
  VAR d, fields, lead, types, inits: D.Doc; f: D.FillBuilder; any: BOOLEAN;
BEGIN
  d := Tok(p); Put(d, SysFlag(p));
  types := D.NewRun(FALSE); inits := D.NewRun(FALSE);
  IF Is(p, S.lparen) THEN
    Put(d, D.Space()); Put(d, Tok(p)); Put(d, Qualident(p));
    Put(d, Expect(p, S.rparen))
  END;
  D.InitFill(f); any := FALSE;
  LOOP
    IF Is(p, S.ident) THEN
      IF any THEN D.Break(f) END;
      IF p.tok.blankBefore THEN (* a blank line ends a run *)
        types := D.NewRun(FALSE); inits := D.NewRun(FALSE)
      END;
      D.Add(f, FieldList(p, types, inits)); any := TRUE;
      IF Is(p, S.semicolon) THEN D.Add(f, Tok(p)) ELSE EXIT END
    ELSIF Is(p, S.semicolon) THEN
      Drop(p)
    ELSE
      EXIT
    END
  END;
  lead := TakeLead(p);
  fields := NIL;
  IF any THEN fields := D.Fill(f) END;
  fields := D.Cat(fields, lead);
  IF fields # NIL THEN
    d := D.Cat(d, D.Nest(p.ind, D.Cat(D.HardLine(), fields)));
    d := D.Cat(d, D.HardLine())
  ELSE
    d := D.Cat(d, D.Space())
  END;
  RETURN D.Cat(d, Expect(p, S.end))
END RecordType;

PROCEDURE Type(p: Parser): D.Doc;
  VAR d: D.Doc; f: D.FillBuilder;
BEGIN
  CASE p.tok.kind OF
    S.ident: d := Qualident(p)
  | S.array:
      d := Tok(p); Put(d, SysFlag(p));
      IF ~Is(p, S.of) THEN
        D.InitFill(f); D.Add(f, Expr(p));
        WHILE Is(p, S.comma) DO
          D.Add(f, Tok(p)); D.Sep(f); D.Add(f, Expr(p))
        END;
        d := D.Cat3(d, D.Space(), D.Fill(f))
      END;
      d := D.Cat3(d, D.Space(), Expect(p, S.of));
      d := D.Cat3(d, D.Space(), Type(p))
  | S.record: d := RecordType(p)
  | S.pointer:
      d := Tok(p); Put(d, SysFlag(p));
      d := D.Cat3(d, D.Space(), Expect(p, S.to));
      d := D.Cat3(d, D.Space(), Type(p))
  | S.procedure:
      d := Tok(p); Put(d, SysFlag(p));
      IF Is(p, S.lparen) THEN d := D.Cat3(d, D.Space(), FormalPars(p)) END
  ELSE
    Expected(p, "a type"); d := D.Empty()
  END;
  RETURN d
END Type;

(* ---- Statements ---- *)

(* CaseLabels {"," CaseLabels} ":" StatementSeq, the body on the labels'
   line when it fits, else nested below them; NIL for an empty arm. *)
(* The line break before the body of a CASE arm or its ELSE, at the
   current token: one that a body that fits does not take, unless with
   --keep-lines the source has the body on a line after the label's. *)
PROCEDURE BodyBreak(p: Parser): D.Doc;
BEGIN
  IF (p.mode = keepLines) & (p.tok.line # p.last.endLine) THEN
    RETURN D.HardLine()
  END;
  RETURN D.Line()
END BodyBreak;

(* An arm, its body lined up in run when on the labels' line *)
PROCEDURE CaseArm(p: Parser; run: D.Doc): D.Doc;
  VAR d, body, br: D.Doc;
BEGIN
  IF Is(p, S.bar) OR Is(p, S.else) OR Is(p, S.end) THEN RETURN NIL END;
  d := ListFill(p, caseLabels); Put(d, Expect(p, S.colon));
  br := BodyBreak(p);
  IF ~Is(p, S.bar) & ~Is(p, S.else) & ~Is(p, S.end) THEN
    Mark(p, alignCase, run)
  END;
  body := BodySeq(p);
  p.nextKind := -1; (* a body of empty statements took no token *)
  IF body # NIL THEN d := D.Group(D.Cat(d, D.Nest(p.ind, D.Cat(br, body)))) END;
  RETURN d
END CaseArm;

(* The padding after a bar, so what follows it lines up with the first
   arm, nested ind after the bar. *)
PROCEDURE BarPad(p: Parser): D.Doc;
  VAR d: D.Doc; i: LONGINT;
BEGIN
  d := D.Space();
  FOR i := 3 TO p.ind DO d := D.Cat(d, D.Space()) END;
  RETURN d
END BarPad;

(* CASE Expr OF arm {"|" arm} [ELSE StatementSeq] END; always broken *)
PROCEDURE CaseStatement(p: Parser): D.Doc;
  VAR
    d, arm, arms, body, br, lead: D.Doc; bar, run: D.Doc; k: INTEGER;
    added: BOOLEAN;
BEGIN
  run := D.NewRun(FALSE);
  d := Tok(p);
  d := D.Cat3(d, D.Space(), Expr(p));
  d := D.Cat3(d, D.Space(), Expect(p, S.of));
  (* the bar before the first arm, as written, added or dropped *)
  arms := NIL; lead := NIL; added := FALSE;
  IF Is(p, S.bar) THEN
    IF p.caseBar = dropBar THEN Drop(p) ELSE lead := TokItem(p, TRUE) END
  ELSIF p.caseBar = addBar THEN
    lead := D.TextOf(OppText.New("|")); added := TRUE
  END;
  arm := CaseArm(p, run);
  WHILE (arm = NIL) & Is(p, S.bar) DO (* empty arms *)
    Drop(p); arm := CaseArm(p, run)
  END;
  IF arm = NIL THEN
    IF (lead # NIL) & ~added THEN arms := D.Cat(D.HardLine(), lead) END
  ELSIF lead = NIL THEN
    arms := D.Nest(p.ind, D.Cat(D.HardLine(), arm))
  ELSE
    arms := D.Cat3(D.HardLine(), lead, D.Cat(BarPad(p), D.Nest(p.ind, arm)))
  END;
  WHILE Is(p, S.bar) DO
    k := PeekKind(p);
    IF (arms = NIL) OR (k = S.bar) OR (k = S.else) OR (k = S.end) THEN
      Drop(p); arm := CaseArm(p, run);
      IF arm # NIL THEN
        arms := D.Cat(arms, D.Nest(p.ind, D.Cat(D.HardLine(), arm)))
      END
    ELSE
      IF p.tok.blankBefore THEN run := D.NewRun(FALSE) END;
      bar := TokItem(p, TRUE);
      arm := CaseArm(p, run);
      arms := D.Cat(arms,
          D.Cat3(D.HardLine(), bar, D.Cat(BarPad(p), D.Nest(p.ind, arm))))
    END
  END;
  d := D.Cat(d, arms);
  IF Is(p, S.else) THEN
    IF p.tok.blankBefore THEN run := D.NewRun(FALSE) END;
    d := D.Cat3(d, D.HardLine(), TokItem(p, TRUE));
    br := BodyBreak(p);
    IF ~Is(p, S.end) THEN Mark(p, alignCase, run) END;
    body := BodySeq(p);
    p.nextKind := -1;
    IF body # NIL THEN d := D.Cat(d, D.Group(D.Nest(p.ind, D.Cat(br, body))))
    END
  ELSE
    d := D.Cat(d, D.Nest(p.ind, TakeLead(p)))
  END;
  RETURN D.Cat3(d, D.HardLine(), ExpectItem(p, S.end))
END CaseStatement;

(* Qualident ":" Qualident DO, a WITH's guard *)
PROCEDURE Guard(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := Qualident(p); Put(d, Expect(p, S.colon)); Put(d, D.Space());
  d := D.Cat3(d, Qualident(p), D.Space());
  RETURN D.Cat(d, Expect(p, S.do))
END Guard;

(* WITH Guard DO StatementSeq {"|" Guard DO StatementSeq}
   [ELSE StatementSeq] END: like WHILE with one guard, else always
   broken *)
PROCEDURE WithStatement(p: Parser; startLine: LONGINT): D.Doc;
  VAR d: D.Doc; c: D.Doc; many: BOOLEAN;
BEGIN
  c := D.NewChoice(); many := FALSE;
  d := Tok(p); Put(d, D.Space()); Put(d, Guard(p));
  d := D.Cat(d, Body(p, c));
  WHILE Is(p, S.bar) DO
    many := TRUE;
    d := D.Cat3(d, D.ChoiceLine(c), TokItem(p, TRUE));
    d := D.Cat3(d, D.Space(), Guard(p));
    d := D.Cat(d, Body(p, c))
  END;
  IF Is(p, S.else) THEN
    many := TRUE;
    d := D.Cat3(d, D.ChoiceLine(c), TokItem(p, TRUE));
    d := D.Cat(d, Body(p, c))
  END;
  d := D.Cat3(d, D.ChoiceLine(c), Expect(p, S.end));
  Lines(p, c, startLine);
  IF many THEN D.Decide(c, TRUE) END;
  RETURN D.Group(d)
END WithStatement;

(* IF Expr THEN StatementSeq {ELSIF Expr THEN StatementSeq}
   [ELSE StatementSeq] END *)
PROCEDURE IfStatement(p: Parser; startLine: LONGINT): D.Doc;
  VAR d, c: D.Doc;
BEGIN
  c := D.NewChoice();
  d := Tok(p); Put(d, D.Space()); Put(d, Expr(p));
  d := D.Cat3(d, D.Space(), Expect(p, S.then));
  d := D.Cat(d, Body(p, c));
  WHILE Is(p, S.elsif) DO
    d := D.Cat3(d, D.ChoiceLine(c), TokItem(p, TRUE));
    d := D.Cat3(d, D.Space(), Expr(p));
    d := D.Cat3(d, D.Space(), Expect(p, S.then));
    d := D.Cat(d, Body(p, c))
  END;
  IF Is(p, S.else) THEN
    d := D.Cat3(d, D.ChoiceLine(c), TokItem(p, TRUE));
    d := D.Cat(d, Body(p, c))
  END;
  d := D.Cat3(d, D.ChoiceLine(c), Expect(p, S.end));
  Lines(p, c, startLine);
  RETURN D.Group(d)
END IfStatement;

PROCEDURE Statement(p: Parser; VAR it: Item);
  VAR d, c, pre, a: D.Doc; start: LONGINT;
BEGIN
  start := p.tok.line; it.startLine := start; it.simple := TRUE;
  it.assign := FALSE;
  pre := ItemLead(p);
  CASE p.tok.kind OF
    S.ident:
      a := D.Anchor();
      d := D.Cat(a, Tok(p));
      (* the rest of a designator, as Designator *)
      LOOP
        IF Is(p, S.period) THEN Put(d, Tok(p)); Put(d, Expect(p, S.ident))
        ELSIF Is(p, S.lbrak) THEN d := D.Cat(d, Bracketed(p, S.rbrak, exprs))
        ELSIF Is(p, S.arrow) THEN d := D.Cat(d, Tok(p))
        ELSIF Is(p, S.lparen) THEN d := D.Cat(d, Bracketed(p, S.rparen, exprs))
        ELSE EXIT
        END
      END;
      IF Is(p, S.becomes) THEN
        it.assign := TRUE; Mark(p, alignAssign, p.assigns);
        p.nextAnchor := a;
        d := D.Cat3(d, D.Space(), Tok(p)); d := D.Cat3(d, D.Space(), Expr(p))
      END
  | S.if: it.simple := FALSE; d := IfStatement(p, start)
  | S.case: it.simple := FALSE; d := CaseStatement(p)
  | S.while:
      it.simple := FALSE; c := D.NewChoice();
      d := Tok(p); Put(d, D.Space()); Put(d, Expr(p));
      d := D.Cat3(d, D.Space(), Expect(p, S.do));
      d := D.Cat(d, Body(p, c));
      d := D.Group(D.Cat3(d, D.ChoiceLine(c), Expect(p, S.end)));
      Lines(p, c, start)
  | S.repeat:
      it.simple := FALSE; c := D.NewChoice();
      d := Tok(p);
      d := D.Cat(d, Body(p, c));
      d := D.Cat3(d, D.ChoiceLine(c), Expect(p, S.until));
      d := D.Group(D.Cat3(d, D.Space(), Expr(p)));
      Lines(p, c, start)
  | S.for:
      it.simple := FALSE; c := D.NewChoice();
      d := Tok(p); Put(d, D.Space()); Put(d, Expect(p, S.ident));
      d := D.Cat3(d, D.Space(), Expect(p, S.becomes));
      d := D.Cat3(d, D.Space(), Expr(p));
      d := D.Cat3(d, D.Space(), Expect(p, S.to));
      d := D.Cat3(d, D.Space(), Expr(p));
      IF Is(p, S.by) THEN
        d := D.Cat3(d, D.Space(), Tok(p)); d := D.Cat3(d, D.Space(), Expr(p))
      END;
      d := D.Cat3(d, D.Space(), Expect(p, S.do));
      d := D.Cat(d, Body(p, c));
      d := D.Group(D.Cat3(d, D.ChoiceLine(c), Expect(p, S.end)));
      Lines(p, c, start)
  | S.loop:
      it.simple := FALSE; c := D.NewChoice();
      d := Tok(p);
      d := D.Cat(d, Body(p, c));
      d := D.Group(D.Cat3(d, D.ChoiceLine(c), Expect(p, S.end)));
      Lines(p, c, start)
  | S.with: it.simple := FALSE; d := WithStatement(p, start)
  | S.exit: d := Tok(p)
  | S.return:
      d := Tok(p);
      IF ~Is(p, S.semicolon) & ~Is(p, S.end) & ~Is(p, S.else) & ~Is(p, S.elsif)
          & ~Is(p, S.until) & ~Is(p, S.bar) & ~Is(p, S.eof) THEN
        d := D.Cat3(d, D.Space(), Expr(p))
      END
  END;
  it.lead := pre; it.doc := d
END Statement;

PROCEDURE StartsStatement(kind: INTEGER): BOOLEAN;
BEGIN
  RETURN (kind = S.ident) OR (kind = S.if) OR (kind = S.case)
      OR (kind = S.while) OR (kind = S.repeat) OR (kind = S.for)
      OR (kind = S.loop) OR (kind = S.with) OR (kind = S.exit)
      OR (kind = S.return)
END StartsStatement;

(* Statement {";" Statement}, or NIL when it has no statements. An empty
   statement's semicolon is dropped; the one after the last statement is
   kept. *)
PROCEDURE StatementSeq(p: Parser): D.Doc;
  VAR q: Seq; it: Item; outer: D.Doc;
BEGIN
  InitSeq(q);
  (* runs of assignments: up to a blank line or another statement *)
  outer := p.assigns; p.assigns := D.NewRun(FALSE);
  LOOP
    IF StartsStatement(p.tok.kind) THEN
      IF p.tok.blankBefore THEN p.assigns := D.NewRun(FALSE) END;
      Statement(p, it);
      IF ~it.assign THEN p.assigns := D.NewRun(FALSE) END;
      IF Is(p, S.semicolon) THEN it.doc := D.Cat(it.doc, Tok(p)) END;
      it.endLine := p.last.endLine;
      AddItem(p, q, it, TRUE);
      IF p.last.kind # S.semicolon THEN EXIT END
    ELSIF Is(p, S.semicolon) THEN
      Drop(p)
    ELSE
      EXIT
    END
  END;
  p.assigns := outer;
  RETURN SeqDoc(q)
END StatementSeq;

(* ---- Declarations ---- *)

(* A CONST, TYPE or VAR section: the keyword, then its declarations, each
   ended by a semicolon. One declaration that fits goes on the keyword's
   line; --pack fills lines with them, on the keyword's line if they all
   fit; --keep-lines keeps them where the source has them, and on the
   keyword's line only if they all are, and fit. *)
PROCEDURE Section(p: Parser): D.Doc;
  VAR
    kw, d, pre, run, inits: D.Doc; q: Seq; it: Item; kind, n: INTEGER;
    kwLine, firstLine: LONGINT;
BEGIN
  kind := p.tok.kind; kwLine := p.tok.line;
  pre := ItemLead(p);
  kw := Tok(p);
  InitSeq(q); n := 0; firstLine := p.tok.line;
  run := D.NewRun(FALSE); inits := D.NewRun(FALSE);
  WHILE Is(p, S.ident) DO
    it.startLine := p.tok.line; it.simple := TRUE;
    IF p.tok.blankBefore THEN (* a blank line ends a run *)
      run := D.NewRun(FALSE); inits := D.NewRun(FALSE)
    END;
    it.lead := ItemLead(p);
    IF kind = S.var THEN
      d := IdentList(p, TRUE); Put(d, Expect(p, S.colon));
      Mark(p, alignVar, run);
      d := D.Cat3(d, D.Space(), Type(p));
      IF Is(p, S.becomes) THEN
        Mark(p, alignInit, inits);
        d := D.Cat3(d, D.Space(), Tok(p)); d := D.Cat3(d, D.Space(), Expr(p))
      END
    ELSE
      d := IdentDef(p, TRUE);
      IF kind = S.const THEN Mark(p, alignConst, run)
      ELSE Mark(p, alignType, run)
      END;
      d := D.Cat3(d, D.Space(), Expect(p, S.eql));
      IF kind = S.const THEN d := D.Cat3(d, D.Space(), Expr(p))
      ELSE d := D.Cat3(d, D.Space(), Type(p))
      END
    END;
    it.doc := D.Cat(d, Expect(p, S.semicolon));
    it.endLine := p.last.endLine;
    AddItem(p, q, it, TRUE); INC(n)
  END;
  d := SeqDoc(q);
  IF d = NIL THEN
    d := kw
  ELSIF (n = 1) & (p.mode # keepLines) OR (p.mode = pack)
      OR (p.mode = keepLines) & (firstLine = kwLine) THEN
    (* on the keyword's line if they all fit there; with --keep-lines, only
       if the first one was there *)
    d := D.Group(D.Cat(kw, D.Nest(p.ind, D.Cat(D.Line(), d))))
  ELSE
    d := D.Cat(kw, D.Nest(p.ind, D.Cat(D.HardLine(), d)))
  END;
  RETURN D.Cat(pre, d)
END Section;

(* The line break after BEGIN, at the first token of the body. cuddled
   says whether the body's first line goes on BEGIN's line, as BEGIN
   RETURN x, as --cuddle-begin says: always, where the source has it there,
   or never; then the break is taken unless the first statement, all on
   one line, fits there. *)
PROCEDURE BeginBreak(p: Parser; VAR cuddled: BOOLEAN): D.Doc;
  VAR c: D.Doc;
BEGIN
  cuddled := (p.cuddleBegin = cuddleForce)
      OR (p.cuddleBegin = cuddleAllow) & (p.tok.line = p.last.endLine);
  IF cuddled THEN
    c := D.NewChoice(); D.Decide(c, TRUE);
    RETURN D.KeptLineItem(c)
  END;
  RETURN D.HardLine()
END BeginBreak;

(* [BEGIN StatementSeq] END ident, after d: the body nested on the lines
   after BEGIN, or starting on BEGIN's line (BeginBreak); then END on a
   line of its own, or, as --cuddle-end says, on the body's line when the
   whole of BEGIN ... END ident fits on one. Without BEGIN, the comments
   before END are nested n. *)
PROCEDURE Block(p: Parser; d: D.Doc; n: LONGINT): D.Doc;
  VAR br, body, e: D.Doc; cuddled: BOOLEAN;
BEGIN
  IF Is(p, S.begin) THEN
    d := D.Cat3(d, D.HardLine(), TokItem(p, TRUE));
    br := BeginBreak(p, cuddled);
    body := BodySeq(p);
    IF body # NIL THEN
      body := D.Nest(p.ind, D.Cat(br, body));
      IF cuddled & Is(p, S.end)
          & ((p.cuddleEnd = cuddleForce)
                 OR (p.cuddleEnd = cuddleAllow)
                     & (p.tok.line = p.last.endLine)) THEN
        e := ExpectItem(p, S.end);
        e := D.Cat3(e, D.Space(), Expect(p, S.ident));
        RETURN D.Cat(d, D.Group(D.Cat3(body, D.Line(), e)))
      END;
      d := D.Cat(d, body)
    END
  ELSE
    d := D.Cat(d, D.Nest(n, TakeLead(p)))
  END;
  d := D.Cat3(d, D.HardLine(), ExpectItem(p, S.end));
  RETURN D.Cat3(d, D.Space(), Expect(p, S.ident))
END Block;

(* [ident ":"] ident, a type-bound procedure's receiver, after VAR *)
PROCEDURE Receiver(p: Parser): D.Doc;
  VAR d: D.Doc;
BEGIN
  d := Tok(p);
  IF Is(p, S.var) THEN d := D.Cat3(d, Tok(p), D.Space()) END;
  Put(d, Expect(p, S.ident)); Put(d, Expect(p, S.colon));
  d := D.Cat3(d, D.Space(), Expect(p, S.ident));
  RETURN D.Cat(d, Expect(p, S.rparen))
END Receiver;

(* Whether the procedure declaration at the current PROCEDURE has a body:
   not a forward declaration, nor poc's external one, nor voc's code
   procedure. *)
PROCEDURE HasBody(p: Parser): BOOLEAN;
  VAR k: INTEGER;
BEGIN
  k := PeekKind(p);
  RETURN (k # S.arrow) & (k # S.lbrak) & (k # S.minus)
END HasBody;

(* A blank line before the current token, ahead of its comments. *)
PROCEDURE ForceBlank(p: Parser);
BEGIN
  IF p.tok.lead # NIL THEN
    p.tok.lead.blankBefore := TRUE
  ELSE
    p.tok.blankBefore := TRUE
  END
END ForceBlank;

(* PROCEDURE ["^" | "[" string ["," string] "]" | "-" | "+" | "*"]
   [Receiver] IdentDef [FormalPars], then ";" for a forward or external
   declaration, a code string or byte list for voc's code procedure, or
   ";" DeclSeq [BEGIN StatementSeq] END ident; the ";" after it is the
   caller's. *)
PROCEDURE ProcedureDecl(p: Parser): D.Doc;
  VAR
    d, decls, body, br: D.Doc; mark: INTEGER; procs: BOOLEAN; f: D.FillBuilder;
BEGIN
  d := TokItem(p, TRUE);
  mark := p.tok.kind;
  IF mark = S.arrow THEN
    d := D.Cat3(d, D.Space(), Tok(p))
  ELSIF mark = S.lbrak THEN
    d := D.Cat3(d, D.Space(), Tok(p));
    d := D.Cat(d, Expect(p, S.string));
    IF Is(p, S.comma) THEN
      d := D.Cat3(d, Tok(p), D.Space()); d := D.Cat(d, Expect(p, S.string))
    END;
    d := D.Cat(d, Expect(p, S.rbrak))
  ELSIF (mark = S.minus) OR (mark = S.plus) OR (mark = S.times) THEN
    d := D.Cat3(d, D.Space(), Tok(p))
  ELSE
    d := D.Cat(d, D.Space())
  END;
  IF (mark = S.arrow) OR (mark = S.lbrak) THEN d := D.Cat(d, D.Space()) END;
  IF Is(p, S.lparen) THEN d := D.Cat3(d, Receiver(p), D.Space()) END;
  d := D.Cat(d, IdentDef(p, FALSE));
  IF Is(p, S.lparen) THEN d := D.Cat(d, FormalPars(p)) END;
  IF (mark = S.arrow) OR (mark = S.lbrak) THEN RETURN d END;
  IF mark = S.minus THEN
    (* voc's code procedure: a string, or byte values *)
    IF Is(p, S.string) THEN
      d := D.Cat(d, D.Group(D.Nest(p.cont, D.Cat(D.Line(), Tok(p)))))
    ELSIF Is(p, S.number) THEN
      D.InitFill(f); D.Add(f, Tok(p));
      WHILE Is(p, S.comma) DO
        D.Add(f, Tok(p)); D.Sep(f); D.Add(f, Expect(p, S.number))
      END;
      d := D.Cat3(d, D.Space(), D.Nest(p.cont, D.Fill(f)))
    END;
    RETURN d
  END;
  d := D.Cat(d, Expect(p, S.semicolon));
  decls := DeclSeq(p, procs);
  IF decls # NIL THEN
    d := D.Cat(d, D.Nest(p.ind, D.Cat(D.HardLine(), decls)))
  END;
  RETURN Block(p, d, p.ind)
END ProcedureDecl;

(* {CONST ... | TYPE ... | VAR ... | ProcedureDecl ";"}, in any order, as
   poc allows; NIL if there are none. procs says whether there are
   procedures. A blank line goes between two procedures when either has a
   body, and after a procedure with a body that a section follows. *)
PROCEDURE DeclSeq(p: Parser; VAR procs: BOOLEAN): D.Doc;
  VAR d, item: D.Doc; prevProc, prevBody, body: BOOLEAN;
BEGIN
  d := NIL; prevProc := FALSE; prevBody := FALSE; procs := FALSE;
  LOOP
    IF Is(p, S.const) OR Is(p, S.type) OR Is(p, S.var) THEN
      IF prevProc & prevBody THEN ForceBlank(p) END;
      item := Section(p); prevProc := FALSE
    ELSIF Is(p, S.procedure) THEN
      body := HasBody(p);
      IF prevProc & (prevBody OR body) THEN ForceBlank(p) END;
      item := ProcedureDecl(p); Put(item, Expect(p, S.semicolon));
      prevProc := TRUE; prevBody := body; procs := TRUE
    ELSE
      EXIT
    END;
    IF d # NIL THEN d := D.Cat(d, D.HardLine()) END;
    d := D.Cat(d, item)
  END;
  RETURN d
END DeclSeq;

(* IMPORT ident [":=" ident] {"," ...} ";", filling lines, continued at
   cont *)
PROCEDURE ImportList(p: Parser): D.Doc;
  VAR d, imp: D.Doc; f: D.FillBuilder;
BEGIN
  d := TokItem(p, TRUE);
  D.InitFill(f);
  LOOP
    imp := Expect(p, S.ident);
    IF Is(p, S.becomes) THEN
      imp := D.Cat3(imp, D.Space(), Tok(p));
      imp := D.Cat3(imp, D.Space(), Expect(p, S.ident))
    END;
    D.Add(f, imp);
    IF Is(p, S.comma) THEN D.Add(f, Tok(p)); D.Sep(f) ELSE EXIT END
  END;
  D.Add(f, Expect(p, S.semicolon));
  RETURN D.Cat3(d, D.Space(), D.Nest(p.cont, D.Fill(f)))
END ImportList;

(* MODULE ident ";" [ImportList] DeclSeq [BEGIN StatementSeq] END ident ".";
   the period is not consumed, so nothing after it is scanned. *)
PROCEDURE Module(p: Parser; moduleIndent: BOOLEAN): D.Doc;
  VAR d, inner, body, br: D.Doc; procs: BOOLEAN; n: LONGINT;
BEGIN
  IF ~Is(p, S.module) THEN Expected(p, "MODULE"); RETURN D.Empty() END;
  d := TokItem(p, TRUE);
  d := D.Cat3(d, D.Space(), Expect(p, S.ident));
  d := D.Cat(d, Expect(p, S.semicolon));
  inner := NIL;
  IF Is(p, S.import) THEN inner := ImportList(p) END;
  body := DeclSeq(p, procs);
  IF body # NIL THEN
    IF inner # NIL THEN inner := D.Cat(inner, D.HardLine()) END;
    inner := D.Cat(inner, body)
  END;
  IF moduleIndent THEN n := p.ind ELSE n := 0 END;
  IF inner # NIL THEN d := D.Cat(d, D.Nest(n, D.Cat(D.HardLine(), inner))) END;
  d := Block(p, d, n);
  IF ~Is(p, S.period) THEN ExpectedKind(p, S.period); RETURN d END;
  (* the period, without scanning past it *)
  d := D.Cat(d, LeadDoc(p.tok.lead));
  IF p.tok.lead # NIL THEN d := D.Cat(d, D.HardLine()) END;
  RETURN D.Cat(d, D.TextOf(p.tok.text))
END Module;

(* Formats src[0 .. len - 1] into out. FALSE, with the position and a
   message, on a syntax error. *)
PROCEDURE Format*(src: OppText.Text; len: LONGINT; VAR opts: Options;
                  VAR out: OppText.Buffer; VAR line, column: LONGINT;
                  VAR msg: ARRAY OF CHAR): BOOLEAN;
  VAR p: Parser; d: D.Doc; i, end: LONGINT; blank: BOOLEAN;
BEGIN
  NEW(p);
  p.s := S.New(src, len);
  NEW(p.eofTok); p.eofTok.kind := S.eof; p.eofTok.text := OppText.New("");
  p.eofTok.lead := NIL; p.eofTok.trail := NIL;
  p.mode := opts.mode; p.caseBar := opts.caseBar; p.align := opts.align;
  p.cuddleBegin := opts.cuddleBegin; p.cuddleEnd := opts.cuddleEnd;
  p.lineUp := opts.lineUp; p.single := opts.single; p.nextKind := -1;
  p.nextRun := NIL; p.nextAnchor := NIL; p.comments := D.NewRun(TRUE);
  p.assigns := NIL;
  p.ind := opts.indent;
  p.cont := 2 * opts.indent;
  p.limit := opts.width * 2 DIV 3;
  p.error := FALSE; p.last := NIL;
  p.tok := p.eofTok; Advance(p);
  d := Module(p, opts.moduleIndent);
  IF p.error THEN
    line := p.errorLine; column := p.errorColumn; COPY(p.errorMessage, msg);
    RETURN FALSE
  END;
  out := D.Render(d, opts.width);
  (* the text after the period, as it is, unless it is only white space *)
  end := p.tok.end; blank := TRUE;
  FOR i := end TO len - 1 DO
    IF (src[i] # " ") & (src[i] # 9X) & (src[i] # 0DX) & (src[i] # 0AX) THEN
      blank := FALSE
    END
  END;
  IF ~blank THEN
    DEC(out.len); out.chars[out.len] := 0X;
    FOR i := end TO len - 1 DO OppText.AppendChar(out, src[i]) END
  END;
  RETURN TRUE
END Format;

END OppFormat.
