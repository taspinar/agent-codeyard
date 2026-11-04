#!/usr/bin/env bash

# The machine-wide slot for heavy verification: one run at a time on this
# machine runs the checks that a project declares as heavy ('heavy:' in
# scripts/verify.conf or scripts/verify-workflow.conf). Source this file; do
# not execute it. scripts/verify.sh uses it only when a heavy check runs.
#
# The slot is a directory outside every worktree, created with mkdir, which is
# atomic: its file 'owner' names the run that holds it. By default it is
# /tmp/agentic-verify-<uid>/lock, the same for every session and worktree of
# the user on this machine; VERIFY_LOCK_DIR names another directory, for
# example one that several users share. TMPDIR is not used: it may differ
# between sessions, and the slot would then not be shared.
#
# A run that finds the slot held reports the holder and does not start its
# heavy checks. A holder whose run is over (a crash, SIGKILL) is stale: the
# next run removes its lock, under a second lock so that two runs do not both
# remove it, and takes the slot. A process is the holder only when its PID and
# its start time both match the record, so a reused PID is not taken for the
# holder. The holder starts each check in a process group of its own and
# records it in the lock ('group='), and the run is over only when the holder
# is gone and no process of that group remains: a check that outlives its
# crashed holder still holds the slot. Only a run that is confirmed over is
# stale: when a process cannot be inspected (ps does not show the process of
# another user, or kill is not permitted), the slot counts as busy.
#
# A verification that a heavy check starts, inside the run that holds the
# slot, runs in that slot: the holder exports VERIFY_LOCK_TOKEN, and a run
# that finds this token in the lock and the holder among its own ancestors
# neither waits for nor releases the slot. A token without both is ignored.

# Exit status of a run that found the slot busy (EX_TEMPFAIL): not a failed
# check, and not a verification.
VERIFY_LOCK_BUSY=75

# A recovery lock older than this many seconds is left over from a run that
# died while removing a stale lock.
VERIFY_LOCK_RECOVER_SECONDS=60

verify_lock_holder_token=""
verify_lock_holder_text=""
verify_lock_acquired=""
verify_lock_group=""

# verify_lock_path: the lock directory.
verify_lock_path() {
  printf '%s/lock\n' "${VERIFY_LOCK_DIR:-/tmp/agentic-verify-$(id -u)}"
}

# verify_lock_started <pid>: the start time of the process, or nothing when
# it does not exist or ps cannot tell. In the C locale, so that sessions with
# different locales write and compare the same text.
verify_lock_started() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}

# verify_lock_field <owner-file> <key>
verify_lock_field() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | sed -n 1p
}

# verify_lock_exists <pid>
# Succeeds when the process exists, returns 1 when it confirmedly does not
# (kill reports "No such process"), and 2 when that cannot be told, for
# example for a process of another user. A negative <pid> names a process
# group: it exists while any of its processes does.
verify_lock_exists() {
  local out

  out="$(export LC_ALL=C; kill -0 -- "$1" 2>&1)" && return 0
  [[ "$out" != *"No such process"* ]] || return 1
  return 2
}

# verify_lock_alive <owner-file>
# Succeeds when the process that the owner file names exists and is the one
# that wrote it: the same PID with the same start time. Returns 1 only when
# that holder is confirmed gone: no process has the PID, or one with another
# start time. Returns 2 when it cannot be told, for example when ps does not
# show a process of another user, or the owner file records no start time; a
# caller treats that as alive, never as stale.
verify_lock_alive() {
  local pid
  local recorded
  local started=""
  local exists=0

  pid="$(verify_lock_field "$1" pid)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  verify_lock_exists "$pid" || exists=$?
  [[ "$exists" -ne 1 ]] || return 1
  recorded="$(verify_lock_field "$1" started)"
  if command -v ps >/dev/null 2>&1; then
    started="$(verify_lock_started "$pid")"
  fi
  if [[ -n "$started" && -n "$recorded" ]]; then
    [[ "$started" == "$recorded" ]] || return 1
    return 0
  fi
  return 2
}

# verify_lock_held <owner-file>
# Like verify_lock_alive, but for the whole run of the holder: succeeds while
# the holder or a process of the check group it recorded exists. Returns 1
# only when the holder is confirmed gone and so is every process of its group,
# and 2 when that cannot be told.
verify_lock_held() {
  local alive=0
  local group

  verify_lock_alive "$1" || alive=$?
  [[ "$alive" -eq 1 ]] || return "$alive"
  group="$(verify_lock_field "$1" group)"
  [[ -n "$group" ]] || return 1
  [[ "$group" =~ ^[1-9][0-9]*$ ]] || return 2
  verify_lock_exists "-$group"
}

# verify_lock_ancestor <pid>: succeeds when <pid> is this shell or one of its
# ancestors.
verify_lock_ancestor() {
  local current="$$"
  local depth=0

  while [[ "$current" =~ ^[1-9][0-9]*$ && "$depth" -lt 64 ]]; do
    [[ "$current" != "$1" ]] || return 0
    [[ "$current" != 1 ]] || return 1
    current="$(ps -o ppid= -p "$current" 2>/dev/null | tr -d '[:space:]')"
    depth=$((depth + 1))
  done
  return 1
}

# verify_lock_describe <owner-file>: the holder in one line.
verify_lock_describe() {
  printf 'run %s, PID %s, worktree %s, since %s\n' \
    "$(verify_lock_field "$1" run)" "$(verify_lock_field "$1" pid)" \
    "$(verify_lock_field "$1" worktree)" "$(verify_lock_field "$1" since)"
}

# verify_lock_mtime <path>: the modification time in seconds, or 0.
verify_lock_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# verify_lock_recover <lock> <stale-token>
# Removes a stale lock whose owner file still holds <stale-token>. Only the
# run that holds the recovery lock removes it, and it checks the owner again
# under that lock, so a lock that another run took in the meantime stays,
# and so does one whose holder is not confirmed gone.
verify_lock_recover() {
  local lock="$1"
  local recover="$1.recover"
  local alive=0
  local kept=""

  if ! mkdir "$recover" 2>/dev/null; then
    [[ $(($(date +%s) - $(verify_lock_mtime "$recover"))) -gt "$VERIFY_LOCK_RECOVER_SECONDS" ]] || return 1
    rmdir "$recover" 2>/dev/null || return 1
    mkdir "$recover" 2>/dev/null || return 1
  fi
  if [[ "$(verify_lock_field "$lock/owner" token)" == "$2" ]]; then
    verify_lock_held "$lock/owner" || alive=$?
    if [[ "$alive" -eq 1 ]]; then
      rm -rf "$lock"
    else
      kept=1
    fi
  fi
  rmdir "$recover" 2>/dev/null || true
  [[ -z "$kept" ]]
}

# verify_lock_acquire <worktree> <run>
# Takes the slot for this shell. Returns 0 when this run may start its heavy
# checks: it took the slot (verify_lock_acquired is set, and the caller
# releases it with verify_lock_release), or a run among its ancestors holds
# it. Returns VERIFY_LOCK_BUSY when another run holds it, with the holder in
# verify_lock_holder_text, and 1 when the lock cannot be created.
verify_lock_acquire() {
  local worktree="$1"
  local run="${2:--}"
  local lock
  local owner
  local token
  local attempt
  local stale
  local alive

  lock="$(verify_lock_path)"
  owner="$lock/owner"
  if [[ -n "${VERIFY_LOCK_TOKEN:-}" && "$(verify_lock_field "$owner" token)" == "$VERIFY_LOCK_TOKEN" ]] &&
    verify_lock_alive "$owner" && verify_lock_ancestor "$(verify_lock_field "$owner" pid)"; then
    return 0
  fi

  mkdir -p "${lock%/*}" 2>/dev/null || return 1
  token="$$-$(date +%s)-$RANDOM$RANDOM"
  for attempt in 1 2; do
    if mkdir "$lock" 2>/dev/null; then
      {
        echo "token=$token"
        echo "pid=$$"
        echo "started=$(verify_lock_started "$$")"
        echo "worktree=$worktree"
        echo "run=$run"
        echo "since=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
      } >"$lock/owner.tmp" && mv "$lock/owner.tmp" "$owner" || {
        rm -rf "$lock"
        return 1
      }
      verify_lock_acquired="$token"
      export VERIFY_LOCK_TOKEN="$token"
      return 0
    fi
    verify_lock_holder_token="$(verify_lock_field "$owner" token)"
    if [[ -z "$verify_lock_holder_token" ]]; then
      # Being taken right now, or left by a run that died between mkdir and
      # writing its owner: only an old one is stale.
      if [[ "$attempt" -eq 1 && $(($(date +%s) - $(verify_lock_mtime "$lock"))) -gt "$VERIFY_LOCK_RECOVER_SECONDS" ]]; then
        verify_lock_recover "$lock" "" && continue
      fi
      verify_lock_holder_text="a run that is taking the slot right now (lock $lock)"
      return "$VERIFY_LOCK_BUSY"
    fi
    alive=0
    verify_lock_alive "$owner" || alive=$?
    if [[ "$alive" -eq 0 ]]; then
      verify_lock_holder_text="$(verify_lock_describe "$owner")"
      return "$VERIFY_LOCK_BUSY"
    fi
    if [[ "$alive" -eq 1 ]]; then
      alive=0
      verify_lock_held "$owner" || alive=$?
      if [[ "$alive" -ne 1 ]]; then
        verify_lock_holder_text="$(verify_lock_describe "$owner"), whose process has ended but whose check (process group $(verify_lock_field "$owner" group)) still runs or cannot be checked, so its lock is kept (lock $lock)"
        return "$VERIFY_LOCK_BUSY"
      fi
    fi
    if [[ "$alive" -ne 1 ]]; then
      verify_lock_holder_text="$(verify_lock_describe "$owner"), whose process cannot be checked from this run, so its lock is kept (lock $lock)"
      return "$VERIFY_LOCK_BUSY"
    fi
    stale="$(verify_lock_describe "$owner")"
    if [[ "$attempt" -eq 1 ]] && verify_lock_recover "$lock" "$verify_lock_holder_token"; then
      echo "Note: removed the stale lock of heavy verification of $stale: its process and its checks no longer exist." >&2
      continue
    fi
    verify_lock_holder_text="$stale, whose process no longer exists; its lock was not removed, because a check of that run still runs or cannot be checked, or another run is removing the lock (lock $lock)"
    return "$VERIFY_LOCK_BUSY"
  done
  verify_lock_holder_text="another run that took the slot first (lock $lock)"
  return "$VERIFY_LOCK_BUSY"
}

# verify_lock_record_group <pgid>
# Records the process group of the check that this holder starts now, or
# clears it with an empty <pgid>. The owner file is replaced, never edited in
# place, so a reader sees the old record or the new one.
verify_lock_record_group() {
  local owner

  [[ -n "$verify_lock_acquired" ]] || return 0
  owner="$(verify_lock_path)/owner"
  [[ "$(verify_lock_field "$owner" token)" == "$verify_lock_acquired" ]] || return 1
  {
    grep -v '^group=' "$owner" || true
    [[ -z "$1" ]] || echo "group=$1"
  } >"$owner.tmp" && mv "$owner.tmp" "$owner" || return 1
  verify_lock_group="$1"
}

# verify_lock_await_group <holder-pid>
# Run by a check as its first step: waits until the holder recorded this
# check's group ($BASHPID, its leader). Fails when the holder is gone before,
# so that no check runs whose group the lock does not name.
verify_lock_await_group() {
  local owner

  owner="$(verify_lock_path)/owner"
  until [[ "$(verify_lock_field "$owner" group)" == "$BASHPID" ]]; do
    kill -0 "$1" 2>/dev/null || return 1
    sleep 0.05
  done
}

# verify_lock_release
# Gives the slot back when this shell took it and still holds it. A check
# that is still running (the holder was interrupted) is stopped first, with
# SIGTERM to its process group; when it has not ended after ten seconds, the
# lock stays, and the next run recovers it once the group is gone.
verify_lock_release() {
  local lock
  local tick

  [[ -n "$verify_lock_acquired" ]] || return 0
  lock="$(verify_lock_path)"
  if [[ -n "$verify_lock_group" ]] && kill -0 -- "-$verify_lock_group" 2>/dev/null; then
    kill -TERM -- "-$verify_lock_group" 2>/dev/null || true
    for ((tick = 0; tick < 100; tick++)); do
      kill -0 -- "-$verify_lock_group" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 -- "-$verify_lock_group" 2>/dev/null; then
      echo "Note: the check in process group $verify_lock_group did not end; the slot for heavy verification stays held until it has (lock $lock)." >&2
      verify_lock_acquired=""
      return 0
    fi
  fi
  if [[ "$(verify_lock_field "$lock/owner" token)" == "$verify_lock_acquired" ]]; then
    rm -rf "$lock"
  fi
  verify_lock_acquired=""
  verify_lock_group=""
}
