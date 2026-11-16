#!/usr/bin/env bash

# The approval requests and plans that a project inherits from the template.
# Source this file; do not execute it.
#
# GitHub's "Use this template" copies every committed file of the template
# into the first commit of the new project, also the template's own approval
# requests (.agents/approval-requests/) and plans (.agents/plans/). Their
# numbers are Issues of the template, which collide with the project's own
# Issues. A file under these directories that the root commit added, and that
# no later commit changed, is such a leftover; the project's own requests and
# plans come in later commits. .gitkeep is not one.
#
# Only a project has them: a repository whose origin is not the 'repository:'
# of .agents/template.conf, compared as CI does (.github/workflows/ci.yml),
# without a trailing '/' or '.git' and without regard to case. In the
# template nothing is reported, and its root commit holds none of them.
# Nothing is reported in a shallow clone either: its oldest commit is not the
# root and may hold the project's own files. inherited_shallow tells such a
# clone of a project; start-planning.sh deepens it before it looks, doctor.sh
# warns that it cannot tell.

INHERITED_DIRECTORIES=(.agents/approval-requests .agents/plans)

# inherited_normalize_url <url>
inherited_normalize_url() {
  local url="$1"

  url="${url%/}"
  url="${url%.git}"
  url="${url%/}"
  printf '%s\n' "${url,,}"
}

# inherited_in_project <root>
# Exits 0 when the repository is a project made from the template: it has an
# origin, and the origin is not the template named in .agents/template.conf.
inherited_in_project() {
  local origin
  local template=""

  origin="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "$origin" ]] || return 1
  if [[ -f "$1/.agents/template.conf" ]]; then
    template="$(sed -n 's/^repository:[[:space:]]*//p' "$1/.agents/template.conf" | head -n 1 | sed 's/[[:space:]]*$//')"
  fi
  [[ "$(inherited_normalize_url "$origin")" != "$(inherited_normalize_url "$template")" ]]
}

# inherited_shallow <root>
# Exits 0 when the repository is a project made from the template and a
# shallow clone, whose inherited files inherited_files cannot tell.
inherited_shallow() {
  inherited_in_project "$1" || return 1
  [[ "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]
}

# inherited_files <root>
# Prints the tracked approval requests and plans that the project inherited
# from the template, one path per line, sorted. Prints nothing in the
# template, in a shallow clone, or outside a Git repository.
inherited_files() {
  local root="$1"
  local commit
  local changed

  inherited_in_project "$root" || return 0
  [[ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" == "false" ]] || return 0
  git -C "$root" rev-parse --verify --quiet "HEAD^{commit}" >/dev/null || return 0

  for commit in $(git -C "$root" rev-list --max-parents=0 HEAD); do
    # What a later commit changed or removed is not left over: a changed
    # file is the project's own now.
    changed="$(git -C "$root" diff --name-only --no-renames "$commit" HEAD -- "${INHERITED_DIRECTORIES[@]}")"
    git -C "$root" ls-tree -r --name-only "$commit" -- "${INHERITED_DIRECTORIES[@]}" |
      grep -v '/\.gitkeep$' |
      grep -vxF -f <(printf '%s\n' "$changed") || true
  done | LC_ALL=C sort -u
}
