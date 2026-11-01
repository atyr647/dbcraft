with Interfaces.C;

package body Gw_Aes is
   use type Interfaces.Unsigned_8;
   use type Interfaces.C.int;
   use type System.Address;

   --  ---- libcrypto imports ----
   function EVP_CIPHER_CTX_new return System.Address;
   pragma Import (C, EVP_CIPHER_CTX_new, "EVP_CIPHER_CTX_new");
   procedure EVP_CIPHER_CTX_free (Ctx : System.Address);
   pragma Import (C, EVP_CIPHER_CTX_free, "EVP_CIPHER_CTX_free");
   function EVP_aes_128_cfb8 return System.Address;
   pragma Import (C, EVP_aes_128_cfb8, "EVP_aes_128_cfb8");
   function EVP_EncryptInit_ex
     (Ctx, Cipher, Impl, Key, Iv : System.Address) return Interfaces.C.int;
   pragma Import (C, EVP_EncryptInit_ex, "EVP_EncryptInit_ex");
   function EVP_DecryptInit_ex
     (Ctx, Cipher, Impl, Key, Iv : System.Address) return Interfaces.C.int;
   pragma Import (C, EVP_DecryptInit_ex, "EVP_DecryptInit_ex");
   function EVP_EncryptUpdate
     (Ctx, Output : System.Address; Outl : access Interfaces.C.int;
      Input : System.Address; Inl : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, EVP_EncryptUpdate, "EVP_EncryptUpdate");
   function EVP_DecryptUpdate
     (Ctx, Output : System.Address; Outl : access Interfaces.C.int;
      Input : System.Address; Inl : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, EVP_DecryptUpdate, "EVP_DecryptUpdate");

   procedure Open (C : in out Cfb8_Ctx; Dir : Direction; Key, Iv : Octets) is
      Rc : Interfaces.C.int;
   begin
      C.Ctx := EVP_CIPHER_CTX_new;
      C.Dir := Dir;
      if Dir = Encrypt then
         Rc := EVP_EncryptInit_ex (C.Ctx, EVP_aes_128_cfb8, System.Null_Address, Key (Key'First)'Address, Iv (Iv'First)'Address);
      else
         Rc := EVP_DecryptInit_ex (C.Ctx, EVP_aes_128_cfb8, System.Null_Address, Key (Key'First)'Address, Iv (Iv'First)'Address);
      end if;
      if Rc /= 1 then
         raise Program_Error with "EVP init failed";
      end if;
   end Open;

   procedure Update_Raw
     (C : in out Cfb8_Ctx; Input : System.Address; Output : System.Address; Len : Natural)
   is
      Outl : aliased Interfaces.C.int := 0;
      Rc   : Interfaces.C.int;
   begin
      if C.Dir = Encrypt then
         Rc := EVP_EncryptUpdate (C.Ctx, Output, Outl'Access, Input, Interfaces.C.int (Len));
      else
         Rc := EVP_DecryptUpdate (C.Ctx, Output, Outl'Access, Input, Interfaces.C.int (Len));
      end if;
      if Rc /= 1 or else Natural (Outl) /= Len then
         raise Program_Error with "EVP update failed";
      end if;
   end Update_Raw;

   procedure Update (C : in out Cfb8_Ctx; Input : Octets; Output : out Octets) is
   begin
      if Input'Length > 0 then
         Update_Raw (C, Input (Input'First)'Address, Output (Output'First)'Address, Input'Length);
      end if;
   end Update;

   procedure Close (C : in out Cfb8_Ctx) is
   begin
      if C.Ctx /= System.Null_Address then
         EVP_CIPHER_CTX_free (C.Ctx);
         C.Ctx := System.Null_Address;
      end if;
   end Close;

   --  ---- portable software AES-128 ----
   Rcon : constant array (1 .. 10) of Interfaces.Unsigned_8 :=
     (1, 2, 4, 8, 16, 32, 64, 128, 16#1B#, 16#36#);

   function Gmul (A0, B0 : Interfaces.Unsigned_8) return Interfaces.Unsigned_8 is
      A : Interfaces.Unsigned_8 := A0;
      B : Interfaces.Unsigned_8 := B0;
      P : Interfaces.Unsigned_8 := 0;
      Hi : Interfaces.Unsigned_8;
   begin
      for I in 1 .. 8 loop
         if (B and 1) /= 0 then
            P := P xor A;
         end if;
         Hi := A and 16#80#;
         A := Interfaces.Shift_Left (A, 1);
         if Hi /= 0 then
            A := A xor 16#1B#;
         end if;
         B := Interfaces.Shift_Right (B, 1);
      end loop;
      return P;
   end Gmul;

   function Make_Sbox return Sbox_Table is
      T   : Sbox_Table := (others => 0);
      Inv : Interfaces.Unsigned_8;
      S, R : Interfaces.Unsigned_8;
   begin
      for X in Interfaces.Unsigned_8 loop
         Inv := 0;
         if X /= 0 then
            for Y in 1 .. Interfaces.Unsigned_8'Last loop
               if Gmul (X, Y) = 1 then
                  Inv := Y;
                  exit;
               end if;
            end loop;
         end if;
         S := Inv;
         R := Inv;
         for K in 1 .. 4 loop
            R := Interfaces.Rotate_Left (R, 1);
            S := S xor R;
         end loop;
         T (X) := S xor 16#63#;
      end loop;
      return T;
   end Make_Sbox;

   function Expand_Key (Key : Octets; Sbox : Sbox_Table) return Round_Keys is
      W : Round_Keys := (others => 0);
      T0, T1, T2, T3 : Interfaces.Unsigned_8;
   begin
      for I in 0 .. 15 loop
         W (I) := Key (Key'First + I);
      end loop;
      for I in 4 .. 43 loop
         T0 := W (4 * I - 4);
         T1 := W (4 * I - 3);
         T2 := W (4 * I - 2);
         T3 := W (4 * I - 1);
         if I mod 4 = 0 then
            declare
               N0 : constant Interfaces.Unsigned_8 := Sbox (T1) xor Rcon (I / 4);
               N1 : constant Interfaces.Unsigned_8 := Sbox (T2);
               N2 : constant Interfaces.Unsigned_8 := Sbox (T3);
               N3 : constant Interfaces.Unsigned_8 := Sbox (T0);
            begin
               T0 := N0; T1 := N1; T2 := N2; T3 := N3;
            end;
         end if;
         W (4 * I)     := W (4 * (I - 4))     xor T0;
         W (4 * I + 1) := W (4 * (I - 4) + 1) xor T1;
         W (4 * I + 2) := W (4 * (I - 4) + 2) xor T2;
         W (4 * I + 3) := W (4 * (I - 4) + 3) xor T3;
      end loop;
      return W;
   end Expand_Key;

   type Block is array (0 .. 15) of Interfaces.Unsigned_8;

   function Encrypt_Block (Rk : Round_Keys; Sbox : Sbox_Table; B : Block) return Block is
      S, T : Block := B;
   begin
      for I in 0 .. 15 loop
         S (I) := S (I) xor Rk (I);
      end loop;
      for Round in 1 .. 10 loop
         for I in 0 .. 15 loop
            S (I) := Sbox (S (I));
         end loop;
         T := S;
         for C in 0 .. 3 loop
            for R in 0 .. 3 loop
               S (4 * C + R) := T (4 * ((C + R) mod 4) + R);
            end loop;
         end loop;
         if Round /= 10 then
            for C in 0 .. 3 loop
               declare
                  A0 : constant Interfaces.Unsigned_8 := S (4 * C);
                  A1 : constant Interfaces.Unsigned_8 := S (4 * C + 1);
                  A2 : constant Interfaces.Unsigned_8 := S (4 * C + 2);
                  A3 : constant Interfaces.Unsigned_8 := S (4 * C + 3);
               begin
                  S (4 * C)     := Gmul (A0, 2) xor Gmul (A1, 3) xor A2 xor A3;
                  S (4 * C + 1) := A0 xor Gmul (A1, 2) xor Gmul (A2, 3) xor A3;
                  S (4 * C + 2) := A0 xor A1 xor Gmul (A2, 2) xor Gmul (A3, 3);
                  S (4 * C + 3) := Gmul (A0, 3) xor A1 xor A2 xor Gmul (A3, 2);
               end;
            end loop;
         end if;
         for I in 0 .. 15 loop
            S (I) := S (I) xor Rk (16 * Round + I);
         end loop;
      end loop;
      return S;
   end Encrypt_Block;

   procedure Cfb8_Encrypt_Soft
     (Rk : Round_Keys; Sbox : Sbox_Table; Iv : Octets; Input : Octets; Output : out Octets)
   is
      Reg : Block;
      K, C : Interfaces.Unsigned_8;
      O : Natural := Output'First;
   begin
      for I in 0 .. 15 loop
         Reg (I) := Iv (Iv'First + I);
      end loop;
      for P of Input loop
         K := Encrypt_Block (Rk, Sbox, Reg) (0);
         C := P xor K;
         Output (O) := C;
         O := O + 1;
         for I in 0 .. 14 loop
            Reg (I) := Reg (I + 1);
         end loop;
         Reg (15) := C;
      end loop;
   end Cfb8_Encrypt_Soft;

begin
   null;
end Gw_Aes;
