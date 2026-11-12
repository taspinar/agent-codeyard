// Tests of the table of old addresses (#373). The walk of the whole table on
// the built site is in search-test.mjs. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { docsAliases, moved, retired, routes, stays } from "./redirects.ts";
import { topics } from "./docs.ts";

test("the retired docs routes of the plan, rows 7 to 20 without 13, each into a topic of /docs/", () => {
  assert.equal(retired.length, 15);
  for (const route of retired.filter((r) => r.path.startsWith("docs/"))) {
    assert.match(route.path, /^docs\//);
    assert.ok(topics.some((topic) => topic.id === route.topic), route.path);
    assert.ok(route.title, route.path);
  }
});

test("the routes that stay: the product pages, /docs/ and the Appendix (3.4)", () => {
  assert.deepEqual(stays.map((route) => route.path), ["", "features/", "examples/", "about/", "docs/", "docs/engineering-records/", "docs/history/"]);
  assert.equal(routes.length, 22);
});

test("an old anchor of a retired route maps to the same id in its topic, a layout id to the topic", () => {
  const troubleshooting = routes.find((route) => route.path === "docs/troubleshooting/")!;
  assert.equal(moved(troubleshooting), "docs/#troubleshooting");
  assert.equal(moved(troubleshooting, "a-check-fails"), "docs/#troubleshooting/a-check-fails");
  assert.equal(moved(troubleshooting, "main"), "docs/#troubleshooting");
  const reference = routes.find((route) => route.path === "docs/reference/workflow/")!;
  assert.equal(moved(reference, "review-the-code-h"), "docs/#workflow-reference/review-the-code-h");
});

test("the old ids of /docs/ itself lead to their new places; a route that stays keeps its ids", () => {
  const docs = routes.find((route) => route.path === "docs/")!;
  assert.equal(moved(docs, "what-stays-with-you"), "docs/#configuration/the-limits-in-short");
  assert.equal(moved(docs, "sources-and-scope"), "docs/#technical-reference/sources-and-scope");
  assert.equal(moved(docs, "main"), "docs/#main");
  assert.deepEqual(Object.keys(docsAliases), ["what-stays-with-you", "find-a-command-or-setting", "more-to-read", "sources-and-scope"]);
  assert.equal(moved(routes.find((route) => route.path === "about/")!, "maker"), "about/#maker");
});

test("/workflow/ and /faq/ are retired as rows 2 and 6 of the table say (#377)", () => {
  const workflow = routes.find((route) => route.path === "workflow/")!;
  const faq = routes.find((route) => route.path === "faq/")!;
  assert.deepEqual(retired.filter((route) => !route.topic), [workflow, faq]);
  assert.equal(moved(workflow), "#demo");
  for (const [id, to] of [["overview-h", "#demo"], ["technical-h", "docs/#workflow-map"], ["explore", "docs/#workflow-map/explore"], ["step-tab-body", "docs/#workflow-map/step-tab-body"],
    ["ways-h", "docs/#workflow-and-commands/step-by-step-or-unattended"], ["case", "docs/engineering-records/#story"], ["steps-h", "docs/#workflow-reference"],
    ["review-the-code", "docs/#workflow-reference/review-the-code"], ["no-such-anchor", "#demo"]]) assert.equal(moved(workflow, id), to, id);
  assert.equal(moved(faq), "features/#faq");
  for (const [id, to] of [["main", "features/#faq"], ["what-h", "features/"], ["cost", "features/#cost"], ["too-heavy-h", "features/#too-heavy"], ["checked", "features/#verify"],
    ["software-h", "#who"], ["wrong", "docs/#troubleshooting"], ["online-h", "docs/#configuration/the-limits-in-short"], ["environments", "docs/#quick-start/before-you-start"],
    ["stop-h", "docs/#troubleshooting/a-session-or-a-run-was-interrupted"], ["unattended", "docs/#configuration/unattended"]]) assert.equal(moved(faq, id), to, id);
});
