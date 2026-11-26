# Development

## Prerequisites

- Bash 4 or newer. Every script of `scripts/` checks it first
  (`scripts/lib/bootstrap.sh`), before it sources a library, and stops with
  status 78 and the install command below Bash 4.
- Git
- GitHub CLI (`gh`), installed and authenticated
- `jq` 1.6 or later
- Codex or Claude CLI when that agent is selected
- For the documentation site of the template (`website/`), which
  `./scripts/verify.sh` builds and checks: Node.js (the version in
  `website/.nvmrc`), and Playwright Chromium with its Linux system
  libraries. Install both once with
  `cd website && npm ci && npx playwright install --with-deps chromium`
  (the system libraries need `sudo`). The check runs `npm ci` again only
  when `website/node_modules` is missing or older than
  `website/package-lock.json`. It installs a missing Chromium
  itself, which needs network access once, and never downloads it again when
  it is installed; when Chromium cannot be installed or does not start for
  missing system libraries, it stops with the command to run. A project
  without `website/` needs none of this.
- For the workflow self-tests (`tests/*-test.sh`, see "Workflow self-tests"):
  GNU `sed`, GNU `timeout` and `date` (GNU coreutils), next to Bash 4, Git,
  and `jq`. A Linux system has them. On macOS install them once with
  `brew install bash coreutils gnu-sed jq`, and put Homebrew's `bin`
  directory and its GNU directories before `/bin` on `PATH`:
  `$(brew --prefix)/opt/coreutils/libexec/gnubin`,
  `$(brew --prefix)/opt/gnu-sed/libexec/gnubin`, and `$(brew --prefix)/bin`.
  The self-tests find the GNU tools in those directories also when they do
  not come first. The workflow scripts use the `stat` and `date` that come
  first on `PATH` in the form that tool takes (GNU `stat -c` and `date -d`,
  or BSD `stat -f` and `date -j -f`), whatever the system is. The
  template has an on-demand macOS verification of its own, which runs
  `./scripts/verify.sh --all` on macOS when the owner starts it (Actions,
  "macOS", "Run workflow"); it runs on no push and on no schedule and is no
  required check.
- Project-specific tools documented in this file after the template is adopted

Run `./scripts/doctor.sh` to check these prerequisites, including that you can
push to `origin` with the Git identity in use. It runs the preflight of
`./scripts/verify.sh` read-only (see "Missing prerequisites"): a missing
prerequisite of the self-tests is a warning with its install command. It reports each check
as `OK`, `WARNING`, or `FAILED` with a fix hint, exits non-zero when a required
prerequisite is missing, and never modifies anything of the project. A missing
agent CLI fails when `.agents/agents.conf` assigns it to a role and is a
warning otherwise. It fails when Git has no commit identity (`user.name` and
`user.email`, at any configuration level), with the two `git config` commands
that set one: without it `finish-feature.sh` fails at the commit, after the
implementation, the review, and the triage are done. It starts no agent
session: whether a Codex role with write access can write the runtime
directories under `.agents/` shows at its first real session (see "Codex and
`.agents/`" under "Configuring agents"). It also warns when a pull request
into `main` can be merged while its checks fail, because no ruleset or branch protection requires a status check; see
`docs/repository-setup.md`. In a project, it warns once while approval
requests or plans of the template's own Issues remain, with their count and
the command that removes them, `./scripts/start-planning.sh` (see "Project
bootstrap workflow"); it removes nothing itself.

Keep `./scripts/verify.sh` as the stable verification entry point for humans,
agents, and CI.

## Configuring verification

`./scripts/verify.sh` runs the checks declared in `scripts/verify.conf`, one
per line:

```text
<name>: <command>
```

After adopting the template, replace the template checks with those of the
project's stack, for example:

```text
lint: ruff check .
tests: pytest
```

Every listed check is required. Each command runs with `bash -eo pipefail`
from the repository root, so a failing step in a pipeline or command sequence
fails the check. Its first word is the required tool. Verification fails
when that tool is missing or not executable, when a command exits non-zero, or
when the configuration is missing, empty, or malformed. All checks run even
after a failure, one at a time or, with `parallel: <n>`, several at a time
(see "Checks at the same time"), and a summary lists each check as `PASS` or
`FAIL`.

Every check is timed: `-- <name> took <seconds>s` follows its output, also in
a partial run. The durations of a run are recorded with the pass in
`.agents/verification/durations` (see "Recorded verification") and in the
run record (the `verification` event, `checks`), so the growth of the
verification shows while it happens; `./scripts/report-runs.sh` lists the
five slowest checks of every verification of a run ("Slowest checks"). A
target for the duration of the checks is a budget (see "Budgets").

There is no automatic stack detection and no optional check: remove a check
from `scripts/verify.conf` rather than letting it be skipped.

### The inputs of a check

A check that reads only a known part of the repository may name it, so that
it runs only when that part changed. One line per check, in
`scripts/verify.conf` only:

```text
inputs: <check> <input>...
```

Each input is a Git pathspec, as under `paths:` of
`scripts/verify-workflow.conf`, or `@<file>`: a list file of the repository,
which is an input itself and holds one input per line, with `#` for
comments:

- `<path>`: a file whose content the check reads. It counts when it changes,
  is added, or is removed.
- `exists <path>`: a path whose existence alone the check reads, such as a
  file a page links to. It counts only when it is added or removed, as by a
  rename, not when its content changes.

The inputs are compared as the workflow self-tests are (see "Workflow
self-tests"): with the tree of the last trusted pass of the run of a
workflow script, or without one with the base of the feature, counting
uncommitted and untracked files. When no input changed, the check does not
run, and the summary shows

```text
SKIP  <check>: none of its inputs ('inputs:' in scripts/verify.conf) changed since <base>; --all runs it
```

When one changed, the output says which before the checks start
(`<check> runs: <path> differs from <base>`). The check runs when that cannot
be determined: a list file is missing, the base is unknown, or the run is on
the base branch itself, where nothing tells a change apart from the base, as
on a push to `main` in CI. `./scripts/verify.sh --all` and `--baseline` run
it always. `--only` and `--changed` compare the inputs as a full run does.
A pass that skipped a check says so in its record (`skipped-by-inputs:`),
and `--all --reuse` does not reuse it.

The list must be complete: a check whose inputs are not all named can pass on
a change it never saw. Adding an `inputs:` line therefore needs the owner's
approval at the merge, as an `accepted-failure:` does
(`scripts/check-guardrails.sh`). Name only what the check reads, and give the check a
test of its list where the list is long. The template's website check
is the example: `inputs: website website @website/check-inputs.conf`. The
list names the files outside `website/` whose content the site check reads
(`.agents/agents.conf`, `.agents/policies/risk.conf`, the website line of
`scripts/verify.conf`), and, as `exists`, every repository file a page
links to and every script a page names. `website/check.sh --build` fails
when the list misses a path that a page names, or a file outside `website/`
that a source of the site names by a relative path (`../`), and when it
lists an `exists` that no page names. A change of only a script's content
skips the website check; a rename of a script that a page names runs it, and
the check then reports the page.

### Groups of checks

A check may name a group in square brackets after its name:

```text
lint [code]: ruff check .
unit-tests [code]: pytest tests/unit
site-build [build]: ./scripts/build-site.sh
tests-in-a-browser [e2e]: pytest tests/e2e
```

- `./scripts/verify.sh` runs every check, whatever its group. Nothing changes
  for the developer and for the workflow scripts.
- `./scripts/verify.sh --only code` runs the checks of one group, and
  `--only code,build` those of several, in the order of the file.
- `./scripts/verify.sh --groups` prints the groups that have a check.
- A check without a group is in the group `default`.
- An unknown group is an error, so a renamed group cannot pass unnoticed.
- A check that runs one part of a split test suite declares that part after
  its group: `<name> [<group>] partition <file>: <command>`.
  `./scripts/verify.sh --partitions` prints the declarations; the run does not
  change (see "A parallel CI").

Groups exist for a CI that has outgrown one job: each job runs
`./scripts/verify.sh --all --only <group>`, and one job that needs all of them
is the required check. The CI of the template works this way (see "A parallel
CI"). Every check stays declared in `scripts/verify.conf`
or `scripts/verify-workflow.conf`; none is declared in the workflow file.
Such a CI has to run **every** group, `default` included, or a check that is
added without a group runs on a laptop and never in CI.
`./scripts/check-ci-groups.sh` compares the output of `--groups` with the
groups that the jobs of the workflow file declare; see "A parallel CI".

A partial run is never a verification. With `--only` nothing is recorded as
passed, nothing is written into the record of a run it was started in, and
`--reuse` is refused, so `review-feature.sh` and `finish-feature.sh` still run
every check. No review is made on a partial run: `review-feature.sh` runs
the full verification before every round, or none with `--unverified`, and a
review artifact that records `verification.status: partial` (written before
#519) is refused as invalid (the risk policy's `verification: groups`, which
asked for such rounds, is refused since #443, see "What each level
requires"). A failing partial run removes an
existing record, like any failing run. The workflow self-tests keep their own
rule with `--only`: they run when a workflow file changed, or with `--all`.

The other partial run is `./scripts/verify.sh --changed`, the targeted check
of an unattended agent session: every check of `scripts/verify.conf`, and of
the self-tests only those of the files changed since the base, the check that
runs `tests/<x>-test.sh` when that file, `scripts/<x>.sh`, or
`scripts/lib/<x>.sh` changed, or when `scripts/<x>.sh` or `scripts/lib/<x>.sh`
names a changed file of `scripts/lib/` that is not a shell script as
`lib/<name>`: a change to `scripts/lib/report.jq` selects `report-runs`, since
`report-runs.sh` reads it. The self-tests of one script may be split over
several files that source a shared part `tests/lib-<x>.sh`: a test that
sources it counts as a test of `scripts/<x>.sh`, so a change to that script
or to the shared part selects every part (`tests/lib-run-feature.sh` and
the parts `tests/run-feature-<part>-test.sh`). A changed library
`scripts/lib/<y>.sh` also selects every self-test whose script, library, test
file, or shared part sources it, directly or through another library: a
change to `scripts/lib/fingerprint.sh` selects the tests of the scripts that
source `lib/records.sh`, which sources it. Only one form of sourcing is
recognized: a line of its own `source "<path>/<y>.sh"`, with the path in
double quotes and nothing after it but spaces, whose path is not under
`tests/`. A `.` command, a path in single quotes or without quotes, or a line
with more after the path (`source "$dir/lib/y.sh" || exit 1`, a comment) is
not seen, and a change to that library then does not select the self-test
that sources it that way; the full verification still runs it. Any other changed file directly
in `tests/` that is not a self-test, such as `tests/lib-fakes.sh`, which every
self-test sources, or a `tests/lib-<x>.sh` that no self-test sources (also
when `scripts/<x>.sh` exists), selects every self-test; the files in the directories
under `tests/` are the project's. A self-test that runs no test
file of its own is left to the full verification, and so is
`adopted-project`, whatever changed, also `tests/adopted-project-test.sh`
itself or `tests/lib-fakes.sh`: it runs other self-tests again in a fixture
project and takes minutes (see "Workflow self-tests"), and the summary says
that it was left to the full verification. When the changed files select
every self-test that `--changed` can select (a change to
`tests/lib-fakes.sh`, or to a library that every self-test sources), it runs
none of them, and its `SKIP` line says that the full verification that
`run-feature.sh` makes after the session runs them all: the session would
otherwise run the complete suite only for the orchestrator to run it again
on the same content (Issue 490). A smaller selection runs as before. It records nothing, takes
neither `--only`, `--all`, nor `--reuse`, and the completion gate refuses it
as evidence like `--only`. The implementer and the triage-implementer of `run-feature.sh` run
it instead of the full suite; the run makes the full verification after the
session (see "Recorded verification").

### The project's CI setup

A project installs its own toolchains and dependencies in CI (Python, uv,
Node.js, Terraform, ...) without editing `.github/workflows/ci.yml`: that
file stays the template's, so `./scripts/sync-template.sh` keeps updating it
without conflicts. The extension point is a composite action that the
project owns: the file `action.yml` in `.github/actions/project-setup/`. Every
group job of `ci.yml` runs it after the checkout and before
`./scripts/verify.sh`, and only when the file exists
(`if: hashFiles('.github/actions/project-setup/action.yml') != ''`); every
group job of `docs/examples/parallel-ci.yml` does the same. A project without
the action runs as before. Name the file `action.yml`: an `action.yaml` is
not found, and the step is skipped.

For a Python project with uv:

```yaml
# .github/actions/project-setup/action.yml
name: Project setup
description: Installs Python, uv, and the dependencies of the project.
runs:
  using: composite
  steps:
    - uses: astral-sh/setup-uv@v6
      with:
        python-version: "3.12"
        enable-cache: true
    - run: uv sync --locked
      shell: bash
```

The template never ships or changes anything under `.github/actions/`: it is
not in the `paths:` of `.agents/template.conf`, and a sync leaves it alone.
The action runs before the verification, so it could replace `verify.sh` or
the tests on the runner. A change under `.github/actions/` is therefore
treated like a change to a CI workflow: it is `high` in
`.agents/policies/risk.conf`, protected by the merge approval gate whatever
`.agents/policies/guardrails.conf` says, and listed in `.github/CODEOWNERS`.
A project gets no fewer approvals from it, only no conflicts.

The action runs with the token of `ci.yml`, which declares read-only
permissions at the top level: `contents: read` for the checkout and
`packages: read` for a package pulled from GitHub Packages, nothing else,
whatever the repository's default workflow permissions are. A composite
action cannot widen them, and it cannot read the repository's secrets. A
project whose setup needs more adds the permission (or passes a secret to
the step) in its `ci.yml`, and keeps that change when
`./scripts/sync-template.sh` updates the file; the change is a CI workflow
change and needs the owner's approval like any other.

GitHub Actions cannot run locally. `tests/sync-template-test.sh` checks the
structure of both workflow files (the step comes after the checkout and
before the verification in every job that runs `verify.sh`) and evaluates its
condition with and without the action; the first CI run of a project with
the action is the end-to-end evidence that it works.

### A parallel CI

A parallel CI runs the groups of checks (see "Groups of checks") in jobs
of their own, at the same time, with one aggregate job as the required
check. `docs/examples/parallel-ci.yml` is a complete example to adapt, with
a producer and a consumer; it is not a workflow of the template.

**The CI of the template is one.** `.github/workflows/ci.yml` runs, after
the job `scope` that decides whether `--all` is added and which group jobs
have nothing to run (see "Workflow self-tests"):

- `group-default`: the checks of `scripts/verify.conf` without a group. In
  the template that is the website check and the light checks of the
  template; it is the only job that installs Node and the browser and
  uploads the website reports, all conditioned on the site's marker
  `website/.codeyard-site`. The website check stays in `default` rather
  than a group `website`: a project replaces `scripts/verify.conf` with its
  own checks, and a job for a group that the project's file does not have
  would fail the mapping of every project that syncs the template.
- `group-adopted-project` and `group-self-tests-1` to `group-self-tests-3`:
  the self-tests, in the groups that `scripts/verify-workflow.conf` gives
  them. `adopted-project` is a group of its own, with the check of its list
  (`adopted-project-list`); the others are spread by their duration on CI,
  not by their count, so that none takes much longer than another. Since
  `adopted-project` runs only the self-tests that read what its fixture
  varies (Issue 478), it takes one to two minutes locally instead of about
  eleven; the check of its list takes about twenty seconds since Issue 486
  (its cases share two runs of the check), so the group takes one and a half
  to two and a half minutes there.
  Its duration on CI is not measured yet, and with it whether the group is
  still the longest. A new self-test goes into the group with the least time.
- `mapping`: `./scripts/check-ci-groups.sh --workflow
  .github/workflows/ci.yml`.
- `verify`, the aggregate and the required check: `if: always()`, it needs
  `scope`, `mapping`, and every group job, and runs
  `./scripts/check-ci-groups.sh --results "$NEEDS" --scope scope`. A group
  job that failed, was cancelled, or was skipped fails it, and so does a
  failed `scope`, except a group job that `scope` named in its output
  `skip` and that was therefore not started: that one may be `skipped`.
  A group job skipped for any other reason, or after `scope` failed, still
  fails it, so a pull request whose groups did not run never passes.

Each group job declares `env: VERIFY_GROUP: <group>` and runs
`./scripts/verify.sh --all --only "$VERIFY_GROUP"`, or without `--all` when
the scope is `changed`. A group job of the self-tests starts only when
`scope` does not name it in `skip`: on a project's pull request or push
that changes no workflow file, none of them starts, and in a project the
job of a group whose self-tests are all framework-only
(`group-adopted-project`) never starts. `group-default` always starts. A
group that has a check of `scripts/verify.conf` always starts too, since
`scope` skips only what the self-tests alone would run.

**In a project that syncs the template.** `ci.yml` is in the `paths:` of
`.agents/template.conf`, so a project gets this file with every sync, and
`scripts/verify-workflow.conf` with the groups of the self-tests. A project
whose `scripts/verify.conf` has no groups runs its own checks in
`group-default` and needs nothing. A project whose checks use a group of
the template's jobs runs them there. A project with a group of its own,
say `lint [code]: ruff check .`, fails the job `mapping`, and so the
required check, with

```text
FAIL  no job of .github/workflows/ci.yml declares the group code, so its checks would never run in CI.
```

That is the intended outcome: no check is left without a job. The fix is
one of two. Remove the group from the check, so that it runs in
`group-default`. Or keep `ci.yml` as the project's own: add
`:(exclude).github/workflows/ci.yml` to the `paths:` of
`.agents/template.conf`, so that a sync no longer replaces it, add a job
`group-code` (a copy of `group-default` with `VERIFY_GROUP: code`, without
the website steps), and add it to the `needs` of `verify`; a later change
of the template's `ci.yml` is then taken over by hand.
`tests/check-ci-groups-test.sh` holds all three cases against the
template's `ci.yml`: no groups, a group the CI has, and a group of its own
before and after the fix, in the template only (see "Workflow
self-tests"): in a project its `ci.yml` is its own. There the question
"do my groups match my CI jobs?" is a check of the project, the line
`ci-groups` of `scripts/verify.conf`, which the template ships and the
adoption writes:

```text
ci-groups: test ! -f .github/workflows/ci.yml || ! grep -q 'VERIFY_GROUP:' .github/workflows/ci.yml || ./scripts/check-ci-groups.sh --workflow .github/workflows/ci.yml
```

It takes a fraction of a second and runs on every verification, also
locally and when no workflow file changed. A CI that declares no
`VERIFY_GROUP`, such as one job that runs `./scripts/verify.sh`, needs no
mapping, and the check passes.

**When one job is the better default.** A project whose verification takes
a few minutes gains little from the parallel jobs, which each check out the
repository and set up the project: the elapsed time shrinks, the runner
time grows. Such a project can keep the template's `ci.yml`, whose
`group-default` job is the whole of its own checks and whose group jobs of
self-tests do not start on a pull request or a push that changes no
workflow file, or keep a single job of its own with `ci.yml` excluded as above.

**What it buys.** Parallel jobs shorten the time until the required check
reports, the elapsed time, to roughly that of the longest chain of jobs. They
do not reduce the compute: every job checks out the repository, installs its
tools, and starts its runner, so the total runner time, and the cost of
paid runners, grows with every job. Parallelism adds no value when the
verification is already fast (a few minutes), when one group takes nearly all
of the time, when the groups depend on each other in one chain, when the
setup of a job costs more than the checks it runs, or when the runners are
too few to run the jobs at once. Measure first: the durations that
`verify.sh` records per check (see "Recorded verification") show which
checks dominate.

**The recipe.**

- Give the checks of `scripts/verify.conf` groups, as in "Groups of checks".
  Each group runs in one job named `group-<group>`, which **declares** its
  group in its own field, the job-level `env: VERIFY_GROUP: <group>`, and
  runs `./scripts/verify.sh --all --only "$VERIFY_GROUP"`. The group is
  written in the file, not taken from an expression or a matrix. The checks
  stay in `scripts/verify.conf`; the workflow names only groups.
- **The declarations are the contract.** `scripts/check-ci-groups.sh`
  checks what the jobs and the checks declare, and never reads a command to
  find out what it runs: no search in the text of a step or a check, no
  parsing of a shell command. A job runs the group it declares; a reviewer
  of the workflow sees one field to compare with the command beside it.
- Independent groups run at the same time. A consumer that needs the output
  of another group declares `needs: group-<producer>`, so it starts only
  after the producer succeeded. The producer uploads its output as an
  artifact whose name carries `github.run_id`, with a file that records the
  run and the commit it was built from; the consumer downloads it without
  `run-id`, which reads only the current run, and refuses an artifact whose
  record names another run or commit. A re-run of a failed job keeps the run
  and the commit, so it reads the output of the same run.
- One aggregate job is the required check, named `verify` like the single
  job of a CI without groups, so the branch protection does not change when
  a project switches. It `needs` every group job and runs with `if: always()`: a job
  that is skipped because a job it needs failed reports as passed in a branch
  protection, so the required check itself must never be skipped. It runs
  `./scripts/check-ci-groups.sh --results "$NEEDS"` with
  `NEEDS: ${{ toJSON(needs) }}`, which fails unless every group has its job
  there and every job ended with `success`: a failed, cancelled, skipped, or
  missing job fails it.
- A job that may be skipped legitimately, say a preview that runs only for
  pull requests from the repository, is named with `--may-skip <job>`: it may
  be `success` or `skipped`, never anything else. A group job cannot be
  named; its checks are required. A group job may be skipped only by a
  decision that is part of the results: `--scope <job>` names the job that
  decides, and a group job that this job, having succeeded, lists in its
  output `skip` (`' group-a group-b '`) may be `skipped`. The group job's
  `if:` reads the same output, so the decision and its acceptance cannot
  drift apart.
- One job runs `./scripts/check-ci-groups.sh --workflow
  .github/workflows/ci.yml`, and the aggregate job needs it. It fails unless
  every group of `verify.sh --groups` is declared by exactly one job: a group
  no job declares (a check was added to a new group, or to `default` without
  a `group-default` job), a group two jobs declare, a group that has no
  check, a group from an expression, a declaration in a job not named
  `group-<group>`, a job `group-<...>` without a declaration, and a
  `VERIFY_GROUP` outside the job-level `env` (in a step, or in a flow
  mapping `env: { ... }`) fail it.
- Where one suite is split over several checks, each part is a partition: a
  file that lists its test files, one per line. The check that runs a
  partition declares it in its own field, after the group:
  `unit-1 [unit-1] partition ci/unit-1.txt: pytest $(cat ci/unit-1.txt)`.
  `./scripts/verify.sh --partitions` lists the declarations, and a budget
  check cannot declare one, since a budget fails nothing.
  `./scripts/check-ci-groups.sh --tests '<pathspec>' --partition <file>...`
  fails when a test file is in no partition or in two, when a partition lists
  a file that is not a test, when a partition does not exist, when no check
  or more than one declares a partition, and when a check declares a
  partition that is not given with `--partition`. A check that runs a
  partition without declaring it therefore fails the mapping, whatever its
  command reads, and a new test cannot drop out of CI. Run it in the
  `mapping` job or as a check of `scripts/verify.conf`.
- Deployment, when the project has one, `needs: verify` and runs only for the
  default branch. It is the only job with write permissions, under an
  environment that keeps its own protection, such as a required reviewer.

**Permissions and untrusted code.** The workflow sets `permissions: contents:
read` for every job; a job that needs more declares it for itself. The jobs
run on `pull_request`, which gives the code of a pull request no secrets of
the repository; never use `pull_request_target` for jobs that run that code.
The approval protections stay as they are: the `Guardrails` workflow, the
branch protection that requires `verify`, and the merge approval gate do not
depend on how many jobs CI has. The example pins actions by their major
version tag, like the workflows of the template.

**What a project does not need.** The recipe uses `verify.sh` and its
groups, nothing else: no scheduler, no runner service, and no
project-specific machinery for provenance of results or for selecting the
tests of a change. A project that needs such things adds them as checks of
its own groups.

### Budgets

A check may be a budget: it measures something against a target (the time of
a test suite, the size of a bundle, the number of warnings) and exits non-zero
over the target. The word `budget` stands before the colon, after the name or
the group:

```text
suite-time [code] budget: ./scripts/measure-suite.sh --max-seconds 300
bundle-size budget: ./scripts/bundle-size.sh --max 250k
```

A budget is a measurement, never a failure and never a repair order:

- `verify.sh` runs it like any check and keeps its output. Over the target
  the summary shows `BUDGET <name> (exit <status>)` with the output of the
  check under it, not `FAIL`, and the verification passes when every other
  check passed: the exit status is 0. Within the target the summary shows
  `PASS <name> (budget within its target)`.
- A budget check that does not finish or cannot run measured nothing: a death
  by a signal, the exit status 124 of `timeout`, and the statuses 125 to 127
  (an error of `timeout` itself, a command that is not executable or not
  found) are a `FAIL` as for any check, and so is a missing tool. The exit
  statuses 1 to 123 and 128 mean "over the target": 128 is not reserved by
  `timeout` or the shell, so a measurement may use it. Wrap a measurement
  that may hang in `timeout`.
- The results are recorded with the pass, in `.agents/verification/budgets`
  next to the record (see "Recorded verification"), and in the run record
  (the `verification` event of `.agents/run/records/`, `budgets`), and a run
  that reuses the pass shows them in its summary again. That summary and the
  run record are where a project owner finds a budget result: the handoff
  note, the reviewer's context, the commit message, and the pull request do
  not repeat it. In a run of `run-feature.sh`, the summary is in the output
  of the step that verified, which the run prints.
- Nothing repairs it. `run-feature.sh` starts no repair session for a budget
  result; the result changes neither the scope of the feature nor the
  architecture, needs no ADR, and opens no Issue by itself. The reviewer may
  raise it as a finding, which is triaged like any finding. The completion
  record may not cite a budget check as evidence of a met criterion: the
  completion gate refuses such a record.
- Changing a budget stays cheap and visible. The target lives in the line of
  the check in `scripts/verify.conf`, or in a file that line reads. Changing
  the line is a change of the verification configuration, protected by the
  merge approval gate like every changed line there, and so is making a check
  a budget or a budget a check; adding a budget check is sensitive, like
  adding any check. Record the measurement and the decision in the commit
  message of that change, and in a comment of the configuration when the
  reason is not obvious; budgets add no approval step of their own.
- The execution limits that the project approved
  (`.agents/policies/execution-limits.md`) are not budgets and stay
  enforceable as they are.

The template ships no budget check. A partial run (`--only`) runs the budget
checks of its groups and shows them the same way; it records nothing, as
before.

#### A target for the duration of the checks

`scripts/verify.conf` and `scripts/verify-workflow.conf` each accept one
line that sets the target, in whole seconds, for the duration of all checks
of that file in one run:

```text
budget-seconds: 600
```

It is a budget like a budget check, with the same rules: a measurement, never
a failure and never a repair order.

- When the checks of the file take longer, the summary shows
  `BUDGET  duration of <file> (<total>s, target <n>s)` with the five slowest
  checks of the file under it, and the verification passes when every check
  passed. A failing check still fails it. The total is the sum of the
  durations; a run of several checks at a time (`parallel:`) shows the
  wall-clock time of the file's checks next to it,
  `(<total>s, <wall>s wall-clock, target <n>s)`.
- The result is recorded as a budget result named `duration of <file>`: with
  the pass in `.agents/verification/budgets` and in the run record, as
  above. `run-feature.sh` starts no repair for it, and the
  completion gate refuses a record that cites `budget-seconds` as the
  evidence of a met criterion.
- Within the target nothing is shown and no budget result is kept; the
  durations are recorded either way. Without the line nothing is compared,
  and the summary is the one it always was.
- A partial run (`--only`) measures the checks it runs and compares with
  nothing, and neither does a file whose checks did not run, such as the
  workflow self-tests when no workflow file changed.
- The line is reserved: `budget-seconds` is not the name of a check, takes no
  group, and is declared at most once per file. Like any line of these files,
  changing or removing it is protected by the merge approval gate.

The template sets no target in either file: the 600 s it once set for its
own workflow self-tests was exceeded in every run and no step acted on it
(Issue 503). The durations of the checks are recorded either way. A project
adds the line to `scripts/verify.conf`, or to `scripts/verify-workflow.conf`,
like any line of these files.

### Recorded verification

A run in which every check passed is recorded in `.agents/verification/passed`,
a working file that Git ignores, together with the fingerprint of the content
it verified. Any change to a file that Git does not ignore makes the record
stale, and a failing run removes it. The results of the budget checks of that
run, with the output of each, are kept next to it in
`.agents/verification/budgets`, and go with the record: a reused pass shows
them, and a failing run removes them. The durations of its checks are kept
the same way in `.agents/verification/durations`, one line per check with
its name, the file that declares it, the duration in milliseconds, and its
result (`pass` or `budget`), separated by tabs, in the order of the files
also when the checks ran at the same time.

`./scripts/verify.sh --reuse` skips the run when the record matches the current
content exactly, and says so. `review-feature.sh`, `apply-triage.sh`, and
`finish-feature.sh` call it that way, so in a feature the checks run once per
version of the content instead of once per step: at a terminal, the agent
verifies its final result, and the scripts that follow reuse that pass. Plain
`./scripts/verify.sh` always runs every check. The record also says who
started the run that wrote it (`origin`): `orchestrator` (`run-feature.sh`),
`script` (another workflow script), `agent-session`, or `manual`.

**The trust contract.** An agent session can write the record: an unattended
Claude session has no filesystem sandbox. So a pass is evidence for an
unattended review or commit only when the `verify.sh` that recorded it was
started by a workflow script itself, never inside an agent session, and that
script keeps the tree of the pass in its own memory:

1. `run-feature.sh` keeps the list `VERIFY_TRUSTED_TREES`: after each of its
   own calls of `verify.sh` that passes (the step `verification before round
   <n>` after every session and before every review round on the full
   verification, the verification of an unreviewed `low` feature, and the
   repeat of a failed verification), it adds the `tree` of the record. The
   scripts of its steps get the list in their environment, so the review, a
   retry of it after a usage limit, and the commit reuse that pass: one full
   run of the checks per distinct content of a run. A child script's own
   pass stays in its own list; it never flows back. The fix step runs
   `apply-triage.sh --caller-verifies`, which verifies nothing itself: the
   run verifies the fixed content before the next round. A failure of the
   run's verification goes to the implementer as a repair session, like one
   a review found.
2. `verify.sh --reuse` with the variable set, also empty, reuses only a
   record whose tree is in the list; otherwise it says so and runs every
   check, and records the pass again.
3. An unattended step without the list runs the verification itself and
   reuses no record: `finish-feature.sh --unattended`,
   `apply-triage.sh --unattended`, `review-feature.sh --unattended`,
   `update-feature.sh` (which publishes without a question), and the
   verification step of `run-feature.sh`. The pass such a step makes is its
   own trusted tree, which the scripts it starts get (`update-feature.sh`
   gives it to `publish-feature.sh`). `update-feature.sh` runs no check
   when nothing was merged and the content is that of the finish commit,
   which records its pass in its message; it trusts that commit, not a
   record file (see "Bringing a finished feature up to date with its
   base").
4. No agent process gets the list: `scripts/lib/agent.sh` removes
   `VERIFY_TRUSTED_TREES` (and `VERIFY_ORIGIN`, with which a script names
   itself as the origin) from the environment of every agent and sets
   `CODEYARD_AGENT_SESSION=1`, so a verification the agent runs records the
   origin `agent-session`. An agent cannot change the list of the script
   that started it, and cannot make a trusted pass for new content: a record
   rewritten to name a tree of the list is harmless, since that tree really
   passed, and the content must be that tree to match.
5. The `verification` event of the run records says who started the
   verification (`origin`) and whether its pass counted as evidence
   (`trusted`); `./scripts/report-runs.sh` reports both (see "Run records").
6. With the list set, the workflow self-tests run when a file under `paths:`
   differs from the tree of the last trusted pass of the run (the last tree
   of the list), not from the base: a fix that changes only documentation
   after a pass that ran them skips them. A trusted pass ran them, or skipped
   them because its workflow files were those of the base or of the pass
   before it, so the same workflow files need no new run. Without a trusted
   tree that Git knows, the base decides, as at a terminal.

Interactive use is unchanged: without the variable, `verify.sh --reuse`, and
`review-feature.sh`, `apply-triage.sh`, and `finish-feature.sh` without
`--unattended`, reuse any record for exactly the current content, also one
that an agent session recorded, as the owner at a terminal expects. CI runs
every check on a clean checkout anyway, and `publish-feature.sh` and a
ruleset on `main` make it the gate before a merge; the contract keeps the
line `Verification: passed` of an unattended commit honest, and keeps an
unattended run from spending its sessions on a forged pass.

The contract costs time in an unattended run: a pass that a step's script
made itself (a review, the fixes of a round) is not known to `run-feature.sh`,
so the step after it verifies the same content again, and the implementer's
own verification is not reused at all.

Two limits:

- The fingerprint does not cover files that Git ignores. A check that depends
  on ignored state, such as an installed dependency or a build cache, is not
  run again when only that state changed. CI runs every check on a clean
  checkout.
- The contract detects nothing and prevents nothing beyond the reuse: an
  agent session can still change files, and the scripts that follow judge
  the content as it is.

A record made without the workflow self-tests does not stand in for a run that
needs them, such as `--reuse --all`.

**The repeat of only the failed checks.** A run that fails keeps a record of
its own, never a pass: `.agents/verification/failed`, with the fingerprint of
the content, the checks that ran, the checks that failed, and who started it,
and next to it the budget results and durations of that run. After a failed
verification, `run-feature.sh` repeats only the checks that failed, to tell a
flaky check from a real failure: `./scripts/verify.sh --repeat
<check>,<check>`. The repeat runs only the named checks when the record of the
failed run is for exactly the current content, a workflow script started that
run (`origin` `orchestrator` or `script`), it names the same failed checks, it
ran the checks this run would run, and the repeat is `run-feature.sh`'s own
(`VERIFY_ORIGIN=orchestrator`, no agent in between). When the repeated checks
pass and no check changed the content, the checks that passed in the failed
run and the repeated ones together are the pass of that content: recorded as
any pass, with the budget results and durations of both runs and a line
`repeated: <check>...`, so the step done again reuses it under the rules
above. When any condition does not hold, for one a changed content, every
check runs, as without the option, and the output says why. A pass or a
forgotten record removes the record of the failed run.

### The baseline of an adopted project

A project that adopted the workflow around an existing product
(`adopt-repository.sh`, "Adopting an existing repository") may have checks
that fail before any change. The baseline keeps those apart from what a
change breaks, without ever presenting them as passed.

```bash
./scripts/verify.sh --baseline   # once, started by the owner, before any change
```

It runs every check of `scripts/verify.conf`, the project's own commands, and
records how each ended in `.agents/verification-baseline`, a file you
commit: `pass: <check>`, `fail: <check> exit <n>`, or `unavailable: <check>
<reason>` for a tool that is missing or a command that was not found (exit
127). It is not a verification: it records no pass, the workflow self-tests
do not run, it exits 1 when a check failed, and it refuses to run when a
baseline exists. To record it again, remove the file in a reviewed change.

Afterwards every run of `./scripts/verify.sh` compares with it:

| Result | When | Fails the verification |
|---|---|---|
| `KNOWN` | The check failed in the baseline and fails now: a pre-existing failure, with its check name | Yes |
| `FAIL ... a regression` | The check passed in the baseline and fails now | Yes |
| `PASS (it failed in the baseline and passes now)` | A pre-existing failure was fixed | No |
| `ACCEPTED` | The check fails, and `scripts/verify.conf` holds your exception for it | No |

A known failure never produces a passing verification. It stays visible until
it is fixed, or until you accept it explicitly with one line in
`scripts/verify.conf`:

```text
accepted-failure: lint The style errors predate the adoption; F03 fixes them.
```

The line names a check of the file and gives the reason; the summary shows
the failure as `ACCEPTED` with it, and says when a check with an exception
passes again, so that the line can go. Adding an exception is protected by
the merge approval gate, and so is any change of the baseline file: neither
passes without you.

#### Scoping an accepted failure

An exception of the whole check has a cost: while the check fails, it hides
every new failure inside it. For a check that runs per file or per test, the
exception can accept only what predates the change. Take a formatter backlog
of 440 files: the adoption cannot reformat them all, but every file a feature
adds or changes has to be formatted. Either of two forms of the line does
that, one per check:

```text
format: npx prettier --list-different .
accepted-failure: format changed-files exit 1 npx prettier --check --ignore-unknown
```

```text
format: npx prettier --list-different .
accepted-failure: format recorded exit 1
```

`exit 1` declares the exit status with which the check completed and found
failures; see below. The rest of the line is the scope:

- **`changed-files <command>`**: when the check fails, `<command>` runs on
  the files the feature adds or changes since its base, given as its
  arguments: committed, staged, unstaged, and untracked; a deleted file is
  left out. The base is the feature's own (`branch.<branch>.workflow-base`,
  then `base:` of `.agents/template.conf`, then `main`), compared at the
  point where the feature left it. When those files pass, or there are none,
  the failure is `SCOPED`; when one fails, the check fails. The command gets
  every changed file, so it must skip the files it does not handle, as
  `--ignore-unknown` does for prettier.
- **`recorded`**: the check prints its failures on standard output, one per
  line, such as `prettier --list-different .` does, and they are compared
  with the list `.agents/accepted-failures/<check>`, one failure per line
  (blank lines and `#` comments are skipped). A failure that is not in the
  list fails the check, and so does a listed one that names a file changed
  since the base: a file you touch is formatted. A check that fails without
  printing a failure fails too. A listed failure that no longer occurs is
  reported as `FIXED`, so that you remove it from the list: the list can
  only shrink. An entry that the list did not hold at the feature's base
  fails the check, also when the check passes; the first record, a list
  that the base does not have, is the exception.

Either form applies only to a check that completed with failures, and only
the check knows which exit status means that: `exit <status>` names it, or
several separated by commas (`exit 1,3`). There is no default, and a line
without it is refused. prettier exits with 1 when files are not formatted
and with 2 when prettier itself has a problem, so its line declares `exit 1`.
A declared status is one of 1 to 123 or 128; a line that declares any other
is refused, because 0 is a pass and the rest mean that the check did not
complete. A check that ended with a status its line does not declare (2 of
prettier), could not run or could not run on (125 to 127: an error of
`timeout`, a command that is not executable or not found), was killed by a
signal (129 and up, such as 143 for `SIGTERM`), or timed out (124 of
`timeout`) fails the verification with the check and its status, even when
what it printed before is recorded: that output is not the whole of its
failures. Nothing is reported as `FIXED` then; a recorded failure counts as
fixed only when the check ended with a declared status, or passed, without
printing it.

| Result | When | Fails the verification |
|---|---|---|
| `SCOPED` | The check fails, but only within the scope of its exception | No |
| `FAIL ... beyond the scope of its exception` | A new or changed file fails, the list gained an entry since the base, the check did not complete or ended with a status its line does not declare, or the scope cannot be checked | Yes |
| `FIXED` | A recorded failure no longer occurs: remove it from the list | No |

Either form needs the base: in a clone without the history back to it, a
shallow clone in CI for example, the files changed since it cannot be
determined, and the check fails. The checkout of such a CI fetches the
history (`fetch-depth: 0` for `actions/checkout`). A scoped form takes no
reason, a budget check takes none, and a baseline run (`--baseline`)
ignores every exception. The scoped line is protected like any added
exception, and the list `.agents/accepted-failures/<check>` like the
baseline: you approve any change of it at the merge, also the one that
shrinks it.

### Checks at the same time

By default `./scripts/verify.sh` runs the checks one after the other. One
line in `scripts/verify.conf` lets it run several at a time on one machine:

```text
parallel: 4
```

- At most `<n>` checks run at the same time, over the checks of both files:
  the checks of the project and the workflow self-tests share the slots.
  They start in the order of the files, and the next one starts as soon as
  one ends, so a long check listed late ends last: list the longest first.
  Without the line, or with `parallel: 1`, the run is the one it always was.
- `VERIFY_PARALLEL=<n>` overrides the line for one run, for example
  `VERIFY_PARALLEL=1 ./scripts/verify.sh` to run the checks one at a time
  while you look for a check that fails only beside another. The line and
  the variable take a whole number greater than 0; the line is declared
  once, only in `scripts/verify.conf`, and is not a check.
- The output of each check is kept apart and printed as one block when the
  check ends: its `-- <name>: <command>` line, everything it printed
  (standard output and error together), and `-- <name> took <s>`. The blocks
  come in the order in which the checks end; the summary keeps the order of
  the files. After the last block one line gives the wall-clock time of the
  run and the sum of the durations of its checks.
- Nothing about the result changes: every check runs, also after a failure,
  and the exit status, `PASS`, `FAIL`, `KNOWN`, `ACCEPTED`, `SCOPED`,
  `BUDGET`, the baseline, `--only`, `--changed`, `--reuse`, and the record of
  a pass are those of a run of the same checks one at a time. The durations
  are recorded in the order of the files. A target for the duration of a
  file (`budget-seconds`, "Budgets") is still compared with the sum of the
  durations of its checks; over it, the `BUDGET` line shows the wall-clock
  time of those checks next to the sum.
- Each check runs in a process group of its own, with `/dev/null` as its
  standard input: a check that reads from the terminal does not work in a
  parallel run. `Ctrl-C`, `SIGTERM`, and `SIGHUP` stop the checks that still
  run, with `SIGTERM` to their process groups.
- Checks that run side by side share the checkout and the machine. A check
  writes only into a temporary directory of its own (`mktemp -d`), never
  into a fixed path or into the checkout, and does not depend on a port, a
  lock, or a file that another check uses too. A check that cannot run
  beside others is a defect of that check.
- A sync of the template never brings the template's line into a project,
  and never changes or removes the project's own (see "Taking over template
  changes"): a project runs its checks one at a time until it sets a value
  of its own, measured on its own checks and machine.

The template ships `parallel: 4`, measured on its host of the runs (8 cores,
31 GB): its 47 workflow self-tests, run side by side in one checkout, took
707 s at four at a time instead of about 2170 s one at a time, at a load of
up to 8.6 and with 3.1 GB of memory in use. The checks themselves take longer
beside each other (their durations added up to 2669 s), and a higher value
gains nothing: the load is at the number of cores already, and the longest
check, `adopted-project` (589 s there, and itself four self-tests at a time,
`ADOPTED_PROJECT_JOBS`), sets the lower limit. It is therefore the first
check of `scripts/verify-workflow.conf`: it starts at once and holds one of
the four slots, while the other checks share the rest; started last, in the
order of the file before, it would end last. No other mechanism is needed
for it: a simulation with the durations of a full run one at a time gave
982 s for four at a time in that old order, 695 s with `adopted-project`
first, and 663 s for an order by the recorded durations.

### Several verifications on one machine

Feature worktrees share the machine, and each verification runs up to
`parallel:` checks of its own; nothing limits the checks of several runs
together. Measured on the host of the runs (8 cores, 31 GB) in its run
records, with `parallel: 4`: in 18 full verifications that ran at least half
of their time beside another one, no check failed because of the load (the
two runs that failed there failed the same checks again when repeated
alone), and `adopted-project`, the longest check, took a median of 750 s
instead of 626 s alone. Two runs side by side take longer each, and together
as long as one after the other (Issue 453: 1,361 to 1,650 s each at
`VERIFY_PARALLEL=2`, against 813 to 846 s for one run alone).

A machine-wide slot for heavy checks (`heavy: <check>...`, Issue 175) was
declared by no project and never taken, and is removed (Issue 521). A line
`heavy:` in `scripts/verify.conf` or `scripts/verify-workflow.conf` is now an
error of the configuration that names the line: remove it, and lower
`parallel:` (or `VERIFY_PARALLEL` for one run) on a machine that runs several
features at the same time.

### Missing prerequisites

Before a check starts, `./scripts/verify.sh` runs a preflight
(`scripts/lib/environment.sh`) with two levels:

- general, on every run: what the workflow scripts need, Bash 4 or newer,
  Git, and `jq` 1.6 or newer;
- the workflow self-tests, only when a self-test is going to run (a workflow
  file changed, `--all`, or `--changed` with a self-test selected), or when
  `--reuse` finds a recorded pass for this content that ran them: their
  isolated toolchain, Bash 4 or newer, GNU `sed`, GNU `timeout` and `date`,
  `jq` 1.6 or newer, and Git (see "Workflow self-tests"). The GNU tools are
  checked by what the scripts need of them, not by their name: `sed -i`
  without a suffix, `timeout --kill-after`, and `date -d`. A tool that
  behaves so passes, such as the uutils coreutils of Ubuntu 26.04.

The preflight runs before `--reuse` accepts a recorded pass: a pass that
covered the self-tests stands in for them only on a machine that can run
them.

A missing prerequisite is a fact of the machine, not a failure of the code.
The run starts no check, records nothing (an existing record of a pass stays
as it is), and exits with status 78 (`EX_CONFIG`). Its summary shows one line
per missing prerequisite, with the command that installs it:

```text
ENVIRONMENT  GNU sed for the workflow self-tests — brew install gnu-sed
```

A run that runs no self-test, such as `--only default` or a run in which no
workflow file changed, needs none of their prerequisites and is not stopped
by them. Below Bash 4 every script of `scripts/` stops the same way before it
does anything (`scripts/lib/bootstrap.sh`): on macOS `/bin/bash` is 3.2, and
`#!/usr/bin/env bash` finds it when no newer Bash comes first on `PATH`.

`review-feature.sh`, `finish-feature.sh`, and `apply-triage.sh` pass the
status 78 on unchanged, apart from the status 4 of a failed verification, and
`run-feature.sh` stops on it, or on an `ENVIRONMENT` line in the output of a
step that failed, with status 78: no retry, no repeat of the verification,
no repair session, and it never counts as an unstable check. Only what the
preflight establishes is an environment failure: a check or a self-test that
exits non-zero, also for a tool it lacks, stays a failure of the code. Install
what the lines name, then run again; `./scripts/doctor.sh` reports the same
prerequisites.

### References in the documentation

`./scripts/check-docs.sh` checks that the tracked Markdown files name files
that exist: every relative link (inline, with or without a title, and the
definition of a reference link; also one that leaves the repository), and
every path in backticks that starts with
a tracked top-level directory and names a `.md`, `.sh`, `.conf`, `.json`,
`.yml`, or `.yaml` file. It does not check anchors or external links, it
skips a path with a placeholder and a path that Git ignores, and it does not
read links that are shown as an example in a fenced code block or in inline
code. A missing file that a document of the product planning names
(`docs/PROJECT_DESCRIPTION.md`, `docs/changes/`, `docs/PROJECT_REQUIREMENTS.md`,
`docs/roadmap.md`) is printed as a note and does not fail the check when the
current feature removed it: the file existed at the base of the feature,
where its branch left the base branch. Only a planning cycle may change those
documents, so the feature could not correct the reference, and the note
leaves it to the next planning cycle. Every other missing file still fails:
a path that never existed, a typo, a file that was already gone at the base.
Outside a feature (on the base branch, on a detached HEAD, or when the base
cannot be determined, as in a shallow checkout) a missing file fails
everywhere. The architecture and the ADRs stay checked, since a feature
updates them. Name the files
that come later, or a directory that will hold them, after `--later`:

```text
docs-references: ./scripts/check-docs.sh --later docs/PLANNING_APPROVAL.md docs/changes
```

The template has such a line in its own `scripts/verify.conf`. It catches a
document that one change still names after another change removed it. The
line also names `.github/workflows/pages.yml`: a project deletes it with the
template's website (`docs/repository-setup.md`), while the documents it takes
over from the template still name it. The paths into `website/` need no
entry: once the directory is deleted, it is no tracked top-level directory,
and the check does not judge paths into it.

### Workflow self-tests

The tests of the workflow scripts (`tests/*-test.sh`) are declared separately,
in `scripts/verify-workflow.conf`. They test the workflow, not the project, so
a feature can break them only by changing a workflow file. That file names
those files in its `paths:` entry, as Git pathspecs.

`./scripts/verify.sh` runs the self-tests only when one of those files differs
from the base branch of the feature (`origin/<base>`, or `<base>`; see "The
base branch of a feature"), counting uncommitted and
untracked files, or when it cannot tell, for example outside a Git repository.
Otherwise the summary reports them as `SKIP`. `./scripts/verify.sh --all`
always runs them.

In CI, `.github/workflows/ci.yml` decides when to pass `--all` and which
group jobs start. Its job `scope` tells the template from a project by
`.agents/template.conf`: the repository that its `repository:` names is the
template, any other is a project. It decides with
`scripts/lib/template-repository.sh`, the predicate of "Framework-only
self-tests" below, given the repository of the run. A repository it cannot
tell (no `template.conf`, for one) counts as a project, except that its
framework-only self-tests run, as `verify.sh` runs them there.

| Event | The template | A project |
|---|---|---|
| Pull request | as in a project: no job of the self-tests without a workflow change; `--all` with one, and when the base cannot be determined | compared with the base of the pull request: no job of the self-tests without a workflow change; `--all` with one, as in a sync of the template, and when the base cannot be determined |
| Push to `main` | `--all` | as a pull request, compared with the commit before the push: no job of the self-tests without a workflow change, `--all` with one; `--all` when that commit cannot be determined |
| Run by hand (`workflow_dispatch`) | `--all` | `--all` |

There is no nightly run. The self-tests take far longer than the checks of
most projects, and a change that touches no workflow file cannot break
them, so a project's pull request and its push to `main` report in
minutes. A sync of the template changes workflow files, so its pull request
and its push run them. A self-test that fails for another reason, such as
a new runner image, is the framework's to find, in the template's own CI,
which runs everything on every push to `main`; a project that wants a full
run starts `ci.yml` by hand ("Run workflow" on the Actions tab), which runs
`--all`. The template's pull request follows the rule of a project: one
that changes no file under `paths:`, such as a change of the documentation
or the website alone, starts no job of the self-tests, and one that changes
such a file runs them all. `paths:` names every file a self-test reads, so
a pull request that can break a self-test runs it. The template's push to
`main` keeps `--all` (an owner decision, to reconsider after the other
reductions of the CI time).

`scope` compares the commit checked out with the base of the pull request
(`github.event.pull_request.base.sha`) or with the commit before the push
(`github.event.before`), over the `paths:` of
`scripts/verify-workflow.conf`. It checks out the history without the file
contents (`fetch-depth: 0`, `filter: blob:none`) and only the files it
reads. That commit cannot be determined on a first push (the zeros), when
the repository does not have it, and when it is no ancestor of the pushed
commit, as after a forced push: then everything runs, as `verify.sh` runs
every self-test when it cannot tell. Its outputs are `verify` (`all` or
`changed`) and `skip`, the group jobs that do not start: on a pull request
without a workflow change, in the template or a project, or on a push of a
project without one, every group of
`scripts/verify-workflow.conf` that has no check of `scripts/verify.conf`;
in a project, also a group whose self-tests are all framework-only. A
skipped job starts no runner, clones nothing, and runs no setup action,
where it ran before only to print a `SKIP` line.

In CI the self-tests run in four parallel jobs, one per group of
`scripts/verify-workflow.conf` (see "A parallel CI"), each with `--only`
of its group. The decision is the one of `scope`, not a second one of
`verify.sh`: `verify.sh` compares with the project's base branch (`base:`
in `.agents/template.conf`, else `main`), which on a push is the commit
itself and on a pull request into another branch is not its target, so
`scope` passes `--all` whenever a workflow file changed and whenever it
cannot tell, on a pull request as on a push. `--all` keeps the
framework-only self-tests out of a project. Without `--all` (no workflow
file changed) only `group-default` and the groups with a check of the
project start, and `verify.sh` decides there as it does anywhere; every
group job checks out the full history (`fetch-depth: 0`), since in a
shallow clone it cannot see which files changed and runs every self-test.
When the job `scope` fails, the group jobs still
run, with `--all`, and the aggregate `verify` fails on the failed `scope`.
`paths:` names the workflow code only: `scripts`,
`.agents/prompts`, `.agents/schemas`, `.agents/policies`, the two CI files the
template ships (`.github/workflows/ci.yml` and `guardrails.yml`),
`docs/examples/parallel-ci.yml`, which a self-test reads, and the self-tests
with their libraries. A pull request that changes or adds only one of them,
as a sync of the template does, runs the self-tests. The files a project is
told to make its own are not listed (#462): `.agents/agents.conf`,
`.agents/template.conf`, `.gitignore`, and a workflow of its own under
`.github/workflows`, such as its deployment. No self-test reads them, so a
pull request that changes only those skips the self-tests. The list decides
only which tests run: the risk policy and the merge gate classify these files
as before (`.agents/agents.conf` and `.github/workflows` stay `high` and
protected by the merge gate). `tests/sync-template-test.sh` runs the decision of
`ci.yml` for both kinds of repository and every event, with and without a
workflow change and with each kind of unknown commit before a push, the
conditions of the group jobs, the aggregate on the outcome, and a pull
request into a branch that is not the project's base, where the group job
runs the self-tests although `verify.sh` alone would skip them; and
`verify.sh` in a checkout made as
`actions/checkout` makes it for a pull request: with the full history it
skips the self-tests for a pull request that changes no workflow file, or
only a file a project makes its own, and runs them for one that changes
workflow code; in a shallow checkout it runs them.

`scripts` is listed as a whole, so a new script is guarded until it is
excluded with an entry `:(exclude)<path>`. `scripts/verify.conf` is excluded:
a project adds its checks there, and only the template's contract checks read
it, in the template. Exclude a
project's own scripts the same way, after checking that no self-test reads or
copies them; a broader list only makes the self-tests run more often. Delete
`scripts/verify-workflow.conf` when the project removes the workflow scripts.

The self-tests depend only on the files the template carries into a project,
never on the state of the repository they run in: not on its
`.agents/template.conf` (a test that needs the template's list of files takes
it without the project's exclusions, `commit:`, and `base:`), its
`.agents/verification-baseline`, its risk policy (a test of the policy the
template ships writes it from the preset of `standard` in
`scripts/lib/risk.sh`; only in the template itself, the repository whose
origin is the `repository:` of `.agents/template.conf`, does
`tests/risk-test.sh` check that its own `risk.conf` still matches that
preset), its ADRs, its agents (`tests/agent-levels-test.sh` holds the lines
of the shipped `.agents/agents.conf` itself and, only in the template, checks
that the file still has them), the plans its documents name (the
`tests/inherited-test.sh` check of the references compares a fixture project
with the same project without its inherited files, not with the repository
it runs in), its own test files (a check over the self-tests reads the
`tests/*-test.sh` that `scripts/verify-workflow.conf` names), its CI, its
documents, its website, its `scripts/verify.conf`, or the rules of its
`.gitignore` other than the workflow's lines for `.agents/`.

The checks that test the template's own copy of such a file, its *contract*,
run in the template only, under `template_repository` of
`tests/lib-fakes.sh`: that its `ci.yml` decides the scope, runs every group,
sets up the project and the website as documented, and grants a read-only
token; that its `paths:` are those `tests/sync-template-test.sh` checks; that
its site has its marker and check; that its `docs/development.md` and site
show the cron line `tests/status-test.sh` runs; that its `agents.conf` and
`risk.conf` match what the tests ship. The template is the repository whose
origin is the `repository:` of its `.agents/template.conf`; a project, and
any doubt, such as an origin that is a local path, is not. CI runs every
self-test of the template on every push to `main` and on every pull request
that changes a file under `paths:`, which names those files, so a change of
one of them there runs its contract checks; in a project they never run.
Whether a project's own CI matches its groups is the project's question, and
a check of its own: the line `ci-groups` of `scripts/verify.conf` runs
`./scripts/check-ci-groups.sh --workflow .github/workflows/ci.yml` when its
`ci.yml` declares groups, as the template's does (see "A parallel CI").

`tests/adopted-project-test.sh` holds the self-tests to it: it builds a fixture
adopted project from the template's files, without the template's website, with its
own CI excluded from the template's files, a CI of one job that runs
`./scripts/verify.sh`, `base: develop`, a risk policy of
its own (`profile: light` and classes of its own in its policy override, "The
project's policy override", and a class still written into the shipped
`risk.conf`), a CI setup action ("The project's CI setup"), a recorded
baseline, its own ADRs, its own `.agents/agents.conf` (the analyst on
Codex), a document that names a plan of its own, a test file of its own
named `tests/<x>-test.sh` that does not follow the rules of the self-tests,
ignore rules of its own for `docs/` and `tests/` paths and a rule `*.json`
that the adoption's section un-ignores again, and no `README.md` or
`LICENSE`. There it runs the self-tests that read something the fixture
varies, four at a time, or `ADOPTED_PROJECT_JOBS` at a time when it is set (a
lower value for a host with few cores); each has to pass. Every other
self-test has the same inputs in the fixture as in the template, and the
framework-only ones never run in a project, so running them again there
proves nothing new.

The list is `fixture_tests` at the top of `tests/adopted-project-test.sh`,
one line per self-test with what it reads, and the run prints it. The test
derives what the fixture varies from the fixture itself (every file that the
fixture and the repository it was built from do not have alike) and searches
each self-test that is not framework-only, with the shared parts
`tests/lib-<y>.sh` it sources: a test reads a varied file when it names it,
or a directory or glob that holds one, through its root variable
(`"$source_root/.agents/agents.conf"`); when it hands the repository on as a
whole (`template_repository "$source_root"`, `cd "$source_root"`, or a path
in a variable, `"$source_root/$path"`); or when it calls a helper of
`tests/lib-fakes.sh` that reads one and whose result differs in the fixture
(`template_conf`; `workflow_gitignore` gives the same lines in both); or
when it runs a script of the repository that reads one, followed through the
scripts and the shared parts `scripts/lib/<y>.sh` that script runs and
sources (`"$source_root/scripts/check-risk.sh"`, directly, after an
interpreter or an assignment such as `PATH=...`, or through a variable that
holds its path and is run). A script is counted as if it ran in the
repository itself, whatever directory the test runs it in: its root
variable, from its own path or from `git rev-parse --show-toplevel`, counts
like the test's, and so does its `script_dir/..`. A script that is only
copied (`cp "$source_root/scripts/check-risk.sh" "$repo/scripts/"`) runs in
the copy and does not count. A test starts in the root of the repository,
so a relative path counts too where its working directory is still the
root: a file it reads (`cat .agents/agents.conf`, `grep ... AGENTS.md`, an
input redirection, a `[[ -f ]]` test) or a script it runs
(`./scripts/check-risk.sh`, `bash scripts/<x>.sh`), at its top level, in a
function it calls there, or after a `cd "$source_root"`; a script it runs
counts as if it ran in the root as well. The check follows the working
directory while it stays in the repository: `cd .`, `cd ./`, `cd "$PWD"`,
and `cd "$(pwd)"` change nothing, a `cd` into a directory of the repository
(`cd tests`, `cd "$source_root/docs"`) counts the paths read there from that
directory (`../AGENTS.md` is the root's `AGENTS.md`), `cd -` and `popd` go
back, and `.` is a path like any other (`ls .` in the root reads the
repository). After a `cd` elsewhere (a variable, an absolute path), in a
subshell or a command substitution that changes into another directory,
and in a `git`, `tar`, or `make` command after `-C <dir>` with such a
directory (`git -C "$repo"`), a relative path is not the repository's; a
heredoc, the values of an array, a `case` pattern,
and the pattern of `grep`, `sed`, `awk`, or `jq` are no paths. Such a
test that is not on the list fails the run before any self-test starts, and
so does an entry that is no self-test, is framework-only, is listed twice,
or does not say what the test reads; `tests/adopted-project-list-test.sh`
tests each case, and `./tests/adopted-project-test.sh --check-list` runs the
check alone in seconds. A new self-test that reads the repository it runs in
goes on the list with what it reads. What the check does not see is a path
it cannot read from the text: a path assembled at run time, or a command
in a string run later (`bash -c '...'`, `eval`): keep such
a test isolated with a copy or a variable such as `AGENT_CONFIG_FILE`, as
the self-tests do, or list it.

The full form runs every other self-test in the fixture, the framework-only
ones too, as the test did before Issue 478, except
`tests/adopted-project-list-test.sh`, which inside the fixture would build a
fixture of the fixture that varies nothing:

```bash
./tests/adopted-project-test.sh --all
```

It starts the self-tests in the order of `scripts/verify-workflow.conf`, so
the longest self-tests are listed first: a long test that starts last would
end last and hold up the whole.

The tests of `scripts/run-feature.sh` are split into parts,
`tests/run-feature-<part>-test.sh`, each a check of its own, that share the
helpers of `tests/lib-run-feature.sh`, so that no single self-test holds up
`adopted-project`. Every case of a part starts with a line
`scenario <id>`, its stable identifier, and the register in
`tests/lib-run-feature.sh` (`scenario_register`) lists each identifier once.
Each part checks at its end that the register agrees with all parts, and
`tests/scenario-register-test.sh`, framework-only, checks it as a test of its own: an
identifier defined twice, one that the register lists and no part runs, and
one that a part runs and the register does not list each fail it. A new case
gets an identifier and a line in the register; a case moves between parts
without a change to the register.

The self-tests run under `set -o pipefail`, so an assertion does not pipe
output into a quiet grep: `producer | grep -q pattern` fails when grep exits
at its first match while the producer is still writing, which depends on the
load of the host (Issue #456). Write `grep -q pattern <<<"$(producer)"`
instead; `>/dev/null` in place of `-q` is no remedy, since GNU grep then stops
at the first match as well. `tests/pipe-grep-test.sh` fails on such a pipe in
the workflow's test files, the `tests/*.sh` that `scripts/verify-workflow.conf`
names, also one that continues on the next line. A project's own test files
are its own and follow its rules; in the template the check reads every
`tests/*.sh`, also `tests/agent-sandbox-test.sh`, which runs by hand only. The workflow scripts follow the same
rule (Issue #509): there a wrong result is a wrong decision of the workflow,
such as `check-ci-groups.sh` calling a group that is there missing. The check
reads every `*.sh` under `scripts/`, less the files and directories that the
`paths:` entry of `scripts/verify-workflow.conf` excludes with
`:(exclude)<path>`, where a project leaves out its own scripts.

For the same reason a self-test does not pipe a tar that creates an archive
into another tar (Issue #466): the tar of macOS may stop reading at the
end-of-archive marker while the writer still pads its last record, and the
writer fails with `tar: Write error`. A test copies files with `copy_files
<from> <to>` of `tests/lib-fakes.sh`, which reads the paths NUL-separated on
its input, keeps the regular files, and passes the archive through a file.
`tests/pipe-grep-test.sh` fails on a `tar -c… | tar` pipe in the same files;
a pipe from another producer into tar, such as `git archive | tar -x`, is not
this form and the check leaves it alone.

A few more traps of the tools, each met in a feature of the template:

- `jq -r` prints a newline after a string that already ends with one. Text
  handed on as a file, such as a diff for `git apply`, comes out with
  `jq -j`, with a final newline added only when it is missing (#403).
- Under `set -euo pipefail`, reading a file that may be missing through a
  pipe, as in `value="$(sed -n ... "$file" 2>/dev/null | head -n 1)"`, ends
  the script when the file is missing; test for the file first (#395).
- `git rev-list --before=@<epoch>` misreads a small epoch and returns
  `HEAD`; pass an ISO date (#157).
- `copy_workflow` of `tests/lib-fakes.sh` copies `scripts/*.sh`,
  `scripts/lib/*.sh`, the prompts, and the schemas. A test of a script that
  reads another file, such as `scripts/verify-workflow.conf`, a policy, or
  `scripts/lib/report.jq`, copies or writes that file into its fixture
  (#189, #195).
- `run-feature.sh` sources its libraries from its own directory: a run
  started from the primary checkout judges a feature with the scripts of that
  checkout, not with those of the feature's branch. A change to
  `scripts/lib/completion.sh`, say, takes effect in a run only after the
  merge; the self-tests test the branch's scripts (#218).

The self-tests run the workflow scripts with a restricted `PATH`, so that
fakes stand in for the agent CLIs and `gh` and nothing else of the machine is
found by accident. They never use a fixed `/usr/bin:/bin` alone: on macOS
that is Bash 3.2, a BSD `sed`, and no `timeout`. `tests/lib-fakes.sh` builds
the isolated test toolchain (`scripts/lib/environment.sh`): a directory of
links to explicitly selected tools only, Bash 4 or newer, GNU `sed`, GNU
`timeout` and the coreutils the scripts use, `jq`, and Git, taken from
Homebrew's GNU directories first, then from `PATH`; never an agent CLI, `gh`,
or another network tool. On Linux the links point at the system's tools. It
is kept once per user and content under `${TMPDIR:-/tmp}`
(`codeyard-test-toolchain.*`). A kept directory is used again only when it,
its `bin`, and its files are owned by the current user and writable by
neither group nor others, none of them is a symbolic link, and `bin` holds
exactly the expected links, each pointing at the tool that was resolved;
otherwise it is built again, and when another user's directory is in the
way, the test uses a directory of its own. A test uses the toolchain by
intent:

- normal isolated execution: `PATH="$ISOLATED_PATH"`, the toolchain followed
  by `/usr/bin:/bin`;
- with fakes in front: `PATH="<fakes>:$ISOLATED_PATH"`;
- a tool made unavailable on purpose, such as Bash or `jq`: a `PATH` of the
  test's own without the toolchain, or with only the links of
  `$TEST_TOOLCHAIN_BIN` it wants, as `tests/doctor-test.sh` does, so that the
  test still proves how the workflow handles the missing tool.

Without a required tool a self-test stops at its start with the
`ENVIRONMENT` line and status 78.

The self-tests start `jq`, `git`, and `bash` thousands of times. On an Apple
Silicon Mac an x86_64 `jq`, such as the one Anaconda installs, runs under
Rosetta and roughly doubles their duration; `file "$(command -v jq)"` shows
which one is first on your `PATH`.

### Framework-only self-tests

Some self-tests test the template as a framework, not the project that uses
it. `tests/adopted-project-test.sh` builds a fixture project from the files
of the repository it runs in and runs there the self-tests that read what
the fixture varies (see "Workflow self-tests"): in the template that is the
proof, before a release, that no self-test reads a file
of the repository hosting it (#304, #392 and #411 broke in projects that
way). In a project the fixture is built from the project's own files, so it
repeats the direct self-tests, which already run on the project's real
state, at 8 to 12 minutes of CI per run. Such a check is marked in
`scripts/verify-workflow.conf` with the keyword `framework` before the
colon:

```text
adopted-project [adopted-project] framework: ./tests/adopted-project-test.sh
```

Only a self-test of `scripts/verify-workflow.conf` can be framework-only;
`verify.sh` refuses the keyword in `scripts/verify.conf`, whose checks are
the project's own. A keyword and not a group, because the group says in
which CI job a check runs, which is a matter of its duration, not of where
it belongs.

The checks marked so, and why:

| Check | Framework-only | Why |
|---|---|---|
| `adopted-project` | yes | It repeats the direct self-tests in a project; its distinct catches were all in the template's own CI. |
| `adopted-project-list` | yes | It tests the list of `adopted-project`, which runs only in the template. |
| `adoption`, `adopt-repository`, `assess-repository` | yes | The adoption tooling runs from a clone of the template, never from a project. |
| `scenario-register` | yes | It reads no file of a project's own: every part of the tests of `run-feature.sh` checks the register at its end, in a project too, and this test adds only the faults of that check (Issue #522). |
| `pipe-grep` | no | In a project it reads the `scripts/*.sh` that `paths:` does not exclude, the project's own scripts until it excludes them, and its copies of the workflow files (Issue #522). |
| `sync-template` | no | Projects use `sync-template.sh`. |

**Whether this is the template.** `scripts/lib/template-repository.sh` holds
the one predicate that `verify.sh` and the job `scope` of `ci.yml` use. The
repository is the template when its origin (`git remote get-url origin`; in
CI the repository of the run, which `actions/checkout` makes the origin) is
the repository that `repository:` of `.agents/template.conf` names. Both are
compared as `<host>/<path>` in lower case, without a user, a port, a
trailing `/` or `.git`, so the HTTPS and the SSH form of one repository are
the same. A framework-only check is skipped only on a positive "not the
template": `template.conf` names a URL, the origin is a URL, and they
differ. With no `template.conf`, no `repository:`, a local path on either
side, or no or an unreadable origin, it runs.

`./scripts/doctor.sh` prints the role and its reason without changing
anything: a `NOTE` for the template and for a project, a `WARNING` when the
role cannot be told, so a wrong role shows before a verification runs or
skips these self-tests.

**After a rename of the template, update the origin of its clones.** The
template was renamed from `agentic-coding-template` to `agent-codeyard`.
GitHub redirects the old name, so a clone whose origin still has it keeps
working, but its origin is then not the repository that `repository:` names:
the clone counts as a project, and its framework-only self-tests are skipped
with a `SKIP` line. Set the origin to the current name
(`git remote set-url origin https://github.com/taspinar/agent-codeyard.git`,
or the SSH form); nothing detects a rename.

**A skip is explicit.** The summary shows one line per skipped check, with
the reason:

```text
SKIP  adopted-project (framework-only): this repository (github.com/owner/project) is not the template that .agents/template.conf names (github.com/taspinar/agent-codeyard); it tests the template itself and runs there; --framework-checks runs it here
```

The record of the pass says `framework-checks: skipped` next to
`workflow-tests: ran` (`ran` when they ran, `none` when no self-test ran).
`--reuse` does not take a pass that skipped them for a run that runs them.
`./scripts/verify.sh --framework-checks` runs them in any repository: before
a project proposes a change of the workflow upstream, or to reproduce a
failure of the template's CI. It needs no `--all` and no changed workflow
file. When no workflow file differs from the base, the framework-only
self-tests run alone: the other self-tests stay skipped as without the
option, with their own line, and the record says `workflow-tests: skipped`
next to `framework-checks: ran`:

```text
SKIP  workflow self-tests (99 checks that are not framework-only): no workflow file differs from origin/main; --all runs them
```

A pass that ran no framework-only self-test does not stand in, with
`--reuse`, for such a run. The option combines with `--all` (every
self-test), with `--only` (the framework-only self-tests of the named
groups), and with `--changed` (those that the changed files select; when
they select none, none runs).

**In CI** nothing changes in the template. In a project the job
`group-adopted-project`, whose self-tests are all framework-only, does not
start: `scope` names it in `skip` on every event, and
`check-ci-groups.sh --results --scope scope` in the aggregate `verify`
accepts it as skipped. A group job skipped by anything else still fails the
aggregate check. Where the job does run in a project, as in a CI of the
project's own, its `verify.sh --all --only adopted-project` prints the
`SKIP` line and passes. `tests/template-repository-test.sh` runs the
predicate, the skip, the record, the option with and without a changed
workflow file, the step `scope`, and the group job of `ci.yml` with
`check-ci-groups.sh --results`.

**Three layers.** The checks of a project fall into three layers, each with
its own responsibility:

- *Framework regression*, in the template only: the framework-only
  self-tests. They show that the template works in any project before it is
  released.
- *Project integration*: the direct self-tests, on the project's real state
  (its policies, its `template.conf`, its CI, its edits). They show that
  this project's copy of the workflow works here.
- *Application checks*: the project's own checks of `scripts/verify.conf`.

When each runs, in a project unless the row says otherwise:

| Situation | Framework regression | Project integration | Application checks |
|---|---|---|---|
| An application feature (no workflow file changed) | no | no: `SKIP workflow self-tests` | yes |
| A sync of the template | no (`SKIP`) | yes: the sync changes workflow files | yes |
| The adoption | no (`SKIP`): `template.conf` names the template, the origin is the project | yes: the workflow files are new | yes |
| A change of a policy under `.agents/policies`, or of `ci.yml` or `guardrails.yml` | no (`SKIP`) | yes | yes |
| A change of only `.agents/agents.conf`, `.agents/template.conf`, `.gitignore`, or a workflow of its own | no | no: not workflow code | yes |
| A change of `scripts/verify.conf` only | no | no: it is not a workflow file | yes |
| Custom edits of workflow code | no (`SKIP`); `--framework-checks` before proposing them upstream, which runs them with or without a changed workflow file | yes | yes |
| Push to `main` | no (job not started) | as a pull request: only when the push changes a workflow file, or when the commit before it cannot be determined (`--all`) | yes |
| A run by hand (`workflow_dispatch`) | no (job not started) | yes (`--all`) | yes |
| An unknown origin (no `template.conf`, a local path, no or an unreadable origin) | yes, whenever the self-tests run | as the event decides | yes |
| The template itself | yes, whenever the self-tests run | yes | yes |

## Configuring agents

`.agents/agents.conf` assigns a provider and model to each workflow role, one
per line:

```text
<role>: <provider> <model>
```

| Role | Used by |
|---|---|
| `project-grill`, `project-planner` | `start-planning.sh` |
| `planning-reviewer` | `review-planning.sh`; the Draft review in `start-planning.sh` (read-only) |
| `implementer` | `start-feature.sh` |
| `reviewer` | `review-feature.sh` |
| `triage` | `triage-review.sh` |
| `triage-implementer` | `apply-triage.sh` |
| `analyst` | `analyze-runs.sh` (read-only) |
| `assessor` | `assess-repository.sh` (read-only) |

Supported providers are `codex` and `claude`. Set each model to one your
account supports, and use a different provider for a reviewing role than for
the role whose work it reviews: `review-feature.sh` refuses to start a
reviewer that resolves to the implementer's provider (see "Per risk level").

Every workflow script accepts `--agent <agent>` and `--model <model>` to
override the configuration for one run. Overriding the provider requires a
model as well. The model is always passed to the provider, for Claude as well
as Codex, and is never replaced: an unknown provider, missing CLI, missing
model, or malformed configuration fails before the script creates a branch,
worktree, or file, and a model the provider rejects fails the run.

**Per risk level.** A role of a feature (`implementer`, `reviewer`, `triage`,
`triage-implementer`) may have a line per risk level of the feature ("The
risk level of a feature" below) next to its plain line:

```text
implementer: claude sonnet
implementer@high: claude fable
```

When a script starts such a role it takes, in this order: `--agent` and
`--model` on the command line; the line of the role and the effective level of
the feature; the plain line of the role. Without a level line the plain line
applies, so a configuration without one behaves as before ("The shipped
configuration" below says which lines the template ships). The level is the
effective level as `check-risk.sh` computes it at the
moment the role starts, raised to the highest level that the run records of
the feature hold: the level can rise during a feature, so a later session may
use a stronger model, never a weaker one than a session that already ran at a
higher level. `start-feature.sh` starts a new feature at the default of the
risk policy of its base, since the feature has no changes yet, and a resumed
session at the level of the changes in the worktree. When you know that a
feature will be `high`, say so before its first session, so that it starts
with the model of `implementer@high`: label the Issue `risk: high` (or
`risk: medium`), or pass `--risk high` to `start-feature.sh` or
`run-feature.sh` ("The owner's hint" under "The risk level of a feature"). A
level that cannot be determined is `high`. The script prints the level, why, and which line
selected the agent; the run record notes both for every agent call (`level`,
and `selection`: `command-line`, `level-line`, or `plain-line`), and
`report-runs.sh` shows the calls, the time, and the tokens per level, model,
and selection ("Per risk level"). A model that cannot be invoked stops the
step, as for a plain line; nothing falls back to another model. In a project
that keeps no run records (see "Run records"), the level is computed anew at
every session.

`doctor.sh` validates the level lines like the plain ones: an unknown level, a
duplicate, a malformed line, an unsupported provider, or an invalid model is
reported with its line, on any line of the file, also one of a role that the
script does not start; a CLI that only a level line needs is required; and
every script refuses such a file before it resolves a role. It also warns
when a reviewing role and the role whose work it reviews resolve to the same
provider, for the plain lines and for every level that either side has a
line for, and when a role that never runs with a level (the planning roles
and the analyst) has a level line. The reviewer's independence is enforced
where the reviewer starts: `review-feature.sh` takes the implementer's
provider from the run records of the feature ("Run records"), which hold
every session of the implementer with the provider it ran with, also a
session that `--agent` on the command line gave another provider than the
configuration (each run counted once, from its run file), and refuses, before it calls any
agent, a reviewer that resolves to a provider the implementer ran with.
Without a recorded session
(a project that keeps no run records, or work done by hand) it resolves the
implementer's provider for the same level (`implementer@<level>`, or the
plain line) and refuses a reviewer that resolves to that provider. `--agent`
and `--model` on the command line can make the pair differ for one run, but
never make the reviewer equal to a provider that implemented: an implementer
that ran with both providers leaves no independent reviewer.

**The shipped configuration.** The template's own `.agents/agents.conf`
gives the writing roles of a feature to Claude at every level, `claude opus`
for a low- and a medium-risk feature and `claude fable` at high
(`implementer@high`, `triage-implementer@high`), the review to Codex at every
level (`reviewer: codex gpt-6-luna`, with no level line, since the pair
differs at every level), and the triage to `claude sonnet`, which judges the
review of the other provider. The planning roles and the analyst have plain
lines. The levels come from the features that built the template: a feature
that changes the workflow and its gate, which the risk policy classes as
high, converged in one or two rounds with the strongest model where a weaker
one needed many, while the other features did not need it. The models are
the template's choices; a project sets the models, the levels, and the
providers it wants, and Codex remains supported as implementer and
triage-implementer for a project that configures it ("Codex and `.agents/`"
below). `tests/agent-levels-test.sh` checks the lines of the shipped file,
which it holds itself: what each level resolves to, and that `doctor.sh`
accepts them without a same-provider warning. Only in the template does it
check that `.agents/agents.conf` still holds exactly those lines; a project's
agents are its own. With no writing role on Codex,
`tests/agent-sandbox-test.sh`, which you run by hand (see "Codex and
`.agents/`"), has no Codex sandbox to check and skips; it checks it as soon
as a line gives Codex write access.

`AGENT_CONFIG_FILE` selects another configuration file for a run, for the
workflow scripts and `doctor.sh`; `ATTRIBUTION_CONFIG_FILE` does the same for
the attribution preference (see "Configuring attribution"). Neither reaches
the checks of `verify.sh`: `verify.sh` unsets both for every check, and the
workflow self-tests that assume the repository's own `.agents/agents.conf`
unset them themselves, so they give the same result when you start one by
hand. `tests/agent-test.sh`, `tests/agent-levels-test.sh`, and
`tests/doctor-test.sh` set them on purpose.
Other variables, such as `CLAUDE*`, are not changed.

Agents run with one of three permission profiles, which are unrelated to
the workflow profiles of the risk policy ("Workflow profiles"). The
permission profile follows from
the role and from how the script is run, not from the provider or model: a
reviewing role is always read-only; a writing role gets `write`, or
`unattended` when you run the step with `--unattended`, as described under
"Running feature steps without questions".

- `write`: an interactive session that may modify its worktree and use the
  network, for example to install dependencies and run builds. Anything beyond
  that needs your permission. Claude accepts edits automatically and asks you
  before it runs a shell command. Codex works without asking inside a
  workspace-write sandbox with network access and asks you when a command
  needs to leave that sandbox, for example to write outside the worktree;
  Codex has no setting that asks per command without a sandbox. Used for
  planning, implementation, and applying triage.
- `unattended`: the reach of `write` without a terminal. The session asks
  nothing and ends by itself, and the script stores its final message. What
  `write` would ask you is decided without you. Codex stays inside its
  workspace-write sandbox and is refused a command that leaves it. Claude runs
  in its `auto` permission mode, in which its own check allows or denies each
  action, and anything that would still prompt is denied. As in a read-only
  session, no MCP servers, apps, or other tools from your configuration are
  loaded, since they act outside the sandbox: Codex runs without your
  `config.toml` and with apps, browser use, and computer use disabled, and
  Claude without MCP configuration. An unattended agent runs commands on your
  machine while you are not watching: it is meant for work whose result you
  read afterwards.
- `read-only`: a non-interactive session that cannot modify files and gets no
  MCP servers, apps, or other tools from the user's configuration. Codex runs
  in a read-only sandbox without the user's `config.toml`, with apps, browser
  use, computer use, and web search disabled. Claude runs restricted: without user, project, or MCP
  configuration, with only its Read, Glob, and Grep tools, and without asking
  for any further permission. The script stores the agent's result. Used for
  review and triage.

A profile that a provider cannot enforce is an error; an agent is never started
with broader permissions instead.

**Codex and `.agents/`.** Codex 0.164 and later mount `.agents/`, `.git/`, and
`.codex/` read-only in the workspace-write sandbox, also inside the worktree
that the session may write otherwise. The implementer and the
triage-implementer have to write four directories under `.agents/`
(`.agents/prompts/implementer.md`, `.agents/prompts/triage-implementer.md`):
the completion record, the handoff note, the summary, and the manual steps.
A Codex session of the `write` and of the `unattended`
profile therefore gets exactly these opened as writable roots of its sandbox
(`-c sandbox_workspace_write.writable_roots=[...]`, built from the worktree):

- `.agents/completion/`
- `.agents/handoffs/`
- `.agents/summaries/`
- `.agents/manual-steps/`

All four are ignored by Git. `agent.sh` creates them before the session
starts, because the sandbox refuses a writable root that does not exist (every
command of the session then fails) and the session cannot create a directory
inside the read-only `.agents/` itself. Nothing else under `.agents/` is
opened: the policies, the prompts, the schemas, the plans, the reviews, the
triage, `.agents/run/`, `.agents/verification/`, and `agents.conf` stay
read-only for the agent, as do `.git/` and `.codex/`; a read-only session and
a Claude session get no such roots. A `./scripts/verify.sh` that the agent
runs inside the sandbox therefore cannot record its pass
(`.agents/verification/`) or its run record (`.agents/run/records/` of the
primary checkout): both are warnings of the scripts, the verification itself
passes or fails as always, and the step that follows the session verifies
the result again. `tests/agent-sandbox-test.sh` checks the grant with the
real Codex CLI, when it is installed and logged in: the four directories are
writable, `.agents/policies/`, `.agents/prompts/`, `.git/`, `.codex/`, and a
directory beside the worktree are not, and the write profile grants the same
roots. It is no self-test of `scripts/verify-workflow.conf` (Issue #522): it
starts a real Codex session, which takes a minute and is paid, and the
verification would start it in every run of a project whose implementer is
Codex. Run it by hand after you update Codex or change the Codex grant of
`scripts/lib/agent.sh`, before you give a writing role to Codex, and when a
Codex session leaves no completion record:

```bash
./tests/agent-sandbox-test.sh
```

It proves what the report of `start-feature.sh` below cannot: that the
grant works before a session needs it, and that it opens nothing else, which
no missing record would show. `AGENT_SANDBOX_TEST_MODEL` names the model when
no writing role uses Codex. `doctor.sh` does not
start a session to check it: a Codex of your host that does not honour the
grant shows at the first session with write access, which leaves no
completion record. `start-feature.sh` then reports the Issue as not complete
(`missing`) and, for a Codex session, names the likely cause: the runtime
directories, the writable roots of the sandbox, and the remedy (update
Codex, or give the role to Claude in `.agents/agents.conf`). Within
`run-feature.sh` that report is in the output of every implementer session,
and the run stops when its sessions are used.

**The artifact manifest.** Every agent session, of every profile and
provider, runs inside a manifest of the artifacts that an agent may only
read (`agent_run` in `scripts/lib/agent.sh`, `fingerprint_manifest` in
`scripts/lib/fingerprint.sh`). Before the session the path, the mode, and
the content hash of every file under `.agents/reviews/`, `.agents/triage/`,
`.agents/exceptions/`, and `.agents/approval-requests/` of the worktree are
taken, and of the verification record (`.agents/verification/passed`,
`budgets`, `durations`); after the session they are taken again. A session
that changed, added, or removed one of those artifacts, also only its mode,
or one whose mode or content the manifest could not read (an unread value
cannot show that nothing changed), ends with status 5, whatever the agent's own status was, and the paths are
named. `start-feature.sh` and `apply-triage.sh` then exit with status 5, a
review stores nothing, and `run-feature.sh` stops without trying anything
again, because a forged review without findings, for example, would
otherwise go to the commit (`tests/agent-test.sh`, `tests/run-feature-verification-test.sh`).
A changed verification record is only reported: a reuse trusts no pass that
an agent recorded (see "Recorded verification").

The manifest detects; it does not prevent. The write has happened when it is
found, and the worktree keeps it for you to look at. Only a sandbox prevents
it: Codex mounts `.agents/` read-only, as described above, but an unattended
Claude session in its `auto` mode has no filesystem sandbox. The manifest is
the same for both providers, so the run stops the same way whichever agent
wrote.

**When a session fails.** A read-only or unattended session that fails says
why, as the provider said it: its error messages, which Codex writes as JSON
events, and its error output. A usage or rate limit is named as one ("This is
a usage limit of codex, not a defect"), and `run-feature.sh` writes it into
the log of the feature. Before anything is shown, what looks like a key or a
token is replaced by `[redacted]`, also a private key with its whole body; a
line of the prompt that the provider repeats is replaced by `[prompt]` (a line
of fewer than four characters only as a word of its own); and only the last
ten lines are shown. The ordinary answer of a failed session is not shown. A
`write` session runs in your terminal, where the agent shows its own messages
as it works: the script repeats nothing of them and says only that the
session ended with its status.

## Configuring attribution

Coding agents name themselves in what they commit: Claude Code adds a
`Co-Authored-By` trailer to a commit and a "Generated with Claude Code" line
to a pull request description, Cursor a trailer of its own. Whether this
project wants that is one setting in `.agents/attribution.conf`:

```text
agent-attribution: disabled
```

The template ships `disabled`: the work is published under the owner's own
name, and the Git author stays the owner's identity. A project that wants its
agents named changes the line to `allowed`.

- `allowed`: agents attribute their work as their clients do, and nothing is
  checked. A project without the file behaves the same: it is what every
  project did before the setting existed.
- `disabled`: no commit of a feature and no pull request description may name
  an agent. Three things follow it:
  - **The instructions.** The section "Attribution" of `AGENTS.md`, which
    every agent reads, holds the rule.
  - **The client settings, as far as a client has them.** A Claude session
    that the scripts start in the `write` or `unattended` profile gets
    `--settings '{"attribution": {"commit": "", "pr": "", "sessionUrl": false}}'`,
    which turns off its trailer and its pull request line (Claude Code 2.0.62
    or later). For a Claude session you start yourself in the project, put the
    same `attribution` object into `.claude/settings.json`; `doctor.sh` tells
    you whether that file agrees with the preference. Codex has no attribution
    setting, and Cursor's can be set only for the user, not in a project file:
    for them nothing is configured, and `doctor.sh` says so instead of
    claiming otherwise.
  - **The check.** `finish-feature.sh` refuses, before it commits, when a
    commit of the feature carries an agent's `Co-authored-by` trailer, and
    undoes its own commit, leaving the changes staged, when the message got
    attribution in the editor or from a hook. `publish-feature.sh` refuses,
    before it pushes, a commit of the branch with an agent trailer and a
    description that would carry generated attribution text; the two are
    reported apart, since a trailer is removed from its commit and the text
    from the finish commit's message or the manual steps. An agent is known
    by its address (`noreply@anthropic.com`, `@cursor.com`,
    `noreply@openai.com`, the Copilot addresses) or by a GitHub App's
    `[bot]`, never by a person's name: a co-author who is a person is never
    rejected, also one whose first name is a product's. Only the commits of
    the feature are checked, from where it left its base; the history of the
    base is neither checked nor rewritten.

A preference that cannot be read, because the file is malformed or the value
is neither `allowed` nor `disabled`, stops the step instead of being guessed.
`ATTRIBUTION_CONFIG_FILE` selects another file for a run, as
`AGENT_CONFIG_FILE` does for the agents; `doctor.sh` also takes
`ATTRIBUTION_CLAUDE_SETTINGS_FILE` for the Claude settings file it checks.
Both exist for the tests of the scripts.

## Project bootstrap workflow

Run project bootstrap from a clean checkout after recording the initial project
idea and completing `docs/repository-setup.md`:

```bash
./scripts/start-planning.sh
```

The full interface is:

```text
./scripts/start-planning.sh [name] [--description <file>] [--agent <agent>] [--model <model>]
./scripts/start-planning.sh <name> --change <file> [--grill] [--agent <agent>] [--model <model>]
```

The second form changes a planning that is already approved; see "Changing an
approved planning" below.

If you already have a project description, pass it with `--description`:

```bash
./scripts/start-planning.sh --description ~/notes/project-idea.md
```

The file may be anywhere, including outside the repository. An uncommitted
description inside the repository is the one change the clean-checkout check
allows.
The script copies it to `docs/PROJECT_DESCRIPTION.md` in the planning worktree
before the first session. Project Grill reads it first and asks only about
what it leaves unresolved. Neither planning phase may modify it, and it is
committed with the planning branch as the recorded input. A missing, empty, or
non-regular file fails before a branch or worktree is created.

Project Grill uses role `project-grill`, the Draft review role
`planning-reviewer`, and the planning session role `project-planner`;
`--agent` and `--model` override all three. The optional name
defaults to `project-bootstrap`. A custom planning cycle such as:

```bash
./scripts/start-planning.sh architecture-refresh
```

creates `planning/architecture-refresh` in a sibling worktree named
`../<repository>-planning-architecture-refresh`.

The script fetches the default base of the project (`origin/<base>`: `base:`
in `.agents/template.conf`, `main` without it; see "The base of a
planning" below), records it for the branch, and creates the planning branch
from that remote ref without switching or modifying the primary checkout. It refuses a
dirty checkout, unsafe name, missing agent or prompt, unavailable base,
duplicate branch, or existing target path.

"Use this template" on GitHub copies every committed file of the template,
also its approval requests (`.agents/approval-requests/`) and plans
(`.agents/plans/`). Their numbers are the template's Issues and collide with
the project's: the reviewer of the project's Issue #2 would be shown the
template's request `2.json`. The first `start-planning.sh` of a project
(in a project that planned before, the next one) removes them in the
planning worktree, says which files it removed, and
stages the removal, so it goes into the planning pull request and no feature
has to. A file is inherited when the project's root commit added it and no
later commit touched it, not even to restore its first content; `.gitkeep`
is not one, and the project's own
requests and plans, which later commits add, stay. It happens only in a
project: a repository whose `origin` is not the `repository:` of
`.agents/template.conf` (compared as CI does, without a trailing `.git` or
`/`), so in the template nothing is removed. The removal is staged before the
planning sessions start and does not count as a change of theirs. A shallow
clone of a project does not hold the root commit, so the script first fetches
the full history (`git fetch --unshallow origin`); `doctor.sh` only warns
there that it cannot tell. Removing an
approval request needs no approval of the owner: the merge approval gate
checks only the requests a change adds or changes. `scripts/lib/inherited.sh`
finds the files; `doctor.sh` warns while they remain.

Bootstrap has two separate interactive agent sessions:

1. Project Grill reads the project context, asks only questions that materially
   affect product or technical direction, and refines
   `docs/PROJECT_REQUIREMENTS.md` in Draft state.
2. The script validates and displays the requirements, and has a read-only
   agent review the Draft before you approve it ("Draft review", below). It
   records Approved status and a UTC timestamp only after explicit human
   confirmation.
3. A fresh project-planner session consumes the approved requirements and
   creates or updates `docs/architecture.md`, `docs/roadmap.md`, and only
   necessary ADRs under `docs/decisions/`.

Project Grill records the owner's intent and its limits, not details of the
implementation: approved requirements bind the planner, who is better placed
to decide those. It writes a concrete value or list only when the owner asks
for one, such as the CPU and memory the owner chose, and a list is "at least"
unless the owner closes it. It promises nothing the technology does not
enforce ("capped", "guaranteed", "always"), and it marks an example as an
example. For instance, "the owner enables
`run.googleapis.com` and `artifactregistry.googleapis.com`" leaves the planner
no room when the service account turns out to need `iam.googleapis.com` too;
"the owner enables the cloud APIs the infrastructure needs, once, before the
first apply" records the same intent and leaves the list to the planner. The
guidance and a full example are in `.agents/prompts/project-grill.md`.

### Draft review

The approved requirements bind the planner, who may not change them: a defect
in them that the planning review finds costs planning rounds. So after
Project Grill, and before it asks for your approval, `start-planning.sh` has
the Draft reviewed. The reviewer uses role `planning-reviewer` with the
`read-only` profile and `.agents/prompts/requirements-reviewer.md`; it gets
the Draft, the project description, and in a change cycle the change request
and the diff of the requirements. It reports four kinds of defect:
statements that contradict each other (`inconsistency`), a constraint the
named technology cannot meet or a closed list that misses what the goal needs
(`infeasible`), a promise the technology does not keep, such as "capped",
"guaranteed", or "always" (`unkept-promise`), and a criterion no one can check,
such as "the smallest that serves" (`unmeasurable`). Each finding names the
section, quotes the text, says the problem, and proposes a wording.

The script shows the findings below the requirements, as `D1`, `D2`, and so
on, and asks you to choose:

- `g`: resume Project Grill with the findings. The new Grill session gets
  them in its prompt and goes through them with you; the proposed wording is
  a proposal, not a decision. The changed Draft is then reviewed again.
- `a`: approve the requirements as they are, with the open findings.
- `n`: mark findings as not applicable, with a reason. The remaining findings
  are shown again; when none remains, the question is the plain approval.
- `q`: stop without approving, as declining did before.

A Draft without findings gets the plain approval question. Each round is
stored as `.agents/reviews/requirements-<name>-review-NN.json`, which Git
ignores: the findings with their identifiers, the findings you marked as not
applicable with your reason and time (`not_applicable`), and your choice with
the findings still open then (`decision`). The run records note each choice
too. The reviewer must leave every file as it is and return a result that
matches `.agents/schemas/requirements-review.schema.json`; an invalid result
is retried once, and a second one, a changed file, or a failed session stops
the planning before the approval and keeps the worktree. A change cycle
without `--grill`, or whose Project Grill leaves the requirements unchanged,
has no Draft and no Draft review.

Declining requirements approval or an agent failure stops the workflow and
leaves the planning worktree intact. Inspect or revise it there; the script
never substitutes another model or removes user work automatically.

After successful planning, continue in the planning worktree with the planning
review, revision, and approval described below. `finish-planning.sh` prints
the exact commit and push commands.

### Planning review

Before committing the planning, let an independent agent review it from the
planning worktree:

```bash
./scripts/review-planning.sh
```

It uses role `planning-reviewer` with the `read-only` profile; configure a
different provider than for `project-planner`. The reviewed file set is the
planning documents: `docs/PROJECT_DESCRIPTION.md` when present,
`docs/PROJECT_REQUIREMENTS.md`, `docs/architecture.md`, `docs/roadmap.md`, and
the ADRs in `docs/decisions/`. The script supplies their contents and their
diff against the recorded base of the planning branch (`origin/<base>`), or
the default base of the project when none is recorded. The requirements must be approved first.

Each round is stored as `.agents/reviews/planning-<name>-review-NN.json` with
a generated report, in the same format as feature reviews but without an Issue.
The review covers only the planning documents, so it becomes stale when one of
them is added, changed, or deleted, and stays current otherwise
(`./scripts/check-review.sh`). A planning review is triaged like a feature
review, with the decisions of a planning, and then revised.

### Planning revision

Handle the findings of a current planning review:

```bash
./scripts/revise-planning.sh --review .agents/reviews/planning-project-bootstrap-review-01.json
```

It runs in two phases:

1. **Triage.** The script runs `triage-review.sh` on the planning review: the
   triage of a feature review ("Independent review triage"), with role
   `triage`, read-only, and the section "Planning triage" of
   `.agents/prompts/triage-reviewer.md`. It returns one decision per finding
   with a rationale: `FIX_NOW` (the planner revises the planning for it),
   `ACCEPT` (the finding is wrong or the planning is the better choice),
   `DEFER` (belongs to a later feature or feature plan; no follow-up Issue),
   `ESCALATE` (needs a product decision of yours or a change to the approved
   requirements), or `AMEND` (the approved requirements themselves are
   wrong, and a small diff of them fixes it; "Amending the approved
   requirements", below). `ESCALATE` and `AMEND` exist only in a planning
   triage; a feature triage that returns them is refused. Critical and
   major findings may only be `FIX_NOW`, `AMEND`, or `ESCALATE`: as in a
   feature triage they are never accepted or deferred by an agent, and the
   owner's record of a planning finding resolves a minor finding only
   (`finish-planning.sh --resolve`, below). The decisions are validated, shown
   to you, and recorded only after your approval, before any planning
   document changes, as the triage artifact
   `.agents/triage/<review>-triage.json` (schema `triage/v1` with `kind:
   planning`, the branch and the round of the review instead of an Issue)
   with a generated report. A planning triage runs only at a terminal of the
   planning worktree, never `--unattended`; it creates no Issue and is not
   published, since a planning has no Issue. `triage-review.sh --decisions`
   gives your own decisions instead, as for a feature.
2. **Revise.** The project planner (role `project-planner`,
   `.agents/prompts/planning-reviser.md`) resolves in a write session exactly
   the `FIX_NOW` findings, and aligns the planning with the amended
   requirements. It may change only `docs/architecture.md`,
   `docs/roadmap.md`, and direct Markdown ADRs. Any other change, including
   to the requirements, the description, or a review or triage artifact, and
   any commit fails the run and keeps the worktree for inspection.

`--agent` and `--model` choose the agent of both phases.

The scripts find such a change by recording the files of the worktree before
the session and comparing them afterwards; they say when they do. The record
covers every file that Git does not ignore, every ignored file outside an
ignored directory (a `.env`, for example), and everything under `.agents/`.
It leaves out the directories that Git ignores as a whole, such as a Python
environment, `node_modules`, a build output, or a test cache: a session that
runs a command may create or change them, and they are never reviewed or
committed. A secret written into such a directory is therefore not reported.

Escalated findings are listed with the next step: change the requirements
through Project Grill and approve them again, or, for a minor finding, record
your decision that it does not apply or that you accept the planning as it is
with it (`finish-planning.sh --resolve`, below). When the write session fails, the approved triage stays recorded;
while the review is still current, running the script again applies it
without deciding again.

After a revision the review is stale by design. Run `review-planning.sh` for
the next round, and repeat until the review passes.

#### Amending the approved requirements

Sometimes a finding's cause is the approved requirements: "cost is capped"
where the design can only limit cost, or a closed list of APIs that misses
one the requirements need. Escalating it would cost a hand edit and extra
review rounds. The triage decides `AMEND` instead and returns, with its
rationale, the minimal unified diff of `docs/PROJECT_REQUIREMENTS.md` that
corrects it.

- **Validated with the decisions.** The diff must change only
  `docs/PROJECT_REQUIREMENTS.md`, not its `Status:` or `Approved at:` line,
  and must apply cleanly, the amendments in the order of the decisions, to
  the requirements as they are. A diff that does not is an invalid decision:
  the triage agent gets one retry, then the run stops and nothing is recorded.
- **Confirmed by you, one by one, at a terminal.** After you approve the
  decisions, the script shows each amendment with its finding and its diff and
  asks "Apply this change to the approved requirements? [y/N]". It runs only
  at a terminal, never unattended or from a pipe.
- **Applied exactly.** On yes the script applies exactly that diff and
  refuses a result whose changed lines differ from it, sets `Approved at` to
  the time of your confirmation, and records in the triage the diff, your
  confirmation, and the requirements before and after. On no the finding
  stays `ESCALATE`, as without the decision, and the requirements are
  unchanged.
- **Aligned in the same revision.** The write session receives the amended
  findings with their diffs and brings the architecture, the roadmap, and the
  ADRs in line with the amended wording. When it fails, running the script
  again keeps the amended requirements and only repeats the write session.
  The next review round reviews the amended requirements with the rest.
- **Recorded in the approval.** `finish-planning.sh` lists every amendment
  of every round in `docs/PLANNING_APPROVAL.md` under "Requirements amended
  with the owner's confirmation", with its finding, the diff, and the time of
  your confirmation.

`AMEND` is for a small correction without which the requirements are
infeasible or contradictory. A new or changed requirement, a different
scope, or a product choice is not an amendment: it is escalated, and goes
through Project Grill or a change cycle with `--change --grill` ("Changing an
approved planning").

### Planning approval

When the latest review round is resolved, approve the planning:

```bash
./scripts/finish-planning.sh
```

The script refuses when a required document is missing, the requirements are
not approved, there is no planning review, the latest review is stale, the
latest round has a critical or major finding (escalated or not), a
finding of the latest round has no approved triage, a `FIX_NOW` finding is
not applied yet, or a finding of the latest round is escalated without your
decision. It shows every accepted, deferred, and escalated finding of all
rounds, with your decisions, also before a refusal. A finding escalated in an
earlier round is not resolved by a newer review alone: you confirm that it was
resolved, unless you recorded a decision on it, and the approval records
that. The approval covers exactly the reviewed planning; a document that
changes while the script waits for your answer is refused.

In a project that adopted the workflow, the adoption may have written the
planning documents as a reconstruction, each starting with the line
`> **Observed, not approved.** ...` ("Adopting an existing repository").
Approving the requirements in `start-planning.sh` removes the mark from them;
the planner removes it from the architecture and the roadmap it confirmed or
rewrote. `finish-planning.sh` refuses the approval while a planning document
still carries the mark, and names it: nothing reconstructed is approved
without passing through the planning.

The approval is recorded in `docs/PLANNING_APPROVAL.md`, which is committed with
the planning: the time, the planning branch, the final review round, the
review rounds, the findings that were not adopted, the amendments of the
requirements you confirmed, your decisions on escalated minor findings, and
the fingerprint of the planning documents. Use it for the planning PR description, because review
and triage files are not committed.

Whether the approval is still current:

```bash
./scripts/finish-planning.sh --check
```

exits 0 when it is and 1 when it is missing or stale. `create-feature-issue.sh
<feature-id>` refuses to create a feature Issue from a roadmap without a
current approval.

What makes the approval stale depends on the document:

| Document | Changed after the approval |
|---|---|
| `docs/PROJECT_DESCRIPTION.md`, `docs/PROJECT_REQUIREMENTS.md`, `docs/roadmap.md`, `docs/changes/` | Stale. What the product is and which features it gets changes only through a planning cycle, with a review and your approval |
| `docs/architecture.md`, `docs/decisions/` | Still current. Features keep these up to date, as the Definition of Done asks, and the feature review covers the change. `--check` lists the commits that changed them since the approval |

So a feature that describes what it built in the architecture, or records a
decision in an ADR, does not stop the next feature. The approval file itself
is not touched by a feature, so features that run side by side cannot conflict
in it. The next approval covers those updates and names their commits in the
record, with the Issue and the review of each, under "Updates by merged work".
A later approval keeps the entries of the earlier ones, also those of an
approval that an earlier version of the workflow amended. Until then `--check` lists them. A feature that changes the
roadmap or the requirements is refused by `finish-feature.sh` before its
commit, with the command of the change cycle.

The script finds the approved state from the commit that last changed
`docs/PLANNING_APPROVAL.md`: the planning documents in that commit must have
the recorded fingerprint. Change that file only through `finish-planning.sh`;
after a change by hand that does not match, any difference counts as stale.

Open and merge a planning PR before creating Issues for actionable roadmap
features. The script never implements features, creates Issues, commits,
pushes, opens or merges a PR, or deploys.

#### Your decision on an escalated finding

An escalated finding asks you to change the requirements or to decide that
they stay as they are. For a minor finding, the second needs no new review
round:

```bash
./scripts/finish-planning.sh --resolve MIN1 --type not-applicable --reason "Sync is a non-goal of the requirements."
```

`--type not-applicable` says that the finding does not apply; `--type
accepted` that you accept the planning as it is with it (stored as the type
`risk-accepted`). The reason is one line. The command runs only at a
terminal, never unattended or from a pipe: it shows the finding as the review
states it, the account (`gh api user`), the triage's rationale for the
escalation, and the record exactly as it will be stored, and asks once. It
accepts one finding of the latest round that the approved planning triage
escalated and that the review rates `minor`, while that review is current,
and one decision per finding. The severity is read from the review, never
from an argument or from the triage. A major or critical finding is refused, with its
severity and the ways that remain: a new review round after the planning
documents changed, or a change of the requirements (Project Grill, or a
change cycle). A record written by hand for such a finding is invalid and
resolves nothing.

The decision is the owner's exception record of a feature, with `kind:
planning` (one record for both, "Owner exceptions to a blocking finding"):
`.agents/exceptions/<review>-<finding-id>.json`, schema
`.agents/schemas/exception.schema.json`, which Git ignores. A planning record
excepts only a minor finding, a feature record only a critical or major one,
and a record never counts for a review of the other kind. A planning review
has no Issue, so the record is not published; the approval lists it. It is
bound to that review by its SHA-256, its round, and its reviewed tree, and
resolves the finding in that round only:

- `finish-planning.sh` approves a latest round whose escalated findings all
  have a decision (an escalated critical or major finding still blocks), and lists the
  decisions of every round in `docs/PLANNING_APPROVAL.md` under "Escalations
  resolved by the owner's decision". An escalation of an earlier round with a
  decision is not asked about again.
- A change of a planning document makes the review stale, and with it the
  decision; an edited review voids it. A later round that raises the finding
  again needs a decision of its own.
- `review-planning.sh` gives the planning reviewer every decision of the
  branch, with the planning documents that changed since it was made. The
  reviewer does not raise such a finding again unless one of those changes
  changed what it is about, and then names the decision
  (`.agents/prompts/planning-reviewer.md`, "Owner decisions").

## Changing an approved planning

A project changes while it runs: a new feature, a requirement that turns out
different, another technical direction. A change to the planning documents
goes through the same review and approval as the first planning, in its own
planning worktree, while feature work continues in its own worktrees.

Which route a change needs:

| Kind of change | Example | What changes | Command |
|---|---|---|---|
| Fits a feature that is not built yet | Sorting within the recipe list of F03 | Only the feature Issue | None; edit the Issue |
| New feature within the approved requirements | A shopping list the requirements already allow | Roadmap | `--change` |
| New or changed requirement | Sharing between households when one household was agreed | Requirements, and usually architecture, roadmap, and ADRs | `--change --grill` |
| Technical change only | From local storage to a server database | Architecture and an ADR that supersedes the old one | `--change` |
| Correction of the requirements that a planning review finds | A closed list of APIs misses one the requirements need | Requirements, by a diff you confirm, and the planning aligned with it | `revise-planning.sh`, decision `AMEND` of the planning triage ("Amending the approved requirements") |

Write the change down in a short file, in your own words, and start the cycle
from a clean primary checkout:

```bash
./scripts/start-planning.sh shopping-list --change ~/notes/shopping-list.md
```

The name is required. It names the branch `planning/shopping-list` and the
change request, which the script copies to `docs/changes/shopping-list.md`.
The original `docs/PROJECT_DESCRIPTION.md` stays as it is. The script requires
that the planning on the base has a current approval
(`./scripts/finish-planning.sh --check`).

Without `--grill` the requirements keep their approval and only the planner
runs. It changes what the change requires: the roadmap, the architecture, an
ADR, or several of them. With `--grill`, Project Grill runs first and asks
about the change only. When it changes the requirements, the script shows the
difference, has the changed Draft reviewed ("Draft review", above), and asks
for your approval before the planner starts; when it finds
that the approved requirements already allow the change, it leaves them
untouched and no approval is asked.

A change keeps what exists:

- **Feature IDs are stable.** A new feature gets the next unused ID. The
  script refuses a result that removed or renumbered a feature; a feature that
  is no longer wanted stays in the roadmap, marked as dropped.
- **Features with an Issue are not rewritten.** They may be in progress or
  delivered. A change to their behaviour is a new feature that depends on
  them.
- **ADRs are superseded, not removed.** A changed decision is a new ADR that
  names what it supersedes; the old one only gets a status line that says so.
  The script refuses a deleted ADR.

After the session, continue as after the first planning, in the planning
worktree:

```bash
./scripts/review-planning.sh
./scripts/revise-planning.sh --review .agents/reviews/planning-shopping-list-review-01.json    # when the review has findings
./scripts/finish-planning.sh
```

`revise-planning.sh` triages the findings with `triage-review.sh` (a planning
triage, `.agents/triage/<review>-triage.json`, "Planning revision"), which
you approve before any planning document changes.

The reviewer receives the change request and the complete planning with the
difference against the base, and checks the rules above. The approval records
the change request and covers it. Commit, push, and merge the planning pull
request; `cleanup-worktree.sh planning/shopping-list` then removes the
worktree and an untracked original of the change request.

A change to the requirements, the roadmap, the description, or a change
request makes the planning approval stale until the new one is merged. In
between, `create-feature-issue.sh` creates no new Issue. A feature that is
already in progress is not affected.

### The base of a planning

A planning branches from the default base of the project, as a feature does
("The base branch of a feature"): `base: <branch>` in
`.agents/template.conf`, and `main` without that line. `start-planning.sh`
fetches `origin/<base>`, creates the planning branch from it, reads the
approved planning of a change cycle there, and records the base for the
branch (`branch.<branch>.workflow-base`). `review-planning.sh` shows the
difference against that base, and `finish-planning.sh` names it in the next
steps as the branch the planning pull request merges into.

### A technical change between plannings

There is one route for each kind of change, and none without a review. A
change to the architecture or an ADR alone is a feature: a feature may update
`docs/architecture.md` and the ADRs under its own review, and the approval
stays current (`finish-planning.sh --check` names the commits). Under
`profile: light` a small one is a low-risk feature. A correction of the
requirements that a planning review finds is an `AMEND` of the planning
triage ("Amending the approved requirements"); anything else is a change
cycle.

## Creating a feature Issue from the roadmap

When a roadmap feature becomes active, create its Issue from its block in
`docs/roadmap.md`:

```bash
./scripts/create-feature-issue.sh F03
```

The script finds the heading that starts with the feature ID, such as
`### F03 — Sharing`, and uses everything up to the next heading of the same or
a higher level as the Issue body, unchanged. The heading becomes the title, so
the feature ID stays visible and review triage can use it for follow-up
provenance. The script shows the proposed Issue and creates it only after your
approval.

It refuses a feature ID that is missing, used for more than one heading, or
has an empty block, and it does not create a second Issue for a feature that
already has one, open or closed. When the block refers to another feature
whose Issue is still open, it warns before asking.

Create Issues one feature at a time, only for work that is about to start. An
Issue that is not a roadmap feature can still be created from a title and a
body file:

```bash
./scripts/create-feature-issue.sh "Issue title" path/to/body.md [label]
```

### Recurring work in an Issue

This rule holds for an Issue written by hand as for a roadmap feature that the
planner writes and the planning reviewer checks. A check that runs on every
change is paid for on every change, long after the incident that motivated it,
so the Issue that adds it says what it costs:

- **Where new recurring work runs.** A proposal that adds a trigger, a
  schedule, a CI job, a self-test, or a check that always runs states where it
  runs (locally, on the pull request, on a push, in projects through the
  sync), how often, and why a narrower trigger or a form you start on demand
  does not give the guarantee.
- **No standing ratchet.** "No test case is removed or weakened" is not a
  default acceptance criterion. An Issue that removes or replaces code removes
  its tests with it. An Issue that must keep a specific guarantee names that
  guarantee, not the number of tests or assertions that happen to check it.

The reviewer may ask for less as well as for more: a finding may recommend
removing a test, narrowing a trigger, or moving a check to where its inputs
change, and recurring work that a feature adds beyond what its Issue asked for
is a finding that the triage decides like any other.

## Canonical feature workflow

Start with an actionable GitHub Issue. Create a detailed implementation plan
under `.agents/plans/` for non-trivial work when warranted.

From a clean primary checkout, create the feature worktree and start the
implementation agent:

```bash
./scripts/start-feature.sh 12 player-movement
```

The full interface is:

```text
./scripts/start-feature.sh <issue> [slug] [base-branch] [--agent <agent>] [--model <model>] [--risk <level>]
./scripts/start-feature.sh <issue> --resume [--agent <agent>] [--model <model>] [--risk <level>]
```

The slug names the branch and the worktree. Without one, the script derives it
from the Issue title: the title without its feature ID, in lowercase, as at
most four words joined by hyphens. Reading the title is tried three times when
the connection or the service fails for a moment (a timeout, a reset or
refused connection, a host that cannot be resolved, a server error); any other
failure, such as an Issue that does not exist or a refusal, stops at once with
its reason. A connection that keeps failing ends with
status 75, which `run-feature.sh` tries again once after 30 seconds, as any
known transient error. The
script fetches the selected remote base (see "The base branch of a feature"),
creates `feature/<issue>-<slug>` in a sibling worktree, and starts the agent
of role `implementer` inside that worktree. Untracked files in the checkout do
not matter; modified tracked files do, because they would not be part of the
new worktree. After the session it prints the worktree path and the next
commands.

### The base branch of a feature

A feature branches from its base, is compared with it, and merges into it.
`start-feature.sh` takes the base as its third argument and records it for
the branch (`git config branch.<branch>.workflow-base`); every later step
reads it there: `run-feature.sh`, `review-feature.sh`, `triage-review.sh`,
`apply-triage.sh`, `finish-feature.sh`, `check-risk.sh`,
`check-guardrails.sh`, the self-test selection of `verify.sh`, and
`publish-feature.sh`, which opens the pull request into that base
(`gh pr create --base <base>`). An open pull request of the branch into
another branch stops `publish-feature.sh` before the push; change its base
on GitHub or close it, and publish again. A base given on the command line of
`review-feature.sh` or `check-risk.sh` overrides the recorded one for that
command.

Without a base on the command line, `start-feature.sh` uses the default of
the project: one line in `.agents/template.conf`,

```text
base: develop
```

and `main` without that line. The same default applies to a branch without a
recorded base. `sync-template.sh` changes only the `repository:` and
`commit:` lines of that file and merges the rest, so the line stays.
`create-feature-issue.sh` takes no base: the `start-feature.sh` it suggests
uses the default. A value that is not a valid branch name stops the script
that reads it.

GitHub applies `Closes #<n>` only when a pull request merges into the default
branch of the repository. When the base of a feature is another branch,
`publish-feature.sh` still writes `Closes #<n>` for a complete feature, and
says in its output and in the description that the merge does not close the
Issue. After the merge, `cleanup-worktree.sh <issue>` closes it (see
"Finishing a feature").

The implementer verifies its result itself: it finishes every edit to a
tracked file and then runs `./scripts/verify.sh`. That pass is recorded and
reused by the review that follows, so you do not run the verification by hand
between the two.

The Definition of Done in `AGENTS.md` asks a feature to update `docs/` and the
ADRs when it changes architecture or behavior, and so the documentation site
(`website/`) where it describes the changed behavior; a project without
the site skips this. The site summarizes this guide in its own voice and
markup, it does not add to it. No check enforces it: the reviewer reports a
change the site describes and the feature left out as a finding, `minor`, or
`major` when the site now says something false.

A new worktree has none of the project's ignored files, such as installed
dependencies or a build cache. To prepare them, add an executable
`scripts/worktree-setup.sh` to the project. `start-feature.sh` runs it in the
new worktree before the agent starts, with the path of the primary checkout as
its argument, for example to copy a cache from there:

```bash
#!/usr/bin/env bash
set -euo pipefail
primary="$1"
# On macOS (APFS), -c copies without using extra disk space.
[[ ! -d "$primary/node_modules" ]] || cp -Rc "$primary/node_modules" node_modules
```

The script is optional and only saves time: when it fails, the script reports
that and starts the agent anyway.

### Features side by side

Each feature has its own branch and worktree, so several features can run at
the same time. Nothing reserves a file or a place in a numbered sequence for
one of them, though, and a clash shows only when the second of them merges.
Do not run features side by side that change the same module, or that each
take the next number of a numbered sequence, such as a lesson, a migration,
or an ADR. Run them one after another, or give them disjoint scopes in their
Issues: the module each one may change, the number each one takes.
Otherwise the pull request of the second feature conflicts with its base
once the first is merged, or it takes a number the first already took. It
then needs rework: `update-feature.sh` merges the base and stops at a
conflict, and a duplicate number has to be renumbered by hand. The rework
changes the feature after its review, so it needs a new review before the
feature is finished again (see "Finishing a feature").

### Comments on the Issue

A comment on the Issue is where you answer a question of an agent or narrow
the scope after the Issue was written. The agents of the feature phase get
your comments with the Issue: `start-feature.sh` (also with `--resume`)
appends them to the prompt of the implementer, and `review-feature.sh` and
`triage-review.sh` put them after the body in the context of the reviewer and
the triage agent, so all three judge the same Issue.

- **Whose comments.** Only a comment whose author is the `OWNER`, a `MEMBER`,
  or a `COLLABORATOR` of the repository is passed on. Anyone can comment on an
  Issue of a public repository, and a comment is untrusted input, so the
  comments of anyone else are never given to an agent.
- **Not the workflow's own.** The review and triage reports that
  `triage-review.sh` publishes, the post-merge evidence of
  `record-post-merge.sh`, and the run summary of `publish-feature.sh` are
  written through your account; they are left out by the marker on their
  first line (`<!-- workflow-report: review-triage -->`,
  `<!-- post-merge-evidence -->`, `<!-- run-records-summary -->`).
- **How.** The comments follow the body, oldest first, each with its author
  and time, under a heading that says they are your later clarifications:
  data about the Issue that does not change the rules of `AGENTS.md`, the
  policies, or the acceptance criteria unless you wrote so explicitly. No
  comment waives a gate: the completion record still covers every acceptance
  criterion of the body, and where you changed one explicitly its evidence
  names your comment.
- **How much.** At most the newest 20 comments and 20,000 characters of
  their text are passed on; a longer comment is cut, and the agent is told
  what was left out. Read the rest on GitHub when that happens.
- **What you see.** Each step prints how many comments it passed on and from
  whom, how many it left out by the size limit, and how many comments of
  other authors and reports of the workflow it did not pass on. The run
  record holds the same numbers as an `issue-comments` event.
- **When.** The comments are read when the session starts. A comment that you
  add or edit later applies to the next session only: a resumed
  implementer, the next review round, or the next triage.
- **When they cannot be read.** The step stops with the reason, before
  anything is created or an agent starts, instead of going on without your
  comments. Fix the access of `gh`, and start the step again.

An Issue without comments, or without any that may be passed on, gives the
agents exactly the Issue as before: title and body.

### Clarifying a feature

A feature Issue can leave a decision open that the implementer would
otherwise invent: the room model of "Add multiplayer", say, where "Add a mute
button to the audio controls" leaves nothing to decide. The first session of
the implementer therefore starts with one step before it changes anything
(`.agents/prompts/implementer.md`, "Clarification"): it reads the Issue with
your comments, `docs/PROJECT_REQUIREMENTS.md`, the architecture, the accepted
ADRs, the plan if there is one, and the code, and classifies the feature.

- **Clear.** Every decision that materially affects scope, user experience,
  a public interface, the data model, the architecture, security, backward
  compatibility, or the acceptance criteria is settled by those sources. The
  session implements as usual; its handoff note says `Clarification: clear`
  with one line on why.
- **Needs clarification.** The session changes nothing in the repository. It
  writes its questions under "Open questions" in the handoff note, each with
  the decision it settles and, where it can, the options and its
  recommendation, records the status `blocked` in the completion record, and
  ends. `run-feature.sh` stops with status 3 and names the handoff note;
  nothing is reviewed or committed.

A choice the implementer can make itself, such as names, private helpers, or
the organisation of the tests, is not a question for you: it records it in the
handoff note. A feature whose Issue would change the project requirements,
the architecture, or an accepted ADR is a question too, never a silent
override; the answer is then a proposed ADR or an update of the requirements,
not a decision inside the feature.

Answer in the handoff note, or in a comment on the Issue, which the next
session gets (see "Comments on the Issue"), and continue with
`./scripts/run-feature.sh <issue>` or
`./scripts/start-feature.sh <issue> --resume`. That session reads the answers and implements; it asks again only
about a decision that the answers left open. The decisions stay in the handoff
note and on the Issue: there is no separate requirements file per feature, and
a plan under `.agents/plans/` can take them up when the feature has one.

The step is not an interview. A clear feature gets no questions, and the
reviewer does not report missing clarification for a feature whose handoff
note says `Clarification: clear`, unless the result settles a decision the
sources left open. A session that ends with `BLOCKED:` but writes no question
under "Open questions" leaves nothing to answer: the line is ignored and the
run goes on, so the step cannot stall a run silently. How often features stop
for questions shows in `./scripts/report-runs.sh` as blocked runs.

### Resuming an interrupted feature

A session can end before the work is complete: a closed terminal, a usage
limit, an agent that got stuck. Continue with:

```bash
./scripts/start-feature.sh 12 --resume
```

Run it from any checkout of the repository. It finds the worktree whose branch
is `feature/12-*` and starts a new implementer session there; it creates
nothing. `--agent` and `--model` let another provider or model continue.

The new session does not have the earlier conversation. It is told to read
the state from the repository: the Issue, the plan, `git status` and the diff
against the base, the latest review or triage if the interrupted session was
resolving findings, and the handoff note.

The handoff note is `.agents/handoffs/<issue>.md`, a working file that Git
ignores. The implementer keeps it while it works, updated after each completed
part and not only at the end, with what is done, what is in progress, what
remains, and what was tried and rejected. A session that ends abruptly may not
have updated it, so the script compares it with the files: changed files that
are newer than the note are named to the new session as not described by it.
Resuming also works without a note.

After a resumed session, continue as after `start-feature.sh`: review, triage,
fixes. When the interrupted session was `apply-triage.sh`, the partial fixes
have made its review stale; resume, then run `review-feature.sh` again.

### The completion gate

A session that ends is not a feature that is complete. An implementer can
stop after two of nine plan steps and end normally, and nothing in the exit
status says so. The scripts therefore decide from what the implementer
recorded, not from the fact that it stopped.

The implementer writes a completion record before it ends, in every session:
`.agents/completion/<issue>.json`, a working file that Git ignores.

```json
{
  "schema": "completion/v1",
  "status": "partial",
  "criteria": [
    {"criterion": "Recipes can be searched by ingredient",
     "status": "met",
     "evidence": "tests/test_search.py::test_search_by_ingredient passes"},
    {"criterion": "The search page works without JavaScript",
     "status": "not_met",
     "evidence": "not started; plan step 4"}
  ],
  "remaining": ["Plan steps 4 to 6: the page without JavaScript, the documentation"]
}
```

The record follows `.agents/schemas/completion.schema.json`, which the
generic validator of `scripts/lib/guardrails.sh` checks; a record that does
not validate is refused with the field named
(`record.criteria[1].status must be one of met, not_met, not_applicable,
pending`). `status` is `complete`, `awaiting_evidence`, `partial`, or
`blocked`. A criterion is `met`, `not_met`, `not_applicable`, or `pending`,
each with evidence. `complete` needs every criterion met or not applicable
and nothing remaining; `partial` and `blocked` need something that remains.
These rules across fields, which a schema cannot express, stay in
`completion_errors` (`scripts/lib/completion.sh`), and a record that breaks
them is invalid as well. An optional `checks[]` holds the triage
implementer's check of each finding to fix (see "Fixing triaged findings"
below).

The record is the single source of remaining work: the gate reads
`remaining[]` and nothing else. The handoff note keeps its sections for
people and for the next session, and no script parses them; readable
Markdown reports are never parsed (the retained decision of #30). A feature
whose note, written by an earlier version of the workflow, still lists work or
checks of findings that the record lacks carries them into the record once;
the prompt of the resumed session says so.

The evidence of a criterion cannot be a partial run of the checks: a record
that cites `./scripts/verify.sh --changed` or `--only` is refused. For a
criterion that the full verification shows, such as "`./scripts/verify.sh
--all` passes", an unattended session names the pass that `run-feature.sh`
makes after it, for example "the full verification that run-feature.sh makes
after this session", and the gate accepts it as `met`: that pass exists
before anything is reviewed, and a failure of it comes back as a repair
session (Issue 490).

#### Evidence that cannot exist yet

Some evidence appears only later: the CI result of a pull request that is not
published yet, the owner's approval of the final commit, a verification of
the default branch after the merge. A criterion therefore names the `gate` at
which its evidence can exist (optional; `implementation` when absent):

| Gate | Evidence exists | Required before |
|---|---|---|
| `implementation` | When the implementer ends | The commit and the pull request |
| `pr_ci` | After the pull request is published | The merge |
| `owner_approval` | When the owner approves the final commit | The merge |
| `post_merge` | After the merge | Closing the Issue |

Only a criterion of a later gate may be `pending`, with the moment its
evidence appears in `evidence`. When every other criterion is met or not
applicable, nothing remains, and something is pending, the status is
`awaiting_evidence`: the feature is reviewed, committed, and published
without `--partial` or `--no-review`, and the reviewer does not report the
pending evidence as a defect. It reports a criterion that is pending although
its evidence could exist now. `complete` keeps its meaning: every required
criterion is satisfied. A not met criterion of the implementation gate cannot
be hidden as pending, and a pending criterion cannot be in a `complete`
record.

Pending `pr_ci` and `owner_approval` evidence is not recorded anywhere by the
scripts: CI and the merge approval gate on the pull request already hold the
merge until it exists, and they are not weakened. A criterion that the record
leaves pending at the `owner_approval` gate also makes `finish-feature.sh`
state that the merge needs the owner's approval, whatever the diff and the
review say: a record can require the owner's approval, never grant it. So
does a criterion that the record calls met and the review of the complete
feature could not confirm (see "Review and triage data", `unverified_criteria`). The pull request of a
feature that awaits only these closes the Issue as usual. A feature that
awaits `post_merge` evidence is published as ready for review, but without
a closing keyword: the commit text refers to the Issue with `Refs`, and the
description says that the Issue stays open and lists the pending criteria. After the merge, record each one with

```bash
./scripts/record-post-merge.sh <issue> "<criterion>" "<evidence>"
```

which posts the criterion and its evidence as a comment on the Issue and
closes the Issue when no `post_merge` criterion is left. The criterion must
be given exactly as the pull request lists it: the finish commit holds one
line `Post-merge criterion: "<criterion as a JSON string>"` per pending
`post_merge` criterion, and the script matches those strings exactly, so a
criterion that begins like another, or holds parentheses or quotes, never
stands for it. `publish-feature.sh` publishes a feature as ready only when
the pending `post_merge` and `owner_approval` lines of the finish commit
equal those of the record; a record edited after the finish needs a new
`finish-feature.sh`, because the finish decides what the pull request states
and whether the merge needs the owner. No pull request and
no review round is needed; the comments are the audit trail. The script does
not authenticate who gives the evidence: it is an agent-written or owner
comment under the account that runs `gh`, not an independent approval. Owner
approval stays with the merge approval gate and with the work to enforce it on
GitHub with a separate identity (#99).

The gate passes when the record is valid and says `complete` or
`awaiting_evidence`; a valid record with either status has an empty
`remaining[]`. What the handoff note says under "Remaining" does not change
the outcome. Two things are never evidence: a partial run of the checks
(`verify.sh --only`), which is not a verification, and a budget check of
`scripts/verify.conf` or `scripts/verify-workflow.conf` (see "Budgets"),
which is a measurement that never fails the verification. A record whose
evidence for a met criterion names such a run, or names a budget check as a
word, is invalid.

| Script | What the gate decides there |
|---|---|
| `start-feature.sh` | After the session it says whether the Issue is complete, and offers the review only then |
| `run-feature.sh` | Goes on to the review only when the gate passes and the summary of the changes exists; otherwise it resumes the implementer with the reasons in the handoff note, at most four sessions in a run. `blocked` stops the run with status 3. The gate is asked again before every later review, because a session that repairs the verification is a session of the implementer too |
| `review-feature.sh` | Gives the record to the reviewer of the complete feature, as a claim to check |
| `finish-feature.sh` | Refuses a missing, invalid, partial, or blocked record. `--partial` commits partial work as your explicit choice, and is refused for a feature that is complete or awaits evidence |
| `publish-feature.sh` | Asks the gate again. The pull request closes the Issue only when the commit says `Completion: complete` (or `awaiting_evidence` with no `post_merge` evidence pending) and the gate still agrees. A feature that awaits `post_merge` evidence is published for review with `Refs`; any other outcome is a draft that refers to the Issue and says why it does not close it |
| `record-post-merge.sh` | After the merge: records the evidence of a pending `post_merge` criterion as an Issue comment, and closes the Issue when none is left |

The record is a claim of the implementer, and an implementer can claim
`complete` wrongly. The scripts only read the status. What checks the claim
is the independent review of the complete feature: the reviewer goes through
every acceptance criterion of the Issue against the diff and the tests, and
reports a criterion that is not met, or a `met` the code does not support, as
a major finding. That is why a feature is committed only on a review of the
complete feature (see "Reviewing only the changes").

When you implemented a feature yourself, write the record yourself: it is the
statement that the Issue is done, with where to see it.

### Reviewing a feature

After the implementation agent exits, enter the feature worktree. When
independent review is required by `.agents/policies/autonomy.md`, run it before
committing so the reviewer includes the complete working-tree changes:

```bash
cd ../project-12-player-movement
./scripts/review-feature.sh 12
```

A reviewer cannot run the checks, so the review starts only when
`./scripts/verify.sh` passes for the content under review. The script runs it
first, names the failing check when it fails, and starts no agent then. The
review records that verification passed for the reviewed tree. To have a
failure reviewed, for example when its cause is unclear, pass
`--unverified "<reason>"`; the review then records the reason instead.

The full interface is:

```text
./scripts/review-feature.sh <issue> [base-branch] [--agent <agent>] [--model <model>] [--changes] [--unverified "<reason>"]
```

It uses role `reviewer` with the `read-only` profile, and refuses to start
when the reviewer resolves to a provider the implementer ran with for the
feature, by the run records, or, without a recorded session, to the
implementer's provider for the feature's risk level (see "Configuring
agents"). The review is
non-interactive: the reviewer cannot modify files and has no network access, so
the script supplies the GitHub Issue and the complete diff against the base
branch, including uncommitted and untracked changes. Without `[base-branch]`
the base is the one the feature recorded, or the project default (see "The
base branch of a feature"). The reviewer returns its
result as JSON and the script validates and stores it. An invalid result is
retried once and then rejected, and a reviewer that changed the working tree or
created a commit is reported as an error; in both cases no review is stored.

The diff starts where the feature left its base branch. The feature was
created from `origin/<base>`, and the local `<base>` of your checkout can be
behind it, for example after pull requests were merged on GitHub. The script
therefore uses whichever of the two shares the more recent commit with the
feature, so that work merged before the feature started never counts as the
feature's own change. You do not have to pull the base branch first.

The review script must run from the matching feature worktree and needs an
authenticated GitHub CLI. Each round writes a numbered pair of files without
overwriting earlier reviews:

```text
.agents/reviews/feature-12-player-movement-review-01.json
.agents/reviews/feature-12-player-movement-review-01.md
```

See "Review and triage data" below for the two files.

Triage an explicit review artifact with an agent independent from the
implementation:

```bash
./scripts/triage-review.sh \
  .agents/reviews/feature-12-player-movement-review-01.json
```

The full interface is:

```text
./scripts/triage-review.sh <review-json> [--agent <agent>] [--model <model>]
./scripts/triage-review.sh <review-json> --decisions <file> --reason <text> [--proposal <file>]
```

The triage agent (role `triage`) classifies every finding as:

- `FIX_NOW`: resolve before the feature proceeds. Critical and Major findings
  always use this category.
- `DEFER`: valid non-blocking work proposed as a separate follow-up Issue.
- `ACCEPT`: consciously take no action, with an explicit rationale.

The script validates the decisions before showing them: every finding is
decided exactly once, Critical and Major findings are `FIX_NOW`, and a deferred
finding has a follow-up title, action, and acceptance criteria. Invalid
decisions are retried once and then rejected. `ESCALATE` and `AMEND`, which
the schema also allows, are decisions of a planning triage only ("Planning
revision"); a feature triage that returns one is refused, and a feature
triage artifact has no `kind` and no `amendment`, as before. A review without
findings needs no triage agent. The triage mode of the project policy for the risk level of
the feature, `full` or `light` (see "What each level requires" and "Light
triage"), is derived by the script itself from the diff and the rules of the
base, shown before the proposal, told to the agent when it is `light`, and
recorded in the artifact (`triage.mode`); a `high` feature always gets the full triage.
A triage artifact without `triage.mode` is invalid, and so is a feature review
without `kind`, `verification`, or `scope`: the scripts write these fields into
every artifact, so a missing one is a broken or hand-made artifact, and the
gates refuse it with a message that names the field instead of reading it as a
full triage, a verified review, or a review of the complete feature (#520).

The script displays the complete proposal before side effects. Only after
interactive approval does it create one GitHub Issue per `DEFER` finding and
write a persistent, uniquely named artifact such as:

```text
.agents/triage/feature-12-player-movement-review-01-triage.json
.agents/triage/feature-12-player-movement-review-01-triage.md
```

That artifact maps the source review findings to their decisions and any
created Issue numbers. After storing it, the script publishes the review and
triage reports as one comment on the source Issue, so the outcome is visible in
the Issue and, through `Closes #12`, from the pull request. The reports are
rendered from the JSON. When they exceed the size of one GitHub comment, they
are published in numbered parts rather than shortened. Every comment, and
every part, names the stored artifact by its path and SHA-256 and says which
part it is (`Triage record: ..., part 1 of 2`). That comment is the record of
the publication: the artifact holds no field for it, so the two cannot
disagree (Issue 527). `finish-feature.sh` and `run-feature.sh` read the
comments of the Issue and count a triage as published only when the
workflow's comments, with their marker, hold every part of a report of
exactly that artifact; a triage changed after its publication is not
published. Only a comment of the authenticated GitHub account (`gh api user`)
counts, the account through which `triage-review.sh` posts: the marker and the
SHA-256 are public, and anyone else who can comment, a member or a
collaborator of the repository too, could write a matching line. A triage
published through another account is therefore not found by a run of this
one; publish it again with `--publish` from the account that commits. When the
comments or the account cannot be read, as without network access, they say
that they cannot check, and stop. A failed publication keeps the stored
triage and prints the command to retry each unpublished part; once every part
is on the Issue, the triage is published, or `--publish` publishes all of it
again. An artifact of an earlier version that still has `published_at` is
refused with what to do: remove the field and publish it again. Declining the proposal creates neither an artifact nor
Issues. The source review remains unchanged. The artifact is stored only after
every follow-up Issue exists; if creating one fails, nothing is stored and a
new triage reuses the Issues created so far, which it finds by their trace
token. A re-run reuses a follow-up Issue that already exists for a finding.

The order is review, triage, fix, verify, review again. Triage every round
with findings before you fix anything from it; `review-feature.sh` says so.

**Historical triage.** Triage applies to the content that was reviewed, so a
review whose code changed afterwards is stale. When findings were fixed before
their triage, the round can still be triaged as a historical review, provided
a later review round of the same Issue exists (the latest round never
qualifies, so a historical review cannot stand in for a fresh review of the
current code) and its reviewed tree is still in the Git object database. The
triage agent then reads an extract of the reviewed tree, not the live
worktree, and classifies the findings as they were reported; the later review
confirms whether they were fixed. The proposal, the approval question,
`--unattended`, the follow-up Issues and the publication on the Issue are the
same as for any triage, and the artifact records `"historical": true`. When
the review is the latest round, or its tree is gone, the script refuses and
creates nothing: run a new review first and triage the older round after it.
`finish-feature.sh` still needs a current latest review and an approved,
published triage of every round with findings; nothing here replaces either.
The extract holds every path of the reviewed tree (also `export-ignore`
paths) and is a Git repository of its own, because Codex refuses to start in
a directory that is not one. A complete historical triage with Codex as the
`triage` agent has not been verified; the automated tests use fake agents, so
full Codex compatibility is not claimed.

### Owner-directed triage

Approving or declining is not always enough: the triage agent can propose
`FIX_NOW` for a suggestion or a trivial documentation point that you decide to
`ACCEPT`, and running the agent again gives the same proposal. Approving a fix
you do not want costs another implementation, verification and review cycle,
which finds new suggestions. In that case, and only when the agent's proposal
is disproportionate, give the decisions yourself:

```bash
./scripts/triage-review.sh <review-json> \
  --decisions <file> --reason "<why you override>" [--proposal <file>]
```

`<file>` has the shape of the triage schema (`{"decisions": [...]}`, one entry
per finding with `finding_id`, `decision`, `rationale`, and `followup`, which
is required for `DEFER` and `null` otherwise). `--proposal` optionally gives
the decisions the agent proposed (for example its output from an earlier run),
so they are recorded next to yours. The same rules apply as for an agent:
every finding exactly once, no unknown IDs, a follow-up for every `DEFER`, and
critical and major findings stay `FIX_NOW` unless you accept or defer them
with the owner's exception record (below). The reason is required, no agent is started, and `--unattended` is
refused. The script shows your exact decisions, the reason and the account, and
asks for your confirmation before it creates follow-up Issues. It then shows
the complete artifact, with the follow-up references, and asks once more
before it stores and publishes it. The files are copied before anything is
shown, and the artifact is stored exactly as shown, and published as stored:
the comment names its SHA-256. Declining the second question stores and publishes
nothing; follow-up Issues already created are reused by the next triage.

A critical or major finding that your decisions accept or defer is decided
only with the owner's exception record ("Owner exceptions to a blocking
finding", below), which the override writes: of type `risk-accepted`, with
your decision and its rationale as the reason, bound to the review by its
SHA-256. A valid record that is stored already, such as a `not-applicable`
one of `record-exception.sh`, is used as it is; an invalid one is refused. It
needs a terminal (standard input and output), the latest and current review,
and not a historical one; otherwise nothing is created. The records are shown
with your decisions before the first question; after the second, each new
record is published as a comment on the Issue with its SHA-256 and stored,
before the triage is. A failed publication stores neither. An agent's triage
never accepts or defers such a finding, whatever records exist: a stored
triage that does is valid only while it is owner-directed and each such
finding has its valid record.

The artifact has an `owner_directed` object with the `reason`, the `account`
that ran the script, the time (`directed_at`), and the `original_proposal`
when one was given; the comment on the Issue shows them. Old artifacts without
the field stay valid. It is not a way to skip the review: the round still
needs an approved and published triage, `finish-feature.sh` and the other
gates are unchanged, and the stored decisions are protected like every review
and triage artifact, so `apply-triage.sh` and `finish-feature.sh` read them as
they are and an agent that changes them is detected.

Deferred follow-up Issue titles include deterministic provenance:

```text
[F02][R01][S2] Concise follow-up title
```

The script obtains the feature ID from the source Issue title and the review
round and finding ID from the review. When no feature ID is available, it falls
back to the source Issue number:

```text
[#12][R01][S2] Concise follow-up title
```

Apply the approved `FIX_NOW` set from the same feature worktree:

```bash
./scripts/apply-triage.sh \
  .agents/triage/feature-12-player-movement-review-01-triage.json
```

The full interface is:

```text
./scripts/apply-triage.sh <triage-json> [--agent <agent>] [--model <model>]
```

The helper uses role `triage-implementer`. It validates the approved artifact and source review, shows the exact
`FIX_NOW` scope, and asks for confirmation before starting a write-capable
agent. It never passes `DEFER` or `ACCEPT` findings to that agent. After the
agent exits, it verifies that the review and triage artifacts are unchanged and
verifies the result with `./scripts/verify.sh --reuse`, so a pass that the
agent recorded for exactly that content is not repeated.

Before it verifies, it checks the completion record that the session left
(`.agents/completion/<issue>.json`) with the rules of the completion gate
(`completion_errors`, `scripts/lib/completion.sh`), so that a record the gate
refuses, such as one that cites `./scripts/verify.sh --changed` as evidence,
is found before the review and not at the commit after it. An unattended
session gets one session of the same agent to correct the record, with the
errors; a record that still does not pass, or one of an interactive session,
stops the helper with status 1 and the errors, before the verification.

The helper does not commit, push, merge, deploy, or create/close Issues. Inspect
the resulting diff and run another independent review and triage when fixes
require confirmation.

A fix session does not only repair the place a finding names
(`.agents/prompts/triage-implementer.md`). For each `FIX_NOW` finding it names
the class of the defect in one sentence and looks for the same pattern in the
files the feature changes and their tests, fixing it there and only reporting
it elsewhere. When the finding claims that something goes wrong and a small
test or command can show it, it runs that first, and records one entry per
finding in `checks[]` of the completion record:
`{"triage": "<triage file name>", "finding": "<id>", "value": "<value>",
"evidence": "<evidence>"}`, where the value is `fixed`,
`refuted` (a reproduction shows the claim does not hold), `not_reproduced`
(the reproduction ran and shows nothing, which proves nothing), or
`not_executable` (it cannot run here; fixed only when reading settles it).
For the last three the code of the finding stays unchanged. `apply-triage.sh`
names at its end the findings returned that way, or without a single check,
and they stay `FIX_NOW`: no script resolves or refutes a finding, and only a
fix recorded as `fixed` with its evidence, or a new triage decision, closes
it. The next review gets the entries under "Decisions of the earlier rounds" and
the triage agent in a section of its own, both as the implementer's statement
and not as evidence, so the existing triage, with its approval, decides again:
a `refuted` minor finding can become `ACCEPT` with its rationale. The entries
are not remaining work for the completion gate, and the triage schema has no
new category.

A `refuted` critical or major finding cannot become `ACCEPT` without you.
When the reviewer, given the refutation, reports it again as `unresolved`
(its `previous`, with the same title: a finding whose title differs, apart
from the mark `Unresolved: ` or `, unresolved`, is a new finding, and the
refutation of the earlier one does not carry over to it), and every `FIX_NOW` finding of that round without your
exception was refuted that way, one of them critical or major,
`run-feature.sh` starts no fix session: the implementer would refute it
again. It stops with status 3 and names each finding with the round and the
evidence of its refutation. A review of changes only goes on to the review of
the complete feature first, since an exception binds only to the latest
review. The run writes nothing into the handoff note then, so that review
stays current. Your ways on, printed with the stop:

- you agree that the finding does not hold: record an exception with
  `./scripts/record-exception.sh <review-json> --finding <id> --type
  not-applicable --evidence ".agents/completion/<issue>.json" --reason "<why>"`
  (below);
- a minor finding or a suggestion among them: an owner-directed triage that
  accepts it (`triage-review.sh <review-json> --decisions <file> --reason
  "<why>"`, above);
- the reviewer is right: write your instruction into the handoff note and
  resume the implementer with `./scripts/start-feature.sh <issue> --resume`.

Then run `./scripts/run-feature.sh <issue>` again: with your exception it
goes on to the commit, after a fix it reviews again, and without a decision it
stops in the same way. A `not_reproduced` or `not_executable` finding proves
nothing either way and is fixed in the next round as before. `scripts/lib/completion.sh` reads the entries (`completion_finding_checks`).
Whether this makes fix rounds cheaper is a follow-up evaluation over later
features; its baseline and measures are in `docs/evaluation.md` ("Measuring
the fix rounds").

### Owner exceptions to a blocking finding

A critical or major finding of the latest review stops `finish-feature.sh`,
and an agent's triage keeps it `FIX_NOW`. When you, the owner, judge that
such a finding is wrong, or that it is right and you accept its risk, record
that decision for that one finding instead of fixing it or committing around
the workflow. One record holds every such decision of the owner: this
section's, an owner-directed triage that accepts or defers the finding
(`triage-review.sh --decisions`, "Owner-directed triage", which writes it),
and, with `kind: planning`, your decision on an escalated minor finding of a
planning review (`finish-planning.sh --resolve`, "Your decision on an
escalated finding"). A record without `kind`, as every record was before the
field existed, is a feature record.

```bash
./scripts/record-exception.sh <review-json> --finding <id> \
  --type not-applicable|risk-accepted --reason "<why>" [--evidence "<text or path>"]
```

- `not-applicable`: the finding is wrong or does not apply; `--evidence` says
  what shows it and is required.
- `risk-accepted`: the finding is valid and you accept its risk, which the
  reason names; `--evidence` is optional.

Only a critical or major finding of the latest, current review of the feature
can be excepted, one finding per call and one exception per finding: an
unknown ID, a minor finding or a suggestion, an older round, a stale review,
an empty reason, `--unattended`, and a run whose standard input or output is
not a terminal are refused. There is no wildcard and no `--force`. The script
copies the review before it shows anything, shows the finding, the account
(`gh api user`), and the complete record, and asks once; it stores the record
exactly as shown in `.agents/exceptions/<review>-<id>.json` (schema
`.agents/schemas/exception.schema.json`; Git ignores the directory) and
publishes it as a comment on the Issue with its SHA-256. Declining stores and
publishes nothing.

The record holds the type, the reason, the evidence, the account, the time
(`directed_at`), the review with its SHA-256 and round, the finding's ID,
title, and severity, and the review's reviewed tree and merge base. It counts
only while all of it holds: the review artifact still has that SHA-256, it is
the latest round, it is current for the content (`check-review.sh`), every
field agrees with the review, and the record is the one published on the
Issue. A change of the content, a new round, an edited review, or an edited,
renamed, or incomplete record makes it invalid; nothing carries it forward or
refreshes it, and a new round needs a new decision.

With a valid exception for every blocking finding, `finish-feature.sh`
commits; it names each finding that still lacks one otherwise. Every other
gate applies exactly as without it: the verification, the completion gate and
its criteria, the triage of each round, the summary. The review and its
verdict are never edited, and an exception does not turn it into a pass: a
finding that says an acceptance criterion is unmet does not change the
completion record, which must still prove the criterion. The commit message
keeps the verdict in its review line and lists each exception under "Owner
exceptions to blocking review findings", with the finding, the type, the
account, the time, the reason, and the record with its SHA-256; the merge
approval gate then always requires the owner, and the approval request names
each record with its SHA-256. An exception can only require your approval,
never grant it. A commit whose message, after the editor, no longer lists a
record with its SHA-256, or whose record changed meanwhile, is undone.
`publish-feature.sh` recomputes the SHA-256 of each record the finish commit
lists and checks it against the latest review again, judging the review
against the content of the finish commit: a merge of the base afterwards
leaves the exception valid, while a commit after the finish that changes the
feature refuses it. A missing, changed, or invalid record is reported and
nothing is pushed, so it is never shown as your decision. Otherwise the pull
request description starts with each original finding and your exception. The run record notes the exception as
an intervention.

`run-feature.sh` never records, proposes, or confirms an exception. It reads
them: a round whose only `FIX_NOW` findings have your valid exception goes on
to the commit. When it stops because the rounds are used up, it names
`record-exception.sh` as your option.

The limit of this trust: the confirmation at a terminal follows the model of
the owner-directed triage. Until the template's Issue #99 gives the agent an
identity of its own, the account is the login of whoever ran the script, and
the rule that only you record an exception is an agreement that the scripts
and agents keep, not a guarantee against an agent that drives a terminal with
your credentials. The merge, which needs your approval on GitHub, is where
you decide; #99 is where the account of an exception becomes verifiable.

### Review and triage data

Results that an agent writes and a script consumes are JSON. Each review and
each triage is stored as two files with the same name:

- `.json` is the source of truth. The scripts read only this file.
- `.md` is a report generated from the JSON for reading. It is never parsed;
  editing it has no effect.

Both are working files for the scripts during a feature and are ignored by
Git, so `git add .` does not commit them. The record that stays is the comment
on the Issue and the follow-up Issues, each of which names its source finding.

The agent's result must match a schema in `.agents/schemas/`
(`review.schema.json`, `triage.schema.json`). The schema is passed to the
provider CLI and the script checks the result again with `jq`, including rules
a schema cannot express. For a review, the verdict must follow from the
findings: `PASS` without findings, `PASS_WITH_MINOR_FINDINGS` with only minor
or suggestion findings, and `CHANGES_REQUIRED` with at least one critical or
major finding. What a reviewer could not verify belongs in `limitations` and
does not change the verdict.

An acceptance criterion that the reviewer of the feature could not check at
all goes, in addition, into `unverified_criteria` of the result
(`feature-review.schema.json`): one entry per criterion, `{criterion,
reason}`, with the criterion as the Issue words it (or its number), and an
empty list when the review confirmed every criterion. Such a criterion is
not confirmed by the review. `finish-feature.sh` names each one in the
commit message under the heading `Not confirmed by the review:`, right
before `Merge approval:`, and `publish-feature.sh` carries the block into the
pull request. When the completion record calls the criterion `met`, the
merge needs the owner's approval, with the reason `the review could not
confirm: <criterion>`. The script finds the criterion in the record by its
text, without regard to case, spacing, a list or checkbox prefix, backticks,
or a trailing period; an entry it cannot match, such as one named by its
number, counts as met, since what cannot be matched gives no permission. A
criterion the record does not call met (`pending` at a later gate, `not
applicable`) is named but does not need the owner. A review without such
criteria, or one made before the field existed, changes nothing in the
commit message or the pull request. A criterion the reviewer checked and
found unmet is not such an entry but a finding.

The script, not the agent, numbers the findings: `C1` (critical), `M1` (major),
`MIN1` (minor), and `S1` (suggestion). Triage decisions and follow-up Issues
refer to those identifiers. When a result is invalid, the agent is asked once
more, with the reasons for the rejection.

Stored artifacts are checked with the same rules as agent results, plus the
fields the scripts own, so editing a stored artifact cannot weaken a decision.

Documents that people maintain, such as the roadmap, requirements, and
architecture, keep Markdown as their source.

### Earlier rounds and re-raised findings

Every round after the first, a review of the changes or of the complete
feature, whether `run-feature.sh` starts it or you do, gets what the approved
triages of all earlier rounds of the feature decided, under "Decisions of the
earlier rounds": per finding its round, identifier, severity, title,
decision, and rationale. The decisions come from the newest triage of each
round that is valid and approved for that round (a newer triage artifact that
is invalid does not hide it); a round without one is named without its
findings, which count as to be fixed. The reviewer does not
raise an accepted or deferred finding again unless the change made it worse.

A finding that continues an earlier one names it in `previous` (the finding
schema, `.agents/schemas/feature-review.schema.json`):

```json
"previous": {"round": 1, "id": "M1", "relation": "unresolved", "reason": ""}
```

- `unresolved`: a finding that was to be fixed (`FIX_NOW`, or never triaged)
  is not, or not fully, resolved. It keeps the title of its predecessor,
  marked only by `Unresolved: ` before it or `, unresolved` after it:
  `run-feature.sh` continues a finding by its `previous` and its title
  together, since the IDs of two rounds are given anew and an `M1` of one
  round can be another defect than the `M1` of an earlier one.
- `worsened`: an accepted or deferred finding that the change made worse;
  `reason` says how and is required. It is a legitimate re-raise and is
  triaged like any finding.

A new finding has `previous: null`; the stored review keeps the field only
when it names a finding, and a review without it is valid as before. The
field is the reviewer's declaration; the scripts check it against the
recorded decisions. `review_artifact_errors` (`scripts/lib/review-data.sh`,
used by `review-feature.sh`, `check-review.sh`, `triage-review.sh`, and
`finish-feature.sh`) makes a review invalid when `previous` names a round
that is not an earlier review of the feature, or a finding that round does
not have, when an `unresolved` finding names one that its approved triage
accepted or deferred or has another severity than its predecessor, when a
`worsened` finding names one that was to be fixed (`FIX_NOW` or never
triaged), or when a `worsened` finding has no reason. The earlier decision
and severity therefore stand: a re-raise cannot lower a blocking finding.
`review-feature.sh` then stores nothing and the round fails, as for any
invalid review. A finding to fix that is really unresolved is still reported
with its severity, and still blocks.

`triage-review.sh` shows the predecessor next to a finding, the report of
the review names it, and the run record has one `finding` event per finding
with its `previous`, so that `report-runs.sh` counts the re-raises per
feature.

### Reviewing only the changes

Every round reviews the complete feature by default, also after a fix. That
costs a full review each time, and it is what finds a problem that an earlier
round missed: a later complete round regularly reports something in code that
did not change.

A review of changes confirms fixes. It does not establish that the Issue is
done, so **a feature is committed on a review of the complete feature**:
`finish-feature.sh` refuses when the latest round reviewed only changes, and
asks for a complete round. A round of changes is for the rounds in between.

After a small fix you can limit a round to what changed since the previous
one:

```bash
./scripts/review-feature.sh 12 --changes
```

The reviewer then receives the difference between the content that the
previous round reviewed and the current content, with the findings of that
round and what an approved triage decided about each; without one, every
finding counts as to be fixed. It checks that every finding
that was to be fixed is resolved, reviews the changed lines and what they
affect, and leaves the rest of the feature alone. The review records its
scope, its report says so at the top, and the commit message of
`finish-feature.sh` names it.

Use it when the fix is small and local. Run a complete round when the fix
touches several parts, changes behaviour beyond the finding, or when you are
not sure. The script refuses `--changes` when it cannot build on the previous
round:

- there is no previous round;
- nothing changed since it;
- the base of the branch changed, for example after merging `main`, so the
  feature differs in more than your changes;
- the content that the previous round reviewed is no longer in the object
  database.

`finish-feature.sh` accepts a review of changes only as the latest round when
it builds on exactly the content of the round before it, back to a complete
review. Otherwise it asks for a complete round.

### When a review becomes stale

Every review records a fingerprint of what it reviewed (`reviewed_tree`): the
Git tree hash of the file contents at review time, including uncommitted and
untracked changes. Review and triage artifacts and ignored files are not part
of it, except files Git already tracks. A review may instead cover an explicit
list of files (`reviewed_paths`); then only those files count.

The fingerprint depends on content, not on commits. Committing the reviewed
content keeps the review current; changing, adding, or deleting a covered file
makes it stale. `apply-triage.sh` refuses a stale review before it starts an
agent. `triage-review.sh` refuses it too, unless it is a historical review (a
later round of the Issue exists and the reviewed tree is available; see
"Historical triage" under `triage-review.sh`). After `apply-triage.sh` changes the code, the
review is stale by design: run a new review round, complete or with
`--changes`, to confirm the fixes.

Check a review yourself with:

```bash
./scripts/check-review.sh .agents/reviews/feature-12-player-movement-review-01.json
```

It exits 0 when the review is current, 1 when it is stale, and 2 on an error.
Every script that refuses a stale review, and `check-review.sh`, first lists
the files that changed since the review, as added, modified, or deleted.

### Finishing a feature

When the latest review round is resolved, finish the feature from its
worktree:

```bash
./scripts/finish-feature.sh 12 "Implement player movement"
```

The script refuses another branch than `feature/12-*` or a tree without
changes, and a feature whose completion gate does not pass (see "The
completion gate"). It checks the latest review of the
feature: it must be current, cover the complete feature, and have no critical
or major finding. Every
review round with findings needs an approved triage that was published on the
Issue (the newest triage of that round counts): the workflow's comment there
names it by its SHA-256, which the script reads from GitHub and refuses the
commit without, also when the comments cannot be read; and the latest round may have
no `FIX_NOW` findings left to apply. These gates, and every other one that
needs no verification, are checked before any check runs, so a refusal costs
no verification. Only then does it verify the result with
`./scripts/verify.sh --reuse`, and it checks that the review is still current
for the verified content. After fixes, run a new review round first;
a passed newer round confirms the fixes of earlier rounds. A failed
publication can be repeated with `./scripts/triage-review.sh --publish
<triage-json>`.

It then stages all changes (review and triage files are ignored) and opens a
structured commit message in your editor: the summary, the Issue, the list of
changes, the completion statement with the evidence per criterion, the
verification, the review round and verdict, the merge approval, the risk
level with its reasons (see "The risk level of a feature"), and `Refs #12`.
Emptying the message aborts the commit and leaves the changes staged. The
script never pushes, opens a PR, or merges.

The list of changes comes from `.agents/summaries/<issue>.md`, which the
implementer writes and keeps up to date when fixes change what the feature
does: every line that starts with `- ` is taken over. Like the manual steps
it is a working file and is not committed. Without it the message has a line
for you to fill in; an unattended commit, which nobody edits, is refused.

Work that is not complete is committed only as your explicit choice:

```bash
./scripts/finish-feature.sh 12 "Add the first part of player movement" --partial
```

The completion record has to say `partial` or `blocked` itself, with what
remains: a record that says `complete` or `awaiting_evidence` passes the gate,
and `--partial` is refused for it, because the commit message is made from
the record. The commit message
carries `Completion: partial` with the criteria and what remains, and
`publish-feature.sh` opens a draft pull request that does not close the Issue.
`run-feature.sh` never uses the option.

When the project disables agent attribution (`.agents/attribution.conf`,
see "Configuring attribution"), the script refuses a feature whose commits
name an agent as a co-author, and undoes a commit whose message got
attribution in the editor; a co-author who is a person passes.

A change that `.agents/policies/autonomy.md` classifies as low risk may be
finished without an independent review; the reason is recorded in the commit
message. `./scripts/check-risk.sh` tells you the level of the feature by the
rules of `.agents/policies/risk.conf` (see "The risk level of a feature"):

```bash
./scripts/finish-feature.sh 12 "Fix a typo in the README" --no-review "documentation only"
```

When the feature needs a step that only you can do, such as a repository
setting or a secret, the implementer records it in
`.agents/manual-steps/<issue>.md`. `finish-feature.sh` shows those steps before
the commit and records them in the commit message under `Manual steps:`; the
file itself is a working file and is not committed.

Then publish the feature:

```bash
./scripts/publish-feature.sh 12
```

The script pushes the branch and opens a pull request whose description is
the commit message, one line with the triage mode of the project policy for
the risk level of the feature (`Triage mode: full` or `light`, see "What each
level requires"), the manual steps, and `Closes #12`. For a pull request
that is already open it pushes and replaces the description with the current
one, since a fix round can change the manual steps. It never merges.

`Closes #12` is written only for a complete feature: the commit carries
`Completion: complete` of `finish-feature.sh`, and the completion gate, asked
again, still passes. In every other case the pull request is opened as a
draft, refers to the Issue, and says why it does not close it: the feature
was committed as partial, the gate does not pass any more, or the commit was
made without `finish-feature.sh` and has no completion statement. A draft is
marked ready when a later publish finds the feature complete, and a pull
request that was ready goes back to a draft when the work published to it is
not complete.

GitHub closes an Issue on a closing keyword (`Closes`, `Fixes`, `Resolves`,
and their forms) next to its number, in a pull request description and in the
message of a merged commit. For work that may not close the Issue the script
therefore turns such a keyword in the text it takes over into `Refs`, and it
refuses to publish, before pushing, while a commit of the branch carries one:
reword that commit, or complete the feature.

With agent attribution disabled (`.agents/attribution.conf`), the script also
refuses to push while a commit of the branch carries an agent's
`Co-authored-by` trailer, or while the description would carry generated
attribution text such as "Generated with Claude Code"; each is reported
on its own, with where to remove it. See "Configuring attribution".

**Bringing a finished feature up to date with its base.** Update the branch
when the base branch moved on after `finish-feature.sh` and the pull request
shows a conflict or is behind its base, or when a check of the pull request
fails on something that a later merge into the base repaired. One command
does it:

```bash
./scripts/update-feature.sh 12    # --wait to stay for the checks of the pull request
```

It fetches the base of the feature (`origin/<base>`, as `start-feature.sh`
recorded it) and merges it into the branch when the branch does not contain
it yet. Staged changes in the index stop it before the merge, with the
staged paths named and the index left as it is. A merge that conflicts stops
before anything changed: the script names the conflicting files and the
commands that continue, which are to merge by hand (`git merge
origin/main`), resolve the files, commit the merge, and run the script
again; a merge left in progress is refused until it is committed. A merge
that would write over an untracked file at a path that the base adds stops
before anything changed too, also when Git ignores the file: Git refuses to
write over an untracked file, but a merge that is not a fast-forward
replaces an ignored one without a word, even with `--no-overwrite-ignore`,
which both scripts pass. The script names the paths; move each out of the
worktree, or remove it once you know it is not needed, and run again. Then
it verifies what the merge can have changed, since a review that was done
before the merge covered the feature, not the merge:

- When nothing was merged and the content is exactly that of the finish
  commit, no check runs, and the script says why: `finish-feature.sh` made
  that commit only after a pass of that content, and its message records
  the pass (`- ./scripts/verify.sh passed` under `Verification:`). The
  commit is the record here, not `.agents/verification/passed`, which an
  agent session may have written. Any other content, also a merge of an
  earlier run or a repair after it, is verified.
- Otherwise `./scripts/verify.sh` runs every check of `scripts/verify.conf`,
  and the workflow self-tests by the trigger that decides them everywhere
  else (`paths:` of `scripts/verify-workflow.conf`): when a workflow file of
  the feature differs from the base. A merge that changed a workflow file
  since the finish commit is no difference from the new base, so for it the
  script passes `--all`, and the output names the files. So does a finish
  commit that records no pass.

It reuses no recorded pass, which an agent session may have written, unless
it is given the trusted passes of a run (see "Recorded verification"); a
later step reuses its pass only where that pass covers the checks the step
requires, by the usual `--reuse` rule. Last, it publishes again
with `publish-feature.sh`. Nothing is pushed when a step fails, and running
the command again continues where it stopped. The same steps by hand are
`git merge origin/main`, `./scripts/verify.sh` (with `--all` when the merge
changed a workflow file), and `./scripts/publish-feature.sh 12`.

A merge of the base can leave untracked files behind: a directory that Git
ignored on the branch, such as the build directory of a site that the base
renamed, is no longer ignored once the base's `.gitignore` arrives. Such a
path is no work of the feature. Both scripts recognize it, as an untracked
path that the ignore rules of the finish commit ignored and that Git does
not ignore now, and report it with its path and the command that removes it
(`rm -rf -- <path>`); nothing deletes it for you. `publish-feature.sh` does
not count it as uncommitted work and publishes. `update-feature.sh` stops
until it is removed, because the verification would count it as content of
the feature. Any other untracked or changed file is uncommitted work, and
both refuse it.

`publish-feature.sh` takes the statement, the description, and the title from the
commit that `finish-feature.sh` made: merge commits of the base after it are
passed over, since they change nothing of the feature itself. So is a commit
after such a merge that fixes what the merge broke, such as a link to a page
the base moved, when it changes only files that the merges of the base
changed since the finish, none that the feature changed up to the finish
(what the review covered), and no protected path, and the finish commit has
no approval request (it names the content of exactly that commit). Any other
commit after the finish has no statement, and the pull request becomes a
draft until the feature is finished again; its description names the commit
that stands in the way and what to do: undo it into the working tree, review
it, and finish again. The owner's exceptions of the finish commit are
judged against its content too, so they survive the merge of the base; with
any other commit after the finish they are refused and nothing is pushed.

What the owner's approval of a protected change means after a merge of the
base: the description still says that the merge approval was decided for the
finish commit, and names its content tree and the approval request it
carries. The content the review and the approval request cover is unchanged;
the merge commit is passed over, so a pure merge of the base needs no new
finish and no new approval request. The owner approves the pull request on
GitHub as before, after the update, and the checks of the pull request run
on the merged branch.

GitHub's "Re-run" of a failed check on the pull request runs it again on the
same merge of the branch with its base that the first run used: a fix that
was merged into the base since then is not in it. Update the branch instead,
and the checks run on the new head.

**During an unattended run.** `run-feature.sh` asks the same question before
it hands a failing verification to the implementer. When checks failed in
two verification runs and the base moved since the feature started, it
fetches the base and merges it into the branch when that merges cleanly,
with the commits of the branch and with the uncommitted work of the feature,
notes `base merged` in the log of the feature, and does the step again on
the merged content; only a check that still fails goes to the implementer.
Staged changes in the index stop the run before the merge, with the staged
paths named: Git refuses a merge with staged changes, and unstaging them
would lose a staged version that differs from the file on disk, so the run
leaves the index as it is. Unstage them (`git restore --staged <path>`) when
the file on disk holds what you want, and run again. A merge that would
conflict stops the run before anything changed, with the conflicting files
and the commands that continue: put the uncommitted work aside (`git stash
push --include-untracked`), merge, resolve and commit, take the work back
(`git stash pop`), and run again. A merge that leaves untracked paths
behind, as above, stops the run with their paths and removal commands too,
and so does a merge that would write over an untracked file, ignored ones
included, before anything is merged.

The script ends once the pull request is open and prints its address. Follow
the checks there and merge after they passed. Local verification during a
feature never runs on a clean checkout, and may run on another operating
system than CI, so a failure can appear in CI only; a pull request must not be
merged while a check fails.

- When the base branch requires a passing status check, through a ruleset or
  branch protection, GitHub refuses that merge, and the script says so.
- When it does not, the script warns: nothing but your own look at the checks
  stops the merge. `docs/repository-setup.md` describes how to add the rule,
  and `./scripts/doctor.sh` reports a `main` without one.

`--wait` keeps the script running until the checks finish, to have the result
in the terminal: all checks passed, or a non-zero exit and the advice not to
merge when one failed. After a failed check, fix the cause in the worktree,
then review, finish, and publish again.

After a merge into the default branch GitHub closes the linked Issue. From
the primary checkout, remove the merged worktree and its branch:

```bash
./scripts/cleanup-worktree.sh 12
```

The script asks GitHub whether the branch's pull request is merged, so it also
works after a squash merge. A branch counts as merged when its tip is the head
of the merged pull request or an ancestor of it: after "Update branch" on the
pull request, or a push from another checkout, the branch on GitHub is ahead
of the local one, and the local branch still holds nothing that was not
merged. A merged head that is not in the local repository is fetched from the
pull request first; when that fails, the worktree is kept and the script says
why. It refuses an unmerged worktree, a branch with a local commit that the
merged pull request does not contain, and a worktree with uncommitted changes;
ignored review and triage files do not count. After removing the worktree and
the local branch it fast-forwards `main` when the primary checkout is on `main`
without modified tracked files; untracked files do not prevent that. After a
merged planning it also removes an untracked file in the primary checkout that
is identical to `docs/PROJECT_DESCRIPTION.md`, such as the original idea file. A planning worktree is cleaned with
`./scripts/cleanup-worktree.sh planning/<name>`, every merged worktree at once
with `--merged`, and an abandoned, unmerged one with `--discard` after
confirmation.

After a merge into a base that is not the default branch, GitHub leaves the
Issue open. Once the script has confirmed the merge as above, it closes the
Issue itself when the pull request says `Closes #<issue>` and lists no
pending `post_merge` criterion, after a comment that names the pull request
and the merge commit. A pull request that does not close its Issue, an Issue
that is closed already, and a merge into the default branch, which GitHub
handled, change nothing; an Issue with pending `post_merge` evidence stays
open until `record-post-merge.sh` has recorded it. When GitHub cannot say
which branch is the default, the script closes nothing, warns, and still
removes the worktree.

### Running feature steps without questions

The steps of a feature that ask you something, or that start an agent in your
terminal, accept `--unattended`. The step then asks nothing and ends by
itself, so a script can run one step after the other.

| Step | With `--unattended` |
|---|---|
| `start-feature.sh <issue> [--resume]` | The implementer runs with the `unattended` profile instead of in your terminal. Its final message is stored in `.agents/run/<issue>-implementer.md` in the feature worktree and shown. |
| `triage-review.sh <review-json>` | The proposed triage is approved without a question (not for `--decisions`, which is refused). The proposal is validated as always: a critical or major finding cannot be deferred or accepted. |
| `apply-triage.sh <triage-json>` | The fixes start without confirmation, with the `unattended` profile. The final message is stored in `.agents/run/<issue>-fixes.md` and shown. |
| `finish-feature.sh <issue> "<summary>"` | The commit message is used as it is, without an editor. Without a summary of the changes the commit is refused: nobody would write one. |

`review-feature.sh` and `publish-feature.sh` ask nothing as they are. The
planning is yours to decide: its steps refuse the option.

The option needs the working files to be ignored by Git, as the template's
`.gitignore` does with `.agents/run/`, `.agents/summaries/`, and
`.agents/completion/`; a step stops
when they are not. A project that was created from an earlier version of the
template gets the rules with `./scripts/sync-template.sh`.

An unattended agent cannot ask you anything. It is told to stop when it
needs a decision of yours, or when the work conflicts with the Issue's scope,
the architecture, or an ADR: it then records the question in the handoff note
and ends its final message with a line `BLOCKED: <reason>`. The step shows
the reason and exits with status 3, which it uses for nothing else, so a
blocked session can be told apart from a failed one. Answer in the handoff note or change the Issue, and
continue with `./scripts/start-feature.sh <issue> --resume`.

`BLOCKED` is only for a decision. The agent is told not to use it when its
own run of `./scripts/verify.sh` fails on something outside its work, does not
finish within the session, or cannot run on the machine: it reports that in
its final message and ends normally. The step that follows verifies the
result itself: `review-feature.sh` and `apply-triage.sh` exit with status 4
when the verification fails, apart from every other failure, and
`run-feature.sh` repeats and repairs it as described under "Running a feature
with one command". Common causes on your side are a tool that
is not in the `PATH` of the terminal you started from, and a verification
that takes longer than one command of an agent session may.

A triage that was approved this way says so: the artifact has
`"unattended": true`, and the report and the comment on the Issue state that
no human approved the decisions. Deferred findings still become follow-up
Issues, and accepted findings keep their rationale, so you can read
afterwards what was decided without you.

The files in `.agents/run/` are working files, ignored by Git. An unattended
Codex session also writes, next to its final message, its events, one JSON
object per line, with `.events` added to the name, and what it writes on
standard error, with `.log` added; the end of both is shown when the session
fails, and the run records read the token usage from the events.

### Running a feature with one command

`run-feature.sh` runs the steps of a feature one after the other, from the
implementation to the open pull request, without asking anything:

```bash
./scripts/run-feature.sh 12
```

```text
./scripts/run-feature.sh <issue> [slug] [base-branch] [--implemented] [--risk <level>] [--rounds <m>]
./scripts/run-feature.sh <issue> --owner-finding [--risk <level>] [--rounds <m>]
```

From the primary checkout it runs:

1. `start-feature.sh <issue> [slug] [base-branch] --unattended`: the worktree
   and the implementation. The run goes on only when the completion gate
   passes and the implementer wrote the summary of the changes. Otherwise it
   resumes the implementer, with the reasons in the handoff note, for at most
   four sessions in a run (`RUN_FEATURE_SESSIONS`).
2. `review-feature.sh`, and for a review with findings `triage-review.sh
   --unattended` and, when the triage has `FIX_NOW` findings,
   `apply-triage.sh --unattended`, followed by the next review round. This
   repeats until a review of the complete feature has no findings or its
   triage has nothing to fix: a round whose findings were all deferred or
   accepted ends without a fix session, in every triage mode of the policy
   (see "Light triage" under "What each level requires").
3. `finish-feature.sh --unattended`, with the title of the Issue as the
   summary of the commit, and `publish-feature.sh`.

It uses at most five review rounds; `--rounds <m>` raises the limit for one
run (below). The first round reviews the complete
feature; a round after fixes reviews only what changed since the round before
it (`review-feature.sh --changes`). Every round after the first knows what
the approved triages of all earlier rounds decided, so a finding that was
deferred or accepted is not reported, triaged, and turned into a follow-up
Issue again in every round (see "Earlier rounds and re-raised findings").
The round that ends the run reviews the complete feature again, against the
Issue and the completion record: a feature with one fix round therefore has
three reviews, the complete feature, the fix, and the complete feature.
When the base of the branch changed between two rounds, for example because
you merged `main` into it while the run was stopped, the next round reviews
the complete feature; so does a round after the risk level of the feature
rose, or when the risk policy requires complete reviews for the level. What
the rounds require per level is described under "What each level requires";
with the policy the template ships, the rounds are as described here.
The agents and models are those of the roles in `.agents/agents.conf`.

What stays with you: choosing the feature and creating its Issue, reading the
pull request, following its checks, merging, and `cleanup-worktree.sh`. The
run never merges, never pushes to `main`, and never removes a worktree.

The run decides the outcome of every step itself, from exit statuses and from
the result of the checks. What an agent writes decides one outcome only, and
only together with what it recorded:

| Outcome | How the run establishes it | What it does |
|---|---|---|
| Completed | The step exits 0 | Goes on |
| Temporary | A step fails on a known transient error in the last lines of its output (`github_transient_error` in `scripts/lib/github.sh`, the list `start-feature.sh` also reads the Issue with: a timeout, a reset or refused connection, a host that cannot be resolved, an unreachable network, a server error, an overloaded service), or an agent reports a usage limit | A known transient error: tries the step again once, after 30 seconds. A usage limit: tries the step again three times, with a wait of four times that, doubling each time, since a limit can last several minutes. Any other failure of a step, also a non-zero exit of an agent, is not tried again: the run stops, and a transient error that the list misses is yours to restart. A fix session that had already changed the content is taken up with `apply-triage.sh <triage-json> --continue`: the same findings, contract, and protections, for the session of this triage that was left unfinished, and for nothing else |
| Unstable check | The verification is repeated once, only the checks that failed (`verify.sh --repeat`, see "The repeat of only the failed checks"; every check when the two runs cannot be combined), and no check failed in both runs | Records the checks, and what the repeat ran, and goes on, at most three times in a run |
| Missing prerequisite | A step ends with status 78, or failed with an `ENVIRONMENT` line of the preflight of `verify.sh` in its output (see "Missing prerequisites") | Stops with status 78: no retry, no repeat of the verification, no repair session, and never an unstable check. Notes `environment` with what is missing |
| Base moved | A check failed in both runs, and the base moved since the feature started and merges cleanly | Merges the base into the branch, notes `base merged`, and does the step again on the merged content, without a session of the implementer; see "Bringing a finished feature up to date with its base" |
| Failed verification | A check failed in both runs, and the base did not move | Resumes the implementer with those checks in the handoff note, at most three times (`AGENTS.md`); a review follows. A repair session is retried like any other |
| Budget exceeded | The verification passed, and a budget check (`<name> [<group>] budget: <command>`, see "Budgets") exceeded its target | Goes on: no repair session, whatever the measurement. The measurement is in the summary of the verification, in the output of the run, and in its `verification` event of the run record; the handoff note, the reviewer's context, the commit message, and the pull request do not repeat it (see "Budgets") |
| Blocked | An agent ends with `BLOCKED:` and the handoff note holds a question under "Open questions", or the completion record says `blocked` | Stops with status 3. Without such a question there is nothing to answer: the line is ignored and the run goes on |
| Not complete | The implementer ended normally, but the completion gate does not pass: no record, an invalid one, `partial` with what remains, or no summary of the changes | Resumes the implementer with the reasons in the handoff note, at most four sessions in a run. Nothing is reviewed or committed before the gate passes |

Every interruption is written to `.agents/run/<issue>-log` in the feature
worktree, one line each: the time, the step, the outcome, the reason, and
what the run did. The output of the last step is kept next to it in
`<issue>-step.log`, and that of a repeated verification in
`<issue>-verify.log`. Status 4 is kept for a failed verification: the scripts
turn an agent that happens to exit with it into an ordinary failure. `RUN_FEATURE_RETRIES` (the retries of a usage limit; 0 tries nothing again),
`RUN_FEATURE_RETRY_WAIT` (the wait in seconds before the retry of a transient
error, and a quarter of the first wait after a usage limit; the self-tests set
it to 0), and `RUN_FEATURE_REPAIRS` change the limits for one run;
`RUN_FEATURE_ROUNDS_CEILING` can only lower the ceiling of 20 for `--rounds`
(the self-tests use it to reach the ceiling without twenty rounds).

The run stops with a non-zero status, and keeps the worktree, when:

| Stop | Status |
|---|---|
| An agent needs a decision of yours, or reports a conflict with the Issue's scope, the architecture, or an ADR. Its question is in the handoff note | 3 |
| A step fails without a known transient error or a usage limit, or still fails after its retries | 1 |
| The verification still fails after three repairs, or checks are unstable more than three times | 1 |
| A prerequisite of the machine is missing (status 78 of `verify.sh`, its `ENVIRONMENT` lines); install it, then run again | 78 |
| The verification fails, the base moved, and its merge conflicts with the branch or the uncommitted work of the feature, would write over an untracked file (also one that Git ignores), meets staged changes in the index, or leaves untracked paths behind that the branch ignored; the files are named | 1 |
| The proposed triage is invalid, for example because it defers a critical or major finding | 1 |
| Five rounds (or the limit of `--rounds`) are used and the last one still has a finding that must be fixed, or was an intermediate round (only the changes); the stop proposes `--rounds` with two rounds more, or, at the ceiling of 20, says that it is reached and proposes only the steps by hand | 1 |
| The implementer ended four sessions without completing the Issue | 1 |
| The completion record says `blocked` | 3 |
| The implementer refuted every finding left to fix, one of them critical or major, with evidence, and the review of the complete feature still reports it; the findings and the ways on are named | 3 |
| The fixes changed nothing, the commit is refused, or the pull request cannot be opened after the retries | 1 |
| A step of the review rounds succeeded without the change it is run for, and the run would start it again for the same round: a review that left no current review, a triage that stored none, fixes after which the review is still current. The stop names the step, the round, and what is missing. A publication of the triage is started at most once per triage in a run: when the comments of the Issue still do not show it afterwards, the run stops and says so. | 1 |

It then says why it stopped and which command resolves it. After that, run
the same command again: `./scripts/run-feature.sh <issue>`. The run reads
where the feature stands from the worktree, so every step that is done is
skipped: a current review is not repeated, a stored triage is not made again,
and a committed feature is only published. The one thing it records itself is
that the completion gate passed, in `.agents/run/<issue>-state`. As long
as that is missing, the next run resumes the implementer, as
`start-feature.sh <issue> --resume` does. The same happens after a fixing
agent stopped for a decision of yours: the implementer reads your answer in
the handoff note and continues, and a review follows. When you completed the
implementation in a session of your own, say so with `--implemented`, and the
run continues with the review without a session of the implementer; the
completion gate has to pass for that too, so write the completion record and
the summary first. You can also take over by hand at any point:
the single scripts work on the same files.

When a run stops because its five review rounds are used, continue it with a
higher limit instead of the steps by hand: `./scripts/run-feature.sh <issue>
--rounds <m>`, with `<m>` above five and at most 20; the stop proposes two
rounds more, up to 20. At a limit of 20 the ceiling is reached: the stop
proposes no `--rounds` and says so, and you continue by hand with the steps
it names. It is your decision and only yours: the run refuses the option
in an agent session (`CODEYARD_AGENT_SESSION`) and when standard input is not
a terminal, so it never runs unattended, and the run record notes it as an
intervention. Every other rule of the rounds stays as it is: the run ends on
a review of the complete feature on the full verification.

Know what you hand over before you use it:

- An unattended agent runs commands on your machine while nobody watches.
  Codex stays inside its workspace sandbox; Claude decides with its own
  permission check. Neither gets the tools of your configuration. See
  "Configuring agents".
- Nobody approves the triage. The validation still refuses to defer or
  accept a critical or major finding, but a minor finding or a suggestion
  can be accepted or deferred wrongly. You see that in the pull request and
  on the Issue, where every finding is published with its decision, instead
  of before the fixes. Read that record before you merge.
- The completion record is the implementer's own claim. The run acts on its
  status; whether the claim holds is judged by the reviewer of the complete
  feature, and by you in the pull request, where the commit message lists
  every criterion with its evidence.
- Up to four implementer sessions and up to five review rounds, each with a
  triage and a fix session, use the
  usage limits of your agents without a moment at which you can stop them.
- The commit message is not edited: its summary is the title of the Issue
  and its list of changes is what the implementer wrote.

#### An owner finding on an open pull request

When you find something wrong in a feature whose pull request is open, post
the finding as a comment on the Issue and run:

```bash
./scripts/run-feature.sh 12 --owner-finding
```

It takes the finding through the steps of a run, in this one process, so the
pass of the fixed content is reused by the commit (see "Recorded
verification"); the trust list stays in the process, and no agent gets it:

1. It starts only on a finished feature, one with a commit of
   `finish-feature.sh` on the branch; otherwise it stops before any session.
2. It merges the base when it moved since the finish, as a run does for a
   failed verification: a conflict, staged changes, or an untracked file
   that the merge would write over stop it before anything is merged, with
   the files named.
3. It reviews the complete feature when one of your comments on the Issue
   (the comments an agent is given, see "Comments on the Issue") was written
   or edited after the latest review and the finish commit. The reviewer
   gets the comment with the Issue. Without such a comment nothing is
   reviewed again unless the content changed since the finish, and the run
   says so.
4. The rounds follow as in a run: triage, fixes, the run's own full
   verification, and a review, every round of the complete feature, until a
   review leaves nothing to fix. A feature with one fix round has two
   reviews and two full verifications, one of the merged and one of the
   fixed content; the commit reuses the second.
5. `finish-feature.sh` commits the fixes as a new finish commit on top of the
   published one, with its own approval request when the merge needs you,
   and `publish-feature.sh` pushes it. The push is a fast-forward of the
   published branch, and the approval request covers the commit that is
   pushed: no `git reset` and no forced push. When the review leaves nothing
   to fix, nothing is committed, and a merge of the base is published.

The round limit counts the rounds of this chain, after the round the finish
commit was made on (`Review: round <n>` in its message), and `--rounds <m>`
raises it as for any run. It stops for you where a run stops: an agent that
needs your decision, a finding that is refuted with evidence, used rounds, or
a step that keeps failing; the stop names the command that continues,
with `--owner-finding`. Running it again continues where it stopped: a
review of the chain that a stop left before its triage or fixes is triaged
and fixed, also when it is newer than your comment and nothing changed; once
the chain's fixes are committed, it only publishes.

The same steps by hand, for one of them on its own:
`./scripts/update-feature.sh <issue>` (or `git merge origin/<base>`),
`./scripts/review-feature.sh <issue>`, `./scripts/triage-review.sh
<review-json> --unattended` and `--publish <triage-json>`,
`./scripts/apply-triage.sh <triage-json>`, `./scripts/review-feature.sh
<issue>`, `./scripts/finish-feature.sh <issue> "<summary>"`, and
`./scripts/publish-feature.sh <issue>`. Each of them verifies on its own when
it runs outside a run. Commit a fix only with `finish-feature.sh`: a commit
of your own after the finish is not covered by its approval request.

### The overview of every feature

`./scripts/status.sh` shows where every feature stands, one row for each
feature that has a worktree or an open pull request, from any checkout:

```bash
./scripts/status.sh              # in the terminal
./scripts/status.sh --markdown   # a table that renders on GitHub
./scripts/status.sh --changes    # only what changed since the last --changes
```

The columns:

- **Issue** and its title.
- **Phase** of the latest run of the feature: `implementing`, `verifying`,
  `review round <n> of <m>`, `triage of round <n>`, `fixing, round <n>`,
  `committing`, `publishing`, `published` or `finished` when the run ended
  well, `stopped (<phase>)`, `interrupted (<phase>)` for a run that has no
  recorded end and whose process is gone, and `merged`.
- **Exit**: the exit status of that run when it stopped (1, 3, 78, or 130;
  see `docs/workflow.md`).
- **Verification**: the last full verification of the feature, whether it
  passed, and whether it counts as trusted evidence, with its origin
  (`orchestrator`, `script`, `agent-session`, `manual`; see "Recorded
  verification").
- **Pull request**: its number, its CI checks (`checks pass`, `checks fail
  (<n> of <m>)`, `checks pending`, `no checks`), and whether it is
  `mergeable` or `conflicting`.
- **Owner decision needed**: what only you can do now, with the command or
  the link that does it, and empty when nothing is needed. A run that stopped
  for your decision (status 3) or a blocked completion record: the question
  that its handoff note holds under "Open questions", to answer in
  `.agents/handoffs/<issue>.md`. A pull request with an approval
  request (`.agents/approval-requests/<issue>.json`) at the head commit of
  the pull request that you have not approved. Review rounds that are used
  up: `--rounds <m>` or an exception. A conflict with the base:
  `./scripts/update-feature.sh <issue>`. Failing checks, or no checks at
  all. A review that requests changes, or an approving review that GitHub
  still requires (`REVIEW_REQUIRED`). A pull request that is ready: merge
  it, offered only when its checks exist and pass, no review requests
  changes, no required review is missing, and the approval request is read
  at the pull request's own head and is approved or absent. A head that is neither in this repository nor
  readable on GitHub makes the need for your approval unknown, which the
  column says, and no merge is offered: a missing or outdated branch here is
  not taken for a head without an approval request. A merged feature with a
  `post_merge` criterion whose evidence is not recorded on the Issue yet:
  `./scripts/record-post-merge.sh`. Any other stop, with its reason and the
  command that continues.

Nothing in the overview is a status of its own. The phase, the exit status,
and the verification come from the run records (see "Run records"), the
implementer's state from the completion gate, the pull request from GitHub
with `gh`, and the need for your approval from the approval request. Every
open pull request is read, however many there are: a query that fills its
limit is repeated with a larger one. A run is
running while its record has no end and the process in its run id lives;
the records are on this machine, so a run on another machine is not seen. A
verification you start by hand is shown, but does not change the phase.

#### Notified on change

`--changes` compares with the previous overview, kept in `.agents/status/` of
the primary checkout, which Git ignores. It prints nothing when nothing
changed; otherwise the rows that changed, the features that are no longer
listed, and under "New owner decisions:" every decision that is new. Without
GitHub it fails and keeps the previous overview, so that no change is
reported that did not happen. One `--changes` runs at a time: it holds the
lock `.agents/status/lock` from reading the previous overview to keeping
the new one, so a run by hand and a scheduled one do not report the same
change twice. Another run waits up to five minutes (`STATUS_LOCK_WAIT`
seconds), then fails and changes nothing; a lock whose process is gone is
taken over, and so is one without an owner (a run killed while taking it)
once it is older than a minute. The run that creates the lock's `owner` file
holds it, with an exclusive create of the shell, so that the lock holds also
with a `mkdir` that is not atomic (that of uutils coreutils, the default of
Ubuntu from 25.10); a run removes only the lock that names it.

To be told, name a command in `.agents/notify.conf` of the primary checkout:
one line `command: <shell command>`. It gets exactly the output of
`--changes` on standard input, and only when something changed. The file the
template ships holds examples. When the command fails, `--changes` says so
and exits 1, and the previous overview is not replaced: the next `--changes`
reports the same changes again. A notification that reaches you is the
setup to have: without it, a run that waits for you waits until you look.

```text
# .agents/notify.conf
command: gh issue comment <tracking-issue> --body-file -
# command: osascript -e "display notification \"$(head -c 200)\" with title \"Features\""
# command: mail -s "Feature status" you@example.com
```

Run it by hand, after each `run-feature.sh`
(`./scripts/run-feature.sh 12; ./scripts/status.sh --changes`), or on a
schedule. With cron, every ten minutes; the log is in `.agents/status/`,
which is created first, as a fresh checkout does not have it:

```text
*/10 * * * * cd /path/to/project && mkdir -p .agents/status && ./scripts/status.sh --changes >/dev/null 2>>.agents/status/cron.log
```

With launchd on macOS, `~/Library/LaunchAgents/local.feature-status.plist`,
loaded with `launchctl load ~/Library/LaunchAgents/local.feature-status.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.feature-status</string>
  <key>WorkingDirectory</key><string>/path/to/project</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>-lc</string><string>./scripts/status.sh --changes</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardErrorPath</key><string>/tmp/feature-status.log</string>
</dict>
</plist>
```

A scheduler starts with a short `PATH`: `gh` and `jq` must be on it, and `gh`
must be logged in for that user.

### The merge approval gate

A feature may update the architecture and add an ADR, and in an unattended
run nobody reads a pull request before it could be merged. The gate decides
which pull requests only you may merge. It rests on what the diff contains;
the judgement of a model is a second line, never the only one.

| Source | What it looks at | Who decides |
|---|---|---|
| Rules on the diff | ADRs, protected and sensitive paths, the verification configuration | `scripts/check-guardrails.sh` |
| Independent review | The impact of the whole feature on the architecture | The reviewer, in `architecture_impact` of its result |

The heaviest of the two decides. Your approval is needed when the diff
changes a protected path, when the reviewer classifies the impact as `major`
or `breaking`, or when there is no valid classification, as for a feature
finished with `--no-review`.

**The rules on the diff.** Always protected, in every project:

- every ADR in `docs/decisions/` that is added, changed, or removed. A new
  ADR can replace an accepted one without touching its file, so no ADR passes
  without you. A feature writes a new ADR with the status `Proposed`;
- the CI workflows, the project's CI setup under `.github/actions/` (see
  "The project's CI setup"), the project's policy overrides under
  `.agents/policy-overrides/` (see "The project's policy override"), and the
  configuration, scripts, prompts, and schemas that carry out the gate;
- in `scripts/verify.conf` and `scripts/verify-workflow.conf`: a changed or
  removed line, which includes a check made a budget, a budget made a check,
  and a changed target (see "Budgets"), and an added `accepted-failure:`
  line, which lets the verification pass while a check fails (see "The
  baseline of an adopted project"). An added check is sensitive;
- `.agents/verification-baseline`, the baseline of an adopted project,
  and a recorded list of accepted failures in `.agents/accepted-failures/`
  ("Scoping an accepted failure"), when it is added, changed, or removed.

What is fundamental in your project you list in
`.agents/policies/guardrails.conf`, as Git pathspecs:

```text
protected: site/_quarto.yml .github/CODEOWNERS deploy
sensitive: docs/architecture.md pyproject.toml
```

A protected path needs your approval. A sensitive path does not: it is named
to the reviewer, who has to look at it. Keep the protected list short, or
every feature waits for you.

The rules are always read from the base branch as it is now, never from the
feature itself, so a feature cannot relax the rules it is checked by; a
change to them is protected. Locally the rules of your base branch and of
`origin/<base>` both apply, whichever is behind; the script does not fetch,
and CI checks every pull request against the base on GitHub.

```bash
./scripts/check-guardrails.sh                      # this worktree against its base
./scripts/check-guardrails.sh --commits main HEAD  # two commits
```

**The reviewer's classification.** A feature review must return
`architecture_impact`: `none`, `minor`, `major`, or `breaking`, with a
rationale and the ADRs and rules it was checked against. The implementer does
not classify its own change. A review without a valid classification is
rejected.

**What happens.** `finish-feature.sh` records the decision and its reasons in
the commit message, under `Merge approval:`, and `publish-feature.sh` in the
pull request. A feature that needs your approval still gets its pull request;
`run-feature.sh` ends with `MERGE APPROVAL REQUIRED`. No script merges a pull
request, and an agent or a queue that merges for you must skip one that says
`required from the project owner`.

**In CI.** The workflow `Guardrails` runs the gate on the actual diff of every
pull request, with the script and the rules of the base branch and without
running code of the pull request, and reports the decision as the check
`guardrails` (`scripts/gate-pull-request.sh`): success when nothing is
protected and the pull request carries no approval request; "Owner approval
required", the conclusion `action_required` and not a failure, when it
carries an approval request that names its content tree, whether for a
protected path or for another reason of `finish-feature.sh` (a major impact
on the architecture, a skipped review), and also for a protected change
without a request, which comes from a pull request made by hand such as a
project's setup; a failure when a request is refused or the gate could
not run. A feature of the workflow never goes out without its request:
`publish-feature.sh` pushes nothing while the branch changes a protected
path and its finish commit carries no request. What the check shows, and whether to require it, is
in [`docs/repository-setup.md`](repository-setup.md).

**Your approval is your own merge.** You merge the commit you see, so an
approval never carries over to content that changed afterwards. This is an
agreement that the scripts and agents keep, not a lock: the agent works with
your GitHub account and could do what you can do. A lock needs a separate
identity for the agent, with code owners and required reviews on GitHub.

**Three things, kept apart.** What was verified and reviewed, what you are
asked to approve, and the approval itself are three different things, and
no file stands in for another:

| Role | What it is | Where |
|---|---|---|
| The content tree | What was verified and reviewed: the Git tree hash of the content without the workflow's metadata under `.agents/` | Computed by `scripts/lib/fingerprint.sh`; printed by `finish-feature.sh` and `publish-feature.sh` next to the commit SHA, and in the commit message under `Merge approval:`; recomputed by `check-guardrails.sh` |
| The approval request | What you are asked to approve, and why: references and an explanation, nothing else | `.agents/approval-requests/<issue>.json`, written by `finish-feature.sh` when the gate requires you, committed with the feature, constrained by `.agents/schemas/approval-request.schema.json` |
| The approval | Your review of the pull request on GitHub, which GitHub binds to the commit | GitHub, and only there |

The content tree is one value: `finish-feature.sh` computes it from the
working tree before the commit, prints it as the content tree next to the
commit SHA, writes it into the request as `content_tree`, and checks after
the commit that the commit holds exactly that content. `publish-feature.sh`
computes it again from the finish commit and puts it into the pull request,
next to the commit SHA, labelled as the content tree. The reviewer gets it in
the review context, and gets the request of the feature, when there is one,
as a section of that context with the content tree it names, like the
completion record and the handoff note: the diff the reviewer sees shows no
change in `.agents/approval-requests/`, neither the feature's own request nor
a request of an earlier feature that the base already has, since the content
fingerprint leaves the directory out. No other fingerprint is printed in the
same statement:
the `reviewed_tree` of a review artifact is a different value, since it also
covers the completion record and the handoff note (see "What does not change
the fingerprint"), and comparing the two was a recurring false finding in
Physics by Construction.

The request asks and records. It grants nothing and changes nothing: no
script reads it for anything but display, and the one check that reads a
field, `check-guardrails.sh`, can only refuse it. The check recomputes the
content tree from the commit it checks, with the exclusion list of
`scripts/lib/fingerprint.sh` and the schema as the base branch has them, and
refuses a request whose `content_tree` differs, that has a field the schema
does not name, or that is not named `<issue>.json`; it exits 4 then, and CI
runs it on every pull request with the script of the base. A merge of the
base into a finished feature is passed over, as `publish-feature.sh` passes
it over: the request names the finish commit. Any other commit after the
finish needs a new finish, which rewrites the request, or removes it when
the gate no longer requires you. The request is never executed and is never
an instruction for an agent, as the prompts of the implementer and the
reviewer say.

The authority of the approval stays with #99: today the request records who
is asked and why, and the approval is bound to the commit by GitHub, not to a
trusted owner identity. Until #99 provides that identity, `finish-feature.sh`
and `publish-feature.sh` require your approval in exactly the cases they
did before, and nothing an agent can write counts as it.

### The risk level of a feature

Every feature has a risk level, `low`, `medium`, or `high`, computed from one
policy: `.agents/policies/risk.conf`, with the project's own choices in a
`risk.conf` in `.agents/policy-overrides/` ("The project's policy override").
`.agents/policies/autonomy.md` says in prose what the levels mean and refers
to the file as the one source of the rules. The level is computed, recorded with the feature, and read by the
workflow; the same policy says what each level requires of the review rounds
("What each level requires" below). The shipped policy changes nothing for a
project until it adds its own classes or requirements.

**The policy.** One `<key>: <value> [<value>...]` per line, with Git pathspecs:

```text
default: medium
high: docs/decisions .github/workflows .agents/policies .agents/prompts/reviewer.md ...
tests: tests test
test-fixtures: tests/lib-fakes.sh
```

| Key | Meaning |
|---|---|
| `low`, `medium`, `high` | The path classes. The highest class of any path the feature changed is its path-based minimum; a path in two classes gets the higher one |
| `default` | The level of a path that no class names |
| `tests` | The test files. A removed or changed line of an existing one, or a removed one, escalates to `high`; a diff that only adds lines does not. Without the key, `tests test` |
| `test-fixtures` | The shared test libraries (a conftest, fixtures, helpers). Any change under them, also an added line or a new file, escalates to `high`. Without the key, `tests/lib-fakes.sh` |
| `manifests` | The dependency and toolchain manifests. A change to an existing one escalates to `high` |
| `profile` | The workflow profile, `light` or `standard`: a named preset of the other keys (see "Workflow profiles" below). Without the key, none |

The template ships the file with `default: medium`, the paths that the merge
approval gate protects as the `high` class (the ADRs, the CI workflows and
the project's CI setup under `.github/actions/`, the project's policy overrides under `.agents/policy-overrides/`, the scripts, prompts, schemas, and configuration of the gate, and the two
verification configurations), and no `low` class: with it, every feature is
`medium` or `high`, which is the behaviour of today, and of a project whose
base has no file at all. A project adds its classes, in its policy override
("The project's policy override"). For a web application, for example:

```text
default: medium
low: docs :(glob)**/*.md
high: src/auth src/permissions db/migrations infra deploy
manifests: package.json package-lock.json pyproject.toml uv.lock Dockerfile
```

Then a documentation-only feature is `low`, a feature that also changes a
module under `src/` is `medium`, and one that touches authentication,
authorization, a migration, the infrastructure, or a dependency file is
`high`.

**The computation.** The effective level is the highest of three sources:

1. the path-based minimum, by the classes and the default of the policy on
   the diff of the feature: from where it left its base, with uncommitted and
   untracked files, as the merge approval gate computes it;
2. the fixed escalations to `high`, which no policy turns off: a changed or
   removed line in `scripts/verify.conf` or `scripts/verify-workflow.conf`;
   a removed or changed line of an existing test file, or a removed test
   file, which is how an existing test is weakened (an assertion, a skip, an
   acceptance threshold, test collection); any change under the shared test
   fixtures (`test-fixtures`), also an added line or a new file, since a
   shared library of the tests can change every test; a change to an
   existing file under
   `.agents/policies/`, `.agents/prompts/`, or `.agents/schemas/`, the policy
   itself among them; any change under `.agents/policy-overrides/`, also an
   added file ("The project's policy override"); a change to an existing
   file of a project skill under
   `.agents/project-skills/` ("Project skills"), which is agent instruction
   like a contract; and a change to an existing manifest the policy names.
   Apart from the test fixtures and the policy overrides, an escalation
   reads only changed or removed existing lines and files, never their
   content: a file the feature adds,
   and the lines of a new file, never escalate by themselves, whatever they
   hold, and a protected path
   keeps its `high` class by the path rule. The template ships no detector of
   content patterns (tolerances, test markers, assertions);

   Why additions to a test file do not count: appending a case to an
   existing test file is the most common change of a feature and weakens
   nothing, and when it escalated, nearly every feature was `high`, so the
   distinction between `medium` and `high` hardly applied. A test is weakened
   by what a diff removes or changes, which the rule reads mechanically from
   the `-` lines of the diff (a binary file, a change of the type, and a
   change of the mode alone count as changed); a line added to a shared
   fixture is the exception the `test-fixtures` key names;
3. what the agents recorded: `"risk": "<level>"` in the implementer's
   completion record, and the reviewer's `architecture_impact`, of which
   `major` and `breaking` count as `high`; and the owner's hint (below).

An agent or a hint can raise the level, never lower it: a recorded level or
a hint below the computed one is ignored and reported, and `finish-feature.sh` refuses a
completion record that claims less than the diff shows. A record without
`risk`, as every record written before the level existed, claims nothing and
is never refused: a feature that was already in progress gets its level
derived, recorded, and shown like any other. The rules are read from the base
branch as it is now, like those of the gate, so a feature that adds its own
paths to `low` is still classified by the base's file, and is `high` because
it changed the policy. Each classification resolves the base to its commit
once and reads the policy, the override, and the gate configuration of that
commit once (`risk_policy_load` in `scripts/lib/risk.sh`); the next
classification resolves the base again, so a base that moved in between is
read with its new policy. When the base of the feature cannot be determined, or
Git cannot enumerate its changes (a failed `git diff`), the level is `high`,
never the default for a feature that changed nothing.

**The owner's hint.** A new feature has no diff, so without a hint its first
session runs at the default of the policy, also when the feature will be
`high`. You can raise the level before that session, in two ways:

- **A label on the Issue:** `risk: high` or `risk: medium` (in any case).
  `start-feature.sh` reads the labels with the title of the Issue when it
  creates the feature and keeps the level of the label in the Git
  configuration of the branch (`branch.<branch>.workflow-risk-label`), so
  that every script of the feature counts it, for the whole feature. Labels
  are set by people with triage rights on the repository; other labels,
  `risk: low` among them, say nothing about the level. Every session reads
  the labels again, a resumed one too, and keeps the highest level it has
  seen: a label added later counts from the next session on, a removed label
  lowers nothing, and a read that fails for a moment keeps the level that
  was kept.
- **A command-line option:** `start-feature.sh <issue> --risk <level>` and
  `run-feature.sh <issue> --risk <level>` (`low`, `medium`, or `high`) do the
  same for one run. The run passes it to the scripts it starts in the
  variable `WORKFLOW_RISK_HINT`; a later run does not see it.

A hint is one more input to the maximum: it raises the level, never lowers
it, and the path-based minimum and the escalations are unchanged. A hint
below the computed level is ignored and reported, like a completion record
that claims less. The reasons name it (`the Issue is labelled risk: high,
which raises the level to high`, `the owner gave --risk high for this run,
...`), `check-risk.sh` prints one line `hint: <level> <source>` per hint
after the reasons, with the source `issue-label` or `command-line`, and the
run record notes the hints with their sources in its `risk` events: the one
of `start-feature.sh` for the first session, and those of `run-feature.sh`.
The first session's agent and model follow the raised level, so
`implementer@high` applies from the start, and later sessions keep it by the
run records ("Per risk level" under "Configuring agents").

**Where it appears.** Each script derives the level itself, from the diff
and the rules of the base at that moment; a level stored in an artifact is an
input to the maximum, never the source of truth. `review-feature.sh` tells
the reviewer the level and its reasons and stores them in the review artifact
(`risk`). `finish-feature.sh` records them in the commit message, under
`Risk:`. `publish-feature.sh` computes the level again for the pull request
description and names the commit's level when the two differ.
`run-feature.sh` prints the level once the worktree exists and before each
review round, and the run record notes it (`risk` events). Each of them names
the workflow profile of the policy next to the level (`profile: light`,
`profile: standard`, or `profile: none`), and `report-runs.sh` shows it per
feature. The merge approval
gate is unchanged: a `high` level grants nothing, and a protected path keeps
needing your approval.

To ask, in a feature worktree or in CI:

```bash
./scripts/check-risk.sh            # against main
./scripts/check-risk.sh develop    # against another base
```

The first line is `risk: <level>`, then one reason per line, then one
`hint: <level> <source>` per hint of the owner, then the workflow profile (`profile: ...`), then what the level requires of the
review rounds (`verification: ...`, `review: ...`, `triage: ...`, and
`refused: ...` for a value of the policy that is not accepted). It exits 0
for `low`, 1 for `medium`, 2 for `high`, and 3 on a usage error, so a CI
step can branch on it.

### What each level requires

The risk policy also says what a level requires of the rounds of
`run-feature.sh`, one `<level>: <kind>: <value>` per line:

| Line | Meaning |
|---|---|
| `<level>: verification: full` | The full verification runs before every review round of a feature of that level. It is the only value: `run-feature.sh` makes the full verification before every round whatever the line says |
| `<level>: verification: groups <group> ...` | Refused since #443, and the full verification applies. It ran a partial check of the named groups in the intermediate rounds; since `run-feature.sh` makes the full verification before every round (#424), the partial check came in addition and saved nothing |
| `<level>: review: delta` | A later round may review only the changes since the round before (`review-feature.sh --changes`), when it can build on that round |
| `<level>: review: full` | Every round reviews the complete feature |
| `low: review: none` | A `low` feature is committed without a review. Only `low` may have it; `medium: review: none` and `high: review: none` are refused |
| `<level>: triage: full` | The findings of a review round are triaged as the triage contract says, with nothing added: the triage agent decides `FIX_NOW`, `DEFER`, or `ACCEPT` for every finding |
| `<level>: triage: light` | The light triage of suggestions and minor findings (see "Light triage" below). Only `low` and `medium` may have it; `high: triage: light` is refused, and the full triage applies |

The template writes no requirement line, so every level gets
`verification: full`, `review: delta`, and `triage: full`, which is exactly
what the workflow did before it knew the levels: the full verification before each round, a review of the changes
when it can build on the round before, a complete review last, and the
triage as the contract says. A level without a line gets the same. Of the
base refs the rules are read from (the local base and `origin/<base>`), the
strictest requirement counts, and a value that is not accepted counts as the
strictest and is reported by `check-risk.sh` and the scripts: `full` before
`delta` before `none`, `full` before `light`.

**Intermediate and final rounds.** Every round, intermediate or final, is
made on the full verification of its tree, which `run-feature.sh` runs after
the session and before the review; the fixes leave it to the run
(`apply-triage.sh --caller-verifies`). `verification: groups`, which ran a
partial check of named groups in the intermediate rounds, is refused since
#443: once the full verification preceded every round (#424), the partial
check ran in addition to it and replaced nothing, so it only cost time. To
let a partial-check round skip the full verification again would bring back
a review of content that no complete run checked, and a fix round that a
failing check outside the groups reaches only at the commit. A policy that
still has the line gets the full verification; `check-risk.sh` prints the
refusal, and `run-feature.sh` notes it in the log of the run. A review by
hand cannot make a partial-check round either: since #519
`review-feature.sh` has no option for a partial check, and a review artifact
with `verification.status: partial` is refused as invalid. A `high` feature
keeps needing your approval through the merge approval gate, which this does
not touch.

**Baseline and delta.** The first review is complete. A later round reviews
only the changes (`--changes`) when the policy allows it for the level, the
previous round is valid, the branch has the same base as then and the
content that round reviewed is still known, and the level computed now did
not rise above the level that round recorded. Otherwise the round reviews
the complete feature, and the log of the run says why: the base changed, the
previous review is invalid, or the level rose because the fixes touched a
path of a higher class or an agent raised it (the feature is reclassified by
the rules of "The risk level of a feature"). There is no changed-line
threshold. `run-feature.sh` computes the level again before every round from
the diff and the rules of the base; the level a review stored is at most
an input to the maximum.

**Low without a review.** With `low: review: none` in the policy of the base,
`run-feature.sh` verifies a `low` feature as a step of its own, repairs a
failed verification as it would after a review, and goes on to the commit
without a reviewer; a repair that makes the feature `medium` sends it to the
review after all. `finish-feature.sh` accepts the feature without a review
artifact and records `Review: not reviewed: Low risk by project policy` in
the commit message, which `publish-feature.sh` copies into the pull request.
Without a reviewer nobody classified the impact on the architecture, so the
merge approval gate requires your approval, as it does today for a feature
without a valid classification; CI stays required. A feature that has a
review is committed on it as before. Without the line, a `low` feature is
reviewed like any other.

**Light triage.** In every mode, a round whose triage has no `FIX_NOW`
finding ends the review loop without a fix session: `run-feature.sh` goes on
to the commit when that round reviewed the complete feature on the full
verification, and to the review of the complete feature when it was an
intermediate round; a `FIX_NOW` finding, also a minor one, is fixed and
reviewed again. With `<level>: triage: light` in the policy of the base, for
`low` or `medium`, `triage-review.sh` tells the triage agent that the policy
prefers to defer or accept a suggestion or a minor finding over a fix
session: `FIX_NOW` for such a finding only when it blocks the feature,
otherwise `DEFER` with a follow-up Issue, or `ACCEPT`. The agent still
decides every finding, and nothing is accepted by a script. Critical and
major findings are `FIX_NOW` in every mode, also in an owner-directed
triage; the validation of the decisions is the same. The triage artifact
records the mode (`triage.mode`), the log of the run notes a round that the
light triage ended, and the pull request description names the mode of the
policy (`Triage mode:`); the published triage comment, the follow-up Issues
of the deferred findings, and the commit message are unchanged.
`triage-review.sh` derives the level itself, from the diff and the rules of
the base, and never runs a light triage for a `high` feature, whatever the
review or the completion record says; `check-risk.sh`, `run-feature.sh`, and
`finish-feature.sh` report `high: triage: light` as refused, the full triage
applies, and `finish-feature.sh` refuses to commit on a light triage of a
feature that is `high` when the commit is made. With the shipped `full`,
nothing changes.

The template ships no `low` class. A project that wants one defines it by
paths only, and any escalation wins over the path class. Physics by
Construction, for example, defines its Level 1 as the documentation and
process files outside the ADRs, the planning documents, and `AGENTS.md`:

```text
default: medium
low: docs :(glob)**/*.md :(exclude)docs/decisions :(exclude)docs/roadmap.md :(exclude)docs/PROJECT_REQUIREMENTS.md :(exclude)AGENTS.md
low: review: none
high: scripts/verify.conf scripts/verify-workflow.conf src/verification
```

With that file a feature that changes only such documentation is `low` and
is committed without a review; a `high` feature gets the full verification
before every review round and its commit, as every level does.

**What does not change the fingerprint.** The content fingerprint that a
verification is recorded for, and that decides whether a review is stale,
leaves out what the workflow writes about the content: the review and triage
artifacts, the record of the last passed verification
(`.agents/verification/`), the run records and the state, logs, and risk
notes of a run (`.agents/run/`, and `.agents/records/` that an earlier
workflow wrote), and the approval
requests (`.agents/approval-requests/`). A review therefore cannot be made
stale by the metadata it produces, also in a project whose `.gitignore` does
not name those paths, and an edited explanation of an approval request keeps
the verification and the review valid. The list is fixed and lives in one
place, `scripts/lib/fingerprint.sh`, which the merge approval gate protects;
`check-guardrails.sh` reads it from the base branch, so a feature cannot add
an exclusion for itself. Nothing else is left out: the plans under
`.agents/plans/` stay in, because a plan can change the acceptance criteria,
the review scope, or the risk, and so do the policies, prompts, schemas,
check lists, and manifests. The fingerprint of a feature review covers one
thing more than the content: the implementer's completion record and handoff
note of the Issue, which the reviewer of the complete feature judged too. A
change to either after the review makes the review stale, while the
verification pass stays valid, since a note about the verification does not
change what was verified.

**The rule for what is left out.** The files the content fingerprint
leaves out are of two kinds, and the rule differs:

- *Display-only files*: the approval request. It changes the behavior of no
  script; a script reads it only to display it, and `check-guardrails.sh` can
  only refuse it. The tests change every field of a request and show that no
  script's exit status or output changes but the displayed request
  (`tests/publish-feature-test.sh`, `tests/guardrails-test.sh`,
  `tests/finish-feature-test.sh`). The sentence "a field which affects
  behavior must enter the content fingerprint" applies to display-only files
  and to nothing else: a file that a script would read for more than display
  is not left out as display-only, and the list is not extended for it.
- *Decision artifacts*: the review and triage artifacts. The gates read them,
  and that is their purpose: `finish-feature.sh` reads the verdict, the
  findings, the base, and the scope of the latest review and the decisions,
  the mode, and the publication of every triage. They change behavior only
  for the content tree they name: a review names the content it judged
  (`reviewed_tree`); an artifact whose `reviewed_tree` is not the tree of the
  current content is not current (`check-review.sh`), and a gate acts only on
  a current artifact that passes its schema. A triage must name the reviewed
  tree and the verdict of its review, and is published on the Issue before a
  commit rests on it. So editing a behavior-driving field of a current
  artifact (the verdict, a finding's severity, a triage decision) changes
  what the gate does, and the gate follows the edited artifact; the same
  artifact against other content is refused as not current
  (`tests/finish-feature-test.sh`, cases `gate-review-field` and
  `gate-triage-field`). The artifacts are left out of the content tree so
  that the evidence cannot invalidate what it describes: editing one leaves
  the content tree, the recorded verification, and the currency of the
  latest review unchanged, and the edit shows in the artifact manifest that
  every agent session runs inside (see "Configuring agents"), which stops
  the session of an agent that changed, added, or removed an artifact, and
  in the hash of the artifacts (`fingerprint_artifacts` in
  `scripts/lib/fingerprint.sh`), which `triage-review.sh` and
  `analyze-runs.sh` also compare around their agents
  (`tests/agent-test.sh`, `tests/fingerprint-test.sh`,
  `tests/finish-feature-test.sh`). The
  verification record and the run records are left out the same way and
  bound the same way: the record names the tree it passed for, and
  `verify.sh --reuse` reuses it for that tree only.

### The project's policy override

`.agents/policies/risk.conf` is the template's file: a sync of the template
(`./scripts/sync-template.sh`) updates it. A project keeps its own choices,
its classes, its default, its profile, and its requirements, in its own
file `risk.conf` in `.agents/policy-overrides/`, in the same format. The
template never ships a file under `.agents/policy-overrides/`, and the
directory is not in the `paths:` of `.agents/template.conf`, so a sync leaves
it alone without an exclusion, and the template's `risk.conf` stays
unchanged and keeps receiving the template's updates. For example, to select the light
profile and add the classes of a web application:

```text
# .agents/policy-overrides/risk.conf
profile: light
high: src/auth db/migrations
manifests: package.json package-lock.json
```

How the two files combine (`risk_config_written` and `risk_classify` in
`scripts/lib/risk.sh`):

- A single value the override writes, `default`, `profile`, or a requirement
  `<level>: <kind>` ("What each level requires"), replaces the line of that
  key in `risk.conf`.
- A path class or list, `low`, `medium`, `high`, `tests`, `test-fixtures`,
  or `manifests`, is matched with its own pathspecs, next to the class of
  `risk.conf` and of the preset, and a path gets the higher of the two. The
  override can therefore never drop a path from the `high` class the
  template ships: writing `high: src/auth` adds `src/auth` to it, and an
  exclusion such as `high: :(exclude)scripts/run-feature.sh` narrows only
  the override's own patterns.
- The preset of the profile ("Workflow profiles") then supplies the keys
  that `risk.conf` does not write and, for a single value, the override
  does not write either; a path class of the override never takes the place
  of the preset's.

The override applies on top of `risk.conf`: a base without `risk.conf` gets
the built-in policy, and its override is not read.

The override can lower what a feature costs, so it gets the scrutiny of the
policy it overrides. It is read from the base branch like `risk.conf`: a
feature that adds or changes it is classified by the policy and the override
of the base, never by its own, so it cannot lower its own level. Any change
under `.agents/policy-overrides/`, also adding the file, is `high`
whatever the policy says, and it is protected by the merge approval gate
whatever `.agents/policies/guardrails.conf` says, so it needs your approval;
`.github/CODEOWNERS` lists the directory too. `tests/risk-test.sh` and
`tests/guardrails-test.sh` check both, and `tests/sync-template-test.sh`
checks that a sync leaves the directory alone.

A project that already wrote its choices into `risk.conf` keeps working: the
lines of `risk.conf` still count. To move them, write them into the
override, restore `risk.conf` to the template's version, and remove an
exclusion `:(exclude).agents/policies/risk.conf` from `.agents/template.conf`
if it has one; the feature is `high` and needs your approval.

### Workflow profiles

A workflow profile is one line of the risk policy that names a preset of
the policy: `profile: light` or `profile: standard`. A project writes it in
its policy override, the file `risk.conf` in `.agents/policy-overrides/`
("The project's policy override"), not in the template's
`.agents/policies/risk.conf`. It is not a second mechanism: the preset
supplies the lines of the keys that the file does not write (the classes,
the `default`, the test files and fixtures, and the `<level>: <kind>` requirements of
"What each level requires"), and a line that the project writes always wins
over it. The presets live in one place, `risk_profile_preset` in
`scripts/lib/risk.sh`, and everything after it is the same implementation:
the same classification, escalations, requirements, completion records,
fingerprints, verification reuse, reviews, triage, and merge approval gate.

| Profile | What the preset supplies |
|---|---|
| none (no `profile:` line) | Nothing: the lines of the file are the policy, as before the profiles existed |
| `standard` | The policy the template ships: `default: medium`, the `high` class of the workflow and its gate, `tests: tests test`, `test-fixtures: tests/lib-fakes.sh`, and `verification: full`, `review: delta`, `triage: full` for every level |
| `light` | The same, and a `low` class of the documentation and process files (`docs/` outside `docs/decisions` and the planning documents, `.agents/plans`, `.agents/handoffs`, `.agents/summaries`, and the top-level Markdown files but `AGENTS.md`), `low: review: none`, `low: triage: light`, and `medium: triage: light` |

**Three things with similar names.** A workflow profile decides what a
`low` and a `medium` feature cost. The risk level is computed from the
change ("The risk level of a feature"), never from the profile: the profile
selects no level, and no profile turns an escalation off. The permission
profiles of the agents (`write`, read-only, `unattended`, see "Configuring
agents") decide what an agent session may do, and are unrelated to both.

**What light removes, and what stays.** For a documentation-only feature,
which is `low` under `light`, the run has no reviewer session and no triage
session: `run-feature.sh` verifies it as a step and commits it as under
"Low without a review". For a `medium` feature whose review has only minor
findings and suggestions, the light triage prefers to defer or accept them,
and the round ends without a fix session and without the reviews after it
("Light triage"). `tests/run-feature-policy-test.sh` runs the same fake features
under no profile, `standard`, and `light` and compares the sessions: one
implementer and one reviewer for the documentation, against one implementer
under `light`; one implementer, three reviews, one triage, and one fix
session for the medium feature, against one implementer, one review, and one
triage under `light`. What stays under every profile: the implementer and its
completion record, the full verification before the commit, the commit and
the pull request with their evidence, CI, and the merge approval gate, which
needs your approval for a feature without a review and for every protected
path.

**High is never lighter.** No preset changes the `high` class, the
escalations, or what `high` requires; `high: review: none` and
`high: triage: light` stay refused whatever the profile. A `high` feature
under `light` gets the full workflow, and `check-risk.sh` says so:
`profile: light; the level is high, so the profile does not apply`.

**Selecting a profile cannot lower the protection of the feature that
selects it.** The policy is read from the base branch, like every rule: a
feature that adds or changes the `profile:` line is classified by the
profile of the base, and is `high` because it changed the policy. The new
profile applies to the features after it is merged, which needs your
approval because the policy is a protected path. A value that is not a
profile (`profile: lite`) is reported as refused, and the preset of
`standard` applies, never less. Of the base refs the rules are read from,
each ref's profile applies to its own rules, and the strictest requirement
counts, as for every requirement; the output then names the profile of each
ref.

**Clarification.** A profile changes nothing about clarification. No
profile adds an interview to a feature, so clear work is not asked
anything; an implementer that cannot continue without your decision records
the question under "Open questions" in the handoff note and stops with
`BLOCKED:` ("Running feature steps without questions"), under every profile.
The targeted clarification gate is available (Issue #16, merged in PR #213);
a profile neither replaces nor skips it.

**Existing projects.** A project whose policy has no `profile:` line keeps
exactly its behavior and is reported as `profile: none`, not as
`standard`. Nothing migrates by itself.

**Migration.** Set or change the one line in the project's policy override,
the `risk.conf` in `.agents/policy-overrides/` ("The project's policy
override"), and
merge it, for example from `light` to `standard` when the project grows:

```text
profile: standard
```

Nothing else changes. The Issues, the history, the completion records, the
reviews, and the recorded verifications stay valid: the profile is not part
of the content fingerprint's rules, and a feature in progress is classified
again by the policy of the base when its scripts next run, as after any
change of the policy. A line the project writes wins over the preset, so a
copy of the policy from before the profiles that writes out every
requirement line keeps those lines under any profile: remove the lines that
the profile should supply.

## Run records

The workflow records how long every step of a feature or a planning took and
how many tokens its agents used. The scripts and the agent adapter record it;
agents estimate nothing. It is a local record for you: nothing is sent to
GitHub.

**A run** is one command that you start: `./scripts/run-feature.sh 12`,
`./scripts/review-feature.sh 12`, `./scripts/revise-planning.sh ...`, or
`./scripts/verify.sh` in a feature or a planning worktree. The
commands that a run starts itself belong to it, so nothing is counted twice. A
command that you start again, such as `start-feature.sh 12 --resume`, is a new
run that names the run before it.

**Where the records are**, in the primary checkout, ignored by Git:

| Path | What |
|---|---|
| `.agents/run/records/<run-id>.jsonl` | One file per run, written while it runs, never rewritten. All worktrees write here, so a record survives the removal of a worktree, and two runs never share a file |

No script removes a run file, and every reader takes the runs of a feature or
a planning by the subject of their start, so the run files are all there is:
nothing copies them together. An earlier workflow also copied the runs of a
feature or a planning to `.agents/records/` when it published or cleaned up;
no script reads or writes those copies any more, since every run they hold
still has its own file. Git still ignores the directory, and you can delete
it.

The records live on one machine: a new clone and `git clean -fdx` do not keep
them. Copy `.agents/run/records/` when you want to keep them. In a project
whose `.gitignore` does not ignore `.agents/run/`, nothing is recorded, since
a record would otherwise be committed; `sync-template.sh` brings the rules.

**What a line holds.** Every line is one JSON object with `schema`
(`run-record/v1`), `run`, `time` (UTC), `epoch`, and `type`:

| `type` | Fields |
|---|---|
| `run-start` | `kind` (`feature` or `planning`), `subject` (the Issue or the name of the planning), `command`, `seq` (the number of the run within its subject, which orders runs that start in the same second; claimed with a link in `.agents/run/records/.sequence/`, `null` when it could not be claimed), `previous` (the run before it of the same subject), `repository` (owner/name), `versions` (the template commit, a hash of the prompts and of `agents.conf`) |
| `run-end` | `status`: the exit status; 130 when the run was interrupted. For a status other than 0 also `step` and `reason`: those of the last `stop` of the run, so a failed run always says where and why it ended. A run without an end was killed and is incomplete, and a start without its end shows what was going on |
| `stop` | `step` and `reason`: where a workflow script stops and the text it tells you. The `step` is the script (`finish-feature.sh`), or for `run-feature.sh` the step of the run (`implementation`, `commit`, ...). A command that fails under `set -e` records `unexpected exit` with the command and its line; a run that ends without a stop gets `exited with status <n> without a recorded reason`, an interruption `interrupted`. The experience record (`derived.stop`) and the Runs table of `report-runs.sh` show them |
| `agent-start`, `agent-call` | an agent call begins (`id`, `role`, `profile`, `agent`, `model`, and `level` and `selection`: the risk level of the feature that selected the agent, `null` for a planning or an analysis, and where the selection came from, `command-line`, `level-line`, or `plain-line`; see "Configuring agents") and ends (the same, with `status`, `seconds`, `usage`) |
| `verification-start`, `verification` | a verification begins (`id`, `groups`: always `all`, since a partial run with `--only` is not recorded) and ends (with `status`, `seconds`, `reused`: a recorded pass stood in for the run, and `budgets`: the budget checks of the run, each with `name`, `status` `exceeded` or `within`, `exit`, and `output`, and the target for the duration of a file's checks that the run exceeded, named `duration of <file>` with `exit` null; an empty list without one, and the recorded results for a reused pass; `checks`: the duration of every check that ran, each with `name`, `config` (the file that declares it), `seconds`, and `result` `pass`, `fail`, or `budget`; an empty list for a reused pass; `origin`: who started the verification, `orchestrator`, `script`, `agent-session`, or `manual`; `trusted`: whether its pass counts as evidence under the trust contract, see "Recorded verification": a pass that a workflow script ran itself, or a reused one whose tree is in `VERIFY_TRUSTED_TREES`) |
| `step-start`, `step` | a step of `run-feature.sh` begins (`id`, `name`) and ends (with `status` and `seconds`) |
| `wait-start`, `wait` | the pause before a step is tried again: the `planned` seconds, and the `seconds` it really took |
| `intervention` | `what` you did that a script saw: an approval, a resume by hand, `--implemented`, `--partial` |
| `resumed` | the run follows a run of the subject that stopped with `previous_status` other than 0 (`after` is that run); for a feature, `handoff_changed` says whether the handoff note changed after the stop (never its content). Who started the run or changed the note is not known, so this is not an intervention |
| `note` | a line of the log of `run-feature.sh` (`.agents/run/<issue>-log`), which is written from the same event |
| `completion-gate` | one check of the completion gate: `check` (its number in the run), `sessions` (the sessions of the implementer and the triage implementer that the run recorded before it, a repair or a retry too), `session` (the last of them, which the check judges; a check without a new session judges it again), `status`, `reasons`, and `content`, the fingerprint of what it judged |
| `artifact` | a review or a triage that the run wrote: `kind` and `path` |
| `finding` | a finding of a feature review that the run stored: `round`, `id`, `severity`, and `previous` (`round`, `id`, `relation`) when it continues an earlier finding; see "Earlier rounds and re-raised findings" |
| `risk` | the risk level of the feature as `run-feature.sh` printed it: `when` (at the start, or before a review round), `level`, and `reasons`; or the level of the first session of `start-feature.sh` when the owner gave a hint; and `hints`, when there is one: each with `level` and `source` (`issue-label` or `command-line`) |
| `issue-comments` | the comments of the Issue that a step read for its agent: `issue`, `role` (`implementer`, `reviewer`, or `triage agent`), `passed` and the `authors` of the passed comments, `left_out` (by the size limit), `others` (comments of other authors), and `workflow` (the workflow's own reports) |
| `experience` | the experience record of a feature run, under `record`: see below |

**Token usage** keeps the field names of the provider, with `source` saying
where it came from: `claude-result` (the result of an unattended or a
read-only Claude session), `codex-events` (the events of a Codex session),
`interactive` (a session in your terminal, which reports nothing), or
`unavailable`. A figure the provider did not report is `null`, never zero.
A Codex call adds up its turns; a field that one turn did not report is
`null` for the call, and what the other turns reported is under `partial`, so
an incomplete sum never passes for a total.
`total_input` adds up what the provider counts as input: Claude reports the
input, the cache creation, and the cache reads apart, and they are added;
Codex reports input tokens that already include the cached ones.

**Time.** `seconds` of a call or a step is elapsed time. The elapsed time of a
run is the difference between its start and its end; the sum of its calls can
be higher when work runs side by side.

No prompt, no answer, no secret, and no transcript is recorded: every event
passes a filter that replaces what looks like a key or a token, a private key
with its whole body, by `[redacted]`. A record that
cannot be written is reported, and the work goes on with its own outcome.

**Self-tests started inside a run.** A run passes its `RECORDS_*` variables to
everything it starts, so a workflow script that an agent starts belongs to the
run. The workflow self-tests do not: every `tests/*-test.sh` sources
`tests/lib-fakes.sh`, which unsets them, as `verify.sh` does for each check,
so a test that an agent starts by hand inside a run writes nothing into that
run's record. A test of the records sets what it needs itself.

Records written before the self-tests did this may contain the fake events of
such tests, under the run's own `run` id. They are recognizable by their
model: `agent-start` and `agent-call` events whose `model` is a fake of the
tests, `model-` followed by a letter or a word (`model-a`, `model-b`,
`model-t`, `model-claude`, `model-codex`), mostly with usage figures `null`.
The same runs hold many `verification-start` and `verification` events within
seconds, and review or triage rounds that the run never had.
`report-runs.sh` leaves their agent calls out of the totals and warns about
them (see "Reporting on the records"); such records are not repaired.

### Reporting on the records

```bash
./scripts/report-runs.sh 12                         # one feature; in its worktree, without the number
./scripts/report-runs.sh 12 14 15                   # side by side, with what differs
./scripts/report-runs.sh planning:final-curriculum  # a planning cycle
./scripts/report-runs.sh --all --since 2026-10-01   # every subject, runs from a date on
./scripts/report-runs.sh --all --split 2026-11-01   # the features before and after a change
./scripts/report-runs.sh 12 --json                  # the same as JSON
```

A report shows per subject the outcome of its runs, the elapsed time, the
agent time, the review rounds, the triage, and the repair sessions, for a
feature the re-raised findings (unresolved and worsened), the tokens
per role, model, and run, the calls, the time, and the tokens per risk level
of the feature, model, and selection of the agent (for the calls that
recorded a level, see "Configuring agents"), the verification (with the
passes that counted as evidence under the trust contract, and who started
the verifications: see "Recorded verification"), the five
slowest checks of each verification that ran its checks (with the sum of the
durations of all of them; a reused pass ran none, and a verification
recorded before the durations has none), the steps of `run-feature.sh`, the
recorded interventions, and the versions the runs used.
It reads the run files
of the primary checkout, each run from its own file, so nothing is counted
twice and a feature whose worktree is gone gives the same totals. It needs no
network.

Some figures need care:

- **Elapsed time** is the time during which at least one run of the subject
  went on: runs side by side count once. A subject with a run without an end
  has an elapsed time of "at least", and `--split` leaves it out of the means
  of elapsed time and says how many. **Agent time** is the sum of the agent
  calls, and is higher when calls ran side by side.
- **A call or a step that did not finish**, as in an interrupted run, counts
  as unfinished: its time and its tokens are unknown.
- **Tokens** that a call did not report are not zero. A call has complete
  figures, partial figures (only some of its turns reported them), or none.
  Partial figures count in the sum, which then says "at least" (and "≥" in
  the GitHub summary) and how many calls are partial and how many have no
  figures; a sum without any figure is "unknown". `--split` leaves features
  with partial or unknown figures out of the means of tokens and says how
  many.
- **A subject without any record** is named and left out, not counted as zero.
- **Calls of undeclared models.** Every `agent-start` and `agent-call` is
  declared when its event records a `selection` (`plain-line`, `level-line`,
  or `command-line`: the script chose the agent and model, overrides
  included), otherwise when its agent and model pair stands on a plain or
  level line of any role in any version of `.agents/agents.conf` in the Git
  history of the primary checkout or in its current file, and undeclared
  otherwise. An undeclared call, such as a fake call of a self-test in an old
  record, is left out of the call counts, the times, the tokens, the review
  rounds, the triage, and the repair sessions, and once per run a warning
  names it ("run <id>: 62 calls of undeclared models model-a, model-b; left
  out of the totals"), with a "Left out" line in the table of the subject.
  `--json` carries the same warnings in `warnings` and the calls left out in
  the subject's `undeclared`; both are absent when no call is undeclared, so
  such a report is unchanged. A model that the project used and later
  replaced in the file stays in the totals. When no version of the file is
  committed, the current file alone is the measure and the warning line says
  so; without any version nothing is compared.
- **A comparison** names what differs between the subjects: the template
  commit, the prompts, `agents.conf`, and the models. It and `--split` say
  that totals and means show no cause: features differ in size and
  difficulty.
- **Interventions** are what a script saw you do. A run that follows a
  stopped run is counted apart, since who started it is not recorded.

**The summary on GitHub.** `./scripts/publish-feature.sh 12 --summary` also
posts the totals of the feature on its Issue: the elapsed time, the number of
runs, the review rounds, the repair sessions, and the tokens per role and
model, with how many calls reported complete, partial, or no figures for
each direction. It is off by default, since a repository is often public. It is built
from an explicit list of numeric fields, so no log, path, time of day, status
reason, or other text of the records reaches it; a role or a model name that
does not look like one is shown as `other`. It is one comment, replaced when
the feature is published again, and a failure to post it only warns. At
every publication, also without `--summary`, the description of the pull
request shows the run figures of the feature after the manual steps (`./scripts/report-runs.sh
--pull-request-figures 12`): the time of the implementer and
triage-implementer sessions, the full verifications (a reused pass and a
partial run count as none), and the lead time from the first run start to the
first `pull request` step that succeeded, or up to this publication before
there is one; numbers only, as for the summary.

### Experience records

At the end of every run of a feature, except a verification on its own, the
run file gets an experience record: compact observations of the run, kept
with its run records, copied with them, and never published. It supplements
the handoff note, the completion record, the reviews, and the triage, and
replaces none of them.

**What a script derives, always.** Without an agent and without tokens, from
what the run itself wrote, as it recorded it when it wrote it (an `artifact`
event for a review or a triage), so that nothing of an earlier run or of a run
beside it counts: the review rounds and their findings
per severity, what the triage decided, the verifications that failed and
those for which a later verification of the same checks passed, why the run
stopped (status 3: a decision of yours; 130: interrupted), the outcome of the
completion gate after each session
(each check of the gate is a `completion-gate` event, with the number of
sessions before it, its reasons, and the content it judged), and the completion record at the end. The
artifacts are read from the worktree of the feature, also when the run was
started from the primary checkout. The record names the code version: the
commit, the content of the worktree with its uncommitted changes, and the
commits and contents the reviews of the run covered. Each becomes an observation of
the kind `fact`, with a reference to its evidence: the review and finding,
the triage, the run record, the handoff note, or the completion record. A
finding without a triage in the run says that its evidence is missing. A run
with nothing to observe says so (`none_relevant`).

A record of an earlier version of the workflow can hold fields, and its run
events, that are no longer written: they are not judged, not shown, and no
source for an analysis.

**Never a gate.** A record that cannot be made is reported, and the run keeps
its own outcome; nothing in a review, the completion gate, `finish-feature.sh`,
or `publish-feature.sh` depends on it. A record is written once and never
rewritten. A record changes nothing in the repository. What looks like a
secret is replaced by `[redacted]`, a private key with its whole body, and
the handoff note and the transcripts are not copied. A record is as long as
the run was.

```bash
./scripts/show-experience.sh 12         # the records of feature 12, as Markdown
./scripts/show-experience.sh 12 --json  # valid and invalid records apart
```

`show-experience.sh` checks every record and lists a record that is not valid
under "Invalid records", with what is wrong, also a line that is not JSON,
with its file and line, and a record that names
another run or Issue than the one it belongs to: it is never a source for an
analysis, and it hides no valid record. Nothing moves from a record to `.agents/lessons/` by itself; that is
a proposal of an analysis and your decision.

### Analysing several runs

```bash
./scripts/analyze-runs.sh 12 14 15          # these features
./scripts/analyze-runs.sh --since 2026-10-01  # the features with runs from a date on
./scripts/analyze-runs.sh --last 10         # the ten features whose first run started last
./scripts/analyze-runs.sh 12 14 --input-only  # the input only, without an agent
```

You start an analysis by hand. It compares the run statistics
(`report-runs.sh`) and the valid experience records (`show-experience.sh`) of
the selected features, looks for recurring errors and blocks, the causes of
extra review and repair rounds, the steps that cost the most time or tokens,
ways of working that succeeded, and assumptions or observations that
contradict each other, and proposes improvements in order of priority.

**The analyst is read-only**: a role of its own in `.agents/agents.conf`
(`analyst`), run as a read-only session. An analysis that changed the working
tree fails, and nothing of it is kept. Nothing reaches the knowledge, the
prompts, or the checks of the project by itself: each proposal names its
place, and you take it through the review and approval that apply there.

| Place | What |
|---|---|
| `adr`, `agent-instruction`, `skill`, `documentation` | a change you make in the project, with its review |
| `script-check` | an enforceable check in a script of the project, also named in `enforceable_check` |
| `issue` | a separate Issue of the project |
| `template` | the workflow scripts, prompts, or schemas: a project takes them over with `sync-template.sh` and cannot repair them locally, so it is an Issue in the template repository |

**What the script checks in the result**, before it keeps it (one corrected
attempt is allowed):

- every conclusion cites evidence, and only ids that are in the input: runs,
  observations (`<run>/<observation>`), and `statistics/<kind>/<subject>`;
- a `finding` rests on at least two runs; one observation is a `hypothesis`
  or a `single-observation`, never a general rule;
- every conclusion says which differences in task size, model, and workflow
  version it considered;
- a proposal that concerns the workflow scripts is placed in `template`;
- no conclusion at all is valid only as `insufficient_evidence`, which is a
  valid outcome.

**Reproducible and not counted twice.** Every analysis is kept in
`.agents/analysis/<time>-<input>/` of the primary checkout, ignored by Git:
`input.json` with the selection and its runs (a period selects runs, so the
observations of a run outside it are not in the input), the template commit,
the commit of the repository, and a content hash of the workflow as it is in
the working tree (the scripts, the prompts, the schemas, and `agents.conf`),
with whether it has uncommitted changes; `sources/` with the prompt, the
schema, and `agents.conf` as they were used, and every file the analyst says
it read besides the input (`consulted`); `analysis.json` with the result and
the evidence it used; and `report.md`. An analyst that changed the working
tree, also a file that was changed already or a review or triage artifact,
fails. The next analysis gets that
evidence as `already_analysed`, and the report marks a conclusion that rests
on it as used by an earlier analysis: the same observations are no new,
independent evidence. The input holds the compact records; the analyst reads
more only where a conclusion needs it.

## Project skills

A skill is a piece of guidance for an agent, such as a design method or a
writing rule, that someone else published or the project wrote. The template
bundles none and needs none. A project may keep a few in its repository, and
a feature plan selects the ones the work needs: only then does an agent read
one. A project without skills has nothing to install, configure, or run, and
every step works as before.

**Where they live.** One directory per skill, `.agents/project-skills/<name>/`,
with its guidance files and its metadata in `skill.conf`:

```text
.agents/project-skills/plain-labels/
  SKILL.md       the guidance an agent reads
  LICENSE        the upstream licence, for third-party content
  skill.conf     the metadata
```

The directory is not `.agents/skills/` or `.claude/skills/` on purpose: Codex
and Claude Code discover those by themselves, and differently, so a skill
there would reach one role and not the other, and without a plan selecting
it. The scripts give the files to every role by path instead.

**The metadata.** One `<key>: <value>` per line:

```text
origin: third-party
source: https://github.com/example/interface-skills
revision: 3f6c2a91d0b4e7c85a1f29e6b0d3c4a7e8f91b25
license: MIT
license-file: LICENSE
content: adapted
changes: kept the section on button and link labels; dropped the install script and the hooks
files: SKILL.md
digest: sha256:9c1e4f...
```

| Key | Meaning |
|---|---|
| `origin` | `project` for a skill the project wrote, `third-party` for one taken from elsewhere |
| `files` | The files an agent reads, relative to the directory: the content that is retained |
| `digest` | `sha256:<hex>` of those files: what `sha256sum <files> \| sha256sum` prints in the directory, and what `./scripts/check-skills.sh --digest <name>` prints |
| `source`, `revision`, `license`, `content` | Required for `third-party`: where it comes from, the full commit hash it was taken at (a branch or a tag can move), its licence, and `upstream` or `adapted` |
| `changes` | What differs from upstream; required for `adapted` |
| `license-file`, `description` | Optional |

A skill holds guidance only: the directory may hold `skill.conf`, its
licence file, and the files it lists, and none may be executable. A script,
an installer, a hook, or a download of an upstream skill is left out when the
skill is taken over; using one is separate work with its own reviewed scope.

**Selecting skills.** The plan of the Issue selects skills in a section
`## Skills`, one per line, pinned by digest, with a note on what it is for:

```markdown
## Skills

- plain-labels sha256:9c1e4f... for the labels of the settings form
```

`start-feature.sh`, `review-feature.sh`, and `apply-triage.sh` read the
selection and list the files in the prompt of the implementer, the reviewer,
and the fix session: the same files for every role and every provider. A
selection that does not resolve stops the step before an agent starts, and
says why: a skill that does not exist, metadata that is not valid, or a
pinned digest that is not the digest of the files now, with the source and
revision of a third-party skill. A plan without the section selects nothing.

**What a skill cannot do.** It is guidance below every other source
(`AGENTS.md`, "Source precedence"): the Issue, the ADRs, `AGENTS.md`, the
architecture, and the plan come first. It cannot waive the owner's approval,
widen permissions, change a policy, or change the scope. Following it is no
evidence: the completion record cites a test, a check, or a file, never that
a skill was read, and a design skill does not show accessibility or
correctness. The contracts of the implementer and the reviewer say so, and
the reviewer reports a record that cites a skill as evidence.

**Changing a skill.** A new version is an ordinary reviewed change: the
files, the `digest` in `skill.conf`, and the digest in the plans that should
use it change in one feature. A change to an existing file of a skill makes
the feature `high` (see "The risk level of a feature"), as a change to an
agent contract does. `.agents/project-skills/` belongs to the project, not to
the template: `sync-template.sh` never adds, changes, or selects a skill, so
no project is opted in by an update.

**The check.** `./scripts/check-skills.sh` checks the metadata of every skill
and that its files still have the recorded digest; the template runs it in
its verification (`skills` in `scripts/verify.conf`), and a project without
skills passes. `--issue <n>` checks the selection of the plan of Issue `<n>`
and prints the files to read. The check reads and hashes files, nothing else:
it installs, fetches, and runs nothing.

**An example.** A project keeps the skill above, `plain-labels`, whose rule
is "name a button after the action it performs, and say what will happen,
not how". The plan of an Issue that adds a settings form selects it. Without
the skill the implementer wrote:

```html
<button type="submit">Submit</button>
<a href="/settings/reset">Click here</a>
```

With the skill in its prompt it wrote:

```html
<button type="submit">Save changes</button>
<a href="/settings/reset">Reset to the default settings</a>
```

The reviewer read the same `SKILL.md`, found one more "OK" on the
confirmation dialog, and reported it as a minor finding that names the rule.
The completion record cites the test that checks the labels of the form, not
the skill.

## Taking over template changes

A project is created as a copy of the template and does not receive later
template changes by itself. `scripts/sync-template.sh` takes them over:

```bash
./scripts/sync-template.sh
```

Run it from the primary checkout without uncommitted changes to tracked
files. On `main` it first creates a branch `fix/sync-template-<commit>`. It
fetches the template named in `.agents/template.conf`, lists the template's
commits since the version the project has, and applies them to the files
listed under `paths:` in the template's version of that file. Every other
file is the project's own and is never touched. To keep a listed file as the
project's own, add `:(exclude)<path>` to `paths:` in the project's
`.agents/template.conf`; the project's exclusions always apply.

| Situation | What the script does |
|---|---|
| The project did not change the file | Replaces it with the template's version |
| Both changed it | Merges the two; a conflict is marked in the file and reported |
| The template added the file | Adds it; a file of the project at that path is merged against nothing and left as a conflict |
| The template removed the file | Reports it; the project decides whether to delete it |
| The template changed a file the project deleted | Reports it and leaves it out |
| The template started to list a file under `paths:` that already existed in the previous version (changed in the range or not) | Adds it when the project has no such file; keeps the project's file with other content and reports it |
| The template changed only the executable bit | Applies it to the project's file |
| The file, or a directory above it, is a symbolic link in the project | Reports it and writes nothing |

One line is never taken over: `parallel: <n>` of `scripts/verify.conf`, the
number of checks that the template runs at a time on its own host. The sync
leaves it out of the template's versions of that file, so a project runs its
checks one at a time until it sets its own line, and a line the project set
stays as it is (see "Checks at the same time").

Whether the template started to list a file is decided against the files of
the version the project has. When that version predates the `paths:` list,
the script says so and takes the list in the project's
`.agents/template.conf` as the files of that version: a file the template
lists now and the project's list does not is newly owned, with the outcomes
in the table. When the project's list is empty too, the files of that
version are not known and nothing counts as newly owned. When neither the
template now nor the project's `.agents/template.conf` lists files under
`paths:`, the script stops with an error before it changes anything. A list
that matches no file is an empty set: every file the template lists now is
newly owned.

The script records the template commit the project now has in
`.agents/template.conf` and prints the next steps: resolve conflicts, run
`./scripts/verify.sh --all`, commit, and open a pull request. It never commits
or pushes, and exits 1 when it left a conflict. Running it again when nothing
changed in the template reports that the project is up to date.

A project that has no recorded version yet, because it was created before
this script existed or has never been synced, gets one on the first run: the
script uses the template commit that has the most files identical to the
project's, and says which one. When several versions match equally well and
differ in template files, it does not guess, because the newest would skip a
template change to a file the project changed too: it lists them and asks for
`--from <commit>`, where the oldest is the safe choice. A project that is
already up to date only gets its version recorded. `--to <ref>` selects
another template version than its default branch, and
`--template <url-or-path>` another location, for example a fork; that location
is recorded, so the next sync continues from it. A local path, such as a
clone of the template on your machine, does not replace a `repository:` that
is a URL: the sync keeps the URL and says so under "Needs your attention",
because the URL is what tells the template from a project ("Framework-only
self-tests"). A sync from another URL records that URL. To follow a local
path from then on, write it into `repository:` yourself.

A template change can need a decision in the project, such as a new check or
a changed step. Read the listed commits before merging the result; the sync
only takes over files.

## Assessing an existing repository

```bash
./scripts/assess-repository.sh ~/my-project               # facts, report, and proposal
./scripts/assess-repository.sh ~/my-project --facts-only  # the facts only, without an agent
```

Run it from a clone of the template, with the path of a repository that does
not use the workflow yet. It is the first of three steps of adopting one
(#170): the assessment changes nothing, and the proposal it writes is the
input of the adoption (`adopt-repository.sh`, below).

**It only reads.** The script runs none of the repository's code, tests, or
installers. Git runs in the repository without optional locks, so the index
is not refreshed, and without the file system monitor and the filter drivers
of its configuration, which would run commands. Files that may hold a secret
(`.env`, `.env.*`, keys, `credentials*.json`, `.npmrc`, `.netrc`, and the
like) are named by path and never opened; deployment files are named by path
only; a CI workflow passes a filter first, the only step that reads the
file: it reads each line, as any filter must, but of an `env:` block it writes
only the secrets referred to by name, so no value of an environment block is
written to a file of the assessment or reaches a later step, the assessor, or
the report. In the commands it does record, what looks like a key or a token and the value of a variable
named like a secret are replaced. Symbolic links are not followed. When the
branch, the commit, or the status of the repository differs afterwards, the
assessment fails.

**The facts** (`facts.json`): the layout and the entry points; the language
and the package manager, from the manifests and lock files; the commands the
project declares (package.json scripts, Makefile targets), the run steps of
its CI, and those its tools run by convention (`go test ./...`, `pytest`),
each marked by origin and with the directory it runs in (the manifest's, or
the `working-directory` of the CI step, its job, or the workflow); the CI
files with the secrets they refer to by name, the events and branches that
trigger them, and what makes one a deployment (a `deploy` name, a deploy
action or command, a job `environment:`); the external actions the checks may
take (`external_actions`): a database client or a migration, an email
client, a client of an external API, telemetry (Next.js, Sentry, and the
like), a deployment, from the dependencies of each manifest and the text of
the commands; the deployment files; the requirement, architecture, and decision documents
and instructions for agents, each with its first heading, its length, and its
headings; the files that may hold a secret; the branch,
the commit, and the uncommitted changes; the branches (`branches`): the one
it measures, the checked-out branch, and the integration branch, the one
features merge into, with the reason: among the checked-out branch, the
default branch of `origin`, a develop-like branch, and the branches the CI
runs on, the one with the most pull requests merged on its first-parent
line, else the one the CI runs on for pull requests, else a develop-like
branch ahead of the checked-out one, else the default branch; and, against the template, the files
an adoption would add, the paths where the repository already has a file
(collisions, with whether they have uncommitted changes; a planning document
of the baseline, `docs/architecture.md`, `docs/PROJECT_REQUIREMENTS.md`, or
`docs/roadmap.md`, is one also where the template has none; a file whose name
differs only in case, such as an upper-case `ARCHITECTURE.md` in `docs/`, is one of the kind
`case-only`, with the project's name), and the directories
both have (`.agents`, `.github`, `docs`, `scripts`, `tests`). It also names
every path the workflow commits that an ignore rule of the repository would
hide (`adoption.ignored`, with the rule, its file, and an ignored directory
above the path when that is the reason): the files an adoption brings, and
those the workflow writes and commits later, such as
`.agents/approval-requests/<issue>.json`, `.agents/plans/`, `docs/decisions/`,
and `.agents/verification-baseline`. A rule such as `*.json` would otherwise
leave a new schema or an approval request out of a later commit, and
`finish-feature.sh` refuses an approval request that Git ignores. The
template's own product files stay behind: its site, `README.md`, `LICENSE`,
`CONTRIBUTING.md`, `SECURITY.md`, its approval requests, the placeholders
`src/.gitkeep` and `infra/.gitkeep`, its decision records under
`docs/decisions/` (all but the README), and the paths its own
`.agents/template.conf` excludes; none of them is named as a hidden path
either. When the application lives in a subdirectory (a manifest below the
top, none at it, such as `nextjs/package.json`), the starter files
`tests/unit/`, `tests/e2e/`, `tests/integration/`, and `.env.example` stay
behind too (`adoption.left_out`): its tests and its environment are there.

**The assessor is read-only**: a role of its own in `.agents/agents.conf`
(`assessor`), run as a read-only session in an empty directory, with the
facts on standard input and without the path of the repository, so that it
cannot read the repository. It writes the report and its part of the
proposal. What the script checks before it keeps them (one corrected attempt
is allowed):

- every fact cites the ids of the facts it rests on, and only those; an
  assumption names its basis, and a question what it settles;
- every collision has exactly one resolution, `keep-project`, `merge`,
  `take-template`, or `ask-owner`, with a rationale; `take-template` is
  refused for `AGENTS.md`, a script, a CI workflow, and a path with
  uncommitted changes, which stay the project's until the owner resolves
  them;
- a collision on a planning document of the baseline is the assessor's
  judgement whether the project's document is sufficient: `keep-project`
  (sufficient, reused), `reconstruct` (not sufficient), or `ask-owner`;
  `merge` and `take-template` are refused for it, and `reconstruct` for any
  other path;
- every verification command names a command of the facts, whose text the
  script takes over, so that no command is invented;
- the workflow profile, `light` or `standard`, has a rationale.

**The output** is kept in `.agents/assessments/<repo>-<time>/` of the primary
checkout of the template, ignored by Git, and nothing is written in the
assessed repository: `facts.json`; `report.md`, whose observed facts,
assumptions, questions, and risks are separate sections and which says that every
inference in it is *observed, not approved*, never an owner-approved
requirement or a historical decision; and `proposal.json` (`adoption-proposal/v1`,
status `proposed, not approved`) with the files to add, the collisions and
their resolutions, the profile, the verification commands, the template
version (the commit of the template checkout), the ownership for a later
`sync-template.sh` (the `paths:` of `.agents/template.conf`, and an
`:(exclude)` for every template file the project keeps), the base
(`base`: the measured branch, the integration branch, and the proposed
`base:` of `.agents/template.conf`), the deployment workflows that a push to
the base starts (`deployment_on_merge`), the isolation of the checks
(`isolation`) and the external actions of each check, what a later
baseline would have to run, with its side effects, and the material of the
baseline documents the adoption writes (the summary, the facts, the
assumptions, the risks, the questions, and the project's own requirement,
architecture, and decision documents). The report has a section for each:
it names the branch it measured and the integration branch, says plainly
when the checked-out branch is not the one features merge into, and then
asks the owner first among its questions which branch features start from
and merge into; it says when a merge into the base triggers a deployment;
and it names the external actions each check may take. Every run makes a new
directory; an earlier assessment is never changed.

## Adopting an existing repository

```bash
./scripts/adopt-repository.sh ~/my-project                     # the latest proposal of its assessment
./scripts/adopt-repository.sh ~/my-project --proposal <file>   # a proposal you chose or edited
./scripts/adopt-repository.sh ~/my-project --publish           # and push the branch, with a pull request
```

The second of the three steps of an adoption (#170). Run it from the clone of
the template that assessed the repository. It applies the proposal as one
commit on the branch `adopt/agent-codeyard` of the repository, which you
review like any change; running it on a proposal is your decision to apply
that proposal. The proposal's reconstructions stay *observed, not approved*.

**It only adds.** The workflow scripts, `.agents/`, `AGENTS.md`, and the
docs skeleton come from the template commit the proposal names, and
`.agents/template.conf` records that template, its version, and its files.
An existing file is never overwritten, and the template's product files stay
behind as in the assessment. A collision is applied as the proposal resolves
it:

- `keep-project`: the project's file stays its own, and the template's
  ownership of that path is excluded (`:(exclude)<path>` under `paths:`).
  `AGENTS.md` and `.gitignore` get a marked section appended once: the
  template's instructions for agents, and the lines that keep the workflow's
  working files out of Git. Below them, the section un-ignores the paths of
  the proposal that a rule of the project's `.gitignore` hides, with one `!`
  line each: a file of `.agents/` and a path the workflow writes later by its
  directory and extension (`!/.agents/schemas/*.json`), since more such files
  follow; any other path by itself. Nothing else of the project is
  un-ignored. A rule of another file (a `.gitignore` further down,
  `.git/info/exclude`) or of an ignored directory above the path cannot be
  undone from there: the adoption names each such path with its rule, for
  you to change.
- `merge` or `take-template`: the template's file is placed beside the
  project's as `<name>.agent-codeyard.<ext>`, to combine by hand. The path
  stays the template's, so a later sync reports a conflict until they are
  combined.
- `ask-owner`, or no resolution: the run stops. Set the resolution in the
  proposal and pass it with `--proposal`, or change the repository and assess
  it again.
- A file identical to the template's needs no resolution.
- A file whose name differs only in case (`case-only`, such as
  an upper-case `ARCHITECTURE.md` in `docs/`): it is renamed to the expected name with `git mv`,
  so its content and history stay, and the resolution then applies as for a
  file at that path. No second file is written beside it.

Nothing is written under `.github/workflows/`: the project's CI stays as it
is, and the template's CI workflows are left out. `paths:` excludes the
directory (`:(exclude).github/workflows`), so a later sync adds or changes no
CI workflow either. The project's history, application code, dependency
management, and deployment files are not touched; the commit runs none of the project's hooks.

**Written from the proposal**, where the project has no such file of its own:

- `scripts/verify.conf`: the verification commands of the proposal, the
  project's own test, lint, and build commands, one check each, run in their
  directory, isolated by default: each check starts by unsetting the
  variables of the environment whose names look like credentials (`TOKEN`,
  `SECRET`, `PASSWORD`, `API_KEY`, `ACCESS_KEY`, ...) and exporting
  `DATABASE_URL` to a closed local port, `DO_NOT_TRACK=1`, and the switch
  that turns off the telemetry of a tool the project uses
  (`NEXT_TELEMETRY_DISABLED=1`), as the proposal's `isolation` lists them.
  Clearing the environment does not shield a credential file that a tool
  loads by itself (`.env`, `.env.local`, `.env.*.local`, `.dev.vars`): a
  check stops with a message that names such a file, never its content,
  while one is in its directory, whether Git tracks it or not, until the
  owner has set up the shielding. A clean working copy, such as the
  worktree of a feature, holds none that Git does not track; a tracked one
  stops the check there too, until it is removed from the repository. An
  example (`.env.example`, `.env.sample`, ...) does not stop it. The assessment names the credential
  files it sees in the directories of the checks, tracked or not, names
  only, in the proposal's `isolation.credential_files` and in the report.
  A comment above each check names the external actions it may take. A check
  that needs a real service is changed in a reviewed change. The project's CI runs as before: the same commands become the
  checks of `verify.sh`, which integrates them without replacing the CI. The
  file is the project's (`:(exclude)scripts/verify.conf` under `paths:`), so a
  sync never changes it. Without a command in the proposal, one check fails
  and says that nothing of the project is verified yet.
- `docs/architecture.md`, `docs/PROJECT_REQUIREMENTS.md`, and
  `docs/roadmap.md`: a minimal baseline from the assessment. The architecture
  names the project's own documents first, to be reused, then the observed
  facts, the assumptions, the risks, and the unknowns; the requirements, still
  `Status: Draft` with the template's sections for Project Grill, name the
  project's documents that state requirements and the open questions; the
  roadmap lists the near-term work of the adoption. Each starts with the line
  `> **Observed, not approved.** ...`, which says how you approve it: through
  the planning approval of the repository (see "Planning approval"), after
  which it no longer carries the mark. A document the project already has at
  that path is applied as the assessment judged it: `keep-project`, it is
  sufficient and reused as it is, unmarked; `reconstruct`, it is not, and the
  marked baseline is written at its path, followed by a section "The
  project's document, as it was" with the assessment's rationale and the
  project's text unchanged, so the commit only adds lines and the owner folds
  the text into the planning; `ask-owner` stops the run. A proposal that
  does not judge a planning document the project has stops the run too:
  assess the repository again.

No ADR is written: the adoption reconstructs no decision of the past.

- `.agents/template.conf` records `base: <branch>` when the proposed base is
  not `main`, so features start from and merge into it.

**It stops before any change**, with a report that names each file, when the
proposal's base is not the branch the assessment measured (check the base
out and assess it again, or set `base.proposed` in the proposal to the
measured branch), when the
repository has uncommitted work (also untracked files), a collision is
unresolved, a path the adoption writes is a symbolic link or lies under one,
or the repository is not in the assessed state: another HEAD, or a file that
appeared or changed since the assessment. Assess it again then. A proposal
whose path is not a plain path in the repository (absolute, or with a `.` or
`..` component) or not a file of its template commit is refused as edited or
damaged, before anything is written.

**It is safe to repeat.** On an adopted repository, on its branch or after
the branch is merged, it changes nothing and says so. On a partial adoption,
for example a run that stopped before its commit, it adds what is missing and
commits it. A file the project changed or removed after the adoption is left
as it is and reported; a section is never appended twice.

**Publishing** with `--publish` pushes only the branch `adopt/agent-codeyard`
to `origin` and opens a pull request against the proposed base (the default
branch without one), or reports the one that is open. When a merge into the
base triggers a deployment, the adoption says so, and the pull request
description repeats it with the workflow and its trigger. Nothing is pushed to the default branch, merged, or
deployed.

After the merge, `./scripts/sync-template.sh` in the repository takes over
later template changes of the files the template owns, and reports a
conflict where the project has its own content.

## The baseline of an adopted repository

The third step of an adoption makes the baseline honest: the adopted project
runs ordinary features from the first day, and nothing claims more than is
known.

1. **Record the baseline of the verification** on the branch
   `adopt/agent-codeyard`, before any change, when you decide to run the
   project's commands (the proposal lists what they need, and their side
   effects): `./scripts/verify.sh --baseline` in the repository, then commit
   `.agents/verification-baseline` on the branch. A check that fails then
   is a pre-existing failure: every later verification shows it as `KNOWN`
   and fails until it is fixed or you accept it with `accepted-failure:` in
   `scripts/verify.conf` ("The baseline of an adopted project").
2. **Review and merge** the adoption. The planning documents stay *observed,
   not approved*.
3. **Work as usual.** `./scripts/run-feature.sh <issue> <name>` runs an
   ordinary feature in the adopted repository, with its review, its
   verification against the baseline, and the merge approval gate. Creating
   features from the roadmap (`create-feature-issue.sh`) waits for the
   approved planning.
4. **Approve the planning** when you are ready: `./scripts/start-planning.sh`
   and `./scripts/finish-planning.sh` in the repository take the reconstructed
   documents through Project Grill, the planner, and the planning review, and
   the approved documents lose the mark.
5. **Take over template changes** with `./scripts/sync-template.sh`, as in
   any project from the template.

The workflow profile of the proposal is not applied: it is one line,
`profile: light` or `profile: standard`, which you add to the project's
policy override, the file `risk.conf` in `.agents/policy-overrides/`, when
you want it ("Workflow profiles", "The project's policy override").

`tests/adoption-test.sh` runs these steps on a synthetic fixture: the
assessment, the adoption, a baseline with a failing linter that fails the
verification as `KNOWN` until it is accepted, one feature with
`run-feature.sh`, and a later `sync-template.sh` that changes a file of the
workflow and leaves the project's checks, its baseline, and its CI alone.

**Limits.** The assessment reads files; it understands no code, and its
reconstruction is a starting point for the planning, not a description you
can rely on. The baseline records how the checks ended on one machine; a
check that fails for a missing tool is `unavailable`, and still fails. The
adoption sets up no deployment, changes no CI, and fixes no existing defect.

## Lifecycle

The complete lifecycle, with diagrams and a reference table per step, is in
`docs/workflow.md`.
