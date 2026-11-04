#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/verify-lock-test.XXXXXX")"
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
  (cd "$worktree" && PATH="${PATH_PREFIX:-}$tmp/bin:/usr/bin:/bin" RECORDS_DISABLED=1 ./scripts/verify.sh "$@") >"$output" 2>&1
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

# The configuration of 'heavy:' is checked.
for conf in "heavy: missing"$'\n'"light: true" "heavy [x]: light"$'\n'"light: true" "heavy: light"$'\n'"heavy: light"$'\n'"light: true"; do
  printf '%s\n' "$conf" >"$tmp/two/scripts/verify.conf"
  status=0
  run_verify "$tmp/two" "$tmp/conf.out" || status=$?
  [[ "$status" -eq 1 ]] || { cat "$tmp/conf.out" >&2; fail "the configuration was not refused: $conf"; }
done

echo "verify-lock tests passed"
