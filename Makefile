# dbcraft: the common tasks.  `make help` lists them.   Everything Mojang-owned is derived on your machine under $(DBCRAFT_HOME) (default ~/.cache/dbcraft).
.PHONY: help setup check up down status test test-seq gateway gateway-test fresh-db clean-cache

help:
	@echo "make setup         one-command setup: packages, vanilla jar, generator reports, captures, database, Rust gateway (tools/bootstrap.sh)"
	@echo "make check         report what is missing, change nothing"
	@echo "make up            start PostgreSQL and the gateway, print the address to connect to"
	@echo "make down          stop them"
	@echo "make status        what is running"
	@echo "make test          the SQL test suite in parallel, each file in its own database clone (tests/sql/prun.sh)"
	@echo "make gateway       build the Rust gateway (gateway/build.sh)"
	@echo "make gateway-test  the gateway's unit tests"
	@echo "make fresh-db      rebuild the database from scratch"
	@echo "make clean-cache   delete the downloaded and derived Mojang data (jar, reports, captures)"

setup:
	tools/bootstrap.sh

check:
	tools/bootstrap.sh --check

up:
	tools/dev-up.sh

down:
	tools/dev-down.sh

status:
	tools/dev-status.sh

test:
	tests/sql/prun.sh

test-seq:
	tests/sql/run.sh

gateway:
	gateway/build.sh

gateway-test:
	gateway/build.sh test

fresh-db:
	tools/setup-db.sh --fresh

clean-cache:
	@. tools/env.sh && echo "removing $$DBCRAFT_HOME (the database cluster in $$DBCRAFT_PGDATA is not touched)" && rm -rf "$$DBCRAFT_HOME"
