---
title: "How the workflow works"
description: "The route from idea to merged pull request: why each step exists, the choices along it, and where to find its commands."
order: 3
---

This page explains the route: what each step is for, what you decide, and the choices you have. It does not list every option. The <a href="../reference/workflow/">workflow reference</a> is the authority for the command of every step, what goes in and comes out, and when it stops or retries; each step below links to its entry there.

The route has two stages. You plan the project once, and again when its direction changes. Then every feature of the plan goes the same way, from an Issue to a pull request that you merge.

<a id="steps"></a>
<a id="every-step-in-detail"></a>

## Stage 1 · Plan the project

<a id="step-idea"></a>

### Describe the idea

You start with a short description in your own words. It does not need every detail worked out: the next step asks about what it leaves open. No agent overwrites it, so it stays the record of what you asked for. <a href="../reference/workflow/#describe-the-idea">Reference</a>.

<a id="step-grill"></a>

### Clarify the requirements (Project Grill)

An agent asks you about the goals, the users, the scope and the constraints, and only about what would change the product or its technical direction. We call this round the Project Grill. It writes the requirements as a draft; they count only after you approve them. Everything after this point is checked against them, so this is the cheapest place to correct a misunderstanding. The planning happens in a planning worktree, a separate working copy next to your repository, so your main checkout stays as it was. <a href="../reference/workflow/#clarify-the-requirements">Reference</a>.

<a id="step-plan"></a>

### Create the project plan

A fresh agent session reads the approved requirements and proposes the architecture, a roadmap of features with IDs and dependencies, and a decision record (an ADR) for each important technical choice. When it needs a decision from you, it stops and asks instead of guessing. <a href="../reference/workflow/#create-the-plan">Reference</a>.

<a id="step-planning-review"></a>

### Review the plan

A second agent, which cannot edit files, checks the plan for missing requirements, inconsistent decisions and risks. Its findings come in a fixed form that the scripts validate, so a review cannot be silently incomplete. <a href="../reference/workflow/#review-the-plan">Reference</a>.

<a id="step-revise"></a>

### Address the review findings

The planning agent proposes what to do with each finding: adopt it, reject it, defer it, or escalate it to you. You approve the decisions, and a changed plan is reviewed again, until a round changes nothing. <a href="../reference/workflow/#address-the-findings">Reference</a>.

<a id="step-finish-planning"></a>

### Approve the plan

Your approval is recorded with a fingerprint: a checksum of the exact requirements and roadmap you approved. If either changes later, the approval no longer applies, and no feature Issue is created from it. That is what keeps the features in line with what you agreed to. <a href="../reference/workflow/#approve-the-plan">Reference</a>.

<a id="step-planning-merge"></a>

### Merge the planning pull request

The approved plan is merged into `main` like any other change, and every feature starts from that version. <a href="../reference/workflow/#merge-the-plan">Reference</a>.

<a id="step-change"></a>

### Update an approved plan

When the requirements or the direction change, you write the change down in a short file. You do not edit the approved documents by hand: the planning agent updates what the change touches, and the change goes through the review and your approval again. Feature IDs stay the same, and a replaced decision stays traceable. A small change to the architecture or to a decision record has a lighter route. <a href="../reference/workflow/#change-the-plan">Reference</a>.

## Stage 2 · Build each feature

<a id="step-issue"></a>

### Create a feature issue

You create the GitHub Issue of a roadmap feature when you are ready to build it, not all at once at the start. Created then, it matches the current requirements and architecture. <a href="../reference/workflow/#create-a-feature-issue">Reference</a>.

<a id="step-implement"></a>

### Implement the feature

The implementer works in its own branch and worktree, so that features in progress do not get in each other's way. It reads the Issue, the approved project documents and the code, writes the code and the tests, and runs the checks itself.

Before it changes anything, its first session decides whether the feature is clear. When the sources settle every decision that matters for the scope, the user experience, a public interface, the data, the architecture, security or compatibility, it implements. When they do not, it changes nothing and writes its questions in the handoff note, each with the options and a recommendation, and the run stops for you. A choice it can make itself, such as a name or the layout of the tests, is not a question for you. Your comments on the Issue reach the implementer, the reviewer and the triage agent alike, so all three judge the same Issue.

Before it ends, every session records how far the Issue is done, with evidence for each acceptance criterion: complete, awaiting evidence, partial, or blocked. A session that ends is not a finished feature; the workflow goes on to the review only when the record says complete, or awaiting evidence that can only exist later, such as the CI result of the pull request. <a href="../verification-and-completion/">Verification and completion</a> explains the record; <a href="../reference/workflow/#implement-the-feature">Reference</a>.

<a id="step-verify"></a>

### Run verification

Your tests, linters and builds run before every review and before the commit. A pass is recorded for exactly the content it checked, so it is reused while that content does not change, and runs again as soon as it does. A check that you declare as a budget measures something, such as a duration, and never fails the verification. <a href="../reference/workflow/#run-the-checks">Reference</a>.

<a id="step-review"></a>

### Review the implementation

An agent of another provider than the implementer, which cannot edit files, checks every acceptance criterion against the code and the tests. The implementer's completion record is a claim; the reviewer reports a claim the code does not support. It also rates how much the change affects the architecture, which decides whether the merge needs you. A review belongs to the content it reviewed: when the code changes, another review is needed. Later rounds know the decisions of the earlier ones, so a finding you accepted or deferred is not raised again unless the change made it worse. <a href="../reference/workflow/#review-the-code">Reference</a>.

<a id="step-triage"></a>

### Decide what to do with review findings

Each finding gets a recorded decision: fix it now, defer it to a follow-up Issue, or accept it with a reason. This step is called triage. Critical and major findings are always decided as fix now; the one other route is <a href="#owner-exception">your exception</a> for a single finding. Step by step, an agent proposes and you approve; in an unattended run the agent decides, and you read its decisions on the Issue afterward. For a low- or medium-risk feature the risk policy can ask for a light triage, which defers or accepts a minor finding rather than starting a fix round. <a href="../reference/workflow/#decide-on-the-findings">Reference</a>.

<a id="step-fix"></a>

### Apply fixes and review again

An implementer session repairs only the findings decided as fix now, and the checks run again. The content changed, so it is reviewed again: first the recent fixes, then the complete feature, until a review leaves nothing to fix. <a href="../reference/workflow/#apply-the-fixes">Reference</a>.

<a id="step-commit"></a>

### Commit the feature

Before it commits, the script checks that the completion record says the feature is done, that the verification passed for this content, and that the latest review is current and covers the complete feature. The commit message records all of that with the risk level and its reasons. When the merge needs your approval, the commit carries an approval request that names the content tree: a checksum of exactly the content that was verified and reviewed. The request only asks and records; it grants nothing. <a href="../reference/workflow/#commit-the-feature">Reference</a>.

<a id="step-publish"></a>

### Open the pull request

The branch is pushed and the pull request opened, with the evidence in its description, and CI runs the checks again. The pull request closes the Issue only when the feature is complete; unfinished work becomes a draft. <a href="../reference/workflow/#open-the-pull-request">Reference</a>.

<a id="step-merge"></a>

### Review and merge

You read the pull request, its checks and the published triage, and merge it. No script merges. The workflow tells you when a change needs your attention: a protected path, an architecture impact rated major or breaking, or a feature that nobody reviewed. To make GitHub enforce that for everyone, configure it as <a href="../github-setup/">GitHub setup</a> describes; the scripts alone cannot. <a href="../reference/workflow/#merge">Reference</a>.

<a id="step-run"></a>

### Run a feature unattended

One command runs the whole feature stage up to the pull request: the implementation, the checks, the review rounds with their triage and fixes, the commit and the publication. It retries a temporary failure, and stops when an agent needs you or it cannot safely go on, with the reason and the command that continues. It never merges. <a href="../reference/workflow/#run-unattended">Reference</a>.

## Choices along the route

### Step by step or unattended

`run-feature.sh` is the short route: you start it and read the pull request. Running the steps one at a time, from `start-feature.sh`, lets you watch each step, approve every triage yourself, and stop between them. Both routes go through the same checks, reviews and gates, and you can switch: an interrupted run continues from its handoff note either way.

### A base branch other than main

A feature branches from its base and merges back into it. Name the base as the third argument of `start-feature.sh` or `run-feature.sh`, or set it once for the project with a line `base: develop` in `.agents/template.conf`; without either it is `main`. The base is recorded with the feature, and every later step uses it: the review and the risk compare with it, and the pull request merges into it. A pull request of the branch that is already open into another branch stops the publication before the push. Details in [the base branch of a feature](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#the-base-branch-of-a-feature) of the development guide.

<a id="owner-directed-triage"></a>

### When you disagree with the triage

If the triage agent's proposal is out of proportion, you can give your own decisions instead, an owner-directed triage. No agent runs; the script shows your decisions for confirmation and records your account and your reason on the Issue. It does not bypass any rule: critical and major findings are still fix now, and the only other route for one of them is <a href="#owner-exception">your exception</a> below; a deferral still needs a follow-up Issue, and an acceptance a reason. The options are in the <a href="../reference/workflow/#decide-on-the-findings">reference</a>, and the file format in [owner-directed triage](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#owner-directed-triage) of the development guide.

<a id="owner-exception"></a>

### When you disagree with a blocking finding

A critical or major finding stops the commit until it is fixed. If you judge that it is wrong, or right but a risk you accept, you can record an exception for that one finding with `./scripts/record-exception.sh`. Only you, at a terminal: the script shows the finding and the exact record, asks once, and publishes it on the Issue; it refuses to run unattended. The exception holds only for the latest review of exactly this content, and any change, new round or edit voids it. The review keeps its verdict, every other check still applies, and the merge then always needs your approval; the pull request shows the finding next to your exception. Until the agent has an identity of its own, this rests on the workflow keeping the rule, not on GitHub. Details in [owner exceptions to a blocking finding](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#owner-exceptions-to-a-blocking-finding) of the development guide.

<a id="skipping-a-review-explicitly"></a>

### Skipping a review

Under the shipped policy every feature is reviewed. A project can let low-risk features skip the review, with `low: review: none` or `profile: light`, and for a low-risk change you can also finish without a review and a recorded reason. Either way the commit and the pull request say it was not reviewed, and since nobody assessed its impact, its merge needs you. The verification and the completion record still apply. <a href="../risk-policy/">Risk policy</a> says which changes are low risk.

<a id="plans-and-earlier-review-rounds"></a>

### A plan for a complex Issue

For an Issue with many parts, a technical plan in `.agents/plans/` holds the implementation details, linked from the Issue. The Issue keeps the scope and the acceptance criteria. Do not turn each step of a plan into an Issue of its own.

The [development guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md) holds every option of every command.
