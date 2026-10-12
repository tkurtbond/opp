(* before the module *)

(* after a blank line *)
MODULE Comments; (* trailing *) (* two trailing *)
  (* leading, own line *)
  CONST a = 1; (* trailing,
    on two lines *) b = 2;

  (* nested (* inner *) still outer *)
  VAR x (* between *) : INTEGER;
END Comments. (* after the end *)
