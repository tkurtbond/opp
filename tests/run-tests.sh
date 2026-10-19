#!/bin/bash
# Run the fixtures in this directory against the programs and
# report how many passed.  With -v, also announce each test and its
# outcome as it goes.  With -o, do that and also show what each program
# actually printed (everything it wrote, exactly as it wrote it, and its
# exit status), whether the test passed or not.  Any other arguments name
# the tests to run, instead of all of them; each may be a bare NAME,
# NAME.test, or tests/NAME.test.
# The programs are run from BINDIR, relative to the directory above
# (default: voc-build, where the GNUmakefile builds them), so a build made
# elsewhere can be tested too.
#
#   tests/run-tests.sh -o opp-help opp-width-range
#
# A fixture is tests/NAME.test, with these lines, in this order:
#
#   program NAME     the program to run, in BINDIR
#   arg VALUE        one command line argument; repeat for each argument
#                    (a bare "arg" is an empty argument)
#   env NAME=VALUE   set an environment variable for the program; repeat
#                    for each variable (optional)
#   dir DIRECTORY    run the program in this directory (optional)
#   input FILE       the program's standard input, relative to DIRECTORY
#                    (optional; default /dev/null, so no test can hang
#                    waiting on the terminal)
#   status N         the expected exit status
#   output           everything after this line is the expected output
#
# Lines starting with # before "output" are comments.  Trailing white
# space is ignored when comparing output, and so are the "Terminated by
# Halt(N)." lines that voc's runtime prints after a HALT (poc's does not).
# Programs are run by their full path, which they may print as their name,
# so that is replaced by the bare NAME in what they print.  Both the
# output and the error output are compared, mixed together.

verbose=0
show=0
while getopts vo opt; do
  case $opt in
    v) verbose=1 ;;
    o) verbose=1; show=1 ;;
    *) echo "usage: $0 [-v] [-o] [TEST...]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

bindir=${BINDIR:-voc-build}

cd "$(dirname "$0")/.." || exit 2
root=$PWD

# A user's own opp.conf must not change what the fixtures show: opp looks
# for it in this directory, which does not exist, unless a fixture says.
export XDG_CONFIG_HOME=$root/tests/data/config/none

fixtures=()
if [ $# -eq 0 ]; then
  fixtures=(tests/*.test)
else
  for arg; do
    fixture=tests/$(basename "$arg" .test).test
    if [ ! -f "$fixture" ]; then
      echo "$0: no such test: $arg" >&2
      exit 2
    fi
    fixtures+=("$fixture")
  done
fi

ok=0
failed=0
failures=()

strip () { sed -e 's/[[:space:]]*$//' -e '/^Terminated by Halt(.*)\.$/d'; }

# Show what the program printed, for -o.
show_output () {
  echo "  output (exit status $got):"
  if [ -n "$raw" ]; then
    printf '%s\n' "$raw" | sed 's/^/    /'
  else
    echo "    (none)"
  fi
}

for fixture in "${fixtures[@]}"; do
  name=$(basename "$fixture" .test)
  program=
  status=
  dir=.
  input=/dev/null
  args=()
  envs=()
  while IFS= read -r line; do
    case $line in
      '#'*)      ;;
      'program '*) program=${line#program } ;;
      arg)       args+=("") ;;
      'arg '*)   args+=("${line#arg }") ;;
      'env '*)   envs+=("${line#env }") ;;
      'dir '*)   dir=${line#dir } ;;
      'input '*) input=${line#input } ;;
      'status '*)  status=${line#status } ;;
      output)    break ;;
    esac
  done < "$fixture"

  expected=$(sed '1,/^output$/d' "$fixture" | strip)
  case $bindir in
    /*) exe=$bindir/$program ;;
    *)  exe=$root/$bindir/$program ;;
  esac
  raw=$(cd "$dir" && env "${envs[@]}" "$exe" "${args[@]}" < "$input" 2>&1)
  got=$?
  raw=${raw//"$exe"/$program}
  actual=$(printf '%s\n' "$raw" | strip)

  if [ "$got" = "$status" ] && [ "$actual" = "$expected" ]; then
    ok=$((ok + 1))
    if [ "$verbose" -eq 1 ]; then
      echo "ok: $name"
      [ "$show" -eq 1 ] && show_output
    fi
  else
    failed=$((failed + 1))
    failures+=("$name")
    echo "FAILED: $name  ($program ${args[*]})"
    [ "$show" -eq 1 ] && show_output
    [ "$got" = "$status" ] || echo "  exit status: expected $status, got $got"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/  /'
  fi
done

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
