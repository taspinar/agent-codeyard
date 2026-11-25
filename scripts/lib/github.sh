#!/usr/bin/env bash

# Questions about the repository on GitHub, and what counts as a failure of
# a connection or a service for a moment.
# Source this file; do not execute it. It uses only Bash builtins, grep, and
# the GitHub CLI.

# github_transient_error <text>
# Succeeds when <text>, the last lines of what a command printed, names a
# known transient error: a timeout, a reset or refused connection, a host that
# cannot be resolved, a network that cannot be reached, a server error, or a
# service that is overloaded for a moment. start-feature.sh reads the Issue
# again on such an error, and run-feature.sh tries a step again once
# (docs/development.md, "Running a feature with one command"); anything else is a failure that a retry
# does not change.
github_transient_error() {
  grep -Eiq 'timeout|timed out|connection (reset|refused)|could not resolve host|no such host|network is unreachable|temporary failure|EOF|HTTP 5[0-9][0-9]|50[234] |service unavailable|bad gateway|overloaded' <<<"$1"
}

# github_required_checks <branch>
# Prints how many status checks a pull request into <branch> must pass before
# it can be merged: rulesets first, then classic branch protection. Prints
# nothing when that cannot be read, for example without access or network.
github_required_checks() {
  local count

  count="$(gh api "repos/{owner}/{repo}/rules/branches/$1" \
    --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] | length' 2>/dev/null)" ||
    count=""
  if [[ "$count" == "0" ]]; then
    count="$(gh api "repos/{owner}/{repo}/branches/$1" \
      --jq '[(.protection.required_status_checks.contexts // [])[], (.protection.required_status_checks.checks // [])[]] | length' 2>/dev/null)" ||
      count=""
  fi
  [[ ! "$count" =~ ^[0-9]+$ ]] || printf '%s' "$count"
}

# github_default_branch
# Prints the name of the default branch of the repository, the one into which
# a merge applies "Closes #<n>". Prints nothing and fails when that cannot be
# read.
github_default_branch() {
  local name

  name="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name // empty' 2>/dev/null)" || return 1
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}

# github_post_merge_recorded <issue>
# Prints the post_merge criteria whose evidence record-post-merge.sh recorded
# on the Issue, one per line: the first 'Criterion: ' line of each comment
# that starts with the marker '<!-- post-merge-evidence -->'. Fails when the
# comments cannot be read. record-post-merge.sh and status.sh read the
# recorded evidence with it, so that both agree on what is still pending.
github_post_merge_recorded() {
  gh api "repos/{owner}/{repo}/issues/$1/comments" --paginate \
    --jq '.[] | select(.body | startswith("<!-- post-merge-evidence -->")) | .body | split("\n") | map(select(startswith("Criterion: "))) | first // empty | .[11:]'
}
