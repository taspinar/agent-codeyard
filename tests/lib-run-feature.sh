#!/usr/bin/env bash

# Shared part of the self-tests of scripts/run-feature.sh. Source this file,
# after tests/lib-fakes.sh, from a part tests/run-feature-<part>-test.sh;
# the caller sets 'source_root' and runs under 'set -euo pipefail'.
#
# It creates the temporary directory 'tmp' (removed on exit) and the fake
# agents and GitHub of the parts, and defines their helpers: setup_repo,
# run_feature, expect_published, expect_stopped, and the replies of the fake
# agents. --changed (scripts/verify.sh) selects every test that sources this
# file for a change to it or to scripts/run-feature.sh.
#
# The scenario register. Every case of a part starts with a line
# 'scenario <id>' with the stable identifier of the case, and
# scenario_register lists every identifier once. scenario_errors fails on
# an identifier that is defined twice, one that the register lists and no
# part runs, and one that a part runs and the register does not list; every
# part checks the register when it ends (scenarios_done), and
# tests/scenario-register-test.sh tests the check with each fault.

tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-feature-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# The scenario that runs, for the message of a failure.
current_scenario=""

fail() {
  echo "run-feature test failed${current_scenario:+ in scenario $current_scenario}: $*" >&2
  exit 1
}

make_fake_agents "$tmp/bin"

# A fake agent that plays every role of a feature, as codex and as claude
# (the reviewer, since the review refuses the implementer's provider). The
# role follows from how the scripts start it. Per role, the control directory
# of a test may hold '<role>-<n>.sh' for the n-th session of that role, or
# '<role>.sh' for all of them: a script that runs in the agent's working
# directory and sets 'reply', the final message. Without one, the role does
# its work well.
cat >"$tmp/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

provider="$(basename "$0")"
out=""
schema=""
logged=()
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --output-schema) schema="${args[$((i + 1))]}" ;;
    # Claude gets the text of the schema, which stays off the logged
    # arguments so that every call is one line of '<role>.args'.
    --json-schema)
      schema="${args[$((i + 1))]}"
      logged+=("--json-schema")
      i=$((i + 1))
      continue
      ;;
  esac
  logged+=("${args[$i]}")
done

case "$provider:$schema:$out" in
  *review.schema.json:* | claude:*\"findings\"*:) role=reviewer ;;
  *triage.schema.json:* | claude:*\"decisions\"*:) role=triage ;;
  *::*-implementer.md) role=implementer ;;
  *::*-fixes.md) role=fixes ;;
  *)
    echo "The fake agent does not know this session: $*" >&2
    exit 98
    ;;
esac

# completion <status> [remaining]: the implementer's completion record of the
# Issue, as the implementer contract describes it.
completion() {
  local remaining='[]'
  local met="met"

  if [[ "$1" != "complete" ]]; then
    remaining="[\"${2:-Plan steps 3 to 9}\"]"
    met="not_met"
  fi
  mkdir -p .agents/completion
  printf '{"schema": "completion/v1", "status": "%s", "criteria": [{"criterion": "The feature file exists", "status": "%s", "evidence": "feature.txt"}], "remaining": %s}\n' \
    "$1" "$met" "$remaining" >".agents/completion/$RUN_ISSUE.json"
}

count="$(($(cat "$RUN_CONTROL/$role.count" 2>/dev/null || echo 0) + 1))"
echo "$count" >"$RUN_CONTROL/$role.count"
printf '%s\n' "${logged[*]}" >>"$RUN_CONTROL/$role.args"
# A read-only session gets its context on standard input.
[[ -z "$schema" ]] || cat >"$RUN_CONTROL/$role-$count.context"

case "$role" in
  implementer)
    default='printf "feature\n" >>feature.txt
mkdir -p .agents/summaries
printf -- "- Adds the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"
completion complete
reply="The feature is implemented."'
    ;;
  reviewer) default='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"PASS\", \"limitations\": \"\", \"findings\": []}"' ;;
  triage)
    default='reply="{\"decisions\": [
  {\"finding_id\": \"M1\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is wrong.\", \"followup\": null},
  {\"finding_id\": \"MIN1\", \"decision\": \"DEFER\", \"rationale\": \"Later.\", \"followup\": {\"title\": \"Rename it\", \"recommended_action\": \"Rename.\", \"acceptance_criteria\": [\"Renamed.\"]}}
]}"'
    ;;
  fixes) default='printf "fixed\n" >>feature.txt
reply="The findings are fixed."' ;;
esac

reply=""
if [[ -f "$RUN_CONTROL/$role-$count.sh" ]]; then
  source "$RUN_CONTROL/$role-$count.sh"
elif [[ -f "$RUN_CONTROL/$role.sh" ]]; then
  source "$RUN_CONTROL/$role.sh"
else
  eval "$default"
fi
if [[ "$provider" != "claude" ]]; then
  printf '%s\n' "$reply" >"$out"
elif printf '%s' "$reply" | jq -e . >/dev/null 2>&1; then
  # Claude returns structured output inside a result envelope.
  printf '{"is_error": false, "structured_output": %s}\n' "$reply"
else
  jq -n --arg result "$reply" '{is_error: false, result: $result}'
fi
AGENT
chmod +x "$tmp/bin/codex"
cp "$tmp/bin/codex" "$tmp/bin/claude"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RUN_CONTROL/gh.log"
case "${1:-} ${2:-}" in
  "auth status") ;;
  "issue view")
    [[ ! -e "$RUN_CONTROL/gh-fails" ]] || exit 1
    # gh-title-flaky holds how many reads of the title fail on the connection.
    if [[ "$*" == *"--json title"* && -s "$RUN_CONTROL/gh-title-flaky" ]]; then
      left="$(cat "$RUN_CONTROL/gh-title-flaky")"
      if [[ "$left" -gt 0 ]]; then
        echo $((left - 1)) >"$RUN_CONTROL/gh-title-flaky"
        echo "net/http: TLS handshake timeout" >&2
        exit 1
      fi
    fi
    case "$*" in
      *"--json number"*) echo "$3" ;;
      *"--json title"*) echo "F02 — Feature file" ;;
      *) printf 'Title: F02 — Feature file\n\nThe feature file exists.\n' ;;
    esac
    ;;
  "issue comment")
    # The bodies, as GitHub would return them: an owner exception is read
    # back from the comments of the Issue (MOCK_ISSUE_COMMENTS).
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then
        jq -n --rawfile body "${args[$((i + 1))]}" '{body: $body}' >>"$RUN_CONTROL/issue-comments.jsonl"
      fi
    done
    ;;
  "issue list" | "pr edit") ;;
  "api user") echo "project-owner" ;;
  "issue create") echo "https://github.com/example/project/issues/123" ;;
  "pr list") ;;
  "pr create")
    [[ ! -e "$RUN_CONTROL/pr-fails" ]] || exit 1
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$RUN_CONTROL/pr-body"; fi
    done
    echo "https://github.com/example/project/pull/7"
    ;;
  "pr view") echo "main" ;;
  "api repos/{owner}/{repo}/rules/branches/main") echo "1" ;;
  "api repos/"*"/comments") exec "$(dirname "$0")/gh-comments" "$@" ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

# shipped_policy: the lines of .agents/policies/risk.conf as the template
# ships it, from the preset of standard without the requirement lines it
# does not write. Not the file of the repository these tests run in: a
# project's own policy may have a profile or classes of its own.
shipped_policy() {
  (source "$source_root/scripts/lib/risk.sh" && risk_profile_preset standard) | grep -Ev '^[a-z]+: (verification|review|triage):'
}

# Creates a project with a remote and prints the path of its clone. The
# control directory of its fake agents and GitHub is '<clone>.control'.
setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed" "$repo.control"
  copy_workflow "$seed"
  # report-runs.sh reads it for the run figures of the pull request.
  cp "$source_root/scripts/lib/report.jq" "$seed/scripts/lib/"
  workflow_gitignore "$seed/.gitignore"
  printf 'implementer: codex model-i\nreviewer: claude model-r\ntriage: codex model-t\ntriage-implementer: codex model-f\n' \
    >"$seed/.agents/agents.conf"
  printf '%s\n' "${VERIFY_CONF:-sound: test ! -e broken.txt}" >"$seed/scripts/verify.conf"
  # The risk policy of the project: the one the template ships, unless the
  # test sets RISK_CONF.
  mkdir -p "$seed/.agents/policies"
  if [[ -n "${RISK_CONF:-}" ]]; then
    printf '%s\n' "$RISK_CONF" >"$seed/.agents/policies/risk.conf"
  else
    shipped_policy >"$seed/.agents/policies/risk.conf"
  fi
  printf '# Agents\n' >"$seed/AGENTS.md"
  # ENVIRONMENT_CONTROL: while this file exists, the preflight of verify.sh
  # finds a prerequisite missing (fake_missing_prerequisite, lib-fakes.sh).
  [[ -z "${ENVIRONMENT_CONTROL:-}" ]] || fake_missing_prerequisite "$seed" "$ENVIRONMENT_CONTROL"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Run Feature Test"
  git -C "$seed" config user.email "run-feature-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed"
  git init -q --bare -b main "$remote"
  git -C "$seed" push -q "$remote" main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Run Feature Test"
  git -C "$repo" config user.email "run-feature-test@example.com"
  printf '%s\n' "$repo"
}

# run_feature <repo> <argument...>: sets 'status' to the exit status.
run_feature() {
  local repo="$1"

  shift
  status=0
  (
    cd "$repo"
    PATH="$tmp/bin:$ISOLATED_PATH" RUN_CONTROL="$repo.control" RUN_ISSUE="${1:-}" GIT_EDITOR=false \
      RUN_FEATURE_RETRY_WAIT=0 START_FEATURE_GH_WAIT=0 \
      ./scripts/run-feature.sh "$@" </dev/null
  ) >"$repo.out" 2>&1 || status=$?
}

# sessions <repo> <role>: how often a role was started.
sessions() {
  cat "$1.control/$2.count" 2>/dev/null || echo 0
}

expect_sessions() {
  local repo="$1"
  local role

  shift
  for role in implementer reviewer triage fixes; do
    [[ "$(sessions "$repo" "$role")" -eq "$1" ]] ||
      fail "$(basename "$repo"): $role ran $(sessions "$repo" "$role") time(s) instead of $1"
    shift
  done
}

pull_requests() {
  grep -c '^pr create' "$1.control/gh.log" 2>/dev/null || true
}

# A run that stopped left the feature for the human: nothing is committed,
# nothing is pushed, and the output says how to go on.
expect_stopped() {
  local repo="$1"
  local expected="$2"
  local reason="$3"

  [[ "$status" -eq "$expected" ]] || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): exited with $status instead of $expected"
  }
  grep -Fq "run-feature.sh stopped: " "$repo.out" || fail "$(basename "$repo"): the stop was not reported"
  grep -Fq "$reason" "$repo.out" || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): the reason was not given: $reason"
  }
  grep -Fq "Then run again: ./scripts/run-feature.sh 2" "$repo.out" ||
    fail "$(basename "$repo"): the command that continues was not given"
  # The end of the run records the step where it stopped and the reason it
  # gave.
  local end
  end="$(cat "$repo"/.agents/run/records/*.jsonl | jq -c -s 'map(select(.type == "run-end")) | sort_by(.epoch) | last')"
  jq -e --argjson status "$expected" --arg reason "$reason" \
    '.status == $status and (.step | type == "string" and length > 0) and (.reason | contains($reason))' <<<"$end" >/dev/null ||
    fail "$(basename "$repo"): the end of the run lacks the step or the reason of the stop: $end"
  [[ "$(pull_requests "$repo")" -eq 0 ]] || fail "$(basename "$repo"): a stopped run opened a pull request"
  [[ -d "$repo-2-thing" ]] || fail "$(basename "$repo"): the worktree of a stopped run is gone"
}

expect_published() {
  local repo="$1"

  [[ "$status" -eq 0 ]] || {
    cat "$repo.out" >&2
    fail "$(basename "$repo"): the run failed with status $status"
  }
  [[ "$(pull_requests "$repo")" -ge 1 ]] || fail "$(basename "$repo"): no pull request was opened"
  git -C "$repo" ls-remote --exit-code --heads origin feature/2-thing >/dev/null 2>&1 ||
    fail "$(basename "$repo"): the feature branch was not pushed"
  [[ -z "$(git -C "$repo-2-thing" status --porcelain)" ]] || fail "$(basename "$repo"): the feature is not committed"
  # It never merges, never pushes to main, and never removes the worktree.
  [[ "$(git -C "$repo" ls-remote origin main | cut -f1)" == "$(git -C "$repo" rev-parse origin/main)" ]] ||
    fail "$(basename "$repo"): main changed on the remote"
  if grep -Eq '^pr merge|--delete' "$repo.control/gh.log"; then fail "$(basename "$repo"): the run merged or deleted"; fi
  [[ -d "$repo-2-thing" ]] || fail "$(basename "$repo"): the worktree was removed"
}

# log_of <repo>: the log of the feature in its worktree.
log_of() {
  cat "$1-2-thing/.agents/run/2-log" 2>/dev/null || true
}

# full_verifications <repo>: the verifications that ran every check, outside
# an agent session.
full_verifications() {
  cat "$1"/.agents/run/records/*.jsonl |
    jq -s '[.[] | select(.type == "verification" and .reused == false and .origin != "agent-session")] | length'
}

# What a fake agent runs to record a question in the handoff note.
ask='mkdir -p .agents/handoffs; printf "**Done:** part.\n\n**Open questions:** %s\n" "$question" >".agents/handoffs/$RUN_ISSUE.md"'

major_and_minor='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Wrong content\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\"},
  {\"severity\": \"minor\", \"title\": \"Vague name\", \"evidence\": \"feature.txt:1\", \"impact\": \"Unclear.\", \"recommendation\": \"Rename.\"}
]}"'

only_major='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Still wrong\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\"}
]}"'
fix_major='if [[ "$count" -eq 1 ]]; then eval "$default"; else
  reply="{\"decisions\": [{\"finding_id\": \"M1\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is wrong.\", \"followup\": null}]}"
fi'

# scenario <id>: the case that follows is the scenario <id> of the register.
scenario() {
  current_scenario="$1"
  printf '%s\n' "$1" >>"$tmp/scenarios-run"
}

# scenario_register: the register of the scenarios, one identifier per line,
# each run by exactly one part ('scenario <id>'). A new case adds its
# identifier here; a case that moves to another part keeps it.
scenario_register() {
  cat <<'REGISTER'
clean
develop-base
hinted
stopped-partway
stopped-partway-note
no-record
record-contradicted
no-summary
awaiting-pr-ci
awaiting-post-merge
never-complete
record-blocked
fixed
closing-review-finds
rounds-end-on-changes
adr
impact-major
major-deferred
rounds
more-rounds
blocked
blocked-restart
blocked-without-question
clarification
clarification-clear
clarification-without-question
issue-flaky
implementer-fails-once
reviewer-fails-once
one-verification
review-usage-limit
verification-after-session
verification-per-tree
implementer-keeps-failing
reviewer-keeps-failing
unstable
repeat-failed-only
repeat-two-failed
alternating
busy
environment
environment-repeat
repaired
base-repairs
base-conflicts
base-ignored
base-staged
base-staged-overlap
repair-leaves-partial
repair-removes-record
repair-leaves-note
repair-blocked
usage-limit
repair-fails-once
agent-exits
implementer-forges-review
implementer-changes-triage
unverified
verification-unfinished
fixes-break
fixes-break-repair-fails
fixes-break-repair-exhausted
fixes-interrupted
fixes-tamper
fixes-fail-once
fixes-blocked
fixes-nothing
fixes-refuted
fixes-mixed
fixes-refuted-other-title
fixes-inconclusive
base-changed
high-groups-refused
level-rises
medium-full-reviews
low-unreviewed
low-unreviewed-repaired
low-rises
low-reviewed
light-ends
light-fix-minor
light-major
light-high-refused
full-shipped
profile-docs
profile-medium
publish-fails
by-hand
resumed
refused
budget
budget-measured
budget-restart
budget-as-evidence
duration-budget
REGISTER
}

# scenario_ids <part...>: '<file>:<line>:<id>' for each 'scenario <id>' line
# of the parts.
scenario_ids() {
  local file

  for file in "$@"; do
    awk -v file="$file" 'match($0, /^[[:space:]]*scenario [^[:space:]]+[[:space:]]*$/) {
      id = $0; sub(/^[[:space:]]*scenario /, "", id); sub(/[[:space:]]+$/, "", id)
      print file ":" FNR ":" id
    }' "$file"
  done
}

# scenario_errors <register> <part...>: prints one line per fault of the
# register file <register> (one identifier per line; '#' starts a comment)
# against the parts, and fails when there is one: an identifier defined twice
# in the parts or listed twice in the register, an identifier that the
# register lists and no part runs, and one that a part runs and the register
# does not list.
scenario_errors() {
  local register="$1"
  local defined
  local listed
  local id
  local errors=0

  shift
  defined="$(scenario_ids "$@")"
  listed="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$register" | grep -v '^$' || true)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    echo "scenario $id is defined more than once: $(awk -F: -v id="$id" '$3 == id { printf "%s%s:%s", sep, $1, $2; sep = ", " }' <<<"$defined")"
    errors=1
  done < <(cut -d: -f3 <<<"$defined" | grep -v '^$' | sort | uniq -d)
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    echo "the register lists $id more than once"
    errors=1
  done < <(sort <<<"$listed" | uniq -d)
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    grep -Fqx -- "$id" <<<"$(cut -d: -f3 <<<"$defined")" || {
      echo "the register lists $id, which no part runs"
      errors=1
    }
  done <<<"$listed"
  while IFS=: read -r file line id; do
    [[ -n "$id" ]] || continue
    grep -Fqx -- "$id" <<<"$listed" || {
      echo "$file:$line runs scenario $id, which the register does not list"
      errors=1
    }
  done <<<"$defined"
  return "$errors"
}

# scenarios_done <part>: the end of the part <part>, the file that ran.
# Every scenario it defines ran, and the register agrees with all parts.
scenarios_done() {
  local part="$1"
  local errors
  local declared
  local ran

  current_scenario=""
  scenario_register >"$tmp/register"
  errors="$(scenario_errors "$tmp/register" "$source_root"/tests/run-feature-*-test.sh)" ||
    fail "the scenario register does not match the parts:"$'\n'"$errors"
  declared="$(scenario_ids "$part" | cut -d: -f3 | sort -u)"
  ran="$(sort -u "$tmp/scenarios-run" 2>/dev/null || true)"
  [[ "$declared" == "$ran" ]] ||
    fail "$(basename "$part") did not run the scenarios it defines: $(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$ran") | paste -sd ' ' -)"
  echo "run-feature $(basename "$part" -test.sh | sed 's/^run-feature-//') tests passed ($(grep -c . <<<"$declared") scenarios)"
}
