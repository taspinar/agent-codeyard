// Pages a visitor uses to do something; they rank above the other pages that
// match the same words (#321).
const tasks = ['docs/getting-started/', 'docs/adopting/', 'docs/troubleshooting/', 'docs/technical-reference/', 'docs/reference/'];

/** The rank of a page by its path under the base: 0 a task page, 1 another docs page, 2 any other page. */
export function pageRank(path) {
  if (tasks.some(task => path.startsWith(task))) return 0;
  return path.startsWith('docs/') ? 1 : 2;
}

function queryWords(query) {
  return query.toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
}

/** Match every query word against the page title and rendered text; task pages first. */
export function searchPages(pages, query) {
  const words = queryWords(query);
  if (!words.length) return [];
  return pages.filter(page => words.every(word =>
    `${page.title} ${page.text}`.toLocaleLowerCase().includes(word)))
    .map((page, order) => ({ page, order }))
    .sort((a, b) => (a.page.rank ?? 2) - (b.page.rank ?? 2) || a.order - b.order)
    .map(({ page }) => page);
}

/** Every place where one of the words occurs in the lower-case text. */
function places(lower, word) {
  const found = [];
  for (let i = lower.indexOf(word); i >= 0; i = lower.indexOf(word, i + 1)) found.push(i);
  return found;
}

/**
 * A short passage of the text around the matched words, as parts that say
 * whether they are a match: the place where the query occurs as a phrase, else
 * the first place where the most query words fall into the passage; empty
 * when the text has none of them.
 */
export function passage(text, query, length = 160) {
  const words = queryWords(query);
  const lower = text.toLocaleLowerCase();
  let at = words.length ? lower.indexOf(words.join(' ')) : -1;
  if (at < 0) {
    const found = words.map(word => places(lower, word));
    let best = 0;
    for (const i of found.flat().sort((a, b) => a - b)) {
      const near = found.filter(list => list.some(j => j >= i && j < i + length / 2)).length;
      if (near > best) [best, at] = [near, i];
    }
  }
  if (at < 0) return [];
  let start = Math.max(0, at - Math.floor(length / 3));
  let end = Math.min(text.length, start + length);
  if (start > 0) start = text.indexOf(' ', start) + 1 || start;
  if (end < text.length) end = text.lastIndexOf(' ', end) > at ? text.lastIndexOf(' ', end) : end;
  const excerpt = text.slice(start, end);
  const pattern = new RegExp(words.map(word => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'gi');
  const parts = [];
  let last = 0;
  for (const match of excerpt.matchAll(pattern)) {
    if (match.index > last) parts.push({ text: excerpt.slice(last, match.index), match: false });
    parts.push({ text: match[0], match: true });
    last = match.index + match[0].length;
  }
  if (last < excerpt.length) parts.push({ text: excerpt.slice(last), match: false });
  if (start > 0) parts.unshift({ text: '… ', match: false });
  if (end < text.length) parts.push({ text: ' …', match: false });
  return parts;
}

/**
 * The passage of a search result: from its text when the text holds every
 * query word, else from its title and text, so a word matched only in the
 * title is shown too.
 */
export function resultPassage(page, query, length = 160) {
  const lower = page.text.toLocaleLowerCase();
  const inText = queryWords(query).every(word => lower.includes(word));
  return passage(inText ? page.text : `${page.title}: ${page.text}`, query, length);
}
