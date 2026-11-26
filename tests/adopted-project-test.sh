#!/usr/bin/env bash

set -euo pipefail

# The self-tests need nothing of the repository they run in but the
# template's own files: every check of scripts/verify-workflow.conf passes in
# a fixture adopted project that has the state of a real one. The project
# keeps its own CI and excludes it from the template's files, starts its
# features from 'develop', has approved its requirements, has a risk policy
# of its own, has recorded its baseline, has its own ADRs and its own
# agents, has a document that names a plan of its own and a test file of its
# own under tests/, and has an ignore rule that hides the workflow's JSON files (un-ignored again, as the adoption
# does), and has no README.md or LICENSE. It uses both extension points of a
# project (docs/development.md): a policy override in
# .agents/policy-overrides/risk.conf and a CI setup in
# .github/actions/project-setup/action.yml. It still edits the shipped
# .agents/policies/risk.conf as well, so a project that keeps its choices
# there and one that uses the override are both represented.
#
# The fixture runs only the self-tests that read something it varies, the
# list below (Issue 478): every other self-test has the same inputs in the
# fixture as in the template, and the framework-only ones never run in a
# project. Before it runs them, it derives from the fixture which self-tests
# read a file that the fixture varies and fails when one is not on the list
# (fixture_reads).
#
# Usage: tests/adopted-project-test.sh [--all | --check-list]
#   --all          the full form: every other self-test of
#                  scripts/verify-workflow.conf in the fixture, the
#                  framework-only ones too (but the test of the list).
#   --check-list   only builds the fixture and checks the list.
#
# ADOPTED_PROJECT_JOBS sets how many self-tests run at a time (default 4).

# The self-tests that read something the fixture varies, '<check>: <what it
# reads>'. A self-test that reads such a file and is not here fails this
# check; a new self-test that reads the repository it runs in goes here, with
# what it reads. A framework-only self-test is never here: a project does
# not run it.
fixture_tests=(
  "verify: the self-test files that scripts/verify-workflow.conf names, by a path in a variable (\$source_root/\$test), where the project keeps its own tests"
  "bootstrap: runs scripts/check-risk.sh in the repository itself"
  "check-docs: builds its fixture from the repository's own files (git ls-files of it) and asks template_repository whether this is the template"
  "check-ci-groups: .github/workflows/ci.yml, the project's own CI, and template_repository"
  "status: website/, which the project does not have, and template_repository"
  "agent-levels: .agents/agents.conf, the project's agents, and template_repository"
  "sync-template: .github/workflows/ci.yml, the project's CI, its .agents/template.conf (template_conf), and template_repository"
  "inherited: a snapshot of the repository's own files (git ls-files of it) and its .agents/template.conf (template_conf)"
  "template-repository: .github/workflows/ci.yml, the project's own CI, and the origin of the repository (template_repository)"
  "pipe-grep: every tests/*.sh, the project's own test file too, and template_repository"
  "risk: .agents/policies/risk.conf, which the project edited, and template_repository"
)

mode=listed
case "${1:-}" in
  "") ;;
  --all) mode=all ;;
  --check-list) mode=check ;;
  *)
    echo "Usage: $0 [--all | --check-list]" >&2
    exit 2
    ;;
esac
[[ "$#" -le 1 ]] || {
  echo "Usage: $0 [--all | --check-list]" >&2
  exit 2
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/adopted-project-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "adopted project test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"

# This check itself and the test of its list, which do not run inside the
# fixture: there a fixture of the fixture would vary nothing.
self="tests/$(basename "${BASH_SOURCE[0]}")"
self_list="tests/adopted-project-list-test.sh"

# The template's files, as an adoption gives them to a project: without the
# website of the template (website/) and the CI workflows of the template, its decisions,
# records, and top-level README and LICENSE, and without the state of the
# repository these tests run in.
project="$tmp/project"
mkdir -p "$project"
(cd "$source_root" && git ls-files -co --exclude-standard -z -- . ':(exclude)website' ':(exclude).github/workflows' \
  ':(exclude)README.md' ':(exclude)LICENSE' ':(exclude).agents/approval-requests' ':(exclude).agents/verification-baseline' \
  ':(exclude).agents/template.conf' ':(exclude).gitignore' |
  while IFS= read -r -d '' path; do
    [[ "$path" != docs/decisions/* || "$path" == docs/decisions/README.md ]] || continue
    [[ -f "$path" ]] && printf '%s\0' "$path"
  done |
  tar --null -T - -cf -) | tar -C "$project" -xf -
[[ -x "$project/$self" ]] || fail "the fixture project does not have the self-tests"
# A project without the template's site: no self-test may need it.
[[ ! -e "$project/website" ]] || fail "the fixture project has files under website/: $(cd "$project" && find website -type f | head -n 3)"

# The project's own state. Its own CI is one job that runs verify.sh, in a
# layout of its own: no self-test may check it as the template's ci.yml.
mkdir -p "$project/.github/workflows" "$project/docs/decisions"
printf 'name: project-ci\non: [push, pull_request]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: make test\n      - run: ./scripts/verify.sh --all\n' \
  >"$project/.github/workflows/ci.yml"
grep -Fq './scripts/verify.sh' "$project/.github/workflows/ci.yml" || fail "the fixture's own CI does not run verify.sh"
# Its planning is approved: no self-test may need the draft the template
# ships.
sed -e 's/^Status: Draft$/Status: Approved/' -e 's/^Approved at: Not approved$/Approved at: 2026-01-05T09:00:00Z/' \
  "$project/docs/PROJECT_REQUIREMENTS.md" >"$tmp/requirements.md"
mv "$tmp/requirements.md" "$project/docs/PROJECT_REQUIREMENTS.md"
grep -Fqx 'Status: Approved' "$project/docs/PROJECT_REQUIREMENTS.md" || fail "the fixture's requirements are not approved"
# Its risk policy is its own: the light profile and classes of its own, in
# its policy override, and a class of its own still written into the shipped
# risk.conf, as a project did before the override. No self-test may need the
# policy the template ships.
printf '\nhigh: src/billing\n' >>"$project/.agents/policies/risk.conf"
grep -Fqx 'high: src/billing' "$project/.agents/policies/risk.conf" || fail "the fixture does not edit the shipped risk policy"
mkdir -p "$project/.agents/policy-overrides"
printf '# The project'"'"'s risk policy.\nprofile: light\nhigh: src/payments\nmanifests: package.json package-lock.json\n' \
  >"$project/.agents/policy-overrides/risk.conf"
grep -Fqx 'profile: light' "$project/.agents/policy-overrides/risk.conf" || fail "the fixture has no policy override"
# Its CI setup, the composite action that ci.yml runs before the verification.
mkdir -p "$project/.github/actions/project-setup"
printf 'name: Project setup\ndescription: Installs the dependencies of the project.\nruns:\n  using: composite\n  steps:\n    - run: make deps\n      shell: bash\n' \
  >"$project/.github/actions/project-setup/action.yml"
grep -Fqx '  using: composite' "$project/.github/actions/project-setup/action.yml" || fail "the fixture has no CI setup action"
printf '# 0001. Store orders in PostgreSQL\n\nStatus: Accepted\n\nThe project keeps its orders in PostgreSQL.\n' \
  >"$project/docs/decisions/0001-store-orders-in-postgresql.md"
# Its agents are its own: other models and level lines for the roles than
# the template's. No self-test may need the agents the template ships. The
# writing roles stay on Claude; tests/agent-sandbox-test.sh, which would
# start the real Codex CLI for a writing role on Codex, is no self-test
# (Issue 522) and does not run here. The assessor, a role that only reads, is on Codex: no self-test of the
# assessment or the adoption may take its assessor from this file.
cat >"$project/.agents/agents.conf" <<'EOF'
# The project's agents.
project-grill: claude sonnet
project-planner: claude sonnet
planning-reviewer: codex gpt-6-luna
implementer: claude sonnet
implementer@medium: claude opus
reviewer: codex gpt-6-astra
reviewer@high: codex gpt-6-luna
triage: claude opus
triage-implementer: claude sonnet
analyst: codex gpt-6-luna
assessor: codex gpt-6-luna
EOF
grep -Fqx 'implementer: claude sonnet' "$project/.agents/agents.conf" || fail "the fixture has no agents of its own"
# Its AGENTS.md is its own: the section of the template's that an adoption
# appends has another heading here. No self-test may need the instructions
# the template ships.
sed 's/^## Definition of Done$/## When the work is done/' "$project/AGENTS.md" >"$tmp/agents.md"
mv "$tmp/agents.md" "$project/AGENTS.md"
grep -Fqx '## When the work is done' "$project/AGENTS.md" && ! grep -Fqx '## Definition of Done' "$project/AGENTS.md" ||
  fail "the fixture has no AGENTS.md of its own"
# Its documents name a plan of its own, which the template does not have.
mkdir -p "$project/.agents/plans"
printf '# Plan of the project Issue 12\n' >"$project/.agents/plans/12-orders-api.md"
printf '\n## Orders\n\nThe orders API follows `.agents/plans/12-orders-api.md`.\n' >>"$project/docs/architecture.md"
grep -Fq '`.agents/plans/12-orders-api.md`' "$project/docs/architecture.md" ||
  fail "the fixture has no document that names a plan of its own"
# It has a test file of its own, named like a self-test, that neither
# sources tests/lib-fakes.sh nor avoids a pipe into a quiet grep, a form the
# workflow's self-tests do not use (tests/pipe-grep-test.sh): the project's
# tests follow its own rules. The pipe is written as $bar so that this file
# does not hold the form.
bar='|'
own_test="./scripts/orders.sh list $bar grep -q order"
printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$own_test" >"$project/tests/orders-test.sh"
chmod +x "$project/tests/orders-test.sh"
grep -Fqx "$own_test" "$project/tests/orders-test.sh" || fail "the fixture has no test file of its own"
template_conf "$tmp/template.conf"
sed -E -e '/^repository:/ s#:.*#: https://example.com/owner/template#' \
  -e '/^paths:/ s#$# :(exclude).github/workflows/ci.yml#' "$tmp/template.conf" >"$project/.agents/template.conf"
printf 'commit: 0123456789abcdef0123456789abcdef01234567\nbase: develop\n' >>"$project/.agents/template.conf"
grep -Fq ':(exclude).github/workflows/ci.yml' "$project/.agents/template.conf" || fail "the fixture does not exclude its CI"
workflow_gitignore "$tmp/workflow.gitignore"
{
  printf '# The project'"'"'s own rules.\n*.json\n*.log\ndocs/drafts/\ntests/fixtures/\n'
  printf '\n# agent-codeyard: the working files of the workflow (added by adopt-repository.sh)\n'
  cat "$tmp/workflow.gitignore"
} >"$project/.gitignore"
git -C "$project" init -q -b main
# The workflow's files that the project's rule hides, and an approval request
# it writes later, un-ignored again as the adoption does: a file of .agents/
# by its directory and extension, another by itself.
mkdir -p "$project/.agents/approval-requests"
: >"$project/.agents/approval-requests/1.json"
git -C "$project" ls-files -o -i --exclude-standard | while IFS= read -r path; do
  name="${path##*/}"
  if [[ "$path" == .agents/*/* && "$name" == ?*.* ]]; then
    printf '!/%s/*.%s\n' "${path%/*}" "${name##*.}"
  else
    printf '!/%s\n' "$path"
  fi
done | awk '!seen[$0]++' >"$tmp/unignore"
grep -Fxq '!/.agents/schemas/*.json' "$tmp/unignore" || fail "the project's rule hides no file of the workflow"
cat "$tmp/unignore" >>"$project/.gitignore"
rm -r "$project/.agents/approval-requests"
[[ -z "$(git -C "$project" ls-files -o -i --exclude-standard)" ]] || fail "the fixture hides files of the workflow"
{
  sed -nE 's/^([a-z0-9-]+)( \[[^]]*\])?( partition [^:]+)?: .*/pass: \1/p' "$project/scripts/verify.conf" |
    grep -Ev '^pass: (budget-seconds|parallel)$'
} >"$project/.agents/verification-baseline"
[[ -s "$project/.agents/verification-baseline" ]] || fail "the fixture has no baseline"
git -C "$project" add -A
git -C "$project" -c user.name=Owner -c user.email=owner@example.com commit -qm "The adopted project"
for path in .agents/policy-overrides/risk.conf .github/actions/project-setup/action.yml; do
  git -C "$project" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || fail "the fixture does not track its $path"
done
git -C "$project" branch develop
git -C "$project" switch -q develop
git init -q --bare -b main "$tmp/project-remote.git"
git -C "$project" remote add origin "$tmp/project-remote.git"
git -C "$project" push -q origin main develop
for path in README.md LICENSE; do
  [[ ! -e "$project/$path" ]] || fail "the fixture has a $path"
done

# What the fixture varies: every file that the fixture has and the
# repository it was built from has not, or the other way round, or that both
# have with other content.
(cd "$source_root" && git ls-files -co --exclude-standard -z) | while IFS= read -r -d '' path; do
  [[ -f "$source_root/$path" ]] && printf '%s\n' "$path"
done | LC_ALL=C sort -u >"$tmp/source.files"
git -C "$project" ls-files | LC_ALL=C sort -u >"$tmp/project.files"
{
  LC_ALL=C comm -3 "$tmp/source.files" "$tmp/project.files" | tr -d '\t'
  LC_ALL=C comm -12 "$tmp/source.files" "$tmp/project.files" | while IFS= read -r path; do
    cmp -s "$source_root/$path" "$project/$path" || printf '%s\n' "$path"
  done
} | LC_ALL=C sort -u >"$tmp/varied"
for path in .github/workflows/ci.yml .agents/agents.conf docs/PROJECT_REQUIREMENTS.md tests/orders-test.sh; do
  grep -Fqx -- "$path" "$tmp/varied" || fail "the fixture does not vary $path"
done

# varied_ref <path>
# Succeeds when <path>, a path or a glob relative to the repository root, is
# or names a file the fixture varies: the file, a directory above it, or a
# glob that matches it.
varied_ref() {
  local ref="${1%/}"
  local file

  [[ -n "$ref" ]] || return 0
  while IFS= read -r file; do
    # shellcheck disable=SC2053
    if [[ "$file" == "$ref" || "$file" == "$ref"/* || "$file" == $ref ]]; then
      return 0
    fi
  done <"$tmp/varied"
  return 1
}

# The helpers of tests/lib-fakes.sh that read a varied file of the
# repository they are sourced from: one written '<name> <file>' counts only
# when what it writes differs in the fixture (workflow_gitignore gives the
# workflow's part of .gitignore, the same in both); any other always counts.
: >"$tmp/varied-helpers"
while IFS= read -r helper; do
  body="$(sed -n "/^$helper() {\$/,/^}\$/p" "$source_root/tests/lib-fakes.sh")"
  reads=no
  while IFS= read -r ref; do
    if varied_ref "$ref"; then reads=yes; fi
  done < <(grep -oE '\$\{?source_root\}?"?/[A-Za-z0-9_.*/-]*' <<<"$body" | sed -E 's#^[^/]*/##')
  [[ "$reads" == yes ]] || continue
  if grep -Eqx "# $helper <file>" "$source_root/tests/lib-fakes.sh" &&
    (source "$source_root/tests/lib-fakes.sh" && "$helper" "$tmp/helper.source") &&
    (source "$project/tests/lib-fakes.sh" && "$helper" "$tmp/helper.project") &&
    cmp -s "$tmp/helper.source" "$tmp/helper.project"; then
    continue
  fi
  printf '%s\n' "$helper" >>"$tmp/varied-helpers"
done < <(sed -nE 's/^([a-z_][a-z0-9_]*)\(\) \{$/\1/p' "$source_root/tests/lib-fakes.sh")

# root_vars <file>
# Prints '<variable> <directory>' for each variable of <file> that holds the
# root of the repository it runs in (assigned from the directory above its
# own or from 'git rev-parse --show-toplevel'), the directory '.', or the
# directory of <file> itself (assigned from 'dirname "${BASH_SOURCE[0]}"'),
# its path from the root.
root_vars() {
  local file="$1"
  local dir

  dir="${file#"$source_root"/}"
  if [[ "$dir" == */* ]]; then dir="${dir%/*}"; else dir=.; fi
  sed -nE 's/^[[:space:]]*(local )?([a-z_]+)="\$\((cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)\/\.\." && pwd( -P)?|git rev-parse --show-toplevel( 2>\/dev\/null)?)\)"([[:space:]].*)?$/\2 ./p' "$file"
  sed -nE 's/^[[:space:]]*(local )?([a-z_]+)="\$\(cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)" && pwd( -P)?\)"([[:space:]].*)?$/\2/p' "$file" |
    while IFS= read -r var; do printf '%s %s\n' "$var" "$dir"; done
}

# root_path <directory> <path>: <path> from <directory>, as a path from the
# root of the repository, without '.', '..', or an empty part (so never with
# a leading or trailing slash); empty for the root itself. A '..' above the
# root stays.
root_path() {
  local -a parts
  local -a out=()
  local part

  IFS=/ read -r -a parts <<<"$1/$2"
  for part in "${parts[@]}"; do
    case "$part" in
      "" | .) ;;
      ..)
        if [[ "${#out[@]}" -gt 0 && "${out[${#out[@]} - 1]}" != .. ]]; then
          unset "out[${#out[@]} - 1]"
        else
          out+=(..)
        fi
        ;;
      *) out+=("$part") ;;
    esac
  done
  (IFS=/ && printf '%s\n' "${out[*]}")
}

# relative_uses <root pattern> <<<"<text>"
# Prints 'read <path>' and 'run <path>' for each relative path that the
# shell text <text> reads or runs while its working directory is still the
# one it started in: a self-test starts in the root of the repository (the
# checks of scripts/verify-workflow.conf run there), and a script it runs
# counts as if it ran there too. A path is read as the file operand of a
# reading command (cat, grep, sed, cmp, cp, ls, find, ...), an input
# redirection, or a test such as [[ -f <path> ]]; it is run as the command
# word or the script of bash, sh, source, or '.'. The directory is followed
# through each 'cd' and 'pushd' in the same shell while it is known to be in
# the repository: a word that <root pattern> matches (a root variable: cd
# "$source_root") is the root, with a path after it a directory of the
# repository; '.', './', "$PWD", "$(pwd)", and an option such as '--' change
# nothing; a relative directory (cd tests) is followed, and a path read
# there counts from it (../AGENTS.md is AGENTS.md of the root); 'cd -',
# "$OLDPWD", and 'popd' go back to where the shell was. Any other 'cd' (a
# variable, an absolute path) leaves the repository, and a relative 'cd'
# after it stays outside. For a command of git, tar, or make after
# '-C <dir>' the directory is <dir>, by the same rules; a command
# substitution in its words runs in the directory of the shell. A 'cd' in a
# subshell or a command substitution ends with it. Its functions count, as
# if called in the root, when it calls them where the directory is known,
# and so on. '.' and '..' are paths like any other: 'ls .' in the root
# reads the repository.
# Comments, heredocs, the values of arrays, the patterns of case, and the
# pattern or program of grep, sed, awk, and jq are no paths, and neither is
# a word that holds an expansion.
relative_awk="$(
  cat <<'AWK'
function isrel(w) { return w ~ /^[A-Za-z0-9_.][A-Za-z0-9_.*\/-]*$/ && w ~ /[\/.]/ }
# target(w, cur, curmoved): the directory <w> from the directory <cur>, as a
# path from the root, or "!" when it is not known to be in the repository.
function target(w, cur, curmoved,   k, head) {
  k = index(w, "/"); head = k ? substr(w, 1, k - 1) : w
  if (head ~ rootre) { cur = ""; curmoved = 0; w = k ? substr(w, k + 1) : ""; sub(/^\/+/, "", w) }
  else if (head ~ /^[$][{]?PWD[}]?$/) { w = k ? substr(w, k + 1) : ""; sub(/^\/+/, "", w) }
  if (curmoved || w ~ /^\// || w !~ /^[A-Za-z0-9_.\/-]*$/) return "!"
  return (w == "") ? cur : cur "/" w
}
function adduse(kind, w,   d) { d = cset ? ccwd : cwd; uses[++nuses] = ctx " " kind " " ((d == "") ? w : d "/" w) }
function flush(   w, here) {
  if (word == "" && !quoted) return
  if (inarray) { finish(); return }
  w = word; here = cset ? (cmoved == 0) : (moved == 0)
  if (redir == "<") { if (here && !wbad && isrel(w)) adduse("read", w); redir = ""; finish(); return }
  if (redir != "") { redir = ""; finish(); return }
  if (cdnext) {
    if (w ~ /^-[A-Za-z-]+$/) { finish(); return }
    cdnext = 0
    if (cmd == "pushd") { pmoved[++npushed] = moved; pcwd[npushed] = cwd }
    if (w == "-" || w ~ /^[$][{]?OLDPWD[}]?$/) { t = oldmoved; u = oldcwd; oldmoved = moved; oldcwd = cwd; moved = t; cwd = u }
    else {
      t = target(w, cwd, moved); oldmoved = moved; oldcwd = cwd
      if (t == "!") moved = 1; else { moved = 0; cwd = t }
    }
    finish(); return
  }
  if (cnext) {
    cnext = 0; t = target(w, cwd, moved); cset = 1
    if (t == "!") cmoved = 1; else { cmoved = 0; ccwd = t }
    finish(); return
  }
  if (cmd == "") {
    if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w ~ /^(then|do|else|elif|exec|env|command|time|!|if|while|until|\[\[|\[)$/) {
      if (w == "[[" || w == "[") { cmd = "test" }
      finish(); return
    }
    cmd = w; nonopt = 0; pat = 0; testop = 0; findexpr = 0; ddash = 0; skip = 0; ncmds[depth]++
    if (here) calls[ctx] = calls[ctx] " " w
    if (here && !wbad && isrel(w) && w ~ /\//) adduse("run", w)
    if (w == "cd" || w == "pushd") cdnext = 1
    if (w == "popd") { if (npushed > 0) { moved = pmoved[npushed]; cwd = pcwd[npushed]; npushed-- } else moved = 1 }
    finish(); return
  }
  if (skip > 0) { skip--; finish(); return }
  if (w == "-C" && cmd ~ /^(git|tar|make)$/) { cnext = 1; finish(); return }
  if (cmd == "test") {
    if (w ~ /^-[a-zA-Z]$/) { testop = 1; finish(); return }
    if (testop && here && !wbad && isrel(w)) adduse("read", w)
    testop = 0; finish(); return
  }
  if (w ~ /^-/ && !ddash) {
    if (w == "--") ddash = 1
    if ((cmd ~ /^(grep|egrep|fgrep|rg|sed)$/ && w ~ /^-([a-zA-Z]*[ef]|-regexp|-file|-expression)/) || (cmd ~ /^(awk|gawk)$/ && w ~ /^-f/) || (cmd == "jq" && w ~ /^-(f|-from-file)/)) pat = 1
    if (cmd == "find") findexpr = 1
    if (cmd ~ /^(grep|egrep|fgrep|rg|sed)$/ && w ~ /^(-[a-zA-Z]*[efmABCd]|--regexp|--file|--expression|--max-count)$/) skip = 1
    if ((cmd == "cut" && w ~ /^-[dfcb]$/) || (cmd == "sort" && w ~ /^-[tkoST]$/) || (cmd ~ /^(head|tail)$/ && w ~ /^-[nc]$/)) skip = 1
    if (cmd ~ /^(awk|gawk)$/ && w ~ /^-[fv]$/) skip = 1
    if (cmd == "jq" && w ~ /^(-f|--from-file|--indent)$/) skip = 1
    if (cmd == "jq" && w ~ /^--(arg|argjson|slurpfile|rawfile)$/) skip = 2
    finish(); return
  }
  nonopt++
  if (cmd ~ /^(bash|sh|source|\.)$/) {
    if (nonopt == 1 && here && !wbad && isrel(w)) adduse("run", w)
    finish(); return
  }
  if (cmd ~ /^(grep|egrep|fgrep|rg|sed|awk|gawk|jq)$/ && nonopt == 1 && !pat) { finish(); return }
  if (cmd == "find" && findexpr) { finish(); return }
  if (cmd ~ /^(for|case|select)$/) { finish(); return }
  if (cmd ~ /^(cat|head|tail|grep|egrep|fgrep|rg|sed|awk|gawk|jq|cmp|diff|cp|ls|find|wc|cksum|sha256sum|shasum|md5sum|stat|sort|uniq|cut|tar|xargs|readlink|realpath|file|less|more|od|xxd|base64|yq|python3|python|node)$/ && here && !wbad && isrel(w)) {
    adduse("read", w)
  }
  finish()
}
function finish() { word = ""; wbad = 0; quoted = 0 }
function boundary() { flush(); if (cmd != "") lastcmd = cmd; cmd = ""; skip = 0; cdnext = 0; cnext = 0; cset = 0; cmoved = 0; ddash = 0; redir = "" }
BEGIN { ctx = "top"; moved = 0; cwd = ""; oldmoved = 1; depth = 0 }
{
  line = $0
  if (hd != "") { t = line; if (hdtab) sub(/^\t+/, "", t); if (t == hd) hd = ""; next }
  if (state == "" && line ~ /^[[:space:]]*#/) next
  onel = 0
  if (state == "" && depth == 0 && ctx == "top" && match(line, /^[a-z_][a-z0-9_]*\(\) \{ .*\}$/)) {
    fname = substr(line, 1, index(line, "(") - 1); line = substr(line, index(line, "{") + 1)
    sub(/\}$/, "", line); ctx = fname; savedmoved = moved; savedcwd = cwd; moved = 0; cwd = ""; onel = 1
  } else if (state == "" && depth == 0 && ctx == "top" && match(line, /^[a-z_][a-z0-9_]*\(\) \{$/)) {
    ctx = substr(line, 1, index(line, "(") - 1); savedmoved = moved; savedcwd = cwd; moved = 0; cwd = ""; next
  }
  if (state == "" && ctx != "top" && line == "}") { boundary(); ctx = "top"; moved = savedmoved; cwd = savedcwd; depth = 0; next }
  if (state == "" && match(line, /(^|[^<])<<-?[[:space:]]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
    if (substr(line, RSTART, 1) != "<") { RSTART++; RLENGTH-- }
    h = substr(line, RSTART, RLENGTH); hdtab = (h ~ /^<<-/); gsub(/^<<-?[[:space:]]*|['"]/, "", h); hd = h
    line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
  }
  cont = 0
  if (state == "" && line ~ /\\$/) { cont = 1; line = substr(line, 1, length(line) - 1) }
  if (state == "" && incase && line ~ /^[[:space:]]*esac([[:space:];)]|$)/) incase = 0
  if (state == "" && incase && match(line, /^[[:space:]]*[^()]*\)/)) line = substr(line, RSTART + RLENGTH)
  if (state == "" && line ~ /(^|[;&|[:space:]])case[[:space:]].*[[:space:]]in[[:space:]]*$/) incase = 1
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (state == "sq") { if (c == "'") state = ""; else word = word c; continue }
    if (c == "\\") { word = word substr(line, i + 1, 1); i++; continue }
    if (c == "$" && substr(line, i + 1, 1) == "(") {
      d = depth + 1; outer[d] = state; savedword[d] = word; savedcmd[d] = cmd; savednon[d] = nonopt
      savedskip[d] = skip; skip = 0; savedpat[d] = pat; savedddash[d] = ddash; savedredir[d] = redir; savedtestop[d] = testop
      savedcset[d] = cset; savedcmoved[d] = cmoved; savedccwd[d] = ccwd; cset = 0; savedfind[d] = findexpr; savedcd[d] = cdnext; savedc[d] = cnext; savedarr[d] = inarray; inarray = 0
      stack[++depth] = moved; cwdstack[depth] = cwd; ncmds[depth] = 0; state = ""; finish(); i++
      cmd = ""; redir = ""; ddash = 0; pat = 0; testop = 0; cdnext = 0; cnext = 0
      continue
    }
    if (state == "dq") {
      if (c == "\"") { state = ""; continue }
      if (c == "$" || c == "`") wbad = 1
      word = word c; continue
    }
    if (c == "'") { state = "sq"; quoted = 1; continue }
    if (c == "\"") { state = "dq"; quoted = 1; continue }
    if (c == "$" || c == "`") { wbad = 1; word = word c; continue }
    if (c == "(") {
      if (substr(line, i + 1, 1) == "(") { word = word c; continue }
      if (word ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=$/) { word = word "()"; wbad = 1; inarray = 1; continue }
      boundary(); outer[depth + 1] = "sub"; stack[++depth] = moved; cwdstack[depth] = cwd; ncmds[depth] = 0; continue
    }
    if (c == ")" && inarray) { inarray = 0; finish(); continue }
    if (c == ")") {
      boundary()
      if (depth > 0) {
        moved = stack[depth]; cwd = cwdstack[depth]
        if (outer[depth] != "sub") {
          d = depth; state = outer[d]; word = savedword[d] ((ncmds[d] == 1 && lastcmd == "pwd") ? "$PWD" : "$()"); wbad = 1; cmd = savedcmd[d]; nonopt = savednon[d]
          skip = savedskip[d]; pat = savedpat[d]; ddash = savedddash[d]; redir = savedredir[d]; testop = savedtestop[d]
          cset = savedcset[d]; cmoved = savedcmoved[d]; ccwd = savedccwd[d]; findexpr = savedfind[d]; cdnext = savedcd[d]; cnext = savedc[d]; inarray = savedarr[d]
        }
        depth--
      }
      continue
    }
    if (c == "<" || c == ">") {
      flush()
      if (c == "<" && substr(line, i + 1, 1) == "<") { i++; if (substr(line, i + 1, 1) == "<") i++; redir = ">"; continue }
      redir = c; if (substr(line, i + 1, 1) ~ /[>&]/) i++
      continue
    }
    if (c ~ /[;&|]/) { boundary(); continue }
    if (c ~ /[[:space:]]/) { flush(); continue }
    if ((c == "{" || c == "}") && word == "") { boundary(); continue }
    word = word c
  }
  if (state == "" && cont) flush()
  else if (state == "") boundary()
  else word = word "\n"
  if (onel) { ctx = "top"; moved = savedmoved; cwd = savedcwd }
}
END {
  reach["top"] = 1
  for (changed = 1; changed; ) {
    changed = 0
    for (c in reach) list[c] = 1
    for (c in list) {
      k = split(calls[c], names, " ")
      for (j = 1; j <= k; j++) if (!(names[j] in reach)) { reach[names[j]] = 1; changed = 1 }
    }
  }
  for (j = 1; j <= nuses; j++) {
    split(uses[j], use, " ")
    if (use[1] in reach) print use[2], use[3]
  }
}
AWK
)"
relative_uses() {
  awk -v rootre="$1" "$relative_awk"
}

# file_reads <file> <label>
# Adds to found what <file>, a self-test or a script it runs, reads that the
# fixture varies, each with <label> before it. It reads, through a variable
# of root_vars, a varied file, a directory or glob that holds one, or the
# repository as a whole ("$source_root" passed on, as to
# template_repository, or changed into); or, a self-test only, it calls a
# helper of varied-helpers. The shared parts it sources through such a
# variable (tests/lib-<y>.sh, scripts/lib/<y>.sh) count as the file, with
# its variables. A script of the repository that it runs through such a
# variable ("$source_root/scripts/check-risk.sh", directly, after an
# interpreter or an assignment, or as the value of a variable) counts with
# what it reads, as if it ran in the repository itself. So does a relative
# path that it reads or runs while its working directory is still the root
# (relative_uses): a self-test starts there.
file_reads() {
  local file="$1"
  local label="$2"
  local text
  local var
  local dir
  local ref
  local path
  local helper
  local lib
  local libs
  local vars
  local kind
  local command_word='(^|[;&|(]|\$\(|(then|do|else|exec|bash|sh|env|command|time)[[:space:]]|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]|"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"[[:space:]])[[:space:]]*'

  [[ "$visited" != *" $file "* ]] || return 0
  visited+="$file "
  vars="$(root_vars "$file" | LC_ALL=C sort -u)"
  text="$(cat "$file")"
  libs=" "
  while :; do
    lib=""
    while IFS=' ' read -r var dir; do
      [[ -n "$var" ]] || continue
      while IFS= read -r path; do
        path="$(root_path "$dir" "$path")"
        if [[ "$path" != tests/lib-fakes.sh && "$libs" != *" $path "* && -f "$source_root/$path" ]]; then lib="$path"; break 2; fi
      done < <(sed -nE "s#^[[:space:]]*(source|\\.) \"\\\$\\{?$var\\}?\"?/([A-Za-z0-9_./-]+\\.sh)\"?[[:space:]]*\$#\\2#p" <<<"$text")
    done <<<"$vars"
    [[ -n "$lib" ]] || break
    libs+="$lib "
    text+=$'\n'"$(cat "$source_root/$lib")"
  done
  text="$(grep -Ev '^[[:space:]]*#|^[[:space:]]*(source|\.) "\$' <<<"$text" || true)"
  while IFS=' ' read -r var dir; do
    [[ -n "$var" ]] || continue
    while IFS= read -r ref; do
      if [[ "$ref" == "the repository" ]]; then
        path=""
      else
        path="$(root_path "$dir" "$ref")"
      fi
      if [[ -z "$path" ]]; then ref="the repository"; else ref="$path"; fi
      if varied_ref "$path" && [[ "$found" != *"; $label$ref;"* ]]; then found+="; $label$ref;"; fi
    done < <(
      grep -oE "\\\$\{?$var\}?\"?/[A-Za-z0-9_.*/-]*" <<<"$text" | sed -E 's#^[^/]*/##'
      grep -Eq "\"\\\$\{?$var\}?\"([^/]|\$)" <<<"$text" && printf '%s\n' "$([[ "$dir" == . ]] && echo "the repository" || echo .)"
    )
    while IFS= read -r path; do
      path="$(root_path "$dir" "$path")"
      [[ "$path" != tests/lib-fakes.sh && -f "$source_root/$path" ]] || continue
      file_reads "$source_root/$path" "$label$path: "
    done < <(
      {
        grep -oE "$command_word\"\\\$\{?$var\}?\"?/[A-Za-z0-9_./-]+\\.sh\"" <<<"$text"
        sed -nE "s#^[[:space:]]*(local )?([a-z_]+)=\"\\\$\{?$var\}?\"?/([A-Za-z0-9_./-]+\\.sh)\"[[:space:]]*\$#\\2 \\3#p" <<<"$text" |
          while IFS=' ' read -r name path; do
            if grep -Eq "$command_word\"\\\$\{?$name\}?\"([^/]|\$)" <<<"$text"; then printf '%s\n' "$path"; fi
          done
      } | sed -E "s#.*\\\$\{?$var\}?\"?/##; s#\"\$##" | LC_ALL=C sort -u
    )
  done <<<"$vars"
  while IFS=' ' read -r kind ref; do
    [[ -n "$kind" ]] || continue
    path="$(root_path . "$ref")"
    if [[ -z "$path" ]]; then ref="the repository"; else ref="$path"; fi
    if varied_ref "$path" && [[ "$found" != *"; $label$ref;"* ]]; then found+="; $label$ref;"; fi
    if [[ "$kind" == run && "$path" != tests/lib-fakes.sh && -f "$source_root/$path" ]]; then
      file_reads "$source_root/$path" "$label$path: "
    fi
  done < <(relative_uses "^[\$][{]?($(awk '$2 == "." { print $1 }' <<<"$vars" | paste -sd '|' -)|/)[}]?\$" <<<"$text")
  if [[ -z "$label" ]]; then
    while IFS= read -r helper; do
      if grep -Eq "(^|[^a-z0-9_])$helper([^a-z0-9_]|\$)" <<<"$text"; then found+="; $helper;"; fi
    done <"$tmp/varied-helpers"
  fi
}

# fixture_reads <test file>
# Prints what the self-test reads that the fixture varies (file_reads),
# nothing when it reads nothing of it.
fixture_reads() {
  local found=""
  local visited=" "

  file_reads "$1" ""
  found="${found//;; /, }"
  found="${found#; }"
  printf '%s' "${found%;}"
}

# The self-tests: '<name>\t<command>\t<framework>'.
sed -nE 's/^([a-z0-9-]+)( \[[^]]*\])?( partition [^: ]+)?( budget)?( framework)?: (.*)$/\1\t\6\t\5/p' "$project/scripts/verify-workflow.conf" |
  grep -Ev '^(paths|budget-seconds)\b' | grep -Fv -e "$self" -e "$self_list" >"$tmp/all-checks" || true
[[ "$(wc -l <"$tmp/all-checks")" -gt 1 ]] || fail "no self-tests found in scripts/verify-workflow.conf"

# The list agrees with the self-tests: each entry a self-test that is not
# framework-only, once, with what it reads; each self-test that reads a
# varied file on it.
errors=()
listed=" "
for entry in "${fixture_tests[@]}"; do
  [[ "$entry" =~ ^([a-z0-9-]+):\ +[^[:space:]] ]] || {
    errors+=("the entry '$entry' of fixture_tests does not say what the self-test reads")
    continue
  }
  name="${BASH_REMATCH[1]}"
  [[ "$listed" != *" $name "* ]] || errors+=("$name is listed twice in fixture_tests")
  listed+="$name "
  line="$(awk -F '\t' -v name="$name" '$1 == name' "$tmp/all-checks")"
  if [[ -z "$line" ]]; then
    errors+=("$name of fixture_tests is not a self-test of scripts/verify-workflow.conf")
  elif [[ "$line" == *$'\t'*framework ]]; then
    errors+=("$name of fixture_tests is framework-only: a project never runs it")
  fi
done
while IFS=$'\t' read -r name command framework; do
  [[ -z "$framework" ]] || continue
  [[ "$command" =~ ^\./(tests/[a-z0-9-]+-test\.sh)([[:space:]]|$) ]] || continue
  reads="$(fixture_reads "$source_root/${BASH_REMATCH[1]}")"
  if [[ -n "$reads" && "$listed" != *" $name "* ]]; then
    errors+=("$name reads what the fixture varies ($reads) and is not in fixture_tests of $self")
  fi
done <"$tmp/all-checks"
if [[ "${#errors[@]}" -gt 0 ]]; then
  printf 'adopted project test: %s\n' "${errors[@]}" >&2
  fail "the list of self-tests of the fixture does not agree with what they read"
fi
if [[ "$mode" == check ]]; then
  echo "adopted project list agrees with the self-tests (${#fixture_tests[@]} listed)"
  exit 0
fi

# The self-tests to run, from the fixture as ./scripts/verify.sh runs them,
# ADOPTED_PROJECT_JOBS at a time, in the order of
# scripts/verify-workflow.conf. --all runs every one, the framework-only ones
# too, as the template does; otherwise those of the list, each named with
# what it reads.
jobs="${ADOPTED_PROJECT_JOBS:-4}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "ADOPTED_PROJECT_JOBS is not a positive number: $jobs"
mkdir -p "$tmp/out"
if [[ "$mode" == all ]]; then
  cut -f 1,2 "$tmp/all-checks" >"$tmp/checks"
  echo "adopted project: the full form, every self-test ($(wc -l <"$tmp/checks"))"
else
  : >"$tmp/checks"
  while IFS=$'\t' read -r name command framework; do
    [[ "$listed" == *" $name "* ]] && printf '%s\t%s\n' "$name" "$command" >>"$tmp/checks"
  done <"$tmp/all-checks"
  echo "adopted project: the self-tests that read what the fixture varies ($self --all runs every one):"
  printf '  %s\n' "${fixture_tests[@]}"
fi
export project tmp
tr '\n' '\0' <"$tmp/checks" | xargs -0 -P "$jobs" -I{} bash -c '
  name="${1%%$'"'"'\t'"'"'*}"
  command="${1#*$'"'"'\t'"'"'}"
  if (cd "$project" && bash -eo pipefail -c "$command") >"$tmp/out/$name" 2>&1 </dev/null; then
    rm "$tmp/out/$name"
  fi
' _ {}
failed=()
for output in "$tmp/out"/*; do
  [[ -e "$output" ]] || continue
  failed+=("$(basename "$output")")
  echo "--- $(basename "$output") in the fixture adopted project:" >&2
  tail -n 40 "$output" >&2
done
[[ "${#failed[@]}" -eq 0 ]] || fail "self-tests failed in an adopted project: ${failed[*]}"
[[ -z "$(git -C "$project" status --porcelain)" ]] || fail "the self-tests changed the fixture project: $(git -C "$project" status --porcelain)"

echo "adopted project tests passed ($(wc -l <"$tmp/checks") self-tests)"
