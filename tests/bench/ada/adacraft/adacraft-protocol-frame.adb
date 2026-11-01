with Ada.Streams;
with Interfaces;
with Adacraft.Protocol.Varnum;

package body Adacraft.Protocol.Frame
  with SPARK_Mode
is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Integer_32;
   use type Varnum.Status_Type;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;

   function Remaining (Last : Natural; From : Natural) return Natural is
     (if From > Last then 0 else Last - From + 1);

   procedure Write_Length_Prefix
     (Length : in  Frame_Body_Length;
      Buffer : out Prefix_Buffer;
      Last   : out Ada.Streams.Stream_Element_Offset)
     with SPARK_Mode => Off
   is
      Raw     : Octets (1 .. Max_Frame_Prefix_Bytes) := (others => 0);
      Written : Natural := 0;
      St      : Varnum.Status_Type := Varnum.Truncated;
   begin
      Buffer := (others => 0);
      Last := 1;
      Varnum.Encode
        (Value       => Interfaces.Integer_32 (Length),
         Buffer      => Raw,
         Start_Index => 1,
         Written     => Written,
         Status      => St);
      if St /= Varnum.Ok or else Written < 1 then
         Buffer (1) := 0;
         Last := 1;
         return;
      end if;
      for I in 1 .. Written loop
         Buffer (I) := Ada.Streams.Stream_Element (Raw (I));
      end loop;
      Last := Ada.Streams.Stream_Element_Offset (Written);
   end Write_Length_Prefix;

   procedure Encode
     (Payload : in  Ada.Streams.Stream_Element_Array;
      Output  : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Status  : out Encode_Status)
     with SPARK_Mode => Off
   is
      Prefix     : Prefix_Buffer;
      Prefix_Len : Ada.Streams.Stream_Element_Offset;
      Frame_Len  : Ada.Streams.Stream_Element_Offset;
      Body_First : Ada.Streams.Stream_Element_Offset;
   begin
      if Output'First > Ada.Streams.Stream_Element_Offset'First then
         Last := Output'First - 1;
      else
         Last := Output'First;
      end if;
      Status := Output_Too_Small;

      if Payload'Length > Max_Frame_Body_Length then
         Status := Body_Too_Long;
         return;
      end if;

      Write_Length_Prefix
        (Frame_Body_Length (Payload'Length), Prefix, Prefix_Len);
      Frame_Len :=
        Prefix_Len +
          Ada.Streams.Stream_Element_Offset (Payload'Length);

      if Output'Length < Frame_Len then
         return;
      end if;

      for I in 1 .. Prefix_Len loop
         Output (Output'First + I - 1) := Prefix (Integer (I));
      end loop;

      if Payload'Length > 0 then
         Body_First := Output'First + Prefix_Len;
         Output
           (Body_First ..
              Body_First +
                Ada.Streams.Stream_Element_Offset (Payload'Length) - 1) :=
            Payload;
      end if;

      Last := Output'First + Frame_Len - 1;
      Status := Ok;
   end Encode;

   procedure Feed
     (Decoder  : in out Decoder_Type;
      Chunk    : in     Byte_Array;
      On_Frame : not null access procedure (Frame : in Byte_Array);
      Status   : out    Feed_Status)
     with SPARK_Mode => Off
   is
      Empty_Body : constant Byte_Array (1 .. 0) := (others => 0);
      Value      : Ada.Streams.Stream_Element;
   begin
      if Decoder.Failed then
         Status := Framing_Error;
         return;
      end if;

      for I in Chunk'Range loop
         Value := Chunk (I);

         case Decoder.Phase is
            when In_Prefix =>
               Decoder.Prefix_Count := Decoder.Prefix_Count + 1;
               Decoder.Prefix_Bytes
                 (Ada.Streams.Stream_Element_Offset
                    (Decoder.Prefix_Count)) := Value;

               declare
                  Count : constant Positive :=
                    Positive (Decoder.Prefix_Count);
                  Raw   : Octets (1 .. Max_Frame_Prefix_Bytes) :=
                    (others => 0);
                  V     : Interfaces.Integer_32 := 0;
                  Cons  : Natural := 0;
                  St    : Varnum.Status_Type := Varnum.Truncated;
               begin
                  for J in 1 .. Count loop
                     Raw (J) :=
                       Octet
                         (Decoder.Prefix_Bytes
                            (Ada.Streams.Stream_Element_Offset (J)));
                  end loop;
                  Varnum.Decode
                    (Buffer      => Raw (1 .. Count),
                     Start_Index => 1,
                     Value       => V,
                     Consumed    => Cons,
                     Status      => St);
                  if St = Varnum.Ok then
                     if Cons /= Count
                       or else V < 0
                       or else V > Interfaces.Integer_32
                         (Max_Frame_Body_Length)
                     then
                        Decoder.Failed := True;
                        Status := Framing_Error;
                        return;
                     end if;
                     Decoder.Body_Length := Frame_Body_Length (V);
                     Decoder.Body_Count := 0;
                     if Decoder.Body_Length = 0 then
                        On_Frame (Empty_Body);
                        Decoder.Phase := In_Prefix;
                        Decoder.Prefix_Count := 0;
                     else
                        Decoder.Phase := In_Body;
                     end if;
                  elsif St = Varnum.Truncated then
                     if Decoder.Prefix_Count = Max_Frame_Prefix_Bytes then
                        Decoder.Failed := True;
                        Status := Framing_Error;
                        return;
                     end if;
                  else
                     if Decoder.Body_Length = 0 then
                        On_Frame (Decoder.Body_Bytes (1 .. 0));
                        Decoder.Phase := In_Prefix;
                        Decoder.Prefix_Count := 0;
                        Decoder.Body_Count := 0;
                        Status := Success;
                     else
                        Decoder.Phase := In_Body;
                     end if;
                  end if;
               end;

            when In_Body =>
               Decoder.Body_Count := Decoder.Body_Count + 1;
               Decoder.Body_Bytes (Decoder.Body_Count) := Value;

               if Decoder.Body_Count = Decoder.Body_Length then
                  Decoder.Phase := In_Prefix;
                  Decoder.Prefix_Count := 0;
                  On_Frame (Decoder.Body_Bytes (1 .. Decoder.Body_Length));
                  Decoder.Body_Count := 0;
               end if;
         end case;
      end loop;

      Status := Success;
   end Feed;

   function Decode_Frame (Buffer : Octets; From : Positive) return Frame_Decode is
      Length      : Varnum.Varint_Result;
      Ident       : Varnum.Varint_Result;
      Size        : Natural;
      Payload_End : Natural;
   begin
      if From > Buffer'Last then
         return (Status => Need_More, Packet_Id => 0, Payload_First => 1,
                 Payload_Last => 0, Next => From, Declared_Length => 0);
      end if;

      Length := Varnum.Decode_Varint (Buffer, From);
      if Length.Status /= Status_Kind'(Ok) then
         return (Status => Length.Status, Packet_Id => 0, Payload_First => 1,
                 Payload_Last => 0, Next => From, Declared_Length => 0);
      end if;

      if Length.Next - From > Max_Length_Bytes
        or else Length.Value > Interfaces.Unsigned_32 (Max_Packet_Length)
      then
         return (Status => Rejected, Packet_Id => 0, Payload_First => 1,
                 Payload_Last => 0, Next => From,
                 Declared_Length =>
                   (if Length.Value > Interfaces.Unsigned_32 (Natural'Last)
                    then Natural'Last
                    else Natural (Length.Value)));
      end if;

      Size := Natural (Length.Value);
      if Size = 0 then
         return
           (Status          => Status_Kind'(Ok),
            Packet_Id       => 0,
            Payload_First   => Length.Next,
            Payload_Last    => Length.Next - 1,
            Next            => Length.Next,
            Declared_Length => 0);
      end if;
      if Remaining (Buffer'Last, Length.Next) < Size then
         return (Status => Need_More, Packet_Id => 0, Payload_First => 1,
                 Payload_Last => 0, Next => From, Declared_Length => Size);
      end if;

      Payload_End := Length.Next + Size - 1;
      Ident := Varnum.Decode_Varint (Buffer, Length.Next);
      if Ident.Status /= Status_Kind'(Ok)
        or else Ident.Next < Length.Next
        or else Ident.Next > Payload_End + 1
        or else Ident.Value > Interfaces.Unsigned_32 (Natural'Last)
      then
         return (Status => Rejected, Packet_Id => 0, Payload_First => 1,
                 Payload_Last => 0, Next => From, Declared_Length => Size);
      end if;

      return
        (Status          => Status_Kind'(Ok),
         Packet_Id       => Natural (Ident.Value),
         Payload_First   => Ident.Next,
         Payload_Last    => Payload_End,
         Next            => Payload_End + 1,
         Declared_Length => Size);
   end Decode_Frame;
end Adacraft.Protocol.Frame;
