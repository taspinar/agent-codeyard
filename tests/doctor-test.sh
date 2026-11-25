#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
bash_path="$(command -v bash)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/doctor-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# doctor.sh runs from a copy of the scripts with a .agents/template.conf of
# the test, so what it reports about the repository's role does not depend
# on the file of the repository that hosts the test.
fixture="$tmp/repository"
mkdir -p "$fixture/.agents"
cp -R "$source_root/scripts" "$fixture/scripts"
printf 'repository: https://github.com/owner/template\n' >"$fixture/.agents/template.conf"
script="$fixture/scripts/doctor.sh"

fail() {
  echo "doctor test failed: $*" >&2
  exit 1
}

# Builds a bin directory that contains only the named fake tools, so that
# PATH can be restricted to it and a missing tool is really missing.
make_bin() {
  local bin="$tmp/$1"
  shift

  mkdir -p "$bin"
  # The prerequisites of the workflow self-tests that doctor.sh checks
  # (lib/environment.sh), from the isolated toolchain, apart from git and
  # jq, which are listed like any tool; MAKE_BIN_WITHOUT leaves one out.
  # head reads .agents/template.conf (lib/template-repository.sh).
  for tool in bash sed timeout date head; do
    [[ " ${MAKE_BIN_WITHOUT:-} " == *" $tool "* ]] || ln -sf "$TEST_TOOLCHAIN_BIN/$tool" "$bin/$tool"
  done
  for tool in "$@"; do
    case "$tool" in
      git)
        cat >"$bin/git" <<FAKE
#!$bash_path
case "\$*" in
  "rev-parse --show-toplevel") exit "\${MOCK_REPO_EXIT:-0}" ;;
  "remote get-url origin") exit "\${MOCK_ORIGIN_EXIT:-0}" ;;
  "-C "*" remote get-url origin")
    [[ "\${MOCK_ORIGIN_EXIT:-0}" -eq 0 ]] || exit "\$MOCK_ORIGIN_EXIT"
    echo "\${MOCK_ORIGIN_URL:-https://github.com/owner/project}"
    exit 0
    ;;
  "ls-remote --exit-code --heads origin main") exit "\${MOCK_MAIN_EXIT:-0}" ;;
  "push --dry-run --quiet origin HEAD:refs/heads/doctor-push-check") exit "\${MOCK_PUSH_EXIT:-0}" ;;
  "config user.name") [[ -z "\${MOCK_GIT_NO_IDENTITY:-}" ]] || exit 1; echo "Test User"; exit 0 ;;
  "config user.email") [[ -z "\${MOCK_GIT_NO_IDENTITY:-}" ]] || exit 1; echo "test@example.com"; exit 0 ;;
esac
echo "unexpected git call: \$*" >&2
exit 97
FAKE
        ;;
      gh)
        cat >"$bin/gh" <<FAKE
#!$bash_path
[[ "\$*" == "auth status" ]] && exit "\${MOCK_GH_AUTH_EXIT:-0}"
if [[ "\$1" == "api" ]]; then
  [[ -z "\${MOCK_GH_API_FAIL:-}" ]] || exit 1
  case "\$2" in
    "repos/{owner}/{repo}/rules/branches/main") echo "\${MOCK_RULESET_CHECKS:-1}" ;;
    "repos/{owner}/{repo}/branches/main") echo "\${MOCK_CLASSIC_CHECKS:-0}" ;;
    *) echo "unexpected gh api call: \$*" >&2; exit 97 ;;
  esac
  exit 0
fi
echo "unexpected gh call: \$*" >&2
exit 97
FAKE
        ;;
      jq)
        # The real jq: doctor.sh reads a settings file with it.
        printf '#!%s\nexec %q "$@"\n' "$bash_path" "$(command -v "$tool")" >"$bin/$tool"
        ;;
      codex)
        # Logs every call: doctor.sh may ask for the version, but it starts
        # no session ('exec').
        cat >"$bin/codex" <<FAKE
#!$bash_path
printf '%s\n' "\$*" >>"\${MOCK_CODEX_LOG:-/dev/null}"
exit 0
FAKE
        ;;
      *)
        printf '#!%s\nexit 0\n' "$bash_path" >"$bin/$tool"
        ;;
    esac
    chmod +x "$bin/$tool"
  done
  printf '%s\n' "$bin"
}

# Every run uses an explicit agent configuration instead of the repository's.
config="$tmp/agents.conf"
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"

# And an explicit attribution preference, 'allowed' unless a test sets
# another, so the result does not depend on the repository's own file.
attribution="$tmp/attribution.conf"
printf 'agent-attribution: allowed\n' >"$attribution"
claude_settings="$tmp/claude-settings.json"

# HOMEBREW_PREFIX names a directory without brew: the PATH of the test is
# all doctor.sh may find, also on a Mac where Homebrew's GNU tools are
# installed (scripts/lib/environment.sh looks in Homebrew's places).
run_doctor() {
  PATH="$1" HOMEBREW_PREFIX="$tmp/no-homebrew" AGENT_CONFIG_FILE="$config" ATTRIBUTION_CONFIG_FILE="$attribution" \
    ATTRIBUTION_CLAUDE_SETTINGS_FILE="$claude_settings" \
    "$bash_path" "$script" >"$tmp/out.log" 2>&1
}

# Requires a non-zero exit with exactly one FAILED line, matching the pattern,
# so a run that fails for another reason does not pass.
expect_failure() {
  local bin="$1"
  local pattern="$2"

  if run_doctor "$bin"; then
    cat "$tmp/out.log" >&2
    fail "expected a failure matching: $pattern"
  fi
  if [[ "$(grep -c '^FAILED' "$tmp/out.log")" -ne 1 ]] ||
    ! grep -Eq "^FAILED +.*$pattern" "$tmp/out.log"; then
    cat "$tmp/out.log" >&2
    fail "expected exactly one FAILED line matching: $pattern"
  fi
}

# Everything available.
bin="$(make_bin all git gh jq codex claude)"
export MOCK_CODEX_LOG="$tmp/codex.log"
: >"$MOCK_CODEX_LOG"
run_doctor "$bin" || {
  cat "$tmp/out.log" >&2
  fail "complete environment was reported as a failure"
}
if grep -Eq '^(FAILED|WARNING)' "$tmp/out.log"; then
  cat "$tmp/out.log" >&2
  fail "complete environment reported a problem"
fi
grep -Eq '^OK +git has a commit identity' "$tmp/out.log" || fail "the commit identity was not reported"
grep -Eq '^OK +the workflow self-tests find their toolchain' "$tmp/out.log" || fail "the toolchain of the self-tests was not reported: $(cat "$tmp/out.log")"

# A missing prerequisite of the workflow self-tests (here GNU sed) is the
# preflight of verify.sh (lib/environment.sh): a warning with the install
# command, since verify.sh needs it only when a self-test is going to run.
bin_without_sed="$(MAKE_BIN_WITHOUT=sed make_bin without-sed git gh jq codex claude)"
run_doctor "$bin_without_sed" || { cat "$tmp/out.log" >&2; fail "a missing prerequisite of the self-tests was reported as a failure"; }
grep -Eq '^WARNING +GNU sed for the workflow self-tests is missing: \./scripts/verify\.sh ends with status 78' "$tmp/out.log" ||
  fail "a missing GNU sed was not reported as a prerequisite of the self-tests: $(cat "$tmp/out.log")"
grep -Eq '^ +Install it: .*(apt-get install sed|brew install gnu-sed)' "$tmp/out.log" || fail "the install command of GNU sed is missing: $(cat "$tmp/out.log")"

# The implementer uses codex with write access: doctor.sh starts no agent
# session for it, and says nothing about a sandbox. Whether Codex can write
# the runtime directories under .agents/ shows at the first real session
# (start-feature.sh names the cause there; tests/start-feature-test.sh).
if grep -q '^exec' "$MOCK_CODEX_LOG"; then fail "doctor.sh started a codex session: $(cat "$MOCK_CODEX_LOG")"; fi
if grep -Fq "sandbox" "$tmp/out.log"; then fail "doctor.sh reported on the Codex sandbox: $(cat "$tmp/out.log")"; fi
# The same for a level line that gives a write role to codex.
printf 'implementer: claude model-a\nimplementer@high: codex model-c\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a codex level line was reported as a failure"; }
if grep -q '^exec' "$MOCK_CODEX_LOG"; then fail "doctor.sh started a codex session for a level line: $(cat "$MOCK_CODEX_LOG")"; fi
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"
# Codex configured for a write role but not installed: the missing CLI fails,
# naming the role.
bin_no_codex="$(make_bin no-codex git gh jq claude)"
expect_failure "$bin_no_codex" "codex CLI is not installed"
grep -Fq "It is configured for: implementer" "$tmp/out.log" ||
  fail "the missing codex CLI does not name the role that needs it: $(cat "$tmp/out.log")"

# Git without a commit identity fails, with both commands to set one.
MOCK_GIT_NO_IDENTITY=1 expect_failure "$bin" "git has no commit identity"
grep -Fq 'git config --global user.name' "$tmp/out.log" && grep -Fq 'git config --global user.email' "$tmp/out.log" ||
  fail "the commands that set the identity were not shown: $(cat "$tmp/out.log")"

# Each missing required tool fails and is identified.
bin="$(make_bin no-jq git gh codex claude)"
expect_failure "$bin" "jq is not installed"

bin="$(make_bin no-gh git jq codex claude)"
expect_failure "$bin" "gh\\) is not installed"

bin="$(make_bin no-git gh jq codex claude)"
expect_failure "$bin" "git is not installed"

# A jq that is too old for the workflow scripts fails.
bin="$(make_bin old-jq git gh jq codex claude)"
printf '#!%s\necho "jq-1.5"\n' "$bash_path" >"$bin/jq"
expect_failure "$bin" "jq jq-1.5 is too old"

# An unauthenticated GitHub CLI fails.
bin="$(make_bin all-unauthenticated git gh jq codex claude)"
MOCK_GH_AUTH_EXIT=1 expect_failure "$bin" "not authenticated"

# Running outside a repository, a missing origin, and an unreachable main fail.
MOCK_REPO_EXIT=128 expect_failure "$bin" "not inside a Git repository"
MOCK_ORIGIN_EXIT=2 expect_failure "$bin" "'origin' is not configured"
MOCK_MAIN_EXIT=2 expect_failure "$bin" "'main' is not reachable"
MOCK_PUSH_EXIT=128 expect_failure "$bin" "cannot push to origin"

# A 'main' that can be merged into while its checks fail is a warning, whether
# the requirement would come from a ruleset or from classic branch protection.
expect_warning() {
  local pattern="$1"

  run_doctor "$bin" || {
    cat "$tmp/out.log" >&2
    fail "a warning was reported as a failure: $pattern"
  }
  grep -Eq "^WARNING +.*$pattern" "$tmp/out.log" || {
    cat "$tmp/out.log" >&2
    fail "expected a warning matching: $pattern"
  }
}

bin="$(make_bin protection git gh jq codex claude)"
MOCK_RULESET_CHECKS=0 expect_warning "accepts a merge while its checks fail"
MOCK_RULESET_CHECKS=0 MOCK_CLASSIC_CHECKS=2 run_doctor "$bin" || fail "classic branch protection was reported as a failure"
if grep -Eq '^WARNING' "$tmp/out.log"; then fail "classic branch protection was not recognised"; fi
MOCK_GH_API_FAIL=1 expect_warning "could not read the rules"

# A missing agent CLI fails when a role uses it and is a warning otherwise.
bin="$(make_bin one-agent git gh jq claude)"
expect_failure "$bin" "codex CLI is not installed"

printf 'implementer: claude model-a\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || {
  cat "$tmp/out.log" >&2
  fail "an agent CLI that no role uses must not be required"
}
grep -Eq '^WARNING +codex' "$tmp/out.log" || fail "unused missing agent was not reported as a warning"

# Invalid agent configuration fails.
printf 'implementer claude model-a\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"
# Also an unsupported provider or an invalid model on the plain line of a
# role, reported with its line.
printf 'implementer: claude model-a\nreviewer: copilot model-b\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"
grep -Fq "unsupported agent 'copilot' for role 'reviewer' on line 2" "$tmp/out.log" || fail "the unsupported provider was not named with its line: $(cat "$tmp/out.log")"
printf 'implementer: claude model-a\nreviewer: codex --fallback\n' >"$config"
expect_failure "$bin" "agent configuration is invalid"
grep -Fq "for role 'reviewer' on line 2" "$tmp/out.log" || fail "the invalid model was not named with its line: $(cat "$tmp/out.log")"


# Agent attribution: the preference is reported; an unconfigured project is
# a warning; with 'disabled', Claude Code's project settings are checked and
# what no setting can enforce is said as such; an unreadable preference fails.
bin="$(make_bin attribution git gh jq codex claude)"
printf 'implementer: codex model-a\nreviewer: claude model-b\n' >"$config"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "an allowed attribution was reported as a failure"; }
grep -Eq '^OK +agent attribution is allowed' "$tmp/out.log" || fail "the allowed preference was not reported"

rm "$attribution"
expect_warning "agent attribution is not configured"
grep -Eq '^WARNING +Claude' "$tmp/out.log" && fail "an unconfigured project was checked for Claude Code's settings"

printf 'agent-attribution: disabled\n' >"$attribution"
expect_warning "Claude Code's attribution is not turned off"
grep -Eq '^OK +agent attribution is disabled' "$tmp/out.log" || fail "the disabled preference was not reported"
grep -Eq '^NOTE +codex has no attribution setting' "$tmp/out.log" || fail "the clients that no setting reaches were not named"

printf '{"attribution": {"commit": "", "pr": ""}}\n' >"$claude_settings"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a disabled attribution with matching Claude settings was reported as a failure"; }
grep -Eq "^OK +Claude Code's attribution is turned off" "$tmp/out.log" || fail "matching Claude settings were not recognised"
if grep -Eq '^WARNING' "$tmp/out.log"; then cat "$tmp/out.log" >&2; fail "matching Claude settings still warn"; fi

printf '{"attribution": {"commit": "Co-Authored-By: Claude <noreply@anthropic.com>", "pr": ""}}\n' >"$claude_settings"
expect_warning "Claude Code's attribution is not turned off"
printf '{"includeCoAuthoredBy": false}\n' >"$claude_settings"
run_doctor "$bin" || fail "the legacy Claude setting was reported as a failure"
grep -Eq "^OK +Claude Code's attribution is turned off" "$tmp/out.log" || fail "the legacy Claude setting was not recognised"

# Without jq the settings cannot be checked, and that is said.
bin="$(make_bin attribution-no-jq git gh codex claude)"
run_doctor "$bin" && fail "a missing jq passed"
grep -Eq "^WARNING +Claude Code's attribution .* could not be checked without jq" "$tmp/out.log" || fail "an uncheckable settings file was not reported"
bin="$(make_bin attribution git gh jq codex claude)"

printf 'agent-attribution: maybe\n' >"$attribution"
expect_failure "$bin" "attribution configuration is invalid"
printf 'agent-attribution: allowed\n' >"$attribution"

# The role of the repository for the framework-only self-tests, as
# ./scripts/verify.sh decides it (lib/template-repository.sh), is printed
# with its reason, and nothing of the repository changes (Issue 470).
bin="$(make_bin role git gh jq codex claude)"
fixture_state() {
  (cd "$fixture" && find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ld --time-style=+%s.%N && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}
fixture_before="$(fixture_state)"
run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "a project was reported as a failure"; }
grep -Eq '^NOTE +this repository is a project made from the template: ./scripts/verify.sh skips the framework-only self-tests' "$tmp/out.log" ||
  fail "the role of a project was not printed: $(cat "$tmp/out.log")"
grep -Fq "this repository (github.com/owner/project) is not the template that .agents/template.conf names (github.com/owner/template)" "$tmp/out.log" ||
  fail "the reason of the role was not printed: $(cat "$tmp/out.log")"

MOCK_ORIGIN_URL="git@github.com:Owner/template.git" run_doctor "$bin" || { cat "$tmp/out.log" >&2; fail "the template was reported as a failure"; }
grep -Eq '^NOTE +this repository is the template: ./scripts/verify.sh runs the framework-only self-tests' "$tmp/out.log" ||
  fail "the role of the template was not printed: $(cat "$tmp/out.log")"
grep -Fq "the origin is the template that .agents/template.conf names (github.com/owner/template)" "$tmp/out.log" ||
  fail "the reason of the template's role was not printed: $(cat "$tmp/out.log")"
[[ "$(fixture_state)" == "$fixture_before" ]] || fail "doctor.sh changed the repository"

# A path in 'repository:', as a sync from a local clone wrote it before
# Issue 470, is a doubt: a warning that says why the self-tests run.
printf 'repository: /home/someone/agent-codeyard\n' >"$fixture/.agents/template.conf"
fixture_before="$(fixture_state)"
expect_warning "whether this repository is the template cannot be told, so ./scripts/verify.sh runs the framework-only self-tests here: .agents/template.conf names the template by a path, not by a URL: /home/someone/agent-codeyard"
[[ "$(fixture_state)" == "$fixture_before" ]] || fail "doctor.sh changed the repository"
printf 'repository: https://github.com/owner/template\n' >"$fixture/.agents/template.conf"

echo "doctor tests passed"
