--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The verified core: coroutine lifecycle and the per-coroutine byte stack.
--
--  Coroutines live in a statically sized pool and are named by index rather
--  than by pointer. That is the single decision that makes this package
--  provable: there is no aliasing for SPARK's ownership model to police, and
--  "is this coroutine still alive" is answered by a Boolean in a slot instead
--  of by the validity of a dangling access value.
--
--  The same decision is what made task affinity cheap to add. The three
--  variables that were really per-thread -- the main context, the running
--  coroutine and the backend-up flag -- became arrays indexed by an owner
--  number, exactly as coroutines are arrays indexed by a coroutine number,
--  and a thread's own number is one thread-local scalar. See "Task affinity"
--  in the spec.

with System.Storage_Elements;

pragma Warnings (Off);
with System.Atomic_Operations.Integer_Arithmetic;
pragma Warnings (On);
--  Instantiated inside the Threads body only, which is SPARK_Mode Off. The
--  warnings are suppressed for the same reason Coroutines does it around
--  System.Soft_Links: this is a runtime-internal unit and -gnatwae would
--  otherwise turn its "internal unit withed by a user program" note into an
--  error.

with Minicoro.Contexts;
with Minicoro.FTAL;

package body Minicoro with
  SPARK_Mode,
  Refined_State => (Pool          => (Coros, Main_Ctxs),
                    Storage       => Stores,
                    Backend       => (Backend_Up, Contexts.Backend_State),
                    Current_State => Currents,
                    Affinity      => Me)
is
   use System.Storage_Elements;
   use type Contexts.Body_Entry;

   type Store_Buffer is array (1 .. Max_Storage) of Byte;

   type Coroutine_Record is limited record
      Coro_State : State          := Dead;
      In_Use     : Boolean        := False;
      Func       : Entry_Point    := null;
      Prev       : Coroutine_Id   := No_Coroutine;

      Owner      : Owner_Id       := No_Owner;
      --  Which thread may switch to this coroutine. No_Owner means detached:
      --  nobody may switch to it and anybody may Adopt it. A scalar in the
      --  slot rather than anything cleverer, for the same reason the rest of
      --  the pool is scalars -- there is nothing to alias and nothing to
      --  reclaim.

      Ctx   : Contexts.Context;
      Stack : Contexts.Stack_Handle;
   end record;

   type Storage_Record is record
      Store  : Store_Buffer  := [others => 0];
      Stored : Storage_Count := 0;
      Cap    : Storage_Count := 0;
   end record
     with Dynamic_Predicate => Storage_Record.Stored <= Storage_Record.Cap;
   --  The predicate is the storage API's whole safety argument in one line:
   --  a slot never holds more bytes than it has room for.
   --
   --  A separate array from Coros, not a set of components in it, and the
   --  reason is Control_Transferred. That helper havocs Coros to model the
   --  fact that control ran elsewhere across a switch; with the byte stacks
   --  inside Coros it havoc'd those too, so nothing could be said about a
   --  coroutine's storage across Resume or Yield. Held apart, the switch says
   --  nothing about the byte stacks -- which is the truth, since the assembly
   --  never touches them.

   type Pool_Array is array (Valid_Id) of Coroutine_Record;
   type Store_Array is array (Valid_Id) of Storage_Record;

   type Context_Array is array (Valid_Owner) of Contexts.Context;
   type Running_Array is array (Valid_Owner) of Coroutine_Id;
   type Flag_Array    is array (Valid_Owner) of Boolean;

   Coros      : Pool_Array;
   Stores     : Store_Array;

   Main_Ctxs  : Context_Array;
   --  One per thread: the thread's own context. No_Coroutine names it, so
   --  that a thread and a coroutine are the same kind of thing to Transfer.
   --  This used to be a single variable, which meant whichever thread called
   --  in first had its stack recorded as "the" main context and every other
   --  thread restored that one on the way out.

   Currents   : Running_Array := [others => No_Coroutine];
   Backend_Up : Flag_Array    := [others => False];
   --  Also per thread. Backend_Up says this thread has adopted its own stack;
   --  Contexts.Backend_State, the code page, is genuinely shared and is
   --  brought up once.

   Me : Owner_Id := No_Owner;
   pragma Thread_Local_Storage (Me);
   --  The calling thread's number, and the only thread-local object in the
   --  tree. Reading it compiles to one %fs-relative load on x86-64, so the
   --  affinity checks cost a load and a compare whether or not the program
   --  has any tasks, and pull in no tasking runtime.
   --
   --  The pragma is fussy: it accepts only an explicit null, a static
   --  expression or a static aggregate as the initialization, which is why
   --  this is a scalar and why the pools around it could not be given the
   --  same treatment -- they all have default component values. That is
   --  recorded in CLAUDE.md under "Per-task pools".
   --
   --  GNATprove does not model Thread_Local_Storage and analyses this as an
   --  ordinary variable. That is the right reading for the proofs, which are
   --  all about one thread of control: what the pragma buys is that a second
   --  thread gets a second copy, and every proof about the first still holds
   --  of it.

   -------------
   -- Threads --
   -------------

   package Threads with SPARK_Mode => On is

      procedure Next_Owner (O : out Owner_Id)
        with Global => null;
      --  Hand out the next unused thread number, or No_Owner when Max_Owners
      --  have already been handed out. Numbers are never reused.
      --
      --  TRUSTED, and the one place in the tree that is genuinely concurrent.
      --  The body is a single atomic fetch-and-add on a counter, which is the
      --  only way two threads arriving here at once can be made to leave with
      --  different numbers. Outside SPARK because SPARK has no model of an
      --  atomic read-modify-write, and Global => null is a statement about
      --  the Ada state this package reasons over rather than about the
      --  counter, which nothing else observes.

   end Threads;

   procedure Trampoline (Handle : System.Address)
     with Convention => C,
          Pre => Ready (Current_Owner)
                   and then To_Integer (Handle) in
                              Integer_Address (Valid_Id'First)
                                .. Integer_Address (Valid_Id'Last)
                   and then Coros (Id_Of (Handle)).In_Use
                   and then Coros (Id_Of (Handle)).Prev /= Id_Of (Handle)
                   and then (if Coros (Id_Of (Handle)).Prev /= No_Coroutine
                             then Coros (Coros (Id_Of (Handle)).Prev).In_Use);
   --  Never returns -- it ends in an unreachable spin -- but it is not marked
   --  No_Return: GNATprove rejects taking 'Access of such a subprogram, and
   --  Make_Context needs its address.
   --
   --  ASSUMPTION. Nothing in SPARK discharges this precondition, because
   --  nothing in SPARK calls Trampoline: the only reference to it is the
   --  'Access taken in Trampoline_Entry, which is SPARK_Mode Off, and the
   --  only caller is the generated entry trampoline, which loads Handle from
   --  R13. So the precondition is not a check but a statement of what
   --  Make_Context and the generated code owe this subprogram -- Handle is
   --  the pool index Create encoded, that slot is live, and its resumer is
   --  neither itself nor a released slot. Create establishes each of those
   --  before it hands Handle_Of (Slot) to Make_Context. Read it the way the
   --  contracts on Contexts.Switch are read.
   --
   --  Ready (Current_Owner) is the affinity half of the same obligation: the
   --  generated code only reaches here because some thread switched into this
   --  coroutine, and Resume, Yield and Switch_To all refuse to do that unless
   --  the coroutine is theirs and their own backend is up.

   function Ready (O : Owner_Id) return Boolean is
     (O in Valid_Owner
        and then Backend_Up (O)
        and then Contexts.Backend_Ready);
   --  Backend_Up alone would not do: it says this thread's main context has
   --  been adopted, but Make_Context and Switch need Contexts.Backend_Ready,
   --  and nothing relates the two. Carrying both in one predicate lets every
   --  precondition below be discharged rather than assumed. The owner
   --  argument is what makes "the backend is up" a per-thread question, which
   --  it has to be: the code page is shared, the adopted stack is not.

   procedure Transfer (O : Owner_Id; From, To : Coroutine_Id)
     with Pre => From /= To
                   and then Ready (O)
                   and then (if To /= No_Coroutine then Coros (To).In_Use);

   procedure Control_Transferred
     with Global => (In_Out => (Coros, Currents));
   --  Called by Transfer the instant Contexts.Switch returns. The body is
   --  empty and outside SPARK, so the prover learns nothing from it and
   --  everything from this contract: the pool and the identity of the running
   --  coroutine may have changed arbitrarily.
   --
   --  That is the honest model of a context switch, and it is what makes the
   --  three "coroutine re-entry" assumptions below meaningful. Without it
   --  SPARK reasons as though Transfer returned with the globals it was
   --  handed -- so it still knows the value the caller stored into Currents a
   --  line earlier, and each Assume then *contradicts* what it derived. A
   --  contradictory Assume makes everything after it vacuously provable,
   --  which silently cost Resume, Yield and Switch_To their postconditions.
   --  With Currents and Coros havoc'd the same three assumptions become
   --  genuine restorations, and those postconditions are proved for real.
   --
   --  Me is deliberately *not* havoc'd. A context switch moves control to
   --  another stack, never to another thread: the switch routine does not
   --  touch %fs, so whichever thread was executing before it is executing
   --  after it, and its number is unchanged. That is what lets the owner read
   --  in Trampoline be trusted.

   procedure Ensure_Owner (O : out Owner_Id)
     with Global => (In_Out => Me),
          Post   => O = Current_Owner;
   --  Number this thread if it has not been numbered yet. Split out from
   --  Ensure_Backend so that the one operation which writes Affinity is a
   --  procedure: Current_Owner has to stay a function to be usable in
   --  contracts, and a SPARK function may not write globals (E0005).

   procedure Ensure_Backend (O : out Owner_Id; Res : out Result)
     with Post => O = Current_Owner
                    and then (if Res = Success then Ready (O));

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

   function Awaited_By_Another (C : Valid_Id) return Boolean is
     (for some I in Valid_Id =>
        Coros (I).In_Use and then Coros (I).Prev = C)
     with Global => (Input => Coros);
   --  Whether any live coroutine is parked waiting to return into C. This is
   --  the condition Detach must refuse on, and it is not the same as C's own
   --  state: if A resumed B then A is Normal and B is Running, and it is B --
   --  not A -- that records the link. Moving A while B still names it would
   --  leave B yielding onto a stack that had changed threads underneath it.

   -------------
   -- Threads --
   -------------

   package body Threads with SPARK_Mode => Off is

      type Owner_Counter is range 0 .. 2 ** 31 - 1 with Atomic;
      --  Deliberately far wider than Max_Owners. The fetch-and-add below has
      --  to be able to run past the ceiling: two threads arriving together
      --  can both pass the cheap pre-check and both increment, and a counter
      --  whose range stopped at Max_Owners would raise Constraint_Error on
      --  the second of them instead of simply refusing it.

      package Counter_Ops is new
        System.Atomic_Operations.Integer_Arithmetic (Owner_Counter);

      Handed_Out : aliased Owner_Counter := 0;
      --  Never decremented. A thread that exits does not give its number
      --  back, because a coroutine may still record it as its owner and
      --  reusing the number would silently hand that coroutine to a
      --  different thread. Max_Owners is therefore a budget of threads over
      --  the life of the process, not of live threads.

      procedure Next_Owner (O : out Owner_Id) is
         Taken : Owner_Counter;
      begin
         --  Saturating rather than wrapping: once the counter reaches
         --  Max_Owners it stays there, and every further thread is told
         --  Too_Many_Tasks instead of being given a number that is already
         --  in use. The add is guarded by the read rather than by a
         --  compare-and-swap, so the counter can be pushed to Max_Owners by
         --  several threads at once -- which is harmless, since the outcome
         --  either way is that they are all refused.
         if Handed_Out >= Max_Owners then
            O := No_Owner;
            return;
         end if;

         Taken := Counter_Ops.Atomic_Fetch_And_Add (Handed_Out, 1);
         if Taken >= Max_Owners then
            O := No_Owner;
         else
            O := Owner_Id (Taken) + 1;
         end if;
      end Next_Owner;

   end Threads;

   ---------------
   -- Observers --
   ---------------

   function Status (C : Coroutine_Id) return State is
     (if C = No_Coroutine then Dead else Coros (C).Coro_State);

   function Bytes_Stored (C : Coroutine_Id) return Storage_Count is
     (if C = No_Coroutine then 0 else Stores (C).Stored);

   function Storage_Size (C : Coroutine_Id) return Storage_Count is
     (if C = No_Coroutine then 0 else Stores (C).Cap);

   function Free_Space (C : Coroutine_Id) return Storage_Count is
     (Storage_Size (C) - Bytes_Stored (C));

   function Current_Owner return Owner_Id is (Me);

   function Running_Coroutine return Coroutine_Id is
     (if Me in Valid_Owner then Currents (Me) else No_Coroutine);

   function Is_Allocated (C : Coroutine_Id) return Boolean is
     (C /= No_Coroutine and then Coros (C).In_Use);

   function Owner_Of (C : Coroutine_Id) return Owner_Id is
     (if C = No_Coroutine then No_Owner else Coros (C).Owner);

   ------------------
   -- Ensure_Owner --
   ------------------

   procedure Ensure_Owner (O : out Owner_Id) is
   begin
      if Me = No_Owner then
         Threads.Next_Owner (Me);
      end if;
      O := Me;
   end Ensure_Owner;

   --------------------
   -- Ensure_Backend --
   --------------------

   procedure Ensure_Backend (O : out Owner_Id; Res : out Result) is
      Ok : Boolean;
   begin
      Ensure_Owner (O);
      if O = No_Owner then
         Res := Too_Many_Tasks;
         return;
      end if;

      --  Idempotent, and cheap once the code page exists. Calling it
      --  unconditionally is what makes Contexts.Backend_Ready hold on every
      --  path out of here, including the already-initialized one.
      Contexts.Initialize_Backend (Ok);
      if not Ok then
         Res := Make_Context_Error;
         return;
      end if;

      --  Claim this thread's own stack once, so that switching away from it
      --  has somewhere to save its registers. Per thread, not per process:
      --  each thread runs on a different stack and each needs its own.
      if not Backend_Up (O) then
         Contexts.Adopt_Current (Main_Ctxs (O));
         Backend_Up (O) := True;
      end if;

      Res := Success;
   end Ensure_Backend;

   --------------
   -- Transfer --
   --------------

   procedure Transfer (O : Owner_Id; From, To : Coroutine_Id) is
   begin
      --  ASSUMPTION (stack disjointness). Contexts.Switch requires the two
      --  contexts to own disjoint stacks. They do: every coroutine stack is a
      --  separate heap allocation, and each main context's is a thread's,
      --  which we never allocate out of. SPARK cannot see that two distinct
      --  pool slots hold distinct allocations, so the fact is asserted here
      --  rather than derived. See README.md, "What is assumed".
      pragma Assume
        (FTAL.Switch_Pre
           (Contexts.Model (if From = No_Coroutine
                            then Main_Ctxs (O) else Coros (From).Ctx),
            Contexts.Model (if To = No_Coroutine
                            then Main_Ctxs (O) else Coros (To).Ctx)));

      if From = No_Coroutine then
         Contexts.Switch (Main_Ctxs (O), Coros (To).Ctx);
      elsif To = No_Coroutine then
         Contexts.Switch (Coros (From).Ctx, Main_Ctxs (O));
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

      --  Control left this thread of execution at the Switch above and has
      --  only just come back, having run inside another coroutine in the
      --  meantime. Say so.
      Control_Transferred;
   end Transfer;

   -------------------------
   -- Control_Transferred --
   -------------------------

   procedure Control_Transferred is
      pragma SPARK_Mode (Off);
      --  Deliberately empty. What it models already happened, in the
      --  generated switch routine, while control was elsewhere; there is
      --  nothing left to execute. Off so that SPARK cannot see that and must
      --  take the declared Global at its word.
   begin
      null;
   end Control_Transferred;

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
      Res          : out Result)
   is
      Slot  : Coroutine_Id := No_Coroutine;
      Owner : Owner_Id;
      Ok    : Boolean;
   begin
      C := No_Coroutine;

      if Func = null then
         Res := Invalid_Arguments;
         return;
      end if;

      Ensure_Backend (Owner, Res);
      if Res /= Success then
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
      pragma Annotate
        (GNATprove, Intentional, "resource or memory leak might occur",
         "Slot was chosen above because not Coros (Slot).In_Use, and Destroy "
         & "is the only way a slot becomes free: it calls Free_Stack and only "
         & "then clears In_Use, so a free slot's handle owns nothing. From "
         & "here SPARK knows Stack_Handle is an ownership type but cannot "
         & "reach the pointer inside it, and it does not track reclamation "
         & "across calls through an array element with a non-static index.");
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
      Coros (Slot).Prev       := No_Coroutine;
      Coros (Slot).Owner      := Owner;
      Stores (Slot).Stored     := 0;
      Stores (Slot).Cap        := Storage_Size;
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

      --  A detached coroutine may be destroyed by anybody: nobody can switch
      --  to it, so there is no stack anyone can be about to run on. One that
      --  still has an owner may only be destroyed by that owner, because
      --  Free_Stack releases memory the owner may be a switch away from
      --  standing on.
      if Coros (C).Owner /= No_Owner and then Coros (C).Owner /= Me then
         Res := Wrong_Task;
         return;
      end if;

      Contexts.Reset (Coros (C).Ctx);
      Contexts.Free_Stack (Coros (C).Stack);

      Coros (C).Coro_State := Dead;
      Coros (C).In_Use     := False;
      Coros (C).Func       := null;
      Coros (C).Prev       := No_Coroutine;
      Coros (C).Owner      := No_Owner;
      Stores (C).Stored     := 0;
      Stores (C).Cap        := 0;

      Res := Success;
   end Destroy;

   ------------
   -- Detach --
   ------------

   procedure Detach (C : Coroutine_Id; Res : out Result) is
   begin
      if C = No_Coroutine or else not Coros (C).In_Use then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Me = No_Owner or else Coros (C).Owner /= Me then
         Res := Wrong_Task;
         return;
      end if;

      --  Parked, in the two senses that matter. Running or Dead is refused
      --  outright -- one is on a stack right now, the other has nothing left
      --  to hand over -- and so is a coroutine some other coroutine is
      --  waiting to return into.
      if Coros (C).Coro_State not in Normal | Suspended
        or else Awaited_By_Another (C)
      then
         Res := Coroutine_Busy;
         return;
      end if;

      --  Sever it from this thread's chain as well as from this thread. Prev
      --  names whoever last switched in, which is a coroutine of ours; left
      --  set, the completion path in Trampoline would try to hand control
      --  back to it from the adopting thread. Cleared, completion goes to
      --  whichever main context is current, which is the adopter's.
      Coros (C).Prev       := No_Coroutine;
      Coros (C).Owner      := No_Owner;
      Coros (C).Coro_State := Suspended;

      Res := Success;
   end Detach;

   --------------
   -- Register --
   --------------

   procedure Register (O : out Owner_Id; Res : out Result) is
   begin
      Ensure_Backend (O, Res);
   end Register;

   -----------
   -- Adopt --
   -----------

   procedure Adopt (C : Coroutine_Id; Res : out Result) is
      Owner : Owner_Id;
   begin
      if C = No_Coroutine or else not Coros (C).In_Use then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Coros (C).Owner /= No_Owner then
         Res := Wrong_Task;
         return;
      end if;

      --  Adopting is a thread's first relevant act as often as creating is,
      --  so it numbers the thread and brings up its main context too. A
      --  worker that only ever steals work still needs somewhere to save its
      --  own registers when it switches into what it stole.
      Ensure_Backend (Owner, Res);
      if Res /= Success then
         return;
      end if;

      Coros (C).Owner := Owner;
      Res := Success;
   end Adopt;

   ------------
   -- Resume --
   ------------

   procedure Resume (C : Valid_Id; Res : out Result) is
      Owner : constant Owner_Id := Me;
      Prev  : Coroutine_Id;
   begin
      if not Coros (C).In_Use then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Owner = No_Owner or else Coros (C).Owner /= Owner then
         --  Live code, and the only thing stopping a thread from installing
         --  another thread's stack pointer on itself.
         Res := Wrong_Task;
         return;
      end if;

      if Coros (C).Coro_State /= Suspended then
         --  Live code, and the only thing enforcing it: Resume carries no
         --  precondition, by the reasoning in the spec.
         Res := Not_Suspended;
         return;
      end if;

      Prev := Currents (Owner);

      if not Ready (Owner) or else C = Prev then
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
      Currents (Owner) := C;

      Transfer (Owner, Prev, C);

      --  ASSUMPTION (coroutine re-entry).
      --
      --  SPARK models Transfer as an ordinary call that returns with the
      --  globals as it left them. What actually happened is that control ran
      --  inside C, and possibly inside coroutines C resumed in turn, before
      --  arriving back here. The two facts below are re-established by the
      --  only routines that can return control to this point -- Yield and
      --  Trampoline -- each of which restores this thread's Currents entry
      --  and moves C to Suspended or Dead before switching back.
      --
      --  This is a real gap in the verification, not a technicality; it is
      --  recorded in README.md alongside the trusted assembly.
      pragma Assume (Currents (Owner) = Prev);
      pragma Assume (Coros (C).Coro_State in Suspended | Dead);

      Res := Success;
   end Resume;

   -----------
   -- Yield --
   -----------

   procedure Yield (C : Valid_Id; Res : out Result) is
      Owner : constant Owner_Id := Me;
      Prev  : constant Coroutine_Id := Coros (C).Prev;
   begin
      if Owner = No_Owner or else Coros (C).Owner /= Owner then
         Res := Wrong_Task;
         return;
      end if;

      if Coros (C).Coro_State /= Running or else not Ready (Owner) then
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
      Currents (Owner) := Prev;

      Transfer (Owner, C, Prev);

      --  ASSUMPTION (coroutine re-entry), as in Resume: control is here again
      --  only because someone resumed C, and Resume sets both of these before
      --  switching in.
      pragma Assume (Currents (Owner) = C);
      pragma Assume (Coros (C).Coro_State = Running);

      Res := Success;
   end Yield;

   ---------------
   -- Switch_To --
   ---------------

   procedure Switch_To (Target : Coroutine_Id; Res : out Result) is
      Owner : constant Owner_Id := Me;
      Cur   : Coroutine_Id;
   begin
      if Owner = No_Owner then
         --  A thread that has never created or adopted anything owns no
         --  coroutine, so there is nothing it may switch to and nowhere of
         --  its own to switch back from.
         Res := Wrong_Task;
         return;
      end if;

      if Target /= No_Coroutine
        and then (not Coros (Target).In_Use
                  or else Coros (Target).Coro_State = Dead)
      then
         Res := Invalid_Coroutine;
         return;
      end if;

      if Target /= No_Coroutine and then Coros (Target).Owner /= Owner then
         Res := Wrong_Task;
         return;
      end if;

      Cur := Currents (Owner);

      if Target = Cur or else not Ready (Owner) then
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
      Currents (Owner) := Target;

      Transfer (Owner, Cur, Target);

      --  ASSUMPTION (coroutine re-entry), as in Resume.
      pragma Assume (Currents (Owner) = Cur);

      Res := Success;
   end Switch_To;

   ----------------
   -- Trampoline --
   ----------------

   procedure Trampoline (Handle : System.Address) is
      C         : constant Valid_Id := Id_Of (Handle);
      Body_Proc : constant Entry_Point := Coros (C).Func;
      Owner     : Owner_Id;
      Prev      : Coroutine_Id;
   begin
      if Body_Proc /= null then
         Body_Proc (C);
      end if;

      --  Read the thread number here rather than on entry, and read it into a
      --  variable rather than a constant. This is the one place in the tree
      --  where the two differ: the body above suspends and resumes, and a
      --  coroutine may be Detached and Adopted by another thread while it is
      --  suspended, so the thread that finishes a coroutine need not be the
      --  one that started it. It is the finishing thread whose main context
      --  we have to be able to return to, and whose Currents entry names what
      --  runs next.
      Owner := Me;

      --  ASSUMPTION (coroutine re-entry, affinity). Whichever thread we are
      --  on reached this coroutine by switching into it, and the only three
      --  routines that can do that -- Resume, Yield and Switch_To -- each
      --  refuse unless the coroutine is theirs and Ready holds of them. Adopt
      --  is what makes a coroutine theirs, and it brings the adopting
      --  thread's backend up before it will hand ownership over.
      pragma Assume (Ready (Owner));

      Prev := Coros (C).Prev;
      pragma Assert (Prev /= C);
      Coros (C).Coro_State := Dead;
      Coros (C).Prev       := No_Coroutine;
      if Prev /= No_Coroutine then
         Coros (Prev).Coro_State := Running;
      end if;
      Currents (Owner) := Prev;

      Transfer (Owner, C, Prev);

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
      Base : constant Storage_Count := Stores (C).Stored;
   begin
      if Src'Length > Stores (C).Cap - Base then
         Res := Not_Enough_Space;
         return;
      end if;

      for I in Src'Range loop
         Stores (C).Store (Base + 1 + (I - Src'First)) := Src (I);
         pragma Loop_Invariant (Stores (C).Stored = Base);
         pragma Loop_Invariant (Stores (C).Cap = Stores (C).Cap'Loop_Entry);
      end loop;

      Stores (C).Stored := Base + Src'Length;
      Res := Success;
   end Push;

   ---------
   -- Pop --
   ---------

   procedure Pop (C : Valid_Id; Dest : out Byte_Array; Res : out Result) is
   begin
      if Dest'Length > Stores (C).Stored then
         Dest := [others => 0];
         Res  := Not_Enough_Space;
         return;
      end if;

      declare
         Base : constant Storage_Count := Stores (C).Stored - Dest'Length;
      begin
         for I in Dest'Range loop
            Dest (I) := Stores (C).Store (Base + 1 + (I - Dest'First));
            pragma Loop_Invariant
              (Stores (C).Stored = Stores (C).Stored'Loop_Entry);
         end loop;
         Stores (C).Stored := Base;
      end;

      Res := Success;
   end Pop;

   ----------
   -- Peek --
   ----------

   procedure Peek (C : Valid_Id; Dest : out Byte_Array; Res : out Result) is
   begin
      if Dest'Length > Stores (C).Stored then
         Dest := [others => 0];
         Res  := Not_Enough_Space;
         return;
      end if;

      declare
         Base : constant Storage_Count := Stores (C).Stored - Dest'Length;
      begin
         for I in Dest'Range loop
            Dest (I) := Stores (C).Store (Base + 1 + (I - Dest'First));
         end loop;
      end;

      Res := Success;
   end Peek;

end Minicoro;
