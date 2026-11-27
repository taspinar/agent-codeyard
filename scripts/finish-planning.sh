#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/guardrails.sh"
source "$script_dir/lib/exceptions.sh"
source "$script_dir/lib/planning.sh"
source "$script_dir/lib/records.sh"
source "$script_dir/lib/base.sh"

usage() {
  echo "Usage:"
  echo "  $0                     Check the planning and record your approval (planning worktree)."
  echo "  $0 --check             Report whether the recorded approval still matches the documents."
  echo "  $0 --resolve <finding-id> --type not-applicable|accepted --reason \"<why>\""
  echo "                         Record your decision on one escalated minor finding of the latest round."
  echo
  echo "--check exits 0 when the approval is current, 1 when it is missing or stale,"
  echo "and 2 on an error."
  echo
  echo "A change to an approved planning is a change cycle:"
  echo "  ./scripts/start-planning.sh <name> --change <file>"
  echo "A feature may update docs/architecture.md and the ADRs under its own review."
  echo
  echo "--resolve records, for one minor finding that the triage escalated in the"
  echo "latest review round, that it does not apply (not-applicable) or that you"
  echo "accept the planning as it is with it (accepted). It refuses a major or critical"
  echo "finding: that needs a new review round after the planning documents changed,"
  echo "or a change of the requirements. It runs only at a terminal, shows the"
  echo "finding and the record, and asks once. The decision is the owner's exception"
  echo "record (kind planning; accepted is stored as the type risk-accepted),"
  echo "stored as $EXCEPTIONS_DIR/<review>-<id>.json; it counts for that round only"
  echo "while the review is current, is listed in $PLANNING_APPROVAL_FILE, and is"
  echo "given to the planning reviewer of later rounds."
  exit 2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

root="$(git rev-parse --show-toplevel)"
review_data_require_jq
tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/finish-planning.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT

resolve_finding=""
resolve_type=""
resolve_reason=""
case "$#:${1:-}" in
  0:) ;;
  *:--resolve | *:--type | *:--reason)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --unattended)
          fail "a decision on a finding needs your confirmation at a terminal and cannot run with --unattended."
          ;;
        --resolve | --type | --reason)
          [[ $# -ge 2 ]] || fail "$1 requires a value."
          case "$1" in
            --resolve) resolve_finding="$2" ;;
            --type) resolve_type="$2" ;;
            --reason) resolve_reason="$2" ;;
          esac
          shift 2
          ;;
        *) usage ;;
      esac
    done
    [[ -n "$resolve_finding" ]] || fail "name the finding: --resolve <finding-id>."
    [[ "$resolve_finding" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "not a finding ID: $resolve_finding"
    case "$resolve_type" in
      not-applicable | accepted) ;;
      "") fail "name the type: --type not-applicable or --type accepted." ;;
      *) fail "the type must be not-applicable or accepted, not: $resolve_type" ;;
    esac
    [[ "$resolve_reason" =~ [^[:space:]] ]] || fail "a decision needs a reason: --reason \"<why>\"."
    [[ "$resolve_reason" != *$'\n'* ]] || fail "the reason of a decision must be a single line."
    # The decision is the owner's, at a terminal: never from a pipe, a file,
    # or another program's output.
    [[ -t 0 && -t 1 ]] ||
      fail "a decision on a finding is confirmed at a terminal; standard input and output must be a terminal."
    ;;
  1:--check)
    status=0
    reason_file="$tmp_work/approval-reason"
    planning_approval_status "$root" "$tmp_work" >"$reason_file" || status=$?
    reason="$(<"$reason_file")"
    case "$status" in
      0)
        if [[ -z "$PLANNING_APPROVAL_UPDATED_SINCE" ]]; then
          echo "Current: $PLANNING_APPROVAL_FILE matches the planning documents."
        else
          echo "Current: the description, the requirements, the change requests, and the roadmap are as approved."
          echo "The architecture or the ADRs were updated since the approval, by:"
          planning_feature_updates "$root" "$PLANNING_APPROVAL_UPDATED_SINCE" HEAD | sed 's/^/  /'
          if ! git -C "$root" diff --quiet HEAD -- "${PLANNING_FEATURE_SCOPE[@]}" 2>/dev/null; then
            echo "  (and uncommitted changes in this working tree)"
          fi
        fi
        ;;
      1) echo "Not approved: $reason"; echo "Finish the planning again with ./scripts/finish-planning.sh in a planning worktree." ;;
      *) echo "Error: $reason" >&2 ;;
    esac
    exit "$status"
    ;;
  *) usage ;;
esac

branch="$(git branch --show-current)"
[[ "$branch" == planning/* ]] ||
  fail "finish-planning.sh must run in a planning worktree (branch planning/<name>). Current branch: $branch"
name="${branch#planning/}"
records_wrap planning "$name" "$0" ${records_arguments[@]+"${records_arguments[@]}"}
# The base the planning merges into: the one start-planning.sh recorded for
# the branch, and the default of the project otherwise (lib/base.sh).
base="$(branch_base "$root" "$branch")" || exit 1

# 1. The planning documents exist and the requirements are approved.
for required in "${PLANNING_BASELINE_DOCUMENTS[@]}"; do
  [[ -f "$root/$required" && ! -L "$root/$required" && -s "$root/$required" ]] ||
    fail "required planning document is missing or empty: $required"
done
grep -Fqx "Status: Approved" "$root/docs/PROJECT_REQUIREMENTS.md" ||
  fail "the project requirements are not approved."
# A document that an adoption reconstructed is approved only as the planner
# confirmed or rewrote it, without the mark (lib/planning.sh). A decision on
# a finding approves nothing, so it does not need that.
observed="$(planning_observed_documents "$root")"
[[ -z "$observed" || -n "$resolve_finding" ]] ||
  fail "these planning documents still carry the mark 'Observed, not approved' of a reconstruction: ${observed//$'\n'/, }. Confirm or rewrite them in the planning, remove the mark, and review again."

# 2. The latest planning review exists, is valid, and is current.
shopt -s nullglob
reviews=("$root/.agents/reviews/planning-${name}-review-"[0-9][0-9].json)
shopt -u nullglob
[[ "${#reviews[@]}" -gt 0 ]] || fail "no planning review exists. Run ./scripts/review-planning.sh first."
latest="${reviews[${#reviews[@]}-1]}"
latest_relative="${latest#"$root"/}"
review_errors="$(review_artifact_errors "$latest")"
[[ -z "$review_errors" ]] || fail "the latest planning review is invalid: ${review_errors//$'\n'/; }"
[[ "$(jq -r '.kind' "$latest")" == "planning" && "$(jq -r '.branch' "$latest")" == "$branch" ]] ||
  fail "$latest_relative is not a planning review of $branch."

current=0
review_is_current "$root" "$tmp_work" "$latest" || current=$?
case "$current" in
  0) ;;
  1)
    review_stale_notice "$root" "$tmp_work" "$latest"
    fail "the latest planning review ($latest_relative) is stale: a planning document changed after it. Run ./scripts/review-planning.sh again."
    ;;
  *) fail "could not compute the fingerprint of the planning documents." ;;
esac

# The approved triage of every round (triage-review.sh, a planning triage):
# the newest valid one of each review, oldest round first.
triages=()
for review in "${reviews[@]}"; do
  candidate="$(review_approved_triage "$root" "$review")"
  [[ -z "$candidate" ]] || triages+=("$candidate")
done
# Every accepted, deferred, or escalated decision of every round.
decisions_file="$tmp_work/decisions.json"
# The amendments of the requirements that you confirmed, of every round.
amendments_file="$tmp_work/amendments.json"
if [[ "${#triages[@]}" -gt 0 ]]; then
  jq -s '[.[] | .round as $round | .decisions[]
          | select(.decision != "FIX_NOW" and .decision != "AMEND") | . + {round: $round}]' "${triages[@]}" >"$decisions_file"
  jq -s '[.[] | .round as $round | .decisions[]
          | select(.decision == "AMEND") | . + {round: $round}]' "${triages[@]}" >"$amendments_file"
else
  echo '[]' >"$decisions_file"
  echo '[]' >"$amendments_file"
fi

round="$(jq -r '.round' "$latest")"
verdict="$(jq -r '.verdict' "$latest")"
# The approved triage of the latest round, or nothing.
triage="$(review_approved_triage "$root" "$latest")"

# Your decisions on escalated findings (--resolve), each joined to the
# escalation it resolves. A decision on anything else resolves nothing.
exception_planning_records "$root" "$name" >"$tmp_work/resolutions.json"
jq --slurpfile resolutions "$tmp_work/resolutions.json" '
  map(. as $d
      | . + {resolution: (if $d.decision == "ESCALATE"
                          then ([$resolutions[0][] | select(.round == $d.round and .finding_id == $d.finding_id)] | first)
                          else null end)})
' "$decisions_file" >"$tmp_work/decisions-resolved.json"
mv "$tmp_work/decisions-resolved.json" "$decisions_file"

# resolve: records your decision on one escalated finding of the latest
# round, for exactly the review as it is now.
resolve() {
  local record
  local record_relative
  local review_sha256
  local record_type
  local account
  local pending="$tmp_work/resolution.json"
  local answer=""
  local errors
  local severity

  [[ -n "$triage" ]] ||
    fail "the findings of round $round have no approved triage. Run ./scripts/revise-planning.sh --review $latest_relative."
  [[ "$(jq --arg id "$resolve_finding" '[.findings[] | select(.id == $id)] | length' "$latest")" -eq 1 ]] ||
    fail "$latest_relative (round $round, the latest) has no finding $resolve_finding."
  [[ "$(jq -r --arg id "$resolve_finding" '.decisions[] | select(.finding_id == $id) | .decision' "$triage")" == "ESCALATE" ]] ||
    fail "finding $resolve_finding of round $round is not escalated: only a finding that the triage escalated needs your decision."
  # The severity is the review's, never an argument's or the triage's.
  severity="$(jq -r --arg id "$resolve_finding" '.findings[] | select(.id == $id) | .severity' "$latest")"
  [[ "$severity" == "minor" ]] ||
    fail "finding $resolve_finding of round $round is $severity in the review: a decision records the owner's answer to a minor finding only. A $severity finding is resolved by a new review round after the planning documents changed, or by a change of the requirements (Project Grill, or a change cycle with ./scripts/start-planning.sh <name> --change <file>). Nothing was stored."
  record="$(exception_file "$root" "$latest" "$resolve_finding")"
  record_relative="${record#"$root"/}"
  [[ ! -e "$record" && ! -L "$record" ]] ||
    fail "a decision on $resolve_finding of round $round exists already: $record_relative. One decision per finding; remove the file first to record it again."
  git -C "$root" check-ignore -q "$EXCEPTIONS_DIR/x.json" ||
    fail "Git does not ignore $EXCEPTIONS_DIR/, so the decision would be committed. Add '$EXCEPTIONS_DIR/' to .gitignore. Nothing was stored."
  command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed; it names the account of the decision. Nothing was stored."
  account="$(gh api user --jq .login </dev/null 2>/dev/null || true)"
  [[ -n "$account" ]] || fail "could not determine the authenticated GitHub account (gh api user). Nothing was stored."

  # The review is copied once, shown and bound as it is now; the record is
  # complete before it is shown, and stored as it is shown. A planning review
  # has no Issue, so the record is not published; the approval lists it.
  cp "$latest" "$tmp_work/review.json"
  review_sha256="$(exception_sha256 "$tmp_work/review.json")"
  record_type="$resolve_type"
  [[ "$record_type" != "accepted" ]] || record_type="risk-accepted"
  exception_record "$tmp_work/review.json" "$latest_relative" "$review_sha256" "$resolve_finding" \
    "$record_type" "$resolve_reason" "" "$account" \
    "$(jq -r --arg id "$resolve_finding" '.decisions[] | select(.finding_id == $id) | .rationale' "$triage")" >"$pending"

  echo "YOUR DECISION on an escalated finding of $latest_relative (round $round)."
  echo "This decision comes from you, not from an agent."
  echo "Account: $account"
  echo
  echo "The finding, as the review states it:"
  jq -r --arg id "$resolve_finding" '
    [.findings[] | select(.id == $id)] | first
    | "  \(.id) (\(.severity)): \(.title)", "  Evidence: \(.evidence)", "  Impact: \(.impact)", "  Recommendation: \(.recommendation)"
  ' "$tmp_work/review.json"
  jq -r '"  The triage escalated it: \(.planner_rationale)"' "$pending"
  echo
  echo "The decision, exactly as it will be stored as $record_relative:"
  cat "$pending"
  echo
  echo "It resolves the finding in round $round only while that review is current:"
  echo "a change of a planning document makes the review stale, and a later round"
  echo "that raises the finding again needs a decision of its own. The planning"
  echo "reviewer of later rounds receives it, and the approval lists it."
  printf "Store exactly this decision? [y/N] "
  read -r answer || true
  case "$answer" in
    y | Y | yes | YES) ;;
    *)
      echo "Declined; nothing was stored."
      exit 0
      ;;
  esac

  # The review is still the one shown, and still current.
  [[ "$(exception_sha256 "$latest")" == "$review_sha256" ]] ||
    fail "$latest_relative changed while the question was open. Nothing was stored."
  [[ "$(fingerprint_files "$root" "$tmp_work" "${PLANNING_SCOPE[@]}")" == "$(jq -r '.reviewed_tree' "$latest")" ]] ||
    fail "a planning document changed while the question was open. Nothing was stored."
  [[ ! -e "$record" && ! -L "$record" ]] || fail "$record_relative appeared while the question was open. Nothing was stored."
  mkdir -p "$root/$EXCEPTIONS_DIR"
  cp "$pending" "$record"
  errors="$(exception_errors "$root" "$record" "$latest")"
  if [[ -n "$errors" ]]; then
    rm -f "$record"
    fail "the decision would be invalid: ${errors//$'\n'/; }. Nothing was stored."
  fi
  records_intervention "recorded a decision ($record_type) on escalated planning finding $resolve_finding of round $round"

  echo
  echo "Stored $record_relative."
  echo "Next: ./scripts/finish-planning.sh, once every escalated finding of round $round has a decision."
}

if [[ -n "$resolve_finding" ]]; then
  resolve
  exit 0
fi

# Show every finding that was not adopted before any refusal, so the reasons
# are visible.
if [[ "$(jq 'length' "$decisions_file")" -gt 0 ]]; then
  echo "Findings that were not adopted:"
  jq -r '.[] | "- Round \(.round), \(.decision): \(.finding_id) [\(.severity)] \(.title)\n  Rationale: \(.rationale)"
    + (if .resolution != null then "\n  Your decision: \(.resolution.type), \(.resolution.reason)" else "" end)' "$decisions_file"
  echo
fi

# 3. The latest round is resolved: no critical or major finding, every finding
#    decided, nothing adopted but not yet applied, and nothing escalated
#    without your decision. Your decision resolves a minor finding only, so
#    an escalated critical or major finding still blocks.
blocking="$(jq '[.findings[] | select(.severity == "critical" or .severity == "major")] | length' "$latest")"
[[ "$blocking" -eq 0 ]] ||
  fail "the latest planning review (round $round) has $blocking critical or major finding(s). Revise with ./scripts/revise-planning.sh and review again, or change the requirements; a decision with --resolve is for minor findings only."

if [[ "$(jq '.findings | length' "$latest")" -gt 0 ]]; then
  [[ -n "$triage" ]] ||
    fail "the findings of round $round have no approved triage. Run ./scripts/revise-planning.sh --review $latest_relative."
  [[ "$(jq '[.decisions[] | select(.decision == "FIX_NOW")] | length' "$triage")" -eq 0 ]] ||
    fail "round $round has FIX_NOW findings that are not applied yet. Run ./scripts/revise-planning.sh --review $latest_relative and review again."
fi

escalated_now="$(jq -r --argjson round "$round" '
  [.[] | select(.round == $round and .decision == "ESCALATE" and .resolution == null) | .finding_id] | join(", ")
' "$decisions_file")"
[[ -z "$escalated_now" ]] ||
  fail "round $round has escalated finding(s) without your decision: $escalated_now. Resolve each through Project Grill and a new review round, or record your decision that it does not apply or that you accept it: ./scripts/finish-planning.sh --resolve <finding-id> --type not-applicable|accepted --reason \"<why>\""

# 4. Escalations of earlier rounds need an explicit resolution by the human;
#    a newer review alone does not resolve them. Your recorded decision on
#    one is that resolution.
earlier_escalations="$(jq -r --argjson round "$round" '
  .[] | select(.round < $round and .decision == "ESCALATE" and .resolution == null) | "- Round \(.round): \(.finding_id) \(.title)"
' "$decisions_file")"
if [[ -n "$earlier_escalations" ]]; then
  echo "Escalated in earlier rounds:"
  printf '%s\n' "$earlier_escalations"
  printf "Was each of these resolved, by changing the requirements through Project Grill or by deciding that it does not apply? [y/N] "
  resolved=""
  read -r resolved || true
  case "$resolved" in
    y | Y | yes | YES) records_intervention "confirmed that the escalated findings are resolved" ;;
    *) fail "the escalated findings of earlier rounds are not resolved." ;;
  esac
  echo
fi

# 5. Ask for approval of exactly the reviewed planning.
reviewed_fingerprint="$(jq -r '.reviewed_tree' "$latest")"
echo "Planning ready for approval:"
echo "  Branch:        $branch"
echo "  Final review:  $latest_relative (round $round, ${verdict//_/ })"
echo

printf "Approve this planning? [y/N] "
approval=""
read -r approval || true
case "$approval" in
  y | Y | yes | YES) records_intervention "approved the planning" ;;
  *)
    echo "Declined; the planning approval was not recorded."
    exit 0
    ;;
esac

# 6. Record the approval for the reviewed planning, and only if it did not
#    change while you were deciding.
fingerprint="$(fingerprint_files "$root" "$tmp_work" "${PLANNING_SCOPE[@]}")" ||
  fail "could not compute the fingerprint of the planning documents."
[[ "$fingerprint" == "$reviewed_fingerprint" ]] ||
  fail "a planning document changed after the final review; the approval was not recorded. Run ./scripts/review-planning.sh again."

# What merged work changed in the architecture and the ADRs since the
# previous approval: this approval covers those changes too, so it names them.
previous_updates=""
recorded_updates="$(planning_recorded_updates "$root/$PLANNING_APPROVAL_FILE")"
if [[ -f "$root/$PLANNING_APPROVAL_FILE" ]]; then
  previous_recorded="$(sed -n 's/^Planning fingerprint: \([0-9a-f]\{40,64\}\)$/\1/p' "$root/$PLANNING_APPROVAL_FILE" | head -n 1)"
  if [[ -n "$previous_recorded" ]]; then
    previous_commit="$(planning_approval_commit "$root" "$tmp_work" "$previous_recorded")"
    [[ -z "$previous_commit" ]] ||
      previous_updates="$(planning_feature_updates "$root" "$previous_commit" HEAD)"
  fi
fi
{
  echo "# Planning Approval"
  echo
  echo "Status: Approved"
  echo "Approved at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Planning branch: $branch"
  [[ ! -f "$root/docs/changes/$name.md" ]] || echo "Change request: docs/changes/$name.md"
  echo "Final review: round $round, ${verdict//_/ }, by $(jq -r '"\(.reviewer.agent) (\(.reviewer.model))"' "$latest")"
  echo "Planning fingerprint: $fingerprint"
  echo
  echo "Recorded by \`scripts/finish-planning.sh\`. The approval covers these planning"
  echo "documents. A change to the description, the requirements, a change request, or the"
  echo "roadmap makes it stale; the architecture and the ADRs may be updated by features"
  echo "(\`./scripts/finish-planning.sh --check\`):"
  echo
  for path in "${PLANNING_SCOPE[@]}"; do
    echo "- \`$path\`"
  done
  echo
  if [[ -n "$previous_updates" || -n "$recorded_updates" ]]; then
    echo "## Updates by merged work"
    echo
    echo "These commits changed the architecture or the ADRs between approvals, each"
    echo "under its own review. This approval covers the documents including them."
    echo
    [[ -z "$recorded_updates" ]] || printf '%s\n' "$recorded_updates"
    [[ -z "$previous_updates" ]] || printf '%s\n' "$previous_updates" | sed 's/^/- /'
    echo
  fi
  echo "## Review rounds"
  echo
  for review in "${reviews[@]}"; do
    jq -r '"- Round \(.round): \(.verdict | gsub("_"; " ")), \(.findings | length) finding(s), by \(.reviewer.agent) (\(.reviewer.model))"' "$review"
  done
  echo
  if [[ -n "$earlier_escalations" ]]; then
    echo "## Escalations confirmed as resolved"
    echo
    printf '%s\n' "$earlier_escalations"
    echo
  fi
  if [[ "$(jq '[.[] | select(.resolution != null)] | length' "$decisions_file")" -gt 0 ]]; then
    echo "## Escalations resolved by the owner's decision"
    echo
    echo "Recorded with \`finish-planning.sh --resolve\`, each for its own review round."
    echo
    jq -r '.[] | select(.resolution != null) | .resolution
      | "- Round \(.round): \(.finding_id) [\(.finding_severity)] \(.finding_title). \(if .type == "risk-accepted" then "Accepted" else "Not applicable" end), decided by the project owner (\(.account)) at \(.directed_at): \(.reason)"' "$decisions_file"
    echo
  fi
  if [[ "$(jq 'length' "$amendments_file")" -gt 0 ]]; then
    echo "## Requirements amended with the owner's confirmation"
    echo
    echo "Proposed by the triage for a finding (\`triage-review.sh\` of \`revise-planning.sh\`, decision AMEND),"
    echo "applied to \`docs/PROJECT_REQUIREMENTS.md\` only after the project owner confirmed"
    echo "exactly this diff at a terminal."
    echo
    jq -r '.[] | "- Round \(.round): \(.finding_id) [\(.severity)] \(.title). \(.rationale) Confirmed by the project owner at \(.amendment.confirmed_at).\n\n  ```diff\n\(.amendment.diff | rtrimstr("\n") | split("\n") | map("  " + .) | join("\n"))\n  ```\n"' "$amendments_file"
  fi
  echo "## Findings that were not adopted"
  echo
  if [[ "$(jq 'length' "$decisions_file")" -eq 0 ]]; then
    echo "None."
  else
    jq -r '.[] | "- Round \(.round), \(.decision): \(.finding_id) [\(.severity)] \(.title). \(.rationale)"' "$decisions_file"
  fi
} >"$root/$PLANNING_APPROVAL_FILE"

echo
echo "Recorded the approval in $PLANNING_APPROVAL_FILE."
echo
echo "Next steps:"
echo "  ./scripts/verify.sh"
to_add=()
for path in "${PLANNING_SCOPE[@]}"; do
  [[ ! -e "$root/$path" ]] || to_add+=("$path")
done
echo "  git add ${to_add[*]} $PLANNING_APPROVAL_FILE"
if [[ -f "$root/docs/changes/$name.md" ]]; then
  echo "  git commit -m \"Plan change: $name\""
else
  echo "  git commit -m \"Plan project bootstrap\""
fi
echo "  git push -u origin \"$branch\""
echo
echo "Open the planning PR into $base; $PLANNING_APPROVAL_FILE summarizes the review"
echo "rounds and the findings that were not adopted for its description. After the"
echo "merge, from the primary checkout:"
echo "  ./scripts/cleanup-worktree.sh $branch    # removes this worktree and updates main"
echo "  ./scripts/create-feature-issue.sh <feature-id>    # for example F01"
