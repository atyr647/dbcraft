with Ada.Streams;
with Ada.Unchecked_Conversion;
with Interfaces;
with Adacraft.Protocol.Frame;
with Adacraft.Protocol.Ids;
with Adacraft.Protocol.Varnum;

package body Adacraft.Protocol.Packet_Encoder is

   use type Adacraft.Protocol.Varnum.Status_Type;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   function To_U32 is new Ada.Unchecked_Conversion
     (Interfaces.Integer_32, Interfaces.Unsigned_32);
   function To_U64 is new Ada.Unchecked_Conversion
     (Interfaces.Integer_64, Interfaces.Unsigned_64);

   procedure Append_Element (E : in out Encoder_Type; V : Byte) is
   begin
      if E.Failed or else not E.Started then
         E.Failed := True;
         return;
      end if;
      if E.Count >= E.Capacity
        or else E.Count >= Adacraft.Protocol.Frame.Max_Frame_Body_Length
      then
         E.Failed := True;
         return;
      end if;
      E.Storage (Ada.Streams.Stream_Element_Offset (E.Count + 1)) := V;
      E.Count := E.Count + 1;
   end Append_Element;

   procedure Append_Raw
     (E : in out Encoder_Type; Data : Ada.Streams.Stream_Element_Array) is
      Data_Len : constant Natural := Natural (Data'Length);
   begin
      if E.Failed or else not E.Started then
         E.Failed := True;
         return;
      end if;
      if Data_Len = 0 then
         return;
      end if;
      if E.Count + Data_Len > E.Capacity
        or else E.Count + Data_Len >
          Adacraft.Protocol.Frame.Max_Frame_Body_Length
      then
         E.Failed := True;
         return;
      end if;
      for I in 1 .. Data_Len loop
         E.Storage (Ada.Streams.Stream_Element_Offset (E.Count + I)) :=
           Data (Data'First + Ada.Streams.Stream_Element_Offset (I) - 1);
      end loop;
      E.Count := E.Count + Data_Len;
   end Append_Raw;

   procedure Start_Packet (E : in out Encoder_Type; Packet_Id : Natural) is
      Buf     : Adacraft.Protocol.Octets (1 .. 5) := (others => 0);
      Written : Natural := 0;
      Status  : Adacraft.Protocol.Varnum.Status_Type;
      Value   : Interfaces.Integer_32;
   begin
      E.Count := 0;
      E.Failed := False;
      E.Started := True;
      E.Storage := (others => 0);
      if Packet_Id > Natural (Interfaces.Integer_32'Last) then
         E.Failed := True;
         return;
      end if;
      Value := Interfaces.Integer_32 (Packet_Id);
      Adacraft.Protocol.Varnum.Encode (Value, Buf, Buf'First, Written, Status);
      if Status /= Adacraft.Protocol.Varnum.Ok then
         E.Failed := True;
         return;
      end if;
      if Written > E.Capacity then
         E.Failed := True;
         return;
      end if;
      for I in 1 .. Written loop
         E.Storage (Ada.Streams.Stream_Element_Offset (I)) :=
           Ada.Streams.Stream_Element (Buf (I));
      end loop;
      E.Count := Written;
   end Start_Packet;

   procedure Write_Boolean (E : in out Encoder_Type; V : Boolean) is
   begin
      if V then
         Append_Element (E, 16#01#);
      else
         Append_Element (E, 16#00#);
      end if;
   end Write_Boolean;

   procedure Write_Byte (E : in out Encoder_Type; V : Byte) is
   begin
      Append_Element (E, V);
   end Write_Byte;

   procedure Write_Int (E : in out Encoder_Type; V : Interfaces.Integer_32) is
      U : constant Interfaces.Unsigned_32 := To_U32 (V);
      B : Ada.Streams.Stream_Element_Array (1 .. 4);
   begin
      B (1) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 24) and 16#FF#);
      B (2) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 16) and 16#FF#);
      B (3) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 8) and 16#FF#);
      B (4) := Ada.Streams.Stream_Element (U and 16#FF#);
      Append_Raw (E, B);
   end Write_Int;

   procedure Write_Long (E : in out Encoder_Type; V : Interfaces.Integer_64) is
      U : constant Interfaces.Unsigned_64 := To_U64 (V);
      B : Ada.Streams.Stream_Element_Array (1 .. 8);
   begin
      B (1) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 56) and 16#FF#);
      B (2) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 48) and 16#FF#);
      B (3) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 40) and 16#FF#);
      B (4) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 32) and 16#FF#);
      B (5) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 24) and 16#FF#);
      B (6) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 16) and 16#FF#);
      B (7) := Ada.Streams.Stream_Element
        (Interfaces.Shift_Right (U, 8) and 16#FF#);
      B (8) := Ada.Streams.Stream_Element (U and 16#FF#);
      Append_Raw (E, B);
   end Write_Long;

   procedure Get_Framed
     (E      : in out Encoder_Type;
      Output : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset)
   is
      Prefix     : Adacraft.Protocol.Frame.Prefix_Buffer;
      Prefix_Len : Ada.Streams.Stream_Element_Offset;
      Need       : Ada.Streams.Stream_Element_Offset;
   begin
      Output := (others => 0);
      if E.Failed
        or else not E.Started
        or else E.Count > Adacraft.Protocol.Frame.Max_Frame_Body_Length
      then
         E.Failed := True;
         if Output'First > Ada.Streams.Stream_Element_Offset'First then
            Last := Output'First - 1;
         else
            Last := Output'First;
         end if;
         return;
      end if;
      Adacraft.Protocol.Frame.Write_Length_Prefix
        (Adacraft.Protocol.Frame.Frame_Body_Length (E.Count),
         Prefix, Prefix_Len);
      Need := Prefix_Len + Ada.Streams.Stream_Element_Offset (E.Count);
      if Output'Length < Need then
         E.Failed := True;
         if Output'First > Ada.Streams.Stream_Element_Offset'First then
            Last := Output'First - 1;
         else
            Last := Output'First;
         end if;
         return;
      end if;
      for I in 1 .. Prefix_Len loop
         Output (Output'First + I - 1) :=
           Prefix (Positive (I));
      end loop;
      for I in 1 .. E.Count loop
         Output (Output'First + Prefix_Len +
                 Ada.Streams.Stream_Element_Offset (I) - 1) :=
           E.Storage (Ada.Streams.Stream_Element_Offset (I));
      end loop;
      Last := Output'First + Need - 1;
   end Get_Framed;

   procedure Get_Body
     (E     : in Encoder_Type;
      Data  : out Ada.Streams.Stream_Element_Array;
      Last  : out Ada.Streams.Stream_Element_Offset)
   is
      N : constant Natural := Natural'Min (E.Count, Natural (Data'Length));
   begin
      Data := (others => 0);
      if N = 0 then
         if Data'First > Ada.Streams.Stream_Element_Offset'First then
            Last := Data'First - 1;
         else
            Last := Data'First;
         end if;
         return;
      end if;
      for I in 1 .. N loop
         Data (Data'First + Ada.Streams.Stream_Element_Offset (I) - 1) :=
           E.Storage (Ada.Streams.Stream_Element_Offset (I));
      end loop;
      Last := Data'First + Ada.Streams.Stream_Element_Offset (N) - 1;
   end Get_Body;

   procedure Write_Varint_U32
     (E : in out Encoder_Type; V : Interfaces.Unsigned_32)
   is
      Buf     : Adacraft.Protocol.Octets (1 .. 5) := (others => 0);
      Written : Natural := 0;
      Status  : Adacraft.Protocol.Varnum.Status_Type;
   begin
      Adacraft.Protocol.Varnum.Encode
        (Interfaces.Integer_32 (V and 16#7FFF_FFFF#),
         Buf, Buf'First, Written, Status);
      --  Values used here (length prefixes, property count 0) are
      --  non-negative, so the Unsigned_32 -> Integer_32 conversion
      --  above cannot overflow.
      if Status /= Adacraft.Protocol.Varnum.Ok then
         E.Failed := True;
         return;
      end if;
      for I in 1 .. Written loop
         Append_Element (E, Byte (Buf (I)));
      end loop;
   end Write_Varint_U32;

   procedure Write_Proto_String
     (E : in out Encoder_Type; Value : String)
   is
   begin
      Write_Varint_U32 (E, Interfaces.Unsigned_32 (Value'Length));
      for Ch of Value loop
         Append_Element (E, Byte (Character'Pos (Ch)));
      end loop;
   end Write_Proto_String;

   procedure Encode_Login_Success
     (E    : in out Encoder_Type;
      Uuid : Adacraft.Protocol.Octets;
      Name : String)
   is
   begin
      Start_Packet (E, Ids.Protocol_Id (Ids.Cb_Login_Login_Finished));
      if E.Failed then
         return;
      end if;
      if Uuid'Length /= 16 then
         E.Failed := True;
         return;
      end if;
      if Name'Length < 1 or else Name'Length > 16 then
         E.Failed := True;
         return;
      end if;
      for I in 1 .. 16 loop
         Append_Element (E, Byte (Uuid (Uuid'First + I - 1)));
      end loop;
      Write_Proto_String (E, Name);
      Write_Varint_U32 (E, 0);
   end Encode_Login_Success;

   procedure Encode_Login_Disconnect
     (E      : in out Encoder_Type;
      Reason : String)
   is
      JSON : constant String := "{""text"":""" & Reason & """}";
   begin
      Start_Packet (E, Ids.Protocol_Id (Ids.Cb_Login_Login_Disconnect));
      if E.Failed then
         return;
      end if;
      Write_Proto_String (E, JSON);
   end Encode_Login_Disconnect;

   function Has_Failed (E : Encoder_Type) return Boolean is
   begin
      return E.Failed;
   end Has_Failed;

   function Length (E : Encoder_Type) return Natural is
   begin
      return E.Count;
   end Length;

end Adacraft.Protocol.Packet_Encoder;
