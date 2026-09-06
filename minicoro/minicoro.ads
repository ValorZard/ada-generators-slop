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
--    * Minicoro.Contexts           -- trusted: context switch (SPARK_Mode Off)
--
--  Everything except Minicoro.Contexts' body is proved by GNATprove. See
--  README.md for what is proved, what is assumed, and why.

with System;

package Minicoro with
  SPARK_Mode,
  Abstract_State => (Pool, Current_State),
  Initializes    => (Pool, Current_State)
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

   Min_Stack_Size     : constant := 32_768;
   Default_Stack_Size : constant := 57_344;  --  56 KiB, as in minicoro

   ------------------
   -- Coroutine Id --
   ------------------

   type Coroutine_Id is range 0 .. Max_Coroutines;
   subtype Valid_Id is Coroutine_Id range 1 .. Max_Coroutines;

   No_Coroutine : constant Coroutine_Id := 0;

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
      Too_Many_Coroutines);

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
     with Global => (Input => Pool),
          Post   => Bytes_Stored'Result <= Storage_Size (C);

   function Storage_Size (C : Coroutine_Id) return Storage_Count
     with Global => (Input => Pool);

   function Free_Space (C : Coroutine_Id) return Storage_Count
     with Global => (Input => Pool),
          Post   => Free_Space'Result = Storage_Size (C) - Bytes_Stored (C);

   function User_Data (C : Coroutine_Id) return System.Address
     with Global => (Input => Pool);

   function Running_Coroutine return Coroutine_Id
     with Global => (Input => Current_State);
   --  The coroutine currently executing, or No_Coroutine on the main context.

   function Is_Allocated (C : Coroutine_Id) return Boolean
     with Global => (Input => Pool),
          Post   => (if C = No_Coroutine then not Is_Allocated'Result);

   ---------------
   -- Lifecycle --
   ---------------

   procedure Create
     (C            : out Coroutine_Id;
      Func         : Entry_Point;
      Stack_Size   : Stack_Count   := Default_Stack_Size;
      Storage_Size : Storage_Count := Max_Storage;
      User_Data    : System.Address := System.Null_Address;
      Res          : out Result)
     with Global => (In_Out => Pool),
          Post   =>
            (if Res = Success then
               C in Valid_Id
                 and then Status (C) = Suspended
                 and then Is_Allocated (C)
                 and then Bytes_Stored (C) = 0
                 and then Minicoro.Storage_Size (C) = Storage_Size
             else C = No_Coroutine);
   --  Allocate a coroutine and its stack. It starts Suspended; call Resume to
   --  begin executing Func.

   procedure Destroy (C : Coroutine_Id; Res : out Result)
     with Global => (In_Out => Pool),
          Pre    => Status (C) in Dead | Suspended,
          Post   => (if Res = Success then not Is_Allocated (C)
                                       and then Status (C) = Dead);
   --  Release C's stack and pool slot. Only legal when C is not active.

   procedure Resume (C : Valid_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State)),
          Pre    => Status (C) = Suspended,
          Post   => (if Res = Success then Status (C) in Suspended | Dead);
   --  Transfer control into C. Returns when C yields or finishes.

   procedure Yield (C : Valid_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State)),
          Pre    => Status (C) = Running,
          Post   => (if Res = Success then Status (C) = Running);
   --  Suspend C and return control to whoever resumed it. On return -- that
   --  is, once someone has resumed C again -- C is running once more.

   procedure Switch_To (Target : Coroutine_Id; Res : out Result)
     with Global => (In_Out => (Pool, Current_State)),
          Post   => (if Res = Success
                     then Running_Coroutine = Running_Coroutine'Old);
   --  Symmetric transfer: save whatever is running and continue Target
   --  wherever it last stopped, regardless of who created or resumed whom.
   --  No_Coroutine names the main program's own context, so this can hand
   --  control back out of the coroutine world as well as between coroutines.
   --
   --  Resume and Yield are the disciplined asymmetric pair and should be
   --  preferred. This is the general operation underneath them, and exists
   --  because a scheduler built on top -- such as the Coroutines package in
   --  this repository -- needs to hand control to an arbitrary peer, which is
   --  what PCL's co_call provided.

   -----------------
   -- Storage API --
   -----------------

   --  A small per-coroutine byte stack, used to pass values across a
   --  Resume/Yield boundary. These four operations are proved free of
   --  overflow and of reads past the written region.

   procedure Push (C : Valid_Id; Src : Byte_Array; Res : out Result)
     with Global => (In_Out => Pool),
          Pre    => Is_Allocated (C),
          Post   =>
            (if Src'Length <= Free_Space (C)'Old then
               Res = Success
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old + Src'Length
             else
               Res = Not_Enough_Space
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old);

   procedure Pop (C : Valid_Id; Dest : out Byte_Array; Res : out Result)
     with Global => (In_Out => Pool),
          Pre    => Is_Allocated (C),
          Post   =>
            (if Dest'Length <= Bytes_Stored (C)'Old then
               Res = Success
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old - Dest'Length
             else
               Res = Not_Enough_Space
                 and then Bytes_Stored (C) = Bytes_Stored (C)'Old);

   procedure Peek (C : Valid_Id; Dest : out Byte_Array; Res : out Result)
     with Global => (Input => Pool),
          Pre    => Is_Allocated (C),
          Post   => Bytes_Stored (C) = Bytes_Stored (C)'Old
                      and then
                    (if Dest'Length <= Bytes_Stored (C)'Old
                       then Res = Success else Res = Not_Enough_Space);

end Minicoro;
