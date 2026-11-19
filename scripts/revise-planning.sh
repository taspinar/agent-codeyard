#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/review-run.sh"
source "$script_dir/lib/scope.sh"

usage() {
  echo "Usage: $0 --review <planning-review-json> [--agent <agent>] [--model <model>]"
  echo
  echo "Run in the planning worktree. The project planner (role 'project-planner')"
  echo "first decides per finding, then, after your approval, revises the planning"
  echo "documents for the adopted findings."
  echo
  echo "A finding whose cause is the approved requirements may be decided AMEND: the"
  echo "planner proposes a small diff of docs/PROJECT_REQUIREMENTS.md, which is applied"
  echo "only after you confirm exactly that diff at a terminal."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

agent_parse_args "$@"
agent_reject_unattended
review_input=""
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --review)
      [[ $# -ge 2 && -n "$2" ]] || fail "--review requires a planning review file."
      review_input="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[[ -n "$review_input" ]] || usage

root="$(git rev-parse --show-toplevel)"
branch="$(git branch --show-current)"
[[ "$branch" != planning/* ]] || records_wrap planning "${branch#planning/}" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
[[ "$branch" == planning/* ]] ||
  fail "revise-planning.sh must run in a planning worktree (branch planning/<name>). Current branch: $branch"

prompt_file="$root/.agents/prompts/planning-reviser.md"
schema_file="$root/.agents/schemas/revision.schema.json"
[[ -f "$prompt_file" ]] || fail "planning revision prompt not found: $prompt_file"
[[ -f "$schema_file" ]] || fail "revision schema not found: $schema_file"
review_data_require_jq

[[ -f "$review_input" ]] || fail "planning review not found: $review_input"
review_path="$(cd "$(dirname "$review_input")" && pwd -P)/$(basename "$review_input")"
[[ "$review_path" == "$root/.agents/reviews/"*.json && "$review_path" != *-revision.json ]] ||
  fail "the review must match .agents/reviews/*.json. Received: $review_path"
review_relative="${review_path#"$root"/}"

review_errors="$(review_artifact_errors "$review_path")"
if [[ -n "$review_errors" ]]; then
  echo "Error: invalid planning review:" >&2
  printf '%s\n' "$review_errors" | sed 's/^/  - /' >&2
  exit 1
fi
[[ "$(jq -r '.kind // "feature"' "$review_path")" == "planning" ]] ||
  fail "this is a feature review; use triage-review.sh."
[[ "$(jq -r '.branch' "$review_path")" == "$branch" ]] ||
  fail "the review belongs to $(jq -r '.branch' "$review_path"), not to $branch."
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" 2>/dev/null ||
  fail "the project requirements are not approved."

agent_resolve "$root" project-planner "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
agent="$AGENT_PROVIDER"
model="$AGENT_MODEL"

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/revise-planning.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

revision="${review_path%.json}-revision"
revision_relative="${revision#"$root"/}"

requirements="docs/PROJECT_REQUIREMENTS.md"

# amendment_lines <diff-file>: the added and removed lines of a diff of one
# file, in order, without the file headers.
amendment_lines() {
  awk '/^@@/ { hunk = 1; next } hunk && /^[-+]/ { print }' "$1"
}

# amendment_apply <diff-file> <requirements-copy>: applies a diff of the
# requirements to a copy of them, exactly: it refuses a diff that touches
# another file, renames or changes a mode, changes the Status or Approved at
# line, or does not apply cleanly, and a result whose changed lines differ
# from those of the diff. Prints the reason of a refusal; the copy is
# unchanged then.
amendment_apply() {
  local diff="$1"
  local copy="$2"
  local work="$tmp_work/amendment-apply"
  local touched

  rm -rf "$work"
  mkdir -p "$work/docs"
  git init -q "$work"
  cp "$copy" "$work/$requirements"
  touched="$(git -C "$work" apply --recount --numstat -- "$diff" 2>/dev/null)" || {
    echo "it is not a valid diff"
    return 1
  }
  [[ "$(printf '%s\n' "$touched" | cut -f3-)" == "$requirements" ]] || {
    echo "it must change $requirements and nothing else"
    return 1
  }
  [[ -z "$(git -C "$work" apply --recount --summary -- "$diff" 2>/dev/null)" ]] || {
    echo "it must not create, delete, rename, or change the mode of a file"
    return 1
  }
  ! amendment_lines "$diff" | grep -Eq '^[-+](Status|Approved at):' || {
    echo "it must not change the Status or Approved at line; the script updates Approved at"
    return 1
  }
  git -C "$work" apply --recount -- "$diff" 2>"$work.err" || {
    echo "it does not apply cleanly to $requirements: $(head -n 1 "$work.err")"
    return 1
  }
  git diff --no-index --no-color --no-ext-diff --no-textconv -U0 -- "$copy" "$work/$requirements" >"$work.result" || true
  [[ "$(amendment_lines "$work.result")" == "$(amendment_lines "$diff")" ]] || {
    echo "applying it changes other lines than the diff shows"
    return 1
  }
  cp "$work/$requirements" "$copy"
}

# amendment_errors <decisions-file>: every proposed amendment must apply
# exactly, in the order of the decisions, to the requirements as they are.
amendment_errors() {
  local copy="$tmp_work/requirements-check.md"
  local index=0
  local id
  local reason

  cp "$root/$requirements" "$copy"
  while IFS= read -r id; do
    jq -j --argjson i "$index" '[.decisions[] | objects | select(.decision == "AMEND")][$i].amendment | if endswith("\n") then . else . + "\n" end' "$1" \
      >"$tmp_work/amendment-check.diff"
    index=$((index + 1))
    reason="$(amendment_apply "$tmp_work/amendment-check.diff" "$copy")" ||
      echo "the amendment of finding $id is refused: $reason"
  done < <(jq -r '.decisions[] | objects | select(.decision == "AMEND") | .finding_id' "$1")
}

# fingerprint_before_amendment <revision-json>: the fingerprint of the review
# with the requirements as they were before the recorded amendments, when the
# requirements are now exactly as amended. Prints nothing otherwise.
fingerprint_before_amendment() {
  local before
  local after
  local mode

  before="$(jq -r '.amended_requirements.before // empty' "$1")"
  after="$(jq -r '.amended_requirements.after // empty' "$1")"
  [[ -n "$before" && -f "$root/$requirements" && ! -L "$root/$requirements" &&
    "$(git -C "$root" hash-object -- "$root/$requirements")" == "$after" ]] || return 0
  git -C "$root" cat-file -e "$before" 2>/dev/null || return 0
  fingerprint_review "$root" "$tmp_work" "$review_path" >/dev/null || return 0
  mode="$(GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" ls-files -s -- "$requirements" | cut -d' ' -f1)"
  GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" update-index --cacheinfo "${mode:-100644},$before,$requirements" &&
    GIT_INDEX_FILE="$tmp_work/fingerprint-files.index" git -C "$root" write-tree
}

current=0
review_is_current "$root" "$tmp_work" "$review_path" || current=$?
# A revision that amended the requirements made the review stale by itself;
# while nothing else changed, its approved decisions still apply.
if [[ "$current" -eq 1 && -f "$revision.json" ]] &&
  [[ "$(fingerprint_before_amendment "$revision.json")" == "$(jq -r '.reviewed_tree' "$review_path")" ]]; then
  current=0
fi
case "$current" in
  0) ;;
  1)
    review_stale_notice "$root" "$tmp_work" "$review_path"
    if [[ -f "$revision.json" ]]; then
      fail "this review was already revised and the planning has changed since. Run ./scripts/review-planning.sh for the next round."
    fi
    fail "the planning review is stale: a planning document changed after it was written. Run ./scripts/review-planning.sh again."
    ;;
  *)
    fail "could not compute the fingerprint of the planning documents."
    ;;
esac

if [[ "$(jq '.findings | length' "$review_path")" -eq 0 ]]; then
  echo "The planning review has no findings; there is nothing to revise."
  exit 0
fi

render_decisions() {
  jq -r '
    def group($decision; $heading):
      $heading,
      ([.[] | select(.decision == $decision)] as $items
       | if ($items | length) == 0 then "- (none)"
         else ($items[] | "- \(.finding_id) [\(.severity)] \(.title) — \(.rationale)") end),
      "";
    group("ADOPT"; "ADOPT"), group("REJECT"; "REJECT"), group("DEFER"; "DEFER"), group("ESCALATE"; "ESCALATE"),
    group("AMEND"; "AMEND (a change of the approved requirements; each is shown and asked separately)")
  ' "$1"
}

if [[ -f "$revision.json" ]]; then
  # Decisions were approved earlier for this unchanged review; only the
  # adopted findings remain to be applied.
  revision_errors="$(revision_artifact_errors "$revision.json" "$review_path")"
  if [[ -n "$revision_errors" ]]; then
    echo "Error: invalid revision artifact $revision_relative.json:" >&2
    printf '%s\n' "$revision_errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  echo "Using the approved decisions in $revision_relative.json."
  # A run that ended between recording the decisions and applying their
  # amendments applies them now, exactly as recorded.
  if [[ -n "$(jq -r '.amended_requirements.after // empty' "$revision.json")" ]] &&
    [[ "$(git -C "$root" hash-object -- "$root/$requirements")" == "$(jq -r '.amended_requirements.before' "$revision.json")" ]]; then
    git -C "$root" cat-file blob "$(jq -r '.amended_requirements.after' "$revision.json")" >"$tmp_work/requirements.md" ||
      fail "the amended requirements recorded in $revision_relative.json are not in the repository."
    cp "$tmp_work/requirements.md" "$root/$requirements"
    echo "Applied the recorded amendment(s) to $requirements."
  fi
else
  context_file="$tmp_work/context.md"
  decisions_file="$tmp_work/decisions.json"
  {
    echo "# Planning review to decide on"
    echo
    echo "Source: $review_relative (round $(jq -r '.round' "$review_path"))"
    echo
    jq '{verdict, limitations, findings}' "$review_path"
  } >"$context_file"

  decide_prompt="Read and follow .agents/prompts/planning-reviser.md, phase 1 (decide).

Standard input contains the findings of the planning review ${review_relative}.
Decide exactly once per finding and return JSON that matches the supplied
schema. You have read-only access; do not modify any file."

  validate_decisions() {
    local errors

    errors="$(revision_decision_errors "$1" "$review_path")"
    [[ -n "$errors" ]] || errors="$(amendment_errors "$1")"
    printf '%s' "$errors"
  }

  echo "Starting $agent planner ($model) to decide per finding, read-only..."
  echo
  review_run_reviewer "$agent" "$model" "$root" "$decide_prompt" "$context_file" "$schema_file" \
    "$decisions_file" "$tmp_work" validate_decisions

  jq -n --slurpfile review "$review_path" --slurpfile result "$decisions_file" '
    ($result[0].decisions | map({key: .finding_id, value: .}) | from_entries) as $decision
    | [$review[0].findings[] | {
        finding_id: .id,
        severity: .severity,
        title: .title,
        decision: $decision[.id].decision,
        rationale: $decision[.id].rationale,
        amendment: $decision[.id].amendment
      }]
  ' >"$tmp_work/proposal.json"

  echo
  echo "Proposed revision decisions:"
  echo
  render_decisions "$tmp_work/proposal.json"
  amend_count="$(jq '[.[] | select(.decision == "AMEND")] | length' "$tmp_work/proposal.json")"
  # A change of the approved requirements is the owner's, at a terminal:
  # never from a pipe, a file, or another program's output.
  [[ "$amend_count" -eq 0 || ( -t 0 && -t 1 ) ]] ||
    fail "the planner proposes to amend the approved requirements, which you confirm at a terminal; standard input and output must be a terminal. Nothing was recorded."
  printf "Record these decisions and revise the planning for the adopted findings? [y/N] "
  approval=""
  read -r approval || true
  case "$approval" in
    y | Y | yes | YES) records_intervention "approved the revision decisions" ;;
    *)
      echo "Declined; no decisions were recorded and no document was changed."
      exit 0
      ;;
  esac

  # Each amendment separately: shown as the diff it is, applied to a copy of
  # the requirements only on your yes, exactly as shown. A declined
  # amendment, or one that no longer applies, leaves the finding escalated.
  requirements_copy="$tmp_work/requirements.md"
  requirements_before="$(git -C "$root" hash-object -w -- "$root/$requirements")"
  cp "$root/$requirements" "$requirements_copy"
  confirmed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  amended=0
  for ((index = 0; index < amend_count; index++)); do
    jq --argjson i "$index" '[.[] | select(.decision == "AMEND")][$i]' "$tmp_work/proposal.json" >"$tmp_work/amend.json"
    jq -j '.amendment | if endswith("\n") then . else . + "\n" end' "$tmp_work/amend.json" >"$tmp_work/amend.diff"
    finding_id="$(jq -r '.finding_id' "$tmp_work/amend.json")"
    echo
    echo "PROPOSED CHANGE OF THE APPROVED REQUIREMENTS, for finding $finding_id:"
    jq -r --slurpfile review "$review_path" '
      .finding_id as $id | ($review[0].findings[] | select(.id == $id)) as $f
      | "  \($f.id) (\($f.severity)): \($f.title)", "  Evidence: \($f.evidence)", "  Impact: \($f.impact)",
        "  The planner'"'"'s rationale: \(.rationale)"' "$tmp_work/amend.json"
    echo
    cat "$tmp_work/amend.diff"
    echo
    echo "An amendment is for a small correction without which the requirements are"
    echo "infeasible or contradictory. A new or changed requirement needs a change cycle:"
    echo "  ./scripts/start-planning.sh <name> --change <file>"
    printf "Apply this change to the approved requirements? [y/N] "
    answer=""
    read -r answer || true
    note=""
    case "$answer" in
      y | Y | yes | YES)
        if reason="$(amendment_apply "$tmp_work/amend.diff" "$requirements_copy")"; then
          records_intervention "confirmed an amendment of the approved requirements for planning finding $finding_id"
          amended=$((amended + 1))
          jq --arg at "$confirmed_at" --arg id "$finding_id" '
            map(if .finding_id == $id then .amendment = {diff: .amendment, confirmed_by: "owner", confirmed_at: $at} else . end)
          ' "$tmp_work/proposal.json" >"$tmp_work/proposal.next"
          mv "$tmp_work/proposal.next" "$tmp_work/proposal.json"
          echo "Confirmed; the change is applied when the decisions are recorded."
          continue
        fi
        echo "The change is refused: $reason. The finding stays escalated."
        note=" The owner confirmed the proposed amendment of the requirements, but it did not apply after the amendments before it."
        ;;
      *)
        echo "Declined; the finding stays escalated."
        note=" The owner declined the proposed amendment of the requirements."
        ;;
    esac
    jq --arg id "$finding_id" --arg note "$note" '
      map(if .finding_id == $id then .decision = "ESCALATE" | .rationale += $note | .amendment = null else . end)
    ' "$tmp_work/proposal.json" >"$tmp_work/proposal.next"
    mv "$tmp_work/proposal.next" "$tmp_work/proposal.json"
  done
  amended_requirements=null
  if [[ "$amended" -gt 0 ]]; then
    # The amended requirements are approved as of now.
    awk -v at="$confirmed_at" '/^Approved at: / && !done { print "Approved at: " at; done = 1; next } { print }' \
      "$requirements_copy" >"$requirements_copy.next"
    mv "$requirements_copy.next" "$requirements_copy"
    amended_requirements="$(jq -n --arg before "$requirements_before" \
      --arg after "$(git -C "$root" hash-object -w -- "$requirements_copy")" '{before: $before, after: $after}')"
  fi

  jq -n \
    --slurpfile review "$review_path" \
    --slurpfile decisions "$tmp_work/proposal.json" \
    --argjson amended_requirements "$amended_requirements" \
    --arg source_review "$review_relative" \
    --arg agent "$agent" \
    --arg model "$model" \
    --arg approved_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" '
    {
      schema: "revision/v1",
      source_review: $source_review,
      branch: $review[0].branch,
      review_round: $review[0].round,
      reviewed_tree: $review[0].reviewed_tree,
      planner: {agent: $agent, model: $model},
      approved_at: $approved_at,
      decisions: ($decisions[0] | map(if .amendment == null then del(.amendment) else . end))
    }
    + (if $amended_requirements == null then {} else {amended_requirements: $amended_requirements} end)
    ' >"$tmp_work/revision.json"

  revision_errors="$(revision_artifact_errors "$tmp_work/revision.json" "$review_path")"
  if [[ -n "$revision_errors" ]]; then
    echo "Error: the revision would be invalid; nothing was recorded:" >&2
    printf '%s\n' "$revision_errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  if [[ "$amended" -gt 0 ]]; then
    # The requirements are still the ones the amendments were made for.
    [[ "$(git -C "$root" hash-object -- "$root/$requirements")" == "$requirements_before" ]] ||
      fail "$requirements changed while you were deciding; nothing was recorded and no document was changed."
  fi
  cp "$tmp_work/revision.json" "$revision.json"
  revision_render_markdown "$revision.json" "$(basename "$revision").json" >"$revision.md"
  echo
  echo "Recorded the decisions:"
  echo "  $revision_relative.json  (source of truth)"
  echo "  $revision_relative.md    (generated report)"
  if [[ "$amended" -gt 0 ]]; then
    cp "$requirements_copy" "$root/$requirements"
    echo "Applied $amended amendment(s) to $requirements, approved at $confirmed_at."
  fi
fi

escalated="$(jq -r '.decisions[] | select(.decision == "ESCALATE") | "- \(.finding_id) \(.title)"' "$revision.json")"
if [[ -n "$escalated" ]]; then
  echo
  echo "Escalated findings need your decision:"
  printf '%s\n' "$escalated"
  echo "Resolve each by changing the requirements through Project Grill and approving"
  echo "them again, or by deciding that the finding does not apply. The planning"
  echo "cannot be finished while an escalated finding is unresolved."
fi

adopted="$(jq -r --slurpfile review "$review_path" '
  .decisions[] | select(.decision == "ADOPT") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n- Severity: \($f.severity)\n- Evidence: \($f.evidence)\n- Impact: \($f.impact)\n- Recommended action: \($f.recommendation)\n- Your rationale: \($d.rationale)\n"
' "$revision.json")"
amendments="$(jq -r --slurpfile review "$review_path" '
  .decisions[] | select(.decision == "AMEND") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n- Severity: \($f.severity)\n- Evidence: \($f.evidence)\n- Your rationale: \($d.rationale)\n- The amendment of the requirements, confirmed by the owner:\n\n```diff\n\($d.amendment.diff | rtrimstr("\n"))\n```\n"
' "$revision.json")"
if [[ -z "$adopted" && -z "$amendments" ]]; then
  echo
  echo "No finding was adopted; no planning document is changed."
  echo "Next: ./scripts/finish-planning.sh, once no escalated finding remains."
  exit 0
fi

# Phase 2: the planner may change only the architecture, the roadmap, and
# direct Markdown ADRs. Everything else, including the requirements, the
# description, and all review artifacts, must stay unchanged.
baseline="$tmp_work/scope-before.tsv"
echo "Recording the files of the planning worktree, to check what the planner changes..."
scope_snapshot "$root" scope_planner_allowed "$baseline"
head_before="$(git -C "$root" rev-parse HEAD)"
before_session="$(fingerprint_review "$root" "$tmp_work" "$review_path")" ||
  fail "could not compute the fingerprint of the planning documents."

revise_prompt="Read and follow .agents/prompts/planning-reviser.md, phase 2 (revise).

The human approved your decisions in ${revision_relative}.json."
if [[ -n "$adopted" ]]; then
  revise_prompt+=" Resolve exactly
these adopted findings of ${review_relative}:

${adopted}"
fi
if [[ -n "$amendments" ]]; then
  revise_prompt+="

The owner amended $requirements for these findings of ${review_relative};
the script applied the amendments already. Align the architecture, the
roadmap, and the ADRs with the amended requirements, wherever they still
follow the old wording:

${amendments}"
fi
revise_prompt+="
Change only docs/architecture.md, docs/roadmap.md, and direct Markdown ADRs
under docs/decisions/. Do not commit, push, open or merge a pull request,
create GitHub Issues, or deploy."

echo
echo "Starting $agent planner ($model) to revise the planning for the decided findings..."
echo
agent_status=0
agent_run write "$agent" "$model" "$root" "$revise_prompt" || agent_status=$?

preserved() {
  echo "Error: $1" >&2
  echo "The planning worktree is preserved; inspect it with: git -C \"$root\" status --short" >&2
  exit "${2:-1}"
}

[[ "$(git -C "$root" rev-parse HEAD)" == "$head_before" ]] ||
  preserved "the planner created a commit; planning agents must leave HEAD unchanged."
echo "Checking which files the planner changed..."
scope_snapshot "$root" scope_planner_allowed "$tmp_work/scope-after.tsv"
scope_unchanged "$baseline" "$tmp_work/scope-after.tsv" ||
  preserved "the planner changed files outside the architecture, the roadmap, and the ADRs."
[[ "$agent_status" -eq 0 ]] || preserved "the planner failed with status $agent_status." "$agent_status"

for document in docs/architecture.md docs/roadmap.md; do
  [[ -f "$root/$document" && ! -L "$root/$document" && -s "$root/$document" ]] ||
    preserved "$document must remain a non-empty regular file."
  [[ ! "$(scope_file_mode "$root/$document")" =~ [1357] ]] ||
    preserved "$document must not be executable."
done
if [[ -e "$root/docs/decisions" || -L "$root/docs/decisions" ]]; then
  [[ -d "$root/docs/decisions" && ! -L "$root/docs/decisions" ]] ||
    preserved "docs/decisions must be a regular directory."
  while IFS= read -r -d '' decision; do
    name="${decision#"$root/docs/decisions/"}"
    [[ "$name" == *.md && -f "$decision" && ! -L "$decision" ]] ||
      preserved "decision records must be regular Markdown files: docs/decisions/$name"
  done < <(find "$root/docs/decisions" -mindepth 1 -maxdepth 1 -print0)
fi

# Adopted findings must lead to a change of the planning documents; an
# amendment alone may need none, when nothing follows the old wording.
after_revision="$(fingerprint_review "$root" "$tmp_work" "$review_path")" ||
  preserved "could not compute the fingerprint of the planning documents."
[[ -z "$adopted" || "$after_revision" != "$before_session" ]] ||
  preserved "the planner changed no planning document for the adopted findings. The approved decisions are kept; run this script again to apply them."

echo
echo "The planning was revised. The planning review is now stale by design."
echo "Next: run ./scripts/review-planning.sh for the next review round."
