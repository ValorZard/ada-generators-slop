--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  The coroutine plumbing of a generator slot: the coroutine that runs it,
--  the coroutine it must return into, and the control transfers between
--  them. Everything Generators does with Coroutines that does not depend on
--  the type being yielded.
--
--  This is the second half of the split Generator_Slots started, and it
--  exists for the same reason: GNATprove analyses instantiations rather than
--  generic units, so anything left inside Generators is never read. Coro and
--  Caller were the last two T-independent fields in Generator_Record.
--  Hoisted out here they are checked like any other package, and with them
--  the affinity guard, the resume/return pair and the kill-on-release.
--
--  What stayed behind in Generators is now only what genuinely depends on
--  the formal type: the yielded values and the user delegate.
--
--  Two shapes here are deliberate and match the layers below:
--
--  * Control transfer reports refusal through Result rather than by raising,
--    as Minicoro does with Wrong_Task. The exception belongs to the generic
--    -- Generator_Error is declared inside Generators, so each instantiation
--    has its own -- and a status code lets the analysed half stay free of
--    it. Resume and Return_To_Caller still carry Exceptional_Cases, because
--    a switch legitimately propagates whatever the generator died of.
--
--  * Detach and Adopt do *not* translate Coroutine_Error. Generators catches
--    it and re-raises Generator_Error carrying the same message, and that
--    message is worth keeping, so it is let through rather than flattened
--    into a Result.

with Coroutines;
with Generator_Slots;

package Generator_Coros with
  SPARK_Mode     => On,
  Abstract_State => Plumbing,
  Initializes    => Plumbing
is

   subtype Slot_Id    is Generator_Slots.Slot_Id;
   subtype Valid_Slot is Generator_Slots.Valid_Slot;

   type Result is
     (Success,
      --  The transfer happened.

      Wrong_Task
      --  The calling task does not own this generator, so it may not
      --  advance it. Generators turns this into Generator_Error.
     );

   ---------------
   -- Observers --
   ---------------

   --  None of these transfers control, so none of them checks affinity. That
   --  is the line the whole tree draws: reading is unguarded, control
   --  transfer is not.

   function Is_Alive (S : Valid_Slot) return Boolean;

   function Owned_Here (S : Valid_Slot) return Boolean;

   function Is_Detached (S : Valid_Slot) return Boolean;

   ---------------
   -- Lifecycle --
   ---------------

   procedure Set_Coro (S : Valid_Slot; C : Coroutines.Coroutine);
   --  Install the coroutine that will run this slot.

   procedure Spawn (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Start it. Propagates Coroutine_Error if the slot has no coroutine or
   --  it belongs to another task.

   procedure Note_Caller (S : Valid_Slot);
   --  Record the currently running coroutine as the one this slot returns
   --  into. Uses the procedure form of Current_Coroutine: the function form
   --  is SPARK_Mode => Off and contagious to its caller.

   procedure Clear_Caller (S : Valid_Slot);
   --  Forget it again.

   procedure Kill_If_Alive (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Kill the slot's coroutine if it is still running. A completed
   --  generator is killed as soon as it is noticed rather than left to the
   --  usual coroutine completion path; see Generators.Run.

   procedure Clear (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Kill the coroutine if alive, then drop both handles. What Generators
   --  does when the last reference to a slot goes.
   --
   --  No `Post => not Is_Alive (S)`, though it is true and was tried: it
   --  needs the prover to know that Coroutines.Null_Coroutine is not alive,
   --  and nothing in that package's interface says so. Alive's body is an
   --  expression function over Alive_Slot, visible only inside Coroutines,
   --  and Coroutine's full view is in a private part, so a postcondition on
   --  Alive could not name the slot either. Stating it would mean widening
   --  Coroutines' interface to serve this one caller, which is a worse
   --  trade than leaving the property unstated.

   ----------------------
   -- Control transfer --
   ----------------------

   procedure Resume (S : Valid_Slot; Res : out Result)
     with Exceptional_Cases => (others => True);
   --  Note the caller and switch into the generator, which is what advancing
   --  one means. Res is Wrong_Task, and nothing happens, if the calling task
   --  does not own it.
   --
   --  Checked here rather than left to Coroutines.Switch, which would raise
   --  Coroutine_Error and let it out of an iteration primitive -- the one
   --  place in Generators where the exception a caller sees would not be
   --  Generator_Error. It cannot be done by wrapping the switch in a handler
   --  either: that switch legitimately propagates whatever the generator
   --  died of, and turning all of that into Generator_Error would swallow
   --  the user's own exceptions.

   procedure Return_To_Caller (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Switch back to whoever last resumed this slot. Used both by Yield and
   --  by the end of Run, which deliberately does not fall back on the usual
   --  coroutine completion path: it must return to the last coroutine that
   --  invoked the generator, not to the generator's parent.

   --------------
   -- Affinity --
   --------------

   procedure Detach (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Give the slot's coroutine up. Propagates Coroutine_Error, which
   --  Generators re-raises as Generator_Error carrying the same message.

   procedure Adopt (S : Valid_Slot)
     with Exceptional_Cases => (others => True);
   --  Take it. Propagates Coroutine_Error, as Detach does.

end Generator_Coros;
