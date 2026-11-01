--  Best-of-N wall-clock timing of a parameterless procedure.
generic
   with procedure Work;
function Gw_Timing (Reps : Positive) return Duration;
