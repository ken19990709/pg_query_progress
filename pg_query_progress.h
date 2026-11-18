/*-------------------------------------------------------------------------
 *
 * pg_query_progress.h
 *		Shared memory layout and constants for per-query progress tracking.
 *
 * The slot layout is frozen: sizeof(PgQPSlot) == 1144 and the worker
 * table block size are pinned by static assertions, and external tests
 * assert the shared-memory byte counts against these constants.
 *
 * Copyright (c) 2026, The pg_query_progress Authors
 *
 * This software is licensed under the PostgreSQL License in the file
 * LICENSE at the top of this source tree.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PG_QUERY_PROGRESS_H
#define PG_QUERY_PROGRESS_H

#include "postgres.h"

#include "datatype/timestamp.h"
#include "port/atomics.h"
#include "storage/lwlock.h"
#include "storage/spin.h"

/*
 * Upper bound of the query text stored in a slot.  The actual stored length
 * is bounded at runtime by the pg_query_progress.max_query_len GUC
 * (128..PGQP_TRUNAME).
 */
#define PGQP_TRUNAME			1024

/* Shmem layout version; bump when PgQPSlot/PgQPSharedState change shape. */
#define PGQP_MAGIC				0x50475032	/* 'PGP2' */

/*
 * Per-tuple tick pacing:
 * check the clock every 16 node calls; publish when >= 250ms elapsed or
 * >= 65536 node calls since the previous publish.
 */
#define PGQP_TICKS_PER_CHECK	16
#define PGQP_PUBLISH_MS			250
#define PGQP_TICKS_PER_PUBLISH	65536

/*
 * v2: in-session progress-bar frame, cell count.
 * Deliberately 24 cells -- a fixed, narrower frame than the 30-cell
 * scripts/pgqp_monitor.sh bar (which keeps its own width); the two
 * renderers are independent deliverables (MINOR-5).
 */
#define PGQP_BAR_CELLS			24

/*
 * v3: default frame gate.  bar_min_query_ms == 0 is
 * the sentinel "mirror bar_interval_ms", so the gate follows the interval
 * knob without a second setting.
 */
#define PGQP_BAR_GATE_DEFAULT	0

/* Slot lifecycle. */
typedef enum PgQPSlotState
{
	PGQP_IDLE = 0,				/* free: procnumber == -1 */
	PGQP_RUNNING,				/* query in flight */
	PGQP_COMPLETED,				/* drained normally; progress == 1.0 */
	PGQP_FAILED,				/* aborted: error, cancel, or End w/o Finish */
	PGQP_TERMINATED			/* cursor closed before EOF; progress < 1.0 */
} PgQPSlotState;

/*
 * One slot per backend, indexed by ProcNumber.
 * Writers: owning backend only, under mutex; readers: SRF snapshot copies.
 */
typedef struct PgQPSlot
{
	int			procnumber;		/* owner ProcNumber; -1 = free */
	pid_t		pid;
	Oid			dbid;
	int			state;			/* PgQPSlotState */
	bool		parallel;		/* plannedstmt->parallelModeNeeded */
	char		query[PGQP_TRUNAME + 1];
	double		progress;		/* [0,1], monotonic */
	double		total_cost;		/* sum of self costs at last publish */
	double		completed_cost;
	double		plan_rows;		/* root node row estimate */
	double		rows_returned;	/* root node rows emitted so far */
	int64		tuples_processed;	/* sum over all nodes of rows emitted */
	int64		query_id;		/* plannedstmt->queryId (may be 0) */
	int			nodes_total;
	int			nodes_done;
	int64		seq;			/* per-slot query serial, disambiguates reuse */
	TimestampTz query_start;
	TimestampTz last_update;
	slock_t		mutex;			/* per-slot spinlock */
} PgQPSlot;

typedef struct PgQPSharedState
{
	LWLock		lock;			/* protects nslots/magic (init time) */
	int			nslots;			/* == MaxBackends */
	uint32		magic;			/* PGQP_MAGIC */
} PgQPSharedState;

/* Layout: one block = [PgQPSharedState][PgQPSlot x nslots], MAXALIGNed. */
#define PGQP_SLOTS(base) \
	((PgQPSlot *) (((char *) (base)) + MAXALIGN(sizeof(PgQPSharedState))))

/*
 * v3: second shared-memory block -- the worker
 * counter table.  One strip per leader ProcNumber (hash by %), one entry
 * per parallel worker, one cumulative row counter per plan_node_id.
 * Single-writer (the owning worker) / multi-reader (leaders merging), a
 * seqlock per entry -- no spinlock, so a worker dying inside its write
 * critical section leaves an odd version and readers simply skip the
 * entry instead of hanging.
 */
#define PGQP_WSTRIPS			128 /* leader strips (compile-time constant,
									 * independent of MaxBackends) */
#define PGQP_WWORKERS			16	/* worker slots per strip */
#define PGQP_WNODES				192 /* plan_node_id upper bound (1..192) */

typedef struct PgQPWorkerEntry
{
	pg_atomic_uint64 ver;		/* seqlock version: even = stable, odd = in
								 * write */
	int			leader_proc;	/* leader ProcNumber claimed under */
	/*
	 * v3.1: parallel-context key, packed as
	 * (worker-tree-root plan_node_id << 4) | ParallelWorkerNumber.
	 * ParallelWorkerNumber counts from 0 within EACH parallel context, so
	 * two Gathers of one query would otherwise fight over the same entry;
	 * the root plan_node_id (each Gather's outer subtree root) is unique
	 * per context and disambiguates both the entry address (strip offset)
	 * and the merge filter.  Packed into the old worker_id slot to keep the
	 * frozen 1568B layout / 3,211,280B block.
	 */
	int			ctx_key;
	int64		seq;			/* leader slot seq at claim time (query
								 * generation) */
	TimestampTz last_update;	/* writer's last publish time (diagnostics) */
	double		rows[PGQP_WNODES];	/* cumulative output rows, indexed by
									 * plan_node_id - 1 */
} PgQPWorkerEntry;				/* 8+4+4+8+8+1536 = 1568B */

/* ctx_key packing helpers (F1): root id in the high bits, worker number in
 * the low 4 (PGQP_WWORKERS == 16).  Root ids beyond 2^27 degrade the worker
 * to non-reporting (unreachable: that would be a 134M-node plan). */
#define PGQP_CTX_ROOT_MAX		((INT_MAX >> 4))
#define PGQP_CTX_KEY(root, worker)	(((root) << 4) | ((worker) & 0xF))
#define PGQP_CTX_KEY_ROOT(key)	((key) >> 4)

typedef struct PgQPWHeader
{
	uint32		magic;			/* PGQP_MAGIC (same value as the main block) */
	int			nstrip;			/* == PGQP_WSTRIPS */
	char		pad[8];			/* keeps the header 16B under MAXALIGN so the
								 * block size matches the 12.4 budget table
								 * (3,211,280B) */
} PgQPWHeader;

/* Layout: [PgQPWHeader][PgQPWorkerEntry x (WSTRIPS * WWORKERS)], MAXALIGNed.
 * Typed as pointer-to-strip so entries can be addressed [strip][worker]. */
#define PGQP_WENTRIES(base) \
	((PgQPWorkerEntry (*) [PGQP_WWORKERS]) \
	 (((char *) (base)) + MAXALIGN(sizeof(PgQPWHeader))))

#define PGQP_WTAB_SIZE \
	(MAXALIGN(sizeof(PgQPWHeader)) + \
	 ((Size) PGQP_WSTRIPS) * PGQP_WWORKERS * sizeof(PgQPWorkerEntry))

/* State names as shown in the view, indexed by PgQPSlotState. */
extern const char *const pgqp_state_names[];

#endif							/* PG_QUERY_PROGRESS_H */
