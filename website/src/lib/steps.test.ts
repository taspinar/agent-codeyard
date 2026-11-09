// Tests of the workflow reference and of the step detail of the workflow map
// against the steps, which both show. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { details, entry, feature, fields, parameters, placeholders, planning, reference, stages, stations, tabs } from "./steps.ts";
import { feature as featureLine, planning as planningLine, route } from "./workflow.ts";

test("every station of the map opens a detail, and every step it names exists", () => {
  assert.deepEqual(Object.keys(stations).sort(), [...planningLine, ...featureLine].sort());
  for (const key of Object.keys(stations)) assert.ok(details(key), key);
  assert.equal(details("t-planning"), undefined, "a stage title is not a station");
});

test("the detail keeps every fact of its steps, each in exactly one field, in the fixed order of each tab", () => {
  for (const key of Object.keys(stations)) {
    const detail = details(key)!;
    const steps = [...planning, ...feature].filter((step) => stations[key].includes(step.id));
    const shown = detail.tabs.flatMap((tab) => tab.rows.flatMap((row) => row.facts.map((fact) => `${fact.label}: ${fact.value}`)));
    assert.deepEqual(shown.sort(), steps.flatMap((step) => step.facts.map(([term, value]) => `${term}: ${value}`)).sort(), key);
    for (const tab of detail.tabs) {
      const order = tab.rows.map((row) => fields.findIndex(([, label]) => label === row.label));
      assert.deepEqual(order, [...order].sort((a, b) => a - b), `${key} ${tab.id}`);
    }
    assert.deepEqual(detail.summaries, steps.map((step) => step.summary), key);
  }
});

test("the panel shortens a step to one sentence; the full text is the reference's", () => {
  for (const step of [...planning, ...feature]) {
    assert.equal(step.summary.match(/[.!?](?=\s|$)/g)?.length, 1, step.id);
    assert.ok(step.summary.length < step.text.length, `${step.id}: the summary is shorter than the text`);
  }
});

test("the tabs: who acts and the decision; the command and what goes in and out; the stops", () => {
  assert.deepEqual(tabs.map((tab) => tab.name), ["Overview", "Technical", "Failure states"]);
  const review = details("f-review")!;
  const rows = (id: string) => review.tabs.find((tab) => tab.id === id)!.rows;
  assert.deepEqual(rows("overview").map((row) => row.label), ["Who acts"]);
  assert.deepEqual(rows("technical").map((row) => row.label), ["Command", "Inputs and outputs"]);
  assert.deepEqual(rows("failure").map((row) => row.label), ["Stops, retries and exceptions"]);
  assert.deepEqual(rows("failure")[0].facts.map((fact) => fact.label), ["refused if", "refused if", "changes only", "earlier rounds"]);
  assert.deepEqual(rows("technical")[0].facts.map((fact) => [fact.label, fact.shown]), [["script", false], ["where", true]], "the command needs no sub-label; where it runs keeps its own");
  assert.equal(rows("technical")[1].facts[0].shown, true, "inputs and outputs keep their label");
});

test("a station with two steps shows both, titled by the first", () => {
  const findings = details("f-findings")!;
  assert.equal(findings.title, "Decide on the findings");
  assert.deepEqual(findings.steps.map((step) => step.id), ["decide-on-the-findings", "apply-the-fixes"]);
  const gate = findings.tabs[0].rows.find((row) => row.label === "Gate or decision")!;
  assert.deepEqual(gate.facts.map((fact) => fact.label), ["your decision", "next"]);
});

test("the reference shows every step once, by stage, and every fact of a step in exactly one of the five fields", () => {
  assert.deepEqual(stages.flatMap((stage) => stage.steps), [...planning, ...feature]);
  const ids = [...planning, ...feature].map((step) => step.id);
  assert.equal(new Set([...ids, ...stages.map((stage) => stage.id)]).size, ids.length + stages.length, "anchors are unique");
  for (const step of [...planning, ...feature]) {
    const rows = reference(step);
    const shown = rows.flatMap((row) => row.facts.map((fact) => `${fact.label}: ${fact.value}`));
    assert.deepEqual(shown.sort(), step.facts.map(([term, value]) => `${term}: ${value}`).sort(), step.id);
    const order = rows.map((row) => fields.findIndex(([, label]) => label === row.label));
    assert.deepEqual(order, [...order].sort((a, b) => a - b), step.id);
    assert.ok(rows.every((row) => row.facts.length), `${step.id}: an empty field is omitted`);
  }
});

test("a reference field keeps the original labels where it gathers several or is not who or command", () => {
  const rows = reference(feature.find((step) => step.id === "commit-the-feature")!);
  assert.deepEqual(rows.map((row) => row.label), ["Who acts", "Command", "Stops, retries and exceptions"]);
  assert.equal(rows[0].facts[0].shown, false);
  assert.deepEqual(rows[2].facts.map((fact) => [fact.label, fact.shown]), [["refused if", true], ["without review", true], ["partial", true], ["important", true]]);
});

test("every element a walkthrough reaches links to its entry in the reference", () => {
  // The stations and the branches a walkthrough stops at; segments and the bypass only light up.
  const reached = route.filter((key) => /^(p|f)-|^b-(clarify|repair|fix)$/.test(key));
  for (const key of reached) assert.ok(entry(key), key);
  assert.equal(entry("b-fix")!.id, "apply-the-fixes");
  assert.equal(entry("f-findings")!.id, "decide-on-the-findings", "a station links to its first step");
  assert.equal(entry("s-f-review"), undefined, "a segment is not a step");
});

test("every step with a command says where it runs, and every placeholder of a command is explained", () => {
  for (const step of [...planning, ...feature]) {
    const terms = step.facts.map(([term]) => term);
    const script = step.facts.find(([term]) => term === "script")?.[1] ?? "";
    if (script.includes("./scripts/")) assert.ok(terms.includes("where"), `${step.id}: no working directory`);
  }
  const explained = parameters.map(([name]) => name);
  assert.equal(new Set(explained).size, explained.length, "each parameter once");
  const used = [...planning, ...feature].flatMap((step) => step.facts.flatMap(([, value]) => placeholders(value)));
  for (const name of new Set(used)) assert.ok(explained.includes(name), `not explained: ${name}`);
  for (const name of explained) assert.ok(used.includes(name), `explained but not used: ${name}`);
  assert.deepEqual(placeholders("`start-feature.sh <issue> [slug]`"), ["<issue>", "<slug>"]);
});
