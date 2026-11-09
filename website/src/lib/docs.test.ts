// Tests of the order of the docs sidebar, which is also the order of the
// previous and next links. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { groups } from "./docs.ts";

test("the sidebar goes from beginning and using to configuring and reference (#334)", () => {
  assert.deepEqual(groups.map((group) => group.label), ["Begin", "Use", "Configure", "Reference"]);
});

test("the four entries of the docs index are in the first two groups", () => {
  const early = groups.slice(0, 2).flatMap((group) => group.pages.map((page) => page.id));
  for (const id of ["new-to-agentic-coding", "getting-started", "adopting", "troubleshooting"]) assert.ok(early.includes(id), id);
});

test("Engineering records is a page of the Reference group (#344)", () => {
  const reference = groups.find((group) => group.label === "Reference")!;
  assert.ok(reference.pages.some((page) => page.id === "engineering-records" && page.title === "Engineering records"));
});
