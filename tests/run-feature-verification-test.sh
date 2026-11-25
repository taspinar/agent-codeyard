#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/run-feature.sh, part 2 of 4: the retries of a
# session, the run's own verification, its repairs, a base that moved on,
# and the artifacts that a session must not change. The fakes, the helpers,
# and the scenario register of all parts are in tests/lib-run-feature.sh;
# every case starts with 'scenario <id>'.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"
source "$source_root/tests/lib-run-feature.sh"

# Reading the Issue fails on the connection before a worktree exists, more
# often than start-feature.sh tries: the run tries the start again, and goes
# on.
scenario issue-flaky
repo="$(setup_repo issue-flaky)"
printf '4\n' >"$repo.control/gh-title-flaky"
run_feature "$repo" 2
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "issue-flaky: the run failed with status $status"; }
git -C "$repo" ls-remote --exit-code --heads origin feature/2-feature-file >/dev/null 2>&1 ||
  fail "issue-flaky: the feature was not published"
grep -Fq "start-feature.sh could not read the Issue (status 75)" "$repo.out" || fail "the retried start is not reported"

# A session that fails once, for example on a usage limit, is tried again by
# the run itself: the implementer is resumed, a reviewer is started again.
scenario implementer-fails-once
repo="$(setup_repo implementer-fails-once)"
printf '%s\n' 'exit 9' >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| temporary |" <<<"$(log_of "$repo")" || fail "the failed session is not in the log of the feature"

scenario reviewer-fails-once
repo="$(setup_repo reviewer-fails-once)"
printf '%s\n' 'exit 9' >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 0 0
grep -Eq "\| temporary \| the step exited with status [0-9]+ \| Retry 1 of 3" <<<"$(log_of "$repo")" ||
  fail "the retry of the review is not in the log of the feature"

# The full verification is the run's own, after the session and before the
# review (lib/verification.sh): the sessions are told to run only the checks
# of what they changed, and the review, a retry of it, the fixes, and the
# commit reuse that pass. One full run of the checks per distinct content.
scenario one-verification
repo="$(setup_repo one-verification)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
[[ "$(full_verifications "$repo")" -eq 1 ]] ||
  fail "a run without findings made $(full_verifications "$repo") full verifications instead of one"
steps="$(cat "$repo"/.agents/run/records/*.jsonl | jq -r -s 'sort_by(.epoch) | map(select(.type == "step") | .name) | join(" | ")')"
[[ "$steps" == *"implementation | verification before round 1 | review, round 1 of at most 5 | "* ]] ||
  fail "the run did not verify after the session and before the review: $steps"
trust_events="$(cat "$repo"/.agents/run/records/*.jsonl | jq -c -s 'sort_by(.epoch) | map(select(.type == "verification" and .origin != "agent-session") | [.reused, .trusted, .origin])')"
[[ "$trust_events" == '[[false,true,"orchestrator"],[true,true,"script"],[true,true,"script"]]' ]] ||
  fail "the review and the commit did not reuse the pass of the run: $trust_events"
grep -Fq "Do not run the full ./scripts/verify.sh in this session" "$repo.control/implementer.args" ||
  fail "the unattended implementer was not told to leave the full verification"
grep -Fq "./scripts/verify.sh --changed after your last change" "$repo.control/implementer.args" ||
  fail "the unattended implementer was not told what to run instead"

# A review step that fails on a usage limit and is tried again verifies
# nothing again: the retry reuses the pass of the run.
scenario review-usage-limit
repo="$(setup_repo review-usage-limit)"
printf '%s\n' 'echo "Error: 429 Too Many Requests: rate limit exceeded" >&2; exit 1' >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 2 0 0
grep -Fq "a usage limit of claude, reported by the agent" <<<"$(log_of "$repo")" ||
  fail "the usage limit of the reviewer is not in the log of the feature: $(log_of "$repo" | grep temporary)"
[[ "$(full_verifications "$repo")" -eq 1 ]] ||
  fail "the retried review made $(full_verifications "$repo") full verifications instead of one"

# A full verification that fails after the session goes to the implementer
# as a repair session, as one a review found; the review follows the repair.
scenario verification-after-session
repo="$(setup_repo verification-after-session)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
else grep -q "FAIL  *sound" ".agents/handoffs/$RUN_ISSUE.md" && rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "| verification before round 1 | failed | checks failed in two verification runs: sound (the repeat ran only the failed checks) | Repair attempt 1 of 3 by the implementer" <<<"$(log_of "$repo")" ||
  fail "the failed verification after the session was not repaired: $(log_of "$repo")"
[[ "$(jq -r '.verification.status' "$repo-2-thing/.agents/reviews/feature-2-thing-review-01.json")" == "passed" ]] ||
  fail "the review after the repair was not made on a passed verification"

# A round with fixes: the fix session is not verified by apply-triage.sh
# (--caller-verifies); the run verifies the fixed content once before the
# next round, and the review of the changes and the closing review of the
# complete feature, both on that content, reuse it: each of the two
# contents is verified once.
scenario verification-per-tree
repo="$(setup_repo verification-per-tree)"
printf '%s\n' "$major_and_minor" >"$repo.control/reviewer-1.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 3 1 1
grep -Fq "the caller verifies the result (--caller-verifies)" "$repo.out" ||
  fail "the fixes were not left to the run to verify"
[[ "$(full_verifications "$repo")" -eq 2 ]] ||
  fail "a run with one round of fixes made $(full_verifications "$repo") full verifications instead of two"

# The retries are bounded: a session that keeps failing stops the run, and
# the next run starts where it stopped.
scenario implementer-keeps-failing
repo="$(setup_repo implementer-keeps-failing)"
printf '%s\n' 'exit 9' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementation failed"
expect_sessions "$repo" 5 0 0 0

scenario reviewer-keeps-failing
repo="$(setup_repo reviewer-keeps-failing)"
printf '%s\n' 'exit 9' >"$repo.control/reviewer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the review did not complete"
expect_sessions "$repo" 1 4 0 0
grep -Fq "also after 3 retries" <<<"$(log_of "$repo")" || fail "the exhausted retries are not in the log of the feature"
rm "$repo.control/reviewer.sh"
run_feature "$repo" 2
expect_published "$repo"
expect_sessions "$repo" 1 5 0 0

# A verification that fails once and passes when it is repeated is an
# unstable check: the run records it and goes on.
scenario unstable
repo="$(VERIFY_CONF="unstable: sh -c 'test -e .agents/run/seen || { mkdir -p .agents/run; touch .agents/run/seen; false; }'" setup_repo unstable)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks, failed in one of two verification runs: unstable" <<<"$(log_of "$repo")" ||
  fail "the unstable check is not named in the log of the feature"

# The repeat runs only the check that failed: the check that passed does not
# run again, the two runs together are the pass of the content, and the step
# done again reuses that pass instead of verifying again.
scenario repeat-failed-only
repo="$(VERIFY_CONF="steady: true
unstable: sh -c 'test -e .agents/run/seen || { mkdir -p .agents/run; touch .agents/run/seen; false; }'" setup_repo repeat-failed-only)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks, failed in one of two verification runs: unstable (the repeat ran only the failed checks)" <<<"$(log_of "$repo")" ||
  fail "the repeat of only the failed check is not in the log of the feature: $(log_of "$repo")"
if grep -Fq -- "-- steady" "$repo-2-thing/.agents/run/2-verify.log"; then fail "the repeat ran a check that had passed: $(cat "$repo-2-thing/.agents/run/2-verify.log")"; fi
grep -Fq -- "-- unstable" "$repo-2-thing/.agents/run/2-verify.log" || fail "the repeat did not run the failed check"
[[ "$(grep -c -- '^-- steady took' "$repo.out")" -eq 1 ]] ||
  fail "the check that passed ran again after the repeat: $(grep -c -- '^-- steady took' "$repo.out") runs"

# Two failed checks are repeated together, without the check that passed:
# the list of failed checks given to --repeat names both.
scenario repeat-two-failed
repo="$(VERIFY_CONF="steady: true
unstable-a: sh -c 'test -e .agents/run/seen-a || { mkdir -p .agents/run; touch .agents/run/seen-a; false; }'
unstable-b: sh -c 'test -e .agents/run/seen-b || { mkdir -p .agents/run; touch .agents/run/seen-b; false; }'" setup_repo repeat-two-failed)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks, failed in one of two verification runs: unstable-a unstable-b (the repeat ran only the failed checks)" <<<"$(log_of "$repo")" ||
  fail "the repeat of only the two failed checks is not in the log of the feature: $(log_of "$repo")"
if grep -Fq -- "-- steady" "$repo-2-thing/.agents/run/2-verify.log"; then fail "the repeat of two failed checks ran a check that had passed: $(cat "$repo-2-thing/.agents/run/2-verify.log")"; fi
grep -Fq -- "-- unstable-a" "$repo-2-thing/.agents/run/2-verify.log" || fail "the repeat did not run the first failed check"
grep -Fq -- "-- unstable-b" "$repo-2-thing/.agents/run/2-verify.log" || fail "the repeat did not run the second failed check"
[[ "$(grep -c -- '^-- steady took' "$repo.out")" -eq 1 ]] ||
  fail "the check that passed ran again after the repeat of two failed checks: $(grep -c -- '^-- steady took' "$repo.out") runs"

# Two checks that fail in turn, each in one run only, are unstable too: no
# check failed twice, so nothing is repaired.
alternating="first: sh -c 'n=\$(cat .agents/run/n 2>/dev/null || echo 0); mkdir -p .agents/run; echo \$((n + 1)) >.agents/run/n; test \$n -ne 0'
second: sh -c 'test \$(cat .agents/run/n) -ne 2'"
scenario alternating
repo="$(VERIFY_CONF="$alternating" setup_repo alternating)"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "unstable checks" <<<"$(log_of "$repo")" || fail "checks that failed in turn were not recorded as unstable"
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a repair was started although no check failed twice"; fi

# A verification that finds the slot for heavy verification of the machine
# held by another run is no defect: nothing is repaired, and the run stops
# with status 75. The slot is held by this test shell.
slot="$tmp/slot"
mkdir -p "$slot/lock"
printf 'token=other\npid=%s\nstarted=%s\nworktree=/elsewhere\nrun=other-run\nsince=now\n' \
  "$$" "$(LC_ALL=C ps -o lstart= -p $$ | sed 's/^ *//; s/ *$//')" >"$slot/lock/owner"
scenario busy
repo="$(VERIFY_CONF="heavy: sound
sound: test ! -e broken.txt" setup_repo busy)"
VERIFY_LOCK_DIR="$slot" run_feature "$repo" 2 thing
expect_stopped "$repo" 75 "the slot for heavy verification of this machine is held by another run"
expect_sessions "$repo" 1 0 0 0
grep -Fq "| busy | the slot for heavy verification of this machine is held by run other-run, PID $$, worktree /elsewhere" <<<"$(log_of "$repo")" ||
  fail "the busy slot and its holder are not in the log of the feature"
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a busy slot was sent to the implementer for repair"; fi
if grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md" 2>/dev/null; then fail "a busy slot was recorded as a failed verification"; fi
rm -rf "$slot"

# A verification that finds a prerequisite of the machine missing (status 78
# of verify.sh, its ENVIRONMENT line) is no defect: the run stops with status
# 78 at once, without a repeat, a retry, or a repair session.
scenario environment
: >"$tmp/environment.missing"
repo="$(ENVIRONMENT_CONTROL="$tmp/environment.missing" setup_repo environment)"
run_feature "$repo" 2 thing
expect_stopped "$repo" 78 "a prerequisite of this machine is missing, which says nothing about this feature: faked-tool for this test — install faked-tool"
expect_sessions "$repo" 1 0 0 0
grep -Fq "| environment | faked-tool for this test — install faked-tool |" <<<"$(log_of "$repo")" ||
  fail "the missing prerequisite is not in the log of the feature: $(log_of "$repo")"
[[ "$(grep -c '^ENVIRONMENT  ' "$repo.out")" -eq 1 ]] || fail "the verification was repeated or retried after the environment status: $(cat "$repo.out")"
if grep -Eq "Repair attempt|unstable|Retry [0-9]" <<<"$(log_of "$repo")"; then fail "a missing prerequisite was retried, repaired, or counted as unstable"; fi
if grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md" 2>/dev/null; then fail "a missing prerequisite was recorded as a failed verification"; fi

# The same when the prerequisite goes missing between the verification that
# failed on the code and its repeat: the repeat's status 78 stops the run,
# and nothing is repaired.
scenario environment-repeat
repo="$(ENVIRONMENT_CONTROL="$tmp/environment-repeat.missing" \
  VERIFY_CONF="sound: sh -c 'touch \"$tmp/environment-repeat.missing\"; false'" setup_repo environment-repeat)"
run_feature "$repo" 2 thing
expect_stopped "$repo" 78 "a prerequisite of this machine is missing"
expect_sessions "$repo" 1 0 0 0
grep -Fq "| environment | faked-tool for this test — install faked-tool |" <<<"$(log_of "$repo")" ||
  fail "the missing prerequisite of the repeat is not in the log of the feature: $(log_of "$repo")"
if grep -Eq "Repair attempt|unstable" <<<"$(log_of "$repo")"; then fail "a missing prerequisite in the repeat was repaired or counted as unstable"; fi

# A verification that fails twice is repaired by the implementer, which is
# given the failing checks in the handoff note.
scenario repaired
repo="$(setup_repo repaired)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
else grep -q "FAIL  *sound" ".agents/handoffs/$RUN_ISSUE.md" && rm -f broken.txt; reply="Repaired."; fi' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 2 1 0 0
grep -Fq "Repair attempt 1 of 3" <<<"$(log_of "$repo")" || fail "the repair is not in the log of the feature"
grep -Fq "## Verification failed" "$repo-2-thing/.agents/handoffs/2.md" || fail "the failing checks were not recorded for the implementer"

# A verification that fails because of the base, which moved on since the
# feature started, is not sent to the implementer: the run merges the base,
# says so, and verifies again. Here another merge on the base, made while the
# implementer worked, adds the file that the check needs.
base_fix='sound: test ! -e broken.txt || test -e base-fix.txt'
# move_base_script <repo> <label> <command> <base-command>: the first session
# of the implementer runs <command> after its work, and moves the base on the
# remote with <base-command>, from a clone of its own, as another merged pull
# request would.
move_base_script() {
  printf '%s\n' "eval \"\$default\"; printf \"x\\n\" >broken.txt
$3
git clone -q \"$tmp/$2-remote.git\" \"$tmp/$2-other\"
(cd \"$tmp/$2-other\" && $4 && git add -A && git -c user.name=Other -c user.email=other@example.com commit -qm \"Meanwhile on main\" && git push -q origin main)" \
    >"$1.control/implementer-1.sh"
}
scenario base-repairs
repo="$(VERIFY_CONF="$base_fix" setup_repo base-repairs)"
move_base_script "$repo" base-repairs ":" 'printf "fixed\n" >base-fix.txt'
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "| base merged | checks failed in two verification runs, and the base moved since the feature started: origin/main merged cleanly" <<<"$(log_of "$repo")" ||
  fail "the merge of the base is not in the log of the feature"
grep -Fq "run-feature.sh: base merged in " "$repo.out" || fail "the merge of the base was not reported"
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a failure that the base repairs was sent to the implementer"; fi
git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD || fail "the base was not merged into the feature"
[[ -f "$repo-2-thing/base-fix.txt" ]] || fail "the change of the base is not in the feature"

# A base whose merge meets the uncommitted work of the feature stops the run,
# with the conflicting file and the commands that continue; nothing is
# merged or repaired.
scenario base-conflicts
repo="$(VERIFY_CONF="$base_fix" setup_repo base-conflicts)"
move_base_script "$repo" base-conflicts 'printf "# Mine\n" >>AGENTS.md' 'printf "fixed\n" >base-fix.txt && printf "# Theirs\n" >>AGENTS.md'
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "merging origin/main conflicts with the feature in: AGENTS.md"
expect_sessions "$repo" 1 0 0 0
grep -Fq "git merge origin/main    # resolve the conflicts, then commit the merge" "$repo.out" || fail "the command that continues the merge was not given"
grep -Fq "| conflict | the base moved since the feature started, and its merge conflicts in: AGENTS.md" <<<"$(log_of "$repo")" ||
  fail "the conflict is not in the log of the feature"
if git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD; then fail "a conflicting base was merged"; fi
grep -Fqx "# Mine" "$repo-2-thing/AGENTS.md" || fail "the uncommitted work of the feature was changed"
if grep -Fq "Repair attempt" <<<"$(log_of "$repo")"; then fail "a conflicting base was sent to the implementer"; fi

# A base that adds a path that exists in the worktree as a file Git ignores
# counts as a conflict: the merge, which would replace the local file without
# a word also with --no-overwrite-ignore, is not made, and the path is named.
scenario base-ignored
repo="$(VERIFY_CONF="$base_fix" setup_repo base-ignored)"
move_base_script "$repo" base-ignored 'mkdir -p .agents/analysis && printf "local\n" >.agents/analysis/cache.txt' \
  'printf "fixed\n" >base-fix.txt && mkdir -p .agents/analysis && printf "base\n" >.agents/analysis/cache.txt && git add -f .agents/analysis/cache.txt'
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "merging origin/main would write over untracked files of the worktree, which Git may ignore: .agents/analysis/cache.txt"
expect_sessions "$repo" 1 0 0 0
grep -Fqx "local" "$repo-2-thing/.agents/analysis/cache.txt" || fail "the ignored local file was changed"
if git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD; then fail "a base that writes over an ignored file was merged"; fi
if grep -Fq "| base merged |" <<<"$(log_of "$repo")"; then fail "a clean merge was reported before the stop"; fi

# Staged changes stop the run before the merge, with the paths named and the
# index unchanged: a staged version that differs from the file on disk is
# not lost.
scenario base-staged
repo="$(VERIFY_CONF="$base_fix" setup_repo base-staged)"
move_base_script "$repo" base-staged 'printf "staged\n" >notes.txt && git add notes.txt && printf "on disk\n" >notes.txt' \
  'printf "fixed\n" >base-fix.txt'
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the index holds staged changes, which a merge of origin/main refuses, in: notes.txt"
expect_sessions "$repo" 1 0 0 0
[[ "$(git -C "$repo-2-thing" show :notes.txt)" == "staged" ]] || fail "the staged version was lost"
grep -Fqx "on disk" "$repo-2-thing/notes.txt" || fail "the file on disk was changed"
[[ "$(git -C "$repo-2-thing" diff --cached --name-only)" == "notes.txt" ]] || fail "the index was changed: $(git -C "$repo-2-thing" diff --cached --name-only)"
if git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD; then fail "the base was merged over staged changes"; fi

# The same when the base changes the staged path too: the stop on staged
# changes comes before the conflict pre-check, whose commands would stash
# the index.
scenario base-staged-overlap
repo="$(VERIFY_CONF="$base_fix" setup_repo base-staged-overlap)"
move_base_script "$repo" base-staged-overlap 'printf "staged\n" >notes.txt && git add notes.txt && printf "on disk\n" >notes.txt' \
  'printf "fixed\n" >base-fix.txt && printf "base\n" >notes.txt'
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the index holds staged changes, which a merge of origin/main refuses, in: notes.txt"
expect_sessions "$repo" 1 0 0 0
if grep -Fq "git stash push" "$repo.out"; then fail "the stop on staged changes gave the commands of a conflict"; fi
[[ "$(git -C "$repo-2-thing" show :notes.txt)" == "staged" ]] || fail "the staged version was lost"
grep -Fqx "on disk" "$repo-2-thing/notes.txt" || fail "the file on disk was changed"
[[ "$(git -C "$repo-2-thing" diff --cached --name-only)" == "notes.txt" ]] || fail "the index was changed: $(git -C "$repo-2-thing" diff --cached --name-only)"
if git -C "$repo-2-thing" merge-base --is-ancestor origin/main HEAD; then fail "the base was merged over staged changes"; fi

# A session that repairs the verification is a session of the implementer
# too: when it repairs the check but leaves the work partial, the gate is
# asked again before the review, and the implementer continues.
scenario repair-leaves-partial
repo="$(setup_repo repair-leaves-partial)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt; completion partial "The documentation"; reply="Repaired; the documentation is left." ;;
  *) eval "$default"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "Repair attempt 1 of 3" <<<"$(log_of "$repo")" || fail "the repair is not in the log of the feature"
grep -Fq "| not complete | partial: " <<<"$(log_of "$repo")" || fail "the repair session that left work is not in the log of the feature"
grep -Fqx "Closes #2" "$repo.control/pr-body" || fail "the feature completed after the repair does not close the Issue"
# The repair session counts in the gate history: the check after it names
# it, with one session more than the check before it.
gates="$(cat "$repo"/.agents/run/records/*.jsonl | jq -c -s '[.[] | select(.type == "completion-gate") | {sessions, session, status}]')"
jq -e 'map(select(.status == "partial")) | length == 1' <<<"$gates" >/dev/null || fail "the check after the repair is not the partial one: $gates"
jq -e '(map(.status) | index("partial")) as $i | $i > 0 and .[$i].sessions == .[$i - 1].sessions + 1 and .[$i].session != .[$i - 1].session' <<<"$gates" >/dev/null ||
  fail "the repair session does not count in the gate history: $gates"

# The same for a repair session that removes the record, or that leaves
# remaining work in the handoff note.
scenario repair-removes-record
repo="$(setup_repo repair-removes-record)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt ".agents/completion/$RUN_ISSUE.json"; reply="Repaired." ;;
  *) eval "$default"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "| not complete | missing: " <<<"$(log_of "$repo")" || fail "the repair session without a record is not in the log of the feature"

scenario repair-leaves-note
repo="$(setup_repo repair-leaves-note)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  2) rm -f broken.txt; printf "**Remaining:** the documentation\n" >".agents/handoffs/$RUN_ISSUE.md"; reply="Repaired." ;;
  *) eval "$default"; printf "Issue %s is complete.\n" "$RUN_ISSUE" >".agents/handoffs/$RUN_ISSUE.md"; reply="Finished." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Fq "the completion record says complete, but the handoff note" <<<"$(log_of "$repo")" ||
  fail "the repair session that left remaining work in the note is not in the log of the feature"

# A repair session that records blocked stops the run for the human, with
# status 3, also without a BLOCKED line: nothing is reviewed.
scenario repair-blocked
repo="$(setup_repo repair-blocked)"
printf '%s\n' 'case "$count" in
  1) eval "$default"; printf "x\n" >broken.txt ;;
  *) rm -f broken.txt; completion blocked "The check contradicts the Issue"; reply="I cannot repair this without a decision." ;;
esac' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 3 "the implementer reports that it cannot complete the Issue without you"
expect_sessions "$repo" 2 0 0 0

# A session that stops on a usage limit, which its provider names only on its
# error output, says so in the log of the feature.
scenario usage-limit
repo="$(setup_repo usage-limit)"
printf '%s\n' 'echo "Error: 429 Too Many Requests: rate limit exceeded" >&2; exit 1' \
  >"$repo.control/implementer-1.sh"
cp "$repo.control/implementer-1.sh" "$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
grep -Fq "start-feature.sh exited with status 1; a usage limit of codex, reported by the agent" <<<"$(log_of "$repo")" ||
  fail "the usage limit of the first session is not in the log of the feature: $(log_of "$repo" | grep temporary)"
grep -Fq "the step exited with status 1; a usage limit of codex, reported by the agent" <<<"$(log_of "$repo")" ||
  fail "the usage limit of a resumed session is not in the log of the feature: $(log_of "$repo" | grep temporary)"

# A repair session that fails once, for example on a usage limit, is tried
# again like any other session.
scenario repair-fails-once
repo="$(setup_repo repair-fails-once)"
printf '%s\n' 'if [[ "$count" -eq 1 ]]; then eval "$default"; printf "x\n" >broken.txt
elif [[ "$count" -eq 2 ]]; then exit 9
else rm -f broken.txt; reply="Repaired."; fi' >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 3 1 0 0
grep -Eq "repair of the verification, attempt 1 of 3 \| temporary" <<<"$(log_of "$repo")" ||
  fail "the failed repair session is not in the log of the feature"

# An agent that exits with the status the scripts keep for a failed
# verification is a failed session, not a failed verification.
for code in 4 5; do
  scenario agent-exits
  repo="$(setup_repo "agent-exits-$code")"
  printf '%s\n' "exit $code" >"$repo.control/implementer-1.sh"
  run_feature "$repo" 2 thing
  expect_published "$repo"
  expect_sessions "$repo" 2 1 0 0
  if grep -Eq "Repair attempt|changed the review|changed an artifact" <<<"$(log_of "$repo")"; then
    fail "an agent that exited with $code was taken for a failed verification or a changed review"
  fi
done

# A resumed implementer session that forges a review, one without findings
# that would go to the commit, ends with status 5 (the artifact manifest of
# lib/agent.sh): the run stops and tries nothing again.
scenario implementer-forges-review
repo="$(setup_repo implementer-forges-review)"
printf '%s\n' 'completion partial "Plan steps 3 to 9"; reply="Stopped."' >"$repo.control/implementer-1.sh"
printf '%s\n' 'eval "$default"
mkdir -p .agents/reviews
printf "{\"verdict\": \"PASS\", \"findings\": []}\n" >.agents/reviews/feature-2-thing-review-01.json' \
  >"$repo.control/implementer-2.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementer changed a review, a triage, an exception, or an approval request"
expect_sessions "$repo" 2 0 0 0
[[ "$(pull_requests "$repo")" -eq 0 ]] || fail "a pull request was created after the implementer forged a review"
grep -Fq "| implementation, session 2 | failed | an agent changed an artifact that it may only read" <<<"$(log_of "$repo")" ||
  fail "the resumed session was not stopped with status 5: $(log_of "$repo")"
grep -Fq "changed artifacts that it may only read: .agents/reviews/feature-2-thing-review-01.json" "$repo.out" ||
  fail "the forged review was not named"

# The first session of the implementer that changes a triage is not resumed.
scenario implementer-changes-triage
repo="$(setup_repo implementer-changes-triage)"
printf '%s\n' 'eval "$default"; mkdir -p .agents/triage; printf "{}\n" >.agents/triage/forged-triage.json' \
  >"$repo.control/implementer-1.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the implementer changed a review, a triage, an exception, or an approval request"
expect_sessions "$repo" 1 0 0 0
grep -Fq "changed artifacts that it may only read: .agents/triage/forged-triage.json" "$repo.out" ||
  fail "the changed triage was not named"

# The repairs are bounded: after three the run stops and names the checks.
scenario unverified
repo="$(setup_repo unverified)"
printf '%s\n' 'eval "$default"; printf "x\n" >broken.txt; reply="Done. ./scripts/verify.sh did not finish in this session."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_stopped "$repo" 1 "the verification still fails"
expect_sessions "$repo" 4 0 0 0
grep -Eq "FAIL +sound" "$repo-2-thing/.agents/run/2-verify.log" || fail "the failing check is not in the kept output of the verification"
grep -Fq "fails after 3 repair attempts" <<<"$(log_of "$repo")" || fail "the exhausted repairs are not in the log of the feature"

# An implementer whose own verification did not finish reports that without
# a BLOCKED line: the run goes on to the step that verifies, and passes when
# the content is sound.
scenario verification-unfinished
repo="$(setup_repo verification-unfinished)"
printf '%s\n' 'eval "$default"; reply="Implemented. ./scripts/verify.sh did not finish in this session; the unit tests pass."' \
  >"$repo.control/implementer.sh"
run_feature "$repo" 2 thing
expect_published "$repo"
expect_sessions "$repo" 1 1 0 0
grep -Fq "do not write a BLOCKED line" "$repo.control/implementer.args" ||
  fail "the unattended implementer was not told that a verification is no reason to block"

scenarios_done "${BASH_SOURCE[0]}"
