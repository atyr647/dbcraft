--  Loopback server in the style of adacraft's network layer: GNAT.Sockets + Check_Selector (select()), non-blocking, frame parser per connection.
--  Protocol = tests/bench/tcl/sock_client.py: clients send batches of 20 frames (1 length byte + 34 bytes), the server answers one byte per 20 frames.
--  env: PORT NCONN DUR   Prints one SOCKET line after DUR seconds measured once NCONN clients are connected.
with Ada.Environment_Variables; use Ada.Environment_Variables;
with Ada.Execution_Time;
with Ada.Real_Time;
with Ada.Streams;           use Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Text_IO;           use Ada.Text_IO;
with GNAT.Sockets;          use GNAT.Sockets;

procedure Sock_Select is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   package RT renames Ada.Real_Time;
   function Env (N : String; D : Integer) return Integer is (if Exists (N) then Integer'Value (Value (N)) else D);
   Port  : constant Integer := Env ("PORT", 25599);
   Nconn : constant Integer := Env ("NCONN", 900);
   Dur   : constant Integer := Env ("DUR", 10);
   Max_Conns : constant := 20_000;

   type Conn is record
      Sock      : Socket_Type;
      Active    : Boolean := False;
      Remain    : Natural := 0;
      Since_Ack : Natural := 0;
   end record;
   Conns : array (1 .. Max_Conns) of Conn;
   Active_Count : Natural := 0;

   Listener : Socket_Type;
   Sel      : Selector_Type;
   R, W     : Socket_Set_Type;
   Status   : Selector_Status;
   Buf      : Stream_Element_Array (1 .. 65536);
   Last     : Stream_Element_Offset;
   Ack      : constant Stream_Element_Array (1 .. 1) := (1 => 1);
   Frames   : Long_Long_Integer := 0;
   Started  : Boolean := False;
   T0, T_End : RT.Time;
   Cpu0     : Ada.Execution_Time.CPU_Time;
   F0       : Long_Long_Integer := 0;

   procedure Drop (I : Positive) is
   begin
      begin Close_Socket (Conns (I).Sock); exception when others => null; end;
      Conns (I).Active := False;
      Active_Count := Active_Count - 1;
   end Drop;

   procedure Pump (I : Positive) is
      B : Stream_Element;
   begin
      begin
         Receive_Socket (Conns (I).Sock, Buf, Last);
      exception when Socket_Error => Drop (I); return;
      end;
      if Last < Buf'First then
         Drop (I);
         return;
      end if;
      for K in Buf'First .. Last loop
         B := Buf (K);
         if Conns (I).Remain = 0 then
            Conns (I).Remain := Natural (B);
         else
            Conns (I).Remain := Conns (I).Remain - 1;
            if Conns (I).Remain = 0 then
               Frames := Frames + 1;
               Conns (I).Since_Ack := Conns (I).Since_Ack + 1;
               if Conns (I).Since_Ack = 20 then
                  Conns (I).Since_Ack := 0;
                  declare
                     L : Stream_Element_Offset;
                  begin
                     Send_Socket (Conns (I).Sock, Ack, L);
                  exception when Socket_Error => null;
                  end;
               end if;
            end if;
         end if;
      end loop;
   end Pump;
begin
   Create_Socket (Listener);
   Set_Socket_Option (Listener, Socket_Level, (Reuse_Address, True));
   Bind_Socket (Listener, (Family_Inet, Inet_Addr ("127.0.0.1"), Port_Type (Port)));
   Listen_Socket (Listener, 4096);
   Create_Selector (Sel);
   declare
      Deadline : constant RT.Time := RT.Clock + RT.Seconds (Dur + 60);
   begin
      loop
         exit when RT.Clock > Deadline;
         exit when Started and then RT.Clock >= T_End;
         Empty (R);
         Empty (W);
         Set (R, Listener);
         for I in 1 .. Max_Conns loop
            if Conns (I).Active then
               Set (R, Conns (I).Sock);
            end if;
         end loop;
         Check_Selector (Sel, R, W, Status, 0.05);
         if Status = Completed then
            if Is_Set (R, Listener) then
               declare
                  S : Socket_Type;
                  A : Sock_Addr_Type;
               begin
                  Accept_Socket (Listener, S, A);
                  for I in 1 .. Max_Conns loop
                     if not Conns (I).Active then
                        Conns (I) := (Sock => S, Active => True, Remain => 0, Since_Ack => 0);
                        Active_Count := Active_Count + 1;
                        exit;
                     end if;
                  end loop;
                  Set_Socket_Option (S, IP_Protocol_For_TCP_Level, (No_Delay, True));
               end;
            end if;
            for I in 1 .. Max_Conns loop
               if Conns (I).Active and then Is_Set (R, Conns (I).Sock) then
                  Pump (I);
               end if;
            end loop;
         end if;
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
         Put_Line ("SOCKET select conns=" & Integer'Image (Active_Count) & " seconds=" & Duration'Image (Secs)
                   & " frames=" & Long_Long_Integer'Image (N)
                   & " frames_per_s=" & Long_Long_Integer'Image (Long_Long_Integer (Long_Float (N) / Long_Float (Secs)))
                   & " server_cpu_busy_pct=" & Integer'Image (Integer (100.0 * Long_Float (Cpu) / Long_Float (Secs)))
                   & " frames_per_cpu_s=" & Long_Long_Integer'Image (Long_Long_Integer (Long_Float (N) / Long_Float (Cpu))));
      end;
   else
      Put_Line ("SOCKET select timeout: only" & Integer'Image (Active_Count) & " clients connected");
   end if;
end Sock_Select;
