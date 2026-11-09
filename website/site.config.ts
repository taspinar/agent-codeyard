// The one place for the public name, the repository and the address of the
// site. SITE_URL and BASE_PATH come from the environment, so the same build
// serves the custom domain at the root and the project path on GitHub Pages:
//
//   npm run build                                   (https://agentcodeyard.com/)
//   SITE_URL=https://taspinar.github.io BASE_PATH=/agent-codeyard/ npm run build

/** A base path with one slash at each end: "/" or "/name/". */
function basePath(value: string | undefined): string {
  const trimmed = (value ?? "/").replace(/^\/+|\/+$/g, "");
  return trimmed ? `/${trimmed}/` : "/";
}

export const site = {
  /** The product name. */
  name: "Agent Codeyard",
  /** The short name, used in running text after the full name. */
  shortName: "Codeyard",
  /** The earlier name, which only About names, once, as "formerly". */
  formerName: "Agentic Coding Template (ACT)",
  /** The positioning line, the hero headline and the title of the home page. */
  tagline: "Build software with AI, with a clear plan and checks along the way.",
  /** The supporting line, the description of the home page. */
  description:
    "Describe what you want to build. Agent Codeyard helps you clarify it, plan the work and guide AI coding tools as they build and check each change. You decide what to accept.",
  /** The repository on GitHub, without a trailing slash. */
  repository: "https://github.com/taspinar/agent-codeyard",
  /** The branch whose files the site links to. */
  branch: "main",
  /** The origin the site is served from, without a path. */
  siteUrl: (process.env.SITE_URL || "https://agentcodeyard.com").replace(/\/+$/, ""),
  /** The path the site is served under. */
  basePath: basePath(process.env.BASE_PATH),
};
