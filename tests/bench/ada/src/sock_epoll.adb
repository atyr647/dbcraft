--  Same server on a hand-written epoll binding (libc imports, no GNAT.Sockets).  Level-triggered, one read per ready fd.
--  env: PORT NCONN DUR.  Prints one SOCKET line.
with Ada.Environment_Variables; use Ada.Environment_Variables;
with Ada.Execution_Time;
with Ada.Real_Time;
with Ada.Text_IO;           use Ada.Text_IO;
with Interfaces.C;          use Interfaces.C;
with Interfaces;
with System;

procedure Sock_Epoll is
   use type Ada.Real_Time.Time;
   use type Ada.Execution_Time.CPU_Time;
   package RT renames Ada.Real_Time;
   function Env (N : String; D : Integer) return Integer is (if Exists (N) then Integer'Value (Value (N)) else D);
   Port  : constant Integer := Env ("PORT", 25599);
   Nconn : constant Integer := Env ("NCONN", 900);
   Dur   : constant Integer := Env ("DUR", 10);

   AF_INET : constant int := 2;
   SOCK_STREAM : constant int := 1;
   SOCK_NONBLOCK : constant int := 2048;
   SOL_SOCKET : constant int := 1;
   SO_REUSEADDR : constant int := 2;
   IPPROTO_TCP : constant int := 6;
   TCP_NODELAY : constant int := 1;
   EPOLLIN : constant Interfaces.Unsigned_32 := 1;
   EPOLL_CTL_ADD : constant int := 1;
   EPOLL_CTL_DEL : constant int := 2;

   type U8_Array is array (0 .. 7) of unsigned_char;
   type Sockaddr_In is record
      Family : unsigned_short;
      Port   : unsigned_short;      --  network byte order
      Addr   : unsigned;            --  network byte order
      Zero   : U8_Array := (others => 0);
   end record;
   pragma Convention (C, Sockaddr_In);

   --  glibc struct epoll_event is packed to 12 bytes on x86-64: u32 events, u64 data.  Three u32 give the same layout.
   type Epoll_Event is record
      Events  : Interfaces.Unsigned_32;
      Data_Lo : Interfaces.Unsigned_32;
      Data_Hi : Interfaces.Unsigned_32;
   end record;
   pragma Convention (C, Epoll_Event);
   type Event_Array is array (0 .. 1023) of Epoll_Event;
   pragma Convention (C, Event_Array);

   function C_socket (D, T, P : int) return int;
   pragma Import (C, C_socket, "socket");
   function C_setsockopt (Fd, Level, Name : int; Val : System.Address; Len : unsigned) return int;
   pragma Import (C, C_setsockopt, "setsockopt");
   function C_bind (Fd : int; Addr : System.Address; Len : unsigned) return int;
   pragma Import (C, C_bind, "bind");
   function C_listen (Fd, Backlog : int) return int;
   pragma Import (C, C_listen, "listen");
   function C_accept4 (Fd : int; A, L : System.Address; Flags : int) return int;
   pragma Import (C, C_accept4, "accept4");
   function C_read (Fd : int; Buf : System.Address; N : size_t) return long;
   pragma Import (C, C_read, "read");
   function C_write (Fd : int; Buf : System.Address; N : size_t) return long;
   pragma Import (C, C_write, "write");
   function C_close (Fd : int) return int;
   pragma Import (C, C_close, "close");
   function C_epoll_create1 (Flags : int) return int;
   pragma Import (C, C_epoll_create1, "epoll_create1");
   function C_epoll_ctl (Ep, Op, Fd : int; Ev : System.Address) return int;
   pragma Import (C, C_epoll_ctl, "epoll_ctl");
   function C_epoll_wait (Ep : int; Evs : System.Address; Max, Timeout : int) return int;
   pragma Import (C, C_epoll_wait, "epoll_wait");

   Max_Fd : constant := 40_000;
   type Conn is record
      Open      : Boolean := False;
      Remain    : Natural := 0;
      Since_Ack : Natural := 0;
   end record;
   Conns : array (0 .. Max_Fd) of Conn;
   Active_Count : Natural := 0;

   Events : aliased Event_Array;
   Buf    : aliased array (1 .. 65536) of unsigned_char;
   Ack    : aliased unsigned_char := 1;
   One    : aliased int := 1;
   Frames : Long_Long_Integer := 0;
   Started : Boolean := False;
   T0, T_End : RT.Time;
   Cpu0   : Ada.Execution_Time.CPU_Time;
   F0     : Long_Long_Integer := 0;
   Listener, Ep, Rc : int;

   function Htons (P : Integer) return unsigned_short is
     (unsigned_short ((P mod 256) * 256 + P / 256));

   procedure Drop (Fd : int) is
      Dummy : Epoll_Event := (0, 0, 0);
   begin
      Rc := C_epoll_ctl (Ep, EPOLL_CTL_DEL, Fd, Dummy'Address);
      Rc := C_close (Fd);
      if Conns (Natural (Fd)).Open then
         Conns (Natural (Fd)).Open := False;
         Active_Count := Active_Count - 1;
      end if;
   end Drop;

   procedure Pump (Fd : int) is
      N : long;
      C : Conn renames Conns (Natural (Fd));
      B : unsigned_char;
      W : long;
   begin
      N := C_read (Fd, Buf'Address, Buf'Length);
      if N <= 0 then
         Drop (Fd);
         return;
      end if;
      for K in 1 .. Integer (N) loop
         B := Buf (K);
         if C.Remain = 0 then
            C.Remain := Natural (B);
         else
            C.Remain := C.Remain - 1;
            if C.Remain = 0 then
               Frames := Frames + 1;
               C.Since_Ack := C.Since_Ack + 1;
               if C.Since_Ack = 20 then
                  C.Since_Ack := 0;
                  W := C_write (Fd, Ack'Address, 1);
               end if;
            end if;
         end if;
      end loop;
   end Pump;
begin
   Listener := C_socket (AF_INET, SOCK_STREAM + SOCK_NONBLOCK, 0);
   Rc := C_setsockopt (Listener, SOL_SOCKET, SO_REUSEADDR, One'Address, 4);
   declare
      A : aliased Sockaddr_In := (Family => unsigned_short (AF_INET), Port => Htons (Port), Addr => 16#0100007F#, Zero => (others => 0));
   begin
      if C_bind (Listener, A'Address, 16) /= 0 then
         Put_Line ("bind failed");
         return;
      end if;
   end;
   Rc := C_listen (Listener, 4096);
   Ep := C_epoll_create1 (0);
   declare
      Ev : aliased Epoll_Event := (EPOLLIN, Interfaces.Unsigned_32 (Listener), 0);
   begin
      Rc := C_epoll_ctl (Ep, EPOLL_CTL_ADD, Listener, Ev'Address);
   end;
   declare
      Deadline : constant RT.Time := RT.Clock + RT.Seconds (Dur + 60);
      Nev : int;
      Fd  : int;
   begin
      loop
         exit when RT.Clock > Deadline;
         exit when Started and then RT.Clock >= T_End;
         Nev := C_epoll_wait (Ep, Events'Address, 1024, 50);
         for I in 0 .. Nev - 1 loop
            Fd := int (Events (Natural (I)).Data_Lo);
            if Fd = Listener then
               loop
                  declare
                     S : constant int := C_accept4 (Listener, System.Null_Address, System.Null_Address, SOCK_NONBLOCK);
                     Ev : aliased Epoll_Event;
                  begin
                     exit when S < 0;
                     Rc := C_setsockopt (S, IPPROTO_TCP, TCP_NODELAY, One'Address, 4);
                     Conns (Natural (S)) := (Open => True, Remain => 0, Since_Ack => 0);
                     Active_Count := Active_Count + 1;
                     Ev := (EPOLLIN, Interfaces.Unsigned_32 (S), 0);
                     Rc := C_epoll_ctl (Ep, EPOLL_CTL_ADD, S, Ev'Address);
                  end;
               end loop;
            else
               Pump (Fd);
            end if;
         end loop;
         if not Started and then Active_Count >= Nconn then
            Started := True;
            T0 := RT.Clock; T_End := T0 + RT.Seconds (Dur); F0 := Frames; Cpu0 := Ada.Execution_Time.Clock;
         end if;
      end loop;
   end;
   if Started then
      declare
         Secs : constant Duration := RT.To_Duration (RT.Clock - T0);
         Cpu  : constant Duration := RT.To_Duration (Ada.Execution_Time.Clock - Cpu0);
         N    : constant Long_Long_Integer := Frames - F0;
      begin
         Put_Line ("SOCKET epoll conns=" & Integer'Image (Active_Count) & " seconds=" & Duration'Image (Secs)
                   & " frames=" & Long_Long_Integer'Image (N)
                   & " frames_per_s=" & Long_Long_Integer'Image (Long_Long_Integer (Long_Float (N) / Long_Float (Secs)))
                   & " server_cpu_busy_pct=" & Integer'Image (Integer (100.0 * Long_Float (Cpu) / Long_Float (Secs)))
                   & " frames_per_cpu_s=" & Long_Long_Integer'Image (Long_Long_Integer (Long_Float (N) / Long_Float (Cpu))));
      end;
   else
      Put_Line ("SOCKET epoll timeout: only" & Integer'Image (Active_Count) & " clients connected");
   end if;
end Sock_Epoll;
