with Ada.Streams;
with Interfaces;
with Adacraft.Protocol.Frame;

--  Provenance: protocol 777 (26.3) packet report
--  generated/26.3/reports/packets.json via
--  generated/adacraft-protocol-ids.ads:
--  clientbound minecraft:login_finished = 2 (Login Success),
--  clientbound minecraft:login_disconnect = 0.
package Adacraft.Protocol.Packet_Encoder is

   subtype Byte is Ada.Streams.Stream_Element;

   type Encoder_Type
     (Capacity : Positive := Adacraft.Protocol.Frame.Max_Frame_Body_Length)
   is record
      Storage : Ada.Streams.Stream_Element_Array
        (1 .. Adacraft.Protocol.Frame.Max_Frame_Body_Length) :=
          (others => 0);
      Count   : Natural := 0;
      Failed  : Boolean := False;
      Started : Boolean := False;
   end record;

   procedure Start_Packet (E : in out Encoder_Type; Packet_Id : Natural);

   procedure Write_Boolean (E : in out Encoder_Type; V : Boolean);

   procedure Write_Byte (E : in out Encoder_Type; V : Byte);

   procedure Write_Int (E : in out Encoder_Type; V : Interfaces.Integer_32);

   procedure Write_Long (E : in out Encoder_Type; V : Interfaces.Integer_64);

   procedure Get_Framed
     (E      : in out Encoder_Type;
      Output : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   procedure Get_Body
     (E     : in Encoder_Type;
      Data  : out Ada.Streams.Stream_Element_Array;
      Last  : out Ada.Streams.Stream_Element_Offset);

   --  Login Success (clientbound id 2): offline UUID (16 bytes) +
   --  validated name (String) + empty properties array (VarInt 0).
   --  No encryption, compression, or plugin bytes.
   procedure Encode_Login_Success
     (E    : in out Encoder_Type;
      Uuid : Adacraft.Protocol.Octets;
      Name : String);

   --  Login Disconnect (clientbound id 0, FR-5.5): single JSON text
   --  component encoded as a protocol String.
   procedure Encode_Login_Disconnect
     (E      : in out Encoder_Type;
      Reason : String);

   function Has_Failed (E : Encoder_Type) return Boolean;

   function Length (E : Encoder_Type) return Natural;

end Adacraft.Protocol.Packet_Encoder;
