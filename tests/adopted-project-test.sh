#!/usr/bin/env bash

set -euo pipefail

# The self-tests need nothing of the repository they run in but the
# template's own files: every check of scripts/verify-workflow.conf passes in
# a fixture adopted project that has the state of a real one. The project
# keeps its own CI and excludes it from the template's files, starts its
# features from 'develop', has approved its requirements, has a risk policy
# of its own, has recorded its baseline, has its own ADRs and its own
# agents, has a document that names a plan of its own and a test file of its
# own under tests/, and has an ignore rule that hides the workflow's JSON files (un-ignored again, as the adoption
# does), and has no README.md or LICENSE. It uses both extension points of a
# project (docs/development.md): a policy override in
# .agents/policy-overrides/risk.conf and a CI setup in
# .github/actions/project-setup/action.yml. It still edits the shipped
# .agents/policies/risk.conf as well, so a project that keeps its choices
# there and one that uses the override are both represented.
#
# ADOPTED_PROJECT_JOBS sets how many self-tests run at a time (default 4).

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adopted-project-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "adopted project test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# This check itself, which does not run again inside the fixture.
self="tests/$(basename "${BASH_SOURCE[0]}")"

# The template's files, as an adoption gives them to a project: without the
# documentation site and the CI workflows of the template, its decisions,
# records, and top-level README and LICENSE, and without the state of the
# repository these tests run in.
project="$tmp/project"
mkdir -p "$project"
(cd "$source_root" && git ls-files -co --exclude-standard -z -- . ':(exclude)documentation' ':(exclude).github/workflows' \
  ':(exclude)README.md' ':(exclude)LICENSE' ':(exclude).agents/approval-requests' ':(exclude).agents/verification-baseline' \
  ':(exclude).agents/template.conf' ':(exclude).gitignore' |
  while IFS= read -r -d '' path; do
    [[ "$path" != docs/decisions/* || "$path" == docs/decisions/README.md ]] || continue
    [[ -f "$path" ]] && printf '%s\0' "$path"
  done |
  tar --null -T - -cf -) | tar -C "$project" -xf -
[[ -x "$project/$self" ]] || fail "the fixture project does not have the self-tests"

# The project's own state.
mkdir -p "$project/.github/workflows" "$project/docs/decisions"
printf 'name: project-ci\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make test\n' \
  >"$project/.github/workflows/ci.yml"
# Its planning is approved: no self-test may need the draft the template
# ships.
sed -e 's/^Status: Draft$/Status: Approved/' -e 's/^Approved at: Not approved$/Approved at: 2026-01-05T09:00:00Z/' \
  "$project/docs/PROJECT_REQUIREMENTS.md" >"$tmp/requirements.md"
mv "$tmp/requirements.md" "$project/docs/PROJECT_REQUIREMENTS.md"
grep -Fqx 'Status: Approved' "$project/docs/PROJECT_REQUIREMENTS.md" || fail "the fixture's requirements are not approved"
# Its risk policy is its own: the light profile and classes of its own, in
# its policy override, and a class of its own still written into the shipped
# risk.conf, as a project did before the override. No self-test may need the
# policy the template ships.
printf '\nhigh: src/billing\n' >>"$project/.agents/policies/risk.conf"
grep -Fqx 'high: src/billing' "$project/.agents/policies/risk.conf" || fail "the fixture does not edit the shipped risk policy"
mkdir -p "$project/.agents/policy-overrides"
printf '# The project'"'"'s risk policy.\nprofile: light\nhigh: src/payments\nmanifests: package.json package-lock.json\n' \
  >"$project/.agents/policy-overrides/risk.conf"
grep -Fqx 'profile: light' "$project/.agents/policy-overrides/risk.conf" || fail "the fixture has no policy override"
# Its CI setup, the composite action that ci.yml runs before the verification.
mkdir -p "$project/.github/actions/project-setup"
printf 'name: Project setup\ndescription: Installs the dependencies of the project.\nruns:\n  using: composite\n  steps:\n    - run: make deps\n      shell: bash\n' \
  >"$project/.github/actions/project-setup/action.yml"
grep -Fqx '  using: composite' "$project/.github/actions/project-setup/action.yml" || fail "the fixture has no CI setup action"
printf '# 0001. Store orders in PostgreSQL\n\nStatus: Accepted\n\nThe project keeps its orders in PostgreSQL.\n' \
  >"$project/docs/decisions/0001-store-orders-in-postgresql.md"
# Its agents are its own: other models and level lines for the roles than
# the template's. No self-test may need the agents the template ships. The
# writing roles stay on Claude: with Codex there, tests/agent-sandbox-test.sh
# starts the real Codex CLI with the project's model wherever it is logged
# in, which is a check of the project's own account, not of the workflow.
cat >"$project/.agents/agents.conf" <<'EOF'
# The project's agents.
project-grill: claude sonnet
project-planner: claude sonnet
planning-reviewer: codex gpt-6-luna
implementer: claude sonnet
implementer@medium: claude opus
reviewer: codex gpt-6-astra
reviewer@high: codex gpt-6-luna
triage: claude opus
triage-implementer: claude sonnet
analyst: claude sonnet
assessor: claude sonnet
EOF
grep -Fqx 'implementer: claude sonnet' "$project/.agents/agents.conf" || fail "the fixture has no agents of its own"
# Its documents name a plan of its own, which the template does not have.
mkdir -p "$project/.agents/plans"
printf '# Plan of the project Issue 12\n' >"$project/.agents/plans/12-orders-api.md"
printf '\n## Orders\n\nThe orders API follows `.agents/plans/12-orders-api.md`.\n' >>"$project/docs/architecture.md"
grep -Fq '`.agents/plans/12-orders-api.md`' "$project/docs/architecture.md" ||
  fail "the fixture has no document that names a plan of its own"
# It has a test file of its own, which pipes into a quiet grep, a form the
# workflow's self-tests do not use (tests/pipe-grep-test.sh): the project's
# tests follow its own rules. The pipe is written as $bar so that this file
# does not hold the form.
bar='|'
own_test="./scripts/orders.sh list $bar grep -q order"
printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$own_test" >"$project/tests/orders.sh"
chmod +x "$project/tests/orders.sh"
grep -Fqx "$own_test" "$project/tests/orders.sh" || fail "the fixture has no test file of its own"
template_conf "$tmp/template.conf"
sed -E -e '/^repository:/ s#:.*#: https://example.com/owner/template#' \
  -e '/^paths:/ s#$# :(exclude).github/workflows/ci.yml#' "$tmp/template.conf" >"$project/.agents/template.conf"
printf 'commit: 0123456789abcdef0123456789abcdef01234567\nbase: develop\n' >>"$project/.agents/template.conf"
grep -Fq ':(exclude).github/workflows/ci.yml' "$project/.agents/template.conf" || fail "the fixture does not exclude its CI"
workflow_gitignore "$tmp/workflow.gitignore"
{
  printf '# The project'"'"'s own rules.\n*.json\n*.log\n'
  printf '\n# agent-codeyard: the working files of the workflow (added by adopt-repository.sh)\n'
  cat "$tmp/workflow.gitignore"
} >"$project/.gitignore"
git -C "$project" init -q -b main
# The workflow's files that the project's rule hides, and an approval request
# it writes later, un-ignored again as the adoption does: a file of .agents/
# by its directory and extension, another by itself.
mkdir -p "$project/.agents/approval-requests"
: >"$project/.agents/approval-requests/1.json"
git -C "$project" ls-files -o -i --exclude-standard | while IFS= read -r path; do
  name="${path##*/}"
  if [[ "$path" == .agents/*/* && "$name" == ?*.* ]]; then
    printf '!/%s/*.%s\n' "${path%/*}" "${name##*.}"
  else
    printf '!/%s\n' "$path"
  fi
done | awk '!seen[$0]++' >"$tmp/unignore"
grep -Fxq '!/.agents/schemas/*.json' "$tmp/unignore" || fail "the project's rule hides no file of the workflow"
cat "$tmp/unignore" >>"$project/.gitignore"
rm -r "$project/.agents/approval-requests"
[[ -z "$(git -C "$project" ls-files -o -i --exclude-standard)" ]] || fail "the fixture hides files of the workflow"
{
  sed -nE 's/^([a-z0-9-]+)( \[[^]]*\])?( partition [^:]+)?: .*/pass: \1/p' "$project/scripts/verify.conf" |
    grep -Ev '^pass: (budget-seconds|parallel)$'
} >"$project/.agents/verification-baseline"
[[ -s "$project/.agents/verification-baseline" ]] || fail "the fixture has no baseline"
git -C "$project" add -A
git -C "$project" -c user.name=Owner -c user.email=owner@example.com commit -qm "The adopted project"
for path in .agents/policy-overrides/risk.conf .github/actions/project-setup/action.yml; do
  git -C "$project" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || fail "the fixture does not track its $path"
done
git -C "$project" branch develop
git -C "$project" switch -q develop
git init -q --bare -b main "$tmp/project-remote.git"
git -C "$project" remote add origin "$tmp/project-remote.git"
git -C "$project" push -q origin main develop
for path in README.md LICENSE; do
  [[ ! -e "$project/$path" ]] || fail "the fixture has a $path"
done

# Every self-test, run from the fixture as ./scripts/verify.sh runs it,
# ADOPTED_PROJECT_JOBS at a time.
jobs="${ADOPTED_PROJECT_JOBS:-4}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "ADOPTED_PROJECT_JOBS is not a positive number: $jobs"
mkdir -p "$tmp/out"
# A framework-only self-test ('framework' before the colon) runs here too:
# the fixture runs every self-test, as the template does.
sed -nE 's/^([a-z0-9-]+)( \[[^]]*\])?( partition [^: ]+)?( budget)?( framework)?: (.*)$/\1\t\6/p' "$project/scripts/verify-workflow.conf" |
  grep -Ev '^(paths|budget-seconds)\b' | grep -Fv "$self" >"$tmp/checks" || true
[[ "$(wc -l <"$tmp/checks")" -gt 1 ]] || fail "no self-tests found in scripts/verify-workflow.conf"
export project tmp
tr '\n' '\0' <"$tmp/checks" | xargs -0 -P "$jobs" -I{} bash -c '
  name="${1%%$'"'"'\t'"'"'*}"
  command="${1#*$'"'"'\t'"'"'}"
  if (cd "$project" && bash -eo pipefail -c "$command") >"$tmp/out/$name" 2>&1 </dev/null; then
    rm "$tmp/out/$name"
  fi
' _ {}
failed=()
for output in "$tmp/out"/*; do
  [[ -e "$output" ]] || continue
  failed+=("$(basename "$output")")
  echo "--- $(basename "$output") in the fixture adopted project:" >&2
  tail -n 40 "$output" >&2
done
[[ "${#failed[@]}" -eq 0 ]] || fail "self-tests failed in an adopted project: ${failed[*]}"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the self-tests changed the fixture project: $(git -C "$project" status --porcelain)"

echo "adopted project tests passed ($(wc -l <"$tmp/checks") self-tests)"
