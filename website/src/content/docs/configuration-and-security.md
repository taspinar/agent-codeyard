---
title: "Configuration and security"
description: "What agents may do on your machine, which data goes to the AI providers and to GitHub, which GitHub rights apply, the changes that need the owner, and attribution."
order: 2
---

## The limits in short

- **An agent runs on your machine, as you.** It uses the sandbox and permission settings of its own command-line tool. It is not in a container or a virtual machine: all agents share your machine, your network, and the services that run there, and a worktree separates working files only.
- **Each step gets one of three permission profiles:** write, unattended, or read-only. Reviewers are always read-only. If an agent cannot enforce its profile, the script stops instead of starting it with more rights.
- **Your code goes to the AI provider of each tool.** Codeyard has no service of its own. The coding tools send what they read to their providers, and the scripts publish to GitHub, both under your accounts (<a href="#data">which data goes where</a>).
- **On GitHub, an agent has the rights of the account that started it.** If you may merge, so may the agent, until agents get an identity of their own ([Issue 99](https://github.com/taspinar/agent-codeyard/issues/99)). Only the settings of <a href="#github-setup">GitHub setup</a> make GitHub refuse a merge.
- **Some changes always need you:** a protected path, a change the reviewer rates as major or breaking for the architecture, and a feature committed without a review are marked as needing your approval (<a href="#gate">changes that need the owner</a>). No script merges.

<a id="profiles"></a>

## What an agent is allowed to do

A script starts an agent with one of three permission profiles. A permission profile is unrelated to the risk level and the workflow profile of the <a href="#risk-policy/three-settings">risk policy</a>.

| Profile | Used for | What the agent can do |
| --- | --- | --- |
| **write** | A step you follow in the terminal, such as implementing a feature | Change files in its worktree and use the network. For anything beyond that it asks you: Claude before it runs a shell command, Codex before a command leaves its sandbox |
| **unattended** | A step that runs without you, such as in `run-feature.sh` | The same reach as write, and it asks nothing. What it would have asked you is decided without you, in a different way per agent: Codex stays inside its sandbox and is refused what leaves it; Claude runs in its automatic permission mode, whose own check allows or denies each action, and anything that would still need a question is denied. It gets none of your personal integrations, such as MCP servers or apps |
| **read-only** | Reviews, triage proposals, and the analysis of runs | Read files. It cannot change them, and it gets none of your personal integrations |

If an agent cannot enforce a profile, the script stops. It never starts the agent with broader permissions instead.

<a id="unattended"></a>

**What "unattended" means.** An unattended session runs between your decisions: nobody answers its questions, so a question is denied, not approved, and an agent that needs a decision of yours stops the run with its question in the handoff note. The two tools get there differently, as [`scripts/lib/agent.sh`](https://github.com/taspinar/agent-codeyard/blob/main/scripts/lib/agent.sh) starts them:

- **Codex** runs non-interactively in its workspace sandbox with network access, without your own Codex configuration file, and with apps, browser use and computer use turned off. A command the sandbox blocks is refused.
- **Claude Code** runs non-interactively in its `auto` permission mode with permission prompts turned off, and without MCP servers from your configuration. Its own check allows or denies each action; what would still need a question is denied.

A read-only session is isolated the same way: Codex in its read-only sandbox without your configuration, with apps, browser use, computer use and web search turned off; Claude Code restricted to reading, without your user, project or MCP configuration.

**Codex and `.agents/`:** Codex keeps `.agents/` read-only inside its sandbox. A writing Codex session therefore gets exactly the five working directories it has to write opened for it: `.agents/completion/`, `.agents/handoffs/`, `.agents/summaries/`, `.agents/manual-steps/`, and `.agents/experience/`. The policies, prompts, schemas, reviews, and the agent configuration stay read-only for the agent. When a role with write access uses Codex, `doctor.sh` runs one short Codex session to check that it can write them.

**What this is not:** a profile uses the permission and sandbox settings of the agent's own command-line tool. It is not a container or a virtual machine. All agents share your machine, your network, and whatever databases and services run there, and a worktree separates working files only. Full isolation per agent is not built.

<a id="data"></a>

## Which data goes where

Codeyard is scripts and files in your repository, and it runs on your machine or your server. It has no service of its own. Data leaves your machine in two ways:

| Where to | What | Through |
| --- | --- | --- |
| **The AI provider of each tool**: Anthropic for Claude Code, OpenAI for Codex | The instructions of the step and whatever the agent reads: your code, the Issue with its comments, the project documents | The tool's own connection, under your account and that provider's terms. Which tool does which role is set in <a href="#agent-roles/shipped-configuration">`.agents/agents.conf`</a> |
| **GitHub** | The commits and branches you push, the pull request with its evidence, and on the Issue the review and triage reports and the follow-up Issues | The `gh` command-line tool and Git, signed in as you |

The run records stay on your machine: durations and tokens, never a prompt, an answer or a transcript. Only `publish-feature.sh --summary`, which you turn on yourself, posts the totals of a feature on its Issue, as numbers. Details in <a href="#technical-reference/records">what is recorded on your machine</a>.

## GitHub rights

The scripts use your GitHub account through `gh`. An agent therefore has the rights of the account that started it: if that account may push to `main` or merge, so may the agent. The workflow's own scripts never push to `main` and never merge, and they mark what needs your approval, but GitHub refuses a merge only when the repository's rulesets and code owners say so. <a href="#github-setup">GitHub setup</a> lists those settings; whether you can require a review from someone else depends on whether you work alone or in a team.

<a id="gate"></a>

## Changes that need the owner

Before a feature is committed, `check-guardrails.sh` looks at which files it changes. The rules come from the base branch, so a feature cannot loosen the rules it is checked against.

| Kind of change | Examples | What happens |
| --- | --- | --- |
| **Protected** | Decision records in `docs/decisions/`, CI workflows, `CODEOWNERS`, the agent configuration, and the scripts and prompts that carry out the review | The pull request is opened and marked as needing the owner's approval. No script merges it |
| **Sensitive** | `docs/architecture.md`, a new check in `scripts/verify.conf`, and paths you add yourself | Allowed; the reviewer is told to look at it closely |
| Everything else | Ordinary feature work | No extra step |

You add the paths that matter in your project, such as the deployment or the dependency manifest, to [`.agents/policies/guardrails.conf`](https://github.com/taspinar/agent-codeyard/blob/main/.agents/policies/guardrails.conf). Changing or removing an existing check in `scripts/verify.conf` counts as protected; adding one counts as sensitive.

The reviewer also says how much a change affects the architecture. A "major" or "breaking" assessment marks the change as needing the owner, whatever the files are. The reviewer can make the outcome stricter, never looser. A feature committed without a review, as the risk policy can allow for a low-risk one, has no such assessment and therefore needs the owner too.

**The approval request.** When a feature needs you, `finish-feature.sh` writes `.agents/approval-requests/<issue>.json` and commits it with the feature: what you are asked to approve and why. It names the content tree, a checksum of exactly the content that was verified and reviewed, which `finish-feature.sh` and `publish-feature.sh` print next to the commit. The request is for display only: no script acts on it, and no agent takes it as an instruction. `check-guardrails.sh` computes the content tree again from the commit and refuses a request that names another one, and CI runs that check on every pull request.

Your approval is your own review of the pull request on GitHub, bound to the commit you see. Nothing an agent can write counts as it. That the approval really comes from you is enforced by GitHub only once agents have an identity of their own ([Issue 99](https://github.com/taspinar/agent-codeyard/issues/99)); until then the scripts ask for your approval in the same cases as before.

<a id="attribution"></a>

## Agent attribution

Coding agents name themselves in what they commit: Claude Code adds a `Co-Authored-By` trailer to a commit and a "Generated with Claude Code" line to a pull request. Whether your project wants that is one setting in [`.agents/attribution.conf`](https://github.com/taspinar/agent-codeyard/blob/main/.agents/attribution.conf):

- `agent-attribution: disabled`, which the template ships, so that the work is published under the owner's own name. With `disabled`, `AGENTS.md` tells the agents, the Claude sessions the scripts start get the matching setting, and `finish-feature.sh` and `publish-feature.sh` refuse a commit of the feature with an agent's trailer and a description with generated attribution text, each reported on its own.
- `allowed`, which a project selects by changing the line if it wants its agents named.

Co-authors who are people are never rejected, and the history of the base is never touched. Codex has no attribution setting and Cursor's is set per user, not per project: `doctor.sh` says so instead of claiming that they are configured.

See the [development guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md) for command options, and <a href="#github-setup">GitHub setup</a> for the settings that enforce merges.
