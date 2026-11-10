#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  echo "Usage: $0 <base-commit> <head-commit> <out-dir>"
  echo
  echo "The decision of the merge approval gate for a pull request, as CI shows it."
  echo "Runs check-guardrails.sh --commits <base-commit> <head-commit>"
  echo "--fail-on-protected and decides what the check of the pull request shows:"
  echo
  echo "  success          nothing the owner must approve is changed"
  echo "  action_required  a protected path is changed and the pull request carries an"
  echo "                   approval request that the gate accepts: the owner's"
  echo "                   approval is required"
  echo "  failure          a protected path is changed without an accepted approval"
  echo "                   request, a request is refused (status 4), or the gate"
  echo "                   could not run"
  echo
  echo "Writes <out-dir>/conclusion (one of the three), <out-dir>/title, and"
  echo "<out-dir>/summary.md (the reasons and the output of the gate), and prints the"
  echo "summary. It exits 0 when the decision is written, whatever it is, and 2 on a"
  echo "usage error. GitHub counts only success, neutral, and skipped as passing a"
  echo "required check, so action_required keeps an unapproved protected change"
  echo "from merging through a required check."
  exit 2
}

[[ $# -eq 3 ]] || usage
[[ "$1" != --* && -n "$3" ]] || usage
out="$3"
mkdir -p "$out"

status=0
output="$("$script_dir/check-guardrails.sh" --commits "$1" "$2" --fail-on-protected 2>&1)" || status=$?

# bullets <prefix>: the lines of the output that start with '<prefix>: ', as
# a Markdown list without the prefix.
bullets() {
  printf '%s\n' "$output" | sed -n "s/^$1: \(.*\)/- \1/p"
}

case "$status" in
  0)
    conclusion="success"
    title="No owner approval needed"
    text="The pull request changes nothing that only the owner may approve."
    ;;
  3)
    if printf '%s\n' "$output" | grep -q '^request: '; then
      conclusion="action_required"
      title="Owner approval required"
      text="The pull request changes what only the owner may approve. This is not a defect: the owner reviews it and merges it, or not."$'\n\n'"Reasons:"$'\n'"$(bullets protected)"$'\n\n'"Approval request, which names the content tree recomputed here and grants nothing:"$'\n'"$(bullets request)"
    else
      conclusion="failure"
      title="Approval request missing"
      text="The pull request changes what only the owner may approve and carries no approval request (.agents/approval-requests/<issue>.json), which finish-feature.sh writes and commits with such a feature."$'\n\n'"Reasons:"$'\n'"$(bullets protected)"
    fi
    ;;
  4)
    conclusion="failure"
    title="Approval request refused"
    text="An approval request of the pull request is refused: it is malformed or names another content tree."$'\n\n'"$(bullets refused)"
    ;;
  *)
    conclusion="failure"
    title="The merge approval gate could not run"
    text="check-guardrails.sh exited with status $status."
    ;;
esac

# The output of the gate follows the decision. A check run takes a summary
# of at most 65535 characters.
summary="## $title"$'\n\n'"$text"$'\n\n'"Output of check-guardrails.sh:"$'\n\n''```text'$'\n'"$(printf '%s\n' "$output" | head -c 50000)"$'\n''```'
printf '%s\n' "$conclusion" >"$out/conclusion"
printf '%s\n' "$title" >"$out/title"
printf '%s\n' "$summary" >"$out/summary.md"
echo "conclusion: $conclusion"
printf '%s\n' "$summary"
