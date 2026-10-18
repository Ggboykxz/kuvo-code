// The opencode builds the Windows harness is written against, pinned exactly as the Mac app
// pins them (Packages/OpenCodeKit/Sources/OpenCodeKit/Engine/EngineInstaller.swift): the npm
// tarball and its `dist.integrity`, checked before anything is unpacked.
//
// Windows and Linux builds carry no Apple signature; npm's checksum is what vouches for them,
// as it does for the Linux machines the Mac app installs engines on. macOS installs are the
// Mac app's own: this table doesn't carry them.

import path from "node:path";
import os from "node:os";

export const VERSION = "2.0.32";

/// key: `<platform>-<machine>`, as `releaseFor` reads them.
export const RELEASES = new Map([
  ["win32-x64", {
    tarball: "https://registry.npmjs.org/@opencode/cli-windows-x64/-/cli-windows-x64-2.0.32.tgz",
    integrity: "sha512-5VdKolj2/NkSk3BuM4qeiYpnNnGRT7szmd2RIv3+aSDPMwD9yRySYkJ2f1WIM7dTDfO5lZHAXVoipt6+i6AD4A==",
    binary: "opencode.exe",
  }],
  ["win32-arm64", {
    tarball: "https://registry.npmjs.org/@opencode/cli-windows-arm64/-/cli-windows-arm64-2.0.32.tgz",
    integrity: "sha512-T1UGNtrcgDoovpRD3nLqpfZoUh8+pDPlEewALD3QIUOLvuHyy4kUAFra6lLl5kitzqHN5Lm+2iQKX5F81A5hGw==",
    binary: "opencode.exe",
  }],
  ["linux-x64", {
    tarball: "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.0.32.tgz",
    integrity: "sha512-Q50ofBQ3gdwjD6ZQhrVR8fVlm8D2xPMshy4dynY6l6b+qLdKgBSJ9WpoaDyrQX1YWmf2s7IN4RbXmoXXdJitDA==",
    binary: "opencode",
  }],
  ["linux-arm64", {
    tarball: "https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.0.32.tgz",
    integrity: "sha512-YR5O03irvmot/G0f8W49ehvhn5uqCFN3vf9JTsChvf47W6ldjKCNvsaCSXS2SP26dPOUMQBn7WqbKnyHzrNR5w==",
    binary: "opencode",
  }],
]);

/// Node's names for machines, and the `uname -m` ones the Mac app reads for machines.
export function normalizeMachine(machine = process.arch) {
  return { x86_64: "x64", amd64: "x64", x64: "x64", aarch64: "arm64", arm64: "arm64" }[machine] ?? machine;
}

export function releaseFor(platform = process.platform, machine = process.arch) {
  return RELEASES.get(`${platform}-${normalizeMachine(machine)}`) ?? null;
}

/// Where a harness keeps its things when nothing says otherwise: the app's own folder on
/// macOS, `%LOCALAPPDATA%\KuvoCode` on Windows, and the machines' `~/.kuvo-code` on Linux.
export function dataRoot(platform = process.platform, environment = process.env, home = os.homedir()) {
  if (platform === "win32") return path.join(environment.LOCALAPPDATA ?? path.join(home, "AppData", "Local"), "KuvoCode");
  if (platform === "darwin") return path.join(home, "Library", "Application Support", "run.kuvo.code");
  return path.join(home, ".kuvo-code");
}
