#!/usr/bin/env bash

set -euo pipefail

# The overview of scripts/status.sh: one row per feature with a worktree or an
# open pull request, its phase from the run records, the owner decision it
# waits for, the Markdown table, --changes, and the notification hook. GitHub
# is a fake 'gh' that answers from files.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/status-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
sleeper=""
trap '[[ -z "$sleeper" ]] || kill "$sleeper" 2>/dev/null || true; rm -rf "$tmp"' EXIT

fail() {
  echo "status test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# The fake GitHub CLI, answering from $FAKE_GH_DIR:
# - 'pr list --state open|merged [--head <branch>] --limit <n>': the first <n>
#   of open.json or merged.json (of <branch>); every call is logged in 'log';
# - 'issue view <n>': the title "Title <n>";
# - 'api .../issues/<n>/comments --jq <filter>': comments-<n>.json, filtered;
# - 'api .../contents/<path>?ref=<oid>': found when has-<oid> exists, HTTP 404
#   when lacks-<oid> exists, and an error otherwise.
# FAKE_GH_FAIL makes every call fail.
mkdir -p "$tmp/bin" "$tmp/gh"
ln -sf "$(command -v jq)" "$tmp/bin/jq"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ -z "${FAKE_GH_FAIL:-}" ]] || exit 1
dir="$FAKE_GH_DIR"
printf '%s\n' "$*" >>"$dir/log"
state="open" head="" limit=30 filter="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --state) state="${args[$((i + 1))]}" ;;
    --head) head="${args[$((i + 1))]}" ;;
    --limit) limit="${args[$((i + 1))]}" ;;
    --jq) filter="${args[$((i + 1))]}" ;;
  esac
done
case "$1 $2" in
  "pr list")
    jq -c --arg head "$head" --argjson limit "$limit" \
      '[.[] | select($head == "" or .headRefName == $head)] | .[:$limit]' "$dir/$state.json"
    ;;
  "issue view") echo "Title $3" ;;
  "api repos/{owner}/{repo}/issues/"*"/comments")
    n="${2#repos/\{owner\}/\{repo\}/issues/}"
    n="${n%/comments}"
    [[ -f "$dir/comments-$n.json" ]] || { echo '[]' >"$dir/comments-$n.json"; }
    jq -r "$filter" "$dir/comments-$n.json"
    ;;
  "api repos/{owner}/{repo}/contents/"*)
    ref="${2##*ref=}"
    if [[ -e "$dir/has-$ref" ]]; then exit 0; fi
    if [[ -e "$dir/lacks-$ref" ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo "gh: error connecting to api.github.com" >&2
    exit 1
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
echo '[]' >"$tmp/gh/open.json"
echo '[]' >"$tmp/gh/merged.json"

repo="$tmp/repo"
mkdir -p "$repo/scripts/lib"
cp "$source_root/scripts/status.sh" "$repo/scripts/"
cp "$source_root/scripts/lib/records.sh" "$source_root/scripts/lib/experience.sh" "$source_root/scripts/lib/completion.sh" \
  "$source_root/scripts/lib/github.sh" "$repo/scripts/lib/"
workflow_gitignore "$repo/.gitignore"
git -C "$repo" init -q -b main
git -C "$repo" -c user.name=t -c user.email=t@example.com add -A
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m init
records="$repo/.agents/run/records"
mkdir -p "$records"

# feature <issue>: a worktree of feature/<issue>-x; prints its path.
feature() {
  git -C "$repo" worktree add -q -b "feature/$1-x" "$tmp/wt-$1" main
  mkdir -p "$tmp/wt-$1/.agents/handoffs" "$tmp/wt-$1/.agents/completion" "$tmp/wt-$1/.agents/approval-requests"
}

# event <issue> <run> <epoch> <type> <json-fields>: one event of a run record.
event() {
  jq -cn --arg run "$2" --argjson epoch "$3" --arg type "$4" --argjson fields "$5" \
    '{schema: "run-record/v1", run: $run, time: ($epoch | todate), epoch: $epoch, type: $type} + $fields' >>"$records/$2.jsonl"
}

# run_start <issue> <run> <epoch> [command]
run_start() {
  event "$1" "$2" "$3" run-start "{\"kind\":\"feature\",\"subject\":\"$1\",\"command\":\"${4:-run-feature.sh}\",\"seq\":$3}"
}

# completion <issue> <status> <criteria-json>
completion() {
  jq -n --arg status "$2" --argjson criteria "$3" \
    '{schema: "completion/v1", status: $status, criteria: $criteria,
      remaining: (if $status == "partial" or $status == "blocked" then ["the question"] else [] end)}' \
    >"$tmp/wt-$1/.agents/completion/$1.json"
}

status() {
  (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" FAKE_GH_DIR="$tmp/gh" ./scripts/status.sh "$@")
}

# open_pr <number> <jq-update>: changes an open pull request of the fake.
open_pr() {
  jq --argjson n "$1" "(.[] | select(.number == \$n)) |= ($2)" "$tmp/gh/open.json" >"$tmp/gh/open.tmp" &&
    mv "$tmp/gh/open.tmp" "$tmp/gh/open.json"
}

# row <output> <issue>: the block of a feature in the terminal output.
row() {
  awk -v head="#$2 " 'index($0, head) == 1 { on = 1 } on && /^$/ { exit } on' <<<"$1"
}

main_oid="$(git -C "$repo" rev-parse main)"

# 1. Nothing to show.
[[ "$(status)" == "No feature has a worktree or an open pull request." ]] || fail "an empty overview is not said plainly"

# The cron line that docs/development.md documents works in a fresh
# checkout, before .agents/status/ exists: its log is in that directory. The
# line is the test's own; that the template's documents show the same one is
# checked in the template only (template_repository in tests/lib-fakes.sh): a
# project may have written its own docs/development.md.
cron_line='*/10 * * * * cd /path/to/project && mkdir -p .agents/status && ./scripts/status.sh --changes >/dev/null 2>>.agents/status/cron.log'
cron_command="$(sed -E 's/^([^ ]+ ){5}//; s#/path/to/project#'"$repo"'#' <<<"$cron_line")"
[[ ! -e "$repo/.agents/status" ]] || fail "the fresh checkout has .agents/status already"
(cd / && PATH="$tmp/bin:$ISOLATED_PATH" FAKE_GH_DIR="$tmp/gh" sh -c "$cron_command") ||
  fail "the cron example fails in a fresh checkout: $cron_command"
[[ -f "$repo/.agents/status/cron.log" ]] || fail "the cron example does not log: $cron_command"
[[ ! -e "$repo/.agents/status/lock" ]] || fail "--changes leaves its lock behind"

# The template's docs/development.md shows that line, and the site's "How
# the workflow works" page the same cron and launchd examples.
if template_repository "$source_root"; then
  [[ "$(grep -E '^\*/10 \* \* \* \* ' "$source_root/docs/development.md")" == "$cron_line" ]] ||
    fail "the cron example of docs/development.md is not the line this test runs"
  site_page="$source_root/website/src/content/docs/detailed-workflow.md"
  site_cron="$(grep -E '^\*/10 \* \* \* \* ' "$site_page")" || fail "the site page has no cron example"
  [[ "$site_cron" == "$cron_line" ]] || fail "the site's cron example differs from docs/development.md: $site_cron"
  plist() { awk '/^<\?xml /{ on = 1 } on { print } /^<\/plist>/{ exit }' "$1"; }
  site_plist="$(plist "$site_page")"
  [[ -n "$site_plist" ]] || fail "the site page has no launchd example"
  [[ "$site_plist" == "$(plist "$source_root/docs/development.md")" ]] ||
    fail "the site's launchd example differs from docs/development.md"
fi

# 2. A running feature: its run has no end, and the PID in its run id lives.
feature 11
sleep 300 &
sleeper=$!
run="20261101T100000Z-$sleeper-1"
run_start 11 "$run" 1000
event 11 "$run" 1010 step-start '{"id":"a","name":"implementation"}'
event 11 "$run" 1020 step '{"id":"a","name":"implementation","status":0,"seconds":10}'
event 11 "$run" 1030 verification '{"status":0,"seconds":5,"reused":false,"groups":"all","trusted":true,"origin":"orchestrator"}'
event 11 "$run" 1040 step-start '{"id":"b","name":"review, round 2 of at most 5"}'

# 3. A stopped feature with a question: status 3, and a blocked record.
feature 12
run="20261101T100000Z-999999999-2"
run_start 12 "$run" 1000
event 12 "$run" 1010 step-start '{"id":"a","name":"implementation"}'
event 12 "$run" 1020 run-end '{"status":3,"step":"implementation","reason":"the implementer needs a decision of yours; its question is in the handoff note"}'
completion 12 blocked '[{"criterion":"c","status":"not_met","evidence":"waiting"}]'
# The question itself, in the handoff note, over two lines and with a '|'.
cat >"$tmp/wt-12/.agents/handoffs/12.md" <<'NOTE'
#12 blocked.

## Open questions

- Should the import keep duplicate rows
  or drop them | merge them?

## Remaining

- the import
NOTE
# A verification by hand afterwards changes nothing in the phase; its pass
# shows that it is not trusted evidence.
run_start 12 20261101T110000Z-999999999-22 1100 verify.sh
event 12 20261101T110000Z-999999999-22 1110 verification '{"status":0,"seconds":5,"reused":false,"groups":"all","trusted":false,"origin":"manual"}'
event 12 20261101T110000Z-999999999-22 1120 run-end '{"status":0}'

# 4. An open pull request that needs the owner's approval, checks passing.
feature 13
run="20261101T100000Z-999999999-3"
run_start 13 "$run" 1000
event 13 "$run" 1020 run-end '{"status":0}'
echo '{}' >"$tmp/wt-13/.agents/approval-requests/13.json"
git -C "$tmp/wt-13" add -f .agents/approval-requests/13.json
git -C "$tmp/wt-13" -c user.name=t -c user.email=t@example.com commit -q -m request
oid_13="$(git -C "$tmp/wt-13" rev-parse HEAD)"

# 5. A conflicting pull request with a failing check.
feature 14

# 6. A merged pull request with a pending post_merge criterion.
feature 15
completion 15 awaiting_evidence '[{"criterion":"the site deploys","gate":"post_merge","status":"pending","evidence":"after the merge"}]'

# 7. An open pull request of a feature without a worktree here, ready to merge.
jq -n --arg oid13 "$oid_13" --arg main "$main_oid" '[
  {number: 113, title: "PR 13", url: "https://github.test/pull/113", headRefName: "feature/13-x", headRefOid: $oid13, isDraft: false,
   mergeable: "MERGEABLE", reviewDecision: "REVIEW_REQUIRED",
   statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]},
  {number: 114, title: "PR 14", url: "https://github.test/pull/114", headRefName: "feature/14-x", headRefOid: $main, isDraft: false,
   mergeable: "CONFLICTING", reviewDecision: "",
   statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "FAILURE"},
                       {__typename: "StatusContext", state: "SUCCESS"}]},
  {number: 116, title: "PR 16", url: "https://github.test/pull/116", headRefName: "feature/16-y", headRefOid: $main, isDraft: false,
   mergeable: "MERGEABLE", reviewDecision: "",
   statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}
]' >"$tmp/gh/open.json"
jq -n '[{number: 115, url: "https://github.test/pull/115", headRefName: "feature/15-x"}]' >"$tmp/gh/merged.json"

out="$(status)"
for issue in 11 12 13 14 15 16; do
  grep -q "^#$issue  Title $issue\$" <<<"$out" || fail "feature $issue is not listed with its title: $out"
done

r="$(row "$out" 11)"
grep -Fq "phase: review round 2 of 5" <<<"$r" || fail "the running feature does not show its review round: $r"
grep -Fq "verification: passed, trusted (orchestrator)" <<<"$r" || fail "the trusted pass and its origin are not shown: $r"
grep -Fq "owner decision needed: none" <<<"$r" || fail "a running feature asks the owner for something: $r"

r="$(row "$out" 12)"
grep -Fq "phase: stopped (implementing), exit status 3" <<<"$r" || fail "the stopped feature does not show its phase and status: $r"
grep -Fq "verification: passed, not trusted (manual)" <<<"$r" || fail "an untrusted pass is not shown as such: $r"
grep -Fq "your decision: Should the import keep duplicate rows or drop them | merge them?" <<<"$r" || fail "the question of the handoff note is not named: $r"
grep -Fq "answer in .agents/handoffs/12.md, then run ./scripts/run-feature.sh 12" <<<"$r" || fail "the command that continues is not named: $r"
[[ "$(grep -c '^    - ' <<<"$r")" -eq 1 ]] || fail "the blocked record repeats the stopped run's question: $r"

r="$(row "$out" 13)"
grep -Fq "phase: published" <<<"$r" || fail "the published feature is not shown as published: $r"
grep -Fq "pull request: #113 (checks pass, mergeable) https://github.test/pull/113" <<<"$r" || fail "the pull request is not shown: $r"
grep -Fq "your approval: review and approve #113" <<<"$r" || fail "the approval is not asked for: $r"
if grep -Fq "merge #113" <<<"$r"; then fail "a pull request that needs approval is offered to merge plainly: $r"; fi

r="$(row "$out" 14)"
grep -Fq "#114 (checks fail (1 of 2), conflicting)" <<<"$r" || fail "the conflicting pull request is not shown: $r"
grep -Fq "conflicts with its base: run ./scripts/update-feature.sh 14" <<<"$r" || fail "the conflict is not a decision: $r"
grep -Fq "checks fail (1 of 2) on #114: https://github.test/pull/114" <<<"$r" || fail "the failing checks are not a decision: $r"

r="$(row "$out" 15)"
grep -Fq "phase: merged" <<<"$r" || fail "the merged feature is not shown as merged: $r"
grep -Fq 'record the post-merge evidence: ./scripts/record-post-merge.sh 15 "the site deploys" "<evidence>"' <<<"$r" ||
  fail "the pending post_merge criterion is not a decision: $r"

r="$(row "$out" 16)"
grep -Fq "merge #116: https://github.test/pull/116" <<<"$r" || fail "a pull request ready to merge is not offered: $r"
# GitHub requires an approving review and no approval request is at the
# head: no merge until that review exists.
open_pr 116 '.reviewDecision = "REVIEW_REQUIRED"'
r="$(row "$(status)" 16)"
if grep -Fq "merge #116" <<<"$r"; then fail "a pull request whose required review is missing is offered to merge: $r"; fi
grep -Fq "a required review is missing on #116" <<<"$r" || fail "the required review is not a decision: $r"
open_pr 116 '.reviewDecision = ""'

# Evidence that record-post-merge.sh recorded on the Issue settles the
# criterion: the merged feature no longer asks for it.
jq -n '[{body: "an unrelated comment\nCriterion: the site deploys"},
        {body: "<!-- post-merge-evidence -->\nPost-merge evidence (recorded by record-post-merge.sh)\n\nCriterion: the site deploys\n\nEvidence: the run on main"}]' \
  >"$tmp/gh/comments-15.json"
r="$(row "$(status)" 15)"
grep -Fq "phase: merged" <<<"$r" || fail "the merged feature is not shown as merged: $r"
grep -Fq "owner decision needed: none" <<<"$r" || fail "a criterion with recorded evidence is still a decision: $r"
# One criterion recorded of two: only the other one is asked for.
completion 15 awaiting_evidence '[{"criterion":"the site deploys","gate":"post_merge","status":"pending","evidence":"after the merge"},
  {"criterion":"the page is live","gate":"post_merge","status":"pending","evidence":"after the merge"}]'
r="$(row "$(status)" 15)"
if grep -Fq '"the site deploys"' <<<"$r"; then fail "the recorded criterion is asked for again: $r"; fi
grep -Fq 'record-post-merge.sh 15 "the page is live"' <<<"$r" || fail "the criterion without evidence is not asked for: $r"
completion 15 awaiting_evidence '[{"criterion":"the site deploys","gate":"post_merge","status":"pending","evidence":"after the merge"}]'

# Whether a merge is offered: only with checks that pass, no review that
# requests changes, and an approval request that is read at the pull
# request's own head.
open_pr 116 '.reviewDecision = "CHANGES_REQUESTED"'
r="$(row "$(status)" 16)"
grep -Fq "a review requests changes on #116" <<<"$r" || fail "requested changes are not a decision: $r"
if grep -Fq "merge #116" <<<"$r"; then fail "a pull request with requested changes is offered to merge: $r"; fi
open_pr 116 '.reviewDecision = "" | .statusCheckRollup = []'
r="$(row "$(status)" 16)"
grep -Fq "#116 (no checks, mergeable)" <<<"$r" || fail "absent checks are not shown: $r"
grep -Fq "no CI check has reported on #116" <<<"$r" || fail "absent checks are not a decision: $r"
if grep -Fq "merge #116" <<<"$r"; then fail "a pull request without checks is offered to merge: $r"; fi
open_pr 116 '.statusCheckRollup = [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]'
# A head that is neither here nor readable on GitHub: unknown, no merge,
# also when a stale branch here holds no approval request.
unknown_oid="1111111111111111111111111111111111111111"
open_pr 116 ".headRefOid = \"$unknown_oid\""
git -C "$repo" update-ref refs/remotes/origin/feature/16-y main
r="$(row "$(status)" 16)"
grep -Fq "whether #116 needs your approval is unknown: its head 111111111111" <<<"$r" || fail "an unreadable head is not unknown: $r"
if grep -Fq "merge #116" <<<"$r"; then fail "a stale branch is taken for a head without an approval request: $r"; fi
git -C "$repo" update-ref -d refs/remotes/origin/feature/16-y
r="$(row "$(status)" 16)"
grep -Fq "needs your approval is unknown" <<<"$r" || fail "a missing branch is taken for a head without an approval request: $r"
# GitHub answers for the head: with the request, the approval is asked for;
# without it (HTTP 404), the merge is offered.
touch "$tmp/gh/has-$unknown_oid"
r="$(row "$(status)" 16)"
grep -Fq "your approval: review and approve #116" <<<"$r" || fail "the approval request on GitHub's head is not read: $r"
rm -f "$tmp/gh/has-$unknown_oid"
touch "$tmp/gh/lacks-$unknown_oid"
r="$(row "$(status)" 16)"
grep -Fq "merge #116: https://github.test/pull/116" <<<"$r" || fail "a head without a request on GitHub is not offered to merge: $r"
rm -f "$tmp/gh/lacks-$unknown_oid"
open_pr 116 ".headRefOid = \"$main_oid\""

# More pull requests than one query returns: none is left out. 250 open
# pull requests of other branches come before the feature's, and 250 merged
# ones of feature 15's branch before its latest.
cp "$tmp/gh/open.json" "$tmp/gh/open.saved"
cp "$tmp/gh/merged.json" "$tmp/gh/merged.saved"
jq --arg main "$main_oid" '[range(1; 251) | {number: (1000 + .), title: "other", url: "https://github.test/pull/\(1000 + .)",
    headRefName: "deps/\(.)", headRefOid: $main, isDraft: false, mergeable: "MERGEABLE", reviewDecision: "", statusCheckRollup: []}] + .' \
  "$tmp/gh/open.saved" >"$tmp/gh/open.json"
jq '[range(1; 251) | {number: (. % 100), url: "https://github.test/pull/\(. % 100)", headRefName: "feature/15-x"}] + .' \
  "$tmp/gh/merged.saved" >"$tmp/gh/merged.json"
: >"$tmp/gh/log"
out="$(status)"
for issue in 13 14 16; do
  grep -q "^#$issue  Title $issue\$" <<<"$out" || fail "feature $issue beyond the first page is left out: $out"
done
grep -Fq "pull request: #115 (merged)" <<<"$(row "$out" 15)" || fail "the merged pull request beyond the first page is left out: $(row "$out" 15)"
grep -Eq -- "--state open --limit 1000" "$tmp/gh/log" || fail "the open pull requests are not asked for again: $(cat "$tmp/gh/log")"
grep -Eq -- "--state merged --head feature/15-x --limit 1000" "$tmp/gh/log" || fail "the merged pull requests are not asked for again: $(cat "$tmp/gh/log")"
mv "$tmp/gh/open.saved" "$tmp/gh/open.json"
mv "$tmp/gh/merged.saved" "$tmp/gh/merged.json"

# A blocked record that no stopped run names: the question of its note too.
completion 11 blocked '[{"criterion":"c","status":"not_met","evidence":"waiting"}]'
printf '## Open questions\n\nWhich port does the server use?\n' >"$tmp/wt-11/.agents/handoffs/11.md"
r="$(row "$(status)" 11)"
grep -Fq "the implementer is blocked on a question: Which port does the server use?; answer it in .agents/handoffs/11.md" <<<"$r" ||
  fail "the question of a blocked record is not named: $r"
# Without a question in the note, the decision still points to the note.
printf '## Open questions\n\nNone.\n' >"$tmp/wt-11/.agents/handoffs/11.md"
r="$(row "$(status)" 11)"
grep -Fq "the implementer is blocked on a question: answer it in .agents/handoffs/11.md" <<<"$r" ||
  fail "a note without a question is not handled: $r"
rm -f "$tmp/wt-11/.agents/completion/11.json" "$tmp/wt-11/.agents/handoffs/11.md"

# A run that stopped with status 78 (Issue 407): the machine lacks a
# prerequisite. The decision is to install it, not a defect of the feature.
run_start 11 20261101T120000Z-999999999-78 2000
event 11 20261101T120000Z-999999999-78 2010 run-end '{"status":78,"step":"implementation","reason":"a prerequisite of this machine is missing, which says nothing about this feature: GNU sed for the workflow self-tests — brew install gnu-sed."}'
r="$(row "$(status)" 11)"
grep -Fq "exit status 78" <<<"$r" || fail "the environment stop does not show its status: $r"
grep -Fq "install what this machine lacks: a prerequisite of this machine is missing, which says nothing about this feature: GNU sed" <<<"$r" ||
  fail "the environment stop is not the decision to install the prerequisite: $r"
grep -Fq "./scripts/doctor.sh lists every prerequisite; then run ./scripts/run-feature.sh 11" <<<"$r" ||
  fail "the environment stop does not name doctor.sh and the command that continues: $r"
if grep -Fq "see .agents/run/11-log" <<<"$r"; then fail "the environment stop is reported as a failed run: $r"; fi
rm -f "$records/20261101T120000Z-999999999-78.jsonl"

# Without a worktree, the approval request is read from the head commit of
# the pull request, which a fetch brought here.
git -C "$repo" branch -q approval-16 main
git -C "$repo" worktree add -q "$tmp/wt-a" approval-16
mkdir -p "$tmp/wt-a/.agents/approval-requests" && echo '{}' >"$tmp/wt-a/.agents/approval-requests/16.json"
git -C "$tmp/wt-a" add -f .agents/approval-requests/16.json
git -C "$tmp/wt-a" -c user.name=t -c user.email=t@example.com commit -q -m request
git -C "$repo" update-ref refs/remotes/origin/feature/16-y approval-16
git -C "$repo" worktree remove --force "$tmp/wt-a"
open_pr 116 ".headRefOid = \"$(git -C "$repo" rev-parse approval-16)\""
r="$(row "$(status)" 16)"
grep -Fq "your approval: review and approve #116" <<<"$r" || fail "the approval request of a fetched branch is not read: $r"
git -C "$repo" update-ref -d refs/remotes/origin/feature/16-y
open_pr 116 ".headRefOid = \"$main_oid\""

# A feature with nothing to decide has an empty column in the table.
md="$(status --markdown)"
[[ "$(sed -n 1p <<<"$md")" == "| Issue | Title | Phase | Exit | Verification | Pull request | Owner decision needed |" ]] ||
  fail "the Markdown table has no header: $md"
[[ "$(sed -n 2p <<<"$md")" == "|---|---|---|---|---|---|---|" ]] || fail "the Markdown table has no separator: $md"
grep -Fxq "| #11 | Title 11 | review round 2 of 5 |  | passed, trusted (orchestrator) |  |  |" <<<"$md" ||
  fail "the row of the running feature is wrong, or its decision column is not empty: $md"
grep -Fq "| #13 | Title 13 | published |  |  | [#113](https://github.test/pull/113) (checks pass, mergeable) | your approval" <<<"$md" ||
  fail "the pull request is not a link: $md"
# Every row has the seven cells of the header, also with a '|' in a text.
while IFS= read -r line; do
  cells="$(sed 's/\\|//g' <<<"$line" | tr -cd '|' | wc -c)"
  [[ "$cells" -eq 8 ]] || fail "a Markdown row does not have seven cells: $line"
done < <(sed -n '3,$p' <<<"$md")

# A run killed without its end is interrupted, and needs the owner.
kill "$sleeper" 2>/dev/null || true
wait "$sleeper" 2>/dev/null || true
sleeper=""
r="$(row "$(status)" 11)"
grep -Fq "phase: interrupted (review round 2 of 5)" <<<"$r" || fail "a run whose process is gone is not interrupted: $r"
sleep 300 &
sleeper=$!
sed -i.bak "s/-[0-9]*-1\"/-$sleeper-1\"/g" "$records"/*-1.jsonl
rm -f "$records"/*.bak
mv "$records"/*-1.jsonl "$records/20261101T100000Z-$sleeper-1.jsonl"
r="$(row "$(status)" 11)"
grep -Fq "phase: review round 2 of 5" <<<"$r" || fail "the running feature is no longer running: $r"

# --changes: the first time every row is a change; then nothing; then only
# the changed row and the new decision.
[[ -n "$(status --changes)" ]] || fail "the first --changes reports nothing"
[[ -f "$repo/.agents/status/overview.json" ]] || fail "the overview is not kept"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "the kept overview is not ignored by Git: $(git -C "$repo" status --porcelain)"
[[ -z "$(status --changes)" ]] || fail "--changes reports something although nothing changed"
jq '(.[] | select(.number == 114) | .mergeable) = "MERGEABLE"' "$tmp/gh/open.json" >"$tmp/gh/open.tmp" && mv "$tmp/gh/open.tmp" "$tmp/gh/open.json"
completion 13 complete '[{"criterion":"c","status":"met","evidence":"e"}]'
event 16 20261101T100000Z-999999999-6 1000 run-start '{"kind":"feature","subject":"16","command":"run-feature.sh","seq":1}'
event 16 20261101T100000Z-999999999-6 1010 run-end '{"status":1,"step":"pull request","reason":"5 review rounds are used and round 5 still has findings"}'
changed="$(status --changes)"
grep -q '^#14  Title 14$' <<<"$changed" || fail "the changed row is not reported: $changed"
grep -q '^#16  Title 16$' <<<"$changed" || fail "the stopped feature is not reported: $changed"
for issue in 11 12 13 15; do
  if grep -q "^#$issue " <<<"$changed"; then fail "the unchanged row $issue is reported: $changed"; fi
done
grep -Fq "New owner decisions:" <<<"$changed" || fail "the new decisions are not listed: $changed"
grep -Fq -- "- #16: the review rounds are used" <<<"$changed" || fail "the rounds used are not a new decision: $changed"
grep -Fq -- "--rounds <m>" <<<"$changed" || fail "the command that raises the limit is not named: $changed"
if grep -Fq -- "- #14:" <<<"$changed"; then fail "a decision that is gone is listed as new: $changed"; fi
# A feature whose worktree and pull request are gone is reported once.
git -C "$repo" worktree remove --force "$tmp/wt-11"
changed="$(status --changes)"
[[ "$changed" == "#11: no longer listed (no worktree and no open pull request)" ]] || fail "a feature that is gone is not reported alone: $changed"
[[ -z "$(status --changes)" ]] || fail "a feature that is gone is reported twice"

# The hook gets exactly the output of --changes.
printf '# The notification hook.\ncommand: cat >"%s/notified"\n' "$tmp" >"$repo/.agents/notify.conf"
jq '(.[] | select(.number == 116) | .isDraft) = true' "$tmp/gh/open.json" >"$tmp/gh/open.tmp" && mv "$tmp/gh/open.tmp" "$tmp/gh/open.json"
changed="$(status --changes)"
[[ -n "$changed" ]] || fail "the draft pull request is not a change"
[[ "$(cat "$tmp/notified")" == "$changed" ]] || fail "the hook did not get exactly the changes: $(cat "$tmp/notified")"
rm -f "$tmp/notified"
[[ -z "$(status --changes)" ]] || fail "nothing changed, but --changes reports something"
[[ ! -e "$tmp/notified" ]] || fail "the hook was called without a change"

# A failing hook is reported, and the change is not lost: the next --changes
# reports it again and delivers it.
printf 'command: cat >"%s/failed"; exit 7\n' "$tmp" >"$repo/.agents/notify.conf"
jq '(.[] | select(.number == 116) | .isDraft) = false' "$tmp/gh/open.json" >"$tmp/gh/open.tmp" && mv "$tmp/gh/open.tmp" "$tmp/gh/open.json"
code=0
err="$(status --changes 2>&1 >"$tmp/first")" || code=$?
[[ "$code" -ne 0 ]] || fail "a failing hook does not fail --changes"
grep -Fq "the notification hook of .agents/notify.conf failed (status 7)" <<<"$err" || fail "the failing hook is not reported: $err"
grep -q '^#16 ' "$tmp/first" || fail "the change is not printed when the hook fails"
printf 'command: cat >"%s/notified"\n' "$tmp" >"$repo/.agents/notify.conf"
[[ "$(status --changes)" == "$(cat "$tmp/first")" ]] || fail "the change that the hook did not deliver is lost"
[[ "$(cat "$tmp/notified")" == "$(cat "$tmp/first")" ]] || fail "the change was not delivered the second time"

# Two --changes at the same time notify a change once: the lock holds the
# second until the first has kept its overview.
printf 'command: echo call >>"%s/calls"; cat >/dev/null; sleep 2\n' "$tmp" >"$repo/.agents/notify.conf"
open_pr 116 '.isDraft = true'
status --changes >"$tmp/a.out" 2>&1 &
first=$!
status --changes >"$tmp/b.out" 2>&1 &
second=$!
code=0
wait "$first" || code=$?
wait "$second" || code=$?
[[ "$code" -eq 0 ]] || fail "concurrent --changes failed: $(cat "$tmp/a.out" "$tmp/b.out")"
[[ "$(wc -l <"$tmp/calls")" -eq 1 ]] || fail "concurrent --changes notified $(wc -l <"$tmp/calls") times"
[[ ! -e "$repo/.agents/status/lock" ]] || fail "--changes leaves its lock behind"
# A lock whose process is gone is stale and taken over; a held lock makes
# --changes fail after its wait, and keeps the previous overview.
open_pr 116 '.isDraft = false'
mkdir "$repo/.agents/status/lock"
printf 'pid=999999999\nstarted=never\n' >"$repo/.agents/status/lock/owner"
grep -q '^#16 ' <<<"$(status --changes)" || fail "a stale lock is not taken over"
[[ "$(wc -l <"$tmp/calls")" -eq 2 ]] || fail "the change after a stale lock is not notified"
open_pr 116 '.isDraft = true'
mkdir "$repo/.agents/status/lock"
printf 'pid=%s\nstarted=%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p "$$" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" >"$repo/.agents/status/lock/owner"
code=0
err="$(STATUS_LOCK_WAIT=1 status --changes 2>&1)" || code=$?
[[ "$code" -ne 0 ]] || fail "--changes does not wait for a held lock"
grep -Fq "another --changes holds" <<<"$err" || fail "a held lock is not reported: $err"
[[ -d "$repo/.agents/status/lock" ]] || fail "a held lock is removed"
rm -rf "$repo/.agents/status/lock"
grep -q '^#16 ' <<<"$(status --changes)" || fail "the change is lost while the lock was held"
# A lock without an owner (a run killed between mkdir and writing it) is
# taken over once it is older than the grace period; a young one is held.
open_pr 116 '.isDraft = false'
mkdir "$repo/.agents/status/lock"
code=0
err="$(STATUS_LOCK_WAIT=1 status --changes 2>&1)" || code=$?
[[ "$code" -ne 0 && -d "$repo/.agents/status/lock" ]] || fail "a lock that is being taken right now is removed: $err"
touch -t 202001010000 "$repo/.agents/status/lock"
grep -q '^#16 ' <<<"$(STATUS_LOCK_WAIT=1 status --changes 2>&1)" || fail "an old lock without an owner is not taken over"
[[ ! -e "$repo/.agents/status/lock" ]] || fail "--changes leaves its lock behind"
# So is a recovery lock of a run killed while it removed a stale lock.
open_pr 116 '.isDraft = true'
mkdir "$repo/.agents/status/lock" "$repo/.agents/status/lock.recover"
touch -t 202001010000 "$repo/.agents/status/lock" "$repo/.agents/status/lock.recover"
grep -q '^#16 ' <<<"$(STATUS_LOCK_WAIT=1 status --changes 2>&1)" || fail "an old recovery lock blocks --changes for good"
[[ ! -e "$repo/.agents/status/lock.recover" ]] || fail "an old recovery lock is left behind"
# #487: the mkdir of uutils coreutils (Ubuntu 25.10 and newer) succeeds for
# both of two runs that create the lock at the same time. The fake mkdir is
# that second run: it succeeds for the lock directory that is already there.
# The lock is still held: only the run that creates its owner holds it.
real_mkdir="$(command -v mkdir)"
cat >"$tmp/bin/mkdir" <<MKDIR
#!/usr/bin/env bash
if [[ -n "\${FAKE_MKDIR_RACE:-}" && \$# -eq 1 && "\$1" == */.agents/status/lock && -d "\$1" ]]; then
  exit 0
fi
exec "$real_mkdir" "\$@"
MKDIR
chmod +x "$tmp/bin/mkdir"
open_pr 116 '.isDraft = false'
mkdir "$repo/.agents/status/lock"
held="$(printf 'pid=%s\nstarted=%s' "$$" "$(LC_ALL=C ps -o lstart= -p "$$" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')")"
printf '%s\n' "$held" >"$repo/.agents/status/lock/owner"
code=0
err="$(FAKE_MKDIR_RACE=1 STATUS_LOCK_WAIT=1 status --changes 2>&1)" || code=$?
[[ "$code" -ne 0 ]] || fail "a run whose mkdir of the held lock succeeds takes the lock: $err"
grep -Fq "another --changes holds" <<<"$err" || fail "a held lock is not reported when mkdir succeeds for it: $err"
[[ "$(cat "$repo/.agents/status/lock/owner" 2>/dev/null)" == "$held" ]] ||
  fail "a run whose mkdir of the held lock succeeds replaces or removes the lock"
rm -rf "$repo/.agents/status/lock"
grep -q '^#16 ' <<<"$(FAKE_MKDIR_RACE=1 status --changes)" || fail "the change is lost while the lock was held"
[[ ! -e "$repo/.agents/status/lock" ]] || fail "--changes leaves its lock behind"
rm -f "$tmp/bin/mkdir"
# A run releases only its own lock: when another run holds the lock at the
# end (it removed this run's lock and took it), that lock stays.
printf 'command: cat >/dev/null; rm -rf .agents/status/lock; mkdir .agents/status/lock; printf "pid=1\\nstarted=other\\n" >.agents/status/lock/owner\n' \
  >"$repo/.agents/notify.conf"
open_pr 116 '.isDraft = true'
grep -q '^#16 ' <<<"$(status --changes)" || fail "the change is not reported when another run takes the lock"
[[ "$(cat "$repo/.agents/status/lock/owner" 2>/dev/null)" == "$(printf 'pid=1\nstarted=other')" ]] ||
  fail "a run removes the lock that another run holds at its end"
rm -rf "$repo/.agents/status/lock"
printf 'command: cat >"%s/notified"\n' "$tmp" >"$repo/.agents/notify.conf"

# GitHub that cannot be read: the overview says so, --changes keeps the
# previous overview.
out="$(FAKE_GH_FAIL=1 status 2>&1)"
grep -Fq "GitHub could not be read" <<<"$out" || fail "an unreadable GitHub is not reported: $out"
code=0
FAKE_GH_FAIL=1 status --changes >/dev/null 2>&1 || code=$?
[[ "$code" -ne 0 ]] || fail "--changes without GitHub does not fail"
[[ -z "$(status --changes)" ]] || fail "--changes without GitHub changed the kept overview"

echo "status tests passed"
