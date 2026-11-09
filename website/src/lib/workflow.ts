// The states of the workflow map on /workflow: what the drawing, its words
// list, its scenario summary, its caption and its walkthrough show for a part of the workflow, a
// way of running it, a risk level, a profile and a situation, and the routes
// of one exception each that the explorer can follow. The page renders the
// initial state at build time and the map's script renders every other state
// from the same function. The real case below the map, #241 as it ran
// (guide), moves along the route of its own state.
//
// The facts are those of docs/development.md ("Project bootstrap workflow",
// "Clarifying a feature", "Running a feature with one command", "What each
// level requires", "Workflow profiles", "The merge approval gate"); the
// models are read from .agents/agents.conf at build time (parseAgents).

export type Part = "all" | "planning" | "feature";
export type Run = "steps" | "unattended";
export type Risk = "low" | "medium" | "high";
export type Profile = "standard" | "light";
export type Situation = "none" | "repair" | "unclear" | "findings" | "protected";

export interface State {
  part: Part;
  run: Run;
  risk: Risk;
  profile: Profile;
  situation: Situation;
}

/** The finished drawing: the whole workflow, medium risk, standard profile. */
export const initial: State = { part: "all", run: "steps", risk: "medium", profile: "standard", situation: "none" };

/** The switches of the map, in the order they are shown; the minor ones in a second, smaller row. */
export const switches = [
  { name: "risk", legend: "risk", options: [["low", "low"], ["medium", "medium"], ["high", "high"]] },
  { name: "profile", legend: "profile", options: [["standard", "standard"], ["light", "light"]] },
  { name: "run", legend: "run", options: [["steps", "step by step"], ["unattended", "unattended"]] },
  { name: "part", legend: "part", minor: true, options: [["all", "both"], ["planning", "planning"], ["feature", "feature"]] },
  {
    name: "situation",
    legend: "situation",
    minor: true,
    options: [["none", "all paths"], ["unclear", "unclear Issue"], ["repair", "checks fail"], ["findings", "findings"], ["protected", "protected path"]],
  },
] as const;

/** Reads a state from the values of the switches; anything unknown is the initial value. */
export function stateOf(values: Record<string, string | undefined>): State {
  const pick = <K extends keyof State>(name: K): State[K] => {
    const known = switches.find((s) => s.name === name)!.options.map(([value]) => value as string);
    const value = values[name];
    return (value !== undefined && known.includes(value) ? value : initial[name]) as State[K];
  };
  return { part: pick("part"), run: pick("run"), risk: pick("risk"), profile: pick("profile"), situation: pick("situation") };
}

/** The provider and model of each role, per risk level ("" is the plain line). */
export type Models = Record<string, Record<string, string>>;

/** Parses .agents/agents.conf: "<role>: <provider> <model>" and "<role>@<level>: ...". */
export function parseAgents(text: string): Models {
  const models: Models = {};
  for (const line of text.split("\n")) {
    const match = /^([a-z-]+)(?:@(low|medium|high))?:\s*(\S+)\s+(\S+)\s*$/.exec(line.trim());
    if (!match) continue;
    const [, role, level = "", provider, model] = match;
    (models[role] ??= {})[level] = `${provider} ${model}`;
  }
  return models;
}

/** The agent of a role at a level: the line of the level, otherwise the plain line. */
export function agent(models: Models, role: string, level: Risk): string {
  const lines = models[role] ?? {};
  return lines[level] ?? lines[""] ?? role;
}

export interface Step {
  /** The element of the map and the words list that this step reaches. */
  key: string;
  /** The elements that are on the route once this step is reached. */
  lights: string[];
  /** Who acts, in plain words. */
  who: string;
  /** What happens, for the caption. */
  text: string;
  /** A decision of yours: a walkthrough that plays pauses here. */
  you?: boolean;
}

export interface View {
  /** Elements drawn off the route in this state. */
  off: string[];
  /** Conditional branches that this state takes. */
  taken: string[];
  /** Elements not shown in this state (the other shape of a station, a note). */
  hidden: string[];
  /** Stations drawn as an owner gate in this state, of those whose shape changes. */
  gates: string[];
  /** The text of every label that changes with the state. */
  labels: Record<string, string>;
  /** The state in plain words: "Medium risk", "standard profile", "step by step", ... */
  summary: string[];
  /** What this state shows, in two or three sentences. */
  caption: string;
  /** The walkthrough of this state, in order. */
  walk: Step[];
}

/** The stations of each line, in the order of the route. */
export const planning = ["p-idea", "p-req", "p-approve-req", "p-plan", "p-review", "p-approve", "p-merge"];
export const feature = ["f-issue", "f-implement", "f-checks", "f-review", "f-findings", "f-commit", "f-pr", "f-merge"];

/** The segments of the route that lead to each station, on its usual path. */
const into: Record<string, string[]> = {
  "p-idea": [],
  "p-req": ["s-p-req"],
  "p-approve-req": ["s-p-approve-req"],
  "p-plan": ["s-p-plan"],
  "p-review": ["s-p-review"],
  "p-approve": ["s-p-approve"],
  "p-merge": ["s-p-merge"],
  "f-issue": ["s-f-issue"],
  "f-implement": ["s-f-implement"],
  "f-checks": ["s-f-checks"],
  "f-review": ["s-f-out", "s-f-review"],
  "f-findings": ["s-f-findings"],
  "f-commit": ["s-f-in", "s-f-commit"],
  "f-pr": ["s-f-pr"],
  "f-merge": ["s-f-merge"],
};

/** Every element the walkthrough moves along. */
export const route = [
  ...Object.keys(into),
  ...Object.values(into).flat(),
  "b-revise", "b-clarify", "f-answer", "b-repair", "b-fix", "b-bypass",
];

const levelName = { low: "Low", medium: "Medium", high: "High" } as const;

export function describe(state: State, models: Models): View {
  const { part, run, risk, profile, situation } = state;
  const unattended = run === "unattended";
  const noReview = risk === "low" && profile === "light";
  const lightTriage = profile === "light" && risk !== "high";
  const implementer = agent(models, "implementer", risk);
  const reviewer = agent(models, "reviewer", risk);
  const triage = agent(models, "triage", risk);
  const approval = noReview || situation === "protected";

  const off = new Set<string>();
  const taken = new Set<string>();
  const hidden = new Set<string>();

  const planningKeys = ["t-planning", ...planning, "s-p-req", "s-p-approve-req", "s-p-plan", "s-p-review", "s-p-approve", "s-p-merge", "s-f-issue", "b-revise"];
  const featureKeys = [
    "t-feature", ...feature, "s-f-implement", "s-f-checks", "s-f-out", "s-f-review", "s-f-findings", "s-f-in", "s-f-commit", "s-f-pr", "s-f-merge",
    "b-clarify", "f-answer", "b-repair", "b-fix", "b-bypass", "n-bypass",
  ];
  if (part === "feature") {
    planningKeys.forEach((key) => off.add(key));
    hidden.add("w-planning");
  }
  if (part === "planning") {
    featureKeys.forEach((key) => off.add(key));
    hidden.add("w-feature");
  }

  // The review and its triage, and the bypass that only low risk under a
  // policy with low: review: none takes. Policy excludes the bypass
  // everywhere else, so there it is drawn off the route, never as a
  // conditional route that could be taken.
  if (noReview) {
    ["s-f-review", "f-review", "s-f-findings", "f-findings", "s-f-in", "b-fix"].forEach((key) => off.add(key));
    hidden.add("w-f-review").add("w-f-findings");
    taken.add("b-bypass").add("n-bypass");
  } else {
    off.add("b-bypass").add("n-bypass");
  }
  // Step by step you approve the triage (a diamond); unattended an agent does (a ring).
  hidden.add(unattended ? "f-findings-gate" : "f-findings-ring");
  if (!unattended) hidden.add("n-unattended");
  if (!approval) hidden.add("f-merge-approval");

  if (part !== "planning") {
    if (situation === "unclear") {
      taken.add("b-clarify");
      ["s-f-checks", "f-checks", "s-f-out", "s-f-review", "f-review", "s-f-findings", "f-findings", "s-f-in", "s-f-commit", "f-commit",
        "s-f-pr", "f-pr", "s-f-merge", "f-merge", "b-repair", "b-fix", "b-bypass", "n-bypass"].forEach((key) => off.add(key));
      taken.delete("b-bypass");
      taken.delete("n-bypass");
    }
    if (situation === "repair") taken.add("b-repair");
    if (situation === "findings" && !noReview) taken.add("b-fix");
  }
  if (situation !== "unclear") hidden.add("n-stop");

  // In plain words: a decision per finding; the light triage lets minor ones
  // wait (step by step the diamond of the station says that you approve).
  const findings = lightTriage
    ? "minor ones may wait"
    : unattended ? "a decision per finding" : "you approve each decision";
  const labels: Record<string, string> = {
    "f-implement.sub": implementer,
    "f-review.sub": noReview ? "not reviewed" : reviewer,
    "f-findings.sub": noReview ? "nothing to decide" : findings,
    "f-commit.sub": noReview ? "not reviewed" : "completion gate",
    "f-merge.sub": "by you",
    "p-review.sub2": agent(models, "planning-reviewer", "medium"),
    "p-req.sub2": agent(models, "project-grill", "medium"),

    "w-f-implement.cond": [
      "If the Issue leaves a decision open that matters, the implementer changes nothing, writes its questions in the handoff note and stops; nothing is reviewed or committed until you answer.",
      unattended ? "The run stops with status 3; answer in the note or in a comment on the Issue and run the feature again." : "Answer in the note or in a comment on the Issue, then resume with start-feature.sh <issue> --resume.",
    ].join(" "),
    "w-f-checks.cond": [
      `If a check fails, the implementer repairs it and the checks run again${unattended ? " (at most three repairs in a run)" : ""}.`,
      noReview ? "Low risk with low: review: none goes from here to the commit, without a reviewer or a triage; a repair that makes the feature medium sends it to the review after all." : "",
    ].filter(Boolean).join(" "),
    "w-f-review.cond": `Another provider than the implementer, read-only: every acceptance criterion against the code and the tests, and the impact on the architecture.${risk === "high" ? " A high-risk feature is always reviewed, under every profile." : ""}`,
    "w-f-findings.cond": [
      "Per finding: fix now, defer to a follow-up Issue, or accept with a reason; critical and major findings are fix now, unless you record an exception.",
      lightTriage ? "The light triage prefers to defer or accept suggestions and minor findings over a fix round." : "",
      unattended ? `The triage agent (${triage}) decides without you; read its decisions on the Issue afterwards.` : "You approve the decisions, which are published on the Issue.",
      "Findings to fix are fixed, checked and reviewed again: the changes, then the complete feature.",
    ].filter(Boolean).join(" "),
    "w-f-commit.cond": noReview
      ? "Records Review: not reviewed: Low risk by project policy. Refused unless the completion record says complete or awaiting evidence and the verification passed for this content."
      : "Refused unless the completion record says complete or awaiting evidence, the verification passed for this content, and the latest review is current, covers the complete feature and has no critical or major finding.",
    "w-f-merge.cond": noReview
      ? "Nobody rated the impact on the architecture, so the merge needs your approval. No script merges."
      : situation === "protected"
        ? "A protected path changed, so the merge needs your approval; the commit carries an approval request that names the content tree. No script merges."
        : "Your approval is needed when a protected path changed or the reviewer rated the impact on the architecture major or breaking. No script merges.",
  };

  const summary = [`${levelName[risk]} risk`, `${profile} profile`, unattended ? "unattended" : "step by step"];
  if (part !== "all") summary.push(part === "planning" ? "planning only" : "one feature");
  if (situation !== "none") summary.push(switches.find((s) => s.name === "situation")!.options.find(([value]) => value === situation)![1]);

  // The caption: what this state shows, in two or three sentences.
  const text: string[] = [];
  if (part === "planning") {
    text.push(
      "Once at the start, and again for each change of the plan: requirements that you approve, a plan, an independent review, your approval and your merge.",
      "The risk level, the profile and the way of running apply to features.",
    );
  } else {
    if (noReview) text.push("No review by policy (low: review: none, which the light profile sets): the commit says not reviewed, and the merge needs your approval.");
    else if (risk === "low") text.push("Reviewed like any other feature: the standard profile has no low: review: none. As shipped no path is low; a project adds a low class in risk.conf.");
    else if (risk === "high") text.push(`The implementer is ${implementer}; the review and the full triage always apply, whatever the profile.`);
    else if (lightTriage) text.push(`Reviewed by ${reviewer}; the light triage prefers to defer or accept suggestions and minor findings over another fix round.`);
    else text.push(`The implementer is ${implementer} and the reviewer ${reviewer}, an agent of another provider; the findings get the full triage.`);
    text.push(
      unattended
        ? "run-feature.sh runs from the implementation to the pull request, and the triage agent decides about the findings without you. It never merges."
        : noReview
          ? "You run each script."
          : "You run each script and approve the triage of every review with findings.",
    );
    if (situation === "unclear") text.push("Here the Issue leaves a decision open: implementation stops with a question, and nothing goes on until you answer.");
    if (situation === "repair") text.push("Here a check fails: the implementer repairs it before anything is reviewed.");
    if (situation === "findings") text.push(noReview ? "Without a review there are no findings to triage." : "Here the review finds something to fix: the fix is checked and reviewed again.");
    if (situation === "protected") text.push("Here a protected path changed: whatever the review says, the merge needs your approval.");
  }

  return {
    off: [...off],
    taken: [...taken],
    hidden: [...hidden],
    gates: unattended ? [] : ["f-findings"],
    labels,
    summary,
    caption: text.join(" "),
    walk: walk(state, models),
  };
}

/** Who acts at each element of the walkthrough, in plain words. */
function whoActs(key: string, unattended: boolean): string {
  const who: Record<string, string> = {
    "p-idea": "You",
    "p-req": "You and Project Grill, an agent that asks",
    "p-approve-req": "You",
    "p-plan": "The planning agent",
    "p-review": "The planning reviewer, an agent that cannot edit files",
    "p-approve": "You",
    "p-merge": "You",
    "f-issue": "A script, started by you",
    "f-implement": "The implementer, an agent",
    "b-clarify": "The implementer",
    "f-answer": "You",
    "f-checks": "A script, verify.sh",
    "b-repair": "The implementer",
    "f-review": "The reviewer, an agent of another provider that cannot edit files",
    "f-findings": unattended ? "The triage agent" : "The triage agent proposes, you approve",
    "b-fix": "The implementer",
    "f-commit": "A script, finish-feature.sh",
    "f-pr": "A script, publish-feature.sh, then CI",
    "f-merge": "You",
  };
  return who[key] ?? "";
}

function walk(state: State, models: Models): Step[] {
  const { part, run, risk, profile, situation } = state;
  const unattended = run === "unattended";
  // Your decisions: the approvals, the answer to a question, the triage step by step, the merge.
  const decisions = ["p-approve-req", "p-approve", "p-merge", "f-answer", "f-merge", ...(unattended ? [] : ["f-findings"])];
  const noReview = risk === "low" && profile === "light";
  const steps: Step[] = [];
  const reach = (key: string, text: string, lights = into[key] ?? []) =>
    steps.push({ key, lights: [...lights, key], who: whoActs(key, unattended), text, ...(decisions.includes(key) && { you: true }) });

  if (part !== "feature") {
    reach("p-idea", "You describe the project in your own words, in docs/PROJECT_DESCRIPTION.md.");
    reach("p-req", `start-planning.sh: Project Grill (${agent(models, "project-grill", "medium")}) asks about the goals, the users, the scope and the constraints, and drafts the requirements.`);
    reach("p-approve-req", "You approve the requirements; the planning goes on only after that.");
    reach("p-plan", `A fresh planning session (${agent(models, "project-planner", "medium")}) writes the architecture, the roadmap and the necessary ADRs.`);
    reach("p-review", `review-planning.sh: ${agent(models, "planning-reviewer", "medium")} reviews the plan, read-only. With findings, revise-planning.sh proposes a decision per finding, you approve them, and the plan is reviewed again.`);
    reach("p-approve", "finish-planning.sh records your approval with a fingerprint of the requirements and the roadmap; a later change to them makes it stale.");
    reach("p-merge", "You merge the planning pull request. Features start from that plan.");
  }
  if (part === "planning") return steps;

  const implementer = agent(models, "implementer", risk);
  reach("f-issue", "create-feature-issue.sh turns a roadmap feature into a GitHub Issue; it refuses while the approval of the plan is stale.", part === "all" ? ["s-f-issue"] : []);
  reach(
    "f-implement",
    `${unattended ? "run-feature.sh starts" : "start-feature.sh creates the branch and the worktree and starts"} the implementer (${implementer}). It first decides whether the Issue is clear, then writes the code and the tests and records how far the Issue is done.`,
  );
  if (situation === "unclear") {
    reach("b-clarify", `The Issue leaves a decision open that matters: the implementer changes nothing, writes its questions in the handoff note and stops. ${unattended ? "run-feature.sh stops with status 3." : "The session ends blocked."} Nothing is reviewed or committed.`, []);
    reach("f-answer", `You answer, in the handoff note or in a comment on the Issue, and ${unattended ? "run run-feature.sh <issue> again" : "resume with start-feature.sh <issue> --resume"}.`, ["b-clarify"]);
    reach("f-implement", "The next session reads your answers and implements; it asks again only about a decision the answers left open.", ["b-clarify", "f-answer"]);
  }
  reach("f-checks", "verify.sh runs the checks of scripts/verify.conf; the pass is recorded for exactly this content.");
  if (situation === "repair") {
    reach("b-repair", `A check fails. The implementer repairs it${unattended ? "; the run resumes it with the failing checks, at most three times" : ""}.`, []);
    reach("f-checks", "The checks run again and pass. Nothing is reviewed before they do.", ["b-repair"]);
  }
  if (noReview) {
    reach("f-commit", "Low risk with low: review: none: no reviewer and no triage. finish-feature.sh commits with Review: not reviewed: Low risk by project policy.", ["s-f-out", "b-bypass", "s-f-commit"]);
  } else {
    const reviewer = agent(models, "reviewer", risk);
    const lightTriage = profile === "light" && risk !== "high";
    reach("f-review", `review-feature.sh: ${reviewer}, another provider than the implementer and read-only, checks every acceptance criterion and rates the impact on the architecture.`);
    reach(
      "f-findings",
      `${unattended ? `The triage agent (${agent(models, "triage", risk)}) decides` : "triage-review.sh proposes, and you approve,"} per finding: fix now, defer or accept${lightTriage ? ", with the light triage" : ""}. The decisions are published on the Issue.`,
    );
    if (situation === "findings") {
      reach("b-fix", "apply-triage.sh: the implementer fixes the findings to fix now.", []);
      reach("f-checks", "The checks run again on the fixes.", ["b-fix"]);
      reach("f-review", "The review again: the changes, then the complete feature. No finding is left to fix.", ["s-f-out", "s-f-review"]);
      reach("f-findings", "The last round leaves nothing to fix.", ["s-f-findings"]);
    }
    reach("f-commit", "finish-feature.sh commits, with the completion, the verification, the review and the risk level recorded.", ["s-f-in", "s-f-commit"]);
  }
  reach("f-pr", "publish-feature.sh pushes the branch and opens the pull request with the evidence; CI runs the checks again.");
  reach(
    "f-merge",
    noReview
      ? "You merge. Nobody rated the impact on the architecture, so the merge needs your approval."
      : situation === "protected"
        ? "You merge. A protected path changed, so the merge needs your approval; check-guardrails.sh names it."
        : "You merge, by your repository's rules. Your approval is needed for a protected path or a major impact on the architecture.",
  );
  return steps;
}

/**
 * The real case: Issue #241 as it ran (PR #249, one unattended run of
 * run-feature.sh on 30 October 2026), shown on /workflow below the map.
 * Every figure is that of Engineering records (/docs/engineering-records/#story), which names
 * its sources: the Issue, its published review and triage, the description of
 * PR #249 and the run record. Its route is the walkthrough of this state, so
 * the guide moves along the map exactly as the switches would draw it.
 */
export const example: State = { part: "feature", run: "unattended", risk: "medium", profile: "standard", situation: "findings" };

/**
 * What happened at each step of #241, in the order of the walkthrough of
 * `example`. This is the tour of /workflow: each text is at most 40 words and
 * three sentences, and no text or who names a risk level, the unattended run,
 * acceptance criteria or a script (#330); the section's lead and the
 * reference entry of each step tell those.
 */
const ran: { key: string; who: string; text: string }[] = [
  { key: "f-issue", who: "You", text: "Issue #241 asked for three pages of this site: Features, Examples and About, now Why Codeyard, Projects and About. You started the run with one command, and it went on without asking you until the pull request." },
  { key: "f-implement", who: "The implementer, an agent (claude opus)", text: "In its own branch and working copy, it first checked that the Issue left no decision open. It wrote the three pages in 11 minutes, then recorded for each requirement whether it is met, with evidence." },
  { key: "f-checks", who: "A script", text: "Every check the project declares ran: the tests, and the build of this site. They passed in 14 seconds, and the pass holds for exactly this content." },
  { key: "f-review", who: "The reviewer, an agent of another provider (codex gpt-6-luna) that cannot edit files", text: "Round 1 compared each requirement of the Issue with the code and found one major problem: the Examples page (now Projects) linked the source files of one example only, and the Issue asked for every example." },
  { key: "f-findings", who: "The triage agent (claude sonnet), deciding without you", text: "For each finding it decides: fix it now, defer it to a later Issue, or accept it with a reason. A major finding is fixed now, so it decided that and published the decision on the Issue." },
  { key: "b-fix", who: "The implementer (claude opus)", text: "It fixed only what was decided as fix now: it added the source files of the other four examples, in 85 seconds." },
  { key: "f-checks", who: "A script", text: "The content changed, so the checks ran again. They passed in 15 seconds." },
  { key: "f-review", who: "The reviewer (codex gpt-6-luna)", text: "Round 2 reviewed only the fix and found nothing. Round 3 reviewed the complete feature again: PASS." },
  { key: "f-findings", who: "The triage agent", text: "With no finding left, there was nothing more to decide." },
  { key: "f-commit", who: "A script", text: "The commit is refused unless the completion record says complete, the checks passed for this exact content, and the latest review covers the whole feature with no critical or major finding. All three held." },
  { key: "f-pr", who: "A script, then CI", text: "It pushed the branch and opened pull request #249, with the records of the run in its description, and CI ran the checks again on GitHub. 13 minutes after the implementation started." },
  { key: "f-merge", who: "You", text: "The owner read the pull request and merged it, half an hour later. No approval was required: the reviewer rated the impact on the architecture minor, and no protected file was touched. No script merges." },
];

/** The steps of the real case: the route of `example`, told as #241 ran it. Decisions of the owner: the start and the merge. */
export function guide(models: Models): Step[] {
  const steps = walk(example, models);
  if (steps.length !== ran.length) throw new Error(`guide: ${ran.length} steps for a route of ${steps.length}`);
  return steps.map((step, i) => {
    if (step.key !== ran[i].key) throw new Error(`guide: step ${i + 1} is ${ran[i].key}, the route reaches ${step.key}`);
    const { you: _, ...rest } = step;
    return { ...rest, who: ran[i].who, text: ran[i].text, ...((step.key === "f-issue" || step.you) && { you: true }) };
  });
}

/** The routes a visitor can follow without a switch: one exception each, step by step. */
const oneFeature: State = { part: "feature", run: "steps", risk: "medium", profile: "standard", situation: "none" };
export const routes = [
  { id: "repair", name: "a check fails", state: { ...oneFeature, situation: "repair" } },
  { id: "unclear", name: "the Issue is unclear", state: { ...oneFeature, situation: "unclear" } },
  { id: "findings", name: "the review finds problems", state: { ...oneFeature, situation: "findings" } },
  { id: "high", name: "higher risk", state: { ...oneFeature, risk: "high" } },
] as const satisfies readonly { id: string; name: string; state: State }[];

/** The view of a route, the first one for an unknown id. */
export function follow(id: string, models: Models): View {
  const chosen = routes.find((r) => r.id === id) ?? routes[0];
  return describe(chosen.state, models);
}

/**
 * The state classes of an element of the map or the words list. With `lit`,
 * the walkthrough is on and an element of the route that it has not reached
 * yet is ahead.
 */
export function classesOf(view: View, key: string, lit?: Set<string>): Record<string, boolean> {
  return {
    "is-off": view.off.includes(key),
    "is-taken": view.taken.includes(key),
    "is-hidden": view.hidden.includes(key),
    "is-ahead": lit !== undefined && route.includes(key) && !lit.has(key),
    you: view.gates.includes(key),
  };
}
