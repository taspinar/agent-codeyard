// The first layer of /workflow: the shared gym scenario of the tracking issue
// (#328, "The shared scenario") in four main steps, each with what you do,
// what the system does, what comes out and why that helps. Planning (steps 1
// and 2) happens once at the start; one function after another goes through
// steps 3 and 4. It is an illustration, labelled so on the page; the real
// case (#241) and the technical map follow it.
//
// The words of the technical layer (risk, unattended, acceptance criteria,
// script names) stay out of it; each step links to the steps of the workflow
// reference behind it (`reference`, ids of src/lib/steps.ts).

export const label = "Illustrative example";

export const scenario = {
  product: "A gym's member application.",
  function: "Trainers record attendance for their classes; members see their own training history.",
};

/** The four answers of every step, in their fixed order. */
export const answers = [
  ["you", "What you do"],
  ["system", "What the system does"],
  ["result", "What comes out"],
  ["why", "Why that helps"],
] as const;

export type Answer = (typeof answers)[number][0];

export interface Step {
  id: string;
  title: string;
  /** The four answers: together the step text of the tour, at most 40 words. */
  text: Record<Answer, string>;
  /** What the step looks like in the gym scenario. */
  example: { label: string; items: string[] }[];
  /** The steps of the workflow reference behind this step. */
  reference: string[];
}

export const phases: { id: string; title: string; note: string; steps: Step[] }[] = [
  {
    id: "once",
    title: "Once, at the start",
    note: "Updated only when the direction changes.",
    steps: [
      {
        id: "describe-and-clarify",
        title: "Describe and clarify what you need",
        text: {
          you: "Describe the function in your own words and answer a few questions.",
          system: "Asks only the questions whose answers change what gets built.",
          result: "Agreements, written down, on who may do what.",
          why: "Open choices are settled before anything is built.",
        },
        example: [
          { label: "Questions", items: ["Who may record or correct attendance?", "May members see other members' data?", "What happens with a wrong registration?"] },
          {
            label: "Agreements",
            items: [
              "Trainers record and correct attendance for their own classes.",
              "A member sees only their own history.",
              "A correction keeps the original entry visible as corrected.",
            ],
          },
        ],
        reference: ["describe-the-idea", "clarify-the-requirements"],
      },
      {
        id: "plan-the-work",
        title: "Plan",
        text: {
          you: "Read the plan; approve it or ask for changes.",
          system: "Splits the work into functions, in a sensible order.",
          result: "An approved plan, with what each function must do.",
          why: "Each function builds on the last, and nothing important is left out.",
        },
        example: [{ label: "Order", items: ["Users and roles", "Classes and attendance", "The member's history view"] }],
        reference: ["create-the-plan", "review-the-plan", "approve-the-plan"],
      },
    ],
  },
  {
    id: "each",
    title: "For each function, one after another",
    note: "Then the next function of the plan starts at step 3.",
    steps: [
      {
        id: "build-and-check",
        title: "Build and check",
        text: {
          you: "Start the next function of the plan.",
          system: "One AI writes code and tests, the checks run, and by default a second AI reviews it.",
          result: "Checked code; remarks approved for fixing are fixed.",
          why: "Problems are caught before the change reaches you.",
        },
        example: [
          { label: "A check", items: ["A member who asks for another member's history is refused; the check runs with the function."] },
          { label: "A review remark", items: ["The first version let every signed-in user open the history view. The reviewer reported it, and the fix was checked."] },
        ],
        reference: ["implement-the-feature", "run-the-checks", "review-the-code", "apply-the-fixes"],
      },
      {
        id: "decide",
        title: "Decide",
        text: {
          you: "Read what was built, which checks ran and what the review found.",
          system: "Proposes the change with that evidence and never adds it itself.",
          result: "Your decision whether it becomes part of the project.",
          why: "What goes into your software stays your call.",
        },
        example: [
          {
            label: "Result",
            items: [
              "A proposed change with the checks that ran and the review's remarks. A working preview or a release depends on what your project has set up.",
            ],
          },
        ],
        reference: ["open-the-pull-request", "merge"],
      },
    ],
  },
];

/** Every step of the overview, numbered in order. */
export const steps = phases.flatMap((phase) => phase.steps);

/** The words of the step text: the four answers together. */
export const words = (step: Step) => answers.flatMap(([key]) => step.text[key].split(/\s+/).filter(Boolean)).length;
