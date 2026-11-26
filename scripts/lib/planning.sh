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

# The Draft review of start-planning.sh: a read-only reviewer
# (.agents/prompts/requirements-reviewer.md) checks the Draft requirements
# before the owner approves them. Each round is stored, with the identifiers
# of its findings and the owner's decisions on them, as
# .agents/reviews/requirements-<name>-review-NN.json, which Git ignores.
PLANNING_DRAFT_REVIEW_SCHEMA="requirements-review/v1"

# planning_draft_review_errors <result-file>
# Prints why the reviewer's result does not match
# .agents/schemas/requirements-review.schema.json, one reason per line;
# prints nothing when it does. Needs review-data.sh.
planning_draft_review_errors() {
  review_data_is_json "$1" || {
    echo "the result is not exactly one JSON value"
    return 0
  }
  jq -r '
    def nonempty: type == "string" and test("\\S");
    if type != "object" then "the result is not a JSON object"
    else
      (keys - ["findings", "limitations"] | if length > 0 then "unknown field(s): \(join(", "))" else empty end),
      (if (.limitations | type) == "string" then empty else "limitations must be a string." end),
      (if (.findings | type) != "array" then "findings must be an array."
       else .findings | to_entries[] | (.key + 1) as $n | .value |
         if type != "object" then "finding \($n) is not an object."
         else
           (keys - ["category", "section", "quote", "problem", "proposed_wording"]
            | if length > 0 then "finding \($n) has unknown field(s): \(join(", "))." else empty end),
           (if (.category | IN("inconsistency", "infeasible", "unkept-promise", "unmeasurable")) then empty
            else "finding \($n): category must be inconsistency, infeasible, unkept-promise, or unmeasurable." end),
           (["section", "quote", "problem", "proposed_wording"][] as $field
            | if (.[$field] | nonempty) then empty else "finding \($n): \($field) must be a non-empty string." end)
         end
       end)
    end
  ' "$1"
}

# Amendments of the approved requirements: the AMEND decision of a planning
# triage (triage-review.sh) proposes a unified diff of them, which the owner
# confirms at a terminal; revise-planning.sh applies a recorded one again
# when a run ended before it did.
PLANNING_REQUIREMENTS="docs/PROJECT_REQUIREMENTS.md"

# planning_amendment_lines <diff-file>: the added and removed lines of a diff
# of one file, in order, without the file headers.
planning_amendment_lines() {
  awk '/^@@/ { hunk = 1; next } hunk && /^[-+]/ { print }' "$1"
}

# planning_amendment_apply <scratch-dir> <diff-file> <requirements-copy>:
# applies a diff of the requirements to a copy of them, exactly: it refuses a
# diff that touches another file, renames or changes a mode, changes the
# Status or Approved at line, or does not apply cleanly, and a result whose
# changed lines differ from those of the diff. Prints the reason of a
# refusal; the copy is unchanged then.
planning_amendment_apply() {
  local work="$1/amendment-apply"
  local diff="$2"
  local copy="$3"
  local touched

  rm -rf "$work"
  mkdir -p "$work/docs"
  git init -q "$work"
  cp "$copy" "$work/$PLANNING_REQUIREMENTS"
  touched="$(git -C "$work" apply --recount --numstat -- "$diff" 2>/dev/null)" || {
    echo "it is not a valid diff"
    return 1
  }
  [[ "$(printf '%s\n' "$touched" | cut -f3-)" == "$PLANNING_REQUIREMENTS" ]] || {
    echo "it must change $PLANNING_REQUIREMENTS and nothing else"
    return 1
  }
  [[ -z "$(git -C "$work" apply --recount --summary -- "$diff" 2>/dev/null)" ]] || {
    echo "it must not create, delete, rename, or change the mode of a file"
    return 1
  }
  ! grep -Eq '^[-+](Status|Approved at):' <<<"$(planning_amendment_lines "$diff")" || {
    echo "it must not change the Status or Approved at line; the script updates Approved at"
    return 1
  }
  git -C "$work" apply --recount -- "$diff" 2>"$work.err" || {
    echo "it does not apply cleanly to $PLANNING_REQUIREMENTS: $(head -n 1 "$work.err")"
    return 1
  }
  git diff --no-index --no-color --no-ext-diff --no-textconv -U0 -- "$copy" "$work/$PLANNING_REQUIREMENTS" >"$work.result" || true
  [[ "$(planning_amendment_lines "$work.result")" == "$(planning_amendment_lines "$diff")" ]] || {
    echo "applying it changes other lines than the diff shows"
    return 1
  }
  cp "$work/$PLANNING_REQUIREMENTS" "$copy"
}

# planning_amendment_errors <root> <scratch-dir> <decisions-file>: every
# proposed amendment must apply exactly, in the order of the decisions, to
# the requirements as they are. Prints one line per refused amendment.
planning_amendment_errors() {
  local root="$1"
  local scratch="$2"
  local copy="$2/requirements-check.md"
  local index=0
  local id
  local reason

  cp "$root/$PLANNING_REQUIREMENTS" "$copy"
  while IFS= read -r id; do
    jq -j --argjson i "$index" '[.decisions[] | objects | select(.decision == "AMEND")][$i].amendment | if endswith("\n") then . else . + "\n" end' "$3" \
      >"$scratch/amendment-check.diff"
    index=$((index + 1))
    reason="$(planning_amendment_apply "$scratch" "$scratch/amendment-check.diff" "$copy")" ||
      echo "the amendment of finding $id is refused: $reason"
  done < <(jq -r '.decisions[] | objects | select(.decision == "AMEND") | .finding_id' "$3")
}
