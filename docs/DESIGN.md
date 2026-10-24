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

- Hover: 150ms ease-standard
- State change: 200ms ease-standard
- Page transition: 300ms ease-out
- Easing: cubic-bezier(0.2, 0, 0, 1) standard, cubic-bezier(0, 0, 0.2, 1) out
- No bouncy easings. No scale-on-hover. No shadow changes on hover.

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

- Forbidden: purple gradient hero backgrounds; emoji icons in CTAs; the word "AI" in body copy; auto-scale on hover; bouncy easings; heavy shadows; pure black backgrounds
- No scale-on-hover, no shadow change on hover
- Cards have no shadow by default
- Inputs use focus rings, not border-only changes
- Scrollbars are thin (8px) and subtle