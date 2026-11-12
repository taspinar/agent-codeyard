// Technical Documentation: one page, /docs/, whose sections group topics
// (website/design/INFORMATION-ARCHITECTURE.md, 4.2; #373). A topic is one
// source: an entry of the docs collection, or a component: the workflow map
// (#377, from /workflow/) or the workflow reference, both built from
// src/lib/steps.ts. A section's id is the id of its first topic, so
// /docs/#troubleshooting opens both. The Appendix pages keep their own routes
// and get the same navigation, as its last group.

export type Topic = { id: string; title: string; entry?: string };
export type Section = { id: string; label: string; topics: Topic[] };

export const sections: Section[] = [
  { id: "quick-start", label: "Quick Start", topics: [
    { id: "quick-start", title: "Quick Start", entry: "getting-started" },
    { id: "new-to-agentic-coding", title: "New to agentic coding?", entry: "new-to-agentic-coding" },
  ] },
  { id: "adopting", label: "Adopting an Existing Repository", topics: [
    { id: "adopting", title: "Adopting an existing repository", entry: "adopting" },
  ] },
  { id: "workflow-and-commands", label: "Workflow & Commands", topics: [
    { id: "workflow-and-commands", title: "How the workflow works", entry: "detailed-workflow" },
    { id: "workflow-map", title: "The workflow as a map" },
    { id: "updating", title: "Updating a project", entry: "updating" },
  ] },
  { id: "configuration", label: "Configuration", topics: [
    { id: "configuration", title: "Configuration and security", entry: "configuration-and-security" },
    { id: "agent-roles", title: "Agent roles and models", entry: "agent-roles" },
    { id: "risk-policy", title: "Risk policy and workflow profiles", entry: "risk-policy" },
    { id: "github-setup", title: "GitHub setup", entry: "github-setup" },
  ] },
  { id: "verification-and-review", label: "Verification & Review", topics: [
    { id: "verification-and-review", title: "Verification and completion", entry: "verification-and-completion" },
  ] },
  { id: "troubleshooting", label: "Troubleshooting", topics: [
    { id: "troubleshooting", title: "Troubleshooting", entry: "troubleshooting" },
  ] },
  { id: "technical-reference", label: "Technical Reference", topics: [
    { id: "technical-reference", title: "Files, records and sources", entry: "technical-reference" },
    { id: "workflow-reference", title: "Workflow reference" },
  ] },
];

/** The Appendix: pages of their own, linked from the navigation. Engineering records left it (#390). */
export const appendix = [
  { path: "docs/history/", title: "How Agent Codeyard began" },
];

/** Every topic, in the order of the navigation and of the previous and next links. */
export const topics = sections.flatMap((section) => section.topics);

/** The topic that opens when the address names none. */
export const first = topics[0];

/**
 * The HTML of a topic for the one page: every id gets the prefix "<topic>/",
 * and so does every link to an id of the same topic. A link to a topic
 * ("#adopting") or into one ("#risk-policy/three-settings") is left as it is.
 * Headings go one level down, below the title of the topic.
 */
export function prefixed(html: string, topic: string): string {
  const own = new Set([...html.matchAll(/<[a-z][a-z0-9]*\b[^>]*?\sid="([^"]+)"/g)].map((match) => match[1]));
  const names = new Set(topics.map((t) => t.id));
  return html
    .replace(/(<[a-z][a-z0-9]*\b[^>]*?\s)id="([^"]+)"/g, (_, tag, id) => `${tag}id="${topic}/${id}"`)
    .replace(/(<a\b[^>]*?\s)href="#([^"/]+)"/g, (whole, tag, id) => {
      if (own.has(id)) return `${tag}href="#${topic}/${id}"`;
      if (names.has(id)) return whole;
      throw new Error(`docs: ${topic} links to #${id}, which is neither one of its ids nor a topic`);
    })
    .replace(/<(\/?)h([2-5])\b/g, (_, close, level) => `<${close}h${Number(level) + 1}`);
}
