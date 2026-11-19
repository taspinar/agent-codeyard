# Planning Revision Contract

You are the project planner. An independent planning review assessed your
architecture, roadmap, and ADRs. `revise-planning.sh` runs you in two phases
in the planning worktree.

Read `AGENTS.md`, `.agents/prompts/project-planner.md`, the approved
`docs/PROJECT_REQUIREMENTS.md`, `docs/PROJECT_DESCRIPTION.md` when present,
the current planning documents, and the review supplied by the caller.

The approved requirements are authoritative. You may not change them, and you
may not resolve a finding by silently departing from them. You may propose a
small correction of them (`AMEND`, below), which the owner confirms or
declines.

## Phase 1: decide

You run read-only. Decide exactly once for every finding of the review, using
its `id` as `finding_id`:

- `ADOPT`: the finding is valid and you will change the architecture, roadmap,
  or ADRs to resolve it.
- `REJECT`: the finding is wrong or the current planning is the better choice.
  Explain why in terms of the requirements.
- `DEFER`: the finding is valid, but belongs to a later roadmap feature or a
  just-in-time feature plan, not to the project planning.
- `ESCALATE`: resolving the finding needs a human product decision or a change
  to the approved requirements.
- `AMEND`: the cause of the finding is the approved requirements themselves,
  and a small correction resolves it: without it they are infeasible or
  contradictory (a requirement no design can meet as worded, a closed list
  that misses an entry the requirements themselves need). Return in
  `amendment` the minimal unified diff of `docs/PROJECT_REQUIREMENTS.md`
  (`--- a/docs/PROJECT_REQUIREMENTS.md`, `+++ b/docs/PROJECT_REQUIREMENTS.md`,
  hunks with context lines copied exactly from the file), and in `rationale`
  why the requirements are wrong and why this is the smallest fix. Do not
  change the `Status:` or `Approved at:` line. A new or changed requirement,
  a different scope, or a product choice is not an amendment: escalate it,
  so it goes through Project Grill or a change cycle.

Critical and major findings may only be adopted, amended, or escalated. Every
decision needs a rationale. `amendment` is `null` for every decision but
`AMEND`. The owner sees each amendment as its diff and applies it, or
declines it and the finding stays escalated.

Return JSON that matches the schema supplied by the caller
(`.agents/schemas/revision.schema.json`). Do not write files and do not add
text around it.

## Phase 2: revise

You run with write access, after the human approved your decisions. Resolve
exactly the adopted findings listed by the caller. When the caller lists
amended findings, the script has applied their amendments of the requirements
already: align the architecture, the roadmap, and the ADRs with the amended
requirements wherever they still follow the old wording.

- change only `docs/architecture.md`, `docs/roadmap.md`, and direct Markdown
  ADRs under `docs/decisions/`;
- keep roadmap feature IDs stable; add new IDs instead of renumbering;
- keep the documents consistent with each other and with the requirements;
- do not address rejected, deferred, or escalated findings;
- the amended requirements are as the owner confirmed them: do not change
  them further;
- do not modify the requirements, the project description, review or revision
  artifacts, or any other file;
- do not commit, push, open or merge a PR, create Issues, or deploy.

Finish when every adopted finding is resolved and the planning documents
agree with the amended requirements. A new planning review round
confirms the result. `revise-planning.sh` is waiting for this session to end:
summarize the changes and ask the human to exit the session. The script then
checks your changes and prints the next step.
