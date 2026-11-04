---
title: "Verification and completion"
description: "Checks, evidence reuse, budgets and the completion gate."
order: 6
---

## "The agent says done" against "verified done"

A coding agent ends a session by saying it is done. That is a claim: the agent may have skipped a criterion, misread one, or stopped when its time ran out. In Codeyard a feature counts as done only when three things hold, and a script checks each before the commit:

- **The checks pass** for exactly the content that is committed: your tests, linters and builds, run by `./scripts/verify.sh`.
- **The completion record** names every acceptance criterion of the Issue with its status and the evidence that shows it.
- **An independent reviewer** of another provider checked those claims against the code and the tests, and no critical or major finding is left. The one exception is a low-risk feature that your risk policy lets skip the review: it is committed as not reviewed, and its merge needs your approval.

### One criterion and its evidence

A real example: Issue [#265](https://github.com/taspinar/agent-codeyard/issues/265) changed the About page of this site, and one of its acceptance criteria was that the social preview image states the profile condition. The completion record, which [pull request 266](https://github.com/taspinar/agent-codeyard/pull/266) carries in its description, says:

```text
- met: The social preview note states the profile condition.
  (documentation/og-image.svg reads 'low risk may skip review under the
  light profile'; documentation/public/og.png re-rendered with node
  og-image.mjs and inspected: the line fits under the bypass without overlap)
```

The criterion is in the words of the Issue, the status is `met`, and the evidence names the file, what it holds, and the command that produced it. The reviewer reads that claim against the diff; a claim the code does not support comes back as a finding. The rest of this page describes the checks and the record in detail.

<a id="verification"></a>

## Project checks and workflow checks

`./scripts/verify.sh` runs two sets of checks:

- **Your project's checks**, listed in [`scripts/verify.conf`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/verify.conf), one command per line: tests, linters, builds. They always run. A check declared as a budget (`<name> budget: <command>`) measures something against a target: over the target it is reported as `BUDGET` with its output, the verification still passes, and nothing repairs it; the reviewer, the commit, and the pull request show the measurement for you to decide on. Every check is timed, and a line `budget-seconds: <n>` sets a target for the duration of all checks of the file, reported the same way with the slowest checks when a run exceeds it. The file ships with the checks of the template itself, and with no budget check; you replace them with your own.
- **Tests of the workflow scripts**, listed in [`scripts/verify-workflow.conf`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/verify-workflow.conf). They protect the workflow, not your application, and run locally only when a workflow file changed. `./scripts/verify.sh --all` always runs them, and CI uses that. The file ships `budget-seconds: 600`, a target for the duration of these tests that fails nothing.

Checks can have a group, such as `code` or `build`. `./scripts/verify.sh --only code` runs one group, for example while you work on a part, or in a CI job of its own. A partial run is never a verification: nothing is recorded as passed, and the review and the commit still run every check.

The template's own project checks include `docs-references`, which runs `./scripts/check-docs.sh`: in the tracked Markdown files, every relative link and every path in backticks that names a file of the repository must exist, so that the documentation does not point at a file that was renamed or removed. External links, anchors, paths with a placeholder, and files that Git ignores are not checked; the details are under "References in the documentation" in [`docs/development.md`](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md). A project keeps the check in its `scripts/verify.conf` or removes it.

A successful run is recorded for the exact content of the working tree that was checked, together with which checks ran. With `--reuse`, a later step skips the run only when that content is unchanged and the recorded run covered every check that is required now: a run that skipped the workflow tests does not count where they are required. Any change to the content means the checks run again.

A review belongs to the content that was reviewed: a change to that content requires another review. New commits on the base branch alone do not make a review outdated.

Separately, if the point where the feature branched off its base branch has changed, for example after you merged the base branch into the feature, any later review has to cover the complete feature and cannot be limited to the recent changes.

The guidance on what makes a check worth having is in [`docs/evaluation.md`](https://github.com/taspinar/agent-codeyard/blob/main/docs/evaluation.md): checks that protect behavior matter more than the number of tests.

## Completion is recorded per criterion

Before ending each session, the implementer writes `.agents/completion/<issue>.json`, with schema `completion/v1`, a status, evidence for every acceptance criterion and uncovered plan step, and a `remaining` list. Its handoff note must agree.

| Status | Meaning |
| --- | --- |
| `complete` | Every criterion is met or not applicable; nothing remains |
| `awaiting_evidence` | All implementation work is done; evidence can only appear at a later gate |
| `partial` | Work remains, even if the session ended successfully |
| `blocked` | A human decision is needed; questions are in the handoff note |

Criterion statuses are `met`, `not_met`, `not_applicable`, or `pending`. The default gate is `implementation`: evidence must exist now. Only `pr_ci`, `owner_approval`, or `post_merge` can be pending; the evidence says when it will exist. Owner approval is never claimed as met by the implementer. A budget measurement or a partial check cannot be evidence of a met criterion.

The complete-feature reviewer checks those claims against the diff and tests. Finish proceeds only on `complete` or `awaiting_evidence`, with no remaining work in the handoff. `--partial` is an explicit owner choice to commit unfinished work; publication then makes a draft and leaves the Issue open. A pending `post_merge` criterion keeps the Issue open after publication; record its evidence with `./scripts/record-post-merge.sh <issue> "<criterion>" "<evidence>"` after the merge.

## Partial checks and budgets

`verification: groups <group>...` can apply to any risk level whose policy sets it, for intermediate repair rounds. The first and final complete review and the commit still need full verification. `--only` refuses `--reuse` and records no pass; a failed partial run invalidates a prior pass. CI split across groups must cover every group, including `default`.

The template's CI is one job, and that stays the default. A project whose groups are independent and expensive can split its CI instead: one job per group, a consumer that waits for its producer and refuses an artifact of another run, and one aggregate required check `verify` that passes only when every group job succeeded. A failed, cancelled, skipped, or missing job fails it. [`scripts/check-ci-groups.sh`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/check-ci-groups.sh) checks the mapping and the results. The mapping is declared, not read from commands: each group job names its group in `env: VERIFY_GROUP`, and each check that runs a test partition names it as `partition <file>`; the script checks only those declarations. [`docs/examples/parallel-ci.yml`](https://github.com/taspinar/agent-codeyard/blob/main/docs/examples/parallel-ci.yml) is an example to adapt. Parallel jobs shorten the wait for the result, not the compute, which grows with every job; for a fast verification or one dominated by a single group they add nothing. See [the recipe](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#a-parallel-ci).

The budget syntax is `<name> [<group>] budget: <command>`. Its nonzero result is a measurement, not a failed required check. Neither a budget nor a duration target should trigger automatic repair. See [the verification reference](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#configuring-verification).
