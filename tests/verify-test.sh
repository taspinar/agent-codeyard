#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "verify test failed: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\necho "ruff $*" >>"$MOCK_TOOL_LOG"\nexit "${MOCK_RUFF_EXIT:-0}"\n' >"$tmp/bin/ruff"
printf '#!/usr/bin/env bash\necho "pytest $*" >>"$MOCK_TOOL_LOG"\nexit "${MOCK_PYTEST_EXIT:-0}"\n' >"$tmp/bin/pytest"
chmod +x "$tmp/bin/ruff" "$tmp/bin/pytest"

# Creates an isolated project that contains only verify.sh and the given config.
setup_project() {
  local label="$1"
  local project="$tmp/$label"

  mkdir -p "$project/scripts"
  cp "$source_root/scripts/verify.sh" "$project/scripts/verify.sh"
  if [[ $# -gt 1 ]]; then
    printf '%s\n' "${@:2}" >"$project/scripts/verify.conf"
  fi
  printf '%s\n' "$project"
}

run_verify() {
  local project="$1"

  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" ${2+"$2"} >"$project/out.log" 2>&1
}

expect_failure() {
  local project="$1"
  local description="$2"

  if run_verify "$project"; then
    cat "$project/out.log" >&2
    fail "expected failure: $description"
  fi
}

# All required checks pass.
project="$(setup_project pass "# stack checks" "" "lint: ruff check ." "tests: pytest")"
run_verify "$project" || {
  cat "$project/out.log" >&2
  fail "passing checks were reported as a failure"
}
[[ "$(grep -c . "$project/tools.log")" -eq 2 ]] || fail "not every configured check ran"

# A failing linter fails verification, and later checks still run.
project="$(setup_project lint-fails "lint: ruff check ." "tests: pytest")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "ruff failure must propagate"
grep -Fq "pytest" "$project/tools.log" || fail "checks after a failure did not run"
grep -Eq "FAIL +lint" "$project/out.log" || fail "failed check was not identified"

# A failing test run fails verification.
project="$(setup_project tests-fail "lint: ruff check ." "tests: pytest")"
MOCK_PYTEST_EXIT=3 expect_failure "$project" "pytest failure must propagate"
grep -Eq "FAIL +tests" "$project/out.log" || fail "failed test check was not identified"

# A failure inside a pipeline or before a later command is not masked.
project="$(setup_project pipeline "lint: ruff check . | cat")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "pipeline failure must propagate"

project="$(setup_project sequence "lint: ruff check .; pytest")"
MOCK_RUFF_EXIT=1 expect_failure "$project" "failure before a later command must propagate"

# A required check whose tool is missing fails and names the check and tool.
project="$(setup_project missing-tool "lint: ruff check ." "types: mypy .")"
expect_failure "$project" "missing required tool must fail"
grep -Fq "mypy" <<<"$(grep -F "types" "$project/out.log")" ||
  fail "missing tool message did not name the check and tool"

# A required check script that is not executable fails.
project="$(setup_project not-executable "suite: ./suite.sh")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$project/suite.sh"
expect_failure "$project" "non-executable check script must fail"

# Checks run from the repository root, regardless of the caller's directory.
project="$(setup_project cwd "marker: test -f scripts/verify.conf")"
mkdir -p "$project/nested"
(cd "$project/nested" && run_verify "$project") ||
  fail "checks did not run from the repository root"

# Missing, empty, malformed, and duplicate configuration is rejected.
project="$(setup_project no-config)"
expect_failure "$project" "missing configuration must fail"

project="$(setup_project empty-config "# no checks" "")"
expect_failure "$project" "configuration without checks must fail"

project="$(setup_project malformed "lint ruff check .")"
expect_failure "$project" "malformed check line must fail"
[[ ! -e "$project/tools.log" ]] || fail "checks ran despite malformed configuration"

project="$(setup_project duplicate "lint: ruff check ." "lint: pytest")"
expect_failure "$project" "duplicate check name must fail"

# The workflow self-tests live in their own file and run only when a workflow
# file differs from the base branch.
setup_workflow_project() {
  local project

  project="$(setup_project "$1" "lint: ruff check .")"
  mkdir -p "$project/tools" "$project/src"
  printf 'paths: tools .gitignore scripts/verify-workflow.conf\nself-test: pytest\n' \
    >"$project/scripts/verify-workflow.conf"
  printf 'one\n' >"$project/tools/tool.sh"
  printf 'one\n' >"$project/src/app.txt"
  git -C "$project" init -q -b main
  git -C "$project" config user.name "Test User"
  git -C "$project" config user.email "test@example.com"
  git -C "$project" add -A
  git -C "$project" commit -qm "Initial commit"
  git -C "$project" checkout -q -b feature/1-change
  printf '%s\n' "$project"
}

self_tests_ran() {
  grep -Fq "pytest" "$1/tools.log"
}

expect_skipped() {
  local project="$1"
  local description="$2"

  rm -f "$project/tools.log"
  run_verify "$project" || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  grep -Fq "ruff" "$project/tools.log" || fail "the project checks did not run: $description"
  if self_tests_ran "$project"; then fail "the self-tests ran although $description"; fi
  grep -Eq "^SKIP +workflow self-tests \(1 checks\)" "$project/out.log" ||
    fail "the skipped self-tests were not reported: $description"
}

expect_ran() {
  local project="$1"
  local description="$2"

  rm -f "$project/tools.log"
  run_verify "$project" ${3+"$3"} || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  self_tests_ran "$project" || fail "the self-tests did not run although $description"
  if grep -Fq "SKIP" "$project/out.log"; then fail "a skip was reported although $description"; fi
}

project="$(setup_workflow_project workflow-unchanged)"
expect_skipped "$project" "nothing changed"
printf 'two\n' >>"$project/src/app.txt"
printf 'new\n' >"$project/src/new.txt"
expect_skipped "$project" "only project files changed"
git -C "$project" add -A
git -C "$project" commit -qm "Change the project"
expect_skipped "$project" "only project files were committed"
expect_ran "$project" "--all was given" --all

project="$(setup_workflow_project workflow-uncommitted)"
printf 'two\n' >>"$project/tools/tool.sh"
expect_ran "$project" "a workflow file has an uncommitted change"

project="$(setup_workflow_project workflow-untracked)"
printf 'new\n' >"$project/tools/new.sh"
expect_ran "$project" "a workflow file is new and untracked"

# A path entry can name a single file in the repository root.
project="$(setup_workflow_project workflow-root-file)"
printf 'build/\n' >"$project/.gitignore"
expect_ran "$project" "a guarded file in the repository root is new"

project="$(setup_workflow_project workflow-committed)"
git -C "$project" rm -q tools/tool.sh
git -C "$project" commit -qm "Remove a workflow file"
expect_ran "$project" "a workflow file was removed in a commit"

# A path entry can exclude a file from a guarded directory.
project="$(setup_workflow_project workflow-excluded)"
printf 'paths: tools :(exclude)tools/tool.sh\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
git -C "$project" commit -qam "Exclude a file"
git -C "$project" branch -q -f main
printf 'two\n' >>"$project/tools/tool.sh"
expect_skipped "$project" "only an excluded file changed"
printf 'new\n' >"$project/tools/other.sh"
expect_ran "$project" "another file in the guarded directory is new"

# Without a base branch the change cannot be determined, so the self-tests run.
project="$(setup_workflow_project workflow-no-base)"
git -C "$project" branch -q -D main
expect_ran "$project" "there is no base branch"

project="$(setup_project workflow-no-repository "lint: ruff check .")"
printf 'paths: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_ran "$project" "the project is not a Git repository"

# A failing self-test fails verification, and a self-test file without paths
# or without checks is rejected.
project="$(setup_workflow_project workflow-fails)"
printf 'two\n' >>"$project/tools/tool.sh"
MOCK_PYTEST_EXIT=1 expect_failure "$project" "a failing self-test must propagate"
grep -Eq "FAIL +self-test" "$project/out.log" || fail "the failed self-test was not identified"

project="$(setup_workflow_project workflow-no-paths)"
printf 'self-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "self-tests without paths must fail"

project="$(setup_workflow_project workflow-no-checks)"
printf 'paths: tools\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "a self-test file without checks must fail"

project="$(setup_workflow_project workflow-duplicate)"
printf 'paths: tools\nlint: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "a check name used in both files must fail"

# A run in which every check passed is recorded for the content it verified,
# and --reuse skips a second run on exactly that content.
setup_recorded_project() {
  local project

  project="$(setup_project "$1" "lint: ruff check .")"
  mkdir -p "$project/scripts/lib" "$project/src"
  cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" "$project/scripts/lib/"
  printf '*.log\n.agents/verification/\n' >"$project/.gitignore"
  printf 'one\n' >"$project/src/app.txt"
  git -C "$project" init -q -b main
  git -C "$project" config user.name "Test User"
  git -C "$project" config user.email "test@example.com"
  git -C "$project" add -A
  git -C "$project" commit -qm "Initial commit"
  printf '%s\n' "$project"
}

record="/.agents/verification/passed"

# run_checks <project> <description> [option...]: the checks must really run.
expect_checks_ran() {
  local project="$1"
  local description="$2"

  shift 2
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1 || {
    cat "$project/out.log" >&2
    fail "verification failed: $description"
  }
  grep -Fq "ruff" "$project/tools.log" 2>/dev/null || fail "the checks did not run although $description"
}

expect_reused() {
  local project="$1"
  local description="$2"

  shift 2
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1 || {
    cat "$project/out.log" >&2
    fail "a reused verification failed: $description"
  }
  [[ ! -e "$project/tools.log" ]] || fail "the checks ran again although $description"
  grep -Fq "already passed" "$project/out.log" || fail "the reuse was not reported: $description"
}

project="$(setup_recorded_project recorded)"
expect_checks_ran "$project" "nothing was recorded yet" --reuse
[[ -f "$project$record" ]] || fail "a passed run was not recorded"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the record changed the working tree"
expect_reused "$project" "the content is unchanged" --reuse
expect_checks_ran "$project" "--reuse was not given"
printf 'two\n' >>"$project/src/app.txt"
expect_checks_ran "$project" "a tracked file changed" --reuse
expect_reused "$project" "the changed content was verified" --reuse
printf 'new\n' >"$project/src/new.txt"
expect_checks_ran "$project" "an untracked file was added" --reuse
git -C "$project" add -A
git -C "$project" commit -qm "Commit the same content"
expect_reused "$project" "the same content was only committed" --reuse

# A failing run records nothing and removes an earlier record.
if MOCK_RUFF_EXIT=1 run_verify "$project"; then fail "a failing run returned success"; fi
[[ ! -e "$project$record" ]] || fail "a failing run left a record"
expect_checks_ran "$project" "the last run failed" --reuse

# A run whose check changes a file verified no single content.
project="$(setup_recorded_project self-modifying)"
printf 'touch: date >>src/app.txt\n' >"$project/scripts/verify.conf"
run_verify "$project" || fail "a run whose check changes a file failed"
[[ ! -e "$project$record" ]] || fail "a run that changed the content was recorded"

# Without the ignore rule the record would become part of the content, so
# none is written.
project="$(setup_recorded_project not-ignored)"
printf '*.log\n' >"$project/.gitignore"
git -C "$project" commit -qam "Drop the ignore rule"
expect_checks_ran "$project" "no record can be kept" --reuse
[[ ! -e "$project$record" ]] || fail "a record was written where Git does not ignore it"
expect_checks_ran "$project" "no record can be kept" --reuse

# A record made without the workflow self-tests does not cover --all.
project="$(setup_workflow_project recorded-workflow)"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" "$project/scripts/lib/"
printf 'paths: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
printf '*.log\n.agents/verification/\n' >"$project/.gitignore"
git -C "$project" add -A
git -C "$project" commit -qm "Keep verification records"
git -C "$project" branch -q -f main
expect_checks_ran "$project" "nothing was recorded yet" --reuse
if self_tests_ran "$project"; then fail "the self-tests ran although no workflow file changed"; fi
expect_reused "$project" "the content is unchanged" --reuse
expect_checks_ran "$project" "the record does not include the self-tests" --reuse --all
self_tests_ran "$project" || fail "--all with --reuse did not run the self-tests"
expect_reused "$project" "the self-tests were included in the record" --reuse --all
expect_reused "$project" "a complete record covers a plain run" --reuse

# The trust contract (lib/verification.sh): with VERIFY_TRUSTED_TREES set,
# --reuse reuses only a record whose tree is in the list. A record written
# by hand, whatever its origin says, or by a run in an agent session, is
# not reused then; without the variable it is, as before. The record says
# who started the run that wrote it.
project="$(setup_recorded_project trusted)"
expect_checks_ran "$project" "nothing was recorded yet" --reuse
grep -Fqx "origin: manual" "$project$record" || fail "a run at a terminal did not record the origin manual: $(cat "$project$record")"
tree="$(sed -n 's/^tree: //p' "$project$record")"
[[ -n "$tree" ]] || fail "the record names no tree"
printf 'tree: %s\nworkflow-tests: none\nverified-at: 2026-01-01T00:00:00Z\norigin: orchestrator\n' "$tree" >"$project$record"
VERIFY_TRUSTED_TREES="0123456789abcdef" expect_checks_ran "$project" "the forged record's tree is not in the list" --reuse
grep -Fq "not by a workflow script of this run" "$project/out.log" || fail "the refused record was not reported: $(cat "$project/out.log")"
printf 'tree: %s\nworkflow-tests: none\nverified-at: 2026-01-01T00:00:00Z\norigin: orchestrator\n' "$tree" >"$project$record"
VERIFY_TRUSTED_TREES="" expect_checks_ran "$project" "the list is empty" --reuse
CODEYARD_AGENT_SESSION=1 VERIFY_ORIGIN=script expect_checks_ran "$project" "--reuse was not given in an agent session"
grep -Fqx "origin: agent-session" "$project$record" || fail "a run in an agent session did not record the origin agent-session: $(cat "$project$record")"
VERIFY_TRUSTED_TREES="other" VERIFY_ORIGIN=script expect_checks_ran "$project" "a pass of an agent session is in no list" --reuse
grep -Fqx "origin: script" "$project$record" || fail "a run of a workflow script did not record the origin script: $(cat "$project$record")"
VERIFY_TRUSTED_TREES="other $tree" expect_reused "$project" "the tree is in the list" --reuse
CODEYARD_AGENT_SESSION=1 expect_checks_ran "$project" "--reuse was not given in an agent session"
expect_reused "$project" "without the list, any record for the content is reused" --reuse

# Inside a recorded run, every verification event says who started it and
# whether its pass counts as evidence.
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
git -C "$project" add -A
git -C "$project" commit -qm "Record runs"
: >"$tmp/trust-run.jsonl"
trust_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/trust-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$1/tools.log" \
    "$1/scripts/verify.sh" "${@:2}" >"$1/out.log" 2>&1
}
last_event() {
  jq -c -s 'map(select(.type == "verification")) | last | {status, reused, trusted, origin}' "$tmp/trust-run.jsonl"
}
expect_event() {
  [[ "$(last_event)" == "$1" ]] || fail "$2: $(last_event)"
}
CODEYARD_AGENT_SESSION=1 trust_run "$project" || fail "a run in an agent session failed"
expect_event '{"status":0,"reused":false,"trusted":false,"origin":"agent-session"}' "a pass of an agent session counts as evidence"
trust_run "$project" --reuse || fail "a reuse at a terminal failed"
expect_event '{"status":0,"reused":true,"trusted":false,"origin":"manual"}' "a reuse without the list counts as evidence"
VERIFY_ORIGIN=orchestrator VERIFY_TRUSTED_TREES="" trust_run "$project" --reuse || fail "a run of the orchestrator failed"
expect_event '{"status":0,"reused":false,"trusted":true,"origin":"orchestrator"}' "a pass that the orchestrator ran is not trusted"
tree="$(sed -n 's/^tree: //p' "$project$record")"
VERIFY_ORIGIN=script VERIFY_TRUSTED_TREES="$tree" trust_run "$project" --reuse || fail "a reuse of a trusted pass failed"
expect_event '{"status":0,"reused":true,"trusted":true,"origin":"script"}' "a reuse of a trusted pass is not trusted"
VERIFY_ORIGIN=script MOCK_RUFF_EXIT=1 trust_run "$project" && fail "a failing run passed"
expect_event '{"status":1,"reused":false,"trusted":false,"origin":"script"}' "a failed verification counts as evidence"

project="$(setup_project unknown-option "lint: ruff check .")"
if PATH="$tmp/bin:/usr/bin:/bin" "$project/scripts/verify.sh" --everything >"$project/out.log" 2>&1; then
  fail "an unknown option was accepted"
fi
[[ ! -e "$project/tools.log" ]] || fail "checks ran despite an unknown option"

# Groups: a check may name one, and --only runs the checks of the named
# groups. run_with <project> [option...] runs verify.sh with a fresh tool log.
run_with() {
  local project="$1"

  shift
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" "$@" >"$project/out.log" 2>&1
}

# ran <project>: the commands that ran, on one line.
ran() {
  tr '\n' ';' <"$1/tools.log" 2>/dev/null || true
}

project="$(setup_project groups "lint [code]: ruff check ." "tests[code]: pytest unit" \
  "slow  [e2e-1]: pytest e2e" "plain: ruff plain")"

# Without --only every check runs, as before.
run_with "$project" || fail "a configuration with groups failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;pytest e2e;ruff plain;" ]] ||
  fail "not every check ran without --only: $(ran "$project")"

run_with "$project" --groups || fail "--groups failed"
[[ "$(tr '\n' ',' <"$project/out.log")" == "code,e2e-1,default," ]] ||
  fail "--groups did not print the groups in the order of their first check: $(cat "$project/out.log")"
[[ ! -e "$project/tools.log" ]] || fail "--groups ran a check"

run_with "$project" --only code || fail "--only with one group failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;" ]] || fail "--only code ran: $(ran "$project")"
grep -Fq "Not a verification" "$project/out.log" || fail "a partial run did not say that it is not a verification"
if grep -Fq "Verification passed" "$project/out.log"; then fail "a partial run reported a passed verification"; fi

# A check without a group is in 'default', and several groups run in the
# order of the file, not of the option.
run_with "$project" --only default,code || fail "--only with two groups failed"
[[ "$(ran "$project")" == "ruff check .;pytest unit;ruff plain;" ]] || fail "--only default,code ran: $(ran "$project")"

if run_with "$project" --only code,nope; then fail "an unknown group was accepted"; fi
grep -Fq "no check is in the group 'nope'" "$project/out.log" || fail "the unknown group was not named"
[[ ! -e "$project/tools.log" ]] || fail "a check ran although a group was unknown"
if run_with "$project" --only; then fail "--only without a group was accepted"; fi
if run_with "$project" --only "Code"; then fail "a group name with a capital was accepted"; fi
if run_with "$project" --only code --reuse; then fail "--only was accepted together with --reuse"; fi
grep -Fq "nothing to reuse" "$project/out.log" || fail "the refusal of --reuse did not say why"

# A failing check of a selected group fails the partial run; a failing check
# of another group does not.
if MOCK_PYTEST_EXIT=1 run_with "$project" --only code; then fail "a failing check of the group passed"; fi
MOCK_PYTEST_EXIT=1 run_with "$project" --only default || fail "a failing check of another group failed the run"

# A malformed group is a malformed line.
project="$(setup_project bad-group "lint [Code]: ruff check .")"
expect_failure "$project" "a group name with a capital must fail"
project="$(setup_project empty-group "lint []: ruff check .")"
expect_failure "$project" "an empty group must fail"

# A check may declare the partition of a split suite it runs. The field
# changes nothing about the run; --partitions lists the declarations.
project="$(setup_project partitions "lint [code]: ruff check ." "unit-1 [code] partition ci/unit-1.txt: pytest one" \
  "unit-2 partition ci/unit-2.txt: pytest two")"
run_with "$project" || fail "a configuration with partitions failed"
[[ "$(ran "$project")" == "ruff check .;pytest one;pytest two;" ]] || fail "not every check ran with partitions: $(ran "$project")"
run_with "$project" --groups || fail "--groups failed with partitions"
[[ "$(tr '\n' ',' <"$project/out.log")" == "code,default," ]] || fail "--groups with partitions printed: $(cat "$project/out.log")"
run_with "$project" --partitions || fail "--partitions failed"
[[ "$(tr '\t\n' ' ,' <"$project/out.log")" == "ci/unit-1.txt unit-1,ci/unit-2.txt unit-2," ]] ||
  fail "--partitions printed: $(cat "$project/out.log")"
[[ ! -e "$project/tools.log" ]] || fail "--partitions ran a check"
project="$(setup_project budget-partition "unit-1 partition ci/unit-1.txt budget: pytest one")"
expect_failure "$project" "a budget check that declares a partition must fail"
project="$(setup_project empty-partition "unit-1 partition: pytest one")"
expect_failure "$project" "a partition field without a file must fail"

# A partial run is never a verification: it records nothing, whichever
# groups it runs, and it leaves a record of a complete run alone. A failing
# partial run removes the record, like any failing run.
project="$(setup_recorded_project partial)"
printf '%s\n' "lint [code]: ruff check ." "tests: pytest" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Give a check a group"
for group in code default code,default; do
  run_with "$project" --only "$group" || fail "--only $group failed"
  [[ ! -e "$project$record" ]] || fail "a partial run of '$group' recorded a passed verification"
done
run_with "$project" --reuse || fail "a complete run failed"
[[ "$(ran "$project")" == "ruff check .;pytest ;" ]] || fail "--reuse took partial runs for a verification: $(ran "$project")"
[[ -f "$project$record" ]] || fail "a complete run was not recorded"
before="$(cat "$project$record")"
run_with "$project" --only code || fail "a partial run after a complete one failed"
[[ "$(cat "$project$record")" == "$before" ]] || fail "a passing partial run changed the record of a complete run"
if MOCK_RUFF_EXIT=1 run_with "$project" --only code; then fail "a failing partial run returned success"; fi
[[ ! -e "$project$record" ]] || fail "a failing partial run left the record of a passed verification"

# The workflow self-tests have groups too, and keep their own rule: they run
# when a workflow file changed, or with --all.
project="$(setup_workflow_project workflow-groups)"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
printf '%s\n' "paths: scripts" "selftest [workflow]: pytest selftest" >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Group the checks"
git -C "$project" branch -f main HEAD
run_with "$project" --groups || fail "--groups failed with workflow self-tests"
[[ "$(tr '\n' ',' <"$project/out.log")" == "code,workflow," ]] || fail "--groups left out the group of a self-test"
run_with "$project" --only workflow || fail "--only workflow failed"
[[ ! -e "$project/tools.log" ]] || fail "--only ran a self-test although no workflow file changed"
grep -Fq "SKIP  workflow self-tests" "$project/out.log" || fail "the skipped self-tests were not reported"
run_with "$project" --all --only workflow || fail "--all --only workflow failed"
[[ "$(ran "$project")" == "pytest selftest;" ]] || fail "--all --only workflow ran: $(ran "$project")"
run_with "$project" --all --only code || fail "--all --only code failed"
[[ "$(ran "$project")" == "ruff check .;" ]] || fail "--all --only code ran a self-test: $(ran "$project")"

# A check name is unique across both files, also when the two checks name
# different groups: the name identifies the check in the summary.
project="$(setup_workflow_project same-name-groups)"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
printf '%s\n' "paths: scripts" "lint [workflow]: pytest selftest" >"$project/scripts/verify-workflow.conf"
if run_with "$project" --all; then fail "the same check name in both files, in different groups, was accepted"; fi
grep -Fq "duplicate check name" "$project/out.log" || fail "the duplicate name was not reported"
[[ ! -e "$project/tools.log" ]] || fail "a check ran although a check name is used twice"
if run_with "$project" --groups; then fail "--groups accepted a duplicate check name"; fi

# A check does not inherit the agent or attribution configuration chosen for
# the run that verifies.
project="$(setup_project agent-config 'config: test -z "${AGENT_CONFIG_FILE:-}" -a -z "${ATTRIBUTION_CONFIG_FILE:-}"')"
AGENT_CONFIG_FILE=/nonexistent.conf ATTRIBUTION_CONFIG_FILE=/nonexistent.conf run_verify "$project" || {
  cat "$project/out.log" >&2
  fail "a check inherited AGENT_CONFIG_FILE or ATTRIBUTION_CONFIG_FILE"
}

# The workflow self-tests give their own result when started by hand with the
# variable set.
(
  export AGENT_CONFIG_FILE=/nonexistent.conf ATTRIBUTION_CONFIG_FILE=/nonexistent.conf
  source "$source_root/tests/lib-fakes.sh"
  [[ -z "${AGENT_CONFIG_FILE:-}" && -z "${ATTRIBUTION_CONFIG_FILE:-}" ]]
) || fail "tests/lib-fakes.sh kept AGENT_CONFIG_FILE or ATTRIBUTION_CONFIG_FILE"

# A self-test started by hand inside a recorded run writes nothing into that
# run's record: tests/lib-fakes.sh drops the run's RECORDS_* variables, as
# verify.sh does for its checks. The workflow script here is verify.sh, which
# records itself into the run it finds.
project="$(setup_project inside-run "lint: ruff check .")"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
: >"$tmp/parent-run.jsonl"
(
  export RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/parent-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1
  source "$source_root/tests/lib-fakes.sh"
  run_verify "$project"
) || {
  cat "$project/out.log" >&2
  fail "verify.sh failed inside a recorded run"
}
[[ ! -s "$tmp/parent-run.jsonl" ]] || fail "a test wrote into the record of the run that started it: $(cat "$tmp/parent-run.jsonl")"

# A partial run inside a recorded run is not a verification and writes
# nothing into that run's record; a complete run there records itself.
project="$(setup_project partial-inside-run "lint [code]: ruff check ." "tests: pytest")"
mkdir -p "$project/scripts/lib"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
: >"$tmp/partial-run.jsonl"
inside_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/partial-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
inside_run "$project" --only code || {
  cat "$project/out.log" >&2
  fail "verify.sh --only failed inside a recorded run"
}
[[ "$(ran "$project")" == "ruff check .;" ]] || fail "--only code inside a run ran: $(ran "$project")"
[[ ! -s "$tmp/partial-run.jsonl" ]] || fail "a partial run wrote into the record of its run: $(cat "$tmp/partial-run.jsonl")"
inside_run "$project" || fail "verify.sh failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .groups == "all")' "$tmp/partial-run.jsonl" >/dev/null ||
  fail "a complete run inside a recorded run was not recorded"

# Budgets: a check declared as '<name> [<group>] budget: <command>' measures
# something against a target. Over the target it is BUDGET, not FAIL: the
# summary shows it with the output of the check, and the verification passes
# when every other check passed.
over='perf [code] budget: sh -c '"'"'echo "1.4 s, target 1.0 s"; exit 2'"'"
project="$(setup_project budget "lint: ruff check ." "$over" "size budget: echo 12kB")"
run_with "$project" || {
  cat "$project/out.log" >&2
  fail "a budget over its target failed the verification"
}
grep -Fq "ruff" "$project/tools.log" || fail "the other checks did not run with a budget"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "the exceeded budget is not BUDGET in the summary: $(cat "$project/out.log")"
grep -Fqx "        1.4 s, target 1.0 s" "$project/out.log" || fail "the summary lacks the output of the budget check"
grep -Fqx "PASS  size (budget within its target)" "$project/out.log" || fail "a budget within its target is not PASS"
grep -Fq "Verification passed." "$project/out.log" || fail "the verification with an exceeded budget did not pass"
grep -Fq "1 budget check(s) exceeded their target" "$project/out.log" || fail "the summary does not say that a budget was exceeded"
if grep -Fq "FAIL" "$project/out.log"; then fail "an exceeded budget was reported as a failure"; fi
grep -Fq -- "-- perf (budget):" "$project/out.log" || fail "a budget check is not marked as one when it runs"

# Every other check still has to pass: a failed check fails the verification
# as before, and the budget is still shown as BUDGET.
if MOCK_RUFF_EXIT=1 run_with "$project"; then fail "a failed check passed next to a budget"; fi
grep -Fqx "FAIL  lint (exit 1)" "$project/out.log" || fail "the failed check next to a budget was not identified"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "the budget is not BUDGET when another check fails"

# A budget check that does not finish measured nothing: the status 124 of
# 'timeout' and a death by a signal are FAIL, as for any check; so is a
# missing tool.
project="$(setup_project budget-timeout "slow budget: timeout 0.2 sleep 5")"
expect_failure "$project" "a budget check that does not finish must fail"
grep -Fqx "FAIL  slow (exit 124, the budget check did not finish)" "$project/out.log" ||
  fail "a budget check that did not finish is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-signal 'killed budget: sh -c '"'"'kill -TERM $$'"'"'')"
expect_failure "$project" "a budget check killed by a signal must fail"
grep -Eq "^FAIL  killed \(exit 1[0-9][0-9], the budget check did not finish\)" "$project/out.log" ||
  fail "a budget check killed by a signal is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-no-tool "perf budget: mypy --bench")"
expect_failure "$project" "a budget check without its tool must fail"
grep -Fq "FAIL  perf (missing tool: mypy)" "$project/out.log" || fail "a budget check without its tool is not FAIL"

# So are the statuses 125 to 127, which 'timeout' and the shell use for a check
# that could not run: an error of 'timeout' itself (125), and a command that is
# not executable (126) or not found (127) behind 'timeout' or anywhere in the
# command. Nothing was measured: FAIL, not BUDGET.
project="$(setup_project budget-timeout-error "perf budget: timeout --bogus 1 true")"
expect_failure "$project" "a budget check whose 'timeout' fails must fail"
grep -Fqx "FAIL  perf (exit 125, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a failing 'timeout' is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-executable "perf budget: timeout 5 ./scripts/verify.conf")"
expect_failure "$project" "a budget check whose command is not executable must fail"
grep -Fqx "FAIL  perf (exit 126, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a command that is not executable is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-found "perf budget: timeout 5 ./no-such-measurement")"
expect_failure "$project" "a budget check whose command is not found must fail"
grep -Fqx "FAIL  perf (exit 127, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a command that is not found is not FAIL: $(cat "$project/out.log")"
project="$(setup_project budget-not-found-later "perf budget: true && ./no-such-measurement")"
expect_failure "$project" "a budget check whose later command is not found must fail"
grep -Fqx "FAIL  perf (exit 127, the budget check could not run)" "$project/out.log" ||
  fail "a budget check with a later command that is not found is not FAIL: $(cat "$project/out.log")"
# The ordinary statuses up to 123 stay BUDGET, and so does 128: no utility
# returns it for a command that was not invoked, so a measurement may use it
# like any other status (review 02 M1).
project="$(setup_project budget-exit-128 "perf budget: sh -c 'echo over; exit 128'")"
run_with "$project" || fail "a budget check that exits 128 failed the verification"
grep -Fqx "BUDGET  perf (exit 128)" "$project/out.log" || fail "a budget check that exits 128 is not BUDGET: $(cat "$project/out.log")"
project="$(setup_project budget-exit-123 "perf budget: sh -c 'echo over; exit 123'")"
run_with "$project" || fail "a budget check that exits 123 failed the verification"
grep -Fqx "BUDGET  perf (exit 123)" "$project/out.log" || fail "a budget check that exits 123 is not BUDGET: $(cat "$project/out.log")"

# A budget with an empty output says so, and the exit status is kept.
project="$(setup_project budget-silent "perf budget: sh -c 'exit 3'")"
run_with "$project" || fail "a silent budget over its target failed the verification"
grep -Fqx "BUDGET  perf (exit 3)" "$project/out.log" || fail "the silent budget is not BUDGET"
grep -Fqx "        (no output)" "$project/out.log" || fail "the summary does not say that the budget check had no output"

# A budget belongs to its group like any check: --only runs it there, and a
# partial run passes with BUDGET too.
project="$(setup_project budget-groups "lint: ruff check ." "$over")"
run_with "$project" --only code || fail "--only with an exceeded budget failed"
grep -Fqx "BUDGET  perf (exit 2)" "$project/out.log" || fail "--only did not show the budget as BUDGET"
[[ ! -e "$project/tools.log" ]] || fail "--only code ran a check of another group"
run_with "$project" --only default || fail "--only default failed"
if grep -Fq "BUDGET" "$project/out.log"; then fail "--only default ran the budget of another group"; fi
run_with "$project" --groups || fail "--groups failed with a budget"
[[ "$(tr '\n' ',' <"$project/out.log")" == "default,code," ]] || fail "--groups lacks the group of a budget: $(cat "$project/out.log")"

# The syntax is exact: 'budget' stands before the colon, after the name or
# the group, separated by a space. Anything else is a name or malformed, and
# 'paths' is not a check.
project="$(setup_project budget-is-a-name "perfbudget: ruff check .")"
run_with "$project" || fail "a name that ends in 'budget' failed"
grep -Fqx "PASS  perfbudget" "$project/out.log" || fail "a name that ends in 'budget' is not an ordinary check"
project="$(setup_project budget-no-space "perf [code]budget: ruff check .")"
expect_failure "$project" "'budget' glued to the group must be malformed"
project="$(setup_project budget-space-before-colon "perf budget : ruff check .")"
expect_failure "$project" "a space before the colon must be malformed"
project="$(setup_project budget-no-group-space "perf[code] budget: ruff check .")"
run_with "$project" || fail "a group without a space before it failed with a budget"
project="$(setup_workflow_project budget-paths)"
printf 'paths budget: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
expect_failure "$project" "'paths' as a budget must be refused"
grep -Fq "'paths' is not a check and cannot be a budget" "$project/out.log" || fail "the refusal of 'paths budget:' did not say why"

# The budget results are recorded with the pass, next to the record, so the
# scripts that reuse the pass can show the measurement. A run without a
# budget check keeps no budget record, and a failing run removes both.
budgets="/.agents/verification/budgets"
project="$(setup_recorded_project recorded-budgets)"
printf '%s\n' "lint: ruff check ." "$over" "size budget: echo 12kB" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Declare budgets"
expect_checks_ran "$project" "nothing was recorded yet" --reuse
[[ -f "$project$record" ]] || fail "a passed run with an exceeded budget was not recorded"
[[ -f "$project$budgets" ]] || fail "the budget results were not recorded with the pass"
grep -Fqx "budget: perf" "$project$budgets" && grep -Fqx "status: exceeded" "$project$budgets" &&
  grep -Fqx "exit: 2" "$project$budgets" && grep -Fqx "  1.4 s, target 1.0 s" "$project$budgets" ||
  fail "the budget record lacks the result of the exceeded budget: $(cat "$project$budgets")"
grep -Fqx "budget: size" "$project$budgets" && grep -Fqx "status: within" "$project$budgets" ||
  fail "the budget record lacks the budget within its target: $(cat "$project$budgets")"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the budget record changed the working tree"
expect_reused "$project" "the content is unchanged" --reuse
grep -Fqx "  budget perf exceeded: 1.4 s, target 1.0 s" "$project/out.log" || fail "a reused pass does not show its budget results: $(cat "$project/out.log")"
grep -Fqx "  budget size within its target" "$project/out.log" || fail "a reused pass does not show the budget within its target"
[[ -f "$project$budgets" ]] || fail "a reused pass lost the budget record"
run_with "$project" --only code || fail "a partial run with a budget failed"
[[ -f "$project$budgets" ]] || fail "a partial run removed the budget record of a complete run"
if MOCK_RUFF_EXIT=1 run_with "$project"; then fail "a failing run with a budget returned success"; fi
[[ ! -e "$project$record" && ! -e "$project$budgets" ]] || fail "a failing run left the record or the budget record"
printf '%s\n' "lint: ruff check ." >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Drop the budgets"
run_with "$project" || fail "a run without budgets failed"
[[ -f "$project$record" && ! -e "$project$budgets" ]] || fail "a run without a budget check kept a budget record"

# The library reads the record and reports it; the report is for a person:
# one line per budget, the whole output of an exceeded one, or the last lines
# with a pointer to the whole output when the caller asks for a limit.
(
  source "$source_root/scripts/lib/fingerprint.sh"
  source "$source_root/scripts/lib/verification.sh"
  file="$tmp/budgets.txt"
  : >"$file"
  printf 'a\nb\nc\n' >"$tmp/out3"
  : >"$tmp/out0"
  printf 'one\n' >"$tmp/out1"
  verification_budget_add "$file" long exceeded 1 "$tmp/out3"
  verification_budget_add "$file" silent exceeded 7 "$tmp/out0"
  verification_budget_add "$file" fine within 0 "$tmp/out1"
  report="$(verification_budget_report <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  a\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the budget report is wrong: $report" >&2; exit 1; }
  report="$(verification_budget_report 2 <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  (1 earlier lines of the output left out)\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the limited budget report is wrong: $report" >&2; exit 1; }
  report="$(verification_budget_report 2 "the record" <"$file")"
  [[ "$report" == "$(printf 'budget long exceeded:\n  (1 earlier lines of the output left out; the full output is in the record)\n  b\n  c\nbudget silent exceeded (exit 7, no output)\nbudget fine within its target')" ]] ||
    { echo "the limited budget report does not say where the full output is: $report" >&2; exit 1; }
  [[ "$(verification_budget_report 3 "the record" <"$file" | head -1)" == "budget long exceeded:" && "$(verification_budget_report 3 <"$file" | sed -n 2p)" == "  a" ]] ||
    { echo "a limit that the output does not reach left lines out" >&2; exit 1; }
  verification_budgets_exceeded "$(cat "$file")" || { echo "an exceeded budget was not seen" >&2; exit 1; }
  if verification_budgets_exceeded "budget: fine"$'\n'"status: within"; then echo "a budget within its target counted as exceeded" >&2; exit 1; fi
  [[ "$(verification_budgets_json "$file" | jq -c 'map([.name, .status, .exit, .output])')" == '[["long","exceeded",1,"a\nb\nc"],["silent","exceeded",7,""],["fine","within",0,"one"]]' ]] ||
    { echo "the budget results as JSON are wrong: $(verification_budgets_json "$file")" >&2; exit 1; }
  [[ "$(verification_budgets_json "$tmp/none")" == "[]" ]] || { echo "a missing budget file is not an empty list" >&2; exit 1; }
) || fail "the budget functions of lib/verification.sh"

# Inside a recorded run, the verification event carries the budget results,
# also for a reused pass; a partial run records nothing, as before.
project="$(setup_recorded_project budgets-inside-run)"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
printf '%s\n' "lint [code]: ruff check ." "$over" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Declare a budget"
: >"$tmp/budget-run.jsonl"
budget_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/budget-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
budget_run "$project" --only code || fail "a partial run with a budget failed inside a run"
[[ ! -s "$tmp/budget-run.jsonl" ]] || fail "a partial run with a budget wrote into the record of its run"
budget_run "$project" || fail "verify.sh with a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .status == 0 and .reused == false
  and (.budgets | length) == 1 and .budgets[0].name == "perf" and .budgets[0].status == "exceeded"
  and .budgets[0].exit == 2 and .budgets[0].output == "1.4 s, target 1.0 s")' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "the verification event lacks the budget results: $(cat "$tmp/budget-run.jsonl")"
budget_run "$project" --reuse || fail "a reused pass with a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .reused == true and (.budgets | length) == 1 and .budgets[0].name == "perf")' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "the verification event of a reused pass lacks the budget results: $(cat "$tmp/budget-run.jsonl")"
printf '%s\n' "lint [code]: ruff check ." >"$project/scripts/verify.conf"
budget_run "$project" || fail "verify.sh without a budget failed inside a recorded run"
jq -e -s 'any(.type == "verification" and .reused == false and .budgets == [])' "$tmp/budget-run.jsonl" >/dev/null ||
  fail "a verification without a budget check does not record an empty list"

# Every check is timed. The durations are recorded with the pass, next to
# the record, and in the verification event of a run; a reused pass ran no
# check. 'budget-seconds: <n>' in either file is the target for the duration
# of all checks of that file: over it, the summary shows BUDGET with the
# total, the target, and the slowest checks, the verification passes when
# every check passed, and the result is recorded as a budget result.
summary_of() {
  sed -n '/^== Verification summary ==$/,$p' "$1/out.log"
}
durations="/.agents/verification/durations"
project="$(setup_recorded_project durations)"
cp "$source_root/scripts/lib/records.sh" "$project/scripts/lib/records.sh"
printf '%s\n' "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" add -A
git -C "$project" commit -qm "A slow check"
run_with "$project" || fail "a run with a slow check failed"
plain_summary="$(summary_of "$project")"
grep -Fq -- "-- slow took 1." "$project/out.log" || fail "the duration of a check is not shown when it ran: $(cat "$project/out.log")"
[[ "$(cut -f1,2,4 "$project$durations" | tr '\t\n' ' ;')" == "lint scripts/verify.conf pass;slow scripts/verify.conf pass;medium scripts/verify.conf pass;" ]] ||
  fail "the durations are not recorded with the pass: $(cat "$project$durations" 2>/dev/null)"
[[ "$(awk -F '\t' '$1 == "slow" { print ($3 >= 1200) }' "$project$durations")" == "1" ]] ||
  fail "the duration of the slow check is not measured: $(cat "$project$durations")"
[[ ! -e "$project$budgets" ]] || fail "a run without a budget kept a budget record"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the durations changed the working tree"

# Without the line the summary is the one it always was; with a target that
# is not exceeded, it is the same, and only the durations are recorded.
[[ "$plain_summary" == "$(printf '%s\n' "== Verification summary ==" "PASS  lint" "PASS  slow" "PASS  medium" "Verification passed.")" ]] ||
  fail "the summary without a target changed: $plain_summary"
printf '%s\n' "budget-seconds: 100" "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "A target that holds"
run_with "$project" || fail "a run within its target failed"
[[ "$(summary_of "$project")" == "$plain_summary" ]] || fail "a target that is not exceeded changed the summary: $(summary_of "$project")"
[[ ! -e "$project$budgets" && -s "$project$durations" ]] || fail "a target that is not exceeded kept a budget result, or lost the durations"

# Over the target: BUDGET with the total, the target, and the slowest checks
# first; the verification passes and the result is a budget result.
printf '%s\n' "budget-seconds: 1" "lint: ruff check ." "slow: sleep 1.2" "medium: sleep 0.3" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "A target that does not hold"
: >"$tmp/duration-run.jsonl"
duration_run() {
  RECORDS_RUN_ID=parent-run RECORDS_FILE="$tmp/duration-run.jsonl" RECORDS_COMMAND=scripts/run-feature.sh \
    RECORDS_KIND=feature RECORDS_SUBJECT=1 run_with "$@"
}
duration_run "$project" || fail "a run over the target of its duration failed: $(cat "$project/out.log")"
grep -Eqx 'BUDGET  duration of scripts/verify\.conf \(1\.[5-9]s, target 1s\)' "$project/out.log" ||
  fail "the summary lacks the BUDGET line with the total and the target: $(cat "$project/out.log")"
[[ "$(summary_of "$project" | grep -A3 '^BUDGET' | tail -n 3 | sed -E 's/ [0-9]+\.[0-9]s$//' | tr '\n' ';')" == "        slow;        medium;        lint;" ]] ||
  fail "the summary lacks the slowest checks, slowest first: $(summary_of "$project")"
grep -Fq "Verification passed." "$project/out.log" || fail "a verification over the target of its duration did not pass"
if grep -Fq "FAIL" "$project/out.log"; then fail "a duration over its target was reported as a failure"; fi
grep -Fqx "budget: duration of scripts/verify.conf" "$project$budgets" && grep -Fqx "status: exceeded" "$project$budgets" &&
  grep -Eq '^  slow [0-9.]+s$' "$project$budgets" ||
  fail "the duration over its target is not recorded as a budget result: $(cat "$project$budgets" 2>/dev/null)"
jq -e -s 'any(.type == "verification" and .status == 0 and .reused == false
  and (.budgets | map(select(.name == "duration of scripts/verify.conf" and .status == "exceeded")) | length) == 1
  and (.checks | map(.name)) == ["lint", "slow", "medium"]
  and (.checks | map(select(.name == "slow" and .seconds >= 1.2 and .result == "pass" and .config == "scripts/verify.conf")) | length) == 1)' \
  "$tmp/duration-run.jsonl" >/dev/null ||
  fail "the verification event lacks the durations or the budget result: $(cat "$tmp/duration-run.jsonl")"
# A reused pass shows the measurement and ran no check.
duration_run "$project" --reuse || fail "a reused pass over the target failed"
grep -Fq "  budget duration of scripts/verify.conf exceeded:" "$project/out.log" || fail "a reused pass does not show the duration budget: $(cat "$project/out.log")"
jq -e -s 'any(.type == "verification" and .reused == true and .checks == [] and (.budgets | length) == 1)' "$tmp/duration-run.jsonl" >/dev/null ||
  fail "the verification event of a reused pass is wrong: $(cat "$tmp/duration-run.jsonl")"

# A failing check still fails the verification; the measurement is shown.
if MOCK_RUFF_EXIT=1 duration_run "$project"; then fail "a failing check passed next to a target for the duration"; fi
grep -Fqx "FAIL  lint (exit 1)" "$project/out.log" || fail "the failing check is not FAIL next to a target for the duration"
grep -Fq "BUDGET  duration of scripts/verify.conf" "$project/out.log" || fail "the duration is not measured in a failing run"
[[ ! -e "$project$record" && ! -e "$project$durations" ]] || fail "a failing run left the record or the durations"
jq -e -s 'any(.type == "verification" and .status == 1 and (.checks | map(select(.name == "lint" and .result == "fail")) | length) == 1)' \
  "$tmp/duration-run.jsonl" >/dev/null || fail "the run record lacks the durations of a failing run"

# A partial run measures the checks it runs and compares with nothing.
printf '%s\n' "budget-seconds: 1" "lint: ruff check ." "slow [slow]: sleep 1.2" >"$project/scripts/verify.conf"
run_with "$project" --only slow || fail "a partial run with a target for the duration failed"
grep -Fq -- "-- slow took 1." "$project/out.log" || fail "a partial run does not measure its checks"
if grep -Fq "BUDGET" "$project/out.log"; then fail "a partial run compared with the target for the duration"; fi

# The target of a file covers only its checks, and self-tests that did not
# run compare with nothing.
project="$(setup_workflow_project duration-workflow)"
printf '%s\n' "budget-seconds: 1" "lint: sleep 1.2" >"$project/scripts/verify.conf"
printf '%s\n' "budget-seconds: 1" "paths: tools" "self-test: pytest" >"$project/scripts/verify-workflow.conf"
git -C "$project" commit -qam "Targets for both files"
run_with "$project" || fail "a run with targets in both files failed"
grep -Fq "SKIP  workflow self-tests" "$project/out.log" || fail "the self-tests ran although no workflow file changed"
grep -Fq "BUDGET  duration of scripts/verify.conf" "$project/out.log" || fail "the project checks were not compared with their target"
if grep -Fq "duration of scripts/verify-workflow.conf" "$project/out.log"; then fail "self-tests that did not run were compared with their target"; fi
run_with "$project" --all || fail "a run of every check with targets in both files failed"
if grep -Fq "duration of scripts/verify-workflow.conf" "$project/out.log"; then
  fail "the self-tests were charged with the duration of the project checks: $(cat "$project/out.log")"
fi
printf '%s\n' "budget-seconds: 1" "paths: tools" "self-test: sleep 1.2" >"$project/scripts/verify-workflow.conf"
run_with "$project" --all || fail "self-tests over their target failed"
grep -Eqx 'BUDGET  duration of scripts/verify-workflow\.conf \(1\.[2-9]s, target 1s\)' "$project/out.log" ||
  fail "the self-tests were not compared with their own target: $(cat "$project/out.log")"

# The line is exact: a whole number above 0, once per file, no group, no
# budget check, and never a check of its own.
for line in "budget-seconds: 0" "budget-seconds: 1.5" "budget-seconds: ten" "budget-seconds [code]: 5" "budget-seconds budget: 5"; do
  project="$(setup_project duration-malformed "$line" "lint: ruff check .")"
  expect_failure "$project" "'$line' must be refused"
  grep -Fq "'budget-seconds'" "$project/out.log" || fail "the refusal of '$line' did not say why: $(cat "$project/out.log")"
  [[ ! -e "$project/tools.log" ]] || fail "checks ran despite '$line'"
  rm -rf "$project"
done
project="$(setup_project duration-twice "budget-seconds: 5" "budget-seconds: 6" "lint: ruff check .")"
expect_failure "$project" "'budget-seconds' twice must be refused"
grep -Fq "declared more than once" "$project/out.log" || fail "the refusal of a second 'budget-seconds' did not say why"
project="$(setup_project duration-only "budget-seconds: 5")"
expect_failure "$project" "a file with a target and no check must be refused"

# The library turns the durations into JSON for the run record and skips a
# damaged line.
(
  source "$source_root/scripts/lib/verification.sh"
  file="$tmp/durations.txt"
  : >"$file"
  verification_duration_add "$file" slow scripts/verify.conf 1234 pass
  verification_duration_add "$file" over scripts/verify-workflow.conf 5 budget
  printf 'damaged line\n' >>"$file"
  [[ "$(verification_durations_json "$file" | jq -c 'map([.name, .config, .seconds, .result])')" == '[["slow","scripts/verify.conf",1.234,"pass"],["over","scripts/verify-workflow.conf",0.005,"budget"]]' ]] ||
    { echo "the durations as JSON are wrong: $(verification_durations_json "$file")" >&2; exit 1; }
  [[ "$(verification_durations_json "$tmp/none")" == "[]" ]] || { echo "a missing durations file is not an empty list" >&2; exit 1; }
) || fail "the duration functions of lib/verification.sh"

# The baseline of an adopted project: the first run records how each check
# ended, and is no verification. A pre-existing failure stays visible as
# KNOWN and never produces a passing verification; only the owner's
# accepted exception lets the verification pass while the check fails.
project="$(setup_recorded_project baseline)"
printf 'lint: ruff check .\ntests: pytest\ntypes: tsc --noEmit\n' >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Three checks"
baseline="$project/.agents/verification-baseline"
if MOCK_RUFF_EXIT=1 run_verify "$project" --baseline; then fail "a baseline with a failing check passed"; fi
grep -Fxq "fail: lint exit 1" "$baseline" && grep -Fxq "pass: tests" "$baseline" &&
  grep -Fxq "unavailable: types missing tool: tsc" "$baseline" && grep -Eq '^recorded-at: [0-9T:Z-]+$' "$baseline" ||
  fail "the baseline does not record each check: $(cat "$baseline" 2>/dev/null)"
[[ ! -e "$project$record" ]] || fail "a baseline recorded a pass"
for option in --reuse --all "--only default"; do
  # shellcheck disable=SC2086
  if PATH="$tmp/bin:/usr/bin:/bin" "$project/scripts/verify.sh" --baseline $option >"$project/out.log" 2>&1; then
    fail "--baseline was combined with $option"
  fi
done
before="$(cat "$baseline")"
if run_verify "$project" --baseline; then fail "a second baseline was recorded"; fi
grep -Fq "the baseline is recorded already" "$project/out.log" && [[ "$(cat "$baseline")" == "$before" ]] ||
  fail "a recorded baseline was not kept: $(cat "$project/out.log")"
git -C "$project" add -A
git -C "$project" commit -qm "Baseline"

# The pre-existing failures fail the verification, named as known, apart from
# a regression; nothing is recorded.
if MOCK_RUFF_EXIT=1 run_verify "$project"; then fail "a verification with pre-existing failures passed"; fi
grep -Eq "^KNOWN +lint \(exit 1\): failed before any change" "$project/out.log" &&
  grep -Eq "^KNOWN +types \(missing tool: tsc\)" "$project/out.log" && grep -Eq "^PASS +tests$" "$project/out.log" &&
  grep -Fq "2 check(s) failed before any change" "$project/out.log" || fail "the pre-existing failures are not shown as known: $(cat "$project/out.log")"
grep -q "Verification failed" "$project/out.log" && [[ ! -e "$project$record" ]] || fail "a verification with known failures recorded a pass"
if MOCK_RUFF_EXIT=1 MOCK_PYTEST_EXIT=2 run_verify "$project"; then fail "a regression passed"; fi
grep -Eq "^FAIL +tests \(exit 2\): a regression, it passed in the baseline" "$project/out.log" ||
  fail "a regression is not told apart from the known failures: $(cat "$project/out.log")"

# A fixed check passes again and says so; the unavailable one still fails.
if run_verify "$project"; then fail "a verification with an unavailable check passed"; fi
grep -Eq "^PASS +lint \(it failed in the baseline and passes now\)" "$project/out.log" || fail "a fixed check is not reported"

# The owner's exception: the failure is shown as accepted and does not fail
# the verification; an exception names a check, and gives a reason.
printf 'accepted-failure: types The type checker is not installed on this machine.\n' >>"$project/scripts/verify.conf"
run_verify "$project" || { cat "$project/out.log" >&2; fail "an accepted exception still failed the verification"; }
grep -Eq "^ACCEPTED +types \(missing tool: tsc\): an accepted exception of scripts/verify.conf: The type checker" "$project/out.log" &&
  grep -Fq "1 check(s) failed and are exceptions the owner accepted" "$project/out.log" ||
  fail "the accepted exception is not shown: $(cat "$project/out.log")"
[[ -f "$project$record" ]] || fail "a verification whose only failure is accepted recorded no pass"
if MOCK_RUFF_EXIT=1 run_verify "$project"; then fail "the known failure of a check without an exception passed"; fi
[[ ! -e "$project$record" ]] || fail "a failed verification kept the record of the earlier pass"
for line in "accepted-failure: types" "accepted-failure: nothing because" "accepted-failure [default]: types reason"; do
  project="$(setup_project "$(basename "$(mktemp -d "$tmp/exception.XXXXXX")")" "types: tsc" "$line")"
  expect_failure "$project" "a malformed exception must be refused: $line"
  grep -Fq "accepted-failure" "$project/out.log" || fail "the refusal of '$line' does not say why"
done
# A scoped exception: a check that already fails must not hide a new failure.
# The formatter 'fmt' lists the files that contain BAD (its arguments, or every
# file in src/) and fails when it lists one.
cat >"$tmp/bin/fmt" <<'FMT'
#!/usr/bin/env bash
echo "fmt $*" >>"$MOCK_TOOL_LOG"
[[ $# -gt 0 ]] || set -- src/*
status=0
for file in "$@"; do
  if grep -q BAD "$file"; then echo "$file"; status=1; fi
done
exit "$status"
FMT
chmod +x "$tmp/bin/fmt"

# setup_scoped_project <label> <exception-line>: a project with the check
# 'format: fmt', the exception, and the library of the base, whose base
# branch 'develop' already holds two unformatted files, on a feature branch
# with the base 'develop' recorded.
setup_scoped_project() {
  local project

  project="$(setup_recorded_project "$1")"
  cp "$source_root/scripts/lib/base.sh" "$project/scripts/lib/"
  printf 'format: fmt\n%s\n' "$2" >"$project/scripts/verify.conf"
  printf 'BAD\n' >"$project/src/old.txt"
  printf 'fine\n' >"$project/src/ok.txt"
  git -C "$project" add -A
  git -C "$project" commit -qm "The formatter backlog"
  git -C "$project" switch -q -c develop
  printf 'BAD\n' >"$project/src/dev.txt"
  git -C "$project" add -A
  git -C "$project" commit -qm "More backlog on develop"
  git -C "$project" switch -q -c feature/9-scope
  git -C "$project" config branch.feature/9-scope.workflow-base develop
  printf '%s\n' "$project"
}

# expect_scoped_failure <project> <description> <pattern>: the verification
# fails, and its output matches <pattern>.
expect_scoped_failure() {
  if run_verify "$1"; then cat "$1/out.log" >&2; fail "$2 passed"; fi
  grep -Eq "$3" "$1/out.log" || fail "$2 is not reported: $(cat "$1/out.log")"
}

# changed-files: the unchanged files of the backlog may fail, every file the
# feature adds or changes must pass, measured from the recorded base: dev.txt
# is unchanged since 'develop', though not since 'main'.
project="$(setup_scoped_project scoped-changed "accepted-failure: format changed-files exit 1 fmt")"
run_verify "$project" || { cat "$project/out.log" >&2; fail "an unchanged backlog failed the scoped check"; }
grep -Eq "^SCOPED +format \(exit 1\): accepted for the files that did not change since develop; no file changed" "$project/out.log" &&
  ! grep -q "^ACCEPTED" "$project/out.log" || fail "the scoped exception is not shown as SCOPED: $(cat "$project/out.log")"
printf 'BAD\n' >"$project/src/new.txt"
expect_scoped_failure "$project" "an untracked file that fails the scoped check" \
  "^FAIL +format \(exit 1\): beyond the scope of its exception"
grep -Eq "a file changed since develop fails it \(exit 1\): fmt" "$project/out.log" || fail "the changed file's failure is not named"
grep -Fq "fmt src/new.txt" "$project/tools.log" || fail "the scoped command did not get the new file: $(cat "$project/tools.log" 2>/dev/null)"
rm "$project/src/new.txt"
printf 'BAD\n' >"$project/src/ok.txt"
expect_scoped_failure "$project" "an unstaged change that fails the scoped check" "^FAIL +format"
git -C "$project" add src/ok.txt
expect_scoped_failure "$project" "a staged change that fails the scoped check" "^FAIL +format"
git -C "$project" commit -qm "Break a file"
expect_scoped_failure "$project" "a committed change that fails the scoped check" "^FAIL +format"
printf 'fine\n' >"$project/src/ok.txt"
printf 'still BAD\n' >"$project/src/old.txt"
expect_scoped_failure "$project" "a changed file of the backlog that still fails" "^FAIL +format"
printf 'fixed\n' >"$project/src/old.txt"
git -C "$project" commit -qam "Fix a file of the backlog"
run_verify "$project" || { cat "$project/out.log" >&2; fail "a feature whose changed files pass failed"; }
grep -Eq "^SCOPED +format \(exit 1\): .*the 1 changed file\(s\) pass" "$project/out.log" &&
  grep -Fq "1 check(s) failed only within the scope" "$project/out.log" || fail "the passing changed files are not reported: $(cat "$project/out.log")"
# The default base of the project when none is recorded, and no base at all.
git -C "$project" config --unset branch.feature/9-scope.workflow-base
mkdir -p "$project/.agents"
printf 'base: develop\n' >"$project/.agents/template.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Default base"
run_verify "$project" || { cat "$project/out.log" >&2; fail "the default base of .agents/template.conf was not used"; }
grep -Eq "^SCOPED +format .*since develop" "$project/out.log" || fail "the default base is not named: $(cat "$project/out.log")"
git -C "$project" config branch.feature/9-scope.workflow-base gone
expect_scoped_failure "$project" "a scope without a base" "the files changed since the base cannot be determined"
# A check that could not run on is not within the scope either, though no
# file changed.
git -C "$project" config branch.feature/9-scope.workflow-base develop
printf 'format: echo src/dev.txt; missing-subcommand\naccepted-failure: format changed-files exit 1 fmt\n' >"$project/scripts/verify.conf"
expect_scoped_failure "$project" "a changed-files check that ended with exit 127" \
  "^FAIL +format \(exit 127, a command was not found\): beyond the scope of its exception"
grep -Eq "^ +it did not complete \(exit 127, a command was not found\)" "$project/out.log" &&
  ! grep -q "^SCOPED" "$project/out.log" || fail "a changed-files check that could not run on is in the scope: $(cat "$project/out.log")"
# Nor is a check that ended with a status its exception does not declare: 2
# of prettier is a problem of the formatter itself, not a formatting failure.
printf 'format: echo src/dev.txt; exit 2\naccepted-failure: format changed-files exit 1 fmt\n' >"$project/scripts/verify.conf"
expect_scoped_failure "$project" "a changed-files check that ended with an undeclared exit 2" \
  "^FAIL +format \(exit 2\): beyond the scope of its exception"
grep -Eq "^ +it ended with exit 2, not with a status its exception declares \(exit 1\)" "$project/out.log" &&
  ! grep -q "^SCOPED" "$project/out.log" || fail "a changed-files check that ended with exit 2 is in the scope: $(cat "$project/out.log")"

# recorded: the failures are compared with a list that may only shrink.
project="$(setup_scoped_project scoped-recorded "accepted-failure: format recorded exit 1")"
expect_scoped_failure "$project" "a recorded exception without its list" "accepted-failures/format, which does not exist"
mkdir -p "$project/.agents/accepted-failures"
printf '# The formatter backlog.\nsrc/dev.txt\nsrc/old.txt\nsrc/gone.txt\n' >"$project/.agents/accepted-failures/format"
git -C "$project" add -A
git -C "$project" commit -qm "Record the backlog"
git -C "$project" branch -f develop HEAD
run_verify "$project" || { cat "$project/out.log" >&2; fail "the recorded failures failed the verification"; }
grep -Eq "^SCOPED +format \(exit 1\): 2 failure\(s\), each recorded in .agents/accepted-failures/format" "$project/out.log" ||
  fail "the recorded failures are not shown as SCOPED: $(cat "$project/out.log")"
grep -Eq "^FIXED +format: src/gone.txt, recorded in .agents/accepted-failures/format, no longer fails" "$project/out.log" &&
  grep -Fq "1 recorded failure(s) no longer occur (FIXED): remove them" "$project/out.log" ||
  fail "a fixed recorded failure is not reported: $(cat "$project/out.log")"
# The list may only shrink: an entry it did not hold at the base fails, even
# of a failure of an unchanged file; a removed entry does not.
printf 'BAD\n' >"$project/src/late.txt"
git -C "$project" add -A
git -C "$project" commit -qm "A failure on the base that is not recorded"
git -C "$project" branch -f develop HEAD
printf 'src/late.txt\n' >>"$project/.agents/accepted-failures/format"
expect_scoped_failure "$project" "a recorded list that grew" "^FAIL +format \(exit 1\): beyond the scope"
grep -Eq "^ +1 failure\(s\) added to .agents/accepted-failures/format since develop, where it may only shrink:" "$project/out.log" &&
  grep -Eq "^ +src/late.txt$" "$project/out.log" || fail "the added entry is not named: $(cat "$project/out.log")"
git -C "$project" checkout -q -- .agents/accepted-failures/format
git -C "$project" rm -q src/late.txt
git -C "$project" commit -qm "Fix the failure on the base"
git -C "$project" branch -f develop HEAD
grep -v '^src/gone.txt$' "$project/.agents/accepted-failures/format" >"$project/shrunk"
mv "$project/shrunk" "$project/.agents/accepted-failures/format"
run_verify "$project" || { cat "$project/out.log" >&2; fail "a recorded list that shrank failed the verification"; }
! grep -q "^FIXED" "$project/out.log" || fail "a removed entry is still reported as FIXED: $(cat "$project/out.log")"
git -C "$project" checkout -q -- .agents/accepted-failures/format
printf 'BAD\n' >"$project/src/new.txt"
expect_scoped_failure "$project" "a failure that is not recorded" "^FAIL +format \(exit 1\): beyond the scope"
grep -Eq "^ +1 new failure\(s\): not recorded" "$project/out.log" && grep -Eq "^ +src/new.txt$" "$project/out.log" ||
  fail "the new failure is not listed: $(cat "$project/out.log")"
rm "$project/src/new.txt"
printf 'BAD again\n' >"$project/src/old.txt"
expect_scoped_failure "$project" "a changed recorded file that still fails" "^ +src/old.txt$"
printf 'fixed\n' >"$project/src/old.txt"
run_verify "$project" || { cat "$project/out.log" >&2; fail "a fixed recorded file failed the verification"; }
grep -Eq "^FIXED +format: src/old.txt" "$project/out.log" || fail "the fixed recorded file is not reported: $(cat "$project/out.log")"
printf 'fixed\n' >"$project/src/dev.txt"
run_verify "$project" || { cat "$project/out.log" >&2; fail "a check without failures failed"; }
grep -Eq "^PASS +format \(it passes: its scoped exception in scripts/verify.conf is no longer needed\)" "$project/out.log" &&
  [[ "$(grep -c "^FIXED" "$project/out.log")" -eq 3 ]] || fail "a passing check with a recorded list is not reported: $(cat "$project/out.log")"
printf 'src/ok.txt\n' >>"$project/.agents/accepted-failures/format"
expect_scoped_failure "$project" "a recorded list that grew while the check passes" \
  "^FAIL +format \(it passes, but 1 failure\(s\) were added to .agents/accepted-failures/format since develop, where it may only shrink\)"
git -C "$project" checkout -q -- .agents/accepted-failures/format
# Only a check that completed is within the scope: one that printed a recorded
# failure and then could not run on (127), was killed by a signal (143), or
# timed out (124) fails, and the recorded failures it did not reach are not
# FIXED.
git -C "$project" checkout -q -- src
for check in "echo src/dev.txt; missing-subcommand|exit 127, a command was not found" \
  'echo src/dev.txt; kill -TERM $$|exit 143' "echo src/dev.txt; timeout 1 sleep 30|exit 124"; do
  printf 'format: %s\naccepted-failure: format recorded exit 1\n' "${check%|*}" >"$project/scripts/verify.conf"
  expect_scoped_failure "$project" "a recorded check that ended with ${check#*|}" \
    "^FAIL +format \(${check#*|}\): beyond the scope of its exception"
  grep -Eq "^ +it did not complete \(${check#*|}\)" "$project/out.log" &&
    grep -Fq "Error: check 'format' did not complete (${check#*|})" "$project/out.log" &&
    ! grep -Eq "^(SCOPED|FIXED)" "$project/out.log" || fail "a check that ended with ${check#*|} is in the scope: $(cat "$project/out.log")"
done
# Only the status the exception declares means a completed check with
# failures: a simulated formatter that prints a recorded failure and exits 2,
# a problem of the formatter itself, fails, with nothing SCOPED or FIXED; the
# same check passes within its scope where its exception declares 2 too.
printf '#!/usr/bin/env bash\necho src/dev.txt\nexit 2\n' >"$tmp/bin/fmt-broken"
chmod +x "$tmp/bin/fmt-broken"
printf 'format: fmt-broken\naccepted-failure: format recorded exit 1\n' >"$project/scripts/verify.conf"
expect_scoped_failure "$project" "a recorded check that ended with an undeclared exit 2" \
  "^FAIL +format \(exit 2\): beyond the scope of its exception"
grep -Eq "^ +it ended with exit 2, not with a status its exception declares \(exit 1\)" "$project/out.log" &&
  grep -Fq "Error: check 'format' ended with status 2, which its scoped exception does not declare" "$project/out.log" &&
  ! grep -Eq "^(SCOPED|FIXED)" "$project/out.log" || fail "a check that ended with an undeclared exit 2 is in the scope: $(cat "$project/out.log")"
printf 'format: fmt-broken\naccepted-failure: format recorded exit 1,2\n' >"$project/scripts/verify.conf"
run_verify "$project" || { cat "$project/out.log" >&2; fail "a declared exit 2 is not within the scope"; }
grep -Eq "^SCOPED +format \(exit 2\): 1 failure\(s\)" "$project/out.log" || fail "a declared exit 2 is not SCOPED: $(cat "$project/out.log")"
printf 'fixed\n' >"$project/src/old.txt"
printf 'fixed\n' >"$project/src/dev.txt"
# A failure that lists nothing is not within the scope.
printf 'format: fmt && exit 3\naccepted-failure: format recorded exit 3\n' >"$project/scripts/verify.conf"
expect_scoped_failure "$project" "a failure without a listed failure" "it listed no failure to compare with"

# A scoped exception declares its statuses; there is no default, and a status
# that does not mean a completed check with failures is refused.
for line in "accepted-failure: format changed-files" "accepted-failure: format changed-files fmt" \
  "accepted-failure: format changed-files exit 1" "accepted-failure: format recorded" \
  "accepted-failure: format recorded exit" "accepted-failure: format recorded exit 1 src/list" \
  "accepted-failure: format recorded exit 0" "accepted-failure: format recorded exit 1,127" \
  "accepted-failure: format recorded exit 124" "accepted-failure: format recorded exit 143" \
  "accepted-failure: format recorded exit 1,,2" "accepted-failure: size changed-files exit 1 fmt"; do
  project="$(setup_project "scoped-$RANDOM" "format: fmt" "size budget: fmt" "$line")"
  expect_failure "$project" "a malformed scoped exception must be refused: $line"
  grep -Fq "accepted-failure" "$project/out.log" || fail "the refusal of '$line' does not say why"
done
# Within a run that keeps trusted passes (VERIFY_TRUSTED_TREES), the
# self-tests are compared with the tree of the last trusted pass, not with
# the base: a later change that touches no workflow file skips them, one that
# does runs them, and without a trusted tree Git knows the base decides.
project="$(setup_recorded_project trusted-trigger)"
mkdir -p "$project/tools"
printf 'one\n' >"$project/tools/tool.sh"
printf 'paths: tools\nself-test: pytest\n' >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Self-tests"
git -C "$project" checkout -q -b feature/1-change
printf 'two\n' >>"$project/tools/tool.sh"
VERIFY_TRUSTED_TREES="" expect_ran "$project" "a workflow file differs from the base and no pass is trusted yet"
trusted="$(sed -n 's/^tree: //p' "$project$record")"
[[ "$(sed -n 's/^workflow-tests: //p' "$project$record")" == "ran" ]] || fail "the first pass did not record its self-tests"
printf 'two\n' >>"$project/src/app.txt"
VERIFY_TRUSTED_TREES="other $trusted" expect_skipped "$project" "no workflow file differs from the last trusted pass"
grep -Fq "no workflow file differs from the last trusted pass of this run (tree ${trusted:0:12})" "$project/out.log" ||
  fail "the skip does not name the trusted pass it compared with: $(cat "$project/out.log")"
VERIFY_TRUSTED_TREES="$trusted 0123456789abcdef0123456789abcdef01234567" expect_ran "$project" "the last trusted tree is unknown to Git, so the base decides"
grep -Fq "a workflow file differs from main" "$project/out.log" || fail "the fallback did not compare with the base: $(cat "$project/out.log")"
expect_ran "$project" "a run at a terminal compares with the base"
printf 'three\n' >>"$project/tools/tool.sh"
VERIFY_TRUSTED_TREES="$trusted" expect_ran "$project" "a workflow file differs from the last trusted pass"
grep -Fq "a workflow file differs from the last trusted pass of this run" "$project/out.log" ||
  fail "the run does not say that it compared with the trusted pass: $(cat "$project/out.log")"

# --changed, the targeted check of an agent session: every project check,
# and the self-tests of the files changed since the base only; a partial run
# that records nothing.
project="$(setup_recorded_project changed-tests)"
mkdir -p "$project/tests"
for name in alpha beta gamma; do
  printf '#!/usr/bin/env bash\necho "%s-test" >>"$MOCK_TOOL_LOG"\n' "$name" >"$project/tests/$name-test.sh"
  chmod +x "$project/tests/$name-test.sh"
done
printf 'one\n' >"$project/scripts/alpha.sh"
printf 'one\n' >"$project/scripts/lib/beta.sh"
# gamma.sh reads a jq program of scripts/lib/, as report-runs.sh reads lib/report.jq.
printf 'jq -f "$(dirname "$0")/lib/delta.jq"\n' >"$project/scripts/gamma.sh"
printf '.\n' >"$project/scripts/lib/delta.jq"
printf '.\n' >"$project/scripts/lib/epsilon.jq"
printf '%s\n' "paths: scripts tests" "alpha: ./tests/alpha-test.sh" "beta: ./tests/beta-test.sh" \
  "gamma: ./tests/gamma-test.sh" "self-test: pytest" >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Self-tests of scripts"
git -C "$project" checkout -q -b feature/1-change
run_changed() {
  rm -f "$project/tools.log"
  PATH="$tmp/bin:/usr/bin:/bin" MOCK_TOOL_LOG="$project/tools.log" \
    "$project/scripts/verify.sh" --changed "$@" >"$project/out.log" 2>&1
}
run_changed || fail "--changed without a change failed: $(cat "$project/out.log")"
grep -Fqx "ruff check ." "$project/tools.log" || fail "--changed did not run the project checks"
[[ "$(grep -c . "$project/tools.log")" -eq 1 ]] || fail "--changed ran a self-test of nothing changed: $(cat "$project/tools.log")"
grep -Fq "SKIP  workflow self-tests (4 checks): --changed selects none" "$project/out.log" || fail "--changed did not report the skip: $(cat "$project/out.log")"
printf 'two\n' >>"$project/scripts/lib/beta.sh"
printf '# two\n' >>"$project/tests/gamma-test.sh"
VERIFY_TRUSTED_TREES="" run_changed || fail "--changed with changed files failed: $(cat "$project/out.log")"
[[ "$(sort "$project/tools.log" | paste -sd ' ' -)" == "beta-test gamma-test ruff check ." ]] ||
  fail "--changed selected the wrong self-tests: $(cat "$project/tools.log")"
grep -Fq -- "--changed selects 2 of 4, of the files changed since main: beta, gamma" "$project/out.log" || fail "--changed does not name what it selected: $(cat "$project/out.log")"
[[ ! -e "$project$record" ]] || fail "--changed recorded a pass"
printf 'two\n' >>"$project/scripts/alpha.sh"
git -C "$project" add -A
git -C "$project" commit -qm "Change alpha"
run_changed || fail "--changed with committed changes failed"
grep -Fqx "alpha-test" "$project/tools.log" || fail "--changed missed the test of a committed script change: $(cat "$project/tools.log")"
if grep -Fq "pytest" "$project/tools.log"; then fail "--changed ran a self-test that runs no test file of its own"; fi
# A changed file of scripts/lib/ that is not a shell script selects the
# self-test of the script that names it (lib/delta.jq: gamma.sh), and nothing
# for a file no script names (epsilon.jq); alpha.sh and beta.sh still differ
# from main.
printf '. | .x\n' >>"$project/scripts/lib/delta.jq"
printf '. | .x\n' >>"$project/scripts/lib/epsilon.jq"
run_changed || fail "--changed with a changed jq program failed: $(cat "$project/out.log")"
[[ "$(sort "$project/tools.log" | paste -sd ' ' -)" == "alpha-test beta-test gamma-test ruff check ." ]] ||
  fail "--changed did not select the self-test of the script that reads the changed jq program: $(cat "$project/tools.log")"
grep -Fq -- "--changed selects 3 of 4, of the files changed since main: alpha, beta, gamma" "$project/out.log" || fail "--changed does not name the self-test of the jq program's reader: $(cat "$project/out.log")"
git -C "$project" checkout -q -- scripts/lib/delta.jq scripts/lib/epsilon.jq
for option in --all --reuse "--only default"; do
  # shellcheck disable=SC2086
  if run_changed $option; then fail "--changed was combined with $option"; fi
done

# The self-tests of one script split over parts that source a shared file
# tests/lib-<script>.sh, as tests/run-feature-<part>-test.sh source
# tests/lib-run-feature.sh: a change to the script, or to the shared file,
# selects every part; a change to one part selects that part. A shared file
# of no script (tests/lib-fakes.sh), which every self-test sources, selects
# every self-test; a file in a directory under tests/ (the project's tests)
# selects none.
project="$(setup_recorded_project changed-parts)"
mkdir -p "$project/tests"
printf 'one\n' >"$project/scripts/alpha.sh"
printf '# shared\n' >"$project/tests/lib-alpha.sh"
printf '# fakes\n' >"$project/tests/lib-fakes.sh"
for name in alpha-one alpha-two other; do
  printf '#!/usr/bin/env bash\nsource_root="$(cd "$(dirname "$0")/.." && pwd)"\nsource "$source_root/tests/lib-fakes.sh"\n' >"$project/tests/$name-test.sh"
  [[ "$name" == "other" ]] || printf 'source "$source_root/tests/lib-alpha.sh"\n' >>"$project/tests/$name-test.sh"
  printf 'echo "%s-test" >>"$MOCK_TOOL_LOG"\n' "$name" >>"$project/tests/$name-test.sh"
  chmod +x "$project/tests/$name-test.sh"
done
printf '%s\n' "paths: scripts tests" "alpha-one: ./tests/alpha-one-test.sh" "alpha-two: ./tests/alpha-two-test.sh" \
  "other: ./tests/other-test.sh" >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Self-tests of alpha in two parts"
git -C "$project" checkout -q -b feature/2-parts
expect_parts() {
  local changed="$1"
  local expected="$2"

  printf '# two\n' >>"$project/$changed"
  run_changed || fail "--changed with a changed $changed failed: $(cat "$project/out.log")"
  [[ "$(grep -v '^ruff' "$project/tools.log" | sort | paste -sd ' ' -)" == "$expected" ]] ||
    fail "--changed with a changed $changed selected $(grep -v '^ruff' "$project/tools.log" | sort | paste -sd ' ' -) instead of $expected: $(cat "$project/out.log")"
  git -C "$project" checkout -q -- "$changed"
}
expect_parts scripts/alpha.sh "alpha-one-test alpha-two-test"
expect_parts tests/lib-alpha.sh "alpha-one-test alpha-two-test"
expect_parts tests/alpha-two-test.sh "alpha-two-test"
expect_parts tests/lib-fakes.sh "alpha-one-test alpha-two-test other-test"
mkdir -p "$project/tests/unit"
printf '# unit\n' >"$project/tests/unit/test_app.py"
run_changed || fail "--changed with a changed project test failed: $(cat "$project/out.log")"
[[ "$(grep -c . "$project/tools.log")" -eq 1 ]] || fail "--changed selected a self-test for a project test under tests/unit: $(cat "$project/tools.log")"
rm -rf "$project/tests/unit"

# A changed library selects the self-tests of everything that sources it,
# directly or through another library: scripts/lib/inner.sh is sourced only by
# scripts/lib/outer.sh, which scripts/zeta.sh sources, and directly by the
# test tests/omega-test.sh; scripts/lib/lone.sh is sourced by nothing and
# selects nothing but its own test, which does not exist.
project="$(setup_recorded_project changed-sourced)"
mkdir -p "$project/tests"
printf '# inner\n' >"$project/scripts/lib/inner.sh"
printf '# lone\n' >"$project/scripts/lib/lone.sh"
printf 'source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/inner.sh"\n' >"$project/scripts/lib/outer.sh"
printf 'script_dir="$(dirname "$0")"\nsource "$script_dir/lib/outer.sh"\n' >"$project/scripts/zeta.sh"
for name in zeta omega other; do
  printf '#!/usr/bin/env bash\nsource_root="$(cd "$(dirname "$0")/.." && pwd)"\n' >"$project/tests/$name-test.sh"
  [[ "$name" != "omega" ]] || printf 'source "$source_root/scripts/lib/inner.sh"\n' >>"$project/tests/$name-test.sh"
  printf 'echo "%s-test" >>"$MOCK_TOOL_LOG"\n' "$name" >>"$project/tests/$name-test.sh"
  chmod +x "$project/tests/$name-test.sh"
done
printf '%s\n' "paths: scripts tests" "zeta: ./tests/zeta-test.sh" "omega: ./tests/omega-test.sh" \
  "other: ./tests/other-test.sh" >"$project/scripts/verify-workflow.conf"
git -C "$project" add -A
git -C "$project" commit -qm "Libraries sourced through others"
git -C "$project" checkout -q -b feature/3-sourced
expect_parts scripts/lib/inner.sh "omega-test zeta-test"
expect_parts scripts/lib/outer.sh "zeta-test"
printf '# two\n' >>"$project/scripts/lib/lone.sh"
run_changed || fail "--changed with a changed library that nothing sources failed: $(cat "$project/out.log")"
[[ "$(grep -c . "$project/tools.log")" -eq 1 ]] || fail "--changed selected a self-test for a library that nothing sources: $(cat "$project/tools.log")"
git -C "$project" checkout -q -- scripts/lib/lone.sh

# Parallel runs: 'parallel: <n>' in scripts/verify.conf runs up to <n> checks
# at a time, over the checks of both files; VERIFY_PARALLEL overrides it for
# one run. Without the line, and with 1, the checks run one at a time.
# overlap-check <log> <name>, a check that logs its start and its end:
# max_overlap <log> prints the most checks that ran at the same time.
printf '#!/usr/bin/env bash\necho "start $2" >>"$1"\nsleep 0.4\necho "end $2" >>"$1"\n' >"$tmp/bin/overlap-check"
chmod +x "$tmp/bin/overlap-check"
max_overlap() {
  awk '$1 == "start" { now++; if (now > most) most = now } $1 == "end" { now-- } END { print most + 0 }' "$1"
}
overlap_checks=()
for check in one two three four five; do
  overlap_checks+=("$check: overlap-check overlap.log $check")
done
# expect_overlap <expected> <description> [<parallel-line>]: with VERIFY_PARALLEL from the caller.
expect_overlap() {
  local project

  project="$(setup_project "overlap-$RANDOM" ${3:+"$3"} "${overlap_checks[@]}")"
  run_with "$project" || fail "a run of checks that pass failed ($2): $(cat "$project/out.log")"
  [[ "$(max_overlap "$project/overlap.log")" -eq "$1" ]] ||
    fail "$2: $(max_overlap "$project/overlap.log") checks ran at the same time, not $1: $(cat "$project/overlap.log")"
  [[ "$(grep -c '^start' "$project/overlap.log")" -eq 5 ]] || fail "$2: not every check ran"
}
expect_overlap 1 "without a 'parallel:' line"
expect_overlap 1 "with 'parallel: 1'" "parallel: 1"
expect_overlap 2 "with 'parallel: 2'" "parallel: 2"
expect_overlap 3 "with 'parallel: 3'" "parallel: 3"
VERIFY_PARALLEL=3 expect_overlap 3 "with VERIFY_PARALLEL=3 and no line"
VERIFY_PARALLEL=1 expect_overlap 1 "with VERIFY_PARALLEL=1 over 'parallel: 3'" "parallel: 3"
# The line covers the self-tests too, together with the checks of the project.
project="$(setup_workflow_project parallel-workflow)"
printf '%s\n' "parallel: 4" "${overlap_checks[@]:0:2}" >"$project/scripts/verify.conf"
printf '%s\n' "paths: tools" "${overlap_checks[@]:2}" >"$project/scripts/verify-workflow.conf"
run_with "$project" --all || fail "a parallel run with self-tests failed: $(cat "$project/out.log")"
[[ "$(max_overlap "$project/overlap.log")" -eq 4 ]] ||
  fail "the checks of both files did not share the slots of 'parallel: 4': $(cat "$project/overlap.log")"
grep -Fq "== Workflow self-tests: requested with --all ==" "$project/out.log" || fail "a parallel run did not say why the self-tests run"

# The result is that of a run of one check at a time: a failing check, a
# missing tool, a command that is not found (127), a budget over its target,
# a KNOWN failure of the baseline, and a check that is killed, with the same
# summary in the order of the files and the same exit status.
project="$(setup_project parallel-results "parallel: 4" "slow: sleep 0.5" "lint: ruff check ." "types: tsc --noEmit" \
  "lost: true && no-such-command" "size budget: echo 'over the target'; exit 3" "known: pytest" \
  "killed: kill -KILL \$\$" "fast: true")"
mkdir -p "$project/.agents"
printf 'pass: slow\nfail: known exit 3\npass: lint\n' >"$project/.agents/verification-baseline"
summaries=()
for jobs in 1 4; do
  status=0
  VERIFY_PARALLEL="$jobs" MOCK_RUFF_EXIT=1 MOCK_PYTEST_EXIT=3 run_with "$project" || status=$?
  [[ "$status" -eq 1 ]] || fail "a failing run with VERIFY_PARALLEL=$jobs exited with $status, not 1: $(cat "$project/out.log")"
  summaries+=("$(summary_of "$project")")
done
[[ "${summaries[0]}" == "${summaries[1]}" ]] ||
  fail "a parallel run has another summary than a run of one check at a time:"$'\n'"${summaries[0]}"$'\n'"---"$'\n'"${summaries[1]}"
for expected in "PASS  slow" "FAIL  lint (exit 1): a regression, it passed in the baseline" "FAIL  types (missing tool: tsc)" \
  "FAIL  lost (exit 127, a command was not found)" "BUDGET  size (exit 3)" "KNOWN  known (exit 3)" "FAIL  killed (exit 137)" "PASS  fast"; do
  grep -Fq -- "$expected" <<<"${summaries[1]}" || fail "the parallel summary lacks '$expected': ${summaries[1]}"
done
[[ "$(grep -E '^(PASS|FAIL|BUDGET|KNOWN) ' <<<"${summaries[1]}" | awk '{ print $2 }' | paste -sd ' ' -)" == "slow lint types lost size known killed fast" ]] ||
  fail "the parallel summary does not keep the order of the file: ${summaries[1]}"
# The check whose tool is missing is one block too, with its duration, in
# both runs.
for jobs in 1 4; do
  VERIFY_PARALLEL="$jobs" MOCK_RUFF_EXIT=1 MOCK_PYTEST_EXIT=3 run_with "$project" || true
  block="$(sed -n '/^-- types: tsc --noEmit$/,/^-- types took /p' "$project/out.log")"
  grep -Fxq -- "-- types took 0.0s" <<<"$block" &&
    grep -Fxq "Error: required check 'types' cannot run; 'tsc' is missing or not executable." <<<"$block" ||
    fail "with VERIFY_PARALLEL=$jobs the block of the check with a missing tool lacks its error or duration: $(cat "$project/out.log")"
done
# A run in which every check passes passes, also in parallel.
project="$(setup_project parallel-pass "parallel: 3" "lint: ruff check ." "tests: pytest" "slow: sleep 0.3")"
run_with "$project" || fail "a parallel run of passing checks failed: $(cat "$project/out.log")"
grep -Fxq "Verification passed." "$project/out.log" || fail "a parallel run that passed did not say so"
grep -Eq '^-- 3 checks, up to 3 at a time, took [0-9]+\.[0-9]s wall-clock; their durations add up to [0-9]+\.[0-9]s$' "$project/out.log" ||
  fail "a parallel run did not report its wall-clock time: $(cat "$project/out.log")"

# A check does not inherit VERIFY_PARALLEL: a verify.sh that it starts, as a
# self-test does, runs its own fixture as that fixture's line says.
project="$(setup_project parallel-inherit "plain: test -z \"\${VERIFY_PARALLEL+set}\"" "other: true")"
VERIFY_PARALLEL=2 run_with "$project" || fail "a check inherited VERIFY_PARALLEL: $(cat "$project/out.log")"

# The output does not interleave: the output of each check is one block,
# its header, everything it printed, and its duration, when it ends.
printf '#!/usr/bin/env bash\nfor step in 1 2 3 4; do echo "$1 $step"; echo "$1 error $step" >&2; sleep 0.1; done\n' >"$tmp/bin/chatty"
chmod +x "$tmp/bin/chatty"
project="$(setup_project parallel-blocks "parallel: 3" "alpha: chatty alpha" "beta: chatty beta" "gamma: chatty gamma")"
run_with "$project" || fail "a parallel run of chatty checks failed: $(cat "$project/out.log")"
for check in alpha beta gamma; do
  block="$(sed -n "/^-- $check: chatty $check\$/,/^-- $check took /p" "$project/out.log")"
  [[ "$(grep -c . <<<"$block")" -eq 10 ]] && ! grep -Ev "^(-- $check|$check )" <<<"$block" >/dev/null ||
    fail "the output of $check is not one block of its own: $(cat "$project/out.log")"
done

# The durations are recorded in the order of the files, whichever check ends
# first, and the target of a file's duration shows the wall-clock time next
# to the sum.
project="$(setup_recorded_project parallel-durations)"
printf '%s\n' "parallel: 3" "budget-seconds: 1" "slow: sleep 0.8" "lint: ruff check ." "medium: sleep 0.6" >"$project/scripts/verify.conf"
git -C "$project" commit -qam "Parallel checks"
run_with "$project" || fail "a parallel run over its duration target failed: $(cat "$project/out.log")"
[[ "$(cut -f1 "$project$durations" | paste -sd ' ' -)" == "slow lint medium" ]] ||
  fail "a parallel run did not record the durations in the order of the file: $(cat "$project$durations")"
grep -Eq '^BUDGET  duration of scripts/verify\.conf \(1\.[0-9]s, 0\.[0-9]s wall-clock, target 1s\)$' "$project/out.log" ||
  fail "the duration target of a parallel run does not show the wall-clock time: $(summary_of "$project")"
[[ -s "$project$record" ]] || fail "a parallel run that passed was not recorded"
run_with "$project" --reuse && grep -Fq "already passed" "$project/out.log" || fail "the pass of a parallel run was not reused"

# A parallel run that is terminated stops the checks that still run.
printf '#!/usr/bin/env bash\necho $$ >>"$1"\nsleep 30\n' >"$tmp/bin/long-check"
chmod +x "$tmp/bin/long-check"
project="$(setup_project parallel-term "parallel: 2" "first: long-check pids" "second: long-check pids")"
PATH="$tmp/bin:/usr/bin:/bin" "$project/scripts/verify.sh" >"$project/out.log" 2>&1 &
runner=$!
for ((waited = 0; waited < 100; waited++)); do
  [[ "$(grep -c . "$project/pids" 2>/dev/null)" -lt 2 ]] || break
  sleep 0.1
done
[[ "$(grep -c . "$project/pids" 2>/dev/null)" -eq 2 ]] || fail "the checks of a parallel run did not start together"
kill -TERM "$runner"
status=0
wait "$runner" || status=$?
[[ "$status" -ne 0 ]] || fail "a terminated parallel run passed"
while IFS= read -r pid; do
  ! kill -0 "$pid" 2>/dev/null || fail "a check of a terminated parallel run still runs (PID $pid)"
done <"$project/pids"

# The line is exact: a whole number above 0, once, no group, no budget, and
# only in scripts/verify.conf; VERIFY_PARALLEL is a whole number above 0.
for line in "parallel: 0" "parallel: two" "parallel: 1.5" "parallel [code]: 2" "parallel budget: 2"; do
  project="$(setup_project "parallel-refused-$RANDOM" "$line" "lint: ruff check .")"
  expect_failure "$project" "'$line' must be refused"
  grep -Fq "'parallel'" "$project/out.log" || fail "the refusal of '$line' did not say why: $(cat "$project/out.log")"
done
project="$(setup_project parallel-twice "parallel: 2" "parallel: 3" "lint: ruff check .")"
expect_failure "$project" "'parallel' twice must be refused"
grep -Fq "declared more than once" "$project/out.log" || fail "the refusal of a second 'parallel' did not say why"
project="$(setup_workflow_project parallel-in-workflow)"
printf '%s\n' "parallel: 2" "paths: tools" "self-test: pytest" >"$project/scripts/verify-workflow.conf"
if run_with "$project" --all; then fail "'parallel' in scripts/verify-workflow.conf was accepted"; fi
grep -Fq "'parallel' is declared in scripts/verify.conf only" "$project/out.log" || fail "the refusal of 'parallel' in the self-tests did not say why: $(cat "$project/out.log")"
project="$(setup_project parallel-variable "lint: ruff check .")"
if VERIFY_PARALLEL=many run_with "$project"; then fail "VERIFY_PARALLEL=many was accepted"; fi
grep -Fq "VERIFY_PARALLEL needs a whole number" "$project/out.log" || fail "the refusal of VERIFY_PARALLEL did not say why"

# Every self-test passes through tests/lib-fakes.sh before it starts anything.
for test in "$source_root"/tests/*-test.sh; do
  grep -Eq '^source "\$(source_)?root/tests/lib-fakes\.sh"$' "$test" ||
    fail "${test#"$source_root/"} does not source tests/lib-fakes.sh"
done
echo "verify tests passed"
