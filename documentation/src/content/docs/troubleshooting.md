---
title: "Troubleshooting"
description: "Find the symptom or the message you see, and the first fix to try."
order: 9
---

Find what you see below: a symptom, or the words a script printed. Each entry starts with the one fix to try first; the text after it says why. A script that stops always prints its reason and, where there is one, the command that continues.

<a id="if-something-goes-wrong"></a>

## Setup and agents

### "… is not installed", or GitHub is not signed in

**First fix:** run `./scripts/doctor.sh` and do what it names.

It checks the tools, the agents of `.agents/agents.conf`, your Git identity and whether you can push, and prints an install or sign-in command for what is missing.

### An agent does not start, or rejects the model

**First fix:** check the line of that role in `.agents/agents.conf`, and sign in to the agent's own command-line tool.

The workflow passes the model name on as you wrote it and never replaces it, so a typo in the model reaches the agent as it is.

### "This is a usage limit of …, not a defect"

**First fix:** run the same step again after the time the provider names.

The provider refused the session because a usage or rate limit is reached; the script shows the provider's own message. An unattended run retries the step and writes the limit into its log.

### "the reviewer would use …, the provider the implementer ran with"

**First fix:** give the `reviewer` role another provider in `.agents/agents.conf`, or pass `--agent` and `--model` to `review-feature.sh`.

The reviewer must come from another provider than the implementer, at every risk level. The message also appears as "the reviewer and the implementer would both use …". See <a href="../agent-roles/#roles">Agent roles and models</a>.

## Checks and reviews

### A check fails

**First fix:** read the output that `./scripts/verify.sh` prints for the failing check, and repair that check.

A feature cannot be reviewed or committed until the checks pass. To have it reviewed anyway, `review-feature.sh <issue> --unverified "<reason>"` records the reason; it is an exception, not a pass, and the commit still needs every check.

### "BUSY  the slot for heavy verification of this machine is held by …"

**First fix:** wait until the run it names has ended, then run the same command again.

Another session or worktree is running the checks that your project marked `heavy:` in `scripts/verify.conf`. Nothing was checked and nothing is wrong with your code; the exit status is 75. To stop the holder instead, check the PID it names with `ps -p <pid> -o pid,lstart,args` and stop exactly that process, not every process with a matching name. When the line says that the holder's process has ended but its check (a process group) still runs, a check of a crashed run is still busy: the slot frees itself when it ends, or stop exactly that group with `kill -- -<group>` after checking it with `ps -o pid,pgid,args -g <group>`. When the line adds that the holder's process "cannot be checked from this run", its owner is another user whose processes this run cannot see: ask that user, or the owner of the shared `VERIFY_LOCK_DIR`, whether the run still exists before removing the lock directory by hand. See <a href="../verification-and-completion/#heavy-checks-on-a-shared-machine">heavy checks on a shared machine</a>.

### "the latest review (…) is stale: the code changed after it"

**First fix:** run `./scripts/review-feature.sh <issue>` again.

A review belongs to the exact content it reviewed. New commits on the base branch alone do not make it stale; a change of the feature does. See <a href="../verification-and-completion/#verification">project checks and workflow checks</a>.

### "the latest review (round …) covers only the changes since round …"

**First fix:** run `./scripts/review-feature.sh <issue>` without `--changes`.

A feature is committed only on a review of the complete feature.

### A review has findings

**First fix:** run `./scripts/triage-review.sh <review>` and decide on each finding.

Each finding gets one recorded decision: fix it now (`FIX_NOW`), defer it to a follow-up Issue (`DEFER`), or accept it with a reason (`ACCEPT`). Critical and major findings are always fixed. See <a href="../detailed-workflow/#step-triage">decide on the findings</a>.

## Planning

### "the planning has not been approved", or "a planning document changed after the planning was approved"

**First fix:** for a new plan, approve it with `./scripts/finish-planning.sh` in its planning worktree and merge it; for a plan you changed, go through <a href="../detailed-workflow/#step-change">the change process</a>.

`create-feature-issue.sh` creates no Issue from a plan whose approval is missing or stale. You do not edit an approved plan by hand: a change request goes through the review and your approval again.

### "the latest planning review (…) is stale"

**First fix:** run `./scripts/review-planning.sh` again.

A planning document changed after the review.

<a id="handles"></a>
<a id="situations-the-workflow-handles"></a>

## Stopped or interrupted runs

### A session or a run was interrupted

**First fix:** when you work step by step, resume the interrupted step: `./scripts/start-feature.sh <issue> --resume`. When an unattended run was interrupted, run `./scripts/run-feature.sh <issue>` again; it continues where the feature stands.

The implementer keeps a handoff note with what is done and what remains, so the work continues without the earlier conversation. An unattended run retries a temporary failure itself, such as a short loss of the network while it reads the Issue.

### "an agent needs a decision; its question is in the handoff note"

**First fix:** answer the question in `.agents/handoffs/<issue>.md` or in a comment on the Issue, then run the feature again.

The implementer asks before it invents an answer to a decision that the Issue, the requirements and the architecture leave open. The next session reads your answer and implements. See <a href="../detailed-workflow/#step-implement">implement the feature</a>.

### "the implementer wrote no completion record", or "the handoff note … lists remaining work"

**First fix:** resume the feature: `./scripts/start-feature.sh <issue> --resume`, or `run-feature.sh <issue>` again.

The commit needs a completion record that says complete or awaiting evidence, and a handoff note without remaining work. Under "Remaining", `None.` may carry an explanation after it (`None. The owner approves on GitHub.`); `None of the tests pass` is work, and the message names the line. A session that ended is not a finished feature. To commit unfinished work on purpose, `finish-feature.sh` takes `--partial`. See <a href="../verification-and-completion/">Verification and completion</a>.

### "could not read the comments of Issue #…"

**First fix:** check that GitHub is reachable and `gh` is signed in, then run the step again.

The implementer does not start without your comments on the Issue, since it would work without your clarifications. An Issue that does not exist, or a refusal, stops at once with its reason.

## Commit and publish

### "… must run on feature/<issue>-*. Current branch: …"

**First fix:** go to the worktree of the feature, whose path `start-feature.sh` printed, and run the script there.

### The base branch moved after the feature was finished

**First fix:** merge the base branch into the feature branch and publish again: `git merge origin/main`, then `./scripts/publish-feature.sh <issue>`.

The pull request is still described by the commit of the finished feature and still closes the Issue. So does a commit after the merge that fixes only what the merge brought in, without touching the files of the feature, a protected path, or a feature that needs the owner's approval. Any other commit after the finish needs a new finish first; the pull request names that commit and what to do. Once the base was merged in, a later review has to cover the complete feature, not only the recent changes.
