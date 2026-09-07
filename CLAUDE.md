# CLAUDE.md

Working notes for this repository. `README.md` explains the design to a
reader; this file records what you need to *operate* on the tree — how to
build, test and prove it, and the traps that cost time.

## What this repo is

A prototype for Ada generators/coroutines, in four layers, bottom up:

| Directory     | Unit                    | SPARK | Role                                        |
|---------------|-------------------------|-------|---------------------------------------------|
| `minicoro/`   | `Minicoro`              | yes*  | coroutine lifecycle + per-coroutine byte stack |
|               | `Minicoro.Atomics`       | yes*  | atomic reference count for the layers above  |
|               | `Minicoro.Machine_Code`  | yes   | x86-64 instruction encoder, switch listing  |
|               | `Minicoro.FTAL`          | yes   | ghost register/stack typing model (all Ghost) |
|               | `Minicoro.Contexts`      | yes*  | **private child**; trusted context switch   |
|               | `Minicoro.Code_Page`     | yes   | W^X page from the OS                        |
| `coroutines/` | `Coroutines`             | yes*  | ref-counted, GNAT-runtime-integrated wrapper |
| `generators/` | `Generator_Slots`        | yes   | ref counting, slot allocation, state machine |
|               | `Generator_Coros`        | yes   | the coroutine behind a generator; affinity, resume/return |
|               | `Generators`             | yes*  | generator API over `Coroutines`             |

`yes*` means the unit is `SPARK_Mode => On` with named exceptions inside it,
each marked and justified where it sits.

Coroutines and generators carry **task affinity**: one belongs to a single
task, only that task may transfer control to it, and `Detach`/`Adopt` move it
to another. That is a property of all three layers and is described in one
place, "Threading model".

No package in the tree is `SPARK_Mode => Off`, and all three proof runs are
clean: `minicoro/` 612 checks, `coroutines/` 829, `generators/` 871 — each
figure including the layers below it, since the projects with each other —
all with 2 justified and **0 unproved**.

`generators/` is the subtle one, and the two non-generic packages are why it
works. `Generators` is a *generic*; GNATprove analyses instantiations rather
than generic units, and no SPARK unit can instantiate this one (its
`Iterable` aspect names the three `Off` functions that advance a generator).
Left as one package it produced literally zero checks. Hoisting everything
that does not depend on the formal type into non-generic packages sidesteps
that entirely, because non-generic packages are analysed directly. 42 of the
871 checks are theirs:

- `Generator_Slots` — 27, the reference counting, slot allocation and the
  execution state machine. Five are postconditions, on `Claim`, `Bump`,
  `Drop`, `Set_State` and `Set_Owns_Delegate`, and they are the ones where a
  reference-counting bug would live.
- `Generator_Coros` — 15, the coroutine that runs a generator and the one
  that resumed it. This is where the affinity guard, the resume/return pair
  and kill-on-release now sit; all fourteen of its subprograms are analysed.

What is left inside the generic is only what genuinely depends on `T`: the
`Values` array and the user delegate. There is no `Generator_Record` any
more.

`minicoro/` replaced a thin binding to PCL (the old `pcl/` directory, deleted).
The `generators/` layer was untouched by that swap — the change is confined to
`Coroutines` and below.

`Coroutines` was later rewritten to get it into SPARK. Its interface is
unchanged, but underneath it is a pool of indices rather than a graph of
ref-counted pointers, and it uses GNAT's `Finalizable` aspect rather than
`Ada.Finalization.Controlled`. Read the header of `coroutines.ads` before
touching it; the reasons are not guessable from the code.

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

Expected: **2/2 minicoro, 21/21 coroutines, 11/11 generators — 34 in all.**

The seven newest cases are the task-affinity ones and each uses real Ada
tasks: `coroutines/tests/test_task_affinity`,
`coroutines/tests/test_continue_after_move`,
`coroutines/tests/test_too_many_tasks`,
`coroutines/tests/test_shared_refcount`,
`generators/tests/test_work_stealing`,
`generators/tests/test_migrate_midway` and
`generators/tests/test_advance_after_move`. They are golden-output cases like
the rest, and they are deterministic on purpose — nothing they print
depends on which task wins a race. See "Threading model".

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
cd minicoro    && gnatprove -P minicoro.gpr    --level=2 -j4 --report=fail
cd coroutines  && gnatprove -P coroutines.gpr  --level=2 -j4 --report=fail
```

Expected: `Success: all checks proved (612 checks)` for `minicoro` and
`(829 checks)` for `coroutines`, each with **2 justified, 0 unproved**. The
second figure includes the first: `coroutines.gpr` withs `minicoro.gpr`, so
that run re-analyses everything and is the one to trust if you only run one.
```sh
cd generators  && gnatprove -P generators.gpr  --level=2 -j4 --report=fail
```

Expected there: `Success: all checks proved (871 checks)`, 2 justified, 0
unproved. That run covers all three layers, so it is the single command to
use if you only run one.

A caution on the check count: it went *down*, 574 to 490, when the byte-stack
fields moved out of `Coroutine_Record` into their own array. That is not lost
coverage. The `Stored <= Cap` predicate used to sit on `Coroutine_Record`, so
every assignment to `Coro_State`, `Prev` or `In_Use` re-checked a storage
invariant it could not affect; on `Storage_Record` it guards only the data it
describes. This was confirmed by mutation rather than assumed — deleting
Push's capacity guard still produces `array index check might fail`,
`overflow check might fail` and `predicate check might fail`. If you ever
make a change that drops the count again, do the same: a smaller number and
"all checks proved" is also what losing a property looks like.

Task affinity moved it the other way, 490 to 612 in `minicoro/` and 646 to
786 in `coroutines/`. That is what adding real state looks like: three
variables became arrays, so every use is an index check; `Ready` gained an
argument, so its callers carry an extra obligation; and `Detach`, `Adopt` and
`Register` are new subprograms with contracts of their own.

Then the atomic reference count took `coroutines/` back down, 786 to 777, and
`generators/` 813 to 804 — the same nine. (The procedure forms of `Create`
and friends later took them to 829 and 856, and `Generator_Coros` took
`generators/` on to 871; both are new verified code rather than anything
moving around.) **This one was checked, not
assumed**, per the rule above. The nine are all runtime checks on arithmetic
that no longer exists in SPARK code: six `Ref_Count + 1` / `- 1` sites in
`Bump`, `Drop`, `Release`, `Claim_Slot`, `Current_Coroutine` and
`Main_Coroutine`, each carrying an overflow and a range check, replaced by
calls into `Minicoro.Atomics` whose body is `SPARK_Mode => Off`. The
arithmetic moved into a trusted subprogram; it did not stop happening.

What matters is that the *functional* property did not go with it, and that
was confirmed by mutation. Making `Generator_Slots.Drop` set `Released` on
every path still produces

```
medium: postcondition might fail, cannot prove
        Released = (In_Use (S)'Old and then Ref_Count (S)'Old = 1)
```

so the reference-counting invariant is still proved, now discharged from
`Atomics.Decrement`'s contract instead of from inline arithmetic. The
`generators/` minus `coroutines/` difference was exactly 27 at that point,
which was `Generator_Slots`' own contribution.

Hoisting `Coro`/`Caller` into `Generator_Coros` then took `generators/` from
856 to 871, and that difference from 27 to 42. Same rule, opposite direction
and no mystery: the 15 are a new non-generic package's own checks, on code
that GNATprove could not see while it sat inside the generic. The split is
visible in the run itself -- `generator_coros` reports 14 subprograms out of
14 analysed, where `generators` still reports 0 out of 0. `coroutines/` is
untouched at 829, as it must be: nothing below `generators/` changed.

Each run takes roughly 10-40 minutes — start it in the background and do not
poll it. `--level=3` also passes; `--report=statistics` if you want per-check
detail.

The default run is not warning-free. `Code_Page` brings most of them, all one
fact — GNATprove does not model writes through an `Import` overlay at a
computed address; see "What `Code_Page` being SPARK does and does not buy"
below. The one that is not `Code_Page` is

```
warning: pragma "Thread_Local_Storage" ignored (not yet supported)
--> minicoro.adb
```

which is GNATprove stating the limitation recorded under "Threading model":
it analyses `Me` as an ordinary variable, which is the right model for proofs
that are all about one thread of control. Nothing else in the default run
warns.

`obj/gnatprove/gnatprove.out` holds the summary table; read lines 5-24.

Do not run `gprbuild` and `gnatprove` on the same directory at the same time —
they share `obj/`. That includes `alr build` and `alr test`, which call
`gprbuild`. Proving `coroutines/` reads `minicoro/`'s sources but writes only
`coroutines/obj`, so those two proof runs can overlap with each other.

There are two justifications, both in `minicoro/` and both written out with
`pragma Annotate` at the site. `coroutines/` has none.

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

## What cannot be SPARK, and why

Each of these was confirmed against GNATprove rather than assumed. Do not
"clean them up" by flipping the pragma: the list below is what the tool
actually rejects.

### In `minicoro/` — eight, six machine-level and two concurrent

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
7. **`Minicoro.Atomics`** (private part and body; the visible part is On).
   The counter's full view carries `Atomic`, which SPARK treats as
   effectively volatile and would force any abstract state holding one to be
   `External`; hiding it is what keeps the reference-counting postconditions
   provable. See "Reference counts are atomic" under "Threading model".
8. **`Minicoro.Threads`** (body only; the spec is On). One
   `Atomic_Fetch_And_Add`, from
   `System.Atomic_Operations.Integer_Arithmetic`, handing out thread
   numbers. SPARK has no model of an atomic read-modify-write. This is the
   only genuinely concurrent code in the tree, and its `Global => null` is
   a claim about the Ada state SPARK reasons over rather than about the
   counter, which nothing else observes. See "Threading model".

The recurring hard errors behind those, for reference:

- `attribute "Address" outside an attribute definition clause is not allowed
  in SPARK [E0002]`
- `unchecked conversion instance to an access to subprogram type` / `from a
  type with access subcomponents`
- `access to subprogram with global effects is not allowed in SPARK`
- `effectively volatile object not at library level [E0001]`

### In `coroutines/` and `generators/` — language-level, not machine-level

A different kind of list. Nothing here is about machine state; every item is
a place where the published interface and the SPARK subset disagree.

1. **The `Create`, `Current_Coroutine`, `Main_Coroutine` *functions*** —
   `SPARK_Mode => Off` on the *declarations*, not just the bodies. A SPARK
   function may not write globals (`E0005`), and handing out a coroutine has
   to bump a reference count. Marking only the body is not enough: GNATprove
   infers the global and rejects the declaration.

   Each of the three now also has a **procedure form**, which is `On` and
   proved, because a procedure may write globals. That is not cosmetic: the
   Off declarations are *contagious* to the caller —

   ```
   error: "C" is not allowed in SPARK (due to entity declared with
          SPARK_Mode Off)
   ```

   on `C : constant Coroutine := Create (...)` — which took the client's whole
   unit out of SPARK, race checking included. See "Proving a client" below.
   The function forms stay for compatibility; every test in the tree uses
   them.
2. **`Spawn`, `Switch`, `Kill`** — they raise, and they are primitives of a
   tagged type. `aspect "Exceptional_Cases" on dispatching operation is not
   yet supported`, so there is no way to declare what comes out of them.
   `Coroutine` has to stay tagged because the whole codebase calls these in
   prefix notation (`C.Spawn`). The work is in `Spawn_Slot`, `Switch_Slot`
   and `Kill_Slot`, which are analysed and do carry `Exceptional_Cases`.
3. **`Raw`** — the body only; its spec is SPARK so the rest of the package
   can call it. Eight operations, four distinct rejections:
   `instance of Unchecked_Deallocation with a general access type is not
   allowed in SPARK` (`Delegate_Access` is `access all`);
   `attribute "Address" outside an attribute definition clause` (the
   secondary-stack overlay); `access to subprogram with global effects`
   (`Coroutine_Wrapper'Access`); and
   `choice parameter in handler is not allowed in SPARK`, which is what
   forces `Capture_Abort` and `Run_Delegate` out — capturing an occurrence
   needs `when E : others`, and SPARK has no way to name `E`.

`Raw` also holds `Save_Sec_Stack`/`Restore_Sec_Stack`. Those are not
*rejected* — they were moved because `System.Soft_Links` reaches the
secondary stack through a variable of access-to-subprogram type, so each call
is a dereference SPARK wants proved non-null and whose target's effects it
cannot see. Grouping them with the rest of the runtime plumbing was cheaper
and more honest than sprinkling null guards through `Switch_Slot`.

`Generators` has the same shape for the same reasons: `Create` and the four
`Iterable` functions are `Off` because a SPARK function may not write
globals, `Yield` because it is a dispatching operation that raises, and its
own `Raw` for the delegate hand-off. `Generator_Slots`, which holds the state
those operations manipulate, is `On` throughout with no exceptions at all.

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

### Proving a client

A SPARK program that uses coroutines can be analysed, and GNATprove will then
report data races on *its own* variables. `coroutines/examples/spark_client`
is a worked example that proves clean, and it is proof-only -- not built by
`alr build`, not run by `alr test`, because its Ravenscar tasks do not
terminate:

```sh
cd coroutines/examples/spark_client && gnatprove -P spark_client.gpr -j8 \
  --report=fail
```

Expected: `Success: all checks proved (839 checks)`, 3 justified, 0 unproved,
and an empty `Concurrency` row -- no data races.

Four things a client needs, all found by trying:

1. **The procedure forms of `Create`** and friends. The function forms are
   `Off` and that is contagious; see the item above.
2. **`pragma Elaborate_Body`** in any package declaring a delegate. Without it
   the type extension is rejected with `E0003`, "first freezing point of type
   must appear within early call region of primitive body" (SPARK RM 7.7(8)):
   a dispatching call could otherwise reach `Run` before its body is
   elaborated. `gnatprove --explain=E0003` gives exactly this fix.
3. **The delegate's `Run` may touch only its own components.** It overrides an
   abstract operation whose inferred `Global` is null, and SPARK RM 6.1.6
   requires an override's `Global` to be subsumed by the overridden one's.
   Reaching for a package variable gets `"X" is an In_Out of overriding
   subprogram, but it is not an Input of overridden subprogram "Run"`. There
   is no fix on the library side: a `Global` that covers every possible
   override does not exist. Put the state in the delegate record.
4. **Only one task may call into the library.** SPARK reports
   `possible data race when accessing variable "coroutines.registry"`
   otherwise, and it is right -- concurrent `Create` is the one operation
   still unsynchronised. Note that `minicoro.affinity` will also be reported,
   and *that* one is a false positive: it is the thread-local owner id, and
   GNATprove does not model `Thread_Local_Storage`.

The client's own allocator (`new Step`) draws
`resource or memory leak might occur`, because `Delegate_Access` is a general
access type and SPARK's ownership model does not track it. The example
justifies it at the site with the obligation `Create` already documents:
ownership transfers, so do not retain or free it.

**Generators cannot be used from SPARK, and that is irreducible.** `Yield` is
a dispatching operation that raises, and `Has_Next`/`Next`/`Element`/
`Has_Element` are functions that advance the generator, so all of them write
globals; the `Iterable` aspect fixes their profiles, so they cannot become
procedures. A procedure form of `Generators.Create` would let a client build a
generator it could not then use, so there is not one.

It fails earlier than at `Yield`, though, and that is the part worth knowing.
A SPARK unit cannot even *declare* the instantiation, so there is no
`Generator` for it to hold and nothing to call `Yield` on. Checked against
GNATprove 16.1 with a delegate whose `Generate` calls `G.Yield`:

```
error: "Yield" is not allowed in SPARK (due to entity declared with
       SPARK_Mode Off)
error: instantiation error at generators.ads:75
       + "Next" is not allowed in SPARK (due to entity declared with
          SPARK_Mode Off)          [and the same for Has_Element, Element]
error: instantiation error at generators.adb:77
       + function "New_Coroutine" with output global "Registry" is not
          allowed in SPARK [E0005]
```

That last one is new information: `Raw.New_Coroutine` is a genuine `E0005`
that the `Off` pragma on `Raw`'s body has been covering. It only surfaces
once an instantiation makes the generic body concrete.

A third wall stands behind those two even if both were removed. `Generate`
overrides an abstract operation whose inferred `Global` is null, and SPARK RM
6.1.6 requires an override's `Global` to be subsumed by the overridden one's
-- the same rule recorded above for `Coroutines.Delegate.Run`. `Yield` writes
the pool, so a `Generate` that calls it violates that no matter what mode
`Yield` carries.

The one thing a client does need first, and gets wrong once: a delegate's
package needs `pragma Elaborate_Body`, or the type extension is rejected with
`E0003` before any of the above is even reported.

### Calling a generator from SPARK

You cannot, directly -- but you can put one behind a boundary, and
`generators/examples/spark_client` is a worked example that proves clean. It
is proof-only, like the coroutines one: not built by `alr build`, not run by
`alr test`, because there is no main at all and the point is what GNATprove
says.

```sh
cd generators/examples/spark_client && gnatprove -P spark_client.gpr -j4 \
  --report=fail
```

Expected: `Success: all checks proved (880 checks)`, 2 justified, 0 unproved.
That figure is the whole library's 871 plus the example's own 9.

The shape is the one used everywhere in this tree that SPARK cannot express
something -- `Minicoro.Atomics` hides an atomic counter, `Minicoro.Contexts`
hides a machine context switch, `Squares` hides a generator:

```
Safe_Client (SPARK_Mode => On, fully analysed)
   |  calls a procedure with Global => (In_Out => Squares.State)
   v
Squares      spec SPARK_Mode => On, Abstract_State => State
             body SPARK_Mode => Off  <-- instantiation, delegate, Yield,
                                         Has_Next/Next all live here
```

Three things about it are load-bearing, and were found by trying:

1. **The boundary must be a procedure.** A SPARK function may not write
   globals (E0005) and driving a generator does. Same reason `Coroutines`
   grew procedure forms of `Create` and friends.
2. **The boundary must be bounded.** The result comes back as an array plus a
   `Count`, not as a lazy sequence, because a SPARK caller needs a size to
   reason about. This is a real loss: laziness is the point of a generator
   and it does not survive the crossing. If a caller wants the values one at
   a time it cannot have them, and no amount of contract writing changes
   that.
3. **The body carries no `Refined_State`.** A `SPARK_Mode => Off` body may
   not, and `State` staying opaque is the intent -- see the rule under
   "GNATprove-specific rejections".

What the client gets is worth being precise about: `Safe_Client` is ordinary
analysed SPARK, and GNATprove proves its arithmetic (that summing yielded
values cannot overflow `Natural` in either direction). What it does *not* get
is any guarantee about the generator, because `Squares`' body is not
analysed. The contract `Post => Got = Wanted` is a claim, not a proof, in
exactly the way `Contexts.Switch`'s postcondition is.

### How `generators/` got analysed, and why the tests still cannot be SPARK

Two facts about generics collide here, and the way round them is worth
knowing before touching this layer.

**A SPARK function may not write globals** (`E0005`). `Has_Next`, `Next`,
`Element` and `Has_Element` all advance the generator, so all four write the
pool. They cannot become procedures, because the `Iterable` aspect fixes
their profiles and `for X of G` is the point of the package. So they are
`Off`.

**GNATprove analyses instantiations, never generic units** — and an
instantiation from SPARK is rejected outright, because `Iterable` names those
`Off` subprograms:

```
error: instantiation error at generators.ads:73
--> support.ads:9:04
      + "Next" is not allowed in SPARK (due to entity declared with
         SPARK_Mode Off)
```

Together those meant the generic produced *zero* checks no matter what was
done to it, and no test could help: any SPARK unit instantiating `Generators`
fails identically. Making the tests SPARK is not the missing ingredient.

Two ways round that look plausible and are not. Both were run against
GNATprove 16.1 rather than reasoned about:

- **`Side_Effects`** (SPARK 2022's functions-with-side-effects) lets a
  function write globals, which is exactly the `E0005` obstacle — but it makes
  the function volatile, and the aspect rejects those by name: `volatile
  function associated with aspect Iterable is not allowed in SPARK`.
- **Hoisting more state out of the generic**, the `Generator_Slots` trick
  applied to `Coro`/`Caller`, does not rescue the `Iterable` four either. An
  instantiation draws `function associated to aspect Iterable with dependency
  on globals is not allowed in SPARK` — *depends on*, not writes, so `Element`
  is refused for merely reading the pool. Hoisting moves where the globals
  live; the rule is about touching globals at all. It would still get the
  coroutine plumbing analysed, which is why it stays on the list under "Not
  done" — just know it is a partial win.

**The way round is to hoist.** Only two of the nine things a generator slot
holds actually depend on the formal type. The rest went into non-generic
packages, where they are analysed directly with no instantiation involved:

| Stayed in the generic | `Generator_Slots` | `Generator_Coros` |
|-----------------------|-------------------|-------------------|
| `Values`, `Delegate`  | `Ref_Count`, `In_Use`, `Owns_Delegate`, `State` | `Coro`, `Caller` |

`Delegate` has to stay: `Generators.Delegate` is declared inside the generic,
because `Generate` takes a `Generator'Class`. `Values` has to stay because it
is an array of `T`. Nothing else did, and the old `Generator_Record` that
held them together is gone -- the generic keeps two flat parallel arrays now,
which is the house style for the reason under "Keep the odd component out of
the record".

`Generator_Coros` was the second half of that split and came later. Two
shapes in it are worth knowing before touching it:

- **Refusal comes back as a status code, not a raise.** `Resume` reports
  `Wrong_Task` the way `Minicoro` does, and `Generators.Advance` turns it
  into `Generator_Error`. It has to work that way round: `Generator_Error` is
  declared *inside* the generic, so each instantiation has its own and a
  non-generic package cannot name it.
- **`Detach` and `Adopt` are the deliberate exception** and let
  `Coroutine_Error` through, because `Generators` re-raises it as
  `Generator_Error` carrying the same message, and that message is worth
  keeping.

One property was tried and dropped rather than forced: `Clear` would like
`Post => not Is_Alive (S)`, which is true. It does not prove, because the
prover would have to know that `Coroutines.Null_Coroutine` is not alive.
`Coroutines.Alive`'s body is an expression function over `Alive_Slot`,
visible only inside that package, and `Coroutine`'s full view sits in a
private part, so a postcondition on `Alive` could not name the slot either.
Stating it meant widening `Coroutines`' interface to serve one caller, which
is the worse trade; the reasoning is recorded at the site.

`Generator_Slots` carries real functional contracts rather than just runtime
checks — `Drop` states the reference-counting invariant and proves it:

```ada
Post => Released = (In_Use (S)'Old and then Ref_Count (S)'Old = 1)
          and then (if Released then not In_Use (S))
```

It is a procedure with an `out` parameter rather than a function returning
the answer, for the same `E0005` reason that shaped everything else here.

If you add state to a generic in this tree, ask first whether it depends on
the formal types. If it does not, it belongs in a non-generic package, or it
will never be checked.

### The tests cannot be `SPARK_Mode => On`

Three independent reasons, found by turning them all on and reading what
GNATprove said. The third is decisive.

1. `Create` is a function that writes globals, so it is `Off` — and that is
   contagious to the caller's own data:
   `error: "C" is not allowed in SPARK (due to entity declared with
   SPARK_Mode Off)` on `C : constant Coroutine := Create (...)`. Every test
   starts that way.
2. `allocator not stored in object as part of assignment, declaration or
   return is not allowed in SPARK` — `Create (new Null_Delegate)` is the
   idiom in a dozen tests. Fixable by hoisting, but pervasive.
3. Five tests print `Exception_Name (Exc) & ": " & Exception_Message (Exc)`
   from a handler, and their `ref/` files contain that output. SPARK rejects
   the choice parameter (`when Exc : ...`), so making them SPARK means
   deleting the thing they assert. That would weaken the tests to satisfy the
   prover, which is backwards.

The tests are deliberately outside SPARK and should stay there. They are the
behavioural oracle; the proof is a separate argument about the library.

### How `Coroutines` got into SPARK

Two things had to change, and neither was avoidable.

**Controlled types are rejected outright** — `error: "Controlled" is not
allowed in SPARK (due to controlled types)`. GNAT's `Finalizable` aspect does
the same job and *is* analysed, so `Coroutine` now carries
`Finalizable => (Adjust => Bump, Finalize => Drop)`. It needs `-gnatX`.

**Reference counting is shared ownership, which SPARK does not have.** Two
handles onto one coroutine are two owning pointers to the same object, which
is exactly what its ownership model forbids. So the handle became an index
into a statically sized pool, as `Minicoro` did one layer down: copying a
handle copies an integer and there is nothing to alias. That also deleted the
old `C'Address` → `Minicoro.User_Data` →
`System.Address_To_Access_Conversions.To_Pointer` round trip, which was three
separate SPARK violations, and with it `Minicoro.User_Data` itself.

Two things that are *not* obstacles, contrary to expectation:
`Ada.Exceptions.Save_Occurrence`/`Reraise_Occurrence` are legal SPARK, and so
is an `exception when others` handler. Only a *choice parameter*
(`when E : others`) is rejected. Both were checked in isolation.

The visible costs are three, all recorded in `coroutines.ads`: a compile-time
ceiling (`Max_Coroutines`), `Create` returning `Null_Coroutine` instead of
raising when the pool is full (a SPARK function may not propagate), and
`Delegate` being an abstract tagged type rather than an interface — see the
GNAT bug under "Traps that cost time".

## Proof warnings: where this stands (2026-09-06)

**Status: all checks prove, in both the default and the extended run, and
none of them vacuously.** The `pragma Assume is always False` family is
fixed. Read this before touching `Resume`, `Yield`, `Switch_To` or
`Transfer`.

### The extended run

Two warning families are off by default. Turn them on:

```sh
cd minicoro && gnatprove -P minicoro.gpr --level=2 -j4 --report=fail \
  --pedantic --proof-warnings=on
```

`Success: all checks proved (612 checks)` and **21 warnings**:

| Count | Kind                                    | Group |
|-------|-----------------------------------------|-------|
| 11    | `operator-reassociation`                | 2     |
| 7     | `Code_Page` overlay family              | 3     |
| 1     | `unreachable code`                      | 4     |
| 1     | `representation-attribute-value`        | 5     |
| 1     | `ignored-pragma`                        | 7     |

None of them has verification consequences any more.

### 1. `pragma Assume is always False` — fixed

**This was a real defect and it is now closed.** It cost the postconditions of
`Resume`, `Yield` and `Switch_To`, which were reported as unreachable
branches and were therefore *not verified* despite appearing in the check
count. They are verified now.

The cause: `Transfer` never assigned `Current`, so SPARK's inferred `Global`
for it did not mention `Current` and the prover concluded it was unchanged
across the call. But `Resume` sets `Current := C` *before* calling
`Transfer`, and the guard above it rules out `C = Prev`. So:

```ada
Current := C;
Transfer (Prev, C);
pragma Assume (Current = Prev);   --  provably False
```

A contradictory `pragma Assume` makes everything after it vacuously
provable. `Yield` (`Current := Prev` then `Assume (Current = C)`) and
`Switch_To` (`Current := Target` then `Assume (Current = Cur)`) failed the
same way, and the second assume in each pair was flagged only for sitting
downstream of the first.

**The fix**, in `minicoro.adb`: a helper whose contract declares the effect
and whose body is opaque to SPARK, called at the end of `Transfer` the
instant `Contexts.Switch` returns.

```ada
   procedure Control_Transferred
     with Global => (In_Out => (Coros, Current));
   --  body: pragma SPARK_Mode (Off); null;
```

With `Current` and `Coros` havoc'd, the three `pragma Assume`s stopped being
contradictions and became genuine restorations, and the postconditions are
proved from them for real. The helper compiles to nothing, so there is no
runtime effect; the 34-case suite was re-run to confirm it.

Do not write an explicit `Global` on `Transfer` itself — it would have to
enumerate `Main_Ctx` and `Contexts.Backend_State`, and the child's state is
deliberately `Part_Of => Minicoro.Pool` so that callers do not have to name
it. Letting inference pick `Current` up from `Control_Transferred` is the
whole trick.

The feared blast radius did not materialise. Havocking `Coros` makes every
pool fact unknown after a `Transfer`, but all three call sites do nothing
afterwards except assign `Res` and return, and `Trampoline` — the fourth
caller, which had not been analysed when the risk was written down — ends in
its unreachable spin. Nothing downstream needed the facts that went away.

`minicoro.adb:352` (`Res := Not_Suspended`) used to be reported here too, and
is now gone for a better reason than suppression. `Resume` had
`Pre => Status (C) = Suspended`, which made the guard dead to the prover. That
precondition was doing no work: nothing in SPARK calls `Resume` (`Coroutines`
uses `Switch_To` and `Destroy`; the tests are not SPARK), and no `.gpr` in the
tree passes `-gnata`, so it was neither verified nor checked at run time --
while the guard it shadowed was the only thing actually stopping a caller from
resuming a `Running` coroutine. The precondition is gone and `Resume` is now
total, like `Switch_To`. `Yield` and `Destroy` keep theirs; they are not in
the same position.

### 2. `operator-reassociation` — 11 warnings, cosmetic, deliberately deferred

`--pedantic` only. Ada (RM 4.5) lets a compiler reassociate a chain of
same-precedence predefined operators, so `A + B + C` may be evaluated as
`A + (B + C)`; the prover assumed left-to-right. It can only *change* anything
if an intermediate overflows, and none of these can — they are byte-range
encoder arithmetic and small index sums.

Sites: `minicoro.adb:856,881,907` (`Base + 1 + (I - Src'First)`),
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
at index 11), GNAT folds the search accordingly, and the 34-case suite passes
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

### 7. `ignored-pragma` at `minicoro.adb:104` — GNATprove does not model
thread-local storage

```
warning: pragma "Thread_Local_Storage" ignored (not yet supported)
```

Also in the **default** run, and the only default-run warning that is not
`Code_Page`. GNATprove analyses `Me` as an ordinary variable, which is the
right model for these proofs — every one of them is about one thread of
control. What the pragma buys is that a second thread gets a second copy, to
which each of those proofs still applies; that step is assumption 10 under
"What is proved vs assumed". Nothing to fix.

### Resuming

Family 1 is done. Family 2 is independent and can be skipped or done at
leisure; families 3, 4 and 5 are tool limitations or deliberate trades, not
work items. If you touch the lifecycle again, re-run the extended command
above and confirm the count is still 21 with no `pragma Assume is always
False` among them — that warning reappearing is the signal that the re-entry
model has drifted.

## Traps that cost time

**GNAT miscompiles `Unchecked_Deallocation` of an interface class-wide object
with a `Finalizable` component.** This cost hours. Symptom:
`free(): invalid size`, or a `Storage_Error` reported as
"stack overflow or erroneous memory access", at a deallocation whose pointer
and object are both demonstrably intact. Under valgrind it is
`Detach_Object_From_Collection` reading a header 24 bytes before a block that
never had one: the allocator emitted a plain block, the deallocation assumed
a collection-attached one.

Minimal reproduction, ~40 lines over three units, all with `-gnatX`:

- unit A declares a `Finalizable` type and an **interface**, plus
  `type P is access all Iface'Class` and an `Unchecked_Deallocation` on it;
- unit B declares a type implementing that interface **with a `Finalizable`
  component**;
- unit C allocates one as `P`; A frees it.

The workaround is to root the class-wide type at an ordinary tagged type:
`Coroutines.Delegate` is `abstract tagged null record`, not `interface`, and
that alone makes the corruption go away. If you ever change it back, the
three tests that catch it are `test_resume_simple`, `test_foreign_kill` and
`test_spawn_switch_kill`. Note that a plain run may still *pass* while
corrupting the heap — check under valgrind, which reports it precisely.

**`pragma Extensions_Allowed (On)` is not enough for clients.** It lets the
unit that writes `Finalizable` compile, but a client compiled without
`-gnatX` silently gets a different view of the type's finalization, and you
get the mismatch above rather than an error. `-gnatX` must be on every unit
that can see the type, which is why all six `.gpr` files carry it.

**GNAT stops warning about unwritten formals when a type stops being
controlled.** `test_secondary_stack` declares helpers taking
`Delegate'Class` as `in out` and only reads them. That was silent while
`Coroutine` was `Ada.Finalization.Controlled` and started failing the build
under `-gnatwae` when it became a `Finalizable` record. The test source is
deliberately unchanged; `coroutines/tests/tests.gpr` turns `-gnatwK` and
`-gnatwU` off *for that one file*.

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

**Keep global state scoped and keep structs narrow.** This is the one design
rule in the tree that paid off repeatedly, and each layer learned it the hard
way.

*Name the state.* `Minicoro` declares four abstract states — `Pool`,
`Storage`, `Backend`, `Current_State` — rather than one lump, and
`Coroutines` declares `Registry` (who exists) and `Sched_State` (what is
running). This is not tidiness. `Coroutines` originally had four raw globals
and no `Abstract_State` at all, so nothing ever had to say it was
initialised; naming the state forced an `Initializes` contract, which
immediately failed with `"Pool" constituent of "Registry" is not
initialized`. A latent gap the single lump had been hiding.

Splitting `Minicoro.Pool` also let flow analysis express something the merged
state could not:

```
medium: "Minicoro.Pool" must be a global Proof_In of "Push"
low:    global Input "Minicoro.Pool" of "Push" not read
```

`Push` reads the pool only in its *precondition*, never in its body — that is
`Proof_In`, not `Input`, and the contract now records it.

*Keep the odd component out of the record.* Three times now, one field with
no default that SPARK can see has made an entire enclosing record count as
uninitialised:

| Field | Type | Now lives in |
|-------|------|--------------|
| `Exc` | `Exception_Occurrence` (limited private) | `Coroutines.Excs` |
| `Yield_Value` | formal private `T` | `Generators.Values` |
| `Store`/`Stored`/`Cap` | (predicate, not init) | `Minicoro.Stores` |

The first two were blocking `Initializes`; the third was making
`Control_Transferred` havoc the byte stacks on every context switch, so
nothing could be said about a coroutine's storage across `Resume` or `Yield`.
In all three cases a parallel array indexed the same way fixed it, and the
enclosing record went back to being fully default-initialised.

*And in a generic, splitting the struct is what gets it analysed at all.*
This is the same rule with a much larger payoff, because the alternative is
not a weaker proof but no proof. `Generators`' old `Generator_Record` held
nine things, of which two depend on the formal type; GNATprove does not read
generic units, so all nine were invisible. Splitting it twice --
`Generator_Slots` first, `Generator_Coros` later -- moved seven of them into
non-generic packages and took the layer from 0 checks of its own to 42. The
question to ask of any state in a generic here is not "is this tidy" but
"does this depend on the formal types", because if it does not, leaving it
inside means it is never checked.

**Coroutines are pool indices, not pointers — at both layers.** `Minicoro`
holds
`Coros : array (Valid_Id) of Coroutine_Record` and names coroutines by index.
This is the single decision that makes the lifecycle provable — no aliasing for
SPARK's ownership model to police. Cost: a compile-time `Max_Coroutines`
(64) and `Max_Storage` (1024 bytes/coroutine, static). Stacks are still
heap-allocated and are not counted in that.

`Coroutines` was later made to do the same thing for the same reason, and the
reason is worth being precise about: ref counting *is* shared ownership, and
SPARK's ownership model has only unique ownership. A `Coroutine` handle is
now a `Slot_Id`, so copying one copies an integer and no two handles are
aliased pointers. `Max_Coroutines` there is 128 and counts unspawned and dead
coroutines too, since a slot is held for as long as any handle names it.

A consequence worth knowing: the two layers have *separate* pools with
separate limits, joined by `By_Coro : array (Minicoro.Valid_Id) of Slot_Id`.
That array is what replaced the old address round trip, and it is the only
thing tying the two id spaces together.

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

## Threading model

**Coroutines belong to one task, and moving one is an explicit operation.**
This replaced an earlier, blunter rule ("single-threaded, and load-bearing"),
and the reason it could be replaced cheaply is the same reason everything else
here works: the state that was really per-thread became arrays indexed by a
thread number, exactly as coroutines are arrays indexed by a coroutine number.

Three variables at the bottom of the tree were per-thread all along and were
not stored that way:

| Was | Is now |
|-----|--------|
| `Minicoro.Main_Ctx` | `Main_Ctxs : array (Valid_Owner) of Context` |
| `Minicoro.Current`  | `Currents : array (Valid_Owner) of Coroutine_Id` |
| `Minicoro.Backend_Up` | `Backend_Up : array (Valid_Owner) of Boolean` |

and one layer up, `Coroutines.Previous_Slot` and `Coroutines.Booted` went the
same way, while the single reserved `Main_Slot` became the reserved *range*
`Task_Slot` — slot N is task N's own main coroutine.

`Minicoro.Max_Owners` (16) is the ceiling. Numbers are handed out on first use
and **never reused**, so it is a budget of threads over the life of the
process, not of live threads; a program that spawns and joins tasks in a loop
will exhaust it and start getting `Too_Many_Tasks`.

### How a thread knows its own number

One thread-local scalar, `Me` in `minicoro.adb`, and it is the only
thread-local object in the tree:

```ada
Me : Owner_Id := No_Owner;
pragma Thread_Local_Storage (Me);
```

`Minicoro.Current_Owner` is a plain read of it. Compiled at `-O2` the whole
function body is

```
minicoro__current_owner:
        movzbl %fs:0x0,%eax
        ret
```

so an affinity check is one `%fs`-relative load and one compare, and the load
inlines away at most call sites. No lock, no atomic on any hot path, and
nothing that drags in the tasking runtime: a program with no tasks pays that
and nothing else. (Confirm it the same way if you touch this — build
`minicoro.adb` at `-O2` and `objdump -d minicoro.o`; the default build has no
`-O` flag, so a debug build shows a stack frame and says nothing.)

`Current_Owner` is a *function* and must stay one — it appears in contracts
and inside other observers — so it cannot do the numbering, because a SPARK
function may not write globals (E0005). The numbering is in `Ensure_Owner`,
called only from `Ensure_Backend`, which is reached only from `Create`,
`Adopt` and the public `Register`. A thread that merely observes never
consumes a number.

The counter behind it is the one genuinely concurrent thing in the tree:
`Threads.Next_Owner`, a nested package whose spec is SPARK and whose body is
`SPARK_Mode => Off`, doing one `Atomic_Fetch_And_Add` from
`System.Atomic_Operations.Integer_Arithmetic` (Ada 2022, so not a GNAT
private unit). Its counter type is deliberately much wider than `Max_Owners`:
two threads can both pass the cheap pre-check and both increment, and a
counter that stopped at `Max_Owners` would raise `Constraint_Error` on the
second rather than simply refusing it.

### The rule, and what enforces it

Every operation that transfers control or frees a stack checks the owner and
reports `Wrong_Task` (`Minicoro`) or raises `Coroutine_Error` (`Coroutines`,
`Generators`). `Push`/`Pop`/`Peek` deliberately do **not** check: they touch a
byte array and never a context, so they cannot put a thread on another
thread's stack, and a task that has just adopted a coroutine legitimately
wants to read what the previous owner pushed. Leaving them alone also keeps
their (strong, proved) postconditions intact.

What is *not* guarded, and on purpose: observers (`Alive`,
`Owned_By_Current_Task`, `Is_Detached`, `"="`), copying a handle, and reading
a value a generator has already yielded — `Generators.Next` hands back what is
sitting in the slot without resuming anything. The line is control transfer,
not reading. Probed empirically rather than assumed; from a foreign task:

| Operation | Result |
|---|---|
| `C.Alive`, `C.Owned_By_Current_Task`, `C = C` | allowed |
| copy of a handle (`Bump`) | allowed, and safe — the count is atomic |
| `G.Next` on an already-yielded value | allowed |
| `C.Spawn`, `C.Switch`, `C.Kill` | `Coroutine_Error` |
| `C.Detach`, `C.Adopt`, `G.Detach`, `G.Adopt` | `Coroutine_Error` / `Generator_Error` |
| `G.Has_Next` when it must actually resume | `Generator_Error` |

That last row needed a fix to be true. `Generators.Advance` now tests
ownership itself and raises `Generator_Error`; left to
`Coroutines.Switch` it raised `Coroutine_Error`, which would have been the
one place in that package where a caller saw a different exception. It cannot
be done by wrapping the switch in a handler, because that switch legitimately
propagates whatever the generator died of.

`Detach` and `Adopt` are the move. Two operations rather than one because
there is no handle on another thread to move a coroutine *to*: only the
receiving thread can adopt, since adopting is what says "I may now switch to
this". In between, the coroutine belongs to nobody and no thread may switch to
it — which is what makes the hand-off safe without a lock, and is also exactly
the work-stealing shape.

`Minicoro.Detach` refuses (`Coroutine_Busy`) unless the coroutine is parked:
not `Running`, and not `Awaited_By_Another`. That second predicate scans the
pool for any live coroutine whose `Prev` names this one, and it is the
condition that is easy to get wrong — if A resumed B, it is *B* that records
the link, so looking only at A's own state would let A move out from under B.
The scan is O(`Max_Coroutines`) and runs only on `Detach`.

A successful `Detach` also clears `Prev` and forces the state to `Suspended`.
Both matter: `Prev` would otherwise send the completion path back into the
releasing task, and `Normal` — "active, but it resumed someone else" — would
make the coroutine ineligible for `Resume` *and* for `Destroy`, so a detached
generator's stack would leak. A generator sits in `Normal` between yields,
because `Switch_To` puts the source there, so this is the common case rather
than a corner one.

### Two re-entry traps, both about stale owner numbers

A coroutine's stack outlives the thread that last ran it. So **any local
holding an owner number across a switch is stale after a migration**, and
there are exactly two places where that matters:

* `Minicoro.Trampoline` reads `Me` *after* the body returns, not on entry. The
  thread that finishes a coroutine need not be the one that started it, and it
  is the finishing thread whose `Main_Ctxs` entry we return to. It carries a
  `pragma Assume (Ready (Owner))` for the same reason the other re-entry
  assumptions exist.
* `Coroutines.Switch_Slot` re-reads the owner after `Minicoro.Switch_To`
  returns. That invocation may live on a coroutine's stack — `Yield_Slot` and
  `Run` both call it — and everything after it indexes per-task state.

  This one is defensive, and honestly so: it was not provoked by any test.
  `Current_Slot` gives the right answer either way, because it goes through
  `Minicoro.Running_Coroutine`, and `Detach` clears `Previous_Slot` for the
  releasing task, which hides the difference in the obvious cases. What is
  left is a genuine cross-task write — reading another task's
  `Previous_Slot`, finding a `To_Clean` slot there and `Reset`ting it — that
  needs a specific interleaving to reach. It was fixed by reasoning rather
  than by a failing test, and reverting it does not make the suite fail.

`Resume`, `Yield` and `Switch_To` do *not* need this: after their `Transfer`
they do nothing but a `pragma Assume` and `Res := Success`, so a stale number
has no runtime effect. `Coroutine_Wrapper` is correct by construction: it
calls `Ensure_Booted` after `Run_Delegate` rather than before, which is the
same discipline written a third way.

`Control_Transferred` havocs `Coros` and `Currents` but deliberately **not**
`Me`: the switch routine does not touch `%fs`, so the thread executing after
it is the thread that was executing before it. Migration happens in the *gap*
between switching out and being switched back in, not during the switch.

### Reference counts are atomic; slot allocation is not

**Handles are safe to share across tasks.** `Coroutines.Coroutine_Record.
Ref_Count` and `Generator_Slots.Counts` are `Minicoro.Atomics.Counter`, so a
handle may be copied and dropped on any task whether or not that task owns the
coroutine. Lifetime and scheduling are different questions, and affinity
guards only the second.

That was not a theoretical fix. `coroutines/tests/test_shared_refcount` runs
eight tasks copying and dropping one handle 50_000 times each; with the
ordinary `if N < Natural'Last then N := N + 1` it aborts with `double free or
corruption` inside a second, because lost increments drive the count to zero
and release a slot the environment task still holds. With the atomic counter
it is clean, under valgrind too.

**The shape of the counter is dictated by SPARK**, and the obvious spelling
does not work. An `Atomic` scalar in the pool array is *effectively volatile*
to SPARK, so the enclosing abstract state has to be declared `External`:

```
error: non-external state "Slots" cannot contain external constituents in
       refinement
```

and external state cannot be read in the ordinary expressions that
`Generator_Slots`' contracts are made of. So `Minicoro.Atomics.Counter` is a
private type whose full view is `SPARK_Mode => Off` — the same trick as
`Contexts.Context` and `Stack_Handle` — with an observer `Value` and
contracts saying what `Increment` and `Decrement` do. The prover never sees
an `Atomic` aspect, and **`Generator_Slots.Drop`'s postcondition survives
unchanged**, which was the thing worth protecting.

`Decrement` returns `Was_Last` rather than letting the caller re-read the
count, and that is the whole point: two tasks dropping the last two
references both see a non-zero count if they look first, but exactly one of
them is told it took the count to zero.

What is trusted is that the body is *indivisible*; SPARK cannot check that.
It was checked by experiment instead — eight tasks × 200_000 increments land
on exactly 1_600_000, where a plain `Natural` lands around 600_000.

**What is still not synchronised: concurrent `Create`.** `Claim_Slot` scans
the shared pool for a free slot and then marks it, and those are two steps, so
two tasks scanning together can pick the same one. Releasing concurrently is
fine — that path is driven by the atomic count. Allocate on one task, hand the
work out, and it does not arise.

Fixing that properly is harder than it looks and was deliberately not
attempted: a compare-and-swap claim is easy, but `Drop` takes the count to
zero *and then* calls `Release`, so a claim keyed on the count would let
another task take the slot while the first is still tearing it down. It needs
a dying state or a claim keyed on `In_Use` with CAS, and `In_Use` is named in
proved contracts throughout `Generator_Slots`.

`coroutines/tests/test_task_affinity` checks the four refusals and a
hand-over; `coroutines/tests/test_continue_after_move` is the paired case --
the *same* `C.Switch` refused on a task that does not own the coroutine and
accepted after the move, resuming at the next step rather than restarting;
`coroutines/tests/test_shared_refcount` hammers the atomic count from eight
tasks; `coroutines/tests/test_too_many_tasks` walks off the `Max_Owners`
ceiling and confirms the surplus tasks are refused rather than given a number
already in use; `generators/tests/test_work_stealing` runs eight detached
generators across three worker tasks; `generators/tests/test_migrate_midway`
alternates a single generator between two tasks on every yield.

`generators/tests/test_advance_after_move` is the generator counterpart of
`test_continue_after_move`, and pins down the two things about the refusal
that are easy to get wrong. First, it is `Generator_Error` and not
`Coroutine_Error` -- which is why `Advance` tests ownership itself rather
than leaving it to `Coroutines.Switch`; that would let the lower layer's
exception out of an iteration primitive, the one place in the package where
a caller would see something else. Second, the value proves the generator
*resumed* rather than restarted: main draws 1, the worker is refused, and
after the move the worker's identical call yields 2. A generator that
restarted would print 1 again. It also shows that detached means detached --
after main lets go, main is refused too, because ownership is what the check
tests and not history.

All of these are golden-output tests
and are deterministic despite the scheduling, because none of them prints
anything that depends on which task won a race.

### Reproducing the old guarantee

For SPARK clients, a genuine data race is still reported rather than merely
documented. SPARK needs both pragmas below before it will look at tasking at
all (`tasking in SPARK requires Ravenscar profile`, then `requires sequential
elaboration`):

```ada
--  conf.adc, referenced from the .gpr as
--  package Builder is for Global_Configuration_Pragmas use "conf.adc"; end;
pragma Profile (Ravenscar);
pragma Partition_Elaboration_Policy (Sequential);
```

With those, a program where two tasks reach the library gets:

```
high: possible data race when accessing variable "minicoro.pool"
  + task "main" accesses "minicoro.pool"
  + task "racer.w" accesses "minicoro.pool"
```

reported once per abstract state — `minicoro.pool`, `minicoro.storage` and
`minicoro.backend` separately, which is a direct dividend of splitting that
state up. This is *correct*, not a false positive: the pool really is shared,
and affinity does not change that. GNATprove does not model
`Thread_Local_Storage` and analyses `Me` as an ordinary variable, which is the
right reading for these proofs — they are all about one thread of control, and
what the pragma buys is that a second thread gets a second copy to which every
one of them still applies.

### Per-task pools: still not viable

Making the *pools* per-task, rather than only the three context variables, was
tried and remains blocked. `pragma Thread_Local_Storage` accepts only an
explicit `null`, a static expression or a static aggregate as the
initialization:

```
error: Thread_Local_Storage variable "Pool" is improperly initialized
error: only allowed initialization is explicit "null", static expression or
       static aggregate
```

Every pool here has default component values, and `Coroutines.Excs` is an
array of `Exception_Occurrence`, so all of them are rejected. That is exactly
why `Me` is a scalar. Stripping the defaults to satisfy the pragma would
reintroduce the initialisation problem the `Initializes` contracts were added
to catch.

The array-indexed-by-owner trick used for `Main_Ctxs`, `Currents` and
`Backend_Up` does not extend to the pools either — not because it would not
compile, but because it would multiply `Max_Coroutines * Max_Storage` by
`Max_Owners` and, more to the point, would stop a coroutine being movable at
all: a slot would belong to the thread whose sub-pool it came out of.

The remaining route to real per-task pools is to stop having global state at
all: pass an explicit scheduler object to every operation, so each task
creates its own. That is zero-cost, is the best possible SPARK story (no
globals means no data races by construction), and is a rewrite of the public
API of all three layers plus all 34 tests. It has not been attempted.

## What is proved vs assumed

Affinity is proved to the same standard as the rest: the owner field is
ordinary pool state, the checks are ordinary guards, and `Detach`/`Adopt` have
postconditions (`Owner_Of (C) = No_Owner and then Status (C) = Suspended`, and
`Owned_Here (C)`) that GNATprove discharges. What is *not* proved is anything
about two threads at once -- see assumptions 9 to 11.

Proved: all of `Machine_Code` (including `Resume_Point_Correct` and the
displacement round trip), `Minicoro`'s absence of runtime errors, state guards
and the storage invariant `Stored <= Cap` (a `Dynamic_Predicate` on
`Coroutine_Record`), `Code_Page`'s allocate/write/seal state machine,
everything in `Contexts` but the five subprograms listed under "What cannot be
SPARK", and — since the rewrite — `Coroutines`' slot lifecycle: the reference
counting, the parent chain, and the absence of runtime errors across
`Claim_Slot`, `Spawn_Slot`, `Switch_Slot`, `Kill_Slot`, `Release` and `Reset`.
That is the part where a ref-counting bug would live, which is why it was
worth the rewrite.

Assumed, each marked in the source with its reasoning:
1. The generated assembly implements `Contexts.Switch`'s contract. SPARK has no
   machine semantics.
2. **Coroutine re-entry.** Control really did run elsewhere between the
   `Contexts.Switch` inside `Transfer` and the return from it.
   `Transfer` ends by calling `Control_Transferred`, whose contract havocs
   `Coros` and `Current`, so the prover treats the pool and the running
   coroutine as unknown afterwards. `Resume`, `Yield` and `Switch_To` then
   each carry a `pragma Assume` restoring what the counterpart routine
   establishes before switching back.

   These are genuine assumptions about the counterpart's behaviour, and the
   postconditions of all three are proved *from* them. They used to be
   contradictions, which made everything downstream vacuously provable; see
   "Proof warnings: where this stands" for what that cost and how it was
   fixed.
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
7. **`Coroutines.Create` does not retain or free its delegate twice.**
   `Raw.Adopt_Delegate` moves a pointer SPARK sees only as observed. The
   obligation is the one `Create`'s documentation already places on the
   caller: ownership of `D` transfers, so the caller must not keep or free
   it.
8. **The GNAT secondary stack and soft links behave.** `Raw`'s
   `Init_Sec_Stack`, `Save_Sec_Stack` and `Restore_Sec_Stack` call through
   `System.Soft_Links`, whose effects SPARK cannot see.

9. **A thread's number is stable across a context switch.**
   `Control_Transferred` havocs `Coros` and `Currents` but not `Me`, because
   the generated switch routine does not touch `%fs`. What it does not model
   -- and what is therefore assumed -- is `Trampoline`'s
   `pragma Assume (Ready (Owner))`: after the body returns, the thread may be
   a *different* one that adopted the coroutine while it was parked, and the
   claim is that whoever it is has its own backend up. `Adopt` establishes
   that before it will hand ownership over.
10. **`Thread_Local_Storage` gives each thread its own `Me`.** GNATprove says
   plainly that it ignores the pragma (`pragma "Thread_Local_Storage" ignored
   (not yet supported)`) and analyses `Me` as an ordinary variable. That is
   the right reading for these proofs -- every one of them is about a single
   thread of control -- but the step from "proved of one thread" to "holds of
   each thread separately" rests on the pragma doing what it says.
11. **The owner counter is atomic.** `Threads.Next_Owner` is outside SPARK and
   is the only place two threads genuinely run at once. See "Threading
   model".

If you touch `Resume`/`Yield`/`Switch_To`/`Trampoline`, re-check that the
assumptions still match what the counterpart routine actually restores. They
are the load-bearing part of the lifecycle argument. `Trampoline` in
particular now has *two* things to get right: what the counterpart restores,
and which thread it is running on.

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
  `.gpr` files carry the same
  `("-gnat2022", "-gnatwae", "-gnatyg", "-gnatX")`; keep them in step.
  `-gnatX` is not optional and not confined to the unit that needs it: see
  the `Extensions_Allowed` trap above. The one deliberate exception is the
  per-file `Switches` for `test_secondary_stack.adb` in
  `coroutines/tests/tests.gpr`, which adds `-gnatwK -gnatwU` so that the
  test source can stay exactly as it was.
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
- The POSIX `Code_Page` body (`mmap`/`mprotect`) now runs: the full 30-case
  suite passes on x86-64 Linux under GNAT 16.1, which exercises it together
  with the System V switch routine. macOS and the BSDs are still untested —
  `MAP_ANONYMOUS` differs there and `On_Linux` picks the value by inspecting
  `Standard'Target_Name`.
- Eleven `operator-reassociation` warnings remain under `--pedantic`. Purely
  cosmetic; see "Proof warnings", family 2.
- `generators/` is proved to the same standard as the layers below it, but
  only the `T`-independent part — which is now all of it except `Values` and
  the user delegate. `Generator_Slots` (reference counting, slot allocation,
  the state machine) and `Generator_Coros` (the coroutine handles, the
  affinity guard, resume/return) are analysed and carry contracts; the
  generic itself still produces no checks of its own and cannot.
  `Coro`/`Caller` used to be listed here as the remaining candidates and have
  since been hoisted, which is what `Generator_Coros` is. There is no obvious
  next candidate: what is left in the generic depends on `T`.
- **`Generator_Coros` carries no functional postconditions**, only absence of
  runtime errors and its flow -- the same gap recorded just below for
  `Coroutines`, now inherited by the newer package. Nothing states what
  `Resume` does to the pool. Contracts in the style of `Generator_Slots.Drop`
  are the next real strengthening there, and unlike the `Iterable` wall this
  one is actually reachable. One was tried and dropped:
  `Clear`'s `Post => not Is_Alive (S)` needs `Coroutines` to expose that a
  null coroutine is not alive, and widening that interface for one caller was
  the worse trade; the reasoning is at the site.
- `Coroutines` proves absence of runtime errors and its slot lifecycle, but
  carries no *functional* postconditions — nothing states what `Switch` does
  to the pool, only that it cannot go wrong. Contracts in the style of
  `Minicoro.Resume`/`Yield` would be the next real strengthening.
- **Concurrent `Create` is the one operation still unsynchronised.**
  `Claim_Slot` scans the shared pool for a free slot and then marks it, in two
  steps, so two tasks scanning together can pick the same one. Everything else
  a second task can do is now either checked (control transfer) or safe
  (reference counting, which is atomic). A compare-and-swap claim is not
  enough on its own: `Drop` takes the count to zero and *then* calls
  `Release`, so a claim keyed on the count would hand the slot out while the
  first task is still tearing it down. It needs a dying state, or a claim
  keyed on `In_Use` with CAS — and `In_Use` is named in proved contracts
  throughout `Generator_Slots`.
- **There is no scheduler, and "work stealing" here is not what Go or Tokio
  mean by it.** Both of those have a per-worker run queue and steal half of a
  victim's; you call `spawn` and never name a target. This library has no run
  queue at all — the caller says `C.Switch`. `test_work_stealing` has the
  *application* holding the queue, which is real but is a different thing.
  Adding a genuine scheduler would also make `Detach`/`Adopt` largely
  redundant: with the scheduler owning the queues, migration is "pop from
  another worker's deque" and needs no handshake. Worth knowing before
  building anything more on top of the current hand-off.
- `Max_Owners` is 16 and thread numbers are never reused, so a program that
  spawns and joins tasks in a loop exhausts it. A free list would fix that,
  at the price of having to prove that no coroutine still records a number
  being reused.
- The user pushes to their own fork
  (`https://github.com/ValorZard/ada-generators-slop.git`) themselves.
