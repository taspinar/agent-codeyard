#!/usr/bin/env bash

set -euo pipefail

# The scenario register of the self-tests of scripts/run-feature.sh
# (tests/lib-run-feature.sh): every case of a part tests/run-feature-<part>-test.sh
# has a stable identifier, and the register lists each once. The check fails
# on an identifier that is defined twice, one that the register lists and no
# part runs, and one that a part runs and the register does not list.

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

source "$source_root/tests/lib-fakes.sh"
source "$source_root/tests/lib-run-feature.sh"

parts=("$source_root"/tests/run-feature-*-test.sh)
[[ -e "${parts[0]}" ]] || fail "no part tests/run-feature-<part>-test.sh exists"

# Every part is a check of scripts/verify-workflow.conf, so every part runs.
for part in "${parts[@]}"; do
  grep -Eq "^[a-z0-9-]+( \[[a-z0-9-]+\])?: \./tests/$(basename "$part")\$" "$source_root/scripts/verify-workflow.conf" ||
    fail "$(basename "$part") is not a check of scripts/verify-workflow.conf"
done

# The register agrees with the parts.
scenario_register >"$tmp/register"
errors="$(scenario_errors "$tmp/register" "${parts[@]}")" || fail "the register does not match the parts: $errors"
first="$(scenario_ids "${parts[@]}" | sed -n "1s/^.*://p")"
[[ -n "$first" ]] || fail "the parts define no scenario"

# expect_fault <description> <message> <register> <part...>: the check fails
# with <message>.
expect_fault() {
  local description="$1"
  local message="$2"
  local output

  shift 2
  if output="$(scenario_errors "$@")"; then fail "the check passed $description"; fi
  grep -Fq -- "$message" <<<"$output" || fail "the check did not report $description: $output"
}

# An identifier that is defined twice, in another part or in the same one.
mkdir -p "$tmp/twice"
cp "${parts[@]}" "$tmp/twice/"
printf 'scenario %s\n' "$first" >>"$tmp/twice/$(basename "${parts[-1]}")"
expect_fault "on an identifier defined twice" "scenario $first is defined more than once: " "$tmp/register" "$tmp/twice"/*
cp "${parts[@]}" "$tmp/twice/"
printf 'scenario %s\n' "$first" >>"$tmp/twice/$(basename "${parts[0]}")"
expect_fault "on an identifier defined twice in one part" "scenario $first is defined more than once: " "$tmp/register" "$tmp/twice"/*

# An identifier that the register lists and no part runs.
{ cat "$tmp/register"; echo "no-such-scenario"; } >"$tmp/register-extra"
expect_fault "on a listed identifier that no part runs" "the register lists no-such-scenario, which no part runs" \
  "$tmp/register-extra" "${parts[@]}"

# An identifier that a part runs and the register does not list.
grep -Fvx -- "$first" "$tmp/register" >"$tmp/register-short"
expect_fault "on an identifier that the register does not list" "runs scenario $first, which the register does not list" \
  "$tmp/register-short" "${parts[@]}"

# An identifier that the register lists twice.
{ cat "$tmp/register"; echo "$first"; } >"$tmp/register-twice"
expect_fault "on an identifier listed twice" "the register lists $first more than once" "$tmp/register-twice" "${parts[@]}"

echo "scenario-register tests passed ($(grep -c . < <(scenario_ids "${parts[@]}")) scenarios in ${#parts[@]} parts)"
