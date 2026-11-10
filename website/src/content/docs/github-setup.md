---
title: "GitHub setup"
description: "Configure the settings that enforce pull requests, checks and owner review."
order: 7
---

A repository created from the template does not inherit these settings: GitHub does not copy them. Take the steps in order, and check each one before the next. The `gh` commands run in your repository; `gh` fills in `{owner}` and `{repo}` itself.

<a id="checklist"></a>
<a id="repository-setup-checklist"></a>

## Step by step

1. **Enable Issues and GitHub Actions.** The workflow keeps every feature in an Issue, and CI runs in Actions.
   - Where: **Settings → General → Features**, and **Settings → Actions → General**.
   - Check: the **Actions** tab of the repository lists the workflows, and this says `true`:

     ```
     gh repo view --json hasIssuesEnabled --jq .hasIssuesEnabled
     ```

2. **Merge by squash only, and delete merged branches.** Allow squash merging; turn off merge commits and rebase merging; turn on automatically deleting head branches.
   - Where: **Settings → General → Pull Requests**.
   - Check: this shows `squashMergeAllowed` and `deleteBranchOnMerge` as `true`, the other two as `false`:

     ```
     gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,deleteBranchOnMerge
     ```

3. **Protect `main` with a ruleset.** Target the default branch; restrict deletions, block force pushes, and require a pull request before merging. Rulesets are available for public repositories with GitHub Free and GitHub Free for organizations, and for public and private repositories with GitHub Pro, GitHub Team and GitHub Enterprise Cloud ([GitHub's documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)).
   - Where: **Settings → Rules → Rulesets → New branch ruleset**.
   - Check: this lists the rules `deletion`, `non_fast_forward` and `pull_request`:

     ```
     gh api 'repos/{owner}/{repo}/rules/branches/main' --jq '.[].type'
     ```

4. **Require the `verify` check.** Without a required check, a pull request can be merged while CI fails. GitHub knows a check only by the name a CI job reported, and it offers only names that it has seen on the repository, so open a first pull request, let CI run, then add `verify` under "Require status checks to pass" in the same ruleset. Do not require a check that no workflow produces: GitHub waits for it forever, and that blocks every merge.
   - Where: the ruleset of step 3.
   - Check: `./scripts/doctor.sh` no longer warns that `main` has no required check, and the rules of step 3 now include `required_status_checks`.
   - The `guardrails` check: alone, leave it optional; in a team, or when an agent may merge, require it as well. It is explained under [What the `guardrails` check shows](#guardrails-check).
5. **Name yourself as code owner.** Replace `@YOUR_GITHUB_USERNAME` in `.github/CODEOWNERS` with your account or team, through a pull request.
   - Where: `.github/CODEOWNERS`.
   - Check: this prints nothing:

     ```
     grep YOUR_GITHUB_USERNAME .github/CODEOWNERS
     ```

6. **Decide on reviews: alone or in a team.** This is the one step where the answer depends on who works in the repository.
   - **Alone:** leave required approvals at 0 and "Require review from Code Owners" off. GitHub does not let you approve your own pull request, so requiring a review would block your own merges. You rely on the workflow's merge approval statement, which names the pull requests that need you, and you merge them yourself.
   - **In a team:** require at least one approval and turn on "Require review from Code Owners", so that a change to a protected path needs the review of a code owner who did not open it.
   - Where: the ruleset of step 3, under "Require a pull request before merging".
   - Check: the ruleset shows the required approvals and "Require review from Code Owners" as you chose.
7. **Decide on bypass rights.** A repository administrator can usually bypass a ruleset. Decide whether that should apply to you.
   - Where: the ruleset's **Bypass list**.
   - Check: the bypass list holds only who you chose.
8. **Keep Actions read-only by default.** Choose the read-only default workflow permissions; a job that needs write access asks for it in its own `permissions:`.
   - Where: **Settings → Actions → General → Workflow permissions**.
   - Check: this shows `default_workflow_permissions` as `read`:

     ```
     gh api 'repos/{owner}/{repo}/actions/permissions/workflow'
     ```

9. **Turn on the security features where available.** Dependency graph, Dependabot alerts and security updates, secret scanning and push protection; what is offered depends on the visibility and the plan of the repository.
   - Where: **Settings → Code security**.
   - Check: the page shows each feature as enabled.

Keep secrets out of Git. For production, use environment approvals and short-lived identity federation where supported; production data and infrastructure changes need explicit human approval. The [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md) is the full checklist with the reasons, including optional Google Cloud, database and deployment controls. Only the template repository itself needs the “Template repository” setting.

<a id="github"></a>

## What GitHub has to enforce

The gate is a check and a statement. `check-guardrails.sh` checks locally; on every pull request the Guardrails workflow (`pull_request_target`) shows the result as the `guardrails` check. The commit and pull request carry a “Merge approval: required” statement. It tells you which pull requests need your attention, and the workflow's own scripts will not merge them. It does **not** stop someone, or an agent with your credentials, from merging on GitHub. To enforce the rules, configure the repository:

- **A ruleset for `main`** that requires a pull request and the CI check before a merge. `./scripts/doctor.sh` warns you when the check is not required. The [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md) lists the settings.
- **`.github/CODEOWNERS`** ships with the placeholder `@YOUR_GITHUB_USERNAME`. Replace it with your own account before you require code owner reviews; until then the file has no effect.
- **Bypass rights:** a repository administrator can usually bypass a ruleset. Decide whether that should apply to you.

<a id="guardrails-check"></a>

### What the `guardrails` check shows

| The pull request | The `guardrails` check |
| --- | --- |
| changes nothing that needs you | passes: “No owner approval needed” |
| changes a protected path and carries a valid approval request | “Action required”: “Owner approval required”, with the paths and the reasons. Not a defect: it waits for you |
| changes a protected path without an approval request, or with one that is malformed or names other content | fails, with the reason. Something is wrong; do not merge |

The job behind it, `Approval gate`, fails only in the last case. GitHub counts “Action required” as not passed, so a **required** `guardrails` check blocks the merge of a protected change until someone with bypass rights merges it. Alone, leave it optional and merge after your review. In a team, or when an agent may merge, require it and keep bypass rights for the people who approve. Never require `Approval gate`: it passes while your approval is still needed. The [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md) has the details.

The complete list of settings is the [repository setup checklist](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md). What to keep out of a repository, and how to report a security problem, is in [`SECURITY.md`](https://github.com/taspinar/agent-codeyard/blob/main/SECURITY.md).

**One identity:** an agent runs with the GitHub permissions of the account that started it. If that account may merge, so may the agent, and no script can prevent it. A separate GitHub identity with limited permissions for agents is not built yet ([Issue 99](https://github.com/taspinar/agent-codeyard/issues/99)).

<a id="keeping-the-template-website"></a>

## Advanced: publishing this website

This section is only for a project that keeps the template's own website. Projects normally delete `website/` and its Pages workflow, `.github/workflows/pages.yml`, and skip it.

**Keep the marker.** If you keep `website/`, keep its marker `website/.codeyard-site` too: the verification and the CI check only the site that has it, and leave a `website/` of your own alone.

**Name and address.** Configure the name, repository URL, site origin and default base path in `website/site.config.ts`. Validation defaults in `website/check.sh` are separate.

**After a repository rename:**

1. Update `site.config.ts`, use `BASE_PATH=/new-repository-name/`, and update the site and repository links in `README.md` and literal source links in the content.
2. In `website/check.sh`, replace the project path (currently `/agent-codeyard/`) in the `for base in … /` list with the new project base path, retaining `/`. Keep `default_site_url` in sync with the site origin in `site.config.ts`, updating it if the owner or domain changes.
3. Update the path in the check's usage comment and `website/validation.md` too.
4. Run `website/check.sh --build` to build, link-check and browser-test the new project path and `/` in the same way as CI.

**A custom domain:**

1. Build with `SITE_URL=https://docs.example.org` and `BASE_PATH=/`.
2. Set the domain in **Settings → Pages** (source: **GitHub Actions**) and verify ownership.
3. Configure DNS: a subdomain's DNS `CNAME` points to `<owner>.github.io`, while an apex uses GitHub's documented DNS records.
4. Enable HTTPS once the certificate is ready.
5. Keep the Actions variable `PUBLISH_DOCUMENTATION=true`; the publishing workflow takes its origin and base path from the Pages configuration.

A repository `CNAME` file is ignored by this Actions-based publication; it does not replace the Pages setting or DNS. Branch-based publication would need it in the published root (Astro could copy `public/CNAME`). Follow the [repository setup guide](https://github.com/taspinar/agent-codeyard/blob/main/docs/repository-setup.md#13-template-website-a-rename-or-custom-domain) and [GitHub's current domain instructions](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site) when you change the name or the address. The template's own site took these steps once: its repository is `taspinar/agent-codeyard`, and it is served from `https://agentcodeyard.com/`.
