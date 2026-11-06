---
title: "Adopting Codeyard in an existing repository"
description: "Bring the workflow into a repository that did not start from the template: assess it, add the workflow on a branch you review, and record an honest baseline."
order: 8
---

A repository that did not start from the template can adopt the workflow in three steps. Each runs from a clone of the template, pointed at the path of your repository, and none of them rewrites your history, replaces your CI, or deploys anything.

## 1. Assess

```
./scripts/assess-repository.sh ~/my-project
```

The assessment only reads. It runs none of your code, tests or installers, never opens a file that may hold a secret such as `.env` or a key, and changes nothing in your repository. A read-only agent writes a report into `.agents/assessments/` of the template clone that keeps what the files show apart from what it infers, the questions only you can answer and the risks it sees, with a proposal: the files to add, the files that collide with yours and how to resolve each, the workflow's files that your ignore rules would hide (a `*.json` rule hides its schemas and approval requests), your own commands that could verify the project, and what a baseline would have to run.

The report names the branch it measured and the branch your features merge into. When those differ, for example `main` checked out while the work happens on `develop`, it says so, asks you which branch is the base, and proposes it as `base:` for `.agents/template.conf`; check that branch out and assess again. It also says when a merge into the base triggers a deployment, and names what your checks may do outside your machine: reach a database during a build, send email, call an external API, or send telemetry.

## 2. Adopt

```
./scripts/adopt-repository.sh ~/my-project
```

The adoption applies the proposal as one commit on the branch `adopt/agent-codeyard` of your repository. It only adds: where you already have a file, it keeps yours, appends a marked section to your `AGENTS.md` and `.gitignore`, or places the template's version beside yours to combine by hand. A document whose name differs only in case, such as `ARCHITECTURE.md` in `docs/` for `docs/architecture.md`, is renamed to the expected name with its history, never doubled. When your application lives in a subdirectory such as `nextjs/`, no empty test directories or `.env.example` are added at the top. The section of `.gitignore` also un-ignores the workflow's files that a rule of yours hides, and nothing else; a rule it cannot undo from there, in a `.gitignore` further down or on an ignored directory, it names for you to change. It stops before any change when you have uncommitted work, a collision is unresolved, or the assessment measured another branch than the base. Review the branch like any change; `--publish` pushes it and opens a pull request into the base, whose description says when the merge deploys.

It also writes, where you have no such file or yours is not sufficient:

- `scripts/verify.conf` with your own test, lint and build commands as the checks of `./scripts/verify.sh`, each in its directory and isolated by default: no credentials from your environment, a database URL that points at a closed local port, and telemetry off. Your CI keeps running them as before.
- `docs/architecture.md`, `docs/PROJECT_REQUIREMENTS.md` and `docs/roadmap.md` as a minimal baseline: your own documents to reuse, what the assessment observed, its assumptions, risks and open questions, and the near-term work. Each starts with the mark **Observed, not approved**. Where you have such a document already, the assessment judges whether it is sufficient: a sufficient one is reused as it is; one that is not, such as a heading without content, gets the marked baseline at its path, with your text kept unchanged below it to fold into the planning. No ADR is written: nothing is presented as a decision of the past.

## 3. Record the baseline

On the branch, before any change, when you decide to run your project's commands:

```
./scripts/verify.sh --baseline
```

It runs every check once and records in `.agents/verification-baseline` how each ended. A check that fails then is a pre-existing failure. From then on, `./scripts/verify.sh` shows it as `KNOWN`, with its check name, apart from a regression, and the verification fails until the failure is fixed or you accept it as an exception with one line in `scripts/verify.conf`:

```
accepted-failure: lint The style errors predate the adoption; F03 fixes them.
```

A known failure never turns into a passing verification by itself. Adding an exception, and changing the baseline, needs your approval at the merge. <a href="../verification-and-completion/">Verification and completion</a> explains the verification.

## After the merge

- Ordinary features run as in any Codeyard project: `./scripts/run-feature.sh <issue> <name>`, with the review, the verification against the baseline, and the merge approval gate.
- The planning documents stay *observed, not approved* until you approve them through the planning of the repository, `./scripts/start-planning.sh` and then `./scripts/finish-planning.sh`. The approved documents lose the mark, and the planning is not approved while a document still carries it. Creating features from the roadmap waits for that approval.
- Later template changes come in with `./scripts/sync-template.sh`, as described in <a href="../updating/">Updating a Codeyard-based project</a>. It changes only the workflow's files: your checks, your baseline, your CI and the files you kept stay yours.

## What is preserved

Your Git history, application code, dependencies, CI workflows and deployment configuration. The adoption never pushes your default branch, never merges, and runs none of your Git hooks.

## Limits

- The assessment reads files. It does not understand your code, and its reconstruction is a starting point for the planning, not a description to rely on.
- The baseline records how the checks ended on one machine. A missing tool is recorded as unavailable and still fails.
- The workflow profile of the proposal is not applied; you add `profile: light` or `profile: standard` to `.agents/policies/risk.conf` when you want it.
- Nothing fixes an existing defect, sets up a deployment or changes your CI. To make `./scripts/verify.sh` the required check on GitHub, add it to your CI in a reviewed change.

The full reference is in [docs/development.md](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#adopting-an-existing-repository).
