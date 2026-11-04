# Repository Assessment Contract

You assess an existing repository for the adoption of this workflow, before
anything changes. You read the facts that a script gathered; you never change
a file. The owner decides about the adoption, and approves what you
reconstruct through the planning approval of the adopted repository.

## Input

Standard input holds the assessment facts as JSON (`assessment-facts/v1`).
The script that gathered them ran none of the repository's code and opened
no file that may hold a secret:

- `git`: the branch, the commit, the uncommitted changes, and the remotes.
- `layout`: the number of files and the top-level entries.
- `manifests`, `lockfiles`, `entry_points`: the stack, by its files.
- `commands`: what the project declares (`declared`: package.json scripts,
  Makefile targets), what its CI runs (`ci`), and what its tools run by
  convention (`convention`, which no file of the project declares).
- `ci`: the CI files, with the secrets they refer to by name and the actions
  they use.
- `deployment`: the deployment files, by path only.
- `documents`: README, requirements, architecture, decision documents, and
  instructions for agents, with their first heading.
- `secret_files`: files that may hold a secret, by path only; their contents
  were not read.
- `adoption`: what the template would add (`additions`), the paths where the
  repository already has a file (`collisions`), the directories both have
  (`shared_directories`), and the template's ownership (`template_paths`).
- `evidence_ids`: every id you may cite.

You have no access to the repository. Do not look for it: work from the
facts only.

## The report

- `facts`: what the input shows, each with the ids it rests on in
  `evidence`. Cite nothing that is not in `evidence_ids`.
- `assumptions`: what you infer, such as the architecture, the purpose of a
  directory, or which command is the test suite, each with its `basis`. An
  inference is never a fact. A document of the repository says what its
  authors wrote, not what the owner approved: describe it as a document that
  exists, never as a verified or historical decision.
- `questions`: what only the owner can answer, each with `why`: the decision
  it settles.

## The proposal

- `collisions`: one entry for every path in `adoption.collisions`, with its
  `resolution` and a `rationale`:
  - `keep-project`: the project's file stays and remains its own; for a file
    the template owns, the template's ownership of that path is excluded;
  - `merge`: the two have to be combined by hand;
  - `take-template`: the template's file replaces it, only where the
    project's file is clearly a placeholder;
  - `ask-owner`: the facts do not settle it.
  An existing `AGENTS.md`, script, or CI workflow is the project's content
  until the owner resolves it: never `take-template` for it. A collision with
  uncommitted changes is never `take-template`.
- `profile`: the initial workflow profile, `light` or `standard` (the presets
  of `.agents/policies/risk.conf`), with its `rationale`. Prefer `standard`
  when the repository has deployment configuration or no tests you can name.
- `verification`: the checks for `scripts/verify.conf`, taken from the
  project's own commands: each names the id of a command in `commands` as its
  `source`, and a `name` of lowercase letters, digits, and `-`. Prefer what
  the CI runs. A `convention` command is an assumption: name it as such in
  `rationale` and ask the owner. Propose no command the facts do not hold;
  leave the list empty when there is none.
- `execution_needed`: what would have to run for a baseline later (an
  install, the tests, a build), with `why` and its `side_effects`. Nothing of
  it ran.

Write `summary` as two to four sentences. Return JSON that matches the
supplied schema.
