#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/lib/environment.sh: the preflight of verify.sh, with
# its two levels (general, and the workflow self-tests only when one is going
# to run), the environment status 78 and its ENVIRONMENT lines, and the
# isolated test toolchain that tests/lib-fakes.sh builds.
#
# A missing tool is made with a PATH of the test's own (intent c of the
# toolchain): links to the tools that stay, and none to the one that goes.
# HOMEBREW_PREFIX names a directory without brew, so that Homebrew's GNU
# directories do not stand in for the missing tool on macOS.

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/environment-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# bin_without <name> <tool>...: a directory with the tools of the toolchain
# and the few others verify.sh runs, without the named ones; prints it.
bin_without() {
  local bin="$tmp/$1"
  local tool
  local path

  shift
  mkdir -p "$bin"
  for path in "$TEST_TOOLCHAIN_BIN"/*; do
    tool="${path##*/}"
    [[ " $* " == *" $tool "* ]] || ln -s "$(readlink "$path")" "$bin/$tool"
  done
  for tool in awk grep find diff cmp xargs ps; do
    [[ " $* " == *" $tool "* ]] || ! path="$(command -v "$tool")" || ln -sf "$path" "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

# A sed with the '-i' of BSD sed, which takes the next argument for the
# suffix of a backup: 'sed -i <script> <file>' then fails, as on macOS.
# Everything else works as GNU sed does, so that only the preflight can tell.
no_gnu_sed="$(bin_without no-gnu-sed sed)"
cat >"$no_gnu_sed/sed" <<FAKE
#!$(readlink "$TEST_TOOLCHAIN_BIN/bash")
[[ "\${1:-}" != --version ]] || { echo "sed (BSD) 1.0"; exit 0; }
[[ "\${1:-}" != -i ]] || set -- "-i\${2:-}" "\${@:3}"
exec $(printf '%q' "$(readlink "$TEST_TOOLCHAIN_BIN/sed")") "\$@"
FAKE
chmod +x "$no_gnu_sed/sed"
# Tools that do what the scripts need of GNU sed, timeout and date without
# the name GNU in their --version, as the uutils coreutils of Ubuntu 26.04:
# the preflight checks the behaviour, so they pass.
uutils="$(bin_without uutils sed timeout date)"
for tool in sed timeout date; do
  cat >"$uutils/$tool" <<FAKE
#!$(readlink "$TEST_TOOLCHAIN_BIN/bash")
[[ "\${1:-}" != --version ]] || { echo "$tool (uutils coreutils) 0.2.2"; exit 0; }
exec $(printf '%q' "$(readlink "$TEST_TOOLCHAIN_BIN/$tool")") "\$@"
FAKE
  chmod +x "$uutils/$tool"
done
no_jq="$(bin_without no-jq jq)"
# A jq older than 1.6, the minimum of docs/development.md and doctor.sh:
# it says so, and otherwise works as the real one.
old_jq="$(bin_without old-jq jq)"
cat >"$old_jq/jq" <<FAKE
#!$(readlink "$TEST_TOOLCHAIN_BIN/bash")
[[ "\${1:-}" != --version ]] || { echo "jq-1.5"; exit 0; }
exec $(printf '%q' "$(readlink "$TEST_TOOLCHAIN_BIN/jq")") "\$@"
FAKE
chmod +x "$old_jq/jq"
# A jq whose version output names no version: it cannot be established as
# 1.6 or newer, so it is not supported either.
odd_jq="$(bin_without odd-jq jq)"
cat >"$odd_jq/jq" <<FAKE
#!$(readlink "$TEST_TOOLCHAIN_BIN/bash")
[[ "\${1:-}" != --version ]] || { echo "jq-custom-build"; exit 0; }
exec $(printf '%q' "$(readlink "$TEST_TOOLCHAIN_BIN/jq")") "\$@"
FAKE
chmod +x "$odd_jq/jq"

# project <label> [git]: a project with one check of its own and one
# self-test, each leaving a mark; with 'git', a repository on main with
# everything committed, so that no workflow file differs from the base.
project() {
  local project="$tmp/$1"

  mkdir -p "$project/scripts/lib" "$project/tests"
  cp "$source_root/scripts/verify.sh" "$project/scripts/"
  cp "$source_root/scripts/lib/bootstrap.sh" "$source_root/scripts/lib/environment.sh" "$project/scripts/lib/"
  [[ "${2:-}" != git ]] ||
    cp "$source_root/scripts/lib/fingerprint.sh" "$source_root/scripts/lib/verification.sh" "$project/scripts/lib/"
  printf 'own: touch ran-own\n' >"$project/scripts/verify.conf"
  printf 'paths: tests\n\nself [self-tests]: touch ran-self\n' >"$project/scripts/verify-workflow.conf"
  printf 'echo test\n' >"$project/tests/sample-test.sh"
  if [[ "${2:-}" == git ]]; then
    printf 'ran-*\n*.log\n.agents/verification/\n' >"$project/.gitignore"
    git -C "$project" init -q -b main
    git -C "$project" add -A
    git -C "$project" -c user.name=Test -c user.email=test@example.com commit -qm "Project"
  fi
  printf '%s\n' "$project"
}

# verify <project> <path> [argument...]: runs verify.sh; sets 'status'.
verify() {
  local project="$1"
  local path="$2"

  shift 2
  status=0
  (cd "$project" && PATH="$path" HOMEBREW_PREFIX="$tmp/no-homebrew" RECORDS_DISABLED=1 ./scripts/verify.sh "$@") \
    >"$project/out.log" 2>&1 || status=$?
}

expect_environment() {
  local project="$1"
  local line="$2"

  [[ "$status" -eq 78 ]] || { cat "$project/out.log" >&2; fail "$(basename "$project"): exited with $status instead of 78"; }
  grep -Eq "^ENVIRONMENT  $line" "$project/out.log" ||
    fail "$(basename "$project"): no ENVIRONMENT line '$line': $(cat "$project/out.log")"
  grep -Fq "Verification not run: a prerequisite of this machine is missing" "$project/out.log" ||
    fail "$(basename "$project"): the stop was not explained: $(cat "$project/out.log")"
  [[ ! -e "$project/ran-own" && ! -e "$project/ran-self" ]] || fail "$(basename "$project"): a check ran although a prerequisite is missing"
}

# Everything there: both checks run and pass.
repo="$(project complete)"
verify "$repo" "$ISOLATED_PATH"
[[ "$status" -eq 0 ]] || { cat "$repo/out.log" >&2; fail "complete: the verification failed with $status"; }
[[ -e "$repo/ran-own" && -e "$repo/ran-self" ]] || fail "complete: a check did not run"
if grep -q '^ENVIRONMENT' "$repo/out.log"; then fail "complete: an ENVIRONMENT line was printed"; fi

# Without GNU sed, a run with the self-tests stops before any check, with
# status 78, the line, and the install command; also with --all.
repo="$(project no-sed)"
verify "$repo" "$no_gnu_sed"
expect_environment "$repo" "GNU sed for the workflow self-tests — .*(apt-get install sed|brew install gnu-sed)$"
verify "$repo" "$no_gnu_sed" --all
expect_environment "$repo" "GNU sed for the workflow self-tests"

# A missing prerequisite of the self-tests does not block a verification
# that runs none: --only of the project's group, and a run in which no
# workflow file differs from the base.
repo="$(project no-sed-only-own)"
verify "$repo" "$no_gnu_sed" --only default
[[ "$status" -eq 0 ]] || { cat "$repo/out.log" >&2; fail "no-sed-only-own: a run without self-tests failed with $status"; }
[[ -e "$repo/ran-own" && ! -e "$repo/ran-self" ]] || fail "no-sed-only-own: the wrong checks ran"
repo="$(project no-sed-unchanged git)"
verify "$repo" "$no_gnu_sed"
[[ "$status" -eq 0 ]] || { cat "$repo/out.log" >&2; fail "no-sed-unchanged: a run that skips the self-tests failed with $status"; }
grep -q '^SKIP  workflow self-tests' "$repo/out.log" || fail "no-sed-unchanged: the self-tests were not skipped: $(cat "$repo/out.log")"
[[ -e "$repo/ran-own" ]] || fail "no-sed-unchanged: the project's check did not run"

# A recorded pass that covered the self-tests is no evidence on a machine
# that cannot run them: --reuse checks their prerequisites before it accepts
# the pass, with --all and also when this run would skip the self-tests.
repo="$(project no-sed-reuse git)"
verify "$repo" "$ISOLATED_PATH" --all
[[ "$status" -eq 0 ]] || { cat "$repo/out.log" >&2; fail "no-sed-reuse: the first verification failed with $status"; }
grep -q '^workflow-tests: ran$' "$repo/.agents/verification/passed" ||
  fail "no-sed-reuse: no pass with the self-tests was recorded: $(cat "$repo/.agents/verification/passed" 2>/dev/null)"
rm -f "$repo/ran-own" "$repo/ran-self"
verify "$repo" "$ISOLATED_PATH" --reuse --all
[[ "$status" -eq 0 ]] && grep -q 'Verification already passed for this content' "$repo/out.log" ||
  { cat "$repo/out.log" >&2; fail "no-sed-reuse: the recorded pass was not reused on a complete machine"; }
for args in "--reuse --all" "--reuse"; do
  # shellcheck disable=SC2086 # the arguments are split on purpose
  verify "$repo" "$no_gnu_sed" $args
  expect_environment "$repo" "GNU sed for the workflow self-tests"
  if grep -q 'Verification already passed' "$repo/out.log"; then
    fail "no-sed-reuse ($args): the recorded pass was reused without the self-test prerequisites"
  fi
done

# A general prerequisite stops every run, also one without the self-tests.
repo="$(project no-jq)"
verify "$repo" "$no_jq" --only default
expect_environment "$repo" "jq — "
if grep -q '^ENVIRONMENT  .*for the workflow self-tests' "$repo/out.log"; then
  fail "no-jq: a run without self-tests checked their prerequisites: $(cat "$repo/out.log")"
fi
# With the self-tests, every missing prerequisite is named, each once.
verify "$repo" "$no_jq"
expect_environment "$repo" "jq — "
expect_environment "$repo" "jq 1\\.6 or newer for the workflow self-tests — "
[[ "$(grep -c '^ENVIRONMENT  ' "$repo/out.log")" -eq 2 ]] || fail "no-jq: not exactly one line per missing prerequisite: $(cat "$repo/out.log")"

# A jq older than 1.6 is a missing prerequisite too, at both levels.
repo="$(project old-jq)"
verify "$repo" "$old_jq" --only default
expect_environment "$repo" "jq 1\\.6 or newer \\(this is jq-1\\.5\\) — "
verify "$repo" "$old_jq"
expect_environment "$repo" "jq 1\\.6 or newer \\(this is jq-1\\.5\\) — "
expect_environment "$repo" "jq 1\\.6 or newer for the workflow self-tests — "
[[ "$(grep -c '^ENVIRONMENT  ' "$repo/out.log")" -eq 2 ]] || fail "old-jq: not exactly one line per unsupported prerequisite: $(cat "$repo/out.log")"
# A jq whose version cannot be read is unsupported too, at both levels.
repo="$(project odd-jq)"
verify "$repo" "$odd_jq" --only default
expect_environment "$repo" "jq 1\\.6 or newer \\(this is jq-custom-build\\) — "
verify "$repo" "$odd_jq"
expect_environment "$repo" "jq 1\\.6 or newer \\(this is jq-custom-build\\) — "
expect_environment "$repo" "jq 1\\.6 or newer for the workflow self-tests — "
[[ "$(grep -c '^ENVIRONMENT  ' "$repo/out.log")" -eq 2 ]] || fail "odd-jq: not exactly one line per unsupported prerequisite: $(cat "$repo/out.log")"
for version in "jq-1.6" "jq-1.7.1" "jq-1.7.1-dirty" "jq-2.0"; do
  environment_jq_supports "$version" || fail "jq version '$version' was rejected"
done
for version in "jq-1.5" "jq-1.4" "jq version 1.3" "jq-0.9" "jq-custom-build" "jq-master" ""; do
  if environment_jq_supports "$version"; then fail "jq version '$version' was accepted"; fi
done

# A failing check stays a failure of the code: status 1, no ENVIRONMENT line,
# also when it fails for a tool it lacks.
repo="$(project code-failure)"
printf 'own: touch ran-own\nlacks: not-a-tool-anywhere --version\nbroken: false\n' >"$repo/scripts/verify.conf"
verify "$repo" "$ISOLATED_PATH"
[[ "$status" -eq 1 ]] || { cat "$repo/out.log" >&2; fail "code-failure: a failing check ended with $status instead of 1"; }
if grep -q '^ENVIRONMENT' "$repo/out.log"; then fail "code-failure: a failing check was reported as an environment failure"; fi

# The toolchain: links to the selected tools only, built once per content
# and found again, and rebuilt when a cleaner removed a link.
for tool in bash sed timeout date jq git; do
  [[ -L "$TEST_TOOLCHAIN_BIN/$tool" ]] || fail "the toolchain has no $tool"
done
for tool in claude codex gh curl; do
  [[ ! -e "$TEST_TOOLCHAIN_BIN/$tool" ]] || fail "the toolchain links $tool, which it never may"
done
environment_passes "$TEST_TOOLCHAIN_BIN/sed" gnu-sed || fail "the toolchain's sed is not GNU sed"
"$TEST_TOOLCHAIN_BIN/bash" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' || fail "the toolchain's bash is older than 4"
again="$(environment_toolchain_build)"
[[ "$again" == "$TEST_TOOLCHAIN_BIN" ]] || fail "the toolchain was built again for the same tools: $again"
own="$(TMPDIR="$tmp" environment_toolchain_build)"
[[ "$own" == "$tmp"/codeyard-test-toolchain.*/bin ]] || fail "the toolchain was not built under TMPDIR: $own"
rm "$own/sed"
rebuilt="$(TMPDIR="$tmp" environment_toolchain_build)"
[[ -L "$rebuilt/sed" ]] || fail "a toolchain without one of its links was not rebuilt"
[[ "$(find "$tmp" -maxdepth 1 -name 'codeyard-test-toolchain.*' | wc -l)" -eq 1 ]] ||
  fail "building the toolchain left directories behind: $(ls "$tmp")"
# Without a required tool it cannot be built: the ENVIRONMENT line and a
# failure.
status=0
(PATH="$no_gnu_sed" HOMEBREW_PREFIX="$tmp/no-homebrew" TMPDIR="$tmp" environment_toolchain_build) >/dev/null 2>"$tmp/build.err" || status=$?
[[ "$status" -ne 0 ]] || fail "a toolchain without GNU sed was built"
grep -q '^ENVIRONMENT  GNU sed for the workflow self-tests' "$tmp/build.err" || fail "a toolchain without GNU sed did not say so: $(cat "$tmp/build.err")"
# Tools that behave as GNU's under another name (uutils) build it, and are
# the ones linked.
uutils_bin="$(PATH="$uutils" HOMEBREW_PREFIX="$tmp/no-homebrew" TMPDIR="$tmp" environment_toolchain_build 2>"$tmp/build.err")" ||
  fail "a toolchain with uutils-like sed, timeout and date was not built: $(cat "$tmp/build.err")"
for tool in sed timeout date; do
  [[ "$(readlink "$uutils_bin/$tool")" == "$uutils/$tool" ]] || fail "the toolchain did not link the uutils-like $tool"
done
# A BSD date (no '-d <date>') and a timeout without --kill-after are not
# taken for GNU's.
mkdir -p "$tmp/bsd-tools"
printf '#!/usr/bin/env bash\n[[ "$1" != -d ]] || { echo "date: illegal option -- d" >&2; exit 1; }\nexit 0\n' >"$tmp/bsd-tools/date"
printf '#!/usr/bin/env bash\n[[ "$1" != --kill-after=* ]] || { echo "timeout: unknown option" >&2; exit 1; }\nexit 0\n' >"$tmp/bsd-tools/timeout"
chmod +x "$tmp/bsd-tools/date" "$tmp/bsd-tools/timeout"
if environment_passes "$tmp/bsd-tools/date" gnu-date; then fail "a date without -d passed as GNU date"; fi
if environment_passes "$tmp/bsd-tools/timeout" gnu-timeout; then fail "a timeout without --kill-after passed as GNU timeout"; fi
if environment_passes "$no_gnu_sed/sed" gnu-sed; then fail "a sed with the -i of BSD passed as GNU sed"; fi
# The search for a tool reads every candidate before it tries the first: a
# first candidate that passes leaves no writer of the rest on a closed pipe.
# With SIGPIPE ignored, as on some CI runners, that writer printed one
# 'write error: Broken pipe' per candidate left.
many="$tmp/many-candidates"
for n in $(seq 1 300); do mkdir -p "$many/$n" && ln -s "$(readlink "$TEST_TOOLCHAIN_BIN/date")" "$many/$n/date"; done
many_path="$(seq 1 300 | sed "s#^#$many/#" | paste -sd: -)"
status=0
found="$(PATH="$many_path:$PATH" HOMEBREW_PREFIX="$tmp/no-homebrew" bash -c 'trap "" PIPE; source "$1"; environment_find date gnu-date' _ "$source_root/scripts/lib/environment.sh" 2>"$tmp/find.err")" || status=$?
[[ "$status" -eq 0 && "$found" == "$many/1/date" ]] || fail "the search for date with many candidates failed ($status): $found $(cat "$tmp/find.err")"
[[ ! -s "$tmp/find.err" ]] || fail "the search for date with many candidates wrote errors: $(head -n 3 "$tmp/find.err")"

echo "environment tests passed"
