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
git -C "$source_root" ls-files -co --exclude-standard -z | copy_files "$source_root" "$copy"
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

# The cases run in two batches, one run of the check each (Issue 486): every
# run builds the fixture and scans every self-test, and the scan is most of
# its cost, while the check reports every fault it finds before it fails.
# Each case adds a self-test, and the scripts it runs, of names of its own,
# so that no case reads another's files. The faults share one run, which
# must fail and report each of them on a line of its own and nothing else;
# the cases that pass share another with the template as it is, which must
# pass.
faults=()
passes=()

# expect_fault <description> <message>: the run of the faults says
# <message>, a line of its report from its start ('<name> reads ...').
expect_fault() {
  faults+=("$1"$'\t'"adopted project test: $2")
}

# expect_pass <description>: the run of the cases that pass holds this case.
expect_pass() {
  passes+=("$1")
}

# The faults.

# A self-test that reads a varied file and is not on the list.
add_test reader 'cat "$source_root/.agents/agents.conf"'
expect_fault "a test that reads a varied file" "reader reads what the fixture varies (.agents/agents.conf) and is not in fixture_tests"
add_test reader-glob 'cat "$source_root"/docs/decisions/*.md'
expect_fault "a test that reads a glob over varied files" "reader-glob reads what the fixture varies (docs/decisions/*.md)"
add_test reader-directory 'ls "${source_root}/.github"'
expect_fault "a test that reads a directory above a varied file" "reader-directory reads what the fixture varies (.github)"
add_test reader-repository 'template_repository "$source_root" || true'
expect_fault "a test that passes the repository on" "reader-repository reads what the fixture varies (the repository)"
add_test reader-helper 'template_conf "$tmp/template.conf"'
expect_fault "a test that calls a helper whose result the fixture changes" "reader-helper reads what the fixture varies (template_conf)"
add_test reader-shared 'source "$source_root/tests/lib-reader.sh"'
printf 'grep -c . "$source_root/AGENTS.md"\n' >"$copy/tests/lib-reader.sh"
expect_fault "a test whose shared part reads a varied file" "reader-shared reads what the fixture varies (AGENTS.md)"
add_test reader-git 'root="$(git rev-parse --show-toplevel)"
cat "$root/docs/PROJECT_REQUIREMENTS.md"'
expect_fault "a test that finds its root with Git" "reader-git reads what the fixture varies (docs/PROJECT_REQUIREMENTS.md)"

# A self-test that runs a script of the repository that reads a varied file:
# directly, through a variable and an interpreter, or through a script and a
# shared part of the scripts that one runs.
add_test reader-script '"$source_root/scripts/check-risk.sh" --help'
expect_fault "a test that runs a script that reads the repository" "reader-script reads what the fixture varies (scripts/check-risk.sh: the repository)"
add_script variable-reader 'root="$(git rev-parse --show-toplevel)"
cat "$root/.agents/agents.conf"'
add_test reader-variable 'script="$source_root/scripts/variable-reader.sh"
out="$(PATH="$PATH" "$BASH" "$script")"'
expect_fault "a test that runs a script through a variable" "reader-variable reads what the fixture varies (scripts/variable-reader.sh: .agents/agents.conf)"
add_script reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/inner.sh"'
add_script inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/inner.sh"'
printf 'cat "$script_dir/../AGENTS.md"\n' >"$copy/scripts/lib/inner.sh"
add_test reader-chain 'bash "$source_root/scripts/reader.sh"'
expect_fault "a test that runs a script that runs one that reads a varied file" "reader-chain reads what the fixture varies (scripts/reader.sh: scripts/inner.sh: AGENTS.md)"
# The same chain, its path normalized: through ./ and a dot directory, and
# never with a leading slash (checked on its line after the run); reading a
# file the fixture keeps, it passes (among the cases that pass).
add_script dot-reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/dot-inner.sh"'
add_script dot-inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/dot-inner.sh"'
printf 'cat "$script_dir/./../.agents/../AGENTS.md"\n' >"$copy/scripts/lib/dot-inner.sh"
add_test reader-dot-chain 'bash "$source_root/scripts/dot-reader.sh"'
expect_fault "a script chain that reads a varied file through ./ and .." "reader-dot-chain reads what the fixture varies (scripts/dot-reader.sh: scripts/dot-inner.sh: AGENTS.md)"

# A self-test starts in the root of the repository: a relative path it reads
# or runs there reads the repository, directly, in a function it calls, after
# a cd back to the root, or in a script it runs that way.
add_test reader-relative 'cat ./AGENTS.md'
expect_fault "a test that reads a varied file by a relative path" "reader-relative reads what the fixture varies (AGENTS.md)"
add_test reader-relative-grep 'grep -c . .agents/agents.conf >/dev/null'
expect_fault "a test that greps a varied file by a relative path" "reader-relative-grep reads what the fixture varies (.agents/agents.conf)"
add_test reader-function 'conf() { cat .agents/agents.conf; }
out="$(conf)"'
expect_fault "a test whose function reads a varied file by a relative path" "reader-function reads what the fixture varies (.agents/agents.conf)"
add_test reader-cd-root 'out="$(cd "$source_root" && cat docs/decisions/*.md)"'
expect_fault "a test that reads a relative path after a cd to its root" "reader-cd-root reads what the fixture varies (the repository, docs/decisions/*.md)"
add_script relative-reader 'cat .agents/agents.conf'
add_test reader-relative-script './scripts/relative-reader.sh'
expect_fault "a test that runs a script by a relative path" "reader-relative-script reads what the fixture varies (scripts/relative-reader.sh: .agents/agents.conf)"
# A cd that stays in the root or in the repository does not hide a read
# (review-06 M1): 'cd .' and its like, a directory of the repository and a
# path back from it, a return with 'cd -' or popd, and '.' as the repository.
add_test reader-cd-dot 'cd . || exit 1
cat .agents/agents.conf'
expect_fault "a test that reads a relative path after cd ." "reader-cd-dot reads what the fixture varies (.agents/agents.conf) and is not in fixture_tests"
add_test reader-cd-stays 'cd ./ && cat AGENTS.md
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
  "reader-cd-stays reads what the fixture varies (AGENTS.md, docs/PROJECT_REQUIREMENTS.md, .agents/policies/risk.conf, .github/workflows/ci.yml, .agents/template.conf, .agents/agents.conf, docs/decisions/*.md)"
add_test reader-cd-up 'cd docs || exit 1
ls ..'
expect_fault "a test that lists the root from a directory of the repository" "reader-cd-up reads what the fixture varies (the repository)"
add_test reader-grep-context 'grep -C 3 -c x AGENTS.md'
expect_fault "a test that greps a varied file with lines of context" "reader-grep-context reads what the fixture varies (AGENTS.md)"
add_test reader-dot 'cat "$source_root/./AGENTS.md"'
expect_fault "a test that reads a varied file through ./" "reader-dot reads what the fixture varies (AGENTS.md)"
add_test reader-dot-dot 'cat "$source_root/.agents/../AGENTS.md"'
expect_fault "a test that reads a varied file through a dot directory and .." "reader-dot-dot reads what the fixture varies (AGENTS.md)"

# The entries of the list.
list "no-such-test: something"
expect_fault "an entry that is not a self-test" "no-such-test of fixture_tests is not a self-test of scripts/verify-workflow.conf"
list "adoption: the adoption"
expect_fault "a framework-only entry" "adoption of fixture_tests is framework-only"
list "risk: again"
expect_fault "an entry listed twice" "risk is listed twice in fixture_tests"
list "doctor"
expect_fault "an entry without what it reads" "the entry 'doctor' of fixture_tests does not say what the self-test reads"

if check_list; then fail "the faults: the check passed: $(cat "$tmp/out")"; fi
grep -Fq "the list of self-tests of the fixture does not agree with what they read" "$tmp/out" ||
  fail "the faults: the check did not fail on the list: $(cat "$tmp/out")"
for fault in "${faults[@]}"; do
  grep -Fq -- "${fault#*$'\t'}" "$tmp/out" || fail "${fault%%$'\t'*}: the check did not say '${fault#*$'\t'}': $(cat "$tmp/out")"
done
if grep -Fq "/AGENTS.md" <<<"$(grep -F "adopted project test: reader-dot-chain " "$tmp/out" || true)"; then
  fail "a script chain through ./ and ..: a path with a leading slash: $(cat "$tmp/out")"
fi
# One line for each fault, and none for anything else, the template's own
# self-tests too.
for fault in "${faults[@]}"; do printf '%s\n' "${fault#*$'\t'}"; done >"$tmp/expected"
unexpected="$(grep '^adopted project test: ' "$tmp/out" | grep -vF -f "$tmp/expected" || true)"
[[ -z "$unexpected" ]] || fail "the faults: the check reported what no case adds: $unexpected"
reported="$(grep -c '^adopted project test: ' "$tmp/out" || true)"
[[ "$reported" -eq "${#faults[@]}" ]] ||
  fail "the faults: the check reported $reported faults, not the ${#faults[@]} of the cases: $(cat "$tmp/out")"
reset

# The cases that pass, with the template as it is.
expect_pass "the template as it is"

# The chain of scripts above, reading a file the fixture keeps.
add_script reader 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
"$script_dir/inner.sh"'
add_script inner 'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/inner.sh"'
printf 'cat "$script_dir/../scripts/lib/risk.sh"\n' >"$copy/scripts/lib/inner.sh"
add_test reader-chain 'bash "$source_root/scripts/reader.sh"'
expect_pass "a test that runs a script that runs one that reads only what the fixture keeps"

# Where the directory is no longer the root, or where the path is data, it
# reads nothing of the repository.
add_test reader-elsewhere '(cd "$tmp" && cat AGENTS.md ./scripts/x.sh)
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
add_test reader-cd-away 'cd "$tmp" || exit 1
cat .agents/agents.conf
./scripts/check-risk.sh'
expect_pass "a test that reads relative paths only after a cd away from the root"
# The same words where the directory is not the repository's: in a
# directory that is not varied, above the root, and after a cd away.
add_test reader-outside 'cut -d . -f 1 "$tmp/out"
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

# On the list, or reading nothing that the fixture varies, it passes.
add_test reader 'cat "$source_root/.agents/agents.conf"'
list "reader: .agents/agents.conf, the project's agents"
expect_pass "a listed test that reads a varied file"
add_test reader-kept 'cat "$source_root/scripts/lib/risk.sh" "$source_root"/.agents/prompts/*.md
workflow_gitignore "$tmp/ignore"
# cat "$source_root/AGENTS.md"
cp "$source_root/scripts/check-risk.sh" "$tmp/"
script="$source_root/scripts/check-risk.sh"
cp "$script" "$tmp/again.sh"
"$source_root/scripts/kept-reader.sh"'
add_script kept-reader 'root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cat "$root/scripts/lib/risk.sh"'
expect_pass "a test that reads only what the fixture keeps"
add_test reader-framework 'cat "$source_root/.agents/agents.conf"' framework
expect_pass "a framework-only test that reads a varied file"

check_list || fail "the cases that pass ($(printf '%s; ' "${passes[@]}")): the check failed: $(cat "$tmp/out")"
grep -Fq "adopted project list agrees with the self-tests" "$tmp/out" ||
  fail "the cases that pass: the check did not say it agrees: $(cat "$tmp/out")"
reset

# The options.
if "$copy/tests/adopted-project-test.sh" --other >"$tmp/out" 2>&1; then fail "an unknown option was accepted"; fi
grep -Fq "Usage:" "$tmp/out" || fail "an unknown option does not print the usage: $(cat "$tmp/out")"
if "$copy/tests/adopted-project-test.sh" --all --check-list >"$tmp/out" 2>&1; then fail "two options were accepted"; fi

echo "adopted project list tests passed"
