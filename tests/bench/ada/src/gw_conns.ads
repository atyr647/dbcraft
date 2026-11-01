--  2,000 connection state machines x 100 rounds (the same model as the Rust and Tcl benchmarks):
--  first 3 packets of a connection move it through 3 handshake-like states; later packets are classified by id.
package Gw_Conns is
   type Totals is record
      Moves, Chats, Other, Bytes : Long_Long_Integer := 0;
   end record;

   function Run_Plain (Nconn, Rounds : Natural) return Totals;
   --  one loop, one state record per connection (what a Rust enum state machine is)

   function Run_Tasks_Rdv (Nconn, Rounds : Natural) return Totals;
   --  one Ada task per connection; the driver delivers every packet by rendezvous (entry call)

   function Run_Tasks_Local (Nconn, Rounds : Natural) return Totals;
   --  one Ada task per connection, each runs its own rounds with no synchronisation (task creation/scheduling cost only)
end Gw_Conns;
