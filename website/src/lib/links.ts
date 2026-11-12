import { site } from "../../site.config";

const base = import.meta.env.BASE_URL.replace(/\/?$/, "/");

/** A link to a page or file of the site, under the base path. */
export function href(path = ""): string {
  return base + path.replace(/^\/+/, "");
}

/** A link to a file of the repository on its default branch. */
export function repoFile(path: string): string {
  return `${site.repository}/blob/${site.branch}/${path}`;
}

/** A link to an Issue or a pull request of the repository. */
export function issue(number: number): string {
  return `${site.repository}/issues/${number}`;
}

/** A link to a pull request of the repository. */
export function pull(number: number): string {
  return `${site.repository}/pull/${number}`;
}

/** The destinations of the site, in the order of the navigation (#377). */
export const sections = [
  { path: "", label: "Home" },
  { path: "features/", label: "Features" },
  { path: "examples/", label: "Projects" },
  { path: "about/", label: "About" },
  { path: "docs/", label: "Docs" },
] as const;

/** The action "Get Started": the Quick Start of the docs, from every page (#377). */
export const getStarted = "docs/#quick-start";
