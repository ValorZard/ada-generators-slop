with Ada.Text_IO; use Ada.Text_IO;

with Minicoro;

package body Coro_Demo is

   use type Minicoro.Result;
   use type Minicoro.State;

   Failures : Natural := 0;

   procedure Check (Cond : Boolean; What : String);

   -----------
   -- Check --
   -----------

   procedure Check (Cond : Boolean; What : String) is
   begin
      if not Cond then
         Failures := Failures + 1;
         Put_Line ("  FAIL: " & What);
      end if;
   end Check;

   --------------
   -- Producer --
   --------------

   Inner : Minicoro.Coroutine_Id := Minicoro.No_Coroutine;

   procedure Counter (Self : Minicoro.Valid_Id) with Convention => C;
   procedure Producer (Self : Minicoro.Valid_Id) with Convention => C;

   procedure Counter (Self : Minicoro.Valid_Id) is
      Pushed, Yielded : Minicoro.Result;
   begin
      --  A nested coroutine: resumed from inside Producer, so yielding must
      --  return to Producer and not to the main context.
      for I in 1 .. 3 loop
         Minicoro.Push (Self, [1 => Minicoro.Byte (100 + I)], Pushed);
         pragma Assert (Pushed = Minicoro.Success);
         Minicoro.Yield (Self, Yielded);
         pragma Assert (Yielded = Minicoro.Success);
      end loop;
   end Counter;

   procedure Producer (Self : Minicoro.Valid_Id) is
      Res : Minicoro.Result;
      Buf : Minicoro.Byte_Array (1 .. 1);
   begin
      for I in 1 .. 5 loop
         Minicoro.Push (Self, [1 => Minicoro.Byte (I)], Res);
         pragma Assert (Res = Minicoro.Success);
         Minicoro.Yield (Self, Res);
         pragma Assert (Res = Minicoro.Success);
      end loop;

      --  Now drive the inner coroutine and forward what it produces.
      while Minicoro.Status (Inner) = Minicoro.Suspended loop
         Minicoro.Resume (Inner, Res);
         pragma Assert (Res = Minicoro.Success);
         if Minicoro.Bytes_Stored (Inner) > 0 then
            Minicoro.Pop (Inner, Buf, Res);
            pragma Assert (Res = Minicoro.Success);
            Minicoro.Push (Self, Buf, Res);
            pragma Assert (Res = Minicoro.Success);
            Minicoro.Yield (Self, Res);
            pragma Assert (Res = Minicoro.Success);
         end if;
      end loop;
   end Producer;

   ---------
   -- Run --
   ---------

   procedure Run is
      Co  : Minicoro.Coroutine_Id;
      Res : Minicoro.Result;
      Buf : Minicoro.Byte_Array (1 .. 1);
      Got : String (1 .. 64) := (others => ' ');
      N   : Natural := 0;
   begin
      Minicoro.Create (Inner, Counter'Access, Res => Res);
      Check (Res = Minicoro.Success, "create inner");

      Minicoro.Create (Co, Producer'Access, Res => Res);
      Check (Res = Minicoro.Success, "create producer");
      Check (Minicoro.Status (Co) = Minicoro.Suspended, "starts suspended");
      Check (Minicoro.Bytes_Stored (Co) = 0, "starts empty");

      while Minicoro.Status (Co) = Minicoro.Suspended loop
         Minicoro.Resume (Co, Res);
         Check (Res = Minicoro.Success, "resume succeeds");

         if Minicoro.Bytes_Stored (Co) > 0 then
            Minicoro.Pop (Co, Buf, Res);
            Check (Res = Minicoro.Success, "pop succeeds");
            N := N + 1;
            declare
               Img : constant String := Natural'Image (Natural (Buf (1)));
            begin
               Got (N * 4 - 3 .. N * 4 - 3 + Img'Length - 1) := Img;
            end;
         end if;
      end loop;

      Put_Line ("  yielded values:" & Got (1 .. N * 4));
      Check (Minicoro.Status (Co) = Minicoro.Dead, "producer ends dead");
      Check (Minicoro.Status (Inner) = Minicoro.Dead, "inner ends dead");
      Check (N = 8, "eight values (5 own + 3 nested), got" & N'Image);

      --  Storage bounds: a push that does not fit must be refused and must
      --  leave the buffer alone.
      declare
         Big : constant Minicoro.Byte_Array (1 .. Minicoro.Max_Storage + 1) :=
           [others => 0];
         C2  : Minicoro.Coroutine_Id;
      begin
         Minicoro.Create (C2, Counter'Access, Res => Res);
         Minicoro.Push (C2, Big, Res);
         Check (Res = Minicoro.Not_Enough_Space, "oversized push refused");
         Check (Minicoro.Bytes_Stored (C2) = 0,
                "refused push changed nothing");

         Minicoro.Pop (C2, Buf, Res);
         Check (Res = Minicoro.Not_Enough_Space, "pop from empty refused");

         Minicoro.Destroy (C2, Res);
         Check (Res = Minicoro.Success, "destroy suspended coroutine");
         Check (not Minicoro.Is_Allocated (C2), "slot released");
      end;

      Minicoro.Destroy (Co, Res);
      Check (Res = Minicoro.Success, "destroy producer");
      Minicoro.Destroy (Inner, Res);
      Check (Res = Minicoro.Success, "destroy inner");

      if Failures = 0 then
         Put_Line ("PASS: coroutine core");
      else
         Put_Line ("FAIL:" & Failures'Image & " check(s)");
      end if;
   end Run;

end Coro_Demo;
