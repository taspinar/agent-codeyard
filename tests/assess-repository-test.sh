#!/usr/bin/env bash

set -euo pipefail

# The read-only assessment of a repository to adopt: facts that are only
# read, no project code that runs, no secret value in the output, a report
# that keeps facts, assumptions, and questions apart, and a proposal.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/assess-repository-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "assess-repository test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# The test's own Git, past the traps of the fixtures.
own_git() {
  git -c core.fsmonitor=false -c filter.marker.clean=cat "$@"
}
commit_all() {
  own_git -C "$1" add -A
  own_git -C "$1" -c user.name=Test -c user.email=test@example.com commit -qm "$2"
}

# The template checkout the assessment runs from, from the files the
# template carries into an adopted project too; its product files and CI,
# which an adoption leaves behind, are written here.
template="$tmp/template"
mkdir -p "$template/docs" "$template/.github/workflows" "$template/src"
copy_workflow "$template"
workflow_gitignore "$template/.gitignore"
cp "$source_root/AGENTS.md" "$template/"
printf '# The template\n' >"$template/README.md"
printf 'The licence of the template.\n' >"$template/LICENSE"
cp "$source_root/.agents/agents.conf" "$template/.agents/"
template_conf "$template/.agents/template.conf"
cp "$source_root/docs/architecture.md" "$source_root/docs/development.md" "$template/docs/"
printf 'name: ci of the template\non: [push]\njobs: {}\n' >"$template/.github/workflows/ci.yml"
: >"$template/src/.gitkeep"
# The starter files of a new project, a decision record of the template's
# own, and a directory its template.conf excludes: an adoption carries none
# of the last two.
mkdir -p "$template/tests/unit" "$template/tests/e2e" "$template/tests/integration" "$template/docs/decisions" "$template/docs/internal"
: >"$template/tests/unit/.gitkeep"
: >"$template/tests/e2e/.gitkeep"
: >"$template/tests/integration/.gitkeep"
printf 'APP_URL=http://localhost:3000\n' >"$template/.env.example"
printf '# Decisions\n' >"$template/docs/decisions/README.md"
printf '# 0001. A decision of the template\n' >"$template/docs/decisions/0001-template-choice.md"
printf '{}\n' >"$template/docs/internal/notes.json"
sed -i 's|^paths: .*|& :(exclude)docs/internal|' "$template/.agents/template.conf"
git -C "$template" init -q -b main
commit_all "$template" "Template"

secret_value="fixture-secret-value-4711"
# Content of the env: blocks of the CI that the parsers of the CI would pick
# up as a run step or an action if anything but the env filter read it.
env_marker="env-block-content-4711"
inline_value="plain-inline-value-0815"
token_value="ghp_$(printf 'a%.0s' {1..36})"

# make_target <name>: a small repository with a stack, declared commands, CI
# with a secret reference and inline credentials, a deployment file, an
# ignored .env, a tracked credentials file, and traps that leave a marker when anything of the
# repository runs: a file system monitor, a filter driver, an installer
# hook, and a Makefile target.
make_target() {
  local repo="$tmp/$1"

  mkdir -p "$repo/src" "$repo/docs" "$repo/.github/workflows"
  cat >"$repo/package.json" <<JSON
{"name": "fixture", "main": "src/index.js",
 "scripts": {"test": "node test.js", "build": "node build.js", "postinstall": "touch $tmp/ran-postinstall"}}
JSON
  printf 'test:\n\ttouch %s/ran-make\n' "$tmp" >"$repo/Makefile"
  printf 'console.log("fixture");\n' >"$repo/src/index.js"
  printf '# Fixture service\n' >"$repo/README.md"
  printf '# Requirements of the fixture\n' >"$repo/docs/requirements.md"
  printf 'FROM scratch\n' >"$repo/Dockerfile"
  cat >"$repo/.github/workflows/build.yml" <<YAML
name: build
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      SECRET_IN_ENV: $secret_value
      ENV_SCRIPT: |
        run: echo $env_marker
        uses: $env_marker/action@v1
    steps:
      - uses: actions/checkout@v4
        env: { CHECKOUT_TOKEN: "\${{ secrets.CHECKOUT_TOKEN }}", NOTE: "$env_marker" }
      - run: npm test
      - name: Deploy
        run: |
          API_TOKEN=$inline_value ./deploy.sh
          curl -H "Authorization: Bearer $token_value" https://example.com
        env:
          TOKEN: \${{ secrets.DEPLOY_TOKEN }}
YAML
  printf '*.js filter=marker\n' >"$repo/.gitattributes"
  printf 'SECRET=%s\n' "$secret_value" >"$repo/.env"
  printf '{"key": "%s"}\n' "$secret_value" >"$repo/credentials.json"
  git -C "$repo" init -q -b main
  printf '.env\n' >>"$repo/.git/info/exclude"
  commit_all "$repo" "Fixture"
  git -C "$repo" config core.fsmonitor "touch $tmp/ran-fsmonitor; false"
  git -C "$repo" config filter.marker.clean "touch $tmp/ran-filter; cat"
  # A changed timestamp makes Git compare the content, through the filter.
  touch -t 202001010000 "$repo/src/index.js"
  printf '%s\n' "$repo"
}

# snapshot <repo>: the content of every file, also under .git, and a marker
# whose time a changed or added file would pass.
snapshot() {
  (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do cksum "$file"; done) >"$1.snapshot"
  touch "$1.marker"
}
unchanged() {
  local now

  now="$(cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do cksum "$file"; done)"
  [[ "$now" == "$(cat "$1.snapshot")" ]] || fail "$2: the content of the repository changed: $(diff <(printf '%s\n' "$now") "$1.snapshot" | head -n 5)"
  [[ -z "$(find "$1" -newer "$1.marker" -print)" ]] || fail "$2: the repository was written: $(find "$1" -newer "$1.marker" -print | head -n 5)"
  for marker in ran-postinstall ran-make ran-fsmonitor ran-filter; do
    [[ ! -e "$tmp/$marker" ]] || fail "$2: code of the repository ran ($marker)"
  done
}

assess() {
  local repo="$1"
  shift
  (
    cd "$template"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.agent" ./scripts/assess-repository.sh "$repo" "$@"
  ) >"$repo.out" 2>&1
}

# latest <repo>: the directory of the last assessment, as the script named it.
latest() {
  printf '%s/%s\n' "$template" "$(sed -n 's#^Assessment facts: \(.*\)facts.json$#\1#p' "$1.out" | tail -n 1)"
}

# no_secret <dir> <label>: no secret value of the fixture is in the output.
no_secret() {
  if grep -rFl -e "$secret_value" -e "$inline_value" -e "$token_value" "$1" >/dev/null; then
    fail "$2: a secret value is in $(grep -rFl -e "$secret_value" -e "$inline_value" -e "$token_value" "$1" | head -n 1)"
  fi
}

# result <facts> [<jq>]: a valid result for these facts, changed by <jq>.
result() {
  jq -c '{summary: "A small Node service with CI and a container.",
    facts: [{statement: "The repository is a Git repository on main.", evidence: ["git"]},
            {statement: "package.json declares the scripts.", evidence: ["manifest:package.json"]}],
    assumptions: [{statement: "The service is a single Node process.", basis: "src/index.js is the main entry of package.json."}],
    questions: [{question: "Is make test or npm test the suite?", why: "Which command becomes the test check."}],
    risks: [{risk: "A push to main may deploy the container.", basis: "The repository has a Dockerfile and a CI workflow."}],
    collisions: [.adoption.collisions[] | {path, resolution: "keep-project", rationale: "The project'"'"'s own file."}],
    profile: {name: "standard", rationale: "It has deployment configuration."},
    verification: [.commands[] | select(.origin == "ci" and .command == "npm test") | {name: "tests", source: .id, rationale: "The CI runs it."}],
    execution_needed: [{what: "npm ci", why: "The tests need the dependencies.", side_effects: "Runs the postinstall script of package.json."}]}
    | '"${2:-.}" "$1"
}

# --------------------------------------------- a repository without collisions
repo="$(make_target clean)"
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of a clean repository failed"; }
[[ ! -e "$repo.agent" ]] || fail "--facts-only called an agent"
facts="$(latest "$repo")facts.json"
unchanged "$repo" "the facts"
no_secret "$(latest "$repo")" "the facts"
jq -e '.git | .repository and .branch == "main" and (.head | length) == 40 and .uncommitted_changes == []' "$facts" >/dev/null ||
  fail "the Git state is wrong: $(jq -c .git "$facts")"
jq -e '.manifests == [{id: "manifest:package.json", path: "package.json", language: "JavaScript/TypeScript", package_manager: "npm"}]' "$facts" >/dev/null ||
  fail "the stack is wrong: $(jq -c .manifests "$facts")"
for command in "declared npm run test" "declared npm run build" "declared make test" "ci npm test"; do
  jq -e --arg origin "${command%% *}" --arg command "${command#* }" '.commands | any(.origin == $origin and .command == $command)' "$facts" >/dev/null ||
    fail "the command '$command' is missing: $(jq -c '.commands | map([.origin, .command])' "$facts")"
done
jq -e '.commands | any(.origin == "ci" and (.command | contains("API_TOKEN=[value omitted]")) and (.command | contains("Authorization: [value omitted]")))' "$facts" >/dev/null ||
  fail "the inline credentials of the CI were not replaced: $(jq -c '.commands | map(.command)' "$facts")"
jq -e '.ci == [{id: "ci:.github/workflows/build.yml", path: ".github/workflows/build.yml", system: "github-actions", parsed: true,
  secret_references: ["CHECKOUT_TOKEN", "DEPLOY_TOKEN"], actions: ["actions/checkout@v4"], triggers: [{event: "push", branch: "*"}],
  deploys: ["runs API_TOKEN=[value omitted] ./deploy.sh"]}]' "$facts" >/dev/null || fail "the CI is wrong: $(jq -c .ci "$facts")"
! grep -rFq -- "$env_marker" "$(latest "$repo")" || fail "the content of an env: block of the CI was read: $(grep -rFl -- "$env_marker" "$(latest "$repo")" | head -n 1)"
jq -e '.secret_files == [{id: "secret-file:.env", path: ".env", tracked_or_unignored: false, contents_read: false},
  {id: "secret-file:credentials.json", path: "credentials.json", tracked_or_unignored: true, contents_read: false}]' "$facts" >/dev/null ||
  fail "the secret files are not named as unread, with whether Git tracks them: $(jq -c .secret_files "$facts")"
jq -e '(.deployment | map(.path)) == ["Dockerfile"] and (.entry_points | any(.target == "src/index.js"))
  and (.documents | any(.path == "docs/requirements.md" and .kind == "requirements" and .title == "Requirements of the fixture"))' "$facts" >/dev/null ||
  fail "the deployment, entry points, or documents are wrong: $(jq -c '{deployment, entry_points, documents}' "$facts")"
jq -e '.adoption | .collisions == [] and (.additions | any(.path == "AGENTS.md" and .ownership == "template"))
  and (.additions | any(.path == "docs/architecture.md" and .ownership == "project"))
  and (.additions | any(.path == "README.md" or .path == "LICENSE" or .path == "src/.gitkeep") | not)
  and (.additions | any(.path == "docs/decisions/README.md"))
  and (.additions | any(.path == "docs/decisions/0001-template-choice.md" or (.path | startswith("docs/internal/"))) | not)
  and (.not_carried | index([":(exclude)docs/internal"]))' "$facts" >/dev/null ||
  fail "the additions are wrong: $(jq -c .adoption "$facts")"
# The application is at the top: the starter files of its tests and its
# environment are proposed.
jq -e '.adoption | .left_out == [] and ([.additions[].path] | index(["tests/unit/.gitkeep"]) and index([".env.example"]))' "$facts" >/dev/null ||
  fail "the starter files of an application at the top are not proposed: $(jq -c .adoption.left_out "$facts")"
# The measured branch is the integration branch, and the proposed base.
jq -e '.branches | .measured == "main" and .integration.name == "main" and (.differs | not)' "$facts" >/dev/null ||
  fail "the branches of a single-branch repository are wrong: $(jq -c .branches "$facts")"
jq -e --arg commit "$(git -C "$template" rev-parse HEAD)" '.template.commit == $commit and .template.uncommitted_changes == false' "$facts" >/dev/null ||
  fail "the template version is wrong: $(jq -c .template "$facts")"
[[ "$(jq -c .adoption.ignored "$facts")" == "[]" ]] || fail "a path is hidden in a repository without ignore rules: $(jq -c .adoption.ignored "$facts")"

# The assessor: read-only, in an empty directory, without the path of the
# repository.
# While it runs, the mock copies the working directory of the assessment,
# where every intermediate file is: the env filter writes no value of an env:
# block, so none is in a file that a later step, the assessor, or the report
# reads.
mkdir "$tmp/work-tmp"
TMPDIR="$tmp/work-tmp" MOCK_OUTPUT="$(result "$facts")" \
  MOCK_AGENT_ACTION='pwd >"$MOCK_AGENT_LOG.pwd"; ls -A >"$MOCK_AGENT_LOG.ls"; cp -R "'"$tmp/work-tmp"'" "$MOCK_AGENT_LOG.work"' assess "$repo" ||
  { cat "$repo.out" >&2; fail "the assessment of a clean repository failed"; }
dir="$(latest "$repo")"
unchanged "$repo" "the assessment"
no_secret "$dir" "the assessment"
filtered="$(find "$repo.agent.work" -path '*/assess-repository.*/workflow' -type f | head -n 1)"
[[ -n "$filtered" ]] && grep -Fq 'secrets.DEPLOY_TOKEN' "$filtered" ||
  fail "the working directory of the assessment holds no filtered workflow: $(find "$repo.agent.work" -type f | head -n 5)"
if grep -rFl -e "$env_marker" -e "$secret_value" "$repo.agent.work" "$repo.agent.stdin" >/dev/null; then
  fail "a value of an env: block was written past the filter: $(grep -rFl -e "$env_marker" -e "$secret_value" "$repo.agent.work" "$repo.agent.stdin" | head -n 1)"
fi
grep -q "ARGS=.*--print" "$repo.agent" || fail "the assessor did not run as a read-only session"
if grep -Eq "acceptEdits|workspace-write|--permission-mode auto" "$repo.agent"; then fail "the assessor could write"; fi
[[ "$(cat "$repo.agent.pwd")" != "$repo"* && ! -s "$repo.agent.ls" ]] || fail "the assessor did not run in an empty directory: $(cat "$repo.agent.pwd")"
if grep -Fq "$repo" "$repo.agent.stdin"; then fail "the assessor was given the path of the repository"; fi
for file in facts.json report.md proposal.json; do [[ -f "$dir$file" ]] || fail "the assessment lacks $file"; done
report="$dir/report.md"
headings="$(grep -E '^## ' "$report" | tr '\n' '|')"
[[ "$headings" == "## Observed facts|## Assumptions (observed, not approved)|## Questions for the owner|## Risks (observed, not approved)|## Proposal|" ]] ||
  fail "the report does not keep facts, assumptions, and questions apart: $headings"
grep -Fq "Everything else in this report, the assumptions, the reconstructed architecture, and the proposal, is an inference: it is no owner-approved requirement and no historical decision." "$report" ||
  fail "the report does not say that its inferences are not approved"
grep -Fq -- '- The repository is a Git repository on main. (`git`)' "$report" || fail "a fact does not cite its evidence"
grep -Fq "  - basis: src/index.js is the main entry of package.json." "$report" || fail "an assumption lacks its basis"
proposal="$dir/proposal.json"
jq -e --arg commit "$(git -C "$template" rev-parse HEAD)" '
  .status == "proposed, not approved" and .template.commit == $commit and .profile.name == "standard"
  and (.additions | length) > 0 and .collisions == []
  and (.verification == [{name: "tests", command: "npm test", directory: null, origin: "ci", source: ".github/workflows/build.yml",
        command_id: .verification[0].command_id, rationale: "The CI runs it.", isolated: true, external_actions: []}])
  and (.ownership.template_paths | index(["scripts"])) and (.ownership.template_owned | index(["AGENTS.md"]))
  and (.ownership.project_owned | index(["docs/architecture.md"])) and (.execution_needed | length) == 1
  and (.baseline | (.facts | length) == 2 and (.assumptions | length) == 1 and (.questions | length) == 1
       and .risks == [{risk: "A push to main may deploy the container.", basis: "The repository has a Dockerfile and a CI workflow."}]
       and (.documents | type) == "array")' "$proposal" >/dev/null ||
  fail "the proposal lacks a part: $(jq -c 'del(.additions, .ownership.template_owned)' "$proposal")"
[[ -z "$(git -C "$template" status --porcelain)" ]] || fail "the assessment is not ignored by Git: $(git -C "$template" status --porcelain)"

# Repeating it is safe and makes a new assessment; the earlier one stays.
first="$dir"
(cd "$first" && cksum facts.json report.md proposal.json) >"$tmp/first.sums"
MOCK_OUTPUT="$(result "$facts")" assess "$repo" || { cat "$repo.out" >&2; fail "a repeated assessment failed"; }
second="$(latest "$repo")"
[[ "$second" != "$first" && -f "${second}report.md" && -f "${second}proposal.json" ]] || fail "a repeated assessment made no new one: $first $second"
[[ "$(cd "$first" && cksum facts.json report.md proposal.json)" == "$(cat "$tmp/first.sums")" ]] || fail "a repeated assessment changed the earlier one"
unchanged "$repo" "the repeated assessment"

# An assessor that writes into the repository fails the assessment.
if MOCK_AGENT_ACTION="touch $repo/written.txt" MOCK_OUTPUT="$(result "$facts")" assess "$repo"; then
  fail "an assessor that wrote into the repository succeeded"
fi
grep -Fq "the assessed repository changed during the assessment" "$repo.out" || fail "the write was not reported"
rm -f "$repo/written.txt"

# ----------------------------------------------- a repository with collisions
repo="$(make_target colliding)"
mkdir -p "$repo/scripts"
printf '# Our agents\n' >"$repo/AGENTS.md"
printf '#!/bin/sh\n' >"$repo/scripts/build.sh"
printf '# Our architecture\n' >"$repo/docs/architecture.md"
printf 'name: ci\n' >"$repo/.github/workflows/ci.yml"
printf 'node_modules/\n' >"$repo/.gitignore"
commit_all "$repo" "Own files"
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of a colliding repository failed"; }
facts="$(latest "$repo")facts.json"
[[ "$(jq -c '.adoption.collisions | map([.path, .ownership, .kind]) | sort' "$facts")" == \
  '[[".github/workflows/ci.yml","template","file"],[".gitignore","template","file"],["AGENTS.md","template","file"],["docs/architecture.md","project","file"]]' ]] ||
  fail "the collisions are wrong: $(jq -c '.adoption.collisions' "$facts")"
[[ "$(jq -c '.adoption.shared_directories | map(.path)' "$facts")" == '[".github","docs","scripts"]' ]] ||
  fail "the shared directories are wrong: $(jq -c '.adoption.shared_directories' "$facts")"
# The assessor judges a planning document by its length and its headings.
[[ "$(jq -c '.documents[] | select(.path == "docs/architecture.md") | [.lines, .headings]' "$facts")" == '[1,["# Our architecture"]]' ]] ||
  fail "the planning document lacks its length or headings: $(jq -c .documents "$facts")"

# invalid <label> <jq> <message>: a result that is rejected twice.
invalid() {
  if MOCK_OUTPUT="$(result "$facts" "$2")" assess "$repo"; then fail "$1 was accepted"; fi
  grep -Fq "$3" "$repo.out" || { cat "$repo.out" >&2; fail "$1 was not reported as such"; }
  [[ ! -e "$(latest "$repo")report.md" && ! -e "$(latest "$repo")proposal.json" ]] || fail "$1 was kept"
}
invalid "a collision without a resolution" '.collisions |= map(select(.path != "AGENTS.md"))' "the collision AGENTS.md has no resolution"
invalid "taking over the project's AGENTS.md" '.collisions |= map(if .path == "AGENTS.md" then .resolution = "take-template" else . end)' \
  "the collision AGENTS.md cannot be resolved with take-template"
invalid "a command the project does not declare" '.verification = [{name: "tests", source: "command:999", rationale: "x"}]' \
  "names command:999, which is no command of the facts"
invalid "a fact without its evidence" '.facts[0].evidence = ["docs/made-up.md"]' "cites docs/made-up.md, which is not in the facts"
invalid "an assumption without a basis" '.assumptions[0].basis = " "' "names no basis"
invalid "a risk without a basis" '.risks[0].basis = ""' "the risk \"A push to main may deploy the container.\" names no basis"
invalid "merging a planning document of the baseline" '.collisions |= map(if .path == "docs/architecture.md" then .resolution = "merge" else . end)' \
  "the collision docs/architecture.md is a planning document of the baseline"
invalid "reconstructing another file" '.collisions |= map(if .path == "AGENTS.md" then .resolution = "reconstruct" else . end)' \
  "the collision AGENTS.md cannot be resolved with reconstruct"
unchanged "$repo" "the rejected assessments"

MOCK_OUTPUT="$(result "$facts" '.collisions |= map(if .path == "docs/architecture.md" then .resolution = "reconstruct" else . end)')" assess "$repo" ||
  { cat "$repo.out" >&2; fail "the assessment of a colliding repository failed"; }
proposal="$(latest "$repo")proposal.json"
[[ "$(jq -c '.ownership.project_exclusions' "$proposal")" == '[":(exclude).github/workflows/ci.yml",":(exclude).gitignore",":(exclude)AGENTS.md"]' ]] ||
  fail "the project's files are not excluded from the template's ownership: $(jq -c .ownership.project_exclusions "$proposal")"
jq -e '.collisions | any(.path == "docs/architecture.md" and .resolution == "reconstruct" and .ownership == "project")' "$proposal" >/dev/null ||
  fail "the resolution is not in the proposal: $(jq -c .collisions "$proposal")"
grep -Fq '| `AGENTS.md` | template | file | no | keep-project |' "$(latest "$repo")report.md" || fail "the report lacks the collision table"
unchanged "$repo" "the colliding assessment"

# ------------------------------------------ a repository with uncommitted work
printf 'local edit\n' >>"$repo/docs/architecture.md"
printf 'notes\n' >"$repo/notes.txt"
own_git -C "$repo" checkout -q -b feature/local
status_before="$(own_git -C "$repo" status --porcelain)"
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of a dirty repository failed"; }
facts="$(latest "$repo")facts.json"
[[ "$(jq -c '.git | [.branch, .uncommitted_changes]' "$facts")" == '["feature/local",[{"status":" M","path":"docs/architecture.md"},{"status":"??","path":"notes.txt"}]]' ]] ||
  fail "the uncommitted changes are wrong: $(jq -c .git "$facts")"
jq -e '.adoption.collisions | any(.path == "docs/architecture.md" and .uncommitted)' "$facts" >/dev/null ||
  fail "the collision with uncommitted changes is not marked"
invalid "taking over a file with uncommitted changes" '.collisions |= map(if .path == "docs/architecture.md" then .resolution = "take-template" else . end)' \
  "the collision docs/architecture.md cannot be resolved with take-template"
MOCK_OUTPUT="$(result "$facts")" assess "$repo" || { cat "$repo.out" >&2; fail "the assessment of a dirty repository failed"; }
unchanged "$repo" "the dirty assessment"
[[ "$(own_git -C "$repo" status --porcelain)" == "$status_before" && "$(own_git -C "$repo" branch --show-current)" == "feature/local" ]] ||
  fail "the uncommitted work or the branch changed"

# ------------------------------------ ignore rules that hide the workflow's files
# The project ignores *.json, with an exception of its own, and a directory
# of the workflow; a local rule hides a document. Every path the workflow
# commits, now or later, that a rule hides is named with the rule.
repo="$(make_target ignoring)"
printf 'node_modules/\n*.json\n!package.json\n.agents/plans/\n/docs/decisions/0*\n' >"$repo/.gitignore"
commit_all "$repo" "Ignore rules"
printf 'docs/development.md\n' >>"$repo/.git/info/exclude"
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of an ignoring repository failed"; }
facts="$(latest "$repo")facts.json"
unchanged "$repo" "the facts of an ignoring repository"
jq -e '.adoption.ignored as $i
  | ($i | map({key: .path, value: .}) | from_entries) as $by
  | $by[".agents/approval-requests/x.json"] == {id: "ignored:.agents/approval-requests/x.json", path: ".agents/approval-requests/x.json",
      rule: {source: ".gitignore", line: 2, pattern: "*.json"}, ignored_directory: null}
  and $by[".agents/schemas/review.schema.json"].rule.pattern == "*.json"
  and $by[".agents/plans/x.md"].ignored_directory == ".agents/plans"
  and $by["docs/development.md"].rule.source == ".git/info/exclude"
  and ($i | map(.path) | all(startswith(".agents/schemas/") or startswith(".agents/plans/") or . == ".agents/approval-requests/x.json" or . == "docs/development.md"))
  and (.evidence_ids | index(["ignored:.agents/approval-requests/x.json"]))' "$facts" >/dev/null ||
  fail "the hidden paths are wrong: $(jq -c '.adoption.ignored | map([.path, .rule.pattern, .ignored_directory])' "$facts")"
# The rules hide the template's decision record and a file of a directory its
# template.conf excludes too; the adoption carries neither, so neither is a
# path of the workflow (#303).
jq -e '.adoption.ignored | any(.path == "docs/decisions/0001-template-choice.md" or (.path | startswith("docs/internal/"))) | not' "$facts" >/dev/null ||
  fail "a path the adoption does not carry is reported as hidden: $(jq -c '.adoption.ignored | map(.path)' "$facts")"
grep -Fq "Hidden by an ignore rule of the repository: $(jq '.adoption.ignored | length' "$facts") paths" "$repo.out" || fail "the hidden paths are not counted: $(cat "$repo.out")"
MOCK_OUTPUT="$(result "$facts")" assess "$repo" || { cat "$repo.out" >&2; fail "the assessment of an ignoring repository failed"; }
jq -e '.ignored | any(.path == ".agents/approval-requests/x.json" and .rule.pattern == "*.json") and all(has("id") | not)' "$(latest "$repo")proposal.json" >/dev/null ||
  fail "the proposal lacks the hidden paths: $(jq -c .ignored "$(latest "$repo")proposal.json")"
grep -Fq -- '- `.agents/approval-requests/x.json`: `*.json` in `.gitignore`' "$(latest "$repo")report.md" &&
  grep -Fq -- '- `.agents/plans/x.md`: `.agents/plans/` in `.gitignore`, through the ignored directory `.agents/plans`' "$(latest "$repo")report.md" ||
  fail "the report does not name the hidden paths: $(cat "$(latest "$repo")report.md")"
unchanged "$repo" "the assessment of an ignoring repository"

# ------------------------------------------------- the branch features merge into
# The work happens on develop, ahead of main with merged pull requests; main
# is checked out. The assessment names the branch it measures, detects
# develop, asks, and proposes it as the base.
repo="$(make_target branches)"
own_git -C "$repo" checkout -q -b develop
for number in 1 2; do
  own_git -C "$repo" checkout -q -b "feature/$number" develop
  printf 'feature %s\n' "$number" >"$repo/feature-$number.txt"
  commit_all "$repo" "Feature $number"
  own_git -C "$repo" checkout -q develop
  own_git -C "$repo" -c user.name=Test -c user.email=test@example.com merge -q --no-ff -m "Merge pull request #$number from owner/feature-$number" "feature/$number"
done
own_git -C "$repo" checkout -q main
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of a repository with develop failed"; }
facts="$(latest "$repo")facts.json"
jq -e '.branches | .measured == "main" and .integration.name == "develop" and .integration.ahead == 4 and .integration.pull_request_merges == 2
  and .differs and (.candidates | map(.name) | index(["feature/1"]) | not)' "$facts" >/dev/null ||
  fail "the integration branch is not detected: $(jq -c .branches "$facts")"
grep -Fq "Measured branch: main; integration branch: develop" "$repo.out" && grep -Fq "The assessment measures main, not the integration branch develop" "$repo.out" ||
  fail "the measured and the integration branch are not named: $(cat "$repo.out")"
MOCK_OUTPUT="$(result "$facts")" assess "$repo" || { cat "$repo.out" >&2; fail "the assessment of a repository with develop failed"; }
jq -e '.base == {measured: "main", integration: "develop", reason: .base.reason, differs: true, proposed: "develop"}
  and (.baseline.questions[0].question | test("measured main, but features appear to merge into develop"))' "$(latest "$repo")proposal.json" >/dev/null ||
  fail "the proposal does not propose develop as the base, or does not ask: $(jq -c '{base, questions: .baseline.questions}' "$(latest "$repo")proposal.json")"
grep -Fq 'The assessment measured the branch `main`' "$(latest "$repo")report.md" &&
  grep -Fq '**The checked-out branch is not the one features merge into.**' "$(latest "$repo")report.md" &&
  grep -Fq 'Proposed for `.agents/template.conf`: `base: develop`.' "$(latest "$repo")report.md" ||
  fail "the report does not name the branches and the base: $(cat "$(latest "$repo")report.md")"
unchanged "$repo" "the assessment of a repository with develop"

# ------------------------------------------- a name that differs only in case
repo="$(make_target cased)"
printf '# Architecture\n\nThe parts of the service.\n' >"$repo/docs/ARCHITECTURE.md"
commit_all "$repo" "Architecture"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of a repository with docs/ARCHITECTURE.md failed"; }
facts="$(latest "$repo")facts.json"
jq -e '(.adoption.collisions | map(select(.path == "docs/architecture.md"))) == [{id: "collision:docs/architecture.md", path: "docs/architecture.md",
    ownership: "project", kind: "case-only", blocking_path: null, project_path: "docs/ARCHITECTURE.md", uncommitted: false}]
  and (.adoption.additions | any(.path == "docs/architecture.md") | not)' "$facts" >/dev/null ||
  fail "the name that differs only in case is no collision: $(jq -c .adoption.collisions "$facts")"
MOCK_OUTPUT="$(result "$facts")" assess "$repo" || { cat "$repo.out" >&2; fail "the assessment of a repository with docs/ARCHITECTURE.md failed"; }
grep -Fq '| `docs/architecture.md` | project | case-only (`docs/ARCHITECTURE.md`, renamed to the expected name with `git mv`, keeping its history) |' \
  "$(latest "$repo")report.md" || fail "the report does not propose the rename: $(grep -F 'docs/architecture.md' "$(latest "$repo")report.md")"

# ------------------------------------------ an application in a subdirectory
# A Next.js application in nextjs/, with its tests and its env example there,
# a CI that runs in that directory, a build that migrates the database, and a
# deployment on every push to main.
repo="$tmp/subdirectory"
mkdir -p "$repo/nextjs/tests" "$repo/.github/workflows"
cat >"$repo/nextjs/package.json" <<'JSON'
{"name": "web", "scripts": {"build": "prisma migrate deploy && next build", "test": "vitest run"},
 "dependencies": {"next": "15.0.0", "@prisma/client": "6.0.0", "nodemailer": "6.9.0", "stripe": "17.0.0"},
 "devDependencies": {"prisma": "6.0.0", "vitest": "2.0.0"}}
JSON
printf 'test("page", () => {});\n' >"$repo/nextjs/tests/page.test.js"
printf 'DATABASE_URL=\n' >"$repo/nextjs/.env.example"
cat >"$repo/.github/workflows/ci.yml" <<'YAML'
name: ci
on:
  pull_request:
    branches: [main]
defaults:
  run:
    working-directory: nextjs
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm run build
      - name: Tests
        working-directory: ./nextjs/
        run: npm test
      - name: Smoke
        run: curl -fsS https://example.com/health
YAML
cat >"$repo/.github/workflows/production.yml" <<'YAML'
name: production
on:
  push:
    branches:
      - main
jobs:
  ship:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - run: npx vercel deploy --prod
YAML
git -C "$repo" init -q -b main
commit_all "$repo" "Next.js in a subdirectory"
snapshot "$repo"
assess "$repo" --facts-only || { cat "$repo.out" >&2; fail "the facts of an application in a subdirectory failed"; }
facts="$(latest "$repo")facts.json"
unchanged "$repo" "the facts of an application in a subdirectory"
jq -e '(.adoption.left_out | map(.path)) == [".env.example", "tests/e2e/.gitkeep", "tests/integration/.gitkeep", "tests/unit/.gitkeep"]
  and (.adoption.left_out[0].reason | test("nextjs/"))
  and (.adoption.additions | any(.path | test("^tests/(unit|e2e|integration)/|^\\.env\\.example$")) | not)' "$facts" >/dev/null ||
  fail "starter files are proposed beside an application in a subdirectory: $(jq -c '{left_out: .adoption.left_out, additions: [.adoption.additions[].path | select(startswith("tests/") or startswith(".env"))]}' "$facts")"
jq -e '[.commands[] | select(.origin == "ci") | [.command, .directory]] == [["npm run build", "nextjs"], ["npm test", "nextjs"],
  ["curl -fsS https://example.com/health", "nextjs"], ["npx vercel deploy --prod", null]]' "$facts" >/dev/null ||
  fail "the CI commands do not carry their working directory: $(jq -c '[.commands[] | select(.origin == "ci") | [.command, .directory]]' "$facts")"
jq -e '.external_actions | map([.kind, .dependency]) as $a
  | ($a | index([["database", "@prisma/client"]])) and ($a | index([["email", "nodemailer"]])) and ($a | index([["external-api", "stripe"]]))
  and ($a | index([["telemetry", "next"]])) and any(.[]; .kind == "database" and (.what | test("prisma migrate deploy")))' "$facts" >/dev/null ||
  fail "the external actions are not named: $(jq -c .external_actions "$facts")"
build_id="$(jq -r '.commands[] | select(.origin == "ci" and .command == "npm run build") | .id' "$facts")"
smoke_id="$(jq -r '.commands[] | select(.origin == "ci" and (.command | startswith("curl "))) | .id' "$facts")"
# The external actions of a check that only its command text shows: the
# migration in the definition of the declared build, and the request of the
# smoke check.
migration_id="$(jq -r '.external_actions[] | select(.kind == "database" and .dependency == null and (.what | test("prisma migrate deploy"))) | .id' "$facts")"
request_id="$(jq -r --arg smoke "$smoke_id" '.external_actions[] | select(.kind == "external-api" and .source == $smoke) | .id' "$facts")"
[[ -n "$migration_id" && -n "$request_id" ]] || fail "the external actions of the command text are not found: $(jq -c .external_actions "$facts")"
MOCK_OUTPUT="$(result "$facts" '.facts[1].evidence = ["manifest:nextjs/package.json"] | .verification = [{name: "build", source: "'"$build_id"'", rationale: "The CI runs it."},
  {name: "smoke", source: "'"$smoke_id"'", rationale: "The CI runs it."}]')" assess "$repo" ||
  { cat "$repo.out" >&2; fail "the assessment of an application in a subdirectory failed"; }
proposal="$(latest "$repo")proposal.json"
report="$(latest "$repo")report.md"
jq -e '(.verification[0] | .directory == "nextjs" and .isolated
    and (.external_actions | map(.kind) | index(["database"]) and index(["telemetry"]) and index(["email"])))
  and (.verification[0].external_actions | map(.id) | index([$migration]))
  and (.verification[1].external_actions | map(.id) | index([$request]))
  and (.isolation.env | map(.name) == ["DATABASE_URL", "DO_NOT_TRACK", "NEXT_TELEMETRY_DISABLED"])
  and (.isolation.env[0].value | test("127\\.0\\.0\\.1:1/"))
  and .deployment_on_merge == [{workflow: ".github/workflows/production.yml", branch: "main", triggers: ["main"],
       reasons: ["environment of the job ship", "runs npx vercel deploy --prod"]}]' --arg migration "$migration_id" --arg request "$request_id" "$proposal" >/dev/null ||
  fail "the proposal lacks the directory, the isolation, the external actions, or the deployment: $(jq -c '{verification, isolation, deployment_on_merge}' "$proposal")"
grep -Fq -- '- `.env.example`: the application is in nextjs/' "$report" &&
  grep -Fq -- '- build: `npm run build` in `nextjs`' "$report" &&
  grep -Fq -- '  - external actions it may take: ' "$report" && grep -Fq 'database, a database migration or client; it reaches the database it is configured for (`prisma migrate deploy`)' "$report" &&
  grep -A 1 -F -- '- smoke: `curl -fsS https://example.com/health` in `nextjs`' "$report" | grep -F -- '  - external actions it may take: ' |
    grep -Fq 'external-api, a download or a request to a server (`curl`)' &&
  grep -Fq -- '- `NEXT_TELEMETRY_DISABLED=1`: Next.js sends telemetry during a build' "$report" &&
  grep -Fq '## External actions the checks may take' <(sed 's/^###/##/' "$report") &&
  grep -Fq '**A merge into `main` triggers a deployment**, also the merge of the adoption:' "$report" ||
  fail "the report does not name the left-out starters, the isolation, the external actions, or the deployment: $(cat "$report")"
unchanged "$repo" "the assessment of an application in a subdirectory"

# ------------------------------------------------------------------ refusals
plain="$tmp/plain"
mkdir -p "$plain"
printf 'requests\n' >"$plain/requirements.txt"
assess "$plain" --facts-only || { cat "$plain.out" >&2; fail "the facts of a directory without Git failed"; }
jq -e '.git.repository == false and (.manifests | map(.path)) == ["requirements.txt"]' "$(latest "$plain")facts.json" >/dev/null ||
  fail "a directory without Git is not assessed: $(jq -c '{git, manifests}' "$(latest "$plain")facts.json")"
if assess "$tmp" --facts-only; then fail "a directory that holds the template checkout was assessed"; fi
grep -Fq "holds the template checkout" "$tmp.out" || fail "the refusal of the template checkout is not explained"

echo "assess-repository tests passed"
