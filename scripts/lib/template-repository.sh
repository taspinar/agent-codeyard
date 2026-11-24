#!/usr/bin/env bash

# Whether the repository is the template itself: the one predicate that
# ./scripts/verify.sh (the framework-only checks of
# scripts/verify-workflow.conf) and the job 'scope' of
# .github/workflows/ci.yml decide by (docs/development.md, "Framework-only
# self-tests"). Source this file; do not execute it.
#
# The template is the repository that the 'repository:' of
# .agents/template.conf names. The repository this one is, is its 'origin'
# (git remote get-url origin), or in CI the repository of the run, which
# actions/checkout makes the origin as well.
#
# Only a positive answer says "not the template": template.conf names a
# repository by its URL, the repository is known by a URL too, and the two
# differ. Everything else is a doubt, and a doubt is never a project: no
# template.conf, no 'repository:', a local path on either side, no origin,
# or an origin that cannot be read.
#
# Both URLs are compared as '<host>/<path>' in lower case, without a user, a
# port, a trailing '/', or '.git', so that the HTTPS and the SSH form of the
# same repository are one: https://github.com/owner/repo,
# https://token@github.com/owner/repo.git, ssh://git@github.com:22/owner/repo
# and git@github.com:owner/repo are all 'github.com/owner/repo'.

# template_repository_url <url>
# Prints <url> as '<host>/<path>' in lower case; fails for anything that is
# not the URL of a remote repository (a local path, a file:// URL, an empty
# value).
template_repository_url() {
  local url="$1"
  local host
  local path

  url="${url#"${url%%[![:space:]]*}"}"
  url="${url%"${url##*[![:space:]]}"}"
  if [[ "$url" =~ ^(https?|ssh|git|git\+ssh)://([^/@]*@)?([^/:]+)(:[0-9]*)?/(.+)$ ]]; then
    host="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[5]}"
  elif [[ "$url" =~ ^[^/@:]+@([^/:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  path="${path#/}"
  while [[ "$path" == */ ]]; do path="${path%/}"; done
  path="${path%.git}"
  while [[ "$path" == */ ]]; do path="${path%/}"; done
  [[ -n "$host" && -n "$path" ]] || return 1
  printf '%s/%s\n' "${host,,}" "${path,,}"
}

# template_repository_role <root> [<repository>]
# Prints 'template', 'project', or 'unknown' on the first line, and the
# reason on the second. <repository> is the URL of this repository; without
# it, the origin of the Git repository at <root>. Only 'project' is a
# positive "not the template"; 'unknown' is a doubt.
template_repository_role() {
  local root="$1"
  local repository="${2-}"
  local template=""
  local template_url
  local repository_url

  if [[ ! -f "$root/.agents/template.conf" ]]; then
    printf 'unknown\nthere is no .agents/template.conf that names the template\n'
    return 0
  fi
  template="$(sed -n 's/^repository:[[:space:]]*//p' "$root/.agents/template.conf" 2>/dev/null | head -n 1 | sed 's/[[:space:]]*$//')" || template=""
  if [[ -z "$template" ]]; then
    printf 'unknown\n.agents/template.conf names no repository\n'
    return 0
  fi
  if ! template_url="$(template_repository_url "$template")"; then
    printf 'unknown\n.agents/template.conf names the template by a path, not by a URL: %s\n' "$template"
    return 0
  fi
  if [[ $# -lt 2 ]]; then
    if ! repository="$(git -C "$root" remote get-url origin 2>/dev/null)" || [[ -z "$repository" ]]; then
      printf 'unknown\nthe repository has no origin that can be read\n'
      return 0
    fi
  fi
  if ! repository_url="$(template_repository_url "$repository")"; then
    printf 'unknown\nthe origin is not the URL of a remote repository\n'
    return 0
  fi
  if [[ "$template_url" == "$repository_url" ]]; then
    printf 'template\nthe origin is the template that .agents/template.conf names (%s)\n' "$template_url"
  else
    printf 'project\nthis repository (%s) is not the template that .agents/template.conf names (%s)\n' "$repository_url" "$template_url"
  fi
}
