/*-------------------------------------------------------------------------
 * pg_stats_backport.c
 *
 *	  Optional planner hook: plan with the stored relation size.
 *
 * The planner normally ignores pg_class.relpages and reltuples as absolute
 * values. estimate_rel_size() reads the real number of pages on disk and
 * scales the stored tuple density to it. On a table whose statistics were
 * restored but whose data was not, that makes every table look empty.
 *
 * When pg_stats_backport.use_stored_size is on, this hook runs after
 * estimate_rel_size() and puts the stored pages, tuples and all-visible
 * fraction back, for the table and each of its indexes. It is off by
 * default: on a database with real data it would make the planner trust
 * possibly stale statistics over the real table size.
 *
 * The hook is installed when the library is loaded, which needs one of
 * LOAD, session_preload_libraries or shared_preload_libraries.
 *
 * Copyright (c) 2026, DBGorilla
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/pg_class.h"
#include "fmgr.h"
#include "nodes/pathnodes.h"
#include "optimizer/plancat.h"
#include "utils/guc.h"
#include "utils/syscache.h"

PG_MODULE_MAGIC;

void		_PG_init(void);

static bool use_stored_size = false;
static get_relation_info_hook_type prev_get_relation_info_hook = NULL;

/*
 * A relation that was never analyzed keeps the planner's own estimate. From
 * PG14 that is reltuples = -1. PG13 uses relpages = 0 and reltuples = 0.
 */
static bool
stored_size_known(Form_pg_class form)
{
#if PG_VERSION_NUM >= 140000
	return form->reltuples >= 0;
#else
	return !(form->relpages == 0 && form->reltuples == 0);
#endif
}

static void
stats_backport_get_relation_info(PlannerInfo *root, Oid relationObjectId,
								 bool inhparent, RelOptInfo *rel)
{
	HeapTuple	tp;
	ListCell   *lc;

	if (prev_get_relation_info_hook)
		prev_get_relation_info_hook(root, relationObjectId, inhparent, rel);

	if (!use_stored_size || rel->rtekind != RTE_RELATION)
		return;

	tp = SearchSysCache1(RELOID, ObjectIdGetDatum(relationObjectId));
	if (HeapTupleIsValid(tp))
	{
		Form_pg_class classForm = (Form_pg_class) GETSTRUCT(tp);

		if (stored_size_known(classForm))
		{
			rel->pages = (BlockNumber) classForm->relpages;
			rel->tuples = (double) classForm->reltuples;
			if (classForm->relpages > 0)
				rel->allvisfrac =
					(double) classForm->relallvisible / (double) classForm->relpages;
			else
				rel->allvisfrac = 0.0;
		}
		ReleaseSysCache(tp);
	}

	foreach(lc, rel->indexlist)
	{
		IndexOptInfo *index = (IndexOptInfo *) lfirst(lc);
		HeapTuple	itp = SearchSysCache1(RELOID, ObjectIdGetDatum(index->indexoid));

		if (HeapTupleIsValid(itp))
		{
			Form_pg_class iForm = (Form_pg_class) GETSTRUCT(itp);

			if (stored_size_known(iForm))
			{
				index->pages = (BlockNumber) iForm->relpages;
				index->tuples = (double) iForm->reltuples;
			}
			ReleaseSysCache(itp);
		}
	}
}

void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_stats_backport.use_stored_size",
							 "Plan with the relation size stored in pg_class instead of the size on disk.",
							 "Use on a database whose statistics were restored without its data.",
							 &use_stored_size,
							 false,
							 PGC_USERSET,
							 0,
							 NULL, NULL, NULL);

#if PG_VERSION_NUM >= 150000
	MarkGUCPrefixReserved("pg_stats_backport");
#else
	EmitWarningsOnPlaceholders("pg_stats_backport");
#endif

	prev_get_relation_info_hook = get_relation_info_hook;
	get_relation_info_hook = stats_backport_get_relation_info;
}
