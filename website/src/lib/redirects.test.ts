// Tests of the table of old addresses (#373). The walk of the whole table on
// the built site is in search-test.mjs. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { docsAliases, moved, retired, routes, stays } from "./redirects.ts";
import { topics } from "./docs.ts";

test("the retired docs routes of the plan, rows 7 to 20 without 13, each into a topic of /docs/", () => {
  assert.equal(retired.length, 13);
  for (const route of retired) {
    assert.match(route.path, /^docs\//);
    assert.ok(topics.some((topic) => topic.id === route.topic), route.path);
    assert.ok(route.title, route.path);
  }
});

test("the routes that stay: the product pages, /docs/ and the Appendix", () => {
  assert.deepEqual(stays.map((route) => route.path), ["", "workflow/", "features/", "examples/", "about/", "faq/", "docs/", "docs/engineering-records/", "docs/history/"]);
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
  assert.equal(moved(routes.find((route) => route.path === "faq/")!, "cost"), "faq/#cost");
});
