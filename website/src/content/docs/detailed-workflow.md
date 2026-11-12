---
title: "How the workflow works"
description: "The workflow in daily use: step by step or unattended, resuming a feature, changing the plan, what each step is for, and what to do when you disagree."
order: 3
---

This page is the manual for daily use: which way to run a feature, how to continue one that stopped, what to do when the plan changes, and what each step is for. For a first look at the route, with an illustrative example, watch the <a href="../#demo">demo on the home page</a>; <a href="#workflow-map">the workflow as a map</a> shows every step and exception on one drawing. For the exact command of a step, what goes in and comes out, and when it stops or retries, use the <a href="#workflow-reference">workflow reference</a>; each step below links to its entry there.

The route has two stages. You plan the project at the start, and update the plan when its direction changes. Then every feature of the plan goes the same way, from an Issue to a pull request that you merge.

<a id="choices-along-the-route"></a>

## Daily use

### Step by step or unattended

Both ways go through the same checks, reviews and gates, and both end at a pull request that you merge. They differ in when you are needed.

- **Unattended:** `./scripts/run-feature.sh <issue>` runs the implementation, the checks, the review rounds with their triage and fixes, the commit and the pull request. The triage agent decides on the review findings and publishes its decisions on the Issue, where you read them afterwards. The run stops when an agent needs a decision of yours, when it cannot safely go on, or when it reaches a limit, and it prints the reason and the command that continues. It never merges.
- **Step by step:** `./scripts/start-feature.sh <issue>` starts the implementer, and you run each following step yourself. You watch every step, approve every triage, and can stop between the steps.

You can switch at any point: an interrupted feature continues from its handoff note either way. Unattended suits a feature whose Issue is clear; step by step suits a feature where you want to follow the decisions as they are made.

<a id="resume"></a>

### Resume a feature that stopped

A feature that stopped keeps its worktree, its handoff note and its records, so nothing is lost.

1. Read the reason the script printed. An unattended run also writes it into its log, `.agents/run/<issue>-log` in the feature worktree.
2. If an agent asked a question, answer it in `.agents/handoffs/<issue>.md` or in a comment on the Issue.
3. Continue the way you were working: `./scripts/start-feature.sh <issue> --resume` step by step, or `./scripts/run-feature.sh <issue>` again unattended; the run continues where the feature stands.

The feature has recovered when the next session starts from the handoff note instead of from the beginning, and the step that stopped runs again. If the same stop comes back, look up its message in <a href="#troubleshooting">Troubleshooting</a>.

### When the plan changes

You do not edit the approved requirements or roadmap by hand. Write the change down in a short file, and start the change process: `./scripts/start-planning.sh <name> --change <file>`, with `--grill` when the requirements change. The planning agent updates what the change touches, the change is reviewed, and you approve it again. A small change to the architecture or a decision record has a lighter route, `./scripts/finish-planning.sh --amend`. Feature Issues that you create afterwards follow the new plan; <a href="#step-change">Update an approved plan</a> says more.

### A base branch other than main

A feature branches from its base and merges back into it. Name the base as the third argument of `start-feature.sh` or `run-feature.sh`, or set it once for the project with a line `base: develop` in `.agents/template.conf`; without either it is `main`. The base is recorded with the feature, and every later step uses it: the review and the risk compare with it, and the pull request merges into it. A pull request of the branch that is already open into another branch stops the publication before the push. Details in [the base branch of a feature](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#the-base-branch-of-a-feature) of the development guide.

### Features side by side

`./scripts/start-feature.sh <issue>` creates the branch `feature/<issue>-<slug>` and a worktree beside the main checkout: a second working folder of the same repository, so your main copy stays untouched. One agent writes in a worktree; agents that work in parallel need separate worktrees and branches. A setup script of your own, if your project adds one, prepares every new worktree before the agent starts, for example by copying ignored files such as installed dependencies; the [development guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md) describes it. After the merge, `./scripts/cleanup-worktree.sh <issue>`, run from the main checkout, copies the run records of the feature and then removes its worktree and branch.

Every feature has its own branch and worktree, so several can run at once. Nothing reserves a file or a number for one of them, though, and a clash shows only when the second one merges. Do not run features side by side that change the same module, or that each take the next number of a numbered sequence: a lesson, a migration, an ADR. Run them one after another, or give them disjoint scopes in their Issues. Otherwise the second pull request conflicts with its base or duplicates a number, and needs rework and a new review. Details in [features side by side](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#features-side-by-side) of the development guide.

<a id="plans-and-earlier-review-rounds"></a>

### A plan for a complex Issue

For an Issue with many parts, a technical plan in `.agents/plans/` holds the implementation details, linked from the Issue. The Issue keeps the scope and the acceptance criteria. Do not turn each step of a plan into an Issue of its own.

<a id="steps"></a>
<a id="every-step-in-detail"></a>

## What each step is for

### Stage 1 · Plan the project

<a id="step-idea"></a>
<a id="describe-the-idea"></a>

**Describe the idea.** A short description in your own words. It does not need every detail: the next step asks about what it leaves open. No agent overwrites it, so it stays the record of what you asked for. <a href="#workflow-reference/describe-the-idea">Reference</a>.

<a id="step-grill"></a>
<a id="clarify-the-requirements-project-grill"></a>

**Clarify the requirements (Project Grill).** An agent asks about the goals, the users, the scope and the constraints, and only about what would change the product or its technical direction. The requirements count only after you approve them, and everything after this point is checked against them, so this is the cheapest place to correct a misunderstanding. They are written to `docs/PROJECT_REQUIREMENTS.md`, and a feature Issue cannot override them silently: where it would, the conflict is a question for you, with a proposed ADR or an update of the requirements as one of the options. The planning runs in a planning worktree, a separate working copy next to your repository. <a href="#workflow-reference/clarify-the-requirements">Reference</a>.

<a id="step-plan"></a>
<a id="create-the-project-plan"></a>

**Create the project plan.** A fresh agent session proposes the architecture, a roadmap of features with IDs and dependencies, and a decision record (an ADR) for each important technical choice. When it needs a decision from you, it stops and asks instead of guessing. <a href="#workflow-reference/create-the-plan">Reference</a>.

<a id="step-planning-review"></a>
<a id="review-the-plan"></a>

**Review the plan.** A second agent, which cannot edit files and, as shipped, runs on another provider than the planner, checks the plan for missing requirements, inconsistent decisions and risks, in a form the scripts validate. <a href="#workflow-reference/review-the-plan">Reference</a>.

<a id="step-revise"></a>
<a id="address-the-review-findings"></a>

**Address the review findings.** The planning agent proposes a decision per finding: adopt, reject, defer, or escalate to you. You approve the decisions, and a changed plan is reviewed again, until a round changes nothing. <a href="#workflow-reference/address-the-findings">Reference</a>.

<a id="step-finish-planning"></a>
<a id="approve-the-plan"></a>

**Approve the plan.** Your approval is recorded with a fingerprint, a checksum of the requirements and roadmap you approved. If either changes later, the approval no longer applies, and no feature Issue is created from it. Every feature session reads the approved architecture, ADRs and roadmap first. An accepted ADR outranks the Issue: an implementer that would have to break one stops and reports the conflict, a new ADR enters with the status `Proposed`, and a pull request that adds, changes or removes an ADR is marked as needing your approval. <a href="#workflow-reference/approve-the-plan">Reference</a>.

<a id="step-planning-merge"></a>
<a id="merge-the-planning-pull-request"></a>

**Merge the planning pull request.** The approved plan is merged into `main`, and every feature starts from that version. <a href="#workflow-reference/merge-the-plan">Reference</a>.

<a id="step-change"></a>
<a id="update-an-approved-plan"></a>

**Update an approved plan.** When the requirements or the direction change, the change goes through the planning agent, the review and your approval again, as <a href="#when-the-plan-changes">When the plan changes</a> describes. Feature IDs stay the same, and a replaced decision stays traceable. <a href="#workflow-reference/change-the-plan">Reference</a>.

### Stage 2 · Build each feature

<a id="step-issue"></a>
<a id="create-a-feature-issue"></a>

**Create a feature Issue.** You create the GitHub Issue of a roadmap feature when you are ready to build it, not all at once at the start, so it matches the current requirements and architecture. <a href="#workflow-reference/create-a-feature-issue">Reference</a>.

<a id="step-implement"></a>
<a id="implement-the-feature"></a>

**Implement the feature.** The implementer works in its own branch and worktree, so that features in progress do not get in each other's way. Its first session reads the Issue, your comments on it, the requirements, the architecture, the ADRs and the code, and decides whether the feature is clear. If a decision that matters is still open, such as the scope, a public interface or security, it changes nothing, writes its questions in the handoff note with options and a recommendation, and the run stops for you, an unattended one with status 3; a name or the layout of the tests it decides itself. Your comments on the Issue reach the implementer, the reviewer and the triage agent alike; only comments of the owner, members and collaborators are passed on. Every session ends with a completion record: complete, awaiting evidence, partial, or blocked, with evidence per acceptance criterion; only complete and awaiting evidence go on to the review. <a href="#verification-and-review">Verification and completion</a> explains the record; <a href="#workflow-reference/implement-the-feature">Reference</a>.

<a id="step-verify"></a>
<a id="run-verification"></a>

**Run verification.** Your tests, linters and builds run before every review and before the commit. A pass counts for exactly the content it checked, and the checks run again as soon as that content changes. <a href="#workflow-reference/run-the-checks">Reference</a>.

<a id="step-review"></a>
<a id="review-the-implementation"></a>

**Review the implementation.** An agent of another provider than the implementer, which cannot edit files, checks every acceptance criterion against the code and the tests; the completion record is a claim, and the reviewer reports one the code does not support. It also rates the impact on the architecture, which decides whether the merge needs you. When the code changes, another review is needed; a finding you accepted or deferred is not raised again unless the change made it worse. <a href="#workflow-reference/review-the-code">Reference</a>.

<a id="step-triage"></a>
<a id="decide-what-to-do-with-review-findings"></a>

**Decide what to do with review findings.** Each finding gets a recorded decision: fix it now, defer it to a follow-up Issue, or accept it with a reason. This step is called triage. Critical and major findings are always fix now; the one other route is <a href="#owner-exception">your exception</a> for a single finding. Step by step, an agent proposes and you approve; unattended, the agent decides and you read its decisions on the Issue. For a low- or medium-risk feature the risk policy can ask for a light triage, which defers or accepts a minor finding rather than starting a fix round. <a href="#workflow-reference/decide-on-the-findings">Reference</a>.

<a id="step-fix"></a>
<a id="apply-fixes-and-review-again"></a>

**Apply fixes and review again.** An implementer session repairs only the findings decided as fix now, and the checks run again. The changed content is reviewed again, first the recent fixes, then the complete feature, until a review leaves nothing to fix. <a href="#workflow-reference/apply-the-fixes">Reference</a>.

<a id="step-commit"></a>
<a id="commit-the-feature"></a>

**Commit the feature.** The commit is refused unless the completion record says the feature is done, the verification passed for this content, and the latest review is current and covers the complete feature. The commit message records all of that with the risk level. When the merge needs your approval, the commit carries an approval request that names the content that was verified and reviewed; it asks and records, it grants nothing. <a href="#workflow-reference/commit-the-feature">Reference</a>.

<a id="step-publish"></a>
<a id="open-the-pull-request"></a>

**Open the pull request.** The branch is pushed and the pull request opened with the evidence in its description, and CI runs the checks again. It closes the Issue only when the feature is complete; unfinished work becomes a draft. <a href="#workflow-reference/open-the-pull-request">Reference</a>.

<a id="step-merge"></a>
<a id="review-and-merge"></a>

**Review and merge.** You read the pull request, its checks and the published triage, and merge it; no script merges. The workflow tells you when a change needs you: a protected path, an architecture impact rated major or breaking, or a feature that nobody reviewed. GitHub enforces that for everyone only with the settings of <a href="#github-setup">GitHub setup</a>. <a href="#workflow-reference/merge">Reference</a>.

<a id="step-run"></a>
<a id="run-a-feature-unattended"></a>

**Run a feature unattended.** One command runs every step of this stage up to the pull request, as <a href="#step-by-step-or-unattended">Step by step or unattended</a> describes. Its limits: at most five review rounds, and by default four implementer sessions, three retries of a failing agent call and three repairs of a failing verification. An agent that needs your decision ends with a `BLOCKED:` line, and the run exits with status 3; running the same command again continues where the feature stands. It never merges and never removes a worktree. <a href="#workflow-reference/run-unattended">Reference</a>.

## When you disagree, and exceptions

The steps above are the normal route. These are the exceptions, each recorded where you and a reviewer can see it.

<a id="owner-directed-triage"></a>

### When you disagree with the triage

If the triage agent's proposal is out of proportion, you can give your own decisions instead, an owner-directed triage. No agent runs; the script shows your decisions for confirmation and records your account and your reason on the Issue. It does not bypass any rule: critical and major findings are still fix now, and the only other route for one of them is <a href="#owner-exception">your exception</a> below; a deferral still needs a follow-up Issue, and an acceptance a reason. The options are in the <a href="#workflow-reference/decide-on-the-findings">reference</a>, and the file format in [owner-directed triage](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#owner-directed-triage) of the development guide.

<a id="owner-exception"></a>

### When you disagree with a blocking finding

A critical or major finding stops the commit until it is fixed. If you judge that it is wrong, or right but a risk you accept, you can record an exception for that one finding with `./scripts/record-exception.sh`. Only you, at a terminal: the script shows the finding and the exact record, asks once, and publishes it on the Issue; it refuses to run unattended. The exception holds only for the latest review of exactly this content, and any change, new round or edit voids it. The review keeps its verdict, every other check still applies, and the merge then always needs your approval; the pull request shows the finding next to your exception. Until the agent has an identity of its own, this rests on the workflow keeping the rule, not on GitHub. Details in [owner exceptions to a blocking finding](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#owner-exceptions-to-a-blocking-finding) of the development guide.

<a id="skipping-a-review-explicitly"></a>

### Skipping a review

Under the shipped policy every feature is reviewed. A project can let low-risk features skip the review, with `low: review: none` or `profile: light`, and for a low-risk change you can also finish without a review and a recorded reason. Either way the commit and the pull request say it was not reviewed, and since nobody assessed its impact, its merge needs you. The verification and the completion record still apply. <a href="#risk-policy">Risk policy</a> says which changes are low risk.

The [development guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md) holds every option of every command.
