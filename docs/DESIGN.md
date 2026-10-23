# DESIGN.md — Kuvo Code (harness UI)

A clean, product-oriented design system for a code-agent interface.
Near-monochrome, information-dense, micro-interactions, restrained accent.
Adapted from the Open Design "Neutral Modern" + "Linear" aesthetic.

## 01 · Color

OKLch-inspired palette with semantic role names. Light default, dark via `prefers-color-scheme`.

- Background: `#fafafa` (`--bg`), Surface: `#ffffff` (`--panel`), Surface 2: `#f5f5f3` (`--panel-2`), Code: `#f1f1ee` (`--code-bg`)
- Foreground: `#111111` (`--ink`), Secondary: `#5a5a5a` (`--ink-soft`), Faint: `#9a9a9f` (`--ink-faint`)
- Border: `#e5e5e5` (`--line`), Border soft: `#efefec` (`--line-soft`)
- Accent: `#2a66d8` cobalt (`--accent`) — primary CTAs, links, one hero element per screen. Never on gradients.
- Semantic: Success `#168f45`, Warn `#c89600`, Danger `#dc2626` (each with a `-soft` variant at 12% opacity)
- Dark mode: background `#0a0a0a`, panel `#141414`, ink `#ececec`, accent `#6f9dff`
- Never pure black; never pure white for backgrounds.

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

- Cobalt accent (#2f6feb) — used sparingly: primary CTAs, links, one hero element per screen
- Never on gradients
- Clear space around logo: ≥ 8px

## 09 · Anti-patterns

- Forbidden: purple gradient hero backgrounds; emoji icons in CTAs; the word "AI" in body copy; auto-scale on hover; bouncy easings; heavy shadows; pure black/white backgrounds
- No scale-on-hover, no shadow change on hover
- Cards have no shadow by default
- Inputs use focus rings, not border-only changes
- Scrollbars are thin (8px) and subtle