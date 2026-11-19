#!/usr/bin/env bash
# tests/smoke.sh -- build, bootstrap a throwaway instance, run the smoke
# matrix, tear everything down.
#
# Usage:
#   tests/smoke.sh [group|scenario ...]      (default: the full matrix
#                                             suitable for this branch)
#
# Groups:
#   S  bar frame gate semantics      (s13, s21)
#   D  DML progress                  (s29-s37: INSERT forms, ON CONFLICT,
#                                     UPDATE/DELETE forms, MERGE, partition
#                                     + trigger, stress, bar-default arm)
#   R  robustness core               (s01 s02 s04 s05 s07 s12)
#   P  parallel visibility           (s22, plus s26 on the main branch)
#   M  shared-memory layout          (s18)
#   L  GUC off arm, stable branches  (s27)
#   I  worker index instrumentation  (s26, main branch only)
#   X  everything else shipped       (s03 s06 s08 s10 s14 s15 s19 s23)
#
# A scenario may also be named directly (e.g. tests/smoke.sh s18).
#
# Environment: see tests/bootstrap.sh (PG_CONFIG, PGQP_SCALE,
# PGQP_TOLERANCE, ...).  The instance is torn down on exit.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS_DIR/.."

GROUP_S="s13_bar_basic.sh s21_silence.sh"
GROUP_D="s29_dml_insert_values.sh s30_dml_insert_select.sh s31_dml_on_conflict.sh s32_dml_update_forms.sh s33_dml_delete_forms.sh s34_dml_merge.sh s35_dml_partition_trigger.sh s36_dml_stress.sh s37_bar_ansi_default.sh"
GROUP_R="s01_cancel.sh s02_error.sh s04_cursor.sh s05_srf.sh s07_auto_explain.sh s12_nonpreload.sh s28_pgss_coload.sh"
GROUP_P="s22_parallel_visibility.sh"
GROUP_M="s18_memory.sh"
GROUP_L="s27_plp_off.sh"
GROUP_I="s26_sd2_verify.sh"
GROUP_X="s03_prepared.sh s06_limit.sh s08_parallel.sh s10_capacity.sh s14_bar_interval.sh s15_bar_suppress.sh s19_bar_off_regression.sh s23_operator_matrix.sh"

# main-branch matrix: no GUC off arm; SD-2 folds into P
GROUP_P_MAIN="s22_parallel_visibility.sh s26_sd2_verify.sh"

args="${*:-}"
if [ -z "$args" ]; then
  args="S D R P M"
  # GUC off arm exists only where the GUC exists (PG <= 18 branches)
  if [ -f "$TESTS_DIR/scenarios/s27_plp_off.sh" ]; then
    args="$args L"
  fi
fi

SCENARIOS=""
for a in $args; do
  case "$a" in
    S) SCENARIOS="$SCENARIOS $GROUP_S" ;;
    D) SCENARIOS="$SCENARIOS $GROUP_D" ;;
    R) SCENARIOS="$SCENARIOS $GROUP_R" ;;
    P) if [ -f "$TESTS_DIR/scenarios/s27_plp_off.sh" ]; then
         SCENARIOS="$SCENARIOS $GROUP_P"
       else
         SCENARIOS="$SCENARIOS $GROUP_P_MAIN"
       fi ;;
    M) SCENARIOS="$SCENARIOS $GROUP_M" ;;
    L) SCENARIOS="$SCENARIOS $GROUP_L" ;;
    I) SCENARIOS="$SCENARIOS $GROUP_I" ;;
    X) SCENARIOS="$SCENARIOS $GROUP_X" ;;
    s[0-9]*) SCENARIOS="$SCENARIOS $(cd "$TESTS_DIR/scenarios" && echo ${a}*) " ;;
    *) echo "smoke: unknown group or scenario: $a" >&2; exit 2 ;;
  esac
done

bash "$TESTS_DIR/bootstrap.sh" || exit 2
trap 'bash "$TESTS_DIR/bootstrap.sh" --down' EXIT
export PGQP_ENV="$TESTS_DIR/.pgqp_env.sh"

FAILED=("")
TOTAL_PASS=0; TOTAL_FAIL=0
for s in $SCENARIOS; do
  s="${s%.sh}"
  script="$TESTS_DIR/scenarios/$s.sh"
  [ -f "$script" ] || { echo "smoke: no scenario $s"; continue; }
  echo
  echo "==== $s =========================================================="
  if bash "$script"; then
    :
  else
    FAILED+=("$s")
  fi
done

echo
echo "==== summary ==========================================================="
if [ "${#FAILED[@]}" -gt 1 ]; then
  echo "FAILED scenarios: ${FAILED[*]:1}"
  exit 1
fi
echo "all requested scenarios passed"
exit 0
