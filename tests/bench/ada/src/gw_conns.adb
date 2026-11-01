package body Gw_Conns is

   Kinds : constant array (0 .. 3) of Natural := (16#1C#, 16#1D#, 6, 16#1B#);

   function Packet_Id (C, R : Natural) return Natural is
     (if R < 3 then 0 else Kinds ((C + R) mod 4));

   function Packet_Len (C, R : Natural) return Natural is
     (10 + ((C * 7 + R * 13) mod 40));

   type State_Rec is record
      State : Natural := 0;
      T     : Totals;
   end record;

   procedure Step (S : in out State_Rec; Id, Len : Natural) is
   begin
      S.T.Bytes := S.T.Bytes + Long_Long_Integer (Len);
      case S.State is
         when 0 => S.State := 1;
         when 1 => S.State := 2;
         when 2 => S.State := 3;
         when others =>
            if Id = 16#1C# or else Id = 16#1D# then
               S.T.Moves := S.T.Moves + 1;
            elsif Id = 6 then
               S.T.Chats := S.T.Chats + 1;
            else
               S.T.Other := S.T.Other + 1;
            end if;
      end case;
   end Step;

   function Run_Plain (Nconn, Rounds : Natural) return Totals is
      type State_Array is array (Natural range <>) of State_Rec;
      Conns : State_Array (0 .. Nconn - 1);
      Sum   : Totals;
   begin
      for R in 0 .. Rounds - 1 loop
         for C in 0 .. Nconn - 1 loop
            Step (Conns (C), Packet_Id (C, R), Packet_Len (C, R));
         end loop;
      end loop;
      for C of Conns loop
         Sum.Moves := Sum.Moves + C.T.Moves;
         Sum.Chats := Sum.Chats + C.T.Chats;
         Sum.Other := Sum.Other + C.T.Other;
         Sum.Bytes := Sum.Bytes + C.T.Bytes;
      end loop;
      return Sum;
   end Run_Plain;

   --  ---- shared collector for the task variants ----
   protected Collector is
      procedure Reset (Expected : Natural);
      procedure Add (T : Totals);
      entry Wait (Result : out Totals);
   private
      Want  : Natural := 0;
      Got   : Natural := 0;
      Sum   : Totals;
   end Collector;

   protected body Collector is
      procedure Reset (Expected : Natural) is
      begin
         Want := Expected;
         Got  := 0;
         Sum  := (others => 0);
      end Reset;

      procedure Add (T : Totals) is
      begin
         Sum.Moves := Sum.Moves + T.Moves;
         Sum.Chats := Sum.Chats + T.Chats;
         Sum.Other := Sum.Other + T.Other;
         Sum.Bytes := Sum.Bytes + T.Bytes;
         Got := Got + 1;
      end Add;

      entry Wait (Result : out Totals) when Got = Want is
      begin
         Result := Sum;
      end Wait;
   end Collector;

   Task_Stack : constant := 128 * 1024;

   task type Rdv_Task (Rounds : Natural) with Storage_Size => Task_Stack is
      entry Deliver (Id, Len : Natural);
   end Rdv_Task;

   task body Rdv_Task is
      S : State_Rec;
   begin
      for I in 1 .. Rounds loop
         accept Deliver (Id, Len : Natural) do
            Step (S, Id, Len);
         end Deliver;
      end loop;
      Collector.Add (S.T);
   end Rdv_Task;

   type Rdv_Access is access Rdv_Task;

   function Run_Tasks_Rdv (Nconn, Rounds : Natural) return Totals is
      Tasks : array (0 .. Nconn - 1) of Rdv_Access;
      Result : Totals;
   begin
      Collector.Reset (Nconn);
      for C in Tasks'Range loop
         Tasks (C) := new Rdv_Task (Rounds);
      end loop;
      for R in 0 .. Rounds - 1 loop
         for C in Tasks'Range loop
            Tasks (C).Deliver (Packet_Id (C, R), Packet_Len (C, R));
         end loop;
      end loop;
      Collector.Wait (Result);
      return Result;
   end Run_Tasks_Rdv;

   task type Local_Task (C : Natural; Rounds : Natural) with Storage_Size => Task_Stack;

   task body Local_Task is
      S : State_Rec;
   begin
      for R in 0 .. Rounds - 1 loop
         Step (S, Packet_Id (C, R), Packet_Len (C, R));
      end loop;
      Collector.Add (S.T);
   end Local_Task;

   type Local_Access is access Local_Task;

   function Run_Tasks_Local (Nconn, Rounds : Natural) return Totals is
      Tasks : array (0 .. Nconn - 1) of Local_Access;
      Result : Totals;
   begin
      Collector.Reset (Nconn);
      for C in Tasks'Range loop
         Tasks (C) := new Local_Task (C, Rounds);
      end loop;
      Collector.Wait (Result);
      return Result;
   end Run_Tasks_Local;
end Gw_Conns;
