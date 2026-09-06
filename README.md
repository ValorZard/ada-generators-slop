Ada 2020 - Generators/Coroutines prototype
==========================================

This repository hosts a prototype for generators/coroutines support in Ada.
This prototype includes:

* `minicoro` — a pure-Ada, largely SPARK-proved coroutine backend, modelled on
  [minicoro](https://github.com/edubart/minicoro). It replaces the former
  binding to PCL and has no external dependencies.
* `coroutines` — a wrapper integrating the backend with the GNAT runtime.
* `generators` — a library leveraging this to provide generators capabilities.

Requirements
------------

A GNAT toolchain. There is **no external library to install** — the previous
dependency on PCL (Portable Coroutine Library) is gone, and with it the
requirement to have a C library and its headers available.

To build, make the `*.gpr` files visible to GPRbuild by adding their
directories to `GPR_PROJECT_PATH`.

To run the proofs you additionally need GNATprove; `alr toolchain` will fetch
both. This tree was developed against GNAT 15.2 and GNATprove FSF 16.1
(Alt-Ergo 2.6.1, cvc5 1.3.2, Z3 4.15.4).

Usage
-----

This is only a prototype so there is no documentation yet! That being said, if
you want to use this prototype, take a look at the `coroutines/tests` and
`generators/tests` subdirectories: in particular all the `.adb` source files.

If you want to run a testsuite, go to the relevant `tests` directory, build the
testcases and run the driver:

```sh
$ gprbuild -Ptests
$ python run.py
```

`minicoro/tests` builds two checks of its own: `test_golden`, which compares
the generated machine code against minicoro's published byte tables, and
`test_coro`, which exercises create/resume/yield/storage including nested
coroutines.

The coroutine backend
---------------------

The backend is built around an unusual idea, drawn from the two papers cited
below: **the context-switch routine is not written, it is generated** — by Ada
code that GNATprove verifies.

```
Minicoro                SPARK   coroutine lifecycle, storage API
Minicoro.Machine_Code   SPARK   x86-64 instruction encoder + switch listing
Minicoro.FTAL           SPARK   ghost register/stack typing model  (all Ghost)
Minicoro.Contexts       ——      trusted: calls the generated code
Minicoro.Code_Page      ——      trusted: W^X page from the OS
```

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
`Success: all checks proved (482 checks)` — 286 run-time checks, 79 functional
contracts, 18 assertions, 53 termination checks, and the flow analysis, with
one justification (see below).

**Proved** (GNATprove, `gnatprove -P minicoro.gpr`):

* `Minicoro.Machine_Code` in full — absence of runtime errors, termination,
  and the functional contracts, including `Resume_Point_Correct` and the
  round trip showing that the displacement bytes patched into the `lea` decode
  back to the displacement that was computed.
* `Minicoro` — absence of runtime errors across the lifecycle and storage API,
  the state-transition guards, and the storage invariant
  `Stored <= Cap` (carried as a predicate on the pool record), which is what
  makes `Push`/`Pop`/`Peek` free of overflow and of reads past written bytes.

**Assumed.** Three things, each marked in the source:

1. **The generated assembly implements `Contexts.Switch`.** SPARK has no
   semantics for machine instructions, so `Switch`'s postcondition is
   assumed of the code, not derived from it. What narrows this gap is that the
   *instruction sequence* is proved well-formed and its resume point proved to
   be an instruction boundary — the part most likely to be silently wrong.
2. **Coroutine re-entry.** SPARK models `Switch` as an ordinary call that
   returns with globals untouched. In reality control ran inside another
   coroutine first. `Resume`, `Yield` and `Switch_To` each carry a
   `pragma Assume` re-establishing what the counterpart routine restores
   before switching back, with the reasoning written out at the assumption.
3. **Stack disjointness.** `Transfer` assumes distinct pool slots hold
   distinct stack allocations. They do — each is a separate allocation — but
   SPARK cannot see it through the heap.

There is also exactly one **justified** check, in `Transfer`: SPARK's
anti-aliasing rule (SPARK RM 6.4.2) is syntactic and treats `Coros (From).Ctx`
and `Coros (To).Ctx` as possibly the same object, because the indices are not
static. `Transfer`'s precondition requires `From /= To`, so they are components
of different array elements. The justification is written out at the call site
with `pragma Annotate` and shows up in GNATprove's report rather than being
silently suppressed.

Design notes
------------

* **Coroutines are pool indices, not pointers.** `Minicoro` holds a statically
  sized array and names coroutines by index. This is what lets the lifecycle
  proofs go through without an ownership model, and it makes "is this
  coroutine still alive" a Boolean in a slot rather than the validity of a
  dangling access value. The cost is a compile-time maximum
  (`Max_Coroutines`, default 64); coroutine *stacks* are still allocated
  dynamically.
* **Layout has one source of truth.** `Machine_Code.Layout` gives the byte
  offsets of the saved-register buffer; the generated code indexes through
  those constants and `Contexts.Context` pins its representation clause to the
  same ones, so the two cannot drift apart.
* **Portability.** The x86-64 encoder covers both the Win64 and System V
  ABIs, chosen at elaboration from the compiler's target. Only
  `Minicoro.Code_Page` is OS-specific (`VirtualAlloc` / `mmap`), selected by
  the project file. Other architectures would need their own encoder; minicoro
  itself also supports ucontext and fibers, which this port does not.
