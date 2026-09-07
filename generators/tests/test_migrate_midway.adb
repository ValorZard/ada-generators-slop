with Ada.Text_IO; use Ada.Text_IO;

with Support; use Support;

--  Test that a generator can change task between two of its own yields, over
--  and over, and go on producing where it left off.
--
--  This is the sharpest case the affinity work has to handle, and a stricter
--  one than work stealing: there, a task adopts a generator and runs it to
--  exhaustion, so the coroutine is only ever resumed by the task that last
--  suspended it. Here the two alternate on every single value, so every
--  resumption is by the *other* task, and the generator's stack is walked
--  onto by a different thread each time.
--
--  The alternation is a rendezvous, so the output is fixed; only the identity
--  of the thread doing the work changes.

procedure Test_Migrate_Midway is

   package IG renames Support.Int_Generators;

   Last : constant := 6;

   G : constant IG.Generator :=
     IG.Create (new Counter_Finite'(Last => Last));

   procedure Pull (Who : String);
   --  Take the generator, draw one value from it, and put it back down.

   procedure Pull (Who : String) is
   begin
      G.Adopt;
      if G.Has_Next then
         Put_Line (Who & " got" & Integer'Image (G.Next));
      else
         Put_Line (Who & ": exhausted");
      end if;
      G.Detach;
   end Pull;

   task Helper is
      entry Step;
      entry Done;
      entry Stop;
   end Helper;

   task body Helper is
   begin
      loop
         select
            accept Step;
         or
            accept Stop;
            exit;
         end select;

         Pull ("helper");

         accept Done;
      end loop;
   end Helper;

begin
   --  The environment task created it, so it is the one that lets go first.
   G.Detach;

   for Step in 1 .. Last / 2 loop
      Pull ("main");

      Helper.Step;
      Helper.Done;
   end loop;

   --  One more draw, which finds the generator finished. It runs on the
   --  environment task, which by now has not touched this generator's stack
   --  for two full rounds.
   Pull ("main");

   Helper.Stop;

   --  Take it back for good, so the task that created it is the one that
   --  releases it.
   G.Adopt;
   Put_Line ("main: reclaimed");
end Test_Migrate_Midway;
