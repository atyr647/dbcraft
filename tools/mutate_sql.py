#!/usr/bin/env python3
"""Mutation check for the SQL tests: write a mutated copy of an sql file (regex substitution, must apply) to stdout.
usage: mutate_sql.py FILE REGEX REPLACEMENT > mutant.sql ; then apply it to a scratch database made from a migrated template and run the test against it: it must FAIL.
(tests/bench/mobs2/mutate.sh does all of it.)"""
import re, sys

s = open(sys.argv[1]).read()
out, n = re.subn(sys.argv[2], sys.argv[3], s, flags=re.S)
if n == 0:
    sys.exit("mutation did not apply")
sys.stdout.write(out)
