Ada 2022 - Generators/Coroutines prototype
==========================================

(Note: A lot of this code is AI-Generated, and is a hard fork of this repository: https://github.com/pmderodat/ada-generators)

This repository hosts a prototype for generators/coroutines support in Ada.
This prototype includes:

* `minicoro` — a pure-Ada, largely SPARK-proved coroutine backend, modelled on
  [minicoro](https://github.com/edubart/minicoro). It replaces the former
  binding to PCL and has no external dependencies.
* `coroutines` — a wrapper integrating the backend with the GNAT runtime.
* `generators` — a library leveraging this to provide generators capabilities.

Requirements
------------

[Alire](https://alire.ada.dev/) and a GNAT toolchain it can fetch. There is
**no external library to install** — the previous dependency on PCL (Portable
Coroutine Library) is gone, and with it the requirement to have a C library
and its headers available.

The tree is one Alire crate, described by the `alire.toml` at the root. Alire
puts the three layers on `GPR_PROJECT_PATH` so they can find each other, so
there is nothing to export by hand:

```sh
$ alr toolchain --select     # once, to pick a GNAT
$ alr build
```

The sources are Ada 2022 (`-gnat2022`), built with `-gnatwae -gnatyg`:
warnings are errors and GNAT style is enforced. Developed against GNAT 16.1
and GNATprove FSF 16.1 (Alt-Ergo 2.6.1, cvc5 1.3.2, Z3 4.15.4).

To run the proofs you additionally need GNATprove. It is deliberately *not* a
dependency of the crate — proving is a maintainer activity, not part of
building — so fetch it separately (`alr get gnatprove`, or your distribution's
package) and put it on `PATH`. See `CLAUDE.md` for the exact invocation.

Usage
-----

This is only a prototype so there is no documentation yet! That being said, if
you want to use this prototype, take a look at the `coroutines/tests` and
`generators/tests` subdirectories: in particular all the `.adb` source files.

All three testsuites run from the repository root:

```sh
$ alr test
```

That builds everything and then runs `run_tests.py`, which reports one verdict
per case — 34 in total: 2 in `minicoro/tests`, 21 in `coroutines/tests` and 11
in `generators/tests`. `alr` writes the report to
`alire/alr_test_local.log`; run `python3 run_tests.py` directly to watch it
live.

The `coroutines` and `generators` cases are golden-output tests, compared
against the matching file in the suite's `ref/` directory. Output is
normalised to LF first: the reference files have LF endings and the
executables emit CRLF on Windows, so a raw byte comparison there reports every
case as a difference and tells you nothing. (The older per-suite `run.py`
drivers still exist and still compare raw bytes.)

`minicoro/tests` is self-checking rather than golden: `test_golden` compares
the generated machine code against minicoro's published byte tables, and
`test_coro` exercises create/resume/yield/storage including nested coroutines.

The coroutine backend
---------------------

The backend is built around an unusual idea, drawn from the two papers cited
below: **the context-switch routine is not written, it is generated** — by Ada
code that GNATprove verifies.

```
Minicoro                SPARK   coroutine lifecycle, storage API
Minicoro.Machine_Code   SPARK   x86-64 instruction encoder + switch listing
Minicoro.FTAL           SPARK   ghost register/stack typing model  (all Ghost)
Minicoro.Contexts       SPARK   except the switch itself and its plumbing
Minicoro.Code_Page      SPARK   W^X page from the OS
Coroutines              SPARK   except where the published API and the
                                SPARK subset disagree
Generator_Slots         SPARK   generator ref counting + slot lifecycle
Generator_Coros         SPARK   the coroutine behind a generator; affinity
Generators              SPARK   except the iteration interface
```

All of `minicoro/` is `SPARK_Mode => On` except eight subprograms, each marked
and justified where it sits: the two `Unchecked_Conversion`s that turn a
code-page address into a callable switch routine and a coroutine body into a
machine word, the indirect call itself, `Make_Context`'s overlay write,
`Adopt_Current`'s volatile stack anchor, `Allocate_Stack`'s `'Address` and
`Storage_Error` handler, and the `'Access` taken in `Trampoline_Entry`. Those
are what GNATprove rejects outright — not choices.

`Coroutines` is SPARK too, which took a rewrite rather than annotations.
Reference counting *is* shared ownership and SPARK's ownership model has only
the unique kind, so the handle became an index into a pool exactly as
`Minicoro`'s is; and `Ada.Finalization.Controlled` is rejected outright, so
finalization uses GNAT's `Finalizable` aspect instead. The interface did not
change. What stayed outside SPARK there is a different kind of thing from
`minicoro`'s — not machine state but places where the published API and the
subset disagree: a SPARK function may not write globals, yet `Create` must
count a reference; and `Exceptional_Cases` is not accepted on a dispatching
operation, yet `Spawn`/`Switch`/`Kill` raise and must stay primitives of a
tagged type for the prefix notation the codebase uses.

`Generators` needed one more move, because it is generic and GNATprove
analyses instantiations rather than generic units — and no SPARK unit can
instantiate it, since its `Iterable` aspect names the three functions that
advance a generator, which must be outside SPARK because a SPARK function may
not write globals. Left as one package it produced *zero* checks.

Almost nothing a generator slot holds turns out to depend on the yielded type,
so almost none of it stayed. Two non-generic packages took it, and being
non-generic they are analysed directly:

* `Generator_Slots` — reference counting, slot allocation and the execution
  state machine, with functional contracts rather than just runtime checks.
  `Drop` states the invariant that a slot is released exactly when its last
  reference goes, and proves it.
* `Generator_Coros` — the coroutine that runs the generator and the one that
  resumed it, and so the affinity guard, the resume/return pair and
  kill-on-release.

Between them they contribute 42 of the 871 checks. What remains in the generic
is only what genuinely depends on the type: the yielded values and the user
delegate. The record that used to hold all nine together is gone.

None of that makes generators usable *from* SPARK, and nothing can: a SPARK
unit cannot even declare the instantiation, so there is no generator for it
to hold. What works instead is a boundary --
`generators/examples/spark_client` is a worked one that proves clean, with a
SPARK spec over a `SPARK_Mode => Off` body that hides the generator, the
delegate and `Yield`. The cost is that the result has to come back bounded,
so laziness does not survive the crossing.

At elaboration, `Minicoro.Machine_Code` assembles the switch routine from
typed instruction encoders; `Minicoro.Code_Page` writes those bytes into a page
that is made read+execute *before* any address in it is handed out, so the
process never holds memory that is both writable and executable.

### Why generate it

minicoro ships its Win64 backend as a literal array of bytes in `.text`,
beginning with

```
48 8d 05 3e 01 00 00     lea 0x13e(%rip), %rax
```

That `0x13e` is a hand-computed distance from the end of the `lea` to the
routine's trailing `ret`. It is the address the routine saves as a coroutine's
resume point, so if it is wrong by one byte, resuming lands mid-instruction.
Nothing in the C source checks it.

Here the number is never written down. `Switch_Displacement` computes it from
the assembled listing, and `Resume_Point_Correct` states that the address the
`lea` produces at run time is exactly where the `ret` sits:

```ada
function Resume_Point_Correct (ABI : ABI_Kind) return Boolean is
  (7 + Decode_Disp32 (Switch_Code (ABI), 3)
     = Displacement (Offset_Of (Switch_Template (ABI), Ret_Position (ABI))));
```

GNATprove discharges it. Independently, `test_golden` confirms the generated
bytes are identical to minicoro's — all 326 of the Win64 switch routine, the
7-byte trampoline, and both displacements (`0x13E` and, for System V, `0x3D`).
So the derivation is both proved self-consistent and validated against a
known-good implementation.

### The two papers

* Rutter, *Using a high level language as a cross assembler*, ACM SIGPLAN
  Notices 16(2), 1981. The instruction encoder in `Minicoro.Machine_Code` is
  this idea: the assembler is ordinary code in the host language, so the
  machine code becomes data a prover can reason about.
* Crary, *Toward a Foundational Typed Assembly Language*, POPL 2003. Machine
  states get types, and a code block's safety is a judgement about the register
  file and stack it is entered with. `Minicoro.FTAL` states that judgement —
  `Well_Typed`, `Switch_Pre`, `Switch_Post` — as ghost predicates that
  GNATprove checks at every call site of the trusted switch.

What is proved and what is assumed
----------------------------------

Being precise about this matters more than the headline number, which is
`Success: all checks proved` — 612 checks for `minicoro`, 829 for
`coroutines` and 871 for `generators`, each figure including the layers below
it since the projects with each other. The full run is 466 run-time checks,
124 functional contracts, 19 assertions, 82 termination checks and the flow
analysis, with two justifications (see below) and nothing unproved.

**Proved** (GNATprove, `gnatprove -P coroutines.gpr`, which covers both
layers):

* `Minicoro.Machine_Code` in full — absence of runtime errors, termination,
  and the functional contracts, including `Resume_Point_Correct` and the
  round trip showing that the displacement bytes patched into the `lea` decode
  back to the displacement that was computed.
* `Minicoro` — absence of runtime errors across the lifecycle and storage API,
  the state-transition guards, and the storage invariant
  `Stored <= Cap` (carried as a predicate on the pool record), which is what
  makes `Push`/`Pop`/`Peek` free of overflow and of reads past written bytes.
* `Minicoro.Code_Page` — the allocate/write/seal state machine. `Address_At`
  requires a sealed page and `Write` requires an unsealed one with room for
  the bytes; both are now discharged by the caller rather than asserted in
  the body. What is *not* covered is the byte copy itself: it goes through an
  `Import` overlay at a computed address, which GNATprove models as having no
  effect (see assumption 6).
* `Minicoro.Contexts` — everything but the five subprograms named above.
* `Coroutines` — the slot lifecycle: reference counting, the parent chain,
  and absence of runtime errors across `Claim_Slot`, `Spawn_Slot`,
  `Switch_Slot`, `Kill_Slot`, `Release` and `Reset`. That is where a
  ref-counting bug would live, which is what made the rewrite worth doing.
  There are no functional postconditions there yet: it is proved not to go
  wrong, not proved to do anything in particular.
* `Generator_Slots` — the generator equivalent, and the one place in the tree
  with functional contracts on reference counting rather than just absence of
  runtime errors: `Claim` establishes that a fresh slot is in use with a
  count of one, `Drop` that a slot is released exactly when its last
  reference goes, and `Set_State`/`Set_Owns_Delegate` that they change what
  they name and nothing else.
* `Generator_Coros` — every one of its fourteen subprograms, which is where
  a generator's task affinity is actually enforced: `Resume` refuses to
  advance a generator the calling task does not own, and reports that as a
  status code rather than an exception, because the exception belongs to the
  generic.

**Assumed.** Nine things, the first eight marked in the source and the
ninth true of the whole library:

1. **The generated assembly implements `Contexts.Switch`.** SPARK has no
   semantics for machine instructions, so `Switch`'s postcondition is
   assumed of the code, not derived from it. What narrows this gap is that the
   *instruction sequence* is proved well-formed and its resume point proved to
   be an instruction boundary — the part most likely to be silently wrong.
2. **Coroutine re-entry.** Control ran inside another coroutine between the
   `Switch` and the return from it. `Transfer` ends by calling
   `Control_Transferred`, a helper whose contract havocs the pool and the
   identity of the running coroutine and whose body is outside SPARK, so the
   prover treats both as unknown once a switch has happened. `Resume`,
   `Yield` and `Switch_To` each then carry a `pragma Assume` restoring what
   the counterpart routine establishes before switching back, with the
   reasoning written out at the assumption — and their postconditions are
   proved from those assumptions rather than around them.
3. **Stack disjointness.** `Transfer` assumes distinct pool slots hold
   distinct stack allocations. They do — each is a separate allocation — but
   SPARK cannot see it through the heap.
4. **`Trampoline`'s precondition.** It states that the handle the generated
   entry code carries in R13 is the pool index `Create` encoded, that the slot
   is live, and that its resumer is neither itself nor a released slot.
   `Create` establishes all three, but nothing in SPARK discharges the
   precondition: the only reference to `Trampoline` is the `'Access` inside
   `Trampoline_Entry`, which is outside SPARK, and the only caller is the
   generated code.
5. **The OS entry points have no Ada effects.** `mmap`/`mprotect`/`munmap`,
   and their Win32 counterparts, carry `Global => null`. That is true of the
   Ada state SPARK reasons about and plainly false of the process; it is
   written down rather than left as the default GNATprove would assume
   silently.
6. **`Code_Page.Write` copies bytes.** GNATprove does not model writes through
   an overlay at a computed address, and says so — `statement has no effect`,
   `unused assignment`. It believes `Write` is a no-op. The bytes it writes
   are checked instead by `test_golden`, which compares the generated listing
   against a byte-for-byte oracle, and by `test_coro`, which runs it.
7. **`Coroutines.Create` does not retain or free its delegate twice.** The
   pointer is moved into the pool by a trusted helper, because SPARK sees
   `Create`'s parameter only as observed. This is the obligation `Create`'s
   documentation already places on its caller: ownership transfers.
8. **The GNAT secondary stack and soft links behave.** Saving, restoring and
   initialising a coroutine's secondary stack goes through
   `System.Soft_Links`, whose effects SPARK cannot see.
9. **One thread of control, per proof.** Every check above is proved of a
   single thread. That is now a weaker statement than it used to be, because
   the state that made it load-bearing is no longer shared: the main context,
   the running coroutine and the backend-up flag are arrays indexed by a
   thread number, and each coroutine records which thread may switch to it,
   so the classic failure — a task installing a stack pointer another task
   adopted — is refused with `Wrong_Task` instead of corrupting memory.

   What is assumed is the step from "proved of one thread" to "holds of each
   thread separately". GNATprove does not model `pragma
   Thread_Local_Storage`; it says so (`pragma "Thread_Local_Storage" ignored
   (not yet supported)`) and analyses the thread number as an ordinary
   variable. Also outside the proof: the single atomic fetch-and-add that
   hands those numbers out, and `Trampoline`'s claim that whichever thread
   finishes a coroutine has its own backend up.

   Reference counts *are* atomic, so handles may be copied and dropped on
   any task; what remains unsynchronised is concurrent `Create`, which finds
   a free slot by scanning the shared pool and then marking it. For SPARK
   clients that residue
   is reported rather than assumed: with `pragma Profile (Ravenscar)` and
   `Partition_Elaboration_Policy (Sequential)`, GNATprove says `possible data
   race when accessing variable "minicoro.pool"`. See "Threading model" in
   `CLAUDE.md` for the full boundary and what the caller must arrange.

The **justified** checks are two, both written out with `pragma Annotate` at
the site and both showing up in GNATprove's report rather than being silently
suppressed.

In `Transfer`: SPARK's anti-aliasing rule (SPARK RM 6.4.2) is syntactic and
treats `Coros (From).Ctx` and `Coros (To).Ctx` as possibly the same object,
because the indices are not static. `Transfer`'s precondition requires
`From /= To`, so they are components of different array elements.

In `Create`, at the `Allocate_Stack` call: a memory-leak check. The slot was
chosen because it is not in use, and `Destroy` — the only way a slot becomes
free — releases the stack before it clears the flag, so a free slot's handle
owns nothing. SPARK knows `Stack_Handle` is an ownership type but cannot reach
the pointer inside it from `Minicoro`, and does not track reclamation across
calls through an array element with a non-static index.

Design notes
------------

* **Coroutines are pool indices, not pointers.** `Minicoro` holds a statically
  sized array and names coroutines by index. This is what lets the lifecycle
  proofs go through without an ownership model, and it makes "is this
  coroutine still alive" a Boolean in a slot rather than the validity of a
  dangling access value. The cost is a compile-time maximum
  (`Max_Coroutines`, default 64); coroutine *stacks* are still allocated
  dynamically.
* **A coroutine belongs to one task.** Switching to a stackful coroutine
  installs its saved stack pointer on the calling thread, so two threads
  switching to one coroutine run on one stack. Each coroutine therefore
  records an owner, every control transfer checks it, and `Detach`/`Adopt`
  hand one over — which is also what makes work stealing possible: a detached
  coroutine is a unit of work any task may pick up. A thread's own number is
  one thread-local scalar, so the check costs a `%fs`-relative load and a
  compare and a program with no tasks pays nothing more. `Minicoro.Max_Owners`
  (16) is the ceiling on threads.
* **Layout has one source of truth.** `Machine_Code.Layout` gives the byte
  offsets of the saved-register buffer; the generated code indexes through
  those constants and `Contexts.Context` pins its representation clause to the
  same ones, so the two cannot drift apart.
* **Portability.** The x86-64 encoder covers both the Win64 and System V
  ABIs, chosen at elaboration from the compiler's target. Only
  `Minicoro.Code_Page` is OS-specific (`VirtualAlloc` / `mmap`), selected by
  the project file. Other architectures would need their own encoder; minicoro
  itself also supports ucontext and fibers, which this port does not.
