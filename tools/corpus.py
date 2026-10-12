#!/usr/bin/env python3
"""make corpus: format large bodies of real Oberon with opp and check it.

usage: corpus.py OPP KNOWN-ERRORS DIRECTORY ...

Formats every .Mod file under each DIRECTORY (the files git tracks there,
or every one if it is not a git repository) in all three modes, and with
--case-bar add and drop, at widths 60, 80 and 120, and checks for each
that

  - opp succeeds: no syntax error (unless KNOWN-ERRORS lists the file) and
    no internal error, which means opp's own safety check passed;
  - formatting the output again changes nothing;
  - no line ends in white space.

It reports how many lines are still longer than the width: those holding
a string or a comment, which opp cannot break, are only counted; any other
is listed. It exits 1 if a check failed. A DIRECTORY that does not exist
is skipped with a note.

KNOWN-ERRORS lists, one to a line, the ends of the paths of files that are
not valid Oberon, which opp must reject; # starts a comment.
"""

import collections
import concurrent.futures
import os
import re
import subprocess
import sys

MODES = [['-1'], ['-p'], ['-k'], ['-1', '--case-bar', 'add'],
         ['-k', '--case-bar', 'drop']]
WIDTHS = [60, 80, 120]


def module_files(directory):
    try:
        r = subprocess.run(['git', '-C', directory, 'ls-files', '-z', '*.Mod'],
                           capture_output=True, check=True)
        names = [n for n in r.stdout.decode().split('\0') if n]
        return [os.path.join(directory, n) for n in names]
    except (subprocess.CalledProcessError, FileNotFoundError):
        found = []
        for root, _, files in os.walk(directory):
            found += [os.path.join(root, f) for f in files if f.endswith('.Mod')]
        return found


def known_errors(path):
    known = []
    with open(path) as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line:
                known.append(line)
    return known


def code_part(lines):
    """For each line, whether it holds part of a string or a comment, as
    Oberon's nested comments and both quote characters run across lines."""
    depth = 0
    marks = []
    for line in lines:
        special = depth > 0
        i = 0
        while i < len(line):
            two = line[i:i + 2]
            if two == '(*':
                depth += 1; special = True; i += 2
            elif two == '*)' and depth > 0:
                depth -= 1; i += 2
            elif depth == 0 and line[i] in '"\'':
                end = line.find(line[i], i + 1)
                special = True
                i = len(line) if end < 0 else end + 1
            else:
                i += 1
        marks.append(special)
    return marks


def module_body(text):
    """text up to the period that ends the module, which opp writes at the
    start of a line as END name.: the text after it is not opp's."""
    lines = text.split('\n')
    for i, line in enumerate(lines):
        m = re.match(r'END [A-Za-z_$][A-Za-z0-9_$]*\.', line)
        if m:
            return lines[:i] + [line[:m.end()]]
    return lines


def check(opp, path, args, width, known):
    """The problems with formatting path, and the long lines of the output."""
    problems, long_special, long_code = [], 0, []
    r = subprocess.run([opp] + args + [path], capture_output=True)
    if r.returncode != 0:
        expected = r.returncode == 1 and any(path.endswith(k) for k in known)
        if not expected:
            problems.append('exit %d: %s' % (r.returncode,
                                                r.stderr.decode('utf-8', 'replace').strip()))
        return problems, long_special, long_code
    if any(path.endswith(k) for k in known):
        problems.append('formatted, but listed as a known error')
    out = r.stdout
    again = subprocess.run([opp] + args, input=out, capture_output=True)
    if again.returncode != 0 or again.stdout != out:
        problems.append('not idempotent')
    text = out.decode('utf-8', 'replace')
    body = module_body(text)
    for n, (line, special) in enumerate(zip(body, code_part(body)), 1):
        if line != line.rstrip():
            problems.append('line %d ends in white space' % n)
        if len(line) > width:
            if special:
                long_special += 1
            else:
                long_code.append('%s:%d: %s' % (path, n, line))
    return problems, long_special, long_code


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    opp = os.path.abspath(sys.argv[1])
    known = known_errors(sys.argv[2])
    paths = []
    for d in sys.argv[3:]:
        if os.path.isdir(d):
            paths += sorted(module_files(d))
        else:
            print('corpus: skipping %s, which does not exist' % d)
    print('corpus: %d files' % len(paths))
    failed = False
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 4) as pool:
        for mode in MODES:
            for width in WIDTHS:
                args = mode + ['-w', str(width)]
                jobs = {pool.submit(check, opp, p, args, width, known): p for p in paths}
                stats = collections.Counter()
                code_lines = []
                for job in concurrent.futures.as_completed(jobs):
                    problems, special, code = job.result()
                    for p in problems:
                        print('FAILED %s %s: %s' % (' '.join(args), jobs[job], p))
                    stats['failed' if problems else 'ok'] += 1
                    stats['long lines with a string or comment'] += special
                    stats['other long lines'] += len(code)
                    code_lines += code
                if stats['failed']:
                    failed = True
                print('opp %s: %s' % (' '.join(args),
                                      ', '.join('%d %s' % (n, k) for k, n in sorted(stats.items()))))
                for line in sorted(code_lines):
                    print('  long: ' + line)
    print('corpus: %s' % ('FAILED' if failed else 'ok'))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
