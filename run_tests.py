#! /usr/bin/env python3

"""Run every testsuite in the tree and report one verdict per case.

Invoked by `alr test`; also usable on its own from the repository root.

Two kinds of case:

* the `minicoro` tests are self-checking -- they print `ok`/`FAIL` lines and
  a final verdict, so a case passes when the program exits 0 and prints no
  line beginning with `FAIL`;
* the `coroutines` and `generators` tests are golden-output cases, compared
  against the matching file in the suite's `ref/` directory.

Output is normalised to LF before comparing. The reference files have LF
endings and the executables emit CRLF on Windows; comparing raw bytes there
reports every case as a difference and says nothing about the code.
"""

import os
import subprocess
import sys


ROOT = os.path.dirname(os.path.abspath(__file__))

#  (suite directory, executable, argv tail, reference file or None)
SUITES = (
    ("minicoro/tests", (
        ("test_golden", [], None),
        ("test_coro", [], None),
    )),
    ("coroutines/tests", (
        ("test_empty", [], "test_empty"),

        ("test_kill_main", [], "test_kill_main"),
        ("test_kill_twice", [], "test_kill_twice"),
        ("test_foreign_kill", [], "test_foreign_kill"),

        ("test_delegate_nonlocal_ref", [], "test_delegate_nonlocal_ref"),

        ("test_spawn_twice", [], "test_spawn_twice"),
        ("test_spawn_exit", [], "test_spawn_exit"),
        ("test_spawn_kill", [], "test_spawn_kill"),
        ("test_spawn_switch_exit", [], "test_spawn_switch_exit"),
        ("test_spawn_switch_kill", [], "test_spawn_switch_kill"),

        ("test_switch_dead", [], "test_switch_dead"),
        ("test_switch_self", [], "test_switch_self"),

        ("test_resume_simple", [], "test_resume_simple"),
        ("test_resume_chained", [], "test_resume_chained"),
        ("test_resume_parent_dead", [], "test_resume_parent_dead"),

        ("test_reference_loop", [], "test_reference_loop"),
        ("test_secondary_stack", [], "test_secondary_stack"),
    )),
    ("generators/tests", (
        ("test_empty", [], "test_empty"),
        ("test_once_kill", [], "test_once_kill"),
        ("test_twice_kill", [], "test_twice_kill"),
        ("test_stop_resume", [], "test_stop_resume"),
        ("test_complete", ["0"], "test_complete_0"),
        ("test_complete", ["1"], "test_complete_1"),
        ("test_complete", ["2"], "test_complete_2"),
        ("test_chained", [], "test_chained"),
    )),
)

GREEN = "\x1b[32m"
RED = "\x1b[31m"
RESET = "\x1b[0m"


def colour(text, code):
    return text if not sys.stdout.isatty() else code + text + RESET


def executable(suite_dir, name):
    """Path of a test program, with or without the Windows suffix."""
    base = os.path.join(ROOT, suite_dir, "exe", name)
    return base + ".exe" if os.path.exists(base + ".exe") else base


def run(suite_dir, name, argv):
    """Run one test program, returning (exit status, LF-normalised output)."""
    exe = executable(suite_dir, name)
    if not os.path.exists(exe):
        return None, "not built: " + exe

    with open(os.devnull, "rb") as devnull:
        proc = subprocess.run(
            [exe] + argv,
            cwd=os.path.join(ROOT, suite_dir),
            stdin=devnull,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    return proc.returncode, proc.stdout.decode("utf-8", "replace") \
                                       .replace("\r\n", "\n")


def check(suite_dir, name, argv, ref):
    """Run one case and say why it failed, or None if it passed."""
    status, output = run(suite_dir, name, argv)

    if status is None:
        return output
    if status != 0:
        return "exit status {}".format(status)

    if ref is None:
        bad = [ln for ln in output.splitlines() if ln.startswith("FAIL")]
        return bad[0] if bad else None

    path = os.path.join(ROOT, suite_dir, "ref", ref)
    with open(path, "r", encoding="utf-8", newline="") as f:
        expected = f.read().replace("\r\n", "\n")

    return None if output == expected else "output differs from ref/" + ref


def main():
    failures = 0
    total = 0

    for suite_dir, cases in SUITES:
        print("== " + suite_dir)
        passed = 0

        for name, argv, ref in cases:
            total += 1
            label = " ".join([name] + argv)
            reason = check(suite_dir, name, argv, ref)

            if reason is None:
                passed += 1
                print("  " + colour("OK  ", GREEN) + " " + label)
            else:
                failures += 1
                print("  " + colour("FAIL", RED) + " " + label
                      + "  (" + reason + ")")

        print("   {}/{} passed".format(passed, len(cases)))
        print("")

    print("{}/{} passed".format(total - failures, total))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
