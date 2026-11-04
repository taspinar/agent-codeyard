#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 <path> [--agent <agent>] [--model <model>] [--facts-only]"
  echo
  echo "Assesses an existing repository for the adoption of this workflow, before"
  echo "anything changes. Run it from a clone of the template, with the path of the"
  echo "repository to assess."
  echo
  echo "The script only reads: it runs none of the project's code, tests, or"
  echo "installers, opens no file that may hold a secret (.env, keys, credentials),"
  echo "and writes nothing in the assessed repository. It gathers the facts (layout,"
  echo "entry points, stack, declared commands, CI, deployment files, documents,"
  echo "files that collide with the template's, and the working-tree state), and a"
  echo "read-only agent (role 'assessor' in .agents/agents.conf) writes a report that"
  echo "keeps facts, assumptions, and questions apart, with a proposal for the"
  echo "adoption."
  echo
  echo "The output is kept in .agents/assessments/<repo>-<time>/ of the primary"
  echo "checkout of the template, which Git ignores: facts.json, report.md, and"
  echo "proposal.json. Every run makes a new one. --facts-only writes facts.json and"
  echo "stops, without an agent."
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/lib/agent.sh"
source "$script_dir/lib/records.sh"
command -v jq >/dev/null 2>&1 || fail "jq is required."

agent_parse_args "$@"
set -- ${AGENT_POSITIONAL[@]+"${AGENT_POSITIONAL[@]}"}
target=""
facts_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --facts-only) facts_only=1 ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [[ -z "$target" ]] || usage
      target="$1"
      ;;
  esac
  shift
done
[[ -n "$target" ]] || usage
[[ -d "$target" ]] || fail "$target is not a directory."
target="$(cd "$target" && pwd -P)"

primary="$(records_primary)" || primary=""
[[ -n "$primary" ]] || fail "run this script from a clone of the template."
root="$(git rev-parse --show-toplevel)"
# The output is written in the template checkout, so it must not be inside
# the assessed repository.
case "$primary/" in
  "$target"/*) fail "$target holds the template checkout; the assessment would write into it." ;;
esac
git -C "$primary" check-ignore -q ".agents/assessments/x" ||
  fail "Git does not ignore .agents/assessments/ in $primary, so an assessment would be committed."
if [[ "$facts_only" -eq 0 ]]; then
  agent_resolve "$root" assessor "$AGENT_CLI_PROVIDER" "$AGENT_CLI_MODEL"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/assess-repository.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# --------------------------------------------------- reading the repository
# Git in the assessed repository only reads: no optional locks, so the index
# is not refreshed; no file system monitor and no filter driver, which would
# run commands of the repository's configuration. Variables of a calling Git
# would point it elsewhere.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
is_git=0
git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
  [[ "$(cd "$(git -C "$target" rev-parse --show-toplevel)" && pwd -P)" == "$target" ]] && is_git=1
target_git_options=(-c core.fsmonitor=false -c core.untrackedCache=false)
if [[ "$is_git" -eq 1 ]]; then
  while IFS= read -r driver; do
    [[ -n "$driver" ]] && target_git_options+=(-c "filter.$driver.clean=" -c "filter.$driver.smudge=" -c "filter.$driver.process=")
  done < <(git -C "$target" config --name-only --get-regexp '^filter\.' 2>/dev/null | sed -n 's/^filter\.\(.*\)\.[^.]*$/\1/p' | sort -u)
fi
tgit() {
  git --no-optional-locks -C "$target" "${target_git_options[@]}" "$@"
}

# target_state: what must be the same after the assessment.
target_state() {
  [[ "$is_git" -eq 1 ]] || return 0
  tgit rev-parse HEAD 2>/dev/null || true
  tgit symbolic-ref -q HEAD 2>/dev/null || true
  tgit status --porcelain=v1 --untracked-files=all 2>/dev/null || true
}
state_before="$(target_state)"

# The directories that are never searched: dependencies and build output.
pruned='^(.*/)?(\.git|node_modules|vendor|\.venv|venv|__pycache__|dist|build|target|\.next|\.terraform)/'

# The files of the repository, without the ignored ones; a name with a line
# break is left out.
if [[ "$is_git" -eq 1 ]]; then
  tgit ls-files -z --cached --others --exclude-standard | while IFS= read -r -d '' file; do
    [[ "$file" == *$'\n'* ]] || printf '%s\n' "$file"
  done | grep -Ev "$pruned" >"$work/files" || true
else
  (cd "$target" && find . -name .git -prune -o \( -type f -o -type l \) -print) | sed 's#^\./##' | grep -Ev "$pruned" >"$work/files" || true
fi
jq -R . "$work/files" | jq -s . >"$work/files.json"

# readable <path>: a regular file of the repository, no link, that is not too
# large to read.
readable() {
  [[ -f "$target/$1" && ! -L "$target/$1" ]] || return 1
  [[ "$(wc -c <"$target/$1")" -le 1048576 ]]
}

# Files that may hold a secret are named, never opened, also when Git
# ignores them.
(cd "$target" && find . -maxdepth 4 \( -name .git -o -name node_modules -o -name vendor -o -name .venv -o -name venv \) -prune -o \
  \( -type f -o -type l \) \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
  -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'credentials*.json' -o -name 'service-account*.json' -o -name 'secrets.*' \
  -o -name '.npmrc' -o -name '.pypirc' -o -name '.netrc' \) -print) | sed 's#^\./##' | sort >"$work/secret-files" || true
jq -R . "$work/secret-files" | jq -s --slurpfile files "$work/files.json" \
  'map({id: "secret-file:\(.)", path: ., tracked_or_unignored: (. as $p | any($files[0][]; . == $p)), contents_read: false})' \
  >"$work/secrets.json"
is_secret() {
  grep -Fxq -- "$1" "$work/secret-files"
}

# Text from the repository that goes into the facts: what looks like a key
# or a token, and the value of a variable whose name says it is a secret, is
# replaced.
redact_jq="$RECORDS_REDACT_JQ"'
def redact_text: redact
  | gsub("(?<name>[A-Za-z_]*(TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|PRIVATE_KEY|CREDENTIAL|AUTH)[A-Za-z0-9_]*)(?<sep>[=:][ ]?)(?<value>\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|[^\\s\"'"'"']+)"; "\(.name)\(.sep)[value omitted]"; "i")
  | gsub("(?<scheme>Bearer|Basic|token) (?<value>[A-Za-z0-9._~+/=-]{8,})"; "\(.scheme) [value omitted]"; "i")
  | gsub("//[^/@\\s]+@"; "//[credentials omitted]@");'

# Manifests and lock files, by name, at most three directories deep.
jq '
  def depth: split("/") | length;
  {"package.json": ["JavaScript/TypeScript", "npm"], "pyproject.toml": ["Python", "pyproject"], "requirements.txt": ["Python", "pip"],
   "setup.py": ["Python", "setuptools"], "setup.cfg": ["Python", "setuptools"], "Pipfile": ["Python", "pipenv"],
   "go.mod": ["Go", "go modules"], "Cargo.toml": ["Rust", "cargo"], "Gemfile": ["Ruby", "bundler"], "pom.xml": ["Java", "maven"],
   "build.gradle": ["Java/Kotlin", "gradle"], "build.gradle.kts": ["Java/Kotlin", "gradle"], "composer.json": ["PHP", "composer"],
   "mix.exs": ["Elixir", "mix"], "deno.json": ["JavaScript/TypeScript", "deno"], "Package.swift": ["Swift", "swift package manager"],
   "pubspec.yaml": ["Dart", "pub"]} as $manifests
  | {"package-lock.json": "npm", "yarn.lock": "yarn", "pnpm-lock.yaml": "pnpm", "bun.lockb": "bun", "poetry.lock": "poetry",
     "uv.lock": "uv", "Pipfile.lock": "pipenv", "Cargo.lock": "cargo", "go.sum": "go modules", "Gemfile.lock": "bundler",
     "composer.lock": "composer"} as $locks
  | map(select(depth <= 3)) as $files
  | {manifests: [$files[] | (split("/") | last) as $name | select($manifests[$name])
       | {id: "manifest:\(.)", path: ., language: $manifests[$name][0], package_manager: $manifests[$name][1]}],
     lockfiles: [$files[] | (split("/") | last) as $name | select($locks[$name])
       | {id: "lockfile:\(.)", path: ., package_manager: $locks[$name]}]}' "$work/files.json" >"$work/stack.json"

# The commands the project declares: the scripts of package.json, the
# targets of a Makefile, the run steps of its CI; and those its tools run by
# convention, which are assumptions until the owner confirms them.
: >"$work/commands.jsonl"
# command <origin> <source> <directory> <command> <definition>
command_fact() {
  jq -cn --arg origin "$1" --arg source "$2" --arg directory "$3" --arg command "$4" --arg definition "$5" \
    "$redact_jq"'{origin: $origin, source: $source, directory: (if $directory == "" or $directory == "." then null else $directory end),
      command: ($command | redact_text), definition: (if $definition == "" then null else ($definition | redact_text) end)}' >>"$work/commands.jsonl"
}
dir_of() {
  [[ "$1" == */* ]] && printf '%s' "${1%/*}" || printf '.'
}
# beside <directory> <name>: whether the repository has the file <name> in
# <directory>.
beside() {
  if [[ "$1" == "." ]]; then grep -Fxq -- "$2" "$work/files"; else grep -Fxq -- "$1/$2" "$work/files"; fi
}
while IFS= read -r path; do
  readable "$path" || continue
  dir="$(dir_of "$path")"
  case "${path##*/}" in
    package.json)
      runner="npm run"
      if beside "$dir" yarn.lock; then runner="yarn"; elif beside "$dir" pnpm-lock.yaml; then runner="pnpm run"; elif beside "$dir" bun.lockb; then runner="bun run"; fi
      jq -r '.scripts // {} | to_entries[] | select(.value | type == "string") | [.key, .value] | @tsv' "$target/$path" 2>/dev/null |
        while IFS=$'\t' read -r name definition; do
          command_fact declared "$path" "$dir" "$runner $name" "$definition"
        done
      ;;
    Makefile | makefile | GNUmakefile)
      awk '/^[A-Za-z0-9][A-Za-z0-9_.-]*:([^=]|$)/ { sub(/:.*/, ""); print }' "$target/$path" | awk '!seen[$0]++' |
        while IFS= read -r name; do
          command_fact declared "$path" "$dir" "make $name" ""
        done
      ;;
    go.mod) command_fact convention "$path" "$dir" "go test ./..." "" ;;
    Cargo.toml) command_fact convention "$path" "$dir" "cargo test" "" ;;
    pom.xml) command_fact convention "$path" "$dir" "mvn test" "" ;;
    build.gradle | build.gradle.kts)
      if beside "$dir" gradlew; then
        command_fact convention "$path" "$dir" "./gradlew test" ""
      else
        command_fact convention "$path" "$dir" "gradle test" ""
      fi
      ;;
    pytest.ini) command_fact convention "$path" "$dir" "pytest" "" ;;
    tox.ini) command_fact convention "$path" "$dir" "tox" "" ;;
    pyproject.toml | setup.cfg)
      grep -Eq '^\[tool(\.|:)pytest' "$target/$path" && command_fact convention "$path" "$dir" "pytest" ""
      ;;
  esac
done < <(awk -F/ 'NF <= 3' "$work/files" | grep -E '(^|/)(package\.json|Makefile|makefile|GNUmakefile|go\.mod|Cargo\.toml|pom\.xml|build\.gradle(\.kts)?|pytest\.ini|tox\.ini|pyproject\.toml|setup\.cfg)$' | sort)

# The CI: the run steps, the secrets it refers to by name, and the actions it
# uses, of GitHub Actions; other CI systems by their file only. The workflow
# passes through without_env first, the only step that reads the file. It
# reads every line, as a filter must, but of an env: block it writes only the
# secrets referred to by name: no value is written to a file of the
# assessment, so no later step, the assessor, or the report sees one.
without_env() {
  awk '
    function indent(s) { match(s, /^[ ]*(- )?/); return RLENGTH }
    function refs(s, pad) {
      while (match(s, /secrets\.[A-Za-z_][A-Za-z0-9_]*/)) { print pad substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH) }
    }
    inenv {
      if ($0 ~ /^[ ]*$/) next
      if (indent($0) > base) { match($0, /^[ ]*/); refs($0, substr($0, 1, RLENGTH)); next }
      inenv = 0
    }
    /^[ ]*(- )?env:/ {
      base = indent($0); match($0, /^[ ]*(- )?env:/); head = substr($0, 1, RLENGTH)
      print head; refs(substr($0, RLENGTH + 1), sprintf("%" (base + 2) "s", "")); inenv = 1; next
    }
    { print }' "$1"
}
: >"$work/ci.jsonl"
while IFS= read -r path; do
  if [[ "$path" != .github/workflows/* ]]; then
    jq -cn --arg path "$path" '{id: "ci:\($path)", path: $path, system: (
      if $path == ".gitlab-ci.yml" then "gitlab" elif ($path | startswith(".circleci/")) then "circleci"
      elif $path == "Jenkinsfile" then "jenkins" elif $path == "azure-pipelines.yml" then "azure"
      elif $path == ".travis.yml" then "travis" else "bitbucket" end),
      parsed: false, secret_references: [], actions: []}' >>"$work/ci.jsonl"
    continue
  fi
  readable "$path" || continue
  without_env "$target/$path" >"$work/workflow"
  awk '
    function indent(s) { match(s, /^[ ]*(- )?/); return RLENGTH }
    block {
      if ($0 ~ /^[ ]*$/) { text = text "\n"; next }
      if (indent($0) > base) { line = $0; sub(/^[ ]+/, "", line); text = text (text == "" ? "" : "\n") line; next }
      sub(/\n+$/, "", text); printf "%s%c", text, 0; block = 0
    }
    /^[ ]*(- )?run:[ ]*/ {
      base = indent($0); value = $0; sub(/^[ ]*(- )?run:[ ]*/, "", value)
      if (value ~ /^[|>][-+0-9]*[ ]*$/) { block = 1; text = ""; next }
      if (value ~ /^".*"$/ || value ~ /^'"'"'.*'"'"'$/) value = substr(value, 2, length(value) - 2)
      printf "%s%c", value, 0
    }
    END { if (block) { sub(/\n+$/, "", text); printf "%s%c", text, 0 } }' "$work/workflow" |
    while IFS= read -r -d '' run; do
      [[ -n "$run" ]] && command_fact ci "$path" "" "$run" ""
    done
  jq -cn --arg path "$path" \
    --argjson secrets "$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$work/workflow" | sed 's/^secrets\.//' | sort -u | jq -R . | jq -sc .)" \
    --argjson actions "$(sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*uses:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"' #]*\).*/\1/p' "$work/workflow" | sort -u | jq -R . | jq -sc .)" \
    '{id: "ci:\($path)", path: $path, system: "github-actions", parsed: true, secret_references: $secrets, actions: $actions}' >>"$work/ci.jsonl"
done < <(grep -E '^(\.github/workflows/[^/]+\.ya?ml|\.gitlab-ci\.yml|\.circleci/config\.ya?ml|Jenkinsfile|azure-pipelines\.yml|\.travis\.yml|bitbucket-pipelines\.yml)$' "$work/files" | sort)
jq -s 'to_entries | map(.value + {id: "command:\(.key + 1)"})' "$work/commands.jsonl" >"$work/commands.json"
jq -s . "$work/ci.jsonl" >"$work/ci.json"

# Deployment configuration, by its files only.
jq '[.[] | . as $p | (split("/") | last) as $name
  | (if $name | test("^(Dockerfile|Containerfile)(\\..*)?$|\\.Dockerfile$") then "container"
     elif $name | test("^(docker-)?compose(\\..*)?\\.ya?ml$") then "compose"
     elif $name == "Procfile" then "procfile" elif $name == "fly.toml" then "fly" elif $name == "vercel.json" then "vercel"
     elif $name == "netlify.toml" then "netlify" elif $name == "render.yaml" then "render" elif $name == "wrangler.toml" then "cloudflare"
     elif $name == "firebase.json" then "firebase" elif $name | test("^app\\.ya?ml$") then "app-engine"
     elif $name | test("^serverless\\.ya?ml$") then "serverless" elif $name | test("\\.tf$") then "terraform"
     elif $name == "Pulumi.yaml" then "pulumi" elif $name == "cdk.json" then "cdk" elif $name == "Chart.yaml" then "helm"
     elif $p | test("(^|/)(k8s|kubernetes)/.*\\.ya?ml$") then "kubernetes"
     elif $p | test("^\\.github/workflows/[^/]*deploy[^/]*\\.ya?ml$"; "i") then "ci-deploy"
     else empty end) as $kind
  | {id: "deploy:\($p)", path: $p, kind: $kind, contents_read: false}]' "$work/files.json" >"$work/deployment.json"

# Documents: requirements, architecture, decisions, instructions for agents,
# and the rest, with their first heading.
: >"$work/documents.jsonl"
while IFS= read -r path; do
  is_secret "$path" && continue
  title=""
  if readable "$path"; then
    title="$(head -n 20 "$target/$path" | sed -n 's/^#[[:space:]]\{1,\}//p' | head -n 1 | cut -c1-120)"
  fi
  jq -cn --arg path "$path" --arg title "$title" "$redact_jq"'
    ($path | ascii_downcase) as $p
    | {id: "document:\($path)", path: $path, title: (if $title == "" then null else ($title | redact_text) end),
       kind: (if $p | test("(^|/)(adrs?|decisions?)/") or ($p | test("(^|/)adr-[^/]*$")) then "decision"
              elif $p | test("(^|/)(agents|claude)\\.md$|^\\.cursor/|^\\.github/copilot-instructions\\.md$") then "agent-instructions"
              elif $p | test("requirement|spec|prd") then "requirements"
              elif $p | test("architecture|design") then "architecture"
              elif $p | test("(^|/)readme[^/]*$") then "readme"
              else "other" end)}' >>"$work/documents.jsonl"
done < <(grep -Ei '^(readme[^/]*|agents\.md|claude\.md|contributing[^/]*|changelog[^/]*|architecture[^/]*|\.github/copilot-instructions\.md|\.cursor/.*|(docs?|documentation|adrs?|decisions)/.*\.(md|mdx|rst|txt|adoc))$|(^|/)(adrs?|decisions)/[^/]*\.md$' "$work/files" | sort | head -n 200)
jq -s . "$work/documents.jsonl" >"$work/documents.json"

# Entry points: what the manifests name, and the files that are one by
# convention.
: >"$work/entries.jsonl"
while IFS= read -r path; do
  readable "$path" || continue
  case "${path##*/}" in
    package.json)
      jq -c --arg source "$path" '[(.main // empty | {kind: "main", target: .}), (.module // empty | {kind: "module", target: .}),
        (.bin // empty | if type == "string" then {kind: "bin", target: .} else to_entries[] | {kind: "bin \(.key)", target: .value} end)]
        | .[] | select(.target | type == "string") | . + {source: $source}' "$target/$path" 2>/dev/null >>"$work/entries.jsonl" || true
      ;;
    pyproject.toml)
      awk '/^\[/ { section = ($0 ~ /^\[(project\.scripts|tool\.poetry\.scripts)\]/) ; next }
        section && /^[A-Za-z0-9_.-]+[ ]*=/ { name = $0; sub(/[ ]*=.*/, "", name); value = $0; sub(/^[^=]*=[ ]*/, "", value); gsub(/"/, "", value); print name "\t" value }' "$target/$path" |
        while IFS=$'\t' read -r name value; do
          jq -cn --arg source "$path" --arg kind "script $name" --arg target "$value" '{kind: $kind, target: $target, source: $source}' >>"$work/entries.jsonl"
        done
      ;;
  esac
done < <(awk -F/ 'NF <= 3' "$work/files" | grep -E '(^|/)(package\.json|pyproject\.toml)$' | sort)
grep -E '^((cmd/[^/]+/)?main\.go|src/(main|lib)\.rs|src/bin/[^/]+\.rs|(src/)?(manage|app|main|wsgi|asgi|__main__)\.py|[^/]+/__main__\.py|(src/)?(index|server|main|app)\.(js|mjs|ts|tsx)|Program\.cs)$' "$work/files" |
  while IFS= read -r path; do
    jq -cn --arg path "$path" '{kind: "file", target: $path, source: $path}' >>"$work/entries.jsonl"
  done || true
jq -s 'unique_by([.source, .kind, .target]) | map(. + {id: "entry:\(.source)#\(.kind)"})' "$work/entries.jsonl" >"$work/entries.json"

# Git: the branch, the commit, the uncommitted changes, and the remotes,
# without the credentials of a remote URL.
if [[ "$is_git" -eq 1 ]]; then
  branch="$(tgit symbolic-ref -q --short HEAD 2>/dev/null || true)"
  head="$(tgit rev-parse -q --verify HEAD 2>/dev/null || true)"
  tgit status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c1-2,4- | jq -R '{status: .[0:2], path: .[2:]}' | jq -s . >"$work/changes.json"
  tgit remote -v 2>/dev/null | awk '$3 == "(fetch)" { print $1 "\t" $2 }' |
    jq -R "$redact_jq"'split("\t") | {name: .[0], url: (.[1] | redact_text)}' | jq -s . >"$work/remotes.json"
  jq -n --arg branch "$branch" --arg head "$head" --slurpfile changes "$work/changes.json" --slurpfile remotes "$work/remotes.json" \
    '{id: "git", repository: true, branch: (if $branch == "" then null else $branch end), detached: ($branch == ""),
      head: (if $head == "" then null else $head end), uncommitted_changes: $changes[0], remotes: $remotes[0]}' >"$work/git.json"
else
  echo '[]' >"$work/changes.json"
  jq -n '{id: "git", repository: false, branch: null, detached: false, head: null, uncommitted_changes: [], remotes: []}' >"$work/git.json"
fi

# ------------------------------------------------------- against the template
# The files an adoption would bring, which of them the template owns
# (.agents/template.conf, paths:) and which become the project's own, and
# which already exist in the repository. The template's product files stay
# behind: its README and licence, its site, its own approvals, and
# the placeholders of a new project's code.
not_carried='^(documentation/|\.github/workflows/pages\.yml$|README\.md$|LICENSE$|CONTRIBUTING\.md$|SECURITY\.md$|\.agents/approval-requests/|src/\.gitkeep$|infra/\.gitkeep$)'
template_paths=()
read -r -a template_paths <<<"$(sed -n 's/^paths:[[:space:]]*//p' "$root/.agents/template.conf" 2>/dev/null | head -n 1)" || true
git -C "$root" ls-files | grep -Ev "$not_carried" | sort >"$work/template-files" || true
if [[ ${#template_paths[@]} -gt 0 ]]; then
  git -C "$root" ls-files -- "${template_paths[@]}" | sort >"$work/template-owned" || true
else
  : >"$work/template-owned"
fi
template_repository="$(sed -n 's/^repository:[[:space:]]*//p' "$root/.agents/template.conf" 2>/dev/null | head -n 1)"
template_commit="$(git -C "$root" rev-parse HEAD)"
if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then template_dirty=true; else template_dirty=false; fi

: >"$work/adoption.jsonl"
while IFS= read -r path; do
  ownership=project
  grep -Fxq -- "$path" "$work/template-owned" && ownership=template
  kind=""
  if [[ -L "$target/$path" ]]; then
    kind=symlink
  elif [[ -d "$target/$path" ]]; then
    kind=directory
  elif [[ -e "$target/$path" ]]; then
    kind=file
  else
    # A file or a link where the template has a directory.
    prefix="$path"
    while [[ "$prefix" == */* ]]; do
      prefix="${prefix%/*}"
      if [[ -L "$target/$prefix" || (-e "$target/$prefix" && ! -d "$target/$prefix") ]]; then
        kind="file-in-the-way:$prefix"
        break
      fi
    done
  fi
  jq -cn --arg path "$path" --arg ownership "$ownership" --arg kind "$kind" '{path: $path, ownership: $ownership, kind: $kind}' >>"$work/adoption.jsonl"
done <"$work/template-files"
for dir in .agents .github docs scripts tests; do
  [[ -d "$target/$dir" && ! -L "$target/$dir" ]] || continue
  jq -cn --arg path "$dir" --argjson files "$(awk -v prefix="$dir/" 'index($0, prefix) == 1' "$work/files" | wc -l | tr -d ' ')" '{shared: true, path: $path, files: $files}' >>"$work/adoption.jsonl"
done

jq -s --slurpfile changes "$work/changes.json" '
  ($changes[0] | map(.path)) as $changed
  | {additions: map(select(.shared | not) | select(.kind == "") | {path, ownership}),
     collisions: map(select(.shared | not) | select(.kind != "")
       | {id: "collision:\(.path)", path, ownership,
          kind: (if .kind | startswith("file-in-the-way:") then "file-in-the-way" else .kind end),
          blocking_path: (if .kind | startswith("file-in-the-way:") then .kind[16:] else null end),
          uncommitted: (.path as $p | $changed | any(. == $p or startswith($p + "/")))}),
     shared_directories: map(select(.shared) | {id: "shared:\(.path)", path, files})}' "$work/adoption.jsonl" >"$work/adoption.json"

name="$(basename "$target" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')"
[[ -n "$name" ]] || name=repository
time="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
jq -n --arg name "$name" --arg path "$target" --arg time "$time" \
  --arg template_repository "$template_repository" --arg template_commit "$template_commit" --argjson template_dirty "$template_dirty" \
  --arg checkout "$root" --argjson template_paths "$(printf '%s\n' ${template_paths[@]+"${template_paths[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')" \
  --argjson files "$(wc -l <"$work/files" | tr -d ' ')" \
  --slurpfile list "$work/files.json" --slurpfile git "$work/git.json" --slurpfile stack "$work/stack.json" \
  --slurpfile commands "$work/commands.json" --slurpfile ci "$work/ci.json" --slurpfile deployment "$work/deployment.json" \
  --slurpfile documents "$work/documents.json" --slurpfile secrets "$work/secrets.json" --slurpfile entries "$work/entries.json" \
  --slurpfile adoption "$work/adoption.json" '
  {schema: "assessment-facts/v1", assessed_at: $time,
   repository: {name: $name, path: $path},
   template: {repository: (if $template_repository == "" then null else $template_repository end), commit: $template_commit,
              uncommitted_changes: $template_dirty, checkout: $checkout},
   git: $git[0],
   layout: {id: "layout", files: $files,
            top_level: ($list[0] | group_by(split("/")[0])
              | map({name: (.[0] | split("/")[0]), type: (if (.[0] | contains("/")) then "directory" else "file" end), files: length}))},
   manifests: $stack[0].manifests, lockfiles: $stack[0].lockfiles, entry_points: $entries[0],
   commands: $commands[0], ci: $ci[0], deployment: $deployment[0], documents: $documents[0], secret_files: $secrets[0],
   adoption: ($adoption[0] + {template_paths: $template_paths,
     not_carried: ["documentation/", ".github/workflows/pages.yml", "README.md", "LICENSE", "CONTRIBUTING.md", "SECURITY.md",
                   ".agents/approval-requests/", "src/.gitkeep", "infra/.gitkeep"]})}
  | .evidence_ids = (["git", "layout"] + [(.manifests, .lockfiles, .entry_points, .commands, .ci, .deployment, .documents,
      .secret_files, .adoption.collisions, .adoption.shared_directories)[] | .id] | unique)' >"$work/facts.json"

# ------------------------------------------------------------ the output
mkdir -p "$primary/.agents/assessments"
stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
dir="$primary/.agents/assessments/$name-$stamp"
number=1
until mkdir "$dir" 2>/dev/null; do
  [[ -e "$dir" ]] || fail "could not create $dir."
  number=$((number + 1))
  dir="$primary/.agents/assessments/$name-$stamp-$number"
done
cp "$work/facts.json" "$dir/facts.json"
echo "Assessment facts: ${dir#"$primary"/}/facts.json"
jq -r '"  Repository: \(.repository.path)\(if .git.repository then ", branch \(.git.branch // "(detached)"), \(.git.uncommitted_changes | length) uncommitted changes" else ", not a Git repository" end)",
  "  Files: \(.layout.files); manifests: \(.manifests | length); commands: \(.commands | length); CI files: \(.ci | length); deployment files: \(.deployment | length)",
  "  Template: \(.adoption.additions | length) files to add, \(.adoption.collisions | length) collisions, \(.adoption.shared_directories | length) shared directories"' "$dir/facts.json"

check_unchanged() {
  [[ "$(target_state)" == "$state_before" ]] ||
    fail "the assessed repository changed during the assessment; compare it with its state before. Nothing of the assessment is kept beyond facts.json."
}
check_unchanged
[[ "$facts_only" -eq 0 ]] || exit 0

# ------------------------------------------------------------ the assessor
# assessment_errors <result> <facts>: what is wrong with the assessor's result.
assessment_errors() {
  jq -r --slurpfile facts "$2" '
    $facts[0] as $f | ($f.evidence_ids | map({key: ., value: true}) | from_entries) as $known
    | ($f.commands | map({key: .id, value: true}) | from_entries) as $commands
    | ($f.adoption.collisions | map(.path)) as $collisions
    | [ (if (.facts | type) != "array" or (.facts | length) == 0 then "the result states no observed fact" else empty end),
        (.facts[]? | . as $fact
          | (if (.evidence | length) == 0 then "the fact \"\($fact.statement)\" cites no evidence" else empty end),
            (.evidence[] | select($known[.] | not) | "the fact \"\($fact.statement)\" cites \(.), which is not in the facts")),
        (.assumptions[]? | select(.basis | test("\\S") | not) | "the assumption \"\(.statement)\" names no basis"),
        (.questions[]? | select(.why | test("\\S") | not) | "the question \"\(.question)\" does not say what it settles"),
        ((.collisions // []) | map(.path) as $resolved
          | ($collisions - $resolved | .[] | "the collision \(.) has no resolution"),
            ($resolved - $collisions | .[] | "a resolution names \(.), which is no collision"),
            ($resolved | group_by(.) | map(select(length > 1) | .[0]) | .[] | "the collision \(.) has more than one resolution")),
        (.collisions[]? | select(.rationale | test("\\S") | not) | "the resolution of \(.path) gives no rationale"),
        # The project'"'"'s instructions, scripts, and CI, and uncommitted work,
        # are its own until the owner resolves them.
        (.collisions[]? | select(.resolution == "take-template") | .path as $p
          | select(($p | test("^(AGENTS\\.md$|scripts/|\\.github/workflows/)")) or ($f.adoption.collisions | any(.path == $p and .uncommitted)))
          | "the collision \($p) cannot be resolved with take-template: it is the project'"'"'s content until the owner resolves it"),
        (.verification[]? | . as $v
          | (if $commands[$v.source] then empty else "the verification \($v.name) names \($v.source), which is no command of the facts" end),
            (if $v.name | test("^[a-z0-9-]+$") then empty else "the verification name \($v.name) is not lowercase letters, digits, and -" end)),
        ((.verification // []) | map(.name) | group_by(.) | map(select(length > 1) | .[0]) | .[] | "the verification name \(.) is used twice"),
        (if (.profile.rationale // "") | test("\\S") then empty else "the profile gives no rationale" end) ]
    | .[]' "$1" 2>/dev/null || echo "the result is not the expected JSON"
}

# The assessor gets the facts on standard input, without the path of the
# repository, and works in an empty directory: it cannot read the repository,
# so it cannot read a secret from it either.
jq 'del(.repository.path, .template.checkout)' "$dir/facts.json" >"$work/agent-facts.json"
mkdir "$work/empty"
prompt="$(cat "$root/.agents/prompts/assessor.md")

Standard input contains the assessment facts as JSON. Return JSON that matches the supplied schema."
schema="$root/.agents/schemas/assessment.schema.json"
attempt_prompt="$prompt"
for attempt in 1 2; do
  : >"$work/result.json"
  set +e
  agent_run read-only "$AGENT_PROVIDER" "$AGENT_MODEL" "$work/empty" "$attempt_prompt" "$work/result.json" "$work/agent-facts.json" "$schema"
  agent_status=$?
  set -e
  check_unchanged
  [[ "$agent_status" -eq 0 ]] || fail "the assessor failed with status $agent_status. The facts are in ${dir#"$primary"/}/facts.json."
  errors="$(assessment_errors "$work/result.json" "$dir/facts.json")"
  [[ -n "$errors" ]] || break
  if [[ "$attempt" -eq 2 ]]; then
    printf 'Error: the assessment is invalid; only its facts are kept:\n' >&2
    printf '%s\n' "$errors" | sed 's/^/  - /' >&2
    exit 1
  fi
  attempt_prompt="$prompt

Your previous result was invalid:
$errors
Return a corrected result."
done
# What looks like a key or a token is replaced in the assessor's text too.
jq "$RECORDS_REDACT_JQ"' redact_all' "$work/result.json" >"$work/result.redacted.json"

# The proposal: what the script determined, with the assessor's resolutions,
# profile, and commands. A collision of a file the template owns that stays
# the project's own becomes an exclusion of its ownership.
jq --slurpfile facts "$dir/facts.json" --arg assessment "$(basename "$dir")" '
  $facts[0] as $f | . as $r
  | ($r.collisions | map({key: .path, value: .}) | from_entries) as $resolution
  | ($f.commands | map({key: .id, value: .}) | from_entries) as $commands
  | {schema: "adoption-proposal/v1", status: "proposed, not approved", assessment: $assessment,
     repository: {name: $f.repository.name, path: $f.repository.path, branch: $f.git.branch, head: $f.git.head},
     template: {repository: $f.template.repository, commit: $f.template.commit, uncommitted_changes: $f.template.uncommitted_changes},
     additions: $f.adoption.additions,
     collisions: ($f.adoption.collisions | map(del(.id) + {resolution: $resolution[.path].resolution, rationale: $resolution[.path].rationale})),
     shared_directories: ($f.adoption.shared_directories | map(del(.id))),
     profile: $r.profile,
     verification: ($r.verification | map($commands[.source] as $c
       | {name, command: $c.command, directory: $c.directory, origin: $c.origin, source: $c.source, command_id: .source, rationale})),
     ownership: {template_paths: $f.adoption.template_paths,
       project_exclusions: [$f.adoption.collisions[] | select(.ownership == "template" and $resolution[.path].resolution == "keep-project") | ":(exclude)\(.path)"],
       template_owned: ([$f.adoption.additions[], $f.adoption.collisions[]] | map(select(.ownership == "template") | .path) | sort),
       project_owned: ([$f.adoption.additions[], $f.adoption.collisions[]] | map(select(.ownership == "project") | .path) | sort)},
     not_carried: $f.adoption.not_carried,
     execution_needed: $r.execution_needed}' "$work/result.redacted.json" >"$dir/proposal.json"

jq -r --slurpfile facts "$dir/facts.json" --slurpfile proposal "$dir/proposal.json" '
  def list(f): if length == 0 then "None.\n" else map(f) | join("") end;
  def code: "`\(.)`";
  $facts[0] as $f | $proposal[0] as $p |
  "# Assessment of \($f.repository.name)\n\n"
  + "Assessed \($f.assessed_at) against the template commit \($f.template.commit[0:12])\(if $f.template.uncommitted_changes then " (with uncommitted changes)" else "" end). "
  + "The assessment only read the repository: no project code, test, or installer ran, no file that may hold a secret was opened, and nothing in the repository changed.\n\n"
  + "> **Observed, not approved.** The observed facts below are what the files show. Everything else in this report, the assumptions, the reconstructed architecture, and the proposal, is an inference: it is no owner-approved requirement and no historical decision. The owner approves it through the planning approval of the adopted repository.\n\n"
  + "\(.summary)\n\n"
  + "## Observed facts\n\n" + (.facts | list("- \(.statement) (\(.evidence | map(code) | join(", ")))\n"))
  + "\n## Assumptions (observed, not approved)\n\n" + (.assumptions | list("- \(.statement)\n  - basis: \(.basis)\n"))
  + "\n## Questions for the owner\n\n" + (.questions | list("- \(.question)\n  - settles: \(.why)\n"))
  + "\n## Proposal\n\nThe proposal is in `proposal.json`, the input of the adoption. Status: \($p.status).\n\n"
  + "### Files to add\n\n\($p.additions | length) files: \($p.additions | map(select(.ownership == "template")) | length) owned by the template, \($p.additions | map(select(.ownership == "project")) | length) that become the project'"'"'s own.\n\n"
  + ($p.additions | list("- \(.path | code) (\(.ownership))\n"))
  + "\n### Collisions\n\n"
  + (if ($p.collisions | length) == 0 then "None.\n" else
      "| Path | Owner in the template | Kind | Uncommitted | Resolution | Rationale |\n|---|---|---|---|---|---|\n"
      + ($p.collisions | map("| \(.path | code) | \(.ownership) | \(.kind)\(if .blocking_path then " (\(.blocking_path | code))" else "" end) | \(if .uncommitted then "yes" else "no" end) | \(.resolution) | \(.rationale | gsub("\\|"; "\\|") | gsub("\n"; " ")) |\n") | join("")) end)
  + "\n### Shared directories\n\n" + ($p.shared_directories | list("- \(.path | code)/: \(.files) files of the project\n"))
  + "\n### Workflow profile\n\n`\($p.profile.name)`: \($p.profile.rationale)\n"
  + "\n### Verification commands\n\n" + ($p.verification | list("- \(.name): \(.command | code)\(if .directory then " in \(.directory | code)" else "" end), \(.origin) in \(.source | code). \(.rationale)\n"))
  + "\n### Template version\n\n\($p.template.repository // "(no repository recorded)") at \($p.template.commit | code)\(if $p.template.uncommitted_changes then ", with uncommitted changes in the template checkout" else "" end).\n"
  + "\n### Ownership for a later sync-template.sh\n\n"
  + "- Owned by the template (`paths:` of `.agents/template.conf`): \($p.ownership.template_paths | map(code) | join(" "))\n"
  + "- Exclusions for the files the project keeps: \(if ($p.ownership.project_exclusions | length) == 0 then "none" else ($p.ownership.project_exclusions | map(code) | join(" ")) end)\n"
  + "- Everything else is the project'"'"'s own, also the \($p.ownership.project_owned | length) starter files the adoption adds.\n"
  + "\n### Execution a later baseline needs\n\nNone of this ran.\n\n" + ($p.execution_needed | list("- \(.what)\n  - why: \(.why)\n  - side effects: \(.side_effects)\n"))
  + "\n### Not carried over\n\n" + ($p.not_carried | list("- \(code)\n"))' "$work/result.redacted.json" >"$dir/report.md"

echo
echo "Assessment: ${dir#"$primary"/}/report.md"
echo "Proposal:   ${dir#"$primary"/}/proposal.json"
jq -r '"  Profile: \(.profile.name); verification commands: \(.verification | length); collisions: \(.collisions | length)"' "$dir/proposal.json"
echo "Nothing was changed in $target."
