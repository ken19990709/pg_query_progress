/*-------------------------------------------------------------------------
 *
 * pgqp_compat.h
 *		Version compatibility layer for pg_query_progress.
 *
 * All lexical differences between the supported PostgreSQL majors live in
 * this file.  The .c sources compile unchanged on every major; the only
 * in-body version guard is the one around the worker-side index scan
 * instrumentation pairing (see PGQP_HAVE_INDEX_INSTR below).  Keeping the
 * sources identical across the release branches of this project is what
 * makes cross-branch backports conflict-free.
 *
 * Verified against PostgreSQL 20devel, 18, 17, 16 and 15.
 *
 * Copyright (c) 2026, The pg_query_progress Authors
 *
 * This software is licensed under the PostgreSQL License in the file
 * LICENSE at the top of this source tree.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGQP_COMPAT_H
#define PGQP_COMPAT_H

#include "postgres.h"

#include "executor/instrument.h"

/*
 * --------------------------------------------------------------------
 * Instrumentation type family
 * --------------------------------------------------------------------
 *
 * PostgreSQL 20 moved per-node instrumentation to NodeInstrumentation
 * (with the shared-fields Instrumentation as its first member) and
 * InstrAllocNode(); PostgreSQL 18 and earlier have the single
 * Instrumentation type and InstrAlloc().  The fields this extension
 * touches (running, tuplecount, ntuples, need_timer, need_bufusage,
 * need_walusage) exist with identical names and semantics in both
 * families.
 *
 * PGQP_ALLOC_NODE_INSTR injects a rows-counting instrument into a
 * PlanState: on 20 it allocates a NodeInstrumentation, on 18- an
 * Instrumentation array of one element.  Both assign directly to
 * ps->instrument, whose type matches the respective family.
 *
 * PGQP_BASE_INSTR yields the Instrumentation * carrying the option
 * flags of an injected instrument (on 20 a pointer to the embedded
 * first member, on 18- the instrument pointer itself).
 */
#if PG_VERSION_NUM >= 200000
typedef NodeInstrumentation PgQpNodeInstr;
#define PGQP_ALLOC_NODE_INSTR(ps) \
	InstrAllocNode(INSTRUMENT_ROWS, (ps)->async_capable)
#define PGQP_BASE_INSTR(ps)		(&(ps)->instrument->instr)
#else
typedef Instrumentation PgQpNodeInstr;
#define PGQP_ALLOC_NODE_INSTR(ps) \
	InstrAlloc(1, INSTRUMENT_ROWS, (ps)->async_capable)
#define PGQP_BASE_INSTR(ps)		((ps)->instrument)
#endif

/*
 * --------------------------------------------------------------------
 * Process identity
 * --------------------------------------------------------------------
 *
 * PostgreSQL 17 introduced procnumber.h (MyProcNumber,
 * ParallelLeaderProcNumber, INVALID_PROC_NUMBER == -1).  On 16/15 the
 * equivalents are MyProc->pgprocno and, for a parallel worker, the
 * lock-group leader's pgprocno: a worker joins its leader's lock group
 * in ParallelWorkerMain (BecomeLockGroupMember) and never leaves it
 * until exit, so the pointer is stable for the worker's whole life.
 * Non-members (plain sessions, non-parallel bgworkers) yield -1, the
 * same value INVALID_PROC_NUMBER carries on 17+.
 */
#if PG_VERSION_NUM >= 170000
#include "storage/procnumber.h"
#define PGQP_MY_PROCNO()		(MyProcNumber)
#define PGQP_LEADER_PROCNO()	(ParallelLeaderProcNumber)
#else
#include "storage/proc.h"
#define PGQP_MY_PROCNO() \
	(MyProc != NULL ? MyProc->pgprocno : -1)
#define PGQP_LEADER_PROCNO() \
	(MyProc != NULL && MyProc->lockGroupLeader != NULL ? \
	 MyProc->lockGroupLeader->pgprocno : -1)
#endif

/*
 * --------------------------------------------------------------------
 * LWLock tranche registration
 * --------------------------------------------------------------------
 *
 * PostgreSQL 20 renamed the API: LWLockNewTrancheId(name) registers the
 * name at allocation time; 18 and earlier return a bare id that the
 * caller must name via LWLockRegisterTranche().
 */
#if PG_VERSION_NUM >= 200000
#define PGQP_NEW_TRANCHE(name)	LWLockNewTrancheId(name)
#else
static inline int
pgqp_compat_new_tranche(const char *name)
{
	int			tranche_id = LWLockNewTrancheId();

	LWLockRegisterTranche(tranche_id, name);
	return tranche_id;
}
#define PGQP_NEW_TRANCHE(name)	pgqp_compat_new_tranche(name)
#endif

/*
 * --------------------------------------------------------------------
 * Parallel leader participation
 * --------------------------------------------------------------------
 *
 * On PostgreSQL 18 and earlier, parallel_leader_participation is a
 * PGC_USERSET GUC that decides (per query) whether the leader process
 * also runs the parallel plan locally; the executor reads it at Gather
 * and Gather Merge initialization.  It was removed upstream after 18;
 * from 19 on the planner and executor behave as if it were always on.
 * Reading it through this macro keeps one call site correct on every
 * major: callers snapshot it once per query (ExecutorStart), never
 * mid-query.
 */
#if PG_VERSION_NUM >= 200000
#define PGQP_LEADER_PARTICIPATION()	((bool) true)
#else
#include "optimizer/optimizer.h"
#define PGQP_LEADER_PARTICIPATION()	(parallel_leader_participation)
#endif

/*
 * --------------------------------------------------------------------
 * Worker-side index scan instrumentation
 * --------------------------------------------------------------------
 *
 * Only PostgreSQL 20 has pointer-shaped per-node index scan
 * instrumentation (iss_/ioss_/biss_Instrument) that a third party must
 * pair up manually when it injects ps->instrument on workers;
 * PostgreSQL 18 embeds the structure (never NULL, nothing to allocate),
 * and 17 and earlier have no index scan instrumentation at all.  The
 * .c file guards the one compensating code block with this macro.
 */
#if PG_VERSION_NUM >= 200000
#define PGQP_HAVE_INDEX_INSTR	1
#endif

#endif							/* PGQP_COMPAT_H */
