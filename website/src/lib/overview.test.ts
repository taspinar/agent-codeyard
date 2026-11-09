// Tests of the four-step overview of /workflow against the rules of its first
// layer (#330, the shared scenario of #328). Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { answers, label, phases, scenario, steps, words } from "./overview.ts";
import { feature, planning } from "./steps.ts";

test("four steps: planning once at the start, then build, check and decide for each function", () => {
  assert.deepEqual(phases.map((phase) => phase.steps.map((step) => step.title)), [
    ["Describe and clarify what you need", "Plan"],
    ["Build and check", "Decide"],
  ]);
  assert.match(phases[0].title, /once/i);
  assert.match(phases[1].title, /each function/i);
  assert.match(phases[1].note, /next function/);
  assert.equal(label, "Illustrative example");
});

test("every step names what you do, what the system does, what comes out and why that helps", () => {
  assert.deepEqual(answers.map(([, name]) => name), ["What you do", "What the system does", "What comes out", "Why that helps"]);
  for (const step of steps) for (const [key] of answers) assert.ok(step.text[key].trim(), `${step.id}: ${key}`);
});

test("every step text is at most 40 words", () => {
  for (const step of steps) assert.ok(words(step) <= 40, `${step.id}: ${words(step)} words`);
  assert.equal(words({ ...steps[0], text: { you: "One two.", system: "Three", result: " four  five ", why: "six" } }), 6);
});

test("the first layer has no risk, unattended, acceptance criteria or script name", () => {
  const texts = [
    scenario.product, scenario.function,
    ...phases.flatMap((phase) => [phase.title, phase.note]),
    ...steps.flatMap((step) => [step.title, ...Object.values(step.text), ...step.example.flatMap((e) => [e.label, ...e.items])]),
  ];
  for (const text of texts) assert.doesNotMatch(text, /\brisk|unattended|acceptance criteri|\.sh\b|pull request|triage|Project Grill/i, text);
});

test("the scenario is the one of the tracking issue: three questions, three agreements, the plan order", () => {
  assert.match(scenario.function, /^Trainers record attendance for their classes; members see their own training history\.$/);
  const [clarify, plan] = steps;
  assert.equal(clarify.example.find((e) => e.label === "Questions")!.items.length, 3);
  assert.equal(clarify.example.find((e) => e.label === "Agreements")!.items.length, 3);
  assert.deepEqual(plan.example[0].items, ["Users and roles", "Classes and attendance", "The member's history view"]);
});

test("every step links to existing steps of the workflow reference, and its anchor is its own", () => {
  const reference = [...planning, ...feature].map((step) => step.id);
  for (const step of steps) {
    assert.ok(step.reference.length, step.id);
    for (const id of step.reference) assert.ok(reference.includes(id), `${step.id}: ${id}`);
  }
  const ids = steps.map((step) => step.id);
  assert.equal(new Set([...ids, ...reference]).size, ids.length + reference.length, "no overview anchor is a step anchor");
});
