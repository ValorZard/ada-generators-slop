# CLAUDE.md

Working notes for this repository. `README.md` explains the design to a
reader; this file records what you need to *operate* on the tree — how to
build, test and prove it, and the traps that cost time.

## What this repo is

A prototype for Ada generators/coroutines, in four layers, bottom up:

| Directory     | Unit                    | SPARK | Role                                        |
|---------------|-------------------------|-------|---------------------------------------------|
| `minicoro/`   | `Minicoro`              | yes   | coroutine lifecycle + per-coroutine byte stack |
|               | `Minicoro.Machine_Code`  | yes   | x86-64 instruction encoder, switch listing  |
|               | `Minicoro.FTAL`          | yes   | ghost register/stack typing model (all Ghost) |
|               | `Minicoro.Contexts`      | spec  | **private child**; trusted context switch   |
|               | `Minicoro.Code_Page`     | no    | W^X page from the OS                        |
| `coroutines/` | `Coroutines`             | no    | ref-counted, GNAT-runtime-integrated wrapper |
| `generators/` | `Generators`             | no    | generator API over `Coroutines`             |

`minicoro/` replaced a thin binding to PCL (the old `pcl/` directory, deleted).
The `generators/` layer was untouched by that swap — the change is confined to
`Coroutines` and below.

## Toolchain

Nothing is on `PATH` by default. Everything comes from Alire's cache. Source
this before any build/prove command:

```sh
export GNAT_ROOT="$LOCALAPPDATA/alire/cache/toolchains/gnat_native_15.2.1_346e2e00"
export GPR_ROOT="$LOCALAPPDATA/alire/cache/toolchains/gprbuild_25.0.1_1bcdf5e8"
export SPARK_ROOT="$LOCALAPPDATA/alire/cache/releases/gnatprove_16.1.0_f3c62ad9"
export PATH="$GNAT_ROOT/bin:$GPR_ROOT/bin:$SPARK_ROOT/bin:$PATH"
```

- GNAT 15.2.0 (`x86_64-w64-mingw32`), GPRBUILD 25.0.0, GNATprove FSF 16.1.0
  with Alt-Ergo 2.6.1, cvc5 1.3.2, Z3 4.15.4.
- Older versions (`gnat_native_15.1.2`, `gnatprove_15.1.0`) are also in the
  cache; prefer the ones above.
- `gnatprove --version` prints the version and *then* raises
  `ADA.IO_EXCEPTIONS.DEVICE_ERROR`. Harmless, ignore it.

Projects find each other through `GPR_PROJECT_PATH`:

```sh
export GPR_PROJECT_PATH="/c/github/ada-generators/minicoro:/c/github/ada-generators/coroutines:/c/github/ada-generators/generators"
```

## Build and test

```sh
cd minicoro/tests    && gprbuild -q -P tests.gpr && ./exe/test_golden.exe && ./exe/test_coro.exe
cd coroutines/tests  && gprbuild -q -P tests.gpr
cd generators/tests  && gprbuild -q -P tests.gpr
```

**`run.py` reports every test as DIFF on Windows.** The reference files in
`ref/` have LF endings; the executables emit CRLF. `run.py` compares bytes. It
is not wrong about anything else — normalise before comparing:

```sh
for t in $(ls ref/); do
  o=$("./exe/$t.exe" 2>&1 | tr -d '\r'); r=$(cat "ref/$t")
  [ "$o" = "$r" ] && echo "OK   $t" || echo "DIFF $t"
done
```

`generators/tests` has parameterised cases: `test_complete` runs with argument
`0`, `1`, `2` against `ref/test_complete_{0,1,2}`.

Expected: **17/17 coroutines, 8/8 generators, 2/2 minicoro.**

## Proving

```sh
cd minicoro && gnatprove -P minicoro.gpr --level=2 -j4 --report=fail
```

Expected: `Success: all checks proved (482 checks)` with **1 justified, 0
unproved**. Takes roughly 10-20 minutes — run it in the background, do not
poll it. `--level=3` also passes; `--report=statistics` if you want per-check
detail.

`obj/gnatprove/gnatprove.out` holds the summary table; read lines 5-24.

Do not run `gprbuild` and `gnatprove` on `minicoro/` at the same time — they
share `obj/`.

The single justification is in `Minicoro.Transfer`: SPARK's anti-aliasing rule
(RM 6.4.2) is syntactic and treats `Coros (From).Ctx` and `Coros (To).Ctx` as
possibly the same object because the indices are not static. `Transfer`'s
precondition requires `From /= To`. Written out with `pragma Annotate` at the
call site.

## Traps that cost time

**Ada in bash heredocs.** Tick attributes (`X'First`, `T'Access`) break
`<<'EOF'` quoting — bash reports `unexpected EOF while looking for matching '`.
Use the Write tool for Ada sources, or a Python script for surgical edits.

**Python writes CRLF.** `open(p, 'w')` on Windows translates `\n` to `\r\n`,
and `-gnatyg` rejects that with `(style) incorrect line terminator`. Always
`open(p, 'w', encoding='utf-8', newline='\n')`, and read with `newline=''`.

**`-gnatyg` (in every `.gpr` here) is strict**, and `-gnatwae` makes warnings
fatal. It will reject:
- lines over 79 columns (`awk 'length > 79 {print FILENAME": "FNR}' *.ad?`)
- a subprogram body with no previous declaration in the same body
- two consecutive blank lines
- redundant `with` clauses in a body when the spec already has them
- record types with a representation clause that omits any component

**`gcc -c -gnatc -I. foo.adb`** is the fast semantic check. Do not pass `-o`:
GNAT rejects an object filename that doesn't match the unit name.

**GNATprove-specific rejections** hit during this work:
- `'Access` of a `No_Return` subprogram — not supported. Drop `No_Return`.
- `'Access` of a subprogram with global effects — forbidden. Wrap the
  `'Access` in a small function with `pragma SPARK_Mode (Off)` in its body and
  a `Post => Result /= null`.
- A package body with `SPARK_Mode => Off` must **not** carry `Refined_State`;
  its abstract state stays opaque, which is the intent. Adding one fails with
  "X is undefined" or "X is not visible".
- `Refined_State` constituents must be variables. Constants are not state.
- A `SPARK_Mode => Off` body cannot show SPARK that it initialises its own
  state, so the parent's `Initializes` contract fails. Declaring
  `Initializes => Backend_State` on the *child spec* fixes it — this was the
  last unproved check in the tree.
- A private type whose full view is in a `SPARK_Mode => Off` private part is
  not known to be default-initialised. Give it a
  `Default_Initial_Condition` (`Contexts.Context` and `Stack_Handle` both do).
- Watch for a state constituent whose name collides with a type (`Page` vs
  `Code_Page.Page`) — rename the variable.
- Opaque functions tell the prover nothing. `Decode_Disp32` was unprovable
  until it became an expression function.
- Unbounded index types overflow *in contracts*: `Positive'Last * 12` does not
  fit. Hence `Max_Listing`/`Max_Code` and the `Listing` subtype.

## Design decisions worth not re-litigating

**Coroutines are pool indices, not pointers.** `Minicoro` holds
`Coros : array (Valid_Id) of Coroutine_Record` and names coroutines by index.
This is the single decision that makes the lifecycle provable — no aliasing for
SPARK's ownership model to police. Cost: a compile-time `Max_Coroutines`
(64) and `Max_Storage` (1024 bytes/coroutine, static). Stacks are still
heap-allocated and are not counted in that.

**`Minicoro.Contexts` is a private child.** Its `Backend_State` is
`Part_Of => Minicoro.Pool`. Without that, every operation in `Minicoro` would
have to name the child's state in its own `Global` contract — and a parent spec
may not `with` its child, so it could not even do so. Consequence: nothing
outside the `Minicoro` hierarchy can `with` it, so a standalone test of the raw
context switch is not possible; `test_golden` (bytes) plus `test_coro`
(execution) cover the same ground.

**`Contexts.Switch (From : in out Context; To : Context)`.** `To` is mode `in`
deliberately: the switch routine writes only `*from`. Making that explicit
removed an in-out/in-out aliasing obligation.

**`Ready` folds two facts.** `Backend_Up` alone says the main context has been
adopted; `Make_Context` and `Switch` need `Contexts.Backend_Ready`, and nothing
relates the two. `function Ready is (Backend_Up and then
Contexts.Backend_Ready)` lets the preconditions be discharged instead of
assumed. `Ensure_Backend` calls `Contexts.Initialize_Backend` unconditionally
(it is idempotent) so `Backend_Ready` holds on every path out.

**`Machine_Code.Layout` is the single source of truth** for the saved-register
buffer offsets. The generated code indexes through those constants and
`Contexts.Context` pins its representation clause to the same ones. Change one,
both move.

**Code generation, not transcription.** The switch routine is built at
elaboration by typed encoders and written into a W^X page. There is no
hand-written byte table anywhere in `minicoro/` — the only byte table is
`tests/golden_win64.ads`, which is minicoro's, used as the oracle.

## What is proved vs assumed

Proved: all of `Machine_Code` (including `Resume_Point_Correct` and the
displacement round trip), and `Minicoro`'s absence of runtime errors, state
guards and the storage invariant `Stored <= Cap` (a `Dynamic_Predicate` on
`Coroutine_Record`).

Assumed, each marked in the source with its reasoning:
1. The generated assembly implements `Contexts.Switch`'s contract. SPARK has no
   machine semantics.
2. **Coroutine re-entry.** SPARK models `Transfer` as an ordinary call that
   returns with globals untouched; in reality control ran elsewhere first.
   `Resume`, `Yield` and `Switch_To` each carry `pragma Assume` re-establishing
   what the counterpart restores.
3. Stack disjointness across separate heap allocations.

If you touch `Resume`/`Yield`/`Switch_To`/`Trampoline`, re-check that the
assumptions still match what the counterpart routine actually restores. They
are the load-bearing part of the lifecycle argument.

## The two papers

- Rutter, *Using a high level language as a cross assembler*, SIGPLAN Notices
  16(2), 1981 — DOI `10.1145/954269.954277`. The encoder is this idea.
- Crary, *Toward a Foundational Typed Assembly Language*, POPL 2003 — DOI
  `10.1145/604131.604149`. `Minicoro.FTAL` states its judgement as ghost
  predicates.

ACM's site returns 403 to fetchers. Resolve DOIs through
`https://api.crossref.org/works/<doi>` instead.

## Pre-existing issues fixed in passing

Six `coroutines/tests` files (`test_foreign_kill`, `test_delegate_nonlocal_ref`,
`test_reference_loop`, `test_resume_chained`, `test_resume_parent_dead`,
`test_secondary_stack`) raised `Program_Error : accessibility check failed`
under GNAT 15 before any coroutine code ran — they converted a locally declared
delegate to the library-level `Delegate_Access`. Fixed with named access types
plus `Delegate_Access'(D.all'Unchecked_Access)`. Note the *qualified
expression*: a type conversion of an access attribute is illegal
("argument of conversion cannot be access attribute").

A real latent bug surfaced from the proof: `Yield` could not rule out a
coroutine being its own resumer, which would hand the switch the same buffer as
source and destination. Now guarded, as is the case where the resumer was
destroyed while the coroutine ran.

## Conventions

- Ada 2012 (`-gnat12`), LF endings, 79 columns, GNAT style.
- Copyright headers: existing files keep
  `Copyright (C) 2014-2022, Pierre-Marie de Rodat`; new files use
  `Copyright (C) 2026, ada-generators contributors`. All `Apache-2.0`.
- Platform-specific bodies use the `__<platform>.adb` suffix and are selected
  by a `Naming` package in the `.gpr`. `minicoro.gpr` picks the backend from
  the `OS` environment variable (`Windows_NT` on Windows, unset elsewhere),
  overridable with `-XMINICORO_BACKEND=windows|posix`.
- A GPR variable cannot be *declared* for the first time inside a `case`;
  declare it before, assign within.

## Not done

- Only x86-64 is implemented (Win64 and System V). Other architectures need
  their own encoder. minicoro itself also has ucontext, fibers and Asyncify
  backends; none are ported.
- The POSIX `Code_Page` body compiles cleanly but has never been run — there is
  no Linux/macOS machine here. Treat it as untested.
- Nothing is committed. The user pushes to their own fork
  (`https://github.com/ValorZard/ada-generators-slop.git`) themselves.
