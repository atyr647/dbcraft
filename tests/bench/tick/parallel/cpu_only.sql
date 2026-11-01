select count(*) from generate_series(1, 200000) g where (g * 7) % 13 = 3;
