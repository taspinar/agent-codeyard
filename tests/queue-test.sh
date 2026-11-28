#!/usr/bin/env bash

set -euo pipefail

# scripts/queue.sh with a fake run-feature.sh, a fake update-feature.sh, a
# fake 'gh' that answers from files, and a fake 'df': the start up to
# --max-parallel, the after-merge dependency, a second run that starts nothing
# twice, the update of the primary checkout and the removal of the merged
# worktree (the real cleanup-worktree.sh), the worktree lock of
# lib/records.sh, the disk limit and its reason in status.sh, the update of
# a conflicting pull request and the owner decision when it stops, and stop;
# also a running step of an Issue removed from the queue file, the free
# space read before every start, and the stale-lock recovery race.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/queue-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
fake="$tmp/fake"
mkdir -p "$fake" "$tmp/bin" "$tmp/gh"

cleanup() {
  local file

  # Every fake step that still waits ends now.
  for file in 1 2 3 4 5 6 7 8 9 10 11; do
    [[ -e "$fake/release-$file" ]] || echo 0 >"$fake/release-$file"
  done
  echo 0 >"$fake/release-hold" 2>/dev/null || true
  sleep 1
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "queue test failed: $*" >&2
  exit 1
}

# wait_for <file>: waits up to 30 seconds for the file to exist.
wait_for() {
  local i

  for ((i = 0; i < 300; i++)); do
    [[ ! -e "$1" ]] || return 0
    sleep 0.1
  done
  fail "$1 did not appear"
}

# The fake GitHub CLI: 'pr list --state open|merged [--head <branch>] [--jq
# <filter>]' from open.json or merged.json, 'repo view' (main), 'issue view'
# ("Title <n>"). Every other call fails.
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
dir="$FAKE_GH_DIR"
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
      '[.[] | select($head == "" or .headRefName == $head)] | .[:$limit]' "$dir/$state.json" | jq -r "$filter"
    ;;
  "repo view") echo main ;;
  "issue view") echo "Title $3" ;;
  *) exit 1 ;;
esac
GH
# The fake df: FAKE_DF_KB kilobytes available.
cat >"$tmp/bin/df" <<'DF'
#!/usr/bin/env bash
# FAKE_DF_HOLD: a pass of the queue waits here, after it read the stop
# marker, until the file exists.
if [[ -n "${FAKE_DF_HOLD:-}" ]]; then
  touch "$FAKE_DF_HOLD.waiting"
  until [[ -e "$FAKE_DF_HOLD" ]]; do sleep 0.1; done
fi
# FAKE_DF_SEQ: a file of values, one per call; the last one stays.
kb="${FAKE_DF_KB:-99999999999}"
if [[ -n "${FAKE_DF_SEQ:-}" && -s "$FAKE_DF_SEQ" ]]; then
  kb="$(sed -n 1p "$FAKE_DF_SEQ")"
  [[ "$(wc -l <"$FAKE_DF_SEQ")" -le 1 ]] || sed -i 1d "$FAKE_DF_SEQ"
fi
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 $kb 1% /"
DF
chmod +x "$tmp/bin/gh" "$tmp/bin/df"
echo '[]' >"$tmp/gh/open.json"
echo '[]' >"$tmp/gh/merged.json"
export FAKE_GH_DIR="$tmp/gh" FAKE_DIR="$fake"
export FAKE_DF_KB=$((100 * 1024 * 1024))

# The repository: an origin and its primary checkout, with the scripts of the
# queue and fakes of run-feature.sh and update-feature.sh.
git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
repo="$tmp/repo"
mkdir -p "$repo/scripts/lib" "$repo/.agents"
cp "$source_root/scripts/queue.sh" "$source_root/scripts/status.sh" "$source_root/scripts/cleanup-worktree.sh" "$repo/scripts/"
cp "$source_root/scripts/lib/records.sh" "$source_root/scripts/lib/experience.sh" "$source_root/scripts/lib/completion.sh" \
  "$source_root/scripts/lib/github.sh" "$source_root/scripts/lib/base.sh" "$repo/scripts/lib/"
workflow_gitignore "$repo/.gitignore"
# The fake run-feature.sh holds the worktree lock as a run of the feature
# does (records_wrap), makes the worktree, and waits for release-<issue>,
# whose content is its exit status.
cat >"$repo/scripts/run-feature.sh" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail
issue="$1"
source "$(cd "$(dirname "$0")" && pwd -P)/lib/records.sh"
records_wrap feature "$issue" "$0" "$@"
printf '%s %s\n' "$issue" "${AGENT_CONFIG_FILE:-}" >>"$FAKE_DIR/started"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
worktree="$(dirname "$root")/wt-$issue"
[[ -d "$worktree" ]] || git -C "$root" worktree add -q -b "feature/$issue-x" "$worktree" origin/main
until [[ -e "$FAKE_DIR/release-$issue" ]]; do sleep 0.1; done
status="$(cat "$FAKE_DIR/release-$issue")"
exit "${status:-0}"
RUN
cat >"$repo/scripts/update-feature.sh" <<'UPDATE'
#!/usr/bin/env bash
issue="$1"
printf '%s %s\n' "$issue" "$(pwd -P)" >>"$FAKE_DIR/updated"
status="$(cat "$FAKE_DIR/update-exit-$issue" 2>/dev/null || echo 0)"
[[ "$status" == 0 ]] || echo "Error: merging origin/main conflicts with the feature in: list.txt"
exit "$status"
UPDATE
chmod +x "$repo/scripts/"*.sh
echo "agent configuration" >"$repo/.agents/agents-fast.conf"
git -C "$repo" -c user.name=t -c user.email=t@example.com add -A
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -q -m init
git -C "$repo" push -q origin main 2>/dev/null

queue() {
  (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/queue.sh "$@")
}
status() {
  (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/status.sh "$@")
}
started() {
  [[ -f "$fake/started" ]] || return 0
  cut -d ' ' -f 1 "$fake/started" | sort -n | tr '\n' ' '
}
overview() {
  jq -r --argjson issue "$1" '.[] | select(.issue == $issue) | "\(.phase): \(.reason) | \(.decision)"' "$repo/.agents/queue/overview.json"
}
# wait_started <count>: waits until that many fake runs have started.
wait_started() {
  local i

  for ((i = 0; i < 300; i++)); do
    [[ ! -f "$fake/started" || "$(wc -l <"$fake/started")" -lt "$1" ]] || return 0
    sleep 0.1
  done
  fail "$1 runs did not start: $(started)"
}

# ------------------------------------------------------------ the queue file

echo "1 after-merge" >"$repo/.agents/queue.conf"
out="$(queue run 2>&1)" && fail "a dependency without an Issue was accepted"
grep -q "after-merge' takes an Issue number" <<<"$out" || fail "the error does not name the word: $out"
echo "1 frobnicate" >"$repo/.agents/queue.conf"
out="$(queue run 2>&1)" && fail "an unknown word was accepted"
grep -q "unknown word 'frobnicate'" <<<"$out" || fail "the error does not name the unknown word: $out"
[[ ! -e "$fake/started" ]] || fail "a queue file with an error started a run"

# ------------------------------------------------------------ start up to --max-parallel

cat >"$repo/.agents/queue.conf" <<'CONF'
# The queue of the test.
1
2
3 after-merge 1 agents=.agents/agents-fast.conf
CONF
out="$(queue run --max-parallel 1)"
wait_started 1
[[ "$(started)" == "1 " ]] || fail "--max-parallel 1 did not start exactly #1: $(started) / $out"
grep -q "ready; 1 of 1 steps are running" <<<"$(overview 2)" || fail "#2 does not say why it waits: $(overview 2)"
queue run --max-parallel 2 >/dev/null
wait_started 2
[[ "$(started)" == "1 2 " ]] || fail "the second slot did not start #2: $(started)"
grep -q "waits for the merge of #1" <<<"$(overview 3)" || fail "#3 does not wait for #1: $(overview 3)"
# Idempotent: another run starts nothing twice, also with more slots.
queue run --max-parallel 5 >/dev/null
sleep 1
[[ "$(wc -l <"$fake/started")" -eq 2 ]] || fail "a second queue.sh run started a run twice: $(cat "$fake/started")"
[[ -f "$repo/.agents/queue/1/run.process" && -f "$repo/.agents/queue/1/run.log" ]] ||
  fail "the process and the log of the run are not recorded"
# A running step counts toward --max-parallel also when its Issue was
# removed from the queue file: #2 runs, is no longer listed, and #9 waits.
cp "$repo/.agents/queue.conf" "$tmp/queue.conf.saved"
printf '1\n9\n' >"$repo/.agents/queue.conf"
queue run --max-parallel 2 >/dev/null
sleep 1
! grep -q '^9 ' "$fake/started" || fail "#9 started beyond --max-parallel while the removed #2 still runs"
grep -q "ready; 2 of 2 steps are running" <<<"$(overview 9)" || fail "#9 does not count the running step of the removed #2: $(overview 9)"
cp "$tmp/queue.conf.saved" "$repo/.agents/queue.conf"

# ------------------------------------------------------------ the worktree lock

out="$(cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" timeout 20 ./scripts/run-feature.sh 1 2>&1)" && fail "a second session of #1 was not refused"
status=0
(cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" timeout 20 ./scripts/run-feature.sh 1 >/dev/null 2>&1) || status=$?
[[ "$status" -eq 75 ]] || fail "a refused second session exits with $status instead of 75"
holder="$(sed -n 's/^pid=//p' "$repo/.git/workflow-locks/feature-1/owner")"
grep -q "has a session or a verification running already: run-feature.sh (PID $holder" <<<"$out" ||
  fail "the refusal does not name the holder (PID $holder): $out"
[[ "$(wc -l <"$fake/started")" -eq 2 ]] || fail "the refused session ran"

# A stale lock is removed only when it is still stale under the recovery
# lock: another run may install a live lock between the first check and the
# recovery lock. The first check is made to see the lock as stale; the live
# holder must keep it.
sleep 60 &
live=$!
race="$tmp/race-lock"
mkdir "$race"
printf 'pid=%s\nstarted=%s\nid=live\ncommand=a live run\n' "$live" \
  "$(LC_ALL=C ps -o lstart= -p "$live" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" >"$race/owner"
race_status=0
(
  cd "$repo"
  source ./scripts/lib/records.sh
  eval "real_$(declare -f records_lock_holder)"
  # A file, since records_lock_take calls it in a command substitution.
  records_lock_holder() {
    if [[ ! -e "$race.seen" ]]; then
      touch "$race.seen"
      return 1
    fi
    real_records_lock_holder "$@"
  }
  records_lock_take "$race" "a second run"
) >/dev/null 2>&1 || race_status=$?
grep -q '^id=live$' "$race/owner" 2>/dev/null || fail "the recovery of a stale lock removed a live lock (status $race_status)"
[[ "$race_status" -eq 1 ]] || fail "records_lock_take did not report the live holder: status $race_status"
kill "$live" 2>/dev/null || true
wait "$live" 2>/dev/null || true
# Once its holder is gone, the lock is taken over.
race_status=0
(cd "$repo" && source ./scripts/lib/records.sh && records_lock_take "$race" "a second run") >/dev/null 2>&1 || race_status=$?
[[ "$race_status" -eq 0 ]] || fail "a stale lock was not taken over: status $race_status"
rm -rf "$race" "$race.seen"

# ------------------------------------------------------------ after a merge

echo 0 >"$fake/release-1"
wait_for "$repo/.agents/queue/1/run.exit"
[[ ! -e "$repo/.git/workflow-locks/feature-1" ]] || fail "the lock of #1 is kept after its run ended"
# The feature is published and merged: its commit is on main of the origin.
echo one >"$tmp/wt-1/one.txt"
git -C "$tmp/wt-1" -c user.name=t -c user.email=t@example.com add one.txt
git -C "$tmp/wt-1" -c user.name=t -c user.email=t@example.com commit -q -m "feature 1"
git -C "$tmp/wt-1" push -q origin HEAD:refs/heads/feature/1-x HEAD:main 2>/dev/null
tip="$(git -C "$tmp/wt-1" rev-parse HEAD)"
jq -n --arg tip "$tip" '[{number: 11, headRefName: "feature/1-x", headRefOid: $tip, baseRefName: "main",
  mergeCommit: {oid: $tip}, body: "Closes #1"}]' >"$tmp/gh/merged.json"
out="$(queue run --max-parallel 2)"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$tip" ]] || fail "the primary checkout was not updated after the merge: $out"
[[ ! -d "$tmp/wt-1" ]] || fail "the merged worktree was not removed: $out"
! git -C "$repo" rev-parse -q --verify refs/heads/feature/1-x >/dev/null || fail "the merged branch was kept"
wait_started 3
grep -q "^3 $repo/.agents/agents-fast.conf$" "$fake/started" || fail "#3 did not start after the merge of #1, with its agents=: $(cat "$fake/started")"
grep -q "^merged" <<<"$(overview 1)" || fail "#1 is not merged in the overview: $(overview 1)"

# ------------------------------------------------------------ a run that stops

echo 1 >"$fake/release-2"
wait_for "$repo/.agents/queue/2/run.exit"
queue run >/dev/null
grep -q "^stopped: run-feature.sh ended with status 1" <<<"$(overview 2)" || fail "#2 does not say that its run stopped: $(overview 2)"
[[ "$(grep -c '^2 ' "$fake/started")" -eq 1 ]] || fail "a run that stopped was started again"
queue reset 2 >/dev/null
queue run >/dev/null
wait_started 4
[[ "$(grep -c '^2 ' "$fake/started")" -eq 2 ]] || fail "queue.sh reset did not let the queue start #2 again"
echo 0 >"$fake/release-2"
wait_for "$repo/.agents/queue/2/run.exit"

# ------------------------------------------------------------ the disk limit

echo 0 >"$fake/release-3"
wait_for "$repo/.agents/queue/3/run.exit"
echo "4" >>"$repo/.agents/queue.conf"
FAKE_DF_KB=$((3 * 1024 * 1024)) queue run >/dev/null
sleep 1
! grep -q '^4 ' "$fake/started" || fail "#4 started below the disk limit"
grep -q "ready; 3 GB free in $tmp, below the limit of 15 GB" <<<"$(overview 4)" || fail "#4 does not name the disk limit: $(overview 4)"
out="$(status)"
grep -q "#4  Title 4" <<<"$out" || fail "status.sh does not list the queued #4: $out"
grep -q "phase: queued: ready; 3 GB free" <<<"$out" || fail "status.sh does not say why #4 waits: $out"
grep -q "free disk space: 3 GB free" <<<"$out" || fail "status.sh does not name the owner decision of the disk: $out"
FAKE_DF_KB=$((3 * 1024 * 1024)) queue run --min-free-gb 2 >/dev/null
wait_started 5
grep -q '^4 ' "$fake/started" || fail "#4 did not start above a lower --min-free-gb"
echo 0 >"$fake/release-4"
wait_for "$repo/.agents/queue/4/run.exit"

# ------------------------------------------------------------ a conflicting pull request

jq -n '[{number: 33, headRefName: "feature/3-x", headRefOid: "aaaa", mergeable: "CONFLICTING"}]' >"$tmp/gh/open.json"
echo 1 >"$fake/update-exit-3"
queue run >/dev/null
wait_for "$repo/.agents/queue/3/update.exit"
grep -q "^3 $tmp/wt-3$" "$fake/updated" || fail "update-feature.sh did not run in the worktree of #3: $(cat "$fake/updated" 2>/dev/null)"
out="$(queue run)"
[[ "$(wc -l <"$fake/updated")" -eq 1 ]] || fail "an update that stopped was tried again without a change"
grep -q "update-feature.sh could not bring #33 up to date (1): merging origin/main conflicts with the feature in: list.txt" <<<"$(overview 3)" ||
  fail "the stopped update is no owner decision: $(overview 3)"
out="$(status)"
grep -q "update-feature.sh could not bring #33 up to date" <<<"$out" || fail "status.sh does not show the stopped update: $out"
# The pull request changed: the queue tries again.
echo 0 >"$fake/update-exit-3"
jq -n '[{number: 33, headRefName: "feature/3-x", headRefOid: "bbbb", mergeable: "CONFLICTING"}]' >"$tmp/gh/open.json"
rm -f "$repo/.agents/queue/3/update.exit"
queue run >/dev/null
wait_for "$repo/.agents/queue/3/update.exit"
[[ "$(wc -l <"$fake/updated")" -eq 2 ]] || fail "a changed pull request was not updated again"
[[ "$(cat "$repo/.agents/queue/3/update.exit")" == 0 ]] || fail "the second update did not succeed"

# ------------------------------------------------------------ a busy worktree

hold_out="$tmp/hold.out"
mkdir -p "$fake/hold"
(cd "$repo" && FAKE_DIR="$fake/hold" PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/run-feature.sh 5 >"$hold_out" 2>&1 &)
wait_for "$fake/hold/started"
echo "5" >>"$repo/.agents/queue.conf"
queue run >/dev/null
sleep 1
! grep -q '^5 ' "$fake/started" || fail "the queue started a run in a worktree that has a session"
grep -q "ready; its worktree is busy: run-feature.sh (PID [0-9]*" <<<"$(overview 5)" || fail "#5 does not name the holder: $(overview 5)"
echo 0 >"$fake/hold/release-5"

# ------------------------------------------------------------ stop

printf '6\n7 after-merge 6\n' >>"$repo/.agents/queue.conf"
sed -i '/^5$/d' "$repo/.agents/queue.conf"
queue run >/dev/null
wait_started 6
grep -q '^6 ' "$fake/started" || fail "#6 did not start"
# A stop while a pass is going on: the pass starts nothing after it, and
# stop returns only when the pass has ended.
echo "8" >>"$repo/.agents/queue.conf"
(cd "$repo" && FAKE_DF_HOLD="$fake/df-release" PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/queue.sh run --max-parallel 3) >"$fake/pass.out" 2>&1 &
pass=$!
wait_for "$fake/df-release.waiting"
# reset waits for no pass: it would remove the records of a step that the
# pass may start.
out="$(queue reset 2 2>&1)" && fail "queue.sh reset ran while a pass was going on: $out"
grep -q "a queue.sh run is going on" <<<"$out" || fail "reset does not name the pass: $out"
queue stop >"$fake/stop.out" 2>&1 &
stop=$!
sleep 1
kill -0 "$stop" 2>/dev/null || fail "queue.sh stop returned while a pass was going on: $(cat "$fake/stop.out")"
touch "$fake/df-release"
wait "$pass" || fail "the pass during the stop failed: $(cat "$fake/pass.out")"
wait "$stop" || fail "queue.sh stop failed: $(cat "$fake/stop.out")"
sleep 1
! grep -q '^8 ' "$fake/started" || fail "a pass started a run after queue.sh stop: $(cat "$fake/pass.out")"
grep -q "ready; the queue is stopped" <<<"$(overview 8)" || fail "#8 does not say that the queue is stopped after a stop during the pass: $(overview 8)"
jq -n --arg tip "$tip" '[{number: 11, headRefName: "feature/1-x", headRefOid: $tip, baseRefName: "main", mergeCommit: {oid: $tip}, body: "Closes #1"},
  {number: 66, headRefName: "feature/6-x", headRefOid: "cccc", baseRefName: "main", mergeCommit: {oid: "cccc"}, body: "Closes #6"}]' >"$tmp/gh/merged.json"
out="$(queue run)"
grep -q "The queue is stopped" <<<"$out" || fail "a stopped queue does not say so: $out"
[[ "$(wc -l <"$fake/started")" -eq 6 ]] || fail "a stopped queue started a run: $(cat "$fake/started")"
grep -q "ready; the queue is stopped" <<<"$(overview 8)" || fail "#8 does not say that the queue is stopped: $(overview 8)"
# The running step finishes.
echo 0 >"$fake/release-6"
wait_for "$repo/.agents/queue/6/run.exit"
[[ "$(cat "$repo/.agents/queue/6/run.exit")" == 0 ]] || fail "the running step did not finish after the stop"
queue run >/dev/null
sleep 1
[[ "$(wc -l <"$fake/started")" -eq 6 ]] || fail "a stopped queue started a run after its running step ended"
[[ -d "$tmp/wt-6" ]] || fail "a stopped queue removed a worktree"
queue resume >/dev/null
queue run --max-parallel 3 >/dev/null
wait_started 8
grep -q '^7 ' "$fake/started" && grep -q '^8 ' "$fake/started" || fail "resume did not start the ready Issues: $(cat "$fake/started")"

# ------------------------------------------------------------ free space before every start

# The free space is read again before every start: the first start of a
# pass takes space, and the second Issue sees the lower value.
echo 0 >"$fake/release-7"
echo 0 >"$fake/release-8"
wait_for "$repo/.agents/queue/7/run.exit"
wait_for "$repo/.agents/queue/8/run.exit"
printf '10\n11\n' >>"$repo/.agents/queue.conf"
printf '%s\n%s\n' $((16 * 1024 * 1024)) $((10 * 1024 * 1024)) >"$fake/df-seq"
FAKE_DF_SEQ="$fake/df-seq" queue run --max-parallel 5 >/dev/null
wait_started 9
sleep 1
grep -q '^10 ' "$fake/started" || fail "#10 did not start with 16 GB free"
! grep -q '^11 ' "$fake/started" || fail "#11 started although the free space fell below the limit after the start of #10"
grep -q "ready; 10 GB free in $tmp, below the limit of 15 GB" <<<"$(overview 11)" || fail "#11 does not name the free space read before its start: $(overview 11)"

echo "queue test passed"
