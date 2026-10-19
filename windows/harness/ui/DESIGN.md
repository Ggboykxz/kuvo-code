# Kuvo Code for Windows — the design this app is bound to

This is the `design.md` the app's look is bound to, in the way OpenDesign binds a design
direction before anything is generated: the palette, the posture and the trade-offs are
written down here first, and the interface follows them.

**Source:** OpenDesign's design direction `modern-minimal` — *"Modern minimal — Linear /
Vercel"*, read with the tool that ships it:

```
od tools directions --id modern-minimal --json
```

The other directions it offers — *editorial-monocle*, *human-approachable*,
*tech-utility*, *brutalist-experimental* — were weighed; this one is right for a client of
a coding agent, where the conversation is the content and the chrome must not compete with
it. The dark ground follows OpenDesign's own `linear-app` system, which is where the
direction's references live.

## The atmosphere

Quiet, precise, software-native. System fonts, crisp neutral foundations, and a small but
visible palette — a primary action colour, one secondary signal, the status colours — so
the interface feels *shipped* rather than greyscale. The chrome stays restrained; the
interaction states and the content carry the colour.

## The palette (the direction's own, in oklch)

| Role | Light | Where |
| --- | --- | --- |
| Canvas | `oklch(99% 0.002 240)` | the app's background |
| Surface | `oklch(100% 0 0)` | cards, inputs, sheets |
| Foreground | `oklch(18% 0.012 250)` | text |
| Muted | `oklch(54% 0.012 250)` | secondary text |
| Border | `oklch(92% 0.005 250)` | every hairline |
| Accent | `oklch(58% 0.18 255)` | the primary action |

The dark ground is the same direction inverted: a near-black canvas (`#08090a`), panels one
step up (`#0f1011`), raised surfaces one more (`#191a1b`), text `#f7f8f8` (never pure
white), and hairline white borders (`rgba(255,255,255,0.08)`) for the structure. The app's
accent is the user's pick — cobalt `#2f6feb` by default, which sits right on the
direction's own blue.

## The posture (the rules, as the direction states them)

- **Tight letter-spacing on display sizes** — `-0.02em` at 20px and up.
- **Hairline borders only, no shadows except dropdowns and modals** — a card is a surface
  and a border, never a shadow. What floats (the command palette, the settings sheet, the
  project drawer) is the only thing that casts one.
- **Tabular numerals** — figures line up in columns: the engine's state, the token gauge,
  the session's dates, the code.
- **A sticky frosted nav** — the header is glass over the conversation.
- **A controlled colour system** — one primary action colour, one secondary signal, the
  status colours; never a gradient on every card.
- **No webfont** — the system stack: SF Pro on macOS, Segoe UI Variable on Windows. The
  app looks native because it *is* native, and it loads nothing.

## Shape and space

- Radius: 4 (rows), 6 (buttons, inputs), 8 (cards), 12 (panels), 9999 (pills).
- Spacing on an 8px base: 4 / 8 / 12 / 16 / 20 / 24 / 32.
- Motion: 120ms for small changes, 200ms for surfaces, `cubic-bezier(0.2, 0, 0, 1)`. The
  command palette keeps the Mac app's spring — that one is the app's signature.

## What this app keeps from the Mac app

The Mac app's *structure* — the same pages, the same wording, the same gestures — and its
three theme choices (light, dark, System). Only the look moves: the Windows app is
dark-native, flat and precise where the Mac app is warm and glassy. Same app, one canvas.

## Where it lives

`style.css` holds the tokens at the top: `:root` for light, `html[data-theme="dark"]` and
the `prefers-color-scheme` block for dark. The accent is applied at runtime by
`applyLook()` in `app.js`, so a user's pick always wins over the default.
