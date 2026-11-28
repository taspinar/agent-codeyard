#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/base.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/github.sh"
source "$script_dir/lib/completion.sh"
source "$script_dir/lib/verification.sh"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/guardrails.sh"
source "$script_dir/lib/exceptions.sh"
source "$script_dir/lib/issue-comments.sh"

MAX_ROUNDS=5
# The most review rounds that --rounds may allow. RUN_FEATURE_ROUNDS_CEILING
# may only lower it (for the self-tests, which cannot afford twenty rounds).
ROUNDS_CEILING=20
if [[ "${RUN_FEATURE_ROUNDS_CEILING:-}" =~ ^[1-9][0-9]*$ && "$RUN_FEATURE_ROUNDS_CEILING" -lt "$ROUNDS_CEILING" ]]; then
  ROUNDS_CEILING="$RUN_FEATURE_ROUNDS_CEILING"
fi
# A session of the implementer that ends without an error has not completed
# the feature by that alone: the completion gate decides. While it does not
# pass, the implementer is resumed, for at most this many sessions in a run.
MAX_SESSIONS="${RUN_FEATURE_SESSIONS:-4}"
# A step that fails on a known transient error (github_transient_error,
# lib/github.sh) is tried again once, after RETRY_WAIT seconds; a step that
# fails otherwise is not tried again. A usage limit that an agent reports is
# tried again RETRIES times, with a wait that starts at four times RETRY_WAIT
# and doubles: the run records showed a limit that ended only after the third
# wait. RUN_FEATURE_RETRIES=0 tries nothing again. A verification that fails
# is repeated once; when it fails again, the implementer repairs it, a limited
# number of times (AGENTS.md).
RETRIES="${RUN_FEATURE_RETRIES:-3}"
RETRY_WAIT="${RUN_FEATURE_RETRY_WAIT:-30}"
LIMIT_WAIT=$((RETRY_WAIT * 4))
MAX_REPAIRS="${RUN_FEATURE_REPAIRS:-3}"
MAX_UNSTABLE=3
repairs=0
unstable=0

usage() {
  echo "Usage: $0 <issue-number> [slug] [base-branch] [--implemented] [--risk <level>] [--rounds <m>]"
  echo "       $0 <issue-number> --owner-finding [--risk <level>] [--rounds <m>]"
  echo
  echo "Runs a feature from its Issue to an open pull request, without questions:"
  echo "start-feature.sh, then review-feature.sh, triage-review.sh, and"
  echo "apply-triage.sh until a review leaves nothing to fix, then finish-feature.sh"
  echo "and publish-feature.sh. Agents run unattended and the triage is approved"
  echo "without you; at most $MAX_ROUNDS review rounds are used, of which the later ones"
  echo "review only the changes since the round before, and the last one reviews the"
  echo "complete feature again. It never merges and never removes a worktree."
  echo
  echo "What the rounds require follows the risk level of the feature and the risk"
  echo "policy of the base (.agents/policies/risk.conf, computed again before every"
  echo "round): the full verification precedes every review, a later round reviews"
  echo "only the changes when the policy allows it ('<level>: review: delta') and the"
  echo "level did not rise, and a low-risk feature is committed without a review when"
  echo "the policy says 'low: review: none'. The feature is always committed on the"
  echo "full verification and, when reviewed, on a review of the complete feature."
  echo
  echo "The review starts only when the completion gate passes: the implementer's"
  echo "completion record says complete (or awaiting_evidence, when only evidence of"
  echo "a later gate is pending), its remaining[] is empty, and it wrote the"
  echo "summary of the changes. The handoff note is context for people and the"
  echo "next session; the gate does not read it. Until then the implementer is"
  echo "resumed, for at most $MAX_SESSIONS sessions in a run."
  echo
  echo "The agent sessions run only the checks of what they changed (verify.sh"
  echo "--changed). The run makes the full verification itself, after the session and"
  echo "before the review, once for each content: the review, a retry of it, the fixes,"
  echo "and the commit reuse that pass instead of verifying again."
  echo
  echo "The run stops with a non-zero status when a step fails or needs you, and"
  echo "says which command continues. Status 3 means that an agent needs a decision"
  echo "of yours. Status 78 means that a prerequisite of this machine is missing"
  echo "(an ENVIRONMENT line of verify.sh): nothing is tried again or repaired;"
  echo "install it. Running the same command"
  echo "again continues where the feature stands: every step that is already done"
  echo "is skipped."
  echo
  echo "A verification that fails twice goes to the implementer for repair, after one"
  echo "question: when the base moved on since the feature started and merges cleanly,"
  echo "the run merges it, says so, and verifies again; only a check that still fails"
  echo "is repaired. A merge that conflicts stops the run with the conflicting files."
  echo
  echo "--implemented says that the implementation in the feature worktree is"
  echo "complete, for example after you finished it in a session of your own, so"
  echo "the run continues with the review without a session of the implementer."
  echo "The completion gate has to pass for that too."
  echo
  echo "--risk low|medium|high is your hint for this run: the level of the feature"
  echo "is at least that, for the agents and for what the rounds require, as with the"
  echo "label 'risk: high' or 'risk: medium' on the Issue. A hint raises the level,"
  echo "never lowers it; one below the computed level is ignored and reported."
  echo
  echo "--rounds <m> raises the limit of review rounds for this run from $MAX_ROUNDS to"
  echo "<m> (at most $ROUNDS_CEILING), to continue a feature that stopped because the"
  echo "rounds were used, without the steps by hand. It is the owner's decision: it is"
  echo "refused in an agent session and without a terminal on standard input, so it"
  echo "never runs unattended, and the run record notes it as an intervention."
  echo
  echo "--owner-finding takes a finding of yours on a finished feature, whose pull"
  echo "request is open, through the same steps in this one process: post the finding"
  echo "as a comment on the Issue first. The run merges the base when it moved, reviews"
  echo "the complete feature when a comment of yours is newer than its latest review"
  echo "and its finish commit, and then triages, fixes, verifies, and reviews the"
  echo "complete feature again, commits the fixes with finish-feature.sh on top of the"
  echo "published commit, and publishes them: the approval request of the new commit"
  echo "covers what is pushed, and the push needs no reset and no force. Every round of"
  echo "it reviews the complete feature, and its round limit counts the rounds after"
  echo "the round the finish commit was made on. It stops where a run stops."
  echo
  echo "Examples:"
  echo "  $0 3"
  echo "  $0 3 site-skeleton develop"
  echo "  $0 3 --risk high"
  echo "  $0 3 --rounds 7"
  echo "  $0 3 --owner-finding"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  records_stop "${0##*/}" "$*"
  exit 1
}

implemented=0
owner_finding=0
rounds=""
arguments=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --implemented) implemented=1 ;;
    --owner-finding) owner_finding=1 ;;
    --rounds)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || usage
      rounds="$2"
      shift
      ;;
    --risk)
      # The owner's hint, which every script of this run reads (lib/risk.sh).
      [[ $# -ge 2 && "$2" =~ ^(low|medium|high)$ ]] || usage
      export WORKFLOW_RISK_HINT="$2"
      shift
      ;;
    --*) usage ;;
    *) arguments+=("$1") ;;
  esac
  shift
done
[[ "${#arguments[@]}" -ge 1 && "${#arguments[@]}" -le 3 ]] || usage
issue="${arguments[0]}"
[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
# What a stop proposes to run again: the same mode.
mode_option=""
[[ "$owner_finding" -eq 0 ]] || mode_option=" --owner-finding"
rerun="$0 $issue$mode_option"
records_wrap feature "$issue" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
[[ "$implemented" -eq 0 ]] || records_intervention "said with --implemented that the implementation is complete"
# --rounds is the owner's decision at a terminal: never an agent's, and never
# a run that nobody watches.
if [[ -n "$rounds" ]]; then
  [[ "${CODEYARD_AGENT_SESSION:-}" != "1" ]] ||
    fail "--rounds raises the limit of review rounds, which only the owner decides; it is refused in an agent session."
  [[ -t 0 ]] ||
    fail "--rounds raises the limit of review rounds, which only the owner decides at a terminal; standard input must be a terminal, so it never runs unattended."
  [[ "$rounds" -gt "$MAX_ROUNDS" && "$rounds" -le "$ROUNDS_CEILING" ]] ||
    fail "--rounds must be more than the $MAX_ROUNDS rounds a run allows anyway, and at most $ROUNDS_CEILING: $rounds"
  records_intervention "raised the limit of review rounds from $MAX_ROUNDS to $rounds with --rounds"
  echo "run-feature.sh: at most $rounds review rounds in this run (--rounds), instead of $MAX_ROUNDS."
  MAX_ROUNDS="$rounds"
fi

review_data_require_jq
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
repo_root="$(git rev-parse --show-toplevel)"

# The trust contract (lib/verification.sh): the trees of the passes that
# this run made itself, with its own calls of verify.sh. The scripts of the
# steps get the list and reuse only such a pass; lib/agent.sh removes it
# from every agent process. A list given to this run is kept.
export VERIFY_TRUSTED_TREES="${VERIFY_TRUSTED_TREES:-}"

# find_worktree: prints the worktrees whose branch belongs to the Issue.
find_worktree() {
  git -C "$repo_root" worktree list --porcelain |
    awk -v prefix="refs/heads/feature/${issue}-" '
      /^worktree / { path = substr($0, 10) }
      /^branch / { if (index($2, prefix) == 1) print path }'
}

# stop <status> <reason> <next-command>...
# Ends the run: where it stopped, why, and what continues it.
stop() {
  local status="$1"
  local reason="$2"

  shift 2
  # The step where the run stopped, as the steps of the run are named.
  records_stop "${run_step:-run-feature.sh}" "$reason"
  {
    echo
    echo "run-feature.sh stopped: $reason"
    if [[ -n "${worktree:-}" ]]; then
      echo "The feature worktree is kept at: $worktree"
    fi
    if [[ $# -gt 0 ]]; then
      echo "To continue:"
      printf '  %s\n' "$@"
    fi
    echo "Then run again: $rerun"
  } >&2
  exit "$status"
}

# note <step> <outcome> <reason> <action>
# Adds one line to the log of the feature, .agents/run/<issue>-log, and shows
# it. The outcome is decided here, from exit statuses and check results.
note() {
  local line

  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ') | $1 | $2 | $3 | $4"
  # The same event in the run record; the log is its readable form.
  records_note "$1" "$2" "$3" "$4"
  echo "run-feature.sh: $2 in '$1': $3. $4"
  if [[ -n "${worktree:-}" && -d "$worktree/.agents" ]]; then
    mkdir -p "$worktree/.agents/run"
    printf '%s\n' "$line" >>"$worktree/.agents/run/$issue-log"
  fi
}

# open_question
# Succeeds when the handoff note of the feature holds a question under
# 'Open questions'. An agent that ends with BLOCKED has to record its
# question there; without one there is nothing for the human to answer.
open_question() {
  local note_file="$worktree/.agents/handoffs/$issue.md"

  [[ -f "$note_file" ]] || return 1
  awk '
    tolower($0) ~ /open questions?/ {
      found = 1
      line = $0
      sub(/.*[Oo]pen [Qq]uestions?[*: ]*/, "", line)
      text = line
      next
    }
    found && /^[[:space:]]*$/ { if (text != "") exit; next }
    found && /^#/ { exit }
    # Another part of the note, such as the clarification line, is no
    # question.
    found && tolower($0) ~ /^[[:space:]]*([-*][[:space:]]*)?\**(done|in progress|remaining( work)?|tried and rejected|clarification)\**[[:space:]]*:/ {
      if (text != "") exit
      found = 0
      next
    }
    found { text = text " " $0 }
    END {
      gsub(/^[[:space:]*:-]+|[[:space:].]+$/, "", text)
      if (text == "" || tolower(text) ~ /^(none|no |n\/a|nothing)/) exit 1
      exit 0
    }' "$note_file"
}

# failing_checks <verification-output>
# Prints the names of the checks that a verification run reports as failed.
# A budget check over its target is BUDGET, not FAIL: it is a measurement
# that the verification passes with, and nothing here repairs it. The output
# of such a check, shown indented under its line, is never a check name.
failing_checks() {
  [[ -f "$1" ]] || return 0
  awk '/^FAIL  / { print $2 }' "$1" | sort -u
}

# retrying <title> <command>...
# Runs a command in the feature worktree and keeps its output in
# .agents/run/<issue>-step.log. A failure that is not a blocked session and
# not a failed verification is tried again only when it is temporary:
#
#   - a usage limit that the agent reported (lib/agent.sh): RETRIES times,
#     after LIMIT_WAIT seconds, a wait that doubles;
#   - a known transient error in the last lines of the output
#     (github_transient_error): once, after RETRY_WAIT seconds.
#
# Any other failure stops: the run records held no step that passed when it
# was tried again after such a failure. Sets step_status to the status of the
# last attempt.
#
# When STEP_REVIEW is set and the content changed since that review, the
# command is repeated with --continue, whatever the failure, once and after
# RETRY_WAIT seconds unless a usage limit sets a longer wait: the fix session
# had started from that review, which is stale now, and apply-triage.sh takes
# up an interrupted session of the same triage only when it is told to.
retrying() {
  local title="$1"
  local limits=0
  local transient=0
  local continued
  local wait
  local log
  local limit
  local action

  shift
  # The script of the step, for a message that names what failed.
  step_command="${1##*/}"
  while true; do
    echo
    echo "=== run-feature.sh: $title ==="
    echo
    log="$worktree/.agents/run/$issue-step.log"
    mkdir -p "$(dirname "$log")"
    step_status=0
    step_started="$(date +%s)"
    step_id="$(records_id)"
    records_step_start "$step_id" "$title"
    run_step="$title"
    (cd "$worktree" && "$@" </dev/null) 2>&1 | tee "$log" || step_status=$?
    records_step "$title" "$step_status" "$(($(date +%s) - step_started))" "$step_id"
    environment_stop "$title" "$step_status" "$log"
    case "$step_status" in
      0 | 3 | 4) return 0 ;;
      5)
        # An agent changed a review, a triage, an exception, or an approval
        # request, which it may only read (the artifact manifest of
        # lib/agent.sh): not a failure that a retry may pass over.
        note "$title" "failed" "an agent changed an artifact that it may only read: a review, a triage, an exception, or an approval request" "Stopping; nothing is tried again"
        return 0
        ;;
    esac
    # A usage limit that an agent reported is the reason, not a defect.
    limit="$(grep -m 1 -o "This is a usage limit of [a-z]*" "$log" 2>/dev/null || true)"
    limit="${limit:+; ${limit#This is }, reported by the agent}"
    continued=0
    if [[ -n "${STEP_REVIEW:-}" ]] && ! (cd "$worktree" && ./scripts/check-review.sh "$STEP_REVIEW" >/dev/null 2>&1); then
      continued=1
    fi
    if [[ -n "$limit" ]]; then
      if [[ "$limits" -ge "$RETRIES" ]]; then
        note "$title" "failed" "the step exited with status $step_status, also after $limits retries$limit" "Stopping"
        return 0
      fi
      wait=$((LIMIT_WAIT << limits))
      limits=$((limits + 1))
      action="retry $limits of $RETRIES in $wait seconds"
    elif [[ "$RETRIES" -gt 0 && "$transient" -eq 0 ]] && github_transient_error "$(tail -n 30 "$log" 2>/dev/null)"; then
      transient=1
      wait="$RETRY_WAIT"
      limit="; a known transient error"
      action="retry once in $wait seconds"
    elif [[ "$RETRIES" -gt 0 && "$continued" -eq 1 ]]; then
      wait="$RETRY_WAIT"
      action="in $wait seconds"
    else
      if [[ "$transient" -eq 1 ]]; then
        note "$title" "failed" "the step exited with status $step_status, also after the retry of a known transient error" "Stopping"
      else
        note "$title" "failed" "the step exited with status $step_status, without a known transient error or a usage limit" "Stopping; a failure that is not transient is not tried again"
      fi
      return 0
    fi
    if [[ "$continued" -eq 1 ]]; then
      note "$title" "temporary" "the step exited with status $step_status after it had changed the content$limit" "Continuing the interrupted session with the same scope, $action"
      STEP_REVIEW=""
      title="$title, continued"
      set -- "$@" --continue
    else
      note "$title" "temporary" "the step exited with status $step_status$limit" "R${action:1}"
    fi
    wait_id="$(records_id)"
    wait_started="$(date +%s)"
    records_wait_start "$wait_id" "$title" "$wait"
    sleep "$wait"
    records_wait "$title" "$(($(date +%s) - wait_started))" "$wait_id"
  done
}

# environment_stop <title> <status> <log>
# Stops the run with status 78 when a step ended because a prerequisite of
# this machine is missing: the status 78 of verify.sh, which review-feature.sh,
# finish-feature.sh, and apply-triage.sh pass on unchanged, or an ENVIRONMENT
# line of its preflight in the output of a step that failed. No code change
# can fix that: nothing is tried again and nothing is repaired, and the
# unstable checks never count it. Returns otherwise.
environment_stop() {
  local title="$1"
  local status="$2"
  local log="$3"
  local missing

  [[ "$status" -ne 0 ]] || return 0
  [[ "$status" -eq 78 ]] || grep -q '^ENVIRONMENT  ' "$log" 2>/dev/null || return 0
  missing="$(sed -n 's/^ENVIRONMENT  //p' "$log" 2>/dev/null | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  note "$title" "environment" "${missing:-a prerequisite of this machine is missing (status 78)}" "Stopping; nothing is tried again or repaired"
  stop 78 "a prerequisite of this machine is missing, which says nothing about this feature: ${missing:-see the ENVIRONMENT lines in .agents/run/$issue-step.log}." \
    "# install what the ENVIRONMENT lines name; ./scripts/doctor.sh lists every prerequisite"
}

# blocked_or_ignored <title>
# Called when a session ended with status 3. A blocked session counts only
# with a question in the handoff note; otherwise step_status becomes 0.
blocked_or_ignored() {
  if open_question; then
    note "$1" "blocked" "an agent needs a decision; its question is in the handoff note" "Stopping"
  else
    note "$1" "completed" "the agent ended with BLOCKED, but the handoff note holds no open question" "Going on"
    step_status=0
  fi
}

# merge_moved_base <step-title>
# Called when checks failed in two verification runs, before the implementer
# is asked to repair them: a check can fail because of the base, which moved
# on since the feature left it, for example when another merge fixed a link
# that the checks follow. Fetches the base; when it moved and merges cleanly,
# merges it into the branch, says so, and succeeds, so that the step is done
# again on the merged content and only a check that still fails goes to the
# implementer. Fails when the base did not move or cannot be read: the
# implementer repairs as before. Stops the run when the merge conflicts with
# the commits of the branch or with the uncommitted work of the feature, when
# it would write over an untracked file, ignored or not, and when the index
# holds staged changes, naming the files, before anything is merged; and when
# the merge leaves behind untracked paths that the branch ignored before it
# (lib/base.sh); nothing is deleted. The texts of its notes and stops are
# those of a failed verification; --owner-finding sets them for the update
# with the base that starts its chain.
base_merges=0
merge_context="the verification fails, and the base moved since the feature started"
merge_cause="checks failed in two verification runs, and the base moved since the feature started"
merge_action="Verifying again; only a check that still fails goes to the implementer"
merge_fallback="Going on with the repair by the implementer"
merge_moved_base() {
  local title="$1"
  local base_ref=""
  local candidate
  local before
  local tree
  local conflicts
  local status=0
  local scratch
  local leftovers
  local overwrites
  local staged

  git -C "$worktree" remote get-url origin >/dev/null 2>&1 &&
    git -C "$worktree" fetch -q origin "$base" </dev/null >/dev/null 2>&1 || true
  for candidate in "origin/$base" "$base"; do
    if git -C "$worktree" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
      base_ref="$candidate"
      break
    fi
  done
  [[ -n "$base_ref" ]] || return 1
  ! git -C "$worktree" merge-base --is-ancestor "$base_ref" HEAD || return 1
  before="$(git -C "$worktree" rev-parse HEAD)"

  # Staged changes first, also where the base changes the same path: a merge
  # refuses them, and unstaging or stashing them would lose a staged version
  # that differs from the file on disk. The run stops and leaves the index as
  # it is.
  staged="$(git -C "$worktree" -c core.quotePath=false diff --cached --name-only)" || {
    note "$title" "base not merged" "the base moved since the feature started, but Git could not read the index" "$merge_fallback"
    return 1
  }
  if [[ -n "$staged" ]]; then
    note "$title" "staged changes" "the base moved since the feature started, but the index holds staged changes in: $(printf '%s' "$staged" | tr '\n' ' ')" "Stopping"
    stop 1 "$merge_context; the index holds staged changes, which a merge of $base_ref refuses, in: $(printf '%s' "$staged" | tr '\n' ' ')- nothing was merged, and the index is unchanged." \
      "cd \"$worktree\"" \
      "git diff --cached    # the staged changes; unstage them with 'git restore --staged <path>' when the file on disk holds what you want, then run the feature again"
  fi
  tree="$(base_merge_conflicts "$worktree" "$base_ref")" || status=$?
  if [[ "$status" -eq 0 ]]; then
    # The merge must not touch a file that the feature changed and did not
    # commit yet: Git would refuse it, and a conflict there is the
    # implementer's work as much as one in a commit.
    conflicts="$(comm -12 \
      <(git -C "$worktree" -c core.quotePath=false diff --name-only HEAD "$tree" | sort -u) \
      <(git -C "$worktree" -c core.quotePath=false status --porcelain --untracked-files=all | cut -c4- | sed 's/^.* -> //' | sort -u))"
  elif [[ "$status" -eq 1 ]]; then
    conflicts="$tree"
  else
    note "$title" "base not merged" "the base moved since the feature started, but Git could not compute the merge with $base_ref" "$merge_fallback"
    return 1
  fi
  if [[ -n "$conflicts" ]]; then
    note "$title" "conflict" "the base moved since the feature started, and its merge conflicts in: $(printf '%s' "$conflicts" | tr '\n' ' ')" "Stopping"
    stop 1 "$merge_context; merging $base_ref conflicts with the feature in: $(printf '%s' "$conflicts" | tr '\n' ' ')" \
      "cd \"$worktree\"" \
      "git stash push --include-untracked -m \"feature $issue before the merge of $base\"    # the uncommitted work of the feature" \
      "git merge $base_ref    # resolve the conflicts, then commit the merge" \
      "git stash pop    # the work again; resolve what meets the base"
  fi

  # Untracked files where the merge writes, ignored ones included: Git would
  # replace an ignored file without a word (lib/base.sh).
  overwrites="$(base_merge_overwrites "$worktree" "$tree")" || {
    note "$title" "base not merged" "the base moved since the feature started, but Git could not tell what its merge writes over" "$merge_fallback"
    return 1
  }
  if [[ -n "$overwrites" ]]; then
    note "$title" "conflict" "the base moved since the feature started, and its merge would write over untracked files of the worktree: $(printf '%s' "$overwrites" | tr '\n' ' ')" "Stopping"
    stop 1 "$merge_context; merging $base_ref would write over untracked files of the worktree, which Git may ignore: $(printf '%s' "$overwrites" | tr '\n' ' ')- nothing was merged or changed." \
      "cd \"$worktree\"" \
      "# move each path above out of the worktree, or remove it after checking that it is not needed"
  fi
  if ! git -C "$worktree" merge -q --no-edit --no-overwrite-ignore "$base_ref" </dev/null >"$worktree/.agents/run/$issue-merge.log" 2>&1; then
    note "$title" "conflict" "the base moved since the feature started, and Git refused its merge: $(grep -m 1 . "$worktree/.agents/run/$issue-merge.log" || true)" "Stopping"
    stop 1 "$merge_context; Git refused the merge of $base_ref (.agents/run/$issue-merge.log)." \
      "cd \"$worktree\"" \
      "git merge $base_ref    # resolve what Git reports, then commit the merge"
  fi
  base_merges=$((base_merges + 1))
  note "$title" "base merged" "$merge_cause: $base_ref merged cleanly ($(git -C "$worktree" rev-parse --short "$before")..$(git -C "$worktree" rev-parse --short HEAD))" "$merge_action"

  if scratch="$(mktemp -d "${TMPDIR:-/tmp}/run-feature-leftovers.XXXXXX" 2>/dev/null)"; then
    leftovers="$(base_leftovers "$worktree" "$before" "$scratch")" || leftovers=""
    rm -rf "$scratch"
    if [[ -n "$leftovers" ]]; then
      note "$title" "leftovers" "the merge of the base left untracked paths that the branch ignored before it: $(printf '%s' "$leftovers" | tr '\n' ' ')" "Stopping; nothing is deleted"
      echo "Left behind by a merge of the base: Git ignored these untracked paths before the merge and does not ignore them now, so the verification and the commit would take them for work of the feature. Nothing was deleted:" >&2
      base_leftover_report "$leftovers" >&2
      stop 1 "the merge of the base left untracked paths that the branch ignored before it; nothing was deleted." \
        "cd \"$worktree\"" \
        "# remove each path above with the command next to it, after checking that it is not yours"
    fi
  fi
}

# repair_verification <step-title>
# Called when the verification failed in a step. Repeats it once and compares
# the checks that failed in both runs. The repeat runs only the checks that
# failed (verify.sh --repeat): on the same content, with the record of the
# failed run, the checks that passed there and the failed ones that pass on
# the repeat are recorded together as the pass of the content, which the
# step done again reuses. When the content changed or the two runs cannot be
# combined for another reason, verify.sh runs every check, as it does when
# the first run names no failed check. A check that failed only once is
# unstable: it is recorded, and the run goes on. For the checks that failed
# twice the implementer is resumed with their names in the handoff note, at
# most MAX_REPAIRS times. Sets step_status to 0 when the run can go on, to 4
# when the verification cannot be repaired here, and to the status of the
# repair session when that failed or is blocked.
repair_verification() {
  local title="$1"
  local first_log="$worktree/.agents/run/$issue-step.log"
  local log="$worktree/.agents/run/$issue-verify.log"
  local first
  local second
  local twice
  local once
  local repeat_status=0
  local repeat=()
  local repeat_scope

  first="$(failing_checks "$first_log")"
  if [[ -n "$first" ]]; then
    repeat=(--repeat "$(printf '%s' "$first" | tr '\n' ',')")
    [[ "${repeat[1]}" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] || repeat=()
  fi
  mkdir -p "$(dirname "$log")"
  (cd "$worktree" && VERIFY_ORIGIN=orchestrator ./scripts/verify.sh ${repeat[@]+"${repeat[@]}"}) >"$log" 2>&1 || repeat_status=$?
  # What the repeat ran, for the log of the run: only the failed checks, or
  # every check and why.
  if grep -q '^Only the checks that failed in the run of ' "$log" 2>/dev/null; then
    repeat_scope="the repeat ran only the failed checks"
  else
    repeat_scope="the repeat ran every check$(sed -n 's/^Every check runs; the failed checks cannot be repeated alone: \(.*\)\.$/: \1/p' "$log" | sed -n 1p)"
  fi
  # A pass of this run's own: the step done again reuses it.
  [[ "$repeat_status" -ne 0 ]] || verification_trust "$(verification_field "$worktree" tree)"
  environment_stop "$title" "$repeat_status" "$log"
  second="$(failing_checks "$log")"
  twice="$(comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second") | grep . || true)"
  once="$(comm -3 <(printf '%s\n' "$first") <(printf '%s\n' "$second") | tr -d '\t' | grep . | tr '\n' ' ' || true)"
  once="${once% }"

  if [[ "$repeat_status" -eq 0 || ( -z "$twice" && -n "$second" && -n "$first" ) ]]; then
    unstable=$((unstable + 1))
    if [[ "$unstable" -gt "$MAX_UNSTABLE" ]]; then
      note "$title" "failed" "checks failed in one verification run and not in the next, for the $unstable. time: $once" "Stopping: the checks are too unstable to rely on"
      step_status=4
      return 0
    fi
    note "$title" "temporary" "unstable checks, failed in one of two verification runs: ${once:-unknown} ($repeat_scope)" "Going on; the step is done again"
    step_status=0
    return 0
  fi
  # Without names from the first run, every check of the second counts.
  [[ -n "$twice" ]] || twice="$second"
  # A base that moved and merges cleanly comes first: the step is done again
  # on the merged content.
  if merge_moved_base "$title"; then
    step_status=0
    return 0
  fi
  if [[ "$repairs" -ge "$MAX_REPAIRS" ]]; then
    note "$title" "failed" "the verification fails after $repairs repair attempts: $(printf '%s' "$twice" | tr '\n' ' ')" "Stopping"
    step_status=4
    return 0
  fi
  repairs=$((repairs + 1))
  note "$title" "failed" "checks failed in two verification runs: $(printf '%s' "$twice" | tr '\n' ' ')${once:+; unstable, failed once: $once} ($repeat_scope)" "Repair attempt $repairs of $MAX_REPAIRS by the implementer"
  mkdir -p "$worktree/.agents/handoffs"
  {
    echo
    echo "## Verification failed ($(date -u +'%Y-%m-%dT%H:%M:%SZ'), recorded by run-feature.sh)"
    echo
    echo "./scripts/verify.sh fails on the content as it is. These checks failed in two"
    echo "runs; repair them. The complete output is in .agents/run/$issue-verify.log."
    echo "Repair attempt $repairs of $MAX_REPAIRS."
    echo
    printf '%s\n' "${twice:-(no check named; read the log)}" | sed 's/^/- FAIL /'
    [[ -z "$once" ]] || echo "Failed in one run only, so probably unstable and not yours to repair: $once"
  } >>"$worktree/.agents/handoffs/$issue.md"
  # The repair is a session of the implementer, not the continuation of a
  # fix session: the review of a fix step that is going on does not apply to
  # it, and start-feature.sh takes no --continue.
  local fix_review="${STEP_REVIEW:-}"
  STEP_REVIEW=""
  retrying "repair of the verification, attempt $repairs of $MAX_REPAIRS" \
    ./scripts/start-feature.sh "$issue" --resume --unattended
  STEP_REVIEW="$fix_review"
  case "$step_status" in
    0) ;;
    3) blocked_or_ignored "repair of the verification" ;;
    4) step_status=1 ;;
  esac
}

# step <title> <command>...
# Runs one step of the workflow in the feature worktree and decides its
# outcome from its exit status. Sets step_status: 0 when the run can go on,
# 3 when an agent needs a decision of the human, 4 when the verification
# cannot be repaired, and another status when the step failed for good.
#
#   0      completed
#   3      blocked, when the handoff note holds an open question; otherwise
#          the BLOCKED line is ignored and the step counts as completed
#   4      the verification failed: repeated once, then repaired
#   5      an agent changed an artifact that it may only read: not tried
#          again
#   other  tried again when temporary (retrying): once on a known transient
#          error, RETRIES times on a usage limit; otherwise the step failed
step() {
  local title="$1"

  retrying "$@"
  case "$step_status" in
    3) blocked_or_ignored "$title" ;;
    4) repair_verification "$title" ;;
  esac
}

# step_once <title> <command>...
# Runs a step that is not tried again, because its failure is a refusal that
# a retry does not change. Sets step_status.
step_once() {
  local title="$1"

  shift
  echo
  echo "=== run-feature.sh: $title ==="
  echo
  step_status=0
  step_started="$(date +%s)"
  step_id="$(records_id)"
  records_step_start "$step_id" "$title"
  run_step="$title"
  (cd "$worktree" && "$@" </dev/null) || step_status=$?
  records_step "$title" "$step_status" "$(($(date +%s) - step_started))" "$step_id"
  [[ "$step_status" -ne 78 ]] || environment_stop "$title" "$step_status" /dev/null
  [[ "$step_status" -eq 0 ]] || note "$title" "failed" "the step exited with status $step_status" "Stopping"
}

# report_risk <when>
# Prints the risk level of the feature and its reasons, as check-risk.sh of
# the worktree computes them from the diff and the rules of the base at this
# moment (never from a level stored in a review), and notes them in the run
# record. Sets risk_level, and what the level requires of the rounds by the
# risk policy: risk_review ('full', 'delta', or 'none'), and risk_triage
# ('full' or 'light'; triage-review.sh derives it again itself). The full
# verification precedes every round whatever the policy says. The workflow profile
# of the policy is printed and recorded with the level. When the level cannot
# be determined, the strictest requirements apply. finish-feature.sh
# enforces the level again before the commit. A value of the policy that is
# refused, such as 'high: triage: light' or 'high: verification: groups
# unit' (refused since #443), is printed with the reasons and noted in the log
# of the feature; the strictest requirement applies.
risk_level=""
risk_review="full"
risk_triage="full"
report_risk() {
  local output
  local status=0
  local refused

  risk_level=""
  risk_review="full"
  risk_triage="full"
  output="$( (cd "$worktree" && ./scripts/check-risk.sh "$base" </dev/null) 2>&1)" || status=$?
  if [[ "$status" -gt 2 ]]; then
    echo "run-feature.sh: the risk level could not be determined $1 (check-risk.sh exited with status $status); the full verification and complete reviews apply."
    return 0
  fi
  risk_level="$(printf '%s\n' "$output" | sed -n '1s/^risk: //p')"
  risk_review="$(printf '%s\n' "$output" | sed -n 's/^review: //p' | sed -n 1p)"
  risk_triage="$(printf '%s\n' "$output" | sed -n 's/^triage: //p' | sed -n 1p)"
  [[ -n "$risk_review" ]] || risk_review="full"
  [[ "$risk_triage" == "light" ]] || risk_triage="full"
  echo
  echo "run-feature.sh: risk level $1: $risk_level"
  printf '%s\n' "$output" | sed '1d; s/^/  /'
  records_risk "$1" "$risk_level" "$(printf '%s\n' "$output" | sed -n 's/^- //p')" \
    "$(printf '%s\n' "$output" | sed -n 's/^profile: //p' | sed -n 1p | sed 's/;.*//')" \
    "$(printf '%s\n' "$output" | sed -n 's/^hint: //p')" 2>/dev/null || true
  refused="$(printf '%s\n' "$output" | sed -n 's/^refused: \([a-z]*: triage: .*\)$/\1/p' | sed -n 1p)"
  if [[ -n "$refused" ]]; then
    echo "run-feature.sh: $refused"
    note "risk policy $1" "refused" "$refused" "The full triage applies"
  fi
  refused="$(printf '%s\n' "$output" | sed -n 's/^refused: \([a-z]*: verification: .*\)$/\1/p' | sed -n 1p)"
  if [[ -n "$refused" ]]; then
    echo "run-feature.sh: $refused"
    note "risk policy $1" "refused" "$refused" "The full verification applies"
  fi
}

# more_rounds: the step that a stop for used rounds proposes to continue:
# --rounds with two rounds more than now (a fix and its review, and the
# review of the complete feature), within ROUNDS_CEILING. At the ceiling no
# higher limit exists, and the step says so instead: the owner continues by
# hand, with the steps that follow it.
more_rounds() {
  local more=$((MAX_ROUNDS + 2))

  if [[ "$MAX_ROUNDS" -ge "$ROUNDS_CEILING" ]]; then
    echo "# the ceiling of $ROUNDS_CEILING review rounds is reached: --rounds cannot raise the limit further; continue by hand"
    return
  fi
  [[ "$more" -le "$ROUNDS_CEILING" ]] || more="$ROUNDS_CEILING"
  echo "./scripts/run-feature.sh $issue$mode_option --rounds $more    # your decision, at a terminal: continue with a higher limit"
}

# level_rank <level>: 0 for low, 1 for medium, 2 for high; 3 otherwise, so
# that an unknown level counts as a rise.
level_rank() {
  case "$1" in
    low) echo 0 ;;
    medium) echo 1 ;;
    high) echo 2 ;;
    *) echo 3 ;;
  esac
}

# verify_step
# The full verification as a step of the run, before a review round and for
# a feature that is committed without a review: a failure gets the status of
# a failed verification, so the implementer repairs it. It reuses only a
# pass of this run (VERIFY_TRUSTED_TREES); the step runs in a subshell, so
# the caller adds its pass to the list.
verify_step() {
  local status=0

  verification_run . orchestrator 1 || status=$?
  # A missing prerequisite of this machine (78) is no failed verification:
  # run-feature.sh stops on it (environment_stop) instead of repairing.
  [[ "$status" -eq 0 || "$status" -eq 78 ]] || status=4
  return "$status"
}

# ---------------------------------------------------------------- implement
worktree="$(find_worktree)"
[[ "$(printf '%s\n' "$worktree" | grep -c .)" -le 1 ]] ||
  fail "more than one worktree is on a branch feature/${issue}-*: $(printf '%s' "$worktree" | tr '\n' ' ')"

if [[ "$owner_finding" -eq 1 ]]; then
  [[ -n "$worktree" ]] ||
    fail "--owner-finding takes a finding on a finished feature, but no worktree is on a branch feature/${issue}-*."
  [[ "${#arguments[@]}" -eq 1 ]] ||
    fail "--owner-finding continues the feature in its worktree ($worktree); run it without a slug or base branch."
fi

if [[ -z "$worktree" ]]; then
  [[ "$implemented" -eq 0 ]] || fail "no worktree is on a branch feature/${issue}-*, so nothing is implemented yet."
  echo
  echo "=== run-feature.sh: implementation ==="
  echo
  step_status=0
  step_started="$(date +%s)"
  step_id="$(records_id)"
  records_step_start "$step_id" "implementation"
  run_step="implementation"
  # Status 75: reading the Issue failed on a known transient error, before a
  # worktree existed (start-feature.sh, read_issue). That is tried again
  # once, like any known transient error.
  first_attempt=0
  first_log="$(mktemp "${TMPDIR:-/tmp}/run-feature-first.XXXXXX")"
  while true; do
    step_status=0
    (cd "$repo_root" && ./scripts/start-feature.sh "${arguments[@]}" --unattended </dev/null) 2>&1 | tee "$first_log" || step_status=$?
    [[ "$step_status" -eq 75 && "$RETRIES" -gt 0 && "$first_attempt" -eq 0 ]] || break
    first_attempt=1
    note "implementation" "temporary" "start-feature.sh could not read the Issue (status 75); a known transient error" "Retry once in $RETRY_WAIT seconds"
    sleep "$RETRY_WAIT"
  done
  limit="$(grep -m 1 -o "This is a usage limit of [a-z]*" "$first_log" 2>/dev/null || true)"
  limit="${limit:+; ${limit#This is }, reported by the agent}"
  rm -f "$first_log"
  records_step "implementation" "$step_status" "$(($(date +%s) - step_started))" "$step_id"
  worktree="$(find_worktree)"
  first_session=1
  if [[ "$step_status" -eq 3 ]]; then
    if open_question; then
      note "implementation" "blocked" "the implementer needs a decision; its question is in the handoff note" "Stopping"
      stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note, or change the Issue"
    fi
    note "implementation" "completed" "the implementer ended with BLOCKED, but the handoff note holds no open question" "Going on"
  elif [[ "$step_status" -eq 5 ]]; then
    note "implementation" "failed" "the implementer changed an artifact that it may only read" "Stopping; nothing is tried again"
    stop 1 "the implementer changed a review, a triage, an exception, or an approval request, which it may only read. Nothing was tried again." \
      "cd \"$worktree\"" \
      "git status    # look at what the session changed; restore the artifacts, then ./scripts/run-feature.sh $issue"
  elif [[ "$step_status" -ne 0 ]]; then
    [[ -n "$worktree" ]] ||
      stop 1 "the implementation failed before a worktree existed (start-feature.sh exited with status $step_status$limit)." \
        "resolve what the output above reports"
    # The session failed, for example on a usage limit: the resumed session
    # below is tried again, with a growing wait.
    note "implementation" "temporary" "start-feature.sh exited with status $step_status$limit" "Resuming the implementer"
    first_session=0
  fi
else
  [[ "${#arguments[@]}" -eq 1 ]] ||
    fail "the feature already has a worktree ($worktree); run without a slug or base branch to continue it."
  first_session=0
fi

branch="$(git -C "$worktree" branch --show-current)"
base="$(branch_base "$worktree" "$branch")" || exit 1
state_file="$worktree/.agents/run/$issue-state"

git -C "$worktree" check-ignore -q ".agents/run/$issue-state" ||
  fail "Git does not ignore .agents/run/ in $worktree. Add '.agents/run/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."
mkdir -p "$(dirname "$state_file")"

# --owner-finding takes a finished feature: its latest finish commit, before
# any session of this run. The round limit of its chain counts the rounds
# after the round that commit was made on.
round_offset=0
if [[ "$owner_finding" -eq 1 ]]; then
  finish_refs=()
  for candidate in "origin/$base" "$base"; do
    git -C "$worktree" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null && finish_refs+=("^$candidate")
  done
  finish_commit="$(git -C "$worktree" log -1 --format=%H --grep='^Completion: ' HEAD ${finish_refs[@]+"${finish_refs[@]}"})"
  [[ -n "$finish_commit" ]] ||
    stop 1 "--owner-finding takes a finding on a finished feature, but no commit of the branch was made by finish-feature.sh." \
      "./scripts/run-feature.sh $issue    # the feature is not finished yet: run it without --owner-finding"
  round_offset="$(git -C "$worktree" log -1 --format=%B "$finish_commit" | sed -n 's/^Review: round \([0-9][0-9]*\),.*/\1/p' | sed -n 1p)"
  round_offset="${round_offset:-0}"
fi
report_risk "at the start"

# The completion gate. The state 'implemented' is written only when it
# passes; an implementer that stopped partway is resumed with the reasons in
# its handoff note. A missing state after an earlier run means that a session
# has to establish where the work stands before the gate is asked.
#
# await_completion <resume-first>
# Returns when the gate passes. Until then it resumes the implementer, for at
# most MAX_SESSIONS sessions in a run, and stops the run when the record says
# blocked or the sessions are used. With <resume-first> 1 a session runs
# before the gate is asked. It is called before the first review and again
# before every later one: a session that repairs the verification is a
# session of the implementer too, and may leave the work partial or blocked.
sessions="$first_session"
await_completion() {
  local resume_first="$1"
  local gate
  local gate_status
  local gate_reasons
  local gate_summary

  while true; do
    if [[ "$resume_first" -eq 0 ]]; then
      gate="$(completion_gate "$worktree" "$issue")"
      gate_status="$(printf '%s\n' "$gate" | sed -n 1p)"
      gate_reasons="$(printf '%s\n' "$gate" | sed 1d)"
      if completion_ready "$gate_status" && ! completion_summary_present "$worktree" "$issue"; then
        # Nobody edits the commit message of this run, so the summary of the
        # changes has to come from the implementer.
        gate_status="no summary"
        gate_reasons="the implementer wrote no summary of the changes (.agents/summaries/$issue.md)"
      fi
      gate_summary="$(printf '%s' "$gate_reasons" | tr '\n' ';' | sed 's/;/; /g')"
      records_gate "$worktree" "$gate_status" "$gate_reasons" 2>/dev/null || true
      case "$gate_status" in
        complete | awaiting_evidence)
          echo "implemented" >"$state_file"
          return 0
          ;;
        blocked)
          rm -f "$state_file"
          note "implementation" "blocked" "the completion record says blocked: $gate_summary" "Stopping"
          stop 3 "the implementer reports that it cannot complete the Issue without you: $gate_summary" \
            "read the handoff note (.agents/handoffs/$issue.md) and the completion record ($COMPLETION_DIR/$issue.json); answer in the handoff note, or change the Issue"
          ;;
      esac
      rm -f "$state_file"
      if [[ "$implemented" -eq 1 ]]; then
        stop 1 "--implemented was given, but the completion gate does not pass ($gate_status): $gate_summary" \
          "write the completion record and the summary as .agents/prompts/implementer.md describes under 'Completion', or run without --implemented to let the implementer establish them"
      fi
      if [[ "$sessions" -ge "$MAX_SESSIONS" ]]; then
        note "implementation" "failed" "not complete after $sessions sessions of the implementer ($gate_status): $gate_summary" "Stopping"
        stop 1 "the implementer ended $sessions sessions without completing the Issue ($gate_status): $gate_summary" \
          "cd \"$worktree\"" \
          "./scripts/start-feature.sh $issue --resume    # or split the Issue; nothing was reviewed or committed"
      fi
      note "implementation" "not complete" "$gate_status: $gate_summary" "Resuming the implementer, session $((sessions + 1)) of at most $MAX_SESSIONS"
      mkdir -p "$worktree/.agents/handoffs"
      {
        echo
        echo "## Not complete ($(date -u +'%Y-%m-%dT%H:%M:%SZ'), recorded by run-feature.sh)"
        echo
        echo "The session ended, but the completion gate does not pass ($gate_status):"
        echo
        printf '%s\n' "$gate_reasons" | sed 's/^/- gate: /'
        echo
        echo "Continue the work on the Issue. Nothing is reviewed or committed before"
        echo "$COMPLETION_DIR/$issue.json says complete, or awaiting_evidence for evidence of a"
        echo "later gate, with evidence for every acceptance criterion that can have it now,"
        echo "its remaining[] is empty, and"
        echo ".agents/summaries/$issue.md exists (.agents/prompts/implementer.md,"
        echo "'Completion'). When the Issue cannot be completed without a decision of the"
        echo "human, record the status 'blocked'."
      } >>"$worktree/.agents/handoffs/$issue.md"
    fi
    resume_first=0
    sessions=$((sessions + 1))
    step "implementation, session $sessions" ./scripts/start-feature.sh "$issue" --resume --unattended
    if [[ "$step_status" -eq 3 ]]; then
      stop 3 "the implementer needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note, or change the Issue"
    elif [[ "$step_status" -eq 5 ]]; then
      stop 1 "the implementer changed a review, a triage, an exception, or an approval request, which it may only read. Nothing was tried again." \
        "cd \"$worktree\"" \
        "git status    # look at what the session changed; restore the artifacts, then ./scripts/run-feature.sh $issue"
    elif [[ "$step_status" -ne 0 ]]; then
      stop 1 "the implementation failed (start-feature.sh exited with status $step_status)." \
        "resolve what the output above reports"
    fi
  done
}

resume_first=0
[[ -f "$state_file" || "$first_session" -eq 1 || "$implemented" -eq 1 ]] || resume_first=1
await_completion "$resume_first"

# ------------------------------------------------------ review, triage, fix
slug="${branch//\//-}"

# latest_review: prints the newest review of the branch, or nothing.
latest_review() {
  local candidate
  local best=""

  for candidate in "$worktree/.agents/reviews/$slug-review-"[0-9][0-9].json; do
    [[ -f "$candidate" ]] || continue
    best="$candidate"
  done
  printf '%s' "$best"
}

# unexcepted_fix_now <review> <triage>
# Prints how many FIX_NOW decisions of the triage have no valid exception of
# the owner (lib/exceptions.sh, record-exception.sh). A blocking finding the
# owner excepted stays FIX_NOW in its triage, but is not fixed now. The run
# only reads exceptions: it never records, proposes, or confirms one.
unexcepted_fix_now() {
  jq --argjson excepted "$(excepted_findings "$1")" '[.decisions[] | select(.decision == "FIX_NOW" and (.finding_id | IN($excepted[]) | not))] | length' "$2"
}

# excepted_findings <review>
# Prints, as a JSON array, the IDs of the findings of <review> that have a
# valid exception of the owner.
excepted_findings() {
  local scratch
  local excepted='[]'

  if [[ -d "$worktree/$EXCEPTIONS_DIR" ]] && scratch="$(mktemp -d "${TMPDIR:-/tmp}/run-feature-exceptions.XXXXXX" 2>/dev/null)"; then
    excepted="$(exception_status "$worktree" "$scratch" "$1" | awk -F '\t' '$1 == "valid" { print $2 }' | jq -R . | jq -s .)" || excepted='[]'
    rm -rf "$scratch"
  fi
  printf '%s\n' "$excepted"
}

# finding_refutation <round> <id>
# Prints the implementer's refutation of finding <id> of review round
# <round>: '<round> TAB <id> TAB <evidence>' of the entry that refuted it in
# checks[] of the completion record (lib/completion.sh,
# triage_check_outcomes). A finding with no check of its own triage (no fix
# session ran for it yet)
# is refuted when the finding it continues as unresolved (previous) is, and
# only when that earlier finding has the same title (finding_title): the IDs
# of two rounds are given anew, so a finding with another title is a new
# one, whatever its 'previous' says. Fails when the finding was fixed, not
# reproduced, not executable, has conflicting checks, or continues no
# refuted finding.
finding_refutation() {
  local round="$1"
  local id="$2"
  local review_file
  local triage_file
  local outcome=""
  local previous

  review_file="$worktree/.agents/reviews/$slug-review-$(printf '%02d' "$round").json"
  [[ -f "$review_file" ]] || return 1
  triage_file="$(review_latest_triage "$worktree" "$review_file")"
  if [[ -n "$triage_file" ]]; then
    outcome="$(triage_check_outcomes "$(completion_record "$worktree" "$issue")" "$triage_file" | awk -F '\t' -v id="$id" '$1 == id')"
  fi
  case "$(cut -f2 <<<"$outcome")" in
    refuted)
      printf '%s\t%s\t%s\n' "$round" "$id" "$(cut -f3- <<<"$outcome")"
      return 0
      ;;
    "" | missing) ;;
    *) return 1 ;;
  esac
  previous="$(jq -r --arg id "$id" '.findings[] | select(.id == $id) | .previous
    | select(. != null and .relation == "unresolved") | "\(.round)\t\(.id)"' "$review_file")"
  [[ -n "$previous" && "${previous%%$'\t'*}" -lt "$round" ]] || return 1
  [[ "$(finding_title "$round" "$id")" == "$(finding_title "${previous%%$'\t'*}" "${previous#*$'\t'}")" ]] || return 1
  finding_refutation "${previous%%$'\t'*}" "${previous#*$'\t'}"
}

# finding_title <round> <id>
# Prints the title of finding <id> of review round <round> as it is
# compared: in lower case, with its white space collapsed, without the mark
# of an unresolved finding that the reviewer contract allows ('Unresolved: '
# before it, ', unresolved' or ' (unresolved)' after it), and without the
# punctuation at its end; nothing when the round or the finding does not
# exist.
finding_title() {
  local review_file

  review_file="$worktree/.agents/reviews/$slug-review-$(printf '%02d' "$1").json"
  [[ -f "$review_file" ]] || return 0
  jq -r --arg id "$2" '.findings[] | select(.id == $id) | .title // ""
    | ascii_downcase | gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub("[ .!;:]+$"; "")
    | sub("^unresolved( ?[:—–-] ?| )"; "") | sub(",? [(]?unresolved[)]?$"; "") | sub("[ .!;:,]+$"; "")' "$review_file"
}

# refuted_findings <review> <triage>
# Succeeds when every FIX_NOW finding of the triage without an owner
# exception was refuted by the implementer with evidence
# (finding_refutation), and at least one of them is critical or major: the
# implementer changed no code for them, and the reviewer still reports them.
# No agent may accept a critical or major finding, so only the owner can
# decide. Sets 'refuted' to one line per finding: <id> TAB <severity> TAB
# <title> TAB <round refuted> TAB <id refuted> TAB <evidence>.
refuted_findings() {
  local id
  local refutation

  refuted=""
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    refutation="$(finding_refutation "$round" "$id")" || return 1
    refuted+="$(jq -r --arg id "$id" '.findings[] | select(.id == $id) | [.id, .severity, .title] | @tsv' "$1")"$'\t'"$refutation"$'\n'
  done < <(jq -r --argjson excepted "$(excepted_findings "$1")" \
    '.decisions[] | select(.decision == "FIX_NOW" and (.finding_id | IN($excepted[]) | not)) | .finding_id' "$2")
  [[ -n "$refuted" ]] && awk -F '\t' '$2 == "critical" || $2 == "major" { found = 1 } END { exit !found }' <<<"$refuted"
}

# refuted_stop
# Stops the run for the owner, with status 3, on the findings that
# refuted_findings found: each with its evidence, and the ways on. Nothing is
# written to the handoff note, which the review covers: the review stays
# current, so the owner's exception can be recorded for it.
refuted_stop() {
  local next=("cd \"$worktree\"")
  local id
  local severity

  note "triage of round $round" "refuted" "the implementer refuted every finding left to fix ($(cut -f1 <<<"${refuted%$'\n'}" | paste -sd ' ' - | sed 's/ /, /g')) with evidence, and the review still reports them; no agent may accept a critical or major finding" "Stopping for the owner's decision"
  while IFS=$'\t' read -r id severity _; do
    [[ -n "$id" ]] || continue
    if [[ "$severity" == "critical" || "$severity" == "major" ]]; then
      next+=("./scripts/record-exception.sh $review_relative --finding $id --type not-applicable --evidence \"$COMPLETION_DIR/$issue.json\" --reason \"<why>\"    # you agree that $id does not hold")
    else
      next+=("./scripts/triage-review.sh $review_relative --decisions <file> --reason \"<why>\"    # an owner-directed triage that accepts $id")
    fi
  done <<<"$refuted"
  next+=("./scripts/start-feature.sh $issue --resume    # or the fix after all: write your instruction into the handoff note first")
  stop 3 "the implementer refuted every finding left to fix in round $round with evidence and changed no code for it, and the review still reports it; only you can accept a critical or major finding:
$(awk -F '\t' 'NF { printf "  - %s (%s): %s — refuted in round %s (%s): %s\n", $1, $2, $3, $4, $5, $6 }' <<<"$refuted")
The evidence is in checks[] of the completion record ($COMPLETION_DIR/$issue.json)." "${next[@]}"
}

# changes_reviewable <review>
# Succeeds when a review of only the changes can build on <review>: the
# branch has the same base as then, and the content it reviewed is known.
changes_reviewable() {
  local merge_base

  # The same base as review-feature.sh uses.
  merge_base="$(feature_base "$worktree" "$base" | sed -n 2p)"
  [[ -n "$merge_base" ]] || return 1
  [[ "$(jq -r '.merge_base' "$1")" == "$merge_base" ]] || return 1
  git -C "$worktree" cat-file -e "$(jq -r '.reviewed_tree' "$1")^{tree}" 2>/dev/null
}

# delta_allowed <review>
# Succeeds when the next round may review only the changes since <review>:
# the risk policy allows a delta review for the level of the feature, the
# review is valid and can be built on (changes_reviewable), and the level
# computed now did not rise above the level that round recorded. A level that
# rose means that the diff since then touched a path of a higher class, or an
# agent raised it: the feature is reclassified, and the next round reviews
# the complete feature. Sets delta_refusal to why not.
delta_allowed() {
  local recorded

  delta_refusal=""
  if [[ "$risk_review" != "delta" ]]; then
    delta_refusal="the risk policy requires a complete review for a $risk_level-risk feature (review: $risk_review)"
    return 1
  fi
  if [[ -n "$(review_artifact_errors "$1")" ]]; then
    delta_refusal="the previous review is invalid"
    return 1
  fi
  if ! changes_reviewable "$1"; then
    delta_refusal="the base of the branch changed, or the content the previous round reviewed is no longer known"
    return 1
  fi
  recorded="$(jq -r '.risk.level // empty' "$1")"
  if [[ "$(level_rank "$risk_level")" -gt "$(level_rank "$recorded")" ]]; then
    delta_refusal="the risk level rose from ${recorded:-unknown} (round $(jq -r '.round' "$1")) to $risk_level"
    return 1
  fi
}

uncommitted() {
  [[ -n "$(git -C "$worktree" status --porcelain)" ]]
}

# changes_only <review>
# Succeeds when a review covered only the changes since an earlier round.
changes_only() {
  [[ "$(jq -r '.scope.kind' "$1")" == "changes" ]]
}

# intermediate <review>
# Succeeds when a review is one of an intermediate round: it covered only the
# changes. A round that ends the run reviews the complete feature on the full
# verification.
intermediate() {
  changes_only "$1"
}

# The steps of the state loop below that succeeded in this run, one
# '<step>|<round>' per line, and the triages this run published. The loop
# decides its next step from the artifacts; a step that succeeds without
# changing the artifact it is started for would otherwise be started again
# without a bound (the triage of #527 was published 500 times). A step of
# the loop is started at most once per round in a run: the second start
# stops the run (loop_guard). Plain lists, not associative arrays, which the
# Bash of macOS lacks.
loop_done=""

# loop_guard <step> <round> <state> <command>
# Stops the run when the step <step> of round <round> succeeded already in
# this run and the loop would start it again: it made no progress. <state>
# says what the loop waits for, <command> runs the step by hand.
loop_guard() {
  grep -Fqx -- "$1|$2" <<<"$loop_done" || return 0
  note "$1 of round $2" "no progress" "the step succeeded earlier in this run, and the loop would start it again: $3" "Stopping"
  stop 1 "the $1 of round $2 succeeded, but $3, so the run would start the same step again; it stops instead of repeating it." \
    "cd \"$worktree\"" \
    "# read the output of the step above and the log of the run, .agents/run/$issue-log: the script succeeded without that change" \
    "$4    # by hand, once the script makes that change"
}

# loop_progress <step> <round>: the step of the round succeeded in this run.
loop_progress() {
  loop_done+="$1|$2"$'\n'
}

# ------------------------------------------------- the owner's finding
# --owner-finding: the owner posted a finding on the Issue of a finished
# feature whose pull request is open. The chain runs in this process, so
# the pass of the fixed content is reused by the commit (VERIFY_TRUSTED_TREES,
# never given to an agent):
#
# 1. the base is merged when it moved since the finish, as merge_moved_base
#    does for a failed verification, and stops on a conflict;
# 2. a review of the complete feature is due when a comment of the owner on
#    the Issue (lib/issue-comments.sh: the comments an agent is given) is
#    newer than the latest review and the finish commit; the reviewer gets
#    the comment with the Issue. Without one nothing is reviewed again
#    unless the content changed, so running the command again continues
#    where it stopped: also on a review of the chain (a round after the
#    finish commit's) that a stop left before its triage or fixes;
# 3. the loop below then triages, fixes, verifies, and reviews the complete
#    feature again, every round on the complete feature, and finish-feature.sh
#    commits the fixes on top of the published commit: the approval request
#    of that commit covers what publish-feature.sh pushes, without a reset or
#    a forced push.
#
# The round limit counts the rounds of the chain: those after the round the
# finish commit was made on ('Review: round <n>' in its message).
owner_review=0
owner_changed=0
owner_pending=0
if [[ "$owner_finding" -eq 1 ]]; then
  run_step="owner finding"
  echo
  echo "run-feature.sh: the owner's finding on the finished feature (finish commit $(git -C "$worktree" rev-parse --short "$finish_commit"), review round ${round_offset/#0/none}); at most $MAX_ROUNDS review rounds after it."

  # 1. The update with the base.
  git -C "$worktree" remote get-url origin >/dev/null 2>&1 &&
    git -C "$worktree" fetch -q origin "$base" </dev/null >/dev/null 2>&1 || true
  base_ref="origin/$base"
  git -C "$worktree" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || base_ref="$base"
  if git -C "$worktree" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null &&
    ! git -C "$worktree" merge-base --is-ancestor "$base_ref" HEAD; then
    merge_context="the base moved since the feature was finished"
    merge_cause="the base moved since the feature was finished"
    merge_action="Going on with the review; the run verifies the merged content before it"
    merge_fallback="Stopping"
    merge_moved_base "update with the base" ||
      stop 1 "the base moved since the feature was finished, and Git could not merge $base_ref; see the log of the run, .agents/run/$issue-log." \
        "cd \"$worktree\"" \
        "./scripts/update-feature.sh $issue    # merges the base by hand, or names what stands in the way"
  else
    echo "run-feature.sh: the branch contains its base ($base_ref); nothing to merge."
  fi

  # 2. A comment of the owner that the latest review has not seen.
  newest="$(issue_comments_newest "$issue")" ||
    stop 1 "could not read the comments of Issue #$issue ($ISSUE_COMMENTS_ERROR), so whether the owner posted a finding is unknown." \
      "gh api \"repos/{owner}/{repo}/issues/$issue/comments\"    # check access to the Issue"
  seen="$(git -C "$worktree" log -1 --format=%ct "$finish_commit")"
  review="$(latest_review)"
  if [[ -n "$review" ]]; then
    reviewed="$(jq -r '.created_at // empty | fromdateiso8601' "$review" 2>/dev/null)" || reviewed=""
    [[ ! "$reviewed" =~ ^[0-9]+$ || "$reviewed" -le "$seen" ]] || seen="$reviewed"
  fi
  if [[ "$newest" =~ ^[0-9]+$ && "$newest" -gt "$seen" ]]; then
    owner_review=1
    note "owner finding" "owner finding" "a comment of the owner on Issue #$issue is newer than the latest review and the finish commit" "Reviewing the complete feature with it"
  else
    note "owner finding" "no new comment" "no comment of the owner on Issue #$issue is newer than the latest review and the finish commit" "Reviewing again only what changed since; post the finding on the Issue first"
  fi
  # A review of the chain, after the round of the finish commit, that a
  # stop left before its triage or fixes: the chain continues on it, also
  # when the comment is older than it and the content is unchanged. The
  # loop ends at once when that review leaves nothing to fix.
  if [[ -n "$review" ]]; then
    review_round="$(jq -r '.round // 0' "$review" 2>/dev/null)" || review_round=0
    [[ ! "$review_round" =~ ^[0-9]+$ || "$review_round" -le "$round_offset" ]] || owner_pending=1
  fi
  # What changed since the finish: the merge of the base, or the work of a
  # chain that stopped.
  if uncommitted; then
    owner_changed=1
  elif fingerprint_scratch="$(mktemp -d "${TMPDIR:-/tmp}/run-feature-owner.XXXXXX")"; then
    if ! head_tree="$(fingerprint_commit "$worktree" "$fingerprint_scratch" HEAD)" ||
      ! finish_tree="$(fingerprint_commit "$worktree" "$fingerprint_scratch" "$finish_commit")" ||
      [[ "$head_tree" != "$finish_tree" ]]; then
      owner_changed=1
    fi
    rm -rf "$fingerprint_scratch"
  else
    owner_changed=1
  fi
fi

# The round that ends the run reviews the complete feature against the Issue,
# on content that passed the full verification, also when the rounds before
# it reviewed only changes: such a round confirms fixes, it does not establish
# that the Issue is done.
complete_review=0
# The owner's finding is reviewed on the complete feature, also when the
# latest review is current for the content.
complete_review="$owner_review"
if uncommitted || [[ "$owner_review" -eq 1 || "$owner_changed" -eq 1 || "$owner_pending" -eq 1 ]]; then
  while true; do
    # A repair session may have left the work partial or blocked.
    await_completion 0
    review="$(latest_review)"
    round=0
    current=1
    if [[ -n "$review" ]]; then
      round="$(jq -r '.round' "$review")"
      current=0
      (cd "$worktree" && ./scripts/check-review.sh "$review" >/dev/null 2>&1) || current=$?
      [[ "$current" -ne 2 ]] ||
        stop 1 "the latest review cannot be read: ${review#"$worktree"/}." \
          "cd \"$worktree\" && ./scripts/check-review.sh ${review#"$worktree"/}"
    fi

    if [[ "$current" -ne 0 || "$complete_review" -eq 1 ]]; then
      # No review yet, the content changed since the latest one, or the
      # latest one was an intermediate round and nothing is left to fix.
      if [[ "$((round - round_offset))" -ge "$MAX_ROUNDS" && "$complete_review" -eq 1 ]]; then
        stop 1 "$MAX_ROUNDS review rounds are used, and round $round reviewed only changes, so no review of the complete feature confirms that the Issue is done." \
          "$(more_rounds)" \
          "cd \"$worktree\"" \
          "./scripts/review-feature.sh $issue $base    # or continue by hand: triage-review.sh, apply-triage.sh, finish-feature.sh, publish-feature.sh"
      fi
      if [[ "$((round - round_offset))" -ge "$MAX_ROUNDS" ]]; then
        stop 1 "$MAX_ROUNDS review rounds are used, and the content changed after round $round, so it is not confirmed by a review." \
          "$(more_rounds)" \
          "cd \"$worktree\"" \
          "./scripts/review-feature.sh $issue $base    # or continue by hand: triage-review.sh, apply-triage.sh, finish-feature.sh, publish-feature.sh"
      fi
      # The level and what it requires, computed now: the policy is applied
      # to the feature as it is, never to a level a review stored.
      report_risk "before round $((round + 1))"

      # A low-risk feature in a project whose policy says 'low: review: none'
      # is committed without a review, when none exists: the verification is
      # a step of its own then, repaired like one that a review would have
      # run. The gate and the level are asked again after a repair, since a
      # repair session can change both.
      # The owner's finding is always reviewed.
      if [[ -z "$review" && "$risk_level" == "low" && "$risk_review" == "none" && "$owner_finding" -eq 0 ]]; then
        attempts_before="$repairs/$unstable/$base_merges"
        step "verification of the low-risk feature, which the project policy does not review" verify_step
        if [[ "$step_status" -eq 3 ]]; then
          rm -f "$state_file"
          stop 3 "the implementer, repairing the verification, needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
            "answer the question in the handoff note"
        elif [[ "$step_status" -eq 4 ]]; then
          stop 1 "the verification still fails; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
            "cd \"$worktree\"" \
            "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
        elif [[ "$step_status" -ne 0 ]]; then
          stop 1 "the verification did not complete (status $step_status)." \
            "resolve what the output above reports"
        fi
        if [[ "$repairs/$unstable/$base_merges" == "$attempts_before" ]]; then
          # The pass of verify_step, with no session after it: the commit
          # reuses it.
          verification_trust "$(verification_field "$worktree" tree)"
          break
        fi
        continue
      fi

      # A later round reviews the changes since the round before it, when
      # the policy allows it for the level and the round can build on it:
      # the same base, a valid round whose content is known, and a level that
      # did not rise since. That review is given the decisions of that round,
      # so a finding that was deferred or accepted is not reported, triaged,
      # and deferred again. Otherwise the round reviews the complete feature.
      review_options=()
      review_title="review"
      if [[ "$complete_review" -eq 1 || ( "$owner_finding" -eq 1 && -n "$review" ) ]]; then
        # The chain of an owner's finding reviews the complete feature in
        # every round: the fix is committed on that review.
        review_title="review of the complete feature"
      elif [[ -n "$review" ]]; then
        if delta_allowed "$review"; then
          review_options=(--changes)
        else
          note "review, round $((round + 1))" "complete" "no review of the changes only: $delta_refusal" "Reviewing the complete feature"
        fi
      fi
      # A review of this round that succeeded already in this run and left
      # no review that is current: the guard comes before the verification,
      # which the round would otherwise repeat first.
      loop_guard "review" "$((round + 1))" "no review of round $((round + 1)) that is current for the content exists (check-review.sh)" \
        "./scripts/review-feature.sh $issue $base${review_options[*]:+ ${review_options[*]}}"
      # The full verification of a round is this run's own, after the
      # session and before the review (lib/verification.sh): the agent
      # sessions run only the checks of what they changed, and its pass is
      # in this run's VERIFY_TRUSTED_TREES, so the review, a retry of it, and
      # the commit reuse it instead of verifying again. A failure goes to the
      # implementer as a repair session; after a repair, or a repeat that
      # passed, the gate and the round are decided again.
      attempts_before="$repairs/$unstable/$base_merges"
      step "verification before round $((round + 1))" verify_step
      if [[ "$step_status" -eq 3 ]]; then
        rm -f "$state_file"
        stop 3 "the implementer, repairing the verification, needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
          "answer the question in the handoff note"
      elif [[ "$step_status" -eq 4 ]]; then
        stop 1 "the verification still fails; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
          "cd \"$worktree\"" \
          "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
      elif [[ "$step_status" -ne 0 ]]; then
        # verify_step itself returns 0 or 4: the repair session failed.
        stop 1 "the repair of the verification before round $((round + 1)) failed ($step_command exited with status $step_status)." \
          "resolve what the output above reports"
      fi
      [[ "$repairs/$unstable/$base_merges" == "$attempts_before" ]] || continue
      # The pass of verify_step, which ran in a subshell.
      verification_trust "$(verification_field "$worktree" tree)"
      complete_review=0
      step "$review_title, round $((round + 1)) of at most $((MAX_ROUNDS + round_offset))" \
        ./scripts/review-feature.sh "$issue" "$base" ${review_options[@]+"${review_options[@]}"}
      if [[ "$step_status" -eq 3 ]]; then
        rm -f "$state_file"
        stop 3 "the implementer, repairing the verification, needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
          "answer the question in the handoff note"
      elif [[ "$step_status" -eq 4 ]]; then
        stop 1 "the verification still fails; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
          "cd \"$worktree\"" \
          "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
      elif [[ "$step_status" -ne 0 ]]; then
        stop 1 "the review did not complete (review-feature.sh exited with status $step_status): the reviewer failed, or the review was refused." \
          "resolve what the output above reports"
      fi
      loop_progress "review" "$((round + 1))"
      continue
    fi

    review_relative="${review#"$worktree"/}"
    if [[ "$(jq '.findings | length' "$review")" -eq 0 ]]; then
      intermediate "$review" || break
      complete_review=1
      continue
    fi

    triage="$(review_latest_triage "$worktree" "$review")"
    if [[ -z "$triage" ]]; then
      loop_guard "triage" "$round" "the review of round $round has no triage" \
        "./scripts/triage-review.sh $review_relative"
      step "triage of round $round" ./scripts/triage-review.sh "$review_relative" --unattended
      [[ "$step_status" -eq 0 ]] ||
        stop 1 "the triage of round $round failed (triage-review.sh exited with status $step_status)." \
          "resolve what the output above reports"
      loop_progress "triage" "$round"
      continue
    fi
    triage_relative="${triage#"$worktree"/}"
    # The publication is the workflow's comment on the Issue (Issue 527).
    # When the comments cannot be read, the run stops rather than publish
    # the triage a second time.
    triage_records="$(cd "$worktree" && issue_comments_triage_records "$issue")" ||
      stop 1 "could not read the comments of Issue #$issue or the authenticated GitHub account whose comments alone publish a triage, so the publication of the triage of round $round cannot be checked." \
        "check the access to GitHub (gh auth status), then run ./scripts/run-feature.sh $issue again"
    if ! issue_comments_triage_published "$triage_records" "$worktree" "$triage"; then
      # Published once by this run and still not found: publishing it again
      # would not find it either.
      [[ "${republished_triage:-}" != "$triage" ]] ||
        stop 1 "the triage of round $round was published, but the comments of Issue #$issue do not show it: no report of the workflow there names $triage_relative with its SHA-256 in every part." \
          "cd \"$worktree\"" \
          "./scripts/triage-review.sh --publish $triage_relative    # then run ./scripts/run-feature.sh $issue again"
      republished_triage="$triage"
      step "publication of the triage of round $round" ./scripts/triage-review.sh --publish "$triage_relative"
      [[ "$step_status" -eq 0 ]] ||
        stop 1 "the triage of round $round could not be published on the Issue." \
          "cd \"$worktree\"" \
          "./scripts/triage-review.sh --publish $triage_relative"
      continue
    fi

    if [[ "$(unexcepted_fix_now "$review" "$triage")" -eq 0 ]]; then
      # Nothing to fix: the round ends without a fix session. A light triage
      # (the mode the policy set when the round was triaged) says so in the
      # log; every finding is then a suggestion or minor, deferred or
      # accepted, since a critical or major finding is always FIX_NOW.
      if [[ "$(jq -r '.triage.mode' "$triage")" == "light" ]]; then
        if intermediate "$review"; then
          next_step="Reviewing the complete feature"
        else
          next_step="Going on to the commit"
        fi
        note "triage of round $round" "light" "every finding is a suggestion or minor and was deferred or accepted; the light triage of the project policy ends the round without a fix session" "$next_step"
      fi
      intermediate "$review" || break
      complete_review=1
      continue
    fi

    # A finding to fix that the triage says departs from a recorded owner
    # decision (owner_decision, lib/issue-comments.sh) is not fixed: the run
    # stops for the owner, who decides whether the decision stands. The body
    # is read now, after the triage: a decision that a later entry replaces
    # no longer stands, and its fix goes on. A body that cannot be read
    # replaces none, so the run stops.
    departures="$(issue_decisions_departures "$triage" "")"
    if [[ -n "$departures" ]]; then
      departure_body=""
      if issue_decisions_read "$issue"; then departure_body="$ISSUE_DECISIONS_BODY"; fi
      departures="$(issue_decisions_departures "$triage" "$departure_body")"
      [[ -n "$departures" ]] ||
        echo "Every owner decision that the triage of round $round names is replaced by a later entry of Issue #$issue; the fixes go on."
    fi
    if [[ -n "$departures" ]]; then
      departure_text=""
      while IFS=$'\t' read -r finding number title; do
        entry="$(issue_decisions_entry "$departure_body" "$number")"
        departure_text+="; finding $finding ($title) departs from owner decision $number: ${entry:-see the block \"## Owner decisions\" of Issue #$issue}"
      done <<<"$departures"
      stop 3 "the triage of round $round would fix what a recorded owner decision ruled out, so no fix was made${departure_text}. Only you decide whether the decision stands." \
        "./scripts/record-decision.sh $issue \"<decision>\" --source <url> --replaces <n>    # the finding is right: a decision that replaces it; then triage again:" \
        "cd \"$worktree\" && ./scripts/triage-review.sh $review_relative" \
        "cd \"$worktree\" && ./scripts/triage-review.sh $review_relative --decisions <file> --reason \"<why>\"    # the decision stands: your own triage of the findings"
    fi

    # The implementer refuted what is left to fix, and the reviewer, who was
    # given the refutation, still reports it: another fix session would
    # refute it again. The owner decides, on a review of the complete feature,
    # which an exception binds to; an intermediate round goes on to that
    # review first.
    if refuted_findings "$review" "$triage"; then
      if ! intermediate "$review"; then
        refuted_stop
      elif [[ "$((round - round_offset))" -lt "$MAX_ROUNDS" ]]; then
        note "triage of round $round" "refuted" "the implementer refuted every finding left to fix with evidence, and this review of changes only still reports them" "Reviewing the complete feature, for the owner's decision"
        complete_review=1
        continue
      fi
    fi
    if [[ "$((round - round_offset))" -ge "$MAX_ROUNDS" ]]; then
      stop 1 "$MAX_ROUNDS review rounds are used and round $round still has findings that must be fixed; see $review_relative. Where the owner disagrees with a critical or major finding, the owner may record an exception to it at a terminal (docs/development.md, 'Owner exceptions to a blocking finding')." \
        "$(more_rounds)" \
        "cd \"$worktree\"" \
        "./scripts/apply-triage.sh $triage_relative    # or continue by hand: review-feature.sh, finish-feature.sh, publish-feature.sh" \
        "./scripts/record-exception.sh $review_relative --finding <id> --type not-applicable|risk-accepted --reason \"<why>\"    # the owner's option, for one blocking finding"
    fi
    # An interrupted fix session is continued with its scope, not started
    # again: apply-triage.sh refuses a review whose content changed. This
    # run's own full verification before the next round verifies the fixes
    # (--caller-verifies), and the review then reuses it.
    loop_guard "fixes" "$round" "the review of round $round is still current and its triage has findings to fix" \
      "./scripts/apply-triage.sh $triage_relative"
    STEP_REVIEW="$review"
    step "fixes for round $round" ./scripts/apply-triage.sh "$triage_relative" --unattended --caller-verifies
    STEP_REVIEW=""
    if [[ "$step_status" -eq 3 ]]; then
      # The next run resumes the implementer, which reads the handoff note
      # with the answer before it continues; a review follows.
      rm -f "$state_file"
      stop 3 "the agent that applies the fixes needs a decision of yours; its question is in the handoff note (.agents/handoffs/$issue.md)." \
        "answer the question in the handoff note"
    elif [[ "$step_status" -eq 4 ]]; then
      stop 1 "the verification still fails after the fixes for round $round; the failing checks are in .agents/run/$issue-verify.log and in the log of the run, .agents/run/$issue-log." \
        "cd \"$worktree\"" \
        "./scripts/verify.sh    # repair what fails, for example with ./scripts/start-feature.sh $issue --resume"
    elif [[ "$step_status" -eq 5 ]]; then
      stop 1 "the agent that applies the fixes changed the review or the approved triage of round $round, which it may only read. Nothing was tried again." \
        "cd \"$worktree\"" \
        "git status    # look at what the session changed; restore the review and the triage, or review again"
    elif [[ "$step_status" -ne 0 ]]; then
      stop 1 "the fixes for round $round failed ($step_command exited with status $step_status)." \
        "resolve what the output above reports"
    fi
    if (cd "$worktree" && ./scripts/check-review.sh "$review" >/dev/null 2>&1); then
      if refuted_findings "$review" "$triage" && ! intermediate "$review"; then
        refuted_stop
      fi
      stop 1 "the fixes for round $round changed nothing, although the triage has findings to fix." \
        "cd \"$worktree\"" \
        "./scripts/apply-triage.sh $triage_relative"
    fi
    loop_progress "fixes" "$round"
  done

  # ---------------------------------------------------------------- finish
  if uncommitted; then
    run_step="commit"
    title="$(gh issue view "$issue" --json title --jq '.title' </dev/null)" ||
      stop 1 "could not read the title of Issue #$issue for the commit message." \
        "cd \"$worktree\"" "./scripts/finish-feature.sh $issue \"<commit summary>\""
    step_once "commit" ./scripts/finish-feature.sh "$issue" "$title" --unattended
    [[ "$step_status" -eq 0 ]] ||
      stop 1 "the feature could not be committed (finish-feature.sh exited with status $step_status)." \
        "cd \"$worktree\"" "./scripts/finish-feature.sh $issue \"$title\""
  else
    # Only the chain of an owner's finding gets here without work: its review
    # of the complete feature left nothing to fix (no finding, or only
    # findings that were deferred or accepted, published on the Issue). The
    # merge of the base, when there was one, is published.
    note "owner finding" "nothing to fix" "the review of the complete feature, round $(jq -r '.round' "$(latest_review)"), leaves nothing to fix; the triage decisions are on the Issue" "Publishing what is committed"
  fi
else
  base_ref="$base"
  git -C "$worktree" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || base_ref="origin/$base"
  [[ "$(git -C "$worktree" rev-list --count "$base_ref..HEAD" 2>/dev/null || echo 0)" -gt 0 ]] ||
    stop 1 "the feature worktree has no changes and no commits: nothing was implemented." \
      "./scripts/start-feature.sh $issue --resume"
  echo
  echo "The feature is already committed; continuing with the pull request."
fi

# ------------------------------------------------------------------ publish
step "pull request" ./scripts/publish-feature.sh "$issue"
[[ "$step_status" -eq 0 ]] ||
  stop 1 "the pull request could not be opened (publish-feature.sh exited with status $step_status)." \
    "cd \"$worktree\"" "./scripts/publish-feature.sh $issue"

echo
echo "run-feature.sh is done: the pull request of Issue #$issue is open."
if grep -Fqx -- "- required from the project owner, for exactly this commit" <<<"$(git -C "$worktree" log -1 --format=%b)"; then
  echo
  echo "MERGE APPROVAL REQUIRED. This pull request changes what only the owner may"
  echo "approve; the reasons are in its description. Nothing may merge it for you:"
  echo "read it and merge it yourself. A queue that merges pull requests skips it."
  echo
fi
echo "Read it, also the triage decisions that were approved without you, follow its"
echo "checks, and merge it. Then clean up with: ./scripts/cleanup-worktree.sh $issue"
if grep -Fq -- "- pending at post_merge: " <<<"$(git -C "$worktree" log -1 --format=%b)"; then
  echo
  echo "The Issue stays open after the merge: the commit lists evidence of the post_merge"
  echo "gate. Record it with ./scripts/record-post-merge.sh $issue \"<criterion>\" \"<evidence>\";"
  echo "the Issue is closed when none is left."
fi
