// The old addresses of the site and where they lead now: the table of
// website/design/INFORMATION-ARCHITECTURE.md, 3.3, as data. The redirect
// pages (src/pages/docs/[...slug].astro), the router of /docs/, the sitemap
// and search-test.mjs read it; #373 created it, the later steps add rows.
//
// A route with a topic is retired: its page is a redirect to /docs/#<topic>,
// and every id of it maps to /docs/#<topic>/<the same id> ("mechanical"),
// the ids of the layout to the topic itself. A route with a target (#377) is
// retired too: its page is a redirect to that target, and its ids map as its
// own table says, an unknown id to the target. A route with neither stays,
// with its ids.

export type Route = { path: string; title?: string; topic?: string; to?: string; label?: string; anchors?: Record<string, string> };

/** The step ids of the workflow reference, which /workflow/ linked from "Every step in detail". */
const steps = ["describe-the-idea", "clarify-the-requirements", "create-the-plan", "review-the-plan", "address-the-findings", "approve-the-plan", "merge-the-plan", "change-the-plan", "create-a-feature-issue", "implement-the-feature", "run-the-checks", "review-the-code", "decide-on-the-findings", "apply-the-fixes", "commit-the-feature", "open-the-pull-request", "merge", "run-unattended"];

/** The ids of the explorer of /workflow/, now the topic "workflow-map" of the docs. */
const explorer = ["explore", "workflow", "workflow-title", "workflow-map-title", "workflow-words", "step-panel", "step-panel-h", "step-tab-overview", "step-tab-technical", "step-tab-failure", "step-tab-body", "routes-label"];

/** Each of the ids, with its "-h" heading id, to one target. */
const each = (ids: string[], to: (id: string) => string) => Object.fromEntries(ids.flatMap((id) => [[id, to(id)], [`${id}-h`, to(id)]]));

/** /workflow/ (website/design/INFORMATION-ARCHITECTURE.md, 3.3, row 2). */
const workflow: Record<string, string> = {
  ...Object.fromEntries(["main", "overview", "overview-h", "describe-and-clarify", "plan-the-work", "build-and-check", "decide"].map((id) => [id, "#demo"])),
  technical: "docs/#workflow-map",
  "technical-h": "docs/#workflow-map",
  ...Object.fromEntries(explorer.map((id) => [id, `docs/#workflow-map/${id}`])),
  ...each(["ways"], () => "docs/#workflow-and-commands/step-by-step-or-unattended"),
  ...each(["case"], () => "docs/engineering-records/#story"),
  ...each(["steps"], () => "docs/#workflow-reference"),
  ...Object.fromEntries(steps.map((id) => [id, `docs/#workflow-reference/${id}`])),
};

/** /faq/ (website/design/INFORMATION-ARCHITECTURE.md, 3.3, row 6). */
const faq: Record<string, string> = {
  main: "features/#faq",
  ...each(["what"], () => "features/"),
  ...each(["replace", "who", "cost", "data", "existing", "too-heavy"], (id) => `features/#${id}`),
  ...each(["permission", "checked", "review"], () => "features/#verify"),
  ...each(["software"], () => "#who"),
  ...each(["wrong"], () => "docs/#troubleshooting"),
  ...each(["online"], () => "docs/#configuration/the-limits-in-short"),
  ...each(["environments"], () => "docs/#quick-start/before-you-start"),
  ...each(["stop"], () => "docs/#troubleshooting/a-session-or-a-run-was-interrupted"),
  ...each(["unattended"], () => "docs/#configuration/unattended"),
};

export const routes: Route[] = [
  { path: "" },
  { path: "workflow/", title: "How it works", to: "#demo", label: "the workflow demo on the home page", anchors: workflow },
  { path: "features/" },
  { path: "examples/" },
  { path: "about/" },
  { path: "faq/", title: "FAQ", to: "features/#faq", label: "the questions on Features", anchors: faq },
  { path: "docs/adopting/", title: "Adopting Agent Codeyard in an existing repository", topic: "adopting" },
  { path: "docs/agent-roles/", title: "Agent roles and models", topic: "agent-roles" },
  { path: "docs/configuration-and-security/", title: "Configuration and security", topic: "configuration" },
  { path: "docs/detailed-workflow/", title: "How the workflow works", topic: "workflow-and-commands" },
  { path: "docs/getting-started/", title: "Getting started", topic: "quick-start" },
  { path: "docs/github-setup/", title: "GitHub setup", topic: "github-setup" },
  { path: "docs/" },
  { path: "docs/new-to-agentic-coding/", title: "New to agentic coding? Start here", topic: "new-to-agentic-coding" },
  { path: "docs/risk-policy/", title: "Risk policy and workflow profiles", topic: "risk-policy" },
  { path: "docs/technical-reference/", title: "Technical reference (advanced)", topic: "technical-reference" },
  { path: "docs/troubleshooting/", title: "Troubleshooting", topic: "troubleshooting" },
  { path: "docs/updating/", title: "Updating an Agent Codeyard project", topic: "updating" },
  { path: "docs/verification-and-completion/", title: "Verification and completion", topic: "verification-and-review" },
  { path: "docs/reference/workflow/", title: "Workflow reference", topic: "workflow-reference" },
  { path: "docs/engineering-records/" },
  { path: "docs/history/" },
];

/** The ids of the layout of a docs page, not of its content. */
export const layoutIds = ["main", "docs-query", "search-status", "search-results"];

/**
 * The old ids of /docs/ itself, whose sections were removed or moved
 * (mechanism A): each leads to an id of the one page. The page holds an empty
 * element with the old id at the new place, and the router goes on to the new id.
 */
export const docsAliases: Record<string, string> = {
  "what-stays-with-you": "configuration/the-limits-in-short",
  "find-a-command-or-setting": "docs-query",
  "more-to-read": "quick-start",
  "sources-and-scope": "technical-reference/sources-and-scope",
};

/** The routes that stay: the pages of the sitemap. */
export const stays = routes.filter((route) => !route.topic && !route.to);

/** The retired routes, each a redirect page. */
export const retired = routes.filter((route) => route.topic || route.to);

/**
 * The new address of an old route and one of its ids, as a path under the
 * base with its fragment: a retired route leads into its topic.
 */
export function moved(route: Route, id?: string): string {
  if (route.to) return (id && route.anchors?.[id]) || route.to;
  if (!route.topic) return route.path + (id ? `#${route.path === "docs/" ? docsAliases[id] ?? id : id}` : "");
  if (!id || layoutIds.includes(id)) return `docs/#${route.topic}`;
  return `docs/#${route.topic}/${id}`;
}
