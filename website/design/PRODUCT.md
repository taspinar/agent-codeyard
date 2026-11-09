# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

Astro, static output, Markdown/MDX content, islands only where interaction is needed; published by GitHub Actions to GitHub Pages under `/agentic-coding-template/`, with site URL and base path configurable for a future root domain. No backend, no external services, no tracking. (Owner decision, 2026-10-30, Issue #234.) The design phase builds static HTML/CSS in `/home/ubuntu/act-runs/design/`; the files move to `website/` in #237.

## Users

First: someone who wants to understand what Agent Codeyard is and what it adds, without knowledge of agentic coding: what you can build with it, what AI does and what Codeyard adds, why it starts with questions and a plan, when you are needed, and what you need to use it. The first reading layer of every page is written for this person: plain words first, a technical term only after its plain name (#328, #329). Understanding needs no programming; using it needs a terminal, Git and a GitHub account, and the site says so instead of suggesting a no-code tool.

Next to them: a developer who will use it, who already uses AI coding agents (Claude Code, Codex) and looks for structure around them: planning, independent review, verification, traceable evidence and human control. Reads critically, wants to see the real mechanism quickly, and wants to try the GitHub template without friction. The documentation serves the same person once they use it.

## Product Purpose

The Agentic Coding Template (ACT) is an open-source, risk-aware development workflow for AI coding agents: from requirements to verified pull requests, with independent reviews, traceable evidence and human control. The site explains what ACT is, shows how it works, states its engineering principles, and gets a developer started. Success: within seconds the visitor understands that ACT is a workflow, not an assistant; within minutes they have seen the real lifecycle and know how to start.

## Positioning

"Build software with AI, with a clear plan and checks along the way." Supporting line: "Describe what you want to build. Agent Codeyard helps you clarify what you need, plan the work, and guide AI coding tools as they build and check each change. You review the result and decide whether to accept it." AI coding tools write code from a description; Codeyard organises their work. The coding tools can plan, ask, test and support reviews themselves; what Codeyard adds is recorded agreements, assigned roles, checks, and progress that the next session can use. No claim of measured time, cost or error savings, and no "always", "nobody" or "nothing" about working without it. ACT does not write code; Claude Code and Codex do. ACT structures their use: planning with approval, a risk level computed from the change and never lowered by an agent, an implementer and a reviewer of different providers, recorded verification evidence and completion records, triage with cross-round continuity, and a merge that stays with the owner. The site states precisely which controls ACT enforces itself and which need GitHub repository settings (rulesets, required checks, CODEOWNERS; a separate agent identity is open work, #99).

## Operating Context

ACT lives in a Git repository created from the template; its scripts run on the developer's machine (`start-feature.sh`, `review-feature.sh`, `run-feature.sh`, `verify.sh`, `check-risk.sh`, `report-runs.sh`), its policies are files (`.agents/agents.conf`, `.agents/policies/risk.conf`, `.agents/attribution.conf`), and its artifacts are GitHub Issues, branches and worktrees, review and triage records, completion records, and pull requests. Visitors arrive from GitHub, links and searches.

## Capabilities and Constraints

- Shipped agents: Claude implements (opus; fable at High), Codex `gpt-6-luna` reviews, Claude sonnet triages; the reviewer's provider must differ from the implementer's, so a feature review needs both providers.
- Risk levels Low, Medium, High from paths, fixed escalations, agent assessments and the owner's hints; never lowered. Workflow profiles `light` / `standard` are a separate dimension; without a profile line nothing changes. Agent permission profiles (write, read-only, unattended) are a third, separate thing.
- Under the shipped policy every feature is reviewed; a project can let Low features skip review (`low: review: none`, or `profile: light`), and then the merge needs the owner.
- The current site's useful parts must survive: the interactive workflow walkthrough (step-by-step versus unattended), the step tables, the configuration tables.
- The public name, repository URL and domain must be changeable in one place.
- The audit of Issue #235 is the reference for what is true; nothing unmerged is presented as released.

## Brand Commitments

Name: Agentic Coding Template (ACT). Positioning line: "Build software with AI, with a clear plan and checks along the way." Supporting line: "Describe what you want to build. Agent Codeyard helps you clarify what you need, plan the work, and guide AI coding tools as they build and check each change. You review the result and decide whether to accept it." The site's description (`site.config.ts`), the home page title, meta description and `og:description` carry the same message. Navigation labels: How it works, Why Codeyard, Projects, Docs, About, Get started, GitHub. Illustrations of the workflow use the one illustrative gym scenario of #328, labelled "Illustrative example". Voice: plain, technical, second person, understated; no superlatives, no marketing claims. The owner explicitly bans: AI robots, glowing brains, shields, locks, rockets, spheres, 3D blobs, circuit-board imagery, purple/blue gradients, glassmorphism, glowing borders, heavy shadows, grids of identical icon cards, repeated three-column feature sections, scroll-triggered reveals, particle effects, invented statistics or testimonials, decorative icons. Light and dark themes, neither relying on gradients or glow. Origin: ACT is central; Physics by Construction may be named discreetly as the project several lessons came from; JIDAI at most on the About page; no organisations or people presented as users.

## Evidence on Hand

Real, linkable evidence only: GitHub Issues and pull requests of this repository with their published review and triage comments (recommended end-to-end example: #217 → PR #222; owner in the loop: #189 → PR #194; short path: #204 → PR #205; clarification: #16 → PR #213), run records with measured verification durations and review rounds (`.agents/records/`), the run analysis of 2026-10-28. There are no testimonials, user counts, benchmarks or customers; none may be invented.

## Product Principles

1. Accuracy before persuasion: every claim traceable to a script, a policy file or a recorded run.
2. Show the mechanism, not a metaphor: real lifecycles, real artifacts, real files.
3. The human stays in control, and the site says exactly where.
4. Understated confidence: describe what exists, mark what does not.
5. Proportionate: the workflow's own principle of matching effort to risk applies to the site's density and tone.

## Accessibility & Inclusion

WCAG 2.2 AA in both themes; every interaction keyboard-operable with visible focus; the workflow visualization has a complete text alternative and works without animation; `prefers-reduced-motion` honoured.
