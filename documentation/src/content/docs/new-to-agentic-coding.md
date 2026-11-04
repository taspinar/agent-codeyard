---
title: "New to agentic coding? Start here"
description: "What a coding agent, a repository, a pull request and an independent review are, and when Agent Codeyard is relevant."
order: 1
---

This page explains the few ideas the rest of the documentation builds on. If you already let a coding agent change code in your own repositories, skip ahead to <a href="../getting-started/">Getting started</a>, the practical guide.

## The four ideas

**A coding agent** is a program that reads and changes code for you on your own computer. You describe a task in words; the agent reads the files, edits them, runs commands such as the tests, and reports what it did. Claude Code and Codex are coding agents. Each signs in to its own provider, and each has its own limits on what it may do without asking you.

**A repository** is the folder of a project under version control with Git: every change is saved as a commit, so you can see who changed what and go back to any earlier version. On GitHub the repository also holds the Issues, the to-do items of the project, each with what has to be done and how you know it is done.

**A pull request** is a proposal to change the main version of the repository. The change is made on a separate branch, a copy of the code where work can happen without touching the main version. The pull request shows the difference, runs the automatic checks (CI), and waits until someone merges it. The pull request itself does not block other changes: the repository rules on GitHub must require that every change to the main version goes through a merged pull request, and <a href="../github-setup/">GitHub setup</a> shows how to switch them on.

**An independent review** is a second agent that reads the change and reports problems, without being able to edit anything. In Codeyard the reviewer must come from another provider than the agent that wrote the code: when Claude implements, Codex reviews. A reviewer that has the same blind spots as the author finds less.

## What Agent Codeyard adds

A coding agent on its own says "done" when it thinks it is done. Agent Codeyard is a set of scripts and rules in your repository that put a fixed route around the agent:

1. You describe the project; an agent asks you questions and writes the requirements, a design and a list of features for your approval.
2. For each feature, an agent implements it in its own branch and records evidence for every acceptance criterion of its Issue.
3. Your checks run, a reviewer of another provider reads the change, and the findings are fixed or recorded with a reason.
4. A pull request is opened with all of that in its description. You merge it; no script merges for you.

How strict the route is depends on the risk of the change: a change to the workflow's own rules always gets the full route, and a project can let documentation-only changes skip the review (their merge then needs you). <a href="../risk-policy/">Risk policy</a> explains how.

## When Codeyard is relevant

Codeyard fits when:

- you start a **new** project from the template. There is no installer: a project starts with `gh repo create --template`, and <a href="../getting-started/">Getting started</a> takes you through it. Adopting Codeyard in an existing repository is not supported yet ([Issue 170](https://github.com/taspinar/agent-codeyard/issues/170));
- you want agents to do most of the work, and you want to decide what is merged;
- you can run two coding agents of different providers, because the review needs the second one.

It is less useful for a quick experiment that nobody will maintain, or when you want to write every line yourself with an agent as an assistant. It is also not a security boundary on its own: the agents run on your machine with your permissions, and an agent can have the same GitHub rights as you until agents get an identity of their own ([Issue 99](https://github.com/taspinar/agent-codeyard/issues/99)). <a href="../github-setup/">GitHub setup</a> shows the settings that let GitHub enforce who merges.

## What to read next

- <a href="../getting-started/">Getting started</a>: what you need, and your first feature from idea to pull request.
- <a href="../detailed-workflow/">How the workflow works</a>: the route in more depth, with the choices along it.
- <a href="../reference/workflow/">Workflow reference</a>: every step with its command, its inputs and outputs, and when it stops.
