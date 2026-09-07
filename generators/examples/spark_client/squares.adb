--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The untrusted side of the boundary. Everything GNATprove refuses to look
--  at is in here: the instantiation, the delegate, Yield, and the iteration
--  interface. None of it is checked, and that is the point -- it is the part
--  the spec's contract is a claim *about*.

with Generators;

package body Squares with SPARK_Mode => Off is

   package Int_Gen is new Generators (Integer);

   type Squarer is new Int_Gen.Delegate with record
      Wanted : Natural := 0;
   end record;

   overriding procedure Generate
     (D : in out Squarer; G : Int_Gen.Generator'Class);

   --------------
   -- Generate --
   --------------

   overriding procedure Generate
     (D : in out Squarer; G : Int_Gen.Generator'Class) is
   begin
      for I in 1 .. D.Wanted loop
         G.Yield (I * I);
      end loop;
   end Generate;

   -------------------
   -- First_Squares --
   -------------------

   procedure First_Squares
     (Wanted : Count; Into : out Int_Array; Got : out Count)
   is
      D : constant Int_Gen.Delegate_Access :=
        new Squarer'(Int_Gen.Delegate with Wanted => Wanted);
      --  Ownership transfers to the generator, as Create documents. Do not
      --  retain or free it here.

      G : constant Int_Gen.Generator := Int_Gen.Create (D);
   begin
      Into := [others => 0];
      Got  := 0;

      --  Bounded by Wanted as well as by Has_Next. The generator stops on
      --  its own, but a caller reasoning about Got needs the bound to be
      --  visible in the contract rather than in the delegate's body.
      while Got < Wanted and then G.Has_Next loop
         Got := Got + 1;
         Into (Got) := G.Next;
      end loop;
   end First_Squares;

end Squares;
