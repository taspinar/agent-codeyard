#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$source_root/tests/lib-fakes.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/update-feature-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "update-feature test failed: $*" >&2
  exit 1
}

# A fake GitHub CLI: it records every call and keeps the description of the
# pull request. MOCK_OPEN_PR is the URL of a pull request that is open.
mkdir -p "$tmp/bin"
ln -sf "$(command -v jq)" "$tmp/bin/jq"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "${MOCK_OPEN_PR:-}" ;;
  "pr create" | "pr edit")
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$MOCK_GH_LOG.body"; fi
    done
    [[ "$2" != "create" ]] || echo "https://github.com/example/project/pull/7"
    ;;
  "pr view")
    case "$*" in
      *isDraft*) echo "false" ;;
      *) echo "main" ;;
    esac
    ;;
  "api repos/{owner}/{repo}/rules/branches/main") echo "1" ;;
  "repo view") echo "main" ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

# Creates a clone on a finished feature branch of Issue 12, with a remote,
# and a second clone, '<repo>-other', in which the base moves on. Git ignores
# the build directory of the site, 'old-site/build/'. The finish commit
# states that the feature is complete, as finish-feature.sh writes it; with
# APPROVAL set it also carries an approval request and requires the owner.
setup_repo() {
  local label="$1"
  local remote="$tmp/$label-remote.git"
  local repo="$tmp/$label"

  git init -q --bare -b main "$remote"
  git clone -q "$remote" "$repo" 2>/dev/null
  copy_workflow "$repo"
  workflow_gitignore "$repo/.gitignore"
  printf 'old-site/build/\n' >>"$repo/.gitignore"
  printf 'sound: test ! -e broken.txt\n' >"$repo/scripts/verify.conf"
  mkdir -p "$repo/old-site"
  printf '# Site\n' >"$repo/old-site/index.md"
  git -C "$repo" config user.name "Update Test"
  git -C "$repo" config user.email "update-test@example.com"
  git -C "$repo" checkout -q -b main
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" push -q origin main
  git clone -q "$remote" "$repo-other" 2>/dev/null
  git -C "$repo-other" config user.name "Someone Else"
  git -C "$repo-other" config user.email "someone@example.com"

  git -C "$repo" checkout -q -b feature/12-marker
  printf 'marker\n' >"$repo/feature.txt"
  git -C "$repo" add feature.txt
  local approval=()
  if [[ -n "${APPROVAL:-}" ]]; then
    mkdir -p "$repo/.agents/approval-requests"
    jq -n --arg tree "$(content_tree_of "$repo")" '{schema: "approval-request/v1", content_tree: $tree,
      commit: {branch: "feature/12-marker", parent: null, base: null}, review: {round: 1, verdict: "PASS", reviewer: "claude (model-r)"},
      reasons: ["docs/decisions/001.md: an ADR is added, changed, or removed"], explanation: "Please approve the ADR."}' \
      >"$repo/.agents/approval-requests/12.json"
    git -C "$repo" add .agents/approval-requests/12.json
    approval=(-m "Merge approval:" -m "- required from the project owner, for exactly this commit")
  fi
  git -C "$repo" commit -qm "Add the marker" -m "Issue: #12" -m "Completion: complete
- met: The marker exists (feature.txt)" -m "Review: round 1, PASS, by claude (model-r)" ${approval[@]+"${approval[@]}"}
  mkdir -p "$repo/.agents/completion"
  jq -n '{schema: "completion/v1", status: "complete",
    criteria: [{criterion: "The marker exists", status: "met", evidence: "feature.txt"}], remaining: []}' \
    >"$repo/.agents/completion/12.json"
  # The build of the site, which Git ignores.
  mkdir -p "$repo/old-site/build/assets"
  printf 'built\n' >"$repo/old-site/build/assets/app.js"
  printf '%s\n' "$repo"
}

# content_tree_of <repo> [<commit>]: the content tree of a commit, or of the
# working tree, as lib/fingerprint.sh computes it.
content_tree_of() {
  (
    source "$source_root/scripts/lib/fingerprint.sh"
    if [[ $# -ge 2 ]]; then
      fingerprint_commit "$1" "$tmp" "$2"
    else
      git -C "$1" add -A
      fingerprint_worktree "$1" "$tmp"
    fi
  )
}

# move_base <repo> <message> <command>: a commit on the base, made in the
# other clone and pushed, as another merged pull request would.
move_base() {
  local other="$1-other"

  git -C "$other" pull -q origin main
  (cd "$other" && eval "$3")
  git -C "$other" add -A
  git -C "$other" commit -qm "$2"
  git -C "$other" push -q origin main
}

# run_update <repo> <argument...>: sets 'status'.
run_update() {
  local repo="$1"

  shift
  status=0
  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" PUBLISH_POLL_SECONDS=0 PUBLISH_START_ATTEMPTS=1 \
      ./scripts/update-feature.sh "$@"
  ) >"$repo.out" 2>&1 || status=$?
}

pushed_head() {
  git -C "$1" ls-remote origin refs/heads/feature/12-marker | cut -f1
}

expect_not_pushed() {
  [[ -z "$(pushed_head "$1")" ]] || fail "$(basename "$1"): the branch was pushed although $2"
  if grep -Eq "^pr (create|edit)" "$1.gh" 2>/dev/null; then fail "$(basename "$1"): the pull request was changed although $2"; fi
}

# A base that moved is merged, the merged content is verified, and the pull
# request is published again: it is still described by the finish commit and
# closes the Issue.
repo="$(setup_repo clean)"
finish="$(git -C "$repo" rev-parse HEAD)"
move_base "$repo" "Meanwhile on main" 'printf "meanwhile\n" >other.txt'
run_update "$repo" 12
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "updating a feature whose base moved failed ($status)"; }
[[ "$(git -C "$repo" rev-parse HEAD^1)" == "$finish" ]] || fail "the merge does not follow the finish commit"
[[ "$(git -C "$repo" rev-parse HEAD^2)" == "$(git -C "$repo" rev-parse origin/main)" ]] || fail "the base was not merged"
[[ -f "$repo/other.txt" ]] || fail "the change of the base is not in the worktree"
[[ "$(pushed_head "$repo")" == "$(git -C "$repo" rev-parse HEAD)" ]] || fail "the merged branch was not pushed"
grep -Fq "Verifying the merged content" "$repo.out" || fail "the merged content was not verified"
grep -Fq "PASS  sound" "$repo.out" || { cat "$repo.out" >&2; fail "the verification did not run its checks"; }
grep -Fq "Finish commit: $finish" "$repo.out" || fail "the publication does not name the finish commit"
grep -Fqx "Closes #12" "$repo.gh.body" || fail "the updated pull request does not close the Issue"
grep -Fq "pr create --base main --head feature/12-marker --title Add the marker" "$repo.gh" ||
  fail "the pull request is not titled after the finish commit"
# Run again, nothing is merged: the verification of the same content is
# reused, and the open pull request gets its description again.
head="$(git -C "$repo" rev-parse HEAD)"
: >"$repo.gh"
MOCK_OPEN_PR="https://github.com/example/project/pull/7" run_update "$repo" 12
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "updating an up-to-date feature failed ($status)"; }
[[ "$(git -C "$repo" rev-parse HEAD)" == "$head" ]] || fail "an up-to-date feature got another commit"
grep -Fq "already contains origin/main; nothing to merge" "$repo.out" || fail "an up-to-date branch was not reported"
grep -Fq "pr edit https://github.com/example/project/pull/7 --body-file" "$repo.gh" || fail "the open pull request was not updated"

# A merge of the base that conflicts with the feature stops before anything
# changed: the files and the commands that continue are named, and nothing
# is pushed.
repo="$(setup_repo conflict)"
finish="$(git -C "$repo" rev-parse HEAD)"
move_base "$repo" "Another marker" 'printf "another marker\n" >feature.txt'
run_update "$repo" 12
[[ "$status" -eq 1 ]] || { cat "$repo.out" >&2; fail "a conflicting merge did not stop ($status)"; }
grep -Fq "Merging origin/main conflicts with the feature in:" "$repo.out" || fail "the conflict was not reported"
grep -Fqx "  feature.txt" "$repo.out" || fail "the conflicting file was not named"
grep -Fq "git merge origin/main    # resolve the files above" "$repo.out" || fail "the command that continues was not given"
grep -Fq "./scripts/update-feature.sh 12" "$repo.out" || fail "the command to run again was not given"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$finish" ]] || fail "a conflicting merge changed the branch"
if git -C "$repo" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then fail "a conflicting merge was left in progress"; fi
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a conflicting merge changed the worktree"
expect_not_pushed "$repo" "the merge conflicts"
# Resolved by hand, the next run verifies and publishes.
git -C "$repo" merge -q --no-edit origin/main >/dev/null 2>&1 || true
printf 'marker\n' >"$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q --no-edit
run_update "$repo" 12
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "updating after a resolved conflict failed ($status)"; }
grep -Fqx "Closes #12" "$repo.gh.body" || fail "the feature with a resolved conflict does not close the Issue"

# A merge that is still in progress is completed by the human first.
repo="$(setup_repo in-progress)"
move_base "$repo" "Another marker" 'printf "another marker\n" >feature.txt'
git -C "$repo" fetch -q origin
git -C "$repo" merge -q --no-edit origin/main >/dev/null 2>&1 && fail "the test merge did not conflict"
run_update "$repo" 12
[[ "$status" -eq 1 ]] || fail "a merge in progress was not refused ($status)"
grep -Fq "a merge is in progress with conflicts in: feature.txt" "$repo.out" || { cat "$repo.out" >&2; fail "the merge in progress was not explained"; }
expect_not_pushed "$repo" "a merge is in progress"

# A base that adds a path that exists in the worktree as a file Git ignores
# stops before the merge: a merge that is not a fast-forward would replace the
# local file without a word, also with --no-overwrite-ignore.
repo="$(setup_repo ignored)"
finish="$(git -C "$repo" rev-parse HEAD)"
move_base "$repo" "Commit a build" \
  'mkdir -p old-site/build/assets && printf "from the base\n" >old-site/build/assets/app.js && git add -f old-site/build/assets/app.js'
run_update "$repo" 12
[[ "$status" -eq 1 ]] || { cat "$repo.out" >&2; fail "a merge that writes over an ignored file did not stop ($status)"; }
grep -Fq "would write over these untracked files" "$repo.out" || { cat "$repo.out" >&2; fail "the ignored file in the way was not reported"; }
grep -Fqx "  old-site/build/assets/app.js" "$repo.out" || fail "the ignored file in the way was not named"
grep -Fqx "built" "$repo/old-site/build/assets/app.js" || fail "the ignored local file was changed"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$finish" ]] || fail "a merge that writes over an ignored file changed the branch"
if git -C "$repo" rev-parse --verify --quiet MERGE_HEAD >/dev/null; then fail "a merge was left in progress"; fi
expect_not_pushed "$repo" "the merge writes over an ignored file"

# Staged changes stop before the merge, with the paths named and the index
# unchanged: a staged version that differs from the file on disk is kept.
repo="$(setup_repo staged)"
finish="$(git -C "$repo" rev-parse HEAD)"
move_base "$repo" "Meanwhile on main" 'printf "meanwhile\n" >other.txt'
printf 'staged\n' >"$repo/feature.txt"
git -C "$repo" add feature.txt
printf 'on disk\n' >"$repo/feature.txt"
index="$(git -C "$repo" write-tree)"
run_update "$repo" 12
[[ "$status" -eq 1 ]] || { cat "$repo.out" >&2; fail "staged changes did not stop the update ($status)"; }
grep -Fq "the index holds staged changes" "$repo.out" || { cat "$repo.out" >&2; fail "the staged changes were not reported"; }
grep -Fqx "  feature.txt" "$repo.out" || fail "the staged path was not named"
[[ "$(git -C "$repo" write-tree)" == "$index" ]] || fail "the index was changed"
[[ "$(git -C "$repo" show :feature.txt)" == "staged" ]] || fail "the staged version was lost"
grep -Fqx "on disk" "$repo/feature.txt" || fail "the file on disk was changed"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$finish" ]] || fail "staged changes did not keep the branch"
expect_not_pushed "$repo" "the index holds staged changes"

# After the update, a pull request with an approval request still shows the
# approval as covering the content of the finish commit: the merge of the
# base needs no new approval.
repo="$(APPROVAL=1 setup_repo approval)"
finish="$(git -C "$repo" rev-parse HEAD)"
tree="$(content_tree_of "$repo" "$finish")"
move_base "$repo" "Meanwhile on main" 'printf "meanwhile\n" >other.txt'
run_update "$repo" 12
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "updating a feature with an approval request failed ($status)"; }
[[ "$(git -C "$repo" rev-parse HEAD^1)" == "$finish" ]] || fail "the base was not merged after the finish commit"
grep -Fqx "The merge approval above was decided for commit \`$finish\`." "$repo.gh.body" ||
  { cat "$repo.gh.body" >&2; fail "the approval does not cover the finish commit after the update"; }
grep -Fq "Content tree of that commit: \`$tree\` (" "$repo.gh.body" || fail "the content tree is not that of the finish commit"
grep -Fq "The approval request \`.agents/approval-requests/12.json\` in that commit names this content tree" "$repo.gh.body" ||
  fail "the approval request of the finish commit is not named"
grep -Fqx -- "- required from the project owner, for exactly this commit" "$repo.gh.body" ||
  fail "the pull request does not show that the owner must approve"

# A directory that the branch ignored and the merged base no longer ignores,
# here the build of a site that the base renamed, is reported with its path
# and the command that removes it. Nothing is deleted, verified, or pushed.
repo="$(setup_repo leftover)"
move_base "$repo" "Rename the site" 'git mv old-site site && sed -i "s|^old-site/build/$|site/build/|" .gitignore'
run_update "$repo" 12
[[ "$status" -eq 1 ]] || { cat "$repo.out" >&2; fail "a leftover directory did not stop the update ($status)"; }
grep -Fq "Left behind by a merge of the base" "$repo.out" || fail "the leftover was not reported as left behind"
grep -Fq "old-site/    remove with: rm -rf -- old-site/" "$repo.out" || { cat "$repo.out" >&2; fail "the leftover was not named with its removal command"; }
if grep -Fq "there are uncommitted changes" "$repo.out"; then fail "the leftover was taken for uncommitted work"; fi
[[ -f "$repo/old-site/build/assets/app.js" ]] || fail "the leftover was deleted"
[[ "$(git -C "$repo" rev-parse HEAD^2 2>/dev/null)" == "$(git -C "$repo" rev-parse origin/main)" ]] || fail "the base was not merged"
if grep -Fq "Verifying the merged content" "$repo.out"; then fail "the leftover went into the verification"; fi
expect_not_pushed "$repo" "a leftover is in the worktree"
# publish-feature.sh does not take it for uncommitted work either: it
# reports it and publishes.
(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" ./scripts/publish-feature.sh 12) >"$repo.publish" 2>&1 ||
  { cat "$repo.publish" >&2; fail "publish-feature.sh refused a leftover of the base"; }
grep -Fq "old-site/    remove with: rm -rf -- old-site/" "$repo.publish" || fail "publish-feature.sh did not report the leftover"
[[ -f "$repo/old-site/build/assets/app.js" ]] || fail "publish-feature.sh deleted the leftover"
# Untracked work next to it is uncommitted work, for both scripts.
printf 'mine\n' >"$repo/notes.txt"
(cd "$repo" && PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" ./scripts/publish-feature.sh 12) >"$repo.publish" 2>&1 &&
  fail "publish-feature.sh published with an untracked file"
grep -Fq "there are uncommitted changes" "$repo.publish" || fail "publish-feature.sh did not report the untracked file"
run_update "$repo" 12
[[ "$status" -eq 1 ]] || fail "update-feature.sh went on with an untracked file"
grep -Fq "?? notes.txt" "$repo.out" || fail "the untracked file was not named"
rm -f "$repo/notes.txt"
# Removed by the human, the next run verifies and publishes.
rm -rf "$repo/old-site"
run_update "$repo" 12
[[ "$status" -eq 0 ]] || { cat "$repo.out" >&2; fail "updating after the leftover was removed failed ($status)"; }
grep -Fq "Verifying the merged content" "$repo.out" || fail "the merged content was not verified"

# A merge that breaks a check is not published.
repo="$(setup_repo breaks)"
move_base "$repo" "Break the check" 'printf "x\n" >broken.txt'
run_update "$repo" 12
[[ "$status" -eq 1 ]] || { cat "$repo.out" >&2; fail "a failing verification after the merge did not stop ($status)"; }
grep -Fq "the verification fails after the merge of origin/main" "$repo.out" || fail "the failing verification was not explained"
expect_not_pushed "$repo" "the verification fails"

# Only a finished feature is updated, and only without uncommitted work.
repo="$(setup_repo unfinished)"
git -C "$repo" commit -q --amend -m "Add the marker"
run_update "$repo" 12
[[ "$status" -eq 1 ]] || fail "an unfinished feature was updated"
grep -Fq "the feature is not finished" "$repo.out" || fail "the unfinished feature was not explained"
expect_not_pushed "$repo" "the feature is not finished"
repo="$(setup_repo uncommitted)"
printf 'more\n' >>"$repo/feature.txt"
run_update "$repo" 12
[[ "$status" -eq 1 ]] || fail "a feature with uncommitted changes was updated"
grep -Fq "there are uncommitted changes" "$repo.out" || fail "the uncommitted changes were not explained"
expect_not_pushed "$repo" "there are uncommitted changes"
run_update "$repo" twelve
[[ "$status" -eq 1 ]] && grep -Fq "issue number must be numeric" "$repo.out" || fail "a non-numeric issue was accepted"
repo="$tmp/unfinished"
(cd "$repo" && git checkout -q main && PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" ./scripts/update-feature.sh 12) >"$repo.out" 2>&1 &&
  fail "update-feature.sh ran on main"
grep -Fq "must run on feature/12-*" "$repo.out" || fail "the wrong branch was not explained"

echo "update-feature tests passed"
