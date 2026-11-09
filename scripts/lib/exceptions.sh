#!/usr/bin/env bash

# The owner's exceptions to blocking review findings. Source this file after
# lib/fingerprint.sh and lib/guardrails.sh; do not execute it.
#
# A critical or major finding of the latest review makes finish-feature.sh
# refuse the commit. The owner can record, for one such finding, that it is
# not applicable or that its risk is accepted (scripts/record-exception.sh).
# The record is .agents/exceptions/<review-basename>-<finding-id>.json, which
# Git ignores. It is bound to the review artifact by its SHA-256 and copies of
# its fields, and to the content by the reviewed tree: it counts only while
# that review is the latest round, is current for the content, and is the
# file it was. A changed tree, a later round, an edited review, or an edited
# record makes it invalid; nothing refreshes or carries it forward.
#
# An exception never changes the review or its verdict, satisfies no
# acceptance criterion, and always makes the merge need the owner's approval.
# Its account is the GitHub login that ran the script. Until the template's
# Issue #99 gives the agent an identity of its own, the confirmation at a
# terminal is an agreement that the scripts and agents keep, not a guarantee
# against an agent that drives a terminal with the owner's credentials.

EXCEPTIONS_DIR=".agents/exceptions"
EXCEPTIONS_SCHEMA=".agents/schemas/exception.schema.json"
# The first line of the comment that record-exception.sh publishes on the
# Issue: lib/issue-comments.sh keeps such reports from the agents.
EXCEPTIONS_MARKER="<!-- workflow-report: owner-exception -->"

# exception_sha256 <file>: the SHA-256 hex digest of the file.
exception_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | cut -c1-64
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 <"$1" | cut -c1-64
  else
    openssl dgst -sha256 -r <"$1" | cut -c1-64
  fi
}

# exception_file <root> <review-json> <finding-id>
# Prints where the exception to that finding of that review is stored.
exception_file() {
  printf '%s/%s/%s-%s.json\n' "$1" "$EXCEPTIONS_DIR" "$(basename "$2" .json)" "$3"
}

# exception_latest_review <review-json>
# Prints the latest round of the reviews of the same feature: the last
# <prefix>-NN.json next to it, as finish-feature.sh finds the latest review.
exception_latest_review() {
  local prefix="${1%-[0-9][0-9].json}"
  local reviews

  shopt -s nullglob
  reviews=("$prefix"-[0-9][0-9].json)
  shopt -u nullglob
  printf '%s\n' "${reviews[${#reviews[@]}-1]}"
}

# exception_blocking_findings <review-json>
# Prints the IDs of the critical and major findings of the review, one per
# line: the findings that make finish-feature.sh refuse.
exception_blocking_findings() {
  jq -r '.findings[] | select(.severity == "critical" or .severity == "major") | .id' "$1"
}

# exception_review_errors <root> <scratch-dir> <review-json> [<commit>]
# Prints why no exception to a finding of the review can count: the review
# is not the latest round, or it is not current for the content: the working
# tree, or the content of <commit> when given, such as the finish commit of
# a branch that merged its base afterwards. Prints nothing when it can.
exception_review_errors() {
  local latest
  local status=0

  latest="$(exception_latest_review "$3")"
  [[ "$latest" == "$3" ]] ||
    echo "${3#"$1"/} is not the latest review: ${latest#"$1"/} is newer"
  review_is_current "$1" "$2" "$3" ${4:+"$4"} || status=$?
  case "$status" in
    0) ;;
    1) echo "${3#"$1"/} is stale: the content changed after the review" ;;
    *) echo "the fingerprint of the reviewed content could not be computed" ;;
  esac
}

# exception_errors <root> <exception-json> <review-json>
# Prints one line per reason the record is not a valid exception to a
# blocking finding of that review: it does not follow its schema, it is not
# stored where it belongs, the review artifact changed since (its SHA-256),
# or a field disagrees with the review. Prints nothing for a valid record.
# Whether the review is the latest and current is exception_review_errors.
exception_errors() {
  local root="$1"
  local file="$2"
  local review="$3"
  local errors
  local finding

  errors="$(guardrails_request_errors "$file" "$root/$EXCEPTIONS_SCHEMA")"
  if [[ -n "$errors" ]]; then
    printf '%s\n' "$errors"
    return 0
  fi
  finding="$(jq -r '.finding_id' "$file")"
  [[ "$file" == "$(exception_file "$root" "$review" "$finding")" ]] ||
    echo "the record of finding $finding is not stored as ${EXCEPTIONS_DIR}/$(basename "$review" .json)-$finding.json"
  [[ "$(jq -r '.review_sha256' "$file")" == "$(exception_sha256 "$review")" ]] ||
    echo "the review artifact changed after the exception was recorded (its SHA-256 differs)"
  jq -r --arg review "${review#"$root"/}" --slurpfile r "$review" '
    $r[0] as $r
    | . as $e
    | ([$r.findings[] | select(.id == $e.finding_id)] | first) as $f
    | (if .review != $review then "it names the review \(.review), not \($review)" else empty end),
      (if .round != $r.round then "it names round \(.round), the review is round \($r.round)" else empty end),
      (if .reviewed_tree != $r.reviewed_tree then "its reviewed tree is not the reviewed tree of the review" else empty end),
      (if .merge_base != $r.merge_base then "its merge base is not the merge base of the review" else empty end),
      (if $f == null then "the review has no finding \(.finding_id)"
       else
         (if ($f.severity | IN("critical", "major")) | not then "finding \(.finding_id) is \($f.severity), not critical or major" else empty end),
         (if .finding_severity != $f.severity then "its severity is not the severity of finding \(.finding_id)" else empty end),
         (if .finding_title != $f.title then "its title is not the title of finding \(.finding_id)" else empty end)
       end),
      (if .type == "not-applicable" and ((.evidence // "") | test("\\S") | not)
       then "a not-applicable exception names the evidence that the finding is wrong" else empty end)
  ' "$file"
}

# exception_status <root> <scratch-dir> <review-json>
# Prints one tab-separated line per blocking finding of the review, in its
# order: 'valid<TAB><id><TAB><record><TAB><sha256>' when it has a valid
# exception, or 'missing<TAB><id><TAB><why>' when it has none or an invalid
# one. Prints nothing for a review without blocking findings.
exception_status() {
  local root="$1"
  local review="$3"
  local review_errors
  local id
  local file
  local errors

  review_errors="$(exception_review_errors "$root" "$2" "$review")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    file="$(exception_file "$root" "$review" "$id")"
    if [[ ! -f "$file" ]]; then
      printf 'missing\t%s\tno exception is recorded\n' "$id"
    elif [[ -n "$review_errors" ]]; then
      printf 'missing\t%s\tthe exception is invalid: %s\n' "$id" "$(printf '%s\n' "$review_errors" | paste -sd ';' - | sed 's/;/; /g')"
    else
      errors="$(exception_errors "$root" "$file" "$review")"
      if [[ -n "$errors" ]]; then
        printf 'missing\t%s\tthe exception is invalid: %s\n' "$id" "$(printf '%s\n' "$errors" | paste -sd ';' - | sed 's/;/; /g')"
      else
        printf 'valid\t%s\t%s\t%s\n' "$id" "${file#"$root"/}" "$(exception_sha256 "$file")"
      fi
    fi
  done < <(exception_blocking_findings "$review")
}

# exception_commit_lines <root> <record>...
# Prints the section of the commit message that lists the exceptions: per
# record the finding, the type, the account and time, the reason and the
# evidence, and the record with its SHA-256, which publish-feature.sh
# recomputes.
exception_commit_lines() {
  local root="$1"
  local record

  shift
  echo "Owner exceptions to blocking review findings:"
  for record in "$@"; do
    jq -r --arg path "${record#"$root"/}" --arg sha "$(exception_sha256 "$record")" '
      "- \(.finding_id) (\(.finding_severity)) \(.finding_title | gsub("\n"; " ")): \(.type), by \(.account) at \(.directed_at)",
      "  reason: \(.reason | gsub("\n"; " "))",
      (if .evidence != null then "  evidence: \(.evidence | gsub("\n"; " "))" else empty end),
      "  record: \($path) sha256 \($sha)"
    ' "$record"
  done
}

# exception_committed_records <commit-message-file>
# Prints the records that a commit message lists, as '<path><TAB><sha256>'.
exception_committed_records() {
  sed -n 's/^  record: \(\.agents\/exceptions\/[^ ]*\.json\) sha256 \([0-9a-f]\{64\}\)$/\1\t\2/p' "$1"
}

# exception_published <issue>
# Prints the records that record-exception.sh published on the Issue, as
# '<path><TAB><sha256>': what the owner confirmed, as it was shown. Fails
# when the comments cannot be read.
exception_published() {
  local bodies

  bodies="$(gh api "repos/{owner}/{repo}/issues/$1/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"$EXCEPTIONS_MARKER\")) | .body" </dev/null)" || return 1
  printf '%s\n' "$bodies" | tr -d '\r' |
    sed -n 's/^- Record: `\(\.agents\/exceptions\/[^`]*\.json\)`, SHA-256 `\([0-9a-f]\{64\}\)`$/\1\t\2/p'
}
