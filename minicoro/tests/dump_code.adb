--  Dumps the generated machine code as hex, one byte per line, so it can be
--  diffed against minicoro's reference byte tables.

with Ada.Command_Line;
with Ada.Text_IO;

with Minicoro.Machine_Code;

procedure Dump_Code is
   use Ada.Text_IO;
   use Minicoro.Machine_Code;

   Hex : constant String := "0123456789abcdef";

   procedure Put_Code (C : Code);

   procedure Put_Code (C : Code) is
   begin
      for B of C loop
         Put_Line ("0x" & Hex (Natural (B) / 16 + 1)
                        & Hex (Natural (B) mod 16 + 1));
      end loop;
   end Put_Code;

   Which : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Ada.Command_Line.Argument (1) else "");
begin
   if Which = "win64-switch" then
      Put_Code (Switch_Code (Win64));
   elsif Which = "sysv-switch" then
      Put_Code (Switch_Code (SysV));
   elsif Which = "win64-wrap" then
      Put_Code (Wrap_Main_Code (Win64));
   elsif Which = "sysv-wrap" then
      Put_Code (Wrap_Main_Code (SysV));
   elsif Which = "facts" then
      Put_Line ("win64 total   =" & Natural'Image
                  (Total_Length (Switch_Template (Win64))));
      Put_Line ("win64 disp    =" & Displacement'Image
                  (Switch_Displacement (Win64)));
      Put_Line ("win64 ret off =" & Natural'Image
                  (Offset_Of (Switch_Template (Win64), Ret_Position (Win64))));
      Put_Line ("win64 theorem = "
                  & Boolean'Image (Resume_Point_Correct (Win64)));
      Put_Line ("sysv  total   =" & Natural'Image
                  (Total_Length (Switch_Template (SysV))));
      Put_Line ("sysv  disp    =" & Displacement'Image
                  (Switch_Displacement (SysV)));
      Put_Line ("sysv  ret off =" & Natural'Image
                  (Offset_Of (Switch_Template (SysV), Ret_Position (SysV))));
      Put_Line ("sysv  theorem = "
                  & Boolean'Image (Resume_Point_Correct (SysV)));
   else
      Put_Line (Standard_Error, "usage: dump_code "
                & "win64-switch|sysv-switch|win64-wrap|sysv-wrap|facts");
      Ada.Command_Line.Set_Exit_Status (2);
   end if;
end Dump_Code;
