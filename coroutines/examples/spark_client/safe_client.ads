--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A SPARK client of Coroutines, proved free of data races.
--
--  The point of this example is not the program, which does nothing useful.
--  It is that GNATprove will analyse it *at all*, and therefore report data
--  races on the client's own variables. That was impossible until Coroutines
--  grew procedure forms of Create, Current_Coroutine and Main_Coroutine: a
--  SPARK function may not write globals, so the function forms are outside
--  SPARK, and that is contagious to the caller --
--
--    error: "C" is not allowed in SPARK (due to entity declared with
--           SPARK_Mode Off)
--
--  -- which took the whole calling unit out of SPARK's reach, race checking
--  included.
--
--  Three things are needed to make a client like this work, and all three
--  were found the hard way:
--
--    1. `pragma Elaborate_Body` below. Without it the delegate is rejected
--       with E0003, "first freezing point of type must appear within early
--       call region of primitive body" (SPARK RM 7.7(8)): a dispatching call
--       could otherwise reach Run before its body is elaborated.
--
--    2. The delegate's Run must touch only its own components. Run overrides
--       an abstract operation whose inferred Global is null, and SPARK RM
--       6.1.6 requires an override's Global to be subsumed by the overridden
--       one's. Reaching for a package-level variable from inside Run gets
--       "X is an In_Out of overriding subprogram, but it is not an Input of
--       overridden subprogram Run". Put the state in the delegate record.
--
--    3. Only one task may touch the coroutine library. Create finds a free
--       slot by scanning a shared pool and then marking it, which is two
--       steps; two tasks doing that together can pick the same slot. This is
--       not a false positive -- it is the one operation documented as
--       unsynchronised in coroutines.ads -- and SPARK reports it as
--       "possible data race when accessing variable coroutines.registry".
--
--  To see the machinery working, move Shared_Total out from behind Tally and
--  have both tasks write it: GNATprove then reports
--
--    high: possible data race when accessing variable
--          "safe_client.shared_total"
--      + task "safe_client.producer" accesses ...
--      + task "safe_client.consumer" accesses ...

with Coroutines;

package Safe_Client with SPARK_Mode => On is

   pragma Elaborate_Body;
   --  See note 1 above. Required, not stylistic.

   type Step is new Coroutines.Delegate with record
      Hits : Natural := 0;
      --  The delegate's state lives here rather than in a package variable.
      --  See note 2 above.
   end record;

   overriding procedure Run (D : in out Step);

   task Producer;
   --  The only task that touches Coroutines. See note 3 above.

   task Consumer;
   --  Reads what Producer published, through the protected object in the
   --  body. It never calls into the coroutine library at all.

end Safe_Client;
