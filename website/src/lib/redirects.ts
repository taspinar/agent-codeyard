// The old addresses of the site and where they lead now: the table of
// website/design/INFORMATION-ARCHITECTURE.md, 3.3, as data. The redirect
// pages (src/pages/docs/[...slug].astro), the router of /docs/, the sitemap
// and search-test.mjs read it; #373 created it, the later steps add rows.
//
// A route with a topic is retired: its page is a redirect to /docs/#<topic>,
// and every id of it maps to /docs/#<topic>/<the same id> ("mechanical"),
// the ids of the layout to the topic itself. A route without a topic stays,
// with its ids.

export type Route = { path: string; title?: string; topic?: string };

export const routes: Route[] = [
  { path: "" },
  { path: "workflow/" },
  { path: "features/" },
  { path: "examples/" },
  { path: "about/" },
  { path: "faq/" },
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
export const stays = routes.filter((route) => !route.topic);

/** The retired routes, each a redirect page. */
export const retired = routes.filter((route) => route.topic);

/**
 * The new address of an old route and one of its ids, as a path under the
 * base with its fragment: a retired route leads into its topic.
 */
export function moved(route: Route, id?: string): string {
  if (!route.topic) return route.path + (id ? `#${route.path === "docs/" ? docsAliases[id] ?? id : id}` : "");
  if (!id || layoutIds.includes(id)) return `docs/#${route.topic}`;
  return `docs/#${route.topic}/${id}`;
}
