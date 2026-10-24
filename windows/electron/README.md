# Kuvo Code for Windows — shell (Stage 2)

This folder is the native Windows shell: an Electron window around the harness that
already knows how to install and run the engine. Stage 2.1 is the shell and the
installer; the terminal (ConPTY), files panel and diff view follow.

## Run it

```sh
cd windows/electron
npm install
npm start
```

On a developer machine the shell starts `windows/harness/server.mjs` with Node; in a
packaged build it starts the bundled `kuvo-windows-harness.exe` from `resources/`.

## Build the installer

```sh
cd windows/harness && npm install && npm run build:exe     # the harness executable first
cd ../electron && npm install && npm run build              # NSIS installer + portable .exe
npm run smoke                                              # starts the portable build, checks it, stops it
```

The build needs the harness executable in `windows/harness/build/` (the step above
produces it); electron-builder copies it into `resources/harness/`.

## Code signing

The builds are unsigned. For a production release, sign `kuvo-windows-harness.exe` and
the Electron installer with an Authenticode certificate (set `CSC_LINK` /
`CSC_KEY_PASSWORD` in CI), otherwise Windows SmartScreen warns on every update.
