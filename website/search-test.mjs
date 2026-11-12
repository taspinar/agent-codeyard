import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { plainText, topicsOf } from './integrations/search.mjs';
import { pageRank, passage, resultPassage, searchPages } from './src/lib/search.mjs';
import { feature, planning } from './src/lib/steps.ts';
import { topics } from './src/lib/docs.ts';
import { listed, moved, routes, stays } from './src/lib/redirects.ts';

assert.equal(plainText('<p>A &amp; B &#x3c; C</p><script>secret</script>'), 'A & B < C');
const example = [{ title: 'Risk policy', text: 'verification: groups', url: '/docs/risk/' }];
assert.equal(searchPages(example, 'RISK groups').length, 1);
assert.equal(searchPages(example, 'risk absent').length, 0);
assert.equal(searchPages(example, '  ').length, 0);
// Within a rank, a title that holds more of the words comes first (#373).
assert.deepEqual(searchPages([{ title: 'Quick Start', text: 'an existing repository', rank: 0 }, { title: 'Adopting an existing repository', text: '', rank: 0 }], 'existing repository').map(p => p.title), ['Adopting an existing repository', 'Quick Start']);
// Task topics first, then the other topics, then the Appendix, then the
// product pages, each in index order (#373).
const ranked = ['about/', 'docs/history/', 'docs/#updating', 'docs/#adopting', 'examples/', 'docs/#workflow-reference']
  .map(path => ({ title: path, text: 'existing repository', url: `/${path}`, rank: pageRank(path) }));
assert.deepEqual(searchPages(ranked, 'existing repository').map(p => p.title),
  ['docs/#adopting', 'docs/#workflow-reference', 'docs/#updating', 'docs/history/', 'about/', 'examples/']);
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
  // One entry per topic of Technical Documentation, and the one Appendix page (#373, #390).
  assert.deepEqual(docs.map(p => p.url), [...topics.map(t => `${base}docs/#${t.id}`), `${base}docs/history/`].sort((a, b) => docs.findIndex(p => p.url === a) - docs.findIndex(p => p.url === b)));
  assert.equal(docs.length, topics.length + 1);
  for (const topic of topics) assert.equal(docs.find(p => p.url === `${base}docs/#${topic.id}`)?.title, topic.title, `The search entry of ${topic.id}`);
  for (const [query, slug] of [['Troubleshooting', 'troubleshooting'], ['GitHub setup', 'github-setup']]) {
    const results = searchPages(docs, query);
    assert(results.some(p => p.url === `${base}docs/#${slug}`));
    assert(results.length < docs.length, `Navigation leaked into search: ${query}`);
    assert(!results.some(p => p.url === `${base}docs/#agent-roles`), `Navigation-only match: ${query}`);
  }
  // A visitor with an existing repository finds Adopting first, with a passage that shows the words (#321).
  const existing = searchPages(pages, 'existing repository');
  assert.equal(existing[0]?.url, `${base}docs/#adopting`, `First for "existing repository": ${existing[0]?.url}`);
  assert.equal(searchPages(pages, 'existing project')[0]?.url, `${base}docs/#adopting`, 'First for "existing project"');
  assert(resultPassage(existing[0], 'existing repository').some(part => part.match), 'No matched words in the passage of Adopting');
  for (const product of ['about/', 'examples/']) {
    const at = existing.findIndex(p => p.url === `${base}${product}`);
    for (const task of ['docs/#quick-start', 'docs/#troubleshooting']) {
      const before = existing.findIndex(p => p.url === `${base}${task}`);
      if (at >= 0 && before >= 0) assert(before < at, `${task} after ${product}`);
    }
  }
  // The questions of a new visitor lead to a task topic first (#334, #373).
  for (const query of ['existing project', 'cost', 'planning', 'resume', 'risk', 'run-feature.sh']) {
    const results = searchPages(pages, query);
    assert.equal(pageRank(results[0]?.url.slice(base.length) ?? ''), 0, `First for "${query}": ${results[0]?.url}`);
  }
  // The table of old addresses (src/lib/redirects.ts) has a row for every
  // route of the live site before #335: the 21 its Issue names and
  // Engineering records (#344), 22 in all. The sitemap and the search index
  // list the routes that stay but for the unlisted Projects (#390); a retired
  // route is a redirect page.
  const sitemap = await readFile(join(output, 'sitemap.xml'), 'utf8');
  const legacy = JSON.parse(await readFile(new URL('./legacy-anchors.json', import.meta.url), 'utf8')).pages;
  assert.equal(Object.keys(legacy).length, 22);
  assert.deepEqual(routes.map(r => r.path).sort(), Object.keys(legacy).sort(), 'The table of old addresses has other routes than the live site before #335');
  const located = [...sitemap.matchAll(/<loc>[^<]*?\/\/[^/<]+([^<]*)<\/loc>/g)].map(m => m[1].slice(base.length)).sort();
  assert.deepEqual(located, listed.map(r => r.path).sort(), 'The sitemap lists other routes than those that stay and are listed');
  assert.deepEqual([...new Set(pages.map(p => p.url.slice(base.length).replace(/#.*/, '')))].sort(), listed.map(r => r.path).sort(), 'The search index lists other routes than those that stay and are listed');
  for (const route of stays.filter(r => r.unlisted)) assert(/<main\b[^>]*\bdata-unlisted\b/.test(await readFile(join(output, route.path, 'index.html'), 'utf8')), `/${route.path} is not marked unlisted`);
  // The walk of the table: every old anchor, and the two restored as pointers
  // by #335, has a row whose target is in the build; the redirect page of a
  // retired route maps it there.
  const restored = [['', 'projects'], ['examples/', 'engineering']];
  const anchors = [...Object.entries(legacy).flatMap(([route, ids]) => ids.map(id => [route, id])), ...restored];
  for (const [path, id] of anchors) {
    const route = routes.find(r => r.path === path);
    const target = moved(route, id);
    const [to, fragment] = target.split('#');
    const landing = await readFile(join(output, to, 'index.html'), 'utf8');
    assert(fragment === undefined ? landing.includes('<main') : landing.includes(`id="${fragment}"`), `Old anchor lost: /${path}#${id} → /${target}`);
    const page = await readFile(join(output, path, 'index.html'), 'utf8');
    if (route.topic || route.to) {
      assert(page.includes('<meta name="robots" content="noindex">') && page.includes(`<meta http-equiv="refresh" content="0; url=${base}${moved(route)}">`), `Not a redirect page: /${path}`);
      assert(page.includes(`${JSON.stringify(id)}:${JSON.stringify(base + target)}`), `The redirect of /${path} does not map #${id} to /${target}`);
      assert(!/<main\b/.test(page), `A redirect page has a <main>: /${path}`);
    } else {
      assert(page.includes(`id="${id}"`), `Old anchor lost on its route: /${path}#${id}`);
    }
  }
  // No heading and no code block of the docs pages before #373 is lost
  // (docs-before.json): each is in its topic, the heading under its old id
  // with the prefix of the topic. Three sections of the old /docs/ were
  // removed by the plan as duplicates (website/design/INFORMATION-ARCHITECTURE.md, 2.7).
  const removed = { 'docs/': ['what-stays-with-you', 'find-a-command-or-setting', 'more-to-read'] };
  const before = JSON.parse(await readFile(new URL('./docs-before.json', import.meta.url), 'utf8')).pages;
  const one = await readFile(join(output, 'docs/index.html'), 'utf8');
  const article = one.match(/<article\b[^>]*\bdata-search\b[^>]*>([\s\S]*?)<\/article>/)[1];
  const topicHtml = Object.fromEntries(article.split(/(?=<section\b[^>]*\bdata-topic=)/).map(part => [part.match(/^<section\b[^>]*\bdata-topic="([^"]+)"/)?.[1], part]));
  assert.deepEqual(topicsOf(article).map(t => t.id), topics.map(t => t.id), 'The topics of /docs/ are those of src/lib/docs.ts, in order');
  for (const [path, { headings, code }] of Object.entries(before)) {
    const route = routes.find(r => r.path === path);
    for (const [id, text] of headings) {
      if (removed[path]?.includes(id)) continue;
      const fragment = moved(route, id).split('#')[1];
      const heading = one.match(new RegExp(`<h([2-6])\\b[^>]*\\bid="${fragment.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*>([\\s\\S]*?)</h\\1>`));
      assert.equal(heading && plainText(heading[2]), text, `Heading lost: /${path}#${id} (${text})`);
    }
    const blocks = [...(topicHtml[route.topic] ?? '').matchAll(/<pre\b[^>]*>([\s\S]*?)<\/pre>/g)].map(m => plainText(m[1]));
    for (const block of code) assert(blocks.includes(block), `Code block lost from /${path}: ${block.slice(0, 60)}`);
  }
  assert(searchPages(pages, 'LICENSE').some(p => p.url === `${base}docs/#quick-start`));
  // The owner's story opens History (#390), and the search finds it there.
  assert(searchPages(docs, 'Giving each agent a job').some(p => p.url === `${base}docs/history/`));
  assert.equal(docs.find(p => p.url === `${base}docs/history/`)?.title, 'How Agent Codeyard began');
  // The period list left History (the owner's correction of 12 November); "What comes next" names both planned items.
  assert(!searchPages(docs, 'Records instead of reports').some(p => p.url === `${base}docs/history/`), 'History still has the period list');
  assert(searchPages(docs, 'OpenCode Ollama supervisor').some(p => p.url === `${base}docs/history/`));
  // Engineering records was removed (#390): no page, no entry of the sitemap or the search.
  assert(!sitemap.includes('engineering-records') && !sitemap.includes(`${base}examples/`), 'The sitemap lists Engineering records or Projects');
  assert(!searchPages(pages, '41 recorded runs').length, 'The search still finds the engineering records');
  const projects = await readFile(join(output, 'examples/index.html'), 'utf8');
  assert(!/When the reviewer did not know|What 41 recorded runs|Engineering records/.test(projects), 'Projects still names the engineering records');
  assert(searchPages(pages, 'owner-directed').some(p => p.url === `${base}docs/#workflow-and-commands`));
  // Every step is in the workflow reference, and its old anchor on /workflow/ leads there (#377).
  const reference = topicHtml["workflow-reference"];
  const workflow = await readFile(join(output, 'workflow/index.html'), 'utf8');
  for (const { id } of [...planning, ...feature]) {
    assert(reference.includes(`<section class="ref-step" id="workflow-reference/${id}"`), `Not in the reference: ${id}`);
    assert(workflow.includes(`${JSON.stringify(id)}:${JSON.stringify(`${base}docs/#workflow-reference/${id}`)}`), `Old anchor lost: /workflow/#${id}`);
  }
  // The explorer of /workflow/ is the topic workflow-map, its ids with the prefix of the topic (#377).
  for (const id of ['explore', 'workflow', 'workflow-words', 'step-panel', 'routes-label']) assert(topicHtml['workflow-map'].includes(`id="workflow-map/${id}"`), `Not in the workflow map: ${id}`);
  // No page links a retired route of #377 or #390 any more, nor the unlisted
  // Projects, and Get Started leads to Quick Start.
  for (const page of [...new Set(pages.map(p => p.url.replace(/#.*/, '')))]) {
    const html = await readFile(join(output, page.slice(base.length), 'index.html'), 'utf8');
    for (const retiredPath of ['workflow/', 'faq/', 'docs/engineering-records/', 'examples/']) assert(!html.includes(`href="${base}${retiredPath}`), `${page} links /${retiredPath}`);
    for (const [, target] of html.matchAll(/<a\b[^>]*href="([^"]*)"[^>]*>\s*Get Started\s*<\/a>/gi)) assert.equal(target, `${base}docs/#quick-start`, `${page}: Get Started leads to ${target}`);
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
    'docs/#quick-start': ['function'],
    'docs/#new-to-agentic-coding': Object.keys(parts),
    'docs/#verification-and-review': ['function', 'check'],
  };
  const scenario = [];
  for (const page of pages) {
    const route = page.url.slice(base.length);
    // A topic of /docs/ by its own text; any other page as a whole.
    const text = (route.includes('#') ? page.text : plainText(await readFile(join(output, route, 'index.html'), 'utf8'))).replace(/[‘’]/g, "'").replace(/\s+/g, ' ');
    for (const [variant, canonical] of gym) assert(!variant.test(text), `${page.url}: the gym scenario differs from ${canonical}`);
    if (/\battendance\b/i.test(text)) scenario.push(route);
    for (const part of uses[route] ?? []) assert(parts[part].test(text), `${page.url}: the ${part} of the gym scenario is missing or reworded`);
  }
  assert.deepEqual(scenario.sort(), Object.keys(uses).sort(), 'Other pages use the gym scenario than search-test.mjs checks');
  for (const url of new Set(pages.map(page => page.url.replace(/#.*/, '')))) {
    assert(url.startsWith(base));
    const html = await readFile(join(output, url.slice(base.length), 'index.html'), 'utf8');
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length, `Duplicate anchors: ${url}`);
    if (url.startsWith(`${base}docs/`)) {
      assert(html.includes('aria-label="Documentation"'));
      assert(html.includes('aria-current="page"'));
      assert(html.includes('class="docs-pagination"'));
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
