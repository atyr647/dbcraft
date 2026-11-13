# Build: make && sudo make install        (needs postgresql-server-dev-NN)
#   make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
EXTENSION    = dbcraft_set
DATA         = dbcraft_set--1.0.sql
MODULE_big   = dbcraft_set
OBJS         = dbcraft_set.o
PG_CPPFLAGS  = -Wall -Wextra -Wno-unused-parameter

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
