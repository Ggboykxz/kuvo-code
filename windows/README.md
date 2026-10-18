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

## Tests

```sh
node --test windows/                 # the bootstrap: pinned table, checksums, install, start, stop
node --test Packages/KuvoLink/Tests/Bridge/   # the link bridge, including its Windows edges
```

The `.github/workflows/windows-engine.yml` workflow runs both on Linux and on
Windows, and ends by installing and running the real pinned engine on Windows.
