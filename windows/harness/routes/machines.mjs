#!/usr/bin/env node
// The machines you reach over SSH: kept in ~/.kuvo-code/machines.json, and asked whether SSH
// reaches them. Running a session on one arrives with the machines work; this side only keeps
// the list and checks the way in, so nothing here claims more than it does.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { HttpError } from "../server.mjs";

const run = promisify(execFile);
// Read when asked, not when this file loads: the tests point KUVO_HOME at a folder of their own.
const machinesFile = () => path.join(process.env.KUVO_HOME || path.join(os.homedir(), ".kuvo-code"), "machines.json");

// `user@host`, and nothing that ssh would read as an option of its own: a destination is handed
// to ssh as an argument, so it must never begin with a dash, and it holds no spaces or quotes.
const DESTINATION = /^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$/;

function readMachines() {
  try {
    const kept = JSON.parse(fs.readFileSync(machinesFile(), "utf8"));
    return Array.isArray(kept) ? kept.filter(machine => machine && typeof machine.id === "string") : [];
  } catch {
    return [];
  }
}

function writeMachines(machines) {
  const file = machinesFile();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const beside = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(beside, JSON.stringify(machines, null, 2));
  fs.renameSync(beside, file);
}

function destinationOf(given) {
  const destination = typeof given === "string" ? given.trim() : "";
  if (!DESTINATION.test(destination)) throw new HttpError(400, "A machine's address is user@host.");
  return destination;
}

// What ssh said, in one line, for the row's note.
function saidBy(error) {
  if (error?.code === "ENOENT") return "ssh isn't installed on this computer";
  const text = String(error?.stderr ?? error?.message ?? error).trim().split("\n").filter(Boolean).at(-1) ?? "no answer";
  return text.slice(0, 200);
}

// `ssh` runs beside the harness, never on its path: the first connection records the host's key,
// as ssh itself does when you say yes, and a password is never asked for.
async function reachable(destination) {
  try {
    await run("ssh", [
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=8",
      "-o", "StrictHostKeyChecking=accept-new",
      destination,
      "true",
    ], { timeout: 15_000, windowsHide: true });
    return { ok: true, status: "reachable" };
  } catch (error) {
    return { ok: false, status: `unreachable: ${saidBy(error)}` };
  }
}

function machineUnder(pathname) {
  if (!pathname.startsWith("/api/machines/")) return null;
  try {
    return decodeURIComponent(pathname.slice("/api/machines/".length));
  } catch {
    return null;
  }
}

export async function handle(ctx, request, response, url) {
  const json = (what, status = 200) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };
  const under = machineUnder(url.pathname);

  if (url.pathname === "/api/machines" && request.method === "GET") {
    json({ machines: readMachines() });
    return true;
  }

  if (url.pathname === "/api/machines" && request.method === "POST") {
    const body = await ctx.readBody(request);
    const name = typeof body.name === "string" ? body.name.trim() : "";
    if (!name) throw new HttpError(400, "A machine needs a name.");
    const destination = destinationOf(body.destination);
    const machines = readMachines();
    if (machines.some(machine => machine.destination === destination)) {
      throw new HttpError(409, "That machine is here already.");
    }
    const machine = { id: `m_${Date.now().toString(36)}`, name, destination, status: "unknown", created: new Date().toISOString() };
    writeMachines([...machines, machine]);
    json({ machine });
    return true;
  }

  if (under && !under.includes("/") && request.method === "DELETE") {
    const machines = readMachines();
    const left = machines.filter(machine => machine.id !== under);
    if (left.length === machines.length) throw new HttpError(404, "No such machine.");
    writeMachines(left);
    json({ ok: true });
    return true;
  }

  const asked = under?.match(/^([^/]+)\/test$/);
  if (asked && request.method === "POST") {
    const machines = readMachines();
    const machine = machines.find(each => each.id === asked[1]);
    if (!machine) throw new HttpError(404, "No such machine.");
    const answer = await reachable(machine.destination);
    writeMachines(machines.map(each => each.id === machine.id ? { ...each, status: answer.status } : each));
    json(answer);
    return true;
  }

  return false;
}
