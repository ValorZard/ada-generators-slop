--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  Ordinary SPARK, fully analysed, consuming a generator it cannot see.
--
--  Nothing here names Generators, a Generator, or Yield -- it could not, and
--  that is what makes it provable. All it knows is that Squares.First_Squares
--  is a procedure with an In_Out global, which is a shape SPARK is perfectly
--  happy with.

with Squares;

package Safe_Client with SPARK_Mode => On is

   procedure Sum_Of_Squares (N : Squares.Count; Total : out Natural)
     with Global => (In_Out => Squares.State);
   --  Saturates rather than overflowing: the loop stops at the first value
   --  that would not fit. A generator can yield anything, so the client
   --  checks rather than assuming.

end Safe_Client;
