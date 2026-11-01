-- each client updates all 500 rows of its OWN table (client id = :client_id, tables 0..7); the table kind is chosen by -D kind=pw or pu
\set t :client_id
select set_config('par.t', :t::text, false) \gset
update par.:kind_sep_:t set a = a + 1, b = b + 1, c = c + 1, d = d + 1;
