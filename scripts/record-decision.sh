#!/usr/bin/env bash
case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi

set -euo pipefail

usage() {
  echo "Usage: $0 <issue-number> \"<decision>\" --source <url> [--replaces <n>]"
  echo
  echo "Records a decision of the owner on a feature in the block '## Owner decisions'"
  echo "at the end of the Issue body: one numbered entry with the date, the account"
  echo "that recorded it, and the link to where it was made: --source, required, the"
  echo "comment (.../issues/<n>#issuecomment-<id>, also on a pull request) or the pull"
  echo "request (.../pull/<n>, with any part of it after it). Every entry has its link."
  echo "The block is created when the body has none, and moved to the end when another"
  echo "section follows it; the rest of the body is kept byte for byte. Every role of"
  echo "the feature reads the block apart from the comments, and a fix that would"
  echo "depart from a decision stops the run for you (docs/development.md, 'Owner"
  echo "decisions')."
  echo
  echo "A decision is never removed. --replaces <n> says that this decision replaces"
  echo "decision <n> of the block, which then no longer stands."
  echo
  echo "Only the owner, a member, or a collaborator of the repository with write"
  echo "access may record a decision: the account that gh is signed in to is checked,"
  echo "and the script is refused in an agent session. Run from any checkout."
  echo
  echo "Examples:"
  echo "  $0 12 \"Keep the old file format; no migration.\" --source https://github.com/o/r/issues/12#issuecomment-1"
  echo "  $0 12 \"Use the second design.\" --source https://github.com/o/r/pull/14#pullrequestreview-2"
  echo "  $0 12 \"Migrate after all, in this feature.\" --source https://github.com/o/r/issues/12#issuecomment-3 --replaces 1"
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

source_url="" replaces="" positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || usage
      source_url="$2"
      shift
      ;;
    --replaces)
      [[ $# -ge 2 ]] || usage
      replaces="$2"
      shift
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *) positional+=("$1") ;;
  esac
  shift
done
[[ "${#positional[@]}" -eq 2 ]] || usage
issue="${positional[0]}"
# One line: a decision is one entry of a numbered list.
decision="$(printf '%s' "${positional[1]}" | tr '\r\n\t' '   ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//')"

[[ "$issue" =~ ^[0-9]+$ ]] || fail "issue number must be numeric: $issue"
[[ -n "$decision" ]] || fail "the decision is empty."
# The link of the entry, [source](<url>), to where the decision was made: a
# comment (on an Issue or a pull request) or a pull request, never the bare
# Issue, which does not say where in it. No space and no parenthesis.
url_pattern='^https://[^/[:space:]()]+/[^/[:space:]()]+/[^/[:space:]()]+/((issues|pull)/[0-9]+#issuecomment-[0-9]+|pull/[0-9]+([/#][^[:space:]()]*)?)$'
[[ -n "$source_url" ]] ||
  fail "--source is required: the link to the comment or pull request where the decision was made. Nothing was recorded."
[[ "$source_url" =~ $url_pattern ]] ||
  fail "--source must be an https:// link without spaces or parentheses to the comment (.../issues/<n>#issuecomment-<id>) or the pull request (.../pull/<n>) where the decision was made: $source_url. Nothing was recorded."
[[ -z "$replaces" || "$replaces" =~ ^[1-9][0-9]*$ ]] || fail "--replaces needs the number of an earlier decision: $replaces"
[[ "${CODEYARD_AGENT_SESSION:-}" != "1" ]] ||
  fail "a decision is the owner's; record-decision.sh is refused in an agent session."
command -v gh >/dev/null 2>&1 || fail "GitHub CLI 'gh' is not installed."
command -v jq >/dev/null 2>&1 || fail "jq is required."
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/issue-comments.sh"

# The caller: the account that gh is signed in to, with write access to the
# repository, as the owner, a member, or a collaborator has it. A login is
# letters, digits and hyphens, a bot's with '[bot]'.
login="$(gh api user --jq .login </dev/null 2>/dev/null || true)"
[[ "$login" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] ||
  fail "could not determine the GitHub account that gh is signed in to (gh api user). Nothing was recorded."
permission="$(gh api "repos/{owner}/{repo}/collaborators/$login/permission" --jq .permission </dev/null 2>/dev/null || true)"
case "$permission" in
  admin | maintain | write) ;;
  "") fail "could not read the permission of @$login on the repository, so whether @$login may record a decision is unknown. Nothing was recorded." ;;
  *) fail "@$login is not the owner or a collaborator with write access to the repository (permission: $permission); only they record a decision. Nothing was recorded." ;;
esac

scratch="$(mktemp -d "${TMPDIR:-/tmp}/record-decision.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# The body as GitHub holds it, as JSON, so that it is kept exactly.
gh api "repos/{owner}/{repo}/issues/$issue" </dev/null >"$scratch/issue.json" 2>"$scratch/errors" ||
  fail "could not read Issue #$issue: $(tail -n 3 "$scratch/errors" | tr '\n' ' ')"
jq -e '(.body // "") | type == "string"' "$scratch/issue.json" >/dev/null 2>&1 ||
  fail "GitHub returned no readable Issue #$issue."
! jq -e 'has("pull_request")' "$scratch/issue.json" >/dev/null 2>&1 ||
  fail "#$issue is a pull request, not an Issue."
if [[ -n "$replaces" ]] &&
  ! jq -e --argjson n "$replaces" "$ISSUE_DECISIONS_JQ_DEFS"' (.body // "") | decision_numbers | index($n) != null' "$scratch/issue.json" >/dev/null; then
  fail "the block of Issue #$issue has no decision $replaces to replace. Nothing was recorded."
fi

# The new body: the entry appended to the block, after its last line that is
# not blank, or a new block at the end of the body. A block that another
# section follows moves to the end of the body with the entry, so that it is
# the last section; every byte of the body outside the block stays, in its
# order. The blank lines after the last entry of a moved block are dropped.
jq --arg decision "$decision" --arg source "$source_url" --arg replaces "$replaces" \
  --arg login "$login" --arg date "$(date -u +%Y-%m-%d)" --arg heading "$ISSUE_DECISIONS_HEADING" \
  "$ISSUE_DECISIONS_JQ_DEFS"'
  (.body // "") as $body
  | (($body | decision_numbers | max // 0) + 1) as $n
  | ("\($n). \($date) (@\($login), [source](\($source))): " +
     (if $replaces != "" then "Replaces decision \($replaces). " else "" end) + $decision) as $entry
  | ($body | decision_bounds) as $b
  | def at_end($rest; $block):
      $rest
      + (if $rest == "" or ($rest | endswith("\n\n")) or ($rest | endswith("\r\n\r\n")) then ""
         elif ($rest | endswith("\n")) then "\n"
         else "\n\n" end)
      + $block + "\n";
    {number: $n, entry: $entry,
     body: (if $b == null then at_end($body; $heading + "\n\n" + $entry)
       else
         ($body | decision_lines) as $l
         | (last(range($b.start; $b.end) | select($l[.] | bare | test("[^ \t]")))) as $k
         | (if $k == $b.start then ["", $entry] else [$entry] end) as $insert
         | if $b.end == ($l | length) then ($l[:$k + 1] + $insert + $l[$k + 1:]) | join("\n")
           else at_end($l[:$b.start] + $l[$b.end:] | join("\n"); $l[$b.start:$k + 1] + $insert | join("\n"))
           end
       end)}' "$scratch/issue.json" >"$scratch/new.json" ||
  fail "could not build the new body of Issue #$issue. Nothing was recorded."

number="$(jq -r '.number' "$scratch/new.json")"
jq '{body}' "$scratch/new.json" >"$scratch/patch.json"
gh api -X PATCH "repos/{owner}/{repo}/issues/$issue" --input "$scratch/patch.json" </dev/null >"$scratch/patched.json" 2>"$scratch/errors" ||
  fail "could not update the body of Issue #$issue: $(tail -n 3 "$scratch/errors" | tr '\n' ' ') Nothing was recorded."
jq -e --slurpfile want "$scratch/patch.json" '.body == $want[0].body' "$scratch/patched.json" >/dev/null 2>&1 ||
  echo "Warning: GitHub returned another body than the one sent; look at Issue #$issue to check decision $number." >&2

echo "Recorded owner decision $number on Issue #$issue:"
echo "  $(jq -r '.entry' "$scratch/new.json")"
echo "Every role of the feature reads it from the next session on."
