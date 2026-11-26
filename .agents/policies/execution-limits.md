# Execution Limits

Stop and escalate when:
- a major architecture change or accepted ADR violation appears necessary;
- requirements materially conflict or cannot be inferred safely;
- production access/destructive action is required;
- the task is expanding beyond its issue/plan;
- three materially different repair attempts fail (in a triage: three at one
  finding): record the attempts, the evidence, the current state, and the next
  recommended step under "Tried and rejected" in the handoff note of the Issue
  (`.agents/handoffs/<issue-number>.md`), and report to the human;
- changes unexpectedly span many unrelated components.

Do not repeatedly retry the same approach or refactor unrelated code to make a local task pass.
