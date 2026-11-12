// The interactive workflow of the home page (#370): an illustrative gym
// project from the idea to three reviewed pull requests, one moment at a
// time. This file holds the data and the step logic, without the page:
// src/lib/demo-view.ts draws it, src/components/WorkflowDemo.astro is its
// markup and src/styles/demo.css its styles. The scenario is the gym of #328;
// the gym, the messages, the file contents and the Issue and pull request
// numbers are made up. The script and file names are those of the workflow
// (docs/development.md); Issues and pull requests are GitHub objects, and the
// files under .agents/ that Git ignores are local work files of a worktree.

export type LaneKey = "f02" | "f03" | "f04";
export type Stage = "build" | "verify" | "review" | "triage" | "pr" | "merge";
export type TerminalKey = "planning" | LaneKey;

/** One moment of the run: what happens, who acts. */
export interface Moment { title: string; who: string; text: string }

export const moments: Moment[] = [
  { title: "You describe the idea", who: "You", text: "A gym wants an app. Trainers record attendance for their classes; members see their own training history. start-planning.sh keeps your description as you wrote it." },
  { title: "Project Grill asks what the idea leaves open", who: "Project Grill, an agent", text: "It asks only the questions that change the product: who may correct attendance, who sees which history. Your answers become the draft requirements." },
  { title: "You approve the requirements", who: "You", text: "The requirements count as approved only after you confirm them. The planning starts from them." },
  { title: "The planner writes the plan", who: "The planner, an agent", text: "From the approved requirements it writes the architecture, a roadmap of features F01 to F05 and one design decision." },
  { title: "Another agent reviews the plan", who: "The planning reviewer, an agent of another provider", text: "It reads the plan without changing it and finds a gap: member history (F05) does not say it depends on attendance (F02)." },
  { title: "The planner revises the plan", who: "The planner, after your approval", text: "It adopts the finding, you approve the decision, and the roadmap now says that F05 depends on F02. The earlier review is stale." },
  { title: "The second review passes", who: "The planning reviewer", text: "Round 2 reviews the revised plan and finds nothing more." },
  { title: "You approve the plan", who: "You", text: "finish-planning.sh records your approval in PLANNING_APPROVAL.md. You merge the planning pull request, and the plan is on main." },
  { title: "Roadmap features become Issues", who: "A script", text: "Three independent features each get a GitHub Issue: #41, #42 and #43. F01 is already on main; F05 waits for F02." },
  { title: "Three features start, each in its own worktree", who: "You start three runs", text: "Each run-feature.sh gets its own branch and working copy. They are separate runs side by side, not a batch." },
  { title: "The implementers build", who: "Three implementers, agents", text: "Each writes its module and its tests in its own worktree. Nothing reaches main because an agent finished." },
  { title: "A check fails in one feature", who: "A script", text: "verify.sh finds that in #41 a member could read another member's history. The checks of #42 and #43 pass." },
  { title: "The implementer repairs it", who: "The implementer of #41", text: "It adds the member check, and the checks run again and pass. #42 and #43 pass their reviews." },
  { title: "The review finds a problem", who: "The reviewer of #41, an agent of another provider", text: "A correction overwrites the original entry, while the requirements keep it visible as corrected. A major finding." },
  { title: "Triage, fix, check and review again", who: "The triage, the implementer and the reviewer", text: "The finding is to be fixed now. After the fix the checks run on the changed content, and a new review round passes. #42 and #43 are committed." },
  { title: "Three pull requests", who: "A script, then CI", text: "Each feature is opened as its own pull request: #61, #62 and #63. No script merges." },
  { title: "You merge pull request #61", who: "You", text: "You read the change, its checks and its review, and merge it into main. #62 and #63 wait for you." },
  { title: "You merge pull request #62", who: "You", text: "You merge the timetable separately, on the main that now holds attendance. #63 waits." },
  { title: "You merge pull request #63", who: "You", text: "The last feature is merged. Three reviewed pull requests, each merged by you, one at a time." },
];

export const last = moments.length - 1;

/** The stations of the planning line, before the features split. */
export const milestones = [
  { key: "idea", name: "Idea", sub: "you describe", moment: 0 },
  { key: "grill", name: "Project Grill", sub: "questions", moment: 1 },
  { key: "plan", name: "Plan", sub: "details", moment: 3, details: true },
  { key: "approve", name: "Approve", sub: "you decide", moment: 7, owner: true },
  { key: "issues", name: "Issues", sub: "#41 – #43", moment: 8 },
] as const;

/** The three features: each its own Issue, worktree and pull request, merged in turn. */
export const lanes = [
  { key: "f02", id: "F02", name: "Attendance", issue: 41, pr: 61, slug: "trainer-attendance", mergeAt: 16 },
  { key: "f03", id: "F03", name: "Timetable", issue: 42, pr: 62, slug: "class-timetable", mergeAt: 17 },
  { key: "f04", id: "F04", name: "Preferences", issue: 43, pr: 63, slug: "notification-preferences", mergeAt: 18 },
] as const satisfies readonly { key: LaneKey; id: string; name: string; issue: number; pr: number; slug: string; mergeAt: number }[];
export type Lane = (typeof lanes)[number];

export const stages: { key: Stage; name: string; owner?: boolean }[] = [
  { key: "build", name: "Build" },
  { key: "verify", name: "Verify" },
  { key: "review", name: "Review" },
  { key: "triage", name: "Triage" },
  { key: "pr", name: "PR" },
  { key: "merge", name: "Merge", owner: true },
];

/** The moment the features start; before it there is one planning terminal. */
export const featuresFrom = 9;
/** The moment every feature has its pull request. */
export const prsAt = 15;

export const clamp = (moment: number) => Math.max(0, Math.min(last, Math.round(moment) || 0));

/** How far the planning line is: the index of the last milestone reached. */
export function progress(moment: number): number {
  return moment === 0 ? 0 : moment <= 2 ? 1 : moment <= 6 ? 2 : moment === 7 ? 3 : 4;
}

/**
 * The moment each lane reaches each stage. The attendance feature fails its
 * check first (verify at 11, repaired at 12) and gets a review finding (13,
 * fixed and reviewed again at 14); the other two pass at once.
 */
const reachedAt: Record<LaneKey, Record<Stage, number>> = {
  f02: { build: 10, verify: 11, review: 13, triage: 14, pr: 15, merge: 16 },
  f03: { build: 10, verify: 11, review: 12, triage: 13, pr: 15, merge: 17 },
  f04: { build: 10, verify: 11, review: 12, triage: 13, pr: 15, merge: 18 },
};

const statusOf: Record<LaneKey, Record<number, string>> = {
  f02: { 9: "worktree created", 10: "building", 11: "check failed", 12: "repaired, checks pass", 13: "review finding", 14: "fixed, review passed", 15: "PR #61 open" },
  f03: { 9: "worktree created", 10: "building", 11: "checks pass", 12: "review passed", 13: "nothing to triage", 14: "committed", 15: "PR #62 open" },
  f04: { 9: "worktree created", 10: "building", 11: "checks pass", 12: "review passed", 13: "nothing to triage", 14: "committed", 15: "PR #63 open" },
};

export interface LaneState {
  status: string;
  reached: Record<Stage, boolean>;
  /** The stage where something happens at this moment, if any. */
  current: Stage | null;
  merged: boolean;
}

export function laneState(moment: number, key: LaneKey): LaneState {
  const lane = lanes.find((l) => l.key === key)!;
  const at = reachedAt[key];
  const reached = Object.fromEntries(stages.map((s) => [s.key, moment >= at[s.key]])) as Record<Stage, boolean>;
  const merged = moment >= lane.mergeAt;
  let current: Stage | null = null;
  for (const s of stages) if (at[s.key] === moment) current = s.key;
  // The repair of a failed check happens at Build and is checked at Verify again.
  if (key === "f02" && moment === 12) current = "verify";
  const status = moment < featuresFrom ? "not started" : merged ? `merged, PR #${lane.pr}` : moment > prsAt ? `PR #${lane.pr} waits for you` : statusOf[key][moment];
  return { status, reached, current, merged };
}

/** A way back on a lane: a failed check to Build, or a review finding through Triage to a fix. */
export interface Loop { key: "repair" | "findings"; lane: LaneKey; from: Stage; to: Stage; note: string }

export const loops: Loop[] = [
  { key: "repair", lane: "f02", from: "verify", to: "build", note: "check fails: repair, verify again" },
  { key: "findings", lane: "f02", from: "triage", to: "build", note: "finding: fix, verify, review again" },
];

/** The loop the route takes at this moment, if any. */
export function loopAt(moment: number): Loop | null {
  if (moment === 11 || moment === 12) return loops[0];
  if (moment === 13 || moment === 14) return loops[1];
  return null;
}

/** The lane merged at this moment: at most one, at its owner diamond. */
export function mergeAt(moment: number): Lane | null {
  return lanes.find((l) => l.mergeAt === moment) ?? null;
}

// The terminals. A line starting with "$ " is a command, "# " a comment,
// "! " a failure or finding, "> " your answer; the rest is output.
const planningLog: string[][] = [
  ["$ ./scripts/start-planning.sh --description ~/notes/gym.md", "Branch planning/project-bootstrap, worktree ../gym-app-planning-project-bootstrap", "Saved docs/PROJECT_DESCRIPTION.md"],
  ["Project Grill: Who may record or correct attendance?", "> Trainers, for their own classes.", "Project Grill: May a member see another member's history?", "> No, only their own.", "Project Grill: What happens to a corrected entry?", "> The original stays visible as corrected.", "Drafted docs/PROJECT_REQUIREMENTS.md"],
  ["Approve these requirements? [y/N]", "> y", "Requirements approved", "Starting the project planner"],
  ["Planner: wrote docs/architecture.md", "Planner: wrote docs/roadmap.md (F01 to F05)", "Planner: wrote docs/decisions/0001-access-control.md"],
  ["$ ./scripts/review-planning.sh", "! M1 major: F05 member history does not depend on F02", "Verdict: CHANGES REQUIRED", "# The report is a local work file that Git ignores."],
  ["$ ./scripts/revise-planning.sh --review .agents/reviews/planning-project-bootstrap-review-01.json", "M1: ADOPT", "Record these decisions? [y/N]", "> y", "Updated docs/roadmap.md: F05 depends on F02", "# The review is stale now: review again."],
  ["$ ./scripts/review-planning.sh", "Round 2: no findings. Verdict: PASS"],
  ["$ ./scripts/finish-planning.sh", "Approve the planning? [y/N]", "> y", "Wrote docs/PLANNING_APPROVAL.md", "# On GitHub, you merge the planning pull request."],
  ["$ ./scripts/create-feature-issue.sh F02", "Created Issue #41: Trainer attendance", "$ ./scripts/create-feature-issue.sh F03", "Created Issue #42: Class timetable", "$ ./scripts/create-feature-issue.sh F04", "Created Issue #43: Notification preferences"],
];

const featureLog: Record<number, Partial<Record<LaneKey, string[]>>> = {
  9: Object.fromEntries(lanes.map((l) => [l.key, [`$ ./scripts/run-feature.sh ${l.issue}`, `Worktree ../gym-app-feature-${l.issue}-${l.slug}`]])),
  10: {
    f02: ["Implementer: wrote src/attendance/record.ts", "Implementer: wrote tests/attendance.test.ts"],
    f03: ["Implementer: wrote src/schedule/timetable.ts", "Implementer: wrote tests/schedule.test.ts"],
    f04: ["Implementer: wrote src/preferences/notifications.ts", "Implementer: wrote tests/preferences.test.ts"],
  },
  11: {
    f02: ["verify.sh: running the checks", "! FAIL: a member who requests another member's history is refused"],
    f03: ["verify.sh: all checks pass"],
    f04: ["verify.sh: all checks pass"],
  },
  12: {
    f02: ["Implementer: added the member check to getHistory", "verify.sh: all checks pass"],
    f03: ["review-feature.sh: round 1, PASS"],
    f04: ["review-feature.sh: round 1, PASS"],
  },
  13: {
    f02: ["review-feature.sh: round 1", "! M1 major: a correction overwrites the original entry"],
    f03: ["# No findings, nothing to triage."],
    f04: ["# No findings, nothing to triage."],
  },
  14: {
    f02: ["triage-review.sh: M1, FIX_NOW", "apply-triage.sh: keep the original, add the correction", "verify.sh: all checks pass", "review-feature.sh: round 2, PASS"],
    f03: ["finish-feature.sh: committed after verification"],
    f04: ["finish-feature.sh: committed after verification"],
  },
  15: {
    f02: ["finish-feature.sh: committed after verification", "publish-feature.sh: pull request #61"],
    f03: ["publish-feature.sh: pull request #62"],
    f04: ["publish-feature.sh: pull request #63"],
  },
  16: { f02: ["# On GitHub, you merged pull request #61."], f03: ["# Pull request #62 waits for you."], f04: ["# Pull request #63 waits for you."] },
  17: { f03: ["# On GitHub, you merged pull request #62."], f04: ["# Pull request #63 waits for you."] },
  18: { f04: ["# On GitHub, you merged pull request #63."] },
};

/** The lines of one moment in a terminal, under the title of that moment. */
export interface Entry { moment: number; title: string; lines: string[] }

/** What a terminal shows at a moment: every entry so far, the earlier ones kept. */
export function terminalLog(moment: number, key: TerminalKey): Entry[] {
  const entries: Entry[] = [];
  for (let n = 0; n <= moment; n++) {
    const lines = key === "planning" ? planningLog[n] : featureLog[n]?.[key];
    if (lines) entries.push({ moment: n, title: moments[n].title, lines });
  }
  return entries;
}

export interface Terminal { key: TerminalKey; title: string; cwd: string; active: boolean; entries: Entry[] }

/** The terminals at a moment: the planning terminal, then one per feature, the selected one active. */
export function terminals(moment: number, selected: LaneKey): Terminal[] {
  if (moment < featuresFrom) {
    return [{ key: "planning", title: "Planning", cwd: "../gym-app-planning-project-bootstrap", active: true, entries: terminalLog(moment, "planning") }];
  }
  return lanes.map((l) => ({ key: l.key, title: `${l.name} #${l.issue}`, cwd: `../gym-app-feature-${l.issue}-${l.slug}`, active: l.key === selected, entries: terminalLog(moment, l.key) }));
}

/** The kind of a terminal line and its text, without the marker of a command or comment. */
export function lineKind(line: string): { kind: "command" | "comment" | "problem" | "answer" | "output"; text: string } {
  if (line.startsWith("$ ")) return { kind: "command", text: line.slice(2) };
  if (line.startsWith("# ")) return { kind: "comment", text: line };
  if (line.startsWith("! ")) return { kind: "problem", text: line };
  if (line.startsWith("> ")) return { kind: "answer", text: line };
  return { kind: "output", text: line };
}

// The files. A tracked file is committed; a local one is a work file under
// .agents/ that Git ignores and that is never merged.
export interface DemoFile {
  path: string;
  from: number;
  what: string;
  local?: boolean;
  /** Only while the planning is not merged: the planning worktree's own work files. */
  until?: number;
  content: (moment: number) => string;
}

const file = (path: string, from: number, what: string, content: DemoFile["content"], extra: Partial<DemoFile> = {}): DemoFile => ({ path, from, what, content, ...extra });

export const planningFiles: DemoFile[] = [
  file("docs/PROJECT_DESCRIPTION.md", 0, "Your description of the idea, kept as you wrote it.", () => "# Gym member app\n\nAn app for our gym. Trainers record who attended\ntheir classes. Members see their own training\nhistory.\n\nKeep the first version simple, and keep\nmembers' data private."),
  file("docs/PROJECT_REQUIREMENTS.md", 1, "The requirements from Project Grill and your answers.", (m) => `# Project requirements\n\nStatus: ${m >= 2 ? "Approved" : "Draft"}\n\n## Users\n- Trainers\n- Members\n\n## Rules\n- Trainers record and correct attendance\n  for their own classes only.\n- A member sees only their own history.\n- A correction keeps the original entry\n  visible as corrected.`),
  file("docs/architecture.md", 3, "The architecture, from the planner.", () => "# Architecture\n\nA web app, a service API and a database.\n\n## Modules\n- auth/         roles and sign-in (F01)\n- attendance/   records and corrections\n- schedule/     class timetable\n- preferences/  notification settings\n- history/      a member's own history\n\nattendance/, schedule/ and preferences/ are\nseparate modules, so their features can be\nbuilt side by side."),
  file("docs/roadmap.md", 3, "The roadmap: features with stable IDs and their dependencies.", (m) => `# Roadmap\n\n- F01 Roles and sign-in (on main)\n- F02 Trainer attendance, depends on F01\n- F03 Class timetable, depends on F01\n- F04 Notification preferences, depends on F01\n- F05 Member history, ${m >= 5 ? "depends on F02" : "depends on F01"}`),
  file("docs/decisions/0001-access-control.md", 3, "A design decision of the plan.", () => "# 0001 Access control\n\nStatus: Accepted\n\n## Decision\nRoles, with an ownership check in the\nservice layer.\n\n## Why\nOnly the trainer of a class edits its\nattendance; a member reads only their own data."),
  file(".agents/reviews/planning-project-bootstrap-review-01.md", 4, "The report of the first planning review: a local work file.", () => "# Planning review, round 1\n\nVerdict: CHANGES REQUIRED\n\n## M1, major\nF05 (member history) needs the attendance\nrecords of F02, but the roadmap does not\nsay so.", { local: true, until: 7 }),
  file(".agents/reviews/planning-project-bootstrap-review-01-revision.md", 5, "The decision on each finding of round 1: a local work file.", () => "# Revision of round 1\n\nM1: ADOPT\nMember history needs attendance data.\n\nChanged: docs/roadmap.md, F05 depends on F02.", { local: true, until: 7 }),
  file(".agents/reviews/planning-project-bootstrap-review-02.md", 6, "The report of the second planning review: a local work file.", () => "# Planning review, round 2\n\nVerdict: PASS\n\nNo findings.", { local: true, until: 7 }),
  file("docs/PLANNING_APPROVAL.md", 7, "Your approval of the reviewed planning documents.", () => "# Planning approval\n\nApproved by the owner.\nBranch: planning/project-bootstrap\nReview rounds: 2, the last one PASS\n\nFingerprint of the planning documents:\n(recorded by finish-planning.sh)"),
];

export const featureFiles: Record<LaneKey, DemoFile[]> = {
  f02: [
    file("src/attendance/record.ts", 10, "The attendance module.", (m) => m < 12
      ? "export function getHistory(user, memberId) {\n  return db.attendance.byMember(memberId);\n}\n\nexport function correct(entry, status) {\n  return db.attendance.update(entry.id, status);\n}"
      : m < 14
        ? "export function getHistory(user, memberId) {\n  if (user.memberId !== memberId) throw forbidden();\n  return db.attendance.byMember(memberId);\n}\n\nexport function correct(entry, status) {\n  return db.attendance.update(entry.id, status);\n}"
        : "export function getHistory(user, memberId) {\n  if (user.memberId !== memberId) throw forbidden();\n  return db.attendance.byMember(memberId);\n}\n\nexport function correct(entry, status) {\n  // Keep the original; add the correction.\n  return db.attendance.addCorrection(entry.id, status);\n}"),
    file("tests/attendance.test.ts", 10, "The tests of the attendance module.", (m) => `test("a member cannot read another member's history", ...);${m >= 14 ? '\ntest("a correction keeps the original entry", ...);' : ""}`),
    file(".agents/handoffs/41.md", 9, "The implementer's note for a session that continues the work: a local work file.", (m) => `# Handoff #41\n\n${m < 10 ? "Reading Issue #41." : m < 11 ? "Building the attendance module." : m === 11 ? "The privacy check failed: repair getHistory." : m < 14 ? "Checks pass; waiting for the review." : "Review passed; ready to finish."}`, { local: true }),
    file(".agents/verification/passed", 12, "The record of the last passed verification of this worktree: a local work file.", () => "The checks passed for exactly this content.", { local: true }),
    file(".agents/reviews/feature-41-trainer-attendance-review-01.md", 13, "The report of review round 1: a local work file.", () => "# Review of #41, round 1\n\nVerdict: CHANGES REQUIRED\n\n## M1, major\nA correction overwrites the original\nentry; the requirements keep it visible\nas corrected.", { local: true }),
    file(".agents/triage/feature-41-trainer-attendance-review-01-triage.md", 14, "The decision on each finding: a local work file, published on Issue #41.", () => "# Triage of #41, round 1\n\nM1: FIX_NOW\nThe requirements ask for it.", { local: true }),
  ],
  f03: [
    file("src/schedule/timetable.ts", 10, "The timetable module, in its own worktree.", () => "export function classesOn(day) {\n  return db.classes.find({ day });\n}"),
    file("tests/schedule.test.ts", 10, "The tests of the timetable module.", () => 'test("lists the classes of a day", ...);'),
    file(".agents/handoffs/42.md", 9, "The implementer's note: a local work file.", (m) => `# Handoff #42\n\n${m < 10 ? "Reading Issue #42." : m < 12 ? "Building the timetable." : "Review passed; ready to finish."}`, { local: true }),
    file(".agents/verification/passed", 11, "The record of the last passed verification of this worktree: a local work file.", () => "The checks passed for exactly this content.", { local: true }),
  ],
  f04: [
    file("src/preferences/notifications.ts", 10, "The preferences module, in its own worktree.", () => "export function savePreferences(memberId, choice) {\n  return db.preferences.upsert({ memberId, ...choice });\n}"),
    file("tests/preferences.test.ts", 10, "The tests of the preferences module.", () => 'test("stores a member\'s choice", ...);'),
    file(".agents/handoffs/43.md", 9, "The implementer's note: a local work file.", (m) => `# Handoff #43\n\n${m < 10 ? "Reading Issue #43." : m < 12 ? "Building the preferences." : "Review passed; ready to finish."}`, { local: true }),
    file(".agents/verification/passed", 11, "The record of the last passed verification of this worktree: a local work file.", () => "The checks passed for exactly this content.", { local: true }),
  ],
};

/** An item of the tree: a file of a branch or worktree, or an object on GitHub. */
export type TreeItem =
  | { kind: "file"; file: DemoFile; lane?: LaneKey; isNew: boolean }
  | { kind: "github"; label: string; state: string; isNew: boolean };

export interface TreeGroup { key: string; title: string; where: string; items: TreeItem[] }

const fileItem = (f: DemoFile, moment: number, lane?: LaneKey): TreeItem => ({ kind: "file", file: f, lane, isNew: f.from === moment });

/**
 * The repository at a moment. The planning documents are in the planning
 * worktree until you merge the planning, then on main for good; a feature's
 * committed files reach main when its pull request is merged, its local work
 * files never do. Issues and pull requests are listed as GitHub objects.
 */
export function tree(moment: number): TreeGroup[] {
  const groups: TreeGroup[] = [];
  const docs = planningFiles.filter((f) => f.from <= moment && !f.local);
  if (moment < 7) {
    groups.push({ key: "planning", title: "Planning worktree", where: "planning/project-bootstrap", items: planningFiles.filter((f) => f.from <= moment && (f.until ?? Infinity) > moment).map((f) => fileItem(f, moment)) });
  } else {
    const merged = lanes.filter((l) => moment >= l.mergeAt).flatMap((l) => featureFiles[l.key].filter((f) => !f.local).map((f) => ({ kind: "file" as const, file: f, lane: l.key, isNew: l.mergeAt === moment })));
    groups.push({ key: "main", title: "main", where: "the default branch", items: [...docs.map((f) => fileItem(f, moment)), ...merged] });
  }
  if (moment >= 7) {
    const github: TreeItem[] = [{ kind: "github", label: "Planning pull request", state: "merged by you", isNew: moment === 7 }];
    if (moment >= 8) for (const l of lanes) github.push({ kind: "github", label: `Issue #${l.issue} ${l.name}`, state: moment >= l.mergeAt ? "closed" : "open", isNew: moment === 8 });
    if (moment >= prsAt) for (const l of lanes) github.push({ kind: "github", label: `Pull request #${l.pr}`, state: moment >= l.mergeAt ? "merged by you" : "open, waits for you", isNew: moment === prsAt || moment === l.mergeAt });
    groups.push({ key: "github", title: "On GitHub", where: "Issues and pull requests, not files", items: github });
  }
  if (moment >= featuresFrom) {
    for (const l of lanes) {
      groups.push({ key: l.key, title: `Worktree #${l.issue}`, where: `feature/${l.issue}-${l.slug}`, items: featureFiles[l.key].filter((f) => f.from <= moment).map((f) => fileItem(f, moment, l.key)) });
    }
  }
  return groups;
}

/** A step inside the Plan station or inside a feature, for its details dialog. */
export interface Substep { name: string; moment: number; text: string; artifacts: string[] }

export const planSteps: Substep[] = [
  { name: "Draft the plan", moment: 3, text: "The planner turns the approved requirements into the architecture, a roadmap with stable feature IDs, and the design decisions it needs.", artifacts: ["docs/architecture.md", "docs/roadmap.md", "docs/decisions/"] },
  { name: "Review the plan", moment: 4, text: "An agent of another provider reads the plan without changing it. Here it finds a dependency the roadmap does not state.", artifacts: ["review-planning.sh", ".agents/reviews/ (local)"] },
  { name: "Revise the plan", moment: 5, text: "The planner decides on each finding, you approve the decisions, and it changes the plan. The earlier review is then stale.", artifacts: ["revise-planning.sh", "docs/roadmap.md"] },
  { name: "Review again", moment: 6, text: "A new round reviews the revised plan. When it passes, the approval is yours.", artifacts: ["review-planning.sh", ".agents/reviews/ (local)"] },
];

export const featureSteps: Substep[] = [
  { name: "Issue and worktree", moment: 9, text: "Each feature of the roadmap gets a GitHub Issue, a branch and a working copy of its own. Three features are three separate runs.", artifacts: ["create-feature-issue.sh", "run-feature.sh", "feature/<issue>-<slug>"] },
  { name: "Build", moment: 10, text: "An implementer writes the code and its tests within the scope of the Issue, and keeps a note for a session that continues.", artifacts: ["src/", "tests/", ".agents/handoffs/ (local)"] },
  { name: "Verify", moment: 11, text: "The project's checks run before any review. A failed check goes back to Build and is verified again.", artifacts: ["verify.sh", ".agents/verification/ (local)"] },
  { name: "Review", moment: 13, text: "An agent of another provider reviews the change without editing it, against the Issue and the requirements.", artifacts: ["review-feature.sh", ".agents/reviews/ (local)"] },
  { name: "Triage and fix", moment: 14, text: "Each finding is fixed now, deferred or accepted with a reason. A fix is verified and reviewed again.", artifacts: ["triage-review.sh", "apply-triage.sh", ".agents/triage/ (local)"] },
  { name: "Pull request", moment: 15, text: "The feature is committed only with passed checks and a current review, and opened as its own pull request.", artifacts: ["finish-feature.sh", "publish-feature.sh"] },
  { name: "Merge", moment: 16, text: "You read the pull request, its checks and its review, and merge it, one at a time. No script merges.", artifacts: ["GitHub: your merge"] },
];

/** A timer the player uses; the tests replace it. */
export interface Timer { start(tick: () => void, ms: number): unknown; stop(handle: unknown): void }

const intervalTimer: Timer = {
  start: (tick, ms) => setInterval(tick, ms),
  stop: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
};

export interface DemoState { moment: number; playing: boolean; lane: LaneKey }

/**
 * The state of the demo and its controls. Nothing plays until play() is
 * called; every other control pauses. Playing advances one moment per
 * interval and stops at the last one; play() at the last moment starts over.
 */
export function createDemo(onChange: (state: DemoState) => void, timer: Timer = intervalTimer, interval = 2600) {
  const state: DemoState = { moment: 0, playing: false, lane: "f02" };
  let handle: unknown = null;
  const emit = () => onChange({ ...state });
  const halt = () => {
    if (handle !== null) timer.stop(handle);
    handle = null;
    state.playing = false;
  };
  const show = (moment: number) => {
    state.moment = clamp(moment);
    // A merge shows the lane that is merged.
    const merged = mergeAt(state.moment);
    if (merged) state.lane = merged.key;
  };
  const tick = () => {
    show(state.moment + 1);
    if (state.moment === last) halt();
    emit();
  };
  return {
    get state(): DemoState { return { ...state }; },
    go(moment: number) { halt(); show(moment); emit(); },
    next() { halt(); show(state.moment + 1); emit(); },
    previous() { halt(); show(state.moment - 1); emit(); },
    restart() { halt(); show(0); emit(); },
    play() {
      if (state.playing) return;
      if (state.moment === last) show(0);
      state.playing = true;
      handle = timer.start(tick, interval);
      emit();
    },
    pause() { if (!state.playing) return; halt(); emit(); },
    toggle() { if (state.playing) this.pause(); else this.play(); },
    /** Selects a feature: its terminal becomes the active one. Before the features start, it goes to their start. */
    select(lane: LaneKey) { halt(); state.lane = lane; if (state.moment < featuresFrom) show(featuresFrom); emit(); },
  };
}
