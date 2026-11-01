with Interfaces;

package Adacraft.Protocol.Buffer is
   type Writer (Capacity : Positive) is record
      Data   : Octets (1 .. Capacity) := (others => 0);
      Len    : Natural := 0;
      Failed : Boolean := False;
   end record;

   procedure Reset (W : in out Writer);
   procedure Put_Octet (W : in out Writer; Value : Octet);
   procedure Put_Bytes (W : in out Writer; Value : Octets);
   procedure Put_Varint (W : in out Writer; Value : Interfaces.Unsigned_32);
   procedure Put_U16 (W : in out Writer; Value : Interfaces.Unsigned_16);
   procedure Put_U64 (W : in out Writer; Value : Interfaces.Unsigned_64);
   procedure Put_String (W : in out Writer; Value : String);

   type String_Decode is record
      Status : Status_Kind := Rejected;
      Text   : String (1 .. 32767) := (others => ' ');
      Length : Natural := 0;
      Next   : Natural := 0;
   end record;

   function Decode_String
     (Buffer : Octets; From : Positive; Max_Chars : Positive) return String_Decode;

   function Decode_U16
     (Buffer : Octets; From : Positive) return Interfaces.Unsigned_16;

   function U16_Ok (Buffer : Octets; From : Positive) return Boolean;

   function Decode_U64
     (Buffer : Octets; From : Positive) return Interfaces.Unsigned_64;

   function U64_Ok (Buffer : Octets; From : Positive) return Boolean;
end Adacraft.Protocol.Buffer;
