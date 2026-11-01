# dbcraft

A Minecraft: Java Edition 26.3 server whose state and logic live in PostgreSQL: the world, players, inventories, settings and the protocol state machine are readable rows and
SQL functions; a small gateway moves bytes between sockets and the database once per tick.

* **How it fits together, what is verified against the real server, what is missing, and the measurements:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* The modules: [docs/NET.md](docs/NET.md) (connections, login, configuration), [docs/WORLD.md](docs/WORLD.md) (chunks, blocks), [docs/GAME.md](docs/GAME.md) (players, chat, commands, tick)
* The gateway as database code: [docs/SQL-GATEWAY.md](docs/SQL-GATEWAY.md); the language and database evaluations behind the design: `docs/*-EVALUATION.md`, [docs/DATABASE-COMPARISON.md](docs/DATABASE-COMPARISON.md)
* Run the tests: `tests/sql/run.sh` (SQL suite), `tests/e2e/run_all.sh` ([end-to-end against recordings of the real server](tests/e2e/README.md))

Reference data (block states, packet ids, registries) is Mojang's generated data: it is read from your own data-generator output and a capture of a vanilla server at load time and is never
committed to this repository.
