#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/scope.sh"
source "$script_dir/lib/planning.sh"

usage() {
  echo "Usage: $0 --review <planning-review-json> [--agent <agent>] [--model <model>]"
  echo
  echo "Run in the planning worktree. First the review is triaged with"
  echo "./scripts/triage-review.sh (role 'triage'): a decision per finding, which you"
  echo "approve. Then the project planner (role 'project-planner') revises the planning"
  echo "documents for the FIX_NOW findings. --agent and --model apply to both."
  echo
  echo "A finding whose cause is the approved requirements may be decided AMEND: the"
  echo "triage proposes a small diff of docs/PROJECT_REQUIREMENTS.md, which is applied"
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
[[ -f "$prompt_file" ]] || fail "planning revision prompt not found: $prompt_file"
review_data_require_jq

[[ -f "$review_input" ]] || fail "planning review not found: $review_input"
review_path="$(cd "$(dirname "$review_input")" && pwd -P)/$(basename "$review_input")"
[[ "$review_path" == "$root/.agents/reviews/"*.json ]] ||
  fail "the review must match .agents/reviews/*.json. Received: $review_path"
review_relative="${review_path#"$root"/}"

review_errors="$(review_artifact_errors "$review_path")"
if [[ -n "$review_errors" ]]; then
  echo "Error: invalid planning review:" >&2
  printf '%s\n' "$review_errors" | sed 's/^/  - /' >&2
  exit 1
fi
[[ "$(jq -r '.kind' "$review_path")" == "planning" ]] ||
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

requirements="$PLANNING_REQUIREMENTS"

# fingerprint_before_amendment <triage-json>: the fingerprint of the review
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

# The approved triage of the review, when it was triaged already: its
# decisions stay in force for the unchanged review.
triage="$(review_approved_triage "$root" "$review_path")"

current=0
review_is_current "$root" "$tmp_work" "$review_path" || current=$?
# A triage that amended the requirements made the review stale by itself;
# while nothing else changed, its approved decisions still apply.
if [[ "$current" -eq 1 && -n "$triage" ]] &&
  [[ "$(fingerprint_before_amendment "$triage")" == "$(jq -r '.reviewed_tree' "$review_path")" ]]; then
  current=0
fi
case "$current" in
  0) ;;
  1)
    review_stale_notice "$root" "$tmp_work" "$review_path"
    if [[ -n "$triage" ]]; then
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

if [[ -n "$triage" ]]; then
  # Decisions were approved earlier for this unchanged review; only the
  # FIX_NOW findings remain to be applied.
  echo "Using the approved decisions in ${triage#"$root"/}."
  # A run that ended between recording the decisions and applying their
  # amendments applies them now, exactly as recorded.
  if [[ -n "$(jq -r '.amended_requirements.after // empty' "$triage")" ]] &&
    [[ "$(git -C "$root" hash-object -- "$root/$requirements")" == "$(jq -r '.amended_requirements.before' "$triage")" ]]; then
    git -C "$root" cat-file blob "$(jq -r '.amended_requirements.after' "$triage")" >"$tmp_work/requirements.md" ||
      fail "the amended requirements recorded in ${triage#"$root"/} are not in the repository."
    cp "$tmp_work/requirements.md" "$root/$requirements"
    echo "Applied the recorded amendment(s) to $requirements."
  fi
else
  # Phase 1: the triage of the planning review, which you approve before any
  # planning document changes (triage-review.sh, a planning triage).
  triage_arguments=("$review_path")
  [[ -z "$AGENT_CLI_PROVIDER" ]] || triage_arguments+=(--agent "$AGENT_CLI_PROVIDER")
  [[ -z "$AGENT_CLI_MODEL" ]] || triage_arguments+=(--model "$AGENT_CLI_MODEL")
  "$script_dir/triage-review.sh" "${triage_arguments[@]}" || exit $?
  triage="$(review_approved_triage "$root" "$review_path")"
  # Declined: triage-review.sh said so, and nothing was recorded.
  [[ -n "$triage" ]] || exit 0
fi
triage_relative="${triage#"$root"/}"

escalated="$(jq -r '.decisions[] | select(.decision == "ESCALATE") | "- \(.finding_id) \(.title)"' "$triage")"
if [[ -n "$escalated" ]]; then
  echo
  echo "Escalated findings need your decision:"
  printf '%s\n' "$escalated"
  echo "Resolve each by changing the requirements through Project Grill and approving"
  echo "them again, or by deciding that the finding does not apply. The planning"
  echo "cannot be finished while an escalated finding is unresolved."
fi

adopted="$(jq -r --slurpfile review "$review_path" '
  .decisions[] | select(.decision == "FIX_NOW") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n- Severity: \($f.severity)\n- Evidence: \($f.evidence)\n- Impact: \($f.impact)\n- Recommended action: \($f.recommendation)\n- The rationale of the triage: \($d.rationale)\n"
' "$triage")"
amendments="$(jq -r --slurpfile review "$review_path" '
  .decisions[] | select(.decision == "AMEND") | . as $d
  | ($review[0].findings[] | select(.id == $d.finding_id)) as $f
  | "### \($f.id). \($f.title)\n\n- Severity: \($f.severity)\n- Evidence: \($f.evidence)\n- The rationale of the triage: \($d.rationale)\n- The amendment of the requirements, confirmed by the owner:\n\n```diff\n\($d.amendment.diff | rtrimstr("\n"))\n```\n"
' "$triage")"
if [[ -z "$adopted" && -z "$amendments" ]]; then
  echo
  echo "No finding is to be fixed now; no planning document is changed."
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

revise_prompt="Read and follow .agents/prompts/planning-reviser.md.

The owner approved the decisions of the triage ${triage_relative}."
if [[ -n "$adopted" ]]; then
  revise_prompt+=" Resolve exactly
these findings of ${review_relative}, decided FIX_NOW:

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
  preserved "the planner changed no planning document for the FIX_NOW findings. The approved triage is kept; run this script again to apply them."

echo
echo "The planning was revised. The planning review is now stale by design."
echo "Next: run ./scripts/review-planning.sh for the next review round."
