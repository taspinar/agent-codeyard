# Lessons for a growing project

What a project should set up on day one so that the workflow stays cheap as
the content grows. The lessons come from one month of
[Physics by Construction](https://github.com/taspinar/physics-by-construction)
(PBC), a project that used this workflow from 2026-10-06 and grew to 94
lessons in a month, while the workflow became its main cost. The review is
recorded in [Issue #313](https://github.com/taspinar/agent-codeyard/issues/313);
the history stays in PBC. The analysis of a repository's own growth belongs
to [#157](https://github.com/taspinar/agent-codeyard/issues/157), defects of
the scripts to [#114](https://github.com/taspinar/agent-codeyard/issues/114).

How to read the evidence:

- **Measured:** a figure counted in PBC's records, as Issue #313 or the PBC
  source named beside it states it.
- **Inferred:** a conclusion drawn from those figures, not tested by a
  comparison.
- **In PBC:** whether PBC itself works this way now. *Not applied* and
  *proposed* mean that the lesson is advice, not a result:
  [PBC #389](https://github.com/taspinar/physics-by-construction/issues/389)
  and [PBC #396](https://github.com/taspinar/physics-by-construction/issues/396)
  were open on 2026-11-06, and nothing in them is a result yet.

PBC names its risk levels 1, 2, and 3; here they are low, medium, and high
(`docs/development.md`, "The risk level of a feature").

## Day-one checklist

Each item is a check you can make in your own repository. Do them before the
first feature, and look again whenever the content doubles.

1. **Durations are recorded.** After the first feature,
   `./scripts/report-runs.sh <issue>` shows the time of every step, and
   `.agents/verification/` holds the duration of every check
   (`docs/development.md`, "Run records").
2. **Verification has tiers.** `scripts/verify.conf` puts its checks in at
   least two groups, so that `./scripts/verify.sh --only <group>` runs a
   fast subset, and you know how long a full run and a fast run take
   (`docs/development.md`, "Groups of checks").
3. **CI can run in parallel jobs.** You have decided at which duration of a
   full run you switch to parallel jobs behind one required check
   (`docs/examples/parallel-ci.yml`, `docs/development.md`, "A parallel
   CI"), and that duration is written down, for example in the
   architecture.
4. **The environment is pinned.** Tool versions are pinned in the
   manifests and lock files, the CI runner image is named by version, not
   as `latest`, and local tools run natively on the machine's architecture.
   Where results are compared byte for byte, two runs of the same commit on
   two runners give the same bytes.
5. **Time limits are measurements.** A duration target is a `budget` check
   (`docs/development.md`, "Budgets"), which reports and does not fail. A
   check fails the verification only for correctness. Every timeout and
   budget has its measured value and margin beside it.
6. **Every capacity limit has a re-assessment point.** Beside each timeout
   or size limit stands the measurement at which you decide again, and
   what you decide between, before you get there.
7. **The protected list is small.** Every `protected:` line of
   `.agents/policies/guardrails.conf` protects something that could make a
   failing verification pass (the gate, what selects the checks, a
   digest), and has a comment that says why. Documents that follow the
   code, such as `docs/architecture.md`, are `sensitive:`, as shipped.
8. **Acceptance criteria are bounded.** Each criterion names the range of
   inputs it covers ("digits and the English number words from zero to
   ninety-nine", not "a count in a data file") and, where it helps, what a
   reviewer should not report.
9. **Heavy checks take the machine-wide slot.** On a shared machine,
   `heavy:` in `scripts/verify.conf` names the checks that need the machine
   to themselves (`docs/development.md`, "Heavy checks and the machine-wide
   slot"), so that a limit on concurrent heavy runs is a lock, not a
   convention.
10. **Small changes are batched.** A one-line fix waits for the next
    feature in the same area, or goes into one Issue with others, unless it
    is urgent.

## The ten lessons

### 1. Record the duration of every step from day one

**Guidance:** know what a step costs before deciding to make it cheaper.
The template records it in its run records; keep them and read them with
`scripts/report-runs.sh`.

- Measured: PBC had no per-step duration record and estimated the steps of
  a run from the times of its files (PBC #389, question 2).
- In PBC: not applied. A per-step record is proposed in PBC #389
  (criterion 3), which is open.

### 2. Make the cost of a pull request grow with the change, not with the content

**Guidance:** before the content grows, select the checks by the inputs a
change touched, reuse results only on identical content, and run
independent groups as parallel CI jobs.

- Measured: a one-lesson pull request with a verified base took 13 min 50 s
  to 14 min 43 s, without the base 22 min 56 s and 25 min 00 s (PBC ADR
  015). A full run executes every lesson, about 0.8 minute per lesson
  (Issue #313); the `build` job alone took 39 to 46 seconds per lesson
  (PBC ADR 014, amendment of 2026-10-24). The median CI run on `main` grew
  from 19 minutes (week of 2026-10-05) to 87 minutes (week of 2026-11-02)
  (Issue #313).
- Inferred: the cost of `main` grew with the content because every push to
  `main` still runs every lesson.
- In PBC: applied to pull requests (PBC ADR 012, parallel jobs behind one
  check; PBC ADR 014, selection against the verified result of `main`).
  Not applied to `main`: incremental `main` (PBC ADR 017) is proposed and
  not accepted, the lesson shards of ADR 014 decision 11 are paused, and
  the decision is point 5 of PBC #396, which is open.

### 3. Pin the environment so that identical inputs give identical bytes

**Guidance:** pin the versions, the architecture, and the runner image, and
record the identity of the environment with every result; reuse a result
only across environments that are known to give the same bytes.

- Measured: comparing results of identical inputs on hosted runners found
  two byte classes of runners: across the classes 7 of 32 lessons differed
  in 10 stored files and the site in 14 of 178 files, and four of seven
  consecutive runs changed class; the logs held no CPU model, locale, or
  time zone (PBC ADR 017, evidence section 5).
- Inferred: incremental verification stalled on this, and the cost was
  paid with longer timeouts instead (Issue #313).
- In PBC: not applied. Recording and enforcing the environment identity is
  a condition of PBC ADR 017, which is proposed and not accepted.

### 4. A time budget is a measurement; a hard failure is for correctness

**Guidance:** a duration over its target is reported for a decision, not a
failure that starts mandatory optimisation. Do not set a fixed limit per
item without margin; a hard limit per item gets a warning level below it
and a table of documented exceptions.

- Measured: the budget of a typical pull request went from 12 to 20
  minutes (PBC ADR 003 to ADR 015); one CI job varied by 3 min 41 s between
  runs that started three seconds apart, so a 15-minute budget would have
  failed on runner variance (PBC ADR 015). Budgets were raised seven times
  in a month (Issue #313).
- In PBC: applied. An exceeded wall-clock budget is a measurement for the
  owner (PBC ADR 020, decision 6); the lesson budget became a warning at 30
  s and a limit of 60 s with exceptions per lesson (Issue #313).
- In the template: a `budget` check never fails the verification
  (`docs/development.md`, "Budgets").

### 5. Keep verification evidence apart from governance paperwork

**Guidance:** a file that only records an approval or a decision must not
change what was verified, so editing it does not invalidate a
verification.

- Measured: an edit of an approval file invalidated a 94-minute
  verification
  ([PBC #266](https://github.com/taspinar/physics-by-construction/issues/266),
  as Issue #313 reports it); 39 commits touched the approval requests, a
  protected class, 23 of them no other protected class (PBC #396).
- In PBC: not recorded as settled in the sources; the approval requests
  were still a protected class on 2026-11-06 (PBC #396).
- In the template: the approval requests and the run and verification
  records are left out of the content fingerprint
  (`scripts/lib/fingerprint.sh`).

### 6. Every rule has an owner and a measurable benefit; keep the protected list small

**Guidance:** protect what makes a pass possible to fake: the gate, the
selection of checks, a digest. Make documents that follow the code
sensitive. A new rule names who owns it and what it measurably prevents.

- Measured: the protected list grew from no entry (2026-10-07) to nine
  lines (2026-10-21); 124 of 215 commits without merges, 58 %, touch a
  protected class, which makes each a high-risk change; 63 commits touch
  `docs/architecture.md`, 28 of them high-risk for that file alone (PBC
  #396). The risk detector gave false positives at least four times (Issue
  #313).
- Inferred: rules were added to repair rules, each right after an
  incident, not from a planned review (Issue #313).
- In PBC: not applied. A smaller protected list (points 1 to 3) and one
  current-state document for the process decisions (point 4) are proposals
  of PBC #396, which is open.
- In the template: `guardrails.conf` ships `docs/architecture.md` as
  sensitive, and the built-in protected list is the gate itself
  (`scripts/lib/guardrails.sh`).

### 7. Write acceptance criteria with a bounded range

**Guidance:** a criterion names the inputs it covers, so that a review can
end; tell the reviewer what is not a finding.

- Measured: a criterion in natural language ("a count in a data file fails
  the build") took five review rounds, each finding a new phrasing
  ([PBC #372](https://github.com/taspinar/physics-by-construction/issues/372),
  as Issue #313 and PBC #389 report it; round 5 was one regex for
  hyphenated number words).
- Inferred: an unbounded criterion gives every review round a new case.
- In PBC: not recorded as a rule in the sources.

### 8. Combine small changes

**Guidance:** every feature pays a fixed cost of at least one full
verification and one review; put small changes together.

- Measured: one-character lesson fixes took 12 to 16 minutes from the pull
  request to the merge after 25 to 30 minutes of work; one fix took 7 h 02
  with three review rounds and three complete local verifications (PBC ADR
  020, context). A complete local verification took about 68 minutes at 38
  lessons (PBC ADR 020) and about 3 hours for a high-risk feature (PBC
  #389).
- In PBC: partly applied. Intermediate review rounds of a high-risk feature
  run a subset of the checks (PBC ADR 020, decision 5); deferring several
  small findings to fix them together is question 4 of PBC #389, which is
  open.
- In the template: `<level>: verification: groups ...` and `triage: light`
  in `.agents/policies/risk.conf` (`docs/development.md`, "What each level
  requires").

### 9. Plan capacity with re-assessment points decided in advance

**Guidance:** a timeout or a capacity limit is a decision with a measured
basis, a margin, and the point at which it is decided again. A "temporary"
raise is a decision too.

- Measured: the CI timeout went from 30 to 45, 60, 90, and 120 minutes in
  25 days, and the lesson capacity from 32 to 45, 64, and 110: five
  capacity decisions (Issue #313; PBC ADR 014, status). At 94 lessons the
  `build` job took 75 minutes, 83 % of its 90-minute timeout (PBC ADR 014,
  amendment of 2026-11-04).
- In PBC: partly applied. The amendments of ADR 014 name re-assessment
  points; the decision between incremental `main` and a raised timeout is
  open (PBC #396, point 5).

### 10. One machine is a constraint

**Guidance:** use native tooling, and limit concurrent heavy runs with a
lock, not by convention.

- Measured: the first full verification of one feature took 4 h 28 min
  with three full runs at once on 10 cores, against about 3 hours for one
  (PBC #389).
- Inferred: memory pressure with four concurrent heavy runs, an x86 `jq`
  under emulation, and flaky timing tests slowed the work (Issue #313).
- In PBC: not applied. PBC had no machine-wide lock (Issue #313); running
  independent groups in parallel on one machine is question 3 of PBC #389,
  which is open.
- In the template: the machine-wide slot for heavy checks
  (`docs/development.md`, "Heavy checks and the machine-wide slot").
