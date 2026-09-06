--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The verified core: coroutine lifecycle and the per-coroutine byte stack.
--
--  Coroutines live in a statically sized pool and are named by index rather
--  than by pointer. That is the single decision that makes this package
--  provable: there is no aliasing for SPARK's ownership model to police, and
--  "is this coroutine still alive" is answered by a Boolean in a slot instead
--  of by the validity of a dangling access value.

with System.Storage_Elements;

with Minicoro.Contexts;
with Minicoro.FTAL;

package body Minicoro with
  SPARK_Mode,
  Refined_State => (Pool          => (Coros, Backend_Up, Main_Ctx,
                                       Contexts.Backend_State),
                    Current_State => Current)
is
   use System.Storage_Elements;
   use type Contexts.Body_Entry;

   type Store_Buffer is array (1 .. Max_Storage) of Byte;

   type Coroutine_Record is limited record
      Coro_State : State          := Dead;
      In_Use     : Boolean        := False;
      Func       : Entry_Point    := null;
      Prev       : Coroutine_Id   := No_Coroutine;
      Data       : System.Address := System.Null_Address;

      Ctx   : Contexts.Context;
      Stack : Contexts.Stack_Handle;

      Store  : Store_Buffer  := [others => 0];
      Stored : Storage_Count := 0;
      Cap    : Storage_Count := 0;
   end record
     with Dynamic_Predicate => Coroutine_Record.Stored <= Coroutine_Record.Cap;
   --  The predicate is the storage API's whole safety argument in one line:
   --  a slot never holds more bytes than it has room for.

   type Pool_Array is array (Valid_Id) of Coroutine_Record;

   Coros      : Pool_Array;
   Main_Ctx   : Contexts.Context;
   --  The thread's own context. No_Coroutine names it, so that the main
   --  program and a coroutine are the same kind of thing to Transfer.
   Current    : Coroutine_Id := No_Coroutine;
   Backend_Up : Boolean      := False;

   procedure Trampoline (Handle : System.Address)
     with Convention => C;
   --  Never returns -- it ends in an unreachable spin -- but it is not marked
   --  No_Return: GNATprove rejects taking 'Access of such a subprogram, and
   --  Make_Context needs its address.

   function Ready return Boolean is
     (Backend_Up and then Contexts.Backend_Ready);
   --  Backend_Up alone would not do: it says the main context has been
   --  adopted, but Make_Context and Switch need Contexts.Backend_Ready, and
   --  nothing relates the two. Carrying both in one predicate lets every
   --  precondition below be discharged rather than assumed.

   procedure Transfer (From, To : Coroutine_Id)
     with Pre => From /= To
                   and then Ready
                   and then (if To /= No_Coroutine then Coros (To).In_Use);

   procedure Ensure_Backend (Ok : out Boolean)
     with Post => (if Ok then Ready);

   function Trampoline_Entry return Contexts.Body_Entry
     with Post => Trampoline_Entry'Result /= null;
   --  Wrapping the 'Access in a function keeps it out of SPARK's way: SPARK
   --  rejects access-to-subprogram values whose designated subprogram has
   --  global effects, and Trampoline necessarily touches the pool. The
   --  postcondition is what callers need and is discharged by inspection of
   --  the one-line body.

   function Handle_Of (C : Valid_Id) return System.Address is
     (To_Address (Integer_Address (C)));
   --  Coroutines cross the assembly boundary as their pool index, encoded as
   --  an address. Nothing is ever dereferenced, so there is no pointer to get
   --  wrong.

   function Id_Of (Handle : System.Address) return Valid_Id is
     (Valid_Id (To_Integer (Handle)))
     with Pre => To_Integer (Handle) in
                   Integer_Address (Valid_Id'First)
                     .. Integer_Address (Valid_Id'Last);

   ---------------
   -- Observers --
   ---------------

   function Status (C : Coroutine_Id) return State is
     (if C = No_Coroutine then Dead else Coros (C).Coro_State);

   function Bytes_Stored (C : Coroutine_Id) return Storage_Count is
     (if C = No_Coroutine then 0 else Coros (C).Stored);

   function Storage_Size (C : Coroutine_Id) return Storage_Count is
     (if C = No_Coroutine then 0 else Coros (C).Cap);

   function Free_Space (C : Coroutine_Id) return Storage_Count is
     (Storage_Size (C) - Bytes_Stored (C));

   function User_Data (C : Coroutine_Id) return System.Address is
     (if C = No_Coroutine then System.Null_Address else Coros (C).Data);

   function Running_Coroutine return Coroutine_Id is (Current);

   function Is_Allocated (C : Coroutine_Id) return Boolean is
     (C /= No_Coroutine and then Coros (C).In_Use);

   --------------------
   -- Ensure_Backend --
   --------------------

   procedure Ensure_Backend (Ok : out Boolean) is
   begin
      --  Idempotent, and cheap once the code page exists. Calling it
      --  unconditionally is what makes Contexts.Backend_Ready hold on every
      --  path out of here, including the already-initialized one.
      Contexts.Initialize_Backend (Ok);
      if not Ok then
         return;
      end if;

      --  Claim the thread's own stack once, so that switching away from the
      --  main program has somewhere to save its registers.
      if not Backend_Up then
         Contexts.Adopt_Current (Main_Ctx);
         Backend_Up := True;
      end if;
   end Ensure_Backend;

   --------------
   -- Transfer --
   --------------

   procedure Transfer (From, To : Coroutine_Id) is
   begin
      --  ASSUMPTION (stack disjointness). Contexts.Switch requires the two
      --  contexts to own disjoint stacks. They do: every coroutine stack is a
      --  separate heap allocation, and the main context's is the thread's,
      --  which we never allocate out of. SPARK cannot see that two distinct
      --  pool slots hold distinct allocations, so the fact is asserted here
      --  rather than derived. See README.md, "What is assumed".
      pragma Assume
        (FTAL.Switch_Pre
           (Contexts.Model (if From = No_Coroutine
                            then Main_Ctx else Coros (From).Ctx),
            Contexts.Model (if To = No_Coroutine
                            then Main_Ctx else Coros (To).Ctx)));

      if From = No_Coroutine then
         Contexts.Switch (Main_Ctx, Coros (To).Ctx);
      elsif To = No_Coroutine then
         Contexts.Switch (Coros (From).Ctx, Main_Ctx);
      else
         Contexts.Switch (Coros (From).Ctx, Coros (To).Ctx);
         pragma Annotate
           (GNATprove, False_Positive,
            "formal parameters ""From"" and ""To"" might be aliased",
            "Transfer requires From /= To, so these are components of two "
            & "different array elements and cannot overlap. SPARK's "
            & "anti-aliasing rule is syntactic and treats any two indexed "
            & "components with non-static indices as possibly the same.");
      end if;
   end Transfer;

   ----------------------
   -- Trampoline_Entry --
   ----------------------

   function Trampoline_Entry return Contexts.Body_Entry is
      pragma SPARK_Mode (Off);
   begin
      return Trampoline'Access;
   end Trampoline_Entry;

   ------------
   -- Create --
   ------------

   procedure Create
     (C            : out Coroutine_Id;
      Func         : Entry_Point;
      Stack_Size   : Stack_Count    := Default_Stack_Size;
      Storage_Size : Storage_Count  := Max_Storage;
      User_Data    : System.Address := System.Null_Address;
      Res          : out Result)
   is
      Slot : Coroutine_Id := No_Coroutine;
      Ok   : Boolean;
   begin
      C := No_Coroutine;

      if Func = null then
         Res := Invalid_Arguments;
         return;
      end if;

      Ensure_Backend (Ok);
      if not Ok then
         Res := Make_Context_Error;
         return;
      end if;

      for I in Valid_Id loop
         if not Coros (I).In_Use then
            Slot := I;
            exit;
         end if;
      end loop;

      if Slot = No_Coroutine then
         Res := Too_Many_Coroutines;
         return;
      end if;

      Contexts.Allocate_Stack
        (Stack_Count'Max (Stack_Size, Min_Stack_Size), Coros (Slot).Stack, Ok);
      if not Ok then
         Res := Out_Of_Memory;
         return;
      end if;

      Contexts.Make_Context
        (Ctx    => Coros (Slot).Ctx,
         Stack  => Coros (Slot).Stack,
         Start  => Trampoline_Entry,
         Handle => Handle_Of (Slot));

      Coros (Slot).Func       := Func;
      Coros (Slot).Data       := User_Data;
      Coros (Slot).Prev       := No_Coroutine;
      Coros (Slot).Stored     := 0;
      Coros (Slot).Cap        := Storage_Size;
      Coros (Slot).Coro_State := Suspended;
      Coros (Slot).In_Use     := True;

      C   := Slot;
      Res := Success;
   end Create;

   -------------
   -- Destroy --
   -------------

   procedure Destroy (C : Coroutine_Id; Res : out Result) is
   begin
      if C = No_Coroutine or else not Coros (C).In_Use then
         Res := Invalid_Coroutine;
         return;
      end if;

      Contexts.Reset (Coros (C).Ctx);
      Contexts.Free_Stack (Coros (C).Stack);

      Coros (C).Coro_State := Dead;
      Coros (C).In_Use     := False;
      Coros (C).Func       := null;
      Coros (C).Prev       := No_Coroutine;
      Coros (C).Stored     := 0;
      Coros (C).Cap        := 0;

      Res := Success;
   end Destroy;

   ------------
   -- Resume --
   ------------

   procedure Resume (C : Valid_Id; Res : out Result) is
      Prev : constant Coroutine_Id := Current;
   begin
      if not Coros (C).In_Use then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Coros (C).Coro_State /= Suspended then
         Res := Not_Suspended;
         return;
      end if;

      if not Ready or else C = Prev then
         Res := Invalid_Operation;
         return;
      end if;

      --  Bookkeeping first, so the state seen from inside C is already right
      --  when it starts running.
      Coros (C).Prev := Prev;
      if Prev /= No_Coroutine then
         Coros (Prev).Coro_State := Normal;
      end if;
      Coros (C).Coro_State := Running;
      Current := C;

      Transfer (Prev, C);

      --  ASSUMPTION (coroutine re-entry).
      --
      --  SPARK models Transfer as an ordinary call that returns with the
      --  globals as it left them. What actually happened is that control ran
      --  inside C, and possibly inside coroutines C resumed in turn, before
      --  arriving back here. The two facts below are re-established by the
      --  only routines that can return control to this point -- Yield and
      --  Trampoline -- each of which restores Current and moves C to
      --  Suspended or Dead before switching back.
      --
      --  This is a real gap in the verification, not a technicality; it is
      --  recorded in README.md alongside the trusted assembly.
      pragma Assume (Current = Prev);
      pragma Assume (Coros (C).Coro_State in Suspended | Dead);

      Res := Success;
   end Resume;

   -----------
   -- Yield --
   -----------

   procedure Yield (C : Valid_Id; Res : out Result) is
      Prev : constant Coroutine_Id := Coros (C).Prev;
   begin
      if Coros (C).Coro_State /= Running or else not Ready then
         Res := Not_Running;
         return;
      end if;

      if Prev = C then
         --  A coroutine cannot be its own resumer. Nothing in this package
         --  sets that up, but if it ever held, the switch would be handed the
         --  same buffer as source and destination -- it would save the live
         --  registers over the very state it is about to restore.
         Res := Invalid_Operation;
         return;
      end if;

      if Prev /= No_Coroutine and then not Coros (Prev).In_Use then
         --  Our resumer was destroyed while we were running. There is nowhere
         --  to go back to, so refuse rather than switch into a released slot.
         Res := Invalid_Operation;
         return;
      end if;

      Coros (C).Coro_State := Suspended;
      Coros (C).Prev       := No_Coroutine;
      if Prev /= No_Coroutine then
         Coros (Prev).Coro_State := Running;
      end if;
      Current := Prev;

      Transfer (C, Prev);

      --  ASSUMPTION (coroutine re-entry), as in Resume: control is here again
      --  only because someone resumed C, and Resume sets both of these before
      --  switching in.
      pragma Assume (Current = C);
      pragma Assume (Coros (C).Coro_State = Running);

      Res := Success;
   end Yield;

   ---------------
   -- Switch_To --
   ---------------

   procedure Switch_To (Target : Coroutine_Id; Res : out Result) is
      Cur : constant Coroutine_Id := Current;
   begin
      if Target /= No_Coroutine
        and then (not Coros (Target).In_Use
                  or else Coros (Target).Coro_State = Dead)
      then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Target = Cur or else not Ready then
         Res := Invalid_Operation;
         return;
      end if;

      if Target /= No_Coroutine then
         Coros (Target).Prev       := Cur;
         Coros (Target).Coro_State := Running;
      end if;
      if Cur /= No_Coroutine then
         Coros (Cur).Coro_State := Normal;
      end if;
      Current := Target;

      Transfer (Cur, Target);

      --  ASSUMPTION (coroutine re-entry), as in Resume.
      pragma Assume (Current = Cur);

      Res := Success;
   end Switch_To;

   ----------------
   -- Trampoline --
   ----------------

   procedure Trampoline (Handle : System.Address) is
      pragma SPARK_Mode (Off);
      --  Off because this subprogram never returns: it runs the user's body
      --  and then leaves its stack for good. SPARK has no way to describe
      --  that shape.

      C         : constant Valid_Id := Id_Of (Handle);
      Body_Proc : constant Entry_Point := Coros (C).Func;
      Prev      : Coroutine_Id;
   begin
      if Body_Proc /= null then
         Body_Proc (C);
      end if;

      Prev := Coros (C).Prev;
      pragma Assert (Prev /= C);
      Coros (C).Coro_State := Dead;
      Coros (C).Prev       := No_Coroutine;
      if Prev /= No_Coroutine then
         Coros (Prev).Coro_State := Running;
      end if;
      Current := Prev;

      Transfer (C, Prev);

      --  Unreachable: a dead context is never switched into again. Spinning
      --  is still better than falling through to the poison return address
      --  Make_Context planted, which is what "returning" from a coroutine
      --  body would otherwise do.
      loop
         null;
      end loop;
   end Trampoline;

   ----------
   -- Push --
   ----------

   procedure Push (C : Valid_Id; Src : Byte_Array; Res : out Result) is
      Base : constant Storage_Count := Coros (C).Stored;
   begin
      if Src'Length > Coros (C).Cap - Base then
         Res := Not_Enough_Space;
         return;
      end if;

      for I in Src'Range loop
         Coros (C).Store (Base + 1 + (I - Src'First)) := Src (I);
         pragma Loop_Invariant (Coros (C).Stored = Base);
         pragma Loop_Invariant (Coros (C).Cap = Coros (C).Cap'Loop_Entry);
      end loop;

      Coros (C).Stored := Base + Src'Length;
      Res := Success;
   end Push;

   ---------
   -- Pop --
   ---------

   procedure Pop (C : Valid_Id; Dest : out Byte_Array; Res : out Result) is
   begin
      if Dest'Length > Coros (C).Stored then
         Dest := [others => 0];
         Res  := Not_Enough_Space;
         return;
      end if;

      declare
         Base : constant Storage_Count := Coros (C).Stored - Dest'Length;
      begin
         for I in Dest'Range loop
            Dest (I) := Coros (C).Store (Base + 1 + (I - Dest'First));
            pragma Loop_Invariant
              (Coros (C).Stored = Coros (C).Stored'Loop_Entry);
         end loop;
         Coros (C).Stored := Base;
      end;

      Res := Success;
   end Pop;

   ----------
   -- Peek --
   ----------

   procedure Peek (C : Valid_Id; Dest : out Byte_Array; Res : out Result) is
   begin
      if Dest'Length > Coros (C).Stored then
         Dest := [others => 0];
         Res  := Not_Enough_Space;
         return;
      end if;

      declare
         Base : constant Storage_Count := Coros (C).Stored - Dest'Length;
      begin
         for I in Dest'Range loop
            Dest (I) := Coros (C).Store (Base + 1 + (I - Dest'First));
         end loop;
      end;

      Res := Success;
   end Peek;

end Minicoro;
