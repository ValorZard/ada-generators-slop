with Ada.Text_IO; use Ada.Text_IO;
with Ada.Exceptions; use Ada.Exceptions;

with Coroutines;

with Support;

--  Test that a coroutine belongs to one task, that another task is refused
--  every operation on it, and that Detach/Adopt hand it over.
--
--  Every step is serialised by a rendezvous, so the output is deterministic
--  even though three tasks take part. The coroutine handle C is never copied
--  across a task boundary: the primitives below are called on the enclosing
--  variable, and a tagged type is passed by reference, so nothing touches the
--  reference count. That is the discipline coroutines.ads asks for.

procedure Test_Task_Affinity is

   C : constant Coroutines.Coroutine :=
     Coroutines.Create (new Support.Null_Delegate);

   procedure Report (What : String; Ok : Boolean);
   procedure Expect_Error (What : String);

   procedure Report (What : String; Ok : Boolean) is
   begin
      Put_Line (What & " = " & (if Ok then "TRUE" else "FALSE"));
   end Report;

   procedure Expect_Error (What : String) is
   begin
      Put_Line (What & ": no error raised");
   end Expect_Error;

   task Foreign is
      entry Go;
      entry Done;
   end Foreign;

   task Mover is
      entry Go;
      entry Done;
   end Mover;

   task body Foreign is
   begin
      accept Go;

      --  Four ways of touching a coroutine that belongs to the environment
      --  task. All four are refused.

      begin
         C.Switch;
         Expect_Error ("foreign: switch");
      exception
         when Exc : Coroutines.Coroutine_Error =>
            Put_Line ("foreign: switch -> " & Exception_Message (Exc));
      end;

      begin
         C.Kill;
         Expect_Error ("foreign: kill");
      exception
         when Exc : Coroutines.Coroutine_Error =>
            Put_Line ("foreign: kill -> " & Exception_Message (Exc));
      end;

      begin
         C.Detach;
         Expect_Error ("foreign: detach");
      exception
         when Exc : Coroutines.Coroutine_Error =>
            Put_Line ("foreign: detach -> " & Exception_Message (Exc));
      end;

      begin
         C.Adopt;
         Expect_Error ("foreign: adopt");
      exception
         when Exc : Coroutines.Coroutine_Error =>
            Put_Line ("foreign: adopt -> " & Exception_Message (Exc));
      end;

      Report ("foreign: owned by me", C.Owned_By_Current_Task);

      accept Done;
   end Foreign;

   task body Mover is
   begin
      accept Go;

      --  C is detached by now, so this task may take it and run it.
      C.Adopt;
      Report ("mover: owned by me", C.Owned_By_Current_Task);
      Report ("mover: detached", C.Is_Detached);

      C.Switch;
      Put_Line ("mover: back from the coroutine");
      Report ("mover: still alive", C.Alive);

      --  Hand it back so the environment task can release it.
      C.Detach;
      Put_Line ("mover: detached again");

      accept Done;
   end Mover;

begin
   C.Spawn;

   Report ("main: owned by me", C.Owned_By_Current_Task);
   Report ("main: detached", C.Is_Detached);

   Foreign.Go;
   Foreign.Done;

   --  The environment task owns it, so it is the one that may let go.
   C.Detach;
   Report ("main: detached", C.Is_Detached);
   Report ("main: owned by me", C.Owned_By_Current_Task);

   Mover.Go;
   Mover.Done;

   C.Adopt;
   Report ("main: owned by me again", C.Owned_By_Current_Task);
   Report ("main: alive", C.Alive);

   Put_Line ("main: done");
end Test_Task_Affinity;
