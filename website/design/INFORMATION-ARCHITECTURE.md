# Information architecture: five destinations

Step 1 of the tracking Issue #371 (this step: #372). A plan for the owner's
approval: it changes no page, route, component or style. Once merged, it is
the source for where content goes and which old URL leads where, for the
steps #373 to #377 and for the home page of #370 where it touches them.

The site had 22 routes when this plan was made (the sitemap of the build).
Since #390 it has four destinations in the header, Home, Features, About and
Docs (then GitHub), plus one appendix page of the docs, History; Projects
stays at its route, unlisted; every other old route is a redirect.

| Header label | Route | Role |
|---|---|---|
| Home | `/` | first impression, value, the interactive demo (#370) |
| Features | `/features/` | what Codeyard adds, three themes and a short FAQ (#374) |
| About | `/about/` | the maker, why it exists, open source (#376) |
| Docs | `/docs/` | Technical Documentation, one interface (#373); its Appendix is `/docs/history/` |
| (none, unlisted since #390) | `/examples/` (kept) | Projects: real cases with sources (#375), linked from no page |

**Get Started** is an action, not a page: `/docs/#quick-start`. Since #390 it
is a link of the home page, not of the header.

**Changed by #390** (the owner's brief of 12 November 2026, section 8): the
header is Home, Features, About, Docs and GitHub, without Projects and without
Get Started; `/examples/` stays at its URL but is unlisted; Engineering
records was removed and redirects to `/docs/history/`, the one Appendix page.
Where this plan says otherwise, section 8 replaces it.

How this document was made: the site was built from the branch of this step
(`npx astro build` in `website/`), and the routes, headings and ids were read
from `dist/`; the inbound links come from `git grep` over the repository and
from the bodies and comments of all 207 Issues and 170 pull requests
(`gh issue list --state all`, `gh pr list --state all`), read on
11 November 2026.

Contents:

1. Inventory
2. Content mapping
3. URL and anchor migration
4. Docs interface
5. Source hierarchy
6. Conflicts
7. The order of the following steps
8. The owner's brief of 12 November 2026 (#390)

---

## 1. Inventory

**A record of the site before the steps, not of the current site.** This
section is the inventory of 11 November 2026, before #373 to #377 and #390:
the routes, anchors, header, footer and links it lists are the old ones that
section 3 maps. Several no longer exist as listed: `/workflow/`, `/faq/` and
`/docs/engineering-records/` are redirect pages, the header and footer
changed with #377 and #390 (the header is that of section 8), and no page links Engineering records or `/examples/`.
The current routes are in 3.3 and 3.4, the current header in section 8.

### 1.1 Routes

On 11 November 2026 the sitemap listed 22 routes, and `search-test.mjs`
asserted the same 22 (now the listed routes of 3.4) and that every anchor of `legacy-anchors.json` (the ids of the live site on
9 November 2026) still resolves on its route; every id of that file is among
the ids listed below.

| # | Route | Source | Title |
|---|---|---|---|
| 1 | `/` | `website/src/pages/index.astro` | (home) |
| 2 | `/workflow/` | `website/src/pages/workflow.astro` | How it works |
| 3 | `/features/` | `website/src/pages/features.astro` | Why Codeyard |
| 4 | `/examples/` | `website/src/pages/examples.astro` | Projects |
| 5 | `/about/` | `website/src/pages/about.astro` | About |
| 6 | `/faq/` | `website/src/pages/faq.astro` | FAQ |
| 7 | `/docs/adopting/` | `website/src/content/docs/adopting.md` | Adopting Agent Codeyard in an existing repository |
| 8 | `/docs/agent-roles/` | `website/src/content/docs/agent-roles.md` | Agent roles and models |
| 9 | `/docs/configuration-and-security/` | `website/src/content/docs/configuration-and-security.md` | Configuration and security |
| 10 | `/docs/detailed-workflow/` | `website/src/content/docs/detailed-workflow.md` | How the workflow works |
| 11 | `/docs/getting-started/` | `website/src/content/docs/getting-started.md` | Getting started |
| 12 | `/docs/github-setup/` | `website/src/content/docs/github-setup.md` | GitHub setup |
| 13 | `/docs/` | `website/src/content/docs/index.mdx` | Documentation |
| 14 | `/docs/new-to-agentic-coding/` | `website/src/content/docs/new-to-agentic-coding.md` | New to agentic coding? Start here |
| 15 | `/docs/risk-policy/` | `website/src/content/docs/risk-policy.md` | Risk policy and workflow profiles |
| 16 | `/docs/technical-reference/` | `website/src/content/docs/technical-reference.md` | Technical reference (advanced) |
| 17 | `/docs/troubleshooting/` | `website/src/content/docs/troubleshooting.md` | Troubleshooting |
| 18 | `/docs/updating/` | `website/src/content/docs/updating.md` | Updating an Agent Codeyard project |
| 19 | `/docs/verification-and-completion/` | `website/src/content/docs/verification-and-completion.md` | Verification and completion |
| 20 | `/docs/reference/workflow/` | `website/src/pages/docs/reference/workflow.astro` (from `src/lib/steps.ts`) | Workflow reference |
| 21 | `/docs/engineering-records/` | `website/src/pages/docs/engineering-records.astro` | Engineering records |
| 22 | `/docs/history/` | `website/src/pages/docs/history.astro` | History and research |

Not routes of the inventory: `404.html`, `robots.txt`, `sitemap.xml`,
`search-index.json`, `og.png`, fonts and images. They stay as they are; the
sitemap and the search index change with the routes (see 3.4).

### 1.2 Anchors per route

Every heading with an id, and every other `id` of the page. "Interface ids"
belong to the layout, not to the content: `main` (the skip link's target) on
every page, and `docs-query`, `search-status` and `search-results` of the docs
search on every docs page. A heading without an id cannot be linked and is not
listed, nor is a `summary` without one.

#### 1. `/` — Build software with AI, with a clear plan and checks along the way.

| Anchor | Element | Text |
|---|---|---|
| `#why-h` | h2 | Why not start building straight away? |
| `#example-h` | h2 | One example in four steps |
| `#roles-h` | h2 | Who does what |
| `#who-h` | h2 | Who it is for |
| `#start-h` | h2 | Start, or read further |

Other ids: `why`, `example`, `roles`, `who`, `start`, `projects`.

Interface ids: `main`.

#### 2. `/workflow/` — From your idea to a change you decide on.

| Anchor | Element | Text |
|---|---|---|
| `#overview-h` | h2 | Four steps, in one example |
| `#technical-h` | h2 | The technical workflow |
| `#workflow-title` | h3 | The route of a change, as a map |
| `#step-panel-h` | h3 | (set by script) |
| `#ways-h` | h2 | Step by step or unattended |
| `#case-h` | h2 | How these pages were built |
| `#steps-h` | h2 | Every step in detail |

Other ids: `overview`, `describe-and-clarify`, `plan-the-work`, `build-and-check`, `decide`, `technical`, `explore`, `workflow`, `workflow-map-title`, `step-panel`, `step-tab-overview`, `step-tab-technical`, `step-tab-failure`, `step-tab-body`, `routes-label`, `workflow-words`, `ways`, `case`, `steps`, `describe-the-idea`, `clarify-the-requirements`, `create-the-plan`, `review-the-plan`, `address-the-findings`, `approve-the-plan`, `merge-the-plan`, `change-the-plan`, `create-a-feature-issue`, `implement-the-feature`, `run-the-checks`, `review-the-code`, `decide-on-the-findings`, `apply-the-fixes`, `commit-the-feature`, `open-the-pull-request`, `merge`, `run-unattended`.

Interface ids: `main`.

#### 3. `/features/` — Why Codeyard

| Anchor | Element | Text |
|---|---|---|
| `#planning-h` | h2 | Before coding starts |
| `#requirements-h` | h3 | Agree on what to build before coding starts |
| `#architecture-h` | h3 | Give every feature the same project plan |
| `#isolation-h` | h3 | Keep changes separate while they are being built |
| `#quality-h` | h2 | Before a change reaches you |
| `#evidence-h` | h3 | See what was checked against your requirements |
| `#review-h` | h3 | Give each change a second review |
| `#risk-h` | h3 | Risk-based checks: more scrutiny where a change can do harm |
| `#control-h` | h2 | Autonomy with limits |
| `#unattended-h` | h3 | Let AI agents work while you are away, and stop where you are needed |
| `#authority-h` | h3 | You hold the last word on every change |
| `#learn-h` | h2 | A self-improving process that learns from its own runs |

Other ids: `planning`, `requirements`, `requirements-t`, `requirements-words`, `architecture`, `planning-t`, `planning-words`, `isolation`, `isolation-t`, `isolation-words`, `quality`, `evidence`, `evidence-t`, `evidence-words`, `review`, `review-t`, `review-words`, `risk`, `risk-t`, `risk-words`, `control`, `unattended`, `unattended-t`, `unattended-words`, `authority`, `authority-t`, `authority-words`, `learn`, `learn-t`, `learn-words`.

Interface ids: `main`.

#### 4. `/examples/` — Projects

| Anchor | Element | Text |
|---|---|---|
| `#products-h` | h2 | Products |
| `#fightanalytics-h` | h3 | FightAnalytics, a platform for gyms |
| `#application-h` | h3 | Physics by Construction, a physics course |
| `#figures-h` | h2 | About the figures |
| `#absent-h` | h3 | What is not shown |
| `#sources-h` | h3 | Where the figures come from |

Other ids: `products`, `fightanalytics`, `application`, `figures`, `absent`, `sources`, `engineering`, `memory`, `story`, `tradeoff`, `features`, `owner`, `repair`, `short`, `analysis`, `levels`.

Interface ids: `main`.

#### 5. `/about/` — About

| Anchor | Element | Text |
|---|---|---|
| `#maker-h` | h2 | The maker, JIDAI and the project |
| `#limits-h` | h2 | What it does, in short |
| `#contribute-h` | h2 | Ready to use, open to contributions |
| `#source-h` | h2 | Source and licence |

Other ids: `maker`, `history`, `why`, `decisions`, `research`, `improvements`, `limits`, `contribute`, `source`.

Interface ids: `main`.

#### 6. `/faq/` — FAQ

| Anchor | Element | Text |
|---|---|---|
| `#what-h` | h2 | What does Agent Codeyard do? |
| `#replace-h` | h2 | Why use it next to Claude Code or Codex? |
| `#who-h` | h2 | Do I need to be able to program? |
| `#software-h` | h2 | What software can I build or maintain with it? |
| `#existing-h` | h2 | Can I use an existing project? |
| `#permission-h` | h2 | What do I still do myself? |
| `#cost-h` | h2 | What does it cost, and why does that differ per project? |
| `#too-heavy-h` | h2 | When is this way of working worth it? |
| `#checked-h` | h2 | How do I know what was checked? |
| `#wrong-h` | h2 | What happens when the AI gets stuck or does something wrong? |
| `#data-h` | h2 | Where does it run, and which data goes to the AI providers? |
| `#online-h` | h2 | Is the software also put online automatically? |
| `#environments-h` | h2 | Which computers does it run on? |
| `#stop-h` | h2 | How do I stop a run, and continue it? |
| `#unattended-h` | h2 | What does an unattended run do without me? |
| `#review-h` | h2 | Is every change reviewed? |

Other ids: `what`, `replace`, `who`, `software`, `existing`, `permission`, `cost`, `too-heavy`, `checked`, `wrong`, `data`, `online`, `environments`, `stop`, `unattended`, `review`.

Interface ids: `main`.

#### 7. `/docs/adopting/` — Adopting Agent Codeyard in an existing repository

| Anchor | Element | Text |
|---|---|---|
| `#the-three-steps` | h2 | The three steps |
| `#the-normal-route` | h2 | The normal route |
| `#1-assess` | h3 | 1. Assess |
| `#2-adopt` | h3 | 2. Adopt |
| `#3-record-the-baseline` | h3 | 3. Record the baseline |
| `#after-the-merge` | h3 | After the merge |
| `#existing-files` | h2 | Existing files |
| `#monorepos-and-subdirectories` | h2 | Monorepos and subdirectories |
| `#the-base-branch` | h2 | The base branch |
| `#baseline-exceptions` | h2 | Baseline exceptions |
| `#what-is-preserved` | h2 | What is preserved |
| `#limits` | h2 | Limits |

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 8. `/docs/agent-roles/` — Agent roles and models

| Anchor | Element | Text |
|---|---|---|
| `#the-roles-in-plain-words` | h2 | The roles in plain words |
| `#role-tool-provider-and-model` | h2 | Role, tool, provider and model |
| `#agent-roles-and-models` | h2 | Agent roles and models |
| `#shipped-configuration` | h2 | Shipped configuration |
| `#further-configuration` | h2 | Further configuration |
| `#one-run-with-another-tool-or-model` | h3 | One run with another tool or model |
| `#models-per-risk-level` | h3 | Models per risk level |
| `#project-skills` | h3 | Project skills |

Other ids: `terms`, `roles`, `default-configuration`, `overrides`, `risk-levels`, `skills`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 9. `/docs/configuration-and-security/` — Configuration and security

| Anchor | Element | Text |
|---|---|---|
| `#the-limits-in-short` | h2 | The limits in short |
| `#what-an-agent-is-allowed-to-do` | h2 | What an agent is allowed to do |
| `#which-data-goes-where` | h2 | Which data goes where |
| `#github-rights` | h2 | GitHub rights |
| `#changes-that-need-the-owner` | h2 | Changes that need the owner |
| `#agent-attribution` | h2 | Agent attribution |

Other ids: `profiles`, `unattended`, `data`, `gate`, `attribution`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 10. `/docs/detailed-workflow/` — How the workflow works

| Anchor | Element | Text |
|---|---|---|
| `#daily-use` | h2 | Daily use |
| `#step-by-step-or-unattended` | h3 | Step by step or unattended |
| `#resume-a-feature-that-stopped` | h3 | Resume a feature that stopped |
| `#when-the-plan-changes` | h3 | When the plan changes |
| `#a-base-branch-other-than-main` | h3 | A base branch other than main |
| `#features-side-by-side` | h3 | Features side by side |
| `#a-plan-for-a-complex-issue` | h3 | A plan for a complex Issue |
| `#what-each-step-is-for` | h2 | What each step is for |
| `#stage-1--plan-the-project` | h3 | Stage 1 · Plan the project |
| `#stage-2--build-each-feature` | h3 | Stage 2 · Build each feature |
| `#when-you-disagree-and-exceptions` | h2 | When you disagree, and exceptions |
| `#when-you-disagree-with-the-triage` | h3 | When you disagree with the triage |
| `#when-you-disagree-with-a-blocking-finding` | h3 | When you disagree with a blocking finding |
| `#skipping-a-review` | h3 | Skipping a review |

Other ids: `choices-along-the-route`, `resume`, `plans-and-earlier-review-rounds`, `steps`, `every-step-in-detail`, `step-idea`, `describe-the-idea`, `step-grill`, `clarify-the-requirements-project-grill`, `step-plan`, `create-the-project-plan`, `step-planning-review`, `review-the-plan`, `step-revise`, `address-the-review-findings`, `step-finish-planning`, `approve-the-plan`, `step-planning-merge`, `merge-the-planning-pull-request`, `step-change`, `update-an-approved-plan`, `step-issue`, `create-a-feature-issue`, `step-implement`, `implement-the-feature`, `step-verify`, `run-verification`, `step-review`, `review-the-implementation`, `step-triage`, `decide-what-to-do-with-review-findings`, `step-fix`, `apply-fixes-and-review-again`, `step-commit`, `commit-the-feature`, `step-publish`, `open-the-pull-request`, `step-merge`, `review-and-merge`, `step-run`, `run-a-feature-unattended`, `owner-directed-triage`, `owner-exception`, `skipping-a-review-explicitly`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 11. `/docs/getting-started/` — Getting started

| Anchor | Element | Text |
|---|---|---|
| `#before-you-start` | h2 | Before you start |
| `#1-sign-in` | h2 | 1. Sign in |
| `#2-create-your-repository` | h2 | 2. Create your repository |
| `#3-set-up-github` | h2 | 3. Set up GitHub |
| `#4-check-your-setup` | h2 | 4. Check your setup |
| `#5-choose-your-agents` | h2 | 5. Choose your agents |
| `#6-plan-your-project` | h2 | 6. Plan your project |
| `#7-require-the-ci-check` | h2 | 7. Require the CI check |
| `#8-build-your-first-feature` | h2 | 8. Build your first feature |

Other ids: `what-you-need`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 12. `/docs/github-setup/` — GitHub setup

| Anchor | Element | Text |
|---|---|---|
| `#step-by-step` | h2 | Step by step |
| `#what-github-has-to-enforce` | h2 | What GitHub has to enforce |
| `#what-the-guardrails-check-shows` | h3 | What the guardrails check shows |
| `#advanced-publishing-this-website` | h2 | Advanced: publishing this website |

Other ids: `checklist`, `repository-setup-checklist`, `github`, `guardrails-check`, `keeping-the-template-website`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 13. `/docs/` — Documentation

| Anchor | Element | Text |
|---|---|---|
| `#what-stays-with-you` | h2 | What stays with you |
| `#find-a-command-or-setting` | h2 | Find a command or setting |
| `#more-to-read` | h2 | More to read |
| `#sources-and-scope` | h2 | Sources and scope |

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 14. `/docs/new-to-agentic-coding/` — New to agentic coding? Start here

| Anchor | Element | Text |
|---|---|---|
| `#one-feature-from-idea-to-decision` | h2 | One feature, from idea to decision |
| `#the-idea` | h3 | The idea |
| `#clarify-what-you-need` | h3 | Clarify what you need |
| `#the-project-folder` | h3 | The project folder |
| `#a-coding-agent-builds-it` | h3 | A coding agent builds it |
| `#a-change-proposal` | h3 | A change proposal |
| `#a-second-agent-reviews-it` | h3 | A second agent reviews it |
| `#you-decide` | h3 | You decide |
| `#what-agent-codeyard-adds` | h2 | What Agent Codeyard adds |
| `#when-codeyard-is-relevant` | h2 | When Codeyard is relevant |
| `#what-to-read-next` | h2 | What to read next |
| `#glossary` | h2 | Glossary |

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 15. `/docs/risk-policy/` — Risk policy and workflow profiles

| Anchor | Element | Text |
|---|---|---|
| `#a-typo-and-a-change-to-authentication` | h2 | A typo and a change to authentication |
| `#what-a-level-changes-in-practice` | h2 | What a level changes in practice |
| `#three-settings-with-similar-names` | h3 | Three settings with similar names |
| `#the-risk-level-of-a-feature` | h2 | The risk level of a feature |
| `#shipped-configuration` | h2 | Shipped configuration |
| `#the-risk-policy` | h2 | The risk policy |
| `#classes-of-paths` | h3 | Classes of paths |
| `#what-each-level-requires` | h3 | What each level requires |
| `#workflow-profiles` | h3 | Workflow profiles |
| `#fixed-escalations` | h3 | Fixed escalations |

Other ids: `in-practice`, `three-settings`, `risk`, `policy-settings`, `escalations`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 16. `/docs/technical-reference/` — Technical reference (advanced)

| Anchor | Element | Text |
|---|---|---|
| `#files-by-function` | h2 | Files by function |
| `#what-is-recorded-on-your-machine` | h2 | What is recorded on your machine |
| `#learning-from-your-runs` | h2 | Learning from your runs |
| `#rules-and-configuration` | h2 | Rules and configuration |
| `#project-documents` | h2 | Project documents |
| `#workflow-scripts` | h2 | Workflow scripts |
| `#script-libraries` | h2 | Script libraries |
| `#agent-contracts-and-schemas` | h2 | Agent contracts and schemas |
| `#working-directories` | h2 | Working directories |
| `#website-files` | h2 | Website files |
| `#source-ownership` | h2 | Source ownership |

Other ids: `by-function`, `records`, `learning`, `rules`, `documents`, `scripts`, `libraries`, `contracts`, `directories`, `website`, `ownership`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 17. `/docs/troubleshooting/` — Troubleshooting

| Anchor | Element | Text |
|---|---|---|
| `#starting-and-resuming` | h2 | Starting and resuming |
| `#-is-not-installed-or-github-is-not-signed-in` | h3 | “… is not installed”, or GitHub is not signed in |
| `#an-agent-does-not-start-or-rejects-the-model` | h3 | An agent does not start, or rejects the model |
| `#a-session-or-a-run-was-interrupted` | h3 | A session or a run was interrupted |
| `#an-agent-needs-a-decision-its-question-is-in-the-handoff-note` | h3 | “an agent needs a decision; its question is in the handoff note” |
| `#the-implementer-wrote-no-completion-record-or-the-handoff-note--lists-remaining-work` | h3 | “the implementer wrote no completion record”, or “the handoff note … lists remaining work” |
| `#this-is-a-usage-limit-of--not-a-defect` | h3 | “This is a usage limit of …, not a defect” |
| `#could-not-read-the-comments-of-issue-` | h3 | “could not read the comments of Issue #…” |
| `#checks-and-reviews` | h2 | Checks and reviews |
| `#a-check-fails` | h3 | A check fails |
| `#busy--the-slot-for-heavy-verification-of-this-machine-is-held-by-` | h3 | “BUSY the slot for heavy verification of this machine is held by …” |
| `#the-reviewer-would-use--the-provider-the-implementer-ran-with` | h3 | “the reviewer would use …, the provider the implementer ran with” |
| `#the-latest-review--is-stale-the-code-changed-after-it` | h3 | “the latest review (…) is stale: the code changed after it” |
| `#the-latest-review-round--covers-only-the-changes-since-round-` | h3 | “the latest review (round …) covers only the changes since round …” |
| `#a-review-has-findings` | h3 | A review has findings |
| `#the-implementer-refuted-every-finding-left-to-fix-in-round-` | h3 | “the implementer refuted every finding left to fix in round …” |
| `#planning` | h2 | Planning |
| `#the-planning-has-not-been-approved-or-a-planning-document-changed-after-the-planning-was-approved` | h3 | “the planning has not been approved”, or “a planning document changed after the planning was approved” |
| `#the-latest-planning-review--is-stale` | h3 | “the latest planning review (…) is stale” |
| `#commit-and-publish` | h2 | Commit and publish |
| `#-must-run-on-feature--current-branch-` | h3 | “… must run on feature/-*. Current branch: …” |
| `#the-base-branch-moved-after-the-feature-was-finished` | h3 | The base branch moved after the feature was finished |
| `#merging-origin-conflicts-with-the-feature-in-` | h3 | “Merging origin/… conflicts with the feature in: …” |
| `#left-behind-by-a-merge-of-the-base` | h3 | “Left behind by a merge of the base” |
| `#-would-write-over--untracked-files-` | h3 | “… would write over … untracked files …” |
| `#the-index-holds-staged-changes` | h3 | “The index holds staged changes” |

Other ids: `if-something-goes-wrong`, `start-and-resume`, `setup-and-agents`, `handles`, `situations-the-workflow-handles`, `stopped-or-interrupted-runs`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 18. `/docs/updating/` — Updating an Agent Codeyard project

| Anchor | Element | Text |
|---|---|---|
| `#update-the-project` | h2 | Update the project |
| `#which-files-it-changes` | h2 | Which files it changes |
| `#versions-and-conflicts` | h2 | Versions and conflicts |
| `#a-conflict-and-the-next-step` | h3 | A conflict, and the next step |

Other ids: `update-an-existing-project`, `sync`, `keeping-a-project-up-to-date`, `a-conflict`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 19. `/docs/verification-and-completion/` — Verification and completion

| Anchor | Element | Text |
|---|---|---|
| `#the-agent-says-done-against-verified-done` | h2 | “The agent says done” against “verified done” |
| `#one-criterion-and-its-evidence` | h3 | One criterion and its evidence |
| `#completion-is-recorded-per-criterion` | h2 | Completion is recorded per criterion |
| `#project-checks-and-workflow-checks` | h2 | Project checks and workflow checks |
| `#advanced-settings` | h2 | Advanced settings |
| `#partial-checks-and-budgets` | h3 | Partial checks and budgets |
| `#a-parallel-ci` | h3 | A parallel CI |
| `#failures-that-existed-before-the-adoption` | h3 | Failures that existed before the adoption |
| `#heavy-checks-on-a-shared-machine` | h3 | Heavy checks on a shared machine |

Other ids: `verification`, `advanced`, `parallel-ci`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 20. `/docs/reference/workflow/` — Workflow reference

| Anchor | Element | Text |
|---|---|---|
| `#index` | h2 | Step index |
| `#parameters` | h2 | Parameters |
| `#plan-the-project` | h2 | Plan the project |
| `#describe-the-idea-h` | h3 | Describe the idea |
| `#clarify-the-requirements-h` | h3 | Clarify the requirements |
| `#create-the-plan-h` | h3 | Create the plan |
| `#review-the-plan-h` | h3 | Review the plan |
| `#address-the-findings-h` | h3 | Address the review findings |
| `#approve-the-plan-h` | h3 | Approve the plan |
| `#merge-the-plan-h` | h3 | Merge the planning pull request |
| `#change-the-plan-h` | h3 | Change an approved plan |
| `#build-each-feature` | h2 | Build each feature |
| `#create-a-feature-issue-h` | h3 | Create a feature Issue |
| `#implement-the-feature-h` | h3 | Implement the feature |
| `#run-the-checks-h` | h3 | Run the checks |
| `#review-the-code-h` | h3 | Review the code |
| `#decide-on-the-findings-h` | h3 | Decide on the findings |
| `#apply-the-fixes-h` | h3 | Fix and review again |
| `#commit-the-feature-h` | h3 | Commit the feature |
| `#open-the-pull-request-h` | h3 | Open the pull request |
| `#merge-h` | h3 | Review and merge |
| `#run-unattended-h` | h3 | Run a feature unattended |

Other ids: `describe-the-idea`, `clarify-the-requirements`, `create-the-plan`, `review-the-plan`, `address-the-findings`, `approve-the-plan`, `merge-the-plan`, `change-the-plan`, `create-a-feature-issue`, `implement-the-feature`, `run-the-checks`, `review-the-code`, `decide-on-the-findings`, `apply-the-fixes`, `commit-the-feature`, `open-the-pull-request`, `merge`, `run-unattended`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 21. `/docs/engineering-records/` — Engineering records

Removed by #390: the route and every id below redirect to `/docs/history/`.

| Anchor | Element | Text |
|---|---|---|
| `#memory` | h2 | When the reviewer did not know what was decided |
| `#story` | h2 | When new pages left out their sources |
| `#tradeoff` | h2 | How many review rounds are worth it |
| `#features` | h2 | Four more problems, four more runs |
| `#owner` | h2 | When every feature got the same workflow |
| `#repair` | h2 | When a missed target sent the agent to repair |
| `#short` | h2 | When one round is enough |
| `#analysis` | h2 | What 41 recorded runs showed |
| `#levels` | h2 | What each risk level changed |
| `#absent` | h2 | What is not shown |
| `#sources` | h2 | Where the figures come from |

Other ids: `run-217-t`, `run-217-words`, `run-241-t`, `run-241-words`.

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

#### 22. `/docs/history/` — History and research

Since #390 titled "How Agent Codeyard began"; `#phases`, `#principles` and
`#decisions` are aliases at the top of the page (section 8).

| Anchor | Element | Text |
|---|---|---|
| `#phases` | h2 | In short |
| `#history` | h2 | History |
| `#principles` | h2 | Engineering principles |
| `#decisions` | h2 | Design decisions |
| `#research` | h2 | Research |

Interface ids: `main`, `docs-query`, `search-status`, `search-results`.

### 1.3 Header and footer

The header and footer of 11 November 2026, replaced by #377 and then by #390:
the header is now Home, Features, About, Docs, GitHub and the theme toggle
(section 8). They were the same on every page (`src/components/Header.astro`, `src/lib/links.ts`,
`src/components/Footer.astro`):

| Where | Label | Target |
|---|---|---|
| header | Agent Codeyard (the mark) | `/` |
| header | How it works | `/workflow/` |
| header | Why Codeyard | `/features/` |
| header | Projects | `/examples/` |
| header | Docs | `/docs/` |
| header | About | `/about/` |
| header | Get started | `/docs/getting-started/` |
| header | GitHub | `https://github.com/taspinar/agent-codeyard` |
| header | Dark / Light (theme toggle, a button) | none |
| footer | Source | the repository |
| footer | Contributing | `CONTRIBUTING.md` on `main` |
| footer | Licence | `LICENSE` on `main` |
| footer | FAQ | `/faq/` |
| footer | About | `/about/` |

Every docs page also has the docs sidebar (four groups: Begin, Use, Configure,
Reference; `src/lib/docs.ts`), its "On this page" list and previous and next
links.

### 1.4 Inbound links

**From the repository, outside `website/`:**

| Source | Link |
|---|---|
| `README.md`, line 9 and line 66 | `https://agentcodeyard.com/` |
| `docs/repository-setup.md`, line 470 | `https://agentcodeyard.com` (the custom domain, in prose) |

No script message, test outside `website/`, `AGENTS.md` or other file of
`docs/` names a site path. `docs/project-map.md` names the site's pages by
name, not by URL: "Getting started", "Configuration and security", "The
workflow page of the website", "The repository tree on the website" (see 6.9).

**From the site itself (links between pages, read from `dist/`, 11 November
2026):** since #390 no page links `/docs/engineering-records/` or `/examples/`,
and `/workflow/` and `/faq/` are redirect pages (#377); the rows below that
name them are the old links, kept as the record of what section 3 had to
redirect. Every docs
page links every other docs page through the sidebar. The deep links between
pages:

| Target | From |
|---|---|
| `/docs/adopting/#what-is-preserved` | `/faq/` |
| `/docs/configuration-and-security/#changes-that-need-the-owner` | `/features/` |
| `/docs/configuration-and-security/#gate` | `/faq/` |
| `/docs/configuration-and-security/#profiles` | `/workflow/` |
| `/docs/configuration-and-security/#unattended` | `/faq/` |
| `/docs/detailed-workflow/#approve-the-plan`, `#clarify-the-requirements-project-grill`, `#create-the-project-plan`, `#decide-what-to-do-with-review-findings`, `#implement-the-feature`, `#review-the-implementation`, `#run-a-feature-unattended` | `/features/` |
| `/docs/detailed-workflow/#owner-exception` | `/examples/` |
| `/docs/engineering-records/#analysis`, `#features`, `#levels`, `#memory`, `#owner`, `#repair`, `#short` | `/examples/` (the moved-case pointers) |
| `/docs/engineering-records/#story` | `/examples/`, `/workflow/` (`src/lib/workflow.ts`) |
| `/docs/engineering-records/#tradeoff` | `/examples/`, `/faq/` |
| `/docs/reference/workflow/#<step>` for the 18 steps | `/workflow/` (the "Every step in detail" lines and `src/components/WorkflowMap.astro`) |
| `/docs/technical-reference/#what-is-recorded-on-your-machine`, `#working-directories` | `/features/` |
| `/docs/troubleshooting/#a-session-or-a-run-was-interrupted` | `/faq/` |
| `/docs/troubleshooting/#stopped-or-interrupted-runs` | `/workflow/` |
| `/examples/#application` | `/docs/engineering-records/` |
| `/faq/`, `/faq/#cost`, `/faq/#who` | `/` |
| `/faq/` | `/about/`, `/docs/` (`index.mdx`), `/features/`; the footer |
| `/features/#learn` | `/docs/engineering-records/` |
| `/features/#review` | `/` |
| `/workflow/` | `/`, `/examples/`, `/faq/`; the header |
| `/about/` | `/docs/`; the footer |

The site's tests name routes too: `search-test.mjs` (the 22 routes, the old
anchors, the moved cases, the search ranking), `browser-check.mjs` (per-page
checks of `/`, `/workflow/`, `/examples/` and the docs) and `check-test.sh`.

**From Issues and pull requests of this repository** (full URLs, then paths
with an anchor written without the domain):

| Link | Where |
|---|---|
| `https://agentcodeyard.com` and `/` | Issues #253, #259, #267, #269, #316, #328, #370, #372; PR #268 |
| `https://agentcodeyard.com/sitemap.xml` | Issue #328, PR #349 |
| the 20 other page URLs: `/workflow/`, `/features/`, `/examples/`, `/faq/`, `/about/`, `/docs/` and every `/docs/...` page except `/docs/engineering-records/` | Issue #328 (its route list) |
| `https://agentcodeyard.com/docs/getting-started/` | Issues #267, #328 |
| `https://agentcodeyard.com/examples/#application` | Issue #328 |
| `/examples/#application` | Issue #329 |
| `/examples/#memory` | Issue #344, PR #347 |
| `/examples/#engineering` | PR #349 |
| `/features/#review` | PR #341 |
| `/faq/#who` | Issue #370 |
| `/workflow/#review-the-code` | PR #263 |
| `/docs/reference/workflow/#implement-the-feature`, `#review-the-code`, `#run-unattended` | Issues #256, #257 |
| `/docs/#quick-start`, `/docs/#troubleshooting`, `/docs/#adopting`, `/docs/#workflow-and-commands` | Issues #371, #372, #373, #377 (new URLs this plan defines) |
| `https://taspinar.github.io/agentic-coding-template/` | Issues #230, #234, #237, #242, #253, #267; PRs #103, #111, #268 (the earlier project path, before the rename and the custom domain; not a route of this site and out of scope) |

**From `website/legacy-anchors.json`:** the ids of all 22 routes as fetched
from the live site on 9 November 2026. Every id in it is still on its route
today; two ids restored as pointers by #335 are checked in addition: `/#projects`
and `/examples/#engineering`.

Links from outside GitHub (articles, search results, bookmarks) cannot be
listed; the rule of 3.1 covers them: every old route and every old anchor
keeps leading somewhere.

---

## 2. Content mapping

Destinations: **Home**, **Features**, **Projects**, **About**, a **Docs**
section (by its id from 4.2), the **Appendix** of the docs (Engineering
records and History and research when this plan was made; since #390 only
History, and Projects unlisted), or **removed** with the reason. "Duplicate"
names what already says the same; a duplicate is removed only once the step
that removes it has checked that its new place holds every fact (the rule
of #371: no content is removed before its new place exists).

### 2.1 Home `/` (rewritten by #370)

| Section (anchor) | Destination | Reason |
|---|---|---|
| Hero (`main`) | Home, hero | #370 rewrites it; the "Get started" action goes to `/docs/#quick-start` in #377 |
| Why not start building straight away? (`why`) | Home, "Why Codeyard?" | #370 replaces the comparison rows |
| One example in four steps (`example`) | Home, interactive demo (`/#demo`) | Duplicate of the demo of #370 and of the overview of `/workflow/`; the demo takes over its role |
| Who does what (`roles`) | removed | #370 removes it; duplicate of Features theme 3 (your decision) and of the roles of Configuration (`agent-roles`) |
| Who it is for (`who`) | Home, "Who it's for" | #370 shortens it |
| Start, or read further (`start`) | Home, "Get started" | #370; its "Read further" list is replaced by the header |
| Pointer "The real project moved to Projects" (`projects`) | Home, "From running features to overseeing them." (`/#oversee`) | #370's evidence section held the id; #390 replaced that section, and `oversee` holds `projects` and `evidence` as aliases |

### 2.2 How it works `/workflow/` (retired by #377)

| Section (anchor) | Destination | Reason |
|---|---|---|
| Four steps, in one example (`overview`, steps `describe-and-clarify`, `plan-the-work`, `build-and-check`, `decide`) | Home, interactive demo (`/#demo`) | Duplicate of Home's demo and of `new-to-agentic-coding` "One feature, from idea to decision"; the beginner story belongs on Home |
| The technical workflow (`technical-h`, `technical`) with the explorer (`explore`, `workflow`): h3 The route of a change, as a map (`workflow-title`, `workflow-map-title`), the route map with switches and its labels (`routes-label`), the words list (`workflow-words`), and the step panel, h3 set by script (`step-panel-h`, `step-panel`, `step-tab-overview`, `step-tab-technical`, `step-tab-failure`, `step-tab-body`) | Docs, `workflow-map` (Workflow & Commands); its ids move with it as `/docs/#workflow-map/<id>` (`technical`, `technical-h`: the topic itself, as 3.3 says) | The signature component (DESIGN.md "Route map with switches", PRODUCT.md "must survive"); it is technical, so it goes to the docs (see 6.4) |
| Step by step or unattended, When a run ends early (`ways`) | removed | Duplicate of `detailed-workflow` "Step by step or unattended" and of `troubleshooting` "Stopped or interrupted runs" (`/docs/#workflow-and-commands/step-by-step-or-unattended`, `/docs/#troubleshooting/stopped-or-interrupted-runs`) |
| How these pages were built, #241 → PR #249 (`case`) | removed | Duplicate of Engineering records "When new pages left out their sources" (`#story`) and of Home's real engineering evidence (#370, same case) |
| Every step in detail (`steps` and the 18 step ids `describe-the-idea`, `clarify-the-requirements`, `create-the-plan`, `review-the-plan`, `address-the-findings`, `approve-the-plan`, `merge-the-plan`, `change-the-plan`, `create-a-feature-issue`, `implement-the-feature`, `run-the-checks`, `review-the-code`, `decide-on-the-findings`, `apply-the-fixes`, `commit-the-feature`, `open-the-pull-request`, `merge`, `run-unattended`) | Docs, `workflow-reference`; each step id to `/docs/#workflow-reference/<id>` | Already only pointers to the workflow reference |

### 2.3 Why Codeyard `/features/` (rewritten by #374 as Features)

The new page has three themes: **Agree before you build** (`agree`), **Let
agents work, independently** (`independent`), **Verify before you accept**
(`verify`), and an inline FAQ (`faq`). The technical layer of each current
feature (its `details.proof` "files and settings", ids `*-t` and `*-words`:
`requirements-t`, `requirements-words`, `planning-t`, `planning-words`,
`isolation-t`, `isolation-words`, `evidence-t`, `evidence-words`, `review-t`,
`review-words`, `risk-t`, `risk-words`, `unattended-t`, `unattended-words`,
`authority-t`, `authority-words`, `learn-t`, `learn-words`)
leaves the page: Features then names no script, setting or file (#374), and
links the Docs section below. #374 compares each layer with its destination and
adds to that Markdown file, in the same pull request, every fact the
destination lacks.

| Section (anchor) | Destination | Technical layer goes to |
|---|---|---|
| Page head and intro (`main`) | Features, intro | — |
| Before coding starts (`planning`) | Features, `agree` | — |
| Agree on what to build before coding starts (`requirements`) | Features, `agree` (with the gym privacy example) | `/docs/#workflow-and-commands/clarify-the-requirements-project-grill` |
| Give every feature the same project plan (`architecture`) | Features, `agree` | `/docs/#workflow-and-commands/create-the-project-plan` and `#workflow-and-commands/approve-the-plan` |
| Keep changes separate while they are being built (`isolation`) | Features, `independent` | `/docs/#technical-reference/working-directories` and `#workflow-and-commands/features-side-by-side` |
| Before a change reaches you (`quality`) | Features, `verify` | — |
| See what was checked against your requirements (`evidence`) | Features, `verify` | `/docs/#verification-and-review` |
| Give each change a second review (`review`) | Features, `verify` | `/docs/#workflow-and-commands/review-the-implementation`, `/docs/#risk-policy` |
| Risk-based checks (`risk`) | Features, `verify` (one sentence: review where the risk policy asks) | `/docs/#risk-policy` |
| Autonomy with limits (`control`) | Features, `independent` | — |
| Let AI agents work while you are away (`unattended`) | Features, `independent` | `/docs/#configuration/unattended`, `/docs/#workflow-and-commands/run-a-feature-unattended` |
| You hold the last word on every change (`authority`) | Features, `verify` | `/docs/#configuration/changes-that-need-the-owner` |
| A self-improving process that learns from its own runs (`learn`) | Docs, `technical-reference` ("Learning from your runs"); Features keeps one sentence, since #390 in its own section "Learn from your runs" (`learn`) after `verify` | `/docs/#technical-reference/learning-from-your-runs` |

### 2.4 Projects `/examples/` (rewritten by #375)

| Section (anchor) | Destination | Reason |
|---|---|---|
| Page head (`main`) | Projects, head | — |
| Products (`products`) | Projects, the list of cases | Group heading only |
| FightAnalytics, a platform for gyms (`fightanalytics`) | Projects, case "FightAnalytics", labelled as private pilot or illustrative | #375: only public information |
| Physics by Construction (`application`) and its records (request, result, review found, unattended and owner, the pull request annotated, the run) | Projects, case "Physics by Construction"; the records under "Explore engineering evidence", closed | #375 |
| About the figures (`figures`), What is not shown (`absent`), Where the figures come from (`sources`) | Projects, inside the PBC evidence disclosure | They explain the PBC figures; Engineering records had its own `#absent` and `#sources` for its cases until #390 |
| Optional third case: Agent Codeyard itself | Projects, one compact case (#241 → PR #249 or another), labelled real verifiable run | #375; must not repeat Home's text |
| Pointers `engineering`, `memory`, `story`, `tradeoff`, `features`, `owner`, `repair`, `short`, `analysis`, `levels` | Projects, empty aliases at the heading of the cases (#390) | Old anchors of #344 (see 3.3); Engineering records was removed by #390 |

### 2.5 About `/about/` (rewritten by #376)

New parts: **Who built Agent Codeyard?** (`maker`), **Why it exists** (`why`),
**Open source and contributions** (`contribute`).

| Section (anchor) | Destination | Reason |
|---|---|---|
| The maker, JIDAI and the project (`maker`) | About, `maker` | — |
| Its history sentence (`history`, with the alias ids `why`, `decisions`, `research`, `improvements`) | About, one link to the Appendix page, "How Agent Codeyard began" since #390 | `why` becomes the id of the real part "Why it exists"; the others stay on the link sentence |
| What it does, in short (`limits`) | removed | Duplicate of Home's hero and of the Features intro; "Codeyard writes no code" stays on Features; "no security boundary" is in `/docs/#configuration` |
| Ready to use, open to contributions (`contribute`) | About, `contribute` | — |
| Source and licence (`source`) | About, `contribute` | Merged: GitHub, MIT licence, contributing, security reports |

### 2.6 FAQ `/faq/` (retired by #377)

All sixteen questions. "Features FAQ" is the inline FAQ of `/features/`; its
question keeps the id it has on `/faq/`.

| # | Question (anchor) | New home | Reason |
|---|---|---|---|
| 1 | What does Agent Codeyard do? (`what`) | Home hero and Features intro | Duplicate: the first question both pages answer |
| 2 | Why use it next to Claude Code or Codex? (`replace`) | Features FAQ, "Why not just use Claude Code or Codex?" | Required by #374; Home's "Why Codeyard?" asks it too |
| 3 | Do I need to be able to program? (`who`) | Features FAQ, "Do I need to know programming?" | Required by #374 |
| 4 | What software can I build or maintain with it? (`software`) | Home "Who it's for" and `/docs/#quick-start/before-you-start` | Duplicate of the requirements Home lists (#370); the gym example is the demo's |
| 5 | Can I use an existing project? (`existing`) | Features FAQ, link to `/docs/#adopting` | A beginner's deciding question |
| 6 | What do I still do myself? (`permission`) | Features, `verify` (your decision) and `/docs/#configuration/changes-that-need-the-owner` | Theme 3 answers it |
| 7 | What does it cost, and why does that differ per project? (`cost`) | Features FAQ, "What does it cost?" | Required by #374 |
| 8 | When is this way of working worth it? (`too-heavy`) | Features FAQ | A beginner's deciding question |
| 9 | How do I know what was checked? (`checked`) | Features, `verify`, and `/docs/#verification-and-review` | Theme 3 answers it |
| 10 | What happens when the AI gets stuck or does something wrong? (`wrong`) | `/docs/#troubleshooting` (a short lead paragraph) | Practical; the detail is there |
| 11 | Where does it run, and which data goes to the AI providers? (`data`) | Features FAQ and `/docs/#configuration/which-data-goes-where` | Required by #374 |
| 12 | Is the software also put online automatically? (`online`) | `/docs/#configuration/the-limits-in-short` (one sentence) | Practical; today it links `adopting#what-is-preserved` |
| 13 | Which computers does it run on? (`environments`) | `/docs/#quick-start/before-you-start` | Practical; the requirements are there |
| 14 | How do I stop a run, and continue it? (`stop`) | `/docs/#troubleshooting/a-session-or-a-run-was-interrupted` | Practical; the detail is there |
| 15 | What does an unattended run do without me? (`unattended`) | `/docs/#configuration/unattended` | Practical; the detail is there |
| 16 | Is every change reviewed? (`review`) | Features, `verify`, and `/docs/#risk-policy` | Theme 3 says "where the risk policy asks for it" |

Features FAQ, in this order: `replace`, `who`, `cost`, `data`, `existing`,
`too-heavy`. Six answers of two to four sentences fit the 900 words of #374
with the three themes. #377 adds the answers of rows 10 and 12 to 15 to their
Docs topics where the facts are missing, before `/faq/` becomes a redirect.

### 2.7 Docs `/docs/` and its pages (moved into one interface by #373)

Every docs page moves whole into its topic of 4.2; its sections stay in its
order, under the same headings. Nothing of rows 7 to 20 is removed by #373.

The tables below name every heading of 1.2 for rows 7 to 22, nested ones
included, and every other id of the page under the heading it stands
before. Where a page moves whole, a heading's destination is its deep link of
4.3, `/docs/#<topic>/<slug>`, with the slug unchanged; the old address leads
there by the table of 3.3. An alias id (`<a id>` before a heading) moves with
the heading it stands before and becomes `/docs/#<topic>/<alias>` too.

#### `/docs/` (`index.mdx`)

| Section (anchor) | Destination | Reason |
|---|---|---|
| Intro list of four routes (no id) | removed | The section navigation replaces it; Quick Start opens by default |
| What stays with you (`what-stays-with-you`) | removed | Duplicate of `/docs/#configuration/the-limits-in-short` and of `/docs/#quick-start/before-you-start` (#373 checks each fact) |
| Find a command or setting (`find-a-command-or-setting`) | removed | The search is in the interface; its one sentence on how search ranks becomes the search's hint |
| More to read (`more-to-read`) | removed | The navigation replaces it |
| Sources and scope (`sources-and-scope`) | `/docs/#technical-reference/sources-and-scope`, a new last h2, and one line under the docs title (see 5) | — |

#### `getting-started` → topic `quick-start`

| Section (anchor) | Destination |
|---|---|
| alias `what-you-need`, before "Before you start" | `/docs/#quick-start/what-you-need` |
| Before you start (`before-you-start`) | `/docs/#quick-start/before-you-start` |
| 1. Sign in (`1-sign-in`) | `/docs/#quick-start/1-sign-in` |
| 2. Create your repository (`2-create-your-repository`) | `/docs/#quick-start/2-create-your-repository` |
| 3. Set up GitHub (`3-set-up-github`) | `/docs/#quick-start/3-set-up-github` |
| 4. Check your setup (`4-check-your-setup`) | `/docs/#quick-start/4-check-your-setup` |
| 5. Choose your agents (`5-choose-your-agents`) | `/docs/#quick-start/5-choose-your-agents` |
| 6. Plan your project (`6-plan-your-project`) | `/docs/#quick-start/6-plan-your-project` |
| 7. Require the CI check (`7-require-the-ci-check`) | `/docs/#quick-start/7-require-the-ci-check` |
| 8. Build your first feature (`8-build-your-first-feature`) | `/docs/#quick-start/8-build-your-first-feature` |

#### `new-to-agentic-coding` → topic `new-to-agentic-coding` (Quick Start)

"One feature …" is a duplicate of Home's demo in words; kept, because it is
the docs' plain-words entry and the text a reader without the demo needs.

| Section (anchor) | Destination |
|---|---|
| One feature, from idea to decision (`one-feature-from-idea-to-decision`) | `/docs/#new-to-agentic-coding/one-feature-from-idea-to-decision` |
| ↳ The idea (`the-idea`) | `/docs/#new-to-agentic-coding/the-idea` |
| ↳ Clarify what you need (`clarify-what-you-need`) | `/docs/#new-to-agentic-coding/clarify-what-you-need` |
| ↳ The project folder (`the-project-folder`) | `/docs/#new-to-agentic-coding/the-project-folder` |
| ↳ A coding agent builds it (`a-coding-agent-builds-it`) | `/docs/#new-to-agentic-coding/a-coding-agent-builds-it` |
| ↳ A change proposal (`a-change-proposal`) | `/docs/#new-to-agentic-coding/a-change-proposal` |
| ↳ A second agent reviews it (`a-second-agent-reviews-it`) | `/docs/#new-to-agentic-coding/a-second-agent-reviews-it` |
| ↳ You decide (`you-decide`) | `/docs/#new-to-agentic-coding/you-decide` |
| What Agent Codeyard adds (`what-agent-codeyard-adds`) | `/docs/#new-to-agentic-coding/what-agent-codeyard-adds` |
| When Codeyard is relevant (`when-codeyard-is-relevant`) | `/docs/#new-to-agentic-coding/when-codeyard-is-relevant` |
| What to read next (`what-to-read-next`) | `/docs/#new-to-agentic-coding/what-to-read-next`; #373 rewrites its links to section links |
| Glossary (`glossary`) | `/docs/#new-to-agentic-coding/glossary` |

#### `adopting` → topic `adopting`

| Section (anchor) | Destination |
|---|---|
| The three steps (`the-three-steps`) | `/docs/#adopting/the-three-steps` |
| The normal route (`the-normal-route`) | `/docs/#adopting/the-normal-route` |
| ↳ 1. Assess (`1-assess`) | `/docs/#adopting/1-assess` |
| ↳ 2. Adopt (`2-adopt`) | `/docs/#adopting/2-adopt` |
| ↳ 3. Record the baseline (`3-record-the-baseline`) | `/docs/#adopting/3-record-the-baseline` |
| ↳ After the merge (`after-the-merge`) | `/docs/#adopting/after-the-merge` |
| Existing files (`existing-files`) | `/docs/#adopting/existing-files` |
| Monorepos and subdirectories (`monorepos-and-subdirectories`) | `/docs/#adopting/monorepos-and-subdirectories` |
| The base branch (`the-base-branch`) | `/docs/#adopting/the-base-branch` |
| Baseline exceptions (`baseline-exceptions`) | `/docs/#adopting/baseline-exceptions` |
| What is preserved (`what-is-preserved`) | `/docs/#adopting/what-is-preserved` |
| Limits (`limits`) | `/docs/#adopting/limits` |

#### `detailed-workflow` → topic `workflow-and-commands`

| Section (anchor) | Destination |
|---|---|
| alias `choices-along-the-route`, before "Daily use" | `/docs/#workflow-and-commands/choices-along-the-route` |
| Daily use (`daily-use`) | `/docs/#workflow-and-commands/daily-use` |
| ↳ Step by step or unattended (`step-by-step-or-unattended`) | `/docs/#workflow-and-commands/step-by-step-or-unattended` |
| ↳ Resume a feature that stopped (`resume-a-feature-that-stopped`, alias `resume`) | `/docs/#workflow-and-commands/resume-a-feature-that-stopped` |
| ↳ When the plan changes (`when-the-plan-changes`) | `/docs/#workflow-and-commands/when-the-plan-changes` |
| ↳ A base branch other than main (`a-base-branch-other-than-main`) | `/docs/#workflow-and-commands/a-base-branch-other-than-main` |
| ↳ Features side by side (`features-side-by-side`) | `/docs/#workflow-and-commands/features-side-by-side` |
| ↳ A plan for a complex Issue (`a-plan-for-a-complex-issue`, alias `plans-and-earlier-review-rounds`) | `/docs/#workflow-and-commands/a-plan-for-a-complex-issue` |
| What each step is for (`what-each-step-is-for`, aliases `steps`, `every-step-in-detail`) | `/docs/#workflow-and-commands/what-each-step-is-for` |
| ↳ Stage 1 · Plan the project (`stage-1--plan-the-project`) and its step ids (`step-idea`, `describe-the-idea`, `step-grill`, `clarify-the-requirements-project-grill`, `step-plan`, `create-the-project-plan`, `step-planning-review`, `review-the-plan`, `step-revise`, `address-the-review-findings`, `step-finish-planning`, `approve-the-plan`, `step-planning-merge`, `merge-the-planning-pull-request`, `step-change`, `update-an-approved-plan`) | `/docs/#workflow-and-commands/stage-1--plan-the-project`; each step id `/docs/#workflow-and-commands/<id>` |
| ↳ Stage 2 · Build each feature (`stage-2--build-each-feature`) and its step ids (`step-issue`, `create-a-feature-issue`, `step-implement`, `implement-the-feature`, `step-verify`, `run-verification`, `step-review`, `review-the-implementation`, `step-triage`, `decide-what-to-do-with-review-findings`, `step-fix`, `apply-fixes-and-review-again`, `step-commit`, `commit-the-feature`, `step-publish`, `open-the-pull-request`, `step-merge`, `review-and-merge`, `step-run`, `run-a-feature-unattended`) | `/docs/#workflow-and-commands/stage-2--build-each-feature`; each step id `/docs/#workflow-and-commands/<id>` |
| When you disagree, and exceptions (`when-you-disagree-and-exceptions`) | `/docs/#workflow-and-commands/when-you-disagree-and-exceptions`; Verification & Review links it (4.2) |
| ↳ When you disagree with the triage (`when-you-disagree-with-the-triage`, alias `owner-directed-triage`) | `/docs/#workflow-and-commands/when-you-disagree-with-the-triage` |
| ↳ When you disagree with a blocking finding (`when-you-disagree-with-a-blocking-finding`, alias `owner-exception`) | `/docs/#workflow-and-commands/when-you-disagree-with-a-blocking-finding` |
| ↳ Skipping a review (`skipping-a-review`, alias `skipping-a-review-explicitly`) | `/docs/#workflow-and-commands/skipping-a-review` |

#### `updating` → topic `updating` (Workflow & Commands)

| Section (anchor) | Destination |
|---|---|
| Update the project (`update-the-project`, alias `update-an-existing-project`) | `/docs/#updating/update-the-project` |
| Which files it changes (`which-files-it-changes`, aliases `sync`, `keeping-a-project-up-to-date`) | `/docs/#updating/which-files-it-changes` |
| Versions and conflicts (`versions-and-conflicts`) | `/docs/#updating/versions-and-conflicts` |
| ↳ A conflict, and the next step (`a-conflict-and-the-next-step`, alias `a-conflict`) | `/docs/#updating/a-conflict-and-the-next-step` |

#### `configuration-and-security` → topic `configuration`

| Section (anchor) | Destination |
|---|---|
| The limits in short (`the-limits-in-short`) | `/docs/#configuration/the-limits-in-short` |
| What an agent is allowed to do (`what-an-agent-is-allowed-to-do`, alias `profiles`; the id `unattended` on its paragraph on unattended runs) | `/docs/#configuration/what-an-agent-is-allowed-to-do`; `/docs/#configuration/unattended` |
| Which data goes where (`which-data-goes-where`, alias `data`) | `/docs/#configuration/which-data-goes-where` |
| GitHub rights (`github-rights`) | `/docs/#configuration/github-rights` |
| Changes that need the owner (`changes-that-need-the-owner`, alias `gate`) | `/docs/#configuration/changes-that-need-the-owner` |
| Agent attribution (`agent-attribution`, alias `attribution`) | `/docs/#configuration/agent-attribution` |

#### `agent-roles` → topic `agent-roles` (Configuration)

| Section (anchor) | Destination |
|---|---|
| The roles in plain words (`the-roles-in-plain-words`) | `/docs/#agent-roles/the-roles-in-plain-words` |
| Role, tool, provider and model (`role-tool-provider-and-model`, alias `terms`) | `/docs/#agent-roles/role-tool-provider-and-model` |
| Agent roles and models (`agent-roles-and-models`, alias `roles`) | `/docs/#agent-roles/agent-roles-and-models` |
| Shipped configuration (`shipped-configuration`, alias `default-configuration`) | `/docs/#agent-roles/shipped-configuration` |
| Further configuration (`further-configuration`) | `/docs/#agent-roles/further-configuration` |
| ↳ One run with another tool or model (`one-run-with-another-tool-or-model`, alias `overrides`) | `/docs/#agent-roles/one-run-with-another-tool-or-model` |
| ↳ Models per risk level (`models-per-risk-level`, alias `risk-levels`) | `/docs/#agent-roles/models-per-risk-level` |
| ↳ Project skills (`project-skills`, alias `skills`) | `/docs/#agent-roles/project-skills` |

#### `risk-policy` → topic `risk-policy` (Configuration)

| Section (anchor) | Destination |
|---|---|
| A typo and a change to authentication (`a-typo-and-a-change-to-authentication`) | `/docs/#risk-policy/a-typo-and-a-change-to-authentication` |
| What a level changes in practice (`what-a-level-changes-in-practice`, alias `in-practice`) | `/docs/#risk-policy/what-a-level-changes-in-practice` |
| ↳ Three settings with similar names (`three-settings-with-similar-names`, alias `three-settings`) | `/docs/#risk-policy/three-settings-with-similar-names` |
| The risk level of a feature (`the-risk-level-of-a-feature`, alias `risk`) | `/docs/#risk-policy/the-risk-level-of-a-feature` |
| Shipped configuration (`shipped-configuration`) | `/docs/#risk-policy/shipped-configuration` |
| The risk policy (`the-risk-policy`, alias `policy-settings`) | `/docs/#risk-policy/the-risk-policy` |
| ↳ Classes of paths (`classes-of-paths`) | `/docs/#risk-policy/classes-of-paths` |
| ↳ What each level requires (`what-each-level-requires`) | `/docs/#risk-policy/what-each-level-requires` |
| ↳ Workflow profiles (`workflow-profiles`) | `/docs/#risk-policy/workflow-profiles` |
| ↳ Fixed escalations (`fixed-escalations`, alias `escalations`) | `/docs/#risk-policy/fixed-escalations` |

#### `github-setup` → topic `github-setup` (Configuration)

| Section (anchor) | Destination |
|---|---|
| Step by step (`step-by-step`, aliases `checklist`, `repository-setup-checklist`) | `/docs/#github-setup/step-by-step` |
| What GitHub has to enforce (`what-github-has-to-enforce`, alias `github`) | `/docs/#github-setup/what-github-has-to-enforce` |
| ↳ What the guardrails check shows (`what-the-guardrails-check-shows`, alias `guardrails-check`) | `/docs/#github-setup/what-the-guardrails-check-shows` |
| Advanced: publishing this website (`advanced-publishing-this-website`, alias `keeping-the-template-website`) | `/docs/#github-setup/advanced-publishing-this-website` |

#### `verification-and-completion` → topic `verification-and-review`

| Section (anchor) | Destination |
|---|---|
| "The agent says done" against "verified done" (`the-agent-says-done-against-verified-done`) | `/docs/#verification-and-review/the-agent-says-done-against-verified-done` |
| ↳ One criterion and its evidence (`one-criterion-and-its-evidence`) | `/docs/#verification-and-review/one-criterion-and-its-evidence` |
| Completion is recorded per criterion (`completion-is-recorded-per-criterion`) | `/docs/#verification-and-review/completion-is-recorded-per-criterion` |
| Project checks and workflow checks (`project-checks-and-workflow-checks`, alias `verification`) | `/docs/#verification-and-review/project-checks-and-workflow-checks` |
| Advanced settings (`advanced-settings`, alias `advanced`) | `/docs/#verification-and-review/advanced-settings` |
| ↳ Partial checks and budgets (`partial-checks-and-budgets`) | `/docs/#verification-and-review/partial-checks-and-budgets` |
| ↳ A parallel CI (`a-parallel-ci`, alias `parallel-ci`) | `/docs/#verification-and-review/a-parallel-ci` |
| ↳ Failures that existed before the adoption (`failures-that-existed-before-the-adoption`) | `/docs/#verification-and-review/failures-that-existed-before-the-adoption` |
| ↳ Heavy checks on a shared machine (`heavy-checks-on-a-shared-machine`) | `/docs/#verification-and-review/heavy-checks-on-a-shared-machine` |

#### `troubleshooting` → topic `troubleshooting`

Every situation keeps its slug; `/docs/#troubleshooting/<slug>` opens it.

| Section (anchor) | Destination |
|---|---|
| Starting and resuming (`starting-and-resuming`, aliases `if-something-goes-wrong`, `start-and-resume`, `setup-and-agents`) | `/docs/#troubleshooting/starting-and-resuming` |
| ↳ "… is not installed", or GitHub is not signed in (`-is-not-installed-or-github-is-not-signed-in`) | `/docs/#troubleshooting/-is-not-installed-or-github-is-not-signed-in` |
| ↳ An agent does not start, or rejects the model (`an-agent-does-not-start-or-rejects-the-model`) | `/docs/#troubleshooting/an-agent-does-not-start-or-rejects-the-model` |
| ↳ A session or a run was interrupted (`a-session-or-a-run-was-interrupted`, aliases `handles`, `situations-the-workflow-handles`, `stopped-or-interrupted-runs`) | `/docs/#troubleshooting/a-session-or-a-run-was-interrupted`; receives FAQ `stop` (2.6) |
| ↳ "an agent needs a decision; …" (`an-agent-needs-a-decision-its-question-is-in-the-handoff-note`) | `/docs/#troubleshooting/an-agent-needs-a-decision-its-question-is-in-the-handoff-note` |
| ↳ "the implementer wrote no completion record", or … (`the-implementer-wrote-no-completion-record-or-the-handoff-note--lists-remaining-work`) | `/docs/#troubleshooting/the-implementer-wrote-no-completion-record-or-the-handoff-note--lists-remaining-work` |
| ↳ "This is a usage limit of …, not a defect" (`this-is-a-usage-limit-of--not-a-defect`) | `/docs/#troubleshooting/this-is-a-usage-limit-of--not-a-defect` |
| ↳ "could not read the comments of Issue #…" (`could-not-read-the-comments-of-issue-`) | `/docs/#troubleshooting/could-not-read-the-comments-of-issue-` |
| Checks and reviews (`checks-and-reviews`) | `/docs/#troubleshooting/checks-and-reviews` |
| ↳ A check fails (`a-check-fails`) | `/docs/#troubleshooting/a-check-fails` |
| ↳ "BUSY the slot for heavy verification …" (`busy--the-slot-for-heavy-verification-of-this-machine-is-held-by-`) | `/docs/#troubleshooting/busy--the-slot-for-heavy-verification-of-this-machine-is-held-by-` |
| ↳ "the reviewer would use …" (`the-reviewer-would-use--the-provider-the-implementer-ran-with`) | `/docs/#troubleshooting/the-reviewer-would-use--the-provider-the-implementer-ran-with` |
| ↳ "the latest review (…) is stale …" (`the-latest-review--is-stale-the-code-changed-after-it`) | `/docs/#troubleshooting/the-latest-review--is-stale-the-code-changed-after-it` |
| ↳ "the latest review (round …) covers only …" (`the-latest-review-round--covers-only-the-changes-since-round-`) | `/docs/#troubleshooting/the-latest-review-round--covers-only-the-changes-since-round-` |
| ↳ A review has findings (`a-review-has-findings`) | `/docs/#troubleshooting/a-review-has-findings` |
| ↳ "the implementer refuted every finding …" (`the-implementer-refuted-every-finding-left-to-fix-in-round-`) | `/docs/#troubleshooting/the-implementer-refuted-every-finding-left-to-fix-in-round-` |
| Planning (`planning`) | `/docs/#troubleshooting/planning` |
| ↳ "the planning has not been approved", or … (`the-planning-has-not-been-approved-or-a-planning-document-changed-after-the-planning-was-approved`) | `/docs/#troubleshooting/the-planning-has-not-been-approved-or-a-planning-document-changed-after-the-planning-was-approved` |
| ↳ "the latest planning review (…) is stale" (`the-latest-planning-review--is-stale`) | `/docs/#troubleshooting/the-latest-planning-review--is-stale` |
| Commit and publish (`commit-and-publish`) | `/docs/#troubleshooting/commit-and-publish` |
| ↳ "… must run on feature/-*. …" (`-must-run-on-feature--current-branch-`) | `/docs/#troubleshooting/-must-run-on-feature--current-branch-` |
| ↳ The base branch moved after the feature was finished (`the-base-branch-moved-after-the-feature-was-finished`) | `/docs/#troubleshooting/the-base-branch-moved-after-the-feature-was-finished` |
| ↳ "Merging origin/… conflicts …" (`merging-origin-conflicts-with-the-feature-in-`) | `/docs/#troubleshooting/merging-origin-conflicts-with-the-feature-in-` |
| ↳ "Left behind by a merge of the base" (`left-behind-by-a-merge-of-the-base`) | `/docs/#troubleshooting/left-behind-by-a-merge-of-the-base` |
| ↳ "… would write over … untracked files …" (`-would-write-over--untracked-files-`) | `/docs/#troubleshooting/-would-write-over--untracked-files-` |
| ↳ "The index holds staged changes" (`the-index-holds-staged-changes`) | `/docs/#troubleshooting/the-index-holds-staged-changes` |

#### `technical-reference` → topic `technical-reference`

Each h2 has a short alias before it; both move.

| Section (anchor) | Destination |
|---|---|
| Files by function (`files-by-function`, alias `by-function`) | `/docs/#technical-reference/files-by-function` |
| What is recorded on your machine (`what-is-recorded-on-your-machine`, alias `records`) | `/docs/#technical-reference/what-is-recorded-on-your-machine` |
| Learning from your runs (`learning-from-your-runs`, alias `learning`) | `/docs/#technical-reference/learning-from-your-runs`; receives the technical layer of Features `learn` (2.3) |
| Rules and configuration (`rules-and-configuration`, alias `rules`) | `/docs/#technical-reference/rules-and-configuration` |
| Project documents (`project-documents`, alias `documents`) | `/docs/#technical-reference/project-documents` |
| Workflow scripts (`workflow-scripts`, alias `scripts`) | `/docs/#technical-reference/workflow-scripts` |
| Script libraries (`script-libraries`, alias `libraries`) | `/docs/#technical-reference/script-libraries` |
| Agent contracts and schemas (`agent-contracts-and-schemas`, alias `contracts`) | `/docs/#technical-reference/agent-contracts-and-schemas` |
| Working directories (`working-directories`, alias `directories`) | `/docs/#technical-reference/working-directories` |
| Website files (`website-files`, alias `website`) | `/docs/#technical-reference/website-files` |
| Source ownership (`source-ownership`, alias `ownership`) | `/docs/#technical-reference/source-ownership` |
| (new) Sources and scope | from `/docs/` `sources-and-scope`, the last h2 |

#### `reference/workflow` → topic `workflow-reference` (Technical Reference)

| Section (anchor) | Destination |
|---|---|
| Step index (`index`) | `/docs/#workflow-reference/index` |
| Parameters (`parameters`) | `/docs/#workflow-reference/parameters` |
| Plan the project (`plan-the-project`) | `/docs/#workflow-reference/plan-the-project` |
| ↳ its eight steps (`describe-the-idea-h`, `clarify-the-requirements-h`, `create-the-plan-h`, `review-the-plan-h`, `address-the-findings-h`, `approve-the-plan-h`, `merge-the-plan-h`, `change-the-plan-h`, each with its id without `-h`) | `/docs/#workflow-reference/<id>`, for the heading and for its id without `-h` |
| Build each feature (`build-each-feature`) | `/docs/#workflow-reference/build-each-feature` |
| ↳ its ten steps (`create-a-feature-issue-h`, `implement-the-feature-h`, `run-the-checks-h`, `review-the-code-h`, `decide-on-the-findings-h`, `apply-the-fixes-h`, `commit-the-feature-h`, `open-the-pull-request-h`, `merge-h`, `run-unattended-h`, each with its id without `-h`) | `/docs/#workflow-reference/<id>`, for the heading and for its id without `-h` |

#### `engineering-records` → removed by #390, a redirect to `/docs/history/`

This plan kept the page in the Appendix, linked from Projects (#375) and Home
(#370). #390 removed it: the route is a redirect page and every id below goes
to the top of `/docs/history/` (row 21 of 3.3, section 8); no page links it.

| Section (anchor) | Destination |
|---|---|
| The nine cases (`memory`, `story`, `tradeoff`, `features`, `owner`, `repair`, `short`, `analysis`, `levels`; with them the ids `run-217-t`, `run-217-words`, `run-241-t`, `run-241-words` of the run figures) | removed; `/docs/history/` (redirect) |
| What is not shown (`absent`) | removed; `/docs/history/` (redirect) |
| Where the figures come from (`sources`) | removed; `/docs/history/` (redirect) |

#### `history` → Appendix, kept at its route

All ids stay on the page; About (#376) links it once. #390 removed "In
short", "Engineering principles" and "Design decisions": their ids are aliases
at the top of the page (section 8).

| Section (anchor) | Destination |
|---|---|
| In short (`phases`) | removed by #390; `phases` is an alias at the top of `/docs/history/` |
| History (`history`) | `/docs/history/#history`, unchanged |
| Engineering principles (`principles`) | removed by #390; `principles` is an alias at the top of `/docs/history/` |
| Design decisions (`decisions`) | removed by #390; `decisions` is an alias at the top of `/docs/history/` |
| Research (`research`) | `/docs/history/#research`, unchanged |

The interface ids of every docs page (`main`, `docs-query`, `search-status`,
`search-results`) belong to the layout, not to a section: the one docs page
has each once.

Duplicates inside the docs that stay for now, named so that a later editorial
step can decide: "Step by step or unattended" (`detailed-workflow`) and the
unattended rows of `configuration-and-security`; "Shipped configuration" in
both `agent-roles` and `risk-policy` (each shows its own file, not a
duplicate). Moving review content (`detailed-workflow` "When you disagree, and
exceptions") into Verification & Review would split a file; it is not
part of #373 (see 4.2).

---

## 3. URL and anchor migration

### 3.1 Rules

- No old route and no old anchor stops working. A route that stays keeps its
  ids, as an alias where the content moved within the page. A route that is
  retired becomes a redirect page.
- A redirect is added in the same pull request that removes the page, and
  that pull request also adds the target.
- The table of 3.3 is data in the site, not only in this document: one module
  (proposed `src/lib/redirects.ts`) that the redirect pages and the hash
  router read, and a test walks it on the built site (#373 creates it, #377
  extends it).

### 3.2 Mechanisms on GitHub Pages

GitHub Pages serves static files: no server redirects, no status 301. Four
mechanisms, by case:

| Mechanism | When | With JavaScript | Without JavaScript |
|---|---|---|---|
| **A. Alias id** | The route stays; the content moved within the page | The browser scrolls to the alias | The same: an empty element with the old id at the new place (as `about.astro` does today) |
| **B. Pointer** | The route stays; the content moved to another page | One sentence with a link, carrying the old id (as the moved-case pointers of `/examples/` today) | The same; one click |
| **C. Redirect page** | The route is retired | An inline script reads `location.hash`, looks it up in the table and calls `location.replace(new URL + new anchor)`; an unknown hash goes to the default target | `<meta http-equiv="refresh" content="0; url=…">` goes to the route's default target: the old anchor is lost, the visitor lands at the right page or section |
| **D. Docs hash router** | An anchor of `/docs/` itself | The router of 4.4 opens the section and scrolls | Every topic is in the page (4.5), so `#topic` and `#topic/heading` are real ids and the browser scrolls natively; the four old ids of `/docs/` get alias ids (A) |

**Astro's `redirects`:** in static output Astro writes, per redirect, an HTML
page with a meta refresh, `<link rel="canonical">`, `noindex` and a link. That
is the shape we want, but the page can hold no script, so it cannot map an old
anchor, and every retired route here has anchors that are linked. Decision:
generate redirect pages of the same shape ourselves, from the table: one
Astro page per retired route (for example a `getStaticPaths` over the table,
rendered by a small `Redirect` layout), each with

- the inline hash script first in `<head>`, then the meta refresh, so that the
  script decides before the refresh;
- `<link rel="canonical">` to the default target, `<meta name="robots"
  content="noindex">`, a `<title>` "Moved: <old title>";
- a visible sentence with a link to the default target, for a visitor whose
  browser does not follow a refresh;
- no header, footer or `<main>`: the search index integration skips a page
  without `<main>`, and the sitemap lists no redirect page.

`check.sh` requires a description on every page; #373 lets it recognise a
redirect page (by its `noindex` and refresh) and check its target instead.
Both base paths apply: the targets are written with `href()` of
`src/lib/links.ts`, never as absolute paths.

### 3.3 The table

`/docs/#<topic>/<id>` is the scheme of 4.3: a docs heading or id keeps its
slug and gets the topic as prefix. "Mechanical" in a row means: every anchor
of the route listed in 1.2 maps to `/docs/#<topic>/<same id>`; the interface
ids `main`, `docs-query`, `search-status` and `search-results` map to
`/docs/#<topic>`.

**Routes**

| # | Old URL | New URL (default target) | Mechanism | Step | Anchors |
|---|---|---|---|---|---|
| 1 | `/` | `/` | stays | #370 | see "Anchors of routes that stay" |
| 2 | `/workflow/` | `/#demo` | C | #377 | see "Anchors of `/workflow/`" |
| 3 | `/features/` | `/features/` | stays (A) | #374 | see "Anchors of routes that stay" |
| 4 | `/examples/` | `/examples/` | stays (A, B) | #375 | see "Anchors of routes that stay" |
| 5 | `/about/` | `/about/` | stays (A) | #376 | see "Anchors of routes that stay" |
| 6 | `/faq/` | `/features/#faq` | C | #377 | see "Anchors of `/faq/`" |
| 7 | `/docs/adopting/` | `/docs/#adopting` | C | #373 | mechanical, topic `adopting` |
| 8 | `/docs/agent-roles/` | `/docs/#agent-roles` | C | #373 | mechanical, topic `agent-roles` |
| 9 | `/docs/configuration-and-security/` | `/docs/#configuration` | C | #373 | mechanical, topic `configuration` |
| 10 | `/docs/detailed-workflow/` | `/docs/#workflow-and-commands` | C | #373 | mechanical, topic `workflow-and-commands` |
| 11 | `/docs/getting-started/` | `/docs/#quick-start` | C | #373 | mechanical, topic `quick-start` |
| 12 | `/docs/github-setup/` | `/docs/#github-setup` | C | #373 | mechanical, topic `github-setup` |
| 13 | `/docs/` | `/docs/` (opens Quick Start) | D | #373 | `#what-stays-with-you` → `#configuration/the-limits-in-short`; `#find-a-command-or-setting` → `#docs-query`; `#more-to-read` → `#quick-start`; `#sources-and-scope` → `#technical-reference/sources-and-scope`; interface ids stay |
| 14 | `/docs/new-to-agentic-coding/` | `/docs/#new-to-agentic-coding` | C | #373 | mechanical, topic `new-to-agentic-coding` |
| 15 | `/docs/risk-policy/` | `/docs/#risk-policy` | C | #373 | mechanical, topic `risk-policy` |
| 16 | `/docs/technical-reference/` | `/docs/#technical-reference` | C | #373 | mechanical, topic `technical-reference` |
| 17 | `/docs/troubleshooting/` | `/docs/#troubleshooting` | C | #373 | mechanical, topic `troubleshooting` |
| 18 | `/docs/updating/` | `/docs/#updating` | C | #373 | mechanical, topic `updating` |
| 19 | `/docs/verification-and-completion/` | `/docs/#verification-and-review` | C | #373 | mechanical, topic `verification-and-review` |
| 20 | `/docs/reference/workflow/` | `/docs/#workflow-reference` | C | #373 | mechanical, topic `workflow-reference` (for example `#review-the-code` → `#workflow-reference/review-the-code`, `#review-the-code-h` → `#workflow-reference/review-the-code-h`) |
| 21 | `/docs/engineering-records/` | `/docs/history/` | C | #390 | every id to `/docs/history/` |
| 22 | `/docs/history/` | `/docs/history/` | stays (Appendix) | — | unchanged |

Without JavaScript, every C row lands on its default target, which is the right
page and, for the docs, the right topic.

**Anchors of `/workflow/`** (row 2; `demo` is the id of #370's demo section,
as its pull request #378 gives it in `website/src/pages/index.astro`. #370 is
asked to keep it; if #370 merges with another id, this table, row 2 and 2.1
and 2.2 are updated to it before #377 builds the redirect)

| Old anchors | New |
|---|---|
| `main`, `overview`, `overview-h`, `describe-and-clarify`, `plan-the-work`, `build-and-check`, `decide` | `/#demo` |
| `technical`, `technical-h`, `explore`, `workflow`, `workflow-title`, `workflow-map-title`, `workflow-words`, `step-panel`, `step-panel-h`, `step-tab-overview`, `step-tab-technical`, `step-tab-failure`, `step-tab-body`, `routes-label` | `/docs/#workflow-map/<same id>` (`technical`, `technical-h`: `/docs/#workflow-map`) |
| `ways`, `ways-h` | `/docs/#workflow-and-commands/step-by-step-or-unattended` |
| `case`, `case-h` | `/docs/history/` (#390; it was `/docs/engineering-records/#story`) |
| `steps`, `steps-h` | `/docs/#workflow-reference` |
| the 18 step ids `describe-the-idea`, `clarify-the-requirements`, `create-the-plan`, `review-the-plan`, `address-the-findings`, `approve-the-plan`, `merge-the-plan`, `change-the-plan`, `create-a-feature-issue`, `implement-the-feature`, `run-the-checks`, `review-the-code`, `decide-on-the-findings`, `apply-the-fixes`, `commit-the-feature`, `open-the-pull-request`, `merge`, `run-unattended` | `/docs/#workflow-reference/<same id>` |

**Anchors of `/faq/`** (row 6)

| Old anchors | New |
|---|---|
| `main` | `/features/#faq` |
| `what`, `what-h` | `/features/` |
| `replace`, `replace-h`, `who`, `who-h`, `cost`, `cost-h`, `data`, `data-h`, `existing`, `existing-h`, `too-heavy`, `too-heavy-h` | `/features/#<same id>` (the Features FAQ; each `-h` to its question) |
| `permission`, `permission-h`, `checked`, `checked-h`, `review`, `review-h` | `/features/#verify` |
| `software`, `software-h` | `/#who` |
| `wrong`, `wrong-h` | `/docs/#troubleshooting` |
| `online`, `online-h` | `/docs/#configuration/the-limits-in-short` |
| `environments`, `environments-h` | `/docs/#quick-start/before-you-start` |
| `stop`, `stop-h` | `/docs/#troubleshooting/a-session-or-a-run-was-interrupted` |
| `unattended`, `unattended-h` | `/docs/#configuration/unattended` |

**Anchors of routes that stay** (mechanisms A and B; the step that rewrites the
page keeps them)

| Route | Old anchors | New place |
|---|---|---|
| `/` | `why`, `why-h` | the "Why Codeyard?" section |
| `/` | `example`, `example-h` | alias on the demo section (`demo`) |
| `/` | `roles`, `roles-h` | alias on the demo section (`demo`; the roles show there) |
| `/` | `who`, `who-h`, `start`, `start-h` | the sections of the same name |
| `/` | `projects`, and #370's `evidence` | aliases on "From running features to overseeing them." (`oversee`, #390) |
| `/features/` | `planning`, `planning-h`, `requirements`, `requirements-h`, `requirements-t`, `requirements-words`, `architecture`, `architecture-h`, `planning-t`, `planning-words` | aliases in `agree` |
| `/features/` | `isolation`, `isolation-h`, `isolation-t`, `isolation-words`, `control`, `control-h`, `unattended`, `unattended-h`, `unattended-t`, `unattended-words` | aliases in `independent` |
| `/features/` | `quality`, `quality-h`, `evidence`, `evidence-h`, `evidence-t`, `evidence-words`, `review`, `review-h`, `review-t`, `review-words`, `risk`, `risk-h`, `risk-t`, `risk-words`, `authority`, `authority-h`, `authority-t`, `authority-words` | aliases in `verify` |
| `/features/` | `learn`, `learn-h`, `learn-t`, `learn-words` | the section "Learn from your runs" (`learn`, #390), its one sentence linking `/docs/#technical-reference/learning-from-your-runs` |
| `/examples/` | `products`, `products-h`, `fightanalytics`, `fightanalytics-h`, `application`, `application-h` | the cases (`application` stays the id of the PBC case) |
| `/examples/` | `figures`, `figures-h`, `absent`, `absent-h`, `sources`, `sources-h` | aliases on the PBC evidence disclosure, which a link to them opens |
| `/examples/` | `engineering`, `memory`, `story`, `tradeoff`, `features`, `owner`, `repair`, `short`, `analysis`, `levels` | aliases at the heading of the cases (`products`, #390; they were pointers to Engineering records) |
| `/about/` | `maker`, `maker-h`, `contribute`, `contribute-h` | the parts of the same name |
| `/about/` | `why` | the part "Why it exists" (today an alias on the history sentence) |
| `/about/` | `limits`, `limits-h` | alias on `why` |
| `/about/` | `source`, `source-h`, `improvements` | aliases in `contribute` |
| `/about/` | `history`, `decisions`, `research` | aliases on the one link to the History page, "How Agent Codeyard began" |

### 3.4 Sitemap, search index and tests

- The sitemap lists the routes that stay and are listed: `/`, `/features/`,
  `/about/`, `/docs/`, `/docs/history/`. Since #390 `/examples/` stays
  unlisted (`unlisted` in `src/lib/redirects.ts`) and
  `/docs/engineering-records/` is a redirect page.
- The search index has no redirect page and no unlisted page; its docs
  entries are topics (4.6).
- `search-test.mjs` today asserts exactly the 22 routes and every legacy
  anchor on its own route. #373 changes the assertion to: the sitemap lists
  the routes of the table that stay, and every (route, id) pair of
  `legacy-anchors.json` and the two pointer ids of #335 has a row, mechanical
  or explicit, whose target exists in the build. `legacy-anchors.json` stays
  unchanged as the frozen list of old anchors.
- The redirect test loads each C row in a browser, with and without
  JavaScript, with a sample of its anchors, and checks the final URL and that
  the target element is visible.

---

## 4. Docs interface

### 4.1 One URL, one interface

`/docs/` becomes **Technical Documentation**: one page whose content still
comes from the Markdown files of `website/src/content/docs/` and the two Astro
sources of the workflow reference and the explorer. The files keep their names
and paths (so that #374 and #377 can add facts to them while #373 is open).
The page shows one topic at a time, chosen in the navigation; the URL's hash
says which.

### 4.2 Sections and the files that feed them

A section is a group of the navigation; a topic is one source. A section's id
is also the id of its first topic, so `/docs/#troubleshooting` is both.

| Section (id) | Topic id | Source | Topic title |
|---|---|---|---|
| **Quick Start** (`quick-start`) | `quick-start` | `website/src/content/docs/getting-started.md` | Quick Start |
| | `new-to-agentic-coding` | `website/src/content/docs/new-to-agentic-coding.md` | New to agentic coding? |
| **Adopting an Existing Repository** (`adopting`) | `adopting` | `website/src/content/docs/adopting.md` | Adopting an existing repository |
| **Workflow & Commands** (`workflow-and-commands`) | `workflow-and-commands` | `website/src/content/docs/detailed-workflow.md` | How the workflow works |
| | `workflow-map` | `src/components/WorkflowMap.astro` with `src/lib/workflow.ts` (the explorer of `/workflow/`; added by #377) | The route of a change |
| | `updating` | `website/src/content/docs/updating.md` | Updating a project |
| **Configuration** (`configuration`) | `configuration` | `website/src/content/docs/configuration-and-security.md` | Configuration and security |
| | `agent-roles` | `website/src/content/docs/agent-roles.md` | Agent roles and models |
| | `risk-policy` | `website/src/content/docs/risk-policy.md` | Risk policy and workflow profiles |
| | `github-setup` | `website/src/content/docs/github-setup.md` | GitHub setup |
| **Verification & Review** (`verification-and-review`) | `verification-and-review` | `website/src/content/docs/verification-and-completion.md` | Verification and completion |
| **Troubleshooting** (`troubleshooting`) | `troubleshooting` | `website/src/content/docs/troubleshooting.md` | Troubleshooting |
| **Technical Reference** (`technical-reference`) | `technical-reference` | `website/src/content/docs/technical-reference.md` | Files, records and sources |
| | `workflow-reference` | `src/pages/docs/reference/workflow.astro` content, from `src/lib/steps.ts` (moved into a component) | Workflow reference |
| **Appendix** (links only) | — | `src/pages/docs/history.astro` | How Agent Codeyard began (History and research until #390, which removed Engineering records) |

Where the remaining pages fit: Agent roles, Risk policy and GitHub setup in
Configuration; Updating in Workflow & Commands; New to agentic coding in Quick
Start, after the steps; the workflow reference in Technical Reference;
History in the Appendix, as its own page (Engineering records too, until #390).

Why the Appendix stays outside the one page: History is not documentation
of using Codeyard but background, it is long, About links it once by its own
URL (`/docs/history/`), and keeping its route spares it a redirect. It gets
the new navigation, with "Appendix" as its last group.

When #373 made this plan, the Appendix had two pages, History and
Engineering records (evidence), together about 7 000 words, both linked by
their URLs from Projects and About. #390 removed Engineering records: its
route is now a redirect page to `/docs/history/` (section 8), and Projects
links neither page.

Verification & Review has one file. Review is also explained in
`workflow-and-commands` ("When you disagree, and exceptions") and in
`risk-policy`; the section links both. Moving those parts into it is an
editorial change for a later Issue, not part of #373, which moves files whole.

### 4.3 Deep links

| Address | Opens |
|---|---|
| `/docs/` | Quick Start |
| `/docs/#<section>` | the section, at its first topic |
| `/docs/#<topic>` | the topic |
| `/docs/#<topic>/<id>` | the topic, scrolled to the heading or element whose slug is `<id>` |

Examples: `/docs/#quick-start`, `/docs/#troubleshooting/a-check-fails`,
`/docs/#configuration/agent-attribution`,
`/docs/#risk-policy/shipped-configuration`,
`/docs/#workflow-reference/review-the-code`.

- Every id inside a topic, headings and the explicit ids the Markdown holds
  (for example `gate`, `unattended`, `profiles` in
  `configuration-and-security.md`), gets the prefix `<topic>/` at build time;
  the slugs themselves do not change, so the mapping from an old docs URL is
  mechanical. The prefix also removes the collisions that one page would
  otherwise have: `shipped-configuration` is in `agent-roles.md` and
  `risk-policy.md`, and seven step ids (`describe-the-idea`,
  `review-the-plan`, `approve-the-plan`, `create-a-feature-issue`,
  `implement-the-feature`, `commit-the-feature`, `open-the-pull-request`) are
  in both `detailed-workflow.md` and the workflow reference. The build fails
  on a duplicate id in `/docs/`.
- Links inside the Markdown between docs pages (`href("docs/…/#…")`) are
  rewritten by #373 to the new form.
- Section and topic ids are the table of 4.2; a later rename needs an alias.

### 4.4 Behaviour with JavaScript

- **Desktop (above 1100 px):** three columns. Left: the search and the
  section navigation (sections with their topics; the open section expanded),
  sticky. Middle: the chosen topic only, with its copy buttons and its
  previous and next links in the order of the navigation. Right: "On this
  page", the contents of that topic only, sticky.
- **760 to 1100 px:** two columns; "On this page" sits above the text between
  hairlines, as today.
- **Mobile (to 760 px):** one column. Under the page title, the search and a
  section picker: a disclosure whose summary names the open topic ("Section:
  Troubleshooting"), holding the same navigation; choosing closes it and moves
  focus to the topic's heading. "On this page" follows as a closed disclosure.
- **Router:** a small script reads the hash on load and on `hashchange`. It
  shows the topic (the others get `hidden`), scrolls to the id, sets
  `aria-current` on the navigation link, sets the document title to
  "<topic> · Technical Documentation", and moves focus to the topic heading
  (`tabindex="-1"`) when the visitor chose it, not on first load. The
  navigation consists of ordinary links to `#…`, so back and forward move between
  topics. An unknown hash opens Quick Start; an old id of `/docs/` itself goes
  through the alias table.
- **Keyboard and screen readers:** the navigation is a `nav` with lists; the
  open topic is announced by the focus on its heading; the picker is a native
  `details`; the visible 3 px focus of DESIGN.md applies.

### 4.5 Without JavaScript

Options weighed:

| Option | For | Against |
|---|---|---|
| **Every topic in order on `/docs/`** | One URL and one document; deep links are real ids and work natively; nothing is fetched; the old URLs can become redirects | Without script, a page of about 25 000 words (the docs without the Appendix today), against the proposal's "no enormous page" |
| Old per-topic pages kept as the no-script fallback | Short pages without script | Two URLs for every text; the old URLs cannot redirect, and search engines index both |
| Only Quick Start in the page, others fetched | A small page | Without script only Quick Start; every other section is unreachable |

**Chosen: every topic in order on `/docs/`**, hidden only when the script runs
(the `js` class of DESIGN.md's "complete no-JS state"). The navigation stays
beside the text, sticky on wide screens, so the long page is navigable: every
link jumps within the page. The "no enormous page" of the proposal concerns
the reading experience, which the script gives; a visitor without script gets
every section, nothing hidden. The HTML grows to about 240 KB of article
markup (measured from the current pages), 59 KB compressed with gzip; the page
weight report of `browser-check.mjs` shows it.

### 4.6 Search

The search keeps working as it does: the index is built from the rendered
output by `integrations/search.mjs`, after the build, without a service.
Changes for #373:

- On `/docs/`, each topic is one entry: the integration splits the article
  by its topic elements (`<section data-topic id=…>`), with the topic title as
  the title and `/docs/#<topic>` as the URL. A result may link the heading
  nearest before the match (`/docs/#<topic>/<id>`).
- A result opens its topic through the router, also when the visitor is
  already on `/docs/`.
- The ranking of `src/lib/search.mjs` becomes one by topic: the task topics
  (`quick-start`, `adopting`, `troubleshooting`, `technical-reference`,
  `workflow-reference`) first, then the other topics, then the Appendix, then
  the product pages. The queries of `search-test.mjs` ("existing project",
  "cost", "planning", "resume", "risk", `run-feature.sh`) keep their test.
- Without JavaScript, the search form is not shown (as today); the navigation
  and the browser's find in page cover it, since every topic is in the page.

---

## 5. Source hierarchy

- **The repository's own `docs/` lead for an installed project.** A project
  created from the template, or adopted, has `docs/development.md`,
  `docs/workflow.md`, `docs/repository-setup.md` and the usage text of each
  script, at the version it installed. For that project they are
  authoritative.
- **The website describes the current release**: the files of this repository
  on `main`. `docs/project-map.md` ("Source ownership") already names, per
  topic, the authoritative source and where it is summarised; the website does
  not add a source of its own except for research, history and proposals.
- **Said on the site:** one line under the title of Technical Documentation:
  "This describes the current version on `main`. In your project, its own
  `docs/` describe the version you installed." with a link to "Sources and
  scope" (`/docs/#technical-reference/sources-and-scope`), which takes over the
  text of today's `index.mdx` "Sources and scope" and the project-map
  sentence of `technical-reference.md`.
- **Keeping one set of commands.** The site shows commands, but does not
  define them: each topic summarises a source file of `docs/` and links it
  ("Source:" line). What keeps them together today: `check.sh` checks that
  every script a page names exists in `scripts/` and that every repository
  link names a file on `main`; `search-test.mjs` compares the configuration
  examples with the shipped `agents.conf` and `risk.conf`; the Definition of
  Done asks every feature that changes described behaviour to update the site
  in the same pull request. What is not checked: an option of a script
  (`--risk`, `--only`) named on the site but not in `docs/development.md` or
  the script's usage. Proposed for a follow-up Issue, not for these steps: a
  check that every `<script>.sh --option` on the site occurs in the usage text
  of that script.
- The docs are not generated from `docs/`: the site's text is written for its
  reader (#240, `content-migration.md`), and generating it would change the
  repository's documents for the site. That stays as decided.

---

## 6. Conflicts

Each with a proposed resolution for the owner to accept or change.
`website/design/DESIGN.md` is not changed in this step; the step named in the
resolution changes it explicitly.

| # | Conflict | With | Proposed resolution |
|---|---|---|---|
| 6.1 | Header labels and order "How it works, Why Codeyard, Projects, Docs, About, Get started (`/docs/getting-started/`), GitHub" | DESIGN.md "Header and navigation"; PRODUCT.md "Brand Commitments: Navigation labels"; `src/lib/links.ts`; #329 | #377 changes all three to "Home · Features · Projects · About · Docs · GitHub · [Get Started]", Get Started a primary button to `/docs/#quick-start`, and records the change in DESIGN.md and PRODUCT.md; #390 then removes Projects and Get Started from the header (section 8) |
| 6.2 | Footer "source, contributing, licence, FAQ, About" | DESIGN.md "Footer" | #377: "Open source · MIT; GitHub / Source; Contributing; Security policy; Technical Documentation", and DESIGN.md "Footer" with it |
| 6.3 | Docs pages: a sidebar in four groups (Begin, Use, Configure, Reference), one page per topic, "On this page" per page, previous and next pages, search ranking by page, `content-migration.md` "remain ordinary links without JavaScript" | DESIGN.md "Layout: Docs pages"; #334; #240 | #373 rewrites that paragraph for the one interface of section 4 (sections as navigation groups, the same group-label style, "On this page" per topic, ranking by topic) and adds a line to `content-migration.md` that #373 supersedes its navigation sentence |
| 6.4 | `/workflow/` is retired, but its explorer (route map with switches) is "signature", and PRODUCT.md says "the interactive workflow walkthrough (step-by-step versus unattended), the step tables, the configuration tables" must survive; DESIGN.md also describes the four-step overview and the "Every step in detail" lines of `/workflow` | DESIGN.md "Route map with switches", "Four-step overview", "Workflow explorer", "Layout: Docs pages" (last sentence); PRODUCT.md "Capabilities and Constraints" | The explorer moves into the docs as topic `workflow-map` (Workflow & Commands), unchanged in behaviour, added by #377 before the redirect; the four-step overview is replaced by Home's demo (#370). #377 moves the "Workflow explorer" paragraph to the docs and removes "Four-step overview" from DESIGN.md. **Alternative for the owner:** drop the explorer in favour of the demo; then PRODUCT.md's sentence changes too |
| 6.5 | "No route map with switches on the home page", the home order of #329 | DESIGN.md "Layout: Hero" | #370's own conflict; resolved there, as #370 says. This plan only needs #370 to keep the home ids of 3.3 (the legacy anchor test already requires it) |
| 6.6 | The home page of #370 links Get started to `/docs/getting-started/`, its start routes to `/docs/getting-started/` and `/docs/adopting/`, and "Who it's for" to `/faq/#who`; it says the deeper pages remain `/workflow/`, `/faq/` | #370 against #371 | #370 keeps its links (their targets exist while it runs); #377 changes them to `/docs/#quick-start`, `/docs/#adopting` and `/features/#who`. The redirects keep the old ones working in between |
| 6.7 | Features: eight features in three groups, each with a pitch definition list and a technical layer under `details.proof` "files and settings" (#343, #331); every public page has two reading layers (#328) | DESIGN.md "Layout: Features"; #328, #331, #343 | #374: three themes and the FAQ; the technical layer of each feature moves to its Docs topic (2.3) and Features links it. The two reading layers stay across the site: the first layer on Features, the technical layer in the Docs. The owner's chosen texts of #343 are reused where a theme says the same. #374 rewrites the "Features" paragraph of DESIGN.md |
| 6.8 | About: #344 removed "Why it exists" ("Nothing of it moves elsewhere") and set the order maker, what it does, ready to use, source; #376 asks for who built it, why it exists, open source | DESIGN.md "Layout: About"; #344 | The later decision of 11 November (#371, #376) wins: #376 writes a new short "Why it exists", without restoring the removed text, and rewrites the "About" paragraph of DESIGN.md; "What it does, in short" is removed as a duplicate (2.5) |
| 6.9 | Projects: grouped contents list, engineering cases, "under 3000 visible words" | DESIGN.md "Layout: Projects"; #332, #344 | #375 rewrites the "Projects" paragraph for two or three cases of 100 to 200 words with collapsed evidence; the route stays `/examples/` (the proposal allows it, and it avoids a redirect), the label is Projects |
| 6.10 | "/docs/history/, under Reference" | DESIGN.md "Layout: About" | History and research becomes an Appendix page (4.2); #373 changes the navigation and the sentence |
| 6.11 | `docs/project-map.md` names "The workflow page of the website", "Getting started", "Configuration and security" and "The repository tree on the website" as where topics are summarised | `docs/project-map.md` "Source ownership" | #377 (which retires `/workflow/`) updates those names to the Docs sections; it is documentation, not architecture |
| 6.12 | `search-test.mjs` asserts the 22 routes in the sitemap and in the search index, and every legacy anchor on its own route | the site's tests (#335, #344) | #373 changes the assertion as 3.4 says; `legacy-anchors.json` stays as the frozen list |
| 6.13 | `check.sh` requires a title, a description and a canonical address on every page, and every sitemap address to be a page | `check.sh` | #373 makes it recognise redirect pages (3.2) |
| 6.14 | Projects names FightAnalytics as the model of the gym scenario; Home's demo (#370) uses the gym too; the three labels (simulation, real run, private pilot or future work) must stay apart | #328, #370, #371 | Every page that shows the gym says "Illustrative"; Projects labels FightAnalytics "private pilot" or "illustrative", never "real verifiable run" (#375) |

No conflict with an accepted ADR was found: the ADRs of `docs/decisions/`
concern the workflow, not the site; PRODUCT.md's stack (static Astro on GitHub
Pages, no backend, no external service) holds for every mechanism here.

---

## 7. The order of the following steps

| Order | Issue | Starts | Needs from this plan |
|---|---|---|---|
| 0 | #370 Home | running | keeps the home ids of 3.3; its demo section keeps the id `demo` (PR #378), which #377 uses for `/workflow/`; if it changes, 3.3 is updated first |
| 1 | #372 this plan | — | the owner's approval of sections 2 to 4 and 6 |
| 2 | #373 Docs | after #372 is merged | 3.2 (redirect pages and the table module), rows 7 to 20 of 3.3, section 4, 3.4 (tests), 6.3, 6.10, 6.12, 6.13 |
| 3 | #374 Features | after #372, beside #373 | 2.3, the Features FAQ of 2.6, the Features rows of 3.3, 6.7 |
| 4 | #375 Projects | after #372, beside #373 | 2.4, the Projects rows of 3.3, 6.9, 6.14 |
| 5 | #376 About | after #372, beside #373 | 2.5, the About rows of 3.3, 6.8 |
| 6 | #377 Header, footer, retirements | after #370, #373 and #374 | 2.2, 2.6 (rows 10 and 12 to 15 into the docs), rows 2 and 6 of 3.3, the `workflow-map` topic, 6.1, 6.2, 6.4, 6.6, 6.11 |

What the steps need that the tracking issue does not say:

- **#373 builds the redirect mechanism for everyone.** It is the first step to
  retire routes; it creates the table module, the redirect layout, the test
  that walks the table and the change to `check.sh`. #377 only adds rows.
- **#373 keeps the Markdown files where they are.** #374 and #377 add facts to
  them (2.3, 2.6); stable paths keep those pull requests mergeable beside
  #373. If one lands first, the other rebases.
- **#377 adds the `workflow-map` topic** to the docs before `/workflow/`
  becomes a redirect, because the explorer's target must exist (6.4). It
  therefore touches the docs interface after #373.
- **#374 and #377 move facts, not only text:** before a section is removed as
  a duplicate, the pull request lists the facts of the removed section and
  where each now stands. A fact with no place goes into the destination file
  in the same pull request.
- **#376 and #375 need no redirect:** their routes stay, and their old anchors
  are aliases or pointers (3.3). The Appendix pages keep their URLs (until
  #390, which made `/docs/engineering-records/` a redirect, section 8).
- **Each step changes its own paragraph of DESIGN.md** (6.1 to 6.10), in the
  pull request that departs from it, as #371 requires.
- **One test across the steps:** the walk of the table (3.4) runs in every
  step after #373, so that #374 to #377 cannot drop an old anchor unnoticed.
- **A follow-up Issue, not part of these steps:** the check of script options
  named on the site (section 5).

---

## 8. The owner's brief of 12 November 2026 (#390)

A shorter site, without the record pages, with what is coming next on the
home page and the maker's own story on the History page. The owner's
decisions replace the earlier ones they touch: the six home sections of #370,
the Projects link in the header of #377, the History page of #319 and #333,
and Engineering records as an Appendix page.

| Where | Change | Old anchors |
|---|---|---|
| Home | "Built with the process it describes." (`evidence`, the run of #241 to PR #249, the link to Engineering records) is replaced, between "Why not just use Claude Code or Codex?" and "Who it's for", by "From running features to overseeing them." (`oversee`): one paragraph and two lines "Coming soon:", the supervisor (#361) and open-source local models (#357 to #360), planned work with no date | `evidence`, `evidence-h`, `projects` are aliases on `oversee` |
| Features | The three paragraphs "Illustrative example." are removed; "Learning from the runs" becomes the section "Learn from your runs" (`learn`) after `verify`; the cost answer no longer links Engineering records | `learn`, `learn-h`, `learn-t`, `learn-words` in `learn` |
| Engineering records | The page `/docs/engineering-records/` is removed from the site, the docs navigation, the Appendix and the search; the route is a redirect page (C, `src/pages/docs/[...slug].astro`) to `/docs/history/`; no page links it | every id to `/docs/history/` (row 21 of 3.3) |
| Projects | `/examples/` stays at its URL, built, but unlisted: no link from the header, the footer, Home, About, Features or the docs; not in the sitemap or the search index; its lines that pointed to Engineering records are removed | the old pointer ids are aliases at the heading of the cases |
| Header | Home, Features, About, Docs, GitHub, then the theme toggle; Projects and the button Get Started leave it. The hero's "Get Started" link and the home section "Give your coding agents a process" keep Quick Start; `/docs/getting-started/` stays a redirect to `/docs/#quick-start` | — |
| About | The first paragraph is the owner's, word for word; the sentence about the projects is removed; the link to History says "How Agent Codeyard began" | unchanged |
| History | Opens with the owner's story in the first person, word for word, under the title "How Agent Codeyard began" (also its title in the navigation), its four parts as level-2 headings, then "What comes next" (planned work, no date); "In short", "Engineering principles" and "Design decisions" are removed; the period list ("History") and "Research" stay below | `phases`, `principles`, `decisions` are aliases at the top of the page |

The tests follow: `src/lib/redirects.test.ts` (the redirect and the unlisted
route), `src/lib/docs.test.ts` (the Appendix), `search-test.mjs` (the
sitemap, the search index, no link to `/examples/` or the removed page, the
walk of the old anchors) and `browser-check.mjs` (the home sections, the
header, Features, About, History and the old anchors of Projects).
