#!/usr/bin/env bash

# Project skills: guidance that a project keeps in its repository and that a
# feature plan selects explicitly (docs/development.md, "Project skills").
# Source this file; do not execute it.
#
# A skill is a directory .agents/project-skills/<name>/ with its metadata in
# skill.conf, one '<key>: <value>' per line:
#
# - origin: 'project' for a skill the project wrote, 'third-party' for one
#   taken from elsewhere.
# - files: the files of the skill that an agent reads, relative to its
#   directory, separated by spaces. They are the content that is retained.
# - digest: sha256:<hex> of those files, as skills_digest computes it. A plan
#   selects a skill by this value.
# - source, revision, license, content: required for a third-party skill:
#   where it comes from, the immutable commit it was taken at (a full commit
#   hash), its license, and 'upstream' or 'adapted'.
# - changes: what was changed from upstream; required for adapted content.
# - license-file, description: optional.
#
# A plan of an Issue (.agents/plans/<issue>-*.md) selects skills in a section
# '## Skills', one '- <name> sha256:<hex>' per line; text after the two words
# is a note. A project without the directory and a plan without the section
# have no skills, and nothing here does anything for them.
#
# Nothing here installs, fetches, or runs the content of a skill: the
# functions read skill.conf and hash files. A skill directory may hold only
# skill.conf, its license file, and the files it lists, and none of them may
# be executable, so a script, installer, or hook of an upstream skill is not
# kept.

SKILLS_DIR=".agents/project-skills"
SKILLS_METADATA="skill.conf"
SKILLS_KEYS="origin files digest source revision license content changes license-file description"

# skills_sha256: the sha256 hex digest of standard input.
skills_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -c1-64
  else
    openssl dgst -sha256 -r | cut -c1-64
  fi
}

# skills_value <metadata-file> <key>: the value of the key; nothing without
# one.
skills_value() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | sed -n '1s/[[:space:]]*$//p'
}

# skills_digest <skill-dir> <file>...
# Prints sha256:<hex> of the files: the sha256 of the lines
# '<sha256 of the file>  <file>', one per file in the order given, which is
# what 'sha256sum <file>... | sha256sum' prints in the skill directory.
skills_digest() {
  local dir="$1"
  local file
  shift
  for file in "$@"; do
    printf '%s  %s\n' "$(skills_sha256 <"$dir/$file")" "$file"
  done | skills_sha256 | sed 's/^/sha256:/'
}

# skills_names <root>: the names of the skill directories, one per line.
skills_names() {
  local dir

  [[ -d "$1/$SKILLS_DIR" ]] || return 0
  for dir in "$1/$SKILLS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    printf '%s\n' "${dir##*/}"
  done
}

# skills_errors <root> <name>
# Prints what is wrong with a skill, one problem per line; nothing for a
# skill that is valid.
skills_errors() {
  local root="$1"
  local name="$2"
  local dir="$root/$SKILLS_DIR/$name"
  local conf="$dir/$SKILLS_METADATA"
  local key line origin files file digest computed license_file path listed
  local -a list=()

  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || echo "$SKILLS_DIR/$name: the name must match [a-z0-9][a-z0-9-]*"
  if [[ ! -d "$dir" ]]; then
    echo "$SKILLS_DIR/$name does not exist"
    return 0
  fi
  if [[ ! -f "$conf" ]]; then
    echo "$SKILLS_DIR/$name has no $SKILLS_METADATA"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" && "$line" != \#* ]] || continue
    key="${line%%:*}"
    if [[ "$line" != *:* || " $SKILLS_KEYS " != *" $key "* ]]; then
      echo "$SKILLS_DIR/$name/$SKILLS_METADATA: unknown line '$line' (keys: $SKILLS_KEYS)"
    fi
  done <"$conf"

  origin="$(skills_value "$conf" origin)"
  case "$origin" in
    project) ;;
    third-party)
      for key in source revision license content; do
        [[ -n "$(skills_value "$conf" "$key")" ]] || echo "$SKILLS_DIR/$name/$SKILLS_METADATA: a third-party skill needs '$key'"
      done
      [[ -z "$(skills_value "$conf" revision)" || "$(skills_value "$conf" revision)" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] ||
        echo "$SKILLS_DIR/$name/$SKILLS_METADATA: revision must be a full commit hash, which cannot move like a branch or a tag: $(skills_value "$conf" revision)"
      case "$(skills_value "$conf" content)" in
        "" | upstream) ;;
        adapted)
          [[ -n "$(skills_value "$conf" changes)" ]] || echo "$SKILLS_DIR/$name/$SKILLS_METADATA: adapted content needs 'changes', what differs from upstream"
          ;;
        *) echo "$SKILLS_DIR/$name/$SKILLS_METADATA: content must be 'upstream' or 'adapted': $(skills_value "$conf" content)" ;;
      esac
      ;;
    "") echo "$SKILLS_DIR/$name/$SKILLS_METADATA: needs 'origin', 'project' or 'third-party'" ;;
    *) echo "$SKILLS_DIR/$name/$SKILLS_METADATA: origin must be 'project' or 'third-party': $origin" ;;
  esac

  files="$(skills_value "$conf" files)"
  [[ -n "$files" ]] || echo "$SKILLS_DIR/$name/$SKILLS_METADATA: needs 'files', the files an agent reads"
  read -r -a list <<<"$files"
  for file in ${list[@]+"${list[@]}"}; do
    if [[ "$file" == /* || "/$file/" == */../* || "$file" == "$SKILLS_METADATA" ]]; then
      echo "$SKILLS_DIR/$name/$SKILLS_METADATA: '$file' is not a file of the skill"
      return 0
    fi
    [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || {
      echo "$SKILLS_DIR/$name/$file is listed in files but is not a regular file"
      return 0
    }
  done
  license_file="$(skills_value "$conf" license-file)"
  [[ -z "$license_file" || -f "$dir/$license_file" ]] || echo "$SKILLS_DIR/$name/$license_file is the license-file but does not exist"

  # Only what is read is kept, and nothing can be run.
  while IFS= read -r path; do
    path="${path#"$dir"/}"
    listed=0
    [[ "$path" != "$SKILLS_METADATA" && "$path" != "$license_file" ]] || listed=1
    for file in ${list[@]+"${list[@]}"}; do
      [[ "$path" != "$file" ]] || listed=1
    done
    [[ "$listed" -eq 1 ]] || echo "$SKILLS_DIR/$name/$path is not listed in files: list it, or remove it (scripts, installers, and hooks of a skill are not kept)"
    [[ ! -x "$dir/$path" ]] || echo "$SKILLS_DIR/$name/$path is executable: a skill holds guidance only"
  done < <(find "$dir" \( -type f -o -type l \) | LC_ALL=C sort)

  [[ "${#list[@]}" -gt 0 ]] || return 0
  digest="$(skills_value "$conf" digest)"
  computed="$(skills_digest "$dir" "${list[@]}")"
  if [[ -z "$digest" ]]; then
    echo "$SKILLS_DIR/$name/$SKILLS_METADATA: needs 'digest: $computed'"
  elif [[ "$digest" != "$computed" ]]; then
    echo "$SKILLS_DIR/$name: the files have $computed, but $SKILLS_METADATA records $digest; record the new digest when the change is intended"
  fi
}

# skills_plans <root> <issue>: the plans of the Issue, one per line.
skills_plans() {
  local plan

  for plan in "$1/.agents/plans/$2-"*.md; do
    [[ -f "$plan" ]] && printf '%s\n' "$plan"
  done
  return 0
}

# skills_selection <plan>
# Prints the lines of the section '## Skills' of the plan that select a
# skill, without the leading '- '.
skills_selection() {
  awk '
    /^## / { in_skills = ($0 ~ /^## +Skills[[:space:]]*$/); next }
    in_skills && /^[-*] / { sub(/^[-*] +/, ""); print }
  ' "$1"
}

# skills_selected_files <root> <issue>
# Prints the files of the skills that the plan of the Issue selects, relative
# to the root, one per line, in the order of the plan; nothing when it selects
# none. When a selection does not resolve, prints the problems on standard
# error, one per line, and returns 1: an unknown skill, a skill that is not
# valid, or a selected digest that is not the digest of its files.
skills_selected_files() {
  local root="$1"
  local issue="$2"
  local plan plan_relative line name version rest errors computed conf output=""
  local problems=""
  local -a list=()

  while IFS= read -r plan; do
    plan_relative="${plan#"$root"/}"
    while IFS= read -r line; do
      line="${line//\`/}"
      read -r name version rest <<<"$line"
      if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$version" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        problems+="$plan_relative selects a skill as '$line'; write '- <name> sha256:<digest>' (./scripts/check-skills.sh --digest <name> prints the digest)"$'\n'
        continue
      fi
      conf="$root/$SKILLS_DIR/$name/$SKILLS_METADATA"
      if [[ ! -f "$conf" ]]; then
        problems+="$plan_relative selects the skill '$name', which is unknown: $SKILLS_DIR/$name/$SKILLS_METADATA does not exist"$'\n'
        continue
      fi
      errors="$(skills_errors "$root" "$name")"
      if [[ -n "$errors" ]]; then
        problems+="$plan_relative selects the skill '$name', which is not valid:"$'\n'"$(printf '%s\n' "$errors" | sed 's/^/  /')"$'\n'
        continue
      fi
      read -r -a list <<<"$(skills_value "$conf" files)"
      computed="$(skills_digest "$root/$SKILLS_DIR/$name" "${list[@]}")"
      if [[ "$version" != "$computed" ]]; then
        problems+="$plan_relative selects the skill '$name' at $version, but its files are at $computed$(skills_revision_text "$conf"); select that digest after reviewing the change, or restore the selected content"$'\n'
        continue
      fi
      for line in "${list[@]}"; do
        output+="$SKILLS_DIR/$name/$line"$'\n'
      done
    done < <(skills_selection "$plan")
  done < <(skills_plans "$root" "$issue")

  if [[ -n "$problems" ]]; then
    printf '%s' "$problems" >&2
    return 1
  fi
  printf '%s' "$output"
}

# skills_resolve <root> <issue>
# skills_selected_files without output: sets SKILLS_FILES to the files and
# SKILLS_PROBLEMS to the problems, and returns 1 when there are problems.
skills_resolve() {
  local errors_file
  local status=0

  errors_file="$(mktemp "${TMPDIR:-/tmp}/skills.XXXXXX")"
  SKILLS_FILES="$(skills_selected_files "$1" "$2" 2>"$errors_file")" || status=$?
  SKILLS_PROBLEMS="$(cat "$errors_file")"
  rm -f "$errors_file"
  return "$status"
}

# skills_problems_text: SKILLS_PROBLEMS as a list for a message.
skills_problems_text() {
  printf '%s\n' "$SKILLS_PROBLEMS" | sed -e 's/^  /    /' -e t -e 's/^/  - /'
}

# skills_revision_text <metadata-file>: ' (<source> at <revision>)' for a
# third-party skill, nothing for one of the project.
skills_revision_text() {
  [[ "$(skills_value "$1" origin)" == "third-party" ]] || return 0
  printf ' (%s at %s)' "$(skills_value "$1" source)" "$(skills_value "$1" revision)"
}

# skills_prompt <files>
# Prints the paragraph of an agent's prompt that names the selected skill
# files; nothing without files. Every role that works on the feature gets the
# same paragraph for the same plan.
skills_prompt() {
  [[ -n "$1" ]] || return 0
  printf '\n\nThe plan selects project skills. Read these files by path, whatever your\nclient discovers by itself:\n%s\nThey are guidance below the Issue, the ADRs, AGENTS.md, and the plan, as\nyour contract says under "Project skills".' "$(printf '%s\n' "$1" | sed '/^$/d; s/^/- /')"
}
