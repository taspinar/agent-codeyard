#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/finish-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "finish-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"
# A fake GitHub CLI that names the account of a decision (--resolve).
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api user") echo "owner-login" ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

reviews=".agents/reviews"
counter=0

# Creates a planning repository. Review rounds are added with add_review.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/$reviews"
  copy_workflow "$repo"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  # Git ignores the owner's decisions, as the template's .gitignore does.
  printf '.agents/exceptions/\n' >"$repo/.gitignore"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Finish Test"
  git -C "$repo" config user.email "finish-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c planning/project-bootstrap

  printf '%s\n' "$repo"
}

# add_review <repo> <round> <verdict> <findings-json>
add_review() {
  local repo="$1"
  local review
  review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  jq -n --argjson round "$2" --arg verdict "$3" --argjson findings "$4" '{
    schema: "review/v1", kind: "planning", issue: null, round: $round,
    branch: "planning/project-bootstrap", base: "origin/main", merge_base: "aaaa", head: "bbbb",
    reviewed_tree: "", reviewed_paths: ["docs/PROJECT_DESCRIPTION.md", "docs/changes", "docs/PROJECT_REQUIREMENTS.md", "docs/architecture.md", "docs/roadmap.md", "docs/decisions"],
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: $verdict, limitations: "", findings: $findings
  }' >"$review"
  record_reviewed_tree "$repo" "$review"
}

# add_triage <repo> <round> <decision-for-each-finding>: the approved planning
# triage of the review of that round (triage-review.sh, kind planning).
add_triage() {
  local repo="$1"
  local review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  mkdir -p "$repo/.agents/triage"
  jq --arg decision "$3" '{
    schema: "triage/v1", kind: "planning",
    source_review: ".agents/reviews/planning-project-bootstrap-review-\(.round | tostring | if length == 1 then "0" + . else . end).json",
    branch, round, reviewed_tree, review_verdict: .verdict,
    triage: {agent: "claude", model: "model-t", mode: "full"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title, decision: $decision, rationale: "Considered.", followup: null}]
  }' "$review" >"$(triage_file "$repo" "$2")"
}

# triage_file <repo> <round>: where the triage of that round is stored.
triage_file() {
  printf '%s/.agents/triage/planning-project-bootstrap-review-%02d-triage.json\n' "$1" "$2"
}

finding() {
  printf '{"id": "%s", "severity": "%s", "title": "%s", "evidence": "docs/roadmap.md", "impact": "Impact.", "recommendation": "Change it."}' "$1" "$2" "$3"
}

run_finish() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" | PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_refused() {
  local repo="$1"
  local description="$2"

  if run_finish "$repo" y; then
    cat "$repo.out" >&2
    fail "expected refusal: $description"
  fi
  [[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded although: $description"
}

check_status() {
  local status=0
  (cd "$1" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check >/dev/null 2>&1) || status=$?
  echo "$status"
}

# A planning document that an adoption reconstructed carries the mark
# 'Observed, not approved' until the planning approves it: a reviewed
# planning that still carries it is not approved.
repo="$(setup_repo observed)"
printf '# Architecture\n\n> **Observed, not approved.** Reconstructed by adopt-repository.sh.\n\nLocal storage.\n' >"$repo/docs/architecture.md"
add_review "$repo" 1 PASS "[]"
expect_refused "$repo" "a planning document still carries the mark of a reconstruction"
grep -Fq "docs/architecture.md" "$repo.out" && grep -Fq "Observed, not approved" "$repo.out" ||
  fail "the refusal does not name the marked document: $(cat "$repo.out")"
printf '# Architecture\n\nLocal storage, as the planner confirmed it.\n' >"$repo/docs/architecture.md"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || { cat "$repo.out" >&2; fail "a planning without the mark was not approved"; }

# An amendment of the requirements that the owner confirmed in a planning triage
# is listed in the approval with its finding and the confirmation, and not
# as a finding that was not adopted.
repo="$(setup_repo amended)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Cost is not capped")]"
add_triage "$repo" 1 AMEND
amend_diff=$'--- a/docs/PROJECT_REQUIREMENTS.md\n+++ b/docs/PROJECT_REQUIREMENTS.md\n@@ -1,1 +1,1 @@\n-# Project Requirements\n+# Project Requirements (cost limited)\n'
jq --arg diff "$amend_diff" '
  .decisions[0].amendment = {diff: $diff, confirmed_by: "owner", confirmed_at: "2026-01-02T00:00:01Z"}
  | .amended_requirements = {before: ("a" * 40), after: ("b" * 40)}' \
  "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
sed -i.bak '1s/.*/# Project Requirements (cost limited)/' "$repo/docs/PROJECT_REQUIREMENTS.md" && rm "$repo/docs/PROJECT_REQUIREMENTS.md.bak"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a planning with an amendment of the requirements failed"
}
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "## Requirements amended with the owner's confirmation" "$approval" || fail "the approval does not list the amendments"
grep -Fq "Round 1: M1 [major] Cost is not capped. Considered. Confirmed by the project owner at 2026-01-02T00:00:01Z." "$approval" ||
  fail "the approval does not list the amendment with its finding and the confirmation: $(cat "$approval")"
grep -Fq "  +# Project Requirements (cost limited)" "$approval" || fail "the approval does not show the confirmed diff"
! grep -Fq "AMEND: M1" "$approval" || fail "an amended finding was listed as not adopted"

# A planning whose latest round passed is approved after confirmation; the
# approval lists the rounds and the findings that were not adopted.
repo="$(setup_repo approve)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned"), $(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 FIX_NOW
jq '.decisions[1].decision = "ACCEPT" | .decisions[1].rationale = "The name follows the requirements."' \
  "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
printf '\n## F02 — Offline use\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a passed planning failed"
}
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "Status: Approved" "$approval" || fail "the approval was not recorded"
grep -Eq '^Planning fingerprint: [0-9a-f]{40}$' "$approval" || fail "the approval lacks the planning fingerprint"
grep -Fq "Round 1, ACCEPT: MIN1 [minor] Vague name" "$approval" || fail "the approval lacks a rejected finding"
grep -Fq "Round 2: PASS" "$approval" || fail "the approval lacks the final round"
grep -Fq "Vague name" "$repo.out" || fail "a rejected finding was not shown before approval"
grep -Fq "git add docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions docs/PLANNING_APPROVAL.md" "$repo.out" ||
  fail "the commit step does not list the existing planning documents"
grep -Fq "Open the planning PR into main;" "$repo.out" || fail "the next steps do not name the base main"

# The base comes from lib/base.sh, as for a feature: the default of the
# project in .agents/template.conf, and the base that start-planning.sh
# recorded for the branch before that.
base_repo="$(setup_repo other-base)"
printf 'base: develop\n' >>"$base_repo/.agents/template.conf"
add_review "$base_repo" 1 PASS "[]"
run_finish "$base_repo" y || { cat "$base_repo.out" >&2; fail "approving a planning of a project with the base develop failed"; }
grep -Fq "Open the planning PR into develop;" "$base_repo.out" || fail "the next steps do not name the default base develop: $(cat "$base_repo.out")"
base_repo="$(setup_repo recorded-base)"
printf 'base: develop\n' >>"$base_repo/.agents/template.conf"
git -C "$base_repo" config branch.planning/project-bootstrap.workflow-base release
add_review "$base_repo" 1 PASS "[]"
run_finish "$base_repo" y || { cat "$base_repo.out" >&2; fail "approving a planning with a recorded base failed"; }
grep -Fq "Open the planning PR into release;" "$base_repo.out" || fail "the next steps do not name the recorded base release"
base_repo="$(setup_repo invalid-base)"
printf 'base: not..valid\n' >>"$base_repo/.agents/template.conf"
add_review "$base_repo" 1 PASS "[]"
expect_refused "$base_repo" "the default base of the project is not a valid branch name"
grep -Fq "not a valid branch name" "$base_repo.out" || fail "an invalid default base was not reported"

# --check reports a current approval, and a stale one after any planning change.
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh approval is not current"
printf 'Unrelated.\n' >"$repo/notes.txt"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "an unrelated change invalidated the approval"
printf '# ADR 001: Storage\n' >"$repo/docs/decisions/001-storage.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "a new ADR did not invalidate the approval"
rm "$repo/docs/decisions/001-storage.md"
printf 'Changed.\n' >>"$repo/docs/architecture.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an architecture change did not invalidate the approval"
repo_without="$(setup_repo no-approval)"
[[ "$(check_status "$repo_without")" -eq 1 ]] || fail "a missing approval was not reported"

# Minor findings that were all rejected or deferred can be approved.
repo="$(setup_repo minor-handled)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name"), $(finding S1 suggestion "Sharing")]"
add_triage "$repo" 1 DEFER
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving with deferred minor findings failed"
}

# Declining records nothing.
repo="$(setup_repo decline)"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" n || fail "declining returned an error"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "a declined approval was recorded"

# Refusals.
repo="$(setup_repo no-review)"
expect_refused "$repo" "there is no planning review"

repo="$(setup_repo stale)"
add_review "$repo" 1 PASS "[]"
printf 'Changed.\n' >>"$repo/docs/roadmap.md"
expect_refused "$repo" "the latest review is stale"

repo="$(setup_repo blocking)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned")]"
add_triage "$repo" 1 ESCALATE
expect_refused "$repo" "the latest review has a major finding"

repo="$(setup_repo undecided)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
expect_refused "$repo" "a minor finding has no approved triage"

repo="$(setup_repo not-applied)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 FIX_NOW
expect_refused "$repo" "a FIX_NOW finding is not applied"

repo="$(setup_repo escalated)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 ESCALATE
expect_refused "$repo" "a finding is escalated"
grep -Fq "Round 1, ESCALATE: MIN1 [minor] Vague name" "$repo.out" || fail "a refusal did not show the escalated finding"
grep -Fq "Rationale: Considered." "$repo.out" || fail "a refusal did not show the rationale"

# An escalation of an earlier round is not resolved by a newer review alone:
# the human confirms its resolution, and the approval records that.
repo="$(setup_repo earlier-escalation)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
printf 'Sharing is out of scope.\n' >>"$repo/docs/PROJECT_REQUIREMENTS.md"
add_review "$repo" 2 PASS "[]"
if run_finish "$repo" $'n\ny'; then
  fail "an earlier escalation that was not confirmed as resolved was approved"
fi
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded with an unresolved earlier escalation"
run_finish "$repo" $'y\ny' || {
  cat "$repo.out" >&2
  fail "approving after confirming an earlier escalation failed"
}
grep -Fq "## Escalations confirmed as resolved" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the confirmed resolution of an earlier escalation was not recorded"

# A planning document that changes while the approval question waits is not approved.
repo="$(setup_repo changes-during-approval)"
add_review "$repo" 1 PASS "[]"
mkfifo "$tmp/answer"
(
  cd "$repo"
  PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh <"$tmp/answer"
) >"$repo.out" 2>&1 &
finisher=$!
exec 3>"$tmp/answer"
for _ in $(seq 1 100); do
  grep -Fq "Approve this planning?" "$repo.out" 2>/dev/null && break
  sleep 0.1
done
printf 'Changed while deciding.\n' >>"$repo/docs/roadmap.md"
echo y >&3
exec 3>&-
status=0
wait "$finisher" || status=$?
[[ "$status" -ne 0 ]] || fail "a planning that changed during the approval question was approved"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded for a changed planning"

repo="$(setup_repo unapproved-requirements)"
add_review "$repo" 1 PASS "[]"
printf '# Project Requirements\n\nStatus: Draft\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
expect_refused "$repo" "the requirements are not approved"

repo="$(setup_repo not-planning)"
add_review "$repo" 1 PASS "[]"
git -C "$repo" switch -q -c feature/1-x
expect_refused "$repo" "the branch is not a planning branch"

# The approval of a change cycle records its change request, covers it, and
# names the commit after the change.
repo="$(setup_repo change-cycle)"
mkdir -p "$repo/docs/changes"
printf 'Add a shopping list.\n' >"$repo/docs/changes/project-bootstrap.md"
printf '\n## F02 — Shopping list\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a change cycle failed"
}
grep -Fqx "Change request: docs/changes/project-bootstrap.md" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the approval does not record the change request"
grep -Fq 'git commit -m "Plan change: project-bootstrap"' "$repo.out" || fail "the commit is not named after the change"
grep -Fq "docs/changes" "$repo.out" || fail "the commit step does not include the change request"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh change approval is not current"

# A later approval names what merged work changed in the architecture since
# the previous one, because it now covers those changes.
later="$(setup_repo later-approval)"
add_review "$later" 1 PASS "[]"
run_finish "$later" y || fail "the first approval failed"
git -C "$later" add -A
git -C "$later" commit -qm "Plan: first approval"
printf '\nThe list is stored locally.\n' >>"$later/docs/architecture.md"
git -C "$later" commit -qam "F03: describe where the list is stored" -m "Issue: #3" -m "Review: round 1, PASS, by codex (model-r)"
printf '\n## F09 — Another feature\n' >>"$later/docs/roadmap.md"
add_review "$later" 2 PASS "[]"
run_finish "$later" y || {
  cat "$later.out" >&2
  fail "the later approval failed"
}
grep -Fqx "## Updates by merged work" "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the later approval does not list the updates by merged work"
grep -Eq '^- [0-9a-f]+ F03: describe where the list is stored \(Issue #3; review: round 1, PASS, by codex \(model-r\)\)$' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the later approval does not name the feature, its Issue, and its review"

# A third approval keeps the entry of the second and adds its own.
git -C "$later" add -A
git -C "$later" commit -qm "Plan: second approval"
printf '\nThe list is sorted.\n' >>"$later/docs/architecture.md"
git -C "$later" commit -qam "F04: describe the order of the list" -m "Issue: #4"
printf '\n## F10 — One more\n' >>"$later/docs/roadmap.md"
add_review "$later" 3 PASS "[]"
run_finish "$later" y || fail "the third approval failed"
grep -Eq '^- [0-9a-f]+ F03: describe where the list is stored ' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the third approval dropped the entry of the second"
grep -Eq '^- [0-9a-f]+ F04: describe the order of the list \(Issue #4\)$' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the third approval lacks its own entry"
printf 'More.\n' >>"$repo/docs/changes/project-bootstrap.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "changing the change request did not invalidate the approval"

# An approval that an earlier version of the workflow amended lists the
# updates by merged work under "Amendments after the approval"; the next
# approval keeps them, under "Updates by merged work".
legacy="$(setup_repo legacy-amendment)"
printf '# Planning Approval\n\nStatus: Approved\nPlanning fingerprint: %s\n\n## Amendments after the approval\n\n- 2026-01-05T00:00:00Z: before the amendment below, merged work had updated the architecture or the ADRs since the approval, each change under its own review:\n  - abc1234 F07: add a cache (Issue #7)\n- 2026-01-05T00:00:00Z, planning/cache: Bound the cache.\n' \
  "$(printf '0%.0s' {1..40})" >"$legacy/docs/PLANNING_APPROVAL.md"
add_review "$legacy" 1 PASS "[]"
run_finish "$legacy" y || { cat "$legacy.out" >&2; fail "approving after an amended approval failed"; }
grep -Fqx -- "- abc1234 F07: add a cache (Issue #7)" "$legacy/docs/PLANNING_APPROVAL.md" ||
  fail "the approval dropped an update by merged work that an amended approval recorded"

# --- An approved planning ----------------------------------------------------
#
# A change to an approved planning is a change cycle; features keep the
# architecture and the ADRs up to date under their own review. There is no
# amendment without a review (finish-planning.sh --amend is gone, #539).

# Creates a repository whose main holds an approved planning, on a new
# planning branch.
setup_approved() {
  local repo
  local fingerprint

  repo="$(setup_repo "$1")"
  git -C "$repo" switch -q main
  printf '# ADR 001: Local storage\n\n## Status\n\nAccepted.\n' >"$repo/docs/decisions/001-local-storage.md"
  fingerprint="$(bash -c 'source "$1/scripts/lib/fingerprint.sh"; source "$1/scripts/lib/planning.sh"
    scratch="$(mktemp -d)"; fingerprint_files "$1" "$scratch" "${PLANNING_SCOPE[@]}"; rm -rf "$scratch"' _ "$repo")"
  printf '# Planning Approval\n\nStatus: Approved\nApproved at: 2026-01-03T00:00:00Z\nFinal review: round 2, PASS, by codex (model-p)\nPlanning fingerprint: %s\n\n## Review rounds\n\n- Round 2: PASS\n' \
    "$fingerprint" >"$repo/docs/PLANNING_APPROVAL.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "Approved planning" >/dev/null
  git -C "$repo" switch -q -c "planning/$1"
  printf '%s\n' "$repo"
}

update_adr() {
  printf '\n## Status\n\nAmended by ADR 002.\n' >>"$1/docs/decisions/001-local-storage.md"
  printf '# ADR 002: Cache\n\nAmends ADR 001.\n' >"$1/docs/decisions/002-cache.md"
  printf '\nA cache sits in front of the storage.\n' >>"$1/docs/architecture.md"
}

# --amend is no option: it prints the usage and changes nothing.
repo="$(setup_approved no-amend)"
update_adr "$repo"
before="$(cat "$repo/docs/PLANNING_APPROVAL.md")"
status=0
(cd "$repo" && printf 'y\n' | PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --amend "A reason.") >"$repo.out" 2>&1 || status=$?
[[ "$status" -eq 2 ]] || { cat "$repo.out" >&2; fail "--amend was not refused with the usage (status $status)"; }
grep -Fq "Usage:" "$repo.out" || fail "--amend did not print the usage"
! grep -Fq -- "--amend" "$repo.out" || fail "the usage still names --amend"
grep -Fq "start-planning.sh <name> --change <file>" "$repo.out" || fail "the usage does not name the change cycle"
[[ "$(cat "$repo/docs/PLANNING_APPROVAL.md")" == "$before" ]] || fail "--amend changed the approval"

# Features keep the architecture and the ADRs up to date. After such a change
# is merged the approval is still current, and the check names the commits.
repo="$(setup_approved feature-updates)"
git -C "$repo" switch -q main
update_adr "$repo"
git -C "$repo" add -A
git -C "$repo" commit -qm "F07: add a cache, with ADR 002" -m "Issue: #7" -m "Review: round 2, PASS, by codex (model-r)"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a feature that updated the architecture made the approval stale"
(cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check) >"$repo.out" 2>&1
grep -Fq "F07: add a cache, with ADR 002" "$repo.out" || fail "the check did not name the commit that updated the architecture"

# What the product is and which features it gets is changed by a planning
# cycle only: a change to the roadmap or the requirements, by a feature or by
# hand, makes the approval stale, also together with an architecture change.
for document in docs/roadmap.md docs/PROJECT_REQUIREMENTS.md; do
  repo="$(setup_approved "stale-$(basename "$document" .md)")"
  git -C "$repo" switch -q main
  update_adr "$repo"
  printf '\nA change outside a planning cycle.\n' >>"$repo/$document"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "F08: change $document"
  [[ "$(check_status "$repo")" -eq 1 ]] || fail "a change to $document did not make the approval stale"
  (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check) >"$repo.out" 2>&1 || true
  grep -Fq "only a planning cycle may change those" "$repo.out" || fail "the stale approval did not say what changed"
done

# The starting point is the commit that last changed the approval file, and
# only when the planning documents in it have the recorded fingerprint. A
# commit that changes the file without recording the documents it comes
# with is no approval of them.
repo="$(setup_approved unrecorded)"
git -C "$repo" switch -q main
printf '\nA note.\n' >>"$repo/docs/PLANNING_APPROVAL.md"
update_adr "$repo"
git -C "$repo" add -A
git -C "$repo" commit -qm "Change the approval file and the architecture without recording it"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an approval that does not match its own commit was trusted"


# --- Decisions on escalated findings ----------------------------------------
#
# finish-planning.sh --resolve records the owner's decision on one escalated
# finding of the latest round, at a terminal only.

# at_terminal <repo> <answer> <command>...: runs the command in the repository
# at a pseudo-terminal, answering <answer> to its question.
at_terminal() {
  local repo="$1"
  local answer="$2"
  local command

  shift 2
  command="cd $(printf '%q' "$repo") && PATH=$(printf '%q' "$tmp/bin:$ISOLATED_PATH") $(printf '%q ' "$@")"
  pty_run "$answer"$'\n' "$command"
}

# resolve <repo> <answer> <argument>...: finish-planning.sh --resolve at a
# terminal. A refusal inside the terminal does not reach the exit status of
# every 'script', so the tests check what was stored.
resolve() {
  local repo="$1"
  local answer="$2"

  shift 2
  at_terminal "$repo" "$answer" ./scripts/finish-planning.sh --resolve "$@" >"$repo.out" 2>&1 || true
}

# resolution <repo> <round> <finding-id>: where the decision is stored, as the
# owner's exception record of the planning (kind planning).
resolution() {
  printf '%s/.agents/exceptions/planning-project-bootstrap-review-%02d-%s.json\n' "$1" "$2" "$3"
}

# A minor finding that the triage escalated: the owner decides it does not
# apply, and the planning can then be approved; the approval lists the decision.
repo="$(setup_repo resolve)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN2 minor "Offline sync is unplanned"), $(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 ESCALATE
jq '.decisions[1].decision = "ACCEPT"' "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
expect_refused "$repo" "an escalated minor finding has no decision"
grep -Fq -- "--resolve <finding-id>" "$repo.out" || fail "the refusal does not name the command that records a decision"

# Without a terminal nothing is asked and nothing is stored.
if run_finish "$repo" y --resolve MIN2 --type not-applicable --reason "Sync is a non-goal."; then
  fail "a decision was recorded without a terminal"
fi
grep -Fq "must be a terminal" "$repo.out" || fail "the refusal without a terminal does not say why"
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a decision was stored without a terminal"
if run_finish "$repo" y --resolve MIN2 --type not-applicable --reason "Sync is a non-goal." --unattended; then
  fail "a decision was recorded unattended"
fi
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a decision was stored unattended"

# Only an escalated finding of the latest round, with a valid type and reason.
resolve "$repo" y MIN1 --type not-applicable --reason "A reason."
grep -Fq "is not escalated" "$repo.out" || fail "a rejected finding was not refused: $(cat "$repo.out")"
resolve "$repo" y X9 --type not-applicable --reason "A reason."
grep -Fq "has no finding X9" "$repo.out" || fail "an unknown finding was not refused"
resolve "$repo" y MIN2 --type risk-accepted --reason "A reason."
grep -Fq "must be not-applicable or accepted" "$repo.out" || fail "an unknown type was not refused"
resolve "$repo" y MIN2 --type accepted --reason " "
grep -Fq "needs a reason" "$repo.out" || fail "an empty reason was not refused"
compgen -G "$repo/.agents/exceptions/*.json" >/dev/null && fail "a refused decision was stored"

# Declining stores nothing.
resolve "$repo" n MIN2 --type not-applicable --reason "Sync is a non-goal."
grep -Fq "Offline sync is unplanned" "$repo.out" || fail "the finding was not shown before the question"
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a declined decision was stored"

resolve "$repo" y MIN2 --type not-applicable --reason "Sync is a non-goal of the requirements."
record="$(resolution "$repo" 1 MIN2)"
[[ -f "$record" ]] || { cat "$repo.out" >&2; fail "the decision was not stored"; }
jq -e --arg sha "$(sha256sum "$repo/$reviews/planning-project-bootstrap-review-01.json" | cut -c1-64)" '
  .schema == "exception/v1" and .kind == "planning" and .type == "not-applicable" and .round == 1 and .finding_id == "MIN2"
  and .finding_severity == "minor" and .reason == "Sync is a non-goal of the requirements." and .account == "owner-login"
  and .review == ".agents/reviews/planning-project-bootstrap-review-01.json" and .review_sha256 == $sha
  and .planner_rationale == "Considered."' "$record" >/dev/null ||
  fail "the stored decision lacks its fields: $(cat "$record")"
grep -Fq '"planner_rationale": "Considered."' "$repo.out" || fail "the record was not shown as it is stored"
resolve "$repo" y MIN2 --type accepted --reason "Again."
grep -Fq "exists already" "$repo.out" || fail "a second decision on the same finding was not refused"
[[ "$(jq -r .type "$record")" == "not-applicable" ]] || fail "a second decision replaced the first"

run_finish "$repo" y || { cat "$repo.out" >&2; fail "a planning whose escalation was decided was not approved"; }
grep -Fq "Your decision: not-applicable, Sync is a non-goal of the requirements." "$repo.out" ||
  fail "the decision was not shown with the findings"
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "## Escalations resolved by the owner's decision" "$approval" || fail "the approval does not list the decisions"
grep -Eq "^- Round 1: MIN2 \[minor\] Offline sync is unplanned\. Not applicable, decided by the project owner \(owner-login\) at [0-9T:Z-]+: Sync is a non-goal of the requirements\.$" "$approval" ||
  fail "the approval does not record the decision: $(cat "$approval")"

# A decision is for a minor finding only: an escalated major or critical
# finding is refused with the severity of the review, and nothing is recorded.
repo="$(setup_repo resolve-blocking)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline sync is unplanned"), $(finding C1 critical "No data model")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y M1 --type not-applicable --reason "Sync is a non-goal."
grep -Fq "M1 of round 1 is major in the review" "$repo.out" || fail "an escalated major finding was not refused: $(cat "$repo.out")"
grep -Fq "a new review round after the planning documents changed" "$repo.out" && grep -Fq "change of the requirements" "$repo.out" ||
  fail "the refusal of a major finding does not name the ways that remain"
resolve "$repo" y C1 --type accepted --reason "The model follows later."
grep -Fq "C1 of round 1 is critical in the review" "$repo.out" || fail "an escalated critical finding was not refused: $(cat "$repo.out")"
compgen -G "$repo/.agents/exceptions/*.json" >/dev/null && fail "a decision on a major or critical finding was stored"
expect_refused "$repo" "escalated major and critical findings block"
grep -Fq "2 critical or major finding(s)" "$repo.out" || fail "the escalated blocking findings were not reported"
# A record written by hand for a major finding resolves nothing.
review="$repo/$reviews/planning-project-bootstrap-review-01.json"
mkdir -p "$repo/.agents/exceptions"
jq --arg sha "$(sha256sum "$review" | cut -c1-64)" '{
  schema: "exception/v1", kind: "planning", type: "risk-accepted", reason: "By hand.", evidence: null,
  account: "owner-login", directed_at: "2026-01-02T00:00:00Z",
  review: ".agents/reviews/planning-project-bootstrap-review-01.json", review_sha256: $sha, round,
  finding_id: "M1", finding_title: "Offline sync is unplanned", finding_severity: "major",
  reviewed_tree, merge_base, planner_rationale: "Considered."}' "$review" >"$(resolution "$repo" 1 M1)"
expect_refused "$repo" "a decision written by hand for a major finding"
grep -Fq "finding M1 is major: a planning record resolves a minor finding only" "$repo.out" ||
  fail "the hand-written decision on a major finding was not reported as invalid: $(cat "$repo.out")"

# A decision is bound to its review as it is: an edited review voids it.
repo="$(setup_repo resolve-edited)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y MIN1 --type accepted --reason "Sharing stays open for now."
[[ -f "$(resolution "$repo" 1 MIN1)" ]] || { cat "$repo.out" >&2; fail "the decision on a minor escalation was not stored"; }
jq '.limitations = "Edited."' "$repo/$reviews/planning-project-bootstrap-review-01.json" >"$tmp/review.tmp"
mv "$tmp/review.tmp" "$repo/$reviews/planning-project-bootstrap-review-01.json"
expect_refused "$repo" "the review was edited after the decision"
grep -Fq "the review artifact changed after the exception was recorded" "$repo.out" || fail "the void decision was not reported: $(cat "$repo.out")"

# A decision is stale once the documents change: the review it belongs to is
# stale, and a new round that raises the finding again needs its own decision.
repo="$(setup_repo resolve-stale)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y MIN1 --type accepted --reason "Sharing stays open for now."
[[ -f "$(resolution "$repo" 1 MIN1)" ]] || fail "the decision was not stored"
printf '\n## F02 — Sharing\n' >>"$repo/docs/roadmap.md"
expect_refused "$repo" "the documents changed after the decision"
grep -Fq "is stale" "$repo.out" || fail "the stale review was not reported"
resolve "$repo" y MIN1 --type accepted --reason "Again."
grep -Fq "is stale" "$repo.out" || fail "a decision on a stale review was not refused"
add_review "$repo" 2 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is still open")]"
add_triage "$repo" 2 ESCALATE
expect_refused "$repo" "a later round escalated the finding again"
grep -Fq "without your decision: MIN1" "$repo.out" || fail "the new escalation was not reported: $(cat "$repo.out")"
# The decision of round 1 still resolves the escalation of round 1, without
# the question for earlier escalations.
resolve "$repo" y MIN1 --type not-applicable --reason "Sharing is decided in F02."
run_finish "$repo" y || { cat "$repo.out" >&2; fail "approving after a decision in each round failed"; }
if grep -Fq "Escalated in earlier rounds:" "$repo.out"; then fail "a decided earlier escalation was asked about again"; fi
[[ "$(grep -c '^- Round [12]: MIN1 ' "$repo/docs/PLANNING_APPROVAL.md")" -eq 2 ]] ||
  fail "the approval does not list the decision of each round"

echo "finish-planning tests passed"
