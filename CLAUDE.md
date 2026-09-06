# CLAUDE.md

Working notes for this repository. `README.md` explains the design to a
reader; this file records what you need to *operate* on the tree — how to
build, test and prove it, and the traps that cost time.

## What this repo is

A prototype for Ada generators/coroutines, in four layers, bottom up:

| Directory     | Unit                    | SPARK | Role                                        |
|---------------|-------------------------|-------|---------------------------------------------|
| `minicoro/`   | `Minicoro`              | yes*  | coroutine lifecycle + per-coroutine byte stack |
|               | `Minicoro.Machine_Code`  | yes   | x86-64 instruction encoder, switch listing  |
|               | `Minicoro.FTAL`          | yes   | ghost register/stack typing model (all Ghost) |
|               | `Minicoro.Contexts`      | yes*  | **private child**; trusted context switch   |
|               | `Minicoro.Code_Page`     | yes   | W^X page from the OS                        |
| `coroutines/` | `Coroutines`             | no    | ref-counted, GNAT-runtime-integrated wrapper |
| `generators/` | `Generators`             | no    | generator API over `Coroutines`             |

`yes*` means the unit is `SPARK_Mode => On` with named exceptions inside it.
All of `minicoro/` is On except six places, each marked and justified where it
sits — see "The six things that cannot be SPARK" below. `coroutines/` and
`generators/` are `SPARK_Mode => Off` and cannot be otherwise: they are built
on `Ada.Finalization.Controlled`, which GNATprove rejects outright.

`minicoro/` replaced a thin binding to PCL (the old `pcl/` directory, deleted).
The `generators/` layer was untouched by that swap — the change is confined to
`Coroutines` and below.

## Toolchain

The tree is a single Alire crate (`alire.toml` at the root) and everything
goes through `alr`, which is the only thing that has to be on `PATH`:

```sh
export PATH="$HOME/alire/bin:$PATH"
```

`alr` supplies the compiler and sets `GPR_PROJECT_PATH` to the three layer
directories, which is how the projects find each other by name
(`with "minicoro.gpr"`). Nothing else needs exporting. To drive a tool `alr`
does not wrap, borrow its environment with `alr exec -- <cmd>`.

- Alire 2.1.1, GNAT 16.1.0 (`x86_64-linux-gnu`), GPRBUILD 26.0.1.
- GNATprove is *not* an Alire dependency of the crate — proving is a
  maintainer activity, not part of building. The release is in the cache at
  `~/.local/share/alire/releases/gnatprove_16.1.0_*/bin`; put that on `PATH`
  along with the GNAT and GPRBUILD toolchains under
  `~/.local/share/alire/toolchains/` when you want to prove.
- GNATprove FSF 16.1.0 with Alt-Ergo 2.6.1, cvc5 1.3.2, Z3 4.15.4.
- `gnatprove --version` prints the version and *then* raises
  `ADA.IO_EXCEPTIONS.DEVICE_ERROR`. Harmless, ignore it.

## Build and test

```sh
alr build     # all six projects: three layers, then their testsuites
alr test      # builds, then runs run_tests.py
```

`alr test` swallows the output and writes it to
`alire/alr_test_local.log`; run `python3 run_tests.py` from the root instead
if you want to watch it. Either way the runner reports one verdict per case
and exits non-zero on any failure.

Expected: **2/2 minicoro, 17/17 coroutines, 8/8 generators — 27 in all.**

`run_tests.py` normalises output to LF before comparing against `ref/`. The
per-suite `run.py` drivers still exist and still compare raw bytes, which is
why **`run.py` reports every test as DIFF on Windows**: the reference files
have LF endings and the executables emit CRLF. `run.py` is not wrong about
anything else. `run_tests.py` also knows the parameterised cases —
`test_complete` runs with argument `0`, `1`, `2` against
`ref/test_complete_{0,1,2}`.

The two `minicoro` cases are self-checking rather than golden: they print
`ok`/`FAIL` lines, and the runner fails the case on any line beginning with
`FAIL` or a non-zero exit status.

## Proving

```sh
export PATH="$HOME/.local/share/alire/releases/gnatprove_16.1.0_82528bef/bin:\
$HOME/.local/share/alire/toolchains/gnat_native_16.1.0_9f74f58a/bin:\
$HOME/.local/share/alire/toolchains/gprbuild_26.0.1_e3f27f25/bin:$PATH"
cd minicoro && gnatprove -P minicoro.gpr --level=2 -j4 --report=fail
```

Expected: `Success: all checks proved (579 checks)` with **2 justified, 0
unproved**. Takes roughly 10-20 minutes — run it in the background, do not
poll it. `--level=3` also passes; `--report=statistics` if you want per-check
detail.

The default run is no longer warning-free: `Code_Page` came into SPARK and
brings six warnings with it, all one fact — GNATprove does not model writes
through an `Import` overlay at a computed address. See "What `Code_Page` being
SPARK does and does not buy" below. Nothing else in the default run warns.

`obj/gnatprove/gnatprove.out` holds the summary table; read lines 5-24.

Do not run `gprbuild` and `gnatprove` on `minicoro/` at the same time — they
share `obj/`. That includes `alr build` and `alr test`, which call `gprbuild`.

There are two justifications, both written out with `pragma Annotate` at the
site.

`Minicoro.Transfer`: SPARK's anti-aliasing rule (RM 6.4.2) is syntactic and
treats `Coros (From).Ctx` and `Coros (To).Ctx` as possibly the same object
because the indices are not static. `Transfer`'s precondition requires
`From /= To`.

`Minicoro.Create`, at the `Allocate_Stack` call: a memory-leak check. `Slot`
was chosen because `not Coros (Slot).In_Use`, and `Destroy` is the only way a
slot becomes free — it calls `Free_Stack` and only then clears `In_Use`, so a
free slot's handle owns nothing. SPARK knows `Stack_Handle` is an ownership
type (its full view became visible when the private part of `Contexts` went
`SPARK_Mode => On`) but cannot reach the pointer inside it from `Minicoro`,
and does not track reclamation across calls through an array element with a
non-static index.

## The six things that cannot be SPARK

Everything in `minicoro/` is `SPARK_Mode => On` except these, and each was
confirmed against GNATprove rather than assumed. Do not "clean them up" by
flipping the pragma: the list below is what the tool actually rejects.

1. **`Minicoro.Contexts.Machine`** (body only; the spec is On). Two
   `Unchecked_Conversion` instances GNATprove refuses — *to* an
   access-to-subprogram type, to reinterpret sealed code-page bytes as the
   switch routine, and *from* `Body_Entry`, to take a coroutine body's address
   as a machine word — plus `Call_Switch`, which is the indirect call into
   the generated code. This is the irreducible trusted base.
2. **`Contexts.Switch`** — one line, calling `Machine.Call_Switch`. Off
   because its postcondition is the trusted claim about the assembly.
3. **`Contexts.Make_Context`** — writes a poison return address through an
   overlay at a computed address.
4. **`Contexts.Adopt_Current`** — a volatile local (SPARK: "effectively
   volatile object not at library level is not allowed") whose `'Address` is
   the evidence that the caller's stack region exists.
5. **`Contexts.Allocate_Stack`** — `'Address` of the allocated block, and a
   handler for `Storage_Error`, which SPARK does not model.
6. **`Minicoro.Trampoline_Entry`** — `Trampoline'Access`. "Access to
   subprogram with global effects is not allowed in SPARK", and the landing
   pad necessarily touches the pool.

The recurring hard errors behind those, for reference:

- `attribute "Address" outside an attribute definition clause is not allowed
  in SPARK [E0002]`
- `unchecked conversion instance to an access to subprogram type` / `from a
  type with access subcomponents`
- `access to subprogram with global effects is not allowed in SPARK`
- `effectively volatile object not at library level [E0001]`

`Minicoro.Trampoline` itself **is** SPARK now. It carries a precondition
stating what the generated entry code owes it (Handle is the pool index
`Create` encoded, the slot is live, its resumer is neither itself nor a
released slot). Nothing discharges that precondition — the only reference to
`Trampoline` is the `'Access` in `Trampoline_Entry`, which is Off — so read it
the way `Contexts.Switch`'s contract is read: a statement of an obligation at
the trusted boundary, not a proved result.

### What `Code_Page` being SPARK does and does not buy

The bookkeeping is genuinely checked: `Size_Of`/`Is_Sealed` are now contracts
on `Allocate`, `Write`, `Seal` and `Address_At`, so `Initialize_Backend`
*discharges* `Address_At`'s "the page is sealed" precondition instead of the
body asserting it. Two `pragma Assert`s that used to sit inside `Write`'s body
— unchecked claims — are now that subprogram's precondition.

What it does not buy is the byte copy. `Write` writes through an `Import`
overlay at a computed address, and under `--proof-warnings=on` GNATprove says
so plainly: `statement has no effect`, `unused assignment`, `"P" is not
modified, could be IN`. It models `Write` as a no-op. The `[E0012]`
`imprecise-address-specification` warning is the same limitation stated once.
So `Code_Page` is analysed for its state machine, not for its effect.

### Why `coroutines/` and `generators/` cannot be SPARK

Not a matter of effort. `Coroutine`, `Coroutine_Internal`, `Generator` and
`Generator_Internal` all extend `Ada.Finalization.Controlled`, and GNATprove's
answer to that is flat:

```
error: "Controlled" is not allowed in SPARK (due to controlled types)
```

Reference counting and stack release via `Initialize`/`Adjust`/`Finalize` is
those two layers' design, so this is not fixable by annotation. Three more
hard rejections sit in `coroutines.adb` on their own account:
`Coroutine_Wrapper'Access` (global effects), `C'Address` (E0002), and
`System.Address_To_Access_Conversions.To_Pointer`, which SPARK models as an
allocating function returning an owning pointer.

Two things that are *not* the reason, contrary to expectation:
`Ada.Exceptions.Save_Occurrence`/`Reraise_Occurrence` are legal SPARK, and so
is an `exception when others` handler. Both were checked in isolation.

Both packages now carry an explicit `SPARK_Mode => Off` with the reason in a
header comment, so the status is declared rather than merely defaulted.

## Proof warnings: where this stands (2026-09-06)

**Status: all checks prove, in both the default and the extended run. The
`pragma Assume is always False` family below is a real defect and is still
open.** Read this before touching `Resume`, `Yield`, `Switch_To` or
`Transfer`.

### The extended run

Two warning families are off by default. Turn them on:

```sh
cd minicoro && gnatprove -P minicoro.gpr --level=2 -j4 --report=fail \
  --pedantic --proof-warnings=on
```

Still `Success: all checks proved (579 checks)`, but **29 warnings**:

| Count | Kind                                    | Group |
|-------|-----------------------------------------|-------|
| 11    | `operator-reassociation`                | 2     |
| 5     | `pragma Assume is always False`         | 1     |
| 3     | `unreachable branch`                    | 1     |
| 2     | `unreachable code`                      | 1, 4  |
| 7     | `Code_Page` overlay family              | 3     |
| 1     | `representation-attribute-value`        | 5     |

Group 1 is the only one with verification consequences.

### 1. `pragma Assume is always False` — a real defect, unfixed

Five warnings (`minicoro.adb:348,349,394,395,432`) plus four
`unreachable branch`/`unreachable code` ones
(`minicoro.ads:155,161,168`, `minicoro.adb:316`). All but the last share one
root cause.

`Transfer` never assigns `Current`, so SPARK's inferred `Global` for it does
not mention `Current` and the prover concludes it is unchanged across the
call. But `Resume` sets `Current := C` *before* calling `Transfer`, and the
guard above it rules out `C = Prev`. So:

```ada
Current := C;
Transfer (Prev, C);
pragma Assume (Current = Prev);   --  provably False
```

The assumption contradicts what the prover derived. **A contradictory
`pragma Assume` makes everything after it vacuously provable** — which is why
the postconditions of `Resume`, `Yield` and `Switch_To` are reported as
unreachable branches. Those three postconditions are *not actually verified
today*. The 579 figure is not wrong, but it counts three vacuous contracts.

`Yield` (`Current := Prev` then `Assume (Current = C)`) and `Switch_To`
(`Current := Target` then `Assume (Current = Cur)`) fail the same way. The
second assume in each pair (`348`/`349`, `394`/`395`) is flagged only because
it sits downstream of the first — fix the first and the second should go
quiet on its own.

**Intended fix.** Stop pretending `Transfer` returns with the pool as it left
it, and model the control transfer honestly: after the switch, `Current` and
`Coros` should be *unknown*, not preserved. The plan was a body-local helper
whose contract declares the effect and whose body is opaque to SPARK, called
at the end of `Transfer` right after `Contexts.Switch` returns:

```ada
   procedure Control_Transferred
     with Global => (In_Out => (Coros, Current));
   --  body: pragma SPARK_Mode (Off); null;
```

With `Current` havoc'd, the three `pragma Assume`s become genuine
restorations instead of contradictions, and the postconditions get proved
from them for real. Do not write an explicit `Global` on `Transfer` itself —
it would have to enumerate `Main_Ctx` and `Contexts.Backend_State`, and the
child's state is deliberately `Part_Of => Minicoro.Pool` so that callers do
not have to name it.

**Risk, and why this was not just done:** havocking `Coros` makes every pool
fact unknown after a `Transfer`, so proofs that currently lean on those facts
may start failing and need their own assumptions. The three call sites do
almost nothing after `Transfer` (they assign `Res` and return), so the blast
radius *looks* small — but `Trampoline` also calls `Transfer`
(`minicoro.adb:437`) and was not analysed. Budget a few proof cycles.

`minicoro.adb:316` (`Res := Not_Suspended`) is separate and is **not a bug**:
`Resume`'s precondition is `Status (C) = Suspended`, so the guard is dead for
SPARK-proved callers. It stays — `Coroutines` is not SPARK and can violate
that precondition. If the warning needs silencing, justify it in place rather
than deleting the check.

### 2. `operator-reassociation` — 11 warnings, cosmetic, deliberately deferred

`--pedantic` only. Ada (RM 4.5) lets a compiler reassociate a chain of
same-precedence predefined operators, so `A + B + C` may be evaluated as
`A + (B + C)`; the prover assumed left-to-right. It can only *change* anything
if an intermediate overflows, and none of these can — they are byte-range
encoder arithmetic and small index sums.

Sites: `minicoro.adb:483,508,534` (`Base + 1 + (I - Src'First)`),
`minicoro-machine_code.adb:24` (`REX`), `:31` (`Mod_RM`), `:63` (`Put_Disp`'s
precondition), `:178`, `:203`, `:243` (`P + 3 + Disp_Size (M)`),
`minicoro-machine_code.ads:148` (`Subprogram_Variant`), `:238`
(`Decode_Disp32`).

The fix is pure parenthesisation — `(P + 3) + Disp_Size (M)`,
`(Base + 1) + (I - Src'First)`, `(L'Last + 1) - Index` — semantically neutral
and safe. It was drafted and pulled back before landing; `REX` and
`Decode_Disp32` are the only ugly ones, needing a nested-paren cascade over
four and five terms. Decide whether pinning the association is worth the
noise before redoing it.

### 3. The `Code_Page` overlay family — 7 warnings, one fact

`minicoro-code_page.ads:40,64` and `minicoro-code_page__posix.adb:109,110,112,
113,159`: `statement has no effect`, `unused assignment`, `unused initial
value of "P"`, `"P" is not modified, could be IN`, and one `[E0012]`
`imprecise-address-specification`. They are all the same thing said seven
ways — GNATprove does not model a write through an `Import` overlay at a
computed address, so it believes `Write` does nothing and `Free` changes
nothing. Seven of these appear in the **default** run too. Nothing to fix;
the limitation is real and is recorded under "What `Code_Page` being SPARK
does and does not buy".

### 4. `unreachable code` at `minicoro-code_page__posix.adb:74` — prover and
compiler disagree about the target

GNATprove proves the `return True` inside `On_Linux` unreachable, i.e. that
`Standard'Target_Name` never contains "linux". The compiler disagrees: on this
machine `Standard'Target_Name` is `"x86_64-pc-linux-gnu"` (19 chars, "linux"
at index 11), GNAT folds the search accordingly, and the 27-case suite passes
— which it could not if `MAP_ANONYMOUS` came out as the BSD `0x1000` instead
of Linux's `0x20`, because `mmap` would fail and `Create` would return
`Make_Context_Error`.

So this is a false report, and the interesting part is *why*: GNATprove's
frontend evidently does not see the same `Standard'Target_Name` the compiler
does. Harmless here because the value is only used to pick a constant, but
worth remembering before making anything load-bearing depend on
`Standard'Target_Name` under proof — `Contexts.Detect_ABI` does exactly that.

### 5. `representation-attribute-value` at `minicoro-contexts.adb:44`

`--pedantic` only, and a deliberate trade. The layout guard used to be a
runtime `pragma Assert (Context'Size >= Machine_Code.Layout.Win64_Size * 8)`
in the package's elaboration part, which GNATprove could not prove (it cannot
evaluate `'Size`) and reported as `medium: assertion might fail`. It is now a
`pragma Compile_Time_Error`, so the compiler checks it and GNATprove
generates no verification condition — it only notes, correctly, that `'Size`
is implementation-defined.

### 6. `info:` lines are not warnings

`cannot unroll loop (too many loop iterations)` and `unrolling loop`.
Informational; the loops carry invariants and prove fine. Nothing to do.

### Resuming

1. Re-run the extended command above to confirm the 29 warnings still stand.
2. Do family 1 first — it is the only one with verification consequences.
   After it lands, re-check that `Resume`/`Yield`/`Switch_To` postconditions
   are genuinely proved (they should stop being reported as unreachable
   branches) and re-run `alr test`: these are the coroutine lifecycle paths,
   so the 27-case suite is the check that the model change did not alter
   behaviour.
3. Family 2 is independent and can be skipped or done at leisure. Families
   3, 4 and 5 are tool limitations or deliberate trades, not work items.

## Traps that cost time

**Ada in bash heredocs.** Tick attributes (`X'First`, `T'Access`) break
`<<'EOF'` quoting — bash reports `unexpected EOF while looking for matching '`.
Use the Write tool for Ada sources, or a Python script for surgical edits.

**Python writes CRLF.** `open(p, 'w')` on Windows translates `\n` to `\r\n`,
and `-gnatyg` rejects that with `(style) incorrect line terminator`. Always
`open(p, 'w', encoding='utf-8', newline='\n')`, and read with `newline=''`.

**Array aggregates must use `[...]`.** Ada 2022 makes `(others => X)` for an
*array* obsolescent, `-gnatwa` warns about it (`-gnatwj`), and `-gnatwae`
turns that into an error. Every array aggregate in the tree is bracketed;
record aggregates keep their parentheses, and so does the record aggregate
that *contains* a bracketed array component:

```ada
Bytes  : Insn_Bytes := [others => 16#90#];          --  array
Ctx.XMM := [others => 0];                            --  array
Unmade : constant Context_Model :=
  (Regs => [others => Junk], SP => 0, ...);          --  record of array
```

The compiler names every site, so the cheap way to convert is to build, fix
what it lists, and repeat — it stops at the first file each time.

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
displacement round trip), `Minicoro`'s absence of runtime errors, state guards
and the storage invariant `Stored <= Cap` (a `Dynamic_Predicate` on
`Coroutine_Record`), `Code_Page`'s allocate/write/seal state machine, and
everything in `Contexts` but the five subprograms listed under "The six things
that cannot be SPARK".

Assumed, each marked in the source with its reasoning:
1. The generated assembly implements `Contexts.Switch`'s contract. SPARK has no
   machine semantics.
2. **Coroutine re-entry.** SPARK models `Transfer` as an ordinary call that
   returns with globals untouched; in reality control ran elsewhere first.
   `Resume`, `Yield` and `Switch_To` each carry `pragma Assume` re-establishing
   what the counterpart restores.

   These three assumptions are currently **contradictory**, not merely
   unproved: `Transfer` does not write `Current`, so the prover knows the
   value the caller just stored and the assume denies it. Everything after
   them is therefore vacuously provable, which costs the postconditions of
   `Resume`, `Yield` and `Switch_To`. `--proof-warnings=on` reports it; the
   fix is drafted under "Proof warnings: where this stands". Until then,
   read those three contracts as claims, not results.
3. Stack disjointness across separate heap allocations.
4. **`Trampoline`'s precondition.** It says Handle is the pool index `Create`
   encoded, that the slot is live, and that its resumer is neither itself nor
   a released slot. `Create` establishes all three before handing
   `Handle_Of (Slot)` to `Make_Context`, but nothing in SPARK discharges it:
   the only reference to `Trampoline` is the `'Access` inside
   `Trampoline_Entry`, which is `SPARK_Mode (Off)`, and the only caller is the
   generated entry code.
5. **The OS entry points have no Ada effects.** `mmap`/`mprotect`/`munmap`
   (and their Win32 counterparts) carry `Global => null`. True of the Ada
   state SPARK reasons over, plainly false of the process. Stated explicitly
   rather than left as the silent default GNATprove would otherwise assume.
6. **`Code_Page.Write` actually copies bytes.** GNATprove models the overlay
   write as having no effect and says so; see "What `Code_Page` being SPARK
   does and does not buy".

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

- Ada 2022 (`-gnat2022`), LF endings, 79 columns, GNAT style. All six
  `.gpr` files carry the same `("-gnat2022", "-gnatwae", "-gnatyg")`; keep
  them in step.
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
- The POSIX `Code_Page` body (`mmap`/`mprotect`) now runs: the full 27-case
  suite passes on x86-64 Linux under GNAT 16.1, which exercises it together
  with the System V switch routine. macOS and the BSDs are still untested —
  `MAP_ANONYMOUS` differs there and `On_Linux` picks the value by inspecting
  `Standard'Target_Name`.
- The `pragma Assume is always False` family is still open, so three
  postconditions (`Resume`, `Yield`, `Switch_To`) are still vacuously proved.
  See "Proof warnings: where this stands" — that is the open work, and it is
  unaffected by the SPARK_Mode expansion.
- `coroutines/` and `generators/` are `SPARK_Mode => Off` and staying that
  way; putting them in SPARK means replacing `Ada.Finalization.Controlled`
  ref-counting with something SPARK accepts, which is a rewrite of both
  layers, not an annotation exercise.
- The user pushes to their own fork
  (`https://github.com/ValorZard/ada-generators-slop.git`) themselves.
