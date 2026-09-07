with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions; use Ada.Exceptions;

with Coroutines;

with Support;

--  Test the pair that task affinity exists to provide: continuing a coroutine
--  from a task that does not own it is refused, and the *same* call succeeds
--  once the coroutine has been moved to that task.
--
--  The point is not just that the second call does not raise. It is that the
--  coroutine picks up where it left off: main runs step 1, the worker is
--  refused, the coroutine moves, and the worker's switch produces step 2 --
--  on a different thread, on the same stack, with the loop counter intact.
--
--  Each phase is bracketed by *two* rendezvous, one to start the worker and
--  one to wait for it to finish. A single one would only mark the start, and
--  the environment task would then race ahead into the next phase while the
--  worker was still in this one -- which is a difference the output ordering
--  would show only sometimes.
--
--  The handle C is never copied across a task boundary; the primitives are
--  called on the enclosing variable and a tagged type is passed by reference.

procedure Test_Continue_After_Move is

   C : constant Coroutines.Coroutine :=
     Coroutines.Create (new Support.Stepper'(Steps => 3));

   procedure Continue_It (Who : String);
   --  "Continue the coroutine", i.e. switch into it. This is the one call the
   --  whole test is about, and it is deliberately the same code on both
   --  tasks: only the ownership of C differs between the calls.

   procedure Continue_It (Who : String) is
   begin
      C.Switch;
      Put_Line (Who & ": continued it");
   exception
      when Exc : Coroutines.Coroutine_Error =>
         Put_Line (Who & ": refused -- " & Exception_Message (Exc));
   end Continue_It;

   task Worker is
      entry Try_It;
      entry Tried;
      entry Take_Over;
      entry Took_Over;
      entry Give_Back;
      entry Gave_Back;
   end Worker;

   task body Worker is
   begin
      --  Phase 1: C still belongs to the environment task.
      accept Try_It;
      Continue_It ("worker");
      accept Tried;

      --  Phase 2: C is detached, so it may be taken.
      accept Take_Over;
      C.Adopt;
      Put_Line ("worker: adopted, owned by me = "
                & Boolean'Image (C.Owned_By_Current_Task));
      Continue_It ("worker");
      Continue_It ("worker");
      accept Took_Over;

      --  Phase 3: hand it back.
      accept Give_Back;
      C.Detach;
      accept Gave_Back;
   end Worker;

begin
   C.Spawn;

   --  Step 1, on the environment task, which owns it.
   Continue_It ("main");

   --  The same call from a task that does not own it.
   Worker.Try_It;
   Worker.Tried;

   --  Detached means detached: even the task that just let go is refused,
   --  because ownership is what the check tests, not history.
   C.Detach;
   Continue_It ("main");

   --  Move it, and the identical call now works -- and resumes at step 2.
   Worker.Take_Over;
   Worker.Took_Over;

   Worker.Give_Back;
   Worker.Gave_Back;

   C.Adopt;
   Put_Line ("main: adopted back, owned by me = "
             & Boolean'Image (C.Owned_By_Current_Task));

   --  Fourth switch: the loop is exhausted, so the delegate returns and the
   --  coroutine dies.
   Continue_It ("main");
   Put_Line ("main: alive = " & Boolean'Image (C.Alive));

   Put_Line ("main: done");
end Test_Continue_After_Move;
