# pg_stats_backport
#
# On PostgreSQL 18 only the planner hook is built: the restore functions are
# part of core. On 13 to 17 the PostgreSQL 18 restore functions in vendor/ are
# compiled in as well.

EXTENSION  = pg_stats_backport
MODULE_big = pg_stats_backport
DATA       = pg_stats_backport--1.0.sql
PGFILEDESC = "pg_stats_backport - PostgreSQL 18 statistics restore for older versions"

OBJS = pg_stats_backport.o

REGRESS      = restore privileges planner_hook
REGRESS_OPTS = --inputdir=test

PG_CONFIG ?= pg_config
PG_MAJOR  := $(shell $(PG_CONFIG) --version | sed -E 's/^PostgreSQL[[:space:]]+([0-9]+).*/\1/')

ifeq ($(shell test "$(PG_MAJOR)" -lt 18 && echo yes),yes)
OBJS        += vendor/attribute_stats.o vendor/relation_stats.o vendor/stat_utils.o
PG_CPPFLAGS += -I$(srcdir)/vendor
endif

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
