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

# base_merge_conflicts merges in memory: the tree of a clean merge, the files
# of a conflicting one, and the worktree untouched either way.
rm -f "$repo/.agents/template.conf"
git -C "$repo" checkout -q main
printf 'base\n' >"$repo/shared.txt"
git -C "$repo" add shared.txt
git -C "$repo" commit -qm "Base"
git -C "$repo" checkout -q -b feature/3-merge HEAD~1
printf 'feature\n' >"$repo/own.txt"
git -C "$repo" add own.txt
git -C "$repo" commit -qm "Feature"
tree="$(base_merge_conflicts "$repo" main)" || fail "a clean merge was reported as conflicting"
git -C "$repo" cat-file -e "$tree^{tree}" || fail "a clean merge did not print its tree"
[[ ! -e "$repo/shared.txt" ]] || fail "the merge in memory changed the worktree"
printf 'mine\n' >"$repo/shared.txt"
git -C "$repo" add shared.txt
git -C "$repo" commit -qm "Conflicting"
status=0
conflicts="$(base_merge_conflicts "$repo" main)" || status=$?
[[ "$status" -eq 1 && "$conflicts" == "shared.txt" ]] || fail "the conflicting file was not named: $status $conflicts"
grep -Fqx "mine" "$repo/shared.txt" || fail "a conflicting merge in memory changed the worktree"

# base_merge_overwrites: the untracked paths, ignored ones included, that a
# clean merge would write over; merge-tree reports such a merge as clean.
git -C "$repo" checkout -q main
printf 'cache.txt\nlink\n' >"$repo/.gitignore"
printf 'base\n' >"$repo/cache.txt"
mkdir -p "$repo/link"
printf 'base\n' >"$repo/link/inside.txt"
git -C "$repo" add .gitignore
git -C "$repo" add -f cache.txt link/inside.txt
git -C "$repo" commit -qm "Base adds ignored paths"
git -C "$repo" checkout -q -b feature/4-ignored HEAD~1
rm -rf "$repo/link"
printf 'local\n' >"$repo/cache.txt"
printf 'local\n' >"$repo/link"
tree="$(base_merge_conflicts "$repo" main)" || fail "a merge over ignored files was reported as conflicting"
[[ "$(base_merge_overwrites "$repo" "$tree")" == "$(printf 'cache.txt\nlink')" ]] ||
  fail "the ignored paths in the way are not named: $(base_merge_overwrites "$repo" "$tree")"
rm -f "$repo/cache.txt" "$repo/link"
[[ -z "$(base_merge_overwrites "$repo" "$tree")" ]] || fail "a merge that writes over nothing names a path"

# base_leftovers: untracked paths that the ignore rules of a commit ignored
# and that Git does not ignore now. A directory is named as a whole when all
# of it is such a leftover, its files otherwise; other untracked work is no
# leftover, and base_uncommitted_work reports only that.
printf 'old/build/\nmixed/*.log\n' >"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm "Ignore the builds"
before="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$repo/old/build" "$repo/mixed"
printf 'x\n' >"$repo/old/build/app.js"
printf 'x\n' >"$repo/mixed/run.log"
[[ -z "$(base_leftovers "$repo" "$before" "$tmp")" ]] || fail "an ignored path counts as a leftover while it is ignored"
printf 'new/build/\n' >"$repo/.gitignore"
git -C "$repo" commit -qam "The base no longer ignores them"
printf 'mine\n' >"$repo/mixed/notes.txt"
leftovers="$(base_leftovers "$repo" "$before" "$tmp")"
[[ "$leftovers" == "$(printf 'mixed/run.log\nold/')" ]] || fail "the leftovers are not named as expected: $leftovers"
[[ "$(base_uncommitted_work "$repo" "$before" "$tmp")" == "?? mixed/notes.txt" ]] ||
  fail "the uncommitted work is not the untracked file alone: $(base_uncommitted_work "$repo" "$before" "$tmp")"
[[ -n "$(base_uncommitted_work "$repo" HEAD "$tmp")" ]] || fail "leftovers by the rules of HEAD are no uncommitted work"
base_leftover_report "old/" | grep -Fqx "  old/    remove with: rm -rf -- old/" || fail "the removal command was not printed"
[[ -f "$repo/old/build/app.js" ]] || fail "a leftover was deleted"

echo "base tests passed"
