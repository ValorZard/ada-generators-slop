with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions; use Ada.Exceptions;

with Coroutines;

with Support;

--  Test the Max_Tasks ceiling. Task numbers are handed out on first use and
--  never reused, so a program with more tasks than the ceiling must refuse
--  the surplus cleanly rather than hand out a number that is already in use.
--
--  Note which tasks count. The environment task below never creates or adopts
--  a coroutine -- it only starts workers and prints -- so it never takes a
--  number, and all Max_Tasks of them go to workers. That is the documented
--  behaviour: a task that merely observes costs nothing.
--
--  The workers are driven one at a time by a rendezvous, and the output is
--  counts rather than per-task lines, so it does not have to be regenerated
--  if Minicoro.Max_Owners is ever changed.

procedure Test_Too_Many_Tasks is

   Over : constant := 3;
   --  How many tasks to ask for beyond the ceiling.

   type Outcome is (Worked, Refused, Other_Error);

   task type Worker is
      entry Run (Got : out Outcome);
   end Worker;

   task body Worker is
   begin
      accept Run (Got : out Outcome) do
         Got := Worked;

         --  Creating a coroutine is what claims a task number, so this is
         --  the operation that runs out. A refused task gets Null_Coroutine
         --  back, and the error surfaces at first use -- exactly as it does
         --  when the coroutine pool itself is exhausted.
         declare
            C : constant Coroutines.Coroutine :=
              Coroutines.Create (new Support.Null_Delegate);
         begin
            C.Spawn;
            C.Kill;
         exception
            when Coroutines.Coroutine_Error =>
               Got := Refused;
            when Exc : others =>
               Put_Line ("unexpected: " & Exception_Name (Exc));
               Got := Other_Error;
         end;
      end Run;
   end Worker;

   Admitted : Natural := 0;
   Rejected : Natural := 0;
   Broken   : Natural := 0;

begin
   for I in 1 .. Coroutines.Max_Tasks + Over loop
      declare
         W   : Worker;
         Got : Outcome;
      begin
         W.Run (Got);
         case Got is
            when Worked      => Admitted := Admitted + 1;
            when Refused     => Rejected := Rejected + 1;
            when Other_Error => Broken   := Broken + 1;
         end case;
      end;
   end loop;

   Put_Line ("admitted = ceiling: "
             & Boolean'Image (Admitted = Coroutines.Max_Tasks));
   Put_Line ("refused:" & Integer'Image (Rejected));
   Put_Line ("unexpected errors:" & Integer'Image (Broken));
   Put_Line ("main: done");
end Test_Too_Many_Tasks;
