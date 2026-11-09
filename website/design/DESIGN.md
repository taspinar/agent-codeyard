---
name: Agentic Coding Template (ACT)
description: Build software with AI, with a clear plan and checks along the way. A transit-map design system for the ACT website.
colors:
  ground: "#f4f5f4"
  ground-2: "#e9ebea"
  ink: "#141617"
  ink-2: "#4c5357"
  ink-3: "#5f676c"
  rule: "#c9cdcf"
  rule-strong: "#7a8186"
  line: "#00804a"
  line-ink: "#006b3e"
  line-soft: "#d4ebdf"
  off: "#b3b8bb"
  select: "#bfe3cf"
  ground-dark: "#121415"
  ground-2-dark: "#1b1e20"
  ink-dark: "#e9ebec"
  ink-2-dark: "#b3babe"
  ink-3-dark: "#8e969b"
  rule-dark: "#33393c"
  rule-strong-dark: "#687075"
  line-dark: "#34c27c"
  line-ink-dark: "#5fd598"
  line-soft-dark: "#173426"
  off-dark: "#474e52"
  select-dark: "#1f5038"
  terminal-ground: "#141617"
  terminal-ground-dark: "#000000"
  terminal-ink: "#e4e6e7"
  terminal-comment: "#8e989d"
  terminal-prompt: "#5fd598"
typography:
  display:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "clamp(2.5rem, 1.3rem + 3.9vw, 4.6rem)"
    fontWeight: 800
    lineHeight: 0.98
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "2.4rem"
    fontWeight: 800
    lineHeight: 1.08
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.3rem"
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: "-0.01em"
  lede:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.3rem"
    fontWeight: 400
    lineHeight: 1.45
  body:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "1.0625rem"
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "0.9rem"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "Overpass, Helvetica Neue, Arial, sans-serif"
    fontSize: "0.8rem"
    fontWeight: 700
    lineHeight: 1.6
  data:
    fontFamily: "Overpass Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "0.9rem"
    fontWeight: 600
    lineHeight: 1.6
  code-block:
    fontFamily: "Overpass Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "0.88rem"
    fontWeight: 400
    lineHeight: 1.75
rounded:
  hair: "2px"
  round: "50%"
spacing:
  s-1: "0.25rem"
  s-2: "0.5rem"
  s-3: "0.75rem"
  s-4: "1rem"
  s-5: "1.5rem"
  s-6: "2rem"
  s-7: "3rem"
  s-8: "4.5rem"
  s-9: "7rem"
  gutter: "clamp(1rem, 0.4rem + 2.4vw, 2.5rem)"
  page: "78rem"
  measure: "68ch"
  stroke: "6px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "{rounded.hair}"
    padding: "0.8rem 1.25rem 0.7rem"
  button-primary-hover:
    backgroundColor: "{colors.line-ink}"
    textColor: "{colors.ground}"
  switch:
    textColor: "{colors.ink-2}"
    typography: "{typography.data}"
    rounded: "{rounded.hair}"
    padding: "0.25rem 0.6rem 0.15rem"
  switch-checked:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
  theme-toggle:
    textColor: "{colors.ink-2}"
    rounded: "{rounded.hair}"
    padding: "0.3rem 0.55rem"
  header:
    backgroundColor: "{colors.ground}"
    height: "3.75rem"
  record:
    backgroundColor: "{colors.ground-2}"
    textColor: "{colors.ink}"
    padding: "1rem 1rem 0.75rem"
  pin:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
    rounded: "{rounded.round}"
    size: "1.35rem"
  reset-button:
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.hair}"
  detail-button:
    textColor: "{colors.ink-2}"
    typography: "{typography.label}"
    rounded: "{rounded.hair}"
  tab:
    textColor: "{colors.ink-2}"
    typography: "{typography.body-sm}"
  tab-selected:
    textColor: "{colors.ink}"
  terminal:
    backgroundColor: "{colors.terminal-ground}"
    textColor: "{colors.terminal-ink}"
    typography: "{typography.code-block}"
    rounded: "{rounded.hair}"
    padding: "1.5rem"
---

# Design System: Agentic Coding Template (ACT)

## Overview

**Creative North Star: "The Route Map of a Change"**

The site is drawn in Vignelli/Beck network-map grammar. A change is a transit line: steps are stations, owner decisions are diamonds, conditional paths are dashed branches, and one signal green marks the route. Everything else is ink on a neutral, slightly cool map-paper ground (never cream), divided by hairline rules. Diagrams are the real mechanism, not a metaphor laid over it; every station and branch corresponds to a script, a policy or a gate that exists.

Density is that of a reference map: flat, typographic, many small labelled facts, generous section spacing. Structure comes from rules and alignment, never from boxes. Light and dark themes are equal citizens and neither uses gradient or glow.

**Key Characteristics:**
- One line colour (signal green) on ink and grey; green is the route, ink is the stops.
- Overpass (highway-signage lineage) for prose and labels; Overpass Mono only for data.
- Hairline rules for division, 2px ink rules to head a structure; no elevation.
- 45/90-degree strokes, round stations, diamond owner gates.
- Every map has a words twin that is both its text alternative and its narrow-screen form.

## Colors

Near-monochrome map paper and ink with a single signal green.

### Primary
- **Signal Green** (`line`): the route of a change. Map trunk strokes, the words-list spine, link underlines, the focus outline, nav current/hover underline, the ring in the ACT mark. 4.59:1 on ground (light), 8.05:1 (dark).
- **Deep Signal Green** (`line-ink`): green used as text or as a filled hover state: the second clause of the hero headline, link hover text, primary button hover, the "changed" label in tables. 6.06:1 (light), 10.08:1 (dark).
- **Green Wash** (`line-soft`): low-half highlighter behind quoted phrases in an annotated record. Never a fill for areas.
- **Selection Green** (`select`): text selection background only.

### Neutral
- **Map Paper** (`ground`): page ground, sticky header ground, station fill, text on filled ink.
- **Paper Shade** (`ground-2`): ground for verbatim artifacts only: the annotated record and inline code.
- **Ink** (`ink`): text, station rings, owner-gate diamonds, pins, primary button, checked switch, the 2px structure rules.
- **Ink Grey** (`ink-2`): secondary text: lede, captions, station sub-labels, nav at rest, ledger lists.
- **Label Grey** (`ink-3`): smallest labels: table heads, switch legends, map notes, record source line, absent values. 5.27:1 (light), 6.15:1 (dark).
- **Hairline** (`rule`): 1px dividers and resting borders of switches and the theme toggle.
- **Strong Hairline** (`rule-strong`): dashed conditional branches and hover borders.
- **Off Route** (`off`): a trunk segment and its station rings not taken in the current state (review bypass).

Dark theme swaps every token to its `-dark` value via `prefers-color-scheme: dark` unless `data-theme="light"` is set, or via `data-theme="dark"`. The terminal keeps its own dark ground in both themes (`terminal-ground`; `terminal-ground-dark` with a 1px `rule` border in dark).

### Named Rules
**The One Line Rule.** Green means the route. It appears only on route strokes, link underlines, focus, the mark ring, record highlights, the "changed" label and the hero's second clause. No green backgrounds, panels, badges or decoration.

**The Ink Decides Rule.** Stations and owner gates are ink, never green. The line is green; what happens on it is black (white in dark). One state exception: the station a reader has selected in the workflow explorer is filled `line` (its ring stays ink), and a focused station's symbol is stroked `line`, because selection and focus are direct signals, like the focus outline.

**The Separator Dot Rule.** A green middle dot (`·` in `line-ink`) may separate short facts on one line (hero fact line, scenario summary). It is a separator, not an icon; it disappears when the facts wrap into a grid.

## Typography

**Display Font:** Overpass 800 (with Helvetica Neue, Arial, sans-serif)
**Body Font:** Overpass 400/600/700 (same stack)
**Label/Mono Font:** Overpass Mono 400/600 (with ui-monospace, SFMono-Regular, Menlo, monospace)

**Character:** Signage sans with tight negative tracking at display sizes; its mono sibling marks anything a machine reads or a person types. Fonts are self-hosted woff2 (OFL), `font-display: swap`, Overpass 800 preloaded. Kerning and ligatures on.

### Hierarchy
- **Display** (800, clamp 2.5–4.6rem, 0.98, -0.035em): the hero headline only, max 14ch.
- **Headline** (800, 2.4rem, 1.08, -0.02em): section h2, balanced wrapping.
- **Title** (700, 1.3rem, -0.01em): h3 and the route-map heading (tracking 0 there). Inside ledgers and splits h3 drops to 1.0625rem.
- **Lede** (400, 1.3rem, 1.45): hero lede (46ch, ink-2) and the first paragraph of a section body (1.5 line height).
- **Body** (400, 1.0625rem, 1.6): prose, max 68ch, pretty wrapping.
- **Body small** (0.9rem): captions, section-header notes, tables, ledger and note lists, nav (600).
- **Label** (600–700, 0.8rem, lowercase): table heads, switch legends, stacked-cell labels, legend items.
- **Map labels** (SVG px): station name 17px/700 (15px in secondary maps), sub-label 14px/600 ink-2, branch note 13.5px/600 ink-3.

### Named Rules
**The Value in Mono Rule.** Overpass Mono is for code, file/script/model/agent names, setting values, verification seconds and the terminal. Prose, headings, labels, station names and condition notes stay in Overpass. A map sub-label is mono only when it is a value (`verify.sh`, `claude opus`), sans when it is a description (`full triage`, `by you`).

**The Lowercase Label Rule.** Field labels are small, bold, lowercase sans in ink-3. No uppercase tracked labels, no eyebrow text above headings. Terms of a definition list that read as words (reference-field labels, comparison rows, docs sidebar group labels) are sentence case; they are still never uppercase or tracked.

## Layout

- **Frame:** content max 78rem, centred, side gutter `clamp(1rem, 0.4rem + 2.4vw, 2.5rem)`. Spacing on a 4px base (`s-1`…`s-9`).
- **Hero:** two-column grid (1.35fr / 1fr, gap s-5 × s-7, bottom-aligned): the headline left, the product line split after its comma with the second clause in `line-ink`; right, the lede in plain words (what you do, what AI and Codeyard do, what you decide; no repository, pull request, triage, evidence, gate, merge, policy, script or worktree) and two actions, the primary "See how it works" and the text link "Get started" (#329). Under the grid, one ink-2 paragraph (`.hero-copy`) introduces Claude Code and Codex with their role, then the fact line. The home page then follows the order of #329: why the open decisions come first (two paragraphs and the comparison grid of possible problems and how Codeyard handles them), the illustrative gym example in four steps (a words list shown at every width, `.scenario-steps`, each step a `.facts` list of what you do, what happens, what comes out and why it helps; the last step is the filled diamond), who does what (the ledger), who it is for (two paragraphs, no tool or provider names), and a split of the start routes and the technical pages. The real case stays on Projects (#343). No route map with switches on the home page: the full map with risk levels and profiles is on /workflow.
- **Features (#319, #343):** each feature opens with a definition list (`.pitch`) of the problem (lede size), what you get and, short, what Codeyard does; its technical layer (route diagram with its words list, tables and facts, no excerpt of a record) follows under a `details` disclosure, `.proof`, closed by default: a summary in small 600 ink that names what it holds ("How ...: files and settings"). When open, the layer's content (`.layer`) hangs from a 2px ink rule on its left and is indented by `s-5`, in body small; no fill, no border box, no shadow, in both themes. It ends with one line "Source:" that links the script or policy file on GitHub, without pull request numbers. The visible layer names no coding tool or provider. The overview stays a hairline contents list in three groups and the optional feature.
- **Projects (#332, route /examples/):** the page head is the title, one lede that names the products, one note on the second layer and a grouped contents list (Products, Engineering case studies, About the figures). The groups are `section.group` headings as on Features, and each case is a level-3 section. A product case first says what the product is and who uses it, then the product figure, then a seven-part `.facts.case` list (`ProductCase`): the problem, the change, settled first, approach and check, the review found, decision and result, sources. An illustrative case starts with the bold words "Illustrative example." An engineering case has a title that names the problem it solved, a first paragraph of at most 80 words, and its records (summary lines, figures, tables, excerpts, timelines) under a closed `details.proof` disclosure whose summary names what it holds; the issue numbers stand in the section note as sources. Times are split into active run time, waiting time and total lead time, defined under "Where the figures come from". With every disclosure closed the page stays under 3000 visible words and 10 000 px at 1440 px.
- **About (#319, #333):** the page head is the title, one lede and the contents list. The sections follow in this order: why it exists (the maker's reason and the problem), the maker, JIDAI and the project, where it stands and how to take part, what it does in short (one paragraph with links to Why Codeyard and the FAQ), the possible improvements as a `.rules` list of open Issues, one paragraph on history, and the facts list of source, licence, contributing and security. Sentences and bullets stay short, at most 20 words. The history period by period, the design decisions and the research live on the docs page History and research (`/docs/history/`, under Reference), whose timeline is the words timeline in the prose. The font licence is in the licence row of About, not in the footer.
- **Section grid:** each section is s-8 vertical padding with a 1px top rule (first section none). Inside, a 15rem header column (h2 plus one short ink-2 note naming the source, with links) and a fluid body column, gap s-6. Body children are spaced s-5. While the grid has two columns (above 1100px) the header column is sticky at 5.5rem from the top.
- **Breakpoints:**
  - **≤1100px:** the header nav moves to a full-width second row whose links wrap onto further rows rather than scroll, so every link and the theme toggle stay in view down to 375px (theme toggle pushed right on its row); hero, section grid and annotated record collapse to one column; every SVG map and its legend are hidden and the words list is shown in its place; the mark's tagline hides; the record stops wrapping and scrolls horizontally.
  - **≤760px:** ledger and split go to one column; tables stack; section padding drops to s-7, hero top to s-6.
- **Measures:** prose 68ch, lede 46ch, caption 80ch, display 14ch.
- **Docs pages:** a sidebar with links in groups, from beginning and using the workflow to configuring it and looking things up (Begin, Use, Configure, Reference); each group label is xs (`t-xs`), bold, ink-3, sentence case, `s-5` above. These are navigation group labels, not kickers: they head a list of links, never a heading. On wide screens the "On this page" list of a long reference page stays beside the text (sticky, like the section header column); in one column it sits above the text between hairlines. A code block of the docs gets a Copy button at its top right (xs, 600, a 1px `terminal-comment` border on the terminal ground) that says "Copied" for two seconds and announces it; without JavaScript there is none. A search result is the page's title as a link, then one small ink-2 passage of about 160 characters around the matched words, the words in the green-wash lower-half highlight of the annotated record; task pages (Getting started, Adopting, Troubleshooting, the references) come before the other docs pages, and those before About, Examples and the other product pages. `/workflow` keeps the heading "Every step in detail" with the note "Every command, input, output, gate and stop condition is in the workflow reference." (linked) and one line of links per stage that keep the old step anchors, and an old anchor goes on to its step in the reference.

## Elevation & Depth

Flat. No box shadows for elevation, no glows, no blur. Depth is expressed by rule weight and ground tint: a 1px `rule` hairline divides; a 2px `ink` rule heads a structure (table head, ledger, record, split heading, stacked row, footer); `ground-2` marks verbatim artifacts. The sticky header separates by its ground fill and a hairline.

### Named Rules
**The Hairline Rule.** If something needs separating, draw a rule. Inset box-shadows are allowed only as drawn strokes (nav underline 3px green, record highlighter), never as offset or blurred shadows.

## Shapes

- **Corners:** 2px (`hair`) on interactive and inline elements only: buttons, switches, theme toggle, inline code, terminal, focus outline. Content regions are square.
- **Circles:** stations, the mark ring, pins and risk-level discs. Level discs: outlined = low, half-filled (hard 50% split) = medium, filled = high.
- **Diamonds:** squares rotated 45°, for owner gates only.
- **Strokes:** route 6px (`stroke`) with round caps and joins; branches 3px dashed (7/7); every direction change is 45° or 90°.

## Components

### Header and navigation
Sticky, `ground` fill, 1px bottom hairline, min height 3.75rem. The labels, in order (#329): How it works (/workflow/), Why Codeyard (/features/), Projects (/examples/), Docs, About, Get started (/docs/getting-started/), GitHub. The mark is a 3px green ring, "ACT" in 800 at 1.35rem, then the full name in body-small ink-2 (hidden ≤1100px). Nav links: 600, body small, ink-2, no underline at rest; hover and `aria-current` turn ink with a 3px green underline. The theme toggle is a mono xs button with a 1px hairline border naming the theme it switches to ("Dark"/"Light"); the choice persists in `localStorage` (`act-theme`) and is applied in `<head>` before paint.

### Buttons and links
- **Primary:** one filled button for the page's main action: ink fill, ground text, 700, 2px corners; hover fills `line-ink`.
- **Secondary actions:** plain text links (600) beside it, not ghost buttons.
- **Links:** ink text, 2px green underline offset 0.22em; hover turns the text `line-ink`.
- **Focus:** 3px green outline, 3px offset, on every focusable element.

### Route map with switches (signature)
A `figure` between hairlines: title-level heading left, switches right, SVG map, legend, live caption.
- **Grammar:** green trunk left to right; ring stations (r 10, ground fill, 3.5px ink) with the name below and one sub-label under it; filled ink diamond = owner gate where you decide (merge, plan approval); outlined diamond = you answer, only when asked; dashed `rule-strong` branch = only when needed, loops above the line with a short ink-3 note, bypasses below; steps not taken in the current state dim to `off`. A second line in the same map is ink (planning), the feature line green.
- **Switches:** radio groups in fieldsets with lowercase ink-3 legends (`risk`, `profile`); options are mono pills, checked = ink fill. State is written to `data-risk` / `data-profile` on the container; CSS redraws the route, script swaps labels and the caption (`aria-live="polite"`).
- **Legend:** one row of the actual map symbols with words; `aria-hidden` because the words list carries the content.
- **Motion:** stroke colour only, 160ms ease-out, and only under `prefers-reduced-motion: no-preference`.

### Converging map and rules list (Learn from your runs)
The same line grammar for many-to-one: short green feature lines end in ring stations (the run records) and join the trunk at 45° into one station (`Analysis`, sub-label `analyze-runs.sh` in mono, `read-only` in sans). A filled diamond (`You decide`) follows on the ink line, which then fans out at 45° into the places a proposal can go, each ending in a ring with its label to the right. Text in this map is set larger (station 18, sub 16, note 15 viewBox units) because its viewBox is wider. Below 1100px it gives way to its words list. The rules beneath it use `.rules`: a two-column list (one column ≤760px) headed by a 2px ink rule, with each item a bold lead-in sentence in ink followed by ink-2 text.

### Four-step overview (/workflow, first layer)
The page opens with the shared scenario of the tracking issue (#328), labelled "Illustrative example" in a bold lead-in before one ink-2 sentence of the product and its function. Four steps in two phases: "Once, at the start" (describe and clarify, plan) under a 6px ink rule, the line of planning in the map, and "For each function, one after another" (build and check, decide) under a 6px green rule, the line of a feature, each with one small ink-2 note (the plan is updated only when the direction changes; the next function starts again at step 3). A step is a column: its number in mono ink-3 and its title at `t-lg`, then four rows under hairlines, always in this order, "What you do", "What the system does", "What comes out", "Why that helps" (xs 700 ink-3 terms, small values), then the example in ink-2 (at most three questions, the agreements, the plan order, an illustrative check and review remark, the result) and a small "In the reference:" line linking the reference steps behind it. Subgrids align the rows across the four columns while the reading order stays step by step; two columns at ≤1100px, one at ≤760px. The four answers of a step together are at most 40 words and never name risk, unattended, acceptance criteria or a script: those words belong to the technical layer. Not cards, tiles or a decorative diagram: a grid of hairline rows, like the comparison grid.

### Workflow explorer (/workflow)
The route map with switches, extended into a tool for finding one step: the technical layer of /workflow, under a `details` disclosure "Explore the technical workflow" (summary at body size, 700 ink), closed by default, after an h2 "The technical workflow" and one ink-2 sentence naming what it holds. A link to an element inside it opens it.
- **Complete drawing first:** the explorer opens on the complete drawing of the initial state (medium / standard / step by step / both / all paths), with the planning line, the script and model names and the switches shown. Nothing advances by itself: "Walk through the steps" starts the walkthrough at step 1, and the reader moves with Previous and Next (small 600 sans text with a 1px hairline border and 2px corners); "Show the complete workflow" ends it. A walkthrough step gives `Step n of N.`, who acts in 700 ink, what happens in at most three sentences, then `In the reference:` and a link to the step's reference entry, which tells the rest.
- **Routes row:** under the hint, a small ink-3 "Follow" label and one button per route, one exception each (a check fails, the Issue is unclear, the review finds problems, higher risk), step by step. Buttons are small 600 sans text with a 1px hairline border and 2px corners; the route followed is pressed (`aria-pressed`, ink fill). A route starts its walkthrough at step 1. Not tiles: one line of buttons, like the walkthrough's.
- **Switches:** the grouped switches, a short ink-2 paragraph that explains each switch in plain words, and the Reset, under a hairline after the routes and the list toggle. Changing a switch leaves the routes (no route pressed) and draws the complete state; the switches always show the state the map draws.
- **Without JavaScript:** the disclosure opens natively; the summary, the map and the words list are drawn for the initial state, and the routes row, the walkthrough buttons and the switches are not shown.
- **The real case:** #241 as it ran (PR #249) is not in the map. It follows the explorer and the two ways of running a feature as the section "How these pages were built": a words timeline (`.words.timeline`), each step named by its reference title, who acts, what happened in at most three sentences and 40 words and its reference link. It is the tour of the page: no step text or who names a risk level, the unattended run, acceptance criteria or a script; the section's lead and the reference entries carry those. Real runs only; its figures are those of /examples.
- **Scenario summary:** under the heading and above the map, a row headed by a 2px ink rule with a hairline below, one `aria-live="polite"` paragraph. Its first line is the summary of the state the map draws, in body size 700 ink, parts separated by green dots (`Medium risk · standard profile · step by step`). Under it, in small ink-2, the walkthrough text of the current step (`Step n of N.`, who acts in 700 ink, what happened), or, while no step is shown, the state's caption; the figure has no second caption. The Reset button (small 600 ink, 1px hairline border, 2px corners, `rule-strong` on hover) is not in this row: it sits at the end of the switches and restores medium / standard / step by step / both / all paths.
- **Grouped switches:** two rows. Primary row: `risk`, `profile`, `run`. Minor row: `part`, `situation`, options in xs type, with a hairline and `s-3` above it.
- **Conditional routes stay visible by default:** with the situation switch at "all paths", every dashed branch and the outlined "you answer" diamond are drawn, softened (dashed `rule-strong`, ink-3 notes); choosing a situation draws that branch as taken. A reader sees that the exceptions exist before asking for one.
- **Clickable stations:** stations and gates with details are buttons (`tabindex="0"`, `aria-label="Details: …"`, Enter/Space). Focus: the station symbol's stroke turns `line` at 6px (no outline box). Hover: the station name gets a green underline. Selected: ring filled `line`, labels in the heavy weight.
- **Hint:** one small ink-2 line under the map naming what selecting a step shows.
- **Step detail panel:** a section under a 2px ink rule. Head row: heading at `t-xl`, heavy weight, receiving focus on keyboard open; a Close link-button right (small 600 ink-2, `rule-strong` underline) that returns focus to the station. Tabs Overview / Technical / Failure states: small 600 ink-2 text buttons over a hairline, gap `s-5`; the selected tab is ink with a 3px green inset underline (the nav underline). ArrowLeft/ArrowRight move between tabs (roving tabindex). Overview: the step's summary at body size plus Who acts and Gate or decision; Technical: Command and Inputs and outputs; Failure states: Stops, retries and exceptions — all as reference fields. A tab whose fields are empty shows nothing of its own, no "nothing here" line. It ends with a small ink-2 line "In the reference:" linking the matching reference steps.
- **Narrow screens:** where the words list replaces the map, each item with details gets a "Details" button after its name (xs 600 ink-2, 1px hairline border, 2px corners) and the same panel opens inside that list item, heading at `t-lg`, tab text small.

### Product figure
An image of a real product, never a mock-up: the existing `Figure` component with the `img` as its first child, at the content width (`width: 100%`, `height: auto`, `width` and `height` attributes set to the file's size), a 1px `rule` hairline around it, no shadow, no rounded corners and no device frame; the same in both themes. The file lies under `website/public/images/`. The caption below names the product, its source (the public address it was taken from) and the date of the screenshot or of the publication; the alt text says what the image shows, in a few sentences, including the language of its labels when they are not English. Only images that the product publishes itself, or screenshots of its public pages: nothing from behind a login or from a private repository. A product figure shows the product, not the process: the text beside it says what Codeyard contributed. Used on Projects for each product and once on the home page, in the real-case section.

### Reference fields
A definition list on a 12rem label column and a fluid value column (gap `s-2` × `s-5`, small text, wide measure). Each row has a hairline above; labels 700 ink. Five fixed fields, always in this order: **Who acts**, **Command**, **Inputs and outputs**, **Gate or decision**, **Stops, retries and exceptions**. Where a field gathers several original entries, each keeps its original sub-label inline before the text (`input`, `result`, `your decision`…) in 600 ink-3. A field with no content is omitted (owner decision: no "none" rows). At ≤760px label and value stack in one column. On the workflow reference page every step is a `section` with a hairline and `s-4` above, its h3, one summary paragraph, then its reference fields; stages are h2.

### Words list (map fallback and text alternative)
An ordered list with a 6px green spine; each item gets a ring marker (0.95rem, 3.5px ink); owner-gate items get a filled ink diamond. Station name in 700, sub-label in body-small ink-2 (mono when a value), conditions as small ink-2 sentences. It is referenced by the map's `aria-describedby`, is shown instead of the map at ≤1100px, and follows the switch state (bypassed stations hidden).

### Fact line (homepage hero)
Directly under the hero grid, spanning both columns: one line of four short facts between two hairlines (`s-3` padding, `s-6` above), small 600 ink, separated by green middle dots (`line-ink`, `s-3` either side). At ≤760px it becomes a two-column grid without dots. Never tiles, cards, numbers-as-stats or icons.

### Handoff
Implementer and reviewer side by side under a 2px ink rule: three columns (fluid / auto, min 9rem / fluid). Each side is an h3 at body size and a small ink-2 bullet list. Between them a horizontal 6px green line (`stroke`, `line`) labelled "the content it checked" in xs 600 ink-2 on `ground`, set just above the line; `aria-hidden`, since both lists already say it. At ≤760px it stacks: implementer, the line, reviewer.

### Gates list
An ordered list of the owner's decision points on a vertical 6px ink line (it is the ink planning line, not the green route). Each item has a diamond marker on the line: filled ink = you decide, outlined (2.5px ink, `ground` fill) = you answer when asked. Item: a bold name on its own line, then one small ink-2 sentence; wide measure.

### Comparison grid
Two columns under a 2px ink rule, gap `s-6`; each column an h3 at body size over a hairline, then a definition list: xs 700 ink-3 sentence-case terms and small values. Rows are in the same order on both sides so they read across; on the home page (`.compare.rows`) the columns share a subgrid, so each row sits opposite its counterpart, and the values are kept about as long on both sides. One column at ≤760px. Used for step by step versus unattended, and on the home page for possible problems and how Codeyard handles them.

### Ledger
Three equal columns under a 2px ink rule, separated by 1px hairlines; h3 at body size, small ink-2 bullet lists. Used for "who does what". One column with hairlines between at ≤760px.

### Tables (stacked)
Small text, tabular figures, left-aligned, hairline row rules; lowercase label heads above a 2px ink rule; row headers 700, no wrap; values mono; numbers mono and right-aligned; captions below in small ink-2; absent values ink-3 with an en dash. At ≤760px rows become blocks headed by a 2px ink rule and each cell is labelled from `data-col`. Wide tables sit in a horizontal scroll wrapper.

### Matrix
A level × profile table with the same rules. Cells differing from the baseline start with a `line-ink` "changed" word label, so the difference is stated in text, not by colour alone. Stacks like tables at ≤760px.

### Annotated record with pins
A verbatim artifact (e.g. a PR description) in a mono `pre` on `ground-2` under a 2px ink rule, source URL in xs mono ink-3 first. Key phrases get the green-wash lower-half highlight and a numbered pin (1.35rem ink disc, sans numeral, `aria-hidden`). Beside it (1.25fr / 1fr), a numbered notes list with hairlines explains each pin. One column ≤1100px.

### Split
Two columns, each headed by a body-size h3 over a 2px ink rule, small bullet lists. Used to separate what ACT enforces from what repository settings enforce. One column ≤760px.

### Terminal
Dark block in both themes, 2px corners, s-5 padding, mono 0.88rem/1.75; comments in `terminal-comment`, `$` prompt in `terminal-prompt` and not selectable. Real commands only. A short small ink-2 requirements note may follow it.

### Footer
2px ink top rule, small ink-2 text, one line of project description and a nav of plain links (source, contributing, licence, FAQ, About), wrapping with space-between; padding s-6 top, s-8 bottom.

## Do's and Don'ts

### Do:
- **Do** draw every process as a line map with stations, owner-gate diamonds (filled = you decide, outlined = you answer) and dashed conditional branches at 45/90 degrees.
- **Do** keep one green, for the route and its direct signals; stations and gates stay ink.
- **Do** pair every map with an ordered words list carrying the same stations and conditions, and give the SVG `role="img"`, a `<title>` and `aria-describedby` pointing at that list.
- **Do** make the no-JS state complete: the hero map defaults to medium risk under the standard profile, switches are hidden without the `js` class, nothing depends on script to be readable.
- **Do** meet WCAG 2.2 AA in both themes: 4.5:1 for text (ink-3 is the lightest text token), 3:1 for meaningful strokes and UI borders, visible 3px focus, keyboard-operable switches, and any dimmed route paired with text stating the state.
- **Do** use Overpass Mono only for code, file, script and model names, values and seconds.
- **Do** separate with 1px hairlines and head structures with 2px ink rules.
- **Do** use real evidence only: linked Issues, PRs, review rounds and measured verification seconds.
- **Do** keep conditional routes visible, softened, by default; a switch draws the chosen one as taken.
- **Do** give every process step the five reference fields in their fixed order, omitting empty ones.

### Don't:
- **Don't** use cards: no bordered, rounded or raised boxes around content groups; tinted grounds are for verbatim artifacts only.
- **Don't** use icons. The only symbols are the map's own (ring, diamond, level disc, pin), each explained by a legend or adjacent text.
- **Don't** use visible gradients, box shadows for elevation, glows, glassmorphism or blur.
- **Don't** animate on scroll, reveal on scroll, or move anything; motion is limited to a 160ms stroke-colour change.
- **Don't** invent statistics, testimonials, user counts or benchmarks.
- **Don't** put eyebrow or kicker text above headings, or use uppercase tracked labels.
- **Don't** add a second accent colour or encode meaning in colour alone.
- **Don't** follow the Agent Codeyard blueprint where it conflicts with this file (owner decision): this DESIGN.md wins. No eyebrows, a neutral ground, no tiles or feature cards.
