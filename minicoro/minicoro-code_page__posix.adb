--  Copyright (C) 2026, ada-generators contributors
--  SPDX-License-Identifier: Apache-2.0

--  POSIX implementation of Minicoro.Code_Page, on mmap/mprotect.

with Interfaces.C;
with System.Storage_Elements;

package body Minicoro.Code_Page with SPARK_Mode => Off is

   use System.Storage_Elements;
   use type Interfaces.C.int;
   use type System.Address;

   subtype C_Int is Interfaces.C.int;
   subtype Size_T is Interfaces.C.size_t;

   PROT_READ  : constant C_Int := 1;
   PROT_WRITE : constant C_Int := 2;
   PROT_EXEC  : constant C_Int := 4;

   MAP_PRIVATE : constant C_Int := 16#02#;

   function On_Linux return Boolean;

   function MAP_ANONYMOUS return C_Int is
     (if On_Linux then 16#20# else 16#1000#);
   --  0x20 on Linux, 0x1000 on the BSDs and macOS.

   MAP_FAILED : constant System.Address :=
     To_Address (Integer_Address'Last);
   --  What mmap returns on failure: (void*)-1, the all-ones address, not
   --  null. Integer_Address is modular ("type Integer_Address is mod
   --  Memory_Size" in s-stoele.ads), so 'Last is that value. Spelling it
   --  System'To_Address (-1) instead means passing a negative literal to a
   --  modular type: the compiler folds it to the same address, but
   --  GNATprove's frontend reports it as a Constraint_Error that will be
   --  raised at run time -- on the success path of every Allocate.

   function mmap
     (Addr   : System.Address;
      Length : Size_T;
      Prot   : C_Int;
      Flags  : C_Int;
      Fd     : C_Int;
      Offset : Long_Integer) return System.Address
     with Import, Convention => C, External_Name => "mmap";

   function munmap (Addr : System.Address; Length : Size_T) return C_Int
     with Import, Convention => C, External_Name => "munmap";

   function mprotect
     (Addr : System.Address; Length : Size_T; Prot : C_Int) return C_Int
     with Import, Convention => C, External_Name => "mprotect";

   --------------
   -- On_Linux --
   --------------

   function On_Linux return Boolean is
      T : constant String := Standard'Target_Name;
   begin
      for I in T'First .. T'Last - 4 loop
         if T (I .. I + 4) = "linux" then
            return True;
         end if;
      end loop;
      return False;
   end On_Linux;

   --------------
   -- Allocate --
   --------------

   procedure Allocate (P : in out Page; Size : Positive; Ok : out Boolean) is
      Addr : System.Address;
   begin
      Addr := mmap
        (System.Null_Address, Size_T (Size),
         PROT_READ + PROT_WRITE, MAP_PRIVATE + MAP_ANONYMOUS, -1, 0);

      if Addr = System.Null_Address or else Addr = MAP_FAILED then
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
      I : Storage_Offset := 1;
   begin
      pragma Assert (not P.Sealed);
      pragma Assert (Offset + Data'Length <= P.Size);

      for B of Data loop
         Target (I) := Storage_Element (B);
         I := I + 1;
      end loop;
   end Write;

   ----------
   -- Seal --
   ----------

   procedure Seal (P : in out Page; Ok : out Boolean) is
   begin
      if mprotect (P.Base, Size_T (P.Size), PROT_READ + PROT_EXEC) /= 0 then
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

   ----------------
   -- Address_At --
   ----------------

   function Address_At (P : Page; Offset : Natural) return System.Address is
     (P.Base + Storage_Offset (Offset));

   ----------
   -- Free --
   ----------

   procedure Free (P : in out Page) is
      Ignored : C_Int;
   begin
      if P.Base /= System.Null_Address then
         Ignored := munmap (P.Base, Size_T (P.Size));
      end if;
      P := (Base => System.Null_Address, Size => 0, Sealed => False);
   end Free;

end Minicoro.Code_Page;
