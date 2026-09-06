--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

package body Minicoro.Machine_Code with SPARK_Mode is

   type U32 is mod 2 ** 32;

   subtype Reg_Num is Natural range 0 .. 15;

   --  ModRM "mod" field for a base+displacement memory operand.
   type Disp_Mode is (Mod0, Mod1, Mod2);

   ---------------
   -- Utilities --
   ---------------

   function Num (R : GP_Reg) return Reg_Num is (GP_Reg'Pos (R));
   function Num (R : XMM_Reg) return Reg_Num is (XMM_Reg'Pos (R));

   function Low3 (N : Reg_Num) return Natural is (N mod 8);
   function High (N : Reg_Num) return Boolean is (N >= 8);

   function REX (W, R, X, B : Boolean) return Byte is
     (16#40#
        + (if W then 8 else 0)
        + (if R then 4 else 0)
        + (if X then 2 else 0)
        + (if B then 1 else 0));

   function Mod_RM (M : Natural; Reg, RM : Natural) return Byte is
     (Byte (M * 64 + Low3 (Reg) * 8 + Low3 (RM)))
   with Pre => M <= 3 and then Reg <= 15 and then RM <= 15;

   function Mode_Of (Base : Base_Reg; Disp : Displacement) return Disp_Mode is
     (if Disp = 0 and then Base not in RBP | R13 then Mod0
      elsif Disp in -128 .. 127 then Mod1
      else Mod2);
   --  RBP and R13 cannot use mod=00: that encoding means RIP-relative, so a
   --  zero displacement on them must still be spelled out.

   function Disp_Size (M : Disp_Mode) return Natural is
     (case M is when Mod0 => 0, when Mod1 => 1, when Mod2 => 4);

   function Mod_Bits (M : Disp_Mode) return Natural is
     (case M is when Mod0 => 0, when Mod1 => 1, when Mod2 => 2);

   function To_U32 (D : Displacement) return U32 is
     (U32 (Long_Long_Integer (D) mod 2 ** 32));

   function Byte_Of (V : U32; K : Natural) return Byte is
     (Byte ((V / (2 ** (8 * K))) mod 256))
   with Pre => K <= 3;

   --------------
   -- Put_Disp --
   --------------

   procedure Put_Disp
     (B     : in out Insn_Bytes;
      Start : Insn_Length;
      D     : Displacement;
      M     : Disp_Mode)
   with Pre => Start + Disp_Size (M) - 1 <= Max_Insn_Length
                 and then (if M = Mod1 then D in -128 .. 127);
   --  Append the displacement bytes for mode M at B (Start ..).

   procedure Put_Disp
     (B     : in out Insn_Bytes;
      Start : Insn_Length;
      D     : Displacement;
      M     : Disp_Mode)
   is
      V : constant U32 := To_U32 (D);
   begin
      case M is
         when Mod0 =>
            null;
         when Mod1 =>
            B (Start) := Byte_Of (V, 0);
         when Mod2 =>
            B (Start)     := Byte_Of (V, 0);
            B (Start + 1) := Byte_Of (V, 1);
            B (Start + 2) := Byte_Of (V, 2);
            B (Start + 3) := Byte_Of (V, 3);
      end case;
   end Put_Disp;

   ---------------
   -- Mov_Store --
   ---------------

   function Mov_Store (Base : Base_Reg; Disp : Displacement; Src : GP_Reg)
      return Insn
   is
      M : constant Disp_Mode := Mode_Of (Base, Disp);
      R : Insn;
   begin
      R.Bytes (1) := REX (True, High (Num (Src)), False, High (Num (Base)));
      R.Bytes (2) := 16#89#;
      R.Bytes (3) := Mod_RM (Mod_Bits (M), Num (Src), Num (Base));
      Put_Disp (R.Bytes, 4, Disp, M);
      R.Length := 3 + Disp_Size (M);
      return R;
   end Mov_Store;

   --------------
   -- Mov_Load --
   --------------

   function Mov_Load (Dst : GP_Reg; Base : Base_Reg; Disp : Displacement)
      return Insn
   is
      M : constant Disp_Mode := Mode_Of (Base, Disp);
      R : Insn;
   begin
      R.Bytes (1) := REX (True, High (Num (Dst)), False, High (Num (Base)));
      R.Bytes (2) := 16#8B#;
      R.Bytes (3) := Mod_RM (Mod_Bits (M), Num (Dst), Num (Base));
      Put_Disp (R.Bytes, 4, Disp, M);
      R.Length := 3 + Disp_Size (M);
      return R;
   end Mov_Load;

   -------------
   -- Mov_Reg --
   -------------

   function Mov_Reg (Dst, Src : GP_Reg) return Insn is
      R : Insn;
   begin
      R.Bytes (1) := REX (True, High (Num (Src)), False, High (Num (Dst)));
      R.Bytes (2) := 16#89#;
      R.Bytes (3) := Mod_RM (3, Num (Src), Num (Dst));
      R.Length := 3;
      return R;
   end Mov_Reg;

   -----------------
   -- Mov_GS_Load --
   -----------------

   function Mov_GS_Load (Dst : GP_Reg; Disp : Displacement) return Insn is
      R : Insn;
   begin
      R.Bytes (1) := 16#65#;                       --  GS segment override
      R.Bytes (2) := REX (True, High (Num (Dst)), False, False);
      R.Bytes (3) := 16#8B#;
      --  mod=00 with rm=100 selects a SIB byte; SIB index=100 (none) and
      --  base=101 together mean "disp32, no base register".
      R.Bytes (4) := Mod_RM (0, Num (Dst), 4);
      R.Bytes (5) := 16#25#;
      Put_Disp (R.Bytes, 6, Disp, Mod2);
      R.Length := 9;
      return R;
   end Mov_GS_Load;

   ------------------
   -- Movups_Store --
   ------------------

   function Movups_Store
     (Base : Base_Reg; Disp : Displacement; Src : XMM_Reg) return Insn
   is
      M      : constant Disp_Mode := Mode_Of (Base, Disp);
      Need_R : constant Boolean := High (Num (Src));
      Need_B : constant Boolean := High (Num (Base));
      R      : Insn;
      P      : Natural := 0;
   begin
      if Need_R or else Need_B then
         P := 1;
         R.Bytes (1) := REX (False, Need_R, False, Need_B);
      end if;
      R.Bytes (P + 1) := 16#0F#;
      R.Bytes (P + 2) := 16#11#;
      R.Bytes (P + 3) := Mod_RM (Mod_Bits (M), Num (Src), Num (Base));
      Put_Disp (R.Bytes, P + 4, Disp, M);
      R.Length := P + 3 + Disp_Size (M);
      return R;
   end Movups_Store;

   -----------------
   -- Movups_Load --
   -----------------

   function Movups_Load
     (Dst : XMM_Reg; Base : Base_Reg; Disp : Displacement) return Insn
   is
      M      : constant Disp_Mode := Mode_Of (Base, Disp);
      Need_R : constant Boolean := High (Num (Dst));
      Need_B : constant Boolean := High (Num (Base));
      R      : Insn;
      P      : Natural := 0;
   begin
      if Need_R or else Need_B then
         P := 1;
         R.Bytes (1) := REX (False, Need_R, False, Need_B);
      end if;
      R.Bytes (P + 1) := 16#0F#;
      R.Bytes (P + 2) := 16#10#;
      R.Bytes (P + 3) := Mod_RM (Mod_Bits (M), Num (Dst), Num (Base));
      Put_Disp (R.Bytes, P + 4, Disp, M);
      R.Length := P + 3 + Disp_Size (M);
      return R;
   end Movups_Load;

   -------------
   -- Lea_RIP --
   -------------

   function Lea_RIP (Dst : GP_Reg; Disp : Displacement) return Insn is
      R : Insn;
   begin
      R.Bytes (1) := REX (True, High (Num (Dst)), False, False);
      R.Bytes (2) := 16#8D#;
      --  mod=00 with rm=101 is the RIP-relative form: always a full disp32,
      --  so the encoding is 7 bytes whatever Disp is. Lea_RIP's
      --  postcondition records that, and single-pass layout relies on it.
      R.Bytes (3) := Mod_RM (0, Num (Dst), 5);
      Put_Disp (R.Bytes, 4, Disp, Mod2);
      R.Length := 7;
      return R;
   end Lea_RIP;

   ------------------
   -- Jmp_Indirect --
   ------------------

   function Jmp_Indirect (Base : Base_Reg; Disp : Displacement) return Insn is
      M : constant Disp_Mode := Mode_Of (Base, Disp);
      R : Insn;
      P : Natural := 0;
   begin
      --  JMP r/m64 already defaults to a 64-bit operand in long mode, so
      --  REX.W is unnecessary; REX.B is still needed to reach r8-r15.
      if High (Num (Base)) then
         P := 1;
         R.Bytes (1) := REX (False, False, False, True);
      end if;
      R.Bytes (P + 1) := 16#FF#;
      R.Bytes (P + 2) := Mod_RM (Mod_Bits (M), 4, Num (Base));  --  /4
      Put_Disp (R.Bytes, P + 3, Disp, M);
      R.Length := P + 2 + Disp_Size (M);
      return R;
   end Jmp_Indirect;

   -------------
   -- Jmp_Reg --
   -------------

   function Jmp_Reg (Target : GP_Reg) return Insn is
      R : Insn;
   begin
      --  A REX prefix is emitted unconditionally, even when no bit of it is
      --  set: a bare 0x40 is a legal no-op prefix, and fixing the length at
      --  three bytes lets the postcondition stay unconditional.
      R.Bytes (1) := REX (False, False, False, High (Num (Target)));
      R.Bytes (2) := 16#FF#;
      R.Bytes (3) := Mod_RM (3, 4, Num (Target));               --  /4
      R.Length := 3;
      return R;
   end Jmp_Reg;

   ---------
   -- Ret --
   ---------

   function Ret return Insn is
      R : Insn;
   begin
      R.Bytes (1) := 16#C3#;
      R.Length := 1;
      return R;
   end Ret;

   ---------
   -- Nop --
   ---------

   function Nop return Insn is
      R : Insn;
   begin
      R.Bytes (1) := 16#90#;
      R.Length := 1;
      return R;
   end Nop;

   ---------------
   -- Offset_Of --
   ---------------

   function Offset_Of (L : Listing; Index : Positive) return Natural is
     (if Index = 1 then 0
      else Offset_Of (L, Index - 1) + L (Index - 1).Length);

   ------------------
   -- Total_Length --
   ------------------

   function Total_Length (L : Listing) return Natural is
     (Offset_Of (L, L'Last + 1));

   ---------------------------
   -- Lemma_Offset_Monotone --
   ---------------------------

   procedure Lemma_Offset_Monotone (L : Listing; Index : Positive) is
   begin
      if Index = L'Last + 1 then
         return;
      end if;
      pragma Assert
        (Offset_Of (L, Index + 1) = Offset_Of (L, Index) + L (Index).Length);
      Lemma_Offset_Monotone (L, Index + 1);
   end Lemma_Offset_Monotone;

   --------------
   -- Assemble --
   --------------

   function Assemble (L : Listing) return Code is
      Size   : constant Natural := Total_Length (L);
      Result : Code (1 .. Size) := [others => 16#90#];
      Pos    : Natural := 0;
   begin
      for I in L'Range loop
         pragma Loop_Invariant (Pos = Offset_Of (L, I));

         Lemma_Offset_Monotone (L, I + 1);
         pragma Assert (Offset_Of (L, I + 1) = Pos + L (I).Length);
         pragma Assert (Pos + L (I).Length <= Size);

         for J in 1 .. L (I).Length loop
            Result (Pos + J) := L (I).Bytes (J);
         end loop;

         Pos := Pos + L (I).Length;
      end loop;
      return Result;
   end Assemble;

   ------------------
   -- Ret_Position --
   ------------------

   --  Both listings are laid out so that instruction 1 is the LEA recording
   --  the resume point and the final instruction is the RET it points at.

   Win64_Ret : constant := 59;
   SysV_Ret  : constant := 18;

   function Ret_Position (ABI : ABI_Kind) return Positive is
     (case ABI is when Win64 => Win64_Ret, when SysV => SysV_Ret);

   --------------------
   -- Win64_Template --
   --------------------

   function Win64_Template return Insn_Array with
     Post => Win64_Template'Result'First = 1
               and then Win64_Template'Result'Last = Win64_Ret
               and then Win64_Template'Result (1).Length = 7;

   function Win64_Template return Insn_Array is
      From : constant Base_Reg := RCX;   --  first argument
      To   : constant Base_Reg := RDX;   --  second argument
      L    : Insn_Array (1 .. Win64_Ret) := [others => Nop];
   begin
      --  Record the resume point. The displacement is patched in later by
      --  Switch_Code; only the length matters for layout, and Lea_RIP pins
      --  that at 7 regardless of the value.
      L (1) := Lea_RIP (RAX, 0);
      L (2) := Mov_Store (From, Layout.RIP, RAX);

      --  Save the callee-saved general registers.
      L (3) := Mov_Store (From, Layout.RSP, RSP);
      L (4) := Mov_Store (From, Layout.RBP, RBP);
      L (5) := Mov_Store (From, Layout.RBX, RBX);
      L (6) := Mov_Store (From, Layout.R12, R12);
      L (7) := Mov_Store (From, Layout.R13, R13);
      L (8) := Mov_Store (From, Layout.R14, R14);
      L (9) := Mov_Store (From, Layout.R15, R15);

      --  Win64 also treats RDI, RSI and XMM6-XMM15 as callee-saved.
      L (10) := Mov_Store (From, Layout.RDI, RDI);
      L (11) := Mov_Store (From, Layout.RSI, RSI);

      for K in 0 .. 9 loop
         pragma Loop_Invariant (L (1).Length = 7);
         L (12 + K) :=
           Movups_Store (From,
                         Displacement (Layout.XMM + 16 * K),
                         XMM_Reg'Val (XMM_Reg'Pos (XMM6) + K));
      end loop;

      --  Swap the four stack-describing fields of the Thread Environment
      --  Block. Windows consults these for guard-page stack growth and for
      --  structured exception handling, so a switch that leaves them
      --  describing the outgoing stack corrupts both.
      L (22) := Mov_GS_Load (R10, Layout.TEB_Self);

      L (23) := Mov_Load  (RAX, R10, Layout.TEB_Fiber_Storage);
      L (24) := Mov_Store (From, Layout.Fiber_Storage, RAX);
      L (25) := Mov_Load  (RAX, R10, Layout.TEB_Dealloc_Stack);
      L (26) := Mov_Store (From, Layout.Dealloc_Stack, RAX);
      L (27) := Mov_Load  (RAX, R10, Layout.TEB_Stack_Limit);
      L (28) := Mov_Store (From, Layout.Stack_Limit, RAX);
      L (29) := Mov_Load  (RAX, R10, Layout.TEB_Stack_Base);
      L (30) := Mov_Store (From, Layout.Stack_Base, RAX);

      L (31) := Mov_Load  (RAX, To, Layout.Stack_Base);
      L (32) := Mov_Store (R10, Layout.TEB_Stack_Base, RAX);
      L (33) := Mov_Load  (RAX, To, Layout.Stack_Limit);
      L (34) := Mov_Store (R10, Layout.TEB_Stack_Limit, RAX);
      L (35) := Mov_Load  (RAX, To, Layout.Dealloc_Stack);
      L (36) := Mov_Store (R10, Layout.TEB_Dealloc_Stack, RAX);
      L (37) := Mov_Load  (RAX, To, Layout.Fiber_Storage);
      L (38) := Mov_Store (R10, Layout.TEB_Fiber_Storage, RAX);

      for K in 0 .. 9 loop
         pragma Loop_Invariant (L (1).Length = 7);
         L (39 + K) :=
           Movups_Load (XMM_Reg'Val (XMM_Reg'Pos (XMM15) - K),
                        To,
                        Displacement (Layout.XMM + 16 * (9 - K)));
      end loop;

      L (49) := Mov_Load (RSI, To, Layout.RSI);
      L (50) := Mov_Load (RDI, To, Layout.RDI);

      --  Restore the incoming context, stack pointer last.
      L (51) := Mov_Load (R15, To, Layout.R15);
      L (52) := Mov_Load (R14, To, Layout.R14);
      L (53) := Mov_Load (R13, To, Layout.R13);
      L (54) := Mov_Load (R12, To, Layout.R12);
      L (55) := Mov_Load (RBX, To, Layout.RBX);
      L (56) := Mov_Load (RBP, To, Layout.RBP);
      L (57) := Mov_Load (RSP, To, Layout.RSP);

      --  Enter the incoming context at the instruction pointer it saved.
      L (58) := Jmp_Indirect (To, Layout.RIP);

      --  Not reached by falling through: this is the instruction the LEA
      --  points at, so switching back into this context returns to our
      --  caller.
      L (59) := Ret;

      return L;
   end Win64_Template;

   -------------------
   -- SysV_Template --
   -------------------

   function SysV_Template return Insn_Array with
     Post => SysV_Template'Result'First = 1
               and then SysV_Template'Result'Last = SysV_Ret
               and then SysV_Template'Result (1).Length = 7;

   function SysV_Template return Insn_Array is
      From : constant Base_Reg := RDI;   --  first argument
      To   : constant Base_Reg := RSI;   --  second argument
      L    : Insn_Array (1 .. SysV_Ret) := [others => Nop];
   begin
      L (1) := Lea_RIP (RAX, 0);
      L (2) := Mov_Store (From, Layout.RIP, RAX);

      L (3) := Mov_Store (From, Layout.RSP, RSP);
      L (4) := Mov_Store (From, Layout.RBP, RBP);
      L (5) := Mov_Store (From, Layout.RBX, RBX);
      L (6) := Mov_Store (From, Layout.R12, R12);
      L (7) := Mov_Store (From, Layout.R13, R13);
      L (8) := Mov_Store (From, Layout.R14, R14);
      L (9) := Mov_Store (From, Layout.R15, R15);

      L (10) := Mov_Load (R15, To, Layout.R15);
      L (11) := Mov_Load (R14, To, Layout.R14);
      L (12) := Mov_Load (R13, To, Layout.R13);
      L (13) := Mov_Load (R12, To, Layout.R12);
      L (14) := Mov_Load (RBX, To, Layout.RBX);
      L (15) := Mov_Load (RBP, To, Layout.RBP);
      L (16) := Mov_Load (RSP, To, Layout.RSP);

      L (17) := Jmp_Indirect (To, Layout.RIP);
      L (18) := Ret;

      return L;
   end SysV_Template;

   ---------------------
   -- Switch_Template --
   ---------------------

   function Switch_Template (ABI : ABI_Kind) return Insn_Array is
     (case ABI is
         when Win64 => Win64_Template,
         when SysV  => SysV_Template);

   -------------------------
   -- Switch_Displacement --
   -------------------------

   function Switch_Displacement (ABI : ABI_Kind) return Displacement is
     (Displacement (Offset_Of (Switch_Template (ABI), Ret_Position (ABI)))
        - 7);

   -----------------
   -- Switch_Code --
   -----------------

   function Switch_Code (ABI : ABI_Kind) return Code is
      T : constant Insn_Array := Switch_Template (ABI);
      D : constant Displacement := Switch_Displacement (ABI);
      V : constant U32 := To_U32 (D);
      R : Code := Assemble (T);
   begin
      pragma Assert (T (1).Length = 7);
      pragma Assert (Offset_Of (T, 2) = 7);
      Lemma_Offset_Monotone (T, 2);
      pragma Assert (R'Length >= 7);

      --  Patch the LEA's disp32 field. It starts three bytes into the
      --  instruction (REX.W, 8D, ModRM), i.e. at 0-based offset 3.
      R (4) := Byte_Of (V, 0);
      R (5) := Byte_Of (V, 1);
      R (6) := Byte_Of (V, 2);
      R (7) := Byte_Of (V, 3);

      --  That Decode_Disp32 (R, 3) = D -- the byte-level round trip -- is
      --  stated as this function's postcondition rather than asserted here,
      --  so it is proved once, in the place callers can rely on.
      return R;
   end Switch_Code;

   --------------------
   -- Wrap_Main_Code --
   --------------------

   function Wrap_Main_Code (ABI : ABI_Kind) return Code is
      --  Make_Context parks the coroutine handle in R13 and the body's entry
      --  point in R12. Move the handle into the ABI's first argument
      --  register and tail-jump into the body.
      Arg0 : constant GP_Reg := (if ABI = Win64 then RCX else RDI);
      L    : constant Insn_Array (1 .. 3) :=
        [1 => Mov_Reg (Arg0, R13),
         2 => Jmp_Reg (R12),
         3 => Ret];            --  unreachable; keeps the block well-formed
   begin
      return Assemble (L);
   end Wrap_Main_Code;

end Minicoro.Machine_Code;
