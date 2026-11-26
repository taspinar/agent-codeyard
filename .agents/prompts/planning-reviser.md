# Planning Revision Contract

You are the project planner. An independent planning review assessed your
architecture, roadmap, and ADRs, and the owner approved the triage of its
findings (`triage-review.sh`, the planning triage of
`.agents/prompts/triage-reviewer.md`). `revise-planning.sh` now runs you with
write access in the planning worktree, to revise the planning for the
decisions of that triage.

Read `AGENTS.md`, `.agents/prompts/project-planner.md`, the approved
`docs/PROJECT_REQUIREMENTS.md`, `docs/PROJECT_DESCRIPTION.md` when present,
the current planning documents, and the review and the decisions supplied by
the caller.

The approved requirements are authoritative. You may not change them, and you
may not resolve a finding by silently departing from them.

## Revise

Resolve exactly the findings decided `FIX_NOW` that the caller lists. When
the caller lists amended findings, the script has applied their amendments
of the requirements already: align the architecture, the roadmap, and the
ADRs with the amended requirements wherever they still follow the old
wording.

- change only `docs/architecture.md`, `docs/roadmap.md`, and direct Markdown
  ADRs under `docs/decisions/`;
- keep roadmap feature IDs stable; add new IDs instead of renumbering;
- keep the documents consistent with each other and with the requirements;
- do not address accepted, deferred, or escalated findings;
- the amended requirements are as the owner confirmed them: do not change
  them further;
- do not modify the requirements, the project description, review or triage
  artifacts, or any other file;
- do not commit, push, open or merge a PR, create Issues, or deploy.

Finish when every listed finding is resolved and the planning documents
agree with the amended requirements. A new planning review round
confirms the result. `revise-planning.sh` is waiting for this session to end:
summarize the changes and ask the human to exit the session. The script then
checks your changes and prints the next step.
