#!/bin/bash
# Check opp --in-place, which the fixtures cannot: it changes files.  Works
# on copies of inputs in tests/data/, in a temporary directory, and reports
# "in-place: N ok, M failed".  Like run-tests.sh, it runs Opp from BINDIR,
# relative to the directory above (default: that directory itself).

cd "$(dirname "$0")/.." || exit 2
root=$(pwd)
bindir=${BINDIR:-.}
case $bindir in
  /*) opp=$bindir/Opp ;;
  *)  opp=$root/$bindir/Opp ;;
esac
data=$root/tests/data
export XDG_CONFIG_HOME=$data/config/none   # no user's opp.conf

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

ok=0
failed=0
check () {   # check DESCRIPTION COMMAND...: one check, passed if COMMAND succeeds
  local what=$1; shift
  if "$@"; then
    ok=$((ok + 1))
  else
    failed=$((failed + 1))
    echo "FAILED: in-place: $what"
  fi
}

# One file to format, one already formatted (with an old time, which must
# not change), and one with a syntax error.
cp "$data/fmt-statements.Mod" "$tmp/a.Mod"
cp "$data/formatted.Mod" "$tmp/b.Mod"
touch -d '2001-01-01 00:00' "$tmp/b.Mod"
cp "$data/fmt-error-paren.Mod" "$tmp/c.Mod"
(cd "$tmp" && "$opp" --in-place a.Mod b.Mod c.Mod) > "$tmp/out" 2>&1
status=$?
check "exit status 1 for the syntax error (got $status)" test "$status" -eq 1
check "the syntax error reported" \
  grep -qx "c.Mod:3:14: expected ')', found ';'" "$tmp/out"
check "nothing else written" test "$(wc -l < "$tmp/out")" -eq 1
check "the file formatted" cmp -s "$tmp/a.Mod" "$data/formatted.Mod"
check "the formatted file left alone" \
  test "$(date -r "$tmp/b.Mod" +%Y)" = 2001
check "the file with the error untouched" cmp -s "$tmp/c.Mod" "$data/fmt-error-paren.Mod"
check "no other files left" test "$(ls -A "$tmp" | tr '\n' ' ')" = "a.Mod b.Mod c.Mod out "

# The options apply: --pack.
cp "$data/fmt-statements.Mod" "$tmp/a.Mod"
"$opp" -p "$tmp/a.Mod" > "$tmp/expected" 2>&1
"$opp" -p --in-place "$tmp/a.Mod" > "$tmp/out" 2>&1
check "--pack --in-place" cmp -s "$tmp/a.Mod" "$tmp/expected"

# A file whose formatting fails the safety check is left as it was.
cp "$data/fmt-statements.Mod" "$tmp/a.Mod"
"$opp" --damage 1 --in-place "$tmp/a.Mod" > "$tmp/out" 2>&1
status=$?
check "exit status 3 for the failed safety check (got $status)" test "$status" -eq 3
check "the file the check failed untouched" cmp -s "$tmp/a.Mod" "$data/fmt-statements.Mod"

# The file is written over, so it keeps its permissions and links.
cp "$data/fmt-statements.Mod" "$tmp/p.Mod"
chmod 600 "$tmp/p.Mod"
ln "$tmp/p.Mod" "$tmp/link.Mod"
"$opp" --in-place "$tmp/p.Mod" > "$tmp/out" 2>&1
check "permissions kept" test "$(stat -c %a "$tmp/p.Mod")" = 600
check "a hard link sees the new text" cmp -s "$tmp/link.Mod" "$data/formatted.Mod"
check "no backup left" test ! -e "$tmp/p.Mod.opp-backup"
rm -f "$tmp/p.Mod" "$tmp/link.Mod"

# A file opp cannot write, or whose backup it cannot write, is left alone
# (permissions do not stop root, so not when run as root).
if [ "$(id -u)" -ne 0 ]; then
  cp "$data/fmt-statements.Mod" "$tmp/r.Mod"
  chmod 444 "$tmp/r.Mod"
  "$opp" --in-place "$tmp/r.Mod" > "$tmp/out" 2>&1
  status=$?
  check "exit status 1 for a read-only file (got $status)" test "$status" -eq 1
  check "a read-only file untouched" cmp -s "$tmp/r.Mod" "$data/fmt-statements.Mod"
  check "no backup of a read-only file" test ! -e "$tmp/r.Mod.opp-backup"
  mkdir "$tmp/ro"
  cp "$data/fmt-statements.Mod" "$tmp/ro/s.Mod"
  chmod 555 "$tmp/ro"
  "$opp" --in-place "$tmp/ro/s.Mod" > "$tmp/out" 2>&1
  status=$?
  chmod 755 "$tmp/ro"
  check "exit status 1 when the backup cannot be written (got $status)" test "$status" -eq 1
  check "a file whose backup cannot be written untouched" \
    cmp -s "$tmp/ro/s.Mod" "$data/fmt-statements.Mod"
fi

echo "in-place: $ok ok, $failed failed"
[ "$failed" -eq 0 ]
