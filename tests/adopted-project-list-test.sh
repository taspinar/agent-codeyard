#!/usr/bin/env bash

set -euo pipefail

# The list of tests/adopted-project-test.sh (fixture_tests), the self-tests
# that the fixture adopted project runs (Issue 478): its check, run with
# --check-list in a copy of the repository, passes on the template as it is
# and fails on each fault, a self-test that reads a file the fixture varies
# and is not on the list (by its path, a directory or glob above it, the
# repository as a whole, a shared part it sources, a script of the
# repository it runs that reads one, a relative path where its working
# directory is still the root or a directory of the repository, or a helper of tests/lib-fakes.sh whose
# result the fixture changes), and an entry that is
# not a self-test, is framework-only, is listed twice, or does not say what
# the test reads. A self-test that reads nothing the fixture varies, or that
# is framework-only, needs no entry.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/adopted-project-list-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "adopted project list test failed: $*" >&2
  exit 1
}

# A copy of the repository's files, as a repository of its own.
copy="$tmp/copy"
mkdir -p "$copy"
(cd "$source_root" && git ls-files -co --exclude-standard -z) |
  while IFS= read -r -d '' path; do
    [[ -f "$source_root/$path" ]] && printf '%s\0' "$path"
  done |
  (cd "$source_root" && tar --null -T - -cf -) | tar -C "$copy" -xf -
git -C "$copy" init -q -b main
git -C "$copy" add -A
git -C "$copy" -c user.name=Test -c user.email=test@example.com commit -qm "The copy"

# check_list: runs the check of the list in the copy, its output in $tmp/out.
check_list() {
  "$copy/tests/adopted-project-test.sh" --check-list >"$tmp/out" 2>&1
}

# reset: the copy as committed.
reset() {
  git -C "$copy" checkout -q -- .
  git -C "$copy" clean -qfd
}

# add_test <name> <body> [framework]: a self-test tests/<name>-test.sh with
# <body> after its root, and its check in scripts/verify-workflow.conf.
add_test() {
  printf '#!/usr/bin/env bash\nsource_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"\nsource "$source_root/tests/lib-fakes.sh"\n%s\n' \
    "$2" >"$copy/tests/$1-test.sh"
  chmod +x "$copy/tests/$1-test.sh"
  printf '%s [self-tests-1]%s: ./tests/%s-test.sh\n' "$1" "${3:+ framework}" "$1" >>"$copy/scripts/verify-workflow.conf"
}

# add_script <name> <body>: a script scripts/<name>.sh with <body>.
add_script() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$copy/scripts/$1.sh"
  chmod +x "$copy/scripts/$1.sh"
}

# list <entry>: adds <entry> to fixture_tests of the copy.
list() {
  ENTRY="$1" awk '{ print } /^fixture_tests=\($/ { print "  \"" ENVIRON["ENTRY"] "\"" }' \
    "$copy/tests/adopted-project-test.sh" >"$tmp/list.sh"
  cat "$tmp/list.sh" >"$copy/tests/adopted-project-test.sh"
  grep -Fq "  \"$1\"" "$copy/tests/adopted-project-test.sh" || fail "the entry '$1' was not added to the copy's list"
}

# expect_pass <description>
expect_pass() {
  check_list || fail "$1: the check failed: $(cat "$tmp/out")"
  grep -Fq "adopted project list agrees with the self-tests" "$tmp/out" || fail "$1: the check did not say it agrees: $(cat "$tmp/out")"
  reset
}

# expect_fault <description> <message>: the check fails and says <message>.
expect_fault() {
  if check_list; then fail "$1: the check passed: $(cat "$tmp/out")"; fi
  grep -Fq -- "$2" "$tmp/out" || fail "$1: the check did not say '$2': $(cat "$tmp/out")"
  reset
}

expect_pass "the template as it is"

# A self-test that reads a varied file and is not on the list.
add_test reader 'cat "$source_root/.agents/agents.conf"'
expect_fault "a test that reads a varied file" "reader reads what the fixture varies (.agents/agents.conf) and is not in fixture_tests"
add_test reader 'cat "$source_root"/docs/decisions/*.md'
expect_fault "a test that reads a glob over varied files" "reader reads what the fixture varies (docs/decisions/*.md)"
add_test reader 'ls "${source_root}/.github"'
expect_fault "a test that reads a directory above a varied file" "reader reads what the fixture varies (.github)"
add_test reader 'template_repository "$source_root" || true'
expect_fault "a test that passes the repository on" "reader reads what the fixture varies (the repository)"
add_test reader 'template_conf "$tmp/template.conf"'
expect_fault "a test that calls a helper whose result the fixture changes" "reader reads what the fixture varies (template_conf)"
add_test reader 'source "$source_root/tests/lib-reader.sh"'
printf 'grep -c . "$source_root/AGENTS.md"\n' >"$copy/tests/lib-reader.sh"
expect_fault "a test whose shared part reads a varied file" "reader reads what the fixture varies (AGENTS.md)"
add_test reader 'root="$(git rev-parse --show-toplevel)"
cat "$root/docs/PROJECT_REQUIREMENTS.md"'
expect_fault "a test that finds its root with Git" "reader reads what the fixture varies (docs/PROJECT_REQUIREMENTS.md)"

# A self-test that runs a script of the repository that reads a varied file:
# directly, through a variable and an interpreter, or through a script and a
# shared part of the scripts that one runs.
add_test reader '"$source_root/scripts/check-risk.sh" --help'
expect_fault "a test that runs a script that reads the repository" "reader reads what the fixture varies (scripts/check-risk.sh: the repository)"
add_script reader 'root="$(git rev-parse --show-toplevel)"
cat "$root/.agents/agents.conf"'
add_test reader 'script="$source_root/scripts/reader.sh"
out="$(PATH="$PATH" "$BASH" "$script")"'
expect_fault "a test that runs a script through a variable" "reader reads what the fixture varies (scripts/reader.sh: .agents/agents.conf)"
add_script reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/inner.sh"'
add_script inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/inner.sh"'
printf 'cat "$script_dir/../AGENTS.md"\n' >"$copy/scripts/lib/inner.sh"
add_test reader 'bash "$source_root/scripts/reader.sh"'
expect_fault "a test that runs a script that runs one that reads a varied file" "reader reads what the fixture varies (scripts/reader.sh: scripts/inner.sh: AGENTS.md)"
# The same chain, its path normalized: through ./ and a dot directory, and
# never with a leading slash; reading a file the fixture keeps, it passes.
add_script reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/inner.sh"'
add_script inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/inner.sh"'
printf 'cat "$script_dir/./../.agents/../AGENTS.md"\n' >"$copy/scripts/lib/inner.sh"
add_test reader 'bash "$source_root/scripts/reader.sh"'
if check_list; then fail "a script chain that reads a varied file through ./ and ..: the check passed: $(cat "$tmp/out")"; fi
grep -Fq "(scripts/reader.sh: scripts/inner.sh: AGENTS.md)" "$tmp/out" || fail "a script chain through ./ and ..: the check did not name AGENTS.md: $(cat "$tmp/out")"
if grep -Fq "/AGENTS.md" "$tmp/out"; then fail "a script chain through ./ and ..: a path with a leading slash: $(cat "$tmp/out")"; fi
reset
add_script reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/inner.sh"'
add_script inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/inner.sh"'
printf 'cat "$script_dir/../scripts/lib/risk.sh"\n' >"$copy/scripts/lib/inner.sh"
add_test reader 'bash "$source_root/scripts/reader.sh"'
expect_pass "a test that runs a script that runs one that reads only what the fixture keeps"

# A self-test starts in the root of the repository: a relative path it reads
# or runs there reads the repository, directly, in a function it calls, after
# a cd back to the root, or in a script it runs that way.
add_test reader 'cat ./AGENTS.md'
expect_fault "a test that reads a varied file by a relative path" "reader reads what the fixture varies (AGENTS.md)"
add_test reader 'grep -c . .agents/agents.conf >/dev/null'
expect_fault "a test that greps a varied file by a relative path" "reader reads what the fixture varies (.agents/agents.conf)"
add_test reader 'conf() { cat .agents/agents.conf; }
out="$(conf)"'
expect_fault "a test whose function reads a varied file by a relative path" "reader reads what the fixture varies (.agents/agents.conf)"
add_test reader 'out="$(cd "$source_root" && cat docs/decisions/*.md)"'
expect_fault "a test that reads a relative path after a cd to its root" "reader reads what the fixture varies (the repository, docs/decisions/*.md)"
add_script reader 'cat .agents/agents.conf'
add_test reader './scripts/reader.sh'
expect_fault "a test that runs a script by a relative path" "reader reads what the fixture varies (scripts/reader.sh: .agents/agents.conf)"
# Where the directory is no longer the root, or where the path is data, it
# reads nothing of the repository.
add_test reader '(cd "$tmp" && cat AGENTS.md ./scripts/x.sh)
git -C "$tmp" add AGENTS.md
grep -Fq "AGENTS.md" "$tmp/out"
paths=(AGENTS.md .agents/agents.conf)
case "$1" in AGENTS.md) ;; esac
cat <<EOF
cat AGENTS.md
EOF
never() { cat AGENTS.md; }
cd "$tmp"
cat AGENTS.md
./scripts/check-risk.sh'
expect_pass "a test that reads relative paths only where they are not the repository's"
add_test reader 'cd "$tmp" || exit 1
cat .agents/agents.conf
./scripts/check-risk.sh'
expect_pass "a test that reads relative paths only after a cd away from the root"
# A cd that stays in the root or in the repository does not hide a read
# (review-06 M1): 'cd .' and its like, a directory of the repository and a
# path back from it, a return with 'cd -' or popd, and '.' as the repository.
add_test reader 'cd . || exit 1
cat .agents/agents.conf'
expect_fault "a test that reads a relative path after cd ." "reader reads what the fixture varies (.agents/agents.conf) and is not in fixture_tests"
add_test reader 'cd ./ && cat AGENTS.md
cd -- "$PWD" && cat docs/PROJECT_REQUIREMENTS.md
cd "$(pwd)" && cat .agents/policies/risk.conf
(cd tests && cat ../.github/workflows/ci.yml)
git -C "$tmp" commit -qm "$(cat .agents/template.conf)"
pushd "$tmp" >/dev/null
popd >/dev/null
cat .agents/agents.conf
cd "$tmp" || exit 1
cd - >/dev/null
cat docs/decisions/*.md'
expect_fault "a test that reads relative paths after a cd that stays in the repository" \
  "reader reads what the fixture varies (AGENTS.md, docs/PROJECT_REQUIREMENTS.md, .agents/policies/risk.conf, .github/workflows/ci.yml, .agents/template.conf, .agents/agents.conf, docs/decisions/*.md)"
add_test reader 'cd docs || exit 1
ls ..'
expect_fault "a test that lists the root from a directory of the repository" "reader reads what the fixture varies (the repository)"
add_test reader 'grep -C 3 -c x AGENTS.md'
expect_fault "a test that greps a varied file with lines of context" "reader reads what the fixture varies (AGENTS.md)"
# The same words where the directory is not the repository's: in a
# directory that is not varied, above the root, and after a cd away.
add_test reader 'cut -d . -f 1 "$tmp/out"
sort -t . -k 2 "$tmp/out"
(cd scripts/lib && cat AGENTS.md ../risk.sh)
(cd .. && cat AGENTS.md)
cd "$tmp" || exit 1
cd .
cat AGENTS.md
cd "$PWD" && cat .agents/agents.conf
cd repo && cat AGENTS.md
ls .'
expect_pass "a test that stays out of the repository through cd . and its like"

add_test reader 'cat "$source_root/./AGENTS.md"'
expect_fault "a test that reads a varied file through ./" "reader reads what the fixture varies (AGENTS.md)"
add_test reader 'cat "$source_root/.agents/../AGENTS.md"'
expect_fault "a test that reads a varied file through a dot directory and .." "reader reads what the fixture varies (AGENTS.md)"
# On the list, or reading nothing that the fixture varies, it passes.
add_test reader 'cat "$source_root/.agents/agents.conf"'
list "reader: .agents/agents.conf, the project's agents"
expect_pass "a listed test that reads a varied file"
add_test reader 'cat "$source_root/scripts/lib/risk.sh" "$source_root"/.agents/prompts/*.md
workflow_gitignore "$tmp/ignore"
# cat "$source_root/AGENTS.md"
cp "$source_root/scripts/check-risk.sh" "$tmp/"
script="$source_root/scripts/check-risk.sh"
cp "$script" "$tmp/again.sh"
"$source_root/scripts/reader.sh"'
add_script reader 'root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cat "$root/scripts/lib/risk.sh"'
expect_pass "a test that reads only what the fixture keeps"
add_test reader 'cat "$source_root/.agents/agents.conf"' framework
expect_pass "a framework-only test that reads a varied file"

# The entries of the list.
list "no-such-test: something"
expect_fault "an entry that is not a self-test" "no-such-test of fixture_tests is not a self-test of scripts/verify-workflow.conf"
list "adoption: the adoption"
expect_fault "a framework-only entry" "adoption of fixture_tests is framework-only"
list "risk: again"
expect_fault "an entry listed twice" "risk is listed twice in fixture_tests"
list "doctor"
expect_fault "an entry without what it reads" "the entry 'doctor' of fixture_tests does not say what the self-test reads"

# The options.
if "$copy/tests/adopted-project-test.sh" --other >"$tmp/out" 2>&1; then fail "an unknown option was accepted"; fi
grep -Fq "Usage:" "$tmp/out" || fail "an unknown option does not print the usage: $(cat "$tmp/out")"
if "$copy/tests/adopted-project-test.sh" --all --check-list >"$tmp/out" 2>&1; then fail "two options were accepted"; fi

echo "adopted project list tests passed"
