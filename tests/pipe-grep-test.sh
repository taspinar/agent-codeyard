#!/usr/bin/env bash

set -euo pipefail

# The self-tests and the workflow scripts (Issue 509) run under
# 'set -o pipefail' and pipe no output into a quiet grep ('-q', '--quiet',
# '--silent'). Such a grep exits at its first match and closes the pipe; a
# producer still writing then fails on the broken pipe, and with pipefail the
# assertion fails although the line was found, depending on timing (Issue
# 456). The safe form reads the output first:
# grep -q <pattern> <<<"$(<producer>)". Redirecting the output of grep to
# /dev/null instead of -q is not safe either: GNU grep and ugrep then also stop
# at the first match.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pipe-grep-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "pipe-grep test failed: $*" >&2
  exit 1
}

# quiet_grep_after_pipe <text>: succeeds when <text> pipes into a grep whose
# options, before its first operand or '--', include -q, --quiet, or --silent.
# '||' is no pipe.
quiet_grep_after_pipe() {
  local rest="$1"
  local word
  local -a words

  while [[ "$rest" =~ (^|[^|])\|[[:space:]]*grep[[:space:]]+(.*)$ ]]; do
    rest="${BASH_REMATCH[2]}"
    read -ra words <<<"$rest"
    for word in "${words[@]}"; do
      [[ "$word" == "--" ]] && break
      if [[ "$word" =~ ^-[A-Za-z0-9]*q || "$word" == "--quiet" || "$word" == "--silent" ]]; then
        return 0
      fi
      [[ "$word" == -* || "$word" =~ ^[0-9]+$ ]] || break
    done
  done
  return 1
}

# pipe_grep_quiet_lines <file...>: prints '<file>:<line>: <text>' for every
# command that pipes into a quiet grep. A line that ends in '|' continues on
# the next one; comment lines are skipped.
pipe_grep_quiet_lines() {
  local file line joined start number

  for file in "$@"; do
    number=0
    joined=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      number=$((number + 1))
      [[ -n "$joined" ]] || start="$number"
      joined+="$line"
      if [[ ! "$line" =~ ^[[:space:]]*# && "$line" =~ (^|[^|])\|[[:space:]]*$ ]]; then
        joined+=" "
        continue
      fi
      if [[ ! "$joined" =~ ^[[:space:]]*# ]] && quiet_grep_after_pipe "$joined"; then
        printf '%s:%s: %s\n' "$file" "$start" "$joined"
      fi
      joined=""
    done <"$file"
  done
}

# The tests of the workflow have none: the files tests/*.sh that
# scripts/verify-workflow.conf names, its self-tests and the helpers they
# source. A project's own test files are not the workflow's: they are its
# own checks, run as it chooses, and the rule is not one of the project
# (Issue 460). In the template, every tests/*.sh is a test of the workflow,
# also one that runs by hand only, such as tests/agent-sandbox-test.sh (Issue
# 522), so the check reads every one there.
tests=()
while IFS= read -r path; do
  [[ -f "$source_root/$path" ]] && tests+=("$source_root/$path")
done < <(grep -Ev '^[[:space:]]*#' "$source_root/scripts/verify-workflow.conf" | grep -oE '(^|[ ./])tests/[A-Za-z0-9_.-]+\.sh' |
  sed -E 's#^[ ./]*##' | LC_ALL=C sort -u)
[[ "${#tests[@]}" -gt 1 ]] || fail "scripts/verify-workflow.conf names no test file tests/*.sh"
if template_repository "$source_root"; then
  tests=("$source_root"/tests/*.sh)
fi
found="$(pipe_grep_quiet_lines "${tests[@]}")"
[[ -z "$found" ]] || fail "a test pipes into a quiet grep, use grep -q ... <<<\"\$(producer)\" instead:
$found"

# workflow_scripts <root>: prints the workflow scripts of <root>, every *.sh
# under scripts/ that the 'paths:' entry of scripts/verify-workflow.conf does
# not exclude with ':(exclude)<path>' (a file or a directory). The scripts run
# under pipefail as well, and there a wrong result is a wrong decision of the
# workflow, not only a red check (Issue 509). A project excludes its own
# scripts there, and they follow its own rules.
workflow_scripts() {
  local root="$1"
  local path excluded
  local -a exclusions=()

  read -ra exclusions <<<"$(sed -nE 's/^paths:[[:space:]]*//p' "$root/scripts/verify-workflow.conf")"
  while IFS= read -r path; do
    path="${path#"$root"/}"
    for excluded in "${exclusions[@]}"; do
      [[ "$excluded" == ":(exclude)"* ]] || continue
      excluded="${excluded#:(exclude)}"
      excluded="${excluded%/}"
      [[ "$path" == "$excluded" || "$path" == "$excluded"/* ]] && continue 2
    done
    printf '%s\n' "$root/$path"
  done < <(find "$root/scripts" -type f -name '*.sh' | LC_ALL=C sort)
}

scripts=()
while IFS= read -r path; do
  scripts+=("$path")
done < <(workflow_scripts "$source_root")
[[ "${#scripts[@]}" -gt 1 ]] || fail "no workflow script found under scripts/"
found="$(pipe_grep_quiet_lines "${scripts[@]}")"
[[ -z "$found" ]] || fail "a workflow script pipes into a quiet grep, use grep -q ... <<<\"\$(producer)\" instead:
$found"

# Seeded cases: each unsafe form is found, each safe one is not. The pipe is
# written as $bar so that this file does not hold the form it looks for.
bar='|'
cat >"$tmp/unsafe.sh" <<EOF
producer $bar grep -Fqx "line" || fail "one line"
if producer $bar grep -q util-linux; then :; fi
  producer $bar
    grep -Fq "two lines" || fail "two lines"
producer $bar grep -E -q "separate option" || fail "separate option"
producer $bar grep --quiet "long option" || fail "long option"
producer $bar grep -A 1 -q "after an option argument" || fail "after an option argument"
first $bar grep -F "x" $bar grep -Fq "second grep" || fail "second grep"
x="\$(producer $bar grep -q "substitution")"
EOF
[[ "$(pipe_grep_quiet_lines "$tmp/unsafe.sh" | cut -d: -f2 | paste -sd,)" == "1,2,3,5,6,7,8,9" ]] ||
  fail "the check did not find every seeded unsafe form: $(pipe_grep_quiet_lines "$tmp/unsafe.sh")"

cat >"$tmp/safe.sh" <<EOF
grep -Fqx "line" <<<"\$(producer)" || fail "here-string"
grep -Fq "x" "\$file" ${bar}${bar} grep -Fq "y" "\$file" || fail "or"
# producer $bar grep -q "a comment"
[[ "\$(producer $bar grep -c x)" -eq 1 ]] || fail "count"
producer $bar grep -F -- "-q" || fail "operand after --"
grep -Fq -- "- none" <<<"\$(message $bar grep -A1 -Fx "Manual steps:")" || fail "quiet grep outside the pipe"
EOF
found="$(pipe_grep_quiet_lines "$tmp/safe.sh")"
[[ -z "$found" ]] || fail "the check reported a safe form: $found"

# A new unsafe line in a test file fails the check of the test files.
cp "${tests[0]}" "$tmp/seeded-test.sh"
printf 'producer %s grep -Fq "seeded" || fail "seeded"\n' "$bar" >>"$tmp/seeded-test.sh"
[[ "$(pipe_grep_quiet_lines "$tmp/seeded-test.sh")" == "$tmp/seeded-test.sh:$(wc -l <"$tmp/seeded-test.sh"):"* ]] ||
  fail "a seeded unsafe line in a test file was not found"

# The workflow scripts are every *.sh under scripts/, also in scripts/lib/,
# less the ones that 'paths:' excludes, a file or a directory.
mkdir -p "$tmp/project/scripts/lib" "$tmp/project/scripts/own"
printf 'paths: scripts .agents/prompts :(exclude)scripts/verify.conf :(exclude)scripts/own.sh :(exclude)scripts/own/\n' \
  >"$tmp/project/scripts/verify-workflow.conf"
for path in clean.sh lib/seeded.sh own.sh own/tool.sh; do
  printf 'grep -Fqx "line" <<<"$(producer)"\n' >"$tmp/project/scripts/$path"
done
for path in lib/seeded.sh own.sh own/tool.sh; do
  printf 'producer %s grep -Fqx "seeded" || fail "seeded"\n' "$bar" >>"$tmp/project/scripts/$path"
done
[[ "$(workflow_scripts "$tmp/project" | paste -sd, -)" == "$tmp/project/scripts/clean.sh,$tmp/project/scripts/lib/seeded.sh" ]] ||
  fail "the workflow scripts are not every script that paths: does not exclude: $(workflow_scripts "$tmp/project" | paste -sd, -)"
mapfile -t fixture_scripts < <(workflow_scripts "$tmp/project")
[[ "$(pipe_grep_quiet_lines "${fixture_scripts[@]}")" == "$tmp/project/scripts/lib/seeded.sh:2: "* ]] ||
  fail "a seeded unsafe line in a workflow script was not found, or one in an excluded script was: $(pipe_grep_quiet_lines "${fixture_scripts[@]}")"

# The check itself fails on a workflow script with such a pipe: a copy of
# this test in a copy of the scripts and the tests, with one unsafe line
# added to scripts/lib/github.sh. The copy skips this part.
if [[ -z "${PIPE_GREP_SEEDED_COPY:-}" ]]; then
  mkdir -p "$tmp/copy"
  cp -R "$source_root/scripts" "$source_root/tests" "$tmp/copy/"
  printf 'producer %s grep -Fq "seeded" || true\n' "$bar" >>"$tmp/copy/scripts/lib/github.sh"
  if output="$(PIPE_GREP_SEEDED_COPY=1 "$tmp/copy/tests/pipe-grep-test.sh" 2>&1)"; then
    fail "the check passed with an unsafe line in scripts/lib/github.sh: $output"
  fi
  grep -Fq "a workflow script pipes into a quiet grep" <<<"$output" ||
    fail "the check failed for another reason than the seeded line: $output"
  grep -Fq "$tmp/copy/scripts/lib/github.sh:" <<<"$output" ||
    fail "the check did not name the seeded file: $output"
fi

# The reproduction: a producer that writes more than a pipe buffer after the
# matching line. The old form fails under pipefail although the line is
# there; the new form passes.
producer() {
  printf 'match\n'
  head -c 1048576 /dev/zero | tr '\0' 'x'
  printf '\n'
}
export -f producer
if bash -c "set -euo pipefail; producer $bar grep -Fqx match"; then
  fail "the old form passed: the reproduction does not reproduce the broken pipe"
fi
bash -c 'set -euo pipefail; grep -Fqx match <<<"$(producer)"' || fail "the new form failed on a matching line"
if bash -c 'set -euo pipefail; grep -Fqx missing <<<"$(producer)"'; then fail "the new form passed without a matching line"; fi

echo "pipe-grep tests passed (${#tests[@]} test files)"
