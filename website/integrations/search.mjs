import { readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join, relative, sep } from 'node:path';
import { pageRank } from '../src/lib/search.mjs';

export function plainText(html) {
  const entities = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  return html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
    .replace(/<[^>]*>/g, ' ')
    .replace(/&(#x[\da-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (_, entity) => {
      if (entity[0] !== '#') return entities[entity.toLowerCase()];
      const value = entity[1].toLowerCase() === 'x'
        ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return value <= 0x10ffff ? String.fromCodePoint(value) : '';
    }).replace(/\s+/g, ' ').trim();
}

/** The topics of an article, by their <section data-topic>, with their title and text. */
export function topicsOf(article) {
  const parts = article.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '').split(/(?=<section\b[^>]*\bdata-topic=)/);
  return parts.flatMap(part => {
    const open = part.match(/^<section\b[^>]*\bdata-topic="([^"]+)"[^>]*\bdata-title="([^"]+)"/);
    return open ? [{ id: open[1], title: plainText(open[2]), text: plainText(part.replace(/<nav\b[^>]*class="docs-pagination"[\s\S]*?<\/nav>/, '')) }] : [];
  });
}

/** Index the rendered output, so MDX, tables and code are searchable too. */
export default function searchIndex() {
  let base;
  return { name: 'local-search', hooks: {
    'astro:config:done': ({ config }) => { base = config.base.replace(/\/?$/, '/'); },
    'astro:build:done': async ({ dir }) => {
      const root = fileURLToPath(dir);
      const pages = [];
      async function walk(directory) {
        for (const entry of await readdir(directory, { withFileTypes: true })) {
          const path = join(directory, entry.name);
          if (entry.isDirectory()) await walk(path);
          else if (entry.name === 'index.html') {
            const html = await readFile(path, 'utf8');
            const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1];
            if (!main) continue;
            const page = relative(root, path).split(sep).join('/').replace(/index\.html$/, '');
            const article = main.match(/<article\b[^>]*\bdata-search\b[^>]*>([\s\S]*?)<\/article>/i)?.[1];
            const topics = topicsOf(article ?? '');
            // Technical Documentation: one entry per topic, which the router opens (#373).
            if (topics.length) {
              for (const topic of topics) pages.push({ title: topic.title, url: `${base}${page}#${topic.id}`, rank: pageRank(`${page}#${topic.id}`), text: topic.text });
              continue;
            }
            pages.push({
              title: plainText(html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1] || ''),
              url: base + page,
              rank: pageRank(page),
              text: plainText(article || main),
            });
          }
        }
      }
      await walk(root);
      await writeFile(join(root, 'search-index.json'), JSON.stringify(pages));
    },
  } };
}
