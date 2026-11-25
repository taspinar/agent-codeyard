#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/run-feature.sh, part 4 of 4: the risk levels and the
# risk policy, the light triage and the profiles, the publication by hand,
# and the budgets. The fakes, the helpers, and the scenario register of all
# parts are in tests/lib-run-feature.sh; every case starts with 'scenario
# <id>'.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"
source "$source_root/tests/lib-run-feature.sh"

# What the rounds require follows the risk level and the risk policy of the
# base. With the policy the template ships, which the cases of the other
# parts run with, nothing changed: the full verification before each round,
# a review of the changes when it can build on the round before, a complete
# review last. A policy that still names groups of checks for the
# intermediate rounds ('high: verification: groups fast', refused since
# #443) gets the full verification before every round: the refusal is
# printed and in the log of the feature, no partial check runs, the fixes
# leave the verification to the run, and the round that ends the run is a
# complete review on the full verification; the commit is made on that one.
verify_trace='sound: sh -c '"'"'mkdir -p .agents/run; echo full >>.agents/run/verify-trace; test ! -e broken.txt'"'"'
fast [fast]: sh -c '"'"'mkdir -p .agents/run; echo fast >>.agents/run/verify-trace'"'"
scenario high-groups-refused
repo="$(VERIFY_CONF="$verify_trace" RISK_CONF="$(printf 'default: medium\nhigh: feature.txt\nhigh: verification: groups fast\nhigh: review: delta')" setup_repo high-groups-refused)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 1
grep -Fq "run-feature.sh: risk level before round 2: high" "$repo.out" || fail "the level of the high-risk feature was not computed before round 2"
grep -Fq "| risk policy before round 1 | refused | high: verification: groups fast is not accepted" <<<"$(log_of "$repo")" ||
  fail "the refused groups are not in the log of the feature: $(log_of "$repo")"
if grep -Fq "on a partial check of the groups" "$repo.out"; then fail "a round ran on a partial check: $(cat "$repo.out")"; fi
if grep -Fq "verify.sh --only" "$repo.control/fixes.args"; then fail "the fixing agent was told to run only the groups"; fi
grep -Fq "verify.sh --changed" "$repo.control/fixes.args" || fail "the fixing agent was not told to run the targeted check"
# The full verification of the run before round 1 and after the fix session
# before round 2; the closing round, on the same tree, and the commit reuse
# the pass of the run (the trust contract, lib/verification.sh).
[[ "$(tr '\n' ' ' <"$repo-2-thing/.agents/run/verify-trace")" == "full fast full fast " ]] ||
  fail "the checks did not run as two full verifications: $(tr '\n' ' ' <"$repo-2-thing/.agents/run/verify-trace")"
[[ "$(full_verifications "$repo")" -eq 2 ]] ||
  fail "the run made $(full_verifications "$repo") full verifications instead of one per distinct tree (two)"
round2="$repo-2-thing/.agents/reviews/feature-2-thing-review-02.json"
[[ "$(jq -c '[.scope.kind, .verification.status]' "$round2")" == '["changes","passed"]' ]] ||
  fail "round 2 is not a delta review on the full verification: $(jq -c '[.scope, .verification]' "$round2")"
if grep -Fq "## Verification of the content under review" "$repo.control/reviewer-2.context"; then fail "the reviewer of round 2 was told about a partial check"; fi
[[ "$(jq -r '.verification.status' "$repo-2-thing/.agents/reviews/feature-2-thing-review-03.json")" == "passed" ]] ||
  fail "the closing round was not made on the full verification"
grep -q "^Review: round 3, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not rest on the closing round"
grep -Fqx "Risk: high" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the high level"
# The complete closing round gets the decisions of the approved triages of
# every earlier round, not only those of the round before.
grep -Fqx "## Decisions of the earlier rounds" "$repo.control/reviewer-3.context" ||
  fail "the closing round was not given the earlier decisions"
grep -Eq '^- Round 1, M1 \[major\] .+: FIX_NOW — It is wrong\.$' "$repo.control/reviewer-3.context" ||
  fail "the closing round was not given the decision to fix of round 1"
grep -Eq '^- Round 1, MIN1 \[minor\] .+: DEFER — Later\.$' "$repo.control/reviewer-3.context" ||
  fail "the closing round was not given the deferred finding of round 1"
grep -Fqx -- "- Round 2: no findings." "$repo.control/reviewer-3.context" || fail "the closing round was not told about round 2"

# A medium-risk feature whose fixes touch a path of the high class is
# reclassified: the round after the fixes reviews the complete feature
# instead of the changes, and the commit records the level high.
scenario level-rises
repo="$(RISK_CONF="$(printf 'default: medium\nhigh: hot.txt')" setup_repo level-rises)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "hot\n" >hot.txt; reply="Fixed."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 1 1
if grep -Fq "Review of changes only" "$repo.control/reviewer.args"; then fail "the round after a rise of the level reviewed only the changes"; fi
grep -Fq "the risk level rose from medium (round 1) to high" <<<"$(log_of "$repo")" || fail "the rise of the level is not in the log of the feature"
grep -Fq "run-feature.sh: risk level before round 2: high" "$repo.out" || fail "the level was not computed again before round 2"
grep -Fqx "Risk: high" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the raised level"
grep -q "^Review: round 2, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not rest on the complete review of round 2"
# With 'medium: review: full' every round reviews the complete feature.
scenario medium-full-reviews
repo="$(RISK_CONF="$(printf 'default: medium\nmedium: review: full')" setup_repo medium-full-reviews)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 1 1
if grep -Fq "Review of changes only" "$repo.control/reviewer.args"; then fail "a round reviewed only the changes although the policy requires complete reviews"; fi
grep -Fq "the risk policy requires a complete review for a medium-risk feature (review: full)" <<<"$(log_of "$repo")" ||
  fail "the complete review by policy is not in the log of the feature"

# A low-risk feature in a project whose policy says 'low: review: none' is
# verified and committed without a review; the commit and the pull request
# say so, and the merge needs the owner, since no reviewer classified the
# impact. A failed verification is repaired like one a review would have
# run. Without that line, a low-risk feature is reviewed as any other.
scenario low-unreviewed
repo="$(RISK_CONF="$(printf 'default: medium\nlow: feature.txt\nlow: review: none')" setup_repo low-unreviewed)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 0 0 0
grep -Fq "verification of the low-risk feature, which the project policy does not review" "$repo.out" || fail "the verification of the unreviewed feature was not a step"
grep -Fqx "Review: not reviewed: Low risk by project policy (.agents/policies/risk.conf of the base: low: review: none)" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not say that the feature was not reviewed by project policy"
grep -Fqx "Review: not reviewed: Low risk by project policy (.agents/policies/risk.conf of the base: low: review: none)" "$repo.control/pr-body" ||
  fail "the pull request does not say that the feature was not reviewed by project policy"
grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "an unreviewed low-risk feature did not need the owner's approval"
grep -Fqx "Risk: low" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the low level"
[[ -f "$repo-2-thing/.agents/verification/passed" ]] || fail "the unreviewed feature was committed without a recorded verification"
# The trust contract: the run verifies the unreviewed feature itself, and
# the commit reuses that pass, which the run gave it in VERIFY_TRUSTED_TREES.
# A verification of an agent session counts for nothing.
grep -Fqx "origin: orchestrator" "$repo-2-thing/.agents/verification/passed" ||
  fail "the pass of the unreviewed feature was not made by the run: $(cat "$repo-2-thing/.agents/verification/passed")"
trust_events="$(cat "$repo"/.agents/run/records/*.jsonl | jq -c -s 'sort_by(.epoch) | map(select(.type == "verification" and .origin != "agent-session") | {reused, trusted, origin})')"
[[ "$trust_events" == '[{"reused":false,"trusted":true,"origin":"orchestrator"},{"reused":true,"trusted":true,"origin":"script"}]' ]] ||
  fail "the commit did not reuse the trusted pass of the run: $trust_events"
scenario low-unreviewed-repaired
repo="$(RISK_CONF="$(printf 'default: medium\nlow: feature.txt\nlow: review: none')" setup_repo low-unreviewed-repaired)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
else grep -q "FAIL  *sound" ".agents/handoffs/$RUN_ISSUE.md" && rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 0 0 0
grep -Fq "Repair attempt 1 of 3" <<<"$(log_of "$repo")" || fail "the verification of the unreviewed feature was not repaired"
grep -Fq "not reviewed: Low risk by project policy" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the repaired feature was not committed without a review"
# A repair that touches a medium path makes the feature medium: it is
# reviewed after all.
scenario low-rises
repo="$(RISK_CONF="$(printf 'default: medium\nlow: feature.txt\nlow: review: none')" setup_repo low-rises)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
else rm -f broken.txt; printf "helper\n" >helper.txt; reply="Repaired with a helper."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fqx "Risk: medium" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the raised level"
grep -q "^Review: round 1, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the feature that became medium was not reviewed"
scenario low-reviewed
repo="$(RISK_CONF="$(printf 'default: medium\nlow: feature.txt')" setup_repo low-reviewed)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -q "^Review: round 1, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "a low-risk feature was not reviewed without 'low: review: none'"
grep -Fqx "Risk: low" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not record the low level"

# The triage mode. With 'medium: triage: light' on the base, a round whose
# findings are all suggestions or minor and all deferred or accepted ends
# the loop without a fix session: the feature is committed on that complete
# review, the triage is published with its follow-up Issue, the agent was
# told the mode, the log says so, and the pull request names the mode. A
# FIX_NOW on a minor finding is still fixed and reviewed again; a major
# finding cannot be accepted; 'high: triage: light' is refused for a
# high-risk feature, which gets the full triage; and the shipped policy
# gives the full triage, with nothing told to the agent.
minor_and_suggestion='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"PASS_WITH_MINOR_FINDINGS\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"minor\", \"title\": \"Vague name\", \"evidence\": \"feature.txt:1\", \"impact\": \"Unclear.\", \"recommendation\": \"Rename.\"},
  {\"severity\": \"suggestion\", \"title\": \"Add a comment\", \"evidence\": \"feature.txt:1\", \"impact\": \"Readability.\", \"recommendation\": \"Comment.\"}
]}"'
defer_and_accept='reply="{\"decisions\": [
  {\"finding_id\": \"MIN1\", \"decision\": \"DEFER\", \"rationale\": \"Later.\", \"followup\": {\"title\": \"Rename it\", \"recommended_action\": \"Rename.\", \"acceptance_criteria\": [\"Renamed.\"]}},
  {\"finding_id\": \"S1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null}
]}"'
fix_minor='reply="{\"decisions\": [
  {\"finding_id\": \"MIN1\", \"decision\": \"FIX_NOW\", \"rationale\": \"Blocks the feature.\", \"followup\": null},
  {\"finding_id\": \"S1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null}
]}"'
light_policy="$(printf 'default: medium\nmedium: triage: light')"
scenario light-ends
repo="$(RISK_CONF="$light_policy" setup_repo light-ends)"
printf '%s\n' "$minor_and_suggestion" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$defer_and_accept" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 1 0
grep -q "^Review: round 1, PASS WITH MINOR FINDINGS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not rest on the round the light triage ended"
triage="$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json"
[[ "$(jq -r '.triage.mode' "$triage")" == "light" ]] || fail "the triage does not record the light mode"
grep -Fq "## Triage mode" "$repo.control/triage-1.context" || fail "the triage agent was not told the light mode"
grep -q '^issue create ' "$repo.control/gh.log" || fail "the deferred finding of a light triage got no follow-up Issue"
grep -q '^issue comment 2 ' "$repo.control/gh.log" || fail "the light triage was not published on the Issue"
grep -Fq "the light triage of the project policy ends the round without a fix session" <<<"$(log_of "$repo")" ||
  fail "the round the light triage ended is not in the log of the feature"
grep -Fq "Triage mode: light (" "$repo.control/pr-body" || fail "the pull request does not name the triage mode"
if grep -Fq "Triage mode" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)"; then fail "the commit message carries the triage mode"; fi
scenario light-fix-minor
repo="$(RISK_CONF="$light_policy" setup_repo light-fix-minor)"
printf '%s\n' "$minor_and_suggestion" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$fix_minor" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 1
grep -Fqx "fixed" "$repo-2-thing/feature.txt" || fail "the FIX_NOW minor finding was not fixed in the light mode"
grep -q "^Review: round 3, PASS" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the fixed minor finding was not reviewed again"
scenario light-major
repo="$(RISK_CONF="$light_policy" setup_repo light-major)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer.sh"
printf '%s\n' 'reply="{\"decisions\": [
  {\"finding_id\": \"M1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null},
  {\"finding_id\": \"MIN1\", \"decision\": \"ACCEPT\", \"rationale\": \"Fine.\", \"followup\": null}
]}"' >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the triage of round 1 failed"
if compgen -G "$repo-2-thing/.agents/triage/*.json" >/dev/null; then fail "a light triage that accepts a major finding was stored"; fi
scenario light-high-refused
repo="$(RISK_CONF="$(printf 'default: medium\nhigh: feature.txt\nhigh: triage: light')" setup_repo light-high-refused)"
printf '%s\n' "$minor_and_suggestion" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$defer_and_accept" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 1 0
grep -Fq "run-feature.sh: high: triage: light is refused" "$repo.out" || fail "the refused 'high: triage: light' was not reported"
grep -Fq "high: triage: light is refused" <<<"$(log_of "$repo")" || fail "the refused policy line is not in the log of the feature"
[[ "$(jq -r '.triage.mode' "$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json")" == "full" ]] ||
  fail "a high-risk feature got a light triage"
if grep -Fq "## Triage mode" "$repo.control/triage-1.context"; then fail "the triage agent was told the light mode for a high-risk feature"; fi
grep -Fq "Triage mode: full (high: triage: light is refused" "$repo.control/pr-body" || fail "the pull request does not name the refused mode"
scenario full-shipped
repo="$(setup_repo full-shipped)"
printf '%s\n' "$minor_and_suggestion" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$defer_and_accept" >"$repo.control/triage.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 1 0
[[ "$(jq -r '.triage.mode' "$repo-2-thing/.agents/triage/feature-2-thing-review-01-triage.json")" == "full" ]] ||
  fail "the shipped policy did not give the full triage"
if grep -Fq "## Triage mode" "$repo.control/triage-1.context"; then fail "the triage agent was told a mode under the shipped policy"; fi
if grep -Fq "light triage" <<<"$(log_of "$repo")"; then fail "the log names a light triage under the shipped policy"; fi
grep -Fq "Triage mode: full (" "$repo.control/pr-body" || fail "the pull request does not name the full triage"

# Workflow profiles. The same fake feature runs under no profile (the
# shipped policy), 'profile: standard', and 'profile: light'. A
# documentation-only feature is medium and reviewed without a profile and
# under standard; under light it is low and is committed without a reviewer
# (the review session is removed). A medium feature whose review has only a
# minor finding and a suggestion is triaged as the mode says: the fake
# triage agent fixes the minor finding unless it is told the light mode,
# so under light the fix session and the reviews after it are removed. What
# remains under every profile: the implementer, the full verification
# before the commit, the commit and pull request, and the merge approval
# gate. The profile is named in the output, the commit, the pull request,
# the run record, and the run report.
docs_only='mkdir -p docs .agents/summaries
printf "feature\n" >>docs/feature.md
printf -- "- Adds the feature page.\n" >".agents/summaries/$RUN_ISSUE.md"
completion complete
reply="The page is written."'
triage_by_mode='if grep -Fq "## Triage mode" "$RUN_CONTROL/triage-$count.context"; then '"$defer_and_accept"'; else '"$fix_minor"'; fi'
for profile in none standard light; do
  if [[ "$profile" == "none" ]]; then
    policy="$(shipped_policy)"
  else
    policy="$(printf 'profile: %s\ndefault: medium' "$profile")"
  fi
  scenario profile-docs
  repo="$(RISK_CONF="$policy" setup_repo "profile-$profile-docs")"
  printf '%s\n' "$docs_only" >"$repo.control/implementer.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  grep -Fq "  profile: $profile" "$repo.out" || fail "run-feature.sh does not name the profile $profile"
  grep -Fqx -- "- profile: $profile" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit does not name the profile $profile"
  grep -Fqx -- "- profile: $profile" "$repo.control/pr-body" || fail "the pull request does not name the profile $profile"
  jq -e -s --arg profile "$profile" 'map(select(.type == "risk")) | length > 0 and all(.profile == $profile)' \
    "$repo"/.agents/run/records/*.jsonl >/dev/null || fail "the run record does not name the profile $profile"
  grep -Fqx "| Workflow profile | $profile |" <<<"$(cd "$repo" && "$source_root/scripts/report-runs.sh" 2)" || fail "the run report does not show the profile $profile"
  if [[ "$profile" == "light" ]]; then
    expect_sessions "$repo" 1 0 0 0
    grep -Fqx "Risk: low" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "light did not make the documentation-only feature low"
    grep -Fq "Review: not reviewed: Low risk by project policy" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
      fail "the documentation-only feature under light was not committed without a review"
    grep -Fq "MERGE APPROVAL REQUIRED" "$repo.out" || fail "the unreviewed feature under light did not need the owner's approval"
  else
    expect_sessions "$repo" 1 1 0 0
    grep -Fqx "Risk: medium" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the documentation-only feature is not medium under $profile"
  fi
  [[ -f "$repo-2-thing/.agents/verification/passed" ]] || fail "the feature under $profile was committed without a recorded verification"

  scenario profile-medium
  repo="$(RISK_CONF="$policy" setup_repo "profile-$profile-medium")"
  printf '%s\n' "$minor_and_suggestion" >"$repo.control/reviewer-1.sh"
  printf '%s\n' "$triage_by_mode" >"$repo.control/triage.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  grep -Fqx "Risk: medium" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the code feature is not medium under $profile"
  if [[ "$profile" == "light" ]]; then
    expect_sessions "$repo" 1 1 1 0
    grep -Fq "Triage mode: light (the profile light of .agents/policies/risk.conf of the base gives 'medium: triage: light')" "$repo.control/pr-body" ||
      fail "the pull request does not say that the light triage comes from the profile"
  else
    expect_sessions "$repo" 1 3 1 1
    grep -Fq "Triage mode: full (" "$repo.control/pr-body" || fail "the pull request does not name the full triage under $profile"
  fi
done

# A pull request that cannot be opened stops the run after the commit; the
# next run only publishes.
scenario publish-fails
repo="$(setup_repo publish-fails)"
: >"$repo.control/pr-fails"
run_feature "$repo" 2 thing
[[ "$status" -eq 1 ]] || fail "a failed publication exited with $status"
grep -Fq "the pull request could not be opened" "$repo.out" || fail "the failed publication was not reported"
rm "$repo.control/pr-fails"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0

# --implemented continues a feature that you implemented in your own session,
# without a session of the implementer. Your word does not replace the
# completion gate: without the record the run stops and says what is missing.
scenario by-hand
repo="$(setup_repo by-hand)"
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
printf 'by hand\n' >"$repo-2-thing/feature.txt"
run_feature "$repo" 2 --implemented
expect_stopped "$repo" 1 "implemented was given, but the completion gate does not pass (missing)"
expect_sessions "$repo" 0 0 0 0
mkdir -p "$repo-2-thing/.agents/completion" "$repo-2-thing/.agents/summaries"
printf '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "The feature file exists", "status": "met", "evidence": "feature.txt"}], "remaining": []}\n' \
  >"$repo-2-thing/.agents/completion/2.json"
run_feature "$repo" 2 --implemented
expect_stopped "$repo" 1 "implemented was given, but the completion gate does not pass (no summary)"
printf -- '- Adds the feature file by hand.\n' >"$repo-2-thing/.agents/summaries/2.md"
run_feature "$repo" 2 --implemented
expect_published "$repo"
expect_sessions "$repo" 0 1 0 0
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "intervention" and (.what | test("--implemented")))' >/dev/null ||
  fail "--implemented is not recorded as an intervention"

# Without it, a worktree that no run completed is resumed by the implementer.
scenario resumed
repo="$(setup_repo resumed)"
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "You are resuming interrupted work" "$repo.control/implementer.args" || fail "the worktree was not resumed"

# Refusals, before anything starts.
scenario refused
repo="$(setup_repo refused)"
for arguments in "two" "2 thing main extra" "2 --merge" "2 --implemented" ""; do
  # shellcheck disable=SC2086
  run_feature "$repo" $arguments
  [[ "$status" -ne 0 ]] || fail "the arguments were accepted: '$arguments'"
done
expect_sessions "$repo" 0 0 0 0
if compgen -G "$repo-2-*" >/dev/null; then fail "a refused run created a worktree"; fi
git -C "$repo" worktree add -q -b feature/2-thing "$repo-2-thing" origin/main
run_feature "$repo" 2 other
[[ "$status" -ne 0 ]] || fail "a slug was accepted for a feature that already has a worktree"
expect_sessions "$repo" 0 0 0 0

# A budget check ('<name> [<group>] budget: <command>' in verify.conf) over
# its target is a measurement, never a repair order: the verification passes
# and no repair session starts. The result is in the summary of verify.sh and
# in the run record, and not in the handoff note, the reviewer's context, the
# commit message, or the pull request (Issue 503).
budget_conf=$'sound: test ! -e broken.txt\nperf budget: echo "1.4 s, target 1.0 s"; false'
scenario budget
repo="$(VERIFY_CONF="$budget_conf" setup_repo budget)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a repair was started for a budget over its target"; fi
if grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md"; then fail "a budget was recorded as a failed verification"; fi
grep -Eq '^BUDGET +perf' "$repo.out" &&
  grep -Fq "1.4 s, target 1.0 s" "$repo.out" ||
  fail "the summary of verify.sh lacks the budget: $(cat "$repo.out")"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "verification" and .status == 0
  and (.budgets | any(.name == "perf" and .status == "exceeded" and .output == "1.4 s, target 1.0 s")))' >/dev/null ||
  fail "the budget is not in the verification events of the run record"
if grep -Fqsi "budget" "$repo-2-thing/.agents/handoffs/2.md"; then fail "the handoff note repeats the budget: $(cat "$repo-2-thing/.agents/handoffs/2.md")"; fi
if grep -Fqi "budget" "$repo.control/reviewer-1.context"; then fail "the reviewer's context repeats the budget"; fi
if grep -Fqi "budget" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)"; then
  fail "the commit message repeats the budget: $(git -C "$repo-2-thing" log -1 --format=%B)"
fi
grep -Fqx -- "- ./scripts/verify.sh passed" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" || fail "the commit message lacks the passed verification"
if grep -Fqi "budget" "$repo.control/pr-body"; then fail "the pull request description repeats the budget: $(cat "$repo.control/pr-body")"; fi
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "a budget over its target kept the pull request from closing the Issue"

# A completion record that cites the budget check as evidence of a met
# criterion does not pass the gate: the implementer is resumed with the
# reason, like for any invalid record.
scenario budget-as-evidence
repo="$(VERIFY_CONF="$budget_conf" setup_repo budget-as-evidence)"
printf '%s\n' 'eval "$default"
printf "{\"schema\": \"completion/v1\", \"status\": \"complete\", \"criteria\": [{\"criterion\": \"The feature is fast\", \"status\": \"met\", \"evidence\": \"the perf check of verify.sh\"}], \"remaining\": []}\n" >".agents/completion/$RUN_ISSUE.json"' \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "cites the budget check 'perf' as evidence of a met criterion" <<<"$(log_of "$repo")" ||
  fail "the record that cites the budget check was not refused: $(log_of "$repo")"

# A target for the duration of the checks ('budget-seconds: <n>' in
# verify.conf) that a run exceeds is a budget result like that of a budget
# check: the verification passes, no repair session starts, and the
# measurement with the slowest checks is in the summary of verify.sh and the
# run record, and not in the handoff note, the reviewer's context, the commit
# message, or the pull request.
scenario duration-budget
repo="$(VERIFY_CONF=$'budget-seconds: 1\nsound: test ! -e broken.txt\nslow: sleep 1.2' setup_repo duration-budget)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a repair was started for a duration over its target"; fi
if grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md"; then fail "a duration over its target was recorded as a failed verification"; fi
grep -Eq '^BUDGET +duration of scripts/verify.conf' "$repo.out" ||
  fail "the summary of verify.sh lacks the duration: $(cat "$repo.out")"
cat "$repo"/.agents/run/records/*.jsonl | jq -e -s 'any(.type == "verification" and .status == 0
  and (.budgets | any(.name == "duration of scripts/verify.conf" and .status == "exceeded"))
  and (.checks | any(.name == "slow" and .seconds >= 1.2)))' >/dev/null ||
  fail "the duration is not in the verification events of the run record"
if grep -Fqsi "budget" "$repo-2-thing/.agents/handoffs/2.md"; then fail "the handoff note repeats the duration"; fi
if grep -Fqi "budget" "$repo.control/reviewer-1.context"; then fail "the reviewer's context repeats the duration"; fi
if grep -Fqi "budget" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)"; then fail "the commit message repeats the duration"; fi
if grep -Fqi "budget" "$repo.control/pr-body"; then fail "the pull request description repeats the duration"; fi

scenarios_done "${BASH_SOURCE[0]}"
