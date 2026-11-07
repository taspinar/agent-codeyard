---
title: "Getting started"
description: "Create your repository and take your first feature from idea to pull request."
order: 1
---

<a id="what-you-need"></a>

## Before you start

**What you need:**

- Git and Bash
- The [GitHub CLI](https://cli.github.com/), signed in to your account
- `jq` 1.6 or later
- Two coding agents of different providers. As shipped, Claude Code implements and Codex reviews; `review-feature.sh` refuses a reviewer of the implementer’s provider.

**What you should know:** how to work in a terminal, and the basics of Git and GitHub: a commit, a branch, a pull request. If those are new, read <a href="../new-to-agentic-coding/">New to agentic coding? Start here</a> first.

**What you will do by hand:** the scripts do not do these for you.

- Sign in to GitHub and to each coding agent.
- Create the repository from the template and delete the template's website from it.
- Set up GitHub: a ruleset for `main` and your account in `.github/CODEOWNERS` (step 1 below).
- Approve the requirements and the plan, and merge the planning pull request.
- Read and merge every feature pull request: no script merges.

Questions about cost, supported environments, stopping a run or what agents may do without you: the <a href="../../faq/">FAQ</a>.

## Sign in

Sign in to GitHub once with `gh auth login`. Each coding agent signs in through its own command-line tool. The workflow reads no tokens: do not put API keys or tokens in a file of the repository.

## 1. Create your repository

There is no installer: a project is a new repository created from the template. With the GitHub CLI:

```
gh repo create my-project --template taspinar/agent-codeyard --private --clone
cd my-project
```

Or [create it on GitHub](https://github.com/taspinar/agent-codeyard/generate) and clone it. Then delete `documentation/` and `.github/workflows/pages.yml`: they are this website, not part of your project. Keep, replace, or remove `LICENSE`, the MIT licence of the template, for your own project.

Have an existing repository instead? It adopts the workflow on a branch you review, without a new repository: <a href="../adopting/">Adopting Agent Codeyard in an existing repository</a>.

Then set up GitHub. The scripts point out risky changes, but only GitHub can enforce who merges:

- Add a ruleset for `main` that requires a pull request and the CI check.
- Replace the placeholder `@YOUR_GITHUB_USERNAME` in `.github/CODEOWNERS` with your account.

The [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md) has every setting; <a href="../github-setup/#github">GitHub setup</a> explains why they matter.

## 2. Check your setup

```
./scripts/doctor.sh
```

The script checks that the tools above are installed and that the agents you configured can run. It also checks that Git has a commit identity (`user.name` and `user.email`) and that you can push with it, and, when Codex has a role that writes, that a Codex session can write the working files of the workflow under `.agents/`. It tells you what is missing.

## 3. Choose your agents

Each role in the workflow has an agent and a model. Set them in `.agents/agents.conf`, one role per line:

```
implementer: claude opus
implementer@high: claude fable
reviewer: codex gpt-6-luna
```

This is what the template ships: Claude implements, with a stronger model for a high-risk feature, and Codex reviews. A line with `@high` (or `@low`, `@medium`) applies to features of that <a href="../risk-policy/#risk">risk level</a>, and the plain line to the others. The file lists every role, including the planner and the planning reviewer; <a href="../agent-roles/#roles">Agent roles and models</a> explains each one. The reviewer must use a different agent than the implementer, at every level.

## 4. Plan your project

Write a short description of what you want to build, and start the planning with it:

```
./scripts/start-planning.sh --description path/to/idea.md
```

An agent asks you questions and writes the requirements for your approval. It then proposes an architecture and a roadmap in a planning worktree: a separate folder next to your repository, whose path the script prints. Go to that folder, then review the plan, address the findings, and approve it:

```
cd ../<repository>-planning-project-bootstrap
./scripts/review-planning.sh
./scripts/revise-planning.sh --review <review>
./scripts/finish-planning.sh
```

Each script ends by telling you the next command. Merge the planning pull request when you are done, then return to your repository and update it:

```
cd ../<repository>
git pull
```

## 5. Build your first feature

From your repository, on the updated `main`, create the issue of the first roadmap feature. Then let one command take it to a pull request:

```
./scripts/create-feature-issue.sh F01
./scripts/run-feature.sh <issue>
```

The run implements the feature, runs your checks, has it reviewed, fixes what the review finds, and opens a pull request. It does not merge. Read the pull request and the decisions about the review findings, then merge it yourself.

To stay closer to the work, run the steps one at a time, starting with `./scripts/start-feature.sh <issue>`. <a href="../detailed-workflow/">The workflow</a> explains each step.

For a complete sample project, read the [worked example](https://github.com/taspinar/agent-codeyard/blob/main/docs/example.md).
