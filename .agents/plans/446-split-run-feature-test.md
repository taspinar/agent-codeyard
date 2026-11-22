# Plan: Issue #446, split run-feature-test.sh into parts with a scenario register

Step 5 of #345. Tests and `scripts/verify-workflow.conf`, and the `--changed`
mapping of `scripts/verify.sh`. No change to a workflow script's behaviour
beyond that mapping.

## Steps

1. `tests/lib-run-feature.sh`: the shared part of the old file, unchanged
   (the fake agents and GitHub, `setup_repo`, `run_feature`,
   `expect_published`, `expect_stopped`, the shared replies), plus the
   scenario machinery: `scenario <id>`, `scenario_register`,
   `scenario_ids`, `scenario_errors`, `scenarios_done`. `fail` names the
   scenario that failed.
2. Four parts `tests/run-feature-<part>-test.sh`, cut from the old file at
   case boundaries (old lines 829, 1225, 1455), each with its cases in their
   old order: `rounds` (the publication, the base, the completion gate, the
   review rounds, the stops for the owner), `verification` (retries, the
   run's own verification and its repairs, a moved base, forged artifacts),
   `fixes` (fix sessions, refuted findings, a changed base), `policy` (risk
   levels and policy, light triage and profiles, publication by hand,
   budgets). The helpers that
   the old file defines between its cases (`log_of`, `awaiting`,
   `interventions`, `resumptions`, `full_verifications`, `move_base_script`,
   `refuted`) and the reply variables stay with the cases that use them,
   except `log_of`, `full_verifications`, and `ask`, which several parts use
   and which move to the lib. Two blocks that check the run of the case
   `clean` and were separated from it by the cases `develop-base` and
   `hinted` move up to that case (the risk level of the run, and a repeated
   command that only publishes); they read only the repository of `clean`.
3. Every case gets a line `scenario <id>` before its `setup_repo`: the label
   of the repository, or for a loop the label without its loop variable
   (`blocked-without-question`, `agent-exits`, `fixes-fail-once`,
   `profile-docs`, `profile-medium`; `fixes-$value` is `fixes-inconclusive`).
4. `tests/scenario-register-test.sh`: the register agrees with the parts,
   every part is a check of `scripts/verify-workflow.conf`, and the check
   fails on each fault: an identifier defined twice (in two parts, and in one
   part), one listed and not run, one run and not listed, and one listed
   twice.
5. `scripts/verify.sh` (`select_changed_tests`, `shared_test_parts`): a test
   that sources `tests/lib-<y>.sh`, where `scripts/<y>.sh` exists, is
   selected for a change to `scripts/<y>.sh`, `scripts/lib/<y>.sh`, or
   `tests/lib-<y>.sh`. `tests/lib-fakes.sh` belongs to no script and still
   selects nothing by itself (#443 point 1 is a separate decision). Tested
   in `tests/verify-test.sh`.
6. `scripts/verify-workflow.conf`: `paths:` adds `tests/lib-run-feature.sh`;
   the four parts replace `run-feature` and are listed first, so that
   `adopted-project` (which starts the self-tests in the order of the file)
   starts the longest first; `scenario-register` replaces nothing.
   `.agents/template.conf` `paths:` adds `tests/lib-run-feature.sh`, so that
   a project that syncs the template gets the file its parts source.
7. Docs: `docs/development.md` ("Partial runs" on `--changed`, "Workflow
   self-tests" on the parts, the register, and the order), the references
   in `tests/records-test.sh` and `tests/base-test.sh`. The website does not
   describe the mapping or the test files; no change there.
   `tests/check-docs-test.sh` builds its fixture without the website from
   the worktree as verified: new untracked files too, and a file the
   worktree deleted as committed (check-docs accepts a name of a file the
   feature removed, and the copy has no history). Before, it copied only
   tracked files and failed on the docs naming the new parts.

## Balance

The parts are balanced by the measured duration of each case (a timed run
of the old file on the host of this run, 680 s in all, against 687 s on the
owner's host in #446), not by line count.
Measured on the host of this run, each test alone, base `fb9ca4b`:

| Test | Before | After |
|---|---|---|
| `run-feature` (one file) | 680 s | removed |
| `run-feature-rounds` | | 185 s |
| `run-feature-verification` | | 149 s |
| `run-feature-fixes` | | 162 s |
| `run-feature-policy` | | 195 s (28 % of 687 s) |
| `adopted-project` | 863 s | 448 s |

The sum of the self-tests, the wall-clock of `./scripts/verify.sh --all`,
and the CI duration of `verify` come from the full verification of the run
and from the CI of the pull request.

Cases: the 91 `setup_repo` cases of the removed run-feature-test.sh on main and
the 91 of the parts have the same labels (`grep -oE 'setup_repo "?[^")]+'`
over each, sorted; the difference is empty), and the 91 scenario
identifiers are those labels (loops as in step 3). Assertions (`fail` and
`expect_*` calls, comments and definitions excluded): 521 on main, 507 in
the parts and 18 in `tests/lib-run-feature.sh` (14 moved, 4 new), 525.

## Not in scope

Parallel CI jobs (step 6 of #345), `parallel:` in `verify.sh` (step 7), and
adding `tests/lib-run-feature.sh` to `test-fixtures:` of the risk policy
(`.agents/policies`, the owner's decision).
