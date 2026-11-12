// Check the actual static output, including 404, at both configured base paths.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join, extname } from 'node:path';
import { chromium } from 'playwright';
import AxeBuilder from '@axe-core/playwright';

const [output, base] = process.argv.slice(2);
assert(output && base, 'Usage: node browser-check.mjs <output> <base>');
const reportDir = resolve(process.env.DOCUMENTATION_REPORT_DIR || 'reports', base === '/' ? 'root' : 'project');
await mkdir(reportDir, { recursive: true });
async function pagesIn(dir, prefix = '') {
  const entries = await readdir(dir, { withFileTypes: true });
  return (await Promise.all(entries.map(e => e.isDirectory() ? pagesIn(join(dir, e.name), `${prefix}${e.name}/`) : e.name.endsWith('.html') ? [`${prefix}${e.name}`] : []))).flat().sort();
}
const files = await pagesIn(output);
// A retired route is a redirect page (src/lib/redirects.ts): the walk of the table below checks it.
const redirects = [];
for (const file of files) if ((await readFile(join(output, file), 'utf8')).includes('<meta http-equiv="refresh"')) redirects.push(file);
const pages = files.filter(file => !redirects.includes(file));
const types = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  try {
    const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    assert(path.startsWith(base));
    const file = resolve(output, path.slice(base.length) + (path.endsWith('/') ? 'index.html' : ''));
    assert(file.startsWith(resolve(output) + '/'));
    res.setHeader('Content-Type', types[extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404).end('Not found'); }
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
const report = { base, pages: [], accessibility: [], screenshots: [], keyboard: [] };
try {
  browser = await chromium.launch();
  const context = await browser.newContext({ reducedMotion: 'reduce' });
  const page = await context.newPage();
  // No JavaScript error on any page (#373).
  const errors = [];
  const watch = p => {
    p.on('pageerror', error => errors.push(`${p.url()}: ${error.message}`));
    p.on('console', message => { if (message.type() === 'error') errors.push(`${p.url()}: ${message.text()}`); });
  };
  watch(page);
  const external = new Set();
  await context.route('**/*', route => {
    if (new URL(route.request().url()).origin !== origin) { external.add(route.request().url()); return route.abort(); }
    return route.continue();
  });
  await page.addInitScript(() => {
    const theme = new URL(location.href).searchParams.get('theme');
    if (theme) localStorage.setItem('act-theme', theme);
  });
  // Tab through actual navigation, radio groups and buttons; no focus() or mouse.
  async function tabTo(selector) {
    for (let i = 0; i < 160; i++) {
      await page.keyboard.press('Tab');
      const matched = await page.evaluate(s => document.activeElement?.matches(s), selector);
      const focused = await page.evaluate(() => {
        const e = document.activeElement;
        if (!e || e === document.body) return true;
        // A station of the workflow map shows focus on its symbol: the stroke turns to the line, 6px wide.
        if (e.matches('g.station')) return [...e.querySelectorAll('.dot, .gate, .gate-o')].some(s => parseFloat(getComputedStyle(s).strokeWidth) >= 6);
        const visible = e.matches('input[type=radio]') ? e.nextElementSibling : e;
        const style = getComputedStyle(visible);
        return style.outlineStyle !== 'none' && parseFloat(style.outlineWidth) >= 2;
      });
      assert(focused, `Missing keyboard focus indicator while seeking ${selector}`);
      if (matched) return;
    }
    assert.fail(`Cannot reach ${selector} with Tab`);
  }
  // Technical Documentation, one interface (#373): Quick Start by default, the
  // navigation and search in view, every section by the navigation and by its
  // deep link, back and forward, the section picker by keyboard, search into
  // the right topic, and the walk of every redirect page with and without
  // JavaScript.
  async function docsInterface() {
    const { sections, topics } = await import('./src/lib/docs.ts');
    const { retired, moved } = await import('./src/lib/redirects.ts');
    const wide = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const p = await wide.newPage();
    watch(p);
    const open = () => p.evaluate(() => [...document.querySelectorAll('.docs-topics > [data-topic]')].filter(s => s.checkVisibility()).map(s => s.id));
    // A fresh load of an address, not a change of the hash of the open page.
    const visit = async url => { await p.goto('about:blank'); await p.goto(url); };
    const inView = (selector) => p.locator(selector).first().evaluate(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.top >= 0 && r.bottom <= innerHeight; });
    await p.goto(origin + base + 'docs/');
    assert.deepEqual(await open(), ['quick-start'], '/docs/ opens with Quick Start');
    for (const selector of ['.docs-search input', '.docs-sidebar nav a', '#quick-start h2']) assert(await inView(selector), `Not in view at 1280 px: ${selector}`);
    assert.equal(await p.locator('.docs-sidebar nav a[aria-current="page"]').innerText(), 'Quick Start');
    // Every section from the navigation, then every topic by its deep link.
    for (const section of sections) {
      await p.locator(`.docs-sections > li > a[href="#${section.id}"]`).click();
      await p.waitForURL(origin + base + 'docs/#' + section.id);
      // The router answers the hashchange event, which follows the new address.
      await p.waitForFunction(id => document.activeElement.closest('[data-topic]')?.id === id, section.id, { timeout: 2000 }).catch(() => {});
      assert.deepEqual(await open(), [section.id], `The navigation opens ${section.id}`);
      assert.equal(await p.evaluate(() => document.activeElement.closest('[data-topic]')?.id + ' ' + document.activeElement.tagName), `${section.id} H2`, `The focus moves to the heading of ${section.id}`);
      assert.match(await p.title(), new RegExp(`^${section.topics[0].title.replace(/[?]/g, '\\?')} · Technical Documentation`));
    }
    await p.goBack();
    await p.waitForFunction(id => document.querySelector(`[data-topic="${id}"]`).checkVisibility(), sections.at(-2).id, { timeout: 2000 }).catch(() => {});
    assert.deepEqual(await open(), [sections.at(-2).id], 'Back opens the section before');
    await p.goForward();
    await p.waitForFunction(id => document.querySelector(`[data-topic="${id}"]`).checkVisibility(), sections.at(-1).id, { timeout: 2000 }).catch(() => {});
    assert.deepEqual(await open(), [sections.at(-1).id], 'Forward opens the section after');
    for (const topic of topics) {
      await visit(origin + base + 'docs/#' + topic.id);
      assert.deepEqual(await open(), [topic.id], `The deep link opens ${topic.id}`);
      assert.equal(await p.locator('.docs-sidebar nav a[aria-current="page"]').getAttribute('href'), '#' + topic.id);
      assert.equal(await p.locator('[data-toc]:visible').getAttribute('data-toc'), topic.id, `"On this page" of ${topic.id}`);
    }
    await visit(origin + base + 'docs/#troubleshooting/a-check-fails');
    assert.deepEqual(await open(), ['troubleshooting']);
    assert(await inView('[id="troubleshooting/a-check-fails"]'), 'A heading deep link scrolls to its heading');
    await visit(origin + base + 'docs/#what-stays-with-you');
    assert.equal(new URL(p.url()).hash, '#configuration/the-limits-in-short', 'An old id of /docs/ goes on to its new place');
    assert(await inView('[id="configuration/the-limits-in-short"]'));
    // An old id of /docs/ that leads to the search input: on a fresh load and
    // followed on the open page, the input is in view and has the focus.
    const searchFocused = () => p.evaluate(() => document.activeElement?.id === 'docs-query');
    await visit(origin + base + 'docs/#find-a-command-or-setting');
    assert.equal(new URL(p.url()).hash, '#docs-query', 'The old search anchor of /docs/ goes on to the search input');
    assert(await inView('#docs-query') && await searchFocused(), 'The old search anchor of /docs/ lands on the search input');
    await visit(origin + base + 'docs/#troubleshooting/a-check-fails');
    await p.evaluate(() => { location.hash = 'find-a-command-or-setting'; });
    await p.waitForFunction(() => document.activeElement?.id === 'docs-query', null, { timeout: 2000 }).catch(() => {});
    assert(await inView('#docs-query') && await searchFocused(), 'The old search anchor followed on the open page lands on the search input');
    await visit(origin + base + 'docs/#no-such-topic');
    assert.deepEqual(await open(), ['quick-start'], 'An unknown hash opens Quick Start');
    // Search opens the right topic, also from /docs/ itself.
    for (const [query, topic] of [['existing project', 'adopting'], ['resume', 'troubleshooting'], ['run-feature.sh', 'quick-start'], ['cost', 'quick-start'], ['planning', 'quick-start'], ['risk', 'quick-start']]) {
      await p.locator('.docs-search input').fill(query);
      await p.locator('#search-results li a').first().waitFor();
      await p.locator('#search-results li a').first().click();
      await p.waitForURL(origin + base + 'docs/#' + topic);
      await p.waitForFunction(id => document.querySelector(`[data-topic="${id}"]`).checkVisibility(), topic, { timeout: 2000 }).catch(() => {});
      assert.deepEqual(await open(), [topic], `Search for "${query}" opens ${topic}`);
    }
    // The section picker at 390 px: on the first screen, operable by keyboard;
    // a choice closes it and moves the focus to the topic's heading.
    await p.setViewportSize({ width: 390, height: 844 });
    await p.goto(origin + base + 'docs/');
    assert(await inView('.docs-picker > summary'), 'The section picker is on the first screen at 390 px');
    assert.equal(await p.locator('.docs-picker > summary').innerText(), 'Section: Quick Start');
    await p.locator('.docs-picker > summary').focus();
    await p.keyboard.press('Enter');
    assert.notEqual(await p.locator('.docs-picker').getAttribute('open'), null);
    for (let i = 0; i < 20 && !await p.evaluate(() => document.activeElement.getAttribute('href') === '#troubleshooting'); i++) await p.keyboard.press('Tab');
    assert.equal(await p.evaluate(() => getComputedStyle(document.activeElement).outlineStyle !== 'none' && parseFloat(getComputedStyle(document.activeElement).outlineWidth) >= 2), true, 'Visible focus in the picker');
    await p.keyboard.press('Enter');
    await p.waitForURL(origin + base + 'docs/#troubleshooting');
    await p.waitForFunction(() => document.activeElement.matches('#troubleshooting > h2'), null, { timeout: 2000 }).catch(() => {});
    assert.equal(await p.locator('.docs-picker').getAttribute('open'), null, 'A choice closes the picker');
    assert.equal(await p.locator('.docs-picker > summary').innerText(), 'Section: Troubleshooting');
    assert.equal(await p.evaluate(() => document.activeElement.matches('#troubleshooting > h2')), true, 'The focus is on the heading of the chosen topic');
    assert.equal(await p.evaluate(() => getComputedStyle(document.activeElement).outlineStyle !== 'none'), true, 'The focused heading shows its focus');
    await wide.close();
    // Every retired route, with and without JavaScript: the default target,
    // and a sample of its anchors (the first and the last, and a layout id).
    for (const javaScriptEnabled of [true, false]) {
      const context = await browser.newContext({ javaScriptEnabled, viewport: { width: 1280, height: 800 } });
      const r = await context.newPage();
      watch(r);
      for (const route of retired) {
        const html = await readFile(join(output, route.path, 'index.html'), 'utf8');
        const ids = Object.keys(JSON.parse(html.match(/const map = (\{.*?\});/)[1]));
        // Every anchor of /workflow/ and /faq/, whose rows are written out (#377); a sample of a mechanical row.
        const samples = !javaScriptEnabled ? [undefined, ids.at(-1)] : route.to ? [undefined, ...ids, 'no-such-anchor'] : [undefined, 'main', ids[4], ids.at(-1), 'no-such-anchor'];
        for (const id of samples) {
          await r.goto(origin + base + route.path + (id ? '#' + id : ''));
          const expected = javaScriptEnabled && id && id !== 'no-such-anchor' ? moved(route, id) : moved(route);
          await r.waitForURL(origin + base + expected);
          const fragment = expected.split('#')[1];
          // An alias id is an empty element: its topic is what must be shown.
          // A target without a fragment is a page (/faq/#what to /features/).
          await r.waitForFunction(id => { const e = id ? document.getElementById(id) : document.querySelector('main'); return e && (e.closest('[data-topic]') ?? e).checkVisibility(); }, fragment ?? null, { timeout: 5000 });
          const topic = route.topic ?? (expected.startsWith('docs/#') ? expected.slice(6).split('/')[0] : undefined);
          if (javaScriptEnabled && topic) assert.deepEqual(await r.evaluate(() => [...document.querySelectorAll('.docs-topics > [data-topic]')].filter(s => s.checkVisibility()).map(s => s.id)), [topic], `/${route.path}#${id ?? ''} opens ${topic}`);
        }
      }
      await context.close();
    }
    // Without JavaScript every topic is on the page, in order, and a deep link is a real id.
    const plain = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1280, height: 800 } });
    const q = await plain.newPage();
    await q.goto(origin + base + 'docs/#risk-policy/shipped-configuration');
    assert.deepEqual(await q.evaluate(() => [...document.querySelectorAll('.docs-topics > [data-topic]')].filter(s => s.checkVisibility()).map(s => s.id)), topics.map(t => t.id), 'Without JavaScript every topic is shown');
    // The web fonts swap in after the first layout and move the target; the
    // browser keeps its fragment anchor and scrolls again in the next frame.
    // Measure once the fonts are in and the target has stayed put for three
    // samples (no requestAnimationFrame without JavaScript), within 5 s.
    const where = () => q.locator('[id="risk-policy/shipped-configuration"]').evaluate(e => ({ ready: document.readyState === 'complete' && document.fonts.status === 'loaded', top: e.getBoundingClientRect().top, header: document.querySelector('.top').getBoundingClientRect().bottom, height: innerHeight }));
    let target = await where();
    for (let stable = 0, start = Date.now(); stable < 3 && Date.now() - start < 5000;) {
      await new Promise(r => setTimeout(r, 50));
      const next = await where();
      stable = next.ready && next.top === target.top ? stable + 1 : 0;
      target = next;
    }
    assert(target.top >= target.header && target.top < target.height, `Without JavaScript a deep link scrolls natively, below the sticky header (${JSON.stringify(target)})`);
    await plain.close();
    console.log(`  Technical Documentation: ${sections.length} sections, ${topics.length} topics, ${retired.length} redirect pages walked with and without JavaScript.`);
  }
  const panelAccessible = async () => {
    const results = await new AxeBuilder({ page }).include('[id="workflow-map/step-panel"]').withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
    assert.deepEqual(results.violations.filter(v => ['serious', 'critical'].includes(v.impact) || v.id === 'color-contrast'), [], 'Accessibility of the step detail panel');
  };
  for (const theme of ['light', 'dark']) {
    for (const width of [375, 1440]) {
      await page.setViewportSize({ width, height: 900 });

      await page.goto(origin + base + '?theme=' + theme);
      await tabTo('.skip');
      await page.keyboard.press('Enter');
      assert.equal(await page.evaluate(() => document.activeElement.id), 'main');
      // The home page (#370, #390): the six sections in order; the hero's primary
      // action goes to the demo, the text link Get Started to Quick Start (#377), and the
      // headline, the lede and both actions are in view without scrolling.
      const hero = page.locator('.hero-grid');
      assert.deepEqual(await page.locator('main h1, main h2').allInnerTexts(), [
        'Build software with AI. Keep control of every change.', 'See how Agent Codeyard works', 'Why not just use Claude Code or Codex?',
        'From running features to overseeing them.', 'Built for developers who want more control over AI-generated software.', 'Give your coding agents a process.',
      ]);
      const primary = hero.locator('.actions a.btn');
      assert.equal(await primary.count(), 1);
      assert.equal(await primary.innerText(), 'Watch it work');
      assert.equal(await primary.getAttribute('href'), '#demo');
      assert.equal(await hero.locator('.actions a:not(.btn)').getAttribute('href'), base + 'docs/#quick-start');
      // The demo draws its route in two layouts and the screen shows one of them.
      assert.equal(await page.locator('main svg').evaluateAll(es => es.filter(e => e.checkVisibility()).length), 1, 'One process diagram on the home page: the demo');
      for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
        await page.setViewportSize(viewport);
        await page.evaluate(() => scrollTo(0, 0));
        for (const selector of ['h1', '.lede', '.actions a.btn', '.actions a:not(.btn)']) {
          const box = await hero.locator(selector).boundingBox();
          assert(box && box.y >= 0 && box.y + box.height <= viewport.height, `Hero ${selector} below the fold at ${viewport.width}×${viewport.height}`);
        }
      }
      await page.setViewportSize({ width, height: 900 });
      // The header (#377, #390): the four destinations and GitHub, in order, then the theme toggle.
      assert.deepEqual(await page.locator('.top .nav a').allInnerTexts(), ['Home', 'Features', 'About', 'Docs', 'GitHub']);
      await page.goto(origin + base + '?theme=' + theme);
      await tabTo('.nav a[href="' + base + 'docs/"]');
      await page.keyboard.press('Enter');
      await page.waitForURL(origin + base + 'docs/');
      await tabTo('.theme');
      await page.keyboard.press('Enter');
      assert.equal(await page.locator('html').getAttribute('data-theme'), theme === 'light' ? 'dark' : 'light');
      await page.keyboard.press('Enter');
      // The workflow map, a topic of the docs (#377): the complete drawing;
      // nothing walks until the reader asks.
      await page.goto(origin + base + 'docs/?theme=' + theme + '#workflow-map');
      assert(await page.locator('[id="workflow-map/workflow"]').isVisible());
      assert.match(await page.locator('[data-summary]').innerText(), /^Medium risk\s*·\s*standard profile\s*·\s*step by step$/);
      assert(!await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      assert(await page.locator('.workflow form').isVisible(), 'The switches are shown with the map');
      assert.equal(await page.locator('.workflow .map').getAttribute('viewBox'), '-30 0 1260 482');
      assert.equal(await page.locator('[data-route="example"], .guide-static, .tour-note').count(), 0, 'The case of #241 is not part of the map');
      await tabTo('[data-action="start"]');
      await page.keyboard.press('Enter');
      assert(await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      assert.match(await page.locator('[data-caption="lead"]').innerText(), /^Step 1 of \d+\.$/);
      assert.equal(await page.locator('[data-caption="who"]').innerText(), 'You:');
      // A step text is at most three sentences; the reference entry of the step tells the rest.
      assert.equal(await page.locator('[data-caption="ref"] a').innerText(), 'Describe the idea');
      assert.match(await page.locator('[data-caption="ref"] a').getAttribute('href'), /^#workflow-reference\/describe-the-idea$/);
      const html = await page.content();
      assert(!html.includes('Nothing in the reference') && !html.includes('Moved to the documentation'));
      assert.equal(await page.locator('[data-key="n-bypass"]').textContent(), 'low risk: no review if the project allows it; then you approve the merge');
      assert.equal(await page.locator('.map [data-label="f-findings.sub"]').textContent(), 'you approve each decision');
      await tabTo('[data-route="repair"]');
      await page.keyboard.press('Enter');
      assert.equal(await page.locator('[data-route="repair"]').getAttribute('aria-pressed'), 'true');
      assert.match(await page.locator('[data-summary]').innerText(), /checks fail/);
      assert.match(await page.locator('[data-caption="lead"]').innerText(), /^Step 1 of/);
      await tabTo('[data-action="next"]');
      await page.keyboard.press('Enter');
      assert.match(await page.locator('[data-caption="who"]').innerText(), /implementer/);
      await tabTo('[data-action="reset"]');
      await page.keyboard.press('Enter');
      assert.equal(await page.locator('[data-route="repair"]').getAttribute('aria-pressed'), 'false');
      for (const name of ['risk', 'profile', 'run', 'part', 'situation']) {
        const radios = page.locator(`input[name="${name}"]`);
        assert(await radios.count() > 1);
        await tabTo(`input[name="${name}"]`);
        const before = await page.locator(`input[name="${name}"]:checked`).inputValue();
        await page.keyboard.press('ArrowRight');
        assert.notEqual(await page.locator(`input[name="${name}"]:checked`).inputValue(), before);
      }
      assert.match(await page.locator('[data-summary]').innerText(), /High risk.*light profile.*unattended.*planning only.*unclear Issue/s);
      // The step detail panel from a station of the map: Enter opens it with
      // the focus on its heading, the arrow keys move between its tabs, Close
      // returns the focus to the station.
      if (width === 1440) {
        await tabTo('svg g.station[data-key="f-review"]');
        await page.keyboard.press('Enter');
        assert(await page.locator('.step-panel').isVisible());
        assert.equal(await page.evaluate(() => document.activeElement.id), 'workflow-map/step-panel-h');
        assert.equal(await page.locator('.step-panel h3').innerText(), 'Review the code');
        assert(await page.locator('svg g[data-key="f-review"]').evaluate(e => e.classList.contains('is-selected')));
        await tabTo('.step-panel [role="tab"][aria-selected="true"]');
        await page.keyboard.press('ArrowRight');
        assert.equal(await page.evaluate(() => document.activeElement.dataset.tab), 'technical');
        assert.match(await page.locator('.step-panel [role="tabpanel"]').innerText(), /Command\s+\.\/scripts\/review-feature\.sh/);
        await page.keyboard.press('ArrowRight');
        assert.match(await page.locator('.step-panel [role="tabpanel"]').innerText(), /Stops, retries and exceptions/);
        await panelAccessible();
        await page.keyboard.press('Shift+Tab');
        await page.keyboard.press('Enter');
        assert(!await page.locator('.step-panel').isVisible());
        assert.equal(await page.evaluate(() => document.activeElement.dataset.key), 'f-review');
      }
      await page.locator('[data-action="reset"]').press('Enter');
      assert.equal(await page.locator('input[name="part"]:checked').inputValue(), 'all');
      assert.match(await page.locator('[data-summary]').innerText(), /^Medium risk.*standard profile.*step by step$/s);
      // The review bypass as rendered. Policy excludes it at medium and high
      // risk and under the standard profile, so there it is off the route: the
      // off colour, solid, never the dashed style of a route that can happen.
      // Only low risk with the light profile draws it at full strength (at
      // 1440 px: at 375 px the list is the map).
      if (width === 1440) {
        const bypass = () => page.evaluate(() => ['b-bypass', 'n-bypass'].map(key => {
          const e = document.querySelector(`svg.map [data-key="${key}"]`);
          const s = getComputedStyle(e);
          return { key, display: s.display, width: e.getBBox().width, off: e.classList.contains('is-off'), taken: e.classList.contains('is-taken'), dash: s.strokeDasharray, stroke: s.stroke, fill: s.fill };
        }));
        const color = name => page.evaluate(name => { const p = document.createElement('p'); p.style.color = `var(${name})`; document.body.append(p); const c = getComputedStyle(p).color; p.remove(); return c; }, name);
        const ink = await color('--ink'), off = await color('--off');
        const choose = async (name, value) => page.locator(`label:has(input[name="${name}"][value="${value}"])`).click();
        for (const risk of ['low', 'medium', 'high']) {
          for (const profile of ['standard', 'light']) {
            await choose('risk', risk);
            await choose('profile', profile);
            const [branch, note] = await bypass();
            const at = `at ${risk} risk, ${profile} profile`;
            if (risk === 'low' && profile === 'light') {
              for (const r of [branch, note]) assert(r.display !== 'none' && r.width > 0 && r.taken && !r.off, `${r.key} taken ${at}`);
              assert.equal(branch.dash, 'none', `b-bypass solid ${at}`);
              assert.notEqual(branch.stroke, off, `b-bypass at full strength ${at}`);
              assert.equal(note.fill, ink, `n-bypass in ink ${at}`);
            } else {
              for (const r of [branch, note]) assert(r.off && !r.taken, `${r.key} off ${at}`);
              assert.equal(branch.dash, 'none', `b-bypass not dashed ${at}`);
              assert.equal(branch.stroke, off, `b-bypass in the off colour ${at}`);
              assert.notEqual(note.fill, ink, `n-bypass not in ink ${at}`);
            }
          }
        }
        await page.locator('[data-action="reset"]').click();
      }
      await tabTo('[data-action="start"]');
      await page.keyboard.press('Enter');
      assert(await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      await tabTo('[data-action="next"]');
      await page.keyboard.press('Enter');
      assert.match(await page.locator('[data-caption="lead"]').innerText(), /Step 2/);
      await tabTo('[data-action="finish"]');
      await page.keyboard.press('Enter');
      assert(!await page.locator('[data-workflow]').evaluate(e => e.classList.contains('walking')));
      if (width === 1440) {
        await tabTo('[data-action="list"]');
        await page.keyboard.press('Enter');
        assert.equal(await page.locator('[data-action="list"]').getAttribute('aria-expanded'), 'true');
      }
      // The same panel from the words list, inside the item that opened it.
      await tabTo('.words li[data-key="f-checks"] .detail-btn');
      await page.keyboard.press('Enter');
      assert(await page.locator('.words li[data-key="f-checks"] .step-panel').isVisible());
      assert.equal(await page.evaluate(() => document.activeElement.id), 'workflow-map/step-panel-h');
      await panelAccessible();
      await tabTo('.panel-close');
      await page.keyboard.press('Enter');
      assert(!await page.locator('.step-panel').isVisible());
      assert(await page.evaluate(() => document.activeElement.matches('.words li[data-key="f-checks"] .detail-btn')));
      await page.goto(origin + base + 'docs/?theme=' + theme);
      await tabTo('.docs-search input');
      if (width <= 760) {
        await tabTo('.docs-sidebar summary');
        await page.keyboard.press('Enter');
        assert.notEqual(await page.locator('.docs-sidebar details').getAttribute('open'), null);
      }
      await tabTo('.docs-sidebar nav a');
      if (width <= 760) {
        await tabTo('.docs-toc summary');
        await page.keyboard.press('Enter');
        assert.notEqual(await page.locator('.docs-toc').getAttribute('open'), null);
      }
      await tabTo('.docs-toc a');
      await tabTo('.docs-pagination a');

      await page.goto(origin + base + 'examples/?theme=' + theme);
      // The Projects page (#375): two or three cases of 100 to 200 visible
      // words, each with exactly one of the three labels and one real image;
      // the long evidence behind closed disclosures.
      if (width === 1440) {
        const projects = await page.evaluate(() => ({
          open: document.querySelectorAll('details[open]').length,
          missing: ['products', 'application', 'fightanalytics', 'figures', 'absent', 'sources', 'engineering', 'memory', 'story', 'tradeoff', 'features', 'owner', 'repair', 'short', 'analysis', 'levels'].filter(id => !document.getElementById(id)),
          first: document.querySelector('main section[id]').id,
          cases: [...document.querySelectorAll('main section[id]:has(.case-label)')].map(section => ({
            id: section.id,
            words: section.innerText.split(/\s+/).filter(Boolean).length,
            labels: [...section.querySelectorAll('.case-label')].map(label => label.innerText.trim()),
            images: [...section.querySelectorAll('img')].filter(img => !img.closest('details')).map(img => ({ alt: img.alt.length, caption: !!img.closest('figure')?.querySelector('figcaption a') })),
          })),
          unnamed: ['Leyra', 'TrafficInsights', 'ChatDocs'].filter(name => document.body.innerText.includes(name)),
        }));
        assert.equal(projects.open, 0, 'Every disclosure of the Projects page starts closed');
        assert.deepEqual(projects.missing, [], 'Every anchor of the Projects page resolves');
        assert.equal(projects.first, 'products', 'The Projects page opens with the cases');
        assert(projects.cases.length >= 2 && projects.cases.length <= 3, `The Projects page shows ${projects.cases.length} cases`);
        for (const project of projects.cases) {
          assert(project.words >= 100 && project.words <= 200, `The case ${project.id} shows ${project.words} words`);
          assert.equal(project.labels.length, 1, `The case ${project.id} carries ${project.labels.length} labels`);
          assert(['Real verifiable run', 'Simulation', 'Private pilot or future work'].includes(project.labels[0]), `The case ${project.id} is labelled "${project.labels[0]}"`);
          assert.equal(project.images.length, 1, `The case ${project.id} shows ${project.images.length} images`);
          assert(project.images[0].alt > 0 && project.images[0].caption, `The image of the case ${project.id} lacks alt text or a linked source`);
        }
        assert.equal(projects.cases.find(project => project.id === 'fightanalytics')?.labels[0], 'Private pilot or future work', 'FightAnalytics is presented as evidence');
        assert.deepEqual(projects.unnamed, [], 'The Projects page names no other product');
        // An old anchor of a part that moved into the evidence opens it.
        await page.goto(origin + base + 'examples/?theme=' + theme + '#sources');
        assert(await page.locator('#evidence').evaluate(e => e.open), 'The old anchor /examples/#sources leaves the evidence closed');
        assert(await page.locator('#sources-h').isVisible(), 'The old anchor /examples/#sources shows no heading');
        // The old anchor of a removed engineering case (#390) lands on the cases.
        await page.goto(origin + base + 'examples/?theme=' + theme + '#memory');
        assert.equal(await page.locator('#memory').evaluate(e => e.closest('section')?.id), 'products', 'The old anchor /examples/#memory does not land on the cases');
        assert(await page.locator('#products-h').evaluate(e => { const r = e.getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight; }), 'The cases are not in view at /examples/#memory');
        await page.goto(origin + base + 'examples/?theme=' + theme);
      }
      await tabTo('.contents a');
      // Reaching the final footer link walks every intervening content link too.
      await tabTo('footer nav a:last-child');
      report.keyboard.push({ theme, width, pages: ['home', 'docs', 'workflow map', 'examples'], passed: true });
    }
  }
  // The workflow demo of the home page (#370), at 1280 × 800, 390 × 844 and
  // 320 × 640 in both themes: nothing plays on load; every moment shows a
  // caption, the terminals and the tree, and the way back of its lane when it
  // takes one; the merges come one at a time; on a phone the route is drawn
  // top to bottom, whole within the viewport, with the same state as the
  // horizontal map of the desktop; the controls and the dialogs work by
  // keyboard, the dialogs take the focus and give it back; no error.
  for (const theme of ['light', 'dark']) {
    for (const [width, height] of [[1280, 800], [390, 844], [320, 640]]) {
      const demoContext = await browser.newContext({ viewport: { width, height }, reducedMotion: 'reduce' });
      await demoContext.addInitScript(t => localStorage.setItem('act-theme', t), theme);
      const p = await demoContext.newPage();
      const errors = [];
      p.on('pageerror', e => errors.push(e.message));
      const at = `(demo ${theme} ${width})`;
      await p.goto(origin + base);
      const count = () => p.locator('[data-count]').innerText();
      const press = async (selector) => { await p.locator(selector).locator('visible=true').first().focus(); await p.keyboard.press('Enter'); };
      const orientation = width >= 1280 ? 'horizontal' : 'vertical';
      assert.deepEqual(await p.locator('.demo-map').evaluateAll(es => es.filter(e => e.checkVisibility()).map(e => e.dataset.map)), [orientation], `The route ${orientation} ${at}`);
      await p.waitForTimeout(3000);
      assert.equal(await count(), 'Moment 1 of 19', `Nothing plays on load ${at}`);
      assert.equal(await p.locator('.demo-map .track').first().evaluate(e => getComputedStyle(e).transitionDuration), '0s', `No transition under reduced motion ${at}`);
      if (width === 1280) {
        await p.locator('.hero .btn').click();
        await p.waitForTimeout(500);
        const box = await p.evaluate(() => ({ top: document.querySelector('.demo').getBoundingClientRect().top, bottom: document.querySelector('.demo-panels').getBoundingClientRect().bottom }));
        assert(box.top >= 0 && box.bottom <= height, `After "Watch it work" the route, the terminals and the tree are in view ${at}: ${JSON.stringify(box)}`);
      }
      const merged = [];
      for (let m = 0; m < 19; m++) {
        if (m > 0) await press('[data-action="next"]');
        assert.equal(await count(), `Moment ${m + 1} of 19`, at);
        const state = await p.evaluate(() => {
          const [map, other] = [...document.querySelectorAll('.demo-map')].sort((a, b) => b.checkVisibility() - a.checkVisibility());
          // What each layout marks: the classes and the words of every station, lane and loop.
          const marks = svg => [...svg.querySelectorAll('[data-milestone], [data-lane], [data-stage], [data-track], [data-loop], [data-main]')].map(e => `${e.getAttribute('class')}|${e.querySelector?.('[data-status]')?.textContent ?? ''}`);
          const frame = map.getBoundingClientRect();
          const parts = [...map.querySelectorAll('text, .sym, .demo-loop path')].filter(e => e.checkVisibility()).map(e => e.getBoundingClientRect()).filter(r => r.width);
          return {
            caption: document.querySelector('[data-title]').textContent.trim() && document.querySelector('[data-text]').textContent.trim(),
            terminals: [...document.querySelectorAll('[data-term]')].filter(e => e.checkVisibility()).map(e => e.innerText.trim().length),
            tree: document.querySelector('[data-tree]').innerText.trim().length,
            loops: [...map.querySelectorAll('[data-loop]')].filter(e => getComputedStyle(e).display !== 'none' && e.getBBox().width > 0).map(e => e.dataset.loop),
            merged: [...map.querySelectorAll('[data-track$="-main"].is-done')].map(e => e.dataset.track),
            statuses: [...map.querySelectorAll('[data-status]')].map(e => e.textContent.trim()),
            same: JSON.stringify(marks(map)) === JSON.stringify(marks(other)),
            outside: parts.filter(r => r.left < Math.max(0, frame.left) - 0.5 || r.right > Math.min(innerWidth, frame.right) + 0.5).length,
            mapScrolls: map.parentElement.scrollWidth > map.parentElement.clientWidth,
            overflow: document.documentElement.scrollWidth > innerWidth,
          };
        });
        assert(state.caption && state.tree > 0 && state.terminals.length > 0 && state.terminals.every(n => n > 0), `Empty panel at moment ${m + 1} ${at}`);
        assert(state.same, `Both layouts of the route show the state of moment ${m + 1} ${at}`);
        assert(state.statuses.length === 3 && state.statuses.every(Boolean), `Each lane's state in words at moment ${m + 1} ${at}`);
        assert(state.outside === 0 && !state.mapScrolls, `The whole route within the viewport at moment ${m + 1} ${at}`);
        assert.deepEqual(state.loops, m === 11 || m === 12 ? ['repair'] : m === 13 || m === 14 ? ['findings'] : [], `Way back at moment ${m + 1} ${at}`);
        assert(!state.overflow, `Horizontal overflow at moment ${m + 1} ${at}`);
        merged.push(state.merged.length);
      }
      assert.deepEqual(merged, [...Array(16).fill(0), 1, 2, 3], `The merges one at a time ${at}`);
      // Play and pause, then restart.
      await press('[data-action="restart"]');
      await press('[data-action="play"]');
      assert.equal(await p.locator('[data-action="play"]').innerText(), 'Pause');
      await p.waitForTimeout(2900);
      const playing = await count();
      assert.notEqual(playing, 'Moment 1 of 19', `Play advances ${at}`);
      await p.keyboard.press('Enter');
      await p.waitForTimeout(2900);
      assert.equal(await count(), playing, `Pause holds ${at}`);
      await press('[data-action="restart"]');
      assert.equal(await count(), 'Moment 1 of 19');
      // The timeline, by keyboard.
      await p.locator('[data-action="timeline"]').focus();
      await p.keyboard.press('ArrowRight');
      assert.equal(await count(), 'Moment 2 of 19', `The timeline moves ${at}`);
      // The Plan dialog from its station: focus in, Escape out, focus back.
      // A dialog opens and the focus moves a task after the key press: wait
      // for the state that is expected, then assert it (no fixed delay).
      const dialog = p.locator('[data-dialog]');
      const opened = async (title, message) => {
        await p.waitForFunction(t => { const d = document.querySelector('[data-dialog]'); return d.open && d.querySelector('[data-dialog-title]').textContent === t; }, title, { timeout: 5000 }).catch(() => {});
        assert.equal(await p.locator('[data-dialog-title]').innerText(), title, message);
        assert(await dialog.isVisible(), message);
      };
      const focused = async (selector, message) => {
        await p.waitForFunction(s => document.activeElement?.matches(s), selector, { timeout: 5000 }).catch(() => {});
        assert(await p.evaluate(s => document.activeElement?.matches(s), selector), message);
      };
      await press('[data-milestone="plan"]');
      await opened('Inside Plan', `The Plan dialog ${at}`);
      assert(await dialog.evaluate(d => d.contains(document.activeElement)), `The Plan dialog takes the focus ${at}`);
      await p.keyboard.press('Escape');
      assert(!await dialog.isVisible());
      await focused('[data-milestone="plan"]', `Focus returns to Plan ${at}`);
      // The feature dialog jumps to a moment.
      await p.locator('[data-action="timeline"]').fill('12');
      await press('[data-action="details"]');
      await opened('Inside a feature', `The feature dialog ${at}`);
      await press('[data-goto="13"]');
      assert(!await dialog.isVisible());
      assert.equal(await count(), 'Moment 14 of 19');
      await focused('[data-action="details"]', `Focus returns to the feature steps ${at}`);
      // Switching the active feature terminal by keyboard: the chosen tab keeps
      // the focus through the redraw, Tab reaches the next tab right away, and
      // a change of moment while a tab has the focus does not drop it.
      await press('[data-select="f03"]');
      assert.equal(await p.locator('[data-select="f03"]').getAttribute('aria-pressed'), 'true', `Terminal switch to f03 ${at}`);
      await focused('[data-select="f03"]', `The chosen terminal tab keeps the focus ${at}`);
      await p.keyboard.press('Tab');
      await focused('[data-select="f04"]', `Tab reaches the next terminal tab ${at}`);
      await p.keyboard.press(' ');
      assert.equal(await p.locator('[data-select="f04"]').getAttribute('aria-pressed'), 'true', `Terminal switch ${at}`);
      await focused('[data-select="f04"]', `The next terminal tab keeps the focus ${at}`);
      await p.evaluate(() => document.querySelector('[data-action="next"]').click());
      assert.equal(await count(), 'Moment 15 of 19');
      await focused('[data-select="f04"]', `A change of moment keeps the focus on the terminal tab ${at}`);
      assert.equal(await p.locator('[data-term].is-active').getAttribute('data-term'), 'f04');
      if (width < 760) assert.equal(await p.locator('[data-term]').evaluateAll(es => es.filter(e => e.checkVisibility()).length), 1, `One terminal at a time on a phone ${at}`);
      else assert.equal(await p.locator('[data-term]').evaluateAll(es => es.filter(e => e.checkVisibility()).length), 3, `Three terminals side by side ${at}`);
      // A file, and the planning log.
      const file = p.locator('[data-file]').first();
      const path = (await file.innerText()).trim();
      await press('[data-file]');
      await opened(path, `The file dialog ${at}`);
      assert((await p.locator('.demo-file').innerText()).trim().length > 0);
      const results = await new AxeBuilder({ page: p }).include('.demo').withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
      assert.deepEqual(results.violations.filter(v => ['serious', 'critical'].includes(v.impact) || v.id === 'color-contrast'), [], `Accessibility of the demo with a dialog open ${at}`);
      await p.keyboard.press('Escape');
      await focused('[data-file]', `Focus returns to the file ${at}`);
      await press('[data-action="log"]');
      await opened('Planning terminal', `The planning log ${at}`);
      await p.keyboard.press('Escape');
      // Every old anchor of the home page lands in the section that took its content.
      for (const [id, section] of [['example', 'demo'], ['roles', 'demo'], ['projects', 'oversee'], ['evidence', 'oversee'], ['why', 'why'], ['who', 'who'], ['start', 'start']]) {
        assert.equal(await p.evaluate(id => document.getElementById(id)?.closest('section')?.id, id), section, `#${id} ${at}`);
      }
      assert.deepEqual(errors, [], `JavaScript errors ${at}`);
      await demoContext.close();
    }
  }
  // Disclosure breakpoint and no-JS fallback, including search-before-navigation.
  for (const javaScriptEnabled of [true, false]) {
    const docs = await browser.newContext({ javaScriptEnabled, viewport: { width: 760, height: 900 } });
    const p = await docs.newPage();
    await p.goto(origin + base + 'docs/');
    const disclosure = p.locator('.docs-sidebar details');
    assert.equal(await disclosure.getAttribute('open'), null);
    assert.equal(await p.locator('.docs-toc').getAttribute('open'), null);
    await p.locator('.docs-sidebar summary').press('Enter');
    assert.notEqual(await disclosure.getAttribute('open'), null);
    await p.locator('.docs-sidebar summary').press('Enter');
    assert((await p.locator('article').boundingBox()).y < 900, 'Docs article starts below the first screen');
    if (javaScriptEnabled) {
      const search = await p.locator('.docs-search').boundingBox();
      const nav = await disclosure.boundingBox();
      assert(search.y + search.height <= nav.y, 'Search must precede the disclosure');
    }
    await p.setViewportSize({ width: 768, height: 900 });
    if (javaScriptEnabled) {
      assert(await p.locator('.docs-sidebar nav').isVisible());
    } else {
      // Summaries must remain reachable even when ::details-content is unsupported.
      for (const selector of ['.docs-sidebar', '.docs-toc']) {
        const summary = p.locator(`${selector} summary`);
        assert(await summary.isVisible(), `No-JS desktop summary hidden: ${selector}`);
        const nav = p.locator(`${selector} nav`);
        assert(!await nav.isVisible(), `No-JS closed desktop content visible: ${selector}`);
        await summary.press('Enter');
        assert(await nav.isVisible(), `No-JS desktop content did not open: ${selector}`);
        await summary.press('Enter');
        assert(!await nav.isVisible(), `No-JS desktop content did not close: ${selector}`);
      }
      await p.goto(origin + base + 'docs/#workflow-map');
      assert(await p.locator('[id="workflow-map/workflow-words"]').isVisible(), 'Without JavaScript the workflow map is its words list');
      assert.match(await p.locator('[data-summary]').innerText(), /^Medium risk\s*·\s*standard profile\s*·\s*step by step$/, 'Without JavaScript the summary is that of the complete drawing');
      assert(await p.locator('[data-key="w-planning"]').isVisible() && await p.locator('[data-key="w-feature"]').isVisible(), 'Without JavaScript the words list is the complete workflow');
      assert(!await p.locator('.workflow .routes').isVisible() && !await p.locator('.workflow .advanced').isVisible());
      for (const actions of await p.locator('.workflow .map-actions').all()) assert(!await actions.isVisible());
      assert(!await p.locator('.workflow .hint').isVisible() && !await p.locator('.workflow .reset').isVisible());
      assert.equal(await p.locator('.station, .detail-btn').count(), 0, 'Without JavaScript nothing pretends to open the step detail');
    }
    await docs.close();
  }
  // The workflow map and the workflow reference: an old anchor of /workflow/ goes on to its place,
  // "On this page" stays beside the text on a wide screen, and a code block copies.
  {
    const wide = await browser.newContext({ viewport: { width: 1440, height: 900 }, permissions: ['clipboard-read', 'clipboard-write'] });
    const p = await wide.newPage();
    await p.goto(origin + base + 'workflow/#workflow-words');
    await p.waitForURL(origin + base + 'docs/#workflow-map/workflow-words');
    assert(await p.locator('[id="workflow-map/workflow-words"]').isVisible(), 'An old anchor of the technical workflow opens the workflow map');
    await p.locator('[data-action="start"]').click();
    await p.waitForTimeout(3000);
    assert.match(await p.locator('[data-caption="lead"]').innerText(), /^Step 1 of/, 'Without reduced motion, too, nothing advances by itself');
    await p.goto(origin + base + 'workflow/#review-the-code');
    await p.waitForURL(origin + base + 'docs/#workflow-reference/review-the-code');
    assert(await p.locator('[id="workflow-reference/review-the-code"]').isVisible());
    await p.mouse.wheel(0, 1000);
    const toc = await p.locator('.docs-toc').boundingBox();
    const text = await p.locator('.docs-body').boundingBox();
    assert(toc.x >= text.x + text.width && toc.y >= 0 && toc.y < 900, 'On this page is not beside the text');
    await p.goto(origin + base + 'docs/getting-started/');
    await p.waitForURL(origin + base + 'docs/#quick-start');
    await p.locator('.code-block .copy').first().click();
    assert.equal(await p.evaluate(() => navigator.clipboard.readText()), await p.locator('.code-block pre').first().evaluate(e => e.innerText.replace(/\n$/, '')));
    await wide.close();
  }
  await docsInterface();
  for (const file of pages) {
    const path = base + file.replace(/index\.html$/, '');
    const slug = file.replace(/\/index\.html$/, '').replace(/\.html$/, '').replaceAll('/', '-');
    for (const theme of ['light', 'dark']) {
      await page.emulateMedia({ colorScheme: theme });

      // Technical Documentation at the widths of #373; Features (#374) and About (#376) also
      // at the narrowest phone width and at 1280 px; the other pages at three.
      // Every page at the widths of #377, the docs at those of #373; the
      // other pages also at 375 px, the width of the keyboard checks.
      for (const width of path.startsWith(base + 'docs/') ? [320, 390, 768, 1280, 1440] : [320, 375, 390, 768, 1280, 1440]) {
        await page.setViewportSize({ width, height: 900 });
        await page.goto(origin + path + '?theme=' + theme);
        await page.evaluate(() => document.fonts.ready);
        assert.equal(await page.locator('html').getAttribute('data-theme'), theme);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `Horizontal overflow: ${path} ${width}`);
        // Every header link and the theme toggle in view, without scrolling the header.
        assert.deepEqual(await page.evaluate(() => {
          const nav = document.querySelector('.top .nav');
          const hidden = [...nav.querySelectorAll('a, .theme')].filter(e => {
            const box = e.getBoundingClientRect();
            return box.left < 0 || box.right > innerWidth;
          }).map(e => e.textContent.trim());
          return nav.scrollWidth > nav.clientWidth ? ['the header scrolls', ...hidden] : hidden;
        }), [], `Header cut off: ${path} ${width}`);
        // The same header and footer on every page (#377); no Get Started in it (#390).
        assert.deepEqual(await page.locator('.top .nav a').allInnerTexts(), ['Home', 'Features', 'About', 'Docs', 'GitHub'], `Header: ${path}`);
        assert.equal(await page.locator('.top .nav .btn').count(), 0, `Header: ${path} has a button link`);
        assert(await page.locator('.top .theme').isVisible(), `Theme toggle: ${path}`);
        assert.deepEqual(await page.locator('footer nav a').allInnerTexts(), ['Open source · MIT', 'GitHub / Source', 'Contributing', 'Security policy', 'Technical Documentation'], `Footer: ${path}`);
        const results = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']).analyze();
        const violations = results.violations.filter(v => ['serious', 'critical'].includes(v.impact) || v.id === 'color-contrast');
        report.accessibility.push({ path, theme, width, violations, incomplete: results.incomplete.map(v => ({ id: v.id, targets: v.nodes.map(n => n.target) })) });
        assert.deepEqual(violations, [], `Accessibility: ${path} ${theme} ${width}`);
        if (width === 1440) {
          const lowContrast = await page.locator('svg text').evaluateAll(elements => {
            const luminance = color => {
              const rgb = color.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => v / 255).map(v => v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
              return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
            };
            const ground = luminance(getComputedStyle(document.body).backgroundColor);
            return elements.filter(e => e.getBoundingClientRect().width && e.checkVisibility()).flatMap(e => {
              const ink = luminance(getComputedStyle(e).fill);
              const ratio = (Math.max(ink, ground) + .05) / (Math.min(ink, ground) + .05);
              return ratio < 4.5 ? [{ text: e.textContent, ratio }] : [];
            });
          });
          assert.deepEqual(lowContrast, [], `SVG text contrast: ${path} ${theme}`);
        }
        const screenshot = `${slug}-${theme}-${width}.png`;
        await page.screenshot({ path: join(reportDir, screenshot), fullPage: true });
        report.screenshots.push(screenshot);
        if (theme === 'light' && width === 1440) {
          const resources = await page.evaluate(() => performance.getEntriesByType('resource').map(r => ({ url: r.name, bytes: r.decodedBodySize, kind: r.initiatorType })));
          const html = await readFile(join(output, file), 'utf8');
          const inlineJS = [...html.matchAll(/<script\b(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].reduce((sum, m) => sum + Buffer.byteLength(m[1]), 0);
          report.pages.push({ path, javascriptBytes: inlineJS + resources.filter(r => r.kind === 'script').reduce((s, r) => s + r.bytes, 0), pageBytes: Buffer.byteLength(html) + resources.reduce((s, r) => s + r.bytes, 0), resources });
        }
        // Features (#374): with the questions closed, at most 900 visible words
        // in <main> and at most 6000 px high at 1440 px.
        if (path === base + 'features/' && width === 1440) {
          const length = await page.evaluate(() => ({
            open: document.querySelectorAll('main details[open]').length,
            words: document.querySelector('main').innerText.split(/\s+/).filter(Boolean).length,
            height: document.documentElement.scrollHeight,
          }));
          report.features ??= [];
          report.features.push({ theme, ...length });
          console.log(`  ${path} ${theme} 1440 px, questions closed: ${length.words} words, ${length.height} px high.`);
          assert.equal(length.open, 0, `Disclosures open on ${path}`);
          assert(length.words <= 900, `${path} shows ${length.words} words, more than 900`);
          assert(length.height <= 6000, `${path} is ${length.height} px high at 1440 px, more than 6000`);
          // No illustrative example; "Learn from your runs" is its own section after "Verify before you accept", and #learn lands there (#390).
          const features = await page.evaluate(() => ({
            sections: [...document.querySelectorAll('main section[id]')].map(section => section.id),
            illustrative: [...document.querySelectorAll('main p')].filter(p => p.innerText.trim().startsWith('Illustrative example.')).length,
            learn: ['learn-h', 'learn-t', 'learn-words'].map(id => document.getElementById(id)?.closest('section')?.id),
          }));
          assert.deepEqual(features.sections.slice(0, 4), ['agree', 'independent', 'verify', 'learn'], 'The sections of Features and their order');
          assert.equal(features.illustrative, 0, 'Features still has an illustrative example');
          assert.deepEqual(features.learn, ['learn', 'learn', 'learn'], 'The old ids of learning are not in its section');
          assert.equal(await page.locator('#learn-h').innerText(), 'Learn from your runs');
        }
        // History (#390): the owner's story with "What comes next" first, then the periods and the research; the removed sections' ids at the top.
        if (path === base + 'docs/history/' && width === 1440) {
          const history = await page.evaluate(() => ({
            title: document.querySelector('main h1').innerText,
            headings: [...document.querySelectorAll('.docs-body h2')].map(h => h.innerText),
            toc: [...document.querySelectorAll('.docs-toc a')].map(a => a.innerText),
            top: ['phases', 'principles', 'decisions'].map(id => document.getElementById(id)?.nextElementSibling?.tagName ?? 'missing'),
            first: document.querySelector('.docs-body .prose > p')?.innerText,
          }));
          const parts = ['Giving each agent a job', 'Making the handoffs reliable', 'From an issue to a pull request', 'Learning from real projects', 'What comes next', 'History', 'Research'];
          assert.equal(history.title, 'How Agent Codeyard began');
          assert.deepEqual(history.headings, parts, 'The parts of History and their order');
          assert.deepEqual(history.toc, parts, 'On this page of History');
          assert.deepEqual(history.top, ['SPAN', 'SPAN', 'P'], 'The old ids of the removed sections are not at the top of History');
          assert(history.first?.startsWith('I started Agent Codeyard with a question'), 'History does not open with the story');
        }
        // About (#376): three parts in order, 300 to 500 visible words in <main>,
        // one link to History and research, and every old anchor in the page.
        if (path === base + 'about/' && width === 1440) {
          const about = await page.evaluate(() => ({
            parts: [...document.querySelectorAll('main section > .wrap h2')].map(h => h.closest('section').id),
            words: document.querySelector('main').innerText.split(/\s+/).filter(Boolean).length,
            history: [...document.querySelectorAll('main a')].filter(a => new URL(a.href).pathname.endsWith('/docs/history/')).map(a => a.innerText),
            projects: [...document.querySelectorAll('main a')].filter(a => /\/(examples|docs\/engineering-records)\/$/.test(new URL(a.href).pathname)).length,
            missing: ['maker', 'maker-h', 'why', 'limits', 'limits-h', 'history', 'decisions', 'research', 'contribute', 'contribute-h', 'source', 'source-h', 'improvements'].filter(id => !document.getElementById(id)),
          }));
          console.log(`  ${path} ${theme} 1440 px: ${about.words} words.`);
          assert.deepEqual(about.parts, ['maker', 'why', 'contribute'], 'The parts of About and their order');
          assert(about.words >= 300 && about.words <= 500, `${path} shows ${about.words} words, not 300 to 500`);
          assert.deepEqual(about.history, ['How Agent Codeyard began'], 'About links the story on History once');
          assert.equal(about.projects, 0, 'About links Projects or Engineering records');
          assert.deepEqual(about.missing, [], 'Every old anchor of About resolves');
        }
      }
    }
    console.log(`  Checked ${path} in both themes at all its widths.`);
  }
  // A link to a question of Features, as the redirect of /faq/ makes, opens its answer (#374).
  for (const id of ['cost', 'data-h']) {
    await page.goto(origin + base + 'features/#' + id);
    assert(await page.locator(`#${id}`).evaluate(e => e.closest('details').open), `features/#${id} leaves its answer closed`);
  }
  // Features raises no script error without a hash, with a question's hash or with an unknown one (#386).
  const featureErrors = [];
  const onError = error => featureErrors.push(error.message);
  page.on('pageerror', onError);
  for (const hash of ['', '#cost', '#no-such-question']) {
    await page.goto(origin + base + 'features/' + hash);
    await page.waitForLoadState('load');
    assert.deepEqual(featureErrors, [], `features/${hash} raises a script error`);
  }
  page.off('pageerror', onError);
  assert.deepEqual([...external], [], 'Third-party resources are forbidden');
  assert.deepEqual(errors, [], 'JavaScript errors');

  report.largestPage = report.pages.reduce((a, b) => a.pageBytes > b.pageBytes ? a : b);
  console.log(`browser-check: ${pages.length} pages, both themes, five or six widths; ${redirects.length} redirect pages; keyboard checks passed (${base}).`);
  for (const p of report.pages) console.log(`  ${p.path}: JS ${p.javascriptBytes} bytes; page ${p.pageBytes} bytes (uncompressed, cold load)`);
  console.log(`  Largest page: ${report.largestPage.path}, ${report.largestPage.pageBytes} bytes. No third-party requests.`);
} finally {
  await writeFile(join(reportDir, 'report.json'), JSON.stringify(report, null, 2));
  await browser?.close();
  await new Promise(r => server.close(r));
}
