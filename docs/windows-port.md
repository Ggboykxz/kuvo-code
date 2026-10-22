> **Frozen — 0.5.101.** This document tracked the Windows client's parity with the macOS
> Kuvo Code app. As of 0.6.0 the Windows client is its own product: parity tracking
> stops here, and the content below is historical reference. New work is tracked in
> `docs/ROADMAP.md`.

# Windows: audit, and what a Windows harness takes

Kuvo Code is a native Mac app: SwiftUI and AppKit, macOS 26, Apple silicon, with
deep system integration (Liquid Glass, the menu bar, Keychain, Sparkle). There is
no Windows build of it, and there can't be one by porting: SwiftUI doesn't exist
on Windows, AppKit even less so. A Windows harness is a rewrite of the interface
against a different toolkit, reusing what's toolkit-independent.

This document is the audit behind that statement, what was verified, and the
staged path. The first stage's code is in `windows/` and the KuvoLink bridge.

## What the app is made of

647 Swift files, 133,578 lines. Split by what they depend on:

| Part | Lines | Depends on |
| --- | --- | --- |
| `KuvoCode/Views` | 27,530 | SwiftUI, AppKit, WebKit, Textual, SwiftTerm |
| `KuvoCode/Stores` | 15,433 | Foundation, AppKit, Security, WebKit, Network |
| `KuvoCode/Design` | 3,849 | SwiftUI, AppKit, QuartzCore |
| `KuvoCode/App` | 1,432 | SwiftUI, AppKit |
| `Packages/UsageKit` | 40,009 (+35,972 tests) | ~30% AppKit/SwiftUI (menu bar panel, popover); ~60% provider/pricing logic; ~10% macOS-only probes |
| `Packages/OpenCodeKit` | 4,788 (+1,490 tests) | Foundation; the engine launcher is `#if os(macOS)` |
| `Packages/KuvoLink` | 1,867 (+913 tests) | Foundation, CryptoKit; the machines' side is the JS bridge |

The interface — windows, the tabs in the title bar, the changes and review
panels, the composer, the transcript — is the product, and it is the part that
doesn't move. Frameworks without a Windows counterpart in the app: AppKit (108
files), SwiftUI (167), WebKit, Security/Keychain, LocalAuthentication, Sparkle,
ServiceManagement, SwiftTerm (a POSIX PTY terminal), KeyboardShortcuts, plus
menu-bar extras, window vibrancy and the accessibility E2E driver.

## The engine is ready for Windows — verified

The engine is opencode, unmodified: any harness keeps it, and its Windows builds
exist at the exact version Kuvo Code pins (2.0.32). Checked against
`registry.npmjs.org`, and by downloading and hashing the tarballs:

| Package | sha512 (`dist.integrity`) | Inner path |
| --- | --- | --- |
| `@opencode/cli-windows-x64` | `5VdKolj2/NkSk3BuM4qeiYpnNnGRT7szmd2RIv3+aSDPMwD9yRySYkJ2f1WIM7dTDfO5lZHAXVoipt6+i6AD4A==` | `package/bin/opencode.exe` |
| `@opencode/cli-windows-arm64` | `T1UGNtrcgDoovpRD3nLqpfZoUh8+pDPlEewALD3QIUOLvuHyy4kUAFra6lLl5kitzqHN5Lm+2iQKX5F81A5hGw==` | `package/bin/opencode.exe` |

`windows/kuvo-engine.mjs` already installs and starts them under the Mac app's
contract: checksum before unpacking, `serve --stdio --port 0`, `{"url": …}` first
line, `OPENCODE_PASSWORD`/`OPENCODE_CLIENT`, XDG folders of its own, stdin
closing as shutdown. The same code was run end to end against the pinned Linux
build here (install → launch → authenticated `api/info` → stop); the Windows
workflow runs it on `windows-latest`.

What changes for Windows, engine-side: the codesign check becomes the checksum
alone (Windows builds carry no Apple signature), npm's tarball is unpacked with
Windows' `tar`, and the shell environment capture (`ShellEnvironment.swift`,
`$SHELL -ilc`) becomes the process environment, optionally with a PowerShell
profile read. What's left of `kuvo-npx`/`kuvo-wake` (POSIX `sh` scripts the Mac
writes for machines) needs `.cmd`/PowerShell or JS equivalents.

## What a Windows harness must rewrite

- **The whole interface** (~46k lines of app code plus UsageKit's AppKit third):
  a Windows toolkit's window model, tabs, panels, menus and shortcuts.
- **The menu bar extra** (usage strip, popover panel): Windows has a tray, not a
  text strip; the honest shape is a tray icon with a windowed detail view.
- **The terminal** (SwiftTerm, forkpty): ConPTY and a terminal emulator.
- **The panel's browser** (WKWebView, script worlds, message handlers): WebView2,
  different API shapes, same `kuvo-browser.js`/CDP design on the engine side.
- **Credentials** (Keychain, Touch ID): Credential Manager / DPAPI, Windows Hello.
- **Updates and signing** (Sparkle, notarization): MSIX or Squirrel/Velopack,
  Authenticode (EV for SmartScreen), no notarization equivalent.
- **The POSIX surfaces**: `setsid`, `chmod`, `kill -0`, `/proc`, `~/.kuvo-code`
  permissions; `ssh -t` uses the Windows OpenSSH client, which has no
  `ControlMaster` multiplexing, so the tunnel lifecycle changes.
- **Notifications, Dock, login item, screen-sharing detection** (the private
  SkyLight probe has no counterpart; Windows has its own share indicators).

## Three ways to build it, in order of fit

1. **Native rewrite in .NET (WinUI 3 or Avalonia)** — best fit long term: the
   engine contract, the KuvoLink protocol (X25519/AES-GCM/HKDF all exist in
   .NET) and the two JS files carry over; the interface is rewritten. The
   estimate is the interface: ~46k lines of SwiftUI is months for a team, not a
   patch.
2. **Swift on Windows for the logic, a shell for the interface** — maximizes
   logic reuse (OpenCodeKit, UsageKit's providers with path adapters), but
   Swift-on-Windows has no SwiftUI, and C ABI interop into WinUI/WPF is friction
   with little payoff.
3. **A web or Tauri/Electron shell around the engine** — fastest to something
   runnable, and the largest product gap: the review/changes/transcript
   experience is the hand-tuned 27k-line part.

## A staged path

- **Stage 0.** Engine bootstrap for Windows, the link bridge's Windows edges,
  tests and a Windows CI job. No interface.
- **Stage 1 (this change).** A minimal client around the bootstrap: `windows/harness/`
  — sessions, prompts, streaming, permission asks, folded from the engine's events
  by the same rules the Mac app's Transcript uses. Its view is plain HTML/JS so the
  core loop is exercisable everywhere, not only on Windows; a native toolkit (the
  Stage 2 question) replaces the page, not the client under it.
- **Stage 2.** Panel parity: files, terminal (ConPTY), browser (WebView2), the
  changes/review flow — and the native shell for Stage 1's client.
  - **2.1 (this change).** The native shell: `windows/electron/` (Electron) — a
    window, a tray, single instance, and the harness supervised as a child process;
    plus an NSIS installer and a portable build. The shell reuses the harness UI
    verbatim and builds in CI on `windows-latest`.
  - **2.2 (next).** ConPTY terminal, files panel, diff view, tray polish,
    auto-update wiring, code signing.
  - **2.58. The app's motion is the Mac's own spring, and the pieces that carry no look
    of their own come from elsewhere. Phase 3 wrote the Mac's `.spring(response: 0.32,
    dampingFraction: 0.86)` down twice: as the analytic curve in CSS (`--ease-spring`,
    `--motion-spring: 450ms`, the true half-percent overshoot) and as Motion's spring
    (stiffness 385.5, damping 33.8) for the components that move — the tab's pill slides to
    the tab you pick, as the Mac's does. The hover is 120 ms and the press is a 13 % fill,
    never a squeeze. The shimmer over "Thinking…" is AI Elements' `Shimmer` (Vercel,
    Apache-2.0), painted in the Mac's ink: the shadcn tokens it reads are bound to the Mac's
    tokens, Tailwind's preflight is not imported, and only the AI Elements' own files are
    scanned for classes, so the Mac's stylesheet stays the base of the app. Their terms
    travel with the app, in `windows/THIRD_PARTY_LICENSES.txt`, written by
    `windows/tools/third-party-licenses.mjs` and checked in CI. The app is linted too
    (oxlint) and type-checked before it is built, in CI and before every push.
  - **2.62 (this change). The upstream's main is merged in.** The branch had fallen 715
    commits behind — the upstream refactored the KuvoLink bridge while we were porting the
    app — and the pull request could not be merged. The merge is now done: the upstream's
    tree comes in whole, and our Windows changes to the bridge are put back on top of their
    new shape — the command line a process tells on Windows (the process list, where there
    is no `/proc`), the bridge's own `isBridge` and `bridgeSpawnOptions`, and the pid file
    that has to go when Windows gives no `SIGTERM`. The pull request is mergeable again.
  - **2.63 (this change). The engine's events reach the conversation, and the working
    mark is the Mac's own.** The page was listening for event names the engine never sends
    (`message.part.updated`), so the words of a reply arrived only when the page was
    reloaded, and the Stop button stayed: the run never ended on screen. The names are the
    engine's own now (`session.text.delta`, `session.execution.succeeded`) — the same ones
    the Mac's transcript reads (`OpenCodeKit/Events/Transcript.swift`). The measure of "the
    agent is at work" takes both halves of the Mac's own: the conversation's last words are
    unfinished *and* the engine still has the session among the active ones
    (`SessionModel.swift:573-587`). And the app's prompt mark painted a stroke of 0.019 pt
    where the Mac's is 1.21 pt — the icon's own proportions are the mark's now, and the
    mark draws itself in short dashes over a faint copy of itself, as the Mac's spinner
    does (`Spinner.swift:1-177`).
  - **2.64 (this change). The conversation at rest, and a turn at its end.** A session with
    nothing in it yet stood blank, where the Mac overlays its own view over the transcript
    while the rows and the waiting are both empty (`TranscriptView.swift:69-75`): the two
    chat bubbles drawn at 34 pt in the light weight over the Mac's question about the
    folder — "What should we work on in `<name>`?" — at `.title3` (15 pt on macOS) in the
    medium weight, a spacing of 10, lifted from the bottom by 120 (the `plain` form of
    `EmptyConversationView`, `TranscriptView.swift:1757-1767`). And the measure of
    "running" had a hole: a message the engine had stamped finished still read as under way
    when it carried no parts and the engine's session flag still said active — the Stop
    button stayed over a turn that was over. The message's own state ends the run on its
    own now, whatever the flag still says and however few parts it carries, the Mac's
    measure (`Message.isRunning`); only a run with no assistant message at all is the
    engine's own answer alone. The live test, meeting a lingering run, re-reads the
    engine's own words and reloads once before it calls the lingering its own.
  - **2.65 (this change). The split is a card, and both conversations stay current.** The
    split pane was the port's own invention: a band at the top with a session picker, which
    read as a second title bar — the one thing the Mac never draws. It is the Mac's card now
    (`MainView.swift:733-754`): the same header the conversation's card has — the session's
    name over its project, the card's mark, the ring, and Swap and Close among its actions
    — over the same hairline, radius and fade, with its rows running under the header at the
    conversation's own 38 + 16 pt. There is no picker inside the pane: a session opens
    beside the one in view the Mac's way, with *Open Beside* in the session's menu
    (`SidebarView.swift:609`, `MainView.swift:757-775`), and Swap exchanges the two places
    (`MainView.swift:743-747`). The pane's conversation is a conversation like the other:
    every event is routed to it the way the Mac routes an event to the model of the session
    it names (`Workspace.swift:1458`, `models[id]`), a turn that ends beside you is read
    back, and an empty one asks the Mac's own question about its folder. And a reconnection
    is the Mac's (`AppModel.swift:448-459` → `Workspace.resync`,
    `Workspace.swift:1347-1359`): the line's `onopen` re-reads the list, the conversation in
    view and the one beside it, so what was said while the line was down is known again
    from the engine's own messages.
  - **2.66 (this change). The panes take the Mac's terrain, and give way in its order.**
    The window's three cards shared no measure with the Mac: the split was a fixed 560, the
    panel a fixed 420, and only the sessions had a handle. They share the Mac's `PaneLayout`
    now (`MainView.swift:2112-2179`): the sessions may be drawn 220 to 440 pt wide, the
    panel 300 to 900, the split 380 to 1200, and the conversation keeps at least 380
    whatever else is on screen. Out of room the split goes first, then the panel, then the
    sessions — a split the window cannot hold is put aside rather than drawn over the
    conversation, and comes back by itself when the room does, and a pane that went early
    is restored if a later one's going left room for it. If room is still short after the
    give-way, the rest shrink as far as they must, the panel first and the split last. The
    page measures the window and hands the layout what each pane asks for and what is
    shown, and writes the three widths back into the page's own variables; the handles
    between the cards move each width inside its own range, and no further than the room
    the conversation leaves. The split's own handle is the Mac's shape — zero width in the
    gap, its grab area reaching over both cards, the accent hairline while pointed at or
    dragged (`PaneResizer`). The layout itself is a plain module
    (`windows/harness/layout.mjs`), so the harness proves the Mac's order of giving way and
    shrinking without a window.
  - **2.67 (this change). The shell's seams, and the model the engine takes.** The window
    knew it was the shell by the address it was opened at — `?shell=1` — and the terminal by
    `?terminalPort=…`; a Back (the mouse's own button, or Alt+Left) could take both away, and
    with them the title bar's room for the window's controls, so the page's buttons slid
    under them. The page knows its window by the bridge now (`preload.js`: `isShell`, and
    the terminal's port asked of the shell), and the shell pins its page: Back and Forward
    are ignored, and the window cannot leave the harness (`main.js`). A terminal that cannot
    start says why where the terminal would be — the close reason the shell sends, whether
    node-pty is missing or the shell could not be spawned — instead of a bare "Terminal
    closed."; node-pty is a required dependency now, so a release that cannot build it fails
    rather than shipping a terminal that never starts. And a model chosen in the composer
    goes to the engine as its own Model.ref — `{ providerID, id }`
    (`OpenCodeKit/Models/Common.swift:70`, `OpenCodeAPI.swift:473-476`) — where the port
    sent the picker's `provider/id` string and the engine answered "Expected Model.Ref at
    [\"model\"]". The picker shows the new model at once and puts the old one back if the engine
    refuses, as the Mac's does (`SessionModel.swift:1333-1341`); the "engine's choice" row
    is gone, since the Mac's picker has no such row and the engine has no call to clear a
    model.
  - **2.68 (this change). The session's own menu, and the sessions kept at the top.** A
    session's row had a menu of three items; the Mac's has the whole of one
    (`SidebarView.swift:600-643`): pinned or not, beside the one in view, its name, the
    folder it works in, the conversation as Markdown, put away or brought back, and the one
    that undoes — in that order, in the Mac's words, with the last one red and asking
    first. The menu now says all of it, and does it: *Pin* keeps a session at the top of
    the sidebar, in a section of its own, out of the recents (the mark is the Mac's own,
    `kuvo.pinned`, written with the session's metadata so the other marks stay —
    `Workspace.swift:342-364`); *Show in Folder* opens the folder where the user can see
    it (the Mac's *Show in Finder* is the Explorer here); *Copy as Markdown* and *Export as
    Markdown…* write the conversation out the Mac's way (`ConversationExport.swift:9-69`:
    the title over it, "You" and "Agent" as the speakers, the agent's steps listed
    together), for any session and not only the one in view; *Archive* and *Unarchive* put
    a session away or bring it back; *Delete…* asks first, as the Mac's does. A menu
    carries what a menu carries: a line between the groups, an item that cannot be
    chosen, and the one that undoes.
  - **2.69 (this change). The tab's own menu.** A tab had only its close mark; the Mac's
    tab carries a menu of its own (`TitleBar.swift:214-231`): *Open Beside* for the tabs
    beside the one in view, *Rename…*, then the tabs to close — *Close Tab*, *Close Other
    Tabs* (dimmed when one tab is open, as the Mac's is) and *Close All Tabs* — in the
    Mac's order, with the Mac's words. The name is written in the tab itself, where the
    title was (`TitleBar.swift:170-200`), as on the Mac, and the tab's rename is the
    session's own name — the same one the sidebar's row writes.
  - **2.70 (this change). The window remembers its own state.** The Mac keeps the panes'
    widths, what is folded away and the row at the top (`MainView.swift:38-40, 90`;
    `SidebarView.swift:32-34`; `TabBar.showsKey`), and the port kept none of it: every
    window opened with the Mac's default widths, every section unfolded, and the row at the
    top always there. The port remembers the same things now, under its own names: the
    sessions' width, the panel's and the split's — kept when the handle is let go, so the
    next window opens as it was left — what the user folded away, and the row at the top,
    which the General settings can put away, as the Mac's does (`GeneralSettings.swift:23`,
    "Show the tab bar"). With the row away, the project, its branch and the sessions as
    tabs go, and the window's own buttons stay.
  - **2.71 (this change). The picture the model can see, and the viewer that looks at
    it.** A picture attached to a message never reached the engine: the port sent the
    file in the page's own shape, where the engine takes a URI and a name
    (`OpenCodeKit`'s `PromptFile`, `OpenCodeAPI.swift:437-445`), and the harness threw
    away the files that were not already on disk. The files go as the Mac sends them now
    — a data URI for what the page read, a file's own path for what was on disk — and a
    picture alone is a message, as it is on the Mac (`Composer.swift:109-113`). The picture
    stays in the conversation when the message is delivered, and the viewer moves as the
    Mac's does (`ImageViewer.swift:22, 28, 40`): it fades in over 160 ms and out over 140,
    the window under it dims to 30 % over 150 ms and is out of reach of a click, the scrim
    is the Mac's black at 62 %, and the picture comes in from 0.94 of its size. A
    double-click zooms it, as the Mac's does.
  - **2.72 (this change). The choices the Mac keeps: the tool permissions, and the model
    picked last.** The composer's mode menu held the modes and nothing else; the Mac's
    holds the tool permissions too (`ComposerMenus.swift:120-135`: the modes, a line, then
    *Tool Permissions* — *Approve All*, "Runs tools without asking", and *Ask First*,
    "Asks before editing files or running commands"). The port's menu says all of that
    now, and it acts: the choice becomes the session's own rules — the edits, the
    commands, the pages and the searches either wait for an OK or do not
    (`ComposerMenus.swift:45-53`; `PermissionsSettings.swift:22-31`) — and it is kept for
    the next time (`toolApproval`). And the model picked last is kept whole, the id with
    its slashes (`SessionView.swift:459-490`), so a new session starts with it, as the
    Mac's does.
  - **2.73 (this change). The appearance's own choices.** The Mac's appearance holds the
    window's material, the typeface of the messages and the detail of the agent's steps
    (`Look.swift:42-63`; `AppearanceSettings.swift:9-77`); the port's held the accent, the
    text size and the motion. It holds them all now, in the Mac's words: *Window* —
    *Glass*, "Frosted glass that lets your desktop’s colors through", or *Solid*, "A
    solid background, with nothing showing through"; *Typeface* — System, Rounded, Serif or
    Monospaced, "Code always stays monospaced"; and *Agent’s steps* — *Each Step*,
    *Summarized* or *Minimal*, each with the Mac's own note. The window's material is the
    glass the port already drew, or a solid ground; the typeface is the messages' (the
    chrome keeps its own); and the steps show as they were chosen: a line that opens to
    each, or only how many there were. Windows has no SF Pro Rounded: the closest it has
    is Candara, whose terminals are round.
  - **2.74 (this change). Two things the app was slow to see.** A session's name comes from
    the engine a moment after its first words — the conversation's card said "New Session"
    for a session the engine had already named, until the list was read again; the session
    in view takes its name from the list now. And a file picked before the session was in
    view was thrown away by the draft that came with the session: the files in the box
    belong to the session they were picked for, and the draft of another one does not take
    them away.
  - **2.75 (this change). The commit form's own choice.** The Mac's commit form remembers
    whether the commit pushes afterwards (`ChangesPanel.swift:304, 331, 344`) — and the
    button says what it will do: *Commit*, or *Commit and Push*. The port's form had the
    mark but forgot it when the panel was closed, and the button always said *Commit*; it
    is kept now, the button says what it does, and the commit pushes the branch when the
    mark is on.
  - **2.76 (this change). The models the user keeps.** The Mac's model picker holds the
    models the user keeps in a rail of their own, each with the mark that keeps it
    (`ModelPicker.swift:40, 57, 436-440, 500, 732-755`); the port's picker listed every
    model and nothing else. The star is here now — drawn, on the same 16 pt grid as the
    Mac's other marks, not a text glyph — beside every model, and the models it keeps sit
    in a *Starred* group at the top of the list. They are kept whole: the provider, and
    the model's id with its slashes.
  - **2.77 (this change). The effort a model is asked for, and the model the composer
    names.** The Mac's picker asks a model for the effort it wants it at — the levels the
    model has, in the Mac's own words ("xhigh" is *Extra*, "max" is *Max*,
    `ModelPicker.swift:5-14`, `567-614`) — and the composer names the model the
    conversation would use: the session's, else the one picked last, else the engine's own
    default (`Catalog.swift:219-226`). The port's picker had neither: the levels were not
    offered, and the composer said "The engine's choice" where the Mac names a model. The
    levels are offered now, in a group of their own, the effort is written after the
    model's name, and the composer names the model the conversation would use.
  - **2.78 (this change). The image viewer's own header, and the pictures beside it.** The
    Mac's viewer opens on a picture with the others of the same message around it, and says
    so: the picture's name, how many there are, the buttons that act on it, and the arrows
    that step from one to the next (`ImageViewer.swift:128-131`, `164-221`). The port's
    viewer showed one picture and its name, and nothing else. It holds the message's
    pictures now, with the Mac's header and its arrows — and the Mac's keys: Escape and
    space put it away, the arrows step, Ctrl+C copies the picture in view.
  - **2.79 (this change). A project has a name of its own.** A project is a folder on
    the Mac, with a name of its own shown instead of the folder's
    (`Workspace.swift:179-199`), changed in the editor over the window
    (`ProjectEditor.swift:8-13`), from the project's own menu
    (`SidebarView.swift:379-396`). The port's projects were folders and nothing else: the
    name is there now — kept with the project, in the shell's own folder, and shown in the
    sidebar in its place.
  - **2.80 (this change). A project runs its own command.** A project can say what runs
    for it — a dev server, say — and the Mac runs it in the panel's terminal, in the
    project's folder (`Workspace.ProjectSettings.run`, `Workspace.swift:198`;
    `MainView.swift:562-566`, `601-610`, `1479-1491`). The port's projects had a name and
    nothing else. They have the command now, written in the editor beside the name (the
    Mac's own prompt, "npm run dev"), and the title bar carries the button that runs it —
    the Mac's play mark, drawn — which opens the panel on the terminal and sends the
    command there, in the project's folder.
  - **2.81 (this change). A project's other folders, where the agent may work too.** A
    project can span several folders: the agent works in the first, and in the others as
    if they were its own (`Workspace.ProjectSettings.folders`, `Workspace.swift:196`; the
    rules, `ProjectFolders.swift:20-27`; the note that names them,
    `ProjectFolders.swift:36-46`). The port's projects had one folder and nothing else.
    The others are written in the editor beside the name — with the Mac's own note, "Sessions
    run in the primary folder; the agent can work in the others too" — and the session in
    view is given them: the rules that allow those folders, and the note that tells the
    agent that "in chugs-pinterest" means that folder (`SessionModel.swift:1379-1405`).
  - **2.100 (this change). Accounts settings page.** The Mac's Settings has an
    Accounts page (`ProvidersView.swift`) that the port did not draw. It is drawn now,
    listing what's connected and every other provider the engine knows, with a Connect
    action. Your own providers are added on the Providers page.
  - **2.99 (this change). Coding agents on this machine.** The Mac's OutsideAgents
    detects Claude Code, Codex, Cursor, Grok and Antigravity by their CLI; the port did
    not. The Auto settings page now lists them with their install state, looked up on
    PATH.
  - **2.98 (this change). Provider plan usage.** The Usage page asked only what the
    engine ran and cost. It now asks each connected provider its own plan — Copilot and
    OpenRouter first — with the credentials the engine holds, and shows what they
    report. Providers whose endpoint isn't wired yet say so.
  - **2.97 (this change). Browser, Passwords, Phone, Auto and Machines settings
    pages.** The Mac's Settings has five more pages the port did not draw
    (`BrowserSettings.swift`, `PasswordsSettings.swift`, `PhoneSettings.swift`,
    `AutoSettings.swift`, `MachinesSettings.swift`). They are drawn now, with the Mac's
    words: the browser's search engine, history and website data; offering to save
    passwords; pairing a phone; Custom Auto (which runs with the coding agents, not
    available on this client yet); and machines reached over SSH.
  - **2.96 (this change). Storage and Integrations settings pages.** The Mac's Settings
    has Storage and Integrations pages (`StorageSettings.swift`, the integrations list) that
    the port did not draw. They are drawn now, with the engine's status and version, the
    log path, the attachments, and the services that give the agent more tools with their
    connection state.
  - **2.95 (this change). The terminal takes the card's colour.** The Mac's terminal
    is on the card itself: the card's own background, edge to edge, with the text inset,
    and an ANSI palette that stays readable on it, in light or in dark
    (`TerminalSession.swift:108-124`). The port's terminal was a black box in every theme.
    It is the card's fill now, and its colours follow the appearance picker and the system
    theme, the way the Mac's does.
  - **2.94 (this change). New Project and New Chat, in the menu.** The Mac's File
    menu carries *New Project…* (⇧⌘N) and *New Chat* (⌥⌘N); the port drew neither. They
    are drawn now, and ask the page to do them: *New Project…* opens the folder picker,
    *New Chat* starts a session.
  - **2.93 (this change). Worktrees, the Mac's way.** The Mac gives a session its own
    copy of the project on a branch of its own, so its changes stay apart
    (`Workspace.swift:201-216`, `GitSettings.swift:60-136`); the port had none. The harness
    now speaks the engine's worktree routes (`POST /api/worktree`, `DELETE /api/worktree`,
    `GET /api/location`), and a branch is created in the folder it lives in. The app
    tracks the worktrees it made, lists them with their branch, project and folder, shows
    them in the Explorer and removes them — with the Mac's warning about what removal
    deletes. A new session can be given one; the engine runs the project's setup command
    in it first.
  - **2.92 (this change). Three of the settings pages the port was missing.** The Mac's
    Settings has Notifications, Privacy and Panel pages (`GeneralSettings.swift:166-230`,
    `BrowserSettings.swift:5-30`) that the port did not draw. They are drawn now, with the
    Mac's words and toggles: Notifications (sessions, a sound, the count on the taskbar
    icon, and the system's notification settings), Privacy (anonymous usage, what is sent,
    and where the data lives), and Panel (what it starts with, whether it shows itself
    when the agent browses, tidying the agents' tabs, and the new tab page). The values
    stay in the app's own store; the system notification settings open in Windows'
    Settings. The port's own settings list is now missing only the surfaces it does not
    have yet: Accounts, Auto, Worktrees, Machines, Integrations, Browser, Passwords, Phone
    and Storage (Storage lives in Engine & Storage).
  - **2.91 (this change). The terminal is the Mac's terminal.** The port's panel had one
    terminal tab, but its page marked the container ready once and never cleared it, so
    hiding the panel or choosing Files/Changes came back to a dead socket; and addon-fit's
    browser build is a namespace (`{ FitAddon }`), not a class, so the first open threw
    before xterm was drawn. The page keeps one terminal handle for the tab's lifetime now:
    the same ConPTY survives hiding the panel and switching tabs, `FitAddon.FitAddon` is
    read for what it is, and the grid is fitted when the terminal is actually visible — on
    the first open, on a panel resize, and on coming back. The socket carries the project
    folder and the real `cols`/`rows` (`terminal.js`), so the shell starts in the project
    at the size the page drew instead of in the home folder at 80×24; Windows PowerShell
    is the guaranteed shell, with PowerShell 7 when it is installed. A shell that ends says
    why and can be restarted from the note or the panel header, and *New Terminal* restarts
    a dead shell. *Run* matches `TerminalSession.run` (`TerminalSession.swift:56-63`): Ctrl-C,
    300 ms, then the command in the project's folder. The terminal's right-click menu is
    the Mac's: *Add to Message* (a code block, trailing spaces removed), *Copy* and
    *Paste*. The Windows runner now proves the real road with `node-pty` and `ws`: a shell
    in a chosen folder, a resize, an exit, and a second shell, before electron-builder
    rebuilds the module for Electron's ABI.
  - **2.90 (this change). The menu bar's own commands, and Open Quickly.** The port's
    menu bar had the app's commands one by one; it now has the Mac's command groups
    (`KuvoCodeApp.swift:130-229`): File's *Close Tab*, *Close Window*, *Reopen Closed Tab*
    and *Open Quickly…*; Edit's *Find in Conversation…*; the **Session** menu (*Stop*,
    *Build Mode*, *Plan Mode*); the **Tools** menu (*Show Changes*, *Show Files*, *Run*,
    *New Terminal*, *Show Panel*); View's *Show Next Tab*, *Show Previous Tab*, the
    *Show Tab* submenu and the *Appearance* picker; and Help's four links. A closed tab is
    remembered where it was — fifty of them, as the Mac keeps them — and comes back at
    the same index, skipping the ones open again or deleted since
    (`MainView.swift:1150-1232`); closing the tab in view shows the tab that took its
    place, not the last one by default. Open Quickly is the Mac's own palette
    (`OpenQuickly.swift:4-104`): 560 points wide, 80 from the top, a 48-point search,
    30-point rows, ten matches, the project's files newest first before anything is typed,
    and `Mentions.matches`' order after. It opens the chosen file in the panel. The menu's
    tab-bar word and appearance check follow the page (`kuvo:menu-state`). The commands
    for surfaces this client does not have — *New Project*, *New Chat*, the bots,
    *New Browser Tab* and *Accounts* — are not drawn.
  - **2.89 (this change). The panel's tree is the project's, on Windows too.** The Mac's
    panel is rooted at the project's own folder (`FilesView.swift:250-275`): the files are
    the tree, and the folder they live in is the root. The port compared the project's
    folder, written with a slash, with the files' paths, which on Windows are written with
    the other separator: nothing matched, and the tree was rooted at the drive. The two
    are brought to one separator before they are compared now, so the project's folder is
    the root on either platform. 0.5.91's numbered file view and 0.5.92's *Add to Message*
    travel with it: their Windows runs stopped at the tree's root.
  - **2.88 (this change). The file's lines can be sent to the composer.** The Mac's file
    view carries its own right-click menu, and the lines that are picked can be sent to
    the composer as *Add to Message* — the file named as a message names it, and the lines
    that were picked (`CodeTextView.swift:91-111`, `FilesView.swift:38-45`, `389-392`).
    The port's file view had no menu at all. It has the Mac's now, and what it adds goes
    to the composer with the Mac's spacing (`MainView.swift:1239-1253`).
  - **2.87 (this change). A file is shown with its lines numbered.** The Mac shows a file
    in a read-only text view, with the lines numbered in a ruler beside it
    (`CodeTextView.swift:4-6`, `119-168`): the ruler is as wide as the widest number
    needs and 20 more, and the numbers sit 8 pt from the code. The port showed the file
    as plain text, with no numbers at all. It is the Mac's now — the code in the Mac's own
    monospaced face, and the numbers in a ruler beside it.
  - **2.86 (this change). The diff folds the long unchanged stretches, as the Mac's does.**
    The Mac asks git for the whole file as context, and shows each change with a few lines
    around it — three on each side — folding the rest into a row that says how many
    lines it holds, and opens when it is pressed
    (`ProjectChanges.swift:5-6, 179`, `ChangesPanel.swift:890-952`). The port asked git for
    three lines of context and showed them all: a long file came out as a wall of text,
    with nothing folded. Git is asked for the whole file now, and the stretches are folded
    as the Mac folds them — with the Mac's mark, its own words (*N unmodified lines*),
    and its help (*Show these lines*). A file too big to read through is named, not shown,
    as the Mac names it (`ProjectChanges.swift:507-511`).
  - **2.85 (this change). The conversation shows the comments back.** A message that carried
    comments is taken apart when it is shown: the words are the user's own, and each
    comment is a card of its own above them — the place it points to, with the Mac's mark
    beside it, the line it was written on with its own coloured bar, and what it says
    (`ChangesPanel.swift:1123-1155`, `AgentReferences.swift:170-179`). The port showed the
    block the agent reads, as if it were the user's words. The words are the words now,
    and the comments are the Mac's cards (`text.bubble` is drawn for the place).
  - **2.84 (this change). A comment on a line is the Mac's own.** The Mac writes a comment
    in the editor under the line — *Add a comment…*, Escape cancels, ⌘Return saves, and the
    button says *Comment* — and keeps it as a card under that line: the user, the line it
    is on (*Comment on line R12*), and a way to take it away (*Delete*)
    (`ChangesPanel.swift:1088-1212`). A comment stays with the line it was written on, by
    its number and by its text, so it does not slide onto another line when the file
    changes (`ChangesPanel.swift:873-880`). The port had a pencil, a one-line field and a
    note; it has the Mac's now — with the line's own side and text, so the comment can say
    which line it is on. The comments go to the agent in the Mac's own block, with the
    words the user wrote in front of it (`ReviewComments.swift:21-39`).
  - **2.83 (this change). The changes' rows are the Mac's own.** The Mac reads a project's
    changes into lines of their own — a kind, the number the line has on each side, and the
    text (`ProjectChanges.swift:40-48`) — and shows them in a gutter, with the text and no
    patch's signs, and a coloured edge on a line that changed
    (`ChangesPanel.swift:959-1042`). The port showed the patch itself: every line of it, with
    its `+` or `−`, its headers, and no number at all. The rows are the Mac's now — the
    number in the gutter is the old one for a removed line and the new one otherwise
    (`ChangesPanel.swift:882-885`), the text is the line as it reads, and a line that changed
    carries the Mac's 3 pt edge. The mark that writes a comment on a line is the Mac's too,
    in the gutter, under the pointer (*Comment on This Line*,
    `ChangesPanel.swift:980-992`).
  - **2.82 (this change). The Run command's own key, and the palette in the Mac's order.**
    The Mac's palette holds the usual actions first, and the project's *Run* among them
    (`MainView.swift:1418-1462`), with the key that does it (⌘R). The port's palette had
    its own order, and no Run at all. It is the Mac's order now — *New Session*, *Run*,
    *New Terminal*, *Show Changes*, *Show Files*, *Show Panel*, *Hide Sessions*, *Edit
    Project…*, *Find in Conversation…*, *Rename this session*, the settings — with the
    client's own three after them — and the Run has its key (Ctrl+R), which runs the
    project's command, or opens the editor on the run field when there is none yet
    (`MainView.swift:1479-1487`).
  - **2.61 (this change). The provider's marks.** The Mac draws the maker's mark beside
    each model (`ProviderLogo.swift`), monochrome so it follows the ink, or in the maker's
    own colour where it has one. The marks themselves are not published as a package, but
    they are served — the Mac fetches them from models.opencode.ai, and so do we, once
    each, and the page keeps them. Until a mark arrives, the provider's initial stands in
    for it, at 55 % of the size, semibold and rounded, exactly as the Mac does.
  - **2.60 (this change). The sidebar holds every project, and the window has a menu bar.**
    The last of the behaviour differences this port had was the sidebar: the Mac keeps
    several projects, each with its own sessions, and the Recents below them; ours kept
    one folder at a time. Now the sidebar is the Mac's: a *Projects* heading that folds
    away, every project with its drawn folder, its name and a compose button (a session
    in that project), its sessions — five to a project, the rest on request, as
    `SidebarView.swift:62-63` says — and the *Recents*: the eight most recent sessions
    across the projects. The harness serves any project it is asked for
    (`POST /api/project`), the engine already lists the sessions of any directory, and
    the shell and the harness now keep **one** list of recent projects (the same file),
    so the tray's menu and the sidebar are the same list. The shell also grew a real
    menu bar (`NativeMenu.swift:5-165`): the app's own menu, File, Edit, View, Window
    and Help, with the Mac's items and keys; the items that act on the conversation ask
    the page to do it, by the shortcut the Mac uses. And a double-click on the title bar
    zooms the window, as it does on the Mac (`Card.swift:186-198`) — on Windows, that is
    the window maximised.
  - **2.59. The window is built by Next.js, and the page is read in a real browser. The
    app's own code (React and TypeScript, in `windows/app/src`) is the page: Next.js
    builds it as a static export (`output: "export"`), the harness serves those files
    from `windows/harness/ui-build`, and the packed executable carries them inside
    itself. There is no server to render the app later — it talks to the engine over
    the harness's own HTTP API — so the export is the whole app, and it works with no
    network. The Mac's stylesheet, tokens and components are unchanged: the App Router
    renders exactly what the page rendered before. The live page test now runs in
    Chromium (Playwright) rather than in a DOM, because the exported page is ES modules
    and a DOM cannot run them; a real browser is also the better witness, since the
    Mac's screenshots are the arbiter. Two bugs came out of that test and are fixed:
    Escape now goes back one step (the palette, then the settings), and choosing a
    session no longer closes the settings by itself — the engine's "the turn ended"
    event was opening the session again, and the settings went with it.
  - **2.57 (this change).** The layout, seen at last: the app's column was never a column —
    the React root, the body and the grid's row all had to become one, or the composer
    floated at the top of the conversation and the sidebar's glass stopped halfway down. The
    palette is a card of glass again (the search above the list, not beside it), the
    settings' *Done* belongs to the card, and the project path is a label, not a field.
  - **2.56 (this change).** The interface, audited against the craft: your own words are an
    **accent glass** bubble again — translucent, tinted, the light along its top edge — the
    Mac app's own material, not a flat chat blue; the marks that stood for icons (a paperclip,
    a pencil) are drawn now, one stroke; the browser's own surfaces (the selection, the caret,
    the scrollbars) carry the palette; the press is a small compression, not a bounce; and the
    stray rule that had been eating the composer's foot is gone.
  - **2.55 (this change).** The update check that works: our releases are prereleases with
    a tag of their own, which electron-updater does not read — so the shell asks GitHub
    itself, compares the versions, and offers the installer. The promise the settings make
    ("Automatic updates") is kept.
  - **2.54 (this change).** The Mac app's provider compatibility: GitHub Copilot's Claude
    models from 5.1 on refuse the `thinking.block_binding` the engine adds, and the engine
    leaves it out only for the models named in its settings — so the app names them, in the
    settings the engine reads. Nothing else is touched.
  - **2.53 (this change).** The Mac app's drafts: what is typed in a composer but not sent
    is kept, by session, across launches — the attachments that are gone are dropped, and a
    message that could not be sent comes back to the box it was written in.
  - **2.52 (this change).** The Mac app's file links: a code span in a reply that names a
    file of the project — `src/App.tsx:42` — becomes a link, and clicking it opens the file
    in the side panel, the Mac's way. The project asks the server which files are real, so
    a link is a file, never a word.
  - **2.51 (this change).** The palette teaches the keys: it offers what can be done —
    a new session, the conversation as Markdown, the files, the changes, a new terminal — and
    says the keys that do it, the Mac app's way, the keys you recorded included.
  - **2.50 (this change).** What the agent has spent: Settings ▸ Usage shows what the
    engine ran and what it cost, by model and by session, read from the engine's own
    sessions. The Mac's menu-bar panel also follows each provider's *plan* — that asks the
    provider with its own key, and this app leaves the keys where opencode keeps them.
  - **2.49 (this change).** The app wears its own icon, the macOS build's drawing: the
    `.icns` that ships inside the Mac app is made into the `.ico` Windows gives the
    executable, the tray, the window and the page's favicon — the same picture, once.
  - **2.48 (this change).** The Mac app's shortcuts can be *changed* here, the way the Mac's
    `KeyboardShortcuts` bundle does it: click the keys of a shortcut, press the new ones, and
    they are kept in this app's own settings and answered to by the app. The list is the
    Mac's, in the groups it uses, with the keys a Windows user reads (⌘ is Ctrl, ⌥ is Alt).
  - **2.47 (this change).** The Mac app's shipped product inventoried with REA (the bundle:
    157 nodes, complete coverage) and the plan that follows written down in
    `docs/INTEGRATION-PLAN.md`: the icon, the shortcut recorder, the usage panel, the browser
    resources, the commands' sign-ins, the secrets we do not touch, and the upstream surface.
  - **2.46. What floats over the conversation is thicker glass: the
    palette, the gauge's popover, the menus and the note are cards of glass, readable over
    whatever is under them, with the light along their top edge.
  - **2.45 (this change).** The canvas carries a whisper of light, so the glass has
    something to hold, and the materials are in the Mac's order: a thin strip for the chrome,
    a fuller one for the composer and the sheets.
  - **2.44 (this change).** The glass, the Mac app's own: the header and the sidebar are
    strips of it, the composer and the sheets are cards of it, and a card catches the light
    along its top edge. The direction's flatness kept, the Mac's translucence restored.
  - **2.43. A run that failed offers **Try Again** — the Mac app's, with its
    wording — and sends your last message again.
  - **2.42. The image viewer zooms, the Mac app's way: a click zooms it in,
    a click again brings it back, Escape closes it, and +/− zoom from the keyboard.
  - **2.41. The Mac app's tool steps, with its gestures: a step with
    details opens like a button and lights up like one, the rest stay plain lines, what opens
    comes down from the icon along a hairline, and a subagent at work shows its steps. The
    settings' detail pages push in. The motions are written down in DESIGN.md.
  - **2.40. A run is running while its **last words are unfinished**, the Mac
    app's own measure (its `Message.isRunning` reads the message's status), not while the
    engine's session flag still says so — that flag lingers for a moment after the turn is
    over, and the Stop button used to stay. The engine's **own answer** counts too: when it
    loads a session the Mac reads whether that session is among the active ones
    (`SessionModel.swift:573-587`), and its stored words can lag behind it the other way —
    a page that loaded just after a turn ended used to keep showing that the agent was at
    work, long after it stopped. Either half can end a run.
  - **2.38. Providers, the Mac app's way: the engine's own are listed, and
    you can add one of yours with its id, its name, its address and its models — the key is
    not written here, it stays where opencode keeps it.
  - **2.37. The upstream's v0.5.20 behaviour: the sidebar folds away (and
    the conversation moves with it, Ctrl+0), the way the Mac app's does since 0.5.20.
  - **2.36. The Changes panel's pull request, the Mac app's way: the
    branch is pushed, the session's model writes the title and the description (with the
    Git settings' instructions), and the host's pull request page opens with them filled in.
  - **2.35. The import reads opencode's own settings when they are
    `.jsonc` — with comments and trailing commas, the way the tools that write them
    (REA, for one) write them. That is what lets a server installed by another tool
    (REA's 207 reverse-engineering tools, among them) come over to Kuvo Code with one
    click.
  - **2.34. The composer's menus, the Mac app's way: the model and the agent
    are chosen from a searchable list — the models grouped by provider, with their context
    window — instead of a plain drop-down.
  - **2.33. The formulas, the Mac app's MathText: KaTeX renders $inline$
    and $$block$$, the code is put aside first so a dollar sign in a snippet stays one, and
    the fonts travel with the page.
  - **2.32. The image viewer: clicking an attached image opens it over the
    page, the Mac app's way, instead of a new browser tab.
  - **2.31. The Mac app's steps row: between two replies, one line says what
    the agent did — "Thought for 40s, ran 6 commands, read 3 files (1 failed)" — and it opens
    to each step, with the Mac's own words.
  - **2.30. Two more of the Mac app's behaviours: the conversation follows
    the newest words (and offers to come back when you scroll up to read), and selecting a
    passage of the answer offers to *quote* it into the composer, where it joins your next
    message.
  - **2.29. More of the Mac app, in React: the long messages fold with a
    *Show more*, the palette finds the project's files and renames the session, and the
    Changes panel puts a file back as it was. `docs/PARITY.md` now says, feature by
    feature, where the Windows client stands against the Mac app.
  - **2.28. The Changes panel's Branch scope: what the branch added since
    it left its base (the repository's default branch, and the point where they parted), and
    the Mac app's Git settings — the branch prefix and the instructions the model writes
    commit and pull-request messages with.
  - **2.27. The Mac app's Changes panel: an extra tab in the side panel
    with the project's changes, read from git (uncommitted, unstaged, staged) or from the
    session's own edits, each file folded to its changes, a note written on a line that
    goes to the agent with the next message, a commit message the session's model writes
    ("Suggest a Message") and the commit itself.
  - **2.26. The motion layer, in the direction's own hand: the overlays
    rise, the drawer slides, the entries and the questions arrive gently, the engine's dot
    breathes while it works, the scrollbars are thin and quiet. Every duration comes from
    the tokens, so "Motion: Reduced" — and the system's own preference — stop all of it at
    once. With it: the palette answers to the arrow keys, the queue folds away when it is
    long, the split pane reads the session it shows, and files dropped on the composer are
    taken.
  - **2.25. The Mac app's way of putting a session away: a mark of the
    app's own, so it leaves the sidebar but stays searchable — Settings › Archived sessions
    brings it back or deletes it. The Keyboard page lists every shortcut, by where it is
    used, and the ones that were missing work now (Ctrl+N, Ctrl+S, Ctrl+F, Ctrl+,, Ctrl+.).
  - **2.24. The Mac app's searching, in the React view: the sidebar finds
    what was said in any session, the drawer finds the project's files by what is written
    in them, and *Find in conversation* narrows what the export carries.
  - **2.23. The Mac app's General settings on Windows: automatic updates,
    starting at login and keeping the machine awake now live in the app's own settings
    (the shell's file, reached through the harness), and *Bring over from opencode* copies
    the MCP servers, the agents, the commands and the model — the keys stay where they
    are. The context gauge opens its popover (what the window is used for, the cost, and
    *Compact context*).
  - **2.22. The conversation view is React and TypeScript: `windows/app`
    holds the source, `npm run build` bundles it into the page the harness serves, and the
    packed executable carries that build. The state stays a plain object the way the page
    has always kept it; React draws it. The hand-written page stays as a fallback when
    there is no build, so the app never shows nothing.
  - **2.21. The look is bound to OpenDesign's design direction `modern-minimal`
    ("Modern minimal — Linear / Vercel"), read with the tool that ships it
    (`od tools directions --id modern-minimal --json`): system fonts, hairline borders, no
    shadows except what floats, tabular numerals, one accent. The binding was written down in
    `windows/harness/ui/DESIGN.md`; Phase 1 retired it for the Mac's own design layer. Also:
    the settings pages belong to the settings — they had slipped inside the navigation, which
    broke every page of it.
  - **2.20. What other tools write into opencode's own settings is now
    visible and can be brought over: the MCP servers the CLI, another agent, or a tool
    like OpenDesign put in `~/.config/opencode/opencode.json` are listed in Settings ▸
    MCP servers, and one click copies them into this app's own settings — in the shape
    this engine reads (`mcp.servers`, `disabled`), since the engine here reads its own
    folder only. The engine is started over afterwards, so the server connects.
  - **2.19. The packaged app served nothing: the executable's page
    files live inside the binary, and the server asked the disk before the blob, so
    every file came back "Not found." in the installed app (the source tree beside
    the build hid it in CI). The blob is asked first now, and the smoke runs the
    executable from a folder with no `ui/` beside it, so this can't pass unnoticed
    again.
  - **2.18.** Forms (the agent's question tool and MCP servers' asks, answered or
    skipped per field type) and revert (undo to before a user message, the words back in the
    composer, redo brings it all back).
  - **2.17. The settings file: MCP servers (list, add, edit, catalog, timeouts,
    on/off, Try Again), agents (defaults, mode, model, steps, instructions, permission
    rules), skills (list, on/off via deny rule, own SKILL.md files), commands (own, with
    agent/model/subagent/template + the engine's own read-only) — edited in pages like the
    Mac app's, saved whole, with a Restart-the-engine button.
  - **2.16. Engine-surface parity: header branch chip (`api/vcs`),
    per-session changed files (`api/session/:id/diff`), the real queue dock on
    the engine's inbox (steer/queue toggle, take back), context compaction,
    read/unread sessions (`api/session/:id/view`), saved-permission rules
    viewer, the engine's read-only lists in settings, and a manual
    light/dark/system appearance mode.
- **Stage 3.** The rest: usage tray, notifications, machines over SSH, phone
  link, packaging, update feed, signing.

## Packaging and release

The Mac pipeline (`scripts/build-app.sh`, `build-dmg.sh`, `appcast.sh`,
`release.yml`) is codesign/notarize/appcast throughout and is Mac-only. A Windows
pipeline needs: an installer (MSIX or Velopack), Authenticode signing (EV
certificate to avoid SmartScreen), an update feed of its own, file associations
for folders and `.kuvobot`, and a `windows-latest` CI job — the same shape,
different tools.

## Licensing

The repository is PolyForm Noncommercial 1.0.0: you may modify and distribute it
for noncommercial purposes with the license and notices passed on; commercial
distribution — including shipping a Windows harness in or for a business —
needs a written license from the copyright holder (`info@kuvo.run`). The MIT
components (opencode itself, UsageKit's OpenUsage fork, Prism, browser-use, the
SPM dependencies) can be reused with attribution, but the harness as a whole is
a derivative of this repository.

## To verify on real Windows first

- Whether `opencode.exe` honors the XDG folder overrides the way the Linux build
  does (the CI job's `e2e` proves it either way as it lands).
- Whether the Windows engine binaries are Authenticode-signed; if they are, the
  installer should check it the way macOS checks codesign.
- Windows OpenSSH's tunnel lifetime without `ControlMaster`, for the machines
  feature.
