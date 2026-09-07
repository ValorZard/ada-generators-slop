--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A reference count that two tasks may hold at once.
--
--  This exists because the layers above are reference-counted and their
--  handles now cross task boundaries: a coroutine can be Detached on one task
--  and Adopted on another, so the handle naming it can legitimately be copied
--  and dropped on either. A plain `N := N + 1` loses updates when that
--  happens -- measurably, not theoretically: eight tasks doing 200_000
--  increments each on an ordinary Natural land around 600_000 instead of
--  1_600_000, which as a reference count means a live coroutine freed under
--  its owner.
--
--  The interesting part is the shape of the type, which is dictated by SPARK.
--
--  The obvious spelling -- an Atomic scalar in the pool array -- does not
--  work: SPARK treats every Atomic object as *effectively volatile*, so the
--  abstract state holding it must be declared External, and external state
--  cannot be read in the ordinary expressions that the reference-counting
--  contracts are made of. Declaring `Counts : array (..) of Atomic_Natural`
--  inside Generator_Slots produces
--
--    error: non-external state "Slots" cannot contain external constituents
--           in refinement
--
--  and there is no way to keep Drop's postcondition after that.
--
--  So the atomicity is hidden instead. Counter is a private type whose full
--  view is outside SPARK, exactly as Contexts.Context and Stack_Handle are,
--  and what SPARK reasons about is the ghost-like observer Value together
--  with the contracts below. The prover never sees an Atomic aspect, the
--  reference-counting postconditions in Generator_Slots survive unchanged,
--  and the machine instruction underneath is a `lock xadd`.
--
--  TRUSTED, then, in one specific respect: that the body implements these
--  contracts *indivisibly*. SPARK checks that callers use them consistently;
--  it has no way to check the "indivisibly". That was verified by experiment
--  instead -- see coroutines/tests/test_shared_refcount, which is the same
--  hammer as above run through the real Coroutine handles.

package Minicoro.Atomics with SPARK_Mode => On is

   pragma Unevaluated_Use_Of_Old (Allow);
   --  The postconditions below mention Value (Item)'Old to the right of an
   --  "and then", which RM 6.1.1(27) would otherwise reject.

   type Counter is private
     with Default_Initial_Condition => Value (Counter) = 0;
   --  A count starts at zero, which is what "this slot is free" means to
   --  every caller. The Default_Initial_Condition is what lets an array of
   --  these still count as fully default-initialised, so the Initializes
   --  contracts one layer up keep working.

   function Value (Item : Counter) return Natural
     with Global => null;
   --  The count, as a number. A read of an atomic object is itself atomic, so
   --  this never observes a torn value -- but it is a *sample*: by the time a
   --  caller acts on it another task may have changed it. Only Increment and
   --  Decrement are safe to act on, because they report what they did rather
   --  than what they saw. Use this for contracts and for diagnostics, not to
   --  decide whether to free something.

   procedure Reset (Item : in out Counter; To : Natural)
     with Global => null,
          Post   => Value (Item) = To;
   --  Set the count outright. Only for a slot the caller has just claimed and
   --  nobody else can name yet; it is a plain store, and racing it against an
   --  Increment loses one of them.

   procedure Increment (Item : in out Counter)
     with Global => null,
          Post   => (if Value (Item)'Old < Natural'Last
                     then Value (Item) = Value (Item)'Old + 1
                     else Value (Item) = Natural'Last);
   --  Take a reference. Saturates rather than overflowing, which is the
   --  behaviour the hand-written counters had: a count that has reached
   --  Natural'Last stops moving, leaking a slot but never wrapping round to
   --  zero and freeing one that is still in use.

   procedure Decrement (Item : in out Counter; Was_Last : out Boolean)
     with Global => null,
          Post   => (if Value (Item)'Old = 0
                     then Value (Item) = 0 and then not Was_Last
                     else Value (Item) = Value (Item)'Old - 1
                            and then Was_Last = (Value (Item)'Old = 1));
   --  Release a reference. Was_Last says whether this call was the one that
   --  took the count to zero, and it is the *only* safe way to ask: two tasks
   --  dropping the last two references both see a non-zero count if they look
   --  first, but exactly one of them gets Was_Last here. That is the whole
   --  reason this package exists.
   --
   --  A count already at zero is left alone and reports False, which is the
   --  reference-loop case the layers above rely on -- Drop can be re-entered
   --  for a slot that is already being released.

private
   pragma SPARK_Mode (Off);

   type Impl is range 0 .. Natural'Last with Atomic;
   --  Same range as the counts it replaces, so Value is a total conversion
   --  and the saturation point is unchanged.

   type Counter is record
      N : aliased Impl := 0;
   end record;
   --  A record rather than a bare scalar so that the type is by-reference:
   --  the atomic primitives take `aliased in out`, and an Increment applied
   --  to a copy would be atomic with respect to nothing at all. RM C.6 makes
   --  a type with an atomic subcomponent by-reference, and the hammer test
   --  named at the top of this file is what confirms it really is.

end Minicoro.Atomics;
