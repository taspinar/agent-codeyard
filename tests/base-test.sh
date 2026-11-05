#!/usr/bin/env bash

set -euo pipefail

# The base branch of a feature (scripts/lib/base.sh): the recorded base of the
# branch, else the default of the project in .agents/template.conf, else main.
# The end-to-end case, a project whose features use 'develop', is in
# run-feature-test.sh; publish-feature-test.sh covers the pull request.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/base-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "base test failed: $*" >&2
  exit 1
}

source "$source_root/scripts/lib/base.sh"

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name "Base Test"
git -C "$repo" config user.email "base-test@example.com"
git -C "$repo" commit -q --allow-empty -m "Seed"
git -C "$repo" checkout -q -b feature/1-thing

# Without the line, and without a template.conf, the default is main.
[[ "$(project_base "$repo")" == "main" ]] || fail "the default without template.conf is not main"
mkdir -p "$repo/.agents"
printf 'repository: https://example.com/template\n\npaths: scripts\n' >"$repo/.agents/template.conf"
[[ "$(project_base "$repo")" == "main" ]] || fail "the default without a base line is not main"
[[ "$(branch_base "$repo")" == "main" ]] || fail "a branch without a recorded base does not fall back to main"

# The line sets the default of the project, with trailing spaces ignored.
printf 'base:   develop  \n' >>"$repo/.agents/template.conf"
[[ "$(project_base "$repo")" == "develop" ]] || fail "the base line of template.conf is not the default"
[[ "$(branch_base "$repo")" == "develop" ]] || fail "a branch without a recorded base does not take the project default"

# A recorded base wins over the default, for the current or a named branch.
git -C "$repo" config branch.feature/1-thing.workflow-base release/2
[[ "$(branch_base "$repo")" == "release/2" ]] || fail "the recorded base of the current branch is not used"
[[ "$(branch_base "$repo" feature/1-thing)" == "release/2" ]] || fail "the recorded base of a named branch is not used"
[[ "$(branch_base "$repo" feature/2-other)" == "develop" ]] || fail "another branch took the recorded base of the current one"

# A line that names no valid branch is refused, not used.
printf 'base: not..a branch\n' >"$repo/.agents/template.conf"
if output="$(project_base "$repo" 2>&1)"; then fail "an invalid default base was accepted: $output"; fi
grep -Fq "not a valid branch name: not..a branch" <<<"$output" || fail "the invalid default base was not explained: $output"
if branch_base "$repo" feature/2-other >/dev/null 2>&1; then fail "an invalid default base was used for a branch without a record"; fi

echo "base tests passed"
