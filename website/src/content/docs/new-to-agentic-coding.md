---
title: "New to agentic coding? Start here"
description: "One example from idea to a reviewed change: what a coding agent, a repository, a pull request and an independent review are, and when Agent Codeyard is relevant."
order: 1
---

This page follows one small feature from the idea to the decision about it, and introduces each idea where the story needs it. If you already let a coding agent change code in your own repositories, skip ahead to <a href="#quick-start">Quick Start</a>, the practical guide.

## One feature, from idea to decision

**Illustrative example.** A gym's member application, not a real project: it shows the route, not results.

### The idea

The gym wants two things in its member application: trainers record attendance for their classes, and members see their own training history. You write that down in a few sentences, in your own words.

### Clarify what you need

Before anything is built, an agent asks the questions that only you can answer. For the gym, three of them:

- Who may record or correct attendance?
- May members see other members' data?
- What happens with a wrong registration?

Your answers become agreements: trainers record and correct attendance for their own classes; a member sees only their own history; a correction keeps the original entry visible as corrected. The agent then proposes the order of the work, for your approval: users and roles first, then classes and attendance, then the member's history view. Technically, the agreements are the *requirements* and, per feature, its *acceptance criteria*: how you know it is done.

### The project folder

The code of the application lives in a project folder that keeps every saved version: the **repository**. With Git, every change is saved as a *commit*, so you can see who changed what and go back to any earlier version. On GitHub the repository also holds the *Issues*, the to-do items of the project, each with what has to be done and how you know it is done. Each item of the gym's plan becomes one Issue.

### A coding agent builds it

The work on an Issue is done by a **coding agent**: a program that reads and changes code for you on your own computer. You describe a task in words; the agent reads the files, edits them, runs commands such as the tests, and reports what it did. Claude Code and Codex are coding agents. Each signs in to its own provider, and each has its own limits on what it may do without asking you.

For the attendance feature, the agent also writes a check, a small test that runs with the feature: a member who requests another member's history is refused.

### A change proposal

The finished work is not put into the application directly. It becomes a change proposal: a **pull request**, a proposal to change the main version of the repository. The change is made on a separate *branch*, a copy of the code where work can happen without touching the main version. The pull request shows the difference, runs the automatic checks (*CI*), and waits until someone merges it.

The pull request itself does not block other changes: the repository rules on GitHub must require that every change to the main version goes through a merged pull request, and <a href="#github-setup">GitHub setup</a> shows how to switch them on.

### A second agent reviews it

Before you see the proposal, a second agent reads the change and reports problems, without being able to edit anything: an **independent review**. In Codeyard the reviewer must come from another provider than the agent that wrote the code: when Claude implements, Codex reviews. A reviewer that has the same blind spots as the author finds less.

In the gym example the first version let every signed-in user open the history view. The reviewer reported it, the agent fixed it, and the check of the fix ran.

### You decide

What reaches you is a proposed change with the checks that ran and the review's remarks. You read it and decide whether it becomes part of the project: you *merge* the pull request, or you do not. No script merges for you.

## What Agent Codeyard adds

A coding agent on its own says "done" when it thinks it is done. Agent Codeyard is a set of scripts and rules in your repository that put a fixed route around the agent, the route of the example:

1. You describe the project; an agent asks you questions and writes the requirements, a design and a list of features for your approval.
2. For each feature, an agent implements it in its own branch and records evidence for every acceptance criterion of its Issue.
3. Your checks run, a reviewer of another provider reads the change, and the findings are fixed or recorded with a reason.
4. A pull request is opened with all of that in its description. You merge it; no script merges for you.

How strict the route is depends on the risk of the change: a change to the workflow's own rules always gets the full route, and a project can let documentation-only changes skip the review (their merge then needs you). <a href="#risk-policy">Risk policy</a> explains how.

## When Codeyard is relevant

Codeyard fits when:

- you start a **new** project from the template. There is no installer: a project starts with `gh repo create --template`, and <a href="#quick-start">Quick Start</a> takes you through it. An existing repository can adopt the workflow instead, as <a href="#adopting">Adopting Agent Codeyard in an existing repository</a> describes;
- you want agents to do most of the work, and you want to decide what is merged;
- you can run two coding agents of different providers, because the review needs the second one.

It is less useful for a quick experiment that nobody will maintain, or when you want to write every line yourself with an agent as an assistant. It is also not a security boundary on its own: the agents run on your machine with your permissions, and an agent can have the same GitHub rights as you until agents get an identity of their own ([Issue 99](https://github.com/taspinar/agent-codeyard/issues/99)). <a href="#github-setup">GitHub setup</a> shows the settings that let GitHub enforce who merges.

## What to read next

- <a href="#quick-start">Quick Start</a>: what you need, and your first feature from idea to pull request.
- <a href="#workflow-and-commands">How the workflow works</a>: the route in more depth, with the choices along it.
- <a href="#workflow-reference">Workflow reference</a>: every step with its command, its inputs and outputs, and when it stops.

## Glossary

- **Coding agent:** a program that reads and changes code on your computer from a task in words, such as Claude Code or Codex.
- **Repository** (the project folder): the folder of a project under version control with Git, with its history of commits; on GitHub also its Issues.
- **Commit:** one saved change in the history of the repository.
- **Branch:** a copy of the code where work happens without touching the main version.
- **Issue:** a to-do item of the project on GitHub, with what has to be done and how you know it is done.
- **Requirements and acceptance criteria:** the agreements of the project, and per feature the conditions that show it is done.
- **Pull request** (the change proposal): a proposal to change the main version, with its difference and its checks, until someone merges it.
- **CI:** the automatic checks that run on a pull request.
- **Independent review:** a reading of the change by an agent of another provider, which reports problems and edits nothing.
- **Merge:** taking a pull request into the main version; in Codeyard, always your decision.

You now know what happens on the route and which decisions stay with you. Using it still takes skills this page does not teach: working in a terminal, the basics of Git and GitHub (a commit, a branch, a pull request), reading the difference of a change and judging a review finding, and installing and signing in to two coding agents of different providers.
