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
--  SPARK. The operating system calls are imported subprograms, which SPARK
--  models as having no global effects -- see the note on their Global
--  contracts in the bodies. Everything this package does with the page
--  itself is analysed.

with System;

with Minicoro.Machine_Code;

package Minicoro.Code_Page with SPARK_Mode is

   type Page is private with
     Default_Initial_Condition =>
       not Is_Sealed (Page) and then Size_Of (Page) = 0;

   function Is_Sealed (P : Page) return Boolean with Global => null;

   function Size_Of (P : Page) return Natural with Global => null;
   --  How many bytes Allocate reserved. Zero before it succeeds. Write's
   --  precondition is stated in terms of this, which is what lets the caller
   --  discharge it rather than have the body assert it.

   procedure Allocate (P : in out Page; Size : Positive; Ok : out Boolean)
     with Global => null,
          Post   => (if Ok then Size_Of (P) = Size and then not Is_Sealed (P));
   --  Reserve at least Size bytes, writable and not yet executable.

   procedure Write
     (P      : in out Page;
      Offset : Natural;
      Data   : Machine_Code.Code)
     with Global => null,
          Pre    => not Is_Sealed (P)
                      and then Offset <= Size_Of (P)
                      and then Data'Length <= Size_Of (P) - Offset,
          Post   => Size_Of (P) = Size_Of (P)'Old
                      and then not Is_Sealed (P);
   --  Copy Data into the page. Only legal before Seal.

   procedure Seal (P : in out Page; Ok : out Boolean)
     with Global => null,
          Post   => Size_Of (P) = Size_Of (P)'Old
                      and then (if Ok then Is_Sealed (P));
   --  Drop write permission, add execute permission, and flush the
   --  instruction cache. After this the page is immutable.

   function Address_At (P : Page; Offset : Natural) return System.Address
     with Global => null,
          Pre    => Is_Sealed (P);
   --  Address of a byte in the sealed page, suitable for conversion to a
   --  subprogram access.

   procedure Free (P : in out Page)
     with Global => null,
          Post   => not Is_Sealed (P) and then Size_Of (P) = 0;

private

   type Page is record
      Base   : System.Address := System.Null_Address;
      Size   : Natural        := 0;
      Sealed : Boolean        := False;
   end record;

end Minicoro.Code_Page;
