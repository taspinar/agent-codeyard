# The Bash floor of the workflow scripts: Bash 4 or newer. Every entry script
# of scripts/ sources this file first, before anything else runs and before
# any other library is sourced:
#
#   case $0 in */*) bootstrap_dir=${0%/*} ;; *) if [ -f "$0" ]; then bootstrap_dir=.; else bootstrap_dir=$(command -v "$0" 2>/dev/null) && bootstrap_dir=${bootstrap_dir%/*} || bootstrap_dir=.; fi ;; esac; if [ -f "$bootstrap_dir/lib/bootstrap.sh" ]; then . "$bootstrap_dir/lib/bootstrap.sh"; elif [ "${BASH_VERSINFO:-0}" -lt 4 ]; then echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}) — install Bash 4 or newer and put it first on PATH"; echo "Error: ${0##*/} needs Bash 4 or newer and did not find lib/bootstrap.sh; it stopped before it did anything." >&2; exit 78; fi
#
# The line finds this file next to the script also when the script is run by
# name ('bash verify.sh'), which Bash looks up in the current directory and
# then on PATH. Where this file is missing (a test fixture that copies a single
# script), the script runs on under Bash 4 and newer, and below Bash 4 still
# stops with 78, with a shorter ENVIRONMENT line.
#
# Below Bash 4 (the /bin/bash 3.2 of macOS, which '#!/usr/bin/env bash' finds
# when no newer Bash comes first on PATH) the script stops here with the
# environment status 78 (EX_CONFIG) and the line
#
#   ENVIRONMENT  <what is missing> — <install command>
#
# on standard output, as ./scripts/verify.sh reports a missing prerequisite
# (lib/environment.sh): a missing prerequisite, not a failure of the code,
# which run-feature.sh does not repair. Bash 4 and newer pass without a word.
#
# This file is read by an old Bash and by a POSIX sh too, so it uses POSIX sh
# only: no [[ ]], no arrays, no 'local'. It defines nothing and changes
# nothing but the variable bootstrap_dir of the line above.

if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      bootstrap_install="brew install bash, and put Homebrew's bin directory (brew --prefix) before /bin on PATH"
      ;;
    *)
      bootstrap_install="install Bash 4 or newer with the package manager of the system, for example: sudo apt-get install bash"
      ;;
  esac
  echo "ENVIRONMENT  Bash 4 or newer (this is ${BASH_VERSION:-not Bash}${BASH:+ at $BASH}) — $bootstrap_install"
  echo "Error: ${0##*/} needs Bash 4 or newer; it stopped before it did anything. This is a missing prerequisite of this machine, not a failure of the code: $bootstrap_install. ./scripts/doctor.sh lists every prerequisite." >&2
  exit 78
fi
