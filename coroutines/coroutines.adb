--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  SPARK, except for the nested package Raw and the secondary-stack helper.
--  See the head of coroutines.ads for why the pointer graph became a pool.
--
--  What is left outside SPARK here is the same shape as Minicoro's trusted
--  base: taking 'Access of a subprogram that touches globals, and adopting a
--  pointer whose ownership the caller has promised to give up. Both are named
--  and justified where they sit.

with Ada.Exceptions; use Ada.Exceptions;
with Ada.Exceptions.Is_Null_Occurrence;
with Ada.Unchecked_Deallocation;

with System;

with Minicoro;

pragma Warnings (Off);
with System.Parameters;
with System.Secondary_Stack;
with System.Soft_Links;
pragma Warnings (On);

package body Coroutines with
  SPARK_Mode    => On,
  Refined_State => (Registry    => (Pool, By_Coro, Excs),
                    Sched_State => (Previous_Slot, Booted))
is

   use type System.Secondary_Stack.SS_Stack_Ptr;
   use type Minicoro.Coroutine_Id;
   use type Minicoro.Entry_Point;
   use type Minicoro.Result;

   package SSL renames System.Soft_Links;

   Abort_Coroutine : exception;
   --  Users should not be able to stop coroutine abortion.

   ----------------
   -- The pool --
   ----------------

   type Coroutine_Record is record
      Ref_Count  : Natural := 0;
      --  Number of Coroutine handles naming this slot. Once it reaches 0 the
      --  slot is released.

      In_Use     : Boolean := False;
      --  Whether this slot holds a coroutine at all. A released slot reads as
      --  not in use and every observer below treats it as dead.

      D          : Delegate_Access := null;
      --  User code, owned by this slot and freed with it.

      Parent     : Slot_Id := No_Slot;
      --  Slot that created this one. Used to resume execution after
      --  completion. Counted: Create bumps it, Release drops it.

      Coro       : Minicoro.Coroutine_Id := Minicoro.No_Coroutine;
      --  Backing coroutine in the Minicoro pool, or No_Coroutine when this
      --  one is not spawned. The main coroutine is always No_Coroutine: that
      --  id names the thread's own context.

      Sec_Stack  : System.Secondary_Stack.SS_Stack_Ptr := null;
      --  Saved coroutine-specific secondary stack.

      Is_Main    : Boolean := False;
      Is_Started : Boolean := False;
      To_Clean   : Boolean := False;
   end record;

   type Pool_Array is array (Valid_Slot) of Coroutine_Record;

   Pool : Pool_Array;

   Excs : array (Valid_Slot) of Exception_Occurrence;
   --  Pending exception per slot: when a slot's occurrence is non-null, the
   --  Switch primitive must re-raise it when resuming execution.
   --
   --  A separate array rather than a component of Coroutine_Record, and the
   --  reason is not tidiness. Exception_Occurrence is limited private, so
   --  SPARK cannot see that it is default-initialised; with it inside the
   --  record, *no* part of Pool counted as initialised and the Initializes
   --  contract on Registry was unprovable. Split out, every remaining
   --  component of Coroutine_Record has a default, Pool initialises itself,
   --  and only this array needs the elaboration loop at the end of the body.

   By_Coro : array (Minicoro.Valid_Id) of Slot_Id := [others => No_Slot];
   --  Which slot backs each live Minicoro coroutine. This replaces the old
   --  round trip, which stashed a Coroutine_Internal'Address in a Minicoro
   --  User_Data field and unchecked-converted it back. Minicoro already names
   --  the running coroutine by index, so an array indexed by that is all it
   --  takes, and no address is ever formed -- which is why that field, and
   --  the observer that read it, are gone from Minicoro entirely.

   Previous_Slot : Slot_Id := Main_Slot;

   Booted : Boolean := False;
   --  Whether Main_Slot has been claimed. Done lazily rather than at
   --  elaboration so that nothing here depends on elaboration order.

   ---------
   -- Raw --
   ---------

   --  TRUSTED. The two things SPARK will not do, in one place.

   package Raw with SPARK_Mode => On is

      procedure Adopt_Delegate (Slot : Valid_Slot; D : Delegate_Access);
      --  Store D as the slot's delegate, taking ownership.
      --
      --  Create takes D by mode `in`, so SPARK sees it as observed and
      --  refuses to let it be moved into the pool. The mode is forced: Create
      --  is a function, SPARK forbids `in out` parameters on functions, and
      --  the published interface has it returning a Coroutine used directly
      --  to initialise a constant. Changing that would break every caller.
      --
      --  The obligation this shifts onto the caller of Create is the one its
      --  documentation already states: ownership of D is transferred, so the
      --  caller must not retain or free it.

      function Wrapper_Entry return Minicoro.Entry_Point
        with Post => Wrapper_Entry'Result /= null;
      --  Coroutine_Wrapper'Access. SPARK rejects access-to-subprogram values
      --  whose designated subprogram has global effects, and the landing pad
      --  for a new coroutine necessarily has them. Same wrapper trick as
      --  Minicoro.Trampoline_Entry.

      procedure Init_Sec_Stack (Slot : Valid_Slot);
      --  Give the slot a secondary stack. Outside SPARK because the static
      --  case overlays an object on Sec_Stack'Address, and 'Address outside
      --  an attribute definition clause is not in SPARK.

      procedure Free_Delegate (Slot : Valid_Slot);
      --  Release the slot's delegate. Delegate_Access is a general access
      --  type (access all), and SPARK does not allow Unchecked_Deallocation
      --  of one -- it has no ownership model for pointers that may designate
      --  something other than the heap.

      procedure Capture_Abort (Slot : Valid_Slot);
      --  Park an Abort_Coroutine occurrence in the slot, for Switch_Slot to
      --  re-raise inside it. Outside SPARK because capturing an occurrence
      --  needs a choice parameter (`when E : ...`), which SPARK rejects.

      procedure Run_Delegate (Slot : Valid_Slot; To_Previous : out Boolean);
      procedure Save_Sec_Stack (Slot : Valid_Slot);
      procedure Restore_Sec_Stack (Slot : Valid_Slot);
      --  Park and reinstate the running secondary stack. System.Soft_Links
      --  reaches it through a variable of access-to-subprogram type, so a
      --  call is a dereference SPARK wants proved non-null, and the target's
      --  effects are invisible to it. Both facts are about the runtime's
      --  internals rather than about this package, so they live here.
      --  Run the slot's delegate and absorb whatever escapes it: a kill
      --  becomes To_Previous, anything else is parked in the slot to be
      --  re-raised in whoever resumes next. Outside SPARK for the same
      --  choice-parameter reason.
      --  Give the slot a secondary stack. Outside SPARK because the static
      --  case overlays an object on Sec_Stack'Address, and 'Address outside
      --  an attribute definition clause is not in SPARK.

   end Raw;

   procedure Coroutine_Wrapper (Self : Minicoro.Valid_Id)
     with Convention => C;
   --  Landing pad: run the delegate, catch what escapes it, then hand control
   --  on. Never returns normally.

   procedure Reraise_And_Clean (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Re-raise the slot's saved occurrence, leaving it null.

   procedure Reset (Slot : Valid_Slot);
   --  Assuming the slot is not running anymore, free associated resources and
   --  reset flags.

   procedure Release (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Last handle gone: kill if needed, free the delegate, clear the slot.

   procedure Ensure_Booted;
   function Current_Slot return Valid_Slot;
   function Alive_Slot (Slot : Slot_Id) return Boolean;
   procedure Switch_Slot (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   procedure Kill_Slot (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   procedure Spawn_Slot
     (Slot       : Valid_Slot;
      Stack_Size : System.Storage_Elements.Storage_Offset)
     with Exceptional_Cases => (Coroutine_Error => True);

   ---------
   -- Raw --
   ---------

   package body Raw with SPARK_Mode => Off is

      procedure Adopt_Delegate (Slot : Valid_Slot; D : Delegate_Access) is
      begin
         Pool (Slot).D := D;
      end Adopt_Delegate;

      function Wrapper_Entry return Minicoro.Entry_Point is
      begin
         return Coroutine_Wrapper'Access;
      end Wrapper_Entry;

      procedure Init_Sec_Stack (Slot : Valid_Slot) is
      begin
         if System.Parameters.Sec_Stack_Dynamic then
            Pool (Slot).Sec_Stack := null;
         else
            declare
               Sec_Stack : System.Address
                 with Import, Address => Pool (Slot).Sec_Stack'Address;
            begin
               System.Secondary_Stack.SS_Allocate
                 (Sec_Stack,
                  System.Storage_Elements.Storage_Count
                    (System.Parameters.Runtime_Default_Sec_Stack_Size));
            end;
         end if;
         System.Secondary_Stack.SS_Init (Pool (Slot).Sec_Stack);
         SSL.Set_Sec_Stack (Pool (Slot).Sec_Stack);
      end Init_Sec_Stack;

      procedure Free_Delegate (Slot : Valid_Slot) is
         procedure Free is new Ada.Unchecked_Deallocation
           (Delegate'Class, Delegate_Access);
      begin
         Free (Pool (Slot).D);
      end Free_Delegate;

      procedure Capture_Abort (Slot : Valid_Slot) is
      begin
         raise Abort_Coroutine;
      exception
         when Exc : Abort_Coroutine =>
            Save_Occurrence (Excs (Slot), Exc);
      end Capture_Abort;

      procedure Save_Sec_Stack (Slot : Valid_Slot) is
      begin
         Pool (Slot).Sec_Stack := SSL.Get_Sec_Stack.all;
      end Save_Sec_Stack;

      procedure Restore_Sec_Stack (Slot : Valid_Slot) is
      begin
         SSL.Set_Sec_Stack (Pool (Slot).Sec_Stack);
      end Restore_Sec_Stack;

      procedure Run_Delegate
        (Slot : Valid_Slot; To_Previous : out Boolean) is
      begin
         To_Previous := False;
         if Pool (Slot).D /= null then
            Pool (Slot).D.all.Run;
         end if;
      exception
         when Abort_Coroutine =>
            --  Kill resumes execution in the coroutine that invoked it.
            To_Previous := True;

         when Exc : others =>
            Save_Occurrence (Excs (Slot), Exc);
      end Run_Delegate;

   end Raw;

   --------------------
   -- Ensure_Booted --
   --------------------

   procedure Ensure_Booted is
   begin
      if Booted then
         return;
      end if;
      Pool (Main_Slot).Ref_Count  := 1;
      Pool (Main_Slot).In_Use     := True;
      Pool (Main_Slot).Is_Main    := True;
      Pool (Main_Slot).Is_Started := True;
      Pool (Main_Slot).Parent     := No_Slot;
      Previous_Slot := Main_Slot;
      Booted := True;
   end Ensure_Booted;

   ------------------
   -- Current_Slot --
   ------------------

   function Current_Slot return Valid_Slot is
      Running : constant Minicoro.Coroutine_Id := Minicoro.Running_Coroutine;
   begin
      --  Minicoro names the thread's own context No_Coroutine, which is
      --  exactly this package's main coroutine.
      if Running = Minicoro.No_Coroutine then
         return Main_Slot;
      elsif By_Coro (Running) in Valid_Slot then
         return By_Coro (Running);
      else
         return Main_Slot;
      end if;
   end Current_Slot;

   ----------------
   -- Alive_Slot --
   ----------------

   function Alive_Slot (Slot : Slot_Id) return Boolean is
     (Slot in Valid_Slot
        and then Pool (Slot).In_Use
        and then (Pool (Slot).Is_Main
                  or else Pool (Slot).Coro /= Minicoro.No_Coroutine));
   --  The main coroutine is always alive: it is the thread itself, and it has
   --  no pool slot in Minicoro to hold.

   ----------
   -- Bump --
   ----------

   procedure Bump (C : in out Coroutine) is
   begin
      if C.Slot in Valid_Slot
        and then Pool (C.Slot).Ref_Count < Natural'Last
      then
         Pool (C.Slot).Ref_Count := Pool (C.Slot).Ref_Count + 1;
      end if;
   end Bump;

   ----------
   -- Drop --
   ----------

   procedure Drop (C : in out Coroutine) is
      Slot : constant Slot_Id := C.Slot;
   begin
      --  Clear the handle before doing anything else. Releasing a slot can
      --  run user finalization, which may look at this very handle; and a
      --  reference loop reaches here with the count already at zero, which
      --  means someone up the stack is already releasing this slot.
      C.Slot := No_Slot;

      if Slot not in Valid_Slot or else Pool (Slot).Ref_Count = 0 then
         return;
      end if;

      Pool (Slot).Ref_Count := Pool (Slot).Ref_Count - 1;

      if Pool (Slot).Ref_Count = 0 and then Slot /= Main_Slot then
         Release (Slot);
      end if;
   exception
      when others =>
         --  A finalizer must not propagate. Release can reach Kill_Slot,
         --  which switches into the coroutine being torn down and can come
         --  back carrying whatever that coroutine died of; letting it out
         --  here would turn an orderly scope exit into Program_Error and
         --  lose the rest of the finalization. Dropping a reference is
         --  best-effort by nature, so the exception stops here.
         null;
   end Drop;

   -------------
   -- Release --
   -------------

   procedure Release (Slot : Valid_Slot) is
      Parent : constant Slot_Id := Pool (Slot).Parent;
   begin
      if Alive_Slot (Slot) then
         Kill_Slot (Slot);
      end if;

      Raw.Free_Delegate (Slot);

      Pool (Slot).In_Use     := False;
      Pool (Slot).Parent     := No_Slot;
      Pool (Slot).Is_Main    := False;
      Pool (Slot).Is_Started := False;
      Pool (Slot).To_Clean   := False;
      Pool (Slot).Coro       := Minicoro.No_Coroutine;
      Save_Occurrence (Excs (Slot), Null_Occurrence);

      --  Drop the counted reference this slot held on its parent. Done last,
      --  and iteratively rather than by recursion, so that a long ancestor
      --  chain cannot recurse arbitrarily deep.
      if Parent in Valid_Slot and then Pool (Parent).Ref_Count > 0 then
         Pool (Parent).Ref_Count := Pool (Parent).Ref_Count - 1;
      end if;
   end Release;

   -----------
   -- Reset --
   -----------

   procedure Reset (Slot : Valid_Slot) is
      Res : Minicoro.Result;
   begin
      if Pool (Slot).Coro /= Minicoro.No_Coroutine then
         By_Coro (Pool (Slot).Coro) := No_Slot;

         --  Destroy is only legal on a coroutine that is not active, which is
         --  the only state one can be in by the time we clean up after it.
         --  Testing rather than asserting keeps the guarantee local: nothing
         --  in Minicoro's contract promises Success, so Res is deliberately
         --  not checked either -- this is best-effort teardown.
         if Minicoro.Status (Pool (Slot).Coro) in
              Minicoro.Dead | Minicoro.Suspended
         then
            Minicoro.Destroy (Pool (Slot).Coro, Res);
         end if;
         Pool (Slot).Coro := Minicoro.No_Coroutine;
      end if;

      if Pool (Slot).Sec_Stack /= null then
         System.Secondary_Stack.SS_Free (Pool (Slot).Sec_Stack);
      end if;

      Pool (Slot).Is_Started := False;
      Pool (Slot).To_Clean   := False;
   end Reset;

   ------------
   -- Create --
   ------------

   procedure Claim_Slot (Slot : out Slot_Id);
   --  Everything Create does apart from adopting the delegate. Split out so
   --  that the part which can be analysed is. No explicit Global: it would
   --  have to name Minicoro.Current_State, which Current_Slot reads through
   --  Minicoro.Running_Coroutine, and inference gets it right.

   procedure Claim_Slot (Slot : out Slot_Id) is
      Parent : Valid_Slot;
   begin
      Slot := No_Slot;
      Ensure_Booted;
      Parent := Current_Slot;

      for I in Valid_Slot loop
         if not Pool (I).In_Use then
            Slot := I;
            exit;
         end if;
      end loop;

      if Slot not in Valid_Slot then
         --  Pool exhausted. A SPARK function may not propagate an exception
         --  -- Exceptional_Cases cannot be applied to one -- so this reports
         --  the failure the way the type already provides for, by handing
         --  back an uninitialized coroutine. Spawn, Switch and Kill all
         --  reject one of those with Coroutine_Error, so the error still
         --  surfaces, at first use rather than at construction.
         return;
      end if;

      Pool (Slot).Ref_Count  := 1;
      Pool (Slot).In_Use     := True;
      Pool (Slot).Parent     := Parent;
      Pool (Slot).Coro       := Minicoro.No_Coroutine;
      Pool (Slot).Sec_Stack  := null;
      Pool (Slot).Is_Main    := False;
      Pool (Slot).Is_Started := False;
      Pool (Slot).To_Clean   := False;
      Save_Occurrence (Excs (Slot), Null_Occurrence);

      --  The new slot holds a counted reference on its parent, so the parent
      --  cannot be released while a child still names it.
      if Pool (Parent).Ref_Count < Natural'Last then
         Pool (Parent).Ref_Count := Pool (Parent).Ref_Count + 1;
      end if;

   end Claim_Slot;

   function Create (D : Delegate_Access) return Coroutine is
      pragma SPARK_Mode (Off);
      --  Off for two reasons, both structural. A SPARK function may not
      --  write globals, and this one must bump a reference count; and D
      --  arrives as a constant view of an access-to-variable, which SPARK
      --  will not let us hand to Raw.Adopt_Delegate. Everything above the
      --  delegate hand-off is in Claim_Slot, which is analysed.
      Slot : Slot_Id;
   begin
      Claim_Slot (Slot);
      if Slot not in Valid_Slot then
         return Null_Coroutine;
      end if;
      Raw.Adopt_Delegate (Slot, D);
      return (Slot => Slot);
   end Create;

   ---------
   -- "=" --
   ---------

   overriding function "=" (Left, Right : Coroutine) return Boolean is
     (Left.Slot = Right.Slot);

   -----------
   -- Alive --
   -----------

   function Alive (C : Coroutine) return Boolean is (Alive_Slot (C.Slot));

   -----------
   -- Spawn --
   -----------

   procedure Spawn
     (C          : Coroutine;
      Stack_Size : System.Storage_Elements.Storage_Offset := 2**16)
   is
      pragma SPARK_Mode (Off);
      --  Off because it raises and it is a primitive of a tagged type: SPARK
      --  does not yet accept Exceptional_Cases on a dispatching operation, so
      --  there is no way to declare what comes out. The work is in
      --  Spawn_Slot, which is analysed.
   begin
      if C.Slot not in Valid_Slot then
         raise Coroutine_Error with "uninitialized coroutine";
      end if;
      Spawn_Slot (C.Slot, Stack_Size);
   end Spawn;

   ----------------
   -- Spawn_Slot --
   ----------------

   procedure Spawn_Slot
     (Slot       : Valid_Slot;
      Stack_Size : System.Storage_Elements.Storage_Offset)
   is
      Coro : Minicoro.Coroutine_Id;
      Res  : Minicoro.Result;
   begin
      Ensure_Booted;

      if Alive_Slot (Slot) then
         raise Coroutine_Error with "Coroutine already spawed";
      end if;

      --  Storage_Offset is signed and far wider than Stack_Count, so the
      --  conversion below needs both ends pinned down. Minicoro raises the
      --  figure to Min_Stack_Size itself, so anything positive is acceptable
      --  here; what is not acceptable is a negative or absurd request.
      if Stack_Size <= 0
        or else Stack_Size > System.Storage_Elements.Storage_Offset
                               (Minicoro.Stack_Count'Last)
      then
         raise Coroutine_Error with "invalid stack size";
      end if;

      Minicoro.Create
        (C          => Coro,
         Func       => Raw.Wrapper_Entry,
         Stack_Size => Minicoro.Stack_Count (Stack_Size),
         Res        => Res);
      if Res /= Minicoro.Success then
         raise Coroutine_Error
           with "Minicoro.Create failed: " & Minicoro.Result'Image (Res);
      end if;

      Pool (Slot).Coro       := Coro;
      Pool (Slot).Is_Main    := False;
      Pool (Slot).To_Clean   := False;
      Pool (Slot).Is_Started := False;
      By_Coro (Coro) := Slot;
      Save_Occurrence (Excs (Slot), Null_Occurrence);
   end Spawn_Slot;

   ------------
   -- Switch --
   ------------

   procedure Switch (C : Coroutine) is
      pragma SPARK_Mode (Off);
      --  Off: as Spawn. Dispatching operations cannot carry
      --  Exceptional_Cases, and this one propagates whatever the resumed
      --  coroutine died of.
   begin
      if C.Slot not in Valid_Slot then
         raise Coroutine_Error with "uninitialized coroutine";
      end if;
      Switch_Slot (C.Slot);
   end Switch;

   -----------------
   -- Switch_Slot --
   -----------------

   procedure Switch_Slot (Slot : Valid_Slot) is
      Res : Minicoro.Result;
      Cur : Valid_Slot;
   begin
      Ensure_Booted;

      if Slot = Current_Slot then
         raise Coroutine_Error with "Trying to switch to the same coroutine";
      elsif not Alive_Slot (Slot) then
         raise Coroutine_Error with "Trying to switch to a dead coroutine";
      end if;

      --  From the next coroutine to run's point of view, the current
      --  coroutine is what Previous_Slot shall be.
      Cur := Current_Slot;
      Raw.Save_Sec_Stack (Cur);
      Previous_Slot := Cur;

      --  A symmetric transfer, as PCL's co_call was: the target may be this
      --  coroutine's parent, a sibling, or the main context, and it resumes
      --  wherever it last stopped. Coro is No_Coroutine for the main
      --  coroutine, which is exactly how Minicoro names the thread context.
      Minicoro.Switch_To (Pool (Slot).Coro, Res);
      if Res /= Minicoro.Success then
         raise Coroutine_Error
           with "Switch failed: " & Minicoro.Result'Image (Res);
      end if;

      Cur := Current_Slot;
      Raw.Restore_Sec_Stack (Cur);

      if Previous_Slot in Valid_Slot and then Pool (Previous_Slot).To_Clean
      then
         Reset (Previous_Slot);
         if not Is_Null_Occurrence (Excs (Previous_Slot)) then
            Reraise_And_Clean (Previous_Slot);
         end if;
      end if;

      if not Is_Null_Occurrence (Excs (Cur)) then
         Reraise_And_Clean (Cur);
      end if;
   end Switch_Slot;

   ----------
   -- Kill --
   ----------

   procedure Kill (C : Coroutine) is
      pragma SPARK_Mode (Off);
      --  Off: as Spawn.
   begin
      if C.Slot not in Valid_Slot then
         raise Coroutine_Error with "uninitialized coroutine";
      end if;
      Kill_Slot (C.Slot);
   end Kill;

   ---------------
   -- Kill_Slot --
   ---------------

   procedure Kill_Slot (Slot : Valid_Slot) is
   begin
      Ensure_Booted;

      if Slot = Main_Slot then
         raise Coroutine_Error with "Cannot kill the main coroutine";
      elsif not Alive_Slot (Slot) then
         raise Coroutine_Error with "Coroutine already killed";
      end if;

      if not Pool (Slot).Is_Started then
         Reset (Slot);
         return;
      end if;

      Raw.Capture_Abort (Slot);

      --  The following will switch to Slot, raise an exception that will
      --  unwind its stack. Then its Coroutine_Wrapper instance will switch
      --  back to the current coroutine, which cleans and destroys it.
      Switch_Slot (Slot);
   end Kill_Slot;

   -----------------------
   -- Current_Coroutine --
   -----------------------

   function Current_Coroutine return Coroutine is
      pragma SPARK_Mode (Off);
      --  Off: a SPARK function may not write globals, and handing out a
      --  reference has to count it.
      Slot : Valid_Slot;
   begin
      Ensure_Booted;
      Slot := Current_Slot;
      if Pool (Slot).Ref_Count < Natural'Last then
         Pool (Slot).Ref_Count := Pool (Slot).Ref_Count + 1;
      end if;
      return (Slot => Slot);
   end Current_Coroutine;

   --------------------
   -- Main_Coroutine --
   --------------------

   function Main_Coroutine return Coroutine is
      pragma SPARK_Mode (Off);
      --  Off: as Current_Coroutine.
   begin
      Ensure_Booted;
      if Pool (Main_Slot).Ref_Count < Natural'Last then
         Pool (Main_Slot).Ref_Count := Pool (Main_Slot).Ref_Count + 1;
      end if;
      return (Slot => Main_Slot);
   end Main_Coroutine;

   -----------------------
   -- Coroutine_Wrapper --
   -----------------------

   procedure Coroutine_Wrapper (Self : Minicoro.Valid_Id) is
      Slot        : Valid_Slot;
      To_Previous : Boolean;
      Ancestor    : Slot_Id;
   begin
      if By_Coro (Self) not in Valid_Slot then
         --  Cannot happen: Spawn_Slot records the mapping before anything can
         --  enter here. There is nowhere to report it to, so spin rather than
         --  fall off the end of the coroutine's stack.
         loop
            null;
         end loop;
      end if;

      Slot := By_Coro (Self);
      Pool (Slot).Is_Started := True;
      Raw.Init_Sec_Stack (Slot);

      --  When leaving the delegate, the coroutine is about to abort, so the
      --  coroutine we will be switching to must clean this one.

      Raw.Run_Delegate (Slot, To_Previous);

      Pool (Slot).To_Clean := True;

      --  Hand control on. Every path out of here is a switch, and none of
      --  them may raise: this is the landing pad the generated entry code
      --  jumps to, with C convention and nothing above it on this stack. An
      --  exception let out here would unwind off a coroutine stack that is
      --  about to be freed, which is undefined rather than merely wrong. So
      --  the switches are wrapped, and a failure falls through to the same
      --  terminal spin as every other way of having nowhere to go.
      begin
         if To_Previous and then Previous_Slot in Valid_Slot then
            Switch_Slot (Previous_Slot);
         end if;

         --  Get the nearest parent coroutine still alive and resume execution
         --  in it. The walk is bounded by the pool size: a chain longer than
         --  that would have to revisit a slot, and there is nowhere left to
         --  go.
         Ancestor := Pool (Slot).Parent;
         for Unused in Valid_Slot loop
            exit when Ancestor not in Valid_Slot or else Alive_Slot (Ancestor);
            Ancestor := Pool (Ancestor).Parent;
         end loop;

         if Ancestor in Valid_Slot and then Alive_Slot (Ancestor) then
            Switch_Slot (Ancestor);
         else
            Switch_Slot (Main_Slot);
         end if;
      exception
         when others =>
            null;
      end;

      --  Unreachable on the ordinary path: nothing switches back into a
      --  coroutine that has run to completion. Reached only if the hand-off
      --  above failed outright, in which case spinning is the least harmful
      --  thing left.
      loop
         null;
      end loop;
   end Coroutine_Wrapper;

   -----------------------
   -- Reraise_And_Clean --
   -----------------------

   procedure Reraise_And_Clean (Slot : Valid_Slot) is
      Saved_Exc : Exception_Occurrence;
   begin
      Save_Occurrence (Saved_Exc, Excs (Slot));
      Save_Occurrence (Excs (Slot), Null_Occurrence);
      Reraise_Occurrence (Saved_Exc);
   end Reraise_And_Clean;

begin
   --  Exception_Occurrence is limited private, so SPARK cannot see that GNAT
   --  default-initialises it to a null occurrence. Nulling them here is a
   --  no-op at run time and turns an implicit assumption into an executed
   --  fact, which is what lets Registry claim to be initialised.
   for I in Valid_Slot loop
      Save_Occurrence (Excs (I), Null_Occurrence);
   end loop;
end Coroutines;
