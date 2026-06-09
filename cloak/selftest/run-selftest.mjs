#!/usr/bin/env node
// Stealth regression gate. Launches CloakBrowser in throwaway profiles, drives
// probe.html over CDP, and asserts privacy invariants. It can run a single probe
// or a two-profile pair probe for per-seed and storage-isolation checks.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const HOME = process.env.HOME;
const BIN = `${HOME}/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium`;
const PROBE_PATH = join(__dir, "probe.html");
const EXT_SOURCE = join(dirname(__dir), "extension", "cloak-companion");

const defaults = {
  seed: "24680",
  seedB: "13579",
  tz: "Asia/Tokyo",
  expectTimezone: "",
  expectIp: "",
  proxyServer: "",
  acceptLang: "",
  extraExtensions: [],
  headless: false,
  quiet: false,
  resultFile: join(__dir, "last-result.json"),
  keep: false,
  raw: false,
  pair: false,
};

function parseArgs(argv) {
  const o = { ...defaults };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`missing value for ${a}`);
      return argv[i];
    };
    switch (a) {
      case "--seed": o.seed = next(); break;
      case "--seed-b": o.seedB = next(); break;
      case "--tz": o.tz = next(); break;
      case "--expect-timezone": o.expectTimezone = next(); break;
      case "--expect-ip": o.expectIp = next(); break;
      case "--proxy-server": o.proxyServer = next(); break;
      case "--accept-lang": o.acceptLang = next(); break;
      case "--extra-extension": o.extraExtensions.push(next()); break;
      case "--headless": o.headless = true; break;
      case "--quiet": o.quiet = true; break;
      case "--result-file": o.resultFile = next(); break;
      case "--no-result-file": o.resultFile = ""; break;
      case "--keep": o.keep = true; break;
      case "--json": o.raw = true; break;
      case "--pair": o.pair = true; break;
      default:
        throw new Error(`unknown argument: ${a}`);
    }
  }
  if (!o.expectTimezone) o.expectTimezone = o.tz;
  for (const ext of o.extraExtensions) {
    if (ext.includes(",")) throw new Error(`extension path contains comma: ${ext}`);
    if (!existsSync(join(ext, "manifest.json"))) throw new Error(`extension manifest not found: ${ext}`);
  }
  return o;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isPrivateV4 = (ip) =>
  /^10\./.test(ip) || /^192\.168\./.test(ip) || /^169\.254\./.test(ip) ||
  /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
const isLinkLocalV6 = (ip) => /^(fe80|fc|fd)/i.test(ip);
const isErr = (v) => typeof v !== "string" || v === "" || v.startsWith("ERR:");

async function startProbeServer() {
  const html = readFileSync(PROBE_PATH);
  const server = createServer((req, res) => {
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
    });
    res.end(html);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const addr = server.address();
  return {
    url: `http://127.0.0.1:${addr.port}/probe.html`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m);
      pending.delete(m.id);
    }
  };
  const send = (method, params = {}) =>
    new Promise((res) => {
      const i = ++id;
      pending.set(i, res);
      ws.send(JSON.stringify({ id: i, method, params }));
    });
  return { send, close: () => ws.close() };
}

async function evaluate(send, expression, awaitPromise = true, timeoutMs = 20000) {
  const request = send("Runtime.evaluate", {
    expression,
    awaitPromise,
    returnByValue: true,
  });
  const r = await Promise.race([
    request,
    new Promise((_, reject) => setTimeout(() => reject(new Error("Runtime.evaluate timeout")), timeoutMs)),
  ]);
  if (r.result?.exceptionDetails) {
    throw new Error("evaluate threw: " + JSON.stringify(r.result.exceptionDetails));
  }
  return r.result?.result?.value;
}

const storageReadExpression = `new Promise((resolve) => {
  const key = "cloak_pair_marker";
  let done = false;
  const finish = (value) => { if (!done) { done = true; resolve(value); } };
  const result = {
    cookie: document.cookie || "",
    local: localStorage.getItem(key),
    idb: null
  };
  setTimeout(() => { result.idb = "TIMEOUT"; finish(result); }, 3000);
  let req;
  try { req = indexedDB.open("cloak_pair_db", 1); } catch (e) { result.idb = "ERR:" + e; finish(result); return; }
  req.onerror = () => finish(result);
  req.onupgradeneeded = () => {};
  req.onsuccess = () => {
    const db = req.result;
    if (!db.objectStoreNames.contains("kv")) { db.close(); finish(result); return; }
    const tx = db.transaction("kv", "readonly");
    const get = tx.objectStore("kv").get(key);
    get.onsuccess = () => { result.idb = get.result || null; db.close(); finish(result); };
    get.onerror = () => { db.close(); finish(result); };
  };
})`;

const storageWriteExpression = `new Promise((resolve, reject) => {
  const key = "cloak_pair_marker";
  let done = false;
  const finish = (value) => { if (!done) { done = true; resolve(value); } };
  document.cookie = key + "=A; path=/; SameSite=Lax";
  localStorage.setItem(key, "A");
  setTimeout(() => finish("TIMEOUT"), 3000);
  const req = indexedDB.open("cloak_pair_db", 1);
  req.onerror = () => reject(req.error || new Error("idb open failed"));
  req.onupgradeneeded = () => {
    const db = req.result;
    if (!db.objectStoreNames.contains("kv")) db.createObjectStore("kv");
  };
  req.onsuccess = () => {
    const db = req.result;
    const tx = db.transaction("kv", "readwrite");
    tx.objectStore("kv").put("A", key);
    tx.oncomplete = () => { db.close(); finish(true); };
    tx.onerror = () => { db.close(); reject(tx.error || new Error("idb write failed")); };
  };
})`;

async function runProbe(serverUrl, opts, seed, writeStorage) {
  const dir = mkdtempSync(join(tmpdir(), "cloak-selftest-"));
  const extDir = join(dir, "cloak-companion");
  cpSync(EXT_SOURCE, extDir, { recursive: true });
  writeFileSync(extDir + "/account-seed-main.js", `window.__cloakAccountSeed = ${JSON.stringify(String(seed))};\n`);
  const loadExtensionDirs = [extDir, ...opts.extraExtensions];
  const args = [
    `--user-data-dir=${dir}`,
    `--load-extension=${loadExtensionDirs.join(",")}`,
    "--remote-debugging-port=0",
    `--fingerprint=${seed}`,
    "--fingerprint-platform=macos",
    "--no-first-run",
    "--no-default-browser-check",
    "--remote-allow-origins=*",
  ];
  if (opts.headless) {
    args.push("--headless=new", "--window-size=1440,900", "--force-device-scale-factor=2");
  }
  if (opts.proxyServer) {
    args.push(`--proxy-server=${opts.proxyServer}`);
  }
  if (opts.acceptLang) args.push(`--accept-lang=${opts.acceptLang}`);
  args.push("about:blank");

  const child = spawn(BIN, args, {
    env: { ...process.env, TZ: opts.tz },
    stdio: "ignore",
  });

  let client;
  try {
    let port;
    for (let i = 0; i < 300 && !port; i += 1) {
      const f = join(dir, "DevToolsActivePort");
      if (existsSync(f)) {
        const n = parseInt(readFileSync(f, "utf8").split("\n")[0], 10);
        if (n) port = n;
      }
      if (!port) await sleep(100);
    }
    if (!port) throw new Error("DevToolsActivePort never appeared");

    let target;
    for (let i = 0; i < 60 && !target; i += 1) {
      const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json().catch(() => []);
      target = list.find((t) => t.type === "page" && (t.url || "").includes("probe.html"))
            || list.find((t) => t.type === "page");
      if (!target) await sleep(150);
    }
    if (!target || !target.webSocketDebuggerUrl) throw new Error("no page target");

    client = await cdp(target.webSocketDebuggerUrl);
    await client.send("Runtime.enable");
    await client.send("Page.enable");
    await client.send("Page.navigate", { url: serverUrl });
    let ready = false;
    for (let i = 0; i < 60; i += 1) {
      const type = await evaluate(client.send, "typeof window.__runProbe", false, 5000);
      if (type === "function") {
        ready = true;
        break;
      }
      await sleep(100);
    }
    if (!ready) throw new Error("probe script did not load");
    const expectedSeed = JSON.stringify(String(seed));
    for (let i = 0; i < 60; i += 1) {
      const installed = await evaluate(
        client.send,
        `window.__cloakFingerprintInstalled === true && String(window.__cloakAccountSeed || "") === ${expectedSeed}`,
        false,
        5000
      );
      if (installed === true) break;
      await sleep(100);
    }
    await evaluate(client.send, "window.__runProbe()", false, 5000);
    let probe = null;
    for (let i = 0; i < 25; i += 1) {
      probe = await evaluate(client.send, "window.__PROBE || null", false, 5000);
      if (probe && (probe.probe_done || probe.probe_error)) break;
      await sleep(1000);
    }
    if (!probe) throw new Error("probe returned nothing");
    const storageBefore = await evaluate(client.send, storageReadExpression);
    if (writeStorage) await evaluate(client.send, storageWriteExpression);
    return { seed, probe, storageBefore, dir };
  } finally {
    try { client?.close(); } catch (_) {}
    if (!opts.keep) {
      try { child.kill("SIGKILL"); } catch (_) {}
      try { rmSync(dir, { recursive: true, force: true }); } catch (_) {}
    }
  }
}

function storageHasMarker(s) {
  if (!s) return false;
  return s.local === "A" || s.idb === "A" || /(?:^|;\s*)cloak_pair_marker=A(?:;|$)/.test(s.cookie || "");
}

function addProbeChecks(checks, label, probe, opts) {
  const hard = (name, pass, got) => checks.push({ name: `${label}: ${name}`, level: "hard", pass, got });

  hard("probe completed without timeout", !probe.probe_error, probe.probe_error || "ok");
  hard("navigator.webdriver is false", probe.webdriver === false, String(probe.webdriver));
  hard("companion seed hook is installed", probe.cloak?.fingerprintInstalled === true, JSON.stringify(probe.cloak || {}));
  const macUA = /Mac OS X/.test(probe.userAgent || "");
  const macPlatform = probe.platform === "MacIntel";
  const macCH = !probe.uaData || probe.uaData.platform === "macOS";
  hard(
    "UA / platform / UA-CH are coherent Mac",
    macUA && macPlatform && macCH,
    `UA mac=${macUA} platform=${probe.platform} CH=${probe.uaData?.platform ?? "n/a"}`
  );

  hard("main timezone follows expected exit", probe.main_tz === opts.expectTimezone, probe.main_tz);
  hard(
    "worker timezone == expected exit",
    probe.worker_tz === opts.expectTimezone && probe.worker_tz === probe.main_tz,
    probe.worker_tz
  );

  if (opts.expectIp) {
    hard("browser public IP matches preflight exit", probe.fetch_ip === opts.expectIp, probe.fetch_ip);
  } else {
    hard("browser public IP fetch succeeded", !isErr(probe.fetch_ip), probe.fetch_ip);
  }

  if (opts.acceptLang) {
    const expected = opts.acceptLang.split(",", 1)[0].toLowerCase();
    const got = ((probe.languages || [])[0] || "").toLowerCase();
    hard("navigator.languages follows Accept-Language", got === expected, JSON.stringify(probe.languages || []));
  }

  const v4 = (probe.webrtc_ips || []).filter((x) => /^[0-9.]+$/.test(x));
  const leak = v4.filter(isPrivateV4).concat((probe.webrtc_ips || []).filter(isLinkLocalV6));
  hard("WebRTC has no private/host IP leak", leak.length === 0, JSON.stringify(probe.webrtc_ips || []));

  const screenOk = probe.screen && probe.screen.width > 0 && probe.screen.height > 0 &&
    probe.screen.devicePixelRatio > 0 && probe.screen.colorDepth >= 24;
  hard("screen/DPR surface is plausible", screenOk, JSON.stringify(probe.screen));
  const macFonts = probe.fonts && (probe.fonts.menlo || probe.fonts.helveticaNeue || probe.fonts.sfPro);
  hard("Mac font surface is plausible", !!macFonts, JSON.stringify(probe.fonts || {}));
  hard("WebGL renderer is coherent Mac/Apple", /Apple/i.test(String(probe.webgl_renderer)), String(probe.webgl_renderer));
  hard("canvas hash present", !isErr(probe.canvas_hash), probe.canvas_hash);
  hard("getImageData hash present", !isErr(probe.image_data_hash), probe.image_data_hash);
  hard("audio hash present", !isErr(probe.audio_hash), probe.audio_hash);
}

function printReport(report) {
  console.log(`\nCloak stealth self-test  (TZ ${report.options.expectTimezone})`);
  console.log("─".repeat(60));
  for (const c of report.checks) {
    const tag = c.pass ? "PASS" : "FAIL";
    console.log(`  ${tag}  ${c.name}\n        → ${c.got}`);
  }
  console.log("─".repeat(60));
  if (report.single) {
    const p = report.single.probe;
    console.log(`  ip      : ${p.fetch_ip}`);
    console.log(`  webgl   : ${p.webgl_vendor} / ${p.webgl_renderer}`);
    console.log(`  canvas  : ${p.canvas_hash}`);
    console.log(`  audio   : ${p.audio_hash}`);
  }
  if (report.pair) {
    console.log(`  A canvas/audio: ${report.pair.a.probe.canvas_hash} / ${report.pair.a.probe.audio_hash}`);
    console.log(`  B canvas/audio: ${report.pair.b.probe.canvas_hash} / ${report.pair.b.probe.audio_hash}`);
  }
  console.log(`  result  : ${report.verdict}  (${report.checks.filter((c) => !c.pass).length} hard)`);
}

function printQuietReport(report) {
  const fails = report.checks.filter((c) => !c.pass);
  if (fails.length === 0) {
    console.log(`Cloak stealth self-test: PASS (${report.checks.length} checks)`);
    return;
  }
  console.log(`Cloak stealth self-test: FAIL (${fails.length} hard)`);
  for (const c of fails) {
    console.log(`FAIL ${c.name}: ${c.got}`);
  }
  if (report.options.resultFile) console.log(`report: ${report.options.resultFile}`);
}

async function main() {
  const opts = parseArgs(process.argv);
  if (!existsSync(BIN)) throw new Error(`binary not found: ${BIN}`);
  const server = await startProbeServer();

  try {
    const checks = [];
    let single = null;
    let pair = null;

    if (opts.pair) {
      const a = await runProbe(server.url, opts, opts.seed, true);
      const b = await runProbe(server.url, opts, opts.seedB, false);
      pair = { a, b };
      addProbeChecks(checks, "A", a.probe, opts);
      addProbeChecks(checks, "B", b.probe, opts);
      checks.push({
        name: "pair: canvas hashes differ by seed",
        level: "hard",
        pass: a.probe.canvas_hash !== b.probe.canvas_hash,
        got: `${a.probe.canvas_hash} vs ${b.probe.canvas_hash}`,
      });
      checks.push({
        name: "pair: getImageData hashes differ by seed",
        level: "hard",
        pass: a.probe.image_data_hash !== b.probe.image_data_hash,
        got: `${a.probe.image_data_hash} vs ${b.probe.image_data_hash}`,
      });
      checks.push({
        name: "pair: audio hashes differ by seed",
        level: "hard",
        pass: a.probe.audio_hash !== b.probe.audio_hash,
        got: `${a.probe.audio_hash} vs ${b.probe.audio_hash}`,
      });
      checks.push({
        name: "pair: localStorage/cookie/IndexedDB are isolated",
        level: "hard",
        pass: !storageHasMarker(b.storageBefore),
        got: JSON.stringify(b.storageBefore),
      });
    } else {
      single = await runProbe(server.url, opts, opts.seed, false);
      addProbeChecks(checks, "single", single.probe, opts);
    }

    const hardFails = checks.filter((c) => !c.pass);
    const report = {
      ts: Date.now(),
      verdict: hardFails.length === 0 ? "PASS" : "FAIL",
      options: opts,
      single,
      pair,
      checks,
    };

    if (opts.resultFile) {
      try {
        writeFileSync(opts.resultFile, JSON.stringify(report, null, 2));
      } catch (_) {}
    }

    if (opts.raw) console.log(JSON.stringify(report, null, 2));
    else if (opts.quiet) printQuietReport(report);
    else printReport(report);

    process.exitCode = hardFails.length === 0 ? 0 : 1;
  } finally {
    await server.close();
  }
}

main().catch((e) => {
  console.error(`SELFTEST ERROR: ${e.message}`);
  process.exit(2);
});
