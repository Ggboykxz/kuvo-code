#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";
import { spawn, spawnSync } from "node:child_process";
import { promisify } from "node:util";

const execFile = promisify(spawn);

// Machine config file
const MACHINES_FILE = path.join(os.homedir(), ".kuvo-code", "machines.json");

function readMachines() {
  try { return JSON.parse(fs.readFileSync(MACHINES_FILE, "utf8")); } catch { return []; }
}

function writeMachines(machines) {
  fs.mkdirSync(path.dirname(MACHINES_FILE), { recursive: true });
  fs.writeFileSync(MACHINES_FILE, JSON.stringify(machines, null, 2));
}

export async function handle(ctx, request, response, url) {
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

  // List machines
  if (url.pathname === "/api/machines" && request.method === "GET") {
    const machines = readMachines();
    return json({ machines });
  }

  // Add a machine
  if (url.pathname === "/api/machines" && request.method === "POST") {
    const body = await ctx.readBody(request);
    const { name, destination } = body;
    if (!name?.trim()) throw new HttpError(400, "A machine needs a name.");
    if (!destination?.trim()) throw new HttpError(400, "A machine needs an SSH destination (user@host).");
    
    const machines = readMachines();
    const id = `m-${Date.now()}`;
    machines.push({ id, name: name.trim(), destination: destination.trim(), status: "unknown", created: new Date().toISOString() });
    writeMachines(machines);
    return json({ ok: true, machine: { id, name: name.trim(), destination: destination.trim(), status: "unknown" } });
  }

  // Remove a machine
  if (url.pathname.startsWith("/api/machines/") && request.method === "DELETE") {
    const id = decodeURIComponent(url.pathname.slice("/api/machines/".length));
    const machines = readMachines().filter(m => m.id !== id);
    writeMachines(machines);
    return json({ ok: true });
  }

  // Test SSH reachability
  if (url.pathname.startsWith("/api/machines/") && url.pathname.endsWith("/test") && request.method === "POST") {
    const id = decodeURIComponent(url.pathname.slice("/api/machines/".length, -"/test".length));
    const machines = readMachines();
    const machine = machines.find(m => m.id === id);
    if (!machine) throw new HttpError(404, "Machine not found.");
    
    try {
      // Test SSH connection with a simple command
      const result = await execFile("ssh", ["-o", "ConnectTimeout=10", "-o", "BatchMode=yes", machine.destination, "echo ok"], { timeout: 15000 });
      const ok = result.exitCode === 0;
      machines.forEach(m => { if (m.id === id) m.status = ok ? "reachable" : `unreachable: ${result.stderr?.toString() || "timeout"}`; });
      writeMachines(machines);
      return json({ ok, status: machines.find(m => m.id === id)?.status });
    } catch (error) {
      const msg = error?.stderr?.toString() || error?.message || "timeout";
      machines.forEach(m => { if (m.id === id) m.status = `unreachable: ${msg}`; });
      writeMachines(machines);
      return json({ ok: false, status: `unreachable: ${msg}` });
    }
  }

  // Install engine on remote machine
  if (url.pathname.startsWith("/api/machines/") && url.pathname.endsWith("/install") && request.method === "POST") {
    const id = decodeURIComponent(url.pathname.slice("/api/machines/".length, -"/install".length));
    const machines = readMachines();
    const machine = machines.find(m => m.id === id);
    if (!machine) throw new HttpError(404, "Machine not found.");
    
    try {
      // Run the installer script on the remote machine
      const installScript = `
set -eu
cd ~
if [ ! -d .kuvo-code ]; then
  mkdir -p .kuvo-code
fi
curl -fsSL https://github.com/serhatandic/kuvo-code/releases/latest/download/kuvo-windows-harness.exe -o kuvo-harness.exe || true
chmod +x kuvo-harness.exe
./kuvo-harness.exe --install-engine
      `.trim();
      
      const result = await execFile("ssh", ["-o", "ConnectTimeout=30", machine.destination, installScript], { timeout: 120000 });
      if (result.exitCode !== 0) throw new Error(result.stderr?.toString() || "install failed");
      
      machines.forEach(m => { if (m.id === id) m.status = "engine-installed"; });
      writeMachines(machines);
      return json({ ok: true, status: "engine-installed" });
    } catch (error) {
      const msg = error?.stderr?.toString() || error?.message || "install failed";
      machines.forEach(m => { if (m.id === id) m.status = `install-failed: ${msg}`; });
      writeMachines(machines);
      return json({ ok: false, status: `install-failed: ${msg}` });
    }
  }

  return false;
}
