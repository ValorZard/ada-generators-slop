with Ada.Text_IO; use Ada.Text_IO;

with Support; use Support;

--  Test that detached generators can be picked up and run by whichever
--  worker task gets to them first -- work stealing -- and handed back.
--
--  The output is deterministic even though the schedule is not: which worker
--  runs which job is up to the runtime, so nothing here prints a worker's
--  identity or a per-worker count. What is checked is that every job ran
--  exactly once, on some task other than the one that created it, and that
--  the values add up.
--
--  The workers operate on Slots (I) in place rather than taking copies of the
--  handles. That is no longer required for safety -- reference counts are
--  atomic, so a handle may be copied and dropped on any task; see "Task
--  affinity" in coroutines.ads -- but it keeps this case about the thing it
--  is testing, which is Detach/Adopt. Creation stays on the environment task
--  because concurrent Create is the one operation that is still
--  unsynchronised.

procedure Test_Work_Stealing is

   package IG renames Support.Int_Generators;

   Job_Count    : constant := 8;
   Worker_Count : constant := 3;

   Slots : array (1 .. Job_Count) of IG.Generator;
   --  Job I yields 1 .. I, so it contributes I * (I + 1) / 2 to the total and
   --  the whole run comes to 120.

   Expected_Total : constant := 120;

   ----------------
   -- Dispatcher --
   ----------------

   protected Dispatcher is
      procedure Next (I : out Natural);
      --  Hand out the next unclaimed job index, or 0 when there are none
      --  left. This is the whole scheduler: a worker that finishes early
      --  simply asks again and takes whatever is next.
   private
      Handed : Natural := 0;
   end Dispatcher;

   protected body Dispatcher is
      procedure Next (I : out Natural) is
      begin
         if Handed < Job_Count then
            Handed := Handed + 1;
            I := Handed;
         else
            I := 0;
         end if;
      end Next;
   end Dispatcher;

   -----------
   -- Tally --
   -----------

   protected Tally is
      procedure Add (V : Integer);
      procedure Finished_A_Job;
      function Total return Integer;
      function Jobs_Done return Natural;
   private
      Sum  : Integer := 0;
      Done : Natural := 0;
   end Tally;

   protected body Tally is

      procedure Add (V : Integer) is
      begin
         Sum := Sum + V;
      end Add;

      procedure Finished_A_Job is
      begin
         Done := Done + 1;
      end Finished_A_Job;

      function Total return Integer is (Sum);

      function Jobs_Done return Natural is (Done);

   end Tally;

   ------------
   -- Worker --
   ------------

   task type Worker;

   task body Worker is
      I : Natural;
   begin
      loop
         Dispatcher.Next (I);
         exit when I = 0;

         --  Steal it, run it to exhaustion, put it back down. Between the
         --  Adopt and the Detach this task is the only one that may advance
         --  the generator, and the checks in Coroutines enforce that rather
         --  than trusting it.
         Slots (I).Adopt;
         for V of Slots (I) loop
            Tally.Add (V);
         end loop;
         Slots (I).Detach;

         Tally.Finished_A_Job;
      end loop;
   end Worker;

   All_Detached : Boolean := True;

begin
   --  Create every job on the environment task, then let go of all of them.
   --  Creation walks the shared pools, so it is deliberately done here, on
   --  one task, before any worker exists.
   for I in Slots'Range loop
      Slots (I) := IG.Create (new Counter_Finite'(Last => I));
      Slots (I).Detach;
   end loop;

   for I in Slots'Range loop
      All_Detached := All_Detached and then Slots (I).Is_Detached;
   end loop;
   Put_Line ("all jobs detached: " & Boolean'Image (All_Detached));

   --  The workers activate at this block's begin -- after every job is in
   --  place -- and it does not complete until all of them have terminated.
   --  Nothing else needs synchronising: the environment task touches no
   --  handle while they run.
   declare
      Crew : array (1 .. Worker_Count) of Worker;
      pragma Unreferenced (Crew);
   begin
      null;
   end;

   Put_Line ("jobs done:" & Natural'Image (Tally.Jobs_Done));
   Put_Line ("total:" & Integer'Image (Tally.Total));
   Put_Line ("total as expected: "
             & Boolean'Image (Tally.Total = Expected_Total));

   --  Take them all back so the environment task is the one that releases
   --  them, for the same reason it is the one that created them.
   All_Detached := True;
   for I in Slots'Range loop
      All_Detached := All_Detached and then Slots (I).Is_Detached;
      Slots (I).Adopt;
   end loop;
   Put_Line ("handed back detached: " & Boolean'Image (All_Detached));
end Test_Work_Stealing;
