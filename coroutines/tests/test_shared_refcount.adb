with Ada.Text_IO; use Ada.Text_IO;

with Coroutines;

with Support;

--  Test that a coroutine handle can be copied and dropped by several tasks at
--  once without losing count.
--
--  Reference counting is about lifetime, not scheduling, so affinity
--  deliberately does not guard it: a coroutine detached by one task and
--  adopted by another is named, in between, by handles that either task may
--  copy. That only works if the count is atomic, and it is -- see
--  Minicoro.Atomics.
--
--  This is a hammer, not a demonstration. Each worker takes and releases a
--  reference Hits times, so the count returns to where it started only if
--  every one of Workers * Hits * 2 updates landed. With an ordinary Natural
--  increment the same loop loses roughly half of them, the count reaches
--  zero early, and the coroutine is released while the environment task still
--  holds a handle -- which is a use-after-free, not a wrong number. So the
--  assertion below is deliberately "is it still alive", the symptom that
--  would actually bite, and the case is worth running under valgrind.

procedure Test_Shared_Refcount is

   Workers : constant := 8;
   Hits    : constant := 50_000;

   C : constant Coroutines.Coroutine :=
     Coroutines.Create (new Support.Null_Delegate);

   task type Hammer;

   task body Hammer is
      Saw_Dead : Boolean := False;
   begin
      for I in 1 .. Hits loop
         declare
            --  Adjust bumps the count on the way in, Finalize drops it on the
            --  way out. Nothing here touches the coroutine's stack, so no
            --  affinity check is involved and none should be: this task never
            --  tries to run it.
            Copy : constant Coroutines.Coroutine := C;
         begin
            Saw_Dead := Saw_Dead or else not Copy.Alive;
         end;
      end loop;

      --  Silent on success, so the golden output does not depend on how the
      --  tasks interleaved.
      if Saw_Dead then
         Put_Line ("worker: saw the coroutine die under it");
      end if;
   end Hammer;

begin
   C.Spawn;
   Put_Line ("before: alive = " & Boolean'Image (C.Alive));

   declare
      Crew : array (1 .. Workers) of Hammer;
      pragma Unreferenced (Crew);
   begin
      null;
   end;

   --  If a single increment had been lost the count would have reached zero
   --  somewhere in the middle, the slot would have been released, and the
   --  delegate freed under us.
   Put_Line ("after:  alive = " & Boolean'Image (C.Alive));
   Put_Line ("owned by me =   " & Boolean'Image (C.Owned_By_Current_Task));
   Put_Line ("main: done");
end Test_Shared_Refcount;
