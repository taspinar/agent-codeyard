#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

usage() {
  echo "Usage: $0 <issue-number> [--wait]"
  echo
  echo "Run in the feature worktree of a finished feature, after finish-feature.sh,"
  echo "when its base branch moved on: for example when the pull request shows a"
  echo "conflict or is behind its base. Brings the branch up to date and publishes"
  echo "it again:"
  echo
  echo "1. fetches the base of the feature (origin/<base>, as start-feature.sh"
  echo "   recorded it), and merges it into the branch when the branch does not"
  echo "   contain it yet. A merge that conflicts stops before anything changed, with"
  echo "   the conflicting files and the commands that continue. So does a merge that"
  echo "   would write over an untracked file, also one that Git ignores, and staged"
  echo "   changes in the index: the files are named, and the index is left as it is;"
  echo "2. runs the full verification, ./scripts/verify.sh --all --reuse: a run that"
  echo "   passed for exactly this content is not repeated;"
  echo "3. publishes again with publish-feature.sh, which pushes the branch and takes"
  echo "   the description, the completion statement, and the approval request from"
  echo "   the finish commit: the merge of the base is passed over, so the approval"
  echo "   the owner is asked for still covers the content of the finish commit."
  echo
  echo "Nothing is pushed when a step fails. Untracked paths that the branch ignored at"
  echo "its finish commit and the merged base no longer ignores, such as the build"
  echo "directory of a renamed site, are reported with the command that removes them;"
  echo "nothing is deleted. Running the command again continues where it stopped."
  echo
  echo "--wait is passed on to publish-feature.sh: it waits for the checks of the"
  echo "pull request."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  records_stop "${0##*/}" "$*"
  exit 1
}

[[ $# -ge 1 ]] || usage
issue="$1"
shift
publish_options=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) publish_options+=(--wait) ;;
    *) usage ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/base.sh"
source "$script_dir/lib/guardrails.sh"
[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
records_wrap feature "$issue" "$0" ${records_arguments[@]+"${records_arguments[@]}"}

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" == feature/${issue}-* ]] ||
  fail "update-feature.sh must run on feature/${issue}-*. Current branch: $branch"
base="$(branch_base "$root" "$branch")" || exit 1
base_ref="origin/$base"

# A merge that a run before this one left for the human to complete.
if git -C "$root" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
  unmerged="$(git -C "$root" diff --name-only --diff-filter=U)"
  if [[ -n "$unmerged" ]]; then
    fail "a merge is in progress with conflicts in: $(printf '%s' "$unmerged" | tr '\n' ' ')- resolve them, then 'git add' them, 'git commit --no-edit', and run ./scripts/update-feature.sh $issue again. Nothing was pushed."
  fi
  fail "a merge is in progress and has no conflicts left: complete it with 'git commit --no-edit', and run ./scripts/update-feature.sh $issue again. Nothing was pushed."
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/update-feature.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

echo "Fetching $base..."
git -C "$root" fetch -q origin "$base" || fail "could not fetch '$base' from origin. Nothing was changed."
git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null ||
  fail "the base of the feature, $base_ref, does not exist."

# The finished feature: the commit that finish-feature.sh made, before the
# merges of the base that brought it up to date already (lib/guardrails.sh).
finish_commit="$(guardrails_finish_after_fixes "$root" "$issue" HEAD "$base_ref" "$base" | sed -n 1p)"
if ! git -C "$root" log -1 --format=%B "$finish_commit" | grep -q '^Completion: ' &&
  [[ -z "$(git -C "$root" log -1 --format=%H --grep='^Completion: ' "$base_ref..HEAD")" ]]; then
  fail "the feature is not finished: no commit of the branch was made by finish-feature.sh. Finish it first: ./scripts/finish-feature.sh $issue \"<commit summary>\""
fi

# check_worktree: stops on uncommitted work, which neither the merge nor the
# publication takes, and on what an earlier merge of the base left behind,
# which the verification would count as content of the feature.
check_worktree() {
  local staged
  local uncommitted
  local leftovers

  # Staged changes first: a merge refuses them, and unstaging them would lose
  # a staged version that differs from the file on disk.
  staged="$(git -C "$root" -c core.quotePath=false diff --cached --name-only)" ||
    fail "could not determine whether the index holds staged changes."
  if [[ -n "$staged" ]]; then
    echo "Staged in the index:" >&2
    printf '%s\n' "$staged" | sed 's/^/  /' >&2
    fail "the index holds staged changes, which a merge of $base_ref refuses. Commit them (./scripts/finish-feature.sh $issue \"<commit summary>\" for work of the feature), or unstage them with 'git restore --staged <path>' when the file on disk holds what you want. Nothing was merged or pushed, and the index is unchanged."
  fi
  uncommitted="$(base_uncommitted_work "$root" "$finish_commit" "$scratch")" ||
    fail "could not determine whether the worktree has uncommitted changes."
  if [[ -n "$uncommitted" ]]; then
    echo "Uncommitted changes in the worktree:" >&2
    printf '%s\n' "$uncommitted" | sed 's/^/  /' >&2
    fail "there are uncommitted changes. Commit them first (./scripts/finish-feature.sh $issue \"<commit summary>\" for work of the feature), or remove them. Nothing was pushed."
  fi
  leftovers="$(base_leftovers "$root" "$finish_commit" "$scratch")" ||
    fail "could not determine what a merge of the base left behind."
  if [[ -n "$leftovers" ]]; then
    echo "Left behind by a merge of the base: Git ignored these untracked paths at the finish commit and does not ignore them now. They are not work of the feature, but the verification would count them as content. Nothing was deleted:" >&2
    base_leftover_report "$leftovers" >&2
    fail "untracked paths that a merge of the base left behind are in the worktree: remove them with the commands above, after checking that they are not yours, and run ./scripts/update-feature.sh $issue again. Nothing was pushed."
  fi
}
check_worktree

if git -C "$root" merge-base --is-ancestor "$base_ref" HEAD; then
  echo "The branch already contains $base_ref; nothing to merge."
else
  conflicts="$(base_merge_conflicts "$root" "$base_ref")" || {
    status=$?
    [[ "$status" -eq 1 ]] || fail "Git could not compute the merge of $base_ref. Nothing was changed."
    echo "Merging $base_ref conflicts with the feature in:" >&2
    printf '%s\n' "$conflicts" | sed 's/^/  /' >&2
    echo "Nothing was changed or pushed. To continue, merge by hand and resolve the conflicts:" >&2
    echo "  git merge $base_ref    # resolve the files above, then 'git add' them and 'git commit --no-edit'" >&2
    echo "  ./scripts/update-feature.sh $issue" >&2
    records_stop "${0##*/}" "merging $base_ref conflicts with the feature in: $(printf '%s' "$conflicts" | tr '\n' ' ')"
    exit 1
  }
  # Untracked files where the merge writes: Git would replace an ignored one
  # without a word (lib/base.sh).
  overwrites="$(base_merge_overwrites "$root" "$conflicts")" ||
    fail "could not determine what the merge of $base_ref writes over. Nothing was changed."
  if [[ -n "$overwrites" ]]; then
    echo "Merging $base_ref would write over these untracked files of the worktree, which Git may ignore:" >&2
    printf '%s\n' "$overwrites" | sed 's/^/  /' >&2
    fail "the merge of $base_ref would write over untracked files: move each path above out of the worktree, or remove it after checking that it is not needed, and run ./scripts/update-feature.sh $issue again. Nothing was merged, changed, or pushed."
  fi
  echo "Merging $base_ref into $branch..."
  git -C "$root" merge -q --no-ff --no-edit --no-overwrite-ignore "$base_ref" ||
    fail "Git refused the merge of $base_ref; see its output above. Nothing was pushed."
  echo "Merged: $(git -C "$root" log -1 --format='%h %s')"
  check_worktree
fi

# The full verification of the merged content, also the workflow's own
# checks: a review covered the feature, not the merge.
echo
echo "Verifying the merged content: ./scripts/verify.sh --all --reuse"
(cd "$root" && ./scripts/verify.sh --all --reuse) ||
  fail "the verification fails after the merge of $base_ref. Repair it in a commit that changes only files the merge changed (publish-feature.sh passes over such a commit), or review and finish the feature again. Nothing was pushed."

echo
"$root/scripts/publish-feature.sh" "$issue" ${publish_options[@]+"${publish_options[@]}"}
