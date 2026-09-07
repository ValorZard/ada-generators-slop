--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

with Minicoro.Atomics;

package body Generator_Slots with
  SPARK_Mode    => On,
  Refined_State => (Slots => (Counts, Used, Owns, States))
is

   --  Four parallel arrays rather than one array of records. That is the
   --  house style here for a reason recorded in CLAUDE.md: a single component
   --  whose type has no default SPARK can see makes the whole enclosing
   --  record count as uninitialised. Nothing in this package has that
   --  problem today, but keeping the state flat costs nothing and means a
   --  later addition of, say, an Exception_Occurrence cannot silently take
   --  the Initializes contract down with it.

   package Atomics renames Minicoro.Atomics;

   Counts : array (Valid_Slot) of Atomics.Counter;
   --  Atomic, and no initializer: Counter's Default_Initial_Condition says a
   --  fresh one reads as zero, which is what keeps this array -- and so the
   --  Initializes contract on Slots -- fully default-initialised.
   --
   --  A generator handle can be copied and dropped on a task other than the
   --  one that owns the generator, because reference counting is about
   --  lifetime rather than scheduling and affinity deliberately does not
   --  guard it. The postconditions below are unchanged by the switch, which
   --  is the whole reason Minicoro.Atomics hides the Atomic aspect behind a
   --  private type instead of exposing an atomic scalar.
   Used   : array (Valid_Slot) of Boolean    := [others => False];
   Owns   : array (Valid_Slot) of Boolean    := [others => False];
   States : array (Valid_Slot) of State_Type := [others => Waiting];

   ------------
   -- In_Use --
   ------------

   function In_Use (S : Valid_Slot) return Boolean is (Used (S));

   ---------------
   -- Ref_Count --
   ---------------

   function Ref_Count (S : Valid_Slot) return Natural is
     (Atomics.Value (Counts (S)));

   --------------
   -- State_Of --
   --------------

   function State_Of (S : Valid_Slot) return State_Type is (States (S));

   -------------------
   -- Owns_Delegate --
   -------------------

   function Owns_Delegate (S : Valid_Slot) return Boolean is (Owns (S));

   -----------
   -- Claim --
   -----------

   procedure Claim (S : out Slot_Id) is
   begin
      S := No_Slot;

      for I in Valid_Slot loop
         if not Used (I) then
            Atomics.Reset (Counts (I), 1);
            Used   (I) := True;
            Owns   (I) := False;
            States (I) := Waiting;
            S := I;
            return;
         end if;
      end loop;
   end Claim;

   ----------
   -- Bump --
   ----------

   procedure Bump (S : Valid_Slot) is
   begin
      Atomics.Increment (Counts (S));
   end Bump;

   ----------
   -- Drop --
   ----------

   procedure Drop (S : Valid_Slot; Released : out Boolean) is
      Was_Last : Boolean;
   begin
      if not Used (S) then
         Released := False;
         return;
      end if;

      --  Was_Last comes back from the decrement rather than from re-reading
      --  the count. Two tasks dropping the last two handles would both see
      --  zero on a re-read and both clear the slot; exactly one of them gets
      --  Was_Last here. A count already at zero reports False, which is the
      --  reference-loop case Generators.Drop relies on.
      Atomics.Decrement (Counts (S), Was_Last);

      if Was_Last then
         Used   (S) := False;
         Owns   (S) := False;
         States (S) := Returning;
         Released := True;
      else
         Released := False;
      end if;
   end Drop;

   ---------------
   -- Set_State --
   ---------------

   procedure Set_State (S : Valid_Slot; To : State_Type) is
   begin
      States (S) := To;
   end Set_State;

   -----------------------
   -- Set_Owns_Delegate --
   -----------------------

   procedure Set_Owns_Delegate (S : Valid_Slot; Owns_It : Boolean) is
   begin
      Owns (S) := Owns_It;
   end Set_Owns_Delegate;

end Generator_Slots;
