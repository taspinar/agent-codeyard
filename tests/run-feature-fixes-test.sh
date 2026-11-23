#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/run-feature.sh, part 3 of 4: the fix sessions, the
# findings they refute, and a base that changed between rounds. The fakes,
# the helpers, and the scenario register of all parts are in tests/lib-run-
# feature.sh; every case starts with 'scenario <id>'.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"
source "$source_root/tests/lib-run-feature.sh"

# A verification that fails after the fixes is repaired too, and a review
# confirms the result.
scenario fixes-break
repo="$(setup_repo fixes-break)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; else rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 3 1 1

# A repair of the verification after the fixes that fails once, after it
# changed the content, is tried again as a repair: start-feature.sh does not
# take the --continue of an interrupted fix session.
scenario fixes-break-repair-fails
repo="$(setup_repo fixes-break-repair-fails)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'case "$count" in
  1) eval "$default" ;;
  2) printf "half repaired\n" >>feature.txt; exit 9 ;;
  *) rm -f broken.txt; reply="Repaired." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 3 1 1
if grep -Fq -- "--continue" "$repo.out"; then fail "a retried repair was given --continue"; fi
grep -Eq "repair of the verification, attempt 1 of 3 \| temporary" <<<"$(log_of "$repo")" ||
  fail "the failed repair after the fixes is not in the log of the feature"

# A repair after the fixes that keeps failing stops the run, which names the
# script that failed, not apply-triage.sh: the fixed content fails the
# verification of the run before round 2.
scenario fixes-break-repair-exhausted
repo="$(setup_repo fixes-break-repair-exhausted)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; printf "x\n" >broken.txt; reply="Fixed."' >"$repo.control/fixes.sh"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; else printf "tried\n" >>feature.txt; exit 9; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the repair of the verification before round 2 failed (start-feature.sh exited with status 9, also after the retries)"
if grep -Fq -- "--continue" "$repo.out"; then fail "an exhausted repair was given --continue"; fi

# A fixing agent that changed a file and then failed is continued with the
# same triage and scope: apply-triage.sh would refuse a new session, because
# the content changed since the review. No other agent takes over.
scenario fixes-interrupted
repo="$(setup_repo fixes-interrupted)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "half fixed\n" >>feature.txt; exit 9' >"$repo.control/fixes-1.sh"
printf '%s\n' 'printf "fixed\n" >>feature.txt; reply="Finished the fixes."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 2
grep -Fq "Continuing the interrupted session with the same scope" <<<"$(log_of "$repo")" ||
  fail "the interrupted fix session is not in the log of the feature"
[[ "$(grep -c "Wrong content" "$repo.control/fixes.args")" -eq 2 ]] ||
  fail "the continued session was not given the FIX_NOW finding of the triage"
[[ "$(grep -c "You are continuing a fix session that was interrupted" "$repo.control/fixes.args")" -eq 1 ]] ||
  fail "only the continued session should be told that it continues"
if grep -Fq "Vague name" "$repo.control/fixes.args"; then fail "a deferred finding was given to the fixing agent"; fi
[[ ! -e "$repo-2-thing/.agents/run/2-fixes-started" ]] || fail "the mark of the unfinished session was kept after it finished"

# An agent that changes the review it works from, validly, is not tried
# again and not continued: the changed review must not become the baseline
# of a next session.
scenario fixes-tamper
repo="$(setup_repo fixes-tamper)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'printf "half fixed\n" >>feature.txt
r=.agents/reviews/feature-2-thing-review-01.json
jq ".findings[0].recommendation = \"Nothing to do.\"" "$r" >"$r.tmp" && mv "$r.tmp" "$r"
reply="Done."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "changed the review or the approved triage"
expect_sessions "$repo" 1 1 1 1
[[ ! -e "$repo-2-thing/.agents/run/2-fixes-started" ]] || fail "the mark of a rejected session was kept"
grep -Fq "nothing is tried again" <<<"$(log_of "$repo")" || fail "the rejected session is not in the log of the feature"

# A fixing agent that failed before it changed anything is started again.
for code in 4 5; do
  scenario fixes-fail-once
  repo="$(setup_repo "fixes-fail-once-$code")"
  printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
  printf '%s\n' "exit $code" >"$repo.control/fixes-1.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 1 3 1 2
done

# A fixing agent that needs a decision stops the run with status 3, and one
# that changes nothing stops it too, instead of reviewing the same content.
scenario fixes-blocked
repo="$(setup_repo fixes-blocked)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "question='which format?'; $ask; reply=\"BLOCKED: which format?\"" >"$repo.control/fixes-1.sh"
# The implementer continues only with the answer from the handoff note.
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"
elif grep -q "Answer: JSON" ".agents/handoffs/$RUN_ISSUE.md" 2>/dev/null && [[ "$*" == *"handoff note: .agents/handoffs/"* ]]; then
  printf "answered\n" >>feature.txt; reply="Continued with the answer."
else reply="BLOCKED: no answer"; fi' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the agent that applies the fixes needs a decision of yours"
# The answer is given: the next run hands it to the implementer, which
# resumes, and round 2 confirms the result.
printf '**Open questions:** none.\n\nWhich format?\nAnswer: JSON\n' >"$repo-2-thing/.agents/handoffs/2.md"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 3 1 1
grep -Fqx "answered" "$repo-2-thing/feature.txt" || fail "the answer in the handoff note did not reach an agent"

scenario fixes-nothing
repo="$(setup_repo fixes-nothing)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' 'reply="Nothing to do."' >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the fixes for round 1 changed nothing"
expect_sessions "$repo" 1 1 1 1

# refuted <id> <value>: a fixing agent that changes no code and records its
# check of a finding under the heading of the triage, with its evidence.
refuted() {
  printf '%s\n' 't="$(ls .agents/triage/*.json | tail -1)"; mkdir -p .agents/handoffs
printf "\n## Triage %s\n\n- '"$1"': '"$2"' — \`grep -c feature feature.txt\` prints 1: the content is right\n" "$(basename "$t")" >>".agents/handoffs/$RUN_ISSUE.md"
reply="'"$1"' is '"$2"'."'
}
# A reviewer that reports M1 of the round before again, as unresolved, with
# its title and the mark that it is unresolved.
unresolved='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Wrong content, unresolved\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\", \"previous\": {\"round\": $((count - 1)), \"id\": \"M1\", \"relation\": \"unresolved\", \"reason\": null}}
]}"'

# A major finding that the implementer refuted with evidence, changing no
# code, and that the reviewer, given the refutation, still reports: no agent
# may accept it, so the run stops for the owner with status 3, on a review of
# the complete feature, and names the finding, the evidence, and the ways on.
# The owner's exception to it lets the next run finish the feature.
scenario fixes-refuted
repo="$(setup_repo fixes-refuted)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$unresolved" >"$repo.control/reviewer.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
refuted M1 refuted >"$repo.control/fixes.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer refuted every finding left to fix in round 3 with evidence"
expect_sessions "$repo" 1 3 3 1
grep -Fq "review of the complete feature, round 3" "$repo.out" || fail "the owner's decision is not asked on a review of the complete feature"
grep -Fq -- "- M1 (major): Wrong content, unresolved — refuted in round 1 (M1): \`grep -c feature feature.txt\` prints 1: the content is right" "$repo.out" ||
  fail "the stop does not name the refuted finding and its evidence"
grep -Fq "./scripts/record-exception.sh .agents/reviews/feature-2-thing-review-03.json --finding M1 --type not-applicable" "$repo.out" ||
  fail "the stop does not give the owner's exception"
grep -Fq "./scripts/start-feature.sh 2 --resume    # or the fix after all" "$repo.out" || fail "the stop does not give the fix after all"
grep -Fq "| triage of round 3 | refuted | " <<<"$(log_of "$repo")" || fail "the refuted finding is not in the log of the feature"
# The stop leaves the review current, so that an exception can bind to it.
(cd "$repo-2-thing" && ./scripts/check-review.sh .agents/reviews/feature-2-thing-review-03.json >/dev/null) ||
  fail "the stop made the review it asks about stale"
# Without the owner's decision, the next run stops in the same way, without
# another agent.
run_feature "$repo" 2
expect_stopped "$repo" 3 "the implementer refuted every finding left to fix in round 3"
expect_sessions "$repo" 1 3 3 1
(
  cd "$repo-2-thing"
  command="PATH=$(printf '%q' "$tmp/bin:/usr/bin:/bin") RUN_CONTROL=$(printf '%q' "$repo.control") ./scripts/record-exception.sh .agents/reviews/feature-2-thing-review-03.json --finding M1 --type not-applicable --evidence .agents/handoffs/2.md --reason 'The content is right.'"
  if grep -q util-linux <<<"$(script --version 2>/dev/null)"; then
    printf 'y\n' | script -qec "$command" /dev/null
  else
    printf 'y\n' | script -q /dev/null sh -c "$command"
  fi
) >"$repo.exception" 2>&1 || {
  cat "$repo.exception" >&2
  fail "the owner's exception to the refuted finding was not recorded"
}
jq -s . "$repo.control/issue-comments.jsonl" >"$repo.control/issue-comments.json"
MOCK_ISSUE_COMMENTS="$repo.control/issue-comments.json" run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 3 3 1
grep -Fq "blocking findings open with the owner's exception: M1" <<<"$(git -C "$repo-2-thing" log -1 --format=%B)" ||
  fail "the commit does not record the owner's exception to the refuted finding"

# A round with a fixed and a refuted finding goes on with the fixed one; the
# refuted major finding that remains stops the run.
two_majors='reply="{\"architecture_impact\": {\"level\": \"minor\", \"rationale\": \"Stays within the accepted architecture.\", \"checked_against\": []}, \"verdict\": \"CHANGES_REQUIRED\", \"limitations\": \"\", \"findings\": [
  {\"severity\": \"major\", \"title\": \"Wrong content\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Fix.\"},
  {\"severity\": \"major\", \"title\": \"Missing line\", \"evidence\": \"feature.txt:1\", \"impact\": \"Bug.\", \"recommendation\": \"Add.\"}
]}"'
scenario fixes-mixed
repo="$(setup_repo fixes-mixed)"
printf '%s\n' "$two_majors" >"$repo.control/reviewer-1.sh"
printf '%s\n' "$unresolved" >"$repo.control/reviewer.sh"
printf '%s\n' 'reply="{\"decisions\": [{\"finding_id\": \"M1\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is wrong.\", \"followup\": null}, {\"finding_id\": \"M2\", \"decision\": \"FIX_NOW\", \"rationale\": \"It is missing.\", \"followup\": null}]}"' >"$repo.control/triage-1.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
{
  printf '%s\n' 'printf "line\n" >>feature.txt'
  refuted M1 refuted
  printf '%s\n' 'printf -- "- M2: fixed — feature.txt has the line\n" >>".agents/handoffs/$RUN_ISSUE.md"'
} >"$repo.control/fixes-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer refuted every finding left to fix in round 3"
expect_sessions "$repo" 1 3 3 1
grep -Fq -- "- M1 (major): Wrong content, unresolved — refuted in round 1 (M1): " "$repo.out" || fail "the remaining refuted finding is not named"
if grep -Fq "M2 (major)" "$repo.out"; then fail "the fixed finding is named as refuted"; fi

# A finding is continued by its ID and its title, apart from the mark that it
# is unresolved: one that names an earlier refuted finding as its
# predecessor but has another title is a new finding,
# which is fixed like any other, and the refutation of the earlier one does
# not stop the run for the owner (#432: a new M1 of round 3 was taken for the
# refuted M1 of round 1).
scenario fixes-refuted-other-title
repo="$(setup_repo fixes-refuted-other-title)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "${unresolved/Wrong content/Another defect}" >"$repo.control/reviewer-2.sh"
printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
refuted M1 refuted >"$repo.control/fixes-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 4 2 2
if grep -Fq "refuted every finding" "$repo.out"; then fail "a finding with another title was taken for the refuted one"; fi
grep -Fqx "fixed" "$repo-2-thing/feature.txt" || fail "the new finding of round 2 was not fixed"

# A finding that was not reproduced, or that cannot be run here, proves
# nothing either way: the next round fixes it as before, without the owner.
for value in not_reproduced not_executable; do
  scenario fixes-inconclusive
  repo="$(setup_repo "fixes-$value")"
  printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
  printf '%s\n' "$unresolved" >"$repo.control/reviewer-2.sh"
  printf '%s\n' "$fix_major" >"$repo.control/triage.sh"
  refuted M1 "$value" >"$repo.control/fixes-1.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 1 4 2 2
  if grep -Fq "refuted every finding" "$repo.out"; then fail "a $value finding stopped the run for the owner"; fi
done

# When the base of the branch changed between two rounds, the next round
# reviews the complete feature instead of being refused.
scenario base-changed
repo="$(setup_repo base-changed)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
printf '%s\n' "question='wait for main?'; $ask; reply=\"BLOCKED: wait\"" >"$repo.control/fixes-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "needs a decision of yours"
printf 'other work\n' >"$repo/other.txt"
git -C "$repo" add other.txt
git -C "$repo" commit -qm "Other work on main"
git -C "$repo" push -q origin main
git -C "$repo-2-thing" stash -q --include-untracked
git -C "$repo-2-thing" merge -q origin/main >/dev/null
git -C "$repo-2-thing" stash pop -q >/dev/null
git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD && [[ -f "$repo-2-thing/other.txt" ]] ||
  fail "the test did not merge main into the feature"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 2 2 1 1
if grep -Fq "Review of changes only" "$repo.control/reviewer.args"; then
  fail "a round after a changed base reviewed only the changes"
fi

scenarios_done "${BASH_SOURCE[0]}"
