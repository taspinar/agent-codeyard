#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

usage() {
  echo "Usage: $0 run [--max-parallel <n>] [--min-free-gb <n>]"
  echo "       $0 stop | resume"
  echo "       $0 reset <issue-number>"
  echo
  echo "Runs the features of the queue file .agents/queue.conf of the primary"
  echo "checkout, one line per Issue:"
  echo
  echo "  351"
  echo "  352 after-merge 351"
  echo "  353 after-merge 351 after-merge 352 agents=.agents/agents-fast.conf"
  echo
  echo "'after-merge <n>' starts the Issue only when a pull request of feature/<n>-*"
  echo "is merged; nothing else is a dependency, also not two features that change"
  echo "the same files. 'agents=<file>' runs it with that agent configuration"
  echo "(AGENT_CONFIG_FILE), relative to the primary checkout."
  echo
  echo "run: one pass, which can be repeated at any time (by hand, cron, launchd):"
  echo "  1. a feature whose pull request was merged: git pull --ff-only in the"
  echo "     primary checkout, then ./scripts/cleanup-worktree.sh <issue>;"
  echo "  2. an open pull request of the queue that conflicts with its base:"
  echo "     ./scripts/update-feature.sh <issue> in its worktree, in the background;"
  echo "     when it stops, status.sh names the owner decision, and it is not tried"
  echo "     again until the pull request or its base changes;"
  echo "  3. every Issue whose dependencies are merged and that has not run yet:"
  echo "     ./scripts/run-feature.sh <issue> in the background,"
  echo "     up to --max-parallel steps at a time (default 2)."
  echo "  Every running step in .agents/queue/ counts, also one of an Issue that was"
  echo "  removed from the queue file. Nothing new starts below --min-free-gb"
  echo "  gigabytes of free space where the worktrees are (default 15), read right"
  echo "  before every start; it is the space free at that moment, and no space is"
  echo "  reserved for the worktree that the step makes. Nor does a step start in a"
  echo "  worktree whose lock another session holds (lib/records.sh). A run that"
  echo "  ended is not started again; reset lets the queue start it once more (not"
  echo "  while a pass is going on)."
  echo "  The process, the log, and the exit"
  echo "  status of every step are in .agents/queue/<issue>/, and the state of every"
  echo "  Issue in .agents/queue/overview.json, which status.sh shows."
  echo
  echo "stop: ends the queue: the running steps finish, nothing new starts, and no"
  echo "worktree is removed; a pass that is going on starts nothing more, and stop"
  echo "returns when it has ended. resume undoes it."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/base.sh"

[[ $# -ge 1 ]] || usage
action="$1"
shift
max_parallel=2
min_free_gb=15
reset_issue=""
case "$action" in
  run)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --max-parallel)
          [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || fail "--max-parallel takes a number of at least 1."
          max_parallel="$2"
          shift
          ;;
        --min-free-gb)
          [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail "--min-free-gb takes a whole number of gigabytes."
          min_free_gb="$2"
          shift
          ;;
        *) usage ;;
      esac
      shift
    done
    ;;
  stop | resume) [[ $# -eq 0 ]] || usage ;;
  reset)
    [[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]] || usage
    reset_issue="$1"
    ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required."
primary="$(records_primary)"
[[ -n "$primary" && -d "$primary" ]] || fail "run it inside a checkout of the repository."
primary="$(cd "$primary" && pwd -P)"
current="$(git rev-parse --show-toplevel 2>/dev/null)" || current=""
[[ -n "$current" && "$(cd "$current" && pwd -P)" == "$primary" ]] ||
  fail "run queue.sh from the primary checkout ($primary): it starts the runs there and removes merged worktrees."

queue_file="$primary/.agents/queue.conf"
state="$primary/.agents/queue"
git -C "$primary" check-ignore -q ".agents/queue/overview.json" 2>/dev/null ||
  fail "Git does not ignore .agents/queue/, where the queue keeps its processes and logs. Take over the template's .gitignore with ./scripts/sync-template.sh."
mkdir -p "$state" || fail "$state cannot be created."

case "$action" in
  stop)
    printf 'since=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$state/stopped"
    # A pass that is going on reads the marker again before every pull,
    # cleanup and start, and ends at its next one: stop returns when it has
    # ended, so that nothing starts after it.
    if holder="$(records_lock_holder "$state/lock")"; then
      echo "Waiting for the queue.sh run that is going on to end: $(records_lock_describe "$holder")."
      while records_lock_holder "$state/lock" >/dev/null; do sleep 0.2; done
    fi
    echo "The queue is stopped: the running steps finish, and queue.sh run starts nothing new until ./scripts/queue.sh resume."
    exit 0
    ;;
  resume)
    rm -f "${state:?}/stopped"
    echo "The queue runs again from the next ./scripts/queue.sh run."
    exit 0
    ;;
esac

# ------------------------------------------------------------ the steps

# step_state <issue> <kind>: the state of the step 'run' or 'update' of an
# Issue: 'none' (never started), 'running', 'ended <status>', or 'ended
# unknown' (its process is gone without an exit status: killed).
step_state() {
  local dir="$state/$1"
  local process

  if [[ -f "$dir/$2.exit" ]]; then
    printf 'ended %s\n' "$(sed -n 1p "$dir/$2.exit")"
  elif [[ -f "$dir/$2.process" ]]; then
    process="$(cat "$dir/$2.process")"
    if records_lock_stale "$process"; then
      # Read again: the step may have ended between the two reads.
      if [[ -f "$dir/$2.exit" ]]; then
        printf 'ended %s\n' "$(sed -n 1p "$dir/$2.exit")"
      else
        echo "ended unknown"
      fi
    else
      echo running
    fi
  else
    echo none
  fi
}

# start_step <issue> <kind> <directory> <command>...: starts the command in
# the directory, in the background and detached from this run, with its
# output in .agents/queue/<issue>/<kind>.log and its exit status in
# <kind>.exit when it ends.
start_step() {
  local issue="$1"
  local kind="$2"
  local directory="$3"
  local dir="$state/$1"
  local pid

  shift 3
  [[ -n "$issue" && -n "$kind" && -d "$directory" ]] || return 1
  mkdir -p "$dir"
  rm -f "$dir/$kind.exit" "$dir/$kind.process"
  nohup bash -c 'cd "$1" || exit 1
exit_file="$2"
shift 2
status=0
"$@" </dev/null || status=$?
printf "%s\n" "$status" >"$exit_file.tmp" && mv "$exit_file.tmp" "$exit_file"' \
    queue-step "$directory" "$dir/$kind.exit" "$@" >"$dir/$kind.log" 2>&1 </dev/null &
  pid=$!
  disown "$pid" 2>/dev/null || true
  printf 'pid=%s\nstarted=%s\ncommand=%s\nsince=%s\n' "$pid" "$(records_process_started "$pid")" "$*" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$dir/$kind.process"
  echo "Started #$issue: $* (PID $pid, log .agents/queue/$issue/$kind.log)"
}

if [[ "$action" == reset ]]; then
  # Under the lock of the queue: a pass could start a step of the Issue
  # between the check and the removal.
  lock_status=0
  records_lock_take "$state/lock" "queue.sh reset" || lock_status=$?
  case "$lock_status" in
    0) trap 'records_lock_release "$state/lock" "$RECORDS_LOCK_OWNER"' EXIT ;;
    1) fail "a queue.sh run is going on: $(records_lock_describe "$RECORDS_LOCK_HOLDER"); run reset again when it has ended." ;;
    *) fail "the lock of the queue cannot be created in $state/lock." ;;
  esac
  [[ "$(step_state "$reset_issue" run)" != running && "$(step_state "$reset_issue" update)" != running ]] ||
    fail "a step of #$reset_issue is running; it is not reset."
  rm -f "${state:?}/$reset_issue/run.exit" "${state:?}/$reset_issue/run.process" \
    "${state:?}/$reset_issue/update.exit" "${state:?}/$reset_issue/update.process" "${state:?}/$reset_issue/update.key"
  echo "#$reset_issue is reset: the next ./scripts/queue.sh run starts it when it is ready."
  exit 0
fi

# One run of the queue at a time: a second one (cron and a run by hand) ends
# at once, without a word of failure.
queue_lock="$state/lock"
lock_status=0
records_lock_take "$queue_lock" "queue.sh run" || lock_status=$?
case "$lock_status" in
  0) trap 'records_lock_release "$queue_lock" "$RECORDS_LOCK_OWNER"' EXIT ;;
  1)
    echo "Another queue.sh run is going on: $(records_lock_describe "$RECORDS_LOCK_HOLDER"). Nothing was done."
    exit 0
    ;;
  *) fail "the lock of the queue cannot be created in $queue_lock." ;;
esac

# ------------------------------------------------------------ the queue file

[[ -f "$queue_file" ]] || fail "there is no queue file $queue_file. Write one line per Issue: '<issue> [after-merge <n>]... [agents=<file>]'."
order=()
declare -A depends=()
declare -A agents=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_number=$((line_number + 1))
  line="${line%%#*}"
  read -r -a words <<<"$line"
  [[ ${#words[@]} -gt 0 ]] || continue
  issue="${words[0]}"
  [[ "$issue" =~ ^[0-9]+$ ]] || fail "$queue_file, line $line_number: '$issue' is no Issue number."
  [[ -z "${depends[$issue]+set}" ]] || fail "$queue_file, line $line_number: #$issue is listed twice."
  depends[$issue]=""
  agents[$issue]=""
  for ((i = 1; i < ${#words[@]}; i++)); do
    word="${words[$i]}"
    case "$word" in
      after-merge)
        dependency="${words[$((i + 1))]:-}"
        [[ "$dependency" =~ ^[0-9]+$ ]] || fail "$queue_file, line $line_number: 'after-merge' takes an Issue number."
        [[ "$dependency" != "$issue" ]] || fail "$queue_file, line $line_number: #$issue cannot wait for its own merge."
        depends[$issue]+="${depends[$issue]:+ }$dependency"
        i=$((i + 1))
        ;;
      agents=*)
        file="${word#agents=}"
        [[ -n "$file" ]] || fail "$queue_file, line $line_number: 'agents=' names no file."
        [[ "$file" == /* ]] || file="$primary/$file"
        [[ -f "$file" ]] || fail "$queue_file, line $line_number: the agent configuration $file does not exist."
        agents[$issue]="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
        ;;
      *) fail "$queue_file, line $line_number: unknown word '$word'; a line is '<issue> [after-merge <n>]... [agents=<file>]'." ;;
    esac
  done
  order+=("$issue")
done <"$queue_file"
[[ ${#order[@]} -gt 0 ]] || fail "the queue file $queue_file lists no Issue."

# ------------------------------------------------------------ GitHub

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed; without it no merge can be seen."

# pr_list <fields> <arguments of gh pr list>: every pull request of the
# query as one JSON array, repeated with a larger limit until nothing is cut
# off (as status.sh).
pr_list() {
  local fields="$1" limit=200 result
  shift

  while :; do
    result="$(cd "$primary" && gh pr list "$@" --limit "$limit" --json "$fields" 2>/dev/null)" || return 1
    jq -e 'type == "array"' <<<"$result" >/dev/null 2>&1 || return 1
    if [[ "$(jq length <<<"$result")" -lt "$limit" ]]; then
      printf '%s' "$result"
      return 0
    fi
    limit=$((limit * 5))
  done
}

open_prs="$(pr_list number,headRefName,headRefOid,mergeable --state open)" ||
  fail "GitHub could not be read with 'gh'; nothing was started, since no merge can be seen."
merged_prs="$(pr_list number,headRefName --state merged)" ||
  fail "GitHub could not be read with 'gh'; nothing was started, since no merge can be seen."

# is_merged <issue>: a pull request of feature/<issue>-* is merged.
is_merged() {
  jq -e --arg prefix "feature/$1-" 'any(.[]; .headRefName | startswith($prefix))' <<<"$merged_prs" >/dev/null
}

# open_pr <issue>: the open pull request of feature/<issue>-*, or nothing.
open_pr() {
  jq -c --arg prefix "feature/$1-" '[.[] | select(.headRefName | startswith($prefix))] | sort_by(.number) | last // empty' <<<"$open_prs"
}

# worktree_of <issue>: the path of the worktree of feature/<issue>-*.
worktree_of() {
  git -C "$primary" worktree list --porcelain | awk -v prefix="refs/heads/feature/$1-" '
    /^worktree / { path = substr($0, 10) }
    /^branch / && index($2, prefix) == 1 { print path; exit }'
}

# lock_holder <issue>: the holder of the worktree lock of the Issue in one
# line, or nothing when it is free.
lock_holder() {
  local dir held

  dir="$(cd "$primary" && records_worktree_lock_dir feature "$1")" || return 0
  held="$(records_lock_holder "$dir")" || return 0
  records_lock_describe "$held"
}

# ------------------------------------------------------------ the limits

# is_stopped: whether queue.sh stop was given, read again before every
# pull, cleanup and start of a step; once it is, the rest of the pass starts
# nothing.
stopped=0
is_stopped() {
  [[ "$stopped" -eq 1 || ! -f "$state/stopped" ]] || stopped=1
  [[ "$stopped" -eq 1 ]]
}
is_stopped || true

# check_disk: sets disk_reason when the free space where the worktrees are
# made (the directory around the primary checkout, start-feature.sh) is
# below the limit. It is read again right before every start, since a step
# that started earlier in the pass uses space; it checks the space that is
# free at that moment and reserves none. QUEUE_FREE_KB is not read: a test
# puts a fake 'df' on PATH.
worktree_parent="$(dirname "$primary")"
disk_reason=""
check_disk() {
  local free_kb

  free_kb="$(df -Pk -- "$worktree_parent" 2>/dev/null | awk 'NR == 2 { print $4 }')" || free_kb=""
  disk_reason=""
  if [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
    disk_reason="the free space of $worktree_parent cannot be read with df; nothing new starts"
  elif [[ "$free_kb" -lt $((min_free_gb * 1024 * 1024)) ]]; then
    disk_reason="$((free_kb / 1024 / 1024)) GB free in $worktree_parent, below the limit of $min_free_gb GB for a new run (a worktree can take about 9 GB); free space, then run ./scripts/queue.sh run"
  fi
  [[ -z "$disk_reason" ]]
}

# Every running step counts toward --max-parallel, also one of an Issue that
# was removed from the queue file while it ran: its step directory stays.
running=0
for dir in "$state"/*/; do
  issue="$(basename "$dir")"
  [[ "$issue" =~ ^[0-9]+$ ]] || continue
  [[ "$(step_state "$issue" run)" != running ]] || running=$((running + 1))
  [[ "$(step_state "$issue" update)" != running ]] || running=$((running + 1))
done

# ------------------------------------------------------------ after a merge

declare -A reason=()
declare -A decision=()
declare -A phase=()
pulled=0
for issue in "${order[@]}"; do
  is_merged "$issue" || continue
  phase[$issue]="merged"
  reason[$issue]="its pull request is merged"
  ! is_stopped || continue
  worktree="$(worktree_of "$issue")"
  if [[ -z "$worktree" ]]; then
    continue
  fi
  if [[ "$(step_state "$issue" run)" == running || "$(step_state "$issue" update)" == running || -n "$(lock_holder "$issue")" ]]; then
    reason[$issue]="its pull request is merged; its worktree is removed when its session has ended"
    continue
  fi
  ! is_stopped || continue
  if [[ "$pulled" -eq 0 ]]; then
    pulled=1
    if git -C "$primary" pull -q --ff-only; then
      echo "Updated the primary checkout: $(git -C "$primary" log -1 --format='%h %s')"
    else
      echo "Warning: git pull --ff-only failed in $primary; cleanup-worktree.sh tries to update it for the base of the feature." >&2
    fi
  fi
  ! is_stopped || continue
  mkdir -p "$state/$issue"
  cleanup_status=0
  (cd "$primary" && ./scripts/cleanup-worktree.sh "$issue") >"$state/$issue/cleanup.log" 2>&1 </dev/null || cleanup_status=$?
  sed 's/^/  /' "$state/$issue/cleanup.log"
  if [[ "$cleanup_status" -ne 0 ]]; then
    kept="$(grep -m 1 -E '^(Kept|Error)' "$state/$issue/cleanup.log" || true)"
    decision[$issue]="the worktree of the merged #$issue was not removed: ${kept:-cleanup-worktree.sh failed (status $cleanup_status)}; see .agents/queue/$issue/cleanup.log, then run ./scripts/cleanup-worktree.sh $issue"
  fi
done

# The bases of the open pull requests, as the primary checkout knows them
# after one fetch: an update that stopped is tried again only when the pull
# request or its base changed.
fetched=0

# ------------------------------------------------------------ conflicts

for issue in "${order[@]}"; do
  [[ -z "${phase[$issue]:-}" ]] || continue
  pr="$(open_pr "$issue")"
  [[ -n "$pr" ]] || continue
  number="$(jq -r .number <<<"$pr")"
  phase[$issue]="published"
  reason[$issue]="pull request #$number is open"
  [[ "$(jq -r '.mergeable // ""' <<<"$pr")" == CONFLICTING ]] || continue
  worktree="$(worktree_of "$issue")"
  update="$(step_state "$issue" update)"
  if [[ "$update" == running ]]; then
    reason[$issue]="pull request #$number conflicts with its base; update-feature.sh is bringing it up to date"
    continue
  fi
  if [[ -z "$worktree" ]]; then
    reason[$issue]="pull request #$number conflicts with its base, and the feature has no worktree here"
    continue
  fi
  if [[ "$fetched" -eq 0 ]]; then
    fetched=1
    git -C "$primary" fetch -q origin 2>/dev/null || true
  fi
  base="$(branch_base "$worktree" 2>/dev/null)" || base=""
  key="$(jq -r '.headRefOid // ""' <<<"$pr") $(git -C "$primary" rev-parse -q --verify "origin/${base:-main}" 2>/dev/null || true)"
  if [[ "$update" == ended* && "$(cat "$state/$issue/update.key" 2>/dev/null)" == "$key" ]]; then
    if [[ "$update" != "ended 0" ]]; then
      why="$(grep -E '^Error: ' "$state/$issue/update.log" 2>/dev/null | tail -n 1 | sed 's/^Error: //' || true)"
      reason[$issue]="pull request #$number conflicts with its base, and update-feature.sh stopped"
      decision[$issue]="update-feature.sh could not bring #$number up to date (${update#ended }): ${why:-see the log}; resolve it in $worktree (log .agents/queue/$issue/update.log), then run ./scripts/update-feature.sh $issue there"
    fi
    continue
  fi
  holder="$(lock_holder "$issue")"
  # The free space now, before the stop marker is read for the last time.
  check_disk || true
  if is_stopped; then
    reason[$issue]="pull request #$number conflicts with its base; the queue is stopped"
  elif [[ -n "$holder" ]]; then
    reason[$issue]="pull request #$number conflicts with its base; its worktree is busy: $holder"
  elif [[ -n "$disk_reason" ]]; then
    reason[$issue]="pull request #$number conflicts with its base; $disk_reason"
    decision[$issue]="free disk space: $disk_reason"
  elif [[ "$running" -ge "$max_parallel" ]]; then
    reason[$issue]="pull request #$number conflicts with its base; $running of $max_parallel steps are running"
  else
    mkdir -p "$state/$issue"
    printf '%s\n' "$key" >"$state/$issue/update.key"
    start_step "$issue" update "$worktree" ./scripts/update-feature.sh "$issue"
    running=$((running + 1))
    reason[$issue]="pull request #$number conflicts with its base; update-feature.sh is bringing it up to date"
  fi
done

# ------------------------------------------------------------ new runs

for issue in "${order[@]}"; do
  [[ -z "${phase[$issue]:-}" ]] || continue
  run="$(step_state "$issue" run)"
  case "$run" in
    running)
      phase[$issue]="running"
      reason[$issue]="run-feature.sh runs (log .agents/queue/$issue/run.log)"
      continue
      ;;
    "ended 0")
      phase[$issue]="finished"
      reason[$issue]="run-feature.sh ended with status 0 and no pull request is open"
      continue
      ;;
    ended*)
      phase[$issue]="stopped"
      reason[$issue]="run-feature.sh ended with status ${run#ended }; the queue does not start it again (status.sh names the decision; ./scripts/queue.sh reset $issue lets the queue start it again)"
      continue
      ;;
  esac
  phase[$issue]="waiting"
  waits=""
  for dependency in ${depends[$issue]}; do
    is_merged "$dependency" || waits+="${waits:+, }#$dependency"
  done
  if [[ -n "$waits" ]]; then
    reason[$issue]="waits for the merge of $waits"
    continue
  fi
  holder="$(lock_holder "$issue")"
  # The free space now, before the stop marker is read for the last time.
  check_disk || true
  if is_stopped; then
    reason[$issue]="ready; the queue is stopped (./scripts/queue.sh resume)"
  elif [[ -n "$holder" ]]; then
    reason[$issue]="ready; its worktree is busy: $holder"
  elif [[ -n "$disk_reason" ]]; then
    reason[$issue]="ready; $disk_reason"
    decision[$issue]="free disk space: $disk_reason"
  elif [[ "$running" -ge "$max_parallel" ]]; then
    reason[$issue]="ready; $running of $max_parallel steps are running (--max-parallel)"
  else
    command=(./scripts/run-feature.sh "$issue")
    [[ -z "${agents[$issue]}" ]] || command=(env "AGENT_CONFIG_FILE=${agents[$issue]}" ./scripts/run-feature.sh "$issue")
    start_step "$issue" run "$primary" "${command[@]}"
    running=$((running + 1))
    phase[$issue]="running"
    reason[$issue]="run-feature.sh runs (log .agents/queue/$issue/run.log)"
  fi
done

# ------------------------------------------------------------ the overview

overview="$(for issue in "${order[@]}"; do
  jq -cn --argjson issue "$issue" --arg phase "${phase[$issue]:-}" --arg reason "${reason[$issue]:-}" \
    --arg decision "${decision[$issue]:-}" --argjson stopped "$stopped" \
    '{issue: $issue, phase: $phase, reason: $reason, decision: $decision, stopped: ($stopped == 1)}'
done | jq -sc .)"
printf '%s\n' "$overview" >"$state/overview.json.tmp" && mv "$state/overview.json.tmp" "$state/overview.json" ||
  fail "the overview could not be kept in $state/overview.json."

[[ "$stopped" -eq 0 ]] || echo "The queue is stopped: nothing new starts until ./scripts/queue.sh resume."
jq -r '.[] | "#\(.issue)  \(.phase): \(.reason)" + (if .decision != "" then "\n  owner decision: \(.decision)" else "" end)' <<<"$overview"
