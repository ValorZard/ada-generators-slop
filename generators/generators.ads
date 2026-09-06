--  Copyright (C) 2014-2022, Pierre-Marie de Rodat
--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

pragma Extensions_Allowed (On);
--  For the Finalizable aspect below, as in Coroutines. See the header of
--  coroutines.ads.

--  NOT SPARK -- but restructured as though it were, with the same two changes
--  Coroutines needed: a pool of indices instead of a graph of ref-counted
--  pointers, and GNAT's Finalizable aspect instead of
--  Ada.Finalization.Controlled. Two facts stand in the way of the mode
--  actually being On, and neither is about effort.
--
--  The caveat: **most of the iteration interface has to stay outside SPARK,
--  and no amount of restructuring changes that.** Has_Next, Next, Element and
--  Has_Element all advance the generator, which means writing the pool; and a
--  SPARK function may not have an output global (E0005). They cannot become
--  procedures either, because the Iterable aspect fixes their profiles, and
--  `for X of G` is the interface this package exists to provide. A generator
--  is a stateful cursor driven by functions, which is precisely the shape
--  SPARK rules out.
--
--  What is analysed is the part underneath: the slot lifecycle, the reference
--  counting and the delegate ownership -- the same part that was worth
--  proving in Coroutines, and for the same reason.
--
--  And a second, harder fact, which is why this package is Off rather than
--  On: **no SPARK unit can instantiate it, so nothing here can ever be
--  checked.** GNATprove analyses generic instantiations, never generic units;
--  and an instantiation from SPARK is itself rejected, because the Iterable
--  aspect above names Next, Has_Element and Element, which are Off:
--
--    error: instantiation error at generators.ads:51
--      "Next" is not allowed in SPARK (due to entity declared with
--       SPARK_Mode Off)
--
--  Those three have to be Off (they advance the generator, so they write the
--  pool), and Iterable has to name them (that is what `for X of G` compiles
--  to). The two requirements are irreconcilable, so the mode is Off and says
--  so rather than claiming an analysis that cannot happen.
--
--  The rewrite underneath is kept anyway, and is worth having on its own:
--  it removes the last Ada.Finalization.Controlled types from the tree,
--  matches Coroutines slot for slot, and fixes a reference-counting
--  asymmetry -- the old Adjust bumped weak handles while Finalize declined
--  to drop them, leaking a count per copy.

generic
   type T is private;
package Generators with SPARK_Mode => Off is

   pragma Elaborate_Body;

   --  This package provides support for creating generators

   --  Generators are procedures that return ("yield") multiple results
   --  incrementally. This package provides a type to hold ref-counted
   --  generators and an interface to implement the actual generator
   --  procedure.

   Max_Generators : constant := 128;
   --  How many generator records may exist at once, live or not. As with
   --  Coroutines.Max_Coroutines, a slot is held for as long as any handle
   --  names it.

   type Generator is tagged private
     with Iterable => (First       => First,
                       Next        => Next,
                       Has_Element => Has_Element,
                       Element     => Element);
   --  Ref-counted generator that yields T values. Use the Create constructor
   --  before using it, or assign another initialized generator to it.
   --  All primitives expect initialized generators and will raise a
   --  Constraint_Error if provided uninitialized ones.

   Null_Generator : constant Generator;

   function Is_Null (G : Generator) return Boolean;

   type Cursor_Type is null record;
   --  Cursor type used in the generator iteration interface. Due to the nature
   --  of generators, cursors do not hold any state: only the generator does.
   --  Hence, iteration on a generator is a one-way process only.

   type Delegate is abstract tagged null record;
   procedure Generate (D : in out Delegate; G : Generator'Class) is abstract;
   --  User code to run as a generator. Inside a generator, the only Generator
   --  primitive that is valid to invoke is Yield. When it completes, all
   --  iterations on it will finish. If it aborts with an exception, the
   --  iteration aborts with an exception.
   --
   --  An abstract tagged type rather than an interface, for the reason given
   --  at Coroutines.Delegate: GNAT miscompiles class-wide deallocation of an
   --  interface-rooted object whose specific type has a Finalizable
   --  component, and a user delegate holding a Generator is exactly that.

   type Delegate_Access is access all Delegate'Class;

   Generator_Error : exception;
   --  Exception raised by generator primitives in erroneous cases. Refer to
   --  primitives specifications to learn about these cases.

   function Create (D                  : Delegate_Access;
                    Transfer_Ownership : Boolean := True) return Generator;
   --  Create and return a new generator that will run the D delegate. If
   --  Transfer_Ownership is true, the ownership of D is transfered to the
   --  generator: it will be free'd when nobody refers to the coroutine
   --  anymore; otherwise it is up to the caller to make sure D is free'd while
   --  the coroutine is not running anymore. Creating a generator starts the
   --  generation (i.e. the delegate is started here).
   --
   --  Returns Null_Generator if the pool is full. Outside SPARK because a
   --  SPARK function may neither write globals nor propagate an exception,
   --  and constructing a generator does the first; the slot bookkeeping is
   --  factored into Claim_Slot, which is analysed.

   procedure Yield (G : Generator; Value : T);
   --  Yield a value.  Must be called from the Generate procedure only.
   --
   --  Outside SPARK because it is a primitive of a tagged type and switches
   --  coroutines, so it can propagate; SPARK does not accept
   --  Exceptional_Cases on a dispatching operation. The work is in
   --  Yield_Slot, which is analysed.

   -------------------------------
   -- Basic iteration interface --
   -------------------------------

   function Has_Next (G : Generator) return Boolean;
   --  Return whether G has a value to yield. Resume the generator to find out
   --  if needed. Outside SPARK: advancing the generator writes the pool, and
   --  a SPARK function may not.

   function Next (G : Generator) return T;
   --  Assuming G has a value to yield, return it and go to next iteration.
   --  Outside SPARK, as Has_Next.

   --------------------------------
   -- Iterable aspect primitives --
   --------------------------------

   function First (G : Generator) return Cursor_Type;
   --  Return a cursor. As stated above, all cursors are identical, they hold
   --  no information. The one iteration primitive that changes nothing, and
   --  so the one that is in SPARK.

   function Next (G : Generator; C : Cursor_Type) return Cursor_Type;
   --  Assuming G is not done, resume it to make it yield its next element. As
   --  the generator may stop, one has to check whether it did yield something
   --  before retreiving it with the Element primitive.

   function Has_Element (G : Generator; C : Cursor_Type) return Boolean;
   --  Return whether the last call to Next on G yielded an element

   function Element (G : Generator; C : Cursor_Type) return T;
   --  Assuming Has_Element is true, return the element the last call to Next
   --  on G yielded.

private

   subtype Slot_Id    is Natural range 0 .. Max_Generators;
   subtype Valid_Slot is Slot_Id range 1 .. Max_Generators;

   No_Slot : constant Slot_Id := 0;

   type State_Type is
     (Waiting,
      --  The generator has already yielded or was just created, and is waiting
      --  to be resumed.

      Yielding,
      --  The generator just yielded and is waiting for its caller to get the
      --  value.

      Returning
      --  The generator has not yielded and is done
     );
   --  Describe the execution state of a generator

   procedure Bump (G : in out Generator);
   procedure Drop (G : in out Generator);
   --  Reference counting, as the Finalizable aspect calls it. Both ignore a
   --  weak handle: Weak means "names a generator without keeping it alive",
   --  and the old Controlled version bumped weak handles while declining to
   --  drop them, which leaked a count for every copy.

   type Generator is tagged record
      Slot : Slot_Id := No_Slot;

      Weak : Boolean := False;
      --  Whether finalization should trigger reference counting and garbage
      --  collection.
   end record
     with Finalizable => (Adjust   => Bump,
                          Finalize => Drop);

   Null_Generator : constant Generator := (Slot => No_Slot, Weak => False);

end Generators;
