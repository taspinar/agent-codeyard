#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "review-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

valid_result='{"verdict": "CHANGES_REQUIRED", "limitations": "", "findings": [
  {"severity": "major", "title": "Roadmap omits offline use", "evidence": "docs/roadmap.md, F02", "impact": "A requirement is unplanned.", "recommendation": "Add a feature for offline use."}
]}'
export MOCK_OUTPUT="$valid_result"

# Creates a repository whose origin/main holds the template documents and
# whose planning branch holds uncommitted planning work.
setup_repo() {
  local label="$1"
  local seed="$tmp/$label-seed"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  mkdir -p "$seed/docs/decisions"
  copy_workflow "$seed"
  printf 'planning-reviewer: claude model-p\n' >"$seed/.agents/agents.conf"
  printf '# Agents\n' >"$seed/AGENTS.md"
  printf '# Architecture\n\nTemplate.\n' >"$seed/docs/architecture.md"
  printf '# Roadmap\n\nTemplate.\n' >"$seed/docs/roadmap.md"
  printf '# Project Requirements\n\nStatus: Draft\nApproved at: Not approved\n' >"$seed/docs/PROJECT_REQUIREMENTS.md"
  git -C "$seed" init -q -b main
  git -C "$seed" config user.name "Planning Review Test"
  git -C "$seed" config user.email "planning-review-test@example.com"
  git -C "$seed" add .
  git -C "$seed" commit -qm "Seed"
  git init -q --bare -b main "$remote"
  git -C "$seed" push -q "$remote" main
  git clone -q "$remote" "$repo"
  git -C "$repo" config user.name "Planning Review Test"
  git -C "$repo" config user.email "planning-review-test@example.com"
  git -C "$repo" switch -q -c planning/project-bootstrap

  printf 'A recipe organizer that works offline.\n' >"$repo/docs/PROJECT_DESCRIPTION.md"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n\n## MVP scope\n\nOffline recipes.\n' \
    >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  mkdir -p "$repo/docs/decisions"
  printf '# ADR 001: Local storage\n' >"$repo/docs/decisions/001-local-storage.md"

  printf '%s\n' "$repo"
}

run_review() {
  local repo="$1"
  shift

  (
    cd "$repo"
    PATH="$tmp/bin:$ISOLATED_PATH" MOCK_AGENT_LOG="$repo.log" ./scripts/review-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_no_review() {
  local repo="$1"
  local description="$2"
  shift 2

  if run_review "$repo" "$@"; then
    cat "$repo.out" >&2
    fail "expected failure: $description"
  fi
  if compgen -G "$repo/.agents/reviews/*.json" >/dev/null; then
    fail "a review was stored although: $description"
  fi
  [[ ! -e "$repo.log" ]] || fail "a reviewer was started although: $description"
}

# A planning review covers exactly the planning documents, runs read-only, and
# is stored as a planning review without an Issue.
repo="$(setup_repo review)"
run_review "$repo" || {
  cat "$repo.out" >&2
  fail "planning review failed"
}
artifact="$repo/.agents/reviews/planning-project-bootstrap-review-01"
[[ -f "$artifact.json" && -f "$artifact.md" ]] || fail "the planning review and its report were not stored"
[[ "$(jq -c '[.kind, .issue, .branch, .round]' "$artifact.json")" == '["planning",null,"planning/project-bootstrap",1]' ]] ||
  fail "the planning review metadata is wrong"
[[ "$(jq -c '.reviewed_paths' "$artifact.json")" == \
  '["docs/PROJECT_DESCRIPTION.md","docs/changes","docs/PROJECT_REQUIREMENTS.md","docs/architecture.md","docs/roadmap.md","docs/decisions"]' ]] ||
  fail "the reviewed scope is wrong"
grep -Fq "# ADR 001: Local storage" "$repo.log.stdin" || fail "the ADR was not supplied"
grep -Fq -- "-Template." "$repo.log.stdin" || fail "the diff does not show replaced template content"
grep -Fq -- "--tools Read,Glob,Grep" "$repo.log" || fail "the planning reviewer was not read-only"
grep -Fq -- "--model model-p" "$repo.log" || fail "the configured planning reviewer was not used"
grep -Fq "A recipe organizer that works offline." "$repo.log.stdin" || fail "the description was not supplied"
grep -Fq "+Local storage." "$repo.log.stdin" || fail "the diff against origin/main was not supplied"
grep -Fq "Planning Review" "$artifact.md" || fail "the report does not identify a planning review"

# Only planning documents make the review stale.
(cd "$repo" && ./scripts/check-review.sh "$artifact.json" >/dev/null) || fail "a fresh planning review is not current"
printf 'Unrelated change.\n' >>"$repo/AGENTS.md"
(cd "$repo" && ./scripts/check-review.sh "$artifact.json" >/dev/null) || fail "an unrelated change made the planning review stale"
expect_stale() {
  local status=0
  (cd "$repo" && ./scripts/check-review.sh "$artifact.json" >/dev/null) || status=$?
  [[ "$status" -eq 1 ]] || fail "$1 did not make the planning review stale"
}
cp "$repo/docs/roadmap.md" "$tmp/roadmap.saved"
printf '\n## F02 — Offline use\n' >>"$repo/docs/roadmap.md"
expect_stale "a roadmap change"
cp "$tmp/roadmap.saved" "$repo/docs/roadmap.md"
printf '# ADR 002: Sync\n' >"$repo/docs/decisions/002-sync.md"
expect_stale "a new ADR"
rm "$repo/docs/decisions/002-sync.md"
mv "$repo/docs/PROJECT_DESCRIPTION.md" "$tmp/description.saved"
expect_stale "a removed description"
mv "$tmp/description.saved" "$repo/docs/PROJECT_DESCRIPTION.md"
(cd "$repo" && ./scripts/check-review.sh "$artifact.json" >/dev/null) ||
  fail "restoring the planning documents did not make the review current again"
printf '\n## F02 — Offline use\n' >>"$repo/docs/roadmap.md"

# A second round references the previous one.
run_review "$repo" --agent codex --model model-c || {
  cat "$repo.out" >&2
  fail "planning re-review failed"
}
[[ "$(jq '.round' "$repo/.agents/reviews/planning-project-bootstrap-review-02.json")" -eq 2 ]] ||
  fail "the re-review was not numbered"
grep -Fq "planning-project-bootstrap-review-01.json" "$repo.log" || fail "the re-review did not reference the previous review"

# A planning review is triaged as a planning triage (Issue 538), only while
# it is current: the stale round 1 is refused with the next step.
if (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/triage-review.sh "$artifact.json" --agent claude --model model-t </dev/null) >"$repo.triage.out" 2>&1; then
  fail "a stale planning review was triaged"
fi
grep -Fq "the planning review is stale" "$repo.triage.out" && grep -Fq "review-planning.sh" "$repo.triage.out" ||
  { cat "$repo.triage.out" >&2; fail "triage-review.sh did not point to a new planning review"; }

# The base comes from lib/base.sh: the one that start-planning.sh recorded
# for the planning branch. The diff is against origin/develop, not main.
repo="$(setup_repo develop-base)"
git clone -q "$tmp/develop-base-remote.git" "$tmp/develop-base-other"
printf '# Architecture\n\nDevelop only.\n' >"$tmp/develop-base-other/docs/architecture.md"
git -C "$tmp/develop-base-other" -c user.name=Other -c user.email=other@example.com commit -qam "Work on develop"
git -C "$tmp/develop-base-other" push -q origin HEAD:develop
git -C "$repo" fetch -q origin
git -C "$repo" reset -q --soft origin/develop
git -C "$repo" config branch.planning/project-bootstrap.workflow-base develop
run_review "$repo" || {
  cat "$repo.out" >&2
  fail "a planning review against the recorded base develop failed"
}
[[ "$(jq -r '.base' "$repo/.agents/reviews/planning-project-bootstrap-review-01.json")" == origin/develop ]] ||
  fail "the planning review does not record the base origin/develop"
grep -Fq -- "-Develop only." "$repo.log.stdin" || fail "the diff is not against origin/develop"
grep -Fq "Diff of the planning documents against origin/develop" "$repo.log.stdin" ||
  fail "the reviewer was not told the diff is against origin/develop"

# A planning document deleted relative to the base appears in the reviewer's diff.
repo="$(setup_repo deleted-adr)"
git -C "$repo" add -A
git -C "$repo" commit -qm "Planning so far"
git -C "$repo" push -q origin HEAD:main
git -C "$repo" fetch -q origin
git -C "$repo" rm -q docs/decisions/001-local-storage.md
run_review "$repo" || {
  cat "$repo.out" >&2
  fail "planning review after deleting an ADR failed"
}
grep -Fq "deleted file mode" "$repo.log.stdin" || fail "a deleted ADR was not shown to the reviewer"
grep -Fq -- "-# ADR 001: Local storage" "$repo.log.stdin" || fail "the deleted ADR content was not shown"

# Preconditions fail before a reviewer starts.
repo="$(setup_repo not-planning)"
git -C "$repo" switch -q -c feature/1-x
expect_no_review "$repo" "the branch is not a planning branch"

repo="$(setup_repo unapproved)"
printf '# Project Requirements\n\nStatus: Draft\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
expect_no_review "$repo" "the requirements are not approved"

repo="$(setup_repo missing-roadmap)"
rm "$repo/docs/roadmap.md"
expect_no_review "$repo" "the roadmap is missing"

# In a change cycle the reviewer gets the change request of the branch and is
# told that it reviews a change. The change request is part of what the review
# covers, so changing it afterwards makes the review stale.
repo="$(setup_repo change-cycle)"
mkdir -p "$repo/docs/changes"
printf 'Add a shopping list.\n' >"$repo/docs/changes/project-bootstrap.md"
printf 'An older, unrelated change.\n' >"$repo/docs/changes/earlier.md"
run_review "$repo" || {
  cat "$repo.out" >&2
  fail "the review of a change cycle failed"
}
grep -Fq "## docs/changes/project-bootstrap.md" "$repo.log.stdin" || fail "the change request was not supplied"
grep -Fq "Add a shopping list." "$repo.log.stdin" || fail "the content of the change request was not supplied"
grep -Fq "This is a change cycle" "$repo.log" || fail "the reviewer was not told that this is a change cycle"
artifact="$repo/.agents/reviews/planning-change-cycle-review-01"
review="$(ls "$repo"/.agents/reviews/planning-*-review-01.json)"
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || fail "a fresh change review is not current"
printf 'And sort it by shop.\n' >>"$repo/docs/changes/project-bootstrap.md"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null 2>&1) || status=$?
[[ "$status" -eq 1 ]] || fail "changing the change request did not make the review stale"

repo="$(setup_repo no-change-cycle)"
run_review "$repo" || fail "a first planning review failed"
if grep -Fq "This is a change cycle" "$repo.log"; then fail "a first planning was reviewed as a change cycle"; fi

# The reviewer of a later round receives the owner's decisions on escalated
# findings (finish-planning.sh --resolve, the owner's exception records of
# kind planning), with the planning documents that
# changed since each; a decision that is no longer valid is left out.
repo="$(setup_repo decisions)"
run_review "$repo" || { cat "$repo.out" >&2; fail "the first round failed"; }
if grep -Fq "The owner's decisions on earlier findings" "$repo.log.stdin"; then
  fail "a first round was given decisions that do not exist"
fi
review="$repo/.agents/reviews/planning-project-bootstrap-review-01.json"
# A decision resolves a minor finding only.
jq '.findings[0].severity = "minor"' "$review" >"$repo.review.tmp"
mv "$repo.review.tmp" "$review"
mkdir -p "$repo/.agents/exceptions"
jq --arg sha "$(sha256sum "$review" | cut -c1-64)" '{
  schema: "exception/v1", kind: "planning", type: "not-applicable", reason: "Offline use is the whole product.",
  evidence: null, account: "owner-login", directed_at: "2026-01-02T00:00:00Z",
  review: ".agents/reviews/planning-project-bootstrap-review-01.json", review_sha256: $sha, round,
  finding_id: "M1", finding_title: .findings[0].title, finding_severity: "minor",
  reviewed_tree, merge_base, planner_rationale: "Needs the owner."}' "$review" \
  >"$repo/.agents/exceptions/planning-project-bootstrap-review-01-M1.json"
jq '.reason = "" | .finding_id = "M2"' "$repo/.agents/exceptions/planning-project-bootstrap-review-01-M1.json" \
  >"$repo/.agents/exceptions/planning-project-bootstrap-review-01-M2.json"
printf '\n## F02 — Sharing\n' >>"$repo/docs/roadmap.md"
rm -f "$repo.log" "$repo.log.stdin"
run_review "$repo" || { cat "$repo.out" >&2; fail "the round after a decision failed"; }
grep -Fq "## The owner's decisions on earlier findings" "$repo.log.stdin" || fail "the reviewer did not receive the decisions"
grep -Fq "Round 1, M1 [minor] Roadmap omits offline use" "$repo.log.stdin" || fail "the decision does not name its finding"
grep -Fq "Decision: not-applicable" "$repo.log.stdin" && grep -Fq "Reason: Offline use is the whole product." "$repo.log.stdin" ||
  fail "the decision lacks its type or reason"
grep -Fq "Planning documents changed since the decision: docs/roadmap.md" "$repo.log.stdin" ||
  fail "the reviewer was not told what changed since the decision: $(cat "$repo.log.stdin")"
grep -Fq '"Owner decisions" rules' "$repo.log" || fail "the reviewer was not pointed to the rules for decisions"
if grep -Fq "Round 1, M2" "$repo.log.stdin"; then fail "an invalid decision was given to the reviewer"; fi
grep -Fq "Ignored the decision .agents/exceptions/planning-project-bootstrap-review-01-M2.json" "$repo.out" ||
  fail "the invalid decision was not reported"

echo "review-planning tests passed"
