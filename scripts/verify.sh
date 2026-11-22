#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for the record of a verification (lib/records.sh).
records_arguments=("$@")

# Stable verification entry point for humans, agents, and CI.
# The required checks of the project are declared in scripts/verify.conf.
# The self-tests of the workflow scripts are declared in
# scripts/verify-workflow.conf and run only when a workflow file changed,
# or always with --all. Changed means: since the last trusted pass of the
# run of a workflow script (the last tree in VERIFY_TRUSTED_TREES,
# lib/verification.sh), when there is one; otherwise since the base branch.
#
# --changed is the targeted check of an agent session: every check of
# scripts/verify.conf, and of the self-tests only those of the files that
# changed since the base: the check that runs tests/<x>-test.sh when that
# file, scripts/<x>.sh, or scripts/lib/<x>.sh changed, or when a changed file
# of scripts/lib/ that is not a shell script (a jq program, for one) is named
# by scripts/<x>.sh or scripts/lib/<x>.sh as 'lib/<name>'. Like --only it is a
# partial run, never a verification: it records nothing. The full
# verification runs after the session (run-feature.sh).
#
# A run in which every check passed is recorded for the content it verified
# (scripts/lib/verification.sh). With --reuse, a second run on identical
# content is skipped.
#
# A check may name a group: '<name> [<group>]: <command>'. A check without one
# belongs to the group 'default'. --only runs the checks of the named groups,
# for a CI that spreads the same checks over parallel jobs. Such a partial
# run is never a verification: it records nothing.
#
# A check that runs one part of a split test suite declares that part, a file
# that lists its tests: '<name> [<group>] partition <file>: <command>'.
# verify.sh only lists the declarations (--partitions); scripts/check-ci-groups.sh
# checks them against the partition files. A budget check declares none.
#
# A check may be a budget: '<name> [<group>] budget: <command>'. It measures
# something (a duration, a size, a count) against a target and exits non-zero
# over it. Such a result is a measurement, not a failure: the summary shows it
# as BUDGET with the output of the check, and the verification passes when
# every other check passed. The budget results are recorded with the pass
# (lib/verification.sh) and in the run record, so that the scripts show them
# where a decision is made; nothing repairs them. A budget check that does not
# finish (a signal, or the status 124 of 'timeout') or could not run (125 to
# 127, the statuses of 'timeout' and the shell for a command that was not
# invoked) is a FAIL like any check.
#
# Every check is timed. The durations are recorded with the pass and in the
# run record (lib/verification.sh). Each of the two files may declare one
# 'budget-seconds: <n>': the target for the duration of all of its checks
# in one run. A run over it shows BUDGET with the total, the target, and the
# slowest checks, recorded as a budget result like that of a budget check;
# it fails nothing. A partial run (--only) and a file whose checks did not
# run compare with nothing.
#
# Each of the two files may declare one 'heavy: <check>...': checks of that
# file that need the machine to themselves. A run that is going to start one
# takes the machine-wide slot for heavy verification first
# (scripts/lib/verify-lock.sh), shared by every session and worktree of the
# machine, and holds it until it ends. When another run holds it, the run
# reports the holder, starts no check, records nothing, and exits with status
# 75: the machine is busy, which says nothing about the code. A run without a
# heavy check, such as --only of the light groups, takes no slot. Without a
# 'heavy:' line nothing is locked.
#
# scripts/verify.conf may declare one 'parallel: <n>': up to <n> checks of the
# run, over the checks of both files, run at the same time, each in a process
# group of its own with /dev/null as its standard input. They start in the
# order of the files; the output of each is kept apart and printed as one
# block when it ends, and the summary, the durations, the exit status, and the
# record are those of a run of the same checks one at a time. A run that holds
# the slot for heavy verification records the group of every check that runs.
# VERIFY_PARALLEL=<n> overrides the line for one run; a check does not inherit
# it. Without either, the checks run one at a time.
#
# A project that adopted the workflow records how its checks ended before any
# change: './scripts/verify.sh --baseline', started by the owner once, runs
# the checks of scripts/verify.conf and writes the result of each to
# .agents/verification-baseline (passed, failed, or unavailable). It is
# never a verification: it records no pass, and it exits non-zero when a
# check failed. Afterwards a check that failed in the baseline and still fails
# is shown as KNOWN, a pre-existing failure, apart from a regression (FAIL of
# a check that passed in the baseline); either fails the verification. Only
# the owner's 'accepted-failure: <check> <reason>' in scripts/verify.conf
# turns the failure of a check into ACCEPTED, which does not fail it.
#
# An exception can be scoped instead, for a check that runs per file or per
# test, so that a check which already fails does not hide a new failure:
# - 'accepted-failure: <check> changed-files exit <statuses> <command>': when
#   the check fails, <command> runs on the files changed since the feature's
#   base (lib/base.sh: committed, staged, unstaged, and untracked), and those
#   must pass.
# - 'accepted-failure: <check> recorded exit <statuses>': the check prints its
#   failures on standard output, one per line, and they are compared with the list
#   .agents/accepted-failures/<check>. A failure that is not in the list, or
#   that names a file changed since the base, fails; a listed failure that
#   no longer occurs is reported, so that the list shrinks. The list may only
#   shrink: an entry that its version at the base does not hold fails.
# <statuses> are the exit statuses, separated by commas, with which the check
# completed and reports failures, such as 'exit 1' for prettier; there is no
# default. Either applies only to a check that ended with one of them: one
# that ended with another status (a problem of the tool itself, such as 2 of
# prettier), could not run, was killed by a signal, or timed out fails, and
# what it printed reports nothing as FIXED.
# Either shows the failure as SCOPED, which does not fail the verification.
# The list is protected by the merge approval gate like the baseline.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
config="$root/scripts/verify.conf"
workflow_config="$root/scripts/verify-workflow.conf"
baseline_relative=".agents/verification-baseline"
baseline_file="$root/$baseline_relative"
accepted_lists_relative=".agents/accepted-failures"

comment_pattern='^[[:space:]]*(#.*)?$'
check_pattern='^([a-z0-9][a-z0-9-]*)([[:space:]]*\[([a-z0-9][a-z0-9-]*)\])?([[:space:]]+partition[[:space:]]+([^[:space:]:]+))?([[:space:]]+budget)?:[[:space:]]*(.*[^[:space:]])[[:space:]]*$'
default_group="default"

usage() {
  echo "Usage: $0 [--all] [--reuse]"
  echo "       $0 [--all] --only <group>[,<group>...]"
  echo "       $0 --changed"
  echo "       $0 --baseline"
  echo "       $0 --groups"
  echo "       $0 --partitions"
  echo
  echo "Runs the checks in scripts/verify.conf. The workflow self-tests in"
  echo "scripts/verify-workflow.conf run only when a file listed under 'paths:' in"
  echo "that file differs from the base branch. --all runs them regardless. Within a"
  echo "run of a workflow script that keeps trusted passes (VERIFY_TRUSTED_TREES), they"
  echo "are compared with the tree of its last trusted pass instead of the base branch."
  echo
  echo "--changed runs every check of scripts/verify.conf and, of the self-tests, only"
  echo "those of the files changed since the base branch: the check that runs"
  echo "tests/<x>-test.sh when that file, scripts/<x>.sh, or scripts/lib/<x>.sh changed,"
  echo "or when a changed file of scripts/lib/ that is not a shell script is named by"
  echo "scripts/<x>.sh or scripts/lib/<x>.sh as 'lib/<name>'."
  echo "It is the targeted check of an agent session: a partial run, which records"
  echo "nothing; the full verification runs after the session."
  echo
  echo "--reuse skips the run when verification already passed for exactly the"
  echo "current content, as recorded by an earlier run."
  echo
  echo "--only runs the checks of the named groups only. A check names its group"
  echo "as '<name> [<group>]: <command>'; one without a group is in 'default'."
  echo "A partial run records nothing and cannot be combined with --reuse: only"
  echo "a run of every check verifies the content."
  echo
  echo "--groups prints the groups that have a check, one per line."
  echo
  echo "A check declared as '<name> [<group>] partition <file>: <command>' runs the tests"
  echo "that <file> lists. --partitions prints '<file> <name>' for each such check."
  echo
  echo "A check declared as '<name> [<group>] budget: <command>' is a budget: when it"
  echo "exits non-zero, the summary shows BUDGET with its output, and the verification"
  echo "passes when every other check passed. A budget check that does not finish or"
  echo "cannot run (exit 124 to 127, or a signal) fails: nothing was measured."
  echo
  echo "A line 'budget-seconds: <n>' in either file is the target for the duration of"
  echo "all checks of that file in one run. Over it, the summary shows BUDGET with the"
  echo "total, the target, and the five slowest checks; the verification still passes"
  echo "when every check passed. A partial run compares with nothing."
  echo
  echo "A line 'heavy: <check>...' in either file names checks that need the machine to"
  echo "themselves. A run that starts one first takes the machine-wide slot for heavy"
  echo "verification (\$VERIFY_LOCK_DIR, by default /tmp/agentic-verify-<uid>). When"
  echo "another run holds it, the summary shows BUSY with that run, no check runs,"
  echo "nothing is recorded, and the exit status is 75. Without the line nothing locks."
  echo
  echo "A line 'parallel: <n>' in scripts/verify.conf runs up to <n> checks of both files"
  echo "at a time; the output of each check follows as one block when it ends, and the"
  echo "result is that of a run one at a time. VERIFY_PARALLEL=<n> overrides it for one"
  echo "run. Without either, the checks run one at a time."
  echo
  echo "--baseline runs the checks of scripts/verify.conf once, before any change of an"
  echo "adopted project, and records how each ended in $baseline_relative:"
  echo "passed, failed, or unavailable. It is not a verification and records no pass;"
  echo "it exits 1 when a check failed. Later runs show a check that failed in the"
  echo "baseline and still fails as KNOWN, a pre-existing failure that still fails the"
  echo "verification, and one that passed in the baseline and fails now as a"
  echo "regression. A line 'accepted-failure: <check> <reason>' in scripts/verify.conf,"
  echo "the owner's exception, shows a failure of that check as ACCEPTED instead, and"
  echo "the verification does not fail for it."
  echo
  echo "A scoped exception accepts only the failures that predate the change:"
  echo "'accepted-failure: <check> changed-files exit <statuses> <command>' runs <command>"
  echo "on the files changed since the feature's base when the check fails, and those"
  echo "must pass; 'accepted-failure: <check> recorded exit <statuses>' compares the"
  echo "failures the check prints, one per line, with the list $accepted_lists_relative/<check>:"
  echo "a new one, or one of a changed file, fails. Within its scope the failure is shown"
  echo "as SCOPED, and a recorded failure that no longer occurs is reported as FIXED. The"
  echo "list may only shrink: an entry it did not hold at the feature's base fails."
  echo "<statuses> are the exit statuses, separated by commas, with which the check"
  echo "completed with failures, such as 'exit 1' for prettier; there is no default."
  echo "Either applies only to a check that ended with one of them: any other status, a"
  echo "check that could not run, was killed by a signal, or timed out fails, and reports"
  echo "nothing FIXED."
  exit 1
}

config_fail() {
  echo "Error: $*" >&2
  echo "Declare required checks as '<name>: <command>', '<name> [<group>]: <command>', '<name> [<group>] partition <file>: <command>', or '<name> [<group>] budget: <command>', a target for their duration as 'budget-seconds: <n>', the number of checks at a time as 'parallel: <n>' (scripts/verify.conf only), and the checks that need the machine to themselves as 'heavy: <check>...'." >&2
  exit 1
}

run_all=0
reuse=0
list_groups=0
list_partitions=0
only=""
partial=0
changed_mode=0
baseline_mode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) run_all=1 ;;
    --baseline) baseline_mode=1 ;;
    --reuse) reuse=1 ;;
    --groups) list_groups=1 ;;
    --partitions)
      list_groups=1
      list_partitions=1
      ;;
    --changed)
      changed_mode=1
      partial=1
      ;;
    --only)
      [[ $# -ge 2 && "$2" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] || usage
      only="$2"
      partial=1
      shift
      ;;
    *) usage ;;
  esac
  shift
done
if [[ "$changed_mode" -eq 1 && ( -n "$only" || "$run_all" -eq 1 ) ]]; then
  echo "Error: --changed selects the checks itself; it takes neither --only nor --all." >&2
  exit 1
fi
if [[ "$partial" -eq 1 && "$reuse" -eq 1 ]]; then
  echo "Error: --only and --changed cannot be combined with --reuse: a partial run is not a verification, so there is nothing to reuse." >&2
  exit 1
fi
if [[ "$list_groups" -eq 1 && ( "$partial" -eq 1 || "$reuse" -eq 1 || "$run_all" -eq 1 ) ]]; then
  usage
fi
if [[ "$baseline_mode" -eq 1 && ( "$partial" -eq 1 || "$reuse" -eq 1 || "$run_all" -eq 1 || "$list_groups" -eq 1 ) ]]; then
  echo "Error: --baseline runs every check of scripts/verify.conf on its own; it takes no other option." >&2
  exit 1
fi

# The verification is recorded (lib/records.sh): its duration, its status,
# and whether a recorded pass was reused. A partial run (--only) and a
# baseline (--baseline) are not verifications and are not recorded, also not
# into a run they were started in. Inside
# a run of the workflow it belongs to that run; run on its own in a feature or
# a planning worktree it is a run of that feature or planning. It runs as a
# child, so that every exit below is seen. Recording is best-effort: when it
# cannot be prepared, the verification runs without it.
if [[ -z "${RECORDS_VERIFICATION:-}" && -z "${RECORDS_DISABLED:-}" && "$list_groups" -eq 0 && "$partial" -eq 0 && "$baseline_mode" -eq 0 ]] &&
  [[ -f "$root/scripts/lib/records.sh" ]] && command -v jq >/dev/null 2>&1; then
  source "$root/scripts/lib/records.sh"
  if [[ -z "${RECORDS_RUN_ID:-}" ]]; then
    records_branch="$(git -C "$root" branch --show-current 2>/dev/null || true)"
    case "$records_branch" in
      feature/*) records_wrap feature "$(records_branch_issue)" "$0" ${records_arguments[@]+"${records_arguments[@]}"} ;;
      planning/*) records_wrap planning "${records_branch#planning/}" "$0" ${records_arguments[@]+"${records_arguments[@]}"} ;;
    esac
  fi
  records_mark=""
  if [[ -n "${RECORDS_RUN_ID:-}" ]] && ! records_mark="$(mktemp "${TMPDIR:-/tmp}/verify-reused.XXXXXX" 2>/dev/null)"; then
    records_mark=""
    echo "Warning: the record of this verification could not be prepared (no temporary file); the verification runs without it." >&2
  fi
  if [[ -n "$records_mark" ]]; then
    rm -f "$records_mark" 2>/dev/null || true
    records_started="$(date +%s)"
    records_call="$(records_id)"
    records_verification_start "$records_call" all
    records_status=0
    RECORDS_VERIFICATION="$records_mark" "$0" ${records_arguments[@]+"${records_arguments[@]}"} || records_status=$?
    records_reused=false
    [[ ! -e "$records_mark" ]] || records_reused=true
    # Whether the pass counts as evidence under the trust contract
    # (lib/verification.sh): one that a workflow script ran itself, or a
    # reused one whose tree is in VERIFY_TRUSTED_TREES; never one of an agent
    # session, of a run at a terminal, or a reuse without the list.
    records_origin=manual
    records_trusted=false
    if [[ -f "$root/scripts/lib/verification.sh" ]]; then
      source "$root/scripts/lib/verification.sh"
      ! declare -F verification_origin >/dev/null || records_origin="$(verification_origin)"
    fi
    if [[ "$records_status" -eq 0 && "$records_origin" != "agent-session" ]]; then
      if [[ "$records_reused" == true ]]; then
        [[ -z "${VERIFY_TRUSTED_TREES+set}" ]] || records_trusted=true
      elif [[ "$records_origin" != "manual" ]]; then
        records_trusted=true
      fi
    fi
    # The budget results of the run, which the child writes next to the mark
    # (lib/verification.sh), also for a reused pass, and the durations of the
    # checks that ran, which a reused pass has none of.
    records_budgets='[]'
    records_checks='[]'
    if [[ -f "$root/scripts/lib/verification.sh" ]]; then
      records_budgets="$(verification_budgets_json "$records_mark.budgets" 2>/dev/null)" || records_budgets='[]'
      if declare -F verification_durations_json >/dev/null; then
        records_checks="$(verification_durations_json "$records_mark.durations" 2>/dev/null)" || records_checks='[]'
      fi
    fi
    rm -f "$records_mark" "$records_mark.budgets" "$records_mark.durations" 2>/dev/null || true
    records_verification "$records_status" "$(($(date +%s) - records_started))" "$records_reused" all "$records_call" "$records_budgets" "$records_checks" "$records_trusted" "$records_origin"
    exit "$records_status"
  fi
fi

# Working files of this run: the output of each budget check, the budget
# results and the durations of the checks (lib/verification.sh), and the
# index of a fingerprint.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")"
# The checks of a parallel run that still run are stopped, and the slot for
# heavy verification is given back, however the run ends; a signal ends it
# through this trap too.
trap '! declare -F parallel_stop >/dev/null || parallel_stop; ! declare -F verify_lock_release >/dev/null || verify_lock_release; rm -rf "$scratch"' EXIT
budgets_file="$scratch/budgets"
durations_file="$scratch/durations"

# A passed run is recorded only where the record is a file that Git ignores.
recordable=0
for library in fingerprint verification; do
  [[ -f "$root/scripts/lib/$library.sh" ]] || continue
  source "$root/scripts/lib/$library.sh"
done
if declare -F verification_recordable >/dev/null && declare -F fingerprint_worktree >/dev/null &&
  verification_recordable "$root"; then
  recordable=1
fi

# budget_result <name> <status> <exit> <output-file>
# Keeps the result of a budget check for the record and the run record, with
# lib/verification.sh; without the library the summary alone shows it.
budget_result() {
  ! declare -F verification_budget_add >/dev/null || verification_budget_add "$budgets_file" "$@"
}

# hand_budgets_to_run
# Gives the budget results to the run that records this verification, when
# one does: the wrapper above reads them next to its mark.
hand_budgets_to_run() {
  [[ -n "${RECORDS_VERIFICATION:-}" && -s "$budgets_file" ]] || return 0
  cp "$budgets_file" "$RECORDS_VERIFICATION.budgets" 2>/dev/null || true
}

# hand_durations_to_run
# Gives the durations of the checks that ran to the run that records this
# verification, as hand_budgets_to_run does.
hand_durations_to_run() {
  [[ -n "${RECORDS_VERIFICATION:-}" && -s "$durations_file" ]] || return 0
  cp "$durations_file" "$RECORDS_VERIFICATION.durations" 2>/dev/null || true
}

# now_ms: the time in milliseconds; whole seconds where the shell has no
# EPOCHREALTIME (bash before 5).
now_ms() {
  local now="${EPOCHREALTIME:-}"

  if [[ -n "$now" ]]; then
    now="${now/[.,]/}"
    echo "$((10#${now:0:${#now}-3}))"
  else
    echo "$(($(date +%s) * 1000))"
  fi
}

# seconds_text <ms>: '12.3s'.
seconds_text() {
  printf '%d.%ds' "$(($1 / 1000))" "$(($1 % 1000 / 100))"
}

names=()
commands=()
groups=()
partitions=()
budgets=()
workflow_paths=""
budget_seconds=""
project_budget_seconds=""
workflow_budget_seconds=""
heavy=()
parallel_value=""
accepted_names=()
accepted_reasons=()
accepted_lines=()
accepted_scopes=()
accepted_statuses=()

# completed_status <status>: whether a non-zero exit status is the check's
# own, so that the check ran to its end. 1..123 and 128 are; 124 of 'timeout'
# and a death by a signal (129 and up) mean that it did not finish, and
# 125..127 (an error of 'timeout' itself, a command that is not executable or
# not found) that it could not run. 128 is not reserved: no utility returns it
# for a command that was not invoked.
completed_status() {
  [[ "$1" -ge 1 && ("$1" -le 123 || "$1" -eq 128) ]]
}

# load_checks <file> <paths-entry>
# Appends the checks of <file> to names, commands, groups, partitions (the
# declared partition file, or empty), and budgets ('yes' for a budget check). With <paths-entry> 'yes', the reserved entry 'paths:'
# sets workflow_paths instead of declaring a check. The reserved entry
# 'budget-seconds:' sets budget_seconds, the target for the duration of the
# checks of <file>. The reserved entry 'heavy:' sets heavy to 'yes' for the
# checks of <file> that it names. In scripts/verify.conf (<paths-entry> 'no'),
# the reserved entry 'parallel: <n>' sets parallel_value, the number of checks
# that run at a time; in the other file it is refused. There,
# the reserved entry 'accepted-failure: <check> <reason>' adds the owner's
# exception for the failure of a check to accepted_names and accepted_reasons;
# a scoped exception sets accepted_scopes to 'changed-files' (its reason is
# then the command for the changed files) or 'recorded', and is empty
# otherwise, and accepted_statuses to the exit statuses it declares, each
# between spaces (' 1 2 ').
load_checks() {
  local file="$1"
  local paths_entry="$2"
  local label="${1#"$root"/}"
  local line
  local line_number=0
  local name
  local group
  local partition
  local budget
  local value
  local existing
  local scope
  local statuses
  local status
  local first="${#names[@]}"
  local heavy_names=""
  local heavy_line=0
  local heavy_list=()
  local index

  budget_seconds=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    [[ "$line" =~ $comment_pattern ]] && continue
    [[ "$line" =~ $check_pattern ]] ||
      config_fail "malformed check on line $line_number of $label: $line"

    name="${BASH_REMATCH[1]}"
    group="${BASH_REMATCH[3]}"
    partition="${BASH_REMATCH[5]}"
    budget="${BASH_REMATCH[6]:+yes}"
    value="${BASH_REMATCH[7]}"
    if [[ "$paths_entry" == "yes" && "$name" == "paths" ]]; then
      [[ -z "$group" ]] || config_fail "'paths' takes no group on line $line_number of $label."
      [[ -z "$partition" ]] || config_fail "'paths' is not a check and declares no partition, on line $line_number of $label."
      [[ -z "$budget" ]] || config_fail "'paths' is not a check and cannot be a budget, on line $line_number of $label."
      [[ -z "$workflow_paths" ]] ||
        config_fail "'paths' is declared more than once in $label."
      workflow_paths="$value"
      continue
    fi
    if [[ "$name" == "budget-seconds" ]]; then
      [[ -z "$group" && -z "$partition" && -z "$budget" ]] ||
        config_fail "'budget-seconds' is a target, not a check: it takes no group, declares no partition, and is no budget check, on line $line_number of $label."
      [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        config_fail "'budget-seconds' needs a whole number of seconds greater than 0, on line $line_number of $label: $value"
      [[ -z "$budget_seconds" ]] ||
        config_fail "'budget-seconds' is declared more than once in $label."
      budget_seconds="$value"
      continue
    fi
    if [[ "$paths_entry" == "no" && "$name" == "accepted-failure" ]]; then
      [[ -z "$group" && -z "$budget" && -z "$partition" ]] ||
        config_fail "'accepted-failure' is an exception, not a check: it takes no group or partition and is no budget check, on line $line_number of $label."
      [[ "$value" =~ ^([a-z0-9][a-z0-9-]*)[[:space:]]+([^[:space:]].*)$ ]] ||
        config_fail "'accepted-failure' needs the name of a check and the reason the owner accepts its failure, on line $line_number of $label: $value"
      for existing in ${accepted_names[@]+"${accepted_names[@]}"}; do
        [[ "$existing" != "${BASH_REMATCH[1]}" ]] ||
          config_fail "'accepted-failure' names the check ${BASH_REMATCH[1]} more than once in $label."
      done
      accepted_names+=("${BASH_REMATCH[1]}")
      accepted_lines+=("$line_number")
      value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^(changed-files|recorded)([[:space:]]|$) ]]; then
        scope="${BASH_REMATCH[1]}"
        [[ "$value" =~ ^$scope[[:space:]]+exit[[:space:]]+([0-9]+(,[0-9]+)*)([[:space:]]+(.*))?$ ]] ||
          config_fail "'accepted-failure: <check> $scope' needs the exit status or statuses, separated by commas, with which the check completed with failures, such as 'exit 1' for prettier, on line $line_number of $label: $value"
        statuses="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[4]}"
        for status in ${statuses//,/ }; do
          [[ "$status" =~ ^[1-9][0-9]{0,2}$ ]] && completed_status "$status" ||
            config_fail "'accepted-failure' declares the exit status $status, which does not mean that the check completed with failures (1 to 123 or 128; 0 is a pass, 124 a time-out, 125 to 127 a check that could not run, 129 and up a signal), on line $line_number of $label."
        done
        statuses=" ${statuses//,/ } "
        if [[ "$scope" == changed-files ]]; then
          [[ -n "$value" ]] ||
            config_fail "'accepted-failure: <check> changed-files exit <statuses>' needs the command that checks the changed files, on line $line_number of $label."
        else
          [[ -z "$value" ]] ||
            config_fail "'accepted-failure: <check> recorded exit <statuses>' takes nothing more: the failures are recorded in $accepted_lists_relative/<check>, on line $line_number of $label: $value"
        fi
        accepted_scopes+=("$scope")
        accepted_reasons+=("$value")
        accepted_statuses+=("$statuses")
      else
        accepted_scopes+=("")
        accepted_reasons+=("$value")
        accepted_statuses+=("")
      fi
      continue
    fi
    if [[ "$name" == "parallel" ]]; then
      [[ "$paths_entry" == "no" ]] ||
        config_fail "'parallel' is declared in scripts/verify.conf only, where it covers the checks of both files, not on line $line_number of $label."
      [[ -z "$group" && -z "$budget" && -z "$partition" ]] ||
        config_fail "'parallel' is a setting, not a check: it takes no group or partition and is no budget check, on line $line_number of $label."
      [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        config_fail "'parallel' needs a whole number of checks greater than 0, on line $line_number of $label: $value"
      [[ -z "$parallel_value" ]] ||
        config_fail "'parallel' is declared more than once in $label."
      parallel_value="$value"
      continue
    fi
    if [[ "$name" == "heavy" ]]; then
      [[ -z "$group" && -z "$budget" && -z "$partition" ]] ||
        config_fail "'heavy' names checks, it is not a check: it takes no group or partition and is no budget check, on line $line_number of $label."
      [[ "$heavy_line" -eq 0 ]] ||
        config_fail "'heavy' is declared more than once in $label."
      heavy_names="$value"
      heavy_line="$line_number"
      continue
    fi
    [[ -z "$partition" || -z "$budget" ]] ||
      config_fail "the budget check $name declares the partition $partition on line $line_number of $label: a budget fails nothing, so its tests would not be required."
    for existing in ${names[@]+"${names[@]}"}; do
      [[ "$existing" != "$name" ]] ||
        config_fail "duplicate check name on line $line_number of $label: $name"
    done
    names+=("$name")
    commands+=("$value")
    groups+=("${group:-$default_group}")
    partitions+=("$partition")
    budgets+=("${budget:-no}")
    heavy+=(no)
  done <"$file"

  read -r -a heavy_list <<<"$heavy_names"
  for name in ${heavy_list[@]+"${heavy_list[@]}"}; do
    for ((index = first; index < ${#names[@]}; index++)); do
      [[ "${names[$index]}" != "$name" ]] || break
    done
    [[ "$index" -lt "${#names[@]}" ]] ||
      config_fail "'heavy' on line $heavy_line of $label names '$name', which is not a check of $label."
    heavy[$index]=yes
  done
}

# in_list <value> <comma-separated-list>
in_list() {
  [[ ",$2," == *",$1,"* ]]
}

# feature_base
# Sets base_commit to the point where the feature left its base branch, and
# base_ref to the ref of the base it was found on: origin/<base>, else
# <base>. The base is the feature's (lib/base.sh); 'main' without the
# library. Fails when it cannot be determined, as in a shallow clone.
base_commit=""
base_ref=""
feature_base() {
  local ref
  local base
  local branch="main"

  [[ -z "$base_commit" ]] || return 0
  command -v git >/dev/null 2>&1 || return 1
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  if [[ -f "$root/scripts/lib/base.sh" ]]; then
    source "$root/scripts/lib/base.sh"
    branch="$(branch_base "$root")" || return 1
  fi
  for ref in "origin/$branch" "$branch"; do
    if base="$(git -C "$root" merge-base "$ref" HEAD 2>/dev/null)" && [[ -n "$base" ]]; then
      base_commit="$base"
      base_ref="$ref"
      return 0
    fi
  done
  return 1
}

# trusted_base
# Prints the tree of the last trusted pass of the run (lib/verification.sh):
# the last tree in VERIFY_TRUSTED_TREES, which only a workflow script adds
# to, for its own passes. Fails without one, without the tree of the content
# now (tree_before), or when Git does not know that tree.
trusted_base() {
  local trusted=()

  [[ -n "$tree_before" ]] || return 1
  read -r -a trusted <<<"${VERIFY_TRUSTED_TREES:-}"
  [[ "${#trusted[@]}" -gt 0 ]] || return 1
  git -C "$root" cat-file -e "${trusted[${#trusted[@]} - 1]}^{tree}" 2>/dev/null || return 1
  printf '%s\n' "${trusted[${#trusted[@]} - 1]}"
}

# workflow_files_changed
# Exits 0 when a file under workflow_paths differs from the tree of the last
# trusted pass of the run (trusted_base), or without one from the base
# branch, counting uncommitted and untracked files; 1 when none does, and 2
# when that cannot be determined. A trusted pass ran the self-tests, or
# skipped them because its workflow files were those of the base or of the
# pass before it, so content with the same workflow files needs no new run.
# Sets workflow_base to what was compared with.
workflow_files_changed() {
  local specs=()
  local changed
  local trusted

  read -r -a specs <<<"$workflow_paths"
  if trusted="$(trusted_base)"; then
    workflow_base="the last trusted pass of this run (tree ${trusted:0:12})"
    changed="$(git -C "$root" diff-tree -r --name-only "$trusted" "$tree_before" -- "${specs[@]}")" || return 2
    [[ -n "$changed" ]]
    return
  fi
  feature_base || return 2
  workflow_base="$base_ref"

  changed="$(
    git -C "$root" diff --name-only "$base_commit" -- "${specs[@]}" &&
      git -C "$root" ls-files --others --exclude-standard -- "${specs[@]}"
  )" || return 2
  [[ -n "$changed" ]]
}

# changed_files <file>
# Writes the files that the feature adds or changes since its base to <file>,
# separated by NUL: committed, staged, unstaged, and untracked; a deleted
# file is left out. Fails when the base cannot be determined.
changed_files() {
  feature_base || return 1
  {
    git -C "$root" diff -z --name-only --no-renames --diff-filter=d "$base_commit" -- &&
      git -C "$root" ls-files -z --others --exclude-standard --
  } >"$1"
}

# reads_changed_lib_file <test> <list>
# Succeeds when scripts/<test>.sh or scripts/lib/<test>.sh names a file of
# scripts/lib/ that is not a shell script and is in <list>, the changed files
# separated by NUL: a jq program or another file the script reads at run
# time, named by its path under scripts/ ('lib/report.jq'). A shell script
# of scripts/lib/ selects its own self-test by name and nothing else.
reads_changed_lib_file() {
  local script
  local file

  for script in "$root/scripts/$1.sh" "$root/scripts/lib/$1.sh"; do
    [[ -f "$script" ]] || continue
    while IFS= read -r -d '' file; do
      [[ "$file" == scripts/lib/* && "$file" != *.sh ]] || continue
      ! grep -Fq -- "${file#scripts/}" "$script" || return 0
    done <"$2"
  done
  return 1
}

# shared_test_parts <test>
# Prints the names <y> of the files tests/lib-<y>.sh that tests/<test>-test.sh
# sources and for which scripts/<y>.sh exists: the shared part of the
# self-tests of scripts/<y>.sh when they are split over several files
# (tests/lib-run-feature.sh and tests/run-feature-<part>-test.sh).
shared_test_parts() {
  local file="$root/tests/$1-test.sh"
  local name

  [[ -f "$file" ]] || return 0
  while IFS= read -r name; do
    if [[ -f "$root/scripts/$name.sh" ]]; then printf '%s\n' "$name"; fi
  done < <(sed -nE 's|^[[:space:]]*source "\$(source_)?root/tests/lib-([a-z0-9][a-z0-9-]*)\.sh"[[:space:]]*$|\2|p' "$file")
}

# select_changed_tests
# For --changed: marks in selected_tests the self-tests of the files changed
# since the base (changed_files): the check that runs tests/<x>-test.sh when
# that file, scripts/<x>.sh, or scripts/lib/<x>.sh changed, or when
# scripts/<x>.sh or scripts/lib/<x>.sh names a changed file of scripts/lib/
# that is not a shell script (reads_changed_lib_file). A test that sources
# the shared part tests/lib-<y>.sh of the self-tests of scripts/<y>.sh
# (shared_test_parts) is selected for <y> as for <x>, and for a change to
# tests/lib-<y>.sh. A self-test that runs no test file of its own is left
# to the full verification. Sets workflow_note, or workflow_skipped when none
# is selected. Without a base no self-test is selected: the full
# verification decides.
selected_tests=()
select_changed_tests() {
  local list="$scratch/changed-files"
  local index
  local test
  local shared
  local reader
  local selected
  local patterns
  local readers
  local count=0
  local chosen=""

  if ! changed_files "$list"; then
    workflow_skipped="SKIP  workflow self-tests ($workflow_count checks): the base branch could not be determined, so no changed file selects one; the full verification decides"
    return 0
  fi
  for ((index = project_count; index < ${#names[@]}; index++)); do
    [[ "${commands[$index]}" =~ ^\./tests/([a-z0-9][a-z0-9-]*)-test\.sh([[:space:]]|$) ]] || continue
    test="${BASH_REMATCH[1]}"
    patterns=(-e "tests/$test-test.sh" -e "scripts/$test.sh" -e "scripts/lib/$test.sh")
    readers=("$test")
    while IFS= read -r shared; do
      patterns+=(-e "tests/lib-$shared.sh" -e "scripts/$shared.sh" -e "scripts/lib/$shared.sh")
      readers+=("$shared")
    done < <(shared_test_parts "$test")
    selected=no
    if tr '\0' '\n' <"$list" | grep -Fqx "${patterns[@]}"; then
      selected=yes
    else
      for reader in "${readers[@]}"; do
        if reads_changed_lib_file "$reader" "$list"; then
          selected=yes
          break
        fi
      done
    fi
    if [[ "$selected" == "yes" ]]; then
      selected_tests[$index]=yes
      count=$((count + 1))
      chosen="${chosen:+$chosen, }${names[$index]}"
    fi
  done
  if [[ "$count" -eq 0 ]]; then
    workflow_skipped="SKIP  workflow self-tests ($workflow_count checks): --changed selects none, since no tested file changed since ${base_ref:-the base}; the full verification decides"
  else
    workflow_note="--changed selects $count of $workflow_count, of the files changed since $base_ref: $chosen"
  fi
}

# skipped_check <index>
# Succeeds when a partial run leaves out the check <index>: one outside the
# groups of --only, or a self-test that --changed does not select.
skipped_check() {
  [[ "$partial" -eq 1 ]] || return 1
  if [[ "$changed_mode" -eq 1 ]]; then
    [[ "$1" -ge "$project_count" && "${selected_tests[$1]:-}" != "yes" ]]
  else
    ! in_list "${groups[$1]}" "$only"
  fi
}

[[ "$list_groups" -eq 1 ]] || echo "== Agentic project verification =="

[[ -f "$config" ]] || config_fail "verification config not found: $config"
load_checks "$config" no
project_budget_seconds="$budget_seconds"
[[ "${#names[@]}" -gt 0 ]] || config_fail "scripts/verify.conf declares no checks."
for index in "${!accepted_names[@]}"; do
  for name in "${names[@]}"; do
    [[ "$name" != "${accepted_names[$index]}" ]] || continue 2
  done
  config_fail "'accepted-failure' on line ${accepted_lines[$index]} of scripts/verify.conf names '${accepted_names[$index]}', which is not a check of scripts/verify.conf."
done
for index in "${!accepted_names[@]}"; do
  [[ -n "${accepted_scopes[$index]}" ]] || continue
  for ((check = 0; check < ${#names[@]}; check++)); do
    [[ "${names[$check]}" != "${accepted_names[$index]}" ]] || break
  done
  [[ "${budgets[$check]}" == "no" ]] ||
    config_fail "'accepted-failure' on line ${accepted_lines[$index]} of scripts/verify.conf scopes the budget check '${accepted_names[$index]}': a budget fails nothing, so there is nothing to scope."
  [[ "${accepted_scopes[$index]}" != "recorded" || -f "$root/$accepted_lists_relative/${accepted_names[$index]}" ]] ||
    config_fail "'accepted-failure' on line ${accepted_lines[$index]} of scripts/verify.conf compares the failures of '${accepted_names[$index]}' with $accepted_lists_relative/${accepted_names[$index]}, which does not exist."
done

# accepted_index <check>: the index of the owner's exception for the failure
# of <check>; fails when there is none. A baseline run knows no exception: it
# records how each check ends.
accepted_index() {
  local index

  [[ "$baseline_mode" -eq 0 ]] || return 1
  for index in "${!accepted_names[@]}"; do
    if [[ "${accepted_names[$index]}" == "$1" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

# accepted_scope <check>: the scope of the owner's exception for <check>
# ('changed-files' or 'recorded'); nothing for an exception of the whole
# check or none.
accepted_scope() {
  local index

  index="$(accepted_index "$1")" || return 0
  printf '%s\n' "${accepted_scopes[$index]}"
}

# The baseline of an adopted project: 'pass: <check>', 'fail: <check>
# <detail>', and 'unavailable: <check> <detail>' lines, written by
# --baseline below.
baseline_entries=""
baseline_recorded_at=""
if [[ -f "$baseline_file" ]]; then
  baseline_entries="$(sed -n -E 's/^(pass|fail|unavailable):[[:space:]]+([a-z0-9][a-z0-9-]*).*$/\1 \2/p' "$baseline_file")"
  baseline_recorded_at="$(sed -n 's/^recorded-at:[[:space:]]*//p' "$baseline_file" | head -n 1)"
fi

# baseline_state <check>: 'pass', 'fail', or 'unavailable' as the baseline
# recorded the check, or nothing.
baseline_state() {
  [[ "$baseline_mode" -eq 0 && -n "$baseline_entries" ]] || return 0
  printf '%s\n' "$baseline_entries" | awk -v name="$1" '$2 == name { print $1; exit }'
}

if [[ "$baseline_mode" -eq 1 ]]; then
  if [[ -e "$baseline_file" ]]; then
    echo "Error: the baseline is recorded already in $baseline_relative${baseline_recorded_at:+ (recorded at $baseline_recorded_at)}. It is recorded once, before any change; to record it again, the owner removes that file in a reviewed change." >&2
    exit 1
  fi
  echo "Baseline: every check of scripts/verify.conf runs once, and how it ends is recorded in $baseline_relative. This runs the project's own commands. It is not a verification and records no pass."
fi

# The fingerprint of the content before any check runs: what a pass is
# recorded for, and what the workflow files are compared with the last
# trusted pass of the run on.
tree_before=""
if [[ "$recordable" -eq 1 && "$list_groups" -eq 0 ]]; then
  tree_before="$(fingerprint_worktree "$root" "$scratch")" || tree_before=""
fi

# Decide whether the workflow self-tests run. Their checks follow the project
# checks; a project without scripts/verify-workflow.conf has none.
project_count="${#names[@]}"
workflow_note=""
workflow_skipped=""
workflow_base=""
if [[ -f "$workflow_config" ]]; then
  load_checks "$workflow_config" yes
  workflow_budget_seconds="$budget_seconds"
  workflow_count=$((${#names[@]} - project_count))
  [[ "$workflow_count" -gt 0 ]] || config_fail "scripts/verify-workflow.conf declares no checks."
  [[ -n "$workflow_paths" ]] ||
    config_fail "scripts/verify-workflow.conf must declare the workflow files as 'paths: <pathspec>...'."

  if [[ "$baseline_mode" -eq 1 ]]; then
    workflow_skipped="SKIP  workflow self-tests ($workflow_count checks): a baseline covers the checks of the project only"
  elif [[ "$run_all" -eq 1 ]]; then
    workflow_note="requested with --all"
  elif [[ "$changed_mode" -eq 1 ]]; then
    select_changed_tests
  else
    changed_status=0
    workflow_files_changed || changed_status=$?
    case "$changed_status" in
      0) workflow_note="a workflow file differs from $workflow_base" ;;
      1) workflow_skipped="SKIP  workflow self-tests ($workflow_count checks): no workflow file differs from $workflow_base; --all runs them" ;;
      *) workflow_note="could not determine whether a workflow file changed" ;;
    esac
  fi
fi

# The groups that have a check, in the order of their first check.
known_groups=""
for group in "${groups[@]}"; do
  in_list "$group" "$known_groups" || known_groups="${known_groups:+$known_groups,}$group"
done
if [[ "$list_partitions" -eq 1 ]]; then
  for i in "${!names[@]}"; do
    [[ -z "${partitions[i]}" ]] || printf '%s\t%s\n' "${partitions[i]}" "${names[i]}"
  done
  exit 0
fi
if [[ "$list_groups" -eq 1 ]]; then
  printf '%s\n' "${known_groups//,/$'\n'}"
  exit 0
fi
if [[ "$changed_mode" -eq 1 ]]; then
  echo "Only the checks of the changed files (--changed): every check of scripts/verify.conf and the self-tests of the files changed since the base. A partial run is not a verification and records nothing."
elif [[ "$partial" -eq 1 ]]; then
  IFS=, read -r -a wanted <<<"$only"
  for group in "${wanted[@]}"; do
    in_list "$group" "$known_groups" ||
      config_fail "no check is in the group '$group'. The groups are: ${known_groups//,/, }."
  done
  echo "Only the groups: ${only//,/, }. A partial run is not a verification and records nothing."
fi

# With --reuse, a recorded pass for exactly this content stands in for a run.
# A record made without the workflow self-tests does not cover a run that
# needs them. With VERIFY_TRUSTED_TREES set, the trust contract of the
# workflow scripts (lib/verification.sh), only a pass whose tree is in the
# list counts: any other record may have been written in an agent session.
if [[ "$recordable" -eq 1 ]]; then
  if [[ "$reuse" -eq 1 && -n "$tree_before" && "$(verification_field "$root" tree)" == "$tree_before" ]] &&
    [[ -n "${VERIFY_TRUSTED_TREES+set}" ]] && ! verification_tree_trusted "$tree_before"; then
    echo
    echo "A pass is recorded for this content, but not by a workflow script of this run (VERIFY_TRUSTED_TREES); every check runs."
  elif [[ "$reuse" -eq 1 && -n "$tree_before" && "$(verification_field "$root" tree)" == "$tree_before" ]]; then
    recorded_workflow="$(verification_field "$root" workflow-tests)"
    if [[ "$recorded_workflow" != "skipped" || ( -n "$workflow_skipped" && "$run_all" -eq 0 ) ]]; then
      echo
      echo "Verification already passed for this content at $(verification_field "$root" verified-at); not run again."
      echo "Run ./scripts/verify.sh without --reuse to run every check."
      recorded_budgets="$(verification_budgets "$root")"
      if [[ -n "$recorded_budgets" ]]; then
        echo "Its budget results, recorded with the pass:"
        printf '%s\n' "$recorded_budgets" | verification_budget_report | sed 's/^/  /'
        printf '%s\n' "$recorded_budgets" >"$budgets_file"
        hand_budgets_to_run
      fi
      [[ -z "${RECORDS_VERIFICATION:-}" ]] || { : >"$RECORDS_VERIFICATION"; } 2>/dev/null || true
      exit 0
    fi
  fi
fi

# How many checks run at a time: 'parallel: <n>' of scripts/verify.conf, or
# VERIFY_PARALLEL for one run; one at a time without either.
parallel_jobs="${parallel_value:-1}"
parallel_source="parallel: $parallel_jobs in scripts/verify.conf"
if [[ -n "${VERIFY_PARALLEL:-}" ]]; then
  [[ "$VERIFY_PARALLEL" =~ ^[1-9][0-9]*$ ]] ||
    config_fail "VERIFY_PARALLEL needs a whole number of checks greater than 0: $VERIFY_PARALLEL"
  parallel_jobs="$VERIFY_PARALLEL"
  parallel_source="VERIFY_PARALLEL=$parallel_jobs"
fi

# The slot for heavy verification, taken only when a heavy check is going to
# run. A run that finds it busy starts no check and records nothing: it is
# not a verification, and not a failure of a check.
heavy_run=0
for index in "${!names[@]}"; do
  [[ "${heavy[$index]}" == "yes" ]] || continue
  [[ "$index" -lt "$project_count" || -z "$workflow_skipped" ]] || continue
  ! skipped_check "$index" || continue
  heavy_run=1
done
if [[ "$heavy_run" -eq 1 ]]; then
  [[ -f "$root/scripts/lib/verify-lock.sh" ]] ||
    config_fail "'heavy' needs scripts/lib/verify-lock.sh, which is missing."
  source "$root/scripts/lib/verify-lock.sh"
  lock_status=0
  verify_lock_acquire "$root" "${RECORDS_RUN_ID:-none}" || lock_status=$?
  if [[ "$lock_status" -ne 0 ]]; then
    echo
    echo "== Verification summary =="
    if [[ "$lock_status" -eq "$VERIFY_LOCK_BUSY" ]]; then
      echo "BUSY  the slot for heavy verification of this machine is held by $verify_lock_holder_text"
      echo "Verification not run: the machine is busy with another heavy verification. This is not a failure of the code, no check ran, and nothing was recorded. Run again when that run has ended." >&2
    else
      echo "BUSY  the slot for heavy verification could not be taken: its lock $(verify_lock_path) cannot be created"
      echo "Verification not run: set VERIFY_LOCK_DIR to a directory that every session of this machine can write. No check ran, and nothing was recorded." >&2
    fi
    exit "$VERIFY_LOCK_BUSY"
  fi
  if [[ -n "$verify_lock_acquired" ]]; then
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    echo
    echo "Holding the slot for heavy verification of this machine (lock $(verify_lock_path), PID $$)."
  fi
fi

# record_duration <index> <ms> <result>
# Keeps the duration of a check that ran: for the duration budgets below, and
# with lib/verification.sh for the record and the run record. <result> is
# 'pass', 'fail', or 'budget'. A parallel run, whose checks end in any
# order, writes the durations when every check has ended, in the order of the
# files (record_duration_file).
record_duration() {
  durations[$1]="$2"
  duration_results[$1]="$3"
  [[ "$parallel_jobs" -gt 1 ]] || record_duration_file "$1"
}

# record_duration_file <index>: adds the duration of the check to the record.
record_duration_file() {
  ! declare -F verification_duration_add >/dev/null ||
    verification_duration_add "$durations_file" "${names[$1]}" "$(config_of "$1")" "${durations[$1]}" "${duration_results[$1]}"
}

# wall_clock <first-index> <end-index>: in a parallel run, the time from the
# start of the first of the checks <first-index> to <end-index> - 1 to the
# end of the last, in milliseconds; nothing when none of them ran.
wall_clock() {
  local index
  local first=""
  local last=""

  for ((index = $1; index < $2; index++)); do
    [[ -n "${check_started[$index]:-}" && -n "${check_ended[$index]:-}" ]] || continue
    [[ -n "$first" && "$first" -le "${check_started[$index]}" ]] || first="${check_started[$index]}"
    [[ -n "$last" && "$last" -ge "${check_ended[$index]}" ]] || last="${check_ended[$index]}"
  done
  [[ -z "$first" ]] || echo "$((last - first))"
}

# config_of <index>: the file that declares the check.
config_of() {
  if [[ "$1" -lt "$project_count" ]]; then echo "scripts/verify.conf"; else echo "scripts/verify-workflow.conf"; fi
}

# duration_budget <label> <target-seconds> <first-index> <end-index>
# Compares the duration of the checks <first-index> to <end-index> - 1, the
# checks of the file <label>, with its target. Over it, the summary shows
# BUDGET with the total, the target, and the five slowest checks, and the
# result is kept as a budget result named 'duration of <label>': a
# measurement that fails nothing. Within it, nothing is shown. The target is
# compared with the sum of the durations; a parallel run also shows the
# wall-clock time of those checks next to it.
duration_budget() {
  local label="$1"
  local target="$2"
  local index
  local total=0
  local output
  local wall=""
  local wall_text=""

  [[ -n "$target" ]] || return 0
  for ((index = $3; index < $4; index++)); do
    total=$((total + ${durations[$index]:-0}))
  done
  [[ "$total" -gt $((target * 1000)) ]] || return 0
  if [[ "$parallel_jobs" -gt 1 ]]; then
    wall="$(wall_clock "$3" "$4")"
    [[ -z "$wall" ]] || wall_text=", $(seconds_text "$wall") wall-clock"
  fi
  output="$scratch/duration-budget.out"
  {
    echo "$(seconds_text "$total") in total$wall_text, target ${target}s; the slowest checks:"
    for ((index = $3; index < $4; index++)); do
      [[ -z "${durations[$index]:-}" ]] || printf '%s\t%s\n' "${durations[$index]}" "${names[$index]}"
    done | sort -t $'\t' -k1,1nr | head -n 5 | while IFS=$'\t' read -r ms check; do
      echo "$check $(seconds_text "$ms")"
    done
  } >"$output"
  echo "Note: the checks of $label took $(seconds_text "$total"), over the target of ${target}s. A budget is a measurement, not a failure: the verification does not fail for it, and nothing repairs it." >&2
  results+=("BUDGET  duration of $label ($(seconds_text "$total")$wall_text, target ${target}s)")
  while IFS= read -r line; do
    results+=("        $line")
  done < <(tail -n +2 "$output")
  budget_result "duration of $label" exceeded - "$output"
  duration_exceeded=$((duration_exceeded + 1))
}

# run_check <command> <output> [stdout]
# Runs a check in the worktree and returns its exit status. With an <output>
# file (a budget check) its output is kept there too; with 'stdout' (a check
# whose failures are recorded) only its standard output.
run_check() {
  if [[ "${3:-}" == "stdout" ]]; then
    (
      unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE VERIFY_PARALLEL
      unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
      cd "$root" && bash -eo pipefail -c "$1"
    ) | tee "$2"
    return "${PIPESTATUS[0]}"
  fi
  if [[ -n "$2" ]]; then
    (
      unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE VERIFY_PARALLEL
      unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
      cd "$root" && bash -eo pipefail -c "$1"
    ) 2>&1 | tee "$2"
    return "${PIPESTATUS[0]}"
  fi
  (
    unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE VERIFY_PARALLEL
    unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
    cd "$root" && bash -eo pipefail -c "$1"
  )
}

# failure_result <index> <what> [status]: the summary line of a check that
# failed or could not run, <what> saying how ('exit 1', 'missing tool: x'),
# <status> its exit status when it ran. Without a baseline and an exception it
# is FAIL; ACCEPTED, the owner's exception, and SCOPED, a failure within the
# scope of a scoped exception, are the only results of a failure that do not
# fail the verification. A scoped exception applies only to a check that
# completed (completed_status) with a status it declares: what a check
# printed before it crashed, was killed, timed out, or ended with another
# status, such as a problem of the tool itself, is not the whole of its
# failures, so it is neither SCOPED nor a source of FIXED.
failure_result() {
  local name="${names[$1]}"
  local accepted
  local state
  local declared
  local detail=""

  if accepted="$(accepted_index "$name")"; then
    if [[ -z "${accepted_scopes[$accepted]}" ]]; then
      results+=("ACCEPTED  $name ($2): an accepted exception of scripts/verify.conf: ${accepted_reasons[$accepted]}")
      accepted_count=$((accepted_count + 1))
      return 0
    elif ! completed_status "${3:-0}"; then
      echo "Error: check '$name' did not complete ($2): its scoped exception accepts only the failures of a check that ran to its end, so it fails." >&2
      scope_lines=("        it did not complete ($2), so its failures cannot be compared with the scope")
    elif [[ "${accepted_statuses[$accepted]}" != *" $3 "* ]]; then
      declared="${accepted_statuses[$accepted]# }"
      declared="${declared% }"
      echo "Error: check '$name' ended with status $3, which its scoped exception does not declare as a completed check with failures (exit ${declared// /,}), so it fails." >&2
      scope_lines=("        it ended with exit $3, not with a status its exception declares (exit ${declared// /,}), so its failures cannot be compared with the scope")
    elif [[ "${accepted_scopes[$accepted]}" == changed-files ]]; then
      ! scoped_changed_files "$1" "$2" "${accepted_reasons[$accepted]}" || return 0
    else
      ! scoped_recorded "$1" "$2" || { flush_fixed; return 0; }
    fi
    detail=": beyond the scope of its exception in scripts/verify.conf"
  fi
  failed=1
  state="$(baseline_state "$name")"
  case "$state" in
    fail | unavailable)
      results+=("KNOWN  $name ($2): failed before any change, as the baseline${baseline_recorded_at:+ of $baseline_recorded_at} recorded; not a regression, and still a failure")
      known=$((known + 1))
      ;;
    pass) results+=("FAIL  $name ($2): a regression, it passed in the baseline") ;;
    *) results+=("FAIL  $name ($2)$detail") ;;
  esac
  [[ "${#scope_lines[@]}" -eq 0 ]] || results+=("${scope_lines[@]}")
  scope_lines=()
  flush_fixed
}

# flush_fixed: adds the FIXED lines of the check that ended to the summary.
flush_fixed() {
  [[ "${#fixed_lines[@]}" -eq 0 ]] || results+=("${fixed_lines[@]}")
  fixed_lines=()
}

# scoped_changed_files <index> <what> <command>
# The scope 'changed-files' of the failure of a check: <command> runs on the
# files changed since the feature's base. Returns 0, with the SCOPED line,
# when they pass; otherwise 1, with the reason in scope_lines.
scoped_changed_files() {
  local name="${names[$1]}"
  local command="$3"
  local list="$scratch/changed-$name"
  local files=()
  local file
  local tool
  local status

  if ! changed_files "$list"; then
    echo "Error: the files changed since the feature's base cannot be determined (no base branch, or a shallow clone), so the scope of the exception of '$name' cannot be checked." >&2
    scope_lines=("        the files changed since the base cannot be determined, so the scope cannot be checked")
    return 1
  fi
  while IFS= read -r -d '' file; do
    [[ ! -e "$root/$file" ]] || files+=("$file")
  done <"$list"
  if [[ "${#files[@]}" -eq 0 ]]; then
    results+=("SCOPED  $name ($2): accepted for the files that did not change since $base_ref; no file changed")
    scoped_count=$((scoped_count + 1))
    return 0
  fi
  read -r tool _ <<<"$command"
  echo "-- $name (the ${#files[@]} file(s) changed since $base_ref): $command"
  if ! (cd "$root" && command -v "$tool" >/dev/null 2>&1); then
    echo "Error: the changed files of '$name' cannot be checked; '$tool' is missing or not executable." >&2
    scope_lines=("        the changed files cannot be checked: missing tool: $tool")
    return 1
  fi
  set +e
  (
    unset AGENT_CONFIG_FILE ATTRIBUTION_CONFIG_FILE VERIFY_PARALLEL
    unset RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT RECORDS_VERIFICATION RECORDS_DISABLED
    cd "$root" && bash -eo pipefail -c "$command \"\$@\"" verify-scope "${files[@]}"
  )
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "Error: a file changed since $base_ref fails check '$name' (status $status)." >&2
    scope_lines=("        a file changed since $base_ref fails it (exit $status): $command")
    return 1
  fi
  results+=("SCOPED  $name ($2): accepted for the files that did not change since $base_ref; the ${#files[@]} changed file(s) pass")
  scoped_count=$((scoped_count + 1))
  return 0
}

# scoped_list <file>: the entries of a list of failures, one per line,
# without blank lines, comments, and white space at the ends, sorted.
scoped_list() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' "$1" | LC_ALL=C sort -u
}

# scoped_fixed <index>: keeps the recorded failures of a check that no longer
# occur in fixed_lines, for the summary, so that the record shrinks.
scoped_fixed() {
  local name="${names[$1]}"
  local entry

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fixed_lines+=("FIXED  $name: $entry, recorded in $accepted_lists_relative/$name, no longer fails")
    fixed_count=$((fixed_count + 1))
  done < <(LC_ALL=C comm -23 "$scratch/recorded-$name.list" "$scratch/recorded-$name.now")
}

# scoped_added <index>: writes the entries of the list of a check that its
# version at the feature's base does not hold to
# $scratch/recorded-<check>.added, after scoped_list wrote the list to
# $scratch/recorded-<check>.list: the list may only shrink. A list that the
# base does not have is the first record, which adds nothing. Fails when the
# base cannot be determined.
scoped_added() {
  local name="${names[$1]}"
  local list="$accepted_lists_relative/$name"
  local added="$scratch/recorded-$name.added"

  feature_base || return 1
  if ! git -C "$root" cat-file -e "$base_commit:./$list" 2>/dev/null; then
    : >"$added"
    return 0
  fi
  git -C "$root" show "$base_commit:./$list" >"$scratch/recorded-$name.base" || return 1
  scoped_list "$scratch/recorded-$name.base" | LC_ALL=C comm -13 - "$scratch/recorded-$name.list" >"$added"
}

# scope_entries <file>: adds the lines of <file> to scope_lines, at most 20.
scope_entries() {
  local entry
  local count
  local shown=0

  count="$(wc -l <"$1" | tr -d ' ')"
  while IFS= read -r entry; do
    if [[ "$shown" -eq 20 ]]; then
      scope_lines+=("          ... and $((count - shown)) more")
      break
    fi
    scope_lines+=("          $entry")
    shown=$((shown + 1))
  done <"$1"
}

# scoped_recorded <index> <what>
# The scope 'recorded' of the failure of a check: the failures it printed are
# compared with its list. Returns 0, with the SCOPED line, when each is
# recorded and names no file changed since the feature's base, and the list
# holds no entry that it did not hold at the base; otherwise 1, with the
# reason in scope_lines. Reports the recorded failures that no longer occur
# either way.
scoped_recorded() {
  local name="${names[$1]}"
  local list="$accepted_lists_relative/$name"
  local output="$scratch/recorded-$name.out"
  local now="$scratch/recorded-$name.now"
  local new="$scratch/recorded-$name.new"
  local changed="$scratch/changed-$name"
  local added="$scratch/recorded-$name.added"
  local count

  [[ -f "$output" ]] || : >"$output"
  scoped_list "$root/$list" >"$scratch/recorded-$name.list"
  scoped_list "$output" >"$now"
  if [[ ! -s "$now" ]]; then
    scope_lines=("        it listed no failure to compare with $list")
    return 1
  fi
  if ! changed_files "$changed"; then
    echo "Error: the files changed since the feature's base cannot be determined (no base branch, or a shallow clone), so the scope of the exception of '$name' cannot be checked." >&2
    scope_lines=("        the files changed since the base cannot be determined, so the scope cannot be checked")
    return 1
  fi
  if ! scoped_added "$1"; then
    echo "Error: the list $list at the feature's base cannot be read, so the scope of the exception of '$name' cannot be checked." >&2
    scope_lines=("        the list at the base cannot be read, so the scope cannot be checked")
    return 1
  fi
  if [[ -s "$added" ]]; then
    count="$(wc -l <"$added" | tr -d ' ')"
    echo "Error: $list records $count failure(s) that it did not record at $base_ref; the list may only shrink." >&2
    scope_lines=("        $count failure(s) added to $list since $base_ref, where it may only shrink:")
    scope_entries "$added"
    scoped_fixed "$1"
    return 1
  fi
  # New: a failure that is not recorded, or that names a changed file.
  {
    LC_ALL=C comm -23 "$now" "$scratch/recorded-$name.list"
    tr '\0' '\n' <"$changed" | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$now"
  } | LC_ALL=C sort -u >"$new"
  scoped_fixed "$1"
  if [[ -s "$new" ]]; then
    count="$(wc -l <"$new" | tr -d ' ')"
    echo "Error: check '$name' has $count failure(s) that $list does not record, or of a file changed since $base_ref." >&2
    scope_lines=("        $count new failure(s): not recorded in $list, or of a file changed since $base_ref:")
    scope_entries "$new"
    return 1
  fi
  results+=("SCOPED  $name ($2): $(wc -l <"$now" | tr -d ' ') failure(s), each recorded in $list, none of a file changed since $base_ref")
  scoped_count=$((scoped_count + 1))
  return 0
}

# pass_result <index>: the summary line of a check that passed.
pass_result() {
  local name="${names[$1]}"
  local state

  state="$(baseline_state "$name")"
  if [[ "$(accepted_scope "$name")" == "recorded" ]]; then
    : >"$scratch/recorded-$name.now"
    scoped_list "$root/$accepted_lists_relative/$name" >"$scratch/recorded-$name.list"
    if ! scoped_added "$1"; then
      failed=1
      results+=("FAIL  $name (it passes, but $accepted_lists_relative/$name cannot be compared with its version at the feature's base, so its scope cannot be checked)")
    elif [[ -s "$scratch/recorded-$name.added" ]]; then
      failed=1
      results+=("FAIL  $name (it passes, but $(wc -l <"$scratch/recorded-$name.added" | tr -d ' ') failure(s) were added to $accepted_lists_relative/$name since $base_ref, where it may only shrink)")
      scope_entries "$scratch/recorded-$name.added"
      results+=("${scope_lines[@]}")
      scope_lines=()
    else
      results+=("PASS  $name (it passes: its scoped exception in scripts/verify.conf is no longer needed)")
    fi
    scoped_fixed "$1"
    flush_fixed
  elif accepted_index "$name" >/dev/null; then
    results+=("PASS  $name (it passes: its accepted exception in scripts/verify.conf is no longer needed)")
  elif [[ "$state" == fail || "$state" == unavailable ]]; then
    results+=("PASS  $name (it failed in the baseline and passes now)")
  else
    results+=("PASS  $name")
  fi
}

results=()
scope_lines=()
fixed_lines=()
failed=0
known=0
accepted_count=0
scoped_count=0
fixed_count=0
outcomes=()
exceeded=0
duration_exceeded=0
durations=()
duration_results=()
check_started=()
check_ended=()
check_output=""
check_capture=""

# check_header <index>: the line that opens the output of a check.
check_header() {
  echo
  if [[ "${budgets[$1]}" == "yes" ]]; then
    echo "-- ${names[$1]} (budget): ${commands[$1]}"
  else
    echo "-- ${names[$1]}: ${commands[$1]}"
  fi
}

# check_missing <index> <tool>: the result of a check whose tool is missing
# or not executable; it does not run. Its block ends with its duration, 0s,
# as the block of every check does.
check_missing() {
  echo "Error: required check '${names[$1]}' cannot run; '$2' is missing or not executable." >&2
  echo "-- ${names[$1]} took $(seconds_text 0)"
  failure_result "$1" "missing tool: $2"
  outcomes[$1]="unavailable: ${names[$1]} missing tool: $2"
  record_duration "$1" 0 fail
}

# check_capture_of <index>: sets check_output and check_capture, the
# arguments of run_check. A check is not part of the run that verifies: a
# workflow script that it starts, as the self-tests do, must not write into
# that run's records, and must not use the agent or attribution
# configuration that was chosen for that run (run_check). The output of a
# budget check is kept: it is the measurement.
check_capture_of() {
  check_output=""
  check_capture=""
  [[ "${budgets[$1]}" != "yes" ]] || check_output="$scratch/budget-${names[$1]}.out"
  if [[ "$(accepted_scope "${names[$1]}")" == "recorded" ]]; then
    check_output="$scratch/recorded-${names[$1]}.out"
    check_capture=stdout
  fi
}

# check_conclude <index> <status> <elapsed-ms>: the result of a check that
# ran, from its exit status.
check_conclude() {
  local index="$1"
  local status="$2"
  local elapsed="$3"
  local name="${names[$1]}"
  local budget="${budgets[$1]}"
  local output
  local line

  check_capture_of "$index"
  output="$check_output"
  if [[ "$status" -eq 0 ]]; then
    if [[ "$budget" == "yes" ]]; then
      results+=("PASS  $name (budget within its target)")
      budget_result "$name" within "$status" "$output"
    else
      pass_result "$index"
    fi
    outcomes[$index]="pass: $name"
    record_duration "$index" "$elapsed" pass
  elif [[ "$budget" == "yes" ]] && completed_status "$status"; then
    # Over the target: a measurement, not a failure. A budget check that did
    # not complete (completed_status) measured nothing, and it fails like any
    # check.
    echo "Note: budget '$name' exceeded its target (exit $status). A budget is a measurement, not a failure: the verification does not fail for it, and nothing repairs it." >&2
    results+=("BUDGET  $name (exit $status)")
    if [[ -s "$output" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        results+=("        $line")
      done <"$output"
    else
      results+=("        (no output)")
    fi
    budget_result "$name" exceeded "$status" "$output"
    exceeded=$((exceeded + 1))
    outcomes[$index]="pass: $name"
    record_duration "$index" "$elapsed" budget
  else
    if [[ "$budget" == "yes" && "$status" -ge 125 && "$status" -le 127 ]]; then
      echo "Error: budget check '$name' could not run (status $status: an error of 'timeout', or a command that is not executable or not found): nothing was measured, so it fails like any check." >&2
      results+=("FAIL  $name (exit $status, the budget check could not run)")
    elif [[ "$budget" == "yes" ]]; then
      echo "Error: budget check '$name' did not finish (status $status): nothing was measured, so it fails like any check." >&2
      results+=("FAIL  $name (exit $status, the budget check did not finish)")
    else
      echo "Error: required check '$name' failed with status $status." >&2
    fi
    if [[ "$budget" == "yes" ]]; then
      failed=1
    elif [[ "$status" -eq 127 ]]; then
      # The shell found no command to run: the check is unavailable here.
      failure_result "$index" "exit 127, a command was not found" "$status"
      outcomes[$index]="unavailable: $name exit 127, a command was not found"
    else
      failure_result "$index" "exit $status" "$status"
      outcomes[$index]="fail: $name exit $status"
    fi
    record_duration "$index" "$elapsed" fail
  fi
}

# run_sequential: the checks one at a time, in the order of the files, each
# with its output as it comes.
run_sequential() {
  local index
  local tool
  local started
  local status
  local elapsed
  local check_pid

  for index in "${!names[@]}"; do
    if [[ "$index" -eq "$project_count" ]]; then
      [[ -z "$workflow_skipped" ]] || break
      echo
      echo "== Workflow self-tests: $workflow_note =="
    fi
    if skipped_check "$index"; then
      continue
    fi
    read -r tool _ <<<"${commands[$index]}"
    check_header "$index"
    if ! (cd "$root" && command -v "$tool" >/dev/null 2>&1); then
      check_missing "$index" "$tool"
      continue
    fi

    check_capture_of "$index"
    started="$(now_ms)"
    set +e
    if [[ -n "${verify_lock_acquired:-}" ]]; then
      # The run holds the slot: the check runs in a process group of its own
      # (job control), which the lock records before the check starts, so that
      # the slot stays held while any process of the check lives, also after a
      # crash of this run. Its standard input is /dev/null: a job outside the
      # terminal's foreground group must not read from it.
      set -m
      (
        verify_lock_await_group "$$" || exit 1
        run_check "${commands[$index]}" "$check_output" "$check_capture"
      ) </dev/null &
      check_pid=$!
      set +m
      if ! verify_lock_add_group "$check_pid"; then
        # The check waits for that record: it is stopped and fails.
        echo "Error: the process group of check '${names[$index]}' could not be recorded in the lock $(verify_lock_path)." >&2
        kill -TERM -- "-$check_pid" 2>/dev/null || true
      fi
      wait "$check_pid"
      status=$?
      verify_lock_remove_group "$check_pid"
    else
      run_check "${commands[$index]}" "$check_output" "$check_capture"
      status=$?
    fi
    set -e
    elapsed=$(($(now_ms) - started))
    echo "-- ${names[$index]} took $(seconds_text "$elapsed")"
    check_conclude "$index" "$status" "$elapsed"
  done
}

# The checks of a parallel run that are running: their indexes, and the
# process (and process group) of each.
parallel_active=()
parallel_pids=()

# parallel_start <index>
# Starts a check in the background, in a process group of its own (job
# control), with its standard input /dev/null and its output, standard
# output and error together, in a file of its own. A run that holds the slot
# for heavy verification records the group in the lock before the check
# begins, as run_sequential does; the slot then stays held while any process
# of any of its checks lives.
parallel_start() {
  local index="$1"
  local pid

  check_capture_of "$index"
  check_started[$index]="$(now_ms)"
  set -m
  (
    if [[ -n "${verify_lock_acquired:-}" ]]; then
      verify_lock_await_group "$$" || exit 1
    fi
    status=0
    run_check "${commands[$index]}" "$check_output" "$check_capture" || status=$?
    now_ms >"$scratch/check-$index.end" 2>/dev/null || true
    exit "$status"
  ) </dev/null >"$scratch/check-$index.log" 2>&1 &
  pid=$!
  set +m
  parallel_pids[$index]="$pid"
  parallel_active+=("$index")
  if [[ -n "${verify_lock_acquired:-}" ]] && ! verify_lock_add_group "$pid"; then
    # The check waits for that record: it is stopped and fails.
    echo "Error: the process group of check '${names[$index]}' could not be recorded in the lock $(verify_lock_path)." >&2
    kill -TERM -- "-$pid" 2>/dev/null || true
  fi
}

# parallel_finish <index>
# Takes the result of a check that ended: prints its output as one block,
# with the line that opens it and its duration, and keeps its summary lines
# apart, so that the summary follows the order of the files.
parallel_finish() {
  local index="$1"
  local pid="${parallel_pids[$1]}"
  local status=0
  local ended=""
  local elapsed
  local kept=()
  local other

  wait "$pid" || status=$?
  [[ ! -s "$scratch/check-$index.end" ]] || ended="$(cat "$scratch/check-$index.end")"
  [[ "$ended" =~ ^[0-9]+$ ]] || ended="$(now_ms)"
  check_ended[$index]="$ended"
  elapsed=$((ended - check_started[index]))
  [[ -z "${verify_lock_acquired:-}" ]] || verify_lock_remove_group "$pid"
  for other in "${parallel_active[@]}"; do
    [[ "$other" == "$index" ]] || kept+=("$other")
  done
  parallel_active=(${kept[@]+"${kept[@]}"})
  unset "parallel_pids[$index]"

  check_header "$index"
  cat "$scratch/check-$index.log"
  echo "-- ${names[$index]} took $(seconds_text "$elapsed")"
  parallel_conclude "$index" check_conclude "$index" "$status" "$elapsed"
}

# parallel_conclude <index> <function> <argument>...: runs <function>, which
# adds the summary lines of the check <index>, and keeps those lines in a
# file of their own until the run has ended.
parallel_conclude() {
  local index="$1"

  shift
  results=()
  "$@"
  printf '%s\n' ${results[@]+"${results[@]}"} >"$scratch/results-$index"
  results=()
}

# parallel_stop: stops the checks that still run, when the run ends before
# them (a signal), with SIGTERM to the process group of each, and waits up to
# ten seconds for them. A run that holds the slot for heavy verification keeps
# it while one of them lives (verify_lock_release).
parallel_stop() {
  local index
  local tick
  local alive

  [[ "${#parallel_active[@]}" -gt 0 ]] || return 0
  for index in "${parallel_active[@]}"; do
    kill -TERM -- "-${parallel_pids[$index]}" 2>/dev/null || true
  done
  for ((tick = 0; tick < 100; tick++)); do
    alive=0
    for index in "${parallel_active[@]}"; do
      ! kill -0 -- "-${parallel_pids[$index]}" 2>/dev/null || alive=1
    done
    [[ "$alive" -eq 1 ]] || break
    sleep 0.1
  done
  parallel_active=()
}

# run_parallel: up to parallel_jobs checks at a time. They start in the order
# of the files, and a check starts as soon as one ends. The output of each is
# printed as one block when it ends; the summary lines are put together in
# the order of the files.
run_parallel() {
  local queue=()
  local index
  local next=0
  local tool
  local ended
  local line
  local wall
  local sum=0

  for index in "${!names[@]}"; do
    [[ "$index" -lt "$project_count" || -z "$workflow_skipped" ]] || break
    if skipped_check "$index"; then
      continue
    fi
    queue+=("$index")
  done
  # A signal ends the run through the EXIT trap, which stops the checks.
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  echo
  echo "Up to $parallel_jobs checks run at a time ($parallel_source). The output of each check follows as one block when it ends; the summary keeps the order of the files."
  if [[ "${#names[@]}" -gt "$project_count" && -z "$workflow_skipped" ]]; then
    echo
    echo "== Workflow self-tests: $workflow_note =="
  fi
  while [[ "$next" -lt "${#queue[@]}" || "${#parallel_active[@]}" -gt 0 ]]; do
    while [[ "$next" -lt "${#queue[@]}" && "${#parallel_active[@]}" -lt "$parallel_jobs" ]]; do
      index="${queue[$next]}"
      next=$((next + 1))
      read -r tool _ <<<"${commands[$index]}"
      if ! (cd "$root" && command -v "$tool" >/dev/null 2>&1); then
        check_header "$index"
        parallel_conclude "$index" check_missing "$index" "$tool"
        continue
      fi
      parallel_start "$index"
    done
    ended=0
    for index in ${parallel_active[@]+"${parallel_active[@]}"}; do
      if ! kill -0 "${parallel_pids[$index]}" 2>/dev/null; then
        parallel_finish "$index"
        ended=1
      fi
    done
    [[ "$ended" -eq 1 || "${#parallel_active[@]}" -eq 0 ]] || sleep 0.1
  done

  for index in ${queue[@]+"${queue[@]}"}; do
    if [[ -f "$scratch/results-$index" ]]; then
      while IFS= read -r line; do
        results+=("$line")
      done <"$scratch/results-$index"
    fi
    sum=$((sum + ${durations[$index]:-0}))
  done
  # The durations are recorded in the order of the files, as in a run of one
  # check at a time.
  for index in ${queue[@]+"${queue[@]}"}; do
    [[ -z "${duration_results[$index]:-}" ]] || record_duration_file "$index"
  done
  wall="$(wall_clock 0 "${#names[@]}")"
  if [[ -n "$wall" ]]; then
    echo
    echo "-- ${#queue[@]} checks, up to $parallel_jobs at a time, took $(seconds_text "$wall") wall-clock; their durations add up to $(seconds_text "$sum")"
  fi
}

if [[ "$parallel_jobs" -gt 1 ]]; then
  run_parallel
else
  run_sequential
fi

# The targets for the duration of each file's checks, compared only in a
# complete run of that file.
if [[ "$partial" -eq 0 ]]; then
  duration_budget "scripts/verify.conf" "$project_budget_seconds" 0 "$project_count"
  [[ -n "$workflow_skipped" ]] ||
    duration_budget "scripts/verify-workflow.conf" "$workflow_budget_seconds" "$project_count" "${#names[@]}"
fi

echo
echo "== Verification summary =="
[[ "${#results[@]}" -eq 0 ]] || printf '%s\n' "${results[@]}"
[[ -z "$workflow_skipped" ]] || echo "$workflow_skipped"
if [[ "$duration_exceeded" -gt 0 ]]; then
  echo "The checks took longer than the target of 'budget-seconds' (BUDGET): a measurement, not a failure. The owner decides whether to change the target or the checks; nothing repairs it automatically."
fi
if [[ "$exceeded" -gt 0 ]]; then
  echo "$exceeded budget check(s) exceeded their target (BUDGET): a measurement, not a failure. The owner decides whether to change the budget or the code; nothing repairs it automatically."
fi
if [[ "$known" -gt 0 ]]; then
  echo "$known check(s) failed before any change, as the baseline in $baseline_relative recorded (KNOWN): pre-existing failures, not regressions. The verification does not pass while they fail. Fix them, or the owner accepts each as an exception with a line 'accepted-failure: <check> <reason>' in scripts/verify.conf."
fi
if [[ "$accepted_count" -gt 0 ]]; then
  echo "$accepted_count check(s) failed and are exceptions the owner accepted in scripts/verify.conf (ACCEPTED): they do not fail the verification, and they are not repaired."
fi
if [[ "$scoped_count" -gt 0 ]]; then
  echo "$scoped_count check(s) failed only within the scope of an exception the owner accepted in scripts/verify.conf (SCOPED): the failures predate the change, and the files it adds or changes pass. They do not fail the verification."
fi
if [[ "$fixed_count" -gt 0 ]]; then
  echo "$fixed_count recorded failure(s) no longer occur (FIXED): remove them from their list in $accepted_lists_relative/, so that the record shrinks. A change of the list needs the owner's approval at the merge."
fi

# A baseline records how each check ended, and is never a verification.
if [[ "$baseline_mode" -eq 1 ]]; then
  mkdir -p "$(dirname "$baseline_file")"
  {
    echo "# The baseline of the verification: how each check of scripts/verify.conf"
    echo "# ended in its first run, before any change, recorded by"
    echo "# ./scripts/verify.sh --baseline. A check that failed here and still fails"
    echo "# is shown as KNOWN: a pre-existing failure, not a regression, which still"
    echo "# fails the verification until it is fixed or the owner accepts it with"
    echo "# 'accepted-failure: <check> <reason>' in scripts/verify.conf. Not edited by"
    echo "# hand; a change of this file needs the owner's approval."
    echo "recorded-at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "commit: $(git -C "$root" rev-parse -q --verify HEAD 2>/dev/null || echo none)"
    for ((index = 0; index < project_count; index++)); do
      [[ -z "${outcomes[$index]:-}" ]] || printf '%s\n' "${outcomes[$index]}"
    done
  } >"$baseline_file"
  [[ "$recordable" -eq 0 ]] || verification_forget "$root"
  echo
  echo "Baseline recorded in $baseline_relative. Commit it with the adoption; it is not a verification, and no pass was recorded."
  if [[ "$failed" -ne 0 ]]; then
    echo "The baseline has failures: ./scripts/verify.sh shows them as KNOWN and does not pass until each is fixed or accepted by the owner." >&2
    exit 1
  fi
  exit 0
fi

if [[ "$partial" -eq 0 ]]; then
  hand_budgets_to_run
  hand_durations_to_run
fi

if [[ "$failed" -ne 0 ]]; then
  [[ "$recordable" -eq 0 ]] || verification_forget "$root"
  echo "Verification failed." >&2
  exit 1
fi

# A partial run passed its own checks and says nothing about the others: an
# existing record is left as it is, and none is written.
if [[ "$partial" -eq 1 && "$changed_mode" -eq 1 ]]; then
  echo "The checks that --changed selects passed. Not a verification: the full ./scripts/verify.sh runs after the session."
  exit 0
fi
if [[ "$partial" -eq 1 ]]; then
  echo "The checks of the groups ${only//,/, } passed. Not a verification: run ./scripts/verify.sh without --only for that."
  exit 0
fi

# Record the pass for the content that was verified. When a check changed a
# file, no single content was verified, so nothing is recorded.
if [[ "$recordable" -eq 1 ]]; then
  if [[ -n "$tree_before" && "$(fingerprint_worktree "$root" "$scratch")" == "$tree_before" ]]; then
    if [[ ! -f "$workflow_config" ]]; then
      workflow_state="none"
    elif [[ -n "$workflow_skipped" ]]; then
      workflow_state="skipped"
    else
      workflow_state="ran"
    fi
    verification_write "$root" "$tree_before" "$workflow_state" "$budgets_file" "$durations_file" ||
      echo "Warning: could not record the passed verification." >&2
  else
    verification_forget "$root"
  fi
fi

echo "Verification passed."
