with Interfaces;

package Adacraft.Protocol is
   subtype Octet is Interfaces.Unsigned_8;
   type Octets is array (Positive range <>) of Octet;

   type Status_Kind is (Ok, Need_More, Rejected);

   Max_Packet_Length : constant := 2_097_151;
   Max_Varint_Bytes  : constant := 5;
   Max_Varlong_Bytes : constant := 10;
   Max_Length_Bytes  : constant := 3;

   --  Login_Phase names the LOGIN protocol state; the child package
   --  Adacraft.Protocol.Login contains its bounded-context handlers.
   type Protocol_State is (Handshake, Status, Login_Phase, Configuration, Play);
end Adacraft.Protocol;
