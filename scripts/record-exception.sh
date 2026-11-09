#!/usr/bin/env bash

set -euo pipefail

# The arguments as given, for a run that records itself (lib/records.sh).
records_arguments=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/review-data.sh"
source "$script_dir/lib/fingerprint.sh"
source "$script_dir/lib/guardrails.sh"
source "$script_dir/lib/exceptions.sh"
source "$script_dir/lib/records.sh"

usage() {
  echo "Usage: $0 <review-json> --finding <id> --type not-applicable|risk-accepted --reason \"<why>\" [--evidence \"<text or path>\"]"
  echo
  echo "Records the owner's exception to one critical or major finding of the latest"
  echo "review of a feature: the finding is not applicable (--evidence says what"
  echo "shows it is wrong; required), or its risk is accepted (the reason names the"
  echo "risk). It is shown in full and stored exactly as shown after your"
  echo "confirmation at a terminal, published on the Issue, and stored as"
  echo "$EXCEPTIONS_DIR/<review>-<id>.json."
  echo
  echo "finish-feature.sh then commits the feature with that finding open, and the"
  echo "merge always needs the owner's approval. The review and its verdict stay as"
  echo "they are; no acceptance criterion is satisfied by an exception. It counts only"
  echo "while the review is the latest round and current for the content: any"
  echo "change of the content, a later round, or an edit of the review or the record"
  echo "makes it invalid. One finding per exception; it cannot run unattended."
  echo "See docs/development.md, 'Owner exceptions to a blocking finding'."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  records_stop "${0##*/}" "$*"
  exit 1
}

review_input=""
finding=""
type=""
reason=""
evidence=""
evidence_given=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unattended)
      fail "an owner exception needs your confirmation at a terminal and cannot run with --unattended."
      ;;
    --finding | --type | --reason | --evidence)
      [[ $# -ge 2 ]] || fail "$1 requires a value."
      case "$1" in
        --finding) finding="$2" ;;
        --type) type="$2" ;;
        --reason) reason="$2" ;;
        --evidence)
          evidence="$2"
          evidence_given=1
          ;;
      esac
      shift 2
      ;;
    -*) usage ;;
    *)
      [[ -z "$review_input" ]] || usage
      review_input="$1"
      shift
      ;;
  esac
done
[[ -n "$review_input" ]] || usage
records_wrap feature "$(records_branch_issue)" "$0" ${records_arguments[@]+"${records_arguments[@]}"}

# One finding, named exactly: no wildcard, no list.
[[ -n "$finding" ]] || fail "name the finding: --finding <id>."
[[ "$finding" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "not a finding ID: $finding"
case "$type" in
  not-applicable | risk-accepted) ;;
  "") fail "name the type: --type not-applicable or --type risk-accepted." ;;
  *) fail "the type must be not-applicable or risk-accepted, not: $type" ;;
esac
[[ "$reason" =~ [^[:space:]] ]] || fail "an exception needs a reason: --reason \"<why>\"."
if [[ "$type" == "not-applicable" && ! "$evidence" =~ [^[:space:]] ]]; then
  fail "a not-applicable exception needs the evidence that the finding is wrong: --evidence \"<text or path>\"."
fi
[[ "$evidence_given" -eq 0 || "$evidence" =~ [^[:space:]] ]] || fail "--evidence is empty."

# The confirmation is the owner's, at a terminal: never from a pipe, a file,
# or another program's output.
[[ -t 0 && -t 1 ]] ||
  fail "an owner exception is confirmed at a terminal; standard input and output must be a terminal."

root="$(git rev-parse --show-toplevel)"
review_data_require_jq
[[ -f "$review_input" ]] || fail "review artifact not found: $review_input"
review_path="$(cd "$(dirname "$review_input")" && pwd -P)/$(basename "$review_input")"
[[ "$review_path" == "$root/.agents/reviews/"*-review-[0-9][0-9].json ]] ||
  fail "review artifact must match .agents/reviews/*-review-NN.json. Received: $review_path"
review_relative="${review_path#"$root"/}"
git -C "$root" check-ignore -q "$EXCEPTIONS_DIR/x.json" ||
  fail "Git does not ignore $EXCEPTIONS_DIR/, so an exception would change the reviewed content and be committed. Add '$EXCEPTIONS_DIR/' to .gitignore, or take over the template's .gitignore with ./scripts/sync-template.sh."

tmp_work="$(mktemp -d "${TMPDIR:-/tmp}/record-exception.XXXXXX")"
trap 'rm -rf "$tmp_work"' EXIT
# The review is copied once; what is shown and stored comes from the copy,
# and the original must still be that copy when the exception is stored.
cp "$review_path" "$tmp_work/review.json"
review_sha256="$(exception_sha256 "$tmp_work/review.json")"

# The copy is validated; the earlier rounds that a finding with a
# predecessor continues are next to the original.
errors="$(review_artifact_errors "$tmp_work/review.json" "$review_path")"
[[ -z "$errors" ]] || fail "invalid review artifact: ${errors//$'\n'/; }"
[[ "$(jq -r '.kind // "feature"' "$tmp_work/review.json")" == "feature" ]] ||
  fail "only a finding of a feature review can be excepted."
errors="$(exception_review_errors "$root" "$tmp_work" "$review_path")"
[[ -z "$errors" ]] || fail "no exception can be recorded: ${errors//$'\n'/; }. An exception applies to the latest, current review only."
severity="$(jq -r --arg id "$finding" '[.findings[] | select(.id == $id)] | first | .severity // empty' "$tmp_work/review.json")"
[[ -n "$severity" ]] || fail "$review_relative has no finding $finding."
[[ "$severity" == "critical" || "$severity" == "major" ]] ||
  fail "finding $finding is $severity: only a critical or major finding, which stops finish-feature.sh, can be excepted; triage it instead."
record_file="$(exception_file "$root" "$review_path" "$finding")"
record_relative="${record_file#"$root"/}"
[[ ! -e "$record_file" ]] ||
  fail "an exception to $finding of this review exists already: $record_relative. One exception per finding; remove the file first to record it again."

command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run: gh auth login"
account="$(gh api user --jq .login </dev/null 2>/dev/null || true)"
[[ -n "$account" ]] || fail "could not determine the authenticated GitHub account (gh api user). Nothing was stored."
issue="$(jq -r '.issue' "$tmp_work/review.json")"
round="$(jq -r '.round' "$tmp_work/review.json")"

# The record is complete before it is shown, and stored as it is shown.
pending="$tmp_work/exception.json"
jq --arg type "$type" --arg reason "$reason" --arg evidence "$evidence" --arg account "$account" \
  --arg at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg review "$review_relative" --arg sha "$review_sha256" \
  --arg id "$finding" '
  ([.findings[] | select(.id == $id)] | first) as $f
  | {
      schema: "exception/v1",
      type: $type,
      reason: $reason,
      evidence: (if $evidence == "" then null else $evidence end),
      account: $account,
      directed_at: $at,
      review: $review,
      review_sha256: $sha,
      round,
      finding_id: $f.id,
      finding_title: $f.title,
      finding_severity: $f.severity,
      reviewed_tree,
      merge_base
    }' "$tmp_work/review.json" >"$pending"
errors="$(guardrails_request_errors "$pending" "$root/$EXCEPTIONS_SCHEMA")"
[[ -z "$errors" ]] || fail "the exception would be invalid: ${errors//$'\n'/; }. Nothing was stored."

echo "OWNER EXCEPTION to a blocking finding of $review_relative (round $round, Issue #$issue)."
echo "This decision comes from you, not from an agent."
echo "Account: $account"
echo
echo "The finding, as the review states it:"
jq -r --arg id "$finding" '
  [.findings[] | select(.id == $id)] | first
  | "  \(.id) (\(.severity)): \(.title)", "  Evidence: \(.evidence)", "  Impact: \(.impact)", "  Recommendation: \(.recommendation)"
' "$tmp_work/review.json"
echo
echo "The exception, exactly as it will be stored as $record_relative:"
cat "$pending"
echo
echo "The review and its verdict stay as they are; no acceptance criterion is met by"
echo "this. finish-feature.sh may then commit the feature with this finding open, and"
echo "the merge needs the owner's approval. Any change of the content, a later review"
echo "round, or an edit of the review or of this record makes it invalid."
echo "It will be published as a comment on Issue #$issue."
printf "Store and publish exactly this exception? [y/N] "
approval=""
read -r approval || true
case "$approval" in
  y | Y | yes | YES) ;;
  *)
    echo "Declined; nothing was stored or published."
    exit 0
    ;;
esac

# The review is still the one shown, the latest, and current.
[[ "$(exception_sha256 "$review_path")" == "$review_sha256" ]] ||
  fail "$review_relative changed while the question was open. Nothing was stored or published."
errors="$(exception_review_errors "$root" "$tmp_work" "$review_path")"
[[ -z "$errors" ]] || fail "${errors//$'\n'/; }. Nothing was stored or published."
[[ ! -e "$record_file" ]] || fail "$record_relative appeared while the question was open. Nothing was stored or published."

comment="$tmp_work/comment.md"
{
  echo "$EXCEPTIONS_MARKER"
  echo "## Owner exception — round $round, finding $finding"
  echo
  echo "The owner recorded an exception (\`$type\`) to a blocking finding of the independent review. The review keeps its verdict; the merge needs the owner's approval."
  echo
  jq -r --arg id "$finding" '[.findings[] | select(.id == $id)] | first
    | "**Finding \(.id) (\(.severity)):** \(.title)\n\n- Evidence: \(.evidence)\n- Impact: \(.impact)"' "$tmp_work/review.json"
  echo
  jq -r '"**Exception:** \(.type), by \(.account) at \(.directed_at)\n\n- Reason: \(.reason)" + (if .evidence != null then "\n- Evidence: \(.evidence)" else "" end)' "$pending"
  echo "- Record: \`$record_relative\`, SHA-256 \`$(exception_sha256 "$pending")\`"
  echo
  echo "<details><summary>Record</summary>"
  echo
  echo '```json'
  cat "$pending"
  echo '```'
  echo
  echo "</details>"
} >"$comment"
gh issue comment "$issue" --body-file "$comment" </dev/null >/dev/null ||
  fail "publishing the exception on Issue #$issue failed. Nothing was stored; run the command again."

mkdir -p "$root/$EXCEPTIONS_DIR"
cp "$pending" "$record_file"
records_intervention "recorded an owner exception ($type) to finding $finding of round $round"
records_artifact exception "$record_relative" 2>/dev/null || true

echo
echo "Stored $record_relative (SHA-256 $(exception_sha256 "$record_file")) and published it on Issue #$issue."
echo "Next: finish the feature; the merge needs the owner's approval:"
echo "  ./scripts/finish-feature.sh $issue \"<commit summary>\""
