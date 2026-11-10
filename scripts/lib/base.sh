#!/usr/bin/env bash

# The base branch of a feature: the branch it is created from, compared
# with, and merged into. Source this file; do not execute it.
#
# start-feature.sh records the base of a feature in
# branch.<branch>.workflow-base. A project whose features do not branch from
# 'main' sets its default once, as a line 'base: <branch>' in
# .agents/template.conf; without the line the default is 'main'.

# project_base <root>
# Prints the default base branch of the project. Fails, with a message, when
# the line names no valid branch.
project_base() {
  local base=""

  if [[ -f "$1/.agents/template.conf" ]]; then
    base="$(sed -n 's/^base:[[:space:]]*//p' "$1/.agents/template.conf" | head -n 1 | sed 's/[[:space:]]*$//')"
  fi
  if [[ -z "$base" ]]; then
    printf 'main\n'
    return 0
  fi
  if ! git check-ref-format --branch "$base" >/dev/null 2>&1; then
    echo "Error: the default base in .agents/template.conf is not a valid branch name: $base" >&2
    return 1
  fi
  printf '%s\n' "$base"
}

# branch_base <root> [<branch>]
# Prints the base of the feature on <branch> (default: the current branch of
# <root>): the recorded one, and the default of the project when none is
# recorded.
branch_base() {
  local branch="${2:-}"
  local base=""

  [[ -n "$branch" ]] || branch="$(git -C "$1" branch --show-current 2>/dev/null || true)"
  [[ -z "$branch" ]] || base="$(git -C "$1" config --get "branch.$branch.workflow-base" || true)"
  if [[ -n "$base" ]]; then
    printf '%s\n' "$base"
  else
    project_base "$1"
  fi
}

# base_merge_conflicts <root> <ref>
# Merges <ref> into HEAD of <root> in memory, without touching the working
# tree, the index, or a branch (git merge-tree). Prints the merged tree and
# succeeds when the merge is clean; prints the files that conflict, one per
# line, and returns 1 when it is not. Returns 2 when the merge cannot be
# computed.
base_merge_conflicts() {
  local output
  local status=0

  output="$(git -C "$1" merge-tree --write-tree --name-only --no-messages HEAD "$2" 2>/dev/null)" || status=$?
  case "$status" in
    0) printf '%s\n' "$output" | sed -n 1p ;;
    1)
      printf '%s\n' "$output" | sed 1d | grep . | sort -u
      return 1
      ;;
    *) return 2 ;;
  esac
}

# base_ignored_by <root> <commit> <scratch-dir>
# Prints the untracked files of <root> that Git does not ignore now, but that
# the .gitignore files of <commit> ignored, one per line. The rules of
# <commit> are laid out in a repository of their own under <scratch-dir>, so
# that 'git check-ignore' reads exactly them.
base_ignored_by() {
  local root="$1"
  local commit="$2"
  local rules="$3/ignore-rules"
  local untracked
  local file

  untracked="$(git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard)" || return 1
  [[ -n "$untracked" ]] || return 0
  rm -rf "$rules"
  git init -q "$rules" || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    mkdir -p "$rules/$(dirname "$file")"
    git -C "$root" show "$commit:$file" >"$rules/$file" || return 1
  done < <(git -C "$root" -c core.quotePath=false ls-tree -r --name-only "$commit" | grep -E '(^|/)\.gitignore$' || true)
  # Status 1: none of them is ignored there.
  printf '%s\n' "$untracked" | git -C "$rules" check-ignore --no-index --stdin || [[ $? -eq 1 ]]
}

# base_leftovers <root> <commit> <scratch-dir>
# Prints what a merge of the base left behind: untracked paths that the
# .gitignore files of <commit>, the branch before the merge, ignored and that
# Git does not ignore now, such as the build directory of a site the base
# renamed. They are no work of the feature, and no script deletes them. One
# path per line: a directory, with a trailing slash, when everything
# untracked in it is such a leftover, and the files otherwise.
base_leftovers() {
  local root="$1"
  local scratch="$3"

  base_ignored_by "$root" "$2" "$scratch" >"$scratch/leftover-files" || return 1
  [[ -s "$scratch/leftover-files" ]] || return 0
  git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard >"$scratch/untracked-files" || return 1
  git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard --directory |
    awk -v left="$scratch/leftover-files" -v all="$scratch/untracked-files" '
      BEGIN {
        while ((getline line < left) > 0) leftover[line] = 1
        while ((getline line < all) > 0) untracked[++n] = line
      }
      substr($0, length($0)) != "/" {
        if ($0 in leftover) print
        next
      }
      {
        some = 0
        every = 1
        for (i = 1; i <= n; i++) {
          if (index(untracked[i], $0) != 1) continue
          if (untracked[i] in leftover) some = 1
          else every = 0
        }
        if (some && every) print
        else if (some) for (i = 1; i <= n; i++) if (index(untracked[i], $0) == 1 && (untracked[i] in leftover)) print untracked[i]
      }'
}

# base_leftover_report <paths>
# Prints the leftovers of base_leftovers with the command that removes each.
base_leftover_report() {
  local path

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf '  %s    remove with: rm -rf -- %q\n' "$path" "$path"
  done <<<"$1"
}

# base_uncommitted_work <root> <commit> <scratch-dir>
# Prints the uncommitted work in <root>, in the form of 'git status
# --porcelain': the changes of tracked files, and the untracked files that Git
# does not ignore, except the leftovers of a merge of the base that
# base_leftovers prints for <commit>. Prints nothing when there is none.
base_uncommitted_work() {
  git -C "$1" status --porcelain --untracked-files=no || return 1
  base_ignored_by "$1" "$2" "$3" >"$3/leftover-files" || return 1
  git -C "$1" -c core.quotePath=false ls-files --others --exclude-standard | grep -vxF -f "$3/leftover-files" | sed 's/^/?? /' || true
}
