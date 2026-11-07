---
title: "Updating an Agent Codeyard project"
description: "Take over template changes in a project that started from the template, while keeping your project settings."
order: 8
---

This page is for a project that was created from Agent Codeyard with `gh repo create --template`, or that adopted it. `sync-template.sh` is not the way to adopt it: an existing repository that did not start from the template adopts the workflow first, as <a href="../adopting/">Adopting Agent Codeyard in an existing repository</a> describes, and syncs afterwards.

<a id="update-an-existing-project"></a>

## Update the project

A repository created from the template does not receive later improvements of the workflow. To bring them over, run this from your repository, with no uncommitted changes:

```
./scripts/sync-template.sh
```

It updates only the files that belong to the template, and never commits or pushes. On `main` it first creates a branch; on another branch it works there, so start from `main` to keep the update apart from other work. Your code, your plan, and your own checks are not touched.

<a id="sync"></a>
<a id="keeping-a-project-up-to-date"></a>

## Which files it changes

- It touches only the files listed under `paths:` in [`.agents/template.conf`](https://github.com/taspinar/agent-codeyard/blob/main/.agents/template.conf): the workflow scripts, prompts, policies, schemas, the CI and guardrails workflows, and the workflow documentation. Your code, your requirements, your roadmap, and your `scripts/verify.conf` stay yours. `LICENSE` stays yours too.
- A file you did not change is replaced. A file both sides changed is merged, and a conflict is left in the file and reported. A file the template removed is reported, never deleted.
- Newly owned files are copied only when absent or safely matched; local content is protected.
- To keep a listed file as your own, add `:(exclude)<path>` to the list.

What each file in the repository is for is in the [project map](https://github.com/taspinar/agent-codeyard/blob/main/docs/project-map.md).

## Versions and conflicts

Work on a branch and inspect the listed template commits. `--from <commit>` chooses a known starting version, `--to <ref>` a target, and `--template <url-or-path>` another source. Without a recorded version, the script compares files to historical template versions; an ambiguous match stops for your `--from` choice, with the oldest the safe choice. It records the new version in `.agents/template.conf`.

A conflict exits with status 1 and leaves the conflict for you to resolve. Review the result, resolve conflicts, run `./scripts/verify.sh --all`, commit and open a pull request.

See [Taking over template changes](https://github.com/taspinar/agent-codeyard/blob/main/docs/development.md#taking-over-template-changes) for the full merge table and version-selection rules.
