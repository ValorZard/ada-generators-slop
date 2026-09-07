with Coroutines;

package Support is

   --  Package providing helpers for test programs

   type Null_Delegate is new Coroutines.Delegate with null record;
   --  Coroutine delegate that does nothing and terminates

   overriding procedure Run (D : in out Null_Delegate);

   type Hello_World_Delegate is new Coroutines.Delegate with record
      Caller     : Coroutines.Coroutine;
      Iterations : Natural;
   end record;
   --  Coroutine delegate that writes "Hello, world!" each time it is switched
   --  to and then switches back to the caller. It stops after performing a
   --  specific number of iterations.

   overriding procedure Run (D : in out Hello_World_Delegate);

   type Stepper is new Coroutines.Delegate with record
      Steps : Natural := 0;
      --  How many times to stop and hand control back.
   end record;
   --  Coroutine delegate that announces each step and then switches back to
   --  the main coroutine *of whichever task is running it*, rather than to a
   --  caller captured when it was created. That is what makes it usable
   --  across a move: Coroutines.Main_Coroutine is per task, so the coroutine
   --  always hands control to a coroutine the running task owns, and picks up
   --  at the next step whoever switches into it next.

   overriding procedure Run (D : in out Stepper);

end Support;
