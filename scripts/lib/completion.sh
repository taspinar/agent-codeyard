#!/usr/bin/env bash

# The completion gate of a feature. Source this file; it needs jq.
#
# A session that ends without an error is not a feature that is complete.
# The implementer therefore states where the work stands in a completion
# record, .agents/completion/<issue>.json, and the scripts go on to the
# commit and the pull request only when that record says that the Issue is
# done. The record is the only source of remaining work: the handoff note is
# a readable report for people and the next session, and no script parses it
# for what remains or for the checks of findings. The record is a claim of
# the implementer: the independent review of the complete feature checks it
# against the code and the tests. Its schema is
# .agents/schemas/completion.schema.json:
#
#   {
#     "schema": "completion/v1",
#     "status": "complete" | "awaiting_evidence" | "partial" | "blocked",
#     "criteria": [
#       {"criterion": "<an acceptance criterion of the Issue, or a plan step>",
#        "gate": "implementation" | "pr_ci" | "owner_approval" | "post_merge",
#        "status": "met" | "not_met" | "not_applicable" | "pending",
#        "evidence": "<the test, file, or command that shows it; for
#                     not_applicable the reason, for pending the gate at
#                     which the evidence appears>"}
#     ],
#     "remaining": ["<what is left>", ...],
#     "checks": [                            (optional)
#       {"triage": "<triage file name>", "finding": "<finding id>",
#        "value": "fixed" | "refuted" | "not_reproduced" | "not_executable",
#        "evidence": "<the test or command and its result>"}
#     ],
#     "risk": "low" | "medium" | "high"   (optional)
#   }
#
# 'checks' is the triage implementer's check of each finding to fix that it
# was given (.agents/prompts/triage-implementer.md), kept across the rounds.
#
# 'risk' is the implementer's own classification of the feature (lib/risk.sh).
# It can raise the level that the scripts compute from the diff, never lower
# it: finish-feature.sh refuses a record that claims less.
#
# 'complete' needs every criterion met or not applicable and nothing
# remaining. 'partial' and 'blocked' need something that remains. The
# evidence of a criterion cannot be a partial run of the checks
# ('verify.sh --only', or '--changed' of an agent session): such a run is
# not a verification. Nor can the
# evidence of a met criterion be a budget check of scripts/verify.conf or
# scripts/verify-workflow.conf ('<name> [<group>] budget: <command>'), nor
# the target for the duration of their checks ('budget-seconds: <n>'): a
# budget is a measurement that never fails the verification, so it shows
# nothing about a criterion.
#
# Evidence appears at a gate: 'implementation' (the default, before the work
# is committed), 'pr_ci' (after the pull request is published, before the
# merge), 'owner_approval' (before the merge), 'post_merge' (after the
# merge, before the Issue is closed). A criterion is 'pending' only when its
# gate is a later one than 'implementation'. When every implementation
# criterion is met and only later evidence is pending, the status is
# 'awaiting_evidence': the work is ready to commit and publish, but it is not
# 'complete' until the pending evidence exists.

COMPLETION_DIR=".agents/completion"
COMPLETION_SCHEMA=".agents/schemas/completion.schema.json"
# The schema is read from the checkout of these scripts, not from the
# working tree a record is checked for.
COMPLETION_LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# completion_ready <status>
# Succeeds for a gate outcome that lets the work go on to the review, the
# commit, and the pull request.
completion_ready() {
  [[ "$1" == "complete" || "$1" == "awaiting_evidence" ]]
}

# completion_record <root> <issue>
# Prints the path of the completion record of the Issue.
completion_record() {
  printf '%s/%s/%s.json' "$1" "$COMPLETION_DIR" "$2"
}

# completion_budget_checks <root>
# Prints the names of the budget checks that the verification configuration
# of the working tree at <root> declares, one per line, and nothing without
# one, and 'budget-seconds' when a file declares a target for the duration of
# its checks. The syntax is that of scripts/verify.sh.
completion_budget_checks() {
  local file

  for file in "$1/scripts/verify.conf" "$1/scripts/verify-workflow.conf"; do
    [[ -f "$file" ]] || continue
    sed -nE 's/^([a-z0-9][a-z0-9-]*)([[:space:]]*\[[a-z0-9][a-z0-9-]*\])?[[:space:]]+budget([[:space:]]+framework)?:.*$/\1/p' "$file"
    if grep -Eq '^budget-seconds:' "$file"; then echo "budget-seconds"; fi
  done | sort -u
}

# completion_errors <record> [<root>]
# Prints what is wrong with a completion record, one problem per line, and
# nothing for a valid one. The record is checked against its schema
# ($COMPLETION_SCHEMA, by the generic validator of lib/guardrails.sh), whose
# lines name the field ('record.criteria[0].status must be one of ...'),
# and then by the rules across fields that a schema cannot express. With
# <root>, the evidence of a met criterion may not name a budget check of that
# working tree.
completion_errors() {
  local record="$1"
  local budget_checks=""

  if ! jq -e . "$record" >/dev/null 2>&1; then
    echo "it is not valid JSON"
    return 0
  fi
  # The generic validator, loaded when a record is checked: a script that
  # only reads the gate's outcome does not need it.
  declare -F guardrails_request_errors >/dev/null || source "$COMPLETION_LIB_ROOT/scripts/lib/guardrails.sh"
  guardrails_request_errors "$record" "$COMPLETION_LIB_ROOT/$COMPLETION_SCHEMA" record
  [[ -z "${2:-}" ]] || budget_checks="$(completion_budget_checks "$2")"
  jq -r --arg budget_checks "$budget_checks" '
    # A budget check named as a whole word in a text: not a word that merely
    # contains the name, such as a test or a path named after it.
    def budget_cited: . as $text
      | [$budget_checks | split("\n")[] | select(length > 0)
         | select(. as $name | $text | test("(^|[^a-z0-9_-])" + ($name | gsub("-"; "[-]")) + "($|[^a-z0-9_-])"))]
      | first // "";
    def statuses: [(.criteria | if type == "array" then .[] else empty end) | objects | .status];
    if type != "object" then empty
    else
      (.criteria | if type == "array" then to_entries[] else empty end |
         (.key + 1) as $n | .value | objects |
           (if .gate == "owner_approval" and (.status == "met")
            then "criterion \($n): owner_approval cannot be met in a record the implementer writes; it stays pending until the owner approves on GitHub" else empty end),
           (if .status == "pending" and ((.gate // "implementation") == "implementation")
            then "criterion \($n): pending is only for evidence of a later gate (pr_ci, owner_approval, or post_merge)" else empty end),
           (if (.evidence | type) == "string" and (.evidence | test("verify\\.sh([[:space:]]+-[^[:space:]]*)*[[:space:]]+--(only|changed)([[:space:]]|$)"))
            then "criterion \($n) cites a partial run of the checks (verify.sh --only or --changed) as evidence, which is not a verification" else empty end),
           (if .status == "met" and (.evidence | type) == "string" and (.evidence | budget_cited) != ""
            then "criterion \($n) cites the budget check \u0027\(.evidence | budget_cited)\u0027 as evidence of a met criterion; a budget is a measurement that never fails the verification, so it shows nothing about the criterion" else empty end)),
      (if (.status == "complete" or .status == "awaiting_evidence") and (statuses | index("not_met")) != null
       then "status is \(.status), but a criterion is not met" else empty end),
      (if .status == "complete" and (statuses | index("pending")) != null
       then "status is complete, but a criterion is pending; the status is awaiting_evidence until its evidence exists" else empty end),
      (if .status == "awaiting_evidence" and (statuses | index("pending")) == null
       then "status is awaiting_evidence, but no criterion is pending" else empty end),
      (if (.status == "complete" or .status == "awaiting_evidence") and (.remaining | type) == "array" and (.remaining | length) > 0
       then "status is \(.status), but work remains" else empty end),
      (if (.status == "partial" or .status == "blocked") and (.remaining | type) == "array"
          and (.remaining | length) == 0
       then "status is \(.status), but remaining does not say what is left" else empty end)
    end' "$record"
}

# completion_finding_checks <record> [<triage-name>]
# Prints the checks[] of a completion record: the check that the triage
# implementer recorded for each finding it was given
# (.agents/prompts/triage-implementer.md), one line per entry: <triage-name>
# TAB <finding-id> TAB <value> TAB <evidence>, with the tabs and line breaks
# of the evidence turned into spaces. With <triage-name>, only the entries of
# that triage. An entry that does not follow the schema (another value, no
# evidence, an id that is not one) is not a check, and a record that is
# missing or not JSON has none. The entries are the implementer's statement:
# they resolve nothing by themselves.
completion_finding_checks() {
  [[ -f "$1" ]] && jq -e . "$1" >/dev/null 2>&1 || return 0
  jq -r --arg only "${2:-}" --slurpfile schema "$COMPLETION_LIB_ROOT/$COMPLETION_SCHEMA" '
    ($schema[0].properties.checks.items.properties) as $fields
    | if type == "object" and (.checks | type) == "array" then .checks[] else empty end
    | objects
    | select((.triage | type) == "string" and (.triage | test($fields.triage.pattern))
        and (.finding | type) == "string" and (.finding | test($fields.finding.pattern))
        and (.value | IN($fields.value.enum[]))
        and (.evidence | type) == "string" and (.evidence | test($fields.evidence.pattern)))
    | select($only == "" or .triage == $only)
    | [.triage, .finding, .value, (.evidence | gsub("[\t\r\n]+"; " ") | gsub("^ +| +$"; ""))] | join("\t")' "$1"
}

# triage_check_outcomes <record> <triage-json>
# Prints, for each FIX_NOW finding of the triage, what the implementer's
# checks[] entries of that triage say: <finding-id> TAB <outcome> TAB
# <evidence>. <outcome> is the recorded value; 'missing' when the finding has
# no check, and 'conflicting' when its checks differ in value or in evidence
# (identical entries count once). Only 'fixed' is resolved; every other
# outcome leaves the finding open until a later fix records 'fixed' or a new
# triage decides otherwise.
triage_check_outcomes() {
  local checks

  checks="$(completion_finding_checks "$1" "$(basename "$2")")"
  jq -r --arg checks "$checks" '
    ($checks | split("\n") | map(select(length > 0) | split("\t")
      | {id: .[1], value: .[2], evidence: (.[3:] | join(" "))})) as $lines
    | .decisions[] | select(.decision == "FIX_NOW") | .finding_id as $id
    | [$lines[] | select(.id == $id)] as $mine
    | if ($mine | length) == 0 then "\($id)\tmissing\t"
      elif ($mine | map([.value, .evidence]) | unique | length) > 1
      then "\($id)\tconflicting\t\($mine | map(.value) | unique | join(", "))\(
        if ($mine | map(.value) | unique | length) == 1 then ", with differing evidence" else "" end)"
      else "\($id)\t\($mine[-1].value)\t\($mine[-1].evidence)"
      end' "$2"
}

# completion_summary_present <root> <issue>
# Succeeds when the implementer wrote the summary of the changes that the
# commit message is made from. An unattended run needs it: nobody edits the
# message there.
completion_summary_present() {
  local summary="$1/.agents/summaries/$2.md"

  [[ -f "$summary" ]] && grep -q '^[[:space:]]*- [^[:space:]]' "$summary"
}

# completion_gate <root> <issue>
# Decides whether the feature is complete. Prints the outcome on the first
# line and the reasons after it, one per line:
#
#   complete  the record is valid and says so; it is the only source of
#             remaining work, and no handoff note changes the outcome
#   awaiting_evidence
#             the same, and only evidence of a later gate is pending: the
#             work may be reviewed, committed, and published, but is not
#             complete yet. The reasons name what is pending.
#   partial   work remains, by the record
#   blocked   the implementer cannot go on without the human
#   missing   there is no record
#   invalid   the record cannot be used
completion_gate() {
  local root="$1"
  local issue="$2"
  local record
  local errors
  local status

  record="$(completion_record "$root" "$issue")"
  if [[ ! -f "$record" ]]; then
    echo "missing"
    echo "the implementer wrote no completion record ($COMPLETION_DIR/$issue.json)"
    return 0
  fi
  errors="$(completion_errors "$record" "$root")"
  if [[ -n "$errors" ]]; then
    echo "invalid"
    printf '%s\n' "$errors" | sed "s|^|the completion record ($COMPLETION_DIR/$issue.json): |"
    return 0
  fi

  status="$(jq -r '.status' "$record")"
  if ! completion_ready "$status"; then
    echo "$status"
    jq -r '.criteria[] | select(.status == "not_met") | "not met: \(.criterion)"' "$record"
    jq -r '.remaining[] | "remaining: \(.)"' "$record"
    return 0
  fi

  echo "$status"
  jq -r '.criteria[] | select(.status == "pending") | "pending at \(.gate): \(.criterion)"' "$record"
}

# completion_pending_gates <root> <issue>
# Prints the gates (pr_ci, owner_approval, post_merge) at which a criterion
# of the record is still pending, once each, and nothing when none is.
completion_pending_gates() {
  jq -r '[.criteria[] | select(.status == "pending") | .gate] | unique[]' "$(completion_record "$1" "$2")"
}

# completion_closing_pattern <issue>
# Prints an extended regular expression, to be matched without regard to
# case, for a keyword with which GitHub closes that Issue on a merge: in a
# pull request description, and in the message of a commit that reaches the
# default branch.
completion_closing_pattern() {
  printf '%s' "(^|[^[:alnum:]])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]*:?[[:space:]]+(#|[[:alnum:]_.-]+/[[:alnum:]_.-]+#|https?://github\\.com/[^[:space:]]+/issues/)$1([^0-9]|\$)"
}

# completion_neutralize_closing <issue>
# Copies standard input and turns every closing keyword for the Issue into
# 'Refs', so that text taken over from a commit message cannot close an Issue
# whose completion gate did not pass.
completion_neutralize_closing() {
  awk -v pattern="$(completion_closing_pattern "$1")" '
    {
      line = $0
      out = ""
      while (match(tolower(line), pattern)) {
        found = substr(line, RSTART, RLENGTH)
        # Keep what stands before the keyword and after the reference.
        lead = (tolower(found) ~ /^[^a-z]/) ? substr(found, 1, 1) : ""
        rest = substr(found, length(lead) + 1)
        sub(/^[A-Za-z]+([[:space:]]*:)?/, "Refs", rest)
        out = out substr(line, 1, RSTART - 1) lead rest
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }'
}

# completion_commit_lines <root> <issue>
# Prints the completion statement of a commit message from a valid record:
# the status, the criteria with their evidence, and what remains. A criterion
# that is pending at the post_merge gate also gets one line
# 'Post-merge criterion: "<criterion as a JSON string>"', which
# record-post-merge.sh reads: exact, whatever the criterion or its evidence
# contain.
completion_commit_lines() {
  local record

  record="$(completion_record "$1" "$2")"
  jq -r '
    "Completion: \(.status)",
    (.criteria[] | "- \(.status | gsub("_"; " "))\(if .status == "pending" then " at \(.gate)" else "" end): \(.criterion) (\(.evidence))"),
    (.remaining[] | "- remaining: \(.)"),
    (.criteria[] | select(.status == "pending" and .gate == "post_merge") | "Post-merge criterion: \(.criterion | tojson)")' "$record"
}

# completion_unconfirmed <record-file> <review-json>
# Prints one JSON line {criterion, reason, hold} per acceptance criterion
# that the review of the complete feature names as one it could not confirm
# (its unverified_criteria), and nothing for a review without such
# criteria. 'hold' is true when the owner must approve the merge for it:
# unless the entry names, by its text, a criterion that the record does not
# call met. The text is compared without regard to case, spacing, a list or
# checkbox prefix, backticks, or a trailing period. An entry that matches no
# criterion of the record, such as one named by its number, holds as well:
# what cannot be matched gives no permission.
completion_unconfirmed() {
  jq -c --slurpfile record "$1" '
    def norm: ascii_downcase | gsub("`"; "")
      | sub("^\\s*([-*]\\s+)?(\\[[ xX]\\]\\s*)?"; "") | gsub("\\s+"; " ") | sub("[\\s.]+$"; "");
    ($record[0].criteria // []) as $criteria
    | (.unverified_criteria // [])[]
    | (.criterion | norm) as $name
    | [$criteria[] | select((.criterion | type) == "string" and (.criterion | norm) == $name)] as $matched
    | {criterion, reason,
       hold: (($matched | length) == 0 or any($matched[]; .status == "met"))}' "$2"
}
