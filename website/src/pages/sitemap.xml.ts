// sitemap.xml: every page of the site that stays, with its full address
// (src/lib/redirects.ts); a redirect page and an unlisted page (#390) are not
// listed. Technical
// Documentation is one page, /docs/, with its Appendix pages.
import type { APIRoute } from "astro";
import { href } from "../lib/links";
import { listed } from "../lib/redirects";

export const GET: APIRoute = async ({ site }) => {
  const urls = listed.map((route) => `  <url><loc>${new URL(href(route.path), site).href}</loc></url>`);
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.join("\n")}
</urlset>
`;
  return new Response(body, { headers: { "Content-Type": "application/xml" } });
};
