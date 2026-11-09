// The sidebar of the documentation: its pages in groups, in the order of the
// sidebar and of the previous and next links. A page is the id of an entry of
// the docs collection, or a page of its own (the workflow reference, built
// from src/lib/steps.ts, Engineering records and History and research) with
// its title. The groups go from beginning and using the workflow to
// configuring it and looking things up (#334).

export type Page = { id: string; title?: string };

export const groups: { label?: string; pages: Page[] }[] = [
  { label: "Begin", pages: [{ id: "index" }, { id: "new-to-agentic-coding" }, { id: "getting-started" }, { id: "adopting" }] },
  { label: "Use", pages: [{ id: "detailed-workflow" }, { id: "troubleshooting" }, { id: "updating" }] },
  { label: "Configure", pages: [{ id: "github-setup" }, { id: "agent-roles" }, { id: "risk-policy" }, { id: "verification-and-completion" }, { id: "configuration-and-security" }] },
  { label: "Reference", pages: [{ id: "reference/workflow", title: "Workflow reference" }, { id: "technical-reference" }, { id: "engineering-records", title: "Engineering records" }, { id: "history", title: "History and research" }] },
];

/** The path of a page under the site, without the base. */
export const path = (id: string) => `docs/${id === "index" ? "" : id + "/"}`;

/**
 * The groups with the title of every page, from the collection where the page
 * is an entry. Every entry of the collection is in exactly one group.
 */
export function sidebar(entries: { id: string; data: { title: string } }[]) {
  const listed = groups.flatMap((group) => group.pages.map((page) => page.id));
  for (const entry of entries) {
    if (listed.filter((id) => id === entry.id).length !== 1) throw new Error(`docs sidebar: ${entry.id} is not listed exactly once`);
  }
  return groups.map((group) => ({
    label: group.label,
    pages: group.pages.map((page) => {
      const title = page.title ?? entries.find((entry) => entry.id === page.id)?.data.title;
      if (!title) throw new Error(`docs sidebar: ${page.id} is not a page`);
      return { id: page.id, title };
    }),
  }));
}
