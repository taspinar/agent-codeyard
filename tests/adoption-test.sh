#!/usr/bin/env bash

set -euo pipefail

# The adoption of an existing repository from end to end, on a synthetic
# fixture: the assessment, the adoption, the baseline of the verification
# with a pre-existing failure, one ordinary feature with run-feature.sh, and
# a later sync of the template. The template is a copy of this checkout.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adoption-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "adoption test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=Test -c user.email=test@example.com commit -qm "$2"
}

# The template: the files it carries into a project, from this checkout as
# they are, and nothing of what an adopted project has of its own there: its
# decisions, its baseline, its ignore rules, and its exclusions from the
# template's files.
template="$tmp/template"
mkdir -p "$template/.agents"
template_conf "$template/.agents/template.conf"
read -r -a template_paths <<<"$(sed -n 's/^paths: *//p' "$template/.agents/template.conf")"
(cd "$source_root" && git ls-files -co --exclude-standard -z -- "${template_paths[@]}" ':(exclude).gitignore' ':(exclude).agents/template.conf' |
  while IFS= read -r -d '' path; do
    [[ -f "$path" ]] && printf '%s\0' "$path"
  done |
  tar --null -T - -cf -) | tar -C "$template" -xf -
workflow_gitignore "$template/.gitignore"
git -C "$template" init -q -b main
commit_all "$template" "Template"

# The project: a small service with a test that passes, a linter that fails
# before any change, its own CI that runs both, and a remote.
repo="$tmp/service"
mkdir -p "$repo/src" "$repo/.github/workflows"
printf '# Fixture service\n\nPrints a greeting.\n' >"$repo/README.md"
printf '#!/bin/sh\necho hello\n' >"$repo/src/app.sh"
printf '#!/bin/sh\ntest "$(sh src/app.sh)" = hello\n' >"$repo/tests.sh"
printf '#!/bin/sh\necho "src/app.sh:1: a style error older than the adoption" >&2\nexit 1\n' >"$repo/lint.sh"
chmod +x "$repo/tests.sh" "$repo/lint.sh"
printf 'name: ci\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ./tests.sh\n      - run: ./lint.sh\n' \
  >"$repo/.github/workflows/ci.yml"
git -C "$repo" init -q -b main
git -C "$repo" config user.name Owner
git -C "$repo" config user.email owner@example.com
commit_all "$repo" "The service"
git init -q --bare -b main "$tmp/service-remote.git"
git -C "$repo" remote add origin "$tmp/service-remote.git"
git -C "$repo" push -q -u origin main
history_before="$(git -C "$repo" rev-list main)"
ci_before="$(cksum <"$repo/.github/workflows/ci.yml")"

# ------------------------------------------------------------ 1. assessment
(cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/assess-repository.sh "$repo" --facts-only) >"$tmp/assess.out" 2>&1 ||
  { cat "$tmp/assess.out" >&2; fail "the facts failed"; }
facts="$template/$(sed -n 's#^Assessment facts: \(.*\)$#\1#p' "$tmp/assess.out")"
result="$(jq -c '{summary: "A shell service with a test and a linter in its CI.",
  facts: [{statement: "The CI runs ./tests.sh and ./lint.sh.", evidence: [.ci[0].id]}],
  assumptions: [{statement: "src/app.sh is the whole service.", basis: "It is the only source file."}],
  questions: [{question: "Who uses the greeting?", why: "The users of the requirements."}],
  risks: [{risk: "The linter fails on main.", basis: "lint.sh exits 1."}],
  collisions: [.adoption.collisions[] | {path, resolution: "keep-project", rationale: "The project'"'"'s own file."}],
  profile: {name: "standard", rationale: "A service."},
  verification: [.commands[] | select(.origin == "ci") | {name: (if .command == "./tests.sh" then "tests" else "lint" end), source: .id,
    rationale: "The CI runs it."}],
  execution_needed: [{what: "./tests.sh and ./lint.sh", why: "The baseline.", side_effects: "None known."}]}' "$facts")"
(cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$tmp/assessor.log" MOCK_OUTPUT="$result" \
  ./scripts/assess-repository.sh "$repo") >"$tmp/assess.out" 2>&1 || { cat "$tmp/assess.out" >&2; fail "the assessment failed"; }

# -------------------------------------------------------------- 2. adoption
(cd "$template" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/adopt-repository.sh "$repo") >"$tmp/adopt.out" 2>&1 ||
  { cat "$tmp/adopt.out" >&2; fail "the adoption failed"; }
[[ "$(git -C "$repo" branch --show-current)" == "adopt/agent-codeyard" ]] || fail "the adoption is not on its branch"
isolation="unset \$(compgen -e | grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL' || true); export DATABASE_URL=postgresql://isolated:isolated@127.0.0.1:1/isolated DO_NOT_TRACK=1; "
guard='for f in .env .env.* .dev.vars; do [[ ! -e $f && ! -L $f || " .env.example .env.sample .env.template .env.dist .env.defaults " == *" $f "* ]] || { echo "$f: a credential file in the directory of this check, which a tool may load, whether Git tracks it or not. The check stops until the owner has set up the shielding: move the file out for the run, or run the verification in a working copy without it." >&2; exit 1; }; done && '
grep -Fxq "tests: ${isolation}${guard}./tests.sh" "$repo/scripts/verify.conf" && grep -Fxq "lint: ${isolation}${guard}./lint.sh" "$repo/scripts/verify.conf" ||
  fail "the project's CI commands are not the checks: $(cat "$repo/scripts/verify.conf")"
[[ "$(cksum <"$repo/.github/workflows/ci.yml")" == "$ci_before" ]] || fail "the project's CI was replaced"
for document in docs/architecture.md docs/PROJECT_REQUIREMENTS.md docs/roadmap.md; do
  grep -q '^> \*\*Observed, not approved\.\*\*' "$repo/$document" || fail "$document is not marked as observed, not approved"
done
[[ -z "$(git -C "$repo" diff --name-only main adopt/agent-codeyard -- docs/decisions | grep -v '^docs/decisions/README.md$' || true)" ]] ||
  fail "the adoption wrote an ADR"

# -------------------------------------------------------------- 3. baseline
# The owner starts the baseline on the adoption's branch. The linter fails
# before any change: the baseline records it, and it is no passing run.
if (cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/verify.sh --baseline) >"$tmp/baseline.out" 2>&1; then
  fail "a baseline with a failing check passed"
fi
baseline="$repo/.agents/verification-baseline"
grep -Fxq "pass: tests" "$baseline" && grep -Fxq "fail: lint exit 1" "$baseline" ||
  fail "the baseline does not record the checks: $(cat "$baseline" 2>/dev/null; cat "$tmp/baseline.out")"
[[ ! -e "$repo/.agents/verification/passed" ]] || fail "the baseline recorded a passing verification"
commit_all "$repo" "Record the baseline of the verification"
git -C "$repo" switch -q main
git -C "$repo" merge -q --ff-only adopt/agent-codeyard
git -C "$repo" push -q origin main
[[ "$(git -C "$repo" rev-list main | tail -n +3)" == "$history_before" ]] || fail "the history of the project was rewritten"

# The pre-existing failure stays visible and fails the verification.
if (cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/verify.sh) >"$tmp/verify.out" 2>&1; then
  fail "the verification passed with a pre-existing failure"
fi
grep -Eq '^KNOWN +lint \(exit 1\): failed before any change' "$tmp/verify.out" && grep -Eq '^PASS +tests$' "$tmp/verify.out" ||
  fail "the pre-existing failure is not shown as known: $(cat "$tmp/verify.out")"
[[ ! -e "$repo/.agents/verification/passed" ]] || fail "a verification with a known failure recorded a pass"

# The owner accepts it as an exception; the verification passes and shows it.
printf 'accepted-failure: lint The style errors predate the adoption; a later feature fixes them.\n' >>"$repo/scripts/verify.conf"
commit_all "$repo" "Accept the known failure of the linter"
git -C "$repo" push -q origin main
(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" ./scripts/verify.sh) >"$tmp/verify.out" 2>&1 ||
  { cat "$tmp/verify.out" >&2; fail "the verification with an accepted exception failed"; }
grep -Eq '^ACCEPTED +lint \(exit 1\)' "$tmp/verify.out" || fail "the accepted exception is not shown: $(cat "$tmp/verify.out")"

# ---------------------------------------------------- 4. an ordinary feature
# Fake agents that play the implementer and the reviewer, and a fake GitHub.
feature_bin="$tmp/feature-bin"
mkdir -p "$feature_bin"
ln -sf "$(command -v jq)" "$feature_bin/jq"
cp "$tmp/bin/gh-comments" "$feature_bin/gh-comments"
cat >"$feature_bin/codex" <<'AGENT'
#!/usr/bin/env bash
set -euo pipefail
provider="$(basename "$0")"
out=""
schema=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --output-last-message) out="${args[$((i + 1))]}" ;;
    --output-schema | --json-schema) schema="${args[$((i + 1))]}" ;;
  esac
done
case "$provider:$schema:$out" in
  *review.schema.json:* | claude:*\"findings\"*:) role=reviewer ;;
  *::*-implementer.md) role=implementer ;;
  *) echo "The fake agent does not know this session: $*" >&2; exit 98 ;;
esac
echo "$role" >>"$RUN_CONTROL/sessions"
[[ -z "$schema" ]] || cat >/dev/null
if [[ "$role" == implementer ]]; then
  printf 'feature\n' >>feature.txt
  mkdir -p .agents/summaries .agents/completion
  printf -- '- Adds the feature file.\n' >".agents/summaries/$RUN_ISSUE.md"
  printf '{"schema": "completion/v1", "status": "complete", "criteria": [{"criterion": "The feature file exists", "status": "met", "evidence": "feature.txt"}], "remaining": []}\n' \
    >".agents/completion/$RUN_ISSUE.json"
  reply="The feature is implemented."
else
  reply='{"architecture_impact": {"level": "minor", "rationale": "Stays within the architecture.", "checked_against": []}, "verdict": "PASS", "limitations": "", "findings": []}'
fi
if [[ "$provider" != claude ]]; then
  printf '%s\n' "$reply" >"$out"
elif printf '%s' "$reply" | jq -e . >/dev/null 2>&1; then
  printf '{"is_error": false, "structured_output": %s}\n' "$reply"
else
  jq -n --arg result "$reply" '{is_error: false, result: $result}'
fi
AGENT
chmod +x "$feature_bin/codex"
cp "$feature_bin/codex" "$feature_bin/claude"
cat >"$feature_bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RUN_CONTROL/gh.log"
case "${1:-} ${2:-}" in
  "auth status") ;;
  "issue view")
    case "$*" in
      *"--json number"*) echo "$3" ;;
      *"--json title"*) echo "F02 — Feature file" ;;
      *) printf 'Title: F02 — Feature file\n\nThe feature file exists.\n' ;;
    esac
    ;;
  "issue comment" | "issue list" | "pr edit" | "pr list") ;;
  "pr create") echo "https://github.com/example/service/pull/7" ;;
  "pr view") echo "main" ;;
  "api repos/{owner}/{repo}/rules/branches/main") echo "1" ;;
  "api repos/"*"/comments") exec "$(dirname "$0")/gh-comments" "$@" ;;
  *) echo "Unexpected gh invocation: $*" >&2; exit 97 ;;
esac
GH
chmod +x "$feature_bin/gh"
printf 'implementer: codex model-i\nreviewer: claude model-r\ntriage: codex model-t\ntriage-implementer: codex model-f\n' >"$tmp/agents.conf"
mkdir -p "$tmp/control"
status=0
(
  cd "$repo"
  PATH="$feature_bin:/usr/bin:/bin" AGENT_CONFIG_FILE="$tmp/agents.conf" RUN_CONTROL="$tmp/control" RUN_ISSUE=2 GIT_EDITOR=false \
    RUN_FEATURE_RETRY_WAIT=0 START_FEATURE_GH_WAIT=0 ./scripts/run-feature.sh 2 thing </dev/null
) >"$tmp/feature.out" 2>&1 || status=$?
[[ "$status" -eq 0 ]] || { cat "$tmp/feature.out" >&2; fail "the ordinary feature failed with status $status"; }
[[ "$(paste -sd, "$tmp/control/sessions")" == "implementer,reviewer" ]] ||
  fail "the feature did not run one implementer and one reviewer: $(paste -sd, "$tmp/control/sessions")"
grep -q '^pr create' "$tmp/control/gh.log" || fail "the feature opened no pull request"
git -C "$repo" ls-remote --exit-code --heads origin feature/2-thing >/dev/null || fail "the feature branch was not pushed"
[[ "$(git -C "$repo-2-thing" show HEAD:feature.txt)" == "feature" && -z "$(git -C "$repo-2-thing" status --porcelain)" ]] ||
  fail "the feature is not committed"
grep -Fq "ACCEPTED  lint" "$tmp/feature.out" || fail "the feature's verification did not show the accepted exception"
# The feature changed no planning document: they stay observed, not
# approved, until the planning approval.
grep -q '^> \*\*Observed, not approved\.\*\*' "$repo-2-thing/docs/architecture.md" || fail "the feature removed the mark"
if (cd "$repo" && PATH="$feature_bin:/usr/bin:/bin" ./scripts/finish-planning.sh --check) >/dev/null 2>&1; then
  fail "the reconstructed planning counts as approved"
fi

# ------------------------------------------------------ 5. a later sync
# The template changes a file of the workflow; the sync takes it over and
# leaves the project's checks, its baseline, and its CI alone.
printf '\nA new rule of the template.\n' >>"$template/docs/evaluation.md"
printf '# A new check of the template.\nsomething: true\n' >>"$template/scripts/verify.conf"
commit_all "$template" "Template update"
checks_before="$(cat "$repo/scripts/verify.conf")"
baseline_before="$(cat "$baseline")"
(cd "$repo" && PATH="$feature_bin:/usr/bin:/bin" ./scripts/sync-template.sh --template "$template") >"$tmp/sync.out" 2>&1 ||
  { cat "$tmp/sync.out" >&2; fail "the sync of the adopted project failed"; }
cmp -s "$repo/docs/evaluation.md" "$template/docs/evaluation.md" || fail "the sync did not take over the workflow file: $(cat "$tmp/sync.out")"
[[ "$(cat "$repo/scripts/verify.conf")" == "$checks_before" && "$(cat "$baseline")" == "$baseline_before" ]] ||
  fail "the sync changed the project's checks or its baseline"
[[ "$(cksum <"$repo/.github/workflows/ci.yml")" == "$ci_before" ]] || fail "the sync changed the project's CI"

echo "adoption tests passed"
