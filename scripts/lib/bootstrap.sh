# The Bash floor of the workflow scripts: Bash 4 or newer. Every entry script
# of scripts/ sources this file first, before anything else runs and before
# any other library is sourced:
#
#   case $0 in */*) bootstrap_dir=${0%/*} ;; *) bootstrap_dir=. ;; esac; [ ! -f "$bootstrap_dir/lib/bootstrap.sh" ] || . "$bootstrap_dir/lib/bootstrap.sh"
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
