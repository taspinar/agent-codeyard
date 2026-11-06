#!/usr/bin/env bash

set -euo pipefail

# The self-tests need nothing of the repository they run in but the
# template's own files: every check of scripts/verify-workflow.conf passes in
# a fixture adopted project that has the state of a real one. The project
# keeps its own CI and excludes it from the template's files, starts its
# features from 'develop', has recorded its baseline, has its own ADRs and
# an ignore rule that hides the workflow's JSON files (un-ignored again, as
# the adoption does), and has no README.md or LICENSE.

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
printf '# 0001. Store orders in PostgreSQL\n\nStatus: Accepted\n\nThe project keeps its orders in PostgreSQL.\n' \
  >"$project/docs/decisions/0001-store-orders-in-postgresql.md"
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
    grep -v '^pass: budget-seconds$'
} >"$project/.agents/verification-baseline"
[[ -s "$project/.agents/verification-baseline" ]] || fail "the fixture has no baseline"
git -C "$project" add -A
git -C "$project" -c user.name=Owner -c user.email=owner@example.com commit -qm "The adopted project"
git -C "$project" branch develop
git -C "$project" switch -q develop
git init -q --bare -b main "$tmp/project-remote.git"
git -C "$project" remote add origin "$tmp/project-remote.git"
git -C "$project" push -q origin main develop
for path in README.md LICENSE; do
  [[ ! -e "$project/$path" ]] || fail "the fixture has a $path"
done

# Every self-test, run from the fixture as ./scripts/verify.sh runs it, four
# at a time.
mkdir -p "$tmp/out"
sed -nE 's/^([a-z0-9-]+)( \[[^]]*\])?( partition [^:]+)?: (.*)$/\1\t\4/p' "$project/scripts/verify-workflow.conf" |
  grep -Ev '^(paths|budget-seconds)\b' | grep -Fv "$self" >"$tmp/checks" || true
[[ "$(wc -l <"$tmp/checks")" -gt 1 ]] || fail "no self-tests found in scripts/verify-workflow.conf"
export project tmp
tr '\n' '\0' <"$tmp/checks" | xargs -0 -P 4 -I{} bash -c '
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
