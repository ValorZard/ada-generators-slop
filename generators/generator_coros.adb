--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

package body Generator_Coros with
  SPARK_Mode    => On,
  Refined_State => (Plumbing => (Coros, Callers))
is

   --  Two parallel arrays rather than one array of records, as in
   --  Generator_Slots and for the reason recorded in CLAUDE.md: keeping the
   --  state flat means a later addition whose type has no default SPARK can
   --  see cannot take the Initializes contract down with it.

   Coros : array (Valid_Slot) of Coroutines.Coroutine;
   --  The coroutine that runs each slot. A default-initialized Coroutine
   --  names no slot, which is what keeps this array -- and so Plumbing --
   --  fully default-initialised without an explicit aggregate.

   Callers : array (Valid_Slot) of Coroutines.Coroutine;
   --  Just before switching to a generator, set to the coroutine it is
   --  supposed to switch back to.

   --------------
   -- Is_Alive --
   --------------

   function Is_Alive (S : Valid_Slot) return Boolean is
     (Coroutines.Alive (Coros (S)));

   ----------------
   -- Owned_Here --
   ----------------

   function Owned_Here (S : Valid_Slot) return Boolean is
     (Coroutines.Owned_By_Current_Task (Coros (S)));

   -----------------
   -- Is_Detached --
   -----------------

   function Is_Detached (S : Valid_Slot) return Boolean is
     (Coroutines.Is_Detached (Coros (S)));

   --------------
   -- Set_Coro --
   --------------

   procedure Set_Coro (S : Valid_Slot; C : Coroutines.Coroutine) is
   begin
      Coros (S) := C;
   end Set_Coro;

   -----------
   -- Spawn --
   -----------

   procedure Spawn (S : Valid_Slot) is
   begin
      Coroutines.Spawn (Coros (S));
   end Spawn;

   -----------------
   -- Note_Caller --
   -----------------

   procedure Note_Caller (S : Valid_Slot) is
   begin
      Coroutines.Current_Coroutine (Callers (S));
   end Note_Caller;

   ------------------
   -- Clear_Caller --
   ------------------

   procedure Clear_Caller (S : Valid_Slot) is
   begin
      Callers (S) := Coroutines.Null_Coroutine;
   end Clear_Caller;

   -------------------
   -- Kill_If_Alive --
   -------------------

   procedure Kill_If_Alive (S : Valid_Slot) is
   begin
      if Coroutines.Alive (Coros (S)) then
         Coroutines.Kill (Coros (S));
      end if;
   end Kill_If_Alive;

   -----------
   -- Clear --
   -----------

   procedure Clear (S : Valid_Slot) is
   begin
      --  Do not rely on the usual coroutine completion mechanism (see
      --  Generators.Run): kill a generator that is still alive rather than
      --  let it linger.
      Kill_If_Alive (S);

      Coros   (S) := Coroutines.Null_Coroutine;
      Callers (S) := Coroutines.Null_Coroutine;
   end Clear;

   ------------
   -- Resume --
   ------------

   procedure Resume (S : Valid_Slot; Res : out Result) is
   begin
      if not Coroutines.Owned_By_Current_Task (Coros (S)) then
         Res := Wrong_Task;
         return;
      end if;

      Res := Success;

      Note_Caller (S);
      Coroutines.Switch (Coros (S));
      Clear_Caller (S);
   end Resume;

   -----------------------
   -- Return_To_Caller --
   -----------------------

   procedure Return_To_Caller (S : Valid_Slot) is
   begin
      Coroutines.Switch (Callers (S));
   end Return_To_Caller;

   ------------
   -- Detach --
   ------------

   procedure Detach (S : Valid_Slot) is
   begin
      Coroutines.Detach (Coros (S));
   end Detach;

   -----------
   -- Adopt --
   -----------

   procedure Adopt (S : Valid_Slot) is
   begin
      Coroutines.Adopt (Coros (S));
   end Adopt;

end Generator_Coros;
