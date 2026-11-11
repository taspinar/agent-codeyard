// Tests of the two layouts of the demo's route map (#370): the vertical one
// of narrow screens draws the same route as the horizontal one, from the same
// data, and stays within its own width. Run by check.sh --build.
import { test } from "node:test";
import assert from "node:assert/strict";
import { lanes, loops, milestones, stages } from "./demo.ts";
import { mapLayouts, wrap, type MapLayout } from "./demo-map.ts";

const [horizontal, vertical] = mapLayouts;
const keys = (map: MapLayout) => ({
  tracks: map.tracks.map((t) => t.key),
  loops: map.loops.map((l) => l.key),
  stops: map.stops.map((s) => [s.key, s.sym.gate]),
  lanes: map.lanes.map((l) => [l.key, l.stages.map((s) => [s.key, s.gate])]),
  columns: map.columns.map((c) => c.text),
});

test("both layouts draw every station, lane, stage, track and way back of the data, and nothing else", () => {
  assert.deepEqual([horizontal.orientation, vertical.orientation], ["horizontal", "vertical"]);
  assert.deepEqual(keys(vertical), keys(horizontal));
  assert.deepEqual(keys(vertical).stops, milestones.map((m) => [m.key, "owner" in m]));
  assert.deepEqual(keys(vertical).lanes, lanes.map((l) => [l.key, stages.map((s) => [s.key, !!s.owner])]));
  assert.deepEqual(keys(vertical).loops, loops.map((l) => l.key));
  // Every track the view marks: the planning line, and per lane its branch, the way into each stage and its join to main.
  assert.equal(vertical.tracks.length, milestones.length - 1 + lanes.length * (stages.length + 2));
});

test("the vertical layout runs top to bottom: planning, the lanes side by side, then main", () => {
  const ys = vertical.stops.map((s) => s.sym.y);
  assert.deepEqual(ys, [...ys].sort((a, b) => a - b), "the planning stations from top to bottom");
  assert.ok(vertical.stops.every((s) => s.sym.x === vertical.stops[0].sym.x), "the planning line is one column");
  for (const lane of vertical.lanes) {
    assert.ok(lane.stages.every((s) => s.x === lane.stages[0].x), `${lane.key} is one column`);
    assert.ok(lane.stages[0].y > ys.at(-1)!, `${lane.key} starts below Issues`);
    assert.ok(lane.stages.at(-1)!.y < vertical.main.sym.y, `${lane.key} merges above main`);
  }
  assert.equal(new Set(vertical.lanes.map((l) => l.stages[0].x)).size, lanes.length, "the lanes side by side");
});

test("the vertical layout keeps its symbols, its hit areas and its labels' anchors within its width", () => {
  const xs = [
    ...vertical.stops.flatMap((s) => [s.sym.x - s.sym.r, s.sym.x + s.sym.r, s.hit.x, s.hit.x + s.hit.width, s.name.x, s.sub.x]),
    ...vertical.lanes.flatMap((l) => [...l.stages.flatMap((s) => [s.x - s.r, s.x + s.r]), ...l.hits.flatMap((h) => [h.x, h.x + h.width]), l.label.x]),
    ...vertical.columns.map((c) => c.x),
  ];
  assert.ok(Math.min(...xs) >= 0 && Math.max(...xs) <= vertical.width, JSON.stringify([Math.min(...xs), Math.max(...xs)]));
  assert.ok(vertical.width < 400, "drawn for a phone, not scaled down from the desktop map");
});

test("a note of a way back wraps at spaces into short lines", () => {
  assert.deepEqual(wrap("check fails: repair, verify again", 12), ["check fails:", "repair,", "verify again"]);
  assert.deepEqual(wrap("finding: fix, verify, review again", 12), ["finding:", "fix, verify,", "review again"]);
  assert.deepEqual(horizontal.loops.map((l) => l.lines), loops.map((l) => [l.note]));
});
