# Approved Triage Implementer Contract

You are implementing only the approved `FIX_NOW` findings supplied by
`apply-triage.sh`.

## Required context

Read:

- `AGENTS.md`
- the originating GitHub Issue
- the matching active feature plan, when one exists
- the source independent-review artifact (JSON)
- the approved triage artifact (JSON)
- relevant architecture documentation and accepted ADRs
- the current working-tree diff
- the project skills that your prompt lists, if any, by path: guidance below
  all of the above, as `.agents/prompts/implementer.md` says under "Project
  skills"

Your prompt holds the owner's decisions, the block `## Owner decisions` of
the Issue body, when there are any. A fix never departs from one
(`.agents/prompts/implementer.md`, "Owner decisions"): when resolving a
finding would do what a decision ruled out, change nothing for that
finding, record the question under "Open questions" in the handoff note,
naming the finding by its identifier and the decision by its number ("M1
conflicts with owner decision 2: ..."), and stop as an unattended session
stops for a decision of the owner.

Treat the supplied `FIX_NOW` findings as exhaustive: resolve no other
finding. The same defect elsewhere in the feature's own files is part of the
finding it belongs to (see below). Preserve each finding identifier while
working.

## Each finding: its class, and a check before the change

A finding names one place; the same mistake is often made in more. A fix of
the one place leaves the rest for the next round, and a claim that does not
hold costs a change that the next review has to undo. For each `FIX_NOW`
finding:

1. **Name its class** in one sentence: the kind of defect, not its place
   ("the parser assumes LF line endings", not "line 40 is wrong").
2. **Search the class in the feature's own files**: the files the feature
   changes against its base (`git diff --name-only` against the merge base,
   and the untracked files), and their tests. Fix every place there that has
   the same defect, as part of the finding. List the places you checked that
   do not have it, or that you are not sure about, in the handoff note under
   a heading for this triage. Outside those files change nothing: name what
   you found in your report.
3. **Check a claim that can be checked before you change code.** When the
   finding claims that something goes wrong, and a small test or command can
   show it, run it first. Then record exactly one value:
   - `fixed`: the defect existed and is fixed. The evidence is the test or
     command that shows it, preferably the reproduction kept as a test. A
     claim that only reading can check (a missing paragraph, a wrong name) is
     `fixed` with the file that shows it.
   - `refuted`: a reproduction shows that the claim does not hold. The
     evidence is the command and its output. Change no code for the finding.
   - `not_reproduced`: the reproduction ran and does not show the problem.
     That does not prove the finding wrong, and it stays open. Change no code
     for it.
   - `not_executable`: the claim cannot be run here; it needs a browser, a
     platform, GitHub, or another machine. Fix it only when reading the code
     settles the claim, and say in the evidence that the fix is unverified;
     otherwise change no code for it.

Record the value in `checks[]` of the completion record
(`.agents/completion/<issue-number>.json`), one entry per finding, with the
triage file name that the script names:

```json
"checks": [
  {"triage": "feature-12-recipes-review-01-triage.json", "finding": "M1", "value": "fixed",
   "evidence": "tests/search-test.sh: the query with CRLF fails before the fix and passes after"},
  {"triage": "feature-12-recipes-review-01-triage.json", "finding": "S2", "value": "refuted",
   "evidence": "`printf 'a\\n' | ./scripts/search.sh` prints \"a\" and exits 0; the claimed error does not occur"}
]
```

The value is one of the four, and the evidence is required
(`.agents/schemas/completion.schema.json`). Keep the entries of earlier
triages. The scripts read these entries and nothing of the handoff note:
`apply-triage.sh` names the findings you returned as `refuted`,
`not_reproduced`, or `not_executable`, and the next review and its triage
receive every entry as data. Only `fixed` with its evidence counts as
resolved. A none-word or delimiters and punctuation alone are no evidence,
and two entries for one finding of one triage that differ in value or
evidence are a conflict that leaves it open: correct the entry instead of
adding one. The class and the places you checked go into the handoff note,
in its own words. A returned finding stays `FIX_NOW` until the triage decides
again, with the owner's approval: no entry of yours closes it, so do not mark
it resolved anywhere else either.

## Actions

- Make the smallest implementation and test changes needed to resolve every
  supplied `FIX_NOW` finding, including the places of its class in the
  feature's own files.
- Keep existing uncommitted feature work intact.
- Update documentation only when a fix changes documented behavior.
- Inspect the final diff for unrelated changes.

Do not:

- implement `DEFER` or `ACCEPT` findings
- broaden the originating feature
- alter the source review or approved triage artifact
- create or close GitHub Issues
- commit, push, merge, or deploy

If a finding cannot be resolved without changing scope or architecture, stop
and report the conflict instead of implementing deferred work.

## Handoff note

A session can end at any moment, and the next one starts without this
conversation. Keep `.agents/handoffs/<issue-number>.md` current while you work,
after each resolved finding and not only at the end: which `FIX_NOW`
identifiers are resolved, which one you are working on and its next step,
which remain, and what you tried and rejected. If an implementer left a note
there, add to it under a heading for this triage; do not remove its content.

## When a fix fails

Do not try fixes at random. State one hypothesis about the cause, collect
evidence that confirms or refutes it, make one change that follows from the
confirmed cause, and verify. Undo a change whose hypothesis was refuted. After
three materially different failed attempts at one finding, stop as
`.agents/policies/execution-limits.md` says.

## Manual steps

When a fix adds, changes, or removes a step that only the human can do (a
repository or account setting, a secret, a service to enable), update
`.agents/manual-steps/<issue-number>.md` to match: one step per line starting
with `- `, and nothing else. Delete the file when no step remains.

## Summary of the changes

When a fix changes what the feature does, update
`.agents/summaries/<issue-number>.md`, the list the commit message is built
from: lines that each start with `- `. Leave it as it is for a fix that only
corrects what was already described.

## Completion

Report:

- which `FIX_NOW` identifiers were resolved, and which were returned with
  which value
- per finding one line: the class that was searched and the places that
  were checked
- files changed
- checks performed
- unresolved findings or risks

Run `./scripts/verify.sh` after your last change. A pass is recorded for
exactly the content it verified, and the script that follows reuses it; a
change after the run costs another full run. In an unattended session run
`./scripts/verify.sh --changed` instead (or the partial check your task
names): `run-feature.sh` makes the full verification after the session.
When the changed files select every self-test, `--changed` runs none of them
and says so, since that full verification runs them all.

When you update the completion record (`.agents/completion/<issue-number>.json`),
the rules of `.agents/prompts/implementer.md` under "Completion" apply. A
partial run of the checks (`./scripts/verify.sh --changed` or `--only`) is a
check for you, not evidence: the record cannot cite it. For a criterion that
the full verification shows, the evidence is the pass that `run-feature.sh`
makes after your session (or your own run of the full `./scripts/verify.sh`
at a terminal), never the targeted run: write it as "the full verification
that run-feature.sh makes after this session", and do not name
`./scripts/verify.sh --changed` in it, which the gate refuses. `apply-triage.sh` checks the record
with the rules of the completion gate right after your session, and a record
that is missing or does not pass goes back to you before the review.

`scripts/apply-triage.sh` is waiting for this session to end. Ask the human to
exit the session; the script then checks the protected artifacts and verifies
the result, unless your run already verified exactly this content.
