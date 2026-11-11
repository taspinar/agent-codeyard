// The behaviour of the home page's workflow demo (#370): draws each moment of
// src/lib/demo.ts into the markup of src/components/WorkflowDemo.astro. The
// map changes classes only, in both of its layouts (horizontal and vertical),
// so the one the screen shows always has the state of the moment; the
// terminals, the tree and the dialog are written from the data. Nothing plays
// until the visitor presses Play.
import { createDemo, featureSteps, featuresFrom, lanes, last, laneState, lineKind, loopAt, milestones, moments, planSteps, progress, stages, terminalLog, terminals, tree, type DemoFile, type DemoState, type Substep } from "./demo";

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function log(entries: ReturnType<typeof terminalLog>): string {
  return entries.map((e) => `<p class="term-moment">— ${esc(e.title)}</p>${e.lines.map((line) => {
    const { kind, text } = lineKind(line);
    return kind === "command" ? `<p class="term-line command"><span class="p" aria-hidden="true">$ </span>${esc(text)}</p>` : `<p class="term-line ${kind}">${esc(text)}</p>`;
  }).join("")}`).join("");
}

export function mountDemo(root: HTMLElement) {
  const $ = <T extends Element = HTMLElement>(selector: string) => root.querySelector<T>(selector)!;
  const all = <T extends Element = Element>(selector: string) => Array.from(root.querySelectorAll<T>(selector));
  const button = (action: string) => $<HTMLButtonElement>(`[data-action="${action}"]`);
  const timeline = $<HTMLInputElement>('[data-action="timeline"]');
  const dialog = $<HTMLDialogElement>("[data-dialog]");
  const termBox = $("[data-terminals]");
  const treeBox = $("[data-tree]");
  let opener: HTMLElement | null = null;
  let shown = -1;
  let shownLane = "";
  const files = new Map<string, DemoFile>();

  const demo = createDemo(render);

  function drawMap(s: DemoState) {
    const reached = progress(s.moment);
    all<SVGGElement>("[data-milestone]").forEach((g) => {
      const i = milestones.findIndex((m) => m.key === g.dataset.milestone);
      g.classList.toggle("is-done", i <= reached);
      g.classList.toggle("is-current", i === reached && s.moment < featuresFrom);
    });
    const done = new Set<string>();
    for (let i = 0; i < reached; i++) done.add(`t${i}`);
    for (const l of lanes) {
      const state = laneState(s.moment, l.key);
      if (s.moment >= featuresFrom) done.add(`branch-${l.key}`);
      for (const st of stages) if (state.reached[st.key]) done.add(`${l.key}-${st.key}`);
      if (state.merged) done.add(`${l.key}-main`);
      for (const g of all<SVGGElement>(`[data-lane="${l.key}"]`)) {
        g.classList.toggle("is-selected", s.moment >= featuresFrom && s.lane === l.key);
        g.querySelector("[data-status]")!.textContent = state.status;
        g.setAttribute("aria-label", `${l.name}, Issue #${l.issue}: ${state.status}. Show its terminal.`);
        for (const sym of g.querySelectorAll<SVGElement>("[data-stage]")) {
          const stage = sym.dataset.stage as keyof typeof state.reached;
          sym.classList.toggle("is-done", state.reached[stage]);
          sym.classList.toggle("is-current", state.current === stage);
        }
      }
    }
    all<SVGPathElement>("[data-track]").forEach((p) => p.classList.toggle("is-done", done.has(p.dataset.track!)));
    all("[data-main]").forEach((c) => c.classList.toggle("is-done", s.moment >= lanes[0].mergeAt));
    const loop = loopAt(s.moment);
    all<SVGGElement>("[data-loop]").forEach((g) => g.classList.toggle("is-taken", g.dataset.loop === loop?.key));
  }

  function drawTerminals(s: DemoState) {
    const list = terminals(s.moment, s.lane);
    const split = list.length > 1;
    const moved = s.moment !== shown;
    const keep = new Map(all<HTMLElement>("[data-term]").map((e) => [e.dataset.term!, e.scrollTop]));
    termBox.classList.toggle("is-split", split);
    $("[data-terminals-title]").textContent = split ? "Terminals, one per feature" : "Terminal";
    button("log").hidden = !split;
    termBox.innerHTML =
      (split ? list.map((t) => `<button type="button" class="term-bar" data-select="${t.key}" aria-pressed="${t.active}"><b>${esc(t.title)}</b> <span>${esc(t.cwd)}</span></button>`).join("") : `<p class="term-bar"><b>${esc(list[0].title)}</b> <span>${esc(list[0].cwd)}</span></p>`) +
      list.map((t) => `<div class="term-body${t.active ? " is-active" : ""}" data-term="${t.key}" tabindex="0" role="region" aria-label="Terminal: ${esc(t.title)}">${log(t.entries)}</div>`).join("");
    for (const body of all<HTMLElement>("[data-term]")) body.scrollTop = moved ? body.scrollHeight : (keep.get(body.dataset.term!) ?? body.scrollHeight);
  }

  function drawTree(s: DemoState) {
    files.clear();
    const groups = tree(s.moment);
    treeBox.innerHTML = groups.map((g) => {
      const items = g.items.map((item) => {
        const marks = item.isNew ? ' <span class="mark">new</span>' : "";
        const fresh = item.isNew ? ' class="is-new"' : "";
        if (item.kind === "github") return `<li${fresh}><span class="tree-obj">${esc(item.label)}</span> <span class="state">${esc(item.state)}</span>${marks}</li>`;
        const id = `${g.key}:${item.file.path}`;
        files.set(id, item.file);
        return `<li${fresh}><button type="button" class="tree-file" data-file="${esc(id)}">${esc(item.file.path)}</button>${item.file.local ? ' <span class="mark">local</span>' : ""}${marks}</li>`;
      }).join("");
      return `<div class="tree-group${g.key === s.lane ? " is-selected" : ""}" data-group="${g.key}"><p class="tree-head"><b>${esc(g.title)}</b> <span>${esc(g.where)}</span></p><ul>${items}</ul></div>`;
    }).join("");
    // Bring the newest item of this moment into view, inside the panel only.
    const fresh = treeBox.querySelector<HTMLElement>("li.is-new");
    if (fresh && s.moment !== shown) treeBox.scrollTop = Math.max(0, fresh.offsetTop - treeBox.clientHeight / 3);
  }

  function render(s: DemoState) {
    const m = moments[s.moment];
    drawMap(s);
    if (s.moment !== shown || s.lane !== shownLane) {
      drawTerminals(s);
      drawTree(s);
    }
    $("[data-count]").textContent = `Moment ${s.moment + 1} of ${moments.length}`;
    if (s.moment !== shown) {
      $("[data-title]").textContent = m.title;
      $("[data-who]").textContent = m.who;
      $("[data-text]").textContent = m.text;
    }
    const details = button("details");
    const inPlan = s.moment >= 3 && s.moment <= 6;
    details.hidden = !(inPlan || s.moment >= featuresFrom);
    details.textContent = inPlan ? "Plan details" : "Feature steps";
    timeline.value = String(s.moment);
    timeline.setAttribute("aria-valuetext", `Moment ${s.moment + 1} of ${moments.length}: ${m.title}`);
    button("play").textContent = s.playing ? "Pause" : "Play";
    button("previous").disabled = s.moment === 0;
    button("next").disabled = s.moment === last;
    root.classList.toggle("is-playing", s.playing);
    shown = s.moment;
    shownLane = s.lane;
  }

  function open(title: string, body: string) {
    demo.pause();
    opener = document.activeElement instanceof HTMLElement || document.activeElement instanceof SVGElement ? (document.activeElement as HTMLElement) : null;
    $("[data-dialog-title]").textContent = title;
    $("[data-dialog-body]").innerHTML = body;
    if (!dialog.open) dialog.showModal();
    button("close").focus();
  }

  function openSteps(kind: "plan" | "feature") {
    const steps: Substep[] = kind === "plan" ? planSteps : featureSteps;
    const lead = kind === "plan"
      ? "Plan is one station of the route. Inside it the documents are drafted, reviewed by another agent, revised when needed, and reviewed again."
      : "Each feature runs in its own worktree, through these steps. A failed check or a review finding goes back within the same lane.";
    open(kind === "plan" ? "Inside Plan" : "Inside a feature", `<p>${esc(lead)}</p><ol class="demo-steps">${steps.map((st) => `<li><b>${esc(st.name)}</b><p>${esc(st.text)}</p><p class="files">${st.artifacts.map((a) => `<code>${esc(a)}</code>`).join(" ")}</p><button type="button" class="demo-link" data-goto="${st.moment}">Show this moment</button></li>`).join("")}</ol>`);
  }

  function openFile(f: DemoFile) {
    const where = f.local ? "A local work file: Git ignores it, and it is never merged." : "A file of the repository, committed with its branch.";
    open(f.path, `<p>${esc(f.what)} ${esc(where)}</p><pre class="demo-file" tabindex="0" aria-label="Contents of ${esc(f.path)}">${esc(f.content(demo.state.moment))}</pre><p class="note">Illustrative contents, as of moment ${demo.state.moment + 1}.</p>`);
  }

  function openLog() {
    open("Planning terminal", `<p>The planning output stays available while the features run.</p><div class="term-body is-active demo-history" tabindex="0" role="region" aria-label="Planning terminal history">${log(terminalLog(featuresFrom - 1, "planning"))}</div>`);
  }

  const activate = (el: Element, fn: () => void) => {
    el.addEventListener("click", fn);
    el.addEventListener("keydown", (e) => {
      const key = (e as KeyboardEvent).key;
      if (key === "Enter" || key === " ") { e.preventDefault(); fn(); }
    });
  };

  all<SVGGElement>("[data-milestone]").forEach((g) => {
    const m = milestones.find((x) => x.key === g.dataset.milestone)!;
    activate(g, () => ("details" in m ? (demo.go(m.moment), openSteps("plan")) : demo.go(m.moment)));
  });
  all<SVGGElement>("[data-lane]").forEach((g) => activate(g, () => demo.select(g.dataset.lane as DemoState["lane"])));
  button("play").addEventListener("click", () => demo.toggle());
  button("previous").addEventListener("click", () => demo.previous());
  button("next").addEventListener("click", () => demo.next());
  button("restart").addEventListener("click", () => demo.restart());
  button("details").addEventListener("click", () => openSteps(demo.state.moment < featuresFrom ? "plan" : "feature"));
  button("log").addEventListener("click", openLog);
  button("close").addEventListener("click", () => dialog.close());
  timeline.addEventListener("input", () => demo.go(Number(timeline.value)));
  termBox.addEventListener("click", (e) => {
    const bar = (e.target as Element).closest<HTMLElement>("[data-select]");
    if (bar) demo.select(bar.dataset.select as DemoState["lane"]);
  });
  treeBox.addEventListener("click", (e) => {
    const b = (e.target as Element).closest<HTMLElement>("[data-file]");
    if (b) openFile(files.get(b.dataset.file!)!);
  });
  dialog.addEventListener("click", (e) => {
    const go = (e.target as Element).closest<HTMLElement>("[data-goto]");
    if (go) { dialog.close(); demo.go(Number(go.dataset.goto)); }
    else if (e.target === dialog) dialog.close();
  });
  // Focus returns to the control that opened the dialog; Escape closes it natively.
  // The close event comes a task later: a control the visitor moved to since keeps the focus.
  dialog.addEventListener("close", () => {
    const back = opener;
    opener = null;
    const now = document.activeElement;
    if (back?.isConnected && (!now || now === document.body || dialog.contains(now))) back.focus();
  });
  document.addEventListener("visibilitychange", () => { if (document.hidden) demo.pause(); });
  render(demo.state);
}
