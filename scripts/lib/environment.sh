#!/usr/bin/env bash

# The prerequisites of this machine, for ./scripts/verify.sh (its preflight),
# ./scripts/doctor.sh (read-only, the same checks), and the workflow
# self-tests (tests/lib-fakes.sh builds their toolchain here). Source this
# file; do not execute it. Read-only except for environment_toolchain_build.
#
# Two levels:
#
# - general: what the workflow scripts need on every run, whatever runs:
#   Bash 4 or newer (lib/bootstrap.sh stops an older one before this file is
#   read), Git, and jq 1.6 or newer.
# - self-tests: what the workflow self-tests (scripts/verify-workflow.conf)
#   need, checked only when they are going to run: the isolated test
#   toolchain below.
#
# A missing prerequisite is an environment failure, not a failure of the
# code: verify.sh ends with ENVIRONMENT_STATUS and one line per missing
# prerequisite,
#
#   ENVIRONMENT  <what is missing> — <install command>
#
# and run-feature.sh stops on it without a retry or a repair session. Only
# what these functions establish counts as an environment failure; a check
# or a test that exits non-zero is a failure of the code.
#
# The isolated test toolchain. The self-tests run the workflow scripts with a
# restricted PATH, '<fakes>:<toolchain>/bin:/usr/bin:/bin', so that the fakes
# stand in for the agents and for gh, and nothing else of the machine is
# found by accident. On Linux /usr/bin has every tool the scripts use; on
# macOS it has Bash 3.2, a BSD sed, and no timeout, and Homebrew's tools are
# outside it. The toolchain is a directory of symbolic links to explicitly
# selected executables only:
#
# - required, and checked: Bash 4 or newer, GNU sed, GNU timeout and date
#   (GNU coreutils, or tools that behave as they do, such as the uutils
#   coreutils of Ubuntu 26.04), jq 1.6 or newer, and Git;
# - linked when found: the other coreutils the scripts and tests use
#   (ENVIRONMENT_COREUTILS), GNU ones first.
#
# Never an agent CLI (claude, codex), gh, or another network tool: a test
# that makes one of them available puts a fake of its own first. Each tool is
# taken, in this order, from Homebrew's GNU directories (coreutils and
# gnu-sed, '<prefix>/opt/<formula>/libexec/gnubin'), from PATH, and from
# Homebrew's bin directory; the first that passes its check is linked. On
# Linux that is the system's own tool.

# Exit status of a run that found a prerequisite missing (EX_CONFIG): not a
# failed check, and not a verification.
ENVIRONMENT_STATUS=78

# The tools of the toolchain that are required, each '<name>:<check>':
# 'bash4' (Bash 4 or newer), 'gnu-sed', 'gnu-timeout', 'gnu-date' (it does
# what the scripts need of the GNU tool; the name it gives itself does not
# count), 'jq16' (jq 1.6 or newer), or 'any'.
ENVIRONMENT_TOOLCHAIN_REQUIRED="bash:bash4 sed:gnu-sed timeout:gnu-timeout date:gnu-date jq:jq16 git:any"

# The coreutils that the workflow scripts and their self-tests run, linked
# when found; one that is not stays the system's (/usr/bin, /bin).
ENVIRONMENT_COREUTILS="basename cat chmod cksum comm cp cut dirname du env expr head id ln ls mkdir mktemp mv nohup od paste readlink realpath rm rmdir seq sha256sum sleep sort split stat tail tee touch tr uname uniq wc"

# environment_system: 'macos' on macOS, 'other' otherwise.
environment_system() {
  local name

  name="$(uname -s 2>/dev/null)" || name=""
  if [[ "$name" == Darwin ]]; then echo macos; else echo other; fi
}

# environment_install <tool>: the command that installs <tool> on this
# system.
environment_install() {
  local formula
  local package

  case "$1" in
    bash) formula=bash package=bash ;;
    sed) formula=gnu-sed package=sed ;;
    jq) formula=jq package=jq ;;
    git) formula=git package=git ;;
    *) formula=coreutils package=coreutils ;;
  esac
  if [[ "$(environment_system)" == macos ]]; then
    case "$formula" in
      bash) echo "brew install bash, and put Homebrew's bin directory (brew --prefix) before /bin on PATH" ;;
      *) echo "brew install $formula" ;;
    esac
  else
    echo "install it with the package manager of the system, for example: sudo apt-get install $package"
  fi
}

# environment_homebrew_prefix: Homebrew's prefix, or nothing: HOMEBREW_PREFIX
# when it is set (Homebrew's shell setup sets it; set to a directory without
# brew, it turns Homebrew off here), else the first of its default places
# that holds brew. brew itself is not run: it is slow, and it may be missing
# from a restricted PATH.
environment_homebrew_prefix() {
  local prefix
  local places="/opt/homebrew /usr/local /home/linuxbrew/.linuxbrew"

  [[ -z "${HOMEBREW_PREFIX+set}" ]] || places="$HOMEBREW_PREFIX"
  for prefix in $places; do
    if [[ -x "$prefix/bin/brew" ]]; then
      printf '%s\n' "$prefix"
      return 0
    fi
  done
  return 0
}

# environment_candidates <name>: the executables that may stand for <name>,
# one per line, in the order of the toolchain: Homebrew's GNU directories,
# PATH, Homebrew's bin directory. A toolchain on PATH (a self-test that runs
# another one) stands for the tool it links to, so that both build the same.
environment_candidates() {
  local name="$1"
  local prefix
  local path

  prefix="$(environment_homebrew_prefix)"
  if [[ -n "$prefix" ]]; then
    [[ ! -x "$prefix/opt/coreutils/libexec/gnubin/$name" ]] || printf '%s\n' "$prefix/opt/coreutils/libexec/gnubin/$name"
    [[ ! -x "$prefix/opt/gnu-sed/libexec/gnubin/$name" ]] || printf '%s\n' "$prefix/opt/gnu-sed/libexec/gnubin/$name"
  fi
  while IFS= read -r path; do
    environment_unlinked "$path"
  done < <(type -aP "$name" 2>/dev/null || true)
  if [[ -n "$prefix" && -x "$prefix/bin/$name" ]]; then
    printf '%s\n' "$prefix/bin/$name"
  fi
}

# environment_unlinked <path>: <path>, or the tool it links to when it is a
# link of a toolchain (codeyard-test-toolchain.*/bin/<name>).
environment_unlinked() {
  local target

  if [[ "$1" == */codeyard-test-toolchain.*/bin/* && -L "$1" ]] && target="$(readlink "$1")"; then
    printf '%s\n' "$target"
  else
    printf '%s\n' "$1"
  fi
}

# environment_jq_supports <version>: whether the output of 'jq --version'
# names a jq the workflow scripts support, 1.6 or newer (the minimum of
# docs/development.md and doctor.sh). 'jq-1.5' and the 'jq version 1.3' of
# the oldest releases do not; neither does an output that names no version
# (a build from source without one): it cannot be shown to be 1.6 or newer.
environment_jq_supports() {
  [[ "$1" =~ ^jq(-|\ version\ )([0-9]+)\.([0-9]+) ]] || return 1
  ((BASH_REMATCH[2] > 1 || (BASH_REMATCH[2] == 1 && BASH_REMATCH[3] >= 6)))
}

# environment_passes <path> <check>: whether the executable passes <check>
# ('bash4', 'gnu-sed', 'gnu-timeout', 'gnu-date', 'jq16', or 'any'). The GNU
# checks try the behaviour the scripts rely on: 'sed -i' without a suffix,
# 'timeout --kill-after', 'date -d'. BSD sed takes the script for a suffix,
# and BSD date has no '-d <date>'.
environment_passes() {
  local version
  local work
  local result

  [[ -x "$1" && ! -d "$1" ]] || return 1
  case "$2" in
    bash4)
      "$1" -c '[ "${BASH_VERSINFO:-0}" -ge 4 ]' </dev/null >/dev/null 2>&1
      ;;
    gnu-sed)
      # The file is made by Bash itself, without overwriting one that is
      # there: the PATH may hold no mktemp.
      work="${TMPDIR:-/tmp}"
      work="${work%/}/codeyard-sed-check.$BASHPID.$RANDOM"
      (set -C && printf 'a\n' >"$work") 2>/dev/null || return 1
      result=1
      if "$1" -i 's/a/b/' "$work" </dev/null >/dev/null 2>&1 && [[ "$(<"$work")" == b ]]; then
        result=0
      fi
      rm -f "$work" 2>/dev/null || true
      return "$result"
      ;;
    gnu-timeout)
      # It runs itself, by its path: the PATH may hold nothing else.
      "$1" --kill-after=5 10 "$1" --version </dev/null >/dev/null 2>&1
      ;;
    gnu-date)
      [[ "$(TZ=UTC "$1" -d '2020-01-02 03:04:05' +%s </dev/null 2>/dev/null)" == 1577934245 &&
         "$(TZ=UTC "$1" -d @86400 +%Y-%m-%d </dev/null 2>/dev/null)" == 1970-01-02 ]]
      ;;
    jq16)
      version="$("$1" --version </dev/null 2>/dev/null)" || return 1
      environment_jq_supports "$version"
      ;;
    *) return 0 ;;
  esac
}

# environment_find <name> <check>: the first candidate for <name> that passes
# <check>; fails when there is none.
environment_find() {
  local candidate
  local candidates

  # Read every candidate before the first is tried: returning while a
  # process substitution still writes would end it with SIGPIPE.
  mapfile -t candidates < <(environment_candidates "$1")
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    if environment_passes "$candidate" "$2"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# environment_requirement_text <name> <check>: what is missing, in words.
environment_requirement_text() {
  case "$2" in
    bash4) echo "Bash 4 or newer for the workflow self-tests" ;;
    gnu-*) echo "GNU $1 for the workflow self-tests" ;;
    jq16) echo "$1 1.6 or newer for the workflow self-tests" ;;
    *) echo "$1 for the workflow self-tests" ;;
  esac
}

# environment_general_missing: one line '<what>\t<install command>' per
# missing general prerequisite; nothing when every one is there.
environment_general_missing() {
  local tool
  local version

  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    printf 'Bash 4 or newer (this is %s)\t%s\n' "${BASH_VERSION:-unknown}" "$(environment_install bash)"
  fi
  for tool in git jq; do
    command -v "$tool" >/dev/null 2>&1 || printf '%s\t%s\n' "$tool" "$(environment_install "$tool")"
  done
  # The jq on PATH is the one the scripts run: it must be 1.6 or newer.
  if command -v jq >/dev/null 2>&1; then
    version="$(jq --version </dev/null 2>/dev/null)" || version="unknown"
    [[ "$version" != unknown ]] && environment_jq_supports "$version" ||
      printf 'jq 1.6 or newer (this is %s)\t%s\n' "$version" "$(environment_install jq)"
  fi
}

# environment_toolchain_resolve
# Finds every tool of the toolchain. Sets ENVIRONMENT_TOOLCHAIN_LINKS to one
# line '<name> <path>' per tool that is linked, and ENVIRONMENT_MISSING to
# one line '<what>\t<install command>' per required tool that was not found.
# Fails when one is missing.
environment_toolchain_resolve() {
  local entry
  local name
  local path
  local prefix
  local candidate

  ENVIRONMENT_TOOLCHAIN_LINKS=""
  ENVIRONMENT_MISSING=""
  for entry in $ENVIRONMENT_TOOLCHAIN_REQUIRED; do
    name="${entry%%:*}"
    if path="$(environment_find "$name" "${entry#*:}")"; then
      ENVIRONMENT_TOOLCHAIN_LINKS+="$name $path"$'\n'
    else
      ENVIRONMENT_MISSING+="$(environment_requirement_text "$name" "${entry#*:}")"$'\t'"$(environment_install "$name")"$'\n'
    fi
  done
  prefix="$(environment_homebrew_prefix)"
  for name in $ENVIRONMENT_COREUTILS; do
    path=""
    if [[ -n "$prefix" && -x "$prefix/opt/coreutils/libexec/gnubin/$name" ]]; then
      path="$prefix/opt/coreutils/libexec/gnubin/$name"
    elif candidate="$(type -P "$name" 2>/dev/null)" && [[ -n "$candidate" ]]; then
      path="$(environment_unlinked "$candidate")"
    fi
    [[ -z "$path" ]] || ENVIRONMENT_TOOLCHAIN_LINKS+="$name $path"$'\n'
  done
  [[ -z "$ENVIRONMENT_MISSING" ]]
}

# environment_toolchain_missing: one line '<what>\t<install command>' per
# missing prerequisite of the self-tests; nothing when every one is there.
environment_toolchain_missing() {
  environment_toolchain_resolve || true
  printf '%s' "$ENVIRONMENT_MISSING"
}

# environment_report: reads '<what>\t<install command>' lines and prints
# one 'ENVIRONMENT  <what> — <install command>' line for each.
environment_report() {
  local what
  local install

  while IFS=$'\t' read -r what install; do
    [[ -n "$what" ]] || continue
    printf 'ENVIRONMENT  %s — %s\n' "$what" "$install"
  done
}

# environment_toolchain_intact <dir>: whether the toolchain in <dir> holds
# exactly the links of ENVIRONMENT_TOOLCHAIN_LINKS, each still there.
environment_toolchain_intact() {
  local name
  local path

  [[ -f "$1/links" && "$(<"$1/links")" == "${ENVIRONMENT_TOOLCHAIN_LINKS%$'\n'}" ]] || return 1
  while read -r name path; do
    [[ -z "$name" || -L "$1/bin/$name" ]] || return 1
  done <<<"$ENVIRONMENT_TOOLCHAIN_LINKS"
}

# environment_toolchain_build
# Builds the toolchain, or finds it built, and prints its bin directory. It
# is kept per user and per content (the tools and their paths) under
# ${TMPDIR:-/tmp}, so that every self-test of the machine shares one
# directory of links instead of leaving one behind each: a directory whose
# name carries the checksum of its links is never changed. Fails, with the
# ENVIRONMENT lines on standard error, when a required tool is missing or the
# directory cannot be made.
environment_toolchain_build() {
  local sum
  local base="${TMPDIR:-/tmp}"
  local final
  local work
  local name
  local path

  if ! environment_toolchain_resolve; then
    printf '%s' "$ENVIRONMENT_MISSING" | environment_report >&2
    return 1
  fi
  base="${base%/}"
  sum="$(printf '%s' "$ENVIRONMENT_TOOLCHAIN_LINKS" | cksum | tr ' ' '-')" || sum=""
  final="$base/codeyard-test-toolchain.$(id -u 2>/dev/null || echo user).${sum%%-*}"
  if [[ -n "$sum" && -f "$final/complete" ]]; then
    if environment_toolchain_intact "$final"; then
      printf '%s\n' "$final/bin"
      return 0
    fi
    # A cleaner of the temporary directory removed some of it.
    rm -rf "$final" 2>/dev/null || true
  fi
  work="$(mktemp -d "$base/codeyard-test-toolchain.XXXXXX" 2>/dev/null)" || {
    printf 'ENVIRONMENT  a writable temporary directory for the test toolchain (%s) — set TMPDIR to one\n' "$base" >&2
    return 1
  }
  mkdir -p "$work/bin"
  while read -r name path; do
    [[ -n "$name" ]] || continue
    ln -s "$path" "$work/bin/$name"
  done <<<"$ENVIRONMENT_TOOLCHAIN_LINKS"
  printf '%s' "$ENVIRONMENT_TOOLCHAIN_LINKS" >"$work/links"
  : >"$work/complete"
  if [[ -z "$sum" ]]; then
    # Without a checksum nothing can be shared: this run's own directory.
    printf '%s\n' "$work/bin"
    return 0
  fi
  # Another test may have built the same toolchain meanwhile: a rename onto
  # an existing directory moves this one into it instead, which is removed
  # again; the one that was there first stays.
  mv "$work" "$final" 2>/dev/null || true
  [[ ! -d "$final/${work##*/}" ]] || rm -rf "$final/${work##*/}"
  [[ ! -d "$work" ]] || rm -rf "$work"
  if [[ -f "$final/complete" ]]; then
    printf '%s\n' "$final/bin"
    return 0
  fi
  printf 'ENVIRONMENT  a writable temporary directory for the test toolchain (%s) — set TMPDIR to one\n' "$base" >&2
  return 1
}
