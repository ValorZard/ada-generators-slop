--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  A page of memory that is written once and then made executable.
--
--  Minicoro.Machine_Code generates the switch routine as ordinary data; this
--  is what turns that data into something the processor will jump to. The
--  page is writable only while it is being filled and is flipped to
--  read+execute before any address in it is handed out, so the process never
--  holds memory that is simultaneously writable and executable.
--
--  Not SPARK: this is operating-system territory.

with System;

with Minicoro.Machine_Code;

package Minicoro.Code_Page with SPARK_Mode => Off is

   type Page is private;

   procedure Allocate (P : in out Page; Size : Positive; Ok : out Boolean);
   --  Reserve at least Size bytes, writable and not yet executable.

   procedure Write
     (P      : in out Page;
      Offset : Natural;
      Data   : Machine_Code.Code);
   --  Copy Data into the page. Only legal before Seal.

   procedure Seal (P : in out Page; Ok : out Boolean);
   --  Drop write permission, add execute permission, and flush the
   --  instruction cache. After this the page is immutable.

   function Is_Sealed (P : Page) return Boolean;

   function Address_At (P : Page; Offset : Natural) return System.Address
     with Pre => Is_Sealed (P);
   --  Address of a byte in the sealed page, suitable for conversion to a
   --  subprogram access.

   procedure Free (P : in out Page);

private

   type Page is record
      Base   : System.Address := System.Null_Address;
      Size   : Natural        := 0;
      Sealed : Boolean        := False;
   end record;

end Minicoro.Code_Page;
