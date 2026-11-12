import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { z } from "astro/zod";

// The documentation: one Markdown file per topic of /docs/ (src/lib/docs.ts).
const docs = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/docs" }),
  schema: z.object({
    title: z.string(),
    order: z.number().default(0),
    description: z.string(),
  }),
});

export const collections = { docs };
