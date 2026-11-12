---
title: "Agent roles and models"
description: "Which tool and model does each job of the workflow: the roles, the default configuration, and how to change it per role, per run and per risk level."
order: 4
---

## The roles in plain words

A role is a job in the workflow, not a person or an account. Four jobs do most of the work:

- **The planner** asks you about a new project and writes its requirements, its design and its list of features. In the configuration these are `project-grill` and `project-planner`; a second agent, the `planning-reviewer`, reviews the plan before you approve it.
- **The builder** implements one feature at a time and writes its tests. In the configuration it is the `implementer`.
- **The reviewer** reads the finished change and reports problems. It cannot edit files, and it must come from another provider than the builder.
- **The fixer** repairs the review findings that were chosen to be fixed now, and nothing else. In the configuration it is the `triage-implementer`; the `triage` role proposes which findings it gets.

You choose which tool and which model does each job. The template's own choice is the <a href="#shipped-configuration">default configuration</a> below; nothing requires it.

<a id="terms"></a>

## Role, tool, provider and model

Four words, each for one thing:

| Word | What it is | Example |
| --- | --- | --- |
| **Role** | A job in the workflow | `implementer`, `reviewer` |
| **Tool** | The coding agent's command-line tool that does the job; the configuration calls it the agent | Claude Code (`claude`) or Codex (`codex`) |
| **Provider** | The company whose models the tool uses | Anthropic for Claude Code, OpenAI for Codex |
| **Model** | The model the tool runs, by the name the tool knows it by | `opus`, `gpt-6-luna` |

One line of [`.agents/agents.conf`](https://github.com/taspinar/agent-codeyard/blob/main/.agents/agents.conf) names all of them for one role: the role, then the tool, then the model. The provider follows from the tool, and an independent review means another tool, and so another provider, than the one that implemented:

```
implementer: claude opus
reviewer: codex gpt-6-luna
```

The supported tools are Claude Code and Codex. Which models you can use depends on your account with that provider; the workflow passes the model name on as you wrote it and never replaces it with another one, and an unknown tool is an error. `./scripts/doctor.sh` checks that each configured tool is installed.

<a id="roles"></a>

## Agent roles and models

| Role | What it does |
| --- | --- |
| `project-grill` | Asks you questions about a new project and writes the requirements |
| `project-planner` | Writes the architecture, the roadmap, and the decision records |
| `planning-reviewer` | Reviews the plan, read-only |
| `implementer` | Implements a feature and writes its tests |
| `reviewer` | Reviews a feature, read-only |
| `triage` | Proposes what to do with each review finding |
| `triage-implementer` | Fixes the findings that were selected |
| `analyst` | Compares the runs of several features and proposes improvements, read-only (<a href="#technical-reference/learning">learning from your runs</a>) |
| `assessor` | Writes the report and the proposal of an assessment of an existing repository, read-only (`assess-repository.sh`) |

The reviewer must use a different tool than the implementer, at every risk level: that is what makes the review independent. `review-feature.sh` refuses to start a reviewer that resolves to a tool the implementer of the feature ran with, and `doctor.sh` warns when a reviewing role and the role it reviews resolve to the same tool.

<a id="default-configuration"></a>

## Shipped configuration

This is the default configuration of the template, and the one the other pages of this site refer to. Set the tools, models and levels your project wants.

| Role | Low and medium risk | High risk |
| --- | --- | --- |
| `implementer`, `triage-implementer` | Claude Code, `opus` | Claude Code, `fable` |
| `reviewer` | Codex, `gpt-6-luna` | The same |
| `triage` | Claude Code, `sonnet` | The same |
| `project-grill`, `project-planner` | Claude Code, `fable` | |
| `planning-reviewer` | Codex, `gpt-6-astra` | |
| `analyst`, `assessor` | Claude Code, `fable` | |

The active lines of [.agents/agents.conf](https://github.com/taspinar/agent-codeyard/blob/main/.agents/agents.conf):

```text
project-grill: claude fable
project-planner: claude fable
planning-reviewer: codex gpt-6-astra
implementer: claude opus
implementer@high: claude fable
reviewer: codex gpt-6-luna
triage: claude sonnet
triage-implementer: claude opus
triage-implementer@high: claude fable
analyst: claude fable
assessor: claude fable
```

Why a stronger model at high risk: the template chose it for the features that change the workflow and its gate, after a few of its own runs. That is the experience of one repository, not a measured result for every project. Codex stays supported as implementer for a project that configures it.

## Further configuration

<a id="overrides"></a>

### One run with another tool or model

`--agent` and `--model` on a workflow script override the tool and the model of its role for that run, such as `--agent codex --model gpt-6-luna`.

<a id="risk-levels"></a>

### Models per risk level

A role of a feature (`implementer`, `reviewer`, `triage`, `triage-implementer`) can also have a line per <a href="#risk-policy/risk">risk level</a> of the feature, such as `implementer@high: claude fable` next to `implementer: claude opus`. A script that starts the role takes `--agent` and `--model` first, then the line of the level the feature has at that moment, then the plain line; a later session of a feature never runs at a weaker level than an earlier one did. Without a level line the plain line applies. `doctor.sh` validates the lines, and `report-runs.sh` shows the calls per level and model.

<a id="skills"></a>

### Project skills

A skill is guidance for an agent, such as a design method or a writing rule. The template bundles none, and a project without skills has nothing to install or set up. A project that wants one keeps it in its repository, in `.agents/project-skills/<name>/`, with a `skill.conf` that says where it comes from: the source, the exact commit, the licence, whether it is the upstream text or an adapted one and what changed, and a checksum of its files.

The plan of a feature selects the skills the work needs, each pinned by that checksum. The builder, the reviewer, and the fixer are then given the same files by path, whatever their tool would discover by itself, so Claude and Codex read the same guidance. A skill that does not exist, or whose files no longer match the selected checksum, stops the step with a message that says which.

A skill is the lowest source of guidance: the Issue, the decision records, `AGENTS.md`, and the plan come first. It cannot waive your approval, widen an agent's permissions, or count as evidence that a feature is done; a test or a check does that. Nothing in a skill is installed, downloaded, or run. A new version of a skill is an ordinary reviewed change, and a change to an existing skill makes the feature high risk, as a change to an agent's instructions does. `./scripts/check-skills.sh` checks the metadata in the verification. The [development guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md) has the format and a worked example.
