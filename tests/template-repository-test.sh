#!/usr/bin/env bash

set -euo pipefail

# The framework-only self-tests (Issue 461): scripts/lib/template-repository.sh
# tells the template from a project, ./scripts/verify.sh skips a check marked
# 'framework' only in a repository that is positively not the template, with
# a SKIP line and the record 'framework-checks: skipped', and runs it with a
# doubt or with --framework-checks; the job 'scope' of
# .github/workflows/ci.yml decides with the same predicate, and in a project
# the group job of a framework-only group passes with the SKIP line, so the
# aggregate check-ci-groups.sh --results passes.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/template-repository-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$tmp"' EXIT

fail() {
  echo "template repository test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/template-repository.sh"

# ---------------------------------------------------------------- the URLs
expect_url() {
  local actual
  actual="$(template_repository_url "$1")" || fail "'$1' was not taken for the URL of a repository"
  [[ "$actual" == "$2" ]] || fail "'$1' is '$actual', expected '$2'"
}
expect_no_url() {
  if template_repository_url "$1" >/dev/null; then fail "'$1' was taken for the URL of a repository"; fi
}
expect_url https://github.com/Owner/Template github.com/owner/template
expect_url https://github.com/owner/template.git/ github.com/owner/template
expect_url "  https://github.com/owner/template  " github.com/owner/template
expect_url https://x-access-token:secret@github.com/owner/template.git github.com/owner/template
expect_url git@github.com:owner/template.git github.com/owner/template
expect_url ssh://git@github.com:22/owner/template github.com/owner/template
expect_url http://gitlab.example.com/group/sub/template gitlab.example.com/group/sub/template
expect_no_url /srv/git/template
expect_no_url ../template
expect_no_url file:///srv/git/template.git
expect_no_url github:owner/template
expect_no_url ""
expect_no_url https://github.com/

# ---------------------------------------------------------------- the roles
# repo <name> [<template-repository>] [<origin>]: a Git repository with a
# template.conf naming <template-repository> (none when '-') and the origin
# <origin> (none when absent).
repo() {
  local dir="$tmp/roles/$1"
  mkdir -p "$dir/.agents"
  git -C "$dir" init -q -b main
  if [[ "${2:--}" != "-" ]]; then
    printf '# The template.\nrepository: %s\n\npaths: scripts\n' "$2" >"$dir/.agents/template.conf"
  fi
  if [[ -n "${3:-}" ]]; then
    git -C "$dir" remote add origin "$3"
  fi
  printf '%s\n' "$dir"
}
expect_role() {
  local output
  output="$(template_repository_role "${@:2}")"
  [[ "${output%%$'\n'*}" == "$1" ]] || fail "the role of ${2#"$tmp"/} is '${output%%$'\n'*}', expected '$1': $output"
  [[ "$output" == *$'\n'?* ]] || fail "the role of ${2#"$tmp"/} gives no reason: $output"
}
expect_role template "$(repo template https://github.com/owner/template https://github.com/Owner/Template.git)"
expect_role template "$(repo template-ssh https://github.com/owner/template git@github.com:owner/template.git)"
expect_role project "$(repo project https://github.com/owner/template https://github.com/owner/project)"
expect_role project "$(repo project-ssh https://github.com/owner/template.git git@github.com:owner/project.git)"
# A doubt is never a project.
expect_role unknown "$(repo no-conf - https://github.com/owner/project)"
dir="$(repo no-repository - https://github.com/owner/project)"
printf 'paths: scripts\n' >"$dir/.agents/template.conf"
expect_role unknown "$dir"
expect_role unknown "$(repo local-template /srv/git/template https://github.com/owner/project)"
expect_role unknown "$(repo no-origin https://github.com/owner/template)"
expect_role unknown "$(repo local-origin https://github.com/owner/template "$tmp/remote.git")"
expect_role unknown "$(repo alias-origin https://github.com/owner/template github:owner/template)"
# An origin that cannot be read: no Git repository at all.
mkdir -p "$tmp/roles/not-git/.agents"
printf 'repository: https://github.com/owner/template\n' >"$tmp/roles/not-git/.agents/template.conf"
expect_role unknown "$tmp/roles/not-git"
# The repository given, as CI gives it, decides instead of the origin.
dir="$(repo given https://github.com/owner/template https://github.com/owner/project)"
expect_role template "$dir" https://github.com/owner/template
expect_role project "$(repo given-project https://github.com/owner/template)" https://github.com/owner/project
expect_role unknown "$dir" ""
# No token of the origin reaches the reason.
output="$(template_repository_role "$(repo token https://github.com/owner/template https://secret-token@github.com/owner/project.git)")"
[[ "$output" != *secret-token* ]] || fail "the reason shows the credential of the origin: $output"

# ---------------------------------------------------------- verify.sh
# project <name> <origin> [<template-repository>]: a repository with
# verify.sh, its libraries, a project check, and two self-tests: 'framework'
# (framework-only, group fw) and 'plain' (group plain). Each records in
# checks.log that it ran.
project() {
  local dir="$tmp/verify/$1"
  mkdir -p "$dir/scripts/lib" "$dir/tests" "$dir/.agents"
  cp "$source_root/scripts/verify.sh" "$dir/scripts/"
  cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" \
    "$source_root/scripts/lib/template-repository.sh" "$dir/scripts/lib/"
  cp "$source_root/scripts/check-ci-groups.sh" "$dir/scripts/"
  printf 'lint: true\n' >"$dir/scripts/verify.conf"
  printf 'paths: tests scripts/verify-workflow.conf\nframework [fw] framework: ./tests/framework-test.sh\nplain [plain]: ./tests/plain-test.sh\n' \
    >"$dir/scripts/verify-workflow.conf"
  for name in framework plain; do
    printf '#!/usr/bin/env bash\necho %s >>checks.log\n' "$name" >"$dir/tests/$name-test.sh"
    chmod +x "$dir/tests/$name-test.sh"
  done
  printf '*.log\n.agents/verification/\n' >"$dir/.gitignore"
  if [[ "${3:--}" != "-" ]]; then
    printf 'repository: %s\n\npaths: scripts tests\n' "$3" >"$dir/.agents/template.conf"
  fi
  git -C "$dir" init -q -b main
  git -C "$dir" add -A
  git -C "$dir" -c user.name=Test -c user.email=test@example.com commit -qm "The project"
  [[ -z "$2" ]] || git -C "$dir" remote add origin "$2"
  printf '%s\n' "$dir"
}
# verify <dir> <option>...: runs verify.sh; its output is in <dir>/out.
verify() {
  local dir="$1"
  shift
  rm -f "$dir/checks.log"
  (cd "$dir" && PATH="$ISOLATED_PATH" RECORDS_DISABLED=1 ./scripts/verify.sh "$@") >"$dir/out.log" 2>&1
}
ran() {
  grep -Fqx "$2" "$1/checks.log" 2>/dev/null
}
field() {
  sed -n "s/^$2: //p" "$1/.agents/verification/passed" 2>/dev/null | head -n 1
}
skip_line() {
  grep -E '^SKIP +framework \(framework-only\): ' "$1/out.log" || true
}
template_url=https://github.com/example/template

# A project: the framework-only check is skipped with the reason and recorded.
dir="$(project project https://github.com/example/project.git "$template_url")"
verify "$dir" --all || { cat "$dir/out.log" >&2; fail "verify.sh --all failed in a project"; }
ran "$dir" plain || fail "the self-test that is not framework-only did not run in a project"
if ran "$dir" framework; then fail "the framework-only self-test ran in a project"; fi
line="$(skip_line "$dir")"
[[ "$line" == *"this repository (github.com/example/project) is not the template that .agents/template.conf names (github.com/example/template)"* ]] ||
  fail "the SKIP line does not give the reason: $(cat "$dir/out.log")"
[[ "$line" == *"--framework-checks"* ]] || fail "the SKIP line does not name the option that runs it: $line"
[[ "$(field "$dir" workflow-tests)" == ran ]] || fail "the record does not say that the self-tests ran"
[[ "$(field "$dir" framework-checks)" == skipped ]] || fail "the record does not say that the framework-only self-tests were skipped: $(cat "$dir/.agents/verification/passed")"

# The pass is reused for a run that skips them too, not for one that runs them.
verify "$dir" --all --reuse || fail "verify.sh --all --reuse failed in a project"
grep -Fq "Verification already passed for this content" "$dir/out.log" || fail "the pass was not reused: $(cat "$dir/out.log")"
verify "$dir" --all --reuse --framework-checks || { cat "$dir/out.log" >&2; fail "verify.sh --framework-checks failed in a project"; }
grep -Fq "it skipped the framework-only self-tests" "$dir/out.log" || fail "the skipping pass stood in for --framework-checks: $(cat "$dir/out.log")"
ran "$dir" framework || fail "--framework-checks did not run the framework-only self-test"
[[ -z "$(skip_line "$dir")" ]] || fail "--framework-checks reported a skip"
[[ "$(field "$dir" framework-checks)" == ran ]] || fail "the record does not say that the framework-only self-tests ran"
# A pass that ran them stands in for a run that skips them.
verify "$dir" --all --reuse || fail "verify.sh --all --reuse failed after --framework-checks"
grep -Fq "Verification already passed for this content" "$dir/out.log" || fail "the pass that ran them was not reused: $(cat "$dir/out.log")"

# The group of a framework-only check alone: the partial run passes with the
# SKIP line and runs nothing; --framework-checks runs it.
verify "$dir" --all --only fw || { cat "$dir/out.log" >&2; fail "verify.sh --all --only fw failed in a project"; }
[[ ! -e "$dir/checks.log" ]] || fail "--only fw ran a check in a project: $(cat "$dir/checks.log")"
[[ -n "$(skip_line "$dir")" ]] || fail "--only fw did not report the skip: $(cat "$dir/out.log")"
verify "$dir" --all --only fw --framework-checks || fail "verify.sh --all --only fw --framework-checks failed"
ran "$dir" framework || fail "--only fw --framework-checks did not run the framework-only self-test"

# --changed: a framework-only self-test that a change selects is skipped too.
git -C "$dir" checkout -q -b feature/1-change
printf '# changed\n' >>"$dir/tests/framework-test.sh"
printf '# changed\n' >>"$dir/tests/plain-test.sh"
verify "$dir" --changed || { cat "$dir/out.log" >&2; fail "verify.sh --changed failed in a project"; }
ran "$dir" plain || fail "--changed did not run the selected self-test"
if ran "$dir" framework; then fail "--changed ran the framework-only self-test in a project"; fi
[[ -n "$(skip_line "$dir")" ]] || fail "--changed did not report the skip: $(cat "$dir/out.log")"
verify "$dir" --changed --framework-checks || fail "verify.sh --changed --framework-checks failed"
ran "$dir" framework || fail "--changed --framework-checks did not run the framework-only self-test"

# expect_runs <dir> <description>: the framework-only check runs with --all.
expect_runs() {
  verify "$1" --all || { cat "$1/out.log" >&2; fail "verify.sh --all failed: $2"; }
  ran "$1" framework || fail "the framework-only self-test did not run: $2"
  ran "$1" plain || fail "the other self-test did not run: $2"
  [[ -z "$(skip_line "$1")" ]] || fail "a skip was reported: $2"
  grep -Fq "the framework-only self-tests run" "$1/out.log" || fail "the run does not say why they run: $2: $(cat "$1/out.log")"
  [[ "$(field "$1" framework-checks)" == ran ]] || fail "the record does not say that they ran: $2"
}
expect_runs "$(project template git@github.com:Example/Template.git "$template_url")" "in the template"
expect_runs "$(project no-conf https://github.com/example/project -)" "without .agents/template.conf"
expect_runs "$(project no-origin "" "$template_url")" "without an origin"
expect_runs "$(project local-origin "$tmp/remote.git" "$template_url")" "with an origin that is a local path"
expect_runs "$(project local-template https://github.com/example/project /srv/git/template)" "with a template named by a local path"
dir="$(project unreadable https://github.com/example/project "$template_url")"
git -C "$dir" config remote.origin.url ""
expect_runs "$dir" "with an origin whose URL is empty"
dir="$(project no-library https://github.com/example/project "$template_url")"
rm "$dir/scripts/lib/template-repository.sh"
expect_runs "$dir" "without scripts/lib/template-repository.sh"

# Without --all and without a changed workflow file no self-test runs, and
# no framework-only line is added to the SKIP of the self-tests.
dir="$(project unchanged https://github.com/example/project "$template_url")"
git -C "$dir" checkout -q -b feature/2-change
verify "$dir" || { cat "$dir/out.log" >&2; fail "verify.sh failed without a workflow change"; }
[[ ! -e "$dir/checks.log" ]] || fail "a self-test ran without a workflow change"
[[ -z "$(skip_line "$dir")" ]] || fail "a framework-only skip was reported although no self-test ran"
[[ "$(field "$dir" framework-checks)" == none ]] || fail "the record of a run without self-tests does not say 'none'"

# The marker belongs to the self-tests only, and to checks only.
dir="$(project in-project-conf https://github.com/example/project "$template_url")"
printf 'lint [default] framework: true\n' >"$dir/scripts/verify.conf"
if verify "$dir" --all; then fail "a framework-only check of scripts/verify.conf was accepted"; fi
grep -Fq "'framework' marks a self-test of scripts/verify-workflow.conf" "$dir/out.log" || fail "the refusal does not say why: $(cat "$dir/out.log")"
dir="$(project reserved https://github.com/example/project "$template_url")"
printf 'budget-seconds framework: 600\n' >>"$dir/scripts/verify-workflow.conf"
if verify "$dir" --all; then fail "a framework-only budget-seconds was accepted"; fi
if (cd "$dir" && PATH="$ISOLATED_PATH" ./scripts/verify.sh --groups --framework-checks) >/dev/null 2>&1; then
  fail "--groups took --framework-checks"
fi

# ---------------------------------------------------------------- CI
# The template's ci.yml only: a project's own CI, which runs no verify.sh
# or has no job group-adopted-project, is not the template's, and the
# fixture of adopted-project has one (sync-template-test.sh does the same).
ci_workflow="$source_root/.github/workflows/ci.yml"
if [[ ! -f "$ci_workflow" ]] || ! grep -Fq 'scripts/verify.sh' "$ci_workflow" || ! grep -Eq '^  group-adopted-project:' "$ci_workflow"; then
  echo "template repository tests passed (without the CI of the template, which this repository does not have)"
  exit 0
fi
# ci_run_script <job> <marker>: the 'run: |' block of the step of the job
# <job> of ci.yml that has a line with <marker>, without its indentation.
ci_run_script() {
  awk -v job="$1" -v marker="$2" '
    /^[^[:space:]#]/ { injob = 0 }
    /^  [^[:space:]#]/ { injob = ($0 ~ "^  " job ":") }
    !injob { next }
    /^      - / { if (hit) exit; body = ""; hit = 0; inrun = 0 }
    inrun {
      line = $0
      sub(/^          /, "", line)
      body = body line "\n"
    }
    /^        run: \|[[:space:]]*$/ { inrun = 1 }
    index($0, marker) { hit = 1 }
    END { if (hit) printf "%s", body }
  ' "$ci_workflow"
}
scope_script="$(ci_run_script scope 'id: scope')"
[[ "$scope_script" == *template_repository_role* ]] || fail "the job scope of ci.yml does not decide with scripts/lib/template-repository.sh: $scope_script"
grep -Fq 'scripts/lib/template-repository.sh' <<<"$(sed -n '/^  scope:/,/^  [a-z]/p' "$ci_workflow")" ||
  fail "the sparse checkout of the job scope does not bring scripts/lib/template-repository.sh"
# ci_scope <dir> <repository> <event>: the scope that the step decides.
ci_scope() {
  : >"$tmp/github-output"
  (cd "$1" && EVENT="$3" REPOSITORY="$2" GITHUB_OUTPUT="$tmp/github-output" bash -eo pipefail -c "$scope_script") >/dev/null ||
    fail "the scope step of ci.yml failed in ${1#"$tmp"/}"
  sed -n 's/^verify=//p' "$tmp/github-output"
}
project_dir="$(project ci-project https://github.com/example/project "$template_url")"
template_dir="$(project ci-template https://github.com/example/template "$template_url")"
[[ "$(ci_scope "$project_dir" https://github.com/example/project pull_request)" == changed ]] ||
  fail "the scope step takes the project for the template"
[[ "$(ci_scope "$template_dir" https://github.com/Example/Template pull_request)" == all ]] ||
  fail "the scope step does not take the template for the template"
[[ "$(ci_scope "$template_dir" https://github.com/example/template schedule)" == none ]] ||
  fail "the scope step runs the nightly verification of the template"

# The group job of the framework-only group, as ci.yml runs it in the
# project: it passes with the SKIP line, so the job succeeds and the
# aggregate check passes; in the template it runs the check.
verify_script="$(ci_run_script group-adopted-project 'scripts/verify.sh')"
[[ -n "$verify_script" ]] || fail "the job group-adopted-project of ci.yml has no step that runs verify.sh"
ci_group() {
  rm -f "$1/checks.log"
  (cd "$1" && PATH="$ISOLATED_PATH" RECORDS_DISABLED=1 SCOPE=all VERIFY_GROUP=fw bash -eo pipefail -c "$verify_script") >"$1/out.log" 2>&1
}
ci_group "$project_dir" || { cat "$project_dir/out.log" >&2; fail "the group job of a framework-only group failed in a project"; }
[[ ! -e "$project_dir/checks.log" ]] || fail "the group job ran the framework-only check in a project"
[[ -n "$(skip_line "$project_dir")" ]] || fail "the group job did not explain the skip: $(cat "$project_dir/out.log")"
ci_group "$template_dir" || { cat "$template_dir/out.log" >&2; fail "the group job failed in the template"; }
ran "$template_dir" framework || fail "the group job did not run the framework-only check in the template"
# needs <result of group-fw>: the needs of the aggregate job.
needs() {
  printf '{"scope":{"result":"success"},"group-default":{"result":"success"},"group-fw":{"result":"%s"},"group-plain":{"result":"success"}}' "$1"
}
(cd "$project_dir" && PATH="$ISOLATED_PATH" ./scripts/check-ci-groups.sh --results "$(needs success)") >"$tmp/results.out" 2>&1 ||
  fail "the aggregate check failed with the group job that skipped its check: $(cat "$tmp/results.out")"
grep -Fq "PASS  every required job succeeded" "$tmp/results.out" || fail "the aggregate check did not pass: $(cat "$tmp/results.out")"
# A group job that GitHub skipped is still no pass: the skip is the check's.
if (cd "$project_dir" && PATH="$ISOLATED_PATH" ./scripts/check-ci-groups.sh --results "$(needs skipped)") >"$tmp/results.out" 2>&1; then
  fail "the aggregate check passed with a skipped group job"
fi

echo "template repository tests passed"
