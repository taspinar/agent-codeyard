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
