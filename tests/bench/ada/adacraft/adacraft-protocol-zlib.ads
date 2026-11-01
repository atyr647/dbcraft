with Interfaces.C;
with Interfaces.C.Strings;
with System;

package Adacraft.Protocol.Zlib is
   pragma Linker_Options ("-lz");

   Z_Ok              : constant := 0;
   Z_Stream_End      : constant := 1;
   Z_Need_Dict       : constant := 2;
   Z_Data_Error      : constant := -3;
   Z_Mem_Error       : constant := -4;
   Z_Buf_Error       : constant := -5;
   Z_Version_Error   : constant := -6;

   Z_No_Flush        : constant := 0;
   Z_Finish          : constant := 4;

   Z_Default_Compression : constant := -1;

   Zlib_Version : constant String := "1.2.12";

   type Z_Stream is private;

   type Z_Stream_Access is access all Z_Stream;
   pragma Convention (C, Z_Stream_Access);

   function Compress_Bound (Source_Len : Interfaces.C.unsigned_long)
     return Interfaces.C.unsigned_long;
   pragma Import (C, Compress_Bound, "compressBound");

   function Deflate_Init
     (Strm    : Z_Stream_Access;
      Level   : Interfaces.C.int;
      Version : Interfaces.C.Strings.chars_ptr;
      Size    : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Deflate_Init, "deflateInit_");

   function Deflate
     (Strm  : Z_Stream_Access;
      Flush : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Deflate, "deflate");

   function Deflate_End (Strm : Z_Stream_Access) return Interfaces.C.int;
   pragma Import (C, Deflate_End, "deflateEnd");

   function Inflate_Init
     (Strm    : Z_Stream_Access;
      Version : Interfaces.C.Strings.chars_ptr;
      Size    : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Inflate_Init, "inflateInit_");

   function Inflate
     (Strm  : Z_Stream_Access;
      Flush : Interfaces.C.int) return Interfaces.C.int;
   pragma Import (C, Inflate, "inflate");

   function Inflate_End (Strm : Z_Stream_Access) return Interfaces.C.int;
   pragma Import (C, Inflate_End, "inflateEnd");

   function Stream_Size return Interfaces.C.int;

   procedure Init_Stream (Strm : out Z_Stream);

   procedure Set_Input
     (Strm : in out Z_Stream; Data : System.Address;
      Len  : Interfaces.C.unsigned);

   procedure Set_Output
     (Strm : in out Z_Stream; Data : System.Address;
      Len  : Interfaces.C.unsigned);

   function Avail_In (Strm : Z_Stream) return Interfaces.C.unsigned;
   function Avail_Out (Strm : Z_Stream) return Interfaces.C.unsigned;
   function Total_Out (Strm : Z_Stream) return Interfaces.C.unsigned_long;

private

   type Z_Stream is record
      Next_In   : System.Address := System.Null_Address;
      Avail_In  : Interfaces.C.unsigned := 0;
      Total_In  : Interfaces.C.unsigned_long := 0;
      Next_Out  : System.Address := System.Null_Address;
      Avail_Out : Interfaces.C.unsigned := 0;
      Total_Out : Interfaces.C.unsigned_long := 0;
      Msg       : System.Address := System.Null_Address;
      State     : System.Address := System.Null_Address;
      Zalloc    : System.Address := System.Null_Address;
      Zfree     : System.Address := System.Null_Address;
      Opaque    : System.Address := System.Null_Address;
      Data_Type : Interfaces.C.int := 0;
      Adler     : Interfaces.C.unsigned_long := 0;
      Reserved  : Interfaces.C.unsigned_long := 0;
   end record;
   pragma Convention (C, Z_Stream);

end Adacraft.Protocol.Zlib;
