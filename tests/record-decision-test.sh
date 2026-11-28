#!/usr/bin/env bash

set -euo pipefail

# record-decision.sh: the block "## Owner decisions" at the end of the Issue
# body, created and extended through a fake GitHub that holds the Issue as
# JSON; the rest of the body stays byte for byte, and a caller without write
# access to the repository is refused.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/record-decision-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "record-decision test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_STATE/gh.log"
jq_filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" != "--jq" ]] || jq_filter="${args[$((i + 1))]}"
done
case "$*" in
  "api user --jq .login") echo "${MOCK_LOGIN-owner-login}" ;;
  "api repos/{owner}/{repo}/collaborators/"*"/permission --jq .permission")
    [[ -z "${MOCK_PERMISSION_FAIL:-}" ]] || { echo "HTTP 403" >&2; exit 1; }
    echo "${MOCK_PERMISSION-admin}"
    ;;
  "api -X PATCH repos/{owner}/{repo}/issues/"*)
    input=""
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[$i]}" != "--input" ]] || input="${args[$((i + 1))]}"
    done
    jq --slurpfile patch "$input" '.body = $patch[0].body' "$MOCK_STATE/issue.json" >"$MOCK_STATE/issue.new"
    mv "$MOCK_STATE/issue.new" "$MOCK_STATE/issue.json"
    echo x >>"$MOCK_STATE/patches"
    cat "$MOCK_STATE/issue.json"
    # Another writer right after this PATCH: MOCK_EDIT_AFTER_PATCH, a jq
    # filter on the Issue.
    if [[ -n "${MOCK_EDIT_AFTER_PATCH:-}" ]]; then
      jq "$MOCK_EDIT_AFTER_PATCH" "$MOCK_STATE/issue.json" >"$MOCK_STATE/issue.new"
      mv "$MOCK_STATE/issue.new" "$MOCK_STATE/issue.json"
    fi
    ;;
  "api repos/{owner}/{repo}/issues/"*)
    # Another writer between two reads: MOCK_EDIT_BEFORE_READ=<n> applies the
    # jq filter MOCK_EDIT to the Issue before its n-th read.
    echo x >>"$MOCK_STATE/reads"
    if [[ -n "${MOCK_EDIT_BEFORE_READ:-}" && "$(wc -l <"$MOCK_STATE/reads" | tr -d ' ')" -eq "$MOCK_EDIT_BEFORE_READ" ]]; then
      jq "$MOCK_EDIT" "$MOCK_STATE/issue.json" >"$MOCK_STATE/issue.new"
      mv "$MOCK_STATE/issue.new" "$MOCK_STATE/issue.json"
    fi
    if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter" "$MOCK_STATE/issue.json"; else cat "$MOCK_STATE/issue.json"; fi
    ;;
  *) echo "Unexpected gh invocation: $*" >&2; exit 97 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export MOCK_STATE="$tmp/state"
mkdir -p "$MOCK_STATE"

today="$(date -u +%Y-%m-%d)"

# set_body <body>: the Issue as the fake GitHub returns it.
set_body() {
  jq -n --arg body "$1" '{number: 12, title: "A feature", body: $body, html_url: "https://github.com/o/r/issues/12"}' >"$MOCK_STATE/issue.json"
  rm -f "$MOCK_STATE/patches" "$MOCK_STATE/reads"
}
# body: the body, with '|' after its last byte, so that a command
# substitution keeps its final newlines.
body() { jq -j '.body + "|"' "$MOCK_STATE/issue.json"; }
patches() { [[ -f "$MOCK_STATE/patches" ]] && wc -l <"$MOCK_STATE/patches" | tr -d ' ' || echo 0; }
record() { PATH="$tmp/bin:$ISOLATED_PATH" "$source_root/scripts/record-decision.sh" "$@" >"$tmp/out" 2>&1; }

# A body without the block: the block is created at its end, after a blank
# line, and every byte before it stays. The entry links the comment where the
# decision was made.
comment="https://github.com/o/r/issues/12#issuecomment-5"
link="[source]($comment)"
original=$'Intro.\n\n### Acceptance criteria\n\n- [ ] It works.'
set_body "$original"
record 12 "Keep the old format." --source "$comment" || { cat "$tmp/out" >&2; fail "recording the first decision failed"; }
expected="$original"$'\n\n## Owner decisions\n\n1. '"$today"' (@owner-login, '"$link"$'): Keep the old format.\n'
[[ "$(body)" == "$expected|" ]] || fail "the block was not created as expected: $(body | cat -A)"
grep -Fq "Recorded owner decision 1 on Issue #12" "$tmp/out" || fail "the recorded decision was not reported"

# A second decision, with its source and over several lines, is appended to
# the block as one entry with the next number.
record 12 $'Use the second\ndesign.' --source "https://github.com/o/r/issues/12#issuecomment-7" ||
  { cat "$tmp/out" >&2; fail "recording the second decision failed"; }
expected="${expected}2. $today (@owner-login, [source](https://github.com/o/r/issues/12#issuecomment-7)): Use the second design."$'\n'
[[ "$(body)" == "$expected|" ]] || fail "the second decision was not appended: $(body | cat -A)"

# A block in the middle of the body, with CR LF line ends, a section after it,
# and no newline at the end: the block, with the entry after its last one,
# moves to the end of the body, after a blank line, and the rest of the body,
# before and after the block, is kept byte for byte and in its order.
original=$'Intro.\r\n\r\n## Owner decisions\r\n\r\n1. 2026-01-01 (@owner-login): First.\r\n3. 2026-01-02 (@owner-login): Third.\r\n\r\n## Notes\r\nlast line'
set_body "$original"
record 12 "Fourth." --source https://github.com/o/r/pull/14 --replaces 3 || { cat "$tmp/out" >&2; fail "recording into a block with a section after it failed"; }
entry="4. $today (@owner-login, [source](https://github.com/o/r/pull/14)): Replaces decision 3. Fourth."
expected=$'Intro.\r\n\r\n## Notes\r\nlast line\n\n## Owner decisions\r\n\r\n1. 2026-01-01 (@owner-login): First.\r\n3. 2026-01-02 (@owner-login): Third.\r\n'"$entry"$'\n'
[[ "$(body)" == "$expected|" ]] ||
  fail "the block was not moved to the end with the entry after its last one, or the body changed elsewhere: $(body | cat -A)"
[[ "$(jq -r '.body' "$MOCK_STATE/issue.json" | grep -En '^#{1,2}[ \t]' | tail -n 1 | tr -d '\r')" == *":## Owner decisions" ]] ||
  fail "the block is not the last section of the body"
# The next entry, into the block now at the end, goes after the last one.
record 12 "Fifth." --source "$comment" || { cat "$tmp/out" >&2; fail "recording into the moved block failed"; }
expected="${expected}5. $today (@owner-login, $link): Fifth."$'\n'
[[ "$(body)" == "$expected|" ]] || fail "the fifth decision was not appended to the moved block: $(body | cat -A)"
# A section with a level-1 heading after the block is kept before it as well.
set_body $'## Owner decisions\n\n1. 2026-01-01 (@owner-login): First.\n\n# Appendix\n\nText.\n'
record 12 "Second." --source "$comment" || { cat "$tmp/out" >&2; fail "recording into a block before a level-1 heading failed"; }
[[ "$(body)" == $'# Appendix\n\nText.\n\n## Owner decisions\n\n1. 2026-01-01 (@owner-login): First.\n2. '"$today"' (@owner-login, '"$link"$'): Second.\n|' ]] ||
  fail "the block before a level-1 heading was not moved to the end: $(body | cat -A)"
set_body "$original"
record 12 "Fourth." --source https://github.com/o/r/pull/14 --replaces 3 >/dev/null || fail "recording the fourth decision again failed"
before="$(body)"

# A decision to replace that the block does not hold is refused, and so is a
# decision without --source, or with a source that is not the https link of a
# comment or a pull request (the bare Issue says not where the decision was
# made); nothing is written.
if record 12 "Other." --source "$comment" --replaces 9; then fail "a decision replacing a missing number was recorded"; fi
grep -Fq "no decision 9" "$tmp/out" || fail "the missing decision to replace was not named"
if record 12 "Other."; then fail "a decision without --source was recorded"; fi
grep -Fq -- "--source is required" "$tmp/out" || fail "the missing --source was not named: $(cat "$tmp/out")"
for bad in "javascript:alert(1)" "https://github.com/o/r/issues/12" "https://github.com/o/r/issues/12#top" \
  "https://github.com/o/r" "http://github.com/o/r/pull/14" "https://github.com/o/r/pull/14 x" "https://github.com/o/r/pull/14)"; do
  if record 12 "Other." --source "$bad"; then fail "the source '$bad' was accepted"; fi
  grep -Fq "comment" "$tmp/out" || fail "the refused source '$bad' was not explained: $(cat "$tmp/out")"
done
if record 12 "   " --source "$comment"; then fail "an empty decision was recorded"; fi
[[ "$(body)" == "$before" && "$(patches)" -eq 1 ]] || fail "a refused decision changed the Issue"

# The caller: only an account with write access to the repository records a
# decision; a reader, a permission that cannot be read, an unknown account,
# and an agent session are refused before the Issue is read or written.
set_body "$original"
: >"$MOCK_STATE/gh.log"
if MOCK_PERMISSION=read record 12 "Mine." --source "$comment"; then fail "a caller with read access recorded a decision"; fi
grep -Fq "is not the owner or a collaborator" "$tmp/out" || fail "the refused caller was not told why: $(cat "$tmp/out")"
if MOCK_PERMISSION=none record 12 "Mine." --source "$comment"; then fail "a caller without access recorded a decision"; fi
if MOCK_PERMISSION_FAIL=1 record 12 "Mine." --source "$comment"; then fail "a caller whose permission cannot be read recorded a decision"; fi
if MOCK_LOGIN="" record 12 "Mine." --source "$comment"; then fail "a decision was recorded without a known account"; fi
if CODEYARD_AGENT_SESSION=1 record 12 "Mine." --source "$comment"; then fail "an agent session recorded a decision"; fi
grep -Fq "agent session" "$tmp/out" || fail "the agent session was not named as the reason"
if grep -Eq 'issues/12' "$MOCK_STATE/gh.log"; then fail "a refused caller read or wrote the Issue"; fi
[[ "$(body)" == "$original|" && "$(patches)" -eq 0 ]] || fail "a refused caller changed the Issue"
MOCK_PERMISSION=write record 12 "A collaborator's decision." --source "$comment" || { cat "$tmp/out" >&2; fail "a collaborator with write access was refused"; }
MOCK_PERMISSION=maintain record 12 "A maintainer's decision." --source "$comment" || { cat "$tmp/out" >&2; fail "a maintainer was refused"; }
[[ "$(patches)" -eq 2 ]] || fail "the decisions of a collaborator and a maintainer were not written"

# Every entry the script wrote has a link to where the decision was made.
if grep -Ev '^[0-9]+\. [0-9-]+ \(@[^,]+, \[source\]\(https://[^)]+\)\): ' < <(jq -r '.body' "$MOCK_STATE/issue.json" | tr -d '\r' | grep -E '^[0-9]+\. ' | grep -Ev '^[13]\. 2026-01-0'); then
  fail "an entry was recorded without a link to its source"
fi

# Other sources that are accepted: a comment on a pull request, a review
# of it, and a line of its diff.
for good in "https://github.com/o/r/pull/14#issuecomment-8" "https://github.com/o/r/pull/14#pullrequestreview-9" \
  "https://github.com/o/r/pull/14/files#r10"; do
  record 12 "Linked." --source "$good" || { cat "$tmp/out" >&2; fail "the source '$good' was refused"; }
  grep -Fq "[source]($good)): Linked." <<<"$(jq -r '.body' "$MOCK_STATE/issue.json")" || fail "the source '$good' was not the link of the entry"
done

# Text that begins with "Replaces decision" without --replaces is refused:
# only --replaces writes the words that end a decision. With --replaces the
# metadata comes first, and prose that mentions a decision replaces none.
set_body $'## Owner decisions\n\n1. 2026-01-01 (@owner-login, [source]('"$comment"$')): First.\n'
before="$(body)"
for text in "Replaces decision 1. Something else." "replaces  decision 1: other."; do
  if record 12 "$text" --source "$comment"; then fail "the text '$text' was recorded without --replaces"; fi
  grep -Fq -- "--replaces" "$tmp/out" || fail "the refusal of '$text' did not name --replaces: $(cat "$tmp/out")"
done
[[ "$(body)" == "$before" && "$(patches)" -eq 0 ]] || fail "a refused replacement text changed the Issue"
record 12 "Nothing here replaces decision 1." --source "$comment" || { cat "$tmp/out" >&2; fail "prose that mentions a decision was refused"; }
source "$source_root/scripts/lib/issue-comments.sh"
replaced() { jq -r '.body' "$MOCK_STATE/issue.json" | jq -Rsc "$ISSUE_DECISIONS_JQ_DEFS"' decision_replaced'; }
[[ "$(replaced)" == "[]" ]] || fail "prose in an entry replaced a decision: $(replaced)"
record 12 "Other." --source "$comment" --replaces 1 || { cat "$tmp/out" >&2; fail "a replacement with --replaces was refused"; }
[[ "$(replaced)" == "[1]" ]] || fail "the entry written with --replaces did not replace decision 1: $(replaced)"
# Hand-written or differently cased words after the link replace nothing.
set_body $'## Owner decisions\n\n1. 2026-01-01 (@o, [source]('"$comment"$')): First.\n2. 2026-01-02 (@o, [source]('"$comment"$')): replaces decision 1. lower case.\n3. 2026-01-02 (@o, [source]('"$comment"$')): See: Replaces decision 1. later in the text.\n'
[[ "$(replaced)" == "[]" ]] || fail "words that are not the metadata of --replaces replaced a decision: $(replaced)"

# One writer at a time. A body that changes between the first read and the
# read right before the PATCH stops the command; nothing is written, and it
# says to run it again.
race_entry='"2. 2026-01-03 (@other, [source](https://github.com/o/r/issues/12#issuecomment-9)): Theirs."'
set_body $'## Owner decisions\n\n1. 2026-01-01 (@owner-login, [source]('"$comment"$')): First.\n'
if MOCK_EDIT_BEFORE_READ=2 MOCK_EDIT=".body += $race_entry + \"\\n\"" record 12 "Mine." --source "$comment"; then
  fail "a decision was recorded over a body that changed after it was read"
fi
grep -Fq "changed while the decision was prepared" "$tmp/out" && grep -Fq "run the command again" "$tmp/out" ||
  fail "the changed body was not reported with what to do: $(cat "$tmp/out")"
[[ "$(patches)" -eq 0 ]] || fail "the command wrote over a body that changed after it was read"
grep -Fq "Theirs." <<<"$(body)" || fail "the other writer's decision was lost"
# A write right after the PATCH that drops the entry, or gives another entry
# its number, makes the command fail with what to check.
set_body $'## Owner decisions\n\n1. 2026-01-01 (@owner-login, [source]('"$comment"$')): First.\n'
if MOCK_EDIT_AFTER_PATCH=".body = \"## Owner decisions\\n\\n1. x\\n\" + $race_entry + \"\\n\"" record 12 "Mine." --source "$comment"; then
  fail "a lost decision was reported as recorded"
fi
grep -Fq "does not hold decision 2 exactly once" "$tmp/out" && grep -Fq "Look at the block" "$tmp/out" ||
  fail "the lost decision was not reported with what to check: $(cat "$tmp/out")"
set_body $'## Owner decisions\n\n1. 2026-01-01 (@owner-login, [source]('"$comment"$')): First.\n'
if MOCK_EDIT_AFTER_PATCH=".body += $race_entry + \"\\n\"" record 12 "Mine." --source "$comment"; then
  fail "a decision whose number another entry has was reported as recorded"
fi
grep -Fq "with a number of its own" "$tmp/out" || fail "the reused number was not reported: $(cat "$tmp/out")"
grep -Fq "Mine." <<<"$(body)" || fail "the decision was not written"

# An empty body gets the block alone.
set_body ""
record 12 "Only this." --source "$comment" || { cat "$tmp/out" >&2; fail "recording into an empty body failed"; }
[[ "$(body)" == $'## Owner decisions\n\n1. '"$today"' (@owner-login, '"$link"$'): Only this.\n|' ]] ||
  fail "an empty body did not get the block alone: $(body | cat -A)"

echo "record-decision test passed"
