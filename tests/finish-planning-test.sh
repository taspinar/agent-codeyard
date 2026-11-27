#!/usr/bin/env bash

set -euo pipefail

# Run as on CI: without the user's global or system Git configuration, so a
# test cannot depend on a local Git identity or setting.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/finish-planning-test.XXXXXX")"

cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "finish-planning test failed: $*" >&2
  exit 1
}

source "$source_root/tests/lib-fakes.sh"
make_fake_agents "$tmp/bin"
# A fake GitHub CLI that names the account of a decision (--resolve).
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api user") echo "owner-login" ;;
  *)
    echo "Unexpected gh invocation: $*" >&2
    exit 97
    ;;
esac
GH
chmod +x "$tmp/bin/gh"

# The lists of planning documents are defined once, in scripts/lib/planning.sh
# (Issue 540). They agree with each other: the scope is the product planning
# and what a feature may update, and the baseline and the planner's
# documents are part of it.
(
  source "$source_root/scripts/lib/planning.sh"
  sorted() { printf '%s\n' "$@" | LC_ALL=C sort; }
  [[ "$(sorted "${PLANNING_SCOPE[@]}")" == "$(sorted "${PLANNING_PRODUCT_SCOPE[@]}" "${PLANNING_FEATURE_SCOPE[@]}")" ]] ||
    fail "PLANNING_SCOPE is not PLANNING_PRODUCT_SCOPE and PLANNING_FEATURE_SCOPE together"
  [[ -z "$(LC_ALL=C comm -12 <(sorted "${PLANNING_PRODUCT_SCOPE[@]}") <(sorted "${PLANNING_FEATURE_SCOPE[@]}"))" ]] ||
    fail "a document is both in PLANNING_PRODUCT_SCOPE and in PLANNING_FEATURE_SCOPE"
  [[ -z "$(LC_ALL=C comm -23 <(sorted "${PLANNING_BASELINE_DOCUMENTS[@]}") <(sorted "${PLANNING_SCOPE[@]}"))" ]] ||
    fail "PLANNING_BASELINE_DOCUMENTS names a document outside PLANNING_SCOPE"
  [[ -z "$(LC_ALL=C comm -23 <(sorted "${PLANNING_PLANNER_DOCUMENTS[@]}") <(sorted "${PLANNING_BASELINE_DOCUMENTS[@]}"))" ]] ||
    fail "PLANNING_PLANNER_DOCUMENTS names a document outside PLANNING_BASELINE_DOCUMENTS"
  [[ " ${PLANNING_FEATURE_SCOPE[*]} " == *" $PLANNING_DECISIONS_DIR "* ]] ||
    fail "PLANNING_DECISIONS_DIR is not in PLANNING_FEATURE_SCOPE"
  [[ "$(planning_list ", " a b c)" == "a, b, c" && "$(planning_list ", " a)" == "a" ]] ||
    fail "planning_list does not join its items"

  # The light risk profile leaves every planning document out of its low
  # class, from the same list.
  source "$source_root/scripts/lib/risk.sh"
  excluded="$(printf '%s\n' "${RISK_PROFILE_LIGHT_LOW[@]}" | sed -n 's/^:(exclude)//p' | LC_ALL=C sort)"
  [[ "$excluded" == "$(sorted "${PLANNING_SCOPE[@]}" "$PLANNING_APPROVAL_FILE" AGENTS.md)" ]] ||
    fail "the light risk profile does not leave out exactly the planning documents and AGENTS.md: $excluded"

  # No other script copies a list (M1 of reviews 01 and 04). A copy need not
  # be one list: separate assignments, case or grep alternatives, or messages
  # can each name one document. So the check does not look for documents
  # that follow each other. planning_copies <table> <file...> counts, per
  # file and planning document, the lines that name it (comment lines do not
  # count; a pathspec magic, a variable directory and a '\' before '/' or '.'
  # are left out first; adjacent quoted pieces are joined, a brace list is
  # expanded, a variable assigned a literal value stands for that value, and
  # a document file counts by its name alone, as in "$dir"/roadmap.md), and
  # prints each file and document whose count differs from the table, with
  # the lines that name it. The table lists
  # every permitted mention: "<file> | <document> | <lines> | <reason>".
  planning_copies() {
    PLANNING_COPY_PATHS="$(printf '%s\n' "${PLANNING_SCOPE[@]}" "$PLANNING_APPROVAL_FILE")" perl -e '
      my (%document, @names, @dirs);
      for my $full (split /\n/, $ENV{PLANNING_COPY_PATHS}) {
        (my $name = $full) =~ s{^docs/}{};
        $document{$name} = $full;
        if ($name =~ /\.md$/) { push @names, quotemeta $name } else { push @dirs, quotemeta $name }
      }
      my $names = join("|", @names);
      my $dirs = join("|", @dirs);
      my $table = shift @ARGV;
      my (%allowed, %found, %lines);
      open(my $rows, "<", $table) or die "no table: $table\n";
      while (<$rows>) {
        next if /^\s*(#|$)/;
        chomp;
        my ($file, $document, $count, $reason) = split /\s*\|\s*/;
        die "a row of the table has no reason: $_\n" unless defined $reason && $reason =~ /\S/;
        $allowed{"$file\t$document"} = $count;
      }
      for my $file (@ARGV) {
        open(my $in, "<", $file) or next;
        my @lines = <$in>;
        close $in;
        # A variable assigned a literal value (no expansion, no command)
        # stands for that value, so "$d/$n" with d=docs and n=decisions
        # names docs/decisions (M1 of review 06).
        my %value;
        for (@lines) {
          next if /^\s*#/;
          while (/(?:^|[\s;(&|])(?:(?:local|readonly|export|declare(?:\s+-[A-Za-z]+)?)\s+)?([A-Za-z_][A-Za-z0-9_]*)=("[^"\$`\\]*"|\x27[^\x27]*\x27|[A-Za-z0-9_.\/-]*)(?=$|[\s;)&|])/g) {
            my ($name, $literal) = ($1, $2);
            $literal =~ s/^["\x27]|["\x27]$//g;
            # A value that names a document already counts on the line
            # that assigns it; only the pieces of a path are resolved.
            next if $literal =~ m{(?<![A-Za-z0-9_.-])(?:docs/(?:$dirs)|(?:docs/)?(?:$names))(?![A-Za-z0-9_.-])};
            $value{$name} = $literal;
          }
        }
        for my $index (0 .. $#lines) {
          my $line = $lines[$index];
          local $. = $index + 1;
          next if $line =~ /^\s*#/;
          my $text = $line;
          $text =~ s/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $value{$1} ? $value{$1} : "\${$1}"/ge;
          $text =~ s/\$([A-Za-z_][A-Za-z0-9_]*)/exists $value{$1} ? $value{$1} : "\$$1"/ge;
          $text =~ s/:\(exclude\)//g;
          $text =~ s/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\///g;
          $text =~ s/\\([\/.])/$1/g;
          $text =~ s/(["\x27])\s*(["\x27])//g;
          $text =~ s{["\x27]?/["\x27]?}{/}g;
          1 while $text =~ s{([A-Za-z0-9_./-]*)(?<!\$)\{([^{}]*,[^{}]*)\}([A-Za-z0-9_./-]*)}{join(" ", map { "$1$_$3" } split(/,/, $2, -1))}e;
          my %named;
          while ($text =~ m{(?<![A-Za-z0-9_.-])(?:(?<![/])docs/($dirs)|(?:docs/)?($names))(?![A-Za-z0-9_.-])}g) {
            $named{$document{$1 // $2}} = 1;
          }
          for my $document (keys %named) {
            $found{"$file\t$document"}++;
            push @{$lines{"$file\t$document"}}, "  $file:$.: $line";
          }
        }
      }
      my %scanned = map { $_ => 1 } @ARGV;
      for my $key (sort keys %{{ %found, %allowed }}) {
        my ($file, $document) = split /\t/, $key;
        next unless $scanned{$file};
        my $count = $found{$key} // 0;
        my $permitted = $allowed{$key} // 0;
        next if $count == $permitted;
        print "$file names $document on $count line(s), the table permits $permitted:\n", @{$lines{$key} // []};
      }
    ' "$@"
  }

  # The check catches a copy in each of these forms, and a script that uses
  # the shared lists is no copy. A mention that the table permits passes; one
  # more fails.
  scan="$tmp/copy-scan"
  mkdir -p "$scan"
  : >"$scan/none.table"
  printf 'scope=(docs/roadmap.md docs/architecture.md)\n' >"$scan/one-line.sh"
  printf 'scope=(\n  "$root/docs/roadmap.md"\n  docs/PROJECT_REQUIREMENTS.md \\\n)\n' >"$scan/array.sh"
  printf 'cat <<EOF\ndocs/architecture.md\n\ndocs/decisions\nEOF\n' >"$scan/heredoc.sh"
  printf 'git diff -- :(exclude)docs/roadmap.md\n# docs/changes\n  :(exclude)docs/changes\n' >"$scan/pathspec.sh"
  printf 'roadmap=docs/roadmap.md\nrun_tests\narchitecture="$root/docs/architecture.md"\n' >"$scan/assignments.sh"
  printf 'case "$path" in\n  docs/roadmap.md) x ;;\n  docs/architecture.md) y ;;\nesac\n' >"$scan/case.sh"
  printf "grep -E 'docs/roadmap\\\\.md|docs/architecture\\\\.md' \"\$file\"\n" >"$scan/grep.sh"
  printf 'awk %s\n' "'/^docs\\/decisions\\// { print }'" >"$scan/escaped.sh"
  # Assembled paths (M1 of review 05): adjacent quoted pieces, brace
  # expansion, and a bare document name after another directory.
  printf 'printf "%%s/%%s\\n" "docs" "roadmap.md"\nx="docs/""architecture.md"\n' >"$scan/pieces.sh"
  printf "y='docs/'\"changes\"\n" >"$scan/pieces-directory.sh"
  printf 'scope=(docs/{roadmap,architecture}.md)\n' >"$scan/brace.sh"
  printf 'scope=(docs/{changes,decisions} "$root"/docs/{PROJECT_REQUIREMENTS,PROJECT_DESCRIPTION}.md)\n' >"$scan/brace-nested.sh"
  printf 'f="$root"/roadmap.md\n' >"$scan/basename.sh"
  # A path assembled from variables (M1 of review 06): a variable assigned a
  # literal value stands for it.
  printf 'd=docs\nn=decisions\npath="$d/$n"\n' >"$scan/variables.sh"
  printf 'local d="docs" n=changes; x="${d}"/"$n"\n' >"$scan/variables-braced.sh"
  printf 'source lib/planning.sh\nscope=("${PLANNING_SCOPE[@]}")\n# docs/roadmap.md docs/architecture.md\n' >"$scan/shared.sh"
  for form in one-line array heredoc pathspec assignments case grep escaped pieces pieces-directory brace brace-nested basename variables variables-braced; do
    [[ -n "$(planning_copies "$scan/none.table" "$scan/$form.sh")" ]] || fail "the copy check misses a copied list ($form)"
  done
  [[ -z "$(planning_copies "$scan/none.table" "$scan/shared.sh")" ]] ||
    fail "the copy check takes the use of the shared lists for a copy: $(planning_copies "$scan/none.table" "$scan/shared.sh")"
  [[ "$(planning_copies "$scan/none.table" "$scan/brace.sh")" == *"names docs/roadmap.md"*"names docs/architecture.md"* ||
    "$(planning_copies "$scan/none.table" "$scan/brace.sh")" == *"names docs/architecture.md"*"names docs/roadmap.md"* ]] ||
    fail "the copy check does not expand a brace list into each document"
  [[ "$(planning_copies "$scan/none.table" "$scan/variables.sh")" == *"names docs/decisions on 1 line(s)"*'variables.sh:3:'* ]] ||
    fail "the copy check does not resolve a directory assembled from variables"
  printf '%s\n' "$scan/case.sh | docs/roadmap.md | 1 | a test" "$scan/case.sh | docs/architecture.md | 1 | a test" >"$scan/case.table"
  [[ -z "$(planning_copies "$scan/case.table" "$scan/case.sh")" ]] ||
    fail "the copy check reports a mention that its table permits"
  printf '  docs/decisions) z ;;\n' >>"$scan/case.sh"
  [[ "$(planning_copies "$scan/case.table" "$scan/case.sh")" == *"names docs/decisions on 1 line(s), the table permits 0"* ]] ||
    fail "the copy check misses a mention that its table does not permit"
  printf 'scripts/x.sh | docs/roadmap.md | 1\n' >"$scan/bad.table"
  ! planning_copies "$scan/bad.table" "$scan/shared.sh" 2>/dev/null ||
    fail "the copy check takes a table row without a reason"

  # Only the template checks its own scripts (template_repository in
  # tests/lib-fakes.sh): a project keeps its own scripts there too, and what
  # they name is not the workflow's.
  if template_repository "$source_root"; then
    mapfile -d '' scripts < <(cd "$source_root" && git ls-files -z -- scripts ':(exclude)scripts/lib/planning.sh')
    cat >"$tmp/permitted-mentions" <<'MENTIONS'
# Each line of a script outside scripts/lib/planning.sh that names a planning
# document. None of them is a list of the planning: each acts on one
# document, or names documents for another purpose. A new mention fails
# the test until it is added here, with its reason.
scripts/adopt-repository.sh | docs/PLANNING_APPROVAL.md | 1 | later_paths: the paths that check-docs.sh may find missing, not a list of the planning
scripts/adopt-repository.sh | docs/decisions | 2 | later_paths (docs/decisions/x.md), and the text of the reconstructed architecture
scripts/adopt-repository.sh | docs/architecture.md | 1 | the reconstruction writes the architecture document
scripts/adopt-repository.sh | docs/PROJECT_REQUIREMENTS.md | 2 | the reconstruction writes the requirements document
scripts/assess-repository.sh | docs/PLANNING_APPROVAL.md | 1 | later_paths, as in adopt-repository.sh
scripts/assess-repository.sh | docs/decisions | 3 | later_paths, and the ADRs other than the README that the assessment leaves out
scripts/check-docs.sh | docs/PLANNING_APPROVAL.md | 1 | the --later example of its usage
scripts/check-docs.sh | docs/changes | 1 | the --later example of its usage
scripts/cleanup-worktree.sh | docs/PROJECT_DESCRIPTION.md | 1 | the description that a planning cycle copies back to the primary checkout
scripts/cleanup-worktree.sh | docs/changes | 1 | the change requests that a planning cycle copies back
scripts/cleanup-worktree.sh | docs/roadmap.md | 1 | the message that names the next step
scripts/create-feature-issue.sh | docs/roadmap.md | 3 | it reads the feature from the roadmap
scripts/finish-planning.sh | docs/architecture.md | 1 | the usage text
scripts/finish-planning.sh | docs/PROJECT_REQUIREMENTS.md | 2 | it checks and names the approved requirements
scripts/finish-planning.sh | docs/changes | 2 | the change request of the cycle
scripts/lib/guardrails.sh | docs/decisions | 2 | a protected path: an ADR change needs approval
scripts/lib/risk.sh | docs/decisions | 1 | RISK_PROFILE_HIGH: the ADRs are high risk, not a list of the planning
scripts/review-planning.sh | docs/PROJECT_REQUIREMENTS.md | 1 | it checks the approved requirements
scripts/review-planning.sh | docs/changes | 2 | the change request of the cycle
scripts/revise-planning.sh | docs/PROJECT_REQUIREMENTS.md | 2 | the usage text, and it checks the approved requirements
scripts/revise-planning.sh | docs/decisions | 6 | it checks that the ADRs are regular Markdown files
scripts/start-planning.sh | docs/PROJECT_DESCRIPTION.md | 1 | the description that the cycle copies in
scripts/start-planning.sh | docs/changes | 3 | the usage text, and the change request that the cycle copies in
scripts/start-planning.sh | docs/PROJECT_REQUIREMENTS.md | 11 | Project Grill writes and the owner approves the requirements
scripts/start-planning.sh | docs/architecture.md | 2 | the placeholder check of the architecture
scripts/start-planning.sh | docs/roadmap.md | 4 | the placeholder check of the roadmap and its feature IDs before and after
scripts/start-planning.sh | docs/decisions | 5 | it checks the ADRs that the planner wrote and that none was deleted
scripts/verify.conf | docs/architecture.md | 1 | the template-structure check
scripts/verify.conf | docs/PROJECT_DESCRIPTION.md | 1 | the --later argument of docs-references
scripts/verify.conf | docs/PLANNING_APPROVAL.md | 1 | the --later argument of docs-references
scripts/verify.conf | docs/changes | 1 | the --later argument of docs-references
MENTIONS
    copies="$(cd "$source_root" && planning_copies "$tmp/permitted-mentions" "${scripts[@]}")" ||
      fail "the copy check could not read its table"
    [[ -z "$copies" ]] ||
      fail "a script copies a list of planning documents instead of using scripts/lib/planning.sh:"$'\n'"$copies"

    # Each script that needs a list sources scripts/lib/planning.sh and uses
    # one of its lists.
    for script in check-docs.sh lib/risk.sh lib/scope.sh review-planning.sh finish-planning.sh start-planning.sh revise-planning.sh adopt-repository.sh assess-repository.sh; do
      grep -qE '^[^#]*source .*planning\.sh' "$source_root/scripts/$script" &&
        grep -qE '^[^#]*PLANNING_(SCOPE|PRODUCT_SCOPE|FEATURE_SCOPE|BASELINE_DOCUMENTS|PLANNER_DOCUMENTS|DECISIONS_DIR)' "$source_root/scripts/$script" ||
        fail "scripts/$script does not use the lists of scripts/lib/planning.sh"
    done
  fi
) || exit 1

reviews=".agents/reviews"
counter=0

# Creates a planning repository. Review rounds are added with add_review.
setup_repo() {
  local repo="$tmp/$1"

  mkdir -p "$repo/docs/decisions" "$repo/$reviews"
  copy_workflow "$repo"
  printf '# Project Requirements\n\nStatus: Approved\nApproved at: 2026-01-01T00:00:00Z\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
  printf '# Architecture\n\nLocal storage.\n' >"$repo/docs/architecture.md"
  printf '# Roadmap\n\n## F01 — Recipes\n\n- Goal: list recipes.\n' >"$repo/docs/roadmap.md"
  # Git ignores the owner's decisions, as the template's .gitignore does.
  printf '.agents/exceptions/\n' >"$repo/.gitignore"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name "Finish Test"
  git -C "$repo" config user.email "finish-test@example.com"
  git -C "$repo" add .
  git -C "$repo" commit -qm "Seed"
  git -C "$repo" switch -q -c planning/project-bootstrap

  printf '%s\n' "$repo"
}

# add_review <repo> <round> <verdict> <findings-json>
add_review() {
  local repo="$1"
  local review
  review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  jq -n --argjson round "$2" --arg verdict "$3" --argjson findings "$4" '{
    schema: "review/v1", kind: "planning", issue: null, round: $round,
    branch: "planning/project-bootstrap", base: "origin/main", merge_base: "aaaa", head: "bbbb",
    reviewed_tree: "", reviewed_paths: ["docs/PROJECT_DESCRIPTION.md", "docs/changes", "docs/PROJECT_REQUIREMENTS.md", "docs/architecture.md", "docs/roadmap.md", "docs/decisions"],
    reviewer: {agent: "codex", model: "model-r"}, created_at: "2026-01-01T00:00:00Z",
    verdict: $verdict, limitations: "", findings: $findings
  }' >"$review"
  record_reviewed_tree "$repo" "$review"
}

# add_triage <repo> <round> <decision-for-each-finding>: the approved planning
# triage of the review of that round (triage-review.sh, kind planning).
add_triage() {
  local repo="$1"
  local review="$repo/$reviews/planning-project-bootstrap-review-$(printf '%02d' "$2").json"

  mkdir -p "$repo/.agents/triage"
  jq --arg decision "$3" '{
    schema: "triage/v1", kind: "planning",
    source_review: ".agents/reviews/planning-project-bootstrap-review-\(.round | tostring | if length == 1 then "0" + . else . end).json",
    branch, round, reviewed_tree, review_verdict: .verdict,
    triage: {agent: "claude", model: "model-t", mode: "full"},
    approved_at: "2026-01-02T00:00:00Z",
    decisions: [.findings[] | {finding_id: .id, severity, title, decision: $decision, rationale: "Considered.", followup: null}]
  }' "$review" >"$(triage_file "$repo" "$2")"
}

# triage_file <repo> <round>: where the triage of that round is stored.
triage_file() {
  printf '%s/.agents/triage/planning-project-bootstrap-review-%02d-triage.json\n' "$1" "$2"
}

finding() {
  printf '{"id": "%s", "severity": "%s", "title": "%s", "evidence": "docs/roadmap.md", "impact": "Impact.", "recommendation": "Change it."}' "$1" "$2" "$3"
}

run_finish() {
  local repo="$1"
  local answer="$2"
  shift 2

  (
    cd "$repo"
    printf '%s\n' "$answer" | PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh "$@"
  ) >"$repo.out" 2>&1
}

expect_refused() {
  local repo="$1"
  local description="$2"

  if run_finish "$repo" y; then
    cat "$repo.out" >&2
    fail "expected refusal: $description"
  fi
  [[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded although: $description"
}

check_status() {
  local status=0
  (cd "$1" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check >/dev/null 2>&1) || status=$?
  echo "$status"
}

# A planning document that an adoption reconstructed carries the mark
# 'Observed, not approved' until the planning approves it: a reviewed
# planning that still carries it is not approved.
repo="$(setup_repo observed)"
printf '# Architecture\n\n> **Observed, not approved.** Reconstructed by adopt-repository.sh.\n\nLocal storage.\n' >"$repo/docs/architecture.md"
add_review "$repo" 1 PASS "[]"
expect_refused "$repo" "a planning document still carries the mark of a reconstruction"
grep -Fq "docs/architecture.md" "$repo.out" && grep -Fq "Observed, not approved" "$repo.out" ||
  fail "the refusal does not name the marked document: $(cat "$repo.out")"
printf '# Architecture\n\nLocal storage, as the planner confirmed it.\n' >"$repo/docs/architecture.md"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || { cat "$repo.out" >&2; fail "a planning without the mark was not approved"; }

# An amendment of the requirements that the owner confirmed in a planning triage
# is listed in the approval with its finding and the confirmation, and not
# as a finding that was not adopted.
repo="$(setup_repo amended)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Cost is not capped")]"
add_triage "$repo" 1 AMEND
amend_diff=$'--- a/docs/PROJECT_REQUIREMENTS.md\n+++ b/docs/PROJECT_REQUIREMENTS.md\n@@ -1,1 +1,1 @@\n-# Project Requirements\n+# Project Requirements (cost limited)\n'
jq --arg diff "$amend_diff" '
  .decisions[0].amendment = {diff: $diff, confirmed_by: "owner", confirmed_at: "2026-01-02T00:00:01Z"}
  | .amended_requirements = {before: ("a" * 40), after: ("b" * 40)}' \
  "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
sed -i.bak '1s/.*/# Project Requirements (cost limited)/' "$repo/docs/PROJECT_REQUIREMENTS.md" && rm "$repo/docs/PROJECT_REQUIREMENTS.md.bak"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a planning with an amendment of the requirements failed"
}
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "## Requirements amended with the owner's confirmation" "$approval" || fail "the approval does not list the amendments"
grep -Fq "Round 1: M1 [major] Cost is not capped. Considered. Confirmed by the project owner at 2026-01-02T00:00:01Z." "$approval" ||
  fail "the approval does not list the amendment with its finding and the confirmation: $(cat "$approval")"
grep -Fq "  +# Project Requirements (cost limited)" "$approval" || fail "the approval does not show the confirmed diff"
! grep -Fq "AMEND: M1" "$approval" || fail "an amended finding was listed as not adopted"

# A planning whose latest round passed is approved after confirmation; the
# approval lists the rounds and the findings that were not adopted.
repo="$(setup_repo approve)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned"), $(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 FIX_NOW
jq '.decisions[1].decision = "ACCEPT" | .decisions[1].rationale = "The name follows the requirements."' \
  "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
printf '\n## F02 — Offline use\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 2 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a passed planning failed"
}
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "Status: Approved" "$approval" || fail "the approval was not recorded"
grep -Eq '^Planning fingerprint: [0-9a-f]{40}$' "$approval" || fail "the approval lacks the planning fingerprint"
grep -Fq "Round 1, ACCEPT: MIN1 [minor] Vague name" "$approval" || fail "the approval lacks a rejected finding"
grep -Fq "Round 2: PASS" "$approval" || fail "the approval lacks the final round"
grep -Fq "Vague name" "$repo.out" || fail "a rejected finding was not shown before approval"
grep -Fq "git add docs/PROJECT_REQUIREMENTS.md docs/architecture.md docs/roadmap.md docs/decisions docs/PLANNING_APPROVAL.md" "$repo.out" ||
  fail "the commit step does not list the existing planning documents"
grep -Fq "Open the planning PR into main;" "$repo.out" || fail "the next steps do not name the base main"

# The base comes from lib/base.sh, as for a feature: the default of the
# project in .agents/template.conf, and the base that start-planning.sh
# recorded for the branch before that.
base_repo="$(setup_repo other-base)"
printf 'base: develop\n' >>"$base_repo/.agents/template.conf"
add_review "$base_repo" 1 PASS "[]"
run_finish "$base_repo" y || { cat "$base_repo.out" >&2; fail "approving a planning of a project with the base develop failed"; }
grep -Fq "Open the planning PR into develop;" "$base_repo.out" || fail "the next steps do not name the default base develop: $(cat "$base_repo.out")"
grep -Fq "removes this worktree and updates develop" "$base_repo.out" || fail "the cleanup hint does not name the base develop: $(cat "$base_repo.out")"
base_repo="$(setup_repo recorded-base)"
printf 'base: develop\n' >>"$base_repo/.agents/template.conf"
git -C "$base_repo" config branch.planning/project-bootstrap.workflow-base release
add_review "$base_repo" 1 PASS "[]"
run_finish "$base_repo" y || { cat "$base_repo.out" >&2; fail "approving a planning with a recorded base failed"; }
grep -Fq "Open the planning PR into release;" "$base_repo.out" || fail "the next steps do not name the recorded base release"
base_repo="$(setup_repo invalid-base)"
printf 'base: not..valid\n' >>"$base_repo/.agents/template.conf"
add_review "$base_repo" 1 PASS "[]"
expect_refused "$base_repo" "the default base of the project is not a valid branch name"
grep -Fq "not a valid branch name" "$base_repo.out" || fail "an invalid default base was not reported"

# --check reports a current approval, and a stale one after any planning change.
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh approval is not current"
printf 'Unrelated.\n' >"$repo/notes.txt"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "an unrelated change invalidated the approval"
printf '# ADR 001: Storage\n' >"$repo/docs/decisions/001-storage.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "a new ADR did not invalidate the approval"
rm "$repo/docs/decisions/001-storage.md"
printf 'Changed.\n' >>"$repo/docs/architecture.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an architecture change did not invalidate the approval"
repo_without="$(setup_repo no-approval)"
[[ "$(check_status "$repo_without")" -eq 1 ]] || fail "a missing approval was not reported"

# Minor findings that were all rejected or deferred can be approved.
repo="$(setup_repo minor-handled)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name"), $(finding S1 suggestion "Sharing")]"
add_triage "$repo" 1 DEFER
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving with deferred minor findings failed"
}

# Declining records nothing.
repo="$(setup_repo decline)"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" n || fail "declining returned an error"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "a declined approval was recorded"

# Refusals.
repo="$(setup_repo no-review)"
expect_refused "$repo" "there is no planning review"

repo="$(setup_repo stale)"
add_review "$repo" 1 PASS "[]"
printf 'Changed.\n' >>"$repo/docs/roadmap.md"
expect_refused "$repo" "the latest review is stale"

repo="$(setup_repo blocking)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline use is unplanned")]"
add_triage "$repo" 1 ESCALATE
expect_refused "$repo" "the latest review has a major finding"

repo="$(setup_repo undecided)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
expect_refused "$repo" "a minor finding has no approved triage"

repo="$(setup_repo not-applied)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 FIX_NOW
expect_refused "$repo" "a FIX_NOW finding is not applied"

repo="$(setup_repo escalated)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 ESCALATE
expect_refused "$repo" "a finding is escalated"
grep -Fq "Round 1, ESCALATE: MIN1 [minor] Vague name" "$repo.out" || fail "a refusal did not show the escalated finding"
grep -Fq "Rationale: Considered." "$repo.out" || fail "a refusal did not show the rationale"

# An escalation of an earlier round is not resolved by a newer review alone:
# the human confirms its resolution, and the approval records that.
repo="$(setup_repo earlier-escalation)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
printf 'Sharing is out of scope.\n' >>"$repo/docs/PROJECT_REQUIREMENTS.md"
add_review "$repo" 2 PASS "[]"
if run_finish "$repo" $'n\ny'; then
  fail "an earlier escalation that was not confirmed as resolved was approved"
fi
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded with an unresolved earlier escalation"
run_finish "$repo" $'y\ny' || {
  cat "$repo.out" >&2
  fail "approving after confirming an earlier escalation failed"
}
grep -Fq "## Escalations confirmed as resolved" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the confirmed resolution of an earlier escalation was not recorded"

# A planning document that changes while the approval question waits is not approved.
repo="$(setup_repo changes-during-approval)"
add_review "$repo" 1 PASS "[]"
mkfifo "$tmp/answer"
(
  cd "$repo"
  PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh <"$tmp/answer"
) >"$repo.out" 2>&1 &
finisher=$!
exec 3>"$tmp/answer"
for _ in $(seq 1 100); do
  grep -Fq "Approve this planning?" "$repo.out" 2>/dev/null && break
  sleep 0.1
done
printf 'Changed while deciding.\n' >>"$repo/docs/roadmap.md"
echo y >&3
exec 3>&-
status=0
wait "$finisher" || status=$?
[[ "$status" -ne 0 ]] || fail "a planning that changed during the approval question was approved"
[[ ! -e "$repo/docs/PLANNING_APPROVAL.md" ]] || fail "an approval was recorded for a changed planning"

repo="$(setup_repo unapproved-requirements)"
add_review "$repo" 1 PASS "[]"
printf '# Project Requirements\n\nStatus: Draft\n' >"$repo/docs/PROJECT_REQUIREMENTS.md"
expect_refused "$repo" "the requirements are not approved"

repo="$(setup_repo not-planning)"
add_review "$repo" 1 PASS "[]"
git -C "$repo" switch -q -c feature/1-x
expect_refused "$repo" "the branch is not a planning branch"

# The approval of a change cycle records its change request, covers it, and
# names the commit after the change.
repo="$(setup_repo change-cycle)"
mkdir -p "$repo/docs/changes"
printf 'Add a shopping list.\n' >"$repo/docs/changes/project-bootstrap.md"
printf '\n## F02 — Shopping list\n' >>"$repo/docs/roadmap.md"
add_review "$repo" 1 PASS "[]"
run_finish "$repo" y || {
  cat "$repo.out" >&2
  fail "approving a change cycle failed"
}
grep -Fqx "Change request: docs/changes/project-bootstrap.md" "$repo/docs/PLANNING_APPROVAL.md" ||
  fail "the approval does not record the change request"
grep -Fq 'git commit -m "Plan change: project-bootstrap"' "$repo.out" || fail "the commit is not named after the change"
grep -Fq "docs/changes" "$repo.out" || fail "the commit step does not include the change request"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a fresh change approval is not current"

# A later approval names what merged work changed in the architecture since
# the previous one, because it now covers those changes.
later="$(setup_repo later-approval)"
add_review "$later" 1 PASS "[]"
run_finish "$later" y || fail "the first approval failed"
git -C "$later" add -A
git -C "$later" commit -qm "Plan: first approval"
printf '\nThe list is stored locally.\n' >>"$later/docs/architecture.md"
git -C "$later" commit -qam "F03: describe where the list is stored" -m "Issue: #3" -m "Review: round 1, PASS, by codex (model-r)"
printf '\n## F09 — Another feature\n' >>"$later/docs/roadmap.md"
add_review "$later" 2 PASS "[]"
run_finish "$later" y || {
  cat "$later.out" >&2
  fail "the later approval failed"
}
grep -Fqx "## Updates by merged work" "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the later approval does not list the updates by merged work"
grep -Eq '^- [0-9a-f]+ F03: describe where the list is stored \(Issue #3; review: round 1, PASS, by codex \(model-r\)\)$' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the later approval does not name the feature, its Issue, and its review"

# A third approval keeps the entry of the second and adds its own.
git -C "$later" add -A
git -C "$later" commit -qm "Plan: second approval"
printf '\nThe list is sorted.\n' >>"$later/docs/architecture.md"
git -C "$later" commit -qam "F04: describe the order of the list" -m "Issue: #4"
printf '\n## F10 — One more\n' >>"$later/docs/roadmap.md"
add_review "$later" 3 PASS "[]"
run_finish "$later" y || fail "the third approval failed"
grep -Eq '^- [0-9a-f]+ F03: describe where the list is stored ' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the third approval dropped the entry of the second"
grep -Eq '^- [0-9a-f]+ F04: describe the order of the list \(Issue #4\)$' "$later/docs/PLANNING_APPROVAL.md" ||
  fail "the third approval lacks its own entry"
printf 'More.\n' >>"$repo/docs/changes/project-bootstrap.md"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "changing the change request did not invalidate the approval"

# An approval that an earlier version of the workflow amended lists the
# updates by merged work under "Amendments after the approval"; the next
# approval keeps them, under "Updates by merged work".
legacy="$(setup_repo legacy-amendment)"
printf '# Planning Approval\n\nStatus: Approved\nPlanning fingerprint: %s\n\n## Amendments after the approval\n\n- 2026-01-05T00:00:00Z: before the amendment below, merged work had updated the architecture or the ADRs since the approval, each change under its own review:\n  - abc1234 F07: add a cache (Issue #7)\n- 2026-01-05T00:00:00Z, planning/cache: Bound the cache.\n' \
  "$(printf '0%.0s' {1..40})" >"$legacy/docs/PLANNING_APPROVAL.md"
add_review "$legacy" 1 PASS "[]"
run_finish "$legacy" y || { cat "$legacy.out" >&2; fail "approving after an amended approval failed"; }
grep -Fqx -- "- abc1234 F07: add a cache (Issue #7)" "$legacy/docs/PLANNING_APPROVAL.md" ||
  fail "the approval dropped an update by merged work that an amended approval recorded"

# --- An approved planning ----------------------------------------------------
#
# A change to an approved planning is a change cycle; features keep the
# architecture and the ADRs up to date under their own review. There is no
# amendment without a review (finish-planning.sh --amend is gone, #539).

# Creates a repository whose main holds an approved planning, on a new
# planning branch.
setup_approved() {
  local repo
  local fingerprint

  repo="$(setup_repo "$1")"
  git -C "$repo" switch -q main
  printf '# ADR 001: Local storage\n\n## Status\n\nAccepted.\n' >"$repo/docs/decisions/001-local-storage.md"
  fingerprint="$(bash -c 'source "$1/scripts/lib/fingerprint.sh"; source "$1/scripts/lib/planning.sh"
    scratch="$(mktemp -d)"; fingerprint_files "$1" "$scratch" "${PLANNING_SCOPE[@]}"; rm -rf "$scratch"' _ "$repo")"
  printf '# Planning Approval\n\nStatus: Approved\nApproved at: 2026-01-03T00:00:00Z\nFinal review: round 2, PASS, by codex (model-p)\nPlanning fingerprint: %s\n\n## Review rounds\n\n- Round 2: PASS\n' \
    "$fingerprint" >"$repo/docs/PLANNING_APPROVAL.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "Approved planning" >/dev/null
  git -C "$repo" switch -q -c "planning/$1"
  printf '%s\n' "$repo"
}

update_adr() {
  printf '\n## Status\n\nAmended by ADR 002.\n' >>"$1/docs/decisions/001-local-storage.md"
  printf '# ADR 002: Cache\n\nAmends ADR 001.\n' >"$1/docs/decisions/002-cache.md"
  printf '\nA cache sits in front of the storage.\n' >>"$1/docs/architecture.md"
}

# --amend is no option: it prints the usage and changes nothing.
repo="$(setup_approved no-amend)"
update_adr "$repo"
before="$(cat "$repo/docs/PLANNING_APPROVAL.md")"
status=0
(cd "$repo" && printf 'y\n' | PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --amend "A reason.") >"$repo.out" 2>&1 || status=$?
[[ "$status" -eq 2 ]] || { cat "$repo.out" >&2; fail "--amend was not refused with the usage (status $status)"; }
grep -Fq "Usage:" "$repo.out" || fail "--amend did not print the usage"
! grep -Fq -- "--amend" "$repo.out" || fail "the usage still names --amend"
grep -Fq "start-planning.sh <name> --change <file>" "$repo.out" || fail "the usage does not name the change cycle"
[[ "$(cat "$repo/docs/PLANNING_APPROVAL.md")" == "$before" ]] || fail "--amend changed the approval"

# Features keep the architecture and the ADRs up to date. After such a change
# is merged the approval is still current, and the check names the commits.
repo="$(setup_approved feature-updates)"
git -C "$repo" switch -q main
update_adr "$repo"
git -C "$repo" add -A
git -C "$repo" commit -qm "F07: add a cache, with ADR 002" -m "Issue: #7" -m "Review: round 2, PASS, by codex (model-r)"
[[ "$(check_status "$repo")" -eq 0 ]] || fail "a feature that updated the architecture made the approval stale"
(cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check) >"$repo.out" 2>&1
grep -Fq "F07: add a cache, with ADR 002" "$repo.out" || fail "the check did not name the commit that updated the architecture"

# What the product is and which features it gets is changed by a planning
# cycle only: a change to the roadmap or the requirements, by a feature or by
# hand, makes the approval stale, also together with an architecture change.
for document in docs/roadmap.md docs/PROJECT_REQUIREMENTS.md; do
  repo="$(setup_approved "stale-$(basename "$document" .md)")"
  git -C "$repo" switch -q main
  update_adr "$repo"
  printf '\nA change outside a planning cycle.\n' >>"$repo/$document"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "F08: change $document"
  [[ "$(check_status "$repo")" -eq 1 ]] || fail "a change to $document did not make the approval stale"
  (cd "$repo" && PATH="$tmp/bin:$ISOLATED_PATH" ./scripts/finish-planning.sh --check) >"$repo.out" 2>&1 || true
  grep -Fq "only a planning cycle may change those" "$repo.out" || fail "the stale approval did not say what changed"
done

# The starting point is the commit that last changed the approval file, and
# only when the planning documents in it have the recorded fingerprint. A
# commit that changes the file without recording the documents it comes
# with is no approval of them.
repo="$(setup_approved unrecorded)"
git -C "$repo" switch -q main
printf '\nA note.\n' >>"$repo/docs/PLANNING_APPROVAL.md"
update_adr "$repo"
git -C "$repo" add -A
git -C "$repo" commit -qm "Change the approval file and the architecture without recording it"
[[ "$(check_status "$repo")" -eq 1 ]] || fail "an approval that does not match its own commit was trusted"


# --- Decisions on escalated findings ----------------------------------------
#
# finish-planning.sh --resolve records the owner's decision on one escalated
# finding of the latest round, at a terminal only.

# at_terminal <repo> <answer> <command>...: runs the command in the repository
# at a pseudo-terminal, answering <answer> to its question.
at_terminal() {
  local repo="$1"
  local answer="$2"
  local command

  shift 2
  command="cd $(printf '%q' "$repo") && PATH=$(printf '%q' "$tmp/bin:$ISOLATED_PATH") $(printf '%q ' "$@")"
  pty_run "$answer"$'\n' "$command"
}

# resolve <repo> <answer> <argument>...: finish-planning.sh --resolve at a
# terminal. A refusal inside the terminal does not reach the exit status of
# every 'script', so the tests check what was stored.
resolve() {
  local repo="$1"
  local answer="$2"

  shift 2
  at_terminal "$repo" "$answer" ./scripts/finish-planning.sh --resolve "$@" >"$repo.out" 2>&1 || true
}

# resolution <repo> <round> <finding-id>: where the decision is stored, as the
# owner's exception record of the planning (kind planning).
resolution() {
  printf '%s/.agents/exceptions/planning-project-bootstrap-review-%02d-%s.json\n' "$1" "$2" "$3"
}

# A minor finding that the triage escalated: the owner decides it does not
# apply, and the planning can then be approved; the approval lists the decision.
repo="$(setup_repo resolve)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN2 minor "Offline sync is unplanned"), $(finding MIN1 minor "Vague name")]"
add_triage "$repo" 1 ESCALATE
jq '.decisions[1].decision = "ACCEPT"' "$(triage_file "$repo" 1)" >"$tmp/triage.tmp"
mv "$tmp/triage.tmp" "$(triage_file "$repo" 1)"
expect_refused "$repo" "an escalated minor finding has no decision"
grep -Fq -- "--resolve <finding-id>" "$repo.out" || fail "the refusal does not name the command that records a decision"

# Without a terminal nothing is asked and nothing is stored.
if run_finish "$repo" y --resolve MIN2 --type not-applicable --reason "Sync is a non-goal."; then
  fail "a decision was recorded without a terminal"
fi
grep -Fq "must be a terminal" "$repo.out" || fail "the refusal without a terminal does not say why"
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a decision was stored without a terminal"
if run_finish "$repo" y --resolve MIN2 --type not-applicable --reason "Sync is a non-goal." --unattended; then
  fail "a decision was recorded unattended"
fi
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a decision was stored unattended"

# Only an escalated finding of the latest round, with a valid type and reason.
resolve "$repo" y MIN1 --type not-applicable --reason "A reason."
grep -Fq "is not escalated" "$repo.out" || fail "a rejected finding was not refused: $(cat "$repo.out")"
resolve "$repo" y X9 --type not-applicable --reason "A reason."
grep -Fq "has no finding X9" "$repo.out" || fail "an unknown finding was not refused"
resolve "$repo" y MIN2 --type risk-accepted --reason "A reason."
grep -Fq "must be not-applicable or accepted" "$repo.out" || fail "an unknown type was not refused"
resolve "$repo" y MIN2 --type accepted --reason " "
grep -Fq "needs a reason" "$repo.out" || fail "an empty reason was not refused"
compgen -G "$repo/.agents/exceptions/*.json" >/dev/null && fail "a refused decision was stored"

# Declining stores nothing.
resolve "$repo" n MIN2 --type not-applicable --reason "Sync is a non-goal."
grep -Fq "Offline sync is unplanned" "$repo.out" || fail "the finding was not shown before the question"
[[ ! -e "$(resolution "$repo" 1 MIN2)" ]] || fail "a declined decision was stored"

resolve "$repo" y MIN2 --type not-applicable --reason "Sync is a non-goal of the requirements."
record="$(resolution "$repo" 1 MIN2)"
[[ -f "$record" ]] || { cat "$repo.out" >&2; fail "the decision was not stored"; }
jq -e --arg sha "$(sha256sum "$repo/$reviews/planning-project-bootstrap-review-01.json" | cut -c1-64)" '
  .schema == "exception/v1" and .kind == "planning" and .type == "not-applicable" and .round == 1 and .finding_id == "MIN2"
  and .finding_severity == "minor" and .reason == "Sync is a non-goal of the requirements." and .account == "owner-login"
  and .review == ".agents/reviews/planning-project-bootstrap-review-01.json" and .review_sha256 == $sha
  and .planner_rationale == "Considered."' "$record" >/dev/null ||
  fail "the stored decision lacks its fields: $(cat "$record")"
grep -Fq '"planner_rationale": "Considered."' "$repo.out" || fail "the record was not shown as it is stored"
resolve "$repo" y MIN2 --type accepted --reason "Again."
grep -Fq "exists already" "$repo.out" || fail "a second decision on the same finding was not refused"
[[ "$(jq -r .type "$record")" == "not-applicable" ]] || fail "a second decision replaced the first"

run_finish "$repo" y || { cat "$repo.out" >&2; fail "a planning whose escalation was decided was not approved"; }
grep -Fq "Your decision: not-applicable, Sync is a non-goal of the requirements." "$repo.out" ||
  fail "the decision was not shown with the findings"
approval="$repo/docs/PLANNING_APPROVAL.md"
grep -Fqx "## Escalations resolved by the owner's decision" "$approval" || fail "the approval does not list the decisions"
grep -Eq "^- Round 1: MIN2 \[minor\] Offline sync is unplanned\. Not applicable, decided by the project owner \(owner-login\) at [0-9T:Z-]+: Sync is a non-goal of the requirements\.$" "$approval" ||
  fail "the approval does not record the decision: $(cat "$approval")"

# A decision is for a minor finding only: an escalated major or critical
# finding is refused with the severity of the review, and nothing is recorded.
repo="$(setup_repo resolve-blocking)"
add_review "$repo" 1 CHANGES_REQUIRED "[$(finding M1 major "Offline sync is unplanned"), $(finding C1 critical "No data model")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y M1 --type not-applicable --reason "Sync is a non-goal."
grep -Fq "M1 of round 1 is major in the review" "$repo.out" || fail "an escalated major finding was not refused: $(cat "$repo.out")"
grep -Fq "a new review round after the planning documents changed" "$repo.out" && grep -Fq "change of the requirements" "$repo.out" ||
  fail "the refusal of a major finding does not name the ways that remain"
resolve "$repo" y C1 --type accepted --reason "The model follows later."
grep -Fq "C1 of round 1 is critical in the review" "$repo.out" || fail "an escalated critical finding was not refused: $(cat "$repo.out")"
compgen -G "$repo/.agents/exceptions/*.json" >/dev/null && fail "a decision on a major or critical finding was stored"
expect_refused "$repo" "escalated major and critical findings block"
grep -Fq "2 critical or major finding(s)" "$repo.out" || fail "the escalated blocking findings were not reported"
# A record written by hand for a major finding resolves nothing.
review="$repo/$reviews/planning-project-bootstrap-review-01.json"
mkdir -p "$repo/.agents/exceptions"
jq --arg sha "$(sha256sum "$review" | cut -c1-64)" '{
  schema: "exception/v1", kind: "planning", type: "risk-accepted", reason: "By hand.", evidence: null,
  account: "owner-login", directed_at: "2026-01-02T00:00:00Z",
  review: ".agents/reviews/planning-project-bootstrap-review-01.json", review_sha256: $sha, round,
  finding_id: "M1", finding_title: "Offline sync is unplanned", finding_severity: "major",
  reviewed_tree, merge_base, planner_rationale: "Considered."}' "$review" >"$(resolution "$repo" 1 M1)"
expect_refused "$repo" "a decision written by hand for a major finding"
grep -Fq "finding M1 is major: a planning record resolves a minor finding only" "$repo.out" ||
  fail "the hand-written decision on a major finding was not reported as invalid: $(cat "$repo.out")"

# A decision is bound to its review as it is: an edited review voids it.
repo="$(setup_repo resolve-edited)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y MIN1 --type accepted --reason "Sharing stays open for now."
[[ -f "$(resolution "$repo" 1 MIN1)" ]] || { cat "$repo.out" >&2; fail "the decision on a minor escalation was not stored"; }
jq '.limitations = "Edited."' "$repo/$reviews/planning-project-bootstrap-review-01.json" >"$tmp/review.tmp"
mv "$tmp/review.tmp" "$repo/$reviews/planning-project-bootstrap-review-01.json"
expect_refused "$repo" "the review was edited after the decision"
grep -Fq "the review artifact changed after the exception was recorded" "$repo.out" || fail "the void decision was not reported: $(cat "$repo.out")"

# A decision is stale once the documents change: the review it belongs to is
# stale, and a new round that raises the finding again needs its own decision.
repo="$(setup_repo resolve-stale)"
add_review "$repo" 1 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is open")]"
add_triage "$repo" 1 ESCALATE
resolve "$repo" y MIN1 --type accepted --reason "Sharing stays open for now."
[[ -f "$(resolution "$repo" 1 MIN1)" ]] || fail "the decision was not stored"
printf '\n## F02 — Sharing\n' >>"$repo/docs/roadmap.md"
expect_refused "$repo" "the documents changed after the decision"
grep -Fq "is stale" "$repo.out" || fail "the stale review was not reported"
resolve "$repo" y MIN1 --type accepted --reason "Again."
grep -Fq "is stale" "$repo.out" || fail "a decision on a stale review was not refused"
add_review "$repo" 2 PASS_WITH_MINOR_FINDINGS "[$(finding MIN1 minor "Sharing scope is still open")]"
add_triage "$repo" 2 ESCALATE
expect_refused "$repo" "a later round escalated the finding again"
grep -Fq "without your decision: MIN1" "$repo.out" || fail "the new escalation was not reported: $(cat "$repo.out")"
# The decision of round 1 still resolves the escalation of round 1, without
# the question for earlier escalations.
resolve "$repo" y MIN1 --type not-applicable --reason "Sharing is decided in F02."
run_finish "$repo" y || { cat "$repo.out" >&2; fail "approving after a decision in each round failed"; }
if grep -Fq "Escalated in earlier rounds:" "$repo.out"; then fail "a decided earlier escalation was asked about again"; fi
[[ "$(grep -c '^- Round [12]: MIN1 ' "$repo/docs/PLANNING_APPROVAL.md")" -eq 2 ]] ||
  fail "the approval does not list the decision of each round"

echo "finish-planning tests passed"
