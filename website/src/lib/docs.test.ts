// Tests of the sections and topics of Technical Documentation and of the
// prefix of its ids (#373). Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { appendix, first, prefixed, sections, topics } from "./docs.ts";

test("the sections of the plan, in its order, with Quick Start first (website/design/INFORMATION-ARCHITECTURE.md, 4.2)", () => {
  assert.deepEqual(sections.map((section) => section.label), ["Quick Start", "Adopting an Existing Repository", "Workflow & Commands", "Configuration", "Verification & Review", "Troubleshooting", "Technical Reference"]);
  assert.equal(first.id, "quick-start");
});

test("a section's id is the id of its first topic, and every topic id is unique", () => {
  for (const section of sections) assert.equal(section.topics[0].id, section.id);
  assert.equal(new Set(topics.map((topic) => topic.id)).size, topics.length);
});

test("the topics and the files that feed them", () => {
  assert.deepEqual(Object.fromEntries(topics.map((topic) => [topic.id, topic.entry ?? null])), {
    "quick-start": "getting-started", "new-to-agentic-coding": "new-to-agentic-coding", adopting: "adopting",
    "workflow-and-commands": "detailed-workflow", updating: "updating", configuration: "configuration-and-security",
    "agent-roles": "agent-roles", "risk-policy": "risk-policy", "github-setup": "github-setup",
    "verification-and-review": "verification-and-completion", troubleshooting: "troubleshooting",
    "technical-reference": "technical-reference", "workflow-reference": null,
  });
});

test("Engineering records and History and research are the Appendix, pages of their own", () => {
  assert.deepEqual(appendix.map((item) => item.path), ["docs/engineering-records/", "docs/history/"]);
});

test("every id of a topic gets the topic as prefix, and so do links to its own ids", () => {
  const html = '<a id="gate"></a><h2 id="the-limits">The limits</h2><p><a href="#gate">gate</a> <a href="#adopting">Adopting</a> <a href="#risk-policy/three-settings">three</a> <a href="https://example.com/#gate">out</a></p><h3 id="sub">Sub</h3>';
  assert.equal(prefixed(html, "configuration"),
    '<a id="configuration/gate"></a><h3 id="configuration/the-limits">The limits</h3><p><a href="#configuration/gate">gate</a> <a href="#adopting">Adopting</a> <a href="#risk-policy/three-settings">three</a> <a href="https://example.com/#gate">out</a></p><h4 id="configuration/sub">Sub</h4>');
});

test("a link to an id that is neither the topic's own nor a topic stops the build", () => {
  assert.throws(() => prefixed('<a href="#missing">x</a>', "adopting"), /#missing/);
});

test("the text of code is not taken for an id", () => {
  assert.equal(prefixed('<pre><code>&lt;a id="x"&gt;</code></pre>', "updating"), '<pre><code>&lt;a id="x"&gt;</code></pre>');
});
