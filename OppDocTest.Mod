MODULE OppDocTest;

(* Checks of OppDoc, the layout engine, in the style of RopeTest: one line
   "ok - name" or "not ok - name" for each check, then "N/M tests passed.",
   and exit status 1 if any failed. A failure shows what was expected and
   what was rendered, with line breaks as "|".

   In the strings given to T, "|" stands for a line break and "~" for a
   tab, since Oberon strings have no escapes. *)

IMPORT Out, Platform, OppText, D := OppDoc;

VAR passed, total: INTEGER;

(* s, with "|" as a line break and "~" as a tab. *)
PROCEDURE T(s: ARRAY OF CHAR): OppText.Text;
  VAR t: OppText.Text; i: LONGINT;
BEGIN
  t := OppText.New(s); i := 0;
  WHILE t[i] # 0X DO
    IF t[i] = "|" THEN t[i] := 0AX ELSIF t[i] = "~" THEN t[i] := 9X END;
    INC(i)
  END;
  RETURN t
END T;

PROCEDURE Show(t: OppText.Text);
  VAR i: LONGINT;
BEGIN
  Out.Char('"'); i := 0;
  WHILE t[i] # 0X DO
    IF t[i] = 0AX THEN
      Out.Char("|")
    ELSIF t[i] = 9X THEN
      Out.Char("~")
    ELSE
      Out.Char(t[i])
    END;
    INC(i)
  END;
  Out.Char('"')
END Show;

(* Renders d within width, and compares it with expected. *)
PROCEDURE Check(name: ARRAY OF CHAR; d: D.Doc; width: LONGINT;
                expected: ARRAY OF CHAR);
  VAR got: OppText.Buffer; want: OppText.Text;
BEGIN
  INC(total);
  got := D.Render(d, width); want := T(expected);
  IF OppText.Equal(got.chars, want) THEN
    INC(passed); Out.String("ok - ")
  ELSE
    Out.String("not ok - ")
  END;
  Out.String(name);
  IF ~OppText.Equal(got.chars, want) THEN
    Out.Ln; Out.String("    expected "); Show(want);
    Out.Ln; Out.String("    got      "); Show(got.chars)
  END;
  Out.Ln
END Check;

PROCEDURE Tx(s: ARRAY OF CHAR): D.Doc;
BEGIN
  RETURN D.Text(s)
END Tx;

(* a Line b, as a group *)
PROCEDURE Pair(a, b: ARRAY OF CHAR): D.Doc;
BEGIN
  RETURN D.Group(D.Cat3(Tx(a), D.Line(), Tx(b)))
END Pair;

(* The first n of "aa", "bb", "cc" and "dd", separated by "," and fill
   separators. (Not a row of an ARRAY OF ARRAY OF CHAR, which voc passes
   wrongly: vishap-bugs 11.) *)
PROCEDURE List(n: INTEGER): D.Doc;
  VAR f: D.FillBuilder; i: INTEGER; item: ARRAY 3 OF CHAR;
BEGIN
  D.InitFill(f);
  FOR i := 0 TO n - 1 DO
    IF i > 0 THEN D.Sep(f) END;
    item[0] := CHR(ORD("a") + i); item[1] := item[0]; item[2] := 0X;
    D.Add(f, Tx(item));
    IF i < n - 1 THEN D.Add(f, Tx(",")) END
  END;
  RETURN D.Fill(f)
END List;

(* A soft break before List(n), aligned. *)
PROCEDURE SoftList(n: INTEGER): D.Doc;
  VAR l: D.Doc;
BEGIN
  l := List(n);
  RETURN D.Cat(D.SoftBreak(l), D.Align(l))
END SoftList;

(* "aa," and then a longer item, in a fill. *)
PROCEDURE ShortLong(): D.Doc;
  VAR f: D.FillBuilder;
BEGIN
  D.InitFill(f);
  D.Add(f, Tx("aa,")); D.Sep(f); D.Add(f, Tx("bbbbbbbbbb"));
  RETURN D.Fill(f)
END ShortLong;

PROCEDURE Basics;
  VAR cafe, want: ARRAY 16 OF CHAR;
BEGIN
  Check("text and a space", D.Cat3(Tx("a"), D.Space(), Tx("b")), 80, "a b|");
  Check("empty document", D.Empty(), 80, "");
  Check("group flat when it fits", Pair("aaa", "bbb"), 10, "aaa bbb|");
  Check("group flat at exactly the width", Pair("aaa", "bbb"), 7, "aaa bbb|");
  Check("group broken when too long", Pair("aaa", "bbb"), 6, "aaa|bbb|");
  cafe := "cafXX"; cafe[3] := 0C3X;
  cafe[4] := 0A9X; (* the e with an acute accent *)
  want := "cafXX ab|"; want[3] := 0C3X; want[4] := 0A9X;
  Check("UTF-8 counts characters, not bytes", Pair(cafe, "ab"), 7, want);
  Check("soft line flat",
        D.Group(
            D.Cat(D.Cat3(Tx("("), D.SoftLine(), Tx("x")),
                  D.Cat(D.SoftLine(), Tx(")")))),
        10, "(x)|");
  Check("soft line broken",
        D.Group(
            D.Cat(D.Cat3(Tx("("), D.SoftLine(), Tx("xx")),
                  D.Cat(D.SoftLine(), Tx(")")))),
        3, "(|xx|)|")
END Basics;

PROCEDURE Indentation;
BEGIN
  Check("nest",
        D.Cat3(Tx("BEGIN"), D.Nest(2, D.Cat(D.HardLine(), Tx("x"))),
               D.Cat(D.HardLine(), Tx("END"))),
        80, "BEGIN|  x|END|");
  Check("nest twice",
        D.Cat(Tx("a"),
              D.Nest(2,
                     D.Cat3(D.HardLine(), Tx("b"),
                            D.Nest(3, D.Cat(D.HardLine(), Tx("c")))))),
        80, "a|  b|     c|");
  Check("align", D.Cat3(Tx("Foo("), D.Align(Pair("aaa", "bbb")), Tx(")")), 8,
        "Foo(aaa|    bbb)|");
  Check("align or nest: aligns left of the limit",
        D.Cat3(Tx("F("), D.AlignOrNest(4, 5, Pair("aaa", "bbb")), Tx(")")), 8,
        "F(aaa|  bbb)|");
  Check("align or nest: nests right of the limit",
      D.Cat3(Tx("LongName("), D.AlignOrNest(4, 5, Pair("aaa", "bbb")), Tx(")")),
      12, "LongName(aaa|    bbb)|");
  Check("soft break: none when the first item fits after it",
        D.Cat3(Tx("Proc("), D.Nest(4, SoftList(2)), Tx(")")), 11,
        "Proc(aa,|     bb)|");
  Check("soft break: a line break when the first item does not fit",
        D.Cat3(Tx("LongerName("), D.Nest(4, SoftList(2)), Tx(")")), 12,
        "LongerName(|    aa, bb)|");
  Check("soft break: nothing when flat",
        D.Group(D.Cat3(Tx("LongerName("), D.Nest(4, SoftList(2)), Tx(")"))), 80,
        "LongerName(aa, bb)|");
  Check("soft break: a first item that fits ignores the items after it",
        D.Cat3(Tx("Name("), D.Nest(4, SoftList(3)), Tx(")")), 9,
        "Name(aa,|     bb,|     cc)|");
  Check("align or nest: aligned when every item fits aligned",
        D.Cat(Tx("NameNameNa("), D.AlignOrNest(4, 40, ShortLong())), 21,
        "NameNameNa(aa,|           bbbbbbbbbb|");
  Check("align or nest: nested when an item fits only nested",
        D.Cat(Tx("NameNameNa("), D.AlignOrNest(4, 40, ShortLong())), 18,
        "NameNameNa(aa,|    bbbbbbbbbb|");
  Check("an empty line has no indentation",
        D.Nest(4, D.Cat3(Tx("a"), D.BlankLine(), Tx("b"))), 80, "a||    b|");
  Check("no space at the end of a line",
        D.Cat(D.Cat3(Tx("a"), D.Space(), D.HardLine()), Tx("b")), 80, "a|b|");
  Check("a flat line at the end of a line leaves no space",
        D.Cat(D.Cat3(Tx("a"), D.Group(D.Line()), D.HardLine()), Tx("b")), 80,
        "a|b|")
END Indentation;

PROCEDURE Groups;
BEGIN
  Check("fits looks past the end of the group",
        D.Cat(Pair("aaaa", "bb"), Tx("))))")), 8, "aaaa|bb))))|");
  Check("fits stops at a line that may break after the group",
        D.Group(D.Cat3(Pair("aaaa", "bb"), D.Line(), Tx("cccccccccc"))), 8,
        "aaaa bb|cccccccccc|");
  Check("a hard line breaks its group",
        D.Group(
            D.Cat(D.Cat3(Tx("a"), D.Line(), Tx("b")),
                  D.Cat(D.HardLine(), Tx("c")))),
        80, "a|b|c|");
  Check("a hard line breaks the groups around it",
        D.Group(
            D.Cat3(Tx("a"), D.Line(),
                   D.Group(D.Cat3(Tx("b"), D.HardLine(), Tx("c"))))),
        80, "a|b|c|");
  Check("outer group breaks, inner stays flat",
        D.Group(
            D.Cat3(Tx("f("),
                   D.Align(
                       D.Cat3(Pair("a", "b"), Tx(","),
                              D.Cat(D.Line(), Tx("ccccccc")))),
                   Tx(")"))),
        10, "f(a b,|  ccccccc)|");
  Check("a flat group keeps its inner groups flat",
        D.Group(D.Cat3(Tx("x"), D.Line(), Pair("y", "z"))), 80, "x y z|")
END Groups;

PROCEDURE LineBreaks;
BEGIN
  Check("two hard lines make one line break",
        D.Cat(D.Cat3(Tx("a"), D.HardLine(), D.HardLine()), Tx("b")), 80,
        "a|b|");
  Check("blank lines in a row make one empty line",
        D.Cat(D.Cat3(Tx("a"), D.BlankLine(), D.BlankLine()),
              D.Cat(D.HardLine(), Tx("b"))),
        80, "a||b|");
  Check("a line left empty counts as the blank line",
        D.Cat(D.Cat3(Tx("a"), D.HardLine(), Tx("")),
              D.Cat(D.BlankLine(), Tx("b"))),
        80, "a||b|");
  Check("no blank line at the start", D.Cat(D.BlankLine(), Tx("a")), 80, "a|");
  Check("a later break's indentation wins",
        D.Cat(D.Nest(4, D.Cat(Tx("a"), D.HardLine())),
              D.Cat(D.HardLine(), Tx("b"))),
        80, "a|b|")
END LineBreaks;

PROCEDURE Fills;
  VAR f: D.FillBuilder;
BEGIN
  Check("fill packs items while they fit", List(4), 9, "aa, bb,|cc, dd|");
  Check("fill flat in a group that fits", D.Group(List(4)), 80,
        "aa, bb, cc, dd|");
  Check("fill counts what follows its last item", D.Cat(List(2), Tx(");")), 7,
        "aa,|bb);|");
  Check("fill: what follows its last item fits exactly",
        D.Cat(List(2), Tx(");")), 8, "aa, bb);|");
  Check("fill nested continues at its indentation",
        D.Cat(Tx("IMPORT"), D.Nest(4, D.Cat(D.Line(), List(4)))), 12,
        "IMPORT|    aa, bb,|    cc, dd|");
  D.InitFill(f);
  D.Add(f, Tx("x;")); D.Sep(f);
  D.Add(f, Pair("long", "tail")); D.Add(f, Tx(";")); D.Sep(f);
  D.Add(f, Tx("y"));
  Check("fill breaks after an item that did not stay on one line", D.Fill(f), 8,
        "x;|long|tail;|y|");
  D.InitFill(f);
  D.Add(f, Tx("a;")); D.Sep(f);
  D.Add(f,
        D.Cat3(Tx("R = RECORD"), D.Nest(2, D.Cat(D.HardLine(), Tx("x: T"))),
               D.Cat(D.HardLine(), Tx("END;"))));
  Check("fill: an item with a line break inside starts a line", D.Fill(f), 80,
        "a;|R = RECORD|  x: T|END;|");
  D.InitFill(f);
  D.Add(f, Tx("a;")); D.Sep(f); D.Add(f, Tx("b;"));
  D.Add(f, D.Cat3(D.Space(), D.Comment(T("(* c *)"), 1), D.HardLine()));
  D.Sep(f); D.Add(f, Tx("d"));
  Check("fill: an item ending in a trailing comment's break shares its line",
        D.Fill(f), 80, "a; b; (* c *)|d|");
  D.InitFill(f);
  D.Add(f, Tx("a;")); D.Break(f); D.Add(f, Tx("b;")); D.Sep(f);
  D.Add(f, Tx("c"));
  Check("fill: a forced break", D.Fill(f), 80, "a;|b; c|");
  D.InitFill(f);
  D.Add(f, Tx("a;")); D.BlankBreak(f); D.Add(f, Tx("b"));
  Check("fill: a forced blank line", D.Fill(f), 80, "a;||b|")
END Fills;

PROCEDURE Choices;
  VAR c: D.Doc;
  PROCEDURE If(c: D.Doc): D.Doc;
  BEGIN
    RETURN D.Group(
        D.Cat3(Tx("IF a THEN"), D.Nest(2, D.Cat(D.ChoiceLine(c), Tx("b"))),
               D.Cat(D.ChoiceLine(c), Tx("END"))))
  END If;

  (* If, with its body kept on the line of THEN *)
  PROCEDURE Kept(c: D.Doc): D.Doc;
  BEGIN
    RETURN D.Group(
        D.Cat3(Tx("IF a THEN"), D.Nest(2, D.Cat(D.KeptLine(c), Tx("b"))),
               D.Cat(D.ChoiceLine(c), Tx("END"))))
  END Kept;
BEGIN
  c := D.NewChoice();
  Check("an undecided choice may be flat", If(c), 80, "IF a THEN b END|");
  c := D.NewChoice(); D.Decide(c, FALSE);
  Check("a choice of flat lines breaks when too long", If(c), 10,
        "IF a THEN|  b|END|");
  c := D.NewChoice(); D.Decide(c, TRUE);
  Check("a choice of hard lines always breaks", If(c), 80,
        "IF a THEN|  b|END|");
  c := D.NewChoice(); D.Decide(c, TRUE);
  Check("a choice of hard lines breaks the groups around it",
        D.Group(D.Cat3(Tx("x"), D.Line(), If(c))), 80, "x|IF a THEN|  b|END|");
  c := D.NewChoice(); D.Decide(c, FALSE);
  Check("a kept line in a flat choice is a choice line", Kept(c), 80,
        "IF a THEN b END|");
  c := D.NewChoice(); D.Decide(c, FALSE);
  Check("a kept line in a flat choice breaks with it", Kept(c), 10,
        "IF a THEN|  b|END|");
  c := D.NewChoice(); D.Decide(c, TRUE);
  Check("a kept line in a hard choice stays when what follows fits", Kept(c),
        11, "IF a THEN b|END|");
  c := D.NewChoice(); D.Decide(c, TRUE);
  Check("a kept line in a hard choice breaks when what follows does not fit",
        Kept(c), 10, "IF a THEN|  b|END|")
END Choices;

PROCEDURE FillWithComment(): D.Doc;
  VAR f: D.FillBuilder;
BEGIN
  D.InitFill(f);
  D.Add(f, Tx("a;")); D.Sep(f);
  D.Add(f, Tx("b;"));
  D.Add(f,
      D.Cat3(D.Space(), D.Comment(T("(* long comment *)"), 1), D.TrailBreak()));
  RETURN D.Fill(f)
END FillWithComment;

PROCEDURE Comments;
BEGIN
  Check("a comment of one line",
        D.Cat3(Tx("x"), D.Space(), D.Comment(T("(* c *)"), 40)), 80,
        "x (* c *)|");
  Check("a comment moved right moves its later lines",
        D.Cat3(Tx("x := 1;"), D.Space(),
               D.Comment(T("(* first|   second *)"), 3)),
        80, "x := 1; (* first|         second *)|");
  Check("a comment moved left moves its later lines",
        D.Comment(T("(* first|            second *)"), 10), 80,
        "(* first|   second *)|");
  Check("a comment's lines never move left of column 1",
        D.Comment(T("(* first|  second *)"), 9), 80, "(* first|second *)|");
  Check("tabs in a comment's indentation count to multiples of 8",
        D.Cat(Tx("    "), D.Comment(T("(* a|~b *)"), 1)), 80,
        "    (* a|            b *)|");
  Check("white space at the end of a comment's lines is dropped",
        D.Comment(T("(* a   |  |   *)"), 1), 80, "(* a||   *)|");
  Check("a comment of several lines breaks its group",
        D.Group(D.Cat3(Tx("a"), D.Line(), D.Comment(T("(* x|y *)"), 1))), 80,
        "a|(* x|y *)|");
  Check("a group ending in a trailing comment's break can be flat",
        D.Cat(
            D.Group(
                D.Cat(D.Cat3(Tx("VAR"), D.Line(), Tx("x;")),
                      D.Cat3(D.Space(), D.Comment(T("(* c *)"), 1),
                             D.TrailBreak()))),
            Tx("y")),
        80, "VAR x; (* c *)|y|");
  Check("a trailing comment's break in the middle breaks its group",
        D.Group(
            D.Cat(D.Cat3(Tx("F(a,"), D.Space(), D.Comment(T("(* c *)"), 1)),
                  D.Cat3(D.TrailBreak(), D.Line(), Tx("b)")))),
        80, "F(a, (* c *)|b)|");
  Check("a comment of one line does not break its group",
        D.Group(D.Cat3(Tx("a"), D.Line(), D.Comment(T("(* x *)"), 1))), 80,
        "a (* x *)|");
  Check("a trailing comment does not break the code before it",
        D.Group(
            D.Cat3(Tx("x :="), D.Line(),
                   D.Cat(Tx("1;"),
                         D.Cat3(D.Space(),
                                D.Comment(T("(* long comment *)"), 1),
                                D.TrailBreak())))),
        12, "x := 1; (* long comment *)|");
  Check(
      "a fill puts an item with a trailing comment on the next line if the comment does not fit",
      FillWithComment(), 20, "a;|b; (* long comment *)|");
  Check("a comment before code on the line is counted",
        D.Group(
            D.Cat3(Tx("x :="), D.Line(),
                   D.Cat3(D.Comment(T("(* long comment *)"), 1), D.Space(),
                          Tx("1;")))),
        12, "x :=|(* long comment *) 1;|")
END Comments;

(* An author's alignment, kept while it fits. *)
PROCEDURE Widths;
BEGIN
  Check("a widened space is kept when the line fits",
        D.Cat(D.Cat3(Tx("a"), D.Space(), D.Widen(4)), Tx("bb")), 80,
        "a    bb|");
  Check("a widened space is one space when the line would not fit",
        D.Cat(D.Cat3(Tx("a"), D.Space(), D.Widen(4)), Tx("bb")), 6, "a bb|");
  Check("a trailing comment counts in whether a widened space fits",
        D.Cat3(D.Cat(Tx("x;"), D.Space()), D.Widen(3),
               D.Comment(T("(* c *)"), 1)),
        11, "x; (* c *)|");
  Check("a widening is measured only up to the next possible break",
        D.Group(
            D.Cat(D.Cat3(Tx("a"), D.Space(), D.Widen(3)),
                  D.Cat3(Tx("b"), D.Line(), Tx("cccc")))),
        6, "a   b|cccc|");
  Check("a widening does not change whether a group breaks",
        D.Group(D.Cat3(Tx("aa"), D.Line(), D.Cat(D.Widen(5), Tx("bb")))), 5,
        "aa bb|");
  Check("a widening after a line break is ignored",
        D.Group(
            D.Cat3(Tx("aaa"), D.Line(),
                   D.Cat3(D.Space(), D.Widen(4), Tx("b")))),
        4, "aaa|b|");
  Check("a line too long without its widening keeps it",
        D.Cat3(D.Cat(Tx("a"), D.Space()), D.Widen(3),
               D.Comment(T("(* long comment *)"), 1)),
        10, "a   (* long comment *)|");
  Check("a widening with no space before it is ignored",
        D.Cat3(Tx("a"), D.Widen(4), Tx("b")), 80, "ab|")
END Widths;

(* "a" and then a pad of run and x, a line break, "bbb", and a pad and y. *)
PROCEDURE TwoPads(run: D.Doc; x, y: ARRAY OF CHAR): D.Doc;
BEGIN
  RETURN D.Cat3(D.Cat3(Tx("a"), D.Space(), D.Pad(run, 0)),
                D.Cat3(Tx(x), D.HardLine(), Tx("bbb")),
                D.Cat3(D.Space(), D.Pad(run, 0), Tx(y)))
END TwoPads;

(* A line, a trailing comment lined up in run, and a line break. *)
PROCEDURE Commented(run: D.Doc; s: ARRAY OF CHAR; blank: BOOLEAN): D.Doc;
  VAR br: D.Doc;
BEGIN
  IF blank THEN br := D.BlankLine() ELSE br := D.HardLine() END;
  RETURN D.Cat3(D.Cat3(Tx(s), D.Space(), D.Pad(run, 0)),
                D.Comment(T("(* c *)"), 1), br)
END Commented;

(* "BEGIN", a KeptLineItem, and a fill of one item: first, and a line
   break and second in it if broken. *)
PROCEDURE BeginItem(first, second: ARRAY OF CHAR; broken: BOOLEAN): D.Doc;
  VAR c, it: D.Doc; f: D.FillBuilder;
BEGIN
  c := D.NewChoice(); D.Decide(c, TRUE);
  it := Tx(first);
  IF broken THEN it := D.Cat3(it, D.HardLine(), Tx(second)) END;
  D.InitFill(f); D.Add(f, it);
  RETURN D.Cat(Tx("BEGIN"), D.Nest(2, D.Cat(D.KeptLineItem(c), D.Fill(f))))
END BeginItem;

(* "BEGIN", a KeptLineItem, and a fill of one item: IF a THEN b END, its
   lines a hard choice's, its condition a group that could break. *)
PROCEDURE BeginChoice(): D.Doc;
  VAR c, h, it: D.Doc; f: D.FillBuilder;
BEGIN
  c := D.NewChoice(); D.Decide(c, TRUE);
  h := D.NewChoice(); D.Decide(h, TRUE);
  it := D.Cat3(Tx("IF"), D.Group(D.Cat3(Tx(" a"), D.Line(), Tx("THEN"))),
               D.Nest(2, D.Cat(D.ChoiceLine(h), Tx("b"))));
  it := D.Cat3(it, D.ChoiceLine(h), Tx("END"));
  D.InitFill(f); D.Add(f, D.Group(it));
  RETURN D.Cat(Tx("BEGIN"), D.Nest(2, D.Cat(D.KeptLineItem(c), D.Fill(f))))
END BeginChoice;

(* What opp lines up itself. *)
PROCEDURE Pads;
  VAR run, d, a, p: D.Doc;
BEGIN
  Check("pads line up", TwoPads(D.NewRun(FALSE), "x", "y"), 80, "a   x|bbb y|");
  run := D.NewRun(FALSE);
  d := D.Cat3(D.Cat3(Tx("bbb"), D.Space(), D.Pad(run, 0)), Tx("x"),
              D.Cat3(D.HardLine(), Tx("a"), D.Space()));
  Check("pads line up at the furthest column, wherever it is",
        D.Cat3(d, D.Pad(run, 0), Tx("y")), 80, "bbb x|a   y|");
  Check("a run that would make a line too long is not lined up",
        TwoPads(D.NewRun(FALSE), "xxxx", "y"), 7, "a xxxx|bbb y|");
  run := D.NewRun(FALSE);
  d := D.Cat3(D.Cat3(Tx("a"), D.Space(), D.Pad(run, 0)), Tx("x"),
              D.Cat3(D.Space(), D.Pad(run, 3), Tx("y")));
  d := D.Cat3(d, D.HardLine(), D.Cat3(Tx("bbbbbb"), D.Space(), D.Pad(run, 0)));
  Check("pads sharing a line are left out of their run, with the author's gap",
        D.Cat(d, Tx("z")), 80, "a x   y|bbbbbb z|");
  run := D.NewRun(TRUE);
  d := D.Cat3(Commented(run, "a", FALSE), Commented(run, "bbb", TRUE),
              Commented(run, "cc", FALSE));
  Check("trailing comments line up on lines next to each other", d, 80,
        "a   (* c *)|bbb (* c *)||cc (* c *)|");
  run := D.NewRun(TRUE);
  d := D.Cat3(D.Cat3(Tx("a"), D.Space(), D.Pad(run, 2)),
              D.Comment(T("(* c *)"), 1), D.Cat(D.Space(), Tx("b")));
  d := D.Cat3(d, D.HardLine(), Commented(run, "ccc", FALSE));
  Check("a comment with text after it is left out, with the author's gap", d,
        80, "a  (* c *) b|ccc (* c *)|");
  run := D.NewRun(FALSE);
  a := D.Anchor(); p := D.Pad(run, 0); D.SetAnchor(p, a);
  d := D.Cat3(D.Cat(Tx("f;"), D.Space()), a,
              D.Cat3(Tx("bbbbbb"), D.Space(), p));
  a := D.Anchor(); p := D.Pad(run, 0); D.SetAnchor(p, a);
  d := D.Cat3(D.Cat3(d, Tx("x"), D.HardLine()), a,
              D.Cat3(Tx("c"), D.Space(), p));
  Check("a pad whose anchor does not start its line is left out of its run",
        D.Cat(d, Tx("y")), 80, "f; bbbbbb x|c y|");
  Check("a widening that pushes a later aligned line too far is dropped",
        D.Cat3(D.Cat3(Tx("a"), D.Space(), D.Widen(3)),
               D.Align(D.Group(D.Cat3(Tx("bb"), D.Line(), Tx("cccc")))),
               D.Empty()),
        6, "a bb|  cccc|");
  Check("a widening that keeps every line within the width is kept",
        D.Cat3(D.Cat3(Tx("a"), D.Space(), D.Widen(3)),
               D.Align(D.Group(D.Cat3(Tx("bb"), D.Line(), Tx("cc")))),
               D.Empty()),
        6, "a   bb|    cc|")
END Pads;

(* Adds to the grid g a cell, name and then "= " and value, and to f, the
   grid's layout, the same, after a line break if newRow, and otherwise
   after a fill separator; with comment after it unless that is empty.
   first says that it is the first cell. *)
PROCEDURE Cell(g: D.Doc; VAR f: D.FillBuilder;
               name, value, comment: ARRAY OF CHAR; first, newRow: BOOLEAN);
  VAR n, r, t: D.Doc;
BEGIN
  n := D.Nest(0, Tx(name));
  r := D.Nest(0, D.Cat3(Tx("="), D.Space(), Tx(value)));
  t := NIL;
  IF comment # "" THEN
    t := D.Nest(0, D.Cat3(D.Space(), D.Comment(T(comment), 1), D.TrailBreak()))
  END;
  D.AddCell(g, n, r, t, newRow);
  IF first THEN
  ELSIF newRow THEN D.Break(f)
  ELSE D.Sep(f)
  END;
  D.Add(f, D.Cat3(n, D.Space(), r)); D.Add(f, t)
END Cell;

(* "CONST" and the grid g, with the layout f, on the lines below it, or on
   its line if group and they fit there. *)
PROCEDURE Section(g: D.Doc; VAR f: D.FillBuilder; group: BOOLEAN): D.Doc;
BEGIN
  D.SetLayout(g, D.Fill(f));
  IF group THEN RETURN D.Group(
        D.Cat(Tx("CONST"), D.Nest(2, D.Cat(D.Line(), g))))
  END;
  RETURN D.Cat(Tx("CONST"), D.Nest(2, D.Cat(D.HardLine(), g)))
END Section;

(* A grid of a = 1;, bbb = 22;, cc = 3; and d = 4444;, in one row of the
   source if rows. *)
PROCEDURE FourCells(rows: BOOLEAN): D.Doc;
  VAR g: D.Doc; f: D.FillBuilder;
BEGIN
  g := D.NewGrid(rows); D.InitFill(f);
  Cell(g, f, "a", "1;", "", TRUE, TRUE);
  Cell(g, f, "bbb", "22;", "", FALSE, FALSE);
  Cell(g, f, "cc", "3;", "", FALSE, FALSE);
  Cell(g, f, "d", "4444;", "", FALSE, FALSE);
  RETURN Section(g, f, FALSE)
END FourCells;

(* Declarations lined up in columns. *)
PROCEDURE Grids;
  VAR g: D.Doc; f: D.FillBuilder;
BEGIN
  Check("a grid has as many columns as fit", FourCells(FALSE), 21,
        "CONST|  a  = 1; bbb = 22;|  cc = 3; d   = 4444;|");
  Check("a grid has one column when two do not fit", FourCells(FALSE), 20,
        "CONST|  a   = 1;|  bbb = 22;|  cc  = 3;|  d   = 4444;|");
  g := D.NewGrid(TRUE); D.InitFill(f);
  Cell(g, f, "a", "1;", "", TRUE, TRUE);
  Cell(g, f, "bbb", "22;", "", FALSE, FALSE);
  Cell(g, f, "cc", "3;", "", FALSE, TRUE);
  Check("a grid keeps the source's rows when they fit", Section(g, f, FALSE),
        80, "CONST|  a  = 1; bbb = 22;|  cc = 3;|");
  Check("a grid whose source's rows do not fit has as many columns as fit",
        FourCells(TRUE), 21,
        "CONST|  a  = 1; bbb = 22;|  cc = 3; d   = 4444;|");
  g := D.NewGrid(FALSE); D.InitFill(f);
  Cell(g, f, "a", "1;", "", TRUE, TRUE);
  Cell(g, f, "b", "2;", "", FALSE, FALSE);
  Check("a flat grid is its layout", Section(g, f, TRUE), 80,
        "CONST a = 1; b = 2;|");
  g := D.NewGrid(FALSE); D.InitFill(f);
  Cell(g, f, "a", "1;", "(* c *)", TRUE, TRUE);
  Cell(g, f, "bbb", "2;", "", FALSE, FALSE);
  Cell(g, f, "c", "3;", "", FALSE, FALSE);
  Check("a trailing comment in a grid ends its row", Section(g, f, FALSE), 80,
        "CONST|  a   = 1; (* c *)|  bbb = 2; c = 3;|");
  g := D.NewGrid(FALSE); D.InitFill(f);
  Cell(g, f, "aaaa", "1;", "", TRUE, TRUE);
  Cell(g, f, "b", "2;", "(* c *)", FALSE, FALSE);
  Check("a trailing comment counts in how many columns fit",
        Section(g, f, FALSE), 20, "CONST|  aaaa = 1;|  b    = 2; (* c *)|");
  g := D.NewGrid(FALSE); D.InitFill(f);
  Cell(g, f, "aaaa", "1;", "", TRUE, TRUE);
  Cell(g, f, "b", "2;", "(* a longer comment *)", FALSE, FALSE);
  Check("a trailing comment too long for any row does not count",
        Section(g, f, FALSE), 20,
        "CONST|  aaaa = 1; b = 2; (* a longer comment *)|");
  g := D.NewGrid(FALSE); D.InitFill(f);
  Cell(g, f, "a", "1;", "", TRUE, TRUE);
  Cell(g, f, "bb", "2;", "", FALSE, FALSE);
  Cell(g, f, "c", "333333;", "", FALSE, FALSE);
  Cell(g, f, "ddd", "4;", "", FALSE, FALSE);
  Check("a cell wider than half the line has a row of its own",
        Section(g, f, FALSE), 22,
        "CONST|  a   = 1; bb = 2;|  c   = 333333;|  ddd = 4;|")
END Grids;

(* The line after BEGIN. *)
PROCEDURE Begins;
BEGIN
  Check("a first statement that fits goes on BEGIN's line",
        BeginItem("x := 1", "", FALSE), 20, "BEGIN x := 1|");
  Check("a first statement that does not fit goes on the next line",
        BeginItem("x := 1000000", "", FALSE), 12, "BEGIN|  x := 1000000|");
  Check("a first statement of several lines goes on the next line",
        BeginItem("IF a THEN", "END", TRUE), 80, "BEGIN|  IF a THEN|  END|");
  Check("a first statement broken by its choice goes on the next line",
        BeginChoice(), 80, "BEGIN|  IF a THEN|    b|  END|")
END Begins;

BEGIN
  passed := 0; total := 0;
  Basics; Indentation; Groups; LineBreaks; Fills; Choices; Comments;
  Widths; Pads; Grids; Begins;
  Out.Int(passed, 0); Out.Char("/"); Out.Int(total, 0);
  Out.String(" tests passed."); Out.Ln;
  Out.Flush;
  IF passed # total THEN Platform.Exit(1) END
END OppDocTest.
