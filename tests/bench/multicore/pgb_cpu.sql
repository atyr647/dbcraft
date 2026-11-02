select sum(sqrt(g::float8)) from generate_series(1, 300000) g;
