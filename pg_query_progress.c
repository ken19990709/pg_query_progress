/*-------------------------------------------------------------------------
 *
 * pg_query_progress.c
 *		Live, per-query progress tracking for SELECT statements.
 *
 * Mechanism: wrap every PlanState's ExecProcNode with a
 * cheap tick function that keeps core-equivalent row instrumentation
 * (InstrStartNode/InstrStopNode around ExecProcNodeReal) and, at a paced
 * interval (>= 250ms or every 65536 node calls), walks the planstate tree
 * to compute a cost-weighted progress fraction (Luo et al. style):
 *
 *	self_cost(node) = total_cost(node) - sum(total_cost(children))
 *	node progress  = min(1, rows emitted / max(plan_rows, 1))
 *	global progress= sum(self_cost * node progress) / sum(self_cost)
 *
 * Snapshots are published to a per-backend slot in shared memory (indexed
 * by ProcNumber) and read by the pg_query_progress() SRF from any session.
 *
 * Must be loaded via shared_preload_libraries (absolute path works).
 *
 * One source tree builds against every supported PostgreSQL major; all
 * version differences are confined to pgqp_compat.h (plus the single
 * version guard around the worker-side index instrumentation pairing).
 *
 * Copyright (c) 2026, The pg_query_progress Authors
 *
 * This software is licensed under the PostgreSQL License in the file
 * LICENSE at the top of this source tree.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/parallel.h"
#include "access/xact.h"
#include "executor/execdesc.h"
#include "executor/executor.h"
#include "executor/instrument.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "nodes/plannodes.h"
#include "pg_query_progress.h"
#include "pgqp_compat.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

/*
 * --------------------------------------------------------------------
 * Globals
 * --------------------------------------------------------------------
 */

/* Shared memory: set by the shmem request/init machinery (postmaster). */
static PgQPSharedState *pgqp = NULL;

/*
 * v3: second shared-memory block, the worker
 * counter table.  The main block above is byte-identical to v1 (s18).
 */
static PgQPWHeader *pgqp_wtab = NULL;

/*
 * Postmaster-initialized and inherited via fork; recomputed in init_fn.
 * Declared non-static only for the shmem request macro (needs &var).
 */
static PgQPSlot *pgqp_slots = NULL;

/* Saved hook values for chaining (set in _PG_init). */
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;

/* GUC-backed variables. */
static bool pgqp_track = true;
static int	pgqp_max_query_len = PGQP_TRUNAME;
/* v2 in-session bar, all PGC_USERSET */
static bool pgqp_bar = false;
static bool pgqp_bar_ansi = false;
static int	pgqp_bar_interval_ms = 500;
/* v3 frame gate: 0 = mirror bar_interval_ms */
static int	pgqp_bar_min_query_ms = PGQP_BAR_GATE_DEFAULT;

/* Backend-private tracking state. */
static int	nesting_level = 0;	/* executor nesting depth (pgss pattern) */
static MemoryContext pgqp_ctx = NULL;	/* entry allocator under TopMemoryContext */

/*
 * The entry for the query currently tracked by this backend, or NULL.
 * Touched by the tick wrapper (hot path): read into a local pointer.
 */
typedef struct PgQPEntry
{
	QueryDesc  *queryDesc;		/* identity guard for Finish/End hooks */
	PlanState  *root_state;		/* queryDesc->planstate at start */
	PgQPSlot  *slot;			/* &pgqp_slots[my proc number] */
	int64		slot_seq;		/* slot seq of this query (v3 merge key) */
	double		last_progress;	/* monotonic clamp, backend-side */
	bool		drained;		/* root returned EOF slot */
	/* hot-path pacing */
	int			tick_countdown;
	int64		ticks_since_publish;
	TimestampTz last_publish_time;
	/* v2 bar state, ~16B */
	TimestampTz bar_last_emit;
	bool		bar_last_emit_valid;
	bool		bar_ansi_started;	/* an ANSI frame was already emitted */
	/*
	 * parallel_leader_participation snapshot taken once at ExecutorStart
	 * (on majors where it is a user-settable GUC; always true where the
	 * upstream removed it).  The walk reads only this copy: reading the
	 * GUC mid-walk could disagree with the executor's own decision points
	 * (Gather/GatherMerge init and worker-restart rescan) within one
	 * query.  See the D-hat computation in pgqp_walk_node.
	 */
	bool		leader_participation;
} PgQPEntry;

static PgQPEntry *pgqp_entry = NULL;

/*
 * v3: backend-private state for the query tracked
 * by a PARALLEL WORKER.  Deliberately parallel to PgQPEntry (never
 * merged): workers create no slot row, render no bar frame, and publish
 * only into their own wtab entry.  The publish-side stack buffer
 * (double[PGQP_WNODES], 1.5KB) keeps the whole worker-side footprint
 * under the ~2KB budget.
 */
typedef struct PgQPWorker
{
	QueryDesc  *queryDesc;		/* identity guard for Finish/End hooks */
	PlanState  *root_state;		/* worker planstate = Gather outer subtree */
	PgQPWorkerEntry *wentry;	/* claimed wtab entry; NULL never happens
								 * here (degraded workers stay unattached) */
	int			leader_proc;	/* L: leader ProcNumber claimed under */
	int64		leader_seq;		/* S: leader slot seq at claim time */
	/*
	 * v3.1: the parallel-context key.  ParallelWorkerNumber
	 * counts from 0 within EACH Gather's parallel context, so the entry
	 * address and the merge filter must additionally be keyed by the
	 * worker-tree-root plan_node_id (unique per Gather within a query).
	 */
	int			ctx_root;		/* worker-tree-root plan_node_id */
	int			ctx_key;		/* PGQP_CTX_KEY(ctx_root, worker number) */
	/* hot-path pacing: same cadence as the leader */
	int			tick_countdown;
	int64		ticks_since_publish;
	TimestampTz last_publish_time;
} PgQPWorker;

static PgQPWorker *pgqp_worker = NULL;

/*
 * v2 memory budget evidence (see tests/scenarios/s18): the bar adds
 * ~16B of entry state on top of v1's entry; the backend-private entry
 * must stay far below the per-session memory budget, and the shmem slot
 * layout is frozen (sizeof must stay byte-identical to v1;
 * 1144 = MAXALIGN'ed v1 layout, verified by standalone probe).
 *
 * v3 additions: entry->slot_seq (8B, still <= 128B budget) and the worker
 * table layout assertions (1568B per entry,
 * 3,211,280B for the whole second block).
 */
static_assert(sizeof(PgQPEntry) <= 128,
			  "pg_query_progress entry exceeds its size budget");
static_assert(sizeof(PgQPSlot) == 1144,
			  "pg_query_progress slot layout drifted from v1");
static_assert(sizeof(PgQPWorkerEntry) == 1568,
			  "pg_query_progress worker entry layout drifted");
static_assert(PGQP_WTAB_SIZE == 3211280,
			  "pg_query_progress worker table block size drifted");

/* one-time flags */
static bool pgqp_exit_registered = false;
static bool pgqp_srf_warned = false;

const char *const pgqp_state_names[] =
{
	[PGQP_IDLE] = "idle",
	[PGQP_RUNNING] = "running",
	[PGQP_COMPLETED] = "completed",
	[PGQP_FAILED] = "failed",
	[PGQP_TERMINATED] = "terminated"
};

/*
 * --------------------------------------------------------------------
 * Forward declarations
 * --------------------------------------------------------------------
 */
void		_PG_init(void);
void		_PG_fini(void);

PG_FUNCTION_INFO_V1(pg_query_progress_srf);

static void pgqp_shmem_request(void);
static void pgqp_shmem_startup(void);
static Size pgqp_memsize(void);

static void pgqp_ExecutorStart(QueryDesc *queryDesc, int eflags);
static void pgqp_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction,
							 uint64 count);
static void pgqp_ExecutorFinish(QueryDesc *queryDesc);
static void pgqp_ExecutorEnd(QueryDesc *queryDesc);

static TupleTableSlot *pgqp_tick(PlanState *node);
static void pgqp_maybe_publish(PgQPEntry *entry);
static void pgqp_publish(PgQPEntry *entry, bool force_done);
static void pgqp_set_slot_state(PgQPEntry *entry, PgQPSlotState state);

static bool pgqp_should_track(QueryDesc *queryDesc, int eflags);
static void pgqp_begin_track(QueryDesc *queryDesc);
static void pgqp_detach_entry(PgQPEntry *entry);
static void pgqp_abort_cleanup(void);
static void pgqp_xact_callback(XactEvent event, void *arg);
static void pgqp_subxact_callback(SubXactEvent event,
								  SubTransactionId mySubid,
								  SubTransactionId parentSubid, void *arg);
static void pgqp_backend_cleanup(int code, Datum arg);

/* v3 worker-side tracking */
static void pgqp_worker_register(QueryDesc *queryDesc, int eflags);
static void pgqp_worker_maybe_publish(PgQPWorker *worker);
static void pgqp_worker_publish(PgQPWorker *worker);
static void pgqp_worker_collect(PlanState *ps, double *buf);
static void pgqp_worker_detach(PgQPWorker *worker);
static void pgqp_worker_exit(int code, Datum arg);
#ifdef PGQP_HAVE_INDEX_INSTR
static void pgqp_worker_alloc_index_instruments(PlanState *ps);
#endif

/* progress tree walk */
typedef struct PgQPAccum
{
	double		completed;		/* sum(self * frac) */
	double		total_self;		/* sum(self) */
	int64		tuples;			/* sum over nodes of rows emitted */
	int			nodes_total;
	int			nodes_done;
} PgQPAccum;

/*
 * v3 walk context: carries the merge identity for
 * worker counts and the stacked parallel divisor D-hat.  depth == 0 means
 * the serial region; entering a Gather subtree pushes D-hat computed from
 * that Gather's num_workers plus the subtree-root plan_node_id (v3.1
 * The parallel-context key that disambiguates the
 * worker-table entries of multiple Gathers within one query).  Gather
 * cannot nest inside a parallel region, so the stack depth stays <= 1 in
 * practice; it is written as a stack for future shapes.
 */
#define PGQP_MAX_GATHER_DEPTH 8

typedef struct PgQPWalk
{
	int			leader_proc;	/* merging leader's ProcNumber */
	int64		leader_seq;		/* leader slot seq (query generation) */
	bool		leader_participation;	/* entry snapshot, read-only here */
	double		divisor[PGQP_MAX_GATHER_DEPTH];
	int			gather_root[PGQP_MAX_GATHER_DEPTH];	/* outer subtree root
													 * plan_node_id */
	int			depth;
} PgQPWalk;

static double pgqp_walk_node(PlanState *ps, PgQPAccum *acc, PgQPWalk *ctx);
static double pgqp_walk_children(PlanState *ps, PgQPAccum *acc,
								 PgQPAccum *leftacc, PgQPWalk *ctx);
static double pgqp_wtab_node_rows(PgQPWalk *ctx, int node_id);
static double pgqp_node_rows(PlanState *ps);
static void pgqp_wrap_planstate(PlanState *ps, bool is_root);
static void pgqp_store_query_text(PgQPSlot *slot, const char *qtext);

/* v2 bar */
static void pgqp_bar_frame(PgQPEntry *entry, TimestampTz now);
static void pgqp_bar_terminal(PgQPEntry *entry, const char *tag);

/*
 * --------------------------------------------------------------------
 * Module load / unload
 * --------------------------------------------------------------------
 */

/* Saved legacy shmem hooks for chaining (set in _PG_init). */
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

/*
 * Module load callback.  Mirrors pg_stat_statements: only take over the
 * system when loaded via shared_preload_libraries (pg_stat_statements.c:400).
 * When loaded on demand (LOAD), no hooks are installed and the SRF reports
 * empty with a one-time WARNING.
 */
void
_PG_init(void)
{
	if (!process_shared_preload_libraries_in_progress)
		return;

	DefineCustomBoolVariable("pg_query_progress.track",
							 "Enable per-query progress tracking.",
							 NULL,
							 &pgqp_track,
							 true,
							 PGC_SUSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	DefineCustomIntVariable("pg_query_progress.max_query_len",
							"Maximum query text length stored per slot.",
							NULL,
							&pgqp_max_query_len,
							PGQP_TRUNAME,
							128,
							PGQP_TRUNAME,
							PGC_USERSET,
							0,
							NULL,
							NULL,
							NULL);

	/* v2 in-session bar: presentation-only knobs,
	 * analogous to client_min_messages -> PGC_USERSET; the tracking data
	 * plane keeps v1's pg_query_progress.track (PGC_SUSET). */
	DefineCustomBoolVariable("pg_query_progress.bar",
							 "Render an in-session progress bar for tracked SELECTs via NOTICE frames.",
							 "Off by default; frames go to the client's NOTICE stream (psql: stderr).",
							 &pgqp_bar,
							 false,
							 PGC_USERSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	DefineCustomBoolVariable("pg_query_progress.bar_ansi",
							 "Use ANSI single-line redraw escape codes in bar frames.",
							 "Only for real terminals; pipes/redirects will retain raw escape bytes.",
							 &pgqp_bar_ansi,
							 false,
							 PGC_USERSET,
							 0,
							 NULL,
							 NULL,
							 NULL);

	DefineCustomIntVariable("pg_query_progress.bar_interval_ms",
							"Minimum interval between bar frames in milliseconds.",
							"Effective frame spacing is max(this, the 16-tick clock cadence under slow tuple flow).",
							&pgqp_bar_interval_ms,
							500,
							100,
							5000,
							PGC_USERSET,
							0,
							NULL,
							NULL,
							NULL);

	/*
	 * v3: unified frame gate.  Queries younger
	 * than the gate emit zero frames (first, intermediate and terminal
	 * alike), so catalog quick-looks like \d stay silent.  The default 0 is
	 * the sentinel "mirror bar_interval_ms": one knob keeps working.
	 */
	DefineCustomIntVariable("pg_query_progress.bar_min_query_ms",
							"Minimum query age in milliseconds before any bar frame may be emitted.",
							"0 mirrors bar_interval_ms.  Queries shorter than the gate emit no frames at all.",
							&pgqp_bar_min_query_ms,
							PGQP_BAR_GATE_DEFAULT,
							0,
							60000,
							PGC_USERSET,
							0,
							NULL,
							NULL,
							NULL);

	MarkGUCPrefixReserved("pg_query_progress");

	/*
	 * Shared memory: register through the legacy shmem_request_hook /
	 * shmem_startup_hook chain.  This is the one API present in every
	 * supported major (20devel still carries it alongside the newer
	 * RegisterShmemCallbacks), so all release branches of this project
	 * share a single code path here.
	 */
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = pgqp_shmem_request;
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = pgqp_shmem_startup;

	/*
	 * Error-path coverage requires both callback kinds: XactEvent has no
	 * ABORT_SUB value, so errors inside a SAVEPOINT only fire the SubXact
	 * callbacks (xact.h:127-150).
	 */
	RegisterXactCallback(pgqp_xact_callback, NULL);
	RegisterSubXactCallback(pgqp_subxact_callback, NULL);

	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = pgqp_ExecutorStart;
	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = pgqp_ExecutorRun;
	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = pgqp_ExecutorFinish;
	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = pgqp_ExecutorEnd;
}

/*
 * Module unload callback: restore hook chain.  In practice the library is
 * never unloaded from a running server (and must not be, while queries are
 * being tracked); this exists for symmetry with other executor-hook
 * extensions.
 */
void
_PG_fini(void)
{
	shmem_request_hook = prev_shmem_request_hook;
	shmem_startup_hook = prev_shmem_startup_hook;
	ExecutorStart_hook = prev_ExecutorStart;
	ExecutorRun_hook = prev_ExecutorRun;
	ExecutorFinish_hook = prev_ExecutorFinish;
	ExecutorEnd_hook = prev_ExecutorEnd;
	UnregisterXactCallback(pgqp_xact_callback, NULL);
	UnregisterSubXactCallback(pgqp_subxact_callback, NULL);
}

/*
 * --------------------------------------------------------------------
 * Shared memory (legacy shmem_request_hook / shmem_startup_hook chain:
 * the common denominator of every supported PostgreSQL major)
 * --------------------------------------------------------------------
 */

static Size
pgqp_memsize(void)
{
	/*
	 * The shmem_request hooks run after InitializeMaxBackends in
	 * postmaster startup (every supported major), so MaxBackends is
	 * final here and the slot array covers every possible backend.
	 */
	return MAXALIGN(sizeof(PgQPSharedState)) +
		((Size) MaxBackends) * MAXALIGN(sizeof(PgQPSlot));
}

static void
pgqp_shmem_request(void)
{
	/*
	 * One combined add-in request: the per-backend slot array (sized by
	 * MaxBackends) plus the fixed-size worker counter table.  The legacy
	 * protocol has no named-request concept; the two blocks are carved
	 * out under their own names in the startup hook below, which is what
	 * makes them individually visible in pg_shmem_allocations.
	 */
	RequestAddinShmemSpace(MAXALIGN(pgqp_memsize()) + PGQP_WTAB_SIZE);
}

static void
pgqp_shmem_startup(void)
{
	bool	found_main;
	bool	found_wtab;
	int		i;

	Assert(!IsUnderPostmaster);

	/*
	 * Chain to the previous startup hook first: extensions earlier in
	 * shared_preload_libraries must find their shared memory ready.
	 */
	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	pgqp = (PgQPSharedState *)
		ShmemInitStruct("pg_query_progress", pgqp_memsize(), &found_main);
	pgqp_wtab = (PgQPWHeader *)
		ShmemInitStruct("pg_query_progress_workers", PGQP_WTAB_SIZE,
						&found_wtab);

	if (!found_main)
	{
		int			tranche_id;

		/*
		 * Initialize the shared-state LWLock even though all current
		 * writers rely solely on per-slot spinlocks: a shmem LWLock left
		 * on garbage would corrupt the lock manager as soon as anyone
		 * acquires it.
		 */
		tranche_id = PGQP_NEW_TRANCHE("pg_query_progress");
		LWLockInitialize(&pgqp->lock, tranche_id);

		pgqp->nslots = MaxBackends;
		pgqp->magic = PGQP_MAGIC;
	}
	pgqp_slots = PGQP_SLOTS(pgqp);

	/*
	 * Explicitly initialize every slot: do not rely on the zero-filled
	 * startup segment.
	 */
	if (!found_main)
	{
		for (i = 0; i < pgqp->nslots; i++)
		{
			PgQPSlot  *slot = &pgqp_slots[i];

			SpinLockInit(&slot->mutex);
			slot->procnumber = -1;
			slot->state = PGQP_IDLE;
		}
	}

	/*
	 * Explicitly initialize the whole worker table -- ver 0 (even =
	 * stable), owner -1, rows all zero.  Runs at postmaster start and
	 * again after a crash-restart (the signal-death path), which is what
	 * recovers entries of workers that died without cleanup.
	 */
	if (!found_wtab)
	{
		pgqp_wtab->magic = PGQP_MAGIC;
		pgqp_wtab->nstrip = PGQP_WSTRIPS;
		{
			PgQPWorkerEntry *wbase = &PGQP_WENTRIES(pgqp_wtab)[0][0];

			for (i = 0; i < PGQP_WSTRIPS * PGQP_WWORKERS; i++)
			{
				PgQPWorkerEntry *we = &wbase[i];

				MemSet(we, 0, sizeof(PgQPWorkerEntry));
				pg_atomic_init_u64(&we->ver, 0);
				we->leader_proc = -1;
				we->ctx_key = 0;
			}
		}
	}
}

/*
 * --------------------------------------------------------------------
 * Tracking filters
 * --------------------------------------------------------------------
 */

/*
 * Decide whether this ExecutorStart should be tracked.  Conditions per
 * Decide whether this ExecutorStart should be tracked: regular backend,
 * top-level (nesting_level == 0, the
 * Run-hook guard excludes SQL-function and PLpgSQL re-entries), CMD_SELECT
 * only, skip EXPLAIN (no ANALYZE) / GENERIC plan modes, skip auxiliary
 * processes whose ProcNumber may exceed nslots.
 *
 * v3: parallel workers are handled by the separate pgqp_worker_register
 * path before this function is reached (pgqp_ExecutorStart branches on
 * IsParallelWorker() first); the early-out below stays as defense in
 * depth.
 */
static bool
pgqp_should_track(QueryDesc *queryDesc, int eflags)
{
	if (!pgqp_track)
		return false;
	if (IsParallelWorker())
		return false;
	if (MyBackendType != B_BACKEND)
		return false;
	if (nesting_level != 0)
		return false;
	if (queryDesc->operation != CMD_SELECT)
		return false;
	if (eflags & (EXEC_FLAG_EXPLAIN_ONLY | EXEC_FLAG_EXPLAIN_GENERIC))
		return false;
	if (queryDesc->estate == NULL || queryDesc->planstate == NULL)
		return false;
	if (PGQP_MY_PROCNO() < 0 || PGQP_MY_PROCNO() >= pgqp->nslots)
		return false;
	return true;
}

/*
 * --------------------------------------------------------------------
 * Hot path: the tick wrappers
 * --------------------------------------------------------------------
 */

/*
 * Wrappers installed as node->ExecProcNode after standard_ExecutorStart.
 * There are two, selected once
 * per node at wrap time by the instrument's option flags (immutable after
 * allocation: need_* are only ever set at instrument initialization), so
 * the hot path needs no flag checks:
 *
 * - pgqp_tick_rows (counting-only instruments, i.e. the INSTRUMENT_ROWS
 *   ones this extension injects) is semantically equivalent to core's
 *   ExecProcNodeInstr (instrument.c:181-192) for the all-flags-off case:
 *   InstrStart is a no-op then (every effect in instrument.c:52-69 is
 *   gated on one of the flags), and InstrStopNode (instrument.c:138-170)
 *   reduces to "tuplecount += n" plus the running-flag transition -- the
 *   firsttuple/counter writes it performs are no-ops while the timer is
 *   off, because counter only advances inside InstrStopCommon's
 *   need_timer branch (instrument.c:81-90) and InstrEndLoop's starttime
 *   guard (instrument.c:210) can therefore never fire.  The rescan fold
 *   (ntuples += tuplecount, nloops++, running reset) happens in
 *   InstrEndLoop as before and is fully preserved.
 *
 * - pgqp_tick (timer/buffer/WAL-carrying instruments: EXPLAIN ANALYZE,
 *   auto_explain) runs the exact core sequence: InstrStartNode /
 *   ExecProcNodeReal / InstrStopNode, semantics untouched.
 *
 * Pacing: every call decrements tick_countdown; at
 * zero the clock is checked and ticks_since_publish is advanced by the
 * whole batch -- the counter still counts every tick exactly (value is a
 * multiple of PGQP_TICKS_PER_CHECK at every point where it is read), so
 * both publish gates (>= 250ms elapsed, >= 65536 ticks) decide exactly as
 * before; the batching only removes a per-call increment.
 *
 * Remaining per-call cost in the rows wrapper: one extra indirect call
 * (ExecProcNodeReal), two stores, one decrement-and-branch, and one
 * clock read per PGQP_TICKS_PER_CHECK calls.  No palloc, no locks except
 * inside publish (rare, >= 250ms apart).
 */
static TupleTableSlot *
pgqp_tick_rows(PlanState *node)
{
	TupleTableSlot *slot = node->ExecProcNodeReal(node);
	PgQpNodeInstr *instr = node->instrument;
	PgQPEntry  *entry = pgqp_entry;
	bool		isnull = TupIsNull(slot);

	if (!isnull)
		instr->tuplecount += 1.0;
	if (!instr->running)
		instr->running = true;

	if (entry != NULL)
	{
		/* Root EOF detection (ExecutePlan's own loop test, execMain.c:1795) */
		if (isnull && node == entry->root_state)
			entry->drained = true;

		if (--entry->tick_countdown <= 0)
		{
			entry->tick_countdown = PGQP_TICKS_PER_CHECK;
			entry->ticks_since_publish += PGQP_TICKS_PER_CHECK;
			pgqp_maybe_publish(entry);
		}
	}
	else
	{
		/*
		 * v3: parallel workers run the very same wrapper;
		 * the only addition on this path is the single worker-pointer
		 * check.  The pacing fields and the publish cadence are the
		 * leader's (>= 250ms or >= 65536 ticks).
		 */
		PgQPWorker *worker = pgqp_worker;

		if (worker != NULL && --worker->tick_countdown <= 0)
		{
			worker->tick_countdown = PGQP_TICKS_PER_CHECK;
			worker->ticks_since_publish += PGQP_TICKS_PER_CHECK;
			pgqp_worker_maybe_publish(worker);
		}
	}
	return slot;
}

static TupleTableSlot *
pgqp_tick(PlanState *node)
{
	TupleTableSlot *slot;
	PgQpNodeInstr *instr = node->instrument;
	PgQPEntry  *entry = pgqp_entry;
	bool		isnull;

	InstrStartNode(instr);
	slot = node->ExecProcNodeReal(node);
	isnull = TupIsNull(slot);
	InstrStopNode(instr, isnull ? 0.0 : 1.0);

	if (entry != NULL)
	{
		/* Root EOF detection (ExecutePlan's own loop test, execMain.c:1795) */
		if (isnull && node == entry->root_state)
			entry->drained = true;

		if (--entry->tick_countdown <= 0)
		{
			entry->tick_countdown = PGQP_TICKS_PER_CHECK;
			entry->ticks_since_publish += PGQP_TICKS_PER_CHECK;
			pgqp_maybe_publish(entry);
		}
	}
	else
	{
		/* v3: worker branch, same pacing as pgqp_tick_rows above */
		PgQPWorker *worker = pgqp_worker;

		if (worker != NULL && --worker->tick_countdown <= 0)
		{
			worker->tick_countdown = PGQP_TICKS_PER_CHECK;
			worker->ticks_since_publish += PGQP_TICKS_PER_CHECK;
			pgqp_worker_maybe_publish(worker);
		}
	}
	return slot;
}

/*
 * Resolve the frame gate: bar_min_query_ms > 0
 * wins; the 0 sentinel mirrors bar_interval_ms, so the default gate is
 * 500ms and follows the interval knob without a second setting.
 */
static inline int
pgqp_bar_gate_ms(void)
{
	return (pgqp_bar_min_query_ms > 0) ? pgqp_bar_min_query_ms :
		pgqp_bar_interval_ms;
}

/*
 * Paced publish check; called only every PGQP_TICKS_PER_CHECK node calls.
 */
static void
pgqp_maybe_publish(PgQPEntry *entry)
{
	TimestampTz now = GetCurrentTimestamp();

	if (TimestampDifferenceExceeds(entry->last_publish_time, now,
								   PGQP_PUBLISH_MS) ||
		entry->ticks_since_publish >= PGQP_TICKS_PER_PUBLISH)
		pgqp_publish(entry, false);

	/*
	 * v2 bar frame check: rides the existing 16-tick
	 * clock branch only; with the bar off this is a single unlikely branch
	 * (one global bool read + short circuit) per 16 node calls.  First
	 * frame fires at the first checkpoint whose elapsed(query_start) >=
	 * gate (the !valid direct-fire branch is gated inside
	 * pgqp_bar_frame), then the interval throttles.  No
	 * worker check needed here: workers never get an entry (workers take
	 * the separate pgqp_worker path).
	 */
	if (unlikely(pgqp_bar) &&
		(!entry->bar_last_emit_valid ||
		 TimestampDifferenceExceeds(entry->bar_last_emit, now,
									 pgqp_bar_interval_ms)))
		pgqp_bar_frame(entry, now);
}

/*
 * --------------------------------------------------------------------
 * v3: parallel-worker side tracking
 * --------------------------------------------------------------------
 */

/*
 * Seqlock-validated read of one entry's contribution for node_id:
 * v1 = read(ver); odd -> skip this entry this round; read barrier; read
 * fields; read barrier; v2 = read(ver); adopt iff v1 == v2 (retry once on
 * mismatch, then skip this round).  The DOUBLE read barrier is the
 * canonical seqlock shape (read barriers on both sides of the field
 * loads):
 * ordering v1 before the field loads AND the field loads before v2 is what
 * makes a cross-generation torn snapshot unadoptable on weakly-ordered
 * ISAs.  Entries not matching (leader_proc, seq, ctx_root) are not this
 * Gather's workers and contribute nothing -- the ctx_root match
 * keeps sibling Gathers of the same query from reading
 * each other's counters.
 */
static double
pgqp_wtab_node_rows(PgQPWalk *ctx, int node_id)
{
	PgQPWorkerEntry *strip;
	double		sum = 0.0;
	int			root;
	int			w;

	if (pgqp_wtab == NULL || ctx->depth <= 0 ||
		node_id < 1 || node_id > PGQP_WNODES)
		return 0.0;				/* callers pass depth > 0; belt and braces */

	root = ctx->gather_root[ctx->depth - 1];

	/* strip offset by the context root: distinct Gathers of one query
	 * report through distinct strips */
	strip = PGQP_WENTRIES(pgqp_wtab)
		[(ctx->leader_proc + root) % PGQP_WSTRIPS];

	for (w = 0; w < PGQP_WWORKERS; w++)
	{
		PgQPWorkerEntry *we = &strip[w];
		int			attempt;

		for (attempt = 0; attempt < 2; attempt++)
		{
			uint64		v1;
			uint64		v2;
			int			lp;
			int64		es;
			int			ek;
			double		r;

			v1 = pg_atomic_read_u64(&we->ver);
			if (v1 & 1)
				break;			/* writer active (or dead): skip this round */
			pg_read_barrier();	/* order the v1 load before field loads */
			lp = we->leader_proc;
			es = we->seq;
			ek = we->ctx_key;
			r = we->rows[node_id - 1];
			pg_read_barrier();	/* ...and the field loads before the v2 load */
			v2 = pg_atomic_read_u64(&we->ver);
			if (v1 == v2)
			{
				if (lp == ctx->leader_proc && es == ctx->leader_seq &&
					PGQP_CTX_KEY_ROOT(ek) == root)
					sum += r;
				break;			/* consistent read; done with this entry */
			}
			/* torn read: retry once, else skip this entry this round */
		}
	}
	return sum;
}

/*
 * Walk the worker's own planstate tree (the Gather outer subtree; node
 * identity is plan_node_id, identical to the leader's tree by core's
 * copyObject serialization) and fill buf[id-1] with
 * each node's cumulative output rows.  Mirrors the walk child set of
 * pgqp_walk_children; folded nodes (Bitmap trio, non-root Materialize)
 * carry no counter and stay unwalked / uninstrumented exactly as on the
 * leader side.  plan_node_id outside 1..192 is not reported (write-side
 * write-side bound check; undercount, never a crash).
 */
static void
pgqp_worker_collect(PlanState *ps, double *buf)
{
	Plan	   *plan = ps->plan;
	ListCell   *lc;

	check_stack_depth();

	switch (nodeTag(plan))
	{
		case T_BitmapIndexScan:
		case T_BitmapAnd:
		case T_BitmapOr:
			/* special case 1: folded into the parent, no counter */
			return;
		default:
			break;
	}

	if (ps->instrument != NULL)
	{
		int			id = plan->plan_node_id;

		if (id >= 1 && id <= PGQP_WNODES)
			buf[id - 1] = pgqp_node_rows(ps);
	}

	/* same child set as pgqp_walk_children */
	foreach(lc, ps->initPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_worker_collect(sps->planstate, buf);
	}
	if (ps->lefttree != NULL)
		pgqp_worker_collect(ps->lefttree, buf);
	if (ps->righttree != NULL)
		pgqp_worker_collect(ps->righttree, buf);

	switch (nodeTag(plan))
	{
		case T_Append:
			{
				AppendState *astate = (AppendState *) ps;
				int			i;

				for (i = 0; i < astate->as_nplans; i++)
					pgqp_worker_collect(astate->appendplans[i], buf);
			}
			break;
		case T_MergeAppend:
			{
				MergeAppendState *mstate = (MergeAppendState *) ps;
				int			i;

				for (i = 0; i < mstate->ms_nplans; i++)
					pgqp_worker_collect(mstate->mergeplans[i], buf);
			}
			break;
		case T_SubqueryScan:
			pgqp_worker_collect(((SubqueryScanState *) ps)->subplan, buf);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScanState *) ps)->custom_ps)
				pgqp_worker_collect((PlanState *) lfirst(lc), buf);
			break;
		default:
			break;
	}

	foreach(lc, ps->subPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_worker_collect(sps->planstate, buf);
	}
}

/*
 * Publish the worker's whole-node snapshot into its wtab entry with the
 * seqlock write protocol (single writer: this worker):
 * ver += 1 (odd) -> pg_write_barrier() -> write fields -> pg_memory_barrier()
 * -> ver += 1 (even).
 *
 * Before writing, re-verify that the leader slot is still RUNNING under
 * the same serial S (short spinlock read; NO wtab access inside the
 * spinlock -- lock-order rule).  On mismatch (leader
 * aborted / moved on / ProcNumber got reused) the worker stops reporting
 * and detaches; a mismatched write could only ever publish stale (L, S)
 * data, which new readers filter out structurally.
 */
static void
pgqp_worker_publish(PgQPWorker *worker)
{
	PgQPWorkerEntry *we = worker->wentry;
	PgQPSlot    *slot;
	double		buf[PGQP_WNODES];
	TimestampTz now;
	int			state;
	int64		seq;

	slot = &pgqp_slots[worker->leader_proc];
	SpinLockAcquire(&slot->mutex);
	state = slot->state;
	seq = slot->seq;
	SpinLockRelease(&slot->mutex);

	if (state != PGQP_RUNNING || seq != worker->leader_seq)
	{
		pgqp_worker_detach(worker);
		return;
	}

	MemSet(buf, 0, sizeof(buf));
	pgqp_worker_collect(worker->root_state, buf);

	now = GetCurrentTimestamp();

	pg_atomic_fetch_add_u64(&we->ver, 1);	/* odd: write in progress */
	pg_write_barrier();
	we->leader_proc = worker->leader_proc;
	we->ctx_key = worker->ctx_key;
	we->seq = worker->leader_seq;
	we->last_update = now;
	memcpy(we->rows, buf, sizeof(we->rows));
	pg_memory_barrier();
	pg_atomic_fetch_add_u64(&we->ver, 1);	/* even: stable again */
}

/*
 * Paced worker publish: same cadence as the leader's (>= 250ms or
 * >= 65536 ticks).  Pacing fields are reset BEFORE the publish call
 * because pgqp_worker_publish may detach (and pfree) the worker.
 */
static void
pgqp_worker_maybe_publish(PgQPWorker *worker)
{
	TimestampTz now = GetCurrentTimestamp();

	if (!(TimestampDifferenceExceeds(worker->last_publish_time, now,
									 PGQP_PUBLISH_MS) ||
		  worker->ticks_since_publish >= PGQP_TICKS_PER_PUBLISH))
		return;

	worker->ticks_since_publish = 0;
	worker->last_publish_time = now;
	pgqp_worker_publish(worker);	/* may detach us */
}

/*
 * Free the worker-private state.  The wtab entry itself is NEVER cleared:
 * entries are passive generational data reclaimed by the next claim's
 * overwrite rules -- no free, no lock, no refcount,
 * zero leak surface.
 */
static void
pgqp_worker_detach(PgQPWorker *worker)
{
	Assert(worker == pgqp_worker);
	pgqp_worker = NULL;
	pfree(worker);
}

/*
 * before_shmem_exit fallback: best-effort final publish
 * when Finish/End hooks never ran (worker error path -- core unwinds
 * ParallelQueryMain by longjmp without ExecutorEnd).  At this point the
 * process is exiting but its memory is still mapped: the estate was never
 * freed (standard_ExecutorEnd did not run), so the tree walk reads valid
 * memory; failures are silent by design.  Nothing is cleaned afterwards.
 */
static void
pgqp_worker_exit(int code, Datum arg)
{
	PgQPWorker *worker = pgqp_worker;

	if (worker == NULL)
		return;
	pgqp_worker_publish(worker);
	pgqp_worker_detach(worker);
}

/*
 * Decide whether the entry we is claimable by (L, S, ctx_key), reading its
 * current generation under the seqlock read protocol,
 * amended by the parallel-context key:
 *  - same leader, same serial, same context key: reuse (worker restart
 *    within one query and one Gather, e.g. a rescanned Gather relaunching
 *    workers);
 *  - same leader, older serial: dead generation, its workers must have
 *    exited (the leader's next ExecutorStart happens after
 *    WaitForParallelWorkersToFinish, parallel.c:805);
 *  - another leader's remnant: claimable iff that leader's slot is not
 *    RUNNING with exactly that serial (dead generation / strip collision
 *    residue);
 *  - same leader and serial but a DIFFERENT context key: a sibling
 *    Gather's LIVE entry of the very same query -- NOT claimable
 *    ParallelWorkerNumber repeats across Gathers; overwriting here would
 *    zero the other branch's counters and break single-writer);
 *  - anything else (including a torn read after one retry): not claimable.
 *
 * Lock-order rule: the foreign leader's slot spinlock is taken
 * alone; wtab is never touched under any spinlock.
 */
static bool
pgqp_wtab_entry_claimable(PgQPWorkerEntry *we, int L, int64 S, int ctx_key)
{
	int			attempt;

	for (attempt = 0; attempt < 2; attempt++)
	{
		uint64		v1;
		uint64		v2;
		int			lp;
		int64		es;
		int			ek;

		v1 = pg_atomic_read_u64(&we->ver);
		if (v1 & 1)
			return false;		/* writer active: skip entry this round */
		pg_read_barrier();
		lp = we->leader_proc;
		es = we->seq;
		ek = we->ctx_key;
		pg_read_barrier();
		v2 = pg_atomic_read_u64(&we->ver);
		if (v1 != v2)
			continue;			/* torn: retry once */

		if (lp == L && es == S && ek == ctx_key)
			return true;		/* same round, same Gather: reuse */
		if (lp == L && es < S)
			return true;		/* same leader, dead generation */
		if (lp != L)
		{
			int			ostate;
			int64		oseq;

			if (lp < 0 || lp >= pgqp->nslots)
				return true;	/* garbage owner: treat as dead remnant */
			SpinLockAcquire(&pgqp_slots[lp].mutex);
			ostate = pgqp_slots[lp].state;
			oseq = pgqp_slots[lp].seq;
			SpinLockRelease(&pgqp_slots[lp].mutex);
			if (ostate != PGQP_RUNNING || oseq != es)
				return true;	/* foreign dead generation */
			return false;		/* foreign LIVE generation: collision */
		}
		return false;			/* same (L, S), other ctx_key (sibling
								 * Gather); or es > S: defensive */
	}
	return false;
}

/*
 * v3.2: restore the core's
 * per-node index-scan instrumentation pairing on the WORKER side.
 *
 * Core allocates the per-node index scan instruments
 * (iss_/ioss_/biss_Instrument) only when estate->es_instrument is set --
 * which this extension never sets, because it injects per-node
 * instrumentation itself after standard_ExecutorStart instead.
 * (This is the PostgreSQL 20 shape; earlier majors either embed the
 * structure -- never NULL, nothing to pair -- or have no index scan
 * instrumentation at all, which is why this whole block exists only on
 * PGQP_HAVE_INDEX_INSTR builds.)
 * The parallel DSM instrumentation hooks, however, gate on ps->instrument
 * (ExecIndex{,Only}ScanInstrumentInitDSM nodeIndexonlyscan.c:874 /
 * ...InitWorker :898; ExecBitmapIndexScanInitializeDSM :392 /
 * ...InitializeWorker :418): with our injection those see a non-NULL
 * ps->instrument in BOTH the leader and (since v3) the worker, so the
 * SharedInfo block is inserted into the plan's DSM at the first Gather call
 * (nodeGather.c:152-171) and attached in every worker.  At worker
 * ExecutorEnd, ExecEndIndex{,Only}Scan / ExecEndBitmapIndexscan then do
 *		winstrument->nsearches += node->X_Instrument->nsearches;
 * (nodeIndexonlyscan.c:443, nodeIndexscan.c:820, nodeBitmapIndexscan.c:206)
 * -- a NULL dereference, SIGSEGV, and a postmaster-judged crash of the
 * whole cluster.  (v1/v2 were safe only because workers carried no
 * injection and thus never attached SharedInfo; the leader's End block is
 * guarded by IsParallelWorker().)
 *
 * Fix: allocate the missing IndexScanInstrumentation for every index scan
 * state in the worker's tree, in es_query_cxt (same lifetime as core's
 * InitPlan allocation), BEFORE ExecParallelInitializeWorker runs -- which
 * is where ioss_/iss_Instrument also flows into index_beginscan_parallel,
 * so the AM-level search counting works exactly as with es_instrument on.
 *
 * The walk must descend into the bitmapplans arrays that the progress walk
 * folds away (special case 1): a BitmapIndexScanState under a
 * BitmapAnd/BitmapOr crashes at worker End just the same, whether or not
 * the worker ever executes its MultiExec.
 */
#ifdef PGQP_HAVE_INDEX_INSTR
static void
pgqp_worker_alloc_index_instruments(PlanState *ps)
{
	Plan	   *plan = ps->plan;
	ListCell   *lc;
	int			i;

	check_stack_depth();

	switch (nodeTag(ps))
	{
		case T_IndexScanState:
			if (((IndexScanState *) ps)->iss_Instrument == NULL)
				((IndexScanState *) ps)->iss_Instrument =
					palloc0_object(IndexScanInstrumentation);
			break;
		case T_IndexOnlyScanState:
			if (((IndexOnlyScanState *) ps)->ioss_Instrument == NULL)
				((IndexOnlyScanState *) ps)->ioss_Instrument =
					palloc0_object(IndexScanInstrumentation);
			break;
		case T_BitmapIndexScanState:
			if (((BitmapIndexScanState *) ps)->biss_Instrument == NULL)
				((BitmapIndexScanState *) ps)->biss_Instrument =
					palloc0_object(IndexScanInstrumentation);
			break;
		default:
			break;
	}

	/* full child set, including the folded bitmap arrays */
	foreach(lc, ps->initPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_worker_alloc_index_instruments(sps->planstate);
	}
	if (ps->lefttree != NULL)
		pgqp_worker_alloc_index_instruments(ps->lefttree);
	if (ps->righttree != NULL)
		pgqp_worker_alloc_index_instruments(ps->righttree);

	switch (nodeTag(plan))
	{
		case T_Append:
			{
				AppendState *astate = (AppendState *) ps;

				for (i = 0; i < astate->as_nplans; i++)
					pgqp_worker_alloc_index_instruments(astate->appendplans[i]);
			}
			break;
		case T_MergeAppend:
			{
				MergeAppendState *mstate = (MergeAppendState *) ps;

				for (i = 0; i < mstate->ms_nplans; i++)
					pgqp_worker_alloc_index_instruments(mstate->mergeplans[i]);
			}
			break;
		case T_BitmapAnd:
		case T_BitmapOr:
			{
				PlanState **bplans = (nodeTag(plan) == T_BitmapAnd) ?
					((BitmapAndState *) ps)->bitmapplans :
					((BitmapOrState *) ps)->bitmapplans;
				int			nplans = (nodeTag(plan) == T_BitmapAnd) ?
					((BitmapAndState *) ps)->nplans :
					((BitmapOrState *) ps)->nplans;

				for (i = 0; i < nplans; i++)
					pgqp_worker_alloc_index_instruments(bplans[i]);
			}
			break;
		case T_SubqueryScan:
			pgqp_worker_alloc_index_instruments(((SubqueryScanState *) ps)->subplan);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScanState *) ps)->custom_ps)
				pgqp_worker_alloc_index_instruments((PlanState *) lfirst(lc));
			break;
		default:
			break;
	}

	foreach(lc, ps->subPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_worker_alloc_index_instruments(sps->planstate);
	}
}
#endif							/* PGQP_HAVE_INDEX_INSTR */

/*
 * Claim the entry with the seqlock write protocol, whole overwrite
 * (rows zeroed).  Before overwriting we must observe an even ver
 * (bounded retry, 8 x 1ms): this seals the theoretical window where
 * a still-running remnant worker of an older generation sits inside its
 * microseconds-long write critical section while we start a new one.
 * A persistently odd ver (writer died inside its critical section --
 * SIGKILL is not interceptable) can never be reclaimed here: per
 * the two-observations-60s-apart zombie rule has no
 * cross-query storage for the first observation, so the implemented
 * semantics are the degraded ones -- the slot stays lost until the next
 * init_fn rebuild (crash restart), a bounded loss of 1/2048 entries.
 */
static bool
pgqp_wtab_claim(PgQPWorkerEntry *we, int L, int64 S, int ctx_key)
{
	uint64		ver = 1;
	int			attempt;

	for (attempt = 0; attempt < 8; attempt++)
	{
		ver = pg_atomic_read_u64(&we->ver);
		if (!(ver & 1))
			break;
		pg_usleep(1000);		/* 1ms spacing */
	}
	if (ver & 1)
		return false;			/* stuck odd: degrade to non-reporting */

	if (!pgqp_wtab_entry_claimable(we, L, S, ctx_key))
		return false;

	pg_atomic_fetch_add_u64(&we->ver, 1);	/* odd */
	pg_write_barrier();
	we->leader_proc = L;
	we->ctx_key = ctx_key;
	we->seq = S;
	we->last_update = GetCurrentTimestamp();
	MemSet(we->rows, 0, sizeof(we->rows));
	pg_memory_barrier();
	pg_atomic_fetch_add_u64(&we->ver, 1);	/* even */
	return true;
}

/*
 * Worker-side ExecutorStart path.  Preconditions:
 * IsParallelWorker() && L = leader proc number >= 0 (hard bound:
 * non-parallel bgworkers export INVALID_PROC_NUMBER == -1, which must
 * never reach the %PGQP_WSTRIPS index) && pgqp_track && CMD_SELECT &&
 * not EXPLAIN-only/generic.  The leader slot must be RUNNING (untracked
 * leader -> unreported worker, both directions consistent).  Claim
 * failure of any kind degrades to non-reporting (undercount, never a
 * crash).
 */
static void
pgqp_worker_register(QueryDesc *queryDesc, int eflags)
{
	PgQPWorker *worker;
	PgQPWorkerEntry *we;
	PgQPSlot    *slot;
	MemoryContext oldctx;
	TimestampTz now;
	int			L;
	int			state;
	int64		S;
	int			R;
	int			ctx_key;

	if (!pgqp_track || pgqp == NULL || pgqp_wtab == NULL || pgqp_slots == NULL)
		return;
	if (queryDesc->operation != CMD_SELECT)
		return;
	if (eflags & (EXEC_FLAG_EXPLAIN_ONLY | EXEC_FLAG_EXPLAIN_GENERIC))
		return;
	if (queryDesc->estate == NULL || queryDesc->planstate == NULL)
		return;

	L = PGQP_LEADER_PROCNO();
	if (L < 0 || L >= pgqp->nslots)		/* INVALID_PROC_NUMBER = -1 */
		return;
	if (ParallelWorkerNumber < 0 || ParallelWorkerNumber >= PGQP_WWORKERS)
		return;				/* >= 16 workers: not reported */
	if (pgqp_worker != NULL)
		return;				/* defensive: one query per worker process */

	/*
	 * v3.1: the parallel-context key.  The worker tree
	 * root is the leader Gather's outer subtree root (ExecInitParallelPlan
	 * serializes exactly that subtree, nodeGather.c:167 / GM nodeGatherMerge.c:211),
	 * so its plan_node_id identifies the Gather this worker belongs to and
	 * is distinct for every Gather of the query.
	 */
	R = queryDesc->planstate->plan->plan_node_id;
	if (R < 1 || R > PGQP_CTX_ROOT_MAX)
		return;				/* absurd plan shape: degrade silently */
	ctx_key = PGQP_CTX_KEY(R, ParallelWorkerNumber);

	/* leader slot short read: (state, seq); RUNNING only */
	slot = &pgqp_slots[L];
	SpinLockAcquire(&slot->mutex);
	state = slot->state;
	S = slot->seq;
	SpinLockRelease(&slot->mutex);
	if (state != PGQP_RUNNING)
		return;

	/*
	 * Entry address, strip offset by the context root: sibling
	 * Gathers of one query land in different strips in the common case;
	 * on the residual R-collision (mod 128) the claim rules below refuse
	 * (same S, different ctx_key) and the worker degrades instead of
	 * ever wiping a live sibling's counters.
	 */
	we = &PGQP_WENTRIES(pgqp_wtab)
		[(L + R) % PGQP_WSTRIPS][ParallelWorkerNumber];
	if (!pgqp_wtab_claim(we, L, S, ctx_key))
		return;				/* degrade: this worker undercounts */

	/*
	 * Wrap the worker's planstate tree exactly like the leader's (same
	 * function, same non-root Materialize folding; existing instruments
	 * from EXPLAIN ANALYZE only get the wrapper).  Wrap happens before the
	 * worker state allocation so a wrap ERROR leaves no allocation behind;
	 * a claimed entry left behind is passive data and harmless.
	 *
	 * The index-scan instrumentation pairing must be restored in the
	 * same context and before ExecParallelInitializeWorker (which passes
	 * the instruments into index_beginscan_parallel and attaches the DSM
	 * SharedInfo blocks whose End-time accumulation would otherwise
	 * dereference NULL).
	 */
	oldctx = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);
	pgqp_wrap_planstate(queryDesc->planstate, true);
#ifdef PGQP_HAVE_INDEX_INSTR
	pgqp_worker_alloc_index_instruments(queryDesc->planstate);
#endif
	MemoryContextSwitchTo(oldctx);

	if (pgqp_ctx == NULL)
		pgqp_ctx = AllocSetContextCreate(TopMemoryContext,
										 "pg_query_progress",
										 ALLOCSET_DEFAULT_SIZES);

	now = GetCurrentTimestamp();
	worker = (PgQPWorker *) MemoryContextAlloc(pgqp_ctx, sizeof(PgQPWorker));
	worker->queryDesc = queryDesc;
	worker->root_state = queryDesc->planstate;
	worker->wentry = we;
	worker->leader_proc = L;
	worker->leader_seq = S;
	worker->ctx_root = R;
	worker->ctx_key = ctx_key;
	worker->tick_countdown = PGQP_TICKS_PER_CHECK;
	worker->ticks_since_publish = 0;
	worker->last_publish_time = now;
	pgqp_worker = worker;

	/* before_shmem_exit fallback; registered once per process */
	if (!pgqp_exit_registered)
	{
		before_shmem_exit(pgqp_backend_cleanup, (Datum) 0);
		before_shmem_exit(pgqp_worker_exit, (Datum) 0);
		pgqp_exit_registered = true;
	}
}

/*
 * --------------------------------------------------------------------
 * Progress computation
 * --------------------------------------------------------------------
 */

/*
 * Rows emitted by a node so far: ntuples + tuplecount.  InstrEndLoop
 * (invoked from ExecReScan, execAmi.c:76-82) folds tuplecount into ntuples
 * on every rescan, so the sum never decreases across rescans.
 */
static double
pgqp_node_rows(PlanState *ps)
{
	PgQpNodeInstr *instr = ps->instrument;

	if (instr == NULL)
		return 0.0;
	return instr->ntuples + instr->tuplecount;
}

/*
 * Walk the children of ps, mirroring the child set of
 * planstate_tree_walker_impl (nodeFuncs.c:4872-4950): initPlan list,
 * lefttree, righttree, Append/MergeAppend/BitmapAnd/BitmapOr arrays,
 * SubqueryScan->subplan, CustomScan->custom_ps, and the subPlan list.
 *
 * Returns the sum of total_cost over *counted* direct children, for the
 * parent's self_cost deduction.  Special case 1:
 * BitmapIndexScan/BitmapAnd/BitmapOr subtrees are not walked and do not
 * contribute to the deduction, folding their cost into the parent
 * (BitmapHeapScan) node.
 *
 * v3: 'leftacc' selects the accumulator the LEFT subtree is walked into;
 * it equals 'acc' everywhere except the BLOCKING nodes, whose outer-input
 * subtree is isolated into a sub-accumulator to drive frac'.
 * All children are walked with the same ctx (parallel divisors
 * and merge identity propagate unchanged).
 */
static double
pgqp_walk_children(PlanState *ps, PgQPAccum *acc, PgQPAccum *leftacc,
				   PgQPWalk *ctx)
{
	Plan	   *plan = ps->plan;
	double		deduct = 0.0;
	ListCell   *lc;

	check_stack_depth();

	/* initPlan-s (uncorrelated SubPlans) */
	foreach(lc, ps->initPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		deduct += pgqp_walk_node(sps->planstate, acc, ctx);
	}

	/* lefttree / righttree */
	if (ps->lefttree != NULL)
		deduct += pgqp_walk_node(ps->lefttree, leftacc, ctx);
	if (ps->righttree != NULL)
		deduct += pgqp_walk_node(ps->righttree, acc, ctx);

	/* array-of-children node types */
	switch (nodeTag(plan))
	{
		case T_Append:
			{
				AppendState *astate = (AppendState *) ps;
				int			i;

				for (i = 0; i < astate->as_nplans; i++)
					deduct += pgqp_walk_node(astate->appendplans[i], acc, ctx);
			}
			break;
		case T_MergeAppend:
			{
				MergeAppendState *mstate = (MergeAppendState *) ps;
				int			i;

				for (i = 0; i < mstate->ms_nplans; i++)
					deduct += pgqp_walk_node(mstate->mergeplans[i], acc, ctx);
			}
			break;
		case T_BitmapAnd:
		case T_BitmapOr:
			/*
			 * Reached only when a BitmapAnd/Or is the root or hangs under a
			 * non-BitmapHeapScan parent (not produced by the planner today).
			 * pgqp_walk_node already skipped the node itself; never descend.
			 */
			break;
		case T_SubqueryScan:
			deduct += pgqp_walk_node(((SubqueryScanState *) ps)->subplan,
									 acc, ctx);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScanState *) ps)->custom_ps)
				deduct += pgqp_walk_node((PlanState *) lfirst(lc), acc, ctx);
			break;
		default:
			break;
	}

	/* subPlan-s (correlated SubPlans) */
	foreach(lc, ps->subPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		deduct += pgqp_walk_node(sps->planstate, acc, ctx);
	}

	return deduct;
}

/*
 * Process one planstate node.  Returns the node's total_cost when it was
 * counted (so the parent deducts it), or 0.0 for skipped subtrees.
 *
 * Special cases:
 * 1. BitmapIndexScan/BitmapAnd/BitmapOr: return 0 without accumulating;
 *    their cost stays inside the parent's self_cost.
 * 2. Gather/GatherMerge -- v3 REPEALS the v1 fold:
 *    descend normally.  Entering the subtree pushes the parallel divisor
 *    D-hat = W + max(0, 1 - 0.3*W) (leader participation is always true
 *    in this tree, replicating costsize.c:6733-6760); every node inside
 *    merges matching worker counts into its numerator and multiplies its
 *    denominator by D-hat.  The Gather node itself stays
 *    output-driven on its full-scale plan_rows (compute_gather_rows
 *    semantics; no D-hat), its own counter already counting every tuple
 *    that leaves the Gather, worker-produced ones included.
 * 3. Materialize (non-root; root Materialize is wrapped and takes the
 *    default path): a 1:1 buffer whose row count duplicates its child's.
 *    Not wrapped (no instrument), so its own rows are always 0; fold its
 *    self cost into the child subtree and drive the block with the child
 *    subtree's progress: completed_children / total_children.  Zero
 *    information loss -- the buffer emits exactly its input.
 * 4. BLOCKING = {T_Agg all shapes, T_Sort, T_SetOp} -- v3 input-driven
 *    model: frac' = subtree_progress(outer input) instead
 *    of the node's own (blocked) output counter.  T_IncrementalSort,
 *    T_WindowAgg, T_Unique and T_Group are streaming and stay
 *    output-driven; T_Hash keeps its v1 MultiExec count-to-full semantics.
 */
static double
pgqp_walk_node(PlanState *ps, PgQPAccum *acc, PgQPWalk *ctx)
{
	NodeTag		tag = nodeTag(ps->plan);
	double		deduct;
	double		self;
	double		rows;
	double		denom;
	double		frac;


	switch (tag)
	{
		case T_BitmapIndexScan:
		case T_BitmapAnd:
		case T_BitmapOr:
			/* special case 1: not a progress signal */
			return 0.0;

		case T_Material:
			if (ps->instrument == NULL)
			{
				/* special case 3: folded node, child-driven frac */
				PgQPAccum	sub;

				MemSet(&sub, 0, sizeof(sub));
				deduct = pgqp_walk_children(ps, &sub, &sub, ctx);
				self = ps->plan->total_cost - deduct;
				if (self < 0.0)
					self = 0.0;

				frac = (sub.total_self > 0.0) ?
					sub.completed / sub.total_self : 0.0;

				acc->completed += (self + sub.total_self) * frac;
				acc->total_self += self + sub.total_self;
				acc->tuples += sub.tuples;
				acc->nodes_total += sub.nodes_total;
				acc->nodes_done += sub.nodes_done;
				return ps->plan->total_cost;
			}
			/* root Materialize is wrapped (instrument != NULL): default */
			break;

		case T_Gather:
		case T_GatherMerge:
			{
				Gather     *gplan = (Gather *) ps->plan;
				int			W = gplan->num_workers;
				double		dhat;
				int			root;

				/*
				 * D-hat = W + leader_share replicates get_parallel_divisor
				 * (costsize.c), where leader_share = max(0, 1 - 0.3*W)
				 * when the leader participates in the parallel plan and 0
				 * when it does not (parallel_leader_participation=off;
				 * both Gather and Gather Merge honor it).  The walk reads
				 * the ExecutorStart snapshot from the walk context, never
				 * the GUC itself.
				 *
				 * Single-copy special case: a single_copy Gather was
				 * created from a parallel_workers == 0 path (pathnode.c
				 * forces num_workers = 1 + single_copy), and core priced
				 * that subpath with divisor 1.0 -- the restore must
				 * multiply by 1.0 as well, not by the W=1 value 1.7.
				 */
				if (tag == T_Gather && gplan->single_copy)
					dhat = 1.0;
				else if (ctx->leader_participation)
					dhat = (double) W + Max(0.0, 1.0 - 0.3 * (double) W);
				else
					dhat = (double) W;

				/*
				 * Push D-hat and the context root (the outer subtree's
				 * plan_node_id -- the worker-tree root, merge key)
				 * around the parallel subtree (kept as a stack for
				 * future plan shapes).
				 */
				root = (ps->lefttree != NULL) ?
					ps->lefttree->plan->plan_node_id : 0;
				if (ctx->depth < PGQP_MAX_GATHER_DEPTH)
				{
					ctx->divisor[ctx->depth] = dhat;
					ctx->gather_root[ctx->depth] = root;
					ctx->depth++;
				}
				deduct = pgqp_walk_children(ps, acc, acc, ctx);
				if (ctx->depth > 0)
					ctx->depth--;

				self = ps->plan->total_cost - deduct;
				if (self < 0.0)
					self = 0.0;

				/* Gather itself: full-scale output, no D-hat */
				rows = pgqp_node_rows(ps);
				frac = rows / Max(ps->plan->plan_rows, 1.0);
				if (frac > 1.0)
					frac = 1.0;

				acc->completed += self * frac;
				acc->total_self += self;
				acc->tuples += rows;
				acc->nodes_total++;
				acc->nodes_done += (frac >= 0.999) ? 1 : 0;

				return ps->plan->total_cost;
			}

		case T_Agg:
		case T_Sort:
		case T_SetOp:
			{
				/* special case 4: BLOCKING, input-driven frac' */
				PgQPAccum	sub;

				MemSet(&sub, 0, sizeof(sub));
				/* outer input (lefttree) isolated into sub; any initPlan /
				 * subPlan children (no righttree for these tags) go to the
				 * parent accumulator directly */
				deduct = pgqp_walk_children(ps, acc, &sub, ctx);
				self = ps->plan->total_cost - deduct;
				if (self < 0.0)
					self = 0.0;

				frac = (sub.total_self > 0.0) ?
					sub.completed / sub.total_self : 0.0;

				/* the node's own emitted rows still feed tuples_processed
				 * (merged inside the parallel region) */
				rows = pgqp_node_rows(ps);
				if (ctx->depth > 0)
					rows += pgqp_wtab_node_rows(ctx,
												ps->plan->plan_node_id);

				/*
				 * Weight invariance: the outer subtree's
				 * own terms enter the parent accumulator unchanged -- every
				 * subtree node keeps its self*frac contribution and its
				 * self in the denominator; frac' (input-driven) replaces
				 * ONLY this node's own term.  The sub accumulator exists
				 * solely to snapshot the subtree's completion ratio.
				 */
				acc->completed += sub.completed + self * frac;
				acc->total_self += sub.total_self + self;
				acc->tuples += sub.tuples + rows;
				acc->nodes_total += sub.nodes_total + 1;
				acc->nodes_done += sub.nodes_done + ((frac >= 0.999) ? 1 : 0);


				return ps->plan->total_cost;
			}

		default:
			break;
	}

	deduct = pgqp_walk_children(ps, acc, acc, ctx);
	self = ps->plan->total_cost - deduct;
	if (self < 0.0)
		self = 0.0;

	rows = pgqp_node_rows(ps);
	denom = Max(ps->plan->plan_rows, 1.0);
	if (ctx->depth > 0)
	{
		/* inside the parallel region: merge worker counts, restore the
		 * planner's division by D-hat */
		rows += pgqp_wtab_node_rows(ctx, ps->plan->plan_node_id);
		denom *= ctx->divisor[ctx->depth - 1];
	}
	frac = rows / denom;
	if (frac > 1.0)
		frac = 1.0;

	acc->completed += self * frac;
	acc->total_self += self;
	acc->tuples += rows;
	acc->nodes_total++;
	acc->nodes_done += (frac >= 0.999) ? 1 : 0;


	return ps->plan->total_cost;
}

/*
 * Compute the current progress fraction and write it to the slot.
 *
 * Called from the query backend at most every 250ms (plus the four forced
 * points: ExecutorStart's zero snapshot, root EOF, ExecutorFinish and
 * ExecutorEnd / xact abort).  The spinlock is held only for a handful of
 * scalar stores.
 *
 * v3: the walk now merges worker counts under
 * Gather subtrees.  The merge reads happen OUTSIDE the slot spinlock
 * (lock-order rule: merge first, enter the slot critical section
 * only afterwards).
 */
static void
pgqp_publish(PgQPEntry *entry, bool force_done)
{
	PgQPAccum	acc;
	PgQPWalk	ctx;
	PgQPSlot  *slot = entry->slot;
	PlanState  *root = entry->root_state;
	double		p;

	MemSet(&acc, 0, sizeof(acc));
	ctx.leader_proc = PGQP_MY_PROCNO();
	ctx.leader_seq = entry->slot_seq;
	ctx.leader_participation = entry->leader_participation;
	ctx.depth = 0;
	if (root != NULL)
		pgqp_walk_node(root, &acc, &ctx);

	p = (acc.total_self > 0.0) ? acc.completed / acc.total_self : 0.0;
	if (force_done || entry->drained)
		p = 1.0;
	if (p < entry->last_progress)
		p = entry->last_progress;	/* monotonic clamp */
	entry->last_progress = p;
	entry->ticks_since_publish = 0;
	entry->last_publish_time = GetCurrentTimestamp();

	SpinLockAcquire(&slot->mutex);
	slot->progress = p;
	slot->completed_cost = acc.completed;
	slot->total_cost = acc.total_self;
	slot->rows_returned = (root != NULL) ? pgqp_node_rows(root) : 0.0;
	slot->tuples_processed = acc.tuples;
	slot->nodes_total = acc.nodes_total;
	slot->nodes_done = acc.nodes_done;
	slot->last_update = entry->last_publish_time;
	SpinLockRelease(&slot->mutex);
}

/*
 * Transition the slot to a terminal state (under the slot spinlock).
 */
static void
pgqp_set_slot_state(PgQPEntry *entry, PgQPSlotState state)
{
	SpinLockAcquire(&entry->slot->mutex);
	if (entry->slot->state == PGQP_RUNNING)
		entry->slot->state = (int) state;
	entry->slot->last_update = GetCurrentTimestamp();
	SpinLockRelease(&entry->slot->mutex);
}

/*
 * --------------------------------------------------------------------
 * v2: in-session progress-bar frames
 * --------------------------------------------------------------------
 */

/*
 * Render the 24-cell bar into cells[]: PGQP_BAR_CELLS "filled"
 * characters followed by PGQP_BAR_CELLS - filled "empty" characters; each
 * character is a 3-byte UTF-8 sequence emitted as raw bytes below (U+2588
 * FULL BLOCK / U+2591 LIGHT SHADE).
 */
static void
pgqp_bar_cells(char *cells, int filled)
{
	int			i;
	int			n = 0;

	if (filled < 0)
		filled = 0;
	if (filled > PGQP_BAR_CELLS)
		filled = PGQP_BAR_CELLS;
	for (i = 0; i < filled; i++)
	{
		cells[n++] = (char) 0xe2;
		cells[n++] = (char) 0x96;
		cells[n++] = (char) 0x88;	/* U+2588 FULL BLOCK */
	}
	for (i = filled; i < PGQP_BAR_CELLS; i++)
	{
		cells[n++] = (char) 0xe2;
		cells[n++] = (char) 0x96;
		cells[n++] = (char) 0x91;	/* U+2591 LIGHT SHADE */
	}
	cells[n] = '\0';
}

/*
 * Emit one bar frame as a NOTICE.  The whole frame is formatted into a
 * stack buffer (R12: no persistent allocation; ereport-side allocations
 * live in ErrorContext and are reset right after the send).
 *
 * The client_min_messages short-circuit runs BEFORE any formatting work:
 * when the frame would not be interesting to anyone, we only stamp the
 * throttle timestamp and return (message_level_is_interesting is the
 * exported mirror of errstart's decision, elog.h:171 / elog.c:284-295).
 */
static void
pgqp_bar_frame(PgQPEntry *entry, TimestampTz now)
{
	char		cells[PGQP_BAR_CELLS * 3 + 1];
	char		buf[160];
	double		p;
	double		elapsed;
	long		secs;
	int			micros;
	const char *prefix = "";
	char		tuples_str[16];
	int			filled;

	if (!message_level_is_interesting(NOTICE))
	{
		/*
		 * suppressed: stamp only the throttle clock and skip formatting.
		 * v3.1: do NOT arm bar_last_emit_valid here --
		 * the valid arm of the terminal gate may only be
		 * set by a frame that passed the elapsed gate; arming it on a
		 * suppressed checkpoint would let a later client_min_messages
		 * relaxation emit a terminal frame for a sub-gate query.
		 */
		entry->bar_last_emit = now;
		return;
	}

	/*
	 * v3 unified elapsed gate: a frame may be emitted
	 * only once the query has lived gate_ms (query_start -> now).  This
	 * kills both the first-frame direct-fire (the old !valid branch
	 * bypassed every time gate, which let millisecond-old catalog queries
	 * emit) and any intermediate frame of a sub-gate query.  Nothing is
	 * stamped on the gated path, so the next 16-tick checkpoint retries
	 * naturally; the first frame therefore lands in [gate, gate+320ms]
	 * (one checkpoint window under slow tuple flow).
	 */
	if (!TimestampDifferenceExceeds(entry->slot->query_start, now,
									pgqp_bar_gate_ms()))
		return;

	/*
	 * Refresh the snapshot first: bar frames and slot contents stay
	 * strictly same-source, same-moment.  We are the sole
	 * writer of this slot, so reading the just-written scalars below
	 * needs no lock.
	 */
	pgqp_publish(entry, false);

	p = entry->last_progress;	/* monotonic clamp value */

	TimestampDifference(entry->slot->query_start, now, &secs, &micros);
	elapsed = (double) secs + (double) micros / 1000000.0;

	filled = (int) (p * (double) PGQP_BAR_CELLS);
	pgqp_bar_cells(cells, filled);

	if (pgqp_bar_ansi)
		prefix = entry->bar_ansi_started ?
			"\x1b[1A\x1b[2K\r" : "\x1b[2K\r";

	{
		int64		t = entry->slot->tuples_processed;
		int			nd = entry->slot->nodes_done;
		int			nt = entry->slot->nodes_total;

		if (t >= 1000000000LL)
			snprintf(tuples_str, sizeof(tuples_str), "%.1fG",
					 (double) t / 1e9);
		else if (t >= 1000000)
			snprintf(tuples_str, sizeof(tuples_str), "%.1fM",
					 (double) t / 1e6);
		else if (t >= 1000)
			snprintf(tuples_str, sizeof(tuples_str), "%.0fK",
					 (double) t / 1e3);
		else
			snprintf(tuples_str, sizeof(tuples_str), "%lld",
					 (long long) t);

		if (p >= 0.05)
		{
			char		eta_str[24];

			snprintf(eta_str, sizeof(eta_str), "eta %.1fs",
					 (p > 0.0) ? elapsed / p - elapsed : 0.0);
			snprintf(buf, sizeof(buf),
					 "%s[%s] %.1f%% %.1fs %s nodes %d/%d tuples %s",
					 prefix, cells, p * 100.0, elapsed, eta_str, nd, nt,
					 tuples_str);
		}
		else
			snprintf(buf, sizeof(buf),
					 "%s[%s] %.1f%% %.1fs eta -- nodes %d/%d tuples %s",
					 prefix, cells, p * 100.0, elapsed, nd, nt,
					 tuples_str);
	}

	ereport(NOTICE, (errmsg("%s", buf)));

	if (pgqp_bar_ansi)
		entry->bar_ansi_started = true;
	entry->bar_last_emit = now;
	entry->bar_last_emit_valid = true;
}

/*
 * Terminal frame: one extra frame at
 * ExecutorFinish ("done" for drained queries) and at TERMINATED
 * transitions ("terminated at X%").  Renders from entry->last_progress as
 * left by the terminal publish -- no recomputation, no interval gate, and
 * no frame on abort/FAILED paths (the following ERROR/FATAL report is the
 * user feedback there).
 *
 * v3.1 terminal gate: emit iff
 *	bar_last_emit_valid || elapsed(query_start -> now) >= gate_ms.
 * The disjuncts each block one class: a sub-gate query can never have
 * valid set (only a gated first frame sets it), so short queries stay
 * zero-frame; a >= gate query whose 16-tick checkpoints all fell before
 * the gate (checkpoint-starved shape, e.g. a slow SRF with < 32 node
 * calls) never gets valid set either, and the elapsed arm preserves its
 * terminal frame -- the "long-query frame sequence must not regress"
 * requirement.
 */
static void
pgqp_bar_terminal(PgQPEntry *entry, const char *tag)
{
	char		cells[PGQP_BAR_CELLS * 3 + 1];
	char		buf[160];
	double		p = entry->last_progress;
	double		elapsed;
	long		secs;
	int			micros;
	const char *prefix = "";
	TimestampTz now = GetCurrentTimestamp();

	if (!message_level_is_interesting(NOTICE))
		return;

	if (!entry->bar_last_emit_valid &&
		!TimestampDifferenceExceeds(entry->slot->query_start, now,
									pgqp_bar_gate_ms()))
		return;

	TimestampDifference(entry->slot->query_start, now, &secs, &micros);
	elapsed = (double) secs + (double) micros / 1000000.0;

	pgqp_bar_cells(cells, (int) (p * (double) PGQP_BAR_CELLS));

	if (pgqp_bar_ansi)
		prefix = entry->bar_ansi_started ?
			"\x1b[1A\x1b[2K\r" : "\x1b[2K\r";

	if (strcmp(tag, "done") == 0)
		snprintf(buf, sizeof(buf), "%s[%s] 100.0%% done %.1fs",
				 prefix, cells, elapsed);
	else
		snprintf(buf, sizeof(buf), "%s[%s] %s at %.1f%% %.1fs",
				 prefix, cells, tag, p * 100.0, elapsed);

	ereport(NOTICE, (errmsg("%s", buf)));

	if (pgqp_bar_ansi)
		entry->bar_ansi_started = true;
}

/*
 * --------------------------------------------------------------------
 * Executor hooks
 * --------------------------------------------------------------------
 */

/*
 * ExecutorStart hook: chain to prev first (planstate tree must exist), then
 * optionally install instrumentation + tick wrappers and claim the slot.
 *
 * v3: parallel workers take a separate, lighter path --
 * they run all four Executor hooks (execParallel.c:1550/1581/1586/1608),
 * claim no slot row, render no bar, and publish only into their wtab
 * entry.  The old blanket IsParallelWorker() skip is thereby replaced by
 * real worker-side tracking.
 */
static void
pgqp_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);

	if (IsParallelWorker())
	{
		pgqp_worker_register(queryDesc, eflags);
		return;
	}

	if (!pgqp_should_track(queryDesc, eflags))
		return;

	/*
	 * Defensive: detach a still-attached entry.  The only reachable case is
	 * a cursor portal still open when another query starts in this session
	 * (End/abort detach covers everything else): exactly one portal per
	 * session is tracked.  The interrupted query has
	 * NOT failed -- publish its true progress and mark it TERMINATED
	 * so the stale portal is marked, not failed; the new query claims the
	 * slot right below,
	 * so the TERMINATED row is observable only by a concurrent reader in
	 * the window between the two operations.
	 */
	if (pgqp_entry != NULL)
	{
		PgQPEntry *stale = pgqp_entry;

		pgqp_publish(stale, false);
		pgqp_set_slot_state(stale, PGQP_TERMINATED);
		if (pgqp_bar)
			pgqp_bar_terminal(stale, "terminated");
		pgqp_detach_entry(stale);
	}

	pgqp_begin_track(queryDesc);
}

/*
 * (Re-)point ps->ExecProcNode at one of our tick wrappers, selected once
 * by the instrument's immutable option flags (see the pgqp_tick_rows
 * comment).  No-op when the wrapper is already installed, so it is safe
 * to call again (the worker re-wrap path).
 */
static void
pgqp_install_wrapper(PlanState *ps)
{
	Instrumentation *ist = PGQP_BASE_INSTR(ps);

	if (ps->ExecProcNode == pgqp_tick || ps->ExecProcNode == pgqp_tick_rows)
		return;
	if (ist->need_timer || ist->need_bufusage || ist->need_walusage)
		ps->ExecProcNode = pgqp_tick;
	else
		ps->ExecProcNode = pgqp_tick_rows;
}

/*
 * v3.1: re-install the tick wrappers across a worker's
 * planstate tree.  Core's ExecParallelInitializeWorker runs AFTER our
 * ExecutorStart wrap (ParallelQueryMain order, execParallel.c) and PHJ
 * nodes reset ExecProcNode there via
 * ExecSetExecProcNode(&state->js.ps, ExecParallelHashJoin)
 * (nodeHashjoin.c:1976), silently dropping our wrapper on that node --
 * the counters keep flowing through core's ExecProcNodeInstr, but the
 * node's tick pacing is lost and the worker's publish cadence coarsens.
 * ExecSetExecProcNode preserves the node's true function in
 * ExecProcNodeReal, so re-pointing ExecProcNode is exactly equivalent to
 * the initial wrap.  Called from the worker's ExecutorRun hook entry:
 * after ExecParallelInitializeWorker, before any tuple has flowed.
 * Leader side needs no counterpart (its Exec*InitializeDSM calls happen
 * inside standard_ExecutorStart, i.e. before our wrap).
 */
static void
pgqp_rewrap_planstate(PlanState *ps)
{
	Plan	   *plan = ps->plan;
	ListCell   *lc;

	check_stack_depth();

	switch (nodeTag(plan))
	{
		case T_BitmapIndexScan:
		case T_BitmapAnd:
		case T_BitmapOr:
			return;				/* folded nodes: never wrapped */
		default:
			break;
	}

	if (ps->instrument != NULL)
		pgqp_install_wrapper(ps);	/* non-root Materialize stays
									 * unwrapped (instrument NULL) */

	/* recurse: same child set as pgqp_wrap_planstate */
	foreach(lc, ps->initPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_rewrap_planstate(sps->planstate);
	}
	if (ps->lefttree != NULL)
		pgqp_rewrap_planstate(ps->lefttree);
	if (ps->righttree != NULL)
		pgqp_rewrap_planstate(ps->righttree);

	switch (nodeTag(plan))
	{
		case T_Append:
			{
				AppendState *astate = (AppendState *) ps;
				int			i;

				for (i = 0; i < astate->as_nplans; i++)
					pgqp_rewrap_planstate(astate->appendplans[i]);
			}
			break;
		case T_MergeAppend:
			{
				MergeAppendState *mstate = (MergeAppendState *) ps;
				int			i;

				for (i = 0; i < mstate->ms_nplans; i++)
					pgqp_rewrap_planstate(mstate->mergeplans[i]);
			}
			break;
		case T_SubqueryScan:
			pgqp_rewrap_planstate(((SubqueryScanState *) ps)->subplan);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScanState *) ps)->custom_ps)
				pgqp_rewrap_planstate((PlanState *) lfirst(lc));
			break;
		default:
			break;
	}

	foreach(lc, ps->subPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_rewrap_planstate(sps->planstate);
	}
}

/*
 * Recursively (a) inject NodeInstrumentation where missing and (b) install
 * the tick wrapper.  Mirrors planstate_tree_walker's child set.  Runs once
 * per query, before any node has executed, so overwriting ExecProcNode
 * (still ExecProcNodeFirst, execProcnode.c:391) is safe; ExecProcNodeReal
 * keeps the node's true function.
 *
 * Special case 3: Materialize is
 * a 1:1 buffer whose emitted-row count duplicates its child's, so its frac
 * carries no independent information.  Non-root Materialize nodes are NOT
 * wrapped or instrumented; their self cost is folded into the child
 * subtree in pgqp_walk_node.  The root is always wrapped so root EOF
 * detection (entry->drained) and rows_returned keep working.
 */
static void
pgqp_wrap_planstate(PlanState *ps, bool is_root)
{
	Plan	   *plan = ps->plan;
	ListCell   *lc;

	check_stack_depth();

	if (!is_root && nodeTag(plan) == T_Material)
	{
		/*
		 * Fold into child: wrap the passthrough child and
		 * any subplan subtrees; this node itself is neither instrumented
		 * nor wrapped.
		 */
		foreach(lc, ps->initPlan)
		{
			SubPlanState *sps = lfirst_node(SubPlanState, lc);

			pgqp_wrap_planstate(sps->planstate, false);
		}
		if (ps->lefttree != NULL)
			pgqp_wrap_planstate(ps->lefttree, false);
		foreach(lc, ps->subPlan)
		{
			SubPlanState *sps = lfirst_node(SubPlanState, lc);

			pgqp_wrap_planstate(sps->planstate, false);
		}
		return;
	}

	/*
	 * Inject when missing (normally es_instrument == 0 so all are missing).
	 * Existing instruments (EXPLAIN ANALYZE, auto_explain) are left alone:
	 * the wrapper keeps calling InstrStartNode/InstrStopNode exactly like
	 * core's ExecProcNodeInstr, so their semantics are unaffected.  The
	 * caller switched to es_query_cxt, so injections die with the plan.
	 */
	if (ps->instrument == NULL)
		ps->instrument = PGQP_ALLOC_NODE_INSTR(ps);

	/*
	 * Select the wrapper once, by the instrument's immutable option flags
	 * (see the pgqp_tick_rows comment): counting-only instruments take the
	 * light wrapper, real-instrumented nodes (EXPLAIN ANALYZE, auto_explain)
	 * take the full core-equivalent sequence.
	 */
	pgqp_install_wrapper(ps);

	/* recurse: same child set as pgqp_walk_children */
	foreach(lc, ps->initPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_wrap_planstate(sps->planstate, false);
	}
	if (ps->lefttree != NULL)
		pgqp_wrap_planstate(ps->lefttree, false);
	if (ps->righttree != NULL)
		pgqp_wrap_planstate(ps->righttree, false);

	switch (nodeTag(plan))
	{
		case T_Append:
			{
				AppendState *astate = (AppendState *) ps;
				int			i;

				for (i = 0; i < astate->as_nplans; i++)
					pgqp_wrap_planstate(astate->appendplans[i], false);
			}
			break;
		case T_MergeAppend:
			{
				MergeAppendState *mstate = (MergeAppendState *) ps;
				int			i;

				for (i = 0; i < mstate->ms_nplans; i++)
					pgqp_wrap_planstate(mstate->mergeplans[i], false);
			}
			break;
		case T_SubqueryScan:
			pgqp_wrap_planstate(((SubqueryScanState *) ps)->subplan, false);
			break;
		case T_CustomScan:
			foreach(lc, ((CustomScanState *) ps)->custom_ps)
				pgqp_wrap_planstate((PlanState *) lfirst(lc), false);
			break;
		default:
			break;
	}

	foreach(lc, ps->subPlan)
	{
		SubPlanState *sps = lfirst_node(SubPlanState, lc);

		pgqp_wrap_planstate(sps->planstate, false);
	}
}

/*
 * Copy the query text into the slot, truncating at pgqp_max_query_len
 * bytes without splitting a multi-byte character: back off over UTF-8
 * continuation bytes (0b10xxxxxx) so the last character stays whole.
 */
static void
pgqp_store_query_text(PgQPSlot *slot, const char *qtext)
{
	int			len;

	if (qtext == NULL)
		qtext = "";

	len = strlen(qtext);
	if (len > pgqp_max_query_len)
	{
		len = pgqp_max_query_len;
		while (len > 0 && (((unsigned char) qtext[len]) & 0xC0) == 0x80)
			len--;
	}

	memcpy(slot->query, qtext, len);
	slot->query[len] = '\0';
}

/*
 * Claim this backend's slot, publish the initial zero snapshot.
 */
static void
pgqp_begin_track(QueryDesc *queryDesc)
{
	MemoryContext oldctx;
	PgQPEntry  *entry;
	PgQPSlot  *slot = &pgqp_slots[PGQP_MY_PROCNO()];
	TimestampTz start_time = GetCurrentTimestamp();

	/*
	 * Inject instruments and install tick wrappers FIRST: wrap can ERROR
	 * (check_stack_depth on pathological plans), and doing it before the
	 * entry allocation keeps the TopMemoryContext entry from leaking on
	 * that path -- pgqp_entry is still NULL, so the abort callbacks would
	 * have nothing to free.  Instruments must live
	 * in es_query_cxt: they are freed by standard_ExecutorEnd ->
	 * FreeExecutorState together with the plan.
	 */
	oldctx = MemoryContextSwitchTo(queryDesc->estate->es_query_cxt);
	pgqp_wrap_planstate(queryDesc->planstate, true);
	MemoryContextSwitchTo(oldctx);

	if (pgqp_ctx == NULL)
		pgqp_ctx = AllocSetContextCreate(TopMemoryContext,
										 "pg_query_progress",
										 ALLOCSET_DEFAULT_SIZES);

	entry = (PgQPEntry *) MemoryContextAlloc(pgqp_ctx, sizeof(PgQPEntry));
	entry->queryDesc = queryDesc;
	entry->root_state = queryDesc->planstate;
	entry->slot = slot;
	entry->slot_seq = 0;		/* set under the spinlock below */
	entry->last_progress = 0.0;
	entry->drained = false;
	entry->tick_countdown = PGQP_TICKS_PER_CHECK;
	entry->ticks_since_publish = 0;
	entry->last_publish_time = start_time;
	/* v2 bar: MemoryContextAlloc does not zero -- initialize explicitly
	 * !valid makes the first 16-tick branch retry
	 * at every checkpoint until the v3 gate admits the first frame
	 * ("switch on, see the bar" once the query is gate_ms old). */
	entry->bar_last_emit = start_time;
	entry->bar_last_emit_valid = false;
	entry->bar_ansi_started = false;
	/* GUC snapshot for the D-hat formula: written here, read by the walk */
	entry->leader_participation = PGQP_LEADER_PARTICIPATION();

	SpinLockAcquire(&slot->mutex);
	slot->procnumber = PGQP_MY_PROCNO();
	slot->pid = MyProcPid;
	slot->dbid = MyDatabaseId;
	slot->state = PGQP_RUNNING;
	slot->parallel = queryDesc->plannedstmt->parallelModeNeeded;
	pgqp_store_query_text(slot, queryDesc->sourceText);
	slot->progress = 0.0;
	slot->total_cost = 0.0;
	slot->completed_cost = 0.0;
	slot->plan_rows = queryDesc->planstate->plan->plan_rows;
	slot->rows_returned = 0.0;
	slot->tuples_processed = 0;
	slot->query_id = queryDesc->plannedstmt->queryId;
	slot->nodes_total = 0;
	slot->nodes_done = 0;
	slot->seq++;
	entry->slot_seq = slot->seq;	/* v3: merge key for worker counts */
	slot->query_start = start_time;
	slot->last_update = start_time;
	SpinLockRelease(&slot->mutex);

	pgqp_entry = entry;

	/* forced publish #1: zero snapshot so monitors see the query at once */
	pgqp_publish(entry, false);

	/*
	 * Process-exit fallback for terminal states outliving the session.
	 * Register once per backend.
	 */
	if (!pgqp_exit_registered)
	{
		before_shmem_exit(pgqp_backend_cleanup, (Datum) 0);
		pgqp_exit_registered = true;
	}
}

/*
 * Free the backend-private entry and clear pgqp_entry.
 * Never touches the slot or planstate.
 */
static void
pgqp_detach_entry(PgQPEntry *entry)
{
	Assert(entry == pgqp_entry);
	pgqp_entry = NULL;
	pfree(entry);
}

/*
 * ExecutorRun hook: nesting guard (pg_stat_statements.c:1016-1031 pattern)
 * plus a forced publish when a run-to-completion call has drained the plan.
 */
static void
pgqp_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
{
	PgQPEntry  *entry = pgqp_entry;
	bool		track = (entry != NULL && entry->queryDesc == queryDesc);

	/*
	 * v3.1: in a worker, ExecParallelInitializeWorker ran
	 * between our ExecutorStart wrap and this Run call and may have reset
	 * ExecProcNode on PHJ nodes; re-install our wrappers before the first
	 * tuple flows.  One tree walk (~microseconds) per worker Run.
	 */
	if (pgqp_worker != NULL && pgqp_worker->queryDesc == queryDesc)
		pgqp_rewrap_planstate(pgqp_worker->root_state);

	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count);
		else
			standard_ExecutorRun(queryDesc, direction, count);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();

	/*
	 * Forced publish #2: count == 0 means "no portal limit", i.e. run to
	 * completion; if the root signaled EOF the query is finished even when
	 * a later hashjoin DSM re-init dropped the root's tick wrapper
	 * (nodeHashjoin.c:1863; trap).
	 */
	if (track && entry->drained &&
		direction == ForwardScanDirection && count == 0)
		pgqp_publish(entry, true);
}

/*
 * ExecutorFinish hook: normal end of a portal run.  Drained -> COMPLETED
 * with progress forced to 1.0; otherwise (cursor closed before EOF, the
 * PORTAL_READY path in portalcmds.c:300-310) -> TERMINATED, progress kept.
 *
 * v3: in a parallel worker this is the first of the two final-publish
 * points (workers finish before the leader's Finish, so the leader's
 * terminal merge still sees the workers' last counters).
 */
static void
pgqp_ExecutorFinish(QueryDesc *queryDesc)
{
	PgQPEntry  *entry = pgqp_entry;
	bool		track = (entry != NULL && entry->queryDesc == queryDesc);
	PgQPWorker *worker = pgqp_worker;
	bool		wtrack = (worker != NULL && worker->queryDesc == queryDesc);

	nesting_level++;
	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_FINALLY();
	{
		nesting_level--;
	}
	PG_END_TRY();

	if (wtrack)
	{
		pgqp_worker_publish(worker);	/* best-effort final publish */
		return;
	}

	if (!track)
		return;

	if (entry->drained)
	{
		pgqp_publish(entry, true);
		pgqp_set_slot_state(entry, PGQP_COMPLETED);
		if (pgqp_bar)
			pgqp_bar_terminal(entry, "done");
	}
	else
	{
		pgqp_publish(entry, false);
		pgqp_set_slot_state(entry, PGQP_TERMINATED);
		if (pgqp_bar)
			pgqp_bar_terminal(entry, "terminated");
	}
}

/*
 * ExecutorEnd hook: publish the terminal snapshot and detach *before*
 * chaining to prev/standard, because standard_ExecutorEnd frees the
 * planstate (and with it the injected instruments).
 *
 * v3: same order for the worker path -- final publish, then detach; the
 * wtab entry itself stays (passive generational data).
 */
static void
pgqp_ExecutorEnd(QueryDesc *queryDesc)
{
	PgQPEntry  *entry = pgqp_entry;
	bool		track = (entry != NULL && entry->queryDesc == queryDesc);
	PgQPWorker *worker = pgqp_worker;
	bool		wtrack = (worker != NULL && worker->queryDesc == queryDesc);

	if (wtrack)
	{
		pgqp_worker_publish(worker);	/* best-effort final publish */
		pgqp_worker_detach(worker);
	}

	if (track)
	{
		/*
		 * If Finish already ran, it set COMPLETED/TERMINATED and
		 * pgqp_publish's monotonic clamp keeps progress at 1.0 (or the
		 * terminal value); this last publish only refreshes the counters.
		 * If Finish never ran (defensive: not the normal error path, which
		 * is covered by the xact callbacks), record FAILED conservatively
		 * (End without Finish conservatively records FAILED).
		 */
		bool		finished;

		SpinLockAcquire(&entry->slot->mutex);
		finished = (entry->slot->state == PGQP_COMPLETED ||
					entry->slot->state == PGQP_TERMINATED);
		SpinLockRelease(&entry->slot->mutex);

		pgqp_publish(entry, entry->drained);
		if (!finished)
			pgqp_set_slot_state(entry,
								entry->drained ? PGQP_COMPLETED : PGQP_FAILED);
		pgqp_detach_entry(entry);
	}

	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
}

/*
 * --------------------------------------------------------------------
 * Error-path fallbacks
 * --------------------------------------------------------------------
 */

/*
 * Shared abort cleanup for XACT_EVENT_ABORT and SUBXACT_EVENT_ABORT_SUB.
 * Only slot scalars are written: the planstate/instrument memory is still
 * alive at this point (ResourceOwnerRelease runs later, xact.c:3017), but
 * we must not depend on that ordering, so no tree walk happens here.
 */
static void
pgqp_abort_cleanup(void)
{
	PgQPEntry  *entry = pgqp_entry;

	if (entry == NULL)
		return;

	pgqp_set_slot_state(entry, PGQP_FAILED);
	pgqp_detach_entry(entry);
}

static void
pgqp_xact_callback(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_ABORT)
		pgqp_abort_cleanup();
}

static void
pgqp_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
					  SubTransactionId parentSubid, void *arg)
{
	if (event == SUBXACT_EVENT_ABORT_SUB)
		pgqp_abort_cleanup();
}

/*
 * before_shmem_exit callback: clear the slot owned by this process so
 * terminal rows do not outlive the session.  Runs in every backend kind;
 * harmless where nothing was tracked.
 */
static void
pgqp_backend_cleanup(int code, Datum arg)
{
	int			idx = PGQP_MY_PROCNO();

	if (pgqp == NULL || pgqp_slots == NULL)
		return;
	if (idx < 0 || idx >= pgqp->nslots)
		return;

	SpinLockAcquire(&pgqp_slots[idx].mutex);
	if (pgqp_slots[idx].procnumber == idx)
	{
		pgqp_slots[idx].procnumber = -1;
		pgqp_slots[idx].state = PGQP_IDLE;
		pgqp_slots[idx].last_update = GetCurrentTimestamp();
	}
	SpinLockRelease(&pgqp_slots[idx].mutex);
}

/*
 * --------------------------------------------------------------------
 * SRF: pg_query_progress()
 * --------------------------------------------------------------------
 */

/*
 * Materialize-mode SRF: snapshot every non-IDLE slot
 * under its spinlock into a tuplestore.  When the library was not preloaded
 * (no shmem), return an empty set and emit one WARNING per session.
 */
Datum
pg_query_progress_srf(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	Tuplestorestate *tupstore;
	TupleDesc	tupdesc;
	int			i;

	/* safety valve */
	if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("set-valued function called in context that cannot accept a set")));
	if (!(rsinfo->allowedModes & SFRM_Materialize))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("materialize mode required, but it is not allowed in this context")));

	InitMaterializedSRF(fcinfo, 0);
	tupstore = rsinfo->setResult;
	tupdesc = rsinfo->setDesc;

	if (pgqp == NULL)
	{
		if (!pgqp_srf_warned)
		{
			pgqp_srf_warned = true;
			ereport(WARNING,
					(errmsg("pg_query_progress must be loaded via shared_preload_libraries"),
					 errdetail("Returning an empty result set.")));
		}
		PG_RETURN_NULL();
	}

	/* layout version cross-check; v3: the magic check extends
	 * to the worker table */
	if (pgqp->magic != PGQP_MAGIC ||
		pgqp_wtab == NULL || pgqp_wtab->magic != PGQP_MAGIC)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("pg_query_progress shared memory has an incompatible layout version"),
				 errhint("Restart the server after rebuilding or changing pg_query_progress.")));

	for (i = 0; i < pgqp->nslots; i++)
	{
		PgQPSlot  *slot = &pgqp_slots[i];

		/* snapshot under the per-slot spinlock */
		pid_t		pid;
		int			state;
		bool		parallel;
		char		query[PGQP_TRUNAME + 1];
		double		progress;
		double		total_cost;
		double		completed_cost;
		double		plan_rows;
		double		rows_returned;
		int64		tuples_processed;
		int64		query_id;
		int			nodes_total;
		int			nodes_done;
		TimestampTz query_start;
		TimestampTz last_update;

		SpinLockAcquire(&slot->mutex);
		if (slot->procnumber == -1 || slot->state == PGQP_IDLE ||
			(slot->procnumber == PGQP_MY_PROCNO() &&
			 slot->state == PGQP_RUNNING))
		{
			/*
			 * Skip free slots and -- unless terminal -- our own slot: the
			 * calling statement itself publishes a zero RUNNING snapshot at
			 * its ExecutorStart, and returning it would make every view
			 * poll show a phantom 0% running row.
			 * Own terminal rows (last completed/failed query) stay visible.
			 */
			SpinLockRelease(&slot->mutex);
			continue;
		}
		pid = slot->pid;
		state = slot->state;
		parallel = slot->parallel;
		memcpy(query, slot->query, sizeof(query));
		progress = slot->progress;
		total_cost = slot->total_cost;
		completed_cost = slot->completed_cost;
		plan_rows = slot->plan_rows;
		rows_returned = slot->rows_returned;
		tuples_processed = slot->tuples_processed;
		query_id = slot->query_id;
		nodes_total = slot->nodes_total;
		nodes_done = slot->nodes_done;
		query_start = slot->query_start;
		last_update = slot->last_update;
		SpinLockRelease(&slot->mutex);

		{
			Datum		values[16];
			bool		nulls[16];
			const char *state_name;
			long		age_secs;
			int			age_micros;

			/* age_ms = clock_timestamp() - query_start, in milliseconds */
			TimestampDifference(query_start, GetCurrentTimestamp(),
								&age_secs, &age_micros);

			MemSet(nulls, 0, sizeof(nulls));

			state_name = (state >= PGQP_RUNNING && state <= PGQP_TERMINATED) ?
				pgqp_state_names[state] : "unknown";

			values[0] = Int32GetDatum(pid);
			values[1] = PointerGetDatum(cstring_to_text(query));
			values[2] = PointerGetDatum(cstring_to_text(state_name));
			values[3] = Float8GetDatum(progress);
			values[4] = Float8GetDatum(total_cost);
			values[5] = Float8GetDatum(completed_cost);
			values[6] = Float8GetDatum(plan_rows);
			values[7] = Int64GetDatum((int64) rows_returned);
			values[8] = Int64GetDatum(tuples_processed);
			values[9] = Int32GetDatum(nodes_total);
			values[10] = Int32GetDatum(nodes_done);
			values[11] = BoolGetDatum(parallel);
			values[12] = Int64GetDatum(query_id);
			values[13] = TimestampTzGetDatum(query_start);
			values[14] = TimestampTzGetDatum(last_update);
			values[15] = Float8GetDatum(age_secs * 1000.0 + age_micros / 1000.0);

			tuplestore_putvalues(tupstore, tupdesc, values, nulls);
		}
	}

	/* clean up and return the tuplestore */
	PG_RETURN_NULL();
}
