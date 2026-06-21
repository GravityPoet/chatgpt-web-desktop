import { invoke } from "@tauri-apps/api/core";
import {
  AlertTriangle,
  Globe2,
  KeyRound,
  Loader2,
  Network,
  Pencil,
  Play,
  Plus,
  RefreshCw,
  ShieldCheck,
  Tag,
  Trash2,
  X,
} from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react";

type Account = {
  name: string;
  profile_path: string;
  seed: string;
  region: string | null;
  locale_enabled: boolean;
  proxy_display: string;
  has_proxy: boolean;
};

type LaunchPlan = {
  account: string;
  seed: string;
  profile_path: string;
  extension_runtime_path: string;
  load_extension_paths: string[];
  extra_extension_paths: string[];
  selftest_extension_paths: string[];
  browser_binary: string;
  proxy: {
    mode: "none" | "direct" | "relay";
    display: string;
    browser_arg: string | null;
    relay_needed: boolean;
    raw_url: string | null;
  };
  geo: {
    exit_ip: string | null;
    country: string | null;
    timezone: string | null;
  };
  locale: string | null;
  argv: string[];
  privacy_failures: string[];
};

type DialogState =
  | { kind: "create"; value: string }
  | { kind: "rename"; account: Account; value: string }
  | { kind: "proxy"; account: Account; value: string }
  | { kind: "region"; account: Account; value: string }
  | { kind: "delete"; account: Account };

const emptyAccounts: Account[] = [];

export default function App() {
  const [accounts, setAccounts] = useState<Account[]>(emptyAccounts);
  const [selectedName, setSelectedName] = useState<string>("");
  const [busy, setBusy] = useState(false);
  const [planLoading, setPlanLoading] = useState(false);
  const [error, setError] = useState<string>("");
  const [dialogError, setDialogError] = useState<string>("");
  const [plan, setPlan] = useState<LaunchPlan | null>(null);
  const [dialog, setDialog] = useState<DialogState | null>(null);

  const selected = useMemo(
    () => accounts.find((account) => account.name === selectedName) ?? accounts[0] ?? null,
    [accounts, selectedName],
  );

  async function refresh(preferredName?: string) {
    setError("");
    const next = await call<Account[]>("list_accounts");
    setAccounts(next);
    setSelectedName((current) => {
      if (preferredName && next.some((account) => account.name === preferredName)) return preferredName;
      if (current && next.some((account) => account.name === current)) return current;
      return next[0]?.name ?? "";
    });
  }

  async function run<T>(operation: () => Promise<T>): Promise<T | null> {
    setBusy(true);
    setError("");
    setDialogError("");
    try {
      return await operation();
    } catch (caught) {
      const message = errorMessage(caught);
      setError(message);
      setDialogError(message);
      return null;
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    void run(() => refresh());
  }, []);

  useEffect(() => {
    if (!error) return;
    const timer = window.setTimeout(() => setError(""), 5000);
    return () => window.clearTimeout(timer);
  }, [error]);

  useEffect(() => {
    if (!selected) {
      setPlan(null);
      return;
    }

    let cancelled = false;
    setPlanLoading(true);
    setError("");
    call<LaunchPlan>("launch_dry_run", { name: selected.name })
      .then((dryRun) => {
        if (!cancelled) setPlan(dryRun);
      })
      .catch((caught) => {
        if (!cancelled) {
          setPlan(null);
          setError(errorMessage(caught));
        }
      })
      .finally(() => {
        if (!cancelled) setPlanLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selected?.name]);

  async function submitDialog(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!dialog) return;

    if (dialog.kind === "delete") {
      await confirmDeleteAccount(dialog.account);
      return;
    }

    const value = dialog.value.trim();
    if (dialog.kind === "create") {
      if (!value) return;
      const account = await run(() => call<Account>("create_account", { name: value }));
      if (account) {
        setDialog(null);
        await refresh(account.name);
      }
      return;
    }

    if (dialog.kind === "rename") {
      if (!value || value === dialog.account.name) {
        setDialog(null);
        return;
      }
      const renamed = await run(() =>
        call<Account>("rename_account", { oldName: dialog.account.name, newName: value }),
      );
      if (renamed) {
        setDialog(null);
        await refresh(renamed.name);
      }
      return;
    }

    if (dialog.kind === "proxy") {
      const updated = await run(() =>
        call<Account>("set_proxy", {
          name: dialog.account.name,
          value: value || null,
        }),
      );
      if (updated) {
        setDialog(null);
        await refresh(updated.name);
      }
      return;
    }

    const updated = await run(() =>
      call<Account>("set_region", {
        name: dialog.account.name,
        value: value || null,
      }),
    );
    if (updated) {
      setDialog(null);
      await refresh(updated.name);
    }
  }

  function openCreateDialog() {
    setError("");
    setDialogError("");
    setDialog({ kind: "create", value: "" });
  }

  async function toggleLocale(account: Account) {
    const updated = await run(() => call<Account>("toggle_locale", { name: account.name }));
    if (updated) await refresh(updated.name);
  }

  async function launchAccount(account: Account) {
    await run(() => call<void>("launch_account", { name: account.name }));
  }

  async function confirmDeleteAccount(account: Account) {
    setBusy(true);
    setError("");
    setDialogError("");
    try {
      await call<void>("delete_account", { name: account.name });
      setDialog(null);
      setPlan(null);
      await refresh();
    } catch (caught) {
      const message = errorMessage(caught);
      setDialogError(message);
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  const accountCountLabel = `${accounts.length} account${accounts.length === 1 ? "" : "s"}`;
  const proxyLabel = selected ? middleTruncate(selected.proxy_display, 48) : "";
  const planHasGeo = Boolean(plan?.geo.exit_ip && plan.geo.timezone);
  const planStatusLabel = planLoading
    ? "检查中"
    : plan?.privacy_failures.length
      ? "隐私门禁有警告"
      : plan
        ? planHasGeo
          ? "启动参数已就绪"
          : "快速参数已就绪"
        : "启动参数未解析";

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="mark" />
          <div>
            <strong>Cloak Picker</strong>
            <span>{accountCountLabel}</span>
          </div>
        </div>
        <div className="topActions">
          <IconButton label="刷新" disabled={busy} onClick={() => void run(() => refresh())}>
            <RefreshCw size={15} />
          </IconButton>
          <button className="primaryButton" disabled={busy} onClick={openCreateDialog}>
            <Plus size={15} />
            新建
          </button>
        </div>
      </header>

      <section className="workspace">
        <aside className="sidebar">
          <div className="sidebarHeader">
            <span>Accounts</span>
            {busy ? <Loader2 className="spin" size={14} /> : null}
          </div>

          <div className="accountList">
            {accounts.length === 0 ? (
              <div className="emptyState">
                <ShieldCheck size={24} />
                <strong>暂无账号</strong>
                <button className="subtleButton" onClick={openCreateDialog}>
                  <Plus size={14} />
                  新建账号
                </button>
              </div>
            ) : (
              accounts.map((account) => (
                <button
                  className={`accountRow ${account.name === selected?.name ? "selected" : ""}`}
                  key={account.name}
                  onClick={() => setSelectedName(account.name)}
                  onDoubleClick={() => void launchAccount(account)}
                >
                  <span className="accountRail" />
                  <span className="accountMain">
                    <span className="accountTitle">
                      <strong title={account.name}>{middleTruncate(account.name, 34)}</strong>
                      <code>{account.seed}</code>
                    </span>
                    <span className="accountMeta">
                      <StatusDot active={account.has_proxy} />
                      <span>{account.region ?? "未设区域"}</span>
                      <span>{account.locale_enabled ? "语言开" : "语言关"}</span>
                      <span>{middleTruncate(account.proxy_display, 30)}</span>
                    </span>
                  </span>
                </button>
              ))
            )}
          </div>
        </aside>

        <section className="detail">
          {selected ? (
            <>
              <header className="detailHeader">
                <div className="titleBlock">
                  <span className="eyebrow">Isolated identity</span>
                  <h1 title={selected.name}>{middleTruncate(selected.name, 44)}</h1>
                </div>
                <button className="launchButton" disabled={busy} onClick={() => void launchAccount(selected)}>
                  <Play size={16} />
                  启动
                </button>
              </header>

              <div className="detailScroll">
                <div className={`statusStrip ${plan?.privacy_failures.length || !plan ? "warn" : "ok"}`}>
                  {planLoading ? <Loader2 className="spin" size={15} /> : plan?.privacy_failures.length || !plan ? <AlertTriangle size={15} /> : <ShieldCheck size={15} />}
                  <span>{planStatusLabel}</span>
                </div>

                <section className="inspector">
                  <InspectorGroup title="Identity">
                    <InfoRow icon={<KeyRound size={15} />} label="指纹" value={selected.seed} mono />
                    <InfoRow label="Profile" value={selected.profile_path} mono />
                  </InspectorGroup>

                  <InspectorGroup title="Network">
                    <InfoRow icon={<Tag size={15} />} label="区域" value={selected.region ?? "未设置"} />
                    <InfoRow icon={<Globe2 size={15} />} label="语言" value={selected.locale_enabled ? "跟随出口" : "关"} />
                    <InfoRow icon={<Network size={15} />} label="代理" value={proxyLabel} />
                    <InfoRow label="出口 IP" value={plan?.geo.exit_ip ?? "启动时解析"} />
                    <InfoRow label="时区" value={plan?.geo.timezone ?? "启动时解析"} />
                  </InspectorGroup>

                  <InspectorGroup title="Runtime">
                    <InfoRow label="真实插件" value={plan ? extensionSummary(plan.extra_extension_paths) : "未解析"} />
                    <InfoRow label="自测插件" value={plan ? extensionSummary(plan.selftest_extension_paths) : "未解析"} />
                    <InfoRow label="Browser" value={plan?.browser_binary ?? "未解析"} mono />
                  </InspectorGroup>
                </section>

                {plan?.privacy_failures.length ? (
                  <div className="warningBox">
                    {plan.privacy_failures.map((failure) => (
                      <p key={failure}>{failure}</p>
                    ))}
                  </div>
                ) : null}

                <details className="argv">
                  <summary>argv</summary>
                  <code>{[plan?.browser_binary, ...(plan?.argv ?? [])].filter(Boolean).join(" ")}</code>
                </details>
              </div>

              <footer className="detailFooter">
                <div className="actionBar">
                  <ActionButton icon={<Network size={15} />} label="代理" onClick={() => setDialog({ kind: "proxy", account: selected, value: "" })} />
                  <ActionButton icon={<Tag size={15} />} label="区域" onClick={() => setDialog({ kind: "region", account: selected, value: selected.region ?? "" })} />
                  <ActionButton icon={<Globe2 size={15} />} label={selected.locale_enabled ? "关闭语言" : "开启语言"} onClick={() => void toggleLocale(selected)} />
                  <ActionButton icon={<Pencil size={15} />} label="重命名" onClick={() => setDialog({ kind: "rename", account: selected, value: selected.name })} />
                  <ActionButton danger icon={<Trash2 size={15} />} label="删除" onClick={() => setDialog({ kind: "delete", account: selected })} />
                </div>
              </footer>
            </>
          ) : (
            <div className="emptyState detailEmpty">
              <ShieldCheck size={28} />
              <strong>选择账号</strong>
            </div>
          )}
        </section>
      </section>

      {error && !dialog ? <div className="toast">{error}</div> : null}
      {dialog ? (
        <EditorDialog
          dialog={dialog}
          busy={busy}
          error={dialogError}
          onChange={(next) => {
            setDialogError("");
            setDialog(next);
          }}
          onClose={() => {
            setDialogError("");
            setDialog(null);
          }}
          onConfirmDelete={confirmDeleteAccount}
          onSubmit={submitDialog}
        />
      ) : null}
    </main>
  );
}

function EditorDialog({
  dialog,
  busy,
  error,
  onChange,
  onClose,
  onConfirmDelete,
  onSubmit,
}: {
  dialog: DialogState;
  busy: boolean;
  error: string;
  onChange: (next: DialogState | null) => void;
  onClose: () => void;
  onConfirmDelete: (account: Account) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
}) {
  if (dialog.kind === "delete") {
    return (
      <div className="modalBackdrop">
        <div className="modal" role="dialog" aria-modal="true">
          <button className="modalClose" type="button" aria-label="关闭" onClick={onClose}>
            <X size={15} />
          </button>
          <h2 title={`删除「${dialog.account.name}」？`}>
            删除「<span className="dialogAccountName">{middleTruncate(dialog.account.name, 28)}</span>」？
          </h2>
          <p>Profile、cookie 和登录状态会被清除。</p>
          {error ? <p className="modalError">{error}</p> : null}
          <div className="modalActions">
            <button autoFocus className="secondaryButton" disabled={busy} type="button" onClick={onClose}>
              取消
            </button>
            <button className="dangerButton" disabled={busy} type="button" onClick={() => onConfirmDelete(dialog.account)}>
              {busy ? "删除中..." : "删除"}
            </button>
          </div>
        </div>
      </div>
    );
  }

  const config = dialogConfig(dialog);
  return (
    <div className="modalBackdrop">
      <form className="modal" onSubmit={onSubmit}>
        <button className="modalClose" type="button" aria-label="关闭" onClick={onClose}>
          <X size={15} />
        </button>
        <h2>{config.title}</h2>
        <label className="field">
          <span>{config.label}</span>
          <input
            autoFocus
            value={dialog.value}
            placeholder={config.placeholder}
            onChange={(event) => onChange({ ...dialog, value: event.currentTarget.value })}
          />
        </label>
        {error ? <p className="modalError">{error}</p> : null}
        <div className="modalActions">
          <button className="secondaryButton" type="button" onClick={onClose}>
            取消
          </button>
          <button className="primaryButton" disabled={busy} type="submit">
            {config.action}
          </button>
        </div>
      </form>
    </div>
  );
}

function dialogConfig(dialog: Exclude<DialogState, { kind: "delete" }>) {
  switch (dialog.kind) {
    case "create":
      return { title: "新建账号", label: "名称", placeholder: "work_01", action: "创建" };
    case "rename": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `重命名「${accountName}」`, label: "新名称", placeholder: dialog.account.name, action: "保存" };
    }
    case "proxy": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `代理「${accountName}」`, label: "代理 URL", placeholder: "socks5://user:pass@host:1080", action: dialog.account.has_proxy ? "保存 / 清除" : "保存" };
    }
    case "region": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `区域「${accountName}」`, label: "区域标签", placeholder: "US / JP / Tokyo", action: dialog.account.region ? "保存 / 清除" : "保存" };
    }
  }
}

function IconButton({
  label,
  children,
  onClick,
  disabled,
}: {
  label: string;
  children: ReactNode;
  onClick: () => void;
  disabled?: boolean;
}) {
  return (
    <button className="iconButton" type="button" title={label} aria-label={label} disabled={disabled} onClick={onClick}>
      {children}
    </button>
  );
}

function ActionButton({
  icon,
  label,
  onClick,
  danger,
}: {
  icon: ReactNode;
  label: string;
  onClick: () => void;
  danger?: boolean;
}) {
  return (
    <button className={`actionButton ${danger ? "dangerText" : ""}`} type="button" onClick={onClick}>
      {icon}
      {label}
    </button>
  );
}

function InspectorGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="inspectorGroup">
      <h2>{title}</h2>
      <div>{children}</div>
    </div>
  );
}

function InfoRow({ icon, label, value, mono }: { icon?: ReactNode; label: string; value: string; mono?: boolean }) {
  return (
    <div className="infoRow">
      <span className="infoLabel">
        {icon}
        {label}
      </span>
      <span className={`infoValue ${mono ? "mono" : ""}`} title={value}>
        {value}
      </span>
    </div>
  );
}

function StatusDot({ active }: { active: boolean }) {
  return <span className={`statusDot ${active ? "active" : ""}`} />;
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (shouldUseMockTauri()) {
    return mockInvoke<T>(command, args);
  }
  return invoke<T>(command, args);
}

function shouldUseMockTauri() {
  return import.meta.env.DEV && !("__TAURI_INTERNALS__" in window);
}

async function mockInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  await new Promise((resolve) => window.setTimeout(resolve, 80));
  const accounts = mockAccounts();
  if (command === "list_accounts") return accounts as T;
  if (command === "launch_dry_run") {
    const name = String(args?.name ?? accounts[0].name);
    const account = accounts.find((item) => item.name === name) ?? accounts[0];
    return mockLaunchPlan(account) as T;
  }
  if (command === "create_account") return { ...accounts[0], name: String(args?.name ?? "new"), seed: "68122" } as T;
  if (command === "rename_account") return { ...accounts[0], name: String(args?.newName ?? "renamed") } as T;
  if (command === "set_proxy" || command === "set_region" || command === "toggle_locale") return accounts[0] as T;
  return undefined as T;
}

function mockAccounts(): Account[] {
  return [
    {
      name: "573505658353maddest_ferries3@icloud.com",
      profile_path: "/Users/moonlitpoet/Library/Application Support/ChatGPT Cloak/Accounts/573505658353maddest_ferries3@icloud.com",
      seed: "48366",
      region: null,
      locale_enabled: false,
      proxy_display: "off (system VPN / direct)",
      has_proxy: false,
    },
    {
      name: "moonlitpoet88",
      profile_path: "/Users/moonlitpoet/Library/Application Support/ChatGPT Cloak/Accounts/moonlitpoet88",
      seed: "77296",
      region: "JP",
      locale_enabled: true,
      proxy_display: "off (system VPN / direct)",
      has_proxy: false,
    },
    {
      name: "relish_callous4t",
      profile_path: "/Users/moonlitpoet/Library/Application Support/ChatGPT Cloak/Accounts/relish_callous4t",
      seed: "68098",
      region: "US",
      locale_enabled: false,
      proxy_display: "socks5://proxy.example.net:1080  (via local SOCKS5 relay)",
      has_proxy: true,
    },
  ];
}

function mockLaunchPlan(account: Account): LaunchPlan {
  return {
    account: account.name,
    seed: account.seed,
    profile_path: account.profile_path,
    extension_runtime_path: `${account.profile_path}/.cloak-companion`,
    load_extension_paths: [
      `${account.profile_path}/.cloak-companion`,
      "/Users/moonlitpoet/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件/Chromium Web Store 插件",
      "/Users/moonlitpoet/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    extra_extension_paths: [
      "/Users/moonlitpoet/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件/Chromium Web Store 插件",
      "/Users/moonlitpoet/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    selftest_extension_paths: [
      "/Users/moonlitpoet/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    browser_binary: "/Users/moonlitpoet/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium",
    proxy: {
      mode: account.has_proxy ? "relay" : "none",
      display: account.proxy_display,
      browser_arg: account.has_proxy ? "socks5://127.0.0.1:<relay-port>" : null,
      relay_needed: account.has_proxy,
      raw_url: null,
    },
    geo: { exit_ip: "185.200.65.192", country: account.region, timezone: account.region === "JP" ? "Asia/Tokyo" : "America/Los_Angeles" },
    locale: account.locale_enabled ? "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7" : null,
    argv: [
      `--user-data-dir=${account.profile_path}`,
      `--fingerprint=${account.seed}`,
      "--fingerprint-platform=macos",
      `--load-extension=${account.profile_path}/.cloak-companion`,
      "--no-first-run",
      "--no-default-browser-check",
      "--new-window",
      "https://chatgpt.com/",
    ],
    privacy_failures: [],
  };
}

function middleTruncate(value: string, max: number) {
  if (value.length <= max) return value;
  const keep = Math.max(4, Math.floor((max - 1) / 2));
  return `${value.slice(0, keep)}…${value.slice(-keep)}`;
}

function extensionSummary(paths: string[]) {
  if (paths.length === 0) return "无";
  return paths.map(pathBaseName).join(" / ");
}

function pathBaseName(path: string) {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

function errorMessage(caught: unknown) {
  const raw = caught instanceof Error ? caught.message : String(caught);
  const alreadyExistsPrefix = "account already exists: ";
  const doesNotExistPrefix = "account does not exist: ";
  const runningPrefix = "account is running: ";
  if (raw.startsWith(alreadyExistsPrefix)) {
    return `账号已存在：${raw.slice(alreadyExistsPrefix.length)}`;
  }
  if (raw.startsWith(doesNotExistPrefix)) {
    return `账号不存在：${raw.slice(doesNotExistPrefix.length)}`;
  }
  if (raw.startsWith(runningPrefix)) {
    return `账号正在运行：${raw.slice(runningPrefix.length)}。请先关闭这个浏览器窗口，再删除。`;
  }
  if (raw.includes("account name is invalid")) {
    return "名字无效：可用字母、数字、.、@、+、-、_；不能叫 main，不能以 . 开头/结尾，不能含 /、\\ 或连续 ..。";
  }
  if (raw.includes("unsupported proxy URL")) {
    return "代理须以 socks5://、http:// 或 https:// 开头。";
  }
  return raw;
}
