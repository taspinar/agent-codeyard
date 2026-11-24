#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-lock-test.XXXXXX")"
# The real path: verify.sh names the worktree of the holder by it, and on
# macOS the temporary directory is under a link (/var -> /private/var).
tmp="$(cd "$tmp" && pwd -P)"
holders=()

cleanup() {
  local pid

  touch "$tmp/go" 2>/dev/null || true
  for pid in ${holders[@]+"${holders[@]}"}; do
    kill -9 "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "verify-lock test failed: $*" >&2
  exit 1
}

# The slot of this test, not the one of the machine.
export VERIFY_LOCK_DIR="$tmp/slot"
unset VERIFY_LOCK_TOKEN
lock="$VERIFY_LOCK_DIR/lock"

# A heavy check that says it started and waits until the test lets it go.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/heavy-work" <<'EOF'
#!/usr/bin/env bash
echo "heavy $PWD" >>"$WORK_LOG"
touch "$WORK_STARTED"
# A deadline, so that a run that should not have started fails the test
# instead of waiting for ever.
for ((tick = 0; tick < 600; tick++)); do
  [[ ! -e "$WORK_GO" ]] || exit 0
  sleep 0.1
done
echo "heavy-work: not let go within 60 seconds" >&2
exit 1
EOF
chmod +x "$tmp/bin/heavy-work"

# A repository with verify.sh, the lock library, and the given configuration,
# with a second worktree: the two worktrees share no files of the slot.
git init -q -b main "$tmp/repo"
mkdir -p "$tmp/repo/scripts/lib"
cp "$source_root/scripts/verify.sh" "$tmp/repo/scripts/verify.sh"
cp "$source_root/scripts/lib/verify-lock.sh" "$tmp/repo/scripts/lib/verify-lock.sh"
cat >"$tmp/repo/scripts/verify.conf" <<'EOF'
heavy: browser
light [lint]: echo light >>"$WORK_LOG"
browser [browser]: heavy-work
EOF
git -C "$tmp/repo" add -A
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.com commit -q -m init
git -C "$tmp/repo" worktree add -q -b feature/1-one "$tmp/one"
git -C "$tmp/repo" worktree add -q -b feature/2-two "$tmp/two"

export WORK_LOG="$tmp/work.log" WORK_STARTED="$tmp/started" WORK_GO="$tmp/go"

# run_verify <worktree> <output> [<argument>...]: verify.sh in the worktree,
# without run records. PATH_PREFIX puts directories before the usual PATH.
run_verify() {
  local worktree="$1"
  local output="$2"

  shift 2
  (cd "$worktree" && PATH="${PATH_PREFIX:-}$tmp/bin:$ISOLATED_PATH" RECORDS_DISABLED=1 ./scripts/verify.sh "$@") >"$output" 2>&1
}

# start_holder <worktree>: starts a verification in the background that
# holds the slot in its heavy check, and waits until the check started.
start_holder() {
  local waited=0

  rm -f "$WORK_STARTED" "$WORK_GO"
  run_verify "$1" "$tmp/holder.out" 2>/dev/null &
  holder=$!
  holders+=("$holder")
  while [[ ! -e "$WORK_STARTED" ]]; do
    kill -0 "$holder" 2>/dev/null || { cat "$tmp/holder.out" >&2; fail "the holding run ended before its heavy check started"; }
    waited=$((waited + 1))
    [[ "$waited" -lt 300 ]] || fail "the heavy check of the holding run did not start"
    sleep 0.1
  done
}

# The verify.sh process of the holder: the child of the subshell started in
# the background.
holder_verify_pid() {
  sed -n 's/^pid=//p' "$lock/owner"
}

# Without a 'heavy:' line nothing is locked: the slot of another run is no
# obstacle, and no lock is written.
mkdir -p "$tmp/plain/scripts"
cp "$source_root/scripts/verify.sh" "$tmp/plain/scripts/verify.sh"
echo 'light: echo plain' >"$tmp/plain/scripts/verify.conf"
mkdir -p "$lock"
printf 'token=other\npid=%s\nstarted=%s\n' "$$" "$(LC_ALL=C ps -o lstart= -p $$ | sed 's/^ *//; s/ *$//')" >"$lock/owner"
run_verify "$tmp/plain" "$tmp/plain.out" || { cat "$tmp/plain.out" >&2; fail "a project without 'heavy:' was stopped by the slot"; }
[[ "$(sed -n 's/^token=//p' "$lock/owner")" == "other" ]] || fail "a project without 'heavy:' touched the slot"
rm -rf "$lock"

# A heavy run takes the slot; a run in another worktree of the machine finds
# it held, names the holder, starts no check, and exits with 75.
start_holder "$tmp/one"
[[ -f "$lock/owner" ]] || fail "the heavy run did not take the slot outside its worktree"
[[ ! -e "$tmp/one/.agents" || -z "$(find "$tmp/one/.agents" -name 'lock*')" ]] || fail "the slot was stored in the worktree"
pid="$(holder_verify_pid)"
: >"$WORK_LOG.two"
status=0
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/busy.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/busy.out" >&2; fail "a competing run exited with $status, not 75"; }
grep -Eq "^BUSY  .*PID $pid, worktree $tmp/one" "$tmp/busy.out" || { cat "$tmp/busy.out" >&2; fail "the busy run did not name the holder's PID and worktree"; }
grep -Fq "not a failure of the code" "$tmp/busy.out" || fail "the busy run did not say that it is no failure"
[[ ! -s "$WORK_LOG.two" ]] || fail "the busy run started a check: $(cat "$WORK_LOG.two")"
grep -Eq '^(FAIL|PASS) ' "$tmp/busy.out" && fail "the busy run reported check results"
grep -Fq "Verification passed" "$tmp/busy.out" && fail "the busy run reported a pass"
[[ ! -e "$tmp/two/.agents/verification" ]] || fail "the busy run recorded a verification"

# Light checks stay available while the slot is held: a run of the light
# groups only takes no slot.
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/light.out" --only lint ||
  { cat "$tmp/light.out" >&2; fail "a run of the light checks was stopped by the slot"; }
grep -Fqx light "$WORK_LOG.two" || fail "the light check did not run"

# A token that is not the holder's does not pass the slot: an inherited or
# copied VERIFY_LOCK_TOKEN is no way around it.
status=0
VERIFY_LOCK_TOKEN="$(sed -n 's/^token=//p' "$lock/owner")" WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/token.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/token.out" >&2; fail "the holder's token passed the slot for a run that the holder did not start"; }

# Released on a normal exit.
touch "$WORK_GO"
wait "$holder" || { cat "$tmp/holder.out" >&2; fail "the holding run failed"; }
[[ ! -e "$lock" ]] || fail "the slot was not released when the run ended"
grep -Fq "Verification passed" "$tmp/holder.out" || fail "the holding run did not pass"

# Released when the run is terminated, after its check is stopped too: the
# check is not let go here, so only the run's SIGTERM to its group ends it.
start_holder "$tmp/one"
pid="$(holder_verify_pid)"
group="$(sed -n 's/^group=//p' "$lock/owner")"
kill -TERM "$pid"
{ wait "$holder"; } 2>/dev/null || true
[[ ! -e "$lock" ]] || fail "the slot was not released when the run was terminated"
kill -0 -- "-$group" 2>/dev/null && fail "the check of a terminated run was not stopped"

# After a crash (SIGKILL, no trap runs) the heavy check that the holder
# started runs on, in the process group that the lock records: the slot is
# still held, and a competing run neither removes the lock nor starts a check.
start_holder "$tmp/one"
pid="$(holder_verify_pid)"
group="$(sed -n 's/^group=//p' "$lock/owner")"
[[ "$group" =~ ^[1-9][0-9]*$ ]] || fail "the holder did not record the process group of its check: '$group'"
kill -KILL "$pid"
{ wait "$holder"; } 2>/dev/null || true
[[ -e "$lock" ]] || fail "the crash left no lock, so the recovery was not tested"
kill -0 -- "-$group" 2>/dev/null || fail "the heavy check ended with its holder, so the orphaned check was not tested"
: >"$WORK_LOG.two"
status=0
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/orphan.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/orphan.out" >&2; fail "a run took the slot while a check of the crashed holder still ran: exit $status"; }
grep -Fq "process group $group" "$tmp/orphan.out" || { cat "$tmp/orphan.out" >&2; fail "the busy run did not name the check that still runs"; }
[[ -e "$lock/owner" ]] || fail "the lock was removed while a check of the crashed holder still ran"
[[ ! -s "$WORK_LOG.two" ]] || fail "a run started a check while a check of the crashed holder still ran"

# Once no process of that group remains, the lock is stale: the next run
# removes it, says so, and takes the slot.
touch "$WORK_GO"
for ((waited = 0; waited < 300; waited++)); do
  kill -0 -- "-$group" 2>/dev/null || break
  sleep 0.1
done
kill -0 -- "-$group" 2>/dev/null && fail "the orphaned heavy check did not end"
run_verify "$tmp/two" "$tmp/recover.out" || { cat "$tmp/recover.out" >&2; fail "a run after a crash did not recover the slot"; }
grep -Fq "removed the stale lock" "$tmp/recover.out" || fail "the recovery did not say that it removed a stale lock"
[[ ! -e "$lock" ]] || fail "the recovered slot was not released"

# A lock whose PID was reused by another process is stale too: the start
# time does not match.
mkdir -p "$lock"
printf 'token=old\npid=%s\nstarted=Mon Jan  1 00:00:00 2001\nworktree=/gone\nrun=none\nsince=2001\n' "$$" >"$lock/owner"
run_verify "$tmp/two" "$tmp/reused.out" || { cat "$tmp/reused.out" >&2; fail "a lock with a reused PID was taken for a live holder"; }

# A holder whose process cannot be inspected, as with a process of another
# user in a shared VERIFY_LOCK_DIR where ps does not show it, is not stale:
# the slot is busy and its lock stays. Here ps shows no process at all; PID 1
# and this test's shell are alive (for PID 1 kill may not be permitted).
mkdir -p "$tmp/blind"
printf '#!/usr/bin/env bash\nexit 1\n' >"$tmp/blind/ps"
chmod +x "$tmp/blind/ps"
for live in 1 "$$"; do
  mkdir -p "$lock"
  printf 'token=hidden\npid=%s\nstarted=Mon Jan  1 00:00:00 2001\nworktree=/elsewhere\nrun=none\nsince=2001\n' "$live" >"$lock/owner"
  : >"$WORK_LOG.two"
  status=0
  PATH_PREFIX="$tmp/blind:" WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/hidden.out" || status=$?
  [[ "$status" -eq 75 ]] || { cat "$tmp/hidden.out" >&2; fail "a live holder that cannot be inspected (PID $live) was taken for stale: exit $status"; }
  [[ "$(sed -n 's/^token=//p' "$lock/owner")" == "hidden" ]] || fail "the lock of a live holder that cannot be inspected was removed"
  grep -Fq "cannot be checked" "$tmp/hidden.out" || { cat "$tmp/hidden.out" >&2; fail "the busy run did not say that the holder cannot be checked"; }
  [[ ! -s "$WORK_LOG.two" ]] || fail "a run started a check while a holder that cannot be inspected held the slot"
  rm -rf "$lock"
done

# Without ps a holder that is confirmed gone (kill finds no such process) is
# still stale.
(exit 0) &
gone=$!
wait "$gone"
mkdir -p "$lock"
printf 'token=gone\npid=%s\nstarted=Mon Jan  1 00:00:00 2001\nworktree=/gone\nrun=none\nsince=2001\n' "$gone" >"$lock/owner"
PATH_PREFIX="$tmp/blind:" run_verify "$tmp/two" "$tmp/gone.out" || { cat "$tmp/gone.out" >&2; fail "a lock whose process is confirmed gone was not recovered when ps shows nothing"; }
grep -Fq "removed the stale lock" "$tmp/gone.out" || fail "the recovery without ps did not say that it removed a stale lock"

# A nested verification, started by a heavy check of the holder, runs in the
# holder's slot and leaves it held.
mkdir -p "$tmp/nested/scripts/lib"
cp "$tmp/repo/scripts/verify.sh" "$tmp/nested/scripts/verify.sh"
cp "$tmp/repo/scripts/lib/verify-lock.sh" "$tmp/nested/scripts/lib/verify-lock.sh"
cat >"$tmp/nested/scripts/verify.conf" <<'EOF'
heavy: inner
inner: echo inner >>"$WORK_LOG"
EOF
printf '#!/usr/bin/env bash\nset -e\ncd "%s"\n./scripts/verify.sh\ntest -d "%s"\n' "$tmp/nested" "$lock" >"$tmp/bin/run-nested"
chmod +x "$tmp/bin/run-nested"
printf 'heavy: outer\nouter: run-nested\n' >"$tmp/one/scripts/verify.conf"
: >"$WORK_LOG"
run_verify "$tmp/one" "$tmp/nested.out" || { cat "$tmp/nested.out" >&2; fail "a nested heavy verification deadlocked or failed"; }
grep -Fqx inner "$WORK_LOG" || fail "the nested heavy check did not run"
[[ ! -e "$lock" ]] || fail "the slot was not released after the nested run"

# A parallel run ('parallel: <n>') holds the slot while any process of any of
# its checks lives: the lock records the process group of every check that
# runs, and releases the slot only when all have ended.
cat >"$tmp/one/scripts/verify.conf" <<'CONF'
parallel: 3
heavy: browser
light [lint]: echo light >>"$WORK_LOG"
browser [browser]: heavy-work
second [browser]: heavy-work
CONF

# start_parallel_holder: starts the parallel run in the background and waits
# until both of its heavy checks started and the lock records both groups.
start_parallel_holder() {
  local waited=0

  rm -f "$WORK_STARTED" "$WORK_GO"
  : >"$WORK_LOG"
  run_verify "$tmp/one" "$tmp/holder.out" 2>/dev/null &
  holder=$!
  holders+=("$holder")
  until [[ "$(grep -c '^heavy ' "$WORK_LOG")" -eq 2 && "$(sed -n 's/^group=//p' "$lock/owner" 2>/dev/null | wc -w | tr -d ' ')" -eq 2 ]]; do
    kill -0 "$holder" 2>/dev/null || { cat "$tmp/holder.out" >&2; fail "the parallel holder ended before its heavy checks started"; }
    waited=$((waited + 1))
    [[ "$waited" -lt 300 ]] || { cat "$tmp/holder.out" >&2; fail "the heavy checks of the parallel holder did not start together"; }
    sleep 0.1
  done
  read -r -a parallel_groups <<<"$(sed -n 's/^group=//p' "$lock/owner")"
  for group in "${parallel_groups[@]}"; do
    [[ "$group" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-$group" 2>/dev/null ||
      fail "the lock records a group that is not one of the running checks: ${parallel_groups[*]}"
  done
}

# Released on a normal exit, when every check has ended.
start_parallel_holder
status=0
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/busy.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/busy.out" >&2; fail "a run took the slot while a parallel holder ran: exit $status"; }
touch "$WORK_GO"
wait "$holder" || { cat "$tmp/holder.out" >&2; fail "the parallel holding run failed"; }
[[ ! -e "$lock" ]] || fail "the slot was not released when the parallel run ended"
grep -Fq "Verification passed" "$tmp/holder.out" || fail "the parallel holding run did not pass"

# Released when the run is terminated, after every check is stopped.
start_parallel_holder
kill -TERM "$(holder_verify_pid)"
{ wait "$holder"; } 2>/dev/null || true
[[ ! -e "$lock" ]] || fail "the slot was not released when the parallel run was terminated"
for group in "${parallel_groups[@]}"; do
  kill -0 -- "-$group" 2>/dev/null && fail "a check of a terminated parallel run was not stopped (group $group)"
done

# After a crash every check runs on: the slot stays held while one of them
# lives, also when the other has ended, and is recovered after.
start_parallel_holder
kill -KILL "$(holder_verify_pid)"
{ wait "$holder"; } 2>/dev/null || true
[[ -e "$lock" ]] || fail "the crash of a parallel run left no lock"
kill -TERM -- "-${parallel_groups[0]}" 2>/dev/null || true
for ((waited = 0; waited < 100; waited++)); do
  kill -0 -- "-${parallel_groups[0]}" 2>/dev/null || break
  sleep 0.1
done
kill -0 -- "-${parallel_groups[1]}" 2>/dev/null || fail "the second check of the crashed parallel run ended, so the slot was not tested"
: >"$WORK_LOG.two"
status=0
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/orphan.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/orphan.out" >&2; fail "a run took the slot while a check of a crashed parallel run still ran: exit $status"; }
[[ ! -s "$WORK_LOG.two" ]] || fail "a run started a check while a check of a crashed parallel run still ran"
touch "$WORK_GO"
for ((waited = 0; waited < 300; waited++)); do
  kill -0 -- "-${parallel_groups[1]}" 2>/dev/null || break
  sleep 0.1
done
run_verify "$tmp/two" "$tmp/recover.out" || { cat "$tmp/recover.out" >&2; fail "a run after the crash of a parallel run did not recover the slot"; }
grep -Fq "removed the stale lock" "$tmp/recover.out" || fail "the recovery after a parallel run did not say that it removed a stale lock"

# A check that ends and leaves a process of its group behind: the group stays
# recorded until that process is gone, so the slot is not free while it lives.
cat >"$tmp/bin/leave-child" <<'EOF'
#!/usr/bin/env bash
heavy-work </dev/null >/dev/null 2>&1 &
echo "$!" >"$WORK_LEFT"
EOF
chmod +x "$tmp/bin/leave-child"
export WORK_LEFT="$tmp/left"

# leftover_alive: succeeds while the process that leave-child left lives.
leftover_alive() {
  [[ -s "$WORK_LEFT" ]] && kill -0 "$(cat "$WORK_LEFT")" 2>/dev/null
}

# await_leftover_gone: lets the leftover go and waits until it has ended.
await_leftover_gone() {
  touch "$WORK_GO"
  for ((waited = 0; waited < 300; waited++)); do
    leftover_alive || return 0
    sleep 0.1
  done
  fail "the process left by a check did not end"
}

# On a normal exit, one check at a time and in parallel: the run ends only
# with the slot held or the leftover stopped, never with the slot free while
# the leftover lives.
for conf in "heavy: leaver"$'\n'"leaver [browser]: leave-child" \
  "parallel: 2"$'\n'"heavy: leaver"$'\n'"leaver [browser]: leave-child"$'\n'"light [lint]: true"; do
  printf '%s\n' "$conf" >"$tmp/one/scripts/verify.conf"
  rm -f "$WORK_GO" "$WORK_LEFT"
  run_verify "$tmp/one" "$tmp/leaver.out" || { cat "$tmp/leaver.out" >&2; fail "a run whose check leaves a process behind failed"; }
  [[ -s "$WORK_LEFT" ]] || fail "the leaving check did not start its process"
  if leftover_alive && [[ ! -e "$lock" ]]; then
    fail "the slot was released while a process of a check of the run still lived ($(head -n 1 <<<"$conf"))"
  fi
  await_leftover_gone
  rm -rf "$lock"
done

# After a crash of a parallel run: the leaving check has ended, its leftover
# lives, and the other check is stopped. The slot stays held for the
# leftover, and is recovered once it is gone.
cat >"$tmp/one/scripts/verify.conf" <<'CONF'
parallel: 2
heavy: leaver second
leaver [browser]: leave-child
second [browser]: heavy-work
CONF
rm -f "$WORK_GO" "$WORK_LEFT" "$WORK_STARTED"
: >"$WORK_LOG"
run_verify "$tmp/one" "$tmp/holder.out" 2>/dev/null &
holder=$!
holders+=("$holder")
for ((waited = 0; waited < 300; waited++)); do
  [[ "$(grep -c '^heavy ' "$WORK_LOG")" -lt 2 ]] || ! grep -Fq -- "-- leaver took" "$tmp/holder.out" || break
  kill -0 "$holder" 2>/dev/null || { cat "$tmp/holder.out" >&2; fail "the parallel run ended before its leaving check ended"; }
  sleep 0.1
done
grep -Fq -- "-- leaver took" "$tmp/holder.out" || { cat "$tmp/holder.out" >&2; fail "the leaving check of the parallel run did not end"; }
leftover_alive || fail "the process left by the check ended, so the slot was not tested"
read -r -a parallel_groups <<<"$(sed -n 's/^group=//p' "$lock/owner")"
kill -KILL "$(holder_verify_pid)"
{ wait "$holder"; } 2>/dev/null || true
for group in "${parallel_groups[@]}"; do
  [[ "$group" -eq "$(ps -o pgid= -p "$(cat "$WORK_LEFT")" | tr -d ' ')" ]] || kill -TERM -- "-$group" 2>/dev/null || true
done
sleep 0.5
leftover_alive || fail "the process left by the check ended with the others, so the slot was not tested"
: >"$WORK_LOG.two"
status=0
WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/orphan.out" || status=$?
[[ "$status" -eq 75 ]] || { cat "$tmp/orphan.out" >&2; fail "a run took the slot while a process left by a check of a crashed run still lived: exit $status"; }
[[ ! -s "$WORK_LOG.two" ]] || fail "a run started a check while a process left by a check of a crashed run still lived"
await_leftover_gone
run_verify "$tmp/two" "$tmp/recover.out" || { cat "$tmp/recover.out" >&2; fail "a run after the leftover of a crashed run ended did not recover the slot"; }
grep -Fq "removed the stale lock" "$tmp/recover.out" || fail "the recovery after the leftover ended did not say that it removed a stale lock"

# A nested verification with 'parallel:' inside the holder's slot (#452): it
# runs its checks one at a time, in the process group of the holder's check
# that started it, which the lock records. A check of the nested run that
# outlives both runs therefore still holds the slot.
mkdir -p "$tmp/pnested/scripts/lib"
cp "$tmp/repo/scripts/verify.sh" "$tmp/pnested/scripts/verify.sh"
cp "$tmp/repo/scripts/lib/verify-lock.sh" "$tmp/pnested/scripts/lib/verify-lock.sh"
cat >"$tmp/pnested/scripts/verify.conf" <<'CONF'
parallel: 2
heavy: inner
inner: nested-work
other: true
CONF
# The nested check: records its PID, says it started, and waits until the
# test lets it go. With NESTED_IGNORE_TERM it ignores SIGTERM.
cat >"$tmp/bin/nested-work" <<'EOF'
#!/usr/bin/env bash
[[ -z "${NESTED_IGNORE_TERM:-}" ]] || trap '' TERM
echo "$$" >"$NESTED_PID"
for ((tick = 0; tick < 600; tick++)); do
  [[ ! -e "$WORK_GO" ]] || exit 0
  sleep 0.1
done
exit 1
EOF
chmod +x "$tmp/bin/nested-work"
# The holder's heavy check: records the PID of the nested verify.sh, which it
# becomes.
printf '#!/usr/bin/env bash\necho "$$" >"%s"\ncd "%s"\nexec ./scripts/verify.sh\n' "$tmp/nested-verify.pid" "$tmp/pnested" >"$tmp/bin/run-pnested"
chmod +x "$tmp/bin/run-pnested"
printf 'heavy: outer\nouter: run-pnested\n' >"$tmp/one/scripts/verify.conf"
export NESTED_PID="$tmp/nested-work.pid"

# nested_alive: succeeds while the nested check lives.
nested_alive() {
  [[ -s "$NESTED_PID" ]] && kill -0 "$(cat "$NESTED_PID")" 2>/dev/null
}

# start_nested_holder: starts the holder and waits until the nested check runs.
start_nested_holder() {
  rm -f "$WORK_GO" "$NESTED_PID" "$tmp/nested-verify.pid"
  run_verify "$tmp/one" "$tmp/holder.out" 2>/dev/null &
  holder=$!
  holders+=("$holder")
  for ((waited = 0; waited < 300; waited++)); do
    ! nested_alive || return 0
    kill -0 "$holder" 2>/dev/null || { cat "$tmp/holder.out" >&2; fail "the holder ended before the nested check started"; }
    sleep 0.1
  done
  fail "the nested check did not start"
}

# expect_nested_held <what>: with the holder and the nested run gone and the
# nested check alive, a competing heavy run finds the slot busy; once the
# check has ended, the next run recovers the slot.
expect_nested_held() {
  local group
  local others

  # The processes of the killed runs end shortly after them (a tee of the
  # holder's check): wait until the recorded group holds nothing else than
  # the nested check, or nothing, so that only that check can keep the slot.
  group="$(sed -n 's/^group=//p' "$lock/owner" 2>/dev/null)"
  for ((waited = 0; waited < 100; waited++)); do
    others="$(ps -eo pid=,pgid= | awk -v g="$group" -v n="$(cat "$NESTED_PID")" '$2 == g && $1 != n { print $1 }')"
    [[ -n "$others" ]] || break
    sleep 0.1
  done
  nested_alive || fail "the nested check ended with the runs, so the slot was not tested ($1)"
  : >"$WORK_LOG.two"
  status=0
  WORK_LOG="$WORK_LOG.two" run_verify "$tmp/two" "$tmp/orphan.out" || status=$?
  [[ "$status" -eq 75 ]] || { cat "$tmp/orphan.out" >&2; fail "a run took the slot while a check of a nested parallel run still ran ($1): exit $status"; }
  [[ ! -s "$WORK_LOG.two" ]] || fail "a run started a check while a check of a nested parallel run still ran ($1)"
  touch "$WORK_GO"
  for ((waited = 0; waited < 300; waited++)); do
    nested_alive || break
    sleep 0.1
  done
  nested_alive && fail "the nested check did not end ($1)"
  run_verify "$tmp/two" "$tmp/recover.out" || { cat "$tmp/recover.out" >&2; fail "a run after the nested check ended did not recover the slot ($1)"; }
  grep -Fq "removed the stale lock" "$tmp/recover.out" || fail "the recovery after a nested parallel run did not say that it removed a stale lock ($1)"
}

# After SIGKILL of the holder and of the nested verify.sh.
start_nested_holder
kill -KILL "$(holder_verify_pid)" "$(cat "$tmp/nested-verify.pid")"
{ wait "$holder"; } 2>/dev/null || true
expect_nested_held "SIGKILL"

# The nested run is stopped normally (SIGTERM) and its check ignores SIGTERM;
# the holder then crashes.
export NESTED_IGNORE_TERM=1
start_nested_holder
nested_verify="$(cat "$tmp/nested-verify.pid")"
kill -TERM "$nested_verify"
for ((waited = 0; waited < 200; waited++)); do
  kill -0 "$nested_verify" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$nested_verify" 2>/dev/null && fail "the nested verify.sh did not end on SIGTERM"
kill -KILL "$(holder_verify_pid)" 2>/dev/null || true
{ wait "$holder"; } 2>/dev/null || true
expect_nested_held "SIGTERM ignored"
unset NESTED_IGNORE_TERM

# The configuration of 'heavy:' is checked.
for conf in "heavy: missing"$'\n'"light: true" "heavy [x]: light"$'\n'"light: true" "heavy: light"$'\n'"heavy: light"$'\n'"light: true"; do
  printf '%s\n' "$conf" >"$tmp/two/scripts/verify.conf"
  status=0
  run_verify "$tmp/two" "$tmp/conf.out" || status=$?
  [[ "$status" -eq 1 ]] || { cat "$tmp/conf.out" >&2; fail "the configuration was not refused: $conf"; }
done

echo "verify-lock tests passed"
