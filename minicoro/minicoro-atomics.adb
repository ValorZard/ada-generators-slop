--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

pragma Warnings (Off);
with System.Atomic_Operations.Integer_Arithmetic;
pragma Warnings (On);
--  Ada 2022, not a GNAT private unit. The warnings are suppressed for the
--  same reason Coroutines does it around System.Soft_Links: -gnatwae would
--  otherwise turn the "internal unit withed by a user program" note into an
--  error.

package body Minicoro.Atomics with SPARK_Mode => Off is

   package Ops is new System.Atomic_Operations.Integer_Arithmetic (Impl);

   -----------
   -- Value --
   -----------

   function Value (Item : Counter) return Natural is (Natural (Item.N));

   -----------
   -- Reset --
   -----------

   procedure Reset (Item : in out Counter; To : Natural) is
   begin
      Item.N := Impl (To);
   end Reset;

   ---------------
   -- Increment --
   ---------------

   procedure Increment (Item : in out Counter) is
      Unused : Impl;
   begin
      --  The guard is not part of the atomic operation, so in principle two
      --  tasks could both see Impl'Last - 1 and both add. Reaching that needs
      --  Natural'Last simultaneous handles on one coroutine -- two billion of
      --  them, at four bytes each -- and the alternative is a
      --  compare-and-swap retry loop for a case that cannot occur. The
      --  saturation itself is not the interesting part of this subprogram;
      --  the add is.
      if Item.N < Impl'Last then
         Unused := Ops.Atomic_Fetch_And_Add (Item.N, 1);
      end if;
   end Increment;

   ---------------
   -- Decrement --
   ---------------

   procedure Decrement (Item : in out Counter; Was_Last : out Boolean) is
      Before : Impl;
   begin
      if Item.N = 0 then
         Was_Last := False;
         return;
      end if;

      --  Fetch-and-subtract, and the answer comes from what it returned
      --  rather than from re-reading Item.N. That is the difference that
      --  makes this correct: if two tasks drop the last two references, both
      --  would see zero on a re-read and both would try to free the slot,
      --  whereas exactly one of them gets Before = 1 here.
      Before   := Ops.Atomic_Fetch_And_Subtract (Item.N, 1);
      Was_Last := Before = 1;
   end Decrement;

end Minicoro.Atomics;
