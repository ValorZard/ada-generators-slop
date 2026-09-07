--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

pragma Extensions_Allowed (On);
--  For the Finalizable aspect below, GNAT's SPARK-analysable replacement for
--  Ada.Finalization.Controlled. Written as a source pragma rather than -gnatX
--  in the .gpr so that it travels with the file: a client that withs this
--  package needs no build-system change, and minicoro.gpr -- whose proof
--  setup is delicate -- stays untouched.

with System.Storage_Elements;
use type System.Storage_Elements.Storage_Offset;

with Minicoro;

--  SPARK, at the cost of one structural change: coroutines are named by pool
--  index rather than by pointer.
--
--  The previous design was a ref-counted Ada.Finalization.Controlled handle
--  over a heap-allocated record. Neither half survives SPARK. Controlled
--  types are rejected outright ("not allowed in SPARK (due to controlled
--  types)"), and -- the deeper problem -- ref counting *is* shared ownership,
--  which SPARK's ownership model does not have: two handles onto one object
--  are two owning pointers to the same thing, which is exactly what it
--  forbids.
--
--  Both are solved the way Minicoro solved them one layer down. The handle
--  becomes an index into a statically sized pool, so copying it copies an
--  integer and there is no aliasing to police; and finalization uses GNAT's
--  Finalizable aspect, which SPARK does analyse. The public interface is
--  unchanged -- Create still returns a Coroutine, handles are still copyable
--  and still ref-counted, and prefix notation still works.
--
--  The cost is a compile-time ceiling on live coroutines (Max_Coroutines).
--  Minicoro already imposes one of its own on *spawned* coroutines, so this
--  is a change of degree, not of kind.

package Coroutines with
  SPARK_Mode     => On,
  Abstract_State => (Registry, Sched_State),
  Initializes    => (Registry, Sched_State)
is

   pragma Elaborate_Body;

   --  Two abstract states rather than one lump, because they have different
   --  characters and different lifetimes. Registry is who exists: the slot
   --  pool and the map from Minicoro ids back to slots. Sched_State is what
   --  is running: the previously-running slot and the one-shot bootstrap
   --  flag. Keeping them apart means a contract can say it reads the registry
   --  without also claiming to touch the scheduler, and vice versa.

   --  This package provides support for creating coroutines.

   --  Coroutines are lightweight user-land cooperative threads. This package
   --  provides a type to hold ref-counted coroutines and an interface to
   --  implement the actual subprogram running under a coroutine.

   Max_Coroutines : constant := 128;
   --  How many coroutine records may exist at once. Unlike
   --  Minicoro.Max_Coroutines this counts unspawned and dead ones too, since
   --  a slot is held for as long as any handle refers to it.

   Max_Tasks : constant := Minicoro.Max_Owners;
   --  How many Ada tasks (or foreign threads) may ever use this package. One
   --  slot out of Max_Coroutines is reserved for each, for that thread's own
   --  main coroutine, so the number of coroutines a program can create is
   --  Max_Coroutines - Max_Tasks. See "Task affinity" below.

   type Coroutine is tagged private;
   --  Ref-counted coroutine. Use the Create constructor before using it, or
   --  assign another initialized coroutine to it. Unless explicitely stated,
   --  all primitives expect a coroutine to be initialized and will raise a
   --  Constraint_Error if provided uninitialized ones.

   Null_Coroutine : constant Coroutine;
   --  Uninitialized coroutine

   type Delegate is abstract tagged null record;
   procedure Run (D : in out Delegate) is abstract;
   --  An abstract tagged type rather than an interface, which it was before
   --  the move to Finalizable. GNAT 16.1 miscompiles Unchecked_Deallocation
   --  of an *interface* class-wide object whose specific type has a
   --  Finalizable component declared in another unit: the allocator emits a
   --  plain block while the deallocation calls
   --  System.Finalization_Primitives.Detach_Object_From_Collection, which
   --  reads a header 24 bytes before a block that never had one. Rooting
   --  Delegate'Class at an ordinary tagged type takes the well-trodden
   --  finalization path and the corruption goes away.
   --
   --  The cost is that a user delegate can no longer combine
   --  Coroutines.Delegate with another interface. Nothing in this repository
   --  did.
   --  User code to run inside a coroutine. When it completes, the coroutine
   --  becomes dead and the execution resumes to its nearest alive parent.
   --  If it aborts with an exception, the coroutine becomes dead too and
   --  the exception is re-raised in its closest alive parent.

   type Delegate_Access is access all Delegate'Class;

   Coroutine_Error : exception;
   --  Exception raised by coroutine primitives in erroneous cases. Refer to
   --  primitives specifications to learn about these cases.

   function Create (D : Delegate_Access) return Coroutine
     with SPARK_Mode => Off;
   --  Outside SPARK, declaration included: a SPARK function may not write
   --  globals, and handing out a coroutine has to count the reference. The
   --  slot bookkeeping it does is factored into Claim_Slot, which is
   --  analysed.
   --  Create and return a new coroutine that will run the D delegate. The
   --  ownership of D is transfered to the coroutine: it will be free'd
   --  when nobody refers to the coroutine anymore. The created coroutine is
   --  associated to the coroutine in which Created is invoked (i.e. this will
   --  be its parent coroutine). In order to actually start the coroutine, use
   --  the Spawn and Switch primitives. It belongs to the calling task until
   --  Detach hands it on.
   --
   --  Returns Null_Coroutine if the pool is full: a SPARK function may not
   --  propagate an exception, so exhaustion is reported through the value
   --  rather than by raising. Spawn, Switch and Kill all reject an
   --  uninitialized coroutine with Coroutine_Error, so it still surfaces.

   procedure Create (C : out Coroutine; D : Delegate_Access);
   --  The same thing as the function above, and the form a SPARK client must
   --  use. A SPARK *function* may not write globals (E0005) and handing out a
   --  coroutine has to count a reference, so the function is outside SPARK --
   --  and that is contagious: `C : constant Coroutine := Create (...)` gets
   --
   --    error: "C" is not allowed in SPARK (due to entity declared with
   --           SPARK_Mode Off)
   --
   --  which put every operation in the calling unit out of SPARK's reach,
   --  including GNATprove's data-race checking on the client's *own*
   --  variables. A procedure may write globals, so this form is analysed and
   --  callers of it stay in SPARK.
   --
   --  C comes back as Null_Coroutine if the pool is full or the task ceiling
   --  is reached, exactly as the function does.

   overriding function "=" (Left, Right : Coroutine) return Boolean;
   --  Return whether Left and Right reference the same coroutine

   function Alive (C : Coroutine) return Boolean;
   --  Return whether C is running (i.e. when it is spawned)

   procedure Spawn
     (C          : Coroutine;
      Stack_Size : System.Storage_Elements.Storage_Offset := 2**16);
   --  Spawn a coroutine and initialize it to call Callee. Note that the Switch
   --  primivite has to be invoked so that the execution actually starts. In
   --  order to re-spawn a coroutine, kill it first.
   --
   --  Spawning a coroutine that is already alive is invalid and raises a
   --  Coroutine_Error, as does spawning one that belongs to another task.

   procedure Switch (C : Coroutine);
   --  Switch execution from current coroutine to C. Trying to switch to a dead
   --  coroutine or to the coroutine currently running is invalid and raises a
   --  Coroutine_Error. So is switching to a coroutine that belongs to another
   --  task, or to a detached one.
   --
   --  Any exception may come back out of here, not just Coroutine_Error: if
   --  the coroutine we switch to died of an exception, that exception is
   --  re-raised in this one. That is the documented behaviour of Run. It
   --  cannot be stated as an Exceptional_Cases contract because Switch is a
   --  primitive of a tagged type, and SPARK does not yet accept that aspect
   --  on a dispatching operation.

   procedure Kill (C : Coroutine);
   --  Kill C. An exception is raised in it, then it is cleaned. Trying to
   --  kill the main coroutine, a dead coroutine, or one belonging to another
   --  task is invalid and raises a Coroutine_Error.

   function Current_Coroutine return Coroutine
     with SPARK_Mode => Off;
   --  Return a reference to the coroutine that is currently running on the
   --  calling task. Outside SPARK for the same reason as Create.

   procedure Current_Coroutine (C : out Coroutine);
   --  The SPARK-callable form, as with Create.

   function Main_Coroutine return Coroutine
     with SPARK_Mode => Off;
   --  Outside SPARK for the same reason as Create.
   --  Return a reference to the coroutine that was started automatically at
   --  the beginning of the *calling task* -- the task itself, seen as a
   --  coroutine. Each task has its own; trying to kill one is invalid and
   --  raises a Coroutine_Error.

   procedure Main_Coroutine (C : out Coroutine);
   --  The SPARK-callable form, as with Create.

   -------------------
   -- Task affinity --
   -------------------

   --  A coroutine belongs to one task at a time and only that task may spawn,
   --  switch to or kill it. The reason is underneath, in Minicoro: switching
   --  to a coroutine installs its saved stack pointer on the calling thread,
   --  so two tasks switching to one coroutine end up running on one stack.
   --  Every primitive above therefore checks, and raises Coroutine_Error
   --  rather than corrupting memory.
   --
   --  Detach and Adopt move a coroutine between tasks. The releasing task
   --  detaches, the coroutine crosses by whatever means the program already
   --  has, and the receiving task adopts:
   --
   --     --  producer                       --  worker
   --     C.Detach;                          Work.Take (C);
   --     Work.Put (C);                      C.Adopt;
   --                                        C.Switch;
   --
   --  Between the two the coroutine belongs to nobody, which is what makes
   --  the hand-off safe without a lock: no task may switch to it, so there is
   --  nothing for a lock to protect. It is also the work-stealing shape --
   --  a detached coroutine is a unit of work in a queue and Adopt is the
   --  steal.
   --
   --  What a foreign task *can* still do, deliberately. The rule is that
   --  affinity guards control transfer, not reading:
   --
   --    * Observers. Alive, Owned_By_Current_Task, Is_Detached and "=" are
   --      plain reads of a slot and never refuse. Asking whether a coroutine
   --      is someone else's has to work from the outside, or Adopt could not
   --      be guarded by it.
   --
   --    * Copying a handle. That is reference counting, not scheduling, so
   --      it is not checked -- and, since the count is atomic, not something
   --      that needs to be. See the note on it below.
   --
   --    * On a generator, reading a value the owner already yielded. Next
   --      hands back what is sitting in the slot without resuming anything,
   --      so no stack is involved and no check fires; it is only the step
   --      that must actually resume the coroutine that is refused.
   --
   --  The same reasoning is why Minicoro's Push/Pop/Peek are unchecked: they
   --  touch a byte array, never a context, so they cannot put a task on
   --  another task's stack.
   --
   --  What is NOT provided, and must be arranged by the caller: **two tasks
   --  must not create coroutines at the same time.** Claim_Slot finds a free
   --  slot by scanning the shared pool and then marks it, and those are two
   --  steps, so two tasks scanning together can pick the same slot. Releasing
   --  concurrently is fine -- that path is driven by the atomic count, and
   --  exactly one task is told it took the last reference.
   --
   --  Allocate on one task, hand the work out, and this does not arise.
   --
   --  Reference counting, on the other hand, *is* safe across tasks: the
   --  count is atomic, so a handle may be freely copied and dropped on any
   --  task, whether or not that task owns the coroutine. Lifetime and
   --  scheduling are different questions and only the second one is what
   --  affinity guards. This was not always true, and the test that keeps it
   --  true is coroutines/tests/test_shared_refcount -- with an ordinary
   --  increment it aborts with "double free or corruption" within a second.
   --
   --  Cost when none of this is used: an affinity check is one thread-local
   --  load and one compare. Nothing here creates a task, takes a lock, or
   --  pulls in the tasking runtime, so a single-task program pays no more
   --  than that.

   function Owned_By_Current_Task (C : Coroutine) return Boolean;
   --  Whether the calling task may spawn, switch to or kill C. False for an
   --  uninitialized or detached coroutine.

   function Is_Detached (C : Coroutine) return Boolean;
   --  Whether C belongs to no task and is therefore available to Adopt.
   --  False for an uninitialized coroutine.

   procedure Detach (C : Coroutine);
   --  Give up ownership of C so that another task may Adopt it.
   --
   --  Raises Coroutine_Error if C is uninitialized, is a task's own main
   --  coroutine, belongs to another task, is the coroutine currently
   --  running, or is one that another coroutine is suspended waiting to
   --  return into. That last case is the one to watch: if A switched to B and
   --  B has not yet switched back, B is waiting on A and A cannot move.
   --
   --  Detaching an unspawned coroutine is allowed and is just a change of
   --  owner; the adopting task is then the one that may Spawn it.

   procedure Adopt (C : Coroutine);
   --  Take ownership of a detached coroutine. Raises Coroutine_Error if C is
   --  uninitialized, still belongs to a task, or if more than Max_Tasks tasks
   --  have used this package.

private

   subtype Slot_Id    is Natural range 0 .. Max_Coroutines;
   subtype Valid_Slot is Slot_Id range 1 .. Max_Coroutines;

   No_Slot : constant Slot_Id := 0;

   subtype Task_Slot is Valid_Slot range 1 .. Max_Tasks;
   subtype User_Slot is Valid_Slot range Max_Tasks + 1 .. Max_Coroutines;
   --  Slots 1 .. Max_Tasks are reserved, one per task, for that task's own
   --  main coroutine -- the thread the operating system made rather than us.
   --  Each is live from its task's first call into this package and is never
   --  released.
   --
   --  This generalises what used to be "slot 1 is the main coroutine". A
   --  single reserved slot was a single main context, which is precisely the
   --  bug affinity exists to fix: with two tasks, the second one's switches
   --  would have been recorded against the first one's stack.

   procedure Bump (C : in out Coroutine);
   procedure Drop (C : in out Coroutine);
   --  The reference counting, as the Finalizable aspect calls it. There is no
   --  Initialize: a default-initialized Coroutine names No_Slot, which is
   --  what "uninitialized" means here, and both operations ignore it.

   type Coroutine is tagged record
      Slot : Slot_Id := No_Slot;
   end record
     with Finalizable => (Adjust               => Bump,
                          Finalize             => Drop,
                          Relaxed_Finalization => True);

   Null_Coroutine : constant Coroutine := (Slot => No_Slot);

end Coroutines;
