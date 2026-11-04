#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/skills.sh"

usage() {
  echo "Usage: $0"
  echo "       $0 --issue <issue-number>"
  echo "       $0 --digest <name>"
  echo
  echo "Checks the project skills in $SKILLS_DIR/ (docs/development.md,"
  echo "\"Project skills\"). Reads metadata and hashes files; never installs,"
  echo "fetches, or runs anything."
  echo
  echo "Without an option, checks the metadata of every skill. A project without"
  echo "skills passes."
  echo
  echo "--issue checks the skills that .agents/plans/<issue>-*.md selects and prints"
  echo "their files, one per line: what the implementer and the reviewer read."
  echo
  echo "--digest prints the digest of a skill's files, for its $SKILLS_METADATA and"
  echo "for the plan that selects it."
  echo
  echo "Exits 0 when everything is valid, 1 when something is not."
  exit 2
}

root="$(git rev-parse --show-toplevel)"

case "${1:-}" in
  "")
    [[ $# -eq 0 ]] || usage
    problems=""
    count=0
    while IFS= read -r name; do
      count=$((count + 1))
      problems+="$(skills_errors "$root" "$name")"$'\n'
    done < <(skills_names "$root")
    problems="$(printf '%s' "$problems" | sed '/^$/d')"
    if [[ -n "$problems" ]]; then
      echo "Project skills are not valid:" >&2
      printf '%s\n' "$problems" | sed 's/^/  - /' >&2
      exit 1
    fi
    if [[ "$count" -eq 0 ]]; then
      echo "No project skills."
    else
      echo "$count project skill(s) valid."
    fi
    ;;
  --issue)
    [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] || usage
    if ! skills_resolve "$root" "$2"; then
      echo "The skills selected for Issue #$2 do not resolve:" >&2
      skills_problems_text >&2
      exit 1
    fi
    [[ -z "$SKILLS_FILES" ]] || printf '%s\n' "$SKILLS_FILES"
    ;;
  --digest)
    [[ $# -eq 2 ]] || usage
    conf="$root/$SKILLS_DIR/$2/$SKILLS_METADATA"
    [[ "$2" =~ ^[a-z0-9][a-z0-9-]*$ && -f "$conf" ]] || {
      echo "Error: unknown skill: $SKILLS_DIR/$2/$SKILLS_METADATA does not exist" >&2
      exit 1
    }
    read -r -a list <<<"$(skills_value "$conf" files)"
    [[ "${#list[@]}" -gt 0 ]] || {
      echo "Error: $SKILLS_DIR/$2/$SKILLS_METADATA lists no files" >&2
      exit 1
    }
    for file in "${list[@]}"; do
      [[ "$file" != /* && "/$file/" != */../* && -f "$root/$SKILLS_DIR/$2/$file" ]] || {
        echo "Error: $SKILLS_DIR/$2/$file is not a file of the skill" >&2
        exit 1
      }
    done
    skills_digest "$root/$SKILLS_DIR/$2" "${list[@]}"
    ;;
  *) usage ;;
esac
