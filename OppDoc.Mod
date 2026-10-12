MODULE OppDoc;

(* The layout engine of opp: documents, and the renderer that fits them to
   a width.

   A document is a tree of nodes (PLAN.md, "OppDoc"), rendered by the
   algorithm of Wadler's "A prettier printer", with Leijen's align and fill,
   run as Prettier runs it: a stack of frames, each an indentation, a mode
   (flat or broken) and a chain of sibling nodes still to print. A group is
   printed flat when it fits, judged by Fits, which measures the group flat
   and then what follows it, up to the first place a line may break.

   Line breaks are lazy: a break is recorded, and written with its
   indentation only when text follows. So two breaks in a row make one, a
   blank line is never doubled, no line ends in white space, and an empty
   line has no indentation. Spaces are lazy the same way, which is why
   white space between tokens is a Space node, never part of a Text.

   A group that holds a hard line, a blank line or a comment of several
   lines can never be flat; Propagate marks those before rendering.

   Fill gives Prettier's fill: each FillLine of a fill breaks only when the
   item after it does not fit on the current line, or when the item before
   it did not stay on the line it started on. A FillBuilder assembles one.

   Alignment adds extra spaces (Widen, Pad) that no layout decision
   counts, so they never change where lines break; Render renders until
   none makes a line too long (PLAN.md, "OppDoc").

   Each node is used once: a node in a concatenation is linked to the next
   by its next field, so a node must never be put in two places. *)

IMPORT OppText;

CONST
  (* node kinds *)
  text = 0; space = 1; line = 2; softLine = 3; hardLine = 4; blankLine = 5;
  fillLine = 6; nest = 7; align = 8; alignOrNest = 9; group = 10;
  concat = 11; comment = 12; mark = 13; choice = 14; choiceLine = 15;
  trailBreak = 16; softBreak = 17; keptLine = 18; widen = 19; pad = 20;
  run = 21; anchor = 22;

  (* modes *)
  flat = 0; broken = 1;

  tabWidth = 8;

TYPE
  Doc* = POINTER TO DocDesc;
  DocDesc = RECORD
    kind: INTEGER;
    text: OppText.Text; (* text, comment *)
    width: LONGINT; (* text: its width; comment: its first line's *)
    n: LONGINT; (* nest, alignOrNest: the indentation added;
                   comment: the column it started at in the
                   source; mark: the line it was printed on;
                   choice: 1 if its lines are hard, else 0 *)
    limit: LONGINT; (* alignOrNest: the last column to align to;
                       keptLine: 1 if it measures the first item after
                       it, else 0 *)
    multiLine: BOOLEAN; (* comment: its text holds a line break *)
    hard: BOOLEAN; (* group: it holds a hard break (Propagate) *)
    child: Doc; (* nest, align, alignOrNest, group: the content;
                   concat: the first part *)
    last: Doc; (* concat: the last part *)
    ref: Doc; (* fillLine: the mark before the item before it;
                 choiceLine, keptLine: its choice; softBreak: its
                 fill; pad: its run *)
    next: Doc; (* the next part of a concatenation *)

    (* alignment; widen: n is its width; pad: n is the author's gap, used
       when it is excluded; run, and a pad that starts a run of lines next
       to each other: n is the column the run lines up at, limit the next
       pass's *)
    on: BOOLEAN; (* widen, excluded pad: its spaces are written; run: it
                    is lined up *)
    adjacent: BOOLEAN; (* run: lines next to each other line up *)
    excluded: BOOLEAN; (* pad: it shares its line with another of its run,
                          or with text after its comment *)
    midLine: BOOLEAN; (* pad: text follows what follows it on its line *)
    line, col, extra: LONGINT; (* widen, pad, as the last pass met it: its
                                  line, its column after one space, and
                                  the extra spaces it wrote *)
    sub: Doc; (* pad: what holds its run's column, its run or the pad
                 that starts its lines *)
    from: Doc; (* pad: the anchor where what it is in starts, or NIL;
                  anchor: on, if it started a line, and its line *)
    link: Doc (* widen, pad: the next the last pass met *)
  END;

  FillBuilder* = RECORD
    doc: Doc; (* the fill so far, a concatenation *)
    item: Doc; (* the current item, a concatenation, or NIL
                  after a separator *)
    mark: Doc (* the mark that begins the current item *)
  END;

  (* A frame of the renderer's stack: print doc and, if chain is set, the
     siblings after it, at indentation ind, in mode. *)
  Frame = POINTER TO FrameDesc;
  FrameDesc = RECORD
    ind: LONGINT;
    mode: INTEGER;
    doc: Doc;
    chain: BOOLEAN;
    shift: LONGINT; (* the extra spaces before ind on its lines *)
    origin: LONGINT; (* the line whose extra spaces shift them, or -1 *)
    below: Frame
  END;

  Lines = POINTER TO ARRAY OF LONGINT;

  Renderer = RECORD
    out: OppText.Buffer;
    width: LONGINT;
    col: LONGINT; (* columns written on the current line *)
    lineNo: LONGINT; (* line breaks written *)
    pendingBreaks: INTEGER; (* 0, or 1 for a line break, 2 for a blank line *)
    pendingIndent: LONGINT; (* the indentation of the pending line break *)
    pendingSpaces: LONGINT;
    pendingPad: LONGINT; (* extra spaces after the pending spaces *)
    pendingShift, pendingOrigin: LONGINT; (* the pending line break's
                                              frame's *)
    extra: LONGINT; (* extra spaces written on the current line *)
    shift, origin: LONGINT; (* the current frame's *)
    lastLineBlank: BOOLEAN; (* the line before the current one is empty *)
    first: BOOLEAN; (* the first pass *)
    lineUp: BOOLEAN; (* pads line up their runs *)
    met, lastMet: Doc; (* the widens and pads this pass met *)
    lastPad: Doc; (* the last pad met on the current line *)
    padTexts: INTEGER; (* texts and comments written after it *)
    lineCol, lineExtra, lineOrigin: Lines (* each line's width, extra
                                             spaces, and the line its
                                             shift comes from *)
  END;

(* ---- Building documents ---- *)

PROCEDURE NewNode(kind: INTEGER): Doc;
  VAR d: Doc;
BEGIN
  NEW(d); d.kind := kind; d.text := NIL; d.width := 0; d.n := 0; d.limit := 0;
  d.multiLine := FALSE; d.hard := FALSE;
  d.child := NIL; d.last := NIL; d.ref := NIL; d.next := NIL;
  d.on := FALSE; d.adjacent := FALSE; d.excluded := FALSE; d.line := -1;
  d.col := 0; d.extra := 0; d.sub := NIL; d.link := NIL; d.from := NIL;
  RETURN d
END NewNode;

PROCEDURE TextOf*(t: OppText.Text): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(text); d.text := t; d.width := OppText.Width(t^);
  RETURN d
END TextOf;

PROCEDURE Text*(s: ARRAY OF CHAR): Doc;
BEGIN
  RETURN TextOf(OppText.New(s))
END Text;

(* One space, written only if text follows on the same line. *)
PROCEDURE Space*(): Doc;
BEGIN
  RETURN NewNode(space)
END Space;

(* A space when flat; a line break when broken. *)
PROCEDURE Line*(): Doc;
BEGIN
  RETURN NewNode(line)
END Line;

(* Nothing when flat; a line break when broken. *)
PROCEDURE SoftLine*(): Doc;
BEGIN
  RETURN NewNode(softLine)
END SoftLine;

(* Always a line break; its groups are broken. *)
PROCEDURE HardLine*(): Doc;
BEGIN
  RETURN NewNode(hardLine)
END HardLine;

(* A line break after a trailing comment: always a line break, but it
   breaks its group only when something follows it in the group, so a
   group that ends with a trailing comment can still be flat. *)
PROCEDURE TrailBreak*(): Doc;
BEGIN
  RETURN NewNode(trailBreak)
END TrailBreak;

(* Nothing, or, when broken, a line break if the first item of fill, the
   fill that follows it, does not fit on the line, and the break would move
   it left: after the "(" of a list whose first item does not fit after
   it. A fill of one item is measured with what follows it, up to the next
   line break. *)
PROCEDURE SoftBreak*(fill: Doc): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(softBreak); d.ref := fill;
  RETURN d
END SoftBreak;

(* A line break and one empty line, however many are asked for in a row;
   none at the start of the text. Its groups are broken. *)
PROCEDURE BlankLine*(): Doc;
BEGIN
  RETURN NewNode(blankLine)
END BlankLine;

(* A choice, decided later, between hard lines and lines that may be flat,
   for the lines of a structured statement whose layout is known only once
   it has all been parsed. Undecided, its lines may be flat. *)
PROCEDURE NewChoice*(): Doc;
  VAR c: Doc;
BEGIN
  c := NewNode(choice); c.n := 0;
  RETURN c
END NewChoice;

PROCEDURE Decide*(c: Doc; hard: BOOLEAN);
BEGIN
  IF hard THEN c.n := 1 ELSE c.n := 0 END
END Decide;

(* A Line, or a HardLine, as c is decided. *)
PROCEDURE ChoiceLine*(c: Doc): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(choiceLine); d.ref := c;
  RETURN d
END ChoiceLine;

(* Nothing, or, after a space on the same line, that space widened to n
   columns unless that makes a line too long: an author's alignment kept.
   Layout decisions ignore it, so it never changes where lines break. *)
PROCEDURE Widen*(n: LONGINT): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(widen); d.n := n;
  RETURN d
END Widen;

(* A run of pads that line up: the pads of one run, or, if adjacent, those
   on lines next to each other. *)
PROCEDURE NewRun*(adjacent: BOOLEAN): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(run); d.adjacent := adjacent; d.on := TRUE;
  RETURN d
END NewRun;

(* Nothing: the start of something with a pad in it, as a statement. *)
PROCEDURE Anchor*(): Doc;
BEGIN
  RETURN NewNode(anchor)
END Anchor;

(* p, a pad, lines up only when what it is in starts its line, at a. *)
PROCEDURE SetAnchor*(p, a: Doc);
BEGIN
  p.from := a
END SetAnchor;

(* Nothing, or, after a space on the same line, that space widened so that
   what follows starts at the same column as after the other pads of run,
   unless that makes a line too long. A pad on a line with another of its
   run, before a comment with text after it on its line, or whose anchor
   does not start its line, is not lined up: it is Widen(gap). Layout
   decisions ignore it. *)
PROCEDURE Pad*(run: Doc; gap: LONGINT): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(pad); d.ref := run; d.n := gap;
  RETURN d
END Pad;

(* A ChoiceLine(c) while c is soft; once c is decided hard, a line break
   only if what follows it does not fit on the line, as Group(Line()): the
   line between a keyword and a body that --keep-lines keeps on the
   keyword's line in a statement it breaks. *)
PROCEDURE KeptLine*(c: Doc): Doc;
  VAR d: Doc;
BEGIN
  d := NewNode(keptLine); d.ref := c;
  RETURN d
END KeptLine;

(* A KeptLine(c) before a fill, as after BEGIN: once c is hard, a line
   break unless the fill's first item, all of it flat, fits on the line. *)
PROCEDURE KeptLineItem*(c: Doc): Doc;
  VAR d: Doc;
BEGIN
  d := KeptLine(c); d.limit := 1;
  RETURN d
END KeptLineItem;

(* d, with its line breaks indented n more. *)
PROCEDURE Nest*(n: LONGINT; d: Doc): Doc;
  VAR r: Doc;
BEGIN
  r := NewNode(nest); r.n := n; r.child := d;
  RETURN r
END Nest;

(* d, with its line breaks indented to the column it starts at. *)
PROCEDURE Align*(d: Doc): Doc;
  VAR r: Doc;
BEGIN
  r := NewNode(align); r.child := d;
  RETURN r
END Align;

(* Align(d) if d starts at or left of column limit (counted from 0), and
   otherwise Nest(n, d). When d is a fill, it is nested also when one of
   its items would not fit on a line of its own aligned but would nested;
   the last item is measured with what follows it. *)
PROCEDURE AlignOrNest*(n, limit: LONGINT; d: Doc): Doc;
  VAR r: Doc;
BEGIN
  r := NewNode(alignOrNest); r.n := n; r.limit := limit; r.child := d;
  RETURN r
END AlignOrNest;

(* d flat if it fits, else broken. *)
PROCEDURE Group*(d: Doc): Doc;
  VAR r: Doc;
BEGIN
  r := NewNode(group); r.child := d;
  RETURN r
END Group;

(* A comment, its text as in the source, which started there at column
   (counted from 1). A comment of several lines keeps its shape: its later
   lines move by as many columns as its first line moved. *)
PROCEDURE Comment*(t: OppText.Text; column: LONGINT): Doc;
  VAR d: Doc; i: LONGINT;
BEGIN
  d := NewNode(comment); d.text := t; d.n := column;
  i := 0;
  WHILE (t[i] # 0X) & (t[i] # 0AX) DO INC(i) END;
  d.multiLine := t[i] = 0AX;
  d.width := OppText.Width(t^);
  IF d.multiLine THEN
    d.width := 0; i := 0;
    WHILE t[i] # 0AX DO
      IF (t[i] < 80X) OR (t[i] >= 0C0X) THEN INC(d.width) END;
      INC(i)
    END
  END;
  RETURN d
END Comment;

(* a followed by b; either may be NIL. a is extended in place when it is a
   concatenation, so a must not be used anywhere else. *)
PROCEDURE Cat*(a, b: Doc): Doc;
  VAR r: Doc;
BEGIN
  IF a = NIL THEN RETURN b
  ELSIF b = NIL THEN RETURN a
  ELSIF a.kind = concat THEN
    IF a.child = NIL THEN a.child := b ELSE a.last.next := b END;
    a.last := b;
    RETURN a
  ELSE
    r := NewNode(concat); r.child := a; r.last := b; a.next := b;
    RETURN r
  END
END Cat;

PROCEDURE Cat3*(a, b, c: Doc): Doc;
BEGIN
  RETURN Cat(Cat(a, b), c)
END Cat3;

(* An empty document. *)
PROCEDURE Empty*(): Doc;
BEGIN
  RETURN NewNode(concat)
END Empty;

(* ---- Fills ---- *)

PROCEDURE InitFill*(VAR f: FillBuilder);
BEGIN
  f.doc := NewNode(concat); f.item := NIL; f.mark := NIL
END InitFill;

(* d, as part of the current item, or as the start of a new one. Each item
   is a concatenation of its own, so that a separator's Fits measures the
   whole of the item after it; it starts with a mark, which records the
   line the item starts on. *)
PROCEDURE Add*(VAR f: FillBuilder; d: Doc);
BEGIN
  IF f.item = NIL THEN
    f.mark := NewNode(mark); f.mark.n := -1;
    f.item := NewNode(concat); f.item := Cat(f.item, f.mark);
    f.doc := Cat(f.doc, f.item)
  END;
  f.item := Cat(f.item, d)
END Add;

(* d, the leading comments of a new item, which put it on a line of its
   own: they go before the item's mark, so that a separator after the item
   asks whether the item itself stayed on one line. *)
PROCEDURE AddLead*(VAR f: FillBuilder; d: Doc);
BEGIN
  f.mark := NewNode(mark); f.mark.n := -1;
  f.item := NewNode(concat); f.item := Cat(f.item, d);
  f.item := Cat(f.item, f.mark);
  f.doc := Cat(f.doc, f.item)
END AddLead;

(* A separator: a space, or a line break if the next item does not fit on
   the line or the item before did not stay on one line. *)
PROCEDURE Sep*(VAR f: FillBuilder);
  VAR s: Doc;
BEGIN
  s := NewNode(fillLine); s.ref := f.mark;
  f.doc := Cat(f.doc, s); f.item := NIL
END Sep;

(* A separator that always breaks the line. *)
PROCEDURE Break*(VAR f: FillBuilder);
BEGIN
  f.doc := Cat(f.doc, HardLine()); f.item := NIL
END Break;

(* Like Break, with an empty line. *)
PROCEDURE BlankBreak*(VAR f: FillBuilder);
BEGIN
  f.doc := Cat(f.doc, BlankLine()); f.item := NIL
END BlankBreak;

PROCEDURE Fill*(VAR f: FillBuilder): Doc;
BEGIN
  RETURN f.doc
END Fill;

(* ---- Rendering ---- *)

(* Marks every group that holds a hard break, and says whether the chain
   from d holds one: strict counts every TrailBreak, end does not count one
   that nothing follows in the chain. A group is hard if its content is by
   end; to what holds the group, it is as its content. *)
PROCEDURE Propagate(d: Doc; VAR strict, end: BOOLEAN);
  VAR s, e: BOOLEAN;
BEGIN
  strict := FALSE; end := FALSE;
  WHILE d # NIL DO
    CASE d.kind OF
      hardLine, blankLine: s := TRUE; e := TRUE
    | trailBreak: s := TRUE; e := FALSE
    | choiceLine: s := d.ref.n = 1; e := s
    | comment: s := d.multiLine; e := s
    | nest, align, alignOrNest, concat: Propagate(d.child, s, e)
    | group: Propagate(d.child, s, e); d.hard := e
    ELSE s := FALSE; e := FALSE
    END;
    strict := strict OR s;
    IF d.next = NIL THEN end := end OR e ELSE end := end OR s END;
    d := d.next
  END
END Propagate;

PROCEDURE Push(VAR stack: Frame; ind: LONGINT; mode: INTEGER; d: Doc;
               chain: BOOLEAN);
  VAR f: Frame;
BEGIN
  IF d # NIL THEN
    NEW(f); f.ind := ind; f.mode := mode; f.doc := d; f.chain := chain;
    f.shift := 0; f.origin := -1; f.below := stack;
    stack := f
  END
END Push;

(* The node at the top of stack, which is taken off it. *)
PROCEDURE Pop(VAR stack: Frame; VAR ind: LONGINT; VAR mode: INTEGER): Doc;
  VAR d: Doc;
BEGIN
  d := stack.doc; ind := stack.ind; mode := stack.mode;
  IF stack.chain & (d.next # NIL) THEN
    stack.doc := d.next
  ELSE
    stack := stack.below
  END;
  RETURN d
END Pop;

(* Whether first, flat, and then the frames of rest, each in its own mode,
   fit in rem columns up to the first line break that may be taken. A hard
   break in first that is not the last thing in it means first cannot be
   flat, so it does not fit; one at its end (a trailing comment's) ends
   the measure. Unless all is set, a comment that ends the line is not
   counted: code is not broken to make room for a trailing comment, which
   could not move to the next line anyway; but a fill separator counts it
   when it decides whether the item after it joins the line. rest is only
   read. *)
PROCEDURE Fits(first: Doc; rest: Frame; rem: LONGINT; all: BOOLEAN): BOOLEAN;
  VAR
    local: Frame; d: Doc; ind, pending: LONGINT; mode: INTEGER;
    inFirst: BOOLEAN;
BEGIN
  local := NIL; inFirst := TRUE; pending := 0;
  Push(local, 0, flat, first, FALSE);
  LOOP
    IF rem < 0 THEN RETURN FALSE END;
    IF local = NIL THEN
      IF rest = NIL THEN RETURN TRUE END;
      inFirst := FALSE;
      Push(local, rest.ind, rest.mode, rest.doc, rest.chain);
      rest := rest.below
    END;
    d := Pop(local, ind, mode);
    (* the comments before d do not end the line *)
    IF (pending > 0)
        & ((d.kind IN {text, space, line, fillLine, choiceLine, keptLine})
               OR (d.kind = comment) & d.multiLine) THEN
      DEC(rem, pending); pending := 0
    END;
    CASE d.kind OF
      text: DEC(rem, d.width)
    | space: DEC(rem)
    | comment:
        IF ~d.multiLine & ~all THEN INC(pending, d.width)
        ELSE
          DEC(rem, d.width);
          IF d.multiLine THEN
            RETURN (rem >= 0) & (~inFirst OR (local = NIL))
          END
        END
    | line, fillLine: IF mode = flat THEN DEC(rem) ELSE RETURN TRUE END
    | choiceLine:
        IF (mode = flat) & (d.ref.n = 0) THEN DEC(rem)
        ELSE RETURN ~inFirst OR (local = NIL)
        END
    | keptLine: (* in a flat group, a space either way *)
        IF mode = flat THEN DEC(rem)
        ELSIF d.ref.n = 1 THEN RETURN TRUE
        ELSE RETURN ~inFirst OR (local = NIL)
        END
    | softLine: IF mode = broken THEN RETURN TRUE END
    | hardLine, blankLine, trailBreak: RETURN ~inFirst OR (local = NIL)
    | nest, align, alignOrNest, concat: Push(local, ind, mode, d.child, TRUE)
    | group:
        IF d.hard THEN Push(local, ind, broken, d.child, TRUE)
        ELSE Push(local, ind, mode, d.child, TRUE)
        END
    | mark, choice, softBreak, widen, pad, run, anchor:
    END
  END
END Fits;

(* Whether the chain from d holds a group that cannot be flat, or a hard
   choice's line: what cannot be on one line. *)
PROCEDURE HoldsHard(d: Doc): BOOLEAN;
BEGIN
  WHILE d # NIL DO
    IF (d.kind = group) & d.hard OR (d.kind = choiceLine) & (d.ref.n = 1)
        OR (d.kind IN {nest, align, alignOrNest, concat, group})
            & HoldsHard(d.child) THEN
      RETURN TRUE
    END;
    d := d.next
  END;
  RETURN FALSE
END HoldsHard;

(* Whether the fill d has an item that does not fit in aligned columns
   but does in nested columns, the last item measured with rest after it. *)
PROCEDURE NestFits(d: Doc; rest: Frame; aligned, nested: LONGINT): BOOLEAN;
  VAR it, last: Doc; r: Frame;
BEGIN
  IF d.kind # concat THEN RETURN FALSE END;
  last := NIL; it := d.child;
  WHILE it # NIL DO
    IF (it.kind # fillLine) & (it.kind # hardLine) & (it.kind # blankLine) THEN
      last := it
    END;
    it := it.next
  END;
  it := d.child;
  WHILE it # NIL DO
    IF (it.kind # fillLine) & (it.kind # hardLine) & (it.kind # blankLine) THEN
      IF it = last THEN r := rest ELSE r := NIL END;
      IF ~Fits(it, r, aligned, FALSE) & Fits(it, r, nested, FALSE) THEN
        RETURN TRUE
      END
    END;
    it := it.next
  END;
  RETURN FALSE
END NestFits;

PROCEDURE Spaces(VAR r: Renderer; n: LONGINT);
BEGIN
  WHILE n > 0 DO OppText.AppendChar(r.out, " "); INC(r.col); DEC(n) END
END Spaces;

(* Records the line just ended, with its width and extra spaces, and starts
   the next, whose shift comes from no line. *)
PROCEDURE EndLine(VAR r: Renderer);
  VAR a, b, c: Lines; i: LONGINT;
BEGIN
  IF r.lineNo + 1 >= LEN(r.lineCol^) THEN
    NEW(a, 2 * LEN(r.lineCol^)); NEW(b, LEN(a^)); NEW(c, LEN(a^));
    FOR i := 0 TO LEN(r.lineCol^) - 1 DO
      a[i] := r.lineCol[i]; b[i] := r.lineExtra[i]; c[i] := r.lineOrigin[i]
    END;
    r.lineCol := a; r.lineExtra := b; r.lineOrigin := c
  END;
  r.lineCol[r.lineNo] := r.col; r.lineExtra[r.lineNo] := r.extra;
  INC(r.lineNo);
  r.lineOrigin[r.lineNo] := -1
END EndLine;

(* Writes the pending line breaks or spaces, as text is about to follow. *)
PROCEDURE Flush(VAR r: Renderer);
BEGIN
  IF r.pendingBreaks > 0 THEN
    IF r.out.len > 0 THEN
      OppText.AppendChar(r.out, 0AX); r.lastLineBlank := r.col = 0;
      EndLine(r);
      IF (r.pendingBreaks = 2) & ~r.lastLineBlank THEN
        OppText.AppendChar(r.out, 0AX); r.col := 0; r.extra := 0; EndLine(r);
        r.lastLineBlank := TRUE
      END
    END;
    r.col := 0; r.pendingBreaks := 0; r.pendingSpaces := 0; r.pendingPad := 0;
    r.lastPad := NIL;
    r.extra := r.pendingShift;
    IF r.pendingShift > 0 THEN r.lineOrigin[r.lineNo] := r.pendingOrigin END;
    Spaces(r, r.pendingIndent + r.pendingShift)
  ELSE
    INC(r.extra, r.pendingPad);
    Spaces(r, r.pendingSpaces + r.pendingPad);
    r.pendingSpaces := 0; r.pendingPad := 0
  END
END Flush;

(* A line break at indentation ind, shifted as the current frame is. *)
PROCEDURE NewLine(VAR r: Renderer; ind: LONGINT; breaks: INTEGER);
BEGIN
  IF breaks > r.pendingBreaks THEN r.pendingBreaks := breaks END;
  r.pendingIndent := ind; r.pendingShift := r.shift;
  r.pendingOrigin := r.origin;
  r.pendingSpaces := 0; r.pendingPad := 0
END NewLine;

(* The line the next text will be on: the line breaks Flush will write. *)
PROCEDURE NextLine(VAR r: Renderer): LONGINT;
  VAR n: LONGINT;
BEGIN
  n := r.lineNo;
  IF (r.pendingBreaks > 0) & (r.out.len > 0) THEN
    INC(n);
    IF (r.pendingBreaks = 2) & (r.col # 0) THEN INC(n) END
  END;
  RETURN n
END NextLine;

(* The column the next text will start at, without the extra spaces of
   alignment: the column every layout decision uses. *)
PROCEDURE Column(VAR r: Renderer): LONGINT;
BEGIN
  IF r.pendingBreaks > 0 THEN
    RETURN r.pendingIndent
  ELSE
    RETURN r.col - r.extra + r.pendingSpaces
  END
END Column;

(* The column the next text will really start at. *)
PROCEDURE RealColumn(VAR r: Renderer): LONGINT;
BEGIN
  IF r.pendingBreaks > 0 THEN
    RETURN r.pendingIndent + r.pendingShift
  ELSE
    RETURN r.col + r.pendingSpaces + r.pendingPad
  END
END RealColumn;

(* Notes, after a Flush, that text is written: a second text after a pad
   on its line puts the pad mid-line. *)
PROCEDURE Written(VAR r: Renderer);
BEGIN
  IF r.lastPad # NIL THEN
    INC(r.padTexts);
    IF r.padTexts = 2 THEN r.lastPad.midLine := TRUE; r.lastPad := NIL END
  END
END Written;

PROCEDURE EmitText(VAR r: Renderer; t: OppText.Text; width: LONGINT);
BEGIN
  Flush(r); Written(r);
  OppText.AppendText(r.out, t); INC(r.col, width)
END EmitText;

(* A comment: its first line here, and each later line moved by as many
   columns as the first line moved from where it was in the source, with
   the white space at the end of each line dropped. Its later lines owe
   their extra spaces to its first line's. *)
PROCEDURE EmitComment(VAR r: Renderer; d: Doc);
  VAR t: OppText.Text; i, j, k, delta, lead, first: LONGINT;
BEGIN
  Flush(r); Written(r);
  t := d.text; first := r.lineNo;
  delta := r.col + 1 - d.n;
  i := 0;
  LOOP
    (* t[i ..] starts a line: its leading white space (only after the
       first line), then its text up to the white space at its end *)
    lead := 0;
    IF i > 0 THEN
      WHILE (t[i] = " ") OR (t[i] = 9X) DO
        IF t[i] = 9X THEN
          lead := (lead DIV tabWidth + 1) * tabWidth
        ELSE
          INC(lead)
        END;
        INC(i)
      END
    END;
    j := i;
    WHILE (t[j] # 0X) & (t[j] # 0AX) DO INC(j) END;
    k := j;
    WHILE (k > i) & ((t[k - 1] = " ") OR (t[k - 1] = 9X)) DO DEC(k) END;
    IF k > i THEN
      IF i > 0 THEN
        lead := lead + delta;
        IF lead < 0 THEN lead := 0 END;
        Spaces(r, lead)
      END;
      WHILE i < k DO
        OppText.AppendChar(r.out, t[i]);
        IF (t[i] < 80X) OR (t[i] >= 0C0X) THEN INC(r.col) END;
        INC(i)
      END
    END;
    IF t[j] = 0X THEN EXIT END;
    OppText.AppendChar(r.out, 0AX); r.lastLineBlank := r.col = 0;
    EndLine(r);
    IF r.extra > 0 THEN r.lineOrigin[r.lineNo] := first END;
    r.col := 0;
    i := j + 1
  END
END EmitComment;

(* Push for the renderer: d at ind, shifted as the current frame is. *)
PROCEDURE PushIn(VAR stack: Frame; VAR r: Renderer; ind: LONGINT; mode: INTEGER;
                 d: Doc);
BEGIN
  Push(stack, ind, mode, d, TRUE);
  IF d # NIL THEN stack.shift := r.shift; stack.origin := r.origin END
END PushIn;

(* d indented to the column it starts at, its shift the extra spaces
   before that column. *)
PROCEDURE PushAligned(VAR stack: Frame; VAR r: Renderer; mode: INTEGER; d: Doc);
  VAR c: LONGINT;
BEGIN
  c := Column(r);
  Push(stack, c, mode, d, TRUE);
  IF d # NIL THEN
    stack.shift := RealColumn(r) - c;
    IF stack.shift > 0 THEN stack.origin := NextLine(r) END
  END
END PushAligned;

(* Adds x, a widen or pad that met a space, to the pass's list. *)
PROCEDURE Met(VAR r: Renderer; x: Doc);
BEGIN
  x.link := NIL;
  IF r.met = NIL THEN r.met := x ELSE r.lastMet.link := x END;
  r.lastMet := x
END Met;

(* One rendering of d: the layout is the same in every pass, as only the
   extra spaces differ. *)
PROCEDURE Pass(d: Doc; width: LONGINT; VAR r: Renderer);
  VAR
    stack, rest: Frame; x, item, nothing: Doc; ind, c: LONGINT;
    mode: INTEGER;
BEGIN
  nothing := NewNode(text); nothing.text := OppText.New(""); nothing.width := 0;
  r.out := OppText.NewBuffer(); r.width := width; r.col := 0; r.lineNo := 0;
  r.pendingBreaks := 0; r.pendingIndent := 0; r.pendingSpaces := 0;
  r.pendingPad := 0; r.pendingShift := 0; r.pendingOrigin := -1;
  r.extra := 0; r.shift := 0; r.origin := -1;
  r.lastLineBlank := FALSE; r.met := NIL; r.lastMet := NIL; r.lastPad := NIL;
  IF r.lineCol = NIL THEN
    NEW(r.lineCol, 256); NEW(r.lineExtra, 256); NEW(r.lineOrigin, 256)
  END;
  r.lineOrigin[0] := -1;
  stack := NIL;
  Push(stack, 0, broken, d, FALSE);
  WHILE stack # NIL DO
    r.shift := stack.shift; r.origin := stack.origin;
    x := Pop(stack, ind, mode);
    CASE x.kind OF
      text: EmitText(r, x.text, x.width)
    | space: IF r.pendingBreaks = 0 THEN INC(r.pendingSpaces) END
    | comment: EmitComment(r, x)
    | line: IF mode = flat THEN INC(r.pendingSpaces) ELSE NewLine(r, ind, 1) END
    | choiceLine:
        IF (mode = flat) & (x.ref.n = 0) THEN
          INC(r.pendingSpaces)
        ELSE
          NewLine(r, ind, 1)
        END
    | widen:
        IF (r.pendingBreaks = 0) & (r.pendingSpaces = 1) & (x.n > 1) THEN
          IF r.first THEN x.on := TRUE END;
          x.line := NextLine(r); x.extra := 0;
          IF x.on THEN x.extra := x.n - 1 END;
          r.pendingPad := x.extra; Met(r, x)
        END
    | pad:
        IF (r.pendingBreaks = 0) & (r.pendingSpaces = 1) THEN
          IF r.first THEN
            x.excluded := FALSE; x.midLine := FALSE; x.sub := NIL;
            r.lastPad := x; r.padTexts := 0
          END;
          x.line := NextLine(r); x.col := RealColumn(r); x.extra := 0;
          IF x.excluded THEN
            IF x.on & (x.n > 1) THEN x.extra := x.n - 1 END
          ELSIF r.lineUp & (x.sub # NIL) & x.sub.on & (x.sub.n > x.col) THEN
            x.extra := x.sub.n - x.col
          END;
          r.pendingPad := x.extra; Met(r, x)
        END
    | keptLine:
        IF x.ref.n = 0 THEN
          IF mode = flat THEN INC(r.pendingSpaces) ELSE NewLine(r, ind, 1) END
        ELSIF r.pendingBreaks # 0 THEN
          NewLine(r, ind, 1)
        ELSIF x.limit = 1 THEN
          (* the fill's first item, all on the line *)
          item := nothing;
          IF stack # NIL THEN
            item := stack.doc;
            IF (item.kind = concat) & (item.child # NIL) THEN
              item := item.child
            END
          END;
          IF ((item.kind # concat) OR ~HoldsHard(item.child))
              & Fits(item, NIL, width - Column(r) - 1, FALSE) THEN
            INC(r.pendingSpaces)
          ELSE
            NewLine(r, ind, 1)
          END
        ELSIF Fits(nothing, stack, width - Column(r) - 1, FALSE) THEN
          INC(r.pendingSpaces)
        ELSE
          NewLine(r, ind, 1)
        END
    | softLine: IF mode = broken THEN NewLine(r, ind, 1) END
    | hardLine, trailBreak: NewLine(r, ind, 1)
    | blankLine: NewLine(r, ind, 2)
    | fillLine:
        IF mode = flat THEN
          INC(r.pendingSpaces)
        ELSIF (x.ref # NIL) & (x.ref.n # NextLine(r)) THEN
          NewLine(r, ind, 1)
        ELSIF stack = NIL THEN
          INC(r.pendingSpaces)
        ELSE
          (* the item after it, flat, then everything after that *)
          item := stack.doc;
          IF stack.chain & (item.next # NIL) THEN
            NEW(rest); rest^ := stack^; rest.doc := item.next
          ELSE
            rest := stack.below
          END;
          IF (r.pendingBreaks = 0)
              & Fits(item, rest, width - Column(r) - 1, TRUE) THEN
            INC(r.pendingSpaces)
          ELSE
            NewLine(r, ind, 1)
          END
        END
    | softBreak:
        IF (mode = broken) & (x.ref.child # NIL) & (Column(r) > ind) THEN
          item := x.ref.child;
          IF item.next = NIL THEN
            item := stack.doc;
            IF stack.chain & (item.next # NIL) THEN
              NEW(rest); rest^ := stack^; rest.doc := item.next
            ELSE
              rest := stack.below
            END
          ELSE
            rest := NIL
          END;
          IF ~Fits(item, rest, width - Column(r), FALSE) THEN
            NewLine(r, ind, 1)
          END
        END
    | nest: PushIn(stack, r, ind + x.n, mode, x.child)
    | align: PushAligned(stack, r, mode, x.child)
    | alignOrNest:
        c := Column(r);
        IF (c <= x.limit)
            & ((mode = flat) OR (c <= ind + x.n)
                   OR ~NestFits(x.child, stack, width - c,
                                width - ind - x.n)) THEN
          PushAligned(stack, r, mode, x.child)
        ELSE PushIn(stack, r, ind + x.n, mode, x.child)
        END
    | group:
        IF (mode = flat)
            OR ~x.hard & Fits(x.child, stack, width - Column(r), FALSE) THEN
          PushIn(stack, r, ind, flat, x.child)
        ELSE
          PushIn(stack, r, ind, broken, x.child)
        END
    | concat: PushIn(stack, r, ind, mode, x.child)
    | mark: x.n := NextLine(r)
    | anchor:
        x.line := NextLine(r);
        x.on := (r.pendingBreaks > 0) OR (r.out.len = 0)
    | choice, run:
    END
  END;
  IF r.out.len > 0 THEN OppText.AppendChar(r.out, 0AX); EndLine(r) END
END Pass;

(* Whether x's extra spaces may be what made line l too long: they are on
   l, or on a line whose extra spaces shift l's start. *)
PROCEDURE Shifts(VAR r: Renderer; x: Doc; l: LONGINT): BOOLEAN;
  VAR n: LONGINT;
BEGIN
  n := 0;
  WHILE (l >= 0) & (n <= r.lineNo) DO
    IF x.line = l THEN RETURN TRUE END;
    l := r.lineOrigin[l]; INC(n)
  END;
  RETURN FALSE
END Shifts;

(* Turns off, for each line too long because of extra spaces, the last
   of them that shifts it: the author's while lining up is off, then a run
   opp lines up. A line too long without them, for a comment or a string
   that cannot break, may keep them, as a trailing comment may overflow.
   Whether it turned off any. *)
PROCEDURE Blame(VAR r: Renderer): BOOLEAN;
  VAR l: LONGINT; x, last: Doc; any: BOOLEAN;
BEGIN
  any := FALSE;
  FOR l := 0 TO r.lineNo - 1 DO
    IF (r.lineCol[l] > r.width) & (r.lineExtra[l] > 0)
        & (r.lineCol[l] - r.lineExtra[l] <= r.width) THEN
      x := r.met; last := NIL;
      WHILE x # NIL DO
        IF (x.extra > 0) & Shifts(r, x, l) THEN
          IF ~r.lineUp & ((x.kind = widen) OR x.excluded)
              OR r.lineUp & (x.kind = pad) & ~x.excluded & x.sub.on THEN
            last := x
          END
        END;
        x := x.link
      END;
      IF last = NIL THEN
      ELSIF r.lineUp THEN last.sub.on := FALSE; any := TRUE
      ELSE last.on := FALSE; any := TRUE
      END
    END
  END;
  RETURN any
END Blame;

(* Leaves out of their runs the pads that share a line with another of
   their run: declarations packed onto a line. *)
PROCEDURE Exclude(VAR r: Renderer);
  VAR x, prev: Doc;
BEGIN
  x := r.met;
  WHILE x # NIL DO IF x.kind = pad THEN x.ref.last := NIL END; x := x.link END;
  x := r.met;
  WHILE x # NIL DO
    IF x.kind = pad THEN
      prev := x.ref.last;
      IF (prev # NIL) & (prev.line = x.line) & ~x.ref.adjacent THEN
        prev.excluded := TRUE; x.excluded := TRUE
      END;
      IF x.midLine & x.ref.adjacent
          OR (x.from # NIL) & (~x.from.on OR (x.from.line # x.line)) THEN
        x.excluded := TRUE
      END;
      x.on := TRUE; x.ref.last := x
    END;
    x := x.link
  END
END Exclude;

(* Gives each pad in a run its run, and each run the column its pads line
   up at: the furthest any of them starts at. With start, every run is on.
   Whether any run's column changed. *)
PROCEDURE Columns(VAR r: Renderer; start: BOOLEAN): BOOLEAN;
  VAR x, prev: Doc; changed: BOOLEAN;
BEGIN
  x := r.met;
  WHILE x # NIL DO
    IF x.kind = pad THEN x.ref.last := NIL; x.ref.limit := 0; x.limit := 0 END;
    x := x.link
  END;
  x := r.met;
  WHILE x # NIL DO
    IF (x.kind = pad) & ~x.excluded THEN
      IF ~x.ref.adjacent THEN
        x.sub := x.ref
      ELSE
        prev := x.ref.last;
        IF (prev # NIL) & (prev.line + 1 = x.line) THEN x.sub := prev.sub
        ELSE x.sub := x
        END;
        x.ref.last := x
      END;
      IF start THEN x.sub.on := TRUE END;
      IF x.col > x.sub.limit THEN x.sub.limit := x.col END
    END;
    x := x.link
  END;
  changed := FALSE; x := r.met;
  WHILE x # NIL DO
    IF (x.kind = pad) & ~x.excluded & (x.sub.n # x.sub.limit) THEN
      x.sub.n := x.sub.limit; changed := TRUE
    END;
    x := x.link
  END;
  RETURN changed
END Columns;

(* d laid out within width columns, ending with one line break.

   Every layout decision ignores the extra spaces of alignment, so the
   lines are the same with or without them, and the extra spaces only move
   text right. The renderer renders d again until no line is too long
   because of them: first with the author's spaces (Widen), turning off
   those of a line that is too long; then with the runs opp lines up
   (Pad), turning off a run with a line too long, until their columns
   settle. The author's spaces come first so that formatting the output
   again gives the same output. *)
PROCEDURE Render*(d: Doc; width: LONGINT): OppText.Buffer;
  VAR
    r: Renderer; strict, end, any: BOOLEAN; x: Doc; n: INTEGER;
BEGIN
  Propagate(d, strict, end);
  r.lineCol := NIL; r.first := TRUE; r.lineUp := FALSE;
  Pass(d, width, r);
  IF r.met = NIL THEN RETURN r.out END;
  r.first := FALSE;
  Exclude(r);
  REPEAT Pass(d, width, r) UNTIL ~Blame(r);
  any := FALSE; x := r.met;
  WHILE x # NIL DO
    IF (x.kind = pad) & ~x.excluded THEN any := TRUE END;
    x := x.link
  END;
  IF any THEN
    r.lineUp := TRUE; any := Columns(r, TRUE); n := 0;
    REPEAT
      Pass(d, width, r); INC(n);
      any := Blame(r);
      IF Columns(r, FALSE) THEN any := TRUE END
    UNTIL ~any OR (n = 20);
    IF any THEN (* they did not settle: none lined up *)
      x := r.met;
      WHILE x # NIL DO
        IF (x.kind = pad) & ~x.excluded THEN x.sub.on := FALSE END;
        x := x.link
      END;
      Pass(d, width, r)
    END
  END;
  RETURN r.out
END Render;

END OppDoc.
