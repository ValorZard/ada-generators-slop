--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The generator slot lifecycle: reference counting, allocation, and the
--  three-state execution machine. Everything Generators does that does not
--  depend on the type being yielded.
--
--  This package exists to be *proved*, and it is non-generic for exactly that
--  reason. GNATprove analyses generic instantiations rather than generic
--  units, and no SPARK unit can instantiate Generators -- its Iterable aspect
--  names the three functions that advance a generator, and those cannot be in
--  SPARK because a SPARK function may not write globals. So anything left
--  inside the generic is unverifiable in practice. Hoisted out here, where no
--  instantiation is involved, it is checked like any other package.
--
--  What stayed behind in Generators is only what genuinely depends on the
--  formal type: the yielded values, the user delegate, and the two Coroutine
--  handles.

package Generator_Slots with
  SPARK_Mode     => On,
  Abstract_State => Slots,
  Initializes    => Slots
is

   pragma Unevaluated_Use_Of_Old (Allow);
   --  Several postconditions below mention X'Old to the right of an
   --  "and then", which RM 6.1.1(27) would otherwise reject. Same reason as
   --  Minicoro.

   Max_Generators : constant := 128;
   --  How many generator records may exist at once, live or not: a slot is
   --  held for as long as any handle names it.

   subtype Slot_Id    is Natural range 0 .. Max_Generators;
   subtype Valid_Slot is Slot_Id range 1 .. Max_Generators;

   No_Slot : constant Slot_Id := 0;

   type State_Type is
     (Waiting,
      --  The generator has already yielded or was just created, and is
      --  waiting to be resumed.

      Yielding,
      --  The generator just yielded and is waiting for its caller to get the
      --  value.

      Returning
      --  The generator has not yielded and is done.
     );

   ---------------
   -- Observers --
   ---------------

   function In_Use (S : Valid_Slot) return Boolean
     with Global => (Input => Slots);

   function Ref_Count (S : Valid_Slot) return Natural
     with Global => (Input => Slots);

   function State_Of (S : Valid_Slot) return State_Type
     with Global => (Input => Slots);

   function Owns_Delegate (S : Valid_Slot) return Boolean
     with Global => (Input => Slots);

   ---------------
   -- Lifecycle --
   ---------------

   procedure Claim (S : out Slot_Id)
     with Global => (In_Out => Slots),
          Post   => (if S in Valid_Slot
                     then In_Use (S)
                            and then Ref_Count (S) = 1
                            and then State_Of (S) = Waiting
                            and then not Owns_Delegate (S));
   --  Reserve a free slot, or return No_Slot when the pool is full.

   procedure Bump (S : Valid_Slot)
     with Global => (In_Out => Slots),
          Post   => In_Use (S) = In_Use (S)'Old
                      and then State_Of (S) = State_Of (S)'Old
                      and then Ref_Count (S) >= Ref_Count (S)'Old;
   --  Take a reference. Saturates rather than overflowing; a count that has
   --  reached Natural'Last stops moving, which leaks a slot but cannot wrap
   --  round to zero and free one that is still in use.

   procedure Drop (S : Valid_Slot; Released : out Boolean)
     with Global => (In_Out => Slots),
          Post   => Released = (In_Use (S)'Old and then Ref_Count (S)'Old = 1)
                      and then (if Released then not In_Use (S))
                      and then (if not Released
                                then In_Use (S) = In_Use (S)'Old);
   --  Release a reference. Released says whether that was the last one, in
   --  which case the slot has been cleared and the caller owes whatever
   --  cleanup belongs to the layer above.

   -------------------
   -- State changes --
   -------------------

   procedure Set_State (S : Valid_Slot; To : State_Type)
     with Global => (In_Out => Slots),
          Pre    => In_Use (S),
          Post   => State_Of (S) = To
                      and then In_Use (S)
                      and then Ref_Count (S) = Ref_Count (S)'Old;

   procedure Set_Owns_Delegate (S : Valid_Slot; Owns_It : Boolean)
     with Global => (In_Out => Slots),
          Pre    => In_Use (S),
          Post   => Owns_Delegate (S) = Owns_It
                      and then In_Use (S)
                      and then State_Of (S) = State_Of (S)'Old;

end Generator_Slots;
