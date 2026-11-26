#!/usr/bin/env bash

set -euo pipefail

# The completion gate of a feature: what counts as a valid completion record
# (its schema and the rules across its fields), the checks of findings it
# holds, and how the gate decides from the record alone.

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/completion-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "completion test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/completion.sh"

root="$tmp/project"
mkdir -p "$root/.agents/completion" "$root/.agents/handoffs" "$root/.agents/summaries"
record="$(completion_record "$root" 7)"
[[ "$record" == "$root/.agents/completion/7.json" ]] || fail "the record of an Issue is not where the contract says: $record"
note="$root/.agents/handoffs/7.md"

complete='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "Works offline", "status": "not_applicable", "evidence": "the Issue dropped it in a comment"}
], "remaining": []}'
partial='{"schema": "completion/v1", "status": "partial", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "The page works without JavaScript", "status": "not_met", "evidence": "not started; plan step 4"}
], "remaining": ["Plan steps 4 to 6"]}'

# expect_errors <description> <record-json> <expected-error>...
expect_errors() {
  local description="$1"
  local errors

  printf '%s\n' "$2" >"$record"
  errors="$(completion_errors "$record")"
  shift 2
  if [[ $# -eq 0 ]]; then
    [[ -z "$errors" ]] || fail "$description: a valid record was refused: $errors"
    return 0
  fi
  for expected in "$@"; do
    grep -Fqx "$expected" <<<"$(printf '%s\n' "$errors")" || fail "$description: missing error '$expected' in: $errors"
  done
}

expect_errors "a complete record" "$complete"
expect_errors "a partial record" "$partial"
expect_errors "a blocked record" "$(printf '%s' "$partial" | sed 's/"partial"/"blocked"/')"
expect_errors "not JSON" "status: complete" "it is not valid JSON"
# The schema (.agents/schemas/completion.schema.json) is checked by the
# generic validator, and each error names the field.
expect_errors "not an object" '["complete"]' "record must be object, not array"
expect_errors "an empty object" '{}' "record.schema is missing" "record.status is missing" \
  "record.criteria is missing" "record.remaining is missing"
expect_errors "an unknown schema" "$(printf '%s' "$complete" | sed 's#completion/v1#completion/v2#')" \
  "record.schema must be one of completion/v1"
expect_errors "an unknown status" "$(printf '%s' "$complete" | sed 's/"complete"/"done"/')" \
  "record.status must be one of complete, awaiting_evidence, partial, blocked"
# A partial run of the checks is not a verification, so it is no evidence.
expect_errors "evidence that cites a partial run" "$(printf '%s' "$complete" | sed 's#tests/test_search.py#./scripts/verify.sh --only unit passed#')" \
  "criterion 1 cites a partial run of the checks (verify.sh --only or --changed) as evidence, which is not a verification"
# Nor is the targeted check of an agent session.
expect_errors "evidence that cites the targeted check of a session" "$(printf '%s' "$complete" | sed 's#tests/test_search.py#./scripts/verify.sh --changed passed#')" \
  "criterion 1 cites a partial run of the checks (verify.sh --only or --changed) as evidence, which is not a verification"
expect_errors "evidence that cites the full run" "$(printf '%s' "$complete" | sed 's#tests/test_search.py#./scripts/verify.sh passed#')"
# The full verification that run-feature.sh makes after an unattended
# session is the evidence of "./scripts/verify.sh --all passes" (Issue 490);
# a --changed run named for that criterion is still refused.
all_passes='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "`./scripts/verify.sh --all` passes", "status": "met", "evidence": "EVIDENCE"}
], "remaining": []}'
expect_errors "the orchestrator's full run as evidence" \
  "${all_passes/EVIDENCE/the full verification that run-feature.sh makes after this session}"
expect_errors "the orchestrator's pass named with its command" \
  "${all_passes/EVIDENCE/the pass of ./scripts/verify.sh --all that run-feature.sh records after this session}"
expect_errors "a targeted run for the full verification" \
  "${all_passes/EVIDENCE/./scripts/verify.sh --changed passed in this session}" \
  "criterion 1 cites a partial run of the checks (verify.sh --only or --changed) as evidence, which is not a verification"
expect_errors "no criteria" '{"schema": "completion/v1", "status": "complete", "criteria": [], "remaining": []}' \
  "record.criteria must have at least 1 item"
expect_errors "a criterion without evidence" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "met", "evidence": " "}], "remaining": []}' \
  "record.criteria[0].evidence does not match [^[:space:]]"
expect_errors "a criterion without text or a known status" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}, {"status": "yes", "evidence": "x"}], "remaining": ["more"]}' \
  "record.criteria[1].criterion is missing" "record.criteria[1].status must be one of met, not_met, not_applicable, pending"
expect_errors "a criterion that is not an object" \
  '{"schema": "completion/v1", "status": "partial", "criteria": ["It works"], "remaining": ["more"]}' \
  "record.criteria[0] must be object, not string"
expect_errors "an unknown risk" "$(printf '%s' "$complete" | sed 's/"remaining": \[\]/"remaining": [], "risk": "none"/')" \
  "record.risk must be one of low, medium, high"
# The status has to follow from the criteria and from what remains.
expect_errors "complete with a criterion that is not met" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "not_met", "evidence": "not started"}], "remaining": []}' \
  "status is complete, but a criterion is not met"
expect_errors "complete with work that remains" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": ["the documentation"]}' \
  "status is complete, but work remains"
expect_errors "partial without saying what is left" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": []}' \
  "status is partial, but remaining does not say what is left"
expect_errors "remaining that is not a list" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": "steps 3 to 9"}' \
  "record.remaining must be array, not string"
expect_errors "remaining that holds an empty text" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "met", "evidence": "a test"}], "remaining": ["step 3", " "]}' \
  "record.remaining[1] does not match [^[:space:]]"

# Evidence that appears at a later gate: pending is allowed there only, and
# the status is awaiting_evidence until it exists.
awaiting='{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [
  {"criterion": "Recipes can be searched", "status": "met", "evidence": "tests/test_search.py"},
  {"criterion": "CI passes on the pull request", "gate": "pr_ci", "status": "pending", "evidence": "after the pull request is published"},
  {"criterion": "main verifies after the merge", "gate": "post_merge", "status": "pending", "evidence": "the verify run on main"}
], "remaining": []}'
expect_errors "an awaiting_evidence record" "$awaiting"
expect_errors "a met criterion with an explicit gate" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "It works", "gate": "pr_ci", "status": "met", "evidence": "the CI run"}], "remaining": []}'
# The owner's approval is given on GitHub, never in a record that an agent
# writes: such a criterion can be pending (or not applicable), but not met.
expect_errors "owner_approval claimed as met" \
  '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "The owner approves", "gate": "owner_approval", "status": "met", "evidence": "the owner agreed in chat"}], "remaining": []}' \
  "criterion 1: owner_approval cannot be met in a record the implementer writes; it stays pending until the owner approves on GitHub"
expect_errors "owner_approval pending" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "The owner approves", "gate": "owner_approval", "status": "pending", "evidence": "approval of the final commit"}], "remaining": []}'
expect_errors "an unknown gate" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "gate": "later", "status": "met", "evidence": "x"}], "remaining": ["more"]}' \
  "record.criteria[0].gate must be one of implementation, pr_ci, owner_approval, post_merge"
expect_errors "pending without a gate" \
  '{"schema": "completion/v1", "status": "partial", "criteria": [{"criterion": "It works", "status": "pending", "evidence": "x"}], "remaining": ["more"]}' \
  "criterion 1: pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)"
expect_errors "pending at the implementation gate" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "It works", "gate": "implementation", "status": "pending", "evidence": "x"}], "remaining": []}' \
  "criterion 1: pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)"
expect_errors "complete with pending evidence" \
  "$(printf '%s' "$awaiting" | sed 's/"awaiting_evidence"/"complete"/')" \
  "status is complete, but a criterion is pending; the status is awaiting_evidence until its evidence exists"
expect_errors "awaiting_evidence with nothing pending" \
  "$(printf '%s' "$complete" | sed 's/"complete"/"awaiting_evidence"/')" \
  "status is awaiting_evidence, but no criterion is pending"
expect_errors "awaiting_evidence with a criterion not met" \
  '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "It works", "status": "not_met", "evidence": "x"}, {"criterion": "CI", "gate": "pr_ci", "status": "pending", "evidence": "y"}], "remaining": []}' \
  "status is awaiting_evidence, but a criterion is not met"
expect_errors "awaiting_evidence with work that remains" \
  "$(printf '%s' "$awaiting" | sed 's/"remaining": \[\]/"remaining": ["the documentation"]/')" \
  "status is awaiting_evidence, but work remains"

# The triage implementer's check of each finding (#292, #425): one entry of
# checks[] per finding and triage, in the completion record.
with_checks() {
  jq --argjson checks "$1" '.checks = $checks' <<<"$complete" >"$record"
}
expect_errors "a record with checks" "$(jq -c '.checks = [
  {triage: "feature-7-x-review-01-triage.json", finding: "C1", value: "fixed", evidence: "tests/a-test.sh: the CRLF case passes"},
  {triage: "feature-7-x-review-01-triage.json", finding: "MIN2", value: "not_executable", evidence: "needs a browser"}]' <<<"$complete")"
# A check that does not follow the schema is refused with its field named:
# another value, no evidence, a none-word or only punctuation for evidence,
# an id that is not one, a triage that is not a triage file.
expect_errors "checks that do not follow the schema" "$(jq -c '.checks = [
  {triage: "feature-7-x-review-01-triage.json", finding: "C1", value: "resolved", evidence: "it is fine"},
  {triage: "feature-7-x-review-01-triage.json", finding: "C2", value: "fixed", evidence: "none"},
  {triage: "feature-7-x-review-01-triage.json", finding: "C3", value: "fixed", evidence: "— — ."},
  {triage: "feature-7-x-review-01-triage.json", finding: "Class", value: "fixed", evidence: "a label"},
  {triage: "notes.md", finding: "C5", value: "fixed", evidence: "tests/a-test.sh"},
  {triage: "feature-7-x-review-01-triage.json", finding: "C6", value: "fixed"}]' <<<"$complete")" \
  "record.checks[0].value must be one of fixed, refuted, not_reproduced, not_executable" \
  "record.checks[1].evidence does not match $(jq -r '.properties.checks.items.properties.evidence.pattern' "$source_root/.agents/schemas/completion.schema.json")" \
  "record.checks[2].evidence does not match $(jq -r '.properties.checks.items.properties.evidence.pattern' "$source_root/.agents/schemas/completion.schema.json")" \
  "record.checks[3].finding does not match ^[A-Z]+[0-9]+\$" \
  "record.checks[4].triage does not match ^[^/[:space:]]+-triage\\.json\$" \
  "record.checks[5].evidence is missing"
# The gate refuses such a record, with the field named.
expect_gate_first() {
  [[ "$(completion_gate "$root" 7 | sed -n 1p)" == "$1" ]] || fail "$2: the gate says $(completion_gate "$root" 7 | tr '\n' ' ')"
}
with_checks '[{"triage": "feature-7-x-review-01-triage.json", "finding": "C1", "value": "resolved", "evidence": "x"}]'
expect_gate_first invalid "a record with a check of an unknown value"
grep -Fq "the completion record (.agents/completion/7.json): record.checks[0].value must be one of" <<<"$(completion_gate "$root" 7)" ||
  fail "the gate does not name the field of the check: $(completion_gate "$root" 7)"

with_checks '[
  {"triage": "feature-7-x-review-01-triage.json", "finding": "C1", "value": "fixed", "evidence": "tests/a-test.sh: the CRLF case passes"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "M2", "value": "refuted", "evidence": "printf x | ./a.sh\texits 0\nas expected"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "M3", "value": "not_reproduced", "evidence": "the command ran and printed nothing wrong"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "S4", "value": "not_executable", "evidence": "needs a browser; settled by reading, unverified"}]'
[[ "$(completion_finding_checks "$record" | cut -f 2,3 | tr '\t\n' ':|')" == "C1:fixed|M2:refuted|M3:not_reproduced|S4:not_executable|" ]] ||
  fail "the checks were not read: $(completion_finding_checks "$record")"
[[ "$(completion_finding_checks "$record" | sed -n 1p)" == "$(printf 'feature-7-x-review-01-triage.json\tC1\tfixed\ttests/a-test.sh: the CRLF case passes')" ]] ||
  fail "a check does not give its triage and its evidence: $(completion_finding_checks "$record" | sed -n 1p)"
[[ "$(completion_finding_checks "$record" | sed -n 2p | cut -f 4)" == "printf x | ./a.sh exits 0 as expected" ]] ||
  fail "the tabs and line breaks of the evidence were kept: $(completion_finding_checks "$record" | sed -n 2p)"
# The checks do not change the outcome of the gate: they are not remaining work.
expect_gate_first complete "a complete record with checks"
# An entry that does not follow the schema is no check, and a record that is
# missing or not JSON has none.
with_checks '[{"triage": "feature-7-x-review-01-triage.json", "finding": "C1", "value": "resolved", "evidence": "it is fine"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "C2", "value": "fixed", "evidence": "n/a"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "C8", "value": "fixed", "evidence": "— — —"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "Class", "value": "fixed", "evidence": "a label"},
  {"triage": "feature-7-x-review-01-triage.json", "finding": "C4", "value": "refuted"}, "C5: fixed — a text"]'
[[ -z "$(completion_finding_checks "$record")" ]] ||
  fail "an entry that is not a check was read as one: $(completion_finding_checks "$record")"
printf 'broken\n' >"$record"
[[ -z "$(completion_finding_checks "$record")" ]] || fail "a record that is not JSON has checks"
rm "$record"
[[ -z "$(completion_finding_checks "$record")" ]] || fail "a missing record has checks"

# The outcome per FIX_NOW finding of one triage: only its own entries count,
# and only fixed is resolved.
triage_file="$tmp/feature-7-x-review-02-triage.json"
jq -n '{decisions: [
  {finding_id: "C1", decision: "FIX_NOW"}, {finding_id: "M2", decision: "FIX_NOW"},
  {finding_id: "M3", decision: "FIX_NOW"}, {finding_id: "S4", decision: "FIX_NOW"},
  {finding_id: "M5", decision: "FIX_NOW"}, {finding_id: "M6", decision: "FIX_NOW"},
  {finding_id: "S7", decision: "ACCEPT"}]}' >"$triage_file"
one="feature-7-x-review-01-triage.json"
two="feature-7-x-review-02-triage.json"
with_checks "$(jq -n --arg one "$one" --arg two "$two" '[
  {triage: $one, finding: "C1", value: "fixed", evidence: "an earlier round"},
  {triage: $one, finding: "M5", value: "fixed", evidence: "an earlier round"},
  {triage: $two, finding: "C1", value: "not_reproduced", evidence: "ran tests/a-test.sh, it passes"},
  {triage: $two, finding: "M2", value: "refuted", evidence: "printf x | ./a.sh exits 0"},
  {triage: $two, finding: "M3", value: "not_executable", evidence: "needs GitHub"},
  {triage: $two, finding: "S4", value: "fixed", evidence: "tests/s-test.sh"},
  {triage: $two, finding: "M6", value: "fixed", evidence: "tests/m-test.sh"},
  {triage: $two, finding: "M6", value: "refuted", evidence: "the claim does not hold"},
  {triage: $two, finding: "S7", value: "fixed", evidence: "tests/s7-test.sh"}]')"
[[ "$(triage_check_outcomes "$record" "$triage_file" | cut -f 1,2 | tr '\t\n' ':|')" == "C1:not_reproduced|M2:refuted|M3:not_executable|S4:fixed|M5:missing|M6:conflicting|" ]] ||
  fail "the outcomes of the checks are not as recorded: $(triage_check_outcomes "$record" "$triage_file")"
[[ "$(completion_finding_checks "$record" "$one" | cut -f 2 | tr '\n' '|')" == "C1|M5|" ]] ||
  fail "the checks of one triage were not selected: $(completion_finding_checks "$record" "$one")"
# Duplicate entries: identical ones count once, and the same value with other
# evidence conflicts.
with_checks "$(jq -n --arg two "$two" '[
  {triage: $two, finding: "C1", value: "fixed", evidence: "tests/a-test.sh"},
  {triage: $two, finding: "C1", value: "fixed", evidence: "tests/a-test.sh"},
  {triage: $two, finding: "M2", value: "fixed", evidence: "tests/a-test.sh"},
  {triage: $two, finding: "M2", value: "fixed", evidence: "tests/b-test.sh"},
  {triage: $two, finding: "M3", value: "fixed", evidence: "tests/c-test.sh"}]')"
[[ "$(triage_check_outcomes "$record" "$triage_file" | sed -n 1,3p | tr '\t\n' ':|')" == "C1:fixed:tests/a-test.sh|M2:conflicting:fixed, with differing evidence|M3:fixed:tests/c-test.sh|" ]] ||
  fail "duplicate checks are not read as identical or conflicting: $(triage_check_outcomes "$record" "$triage_file")"
# A handoff note in the old form is not read: its lines check nothing.
printf '%b' "## Triage $two\n- C1: fixed — tests/a-test.sh\n" >"$note"
rm "$record"
[[ "$(triage_check_outcomes "$record" "$triage_file" | cut -f 2 | sort -u)" == "missing" ]] ||
  fail "without a record, a finding is not missing its check"
rm "$note"

# The gate: the outcome on the first line, the reasons after it.
# expect_gate <description> <outcome> [reason-fragment...]
expect_gate() {
  local description="$1"
  local expected="$2"
  local gate

  gate="$(completion_gate "$root" 7)"
  [[ "$(printf '%s\n' "$gate" | sed -n 1p)" == "$expected" ]] ||
    fail "$description: the gate says '$(printf '%s\n' "$gate" | sed -n 1p)' instead of '$expected'"
  shift 2
  for fragment in "$@"; do
    grep -Fq "$fragment" <<<"$(printf '%s\n' "$gate" | sed 1d)" || fail "$description: the reasons lack '$fragment': $gate"
  done
}

rm -f "$record"
expect_gate "no record" missing "the implementer wrote no completion record (.agents/completion/7.json)"
printf 'broken\n' >"$record"
expect_gate "a record that cannot be read" invalid "it is not valid JSON"
printf '%s\n' "$partial" >"$record"
expect_gate "a partial record" partial "not met: The page works without JavaScript" "remaining: Plan steps 4 to 6"
printf '%s\n' "$partial" | sed 's/"partial"/"blocked"/' >"$record"
expect_gate "a blocked record" blocked "remaining: Plan steps 4 to 6"
printf '%s\n' "$complete" >"$record"
expect_gate "a complete record" complete
[[ "$(completion_gate "$root" 7)" == "complete" ]] || fail "a passed gate gives reasons"
# The record of another Issue says nothing about this one.
expect_gate "the record of another Issue" complete
[[ "$(completion_gate "$root" 8 | sed -n 1p)" == "missing" ]] || fail "the record of Issue 7 was used for Issue 8"

# Pending evidence of a later gate passes the gate as awaiting_evidence and
# names what is pending; a hidden implementation criterion cannot be pending.
printf '%s\n' "$awaiting" >"$record"
expect_gate "an awaiting_evidence record" awaiting_evidence \
  "pending at pr_ci: CI passes on the pull request" "pending at post_merge: main verifies after the merge"
[[ "$(completion_pending_gates "$root" 7 | tr '\n' ' ')" == "post_merge pr_ci " ]] ||
  fail "the pending gates are '$(completion_pending_gates "$root" 7 | tr '\n' ' ')'"
completion_ready awaiting_evidence || fail "awaiting_evidence does not let the work go on"
completion_ready complete || fail "complete does not let the work go on"
if completion_ready partial; then fail "partial lets the work go on"; fi
printf '%s\n' "$awaiting" | sed 's/"gate": "pr_ci", //' >"$record"
expect_gate "pending without a gate" invalid "criterion 2: pending is only for evidence of a later gate"
printf '%s\n' "$awaiting" >"$record"
printf '**Remaining:** step 3.\n' >"$note"
expect_gate "pending evidence and remaining work in the handoff note" awaiting_evidence "pending at pr_ci: CI passes on the pull request"
rm "$note"

# A budget check of the verification configuration ('<name> [<group>]
# budget: <command>', scripts/verify.sh) is a measurement that never fails
# the verification, so it cannot be the evidence of a met criterion. The
# check is named as a whole word; a word that merely contains the name is not
# the check. Without a root, completion_errors cannot know the budgets.
mkdir -p "$root/scripts"
printf 'lint: true\nperf [code] budget: ./bench.sh\n' >"$root/scripts/verify.conf"
printf 'paths: scripts\nbundle-size budget: du -s dist\nselftest: ./tests/x.sh\n' >"$root/scripts/verify-workflow.conf"
[[ "$(completion_budget_checks "$root" | paste -sd, -)" == "bundle-size,perf" ]] ||
  fail "the budget checks of both files were not found: $(completion_budget_checks "$root" | paste -sd, -)"
cites_budget='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "The page is fast", "status": "met", "evidence": "the perf check of verify.sh passes"},
  {"criterion": "The bundle is small", "status": "met", "evidence": "verify.sh: bundle-size is within its target"}
], "remaining": []}'
printf '%s\n' "$cites_budget" >"$record"
expect_gate "evidence that cites a budget check" invalid \
  "criterion 1 cites the budget check 'perf' as evidence of a met criterion" \
  "criterion 2 cites the budget check 'bundle-size' as evidence of a met criterion"
[[ -z "$(completion_errors "$record")" ]] || fail "completion_errors without a root knew the budget checks"
names_but_not_the_check='{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "The page is fast", "status": "met", "evidence": "tests/test_performance.py::test_perf_page passes; perf-tests/ cover it"},
  {"criterion": "The bundle is small", "status": "met", "evidence": "the size of dist/ is asserted by tests/test_bundle.py"}
], "remaining": []}'
printf '%s\n' "$names_but_not_the_check" >"$record"
expect_gate "evidence that only contains the name of a budget check in a word" complete
budget_for_not_met='{"schema": "completion/v1", "status": "partial", "criteria": [
  {"criterion": "The page is fast", "status": "not_met", "evidence": "the perf budget is exceeded; the optimization is not done"}
], "remaining": ["The optimization"]}'
printf '%s\n' "$budget_for_not_met" >"$record"
expect_gate "a budget named in the evidence of a criterion that is not met" partial
# The target for the duration of the checks of a file ('budget-seconds: <n>')
# is a budget too: a record cannot cite it for a met criterion.
printf 'budget-seconds: 600\npaths: scripts\nselftest: ./tests/x.sh\n' >"$root/scripts/verify-workflow.conf"
[[ "$(completion_budget_checks "$root" | paste -sd, -)" == "budget-seconds,perf" ]] ||
  fail "the target for the duration was not found: $(completion_budget_checks "$root" | paste -sd, -)"
printf '%s\n' '{"schema": "completion/v1", "status": "complete", "criteria": [
  {"criterion": "The suite is fast", "status": "met", "evidence": "verify.sh stays within budget-seconds"}
], "remaining": []}' >"$record"
expect_gate "evidence that cites the target for the duration" invalid \
  "criterion 1 cites the budget check 'budget-seconds' as evidence of a met criterion"
rm "$root/scripts/verify.conf" "$root/scripts/verify-workflow.conf"
printf '%s\n' "$cites_budget" >"$record"
expect_gate "the same record in a project without budget checks" complete
printf '%s\n' "$awaiting" >"$record"
grep -Fqx -- "- pending at post_merge: main verifies after the merge (the verify run on main)" <<<"$(completion_commit_lines "$root" 7)" ||
  fail "the commit lines do not name the gate of pending evidence"
grep -Fqx "Completion: awaiting_evidence" <<<"$(completion_commit_lines "$root" 7)" || fail "the commit lines do not state awaiting_evidence"
# A pending post_merge criterion also gets an exact line, a JSON string, so
# that record-post-merge.sh matches it whatever it or its evidence contains;
# other gates and other statuses get none.
[[ "$(completion_commit_lines "$root" 7 | grep -c '^Post-merge criterion: ')" -eq 1 ]] || fail "the commit lines do not hold exactly one post-merge criterion line"
grep -Fqx 'Post-merge criterion: "main verifies after the merge"' <<<"$(completion_commit_lines "$root" 7)" || fail "the post-merge criterion line is not the criterion as a JSON string"
printf '%s\n' '{"schema": "completion/v1", "status": "awaiting_evidence", "criteria": [{"criterion": "main verifies \"fast\" (production)", "gate": "post_merge", "status": "pending", "evidence": "the run (verify.sh)"}], "remaining": []}' >"$record"
grep -Fqx 'Post-merge criterion: "main verifies \"fast\" (production)"' <<<"$(completion_commit_lines "$root" 7)" || fail "quotes and parentheses of a criterion are not kept exactly in its JSON string"
printf '%s\n' "$awaiting" >"$record"
printf '%s\n' "$complete" >"$record"

# The record is the only source of remaining work (#425): a handoff note
# that lists work does not change the outcome of the gate, and a record that
# says complete while work remains never reaches the review.
for listed in '**Remaining:** steps 3 to 9.\n' '## Remaining\n- step 3\n- step 4\n' '**Remaining:** None of the tests pass yet.\n'; do
  printf '%b' "$listed" >"$note"
  expect_gate "a complete record beside a note that lists work: $listed" complete
done
printf '%s\n' "$partial" >"$record"
printf 'Issue 7 is complete.\n' >"$note"
expect_gate "a partial record beside a note that says it is complete" partial "remaining: Plan steps 4 to 6"
printf '%s\n' "$complete" | jq '.remaining = ["the documentation"]' >"$record"
expect_gate "a complete record with work that remains" invalid "status is complete, but work remains"
printf '%s\n' "$complete" >"$record"
printf 'Issue 7 is complete.\n' >"$note"

# The statement that finish-feature.sh puts in the commit message.
[[ "$(completion_commit_lines "$root" 7)" == "Completion: complete
- met: Recipes can be searched (tests/test_search.py)
- not applicable: Works offline (the Issue dropped it in a comment)" ]] || fail "the completion statement of a complete record is wrong"
printf '%s\n' "$partial" >"$record"
[[ "$(completion_commit_lines "$root" 7)" == "Completion: partial
- met: Recipes can be searched (tests/test_search.py)
- not met: The page works without JavaScript (not started; plan step 4)
- remaining: Plan steps 4 to 6" ]] || fail "the completion statement of a partial record is wrong"

# Closing keywords. GitHub closes an Issue on one of them next to its number,
# so text taken over into a pull request that may not close the Issue is
# rewritten, and a commit that carries one is found.
closes() {
  grep -Eiq "$(completion_closing_pattern 12)" <<<"$(printf '%s\n' "$1")"
}
for closing in "Closes #12" "closes #12." "CLOSED #12" "Fix #12" "fixes: #12" "This fixed #12, see below" \
  "resolve #12" "Resolves owner/repo#12" "resolved https://github.com/owner/repo/issues/12" "(closes #12)"; do
  closes "$closing" || fail "a closing keyword was not recognised: $closing"
done
for harmless in "Refs #12" "Closes #123" "Closes #1" "This encloses #12" "prefixes #12" "See #12" "closes the gap in #12" \
  "Closes owner/repo#120"; do
  if closes "$harmless"; then fail "text without a closing keyword for Issue 12 was taken for one: $harmless"; fi
done
[[ "$(printf '%s\n' "Closes #12" "closes: #12." "This fixes #12 and Fixes #123, resolved owner/repo#12; see #12" \
  "Fixed https://github.com/o/r/issues/12" "Refs #12" "This encloses #12" | completion_neutralize_closing 12)" == "Refs #12
Refs #12.
This Refs #12 and Fixes #123, Refs owner/repo#12; see #12
Refs https://github.com/o/r/issues/12
Refs #12
This encloses #12" ]] || fail "closing keywords were not turned into references as expected"
if grep -Eiq "$(completion_closing_pattern 12)" <<<"$(printf '%s\n' "Closes #12" "Fixes #12 and resolves #12" | completion_neutralize_closing 12)"; then
  fail "a closing keyword survived the rewriting"
fi

# The summary of the changes, which an unattended commit needs.
if completion_summary_present "$root" 7; then fail "a missing summary counts as present"; fi
printf 'Some text without a list.\n' >"$root/.agents/summaries/7.md"
if completion_summary_present "$root" 7; then fail "a summary without a list line counts as present"; fi
printf -- '- Adds the search.\n' >"$root/.agents/summaries/7.md"
completion_summary_present "$root" 7 || fail "a summary with a list line does not count"

echo "completion tests passed"
