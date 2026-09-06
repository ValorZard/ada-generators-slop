--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The trusted base: saved machine contexts and the switch between them.
--
--  This spec is SPARK; the body is not, and cannot be. Switching stacks is
--  not expressible in Ada's semantics, let alone SPARK's. What this package
--  does instead is state, in the contracts below, exactly what the trusted
--  code promises -- using the ghost model in Minicoro.FTAL -- so that every
--  caller's obligations are checked by GNATprove even though the callee's
--  are not.
--
--  The machine code itself is not written here. It is generated at
--  elaboration by Minicoro.Machine_Code, which is proved, and installed into
--  an executable page by Minicoro.Code_Page.

with System;

with Minicoro.FTAL;
with Minicoro.Machine_Code;

private package Minicoro.Contexts with
  SPARK_Mode,
  Abstract_State => (Backend_State with Part_Of => Minicoro.Pool),
  Initializes    => Backend_State
is
   --  A private child so that the generated code page and the "is the backend
   --  up" flag can be declared Part_Of the parent's Pool. Without that, every
   --  operation in Minicoro would have to name this package's state in its
   --  own Global contract -- and a parent spec may not depend on its child,
   --  so it could not even do so.

   use type FTAL.Stack_Region;

   type Context is limited private with
     Default_Initial_Condition => not FTAL.Well_Typed (Model (Context));
   --  A fresh buffer is unmade, hence not a switch target until Make_Context
   --  or Adopt_Current has run on it.

   type Stack_Handle is private with
     Default_Initial_Condition => not Is_Allocated (Stack_Handle);

   type Body_Entry is access procedure (Handle : System.Address)
     with Convention => C;
   --  A coroutine body, as the generated trampoline will call it.

   ------------------
   -- Ghost model  --
   ------------------

   --  These have no bodies in SPARK. They are uninterpreted: everything a
   --  caller knows about them comes from the contracts below, which is
   --  precisely the trusted interface.

   function Model (C : Context) return FTAL.Context_Model
     with Ghost, Global => null;
   function Region_Of (S : Stack_Handle) return FTAL.Stack_Region
     with Ghost, Global => null;
   function Is_Allocated (S : Stack_Handle) return Boolean
     with Ghost, Global => null;

   -------------------------
   -- Backend elaboration --
   -------------------------

   function Backend_Ready return Boolean
     with Global => (Input => Backend_State);

   procedure Initialize_Backend (Ok : out Boolean)
     with Global => (In_Out => Backend_State),
          Post   => (if Ok then Backend_Ready);
   --  Assemble the switch routine and the entry trampoline for this target's
   --  ABI and install them in an executable page. Idempotent. Must succeed
   --  before any other operation here is called.

   function Target_ABI return Machine_Code.ABI_Kind
     with Global => (Input => Backend_State);
   --  Which ABI this process is running under. Decided at elaboration from
   --  the target name, which is sound because the code is generated then too.

   ------------
   -- Stacks --
   ------------

   procedure Allocate_Stack
     (Size : Stack_Count;
      S    : out Stack_Handle;
      Ok   : out Boolean)
     with Global => null,
          Pre    => Size >= Min_Stack_Size,
          Post => (if Ok then Is_Allocated (S)
                             and then FTAL.Is_Live (Region_Of (S))
                             and then not Region_Of (S).Foreign
                    else not Is_Allocated (S));

   procedure Free_Stack (S : in out Stack_Handle)
     with Global => null,
          Post   => not Is_Allocated (S);

   --------------
   -- Contexts --
   --------------

   procedure Make_Context
     (Ctx    : in out Context;
      Stack  : Stack_Handle;
      Start  : Body_Entry;
      Handle : System.Address)
     with Global => (Input => Backend_State),
          Pre  => Backend_Ready
                    and then Is_Allocated (Stack)
                    and then Start /= null,
          Post => FTAL.Well_Typed (Model (Ctx))
                    and then Model (Ctx).Stack = Region_Of (Stack);
   --  Lay down an initial frame on Stack so that switching into Ctx enters
   --  Start with Handle as its argument. The frame is built to satisfy
   --  FTAL.Well_Typed, so a never-run context and a suspended one are
   --  indistinguishable to Switch.

   procedure Adopt_Current (Ctx : in out Context)
     with Global => (Input => Backend_State),
          Pre  => Backend_Ready,
          Post => FTAL.Well_Typed (Model (Ctx))
                    and then Model (Ctx).Stack.Foreign;
   --  Claim the caller's own (OS-provided) stack as a context. Used once, for
   --  the main context, which the operating system made rather than us. The
   --  register fields are filled in by the first Switch out of it; what this
   --  establishes is the ownership fact, not the register contents.

   procedure Reset (Ctx : in out Context)
     with Global => null,
          Post   => not FTAL.Well_Typed (Model (Ctx));
   --  Return Ctx to the unmade state, so it cannot be switched to.

   procedure Switch (From : in out Context; To : Context)
     with Global => (Input => Backend_State),
          Pre  => Backend_Ready
                    and then FTAL.Switch_Pre (Model (From), Model (To)),
          Post => FTAL.Switch_Post (Model (From), Model (To));
   --  Save the running state into From, install To, and continue there.
   --  Returns when someone switches back into From.
   --
   --  TRUSTED. The body is the generated machine code. What discharges the
   --  postcondition's claim that From's saved instruction pointer is a real
   --  instruction boundary is Machine_Code.Resume_Point_Correct, which *is*
   --  proved -- see README.md.

private
   pragma SPARK_Mode (Off);

   use type Machine_Code.ABI_Kind;

   --  The saved-register buffer. Its layout is pinned to the offsets the
   --  generated code indexes through, so the two cannot drift apart; the
   --  representation clause below is checked against Machine_Code.Layout by
   --  the assertions in the body.

   type Word is mod 2 ** 64 with Size => 64;
   type XMM_Save is array (0 .. 19) of Word;   --  XMM6-XMM15, 16 bytes each

   type Context is limited record
      RIP, RSP, RBP, RBX, R12, R13, R14, R15 : Word := 0;
      RDI, RSI                               : Word := 0;
      XMM                                    : XMM_Save := (others => 0);
      Fiber_Storage                          : Word := 0;
      Dealloc_Stack                          : Word := 0;
      Stack_Limit                            : Word := 0;
      Stack_Base                             : Word := 0;

      --  Bookkeeping, invisible to the generated code because it sits past
      --  Layout.Win64_Size.
      Made        : Boolean := False;
      Is_Foreign  : Boolean := False;
      Region_Base : Word    := 0;
      Region_Size : Word    := 0;
   end record
   with Alignment => 16;

   for Context use record
      RIP           at Machine_Code.Layout.RIP           range 0 .. 63;
      RSP           at Machine_Code.Layout.RSP           range 0 .. 63;
      RBP           at Machine_Code.Layout.RBP           range 0 .. 63;
      RBX           at Machine_Code.Layout.RBX           range 0 .. 63;
      R12           at Machine_Code.Layout.R12           range 0 .. 63;
      R13           at Machine_Code.Layout.R13           range 0 .. 63;
      R14           at Machine_Code.Layout.R14           range 0 .. 63;
      R15           at Machine_Code.Layout.R15           range 0 .. 63;
      RDI           at Machine_Code.Layout.RDI           range 0 .. 63;
      RSI           at Machine_Code.Layout.RSI           range 0 .. 63;
      XMM           at Machine_Code.Layout.XMM
        range 0 .. 20 * 64 - 1;
      Fiber_Storage at Machine_Code.Layout.Fiber_Storage range 0 .. 63;
      Dealloc_Stack at Machine_Code.Layout.Dealloc_Stack range 0 .. 63;
      Stack_Limit   at Machine_Code.Layout.Stack_Limit   range 0 .. 63;
      Stack_Base    at Machine_Code.Layout.Stack_Base    range 0 .. 63;

      --  Placed explicitly past Layout.Win64_Size so that the generated code,
      --  which indexes the buffer only through the offsets above, can never
      --  reach them.
      Made        at Machine_Code.Layout.Win64_Size      range 0 .. 7;
      Is_Foreign  at Machine_Code.Layout.Win64_Size + 1  range 0 .. 7;
      Region_Base at Machine_Code.Layout.Win64_Size + 8  range 0 .. 63;
      Region_Size at Machine_Code.Layout.Win64_Size + 16 range 0 .. 63;
   end record;

   type Stack_Storage is array (Stack_Count range <>) of Word;
   type Stack_Storage_Access is access Stack_Storage;

   type Stack_Handle is record
      Mem  : Stack_Storage_Access := null;
      Base : Word                 := 0;
      Size : Word                 := 0;
   end record;

end Minicoro.Contexts;
