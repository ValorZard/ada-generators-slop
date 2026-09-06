with Coroutines; use Coroutines;

--  Test the finalization of a loop of coroutine references

procedure Test_Reference_Loop is

   type Delegate is new Coroutines.Delegate with record
     Self : Coroutine;
   end record;
   overriding procedure Run (D : in out Delegate);

   ---------
   -- Run --
   ---------

   overriding procedure Run (D : in out Delegate) is
      pragma Unreferenced (D);
   begin
      null;
   end Run;

   type D_Ptr is access all Delegate;

   D : constant D_Ptr := new Delegate;
   C : constant Coroutine := Create (Delegate_Access'(D.all'Unchecked_Access));

begin
   D.Self := C;
end Test_Reference_Loop;
