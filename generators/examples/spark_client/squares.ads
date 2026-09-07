--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A generator behind a SPARK-callable interface.
--
--  Generators cannot be used from SPARK at all -- not Yield, not the
--  iteration interface, not even the instantiation. A SPARK unit that writes
--
--     package Int_Gen is new Generators (Integer);
--
--  is rejected outright, so there is no Generator for a SPARK client to hold
--  and nothing for it to call Yield on. See CLAUDE.md, "Generators cannot be
--  used from SPARK", for the four errors and why they are irreducible.
--
--  This package is the way round it, and it is the same shape the tree uses
--  wherever SPARK cannot express something: Minicoro.Atomics hides an atomic
--  counter, Minicoro.Contexts hides a machine context switch, and this hides
--  a generator. The spec is SPARK and is what callers reason about; the body
--  is SPARK_Mode => Off and is where the generator actually lives.
--
--  Two things make the boundary work, and neither is optional:
--
--  * **It must be a procedure.** A SPARK function may not write globals
--    (E0005), and driving a generator does. This is the same reason
--    Coroutines grew procedure forms of Create and friends.
--
--  * **It must be bounded.** A SPARK caller needs a size it can reason
--    about, so the result comes back as an array with a Count rather than as
--    a lazy sequence. That is a real loss -- laziness is the point of a
--    generator, and it does not survive the crossing.
--
--  The body has no Refined_State, deliberately: a SPARK_Mode => Off body may
--  not carry one, and State staying opaque is exactly the intent.

package Squares with
  SPARK_Mode     => On,
  Abstract_State => State,
  Initializes    => State
is

   Max : constant := 16;

   subtype Count is Natural range 0 .. Max;

   type Int_Array is array (1 .. Max) of Integer;

   procedure First_Squares
     (Wanted : Count; Into : out Int_Array; Got : out Count)
     with Global => (In_Out => State),
          Post   => Got = Wanted;
   --  Run a generator that yields the first Wanted squares, and hand back
   --  what it produced. Got = Wanted because the generator is driven to
   --  completion here; a caller never sees it suspended.

end Squares;
