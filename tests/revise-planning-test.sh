#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/revise-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "revise-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

review=".agents/reviews/planning-project-bootstrap-review-01.json"
revision=".agents/reviews/planning-project-bootstrap-review-01-revision"
valid_decisions='{"decisions": [
  {"finding_id": "M1", "decision": "ADOPT", "rationale": "Offline use is an MVP requirement."},
  {"finding_id": "MIN1", "decision": "REJECT", "rationale": "The name follows the requirements."},
  {"finding_id": "S1", "decision": "ESCALATE", "rationale": "Sharing scope is a product decision."}
]}'
export MOCK_OUTPUT="$valid_decisions"

# Creates a planning repository with a current planning review of round 1.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/.agents/reviews"
  copy_workflow "$repo"
  printf 'project-planner: claude model-p\n' >"$repo/.agents/agents.conf"
  printf '# Agents\n' >"$repo/AGENTS.md"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n\n## MVP scope\n\nOffline recipes.\n' \
    >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Revise Test"
  git -C "$repo" config user.email "revise-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c planning/project-bootstrap

  jq -n '{
    schema: "review/v1", kind: "planning", issue: null, round: 1,
    branch: "planning/project-bootstrap", base: "origin/main", merge_base: "aaaa", head: "bbbb",
    reviewed_tree: "", reviewed_paths: ["docs/PROJECT_DESCRIPTION.md", "docs/changes", "docs/PROJECT_REQUIREMENTS.md", "docs/architecture.md", "docs/roadmap.md", "docs/decisions"],
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: "CHANGES_REQUIRED", limitations: "",
    findings: [
      {id: "M1", severity: "major", title: "Offline use is unplanned", evidence: "docs/roadmap.md", impact: "An MVP requirement is missing.", recommendation: "Add a feature for offline use."},
      {id: "MIN1", severity: "minor", title: "Feature name is vague", evidence: "docs/roadmap.md, F01", impact: "Readability.", recommendation: "Rename F01."},
      {id: "S1", severity: "suggestion", title: "Consider sharing", evidence: "docs/roadmap.md", impact: "Households share recipes.", recommendation: "Add sharing."}
    ]
  }' >"$repo/$review"
  record_reviewed_tree "$repo" "$repo/$review"

  printf '%s\n' "$repo"
}

run_revise() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" |
      PATH="$tmp/bin:/usr/bin:/bin" MOCK_AGENT_LOG="$repo.log" ./scripts/revise-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

write_sessions() {
  grep -c -- "--permission-mode acceptEdits" "$1.log" 2>/dev/null || true
}

add_offline_feature="printf '\\n## F02 — Offline use\\n\\n- Goal: work offline.\\n' >>docs/roadmap.md"

# The planner decides read-only; after approval the decisions are recorded and
# a write session revises exactly the adopted findings.
repo="$(setup_repo revise)"
MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "revising the planning failed"
}
[[ -f "$repo/$revision.json" && -f "$repo/$revision.md" ]] || fail "the revision and its report were not recorded"
[[ "$(jq -c '[.schema, .review_round, (.decisions | map(.decision))]' "$repo/$revision.json")" == \
  '["revision/v1",1,["ADOPT","REJECT","ESCALATE"]]' ]] || fail "the recorded decisions are wrong"
grep -Fq -- "--tools Read,Glob,Grep" "$repo.log" || fail "the planner did not decide read-only"
grep -Fq -- "--json-schema" "$repo.log" || fail "the planner was not given the revision schema"
[[ "$(write_sessions "$repo")" -eq 1 ]] || fail "exactly one write session was expected"
grep -Fq "M1. Offline use is unplanned" "$repo.log" || fail "the adopted finding was not passed to the planner"
if grep -Fq "Feature name is vague" "$repo.log" || grep -Fq "Consider sharing" "$repo.log"; then
  fail "a finding that was not adopted was passed to the write session"
fi
grep -Fq "F02 — Offline use" "$repo/docs/roadmap.md" || fail "the revision did not reach the roadmap"
grep -Fq "Escalated findings need your decision" "$repo.out" || fail "the escalated finding was not reported"
status=0
(cd "$repo" && ./scripts/check-review.sh "$review" >/dev/null) || status=$?
[[ "$status" -eq 1 ]] || fail "the planning review is not stale after the revision"

# A revised review cannot be revised again; the next step is a new review.
if run_revise "$repo" y --review "$review"; then
  fail "an already revised review was revised again"
fi
grep -Fq "review-planning.sh" "$repo.out" || fail "the next review round was not suggested"

# A revision is decided by you, so it cannot run unattended.
repo="$(setup_repo unattended)"
if run_revise "$repo" y --review "$review" --unattended; then fail "a revision ran unattended"; fi
grep -Fq "cannot run with --unattended" "$repo.out" || fail "the refusal of an unattended revision gave no reason"
[[ ! -e "$repo.log" ]] || fail "an agent started for an unattended revision"

# Declining records nothing and changes nothing.
repo="$(setup_repo decline)"
run_revise "$repo" n --review "$review" || fail "declining returned an error"
[[ ! -e "$repo/$revision.json" ]] || fail "declined decisions were recorded"
[[ "$(write_sessions "$repo")" -eq 0 ]] || fail "a write session started after declining"

# Invalid decisions are retried once and then rejected before anything is recorded.
# One invalid result per rule, each derived from the valid decisions.
for invalid in \
  "not json" \
  '{"decisions": {}}' \
  "$(jq '.decisions[0].decision = "REJECT"' <<<"$valid_decisions")" \
  "$(jq '.decisions[0].decision = "DEFER"' <<<"$valid_decisions")" \
  "$(jq 'del(.decisions[2])' <<<"$valid_decisions")" \
  "$(jq '.decisions += [.decisions[1]]' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].finding_id = "MIN9"' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].decision = "LATER"' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].rationale = ""' <<<"$valid_decisions")" \
  "$(jq '.decisions[1].severity = "minor"' <<<"$valid_decisions")"; do
  repo="$(setup_repo "invalid-$(grep -c . "$tmp/invalid-count" 2>/dev/null || true)")"
  echo x >>"$tmp/invalid-count"
  if MOCK_OUTPUT="$invalid" run_revise "$repo" y --review "$review"; then
    fail "invalid revision decisions were accepted"
  fi
  [[ ! -e "$repo/$revision.json" ]] || fail "invalid decisions were recorded"
  [[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "invalid decisions were not retried exactly once"
done

# The write session may change only the architecture, roadmap, and ADRs.
for action in \
  "printf 'changed\\n' >>docs/PROJECT_REQUIREMENTS.md" \
  "printf 'changed\\n' >>AGENTS.md" \
  "printf 'x\\n' >.env" \
  "printf 'x\\n' >>$revision.json" \
  "printf 'x\\n' >docs/decisions/tool.sh" \
  "git add -A && git commit -qm 'Agent must not commit'"; do
  repo="$(setup_repo "scope-$(grep -c . "$tmp/scope-count" 2>/dev/null || true)")"
  echo x >>"$tmp/scope-count"
  if MOCK_WRITE_ACTION="$add_offline_feature; $action" run_revise "$repo" y --review "$review"; then
    fail "an out-of-scope change was accepted: $action"
  fi
  grep -Fq "preserved" "$repo.out" || fail "a scope violation did not preserve the worktree: $action"
done

# A minor finding may be deferred.
repo="$(setup_repo defer)"
MOCK_OUTPUT="$(jq '.decisions[1].decision = "DEFER"' <<<"$valid_decisions")" \
  MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "deferring a minor finding was rejected"
}

# A write session that changes nothing does not count as a revision; the
# approved decisions stay for a retry.
repo="$(setup_repo no-op)"
if run_revise "$repo" y --review "$review"; then
  fail "a write session without changes was reported as a revision"
fi
grep -Fq "changed no planning document" "$repo.out" || fail "an empty revision was not reported"
[[ -f "$repo/$revision.json" ]] || fail "the approved decisions were lost after an empty revision"

# A failed write session keeps the approved decisions; while the review is
# still current, a re-run applies them without deciding again.
repo="$(setup_repo resume)"
if MOCK_WRITE_EXIT=5 run_revise "$repo" y --review "$review"; then
  fail "a failed planner returned success"
fi
[[ -f "$repo/$revision.json" ]] || fail "the approved decisions were lost after a failed write session"
rm "$repo.log"
MOCK_WRITE_ACTION="$add_offline_feature" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "resuming the revision failed"
}
[[ "$(grep -c '^AGENT=' "$repo.log")" -eq 1 ]] || fail "resuming decided again instead of applying the recorded decisions"

# Without adopted findings no document is changed.
repo="$(setup_repo nothing-adopted)"
MOCK_OUTPUT="$(jq '.decisions[0].decision = "ESCALATE"' <<<"$valid_decisions")" run_revise "$repo" y --review "$review" || {
  cat "$repo.out" >&2
  fail "a revision without adopted findings failed"
}
[[ "$(write_sessions "$repo")" -eq 0 ]] || fail "a write session started without adopted findings"

# AMEND: a finding caused by the approved requirements. The planner proposes
# a diff of them; it is applied only after the owner confirms it at a
# terminal, and only that diff.
amend_diff='--- a/docs/PROJECT_REQUIREMENTS.md
+++ b/docs/PROJECT_REQUIREMENTS.md
@@ -7,3 +7,3 @@
 ## MVP scope
 
-Offline recipes.
+Offline recipes, stored on the device.
'
amend_decisions="$(jq --arg diff "$amend_diff" '
  .decisions[0] = {finding_id: "M1", decision: "AMEND", amendment: $diff,
                   rationale: "The requirements leave the storage of offline recipes open."}' <<<"$valid_decisions")"
align_roadmap="printf '\\n## F02 — Offline storage\\n\\n- Goal: store recipes on the device.\\n' >>docs/roadmap.md"

# at_terminal <repo> <answers> <argument>...: revise-planning.sh at a
# pseudo-terminal, answering one line per question. A refusal inside the
# terminal does not reach the exit status of every 'script', so the tests
# check what was stored.
at_terminal() {
  local repo="$1"
  local answers="$2"
  local command

  shift 2
  command="cd $(printf '%q' "$repo") && PATH=$(printf '%q' "$tmp/bin:/usr/bin:/bin") MOCK_AGENT_LOG=$(printf '%q' "$repo.log") ./scripts/revise-planning.sh $(printf '%q ' "$@")"
  if script --version 2>/dev/null | grep -q util-linux; then
    printf '%s' "$answers" | script -qec "$command" /dev/null >"$repo.out" 2>&1 || true
  else
    printf '%s' "$answers" | script -q /dev/null sh -c "$command" >"$repo.out" 2>&1 || true
  fi
}

requirements_blob() {
  git -C "$1" hash-object docs/PROJECT_REQUIREMENTS.md
}

# Accept: the diff is applied exactly, Approved at is updated, the revision
# records the owner's confirmation, and the same write session aligns the
# planning documents.
repo="$(setup_repo amend-accept)"
original="$(cat "$repo/docs/PROJECT_REQUIREMENTS.md")"
MOCK_OUTPUT="$amend_decisions" MOCK_WRITE_ACTION="$align_roadmap" at_terminal "$repo" $'y\ny\n' --review "$review"
[[ -f "$repo/$revision.json" ]] || { cat "$repo.out" >&2; fail "an accepted amendment recorded no revision"; }
grep -Fq "Apply this change to the approved requirements? [y/N]" "$repo.out" || fail "the amendment was not asked separately"
grep -Fq -- "+Offline recipes, stored on the device." "$repo.out" || fail "the diff was not shown before the question"
expected="$(printf '%s\n' "$original" | sed 's/^Offline recipes\.$/Offline recipes, stored on the device./')"
[[ "$(sed '/^Approved at: /d' "$repo/docs/PROJECT_REQUIREMENTS.md")" == "$(printf '%s\n' "$expected" | sed '/^Approved at: /d')" ]] ||
  fail "the requirements are not exactly the amended ones: $(cat "$repo/docs/PROJECT_REQUIREMENTS.md")"
grep -Fqx "Status: Approved" "$repo/docs/PROJECT_REQUIREMENTS.md" || fail "the amended requirements are no longer approved"
grep -Eq '^Approved at: 20[0-9]{2}-' "$repo/docs/PROJECT_REQUIREMENTS.md" &&
  ! grep -Fqx "Approved at: 2026-01-01T00:00:00Z" "$repo/docs/PROJECT_REQUIREMENTS.md" ||
  fail "Approved at was not updated for the amendment"
[[ "$(jq -r '.decisions[0] | [.decision, .amendment.confirmed_by, .amendment.diff == $diff] | @tsv' \
  --arg diff "$amend_diff" "$repo/$revision.json")" == $'AMEND\towner\ttrue' ]] ||
  fail "the revision does not record the owner's confirmation of exactly the diff"
[[ "$(jq -r '.amended_requirements.after' "$repo/$revision.json")" == "$(requirements_blob "$repo")" ]] ||
  fail "the revision does not name the amended requirements"
(source "$repo/scripts/lib/review-data.sh" && [[ -z "$(revision_artifact_errors "$repo/$revision.json" "$repo/$review")" ]]) ||
  fail "the recorded revision with an amendment is invalid"
grep -Fq "Requirements amended with the owner's confirmation" "$repo/$revision.md" || fail "the report does not list the amendment"
[[ "$(write_sessions "$repo")" -eq 1 ]] || fail "the amendment did not lead to one write session"
grep -Fq "Align the architecture, the" "$repo.log" || fail "the write session was not asked to align with the amended requirements"
grep -Fq "F02 — Offline storage" "$repo/docs/roadmap.md" || fail "the write session did not align the roadmap"

# A recorded amendment is the owner's: one without confirmation is invalid.
jq '.decisions[0].amendment.confirmed_by = "planner"' "$repo/$revision.json" >"$tmp/forged.json"
(source "$repo/scripts/lib/review-data.sh" && revision_artifact_errors "$tmp/forged.json" "$repo/$review") |
  grep -Fq "no confirmation by the owner" || fail "an amendment without the owner's confirmation was valid"

# A failed write session after the amendment: the decisions and the amended
# requirements stay, and a re-run aligns the planning without asking again.
repo="$(setup_repo amend-resume)"
MOCK_OUTPUT="$amend_decisions" MOCK_WRITE_EXIT=5 at_terminal "$repo" $'y\ny\n' --review "$review"
[[ -f "$repo/$revision.json" ]] || { cat "$repo.out" >&2; fail "the amendment was lost after a failed write session"; }
amended_blob="$(requirements_blob "$repo")"
rm -f "$repo.log"
MOCK_WRITE_ACTION="$align_roadmap" run_revise "$repo" "" --review "$review" || {
  cat "$repo.out" >&2
  fail "resuming a revision with an amendment failed"
}
[[ "$(grep -c '^AGENT=' "$repo.log")" -eq 1 ]] || fail "resuming decided again instead of applying the recorded decisions"
[[ "$(requirements_blob "$repo")" == "$amended_blob" ]] || fail "resuming changed the amended requirements"

# Decline: the requirements stay as they are and the finding stays escalated.
repo="$(setup_repo amend-decline)"
before="$(requirements_blob "$repo")"
MOCK_OUTPUT="$amend_decisions" MOCK_WRITE_ACTION="$add_offline_feature" at_terminal "$repo" $'y\nn\n' --review "$review"
[[ -f "$repo/$revision.json" ]] || { cat "$repo.out" >&2; fail "the decisions were not recorded after declining the amendment"; }
[[ "$(requirements_blob "$repo")" == "$before" ]] || fail "a declined amendment changed the requirements"
[[ "$(jq -r '.decisions[0] | [.decision, has("amendment")] | @tsv' "$repo/$revision.json")" == $'ESCALATE\tfalse' ]] ||
  fail "a declined amendment did not leave the finding escalated"
jq -e 'has("amended_requirements") | not' "$repo/$revision.json" >/dev/null || fail "a declined amendment named amended requirements"
grep -Fq "Escalated findings need your decision" "$repo.out" || fail "the declined amendment was not reported as escalated"
[[ "$(write_sessions "$repo")" -eq 0 ]] || fail "a write session started without adopted or amended findings"

# A diff that does not apply cleanly is an invalid decision: retried once and
# refused, before anything is asked or recorded. Each case: the reason, then
# the decisions.
amend_invalid() {
  printf '%s\t%s\n' "$1" "$(jq -c "$2" <<<"$amend_decisions")"
}
while IFS=$'\t' read -r reason invalid; do
  repo="$(setup_repo "amend-invalid-$(grep -c . "$tmp/amend-count" 2>/dev/null || true)")"
  echo x >>"$tmp/amend-count"
  before="$(requirements_blob "$repo")"
  MOCK_OUTPUT="$invalid" at_terminal "$repo" $'y\ny\n' --review "$review"
  [[ ! -e "$repo/$revision.json" ]] || fail "an invalid amendment was recorded: $invalid"
  [[ "$(requirements_blob "$repo")" == "$before" ]] || fail "an invalid amendment changed the requirements"
  [[ "$(grep -c '^AGENT=' "$repo.log")" -eq 2 ]] || fail "an invalid amendment was not retried exactly once"
  grep -Fq "$reason" "$repo.out" || fail "an invalid amendment was not refused with '$reason': $(cat "$repo.out")"
done < <(
  amend_invalid "does not apply cleanly" '.decisions[0].amendment |= sub("-Offline recipes."; "-Online recipes.")'
  amend_invalid "and nothing else" '.decisions[0].amendment |= gsub("PROJECT_REQUIREMENTS"; "PROJECT_DESCRIPTION")'
  amend_invalid "must not change the Status or Approved at line" \
    '.decisions[0].amendment = "--- a/docs/PROJECT_REQUIREMENTS.md\n+++ b/docs/PROJECT_REQUIREMENTS.md\n@@ -3,2 +3,2 @@\n-Status: Approved\n+Status: Draft\n Approved at: 2026-01-01T00:00:00Z\n"'
  amend_invalid "not a valid diff" '.decisions[0].amendment = "Store recipes on the device."'
  amend_invalid "needs a diff of the requirements" '.decisions[0].amendment = null'
  amend_invalid "must not have an amendment" '.decisions[1].amendment = .decisions[0].amendment'
)

# Without a terminal an amendment is not asked and nothing is recorded.
repo="$(setup_repo amend-no-terminal)"
before="$(requirements_blob "$repo")"
if MOCK_OUTPUT="$amend_decisions" run_revise "$repo" y --review "$review"; then
  fail "an amendment was accepted without a terminal"
fi
grep -Fq "must be a terminal" "$repo.out" || fail "the refusal without a terminal does not say why"
[[ ! -e "$repo/$revision.json" && "$(requirements_blob "$repo")" == "$before" ]] ||
  fail "something was recorded for an amendment without a terminal"

# A stale review is refused even when it has no findings.
repo="$(setup_repo stale-empty)"
jq '.verdict = "PASS" | .findings = []' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
printf '\nChanged.\n' >>"$repo/docs/roadmap.md"
if run_revise "$repo" y --review "$review"; then
  fail "a stale review without findings was accepted"
fi

# Stale, foreign, and misplaced reviews fail before an agent starts.
repo="$(setup_repo stale)"
printf '\nChanged.\n' >>"$repo/docs/architecture.md"
if run_revise "$repo" y --review "$review"; then
  fail "a stale planning review was revised"
fi
[[ ! -e "$repo.log" ]] || fail "an agent started for a stale review"

repo="$(setup_repo feature-review)"
jq '.kind = "feature" | .issue = 3 | .reviewed_paths = null' "$repo/$review" >"$repo/$review.tmp"
mv "$repo/$review.tmp" "$repo/$review"
if run_revise "$repo" y --review "$review"; then
  fail "a feature review was revised as planning"
fi

repo="$(setup_repo not-planning)"
git -C "$repo" switch -q -c feature/1-x
if run_revise "$repo" y --review "$review"; then
  fail "revision ran outside a planning worktree"
fi
[[ ! -e "$repo.log" ]] || fail "an agent started despite failed preconditions"

echo "revise-planning tests passed"
