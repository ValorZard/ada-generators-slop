--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

package body Safe_Client with SPARK_Mode => On is

   ---------
   -- Run --
   ---------

   overriding procedure Run (D : in out Step) is
   begin
      --  Only D. Reaching for a package variable here is what SPARK RM 6.1.6
      --  rejects; see note 2 in the spec.
      if D.Hits < Natural'Last then
         D.Hits := D.Hits + 1;
      end if;
   end Run;

   -----------
   -- Tally --
   -----------

   protected Tally is
      procedure Add;
      function Total return Natural;
   private
      N : Natural := 0;
   end Tally;
   --  A protected object is *synchronized* state to SPARK, so touching it
   --  from two tasks raises nothing. This is the ordinary Ada answer to
   --  sharing data between tasks, and the coroutine library neither provides
   --  nor needs a replacement for it.

   protected body Tally is

      procedure Add is
      begin
         if N < Natural'Last then
            N := N + 1;
         end if;
      end Add;

      function Total return Natural is (N);

   end Tally;

   --------------
   -- Producer --
   --------------

   task body Producer is
      C : Coroutines.Coroutine;
      D : constant Coroutines.Delegate_Access := new Step;
      pragma Annotate
        (GNATprove, Intentional, "resource or memory leak might occur",
         "Ownership of D transfers to the coroutine, which frees it when the "
         & "last handle goes; that is what Create's documentation promises "
         & "and what Raw.Free_Delegate does. SPARK cannot see it because "
         & "Delegate_Access is a general access type (access all), which its "
         & "ownership model does not track. This is the obligation every "
         & "caller of Create already carries -- do not retain or free D -- "
         & "written down at the one place a client has to honour it.");
   begin
      --  The procedure form. The function form would put this whole unit
      --  outside SPARK, and with it every race check above.
      Coroutines.Create (C, D);

      loop
         Tally.Add;
      end loop;
   end Producer;

   --------------
   -- Consumer --
   --------------

   task body Consumer is
      Seen : Natural;
   begin
      loop
         Seen := Tally.Total;
         pragma Assert (Seen >= 0);
      end loop;
   end Consumer;

end Safe_Client;
