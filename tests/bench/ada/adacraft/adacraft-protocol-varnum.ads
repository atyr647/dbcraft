with Interfaces;

package Adacraft.Protocol.Varnum
  with SPARK_Mode => On
is
   use type Interfaces.Integer_32;
   use type Interfaces.Integer_64;

   --  Bounded 32-bit VarInt codec. Malformed or short input is reported
   --  through Status_Type; no operation raises an exception.

   type Status_Type is (Ok, Truncated, Overlong, Buffer_Too_Small);

   function Encoded_Length (Value : Interfaces.Integer_32) return Natural
     with
       Global => null,
       Post   => Encoded_Length'Result in 1 .. Max_Varint_Bytes
                 and then (if Value < 0 then Encoded_Length'Result = 5);
   --  Exact number of bytes Encode writes for Value (minimal form).

   procedure Encode
     (Value       : in     Interfaces.Integer_32;
      Buffer      : in out Octets;
      Start_Index : in     Integer;
      Written     :    out Natural;
      Status      :    out Status_Type)
     with
       Global => null,
       Post   =>
         (if Status = Ok
          then Written = Encoded_Length (Value)
          else Status = Buffer_Too_Small
               and then Written = 0
               and then Buffer = Buffer'Old);
   --  Writes the minimal VarInt at Buffer (Start_Index ..). If the full
   --  encoding does not fit inside Buffer'Range from Start_Index, returns
   --  Buffer_Too_Small, writes nothing and leaves Buffer unchanged.

   procedure Decode
     (Buffer      : in     Octets;
      Start_Index : in     Integer;
      Value       :    out Interfaces.Integer_32;
      Consumed    :    out Natural;
      Status      :    out Status_Type)
     with
       Global => null,
       Post   =>
         (if Status = Ok
          then Consumed in 1 .. Max_Varint_Bytes
          else Status in Truncated | Overlong
               and then Value = 0
               and then Consumed = 0);
   --  Reads at most 5 bytes from Buffer (Start_Index ..), never outside
   --  Buffer'Range and never past the terminating byte.
   --  Truncated: no available byte at Start_Index, or the buffer ends
   --  before a terminating byte. Overlong: the 5th byte has the
   --  continuation bit set or is greater than 16#0F#. Non-minimal forms
   --  within 5 bytes are accepted.

   function Encoded_Length_VarLong (Value : Interfaces.Integer_64) return Natural
     with
       Global => null,
       Post   => Encoded_Length_VarLong'Result in 1 .. Max_Varlong_Bytes;
   --  Exact number of bytes Encode_VarLong writes (negatives: 10).

   procedure Encode_VarLong
     (Value       : in     Interfaces.Integer_64;
      Buffer      : in out Octets;
      Start_Index : in     Integer;
      Written     :    out Natural;
      Status      :    out Status_Type)
     with
       Global => null,
       Post   =>
         (if Status = Ok
          then Written = Encoded_Length_VarLong (Value)
          else Status = Buffer_Too_Small
               and then Written = 0
               and then Buffer = Buffer'Old);

   procedure Decode_VarLong
     (Buffer      : in     Octets;
      Start_Index : in     Integer;
      Value       :    out Interfaces.Integer_64;
      Consumed    :    out Natural;
      Status      :    out Status_Type)
     with
       Global => null,
       Post   =>
         (if Status = Ok
          then Consumed in 1 .. Max_Varlong_Bytes
          else Status in Truncated | Overlong
               and then Value = 0
               and then Consumed = 0);
   --  Reads at most 10 bytes. Overlong: the 10th byte has the continuation
   --  bit set or payload above 1. Non-minimal forms are accepted.

   --  Compatibility wrapper for existing callers (frame, buffer, packets):
   --  same shape and strictness as the previous Decode_Varint, which also
   --  rejects non-minimal forms.
   type Varint_Result is record
      Status : Status_Kind            := Rejected;
      Value  : Interfaces.Unsigned_32 := 0;
      Next   : Natural                := 0;
   end record;

   type VarLong_Result is record
      Status : Status_Kind            := Rejected;
      Value  : Interfaces.Unsigned_64 := 0;
      Next   : Natural                := 0;
   end record;

   function Decode_Varint (Buffer : Octets; From : Positive) return Varint_Result
     with
       Global => null,
       Pre    => Buffer'Last < Positive'Last
                 and then From <= Buffer'Last + 1,
       Post   =>
         (if Decode_Varint'Result.Status = Status_Kind'(Ok)
          then Decode_Varint'Result.Next in From + 1 .. From + Max_Varint_Bytes
               and then Decode_Varint'Result.Next - 1 <= Buffer'Last)
         and then (if Decode_Varint'Result.Status /= Status_Kind'(Ok)
                   then Decode_Varint'Result.Next = From);

   function Decode_VarLong (Buffer : Octets; From : Positive) return VarLong_Result
     with
       Pre  => Buffer'Last < Positive'Last
               and then From <= Buffer'Last + 1,
       Post =>
         (if Decode_VarLong'Result.Status = Status_Kind'(Ok)
          then Decode_VarLong'Result.Next in From + 1 .. From + Max_Varlong_Bytes
               and then Decode_VarLong'Result.Next - 1 <= Buffer'Last)
         and then (if Decode_VarLong'Result.Status /= Status_Kind'(Ok)
                   then Decode_VarLong'Result.Next = From);
end Adacraft.Protocol.Varnum;
