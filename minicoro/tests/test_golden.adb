--  Locks the generated machine code to minicoro's own byte tables.
--
--  Minicoro.Machine_Code derives the switch routine from an instruction
--  encoder rather than transcribing it, so this test is what says the
--  derivation actually lands on the code minicoro ships -- including the
--  RIP-relative displacement that minicoro writes by hand as 0x13e and that
--  we compute.

with Ada.Text_IO; use Ada.Text_IO;

with Golden_Win64;
with Minicoro.Machine_Code;

procedure Test_Golden is

   use Minicoro.Machine_Code;
   use type Golden_Win64.Ref_Byte;

   Failures : Natural := 0;

   procedure Compare (What : String;
                      Got  : Code;
                      Ref  : Golden_Win64.Ref_Bytes);

   -------------
   -- Compare --
   -------------

   procedure Compare (What : String;
                      Got  : Code;
                      Ref  : Golden_Win64.Ref_Bytes)
   is
   begin
      if Got'Length /= Ref'Length then
         Put_Line ("FAIL " & What & ": length" & Got'Length'Image
                   & ", expected" & Ref'Length'Image);
         Failures := Failures + 1;
         return;
      end if;

      for I in 1 .. Got'Length loop
         if Golden_Win64.Ref_Byte (Got (Got'First + I - 1))
              /= Ref (Ref'First + I - 1)
         then
            Put_Line ("FAIL " & What & ": byte" & I'Image & " differs");
            Failures := Failures + 1;
            return;
         end if;
      end loop;

      Put_Line ("ok   " & What & " (" & Got'Length'Image & " bytes)");
   end Compare;

begin
   Compare ("win64 switch routine", Switch_Code (Win64),
            Golden_Win64.Switch_Ref);
   Compare ("win64 entry trampoline", Wrap_Main_Code (Win64),
            Golden_Win64.Wrap_Main_Ref);

   --  The displacement minicoro hard-codes as 0x13e, recomputed from the
   --  assembled listing.
   if Switch_Displacement (Win64) = 16#13E# then
      Put_Line ("ok   win64 resume displacement = 16#13E#, as in minicoro");
   else
      Put_Line ("FAIL win64 displacement is"
                & Switch_Displacement (Win64)'Image);
      Failures := Failures + 1;
   end if;

   --  System V's, which minicoro writes as 0x3d in its inline assembler.
   if Switch_Displacement (SysV) = 16#3D# then
      Put_Line ("ok   sysv resume displacement = 16#3D#, as in minicoro");
   else
      Put_Line ("FAIL sysv displacement is"
                & Switch_Displacement (SysV)'Image);
      Failures := Failures + 1;
   end if;

   --  The proved theorem, evaluated for good measure.
   for ABI in ABI_Kind loop
      if Resume_Point_Correct (ABI) then
         Put_Line ("ok   resume point lands on the RET (" & ABI'Image & ")");
      else
         Put_Line ("FAIL resume point wrong (" & ABI'Image & ")");
         Failures := Failures + 1;
      end if;
   end loop;

   if Failures = 0 then
      Put_Line ("PASS: generated code matches minicoro byte for byte");
   else
      Put_Line ("FAIL:" & Failures'Image & " mismatch(es)");
   end if;
end Test_Golden;
