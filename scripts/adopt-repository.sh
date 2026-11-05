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
  echo "                 .gitignore a marked section of the workflow is appended;"
  echo "                 that of .gitignore also un-ignores the workflow's files"
  echo "                 that a rule of the project's .gitignore hides."
  echo "  merge,         the template's file is placed beside it, as"
  echo "  take-template  <name>.agent-codeyard.<ext>, to combine by hand."
  echo "  ask-owner, or no resolution, stops the run before any change."
  echo "Nothing is written under .github/workflows/: the project's CI stays as it is."
  echo
  echo "Written from the proposal, where the project has no such file:"
  echo "  scripts/verify.conf   the project's own commands as the checks of verify.sh;"
  echo "                        the project's file, which a sync does not change."
  echo "  docs/architecture.md, docs/PROJECT_REQUIREMENTS.md, docs/roadmap.md"
  echo "                        a minimal baseline from the assessment, marked"
  echo "                        'Observed, not approved' until the planning approval."
  echo "  A planning document the project has is resolved by the assessment's judgement:"
  echo "  keep-project   it is sufficient, and reused as it is;"
  echo "  reconstruct    it is not: the marked baseline is written at its path, with"
  echo "                 the project's text kept unchanged below it."
  echo "No ADR is written: the adoption reconstructs no decision of the past."
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
source "$script_dir/lib/planning.sh"
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
# relative path that names a file of the template commit, or a planning
# document of the baseline, which this script writes. A path that leaves the
# repository (absolute, or with a '.' or '..' component) or that the template
# does not have is an edited or damaged proposal, refused before any change.
baseline_documents=(docs/architecture.md docs/PROJECT_REQUIREMENTS.md docs/roadmap.md)
plain_relative='def plain_relative: type == "string" and . != "" and (startswith("/") | not)
  and (explode | any(. < 32 or . == 127) | not) and (split("/") | any(. == "" or . == "." or . == "..") | not);'
invalid_paths=()
while IFS= read -r line; do
  invalid_paths+=("$line")
done < <(jq -r "$plain_relative"' (.additions[], .collisions[]) | .path | select(plain_relative | not) | tojson' "$proposal")
while IFS= read -r path; do
  [[ " ${baseline_documents[*]} " != *" $path "* ]] || continue
  [[ "$(git -C "$root" cat-file -t "$template_commit:$path" 2>/dev/null)" == blob ]] ||
    invalid_paths+=("\"$path\" (not a file of the template commit ${template_commit:0:7})")
done < <(jq -r "$plain_relative"' (.additions[], .collisions[]) | .path | select(plain_relative)' "$proposal")
# A path an ignore rule hides is one of the template commit too, or one the
# workflow writes later, which the assessment names by an example.
later_paths=(.agents/approval-requests/x.json .agents/plans/x.md .agents/verification-baseline docs/decisions/x.md docs/PLANNING_APPROVAL.md)
while IFS= read -r line; do
  invalid_paths+=("$line")
done < <(jq -r "$plain_relative"' (.ignored // [])[] | .path | select(plain_relative | not) | tojson' "$proposal")
while IFS= read -r path; do
  [[ " ${later_paths[*]} " != *" $path "* ]] || continue
  [[ "$(git -C "$root" cat-file -t "$template_commit:$path" 2>/dev/null)" == blob ]] ||
    invalid_paths+=("\"$path\" (hidden by an ignore rule, but not a path of the workflow)")
done < <(jq -r "$plain_relative"' (.ignored // [])[] | .path | select(plain_relative)' "$proposal")
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
#   verify   scripts/verify.conf, the project's commands, written by this script
#   document a planning document of the baseline, written by this script
#   reconstruct  a planning document of the baseline written by this script
#            at the path of the project's insufficient one, whose text it
#            keeps unchanged below
#   section  a marked section appended to the project's AGENTS.md or .gitignore
#   keep     the project's file, unchanged
#   present  the project's file, identical to the template's
#   ci       a CI workflow, left out
problems=()
exclusions=()
verify_path="scripts/verify.conf"
: >"$work/plan"
while IFS=$'\t' read -r path ownership; do
  if [[ "$path" == ".agents/template.conf" ]]; then
    printf 'config\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  elif [[ "$path" == "$verify_path" ]]; then
    printf 'verify\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  elif [[ " ${baseline_documents[*]} " == *" $path "* ]]; then
    printf 'document\t%s\t%s\n' "$path" "$path" >>"$work/plan"
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
  # A planning document of the baseline is the project's: reused when the
  # assessment judged it sufficient, reconstructed when not.
  if [[ " ${baseline_documents[*]} " == *" $path "* ]]; then
    [[ "$ownership" != template || ("$resolution" != keep-project && "$resolution" != reconstruct) ]] || exclusions+=(":(exclude)$path")
    case "$resolution" in
      keep-project) printf 'keep\t%s\t%s\n' "$path" "$path" >>"$work/plan" ;;
      reconstruct)
        if [[ "$kind" == file ]]; then
          printf 'reconstruct\t%s\t%s\n' "$path" "$path" >>"$work/plan"
        else
          problems+=("$path: resolved as reconstruct, but the project has a $kind there, not a document. Move it, or resolve it as keep-project.")
        fi
        ;;
      ask-owner)
        problems+=("$path: the proposal leaves it to the owner (ask-owner): ${rationale:-no rationale}. Decide whether the project's document is sufficient: keep-project reuses it, reconstruct writes the marked baseline above its text. Set the resolution in the proposal and pass it with --proposal.")
        ;;
      *)
        problems+=("$path: a planning document of the baseline, resolved as '${resolution:-nothing}'. Resolve it as keep-project (sufficient, reused) or reconstruct (not sufficient: the marked baseline above the project's text) in the proposal and pass it with --proposal.")
        ;;
    esac
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

# The checks and the planning documents are written also where the template
# has no such file, unless the project has its own: a collision of the
# proposal, or a file of the assessed commit. Its own checks are reused as
# they are; a planning document the proposal does not judge stops the run,
# as a proposal of an older assessment would leave it.
for path in "$verify_path" "${baseline_documents[@]}"; do
  jq -e --arg path "$path" '[.additions[], .collisions[]] | any(.path == $path)' "$proposal" >/dev/null && continue
  if tgit cat-file -e "$assessed_head:$path" 2>/dev/null; then
    [[ "$path" == "$verify_path" ]] ||
      problems+=("$path: the project has this planning document, and the proposal does not judge whether it is sufficient. Assess the repository again.")
    continue
  fi
  if [[ "$path" == "$verify_path" ]]; then
    printf 'verify\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  else
    printf 'document\t%s\t%s\n' "$path" "$path" >>"$work/plan"
  fi
done

# The paths the adoption writes; a partial adoption may have left them
# uncommitted on its branch.
awk -F'\t' '$1 == "add" || $1 == "beside" || $1 == "config" || $1 == "verify" || $1 == "document" || $1 == "reconstruct" || $1 == "section" { print $2 }' "$work/plan" | LC_ALL=C sort >"$work/planned"

# The paths of the workflow that a rule of the project's .gitignore hides are
# un-ignored in its section: a file of .agents/, and a path the workflow
# writes later, by its directory and extension, since the workflow adds more
# of them; any other path by itself. A rule of another file (a .gitignore
# further down, .git/info/exclude) or of an ignored directory above the path
# cannot be undone from there: such a path is named after the commit.
: >"$work/unignore"
if grep -Fxq $'section\t.gitignore\t.gitignore' "$work/plan"; then
  while IFS= read -r path; do
    [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]] || continue
    name="${path##*/}"
    if [[ "$path" == */* && "$name" == ?*.* && ("$path" == .agents/* || " ${later_paths[*]} " == *" $path "*) ]]; then
      printf '!/%s/*.%s\n' "${path%/*}" "${name##*.}"
    else
      printf '!/%s\n' "$path"
    fi
  done < <(jq -r '(.ignored // [])[] | select(.rule.source == ".gitignore" and .ignored_directory == null) | .path' "$proposal") |
    awk '!seen[$0]++' >"$work/unignore"
fi

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
# the project's, so a later sync adds none of the template's either, and so
# are the checks of scripts/verify.conf, the project's own commands.
paths_value="$(jq -r '.ownership.template_paths | join(" ")' "$proposal") :(exclude).github/workflows :(exclude)$verify_path"
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
      if [[ -s "$work/unignore" ]]; then
        printf '# The files of the workflow that a rule above would hide; the workflow\n# commits them.\n'
        cat "$work/unignore"
      fi
    } >"$2"
  fi
}

# verify_file <file>: scripts/verify.conf with the verification commands of
# the proposal, the project's own, in the directory each belongs to. Without
# one, a check that fails says so: nothing of the project is verified yet,
# and the verification does not claim it is.
verify_file() {
  local name command directory origin source

  {
    echo "# Required verification checks for ./scripts/verify.sh: the project's own"
    echo "# commands, taken over by adopt-repository.sh from the proposal of the"
    echo "# assessment ${assessment:-(unnamed)}. The project's CI runs as before; these"
    echo "# checks run the same commands for the workflow. This file is the project's"
    echo "# own, which a sync of the template does not change. Its format, groups,"
    echo "# budgets, and exceptions: docs/development.md, \"Configuring verification\"."
    echo "#"
    echo "# Record the baseline once, before any change: ./scripts/verify.sh --baseline"
    echo "# A check that fails then is a pre-existing failure: it stays visible as"
    echo "# KNOWN and fails the verification until it is fixed, or until the owner"
    echo "# accepts it here with 'accepted-failure: <check> <reason>'."
    echo
  } >"$1"
  if [[ "$(jq '.verification // [] | length' "$proposal")" -eq 0 ]]; then
    {
      echo "# The assessment found no command of the project to verify it with."
      echo "no-project-check: echo 'scripts/verify.conf has no check of the project yet: add its test, lint, and build commands. Until then nothing of the project is verified.' >&2; exit 1"
    } >>"$1"
    return 0
  fi
  # The fields are separated by the unit separator: a tab, as white space,
  # would let 'read' drop an empty directory.
  while IFS=$'\x1f' read -r name command directory origin source; do
    printf '# %s, %s in %s.\n' "$name" "$origin" "$source" >>"$1"
    case "$name" in
      paths | budget-seconds | heavy | accepted-failure)
        printf '# Not taken over: %s is a reserved word of this file. Add the check under another name.\n' "$name" >>"$1"
        continue
        ;;
    esac
    if [[ -n "$directory" && "$directory" != "." ]]; then
      printf '%s: cd %q && %s\n' "$name" "$directory" "$command" >>"$1"
    else
      printf '%s: %s\n' "$name" "$command" >>"$1"
    fi
  done < <(jq -r '.verification[] | select((.command | type) == "string" and (.command | test("[\n\r]") | not))
    | [.name, .command, (.directory // ""), (.origin // "declared"), (.source // "the project")] | map(tostring | gsub("\u001f"; " ")) | join("\u001f")' "$proposal")
  jq -r '.verification[] | select((.command | type) != "string" or (.command | test("[\n\r]"))) | "# Not taken over: \(.name), a command of more than one line. Add it as a script."' "$proposal" >>"$1"
}

# document_file <path> <file>: the planning document <path> of the baseline,
# from the assessment: what the files show, the assumptions, the risks, and
# the questions, marked as observed and not approved. The project's own
# documents are named first, to be reused.
document_file() {
  local mark

  mark="$PLANNING_OBSERVED_MARK Reconstructed by adopt-repository.sh from the assessment ${assessment:-(unnamed)} of the existing project: what its files show and what the assessment inferred from them, not a decision of the owner. The owner approves it through the planning approval of this repository (./scripts/start-planning.sh, then ./scripts/finish-planning.sh); an approved document no longer carries this mark."
  jq -r --arg path "$1" --arg mark "$mark" --arg branch "$branch_name" '
    def list(f): if length == 0 then "None recorded by the assessment.\n" else map(f) | join("") end;
    def code: "`\(.)`";
    (.baseline // {}) as $b
    | ($b.documents // [] | map(select(.path != $path))) as $documents
    | if $path == "docs/architecture.md" then
        "# Architecture\n\n\($mark)\n\n"
        + (if ($b.summary // "") != "" then "\($b.summary)\n\n" else "" end)
        + "## Existing documents\n\nThe project'"'"'s own documents come first: where they describe the architecture, they are reused, and this file only links them into the planning.\n\n"
        + ($documents | list("- \(.path | code) (\(.kind))\(if .title then ": \(.title)" else "" end)\n"))
        + "\n## Observed architecture\n\nWhat the files of the project show, with the facts of the assessment it rests on.\n\n"
        + (($b.facts // []) | list("- \(.statement) (\(.evidence | map(code) | join(", ")))\n"))
        + "\n## Assumptions\n\n" + (($b.assumptions // []) | list("- \(.statement)\n  - basis: \(.basis)\n"))
        + "\n## Risks\n\n" + (($b.risks // []) | list("- \(.risk)\n  - basis: \(.basis)\n"))
        + "\n## Unknowns\n\n" + (($b.questions // []) | list("- \(.question)\n  - settles: \(.why)\n"))
        + "\n## Decisions\n\nNo decision of the past is recorded: the adoption reconstructs no ADR. Decisions made from now on are recorded in `docs/decisions/`.\n"
      elif $path == "docs/PROJECT_REQUIREMENTS.md" then
        "\($mark)\n\n"
        + "Project Grill completes these requirements with the owner in the first planning (`./scripts/start-planning.sh`), starting from what the project already is.\n\n"
        + "## Known requirements\n\nThe project'"'"'s own documents that state requirements, to be reused:\n\n"
        + ($documents | map(select(.kind == "requirements" or .kind == "readme")) | list("- \(.path | code) (\(.kind))\(if .title then ": \(.title)" else "" end)\n"))
        + (if ($b.summary // "") != "" then "\nWhat the assessment observed: \($b.summary)\n" else "" end)
        + "\n## Open questions of the assessment\n\n" + (($b.questions // []) | list("- \(.question)\n  - settles: \(.why)\n"))
      else
        "# Roadmap\n\n\($mark)\n\n## Near-term work\n\nThe work that makes the baseline of the adopted project honest and complete, before new features:\n\n"
        + "- Review and merge the adoption (the branch `\($branch)`).\n"
        + "- Record the baseline of the verification once, before any change: `./scripts/verify.sh --baseline`. It runs the project'"'"'s own commands of `scripts/verify.conf`.\n"
        + ((.execution_needed // []) | map("  - It needs: \(.what) (\(.why)); side effects: \(.side_effects)\n") | join(""))
        + "- Fix each pre-existing failure the baseline records, or accept it as an exception in `scripts/verify.conf`.\n"
        + (if (($b.questions // []) | length) == 0 then "" else "- Answer the open questions of the assessment:\n" + ($b.questions | map("  - \(.question)\n") | join("")) end)
        + "- Approve the planning: `./scripts/start-planning.sh`, then `./scripts/finish-planning.sh`.\n"
        + "\n## Later phases\n\n- Add features once the planning is approved.\n"
      end' "$proposal" >"$2"
  [[ "$1" == docs/PROJECT_REQUIREMENTS.md ]] || return 0
  # The requirements keep the sections of the template's, which Project Grill
  # completes, below the observed part; without them, a draft of their own.
  mv "$2" "$2.observed"
  if template_file "$1" "$2.template" 2>/dev/null && grep -Fqx "Approved at: Not approved" "$2.template"; then
    awk -v observed="$2.observed" '
      { print }
      /^Approved at: Not approved$/ && !done {
        print ""
        while ((getline line < observed) > 0) print line
        done = 1
      }' "$2.template" >"$2"
  else
    { printf '# Project Requirements\n\nStatus: Draft\nApproved at: Not approved\n\n'; cat "$2.observed"; } >"$2"
  fi
  rm -f "$2.observed" "$2.template"
}

# reconstruct_file <path> <file>: the planning document <path> of the
# baseline, written where the assessment judged the project's own not
# sufficient: the marked baseline, then the project's text as the assessed
# commit has it, unchanged, for the owner to fold into the planning.
reconstruct_file() {
  local rationale

  rationale="$(jq -r --arg path "$1" '[.collisions[] | select(.path == $path) | .rationale // ""][0] // "" | gsub("[\n\r]+"; " ")' "$proposal")"
  document_file "$1" "$2"
  {
    printf '\n## The project'"'"'s document, as it was\n\n'
    printf 'The assessment judged `%s` not sufficient as the baseline: %s\n' "$1" "${rationale:-no rationale given}"
    printf 'Its text follows unchanged, for the owner to fold into the planning or to keep where it holds.\n\n'
    tgit show "$assessed_head:$1"
  } >>"$2"
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
    add | beside | config | verify | document)
      if ! plain_path "$2" || [[ -e "$file" && ! -f "$file" ]]; then
        echo blocked
      elif [[ ! -e "$file" ]]; then
        if grep -Fxq -- "$2" "$work/removed"; then echo kept; else echo write; fi
      else
        if [[ "$1" == config ]]; then
          cp "$work/template.conf" "$work/expected"
        elif [[ "$1" == verify ]]; then
          verify_file "$work/expected"
        elif [[ "$1" == document ]]; then
          document_file "$2" "$work/expected"
        else
          template_file "$3" "$work/expected"
        fi
        if cmp -s "$file" "$work/expected"; then echo done; else echo kept; fi
      fi
      ;;
    reconstruct)
      if ! plain_path "$2" || [[ -e "$file" && ! -f "$file" ]]; then
        echo blocked
      elif [[ ! -e "$file" ]]; then
        echo kept
      else
        reconstruct_file "$2" "$work/expected"
        tgit show "$assessed_head:$2" >"$work/original" 2>/dev/null || : >"$work/original"
        if cmp -s "$file" "$work/expected"; then
          echo done
        elif cmp -s "$file" "$work/original"; then
          echo write
        else
          echo kept
        fi
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

# still_hidden: the paths of the workflow that an ignore rule of the
# repository still hides, with the rule; the owner changes that rule.
still_hidden() {
  local rule path

  jq -r '(.ignored // [])[] | .path' "$proposal" | tr '\n' '\0' |
    tgit check-ignore -z -v -n --no-index --stdin 2>/dev/null |
    while IFS= read -r -d '' source && IFS= read -r -d '' line && IFS= read -r -d '' rule && IFS= read -r -d '' path; do
      [[ -n "$source" && "$rule" != '!'* ]] || continue
      printf '%s (%s in %s:%s)\n' "$path" "$rule" "$source" "$line"
    done || true
}
print_hidden() {
  local hidden

  hidden="$(still_hidden)"
  [[ -n "$hidden" ]] || return 0
  echo "Still hidden by an ignore rule the adoption cannot change; the workflow commits these paths, so change the rule:"
  printf '%s\n' "$hidden" | sed 's/^/  /'
}

pending="$(awk -F'\t' '$1 == "write"' "$work/states" | wc -l | tr -d ' ')"
uncommitted="$(tgit status --porcelain=v1 --untracked-files=all | wc -l | tr -d ' ')"

if [[ "$pending" -eq 0 && "$uncommitted" -eq 0 && ("$mode" == adopted || "$publish" -eq 0) ]]; then
  # The ignore rules are those of the adoption's branch, read before the
  # switch back to the branch the run started from.
  hidden="$(print_hidden)"
  switch_back
  echo "$target is adopted already: every file of the proposal is in place. Nothing changed."
  awk -F'\t' '$1 == "kept" { print "  Left as the project has it: " $3 }' "$work/states"
  [[ -z "$hidden" ]] || printf '%s\n' "$hidden"
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
written=()
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
    verify)
      mkdir -p "$(dirname "$file")"
      verify_file "$file"
      written+=("$path ($(jq '.verification // [] | length' "$proposal") checks of the project from the proposal)")
      ;;
    document)
      mkdir -p "$(dirname "$file")"
      document_file "$path" "$file"
      written+=("$path (observed, not approved)")
      ;;
    reconstruct)
      reconstruct_file "$path" "$file.$suffix.$$"
      mv "$file.$suffix.$$" "$file"
      written+=("$path (observed, not approved, above the project's text, which the assessment judged not sufficient)")
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
    echo "- written from the assessment: ${#written[@]} (the project's checks, and the planning"
    echo "  documents of the baseline, observed, not approved)"
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
print_list "Written from the assessment:" ${written[@]+"${written[@]}"}
print_list "Placed beside the project's file, to combine by hand:" ${beside[@]+"${beside[@]}"}
print_list "Section of the workflow appended:" ${sections[@]+"${sections[@]}"}
mapfile -t kept < <(awk -F'\t' '$1 == "kept" { print $3 }' "$work/states")
print_list "Left as the project has it (changed or removed since the adoption):" ${kept[@]+"${kept[@]}"}
mapfile -t own < <(awk -F'\t' '$2 == "keep" || $2 == "section" { print $3 }' "$work/states")
print_list "The project's own (excluded from the template's files where the template has one):" ${own[@]+"${own[@]}"}
mapfile -t ci < <(awk -F'\t' '$2 == "ci" { print $3 }' "$work/states")
print_list "Not added, the project's CI stays as it is:" ${ci[@]+"${ci[@]}"}
unignored=()
[[ " ${sections[*]-} " != *" .gitignore "* ]] || mapfile -t unignored <"$work/unignore"
print_list "Un-ignored in the section of .gitignore, as the workflow commits them:" ${unignored[@]+"${unignored[@]}"}
print_hidden
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
      echo "- \`scripts/verify.conf\` runs the project's own commands from the assessment; the project's CI is not replaced."
      echo
      echo "The planning documents this change writes are reconstructions, marked *observed, not approved*: the owner approves them through the planning approval of this repository. No ADR is written. Before the merge, record the baseline of the verification with \`./scripts/verify.sh --baseline\` on this branch: it runs the project's commands, and a check that fails then stays visible as a known failure."
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
echo "  Record the baseline on $branch_name, before any change: cd $target && ./scripts/verify.sh --baseline"
echo "    It runs the project's own commands of scripts/verify.conf; commit .agents/verification-baseline."
echo "    A check that fails then stays visible as KNOWN and fails the verification until it is"
echo "    fixed or the owner accepts it with 'accepted-failure: <check> <reason>' in scripts/verify.conf."
echo "  The planning documents are observed, not approved: approve them with ./scripts/start-planning.sh"
echo "    and ./scripts/finish-planning.sh in $target."
