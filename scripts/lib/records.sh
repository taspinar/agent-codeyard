#!/usr/bin/env bash

# Run records: how long every step of a feature or a planning cycle took, and
# how many tokens its agents used. Source this file; it needs jq.
#
# The workflow scripts and the agent adapter record; agents estimate nothing.
# A run is one execution of a workflow command that the human started:
# `run-feature.sh 12`, `review-feature.sh 12`, `revise-planning.sh ...`. The
# commands that such a run starts itself belong to it, so nothing is counted
# twice. A resumed feature is a new run that names the run before it.
#
# Where the records are:
# - while the work runs: one file per run, appended to and never rewritten,
#   in .agents/run/records/ of the primary checkout. All worktrees of the
#   repository write there, so a record survives the removal of a worktree,
#   and two runs never write to the same file;
#   No script removes a run file, so a run is read from its file alone, and
#   every reader takes the runs of a subject by the subject of their start.
# The directory is ignored by Git and nothing is sent to GitHub. It lives on
# one machine: a new clone or `git clean -fdx` does not keep it.
#
# Every line is one JSON object with the fields "schema", "run", "time"
# (UTC), "epoch" (seconds), and "type":
#   run-start    kind ("feature" or "planning"), subject (the Issue number
#                or the name of the planning), command, previous (the run
#                before it of the same subject, or null), repository,
#                versions (template commit, prompts, agents.conf)
#   run-end      status (exit status; 130 for an interruption), and for a
#                status other than 0 step and reason: those of the last stop
#                event of the run
#   stop         step, reason: where and why a workflow script stops, as it
#                tells the user: the script, or the step of run-feature.sh
#   step         name, status, seconds: a step of run-feature.sh
#   wait         name, seconds: a pause before a step is tried again
#   verification status, seconds, reused, groups (always "all": a --only run
#                is not recorded), budgets: the budget checks of the run
#                (name, status "exceeded" or "within", exit, output), empty
#                without one, and checks: the duration of every check that
#                ran (name, config, seconds, result "pass", "fail", or
#                "budget"), empty for a reused pass
#   agent-call   role, profile, agent, model, status, seconds, usage, and
#                level and selection: the risk level of the feature that
#                selected the agent (null for a planning or an analysis)
#                and where the selection came from ("command-line",
#                "level-line", "plain-line"; lib/agent.sh)
#   intervention what: something the human did that a script observed
#   note         step, outcome, reason, action: a line of the log of
#                run-feature.sh, which is written from the same call
#   issue-comments issue, role, passed, authors, left_out, others,
#                workflow: the Issue comments a step passed on to its agent
#                and what it left out (lib/issue-comments.sh)
#   risk         when, level, reasons: the risk level of the feature
#                (lib/risk.sh) as run-feature.sh printed it, or the level of
#                the first session of start-feature.sh; and hints, when the
#                owner gave one: each with level and source ("issue-label"
#                or "command-line")
# A run without a run-end was interrupted and is incomplete.
#
# usage holds what the provider reported, with its own field names, and
# "source" says where it came from: "claude-result", "codex-events",
# "interactive" (a session in the human's terminal reports nothing), or
# "unavailable". A figure the provider did not report is null, never zero.
# "total_input" adds up what the provider counts as input: for Claude the
# input, cache creation, and cache read tokens, which it reports apart; for
# Codex the input tokens, which already include the cached ones.
#
# Nothing here may change the outcome of a step: a record that cannot be
# written is reported on standard error and the work goes on. No prompt, no
# secret, and no transcript is written.

RECORDS_SCHEMA="run-record/v1"

# records_primary: prints the path of the primary checkout of the repository
# that the current directory belongs to.
records_primary() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree / { print substr($0, 10); exit }'
}

# records_run_dir: prints the directory of the files of the runs.
records_run_dir() {
  local primary

  primary="$(records_primary)"
  [[ -n "$primary" ]] || return 1
  printf '%s/.agents/run/records' "$primary"
}

records_warn() {
  echo "Warning: the run record could not be written ($*); the work goes on." >&2
}

# records_append <json-object>: appends one line to the file of the current
# run. Does nothing outside a run.
records_append() {
  [[ -n "${RECORDS_FILE:-}" ]] || return 0
  if ! printf '%s\n' "$1" >>"$RECORDS_FILE" 2>/dev/null; then
    records_warn "$RECORDS_FILE is not writable"
  fi
  return 0
}

# records_emit <type> [jq-options...] <jq-object-expression>
# Writes one event of the current run: the common fields, followed by the
# fields that the expression builds from the --arg and --argjson options
# given before it.
# The jq definition that replaces what looks like a secret in text: a private
# key with its whole body, an API key, or a token. Every event passes it, so no
# reason, note, or record copies one.
RECORDS_REDACT_JQ='def redact:
  gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"; "[redacted]")
  | gsub("(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"; "[redacted]");
def redact_all: walk(if type == "string" then redact else . end);
'

records_emit() {
  local type="$1"
  local expression
  local line

  shift
  [[ -n "${RECORDS_RUN_ID:-}" && $# -ge 1 ]] || return 0
  expression="${*: -1}"
  set -- "${@:1:$#-1}"
  line="$(jq -cn --arg _schema "$RECORDS_SCHEMA" --arg _run "$RECORDS_RUN_ID" --arg _type "$type" \
    --arg _time "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --argjson _epoch "$(date +%s)" "$@" \
    "$RECORDS_REDACT_JQ ({schema: \$_schema, run: \$_run, time: \$_time, epoch: \$_epoch, type: \$_type} + ($expression)) | redact_all" 2>/dev/null)" || {
    records_warn "the event '$type' could not be built"
    return 0
  }
  records_append "$line"
}

# records_versions: prints the versions that make runs comparable, as JSON.
records_versions() {
  local root
  local template=""
  local prompts=""
  local agents=""

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="."
  if [[ -f "$root/.agents/template.conf" ]]; then
    template="$(sed -n 's/^commit:[[:space:]]*//p' "$root/.agents/template.conf" | head -n 1)"
  fi
  # In the template itself the workflow is its own commit.
  [[ -n "$template" ]] || template="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  if compgen -G "$root/.agents/prompts/*.md" >/dev/null; then
    prompts="$(cat "$root"/.agents/prompts/*.md | git hash-object --stdin 2>/dev/null || true)"
  fi
  if [[ -f "$root/.agents/agents.conf" ]]; then
    agents="$(git hash-object "$root/.agents/agents.conf" 2>/dev/null || true)"
  fi
  jq -cn --arg template "$template" --arg prompts "$prompts" --arg agents "$agents" \
    '{template: $template, prompts: $prompts, agents_conf: $agents} | with_entries(select(.value != ""))'
}

# records_repository: prints owner/name of the origin remote, or the name of
# the directory; never a URL, which can carry credentials.
records_repository() {
  local url

  url="$(git remote get-url origin 2>/dev/null)" || url=""
  url="${url%.git}"
  if [[ "$url" =~ [:/]([^/:]+/[^/:]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    basename "$(records_primary)"
  fi
}

# records_sequence <kind> <subject> <run>: gives the run the next number of
# its subject and prints "<number>\t<previous run>". A number is claimed by a
# symbolic link from the number to the run, which only one run can create:
# two runs that start at once get different numbers, and each finds the run
# just before it by its link, without a lock that a killed run could leave
# behind. The first number has no run before it.
records_sequence() {
  local links
  local n=0
  local previous=""
  local entry

  links="$(records_run_dir)/.sequence/$1-$2"
  mkdir -p "$links" 2>/dev/null || return 1
  for entry in "$links"/*; do
    entry="${entry##*/}"
    if [[ "$entry" =~ ^[0-9]+$ ]] && [[ "$entry" -gt "$n" ]]; then
      n="$entry"
    fi
  done
  n=$((n + 1))
  until ln -s "$3" "$links/$n" 2>/dev/null; do
    [[ -L "$links/$n" ]] || return 1
    n=$((n + 1))
  done
  if [[ "$n" -gt 1 ]]; then
    previous="$(readlink "$links/$((n - 1))" 2>/dev/null)" || previous=""
  fi
  printf '%s\t%s' "$n" "$previous"
}

# records_begin <kind> <subject> <command>
# Starts a run and exports it to the commands this one starts. Does nothing
# when a run is already going on: the command belongs to that run.
records_begin() {
  local kind="$1"
  local subject="$2"
  local command="$3"
  local dir
  local previous

  [[ -z "${RECORDS_RUN_ID:-}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(records_run_dir)" || return 0
  # Records are never committed: without the ignore rule nothing is recorded,
  # since the file would become part of what is reviewed and committed.
  if ! git -C "$(records_primary)" check-ignore -q ".agents/run/records/run.jsonl" 2>/dev/null; then
    echo "Note: no run record is kept, because Git does not ignore .agents/run/. Take over the template's .gitignore with ./scripts/sync-template.sh." >&2
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    records_warn "$dir cannot be created"
    return 0
  fi
  # The scripts run with errexit: nothing here may end them. A run follows
  # the run with the number before its own; whole seconds and run ids do not
  # tell runs apart that start in the same second.
  local latest
  local seq=""
  # The file of the run is created here, and only by this run: subshells of
  # one process share its id and may draw the same $RANDOM, so an id that
  # another run took is replaced by the next.
  local attempt=0
  while true; do
    RECORDS_RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-$$-$RANDOM"
    RECORDS_FILE="$dir/$RECORDS_RUN_ID.jsonl"
    if (set -o noclobber; : >"$RECORDS_FILE") 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    if [[ "$attempt" -ge 50 ]]; then
      records_warn "no file of its own could be created for the run in $dir"
      unset RECORDS_RUN_ID RECORDS_FILE
      return 0
    fi
  done
  if latest="$(records_sequence "$kind" "$subject" "$RECORDS_RUN_ID" 2>/dev/null)"; then
    seq="${latest%%$'\t'*}"
    previous="${latest#*$'\t'}"
  else
    records_warn "the run of $kind $subject got no number; it names no previous run"
    previous=""
  fi
  # The command that started the run, so that a command can tell whether it
  # runs as its own run or within another.
  RECORDS_COMMAND="$command"
  RECORDS_KIND="$kind"
  RECORDS_SUBJECT="$subject"
  export RECORDS_RUN_ID RECORDS_FILE RECORDS_COMMAND RECORDS_KIND RECORDS_SUBJECT
  local repository
  local versions
  repository="$(records_repository 2>/dev/null)" || repository=""
  versions="$(records_versions 2>/dev/null)" || versions='{}'
  [[ -n "$versions" ]] || versions='{}'
  records_emit run-start --arg kind "$kind" --arg subject "$subject" --arg command "$command" \
    --arg previous "$previous" --arg seq "$seq" --arg repository "$repository" --argjson versions "$versions" \
    '{kind: $kind, subject: $subject, command: $command, seq: (if $seq == "" then null else ($seq | tonumber) end), previous: (if $previous == "" then null else $previous end),
      repository: $repository, versions: $versions}'
  records_resumption "$kind" "$subject" "$previous" 2>/dev/null || true
}

# records_previous_end <run>: prints "<status> <epoch>" of the end of a run,
# or nothing when it has none.
records_previous_end() {
  local dir

  dir="$(records_run_dir)" || return 0
  [[ -f "$dir/$1.jsonl" ]] || return 0
  jq -r 'select(.type == "run-end") | "\(.status) \(.epoch)"' "$dir/$1.jsonl" 2>/dev/null | tail -n 1 || true
}

# records_feature_worktree <issue>: prints the worktree of feature/<issue>-*.
records_feature_worktree() {
  git worktree list --porcelain 2>/dev/null |
    awk -v prefix="refs/heads/feature/$1-" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if (index($2, prefix) == 1) { print path; exit } }' || true
}

# records_mtime <path>: the time of the last change of <path>, in epoch
# seconds, or 0 when it cannot be read. The form is that of the stat on PATH
# (GNU 'stat -c', or BSD 'stat -f'), not of the system: on macOS GNU
# coreutils may come first on PATH.
records_mtime() {
  if stat -c '%Y' -- / >/dev/null 2>&1; then
    stat -c '%Y' -- "$1" 2>/dev/null || echo 0
  else
    stat -f '%m' "$1" 2>/dev/null || echo 0
  fi
}

# records_resumption <kind> <subject> <previous-run>
# Records what a script can see between the previous run of the subject and
# this one, without claiming who did it: this run follows a run that stopped
# with a status other than 0, and, for a feature, whether its handoff note
# changed after that stop. A person, a scheduler or a retry can each start a
# run, and any write changes the note, so this is a resumed event, not an
# intervention. Nothing of the note is recorded.
records_resumption() {
  local previous_end
  local status
  local ended
  local note
  local changed
  local note_changed="null"

  [[ -n "$3" ]] || return 0
  previous_end="$(records_previous_end "$3")"
  [[ -n "$previous_end" ]] || return 0
  status="${previous_end%% *}"
  ended="${previous_end##* }"
  [[ "$status" != "0" ]] || return 0
  if [[ "$1" == "feature" ]]; then
    note="$(records_feature_worktree "$2")/.agents/handoffs/$2.md"
    note_changed="false"
    if [[ -f "$note" ]]; then
      changed="$(records_mtime "$note")"
      [[ "$changed" -le "$ended" ]] || note_changed="true"
    fi
  fi
  records_emit resumed --arg after "$3" --argjson status "$status" --argjson changed "$note_changed" \
    '{after: $after, previous_status: $status, handoff_changed: $changed}'
}

# records_end <status>: ends the current run.
records_end() {
  local stop="null"

  # Why the run stopped: the last stop that a script of the run recorded. A
  # run that ends otherwise gets one here, so that no failed run is without
  # its step and reason.
  if [[ "${1:-0}" != "0" && -n "${RECORDS_FILE:-}" ]]; then
    if [[ "${1:-0}" == "130" ]]; then
      records_stop "${RECORDS_COMMAND:-unknown}" "interrupted"
    else
      stop="$(jq -c -s 'map(select(.type == "stop")) | last // null' "$RECORDS_FILE" 2>/dev/null)" || stop="null"
      [[ -n "$stop" && "$stop" != "null" ]] ||
        records_stop "${RECORDS_COMMAND:-unknown}" "exited with status ${1:-0} without a recorded reason"
    fi
    stop="$(jq -c -s 'map(select(.type == "stop")) | last // null | if . == null then null else {step, reason} end' "$RECORDS_FILE" 2>/dev/null)" || stop="null"
    [[ -n "$stop" ]] || stop="null"
  fi
  # The experience record of a feature run (lib/experience.sh), before its
  # end. A verification on its own has nothing to observe beyond its result.
  if [[ "${RECORDS_KIND:-}" == "feature" && "${RECORDS_COMMAND##*/}" != "verify.sh" ]] &&
    declare -F experience_record >/dev/null; then
    experience_record "${1:-0}" || records_warn "the experience record of the run could not be made"
  fi
  records_emit run-end --argjson status "${1:-0}" --argjson stop "$stop" \
    '{status: $status} + (if $stop == null then {} else {step: $stop.step, reason: $stop.reason} end)'
  return 0
}

# records_wrap <kind> <subject> <script> <argument>...
# Runs the script as a run of its own when no run is going on, and exits with
# its status; returns at once inside a run, so that the caller goes on. The
# script runs as a child, so its own traps and exits stay as they are, and the
# end of the run is recorded also when it fails. An interruption ends the run
# with status 130; a run that is killed has no end and stays incomplete.
# Inside a run, the script gets a trap that records an unexpected exit.
records_wrap() {
  local kind="$1"
  local subject="$2"
  local script="$3"
  local status=0

  shift 3
  if [[ -n "${RECORDS_RUN_ID:-}" ]]; then
    records_trap_unexpected
    return 0
  fi
  # One session or verification in a worktree at a time (records_worktree_lock).
  [[ -z "$subject" ]] || records_worktree_lock "$kind" "$subject" "$(basename "$script")" || exit 75
  [[ -z "${RECORDS_DISABLED:-}" && -n "$subject" ]] || return 0
  records_begin "$kind" "$subject" "$(basename "$script")"
  if [[ -z "${RECORDS_RUN_ID:-}" ]]; then
    # The run could not be started; the work goes on without a record.
    RECORDS_DISABLED=1 "$script" "$@" || status=$?
    records_worktree_unlock
    exit "$status"
  fi
  trap 'records_end 130; records_worktree_unlock; exit 130' INT TERM
  "$script" "$@" || status=$?
  trap - INT TERM
  records_end "$status"
  records_worktree_unlock
  exit "$status"
}

# ------------------------------------------------------------ the worktree lock
#
# A run of a feature or a planning (records_wrap) holds the lock of its
# subject while it runs, so that a worktree never has two sessions or two
# verifications at the same time: a second run-feature.sh, start-feature.sh,
# update-feature.sh, finish-feature.sh, or full verify.sh of the same Issue is
# refused with status 75 and the holder named (Issue 364). The commands that
# a run starts itself, its agent sessions among them, are inside the holder:
# they inherit WORKFLOW_WORKTREE_LOCK, the id of the lock, and pass. The name
# has no TOKEN, KEY, or SECRET in it, which Codex removes from the
# environment of its sessions.
#
# The lock is the directory <git-common-dir>/workflow-locks/<kind>-<subject>
# with its file 'owner': the same for every worktree of the repository, also
# before the feature's worktree exists, and never part of the content. The
# run that creates 'owner' (an exclusive create, noclobber) holds it, as the
# lock of status.sh --changes. A lock whose holder is gone (its PID does not
# exist or now belongs to a process with another start time) is stale and is
# taken over under a second lock; a holder that cannot be inspected holds it.
# A lock that cannot be created (a read-only Git directory) is reported and
# the work goes on, as with a record that cannot be written.

# records_process_started <pid>: the start time of the process, or nothing.
records_process_started() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

# records_process_exists <pid>: 0 when it exists, 1 when it confirmedly does
# not, 2 when that cannot be told.
records_process_exists() {
  local out

  out="$(export LC_ALL=C; kill -0 -- "$1" 2>&1)" && return 0
  [[ "$out" != *"No such process"* ]] || return 1
  return 2
}

# records_lock_field <owner-text> <field>
records_lock_field() {
  sed -n "s/^$2=//p" <<<"$1" | sed -n 1p
}

# records_lock_stale <owner-text>: whether the holder is confirmedly gone.
records_lock_stale() {
  local pid started now exists=0

  pid="$(records_lock_field "$1" pid)"
  started="$(records_lock_field "$1" started)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  records_process_exists "$pid" || exists=$?
  case "$exists" in
    0)
      now="$(records_process_started "$pid")"
      [[ -n "$now" && -n "$started" && "$now" != "$started" ]]
      ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}

# records_lock_old <dir>: whether the directory is older than a minute; a
# lock without an owner is being taken, or was left by a run killed while it
# took it.
records_lock_old() {
  local mtime

  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -gt 0 && -e "$1" && $(($(date +%s) - mtime)) -gt 60 ]]
}

# records_lock_holder <dir>: prints the owner text of the lock and succeeds
# when a process that exists (or cannot be inspected) holds it; fails when
# the lock is free or stale.
records_lock_holder() {
  local owner

  [[ -d "$1" ]] || return 1
  owner="$(cat "$1/owner" 2>/dev/null)" || owner=""
  if [[ -z "$owner" ]]; then
    ! records_lock_old "$1" || return 1
    printf 'pid=\ncommand=a run that is taking the lock\n'
    return 0
  fi
  ! records_lock_stale "$owner" || return 1
  printf '%s\n' "$owner"
}

# records_lock_describe <owner-text>: the holder in one line.
records_lock_describe() {
  local pid command since worktree

  pid="$(records_lock_field "$1" pid)"
  command="$(records_lock_field "$1" command)"
  since="$(records_lock_field "$1" since)"
  worktree="$(records_lock_field "$1" worktree)"
  printf '%s' "${command:-a run}"
  [[ -z "$pid" ]] || printf ' (PID %s' "$pid"
  [[ -z "$since" ]] || printf ', since %s' "$since"
  [[ -z "$worktree" ]] || printf ', in %s' "$worktree"
  [[ -z "$pid" ]] || printf ')'
}

# records_lock_take <dir> <command>: takes the lock. Status 0 when taken
# (RECORDS_LOCK_OWNER holds its text), 1 when another holder has it
# (RECORDS_LOCK_HOLDER holds its text), 2 when it cannot be created.
records_lock_take() {
  local dir="$1"
  local owner
  local tries=0
  local recover="$dir.recover"

  RECORDS_LOCK_HOLDER=""
  RECORDS_LOCK_OWNER="$(printf 'pid=%s\nstarted=%s\nid=%s-%s-%s\ncommand=%s\nworktree=%s\nsince=%s' \
    "$$" "$(records_process_started "$$")" "$$" "$(date +%s)" "$RANDOM" "$2" \
    "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  mkdir -p "${dir%/*}" 2>/dev/null || return 2
  while [[ "$tries" -lt 5 ]]; do
    tries=$((tries + 1))
    if mkdir "$dir" 2>/dev/null; then
      if (set -C && printf '%s\n' "$RECORDS_LOCK_OWNER" >"$dir/owner") 2>/dev/null; then
        return 0
      fi
    fi
    [[ -d "$dir" ]] || return 2
    if RECORDS_LOCK_HOLDER="$(records_lock_holder "$dir")"; then
      return 1
    fi
    # Stale: removed under the recovery lock, only when it is still the lock
    # that was seen and, checked again under that lock, still stale (or,
    # without an owner, old): another run may have taken it between the
    # check above and the recovery lock.
    owner="$(cat "$dir/owner" 2>/dev/null)" || owner=""
    if ! mkdir "$recover" 2>/dev/null; then
      records_lock_old "$recover" && rmdir "$recover" 2>/dev/null && mkdir "$recover" 2>/dev/null || continue
    fi
    if [[ -d "$dir" && "$(cat "$dir/owner" 2>/dev/null)" == "$owner" ]] && ! records_lock_holder "$dir" >/dev/null; then
      rm -rf "$dir"
    fi
    rmdir "$recover" 2>/dev/null || true
  done
  RECORDS_LOCK_HOLDER="$(records_lock_holder "$dir")" || RECORDS_LOCK_HOLDER="command=a run that keeps taking the lock"
  return 1
}

# records_lock_release <dir> <owner-text>: removes the lock when it names
# the owner.
records_lock_release() {
  [[ -n "$2" && "$(cat "$1/owner" 2>/dev/null)" == "$2" ]] || return 0
  rm -rf "$1" 2>/dev/null || true
}

# records_worktree_lock_dir <kind> <subject>: the directory of the lock of
# a feature or a planning of the repository of the current directory.
records_worktree_lock_dir() {
  local common

  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  common="$(cd "$common" 2>/dev/null && pwd -P)" || return 1
  printf '%s/workflow-locks/%s-%s' "$common" "$1" "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
}

# records_worktree_lock <kind> <subject> <command>: takes the lock of the
# subject for this run, or passes inside the run that holds it. Fails, with
# the holder named on standard error, when another run holds it.
RECORDS_WORKTREE_LOCK_DIR=""
records_worktree_lock() {
  local dir
  local held
  local status=0

  [[ "$1" == feature || "$1" == planning ]] || return 0
  dir="$(records_worktree_lock_dir "$1" "$2")" || return 0
  if [[ -n "${WORKFLOW_WORKTREE_LOCK:-}" ]] && held="$(records_lock_holder "$dir")" &&
    [[ "$(records_lock_field "$held" id)" == "$WORKFLOW_WORKTREE_LOCK" ]]; then
    return 0
  fi
  records_lock_take "$dir" "$3" || status=$?
  case "$status" in
    0)
      RECORDS_WORKTREE_LOCK_DIR="$dir"
      WORKFLOW_WORKTREE_LOCK="$(records_lock_field "$RECORDS_LOCK_OWNER" id)"
      export WORKFLOW_WORKTREE_LOCK
      ;;
    1)
      echo "Error: the $1 $2 has a session or a verification running already: $(records_lock_describe "$RECORDS_LOCK_HOLDER"). $3 does not start a second one in the same worktree; nothing was changed. Wait until it has ended, or stop exactly that process (kill <PID>); a lock whose process is gone is taken over by itself ($dir)." >&2
      return 1
      ;;
    *) echo "Warning: the lock of the $1 $2 could not be created in $dir; $3 runs without it." >&2 ;;
  esac
  return 0
}

# records_worktree_unlock: releases the lock that this run took.
records_worktree_unlock() {
  [[ -n "$RECORDS_WORKTREE_LOCK_DIR" ]] || return 0
  records_lock_release "$RECORDS_WORKTREE_LOCK_DIR" "$RECORDS_LOCK_OWNER"
  RECORDS_WORKTREE_LOCK_DIR=""
}

# records_stop <step> <reason>: where and why a workflow script stops: the
# script, or the step of run-feature.sh, and the text that it tells the user.
# The end of the run carries the last one (records_end).
records_stop() {
  records_emit stop --arg step "$1" --arg reason "$2" '{step: $step, reason: $reason}'
}

# records_trap_unexpected: records the exit of the calling script that a
# failing command causes under errexit, with the command, so that no stop is
# without a reason. The trap is inherited by functions (errtrace) and changes
# no exit status.
records_trap_unexpected() {
  set -E
  trap 'records_unexpected "$?" "$BASH_COMMAND" "$LINENO"' ERR
}

# records_unexpected <status> <command> <line>: the trap of
# records_trap_unexpected. The ERR trap also runs where errexit does not apply,
# as in a command substitution; that is no exit. A stop that is the last
# event already explains this one: a script that stopped inside a command
# substitution, whose failure ends the script around it.
records_unexpected() {
  local last

  [[ "$-" == *e* && -n "${RECORDS_FILE:-}" ]] || return 0
  last="$(tail -n 1 "$RECORDS_FILE" 2>/dev/null | jq -r '.type' 2>/dev/null)" || last=""
  [[ "$last" != "stop" ]] || return 0
  records_stop "${0##*/}" "unexpected exit: the command '$2' on line $3 failed with status $1"
}

# records_intervention <what>: records something the human did.
records_intervention() {
  records_emit intervention --arg what "$1" \
    '{what: $what}'
}

# records_usage <provider> <profile> <output-file>
# Prints the usage that a provider reported for one call, as JSON.
records_usage() {
  local provider="$1"
  local profile="$2"
  local output_file="$3"
  local envelope="$output_file.envelope"
  local events="$output_file.events"


  if [[ "$profile" == "write" ]]; then
    jq -cn '{source: "interactive"}'
    return 0
  fi
  case "$provider" in
    claude)
      if [[ -s "$envelope" ]] && jq -e '(.usage | type) == "object"' "$envelope" >/dev/null 2>&1; then
        jq -c '.usage as $u | {
            source: "claude-result",
            input_tokens: ($u.input_tokens // null),
            output_tokens: ($u.output_tokens // null),
            cache_creation_input_tokens: ($u.cache_creation_input_tokens // null),
            cache_read_input_tokens: ($u.cache_read_input_tokens // null)
          }
          | .total_input = (if .input_tokens == null or .cache_creation_input_tokens == null or .cache_read_input_tokens == null
              then null
              else .input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens end)' "$envelope"
        return 0
      fi
      ;;
    codex)
      if [[ -s "$events" ]]; then
        # One event per turn; the turns of a call add up.
        # One event per completed turn; a turn whose usage is absent, null, or
        # lacks a field counts as a turn that did not report it. A field that
        # a turn did not report is null for the call, so that an incomplete
        # sum never passes for a total; what the other turns reported is kept
        # apart, under "partial". Lines that are not JSON are left out: the
        # events are read line by line.
        jq -cRs '[split("\n")[] | select(length > 0) | (try fromjson catch null) | objects] as $events
          | ([$events[] | select(.type == "turn.completed")]
             | if length > 0 then map(.usage | if type == "object" then . else {} end)
               else [$events[] | .usage? | objects] end) as $turns
          | def field($name): [$turns[] | .[$name]] as $values
              | if ($values | all(type == "number")) then {total: ($values | add), partial: null}
                elif ($values | any(type == "number")) then {total: null, partial: ([$values[] | numbers] | add)}
                else {total: null, partial: null} end;
          if ($turns | length) == 0 then {source: "unavailable"} else
            (field("input_tokens")) as $input | (field("cached_input_tokens")) as $cached | (field("output_tokens")) as $output
            | {
                source: "codex-events",
                turns: ($turns | length),
                turns_without_usage: ([$turns[] | select(length == 0)] | length),
                input_tokens: $input.total,
                cached_input_tokens: $cached.total,
                output_tokens: $output.total,
                total_input: $input.total
              }
            + ({input_tokens: $input.partial, cached_input_tokens: $cached.partial, output_tokens: $output.partial}
                | with_entries(select(.value != null)) | if length == 0 then {} else {partial: .} end)
          end' "$events" 2>/dev/null && return 0
      fi
      ;;
  esac
  jq -cn '{source: "unavailable"}'
}

# records_agent_start <id> <role> <profile> <provider> <model> [<level>] [<selection>]
# An agent call begins. A start without its agent-call is a call that was
# interrupted. <level> is the risk level that selected the agent, empty when
# the role runs without one, and <selection> where the selection came from.
records_agent_start() {
  records_emit agent-start --arg id "$1" --arg role "$2" --arg profile "$3" --arg agent "$4" --arg model "$5" \
    --arg level "${6:-}" --arg selection "${7:-}" \
    '{id: $id, role: $role, profile: $profile, agent: $agent, model: $model,
      level: (if $level == "" then null else $level end), selection: (if $selection == "" then null else $selection end)}'
}

# records_agent_call <role> <profile> <provider> <model> <seconds> <status> <output-file> [<id>] [<level>] [<selection>]
records_agent_call() {
  local usage

  [[ -n "${RECORDS_RUN_ID:-}" ]] || return 0
  usage="$(records_usage "$3" "$2" "$7" 2>/dev/null)" || usage=""
  [[ -n "$usage" ]] || usage='{"source": "unavailable"}'
  records_emit agent-call --arg role "$1" --arg profile "$2" --arg agent "$3" --arg model "$4" \
    --argjson seconds "$5" --argjson status "$6" --argjson usage "$usage" --arg id "${8:-}" \
    --arg level "${9:-}" --arg selection "${10:-}" \
    '{role: $role, profile: $profile, agent: $agent, model: $model, status: $status, seconds: $seconds, usage: $usage,
      level: (if $level == "" then null else $level end), selection: (if $selection == "" then null else $selection end)}
     + (if $id == "" then {} else {id: $id} end)'
}

# records_feature_events <issue> [jq-options...] <jq-program>
# Runs <jq-program> over the array of the events of feature <issue>, with
# the --arg options given before it, and prints its raw output: the events
# of the runs whose start names the feature; the runs of another feature or
# of a planning never count. Every run is read once, from its own file.
# Nothing when there is no record or no jq.
records_feature_events() {
  local issue="$1"
  local program
  local dir
  local files=()
  local file

  shift
  program="${*: -1}"
  set -- "${@:1:$#-1}"
  command -v jq >/dev/null 2>&1 || return 0
  dir="$(records_run_dir)" || return 0
  for file in "$dir"/*.jsonl; do
    [[ -f "$file" ]] && files+=("$file")
  done
  [[ "${#files[@]}" -gt 0 ]] || return 0
  cat "${files[@]}" 2>/dev/null | jq -c -R 'fromjson? | objects' 2>/dev/null |
    jq -rs --arg subject "$issue" "$@" '
      [.[] | select(.type == "run-start" and .kind == "feature" and (.subject | tostring) == $subject) | .run] as $runs
      | [.[] | select(.run as $run | any($runs[]; . == $run))]
      | '"$program" 2>/dev/null || true
}

# records_highest_level <issue>
# Prints the highest risk level that the records of feature <issue> hold:
# the levels run-feature.sh noted ('risk' events) and the levels at which
# its agents were started (records_feature_events). Nothing when there is no
# record or no level. A script that starts a role raises the level it
# computed to this one, so a later session never runs at a weaker configured
# level than an earlier one did.
records_highest_level() {
  records_feature_events "$1" '
    [.[] | select((.type == "risk" or .type == "agent-start" or .type == "agent-call") and (.level | type) == "string")
         | .level | {low: 0, medium: 1, high: 2}[.] // empty]
    | if length == 0 then empty else (max | ["low", "medium", "high"][.]) end'
}

# records_role_providers <issue> <role>
# Prints the providers that <role> ran with for feature <issue>, one per
# line, each followed by a tab and the number of its calls: the agent calls
# of the runs of the feature (records_feature_events), and the starts of
# calls that were interrupted. A session started with --agent on the command
# line counts with the provider it ran with, not the configured one.
# Nothing when the role has no recorded call.
records_role_providers() {
  records_feature_events "$1" --arg role "$2" '
    [.[] | select(.type == "agent-call" and .role == $role and (.agent | type) == "string")] as $calls
    | [$calls[] | .id // empty] as $ids
    | $calls + [.[] | select(.type == "agent-start" and .role == $role and (.agent | type) == "string"
                            and (.id as $id | any($ids[]; . == $id) | not))]
    | group_by(.agent) | .[] | "\(.[0].agent)\t\(length)"'
}

# records_id: prints an identifier for a pair of start and end events.
records_id() {
  printf '%s-%s%s' "$(date +%s)" "$RANDOM" "$RANDOM"
}

# records_step_start <id> <name>: a step of run-feature.sh begins. A start
# without its end is a step that was interrupted.
records_step_start() {
  records_emit step-start --arg id "$1" --arg name "$2" '{id: $id, name: $name}'
}

# records_step <name> <status> <seconds> [<id>]: a step of run-feature.sh
# ended.
records_step() {
  records_emit step --arg name "$1" --argjson status "$2" --argjson seconds "$3" --arg id "${4:-}" \
    '{name: $name, status: $status, seconds: $seconds} + (if $id == "" then {} else {id: $id} end)'
}

# records_wait_start <id> <name> <planned-seconds>: a pause before a step is
# tried again begins; records_wait records how long it really took.
records_wait_start() {
  records_emit wait-start --arg id "$1" --arg name "$2" --argjson planned "$3" '{id: $id, name: $name, planned: $planned}'
}

# records_wait <name> <seconds> [<id>]: a pause ended after <seconds>.
records_wait() {
  records_emit wait --arg name "$1" --argjson seconds "$2" --arg id "${3:-}" \
    '{name: $name, seconds: $seconds} + (if $id == "" then {} else {id: $id} end)'
}

# records_note <step> <outcome> <reason> <action>: a line of the log of
# run-feature.sh.
# records_gate <worktree> <status> <reasons>: one check of the completion
# gate, with its outcome, its reasons, one per line, and the fingerprint of
# the content it judged (lib/fingerprint.sh), so that two checks on one commit
# stay apart. It names the implementing sessions of the run before it, as the
# run recorded them: every session of the implementer or the triage
# implementer, a repair or a retry too, and the last of them, the session it
# judges. A check without a session since the one before judges the same
# session again.
records_gate() {
  local content=""
  local scratch
  local sessions='{"count": 0, "last": null}'

  [[ -n "${RECORDS_FILE:-}" ]] || return 0
  if declare -F fingerprint_worktree >/dev/null && scratch="$(mktemp -d "${TMPDIR:-/tmp}/records-gate.XXXXXX" 2>/dev/null)"; then
    content="$(fingerprint_worktree "$1" "$scratch" 2>/dev/null)" || content=""
    rm -rf "$scratch"
  fi
  if [[ -f "$RECORDS_FILE" ]]; then
    sessions="$(jq -cs '[.[] | select(.type == "agent-start" and (.role == "implementer" or .role == "triage-implementer"))]
      | {count: length, last: (last | if . == null then null else .id end)}' "$RECORDS_FILE" 2>/dev/null)" ||
      sessions='{"count": null, "last": null}'
  fi
  RECORDS_GATE_CHECKS=$((${RECORDS_GATE_CHECKS:-0} + 1))
  records_emit completion-gate --argjson check "$RECORDS_GATE_CHECKS" --argjson sessions "$sessions" \
    --arg status "${2:-}" --arg reasons "${3:-}" --arg content "$content" \
    '{check: $check, sessions: $sessions.count, session: $sessions.last, status: $status,
      reasons: ($reasons | split("\n") | map(select(length > 0))),
      content: (if $content == "" then null else $content end)}'
}

# records_artifact <kind> <path>: a review or a triage that this run wrote,
# by its path in the worktree, so that its experience record names what the
# run produced and nothing of another run.
records_artifact() {
  records_emit artifact --arg kind "$1" --arg path "$2" '{kind: $kind, path: $path}'
}

# records_findings <review-json>: one 'finding' event per finding of a stored
# feature review: its round, id, and severity, and previous when it continues
# an earlier finding, so that a report can count the re-raises.
records_findings() {
  local finding

  [[ -n "${RECORDS_RUN_ID:-}" ]] || return 0
  while IFS= read -r finding; do
    [[ -n "$finding" ]] || continue
    records_emit finding --argjson finding "$finding" '$finding'
  done < <(jq -c '.round as $round | .findings[]?
    | {round: $round, id, severity} + (if (.previous | type) == "object" then {previous: (.previous | {round, id, relation})} else {} end)' "$1" 2>/dev/null)
}

# records_risk <when> <level> <reasons> [<profile>] [<hints>]: the risk
# level of the feature and its reasons, one per line, at a moment of the run,
# the workflow profile of the risk policy ('light', 'standard', or 'none'),
# and the owner's hints, one '<level> <source>' per line (lib/risk.sh).
records_risk() {
  records_emit risk --arg when "$1" --arg level "$2" --arg reasons "$3" --arg profile "${4:-}" --arg hints "${5:-}" \
    '{when: $when, level: $level, reasons: ($reasons | split("\n") | map(select(length > 0)))}
     + (if $profile == "" then {} else {profile: $profile} end)
     + ($hints | split("\n") | map(select(length > 0) | split(" ") | {level: .[0], source: (.[1] // "")})
        | if length == 0 then {} else {hints: .} end)'
}

records_note() {
  records_emit note --arg step "$1" --arg outcome "$2" --arg reason "$3" --arg action "$4" \
    '{step: $step, outcome: $outcome, reason: $reason, action: $action}'
}

# records_verification_start <id> <groups>: a verification begins. A start
# without its end is a verification that was interrupted.
records_verification_start() {
  records_emit verification-start --arg id "$1" --arg groups "$2" '{id: $id, groups: $groups}'
}

# records_verification <status> <seconds> <reused> <groups> [<id>] [<budgets>] [<checks>] [<trusted>] [<origin>]
# <budgets> is a JSON array of the budget results of the run
# (lib/verification.sh, verification_budgets_json); an empty array without
# a budget check. <checks> is a JSON array of the durations of the checks
# that ran (verification_durations_json); an empty array without one.
# <trusted> is 'true' when the pass counts as evidence under the trust
# contract, 'false' otherwise (the default), and <origin> who started the
# verification: 'orchestrator', 'script', 'agent-session', or 'manual' (the
# default; lib/verification.sh, verification_origin).
records_verification() {
  local budgets="${6:-[]}"
  local checks="${7:-[]}"
  local trusted="${8:-false}"
  local origin="${9:-manual}"

  jq -e 'type == "array"' <<<"$budgets" >/dev/null 2>&1 || budgets='[]'
  jq -e 'type == "array"' <<<"$checks" >/dev/null 2>&1 || checks='[]'
  [[ "$trusted" == "true" ]] || trusted=false
  records_emit verification --argjson status "$1" --argjson seconds "$2" --argjson reused "$3" --arg groups "$4" --arg id "${5:-}" \
    --argjson budgets "$budgets" --argjson checks "$checks" --argjson trusted "$trusted" --arg origin "$origin" \
    '{status: $status, seconds: $seconds, reused: $reused, groups: $groups, budgets: $budgets, checks: $checks, trusted: $trusted, origin: $origin} + (if $id == "" then {} else {id: $id} end)'
}

# records_branch_issue: prints the Issue number of the feature branch that is
# checked out, or nothing.
records_branch_issue() {
  git branch --show-current 2>/dev/null | sed -n 's#^feature/\([0-9][0-9]*\)-.*#\1#p'
}

# The experience records belong to the runs; a copy of this file without them
# records the runs only.
if [[ -f "${BASH_SOURCE[0]%/*}/experience.sh" ]]; then
  source "${BASH_SOURCE[0]%/*}/experience.sh"
fi
