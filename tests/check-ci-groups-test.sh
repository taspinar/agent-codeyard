#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-ci-groups-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "check-ci-groups test failed: $*" >&2
  exit 1
}

# A project with the groups of the example workflow (docs/examples/
# parallel-ci.yml): code, build, e2e, and default; the unit tests are split
# over two partitions, each declared by the check that runs it.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/scripts" "$repo/ci" "$repo/tests/unit"
  cp "$source_root/scripts/verify.sh" "$source_root/scripts/check-ci-groups.sh" "$repo/scripts/"
  cp "$source_root/docs/examples/parallel-ci.yml" "$repo/ci.yml"
  cat >"$repo/scripts/verify.conf" <<'EOF'
lint [code]: true
unit-1 [code] partition ci/unit-1.txt: true
unit-2 [code] partition ci/unit-2.txt: true
site-build [build]: true
browser-tests [e2e]: true
structure: true
EOF
  touch "$repo/tests/unit/a_test.py" "$repo/tests/unit/b_test.py" "$repo/tests/unit/c_test.py"
  printf 'tests/unit/a_test.py\n' >"$repo/ci/unit-1.txt"
  printf '# the slow ones\ntests/unit/b_test.py\ntests/unit/c_test.py\n' >"$repo/ci/unit-2.txt"
  git -C "$repo" init -q -b main
  printf '%s\n' "$repo"
}

# check <repo> [argument...]: runs the check; sets 'status' and '<repo>.out'.
check() {
  local repo="$1"

  shift
  status=0
  (cd "$repo" && ./scripts/check-ci-groups.sh "$@") >"$repo.out" 2>&1 || status=$?
}

expect() {
  local repo="$1"
  local want="$2"
  local text="$3"
  local description="$4"

  [[ "$status" -eq "$want" ]] || {
    cat "$repo.out" >&2
    fail "$description: exit $status, expected $want"
  }
  [[ -z "$text" ]] || grep -Fq -- "$text" "$repo.out" || {
    cat "$repo.out" >&2
    fail "$description: the output does not say '$text'"
  }
}

partitions=(--tests 'tests/unit/*_test.py' --partition ci/unit-1.txt --partition ci/unit-2.txt)
needs_ok='{"mapping":{"result":"success","outputs":{}},"group-code":{"result":"success","outputs":{}},"group-default":{"result":"success","outputs":{}},"group-build":{"result":"success","outputs":{}},"group-e2e":{"result":"success","outputs":{}}}'

# The example workflow maps every group onto one job, the partitions cover
# every test once, and the aggregate passes when every job succeeded.
repo="$(setup_repo holds)"
check "$repo" --workflow ci.yml "${partitions[@]}" --results "$needs_ok"
expect "$repo" 0 "PASS  every required job succeeded" "a complete mapping"

# A group that no job declares: a check added to a new group.
repo="$(setup_repo omitted-group)"
printf 'schema [data]: true\n' >>"$repo/scripts/verify.conf"
check "$repo" --workflow ci.yml
expect "$repo" 1 "no job of ci.yml declares the group data" "an unassigned group"

# The group 'default' counts like any other: a job removed for it fails.
repo="$(setup_repo omitted-default)"
sed -i.bak '/^  group-default:/,/^$/d' "$repo/ci.yml"
grep -Fq 'VERIFY_GROUP: default' "$repo/ci.yml" && fail "the default job was not removed"
check "$repo" --workflow ci.yml
expect "$repo" 1 "no job of ci.yml declares the group default" "an unassigned default group"

# A group job whose declaration was dropped: the command alone counts for
# nothing, whatever it runs.
repo="$(setup_repo undeclared-job)"
sed -i.bak '/VERIFY_GROUP: e2e/d' "$repo/ci.yml"
sed -i.bak 's|--only "$VERIFY_GROUP"|--only e2e|' "$repo/ci.yml"
check "$repo" --workflow ci.yml
expect "$repo" 1 "(job group-e2e) declares no group" "a group job without a declaration"
grep -Fq "no job of ci.yml declares the group e2e" "$repo.out" || fail "a group run only by its command passed: $(cat "$repo.out")"

# A group declared twice, a group verify.sh does not know, a group from an
# expression, a declaration in a job named for another group, and a
# declaration outside the env of a job.
repo="$(setup_repo bad-declarations)"
cat >>"$repo/ci.yml" <<'EOF'
  group-extra:
    env:
      VERIFY_GROUP: code
    steps:
      - run: ./scripts/verify.sh --all --only "$VERIFY_GROUP"
  group-docs:
    env:
      VERIFY_GROUP: docs
  group-matrix:
    env:
      VERIFY_GROUP: ${{ matrix.group }}
  group-step:
    steps:
      - env:
          VERIFY_GROUP: build
        run: ./scripts/verify.sh --all --only "$VERIFY_GROUP"
  group-flow:
    env: { VERIFY_GROUP: e2e }
EOF
check "$repo" --workflow ci.yml
expect "$repo" 1 "2 jobs of ci.yml declare the group code" "a group assigned twice"
grep -Fq "declares the group docs, which has no check" "$repo.out" || fail "an unknown group passed: $(cat "$repo.out")"
grep -Fq "(job group-matrix) declares no single group, or one from an expression" "$repo.out" || fail "an expression passed: $(cat "$repo.out")"
grep -Fq "(job group-extra) declares the group code; name the job group-code" "$repo.out" || fail "a misnamed job passed: $(cat "$repo.out")"
grep -Fq "(job group-step) names VERIFY_GROUP outside the env of a job" "$repo.out" || fail "a step-level declaration passed: $(cat "$repo.out")"
grep -Fq "(job group-flow) names VERIFY_GROUP outside the env of a job" "$repo.out" || fail "a flow declaration passed: $(cat "$repo.out")"

# A quoted declaration is the same declaration.
repo="$(setup_repo quoted)"
sed -i.bak "s|VERIFY_GROUP: code|VERIFY_GROUP: 'code'|; s|VERIFY_GROUP: build|VERIFY_GROUP: \"build\" # the producer|" "$repo/ci.yml"
check "$repo" --workflow ci.yml
expect "$repo" 0 "PASS  every group is declared by exactly one job of ci.yml" "quoted declarations"

# A new test file that no partition lists, a file listed twice, and a stale
# entry.
repo="$(setup_repo partitions)"
touch "$repo/tests/unit/d_test.py"
printf 'tests/unit/c_test.py\ntests/unit/gone_test.py\n' >>"$repo/ci/unit-1.txt"
check "$repo" "${partitions[@]}"
expect "$repo" 1 "no partition lists the test tests/unit/d_test.py" "an unassigned test"
grep -Fq "the test tests/unit/c_test.py is listed 2 times" "$repo.out" || fail "a duplicate test passed: $(cat "$repo.out")"
grep -Fq "lists tests/unit/gone_test.py, which is not a file" "$repo.out" || fail "a stale entry passed: $(cat "$repo.out")"

# A partition that no check declares: a check that runs it but lacks the
# declaration counts for nothing, whatever its command reads.
repo="$(setup_repo undeclared-partition)"
sed -i.bak 's|^unit-2 \[code\] partition ci/unit-2.txt: true$|unit-2 [code]: true $(cat ci/unit-2.txt)|' "$repo/scripts/verify.conf"
grep -Fq 'unit-2 [code]: true $(cat ci/unit-2.txt)' "$repo/scripts/verify.conf" || fail "the undeclared partition was not set up"
check "$repo" "${partitions[@]}"
expect "$repo" 1 "no check of scripts/verify.conf declares the partition ci/unit-2.txt" "an undeclared partition"

# A partition that two checks declare.
repo="$(setup_repo duplicate-partition)"
printf 'unit-2-again [e2e] partition ci/unit-2.txt: true\n' >>"$repo/scripts/verify.conf"
check "$repo" "${partitions[@]}"
expect "$repo" 1 "the partition ci/unit-2.txt is declared by 2 checks: unit-2, unit-2-again" "a duplicate partition"

# A declared partition that does not exist, and a declaration of a partition
# that is not given.
repo="$(setup_repo missing-partition)"
rm "$repo/ci/unit-2.txt"
printf 'unit-3 [code] partition ci/unit-3.txt: true\n' >>"$repo/scripts/verify.conf"
check "$repo" "${partitions[@]}"
expect "$repo" 1 "the partition ci/unit-2.txt does not exist" "a missing partition"
grep -Fq "the check unit-3 declares the partition ci/unit-3.txt, which is not given with --partition" "$repo.out" ||
  fail "a declared partition outside --partition passed: $(cat "$repo.out")"

# The aggregate: failed, cancelled, skipped, and missing jobs fail it.
repo="$(setup_repo results)"
for result in failure cancelled skipped; do
  check "$repo" --results "$(jq -c --arg result "$result" '."group-e2e".result = $result' <<<"$needs_ok")"
  expect "$repo" 1 "the job group-e2e ended with '$result'" "a $result group job"
done
check "$repo" --results "$(jq -c 'del(."group-build")' <<<"$needs_ok")"
expect "$repo" 1 "the aggregate job does not need group-build" "a missing group job"
check "$repo" --results '{}'
expect "$repo" 1 "does not need group-code" "no results at all"
check "$repo" --results ''
expect "$repo" 2 "is not the needs of a job" "an empty result"

# A skip is allowed only where it is modeled, and never for a group job.
needs_preview="$(jq -c '. + {"preview":{"result":"skipped","outputs":{}}}' <<<"$needs_ok")"
check "$repo" --results "$needs_preview"
expect "$repo" 1 "the job preview ended with 'skipped'" "an unmodeled skip"
check "$repo" --results "$needs_preview" --may-skip preview
expect "$repo" 0 "SKIP  preview (may be skipped)" "a modeled skip"
check "$repo" --results "$(jq -c '.preview.result = "failure"' <<<"$needs_preview")" --may-skip preview
expect "$repo" 1 "the job preview ended with 'failure'" "a failure of a job that may be skipped"
check "$repo" --results "$needs_ok" --may-skip group-e2e
expect "$repo" 2 "a group job may not be skipped" "a group job declared skippable"

echo "check-ci-groups tests passed"
