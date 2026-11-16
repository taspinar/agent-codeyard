#!/usr/bin/env bash

set -euo pipefail

# The approval requests and plans that a project inherits from the template
# (scripts/lib/inherited.sh): which files count as inherited in a project made
# with "Use this template", that doctor.sh warns about them without changing
# anything and says nothing in the template, and that the removal needs no
# approval of the owner and leaves the references of the documents intact.
# start-planning.sh's removal is tested in tests/start-planning-test.sh.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/inherited-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "inherited test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
source "$source_root/scripts/lib/inherited.sh"

template_url="https://example.com/owner/template"

commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=Owner -c user.email=owner@example.com commit -qm "$2"
}

# The template's files as "Use this template" copies them: every tracked
# file, in one first commit. Its approval requests and plans are fixtures,
# not those of the repository these tests run in: 2.json collides with the
# project's Issue #2, 7.json is one the project changes later, and the plan of
# a template Issue.
snapshot="$tmp/snapshot"
mkdir -p "$snapshot"
(cd "$source_root" && git ls-files -co --exclude-standard -z -- . ':(exclude).agents/approval-requests' \
  ':(exclude).agents/plans' ':(exclude).agents/verification-baseline' ':(exclude).agents/template.conf' |
  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] && printf '%s\0' "$path"
  done |
  tar --null -T - -cf -) | tar -C "$snapshot" -xf -
mkdir -p "$snapshot/.agents/approval-requests" "$snapshot/.agents/plans"
: >"$snapshot/.agents/plans/.gitkeep"
for issue in 2 7; do
  jq -n --argjson issue "$issue" '{schema: "approval-request/v1", issue: $issue}' \
    >"$snapshot/.agents/approval-requests/$issue.json"
done
printf '# Plan of the template Issue 313\n' >"$snapshot/.agents/plans/313-growth-lessons.md"
template_conf "$tmp/template.conf"
sed -E "/^repository:/ s#:.*#: $template_url#" "$tmp/template.conf" >"$snapshot/.agents/template.conf"

# make_project <name>: a project from the snapshot, with its own origin.
make_project() {
  local project="$tmp/$1"

  cp -R "$snapshot" "$project"
  git -C "$project" init -q -b main
  commit "$project" "Initial commit"
  git init -q --bare -b main "$tmp/$1-remote.git"
  git -C "$project" remote add origin "$tmp/$1-remote.git"
  git -C "$project" push -q origin main
  printf '%s\n' "$project"
}

expected_inherited=$'.agents/approval-requests/2.json\n.agents/approval-requests/7.json\n.agents/plans/313-growth-lessons.md'

# A new project: everything the first commit added is inherited, .gitkeep is
# not.
project="$(make_project project)"
[[ "$(inherited_files "$project")" == "$expected_inherited" ]] ||
  fail "a new project does not list exactly the template's requests and plans: $(inherited_files "$project")"

# The project's own request, added later, is kept, and so is an inherited
# one that a later commit changed: finish-feature.sh rewrote it for the
# project's own Issue.
own="$(make_project own)"
jq -n '{schema: "approval-request/v1", issue: 9}' >"$own/.agents/approval-requests/9.json"
printf '# Plan of the project Issue 9\n' >"$own/.agents/plans/9-own.md"
jq -n '{schema: "approval-request/v1", issue: 7, project: true}' >"$own/.agents/approval-requests/7.json"
commit "$own" "Feature 9 and 7"
[[ "$(inherited_files "$own")" == $'.agents/approval-requests/2.json\n.agents/plans/313-growth-lessons.md' ]] ||
  fail "a project's own requests and plans are listed as inherited: $(inherited_files "$own")"

# An inherited file that a later commit changed and another restored to its
# first content is the project's own too, although the root commit and HEAD
# do not differ; the untouched ones are still inherited.
restored="$(make_project restored)"
original="$(cat "$restored/.agents/approval-requests/7.json")"
jq -n '{schema: "approval-request/v1", issue: 7, project: true}' >"$restored/.agents/approval-requests/7.json"
commit "$restored" "Feature 7"
printf '%s\n' "$original" >"$restored/.agents/approval-requests/7.json"
commit "$restored" "Restore 7"
git -C "$restored" diff --quiet "$(git -C "$restored" rev-list --max-parents=0 HEAD)" HEAD -- .agents ||
  fail "the restored request differs from the root commit"
[[ "$(inherited_files "$restored")" == $'.agents/approval-requests/2.json\n.agents/plans/313-growth-lessons.md' ]] ||
  fail "a changed and restored request is listed as inherited: $(inherited_files "$restored")"

# Once removed, nothing is left.
removed="$(make_project removed)"
git -C "$removed" rm -q -- $expected_inherited
commit "$removed" "Plan project bootstrap"
[[ -z "$(inherited_files "$removed")" ]] || fail "removed files are still listed: $(inherited_files "$removed")"

# The template itself: its origin is the 'repository:' of template.conf, also
# with '.git', a trailing '/', or another case. Nothing is listed even though
# this first commit holds requests.
for url in "$template_url" "$template_url.git" "$template_url/" "https://Example.com/owner/Template.git"; do
  git -C "$project" remote set-url origin "$url"
  [[ -z "$(inherited_files "$project")" ]] || fail "the template with origin $url lists inherited files"
done
git -C "$project" remote set-url origin "$tmp/project-remote.git"

# Without an origin a repository is not known to be a project, and a shallow
# clone's oldest commit is not its root: inherited_shallow tells it, and
# start-planning.sh deepens it (tests/start-planning-test.sh).
git -C "$project" remote remove origin
[[ -z "$(inherited_files "$project")" ]] || fail "a repository without origin lists inherited files"
git -C "$project" remote add origin "$tmp/project-remote.git"
git clone -q --depth 1 "file://$own" "$tmp/shallow"
[[ -z "$(inherited_files "$tmp/shallow")" ]] || fail "a shallow clone lists inherited files"
inherited_shallow "$tmp/shallow" || fail "a shallow clone of a project is not told"
! inherited_shallow "$own" || fail "a full clone is told as shallow"

# doctor.sh warns once, with the count and the command, and changes nothing.
# gh is not logged in and no role uses Codex, so it stays local.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
printf 'implementer: claude model-a\nreviewer: claude model-b\n' >"$tmp/agents.conf"
run_doctor() {
  (cd "$1" && PATH="$tmp/bin:$PATH" AGENT_CONFIG_FILE="$tmp/agents.conf" \
    ATTRIBUTION_CONFIG_FILE="$tmp/attribution.conf" ./scripts/doctor.sh) >"$1.doctor" 2>&1 || true
}
status_before="$(git -C "$project" status --porcelain --untracked-files=all)"
run_doctor "$project"
[[ "$(grep -c "^WARNING  3 approval request(s) and plan(s) of the template's own Issues remain in this project" "$project.doctor")" -eq 1 ]] || {
  cat "$project.doctor" >&2
  fail "doctor.sh does not warn once about the 3 inherited files"
}
grep -Fq "Run ./scripts/start-planning.sh: it removes them in the planning pull request." "$project.doctor" ||
  fail "doctor.sh does not name the command that removes them"
[[ "$(git -C "$project" status --porcelain --untracked-files=all)" == "$status_before" ]] ||
  fail "doctor.sh changed the project"
[[ "$(inherited_files "$project")" == "$expected_inherited" ]] || fail "doctor.sh removed inherited files"

# In a shallow clone it cannot tell, and says so.
run_doctor "$tmp/shallow"
grep -Fq "WARNING  this shallow clone does not hold the project's first commit" "$tmp/shallow.doctor" || {
  cat "$tmp/shallow.doctor" >&2
  fail "doctor.sh does not warn that a shallow clone cannot be checked"
}
grep -Fq "Run: git fetch --unshallow origin." "$tmp/shallow.doctor" || fail "doctor.sh does not name the command that deepens the clone"
[[ "$(git -C "$tmp/shallow" rev-parse --is-shallow-repository)" == "true" ]] || fail "doctor.sh deepened the shallow clone"

# The template, which names its own origin, here a local one so that
# doctor.sh needs no network.
template="$(make_project template)"
sed -E "/^repository:/ s#:.*#: $tmp/template-remote.git/#" "$snapshot/.agents/template.conf" >"$template/.agents/template.conf"
commit "$template" "Name the template"
[[ -z "$(inherited_files "$template")" ]] || fail "the template lists inherited files"
for repo in "$removed" "$template"; do
  run_doctor "$repo"
  grep -Fq "remote 'origin' is configured" "$repo.doctor" || {
    cat "$repo.doctor" >&2
    fail "doctor.sh did not reach the check of the origin in $repo"
  }
  ! grep -Fq "of the template's own Issues" "$repo.doctor" || fail "doctor.sh warns in $repo, which has no inherited files"
  ! grep -Fq "shallow clone" "$repo.doctor" || fail "doctor.sh calls $repo a shallow clone"
done

# The removal, as the planning pull request carries it, needs no approval of
# the owner: the gate finds nothing protected and refuses no request.
guarded="$(make_project guarded)"
git -C "$guarded" switch -q -c planning/project-bootstrap
git -C "$guarded" rm -q -- $(inherited_files "$guarded")
commit "$guarded" "Plan project bootstrap"
status=0
(cd "$guarded" && ./scripts/check-guardrails.sh --commits main HEAD --fail-on-protected) >"$guarded.out" 2>&1 || status=$?
[[ "$status" -eq 0 && "$(sed -n 1p "$guarded.out")" == "level: none" ]] || {
  cat "$guarded.out" >&2
  fail "removing the inherited requests needs the owner's approval (status $status)"
}
! grep -q '^refused:' "$guarded.out" || fail "the gate refused a removed request"
status=0
(cd "$guarded" && ./scripts/check-guardrails.sh main --fail-on-protected) >"$guarded.out" 2>&1 || status=$?
[[ "$status" -eq 0 && "$(sed -n 1p "$guarded.out")" == "level: none" ]] || {
  cat "$guarded.out" >&2
  fail "removing the inherited requests needs the owner's approval in the worktree (status $status)"
}

# No document names an inherited file: removing them adds no problem to the
# check of the references. The project's documents are the ones of the
# repository these tests run in, which in an adopted project may name a
# template file it excluded: the check ends in the project, before and after
# the removal, as it ends in that repository, which in the template is a
# pass, and its problems stay the same. The command is the template's line
# of scripts/verify.conf, which a project may change.
docs_references() {
  local status=0

  (cd "$1" && ./scripts/check-docs.sh --later docs/PROJECT_DESCRIPTION.md docs/PLANNING_APPROVAL.md docs/changes \
    scripts/worktree-setup.sh .github/workflows/pages.yml) >"$2" 2>&1 || status=$?
  grep -v ' problem(s)\.' "$2" >"$2.problems" || true
  printf '%s\n' "$status"
}
source_status="$(docs_references "$source_root" "$tmp/source.docs")"
for repo in "$project" "$guarded"; do
  status="$(docs_references "$repo" "$repo.docs")"
  [[ "$status" == "$source_status" ]] || {
    cat "$repo.docs" >&2
    fail "the check of the references ends with $status in $repo, with $source_status in the repository of the tests"
  }
done
inherited_in_project "$source_root" || [[ "$source_status" -eq 0 ]] || {
  cat "$tmp/source.docs" >&2
  fail "the check of the references fails in the template"
}
diff "$project.docs.problems" "$guarded.docs.problems" >&2 || fail "removing the inherited files breaks a reference of the documents"
grep -q 'names .agents/\(approval-requests\|plans\)/' "$project.docs.problems" && fail "a document names an inherited file"

echo "inherited tests passed"
