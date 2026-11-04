# Evaluation

Substantial changes are evaluated against:
- **Correctness:** acceptance criteria and expected behavior.
- **Tests:** appropriate unit/integration/e2e coverage.
- **Architecture:** boundaries and accepted ADRs remain intact.
- **Security:** authorization, validation, secrets, and least privilege.
- **Reliability:** failure paths, retries/timeouts where relevant.
- **Maintainability:** focused changes, reuse of established patterns, no unnecessary complexity.
- **Buildability:** `./scripts/verify.sh` passes.

Review depth should follow `.agents/policies/autonomy.md`.

## Meaningful tests

Tests exist to catch behavior that must not regress. Add or keep a test when it
protects:

- an approval or confirmation gate;
- a scope or permission boundary;
- the ordering of workflow phases;
- propagation of a failure to the caller;
- an acceptance criterion of the Issue.

Do not add tests that only pin message wording, formatting, or layout. Assert
on output text only as far as needed to tell one failure class from another.
A test that would still pass after the behavior it names is broken is not
meaningful; fix or remove it.

Reviewers apply the same principle: report missing coverage of the behaviors
above, and report tests that only fix wording as unnecessary.

## Review findings

When independent review is required, run it against the complete implementation
before committing, including uncommitted working-tree changes. Then run
`./scripts/triage-review.sh` against the explicit review artifact and approve or
decline the proposed decisions.

- **Critical / Major:** classify as `FIX_NOW`, resolve before merge, and obtain
  a re-review when independent confirmation is needed.
- **Minor:** classify as `FIX_NOW`, `DEFER`, or `ACCEPT`. Deferral creates a
  linked follow-up Issue after human approval.
- **Suggestion:** classify explicitly; it may be deferred when worthwhile or
  accepted with a rationale.

The approved `.agents/triage/*.json` artifact is the source of truth for these
decisions. Use `./scripts/apply-triage.sh` to hand only its `FIX_NOW` scope to a
write-capable implementation agent. The helper verifies the result but does not
commit it. The fixes make the review stale, so run a new review round before
committing. With `--changes` a round confirms a small, local fix; the round a
feature is committed on reviews the complete feature against the Issue.

## Measuring the fix rounds

Whether the class search and the check before the change of a fix session
(Issue #292, see "Owner-directed triage" in `docs/development.md`) make fix rounds
cheaper is a follow-up evaluation, not part of the change that introduced
them: it compares features before and after that change, so its data can exist
only once at least ten features have gone through review on the new contract.

**Baseline.** The study behind Issue #292: in this repository 40 findings of
round 2 and later in 14 features, in Physics by Construction 25 in 17, of
which *unresolved* plus *introduced by a repair* made up 24 of 40 and 9 of 25
(with proven origin only, 18 of 32 and 7 of 17). Add the features since
2026-10-20 that have review comments, since main already had approval
requests, the claims fingerprint, the comment filter, and earlier decisions
for later reviewers, which the studied commits did not.

**Per feature, before and after**, with the classification of the study, and
where each figure comes from:

- wall time from the first review start to PASS, and the number of rounds to
  PASS: the run records (`step` and `finding` events, `round`) and
  `./scripts/report-runs.sh <issue>`;
- tokens and cost: the `usage` of the `agent-call` events in the run records;
- repair work: the `apply-triage.sh` sessions (`agent-call` with role
  `triage-implementer`) and the size of each repair diff, to see that the
  scope does not grow;
- unjustified blocks: findings later classified as invalid, and the lines
  `refuted` under `## Triage <triage file name>` in the handoff note;
- the later findings by category, as absolute counts next to the share, since
  the share of one category can fall only because another rises.

A returned finding or a refused check is an intercepted inconsistency, not yet
a proven saving.
