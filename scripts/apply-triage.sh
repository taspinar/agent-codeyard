#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/base.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/verification.sh"
source "$script_dir/lib/skills.sh"
source "$script_dir/lib/completion.sh"

usage() {
  echo "Usage: $0 <triage-json> [--agent <agent>] [--model <model>] [--unattended] [--continue] [--checks <group>[,<group>...] | --caller-verifies]"
  echo
  echo "--continue takes up a fix session of this triage that was interrupted after"
  echo "it had changed files. The review is then no longer current, which is refused"
  echo "otherwise; everything else is as for a new session: the same findings, the"
  echo "same contract, the same protection of the review and the triage. It is"
  echo "refused when no session of this triage was started and left unfinished."
  echo
  echo "--checks verifies the result with only the named groups of ./scripts/verify.sh"
  echo "(--only), and tells the agent to do the same, for an intermediate round that"
  echo "you run by hand (run-feature.sh never asks for one). A partial check is not a"
  echo "verification: it records nothing, and the full verification runs before"
  echo "the commit."
  echo
  echo "--caller-verifies runs no verification after the session: the script that"
  echo "started this one makes the full verification of the result itself, as"
  echo "run-feature.sh does before the next review round, and its pass is the one the"
  echo "review and the commit reuse. A failure there is repaired as any failed"
  echo "verification of the run."
  echo
  echo "The agent and model come from role 'triage-implementer' in"
  echo ".agents/agents.conf unless --agent and --model are given."
  echo
  echo "Examples:"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.json"
  echo "  $0 .agents/triage/feature-5-rendering-review-01-triage.json --agent claude --model opus"
  exit 1
}

report_errors() {
  echo "Error: $1" >&2
  printf '%s\n' "$2" | sed 's/^/  - /' >&2
  exit 1
}

continue_session=0
checks=""
caller_verifies=0
arguments=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--continue" ]]; then
    continue_session=1
  elif [[ "$1" == "--checks" ]]; then
    [[ $# -ge 2 && "$2" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] || {
      echo "Error: --checks requires the groups of verify.sh to run, separated by commas." >&2
      exit 1
    }
    checks="$2"
    shift
  elif [[ "$1" == "--caller-verifies" ]]; then
    caller_verifies=1
  else
    arguments+=("$1")
  fi
  shift
done
agent_parse_args ${arguments[@]+"${arguments[@]}"}
if [[ "${#AGENT_POSITIONAL[@]}" -ne 1 ]]; then
  usage
fi
if [[ -n "$checks" && "$caller_verifies" -eq 1 ]]; then
  echo "Error: --checks and --caller-verifies exclude each other: a partial check runs here, --caller-verifies leaves the verification to the caller." >&2
  exit 1
fi

triage_input="${AGENT_POSITIONAL[0]}"
records_wrap feature "$(records_branch_issue)" "$0" ${records_arguments[@]+"${records_arguments[@]}"}

root="$(git rev-parse --show-toplevel)"
prompt_file="$root/.agents/prompts/triage-implementer.md"

if [[ ! -f "$triage_input" ]]; then
  echo "Error: triage artifact not found: $triage_input"
  records_stop "${0##*/}" "triage artifact not found: $triage_input"
  exit 1
fi

triage_dir="$(cd "$(dirname "$triage_input")" && pwd -P)"
triage_path="$triage_dir/$(basename "$triage_input")"

if [[ "$triage_path" != "$root/.agents/triage/"*.json ]]; then
  echo "Error: triage artifact must match .agents/triage/*.json (the generated .md report is not an input)."
  echo "Received: $triage_path"
  records_stop "${0##*/}" "triage artifact must match .agents/triage/*.json (the generated .md report is not an input)."
  exit 1
fi

if [[ ! -f "$prompt_file" ]]; then
  echo "Error: triage implementer prompt not found: $prompt_file"
  records_stop "${0##*/}" "triage implementer prompt not found: $prompt_file"
  exit 1
fi

review_data_require_jq

# The agent of the triage implementer by the risk level of the feature as it
# is now, never below the level an earlier session of the feature ran at
# (lib/agent.sh).
apply_base="$(branch_base "$root")" || exit 1
agent_computed="$(agent_computed_level "$root" "$apply_base")"
agent_selected="$(agent_feature_level "$(records_branch_issue)" "${agent_computed%%$'\t'*}" "${agent_computed#*$'\t'}")"
agent_level="${agent_selected%%$'\t'*}"
agent_level_why="${agent_selected#*$'\t'}"
agent_resolve "$root" triage-implementer "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL" "$agent_level"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

source_review_relative="$(triage_source_review "$triage_path")"
if [[ -z "$source_review_relative" ]]; then
  echo "Error: the file is not a triage/v1 artifact with a source review: $triage_input"
  records_stop "${0##*/}" "the file is not a triage/v1 artifact with a source review: $triage_input"
  exit 1
fi
if [[ ! "$source_review_relative" =~ ^\.agents/reviews/[^/]+\.json$ ]]; then
  echo "Error: source review must match .agents/reviews/*.json: $source_review_relative"
  records_stop "${0##*/}" "source review must match .agents/reviews/*.json: $source_review_relative"
  exit 1
fi
source_review_path="$root/$source_review_relative"
if [[ ! -f "$source_review_path" ]]; then
  echo "Error: source review artifact not found: $source_review_relative"
  records_stop "${0##*/}" "source review artifact not found: $source_review_relative"
  exit 1
fi

# Both stored artifacts are checked with the same rules as agent output, so an
# edited artifact cannot weaken a decision.
review_errors="$(review_artifact_errors "$source_review_path")"
[[ -z "$review_errors" ]] || report_errors "invalid source review artifact:" "$review_errors"

triage_errors="$(triage_artifact_errors "$triage_path" "$source_review_path")"
[[ -z "$triage_errors" ]] || report_errors "invalid or unapproved triage artifact:" "$triage_errors"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/apply-triage.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT
review_path="$source_review_path"
review_relative="$source_review_relative"
fail() {
  echo "Error: $*" >&2
  records_stop "${0##*/}" "$*"
  exit 1
}

# Triage and fixes apply only to the content that was reviewed.
stale_status=0
review_is_current "$root" "$tmp_work" "$review_path" || stale_status=$?
case "$stale_status" in
  0) ;;
  1)
    # A session that was interrupted after it changed files is taken up
    # with --continue, and only that: the mark of the unfinished session
    # must name this triage. Every other stale review is refused.
    started_mark="$root/.agents/run/$(jq -r '.issue' "$triage_path")-fixes-started"
    # The mark holds the triage and what the review and the triage were when
    # the session started; a session is continued only on exactly those.
    expected_mark="${triage_path#"$root"/}"$'\n'"$(git hash-object "$review_path")"$'\n'"$(git hash-object "$triage_path")"
    if [[ "$continue_session" -eq 1 && -f "$started_mark" && "$(cat "$started_mark")" == "$expected_mark" ]]; then
      echo "Continuing the interrupted fix session of ${triage_path#"$root"/}."
    else
      review_stale_notice "$root" "$tmp_work" "$review_path"
      if [[ "$continue_session" -eq 1 ]]; then
        fail "--continue found no unfinished fix session of this triage with this review and triage as they were then, and the review is stale. Run a new review."
      fi
      fail "the review is stale: the reviewed content changed after $review_relative was written. Run a new review."
    fi
    ;;
  *) fail "could not compute the current fingerprint of the working tree." ;;
esac

source_issue="$(jq -r '.issue' "$triage_path")"

branch="$(git branch --show-current)"
if [[ "$branch" != feature/* ]]; then
  echo "Error: apply-triage.sh must run in an existing feature worktree."
  echo "Current branch: $branch"
  records_stop "${0##*/}" "apply-triage.sh must run in an existing feature worktree."
  exit 1
fi

if [[ "$branch" != feature/${source_issue}-* ]]; then
  echo "Error: current branch does not match source Issue #$source_issue."
  echo "Current branch: $branch"
  records_stop "${0##*/}" "current branch does not match source Issue #$source_issue."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI 'gh' is not installed."
  records_stop "${0##*/}" "GitHub CLI 'gh' is not installed."
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "Run: gh auth login"
  records_stop "${0##*/}" "GitHub CLI is not authenticated."
  exit 1
fi
resolved_issue="$(gh issue view "$source_issue" --json number --template '{{.number}}')"
if [[ "$resolved_issue" != "$source_issue" ]]; then
  echo "Error: could not validate source Issue #$source_issue."
  records_stop "${0##*/}" "could not validate source Issue #$source_issue."
  exit 1
fi

fix_count="$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage_path")"
if [[ "$fix_count" -eq 0 ]]; then
  echo "No FIX_NOW findings found; no implementation agent was started."
  echo "Next: finish the feature:"
  echo "  ./scripts/finish-feature.sh $source_issue \"<commit summary>\""
  exit 0
fi

triage_relative="${triage_path#"$root"/}"
fix_scope="$(jq -r --slurpfile review "$source_review_path" '
  .decisions[] | select(.decision == "FIX_NOW") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n" +
    "- Severity: \($f.severity)\n" +
    "- Evidence: \($f.evidence)\n" +
    "- Impact: \($f.impact)\n" +
    "- Recommended action: \($f.recommendation)\n" +
    "- Triage rationale: \($d.rationale)\n"
' "$triage_path")"

# The project skills that the plan selects (lib/skills.sh), the files the
# implementer and the reviewer were given.
skills_resolve "$root" "$source_issue" ||
  fail "the project skills that the plan of Issue #$source_issue selects do not resolve:"$'\n'"$(skills_problems_text)"$'\n'"Correct the selection in the plan or the skill, and review again."

echo "Approved FIX_NOW scope from $triage_relative:"
echo
printf '%s\n' "$fix_scope"
echo "Findings to resolve: $fix_count"
echo
if [[ "$AGENT_UNATTENDED" -eq 1 ]]; then
  agent_require_ignored "$root" ".agents/run/$source_issue-fixes.md"
  echo "Starting an unattended $agent agent for this scope (--unattended)."
else
  printf "Start a write-capable $agent agent for this scope? [y/N] "
  read -r approval
  case "$approval" in
    y | Y | yes | YES) ;;
    *)
      echo "Apply triage declined; no implementation agent was started."
      exit 0
      ;;
  esac
fi

start_prompt="Read and follow .agents/prompts/triage-implementer.md.

Source feature Issue: ${source_issue:-unknown}
Source review artifact: ${source_review_relative}
Approved triage artifact: ${triage_relative}

Resolve exactly these approved FIX_NOW findings:

${fix_scope}

Do not implement any DEFER or ACCEPT finding.
Do not commit, push, merge, deploy, or create/close Issues.

Record the check of each finding in the handoff note of the Issue under
the heading '## Triage ${triage_relative##*/}', one line per finding, as your
contract says under 'Each finding: its class, and a check before the change'."
start_prompt+="$(skills_prompt "$SKILLS_FILES")"
if [[ -n "$source_issue" && -f "$root/.agents/handoffs/$source_issue.md" ]]; then
  start_prompt+="

There is a handoff note: .agents/handoffs/$source_issue.md. Read it first; it
may hold the human's answer to a question of an earlier session."
fi
if [[ -n "$checks" ]]; then
  start_prompt+="

This is an intermediate round: after your last change run
./scripts/verify.sh --only $checks
instead of the full ./scripts/verify.sh, as the caller asked for this round
(--checks). A partial run is not a verification: it records nothing and cannot be
cited as evidence in the completion record; the full verification runs
before the commit."
fi

echo
# The mark of a session that has started and not finished; --continue needs
# it. It is removed when the fixes are made and verified.
started_mark="$root/.agents/run/$source_issue-fixes-started"
if git -C "$root" check-ignore -q ".agents/run/$source_issue-fixes-started" 2>/dev/null; then
  mkdir -p "$(dirname "$started_mark")"
  # Kept as it was for a continued session: the first start decides.
  [[ "$continue_session" -eq 1 && -f "$started_mark" ]] ||
    printf '%s\n%s\n%s\n' "$triage_relative" "$(git hash-object "$source_review_path")" "$(git hash-object "$triage_path")" >"$started_mark"
fi
if [[ "$continue_session" -eq 1 ]]; then
  start_prompt+="

You are continuing a fix session that was interrupted. An earlier session may
have resolved part of these findings: inspect the working tree and the diff
first, keep what is done, and finish the rest. The scope is unchanged."
fi

echo "Starting $agent implementation agent ($model)..."
echo "  Level:    $agent_level ($agent_level_why)"
echo "  Selected: by $(agent_selection_text)"
echo

final_message="$root/.agents/run/$source_issue-fixes.md"
blocked=""
set +e
if [[ "$AGENT_UNATTENDED" -eq 1 ]]; then
  mkdir -p "$(dirname "$final_message")"
  rm -f "$final_message"
  agent_run unattended "$agent" "$model" "$root" "$start_prompt

$AGENT_UNATTENDED_PROMPT" "$final_message"
  agent_status=$?
  if [[ -s "$final_message" ]]; then
    echo "Final message of the implementer:"
    echo
    sed 's/^/  /' "$final_message"
  fi
  blocked="$(agent_blocked_reason "$final_message")"
else
  agent_run write "$agent" "$model" "$root" "$start_prompt"
  agent_status=$?
fi
set -e
# The protected artifacts that this session changed (lib/agent.sh), kept
# before any later session: agent_run resets AGENT_ARTIFACTS_CHANGED at its
# start, so a correcting session must not be what hides this change.
artifacts_changed="$AGENT_ARTIFACTS_CHANGED"

# The completion record that the session left is checked now, with the rules
# of the completion gate (lib/completion.sh, completion_errors), and not only
# at the commit after the next review: a record that cites a partial run of
# the checks as evidence, for example, would cost a review round there. An
# unattended session gets one session to correct it, with the errors; an
# interactive one stops here, before the verification, for the human to
# correct it. A missing record is an error of the gate as well: without one
# the feature would reach the review only to be refused at the commit.
fix_record_errors() {
  if [[ -f "$completion_file" ]]; then
    completion_errors "$completion_file" "$root"
  else
    echo "there is no completion record: write it as .agents/prompts/implementer.md describes under 'Completion'"
  fi
}
record_errors=""
if [[ "$agent_status" -eq 0 && -z "$blocked" && -z "$artifacts_changed" && -n "$source_issue" ]]; then
  completion_file="$(completion_record "$root" "$source_issue")"
  record_errors="$(fix_record_errors)"
  if [[ -n "$record_errors" && "$AGENT_UNATTENDED" -eq 1 ]]; then
    echo
    echo "The completion record ($COMPLETION_DIR/$source_issue.json) does not pass the completion gate:"
    printf '%s\n' "$record_errors" | sed 's/^/  - /'
    echo "Starting a session of the $agent agent to correct it."
    set +e
    agent_run unattended "$agent" "$model" "$root" "Read and follow .agents/prompts/triage-implementer.md.

You applied the approved FIX_NOW findings of ${triage_relative} for Issue #${source_issue}.
The completion record $COMPLETION_DIR/$source_issue.json that you left does not
pass the completion gate:

$(printf '%s\n' "$record_errors" | sed 's/^/- /')

Correct only the completion record, as .agents/prompts/implementer.md
describes it under 'Completion'. A partial run of the checks
(./scripts/verify.sh --changed or --only) is no evidence: for a criterion that
the full verification shows, the evidence is the pass that run-feature.sh
makes after your session. Change no other file.

$AGENT_UNATTENDED_PROMPT" "$final_message"
    agent_status=$?
    set -e
    artifacts_changed="$AGENT_ARTIFACTS_CHANGED"
    blocked="$(agent_blocked_reason "$final_message")"
    record_errors=""
    [[ "$agent_status" -ne 0 || -n "$blocked" ]] ||
      record_errors="$(fix_record_errors)"
  fi
fi

# Each session ran inside the artifact manifest of agent_run (lib/agent.sh),
# which covers the review and the triage this session works from. The first
# session's result was checked before the correcting session (which starts
# only when it changed nothing protected); the correcting session's result
# is checked here.
protected_artifact_changed=0
protected_artifact_reason=""
if [[ -n "$artifacts_changed" ]]; then
  echo "Error: implementation agent modified artifacts that it may only read: ${artifacts_changed//$'\n'/, }."
  protected_artifact_changed=1
  protected_artifact_reason="implementation agent modified artifacts that it may only read: ${artifacts_changed//$'\n'/, }."
fi

if [[ -n "$record_errors" && -z "$artifacts_changed" ]]; then
  echo "Error: the completion record ($COMPLETION_DIR/$source_issue.json) does not pass the completion gate:" >&2
  printf '%s\n' "$record_errors" | sed 's/^/  - /' >&2
  echo "Correct it as .agents/prompts/implementer.md describes under 'Completion', then review again: ./scripts/review-feature.sh $source_issue" >&2
  records_stop "${0##*/}" "the completion record does not pass the completion gate: ${record_errors//$'\n'/; }"
  exit 1
fi

# The fixed content must pass verification. A pass recorded for exactly this
# content is not repeated, except where the trust contract does not trust it
# (lib/verification.sh): with the trusted passes of a run, only one of them;
# with --unattended and without them, none. With --checks only the named
# groups run: a partial check, which records nothing. With --caller-verifies
# nothing runs here: the caller verifies the result itself.
echo
set +e
if [[ "$caller_verifies" -eq 1 ]]; then
  echo "Not verifying here: the caller makes the full verification of the result (--caller-verifies)."
  true
elif [[ -n "$checks" ]]; then
  echo "Running only the groups ${checks//,/, } of the verification (a partial check, not a verification)..."
  (
    cd "$root"
    ./scripts/verify.sh --only "$checks"
  )
else
  echo "Checking repository verification..."
  verification_run "$root" script "$AGENT_UNATTENDED"
fi
verification_status=$?
set -e

if [[ "$protected_artifact_changed" -ne 0 ]]; then
  # Status 5: a session changed the review or the triage it works from. It
  # is not tried again and not continued; the mark is removed.
  rm -f "$started_mark"
  records_stop "${0##*/}" "$protected_artifact_reason"
  exit 5
fi

if [[ "$agent_status" -eq 0 && -n "$blocked" ]]; then
  echo "The implementer stopped because it needs you: $blocked" >&2
  echo "Answer in the handoff note or change the triage, then continue with ./scripts/start-feature.sh $source_issue --resume, and review again." >&2
  if [[ "$verification_status" -ne 0 ]]; then
    echo "Repository verification also failed with status $verification_status." >&2
  fi
  records_stop "${0##*/}" "The implementer stopped because it needs you: $blocked"
  exit 3
fi

if [[ "$agent_status" -ne 0 ]]; then
  echo "Error: implementation agent exited with status $agent_status."
  echo "Continue the fixes with ./scripts/start-feature.sh $source_issue --resume, then review again."
  if [[ "$verification_status" -ne 0 ]]; then
    echo "Repository verification also failed with status $verification_status."
  fi
  records_stop "${0##*/}" "implementation agent exited with status $agent_status."
  # The statuses 3, 4, and 5 have a meaning of their own in the workflow:
  # a blocked session, a failed verification, and a changed review or
  # triage. An agent that happens to exit with one of them just failed.
  [[ "$agent_status" -lt 3 || "$agent_status" -gt 5 ]] || agent_status=1
  exit "$agent_status"
fi

if [[ "$verification_status" -eq 78 ]]; then
  # A prerequisite of this machine is missing (verify.sh, the ENVIRONMENT
  # lines above): not a failure of the fixes. The status is passed on
  # unchanged, so that a caller does not repair the code for it.
  echo "Error: the verification could not run: a prerequisite of this machine is missing (the ENVIRONMENT lines above). The fixes were made; install what is missing, then verify again."
  records_stop "${0##*/}" "the verification could not run: a prerequisite of this machine is missing."
  exit 78
fi
if [[ "$verification_status" -ne 0 ]]; then
  echo "Error: repository verification failed with status $verification_status."
  # Status 4 tells a caller that the fixes were made and the verification
  # failed, apart from a failed agent.
  records_stop "${0##*/}" "repository verification failed with status $verification_status."
  exit 4
fi

# The implementer's check of each finding (lib/completion.sh). A finding it
# returned, or recorded no check for, stays FIX_NOW: no script resolves or
# refutes it; a later fix recorded as fixed, or a new triage, decides.
report_checks() {
  local outcomes
  local returned
  local unrecorded

  outcomes="$(triage_check_outcomes "$root/.agents/handoffs/$source_issue.md" "$triage_path")"
  echo
  echo "The implementer's check of each FIX_NOW finding (.agents/handoffs/$source_issue.md, '## Triage ${triage_relative##*/}'):"
  printf '%s\n' "$outcomes" | awk -F '\t' '$2 == "fixed" { printf "  - %s: fixed — %s\n", $1, $3 }'
  returned="$(printf '%s\n' "$outcomes" | awk -F '\t' '$2 ~ /^(refuted|not_reproduced|not_executable)$/ { printf "  - %s: %s — %s\n", $1, $2, $3 }')"
  unrecorded="$(printf '%s\n' "$outcomes" | awk -F '\t' '$2 == "missing" { print "  - " $1 ": no check recorded" } $2 == "conflicting" { print "  - " $1 ": conflicting checks (" $3 ")" }')"
  if [[ -n "$returned" ]]; then
    echo "Returned to the triage, with the code of the finding unchanged (a not_executable finding settled by reading excepted):"
    printf '%s\n' "$returned"
  fi
  if [[ -n "$unrecorded" ]]; then
    echo "Without a single recorded check:"
    printf '%s\n' "$unrecorded"
  fi
  if [[ -n "$returned$unrecorded" ]]; then
    echo "These findings stay FIX_NOW: only a fix recorded as fixed, with its evidence, or a new"
    echo "triage decision closes them. The next review receives the lines under 'Decisions of the"
    echo "earlier rounds', and the existing triage step decides again (./scripts/triage-review.sh"
    echo "<review-json>, with the owner's approval): a refuted finding can become ACCEPT with its"
    echo "rationale; a not_reproduced or not_executable one stays FIX_NOW or goes to the next review."
  fi
}

report_checks
echo
rm -f "$started_mark"
if [[ "$caller_verifies" -eq 1 ]]; then
  echo "FIX_NOW implementation completed; the caller verifies the result (--caller-verifies)."
elif [[ -n "$checks" ]]; then
  echo "FIX_NOW implementation completed and the partial check of the groups ${checks//,/, } passed (not a verification)."
else
  echo "FIX_NOW implementation completed and verification passed."
fi
echo "The code changed, so the review is stale. Next: review again to confirm the fixes:"
echo "  ./scripts/review-feature.sh $source_issue"
echo "Then triage any earlier round that has no triage yet (a round fixed before its triage is triaged as a historical review):"
echo "  ./scripts/triage-review.sh <review-json>"
