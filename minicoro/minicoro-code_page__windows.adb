--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  Windows implementation of Minicoro.Code_Page, on VirtualAlloc.

with Interfaces.C;
with System.Storage_Elements;

package body Minicoro.Code_Page with SPARK_Mode is

   use System.Storage_Elements;
   use type Interfaces.C.unsigned;
   use type Interfaces.C.int;
   use type System.Address;

   subtype DWORD  is Interfaces.C.unsigned;
   subtype SIZE_T is Interfaces.C.size_t;
   subtype BOOL   is Interfaces.C.int;

   MEM_COMMIT        : constant DWORD := 16#0000_1000#;
   MEM_RESERVE       : constant DWORD := 16#0000_2000#;
   MEM_RELEASE       : constant DWORD := 16#0000_8000#;
   PAGE_READWRITE    : constant DWORD := 16#0000_0004#;
   PAGE_EXECUTE_READ : constant DWORD := 16#0000_0020#;

   --  ASSUMPTION. Global => null says these touch no Ada object, which is
   --  what makes the rest of this package analysable. It is a statement about
   --  the Ada state SPARK reasons over, not about the process: they plainly
   --  change the address space. Without it GNATprove assumes the same thing
   --  silently and says so as a warning on every call.

   function VirtualAlloc
     (Addr       : System.Address;
      Size       : SIZE_T;
      Alloc_Type : DWORD;
      Protect    : DWORD) return System.Address
     with Import, Convention => Stdcall, External_Name => "VirtualAlloc",
          Global => null;

   function VirtualFree
     (Addr      : System.Address;
      Size      : SIZE_T;
      Free_Type : DWORD) return BOOL
     with Import, Convention => Stdcall, External_Name => "VirtualFree",
          Global => null;

   function VirtualProtect
     (Addr        : System.Address;
      Size        : SIZE_T;
      New_Protect : DWORD;
      Old_Protect : access DWORD) return BOOL
     with Import, Convention => Stdcall, External_Name => "VirtualProtect",
          Global => null;

   function GetCurrentProcess return System.Address
     with Import, Convention => Stdcall, External_Name => "GetCurrentProcess",
          Global => null;

   function FlushInstructionCache
     (Process : System.Address;
      Base    : System.Address;
      Size    : SIZE_T) return BOOL
     with Import, Convention => Stdcall,
          External_Name => "FlushInstructionCache",
          Global => null;

   --------------
   -- Allocate --
   --------------

   procedure Allocate (P : in out Page; Size : Positive; Ok : out Boolean) is
      Addr : System.Address;
   begin
      Addr := VirtualAlloc
        (System.Null_Address, SIZE_T (Size),
         MEM_COMMIT + MEM_RESERVE, PAGE_READWRITE);

      if Addr = System.Null_Address then
         Ok := False;
         return;
      end if;

      P := (Base => Addr, Size => Size, Sealed => False);
      Ok := True;
   end Allocate;

   -----------
   -- Write --
   -----------

   procedure Write
     (P      : in out Page;
      Offset : Natural;
      Data   : Machine_Code.Code)
   is
      Target : Storage_Array (1 .. Storage_Offset (Data'Length))
        with Import, Address => P.Base + Storage_Offset (Offset);
   begin
      for I in 0 .. Data'Length - 1 loop
         Target (Storage_Offset (I) + 1) :=
           Storage_Element (Data (Data'First + I));
      end loop;
   end Write;

   ----------
   -- Seal --
   ----------

   procedure Seal (P : in out Page; Ok : out Boolean) is
      Old : aliased DWORD := 0;

      Old_Ptr : constant access DWORD := Old'Access;
      --  Hoisted out of the call below: SPARK does not yet accept 'Access of
      --  an ownership type anywhere but an assignment, object declaration or
      --  return statement.

      Prot_Ok : constant BOOL :=
        VirtualProtect (P.Base, SIZE_T (P.Size), PAGE_EXECUTE_READ, Old_Ptr);
   begin
      if Prot_Ok = 0 then
         Ok := False;
         return;
      end if;

      if FlushInstructionCache
           (GetCurrentProcess, P.Base, SIZE_T (P.Size)) = 0
      then
         Ok := False;
         return;
      end if;

      P.Sealed := True;
      Ok := True;
   end Seal;

   ---------------
   -- Is_Sealed --
   ---------------

   function Is_Sealed (P : Page) return Boolean is (P.Sealed);

   -------------
   -- Size_Of --
   -------------

   function Size_Of (P : Page) return Natural is (P.Size);

   ----------------
   -- Address_At --
   ----------------

   function Address_At (P : Page; Offset : Natural) return System.Address is
     (P.Base + Storage_Offset (Offset));

   ----------
   -- Free --
   ----------

   procedure Free (P : in out Page) is
      Ignored : BOOL;
   begin
      if P.Base /= System.Null_Address then
         Ignored := VirtualFree (P.Base, 0, MEM_RELEASE);
      end if;
      P := (Base => System.Null_Address, Size => 0, Sealed => False);
   end Free;

end Minicoro.Code_Page;
