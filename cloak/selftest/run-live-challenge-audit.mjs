#!/usr/bin/env node
// Headed/live stealth audit for the local patched CloakBrowser binary.
//
// This is intentionally an audit harness, not a challenge solver: it launches a
// temporary profile with the same Rust launch-plan flags, records observable
// detection-site verdicts, and saves a JSON report plus screenshots.

import { spawn, spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dir = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(__dir);
const CLOAK = join(ROOT, "target", "debug", "cloak");
const EXT_SOURCE = join(ROOT, "extension", "cloak-companion");
const DEFAULT_BIN = `${process.env.HOME}/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium`;
const SHA_FILE = join(ROOT, "packaging", "cloakbrowser-current.sha256");

const SITE_DEFS = {
  sannysoft: {
    url: "https://bot.sannysoft.com",
    waitMs: 6000,
    evaluate: `(() => {
      const rows = Array.from(document.querySelectorAll("table tr"));
      const failed = [];
      let total = 0;
      for (const row of rows) {
        const cells = row.querySelectorAll("td");
        if (cells.length < 2) continue;
        total += 1;
        const key = cells[0].innerText.trim();
        const value = cells[1].innerText.trim();
        const cls = cells[1].className || "";
        if (cls.includes("failed")) failed.push({ key, value });
      }
      return { total, failed, passed: total > 0 && failed.length === 0 };
    })()`,
  },
  browserscan: {
    url: "https://www.browserscan.net/bot-detection",
    waitMs: 9000,
    evaluate: `(() => {
      const text = document.body.innerText || "";
      const normal = (text.match(/Normal/g) || []).length;
      const abnormal = (text.match(/Abnormal/g) || []).length;
      return {
        normal,
        abnormal,
        passed: normal > 0 && abnormal === 0,
        sample: text.slice(0, 800),
      };
    })()`,
  },
  fingerprintjs: {
    url: "https://demo.fingerprint.com/web-scraping",
    waitMs: 9000,
    beforeEvaluate: `(() => {
      const buttons = Array.from(document.querySelectorAll("button"));
      const search = buttons.find((button) => /search/i.test(button.innerText || button.textContent || ""));
      if (search) search.click();
      return Boolean(search);
    })()`,
    afterActionWaitMs: 6000,
    evaluate: `(() => {
      const text = document.body.innerText || "";
      const hasFlights = text.includes("Price per adult") || /\\$\\s*\\d/.test(text);
      const isBlocked = /malicious bot detected/i.test(text)
        || /access denied/i.test(text)
        || /request was blocked/i.test(text)
        || /bot visit detected/i.test(text);
      return {
        passed: hasFlights && !isBlocked,
        isBlocked,
        hasFlights,
        sample: text.slice(0, 800),
      };
    })()`,
  },
  "browserleaks-webrtc": {
    url: "https://browserleaks.com/webrtc",
    waitMs: 8000,
    evaluate: `((expectedIp) => new Promise((resolve) => {
      const text = document.body.innerText || "";
      const candidates = [];
      let pc = null;
      try {
        pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.l.google.com:19302" }] });
        pc.createDataChannel("cloak-audit");
        pc.onicecandidate = (event) => {
          if (event.candidate?.candidate) candidates.push(event.candidate.candidate);
        };
        pc.createOffer().then((offer) => pc.setLocalDescription(offer)).catch(() => {});
      } catch (error) {
        candidates.push(String(error?.message || error));
      }
      setTimeout(() => {
        try { pc?.close(); } catch {}
        const all = [text, ...candidates].join("\\n");
        const ips = Array.from(new Set(all.match(/\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b/g) || []));
        const privateIps = ips.filter((ip) => /^(10\\.|127\\.|169\\.254\\.|192\\.168\\.|172\\.(1[6-9]|2\\d|3[01])\\.)/.test(ip));
        const hasExpectedIp = expectedIp ? all.includes(expectedIp) : null;
        resolve({
          expectedIp,
          pageLoaded: /WebRTC|Local IP|Public IP|Leak/i.test(text),
          ips,
          privateIps,
          hasExpectedIp,
          candidates: candidates.slice(0, 10),
          passed: privateIps.length === 0 && (expectedIp ? hasExpectedIp === true : true),
          sample: text.slice(0, 800),
        });
      }, 5000);
    }))(__EXPECTED_IP__)`,
  },
  creepjs: {
    url: "https://abrahamjuliot.github.io/creepjs",
    waitMs: 18000,
    evaluate: `(() => {
      const text = document.body.innerText || "";
      const likeMatch = text.match(/(\\d+)%\\s*like headless/i);
      const headlessMatch = text.match(/(\\d+)%\\s*headless:/i);
      const stealthMatch = text.match(/(\\d+)%\\s*stealth:/i);
      const scores = {
        likeHeadlessPct: likeMatch ? Number(likeMatch[1]) : null,
        headlessPct: headlessMatch ? Number(headlessMatch[1]) : null,
        stealthPct: stealthMatch ? Number(stealthMatch[1]) : null,
      };
      const signals = (() => {
        try {
          const headless = window.Fingerprint?.headless;
          if (!headless) return null;
          return {
            likeHeadless: headless.likeHeadless || null,
            headless: headless.headless || null,
            stealth: headless.stealth || null,
          };
        } catch {
          return null;
        }
      })();
      const badBot = /you are a bad bot/i.test(text);
      const trustMatch = text.match(/trust score[^0-9]*(\\d+(?:\\.\\d+)?)/i);
      return {
        pageLoaded: /creepjs|trust score|fingerprint|FP ID|Headless/i.test(text),
        trustScore: trustMatch ? Number(trustMatch[1]) : null,
        scores,
        signals,
        badBot,
        passed: text.length > 500
          && !badBot
          && scores.headlessPct !== null
          && scores.stealthPct !== null
          && scores.headlessPct <= 30
          && scores.stealthPct <= 30,
        sample: text.slice(0, 1000),
      };
    })()`,
  },
  "fingerprint-pro": {
    url: "https://fingerprint.com/products/bot-detection",
    waitMs: 12000,
    beforeEvaluate: `(() => {
      const buttons = Array.from(document.querySelectorAll("button, a"));
      const target = buttons.find((button) => {
        const text = (button.innerText || button.textContent || "").trim();
        return /test|try|detect|demo|playground/i.test(text) && !/contact sales|get started/i.test(text);
      });
      if (target) target.click();
      return target ? (target.innerText || target.textContent || "").trim() : "";
    })()`,
    afterActionWaitMs: 5000,
    evaluate: `(async () => {
      const text = document.body.innerText || "";
      const isBlocked = /malicious bot detected|access denied|request was blocked|bad bot|bot visit detected/i.test(text);
      const hasVerdict = /you are|not a bot|human|bot detected|automation|visitor/i.test(text);
      const browserMismatch = /browser not available on mac os x/i.test(text);
      const uaData = navigator.userAgentData
        ? await navigator.userAgentData.getHighEntropyValues([
            "architecture",
            "bitness",
            "brands",
            "fullVersionList",
            "mobile",
            "model",
            "platform",
            "platformVersion",
            "uaFullVersion",
          ]).catch((error) => ({ error: String(error?.message || error) }))
        : null;
      return {
        pageLoaded: /fingerprint|bot detection/i.test(text),
        hasVerdict,
        isBlocked,
        browserMismatch,
        navigator: {
          userAgent: navigator.userAgent,
          platform: navigator.platform,
          language: navigator.language,
          languages: Array.from(navigator.languages || []),
          hardwareConcurrency: navigator.hardwareConcurrency,
          deviceMemory: navigator.deviceMemory ?? null,
          uaData,
        },
        passed: hasVerdict ? !isBlocked && !browserMismatch : false,
        sample: text.slice(0, 1000),
      };
    })()`,
  },
  deviceinfo: {
    url: "https://deviceandbrowserinfo.com/are_you_a_bot",
    waitMs: 10000,
    evaluate: `(() => {
      const text = document.body.innerText || "";
      const botMatch = text.match(/"isBot":\\s*(true|false)/);
      const isBot = botMatch ? botMatch[1] === "true" : null;
      const checks = {};
      for (const key of [
        "isBot",
        "hasBotUserAgent",
        "hasWebdriverTrue",
        "isHeadlessChrome",
        "isAutomatedWithCDP",
        "hasSuspiciousWeakSignals",
        "isPlaywright",
        "hasInconsistentChromeObject",
      ]) {
        const match = text.match(new RegExp('"' + key + '":\\\\s*(true|false)'));
        if (match) checks[key] = match[1] === "true";
      }
      return { passed: isBot === false, isBot, checks, sample: text.slice(0, 800) };
    })()`,
  },
};

function parseArgs(argv) {
  const opts = {
    headless: false,
    keep: false,
    screenshots: true,
    timeoutMs: 45000,
    accountName: `live-audit-${Date.now()}`,
    sites: [],
    manualUrls: [],
    resultDir: "",
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`missing value for ${arg}`);
      return argv[i];
    };
    switch (arg) {
      case "--headless":
        opts.headless = true;
        break;
      case "--headed":
        opts.headless = false;
        break;
      case "--keep":
        opts.keep = true;
        break;
      case "--no-screenshots":
        opts.screenshots = false;
        break;
      case "--timeout-ms":
        opts.timeoutMs = Number(next());
        break;
      case "--account-name":
        opts.accountName = next();
        break;
      case "--site":
        opts.sites.push(next());
        break;
      case "--manual-url":
        opts.manualUrls.push(next());
        break;
      case "--result-dir":
        opts.resultDir = resolve(next());
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (opts.sites.length === 0 && opts.manualUrls.length === 0) {
    opts.sites = ["browserscan", "fingerprintjs"];
  }
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs < 5000) {
    throw new Error("--timeout-ms must be at least 5000");
  }
  for (const site of opts.sites) {
    if (!SITE_DEFS[site]) {
      throw new Error(`unknown site: ${site}; use one of ${Object.keys(SITE_DEFS).join(", ")}`);
    }
  }
  return opts;
}

function runChecked(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    ...options,
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(" ")} failed\n${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function ensureCli() {
  if (existsSync(CLOAK)) return;
  runChecked("cargo", ["build", "-p", "cloak-cli"], { cwd: ROOT });
}

function verifyBrowserHash() {
  const bin = process.env.CLOAK_BROWSER_BIN || DEFAULT_BIN;
  if (!existsSync(bin)) throw new Error(`CloakBrowser binary not found: ${bin}`);
  if (!existsSync(SHA_FILE)) return { bin, checked: false };
  const expected = readFileSync(SHA_FILE, "utf8").trim().split(/\s+/)[0];
  const got = runChecked("shasum", ["-a", "256", bin]).trim().split(/\s+/)[0];
  if (got !== expected) {
    throw new Error(`CloakBrowser hash changed: got ${got}, expected ${expected}`);
  }
  return { bin, checked: true, sha256: got };
}

function truthy(value) {
  return /^(1|on|true|yes)$/i.test(String(value ?? ""));
}

function falsy(value) {
  return /^(0|off|false|no)$/i.test(String(value ?? ""));
}

function companionPageSpoofEnabled() {
  if (Object.prototype.hasOwnProperty.call(process.env, "CLOAK_COMPANION_PAGE_SPOOF")) {
    return !falsy(process.env.CLOAK_COMPANION_PAGE_SPOOF);
  }
  if (Object.prototype.hasOwnProperty.call(process.env, "CLOAK_JS_FINGERPRINT")) {
    return !falsy(process.env.CLOAK_JS_FINGERPRINT);
  }
  return true;
}

function stripCompanionPageScripts(manifestPath) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  delete manifest.content_scripts;
  delete manifest.host_permissions;
  delete manifest.background;
  manifest.permissions = ["storage"];
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function prepareCompanion(plan) {
  const dest = plan.extension_runtime_path;
  rmSync(dest, { recursive: true, force: true });
  cpSync(EXT_SOURCE, dest, { recursive: true });
  if (companionPageSpoofEnabled()) {
    writeFileSync(join(dest, "account-seed-main.js"), `window.__cloakAccountSeed = ${JSON.stringify(String(plan.seed))};\n`);
  } else {
    writeFileSync(join(dest, "account-seed-main.js"), "window.__cloakAccountSeed = \"\";\n");
    stripCompanionPageScripts(join(dest, "manifest.json"));
  }
}

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function cdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("CDP websocket open timeout")), 10000);
    ws.onopen = () => {
      clearTimeout(timer);
      resolve();
    };
    ws.onerror = (error) => {
      clearTimeout(timer);
      reject(error);
    };
  });
  let id = 0;
  const pending = new Map();
  const failAll = (error) => {
    for (const [current, entry] of pending) {
      clearTimeout(entry.timer);
      pending.delete(current);
      entry.reject(error);
    }
  };
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject, timer } = pending.get(message.id);
      clearTimeout(timer);
      pending.delete(message.id);
      if (message.error) {
        reject(new Error(`CDP ${message.error.code}: ${message.error.message}`));
      } else {
        resolve(message);
      }
    }
  };
  ws.onerror = () => failAll(new Error("CDP websocket error"));
  ws.onclose = () => failAll(new Error("CDP websocket closed"));
  const send = (method, params = {}, timeoutMs = 15000) => new Promise((resolve, reject) => {
    const current = ++id;
    const timer = setTimeout(() => {
      pending.delete(current);
      reject(new Error(`${method} timeout`));
    }, timeoutMs);
    pending.set(current, { resolve, reject, timer });
    ws.send(JSON.stringify({ id: current, method, params }));
  });
  const close = () => new Promise((resolve) => {
    try {
      ws.onmessage = null;
      ws.onerror = null;
      failAll(new Error("CDP websocket closing"));
      ws.onclose = resolve;
      ws.close();
      setTimeout(resolve, 500);
    } catch {
      resolve();
    }
  });
  return { send, close };
}

async function evaluate(client, expression, timeoutMs) {
  const request = client.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  }, timeoutMs + 1000);
  const response = await Promise.race([
    request,
    new Promise((_, reject) => setTimeout(() => reject(new Error("Runtime.evaluate timeout")), timeoutMs)),
  ]);
  if (response.result?.exceptionDetails) {
    throw new Error(`evaluate threw: ${JSON.stringify(response.result.exceptionDetails)}`);
  }
  return response.result?.result?.value;
}

async function evaluateJson(client, expression, timeoutMs) {
  const raw = await evaluate(client, `(async () => JSON.stringify(await (${expression})))()`, timeoutMs);
  if (typeof raw !== "string") return null;
  return JSON.parse(raw);
}

function siteEvaluateExpression(site, plan) {
  return site.evaluate.replaceAll("__EXPECTED_IP__", JSON.stringify(plan.geo?.exit_ip || ""));
}

async function waitForDevTools(profilePath, timeoutMs) {
  const portFile = join(profilePath, "DevToolsActivePort");
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(portFile)) {
      const [port] = readFileSync(portFile, "utf8").trim().split(/\r?\n/);
      const list = await fetch(`http://127.0.0.1:${port}/json/list`)
        .then((response) => response.json())
        .catch(() => []);
      const target = list.find((item) => item.type === "page");
      if (target?.webSocketDebuggerUrl) {
        return { port, wsUrl: target.webSocketDebuggerUrl };
      }
    }
    await sleep(100);
  }
  throw new Error("page DevTools target never appeared");
}

async function navigate(client, url, waitMs, timeoutMs) {
  await client.send("Page.enable");
  await client.send("Runtime.enable");
  await client.send("Page.navigate", { url });
  await sleep(Math.min(waitMs, timeoutMs));
}

async function captureScreenshot(client, path) {
  const result = await client.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
  }, 20000);
  if (result.result?.data) {
    writeFileSync(path, Buffer.from(result.result.data, "base64"));
  }
}

function launchArgsFromPlan(plan, opts) {
  const args = plan.argv.filter((arg) => arg !== "--new-window" && !/^https:\/\/chatgpt\.com\/?$/i.test(arg));
  args.push("--remote-debugging-port=0", "--remote-allow-origins=*");
  if (opts.headless) {
    args.push("--headless=new", "--window-size=1440,900", "--force-device-scale-factor=2");
  }
  args.push("about:blank");
  return args;
}

async function run() {
  const opts = parseArgs(process.argv);
  const browser = verifyBrowserHash();
  ensureCli();

  const tempRoot = mkdtempSync(join(tmpdir(), "cloak-live-audit-"));
  const resultDir = opts.resultDir || join(ROOT, "selftest", "live-results", new Date().toISOString().replace(/[:.]/g, "-"));
  mkdirSync(resultDir, { recursive: true });

  const env = {
    ...process.env,
    CLOAK_ACCOUNT_BASE: join(tempRoot, "accounts"),
    CLOAK_EXTRA_EXTENSIONS: process.env.CLOAK_EXTRA_EXTENSIONS || "0",
    LOCALE: process.env.LOCALE || "1",
  };
  mkdirSync(env.CLOAK_ACCOUNT_BASE, { recursive: true });

  runChecked(CLOAK, ["account", "create", opts.accountName, "--json"], { env, cwd: ROOT });
  const plan = JSON.parse(runChecked(CLOAK, ["launch", opts.accountName, "--dry-run", "--json"], { env, cwd: ROOT }));
  if (plan.privacy_failures?.length) {
    throw new Error(`privacy gate inputs failed:\n${plan.privacy_failures.join("\n")}`);
  }
  prepareCompanion(plan);

  const args = launchArgsFromPlan(plan, opts);
  const child = spawn(plan.browser_binary, args, {
    env: { ...env, TZ: plan.geo?.timezone || process.env.TZ || "" },
    stdio: "ignore",
  });

  let client = null;
  const report = {
    ts: new Date().toISOString(),
    mode: opts.headless ? "headless" : "headed",
    browser,
    account: opts.accountName,
    profile_path: plan.profile_path,
    geo: plan.geo,
    locale: plan.locale,
    companion_page_spoof: companionPageSpoofEnabled(),
    extra_extensions: env.CLOAK_EXTRA_EXTENSIONS,
    results: [],
  };

  try {
    const reconnect = async () => {
      if (client) {
        try { await client.close(); } catch {}
        client = null;
      }
      const devtools = await waitForDevTools(plan.profile_path, opts.timeoutMs);
      client = await cdp(devtools.wsUrl);
    };

    for (const siteName of opts.sites) {
      const site = SITE_DEFS[siteName];
      const item = { name: siteName, url: site.url, passed: false };
      try {
        await reconnect();
        await navigate(client, site.url, site.waitMs, opts.timeoutMs);
        if (site.beforeEvaluate) {
          item.action = await evaluate(client, site.beforeEvaluate, 5000);
          await sleep(site.afterActionWaitMs || 3000);
        }
        item.details = await evaluateJson(client, siteEvaluateExpression(site, plan), 12000);
        item.passed = Boolean(item.details?.passed);
        if (opts.screenshots) {
          item.screenshot = join(resultDir, `${siteName}.png`);
          try {
            await captureScreenshot(client, item.screenshot);
          } catch (error) {
            item.screenshot_error = String(error?.message || error);
          }
        }
      } catch (error) {
        item.error = String(error?.message || error);
      }
      report.results.push(item);
      console.log(`${item.passed ? "PASS" : "CHECK"} ${siteName}: ${JSON.stringify(item.details || item.error || {})}`);
    }

    let manualIndex = 0;
    for (const url of opts.manualUrls) {
      manualIndex += 1;
      const name = `manual-${manualIndex}`;
      const item = { name, url, passed: null, manual: true };
      try {
        await reconnect();
        await navigate(client, url, 12000, opts.timeoutMs);
        item.sample = await evaluate(client, "document.body.innerText.slice(0, 1200)", 10000);
        if (opts.screenshots) {
          item.screenshot = join(resultDir, `${name}.png`);
          try {
            await captureScreenshot(client, item.screenshot);
          } catch (error) {
            item.screenshot_error = String(error?.message || error);
          }
        }
      } catch (error) {
        item.error = String(error?.message || error);
      }
      report.results.push(item);
      console.log(`MANUAL ${url}: ${item.screenshot || item.error || "loaded"}`);
    }
  } finally {
    if (client) await client.close();
    if (!opts.keep) {
      try { child.kill("SIGKILL"); } catch {}
      rmSync(tempRoot, { recursive: true, force: true });
    } else {
      report.temp_root = tempRoot;
      report.browser_pid = child.pid;
    }
  }

  const reportPath = join(resultDir, "report.json");
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  const hardFailures = report.results.filter((item) => item.manual !== true && item.passed !== true);
  console.log(`report: ${reportPath}`);
  process.exitCode = hardFailures.length === 0 ? 0 : 1;
}

run().catch((error) => {
  console.error(`LIVE AUDIT ERROR: ${error.message}`);
  process.exit(2);
});
