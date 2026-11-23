#!/usr/bin/env bash

set -euo pipefail

# The self-tests run under 'set -o pipefail' and pipe no output into a quiet
# grep ('-q', '--quiet', '--silent'). Such a grep exits at its first match and
# closes the pipe; a producer still writing then fails on the broken pipe, and
# with pipefail the assertion fails although the line was found, depending on
# timing (Issue 456). The safe form reads the output first:
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

# The tests of the template have none.
tests=("$source_root"/tests/*.sh)
[[ -e "${tests[0]}" ]] || fail "no test file tests/*.sh exists"
found="$(pipe_grep_quiet_lines "${tests[@]}")"
[[ -z "$found" ]] || fail "a test pipes into a quiet grep, use grep -q ... <<<\"\$(producer)\" instead:
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
