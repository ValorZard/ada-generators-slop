--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  Pure-Ada replacement for the PCL (Portable Coroutine Library) dependency,
--  modelled on minicoro <https://github.com/edubart/minicoro>.
--
--  The library is split into a verified core and a small trusted base:
--
--    * Minicoro                    -- SPARK: coroutine lifecycle and storage
--    * Minicoro.Machine_Code       -- SPARK: x86-64 instruction encoder
--    * Minicoro.FTAL               -- SPARK: ghost register/stack typing model
--    * Minicoro.Contexts           -- SPARK, bar the trusted switch itself
--    * Minicoro.Code_Page          -- SPARK: W^X page from the OS
--    * Minicoro.Atomics            -- SPARK bar the counter's full view
--
--  Everything is SPARK_Mode On except eight items, each marked and justified
--  in place: Contexts.Machine, Contexts.Allocate_Stack,
--  Contexts.Make_Context, Contexts.Adopt_Current, Contexts.Switch,
--  Minicoro.Trampoline_Entry, Minicoro's nested Threads package and
--  Minicoro.Atomics' private part. See README.md for what is proved, what is
--  assumed, and why.

package Minicoro with
  SPARK_Mode,
  Abstract_State => (Pool, Storage, Backend, Current_State, Affinity),
  Initializes    => (Pool, Storage, Backend, Current_State, Affinity)
is

   pragma Unevaluated_Use_Of_Old (Allow);
   --  Several postconditions below mention Bytes_Stored (C)'Old inside an
   --  if-expression, which RM 6.1.1(27) would otherwise reject.

   -------------------------
   -- Compile-time limits --
   -------------------------

   --  The verified core uses a statically sized pool rather than pointers:
   --  this is what lets GNATprove discharge the lifecycle proofs without an
   --  ownership model. Raise these if you need more; the cost is static data
   --  (Max_Coroutines * Max_Storage bytes, plus the pool records themselves).
   --  Coroutine *stacks* are still allocated dynamically and are not counted
   --  here.

   Max_Coroutines : constant := 64;
   Max_Storage    : constant := 1024;

   Max_Owners : constant := 16;
   --  How many threads of control may ever touch this library in one process.
   --  Each gets its own main context, its own "what is running" variable and
   --  its own backend-initialised flag; the cost is that much static data, so
   --  this is the figure to raise if a program has more worker threads than
   --  that. Threads are numbered on first use and numbers are never reused,
   --  so a program that creates and joins threads in a loop exhausts this
   --  even though only a few are ever live at once. See "Task affinity".

   Min_Stack_Size     : constant := 32_768;
   Default_Stack_Size : constant := 57_344;  --  56 KiB, as in minicoro

   ------------------
   -- Coroutine Id --
   ------------------

   type Coroutine_Id is range 0 .. Max_Coroutines;
   subtype Valid_Id is Coroutine_Id range 1 .. Max_Coroutines;

   No_Coroutine : constant Coroutine_Id := 0;

   -------------------
   -- Task affinity --
   -------------------

   --  A stackful coroutine is a saved stack pointer and a saved register
   --  file. Switching to one installs that stack pointer on the *calling*
   --  thread, so two threads switching to the same coroutine end up running
   --  on one stack at once -- silent corruption, not an exception. The same
   --  goes for the main context: whichever thread first calls into this
   --  library used to have its stack recorded as "the" main context, and any
   --  other thread switching out would then restore that first thread's stack
   --  pointer while running on its own.
   --
   --  Both are fixed the same way, and it is the way everything else in this
   --  package is done: by indexing. Every thread that touches the library is
   --  numbered on first use, and the three pieces of state that are really
   --  per-thread -- the main context, the running coroutine, and whether the
   --  backend has been brought up -- become arrays indexed by that number
   --  rather than single variables. A thread's own number lives in one
   --  thread-local scalar, which on x86-64 is an %fs-relative load; there is
   --  no lock, no atomic and no tasking runtime on any path a single-threaded
   --  program takes. See Current_Owner.
   --
   --  On top of that, each coroutine records which thread may switch to it.
   --  Every control transfer checks it and reports Wrong_Task rather than
   --  corrupting a stack. Detach and Adopt are how a coroutine legitimately
   --  changes hands.
   --
   --  What this does *not* do is make the library thread-safe. The pool, the
   --  byte stacks and the id-to-slot maps are still plain unsynchronised
   --  arrays, so two threads must not Create or Destroy concurrently; what is
   --  now safe is that a coroutine, once created, can be handed to another
   --  thread and run there, and that a thread cannot touch a coroutine that
   --  is not its own. That is the work-stealing shape: allocate on one
   --  thread, detach, hand the id across, adopt, run.

   type Owner_Id is range 0 .. Max_Owners;
   subtype Valid_Owner is Owner_Id range 1 .. Max_Owners;

   No_Owner : constant Owner_Id := 0;
   --  Also what a detached coroutine's owner reads as: it belongs to nobody
   --  and any thread may Adopt it.

   ------------
   -- States --
   ------------

   type State is
     (Dead,       --  Finished, or never started
      Normal,     --  Active but not running: it resumed another coroutine
      Running,    --  Active and running
      Suspended); --  Suspended in yield, or not started yet

   type Result is
     (Success,
      Invalid_Coroutine,
      Not_Suspended,
      Not_Running,
      Make_Context_Error,
      Not_Enough_Space,
      Out_Of_Memory,
      Invalid_Arguments,
      Invalid_Operation,
      Stack_Overflow,
      Too_Many_Coroutines,

      --  Wrong_Task: the caller is not the thread this coroutine belongs to.
      --  Returned by every operation that transfers control or frees a stack.
      --
      --  Too_Many_Tasks: more than Max_Owners threads have called in.
      --
      --  Coroutine_Busy: Detach was asked to release a coroutine that is
      --  running, or that another coroutine is suspended waiting to return
      --  into.

      Wrong_Task,
      Too_Many_Tasks,
      Coroutine_Busy);

   subtype Storage_Count is Natural range 0 .. Max_Storage;
   subtype Stack_Count   is Natural range 0 .. Natural'Last;

   type Byte is mod 2 ** 8 with Size => 8;
   type Byte_Array is array (Positive range <>) of Byte;

   type Entry_Point is access procedure (C : Valid_Id)
     with Convention => C;

   ---------------
   -- Observers --
   ---------------

   function Status (C : Coroutine_Id) return State
     with Global => (Input => Pool);
   --  State of C. A never-allocated or released id reads as Dead.

   function Bytes_Stored (C : Coroutine_Id) return Storage_Count
     with Global => (Input => Storage),
          Post   => Bytes_Stored'Result <= Storage_Size (C);

   function Storage_Size (C : Coroutine_Id) return Storage_Count
     with Global => (Input => Storage);

   function Free_Space (C : Coroutine_Id) return Storage_Count
     with Global => (Input => Storage),
          Post   => Free_Space'Result = Storage_Size (C) - Bytes_Stored (C);

   function Running_Coroutine return Coroutine_Id
     with Global => (Input => (Current_State, Affinity));
   --  The coroutine currently executing on the calling thread, or
   --  No_Coroutine when that thread is on its own context.

   function Is_Allocated (C : Coroutine_Id) return Boolean
     with Global => (Input => Pool),
          Post   => (if C = No_Coroutine then not Is_Allocated'Result);

   function Current_Owner return Owner_Id
     with Global => (Input => Affinity);
   --  The calling thread's number, or No_Owner if it has never created or
   --  adopted a coroutine. Numbers are handed out by Create and Adopt, which
   --  are the only two operations that can make a thread relevant here; a
   --  thread that only observes never consumes one.
   --
   --  This is a read of one thread-local scalar. It is deliberately a
   --  function with no side effect so that it can be used in contracts and
   --  inside the observers above; the numbering itself happens in Create and
   --  Adopt.

   function Owner_Of (C : Coroutine_Id) return Owner_Id
     with Global => (Input => Pool),
          Post   => (if C = No_Coroutine then Owner_Of'Result = No_Owner);
   --  Which thread may switch to C, or No_Owner if C is detached or was
   --  never allocated.

   function Owned_Here (C : Coroutine_Id) return Boolean is
     (C /= No_Coroutine
        and then Current_Owner /= No_Owner
        and then Owner_Of (C) = Current_Owner)
     with Global => (Input => (Pool, Affinity));
   --  Whether the calling thread may transfer control to C.

   ---------------
   -- Lifecycle --
   ---------------

   procedure Create
     (C            : out Coroutine_Id;
      Func         : Entry_Point;
      Stack_Size   : Stack_Count   := Default_Stack_Size;
      Storage_Size : Storage_Count := Max_Storage;
      Res          : out Result)
     with Global => (In_Out => (Pool, Storage, Backend, Affinity)),
          Post   =>
            (if Res = Success then
               C in Valid_Id
                 and then Status (C) = Suspended
                 and then Is_Allocated (C)
                 and then Owned_Here (C)
                 and then Bytes_Stored (C) = 0
                 and then Minicoro.Storage_Size (C) = Storage_Size
             else C = No_Coroutine);
   --  Allocate a coroutine and its stack. It starts Suspended, owned by the
   --  calling thread; call Resume to begin executing Func.
   --
   --  This is one of the two operations that number a thread, so it can fail
   --  with Too_Many_Tasks once Max_Owners threads have called in.

   procedure Destroy (C : Coroutine_Id; Res : out Result)
     with Global => (In_Out => (Pool, Storage), Input => Affinity),
          Pre    => Status (C) in Dead | Suspended,
          Post   => (if Res = Success then not Is_Allocated (C)
                                       and then Status (C) = Dead);
   --  Release C's stack and pool slot. Only legal when C is not active, and
   --  only from the thread that owns it: freeing a stack another thread may
   --  still switch onto is exactly the corruption affinity exists to stop.
   --  A detached coroutine can be destroyed by anyone -- nobody can switch to
   --  it, so there is nothing to race with.

   procedure Resume (C : Valid_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State),
                     Input  => (Backend, Affinity)),
          Post   => (if Res = Success then Status (C) in Suspended | Dead);
   --  Transfer control into C. Returns when C yields or finishes.
   --
   --  Total, like Switch_To and unlike Yield: every call returns a defined
   --  Result. C not being Suspended is reported as Not_Suspended rather than
   --  forbidden by a precondition. That is deliberate -- the enumerator
   --  exists to report exactly this, the only callers are outside SPARK, and
   --  a precondition here would be neither verified (nothing in SPARK calls
   --  Resume) nor checked (no .gpr in the tree passes -gnata), while making
   --  the guard that does the real work look dead to the prover.
   --
   --  C not belonging to the calling thread is reported the same way, as
   --  Wrong_Task, and for the same reason.

   procedure Yield (C : Valid_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State),
                     Input  => (Backend, Affinity)),
          Pre    => Status (C) = Running,
          Post   => (if Res = Success then Status (C) = Running);
   --  Suspend C and return control to whoever resumed it. On return -- that
   --  is, once someone has resumed C again -- C is running once more.

   procedure Switch_To (Target : Coroutine_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State),
                     Input  => (Backend, Affinity)),
          Post   => (if Res = Success
                     then Running_Coroutine = Running_Coroutine'Old);
   --  Symmetric transfer: save whatever is running and continue Target
   --  wherever it last stopped, regardless of who created or resumed whom.
   --  No_Coroutine names the calling thread's own context, so this can hand
   --  control back out of the coroutine world as well as between coroutines.
   --
   --  Resume and Yield are the disciplined asymmetric pair and should be
   --  preferred. This is the general operation underneath them, and exists
   --  because a scheduler built on top -- such as the Coroutines package in
   --  this repository -- needs to hand control to an arbitrary peer, which is
   --  what PCL's co_call provided.

   ----------------------
   -- Moving a thread --
   ----------------------

   --  Detach and Adopt are the move, split in two because there is no handle
   --  on another thread to move a coroutine *to*: only the receiving thread
   --  can adopt, because adopting is what says "I may now switch to this".
   --  The releasing thread calls Detach, the coroutine id crosses to the
   --  other thread by whatever means the program already has, and the
   --  receiving thread calls Adopt. In between the coroutine belongs to
   --  nobody and no thread may switch to it, which is what makes the hand-off
   --  safe without a lock.
   --
   --  That split is also exactly the shape work stealing wants: a detached
   --  coroutine is a unit of work sitting in a queue, and Adopt is the steal.

   procedure Register (O : out Owner_Id; Res : out Result)
     with Global => (In_Out => (Pool, Backend, Affinity)),
          Post   => O = Current_Owner
                      and then (if Res = Success then O in Valid_Owner);
   --  Number the calling thread and bring up its main context, without
   --  creating anything. Create and Adopt do this for themselves; this is for
   --  a layer above that has its own per-thread bookkeeping to set up first
   --  -- Coroutines reserves a slot per thread for the thread itself, and has
   --  to know its number before it can.

   procedure Detach (C : Coroutine_Id; Res : out Result)
     with Global => (In_Out => Pool, Input => Affinity),
          Post   => (if Res = Success
                     then Owner_Of (C) = No_Owner
                            and then Status (C) = Suspended);
   --  Give up ownership of C so that another thread may Adopt it.
   --
   --  Refused with Coroutine_Busy unless C is genuinely parked: it must not
   --  be the running coroutine, and no other coroutine may be suspended
   --  waiting to return into it. The second condition is the one that is easy
   --  to miss -- if A resumed B, then B holds A as its resumer, and moving A
   --  alone would leave B yielding onto a stack that now belongs to another
   --  thread.
   --
   --  A successful Detach also clears C's own resumer and leaves C Suspended,
   --  severing it from the releasing thread's chain: when C next finishes it
   --  returns to whichever thread's main context is current, which is the
   --  adopting one. Normal -- "active, but it resumed someone else" -- is a
   --  statement about a chain that no longer exists once the coroutine is
   --  parked and nobody is waiting on it, and leaving it set would make the
   --  coroutine ineligible for both Resume and Destroy.

   procedure Adopt (C : Coroutine_Id; Res : out Result)
     with Global => (In_Out => (Pool, Backend, Affinity)),
          Post   => (if Res = Success then Owned_Here (C));
   --  Take ownership of a detached coroutine. Fails with Wrong_Task if C
   --  still belongs to someone, and with Too_Many_Tasks if this thread cannot
   --  be numbered. Like Create, this is an operation that numbers a thread.

   -----------------
   -- Storage API --
   -----------------

   --  A small per-coroutine byte stack, used to pass values across a
   --  Resume/Yield boundary. These four operations are proved free of
   --  overflow and of reads past the written region.
   --
   --  Deliberately *not* affinity-checked. They touch a byte array and never
   --  a context, so no reading or writing of one can put a thread on another
   --  thread's stack -- the thing affinity exists to prevent. A thread that
   --  has just adopted a coroutine legitimately wants to read what the
   --  previous owner pushed, and a check here would refuse exactly that.

   procedure Push (C : Valid_Id; Src : Byte_Array; Res : out Result)
     with Global => (In_Out => Storage, Proof_In => Pool),
          Pre    => Is_Allocated (C),
          Post   =>
            (if Src'Length <= Free_Space (C)'Old then
               Res = Success
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old + Src'Length
             else
               Res = Not_Enough_Space
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old);

   procedure Pop (C : Valid_Id; Dest : out Byte_Array; Res : out Result)
     with Global => (In_Out => Storage, Proof_In => Pool),
          Pre    => Is_Allocated (C),
          Post   =>
            (if Dest'Length <= Bytes_Stored (C)'Old then
               Res = Success
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old - Dest'Length
             else
               Res = Not_Enough_Space
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old);

   procedure Peek (C : Valid_Id; Dest : out Byte_Array; Res : out Result)
     with Global => (Input => Storage, Proof_In => Pool),
          Pre    => Is_Allocated (C),
          Post   => Bytes_Stored (C) = Bytes_Stored (C)'Old
                      and then
                    (if Dest'Length <= Bytes_Stored (C)'Old
                       then Res = Success else Res = Not_Enough_Space);

end Minicoro;
