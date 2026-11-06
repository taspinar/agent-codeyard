#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/records.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/github.sh"

usage() {
  echo "Usage:"
  echo "  $0 <issue-number>        Remove the merged worktree of feature/<issue>-*"
  echo "  $0 planning/<name>       Remove the merged planning worktree"
  echo "  $0 <worktree-path>       Remove the merged worktree at a path"
  echo "  $0 --merged              Remove every worktree whose pull request is merged"
  echo
  echo "Add --discard to remove an unmerged worktree and its branch after confirmation."
  echo
  echo "GitHub closes an Issue from 'Closes #<n>' only on a merge into the default"
  echo "branch. For a feature merged into another base, the script closes its Issue,"
  echo "with a comment that names the pull request and the merge commit, when the"
  echo "pull request says 'Closes #<n>' and lists no pending post_merge criterion."
  echo "Run from the primary checkout."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

discard=0
merged_mode=0
target=""
for argument in "$@"; do
  case "$argument" in
    --discard) discard=1 ;;
    --merged) merged_mode=1 ;;
    -*) usage ;;
    *)
      [[ -z "$target" ]] || usage
      target="$argument"
      ;;
  esac
done
[[ "$merged_mode" -eq 1 && -z "$target" && "$discard" -eq 0 ]] || [[ "$merged_mode" -eq 0 && -n "$target" ]] || usage

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
command -v jq >/dev/null 2>&1 || fail "jq is required."

# The primary checkout is the first entry of the worktree list.
primary="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
current="$(git rev-parse --show-toplevel)"
current="$(cd "$current" && pwd -P)"
primary="$(cd "$primary" && pwd -P)"
[[ "$current" == "$primary" ]] ||
  fail "run cleanup-worktree.sh from the primary checkout ($primary), not from a linked worktree."

# linked_worktrees [all]: prints "<path>\t<branch>" for every linked worktree
# on a feature or planning branch, or on any branch with "all". Paths are
# compared resolved, because Git may print them unresolved.
linked_worktrees() {
  local scope="${1:-workflow}"
  local path
  local branch

  git worktree list --porcelain | awk -v scope="$scope" '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// {
      branch = substr($0, 19)
      if (scope == "all" || branch ~ /^feature\// || branch ~ /^planning\//) {
        print path "\t" branch
      }
    }
  ' | while IFS=$'\t' read -r path branch; do
    [[ -d "$path" && "$(cd "$path" && pwd -P)" != "$primary" ]] || continue
    printf '%s\t%s\n' "$path" "$branch"
  done
}

# merged_pull_request <branch> [<issue>]: prints the merged pull request of a
# branch as one line of tab-separated fields, or nothing when no pull request
# of it is merged: the head commit, the number, the base branch, the merge
# commit ('-' when GitHub gives none: a tab-separated field is never empty,
# because 'read' joins adjacent tabs), whether its description says "Closes #<issue>" on a line of its own
# (1 or 0), and whether it lists a pending post_merge criterion (1 or 0).
merged_pull_request() {
  local issue="${2:-0}"

  gh pr list --head "$1" --state merged --limit 1 --json headRefOid,number,baseRefName,mergeCommit,body \
    --jq ".[0] // empty | ((.body // \"\") | split(\"\\n\") | map(rtrimstr(\"\\r\"))) as \$lines
      | [.headRefOid, (.number | tostring), (.baseRefName // \"-\"), (.mergeCommit.oid // \"-\"),
         (if any(\$lines[]; . == \"Closes #$issue\") then \"1\" else \"0\" end),
         (if any(\$lines[]; startswith(\"Post-merge criterion: \")) then \"1\" else \"0\" end)]
      | join(\"\\t\")" </dev/null
}

# close_issue_after_merge <issue> <number> <base> <merge-commit> <closes> <post-merge>
# GitHub closes an Issue from "Closes #<n>" only on a merge into the default
# branch. After a merge into another base, closes the Issue of a pull request
# that says "Closes #<issue>" (publish-feature.sh writes it only for work
# that may close the Issue) and lists no pending post_merge criterion, which
# record-post-merge.sh records and then closes the Issue. Comments with the
# pull request and the merge commit first. Prints what it did; a failure only
# warns, the merge is done.
close_issue_after_merge() {
  local issue="$1"
  local number="$2"
  local base="$3"
  local merge_commit="$4"
  local closes="$5"
  local post_merge="$6"
  local default_branch
  local state
  local comment

  [[ "$merge_commit" != "-" ]] || merge_commit="unknown"
  if [[ "$base" == "-" ]]; then
    echo "Warning: GitHub did not name the base of pull request #$number; if it did not merge into the default branch, close Issue #$issue by hand." >&2
    return 0
  fi
  if ! default_branch="$(github_default_branch)"; then
    echo "Warning: could not ask GitHub for the default branch; if pull request #$number did not merge into it, close Issue #$issue by hand." >&2
    return 0
  fi
  [[ "$base" != "$default_branch" ]] || return 0
  if [[ "$post_merge" == "1" ]]; then
    echo "Issue #$issue stays open: pull request #$number lists pending post_merge evidence. Record it with ./scripts/record-post-merge.sh $issue \"<criterion>\" \"<evidence>\"; the Issue is closed when none is left."
    return 0
  fi
  if [[ "$closes" != "1" ]]; then
    echo "Issue #$issue stays open: pull request #$number into '$base' does not close it."
    return 0
  fi
  if ! state="$(gh issue view "$issue" --json state --jq '.state')"; then
    echo "Warning: could not read Issue #$issue; close it by hand: pull request #$number is merged into '$base'." >&2
    return 0
  fi
  [[ "$state" == "OPEN" ]] || return 0
  comment="Pull request #$number is merged into \`$base\`, which is not the default branch \`$default_branch\`, so GitHub did not close this Issue. Closed by cleanup-worktree.sh after the merge.

Pull request: #$number
Merge commit: $merge_commit"
  if ! gh issue comment "$issue" --body "$comment" >/dev/null ||
    ! gh issue close "$issue" >/dev/null; then
    echo "Warning: could not close Issue #$issue; close it by hand: pull request #$number is merged into '$base'." >&2
    return 0
  fi
  echo "Closed Issue #$issue: pull request #$number is merged into '$base' (merge commit $merge_commit)."
}

# contains_tip <path> <merged-head> <number> <tip>
# Succeeds when the merged head contains the local tip, so that the branch
# holds nothing the merged pull request did not: the tip is the merged head,
# or an ancestor of it. The branch on GitHub can be ahead of the local one,
# after "Update branch" on the pull request or a push from another checkout.
# A merged head that is not in the local repository is fetched first, from
# the pull request ref that GitHub keeps also after the branch is deleted.
contains_tip() {
  local path="$1"
  local merged="$2"
  local number="$3"
  local tip="$4"

  [[ "$merged" != "$tip" ]] || return 0
  if ! git -C "$path" cat-file -e "$merged^{commit}" 2>/dev/null; then
    git -C "$path" fetch -q origin "refs/pull/$number/head" 2>/dev/null ||
      git -C "$path" fetch -q origin "$merged" 2>/dev/null || return 2
    git -C "$path" cat-file -e "$merged^{commit}" 2>/dev/null || return 2
  fi
  git -C "$path" merge-base --is-ancestor "$tip" "$merged"
}

# cleanup <path> <branch>: removes one worktree and its branch when that is
# safe. Returns 0 when removed, 1 when kept, and 2 when a removal failed;
# prints the reason. Callers run it in a condition, so every destructive step
# checks its own status.
cleanup() {
  local path="$1"
  local branch="$2"
  local head
  local number
  local merged
  local tip
  local issue
  local pr_base=""
  local merge_commit=""
  local pr_closes=""
  local pr_post_merge=""
  local contained=1
  local answer=""

  path="$(cd "$path" && pwd -P)"
  if [[ "$path" == "$current" ]]; then
    echo "Kept $branch: this is the checkout you run the script in. Run it from the primary checkout."
    return 1
  fi

  # Ignored files, such as review and triage results, do not count.
  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    echo "Kept $branch: $path has uncommitted changes."
    return 1
  fi

  issue="$(printf '%s' "$branch" | sed -n 's#^feature/\([0-9][0-9]*\)-.*#\1#p')"
  if ! merged="$(merged_pull_request "$branch" "$issue")"; then
    echo "Kept $branch: could not ask GitHub about its pull request."
    return 1
  fi
  IFS=$'\t' read -r head number pr_base merge_commit pr_closes pr_post_merge <<<"$merged" || true
  tip="$(git -C "$path" rev-parse HEAD)"
  if [[ -n "$head" ]]; then
    contained=0
    contains_tip "$path" "$head" "$number" "$tip" || contained=$?
  fi

  if [[ "$contained" -ne 0 ]]; then
    if [[ "$discard" -eq 1 ]]; then
      printf "Discard %s and its worktree %s, although it is not merged? [y/N] " "$branch" "$path"
      read -r answer || true
      case "$answer" in
        y | Y | yes | YES) ;;
        *)
          echo "Kept $branch."
          return 1
          ;;
      esac
    elif [[ -z "$head" ]]; then
      echo "Kept $branch: its pull request is not merged."
      return 1
    elif [[ "$contained" -eq 2 ]]; then
      echo "Kept $branch: the head of its merged pull request (#$number) could not be fetched from GitHub to compare it with the local branch."
      return 1
    else
      echo "Kept $branch: it has commits after its merged pull request."
      return 1
    fi
  fi

  # The pull request is merged and holds the branch: its Issue may close.
  if [[ -n "$issue" && -n "$head" && "$contained" -eq 0 ]]; then
    close_issue_after_merge "$issue" "$number" "$pr_base" "$merge_commit" "$pr_closes" "$pr_post_merge"
  fi

  # The run records of the feature or the planning together in the primary
  # checkout (.agents/records/), before the worktree goes. They are in the
  # primary checkout already; the copy holds them per feature. A copy that
  # cannot be written keeps the worktree.
  case "$branch" in
    feature/*) records_kind=feature records_subject="$(printf '%s' "$branch" | sed -n 's#^feature/\([0-9][0-9]*\)-.*#\1#p')" ;;
    planning/*) records_kind=planning records_subject="${branch#planning/}" ;;
    *) records_kind="" records_subject="" ;;
  esac
  if [[ -n "$records_subject" ]] && command -v jq >/dev/null 2>&1 &&
    ! (cd "$primary" && records_consolidate "$records_kind" "$records_subject"); then
    echo "Kept $branch: its run records could not be copied to .agents/records/ in $primary."
    return 1
  fi

  if ! git worktree remove "$path"; then
    echo "Error: could not remove the worktree of $branch at $path; the branch was kept." >&2
    return 2
  fi
  if ! git branch -D "$branch" >/dev/null; then
    echo "Error: removed the worktree of $branch, but could not delete the branch." >&2
    return 2
  fi
  echo "Removed $branch and its worktree $path."
  if [[ "$branch" == planning/* && -n "$head" && "$contained" -eq 0 ]]; then
    removed_planning=1
  fi
  return 0
}

removed=0
removed_planning=0
main_updated=0
errors=0
if [[ "$merged_mode" -eq 1 ]]; then
  while IFS=$'\t' read -r path branch; do
    [[ -n "$path" ]] || continue
    status=0
    cleanup "$path" "$branch" </dev/null || status=$?
    case "$status" in
      0) removed=$((removed + 1)) ;;
      2) errors=$((errors + 1)) ;;
    esac
  done < <(linked_worktrees)
  [[ "$removed" -gt 0 || "$errors" -gt 0 ]] || echo "No merged worktree to remove."
else
  # Resolve the target to exactly one worktree.
  matches="$(linked_worktrees | awk -F '\t' -v target="$target" '
    BEGIN { issue = (target ~ /^[0-9]+$/) }
    issue && index($2, "feature/" target "-") == 1 { print; next }
    !issue && $2 == target { print; next }
  ')"
  if [[ -z "$matches" && -e "$target" ]]; then
    target_path="$(cd "$target" && pwd -P)"
    matches="$(linked_worktrees all | while IFS=$'\t' read -r path branch; do
      [[ "$(cd "$path" && pwd -P)" == "$target_path" ]] && printf '%s\t%s\n' "$path" "$branch"
    done || true)"
  fi
  [[ -n "$matches" ]] || fail "no feature or planning worktree matches: $target"
  [[ "$(printf '%s\n' "$matches" | grep -c .)" -eq 1 ]] || fail "more than one worktree matches: $target"

  IFS=$'\t' read -r path branch <<<"$matches"
  status=0
  cleanup "$path" "$branch" || status=$?
  case "$status" in
    0) removed=1 ;;
    1) exit 1 ;;
    *) errors=1 ;;
  esac
fi

git worktree prune

if [[ "$removed" -gt 0 ]]; then
  # Bring main up to date with the merged work. Untracked files do not prevent
  # a fast-forward; modified tracked files do.
  if [[ "$(git -C "$primary" branch --show-current)" == "main" &&
        -z "$(git -C "$primary" status --porcelain --untracked-files=no)" ]]; then
    if git -C "$primary" pull -q --ff-only origin main; then
      echo "Updated main in $primary."
      main_updated=1
    else
      echo "Warning: could not fast-forward main in $primary; update it by hand with: git pull --ff-only origin main"
    fi
  else
    git -C "$primary" fetch -q origin main || true
    echo "Fetched origin/main, but did not update $primary: it is not on main or has uncommitted changes to tracked files."
    echo "Update it by hand with: git pull --ff-only origin main"
  fi

  # After a merged planning, the description or the change request that
  # start-planning.sh copied is in the repository. Remove an untracked
  # original that is byte-identical to its copy.
  if [[ "$removed_planning" -eq 1 && "$main_updated" -eq 1 ]]; then
    copies=()
    [[ ! -f "$primary/docs/PROJECT_DESCRIPTION.md" ]] || copies+=("docs/PROJECT_DESCRIPTION.md")
    while IFS= read -r -d '' copy; do
      copies+=("$copy")
    done < <(git -C "$primary" ls-files -z -- 'docs/changes/*.md')
    while IFS= read -r -d '' candidate; do
      [[ -f "$primary/$candidate" && ! -L "$primary/$candidate" ]] || continue
      for copy in ${copies[@]+"${copies[@]}"}; do
        if cmp -s "$primary/$candidate" "$primary/$copy"; then
          rm "$primary/$candidate"
          echo "Removed $candidate: it is identical to $copy, which is now in the repository."
          break
        fi
      done
    done < <(git -C "$primary" ls-files --others --exclude-standard -z)
  fi

  echo
  echo "Next: create the Issue of the next roadmap feature, using its ID from docs/roadmap.md:"
  echo "  ./scripts/create-feature-issue.sh <feature-id>    # for example F01"
fi

[[ "$errors" -eq 0 ]] || exit 1
