--  Ada gateway hot-path benchmark: same inputs, logic and RESULT lines as tests/bench/tcl/rust/src/main.rs.
--  Uses the REAL adacraft packages (Varnum, Frame, Packet_Encoder, Zlib) unmodified ("as-is" rows) and hand-written tight loops
--  in Ada ("tight" rows) so the cost of the existing code's structure can be separated from the cost of the language.
--
--  usage: gwbench DATA_DIR        env: REPS (default 5)
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Environment_Variables;
with Ada.Long_Float_Text_IO;
with Ada.Streams;           use Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;           use Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Ada.Command_Line;
with Interfaces;            use Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

with Adacraft.Protocol;     use Adacraft.Protocol;
with Adacraft.Protocol.Varnum;
with Adacraft.Protocol.Frame;
with Adacraft.Protocol.Packet_Encoder;
with Adacraft.Protocol.Zlib;
with Gw_Aes;
with Gw_Conns;
with Gw_Timing;

procedure Gwbench is
   package Pe renames Adacraft.Protocol.Packet_Encoder;
   package Z renames Adacraft.Protocol.Zlib;

   type Octets_Access is access Octets;
   type SE_Access is access Stream_Element_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Octets, Octets_Access);
   procedure Free_SE is new Ada.Unchecked_Deallocation (Stream_Element_Array, SE_Access);
   type Int_Array is array (Positive range <>) of Integer_32;
   type Int_Access is access Int_Array;

   Data_Dir : constant String := Ada.Command_Line.Argument (1);
   Reps : constant Positive :=
     (if Ada.Environment_Variables.Exists ("REPS")
      then Positive'Value (Ada.Environment_Variables.Value ("REPS")) else 5);

   --  ---------------------------------------------------------------- helpers
   function Trim (S : String) return String is (Ada.Strings.Fixed.Trim (S, Ada.Strings.Both));
   function Img (N : Long_Long_Integer) return String is (Trim (Long_Long_Integer'Image (N)));
   function Img (N : Unsigned_64) return String is (Trim (Unsigned_64'Image (N)));
   function Img (D : Duration) return String is (Trim (Duration'Image (D)));

   function File_Size (Path : String) return Natural is
      F : Ada.Streams.Stream_IO.File_Type;
      N : Natural;
   begin
      Ada.Streams.Stream_IO.Open (F, Ada.Streams.Stream_IO.In_File, Path);
      N := Natural (Ada.Streams.Stream_IO.Size (F));
      Ada.Streams.Stream_IO.Close (F);
      return N;
   end File_Size;

   function Read_Octets (Name : String) return Octets_Access is
      Path : constant String := Data_Dir & "/" & Name;
      N    : constant Natural := File_Size (Path);
      R    : constant Octets_Access := new Octets (1 .. N);
      F    : Ada.Streams.Stream_IO.File_Type;
      Tmp  : SE_Access := new Stream_Element_Array (1 .. Stream_Element_Offset (N));
      Last : Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (F, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Read (F, Tmp.all, Last);
      Ada.Streams.Stream_IO.Close (F);
      for I in 1 .. N loop
         R (I) := Octet (Tmp (Stream_Element_Offset (I)));
      end loop;
      Free_SE (Tmp);
      return R;
   end Read_Octets;

   function Read_SE (Name : String) return SE_Access is
      Path : constant String := Data_Dir & "/" & Name;
      N    : constant Natural := File_Size (Path);
      R    : constant SE_Access := new Stream_Element_Array (1 .. Stream_Element_Offset (N));
      F    : Ada.Streams.Stream_IO.File_Type;
      Last : Stream_Element_Offset;
   begin
      Ada.Streams.Stream_IO.Open (F, Ada.Streams.Stream_IO.In_File, Path);
      Ada.Streams.Stream_IO.Read (F, R.all, Last);
      Ada.Streams.Stream_IO.Close (F);
      return R;
   end Read_SE;

   --  expected RESULT lines (oracle from gen_data.py)
   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);
   Expected : String_Sets.Set;

   procedure Load_Expected is
      F : File_Type;
   begin
      Open (F, In_File, Data_Dir & "/expected.txt");
      while not End_Of_File (F) loop
         declare
            L : constant String := Trim (Get_Line (F));
         begin
            if L'Length > 0 then
               Expected.Include (L);
            end if;
         end;
      end loop;
      Close (F);
   end Load_Expected;

   Mismatches : Natural := 0;

   --  Prints the RESULT line and whether it equals the oracle's line.
   procedure Check (Variant, Line : String) is
   begin
      Put_Line ("RESULT " & Line & "   -- " & Variant);
      if Expected.Contains ("RESULT " & Line) then
         Put_Line ("CHECK " & Variant & " OK");
      else
         Put_Line ("CHECK " & Variant & " MISMATCH: RESULT " & Line);
         Mismatches := Mismatches + 1;
      end if;
   end Check;

   procedure Report (Name : String; Best : Duration; Units, Bytes : Long_Long_Integer) is
   begin
      Put_Line ("BENCH " & Name & " " & Img (Best) & " " & Img (Units) & " " & Img (Bytes));
   end Report;

   function Fmt6 (X : Long_Float) return String is
      S : String (1 .. 48);
   begin
      Ada.Long_Float_Text_IO.Put (To => S, Item => X, Aft => 6, Exp => 0);
      return Trim (S);
   end Fmt6;

   --  ---------------------------------------------------------------- inputs
   Varints    : Octets_Access;
   Vals_Raw   : Octets_Access;
   Frames     : Octets_Access;
   Frames_SE  : SE_Access;
   Pos_Bin    : Octets_Access;
   Chunk      : Octets_Access;
   Aes_Expect : Octets_Access;
   Frames_Out : Octets_Access;
   Vals       : constant Int_Access := new Int_Array (1 .. 1_000_000);

   --  sinks keep the optimiser from dropping the work
   S_Count, S_Sum  : Unsigned_64 := 0;
   S_Frames, S_IdSum, S_Body : Unsigned_64 := 0;
   S_Sx : Long_Float := 0.0;
   S_Flags : Unsigned_64 := 0;

   --  ======================================================== (a) VarInt decode
   procedure Vi_Decode_Asis is
      Pos : Positive := Varints'First;
      R   : Adacraft.Protocol.Varnum.Varint_Result;
      Cnt, Sum : Unsigned_64 := 0;
   begin
      while Pos <= Varints'Last loop
         R := Adacraft.Protocol.Varnum.Decode_Varint (Varints.all, Pos);
         exit when R.Status /= Ok;
         Sum := Sum + Unsigned_64 (R.Value);
         Cnt := Cnt + 1;
         Pos := R.Next;
      end loop;
      S_Count := Cnt;
      S_Sum := Sum;
   end Vi_Decode_Asis;

   procedure Vi_Decode_Tight is
      Buf : Octets renames Varints.all;
      I   : Positive := Buf'First;
      V   : Unsigned_64;
      Sh  : Natural;
      B   : Octet;
      Cnt, Sum : Unsigned_64 := 0;
   begin
      while I <= Buf'Last loop
         V := 0;
         Sh := 0;
         loop
            B := Buf (I);
            I := I + 1;
            V := V or Shift_Left (Unsigned_64 (B and 16#7F#), Sh);
            exit when (B and 16#80#) = 0;
            Sh := Sh + 7;
         end loop;
         Sum := Sum + V;
         Cnt := Cnt + 1;
      end loop;
      S_Count := Cnt;
      S_Sum := Sum;
   end Vi_Decode_Tight;

   function T_Vi_Decode_Asis  is new Gw_Timing (Vi_Decode_Asis);
   function T_Vi_Decode_Tight is new Gw_Timing (Vi_Decode_Tight);

   --  ======================================================== (b) VarInt encode
   Enc_Buf : Octets_Access;
   Enc_Len : Natural := 0;
   Enc_Limit : Natural := Vals'Length;

   procedure Vi_Encode_Asis is
      Pos : Positive := 1;
      W   : Natural;
      St  : Adacraft.Protocol.Varnum.Status_Type;
   begin
      for I in 1 .. Enc_Limit loop
         Adacraft.Protocol.Varnum.Encode (Vals (I), Enc_Buf.all, Pos, W, St);
         Pos := Pos + W;
      end loop;
      Enc_Len := Pos - 1;
   end Vi_Encode_Asis;

   procedure Vi_Encode_Asis_Small is   --  how adacraft itself calls Encode: into a 5-byte scratch buffer, then copy
      Pos : Positive := 1;
      W   : Natural;
      St  : Adacraft.Protocol.Varnum.Status_Type;
      Scratch : Octets (1 .. 5);
   begin
      for I in 1 .. Enc_Limit loop
         Adacraft.Protocol.Varnum.Encode (Vals (I), Scratch, 1, W, St);
         for K in 1 .. W loop
            Enc_Buf (Pos + K - 1) := Scratch (K);
         end loop;
         Pos := Pos + W;
      end loop;
      Enc_Len := Pos - 1;
   end Vi_Encode_Asis_Small;

   procedure Vi_Encode_Tight is
      Pos : Positive := 1;
      V   : Unsigned_32;
   begin
      for I in 1 .. Enc_Limit loop
         V := Unsigned_32 (Vals (I));
         while V >= 16#80# loop
            Enc_Buf (Pos) := Octet ((V and 16#7F#) or 16#80#);
            Pos := Pos + 1;
            V := Shift_Right (V, 7);
         end loop;
         Enc_Buf (Pos) := Octet (V);
         Pos := Pos + 1;
      end loop;
      Enc_Len := Pos - 1;
   end Vi_Encode_Tight;

   function T_Vi_Encode_Asis  is new Gw_Timing (Vi_Encode_Asis);
   function T_Vi_Encode_Asis_Small is new Gw_Timing (Vi_Encode_Asis_Small);
   function T_Vi_Encode_Tight is new Gw_Timing (Vi_Encode_Tight);

   function Prefix_Equal (A : Octets; B : Octets; N : Natural) return Boolean is
   begin
      if A'Length < N or else B'Length < N then
         return False;
      end if;
      for I in 0 .. N - 1 loop
         if A (A'First + I) /= B (B'First + I) then
            return False;
         end if;
      end loop;
      return True;
   end Prefix_Equal;

   --  ======================================================== (c) frame split
   procedure Split_Index_Asis is      --  adacraft Decode_Frame, no body copy
      Pos : Positive := Frames'First;
      R   : Adacraft.Protocol.Frame.Frame_Decode;
      F, Ids, Bb : Unsigned_64 := 0;
   begin
      while Pos <= Frames'Last loop
         R := Adacraft.Protocol.Frame.Decode_Frame (Frames.all, Pos);
         exit when R.Status /= Ok;
         Ids := Ids + Unsigned_64 (R.Packet_Id);
         Bb := Bb + Unsigned_64 (R.Payload_Last - R.Payload_First + 1);
         Pos := R.Next;
         F := F + 1;
      end loop;
      S_Frames := F; S_IdSum := Ids; S_Body := Bb;
   end Split_Index_Asis;

   procedure Split_Scan_Asis is       --  adacraft Decode_Frame + copy of every body into a fresh heap object (like Rust to_vec / Tcl string range)
      Pos : Positive := Frames'First;
      R   : Adacraft.Protocol.Frame.Frame_Decode;
      F, Ids, Bb : Unsigned_64 := 0;
      Cp  : Octets_Access;
   begin
      while Pos <= Frames'Last loop
         R := Adacraft.Protocol.Frame.Decode_Frame (Frames.all, Pos);
         exit when R.Status /= Ok;
         Cp := new Octets'(Frames (R.Payload_First .. R.Payload_Last));
         Bb := Bb + Unsigned_64 (Cp'Length);
         Free (Cp);
         Ids := Ids + Unsigned_64 (R.Packet_Id);
         Pos := R.Next;
         F := F + 1;
      end loop;
      S_Frames := F; S_IdSum := Ids; S_Body := Bb;
   end Split_Scan_Asis;

   procedure Split_Tight is           --  hand-written loop, body copied into a reusable scratch buffer
      Buf : Octets renames Frames.all;
      Scratch : Octets (1 .. 4096);
      Pos : Positive := Buf'First;
      Len, Id : Natural;
      Sh  : Natural;
      B   : Octet;
      Id_Start, Id_Len, Body_Len : Natural;
      F, Ids, Bb : Unsigned_64 := 0;
      Dummy : Octet := 0;
   begin
      while Pos <= Buf'Last loop
         Len := 0; Sh := 0;
         loop
            B := Buf (Pos); Pos := Pos + 1;
            Len := Len + Natural (Shift_Left (Unsigned_32 (B and 16#7F#), Sh));
            exit when (B and 16#80#) = 0;
            Sh := Sh + 7;
         end loop;
         Id_Start := Pos;
         Id := 0; Sh := 0;
         loop
            B := Buf (Pos); Pos := Pos + 1;
            Id := Id + Natural (Shift_Left (Unsigned_32 (B and 16#7F#), Sh));
            exit when (B and 16#80#) = 0;
            Sh := Sh + 7;
         end loop;
         Id_Len := Pos - Id_Start;
         Body_Len := Len - Id_Len;
         Scratch (1 .. Body_Len) := Buf (Pos .. Pos + Body_Len - 1);
         Dummy := Dummy xor Scratch (1);
         Pos := Pos + Body_Len;
         Ids := Ids + Unsigned_64 (Id);
         Bb := Bb + Unsigned_64 (Body_Len);
         F := F + 1;
      end loop;
      S_Frames := F; S_IdSum := Ids; S_Body := Bb + Unsigned_64 (Dummy) * 0;
   end Split_Tight;

   --  the stateful ingress decoder the adacraft network layer really uses (Frame.Feed, byte by byte, callback per frame), 4 KiB reads
   Stream_Frames, Stream_Ids, Stream_Body : Unsigned_64;

   procedure On_Frame (Fr : in Adacraft.Protocol.Frame.Byte_Array) is
      I  : Stream_Element_Offset := Fr'First;
      V  : Unsigned_64 := 0;
      Sh : Natural := 0;
      B  : Stream_Element;
   begin
      loop
         B := Fr (I);
         I := I + 1;
         V := V or Shift_Left (Unsigned_64 (B and 16#7F#), Sh);
         exit when (B and 16#80#) = 0;
         Sh := Sh + 7;
      end loop;
      Stream_Frames := Stream_Frames + 1;
      Stream_Ids := Stream_Ids + V;
      Stream_Body := Stream_Body + Unsigned_64 (Fr'Last - I + 1);
   end On_Frame;

   procedure Split_Stream_Asis is
      Dec : constant access Adacraft.Protocol.Frame.Decoder_Type := new Adacraft.Protocol.Frame.Decoder_Type;
      I   : Stream_Element_Offset := Frames_SE'First;
      E   : Stream_Element_Offset;
      St  : Adacraft.Protocol.Frame.Feed_Status;
      use type Adacraft.Protocol.Frame.Feed_Status;
   begin
      Stream_Frames := 0; Stream_Ids := 0; Stream_Body := 0;
      while I <= Frames_SE'Last loop
         E := Stream_Element_Offset'Min (I + 4095, Frames_SE'Last);
         Adacraft.Protocol.Frame.Feed (Dec.all, Frames_SE (I .. E), On_Frame'Unrestricted_Access, St);
         exit when St /= Adacraft.Protocol.Frame.Success;
         I := E + 1;
      end loop;
      S_Frames := Stream_Frames; S_IdSum := Stream_Ids; S_Body := Stream_Body;
   end Split_Stream_Asis;

   function T_Split_Index_Asis  is new Gw_Timing (Split_Index_Asis);
   function T_Split_Scan_Asis   is new Gw_Timing (Split_Scan_Asis);
   function T_Split_Tight       is new Gw_Timing (Split_Tight);
   function T_Split_Stream_Asis is new Gw_Timing (Split_Stream_Asis);

   --  ======================================================== (d) position decode
   function To_F64 is new Ada.Unchecked_Conversion (Unsigned_64, IEEE_Float_64);
   function To_F32 is new Ada.Unchecked_Conversion (Unsigned_32, IEEE_Float_32);
   function To_U64 is new Ada.Unchecked_Conversion (IEEE_Float_64, Unsigned_64);
   function To_I64 is new Ada.Unchecked_Conversion (IEEE_Float_64, Integer_64);

   function BE64 (B : Octets; Off : Natural) return Unsigned_64 is
      V : Unsigned_64 := 0;
   begin
      for I in 0 .. 7 loop
         V := Shift_Left (V, 8) or Unsigned_64 (B (Off + I));
      end loop;
      return V;
   end BE64;

   function BE32 (B : Octets; Off : Natural) return Unsigned_32 is
      V : Unsigned_32 := 0;
   begin
      for I in 0 .. 3 loop
         V := Shift_Left (V, 8) or Unsigned_32 (B (Off + I));
      end loop;
      return V;
   end BE32;

   procedure Pos_Decode is
      P : Octets renames Pos_Bin.all;
      Sx : Long_Float := 0.0;
      Fl : Unsigned_64 := 0;
      Off : Natural;
      X, Z, Yaw, Pitch : Long_Float;
   begin
      for I in 0 .. 199_999 loop
         Off := P'First + (I mod 1000) * 33;
         X := Long_Float (To_F64 (BE64 (P, Off)));
         Z := Long_Float (To_F64 (BE64 (P, Off + 16)));
         Yaw := Long_Float (To_F32 (BE32 (P, Off + 24)));
         Pitch := Long_Float (To_F32 (BE32 (P, Off + 28)));
         Sx := Sx + X + Z + Yaw + Pitch;
         Fl := Fl + Unsigned_64 (P (Off + 32));
      end loop;
      S_Sx := Sx; S_Flags := Fl;
   end Pos_Decode;

   function T_Pos_Decode is new Gw_Timing (Pos_Decode);

   --  ======================================================== (e) build frames
   Build_Out : Octets_Access;
   Build_N   : Natural := 200_000;
   Build_Len : Natural := 0;

   procedure Build_Tight is
      Pos : Natural := 0;
      procedure Put64 (V : Unsigned_64) is
      begin
         for K in reverse 0 .. 7 loop
            Pos := Pos + 1;
            Build_Out (Pos) := Octet (Shift_Right (V, K * 8) and 16#FF#);
         end loop;
      end Put64;
   begin
      for I in 0 .. Build_N - 1 loop
         Pos := Pos + 1; Build_Out (Pos) := 31;                                   --  length: id (1) + body (30)
         Pos := Pos + 1; Build_Out (Pos) := Octet (16#2F# + (I mod 4));           --  packet id
         for K in reverse 0 .. 3 loop
            Pos := Pos + 1;
            Build_Out (Pos) := Octet (Shift_Right (Unsigned_32 (I), K * 8) and 16#FF#);
         end loop;
         Put64 (To_U64 (IEEE_Float_64 (Long_Float (I) * 0.5)));
         Put64 (To_U64 (64.0));
         Put64 (To_U64 (IEEE_Float_64 (Long_Float (I) * 0.25)));
         Pos := Pos + 1; Build_Out (Pos) := Octet (I mod 256);
         Pos := Pos + 1; Build_Out (Pos) := Octet ((I / 8) mod 256);
      end loop;
      Build_Len := Pos;
   end Build_Tight;

   Enc_Obj : constant access Pe.Encoder_Type := new Pe.Encoder_Type;   --  2 MiB, must not live on the stack

   procedure Build_Asis is            --  adacraft Packet_Encoder: Start_Packet, Write_*, Get_Framed
      Scratch : Stream_Element_Array (1 .. 64);
      Last    : Stream_Element_Offset;
      Pos     : Natural := 0;
   begin
      for I in 0 .. Build_N - 1 loop
         Pe.Start_Packet (Enc_Obj.all, 16#2F# + (I mod 4));
         Pe.Write_Int  (Enc_Obj.all, Integer_32 (I));
         Pe.Write_Long (Enc_Obj.all, To_I64 (IEEE_Float_64 (Long_Float (I) * 0.5)));
         Pe.Write_Long (Enc_Obj.all, To_I64 (64.0));
         Pe.Write_Long (Enc_Obj.all, To_I64 (IEEE_Float_64 (Long_Float (I) * 0.25)));
         Pe.Write_Byte (Enc_Obj.all, Stream_Element (I mod 256));
         Pe.Write_Byte (Enc_Obj.all, Stream_Element ((I / 8) mod 256));
         Pe.Get_Framed (Enc_Obj.all, Scratch, Last);
         for K in 1 .. Last loop
            Pos := Pos + 1;
            Build_Out (Pos) := Octet (Scratch (K));
         end loop;
      end loop;
      Build_Len := Pos;
   end Build_Asis;

   function T_Build_Tight is new Gw_Timing (Build_Tight);
   function T_Build_Asis  is new Gw_Timing (Build_Asis);

   --  ======================================================== (f) connections
   Conn_Res : Gw_Conns.Totals;
   procedure Conns_Plain is begin Conn_Res := Gw_Conns.Run_Plain (2000, 100); end Conns_Plain;
   procedure Conns_Rdv   is begin Conn_Res := Gw_Conns.Run_Tasks_Rdv (2000, 100); end Conns_Rdv;
   procedure Conns_Local is begin Conn_Res := Gw_Conns.Run_Tasks_Local (2000, 100); end Conns_Local;
   function T_Conns_Plain is new Gw_Timing (Conns_Plain);
   function T_Conns_Rdv   is new Gw_Timing (Conns_Rdv);
   function T_Conns_Local is new Gw_Timing (Conns_Local);

   function Conn_Line (T : Gw_Conns.Totals) return String is
     ("coro moves=" & Img (T.Moves) & " chats=" & Img (T.Chats) & " other=" & Img (T.Other) & " bytes=" & Img (T.Bytes));

   --  ======================================================== (g) AES-128-CFB8
   Key : constant Octets (1 .. 16) := (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);
   Iv  : constant Octets (1 .. 16) := (16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);
   Aes_Out : Octets_Access;
   Sbox : Gw_Aes.Sbox_Table;
   Rk   : Gw_Aes.Round_Keys;

   procedure Aes_Ossl_Enc is
      C : Gw_Aes.Cfb8_Ctx;
   begin
      Gw_Aes.Open (C, Gw_Aes.Encrypt, Key, Iv);
      Gw_Aes.Update (C, Chunk.all, Aes_Out.all);
      Gw_Aes.Close (C);
   end Aes_Ossl_Enc;

   procedure Aes_Ossl_Dec is
      C : Gw_Aes.Cfb8_Ctx;
   begin
      Gw_Aes.Open (C, Gw_Aes.Decrypt, Key, Iv);
      Gw_Aes.Update (C, Aes_Expect.all, Aes_Out.all);
      Gw_Aes.Close (C);
   end Aes_Ossl_Dec;

   procedure Aes_Ossl_Enc_1k is       --  per-message pattern: one persistent context, 1000-byte calls
      C : Gw_Aes.Cfb8_Ctx;
      P : Natural := Chunk'First;
   begin
      Gw_Aes.Open (C, Gw_Aes.Encrypt, Key, Iv);
      while P <= Chunk'Last loop
         declare
            N : constant Natural := Natural'Min (1000, Chunk'Last - P + 1);
         begin
            Gw_Aes.Update_Raw (C, Chunk (P)'Address, Aes_Out (P)'Address, N);
            P := P + N;
         end;
      end loop;
      Gw_Aes.Close (C);
   end Aes_Ossl_Enc_1k;

   procedure Aes_Ossl_Dec_150 is      --  per-message pattern: 150-byte inbound messages
      C : Gw_Aes.Cfb8_Ctx;
      P : Natural := Aes_Expect'First;
   begin
      Gw_Aes.Open (C, Gw_Aes.Decrypt, Key, Iv);
      while P <= Aes_Expect'Last loop
         declare
            N : constant Natural := Natural'Min (150, Aes_Expect'Last - P + 1);
         begin
            Gw_Aes.Update_Raw (C, Aes_Expect (P)'Address, Aes_Out (P)'Address, N);
            P := P + N;
         end;
      end loop;
      Gw_Aes.Close (C);
   end Aes_Ossl_Dec_150;

   procedure Aes_Soft is
   begin
      Gw_Aes.Cfb8_Encrypt_Soft (Rk, Sbox, Iv, Chunk.all, Aes_Out.all);
   end Aes_Soft;

   function T_Aes_Enc    is new Gw_Timing (Aes_Ossl_Enc);
   function T_Aes_Dec    is new Gw_Timing (Aes_Ossl_Dec);
   function T_Aes_Enc_1k is new Gw_Timing (Aes_Ossl_Enc_1k);
   function T_Aes_Dec_150 is new Gw_Timing (Aes_Ossl_Dec_150);
   function T_Aes_Soft   is new Gw_Timing (Aes_Soft);

   --  ======================================================== (h) zlib through adacraft's binding
   Z_Bound : Natural;
   Z_Comp  : Octets_Access;
   Z_Clen  : Natural := 0;
   Z_Back  : Octets_Access;
   Z_Ok    : Boolean := True;

   procedure Z_Compress is
      S   : aliased Z.Z_Stream;
      Ver : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Z.Zlib_Version);
      Rc  : Interfaces.C.int;
      use type Interfaces.C.int;
   begin
      Z.Init_Stream (S);
      Z.Set_Input (S, Chunk (Chunk'First)'Address, Interfaces.C.unsigned (Chunk'Length));
      Z.Set_Output (S, Z_Comp (Z_Comp'First)'Address, Interfaces.C.unsigned (Z_Bound));
      Rc := Z.Deflate_Init (S'Unchecked_Access, 6, Ver, Z.Stream_Size);
      if Rc /= Z.Z_Ok then Z_Ok := False; end if;
      Rc := Z.Deflate (S'Unchecked_Access, Z.Z_Finish);
      if Rc /= Z.Z_Stream_End then Z_Ok := False; end if;
      Z_Clen := Natural (Z.Total_Out (S));
      Rc := Z.Deflate_End (S'Unchecked_Access);
      Interfaces.C.Strings.Free (Ver);
   end Z_Compress;

   procedure Z_Decompress is
      S   : aliased Z.Z_Stream;
      Ver : Interfaces.C.Strings.chars_ptr := Interfaces.C.Strings.New_String (Z.Zlib_Version);
      Rc  : Interfaces.C.int;
      use type Interfaces.C.int;
   begin
      Z.Init_Stream (S);
      Z.Set_Input (S, Z_Comp (Z_Comp'First)'Address, Interfaces.C.unsigned (Z_Clen));
      Z.Set_Output (S, Z_Back (Z_Back'First)'Address, Interfaces.C.unsigned (Z_Back'Length));
      Rc := Z.Inflate_Init (S'Unchecked_Access, Ver, Z.Stream_Size);
      if Rc /= Z.Z_Ok then Z_Ok := False; end if;
      Rc := Z.Inflate (S'Unchecked_Access, Z.Z_Finish);
      if Rc /= Z.Z_Stream_End then Z_Ok := False; end if;
      Rc := Z.Inflate_End (S'Unchecked_Access);
      Interfaces.C.Strings.Free (Ver);
   end Z_Decompress;

   function T_Z_Compress   is new Gw_Timing (Z_Compress);
   function T_Z_Decompress is new Gw_Timing (Z_Decompress);

   Best : Duration;
   Limit_Reps : constant Positive := Positive'Min (Reps, 2);
   Skip_Slow : constant Boolean := Ada.Environment_Variables.Exists ("SKIP_SLOW");

   --  rough per-iteration calibration so the as-is encoder rows (which may be very slow) finish in about a second
   function Calibrated (Total : Natural; Probe : Natural; Probe_Time : Duration) return Natural is
      Per : constant Long_Float := Long_Float (Probe_Time) / Long_Float (Probe);
      N   : constant Long_Float := 1.0 / Long_Float'Max (Per, 1.0E-9);
   begin
      if N >= Long_Float (Total) then
         return Total;
      else
         return Natural'Max (Probe, Natural (N));
      end if;
   end Calibrated;

begin
   Load_Expected;
   Varints    := Read_Octets ("varints.bin");
   Vals_Raw   := Read_Octets ("vals.bin");
   Frames     := Read_Octets ("frames.bin");
   Frames_SE  := Read_SE ("frames.bin");
   Pos_Bin    := Read_Octets ("pos.bin");
   Chunk      := Read_Octets ("chunk.bin");
   Aes_Expect := Read_Octets ("aes_expected.bin");
   Frames_Out := Read_Octets ("frames_out.bin");
   for I in Vals'Range loop
      declare
         O : constant Natural := (I - 1) * 4;
      begin
         Vals (I) := Integer_32
           (Unsigned_32 (Vals_Raw (O + 1))
            or Shift_Left (Unsigned_32 (Vals_Raw (O + 2)), 8)
            or Shift_Left (Unsigned_32 (Vals_Raw (O + 3)), 16)
            or Shift_Left (Unsigned_32 (Vals_Raw (O + 4)), 24));
      end;
   end loop;
   Enc_Buf   := new Octets (1 .. 2_000_000);
   Build_Out := new Octets (1 .. 7_000_000);
   Aes_Out   := new Octets (1 .. Chunk'Length);
   Z_Bound   := Natural (Z.Compress_Bound (Interfaces.C.unsigned_long (Chunk'Length)));
   Z_Comp    := new Octets (1 .. Z_Bound);
   Z_Back    := new Octets (1 .. Chunk'Length);

   Put_Line ("INFO ada reps=" & Img (Long_Long_Integer (Reps)));

   --  (a) VarInt decode
   Best := T_Vi_Decode_Asis (Reps);
   Report ("vi_decode_asis", Best, 1_000_000, Long_Long_Integer (Varints'Length));
   Check ("vi_decode_asis", "vi_decode count=" & Img (S_Count) & " sum=" & Img (S_Sum));
   Best := T_Vi_Decode_Tight (Reps);
   Report ("vi_decode_tight", Best, 1_000_000, Long_Long_Integer (Varints'Length));
   Check ("vi_decode_tight", "vi_decode count=" & Img (S_Count) & " sum=" & Img (S_Sum));

   --  (b) VarInt encode
   declare
      Probe_T : Duration;
      Probe   : constant := 2_000;
   begin
      Enc_Limit := Probe;
      Probe_T := T_Vi_Encode_Asis (1);
      Enc_Limit := Calibrated (Vals'Length, Probe, Probe_T);
   end;
   Best := T_Vi_Encode_Asis (Reps);
   Report ("vi_encode_asis", Best, Long_Long_Integer (Enc_Limit), Long_Long_Integer (Enc_Len));
   if Enc_Limit = Vals'Length then
      Check ("vi_encode_asis", "vi_encode len=" & Img (Long_Long_Integer (Enc_Len)) & " ok=" & (if Prefix_Equal (Enc_Buf.all, Varints.all, Enc_Len) and then Enc_Len = Varints'Length then "1" else "0"));
   else
      Put_Line ("CHECK vi_encode_asis PARTIAL n=" & Img (Long_Long_Integer (Enc_Limit)) & " prefix_ok=" & (if Prefix_Equal (Enc_Buf.all, Varints.all, Enc_Len) then "1" else "0"));
   end if;
   Enc_Limit := Vals'Length;
   Best := T_Vi_Encode_Asis_Small (Reps);
   Report ("vi_encode_asis_small", Best, 1_000_000, Long_Long_Integer (Enc_Len));
   Check ("vi_encode_asis_small", "vi_encode len=" & Img (Long_Long_Integer (Enc_Len)) & " ok=" & (if Prefix_Equal (Enc_Buf.all, Varints.all, Enc_Len) and then Enc_Len = Varints'Length then "1" else "0"));
   Best := T_Vi_Encode_Tight (Reps);
   Report ("vi_encode_tight", Best, 1_000_000, Long_Long_Integer (Enc_Len));
   Check ("vi_encode_tight", "vi_encode len=" & Img (Long_Long_Integer (Enc_Len)) & " ok=" & (if Prefix_Equal (Enc_Buf.all, Varints.all, Enc_Len) and then Enc_Len = Varints'Length then "1" else "0"));

   --  (c) frame split
   Best := T_Split_Index_Asis (Reps);
   Report ("split_index_asis", Best, 200_000, Long_Long_Integer (Frames'Length));
   Check ("split_index_asis", "split_index frames=" & Img (S_Frames) & " idsum=" & Img (S_IdSum) & " bodybytes=" & Img (S_Body));
   Best := T_Split_Scan_Asis (Reps);
   Report ("split_scan_asis", Best, 200_000, Long_Long_Integer (Frames'Length));
   Check ("split_scan_asis", "split_scan frames=" & Img (S_Frames) & " idsum=" & Img (S_IdSum) & " bodybytes=" & Img (S_Body));
   Best := T_Split_Tight (Reps);
   Report ("split_tight", Best, 200_000, Long_Long_Integer (Frames'Length));
   Check ("split_tight", "split_scan frames=" & Img (S_Frames) & " idsum=" & Img (S_IdSum) & " bodybytes=" & Img (S_Body));
   Best := T_Split_Stream_Asis (Limit_Reps);
   Report ("split_stream_asis", Best, 200_000, Long_Long_Integer (Frames'Length));
   Check ("split_stream_asis", "split_scan frames=" & Img (S_Frames) & " idsum=" & Img (S_IdSum) & " bodybytes=" & Img (S_Body));

   --  (d) position decode
   Best := T_Pos_Decode (Reps);
   Report ("pos_decode", Best, 200_000, 200_000 * 33);
   Check ("pos_decode", "pos_decode sx=" & Fmt6 (S_Sx) & " flags=" & Img (S_Flags));

   --  (e) build frames
   Build_N := 200_000;
   Best := T_Build_Tight (Reps);
   Report ("build_tight", Best, 200_000, 6_400_000);
   Check ("build_tight", "build_frames len=" & Img (Long_Long_Integer (Build_Len)) & " ok=" & (if Prefix_Equal (Build_Out.all, Frames_Out.all, Build_Len) and then Build_Len = Frames_Out'Length then "1" else "0"));
   if not Skip_Slow then
   declare
      Probe_T : Duration;
      Probe   : constant := 200;
   begin
      Build_N := Probe;
      Probe_T := T_Build_Asis (1);
      Build_N := Calibrated (200_000, Probe, Probe_T);
   end;
   Best := T_Build_Asis (Limit_Reps);
   Report ("build_asis", Best, Long_Long_Integer (Build_N), Long_Long_Integer (Build_Len));
   if Build_N = 200_000 then
      Check ("build_asis", "build_frames len=" & Img (Long_Long_Integer (Build_Len)) & " ok=" & (if Prefix_Equal (Build_Out.all, Frames_Out.all, Build_Len) and then Build_Len = Frames_Out'Length then "1" else "0"));
   else
      Put_Line ("CHECK build_asis PARTIAL n=" & Img (Long_Long_Integer (Build_N)) & " prefix_ok=" & (if Prefix_Equal (Build_Out.all, Frames_Out.all, Build_Len) then "1" else "0"));
   end if;
   end if;

   --  (f) connection state machines
   Best := T_Conns_Plain (Reps);
   Report ("coro_plain", Best, 200_000, 0);
   Check ("coro_plain", Conn_Line (Conn_Res));
   Best := T_Conns_Local (Limit_Reps);
   Report ("coro_tasks_local", Best, 200_000, 0);
   Check ("coro_tasks_local", Conn_Line (Conn_Res));
   if not Skip_Slow then
      Best := T_Conns_Rdv (Limit_Reps);
      Report ("coro_tasks_rdv", Best, 200_000, 0);
      Check ("coro_tasks_rdv", Conn_Line (Conn_Res));
   end if;

   --  (g) zlib
   Best := T_Z_Compress (Reps);
   Report ("z_compress", Best, 1, Long_Long_Integer (Chunk'Length));
   Best := T_Z_Decompress (Reps);
   Report ("z_decompress", Best, 1, Long_Long_Integer (Chunk'Length));
   Check ("z_decompress", "z_roundtrip ok=" & (if Z_Ok and then Prefix_Equal (Z_Back.all, Chunk.all, Chunk'Length) then "1" else "0"));
   Put_Line ("INFO z_compress clen=" & Img (Long_Long_Integer (Z_Clen)));

   --  (h) AES-128-CFB8
   Sbox := Gw_Aes.Make_Sbox;
   Rk := Gw_Aes.Expand_Key (Key, Sbox);
   if not Skip_Slow then
      Best := T_Aes_Soft (Limit_Reps);
      Report ("aes_cfb8_soft", Best, Long_Long_Integer (Chunk'Length), Long_Long_Integer (Chunk'Length));
      Check ("aes_cfb8_soft", "aes_cfb8 len=" & Img (Long_Long_Integer (Aes_Out'Length)) & " ok=" & (if Prefix_Equal (Aes_Out.all, Aes_Expect.all, Aes_Out'Length) then "1" else "0"));
   end if;
   Best := T_Aes_Enc (Reps);
   Report ("aes_cfb8", Best, Long_Long_Integer (Chunk'Length), Long_Long_Integer (Chunk'Length));
   Check ("aes_cfb8", "aes_cfb8 len=" & Img (Long_Long_Integer (Aes_Out'Length)) & " ok=" & (if Prefix_Equal (Aes_Out.all, Aes_Expect.all, Aes_Out'Length) then "1" else "0"));
   Best := T_Aes_Dec (Reps);
   Report ("aes_cfb8_dec", Best, Long_Long_Integer (Chunk'Length), Long_Long_Integer (Chunk'Length));
   Check ("aes_cfb8_dec", "aes_cfb8 len=" & Img (Long_Long_Integer (Aes_Out'Length)) & " ok=" & (if Prefix_Equal (Aes_Out.all, Chunk.all, Aes_Out'Length) then "1" else "0"));
   Best := T_Aes_Enc_1k (Reps);
   Report ("aes_cfb8_enc_1k_calls", Best, Long_Long_Integer (Chunk'Length), Long_Long_Integer (Chunk'Length));
   Check ("aes_cfb8_enc_1k_calls", "aes_cfb8 len=" & Img (Long_Long_Integer (Aes_Out'Length)) & " ok=" & (if Prefix_Equal (Aes_Out.all, Aes_Expect.all, Aes_Out'Length) then "1" else "0"));
   Best := T_Aes_Dec_150 (Reps);
   Report ("aes_cfb8_dec_150_calls", Best, Long_Long_Integer (Chunk'Length), Long_Long_Integer (Chunk'Length));
   Check ("aes_cfb8_dec_150_calls", "aes_cfb8 len=" & Img (Long_Long_Integer (Aes_Out'Length)) & " ok=" & (if Prefix_Equal (Aes_Out.all, Chunk.all, Aes_Out'Length) then "1" else "0"));

   Put_Line ("INFO mismatches=" & Img (Long_Long_Integer (Mismatches)));
end Gwbench;
