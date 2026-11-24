#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sync-template-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "sync-template test failed: $*" >&2
  exit 1
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name="Sync Test" -c user.email="sync-test@example.com" commit -qm "$2"
}

lines() {
  printf '%s\n' "$@"
}

# A template with two versions. From the first to the second it changes a
# file in three ways, adds one, removes one, and changes a file it does not
# own.
template="$tmp/template"
mkdir -p "$template/scripts" "$template/docs" "$template/.agents"
git -C "$template" init -q -b main
lines "repository: $template" "" "paths: scripts docs/guide.md .agents/template.conf :(exclude)scripts/local.sh" \
  >"$template/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$template/scripts/sync-template.sh"
lines "#!/usr/bin/env bash" "echo untouched one" >"$template/scripts/untouched.sh"
lines "top" "a" "b" "c" "middle" "d" "e" "f" "bottom" >"$template/scripts/both.sh"
lines "first" "contested" "last" >"$template/scripts/conflict.sh"
lines "to be removed" >"$template/scripts/gone.sh"
lines "becomes executable" >"$template/scripts/make-exec.sh"
lines "stops being executable" >"$template/scripts/drop-exec.sh"
chmod +x "$template/scripts/drop-exec.sh"
lines "template readme, before version one" >"$template/README.md"
lines "guide" >"$template/docs/guide.md"
chmod +x "$template/scripts/untouched.sh"
# An earlier version that differs only in a file the project replaced, so it
# matches the project exactly as well as version one does.
commit_all "$template" "Version zero"
lines "template readme" >"$template/README.md"
commit_all "$template" "Version one"
version_one="$(git -C "$template" rev-parse HEAD)"

lines "#!/usr/bin/env bash" "echo untouched two" >"$template/scripts/untouched.sh"
lines "top" "a" "b" "c" "middle" "d" "e" "f" "bottom changed by the template" >"$template/scripts/both.sh"
lines "first" "contested by the template" "last" >"$template/scripts/conflict.sh"
lines "#!/usr/bin/env bash" "echo new" >"$template/scripts/new.sh"
chmod +x "$template/scripts/new.sh"
lines "excluded" >"$template/scripts/local.sh"
git -C "$template" rm -q scripts/gone.sh
chmod +x "$template/scripts/make-exec.sh"
chmod -x "$template/scripts/drop-exec.sh"
lines "template readme, second version" >"$template/README.md"
# The sync script itself changes too, in length, while a sync runs it.
{
  sed -n 1p "$source_root/scripts/sync-template.sh"
  for number in $(seq 1 400); do echo "# line $number added in version two"; done
  sed 1d "$source_root/scripts/sync-template.sh"
} >"$template/scripts/sync-template.sh"
commit_all "$template" "Version two"
version_two="$(git -C "$template" rev-parse HEAD)"

# A later version on its own branch, which changes only one template file.
git -C "$template" switch -q -c three
lines "top" "a" "b" "c" "middle changed in version three" "d" "e" "f" "bottom changed by the template" >"$template/scripts/both.sh"
commit_all "$template" "Version three"
version_three="$(git -C "$template" rev-parse HEAD)"
git -C "$template" switch -q main

# A branch on which a template file changes and is changed back.
git -C "$template" switch -q -c reverted
lines "first" "contested, changed for a while" "last" >"$template/scripts/conflict.sh"
commit_all "$template" "Change a file"
changed_for_a_while="$(git -C "$template" rev-parse HEAD)"
lines "first" "contested by the template" "last" >"$template/scripts/conflict.sh"
commit_all "$template" "Change the file back"
git -C "$template" switch -q main

# A project created from version one (or the given version), without the
# template's history, that changed some template files and has files of its
# own.
setup_project() {
  local project="$tmp/$1"

  mkdir -p "$project"
  git -C "$template" archive "${2:-$version_one}" | tar -x -C "$project"
  git -C "$project" init -q -b main
  commit_all "$project" "Create the project from the template"
  sed 's/^top$/top changed by the project/' "$project/scripts/both.sh" >"$project/both.tmp"
  mv "$project/both.tmp" "$project/scripts/both.sh"
  lines "first" "contested by the project" "last" >"$project/scripts/conflict.sh"
  lines "project readme" >"$project/README.md"
  mkdir -p "$project/src"
  lines "project code" >"$project/src/app.txt"
  lines "project script" >"$project/scripts/local.sh"
  commit_all "$project" "Project work"
  printf '%s\n' "$project"
}

run_sync() {
  local project="$1"

  shift
  (cd "$project" && PATH="$ISOLATED_PATH" ./scripts/sync-template.sh "$@") >"$project.out" 2>&1
}

# Without a recorded version the base is found from the files: the newest of
# the template versions that match the project best. Each kind of change is
# handled. A conflict fails the run after everything else is done.
project="$(setup_project sync)"
head_before="$(git -C "$project" rev-parse HEAD)"
if run_sync "$project"; then
  cat "$project.out" >&2
  fail "a sync that leaves a conflict returned success"
fi
grep -Fq "matches template commit ${version_one:0:7} best" "$project.out" || {
  cat "$project.out" >&2
  fail "the template version of the project was not found"
}
[[ "$(git -C "$project" branch --show-current)" == "fix/sync-template-${version_two:0:7}" ]] ||
  fail "the sync did not create a branch from main"
[[ "$(git -C "$project" rev-parse HEAD)" == "$head_before" ]] || fail "the sync created a commit"

grep -Fqx "echo untouched two" "$project/scripts/untouched.sh" || fail "an unchanged file was not replaced"
[[ -x "$project/scripts/untouched.sh" ]] || fail "a replaced file lost its executable bit"
[[ "$(tr '\n' ' ' <"$project/scripts/both.sh")" == "top changed by the project a b c middle d e f bottom changed by the template " ]] ||
  fail "changes of both sides were not merged"
grep -Fq "<<<<<<< project" "$project/scripts/conflict.sh" || fail "a conflict was not marked in the file"
grep -Fq "contested by the project" "$project/scripts/conflict.sh" || fail "the project's side of a conflict was lost"
grep -Fq "contested by the template" "$project/scripts/conflict.sh" || fail "the template's side of a conflict is missing"
[[ -x "$project/scripts/new.sh" ]] || fail "a new template file was not added as an executable"
[[ -x "$project/scripts/make-exec.sh" ]] || fail "a file the template made executable is not executable"
[[ ! -x "$project/scripts/drop-exec.sh" ]] || fail "a file the template made non-executable is still executable"
[[ -f "$project/scripts/gone.sh" ]] || fail "a file the template removed was deleted"
grep -Fq "scripts/gone.sh: removed from the template" "$project.out" || fail "a removed template file was not reported"
grep -Eq "^  scripts/conflict.sh$" "$project.out" || fail "the conflict was not reported"

# Files outside the template's list are the project's own.
grep -Fqx "project readme" "$project/README.md" || fail "a file the template does not own was changed"
grep -Fqx "project code" "$project/src/app.txt" || fail "a project file was changed"
grep -Fqx "project script" "$project/scripts/local.sh" || fail "an excluded file was overwritten"

grep -Fqx "commit: $version_two" "$project/.agents/template.conf" || fail "the new template version was not recorded"
grep -Fq "Version two" "$project.out" || fail "the template's changes were not listed"
# The script replaced itself while running and still finished.
grep -Fqx "# line 400 added in version two" "$project/scripts/sync-template.sh" || fail "the sync script was not updated"
grep -Fq "Push the branch and open a pull request." "$project.out" || fail "the sync did not finish after replacing its own script"
if compgen -G "$project/scripts/*.sync-template.*" >/dev/null; then fail "a staging file was left behind"; fi

# With the version recorded, a second sync has nothing to do and changes nothing.
git -C "$project" checkout -q -- scripts/conflict.sh
commit_all "$project" "Sync"
before="$(git -C "$project" rev-parse HEAD)$(git -C "$project" status --porcelain)"
run_sync "$project" || fail "a second sync failed"
grep -Fq "Already up to date" "$project.out" || fail "a second sync was not reported as up to date"
[[ "$(git -C "$project" rev-parse HEAD)$(git -C "$project" status --porcelain)" == "$before" ]] ||
  fail "a second sync changed something"

# Without a conflict the sync succeeds; --from and --to select the versions.
project="$(setup_project clean)"
git -C "$project" checkout -q HEAD~1 -- scripts/conflict.sh
commit_all "$project" "Drop the conflicting change"
git -C "$project" switch -q -c chore/sync
run_sync "$project" --from "$version_one" --to "$version_two" || {
  cat "$project.out" >&2
  fail "a sync without conflicts failed"
}
[[ "$(git -C "$project" branch --show-current)" == "chore/sync" ]] || fail "the sync left the current branch"
grep -Fqx "contested by the template" "$project/scripts/conflict.sh" || fail "an unchanged file was not replaced with --from"
if grep -Fq "best" "$project.out"; then fail "--from did not replace the search for a base"; fi

# The project decides what is its own: a file it excludes in its own list is
# not taken over, although the template lists it. A template file that the
# project replaced with a symbolic link is not written through.
project="$(setup_project owned)"
git -C "$project" checkout -q HEAD~1 -- scripts/conflict.sh
sed 's|^paths: .*|& :(exclude)scripts/untouched.sh|' "$project/.agents/template.conf" >"$project/conf.tmp"
mv "$project/conf.tmp" "$project/.agents/template.conf"
rm "$project/scripts/new.sh" 2>/dev/null || true
ln -s ../src/app.txt "$project/scripts/new.sh"
commit_all "$project" "Own a script and link another"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "a sync with a project exclusion failed"
}
grep -Fqx "echo untouched one" "$project/scripts/untouched.sh" || fail "a file the project excludes was taken over"
[[ -L "$project/scripts/new.sh" ]] || fail "a symbolic link in the project was replaced"
grep -Fqx "project code" "$project/src/app.txt" || fail "the sync wrote through a symbolic link"
grep -Fq "scripts/new.sh: is, or lies under, a symbolic link" "$project.out" || fail "the symbolic link was not reported"

# When several template versions match the project equally well and differ in
# template files, the base is not guessed: taking the newest would skip a
# template change to a file the project changed too.
project="$(setup_project ambiguous "$version_two")"
if run_sync "$project" --to three; then
  cat "$project.out" >&2
  fail "an ambiguous template version was guessed"
fi
grep -Fq "cannot be determined" "$project.out" || fail "the ambiguity was not reported"
grep -Fq "${version_two:0:7}" "$project.out" || fail "the candidate versions were not listed"
[[ -z "$(git -C "$project" status --porcelain)" && "$(git -C "$project" branch --show-current)" == "main" ]] ||
  fail "an ambiguous sync changed the project"
run_sync "$project" --to three --from "$version_two" || {
  cat "$project.out" >&2
  fail "a sync with an explicit base failed"
}
[[ "$(tr '\n' ' ' <"$project/scripts/both.sh")" == "top changed by the project a b c middle changed in version three d e f bottom changed by the template " ]] ||
  fail "the template change was not merged with an explicit base"
grep -Fqx "commit: $version_three" "$project/.agents/template.conf" || fail "the version was not recorded"

# The same holds when the equally good versions lie between two that are
# identical: a file that changed and was changed back.
project="$(setup_project reverted "$changed_for_a_while")"
if run_sync "$project" --to reverted; then
  cat "$project.out" >&2
  fail "a version between a change and its revert was guessed"
fi
grep -Fq "cannot be determined" "$project.out" || fail "the ambiguity around a revert was not reported"

# A project that already has the target version, but no record of it, gets
# the record and nothing else.
project="$tmp/unrecorded"
mkdir -p "$project"
git -C "$template" archive "$version_two" | tar -x -C "$project"
git -C "$project" init -q -b main
commit_all "$project" "Create the project from the template"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "recording the version of an up-to-date project failed"
}
[[ "$(git -C "$project" status --porcelain)" == " M .agents/template.conf" ]] ||
  fail "recording the version changed more than the configuration"
grep -Fqx "commit: $version_two" "$project/.agents/template.conf" || fail "the version was not recorded"
[[ "$(git -C "$project" branch --show-current)" != "main" ]] || fail "the version was recorded on main"

# A sync from another location, such as a fork, records that location, so
# the next sync continues from there without the option.
fork="$tmp/fork"
git clone -q "$template" "$fork" 2>/dev/null
lines "#!/usr/bin/env bash" "echo untouched in the fork" >"$fork/scripts/untouched.sh"
commit_all "$fork" "Fork change"
project="$tmp/forked"
mkdir -p "$project"
git -C "$template" archive "$version_two" | tar -x -C "$project"
git -C "$project" init -q -b main
commit_all "$project" "Create the project from the template"
run_sync "$project" --template "$fork" --from "$version_two" || {
  cat "$project.out" >&2
  fail "a sync from a fork failed"
}
grep -Fqx "echo untouched in the fork" "$project/scripts/untouched.sh" || fail "the fork's change was not taken over"
grep -Fqx "repository: $fork" "$project/.agents/template.conf" || fail "the fork was not recorded as the template"
commit_all "$project" "Sync from the fork"
run_sync "$project" || {
  cat "$project.out" >&2
  fail "the next sync did not continue from the recorded fork"
}
grep -Fq "Already up to date" "$project.out" || fail "the next sync from the fork was not up to date"

# Switching to another location that is at the recorded commit records the
# location, although no file changes.
same="$tmp/same-fork"
git clone -q "$fork" "$same" 2>/dev/null
run_sync "$project" --template "$same" || {
  cat "$project.out" >&2
  fail "switching to a location at the same commit failed"
}
grep -Fqx "repository: $same" "$project/.agents/template.conf" || fail "the new location at the same commit was not recorded"

# The configuration is written by the sync, so a linked configuration file or
# a linked .agents directory stops it before anything changes.
project="$(setup_project linked-config)"
rm "$project/.agents/template.conf"
ln -s ../src/app.txt "$project/.agents/template.conf"
commit_all "$project" "Link the configuration"
if run_sync "$project" --template "$template"; then fail "a linked configuration file was accepted"; fi
grep -Fqx "project code" "$project/src/app.txt" || fail "the sync wrote through a linked configuration file"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"

project="$(setup_project linked-directory)"
mv "$project/.agents" "$project/agents-elsewhere"
ln -s agents-elsewhere "$project/.agents"
commit_all "$project" "Link the directory"
if run_sync "$project"; then fail "a linked .agents directory was accepted"; fi
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"

# Uncommitted changes, an unknown version, and an unknown option are refused
# before anything changes.
project="$(setup_project refused)"
printf 'uncommitted\n' >>"$project/README.md"
if run_sync "$project"; then fail "a checkout with uncommitted changes was synced"; fi
git -C "$project" checkout -q -- README.md
if run_sync "$project" --to no-such-version; then fail "an unknown template version was accepted"; fi
if run_sync "$project" --from 0123456789012345678901234567890123456789; then fail "an unknown base commit was accepted"; fi
if run_sync "$project" --everything; then fail "an unknown option was accepted"; fi
if run_sync "$project" --template "$tmp/no-such-template"; then fail "a missing template was accepted"; fi
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "a refused sync changed the project"
[[ "$(git -C "$project" branch --show-current)" == "main" ]] || fail "a refused sync created a branch"

# A template version that only extends 'paths:' to files that already exist
# and do not change: the files are not in the diff. A project without one gets
# it; a project with its own content keeps it, and the file is reported.
owned="$tmp/owned-template"
mkdir -p "$owned/scripts" "$owned/docs" "$owned/.agents"
git -C "$owned" init -q -b main
lines "repository: $owned" "" "paths: scripts .agents/template.conf" >"$owned/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$owned/scripts/sync-template.sh"
lines "tool one" >"$owned/scripts/tool.sh"
lines "removed with the listing" >"$owned/docs/gone.md"
lines "guide" >"$owned/docs/guide.md"
lines "notes" >"$owned/docs/notes.md"
lines "#!/usr/bin/env bash" "echo helper" >"$owned/docs/helper.sh"
chmod +x "$owned/docs/helper.sh"
commit_all "$owned" "Owned one"
owned_one="$(git -C "$owned" rev-parse HEAD)"
lines "repository: $owned" "" "paths: scripts docs .agents/template.conf :(exclude)docs/notes.md" >"$owned/.agents/template.conf"
lines "tool two" >"$owned/scripts/tool.sh"
lines "template added" >"$owned/docs/added.md"
git -C "$owned" rm -q docs/gone.md
lines "edited helper" >>"$owned/docs/notes.md"
lines "#!/usr/bin/env bash" "echo helper two" >"$owned/docs/helper.sh"
commit_all "$owned" "Owned two: lists the docs"
for case_name in lacks has; do
  project="$tmp/owned-$case_name"
  mkdir -p "$project"
  git -C "$owned" archive "$owned_one" | tar -x -C "$project"
  git -C "$project" init -q -b main
  rm -rf "$project/docs"
  rm "$project/scripts/tool.sh"
  mkdir -p "$project/docs"
  if [[ "$case_name" == "has" ]]; then
    lines "project guide" >"$project/docs/guide.md"
    lines "project helper" >"$project/docs/helper.sh"
  fi
  commit_all "$project" "Create the project"
  run_sync "$project" --from "$owned_one" || {
    cat "$project.out" >&2
    fail "a sync that only extends the template paths failed"
  }
  [[ ! -e "$project/scripts/tool.sh" ]] || fail "an always-owned file the project deleted was added again"
  grep -Fq "scripts/tool.sh: changed in the template, but the project has no such file; left out" "$project.out" ||
    fail "a deleted, changed template file was not reported as left out"
  [[ ! -e "$project/docs/notes.md" ]] || fail "a file the template excludes was added as newly owned"
  if [[ "$case_name" == "lacks" ]]; then
    grep -Fqx "guide" "$project/docs/guide.md" || fail "a newly owned file was not added"
    [[ -x "$project/docs/helper.sh" ]] || fail "a newly owned file lost its executable bit"
    grep -Fqx "echo helper two" "$project/docs/helper.sh" || fail "a newly owned file that also changed was not added"
    grep -Fq "docs/helper.sh (newly owned by the template)" "$project.out" || fail "a changed, newly owned file was not reported as added"
    grep -Fq "docs/guide.md (newly owned by the template)" "$project.out" || fail "an added newly owned file was not reported"
  else
    grep -Fqx "project guide" "$project/docs/guide.md" || fail "a project file at a newly owned path was replaced"
    grep -Fq "docs/guide.md: newly owned by the template, but the project has its own version" "$project.out" ||
      fail "a kept project file at a newly owned path was not reported"
    grep -Fqx "project helper" "$project/docs/helper.sh" || fail "a project file at a newly owned and changed path was merged or replaced"
    grep -Fq "docs/helper.sh: newly owned by the template, but the project has its own version" "$project.out" ||
      fail "a kept project file at a newly owned and changed path was not reported"
    if grep -Fq "<<<<<<<" "$project/docs/helper.sh"; then fail "a newly owned file was merged"; fi
  fi
done

# A file the template adds in the range, where the project already has its own
# file at that path, is never overwritten silently: it is merged against
# nothing and left as a conflict.
project="$tmp/owned-added"
mkdir -p "$project"
git -C "$owned" archive "$owned_one" | tar -x -C "$project"
git -C "$project" init -q -b main
mkdir -p "$project/docs"
lines "project added" >"$project/docs/added.md"
lines "project own file" >"$project/docs/gone.md"
commit_all "$project" "Create the project"
if run_sync "$project" --from "$owned_one"; then fail "a project file at a path the template adds was not reported as a conflict"; fi
if grep -Fq "docs/gone.md" "$project.out"; then fail "a file the template never owned for the project was reported as removed from the template"; fi
grep -Fq "docs/added.md" "$project.out" || fail "the conflict at a path the template adds was not reported"
grep -Fq "project added" "$project/docs/added.md" || fail "a project file at a path the template adds was lost"
grep -Fq "<<<<<<<" "$project/docs/added.md" || fail "a project file at a path the template adds was not marked as a conflict"
# A project copy that equals the previous, unowned template version is its own
# file as well: it is kept and reported, not replaced.
grep -Fqx "echo helper" "$project/docs/helper.sh" || fail "a project file equal to the unowned base version was replaced"
grep -Fq "docs/helper.sh: newly owned by the template, but the project has its own version" "$project.out" ||
  fail "a kept project file equal to the unowned base version was not reported"

# A base version whose list matches no file is an empty ownership set, not
# missing information: a file the target newly lists is still newly owned.
empty="$tmp/empty-template"
mkdir -p "$empty/scripts" "$empty/.agents"
git -C "$empty" init -q -b main
lines "repository: $empty" "" "paths: nothing-here" >"$empty/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$empty/scripts/sync-template.sh"
lines "tool one" >"$empty/scripts/tool.sh"
lines "kept as it is" >"$empty/scripts/keep.sh"
lines "removed while unowned" >"$empty/scripts/gone.sh"
commit_all "$empty" "Empty one"
empty_one="$(git -C "$empty" rev-parse HEAD)"
lines "repository: $empty" "" "paths: nothing-here scripts" >"$empty/.agents/template.conf"
lines "tool two" >"$empty/scripts/tool.sh"
git -C "$empty" rm -q scripts/gone.sh
commit_all "$empty" "Empty two"
for case_name in lacks has; do
  project="$tmp/empty-$case_name"
  mkdir -p "$project"
  git -C "$empty" archive "$empty_one" | tar -x -C "$project"
  git -C "$project" init -q -b main
  if [[ "$case_name" == "lacks" ]]; then
    rm "$project/scripts/tool.sh" "$project/scripts/keep.sh"
  else
    lines "project tool" >"$project/scripts/tool.sh"
    lines "project keep" >"$project/scripts/keep.sh"
  fi
  commit_all "$project" "Create the project"
  run_sync "$project" --from "$empty_one" --template "$empty" || {
    cat "$project.out" >&2
    fail "a sync with an empty base ownership set failed"
  }
  # Both the diff and the files the diff leaves out treat the empty set alike.
  if grep -Fq "scripts/gone.sh" "$project.out"; then fail "a file the empty base list did not own was reported as removed from the template"; fi
  if [[ "$case_name" == "lacks" ]]; then
    grep -Fqx "tool two" "$project/scripts/tool.sh" || fail "a newly listed, changed file was not added with an empty base ownership set"
    grep -Fqx "kept as it is" "$project/scripts/keep.sh" || fail "a newly listed, unchanged file was not added with an empty base ownership set"
  else
    for name in tool keep; do
      grep -Fqx "project $name" "$project/scripts/$name.sh" || fail "a project file was merged or replaced with an empty base ownership set"
      grep -Fq "scripts/$name.sh: newly owned by the template, but the project has its own version" "$project.out" ||
        fail "a kept project file was not reported with an empty base ownership set"
    done
  fi
done

# A base version that predates the 'paths:' list: the project's own list is
# the base ownership, so a file the target newly lists is newly owned, in the
# diff and outside it, while a file the project's list owns is synced as
# always. A project file with other content is kept and reported.
unlisted="$tmp/unlisted-template"
mkdir -p "$unlisted/scripts" "$unlisted/docs" "$unlisted/.agents"
git -C "$unlisted" init -q -b main
lines "repository: $unlisted" >"$unlisted/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$unlisted/scripts/sync-template.sh"
lines "tool one" >"$unlisted/scripts/tool.sh"
lines "guide" >"$unlisted/docs/guide.md"
lines "helper one" >"$unlisted/docs/helper.md"
lines "removed while unowned" >"$unlisted/docs/gone.md"
commit_all "$unlisted" "Unlisted one"
unlisted_one="$(git -C "$unlisted" rev-parse HEAD)"
lines "repository: $unlisted" "" "paths: scripts docs .agents/template.conf" >"$unlisted/.agents/template.conf"
lines "tool two" >"$unlisted/scripts/tool.sh"
lines "helper two" >"$unlisted/docs/helper.md"
git -C "$unlisted" rm -q docs/gone.md
commit_all "$unlisted" "Unlisted two: lists the files"
for case_name in lacks has; do
  project="$tmp/unlisted-$case_name"
  mkdir -p "$project"
  git -C "$unlisted" archive "$unlisted_one" | tar -x -C "$project"
  git -C "$project" init -q -b main
  lines "repository: $unlisted" "" "paths: scripts" >"$project/.agents/template.conf"
  if [[ "$case_name" == "lacks" ]]; then
    rm "$project/docs/guide.md" "$project/docs/helper.md"
  else
    lines "project guide" >"$project/docs/guide.md"
    lines "project helper" >"$project/docs/helper.md"
  fi
  commit_all "$project" "Create the project"
  run_sync "$project" --from "$unlisted_one" || {
    cat "$project.out" >&2
    fail "a sync from a base without 'paths:' failed"
  }
  grep -Fq "does not list its files under 'paths:'; using the list in .agents/template.conf" "$project.out" ||
    fail "the fallback to the project's list was not reported"
  grep -Fqx "tool two" "$project/scripts/tool.sh" || fail "a file the project's list owns was not replaced"
  if grep -Fq "docs/gone.md" "$project.out"; then fail "a file the project's list did not own was reported as removed from the template"; fi
  grep -Fq ".agents/template.conf: newly owned by the template, but the project has its own version" "$project.out" ||
    fail "the project's configuration was not kept as its own version"
  grep -Fqx "paths: scripts" "$project/.agents/template.conf" || fail "the project's list was replaced"
  if [[ "$case_name" == "lacks" ]]; then
    grep -Fqx "guide" "$project/docs/guide.md" || fail "a newly owned, unchanged file was not added from a base without 'paths:'"
    grep -Fqx "helper two" "$project/docs/helper.md" || fail "a newly owned, changed file was not added from a base without 'paths:'"
  else
    for name in guide helper; do
      grep -Fqx "project $name" "$project/docs/$name.md" || fail "a project file was merged or replaced from a base without 'paths:'"
      grep -Fq "docs/$name.md: newly owned by the template, but the project has its own version" "$project.out" ||
        fail "a kept project file was not reported from a base without 'paths:'"
    done
  fi
done

# The template-contract checks below read the template's own files that a
# project makes its own: its site, its scripts/verify.conf, its ci.yml, its
# example CI, and its list of workflow files. They run in the template only
# (template_repository in tests/lib-fakes.sh), where CI runs every self-test
# on every pull request; in a project those files are the project's.
in_template=0
if template_repository "$source_root"; then in_template=1; fi

# The paths this repository hands out, by the template's list without the
# exclusions an adopted project adds: the website of the template
# and the workflow that publishes it never reach a project, while the
# workflows of the template do.
template_conf "$tmp/template.conf"
if [[ "$in_template" -eq 1 ]]; then
  handed_out="$(
    cd "$source_root"
    read -r -a pathspecs <<<"$(sed -n 's/^paths: *//p' "$tmp/template.conf")"
    git ls-files --cached --others --exclude-standard -- "${pathspecs[@]}"
  )"
  if grep -Eq '^website/|^\.github/workflows/pages\.yml$' <<<"$handed_out"; then
    fail "the template paths hand out the website or its workflow"
  fi
  for workflow in ci.yml guardrails.yml; do
    grep -Fxq ".github/workflows/$workflow" <<<"$handed_out" || fail "the template paths do not hand out $workflow"
  done
fi

# A project has no website: it is not handed out, and a new project
# deletes it. The check of the site in the template's verification passes
# there.
site_marker="website/.codeyard-site"
site_check=""
if [[ "$in_template" -eq 1 ]]; then
  site_check="$(sed -n 's/^website: *//p' "$source_root/scripts/verify.conf")"
  [[ -n "$site_check" ]] || fail "the template has no website check in scripts/verify.conf"
  [[ -f "$source_root/$site_marker" ]] || fail "the template's website has no marker $site_marker"
fi
if [[ -n "$site_check" ]]; then
  mkdir -p "$tmp/no-site"
  (cd "$tmp/no-site" && bash -c "$site_check") >"$tmp/no-site.out" 2>&1 || {
    cat "$tmp/no-site.out" >&2
    fail "the website check fails in a repository without the website"
  }
fi

# A project may have a website/ of its own. The template's site is
# recognised by its marker, which the project's directory does not have: the
# check passes there without running the template's site checks, and the
# website steps of the CI are conditioned on the same marker.
if [[ -n "$site_check" ]]; then
  mkdir -p "$tmp/own-site/website" "$tmp/own-site-bin"
  echo 22 >"$tmp/own-site/website/.nvmrc"
  printf '{"name": "project-site", "private": true}\n' >"$tmp/own-site/website/package.json"
  # npm records that it ran: the template's site checks start with npm ci.
  printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$tmp/own-site-npm-ran" >"$tmp/own-site-bin/npm"
  chmod +x "$tmp/own-site-bin/npm"
  (cd "$tmp/own-site" && PATH="$tmp/own-site-bin:$PATH" bash -c "$site_check") >"$tmp/own-site.out" 2>&1 || {
    cat "$tmp/own-site.out" >&2
    fail "the website check fails in a repository with a website/ of its own"
  }
  [[ ! -e "$tmp/own-site-npm-ran" ]] ||
    fail "the website check runs the template's site checks on a project's own website/"
fi

# Evaluates the if: condition of a step of the CI as GitHub would in the
# checkout $1: hashFiles() is true when a file there matches, always() and
# success() are true. A condition with anything else cannot be evaluated and
# fails the test.
ci_condition_true() {
  local checkout="$1" expression="$2" pattern found equal
  expression="${expression#\$\{\{}"
  expression="${expression%\}\}}"
  while [[ "$expression" =~ hashFiles\(\'([^\']*)\'\) ]]; do
    pattern="${BASH_REMATCH[1]}"
    found="$(cd "$checkout" && shopt -s globstar nullglob dotglob &&
      for file in $pattern; do [[ -f "$file" ]] && echo 1 && break; done; true)"
    expression="${expression/"${BASH_REMATCH[0]}"/${found:-0}}"
  done
  expression="${expression//always()/1}"
  expression="${expression//success()/1}"
  expression="${expression//cancelled()/0}"
  while [[ "$expression" =~ \'([^\']*)\'[[:space:]]*(==|!=)[[:space:]]*\'([^\']*)\' ]]; do
    equal=0
    [[ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]] || equal=1
    [[ "${BASH_REMATCH[2]}" == "==" ]] || equal=$((1 - equal))
    expression="${expression/"${BASH_REMATCH[0]}"/$equal}"
  done
  expression="${expression//\'\'/0}"
  [[ "$expression" =~ ^[01[:space:]\&\|\!=\(\)]*$ ]] ||
    fail "cannot evaluate the ci.yml condition: $2"
  (($expression))
}

# Prints the if: condition of every step of ci.yml that names website/, one
# per line; a website step without an if: prints an empty line.
ci_website_conditions() {
  awk '
    function flush() { if (step && site) print cond; step = 0; site = 0; cond = "" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*steps:/ { flush(); insteps = 1; indent = ""; next }
    /^  [^[:space:]]/ { flush(); insteps = 0; next }
    insteps && match($0, /^[[:space:]]*- /) && (indent == "" || RLENGTH == indent) { indent = RLENGTH; flush(); step = 1 }
    step && /website/ { site = 1 }
    step && match($0, /^[[:space:]]*(- )?if:[[:space:]]*/) { cond = substr($0, RLENGTH + 1) }
    END { flush() }
  ' "$1"
}

ci_workflow="$source_root/.github/workflows/ci.yml"
if [[ "$in_template" -eq 1 ]]; then
  # The project's own website/ with reports of its own: only the marker may
  # keep the steps from running. With the marker added, they do run.
  mkdir -p "$tmp/ci-own-site/website/reports"
  echo 22 >"$tmp/ci-own-site/website/.nvmrc"
  printf '{"name": "project-site", "private": true}\n' >"$tmp/ci-own-site/website/package.json"
  printf '<p>report</p>\n' >"$tmp/ci-own-site/website/reports/index.html"
  cp -R "$tmp/ci-own-site" "$tmp/ci-template-site"
  touch "$tmp/ci-template-site/$site_marker"
  website_steps=0
  while IFS= read -r condition; do
    website_steps=$((website_steps + 1))
    [[ -n "$condition" ]] || fail "a website step of ci.yml has no if: and runs on a project's own website/"
    ! ci_condition_true "$tmp/ci-own-site" "$condition" ||
      fail "a website step of ci.yml runs without the site's marker: $condition"
    ci_condition_true "$tmp/ci-template-site" "$condition" ||
      fail "a website step of ci.yml does not run with the site's marker: $condition"
  done < <(ci_website_conditions "$ci_workflow")
  # A ci.yml that names website/ outside comments has website steps: none
  # found means the steps were not read.
  if grep -Eq '^[[:space:]]*[^#[:space:]].*website' "$ci_workflow" && [[ "$website_steps" -eq 0 ]]; then
    fail "ci.yml has no website steps to check"
  fi
fi

# Prints the script of the 'run: |' block of the first step of ci.yml that
# has a line containing $2, without its indentation. Comments do not count.
ci_step_script() {
  awk -v marker="$2" '
    function flush() { if (hit && !done) { printf "%s", body; done = 1 } hit = 0; body = ""; inrun = 0 }
    /^[[:space:]]*steps:/ { flush(); indent = ""; next }
    inrun {
      match($0, /^[[:space:]]*/)
      if ($0 ~ /^[[:space:]]*$/ || RLENGTH > runindent) { if (index($0, marker)) hit = 1; line = $0; sub(/^[[:space:]]+/, "", line); body = body line "\n"; next }
      inrun = 0
    }
    /^[[:space:]]*#/ { next }
    index($0, marker) { hit = 1 }
    match($0, /^[[:space:]]*- /) && (indent == "" || RLENGTH == indent) { flush(); indent = RLENGTH; hit = index($0, marker) > 0 }
    /^[[:space:]]*(- )?run: \|[[:space:]]*$/ { inrun = 1; match($0, /^[[:space:]]*(- )?/); runindent = RLENGTH; next }
    END { flush() }
  ' "$1"
}

# Prints the lines of the job $2 of ci.yml.
ci_job_block() {
  awk -v job="$2" '
    /^[^[:space:]#]/ { injob = 0 }
    /^  [^[:space:]#]/ { injob = ($0 ~ "^  " job ":") }
    injob { print }
  ' "$1"
}

# Prints the job-level if: of the job $2 of ci.yml.
ci_job_condition() {
  ci_job_block "$1" "$2" | awk '/^    if:/ { sub(/^    if:[[:space:]]*/, ""); print; exit }'
}

# Prints the jobs of ci.yml whose name starts with $2, one per line.
ci_jobs() {
  awk -v prefix="$2" '
    /^jobs:/ { injobs = 1; next }
    /^[^[:space:]#]/ { injobs = 0 }
    injobs && /^  [^[:space:]#]/ { job = $1; sub(/:.*/, "", job); if (index(job, prefix) == 1) print job }
  ' "$1"
}

# The workflow self-tests: a project runs them on a pull request only when a
# workflow file changed, and always on main and every night; the template
# runs them on every pull request and needs no nightly run (Issue 395).
# The template's ci.yml only: a project's own CI may run verify.sh in a
# layout of its own.
if [[ "$in_template" -eq 1 ]]; then
  scope_script="$(ci_step_script "$ci_workflow" 'id: scope')"
  [[ -n "$scope_script" ]] || fail "ci.yml has no step 'scope' that decides which checks run"
  mkdir -p "$tmp/ci-scope/template/.agents" "$tmp/ci-scope/project/.agents" "$tmp/ci-scope/bare"
  printf 'repository: https://github.com/Owner/Template.git\n\npaths: scripts\n' >"$tmp/ci-scope/template/.agents/template.conf"
  printf 'repository: https://github.com/owner/template\n\npaths: scripts\ncommit: 0123\n' >"$tmp/ci-scope/project/.agents/template.conf"
  # The predicate of the scope, which its sparse checkout brings.
  for checkout in template project bare; do
    mkdir -p "$tmp/ci-scope/$checkout/scripts/lib"
    cp "$source_root/scripts/lib/template-repository.sh" "$tmp/ci-scope/$checkout/scripts/lib/"
  done

  # ci_scope <checkout> <repository> <event>: the scope the step decides.
  ci_scope() {
    : >"$tmp/ci-scope/output"
    (cd "$tmp/ci-scope/$1" && EVENT="$3" REPOSITORY="https://github.com/$2" GITHUB_OUTPUT="$tmp/ci-scope/output" \
      bash -euo pipefail -c "$scope_script") >/dev/null || fail "the scope step of ci.yml failed in $1 on $3"
    sed -n 's/^verify=//p' "$tmp/ci-scope/output"
  }
  expect_scope() {
    local actual
    actual="$(ci_scope "$1" "$2" "$3")"
    [[ "$actual" == "$4" ]] || fail "ci.yml decides '$actual' for $1 on $3, expected '$4'"
  }
  expect_scope template owner/template pull_request all
  expect_scope template owner/template push all
  expect_scope template owner/template schedule none
  expect_scope project owner/project pull_request changed
  expect_scope project owner/project push all
  expect_scope project owner/project schedule all
  expect_scope bare owner/project pull_request changed

  # The group jobs (Issue 448): each runs verify.sh for the group it
  # declares; only 'changed' leaves out --all, also when the scope job gave
  # nothing. Each runs unless the scope is 'none', also when the scope job
  # failed and gave nothing, and checks out the full history: in a shallow
  # clone verify.sh cannot tell which files changed and runs every
  # self-test. A project's own CI without group jobs is not the template's.
  mkdir -p "$tmp/ci-verify/scripts"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "verify.sh $*" >"%s"\n' "$tmp/ci-verify/ran" >"$tmp/ci-verify/scripts/verify.sh"
  chmod +x "$tmp/ci-verify/scripts/verify.sh"
  group_jobs="$(ci_jobs "$ci_workflow" group-)"
  [[ -n "$group_jobs" ]] || fail "ci.yml has no group jobs"
  for job in $group_jobs; do
    ci_job_block "$ci_workflow" "$job" >"$tmp/ci-job.yml"
    group="$(sed -n 's/^      VERIFY_GROUP:[[:space:]]*//p' "$tmp/ci-job.yml")"
    [[ "$group" == "${job#group-}" ]] || fail "the job $job of ci.yml declares the group '$group'"
    verify_script="$(ci_step_script "$tmp/ci-job.yml" 'scripts/verify.sh')"
    [[ -n "$verify_script" ]] || fail "the job $job of ci.yml has no step that runs verify.sh"
    for case in "changed:verify.sh --only $group" "all:verify.sh --all --only $group" ":verify.sh --all --only $group"; do
      rm -f "$tmp/ci-verify/ran"
      (cd "$tmp/ci-verify" && SCOPE="${case%%:*}" VERIFY_GROUP="$group" bash -euo pipefail -c "$verify_script") ||
        fail "the verify step of $job failed with the scope '${case%%:*}'"
      [[ "$(cat "$tmp/ci-verify/ran" 2>/dev/null)" == "${case#*:}" ]] ||
        fail "the verify step of $job ran '$(cat "$tmp/ci-verify/ran" 2>/dev/null)' with the scope '${case%%:*}'"
    done
    verify_condition="$(ci_job_condition "$ci_workflow" "$job")"
    for scope in all changed ''; do
      ci_condition_true "$tmp/ci-verify" "${verify_condition//needs.scope.outputs.verify/\'$scope\'}" ||
        fail "the job $job of ci.yml does not run with the scope '$scope': $verify_condition"
    done
    ! ci_condition_true "$tmp/ci-verify" "${verify_condition//needs.scope.outputs.verify/\'none\'}" ||
      fail "the job $job of ci.yml runs with the scope 'none': $verify_condition"
    grep -Fq 'fetch-depth: 0' "$tmp/ci-job.yml" ||
      fail "the job $job of ci.yml checks out without the history verify.sh compares with"
  done
  grep -Eq '^[[:space:]]+schedule:' "$ci_workflow" || fail "ci.yml has no schedule for the nightly --all"

  # Only the job of the group of the website check sets up Node and the
  # browser and uploads the website reports.
  website_group="$(sed -nE 's/^website( \[([a-z0-9-]+)\])?:.*/\2/p' "$source_root/scripts/verify.conf")"
  website_group="${website_group:-default}"
  for job in $(ci_jobs "$ci_workflow" ""); do
    ci_job_block "$ci_workflow" "$job" | grep -v '^[[:space:]]*#' >"$tmp/ci-job.yml"
    if grep -Eq 'setup-node|playwright|upload-artifact|website/' "$tmp/ci-job.yml"; then
      [[ "$job" == "group-$website_group" ]] ||
        fail "the job $job of ci.yml sets up or reports the website, which is checked in group-$website_group"
    fi
  done
  grep -Fq 'playwright install' <<<"$(ci_job_block "$ci_workflow" "group-$website_group")" ||
    fail "the job group-$website_group of ci.yml does not install the browser for the website check"

  # The aggregate job 'verify' is the required check: it always runs, needs
  # the scope, the mapping, and every group job, and passes the needs to
  # check-ci-groups.sh --results, except on the template's nightly run, the
  # scope 'none' on a schedule. The scope 'none' on any other event goes to
  # --results, which fails on the skipped group jobs.
  [[ "$(ci_job_condition "$ci_workflow" verify)" == "always()" ]] ||
    fail "the job verify of ci.yml does not run with if: always(): $(ci_job_condition "$ci_workflow" verify)"
  aggregate_needs="$(ci_job_block "$ci_workflow" verify | sed -n 's/^    needs:[[:space:]]*//p')"
  for job in scope mapping $group_jobs; do
    [[ "$aggregate_needs" =~ [\[,[:space:]]$job[],] ]] || fail "the job verify of ci.yml does not need $job: $aggregate_needs"
  done
  ci_job_block "$ci_workflow" verify >"$tmp/ci-job.yml"
  aggregate_script="$(ci_step_script "$tmp/ci-job.yml" 'check-ci-groups.sh --results')"
  [[ -n "$aggregate_script" ]] || fail "the job verify of ci.yml does not run check-ci-groups.sh --results"
  grep -Fq 'NEEDS: ${{ toJSON(needs) }}' "$tmp/ci-job.yml" || fail "the job verify of ci.yml does not pass toJSON(needs)"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "check-ci-groups.sh $*" >"%s"\nexit "${CHECK_STATUS:-0}"\n' "$tmp/ci-verify/ran" >"$tmp/ci-verify/scripts/check-ci-groups.sh"
  chmod +x "$tmp/ci-verify/scripts/check-ci-groups.sh"
  # aggregate <scope> <event> <status of --results>: the exit status of the
  # step; 'ran' holds the call of check-ci-groups.sh.
  aggregate() {
    rm -f "$tmp/ci-verify/ran"
    (cd "$tmp/ci-verify" && SCOPE="$1" EVENT="$2" NEEDS='{"needs":1}' CHECK_STATUS="$3" \
      bash -euo pipefail -c "$aggregate_script") >/dev/null
  }
  aggregate none schedule 1 || fail "the aggregate of ci.yml fails on the template's nightly run"
  [[ ! -f "$tmp/ci-verify/ran" ]] || fail "the aggregate of ci.yml checks results on the template's nightly run"
  for case in "none pull_request" "none push" "all pull_request" "all push" "all schedule" "changed pull_request" " pull_request"; do
    read -r scope event <<<"$case"
    [[ -n "$event" ]] || { event="$scope"; scope=""; }
    aggregate "$scope" "$event" 0 || fail "the aggregate of ci.yml fails with the scope '$scope' on $event when the jobs succeeded"
    [[ "$(cat "$tmp/ci-verify/ran" 2>/dev/null)" == 'check-ci-groups.sh --results {"needs":1}' ]] ||
      fail "the aggregate of ci.yml does not check the results with the scope '$scope' on $event: $(cat "$tmp/ci-verify/ran" 2>/dev/null)"
    ! aggregate "$scope" "$event" 1 || fail "the aggregate of ci.yml passes with the scope '$scope' on $event when a job failed"
  done

  # The token is read-only whatever the repository's default (Issue 435):
  # the top level grants contents and packages read and nothing else, and no
  # job grants more.
  ci_permissions="$(awk '
    /^permissions:/ { p = 1; next }
    p && /^[^[:space:]#]/ { p = 0 }
    p && /^[[:space:]]+[^[:space:]#]/ { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]*#.*$/, "", line); print line }
  ' "$ci_workflow" | sort)"
  [[ "$ci_permissions" == $'contents: read\npackages: read' ]] ||
    fail "ci.yml does not declare exactly 'contents: read' and 'packages: read' at the top level: ${ci_permissions:-none}"
  ! grep -Eq '^[[:space:]]+permissions:' "$ci_workflow" || fail "a job of ci.yml declares permissions of its own"
fi

# A pull request in a project, checked out as actions/checkout does it: a new
# repository fetches the merge commit refs/pull/<n>/merge from the remote and
# checks it out detached; with fetch-depth: 0 it fetches every branch too,
# with the default depth only that one commit. verify.sh then runs as the
# scope 'changed' runs it, with the template's paths: of
# scripts/verify-workflow.conf and a stub for the self-tests. The workflow
# code is a workflow file: the template's two CI files, a script, a prompt,
# a schema, a policy, the example CI that a self-test reads, a self-test,
# and its library (Issue 395, criteria 7 and 9 to 12). The files a project
# makes its own are not (Issue 462): its agents, its template.conf, its
# .gitignore, and a workflow of its own, changed (deploy.yml) or added
# (release.yml). main moves on with a workflow change of its own, which must
# not count for the pull request.
pr_paths='scripts .agents/prompts .agents/schemas .agents/policies .github/workflows/ci.yml .github/workflows/guardrails.yml docs/examples/parallel-ci.yml :(glob)tests/*-test.sh tests/lib-fakes.sh tests/lib-run-feature.sh :(exclude)scripts/verify.conf'
# The line is the template's own, which a project may narrow: the template
# lists exactly these (template_repository in tests/lib-fakes.sh).
if [[ "$in_template" -eq 1 ]]; then
  [[ "$(sed -n 's/^paths:[[:space:]]*//p' "$source_root/scripts/verify-workflow.conf")" == "$pr_paths" ]] ||
    fail "the paths: of the template's scripts/verify-workflow.conf are not those this test checks: $(sed -n 's/^paths:[[:space:]]*//p' "$source_root/scripts/verify-workflow.conf")"
fi
pr_root="$tmp/ci-pr"
mkdir -p "$pr_root/work/scripts/lib" "$pr_root/work/.github/workflows" "$pr_root/work/.agents/policies" "$pr_root/work/.agents/prompts" \
  "$pr_root/work/.agents/schemas" "$pr_root/work/docs/examples" "$pr_root/work/src" "$pr_root/work/tests"
cp "$source_root/scripts/verify.sh" "$pr_root/work/scripts/"
cp "$source_root/scripts/lib/base.sh" "$pr_root/work/scripts/lib/"
printf 'project: true\n' >"$pr_root/work/scripts/verify.conf"
printf 'paths: %s\n\nself-test [self-tests]: echo ran >>"$SELF_TEST_LOG"\n' "$pr_paths" >"$pr_root/work/scripts/verify-workflow.conf"
printf 'name: ci\n' >"$pr_root/work/.github/workflows/ci.yml"
printf 'name: guardrails\n' >"$pr_root/work/.github/workflows/guardrails.yml"
printf 'name: deploy\n' >"$pr_root/work/.github/workflows/deploy.yml"
printf 'name: parallel\n' >"$pr_root/work/docs/examples/parallel-ci.yml"
printf 'default: medium\n' >"$pr_root/work/.agents/policies/risk.conf"
printf 'repository: https://github.com/owner/template\n\npaths: scripts\ncommit: 0123\n' >"$pr_root/work/.agents/template.conf"
printf 'one\n' >"$pr_root/work/src/app.txt"
printf 'one\n' >"$pr_root/work/scripts/tool.sh"
printf 'implementer: claude opus\n' >"$pr_root/work/.agents/agents.conf"
printf '.env\n' >"$pr_root/work/.gitignore"
printf '# Implementer\n' >"$pr_root/work/.agents/prompts/implementer.md"
printf '{}\n' >"$pr_root/work/.agents/schemas/review.schema.json"
printf '#!/usr/bin/env bash\n' >"$pr_root/work/tests/tool-test.sh"
printf '# fakes\n' >"$pr_root/work/tests/lib-fakes.sh"
git -C "$pr_root/work" init -q -b main
commit_all "$pr_root/work" "A project"
git init -q --bare "$pr_root/remote.git"
pr_number=0

# open_pr <file>: pushes a branch that changes <file> and its merge commit
# refs/pull/<n>/merge into main, after main moved on with a workflow change
# of its own, and prints <n>.
open_pr() {
  pr_number=$((pr_number + 1))
  git -C "$pr_root/work" checkout -q -b "pr-$pr_number" main
  printf 'change %s\n' "$pr_number" >>"$pr_root/work/$1"
  commit_all "$pr_root/work" "Change $1"
  git -C "$pr_root/work" checkout -q main
  printf 'main %s\n' "$pr_number" >>"$pr_root/work/.agents/policies/tools.md"
  commit_all "$pr_root/work" "Move main on"
  git -C "$pr_root/work" checkout -q --detach main
  git -C "$pr_root/work" -c user.name="Sync Test" -c user.email="sync-test@example.com" \
    merge -q --no-ff -m "Merge pr-$pr_number into main" "pr-$pr_number"
  git -C "$pr_root/work" push -q "file://$pr_root/remote.git" main "pr-$pr_number" "HEAD:refs/pull/$pr_number/merge"
  git -C "$pr_root/work" checkout -q main
}

# check_out_pr <n> <depth>: the checkout of actions/checkout for the pull
# request <n>, with fetch-depth: <depth>.
check_out_pr() {
  local checkout="$pr_root/checkout-$1-$2"
  local refspecs=("+refs/pull/$1/merge:refs/remotes/pull/$1/merge")
  local depth=()

  if [[ "$2" -eq 0 ]]; then
    refspecs=("+refs/heads/*:refs/remotes/origin/*" "${refspecs[@]}")
  else
    depth=("--depth=$2")
  fi
  git init -q "$checkout"
  git -C "$checkout" remote add origin "file://$pr_root/remote.git"
  git -C "$checkout" fetch -q --no-tags --prune --no-recurse-submodules "${depth[@]}" origin "${refspecs[@]}"
  git -C "$checkout" checkout -q --force "refs/remotes/pull/$1/merge"
  printf '%s\n' "$checkout"
}

# expect_pr <file> <depth> <ran|skipped> <note>: verify.sh in the checkout of
# a pull request that changes <file>.
expect_pr() {
  local number checkout
  open_pr "$1"
  number="$pr_number"
  checkout="$(check_out_pr "$number" "$2")"
  rm -f "$pr_root/ran"
  (cd "$checkout" && SELF_TEST_LOG="$pr_root/ran" ./scripts/verify.sh >"$pr_root/out.log" 2>&1) || {
    cat "$pr_root/out.log" >&2
    fail "verify.sh failed in the checkout of a pull request that changes $1"
  }
  case "$3" in
    ran) [[ -f "$pr_root/ran" ]] || fail "a pull request that changes $1 (fetch-depth: $2) skips the self-tests: $(cat "$pr_root/out.log")" ;;
    skipped) [[ ! -f "$pr_root/ran" ]] || fail "a pull request that changes $1 (fetch-depth: $2) runs the self-tests: $(cat "$pr_root/out.log")" ;;
  esac
  grep -Fq "$4" "$pr_root/out.log" || fail "verify.sh does not say '$4' for a pull request that changes $1 (fetch-depth: $2): $(cat "$pr_root/out.log")"
  # The group job of the self-tests decides the same, and passes when it
  # skips them (Issue 448).
  rm -f "$pr_root/ran"
  (cd "$checkout" && SELF_TEST_LOG="$pr_root/ran" ./scripts/verify.sh --only self-tests >"$pr_root/out.log" 2>&1) || {
    cat "$pr_root/out.log" >&2
    fail "verify.sh --only self-tests failed in the checkout of a pull request that changes $1"
  }
  case "$3" in
    ran) [[ -f "$pr_root/ran" ]] || fail "the group job skips the self-tests for a pull request that changes $1 (fetch-depth: $2): $(cat "$pr_root/out.log")" ;;
    skipped) [[ ! -f "$pr_root/ran" ]] || fail "the group job runs the self-tests for a pull request that changes $1 (fetch-depth: $2): $(cat "$pr_root/out.log")" ;;
  esac
}

for file in src/app.txt .agents/agents.conf .agents/template.conf .gitignore .github/workflows/deploy.yml .github/workflows/release.yml; do
  expect_pr "$file" 0 skipped "no workflow file differs from origin/main"
done
for file in .github/workflows/ci.yml .github/workflows/guardrails.yml .agents/policies/risk.conf docs/examples/parallel-ci.yml \
  scripts/tool.sh .agents/prompts/implementer.md .agents/schemas/review.schema.json tests/tool-test.sh tests/lib-fakes.sh; do
  expect_pr "$file" 0 ran "a workflow file differs from origin/main"
done
# In a shallow checkout verify.sh cannot tell, and runs them.
expect_pr src/app.txt 1 ran "could not determine whether a workflow file changed"

# The project's CI setup (Issue 412): ci.yml and the parallel CI of
# docs/examples call the composite action .github/actions/project-setup in
# every job that runs verify.sh, after the checkout and before the
# verification, and only when the project has the action. GitHub Actions
# cannot run here, so this checks the structure of both files and evaluates
# the condition with and without the action; the first CI run of a project
# with the action is the end-to-end evidence.

# Prints, for every job of the workflow $1 that runs verify.sh, one line
# with tabs: the job, the position of its checkout step, of its project
# setup step, and of its first step that runs verify.sh (0 when missing),
# and the if: of the setup step.
ci_setup_steps() {
  awk '
    function endstep() {
      if (s_checkout && !checkout) checkout = n
      if (s_setup && !setup) { setup = n; setupif = s_if }
      if (s_verify && !verify) verify = n
      s_checkout = 0; s_setup = 0; s_verify = 0; s_if = ""
    }
    function endjob() {
      endstep()
      if (job != "" && verify) print job "\t" checkout "\t" setup "\t" verify "\t" setupif
      job = ""; n = 0; checkout = 0; setup = 0; verify = 0; setupif = ""
    }
    /^[[:space:]]*#/ { next }
    /^jobs:/ { injobs = 1; next }
    /^[^[:space:]]/ { if (injobs) endjob(); injobs = 0; next }
    !injobs { next }
    /^  [^[:space:]]/ { endjob(); job = $1; sub(/:.*/, "", job); next }
    /^      - / { endstep(); n++ }
    n && /uses:[[:space:]]*actions\/checkout@/ { s_checkout = 1 }
    n && /uses:[[:space:]]*\.\/\.github\/actions\/project-setup[[:space:]]*$/ { s_setup = 1 }
    n && /scripts\/verify\.sh/ { s_verify = 1 }
    n && match($0, /^      (- |  )if:[[:space:]]*/) { s_if = substr($0, RLENGTH + 1) }
    END { if (injobs) endjob() }
  ' "$1"
}

mkdir -p "$tmp/ci-setup/with/.github/actions/project-setup" "$tmp/ci-setup/without/.github/actions/other"
printf 'name: setup\nruns:\n  using: composite\n  steps: []\n' >"$tmp/ci-setup/with/.github/actions/project-setup/action.yml"
printf 'name: other\n' >"$tmp/ci-setup/without/.github/actions/other/action.yml"
# The template's files only: a project's own CI is its own.
for workflow in .github/workflows/ci.yml docs/examples/parallel-ci.yml; do
  [[ "$in_template" -eq 1 ]] || continue
  setup_jobs=0
  while IFS=$'\t' read -r job checkout setup verify condition; do
    setup_jobs=$((setup_jobs + 1))
    [[ "$checkout" -gt 0 ]] || fail "the job $job of $workflow runs verify.sh without a checkout"
    [[ "$setup" -gt 0 ]] || fail "the job $job of $workflow does not set up the project with .github/actions/project-setup"
    [[ "$setup" -gt "$checkout" ]] || fail "the job $job of $workflow sets up the project before the checkout"
    [[ "$verify" -gt "$setup" ]] || fail "the job $job of $workflow sets up the project after the verification"
    [[ -n "$condition" ]] || fail "the project setup of the job $job of $workflow has no if: and fails in a project without the action"
    ci_condition_true "$tmp/ci-setup/with" "$condition" ||
      fail "the project setup of the job $job of $workflow does not run with the action: $condition"
    ! ci_condition_true "$tmp/ci-setup/without" "$condition" ||
      fail "the project setup of the job $job of $workflow runs without the action: $condition"
  done < <(ci_setup_steps "$source_root/$workflow")
  [[ "$setup_jobs" -gt 0 ]] || fail "no job of $workflow that runs verify.sh was found"
done

# A sync never takes over or changes .github/actions/ or the project's policy
# overrides in .agents/policy-overrides/: the template's list of files does
# not name them, so they stay the project's own without an exclusion in
# .agents/template.conf, also when the template has a file at that path and
# changes it. The template's risk.conf is still synced.
template_conf "$tmp/setup-template.conf"
setup_template="$tmp/setup-template"
mkdir -p "$setup_template/scripts" "$setup_template/.agents/policies" "$setup_template/.agents/policy-overrides" "$setup_template/.github/workflows" "$setup_template/.github/actions/project-setup"
sed "s#^repository:.*#repository: $setup_template#" "$tmp/setup-template.conf" >"$setup_template/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$setup_template/scripts/sync-template.sh"
lines "name: CI" >"$setup_template/.github/workflows/ci.yml"
lines "name: template setup" >"$setup_template/.github/actions/project-setup/action.yml"
lines "default: medium" >"$setup_template/.agents/policies/risk.conf"
lines "profile: standard" >"$setup_template/.agents/policy-overrides/risk.conf"
git -C "$setup_template" init -q -b main
commit_all "$setup_template" "Setup one"
setup_one="$(git -C "$setup_template" rev-parse HEAD)"
lines "name: CI" "# changed by the template" >"$setup_template/.github/workflows/ci.yml"
lines "name: template setup, changed" >"$setup_template/.github/actions/project-setup/action.yml"
lines "template only" >"$setup_template/.github/actions/project-setup/extra.txt"
lines "default: medium" "# changed by the template" >"$setup_template/.agents/policies/risk.conf"
lines "profile: standard" "default: high" >"$setup_template/.agents/policy-overrides/risk.conf"
lines "template only" >"$setup_template/.agents/policy-overrides/other.conf"
commit_all "$setup_template" "Setup two"
project="$tmp/setup-project"
mkdir -p "$project"
git -C "$setup_template" archive "$setup_one" | tar -x -C "$project"
lines "name: project setup" "runs:" "  using: composite" "  steps: []" >"$project/.github/actions/project-setup/action.yml"
lines "uv" >"$project/.github/actions/project-setup/requirements.txt"
lines "profile: light" >"$project/.agents/policy-overrides/risk.conf"
git -C "$project" init -q -b main
commit_all "$project" "Create the project with its own CI setup"
setup_before="$(cd "$project" && find .github/actions .agents/policy-overrides -type f | LC_ALL=C sort | xargs cksum)"
run_sync "$project" --from "$setup_one" || {
  cat "$project.out" >&2
  fail "a sync with the project's own CI setup failed"
}
grep -Fqx "# changed by the template" "$project/.github/workflows/ci.yml" || fail "the template's ci.yml was not synced"
grep -Fqx "# changed by the template" "$project/.agents/policies/risk.conf" || fail "the template's risk.conf was not synced"
[[ "$(cd "$project" && find .github/actions .agents/policy-overrides -type f | LC_ALL=C sort | xargs cksum)" == "$setup_before" ]] ||
  fail "a sync changed the project's .github/actions/ or .agents/policy-overrides/"
if grep -Fq -e ".github/actions" -e ".agents/policy-overrides" "$project.out"; then
  fail "a sync reported a file under .github/actions/ or .agents/policy-overrides/: $(cat "$project.out")"
fi
[[ -z "$(git -C "$project" status --porcelain -- .github/actions .agents/policy-overrides)" ]] ||
  fail "a sync left changes under .github/actions/ or .agents/policy-overrides/"
if grep -Fq "policy-overrides" "$project/.agents/template.conf"; then fail "the project needed an exclusion for its policy overrides"; fi

# A sync does not bring the template's 'parallel: <n>' of scripts/verify.conf
# into a project (Issue 450): the template chose it for its own checks on its
# own host, so a project runs its checks one at a time until it sets its own
# line, and keeps the line it set. The rest of the template's changes of the
# file are taken over as before.
template_conf "$tmp/parallel-template.conf"
parallel_template="$tmp/parallel-template"
mkdir -p "$parallel_template/scripts" "$parallel_template/.agents"
sed "s#^repository:.*#repository: $parallel_template#" "$tmp/parallel-template.conf" >"$parallel_template/.agents/template.conf"
cp "$source_root/scripts/sync-template.sh" "$parallel_template/scripts/sync-template.sh"
lines "# The checks." "" "lint: echo lint" >"$parallel_template/scripts/verify.conf"
git -C "$parallel_template" init -q -b main
commit_all "$parallel_template" "Checks one at a time"
parallel_one="$(git -C "$parallel_template" rev-parse HEAD)"
lines "# The checks, changed by the template." "" "parallel: 4" "lint: echo lint" >"$parallel_template/scripts/verify.conf"
commit_all "$parallel_template" "Four checks at a time"
parallel_two="$(git -C "$parallel_template" rev-parse HEAD)"
lines "# The checks, changed by the template." "" "parallel: 6" "lint: echo lint" >"$parallel_template/scripts/verify.conf"
commit_all "$parallel_template" "Six checks at a time"
# sync_parallel <label> <verify.conf of the project>...: a project of the
# first version with that scripts/verify.conf, synced to the last version.
sync_parallel() {
  local project="$tmp/parallel-$1"

  shift
  mkdir -p "$project"
  git -C "$parallel_template" archive "$parallel_one" | tar -x -C "$project"
  git -C "$project" init -q -b main
  commit_all "$project" "Create the project"
  if [[ $# -gt 0 ]]; then
    lines "$@" >"$project/scripts/verify.conf"
    commit_all "$project" "The project's checks"
  fi
  run_sync "$project" --from "$parallel_one" || { cat "$project.out" >&2; fail "the sync of $project failed"; }
  printf '%s\n' "$project"
}
project="$(sync_parallel unchanged)"
grep -Fqx "# The checks, changed by the template." "$project/scripts/verify.conf" || fail "the template's change of scripts/verify.conf was not taken over"
if grep -q '^parallel' "$project/scripts/verify.conf"; then fail "a sync brought the template's 'parallel:' into a project: $(cat "$project/scripts/verify.conf")"; fi
project="$(sync_parallel own-checks "# The checks." "" "lint: echo lint" "tests: echo tests")"
grep -Fqx "tests: echo tests" "$project/scripts/verify.conf" && grep -Fqx "# The checks, changed by the template." "$project/scripts/verify.conf" ||
  fail "the sync did not merge scripts/verify.conf of a project with checks of its own: $(cat "$project/scripts/verify.conf")"
if grep -q '^parallel' "$project/scripts/verify.conf"; then fail "a sync brought the template's 'parallel:' into a project with checks of its own: $(cat "$project/scripts/verify.conf")"; fi
project="$(sync_parallel own-value "# The checks." "" "parallel: 2" "lint: echo lint")"
[[ "$(grep '^parallel' "$project/scripts/verify.conf")" == "parallel: 2" ]] ||
  fail "a sync changed the project's own 'parallel:': $(cat "$project/scripts/verify.conf")"
if grep -Fq "CONFLICT" "$project.out"; then fail "the project's own 'parallel:' conflicted with the template's: $(cat "$project.out")"; fi

echo "sync-template tests passed"
