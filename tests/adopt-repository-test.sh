#!/usr/bin/env bash

set -euo pipefail

# The adoption of an existing repository from the proposal of its
# assessment: additive, on its own branch, with the project's history,
# application, CI, and deployment unchanged; stopped by uncommitted work and
# unresolved collisions; safe to repeat; and followed by a working
# sync-template.sh.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adopt-repository-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "adopt-repository test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=Test -c user.email=test@example.com commit -qm "$2"
}

# The template checkout the assessment and the adoption run from, from the
# files the template carries into an adopted project too; its product files
# and CI, which an adoption leaves behind, are written here.
template="$tmp/template"
mkdir -p "$template/docs" "$template/.github/workflows" "$template/src"
copy_workflow "$template"
workflow_gitignore "$template/.gitignore"
cp "$source_root/AGENTS.md" "$template/"
printf '# The template\n' >"$template/README.md"
cp "$source_root/.agents/agents.conf" "$source_root/.agents/attribution.conf" "$template/.agents/"
template_conf "$template/.agents/template.conf"
cp "$source_root/docs/architecture.md" "$source_root/docs/workflow.md" "$source_root/docs/evaluation.md" "$source_root/docs/example.md" "$template/docs/"
printf 'name: ci of the template\non: [push]\njobs: {}\n' >"$template/.github/workflows/ci.yml"
printf 'name: guardrails\non: [pull_request]\njobs: {}\n' >"$template/.github/workflows/guardrails.yml"
cp "$source_root/.github/PULL_REQUEST_TEMPLATE.md" "$template/.github/"
: >"$template/src/.gitkeep"
# The starter files of a new project, a decision record of the template's
# own, and a directory its template.conf excludes: an adoption carries none
# of the last two, and un-ignores neither.
mkdir -p "$template/tests/unit" "$template/docs/decisions" "$template/docs/internal"
: >"$template/tests/unit/.gitkeep"
printf 'APP_URL=http://localhost:3000\n' >"$template/.env.example"
printf '# 0001. A decision of the template\n' >"$template/docs/decisions/0001-template-choice.md"
printf '{}\n' >"$template/docs/internal/notes.json"
sed -i 's|^paths: .*|& :(exclude)docs/internal|' "$template/.agents/template.conf"
git -C "$template" init -q -b main
commit_all "$template" "Template"
template_commit="$(git -C "$template" rev-parse HEAD)"

# make_target <name>: a small project with application code, its own CI and
# deployment, and its own AGENTS.md, .gitignore, architecture, and pull
# request template, which collide with the template's.
make_target() {
  local repo="$tmp/$1"

  mkdir -p "$repo/src" "$repo/docs" "$repo/scripts" "$repo/.github/workflows"
  printf '{"name": "fixture", "scripts": {"test": "node test.js"}}\n' >"$repo/package.json"
  printf 'console.log("fixture");\n' >"$repo/src/app.js"
  printf '#!/bin/sh\necho build\n' >"$repo/scripts/build.sh"
  printf 'FROM scratch\n' >"$repo/Dockerfile"
  printf 'name: build\non: [push]\njobs: {}\n' >"$repo/.github/workflows/build.yml"
  printf 'name: ci\non: [push]\njobs: {}\n' >"$repo/.github/workflows/ci.yml"
  printf '# Our agents\n\nBe careful.\n' >"$repo/AGENTS.md"
  printf 'node_modules/\n' >"$repo/.gitignore"
  printf '# Our architecture\n' >"$repo/docs/architecture.md"
  printf '# Our pull requests\n\nDescribe the change.\n' >"$repo/.github/PULL_REQUEST_TEMPLATE.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name Owner
  git -C "$repo" config user.email owner@example.com
  commit_all "$repo" "Fixture"
  printf 'v2\n' >>"$repo/src/app.js"
  commit_all "$repo" "Second commit"
  printf '%s\n' "$repo"
}

# result <facts> [<jq>]: a valid assessor result: every collision kept as the
# project's, the pull request template merged; changed by <jq>.
result() {
  jq -c '{summary: "A small Node service.",
    facts: [{statement: "The repository is a Git repository.", evidence: ["git"]}],
    assumptions: [{statement: "The service runs as one Node process.", basis: "src/app.js is its only source file."}],
    questions: [{question: "Is the Dockerfile deployed?", why: "Whether a change can reach production."}],
    risks: [{risk: "A push may deploy the container.", basis: "The repository has a Dockerfile."}],
    collisions: [.adoption.collisions[] | {path, resolution: (if .path == ".github/PULL_REQUEST_TEMPLATE.md" then "merge" else "keep-project" end),
      rationale: "The project'"'"'s own file."}],
    profile: {name: "standard", rationale: "It has deployment configuration."},
    verification: [.commands[] | select(.command == "npm run test") | {name: "tests", source: .id, rationale: "package.json declares it."}],
    execution_needed: [{what: "npm ci", why: "The tests need the dependencies.", side_effects: "Writes node_modules/."}]}
    | '"${2:-.}" "$1"
}

# assess <repo> [<jq>]: the assessment of <repo>, with the result changed by <jq>.
assess() {
  local repo="$1"

  (cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/assess-repository.sh "$repo" --facts-only) >"$repo.assess" 2>&1 ||
    { cat "$repo.assess" >&2; fail "the facts of $repo failed"; }
  facts="$template/$(sed -n 's#^Assessment facts: \(.*\)$#\1#p' "$repo.assess" | tail -n 1)"
  (cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.agent" MOCK_OUTPUT="$(result "$facts" "${2:-.}")" \
    ./scripts/assess-repository.sh "$repo") >"$repo.assess" 2>&1 || { cat "$repo.assess" >&2; fail "the assessment of $repo failed"; }
}

adopt() {
  local repo="$1"
  shift
  (cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/adopt-repository.sh "$repo" "$@") >"$repo.out" 2>&1
}

# state <repo>: the refs, the checked-out branch, and the status.
state() {
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
  git -C "$1" symbolic-ref -q HEAD || true
  git -C "$1" status --porcelain=v1 --untracked-files=all
}

# project_files <repo>: the content of the files of the project: application,
# dependencies, CI, deployment, and the files it keeps unchanged.
project_files() {
  (cd "$1" && cksum package.json src/app.js scripts/build.sh Dockerfile .github/workflows/build.yml .github/workflows/ci.yml \
    docs/architecture.md .github/PULL_REQUEST_TEMPLATE.md)
}

# ------------------------------------------------------- an additive adoption
repo="$(make_target project)"
assess "$repo"
main_before="$(git -C "$repo" rev-parse main)"
history_before="$(git -C "$repo" rev-list main)"
files_before="$(project_files "$repo")"
agents_before="$(cat "$repo/AGENTS.md")"
gitignore_before="$(cat "$repo/.gitignore")"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption failed"; }
[[ "$(git -C "$repo" branch --show-current)" == "adopt/agent-codeyard" ]] || fail "the adoption is not on its branch"
[[ "$(git -C "$repo" rev-parse main)" == "$main_before" && "$(git -C "$repo" rev-list main)" == "$history_before" ]] ||
  fail "the history of main changed"
[[ "$(git -C "$repo" rev-parse adopt/agent-codeyard~1)" == "$main_before" ]] || fail "the adoption is not one commit on top of the assessed commit"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || fail "the adoption left uncommitted files: $(git -C "$repo" status --porcelain)"
[[ "$(project_files "$repo")" == "$files_before" ]] || fail "a file of the project changed: $(diff <(project_files "$repo") <(printf '%s\n' "$files_before"))"
# The commit only adds, except the sections appended to AGENTS.md and .gitignore.
changes="$(git -C "$repo" diff --no-renames --name-status main adopt/agent-codeyard | grep -v '^A' || true)"
[[ "$changes" == $'M\t.gitignore\nM\tAGENTS.md' ]] || fail "the adoption changed more than it added: $changes"
[[ "$(head -c "${#agents_before}" "$repo/AGENTS.md")" == "$agents_before" &&
  "$(head -c "${#gitignore_before}" "$repo/.gitignore")" == "$gitignore_before" ]] || fail "the project's AGENTS.md or .gitignore was not kept"
[[ "$(grep -c 'agent-codeyard: begin' "$repo/AGENTS.md")" -eq 1 ]] && grep -q '^## Agent workflow (agent-codeyard)$' "$repo/AGENTS.md" &&
  grep -q '^### Definition of Done$' "$repo/AGENTS.md" || fail "the workflow's section of AGENTS.md is missing"
grep -Fxq '.agents/handoffs/*' "$repo/.gitignore" && ! grep -Fxq '.env' "$repo/.gitignore" ||
  fail "the .gitignore section is not the workflow's: $(cat "$repo/.gitignore")"
[[ -x "$repo/scripts/verify.sh" && -f "$repo/.agents/prompts/implementer.md" && -f "$repo/docs/workflow.md" ]] ||
  fail "the workflow files were not added"
cmp -s "$repo/.github/PULL_REQUEST_TEMPLATE.agent-codeyard.md" "$template/.github/PULL_REQUEST_TEMPLATE.md" ||
  fail "the template's pull request template is not placed beside the project's"
[[ ! -e "$repo/.github/workflows/guardrails.yml" && ! -e "$repo/.github/workflows/ci.agent-codeyard.yml" ]] || fail "a CI workflow was added"
[[ ! -e "$repo/README.md" && ! -e "$repo/src/.gitkeep" ]] || fail "a product file of the template was carried over"
[[ ! -e "$repo/docs/decisions/0001-template-choice.md" && ! -e "$repo/docs/internal" ]] ||
  fail "a decision record of the template, or a path its template.conf excludes, was carried over"
[[ -f "$repo/tests/unit/.gitkeep" && -f "$repo/.env.example" ]] || fail "the starter files of an application at the top were not added"
conf="$repo/.agents/template.conf"
grep -Fxq "commit: $template_commit" "$conf" && grep -Fxq "$(grep '^repository:' "$template/.agents/template.conf")" "$conf" ||
  fail "the template version is not recorded: $(grep -v '^#' "$conf")"
paths="$(sed -n 's/^paths: //p' "$conf")"
for spec in scripts ':(exclude)AGENTS.md' ':(exclude).gitignore' ':(exclude).github/workflows/ci.yml'; do
  [[ " $paths " == *" $spec "* ]] || fail "the ownership lacks $spec: $paths"
done
[[ " $paths " != *":(exclude).github/PULL_REQUEST_TEMPLATE.md"* ]] || fail "a merged file was excluded from the template's ownership"
grep -q "Adopt the agent-codeyard workflow" <(git -C "$repo" log -1 --format=%B) || fail "the commit message is wrong"

# The project's own commands become the checks of the verification, in a
# file of the project's that a sync leaves alone; the CI stays as it is.
# isolated: no credential of the environment, no database, no telemetry.
# A check stops while a credential file, tracked by Git or not, is in its
# directory: a tool loads it past the cleared environment.
isolation="unset \$(compgen -e | grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL' || true); export DATABASE_URL=postgresql://isolated:isolated@127.0.0.1:1/isolated DO_NOT_TRACK=1; "
guard='for f in .env .env.* .dev.vars; do [[ ! -e $f && ! -L $f || " .env.example .env.sample .env.template .env.dist .env.defaults " == *" $f "* ]] || { echo "$f: a credential file in the directory of this check, which a tool may load, whether Git tracks it or not. The check stops until the owner has set up the shielding: move the file out for the run, or run the verification in a working copy without it." >&2; exit 1; }; done && '
grep -Fxq "tests: ${isolation}${guard}npm run test" "$repo/scripts/verify.conf" || fail "the project's command is not an isolated check: $(cat "$repo/scripts/verify.conf")"
[[ " $paths " == *" :(exclude)scripts/verify.conf "* ]] || fail "the checks of the project are owned by the template: $paths"
grep -Fq "./scripts/verify.sh --baseline" "$repo.out" || fail "the adoption does not say how to record the baseline: $(cat "$repo.out")"
# The planning documents the project lacks are a minimal baseline, marked as
# observed and not approved; the project's own architecture is reused as it
# is; and no ADR is written.
for document in docs/PROJECT_REQUIREMENTS.md docs/roadmap.md; do
  grep -q '^> \*\*Observed, not approved\.\*\* .*planning approval of this repository' "$repo/$document" ||
    fail "$document does not carry the mark: $(cat "$repo/$document")"
done
grep -Fxq "Status: Draft" "$repo/docs/PROJECT_REQUIREMENTS.md" && grep -Fxq "Approved at: Not approved" "$repo/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the reconstructed requirements are presented as approved"
grep -Fq "Is the Dockerfile deployed?" "$repo/docs/PROJECT_REQUIREMENTS.md" && grep -Fq "It needs: npm ci" "$repo/docs/roadmap.md" ||
  fail "the baseline does not carry the questions and the execution the assessment found"
[[ "$(cat "$repo/docs/architecture.md")" == "# Our architecture" ]] || fail "the project's architecture was not reused as it is"
[[ -z "$(git -C "$repo" diff --name-only main adopt/agent-codeyard -- docs/decisions | grep -v '^docs/decisions/README.md$' || true)" ]] ||
  fail "the adoption wrote an ADR"

# Run again: nothing changes, also from another branch, which stays checked out.
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption failed"; }
grep -Fq "is adopted already" "$repo.out" || fail "a repeated adoption did not say that nothing changed: $(cat "$repo.out")"
[[ "$(state "$repo")" == "$state_before" ]] || fail "a repeated adoption changed the repository"
git -C "$repo" switch -q main
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption from main failed"; }
grep -Fq "is adopted already" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "a repeated adoption from main changed the repository: $(cat "$repo.out")"
git -C "$repo" switch -q adopt/agent-codeyard

# Newer project changes after the adoption are kept: a changed file and a
# removed one.
printf 'Our note.\n' >>"$repo/docs/workflow.md"
git -C "$repo" rm -q docs/example.md
commit_all "$repo" "Own changes"
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption after project changes failed"; }
grep -Fq "is adopted already" "$repo.out" && grep -Fq "docs/workflow.md" "$repo.out" && grep -Fq "docs/example.md" "$repo.out" ||
  fail "the kept project changes are not reported: $(cat "$repo.out")"
[[ "$(state "$repo")" == "$state_before" && ! -e "$repo/docs/example.md" ]] && grep -q 'Our note' "$repo/docs/workflow.md" ||
  fail "a newer project change was overwritten"

# Once merged into main, a repeated adoption changes nothing either.
git -C "$repo" switch -q main
git -C "$repo" merge -q --ff-only adopt/agent-codeyard
git -C "$repo" branch -q -D adopt/agent-codeyard
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption of a merged adoption failed"; }
grep -Fq "is adopted already" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "a merged adoption was changed: $(cat "$repo.out")"

# A project without an architecture document and without a command to verify
# it with: the architecture is reconstructed, marked, from the assessment, and
# the verification fails until the project has a check.
repo="$(make_target bare)"
git -C "$repo" rm -q docs/architecture.md
commit_all "$repo" "No architecture"
assess "$repo" '.verification = []'
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption of a project without checks failed"; }
architecture="$repo/docs/architecture.md"
grep -q '^> \*\*Observed, not approved\.\*\*' "$architecture" && grep -Fq -- "- A push may deploy the container." "$architecture" &&
  grep -Fq -- "- The service runs as one Node process." "$architecture" && grep -Fq "the adoption reconstructs no ADR" "$architecture" ||
  fail "the reconstructed architecture is incomplete: $(cat "$architecture")"
grep -q '^no-project-check: ' "$repo/scripts/verify.conf" || fail "a project without a command got no failing check: $(cat "$repo/scripts/verify.conf")"
if (cd "$repo" && PATH="/usr/bin:/bin" ./scripts/verify.sh) >"$repo.verify" 2>&1; then fail "a project without a check passed the verification"; fi
grep -Fq "nothing of the project is verified" "$repo.verify" || fail "the verification does not say that nothing is verified: $(cat "$repo.verify")"

# A project whose architecture and requirements the assessment judged not
# sufficient: the marked baseline is written at their paths, above the
# project's text, which stays unchanged; the change only adds lines.
repo="$(make_target stub)"
printf '# Requirements\n\nTBD\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
commit_all "$repo" "Requirements stub"
assess "$repo" '.collisions |= map(if .path == "docs/architecture.md" or .path == "docs/PROJECT_REQUIREMENTS.md"
  then .resolution = "reconstruct" | .rationale = "Only a heading, no content." else . end)'
proposal="$(ls -td "$template"/.agents/assessments/stub-*/ | head -n 1)proposal.json"
# A planning document the owner is to judge, or merged as a template file,
# stops the run before any change.
state_before="$(state "$repo")"
for resolution in ask-owner merge; do
  jq --arg resolution "$resolution" '.collisions |= map(if .path == "docs/architecture.md" then .resolution = $resolution else . end)' \
    "$proposal" >"$tmp/stub-$resolution.json"
  if adopt "$repo" --proposal "$tmp/stub-$resolution.json"; then fail "a planning document resolved as $resolution was applied"; fi
  grep -q '^  - docs/architecture.md: .*keep-project.*reconstruct' "$repo.out" ||
    fail "a planning document resolved as $resolution is not reported: $(cat "$repo.out")"
  [[ "$(state "$repo")" == "$state_before" ]] || fail "a refused adoption of a planning document changed the repository"
done
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption of insufficient planning documents failed"; }
for document in docs/architecture.md docs/PROJECT_REQUIREMENTS.md; do
  original="$(git -C "$repo" show "main:$document")"
  grep -q '^> \*\*Observed, not approved\.\*\* .*planning approval of this repository' "$repo/$document" &&
    grep -Fxq "## The project's document, as it was" "$repo/$document" && grep -Fq "Only a heading, no content." "$repo/$document" ||
    fail "$document is not the marked baseline: $(cat "$repo/$document")"
  [[ "$(tail -n "$(printf '%s\n' "$original" | wc -l)" "$repo/$document")" == "$original" ]] ||
    fail "the project's text of $document was not kept: $(cat "$repo/$document")"
  [[ "$(git -C "$repo" diff --numstat main adopt/agent-codeyard -- "$document" | cut -f2)" == 0 ]] ||
    fail "the reconstruction of $document removed lines of the project"
done
grep -Fxq "Status: Draft" "$repo/docs/PROJECT_REQUIREMENTS.md" || fail "the reconstructed requirements are presented as approved"
grep -Fq -- "- The service runs as one Node process." "$repo/docs/architecture.md" || fail "the reconstructed architecture lacks the assessment"
! grep -Fq '`docs/architecture.md` (architecture)' "$repo/docs/architecture.md" ||
  fail "the reconstructed architecture names itself as a document to reuse"
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption of reconstructed documents failed"; }
grep -Fq "is adopted already" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "a repeated adoption changed the reconstructed documents: $(cat "$repo.out")"

# ------------------------------------ ignore rules that hide the workflow's files
# The project ignores *.json with an exception of its own, and a .gitignore
# further down hides a document. The section un-ignores the paths of the
# workflow that the project's .gitignore hides, and only those; the rule
# further down cannot be undone from there, and the adoption names it.
repo="$(make_target ignoring)"
printf 'node_modules/\n*.json\n!package.json\n/docs/decisions/0*\n' >"$repo/.gitignore"
printf 'example.md\n' >"$repo/docs/.gitignore"
commit_all "$repo" "Ignore rules"
assess "$repo"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption of an ignoring project failed"; }
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || fail "the adoption left uncommitted files: $(git -C "$repo" status --porcelain)"
[[ "$(sed -n '/^# The files of the workflow that a rule above would hide/,$p' "$repo/.gitignore" | grep -v '^#')" == \
  $'!/.agents/approval-requests/*.json\n!/.agents/schemas/*.json' ]] || fail "the section does not un-ignore the hidden paths: $(cat "$repo/.gitignore")"
# The rules hide the template's decision record and docs/internal/notes.json
# too, which the adoption does not carry: neither is un-ignored nor named
# (#303).
! grep -Eq 'docs/(internal|decisions/0001)' "$repo/.gitignore" "$repo.out" ||
  fail "a path the adoption does not carry was un-ignored or named: $(cat "$repo/.gitignore" "$repo.out")"
for path in .agents/approval-requests/12.json .agents/schemas/review.schema.json .agents/schemas/new.schema.json package.json; do
  if git -C "$repo" check-ignore -q --no-index "$path"; then fail "$path is still ignored: $(cat "$repo/.gitignore")"; fi
done
git -C "$repo" check-ignore -q --no-index other.json && git -C "$repo" check-ignore -q --no-index docs/example.md ||
  fail "the adoption un-ignored a path of the project, or one it cannot change"
grep -Fxq "  docs/example.md (example.md in docs/.gitignore:1)" "$repo.out" || fail "the path that stays hidden is not named: $(cat "$repo.out")"
mkdir -p "$repo/.agents/approval-requests"
printf '{}\n' >"$repo/.agents/approval-requests/12.json"
[[ "$(git -C "$repo" status --porcelain --untracked-files=all)" == "?? .agents/approval-requests/12.json" ]] ||
  fail "a later approval request is not seen by Git: $(git -C "$repo" status --porcelain --untracked-files=all)"
rm -r "$repo/.agents/approval-requests"

# A repeated run started from the project's branch reads the ignore rules of
# the adoption's branch: no warning about the paths its section un-ignores,
# and still one when that branch no longer un-ignores them.
git -C "$repo" switch -q main
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption from main failed"; }
grep -Fq "is adopted already" "$repo.out" && [[ "$(git -C "$repo" symbolic-ref HEAD)" == refs/heads/main ]] ||
  fail "a repeated adoption from main did not leave main checked out: $(cat "$repo.out")"
! grep -Eq '^  \.agents/(schemas|approval-requests)/' "$repo.out" ||
  fail "a repeated adoption from main warns about paths its branch un-ignores: $(cat "$repo.out")"
grep -Fxq "  docs/example.md (example.md in docs/.gitignore:1)" "$repo.out" ||
  fail "a repeated adoption from main does not name the path that stays hidden: $(cat "$repo.out")"
git -C "$repo" switch -q adopt/agent-codeyard
sed -i '/^!\/\.agents\//d' "$repo/.gitignore"
commit_all "$repo" "Drop the exceptions"
git -C "$repo" switch -q main
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption from main without the exceptions failed"; }
grep -Eq '^  \.agents/schemas/.* \(\*\.json in \.gitignore:2\)$' "$repo.out" &&
  grep -Eq '^  \.agents/approval-requests/.* \(\*\.json in \.gitignore:2\)$' "$repo.out" ||
  fail "a repeated adoption from main does not warn about the paths its branch hides: $(cat "$repo.out")"

# -------------------------------------------- a name that differs only in case
# The project's docs/ARCHITECTURE.md is renamed to docs/architecture.md with
# its history: no second file.
repo="$(make_target cased)"
git -C "$repo" mv docs/architecture.md docs/ARCHITECTURE.md
commit_all "$repo" "Upper-case architecture"
assess "$repo"
proposal="$(ls -td "$template"/.agents/assessments/cased-*/ | head -n 1)proposal.json"
jq -e '.collisions | any(.path == "docs/architecture.md" and .kind == "case-only" and .project_path == "docs/ARCHITECTURE.md" and .resolution == "keep-project")' \
  "$proposal" >/dev/null || fail "the proposal does not resolve the name that differs only in case: $(jq -c .collisions "$proposal")"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption with a name that differs only in case failed"; }
[[ "$(git -C "$repo" ls-files docs | grep -ci '^docs/architecture\.md$')" -eq 1 && -n "$(git -C "$repo" ls-files -- docs/architecture.md)" ]] ||
  fail "the project's document was not renamed, or a second one was written: $(git -C "$repo" ls-files docs)"
[[ "$(cat "$repo/docs/architecture.md")" == "# Our architecture" ]] || fail "the renamed document lost its content: $(cat "$repo/docs/architecture.md")"
git -C "$repo" diff -M --name-status main adopt/agent-codeyard -- docs | grep -Fxq $'R100\tdocs/ARCHITECTURE.md\tdocs/architecture.md' ||
  fail "the adoption is no rename: $(git -C "$repo" diff -M --name-status main adopt/agent-codeyard -- docs)"
[[ "$(git -C "$repo" log --follow --format=%s adopt/agent-codeyard -- docs/architecture.md | tail -n 1)" == "Fixture" ]] ||
  fail "the history of the document was not kept: $(git -C "$repo" log --follow --format=%s adopt/agent-codeyard -- docs/architecture.md)"
grep -Fq "docs/ARCHITECTURE.md -> docs/architecture.md" "$repo.out" || fail "the rename is not reported: $(cat "$repo.out")"
state_before="$(state "$repo")"
adopt "$repo" || { cat "$repo.out" >&2; fail "a repeated adoption after the rename failed"; }
grep -Fq "is adopted already" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "a repeated adoption after the rename changed the repository: $(cat "$repo.out")"

# ------------------------------------------------------- a partial adoption
# A run that stopped before its commit left some of the files, one of them
# changed since.
repo="$(make_target partial)"
assess "$repo"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption of the partial fixture failed"; }
git -C "$repo" reset -q HEAD~1
git -C "$repo" checkout -q -- AGENTS.md .gitignore
rm -rf "$repo/scripts/lib" "$repo/docs/evaluation.md" "$repo/.agents/template.conf"
printf 'Changed meanwhile.\n' >>"$repo/docs/workflow.md"
adopt "$repo" || { cat "$repo.out" >&2; fail "the completion of a partial adoption failed"; }
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || fail "the partial adoption was not completed: $(git -C "$repo" status --porcelain)"
[[ "$(git -C "$repo" rev-list --count main..adopt/agent-codeyard)" -eq 1 ]] || fail "the completion did not make one commit"
[[ -f "$repo/scripts/lib/agent.sh" && -f "$repo/docs/evaluation.md" && -f "$repo/.agents/template.conf" ]] || fail "a missing file was not added"
grep -q 'Changed meanwhile' "$repo/docs/workflow.md" || fail "a changed file of the partial adoption was overwritten"
[[ "$(grep -c 'agent-codeyard: begin' "$repo/AGENTS.md")" -eq 1 && "$(grep -c 'agent-codeyard: the working files' "$repo/.gitignore")" -eq 1 ]] ||
  fail "a section was duplicated or not added"
[[ "$(git -C "$repo" diff --no-renames --name-status main adopt/agent-codeyard | grep -vc '^A')" -eq 2 ]] || fail "the completion changed more than it added"

# ---------------------------------- uncommitted work and unresolved collisions
repo="$(make_target dirty)"
printf 'local edit\n' >>"$repo/src/app.js"
printf 'notes\n' >"$repo/notes.txt"
assess "$repo" '.collisions |= map(if .path == "AGENTS.md" then .resolution = "ask-owner" else . end)'
state_before="$(state "$repo")"
files_before="$(project_files "$repo")"
if adopt "$repo"; then fail "an adoption with uncommitted work and an unresolved collision succeeded"; fi
for path in src/app.js notes.txt AGENTS.md; do
  grep -q "^  - $path: " "$repo.out" || fail "the refusal does not name $path: $(cat "$repo.out")"
done
grep -Fq "stops before any change" "$repo.out" || fail "the refusal does not say that nothing changed"
[[ "$(state "$repo")" == "$state_before" && "$(project_files "$repo")" == "$files_before" ]] || fail "a refused adoption changed the repository"

# A collision without a resolution, in a proposal given by path.
proposal="$(ls -td "$template"/.agents/assessments/dirty-*/ | head -n 1)proposal.json"
jq '.collisions |= map(if .path == "AGENTS.md" then del(.resolution) else . end)' "$proposal" >"$tmp/unresolved.json"
if adopt "$repo" --proposal "$tmp/unresolved.json"; then fail "a collision without a resolution was applied"; fi
grep -Fq "AGENTS.md: the proposal does not resolve this collision" "$repo.out" || fail "a collision without a resolution is not reported: $(cat "$repo.out")"
[[ "$(state "$repo")" == "$state_before" ]] || fail "a refused adoption changed the repository"

# After the work is committed, the proposal no longer matches.
commit_all "$repo" "Local work"
state_before="$(state "$repo")"
if adopt "$repo"; then fail "a proposal of an older commit was applied"; fi
grep -Fq "changed since the assessment" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "a changed HEAD was not refused: $(cat "$repo.out")"

# A file that appeared since the assessment, ignored by Git, stops it too.
repo="$(make_target appeared)"
assess "$repo"
printf 'docs/workflow.md\n' >>"$repo/.git/info/exclude"
printf 'ours\n' >"$repo/docs/workflow.md"
state_before="$(state "$repo")"
if adopt "$repo"; then fail "an adoption over a file that appeared since the assessment succeeded"; fi
grep -Fq "docs/workflow.md: changed since the assessment" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] &&
  grep -qx 'ours' "$repo/docs/workflow.md" || fail "a file that appeared was not reported or was changed: $(cat "$repo.out")"

# A proposal path that leaves the repository, or that the template does not
# have, stops the run before any change, inside the repository or outside it.
repo="$(make_target traversal)"
assess "$repo"
proposal="$(ls -td "$template"/.agents/assessments/traversal-*/ | head -n 1)proposal.json"
state_before="$(state "$repo")"
files_before="$(project_files "$repo")"
: >"$tmp/edited.json"
: >"$repo.out"
outside_before="$(cd "$tmp" && find . -path ./traversal -prune -o -print | LC_ALL=C sort)"
for edit in '.additions += [{path: "../../outside.txt", ownership: "template"}]' \
  '.additions[0].path = "docs/../../outside.md"' \
  '.additions[0].path = "/tmp/outside.md"' \
  '.additions[0].path = "./docs/workflow.md"' \
  '.collisions[0].path = "../escaped.md"' \
  '.additions += [{path: "docs/not-in-template.md", ownership: "template"}]'; do
  jq "$edit" "$proposal" >"$tmp/edited.json"
  if adopt "$repo" --proposal "$tmp/edited.json"; then fail "a proposal with an invalid path was applied: $edit"; fi
  grep -Fq "stops before any change" "$repo.out" || fail "an invalid path was not refused ($edit): $(cat "$repo.out")"
  [[ "$(state "$repo")" == "$state_before" && "$(project_files "$repo")" == "$files_before" ]] ||
    fail "a refused proposal with an invalid path changed the repository: $edit"
  [[ "$(cd "$tmp" && find . -path ./traversal -prune -o -print | LC_ALL=C sort)" == "$outside_before" ]] ||
    fail "a refused proposal with an invalid path wrote outside the repository: $edit"
  [[ ! -e "$(dirname "$tmp")/outside.txt" ]] || fail "a refused proposal with an invalid path wrote outside the repository: $edit"
done

# ------------------------------------------------- a later sync-template.sh
repo="$(make_target synced)"
assess "$repo"
adopt "$repo" || { cat "$repo.out" >&2; fail "the adoption before the sync failed"; }
printf '\nA new template rule.\n' >>"$template/docs/evaluation.md"
printf '\nA new template section.\n' >>"$template/.github/PULL_REQUEST_TEMPLATE.md"
printf '\nA new template instruction.\n' >>"$template/AGENTS.md"
printf '# A new template check.\n' >>"$template/.github/workflows/guardrails.yml"
printf '# A new template check.\n' >>"$template/.github/workflows/ci.yml"
printf 'name: release\non: [push]\njobs: {}\n' >"$template/.github/workflows/release.yml"
sed -i 's|^paths: |paths: .github/workflows/release.yml |' "$template/.agents/template.conf"
commit_all "$template" "Template update"
agents_before="$(cat "$repo/AGENTS.md")"
workflows_before="$(cd "$repo" && find .github/workflows -type f | LC_ALL=C sort | xargs cksum)"
if (cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/sync-template.sh --template "$template") >"$repo.sync" 2>&1; then
  fail "the sync reported no conflict: $(cat "$repo.sync")"
fi
grep -A3 '^Replaced' "$repo.sync" | grep -Fq 'docs/evaluation.md' && cmp -s "$repo/docs/evaluation.md" "$template/docs/evaluation.md" ||
  fail "the sync did not update a file of the workflow: $(cat "$repo.sync")"
grep -A3 '^CONFLICTS' "$repo.sync" | grep -Fq '.github/PULL_REQUEST_TEMPLATE.md' ||
  fail "the sync did not report the conflict of the project's file: $(cat "$repo.sync")"
[[ "$(cat "$repo/AGENTS.md")" == "$agents_before" ]] || fail "the sync changed the project's AGENTS.md"
# The project's CI stays its own: a template workflow the adoption left out is
# not added by a sync either.
[[ "$(cd "$repo" && find .github/workflows -type f | LC_ALL=C sort | xargs cksum)" == "$workflows_before" ]] ||
  fail "the sync changed the project's CI workflows: $(cat "$repo.sync")"
git -C "$repo" checkout -q -- .
git -C "$template" reset -q --hard "$template_commit"

# ------------------------------------------------------------- publishing
repo="$(make_target published)"
git init -q --bare "$tmp/origin.git"
git -C "$repo" remote add origin "$tmp/origin.git"
git -C "$repo" push -q origin main
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"$MOCK_GH_LOG"
previous=""
for argument in "$@"; do
  [[ "$previous" != --body-file ]] || cp "$argument" "$MOCK_GH_LOG.body"
  previous="$argument"
done
case "$1 $2" in
  "repo view") echo main ;;
  "pr list") [[ ! -e "$MOCK_GH_LOG.created" ]] || echo "https://github.com/example/fixture/pull/1" ;;
  "pr create") : >"$MOCK_GH_LOG.created"; echo "https://github.com/example/fixture/pull/1" ;;
esac
GH
chmod +x "$tmp/bin/gh"
export MOCK_GH_LOG="$tmp/gh.log"
assess "$repo"
adopt "$repo" --publish || { cat "$repo.out" >&2; fail "the published adoption failed"; }
[[ "$(git -C "$tmp/origin.git" rev-parse main)" == "$(git -C "$repo" rev-parse main)" ]] || fail "the default branch of origin changed"
[[ "$(git -C "$tmp/origin.git" rev-parse adopt/agent-codeyard)" == "$(git -C "$repo" rev-parse adopt/agent-codeyard)" ]] || fail "the branch was not pushed"
grep -q '^pr create --base main --head adopt/agent-codeyard' "$MOCK_GH_LOG" || fail "no pull request was opened: $(cat "$MOCK_GH_LOG")"
adopt "$repo" --publish || { cat "$repo.out" >&2; fail "the repeated published adoption failed"; }
[[ "$(grep -c '^pr create' "$MOCK_GH_LOG")" -eq 1 ]] && grep -Fq "(open already)" "$repo.out" || fail "a second pull request was opened"

# ------------------- the integration branch, an application in a subdirectory
# A Next.js application in nextjs/, whose work happens on develop, where a
# push deploys; main is checked out. The adoption stops until develop is
# assessed; then it records develop as the base, runs the project's checks in
# nextjs/, isolated, adds no starter file beside the application, and its
# pull request goes into develop and says that the merge deploys. A
# fictional key in nextjs/.env, ignored by Git or tracked, never reaches the
# check.
repo="$(make_target integration)"
git -C "$repo" rm -q package.json
mkdir -p "$repo/nextjs/tests"
printf '{"name": "web", "scripts": {"build": "next build", "test": "vitest run"}, "dependencies": {"next": "15.0.0"}}\n' >"$repo/nextjs/package.json"
printf 'test("page", () => {});\n' >"$repo/nextjs/tests/page.test.js"
printf 'DATABASE_URL=\n' >"$repo/nextjs/.env.example"
printf '.env\n' >"$repo/nextjs/.gitignore"
printf 'name: deploy\non:\n  push:\n    branches: [develop]\njobs:\n  ship:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npx vercel deploy --prod\n' \
  >"$repo/.github/workflows/deploy.yml"
commit_all "$repo" "Next.js in a subdirectory"
git -C "$repo" checkout -q -b develop
for number in 1 2; do
  git -C "$repo" checkout -q -b "feature/$number" develop
  printf 'feature %s\n' "$number" >"$repo/nextjs/feature-$number.txt"
  commit_all "$repo" "Feature $number"
  git -C "$repo" checkout -q develop
  git -C "$repo" merge -q --no-ff -m "Merge pull request #$number from owner/feature-$number" "feature/$number"
done
git -C "$repo" checkout -q main
git init -q --bare "$tmp/integration-origin.git"
git -C "$repo" remote add origin "$tmp/integration-origin.git"
git -C "$repo" push -q origin main develop
assess "$repo"
state_before="$(state "$repo")"
if adopt "$repo"; then fail "an adoption of main, while features merge into develop, succeeded"; fi
grep -Fq "the assessment measured main, but features merge into develop" "$repo.out" && [[ "$(state "$repo")" == "$state_before" ]] ||
  fail "the adoption of the wrong branch was not stopped before any change: $(cat "$repo.out")"
git -C "$repo" checkout -q develop
assess "$repo"
export MOCK_GH_LOG="$tmp/gh-integration.log"
adopt "$repo" --publish || { cat "$repo.out" >&2; fail "the adoption of develop failed"; }
[[ "$(git -C "$repo" rev-parse adopt/agent-codeyard~1)" == "$(git -C "$repo" rev-parse develop)" ]] || fail "the adoption does not start from develop"
grep -Fxq "base: develop" "$repo/.agents/template.conf" || fail "the base is not recorded: $(grep -v '^#' "$repo/.agents/template.conf")"
next_isolation="${isolation%; }"
grep -Fxq "tests: ${next_isolation} NEXT_TELEMETRY_DISABLED=1; cd nextjs && ${guard}npm run test" "$repo/scripts/verify.conf" ||
  fail "the check does not run isolated in the application's directory: $(cat "$repo/scripts/verify.conf")"
# The check as verify.sh runs it, with an npm that loads nextjs/.env as
# dotenv and Next.js do: while the file is there, the check stops and names
# it, and the key is not available; in a clean working copy of the same
# commit it runs, with its tracked .env.example, and finds no key.
fictional_key="sk_test_fictional_0000_adopt"
printf 'PAYMENTS_API_KEY=%s\n' "$fictional_key" >"$repo/nextjs/.env"
mkdir -p "$tmp/npm-bin"
printf '#!/bin/sh\n[ ! -f .env ] || { set -a; . ./.env; set +a; }\necho "npm ran; the key: ${PAYMENTS_API_KEY:-absent}"\n' >"$tmp/npm-bin/npm"
chmod +x "$tmp/npm-bin/npm"
check="$(sed -n 's/^tests: //p' "$repo/scripts/verify.conf")"
if (cd "$repo" && PATH="$tmp/npm-bin:$PATH" PAYMENTS_API_KEY="$fictional_key" bash -eo pipefail -c "$check") >"$tmp/check.out" 2>&1; then
  fail "the check ran with a credential file in its directory: $(cat "$tmp/check.out")"
fi
grep -Fq ".env: a credential file in the directory of this check, which a tool may load, whether Git tracks it or not" "$tmp/check.out" &&
  ! grep -Fq -e "$fictional_key" -e "npm ran" "$tmp/check.out" ||
  fail "the check does not stop with a message that names the file, or the key is available: $(cat "$tmp/check.out")"
git -C "$repo" worktree add -q --detach "$tmp/integration-clean" adopt/agent-codeyard
(cd "$tmp/integration-clean" && PATH="$tmp/npm-bin:$PATH" PAYMENTS_API_KEY="$fictional_key" bash -eo pipefail -c "$check") >"$tmp/check.out" 2>&1 &&
  grep -Fxq "npm ran; the key: absent" "$tmp/check.out" ||
  fail "the check does not run in a clean working copy, or the key is available there: $(cat "$tmp/check.out")"
# A .env that Git tracks is loaded all the same: in a working copy where
# it is committed, the check stops too and the key is not available.
printf 'PAYMENTS_API_KEY=%s\n' "$fictional_key" >"$tmp/integration-clean/nextjs/.env"
git -C "$tmp/integration-clean" add -f nextjs/.env
git -C "$tmp/integration-clean" -c user.name=Test -c user.email=test@example.com commit -qm "A tracked .env"
if (cd "$tmp/integration-clean" && PATH="$tmp/npm-bin:$PATH" bash -eo pipefail -c "$check") >"$tmp/check.out" 2>&1; then
  fail "the check ran with a tracked credential file in its directory: $(cat "$tmp/check.out")"
fi
grep -Fq ".env: a credential file in the directory of this check" "$tmp/check.out" &&
  ! grep -Fq -e "$fictional_key" -e "npm ran" "$tmp/check.out" ||
  fail "the check does not stop on a tracked .env, or the key is available: $(cat "$tmp/check.out")"
git -C "$repo" worktree remove --force "$tmp/integration-clean"
rm "$repo/nextjs/.env"
[[ ! -e "$repo/tests/unit" && ! -e "$repo/.env.example" ]] || fail "starter files were added beside an application in a subdirectory"
grep -q '^pr create --base develop --head adopt/agent-codeyard' "$MOCK_GH_LOG" || fail "the pull request does not go into develop: $(cat "$MOCK_GH_LOG")"
grep -Fq '**A merge of this pull request into `develop` triggers a deployment**' "$MOCK_GH_LOG.body" &&
  grep -Fq '`.github/workflows/deploy.yml`, on a push to `develop`: runs npx vercel deploy --prod' "$MOCK_GH_LOG.body" ||
  fail "the pull request does not say that the merge deploys: $(cat "$MOCK_GH_LOG.body")"
grep -Fq "A merge into develop triggers a deployment" "$repo.out" || fail "the adoption does not say that the merge deploys: $(cat "$repo.out")"

echo "adopt-repository tests passed"
