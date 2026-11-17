#!/usr/bin/env bash

# The planning documents and the planning approval.
# Source this file after fingerprint.sh; do not execute it.

# The planning scope: every document of the project planning. It names the
# optional description, the change requests of later change cycles, and the
# decisions directory even when they are absent, so adding, changing, or
# deleting any planning document changes its fingerprint.
PLANNING_SCOPE=(docs/PROJECT_DESCRIPTION.md docs/changes docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions)
PLANNING_APPROVAL_FILE="docs/PLANNING_APPROVAL.md"

# The part of the planning that only a planning cycle may change: what the
# product is and which features it gets. The rest of the scope, the
# architecture and the ADRs, is also kept up to date by features, which the
# Definition of Done asks for and a feature review covers.
PLANNING_PRODUCT_SCOPE=(docs/PROJECT_DESCRIPTION.md docs/changes docs/PROJECT_REQUIREMENTS.md docs/roadmap.md)

# The mark of a planning document that adopt-repository.sh reconstructed from
# an existing project: what its files show and what was inferred from them,
# not what the owner approved. It is the start of one line. Approving the
# requirements removes it from them (start-planning.sh), and the planning is
# approved only when no planning document carries it (finish-planning.sh).
PLANNING_OBSERVED_MARK="> **Observed, not approved.**"

# planning_observed_documents <root>
# Prints the planning documents that carry the mark at the start of a line,
# one per line.
planning_observed_documents() {
  local path

  for path in "${PLANNING_SCOPE[@]}"; do
    [[ -e "$1/$path" ]] || continue
    { grep -rl -- '^> \*\*Observed, not approved\.\*\*' "$1/$path" 2>/dev/null || true; } | while IFS= read -r file; do
      printf '%s\n' "${file#"$1"/}"
    done
  done | LC_ALL=C sort -u
}

# planning_tree_at <root> <scratch> <commit> <path...>
# Prints the fingerprint of the given paths as they are in a commit; it is
# comparable with fingerprint_files of the same content in a working tree.
planning_tree_at() {
  local root="$1"
  local index="$2/planning-tree-at.index"
  local commit="$3"

  shift 3
  rm -f "$index"
  GIT_INDEX_FILE="$index" git -C "$root" read-tree --empty &&
    git -C "$root" ls-tree -r "$commit" -- "$@" |
    GIT_INDEX_FILE="$index" git -C "$root" update-index --index-info &&
    GIT_INDEX_FILE="$index" git -C "$root" write-tree
}

# planning_approval_commit <root> <scratch> <recorded-fingerprint> [<from>]
# Prints the commit that recorded the approval: the last commit before
# <from> (default HEAD) that changed the approval file, when the planning
# documents in that commit have the recorded fingerprint. Prints nothing
# when there is none, for example after the file was edited by hand.
planning_approval_commit() {
  local root="$1"
  local scratch="$2"
  local recorded="$3"
  local from="${4:-HEAD}"
  local commit

  commit="$(git -C "$root" log -1 --format=%H "$from" -- "$PLANNING_APPROVAL_FILE" 2>/dev/null)" || return 0
  [[ -n "$commit" ]] || return 0
  [[ "$(planning_tree_at "$root" "$scratch" "$commit" "${PLANNING_SCOPE[@]}" 2>/dev/null)" == "$recorded" ]] || return 0
  printf '%s\n' "$commit"
}

# planning_feature_updates <root> <from> <to>
# Lists the commits between two commits that changed the architecture or the
# ADRs, oldest first, one per line: "<hash> <subject>", followed by the Issue
# and the review that finish-feature.sh recorded in the commit message, when
# the commit has them.
planning_feature_updates() {
  local root="$1"
  local commit
  local body
  local issue
  local review

  git -C "$root" log --no-merges --reverse --format='%H' "$2..$3" -- docs/architecture.md docs/decisions |
    while IFS= read -r commit; do
      body="$(git -C "$root" log -1 --format=%b "$commit")"
      issue="$(printf '%s\n' "$body" | sed -n 's/^Issue: //p' | head -n 1)"
      review="$(printf '%s\n' "$body" | sed -n 's/^Review: //p' | head -n 1)"
      printf '%s' "$(git -C "$root" log -1 --format='%h %s' "$commit")"
      [[ -z "$issue" && -z "$review" ]] ||
        printf ' (%s%s%s)' "${issue:+Issue $issue}" "${issue:+${review:+; }}" "${review:+review: $review}"
      printf '\n'
    done
}

# planning_recorded_updates <approval-file>
# Prints the updates by merged work that an approval file already records, as
# list items, so that a later approval keeps them.
planning_recorded_updates() {
  [[ -f "$1" ]] || return 0
  awk '
    /^## / { section = $0; next }
    section == "## Updates by merged work" && /^- / { print; next }
    section == "## Amendments after the approval" && /^  - / { sub(/^  /, ""); print }
  ' "$1"
}

# planning_approval_status <root> <scratch-dir>
# Exits 0 when the recorded planning approval is current, 1 when it is missing
# or stale, and 2 when it is malformed. Prints the reason for a non-zero
# status.
#
# The approval is current when the planning documents are as approved. It is
# also current when only the architecture or the ADRs changed since the commit
# that recorded it: features keep those up to date, under their own review.
# PLANNING_APPROVAL_UPDATED_SINCE then holds that commit, and is empty
# otherwise. A change to the description, the requirements, a change request,
# or the roadmap always makes the approval stale.
planning_approval_status() {
  local root="$1"
  local scratch="$2"
  local approval="$root/$PLANNING_APPROVAL_FILE"
  local recorded
  local current

  if [[ ! -f "$approval" ]]; then
    echo "the planning has not been approved: $PLANNING_APPROVAL_FILE is missing."
    return 1
  fi
  grep -Fqx "Status: Approved" "$approval" || {
    echo "$PLANNING_APPROVAL_FILE does not record an approval."
    return 2
  }
  recorded="$(sed -n 's/^Planning fingerprint: \([0-9a-f]\{40,64\}\)$/\1/p' "$approval")"
  [[ "$(printf '%s' "$recorded" | grep -c .)" -eq 1 ]] || {
    echo "$PLANNING_APPROVAL_FILE must contain exactly one valid planning fingerprint."
    return 2
  }
  current="$(fingerprint_files "$root" "$scratch" "${PLANNING_SCOPE[@]}")" || {
    echo "could not compute the fingerprint of the planning documents."
    return 2
  }
  PLANNING_APPROVAL_UPDATED_SINCE=""
  [[ "$current" != "$recorded" ]] || return 0

  local approved
  local product_now
  local product_then

  approved="$(planning_approval_commit "$root" "$scratch" "$recorded")"
  if [[ -n "$approved" ]] && git -C "$root" diff --quiet "$approved" -- "$PLANNING_APPROVAL_FILE" 2>/dev/null; then
    product_now="$(fingerprint_files "$root" "$scratch" "${PLANNING_PRODUCT_SCOPE[@]}")" || product_now=""
    product_then="$(planning_tree_at "$root" "$scratch" "$approved" "${PLANNING_PRODUCT_SCOPE[@]}")" || product_then=""
    if [[ -n "$product_now" && "$product_now" == "$product_then" ]]; then
      PLANNING_APPROVAL_UPDATED_SINCE="$approved"
      return 0
    fi
    echo "the description, the requirements, a change request, or the roadmap changed after the planning was approved; only a planning cycle may change those."
    return 1
  fi
  echo "a planning document changed after the planning was approved."
  return 1
}

# The owner's decisions on escalated findings of a planning review
# (finish-planning.sh --resolve). A decision says that the finding does not
# apply (not-applicable), or that the owner accepts the planning as it is with
# it (accepted), and only for a finding that the review rates minor. It is
# stored next to its review, which Git ignores too, as
# <review>-resolution-<finding-id>.json, and bound to that review by the hash
# of its file, its round, its branch, and its reviewed tree. It resolves the
# finding in its own round only: a changed planning makes the review stale,
# and a later round that raises the finding again needs a decision of its own.
PLANNING_RESOLUTION_SCHEMA="planning-resolution/v1"

# planning_resolution_file <review-json> <finding-id>
# Prints where the decision on that finding of that review is stored.
planning_resolution_file() {
  printf '%s-resolution-%s.json\n' "${1%.json}" "$2"
}

# planning_resolution_errors <root> <record> <review-json>
# Prints why the record is not a valid decision on a finding of the review as
# the review is now, one reason per line; prints nothing when it is.
planning_resolution_errors() {
  local root="$1"
  local record="$2"
  local review="$3"
  local blob

  if [[ ! -f "$record" || -L "$record" ]] || ! jq -es 'length == 1 and (.[0] | type) == "object"' "$record" >/dev/null 2>&1; then
    echo "${record#"$root"/} is not a JSON object."
    return 0
  fi
  if [[ ! -f "$review" ]] || ! jq -e 'type == "object"' "$review" >/dev/null 2>&1; then
    echo "its review ${review#"$root"/} is missing or invalid."
    return 0
  fi
  blob="$(git -C "$root" hash-object -- "$review")"
  jq -r --arg schema "$PLANNING_RESOLUTION_SCHEMA" --arg review "${review#"$root"/}" --arg blob "$blob" \
    --arg file "$(basename "$record")" --slurpfile r "$review" '
    def nonempty: type == "string" and test("\\S");
    $r[0] as $rev
    | (if .schema != $schema then "unknown schema: \(.schema)" else empty end),
      (if (.type | IN("not-applicable", "accepted")) then empty else "the type must be not-applicable or accepted." end),
      (if (.reason | nonempty) and (.reason | test("\n") | not) then empty else "the reason must be a single line that is not empty." end),
      (if (.decided_at | nonempty) then empty else "decided_at is missing." end),
      (if .review != $review then "it belongs to \(.review), not to \($review)." else empty end),
      (if .review_blob != $blob then "the review changed after the decision." else empty end),
      (if .round != $rev.round or .branch != $rev.branch or .reviewed_tree != $rev.reviewed_tree
       then "its round, branch, or reviewed tree differs from the review." else empty end),
      (if (.finding_id | type) == "string" and $file == ($review | sub(".*/"; "") | sub("\\.json$"; "")) + "-resolution-\(.finding_id).json"
       then empty else "its file name does not name its finding." end),
      (. as $d | ([$rev.findings[]? | select(.id == $d.finding_id)] | first) as $f
       | if $f == null then "the review has no finding \($d.finding_id)."
         elif $f.severity != "minor" then "the finding is \($f.severity) in the review; a decision resolves a minor finding only."
         else empty end)
  ' "$record"
}

# planning_resolutions <root> <name>
# Prints, as a JSON array ordered by round and finding, the valid decisions
# on findings of the planning reviews of planning/<name>. A record that is not
# valid is left out, and standard error says why.
planning_resolutions() {
  local root="$1"
  local prefix="$1/.agents/reviews/planning-$2-review-"
  local record
  local review
  local errors

  shopt -s nullglob
  for record in "$prefix"[0-9][0-9]-resolution-*.json; do
    review="${record%-resolution-*.json}.json"
    errors="$(planning_resolution_errors "$root" "$record" "$review")"
    if [[ -n "$errors" ]]; then
      echo "Ignored the decision ${record#"$root"/}: ${errors//$'\n'/ }" >&2
      continue
    fi
    jq -c . "$record"
  done | jq -s 'sort_by(.round, .finding_id)'
  shopt -u nullglob
}
