--  AES-128-CFB8 for the gateway benchmark.
--    * OpenSSL: a thin Interfaces.C binding to libcrypto EVP (aes-128-cfb8; uses AES-NI when the CPU has it).
--    * Soft:    a portable Ada implementation (S-box, key expansion, one block per byte), the analogue of the Rust "software" row.
with Interfaces;
with System;
with Adacraft.Protocol;

package Gw_Aes is
   pragma Linker_Options ("-lcrypto");

   subtype Octets is Adacraft.Protocol.Octets;

   --  ---- OpenSSL EVP ----
   type Direction is (Encrypt, Decrypt);

   type Cfb8_Ctx is limited private;

   procedure Open (C : in out Cfb8_Ctx; Dir : Direction; Key, Iv : Octets);
   --  Key and Iv are 16 bytes each.
   procedure Update (C : in out Cfb8_Ctx; Input : Octets; Output : out Octets);
   --  Output'Length >= Input'Length; processes Input.  Output and Input must not overlap.
   procedure Update_Raw (C : in out Cfb8_Ctx; Input : System.Address; Output : System.Address; Len : Natural);
   procedure Close (C : in out Cfb8_Ctx);

   --  ---- portable software AES-128 ----
   type Round_Keys is array (0 .. 175) of Interfaces.Unsigned_8;
   type Sbox_Table is array (Interfaces.Unsigned_8) of Interfaces.Unsigned_8;

   function Make_Sbox return Sbox_Table;
   function Expand_Key (Key : Octets; Sbox : Sbox_Table) return Round_Keys;
   procedure Cfb8_Encrypt_Soft
     (Rk : Round_Keys; Sbox : Sbox_Table; Iv : Octets; Input : Octets; Output : out Octets);

private
   type Cfb8_Ctx is limited record
      Ctx : System.Address := System.Null_Address;
      Dir : Direction := Encrypt;
   end record;
end Gw_Aes;
