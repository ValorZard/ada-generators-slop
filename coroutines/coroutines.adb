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

with Minicoro.Atomics;

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
   use type Minicoro.Owner_Id;
   use type Minicoro.Result;

   package SSL renames System.Soft_Links;
   package Atomics renames Minicoro.Atomics;

   subtype Owner_Id    is Minicoro.Owner_Id;
   subtype Valid_Owner is Minicoro.Valid_Owner;

   No_Owner : Owner_Id renames Minicoro.No_Owner;

   pragma Compile_Time_Error
     (Max_Tasks >= Max_Coroutines,
      "Max_Tasks must leave room for user coroutines: slots 1 .. Max_Tasks "
      & "are reserved, one per task, and User_Slot is what is left");
   --  Checked by the compiler rather than the prover, for the same reason as
   --  the layout guard in Contexts: the two constants come from different
   --  packages -- Max_Tasks is Minicoro.Max_Owners -- and raising one without
   --  looking at the other would silently give User_Slot a null range, which
   --  shows up only as Create always returning Null_Coroutine.

   Abort_Coroutine : exception;
   --  Users should not be able to stop coroutine abortion.

   ----------------
   -- The pool --
   ----------------

   type Coroutine_Record is record
      Ref_Count  : Atomics.Counter;
      --  Number of Coroutine handles naming this slot. Once it reaches 0 the
      --  slot is released.
      --
      --  Atomic, because a handle may legitimately be copied and dropped on a
      --  task other than the coroutine's owner: reference counting is about
      --  lifetime, not scheduling, so affinity deliberately does not guard it.
      --  See Minicoro.Atomics for why it is a private type rather than an
      --  Atomic scalar.

      In_Use     : Boolean := False;
      --  Whether this slot holds a coroutine at all. A released slot reads as
      --  not in use and every observer below treats it as dead.

      D          : Delegate_Access := null;
      --  User code, owned by this slot and freed with it.

      Parent     : Slot_Id := No_Slot;
      --  Slot that created this one. Used to resume execution after
      --  completion. Counted: Create bumps it, Release drops it.
      --
      --  A lifetime link, not a scheduling one, which is why Detach leaves it
      --  alone: a coroutine that moves to another task keeps its parent
      --  alive, but the completion walk in Coroutine_Wrapper skips ancestors
      --  the running task does not own.

      Owner      : Owner_Id := No_Owner;
      --  Which task may spawn, switch to or kill this slot. No_Owner means
      --  detached. Kept here rather than read back out of Minicoro because a
      --  slot that has not been spawned yet has no Minicoro coroutine to ask,
      --  and a task's own main slot never has one at all.

      Coro       : Minicoro.Coroutine_Id := Minicoro.No_Coroutine;
      --  Backing coroutine in the Minicoro pool, or No_Coroutine when this
      --  one is not spawned. A task's own main coroutine is always
      --  No_Coroutine: that id names the calling thread's own context.

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
   --
   --  Shared across tasks, and safely so: a Minicoro id belongs to exactly
   --  one slot, and a slot to at most one task, so no two tasks ever write
   --  the same element.

   Previous_Slot : array (Valid_Owner) of Slot_Id := [others => No_Slot];
   --  Per task: from the next coroutine to run's point of view, what the
   --  current one was. One variable would have made every task's switches
   --  overwrite every other task's.

   Booted : array (Valid_Owner) of Boolean := [others => False];
   --  Whether this task's main slot has been claimed. Done lazily rather than
   --  at elaboration so that nothing here depends on elaboration order, and
   --  because a task that never calls in should not cost a slot.

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
      --
      --  These are also the one part of this package that was already
      --  per-task before affinity existed: in a tasking runtime the soft
      --  links are per-task, so each task saves and restores its own
      --  secondary stack, and a coroutine carries its own in its slot when it
      --  moves.
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

   procedure Ensure_Booted (O : out Owner_Id; Ok : out Boolean);
   function Main_Slot_Of (O : Valid_Owner) return Task_Slot;
   function Current_Slot (O : Valid_Owner) return Valid_Slot;
   function Alive_Slot (Slot : Slot_Id) return Boolean;
   procedure Switch_Slot (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   procedure Kill_Slot (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   procedure Spawn_Slot
     (Slot       : Valid_Slot;
      Stack_Size : System.Storage_Elements.Storage_Offset)
     with Exceptional_Cases => (Coroutine_Error => True);
   procedure Detach_Slot (Slot : Valid_Slot; Res : out Minicoro.Result);
   procedure Adopt_Slot (Slot : Valid_Slot; Res : out Minicoro.Result);

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

   ------------------
   -- Main_Slot_Of --
   ------------------

   function Main_Slot_Of (O : Valid_Owner) return Task_Slot is
     (Task_Slot (O));
   --  The reservation is by construction rather than by search: task number
   --  N owns slot N. Nothing has to be allocated, so two tasks booting at
   --  once cannot pick the same slot.

   -------------------
   -- Ensure_Booted --
   -------------------

   procedure Ensure_Booted (O : out Owner_Id; Ok : out Boolean) is
      Res  : Minicoro.Result;
      Slot : Task_Slot;
   begin
      --  Minicoro numbers the calling thread and adopts its stack. Both are
      --  idempotent and both are needed before this package can name the
      --  task's own main coroutine.
      Minicoro.Register (O, Res);
      Ok := Res = Minicoro.Success and then O in Valid_Owner;
      if not Ok then
         return;
      end if;

      if Booted (O) then
         return;
      end if;

      Slot := Main_Slot_Of (O);
      Atomics.Reset (Pool (Slot).Ref_Count, 1);
      Pool (Slot).In_Use     := True;
      Pool (Slot).Is_Main    := True;
      Pool (Slot).Is_Started := True;
      Pool (Slot).Parent     := No_Slot;
      Pool (Slot).Owner      := O;
      Previous_Slot (O) := Slot;
      Booted (O) := True;
   end Ensure_Booted;

   ------------------
   -- Current_Slot --
   ------------------

   function Current_Slot (O : Valid_Owner) return Valid_Slot is
      Running : constant Minicoro.Coroutine_Id := Minicoro.Running_Coroutine;
   begin
      --  Minicoro names the calling thread's own context No_Coroutine, which
      --  is exactly this package's main coroutine for that task.
      if Running = Minicoro.No_Coroutine then
         return Main_Slot_Of (O);
      elsif By_Coro (Running) in Valid_Slot then
         return By_Coro (Running);
      else
         return Main_Slot_Of (O);
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
   --  A task's main coroutine is always alive: it is the task itself, and it
   --  has no pool slot in Minicoro to hold.

   ----------
   -- Bump --
   ----------

   procedure Bump (C : in out Coroutine) is
   begin
      if C.Slot in Valid_Slot then
         Atomics.Increment (Pool (C.Slot).Ref_Count);
      end if;
   end Bump;

   ----------
   -- Drop --
   ----------

   procedure Drop (C : in out Coroutine) is
      Slot     : constant Slot_Id := C.Slot;
      Was_Last : Boolean;
   begin
      --  Clear the handle before doing anything else. Releasing a slot can
      --  run user finalization, which may look at this very handle; and a
      --  reference loop reaches here with the count already at zero, which
      --  means someone up the stack is already releasing this slot.
      C.Slot := No_Slot;

      if Slot not in Valid_Slot then
         return;
      end if;

      --  Was_Last, not a re-read of the count. If two tasks drop the last two
      --  handles at once, both would see zero on a re-read and both would try
      --  to release the slot; exactly one of them gets Was_Last here. A count
      --  already at zero reports False, which is the reference-loop case the
      --  comment above describes.
      Atomics.Decrement (Pool (Slot).Ref_Count, Was_Last);

      if Was_Last and then Slot not in Task_Slot then
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
      Parent       : constant Slot_Id := Pool (Slot).Parent;
      O            : Owner_Id;
      Ok           : Boolean;
      Res          : Minicoro.Result;
      Parent_Freed : Boolean;
   begin
      Ensure_Booted (O, Ok);

      if Ok and then Alive_Slot (Slot) then
         --  A detached coroutine has no owner to unwind it, so take it back
         --  first: adopting costs nothing and lets Kill_Slot raise
         --  Abort_Coroutine inside it in the ordinary way, so its stack
         --  unwinds and its finalizers run.
         if Pool (Slot).Owner = No_Owner then
            Adopt_Slot (Slot, Res);
            --  Res is deliberately not tested. The only thing that matters is
            --  whether we now own the slot, which the next line asks
            --  directly; a failed adoption falls into the branch below, which
            --  is where anything we cannot unwind belongs anyway.
         end if;

         if Pool (Slot).Owner = O then
            Kill_Slot (Slot);
         else
            --  Not ours: either the slot belongs to another live task, or it
            --  was detached and we could not take it (the task ceiling). We
            --  cannot switch into it from here, so it cannot be unwound; the
            --  slot is cleared but its stack is left alone rather than freed
            --  under a task that may be a switch away from standing on it.
            --  Dropping the last handle to a coroutine that belongs to
            --  another task is a programming error -- see "Task affinity" in
            --  the spec -- and leaking a stack is the safe way to lose that
            --  race.
            Reset_Foreign : declare
               Coro : constant Minicoro.Coroutine_Id := Pool (Slot).Coro;
            begin
               if Coro /= Minicoro.No_Coroutine then
                  By_Coro (Coro) := No_Slot;
               end if;
            end Reset_Foreign;
            Pool (Slot).Coro := Minicoro.No_Coroutine;
         end if;
      end if;

      Raw.Free_Delegate (Slot);

      Pool (Slot).In_Use     := False;
      Pool (Slot).Parent     := No_Slot;
      Pool (Slot).Is_Main    := False;
      Pool (Slot).Is_Started := False;
      Pool (Slot).To_Clean   := False;
      Pool (Slot).Owner      := No_Owner;
      Pool (Slot).Coro       := Minicoro.No_Coroutine;
      Save_Occurrence (Excs (Slot), Null_Occurrence);

      --  Drop the counted reference this slot held on its parent. Done last,
      --  and iteratively rather than by recursion, so that a long ancestor
      --  chain cannot recurse arbitrarily deep.
      if Parent in Valid_Slot then
         Atomics.Decrement (Pool (Parent).Ref_Count, Parent_Freed);
         --  Deliberately not chased. Releasing the parent from here would
         --  recurse up an arbitrarily long ancestor chain, which is the thing
         --  the original comment above is about; the parent is released by
         --  whoever drops its last *handle*, and this only removes the claim
         --  this child had on it.
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
   --  have to name Minicoro's states, which Current_Slot reads through
   --  Minicoro.Running_Coroutine, and inference gets it right.

   procedure Claim_Slot (Slot : out Slot_Id) is
      Parent : Valid_Slot;
      Owner  : Owner_Id;
      Ok     : Boolean;
   begin
      Slot := No_Slot;
      Ensure_Booted (Owner, Ok);
      if not Ok then
         return;
      end if;
      Parent := Current_Slot (Owner);

      --  User coroutines come out of User_Slot only: the low slots are spoken
      --  for, one per task, and are never allocated from.
      for I in User_Slot loop
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

      Atomics.Reset (Pool (Slot).Ref_Count, 1);
      Pool (Slot).In_Use     := True;
      Pool (Slot).Parent     := Parent;
      Pool (Slot).Owner      := Owner;
      Pool (Slot).Coro       := Minicoro.No_Coroutine;
      Pool (Slot).Sec_Stack  := null;
      Pool (Slot).Is_Main    := False;
      Pool (Slot).Is_Started := False;
      Pool (Slot).To_Clean   := False;
      Save_Occurrence (Excs (Slot), Null_Occurrence);

      --  The new slot holds a counted reference on its parent, so the parent
      --  cannot be released while a child still names it.
      Atomics.Increment (Pool (Parent).Ref_Count);

   end Claim_Slot;

   procedure Create (C : out Coroutine; D : Delegate_Access) is
      Slot : Slot_Id;
   begin
      C := Null_Coroutine;
      Claim_Slot (Slot);
      if Slot not in Valid_Slot then
         return;
      end if;
      Raw.Adopt_Delegate (Slot, D);
      C := (Slot => Slot);
   end Create;

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

   -----------------------------
   -- Owned_By_Current_Task --
   -----------------------------

   function Owned_By_Current_Task (C : Coroutine) return Boolean is
     (C.Slot in Valid_Slot
        and then Pool (C.Slot).In_Use
        and then Minicoro.Current_Owner /= No_Owner
        and then Pool (C.Slot).Owner = Minicoro.Current_Owner);

   -----------------
   -- Is_Detached --
   -----------------

   function Is_Detached (C : Coroutine) return Boolean is
     (C.Slot in Valid_Slot
        and then Pool (C.Slot).In_Use
        and then Pool (C.Slot).Owner = No_Owner);

   -----------------
   -- Detach_Slot --
   -----------------

   procedure Detach_Slot (Slot : Valid_Slot; Res : out Minicoro.Result) is
      O  : Owner_Id;
      Ok : Boolean;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         Res := Minicoro.Too_Many_Tasks;
         return;
      end if;

      if Slot in Task_Slot then
         --  A task's own main coroutine *is* the task. There is no stack to
         --  hand over that the other task could run on.
         Res := Minicoro.Invalid_Operation;
         return;
      end if;

      if Pool (Slot).Owner /= O then
         Res := Minicoro.Wrong_Task;
         return;
      end if;

      if Slot = Current_Slot (O) then
         Res := Minicoro.Coroutine_Busy;
         return;
      end if;

      --  An unspawned slot has no Minicoro coroutine, and detaching it is
      --  just a change of owner: the adopting task is then the one that may
      --  Spawn it. A spawned one has to pass Minicoro's own checks first,
      --  which are the ones that know about resume chains.
      if Pool (Slot).Coro /= Minicoro.No_Coroutine then
         Minicoro.Detach (Pool (Slot).Coro, Res);
         if Res /= Minicoro.Success then
            return;
         end if;
      end if;

      --  Forget it as this task's "previously running". Left set, the
      --  post-switch cleanup in Switch_Slot would go looking at a slot that
      --  now belongs to somebody else.
      if Previous_Slot (O) = Slot then
         Previous_Slot (O) := No_Slot;
      end if;

      Pool (Slot).Owner := No_Owner;
      Res := Minicoro.Success;
   end Detach_Slot;

   ----------------
   -- Adopt_Slot --
   ----------------

   procedure Adopt_Slot (Slot : Valid_Slot; Res : out Minicoro.Result) is
      O  : Owner_Id;
      Ok : Boolean;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         Res := Minicoro.Too_Many_Tasks;
         return;
      end if;

      if Pool (Slot).Owner /= No_Owner then
         Res := Minicoro.Wrong_Task;
         return;
      end if;

      if Pool (Slot).Coro /= Minicoro.No_Coroutine then
         Minicoro.Adopt (Pool (Slot).Coro, Res);
         if Res /= Minicoro.Success then
            return;
         end if;
      end if;

      Pool (Slot).Owner := O;
      Res := Minicoro.Success;
   end Adopt_Slot;

   ------------
   -- Detach --
   ------------

   procedure Detach (C : Coroutine) is
      pragma SPARK_Mode (Off);
      --  Off: as Spawn. A dispatching operation cannot carry
      --  Exceptional_Cases. The work is in Detach_Slot, which is analysed.
      Res : Minicoro.Result;
   begin
      if C.Slot not in Valid_Slot or else not Pool (C.Slot).In_Use then
         raise Coroutine_Error with "uninitialized coroutine";
      end if;

      Detach_Slot (C.Slot, Res);
      if Res /= Minicoro.Success then
         raise Coroutine_Error
           with "Detach failed: " & Minicoro.Result'Image (Res);
      end if;
   end Detach;

   -----------
   -- Adopt --
   -----------

   procedure Adopt (C : Coroutine) is
      pragma SPARK_Mode (Off);
      --  Off: as Detach.
      Res : Minicoro.Result;
   begin
      if C.Slot not in Valid_Slot or else not Pool (C.Slot).In_Use then
         raise Coroutine_Error with "uninitialized coroutine";
      end if;

      Adopt_Slot (C.Slot, Res);
      if Res /= Minicoro.Success then
         raise Coroutine_Error
           with "Adopt failed: " & Minicoro.Result'Image (Res);
      end if;
   end Adopt;

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
      Coro  : Minicoro.Coroutine_Id;
      Res   : Minicoro.Result;
      Owner : Owner_Id;
      Ok    : Boolean;
   begin
      Ensure_Booted (Owner, Ok);
      if not Ok then
         raise Coroutine_Error with "too many tasks";
      end if;

      if Alive_Slot (Slot) then
         raise Coroutine_Error with "Coroutine already spawed";
      end if;

      if Pool (Slot).Owner /= Owner then
         raise Coroutine_Error
           with "Coroutine belongs to another task";
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
      O   : Owner_Id;
      Ok  : Boolean;
      Cur : Valid_Slot;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         raise Coroutine_Error with "too many tasks";
      end if;

      if Slot = Current_Slot (O) then
         raise Coroutine_Error with "Trying to switch to the same coroutine";
      elsif not Alive_Slot (Slot) then
         raise Coroutine_Error with "Trying to switch to a dead coroutine";
      elsif Pool (Slot).Owner /= O then
         raise Coroutine_Error
           with "Trying to switch to a coroutine of another task";
      end if;

      --  From the next coroutine to run's point of view, the current
      --  coroutine is what Previous_Slot shall be.
      Cur := Current_Slot (O);
      Raw.Save_Sec_Stack (Cur);
      Previous_Slot (O) := Cur;

      --  A symmetric transfer, as PCL's co_call was: the target may be this
      --  coroutine's parent, a sibling, or the main context, and it resumes
      --  wherever it last stopped. Coro is No_Coroutine for a task's main
      --  coroutine, which is exactly how Minicoro names the thread context.
      Minicoro.Switch_To (Pool (Slot).Coro, Res);
      if Res /= Minicoro.Success then
         raise Coroutine_Error
           with "Switch failed: " & Minicoro.Result'Image (Res);
      end if;

      --  Re-read the task number rather than reusing the one from above.
      --  This invocation lives on some coroutine's stack, and that coroutine
      --  may have been Detached and Adopted by another task while it was
      --  parked here -- which is the whole point of the feature. The switch
      --  itself never changes threads, but the gap between switching out and
      --  being switched back in can. Everything below indexes per-task state,
      --  so it has to be the task we are actually on.
      Ensure_Booted (O, Ok);
      if not Ok then
         raise Coroutine_Error with "too many tasks";
      end if;

      Cur := Current_Slot (O);
      Raw.Restore_Sec_Stack (Cur);

      if Previous_Slot (O) in Valid_Slot
        and then Pool (Previous_Slot (O)).To_Clean
      then
         Reset (Previous_Slot (O));
         if not Is_Null_Occurrence (Excs (Previous_Slot (O))) then
            Reraise_And_Clean (Previous_Slot (O));
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
      O  : Owner_Id;
      Ok : Boolean;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         raise Coroutine_Error with "too many tasks";
      end if;

      if Slot in Task_Slot then
         raise Coroutine_Error with "Cannot kill the main coroutine";
      elsif not Alive_Slot (Slot) then
         raise Coroutine_Error with "Coroutine already killed";
      elsif Pool (Slot).Owner /= O then
         raise Coroutine_Error with "Coroutine belongs to another task";
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

   procedure Current_Coroutine (C : out Coroutine) is
      Slot : Valid_Slot;
      O    : Owner_Id;
      Ok   : Boolean;
   begin
      C := Null_Coroutine;
      Ensure_Booted (O, Ok);
      if not Ok then
         return;
      end if;
      Slot := Current_Slot (O);
      Atomics.Increment (Pool (Slot).Ref_Count);
      C := (Slot => Slot);
   end Current_Coroutine;

   function Current_Coroutine return Coroutine is
      pragma SPARK_Mode (Off);
      --  Off: a SPARK function may not write globals, and handing out a
      --  reference has to count it.
      Slot : Valid_Slot;
      O    : Owner_Id;
      Ok   : Boolean;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         return Null_Coroutine;
      end if;
      Slot := Current_Slot (O);
      Atomics.Increment (Pool (Slot).Ref_Count);
      return (Slot => Slot);
   end Current_Coroutine;

   --------------------
   -- Main_Coroutine --
   --------------------

   procedure Main_Coroutine (C : out Coroutine) is
      Slot : Task_Slot;
      O    : Owner_Id;
      Ok   : Boolean;
   begin
      C := Null_Coroutine;
      Ensure_Booted (O, Ok);
      if not Ok then
         return;
      end if;
      Slot := Main_Slot_Of (O);
      Atomics.Increment (Pool (Slot).Ref_Count);
      C := (Slot => Slot);
   end Main_Coroutine;

   function Main_Coroutine return Coroutine is
      pragma SPARK_Mode (Off);
      --  Off: as Current_Coroutine.
      Slot : Task_Slot;
      O    : Owner_Id;
      Ok   : Boolean;
   begin
      Ensure_Booted (O, Ok);
      if not Ok then
         return Null_Coroutine;
      end if;
      Slot := Main_Slot_Of (O);
      Atomics.Increment (Pool (Slot).Ref_Count);
      return (Slot => Slot);
   end Main_Coroutine;

   -----------------------
   -- Coroutine_Wrapper --
   -----------------------

   procedure Coroutine_Wrapper (Self : Minicoro.Valid_Id) is
      Slot        : Valid_Slot;
      To_Previous : Boolean;
      Ancestor    : Slot_Id;
      O           : Owner_Id;
      Ok          : Boolean;
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
         Ensure_Booted (O, Ok);
         if not Ok then
            raise Coroutine_Error with "too many tasks";
         end if;

         if To_Previous
           and then Previous_Slot (O) in Valid_Slot
           and then Pool (Previous_Slot (O)).Owner = O
         then
            Switch_Slot (Previous_Slot (O));
         end if;

         --  Get the nearest parent coroutine still alive *and belonging to
         --  the task we are running on*, and resume execution in it. The
         --  owner test is what a moved coroutine needs: its parent chain
         --  still points back into the task that created it, and switching
         --  there would install another task's stack. The walk is bounded by
         --  the pool size: a chain longer than that would have to revisit a
         --  slot, and there is nowhere left to go.
         Ancestor := Pool (Slot).Parent;
         for Unused in Valid_Slot loop
            exit when Ancestor not in Valid_Slot
              or else (Alive_Slot (Ancestor)
                       and then Pool (Ancestor).Owner = O);
            Ancestor := Pool (Ancestor).Parent;
         end loop;

         if Ancestor in Valid_Slot
           and then Alive_Slot (Ancestor)
           and then Pool (Ancestor).Owner = O
         then
            Switch_Slot (Ancestor);
         else
            Switch_Slot (Main_Slot_Of (O));
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
