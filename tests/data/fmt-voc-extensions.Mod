MODULE VocExtensions;
  IMPORT SYSTEM;
  TYPE
    Untraced* = POINTER [1] TO UntracedDesc;
    UntracedDesc* = RECORD [1] END;
    CProc = PROCEDURE [1] (x: INTEGER);
    Buf = ARRAY [1] 16 OF CHAR;
  VAR modules-: SYSTEM.PTR;
  PROCEDURE -includeStdio "#include <stdio.h>";
  PROCEDURE -Halt(code: LONGINT) "exit(code)";
  PROCEDURE -Bytes 0E8H, 12H, 34H;
  PROCEDURE +Interrupt; BEGIN END Interrupt;
  PROCEDURE *Marked; BEGIN END Marked;
  PROCEDURE WriteString*(s: ARRAY [1] OF CHAR; x-: INTEGER);
  BEGIN IF 1THEN END END WriteString;
END VocExtensions.
