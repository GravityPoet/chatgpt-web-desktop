#!/usr/bin/env node
// Stealth regression gate. Launches the installed CloakBrowser headfully in a
// THROWAWAY profile (never the real login), drives it over CDP with zero
// dependencies (Node >=21 global WebSocket + fetch), runs probe.html, and
// asserts the stealth invariants. Exits non-zero on any hard regression so it
// can gate an auto-update.
//
// TZ is forced to Asia/Tokyo for the run: the engine-level TZ env var must make
// BOTH the main thread and a Web Worker report Asia/Tokyo. A page-world JS spoof
// cannot do that for workers — this is the exact leak the earlier manual test
// found, now pinned as a regression check.
//
// Usage:  node run-selftest.mjs [--keep] [--json]
//   --keep  leave the browser open (debug)
//   --json  print the raw probe JSON

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const HOME = process.env.HOME;
const BIN = `${HOME}/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium`;
const PROBE = pathToFileURL(join(__dir, "probe.html")).href;
const FORCE_TZ = "Asia/Tokyo";
const TEST_SEED = "24680";
const KEEP = process.argv.includes("--keep");
const RAW = process.argv.includes("--json");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isPrivateV4 = (ip) =>
  /^10\./.test(ip) || /^192\.168\./.test(ip) || /^169\.254\./.test(ip) ||
  /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
const isLinkLocalV6 = (ip) => /^(fe80|fc|fd)/i.test(ip);

async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0; const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  };
  const send = (method, params = {}) =>
    new Promise((res) => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
  return { send, close: () => ws.close() };
}

async function main() {
  if (!existsSync(BIN)) { console.error(`error: binary not found: ${BIN}`); process.exit(2); }

  const dir = mkdtempSync(join(tmpdir(), "cloak-selftest-"));
  const args = [
    `--user-data-dir=${dir}`,
    "--remote-debugging-port=0",
    `--fingerprint=${TEST_SEED}`,
    "--fingerprint-platform=macos",
    "--no-first-run", "--no-default-browser-check",
    "--remote-allow-origins=*",
    PROBE,
  ];
  const child = spawn(BIN, args, { env: { ...process.env, TZ: FORCE_TZ }, stdio: "ignore" });

  let probe, error;
  try {
    // Read the chosen debugging port from the profile.
    let port;
    for (let i = 0; i < 120 && !port; i++) {
      const f = join(dir, "DevToolsActivePort");
      if (existsSync(f)) { const n = parseInt(readFileSync(f, "utf8").split("\n")[0], 10); if (n) port = n; }
      if (!port) await sleep(100);
    }
    if (!port) throw new Error("DevToolsActivePort never appeared");

    // Find the probe page target.
    let target;
    for (let i = 0; i < 60 && !target; i++) {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json().catch(() => []);
      target = list.find((t) => t.type === "page" && (t.url || "").includes("probe.html"))
            || list.find((t) => t.type === "page");
      if (!target) await sleep(150);
    }
    if (!target || !target.webSocketDebuggerUrl) throw new Error("no page target");

    const { send, close } = await cdp(target.webSocketDebuggerUrl);
    await send("Runtime.enable");
    const r = await send("Runtime.evaluate",
      { expression: "window.__runProbe()", awaitPromise: true, returnByValue: true });
    if (r.result?.exceptionDetails) throw new Error("probe threw: " + JSON.stringify(r.result.exceptionDetails));
    probe = r.result?.result?.value;
    if (!probe) throw new Error("probe returned nothing");
    if (!KEEP) close();
  } catch (e) { error = e; }
  finally {
    if (!KEEP) { try { child.kill("SIGKILL"); } catch (_) {} try { rmSync(dir, { recursive: true, force: true }); } catch (_) {} }
  }

  if (error) { console.error(`SELFTEST ERROR: ${error.message}`); process.exit(2); }
  if (RAW) console.log(JSON.stringify(probe, null, 2));

  // ---- assertions -------------------------------------------------------
  const checks = [];
  const hard = (name, pass, got) => checks.push({ name, level: "hard", pass, got });
  const warn = (name, pass, got) => checks.push({ name, level: "warn", pass, got });

  hard("navigator.webdriver is false", probe.webdriver === false, String(probe.webdriver));
  const macUA = /Mac OS X/.test(probe.userAgent || "");
  const macCH = !probe.uaData || probe.uaData.platform === "macOS";
  hard("honest-Mac UA + UA-CH", macUA && macCH, `UA mac=${macUA} CH=${probe.uaData?.platform ?? "n/a"}`);
  hard("main timezone follows TZ env", probe.main_tz === FORCE_TZ, probe.main_tz);
  hard("worker timezone == main (engine-level, no leak)",
       probe.worker_tz === FORCE_TZ && probe.worker_tz === probe.main_tz, probe.worker_tz);

  const v4 = (probe.webrtc_ips || []).filter((x) => /^[0-9.]+$/.test(x));
  const leak = v4.filter(isPrivateV4).concat((probe.webrtc_ips || []).filter(isLinkLocalV6));
  hard("WebRTC: no private/host IP leak", leak.length === 0, JSON.stringify(probe.webrtc_ips || []));
  const pub = v4.filter((x) => !isPrivateV4(x));
  if (pub.length) warn("WebRTC exposed a public IP (expected with STUN; ensure it is the VPN exit)", false, JSON.stringify(pub));

  warn("WebGL renderer is Apple (honest-Mac)", /Apple/i.test(String(probe.webgl_renderer)), String(probe.webgl_renderer));
  warn("canvas hash present (per-seed entropy)", typeof probe.canvas_hash === "string" && !probe.canvas_hash.startsWith("ERR"), probe.canvas_hash);

  // ---- report -----------------------------------------------------------
  const hardFails = checks.filter((c) => c.level === "hard" && !c.pass);
  const warnFails = checks.filter((c) => c.level === "warn" && !c.pass);
  console.log("\nCloak stealth self-test  (seed " + TEST_SEED + ", TZ " + FORCE_TZ + ")");
  console.log("─".repeat(60));
  for (const c of checks) {
    const tag = c.pass ? "PASS" : (c.level === "hard" ? "FAIL" : "WARN");
    console.log(`  ${tag}  ${c.name}\n        → ${c.got}`);
  }
  console.log("─".repeat(60));
  console.log(`  webgl   : ${probe.webgl_vendor} / ${probe.webgl_renderer}`);
  console.log(`  uaData  : ${JSON.stringify(probe.uaData)}`);
  console.log(`  result  : ${hardFails.length === 0 ? "PASS" : "FAIL"}  (${hardFails.length} hard, ${warnFails.length} warn)`);

  try {
    writeFileSync(join(__dir, "last-result.json"),
      JSON.stringify({ ts: probe.ts, verdict: hardFails.length === 0 ? "PASS" : "FAIL", probe, checks }, null, 2));
  } catch (_) {}

  process.exit(hardFails.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(2); });
