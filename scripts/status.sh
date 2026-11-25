#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

usage() {
  echo "Usage: $0 [--markdown] [--changes]"
  echo
  echo "One overview of every feature that has a worktree or an open pull request,"
  echo "one row each: the Issue and its title, the phase of its latest run, the exit"
  echo "status of that run when it stopped, the last full verification and whether"
  echo "it counts as trusted evidence, the pull request with its checks and whether"
  echo "it merges, and the owner decision the feature waits for, with the command"
  echo "or the link that settles it. An empty decision means that nothing is"
  echo "needed from the owner."
  echo
  echo "Nothing here is a status of its own: the phase and the exit status come from"
  echo "the run records (lib/records.sh), the implementer's state from the"
  echo "completion gate (lib/completion.sh), the pull request from GitHub, and the"
  echo "need for the owner's approval from the approval request that"
  echo "finish-feature.sh committed. Run it from any checkout of the repository."
  echo
  echo "  --markdown  a Markdown table, for example to post as a comment"
  echo "  --changes   only what changed since the previous --changes: the changed"
  echo "              rows, the features no longer listed, and every new owner"
  echo "              decision; nothing when nothing changed. The previous overview"
  echo "              is kept in .agents/status/ of the primary checkout, which Git"
  echo "              ignores. When .agents/notify.conf of the primary checkout names"
  echo "              a 'command:', the changes are passed to it on standard input;"
  echo "              when it fails, the changes are kept and sent again next time."
  echo "              One --changes runs at a time; another waits for its lock"
  echo "              (.agents/status/lock) up to STATUS_LOCK_WAIT seconds (300)."
  echo
  echo "Examples:"
  echo "  $0"
  echo "  $0 --markdown | gh issue comment 361 --body-file -"
  echo "  $0 --changes"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/completion.sh"
source "$script_dir/lib/github.sh"
source "$script_dir/lib/verify-lock.sh"

markdown=0
changes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --markdown) markdown=1 ;;
    --changes) changes=1 ;;
    *) usage ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || fail "jq is required."
primary="$(records_primary)"
[[ -n "$primary" ]] || fail "run it inside a checkout of the repository."

# --changes is one transaction: read the previous overview, compare, notify,
# and keep the new overview. Two at the same time (cron and a run by hand)
# would both notify the same change, or keep their overviews in the wrong
# order, so the whole run holds a lock: the directory .agents/status/lock and
# its file 'owner', which names the process. The run that creates 'owner'
# holds the lock: Bash creates it with noclobber, an exclusive create (O_EXCL)
# that the kernel decides, so that exactly one run wins whatever 'mkdir' does.
# mkdir alone does not decide it: the mkdir of uutils coreutils (Ubuntu 25.10
# and newer) succeeds for both of two runs that create the same directory at
# the same time, and both then took the lock (#487). A lock whose process is
# gone (a crash, SIGKILL), or that has no owner, or an empty one, and is older
# than a grace period, is stale and is removed under a second lock, so that
# two runs do not both remove it. A run removes only the lock that names it.
# A run that waits longer than STATUS_LOCK_WAIT seconds (default 300) fails
# and changes nothing.
state_dir="$primary/.agents/status"
lock_dir="$state_dir/lock"
lock_held=0
lock_owner=""
release_lock() {
  if [[ "$lock_held" -eq 1 && "$(cat "$lock_dir/owner" 2>/dev/null)" == "$lock_owner" ]]; then
    rm -rf "$lock_dir"
  fi
  lock_held=0
}
# lock_stale <owner-text>: whether the process that the text names is
# confirmedly gone, or its PID now belongs to another process. A process that
# cannot be inspected holds the lock.
lock_stale() {
  local pid started now exists=0

  pid="$(sed -n 's/^pid=//p' <<<"$1")"
  started="$(sed -n 's/^started=//p' <<<"$1")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  verify_lock_exists "$pid" || exists=$?
  case "$exists" in
    0)
      now="$(verify_lock_started "$pid")"
      [[ -n "$now" && -n "$started" && "$now" != "$started" ]]
      ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
}
# lock_old <dir>: whether the directory is older than the grace period
# (VERIFY_LOCK_RECOVER_SECONDS). A lock without an owner is being taken right
# now, or was left by a run killed while it took the lock; only an old one is
# stale. The same holds for a recovery lock. A directory whose time cannot be
# read (it was removed a moment ago) is not old.
lock_old() {
  local mtime

  mtime="$(verify_lock_mtime "$1")"
  [[ "$mtime" =~ ^[0-9]+$ && "$mtime" -gt 0 && -e "$1" && $(($(date +%s) - mtime)) -gt "$VERIFY_LOCK_RECOVER_SECONDS" ]]
}
# recover_lock <owner-text>: removes the stale lock under the recovery lock,
# only when it is still the lock that was seen: the same owner, or still no
# owner and still old. An old recovery lock of a killed run is taken over.
recover_lock() {
  local recover="$lock_dir.recover"

  if ! mkdir "$recover" 2>/dev/null; then
    lock_old "$recover" && rmdir "$recover" 2>/dev/null && mkdir "$recover" 2>/dev/null || return 1
  fi
  if [[ "$(cat "$lock_dir/owner" 2>/dev/null)" == "$1" ]] && { [[ -n "$1" ]] || lock_old "$lock_dir"; }; then
    rm -rf "$lock_dir"
  fi
  rmdir "$recover" 2>/dev/null || true
}
# claim_lock: creates the owner of the lock, exclusively; fails when another
# run did first, or when the directory is gone.
claim_lock() {
  lock_owner="$(printf 'pid=%s\nstarted=%s' "$$" "$(verify_lock_started "$$")")"
  (set -C && printf '%s\n' "$lock_owner" >"$lock_dir/owner") 2>/dev/null
}
take_lock() {
  local waited=0 limit="${STATUS_LOCK_WAIT:-300}" owner

  while :; do
    # Only a run whose mkdir succeeded claims: a directory that is there
    # without an owner is being taken by another run.
    if mkdir "$lock_dir" 2>/dev/null && claim_lock; then
      lock_held=1
      trap release_lock EXIT
      return 0
    fi
    owner="$(cat "$lock_dir/owner" 2>/dev/null)" || owner=""
    if { if [[ -n "$owner" ]]; then lock_stale "$owner"; else lock_old "$lock_dir"; fi; } &&
      recover_lock "$owner"; then
      continue
    fi
    [[ "$waited" -lt "$limit" ]] ||
      fail "another --changes holds $lock_dir ($(tr '\n' ' ' <<<"$owner")); nothing was compared or kept. When no status.sh runs, remove that directory."
    sleep 1
    waited=$((waited + 1))
  done
}
if [[ "$changes" -eq 1 ]]; then
  git -C "$primary" check-ignore -q ".agents/status/overview.json" 2>/dev/null ||
    fail "Git does not ignore .agents/status/, where --changes keeps the previous overview. Take over the template's .gitignore with ./scripts/sync-template.sh."
  mkdir -p "$state_dir" || fail "$state_dir cannot be created."
  take_lock
fi

# ------------------------------------------------------------ the features

# The feature worktrees: '<issue> TAB <path> TAB <branch>', one per Issue.
worktrees="$(git -C "$primary" worktree list --porcelain | awk '
  /^worktree / { path = substr($0, 10) }
  /^branch refs\/heads\/feature\/[0-9]+-/ {
    branch = substr($2, 12)
    issue = branch
    sub(/^feature\//, "", issue)
    sub(/-.*/, "", issue)
    if (!(issue in seen)) { seen[issue] = 1; print issue "\t" path "\t" branch }
  }')"

# pr_list <fields> <arguments of gh pr list>: every pull request that the
# query finds, as one JSON array. gh pr list returns at most --limit of them,
# and a result that fills the limit may be cut off: the query is repeated
# with a larger limit until the result is shorter than the limit, so that no
# feature is left out without a word.
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

# The pull requests of feature branches: every open one, and the merged
# pull request of each worktree's branch that has no open one. GitHub that
# cannot be read leaves the pull request unknown, never absent.
github=1
open_prs="[]"
merged_prs="[]"
if ! command -v gh >/dev/null 2>&1; then
  github=0
elif ! open_prs="$(pr_list number,title,url,headRefName,headRefOid,isDraft,mergeable,reviewDecision,statusCheckRollup --state open)"; then
  github=0
  open_prs="[]"
else
  while IFS=$'\t' read -r w_issue _ w_branch; do
    [[ -n "$w_issue" ]] || continue
    ! jq -e --arg prefix "feature/$w_issue-" 'any(.[]; .headRefName | startswith($prefix))' <<<"$open_prs" >/dev/null || continue
    if ! found="$(pr_list number,url,headRefName --state merged --head "$w_branch")"; then
      github=0
      open_prs="[]"
      merged_prs="[]"
      break
    fi
    merged_prs="$(jq -c --argjson found "$found" '. + $found' <<<"$merged_prs")"
  done <<<"$worktrees"
fi
if [[ "$github" -eq 0 ]]; then
  echo "Warning: GitHub could not be read with 'gh'; the pull requests and the titles are unknown." >&2
  # A comparison with unknown pull requests would report changes that did
  # not happen, and lose them for the next comparison.
  [[ "$changes" -eq 0 ]] || fail "--changes needs GitHub; the previous overview is kept as it was."
fi

issues="$({
  [[ -z "$worktrees" ]] || cut -f1 <<<"$worktrees"
  jq -r '.[] | .headRefName | capture("^feature/(?<n>[0-9]+)-").n // empty' <<<"$open_prs"
} | sort -n -u)"

# issue_title <issue>: the title of the Issue, or the title of its pull
# request, or nothing.
issue_title() {
  local title=""

  if [[ "$github" -eq 1 ]]; then
    title="$(cd "$primary" && gh issue view "$1" --json title --jq .title 2>/dev/null)" || title=""
  fi
  [[ -n "$title" ]] || title="$(jq -r --arg prefix "feature/$1-" \
    '[.[] | select(.headRefName | startswith($prefix))] | first | .title // empty' <<<"$open_prs")"
  printf '%s' "$title"
}

# latest_run <issue>: the latest run of the feature as one JSON object, from
# its run records: the command, whether it ended and with which status, the
# step it was in or stopped at, the reason of the stop, the last full
# verification of the feature with its trust and origin, and the PID in the
# run id. A verification started by hand is a run of its own that changes
# nothing in the phase, so it is passed over unless it still runs.
latest_run() {
  records_feature_events "$1" '
    . as $events
    | [$events[] | select(.type == "verification")] | last as $verification
    | [$events[] | select(.type == "run-start")] | sort_by([(.seq // 0), .epoch]) as $starts
    | [$events[] | select(.type == "run-end") | .run] as $ended
    | ([$starts[] | select(.command != "verify.sh" or (.run as $r | any($ended[]; . == $r) | not))] | last) as $start
    | if $start == null then {verification: $verification} else
        [$events[] | select(.run == $start.run)] as $own
        | ($own | map(select(.type == "run-end")) | last) as $end
        | ($own | map(select(.type == "step-start")) | last) as $step
        | ($own | map(select(.type == "stop")) | last) as $stop
        | {run: $start.run, command: $start.command, ended: ($end != null), status: ($end.status // null),
           step: ($step.name // null), stop_step: ($end.step // $stop.step // null),
           reason: ($end.reason // $stop.reason // null), verification: $verification,
           pid: ([$start.run | capture("^[0-9]{8}T[0-9]{6}Z-(?<pid>[0-9]+)-")] | first.pid // null)}
      end'
}

# phase_of <step-name>: the phase of a step of run-feature.sh, as the owner
# reads it.
phase_of() {
  local step="$1"

  case "$step" in
    implementation*) echo "implementing" ;;
    *"review"*", round "*" of at most "*)
      sed -E 's/.*, round ([0-9]+) of at most ([0-9]+).*/review round \1 of \2/' <<<"$step"
      ;;
    "triage of round "* | "publication of the triage of round "*)
      sed -E 's/.*round ([0-9]+).*/triage of round \1/' <<<"$step"
      ;;
    "fixes for round "*) sed -E 's/.*round ([0-9]+).*/fixing, round \1/' <<<"$step" ;;
    *verification*) echo "verifying" ;;
    commit) echo "committing" ;;
    "pull request") echo "publishing" ;;
    "") echo "starting" ;;
    *) printf '%s\n' "$step" ;;
  esac
}

# checks_of <statusCheckRollup-json>: the CI checks of a pull request in a
# few words.
checks_of() {
  jq -r '
    map(if .__typename == "StatusContext" or has("state")
        then (.state // "" | ascii_upcase | if . == "SUCCESS" then "pass" elif . == "PENDING" or . == "EXPECTED" then "pending" else "fail" end)
        else (if (.status // "COMPLETED" | ascii_upcase) != "COMPLETED" then "pending"
              elif (.conclusion // "" | ascii_upcase | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "pass"
              else "fail" end)
        end) as $results
    | if ($results | length) == 0 then "no checks"
      elif any($results[]; . == "fail") then "checks fail (\([$results[] | select(. == "fail")] | length) of \($results | length))"
      elif any($results[]; . == "pending") then "checks pending (\([$results[] | select(. == "pending")] | length) of \($results | length))"
      else "checks pass" end' <<<"$1"
}

# handoff_question <handoff-note>
# Prints the question that the note holds under 'Open questions' on one
# line, and nothing when it holds none. The same reading as open_question
# of run-feature.sh, which only asks whether there is one: the next blank
# line after the question, a heading, or another part of the note ends it.
handoff_question() {
  [[ -f "$1" ]] || return 0
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
    found && tolower($0) ~ /^[[:space:]]*([-*][[:space:]]*)?\**(done|in progress|remaining( work)?|tried and rejected|clarification)\**[[:space:]]*:/ {
      if (text != "") exit
      found = 0
      next
    }
    found {
      line = $0
      sub(/^[[:space:]]*([-*][[:space:]]+)?/, "", line)
      text = text " " line
    }
    END {
      gsub(/[[:space:]]+/, " ", text)
      gsub(/^[[:space:]*:-]+|[[:space:]]+$/, "", text)
      if (text == "" || tolower(text) ~ /^(none|no |n\/a|nothing)/) exit
      print text
    }' "$1"
}

# approval_request <issue> <head-oid>: whether the commit at the head of the
# pull request holds the approval request that finish-feature.sh commits:
# 'yes', 'no', or 'unknown'. The commit is read here when Git has it, in any
# worktree or fetched ref; otherwise from GitHub. A head that cannot be read
# is unknown, never a head without a request: a missing or stale branch here
# says nothing about the pull request.
approval_request() {
  local path=".agents/approval-requests/$1.json" err

  if [[ ! "$2" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo unknown
  elif git -C "$primary" cat-file -e "$2^{commit}" 2>/dev/null; then
    if git -C "$primary" cat-file -e "$2:$path" 2>/dev/null; then echo yes; else echo no; fi
  elif err="$(cd "$primary" && gh api "repos/{owner}/{repo}/contents/$path?ref=$2" --silent 2>&1)"; then
    echo yes
  elif grep -q "HTTP 404" <<<"$err"; then
    echo no
  else
    echo unknown
  fi
}

# A row per feature, as one JSON object:
# {issue, title, phase, exit, verification, pull_request, url, decisions}.
rows="[]"
while IFS= read -r issue; do
  [[ -n "$issue" ]] || continue
  worktree="$(awk -F '\t' -v issue="$issue" '$1 == issue { print $2 }' <<<"$worktrees")"
  title="$(issue_title "$issue")"
  pr="$(jq -c --arg prefix "feature/$issue-" '[.[] | select(.headRefName | startswith($prefix))] | sort_by(.number) | last // empty' <<<"$open_prs")"
  merged=""
  [[ -n "$pr" ]] || merged="$(jq -c --arg prefix "feature/$issue-" '[.[] | select(.headRefName | startswith($prefix))] | sort_by(.number) | last // empty' <<<"$merged_prs")"
  run="$(cd "$primary" && latest_run "$issue")"
  [[ -n "$run" ]] || run='{}'
  decisions=()
  # The open question of the handoff note, which a decision names.
  question=""
  [[ -z "$worktree" ]] || question="$(handoff_question "$worktree/.agents/handoffs/$issue.md")"

  # The gate of the implementer's completion record, as every script reads it.
  gate=""
  gate_status=""
  if [[ -n "$worktree" && -d "$worktree" ]]; then
    gate="$(completion_gate "$worktree" "$issue" 2>/dev/null)" || gate=""
    gate_status="$(sed -n 1p <<<"$gate")"
  fi

  # The phase, from the latest run.
  exit_status=""
  command="$(jq -r '.command // empty' <<<"$run")"
  reason="$(jq -r '.reason // empty' <<<"$run" | tr '\n\t' '  ')"
  continue_command="./scripts/run-feature.sh $issue"
  if [[ -z "$command" ]]; then
    phase="no run recorded"
    [[ -z "$gate_status" ]] || phase="no run recorded; completion: $gate_status"
  elif [[ "$(jq -r '.ended' <<<"$run")" == "false" ]]; then
    pid="$(jq -r '.pid // empty' <<<"$run")"
    step_phase="$(phase_of "$(jq -r '.step // empty' <<<"$run")")"
    [[ "$command" == "run-feature.sh" ]] || step_phase="$command"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      phase="$step_phase"
    else
      phase="interrupted ($step_phase)"
      decisions+=("the run ended without a record of its end, killed or crashed: look at .agents/run/$issue-log, then run $continue_command")
    fi
  else
    exit_status="$(jq -r '.status' <<<"$run")"
    if [[ "$exit_status" == "0" ]]; then
      exit_status=""
      if [[ "$command" != "run-feature.sh" ]]; then
        phase="$command finished"
      elif [[ -n "$pr" ]]; then
        phase="published"
      else
        phase="finished"
      fi
    else
      phase="stopped ($(phase_of "$(jq -r '.stop_step // empty' <<<"$run")"))"
      [[ "$command" == "run-feature.sh" ]] || phase="stopped ($command)"
      case "$exit_status" in
        3) decisions+=("your decision: ${question:-${reason:-an agent needs it}}; answer in .agents/handoffs/$issue.md, then run $continue_command") ;;
        75) decisions+=("run again when the slot for heavy verification is free: $continue_command") ;;
        # A prerequisite of the machine that ran it is missing: nothing for
        # the feature to fix, and nothing to answer, only to install.
        78) decisions+=("install what this machine lacks: ${reason:-a prerequisite is missing}; ./scripts/doctor.sh lists every prerequisite; then run $continue_command") ;;
        130) decisions+=("the run was interrupted; continue with $continue_command") ;;
        *)
          if grep -Eq 'review rounds are used' <<<"$reason"; then
            decisions+=("the review rounds are used: ${reason}; raise the limit with $continue_command --rounds <m>, or record an exception with ./scripts/record-exception.sh")
          elif grep -Eq 'conflict' <<<"$reason"; then
            decisions+=("resolve the conflict with the base: ${reason}; then run $continue_command")
          else
            decisions+=("the run stopped: ${reason:-no reason recorded}; see .agents/run/$issue-log, then run $continue_command")
          fi
          ;;
      esac
    fi
  fi
  # A blocked completion record that no stopped run names yet.
  if [[ "$gate_status" == "blocked" && "$exit_status" != "3" ]]; then
    decisions+=("the implementer is blocked on a question: ${question:+$question; }answer it in .agents/handoffs/$issue.md, then run $continue_command")
  fi

  # The pull request.
  pull_request=""
  url=""
  if [[ "$github" -eq 0 ]]; then
    pull_request="unknown"
  elif [[ -n "$pr" ]]; then
    number="$(jq -r '.number' <<<"$pr")"
    url="$(jq -r '.url' <<<"$pr")"
    checks="$(checks_of "$(jq -c '.statusCheckRollup // []' <<<"$pr")")"
    mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$pr")"
    case "$mergeable" in
      MERGEABLE) merge_text="mergeable" ;;
      CONFLICTING) merge_text="conflicting" ;;
      *) merge_text="mergeability unknown" ;;
    esac
    draft=""
    [[ "$(jq -r '.isDraft' <<<"$pr")" != "true" ]] || draft="draft, "
    pull_request="#$number (${draft}$checks, $merge_text)"
    head="$(jq -r '.headRefOid // empty' <<<"$pr")"
    approval="$(approval_request "$issue" "$head")"
    review="$(jq -r '.reviewDecision // ""' <<<"$pr")"
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      decisions+=("the pull request #$number conflicts with its base: run ./scripts/update-feature.sh $issue in the feature worktree")
    fi
    if [[ "$checks" == "checks fail"* ]]; then
      decisions+=("$checks on #$number: $url")
    fi
    # A merge is offered only when nothing stands in its way: checks that
    # exist and pass, no review that requests changes, no approving review
    # that GitHub still requires, and an approval request of the pull
    # request's own head that is read, and approved when there is one.
    if [[ "$review" == "CHANGES_REQUESTED" ]]; then
      decisions+=("a review requests changes on #$number: settle the review before a merge: $url")
    elif [[ "$approval" == "unknown" ]]; then
      decisions+=("whether #$number needs your approval is unknown: its head ${head:0:12} cannot be read here or on GitHub; fetch it with git fetch origin and run ./scripts/status.sh again, or look at $url")
    elif [[ "$approval" == "yes" && "$review" != "APPROVED" ]]; then
      decisions+=("your approval: review and approve #$number, which only you may merge (.agents/approval-requests/$issue.json): $url")
    elif [[ "$review" == "REVIEW_REQUIRED" ]]; then
      decisions+=("a required review is missing on #$number: GitHub needs an approving review before a merge: $url")
    elif [[ -z "$draft" && "$checks" == "no checks" ]]; then
      decisions+=("no CI check has reported on #$number: look at its checks before a merge: $url")
    elif [[ -z "$draft" && "$mergeable" == "MERGEABLE" && "$checks" == "checks pass" ]]; then
      decisions+=("merge #$number: $url")
    fi
  elif [[ -n "$merged" ]]; then
    number="$(jq -r '.number' <<<"$merged")"
    url="$(jq -r '.url' <<<"$merged")"
    pull_request="#$number (merged)"
    phase="merged"
    exit_status=""
    decisions=()
    # A criterion whose evidence record-post-merge.sh recorded on the Issue
    # is no longer pending: the completion record is not changed after the
    # merge, the comments are.
    pending="$(sed -n 's/^pending at post_merge: //p' <<<"$gate")"
    if [[ -n "$pending" ]]; then
      recorded_known=1
      recorded="$(cd "$primary" && github_post_merge_recorded "$issue" 2>/dev/null)" || recorded_known=0
      while IFS= read -r criterion; do
        if [[ "$recorded_known" -eq 1 ]] && grep -Fqx -- "$criterion" <<<"$recorded"; then
          continue
        fi
        decision="record the post-merge evidence: ./scripts/record-post-merge.sh $issue \"$criterion\" \"<evidence>\""
        [[ "$recorded_known" -eq 1 ]] ||
          decision+=" (the comments of Issue #$issue cannot be read: the evidence may be recorded already)"
        decisions+=("$decision")
      done <<<"$pending"
    fi
  fi

  # The last full verification of the feature, and which evidence counted.
  verification="$(jq -r '.verification // empty
    | if . == null then empty else
        (if .status == 0 then "passed" else "failed" end)
        + (if .reused == true then ", reused" else "" end)
        + (if .trusted == true then ", trusted" elif .status == 0 then ", not trusted" else "" end)
        + (if (.origin // "") != "" then " (\(.origin))" else "" end)
      end' <<<"$run")"

  decisions_json="$(printf '%s\n' "${decisions[@]+"${decisions[@]}"}" | jq -R . | jq -sc 'map(select(length > 0) | gsub("[\t\r\n]"; " "))')"
  rows="$(jq -c --arg issue "$issue" --arg title "$title" --arg phase "$phase" --arg exit "$exit_status" \
    --arg verification "$verification" --arg pull_request "$pull_request" --arg url "$url" --argjson decisions "$decisions_json" \
    '. + [{issue: ($issue | tonumber), title: ($title | gsub("[\t\r\n]"; " ")), phase: ($phase | gsub("[\t\r\n]"; " ")), exit: $exit,
           verification: $verification, pull_request: $pull_request, url: $url, decisions: $decisions}]' <<<"$rows")"
done <<<"$issues"

# ------------------------------------------------------------ the output

# render <rows-json>: the rows as a table, for the terminal or in Markdown.
render() {
  if [[ "$markdown" -eq 1 ]]; then
    jq -r '
      def cell: tostring | gsub("\\|"; "\\|") | gsub("[\r\n]"; " ");
      "| Issue | Title | Phase | Exit | Verification | Pull request | Owner decision needed |",
      "|---|---|---|---|---|---|---|",
      (.[] | "| #\(.issue) | \(.title | cell) | \(.phase | cell) | \(.exit | cell) | \(.verification | cell) | "
        + (if .url != "" then "[\(.pull_request | split(" ")[0])](\(.url)) \(.pull_request | split(" ")[1:] | join(" ") | cell)" else (.pull_request | cell) end)
        + " | \(.decisions | map(cell) | join("<br>")) |")' <<<"$1"
  else
    jq -r '.[] |
      "#\(.issue)  \(.title)",
      "  phase: \(.phase)\(if .exit != "" then ", exit status \(.exit)" else "" end)",
      (if .verification != "" then "  verification: \(.verification)" else empty end),
      (if .pull_request != "" then "  pull request: \(.pull_request)\(if .url != "" then " \(.url)" else "" end)" else "  pull request: none" end),
      (if (.decisions | length) == 0 then "  owner decision needed: none"
       else "  owner decision needed:", (.decisions[] | "    - \(.)") end),
      ""' <<<"$1"
  fi
}

if [[ "$changes" -eq 0 ]]; then
  if [[ "$rows" == "[]" ]]; then
    echo "No feature has a worktree or an open pull request."
  else
    render "$rows"
  fi
  exit 0
fi

# --changes: what differs from the previous overview, which is kept in a
# directory that Git ignores, like the run records. The lock is held.
previous_file="$state_dir/overview.json"
previous="[]"
if [[ -f "$previous_file" ]] && jq -e 'type == "array"' "$previous_file" >/dev/null 2>&1; then
  previous="$(cat "$previous_file")"
fi
# The fields that make a change; the URL follows the pull request.
diff_json="$(jq -c --argjson previous "$previous" '
  def key: {issue, title, phase, exit, verification, pull_request, decisions};
  ($previous | map({key: (.issue | tostring), value: .}) | from_entries) as $before
  | (map({key: (.issue | tostring), value: .}) | from_entries) as $now
  | {changed: [.[] | select(($before[.issue | tostring] | if . == null then null else key end) != key)],
     gone: [$previous[] | select($now[.issue | tostring] == null) | .issue],
     new_decisions: [.[] | . as $row | ($before[.issue | tostring].decisions // []) as $old
       | .decisions[] | select(. as $d | $old | index([$d]) | not) | {issue: $row.issue, decision: .}]}' <<<"$rows")"

output="$(
  if [[ "$(jq '.changed | length' <<<"$diff_json")" -gt 0 ]]; then
    render "$(jq -c '.changed' <<<"$diff_json")"
  fi
  jq -r '.gone[] | "#\(.): no longer listed (no worktree and no open pull request)"' <<<"$diff_json"
  if [[ "$(jq '.new_decisions | length' <<<"$diff_json")" -gt 0 ]]; then
    [[ "$markdown" -eq 0 ]] || echo
    echo "New owner decisions:"
    jq -r '.new_decisions[] | "- #\(.issue): \(.decision)"' <<<"$diff_json"
  fi
)"

[[ -n "$output" ]] || exit 0
printf '%s\n' "$output"

# The notification hook of the primary checkout: one line 'command: <shell
# command>' in .agents/notify.conf, which gets the changes on standard input.
hook=""
if [[ -f "$primary/.agents/notify.conf" ]]; then
  hook="$(sed -n 's/^command:[[:space:]]*//p' "$primary/.agents/notify.conf" | sed -n 1p)"
fi
if [[ -n "$hook" ]]; then
  hook_status=0
  printf '%s\n' "$output" | (cd "$primary" && bash -c "$hook") >&2 || hook_status=$?
  if [[ "$hook_status" -ne 0 ]]; then
    echo "Error: the notification hook of .agents/notify.conf failed (status $hook_status). The changes are kept and reported again by the next --changes." >&2
    exit 1
  fi
fi

# The overview is kept only now, so a change that the hook did not deliver
# is reported again.
printf '%s\n' "$rows" >"$previous_file.tmp" && mv "$previous_file.tmp" "$previous_file" ||
  fail "the overview could not be kept in $previous_file."
