import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { plainText } from './integrations/search.mjs';
import { pageRank, passage, resultPassage, searchPages } from './src/lib/search.mjs';
import { feature, planning } from './src/lib/steps.ts';

assert.equal(plainText('<p>A &amp; B &#x3c; C</p><script>secret</script>'), 'A & B < C');
const example = [{ title: 'Risk policy', text: 'verification: groups', url: '/docs/risk/' }];
assert.equal(searchPages(example, 'RISK groups').length, 1);
assert.equal(searchPages(example, 'risk absent').length, 0);
assert.equal(searchPages(example, '  ').length, 0);
// Task pages first, then the other docs, then the product pages, each in index order.
const ranked = ['about/', 'docs/history/', 'docs/adopting/', 'examples/', 'docs/reference/workflow/']
  .map(path => ({ title: path, text: 'existing repository', url: `/${path}`, rank: pageRank(path) }));
assert.deepEqual(searchPages(ranked, 'existing repository').map(p => p.title),
  ['docs/adopting/', 'docs/reference/workflow/', 'docs/history/', 'about/', 'examples/']);
// A passage around the matched words, with the words marked.
const words = 'one two three four five six seven eight nine ten '.repeat(10) + 'adopt an Existing Repository here ' + 'eleven twelve '.repeat(20);
const parts = passage(words, 'existing repository', 80);
const shown = parts.map(part => part.text).join('');
assert(shown.length < 100 && shown.startsWith('… ') && shown.endsWith(' …'), shown);
assert.deepEqual(parts.filter(part => part.match).map(part => part.text), ['Existing', 'Repository']);
assert.deepEqual(passage('nothing here', 'absent'), []);
// Without the phrase, the passage goes where most of the words are.
assert.deepEqual(passage('a repository, ' + 'then more words '.repeat(10) + 'an existing one, a repository', 'existing repository', 60).filter(part => part.match).map(part => part.text), ['existing', 'repository']);
// A result that matches only in its title still shows the matched words (#321).
assert.deepEqual(resultPassage(example[0], 'risk').filter(part => part.match).map(part => part.text), ['Risk']);
assert.deepEqual(resultPassage(example[0], 'risk groups').filter(part => part.match).map(part => part.text), ['Risk', 'groups']);
// Every result of a search has a passage with a matched word.
for (const page of searchPages([...example, ...ranked], 'risk')) assert(resultPassage(page, 'risk').some(part => part.match), page.title);

if (process.argv[2]) {
  const [output, base] = process.argv.slice(2);
  const pages = JSON.parse(await readFile(join(output, 'search-index.json'), 'utf8'));
  const docs = pages.filter(p => p.url.startsWith(`${base}docs/`));
  assert.equal(docs.length, 16);
  for (const [query, slug] of [['Troubleshooting', 'troubleshooting'], ['GitHub setup', 'github-setup']]) {
    const results = searchPages(docs, query);
    assert(results.some(p => p.url === `${base}docs/${slug}/`));
    assert(results.length < docs.length, `Navigation leaked into search: ${query}`);
    assert(!results.some(p => p.url === `${base}docs/agent-roles/`), `Sidebar-only match: ${query}`);
  }
  // A visitor with an existing repository finds Adopting first, with a passage that shows the words (#321).
  const existing = searchPages(pages, 'existing repository');
  assert.equal(existing[0]?.url, `${base}docs/adopting/`, `First for "existing repository": ${existing[0]?.url}`);
  assert(resultPassage(existing[0], 'existing repository').some(part => part.match), 'No matched words in the passage of Adopting');
  for (const product of ['about/', 'examples/']) {
    const at = existing.findIndex(p => p.url === `${base}${product}`);
    for (const task of ['docs/getting-started/', 'docs/troubleshooting/']) {
      const before = existing.findIndex(p => p.url === `${base}${task}`);
      if (at >= 0 && before >= 0) assert(before < at, `${task} after ${product}`);
    }
  }
  // The questions of a new visitor lead to a task page first (#334).
  for (const query of ['existing project', 'cost', 'planning', 'resume', 'risk', 'run-feature.sh']) {
    const results = searchPages(pages, query);
    assert.equal(pageRank(results[0]?.url.slice(base.length) ?? ''), 0, `First for "${query}": ${results[0]?.url}`);
  }
  // The sitemap lists the pages outside the docs collection too.
  const sitemap = await readFile(join(output, 'sitemap.xml'), 'utf8');
  assert(sitemap.includes(`${base}docs/reference/workflow/</loc>`), 'The workflow reference is missing from the sitemap');
  // The sitemap and the search index list exactly the routes of the live site
  // before #335: the 21 its Issue names and Engineering records (#344), 22 in
  // all. Every anchor of those pages still resolves.
  const legacy = JSON.parse(await readFile(new URL('./legacy-anchors.json', import.meta.url), 'utf8')).pages;
  const routes = Object.keys(legacy).sort();
  assert.equal(routes.length, 22);
  const located = [...sitemap.matchAll(/<loc>[^<]*?\/\/[^/<]+([^<]*)<\/loc>/g)].map(m => m[1].slice(base.length)).sort();
  assert.deepEqual(located, routes, 'The sitemap lists other routes than the live site before #335');
  assert.deepEqual(pages.map(p => p.url.slice(base.length)).sort(), routes, 'The search index lists other routes than the live site before #335');
  for (const [route, ids] of Object.entries(legacy)) {
    const html = await readFile(join(output, route, 'index.html'), 'utf8');
    for (const id of ids) assert(html.includes(`id="${id}"`), `Old anchor lost: /${route}#${id}`);
  }
  // Anchors dropped by earlier steps of #328 and restored as pointers (#335).
  for (const [route, id] of [['', 'projects'], ['examples/', 'engineering']]) {
    assert((await readFile(join(output, route, 'index.html'), 'utf8')).includes(`id="${id}"`), `Old anchor lost: /${route}#${id}`);
  }
  assert(searchPages(pages, 'LICENSE').some(p => p.url === `${base}docs/getting-started/`));
  // History and research moved from About to the docs (#319).
  assert(searchPages(docs, 'Physics by Construction').some(p => p.url === `${base}docs/history/`));
  // The engineering case studies moved from Projects to Engineering records (#344).
  assert(sitemap.includes(`${base}docs/engineering-records/</loc>`), 'Engineering records is missing from the sitemap');
  for (const query of ['41 recorded runs', '#217']) {
    assert(searchPages(pages, query).some(p => p.url === `${base}docs/engineering-records/`), `Engineering records not found for "${query}"`);
  }
  const records = await readFile(join(output, 'docs/engineering-records/index.html'), 'utf8');
  const projects = await readFile(join(output, 'examples/index.html'), 'utf8');
  for (const id of ['memory', 'story', 'tradeoff', 'features', 'owner', 'repair', 'short', 'analysis', 'levels']) {
    assert(records.includes(`<h2 id="${id}">`), `Not in Engineering records: ${id}`);
    assert(projects.includes(`<p id="${id}" class="moved-case">This case moved to <a href="${base}docs/engineering-records/#${id}">Engineering records</a>.</p>`), `Old anchor lost: /examples/#${id}`);
  }
  assert(!/When the reviewer did not know|What 41 recorded runs/.test(projects), 'An engineering case is still on Projects');
  assert(searchPages(pages, 'owner-directed').some(p => p.url === `${base}docs/detailed-workflow/`));
  // Every step is in the workflow reference, and its old anchor on /workflow leads there.
  const reference = await readFile(join(output, 'docs/reference/workflow/index.html'), 'utf8');
  const workflow = await readFile(join(output, 'workflow/index.html'), 'utf8');
  assert(workflow.includes('id="steps"'), 'The section anchor of /workflow is gone');
  for (const { id } of [...planning, ...feature]) {
    assert(reference.includes(`<section class="ref-step" id="${id}"`), `Not in the reference: ${id}`);
    assert(workflow.includes(`<a id="${id}" href="${base}docs/reference/workflow/#${id}">`), `Old anchor lost: /workflow/#${id}`);
  }
  // The gym scenario of #328 says the same on every page that uses it (#335).
  const gym = [
    [/members see their own(?! training history)/i, 'the function: "members see their own training history"'],
    [/member who (?!requests another member's history is refused)\w+ (for )?another member's history/i, 'the check: "a member who requests another member\'s history is refused"'],
    [/correction keeps the original entry visible(?! as corrected)/i, 'the agreement: "a correction keeps the original entry visible as corrected"'],
    [/users and roles(,| first,) then (?!classes and attendance, then the member's history view)/i, 'the plan: "users and roles, then classes and attendance, then the member\'s history view"'],
    [/let every signed-in user open (?!the history view)/i, 'the finding: "the first version let every signed-in user open the history view"'],
  ];
  // The canonical parts, and the routes that use each of them: a part removed
  // or reworded on one of these pages fails.
  const parts = {
    function: /trainers record attendance for their classes(;|,? and) members see their own training history/i,
    check: /a member who requests another member's history is refused/i,
    agreement: /a correction keeps the original entry visible as corrected/i,
    plan: /users and roles\b[^.]*?\bclasses and attendance\b[^.]*?\bthe member's history view/i,
    finding: /the first version let every signed-in user open the history view/i,
  };
  const uses = {
    '': ['function'],
    'workflow/': Object.keys(parts),
    'features/': ['function', 'plan', 'check', 'finding'],
    'faq/': ['function'],
    'docs/getting-started/': ['function'],
    'docs/new-to-agentic-coding/': Object.keys(parts),
    'docs/verification-and-completion/': ['function', 'check'],
  };
  const scenario = [];
  for (const page of pages) {
    const route = page.url.slice(base.length);
    const text = plainText(await readFile(join(output, route, 'index.html'), 'utf8')).replace(/[‘’]/g, "'").replace(/\s+/g, ' ');
    for (const [variant, canonical] of gym) assert(!variant.test(text), `${page.url}: the gym scenario differs from ${canonical}`);
    if (/\battendance\b/i.test(text)) scenario.push(route);
    for (const part of uses[route] ?? []) assert(parts[part].test(text), `${page.url}: the ${part} of the gym scenario is missing or reworded`);
  }
  assert.deepEqual(scenario.sort(), Object.keys(uses).sort(), 'Other pages use the gym scenario than search-test.mjs checks');
  for (const page of pages) {
    assert(page.url.startsWith(base));
    const html = await readFile(join(output, page.url.slice(base.length), 'index.html'), 'utf8');
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length, `Duplicate anchors: ${page.url}`);
    if (page.url.startsWith(`${base}docs/`)) {
      assert(html.includes('aria-label="Documentation"'));
      assert(html.includes('aria-current="page"'));
      assert(html.includes('aria-label="Previous and next pages"'));
    }
  }
}

// Shipped examples must move with their source configuration.
for (const [slug, source] of [['agent-roles', '.agents/agents.conf'], ['risk-policy', '.agents/policies/risk.conf']]) {
  const config = await readFile(new URL(`../${source}`, import.meta.url), 'utf8');
  const active = config.split('\n').filter(line => line && !line.startsWith('#')).join('\n');
  const content = await readFile(new URL(`./src/content/docs/${slug}.md`, import.meta.url), 'utf8');
  assert(content.includes('```text\n' + active + '\n```'), `Stale shipped example: ${slug}`);
}

console.log('search-test: passed');
