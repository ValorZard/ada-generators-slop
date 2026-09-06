--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  This body is SPARK except for the nested package Machine and the four
--  subprograms marked SPARK_Mode (Off) below. Those are the trusted base:
--  they convert between addresses and code pointers, and they call the
--  generated switch routine, which changes the stack out from under the
--  caller. No dialect of Ada can describe that.

with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;

with Minicoro.Code_Page;

package body Minicoro.Contexts with
  SPARK_Mode,
  Refined_State => (Backend_State => (Area, Do_Switch, Wrap_At, Ready))
is

   use type System.Address;

   type Switch_Proc is access procedure (From, To : System.Address)
     with Convention => C;

   --  The constituents of Backend_State. They are declared here, ahead of
   --  every body in this package, because a Refined_State constituent must
   --  precede the first body that freezes the contract.

   Area      : Code_Page.Page;
   Do_Switch : Switch_Proc    := null;
   Wrap_At   : System.Address := System.Null_Address;
   Ready     : Boolean        := False;

   Switch_At : constant Natural := 0;

   --  Guard against the record layout and the generated code disagreeing.
   --  Both derive from Machine_Code.Layout, so these can only fire if the
   --  compiler declined the representation clause. They were runtime
   --  assertions in the package's elaboration part; as compile-time checks
   --  they say the same thing earlier and leave GNATprove no verification
   --  condition about 'Size, which it cannot evaluate.

   pragma Compile_Time_Error
     (Context'Size < Machine_Code.Layout.Win64_Size * 8,
      "Context is smaller than the buffer the generated code indexes");
   pragma Compile_Time_Error
     (Word'Size /= 64, "Context fields must be 64 bits wide");

   -------------
   -- Machine --
   -------------

   --  TRUSTED. Everything SPARK cannot express, in one place, so that the
   --  rest of this body can be analysed. Each operation is small enough to
   --  read against its declaration.

   package Machine with SPARK_Mode => On is

      function To_Switch (A : System.Address) return Switch_Proc;
      --  Reinterpret a byte in the sealed code page as the switch routine.
      --  SPARK forbids Unchecked_Conversion to an access-to-subprogram type:
      --  it has no way to know the bytes are a subprogram at all.

      function Entry_Word (E : Body_Entry) return Word;
      --  The address of a coroutine body, as a machine word for the
      --  generated code to load into R12. SPARK forbids Unchecked_Conversion
      --  out of a type with access subcomponents.

      procedure Call_Switch (From : in out Context; To : Context);
      --  Enter the generated routine. This is the one operation in the
      --  library that does not return to its caller in the ordinary sense.

   end Machine;

   function To_Word is new Ada.Unchecked_Conversion (System.Address, Word);
   function To_Addr is new Ada.Unchecked_Conversion (Word, System.Address);

   procedure Free_Storage is new Ada.Unchecked_Deallocation
     (Stack_Storage, Stack_Storage_Access);

   ------------------
   -- ABI decision --
   ------------------

   function Contains (Haystack, Needle : String) return Boolean
     with Global => null;
   function Detect_ABI return Machine_Code.ABI_Kind
     with Global => null;

   function Contains (Haystack, Needle : String) return Boolean is
   begin
      if Needle'Length = 0 then
         return True;
      elsif Needle'Length > Haystack'Length then
         return False;
      end if;

      --  The obvious loop bound, Haystack'Last - Needle'Length + 1, is not
      --  provably in range: nothing stops Haystack'Last from being
      --  Positive'Last. Running I over the whole string and testing whether
      --  Needle still fits keeps every intermediate inside Positive.
      for I in Haystack'First .. Haystack'Last loop
         if Natural (Haystack'Last - I) + 1 >= Needle'Length
           and then Haystack (I .. I + (Needle'Length - 1)) = Needle
         then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Detect_ABI return Machine_Code.ABI_Kind is
      T : constant String := Standard'Target_Name;
   begin
      --  Deciding this at elaboration is sound because the code is generated
      --  at elaboration too: the assembler and its target agree by
      --  construction. It must nonetheless match the calling convention the
      --  compiler uses for Switch_Proc above, which is why it keys off the
      --  compiler's own target name.
      if Contains (T, "mingw")
        or else Contains (T, "windows")
        or else Contains (T, "cygwin")
      then
         return Machine_Code.Win64;
      else
         return Machine_Code.SysV;
      end if;
   end Detect_ABI;

   ABI : constant Machine_Code.ABI_Kind := Detect_ABI;

   function Target_ABI return Machine_Code.ABI_Kind is (ABI);

   function Backend_Ready return Boolean is (Ready);

   -------------
   -- Machine --
   -------------

   package body Machine with SPARK_Mode => Off is

      function To_Switch_Conv is new Ada.Unchecked_Conversion
        (System.Address, Switch_Proc);

      function Entry_Conv is new Ada.Unchecked_Conversion (Body_Entry, Word);

      function To_Switch (A : System.Address) return Switch_Proc is
        (To_Switch_Conv (A));

      function Entry_Word (E : Body_Entry) return Word is (Entry_Conv (E));

      procedure Call_Switch (From : in out Context; To : Context) is
      begin
         --  The generated routine saves the live registers into From,
         --  installs To, and jumps to To.RIP. Control reappears here only
         --  when some other context switches back into From -- at which
         --  point From.RIP was the address of the `ret` that
         --  Machine_Code.Resume_Point_Correct pins down, and that `ret`
         --  returns to this very call.
         Do_Switch (From'Address, To'Address);
      end Call_Switch;

   end Machine;

   ------------------------
   -- Initialize_Backend --
   ------------------------

   procedure Initialize_Backend (Ok : out Boolean) is
      SC : constant Machine_Code.Code := Machine_Code.Switch_Code (ABI);
      WC : constant Machine_Code.Code := Machine_Code.Wrap_Main_Code (ABI);

      --  Start the trampoline on a fresh 16-byte boundary.
      Wrap_Off : constant Natural := ((SC'Length + 15) / 16) * 16;
      Total    : constant Positive := Wrap_Off + WC'Length;
   begin
      if Ready then
         Ok := True;
         return;
      end if;

      Code_Page.Allocate (Area, Total, Ok);
      if not Ok then
         return;
      end if;

      Code_Page.Write (Area, Switch_At, SC);
      Code_Page.Write (Area, Wrap_Off, WC);

      Code_Page.Seal (Area, Ok);
      if not Ok then
         Code_Page.Free (Area);
         return;
      end if;

      Do_Switch := Machine.To_Switch (Code_Page.Address_At (Area, Switch_At));
      Wrap_At   := Code_Page.Address_At (Area, Wrap_Off);
      Ready     := True;
      Ok        := True;
   end Initialize_Backend;

   -----------------
   -- Ghost model --
   -----------------

   function Region_Of (S : Stack_Handle) return FTAL.Stack_Region is
     ((Base    => FTAL.Word (S.Base),
       Size    => FTAL.Word (S.Size),
       Foreign => False));

   function Is_Allocated (S : Stack_Handle) return Boolean is (S.Mem /= null);

   function Model (C : Context) return FTAL.Context_Model is
     ((Regs  =>
         [FTAL.RIP => (if C.Made then FTAL.Code_Pointer else FTAL.Junk),
          FTAL.RSP => (if C.Made then FTAL.Stack_Pointer else FTAL.Junk),
          FTAL.R13 => (if C.Made then FTAL.Handle else FTAL.Junk),
          others   => FTAL.Scalar],
       SP    => FTAL.Word (C.RSP),
       PC    => FTAL.Word (C.RIP),
       Stack => (Base    => FTAL.Word (C.Region_Base),
                 Size    => FTAL.Word (C.Region_Size),
                 Foreign => C.Is_Foreign),
       Made  => C.Made));

   --------------------
   -- Allocate_Stack --
   --------------------

   procedure Allocate_Stack
     (Size : Stack_Count;
      S    : out Stack_Handle;
      Ok   : out Boolean)
   is
      pragma SPARK_Mode (Off);
      --  Off for two reasons that are the same reason twice: the handler for
      --  Storage_Error (SPARK does not model allocation failure) and
      --  'Address on the allocated block (SPARK has no address arithmetic).

      --  Round up to a whole number of 16-byte units so that the top of the
      --  stack is 16-aligned, as Make_Context's frame arithmetic assumes.
      Units : constant Stack_Count := ((Size + 15) / 16) * 2;
   begin
      S.Mem := new Stack_Storage (1 .. Units);
      S.Base := To_Word (S.Mem (1)'Address);
      S.Size := Word (Units) * 8;
      Ok := True;
   exception
      when Storage_Error =>
         S := (Mem => null, Base => 0, Size => 0);
         Ok := False;
   end Allocate_Stack;

   ----------------
   -- Free_Stack --
   ----------------

   procedure Free_Stack (S : in out Stack_Handle) is
   begin
      if S.Mem /= null then
         Free_Storage (S.Mem);
      end if;
      S := (Mem => null, Base => 0, Size => 0);
   end Free_Stack;

   ------------------
   -- Make_Context --
   ------------------

   procedure Make_Context
     (Ctx    : in out Context;
      Stack  : Stack_Handle;
      Start  : Body_Entry;
      Handle : System.Address)
   is
      pragma SPARK_Mode (Off);
      --  Off because of Poison: writing a word at a computed address is an
      --  overlay SPARK will not model.

      --  Win64 requires 32 bytes of shadow space above the frame; System V
      --  requires a 128-byte red zone below it. Both are carved off the top
      --  before anything else, exactly as minicoro does.
      Reserve : constant Word :=
        (if ABI = Machine_Code.Win64 then 32 else 128);

      Top : constant Word := (Stack.Base + Stack.Size - Reserve) and not 15;

      --  One slot below the aligned top holds a poison return address. It is
      --  never used: the trampoline tail-jumps and the body never returns.
      --  Its purpose is to leave RSP congruent to 8 mod 16, which is what the
      --  ABI guarantees on entry to a called subprogram -- so the body sees a
      --  correctly aligned frame.
      SP : constant Word := Top - 8;

      Poison : Word with Import, Address => To_Addr (SP);
   begin
      Poison := 16#DEAD_DEAD_DEAD_DEAD#;

      Ctx.RIP := To_Word (Wrap_At);          --  trampoline
      Ctx.RSP := SP;
      Ctx.R12 := Machine.Entry_Word (Start); --  body, jumped to by trampoline
      Ctx.R13 := To_Word (Handle);           --  its argument

      Ctx.RBP := 0;
      Ctx.RBX := 0;
      Ctx.R14 := 0;
      Ctx.R15 := 0;
      Ctx.RDI := 0;
      Ctx.RSI := 0;
      Ctx.XMM := [others => 0];

      --  Win64 keeps the running stack's bounds in the Thread Environment
      --  Block; the switch routine swaps them, so they must describe this
      --  stack before the first entry.
      Ctx.Stack_Base    := Top;
      Ctx.Stack_Limit   := Stack.Base;
      Ctx.Dealloc_Stack := Stack.Base;
      Ctx.Fiber_Storage := 0;

      Ctx.Made        := True;
      Ctx.Is_Foreign  := False;
      Ctx.Region_Base := Stack.Base;
      Ctx.Region_Size := Stack.Size;
   end Make_Context;

   -------------------
   -- Adopt_Current --
   -------------------

   procedure Adopt_Current (Ctx : in out Context) is
      pragma SPARK_Mode (Off);
      --  Off because the whole point of Anchor is to observe where the
      --  caller's own stack frame is, and SPARK has neither a volatile local
      --  nor 'Address to say that with.

      Anchor : Word with Volatile;
      --  Its address is on the caller's stack, which is the region being
      --  adopted. We record it only as evidence that the region exists; the
      --  model marks the region Foreign precisely because we cannot know its
      --  bounds.
   begin
      Anchor := 0;

      Ctx.Made        := True;
      Ctx.Is_Foreign  := True;
      Ctx.Region_Base := To_Word (Anchor'Address);
      Ctx.Region_Size := 0;

      --  These two are placeholders, not a resumable machine state: the real
      --  values are written by the switch routine the first time control
      --  leaves this context. They are set to something non-null only so the
      --  buffer satisfies FTAL.Well_Typed, which Switch requires of its
      --  target.
      --
      --  That is sound because an adopted context is always a switch *source*
      --  before it is ever a target: it describes the stack we are running on
      --  right now, so the only way to reach a point where something could
      --  switch into it is to have switched out of it first. Adopting a
      --  context and then entering it without leaving it would jump to the
      --  trampoline on a stack that has no frame -- so do not do that.
      Ctx.RIP := To_Word (Wrap_At);
      Ctx.RSP := Ctx.Region_Base;
   end Adopt_Current;

   -----------
   -- Reset --
   -----------

   procedure Reset (Ctx : in out Context) is
   begin
      Ctx.Made        := False;
      Ctx.Is_Foreign  := False;
      Ctx.Region_Base := 0;
      Ctx.Region_Size := 0;
      Ctx.RIP         := 0;
      Ctx.RSP         := 0;
   end Reset;

   ------------
   -- Switch --
   ------------

   procedure Switch (From : in out Context; To : Context) is
      pragma SPARK_Mode (Off);
      --  TRUSTED, and irreducibly so. Machine.Call_Switch does not return
      --  here in the sense SPARK understands "return": it leaves on one stack
      --  and comes back on another, having run arbitrary code in between.
   begin
      Machine.Call_Switch (From, To);
   end Switch;

end Minicoro.Contexts;
