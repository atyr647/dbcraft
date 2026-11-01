# Build: make && sudo make install        (needs postgresql-server-dev-NN and zlib1g-dev; libdeflate-dev is optional)
#   make WITH_LIBDEFLATE=no               force zlib only
#   make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config
EXTENSION    = dbcraft_zlib
DATA         = dbcraft_zlib--1.0.sql
MODULE_big   = dbcraft_zlib
OBJS         = dbcraft_zlib.o
PG_CPPFLAGS  = -Wall -Wextra -Wno-unused-parameter
SHLIB_LINK   = -lz

WITH_LIBDEFLATE ?= auto
ifneq ($(WITH_LIBDEFLATE),no)
  HAVE_LD := $(shell pkg-config --exists libdeflate 2>/dev/null && echo yes)
  ifeq ($(HAVE_LD),yes)
    PG_CPPFLAGS += -DDBZ_HAVE_LIBDEFLATE $(shell pkg-config --cflags libdeflate)
    SHLIB_LINK  += $(shell pkg-config --libs libdeflate)
  else ifeq ($(WITH_LIBDEFLATE),yes)
    $(error libdeflate requested but pkg-config cannot find it)
  endif
endif

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
