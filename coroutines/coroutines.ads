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
   --  analysed; what is left here is the delegate hand-off.
   --  Create and return a new coroutine that will run the D delegate. The
   --  ownership of D is transfered to the coroutine: it will be free'd
   --  when nobody refers to the coroutine anymore. The created coroutine is
   --  associated to the coroutine in which Created is invoked (i.e. this will
   --  be its parent coroutine). In order to actually start the coroutine, use
   --  the Spawn and Switch primitives.
   --
   --  Returns Null_Coroutine if the pool is full: a SPARK function may not
   --  propagate an exception, so exhaustion is reported through the value
   --  rather than by raising. Spawn, Switch and Kill all reject an
   --  uninitialized coroutine with Coroutine_Error, so it still surfaces.

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
   --  Coroutine_Error.

   procedure Switch (C : Coroutine);
   --  Switch execution from current coroutine to C. Trying to switch to a dead
   --  coroutine or to the coroutine currently running is invalid and raises a
   --  Coroutine_Error.
   --
   --  Any exception may come back out of here, not just Coroutine_Error: if
   --  the coroutine we switch to died of an exception, that exception is
   --  re-raised in this one. That is the documented behaviour of Run. It
   --  cannot be stated as an Exceptional_Cases contract because Switch is a
   --  primitive of a tagged type, and SPARK does not yet accept that aspect
   --  on a dispatching operation.

   procedure Kill (C : Coroutine);
   --  Kill C. An exception is raised in it, then it is cleaned. Trying to
   --  kill the main coroutine or a dead coroutine is invalid and raises a
   --  Coroutine_Error.

   function Current_Coroutine return Coroutine
     with SPARK_Mode => Off;
   --  Return a reference to the coroutine that is currently running.
   --  Outside SPARK for the same reason as Create.

   function Main_Coroutine return Coroutine
     with SPARK_Mode => Off;
   --  Outside SPARK for the same reason as Create.
   --  Return a reference to the coroutine that was started automatically at
   --  the beginning of the process. Trying to kill it is invalid and raises
   --  a Coroutine_Error.

private

   subtype Slot_Id    is Natural range 0 .. Max_Coroutines;
   subtype Valid_Slot is Slot_Id range 1 .. Max_Coroutines;

   No_Slot   : constant Slot_Id    := 0;
   Main_Slot : constant Valid_Slot := 1;
   --  Slot 1 is reserved for the main coroutine -- the thread itself, which
   --  the operating system made rather than us. It is live from elaboration
   --  and is never released.

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
