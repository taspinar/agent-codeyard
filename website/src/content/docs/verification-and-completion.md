---
title: "Verification and completion"
description: "When a feature counts as done: the checks, the completion record per acceptance criterion, its statuses, and the advanced settings of the verification."
order: 6
---

## "The agent says done" against "verified done"

A coding agent ends a session by saying it is done. That is a claim: the agent may have skipped a criterion, misread one, or stopped when its time ran out. In Codeyard a feature counts as done only when three things hold, and a script checks each before the commit:

- **The checks pass** for exactly the content that is committed: your tests, linters and builds, run by `./scripts/verify.sh`.
- **The completion record** names every acceptance criterion of the Issue with its status and the evidence that shows it.
- **An independent reviewer** of another provider checked those claims against the code and the tests, and no critical or major finding is left. The one exception is a low-risk feature that your risk policy lets skip the review: it is committed as not reviewed, and its merge needs your approval.

### One criterion and its evidence

**Illustrative example.** A gym's member application gets one function: trainers record attendance for their classes; members see their own training history. One of the agreements is that a member sees only their own history, and the check for it is that a member who requests another member's history is refused; the check runs with the feature. In the completion record the criterion could read:

```text
- met: A member sees only their own training history.
  (test "a member who requests another member's history is refused",
  run by ./scripts/verify.sh, which passed for this content)
```

The criterion is in the words of the Issue, the status is `met`, and the evidence names the check that shows it. The pass is evidence about what that check examines: one member asking for another member's history, not every way of reaching the data. The reviewer reads the claim against the diff; a claim the code does not support comes back as a finding.

**A real record.** Issue [#265](https://github.com/taspinar/agent-codeyard/issues/265) changed the About page of this site, and one of its acceptance criteria was that the social preview image states the profile condition. The completion record, which [pull request 266](https://github.com/taspinar/agent-codeyard/pull/266) carries in its description, says:

```text
- met: The social preview note states the profile condition.
  (website/og-image.svg reads 'low risk may skip review under the
  light profile'; website/public/og.png re-rendered with node
  og-image.mjs and inspected: the line fits under the bypass without overlap)
```

The evidence names the file, what it holds, and the command that produced it.

## Completion is recorded per criterion

Before ending each session, the implementer writes `.agents/completion/<issue>.json`, with schema `completion/v1`, a status, evidence for every acceptance criterion and uncovered plan step, and a `remaining` list. Its handoff note must agree: remaining work listed there counts as not done.

The record has one of four statuses:

- `complete`: every criterion is met or not applicable; nothing remains. Next: the review, the commit, and a pull request that closes the Issue.
- `awaiting_evidence`: all implementation work is done; evidence can only appear at a later gate. Next: the review, the commit and the pull request; when evidence is pending after the merge, the Issue stays open until it is recorded.
- `partial`: work remains, even if the session ended successfully. Next: the commit is refused; an unattended run starts the implementer again.
- `blocked`: a human decision is needed; the questions are in the handoff note. Next: the run stops for you.

Criterion statuses are `met`, `not_met`, `not_applicable`, or `pending`. Each criterion has a gate, the moment its evidence can exist:

- `implementation`, the default: the evidence exists now, before the commit. Such a criterion cannot be `pending`.
- `pr_ci`: the evidence is the CI result of the pull request.
- `owner_approval`: the evidence is your approval on GitHub, before the merge. Such a criterion is `pending` or `not_applicable`, never `met`: the implementer cannot claim your approval.
- `post_merge`: the evidence exists on the default branch after the merge.

Only a criterion of the last three gates may be `pending`, and its evidence says when it will exist. A budget measurement or a partial check cannot be evidence of a met criterion.

The complete-feature reviewer checks those claims against the diff and tests. Finish proceeds only on `complete` or `awaiting_evidence`, with no remaining work in the handoff.

A criterion the reviewer could not check at all, such as one that needs a service it cannot reach, is not confirmed by the review. The reviewer names it apart from its findings, and the commit message and the pull request list it under **Not confirmed by the review**, next to the merge approval. When the completion record calls such a criterion `met`, the merge needs your approval, with the reason "the review could not confirm: …". See [the reference](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#review-and-triage-data).

**The exceptions, exactly:**

- `--partial` is an explicit owner choice to commit unfinished work; publication then makes a draft and leaves the Issue open.
- A pending `post_merge` criterion keeps the Issue open after publication; record its evidence with `./scripts/record-post-merge.sh <issue> "<criterion>" "<evidence>"` after the merge.
- GitHub closes an Issue from `Closes #<n>` only on a merge into the default branch: for a feature whose base is another branch, such as `develop`, publication says so, and `./scripts/cleanup-worktree.sh <issue>` closes the Issue after the merge, with a comment that names the pull request and the merge commit.

<a id="verification"></a>

## Project checks and workflow checks

`./scripts/verify.sh` runs two sets of checks:

- **Your project's checks**, listed in [`scripts/verify.conf`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/verify.conf), one command per line: tests, linters, builds. They always run. The file ships with the checks of the template itself, and with no budget check; you replace them with your own.
- **Tests of the workflow scripts**, listed in [`scripts/verify-workflow.conf`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/verify-workflow.conf). They protect the workflow, not your application, and run locally only when a workflow file changed. `./scripts/verify.sh --all` always runs them, and CI uses that. The file ships `budget-seconds: 600`, a target for the duration of these tests that fails nothing (<a href="#partial-checks-and-budgets">budgets</a>). They need nothing of your project but the workflow's files, so they pass in an adopted project with its own CI, ADRs, baseline, and ignore rules; one of them runs all the others in such a fixture project to keep it so.

A successful run is recorded for the exact content of the working tree that was checked, together with which checks ran. With `--reuse`, a later step skips the run only when that content is unchanged and the recorded run covered every check that is required now: a run that skipped the workflow tests does not count where they are required. Any change to the content means the checks run again.

A review belongs to the content that was reviewed: a change to that content requires another review. New commits on the base branch alone do not make a review outdated.

Separately, if the point where the feature branched off its base branch has changed, for example after you merged the base branch into the feature, any later review has to cover the complete feature and cannot be limited to the recent changes.

The template's own project checks include `docs-references`, which runs `./scripts/check-docs.sh`: in the tracked Markdown files, every relative link and every path in backticks that names a file of the repository must exist, so that the documentation does not point at a file that was renamed or removed. External links, anchors, paths with a placeholder, and files that Git ignores are not checked; the details are under "References in the documentation" in [`docs/development.md`](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md). A project keeps the check in its `scripts/verify.conf` or removes it.

The guidance on what makes a check worth having is in [`docs/evaluation.md`](https://github.com/taspinar/agent-codeyard/blob/main/docs/evaluation.md): checks that protect behavior matter more than the number of tests.

<a id="advanced"></a>

## Advanced settings

You do not need these to start. They matter when the checks get slow, when an adopted repository has failing checks, or when several sessions share one machine.

### Partial checks and budgets

Checks can have a group, such as `code` or `build`. `./scripts/verify.sh --only code` runs one group, for example while you work on a part, or in a CI job of its own. A partial run is never a verification: nothing is recorded as passed, and the review and the commit still run every check.

`verification: groups <group>...` can apply to any risk level whose policy sets it, for intermediate repair rounds. The first and final complete review and the commit still need full verification. `--only` refuses `--reuse` and records no pass; a failed partial run invalidates a prior pass. CI split across groups must cover every group, including `default`.

A check declared as a budget (`<name> budget: <command>`) measures something against a target: over the target it is reported as `BUDGET` with its output, the verification still passes, and nothing repairs it; the reviewer, the commit, and the pull request show the measurement for you to decide on. The full syntax is `<name> [<group>] budget: <command>`. Its nonzero result is a measurement, not a failed required check. Every check is timed, and a line `budget-seconds: <n>` sets a target for the duration of all checks of the file, reported the same way with the slowest checks when a run exceeds it. Neither a budget nor a duration target should trigger automatic repair. See [the verification reference](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#configuring-verification).

<a id="parallel-ci"></a>

### A parallel CI

The template's CI is one job, and that stays the default. A project whose groups are independent and expensive can split its CI instead: one job per group, a consumer that waits for its producer and refuses an artifact of another run, and one aggregate required check `verify` that passes only when every group job succeeded. A failed, cancelled, skipped, or missing job fails it. [`scripts/check-ci-groups.sh`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/check-ci-groups.sh) checks the mapping and the results. The mapping is declared, not read from commands: each group job names its group in `env: VERIFY_GROUP`, and each check that runs a test partition names it as `partition <file>`; the script checks only those declarations. [`docs/examples/parallel-ci.yml`](https://github.com/taspinar/agent-codeyard/blob/main/docs/examples/parallel-ci.yml) is an example to adapt. Parallel jobs shorten the wait for the result, not the compute, which grows with every job; for a fast verification or one dominated by a single group they add nothing. See [the recipe](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#a-parallel-ci).

### Failures that existed before the adoption

A repository that <a href="../adopting/">adopted the workflow</a> may have checks that fail before any change. `./scripts/verify.sh --baseline`, started once by the owner, records how each check ended; it is never a passing verification. Afterwards a check that failed in the baseline and still fails is shown as `KNOWN`, with its name, apart from a regression of a check that passed. Both fail the verification. Only an exception the owner writes into `scripts/verify.conf`, `accepted-failure: <check> <reason>`, shows the failure as `ACCEPTED` and lets the verification pass; adding one needs the owner's approval at the merge. See [the reference](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#the-baseline-of-an-adopted-project).

An exception of a whole check hides every new failure inside it. For a check that runs per file, such as a formatter with a backlog of hundreds of files, the exception can be scoped instead. `accepted-failure: <check> changed-files exit 1 <command>` runs `<command>` on the files the feature adds or changes since its base, and those must pass. `accepted-failure: <check> recorded exit 1` compares the failures the check prints, one per line, with the list `.agents/accepted-failures/<check>`: a failure that is not listed, or one of a changed file, fails. Within its scope the failure shows as `SCOPED`, and a listed failure that no longer occurs as `FIXED`, so that the list shrinks; an entry that the list did not hold at the feature's base fails, since the list may only shrink, and a change of the list needs the owner's approval like the baseline. `exit 1` declares the status with which the check completed with failures, such as 1 of prettier, whose 2 is a problem of prettier itself; there is no default. Either form applies only to a check that ended with a declared status: one that ended with another, could not run on (status 126 or 127), was killed by a signal, or timed out fails the verification, and nothing it printed counts as `FIXED`. See [scoping an accepted failure](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#scoping-an-accepted-failure).

### Heavy checks on a shared machine

Worktrees share the machine. When two sessions run a browser suite at the same time, a check can time out for no fault of the code. A line `heavy: <check>...` in `scripts/verify.conf` names the checks that need the machine to themselves; without it, nothing is locked.

- **The slot.** A run that starts such a check first takes the one slot of the machine, outside every worktree (`/tmp/agentic-verify-<uid>`, or `VERIFY_LOCK_DIR`), and holds it until it ends. Light checks (`--only <group>` without a heavy check) still run.
- **A busy machine.** A competing run shows `BUSY` with the holder's run, PID, and worktree, runs nothing, records nothing, and exits with status 75: the machine is busy, the code is not at fault, and `run-feature.sh` stops instead of starting a repair.
- **Release and recovery.** The slot is released on exit and on `Ctrl-C` or `SIGTERM`, after the check that is running has been stopped. Each check of the holder runs in a process group of its own that the lock records, so a lock left by a crash is removed by the next run only when the holder is confirmed gone and no process of that group remains: a check that outlives its crashed run, or a holder that cannot be inspected, such as a process of another user, keeps the slot busy.
- **Stopping a holder.** Check its PID with `ps -p <pid>` and stop that process, never with a match on its name such as `pkill -f verify.sh`. <a href="../troubleshooting/#busy--the-slot-for-heavy-verification-of-this-machine-is-held-by-">Troubleshooting</a> has the steps.

See [heavy checks](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#heavy-checks-and-the-machine-wide-slot).
