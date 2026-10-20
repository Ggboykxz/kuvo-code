# The Mac UI, mapped — Phase 0 ledger

**Status: Phase 0, extraction complete** (2026-10-20, at `4340961`, `windows-v0.5.36`).
Source of truth: the Mac app's own Swift, `KuvoCode/`. The exhaustive raw inventory is
[`MAC-UI-INVENTORY.md`](MAC-UI-INVENTORY.md), generated from that source by
`windows/tools/mac-ui-inventory.mjs`. This document is the hand-written registry: what each
piece is for, the exact values it uses, what the Windows client does today, and which phase
closes the gap.

Nothing here is a redesign. It is the Mac, value by value. Where a Mac value cannot exist on
Windows (SF Symbols, `.regularMaterial`, the macOS system accent), the row says so and names
the equivalent.

## How to read a row

Behaviour and look are two separate promises, so each row has two marks:

| Mark | Behaviour | Look |
| --- | --- | --- |
| ✅ | ported, same wording and same effect | the Mac's exact value |
| ◐ | ported, but a piece is missing or different | present, but the Mac's value is not applied yet |
| ⬜ | absent | not built |
| ⛔ | excluded: upstream surface, or secrets (decided) | no Windows surface |
| — | no behaviour to port | no visual surface |

The phase says when the look is expected to reach ✅. A look mark of ◐ is the default for
every screen in this port today: the Windows app is bound to a different visual system (§1),
so *no screen* is at ✅ until Phase 1 and Phase 2 land, however close a screenshot looks.

Extraction totals: 27 design files, 74 view files, 23 Settings pages, **89 SF Symbols in 238
uses**, **261 motion call sites**, **1 208 user-facing string sites (933 distinct)**, 6
Shape/Canvas declarations plus the drawn avatar faces, 20 view files deliberately excluded.

---

## 1. The finding that resets the look

The Windows client was bound to **OpenDesign's `modern-minimal` direction** until 0.5.36, not
to the Mac's design:

- `windows/harness/ui/DESIGN.md:7` — *"Source: OpenDesign's design direction `modern-minimal`"*
  (replaced in Phase 1 by the Mac's own design layer).
- `DESIGN.md:10` — *"The Mac app's structure and wording are unchanged — only the look moves to
  this system."* (the retired sentence).
- `docs/PARITY.md:120` — *"The view is bound to OpenDesign's design direction `modern-minimal`"*
  (replaced in Phase 1).

That was a deliberate reinterpretation, and it is the opposite of the current brief: reproduce
the Mac's UI, UX, motions, design and icons *à la lettre près*. The difference is not a few
colours; it is a different system — cool flat neutrals, 8/12 px radii, hairline borders and no
shadows, against the Mac's warm ivory canvas, opaque cards at 14 px, specular rims, soft
shadows, and accent glass.

| # | Element | Mac (source) | Windows before Phase 1 (0.5.36) | Phase |
| ---: | --- | --- | --- | --- |
| 1 | Light canvas | `#F6F4EE` at 86 % over `.regularMaterial`, warm-to-cool ambient (`Surfaces.swift:28-55`) | `oklch(99% 0.002 240)` flat, indigo/teal radial washes (`style.css:14-17`) | 1 |
| 2 | Dark canvas | white 6 % at 25 % over material, ambient 6 % (`Surfaces.swift:28-55`) | `#08090a` flat, indigo/teal washes (`style.css:137-141`) | 1 |
| 3 | Cards | Opaque; white (focused) / `#F9F7F1` (unfocused) light, `#181A1F` / `#202228` dark; radius 14; shadow 16/6; specular rim (`Surfaces.swift:59-72`, `Card.swift:30-44`) | Flat `--surface` / `--panel-2`, radius 8, 1 px border, no shadow (`style.css:241-251`) | 1, 2 |
| 4 | Card header | 38 pt, icon 16, title 13 semibold, truncation middle, 62 pt fade under it (`Card.swift:70-125`) | Flat row of buttons, no fade (`style.css:234-238`) | 2 |
| 5 | Window gaps | 8 pt between cards and at the edges; cards float on the glass (`Theme.swift:16`, `MainView.swift:272-284`) | Full-height strips meeting at 1 px borders | 2 |
| 6 | Composer | **Opaque** `cardFill`, radius 14, shadow 8/2 (light) or 3/1 (dark), specular rim, 1 px black 10 % edge (`Composer.swift:489-511`) | Glass, `blur(28px)`, radius 12, border (`style.css:225-231`) | 2 |
| 7 | Your message | Accent glass, radius 18, accent 10 % (light) / 22 % (dark), edge white 85 % → accent 25 %, padding 14/10, leading 80 (`TranscriptView.swift:600-681,1500-1513`) | Accent 9 %, radius 12, `blur(14px)`, 1 px accent border, inset white (`style.css:432-444`) | 1, 2 |
| 8 | Materials | Only the **window** is material; cards, composer, sheets and palette are opaque (`WindowGlass.swift:23-39`) | Glass on header, sidebar, composer, drawer, settings card (`style.css:218-231`) | 2 |
| 9 | Radii | 14 card/composer, 18 bubble/palette, 10 well field, 8 sidebar row, 7 list row, 6 button/icon button, 5 text button | 8 card, 12 large, 6 small, 4 xs, pill (`style.css:50-55`) | 1 |
| 10 | Shadows | Cards 16/6 (focused) and 6/2; composer 8/2; palette lifted | `--shadow-card: none`; shadows only on floating layers (`style.css:56-58`) | 1, 2 |
| 11 | Motion | Spring `response 0.32, damping 0.86`; hover `easeOut 0.12`; no press scale (`Theme.swift:21-31`, `Pressable.swift:8-9,56-70`) | 320 ms `cubic-bezier(0.34, 1.3, 0.64, 1)`; hover 200 ms; press `scale(0.97)` (`style.css:60-66,253-270`) | 3 |
| 12 | Type | Message 14 (13 / 14 / 15.5 / 17), four typefaces; code size −1.5; header 13 semibold (`Look.swift:48-83`, `Card.swift:108`) | 13 base / 14 md; system only; header weights mixed (`style.css:69-80`) | 1 |
| 13 | Accent | macOS system accent by default, 9 presets, any `#RRGGBB` (`Look.swift:12-39`) | Cobalt `#2f6feb`; 9 presets exist, "system" is titled "Default" not "macOS Accent"; no custom hex | 1 |
| 14 | Icons | 89 SF Symbols, 238 uses, plus 6 Shape/Canvas declarations and the drawn avatar faces (`MAC-UI-INVENTORY.md` §3, §6) | A mix of text glyphs, two drawn SVGs, and SF-symbol names in labels | 4 |
| 15 | Header | Session **tabs**, project identity, traffic-light inset, Hide Sessions / Hide Panel, split (`TitleBar.swift:218-251,579-599`) | Flat row: Files / Hide sessions / Split / `@` / Appearance / Export, find field always on (`App.tsx`) | 2, 6 |
| 16 | Sidebar | One search well, project tree, 32 pt rows, 18 pt icons, unread and bot avatars (`SidebarView.swift:675-726`) | Two stacked search fields; flat list (`App.tsx`) | 2, 6 |

**After 0.5.40:** rows 1–13 and 15–16 are bound to the Mac's values — the cards and their
gaps (0.5.38), the materials, the header's tabs and the palette (0.5.39), and the motion
(0.5.40). Row 14, the icons, and the rest of Phase 6 (the screens) remain. The table is the
baseline the release is measured against, not a description of the current page.

**The verification is a measurement, not a picture.** `windows/harness/verify.test.mjs` reads
the rendered page in a browser and holds it to the numbers in §2 and §3; the matrix of
captures is in `docs/captures/`, written by `windows/harness/captures.mjs`.

**The wording is finished with the screens it lives in.** The shell's strings are the Mac's,
word for word, and a check holds them to the Mac's own source
(`windows/wording.test.mjs`); the rest follow the screens they belong to, in Phase 6.

**The platform moved, the look did not.** Since 0.5.41 the window is built by Next.js (a
static export the harness serves), and the page is read in a real browser in CI. That changes
how the app is built and tested, not what it looks like: the Mac's stylesheet, tokens and
components are the ones the App Router renders. The reasoning is in
[`windows-port.md`](windows-port.md) §2.24.

**Decision, taken and executed in Phase 1.** `DESIGN.md` is rewritten around the Mac's own
system — `Theme.swift`, `Look.swift`, `Surfaces.swift`, `Card.swift`, `WindowGlass.swift` — and
the Mac binding block at the end of `style.css` takes its values from that document. Phase 2
merges the block into the components and deletes the old direction. `modern-minimal` stays
recorded only as the origin of the pre-Phase-1 CSS, not as the target. The 0.5.37 capture is
the first one measured against the Mac's design rather than the reinterpretation.

---

## 2. The window, as the Mac lays it out

The Mac window is **cards floating on glass**, not panels meeting at borders. The window itself
is a material (or a solid colour in Settings › Appearance); every pane is an opaque card with a
14 pt radius and a soft shadow, separated by 8 pt of the material showing through.

| Element | Mac value | Evidence | Windows today | Phase |
| --- | --- | --- | --- | --- |
| Window background | `.regularMaterial` + canvas tint + ambient; solid mode: `#F2F0EA` / `#131417` + ambient | `WindowGlass.swift:23-39`, `Surfaces.swift:28-55` | CSS background + two radial washes | 2 |
| Pane gap | 8 pt, between cards and at the edges | `Theme.swift:16`, `MainView.swift:272-284` | Grid with 1 px hairlines | 2 |
| Card | radius 14, opaque, shadow 16/6 focused · 6/2 unfocused, specular rim | `Card.swift:29-44`, `Theme.swift:9` | radius 8, border, no shadow | 1, 2 |
| Card header | height 38; leading 14 + controls inset; trailing 8 + panel inset; icon 16; title 13 semibold | `Card.swift:91-125`, `Theme.swift:11` | Flat header, no 38 pt bar | 2 |
| Header fade | card fill, 62 pt tall; stops 0 → 1, .6 → 1, .74 → .75, .88 → .3, 1 → 0 | `Card.swift:70-89` | none | 2 |
| Window controls inset | 26 pt above the first row when the tab bar is hidden | `Theme.swift:12-14` | none (frameless shell) | 2 |
| Readable column | 760 pt, centred; transcript gutter 20 pt | `Theme.swift:7,18`, `Theme.swift:160-165` | 760 px and 20 px already | ✅ |
| Sidebar row | 32 pt high, 18 pt icon column, radius 8, search well radius 8 | `SidebarView.swift:675-726` | Flat rows | 2, 6 |
| Title bar tab | capsule, height 30; tab tile 25 × 20; divider 1 × 16 | `TitleBar.swift:98-103,242-251,282` | Flat header row | 2, 6 |
| Utilities pane | card header 44 pt; tab pill radius 9; action 28 × 28 | `UtilitiesPane.swift:113-115,282-290` | Drawer with flat rows | 2, 6 |
| Settings page | card fill, radius 14, rim; page column 798 (700 + 2 × 49); title inset 49 | `SettingsView.swift:32-73,433-440` | Settings card, different widths | 2, 6 |
| Composer | radius 14, opaque; inner padding 16 / 10 / 7 | `Composer.swift:249-253,489-511` | radius 12, glass | 2 |
| Your message | radius 18; padding 14 / 10; leading 80; max width 680 of the 760 column | `TranscriptView.swift:613-681,1500-1513` | max-width 80 %, radius 12 | 2 |
| Palette | 600 wide; search 48; list padding 6; row 30; radius 18; regular glass | `CommandPalette.swift:81-111,165-168` | Palette card, different width/radius | 2, 6 |
| Context gauge | 12 pt ring, 24 pt pill, popover 320 wide with 16 pt padding | `ContextGauge.swift:25-31,156-157` | The Mac's: the ring, the pill, the popover, and orange past eight parts | 6 ✅ (0.5.44) |
| Image viewer | corner 10 when fitted, 0 when zoomed; capsule glass toolbar; toolbar max 560 | `ImageViewer.swift:90-91,200-206` | Exists; geometry to check | 6 |
| Pane resizer | 8 pt hit area; 3 pt tint capsule, 40 pt vertical inset, 50 % opacity on hover/drag; 0.15 s easeOut; `column-resize` cursor | `WindowGlass.swift:43-81` | No Mac-style grabber; pane widths are fixed | 2, 7 |

---

## 3. Tokens, exactly

### 3.1 Measurements (`Theme.swift:5-19`)

| Token | Value | Windows today | Phase |
| --- | ---: | --- | --- |
| `readableWidth` | 760 pt | 760 px ✅ | — |
| `composerRadius` | 14 | 12 | 1 |
| `cardRadius` | 14 | 8 | 1 |
| `cardHeaderHeight` | 38 | not 38 (flat header row) | 1, 2 |
| `windowControlsHeight` | 26 | 0 | 2 |
| `paneGap` | 8 | 1 px borders | 2 |
| `bubbleRadius` | 18 | 12 | 1 |
| `gutter` | 20 | 20 ✅ | — |

### 3.2 Colour (`Surfaces.swift`, `Look.swift`)

`slate` is `rgb(15, 23, 42)` = `#0F172A` (`Surfaces.swift:12`). It is the ink of every hairline
and well in light mode; the Mac does not use neutral gray for those.

| Role | Light | Dark | Evidence |
| --- | --- | --- | --- |
| Hairline outside a surface | slate 7 % | black 45 % | `Surfaces.swift:15-17` |
| Lit top edge | white 80 % | white 13 % | `Surfaces.swift:20-22` |
| Canvas tint | `#F6F4EE` 86 % | white 6 % at 25 % | `Surfaces.swift:28-32` |
| Canvas solid | `#F2F0EA` | `#131417` | `Surfaces.swift:35-37` |
| Ambient warm | `rgb(255, 158, 107)` at 7 % → 1.75 % | at 6 % → 1.5 % | `Surfaces.swift:41-55` |
| Ambient cool | `rgb(107, 140, 255)` at 1.75 % → 7 % | at 1.5 % → 6 % | `Surfaces.swift:41-55` |
| Card fill, focused | `#FFFFFF` | `#181A1F` (`0.094, 0.102, 0.122`) | `Surfaces.swift:65-71` |
| Card fill, unfocused | `#F9F7F1` (`0.976, 0.969, 0.945`) | `#202228` (`0.125, 0.133, 0.157`) | `Surfaces.swift:65-71` |
| Accent wash | accent 10 % | accent 22 % | `Surfaces.swift:75-77` |
| Well (code, search) | slate 3.5 % | black 30 % | `Surfaces.swift:80-82` |
| Well border | slate 7 % | white 7 % | `Surfaces.swift:85-87` |
| Specular rim | white 80 % at top → white 24 % at 12 % → clear at 45 %, 1 pt; hairline 0.5 pt inset −0.5 | white 13 % → 3.9 % → clear | `Surfaces.swift:115-146` |
| Accent glass edge | white 85 % → accent 25 %, 1 pt | white 20 % → accent 40 % | `Surfaces.swift:148-177` |

### 3.3 Type (`Look.swift:48-83`, `Card.swift:108`)

| Role | Mac | Windows today | Phase |
| --- | --- | --- | --- |
| Message default | 14 pt, system design | 14 px (`--text-md`) | ✅ |
| Message sizes | 13 (Small), 14 (Default), 15.5 (Large), 17 (Larger) | 13 / 14 / 16 (from `look.textSize`) | 1 |
| Typefaces | System, Rounded, Serif, Monospaced | System only | 1 |
| Code | message size − 1.5 pt, always monospaced | 0.9 em (≈12.6 at 14 px) | 1 |
| Card header | 13 semibold | Mixed | 1 |
| App UI | System font, AppKit sizes (13 body, 11 caption) | Segoe UI Variable | — |
| Menu chevron | 8 pt bold, secondary | Text glyph | 4 |
| Diff stat | caption, monospaced digits, medium | Exists | ✅ |

### 3.4 Radii, rims and shadows

| Element | Radius | Shadow | Evidence |
| --- | ---: | --- | --- |
| Card | 14 | light: slate 10 %, 16 pt radius, y 6 (focused) · slate 7 %, 6 pt, y 2; dark: black 36 % / 22 % | `Card.swift:37-44,127-133` |
| Composer | 14 | light black 7 %, 8 pt, y 2; dark black 25 %, 3 pt, y 1; 1 px black 10 % edge in light | `Composer.swift:495-510` |
| Your message | 18 | none (accent glass edge) | `TranscriptView.swift:1500-1513` |
| Well field | 10 | none, 12 / 9 padding, no focus ring | `Surfaces.swift:179-191` |
| Icon button | 6 | none, 24 × 22 | `Pressable.swift:13-25` |
| Card action | 6 | none, 26 × 24, icon 13 | `Card.swift:150-163` |
| List row | 7 (palette 8) | selected tint 16 %, pressed 24 % | `Pressable.swift:137-164`, `CommandPalette.swift:168` |
| Text button | 5 | 6 / 3 padding, outset option | `Pressable.swift:31-46` |
| Sidebar row | 8 | hover primary 6 %, selected accent glass | `SidebarView.swift:715-738` |
| Palette | 18 | regular glass + `.background` 75 % | `CommandPalette.swift:108-111` |
| Image viewer | 10 | none | `ImageViewer.swift:90-91` |
| Quote bar | 3 pt capsule, tint | none | `QuoteViews.swift:10-12` |

---

## 4. Components (`KuvoCode/Design/`, 27 files)

The design layer is the Mac's own component library. The Windows client has equivalents for
most behaviours but not for the values; Phase 1–4 port the values.

| File | What it is | Mac evidence | Windows | Phase |
| --- | --- | --- | --- | --- |
| `AgentPointer.swift` | The pointer the browser agent moves and clicks | arrow path 20 pt tall, glide `(0.3, 0, 0.2, 1)` 0.32 s, click pulse 0.5 s, other 1.2 s, delay 0.28, fade 0.35, linger 2.6 s | ⛔ browser surface | — |
| `BotAvatar.swift` | A bot's drawn body and face: 10 tints (mint `#5EC7B8`, sky, indigo, violet, pink, coral, orange, amber, lime, graphite), 5 forms, 6 faces | forms round/squircle/pebble/gem/bloom; faces calm/happy/sleepy/wink/curious/bright; `BotAvatar.swift:14-53,269,535,592` | ⛔ bots | — |
| `BotMotion.swift` | A bot's Core Animation cycle | idle 79.8 s (19 s noticed), working 42 s, waiting 4.8 s, news 46.8 s, watching 134.4 s, sleeping 50.4 s; sparks orbit 1.3 s | ⛔ bots | — |
| `Card.swift` | The window's building block | §2, §3.4; header double-click = title bar | ◐ | 2 |
| `Clipboard.swift` | Copy text, replacing the pasteboard | `Clipboard.swift:1-16` | ✅ (navigator.clipboard) | — |
| `CodeBlockStyle.swift` | One recessed well, line numbers, language, Copy | well + top-corner language/Copy; copy icon swaps to check via `contentTransition` | ◐ | 2, 4 |
| `CodeHighlighter.swift` | Prism.js tokenisation off the main thread | Prism bundled in Resources (MIT); tokens, not HTML, so lines keep exact text | ✅ behaviour (highlighting exists) | — |
| `FileDrop.swift` | Files dropped anywhere, text fields included | only active during a file drag; clicks pass through | ✅ | — |
| `Flow.swift` | Wrapping rows, leading or trailing | `Flow.swift:5-63` | ✅ (flex-wrap) | — |
| `FolderIcon.swift` | Drawn folder, closed or open | 16 × 13 grid, fill 20 %, stroke `size / 11.5`, round joins | ⬜ | 4 |
| `HoverHighlight.swift` | Flat control: no fill, 6 % hover, 8 % selected, 0.12 s | `HoverHighlight.swift:14-26` | ◐ (5 %, 200 ms) | 3 |
| `IconOnlyToolbar.swift` | AppKit toolbar without Icon/Text menu | `IconOnlyToolbar.swift:4-38` | — (no AppKit) | — |
| `InlineTitleField.swift` | Rename where it shows: all selected, Return commits, Escape cancels, click-away keeps | `InlineTitleField.swift:4-55` | ⬜ (a rename prompt exists) | 7 |
| `Look.swift` | Appearance: accent, window, text size, typeface | §3.2, §3.3 | ◐ | 1 |
| `NativeMenu.swift` | Real AppKit menus with values on the right and subtitles | `NativeMenu.swift:5-165` | ◐ (HTML menus; values differ) | 6 |
| `PillPicker.swift` | Glass track, raised pill slides to the choice | `.ui` spring, matched geometry | ◐ | 3, 6 |
| `PlainDatePicker.swift` | Date/time without a box, for a well row | `PlainDatePicker.swift:6-30` | ◐ (HTML input) | 6 |
| `Pressable.swift` | Every small control's hover/pressed language | hover 8 %, pressed 13 %, hover 0.12 s; list selected 16 %, pressed 24 %; disabled 45 %; accent badge hover 1.12 / −0.07, press −0.15 | ◐ (press scale 0.97 is not Mac) | 3 |
| `ProviderLogo.swift` | models.dev mark, monochrome or maker colour | 20 pt default; fallback initial 55 % size, semibold rounded | ◐ | 4 |
| `QuoteViews.swift` | "Replying to" card over the composer | 3 pt tint capsule; caption medium; 3 lines; remove button, `.help("Drop the quote")` | ◐ (behaviour ✅) | 2 |
| `RightClickMenu.swift` | One window-level right-click watcher, works in the title bar | `RightClickMenu.swift:4-65` | ✅ (HTML contextmenu) | 7 |
| `ScreenRoom.swift` | Room above/below for popovers that must stay on one side | `ScreenRoom.swift:4-33` | ⬜ | 7 |
| `ScrollFrameMonitor.swift` | Debug instrumentation for late frames and scroll cost | `ScrollFrameMonitor.swift` | — (diagnostic) | — |
| `Spinner.swift` | The prompt mark drawing itself in dashes | size 11, 1.6 s; dash `[line, 1.8 line]`, line `max(1, size × 0.11)`; chevron 0→0.4, cursor 0.32→0.6, hold, fade 0.78→1 | ⬜ | 3, 4 |
| `Surfaces.swift` | All materials in one place | §3.2 | ◐ | 1 |
| `Theme.swift` | Metrics, spring, shimmer, readable column, diff stat | §3.4; shimmer 1.6 s | ◐ | 1, 3 |
| `WindowGlass.swift` | Window material or solid + ambient; pane resizer | §2 | ◐ | 2 |

---

## 5. Motion

Every motion site is listed in `MAC-UI-INVENTORY.md` §4 (261 lines). This section gives the
values those sites use, and the conversion to CSS.

### 5.1 The default motion

`Theme.swift:21-31`:

```swift
static let ui: Animation = .spring(response: 0.32, dampingFraction: 0.86)
```

For a unit mass spring: stiffness `k = (2π / 0.32)² = 385.5`, damping
`c = 4π × 0.86 / 0.32 = 33.8`, natural frequency `ω₀ = 19.64 rad/s`, damped
`ω_d = 19.64 × √(1 − 0.86²) = 10.02 rad/s`. First overshoot:
`e^(−0.86π / √(1 − 0.86²)) = 0.5 %` — a fast settle with a barely visible give.

The Windows spring is now the Mac's own: the analytic solution, sampled as a CSS
`linear()` over 450 ms — the full settle (98 % by ~0.23 s) — with the true 0.5 % overshoot,
not a synthetic one (`--ease-spring`, `--motion-spring`; `windows/harness/ui/style.css`).
The components take the same spring as Motion's: stiffness 385.5, damping 33.8, mass 1
(`windows/app/src/motion.ts`), which is what moves the tab's pill from one tab to the next.
For interrupted transitions the browser retargets from the current value, which is the best
CSS equivalent of SwiftUI's velocity-preserving springs.

### 5.2 The catalogue

| Motion | Mac value | Where | Windows today | Phase |
| --- | --- | --- | --- | --- |
| Default (`ui`) | spring 0.32 / 0.86 | everywhere (`withAnimation(.ui)`, `animation(.ui, value:)`) | 450 ms over the analytic curve (0.5 % overshoot) | 3 ✅ |
| Hover | `easeOut(0.12)` | `HoverHighlight.swift:20`, `Pressable.swift:63,187,217`, `CodeBlockStyle` | 120 ms ease-out | 3 ✅ |
| Glass hover | `easeOut(0.15)` | `WindowGlass.swift:69` | 120 ms | 3 ✅ |
| Press | fill 13 %, no scale | `Pressable.swift:8-9,66-70` | fill 13 %, no scale | 3 ✅ |
| List selection | tint 16 %, pressed 24 % | `Pressable.swift:158-162` | accent wash 16 % | 3 ✅ |
| Disabled | opacity 45 % | `Pressable.swift:61` | mixed | 3, 6 |
| Palette / picks | `.ui` spring, matched geometry | `PillPicker.swift:22`, `CommandPalette` | the palette on the spring; the tab's pill slides with it | 3, 6 |
| Image viewer | open 0.16, close 0.14, `isOpen` 0.15 easeOut | `ImageViewer.swift` | 320 ms spring zoom (`style.css:1489`) | 6 |
| Count / copy icon | content transition, symbol effect replace | `CodeBlockStyle`, copy buttons | None | 4 |
| Reduced motion | Spinner still, shimmer off, bots still, transitions reduced | `Spinner.swift:19-24`, `Theme.swift:53`, `BotAvatar.swift:80` | the shimmer stops, the spinner stands still, transitions reduced | 3 ✅ |

### 5.3 Perpetual motion

| Motion | Exact | Evidence |
| --- | --- | --- |
| Shimmer ("Thinking…") | 1.6 s linear, loop; sweep 0.6 × text width, centre −0.9 w → 1.74 w; label ink at 90 %; in step across the screen | `Theme.swift:39-143` |
| Spinner | 1.6 s; 48 keyframes; chevron drawn 0→0.4, cursor 0.32→0.6, hold, fade 0.78→1; opacity 0.35 + 0.65 × fade; faint copy at 18 % ink; dash `[line, 1.8 line]`, line `max(1, size × 0.11)` | `Spinner.swift:15,40-55,129-143` |
| Working elapsed | 1 s timeline ("Working…" + elapsed) | `TranscriptView.swift:604-607` |
| Agent pointer | glide `(0.3, 0, 0.2, 1)` 0.32; click pulse 0.5 s / 1.2 s, delay 0.28; ring 1.4 s; fade 0.35; linger 2.6 s | `AgentPointer.swift:28-118` |
| Bot moods | idle 79.8 s @ 20 fps (noticed 19 s @ 30); working 42 s @ 30; waiting 4.8 s @ 30; news 46.8 s @ 30; watching 134.4 s @ 20 (noticed 42 s @ 20); sleeping 50.4 s @ 20 | `BotMotion.swift:154-168` |
| Bot sparks | orbit 1.3 s | `BotMotion.swift:258-279` |

The motion inventory's 261 sites are not 261 different animations. They are 261 places
that use one of the values above; the largest groups are `withAnimation` (127), `transition`
(52), `easeOut` (33), `.animation` (69), `contentTransition` (6), `matchedGeometryEffect` (4),
`symbolEffect` (4), `.spring` (3), `.snappy` (3), `timingCurve` (1), `easeInOut` (1).
A line can be counted in more than one group.

---

## 6. Screens (`KuvoCode/Views/`, 74 files)

The Mac's 74 view files. Status is behaviour / look. The Windows side is the React client at
0.5.36; "look ◐" means the screen exists but the Mac values are not applied yet (§1). The rows
below are grouped by area; the exhaustive list of all 74 files is in `MAC-UI-INVENTORY.md` §2.

### 6.1 Window and chrome

| Mac view | What it does | Windows | Phase |
| --- | --- | --- | --- |
| `MainView` | Tabs in the title bar, split view, three panes, focus per card | ✅ / ◐ | 2, 6 |
| `RootView` | Engine setup until running, then the workspace | ✅ / ◐ | 6 |
| `TitleBar` | Session tabs, project identity, hide/show, split, tab bar hidden option | ✅ / ◐ | 2, 6 |
| `SidebarView` | New Session, projects, sessions, search, unread, archived | ✅ / ◐ | 2, 6 |
| `SettingsView` | 23 pages in 5 groups, search, page header, in-window card | ◐ / ◐ | 2, 6 |
| `CommandPalette` | Actions, sessions, files, commands, shortcuts shown | ✅ / ◐ | 2, 6 |
| `OpenQuickly` | Find a file in any project folder | ✅ / ◐ | 6 |
| `AnalyticsNotice` | One-time anonymous-usage note at the sidebar's foot | ✅ / ◐ | 6 |
| `ImageViewer` | Pictures over the window, fit/zoom, toolbar | ✅ / ◐ | 6 |
| `ProjectEditor` | Create/change a project: name and folders | ◐ / ◐ | 6 |
| `ProvidersView` | Accounts and providers, connected or not | ✅ / ◐ | 6 |
| `CustomProviders` | Providers added by hand | ✅ / ◐ | 6 |
| `ConnectView` | Provider sign-in, browser or key | ⛔ secrets | — |
| `PaneResizer` (`WindowGlass.swift`) | Drag the gap to resize a card | ⬜ / ⬜ | 2, 7 |

### 6.2 Conversation

| Mac view | What it does | Windows | Phase |
| --- | --- | --- | --- |
| `TranscriptView` | The conversation, stick-to-bottom, rows, working line | ✅ / ◐ | 2, 6 |
| `YourMessage` | Message bubble + hover time/Copy/New Session/Undo | ✅ / ◐ | 2, 7 |
| `Composer` | Message field, modes, model, send/stop, attachments, quotes | ✅ / ◐ | 2, 6 |
| `ComposerMenus` | Mode/model menus, searchable, grouped by provider | ✅ / ◐ | 6 |
| `ModelPicker` | Effort levels ("xhigh" = Extra) | ✅ / ◐ | 6 |
| `QueueDock` | Waiting messages tucked behind the composer | ✅ / ◐ | 2, 6 |
| `ContextGauge` | Ring + number; popover: window, cost, compact | ✅ / ◐ | 2, 6 |
| `StepsRow` | Steps between replies, foldable summary | ✅ / ◐ | 6 |
| `AttentionCards` | Permission and form requests, Try Again | ✅ / ◐ | 6 |
| `ToolCallView` | One tool call, expandable details, sub-agent steps | ✅ / ◐ | 6 |
| `ShellRow` | A `!` command you ran, as a step | ✅ / ◐ | 6 |
| `DiffView` | A short diff in a recessed well | ✅ / ◐ | 2, 6 |
| `FindBar` | Find in one conversation, count, next/previous | ✅ / ◐ | 2, 6 |
| `QuoteList` | Quotes being answered, with your answer under each | ✅ / ◐ | 2, 6 |
| `SelectionMenu` | Add to Chat / Quote over a selection | ✅ / ◐ | 7 |
| `LongText` | Long text grows as you read; Show More / Show Less | ✅ / ◐ | 6 |
| `MathText` | `$…$`, `\(…\)`, `$$…$$`, `\[…\]` as math | ✅ / ◐ | 6 |
| `MarkdownChunks` | Long reply in chunks, each drawn on its own | ✅ / ◐ | 6 |
| `FileLinks` | Code naming a project file becomes a link | ✅ / ◐ | 6 |
| `ConversationScroll` | Stick to bottom, ↓ Latest when reading back | ✅ / ◐ | 6 |
| `AttachmentViews` | Attachments: kept, on their way, failed | ✅ / ◐ | 6 |
| `SessionView` | A session's error strip over the composer | ✅ / ◐ | 6 |
| `CodeTextView` | Read-only code, line numbers, selectable across lines | ✅ / ◐ | 6 |
| `ChangesPanel` | Uncommitted / unstaged / staged / branch / session | ✅ / ◐ | 2, 6 |
| `UtilitiesPane` | Right panel: Changes, Files, Terminal, Browser tabs | ✅ / ◐ | 2, 6 |
| `FilesView` | File tree, rendered file, highlighted or previewed | ✅ / ◐ | 6 |
| `TerminalSession` | Login shell in the project folder (ConPTY on Windows) | ✅ / ◐ | 6 |
| `WidgetView` | A page an agent made with `show_widget` | ⛔ browser surface | — |

### 6.3 Settings (23 Mac pages)

Mac pages in `SettingsView.swift:135-139`; Windows `PAGES` in `Settings.tsx:33-48`.

| Mac page | Windows page | Behaviour / look | Phase |
| --- | --- | --- | --- |
| General | General | ✅ / ◐ | 6 |
| Appearance | Appearance | ✅ / ◐ | 1, 6 |
| Notifications | — | ⬜ / ⬜ | 6 |
| Phone | — | ⛔ upstream | — |
| Shortcuts | Keyboard | ✅ / ◐ | 6 |
| Privacy | — | ⬜ / ⬜ | 6 |
| Storage | Engine & storage | ✅ / ◐ (merged) | 6 |
| Accounts | Providers | ✅ / ◐ | 6 |
| Usage | Usage | ◐ / ◐ (engine spend only; provider plans need keys) | 6 |
| Agents | Agents | ✅ / ◐ | 6 |
| Permissions | Permissions | ✅ / ◐ | 6 |
| Commands | Commands | ✅ / ◐ | 6 |
| Skills | Skills | ✅ / ◐ | 6 |
| Integrations | — | ⛔ OAuth secrets | — |
| MCP | MCP servers | ✅ / ◐ | 6 |
| Engine | Engine & storage | ✅ / ◐ (merged) | 6 |
| Git | Git | ✅ / ◐ | 6 |
| Worktrees | Projects | ◐ / ◐ | 6 |
| Archived | Archived sessions | ✅ / ◐ | 6 |
| Machines | — | ⛔ upstream | — |
| Panel | — | ⬜ / ⬜ | 6 |
| Browser | — | ⛔ upstream | — |
| Passwords | — | ⛔ secrets | — |

The Mac lists 23 pages in five groups (`Kuvo Code`, `Models`, `Agent`, `Projects`, `Side
Panel`). The Windows client lists 14 flat entries. Phase 6 restores the Mac's grouping,
page header, and page order, builds the three missing unblocked pages (Notifications, Privacy,
Panel), and treats Worktrees as the Projects page unless the maintainer says otherwise. Five
pages stay ⛔.

### 6.4 Excluded view files (20)

These are excluded by an earlier, still-standing decision, not because they are hard to draw.
They must not be "approximated" with a lookalike UI: either the maintainer reopens the surface,
or the Windows client does not show it.

| Mac view | Why |
| --- | --- |
| `BrowserAskCard`, `BrowserChrome`, `BrowserSession`, `NewTabPage`, `MachineBrowserPane`, `AgentBadge`, `BrowserSettings` | The integrated browser is an upstream surface; the agent badge belongs to it |
| `WidgetView` | A `show_widget` page is rendered in the browser surface |
| `BotEditor`, `GroupChatView`, `GroupEditor`, `GroupMentions` | Bots and group chats are an upstream surface |
| `MachineForm`, `MachineStatusViews`, `MachinesSettings` | Remote machines over SSH: upstream |
| `PhoneSettings` | Phone link: upstream |
| `IntegrationsSettings`, `SiteSignInPage`, `ConnectView`, `PasswordsSettings` | OAuth / site sign-ins: secrets are not handled here |

**Boundary, stated plainly:** the ledger covers all 74 view files and all 23 settings pages,
but 20 view files are excluded — five of them the excluded Settings pages. One of those,
`BrowserSettings.swift`, also carries the in-scope Panel page (§6.5). "100 % of the Mac UI" in
this project therefore means 100 % of the in-scope screens: 54 wholly in-scope view files plus
the Panel page, and 18 of the 23 settings pages. The excluded surfaces need a maintainer
decision before they can be reproduced, and the Windows client cannot prove them from the Mac
source alone.

### 6.5 The files behind the pages

The pages do not map one file per page, which is why the ledger counts pages and view files
separately:

| Mac page(s) | File |
| --- | --- |
| General, Notifications, Privacy, Usage | `Settings/GeneralSettings.swift` |
| Appearance | `Settings/AppearanceSettings.swift` |
| Shortcuts | `Settings/ShortcutsSettings.swift` |
| Storage | `Settings/StorageSettings.swift` |
| Accounts | `Providers/ProvidersView.swift` |
| Agents | `Settings/AgentsSettings.swift` |
| Permissions | `Settings/PermissionsSettings.swift` |
| Commands | `Settings/CommandsSettings.swift` |
| Skills | `Settings/SkillsSettings.swift` |
| MCP | `Settings/MCPSettings.swift` |
| Engine | `Settings/EngineSettings.swift` |
| Git, Worktrees | `Settings/GitSettings.swift` |
| Archived | `Settings/ArchivedSessionsSettings.swift` |
| Panel | `Settings/BrowserSettings.swift` (`PanelSettingsView`; the `BrowserSettings` half is ⛔) |
| Phone, Integrations, Machines, Passwords | their own `Settings/*.swift` files — ⛔ |
| Site sign-in | `Settings/SiteSignInPage.swift` — ⛔ |

Three shared files carry the chrome of every page: `Settings/SettingsControls.swift` (rows,
wells, buttons), `Settings/SettingsDetail.swift` (page header, column), and
`Shared/FormFieldsView.swift` (text fields, steppers, pickers). They are in scope with the
pages: the look comes from §3, the behaviour from §9.

---

## 7. Icons and drawn artwork

The generated inventory lists **89 unique SF Symbols in 238 uses** (both `systemName:` and
`systemImage:`; the earlier planning count of 191 was `systemName:` only). The full list, with
every site, is `MAC-UI-INVENTORY.md` §3.

Most used:

| Symbol | Uses | Meaning |
| --- | ---: | --- |
| `xmark` | 18 | close / clear |
| `chevron.right` | 13 | disclosure |
| `plus` | 10 | new |
| `magnifyingglass` | 9 | search |
| `minus.circle.fill` | 9 | remove |
| `checkmark` | 7 | done |
| `folder` | 7 | project / file |
| `arrow.triangle.branch` | 6 | fork / branch |
| `server.rack` | 6 | machine |
| `xmark.circle.fill` | 6 | clear / close |
| `chevron.down` | 5 | menu |
| `ellipsis` | 5 | more |
| `checkmark.circle.fill` | 4 | connected / done |
| `exclamationmark.triangle.fill` | 4 | warning |
| `hand.raised.fill` | 4 | permission |
| `pause.circle` | 4 | stop / pause |

The Mac draws these rather than using a symbol. The annex lists the six Shape/Canvas
declarations (`MAC-UI-INVENTORY.md` §6); the avatar faces and group avatar are drawn views,
listed here because their drawing is not a single `Shape`:

| Drawn type | What it is | Exact geometry | Windows | Phase |
| --- | --- | --- | --- | --- |
| `FolderShape` / `FolderIcon` | Closed and open folder | 16 × 13 grid, fill foreground 20 %, stroke `size / 11.5`, round caps and joins, open state has a different back/tab | ⬜ | 4 |
| `PromptMark` | The `>_` app mark, chevron or cursor | aspect 530 / 690; original coordinates mapped from (170, 250)–(860, 780); round caps; used at 11 pt in the spinner | ⬜ | 3, 4 |
| `Star` | The sparkle beside a bot | `BotAvatar.swift:313` | ⛔ | — |
| `BotShape` | 5 body silhouettes | round, squircle, pebble, gem, bloom; `BotAvatar.swift:535` | ⛔ | — |
| `BotFace` | 6 faces | calm, happy, sleepy, wink, curious, bright; `BotAvatar.swift:592` | ⛔ | — |
| `GroupAvatar` | Overlapping member avatars | `BotAvatar.swift:269` | ⛔ | — |
| `ArrowShape` | The agent's pointer | path 0,0 → 0,−18 → 4.6,−13.8 → 7.6,−20.4 → 10.6,−19.1 → 7.7,−12.6 → 13.6,−12.6, close | ⛔ | — |

**Rules for Phase 4.** No emoji, no text glyph standing in for an icon, no icon font. Each SF
Symbol becomes a drawn SVG with the same silhouette, on the same 16 pt optical grid, with a
1.5 pt stroke at 16 pt, round caps and joins, and `currentColor`. Decorative icons are
`aria-hidden`; icon-only buttons carry the Mac's `.help` text as `aria-label` and `title`.

**Done in 0.5.42, for the marks the client uses today:** the drawings live in
`windows/app/src/components/symbols.tsx` (the symbols, the folder, the app's own prompt
mark), the glyphs that stood in for them are gone, and the check that keeps them gone is in
`windows/mac-tokens.test.mjs`. The remaining symbols arrive with the screens that use them
(Phase 6).
Provider logos come from models.dev, monochrome by default, maker colour only where the Mac
uses `colored: true` (`ProviderLogo.swift:7-12`).

The Windows app currently draws the paperclip and pencil as SVG (shipped 0.5.34), and still has
a naked `@` glyph in the header and `⇩`/`✕` text marks in session rows. Those are exactly the
kind of stand-ins Phase 4 removes.

---

## 8. Wording

The generated annex lists **1 208 string sites, 933 distinct** (`MAC-UI-INVENTORY.md` §5): every
`Text`, `Button`, `Label`, `Toggle`, `Picker`, `Section`, field prompt, `.help`,
`.accessibilityLabel`, and every `title:` / `detail:` / `name:` property, with its `file:line`.
The earlier planning count of 369 came from a narrower pass; the annex is the superset and
includes menu commands and tooltips, which are part of the UI too.

Rules for Phase 5:

1. **Verbatim.** Copy the Mac string exactly, including curly apostrophes (`Don’t Reply to
   This`, `What’s New`), ellipses (`Check for Updates…`, `Undo From Here…`), case (`New
   Session`, `Show More` / `Show Less`), and spacing.
2. **No new wording.** If the Windows client needs a string the Mac does not have, that is a
   portability note in this ledger and a maintainer decision, not an invented label.
3. **One string, one place.** Menus, tooltips, empty states, errors, confirmations, and
   accessibility labels all come from the annex.
4. **Runtime strings keep their interpolation.** `"\(count) sessions"` becomes the same
   sentence with the same punctuation; pluralisation follows the Mac's rules.
5. **The annex is the checklist.** Phase 5 closes when every in-scope site has been compared,
   not when the visible screens look right.

The annex is generated, never edited. Add a string to the Mac source, run
`node windows/tools/mac-ui-inventory.mjs`, and the count changes.

---

## 9. Interaction invariants

Behaviour that is not a colour or a curve, and that a screenshot cannot prove.

| Invariant | Mac behaviour | Evidence | Windows | Phase |
| --- | --- | --- | --- | --- |
| Hover language | 6 % fill on rows, 8 % on buttons; selected 8 %; 0.12 s easeOut | `HoverHighlight.swift:14-26`, `Pressable.swift:8-9` | ✅ | 3 |
| Press | 13 % fill, no movement | `Pressable.swift:56-70` | ✅ | 3 |
| Disabled | 45 % opacity, no fill | `Pressable.swift:61` | ✅ | 3 |
| Inline rename | All text selected; Return commits; Escape cancels; click-away keeps (except a branch, which needs Return) | `InlineTitleField.swift:4-55` | ✅ (0.5.48) | 7 |
| File drop | Anywhere over the window, text fields included; only during a file drag; clicks pass through | `FileDrop.swift:4-70` | ✅ | — |
| Right-click | Message actions, title-bar menus; one window-level watcher | `RightClickMenu.swift:4-65` | ✅ (the rows' and the messages' menus) | 7 |
| Double-click title | Follows the system preference: zoom, minimise, or nothing | `Card.swift:186-198` | ⬜ | 7 |
| Pane resize | 8 pt gap is the handle; 3 pt tint capsule appears at 50 %; `column-resize` cursor | `WindowGlass.swift:43-81` | ✅ (0.5.48) | 2, 7 |
| Hover actions | Time, Copy, New Session, Undo appear under the pointer with no layout shift; 0.12 s | `YourMessage.swift:41-64` | ✅ (0.5.52) | 7 |
| Composer history | ↑ / ↓ walk sent messages, as in a shell | `Composer.swift:22-24` | ✅ (0.5.48) | 7 |
| Queue | ⌘Return queues while idle when messages are waiting; send becomes Stop | `Composer.swift:20-21` | ✅ | — |
| Quote | 3 pt tint bar, "Replying to", 3 lines, remove; `.help("Drop the quote")` | `QuoteViews.swift:8-30` | ✅ (0.5.54) | 2 |
| Search clear | Clear (×) is tertiary at rest, secondary on hover, primary pressed | `Pressable.swift:73-91` | ✅ (0.5.50) | 3, 7 |
| Remove (−) | Turns red under the pointer, 70 % while pressed | `Pressable.swift:93-112` | ✅ (0.5.53) | 7 |
| Accent badge | Grows to 1.12 and darkens 7 % on hover; 15 % on press | `Pressable.swift:201-220` | ⬜ | 7 |
| List selection | Tint 16 % selected, 24 % pressed; row radius 7 | `Pressable.swift:137-164` | ✅ | 3 |
| Focus | Well fields have no focus ring; `focusEffectDisabled` | `Surfaces.swift:179-191` | ✅ | 7 |
| Selection | Message text selectable; selection is tinted, caret is accent | `TranscriptView.swift:713`, `style.css:211-212` | ✅ | — |
| Find | Find in conversation is invoked, not permanently in the header; highlights and count | `FindBar.swift`, `App` menu | ✅ (0.5.49) | 2, 6 |
| Sidebar search | One search well; search-in-conversations shows a spinner in it | `SidebarView.swift:693-697` | ✅ (one well; the spinner is Phase 6) | 2, 6 |
| Scroll | Sticks to the bottom while the agent writes; scrolling up reveals ↓ Latest; 120 pt tail | `TranscriptView.swift:1496`, `ConversationScroll.swift` | ✅ | — |
| Popover side | A menu/popover that outgrows its side flips to the other | `ScreenRoom.swift:4-33` | ✅ (0.5.50) | 7 |
| Reduce Motion | Spinner holds still, shimmer stops, bots hold, transitions reduce | `Spinner.swift:19`, `Theme.swift:45-53`, `BotAvatar.swift:80` | ✅ | 3 |
| Window controls | The first card leaves 26 pt for close/minimise/zoom when tabs are hidden | `Theme.swift:12-14`, `Card.swift:118` | ◐ (frameless shell) | 2 |
| Menu chevron | 8 pt bold, secondary, after the label | `Pressable.swift:192-198` | ◐ (Phase 4) | 4 |

---

## 10. Verification loop

Phase 0's extraction is only useful if every later phase is measured against it.

1. **Source, not memory.** Every value in this ledger cites a `file:line`. A Windows value that
   disagrees is a bug in the port, unless this document says the Mac value cannot exist.
2. **Captures.** `windows/tools/capture.mjs` drives the harness with Chromium and the sandbox
   font workaround, at 1440 × 900 and 1000 × 700, in light and dark. Each phase captures the
   affected screens before and after. The PNGs are the review artefact, not the proof.
3. **Computed values.** For tokens, geometry and motion, the proof is the computed CSS
   (`getComputedStyle`) compared with the Swift value. The DOM test (`windows/harness/ui.dom.test.mjs`)
   asserts the behaviours; token assertions are added with Phase 1.
4. **The Mac screenshots are the arbiter.** The sandbox has no macOS, no SF fonts and no GPU;
   captures here can prove structure, values and regressions, not the last 5 % of optical
   fidelity. When the user supplies screenshots of the real Mac app, they override any local
   judgement about a hairline.
5. **Gates per batch.** Unit tests (`node --test`, 91), DOM test with `KUVO_HARNESS_LIVE=1`,
   `npx tsc --noEmit`, UI build, CI on `windows-latest`, then one version number and one
   release. A batch that is not green does not get a version.

### 10.1 The capture matrix

Each state is captured at 1440 × 900 and 1000 × 700, in light and in dark, once its tokens
exist. `windows/tools/capture.mjs` takes one shot; the state setup is the harness's. A phase is
not done until its rows exist in both themes and its computed values match §3.

| State | What the capture must show |
| --- | --- |
| Empty, no project | warm canvas, ambient, sidebar empty state, column width |
| Session, light | user bubble at radius 18, transcript type, code well, tool call |
| Session, dark | dark card fills, specular rim, accent glass, code well |
| Composer with quote and attachment | quote bar 3 pt, "Replying to", attachment row, foot |
| Palette with a query | 600 width, 48 search, 30 rows, 18 radius, glass |
| Settings › Appearance | nine accents, four sizes, window mode, typeface |
| Settings › General | page header, 49 inset, grouped form, 38 header |
| Drawer › Files, Changes, Terminal | 44 header, 9 tab pill, file tree, diff well |
| Sidebar with projects and sessions | 32 rows, 18 icons, unread, one search well |
| Title bar with tabs and split | tab capsule 30, tile 25 × 20, controls inset |
| Queue and context gauge open | queue rows, 12 ring, 320 popover |
| Find bar open | find field, count, previous/next, highlights |
| Image viewer | radius 10, capsule toolbar, backdrop |
| Message hover | time and actions, no layout shift, 0.12 s |
| Permission card | attention card, Allow/Deny, Try Again |
| Window: glass and solid | material and canvas tint vs canvas solid |
| Reduced Motion | shimmer stopped, spinner still, transitions reduced |

**Definition of done for this ledger:** every in-scope row is ✅ on both axes, every excluded
row is ⛔ with a reason, and no ◐ or ⬜ remains. The look is then the Mac's, not an
interpretation of it.

---

## 11. Phases and release batches

| Phase | Scope | Ledger rows it closes | Release |
| --- | --- | --- | --- |
| **0. Extraction** | This document, the generated inventory, the generator | all rows extracted; statuses set | docs commit (no release) |
| **1. Tokens** | Rebind `DESIGN.md`; replace `:root` light/dark with §3; radii 14/18/10/8/7/6/5; shadows; type sizes and faces; accent presets | §1 rows 1, 3, 7, 9, 10, 12, 13; §3 | 0.5.37 ✅ |
| **2a. Cards & glass** | The conversation card, 38 pt header + 62 pt fade, 8 pt window gaps, the sidebar on the glass (no surface), 32 pt rows, one search, the composer inside the card | §1 rows 3–8, 15, 16; §2; §4 Card/Composer/Bubble | 0.5.38 ✅ |
| **2b. Title bar & overlays** | Title-bar tabs, drawer, palette 600/18, settings card, gauge popover, wells | §1 rows 15, 16; §2; §4 | 0.5.39 ✅ |
| **3. Motion** | Analytic spring `linear()`, hover 0.12, press fills, list tint, shimmer, spinner, image-viewer transitions, reduced motion | §5 | 0.5.40 ✅ |
| **— The platform** | The window is built by Next.js (a static export the harness serves) and the page is read in a real browser in CI; the look and the behaviour do not move | — | 0.5.41 |
| **4. Icons** | 89 symbols → drawn SVGs; FolderIcon; PromptMark; provider logos; remove text glyphs and the naked `@` | §7 | 0.5.42 ✅ |
| **5. Wording** | 1 208 sites compared; menus, tooltips, accessibility labels; punctuation | §8 | 0.5.43 ✅ (the shell's words; the rest with the screens) |
| **6. Screens** | Sidebar + title bar; transcript; composer + queue + gauge; palette + drawer; settings (14 existing + 3 missing: Notifications, Privacy, Panel; Worktrees maps to Projects); files/changes/terminal | §6.1–6.3 | 0.5.44 ✅ (the transcript, the gauge, the steps row) · 0.5.45 ✅ (the settings' grouped form) · 0.5.46 ✅ (the rest of the groups; the run that would not end) · 0.5.47 ✅ (the panel's files, as a tree) → 0.5.49 |
| **7. Gestures & micro-UX** | Rename, double-click, resize grabber, history, popover flip, clear/remove/badge behaviours, find and search field shape | §9 | 0.5.48 ✅ (the rename, the grabber, the history) · 0.5.49 ✅ (the find bar) · 0.5.50 ✅ (the popover that flips, the clear) · 0.5.52 ✅ (the actions under a message) · 0.5.53 ✅ (the disabled and remove states) · 0.5.54 ✅ (the quote card, the message menu) |
| **8. Verification** | Full capture matrix, computed-value checks, close every ◐; final side-by-side | all in-scope rows | 0.5.51 ✅ (the matrix and the measured values) |

One release per batch, one descriptive commit line, CI green on `windows/harness` and `main`
before the tag. The 20 excluded view files — five of them the excluded Settings pages — stay
⛔ until the maintainer reopens them; they are recorded here so nobody mistakes their absence
for an oversight.

---

*Generated companion: [`MAC-UI-INVENTORY.md`](MAC-UI-INVENTORY.md) — every design and view
file, all 89 symbols with their sites, all 261 motion sites, all 1 208 string sites, the drawn
artwork, and both settings-page lists. Regenerate with
`node windows/tools/mac-ui-inventory.mjs`.*
