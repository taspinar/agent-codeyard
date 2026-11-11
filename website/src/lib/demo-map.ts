// The geometry of the demo's route map (#370), in two orientations drawn from
// the same stations, lanes, stages and ways back of src/lib/demo.ts:
// horizontal for wide screens, vertical (top to bottom) for narrow ones.
// WorkflowDemo.astro draws each layout with one template; src/lib/demo-view.ts
// marks both, so the two maps show the same state at every moment.
// The extension lets node --test load this module directly, as Vite does.
import { lanes, loops, milestones, stages, type LaneKey, type Stage } from "./demo.ts";

export type Orientation = "horizontal" | "vertical";
export interface Label { x: number; y: number; anchor: "start" | "middle" | "end" }
export interface Rect { x: number; y: number; width: number; height: number }
export interface Symbol { x: number; y: number; r: number; gate: boolean }

export interface MapLayout {
  orientation: Orientation;
  width: number;
  height: number;
  tracks: { key: string; d: string }[];
  loops: { key: string; d: string; head: string; note: Label; lines: string[] }[];
  stops: { key: string; sym: Symbol; hit: Rect; name: Label; sub: Label }[];
  lanes: { key: LaneKey; hits: Rect[]; label: Label; tag?: Label; stages: (Symbol & { key: Stage })[] }[];
  main: { sym: Symbol; label: Label };
  columns: (Label & { text: string })[];
}

const path = (points: [number, number][]) => points.map(([x, y], i) => `${i ? "L" : "M"}${x} ${y}`).join(" ");

/** Splits a note into lines of at most `width` characters, at spaces. */
export function wrap(text: string, width: number): string[] {
  const lines: string[] = [];
  for (const word of text.split(" ")) {
    const line = lines.at(-1);
    if (line !== undefined && line.length + 1 + word.length <= width) lines[lines.length - 1] = `${line} ${word}`;
    else lines.push(word);
  }
  return lines;
}

/** The map as wide screens show it: the planning line on the middle row, the lanes to the right. */
function horizontal(): MapLayout {
  const trunk = 118;
  const laneY = [56, 118, 180];
  const stopX = [40, 150, 260, 370, 480];
  const split = 520;
  const laneStart = 582;
  const stageX = [660, 760, 860, 960, 1060, 1160];
  const mainX = 1236;
  const xOf = Object.fromEntries(stages.map((s, i) => [s.key, stageX[i]]));
  const off = (i: number) => Math.abs(laneY[i] - trunk);
  const loopTop = laneY[0] - 26;
  return {
    orientation: "horizontal",
    width: 1280,
    height: 236,
    tracks: [
      ...stopX.slice(0, -1).map((x, i) => ({ key: `t${i}`, d: `M${x} ${trunk} H${stopX[i + 1]}` })),
      ...lanes.flatMap((l, i) => [
        { key: `branch-${l.key}`, d: `M${stopX[4]} ${trunk} H${split} L${split + off(i)} ${laneY[i]} H${laneStart}` },
        { key: `${l.key}-build`, d: `M${laneStart} ${laneY[i]} H${stageX[0]}` },
        ...stages.slice(1).map((s, j) => ({ key: `${l.key}-${s.key}`, d: `M${stageX[j]} ${laneY[i]} H${stageX[j + 1]}` })),
        { key: `${l.key}-main`, d: `M${stageX[5]} ${laneY[i]} L${stageX[5] + off(i)} ${trunk} H${mainX}` },
      ]),
    ],
    loops: loops.map((loop) => ({
      key: loop.key,
      d: `M${xOf[loop.from]} ${laneY[0] - 12} V${loopTop} H${xOf[loop.to]} V${laneY[0] - 14}`,
      head: `M${xOf[loop.to] - 6} ${laneY[0] - 22} L${xOf[loop.to]} ${laneY[0] - 13} L${xOf[loop.to] + 6} ${laneY[0] - 22}`,
      note: { x: (xOf[loop.from] + xOf[loop.to]) / 2, y: loopTop - 8, anchor: "middle" },
      lines: [loop.note],
    })),
    stops: milestones.map((m, i) => ({
      key: m.key,
      sym: { x: stopX[i], y: trunk, r: 10, gate: "owner" in m },
      hit: { x: stopX[i] - 50, y: trunk - 20, width: 100, height: 70 },
      name: { x: stopX[i], y: trunk + 32, anchor: "middle" },
      sub: { x: stopX[i], y: trunk + 49, anchor: "middle" },
    })),
    lanes: lanes.map((l, i) => ({
      key: l.key,
      hits: [{ x: laneStart + 6, y: laneY[i] - 28, width: stageX[5] - laneStart + 14, height: 56 }],
      label: { x: laneStart + 14, y: laneY[i] + 25, anchor: "start" },
      stages: stages.map((s, j) => ({ key: s.key, x: stageX[j], y: laneY[i], r: 8, gate: !!s.owner })),
    })),
    main: { sym: { x: mainX, y: trunk, r: 10, gate: false }, label: { x: mainX, y: trunk + 32, anchor: "middle" } },
    columns: stages.map((s, j) => ({ text: s.name, x: stageX[j], y: 228, anchor: "middle" })),
  };
}

/**
 * The map as narrow screens show it, top to bottom: the planning line on the
 * middle column with its labels to the left, the three lanes side by side
 * with the stage names to their right and the ways back to the left of the
 * first lane, then main, and under it each lane's name and state in words.
 */
function vertical(): MapLayout {
  const width = 336;
  const trunk = 190;
  const laneX = [120, 190, 260];
  const stopY = [24, 84, 144, 204, 264];
  const split = 290;
  const off = (i: number) => Math.abs(laneX[i] - trunk);
  const laneStart = split + off(0);
  const stageY = [392, 447, 502, 557, 612, 667];
  const join = stageY[5] + off(0);
  const mainY = join + 22;
  const statusY = [mainY + 44, mainY + 68, mainY + 92];
  const yOf = Object.fromEntries(stages.map((s, i) => [s.key, stageY[i]]));
  const loopX = laneX[0] - 26;
  return {
    orientation: "vertical",
    width,
    height: statusY[2] + 14,
    tracks: [
      ...stopY.slice(0, -1).map((y, i) => ({ key: `t${i}`, d: `M${trunk} ${y} V${stopY[i + 1]}` })),
      ...lanes.flatMap((l, i) => [
        { key: `branch-${l.key}`, d: path([[trunk, stopY[4]], [trunk, split], [laneX[i], split + off(i)], [laneX[i], laneStart]]) },
        { key: `${l.key}-build`, d: `M${laneX[i]} ${laneStart} V${stageY[0]}` },
        ...stages.slice(1).map((s, j) => ({ key: `${l.key}-${s.key}`, d: `M${laneX[i]} ${stageY[j]} V${stageY[j + 1]}` })),
        { key: `${l.key}-main`, d: path([[laneX[i], stageY[5]], [trunk, stageY[5] + off(i)], [trunk, mainY]]) },
      ]),
    ],
    loops: loops.map((loop) => {
      const lines = wrap(loop.note, 12);
      const from = yOf[loop.from];
      const to = yOf[loop.to];
      return {
        key: loop.key,
        d: `M${laneX[0] - 12} ${from} H${loopX} V${to} H${laneX[0] - 14}`,
        head: `M${laneX[0] - 22} ${to - 6} L${laneX[0] - 13} ${to} L${laneX[0] - 22} ${to + 6}`,
        note: { x: loopX - 8, y: (from + to) / 2 - ((lines.length - 1) * 16) / 2 + 4, anchor: "end" },
        lines,
      };
    }),
    stops: milestones.map((m, i) => ({
      key: m.key,
      sym: { x: trunk, y: stopY[i], r: 10, gate: "owner" in m },
      hit: { x: 20, y: stopY[i] - 26, width: trunk - 6, height: 52 },
      name: { x: trunk - 22, y: stopY[i] - 2, anchor: "end" },
      sub: { x: trunk - 22, y: stopY[i] + 15, anchor: "end" },
    })),
    lanes: lanes.map((l, i) => ({
      key: l.key,
      hits: [
        { x: laneX[i] - 30, y: laneStart - 4, width: 60, height: stageY[5] - laneStart + 26 },
        { x: 0, y: statusY[i] - 17, width, height: 24 },
      ],
      label: { x: 2, y: statusY[i], anchor: "start" },
      tag: { x: laneX[i] + 12, y: laneStart + 12, anchor: "start" },
      stages: stages.map((s, j) => ({ key: s.key, x: laneX[i], y: stageY[j], r: 8, gate: !!s.owner })),
    })),
    main: { sym: { x: trunk, y: mainY, r: 10, gate: false }, label: { x: trunk - 22, y: mainY + 5, anchor: "end" } },
    columns: stages.map((s, j) => ({ text: s.name, x: laneX[2] + 18, y: stageY[j] + 5, anchor: "start" })),
  };
}

export const mapLayouts: MapLayout[] = [horizontal(), vertical()];
