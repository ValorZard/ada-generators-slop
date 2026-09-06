--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  See the header of generators.ads for why this layer is not SPARK, and why
--  it is nonetheless shaped like the two below it. Raw keeps the ownership
--  hand-offs in one place, as Coroutines.Raw does, so that the boundary stays
--  visible if the mode is ever revisited.

with Ada.Unchecked_Deallocation;

with Coroutines;

package body Generators with SPARK_Mode => Off is

   ------------------
   -- The pool --
   ------------------

   type Generator_Record is record
      Ref_Count     : Natural := 0;
      --  Number of non-weak Generator handles naming this slot.

      In_Use        : Boolean := False;

      Delegate      : Delegate_Access := null;
      --  User delegate, to be run under Generator_Delegate.

      Owns_Delegate : Boolean := False;
      --  Whether Delegate is owned by this generator, and so freed with it.

      Coro          : Coroutines.Coroutine;
      --  Coroutine that runs this generator.

      Caller        : Coroutines.Coroutine;
      --  Just before switching to the generator coroutine, set to reference
      --  the coroutine it is supposed to switch back to.

      State         : State_Type := Waiting;
      --  Generator execution state. Used to synchronize the generator and its
      --  caller.

      Yield_Value   : T;
      --  Holds values the generator yields so that the caller can access it.
      --  T is a formal private type with no known default, so this component
      --  is meaningless until State has been Yielding at least once; every
      --  read of it below is guarded by that.
   end record;

   Pool : array (Valid_Slot) of Generator_Record;

   type Generator_Delegate is new Coroutines.Delegate with record
      Slot : Slot_Id := No_Slot;
   end record;
   type Generator_Delegate_Access is access all Generator_Delegate;
   --  Delegate that actually implements the generator's coroutine. This is
   --  what invokes the user delegate. It names its generator by slot, not by
   --  pointer, so there is no cycle for ownership to trip over.

   overriding procedure Run (D : in out Generator_Delegate);

   ---------
   -- Raw --
   ---------

   --  TRUSTED, as Coroutines.Raw is: the ownership hand-offs SPARK will not
   --  perform, in one place.

   package Raw is

      procedure Adopt_Delegate (Slot : Valid_Slot; D : Delegate_Access);
      --  Store D as the slot's user delegate, taking ownership. Create takes
      --  D by mode `in`, so SPARK sees it as observed and will not let it be
      --  moved into the pool; the mode is forced by Create being a function
      --  whose result initialises a constant at every call site.

      procedure Free_Delegate (Slot : Valid_Slot);
      --  Release it again. Delegate_Access is a general access type, and
      --  SPARK does not allow Unchecked_Deallocation of one.

      function New_Coroutine (Slot : Valid_Slot) return Coroutines.Coroutine;
      --  Build the Coroutines.Coroutine that will run this slot, handing it a
      --  freshly allocated Generator_Delegate. Outside SPARK for the same
      --  ownership reason: the allocator's result is moved into a call.

   end Raw;

   procedure Claim_Slot (Slot : out Slot_Id);
   --  Reserve a pool slot and initialise its bookkeeping.

   procedure Release (Slot : Valid_Slot);
   --  Last non-weak handle gone: drop the coroutine, free the delegate if
   --  owned, and clear the slot.

   procedure Yield_Slot (Slot : Valid_Slot; Value : T);
   --  The body of Yield.

   procedure Advance (Slot : Valid_Slot);
   --  Resume the generator until it yields or finishes.

   function Live (G : Generator) return Boolean is
     (G.Slot in Valid_Slot and then Pool (G.Slot).In_Use);

   ---------
   -- Raw --
   ---------

   package body Raw is

      procedure Adopt_Delegate (Slot : Valid_Slot; D : Delegate_Access) is
      begin
         Pool (Slot).Delegate := D;
      end Adopt_Delegate;

      procedure Free_Delegate (Slot : Valid_Slot) is
         procedure Free is new Ada.Unchecked_Deallocation
           (Delegate'Class, Delegate_Access);
      begin
         if Pool (Slot).Owns_Delegate then
            Free (Pool (Slot).Delegate);
         else
            Pool (Slot).Delegate := null;
         end if;
      end Free_Delegate;

      function New_Coroutine (Slot : Valid_Slot) return Coroutines.Coroutine is
         D : constant Generator_Delegate_Access :=
           new Generator_Delegate'(Coroutines.Delegate with Slot => Slot);
      begin
         return Coroutines.Create (Coroutines.Delegate_Access (D));
      end New_Coroutine;

   end Raw;

   -------------
   -- Is_Null --
   -------------

   function Is_Null (G : Generator) return Boolean is (G.Slot = No_Slot);

   ----------
   -- Bump --
   ----------

   procedure Bump (G : in out Generator) is
   begin
      if not G.Weak
        and then G.Slot in Valid_Slot
        and then Pool (G.Slot).Ref_Count < Natural'Last
      then
         Pool (G.Slot).Ref_Count := Pool (G.Slot).Ref_Count + 1;
      end if;
   end Bump;

   ----------
   -- Drop --
   ----------

   procedure Drop (G : in out Generator) is
      Slot : constant Slot_Id := G.Slot;
      Weak : constant Boolean := G.Weak;
   begin
      --  Clear the handle first: releasing a slot runs user finalization,
      --  which may reach this very handle, and a reference loop arrives here
      --  with the count already at zero.
      G.Slot := No_Slot;

      if Weak
        or else Slot not in Valid_Slot
        or else Pool (Slot).Ref_Count = 0
      then
         return;
      end if;

      Pool (Slot).Ref_Count := Pool (Slot).Ref_Count - 1;

      if Pool (Slot).Ref_Count = 0 then
         Release (Slot);
      end if;
   exception
      when others =>
         --  A finalizer must not propagate; releasing a slot kills a
         --  coroutine, which can come back carrying whatever it died of.
         null;
   end Drop;

   ----------------
   -- Claim_Slot --
   ----------------

   procedure Claim_Slot (Slot : out Slot_Id) is
   begin
      Slot := No_Slot;
      for I in Valid_Slot loop
         if not Pool (I).In_Use then
            Slot := I;
            exit;
         end if;
      end loop;

      if Slot not in Valid_Slot then
         return;
      end if;

      Pool (Slot).Ref_Count     := 1;
      Pool (Slot).In_Use        := True;
      Pool (Slot).Owns_Delegate := False;
      Pool (Slot).State         := Waiting;
      Pool (Slot).Caller        := Coroutines.Current_Coroutine;
   end Claim_Slot;

   -------------
   -- Release --
   -------------

   procedure Release (Slot : Valid_Slot) is
   begin
      --  Do not rely on the usual coroutine completion mechanism (see Run):
      --  kill a generator that is still alive rather than let it linger.
      if Pool (Slot).Coro.Alive then
         Pool (Slot).Coro.Kill;
      end if;

      Pool (Slot).Coro   := Coroutines.Null_Coroutine;
      Pool (Slot).Caller := Coroutines.Null_Coroutine;
      Pool (Slot).State  := Returning;

      Raw.Free_Delegate (Slot);

      Pool (Slot).Owns_Delegate := False;
      Pool (Slot).In_Use        := False;
   end Release;

   ------------
   -- Create --
   ------------

   function Create (D                  : Delegate_Access;
                    Transfer_Ownership : Boolean := True) return Generator
   is
      Slot : Slot_Id;
   begin
      Claim_Slot (Slot);
      if Slot not in Valid_Slot then
         return Null_Generator;
      end if;

      Raw.Adopt_Delegate (Slot, D);
      Pool (Slot).Owns_Delegate := Transfer_Ownership;

      Pool (Slot).Coro := Raw.New_Coroutine (Slot);
      Pool (Slot).Coro.Spawn;

      return (Slot => Slot, Weak => False);
   end Create;

   ---------
   -- Run --
   ---------

   overriding procedure Run (D : in out Generator_Delegate) is
      Slot : constant Slot_Id := D.Slot;
   begin
      if Slot not in Valid_Slot then
         return;
      end if;

      declare
         --  A weak handle: a generator holding a reference to itself would
         --  never be collected until its execution completed.
         G : constant Generator := (Slot => Slot, Weak => True);
      begin
         begin
            if Pool (Slot).Delegate /= null then
               Pool (Slot).Delegate.all.Generate (Generator'Class (G));
            end if;
         exception
            when others =>
               Pool (Slot).State := Returning;
               raise;
         end;
      end;

      --  We do not want to resume to the parent coroutine. We want instead to
      --  resume to the last coroutine that invoked this generator, so do not
      --  rely on usual coroutine completion mechanism.

      Pool (Slot).State := Returning;
      Pool (Slot).Caller.Switch;
   end Run;

   ----------------
   -- Yield_Slot --
   ----------------

   procedure Yield_Slot (Slot : Valid_Slot; Value : T) is
   begin
      Pool (Slot).State       := Yielding;
      Pool (Slot).Yield_Value := Value;
      Pool (Slot).Caller.Switch;
   end Yield_Slot;

   -----------
   -- Yield --
   -----------

   procedure Yield (G : Generator; Value : T) is
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;
      Yield_Slot (G.Slot, Value);
   end Yield;

   -------------
   -- Advance --
   -------------

   procedure Advance (Slot : Valid_Slot) is
   begin
      Pool (Slot).Caller := Coroutines.Current_Coroutine;
      Pool (Slot).Coro.Switch;
      Pool (Slot).Caller := Coroutines.Null_Coroutine;
   end Advance;

   --------------
   -- Has_Next --
   --------------

   function Has_Next (G : Generator) return Boolean is
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case Pool (G.Slot).State is
         when Waiting =>
            null;
         when Yielding =>
            return True;
         when Returning =>
            return False;
      end case;

      Advance (G.Slot);

      case Pool (G.Slot).State is
         when Waiting =>
            raise Program_Error with "Unreachable state";
         when Yielding =>
            return True;
         when Returning =>
            --  We do not want to rely on usual coroutine completion mechanism
            --  (see Run), so kill completed generators as soon as possible.

            if Pool (G.Slot).Coro.Alive then
               Pool (G.Slot).Coro.Kill;
            end if;
            return False;
      end case;
   end Has_Next;

   ----------
   -- Next --
   ----------

   function Next (G : Generator) return T is
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case Pool (G.Slot).State is
         when Waiting | Returning =>
            raise Program_Error with "Unreachable state";
         when Yielding =>
            Pool (G.Slot).State := Waiting;
            return Pool (G.Slot).Yield_Value;
      end case;
   end Next;

   -----------
   -- First --
   -----------

   function First (G : Generator) return Cursor_Type is
      pragma Unreferenced (G);
   begin
      return (null record);
   end First;

   ----------
   -- Next --
   ----------

   function Next (G : Generator; C : Cursor_Type) return Cursor_Type is
      pragma Unreferenced (C);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case Pool (G.Slot).State is
         when Waiting =>
            null;
         when Yielding =>
            Pool (G.Slot).State := Waiting;
         when Returning =>
            raise Program_Error with "Unreachable state";
      end case;
      return G.First;
   end Next;

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element (G : Generator; C : Cursor_Type) return Boolean is
      pragma Unreferenced (C);
   begin
      return G.Has_Next;
   end Has_Element;

   -------------
   -- Element --
   -------------

   function Element (G : Generator; C : Cursor_Type) return T is
      pragma Unreferenced (C);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case Pool (G.Slot).State is
         when Returning =>
            raise Program_Error with "Unreachable state";

         when Waiting | Yielding =>

            --  Switch to Waiting state so that we don't require a call to Next
            --  in order to go to the next element. This is useful to resume
            --  iteration with a FOR loop.

            Pool (G.Slot).State := Waiting;

            return Pool (G.Slot).Yield_Value;
      end case;
   end Element;

end Generators;
