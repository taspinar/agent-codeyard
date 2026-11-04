#!/usr/bin/env bash

# Checks the mapping of an optional parallel CI onto the groups of checks
# (docs/development.md, "A parallel CI"). The default CI is one job that runs
# ./scripts/verify.sh --all and needs none of this.
#
# The mapping is declared, never read from commands: a job declares the group
# it runs, and a check declares the partition it runs. This script checks the
# declarations; it does not look at what a step or a check runs.
#
# Three checks, each on its own or together:
#
# - --workflow <file>: every group that ./scripts/verify.sh --groups prints is
#   declared by exactly one job of the workflow file, as the job-level
#   'env: VERIFY_GROUP: <group>', in a job named 'group-<group>'. A group no
#   job declares, a group two jobs declare, a group verify.sh does not know,
#   a group from an expression, a job 'group-<group>' without a declaration,
#   and a VERIFY_GROUP outside the env of a job fail. The job runs
#   './scripts/verify.sh --all --only "$VERIFY_GROUP"'.
# - --tests <pathspec> --partition <file>...: where one suite is split over
#   several checks, every file that <pathspec> matches is listed in exactly
#   one partition file, every listed file is such a file, and every
#   partition file is declared by exactly one check of scripts/verify.conf,
#   as '<name> [<group>] partition <file>: <command>'. A partition no check
#   declares, two checks declare, or that does not exist fails, and so does
#   a declared partition that is not given with --partition. A new test file
#   that no partition lists fails, so it cannot drop out of CI.
# - --results <json> [--may-skip <job>...]: the aggregate job. <json> is
#   '${{ toJSON(needs) }}' of the job. Every group has its job 'group-<group>'
#   in it, and every job in it succeeded. A failed, cancelled, or skipped job
#   fails, and so does a missing one. --may-skip names a job that is not a
#   group job and may be skipped by a condition of the workflow; a group job
#   may never be skipped.
#
# Exit status: 0 when every requested check holds, 1 when one does not, 2 on
# a usage error.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
  echo "Usage: $0 [--workflow <file>] [--tests <pathspec> --partition <file>...]"
  echo "          [--results <json> [--may-skip <job>...]]"
  echo
  echo "Checks an optional parallel CI against the groups of ./scripts/verify.sh:"
  echo "--workflow that every group is declared by exactly one job 'group-<group>'"
  echo "  (env: VERIFY_GROUP: <group>),"
  echo "--tests with --partition that every test file is in exactly one partition"
  echo "  and every partition is declared by exactly one check (partition <file>),"
  echo "--results that every group job of the aggregate job succeeded."
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 2
}

workflow=""
tests=""
partitions=()
results=""
results_given=0
may_skip=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow | --tests | --partition | --results | --may-skip)
      [[ $# -ge 2 ]] || fail "$1 requires a value."
      case "$1" in
        --workflow) workflow="$2" ;;
        --tests) tests="$2" ;;
        --partition) partitions+=("$2") ;;
        --results)
          results="$2"
          results_given=1
          ;;
        --may-skip) may_skip+=("$2") ;;
      esac
      shift 2
      ;;
    *) usage ;;
  esac
done
[[ -n "$workflow" || -n "$tests" || "$results_given" -eq 1 ]] || usage
[[ -z "$tests" || "${#partitions[@]}" -gt 0 ]] || fail "--tests requires at least one --partition."
[[ -n "$tests" || "${#partitions[@]}" -eq 0 ]] || fail "--partition requires --tests."
[[ "$results_given" -eq 1 || "${#may_skip[@]}" -eq 0 ]] || fail "--may-skip requires --results."

problems=0
problem() {
  echo "FAIL  $*"
  problems=$((problems + 1))
}

# The groups that have a check, one per line.
groups=""
if [[ -n "$workflow" || "$results_given" -eq 1 ]]; then
  groups="$("$root/scripts/verify.sh" --groups)" || fail "./scripts/verify.sh --groups failed."
  [[ -n "$groups" ]] || fail "./scripts/verify.sh --groups printed no group."
fi

# is_group <name>
is_group() {
  printf '%s\n' "$groups" | grep -Fqx -- "$1"
}

if [[ -n "$workflow" ]]; then
  [[ -f "$workflow" ]] || fail "workflow file not found: $workflow"
  # One line per declaration: '<line> <job> decl <group>' for a key
  # VERIFY_GROUP in the env of a job, '<line> <job> misplaced -' for one
  # anywhere else, and '<line> <job> job -' for every job. The indentation
  # gives the structure: the jobs are the keys under 'jobs:', their keys the
  # first indentation below a job, and the env entries the first below 'env:'.
  declarations="$(
    awk '
      /^[[:space:]]*(#.*)?$/ { next }
      {
        indent = match($0, /[^[:space:]]/) - 1
        line = $0
        sub(/[[:space:]]+#.*$/, "", line)
        sub(/[[:space:]]+$/, "", line)
        key = ""
        if (match(line, /^[[:space:]]*[A-Za-z0-9_-]+:([[:space:]]|$)/)) {
          key = substr(line, indent + 1, RLENGTH - indent)
          sub(/:[[:space:]]*$/, "", key)
        }
      }
      indent == 0 { in_jobs = (key == "jobs"); job_indent = -1; job = ""; next }
      !in_jobs { next }
      {
        if (job_indent < 0) job_indent = indent
        if (indent <= job_indent) {
          job = key; prop_indent = -1; in_env = 0
          if (job != "") print NR, job, "job", "-"
        } else if (prop_indent < 0 || indent <= prop_indent) {
          prop_indent = indent
          in_env = (key == "env" && line ~ /:$/); env_indent = -1
        } else if (in_env) {
          if (env_indent < 0) env_indent = indent
          if (indent == env_indent && key == "VERIFY_GROUP") {
            value = substr(line, index(line, ":") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
            if (value == "" || value ~ /[[:space:]]/) value = "!"
            print NR, job, "decl", value
            next
          }
        }
      }
      line ~ /(^|[[:space:]{,-])VERIFY_GROUP[[:space:]]*:([[:space:]]|$)/ { print NR, (job == "" ? "-" : job), "misplaced", "-" }
    ' "$workflow"
  )"
  declared=""
  declaring_jobs=""
  group_jobs=""
  while read -r line job kind group; do
    [[ -n "$line" ]] || continue
    where="$workflow:$line (job $job)"
    case "$kind" in
      job)
        [[ "$job" != group-* ]] || group_jobs+="$job $line"$'\n'
        continue
        ;;
      misplaced)
        problem "$where names VERIFY_GROUP outside the env of a job, so it declares nothing; declare the group as 'env: VERIFY_GROUP: <group>' of the job."
        continue
        ;;
    esac
    declaring_jobs+="$job"$'\n'
    if [[ "$group" == "!" || "$group" == *'$'* || "$group" == *'{'* || "$group" == *,* ]]; then
      problem "$where declares no single group, or one from an expression; write one group in the file, so that the mapping can be checked."
      continue
    fi
    if ! is_group "$group"; then
      problem "$where declares the group $group, which has no check. The groups are: $(printf '%s\n' "$groups" | paste -sd, - | sed 's/,/, /g')."
      continue
    fi
    [[ "$job" == "group-$group" ]] ||
      problem "$where declares the group $group; name the job group-$group, the name the aggregate job looks for."
    declared+="$group"$'\n'
  done <<<"$declarations"
  while read -r job line; do
    [[ -n "$job" ]] || continue
    printf '%s' "$declaring_jobs" | grep -Fqx -- "$job" ||
      problem "$workflow:$line (job $job) declares no group; declare it as 'env: VERIFY_GROUP: ${job#group-}' of the job."
  done <<<"$group_jobs"
  while IFS= read -r group; do
    count="$(printf '%s' "$declared" | grep -Fxc -- "$group" || true)"
    if [[ "$count" -eq 0 ]]; then
      problem "no job of $workflow declares the group $group, so its checks would never run in CI."
    elif [[ "$count" -gt 1 ]]; then
      problem "$count jobs of $workflow declare the group $group; each group is assigned to exactly one job."
    fi
  done <<<"$groups"
  [[ "$problems" -gt 0 ]] || echo "PASS  every group is declared by exactly one job of $workflow"
fi

if [[ -n "$tests" ]]; then
  before="$problems"
  # '<file>\t<check>' for each check that declares a partition.
  declarations="$("$root/scripts/verify.sh" --partitions)" || fail "./scripts/verify.sh --partitions failed."
  files="$(git -C "$root" ls-files --cached --others --exclude-standard -- "$tests" | sort -u)"
  [[ -n "$files" ]] || problem "no file matches the tests $tests."
  while IFS=$'\t' read -r partition check; do
    [[ -n "$partition" ]] || continue
    [[ " ${partitions[*]} " == *" $partition "* ]] ||
      problem "the check $check declares the partition $partition, which is not given with --partition; give every partition of the suite."
  done <<<"$declarations"
  listed=""
  for partition in "${partitions[@]}"; do
    checks="$(printf '%s\n' "$declarations" | awk -F '\t' -v p="$partition" '$1 == p { print $2 }')"
    count="$(printf '%s' "$checks" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
      problem "no check of scripts/verify.conf declares the partition $partition, so its tests would not run; declare it on the check that runs it, as '<name> [<group>] partition $partition: <command>'."
    elif [[ "$count" -gt 1 ]]; then
      problem "the partition $partition is declared by $count checks: $(printf '%s\n' "$checks" | paste -sd, - | sed 's/,/, /g'); each partition is declared by exactly one check."
    fi
    [[ -f "$root/$partition" ]] || {
      problem "the partition $partition does not exist."
      continue
    }
    while IFS= read -r entry || [[ -n "$entry" ]]; do
      [[ "$entry" =~ ^[[:space:]]*(#.*)?$ ]] && continue
      printf '%s\n' "$files" | grep -Fqx -- "$entry" ||
        problem "$partition lists $entry, which is not a file of the tests $tests."
      listed+="$entry"$'\t'"$partition"$'\n'
    done <"$root/$partition"
  done
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    in="$(printf '%s' "$listed" | awk -F '\t' -v f="$file" '$1 == f { print $2 }')"
    count="$(printf '%s' "$in" | grep -c . || true)"
    if [[ "$count" -eq 0 ]]; then
      problem "no partition lists the test $file, so it would not run in CI."
    elif [[ "$count" -gt 1 ]]; then
      problem "the test $file is listed $count times: $(printf '%s\n' "$in" | paste -sd, - | sed 's/,/, /g')."
    fi
  done <<<"$files"
  [[ "$problems" -gt "$before" ]] || echo "PASS  every test of $tests is in exactly one partition, and every partition is declared by exactly one check"
fi

if [[ "$results_given" -eq 1 ]]; then
  before="$problems"
  command -v jq >/dev/null 2>&1 || fail "jq is required."
  for job in ${may_skip[@]+"${may_skip[@]}"}; do
    [[ "$job" != group-* ]] || ! is_group "${job#group-}" ||
      fail "--may-skip $job: a group job may not be skipped; its checks are required."
  done
  jq -e 'type == "object" and all(.[]; type == "object" and (.result | type) == "string")' \
    <<<"$results" >/dev/null 2>&1 ||
    fail "--results is not the needs of a job ('\${{ toJSON(needs) }}'): $results"
  while IFS= read -r group; do
    jq -e --arg job "group-$group" 'has($job)' <<<"$results" >/dev/null ||
      problem "the aggregate job does not need group-$group, so the group $group is not checked."
  done <<<"$groups"
  while IFS=$'\t' read -r job result; do
    [[ -n "$job" ]] || continue
    [[ "$result" != "success" ]] || continue
    allowed=0
    for skip in ${may_skip[@]+"${may_skip[@]}"}; do
      [[ "$result" != "skipped" || "$skip" != "$job" ]] || allowed=1
    done
    if [[ "$allowed" -eq 1 ]]; then
      echo "SKIP  $job (may be skipped)"
    else
      problem "the job $job ended with '$result', not 'success'."
    fi
  done < <(jq -r 'to_entries[] | [.key, .value.result] | @tsv' <<<"$results")
  [[ "$problems" -gt "$before" ]] || echo "PASS  every required job succeeded"
fi

[[ "$problems" -eq 0 ]] || exit 1
