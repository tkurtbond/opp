MODULE M;
BEGIN
  CASE ch OF
  | "a": x := 1 (* one *)
  | "b", "c": x := 2
  ELSE x := 3
  END;
  CASE n OF 0: x := 1 | 1: x := 2 END;
  CASE n OF | | 0: x := 1 END;
  CASE n OF | ELSE x := 0 END
END M.
