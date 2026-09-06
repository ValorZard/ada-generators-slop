--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A ghost typing model for saved machine contexts, after Crary, "Toward a
--  Foundational Typed Assembly Language" (POPL 2003).
--
--  FTAL's contribution is that machine states get *types*, and the safety of
--  a code block is a judgement about the register file and stack it is
--  entered with, derived from first principles rather than trusted. We cannot
--  reproduce that derivation inside SPARK -- SPARK has no semantics for
--  machine instructions -- but we can do the next most useful thing: state
--  the judgement.
--
--  Everything here is Ghost, so none of it exists at run time. Its purpose is
--  to turn "the assembly had better be entered with a sane register file"
--  from a comment into a proof obligation that GNATprove checks at every call
--  site of Minicoro.Contexts.Switch, and that appears explicitly as an
--  assumption where the trusted assembly discharges it.
--
--  See README.md, "What is proved and what is assumed".

package Minicoro.FTAL with SPARK_Mode, Ghost is

   type Word is mod 2 ** 64;

   ------------------------
   -- Value classification --
   ------------------------

   --  How a machine word in a saved context is classified. This is the
   --  coarse residue of FTAL's type structure: enough to state the
   --  invariants the context switch relies on, and no more.

   type Value_Kind is
     (Junk,           --  no guarantee whatsoever
      Code_Pointer,   --  an instruction boundary inside a known code block
      Stack_Pointer,  --  a live address inside an owned stack region
      Handle,         --  a live coroutine handle
      Scalar);        --  an ordinary value, safe to save and restore blindly

   --  The registers a context buffer preserves. Caller-saved registers do
   --  not appear: the switch routine is entitled to clobber them, which is
   --  exactly what makes it callable as an ordinary C-convention subprogram.

   type Reg_Name is
     (RIP, RSP, RBP, RBX, R12, R13, R14, R15, RDI, RSI);

   type Reg_File is array (Reg_Name) of Value_Kind;

   ------------------
   -- Stack region --
   ------------------

   --  A half-open region [Base, Base + Size). Ownership is exclusive: two
   --  live coroutines never share one.
   --
   --  Foreign marks the one region we did not allocate: the thread's own
   --  stack, on which the main context runs. We know it exists and that it
   --  is disjoint from every stack we allocate, but not where it ends, so
   --  the model deliberately carries a weaker fact about it than about ours.
   --  Being explicit about that gap is the point -- it is exactly the kind of
   --  assumption Crary's development makes you write down.

   type Stack_Region is record
      Base    : Word;
      Size    : Word;
      Foreign : Boolean;
   end record;

   Null_Region : constant Stack_Region :=
     (Base => 0, Size => 0, Foreign => False);

   function Is_Live (R : Stack_Region) return Boolean is
     (if R.Foreign then R.Base /= 0
      else R.Size >= Word (Min_Stack_Size)
             and then R.Base /= 0
             and then Word'Last - R.Size >= R.Base);
   --  Ours: non-empty, large enough to run on, not wrapping the address
   --  space. Foreign: merely known to exist.

   function In_Region (A : Word; R : Stack_Region) return Boolean is
     (Is_Live (R)
        and then (R.Foreign
                  or else (A >= R.Base and then A < R.Base + R.Size)));

   function Aligned_16 (A : Word) return Boolean is (A mod 16 = 0);

   function Disjoint (L, R : Stack_Region) return Boolean is
     (not Is_Live (L) or else not Is_Live (R)
        or else L.Foreign /= R.Foreign
        or else (not L.Foreign
                   and then not R.Foreign
                   and then (L.Base + L.Size <= R.Base
                             or else R.Base + R.Size <= L.Base)));
   --  A coroutine stack is never carved out of the thread stack, so those
   --  two are always disjoint. Two foreign regions are the *same* region,
   --  hence not disjoint -- which is what makes switching the main context
   --  to itself unprovable, as it should be.

   -----------------------
   -- The typing judgement --
   -----------------------

   --  A context is a machine state frozen mid-execution. It is well typed
   --  when resuming it cannot go wrong: control returns to a real
   --  instruction, the stack pointer addresses that context's own stack, and
   --  the preserved registers hold what the switch routine will assume.

   type Context_Model is record
      Regs  : Reg_File;
      SP    : Word;          --  value of RSP
      PC    : Word;          --  value of RIP
      Stack : Stack_Region;  --  the region SP must lie in
      Made  : Boolean;       --  Make_Context has run on this buffer
   end record;

   Unmade : constant Context_Model :=
     (Regs  => (others => Junk),
      SP    => 0,
      PC    => 0,
      Stack => Null_Region,
      Made  => False);

   function Well_Typed (M : Context_Model) return Boolean is
     (M.Made
        and then M.Regs (RIP) = Code_Pointer
        and then M.Regs (RSP) = Stack_Pointer
        and then M.PC /= 0
        and then In_Region (M.SP, M.Stack)
        and then Aligned_16 (M.SP + 8));
   --  The +8 is the ABI's doing, not ours: at the instruction after a call,
   --  the return address has already been pushed, so a correctly aligned
   --  frame has RSP congruent to 8 rather than 0 mod 16. Make_Context builds
   --  the initial frame to match, so a never-yet-run context and a
   --  half-finished one satisfy the same judgement -- which is what lets
   --  Switch treat "start" and "resume" as one operation.

   -------------------------------
   -- Obligations on the assembly --
   -------------------------------

   --  The two judgements the trusted switch routine must satisfy. They are
   --  stated here, checked by GNATprove at every call site, and *assumed* of
   --  the assembly itself.

   function Switch_Pre (From, To : Context_Model) return Boolean is
     (Well_Typed (To)
        and then To.Made
        and then Disjoint (From.Stack, To.Stack));
   --  Entering `To` requires it to be well typed, and the two contexts must
   --  not share a stack -- otherwise saving `From` would scribble on the
   --  frame `To` is about to resume.

   function Switch_Post (From, To : Context_Model) return Boolean is
     (Well_Typed (From) and then To.Made);
   --  On the way out, the outgoing context has been made resumable: its RIP
   --  is the address of the `ret` that Minicoro.Machine_Code's
   --  Resume_Point_Correct pins down, and its RSP still addresses its own
   --  stack. This is the one place where the two papers meet -- the
   --  foundational judgement that `From.Regs (RIP) = Code_Pointer` is
   --  discharged, for the code we generate, by the proved theorem that the
   --  saved address is exactly an instruction boundary.

end Minicoro.FTAL;
