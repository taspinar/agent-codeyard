#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

root="$(git rev-parse --show-toplevel)"
source "$root/tests/lib-fakes.sh"
script_source="$root/scripts/start-planning.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/start-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "start-planning test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"

cat >"$tmp/bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail

agent="$(basename "$0")"
prompt="${!#}"

# The read-only Draft review: MOCK_REVIEW_RESULT_<n> answers round <n>,
# MOCK_REVIEW_RESULT every other round; no findings without either.
if [[ "$prompt" == *"requirements-reviewer.md"* ]]; then
  cat >"$MOCK_AGENT_LOG.review-stdin"
  review_count="$(grep -c '^REVIEW=' "$MOCK_AGENT_LOG" 2>/dev/null || true)"
  review_count=$((${review_count:-0} + 1))
  {
    echo "REVIEW=$review_count"
    echo "REVIEW_ARGS=$*"
  } >>"$MOCK_AGENT_LOG"
  result_variable="MOCK_REVIEW_RESULT_$review_count"
  result="${!result_variable:-}"
  [[ -n "$result" ]] || result="${MOCK_REVIEW_RESULT:-}"
  [[ -n "$result" ]] || result='{"findings": [], "limitations": ""}'
  if [[ "$agent" == "codex" ]]; then
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[$i]}" != "--output-last-message" ]] || printf '%s\n' "$result" >"${args[$((i + 1))]}"
    done
  else
    printf '{"structured_output": %s}\n' "$result"
  fi
  exit 0
fi

if [[ "$prompt" == *"Project Grill phase"* ]]; then
  phase="grill"
elif [[ "$prompt" == *"project planning phase"* ]]; then
  phase="planner"
else
  echo "Unknown phase prompt" >&2
  exit 90
fi

{
  echo "AGENT=$agent"
  echo "PHASE=$phase"
  echo "PWD=$PWD"
  echo "ARGS=$*"
} >>"$MOCK_AGENT_LOG"
if [[ "$phase" == "grill" && "$prompt" == *"Draft review findings"* ]]; then
  echo "RESUMED_WITH=$(grep -o 'D[0-9] \[[a-z-]*\]' <<<"$prompt" | paste -sd, -)" >>"$MOCK_AGENT_LOG"
  eval "${MOCK_RESUMED_GRILL:-:}"
fi

if [[ "$prompt" == *"This is a change cycle"* ]]; then
  echo "CHANGE=$phase" >>"$MOCK_AGENT_LOG"
  [[ "$prompt" == *"docs/changes/"* ]] || exit 92
  if [[ "$phase" == "grill" ]]; then
    eval "${MOCK_CHANGE_GRILL:-:}"
  else
    grep -Fqx "Status: Approved" docs/PROJECT_REQUIREMENTS.md || exit 91
    eval "${MOCK_CHANGE_PLANNER:-:}"
  fi
  exit 0
fi

if [[ "$phase" == "grill" ]]; then
  if [[ "${MOCK_GRILL_MODE:-success}" == "fail" ]]; then
    exit 41
  fi

  if [[ "${MOCK_GRILL_MODE:-success}" == "malformed" ]]; then
    printf '# Project Requirements\n\nStatus: Draft\n' >docs/PROJECT_REQUIREMENTS.md
    exit 0
  fi

  cat >docs/PROJECT_REQUIREMENTS.md <<'REQUIREMENTS'
# Project Requirements

Status: Draft
Approved at: Not approved

## Project goal

Ship a focused test product.

## Target users

Test users.

## Primary use cases and journeys

Complete the primary test journey.

## MVP scope

One complete vertical slice.

## Non-goals

Production deployment.

## UX expectations

Clear keyboard-accessible interactions.

## Data and persistence

Local ephemeral data.

## Authentication and authorization

None.

## External integrations

None.

## Runtime and deployment constraints

Run locally.

## Security and privacy constraints

Do not process sensitive data.

## Major product decisions

Keep the MVP local and single-user.

## Unresolved questions

None.
REQUIREMENTS
  if [[ "${MOCK_GRILL_MODE:-success}" == "extra" ]]; then
    printf 'Out-of-scope Grill change.\n' >README.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "ignored" ]]; then
    printf 'IGNORED_SECRET=test\n' >.env
  elif [[ "${MOCK_GRILL_MODE:-success}" == "edit-description" ]]; then
    printf 'Changed by Project Grill.\n' >>docs/PROJECT_DESCRIPTION.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "weird-paths" ]]; then
    printf 'Tab path.\n' >$'docs/PROJECT_REQUIREMENTS.md\textra'
    printf 'Newline path.\n' >$'unexpected\nfile'
  elif [[ "${MOCK_GRILL_MODE:-success}" == "empty-section" ]]; then
    awk '
      /^## Project goal$/ {
        print
        getline
        getline
        next
      }
      { print }
    ' docs/PROJECT_REQUIREMENTS.md >docs/PROJECT_REQUIREMENTS.tmp
    mv docs/PROJECT_REQUIREMENTS.tmp docs/PROJECT_REQUIREMENTS.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "observed" ]]; then
    # Requirements an adoption reconstructed keep their mark through the
    # Grill session.
    sed -i.bak 's/^Approved at: Not approved$/&\n\n> **Observed, not approved.** Reconstructed by adopt-repository.sh./' docs/PROJECT_REQUIREMENTS.md
    rm -f docs/PROJECT_REQUIREMENTS.md.bak
  elif [[ "${MOCK_GRILL_MODE:-success}" == "duplicate-section" ]]; then
    printf '\n## Project goal\n\nDuplicate goal.\n' >>docs/PROJECT_REQUIREMENTS.md
  elif [[ "${MOCK_GRILL_MODE:-success}" == "commit-extra" ]]; then
    printf 'Committed out-of-scope Grill change.\n' >README.md
    git add docs/PROJECT_REQUIREMENTS.md README.md
    git commit -qm "Agent must not commit"
  fi
  exit 0
fi

grep -Fqx "Status: Approved" docs/PROJECT_REQUIREMENTS.md ||
  exit 91

if [[ "${MOCK_PLANNER_MODE:-success}" == "fail" ]]; then
  exit 42
fi

if [[ "${MOCK_PLANNER_MODE:-success}" != "only-roadmap" && "${MOCK_PLANNER_MODE:-success}" != "mode-only" ]]; then
  cat >docs/architecture.md <<'ARCHITECTURE'
# Architecture

The approved test product uses one local component.
ARCHITECTURE
fi

if [[ "${MOCK_PLANNER_MODE:-success}" != "only-architecture" && "${MOCK_PLANNER_MODE:-success}" != "mode-only" ]]; then
  cat >docs/roadmap.md <<'ROADMAP'
# Roadmap

## F01 — Test vertical slice

- Goal: deliver the primary journey.
- Dependencies: none.
- Acceptance criteria: the journey works locally.
- Risk: low.
- Detailed plan: expected when activated.
ROADMAP
fi

if [[ "${MOCK_PLANNER_MODE:-success}" == "extra" ]]; then
  printf 'Out-of-scope planner change.\n' >application.txt
elif [[ "${MOCK_PLANNER_MODE:-success}" == "ignored" ]]; then
  printf 'IGNORED_SECRET=test\n' >.env
elif [[ "${MOCK_PLANNER_MODE:-success}" == "weird-paths" ]]; then
  printf 'Tab path.\n' >$'docs/architecture.md\textra'
  printf 'Newline path.\n' >$'docs/roadmap.md\nextra'
elif [[ "${MOCK_PLANNER_MODE:-success}" == "commit-extra" ]]; then
  printf 'Committed out-of-scope planner change.\n' >application.txt
  git add docs/architecture.md docs/roadmap.md application.txt
  git commit -qm "Agent must not commit"
elif [[ "${MOCK_PLANNER_MODE:-success}" == "requirements-mode" ]]; then
  chmod 600 docs/PROJECT_REQUIREMENTS.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "architecture-directory" ]]; then
  rm docs/architecture.md
  mkdir docs/architecture.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "roadmap-symlink" ]]; then
  cp docs/roadmap.md "$MOCK_AGENT_LOG.roadmap"
  rm docs/roadmap.md
  ln -s "$MOCK_AGENT_LOG.roadmap" docs/roadmap.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "adr-non-markdown" ]]; then
  printf '#!/usr/bin/env bash\n' >docs/decisions/tool.sh
elif [[ "${MOCK_PLANNER_MODE:-success}" == "adr-nested" ]]; then
  mkdir -p docs/decisions/nested
  printf '# Nested decision\n' >docs/decisions/nested/decision.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "mode-only" ]]; then
  chmod 600 docs/architecture.md docs/roadmap.md
elif [[ "${MOCK_PLANNER_MODE:-success}" == "executable-docs" ]]; then
  chmod 755 docs/architecture.md docs/roadmap.md
fi
AGENT

cp "$tmp/bin/codex" "$tmp/bin/claude"
chmod +x "$tmp/bin/codex" "$tmp/bin/claude"

# setup_repo <label> [<function>]: a project whose first commit is the
# seed; <function> runs with the seed directory before that commit and gets
# 'later' after it, for the commits of the project.
setup_repo() {
  local label="$1"
  local seed_hook="${2:-}"
  local seed="$tmp/${label}-seed"
  local remote="$tmp/${label}-remote.git"
  local repo="$tmp/${label}-repo"

  mkdir -p \
    "$seed/scripts" \
    "$seed/tests" \
    "$seed/.agents/prompts" \
    "$seed/docs/decisions"

  cp "$script_source" "$seed/scripts/start-planning.sh"
  mkdir -p "$seed/scripts/lib"
  cp "$root"/scripts/lib/*.sh "$seed/scripts/lib/"
  printf 'project-grill: codex astra\nproject-planner: codex astra\n' >"$seed/.agents/agents.conf"
  cp "$root/.agents/prompts/project-grill.md" "$seed/.agents/prompts/project-grill.md"
  cp "$root/.agents/prompts/project-planner.md" "$seed/.agents/prompts/project-planner.md"
  cp "$root/.agents/prompts/requirements-reviewer.md" "$seed/.agents/prompts/requirements-reviewer.md"
  mkdir -p "$seed/.agents/schemas"
  cp "$root/.agents/schemas/requirements-review.schema.json" "$seed/.agents/schemas/"
  # The unapproved draft the template ships, not the requirements of the
  # repository these tests run in, which are approved once its planning is.
  printf '# Project Requirements\n\nStatus: Draft\nApproved at: Not approved\n\n## Project goal\n\n<!-- REQUIRED: Describe the product outcome and why it matters. -->\n' \
    >"$seed/docs/PROJECT_REQUIREMENTS.md"
  cp "$root/.gitignore" "$seed/.gitignore"

  printf '# Agents\n' >"$seed/AGENTS.md"
  printf '# Repository setup\n' >"$seed/docs/repository-setup.md"
  printf '# Architecture\n\nTemplate.\n' >"$seed/docs/architecture.md"
  printf '# Roadmap\n\nTemplate.\n' >"$seed/docs/roadmap.md"

  [[ -z "$seed_hook" ]] || "$seed_hook" "$seed" >/dev/null

  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Planning Test"
  git -C "$seed" config user.email "planning-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed project"
  if [[ -n "$seed_hook" ]]; then
    "$seed_hook" "$seed" later >/dev/null
    git -C "$seed" add .
    git -C "$seed" diff --cached --quiet || git -C "$seed" commit -qm "Later work of the project"
  fi

  git init -q --bare -b main "$remote"
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q -u origin main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Planning Test"
  git -C "$repo" config user.email "planning-test@example.com"

  printf '%s\n' "$repo"
}

codex_repo="$(setup_repo codex)"
codex_log="$tmp/codex.log"
codex_output="$(
  cd "$codex_repo/docs"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$codex_log" \
    ../scripts/start-planning.sh --agent codex --model astra 2>"$tmp/codex-success.err"
)"
codex_worktree="$tmp/codex-repo-planning-project-bootstrap"

[[ -d "$codex_worktree" ]] || fail "Codex worktree was not created"
[[ "$(git -C "$codex_worktree" branch --show-current)" == "planning/project-bootstrap" ]] ||
  fail "Codex planning branch is incorrect"
[[ "$(git -C "$codex_worktree" rev-parse HEAD)" == "$(git -C "$codex_repo" rev-parse origin/main)" ]] ||
  fail "planning branch did not start at origin/main"
[[ "$(grep -c '^PHASE=' "$codex_log")" -eq 2 ]] ||
  fail "Codex did not run exactly two phases"
[[ "$(awk -F= '/^PHASE=/ { print $2 }' "$codex_log" | paste -sd, -)" == "grill,planner" ]] ||
  fail "Codex phases ran out of order"
# The run records name the role of each session, though both roles are
# resolved before the first one starts.
[[ "$(cat "$codex_repo"/.agents/run/records/*.jsonl 2>/dev/null |
  jq -r -s '[.[] | select(.type == "agent-call") | .role] | join(",")')" == "project-grill,planning-reviewer,project-planner" ]] ||
  fail "the run records do not name the role of each planning session"
grep -Fq -- "--model astra" "$codex_log" ||
  fail "Codex model was not forwarded"
grep -Fq -- "--sandbox workspace-write" "$codex_log" ||
  fail "Codex workspace sandbox was not configured"
grep -Fqx "Status: Approved" "$codex_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "approval status was not persisted"
grep -Eq '^Approved at: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$codex_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "approval timestamp was not persisted"
[[ "$codex_output" == *"Project bootstrap planning completed."* ]] ||
  fail "success guidance was not printed"
if grep -Fq "No such file or directory" "$tmp/codex-success.err"; then
  fail "Codex happy path emitted a missing optional ADR directory error"
fi
# A Draft without findings: one read-only review of the Draft, recorded with
# the owner's approval, and the plain approval question.
[[ "$(grep -c '^REVIEW=' "$codex_log")" -eq 1 ]] || fail "the Draft was not reviewed exactly once"
grep -Fq -- "--sandbox read-only" <<<"$(grep '^REVIEW_ARGS=' "$codex_log")" ||
  fail "the Draft reviewer did not run read-only"
grep -Fq "Status: Draft" "$codex_log.review-stdin" && grep -Fq "## docs/PROJECT_REQUIREMENTS.md" "$codex_log.review-stdin" ||
  fail "the Draft reviewer did not get the Draft requirements"
jq -e '.schema == "requirements-review/v1" and .round == 1 and .findings == [] and .decision.choice == "approve"
  and .decision.open_findings == [] and .reviewer == {agent: "codex", model: "astra"}' \
  "$codex_worktree/.agents/reviews/requirements-project-bootstrap-review-01.json" >/dev/null ||
  fail "the Draft review without findings and the approval were not recorded"
[[ "$codex_output" == *"The Draft review found no defect in the requirements"* ]] ||
  fail "the owner was not told that the Draft review found nothing"

claude_repo="$(setup_repo claude)"
claude_log="$tmp/claude.log"
(
  cd "$claude_repo"
  printf 'yes\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$claude_log" \
    ./scripts/start-planning.sh --agent claude --model fable architecture-refresh \
    >/dev/null 2>"$tmp/claude-success.err"
)
claude_worktree="$tmp/claude-repo-planning-architecture-refresh"

[[ "$(git -C "$claude_worktree" branch --show-current)" == "planning/architecture-refresh" ]] ||
  fail "custom Claude planning branch is incorrect"
[[ "$(grep -c '^PHASE=' "$claude_log")" -eq 2 ]] ||
  fail "Claude did not run exactly two phases"
grep -Fq -- "--model fable" "$claude_log" ||
  fail "Claude model was not forwarded"
if grep -Fq -- "--sandbox" "$claude_log"; then
  fail "Codex-only flags were forwarded to Claude"
fi
if grep -Fq "No such file or directory" "$tmp/claude-success.err"; then
  fail "Claude happy path emitted a missing optional ADR directory error"
fi
grep -Fq -- "--tools Read,Glob,Grep" <<<"$(grep '^REVIEW_ARGS=' "$claude_log")" ||
  fail "the Claude Draft reviewer did not run read-only"
jq -e '.findings == [] and .decision.choice == "approve"' \
  "$claude_worktree/.agents/reviews/requirements-architecture-refresh-review-01.json" >/dev/null ||
  fail "the Claude Draft review was not recorded"

# The Draft review with findings. The owner sees each with its proposed
# wording and chooses; every choice is recorded in the review.
draft_findings='{"findings": [
  {"category": "unkept-promise", "section": "## Runtime and deployment constraints", "quote": "Cost is capped.",
   "problem": "Nothing caps the bill.", "proposed_wording": "A budget alert notifies the owner; nothing caps the bill."},
  {"category": "unmeasurable", "section": "## UX expectations", "quote": "the smallest that serves",
   "problem": "No one can check it.", "proposed_wording": "At most one instance."}
], "limitations": ""}'

# run_review_case <label> <answers> [VARIABLE=value...]: a first planning
# whose questions get <answers>, with the fakes configured by the variables.
run_review_case() {
  local label="$1"
  local answers="$2"
  local repo

  shift 2
  repo="$(setup_repo "$label")"
  (
    cd "$repo"
    printf '%s' "$answers" |
      env PATH="$tmp/bin:$ISOLATED_PATH" MOCK_AGENT_LOG="$tmp/$label.log" "$@" \
      ./scripts/start-planning.sh --agent codex --model astra
  ) >"$tmp/$label.out" 2>&1
}

draft_review_file() {
  printf '%s\n' "$tmp/$1-repo-planning-project-bootstrap/.agents/reviews/requirements-project-bootstrap-review-$2.json"
}

draft_interventions() {
  cat "$tmp/$1-repo"/.agents/run/records/*.jsonl | jq -r 'select(.type == "intervention") | .what'
}

# Approve as they are: the planner runs, the open findings are recorded.
run_review_case review-approve $'a\n' MOCK_REVIEW_RESULT="$draft_findings" || {
  cat "$tmp/review-approve.out" >&2
  fail "approving the requirements with open Draft findings failed"
}
grep -Fq "D1 [unkept-promise] ## Runtime and deployment constraints" "$tmp/review-approve.out" &&
  grep -Fq "Proposed: A budget alert notifies the owner; nothing caps the bill." "$tmp/review-approve.out" &&
  grep -Fq "Project requirements proposed by Project Grill:" "$tmp/review-approve.out" ||
  fail "the owner did not see the findings with their proposed wording next to the requirements"
[[ "$(awk -F= '/^PHASE=/ { print $2 }' "$tmp/review-approve.log" | paste -sd, -)" == "grill,planner" ]] ||
  fail "approving with open findings did not continue to the planner"
grep -Fqx "Status: Approved" "$tmp/review-approve-repo-planning-project-bootstrap/docs/PROJECT_REQUIREMENTS.md" ||
  fail "approving with open findings did not approve the requirements"
jq -e '[.findings[].id] == ["D1", "D2"] and .decision.choice == "approve" and .decision.open_findings == ["D1", "D2"]' \
  "$(draft_review_file review-approve 01)" >/dev/null || fail "the approval with open findings was not recorded"
grep -Fqx "approved the project requirements with 2 open Draft review finding(s)" <<<"$(draft_interventions review-approve)" ||
  fail "the run records do not show the approval with open findings"

# Mark single findings as not applicable: an unknown one is refused, a marked
# one is no longer open, and the rest is approved.
run_review_case review-not-applicable $'n\nD9\nn\nd2\nThe owner chose no size.\na\n' MOCK_REVIEW_RESULT="$draft_findings" || {
  cat "$tmp/review-not-applicable.out" >&2
  fail "marking a Draft finding as not applicable failed"
}
grep -Fq "There is no open finding D9; nothing was marked." "$tmp/review-not-applicable.out" ||
  fail "an unknown finding was not refused"
jq -e '(.not_applicable | map({finding_id, reason})) == [{finding_id: "D2", reason: "The owner chose no size."}]
  and .decision.choice == "approve" and .decision.open_findings == ["D1"]' \
  "$(draft_review_file review-not-applicable 01)" >/dev/null ||
  fail "the finding marked as not applicable was not recorded"
grep -Fqx "marked Draft review finding(s) D2 as not applicable" <<<"$(draft_interventions review-not-applicable)" ||
  fail "the run records do not show the finding marked as not applicable"

# Once every finding is marked, the question is the plain approval.
run_review_case review-all-marked $'n\nD1 D2\nBoth are what the owner wants.\ny\n' MOCK_REVIEW_RESULT="$draft_findings" || {
  cat "$tmp/review-all-marked.out" >&2
  fail "approving after marking every Draft finding failed"
}
jq -e '(.not_applicable | map(.finding_id)) == ["D1", "D2"] and .decision.choice == "approve" and .decision.open_findings == []' \
  "$(draft_review_file review-all-marked 01)" >/dev/null || fail "marking every finding was not recorded"

# Resume Project Grill: it gets the findings, and the changed Draft is
# reviewed again before the owner approves it.
run_review_case review-resume $'g\ny\n' MOCK_REVIEW_RESULT_1="$draft_findings" || {
  cat "$tmp/review-resume.out" >&2
  fail "resuming Project Grill with the Draft findings failed"
}
[[ "$(awk -F= '/^PHASE=/ { print $2 }' "$tmp/review-resume.log" | paste -sd, -)" == "grill,grill,planner" ]] ||
  fail "Project Grill was not resumed before the planner"
grep -Fqx "RESUMED_WITH=D1 [unkept-promise],D2 [unmeasurable]" "$tmp/review-resume.log" ||
  fail "the resumed Project Grill did not get the findings"
grep -Fq "  Proposed: A budget alert notifies the owner; nothing caps the bill." "$tmp/review-resume.log" ||
  fail "the resumed Project Grill did not get the proposed wording"
[[ "$(grep -c '^REVIEW=' "$tmp/review-resume.log")" -eq 2 ]] || fail "the changed Draft was not reviewed again"
jq -e '.decision.choice == "resume-grill" and .decision.open_findings == ["D1", "D2"]' \
  "$(draft_review_file review-resume 01)" >/dev/null || fail "resuming Project Grill was not recorded"
jq -e '.round == 2 and .findings == [] and .decision.choice == "approve"' \
  "$(draft_review_file review-resume 02)" >/dev/null || fail "the second Draft review was not recorded"
grep -Fqx "resumed Project Grill with 2 Draft review finding(s)" <<<"$(draft_interventions review-resume)" ||
  fail "the run records do not show the resumed Project Grill"

# Stop: nothing is approved, the planner does not run, and the stop is recorded.
if run_review_case review-stop $'q\n' MOCK_REVIEW_RESULT="$draft_findings"; then
  fail "stopping at the Draft findings returned success"
fi
[[ "$(awk -F= '/^PHASE=/ { print $2 }' "$tmp/review-stop.log" | paste -sd, -)" == "grill" ]] ||
  fail "the planner ran after the owner stopped at the Draft findings"
grep -Fqx "Status: Draft" "$tmp/review-stop-repo-planning-project-bootstrap/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the requirements did not stay Draft after the stop"
jq -e '.decision.choice == "decline"' "$(draft_review_file review-stop 01)" >/dev/null ||
  fail "the stop was not recorded"

# A reviewer that returns an invalid result twice stops the planning before
# the approval and stores no review.
if run_review_case review-invalid $'a\n' MOCK_REVIEW_RESULT='{"findings": [{"category": "style"}], "limitations": ""}'; then
  fail "an invalid Draft review returned success"
fi
[[ "$(grep -c '^REVIEW=' "$tmp/review-invalid.log")" -eq 2 ]] || fail "an invalid Draft review was not retried once"
grep -Fq "the Draft review failed; the requirements were not approved." "$tmp/review-invalid.out" &&
  grep -Fq "Planning worktree preserved at:" "$tmp/review-invalid.out" ||
  fail "the failed Draft review was not reported"
[[ ! -e "$(draft_review_file review-invalid 01)" ]] || fail "an invalid Draft review was stored"
grep -Fqx "Status: Draft" "$tmp/review-invalid-repo-planning-project-bootstrap/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the requirements did not stay Draft after a failed review"

# A project made with "Use this template" has the template's approval
# requests and plans in its first commit. The first planning removes them,
# stages the removal for the planning pull request, and keeps the project's
# own request of a later commit; the planning agents' scope check does not
# count it as their change.
inherited_seed() {
  mkdir -p "$1/.agents/approval-requests" "$1/.agents/plans"
  if [[ "${2:-}" == "later" ]]; then
    printf '{"issue": 9}\n' >"$1/.agents/approval-requests/9.json"
  else
    : >"$1/.agents/plans/.gitkeep"
    printf '{"issue": 2}\n' >"$1/.agents/approval-requests/2.json"
    printf '# Plan of a template Issue\n' >"$1/.agents/plans/313-growth-lessons.md"
  fi
}
inherited_repo="$(setup_repo inherited inherited_seed)"
inherited_output="$(
  cd "$inherited_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/inherited.log" \
    ./scripts/start-planning.sh --agent codex --model astra 2>"$tmp/inherited.err"
)" || {
  cat "$tmp/inherited.err" >&2
  fail "the first planning of a project with inherited files failed"
}
inherited_worktree="$tmp/inherited-repo-planning-project-bootstrap"
[[ "$(git -C "$inherited_worktree" diff --cached --name-status -- .agents)" == \
  $'D\t.agents/approval-requests/2.json\nD\t.agents/plans/313-growth-lessons.md' ]] ||
  fail "the first planning did not stage the removal of exactly the inherited files"
for kept in .agents/approval-requests/9.json .agents/plans/.gitkeep; do
  [[ -f "$inherited_worktree/$kept" ]] || fail "the first planning removed the project's own $kept"
done
[[ "$inherited_output" == *"Removed 2 approval request(s) and plan(s) of the template's own Issues"* &&
  "$inherited_output" == *"  .agents/approval-requests/2.json"* &&
  "$inherited_output" == *"  .agents/plans/313-growth-lessons.md"* ]] ||
  fail "the first planning did not say which files it removed"
[[ "$inherited_output" == *"Project bootstrap planning completed."* ]] ||
  fail "the planning with removed inherited files did not complete"

# A shallow clone of such a project does not hold its root commit: the first
# planning deepens it to the full history and removes the same files.
shallow_repo="$(setup_repo shallow inherited_seed)"
rm -rf "$shallow_repo"
git clone -q --depth 1 "file://$tmp/shallow-remote.git" "$shallow_repo"
git -C "$shallow_repo" config user.name "Planning Test"
git -C "$shallow_repo" config user.email "planning-test@example.com"
[[ "$(git -C "$shallow_repo" rev-parse --is-shallow-repository)" == "true" ]] ||
  fail "the shallow fixture is not a shallow clone"
shallow_output="$(
  cd "$shallow_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/shallow.log" \
    ./scripts/start-planning.sh --agent codex --model astra 2>"$tmp/shallow.err"
)" || {
  cat "$tmp/shallow.err" >&2
  fail "the first planning of a shallow project with inherited files failed"
}
shallow_worktree="$tmp/shallow-repo-planning-project-bootstrap"
[[ "$(git -C "$shallow_worktree" diff --cached --name-status -- .agents)" == \
  $'D\t.agents/approval-requests/2.json\nD\t.agents/plans/313-growth-lessons.md' ]] ||
  fail "the first planning of a shallow clone did not stage the removal of exactly the inherited files"
[[ -f "$shallow_worktree/.agents/approval-requests/9.json" ]] ||
  fail "the first planning of a shallow clone removed the project's own request"
[[ "$shallow_output" == *"Removed 2 approval request(s) and plan(s) of the template's own Issues"* ]] ||
  fail "the first planning of a shallow clone did not say which files it removed"

# In the template, whose origin is the repository of its template.conf,
# nothing is removed, whatever its first commit holds.
template_seed() {
  [[ "${2:-}" != "later" ]] || return 0
  inherited_seed "$1"
  mkdir -p "$1/.agents"
  printf 'repository: %s\n' "$tmp/template-remote.git" >"$1/.agents/template.conf"
}
template_repo="$(setup_repo template template_seed)"
template_output="$(
  cd "$template_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/template.log" \
    ./scripts/start-planning.sh --agent codex --model astra 2>"$tmp/template.err"
)" || {
  cat "$tmp/template.err" >&2
  fail "the planning in the template failed"
}
template_worktree="$tmp/template-repo-planning-project-bootstrap"
[[ -z "$(git -C "$template_worktree" status --porcelain -- .agents)" ]] ||
  fail "the planning in the template changed its approval requests or plans"
[[ "$template_output" != *"of the template's own Issues"* ]] ||
  fail "the planning in the template reported inherited files"

decline_repo="$(setup_repo decline)"
decline_log="$tmp/decline.log"
if (
  cd "$decline_repo"
  printf 'n\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$decline_log" \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "declined requirements returned success"
fi
decline_worktree="$tmp/decline-repo-planning-project-bootstrap"
[[ -d "$decline_worktree" ]] || fail "declined worktree was removed"
[[ "$(grep -c '^PHASE=' "$decline_log")" -eq 1 ]] ||
  fail "planner ran after declined requirements"
grep -Fqx "Status: Draft" "$decline_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "declined requirements did not remain Draft"

malformed_repo="$(setup_repo malformed)"
malformed_log="$tmp/malformed.log"
if (
  cd "$malformed_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$malformed_log" \
    MOCK_GRILL_MODE=malformed \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "malformed requirements returned success"
fi
[[ "$(grep -c '^PHASE=' "$malformed_log")" -eq 1 ]] ||
  fail "planner ran after malformed requirements"

empty_section_repo="$(setup_repo empty-section)"
empty_section_log="$tmp/empty-section.log"
if (
  cd "$empty_section_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$empty_section_log" \
    MOCK_GRILL_MODE=empty-section \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "empty required section returned success"
fi
[[ "$(grep -c '^PHASE=' "$empty_section_log")" -eq 1 ]] ||
  fail "planner ran after an empty requirements section"

duplicate_section_repo="$(setup_repo duplicate-section)"
duplicate_section_log="$tmp/duplicate-section.log"
if (
  cd "$duplicate_section_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$duplicate_section_log" \
    MOCK_GRILL_MODE=duplicate-section \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "duplicate required section returned success"
fi
[[ "$(grep -c '^PHASE=' "$duplicate_section_log")" -eq 1 ]] ||
  fail "planner ran after a duplicate requirements section"

grill_scope_repo="$(setup_repo grill-scope)"
grill_scope_log="$tmp/grill-scope.log"
if (
  cd "$grill_scope_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$grill_scope_log" \
    MOCK_GRILL_MODE=extra \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "out-of-scope Project Grill change returned success"
fi
[[ "$(grep -c '^PHASE=' "$grill_scope_log")" -eq 1 ]] ||
  fail "planner ran after an out-of-scope Grill change"

# The owner's approval of requirements that an adoption reconstructed removes
# their mark 'Observed, not approved'.
observed_repo="$(setup_repo observed)"
(
  cd "$observed_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" MOCK_AGENT_LOG="$tmp/observed.log" MOCK_GRILL_MODE=observed \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/observed.out" 2>&1
) || { cat "$tmp/observed.out" >&2; fail "the planning of reconstructed requirements failed"; }
grep -Fq "> **Observed, not approved.**" "$tmp/observed.out" || fail "the requirements shown for approval do not carry the mark"
observed_requirements="$tmp/observed-repo-planning-project-bootstrap/docs/PROJECT_REQUIREMENTS.md"
grep -Fqx "Status: Approved" "$observed_requirements" ||
  fail "the reconstructed requirements were not approved"
if grep -Fq "Observed, not approved" "$observed_requirements"; then
  fail "the approved requirements still carry the mark: $(cat "$observed_requirements")"
fi

grill_ignored_repo="$(setup_repo grill-ignored)"
grill_ignored_log="$tmp/grill-ignored.log"
if (
  cd "$grill_ignored_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$grill_ignored_log" \
    MOCK_GRILL_MODE=ignored \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/grill-ignored.out" 2>&1
); then
  fail "ignored Project Grill file returned success"
fi
grep -Fq ".env" "$tmp/grill-ignored.out" ||
  fail "ignored Project Grill diagnostic did not identify .env"
grep -Fq "Planning worktree preserved at:" "$tmp/grill-ignored.out" ||
  fail "ignored Project Grill diagnostic omitted preservation guidance"

grill_weird_repo="$(setup_repo grill-weird)"
grill_weird_log="$tmp/grill-weird.log"
if (
  cd "$grill_weird_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$grill_weird_log" \
    MOCK_GRILL_MODE=weird-paths \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "tab/newline Project Grill paths returned success"
fi

grill_commit_repo="$(setup_repo grill-commit)"
grill_commit_log="$tmp/grill-commit.log"
if (
  cd "$grill_commit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$grill_commit_log" \
    MOCK_GRILL_MODE=commit-extra \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "Project Grill commit returned success"
fi
[[ "$(grep -c '^PHASE=' "$grill_commit_log")" -eq 1 ]] ||
  fail "planner ran after a Project Grill commit"

grill_fail_repo="$(setup_repo grill-fail)"
grill_fail_log="$tmp/grill-fail.log"
set +e
(
  cd "$grill_fail_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$grill_fail_log" \
    MOCK_GRILL_MODE=fail \
    ./scripts/start-planning.sh --agent claude --model fable >"$tmp/grill-fail.out" 2>&1
)
grill_status=$?
set -e
[[ "$grill_status" -eq 41 ]] ||
  fail "Project Grill failure status was not preserved: $grill_status"
[[ -d "$tmp/grill-fail-repo-planning-project-bootstrap" ]] ||
  fail "Project Grill failure removed the worktree"
grep -Fq "Project Grill failed with status 41" "$tmp/grill-fail.out" ||
  fail "Project Grill failure diagnostic omitted its phase and status"
grep -Fq "Inspect it with: git -C" "$tmp/grill-fail.out" ||
  fail "Project Grill failure diagnostic omitted inspection guidance"

planner_fail_repo="$(setup_repo planner-fail)"
planner_fail_log="$tmp/planner-fail.log"
set +e
(
  cd "$planner_fail_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$planner_fail_log" \
    MOCK_PLANNER_MODE=fail \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
)
planner_status=$?
set -e
[[ "$planner_status" -eq 42 ]] ||
  fail "planner failure status was not preserved: $planner_status"
[[ -d "$tmp/planner-fail-repo-planning-project-bootstrap" ]] ||
  fail "planner failure removed the worktree"

planner_scope_repo="$(setup_repo planner-scope)"
planner_scope_log="$tmp/planner-scope.log"
if (
  cd "$planner_scope_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$planner_scope_log" \
    MOCK_PLANNER_MODE=extra \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "out-of-scope project-planner change returned success"
fi
[[ "$(grep -c '^PHASE=' "$planner_scope_log")" -eq 2 ]] ||
  fail "planner-scope scenario did not run both phases"

planner_ignored_repo="$(setup_repo planner-ignored)"
planner_ignored_log="$tmp/planner-ignored.log"
if (
  cd "$planner_ignored_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$planner_ignored_log" \
    MOCK_PLANNER_MODE=ignored \
    ./scripts/start-planning.sh --agent claude --model fable >"$tmp/planner-ignored.out" 2>&1
); then
  fail "ignored project-planner file returned success"
fi
grep -Fq ".env" "$tmp/planner-ignored.out" ||
  fail "ignored project-planner diagnostic did not identify .env"

planner_weird_repo="$(setup_repo planner-weird)"
planner_weird_log="$tmp/planner-weird.log"
if (
  cd "$planner_weird_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$planner_weird_log" \
    MOCK_PLANNER_MODE=weird-paths \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "tab/newline project-planner paths returned success"
fi

planner_commit_repo="$(setup_repo planner-commit)"
planner_commit_log="$tmp/planner-commit.log"
if (
  cd "$planner_commit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$planner_commit_log" \
    MOCK_PLANNER_MODE=commit-extra \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "project-planner commit returned success"
fi

requirements_mode_repo="$(setup_repo requirements-mode)"
requirements_mode_log="$tmp/requirements-mode.log"
if (
  cd "$requirements_mode_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$requirements_mode_log" \
    MOCK_PLANNER_MODE=requirements-mode \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "requirements mode change returned success"
fi

architecture_directory_repo="$(setup_repo architecture-directory)"
architecture_directory_log="$tmp/architecture-directory.log"
if (
  cd "$architecture_directory_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$architecture_directory_log" \
    MOCK_PLANNER_MODE=architecture-directory \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "architecture directory returned success"
fi

roadmap_symlink_repo="$(setup_repo roadmap-symlink)"
roadmap_symlink_log="$tmp/roadmap-symlink.log"
if (
  cd "$roadmap_symlink_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$roadmap_symlink_log" \
    MOCK_PLANNER_MODE=roadmap-symlink \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "roadmap symlink returned success"
fi

adr_non_markdown_repo="$(setup_repo adr-non-markdown)"
adr_non_markdown_log="$tmp/adr-non-markdown.log"
if (
  cd "$adr_non_markdown_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$adr_non_markdown_log" \
    MOCK_PLANNER_MODE=adr-non-markdown \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "non-Markdown ADR artifact returned success"
fi

adr_nested_repo="$(setup_repo adr-nested)"
adr_nested_log="$tmp/adr-nested.log"
if (
  cd "$adr_nested_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$adr_nested_log" \
    MOCK_PLANNER_MODE=adr-nested \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "nested ADR artifact returned success"
fi

only_roadmap_repo="$(setup_repo only-roadmap)"
only_roadmap_log="$tmp/only-roadmap.log"
if (
  cd "$only_roadmap_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$only_roadmap_log" \
    MOCK_PLANNER_MODE=only-roadmap \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "unchanged architecture returned success"
fi

only_architecture_repo="$(setup_repo only-architecture)"
only_architecture_log="$tmp/only-architecture.log"
if (
  cd "$only_architecture_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$only_architecture_log" \
    MOCK_PLANNER_MODE=only-architecture \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "unchanged roadmap returned success"
fi

mode_only_repo="$(setup_repo mode-only)"
printf '# Architecture\n\nExisting populated architecture.\n' >"$mode_only_repo/docs/architecture.md"
printf '# Roadmap\n\n## F01 — Existing feature\n' >"$mode_only_repo/docs/roadmap.md"
git -C "$mode_only_repo" add docs/architecture.md docs/roadmap.md
git -C "$mode_only_repo" commit -qm "Populate planning documents"
git -C "$mode_only_repo" push -q origin main
mode_only_log="$tmp/mode-only.log"
if (
  cd "$mode_only_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$mode_only_log" \
    MOCK_PLANNER_MODE=mode-only \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "mode-only architecture and roadmap changes returned success"
fi

executable_docs_repo="$(setup_repo executable-docs)"
executable_docs_log="$tmp/executable-docs.log"
if (
  cd "$executable_docs_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$executable_docs_log" \
    MOCK_PLANNER_MODE=executable-docs \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "executable planning documents returned success"
fi

invalid_repo="$(setup_repo invalid)"
if (
  cd "$invalid_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model fable >/dev/null 2>&1
); then
  fail "known incompatible agent/model combination returned success"
fi
[[ ! -e "$tmp/invalid-repo-planning-project-bootstrap" ]] ||
  fail "invalid combination created a worktree"

unknown_agent_repo="$(setup_repo unknown-agent)"
if (
  cd "$unknown_agent_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent other --model model >/dev/null 2>&1
); then
  fail "unknown agent returned success"
fi

invalid_name_repo="$(setup_repo invalid-name)"
if (
  cd "$invalid_name_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra ../unsafe >/dev/null 2>&1
); then
  fail "unsafe planning name returned success"
fi

invalid_model_repo="$(setup_repo invalid-model)"
if (
  cd "$invalid_model_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model "bad model" >/dev/null 2>&1
); then
  fail "unsafe model syntax returned success"
fi

option_model_repo="$(setup_repo option-model)"
if (
  cd "$option_model_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model --fallback >/dev/null 2>&1
); then
  fail "option-like model returned success"
fi

missing_cli_repo="$(setup_repo missing-cli)"
if (
  cd "$missing_cli_repo"
  PATH="$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent claude --model fable >/dev/null 2>&1
); then
  fail "missing selected agent CLI returned success"
fi

remote_repo="$(setup_repo remote-duplicate)"
git -C "$remote_repo" branch planning/project-bootstrap
git -C "$remote_repo" push -q origin planning/project-bootstrap
git -C "$remote_repo" branch -D planning/project-bootstrap >/dev/null
if (
  cd "$remote_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "existing remote planning branch returned success"
fi
[[ ! -e "$tmp/remote-duplicate-repo-planning-project-bootstrap" ]] ||
  fail "remote duplicate branch created a worktree"

local_repo="$(setup_repo local-duplicate)"
git -C "$local_repo" branch planning/project-bootstrap
if (
  cd "$local_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/local-duplicate.out" 2>&1
); then
  fail "existing local planning branch returned success"
fi
grep -Fq "planning branch already exists" "$tmp/local-duplicate.out" ||
  fail "local branch collision diagnostic was not actionable"
[[ ! -e "$tmp/local-duplicate-repo-planning-project-bootstrap" ]] ||
  fail "local branch collision created a worktree path"

path_repo="$(setup_repo path-duplicate)"
mkdir "$tmp/path-duplicate-repo-planning-project-bootstrap"
if (
  cd "$path_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "existing worktree path returned success"
fi
if git -C "$path_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "existing worktree path created a planning branch"
fi

dangling_path_repo="$(setup_repo dangling-path)"
ln -s "$tmp/missing-worktree-target" "$tmp/dangling-path-repo-planning-project-bootstrap"
if (
  cd "$dangling_path_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/dangling-path.out" 2>&1
); then
  fail "dangling worktree symlink returned success"
fi
grep -Fq "planning worktree path already exists" "$tmp/dangling-path.out" ||
  fail "dangling worktree diagnostic was not explicit"
if git -C "$dangling_path_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "dangling worktree path created a planning branch"
fi

missing_prompt_repo="$(setup_repo missing-prompt)"
rm "$missing_prompt_repo/.agents/prompts/project-planner.md"
if (
  cd "$missing_prompt_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "missing project-planner prompt returned success"
fi

missing_base_repo="$(setup_repo missing-base)"
git -C "$missing_base_repo" remote set-url origin "$tmp/does-not-exist.git"
if (
  cd "$missing_base_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >"$tmp/missing-base.out" 2>&1
); then
  fail "unavailable origin/main returned success"
fi
grep -Fq "could not fetch origin/main" "$tmp/missing-base.out" ||
  fail "unavailable origin/main diagnostic was not actionable"

dirty_repo="$(setup_repo dirty)"
printf '\nDirty.\n' >>"$dirty_repo/AGENTS.md"
if (
  cd "$dirty_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    ./scripts/start-planning.sh --agent codex --model astra >/dev/null 2>&1
); then
  fail "dirty repository returned success"
fi
[[ ! -e "$tmp/dirty-repo-planning-project-bootstrap" ]] ||
  fail "dirty repository created a worktree"

# A project description from outside the repository is copied into the
# planning worktree before the phases start and is announced to Project Grill.
description="$tmp/project idea.txt"
printf 'A local-first recipe organizer.\n' >"$description"
description_repo="$(setup_repo description)"
description_log="$tmp/description.log"
(
  cd "$description_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$description_log" \
    ./scripts/start-planning.sh --description "$description" --agent claude --model fable \
    >"$tmp/description.out" 2>&1
) || {
  cat "$tmp/description.out" >&2
  fail "planning with a project description failed"
}
description_worktree="$tmp/description-repo-planning-project-bootstrap"
cmp -s "$description" "$description_worktree/docs/PROJECT_DESCRIPTION.md" ||
  fail "project description was not copied into the planning worktree"
grep -Fq "docs/PROJECT_DESCRIPTION.md" "$description_log" ||
  fail "project description was not announced to the agent"
[[ -z "$(git -C "$description_repo" status --porcelain)" ]] ||
  fail "project description changed the primary checkout"

# An uncommitted description inside the repository is accepted, but it does
# not excuse other uncommitted changes.
inside_repo="$(setup_repo description-inside)"
printf 'An untracked description in the checkout.\n' >"$inside_repo/idea.md"
printf '\nDirty.\n' >>"$inside_repo/AGENTS.md"
if (
  cd "$inside_repo"
  PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/description-inside.log" \
    ./scripts/start-planning.sh --description idea.md --agent codex --model astra >/dev/null 2>&1
); then
  fail "unrelated uncommitted changes were accepted together with a description"
fi
[[ ! -e "$tmp/description-inside-repo-planning-project-bootstrap" ]] ||
  fail "a dirty checkout created a worktree"
git -C "$inside_repo" checkout -q -- AGENTS.md
(
  cd "$inside_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/description-inside.log" \
    ./scripts/start-planning.sh --description idea.md --agent codex --model astra \
    >"$tmp/description-inside.out" 2>&1
) || {
  cat "$tmp/description-inside.out" >&2
  fail "an uncommitted description inside the repository was rejected"
}
cmp -s "$inside_repo/idea.md" \
  "$tmp/description-inside-repo-planning-project-bootstrap/docs/PROJECT_DESCRIPTION.md" ||
  fail "in-repository description was not copied into the planning worktree"

# A phase that modifies the supplied description exceeds its scope.
description_edit_repo="$(setup_repo description-edit)"
if (
  cd "$description_edit_repo"
  printf 'y\n' |
    PATH="$tmp/bin:$ISOLATED_PATH" \
    MOCK_AGENT_LOG="$tmp/description-edit.log" \
    MOCK_GRILL_MODE=edit-description \
    ./scripts/start-planning.sh --description "$description" --agent codex --model astra \
    >/dev/null 2>&1
); then
  fail "a modified project description returned success"
fi
[[ "$(grep -c '^PHASE=' "$tmp/description-edit.log")" -eq 1 ]] ||
  fail "planner ran after the project description was modified"

# An unusable description fails before any branch or worktree is created.
: >"$tmp/empty-description.txt"
description_invalid_repo="$(setup_repo description-invalid)"
for invalid_description in "$tmp/no-such-description.txt" "$tmp/empty-description.txt" "$tmp/bin" ""; do
  if (
    cd "$description_invalid_repo"
    PATH="$tmp/bin:$ISOLATED_PATH" \
      MOCK_AGENT_LOG="$tmp/description-invalid.log" \
      ./scripts/start-planning.sh --agent codex --model astra --description "$invalid_description" \
      >/dev/null 2>&1
  ); then
    fail "unusable project description returned success: '$invalid_description'"
  fi
done
[[ ! -e "$tmp/description-invalid-repo-planning-project-bootstrap" ]] ||
  fail "unusable project description created a worktree"
if git -C "$description_invalid_repo" show-ref --verify --quiet refs/heads/planning/project-bootstrap; then
  fail "unusable project description created a branch"
fi
[[ ! -e "$tmp/description-invalid.log" ]] || fail "an agent started despite an unusable project description"

# --- Change cycle ------------------------------------------------------------
#
# A change to a planning that was approved and merged before.

# Records a planning approval that matches the planning documents in <dir>.
record_planning_approval() {
  local fingerprint

  fingerprint="$(bash -c 'source "$1/scripts/lib/fingerprint.sh"; source "$1/scripts/lib/planning.sh"
    scratch="$(mktemp -d)"; fingerprint_files "$1" "$scratch" "${PLANNING_SCOPE[@]}"; rm -rf "$scratch"' _ "$1")"
  printf '# Planning Approval\n\nStatus: Approved\nPlanning fingerprint: %s\n' "$fingerprint" >"$1/docs/PLANNING_APPROVAL.md"
}

# Creates a repository whose origin/main holds an approved planning with one
# feature, one ADR, and the original project description.
setup_approved_repo() {
  local label="$1"
  local repo
  local worktree="$tmp/${label}-repo-planning-project-bootstrap"

  repo="$(setup_repo "$label")"
  printf 'The original idea.\n' >"$tmp/$label-idea.md"
  (
    cd "$repo"
    printf 'y\n' |
      PATH="$tmp/bin:$ISOLATED_PATH" MOCK_AGENT_LOG="$tmp/$label-bootstrap.log" \
      ./scripts/start-planning.sh --agent codex --model astra --description "$tmp/$label-idea.md" >/dev/null 2>&1
  ) || fail "the first planning of $label failed"
  mkdir -p "$worktree/docs/decisions"
  printf '# ADR 001: Local component\n\n## Status\n\nAccepted.\n' >"$worktree/docs/decisions/001-local-component.md"
  # Generate more than a pipe buffer without an early-closing producer pipe.
  if [[ "${PAD_REQUIREMENTS:-}" == 1 ]]; then
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "A line of approved requirements that makes the document large." }' \
      >>"$worktree/docs/PROJECT_REQUIREMENTS.md"
  fi
  record_planning_approval "$worktree"
  git -C "$worktree" add -A
  git -C "$worktree" -c user.name="Planning Test" -c user.email="planning-test@example.com" \
    commit -qm "Plan project bootstrap"
  git -C "$worktree" push -q origin HEAD:main
  git -C "$repo" pull -q
  git -C "$repo" cat-file -e origin/main:docs/decisions/001-local-component.md ||
    fail "the approved planning of $label has no ADR"
  printf '%s\n' "$repo"
}

change_request="$tmp/change-request.md"
printf 'Add a shopping list that is filled from the recipes.\n' >"$change_request"
add_feature='printf "\n## F02 — Shopping list\n\n- Goal: list what to buy.\n- Dependencies: F01.\n" >>docs/roadmap.md'

# run_change <repo> <log-label> <stdin> <name> [option...]
run_change() {
  local repo="$1"
  local label="$2"
  local answer="$3"
  local name="$4"

  shift 4
  (
    cd "$repo"
    printf '%s' "$answer" |
      PATH="$tmp/bin:$ISOLATED_PATH" MOCK_AGENT_LOG="$tmp/$label.log" \
      ./scripts/start-planning.sh "$name" --agent codex --model astra "$@"
  ) >"$tmp/$label.out" 2>&1
}

phases() {
  awk -F= '/^PHASE=/ { print $2 }' "$1" | paste -sd, -
}

# An early approval line in a large document must not cause producer SIGPIPE.
big_repo="$(PAD_REQUIREMENTS=1 setup_approved_repo big)"
[[ "$(git -C "$big_repo" show origin/main:docs/PROJECT_REQUIREMENTS.md | wc -c)" -gt 1000000 ]] ||
  fail "the large requirements fixture is too small"
MOCK_CHANGE_PLANNER="$add_feature" run_change "$big_repo" change-big "" big-change --change "$change_request" || {
  cat "$tmp/change-big.out" >&2
  fail "a change cycle on a large approved requirements file failed"
}
[[ "$(phases "$tmp/change-big.log")" == "planner" ]] || fail "large requirements did not reach the planner"
cmp -s "$big_repo/docs/PROJECT_REQUIREMENTS.md" "$big_repo-planning-big-change/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the large approved requirements changed"

# A new feature that fits the requirements changes only the roadmap. Only the
# planner runs, the requirements keep their approval, and the change request
# gets its own file next to the original description.
change_repo="$(setup_approved_repo change)"
approved_requirements="$(git -C "$change_repo" show origin/main:docs/PROJECT_REQUIREMENTS.md)"
MOCK_CHANGE_PLANNER="$add_feature" run_change "$change_repo" change-roadmap "" shopping-list --change "$change_request" || {
  cat "$tmp/change-roadmap.out" >&2
  fail "a roadmap-only change failed"
}
change_worktree="$tmp/change-repo-planning-shopping-list"
[[ "$(git -C "$change_worktree" branch --show-current)" == "planning/shopping-list" ]] ||
  fail "the change cycle did not get its own planning branch"
[[ "$(phases "$tmp/change-roadmap.log")" == "planner" ]] || fail "a change without --grill did not run only the planner"
! grep -q '^REVIEW=' "$tmp/change-roadmap.log" || fail "a change without --grill reviewed the requirements"
grep -Fq "Planning change cycle completed." "$tmp/change-roadmap.out" || fail "the change cycle was not reported as completed"
cmp -s "$change_request" "$change_worktree/docs/changes/shopping-list.md" ||
  fail "the change request was not copied to docs/changes/"
grep -Fqx "The original idea." "$change_worktree/docs/PROJECT_DESCRIPTION.md" ||
  fail "the change cycle overwrote the original project description"
[[ "$(cat "$change_worktree/docs/PROJECT_REQUIREMENTS.md")" == "$approved_requirements" ]] ||
  fail "a change without --grill touched the approved requirements"
git -C "$change_worktree" diff --quiet -- docs/architecture.md || fail "a roadmap-only change touched the architecture"
grep -Fq "## F02 — Shopping list" "$change_worktree/docs/roadmap.md" || fail "the new feature is not in the roadmap"

# A technical change may leave the roadmap as it is.
MOCK_CHANGE_PLANNER='printf "\nA server component stores the data.\n" >>docs/architecture.md; printf "# ADR 002: Server storage\n\nSupersedes ADR 001.\n" >docs/decisions/002-server-storage.md' \
  run_change "$change_repo" change-architecture "" server-storage --change "$change_request" || {
  cat "$tmp/change-architecture.out" >&2
  fail "an architecture-only change failed"
}
git -C "$tmp/change-repo-planning-server-storage" diff --quiet -- docs/roadmap.md ||
  fail "an architecture-only change touched the roadmap"

# The planner must produce the change, keep every feature ID, keep the ADRs,
# and leave the requirements and the change request alone.
expect_change_rejected() {
  local name="$1"
  local planner_action="$2"
  local message="$3"

  if MOCK_CHANGE_PLANNER="$planner_action" run_change "$change_repo" "rejected-$name" "" "$name" --change "$change_request"; then
    cat "$tmp/rejected-$name.out" >&2
    fail "a change cycle was accepted although: $name"
  fi
  grep -Fq "$message" "$tmp/rejected-$name.out" || {
    cat "$tmp/rejected-$name.out" >&2
    fail "the rejection of '$name' did not say: $message"
  }
}

expect_change_rejected nothing-planned ":" "the change was not planned"
expect_change_rejected feature-removed 'printf "# Roadmap\n\n## F02 — Shopping list\n" >docs/roadmap.md' \
  "removed or renumbered roadmap feature(s): F01"
expect_change_rejected feature-renumbered "sed 's/## F01 /## F03 /' docs/roadmap.md >roadmap.tmp && mv roadmap.tmp docs/roadmap.md" \
  "removed or renumbered roadmap feature(s): F01"
expect_change_rejected adr-deleted "$add_feature; rm docs/decisions/001-local-component.md" \
  "deleted an existing decision artifact"
expect_change_rejected requirements-edited "$add_feature; printf 'More.\n' >>docs/PROJECT_REQUIREMENTS.md" \
  "modified the approved requirements artifact"
expect_change_rejected request-edited "$add_feature; printf 'More.\n' >>docs/changes/request-edited.md" \
  "exceeded its allowed file scope"

# A feature ID that only appears inside a code block is not a feature.
MOCK_CHANGE_PLANNER="$add_feature; printf '\n\`\`\`text\n## F09 — Example\n\`\`\`\n' >>docs/roadmap.md" \
  run_change "$change_repo" change-fenced "" fenced --change "$change_request" || fail "a roadmap with a fenced example failed"

# With --grill, Project Grill may change the requirements. They return to
# Draft, the script shows the difference, and after approval the planner runs
# on the newly approved requirements.
change_requirements='sed -e "s/^Status: Approved$/Status: Draft/" -e "s/^Approved at: .*/Approved at: Not approved/" -e "s/^One complete vertical slice.$/One complete vertical slice, and a shopping list./" docs/PROJECT_REQUIREMENTS.md >requirements.tmp && mv requirements.tmp docs/PROJECT_REQUIREMENTS.md'
MOCK_CHANGE_GRILL="$change_requirements" MOCK_CHANGE_PLANNER="$add_feature" \
  run_change "$change_repo" change-grill "y
" with-grill --change "$change_request" --grill || {
  cat "$tmp/change-grill.out" >&2
  fail "a change cycle with a requirement change failed"
}
[[ "$(phases "$tmp/change-grill.log")" == "grill,planner" ]] || fail "--grill did not run Project Grill before the planner"
[[ "$(grep -c '^REVIEW=' "$tmp/change-grill.log")" -eq 1 ]] || fail "the changed Draft was not reviewed"
grep -Fq "## docs/changes/with-grill.md" "$tmp/change-grill.log.review-stdin" &&
  grep -Fq "+One complete vertical slice, and a shopping list." "$tmp/change-grill.log.review-stdin" ||
  fail "the Draft reviewer of a change did not get the change request and the diff"
grep -Fq "+One complete vertical slice, and a shopping list." "$tmp/change-grill.out" ||
  fail "the change to the requirements was not shown before the approval"
grill_worktree="$tmp/change-repo-planning-with-grill"
grep -Fqx "Status: Approved" "$grill_worktree/docs/PROJECT_REQUIREMENTS.md" || fail "the changed requirements were not approved"
grep -Fqx "One complete vertical slice, and a shopping list." "$grill_worktree/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the approved requirements lack the change"
[[ "$(grep '^Approved at: ' "$grill_worktree/docs/PROJECT_REQUIREMENTS.md")" != "$(printf '%s\n' "$approved_requirements" | grep '^Approved at: ')" ]] ||
  fail "the changed requirements kept their old approval"

# Declining the changed requirements stops before the planner.
if MOCK_CHANGE_GRILL="$change_requirements" MOCK_CHANGE_PLANNER="$add_feature" \
  run_change "$change_repo" change-declined "n
" declined --change "$change_request" --grill; then
  fail "declined requirement changes returned success"
fi
[[ "$(phases "$tmp/change-declined.log")" == "grill" ]] || fail "the planner ran although the changed requirements were declined"

# When Project Grill leaves the requirements as they are, no approval is
# asked: the run has no input to answer with.
MOCK_CHANGE_PLANNER="$add_feature" run_change "$change_repo" change-fits "" fits --change "$change_request" --grill || {
  cat "$tmp/change-fits.out" >&2
  fail "a change that needs no requirement change failed"
}
[[ "$(phases "$tmp/change-fits.log")" == "grill,planner" ]] || fail "the planner did not run after an unchanged Project Grill"
! grep -q '^REVIEW=' "$tmp/change-fits.log" || fail "unchanged approved requirements were reviewed as a Draft"
grep -Fq "no new approval is needed" "$tmp/change-fits.out" || fail "the unchanged requirements were not reported"
[[ "$(cat "$tmp/change-repo-planning-fits/docs/PROJECT_REQUIREMENTS.md")" == "$approved_requirements" ]] ||
  fail "unchanged requirements were touched"

# Project Grill may not change anything but the requirements in a change cycle.
if MOCK_CHANGE_GRILL='printf "More.\n" >>docs/changes/grill-scope.md' \
  run_change "$change_repo" change-grill-scope "" grill-scope --change "$change_request" --grill; then
  fail "Project Grill changed the change request"
fi

# Invalid change cycles fail before a branch or worktree is created.
expect_change_refused() {
  local description="$1"
  local name="$2"
  local repo="$3"

  shift 3
  if run_change "$repo" refused "" "$name" "$@"; then
    fail "a change cycle was started although: $description"
  fi
  [[ ! -e "$tmp/refused.log" ]] || fail "an agent started although: $description"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/planning/$name"; then
    fail "a branch was created although: $description"
  fi
}

: >"$tmp/empty-change.md"
expect_change_refused "the change request does not exist" missing "$change_repo" --change "$tmp/no-such-change.md"
expect_change_refused "the change request is empty" empty "$change_repo" --change "$tmp/empty-change.md"
expect_change_refused "a description was given too" both "$change_repo" --change "$change_request" --description "$change_request"
expect_change_refused "planning cannot run unattended" unattended "$change_repo" --change "$change_request" --unattended
grep -Fq "cannot run with --unattended" "$tmp/refused.out" || fail "the refusal of an unattended planning gave no reason"
fresh_repo="$(setup_repo change-unapproved)"
expect_change_refused "no planning was approved yet" early "$fresh_repo" --change "$change_request"

# A missing Git object is a read failure, distinct from an unapproved file.
grep -Fq "has no approved" "$tmp/refused.out" || fail "draft requirements were not classified as unapproved"
missing_repo="$(setup_repo change-missing)"
git -C "$missing_repo" rm -q docs/PROJECT_REQUIREMENTS.md
git -C "$missing_repo" commit -qm "Remove requirements"
git -C "$missing_repo" push -q origin main
expect_change_refused "the requirements are missing" missing-requirements "$missing_repo" --change "$change_request"
grep -Fq "could not read origin/main:docs/PROJECT_REQUIREMENTS.md" "$tmp/refused.out" ||
  fail "missing requirements were not classified as a read failure"

# Simulate a Git read that emits approved content but then fails. Partial
# output must never authorize a cycle, even when it contains the exact line.
cat >"$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
if [[ "$*" == *"show origin/main:docs/PROJECT_REQUIREMENTS.md"* ]]; then
  printf 'Status: Approved\n'
  exit 1
fi
exec /usr/bin/git "$@"
GIT
chmod +x "$tmp/bin/git"
expect_change_refused "the requirements read fails after partial output" unreadable "$change_repo" --change "$change_request"
rm "$tmp/bin/git"
grep -Fq "could not read origin/main:docs/PROJECT_REQUIREMENTS.md" "$tmp/refused.out" ||
  fail "unreadable requirements were not classified as a read failure"
[[ ! -e "$change_repo-planning-unreadable" ]] || fail "a read failure created a worktree"

# The planning on origin/main must have a current approval: a change cycle
# does not start from a planning that was never approved, or that changed
# after its approval. Nothing is left behind.
expect_no_current_approval() {
  local label="$1"
  local repo="$2"

  expect_change_refused "$label" late "$repo" --change "$change_request"
  grep -Fq "has no current approval" "$tmp/refused.out" || fail "the refusal did not name the approval: $label"
  [[ ! -e "${repo}-planning-late" ]] || fail "a worktree was left behind although: $label"
}

unapproved_repo="$(setup_approved_repo unapproved-planning)"
git -C "$unapproved_repo" rm -q docs/PLANNING_APPROVAL.md
git -C "$unapproved_repo" commit -qm "Drop the approval"
git -C "$unapproved_repo" push -q origin main
expect_no_current_approval "the planning has no approval" "$unapproved_repo"

stale_repo="$(setup_approved_repo stale-planning)"
printf '\nChanged after the approval.\n' >>"$stale_repo/docs/roadmap.md"
git -C "$stale_repo" commit -qam "Change the roadmap without approval"
git -C "$stale_repo" push -q origin main
expect_no_current_approval "the planning changed after its approval" "$stale_repo"
if (cd "$change_repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/start-planning.sh --agent codex --model astra --change "$change_request") >/dev/null 2>&1; then
  fail "a change cycle without a name was accepted"
fi
if (cd "$change_repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/start-planning.sh again --agent codex --model astra --grill) >/dev/null 2>&1; then
  fail "--grill without --change was accepted"
fi

# A change request name that origin/main already has is refused.
git -C "$change_worktree" add -A
git -C "$change_worktree" -c user.name="Planning Test" -c user.email="planning-test@example.com" commit -qm "Plan change"
git -C "$change_worktree" push -q origin HEAD:main
git -C "$change_worktree" switch -q --detach
git -C "$change_repo" branch -q -D planning/shopping-list
expect_change_refused "the change request name is taken" shopping-list "$change_repo" --change "$change_request"

echo "start-planning tests passed"
