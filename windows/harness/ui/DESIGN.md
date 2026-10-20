# Kuvo Code for Windows — the design this app is bound to

This is the `design.md` the Windows client follows. The binding changed in Phase 1: the app is
no longer tied to an OpenDesign direction. It is tied to the Mac app's own design layer, read
from the Swift source line by line.

**Source of truth:** `KuvoCode/Design/` (27 files) and `KuvoCode/Views/` (74 files). The
extraction ledger is [`docs/MAC-UI-MAP.md`](../../../docs/MAC-UI-MAP.md); the generated annex
with every symbol, motion site and string is [`docs/MAC-UI-INVENTORY.md`](../../../docs/MAC-UI-INVENTORY.md).
The value tables below cite the Swift file and line they come from. When a value is uncertain,
the Swift source wins over this document; when the two disagree with a screenshot of the real
Mac app, the screenshot wins over both.

The OpenDesign direction `modern-minimal` — the cool neutrals, the 8/12 px radii, the
shadowless glass, the 320 ms over-bouncy curve — is retired. Its block is still at the top of
`style.css` while Phase 2 moves the rules into their components; the **Mac binding** block at
the end of the file is the current source of truth, and Phase 2 deletes the old one.

## The atmosphere

Quiet, warm, precise. The Mac app is a glass window with cards on it: a warm canvas, opaque
cards with a lit top edge, one accent that the user chooses, and generous space around the
conversation. The chrome is almost silent; the conversation is the content. Nothing floats
that the Mac keeps still, nothing is blurred that the Mac keeps opaque.

The four rules that follow from that:

1. **Warm neutrals, not cool ones.** The canvas is ivory; the cards are white or a warm
   ivory; hairlines are slate at 7 %, never a visible grey border.
2. **A card is opaque.** Glass is for the palette and for the window chrome, not for the
   composer, not for settings, not for your own message.
3. **One accent.** It appears as a 10 % wash (22 % in dark) and as a 1 px edge; the app does
   not paint whole toolbars with it.
4. **Motion is short and quiet.** Hovers are 120 ms; surfaces hand over with the Mac's spring;
   pressing a button does not shrink it.

## The canvas

| Token | Light | Dark | Source |
| --- | --- | --- | --- |
| Canvas tint | `#F6F4EE` at 86 % | `white 0.06` at 25 % | `Surfaces.swift:23-32` |
| Canvas solid | `#F2F0EA` | `#131417` | `Surfaces.swift:33-37` |
| Ambient warm | `rgb(255, 158, 107)` at 7 % | at 6 % | `Surfaces.swift:41-54` |
| Ambient cool | `rgb(107, 140, 255)` at 7 % | at 6 % | `Surfaces.swift:41-54` |
| Ink | system label | system label | macOS semantic colour |
| Hairline | slate `#0F172A` at 7 % | white at 8 % | `Surfaces.swift:12-22` |

The ambient is one linear gradient from the top-leading corner to the bottom-trailing corner:
warm at 7 % at 0, warm at 1.75 % at 40 %, cool at 1.75 % at 60 %, cool at 7 % at 100 %. Dark
mode halves it. The CSS keeps the exact stops.

The Windows window is opaque today, so the CSS uses the **canvas tint** `#F6F4EE` in light and
the **solid** `#131417` in dark. Electron acrylic can supply a real material later; the tint is
already the Mac's value, so enabling it is a shell change, not a repaint.

## Cards

| Property | Focused | Unfocused | Source |
| --- | --- | --- | --- |
| Light fill | `#FFFFFF` | `#F9F7F1` | `Surfaces.swift:59-71` |
| Dark fill | `#181A1F` | `#202228` | `Surfaces.swift:59-71` |
| Radius | 14 pt | 14 pt | `Card.swift:19-29`, `Theme.swift:9` |
| Light shadow | slate 10 %, radius 16, y 6 | slate 7 %, radius 6, y 2 | `Card.swift:41-70` |
| Dark shadow | black 36 % | black 22 % | `Card.swift:41-70` |
| Rim | white 80 % inset top edge (dark: white 13 %) | same | `Card.swift:31-39` |

A card has no visible grey border. Its edge is the fill against the canvas plus a 1 px inset
highlight along the top. The CSS approximates the Mac's specular rim with a 1 px hairline and
`inset 0 1px 0 var(--lit)`; Phase 2 replaces the approximation with a gradient rim where it is
worth it. `--shadow-card` is the unfocused shadow; `:focus-within` lifts to the focused one.

## The accent and your message

The user bubble is the only large accent surface:

| Property | Light | Dark | Source |
| --- | --- | --- | --- |
| Wash | accent 10 % | accent 22 % | `Surfaces.swift:89-99` |
| Edge | white 85 % → accent 25 % | white 20 % → accent 40 % | `Surfaces.swift:101-111` |
| Radius | 18 pt | 18 pt | `TranscriptView.swift:1500-1513` |
| Padding | 14 × 10 pt | 14 × 10 pt | `TranscriptView.swift:1500-1513` |
| Leading | 80 pt | 80 pt | `TranscriptView.swift:613` |
| Blur | none | none | `Surfaces.swift:89-99` |

The CSS uses `--bubble-fill` (accent at 10 % / 22 %) and `--bubble-edge` (a single accent-white
mix); the gradient edge is Phase 2. The bubble is `max-width: min(680px, calc(100% - 80px))`:
680 pt is 760 − 80, the Mac's readable width minus its leading.

Nine presets exist — Default, Blue, Purple, Pink, Red, Orange, Yellow, Green, Graphite — in
`Look.swift:12-46`. Default is the system accent. A chosen accent changes `--accent` and
`--accent-hover`; the wash and the edge follow through `color-mix`.

## The composer

| Property | Value | Source |
| --- | --- | --- |
| Surface | opaque card fill, no blur | `Composer.swift:489-511` |
| Radius | 14 pt | `Composer.swift:489-511` |
| Inner padding | 16 leading/trailing, 10 top, 7 bottom | `Composer.swift:489-511` |
| Light rim | black 10 % | `Composer.swift:489-511` |
| Shadow | black 8 %, radius 8, y 2 | `Composer.swift:489-511` |
| Text | message size (13 / 14 / 15.5 / 17) | `Look.swift:48-83` |

The editor is the card, not a well inside it: `.composer textarea` is transparent and has no
border. The focus ring is the accent at 10 %, not a second card.

## Wells

Code blocks, search fields and form fields sit in a recessed well:

| Property | Light | Dark | Source |
| --- | --- | --- | --- |
| Fill | slate 3.5 % | black 30 % | `Surfaces.swift:79-87` |
| Edge | slate 7 % | white 7 % | `Surfaces.swift:79-87` |
| Radius | 10 pt | 10 pt | `Theme.swift:11` |

## Type

The Mac uses the system face: SF Pro on macOS, Segoe UI Variable on Windows. The CSS stack is
`-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", sans-serif`. Code is
`"SF Mono", "Cascadia Code", Consolas, monospace`.

| Role | Size / weight | Source |
| --- | --- | --- |
| Message | 13 / 14 / 15.5 / 17, regular | `Look.swift:48-83`, `Theme.swift:99-120` |
| Code | 12.5 pt (0.9 em of the message) | `Theme.swift:99-120` |
| Page title | 13 pt semibold | `SettingsDetail.swift` |
| Section header | 13 pt semibold | `SettingsControls.swift` |
| Row label | 13 pt regular | `SettingsControls.swift` |
| Caption | 11 pt regular, 62 % ink | `Theme.swift` |

There is no negative display tracking. The Mac uses the system's optical tracking; the CSS
sets `--tracking-display: 0` and lets the font do it. Text sizes are a conversation setting,
not a global zoom: `--message-size` applies to messages and the composer, never to the chrome.

## Motion

| Motion | Value | Source |
| --- | --- | --- |
| Hover / press | 120 ms, ease-out | `Theme.swift:44-52` |
| Surface hand-over | spring, 320 ms, response 0.32, damping 0.86 | `Theme.swift:31-42` |
| Press | fill 13 %, no scale | `Theme.swift:54-60` |
| Hover fill | 6 % rows, 8 % buttons | `Theme.swift:44-52` |
| Shimmer | 1.8 s linear, 0.55 → 1.0 opacity | `Theme.swift:121-140` |
| Reduced motion | 1 ms transitions; shimmer still | `Theme.swift` |

Phase 1 sets the durations and the 120 ms hover beat. The CSS still uses
`cubic-bezier(0.34, 1.3, 0.64, 1)` for surfaces and a 0.97 press scale; Phase 3 replaces the
curve with the Mac's analytic spring and removes the scale. The shimmer is kept as-is: it is
the one place where the app is allowed to feel alive while it waits.

## Radii

| Radius | Value | Used for |
| --- | --- | --- |
| Card / composer / panel | 14 | cards, composer, settings, drawer |
| Bubble / palette | 18 | your message, command palette |
| Well | 10 | code blocks, fields, popovers |
| Row | 8 | sidebar rows, palette rows |
| List | 7 | menus, lists |
| Button | 6 | buttons |
| Text | 5 | inline code, tags |

## Icons

The Mac uses 89 SF Symbols across 238 sites (`docs/MAC-UI-INVENTORY.md` §1). They are drawn as
inline SVG at the Mac's point size and weight in Phase 4; emoji are banned as interface marks.
A mark that has no SF Symbol equivalent is drawn from the Swift `Path`/`Canvas` source (six
declarations), not borrowed from a generic icon set.

## Wording

The Mac's strings are ported verbatim, in the same places, with the same punctuation and the
same sentence case (`docs/MAC-UI-INVENTORY.md` §5; 1,208 sites). A Windows-only string is a
bug unless the platform forces it (for example a native file dialog), and then it is recorded
in `docs/PARITY.md`.

## What is out of scope

The ledger excludes 20 view files and five settings pages (integrated browser, machines,
phone, passwords, site sign-in). They are listed with reasons in
[`docs/MAC-UI-MAP.md`](../../../docs/MAC-UI-MAP.md) §6.4. The Windows client does not invent
surfaces for them; they need a maintainer decision first.

## The Windows shell

The title bar is native chrome with a 38 px overlay (`windows/electron/main.js`), the window
is opaque, and the canvas is the Mac's. The Mac's traffic lights have no Windows equivalent;
the native minimise/maximise/close controls keep their place and their system colours. The
app's own header is reproduced, not the OS's.

## Phases

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Extraction ledger, inventory, map | done |
| 1 | This binding: tokens, canvas, cards, composer, bubble, type | 0.5.37 |
| 2a | The conversation card and its 38 pt header, the 62 pt fade, 8 pt window gaps, the sidebar on the glass, 32 pt rows, one search, the composer on the column | 0.5.38 |
| 2b | The title bar's tabs, the drawer, the palette and the settings card | next |
| 3 | Motion: analytic spring, press, shimmer, reduced motion | |
| 4 | Icons: 89 symbols as SVG, six drawn marks | |
| 5 | Wording: 1,208 strings verbatim | |
| 6 | Screens: 23 settings pages, transcript, drawers | |
| 7 | Gestures and shortcuts | |
| 8 | Verification: capture matrix, real-Mac screenshots | |

The Mac screenshots are the arbiter. Until they exist, `docs/MAC-UI-MAP.md` and the Swift
source are the evidence, and a capture that does not match them is a defect, not a taste
question.
