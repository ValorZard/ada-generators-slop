with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions; use Ada.Exceptions;

with Support; use Support;

--  Test the pair that task affinity exists to provide, at the generator
--  layer: advancing a generator from a task that does not own it is refused,
--  and the *same* call succeeds once the generator has been moved to that
--  task.
--
--  This is the generator counterpart of
--  coroutines/tests/test_continue_after_move, and the point is the same. It
--  is not just that the second call does not raise. It is that the generator
--  picks up where it left off: main draws 1, the worker is refused, the
--  generator moves, and the worker's identical call produces 2 -- on a
--  different thread, on the same stack, with the delegate's loop counter
--  intact. A generator that restarted would print 1 again.
--
--  Two details this test exists to pin down, both of them easy to get wrong:
--
--  * The refusal is Generator_Error, not Coroutine_Error. Advance checks
--    ownership itself for exactly this reason; left to Coroutines.Switch it
--    would raise the lower layer's exception and let it out of an iteration
--    primitive, which would be the one place in the package where a caller
--    saw something else.
--
--  * Detached means detached. After main lets go, *main* is refused too --
--    ownership is what the check tests, not history.
--
--  Each phase is bracketed by two rendezvous, one to start the worker and one
--  to wait for it to finish, so the output ordering is fixed. A single one
--  would only mark the start, and the environment task would race ahead into
--  the next phase while the worker was still in this one.

procedure Test_Advance_After_Move is

   package IG renames Support.Int_Generators;

   Last : constant := 4;

   G : constant IG.Generator :=
     IG.Create (new Counter_Finite'(Last => Last));

   procedure Draw (Who : String);
   --  Draw one value. This is the one call the whole test is about, and it is
   --  deliberately the same code on both tasks: only the ownership of G
   --  differs between the calls.

   procedure Draw (Who : String) is
   begin
      if G.Has_Next then
         Put_Line (Who & " got" & Integer'Image (G.Next));
      else
         Put_Line (Who & ": exhausted");
      end if;
   exception
      when Exc : IG.Generator_Error =>
         Put_Line (Who & ": refused -- " & Exception_Message (Exc));
   end Draw;

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
      --  Phase 1: G still belongs to the environment task. Has_Next has to
      --  resume the generator to answer, so this is a control transfer and
      --  is refused. Reading a value already yielded would not be.
      accept Try_It;
      Draw ("worker");
      accept Tried;

      --  Phase 2: G is detached, so it may be taken.
      accept Take_Over;
      G.Adopt;
      Put_Line ("worker: adopted, owned by me = "
                & Boolean'Image (G.Owned_By_Current_Task));
      Draw ("worker");
      Draw ("worker");
      accept Took_Over;

      --  Phase 3: hand it back.
      accept Give_Back;
      G.Detach;
      accept Gave_Back;
   end Worker;

begin
   --  Value 1, on the environment task, which owns it.
   Draw ("main");

   --  The same call from a task that does not own it.
   Worker.Try_It;
   Worker.Tried;

   --  Let go, and even the task that just let go is refused.
   G.Detach;
   Put_Line ("main: detached, detached = " & Boolean'Image (G.Is_Detached));
   Draw ("main");

   --  Move it, and the identical call now works -- and resumes at 2.
   Worker.Take_Over;
   Worker.Took_Over;

   Worker.Give_Back;
   Worker.Gave_Back;

   G.Adopt;
   Put_Line ("main: adopted back, owned by me = "
             & Boolean'Image (G.Owned_By_Current_Task));

   --  Value 4, then the delegate's loop is exhausted and the generator is
   --  done -- on the environment task, which has not touched this
   --  generator's stack since value 1.
   Draw ("main");
   Draw ("main");

   Put_Line ("main: done");
end Test_Advance_After_Move;
