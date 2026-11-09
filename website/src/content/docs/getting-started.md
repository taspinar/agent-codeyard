---
title: "Getting started"
description: "One path from a GitHub account to your first feature as a pull request: create the repository, plan it, build the first feature."
order: 1
---

This page is one path, in eight steps, from a GitHub account without the project to the pull request of your first feature. Every step says where you run it, what you give it, what you should see, and what comes next. A word in angle brackets in a command takes a value of yours; the step that first uses it says which.

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
- Set up GitHub: a ruleset for `main` and your account in `.github/CODEOWNERS` (step 3 below).
- Approve the requirements and the plan, and merge the planning pull request.
- Read and merge every feature pull request: no script merges.

Questions about cost, supported environments, stopping a run or what agents may do without you: <a href="../../faq/">/faq/</a>.

## 1. Sign in

Sign in to GitHub and to each coding agent, then check both:

```
gh auth login
gh auth status
claude
codex login
```

`gh auth login` asks for your GitHub account; `gh auth status` then shows it as logged in. Each coding agent signs in through its own command-line tool: start Claude Code with `claude` and follow its sign-in prompt, then quit it; sign in to Codex with `codex login`. The workflow reads no tokens: do not put API keys or tokens in a file of the repository.

- **Where:** any directory.
- **Input:** your GitHub account and the accounts of your two coding agents.
- **Result:** `gh auth status` shows your account, and `claude` and `codex` start without asking you to sign in again.
- **Next:** create the repository.

## 2. Create your repository

There is no installer: a project is a new repository created from the template. Choose its visibility first, because it decides whether GitHub can protect `main` in steps 3 and 7. A ruleset with a required check is available for a private repository with GitHub Pro, GitHub Team and GitHub Enterprise Cloud; with GitHub Free and GitHub Free for organizations it is available only for a public repository ([GitHub's documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)).

With the GitHub CLI, take one of the two:

- **A private repository**, on a plan that supports the ruleset for it:

  ```
  gh repo create my-project --template taspinar/agent-codeyard --private --clone
  ```

- **A public practice repository**, on GitHub Free:

  ```
  gh repo create my-project --template taspinar/agent-codeyard --public --clone
  ```

  Anyone can read and clone the code and the history of a public repository, so put nothing in it that you would not publish.

Then go to the new folder:

```
cd my-project
```

`my-project` is the name of your repository, and of the folder it is cloned into; choose your own. Later commands call that folder `<repository>`.

Or [create it on GitHub](https://github.com/taspinar/agent-codeyard/generate), with the visibility you chose, and clone it. Then delete `website/` and `.github/workflows/pages.yml`: they are this website, not part of your project. Keep, replace, or remove `LICENSE`, the MIT licence of the template, for your own project.

Have an existing repository instead? It adopts the workflow on a branch you review, without a new repository: <a href="../adopting/">Adopting Agent Codeyard in an existing repository</a>.

- **Where:** the folder that should hold your project folder, then the new folder `my-project`.
- **Input:** the name of the repository, and its visibility for your plan.
- **Result:** a private repository on a plan that supports its ruleset, or a public practice repository on GitHub Free, and its clone on your machine, without the template's website.
- **Next:** set up GitHub, from the same folder.

## 3. Set up GitHub

The scripts point out risky changes, but only GitHub can enforce who merges:

- Replace the placeholder `@YOUR_GITHUB_USERNAME` in `.github/CODEOWNERS` with your account, such as `@your-name`.
- Commit that change and the deletions of step 2, and push them: the planning in step 6 starts only from a working tree without uncommitted changes.
- Add a ruleset for `main` that requires a pull request and the CI check. GitHub lists the check, `verify`, only after it ran once on your repository, so you add it in step 7. The ruleset needs the plan and visibility of step 2: a private repository on GitHub Free cannot have one, and then nothing protects its `main`.

The [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md) has every setting; <a href="../github-setup/#github">GitHub setup</a> explains why they matter.

- **Where:** `my-project` for the file, and the settings of the repository on GitHub for the ruleset.
- **Input:** your GitHub account name.
- **Result:** `main` takes changes only through a pull request, and the code owners file names you.
- **Next:** check your setup.

## 4. Check your setup

```
./scripts/doctor.sh
```

The script checks that the tools above are installed and that the agents you configured can run. It also checks that Git has a commit identity (`user.name` and `user.email`) and that you can push with it, and, when Codex has a role that writes, that a Codex session can write the working files of the workflow under `.agents/`. It tells you what is missing.

- **Where:** `my-project`.
- **Input:** none.
- **Result:** `All required prerequisites are available.` A warning that `main` accepts a merge while its checks fail stays until step 7 adds the check; if it is still there after step 7, check the plan and visibility of step 2; a line marked `FAILED` names what to fix before you go on.
- **Next:** choose your agents, or keep the shipped ones.

## 5. Choose your agents

Each role in the workflow has an agent and a model. Set them in `.agents/agents.conf`, one role per line:

```
implementer: claude opus
implementer@high: claude fable
reviewer: codex gpt-6-luna
```

This is what the template ships: Claude implements, with a stronger model for a high-risk feature, and Codex reviews. A line with `@high` (or `@low`, `@medium`) applies to features of that <a href="../risk-policy/#risk">risk level</a>, and the plain line to the others. The file lists every role, including the planner and the planning reviewer; <a href="../agent-roles/#roles">Agent roles and models</a> explains each one and how to change it. The reviewer must use a different agent than the implementer, at every level.

- **Where:** `my-project`.
- **Input:** nothing when the shipped models are available to your accounts; otherwise a model your account offers, on the line of its role.
- **Result:** every role names an agent you are signed in to; run `./scripts/doctor.sh` again after a change.
- **Next:** describe your project.

## 6. Plan your project

Write a short description of what you want to build, in your own words, for example in `idea.md`:

```
A member application for a gym. Trainers record attendance for their
classes; members see their own training history.
```

Then start the planning with it; `path/to/idea.md` is the path of your file:

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

`project-bootstrap` is the name of the first planning, so the folder is `../my-project-planning-project-bootstrap`. `<review>` is the file of the review that `review-planning.sh` wrote, such as `.agents/reviews/planning-project-bootstrap-review-01.json`; the script prints the whole `revise-planning.sh` command with it. Without findings it names `finish-planning.sh` instead, and you skip the revision. Review and revise again until the review passes.

Each script ends by telling you the next command. `finish-planning.sh` records your approval and prints the next steps: `./scripts/verify.sh`, a `git add` of the planning files, `git commit` and `git push`. Run them, still in the planning folder. Then open the planning pull request on GitHub, or with `gh pr create --fill` from the planning folder, read it, and merge it. Then return to your repository and update it:

```
cd ../<repository>
git pull
```

The steps of this section in order, with the folder of each:

1. In `my-project`: write `idea.md` and run `start-planning.sh`.
2. In the planning folder `../my-project-planning-project-bootstrap`: run `review-planning.sh`, then `revise-planning.sh` and `review-planning.sh` again until the review passes, then `finish-planning.sh` and the commit and push steps it prints.
3. On GitHub: open the planning pull request and merge it.
4. In `my-project`: run `git pull`, so `main` has the merged planning.

- **Where:** `my-project` for `start-planning.sh`; the planning folder for every command from `review-planning.sh` to `git push`; GitHub to open and merge the pull request; `my-project` again for `git pull`.
- **Input:** your description, your answers to the questions, and your approval of the requirements and the plan.
- **Result:** the planning pull request is merged, and `main` in `my-project` holds the approved requirements, architecture and roadmap; the roadmap lists the features as `F01`, `F02` and so on.
- **Next:** once the planning pull request is merged and `git pull` has run in `my-project`, require the CI check in step 7.

## 7. Require the CI check

By now `verify` has run on your repository, on the push of step 3 and on the planning pull request, so GitHub lists it. Add `verify` as a required status check to the ruleset of `main`; <a href="../github-setup/#github">GitHub setup</a> shows where. Then run `./scripts/doctor.sh` again in `my-project`.

- **Where:** the settings of the repository on GitHub for the ruleset, then `my-project` for `doctor.sh`.
- **Input:** the check `verify`.
- **Result:** `./scripts/doctor.sh` reports that `main` requires a passing status check before a merge.
- **Next:** build your first feature.

## 8. Build your first feature

From your repository, on the updated `main`, create the issue of the first roadmap feature. Then let one command take it to a pull request:

```
./scripts/create-feature-issue.sh F01
./scripts/run-feature.sh <issue>
```

`F01` is the ID of the feature in the roadmap. `create-feature-issue.sh` shows the Issue for your approval and prints its address; `<issue>` is the number at the end of that address, such as `12`.

The run implements the feature, runs your checks, has it reviewed, fixes what the review finds, and opens a pull request. It does not merge. Read the pull request and the decisions about the review findings, then merge it yourself.

To stay closer to the work, run the steps one at a time, starting with `./scripts/start-feature.sh <issue>`. <a href="../detailed-workflow/">The workflow</a> explains each step.

- **Where:** `my-project`, on `main`.
- **Input:** the feature ID, your approval of the Issue, and the Issue number.
- **Result:** a pull request of the feature with the checks that ran and the decisions about the review findings in its description.
- **Next:** read it and merge it, then create the Issue of the next feature. A run that stops prints its reason; <a href="../troubleshooting/">Troubleshooting</a> has the first fix.

For a complete sample project, read the [worked example](https://github.com/taspinar/agent-codeyard/blob/main/docs/example.md).
