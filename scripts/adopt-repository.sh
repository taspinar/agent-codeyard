#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <path> [--proposal <file>] [--publish]"
  echo
  echo "Applies the proposal of an assessment (assess-repository.sh) to the existing"
  echo "repository at <path>, as one commit on the branch $branch_name of that"
  echo "repository. Run it from the clone of the template the assessment ran from."
  echo
  echo "The adoption only adds: an existing file is never overwritten. A collision"
  echo "is applied as the proposal resolves it:"
  echo "  keep-project   the project's file stays its own; for AGENTS.md and"
  echo "                 .gitignore a marked section of the workflow is appended."
  echo "  merge,         the template's file is placed beside it, as"
  echo "  take-template  <name>.agent-codeyard.<ext>, to combine by hand."
  echo "  ask-owner, or no resolution, stops the run before any change."
  echo "Nothing is written under .github/workflows/: the project's CI stays as it is."
  echo
  echo "The run also stops before any change when the repository has uncommitted"
  echo "work or differs from the assessed state, and when the proposal names a path"
  echo "that is no file of its template commit inside the repository. Run again, it"
  echo "completes a partial adoption and changes nothing on an adopted repository."
  echo "A file the project changed or removed since the adoption is left as it is."
  echo
  echo "--proposal names the proposal.json (default: the latest assessment of <path>"
  echo "in .agents/assessments/). --publish pushes the branch to 'origin' of the"
  echo "repository and opens a pull request. The script never pushes the default"
  echo "branch, merges, or deploys."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

branch_name="adopt/agent-codeyard"
suffix="agent-codeyard"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/records.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

target=""
proposal=""
publish=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proposal)
      [[ $# -ge 2 && -n "$2" ]] || fail "--proposal requires a file."
      proposal="$2"
      shift
      ;;
    --publish) publish=1 ;;
    -*) usage ;;
    *)
      [[ -z "$target" ]] || usage
      target="$1"
      ;;
  esac
  shift
done
[[ -n "$target" ]] || usage
[[ -d "$target" ]] || fail "$target is not a directory."
target="$(cd "$target" && pwd -P)"

root="$(git rev-parse --show-toplevel)"
primary="$(records_primary)" || primary=""
[[ -n "$primary" ]] || primary="$root"
case "$root/" in
  "$target"/*) fail "$target holds the template checkout; the adoption would write into it." ;;
esac

# Git in the repository: variables of a calling Git would point it elsewhere;
# its hooks and file system monitor are code of the project, which the
# adoption does not run.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
tgit() {
  git -C "$target" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}
tgit rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [[ "$(cd "$(tgit rev-parse --show-toplevel)" && pwd -P)" == "$target" ]] ||
  fail "$target is not the top directory of a Git repository. The adoption is a commit on a branch: commit the project to Git first, then assess it again."

# ------------------------------------------------------------- the proposal
if [[ -z "$proposal" ]]; then
  for candidate in "$primary"/.agents/assessments/*/proposal.json; do
    [[ -f "$candidate" ]] || continue
    [[ "$(jq -r '.repository.path // empty' "$candidate" 2>/dev/null)" == "$target" ]] || continue
    if [[ -z "$proposal" || "$candidate" -nt "$proposal" ]]; then proposal="$candidate"; fi
  done
  [[ -n "$proposal" ]] ||
    fail "no assessment of $target is in $primary/.agents/assessments/. Run ./scripts/assess-repository.sh $target first, or pass --proposal <file>."
fi
[[ -f "$proposal" ]] || fail "$proposal is not a file."
jq -e '.schema == "adoption-proposal/v1" and (.additions | type) == "array" and (.collisions | type) == "array"
  and (.template.commit | type) == "string" and (.ownership.template_paths | type) == "array"' "$proposal" >/dev/null 2>&1 ||
  fail "$proposal is not a proposal of assess-repository.sh (adoption-proposal/v1)."
proposal_path="$(jq -r '.repository.path // ""' "$proposal")"
[[ "$proposal_path" == "$target" ]] || fail "$proposal is the proposal for $proposal_path, not for $target."
assessed_head="$(jq -r '.repository.head // ""' "$proposal")"
[[ -n "$assessed_head" ]] || fail "the repository had no commit when it was assessed. Commit the project, then assess it again."
assessment="$(jq -r '.assessment // ""' "$proposal")"
template_commit="$(jq -r '.template.commit' "$proposal")"
git -C "$root" cat-file -e "$template_commit^{commit}" 2>/dev/null ||
  fail "the template checkout $root has no commit $template_commit, the version the proposal adds. Fetch it, or assess the repository again."
# Every path of the proposal is a destination in the repository: a plain
# relative path that names a file of the template commit. A path that leaves
# the repository (absolute, or with a '.' or '..' component) or that the
# template does not have is an edited or damaged proposal, refused before any
# change.
plain_relative='def plain_relative: type == "string" and . != "" and (startswith("/") | not)
  and (explode | any(. < 32 or . == 127) | not) and (split("/") | any(. == "" or . == "." or . == "..") | not);'
invalid_paths=()
while IFS= read -r line; do
  invalid_paths+=("$line")
done < <(jq -r "$plain_relative"' (.additions[], .collisions[]) | .path | select(plain_relative | not) | tojson' "$proposal")
while IFS= read -r path; do
  [[ "$(git -C "$root" cat-file -t "$template_commit:$path" 2>/dev/null)" == blob ]] ||
    invalid_paths+=("\"$path\" (not a file of the template commit ${template_commit:0:7})")
done < <(jq -r "$plain_relative"' (.additions[], .collisions[]) | .path | select(plain_relative)' "$proposal")
if [[ "${#invalid_paths[@]}" -gt 0 ]]; then
  echo "Error: $proposal names paths that are no files of the template in the repository; the adoption stops before any change:" >&2
  printf '  - %s\n' "${invalid_paths[@]}" >&2
  echo "Assess the repository again, or correct the proposal." >&2
  exit 1
fi
template_repository="$(jq -r '.template.repository // ""' "$proposal")"
[[ -n "$template_repository" ]] || template_repository="$root"

work="$(mktemp -d "${TMPDIR:-/tmp}/adopt-repository.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# template_file <path> <file>: writes the template's version of <path>.
template_file() {
  git -C "$root" show "$template_commit:$1" >"$2"
}
# template_mode <path>: the Git file mode of the template's version.
template_mode() {
  git -C "$root" ls-tree "$template_commit" -- "$1" | cut -c1-6
}

# beside_name <path>: the other name for the template's version of a file the
# project has: AGENTS.md becomes AGENTS.agent-codeyard.md.
beside_name() {
  local dir="" name="${1##*/}"

  [[ "$1" != */* ]] || dir="${1%/*}/"
  if [[ "$name" == ?*.* ]]; then
    printf '%s%s.%s.%s\n' "$dir" "${name%.*}" "$suffix" "${name##*.}"
  else
    printf '%s%s.%s\n' "$dir" "$name" "$suffix"
  fi
}

# kind_of <path>: what the working tree has at <path>, as the assessment names
# it, or nothing when it is free.
kind_of() {
  local prefix="$1"

  if [[ -L "$target/$1" ]]; then
    echo symlink
  elif [[ -d "$target/$1" ]]; then
    echo directory
  elif [[ -e "$target/$1" ]]; then
    echo file
  else
    while [[ "$prefix" == */* ]]; do
      prefix="${prefix%/*}"
      if [[ -L "$target/$prefix" || (-e "$target/$prefix" && ! -d "$target/$prefix") ]]; then
        echo file-in-the-way
        return 0
      fi
    done
  fi
}

# ------------------------------------------------------------------ the plan
# One action per line: <action> <tab> <path in the repository> <tab> <path in
# the template>.
#   add      the template's file, at the same path
#   beside   the template's file, under another name
#   config   .agents/template.conf, written by this script
#   section  a marked section appended to the project's AGENTS.md or .gitignore
#   keep     the project's file, unchanged
#   present  the project's file, identical to the template's
#   ci       a CI workflow, left out
problems=()
exclusions=()
: >"$work/plan"
while IFS=$'\t' read -r path ownership; do
  if [[ "$path" == ".agents/template.conf" ]]; then
    printf 'config\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  elif [[ "$path" == .github/workflows/* ]]; then
    printf 'ci\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  else
    printf 'add\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  fi
done < <(jq -r '.additions[] | [.path, .ownership] | @tsv' "$proposal")

while IFS=$'\t' read -r path ownership kind resolution rationale; do
  if [[ "$path" == ".agents/template.conf" ]]; then
    problems+=("$path: the repository has its own template configuration. When it was made from this template, take over its changes with ./scripts/sync-template.sh in the repository instead.")
    continue
  fi
  # A file that is already the template's needs no resolution.
  if [[ "$kind" == file ]] &&
    [[ "$(tgit rev-parse -q --verify "$assessed_head:$path" 2>/dev/null)" == "$(git -C "$root" rev-parse -q --verify "$template_commit:$path" 2>/dev/null)" ]]; then
    printf 'present\t%s\t%s\n' "$path" "$path" >>"$work/plan"
    continue
  fi
  case "$resolution" in
    keep-project)
      [[ "$ownership" != template ]] || exclusions+=(":(exclude)$path")
      if [[ "$kind" == file && ("$path" == AGENTS.md || "$path" == .gitignore) ]]; then
        printf 'section\t%s\t%s\n' "$path" "$path" >>"$work/plan"
      else
        printf 'keep\t%s\t%s\n' "$path" "$path" >>"$work/plan"
      fi
      ;;
    merge | take-template)
      if [[ "$path" == .github/workflows/* ]]; then
        printf 'ci\t%s\t%s\n' "$path" "$path" >>"$work/plan"
      elif [[ "$kind" != file ]]; then
        problems+=("$path: resolved as $resolution, but the project has a $kind there, so the template's file cannot be placed beside it. Move the project's $kind, or resolve it as keep-project.")
      else
        printf 'beside\t%s\t%s\n' "$(beside_name "$path")" "$path" >>"$work/plan"
      fi
      ;;
    ask-owner)
      problems+=("$path: the proposal leaves it to the owner (ask-owner): ${rationale:-no rationale}. Decide, then set its resolution in the proposal and pass it with --proposal, or change the repository and assess it again.")
      ;;
    *)
      problems+=("$path: the proposal does not resolve this collision. Set a resolution (keep-project, merge, or take-template) in the proposal and pass it with --proposal.")
      ;;
  esac
done < <(jq -r '.collisions[] | [.path, .ownership, .kind, (.resolution // ""), ((.rationale // "") | gsub("[\t\n]"; " "))] | @tsv' "$proposal")

# The paths the adoption writes; a partial adoption may have left them
# uncommitted on its branch.
awk -F'\t' '$1 == "add" || $1 == "beside" || $1 == "config" || $1 == "section" { print $2 }' "$work/plan" | LC_ALL=C sort >"$work/planned"

# --------------------------------------------- the state of the repository
current="$(tgit symbolic-ref -q --short HEAD 2>/dev/null || true)"
head="$(tgit rev-parse -q --verify HEAD 2>/dev/null || true)"
branch_tip="$(tgit rev-parse -q --verify "refs/heads/$branch_name" 2>/dev/null || true)"

# Uncommitted work is the project's, and stops the adoption; only on the
# adoption's branch may an interrupted run have left the files it writes.
while IFS= read -r -d '' entry; do
  path="${entry:3}"
  if [[ "$current" == "$branch_name" ]] && grep -Fxq -- "$path" "$work/planned"; then
    continue
  fi
  problems+=("$path: uncommitted change (${entry:0:2}). Commit or stash it first; the adoption does not mix with work in progress.")
done < <(tgit status --porcelain=v1 -z --untracked-files=all --no-renames)

tgit var GIT_COMMITTER_IDENT >/dev/null 2>&1 ||
  problems+=("no Git identity is set for $target: set user.name and user.email, so the adoption can be committed.")

# fresh: the assessed commit; branch: the adoption's branch exists; adopted:
# the adoption is merged into the checked-out branch.
if [[ -n "$branch_tip" ]]; then
  mode=branch
  tgit merge-base --is-ancestor "$assessed_head" "$branch_tip" 2>/dev/null ||
    fail "the branch $branch_name of $target does not start from the assessed commit ${assessed_head:0:7}. Delete the branch, or assess the repository again."
elif [[ "$head" == "$assessed_head" ]]; then
  mode=fresh
elif [[ -n "$head" ]] && tgit merge-base --is-ancestor "$assessed_head" "$head" 2>/dev/null &&
  tgit show "$head:.agents/template.conf" 2>/dev/null | grep -q '^commit:'; then
  mode=adopted
else
  fail "$target changed since the assessment: HEAD is ${head:0:7}, the assessment saw ${assessed_head:0:7}. Assess it again: ./scripts/assess-repository.sh $target"
fi

# On the assessed commit, the files are as the assessment saw them.
if [[ "$mode" == fresh ]]; then
  while IFS=$'\t' read -r path kind; do
    now="$(kind_of "$path")"
    [[ "$now" == "$kind" ]] ||
      problems+=("$path: changed since the assessment (was: ${kind:-free}, is: ${now:-free}). Assess the repository again.")
  done < <(jq -r '(.additions[] | [.path, ""]), (.collisions[] | [.path, .kind]) | @tsv' "$proposal")
fi

if [[ "${#problems[@]}" -gt 0 ]]; then
  echo "Error: the adoption of $target stops before any change:" >&2
  printf '  - %s\n' "${problems[@]}" >&2
  echo "Proposal: $proposal" >&2
  exit 1
fi

# ------------------------------------------------------ the files to write
# .agents/template.conf, from the template's: the template, its version, and
# its files, without those the project keeps as its own. The CI workflows are
# the project's, so a later sync adds none of the template's either.
paths_value="$(jq -r '.ownership.template_paths | join(" ")' "$proposal") :(exclude).github/workflows"
for exclusion in ${exclusions[@]+"${exclusions[@]}"}; do
  paths_value="$paths_value $exclusion"
done
template_file .agents/template.conf "$work/template.conf.base" 2>/dev/null || : >"$work/template.conf.base"
{
  has_repository=0 has_paths=0 has_commit=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      repository:*) printf 'repository: %s\n' "$template_repository" && has_repository=1 ;;
      paths:*) printf 'paths: %s\n' "$paths_value" && has_paths=1 ;;
      commit:*) printf 'commit: %s\n' "$template_commit" && has_commit=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$work/template.conf.base"
  [[ "$has_repository" -eq 1 ]] || printf '\nrepository: %s\n' "$template_repository"
  [[ "$has_paths" -eq 1 ]] || printf '\npaths: %s\n' "$paths_value"
  [[ "$has_commit" -eq 1 ]] || printf '\ncommit: %s\n' "$template_commit"
} >"$work/template.conf"

agents_marker="<!-- agent-codeyard: begin (added by adopt-repository.sh) -->"
gitignore_marker="# agent-codeyard: the working files of the workflow (added by adopt-repository.sh)"
# section_file <path> <file>: the section appended to the project's file.
section_file() {
  if [[ "$1" == AGENTS.md ]]; then
    {
      printf '\n%s\n\n## Agent workflow (agent-codeyard)\n\n' "$agents_marker"
      printf 'This project follows the agent-codeyard workflow. Its instructions follow.\n'
      printf 'Where they conflict with the instructions above, stop and report the conflict.\n\n'
      # One heading level down, below the section.
      template_file AGENTS.md /dev/stdout | sed -e '1{/^# /d;}' -e 's/^\(#\{1,5\}\) /#\1 /'
      printf '\n<!-- agent-codeyard: end -->\n'
    } >"$2"
  else
    {
      printf '\n%s\n' "$gitignore_marker"
      template_file .gitignore /dev/stdout | grep -E '^!?\.agents/' || true
    } >"$2"
  fi
}

# plain_path <path>: neither <path> nor a directory above it is a symbolic
# link or a file in the way; writing through one would change something that
# is not the repository's.
plain_path() {
  local current="$1"

  while [[ "$current" != "." && "$current" != "/" ]]; do
    [[ ! -L "$target/$current" ]] || return 1
    current="$(dirname "$current")"
    [[ "$current" == "." || -d "$target/$current" || ! -e "$target/$current" ]] || return 1
  done
}

# The files a commit of the adoption's branch removed are the project's
# decision; they are not added again.
: >"$work/removed"

# state <action> <path> <template path>: what the adoption has to do.
#   write    the file is to be written, or the section to be appended
#   done     the file or the section is already there
#   kept     the project has its own version, or removed the file
#   blocked  the path is not a plain file of the repository
state() {
  local file="$target/$2"

  case "$1" in
    add | beside | config)
      if ! plain_path "$2" || [[ -e "$file" && ! -f "$file" ]]; then
        echo blocked
      elif [[ ! -e "$file" ]]; then
        if grep -Fxq -- "$2" "$work/removed"; then echo kept; else echo write; fi
      else
        if [[ "$1" == config ]]; then
          cp "$work/template.conf" "$work/expected"
        else
          template_file "$3" "$work/expected"
        fi
        if cmp -s "$file" "$work/expected"; then echo done; else echo kept; fi
      fi
      ;;
    section)
      if [[ -L "$file" || ! -f "$file" ]]; then
        echo kept
      elif grep -Fxq -- "$([[ "$2" == AGENTS.md ]] && echo "$agents_marker" || echo "$gitignore_marker")" "$file"; then
        echo done
      else
        echo write
      fi
      ;;
    *) echo done ;;
  esac
}

# evaluate: the state of every action, into $work/states.
evaluate() {
  : >"$work/states"
  while IFS=$'\t' read -r action path source; do
    printf '%s\t%s\t%s\t%s\n' "$(state "$action" "$path" "$source")" "$action" "$path" "$source" >>"$work/states"
  done <"$work/plan"
}

original="$current"
[[ -n "$original" ]] || original="$head"
if [[ "$mode" == branch ]]; then
  tgit log --format= --name-only --diff-filter=D "$assessed_head..$branch_tip" | LC_ALL=C sort -u >"$work/removed"
  if [[ "$current" != "$branch_name" ]]; then
    tgit switch -q "$branch_name" || fail "could not switch $target to the branch $branch_name."
  fi
elif [[ "$mode" == adopted ]]; then
  tgit log --format= --name-only --diff-filter=D "$assessed_head..$head" | LC_ALL=C sort -u >"$work/removed"
fi
evaluate

# switch_back: the branch that was checked out before, when this run
# switched to the adoption's branch only to look at it.
switch_back() {
  if [[ "$mode" == branch && "$current" != "$branch_name" ]]; then
    tgit switch -q "$original" 2>/dev/null || tgit switch -q --detach "$original" 2>/dev/null || true
  fi
}

blocked="$(awk -F'\t' '$1 == "blocked" { print "  - " $3 ": a symbolic link, a directory, or a file is in the way in the repository" }' "$work/states")"
if [[ -n "$blocked" ]]; then
  switch_back
  echo "Error: the adoption of $target stops before any change:" >&2
  printf '%s\n' "$blocked" >&2
  exit 1
fi

pending="$(awk -F'\t' '$1 == "write"' "$work/states" | wc -l | tr -d ' ')"
uncommitted="$(tgit status --porcelain=v1 --untracked-files=all | wc -l | tr -d ' ')"

if [[ "$pending" -eq 0 && "$uncommitted" -eq 0 && ("$mode" == adopted || "$publish" -eq 0) ]]; then
  switch_back
  echo "$target is adopted already: every file of the proposal is in place. Nothing changed."
  awk -F'\t' '$1 == "kept" { print "  Left as the project has it: " $3 }' "$work/states"
  exit 0
fi

# ---------------------------------------------------------------- applying
if [[ "$mode" != branch ]] && [[ "$pending" -gt 0 || "$uncommitted" -gt 0 ]]; then
  tgit switch -q -c "$branch_name" || fail "could not create the branch $branch_name in $target."
  echo "Created the branch $branch_name in $target."
elif [[ "$current" != "$branch_name" ]]; then
  echo "Switched $target to the branch $branch_name."
fi

added=()
beside=()
sections=()
while IFS=$'\t' read -r status action path source; do
  [[ "$status" == write ]] || continue
  file="$target/$path"
  case "$action" in
    add | beside)
      mkdir -p "$(dirname "$file")"
      template_file "$source" "$file.$suffix.$$"
      if [[ "$(template_mode "$source")" == "100755" ]]; then chmod +x "$file.$suffix.$$"; fi
      mv "$file.$suffix.$$" "$file"
      if [[ "$action" == add ]]; then added+=("$path"); else beside+=("$path (the template's $source)"); fi
      ;;
    config)
      mkdir -p "$(dirname "$file")"
      cp "$work/template.conf" "$file"
      added+=("$path (template $template_repository at ${template_commit:0:7})")
      ;;
    section)
      section_file "$path" "$work/section"
      [[ -z "$(tail -c 1 "$file")" ]] || printf '\n' >>"$file"
      cat "$work/section" >>"$file"
      sections+=("$path")
      ;;
  esac
done <"$work/states"

# The commit holds the files of the plan only, also those an interrupted run
# left uncommitted.
committed=0
planned_present=()
while IFS= read -r path; do
  [[ -f "$target/$path" && ! -L "$target/$path" ]] && planned_present+=("$path")
done <"$work/planned"
[[ "${#planned_present[@]}" -eq 0 ]] || tgit add -f -- "${planned_present[@]}"
if ! tgit diff --cached --quiet; then
  {
    echo "Adopt the agent-codeyard workflow (template ${template_commit:0:7})"
    echo
    echo "Applied by adopt-repository.sh from the assessment ${assessment:-(unnamed)}."
    echo "It only adds files of the workflow; the project's files stay its own:"
    echo "- added: ${#added[@]} files"
    echo "- placed beside a project file, to combine by hand: ${#beside[@]}"
    echo "- sections appended: ${sections[*]:-none}"
    echo
    echo "The template is $template_repository at $template_commit,"
    echo "recorded in .agents/template.conf for a later sync-template.sh."
  } >"$work/message"
  tgit commit -q -F "$work/message" || fail "the commit in $target failed; the files are written and not committed."
  committed=1
fi

print_list() {
  local title="$1"

  shift
  [[ $# -gt 0 ]] || return 0
  echo "$title"
  printf '  %s\n' "$@"
}

echo
print_list "Added:" ${added[@]+"${added[@]}"}
print_list "Placed beside the project's file, to combine by hand:" ${beside[@]+"${beside[@]}"}
print_list "Section of the workflow appended:" ${sections[@]+"${sections[@]}"}
mapfile -t kept < <(awk -F'\t' '$1 == "kept" { print $3 }' "$work/states")
print_list "Left as the project has it (changed or removed since the adoption):" ${kept[@]+"${kept[@]}"}
mapfile -t own < <(awk -F'\t' '$2 == "keep" || $2 == "section" { print $3 }' "$work/states")
print_list "The project's own (excluded from the template's files where the template has one):" ${own[@]+"${own[@]}"}
mapfile -t ci < <(awk -F'\t' '$2 == "ci" { print $3 }' "$work/states")
print_list "Not added, the project's CI stays as it is:" ${ci[@]+"${ci[@]}"}
echo
if [[ "$committed" -eq 1 ]]; then
  echo "Committed on $branch_name: $(tgit log -1 --format='%h %s')"
else
  echo "Nothing new to commit on $branch_name."
fi

if [[ "$publish" -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || fail "--publish needs the GitHub CLI (gh)."
  tgit remote get-url origin >/dev/null 2>&1 || fail "$target has no remote 'origin' to publish to."
  default_branch="$(cd "$target" && gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)" ||
    fail "could not read the default branch of the repository on GitHub."
  [[ -n "$default_branch" && "$default_branch" != "$branch_name" ]] ||
    fail "the default branch of the repository is '$default_branch'; the adoption is never pushed to it."
  tgit push -q origin "refs/heads/$branch_name:refs/heads/$branch_name" || fail "could not push $branch_name."
  echo "Pushed $branch_name to origin."
  existing="$(cd "$target" && gh pr list --head "$branch_name" --state open --json url --jq '.[0].url // empty')"
  if [[ -n "$existing" ]]; then
    echo "Pull request: $existing (open already)"
  else
    {
      echo "Adopts the agent-codeyard workflow around the existing project, as one additive change."
      echo
      echo "- Only adds files: no file of the project is overwritten; its history, application, dependencies, CI, and deployment are unchanged."
      echo "- Files the project already had stay its own; where the proposal said to merge, the template's version is placed beside them as \`*.$suffix.*\`, to combine by hand."
      echo "- \`.agents/template.conf\` records the template version and the files it owns, for a later \`sync-template.sh\`."
      echo
      echo "The assessment's reconstructions are observed, not approved: the owner approves requirements and architecture through the planning approval of this repository. The project's own verification commands are not set up by this change."
    } >"$work/body"
    url="$(cd "$target" && gh pr create --base "$default_branch" --head "$branch_name" \
      --title "Adopt the agent-codeyard workflow" --body-file "$work/body")" || fail "could not open the pull request."
    echo "Pull request: $url"
  fi
fi

echo
echo "Next:"
echo "  Review the branch $branch_name in $target: git -C $target diff $assessed_head..$branch_name"
[[ "${#beside[@]}" -eq 0 ]] || echo "  Combine each file placed beside the project's, then delete it."
[[ "$publish" -eq 1 ]] || echo "  Push it and open a pull request, or run again with --publish."
echo "  The project's verification commands and its baseline are the next step of the adoption."
