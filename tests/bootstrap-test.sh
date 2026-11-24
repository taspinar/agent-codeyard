#!/usr/bin/env bash

set -euo pipefail

# Self-tests of scripts/lib/bootstrap.sh: the Bash floor of the workflow.
# Every entry script of scripts/ reads it first, before anything else runs
# and before it sources a library, and below Bash 4 stops with status 78 and
# the ENVIRONMENT line with the install command.
#
# Below Bash 4 is a shell without BASH_VERSINFO >= 4: 'sh' (dash on Linux,
# the Bash 3.2 of macOS in its POSIX mode there), and /bin/bash itself where
# it is older than 4, as on macOS.

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bootstrap_line='case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi'

# The old shells of this machine: sh, and /bin/bash when it is older than 4.
old_shells=()
sh_path="$(command -v sh || true)"
if [[ -n "$sh_path" ]] && ! "$sh_path" -c '[ "${BASH_VERSINFO:-0}" -ge 4 ]' 2>/dev/null; then
  old_shells+=("$sh_path")
fi
if [[ -x /bin/bash ]] && ! /bin/bash -c '[ "${BASH_VERSINFO:-0}" -ge 4 ]' 2>/dev/null; then
  old_shells+=(/bin/bash)
fi
[[ "${#old_shells[@]}" -gt 0 ]] || fail "this machine has no shell older than Bash 4 to test with (sh is $(sh -c 'echo ${BASH_VERSION:-not Bash}'))"

# A copy of the scripts in which every library but the bootstrap leaves a
# mark when it is sourced: a script that sources one before the bootstrap
# stopped it leaves the mark.
copy="$tmp/copy"
mkdir -p "$copy/scripts/lib"
cp "$source_root"/scripts/*.sh "$copy/scripts/"
cp "$source_root/scripts/lib/bootstrap.sh" "$copy/scripts/lib/"
for library in "$source_root"/scripts/lib/*.sh; do
  name="${library##*/}"
  [[ "$name" != bootstrap.sh ]] || continue
  printf ': >>%q\n' "$tmp/sourced-$name" >"$copy/scripts/lib/$name"
done

entry_count=0
for script in "$source_root"/scripts/*.sh; do
  name="${script##*/}"
  entry_count=$((entry_count + 1))

  # The bootstrap is the first thing after the interpreter line.
  [[ "$(sed -n 2p "$script")" == "$bootstrap_line" ]] ||
    fail "$name does not read lib/bootstrap.sh on its second line: $(sed -n 2p "$script")"

  for shell in "${old_shells[@]}"; do
    for invocation in "./scripts/$name" "$copy/scripts/$name"; do
      status=0
      (cd "$copy" && "$shell" "$invocation" --help) >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
      [[ "$status" -eq 78 ]] || fail "$name under $shell ($invocation) exited with $status instead of 78: $(cat "$tmp/out" "$tmp/err")"
      grep -Eq '^ENVIRONMENT  Bash 4 or newer \(this is .*\) — .*(brew install bash|apt-get install bash)' "$tmp/out" ||
        fail "$name under $shell did not print the ENVIRONMENT line with the install command: $(cat "$tmp/out")"
      [[ "$(wc -l <"$tmp/out")" -eq 1 ]] || fail "$name under $shell printed more than the ENVIRONMENT line: $(cat "$tmp/out")"
      grep -Fq "Error: $name needs Bash 4 or newer" "$tmp/err" || fail "$name under $shell did not explain the stop: $(cat "$tmp/err")"
      if compgen -G "$tmp/sourced-*" >/dev/null; then
        fail "$name under $shell sourced a library before the bootstrap stopped it: $(cd "$tmp" && ls sourced-*)"
      fi
    done
  done
done
[[ "$entry_count" -gt 20 ]] || fail "only $entry_count entry scripts were found"

# Run from scripts/ itself, the script finds the bootstrap next to it.
status=0
(cd "$copy/scripts" && "${old_shells[0]}" verify.sh) >"$tmp/out" 2>/dev/null || status=$?
[[ "$status" -eq 78 ]] || fail "verify.sh run from scripts/ under ${old_shells[0]} exited with $status instead of 78"

# Run by name from a directory without lib/ ('bash verify.sh', which Bash
# finds on PATH), the script finds the bootstrap next to it. Shown on every
# host with a copy whose bootstrap acts as a Bash 3.2 would (it always stops),
# run by the Bash of the test, and with each real old Bash of the host.
fake="$tmp/fake-floor"
mkdir -p "$fake/scripts/lib" "$tmp/elsewhere"
cp "$copy"/scripts/*.sh "$fake/scripts/"
cp "$copy"/scripts/lib/*.sh "$fake/scripts/lib/"
printf '%s\n' 'echo "ENVIRONMENT  Bash 4 or newer (this is 3.2.57(1)-release) — brew install bash"' 'exit 78' >"$fake/scripts/lib/bootstrap.sh"
by_name_shells=(bash)
for shell in "${old_shells[@]}"; do
  if "$shell" -c '[ -n "${BASH_VERSION:-}" ]' 2>/dev/null; then by_name_shells+=("$shell"); fi
done
for shell in "${by_name_shells[@]}"; do
  root="$fake"
  [[ "$shell" == bash ]] || root="$copy"
  for name in verify.sh doctor.sh run-feature.sh; do
    status=0
    (cd "$tmp/elsewhere" && PATH="$root/scripts:$PATH" "$shell" "$name" --help) >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
    [[ "$status" -eq 78 ]] || fail "$name run by name under $shell exited with $status instead of 78: $(cat "$tmp/out" "$tmp/err")"
    grep -Eq '^ENVIRONMENT  Bash 4 or newer \(this is .*\) — .*(brew install bash|apt-get install bash)' "$tmp/out" ||
      fail "$name run by name under $shell did not read the bootstrap: $(cat "$tmp/out")"
    if compgen -G "$tmp/sourced-*" >/dev/null; then
      fail "$name run by name under $shell sourced a library before the bootstrap stopped it: $(cd "$tmp" && ls sourced-*)"
    fi
  done
done

# Where lib/bootstrap.sh is missing (a fixture that copies one script), an old
# shell still stops with 78 before anything runs; Bash 4 runs the script.
lone="$tmp/lone"
mkdir -p "$lone/scripts"
cp "$source_root/scripts/check-risk.sh" "$lone/scripts/"
for shell in "${old_shells[@]}"; do
  status=0
  (cd "$lone" && "$shell" ./scripts/check-risk.sh --help) >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
  [[ "$status" -eq 78 ]] || fail "check-risk.sh without lib/bootstrap.sh under $shell exited with $status instead of 78: $(cat "$tmp/out" "$tmp/err")"
  grep -Eq '^ENVIRONMENT  Bash 4 or newer \(this is .*\) — ' "$tmp/out" || fail "check-risk.sh without lib/bootstrap.sh under $shell printed no ENVIRONMENT line: $(cat "$tmp/out")"
  [[ "$(wc -l <"$tmp/out")" -eq 1 ]] || fail "check-risk.sh without lib/bootstrap.sh under $shell printed more than the ENVIRONMENT line: $(cat "$tmp/out")"
  grep -Fq "did not find lib/bootstrap.sh" "$tmp/err" || fail "check-risk.sh without lib/bootstrap.sh under $shell did not explain the stop: $(cat "$tmp/err")"
done
out="$(cd "$lone" && bash ./scripts/check-risk.sh --help 2>&1)" || true
[[ "$out" != *ENVIRONMENT* ]] || fail "check-risk.sh without lib/bootstrap.sh stopped under Bash $BASH_VERSION: $out"

# Bash 4 and newer pass without a word, and the script runs.
status=0
out="$(cd "$source_root" && bash ./scripts/check-risk.sh --help 2>&1)" || status=$?
[[ "$out" != *ENVIRONMENT* ]] || fail "the bootstrap reported Bash $BASH_VERSION as too old: $out"
grep -Fq "Usage: ./scripts/check-risk.sh" <<<"$out" || fail "check-risk.sh did not run under Bash $BASH_VERSION: $out"
out="$(bash -c 'source "$1"; echo "after the bootstrap"' _ "$source_root/scripts/lib/bootstrap.sh" 2>&1)"
[[ "$out" == "after the bootstrap" ]] || fail "the bootstrap printed something under Bash $BASH_VERSION: $out"

# The bootstrap is POSIX sh, which every old shell reads.
for shell in "${old_shells[@]}"; do
  "$shell" -n "$source_root/scripts/lib/bootstrap.sh" || fail "$shell cannot parse lib/bootstrap.sh"
done

echo "bootstrap tests passed ($entry_count entry scripts, shells: ${old_shells[*]})"
