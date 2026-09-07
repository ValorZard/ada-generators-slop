--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  See the header of generators.ads for why this layer is not SPARK, and why
--  it is nonetheless shaped like the two below it. Raw keeps the ownership
--  hand-offs in one place, as Coroutines.Raw does, so that the boundary stays
--  visible if the mode is ever revisited.

with Ada.Exceptions; use Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Coroutines;
with Generator_Coros;

package body Generators with SPARK_Mode => On is

   package GS renames Generator_Slots;
   package GC renames Generator_Coros;
   use all type GS.State_Type;
   use all type GC.Result;

   ------------------
   -- The pool --
   ------------------

   Delegates : array (Valid_Slot) of Delegate_Access := [others => null];
   --  The user delegate, and by now the only thing left here that depends on
   --  the formal type -- Delegate is declared inside this generic, because
   --  Generate takes a Generator'Class.
   --
   --  Everything else that used to sit beside it in a Generator_Record has
   --  been hoisted into a non-generic package, which is the only way code in
   --  this tree gets analysed at all: the reference count, the in-use flag,
   --  the delegate-ownership flag and the execution state into
   --  Generator_Slots, and the two Coroutine handles into Generator_Coros.

   Values : array (Valid_Slot) of T;
   --  What the generator yields. Kept in its own array rather than beside
   --  the delegate, for the same reason Coroutines holds its exception
   --  occurrences apart: T is a formal private type with no default SPARK
   --  can see, and one component like that makes a whole enclosing record
   --  count as uninitialised. Flat parallel arrays are the house style
   --  throughout this layer for exactly that reason -- there is no longer a
   --  Generator_Record at all. A slot's value is meaningless until its State
   --  has been Yielding; every read below is guarded by that.

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

   package Raw with SPARK_Mode => On is

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

   procedure Yield_Slot (Slot : Valid_Slot; Value : T)
     with Exceptional_Cases => (others => True);
   --  The body of Yield.

   procedure Advance (Slot : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Resume the generator until it yields or finishes.

   function Live (G : Generator) return Boolean is
     (G.Slot in Valid_Slot and then GS.In_Use (G.Slot));

   ---------
   -- Raw --
   ---------

   package body Raw with SPARK_Mode => Off is

      procedure Adopt_Delegate (Slot : Valid_Slot; D : Delegate_Access) is
      begin
         Delegates (Slot) := D;
      end Adopt_Delegate;

      procedure Free_Delegate (Slot : Valid_Slot) is
         procedure Free is new Ada.Unchecked_Deallocation
           (Delegate'Class, Delegate_Access);
      begin
         if GS.Owns_Delegate (Slot) then
            Free (Delegates (Slot));
         else
            Delegates (Slot) := null;
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
      if not G.Weak and then G.Slot in Valid_Slot then
         GS.Bump (G.Slot);
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

      if Weak or else Slot not in Valid_Slot then
         return;
      end if;

      declare
         Released : Boolean;
      begin
         --  Generator_Slots.Drop does the counting and clears the slot when
         --  the count reaches zero; what it cannot do is the cleanup that
         --  depends on the formal type, which is why Released comes back.
         GS.Drop (Slot, Released);
         if Released then
            Release (Slot);
         end if;
      end;
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
      GS.Claim (Slot);
      if Slot in Valid_Slot then
         GC.Note_Caller (Slot);
      end if;
   end Claim_Slot;

   -------------
   -- Release --
   -------------

   procedure Release (Slot : Valid_Slot) is
   begin
      --  Kills the coroutine if it is still alive rather than letting it
      --  linger; see the comment in Generator_Coros.Clear.
      GC.Clear (Slot);

      --  Generator_Slots.Drop has already cleared the slot's bookkeeping by
      --  the time we get here; what is left is the part neither it nor
      --  Generator_Coros can see, which is now just the delegate.
      Raw.Free_Delegate (Slot);
   end Release;

   ------------
   -- Create --
   ------------

   function Create (D                  : Delegate_Access;
                    Transfer_Ownership : Boolean := True) return Generator
   is
      pragma SPARK_Mode (Off);
      Slot : Slot_Id;
   begin
      Claim_Slot (Slot);
      if Slot not in Valid_Slot then
         return Null_Generator;
      end if;

      Raw.Adopt_Delegate (Slot, D);
      GS.Set_Owns_Delegate (Slot, Transfer_Ownership);

      GC.Set_Coro (Slot, Raw.New_Coroutine (Slot));
      GC.Spawn (Slot);

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
            if Delegates (Slot) /= null then
               Delegates (Slot).all.Generate (Generator'Class (G));
            end if;
         exception
            when others =>
               GS.Set_State (Slot, Returning);
               raise;
         end;
      end;

      --  We do not want to resume to the parent coroutine. We want instead to
      --  resume to the last coroutine that invoked this generator, so do not
      --  rely on usual coroutine completion mechanism.

      GS.Set_State (Slot, Returning);
      GC.Return_To_Caller (Slot);
   end Run;

   ---------------------------
   -- Owned_By_Current_Task --
   ---------------------------

   function Owned_By_Current_Task (G : Generator) return Boolean is
     (Live (G) and then GC.Owned_Here (G.Slot));

   -----------------
   -- Is_Detached --
   -----------------

   function Is_Detached (G : Generator) return Boolean is
     (Live (G) and then GC.Is_Detached (G.Slot));

   ------------
   -- Detach --
   ------------

   procedure Detach (G : Generator) is
      pragma SPARK_Mode (Off);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      begin
         GC.Detach (G.Slot);
      exception
         when Exc : Coroutines.Coroutine_Error =>
            raise Generator_Error with Exception_Message (Exc);
      end;

      --  Forget who last advanced it. Caller names a coroutine of the task we
      --  are leaving; the next Advance sets it to one of the adopting task's
      --  before anything can switch. Clearing it is only tidiness in the
      --  usual case -- Advance already nulls it on the way out -- but a
      --  generator detached between Create and its first iteration would
      --  otherwise carry the creating task's handle across.
      GC.Clear_Caller (G.Slot);
   end Detach;

   -----------
   -- Adopt --
   -----------

   procedure Adopt (G : Generator) is
      pragma SPARK_Mode (Off);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      GC.Adopt (G.Slot);
   exception
      when Exc : Coroutines.Coroutine_Error =>
         raise Generator_Error with Exception_Message (Exc);
   end Adopt;

   ----------------
   -- Yield_Slot --
   ----------------

   procedure Yield_Slot (Slot : Valid_Slot; Value : T) is
   begin
      GS.Set_State (Slot, Yielding);
      Values (Slot) := Value;
      GC.Return_To_Caller (Slot);
   end Yield_Slot;

   -----------
   -- Yield --
   -----------

   procedure Yield (G : Generator; Value : T) is
      pragma SPARK_Mode (Off);
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
      Res : GC.Result;
   begin
      --  The affinity check and the switch both live in Generator_Coros
      --  now, where they are analysed. What is left here is turning its
      --  refusal into this instantiation's own exception -- which is exactly
      --  why the refusal comes back as a status code rather than as a raise:
      --  Generator_Error is declared inside this generic, so a non-generic
      --  package cannot name it.
      GC.Resume (Slot, Res);

      if Res /= Success then
         raise Generator_Error with "generator belongs to another task";
      end if;
   end Advance;

   --------------
   -- Has_Next --
   --------------

   function Has_Next (G : Generator) return Boolean is
      pragma SPARK_Mode (Off);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case GS.State_Of (G.Slot) is
         when Waiting =>
            null;
         when Yielding =>
            return True;
         when Returning =>
            return False;
      end case;

      Advance (G.Slot);

      case GS.State_Of (G.Slot) is
         when Waiting =>
            raise Program_Error with "Unreachable state";
         when Yielding =>
            return True;
         when Returning =>
            --  We do not want to rely on usual coroutine completion mechanism
            --  (see Run), so kill completed generators as soon as possible.

            GC.Kill_If_Alive (G.Slot);
            return False;
      end case;
   end Has_Next;

   ----------
   -- Next --
   ----------

   function Next (G : Generator) return T is
      pragma SPARK_Mode (Off);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case GS.State_Of (G.Slot) is
         when Waiting | Returning =>
            raise Program_Error with "Unreachable state";
         when Yielding =>
            GS.Set_State (G.Slot, Waiting);
            return Values (G.Slot);
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
      pragma SPARK_Mode (Off);
      pragma Unreferenced (C);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case GS.State_Of (G.Slot) is
         when Waiting =>
            null;
         when Yielding =>
            GS.Set_State (G.Slot, Waiting);
         when Returning =>
            raise Program_Error with "Unreachable state";
      end case;
      return G.First;
   end Next;

   -----------------
   -- Has_Element --
   -----------------

   function Has_Element (G : Generator; C : Cursor_Type) return Boolean is
      pragma SPARK_Mode (Off);
      pragma Unreferenced (C);
   begin
      return G.Has_Next;
   end Has_Element;

   -------------
   -- Element --
   -------------

   function Element (G : Generator; C : Cursor_Type) return T is
      pragma SPARK_Mode (Off);
      pragma Unreferenced (C);
   begin
      if not Live (G) then
         raise Generator_Error with "uninitialized generator";
      end if;

      case GS.State_Of (G.Slot) is
         when Returning =>
            raise Program_Error with "Unreachable state";

         when Waiting | Yielding =>

            --  Switch to Waiting state so that we don't require a call to Next
            --  in order to go to the next element. This is useful to resume
            --  iteration with a FOR loop.

            GS.Set_State (G.Slot, Waiting);

            return Values (G.Slot);
      end case;
   end Element;

end Generators;
