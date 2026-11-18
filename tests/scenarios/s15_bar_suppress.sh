#!/usr/bin/env bash
# s15: suppression short-circuit.  bar=on + client_min_messages=warning:
# zero frames in stderr (message_level_is_interesting short-circuits the
# server path before any formatting), query completes normally.
source "$(dirname "$BASH_SOURCE")/../common.sh"

Q="SELECT count(*), sum(x + 1) FROM big_table"
OUT="$WORKDIR/s15.out"; ERR="$WORKDIR/s15.err"

psql -X -At -c "SET pg_query_progress.bar=on" \
             -c "SET client_min_messages=warning" \
             -c "SET max_parallel_workers_per_gather=0" \
             -c "$Q" > "$OUT" 2> "$ERR"
check "query completes under suppression" $?

FRAMES=$(bar_count "$ERR")
BYTES=$(wc -c < "$ERR")
[ "$FRAMES" = "0" ]; check "zero NOTICE frames in stderr" $? "frames=$FRAMES bytes=$BYTES"

RES=$(cat "$OUT")
[ -n "$RES" ]; check "result row still produced on stdout" $? "$RES"

finish_scenario
