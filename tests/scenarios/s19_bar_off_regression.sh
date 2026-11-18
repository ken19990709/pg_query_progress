#!/usr/bin/env bash
# s19: bar=off zero regression.  With the bar at its default (off), re-run
# the robustness scenarios and require identical outcomes.  (The internal
# predecessor chained the full s01-s12 set; the public subset chains what
# is in this repository.)
source "$(dirname "$BASH_SOURCE")/../common.sh"

IDS="${PGQP_S19_IDS:-1 2 3 4 5 6 8 10 12}"
RC=0
for id in $IDS; do
  script=$(printf "%s/s%02d_*.sh" "$SCENARIO_DIR" "$id")
  script=$(echo $script | awk '{print $1}')
  if [ ! -f "$script" ]; then echo "  scenario $id: no script"; continue; fi
  echo "--- s19 chain: $(basename "$script")"
  bash "$script" | tee "$WORKDIR/s19_$(basename "$script" .sh).log" || RC=1
done

# zero-adaptation evidence: no robustness scenario script references the
# bar GUCs (they run unchanged with the bar on or off)
ADAPTED=$(grep -l "pg_query_progress.bar" "$SCENARIO_DIR"/s[0-1][0-9]_*.sh 2>/dev/null \
          | grep -Ev 's1[3-5]|s19' || true)
[ -z "$ADAPTED" ]; check "no robustness script references bar GUCs (zero adaptation)" $? "${ADAPTED:-clean}"

[ "$RC" = "0" ]; check "robustness scenarios all pass with bar default-off" $?
finish_scenario
