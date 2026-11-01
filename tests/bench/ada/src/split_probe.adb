--  Probe: why is the hand-written frame split slow at -O2 with checks on?  Same loop, three ways to move the body.
with Ada.Command_Line; with Ada.Real_Time; with Ada.Streams; with Ada.Streams.Stream_IO; with Ada.Text_IO; with Interfaces;
with Gw_Timing;
procedure Split_Probe is
   use Interfaces; use Ada.Text_IO;
   type Octets is array (Positive range <>) of Unsigned_8;
   type Acc is access Octets;
   F    : Ada.Streams.Stream_IO.File_Type;
   N    : Natural;
   Buf  : Acc;
   Sink : Unsigned_64 := 0;
   Mode : Natural := 0;

   procedure Run is
      Scratch : Octets (1 .. 4096);
      Pos : Positive := Buf'First;
      Len, Sh, Body_Len, Id_Start : Natural;
      B : Unsigned_8;
      Cnt, Bb : Unsigned_64 := 0;
      Dummy : Unsigned_8 := 0;
   begin
      Scratch := (others => 0);
      while Pos <= Buf'Last loop
         Len := 0; Sh := 0;
         loop
            B := Buf (Pos); Pos := Pos + 1;
            Len := Len + Natural (Shift_Left (Unsigned_32 (B and 16#7F#), Sh));
            exit when (B and 16#80#) = 0;
            Sh := Sh + 7;
         end loop;
         Id_Start := Pos;
         loop
            B := Buf (Pos); Pos := Pos + 1;
            exit when (B and 16#80#) = 0;
         end loop;
         Body_Len := Len - (Pos - Id_Start);
         case Mode is
            when 0 => Scratch (1 .. Body_Len) := Buf (Pos .. Pos + Body_Len - 1);          --  slice assignment
            when 1 => for K in 0 .. Body_Len - 1 loop Scratch (K + 1) := Buf (Pos + K); end loop;   --  explicit loop
            when others => null;                                                              --  no copy
         end case;
         Dummy := Dummy xor Scratch (1);
         Pos := Pos + Body_Len;
         Bb := Bb + Unsigned_64 (Body_Len); Cnt := Cnt + 1;
      end loop;
      Sink := Bb + Cnt + Unsigned_64 (Dummy);
   end Run;
   function T is new Gw_Timing (Run);
begin
   Ada.Streams.Stream_IO.Open (F, Ada.Streams.Stream_IO.In_File, Ada.Command_Line.Argument (1) & "/frames.bin");
   N := Natural (Ada.Streams.Stream_IO.Size (F));
   declare
      Tmp : constant access Ada.Streams.Stream_Element_Array := new Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (N));
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Read (F, Tmp.all, Last);
      Buf := new Octets (1 .. N);
      for I in 1 .. N loop Buf (I) := Unsigned_8 (Tmp (Ada.Streams.Stream_Element_Offset (I))); end loop;
   end;
   for M in 0 .. 2 loop
      Mode := M;
      declare D : constant Duration := T (10); begin
         Put_Line ((case M is when 0 => "slice assignment ", when 1 => "explicit byte loop", when others => "no copy          ") & "  frames/s =" & Integer'Image (Integer (200_000.0 / Long_Float (D))));
      end;
   end loop;
end Split_Probe;
