# DESIGN.md — Kuvo Code (harness UI)

A clean, product-oriented design system for a code-agent interface.
Near-monochrome, information-dense, micro-interactions, restrained accent.
Adapted from the Open Design "Neutral Modern" + "Linear" aesthetic.

## 01 · Color

The Mac's own palette, bound in `windows/harness/ui/style.css`; light by default, dark via
`prefers-color-scheme` or `data-theme="dark"`. Every ink is measured against every surface by
`node windows/tools/contrast-check.mjs` (WCAG 2.1 AA, 4.5:1), including the narrow-window palette.

- Background: `#F6F4EE` (`--bg`), Surface: `#FFFFFF` (`--panel`), Surface 2: `#F9F7F1` (`--panel-2`), Code: `rgba(15, 23, 42, 0.035)` over the panel (`--code-bg`)
- Foreground: `#1D1D1F` (`--ink`), Secondary: `rgba(29, 29, 31, 0.70)` (`--ink-soft`), Faint: `rgba(29, 29, 31, 0.62)` (`--ink-faint`)
- Border: `rgba(15, 23, 42, 0.07)` (`--line`), Border soft: `rgba(15, 23, 42, 0.05)` (`--line-soft`)
- Accent: `#0062CC` cobalt (`--accent`, hover `#0051A8`) — primary CTAs, links, one hero element per screen. Never on gradients.
- Semantic: Success `#1E7B34`, Warn `#9A5B00`, Danger `#C4271E` (each with a `-soft` variant)
- Dark mode: background `#131417`, panel `#181A1F`, panel 2 `#202228`, ink `#F5F5F7`, accent `#2F97FF`
- Narrow windows (≤760 px): background `#F6F4EE`, secondary `#6B6B6B`, faint `#67676C`, accent `#1F5FD6`
- Never pure black. The light canvas is warm ivory; white is a card on it, not the ground.

## 02 · Typography

- Display / headings: Inter, weight 600, letter-spacing -0.01em on ≥20px
- Body: Inter, weight 400
- Mono: ui-monospace, Cascadia Mono, JetBrains Mono, Menlo
- Scale (px): 11 · 12 · 13 · 14 · 16 · 20 · 24
- Line-height: 1.5 body, 1.2 headings
- Variable font axes honored where available

## 03 · Spacing

- Base unit: 8px. Scale: 4 · 8 · 12 · 16 · 20 · 24 · 32
- Prefer larger for vertical rhythm, smaller for inline gaps
- Component internal padding: 12-16px; section gaps: 24-32px

## 04 · Layout

- Sidebar: 260px fixed. Main: flex. Drawer: 440px.
- Container max: 900px for conversation entries
- Grid: 2-column (sidebar + main) on desktop
- Breakpoints: not explicitly defined; fluid with min-widths

## 05 · Components

- Buttons: 6px radius, 5px 10px padding. Primary = cobalt fill. Secondary = 1px border, transparent. Hover: border darkens, background panel-2.
- Cards (tool, ask): 8px radius, 1px border, white bg, no shadow by default. Hover: border darkens.
- Inputs: 6px radius, 1px border. Focus: cobalt border + 2px accent-soft ring.
- Modals: 12px radius, shadow 0 16px 48px, fade+scale animation 200ms.
- Drawer: slide-in from right, 440px, backdrop blur.

## 06 · Motion

The Mac binding in `windows/harness/ui/style.css` is the source of truth.

- Hover and small answers: 120ms (`--motion-hover`, `--motion-quick`), ease-out
- State change: 320ms (`--motion-base`)
- The spring: 450ms, the Mac's `.spring(response: 0.32, dampingFraction: 0.86)`
  written as a `linear()` curve — a little past 1, then home
- Press is a fill, never a squeeze: 8% under the pointer and 13% while it is
  down (`--press-hover`, `--press-active`)

What moves: chrome-less controls fill; marks lean or turn a pixel or two toward
what they do; the row in use grows a 2px accent bar; menus arrive as one piece
with their items following in a 14ms run; a Settings page pushes in 4px; the
search well deepens; the primary action lifts 1px; links underline from the
left; a copy says “Copied” with the Mac's check; the toast stack keeps three,
newest in front, and opens under the pointer; a working session's dot breathes.

Find and the tree: every match is marked in the words, the one you are on in
the accent; the arrows step the marks themselves, not just the message; the
bar slides down over the card and the count pops when it changes; the file
tree's rows fade in as folders open and their chevrons turn; a search result's
snippet shows the matched words.

Ask in place: a destructive action asks in its own row — “Keep” takes the
focus first, Escape or moving the focus away leaves things as they were — never
in a system dialog over the page. The toast shows its time left as a line under
it that stops while the stack is held open.

Reduced motion: “Motion: Reduced” sets the tokens to 1ms and
`html[data-motion="reduced"]` stops the hard-coded loops (the working dot, the
skeleton shimmer, the menu stagger, the toast's countdown line). The system's
`prefers-reduced-motion` does the same for the CSS animations.

## 07 · Voice

- Terse, technical, no marketing fluff
- No "amazing", "powerful", "incredible", "unleash"
- Error messages: what happened + what to do
- Button labels: verbs ("Save", "Send", "Stop", "Choose")

## 08 · Brand

- Cobalt accent (#0062CC) — used sparingly: primary CTAs, links, one hero element per screen
- Never on gradients
- Clear space around logo: ≥ 8px

## 09 · Anti-patterns

- Forbidden: purple gradient hero backgrounds; emoji icons in CTAs; the word "AI" in body copy; pure black backgrounds
- No scale on layout, rows or text; a mark may answer at 1.06–1.12, and the chosen swatch may grow
- A control's hover is a fill or a 1px lift, never a squeeze of the whole row
- Cards have no shadow by default; only the primary action and lifted surfaces gain one
- Inputs use focus rings, not border-only changes
- Scrollbars are thin (8px) and subtle