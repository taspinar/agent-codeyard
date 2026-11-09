# Plan: Issue #313, lessons of one month of growth (PBC) as guidance

## Home

A new file, `docs/growth-lessons.md`, rather than a section of
`docs/workflow.md`: the workflow file describes what the workflow does, and
this is advice on how a project sets it up and keeps it small. Not an ADR
note: the guidance decides nothing for a project, and an ADR change needs the
owner's approval. Not `.agents/lessons/`: that directory holds the failure
lessons of agents.

Pointers:

- `docs/workflow.md`: one sentence in the introduction.
- `docs/project-map.md`: a row in "Project documents".
- The documentation site lists the template's `docs/` files only in the
  "Project documents" table of `website/src/content/docs/technical-reference.md`;
  a row there, nothing else on the site.
- `.agents/template.conf`: the file joins `paths`, as
  `docs/examples/parallel-ci.yml` did in #295. Without it, a project that
  syncs the template gets the link from `docs/workflow.md` but not the file,
  and its `check-docs.sh` fails.

## Level

Documentation and `.agents/template.conf` only. Read on the base:
`.agents/policies/risk.conf` has no low class and `default: medium`; none of
the changed paths is in its high class or an escalation. None is in
`guardrails.conf` or the built-in protected list of
`scripts/lib/guardrails.sh`. Level: medium by path. No protected path.

## Sources and evidence

Only Issue #313, PBC ADRs 003, 005, 012, 014, 015, 017, 020, and PBC Issues
#389 and #396 (read with `gh` on 2026-11-06). Every figure names its source.
"Measured": a figure counted in those sources. "Inferred": a conclusion drawn
from them, not tested. Each lesson states whether PBC has applied it; what
depends on PBC #389 or #396 says that they are open and that it is a proposal.

## Steps

1. Write `docs/growth-lessons.md`: the evidence key, the day-one checklist
   (followable without PBC), the ten lessons with evidence, PBC status, and
   what the template already provides.
2. Add the pointers above.
3. `./scripts/verify.sh`.

## Out of scope

Scripts, risk levels, protected paths, verification rules, the template's own
CI; analysis of a repository's own growth (#157); script defects (#114);
periodic analysis (#131).
