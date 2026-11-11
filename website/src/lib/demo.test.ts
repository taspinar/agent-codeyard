// Tests of the step logic of the home page's workflow demo (#370): the
// timeline and the player, the terminals, the dialogs' steps, both ways back
// on a lane and the merges one at a time. Run by check.sh --build:
//   node --test "src/**/*.test.ts"  (in website/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { createDemo, featureSteps, featuresFrom, lanes, last, laneState, lineKind, loopAt, mergeAt, moments, planSteps, planningFiles, prsAt, stages, terminalLog, terminals, tree, type DemoState, type Timer } from "./demo.ts";

/** A timer that ticks only when the test says so. */
function manualTimer() {
  let tick: (() => void) | null = null;
  const timer: Timer = { start: (fn) => { tick = fn; return 1; }, stop: () => { tick = null; } };
  return { timer, tick: () => tick?.(), get running() { return tick !== null; } };
}

function demo() {
  const clock = manualTimer();
  const seen: DemoState[] = [];
  return { clock, seen, d: createDemo((s) => seen.push(s), clock.timer) };
}

test("nothing plays until play is pressed; playing advances one moment per tick and stops at the end", () => {
  const { clock, d } = demo();
  assert.deepEqual(d.state, { moment: 0, playing: false, lane: "f02" });
  assert.ok(!clock.running, "no timer runs on load");
  d.play();
  assert.ok(d.state.playing && clock.running);
  clock.tick();
  clock.tick();
  assert.equal(d.state.moment, 2);
  for (let i = 0; i < 40; i++) clock.tick();
  assert.equal(d.state.moment, last);
  assert.ok(!d.state.playing && !clock.running, "it stops at the last moment");
  d.play();
  assert.equal(d.state.moment, 0, "play at the end starts over");
});

test("pause holds the moment, and every manual control pauses", () => {
  const { clock, d } = demo();
  d.play();
  clock.tick();
  d.pause();
  assert.deepEqual([d.state.moment, d.state.playing, clock.running], [1, false, false]);
  clock.tick();
  assert.equal(d.state.moment, 1, "a paused demo does not advance");
  for (const control of [() => d.next(), () => d.previous(), () => d.go(5), () => d.restart(), () => d.select("f03")]) {
    d.play();
    control();
    assert.ok(!d.state.playing && !clock.running);
  }
  d.toggle();
  assert.ok(d.state.playing);
  d.toggle();
  assert.ok(!d.state.playing);
});

test("the timeline goes to any moment and stays within the run", () => {
  const { d } = demo();
  d.go(7);
  assert.equal(d.state.moment, 7);
  d.go(-3);
  assert.equal(d.state.moment, 0);
  d.previous();
  assert.equal(d.state.moment, 0);
  d.go(99);
  assert.equal(d.state.moment, last);
  d.next();
  assert.equal(d.state.moment, last);
  d.restart();
  assert.equal(d.state.moment, 0);
  assert.equal(moments.length, 19);
});

test("the terminals keep every earlier message, and selecting a feature switches the active terminal", () => {
  const { d } = demo();
  assert.deepEqual(terminals(3, "f02").map((t) => t.key), ["planning"]);
  const planning = terminalLog(8, "planning");
  assert.deepEqual(planning.map((e) => e.moment), [0, 1, 2, 3, 4, 5, 6, 7, 8], "the planning terminal is cumulative");
  assert.deepEqual(terminalLog(3, "planning"), planning.slice(0, 4));
  d.go(12);
  let shown = terminals(d.state.moment, d.state.lane);
  assert.deepEqual(shown.map((t) => t.key), ["f02", "f03", "f04"], "three feature terminals side by side");
  assert.deepEqual(shown.filter((t) => t.active).map((t) => t.key), ["f02"]);
  d.select("f04");
  shown = terminals(d.state.moment, d.state.lane);
  assert.deepEqual(shown.filter((t) => t.active).map((t) => t.key), ["f04"]);
  assert.equal(d.state.moment, 12, "switching terminals keeps the moment");
  for (const t of shown) assert.deepEqual(t.entries.map((e) => e.moment), [9, 10, 11, 12], `${t.key} keeps its earlier messages`);
  d.restart();
  d.select("f03");
  assert.equal(d.state.moment, featuresFrom, "selecting a feature before the features start goes to their start");
  assert.deepEqual(lineKind("$ ./scripts/verify.sh"), { kind: "command", text: "./scripts/verify.sh" });
  assert.equal(lineKind("! M1 major").kind, "problem");
});

test("no moment leaves a panel empty", () => {
  for (let m = 0; m <= last; m++) {
    for (const t of terminals(m, "f02")) {
      assert.ok(t.entries.length > 0, `terminal ${t.key} at ${m}`);
      assert.ok(t.entries.at(-1)!.lines.length > 0);
    }
    const groups = tree(m);
    assert.ok(groups.length > 0 && groups.every((g) => g.items.length > 0), `tree at ${m}`);
    assert.ok(moments[m].title && moments[m].who && moments[m].text, `caption at ${m}`);
  }
});

test("a failed check goes back to Build and is verified again, on that lane only", () => {
  assert.equal(loopAt(10), null);
  for (const m of [11, 12]) assert.deepEqual([loopAt(m)?.key, loopAt(m)?.lane, loopAt(m)?.from, loopAt(m)?.to], ["repair", "f02", "verify", "build"]);
  const failed = laneState(11, "f02");
  assert.equal(failed.status, "check failed");
  assert.equal(failed.current, "verify");
  assert.ok(!failed.reached.review, "the failed lane does not go on to review");
  assert.equal(laneState(12, "f02").current, "verify", "the repair is verified again");
  assert.ok(!laneState(12, "f02").reached.review);
  assert.ok(laneState(12, "f03").reached.review, "the other lanes go on");
  assert.match(terminalLog(11, "f02").at(-1)!.lines.join("\n"), /FAIL/);
  assert.match(terminalLog(12, "f02").at(-1)!.lines.join("\n"), /all checks pass/);
});

test("a review finding runs through Triage back to a fix, a check and a new review", () => {
  for (const m of [13, 14]) assert.deepEqual([loopAt(m)?.key, loopAt(m)?.from, loopAt(m)?.to], ["findings", "triage", "build"]);
  assert.equal(loopAt(15), null);
  assert.equal(laneState(13, "f02").current, "review");
  assert.ok(!laneState(13, "f02").reached.triage);
  assert.equal(laneState(14, "f02").current, "triage");
  const fix = terminalLog(14, "f02").at(-1)!.lines.join("\n");
  for (const step of ["triage-review.sh", "apply-triage.sh", "verify.sh", "review-feature.sh: round 2, PASS"]) assert.ok(fix.includes(step), step);
  assert.ok(fix.indexOf("apply-triage.sh") < fix.indexOf("verify.sh") && fix.indexOf("verify.sh") < fix.indexOf("review-feature.sh"));
});

test("the three lanes run side by side up to their own pull requests, then merge one at a time at an owner diamond", () => {
  assert.ok(stages.find((s) => s.key === "merge")!.owner, "the merge is an owner diamond");
  for (let m = 0; m < prsAt; m++) for (const l of lanes) assert.ok(!laneState(m, l.key).reached.pr, `${l.key} has no PR at ${m}`);
  for (const l of lanes) assert.ok(laneState(prsAt, l.key).reached.pr && !laneState(prsAt, l.key).merged, `${l.key} has its PR at ${prsAt}`);
  const merges = [];
  for (let m = 0; m <= last; m++) {
    const merged = lanes.filter((l) => laneState(m, l.key).merged && !laneState(m - 1, l.key).merged);
    assert.ok(merged.length <= 1, `at most one merge at ${m}`);
    if (merged.length) {
      merges.push([m, merged[0].key]);
      assert.equal(mergeAt(m)?.key, merged[0].key);
      assert.equal(laneState(m, merged[0].key).current, "merge");
      assert.equal(moments[m].who, "You");
    }
  }
  assert.deepEqual(merges, [[16, "f02"], [17, "f03"], [18, "f04"]]);
  const { d } = demo();
  d.go(17);
  assert.equal(d.state.lane, "f03", "a merge shows the lane it merges");
});

test("the planning documents stay after the features start; work files and GitHub objects are not merged files", () => {
  const docs = planningFiles.filter((f) => !f.local).map((f) => f.path);
  const main = (m: number) => tree(m).find((g) => g.key === "main");
  for (let m = 7; m <= last; m++) {
    const paths = main(m)!.items.flatMap((i) => (i.kind === "file" ? [i.file.path] : []));
    for (const doc of docs) assert.ok(paths.includes(doc), `${doc} on main at ${m}`);
    assert.ok(paths.every((p) => !p.startsWith(".agents/")), `no work file on main at ${m}`);
    assert.ok(main(m)!.items.every((i) => i.kind === "file"), "GitHub objects are not files of main");
  }
  assert.equal(main(6), undefined, "before the approval the plan is in its worktree");
  const github = tree(last).find((g) => g.key === "github")!;
  assert.deepEqual(github.items.map((i) => (i.kind === "github" ? i.label : "")), ["Planning pull request", "Issue #41 Attendance", "Issue #42 Timetable", "Issue #43 Preferences", "Pull request #61", "Pull request #62", "Pull request #63"]);
  for (const g of tree(last).filter((g) => g.key.startsWith("f"))) {
    for (const i of g.items) if (i.kind === "file") assert.equal(Boolean(i.file.local), i.file.path.startsWith(".agents/") && !i.file.path.startsWith(".agents/plans/"), i.file.path);
  }
  const merged = (m: number) => main(m)!.items.filter((i) => i.kind === "file" && i.lane).map((i) => (i.kind === "file" ? i.lane : ""));
  assert.deepEqual([...new Set(merged(15))], []);
  assert.deepEqual([...new Set(merged(16))], ["f02"]);
  assert.deepEqual([...new Set(merged(18))], ["f02", "f03", "f04"]);
});

test("the plan and the feature dialogs list their steps in order, each with a moment to show", () => {
  assert.deepEqual(planSteps.map((s) => s.moment), [3, 4, 5, 6]);
  assert.deepEqual(featureSteps.map((s) => s.name), ["Issue and worktree", "Build", "Verify", "Review", "Triage and fix", "Pull request", "Merge"]);
  for (const steps of [planSteps, featureSteps]) {
    assert.deepEqual(steps.map((s) => s.moment), [...steps.map((s) => s.moment)].sort((a, b) => a - b));
    for (const s of steps) assert.ok(s.moment >= 0 && s.moment <= last && s.text && s.artifacts.length);
  }
  const file = planningFiles.find((f) => f.path === "docs/roadmap.md")!;
  assert.match(file.content(4), /F05 Member history, depends on F01/);
  assert.match(file.content(5), /F05 Member history, depends on F02/, "a file shows its content at the moment it is opened");
});
