#!/usr/bin/env bash

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

# The pull requests of feature branches. GitHub that cannot be read leaves
# the pull request unknown, never absent.
github=1
open_prs="[]"
merged_prs="[]"
if ! command -v gh >/dev/null 2>&1; then
  github=0
elif ! open_prs="$(cd "$primary" && gh pr list --state open --limit 200 \
  --json number,title,url,headRefName,isDraft,mergeable,reviewDecision,statusCheckRollup 2>/dev/null)" ||
  ! jq -e 'type == "array"' <<<"$open_prs" >/dev/null 2>&1; then
  github=0
  open_prs="[]"
elif [[ -n "$worktrees" ]] && ! merged_prs="$(cd "$primary" && gh pr list --state merged --limit 200 \
  --json number,url,headRefName 2>/dev/null)"; then
  github=0
  merged_prs="[]"
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
    approval=0
    if [[ -n "$worktree" ]]; then
      [[ ! -f "$worktree/.agents/approval-requests/$issue.json" ]] || approval=1
    elif git -C "$primary" cat-file -e "refs/remotes/origin/$(jq -r '.headRefName' <<<"$pr"):.agents/approval-requests/$issue.json" 2>/dev/null; then
      # Without a worktree here, the branch as it was last fetched.
      approval=1
    fi
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      decisions+=("the pull request #$number conflicts with its base: run ./scripts/update-feature.sh $issue in the feature worktree")
    fi
    if [[ "$checks" == "checks fail"* ]]; then
      decisions+=("$checks on #$number: $url")
    fi
    if [[ "$approval" -eq 1 && "$(jq -r '.reviewDecision // ""' <<<"$pr")" != "APPROVED" ]]; then
      decisions+=("your approval: review and approve #$number, which only you may merge (.agents/approval-requests/$issue.json): $url")
    elif [[ -z "$draft" && "$mergeable" == "MERGEABLE" && "$checks" != "checks fail"* && "$checks" != "checks pending"* ]]; then
      decisions+=("merge #$number: $url")
    fi
  elif [[ -n "$merged" ]]; then
    number="$(jq -r '.number' <<<"$merged")"
    url="$(jq -r '.url' <<<"$merged")"
    pull_request="#$number (merged)"
    phase="merged"
    exit_status=""
    decisions=()
    pending="$(sed -n 's/^pending at post_merge: //p' <<<"$gate")"
    if [[ -n "$pending" ]]; then
      while IFS= read -r criterion; do
        decisions+=("record the post-merge evidence: ./scripts/record-post-merge.sh $issue \"$criterion\" \"<evidence>\"")
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
# directory that Git ignores, like the run records.
state_dir="$primary/.agents/status"
git -C "$primary" check-ignore -q ".agents/status/overview.json" 2>/dev/null ||
  fail "Git does not ignore .agents/status/, where --changes keeps the previous overview. Take over the template's .gitignore with ./scripts/sync-template.sh."
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
mkdir -p "$state_dir" || fail "$state_dir cannot be created."
printf '%s\n' "$rows" >"$previous_file.tmp" && mv "$previous_file.tmp" "$previous_file" ||
  fail "the overview could not be kept in $previous_file."
