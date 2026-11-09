#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/record-exception-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "record-exception test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"

# A fake GitHub CLI. It records every call; a comment on an Issue is kept in
# <log>.comments and returned by the comments API, as GitHub would, so that
# finish-feature.sh can compare a record with the one published. It answers
# what publish-feature.sh asks for a new pull request.
#   MOCK_GH_USER        the login of the authenticated account
#   MOCK_COMMENT_EXIT   exit status of 'issue comment'
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
case "${1:-} ${2:-}" in
  "auth status") ;;
  "api user") echo "${MOCK_GH_USER-owner-login}" ;;
  "issue comment")
    [[ "${MOCK_COMMENT_EXIT:-0}" -eq 0 ]] || exit "$MOCK_COMMENT_EXIT"
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then
        jq -Rs '{body: .}' "${args[$((i + 1))]}" >>"$MOCK_GH_LOG.comments"
      fi
    done
    ;;
  "api repos/{owner}/{repo}/issues/12/comments")
    filter="."
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--jq" ]]; then filter="$2"; fi
      shift
    done
    if [[ -f "$MOCK_GH_LOG.comments" ]]; then jq -s . "$MOCK_GH_LOG.comments"; else echo '[]'; fi | jq -r "$filter"
    ;;
  "pr list") ;;
  "pr create")
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [[ "${args[$i]}" == "--body-file" ]]; then cp "${args[$((i + 1))]}" "$MOCK_GH_LOG.body"; fi
    done
    echo "https://github.com/example/project/pull/7"
    ;;
  "repo view") echo main ;;
  "api repos/{owner}/{repo}/rules/branches/main" | "api repos/{owner}/{repo}/branches/main") echo 0 ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

review=".agents/reviews/feature-12-marker-review-01.json"
review2=".agents/reviews/feature-12-marker-review-02.json"
triage=".agents/triage/feature-12-marker-review-01-triage.json"
record_m1=".agents/exceptions/feature-12-marker-review-01-M1.json"
record_c1=".agents/exceptions/feature-12-marker-review-01-C1.json"

findings='[
  {"id": "M1", "severity": "major", "title": "Wrong result", "evidence": "feature.txt:1", "impact": "Bug.", "recommendation": "Fix."},
  {"id": "C1", "severity": "critical", "title": "Data loss", "evidence": "feature.txt:2", "impact": "Loss.", "recommendation": "Guard."},
  {"id": "MIN1", "severity": "minor", "title": "Vague name", "evidence": "feature.txt:1", "impact": "Readability.", "recommendation": "Rename."}
]'

# set_completion <repo> <status>
set_completion() {
  local remaining='[]'
  local met="met"

  if [[ "$2" != "complete" ]]; then
    remaining='["Plan steps 3 to 9"]'
    met="not_met"
  fi
  mkdir -p "$1/.agents/completion"
  jq -n --arg status "$2" --arg met "$met" --argjson remaining "$remaining" '{
    schema: "completion/v1", status: $status,
    criteria: [
      {criterion: "The marker exists", status: "met", evidence: "feature.txt"},
      {criterion: "The marker is documented", status: $met, evidence: "docs/marker.md"}
    ],
    remaining: $remaining
  }' >"$1/.agents/completion/12.json"
}

# write_review <repo> <path> <round>: a current review of the feature with the
# findings, which classified no impact on the architecture, so that only an
# exception makes the merge need the owner.
write_review() {
  jq -n --argjson findings "$findings" --argjson round "$3" --arg merge_base "$(git -C "$1" rev-parse main)" '{
    schema: "review/v1", kind: "feature", issue: 12, round: $round,
    branch: "feature/12-marker", base: "main", merge_base: $merge_base, head: "bbbb",
    reviewed_tree: "", reviewed_paths: null,
    reviewer: {agent: "claude", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    architecture_impact: {level: "none", rationale: "A marker file.", checked_against: ["AGENTS.md"]},
    verdict: "CHANGES_REQUIRED", limitations: "", findings: $findings
  }' >"$1/$2"
  record_reviewed_tree "$1" "$1/$2"
}

# write_triage <repo> <review>: the published triage of the review; the
# blocking findings are FIX_NOW, as they always are.
write_triage() {
  jq --arg source "$2" '{
    schema: "triage/v1", source_review: $source, issue,
    reviewed_tree, review_verdict: .verdict, triage: {agent: "codex", model: "model-t"},
    approved_at: "2026-01-02T00:00:00Z", published_at: "2026-01-02T00:01:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title,
      decision: (if .severity == "minor" then "ACCEPT" else "FIX_NOW" end), rationale: "Considered.", followup: null}]
  }' "$1/$2" >"$1/.agents/triage/$(basename "$2" .json)-triage.json"
}

# setup_repo <label>: a feature of Issue 12 with an uncommitted change, a
# complete record, and a current review with a major, a critical, and a
# minor finding, triaged and published; with a remote for the publication.
setup_repo() {
  local repo="$tmp/$1"
  local remote="$tmp/$1-remote.git"

  git init -q --bare -b main "$remote"
  git clone -q "$remote" "$repo" 2>/dev/null
  mkdir -p "$repo/.agents/reviews" "$repo/.agents/triage"
  copy_workflow "$repo"
  workflow_gitignore "$repo/.gitignore"
  printf 'marker: test -f AGENTS.md\n' >"$repo/scripts/verify.conf"
  printf '# Agents\n' >"$repo/AGENTS.md"
  git -C "$repo" config user.name "Exception Test"
  git -C "$repo" config user.email "exception-test@example.com"
  git -C "$repo" checkout -q -b main
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" push -q origin main
  git -C "$repo" switch -q -c feature/12-marker
  printf 'feature work\n' >"$repo/feature.txt"
  set_completion "$repo" complete
  write_review "$repo" "$review" 1
  write_triage "$repo" "$review"
  printf '%s\n' "$repo"
}

# at_terminal <repo> <answer> <command>...: runs the command in the repository
# at a pseudo-terminal, answering <answer> to its question.
at_terminal() {
  local repo="$1"
  local answer="$2"
  local command

  shift 2
  command="cd $(printf '%q' "$repo") && PATH=$(printf '%q' "$tmp/bin:/usr/bin:/bin") MOCK_GH_LOG=$(printf '%q' "$repo.gh") $(printf '%q ' "$@")"
  if script --version 2>/dev/null | grep -q util-linux; then
    printf '%s\n' "$answer" | script -qec "$command" /dev/null
  else
    printf '%s\n' "$answer" | script -q /dev/null sh -c "$command"
  fi
}

# record <repo> <answer> <argument>...: record-exception.sh at a terminal.
record() {
  local repo="$1"
  local answer="$2"

  shift 2
  at_terminal "$repo" "$answer" ./scripts/record-exception.sh "$@" >"$repo.out" 2>&1
}

# expect_refused <repo> <description> <message> <argument>...
expect_refused() {
  local repo="$1"
  local description="$2"
  local message="$3"

  shift 3
  if record "$repo" y "$@"; then
    cat "$repo.out" >&2
    fail "expected a refusal: $description"
  fi
  grep -Fq -- "$message" "$repo.out" || {
    cat "$repo.out" >&2
    fail "the refusal does not say why: $description"
  }
  [[ -z "$(find "$repo/.agents/exceptions" -type f 2>/dev/null)" ]] || fail "an exception was stored although: $description"
  [[ ! -s "$repo.gh.comments" ]] || fail "an exception was published although: $description"
}

run_finish() {
  local repo="$1"
  shift

  (
    cd "$repo"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" GIT_EDITOR="${EDITOR_COMMAND:-true}" ./scripts/finish-feature.sh "$@"
  ) >"$repo.finish" 2>&1
}

expect_no_commit() {
  local repo="$1"
  local description="$2"
  local message="$3"

  if run_finish "$repo" 12 "Add the marker"; then
    cat "$repo.finish" >&2
    fail "finish-feature.sh committed although: $description"
  fi
  [[ "$(git -C "$repo" rev-list --count HEAD)" -eq 1 ]] || fail "a commit was created although: $description"
  grep -Fq -- "$message" "$repo.finish" || {
    cat "$repo.finish" >&2
    fail "finish-feature.sh does not say why it refused although: $description"
  }
}

run_publish() {
  (
    cd "$1"
    PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$1.gh" ./scripts/publish-feature.sh 12
  ) >"$1.publish" 2>&1
}

pushed() {
  git -C "$1" ls-remote --exit-code --heads origin feature/12-marker >/dev/null 2>&1
}

not_applicable=(--finding M1 --type not-applicable --reason "The code checks the bound." --evidence "feature.txt:1 has the check")
risk_accepted=(--finding C1 --type risk-accepted --reason "The data is a cache; losing it is acceptable.")

# ------------------------------------------------------------------ refusals
repo="$(setup_repo refusals)"

# Without a terminal: the confirmation is never read from a pipe.
if (cd "$repo" && printf 'y\n' | PATH="$tmp/bin:/usr/bin:/bin" MOCK_GH_LOG="$repo.gh" \
  ./scripts/record-exception.sh "$review" "${not_applicable[@]}") >"$repo.out" 2>&1; then
  fail "an exception was recorded without a terminal"
fi
grep -Fq "must be a terminal" "$repo.out" || fail "the refusal without a terminal does not say why"
[[ ! -e "$repo/$record_m1" ]] || fail "an exception was stored without a terminal"

expect_refused "$repo" "--unattended" "cannot run with --unattended" "$review" "${not_applicable[@]}" --unattended
expect_refused "$repo" "no type" "name the type" "$review" --finding M1 --reason "Why."
expect_refused "$repo" "a wrong type" "must be not-applicable or risk-accepted" "$review" --finding M1 --type accepted --reason "Why."
expect_refused "$repo" "an empty reason" "needs a reason" "$review" --finding M1 --type risk-accepted --reason "  "
expect_refused "$repo" "no reason" "needs a reason" "$review" --finding M1 --type risk-accepted
expect_refused "$repo" "not-applicable without evidence" "needs the evidence" "$review" --finding M1 --type not-applicable --reason "Wrong."
expect_refused "$repo" "no finding" "name the finding" "$review" --type risk-accepted --reason "Why."
expect_refused "$repo" "a wildcard" "not a finding ID" "$review" --finding '*' --type risk-accepted --reason "Why."
expect_refused "$repo" "an unknown finding" "has no finding M9" "$review" --finding M9 --type risk-accepted --reason "Why."
expect_refused "$repo" "a minor finding" "finding MIN1 is minor" "$review" --finding MIN1 --type risk-accepted --reason "Why."
expect_refused "$repo" "a general --force" "Usage:" "$review" "${not_applicable[@]}" --force

# A review that is not the latest round, and a stale review.
write_review "$repo" "$review2" 2
expect_refused "$repo" "an older round" "is not the latest review" "$review" "${not_applicable[@]}"
rm "$repo/$review2"
printf 'changed after the review\n' >>"$repo/feature.txt"
expect_refused "$repo" "a stale review" "is stale" "$review" "${not_applicable[@]}"

# Declined: nothing is stored or published.
repo="$(setup_repo declined)"
record "$repo" n "$review" "${not_applicable[@]}" || fail "declining an exception failed"
grep -Fq "Declined; nothing was stored or published." "$repo.out" || fail "a declined exception was not reported"
[[ ! -e "$repo/$record_m1" && ! -s "$repo.gh.comments" ]] || fail "a declined exception was stored or published"

# A failed publication stores nothing.
repo="$(setup_repo unpublished)"
if MOCK_COMMENT_EXIT=1 record "$repo" y "$review" "${not_applicable[@]}"; then
  fail "an exception that could not be published was reported as stored"
fi
[[ ! -e "$repo/$record_m1" ]] || fail "an exception that could not be published was stored"

# ------------------------------------------- a false finding and a risk accepted
repo="$(setup_repo excepted)"
record "$repo" y "$review" "${not_applicable[@]}" || {
  cat "$repo.out" >&2
  fail "recording a not-applicable exception failed"
}
[[ -f "$repo/$record_m1" ]] || fail "the exception was not stored as $record_m1"
jq -e --arg sha "$(sha256sum "$repo/$review" | cut -c1-64)" --arg tree "$(jq -r .reviewed_tree "$repo/$review")" '
  .schema == "exception/v1" and .type == "not-applicable" and .reason == "The code checks the bound."
  and .evidence == "feature.txt:1 has the check" and .account == "owner-login"
  and (.directed_at | test("^[0-9-]{10}T[0-9:]{8}Z$")) and .review == ".agents/reviews/feature-12-marker-review-01.json"
  and .review_sha256 == $sha and .round == 1 and .finding_id == "M1" and .finding_title == "Wrong result"
  and .finding_severity == "major" and .reviewed_tree == $tree and (.merge_base | length) == 40
' "$repo/$record_m1" >/dev/null || fail "the stored exception lacks a field: $(cat "$repo/$record_m1")"
# Stored exactly as shown.
tr -d '\r' <"$repo.out" | grep -Fq -- "$(cat "$repo/$record_m1")" || fail "the stored exception is not the one shown"
[[ -z "$(git -C "$repo" status --porcelain -- .agents/exceptions)" ]] || fail "Git does not ignore the exceptions"
# Published on the Issue, with the marker that keeps it from the agents.
jq -r .body "$repo.gh.comments" >"$repo.comment"
[[ "$(head -n 1 "$repo.comment")" == "<!-- workflow-report: owner-exception -->" ]] || fail "the published exception lacks its marker"
grep -Fq "Wrong result" "$repo.comment" || fail "the published exception does not name the finding"
grep -Fq "SHA-256 \`$(sha256sum "$repo/$record_m1" | cut -c1-64)\`" "$repo.comment" || fail "the published exception lacks the SHA-256 of the record"
# One exception per finding.
expect_refused_again() {
  if record "$repo" y "$review" "${not_applicable[@]}"; then fail "a second exception to M1 was recorded"; fi
  grep -Fq "exists already" "$repo.out" || fail "a second exception to M1 was not refused as such"
}
expect_refused_again

# One blocking finding excepted, the other not: finish still refuses and
# names the finding without an exception.
review_before="$(sha256sum "$repo/$review")"
expect_no_commit "$repo" "C1 has no exception" "C1: no exception is recorded"
if grep -Fq "M1: " "$repo.finish"; then fail "finish-feature.sh named the excepted finding M1 as open"; fi

record "$repo" y "$review" "${risk_accepted[@]}" || {
  cat "$repo.out" >&2
  fail "recording a risk-accepted exception failed"
}
jq -e '.type == "risk-accepted" and .evidence == null' "$repo/$record_c1" >/dev/null || fail "the risk-accepted exception is wrong"

# The completion gate is not waived: an unmet criterion still stops the commit.
set_completion "$repo" partial
record_reviewed_tree "$repo" "$repo/$review"
# The review changed (its reviewed tree), so the exceptions are invalid now;
# the completion gate comes first and refuses anyway.
expect_no_commit "$repo" "the feature is partial" "the feature is not complete (partial)"

# A fresh repository for the commit.
repo="$(setup_repo committed)"
record "$repo" y "$review" "${not_applicable[@]}" || fail "recording M1 failed"
record "$repo" y "$review" "${risk_accepted[@]}" || fail "recording C1 failed"
review_before="$(sha256sum "$repo/$review")"
run_finish "$repo" 12 "Add the marker" || {
  cat "$repo.finish" >&2
  fail "finishing with an exception to every blocking finding failed"
}
[[ "$(sha256sum "$repo/$review")" == "$review_before" ]] || fail "the review was changed"
message="$(git -C "$repo" log -1 --format=%B)"
grep -Fq "Review: round 1, CHANGES REQUIRED, by claude (model-r); triage published on #12; blocking findings open with the owner's exception: M1 C1" <<<"$message" ||
  fail "the review line does not keep the verdict and name the excepted findings: $message"
grep -Fqx "Owner exceptions to blocking review findings:" <<<"$message" || fail "the message has no section for the exceptions"
for line in "- M1 (major) Wrong result: not-applicable, by owner-login at $(jq -r .directed_at "$repo/$record_m1")" \
  "  reason: The code checks the bound." "  evidence: feature.txt:1 has the check" \
  "  record: $record_m1 sha256 $(sha256sum "$repo/$record_m1" | cut -c1-64)" \
  "- C1 (critical) Data loss: risk-accepted, by owner-login at $(jq -r .directed_at "$repo/$record_c1")" \
  "  record: $record_c1 sha256 $(sha256sum "$repo/$record_c1" | cut -c1-64)" \
  "- required from the project owner, for exactly this commit"; do
  grep -Fqx -- "$line" <<<"$message" || fail "the commit message lacks: $line"
done
# The merge gate needs the owner, and the approval request names each record.
request="$(git -C "$repo" show HEAD:.agents/approval-requests/12.json)" || fail "no approval request was committed"
jq -e --arg m1 "$(sha256sum "$repo/$record_m1" | cut -c1-64)" --arg c1 "$(sha256sum "$repo/$record_c1" | cut -c1-64)" '
  (.reasons | any(test("exception \\(not-applicable\\) to the blocking finding M1 .* sha256 " + $m1)))
  and (.reasons | any(test("exception \\(risk-accepted\\) to the blocking finding C1 .* sha256 " + $c1)))
' <<<"$request" >/dev/null || fail "the approval request does not name the exceptions: $request"
if git -C "$repo" show --name-only --format= HEAD | grep -Fq ".agents/exceptions"; then fail "an exception was committed"; fi

# The pull request shows the original finding and the owner's exception
# first, from the records whose SHA-256 it recomputed.
run_publish "$repo" || {
  cat "$repo.publish" >&2
  fail "publishing a feature with exceptions failed"
}
[[ "$(head -n 1 "$repo.gh.body")" == "## Owner exceptions to blocking review findings" ]] ||
  fail "the pull request does not start with the exceptions"
for line in "### Finding M1 (major), review round 1: Wrong result" "- Impact: Bug." \
  "**The owner's exception:** \`not-applicable\`, by owner-login at $(jq -r .directed_at "$repo/$record_m1")" \
  "- Reason: The code checks the bound." "### Finding C1 (critical), review round 1: Data loss" \
  "- Reason: The data is a cache; losing it is acceptable."; do
  grep -Fqx -- "$line" "$repo.gh.body" || fail "the pull request description lacks: $line"
done

# A record altered after the finish is reported and not shown as the
# owner's decision; nothing is pushed.
repo="$(setup_repo altered-after)"
record "$repo" y "$review" "${not_applicable[@]}" || fail "recording M1 failed"
record "$repo" y "$review" "${risk_accepted[@]}" || fail "recording C1 failed"
run_finish "$repo" 12 "Add the marker" || fail "finishing failed"
jq '.reason = "Edited later."' "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"
if run_publish "$repo"; then fail "a feature with an altered exception was published"; fi
grep -Fq "is not the record the finish commit names" "$repo.publish" || fail "the altered exception was not reported"
pushed "$repo" && fail "a feature with an altered exception was pushed"
rm "$repo/$record_c1"
if run_publish "$repo"; then fail "a feature with a missing exception was published"; fi
grep -Fq "$record_c1 is missing" "$repo.publish" || fail "the missing exception was not reported"

# ------------------------------------- a finding that continues an earlier one
# The round-2 review re-raises M1 of round 1, which the triage left to fix:
# the copy that record-exception.sh validates finds round 1 next to the
# stored review.
findings_round1="$findings"
findings="$(jq '(.[] | select(.id == "M1")) += {previous: {round: 1, id: "M1", relation: "unresolved", reason: "Still wrong."}}' <<<"$findings_round1")"
repo="$(setup_repo continued)"
write_review "$repo" "$review2" 2
record "$repo" y "$review2" "${not_applicable[@]}" || {
  cat "$repo.out" >&2
  fail "recording an exception to a finding that continues an earlier round failed"
}
record_continued=".agents/exceptions/feature-12-marker-review-02-M1.json"
[[ -f "$repo/$record_continued" ]] || fail "the exception was not stored as $record_continued"
jq -e --arg sha "$(sha256sum "$repo/$review2" | cut -c1-64)" '
  (keys == (["account", "directed_at", "evidence", "finding_id", "finding_severity", "finding_title", "merge_base",
             "reason", "review", "review_sha256", "reviewed_tree", "round", "schema", "type"]))
  and .review == ".agents/reviews/feature-12-marker-review-02.json" and .review_sha256 == $sha
  and .round == 2 and .finding_id == "M1" and .finding_title == "Wrong result"
' "$repo/$record_continued" >/dev/null || fail "the exception to a continued finding differs in form: $(cat "$repo/$record_continued")"
jq -r .body "$repo.gh.comments" >"$repo.comment"
[[ "$(head -n 1 "$repo.comment")" == "<!-- workflow-report: owner-exception -->" ]] || fail "the comment on a continued finding lacks its marker"
grep -Fqx "## Owner exception — round 2, finding M1" "$repo.comment" || fail "the comment on a continued finding differs in form"
grep -Fq "SHA-256 \`$(sha256sum "$repo/$record_continued" | cut -c1-64)\`" "$repo.comment" ||
  fail "the comment on a continued finding lacks the SHA-256 of the record"

# A predecessor whose round does not exist is still refused, with the same
# message.
repo="$(setup_repo no-predecessor)"
rm "$repo/$review" "$repo/$triage"
write_review "$repo" "$review2" 2
expect_refused "$repo" "a predecessor of a round without a review" \
  "invalid review artifact: finding M1 names round 1 as its predecessor, but the feature has no review of that round" \
  "$review2" "${not_applicable[@]}"
findings="$findings_round1"

# ------------------------------------------ the base merged after the finish
# finished_with_exceptions <label>: a feature committed by finish-feature.sh
# with an exception to each blocking finding, whose base then moved: main
# has a commit that the feature does not.
finished_with_exceptions() {
  repo="$(setup_repo "$1")"
  record "$repo" y "$review" "${not_applicable[@]}" || fail "$1: recording M1 failed"
  record "$repo" y "$review" "${risk_accepted[@]}" || fail "$1: recording C1 failed"
  run_finish "$repo" 12 "Add the marker" || {
    cat "$repo.finish" >&2
    fail "$1: finishing failed"
  }
  git -C "$repo" switch -q main
  printf 'moved on\n' >"$repo/base.txt"
  git -C "$repo" add base.txt
  git -C "$repo" commit -qm "Base moves on"
  git -C "$repo" push -q origin main
  git -C "$repo" switch -q feature/12-marker
}

# Merging the base changes the working tree, but not what the review and
# the exceptions covered: they are judged against the finish commit.
finished_with_exceptions merged-base
git -C "$repo" merge -q --no-edit origin/main
run_publish "$repo" || {
  cat "$repo.publish" >&2
  fail "a feature with exceptions was refused after a merge of its base"
}
grep -Fq "The branch merged its base after the feature was finished" "$repo.publish" || fail "the merge of the base was not noticed"
grep -Fqx "### Finding M1 (major), review round 1: Wrong result" "$repo.gh.body" ||
  fail "the pull request after a merge of the base does not show the exception"
pushed "$repo" || fail "the feature with exceptions was not pushed after a merge of the base"

# A commit after the finish that changes what the review covered makes the
# exceptions invalid, after a merge of the base and without one.
finished_with_exceptions changed-after-merge
git -C "$repo" merge -q --no-edit origin/main
printf 'changed after the finish\n' >>"$repo/feature.txt"
git -C "$repo" commit -qam "Change the feature after the finish"
if run_publish "$repo"; then fail "exceptions were published although the feature changed after the finish"; fi
grep -Fq "cannot be shown as the owner's decision" "$repo.publish" || {
  cat "$repo.publish" >&2
  fail "the exceptions of a feature changed after the merge were not refused"
}
grep -Fq "lists them, but the commit $(git -C "$repo" rev-parse --short HEAD) (Change the feature after the finish)" "$repo.publish" ||
  fail "the refusal does not name the change after the merge"
pushed "$repo" && fail "a feature changed after the finish was pushed with its exceptions"

finished_with_exceptions changed-after-finish
printf 'changed after the finish\n' >>"$repo/feature.txt"
git -C "$repo" commit -qam "Change the feature after the finish"
if run_publish "$repo"; then fail "exceptions were published although the feature changed after the finish"; fi
grep -Fq "cannot be shown as the owner's decision" "$repo.publish" || {
  cat "$repo.publish" >&2
  fail "the exceptions of a feature changed after the finish were not refused"
}
pushed "$repo" && fail "a feature changed after the finish was pushed with its exceptions"

# ----------------------------------------- invalid exceptions at the finish
# expect_invalid <label> <message> <change>: records both exceptions, applies
# the change, and expects finish-feature.sh to refuse with the message.
expect_invalid() {
  repo="$(setup_repo "$1")"
  record "$repo" y "$review" "${not_applicable[@]}" || fail "$1: recording M1 failed"
  record "$repo" y "$review" "${risk_accepted[@]}" || fail "$1: recording C1 failed"
  eval "$3"
  expect_no_commit "$repo" "$1" "$2"
}

# A missing record.
expect_invalid missing "C1: no exception is recorded" 'rm "$repo/$record_c1"'
# A field that disagrees with the review, or is missing.
expect_invalid altered-title "its title is not the title of finding C1" \
  'jq ".finding_title = \"Something else\"" "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"'
expect_invalid extra-field "is not a field of the schema" \
  'jq ".extra = true" "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"'
expect_invalid missing-field ".reviewed_tree is missing" \
  'jq "del(.reviewed_tree)" "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"'
expect_invalid wrong-type ".type must be one of" \
  'jq ".type = \"waived\"" "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"'
expect_invalid no-evidence "a not-applicable exception names the evidence" \
  'jq ".evidence = null" "$repo/$record_m1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_m1"'
# Free text altered after the confirmation: not the record that was published.
expect_invalid altered-reason "is not the exception published on Issue #12" \
  'jq ".reason = \"Edited.\"" "$repo/$record_c1" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$record_c1"'
# A record that is not stored under its own name.
expect_invalid renamed "C1: no exception is recorded" 'mv "$repo/$record_c1" "$repo/.agents/exceptions/other.json"'
# The review artifact edited after the exception (its SHA-256), with the
# same reviewed tree.
expect_invalid altered-review "the review artifact changed after the exception was recorded" \
  'jq ".limitations = \"Edited.\"" "$repo/$review" >"$repo/x.tmp" && mv "$repo/x.tmp" "$repo/$review"'
# A newer review round of the same findings: nothing carries forward.
expect_invalid newer-round "M1: no exception is recorded" \
  'write_review "$repo" "$review2" 2; write_triage "$repo" "$review2"'
# Changed content: the review is stale, and so is the exception.
expect_invalid stale "is stale" 'printf "changed\n" >>"$repo/feature.txt"'
# An exception of a stale review, after a new review of the changed content
# with the same findings, does not count either.
expect_invalid stale-then-reviewed "M1: no exception is recorded" \
  'printf "changed\n" >>"$repo/feature.txt"; write_review "$repo" "$review2" 2; write_triage "$repo" "$review2"'

echo "record-exception tests passed"
