#!/usr/bin/env bash

# Tests check.sh on small outputs written here, without a build: a correct
# output under each base path passes, and every kind of fault is reported.
# Also tests that the website check of scripts/verify.conf installs the
# dependencies only when they are missing or older than package-lock.json.
#
# Run from anywhere: ./website/check-test.sh

set -euo pipefail

site="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
url="https://agentcodeyard.com"
repository="https://github.com/taspinar/agent-codeyard/blob/main"
failures=0

fail() {
  echo "check-test: $*" >&2
  failures=$((failures + 1))
}

# page <file> <base> <canonical path> <body>: writes a page of the output.
page() {
  mkdir -p "$(dirname "$1")"
  printf '<!doctype html><html><head><title>T</title><meta name="description" content="D"><link rel="canonical" href="%s%s"><link rel="stylesheet" href="%s_astro/s.css"></head><body id="top">%s</body></html>\n' \
    "$url" "$3" "$2" "$4" >"$1"
}

# output <dir> <base>: a correct output of two pages for that base path.
output() {
  local dir="$1" base="$2"
  mkdir -p "$dir/_astro" "$dir/fonts"
  : >"$dir/fonts/f.woff2"
  printf '@font-face{src:url(%sfonts/f.woff2)}\n' "$base" >"$dir/_astro/s.css"
  page "$dir/index.html" "$base" "$base" "<a href=\"${base}docs/#intro\">docs</a> <a href=\"#top\">top</a> <a href=\"$repository/docs/workflow.md\">w</a> run doctor.sh"
  page "$dir/docs/index.html" "$base" "${base}docs/" "<h2 id=\"intro\">i</h2><a href=\"$base\">home</a>"
  printf '<urlset><url><loc>%s%s</loc></url><url><loc>%s%sdocs/</loc></url></urlset>\n' "$url" "$base" "$url" "$base" >"$dir/sitemap.xml"
  : >"$dir/robots.txt"
}

# expect_fault <name> <base> <command that breaks the output> <message>
expect_fault() {
  local name="$1" base="$2" breaks="$3" message="$4" dir="$work/$1" result
  output "$dir" "$base"
  (cd "$dir" && eval "$breaks")
  if result="$("$site/check.sh" "$dir" "$base" 2>&1)"; then
    fail "$name: check.sh passed"
  elif ! grep -Fq "$message" <<<"$result"; then
    fail "$name: no '$message' in: $result"
  fi
}

for base in /agent-codeyard/ /; do
  output "$work/good" "$base"
  "$site/check.sh" "$work/good" "$base" >/dev/null 2>&1 || fail "a correct output under $base does not pass"
  rm -rf "$work/good"
done

expect_fault wrong-repository-ref / \
  'sed -i "s|blob/main/|blob/feature/|" index.html' "repository ref other than main"

# Qualified libraries and tests are checked at their actual repository paths.
output "$work/qualified" /
sed -i 's|doctor.sh|scripts/lib/risk.sh tests/lib-fakes.sh website/check.sh|' "$work/qualified/index.html"
"$site/check.sh" "$work/qualified" / >/dev/null 2>&1 || fail "qualified scripts were rejected"
expect_fault missing-qualified-script / \
  'sed -i "s|doctor.sh|scripts/lib/not-real.sh|" index.html' "not in the repository"

expect_fault missing-page /agent-codeyard/ \
  'rm -r docs' "links to /agent-codeyard/docs/#intro, which is not in the output"
expect_fault outside-base /agent-codeyard/ \
  'sed -i "s|/agent-codeyard/docs/|/docs/|" index.html' "which is outside the base path"
expect_fault missing-place / \
  'sed -i "s|id=\"intro\"||" docs/index.html' "which is not on that page"
expect_fault missing-anchor / \
  'sed -i "s|id=\"top\"||" index.html' "links to #top, which is not on the page"
expect_fault missing-repository-file / \
  'sed -i "s|docs/workflow.md|docs/missing.md|" index.html' "docs/missing.md, which is not in the repository"
expect_fault missing-script / \
  'sed -i "s|doctor.sh|no-such-script.sh|" index.html' "names no-such-script.sh, which is not in scripts/"
expect_fault missing-font /agent-codeyard/ \
  'rm fonts/f.woff2' "uses /agent-codeyard/fonts/f.woff2, which is not in the output"
expect_fault missing-canonical / \
  'sed -i "s|rel=\"canonical\"|rel=\"x\"|" docs/index.html' "has no canonical address"
expect_fault sitemap-page / \
  'rm -r docs && sed -i "s|href=\"/docs/#intro\"|href=\"#top\"|" index.html' "sitemap.xml (base /) lists"

# A redirect page of a retired route (#373): checked by its target, not by its
# metadata; a link to a place on it must be one its table maps.
redirect() {
  mkdir -p "$1/old"
  printf '<!doctype html><html><head><script>var map = {"step":"%sdocs/#intro"};</script><meta http-equiv="refresh" content="0; url=%s"><meta name="robots" content="noindex"></head><body><a href="%s">moved</a></body></html>\n' \
    "$2" "$3" "$3" >"$1/old/index.html"
}
output "$work/redirect" /
redirect "$work/redirect" / /docs/#intro
sed -i 's|run doctor.sh|<a href="/old/#step">old</a>|' "$work/redirect/index.html"
"$site/check.sh" "$work/redirect" / >/dev/null 2>&1 || fail "a correct redirect page does not pass"
rm -rf "$work/redirect"
expect_fault redirect-missing-target / \
  'mkdir -p old && printf "%s" "<meta http-equiv=\"refresh\" content=\"0; url=/gone/\"><meta name=\"robots\" content=\"noindex\">" >old/index.html' "old/index.html (base /) redirects to /gone/, which is not in the output"
expect_fault redirect-missing-place / \
  'printf "%s" "<meta http-equiv=\"refresh\" content=\"0; url=/docs/#none\"><meta name=\"robots\" content=\"noindex\">" >redirect.html' "redirects to /docs/#none, which is not on that page"
expect_fault redirect-unmapped-anchor / \
  'mkdir -p old && printf "%s" "<script>var map = {\"step\":\"/docs/#intro\"};</script><meta http-equiv=\"refresh\" content=\"0; url=/docs/#intro\"><meta name=\"robots\" content=\"noindex\">" >old/index.html && sed -i "s|run doctor.sh|<a href=\"/old/#other\">o</a>|" index.html' "links to /old/#other, which its redirect does not map"

# The list of the inputs (check-inputs.conf): a list that names every path
# the pages name as 'exists', and every file outside website/ that a source
# reads, passes; a path the pages name or a file a source reads that it
# leaves out, an 'exists' that no page names, and a malformed line fail.
# scripts/verify.conf names the list as the inputs of the website check.
output "$work/inputs" /
sed -i 's|doctor.sh|./scripts/status.sh and doctor.sh|' "$work/inputs/index.html"
reads="$(grep -Ev '^[[:space:]]*(#|exists[[:space:]]|$)' "$site/check-inputs.conf")"
[[ -n "$reads" ]] || fail "inputs: check-inputs.conf lists no file that a source reads"
printf '%s\n' "# inputs" "$reads" "exists docs/workflow.md" "exists scripts/doctor.sh" "exists scripts/status.sh" >"$work/inputs.conf"
WEBSITE_CHECK_INPUTS="$work/inputs.conf" "$site/check.sh" --inputs "$work/inputs" >/dev/null 2>&1 ||
  fail "inputs: a complete list does not pass: $(WEBSITE_CHECK_INPUTS="$work/inputs.conf" "$site/check.sh" --inputs "$work/inputs" 2>&1)"
# expect_inputs_fault <name> <list> <message>
expect_inputs_fault() {
  local result
  printf '%s\n' "$2" >"$work/inputs-$1.conf"
  if result="$(WEBSITE_CHECK_INPUTS="$work/inputs-$1.conf" "$site/check.sh" --inputs "$work/inputs" 2>&1)"; then
    fail "inputs: $1: check.sh passed"
  elif ! grep -Fq "$3" <<<"$result"; then
    fail "inputs: $1: no '$3' in: $result"
  fi
}
expect_inputs_fault missing-script "$(grep -v 'scripts/status.sh' "$work/inputs.conf")" \
  "does not list scripts/status.sh, which index.html names: add 'exists scripts/status.sh'"
expect_inputs_fault missing-link "$(grep -v 'docs/workflow.md' "$work/inputs.conf")" \
  "does not list docs/workflow.md, which index.html names"
expect_inputs_fault stale "$(cat "$work/inputs.conf"; echo "exists scripts/verify.sh")" \
  "lists 'exists scripts/verify.sh', which no page names: remove it"
first_read="$(head -n 1 <<<"$reads")"
expect_inputs_fault missing-read "$(grep -Fxv "$first_read" "$work/inputs.conf")" \
  "does not list $first_read, which a source of the site reads"
expect_inputs_fault malformed "$(cat "$work/inputs.conf"; echo "exist scripts/doctor.sh")" \
  "neither '<path>' nor 'exists <path>': exist scripts/doctor.sh"
grep -Eq '^inputs: website( [^ ]+)* website( [^ ]+)* @website/check-inputs\.conf( |$)' "$site/../scripts/verify.conf" ||
  fail "inputs: scripts/verify.conf does not name website/ and check-inputs.conf as the inputs of the website check"
rm -rf "$work/inputs"

# The tokens: a style sheet that names only tokens passes; a literal font,
# spacing or colour value outside :root and @font-face is reported.
tokens="$work/tokens.css"
printf '%s\n' '@font-face { font-family: "F"; font-weight: 400; src: url(f.woff2); }' \
  ':root { --ink: #141617; --t-sm: 0.9rem; --s-2: 0.5rem; --w-bold: 700; }' \
  '@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ink: #e9ebec; } }' \
  '/* padding: 1rem; color: #fff */' \
  'a:hover { color: var(--ink); border: 1px solid var(--ink); }' \
  'p { font: var(--w-bold) var(--t-sm)/var(--t-sm) var(--sans); margin: 0 auto; padding: var(--s-2) 0; }' >"$tokens"
"$site/check.sh" --tokens "$tokens" >/dev/null 2>&1 || fail "a style sheet of tokens does not pass"
for literal in 'line-height: 1.6' 'padding: 0.3rem var(--s-2)' 'font: 700 var(--t-sm) var(--sans)' 'font-weight: 600' \
  'letter-spacing: -0.02em' 'gap: 4px' 'color: #00804a' 'background: rgb(0, 0, 0)'; do
  printf 'b { %s; }\n' "$literal" >"$work/literal.css"
  if result="$("$site/check.sh" --tokens "$work/literal.css" 2>&1)"; then
    fail "tokens: '$literal' passed"
  elif ! grep -Fq "sets '$literal', which is not a token" <<<"$result"; then
    fail "tokens: no report of '$literal' in: $result"
  fi
done

# The browser: check.sh --browser installs Chromium only when it is missing,
# and reports an install that fails or a browser that does not start. npx is
# replaced by a fake that records its arguments and fails like a run offline.
if [[ -d "$site/node_modules" ]]; then
  mkdir -p "$work/bin" "$work/browsers"
  printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexit 1\n' "$work/npx.log" >"$work/bin/npx"
  chmod +x "$work/bin/npx"
  if (cd "$site" && node browser-ready.mjs) >/dev/null 2>&1; then
    : >"$work/npx.log"
    PATH="$work/bin:$PATH" "$site/check.sh" --browser >/dev/null 2>&1 || fail "an installed browser does not pass"
    [[ ! -s "$work/npx.log" ]] || fail "an installed browser is installed again: $(cat "$work/npx.log")"
  else
    echo "check-test: no Playwright Chromium here; the check of an installed browser is skipped." >&2
  fi

  : >"$work/npx.log"
  if result="$(PLAYWRIGHT_BROWSERS_PATH="$work/browsers" PATH="$work/bin:$PATH" "$site/check.sh" --browser 2>&1)"; then
    fail "a missing browser that cannot be installed passed"
  elif ! grep -Fq "could not be installed; it needs network access" <<<"$result"; then
    fail "missing browser: no clear message in: $result"
  fi
  grep -Fxq -- "--no-install playwright install chromium" "$work/npx.log" || fail "a missing browser is not installed"

  # A browser whose system libraries are missing fails to start like this one.
  executable="$(sed -n 's/.*is not installed (no \(.*\))\.$/\1/p' <<<"$result")"
  if [[ -n "$executable" ]]; then
    mkdir -p "$(dirname "$executable")"
    printf '#!/bin/sh\necho "chrome: error while loading shared libraries: libnss3.so: cannot open shared object file" >&2\nexit 127\n' >"$executable"
    chmod +x "$executable"
    : >"$work/npx.log"
    if result="$(PLAYWRIGHT_BROWSERS_PATH="$work/browsers" PATH="$work/bin:$PATH" "$site/check.sh" --browser 2>&1)"; then
      fail "a browser that does not start passed"
    elif ! grep -Fq "does not start" <<<"$result" || ! grep -Fq "libnss3.so" <<<"$result" ||
      ! grep -Fq "playwright install-deps chromium" <<<"$result"; then
      fail "browser without libraries: no clear message in: $result"
    fi
    [[ ! -s "$work/npx.log" ]] || fail "a browser that does not start is installed again"
  else
    fail "missing browser: no executable path in: $result"
  fi
else
  echo "check-test: no node_modules in $site; the browser checks are skipped." >&2
fi

# browser-check.mjs on small outputs of two pages: the page matrix over
# parallel contexts keeps its counts and names the page, the theme and the
# width of a failure; the part 'pages', which the root base runs instead of
# the matrix, finds a hard-coded base path under either base.
# browser_page <file> <base> <extra>: a page that the matrix accepts.
browser_page() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>T</title>' \
    '<script>document.documentElement.dataset.theme = localStorage.getItem("act-theme") || "light";</script>' \
    '<style>body{margin:0;font:16px sans-serif;background:#fff;color:#111}html[data-theme=dark] body{background:#111;color:#eee}a,button{color:inherit;background:none;border:1px solid currentColor}.nav{display:flex;flex-wrap:wrap;gap:4px}</style></head><body>' \
    "<header class=\"top\"><nav class=\"nav\" aria-label=\"Site\"><a href=\"$2\">Home</a><a href=\"$2#main\">Features</a><a href=\"$2#main\">About</a><a href=\"$2docs/\">Docs</a><a href=\"https://github.com/\">GitHub</a><button class=\"theme\" type=\"button\">Theme</button></nav></header>" \
    "<main id=\"main\"><h1>Page</h1><p>Text.</p>$3</main>" \
    "<footer><nav aria-label=\"Footer\"><a href=\"$2\">Open source · MIT</a><a href=\"$2\">GitHub / Source</a><a href=\"$2\">Contributing</a><a href=\"$2\">Security policy</a><a href=\"$2docs/\">Technical Documentation</a></nav></footer></body></html>" >"$1"
}

# browser_output <dir> <base>: an output of a home page and a docs page.
browser_output() {
  browser_page "$1/index.html" "$2" ""
  browser_page "$1/docs/index.html" "$2" ""
}

# browser_run <dir> <base> <parts>: runs browser-check.mjs on the output, with two contexts.
browser_run() {
  (cd "$site" && DOCUMENTATION_REPORT_DIR="$1/reports" BROWSER_CHECK_WORKERS=2 node browser-check.mjs "$1" "$2" "$3")
}

# expect_browser_fault <name> <base> <parts> <file> <extra> <message>:
# the part fails on the output with <extra> in <file>, and says <message>.
expect_browser_fault() {
  local dir="$work/browser-$1" result
  browser_output "$dir" "$2"
  browser_page "$dir/$4" "$2" "$5"
  if result="$(browser_run "$dir" "$2" "$3" 2>&1)"; then
    fail "browser $1: browser-check.mjs passed"
  elif ! grep -Fq -- "$6" <<<"$result"; then
    fail "browser $1: no '$6' in: $result"
  fi
}

if [[ -d "$site/node_modules" ]] && (cd "$site" && node browser-ready.mjs) >/dev/null 2>&1; then
  for base in /agent-codeyard/ /; do
    dir="$work/browser-good$(tr -d / <<<"$base")"
    browser_output "$dir" "$base"
    if ! result="$(browser_run "$dir" "$base" pages,matrix 2>&1)"; then
      fail "browser: a correct output under $base does not pass: $result"
    else
      # Two pages in two themes at six and at five widths: 22 cells, each
      # with its axe result and its screenshot, in the order of a run in one
      # context (page, theme, width), as on main; one page report per page.
      order="$(node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1])); console.log([...r.accessibility.map(c => `${c.path} ${c.theme} ${c.width}`), ...r.screenshots, ...r.pages.map(p => p.path)].join("\n"))' \
        "$dir/reports/$([[ "$base" == / ]] && echo root || echo project)/report.json")"
      expected="$(for page in docs/ ''; do for theme in light dark; do
        if [[ -n "$page" ]]; then widths="320 390 768 1280 1440"; else widths="320 375 390 768 1280 1440"; fi
        for width in $widths; do echo "$base$page $theme $width"; done; done; done
        for page in docs ''; do for theme in light dark; do
        if [[ -n "$page" ]]; then widths="320 390 768 1280 1440"; else widths="320 375 390 768 1280 1440"; fi
        for width in $widths; do echo "${page:-index}-$theme-$width.png"; done; done; done
        echo "${base}docs/"; echo "$base")"
      [[ "$order" == "$expected" ]] || fail "browser: the report under $base is not the matrix in its order: $(diff <(echo "$expected") <(echo "$order") | head -n 5)"
      # The whole summary line; the Pages base of the real output, with the
      # keyboard checks, prints the line of main (check.sh asserts it).
      grep -Fxq "browser-check: 2 pages, both themes, five or six widths; 0 redirect pages; the parts pages, matrix passed ($base)." <<<"$result" ||
        fail "browser: no summary line under $base in: $result"
    fi
  done

  # A failure in one cell of the parallel matrix fails the check and names
  # the page, the theme and the width: here the docs page in the dark theme
  # at 320 px only.
  expect_browser_fault matrix-cell /agent-codeyard/ matrix docs/index.html \
    '<style>@media (max-width: 330px) { html[data-theme=dark] main { width: 1000px; } }</style>' \
    "/agent-codeyard/docs/ dark 320 px: Horizontal overflow"

  # Hard-coded paths that only the Pages base shows: an asset under '/' and
  # an absolute /docs/ link.
  expect_browser_fault asset-under-root /agent-codeyard/ pages index.html \
    '<link rel="stylesheet" href="/s.css">' "/agent-codeyard/ at 390 px: /s.css answers 404"
  expect_browser_fault absolute-docs-link /agent-codeyard/ pages index.html \
    '<a href="/docs/">docs</a>' "links to /docs/, which is outside the base path /agent-codeyard/"
  # Hard-coded paths that only the root shows, which the root base, without
  # the matrix, still finds: a route that a script writes for the Pages
  # base, and an asset of the base joined with a second slash.
  expect_browser_fault route-assumes-base / pages docs/index.html \
    '<script>document.querySelector("main").insertAdjacentHTML("beforeend", "<a href=\"/agent-codeyard/docs/\">docs</a>")</script>' \
    "/docs/ at 390 px: links to /agent-codeyard/docs/, which is not in the output"
  expect_browser_fault double-slash-asset / pages index.html \
    '<img src="//fonts/f.png" alt="">' "/ at 390 px: requests http://fonts/f.png, which is not on the site"
else
  echo "check-test: no Playwright Chromium here; the checks of browser-check.mjs are skipped." >&2
fi

# The website check of scripts/verify.conf runs npm ci only when the install
# is missing or older than package-lock.json. It runs here in a copy with a
# recording npm and check scripts that only pass.
website_check="$(sed -n 's/^website: *//p' "$site/../scripts/verify.conf" 2>/dev/null || true)"
if [[ -n "$website_check" ]]; then
  copy="$work/install"
  mkdir -p "$work/install-bin"
  printf '#!/bin/sh\necho "$*" >>"%s"\n' "$work/npm.log" >"$work/install-bin/npm"
  chmod +x "$work/install-bin/npm"

  # install_state: the state of the install in the copy, as install_fixture
  # names it, from the files alone.
  install_state() {
    local w="$copy/website" lock="$copy/website/node_modules/.package-lock.json"
    if [[ ! -e "$w/node_modules" ]]; then echo missing
    elif [[ ! -f "$lock" ]]; then echo "no lock"
    elif [[ "$lock" -ot "$w/package-lock.json" ]]; then echo older
    elif [[ "$lock" -nt "$w/package-lock.json" ]]; then echo current
    else echo "same age"
    fi
  }

  # install_fixture <state>: writes a new copy with check scripts that only
  # pass and an install in that state: missing, no lock, older, current or
  # same age.
  install_fixture() {
    rm -rf "$copy"
    mkdir -p "$copy/website"
    : >"$copy/website/.codeyard-site"
    printf '#!/bin/sh\nexit 0\n' >"$copy/website/check-test.sh"
    cp "$copy/website/check-test.sh" "$copy/website/check.sh"
    chmod +x "$copy/website/check-test.sh" "$copy/website/check.sh"
    : >"$copy/website/package-lock.json"
    touch -t 200001020000 "$copy/website/package-lock.json"
    [[ "$1" == missing ]] && return 0
    mkdir "$copy/website/node_modules"
    [[ "$1" == "no lock" ]] && return 0
    : >"$copy/website/node_modules/.package-lock.json"
    case "$1" in
      older) touch -t 200001010000 "$copy/website/node_modules/.package-lock.json" ;;
      current) touch -t 200001030000 "$copy/website/node_modules/.package-lock.json" ;;
      "same age") touch -t 200001020000 "$copy/website/node_modules/.package-lock.json" ;;
    esac
  }

  # install_case <state> <yes|no>: runs the check on an install in that state
  # and reports when npm ci does not run as expected, or the state is not the
  # one the case names before and after the run.
  install_case() {
    local state="$1" expected="$2" ran=no
    install_fixture "$state"
    [[ "$(install_state)" == "$state" ]] || { fail "$state: the fixture is $(install_state)"; return 0; }
    rm -f "$work/npm.log"
    (cd "$copy" && PATH="$work/install-bin:$PATH" bash -eo pipefail -c "$website_check") >"$work/install.out" 2>&1 ||
      { cat "$work/install.out" >&2; fail "$state: the website check fails"; return 0; }
    [[ -f "$work/npm.log" ]] && grep -Eq '^ci( |$)' "$work/npm.log" && ran=yes
    [[ "$ran" == "$expected" ]] || fail "$state install: npm ci runs: $ran, expected: $expected"
    [[ "$(install_state)" == "$state" ]] || fail "$state: the run changes the fixture to $(install_state)"
  }

  install_case missing yes
  install_case "no lock" yes
  install_case older yes
  install_case current no
  install_case "same age" no
fi

if [[ "$failures" -gt 0 ]]; then
  echo "check-test: $failures failure(s)." >&2
  exit 1
fi
echo "check-test: passed."
