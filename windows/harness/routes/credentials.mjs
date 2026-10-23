#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { HttpError } from "../server.mjs";
import { spawnSync } from "node:child_process";

const CRED_DIR = path.join(os.homedir(), ".kuvo-code", "credentials");
const CRED_FILE = path.join(CRED_DIR, "index.json");

function readIndex() {
  try { return JSON.parse(fs.readFileSync(CRED_FILE, "utf8")); } catch { return {}; }
}

function writeIndex(index) {
  fs.mkdirSync(CRED_DIR, { recursive: true });
  fs.writeFileSync(CRED_FILE, JSON.stringify(index, null, 2));
}

// Use Windows Credential Manager via cmdkey / Windows.Security.Credentials
function credentialGet(targetName) {
  if (process.platform !== "win32") return null;
  const result = spawnSync("cmdkey", ["/list", targetName], { encoding: "utf8" });
  if (result.status !== 0) return null;
  // Parse cmdkey output to check if credential exists
  return result.stdout.includes(targetName);
}

function credentialSet(targetName, userName, password) {
  if (process.platform !== "win32") return false;
  const result = spawnSync("cmdkey", ["/add", targetName, "/user", userName, "/pass", password], { encoding: "utf8" });
  return result.status === 0;
}

function credentialDelete(targetName) {
  if (process.platform !== "win32") return false;
  const result = spawnSync("cmdkey", ["/delete", targetName], { encoding: "utf8" });
  return result.status === 0;
}

export async function handle(ctx, request, response, url) {
  const json = (what) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(what));
  };

  // List stored credentials (metadata only, not the secrets)
  if (url.pathname === "/api/credentials" && request.method === "GET") {
    const index = readIndex();
    const credentials = Object.entries(index).map(([target, meta]) => ({
      target,
      username: meta.username,
      created: meta.created,
      hasPassword: !!meta.hasPassword,
    }));
    return json({ credentials });
  }

  // Get a specific credential (for auto-fill)
  if (url.pathname.startsWith("/api/credentials/") && request.method === "GET") {
    const target = decodeURIComponent(url.pathname.slice("/api/credentials/".length));
    const index = readIndex();
    const meta = index[target];
    if (!meta) throw new HttpError(404, "Credential not found.");
    
    // On Windows, retrieve from Credential Manager
    let password = null;
    if (process.platform === "win32") {
      // Use a PowerShell script to get the password from Windows Credential Manager
      const psScript = `
$cred = Get-StoredCredential -Target "${target}" -AsCredentialObject
if ($cred) { $cred.GetNetworkCredential().Password } else { "" }
      `.trim();
      const result = spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", psScript], { encoding: "utf8", timeout: 10000 });
      if (result.status === 0 && result.stdout.trim()) {
        password = result.stdout.trim();
      }
    }
    return json({ target, username: meta.username, password });
  }

  // Store a credential
  if (url.pathname === "/api/credentials" && request.method === "POST") {
    const body = await ctx.readBody(request);
    const { target, username, password } = body;
    if (!target?.trim()) throw new HttpError(400, "A target name is required.");
    if (!username?.trim()) throw new HttpError(400, "A username is required.");
    if (!password) throw new HttpError(400, "A password is required.");

    let ok = false;
    if (process.platform === "win32") {
      // Store in Windows Credential Manager
      const psScript = `
$cred = New-Object System.Management.Automation.PSCredential("${username}", (ConvertTo-SecureString "${password.replace(/"/g, '""')}" -AsPlainText -Force))
New-StoredCredential -Target "${target}" -Credential $cred -Persist LocalMachine
      `.trim();
      const result = spawnSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", psScript], { encoding: "utf8", timeout: 10000 });
      ok = result.status === 0;
    } else {
      // Fallback: store encrypted in local file (for non-Windows)
      const crypto = await import("node:crypto");
      const key = crypto.scryptSync(process.env.KUVO_CRED_KEY || "kuvo-code-credentials", "salt", 32);
      const iv = crypto.randomBytes(16);
      const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
      const encrypted = Buffer.concat([cipher.update(password, "utf8"), cipher.final()]);
      const authTag = cipher.getAuthTag();
      const index = readIndex();
      index[target] = { username, iv: iv.toString("base64"), encrypted: encrypted.toString("base64"), authTag: authTag.toString("base64"), created: new Date().toISOString(), hasPassword: true };
      writeIndex(index);
      ok = true;
    }

    if (!ok) throw new HttpError(500, "Failed to store credential.");
    
    const index = readIndex();
    index[target] = { username, created: new Date().toISOString(), hasPassword: true };
    writeIndex(index);
    return json({ ok: true });
  }

  // Delete a credential
  if (url.pathname.startsWith("/api/credentials/") && request.method === "DELETE") {
    const target = decodeURIComponent(url.pathname.slice("/api/credentials/".length));
    
    if (process.platform === "win32") {
      const result = spawnSync("cmdkey", ["/delete", target], { encoding: "utf8" });
      if (result.status !== 0) throw new HttpError(500, "Failed to delete credential.");
    }
    
    const index = readIndex();
    delete index[target];
    writeIndex(index);
    return json({ ok: true });
  }

  return false;
}
