#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-skills-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "check-skills test failed: $*" >&2
  exit 1
}

# sha256: the hex digest of standard input, also where sha256sum is missing.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-64
  else
    shasum -a 256 | cut -c1-64
  fi
}

# skill_digest <skill-dir>: what 'sha256sum SKILL.md | sha256sum' gives there.
skill_digest() {
  printf '%s  SKILL.md\n' "$(sha256 <"$1/SKILL.md")" | sha256
}

# A repository with the check and a plan for Issue 7 without skills.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/scripts/lib" "$repo/.agents/plans"
  cp "$source_root/scripts/check-skills.sh" "$repo/scripts/check-skills.sh"
  cp "$source_root/scripts/lib/skills.sh" "$repo/scripts/lib/skills.sh"
  printf '# Plan 7\n\n## Steps\n\n- Write the page\n' >"$repo/.agents/plans/7-page.md"
  git -C "$repo" init -q -b main
  printf '%s\n' "$repo"
}

# add_skill <repo>: an adapted third-party skill 'plain-labels' with one
# guidance file and its license, and its digest recorded.
add_skill() {
  local dir="$1/.agents/project-skills/plain-labels"
  local digest

  mkdir -p "$dir"
  printf '# Plain labels\n\nName a button after its action: "Save changes", not "Submit".\n' >"$dir/SKILL.md"
  printf 'MIT License\n' >"$dir/LICENSE"
  digest="$(skill_digest "$dir")"
  {
    printf 'origin: third-party\n'
    printf 'source: https://github.com/example/skills\n'
    printf 'revision: %s\n' "0123456789abcdef0123456789abcdef01234567"
    printf 'license: MIT\n'
    printf 'license-file: LICENSE\n'
    printf 'content: adapted\n'
    printf 'changes: kept the section on labels only\n'
    printf 'files: SKILL.md\n'
    printf 'digest: sha256:%s\n' "$digest"
  } >"$dir/skill.conf"
}

# select_skill <repo> <version>: the plan of Issue 7 selects plain-labels.
select_skill() {
  printf '\n## Skills\n\n- `plain-labels` %s for the labels of the page\n\n## Tests\n\n- a test\n' "$2" >>"$1/.agents/plans/7-page.md"
}

# check <repo> [argument...]: runs the check; sets 'status', '<repo>.out'
# (standard output), and '<repo>.err'.
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && ./scripts/check-skills.sh "$@") >"$repo.out" 2>"$repo.err" || status=$?
}

# A project without skills: every form passes and prints no file to read.
repo="$(setup_repo none)"
check "$repo"
[[ "$status" -eq 0 ]] || fail "a project without skills did not pass ($status)"
grep -Fq "No project skills." "$repo.out" || fail "a project without skills was not reported as such"
check "$repo" --issue 7
[[ "$status" -eq 0 && ! -s "$repo.out" ]] || fail "a plan without skills selected files or failed ($status)"
check "$repo" --issue 8
[[ "$status" -eq 0 && ! -s "$repo.out" ]] || fail "an Issue without a plan selected files or failed ($status)"

# A valid skill that the plan selects at its digest: the file to read is
# printed, and the digest is the one that 'sha256sum SKILL.md | sha256sum'
# gives in the skill directory.
repo="$(setup_repo selected)"
add_skill "$repo"
digest="$(sed -n 's/^digest: //p' "$repo/.agents/project-skills/plain-labels/skill.conf")"
check "$repo"
[[ "$status" -eq 0 ]] || {
  cat "$repo.err" >&2
  fail "a valid skill was refused"
}
check "$repo" --digest plain-labels
[[ "$status" -eq 0 && "$(cat "$repo.out")" == "$digest" ]] || fail "--digest printed '$(cat "$repo.out")', not $digest"
select_skill "$repo" "$digest"
check "$repo" --issue 7
[[ "$status" -eq 0 ]] || {
  cat "$repo.err" >&2
  fail "a selection at the current digest did not resolve"
}
[[ "$(cat "$repo.out")" == ".agents/project-skills/plain-labels/SKILL.md" ]] ||
  fail "the selected files were '$(cat "$repo.out")'"

# The selected content changes: the plan's pin and the recorded digest no
# longer match, and both are reported with the digest the files have now.
printf 'Use "OK" everywhere.\n' >>"$repo/.agents/project-skills/plain-labels/SKILL.md"
now="$(skill_digest "$repo/.agents/project-skills/plain-labels")"
check "$repo"
[[ "$status" -eq 1 ]] || fail "a skill whose files differ from its digest passed"
grep -Fq "the files have sha256:$now, but skill.conf records $digest" "$repo.err" || fail "the stale digest was not reported: $(cat "$repo.err")"
sed -i.bak "s/^digest: .*/digest: sha256:$now/" "$repo/.agents/project-skills/plain-labels/skill.conf"
rm "$repo/.agents/project-skills/plain-labels/skill.conf.bak"
check "$repo" --issue 7
[[ "$status" -eq 1 && ! -s "$repo.out" ]] || fail "a selection of an older version resolved"
grep -Fq "selects the skill 'plain-labels' at $digest, but its files are at sha256:$now (https://github.com/example/skills at 0123456789abcdef0123456789abcdef01234567)" "$repo.err" ||
  fail "the mismatched version was not reported clearly: $(cat "$repo.err")"

# An unknown skill and an unreadable selection.
repo="$(setup_repo unknown)"
select_skill "$repo" "sha256:$(printf x | sha256)"
printf '\n## Skills\n\n- frontend-design latest\n' >>"$repo/.agents/plans/7-page.md"
check "$repo" --issue 7
[[ "$status" -eq 1 ]] || fail "an unknown skill resolved"
grep -Fq "selects the skill 'plain-labels', which is unknown" "$repo.err" || fail "the unknown skill was not reported: $(cat "$repo.err")"
grep -Fq "selects a skill as 'frontend-design latest'" "$repo.err" || fail "a selection without a digest was not reported: $(cat "$repo.err")"

# Metadata that does not identify the content: a third-party skill without
# its license, with a revision that can move, adapted without saying how, and
# with a key that is not known.
repo="$(setup_repo metadata)"
add_skill "$repo"
conf="$repo/.agents/project-skills/plain-labels/skill.conf"
sed -i.bak -e '/^license: /d' -e '/^changes: /d' -e 's/^revision: .*/revision: main/' "$conf"
printf 'install: npx skills add example/skills\n' >>"$conf"
check "$repo"
[[ "$status" -eq 1 ]] || fail "incomplete metadata passed"
for text in "a third-party skill needs 'license'" "revision must be a full commit hash" "adapted content needs 'changes'" "unknown line 'install: npx skills add example/skills'"; do
  grep -Fq "$text" "$repo.err" || fail "not reported: $text ($(cat "$repo.err"))"
done

# A project skill needs no source, revision, or license.
repo="$(setup_repo project)"
dir="$repo/.agents/project-skills/release-notes"
mkdir -p "$dir"
printf '# Release notes\n' >"$dir/SKILL.md"
printf 'origin: project\nfiles: SKILL.md\n' >"$dir/skill.conf"
check "$repo"
grep -Fq "needs 'digest: sha256:$(skill_digest "$dir")'" "$repo.err" || fail "a missing digest was not reported with its value"
check "$repo" --digest release-notes
printf 'origin: project\nfiles: SKILL.md\ndigest: %s\n' "$(cat "$repo.out")" >"$dir/skill.conf"
check "$repo"
[[ "$status" -eq 0 ]] || {
  cat "$repo.err" >&2
  fail "a project skill was refused"
}

# Nothing executable and nothing unlisted is kept, and a listed file cannot
# lie outside the skill.
repo="$(setup_repo executable)"
add_skill "$repo"
dir="$repo/.agents/project-skills/plain-labels"
mkdir -p "$dir/scripts"
printf '#!/bin/sh\necho installed\n' >"$dir/scripts/install.sh"
chmod +x "$dir/scripts/install.sh"
check "$repo"
[[ "$status" -eq 1 ]] || fail "a skill with a script passed"
grep -Fq "plain-labels/scripts/install.sh is not listed in files" "$repo.err" || fail "the unlisted script was not reported"
grep -Fq "plain-labels/scripts/install.sh is executable" "$repo.err" || fail "the executable script was not reported"
[[ ! -e "$repo/installed" ]] || fail "the check ran a file of the skill"
sed -i.bak 's/^files: .*/files: ..\/..\/plans\/7-page.md/' "$dir/skill.conf"
check "$repo"
grep -Fq "'../../plans/7-page.md' is not a file of the skill" "$repo.err" || fail "a file outside the skill was accepted"

# Refusals.
repo="$(setup_repo refusals)"
check "$repo" --issue
[[ "$status" -eq 2 ]] || fail "--issue without a number was accepted"
check "$repo" --everything
[[ "$status" -eq 2 ]] || fail "an unknown option was accepted"
check "$repo" --digest missing
[[ "$status" -eq 1 ]] || fail "--digest of an unknown skill succeeded"

echo "check-skills tests passed"
