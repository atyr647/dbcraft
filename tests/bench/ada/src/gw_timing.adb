with Ada.Real_Time;

function Gw_Timing (Reps : Positive) return Duration is
   use Ada.Real_Time;
   Best : Duration := Duration'Last;
   T0   : Time;
   D    : Duration;
begin
   for R in 1 .. Reps loop
      T0 := Clock;
      Work;
      D := To_Duration (Clock - T0);
      if D < Best then
         Best := D;
      end if;
   end loop;
   return Best;
end Gw_Timing;
