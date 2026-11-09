// Tests of the states of the workflow map against the rules of
// docs/development.md that each state draws. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { agent, describe, example, follow, guide, initial, parseAgents, route, routes, stateOf, switches, type State } from "./workflow.ts";

const models = parseAgents(readFileSync(new URL("../../../.agents/agents.conf", import.meta.url), "utf8"));
const view = (change: Partial<State>) => describe({ ...initial, ...change }, models);
const keys = (state: Partial<State>) => view(state).walk.map((step) => step.key);

test("the initial state is the complete drawing: no branch taken, only the bypass off (policy excludes it)", () => {
  const v = view({});
  assert.deepEqual(v.off, ["b-bypass", "n-bypass"]);
  assert.deepEqual(v.taken, []);
  for (const key of ["b-bypass", "n-bypass"]) assert.ok(!v.hidden.includes(key), key);
  assert.ok(v.hidden.includes("f-merge-approval"), "the approval flag shows only when it is required");
  assert.deepEqual(v.summary, ["Medium risk", "standard profile", "step by step"]);
});

test("low risk skips the review only under a policy with low: review: none (light)", () => {
  const light = view({ risk: "low", profile: "light" });
  for (const key of ["f-review", "f-findings", "s-f-review", "s-f-findings"]) assert.ok(light.off.includes(key), key);
  assert.ok(light.taken.includes("b-bypass") && light.taken.includes("n-bypass"));
  assert.ok(light.hidden.includes("w-f-review") && light.hidden.includes("w-f-findings"));
  assert.ok(!light.hidden.includes("f-merge-approval"), "without a review the merge needs the owner's approval");
  assert.ok(!keys({ risk: "low", profile: "light" }).includes("f-review"));

  const standard = view({ risk: "low", profile: "standard" });
  assert.ok(!standard.off.includes("f-review"));
  assert.ok(keys({ risk: "low" }).includes("f-review"));
  assert.ok(standard.hidden.includes("f-merge-approval"));
  assert.ok(!standard.hidden.includes("b-bypass") && !standard.taken.includes("b-bypass"), "visible, not taken");
  for (const risk of ["low", "medium", "high"] as const) {
    for (const profile of ["standard", "light"] as const) {
      if (risk === "low" && profile === "light") continue;
      const v = view({ risk, profile });
      for (const key of ["b-bypass", "n-bypass"]) assert.ok(v.off.includes(key) && !v.taken.includes(key), `${key} off at ${risk}, ${profile}`);
    }
  }
});

test("high risk is never lighter: reviewed and fully triaged under every profile", () => {
  for (const profile of ["standard", "light"] as const) {
    const v = view({ risk: "high", profile });
    assert.ok(!v.off.includes("f-review"), profile);
    assert.equal(v.labels["f-findings.sub"], "you approve each decision", profile);
    assert.equal(view({ risk: "high", profile, run: "unattended" }).labels["f-findings.sub"], "a decision per finding", profile);
  }
  assert.match(view({ risk: "medium", profile: "light" }).labels["f-findings.sub"], /^minor ones may wait$/);
  assert.equal(view({ risk: "low", profile: "light" }).labels["f-findings.sub"], "nothing to decide");
});

test("the implementer's model follows the risk level of agents.conf", () => {
  assert.equal(view({ risk: "high" }).labels["f-implement.sub"], agent(models, "implementer", "high"));
  assert.equal(view({ risk: "medium" }).labels["f-implement.sub"], agent(models, "implementer", "medium"));
  assert.equal(agent({ implementer: { "": "claude opus", high: "claude fable" } }, "implementer", "low"), "claude opus");
});

test("the shipped reviewer is of another provider than the implementer at every level, as the map says", () => {
  for (const level of ["low", "medium", "high"] as const) {
    const provider = (role: string) => agent(models, role, level).split(" ")[0];
    assert.notEqual(provider("reviewer"), provider("implementer"), level);
  }
});

test("an unclear Issue stops the implementation until the owner answers", () => {
  const v = view({ situation: "unclear" });
  assert.ok(v.taken.includes("b-clarify"));
  for (const key of ["f-checks", "f-review", "f-commit", "f-merge"]) assert.ok(v.off.includes(key), key);
  const walk = keys({ situation: "unclear", part: "feature" });
  assert.deepEqual(walk.slice(0, 5), ["f-issue", "f-implement", "b-clarify", "f-answer", "f-implement"]);
  assert.match(view({ situation: "unclear", run: "unattended" }).labels["w-f-implement.cond"], /status 3/);
});

test("a failed check is repaired before anything is reviewed", () => {
  const walk = keys({ situation: "repair", part: "feature" });
  assert.ok(walk.indexOf("b-repair") > walk.indexOf("f-checks"));
  assert.ok(walk.indexOf("b-repair") < walk.indexOf("f-review"));
  assert.ok(view({ situation: "repair" }).taken.includes("b-repair"));
});

test("findings are fixed, checked and reviewed again; without a review there are none", () => {
  const walk = keys({ situation: "findings", part: "feature" });
  const fix = walk.indexOf("b-fix");
  assert.ok(fix > walk.indexOf("f-findings"));
  assert.deepEqual(walk.slice(fix + 1, fix + 3), ["f-checks", "f-review"]);
  assert.ok(!view({ situation: "findings", risk: "low", profile: "light" }).taken.includes("b-fix"));
});

test("a protected path needs the owner's approval of the merge", () => {
  const v = view({ situation: "protected" });
  assert.ok(!v.hidden.includes("f-merge-approval"));
  assert.match(v.labels["w-f-merge.cond"], /protected path/);
});

test("step by step the owner approves the triage; unattended an agent decides", () => {
  const steps = view({ run: "steps" });
  assert.deepEqual(steps.gates, ["f-findings"]);
  assert.ok(steps.hidden.includes("f-findings-ring"));
  const unattended = view({ run: "unattended" });
  assert.deepEqual(unattended.gates, []);
  assert.ok(unattended.hidden.includes("f-findings-gate"));
  assert.ok(!unattended.hidden.includes("n-unattended"));
});

test("planning and feature execution are each shown alone", () => {
  const planning = view({ part: "planning" });
  assert.ok(planning.off.includes("f-implement") && !planning.off.includes("p-plan"));
  assert.ok(planning.hidden.includes("w-feature"));
  assert.ok(planning.walk.every((step) => step.key.startsWith("p-")));
  const feature = view({ part: "feature" });
  assert.ok(feature.off.includes("p-plan") && !feature.off.includes("f-implement"));
  assert.ok(feature.walk.every((step) => !step.key.startsWith("p-")));
});

test("every state's walkthrough moves only along elements of the map", () => {
  const values = (name: string) => switches.find((s) => s.name === name)!.options.map(([value]) => value);
  for (const part of values("part")) for (const run of values("run")) for (const risk of values("risk"))
    for (const profile of values("profile")) for (const situation of values("situation")) {
      const v = describe(stateOf({ part, run, risk, profile, situation }), models);
      assert.ok(v.walk.length > 0);
      for (const step of v.walk) for (const key of [step.key, ...step.lights]) assert.ok(route.includes(key), `${key} in ${part}/${risk}/${profile}/${situation}`);
      assert.equal(v.walk.at(-1)!.key, part === "planning" ? "p-merge" : "f-merge");
    }
});

test("an unknown switch value falls back to the initial state", () => {
  assert.deepEqual(stateOf({ risk: "extreme", part: "feature" }), { ...initial, part: "feature" });
});

test("the summary names every switch that differs from the initial state, in plain words", () => {
  assert.deepEqual(view({ risk: "high", run: "unattended", part: "feature", situation: "repair" }).summary,
    ["High risk", "standard profile", "unattended", "one feature", "checks fail"]);
  assert.deepEqual(view({ part: "planning", profile: "light" }).summary, ["Medium risk", "light profile", "step by step", "planning only"]);
});

test("the walkthrough pauses at the owner's decisions, and at the triage only step by step", () => {
  const paused = (state: Partial<State>) => view(state).walk.filter((step) => step.you).map((step) => step.key);
  assert.deepEqual(paused({}), ["p-approve-req", "p-approve", "p-merge", "f-findings", "f-merge"]);
  assert.deepEqual(paused({ run: "unattended", part: "feature" }), ["f-merge"]);
  assert.deepEqual(paused({ situation: "unclear", part: "feature" }), ["f-answer", "f-findings", "f-merge"]);
});

test("the real case follows #241 along the route the switches draw for its state, and says who acts at every step", () => {
  const steps = guide(models);
  const route241 = describe(example, models).walk;
  assert.deepEqual(steps.map((step) => [step.key, step.lights]), route241.map((step) => [step.key, step.lights]));
  assert.deepEqual(steps.map((step) => step.key), [
    "f-issue", "f-implement", "f-checks", "f-review", "f-findings", "b-fix", "f-checks", "f-review", "f-findings", "f-commit", "f-pr", "f-merge",
  ]);
  for (const step of steps) assert.ok(step.who && step.text, step.key);
  assert.deepEqual(steps.filter((step) => step.you).map((step) => step.key), ["f-issue", "f-merge"], "it stops at your decisions: the start and the merge");
  assert.deepEqual(example, { part: "feature", run: "unattended", risk: "medium", profile: "standard", situation: "findings" }, "#241: one unattended run, medium risk, one major finding");
});

test("the routes of the map are one exception each, step by step, and every step names who acts; #241 is not one of them", () => {
  assert.deepEqual(routes.map((r) => r.id), ["repair", "unclear", "findings", "high"]);
  assert.deepEqual(follow("unknown", models).walk, follow("repair", models).walk, "an unknown route is the first one");
  const situation = (id: string) => routes.find((r) => r.id === id)!.state;
  assert.equal(situation("repair").situation, "repair");
  assert.equal(situation("unclear").situation, "unclear");
  assert.equal(situation("findings").situation, "findings");
  assert.equal(situation("high").risk, "high");
  for (const r of routes) {
    assert.equal(r.state.run, "steps", r.id);
    const walk = follow(r.id, models).walk;
    assert.deepEqual(walk, describe(r.state, models).walk, r.id);
    for (const step of walk) assert.ok(step.who, `${r.id}: ${step.key}`);
  }
  assert.ok(follow("findings", models).walk.some((step) => step.key === "f-findings" && step.you), "step by step you approve the triage");
});

test("every step text of the tour of #241 is at most 40 words and has no risk, unattended, acceptance criteria or script name", () => {
  const words = (text: string) => text.trim().split(/\s+/).length;
  for (const step of guide(models)) {
    assert.ok(words(step.text) <= 40, `${step.key}: ${words(step.text)} words`);
    for (const text of [step.text, step.who]) assert.doesNotMatch(text, /\brisk|unattended|acceptance criteri|\.sh\b/i, `${step.key}: ${text}`);
  }
  assert.equal(words(" One two,  three. "), 3);
});

test("every walkthrough step is at most three sentences; the reference entry tells the rest", () => {
  const sentences = (text: string) => text.match(/[.!?](?=\s|$)/g)?.length ?? 0;
  const values = (name: string) => switches.find((s) => s.name === name)!.options.map(([value]) => value);
  const walks = [guide(models), ...routes.map((r) => follow(r.id, models).walk)];
  for (const part of values("part")) for (const run of values("run")) for (const risk of values("risk"))
    for (const profile of values("profile")) for (const situation of values("situation"))
      walks.push(describe(stateOf({ part, run, risk, profile, situation }), models).walk);
  for (const walk of walks) for (const step of walk) assert.ok(sentences(step.text) <= 3, `${step.key}: ${step.text}`);
  assert.equal(sentences("One. Two, in docs/development.md. Three: start-feature.sh <issue> --resume."), 3);
});
