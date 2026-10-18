# Windows

The app itself is a native Mac app — SwiftUI and AppKit — so there is no Windows
build of it: a Windows harness is a rewrite of the interface, not a port. This
folder is the part that's the same whoever writes the interface, and it's what
`docs/windows-port.md` plans around.

## The engine bootstrap

`kuvo-engine.mjs` installs the pinned opencode build and starts it the way the
Mac app does (Packages/OpenCodeKit's ServerProcess): `opencode serve --stdio
--port 0`, `{"url": …}` as the first line of stdout, stdin closing as the signal
to shut down. `releases.mjs` holds the pinned tarballs and npm checksums, the
Windows ones verified against the registry.

```sh
node windows/kuvo-engine.mjs install    # download, check the checksum, unpack
node windows/kuvo-engine.mjs launch     # start it; prints {url, password}, stops on stdin close
node windows/kuvo-engine.mjs e2e        # install, start, call it with the password, stop
```

`KUVO_ENGINE_ROOT` moves where builds live (`%LOCALAPPDATA%\KuvoCode\engine` on
Windows), and `KUVO_OPENCODE_BINARY` uses a binary of your own — the same
override the Mac app's scheme has.

It wants Node 22 or later (the version the phone bridge's self-test needs too, for
a global `WebSocket`), and `tar` (Windows 10 and later ship it).

## The conversation view

`harness/` is a minimal client on top of that engine: the part a Windows interface
needs before it needs to look like anything. It supervises the engine itself and
serves a small page — sessions in a folder, a prompt box, the answer streaming in,
permission asks to answer — over the same HTTP API the Mac app calls
(`Packages/OpenCodeKit/Sources/OpenCodeKit/OpenCodeAPI.swift` is the reference for
every route it uses).

```sh
node windows/harness/server.mjs --project C:\work\app    # then open the URL it prints
```

The engine's password stays in the server; the page never sees it. What the page
shows is folded from the engine's events by `harness/transcript.mjs` — a plain
module (no imports) that the browser and the tests load the same copy of, mirroring
`Packages/OpenCodeKit/Sources/OpenCodeKit/Events/Transcript.swift`.

## Tests

```sh
node --test "windows/*.test.mjs"                       # the bootstrap: pinned table, checksums, install, start, stop
node --test "windows/harness/*.test.mjs"               # the client: engine calls, SSE, the transcript, the server in front
node --test "Packages/KuvoLink/Tests/Bridge/*.test.js" # the link bridge, including its Windows edges
```

Two more run the whole loop against the real engine — installing it if it isn't
there, and asking one of the public free models the engine defaults to. They only
run when `KUVO_HARNESS_LIVE=1` is set (`$env:KUVO_HARNESS_LIVE="1"` in PowerShell,
`KUVO_HARNESS_LIVE=1` in a POSIX shell):

```sh
cd windows/harness
npm install                                       # once, for jsdom
npm run test:live
```

`live.test.mjs` takes the engine's side (install, start, events, history), and
`ui.dom.test.mjs` runs `harness/ui/` in a DOM: boot, a session, a prompt, the
answer arriving, the folder picker, and a reload reading the conversation back.

The `.github/workflows/windows-engine.yml` workflow runs all of it on Linux and on
Windows, and ends by installing and running the real pinned engine — and the live
loop — on Windows.
