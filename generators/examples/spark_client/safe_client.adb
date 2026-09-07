--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

package body Safe_Client with SPARK_Mode => On is

   --------------------
   -- Sum_Of_Squares --
   --------------------

   procedure Sum_Of_Squares (N : Squares.Count; Total : out Natural) is
      Vals : Squares.Int_Array;
      Got  : Squares.Count;
   begin
      Squares.First_Squares (N, Vals, Got);

      Total := 0;
      for I in 1 .. Got loop
         --  Both halves are needed and both are proved: a negative value
         --  would take Total below Natural'First, a large one above
         --  Natural'Last.
         exit when Vals (I) < 0
           or else Vals (I) > Natural'Last - Total;

         Total := Total + Vals (I);
      end loop;
   end Sum_Of_Squares;

end Safe_Client;
