#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/run-feature.sh, part 1 of 4: the publication, the
# base of a feature, the completion gate, the review rounds, and the stops
# for a decision of the owner. The fakes, the helpers, and the scenario
# register of all parts are in tests/lib-run-feature.sh; every case starts
# with 'scenario <id>'.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"
source "$source_root/tests/lib-run-feature.sh"

# One command takes an Issue to an open pull request: a review without
# findings needs no triage and no fixes.
scenario clean
repo="$(setup_repo clean)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq -- "--sandbox workspace-write" "$repo.control/implementer.args" || fail "the implementer did not run in the sandbox"
grep -Fqx "F02 — Feature file" <<<"$(git -C "$repo-2-thing" log -1 --format=%s)" || fail "the commit is not named after the Issue"
grep -Fqx -- "- Adds the feature file." <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit message lacks the implementer's summary"

# The pull request closes the Issue, because the completion gate passed: the
# commit carries the statement of the implementer's record.
grep -Fqx "Completion: complete" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not carry the completion statement"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the pull request of a complete feature does not close the Issue"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "the pull request of a complete feature is a draft"; fi
# The run's own publication, without --summary, reports the run figures from
# the run records: the orchestrator's one full verification, reused by the
# commit, and the lead time up to this publication.
grep -Fqx "## Run figures" "$repo.control/pr-body" || { cat "$repo.control/pr-body" >&2; fail "the pull request of the run lacks the run figures"; }
grep -Fqx "| Full verifications | 1 |" "$repo.control/pr-body" || fail "the pull request of the run does not report one full verification"
grep -Eq '^\| Implementer and triage-implementer session time \| [0-9]+ s ' "$repo.control/pr-body" ||
  fail "the pull request of the run lacks the session time"
grep -Eq '^\| Lead time from the first run start to the pull request \| [0-9]+ s .*, up to this publication \|$' "$repo.control/pr-body" ||
  fail "the pull request of the run lacks the lead time"
grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-1.context" ||
  fail "the reviewer was not given the completion record"
grep -Fq '"status": "complete"' "$repo.control/reviewer-1.context" || fail "the reviewer was not shown what the record says"
grep -Fq "not evidence" "$repo.control/reviewer-1.context" || fail "the reviewer was not told that the record is a claim"

if grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out"; then fail "ordinary work was reported as needing the owner's approval"; fi
grep -Fqx -- "- not required" <<<"$(git -C "$repo-2-thing" log -1 --format=%B | grep -A1 -Fx "Merge approval:")" ||
  fail "the commit does not record that no approval is needed"

grep -Fq "pr create --base main --head feature/2-thing" "$repo.control/gh.log" ||
  fail "the pull request does not target main, the default base without a project default"

# The risk level is printed when the feature starts and before the review,
# the reviewer is told, the commit records it, and the run record notes it.
grep -Fq "run-feature.sh: risk level at the start: medium" "$repo.out" || fail "the risk level was not printed when the feature started"
grep -Fq "run-feature.sh: risk level before round 1: medium" "$repo.out" || fail "the risk level was not printed before the review"
grep -Fq "## Risk level" "$repo.control/reviewer-1.context" || fail "the reviewer was not told the risk level"
grep -Fqx "Risk: medium" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the risk level"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "risk" and .level == "medium" and (.reasons | length) >= 1)' >/dev/null ||
  fail "the risk level is not in the run records"

# A finished feature is not run again: a repeated command only publishes.
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0

# A project whose features branch from and merge into 'develop' says so once,
# in .agents/template.conf, and every step uses that base: the worktree is
# created from it and records it, the review, the guardrails, and the risk
# compare with it, and the pull request merges into it. 'develop' holds an
# ADR that 'main' lacks, so a step that compared with 'main' would see a
# protected change that is not the feature's.
scenario develop-base
repo_develop="$(setup_repo develop-base)"
git -C "$repo_develop" checkout -q -b develop
printf 'base: develop\n' >"$repo_develop/.agents/template.conf"
mkdir -p "$repo_develop/docs/decisions"
printf '# ADR 0001\n' >"$repo_develop/docs/decisions/0001-develop.md"
git -C "$repo_develop" add .agents/template.conf docs/decisions
git -C "$repo_develop" commit -qm "Develop"
git -C "$repo_develop" push -q origin develop
run_feature "$repo_develop" 2 thing
expect_published "$repo_develop"
[[ "$(git -C "$repo_develop-2-thing" config --get branch.feature/2-thing.workflow-base)" == "develop" ]] ||
  fail "the project default base was not recorded for the feature"
git -C "$repo_develop-2-thing" merge-base --is-ancestor origin/develop HEAD ||
  fail "the feature was not created from the project default base"
grep -Fq "pr create --base develop --head feature/2-thing" "$repo_develop.control/gh.log" ||
  fail "the pull request does not merge into the base of the feature"
grep -Eq "Complete diff against (origin/)?develop," "$repo_develop.control/reviewer-1.context" ||
  fail "the review did not compare with the base of the feature"
if grep -Fq "0001-develop.md" "$repo_develop.control/reviewer-1.context"; then
  fail "the review counted a change of the base as the feature's"
fi
if grep -Fq "MERGE APPROVAL REQUIRED" "$repo_develop.out"; then
  fail "a change of the base was counted as a protected change of the feature"
fi
# Run by hand in the worktree, without a base, the checks take the recorded
# base, not main.
(cd "$repo_develop-2-thing" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/check-guardrails.sh) >"$repo_develop.guardrails" 2>&1 ||
  fail "check-guardrails.sh failed on the recorded base: $(cat "$repo_develop.guardrails")"
grep -Fqx "level: none" <<<"$(sed -n 1p "$repo_develop.guardrails")" ||
  fail "check-guardrails.sh did not compare with the recorded base: $(cat "$repo_develop.guardrails")"
(cd "$repo_develop-2-thing" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/check-risk.sh) >"$repo_develop.risk" 2>&1 || true
if grep -Fq "decisions" "$repo_develop.risk"; then
  fail "check-risk.sh did not compare with the recorded base: $(cat "$repo_develop.risk")"
fi

# --risk high raises the level of the feature for the run: at the start,
# before the review, and in the commit, with the hint and its source in the
# run record. A --risk without a level is refused.
scenario hinted
repo_hint="$(setup_repo hinted)"
run_feature "$repo_hint" 2 thing --risk high
expect_published "$repo_hint"
grep -Fq "run-feature.sh: risk level at the start: high" "$repo_hint.out" || fail "--risk high did not raise the level at the start"
grep -Fq "run-feature.sh: risk level before round 1: high" "$repo_hint.out" || fail "--risk high did not raise the level before the review"
grep -Fqx "Risk: high" <<<"$(git -C "$repo_hint-2-thing" log -1 --format=%B)" || fail "the commit does not record the raised level"
grep -Fqx -- "- the owner gave --risk high for this run, which raises the level to high" <<<"$(git -C "$repo_hint-2-thing" log -1 --format=%B)" ||
  fail "the commit does not name --risk as a reason"
cat "$repo_hint"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "risk" and .when == "at the start" and .hints == [{level: "high", source: "command-line"}])' >/dev/null ||
  fail "the run record does not note --risk and its source"
run_feature "$repo_hint" 3 --risk
[[ "$status" -eq 1 ]] || fail "a --risk without a level was not refused ($status)"

# The completion gate. A session of the implementer that ends without an
# error has not completed the feature by that alone: the run goes on to the
# review only when the completion record says complete, the handoff note
# lists nothing that remains, and the summary of the changes exists.
# Otherwise the implementer is resumed with the reason in its handoff note.
#
# The case of the bug this guards against: the implementer stopped after two
# of nine plan steps, said so in its handoff note, and ended normally.
scenario stopped-partway
repo="$(setup_repo stopped-partway)"
printf '%s\n' 'printf "steps 1 and 2\n" >>feature.txt
mkdir -p .agents/handoffs
printf "**Done:** steps 1 and 2.\n**Remaining:** steps 3 to 9.\n" >".agents/handoffs/$RUN_ISSUE.md"
completion partial "Plan steps 3 to 9"
reply="Steps 1 and 2 are done. I ran out of time."' >"$repo.control/implementer-1.sh"
printf '%s\n' 'eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"' \
  >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| implementation | not complete | partial: " <<<"$(log_of "$repo")" || fail "the session that stopped partway is not in the log of the feature"
grep -Fq "remaining: Plan steps 3 to 9" <<<"$(log_of "$repo")" || fail "what remained is not in the log of the feature"
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the implementer was not resumed after it stopped partway"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the completed feature does not close the Issue"

# The reason is put in the handoff note for the session that continues.
scenario stopped-partway-note
repo="$(setup_repo stopped-partway-note)"
printf '%s\n' 'completion partial "Plan steps 3 to 9"; reply="Stopped."' >"$repo.control/implementer-1.sh"
printf '%s\n' 'cp ".agents/handoffs/$RUN_ISSUE.md" "$RUN_CONTROL/note-seen"; eval "$default"' >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "## Not complete" "$repo.control/note-seen" || fail "the resumed implementer was not told that the gate did not pass"
grep -Fq -- "- gate: remaining: Plan steps 3 to 9" "$repo.control/note-seen" || fail "the resumed implementer was not told what remained"
# What the run records there does not itself count as remaining work.
[[ -n "$(git -C "$repo-2-thing" log -1 --format=%B | grep -Fx 'Completion: complete')" ]] ||
  fail "the note of the run kept the gate from passing"
# The run records one check of the gate per check, with the implementation
# sessions before it: partial after session 1, complete after session 2,
# and the check before the review after the same session 2 is check 3.
gates="$(cat "$repo"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "completion-gate") | "\(.check):\(.sessions):\(.status)"] | join(" ")')"
[[ "$gates" == "1:1:partial 2:2:complete"* ]] || fail "the gate checks of the run are not recorded per check and session: $gates"
if grep -Eq '(^| )[0-9]+:1:partial .*[0-9]+:1:partial' <<<"$gates"; then fail "one session gave two partial outcomes: $gates"; fi
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "experience" and (.record.derived.completion_gates | map(.status) | index("partial")) != null)' >/dev/null ||
  fail "the experience record of the run lacks the gate checks"

# Without any completion record, the same: the end of a session says nothing.
scenario no-record
repo="$(setup_repo no-record)"
printf '%s\n' 'printf "half\n" >>feature.txt; mkdir -p .agents/summaries
printf -- "- Adds half of the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"; reply="Done."' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| not complete | missing: the implementer wrote no completion record" <<<"$(log_of "$repo")" ||
  fail "the missing completion record is not in the log of the feature"

# A record that says complete is not believed against the handoff note.
scenario record-contradicted
repo="$(setup_repo record-contradicted)"
printf '%s\n' 'eval "$default"; mkdir -p .agents/handoffs
printf "## Done\nsteps 1 and 2\n\n## Remaining\n- step 3\n- step 4\n" >".agents/handoffs/$RUN_ISSUE.md"' >"$repo.control/implementer-1.sh"
printf '%s\n' 'eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"' \
  >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "the completion record says complete, but the handoff note" <<<"$(log_of "$repo")" ||
  fail "the contradiction between the record and the handoff note is not in the log of the feature"

# A complete record without the summary of the changes: the commit message
# of an unattended run would say nothing, so the implementer is resumed.
scenario no-summary
repo="$(setup_repo no-summary)"
printf '%s\n' 'printf "feature\n" >>feature.txt; completion complete; reply="Done."' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| not complete | no summary: the implementer wrote no summary of the changes" <<<"$(log_of "$repo")" ||
  fail "the missing summary is not in the log of the feature"
grep -Fqx -- "- Adds the feature file." <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit message lacks the summary that the resumed implementer wrote"

# Evidence that cannot exist yet does not stop the run. An implementer that
# records awaiting_evidence, with the CI result of the pull request pending,
# goes on to the review in one session; the commit says so and the pull
# request closes the Issue, because that evidence exists before the merge.
awaiting() {
  # awaiting <gate>: the implementer's work, with a criterion pending at the gate
  printf '%s\n' 'printf "feature\n" >>feature.txt
mkdir -p .agents/summaries .agents/completion
printf -- "- Adds the feature file.\n" >".agents/summaries/$RUN_ISSUE.md"
printf "{\"schema\": \"completion/v1\", \"status\": \"awaiting_evidence\", \"criteria\": [{\"criterion\": \"The feature file exists\", \"status\": \"met\", \"evidence\": \"feature.txt\"}, {\"criterion\": \"Evidence later\", \"gate\": \"'"$1"'\", \"status\": \"pending\", \"evidence\": \"after the gate\"}], \"remaining\": []}\n" >".agents/completion/$RUN_ISSUE.json"
reply="Done."'
}

scenario awaiting-pr-ci
repo="$(setup_repo awaiting-pr-ci)"
awaiting pr_ci >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fqx "Completion: awaiting_evidence" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not say that the feature awaits evidence"
grep -Fqx -- "- pending at pr_ci: Evidence later (after the gate)" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not name the pending evidence"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "a feature that awaits only pr_ci evidence does not close the Issue"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "a feature that awaits evidence was opened as a draft"; fi
grep -Fq '"status": "awaiting_evidence"' "$repo.control/reviewer-1.context" || fail "the reviewer was not shown the awaiting_evidence record"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "completion-gate" and .status == "awaiting_evidence")' >/dev/null ||
  fail "the completion gate outcome awaiting_evidence is not in the run records"

# Evidence of the post_merge gate keeps the Issue open, but the pull request
# is ready for review.
scenario awaiting-post-merge
repo="$(setup_repo awaiting-post-merge)"
awaiting post_merge >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
if grep -Eiq '(^|[^[:alnum:]])(close[sd]?|fix(e[sd])?|resolve[sd]?):? +#2([^0-9]|$)' "$repo.control/pr-body"; then
  fail "a feature that awaits post_merge evidence closes the Issue on the merge"
fi
grep -Fq "evidence of the post_merge gate is pending" "$repo.control/pr-body" || fail "the pull request does not say why the Issue stays open"
grep -Fq "./scripts/record-post-merge.sh 2" "$repo.out" || fail "the end of the run does not name record-post-merge.sh"
if grep -Fq -- "--draft" "$repo.control/gh.log"; then fail "a feature that awaits post_merge evidence was opened as a draft"; fi

# The sessions are bounded: an implementer that never completes the Issue
# stops the run before any review, commit, or pull request.
scenario never-complete
repo="$(setup_repo never-complete)"
printf '%s\n' 'printf "more\n" >>feature.txt; completion partial "Plan steps 3 to 9"; reply="Stopped again."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementer ended 4 sessions without completing the Issue (partial): not met: The feature file exists; remaining: Plan steps 3 to 9"
expect_sessions "$repo" 4 0 0 0
[[ -n "$(git -C "$repo-2-thing" status --porcelain)" ]] || fail "work that is not complete was committed"
[[ "$(git -C "$repo-2-thing" rev-list --count origin/main..HEAD)" -eq 0 ]] || fail "work that is not complete was committed"
if git -C "$repo" ls-remote --exit-code --heads origin feature/2-thing >/dev/null 2>&1; then
  fail "work that is not complete was pushed"
fi
# Running again gives the implementer the same number of sessions again.
run_feature "$repo" 2
expect_stopped "$repo" 1 "without completing the Issue"
expect_sessions "$repo" 8 0 0 0

# A record that says blocked stops the run for the human, with status 3,
# also without a BLOCKED line in the final message.
scenario record-blocked
repo="$(setup_repo record-blocked)"
printf '%s\n' 'printf "part\n" >>feature.txt; completion blocked "The Issue contradicts ADR 002"; reply="I cannot go on."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer reports that it cannot complete the Issue without you: not met: The feature file exists; remaining: The Issue contradicts ADR 002"
expect_sessions "$repo" 1 0 0 0

# Findings are triaged without a question and fixed, a second round confirms
# the fixes on the changes, and a third reviews the complete feature again:
# the round a feature is committed on always covers the whole Issue.
scenario fixed
repo="$(setup_repo fixed)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 1
[[ "$(grep -c "Review of changes only" "$repo.control/reviewer.args")" -eq 1 ]] ||
  fail "the round after the fixes did not review only the changes, or the last round did"
if grep -Fq "Review of changes only" <<<"$(sed -n 3p "$repo.control/reviewer.args")"; then
  fail "the last round reviewed only the changes"
fi
grep -Fq "## Complete diff against" "$repo.control/reviewer-3.context" || fail "the last round was not given the complete feature"
grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-3.context" ||
  fail "the last round was not given the completion record"
if grep -Fq "## Completion record of the implementer" "$repo.control/reviewer-2.context"; then
  fail "a review of changes only was given the completion record to judge"
fi
log_of "$repo" >/dev/null
grep -Fq "review of the complete feature, round 3 of at most 5" "$repo.out" || fail "the closing review was not announced"
triage="$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json"
[[ "$(jq -r '.unattended' "$triage")" == "true" ]] || fail "the triage does not record that no human approved it"
[[ "$(jq -r '[.decisions[].decision] | join(",")' "$triage")" == "FIX_NOW,DEFER" ]] || fail "the triage lost its decisions"
grep -q '^issue comment 2 ' "$repo.control/gh.log" || fail "the triage was not published on the Issue"
grep -q '^issue create ' "$repo.control/gh.log" || fail "the deferred finding got no follow-up Issue"
grep -q "^Review: round 3, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not name the review of the complete feature"

# The run is recorded in the primary checkout: one run, its steps, the
# verifications, and an agent call per session with its role, and the runs of
# the feature together in .agents/records/ after the publication.
records="$(cat "$repo"/.agents/run/records/*.jsonl)"
[[ "$(jq -r -s '[.[] | select(.type == "run-start")] | length' <<<"$records")" -eq 1 ]] ||
  fail "the run of the feature is not one run: the commands it started made runs of their own"
[[ "$(jq -r -s '.[] | select(.type == "run-start") | "\(.kind) \(.subject) \(.command)"' <<<"$records")" == "feature 2 run-feature.sh" ]] ||
  fail "the run does not name the feature"
[[ "$(jq -r -s '[.[] | select(.type == "agent-call") | .role] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"$records")" == "implementer=1 reviewer=3 triage=1 triage-implementer=1" ]] ||
  fail "the agent calls are not recorded per role: $(jq -r -s '[.[] | select(.type == "agent-call") | .role] | join(",")' <<<"$records")"
jq -e -s 'any(.type == "verification" and .status == 0)' <<<"$records" >/dev/null || fail "the verifications are not recorded"
jq -e -s 'any(.type == "step" and .name == "review, round 1 of at most 5")' <<<"$records" >/dev/null || fail "the steps are not recorded"
jq -e -s 'any(.type == "run-end" and .status == 0)' <<<"$records" >/dev/null || fail "the end of the run is not recorded"
[[ -s "$repo/.agents/records/feature-2.jsonl" ]] || fail "the runs of the feature were not copied to .agents/records/ by the publication"
# The copy holds the run to its end: the publication and the status.
jq -e -s 'any(.type == "step" and .name == "pull request" and .status == 0)' "$repo/.agents/records/feature-2.jsonl" >/dev/null ||
  fail "the copy lacks the publication"
[[ "$(jq -r -s '.[-1] | "\(.type) \(.status)"' "$repo/.agents/records/feature-2.jsonl")" == "run-end 0" ]] ||
  fail "the copy does not end with the end of the run"
jq -e -s '[.[] | select(.type == "agent-start") | .id] == [.[] | select(.type == "agent-call") | .id]' <<<"$records" >/dev/null ||
  fail "an agent call does not close its start"
[[ ! -d "$repo-2-thing/.agents/run/records" ]] || fail "the run wrote records into the feature worktree"

# A finding of the closing review is fixed like any other, and the run ends
# on a review of the complete feature again.
scenario closing-review-finds
repo="$(setup_repo closing-review-finds)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$only_major" >"$repo.control/reviewer-3.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 5 2 2
grep -q "^Review: round 5, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the run did not end on the fifth round"
if grep -Fq "Review of changes only" <<<"$(sed -n 5p "$repo.control/reviewer.args")"; then
  fail "the run ended on a review of changes only"
fi

# When the rounds are used and the last one reviewed only changes, nothing
# confirms that the Issue is done: the run stops before the commit.
scenario rounds-end-on-changes
repo="$(setup_repo rounds-end-on-changes)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
for n in 2 3 4; do printf '%s\n' "$only_major" >"$repo.control/reviewer-$n.sh"; done
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "5 review rounds are used, and round 5 reviewed only changes"
expect_sessions "$repo" 1 5 4 4
grep -Fqx "fixed" "$repo-2-thing/feature.txt" || fail "the fixes are not in the feature"

# A feature that adds an ADR still gets its pull request, and the run says
# that only the owner may merge it, although the reviewer calls it minor.
scenario adr
repo="$(setup_repo adr)"
printf '%s\n' 'eval "$default"; mkdir -p docs/decisions; printf "# ADR 002: Other\n\nStatus: Proposed\n" >docs/decisions/002-other.md' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "the run did not say that the owner must approve the merge"
grep -Fq "docs/decisions/002-other.md: an ADR is added, changed, or removed" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not record why the owner's approval is needed"

# The same when the independent reviewer classifies the impact as major.
scenario impact-major
repo="$(setup_repo impact-major)"
printf '%s\n' 'reply="{\"architecture_impact\": {\"level\": \"major\", \"rationale\": \"Adds shared infrastructure.\", \"checked_against\": []}, \"verdict\": \"PASS\", \"limitations\": \"\", \"findings\": []}"' \
  >"$repo.control/reviewer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "a major impact did not need the owner's approval"

# An unattended triage cannot let a major finding pass: the run stops.
scenario major-deferred
repo="$(setup_repo major-deferred)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer.sh"
printf '%s\n' 'reply="{\"decisions\": [
  {\"finding_id\": \"M1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null},
  {\"finding_id\": \"MIN1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null}
]}"' >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the triage of round 1 failed"
if compgen -G "$repo-2-thing/.agents/triage/*.json" >/dev/null; then fail "a triage that accepts a major finding was stored"; fi

# At most five rounds: when the fifth still has a finding to fix, the run
# stops before another fix that no review would confirm.
scenario rounds
repo="$(setup_repo rounds)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$only_major" >"$repo.control/reviewer.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "5 review rounds are used and round 5 still has findings that must be fixed"
expect_sessions "$repo" 1 5 5 4
# A later round reviews the changes with the decisions of the round before,
# so the finding that round 1 deferred got one follow-up Issue, not five.
[[ "$(grep -c "Review of changes only" "$repo.control/reviewer.args")" -eq 4 ]] ||
  fail "the rounds after the first did not review only the changes"
grep -Fq "Decision: DEFER" "$repo.control/reviewer-2.context" ||
  fail "the second round was not given the decisions of the first"
[[ "$(grep -c '^issue create ' "$repo.control/gh.log")" -eq 1 ]] ||
  fail "the deferred finding of round 1 got $(grep -c '^issue create ' "$repo.control/gh.log") follow-up Issues"
# Running again does not start a sixth round.
run_feature "$repo" 2
expect_stopped "$repo" 1 "5 review rounds are used"
expect_sessions "$repo" 1 5 5 4
grep -Fq "./scripts/run-feature.sh 2 --rounds 7    # your decision, at a terminal" "$repo.out" ||
  fail "the stop for used rounds does not offer a higher limit: $(cat "$repo.out")"
# At the ceiling (here lowered to the five rounds used; the real one is 20)
# no higher limit exists: the stop proposes no --rounds that would be refused
# or stop again at once, says that the ceiling is reached, and names the
# steps by hand.
RUN_FEATURE_ROUNDS_CEILING=5 run_feature "$repo" 2
expect_stopped "$repo" 1 "5 review rounds are used"
expect_sessions "$repo" 1 5 5 4
if grep -Fq -- "run-feature.sh 2 --rounds" "$repo.out"; then fail "the stop at the ceiling proposes --rounds: $(cat "$repo.out")"; fi
grep -Fq "the ceiling of 5 review rounds is reached" "$repo.out" ||
  fail "the stop at the ceiling does not say that it is reached: $(cat "$repo.out")"
grep -Fq "./scripts/apply-triage.sh" "$repo.out" || fail "the stop at the ceiling names no step by hand: $(cat "$repo.out")"

# --rounds <m> continues the loop with a higher limit, as the owner's decision
# at a terminal: refused without a terminal, in an agent session, and for a
# limit that is not higher than five. The run record notes the intervention.
scenario more-rounds
run_feature "$repo" 2 --rounds 7
[[ "$status" -eq 1 ]] && grep -Fq "standard input must be a terminal" "$repo.out" ||
  fail "--rounds was accepted without a terminal: $(cat "$repo.out")"
expect_sessions "$repo" 1 5 5 4
# run_at_terminal <repo> <argument>...: run-feature.sh at a pseudo-terminal.
run_at_terminal() {
  local repo="$1"
  local command

  shift
  command="PATH=$(printf '%q' "$tmp/bin:$ISOLATED_PATH") RUN_CONTROL=$(printf '%q' "$repo.control") RUN_ISSUE=$1 GIT_EDITOR=false RUN_FEATURE_RETRY_WAIT=0 START_FEATURE_GH_WAIT=0 ${AT_TERMINAL_ENV:-} ./scripts/run-feature.sh $*"
  status=0
  (
    cd "$repo"
    if grep -q util-linux <<<"$(script --version 2>/dev/null)"; then
      script -qec "$command" /dev/null </dev/null
    else
      script -q /dev/null sh -c "$command" </dev/null
    fi
  ) >"$repo.out" 2>&1 || status=$?
}
AT_TERMINAL_ENV="CODEYARD_AGENT_SESSION=1" run_at_terminal "$repo" 2 --rounds 7
[[ "$status" -ne 0 ]] && grep -Fq "it is refused in an agent session" "$repo.out" ||
  fail "--rounds was accepted in an agent session: $(cat "$repo.out")"
for limit in 5 3 21; do
  run_at_terminal "$repo" 2 --rounds "$limit"
  [[ "$status" -ne 0 ]] && grep -Fq -- "--rounds must be more than the 5 rounds" "$repo.out" ||
    fail "--rounds $limit was accepted: $(cat "$repo.out")"
done
expect_sessions "$repo" 1 5 5 4
# With seven rounds: round 5 is fixed, round 6 confirms the fix on the
# changes, and round 7 reviews the complete feature.
printf '%s\n' 'eval "$default"' >"$repo.control/reviewer-6.sh"
printf '%s\n' 'eval "$default"' >"$repo.control/reviewer-7.sh"
run_at_terminal "$repo" 2 --rounds 7
expect_published "$repo"
expect_sessions "$repo" 1 7 5 5
grep -Fq "at most 7 review rounds in this run (--rounds)" "$repo.out" || fail "the run does not say that the limit was raised"
grep -Fq "review of the complete feature, round 7 of at most 7" "$repo.out" || fail "the seventh round did not review the complete feature"
grep -q "^Review: round 7, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not name round 7"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "intervention" and .what == "raised the limit of review rounds from 5 to 7 with --rounds")' >/dev/null ||
  fail "the raised limit is not in the run record"

# An implementer that needs a decision, with its question in the handoff
# note, stops the run with status 3. After the answer, the same command
# resumes the implementation and goes on.
scenario blocked
repo="$(setup_repo blocked)"
printf '%s\n' "question='does the Issue override ADR 002?'; $ask; reply=\"BLOCKED: the Issue contradicts ADR 002\"" \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
grep -Fq "the Issue contradicts ADR 002" "$repo.out" || fail "the question of the implementer was not shown"
[[ "$(cat "$repo"/.agents/run/records/*.jsonl | jq -r 'select(.type == "run-end") | .step')" == "implementation" ]] ||
  fail "the stop of a blocked implementation does not name its step"
expect_sessions "$repo" 1 0 0 0
grep -Fq "| blocked |" <<<"$(log_of "$repo")" || fail "the blocked session is not in the log of the feature"
# The run records what a script can see, without claiming that a person did
# it: the next run follows a run that stopped with status 3, and the handoff
# note changed after that stop. Neither is an intervention.
interventions() {
  cat "$1"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "intervention") | .what] | join("|")'
}
resumptions() {
  cat "$1"/.agents/run/records/*.jsonl | jq -r -s '[.[] | select(.type == "resumed") | "\(.previous_status) \(.handoff_changed)"] | join("|")'
}
[[ "$(resumptions "$repo")" == "" ]] || fail "a first run records a resumption"
sleep 1
printf '**Open questions:** none.\n\nAnswer: the Issue overrides it.\n' >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
[[ "$(resumptions "$repo")" == "3 true" ]] ||
  fail "the run after the stop and the changed handoff note are not recorded: $(resumptions "$repo")"
[[ "$(interventions "$repo")" == "" ]] ||
  fail "a run after a stop is recorded as a human intervention: $(interventions "$repo")"
if grep -q "the Issue overrides it" <<<"$(cat "$repo"/.agents/run/records/*.jsonl)"; then fail "the answer itself reached the record"; fi
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the second session did not resume the work"

# A run that starts again after the stop without a change to the handoff
# note, as a scheduler or a retry would, records that the note did not change.
scenario blocked-restart
repo="$(setup_repo blocked-restart)"
printf '%s\n' "question='which ADR applies?'; $ask; reply=\"BLOCKED: two ADRs disagree\"" \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
sleep 1
run_feature "$repo" 2
[[ "$(resumptions "$repo" | cut -d'|' -f1)" == "3 false" ]] ||
  fail "a run after the stop without a changed note is not recorded as such: $(resumptions "$repo")"
[[ "$(interventions "$repo")" == "" ]] ||
  fail "a run after the stop without an answer is recorded as an intervention: $(interventions "$repo")"

# BLOCKED without a question in the handoff note leaves nothing to answer:
# the script goes by what is recorded, not by the line, and the run goes on.
for note in "" "**Open questions:** none blocking."; do
  scenario blocked-without-question
  repo="$(setup_repo "blocked-without-question-${#note}")"
  printf '%s\n' "eval \"\$default\"; mkdir -p .agents/handoffs; printf '%s\n' '$note' >.agents/handoffs/\$RUN_ISSUE.md; reply=\"BLOCKED: the verification did not finish\"" \
    >"$repo.control/implementer.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 1 1 0 0
  grep -Fq "holds no open question" <<<"$(log_of "$repo")" || fail "the ignored BLOCKED line is not in the log of the feature"
done

# The clarification step of the implementer (.agents/prompts/implementer.md,
# "Clarification") uses the same path. A feature that needs the owner's
# decisions: the first session changes nothing, records blocked with its two
# questions, and the run stops with status 3, with nothing reviewed or
# committed. After the owner's answers in the handoff note, the same command
# implements and publishes.
scenario clarification
repo="$(setup_repo clarification)"
cat >"$repo.control/implementer-1.sh" <<'SESSION'
mkdir -p .agents/handoffs .agents/completion
printf '%s\n' "**Clarification:** needs clarification." "" "**Open questions:**" \
  "- How many players share a room? Settles the room model; options 2 or 2-8; recommended 2-8." \
  "- Does a player reconnect into the same room? Settles the persistence; recommended yes." \
  >".agents/handoffs/$RUN_ISSUE.md"
printf '{"schema": "completion/v1", "status": "blocked", "criteria": [{"criterion": "The feature file exists", "status": "not_met", "evidence": "not started; two questions for the owner"}], "remaining": ["The owner decides the room size and reconnection"]}\n' \
  >".agents/completion/$RUN_ISSUE.json"
reply="BLOCKED: two decisions of the owner settle the room model"
SESSION
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer needs a decision of yours"
expect_sessions "$repo" 1 0 0 0
[[ -z "$(git -C "$repo-2-thing" status --porcelain)" ]] || fail "the session that asked changed the repository"
[[ "$(git -C "$repo-2-thing" rev-list --count main..HEAD)" -eq 0 ]] || fail "the session that asked was committed"
[[ "$(grep -c '^- .*?' "$repo-2-thing/.agents/handoffs/2.md")" -eq 2 ]] || fail "the two questions are not in the handoff note"
sleep 1
printf '%s\n' "**Clarification:** answered by the owner." "" "**Open questions:** none." "" \
  "Answers: rooms of 2 to 8 players; a player reconnects into the same room." >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0

# A clear feature runs as before: the implementer records the step in its
# handoff note and implements in one session. The clarification line is
# neither remaining work nor an open question, also right after the list of
# what remains.
scenario clarification-clear
repo="$(setup_repo clarification-clear)"
printf '%s\n' "eval \"\$default\"; mkdir -p .agents/handoffs; printf '**Remaining:** none.\n**Clarification:** clear, the Issue and the ADRs settle every decision.\n' >.agents/handoffs/\$RUN_ISSUE.md" \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "**Clarification:** clear" "$repo-2-thing/.agents/handoffs/2.md" || fail "the clear feature does not show the step in its handoff note"

# The step cannot stall a run silently: a session that ends with BLOCKED but
# leaves "Open questions" empty, with the clarification line after it, has
# nothing for the owner to answer, and the run goes on.
scenario clarification-without-question
repo="$(setup_repo clarification-without-question)"
printf '%s\n' "eval \"\$default\"; mkdir -p .agents/handoffs; printf '**Open questions:**\n\n**Clarification:** needs clarification.\n' >.agents/handoffs/\$RUN_ISSUE.md; reply=\"BLOCKED: unclear\"" \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "holds no open question" <<<"$(log_of "$repo")" || fail "the ignored BLOCKED line is not in the log of the feature"

scenarios_done "${BASH_SOURCE[0]}"
