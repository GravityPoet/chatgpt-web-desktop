const ZONES = [
  "UTC",
  "Europe/Amsterdam", "Europe/London", "Europe/Paris", "Europe/Berlin",
  "Europe/Madrid", "Europe/Moscow",
  "Asia/Shanghai", "Asia/Hong_Kong", "Asia/Tokyo", "Asia/Singapore",
  "Asia/Seoul", "Asia/Taipei", "Asia/Bangkok", "Asia/Dubai", "Asia/Kolkata",
  "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
  "America/Sao_Paulo", "Australia/Sydney", "Pacific/Auckland",
];

const sel = document.getElementById("tz");
const cur = document.getElementById("cur");
const st = document.getElementById("status");

async function load() {
  const { tz } = await chrome.storage.local.get("tz");
  const list = Array.from(new Set([tz, ...ZONES].filter(Boolean)));
  sel.replaceChildren();
  for (const z of list) {
    const opt = new Option(z, z); // Option() sets text safely (no HTML parsing)
    if (z === tz) opt.selected = true;
    sel.add(opt);
  }
  cur.textContent = tz || "未设置(系统默认)";
}

async function apply(tz) {
  await chrome.storage.local.set({ tz });
  cur.textContent = tz;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab) chrome.tabs.reload(tab.id);
}

sel.addEventListener("change", () => apply(sel.value));

document.getElementById("auto").addEventListener("click", async () => {
  st.textContent = "检测中…";
  const z = await chrome.runtime.sendMessage({ type: "detectTZ" });
  if (z) {
    if (![...sel.options].some((o) => o.value === z)) {
      sel.add(new Option(z, z), 0);
    }
    sel.value = z;
    await apply(z);
    st.textContent = "已匹配 IP:" + z;
  } else {
    st.textContent = "检测失败,请手动选择";
  }
});

load();
