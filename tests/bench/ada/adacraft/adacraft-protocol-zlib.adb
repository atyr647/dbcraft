with System;

package body Adacraft.Protocol.Zlib is

   function Stream_Size return Interfaces.C.int is
   begin
      return Interfaces.C.int (Z_Stream'Size / System.Storage_Unit);
   end Stream_Size;

   procedure Init_Stream (Strm : out Z_Stream) is
      Empty : Z_Stream;
   begin
      Empty.Next_In := System.Null_Address;
      Empty.Avail_In := 0;
      Empty.Total_In := 0;
      Empty.Next_Out := System.Null_Address;
      Empty.Avail_Out := 0;
      Empty.Total_Out := 0;
      Empty.Msg := System.Null_Address;
      Empty.State := System.Null_Address;
      Empty.Zalloc := System.Null_Address;
      Empty.Zfree := System.Null_Address;
      Empty.Opaque := System.Null_Address;
      Empty.Data_Type := 0;
      Empty.Adler := 0;
      Empty.Reserved := 0;
      Strm := Empty;
   end Init_Stream;

   procedure Set_Input
     (Strm : in out Z_Stream; Data : System.Address;
      Len  : Interfaces.C.unsigned) is
   begin
      Strm.Next_In := Data;
      Strm.Avail_In := Len;
   end Set_Input;

   procedure Set_Output
     (Strm : in out Z_Stream; Data : System.Address;
      Len  : Interfaces.C.unsigned) is
   begin
      Strm.Next_Out := Data;
      Strm.Avail_Out := Len;
   end Set_Output;

   function Avail_In (Strm : Z_Stream) return Interfaces.C.unsigned is
   begin
      return Strm.Avail_In;
   end Avail_In;

   function Avail_Out (Strm : Z_Stream) return Interfaces.C.unsigned is
   begin
      return Strm.Avail_Out;
   end Avail_Out;

   function Total_Out (Strm : Z_Stream) return Interfaces.C.unsigned_long is
   begin
      return Strm.Total_Out;
   end Total_Out;

end Adacraft.Protocol.Zlib;
