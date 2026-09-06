--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A small, verified x86-64 instruction encoder.
--
--  This package follows Rutter, "Using a high level language as a cross
--  assembler" (ACM SIGPLAN Notices 16(2), 1981): rather than shipping the
--  context-switch routine as opaque assembler text or as a hand-transcribed
--  table of bytes, the routine is *built* here by Ada functions. The machine
--  code is ordinary data, so GNATprove can reason about it.
--
--  minicoro's own Win64 backend ships the switch routine as a literal byte
--  array beginning with
--
--      48 8d 05 3e 01 00 00     lea 0x13e(%rip), %rax
--
--  The 0x13e is a hand-computed distance to the trailing `ret`; it is the
--  address the routine saves as the coroutine's resume point. If it is off by
--  even one, control lands in the middle of an instruction. Here that number
--  is not written down at all: it is computed from the assembled listing by
--  Switch_Displacement, and Resume_Point_Correct states -- and GNATprove
--  discharges -- that it lands exactly on the `ret`.

package Minicoro.Machine_Code with SPARK_Mode is

   -----------------
   -- Instruction --
   -----------------

   Max_Insn_Length : constant := 12;

   subtype Insn_Length is Natural range 1 .. Max_Insn_Length;
   type Insn_Bytes is array (1 .. Max_Insn_Length) of Byte;

   type Insn is record
      Length : Insn_Length := 1;
      Bytes  : Insn_Bytes  := (others => 16#90#);  --  nop
   end record;

   --  Listings and code blocks are bounded. Without an upper bound on the
   --  index, contracts such as Offset_Of's would themselves overflow
   --  (Positive'Last * Max_Insn_Length does not fit), and the arithmetic
   --  could not be discharged. The bounds are far above anything the switch
   --  routine needs.

   Max_Listing : constant := 4_096;
   Max_Code    : constant := Max_Listing * Max_Insn_Length;

   subtype Listing_Index is Positive range 1 .. Max_Listing;
   type Insn_Array is array (Listing_Index range <>) of Insn;

   subtype Code_Index is Positive range 1 .. Max_Code;
   type Code is array (Code_Index range <>) of Byte;

   ---------------
   -- Registers --
   ---------------

   --  Pos is the architectural register number, so encoding is direct.

   type GP_Reg is
     (RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI,
      R8,  R9,  R10, R11, R12, R13, R14, R15);

   type XMM_Reg is
     (XMM0, XMM1, XMM2,  XMM3,  XMM4,  XMM5,  XMM6,  XMM7,
      XMM8, XMM9, XMM10, XMM11, XMM12, XMM13, XMM14, XMM15);

   type Displacement is range -2 ** 31 .. 2 ** 31 - 1;

   --  RSP and R12 encode as "SIB follows" in the r/m field, so a base-plus-
   --  displacement operand on them needs an extra byte. The switch routine
   --  never uses them as a base, so the encoders exclude them rather than
   --  carry an unexercised code path.
   subtype Base_Reg is GP_Reg with
     Static_Predicate => Base_Reg not in RSP | R12;

   --------------
   -- Encoders --
   --------------

   function Mov_Store (Base : Base_Reg; Disp : Displacement; Src : GP_Reg)
      return Insn;
   --  mov %Src, Disp(%Base)                                  [REX.W 89 /r]

   function Mov_Load (Dst : GP_Reg; Base : Base_Reg; Disp : Displacement)
      return Insn;
   --  mov Disp(%Base), %Dst                                  [REX.W 8B /r]

   function Mov_Reg (Dst, Src : GP_Reg) return Insn
     with Post => Mov_Reg'Result.Length = 3;
   --  mov %Src, %Dst                                         [REX.W 89 /r]

   function Mov_GS_Load (Dst : GP_Reg; Disp : Displacement) return Insn
     with Post => Mov_GS_Load'Result.Length = 9;
   --  mov %gs:Disp, %Dst                              [65 REX.W 8B /r SIB]
   --  Reads the Win64 Thread Environment Block.

   function Movups_Store
     (Base : Base_Reg; Disp : Displacement; Src : XMM_Reg) return Insn;
   --  movups %Src, Disp(%Base)                                  [0F 11 /r]

   function Movups_Load
     (Dst : XMM_Reg; Base : Base_Reg; Disp : Displacement) return Insn;
   --  movups Disp(%Base), %Dst                                  [0F 10 /r]

   function Lea_RIP (Dst : GP_Reg; Disp : Displacement) return Insn
     with Post => Lea_RIP'Result.Length = 7;
   --  lea Disp(%rip), %Dst                                   [REX.W 8D /r]
   --
   --  The postcondition is what makes single-pass assembly sound: a
   --  RIP-relative LEA always uses mod=00 rm=101 with a full 32-bit
   --  displacement, so its length does not depend on Disp. Patching the
   --  displacement after laying out the listing therefore cannot move
   --  anything.

   function Jmp_Indirect (Base : Base_Reg; Disp : Displacement) return Insn;
   --  jmp *Disp(%Base)                                            [FF /4]

   function Jmp_Reg (Target : GP_Reg) return Insn
     with Post => Jmp_Reg'Result.Length = 3;
   --  jmp *%Target                                                [FF /4]

   function Ret return Insn with Post => Ret'Result.Length = 1;
   function Nop return Insn with Post => Nop'Result.Length = 1;

   ------------------------
   -- Listings and sizes --
   ------------------------

   --  Listings are non-empty throughout: an empty one has no meaning here,
   --  and excluding it keeps L'Last + 1 inside Positive.
   subtype Listing is Insn_Array with
     Dynamic_Predicate => Listing'First = 1 and then Listing'Last >= 1;

   function Offset_Of (L : Listing; Index : Positive) return Natural with
     Subprogram_Variant => (Decreases => Index),
     Pre  => Index in 1 .. L'Last + 1,
     Post => Offset_Of'Result <= (Index - 1) * Max_Insn_Length;
   --  0-based byte offset at which instruction Index begins.

   function Total_Length (L : Listing) return Natural with
     Post => Total_Length'Result = Offset_Of (L, L'Last + 1)
               and then Total_Length'Result <= L'Last * Max_Insn_Length;

   procedure Lemma_Offset_Monotone (L : Listing; Index : Positive) with
     Ghost,
     Subprogram_Variant => (Decreases => L'Last + 1 - Index),
     Pre  => Index in 1 .. L'Last + 1,
     Post => Offset_Of (L, Index) <= Total_Length (L);
   --  The recursion walks *up* towards L'Last + 1, so the measure that
   --  decreases is the distance remaining, not the index.

   function Assemble (L : Listing) return Code with
     Post => Assemble'Result'First = 1
               and then Assemble'Result'Length = Total_Length (L);

   ---------------------------------
   -- Context buffer field layout --
   ---------------------------------

   --  Byte offsets within the saved-context buffer. These constants are the
   --  single source of truth: Minicoro.Contexts pins its record layout to
   --  them with a representation clause, and the encoders below index the
   --  buffer through them, so the generated code and the Ada record cannot
   --  drift apart.

   package Layout is
      RIP : constant := 0;
      RSP : constant := 8;
      RBP : constant := 16;
      RBX : constant := 24;
      R12 : constant := 32;
      R13 : constant := 40;
      R14 : constant := 48;
      R15 : constant := 56;

      --  System V AMD64 saves nothing further.
      SysV_Size : constant := 64;

      --  Win64 additionally preserves RDI/RSI, XMM6-XMM15 and four fields of
      --  the Thread Environment Block.
      RDI : constant := 64;
      RSI : constant := 72;
      XMM : constant := 80;   --  XMM6 .. XMM15, 16 bytes each

      Fiber_Storage : constant := 240;
      Dealloc_Stack : constant := 248;
      Stack_Limit   : constant := 256;
      Stack_Base    : constant := 264;

      Win64_Size : constant := 272;

      --  TEB field offsets, relative to %gs.
      TEB_Self          : constant := 16#30#;
      TEB_Stack_Base    : constant := 16#08#;
      TEB_Stack_Limit   : constant := 16#10#;
      TEB_Dealloc_Stack : constant := 16#1478#;
      TEB_Fiber_Storage : constant := 16#20#;
   end Layout;

   ------------------------
   --  The switch routine --
   ------------------------

   --  void switch (Context* from, Context* to)
   --
   --  Saves the callee-saved state of the running context into `from`,
   --  installs `to`, and jumps to the instruction pointer `to` recorded. The
   --  value saved as `from`'s instruction pointer is the address of the
   --  trailing `ret`, so a later switch back into `from` returns to this
   --  routine's caller.
   --
   --  Argument registers follow the platform ABI: RCX/RDX on Win64,
   --  RDI/RSI on System V.

   type ABI_Kind is (Win64, SysV);

   function Ret_Position (ABI : ABI_Kind) return Positive;
   --  Index of the trailing RET within Switch_Template.

   function Switch_Template (ABI : ABI_Kind) return Insn_Array with
     Post => Switch_Template'Result'First = 1
               and then Switch_Template'Result'Last = Ret_Position (ABI)
               and then Switch_Template'Result (1).Length = 7;
   --  The listing with the LEA displacement left at zero. Instruction 1 is
   --  always the LEA and the last instruction is always the RET.

   function Switch_Displacement (ABI : ABI_Kind) return Displacement with
     Post => Switch_Displacement'Result
               = Displacement
                   (Offset_Of (Switch_Template (ABI), Ret_Position (ABI))) - 7;
   --  Distance from the end of the LEA to the RET: what the LEA must add to
   --  RIP. minicoro writes 0x13e here by hand; we derive it.

   function Decode_Disp32 (C : Code; At_Offset : Natural) return Displacement
   is
     (Displacement (C (At_Offset + 1))
        + Displacement (C (At_Offset + 2)) * 256
        + Displacement (C (At_Offset + 3)) * 65_536
        + (if C (At_Offset + 4) < 128
           then Displacement (C (At_Offset + 4)) * 16_777_216
           else (Displacement (C (At_Offset + 4)) - 256) * 16_777_216))
     with Pre => C'First = 1
                   and then C'Length >= 4
                   and then At_Offset <= C'Length - 4;
   --  Decode a little-endian signed 32-bit field, as the CPU would: the low
   --  three bytes contribute their magnitude and the top byte its two's
   --  complement value.
   --
   --  Written as an expression function on purpose. As an opaque function it
   --  would tell the prover nothing, and the round trip in Switch_Code's
   --  postcondition -- that the bytes we patch in decode back to the
   --  displacement we computed -- would be unprovable.

   function Switch_Code (ABI : ABI_Kind) return Code with
     Post => Switch_Code'Result'First = 1
               and then Switch_Code'Result'Length
                          = Total_Length (Switch_Template (ABI))
               and then Switch_Code'Result'Length >= 7
               and then Decode_Disp32 (Switch_Code'Result, 3)
                          = Switch_Displacement (ABI);
   --  Switch_Template assembled, with the LEA's displacement field patched to
   --  Switch_Displacement. Offset 3 is where that field starts (REX.W 8D
   --  ModRM = 3 bytes ahead of it).

   function Resume_Point_Correct (ABI : ABI_Kind) return Boolean is
     (7 + Decode_Disp32 (Switch_Code (ABI), 3)
        = Displacement
            (Offset_Of (Switch_Template (ABI), Ret_Position (ABI))));
   --  THEOREM. At run time the LEA computes RIP + disp32, where RIP already
   --  points just past the 7-byte LEA. This says that address is exactly
   --  where the RET sits -- i.e. the saved resume point is a real instruction
   --  boundary, and resuming this context returns to switch's caller.

   ------------------------
   --  The trampoline    --
   ------------------------

   function Wrap_Main_Code (ABI : ABI_Kind) return Code with
     Post => Wrap_Main_Code'Result'First = 1;
   --  Entry trampoline for a freshly made context: moves the coroutine handle
   --  parked in a callee-saved register into the ABI's first argument
   --  register and jumps to the coroutine body. It is never returned from.

end Minicoro.Machine_Code;
