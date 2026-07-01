import { invoke } from "@tauri-apps/api/core";
import {
  ArchiveRestore,
  CalendarClock,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Folder,
  GripVertical,
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
import { useEffect, useMemo, useState, type DragEvent, type FormEvent, type ReactNode } from "react";

type Account = {
  name: string;
  profile_path: string;
  created_at: number;
  archived: boolean;
  trashed: boolean;
  seed: string;
  group: string | null;
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
  | { kind: "group"; account: Account; value: string }
  | { kind: "delete"; account: Account }
  | { kind: "permanentDelete"; account: Account };

const emptyAccounts: Account[] = [];
type AccountView = "active" | "trash";
const allGroupsValue = "__all__";
const allGroupsLabel = "全部";
const ungroupedLabel = "未分组";
const commonGroups = ["codex", "antigravity", "claude"];
const groupOrderStorageKey = "cloak-picker.groupOrder.v1";
const collapsedGroupsStorageKey = "cloak-picker.collapsedGroups.v1";

type GroupOption = {
  label: string;
  value: string;
};

type GroupFilter = GroupOption & {
  count: number;
};

export default function App() {
  const [accounts, setAccounts] = useState<Account[]>(emptyAccounts);
  const [accountView, setAccountView] = useState<AccountView>("active");
  const [selectedName, setSelectedName] = useState<string>("");
  const [selectedGroup, setSelectedGroup] = useState<string>(allGroupsValue);
  const [draggingAccountName, setDraggingAccountName] = useState<string>("");
  const [draggingGroupLabel, setDraggingGroupLabel] = useState<string>("");
  const [dropTargetGroup, setDropTargetGroup] = useState<string>("");
  const [groupOrder, setGroupOrder] = useState<string[]>(() => readStoredStringArray(groupOrderStorageKey));
  const [collapsedGroups, setCollapsedGroups] = useState<string[]>(() =>
    readStoredStringArray(collapsedGroupsStorageKey),
  );
  const [busy, setBusy] = useState(false);
  const [planLoading, setPlanLoading] = useState(false);
  const [error, setError] = useState<string>("");
  const [dialogError, setDialogError] = useState<string>("");
  const [plan, setPlan] = useState<LaunchPlan | null>(null);
  const [dialog, setDialog] = useState<DialogState | null>(null);

  const groupFilters = useMemo(() => buildGroupFilters(accounts, groupOrder), [accounts, groupOrder]);
  const visibleAccounts = useMemo(
    () =>
      selectedGroup === allGroupsValue
        ? accounts
        : accounts.filter((account) => accountGroupLabel(account) === selectedGroup),
    [accounts, selectedGroup],
  );
  const selected = useMemo(
    () => visibleAccounts.find((account) => account.name === selectedName) ?? visibleAccounts[0] ?? null,
    [visibleAccounts, selectedName],
  );
  const groupedAccounts = useMemo(() => orderAccountGroups(groupAccounts(visibleAccounts), groupOrder), [visibleAccounts, groupOrder]);
  const groupOptions = useMemo(() => buildGroupOptions(accounts), [accounts]);

  async function refresh(preferredName?: string, view: AccountView = accountView) {
    setError("");
    const command = view === "trash" ? "list_trashed_accounts" : "list_accounts";
    const next = await call<Account[]>(command);
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
    void run(() => refresh(undefined, accountView));
  }, [accountView]);

  useEffect(() => {
    if (selectedGroup === allGroupsValue) return;
    if (!groupFilters.some((group) => group.value === selectedGroup)) {
      setSelectedGroup(allGroupsValue);
    }
  }, [groupFilters, selectedGroup]);

  useEffect(() => {
    writeStoredStringArray(groupOrderStorageKey, groupOrder);
  }, [groupOrder]);

  useEffect(() => {
    writeStoredStringArray(collapsedGroupsStorageKey, collapsedGroups);
  }, [collapsedGroups]);

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
    if (selected.trashed) {
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
  }, [selected?.name, selected?.trashed]);

  async function submitDialog(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!dialog) return;

    if (dialog.kind === "delete") {
      await confirmDeleteAccount(dialog.account);
      return;
    }

    if (dialog.kind === "permanentDelete") {
      await confirmPermanentDeleteAccount(dialog.account);
      return;
    }

    const value = dialog.value.trim();
    if (dialog.kind === "create") {
      if (!value) return;
      const account = await run(() => call<Account>("create_account", { name: value }));
      if (account) {
        setDialog(null);
        setAccountView("active");
        await refresh(account.name, "active");
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

    if (dialog.kind === "group") {
      await assignAccountGroup(dialog.account, value || null, true);
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

  async function assignAccountGroup(account: Account, value: string | null, closeDialog: boolean) {
    const nextGroup = value?.trim() || null;
    const currentGroup = account.group?.trim() || null;
    if (currentGroup === nextGroup) {
      if (closeDialog) setDialog(null);
      return;
    }

    const updated = await run(() =>
      call<Account>("set_group", {
        name: account.name,
        value: nextGroup,
      }),
    );
    if (!updated) return;
    if (closeDialog) setDialog(null);
    await refresh(updated.name);
  }

  function startAccountDrag(event: DragEvent<HTMLButtonElement>, account: Account) {
    if (account.trashed) return;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", account.name);
    setDraggingAccountName(account.name);
    setSelectedName(account.name);
  }

  function allowGroupDrop(event: DragEvent<HTMLElement>, groupLabel: string) {
    if (!draggingAccountName) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    setDropTargetGroup(groupLabel);
  }

  async function dropAccountOnGroup(event: DragEvent<HTMLElement>, groupLabel: string) {
    event.preventDefault();
    const accountName = event.dataTransfer.getData("text/plain") || draggingAccountName;
    setDraggingAccountName("");
    setDropTargetGroup("");
    const account = accounts.find((item) => item.name === accountName);
    if (!account) return;
    await assignAccountGroup(account, groupLabel === ungroupedLabel ? null : groupLabel, false);
    setSelectedGroup(groupLabel);
  }

  function startGroupDrag(event: DragEvent<HTMLElement>, group: GroupFilter) {
    if (group.value === allGroupsValue) return;
    event.stopPropagation();
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("application/x-cloak-group", group.label);
    setDraggingGroupLabel(group.label);
  }

  function allowGroupReorder(event: DragEvent<HTMLElement>, group: GroupFilter) {
    if (!draggingGroupLabel || group.value === allGroupsValue) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    setDropTargetGroup(group.label);
  }

  function dropGroupOnGroup(event: DragEvent<HTMLElement>, group: GroupFilter) {
    event.preventDefault();
    if (!draggingGroupLabel || group.value === allGroupsValue) return;
    setGroupOrder((current) => reorderGroupLabels(current, groupFilters, draggingGroupLabel, group.label));
    setDraggingGroupLabel("");
    setDropTargetGroup("");
  }

  function handleGroupFilterClick(group: GroupFilter) {
    if (group.value === allGroupsValue && selectedGroup === allGroupsValue) {
      toggleAllGroupsCollapsed();
      return;
    }
    setSelectedGroup(group.value);
  }

  function moveGroupFilter(group: GroupFilter, direction: -1 | 1) {
    if (group.value === allGroupsValue) return;
    setGroupOrder((current) => moveGroupLabel(current, groupFilters, group.label, direction));
  }

  function toggleGroupCollapse(groupLabel: string) {
    setCollapsedGroups((current) => toggleStringInArray(current, groupLabel));
  }

  function toggleAllGroupsCollapsed() {
    const labels = groupedAccounts.map((group) => group.label);
    if (labels.length === 0) return;
    setCollapsedGroups((current) => {
      const next = new Set(current);
      const allCollapsed = labels.every((label) => next.has(label));
      for (const label of labels) {
        if (allCollapsed) {
          next.delete(label);
        } else {
          next.add(label);
        }
      }
      return [...next];
    });
  }

  async function toggleLocale(account: Account) {
    const updated = await run(() => call<Account>("toggle_locale", { name: account.name }));
    if (updated) await refresh(updated.name);
  }

  async function launchAccount(account: Account) {
    if (account.trashed) return;
    const checked = await runFullPreflight(account);
    if (!checked) return;
    if (checked.privacy_failures.length > 0) {
      setError("启动检查未通过，已停止启动。");
      return;
    }
    await run(() => call<void>("launch_account", { name: account.name }));
  }

  async function runFullPreflight(account: Account): Promise<LaunchPlan | null> {
    setPlanLoading(true);
    setError("");
    try {
      const checked = await call<LaunchPlan>("launch_preflight", { name: account.name });
      setPlan(checked);
      return checked;
    } catch (caught) {
      const message = errorMessage(caught);
      setPlan(null);
      setError(message);
      return null;
    } finally {
      setPlanLoading(false);
    }
  }

  async function confirmDeleteAccount(account: Account) {
    setBusy(true);
    setError("");
    setDialogError("");
    try {
      await call<void>("delete_account", { name: account.name });
      setDialog(null);
      setPlan(null);
      await refresh(undefined, accountView);
    } catch (caught) {
      const message = errorMessage(caught);
      setDialogError(message);
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  async function confirmPermanentDeleteAccount(account: Account) {
    setBusy(true);
    setError("");
    setDialogError("");
    try {
      await call<void>("permanently_delete_account", { name: account.name });
      setDialog(null);
      setPlan(null);
      await refresh(undefined, "trash");
    } catch (caught) {
      const message = errorMessage(caught);
      setDialogError(message);
      setError(message);
    } finally {
      setBusy(false);
    }
  }

  async function restoreAccount(account: Account) {
    const restored = await run(() => call<Account>("restore_account", { name: account.name }));
    if (!restored) return;
    setPlan(null);
    setAccountView("active");
    await refresh(restored.name, "active");
  }

  const selectedGroupLabel = selectedGroup === allGroupsValue ? "" : `${selectedGroup} 分组 · `;
  const accountCountLabel =
    accountView === "trash"
      ? `${selectedGroupLabel}${visibleAccounts.length} 个回收站账号`
      : `${selectedGroupLabel}${visibleAccounts.length} 个活跃账号`;
  const emptyTitle = accountView === "trash" ? "回收站为空" : "暂无活跃账号";
  const emptyAction = accountView === "active" ? "新建账号" : "查看活跃";
  const proxyLabel = selected ? middleTruncate(selected.proxy_display, 48) : "";
  const statusLabel = selected?.trashed ? "已移入回收站" : "活跃";
  const reorderableGroupLabels = groupFilters
    .filter((group) => group.value !== allGroupsValue)
    .map((group) => group.label);

  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="mark" />
          <div>
            <strong>Cloak 账号管理</strong>
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
            <span>账号</span>
            {busy ? <Loader2 className="spin" size={14} /> : null}
          </div>
          <div className="viewSwitch" role="tablist" aria-label="账号视图">
            <button
              className={accountView === "active" ? "active" : ""}
              type="button"
              role="tab"
              aria-selected={accountView === "active"}
              onClick={() => setAccountView("active")}
            >
              活跃
            </button>
            <button
              className={accountView === "trash" ? "active" : ""}
              type="button"
              role="tab"
              aria-selected={accountView === "trash"}
              onClick={() => setAccountView("trash")}
            >
              回收站
            </button>
          </div>

          <div className="groupFilter" aria-label="分组筛选">
            {groupFilters.map((group) => {
              const isAll = group.value === allGroupsValue;
              const isActive = selectedGroup === group.value;
              const groupIndex = reorderableGroupLabels.indexOf(group.label);
              const canMoveBackward = groupIndex > 0;
              const canMoveForward = groupIndex >= 0 && groupIndex < reorderableGroupLabels.length - 1;
              return (
                <div
                  className={`groupFilterButton ${isActive ? "active" : ""} ${dropTargetGroup === group.label ? "dropTarget" : ""}`}
                  key={group.value}
                  onDragEnd={() => {
                    setDraggingGroupLabel("");
                    setDropTargetGroup("");
                  }}
                  onDragLeave={() => setDropTargetGroup((current) => (current === group.label ? "" : current))}
                  onDragOver={(event) => {
                    if (draggingGroupLabel) {
                      allowGroupReorder(event, group);
                    } else if (!isAll) {
                      allowGroupDrop(event, group.label);
                    }
                  }}
                  onDrop={(event) => {
                    if (draggingGroupLabel) {
                      dropGroupOnGroup(event, group);
                    } else if (!isAll) {
                      void dropAccountOnGroup(event, group.label);
                    }
                  }}
                >
                  <button
                    className="groupFilterSelect"
                    type="button"
                    aria-pressed={isActive}
                    title={isAll ? "再次点击可折叠或展开全部分组" : "点击查看该分组；拖动抓手或点箭头调整顺序"}
                    onClick={() => handleGroupFilterClick(group)}
                  >
                    {isAll ? null : (
                      <span
                        className="groupDragHandle"
                        draggable
                        title="拖动调整分组顺序"
                        onDragStart={(event) => startGroupDrag(event, group)}
                      >
                        <GripVertical size={12} />
                      </span>
                    )}
                    {isAll ? null : <Folder className="groupIcon" size={12} />}
                    <span className="groupFilterLabel">{group.label}</span>
                    <small>{group.count}</small>
                  </button>
                  {isAll ? null : (
                    <span className="groupMoveControls" aria-label={`${group.label} 分组排序`}>
                      <button
                        className="groupMoveButton"
                        type="button"
                        aria-label={`${group.label} 前移`}
                        title="前移分组"
                        disabled={!canMoveBackward}
                        onClick={() => moveGroupFilter(group, -1)}
                      >
                        <ChevronLeft size={12} />
                      </button>
                      <button
                        className="groupMoveButton"
                        type="button"
                        aria-label={`${group.label} 后移`}
                        title="后移分组"
                        disabled={!canMoveForward}
                        onClick={() => moveGroupFilter(group, 1)}
                      >
                        <ChevronRight size={12} />
                      </button>
                    </span>
                  )}
                </div>
              );
            })}
          </div>

          <div className="accountList">
            {visibleAccounts.length === 0 ? (
              <div className="emptyState">
                {accountView === "active" ? <ShieldCheck size={24} /> : <Trash2 size={24} />}
                <strong>{emptyTitle}</strong>
                <button
                  className="subtleButton"
                  onClick={accountView === "active" ? openCreateDialog : () => setAccountView("active")}
                >
                  {accountView === "active" ? <Plus size={14} /> : <ArchiveRestore size={14} />}
                  {emptyAction}
                </button>
              </div>
            ) : (
              groupedAccounts.map((group) => (
                <AccountGroupSection
                  collapsed={selectedGroup === allGroupsValue && collapsedGroups.includes(group.label)}
                  canCollapse={selectedGroup === allGroupsValue}
                  dropTarget={dropTargetGroup === group.label}
                  group={group}
                  key={group.label}
                  onAllowDrop={allowGroupDrop}
                  onDropAccount={dropAccountOnGroup}
                  onLaunchAccount={launchAccount}
                  onRestoreAccount={restoreAccount}
                  onSelectAccount={setSelectedName}
                  onStartAccountDrag={startAccountDrag}
                  onToggleCollapse={toggleGroupCollapse}
                  selectedName={selected?.name ?? ""}
                  setDraggingAccountName={setDraggingAccountName}
                  setDropTargetGroup={setDropTargetGroup}
                />
              ))
            )}
          </div>
        </aside>

        <section className="detail">
          {selected ? (
            <>
              <header className="detailHeader">
                <div className="titleBlock">
                  <span className="eyebrow">隔离身份</span>
                  <h1 title={selected.name}>{middleTruncate(selected.name, 44)}</h1>
                </div>
                {selected.trashed ? (
                  <button className="launchButton" disabled={busy} onClick={() => void restoreAccount(selected)}>
                    <ArchiveRestore size={16} />
                    恢复
                  </button>
                ) : (
                  <button className="launchButton" disabled={busy || planLoading} onClick={() => void launchAccount(selected)}>
                    <Play size={16} />
                    启动
                  </button>
                )}
              </header>

              <div className="detailScroll">
                <section className="inspector">
                  <InspectorGroup title="身份">
                    <InfoRow icon={<KeyRound size={15} />} label="指纹" value={selected.seed} mono />
                    <InfoRow icon={<Folder size={15} />} label="分组" value={accountGroupLabel(selected)} />
                    <InfoRow icon={<CalendarClock size={15} />} label="创建时间" value={formatCreatedAt(selected.created_at)} />
                    <InfoRow icon={selected.trashed ? <Trash2 size={15} /> : <ShieldCheck size={15} />} label="状态" value={statusLabel} />
                    <InfoRow label="账号目录" value={selected.profile_path} mono />
                  </InspectorGroup>

                  <InspectorGroup title="网络">
                    <InfoRow icon={<Tag size={15} />} label="区域" value={selected.region ?? "未设置"} />
                    <InfoRow icon={<Globe2 size={15} />} label="语言" value={selected.locale_enabled ? "跟随出口" : "关"} />
                    <InfoRow icon={<Network size={15} />} label="代理" value={proxyLabel} />
                    <InfoRow label="出口 IP" value={plan?.geo.exit_ip ?? "启动时解析"} />
                    <InfoRow label="时区" value={plan?.geo.timezone ?? "启动时解析"} />
                  </InspectorGroup>

                  <InspectorGroup title="运行">
                    <InfoRow label="真实插件" value={plan ? extensionSummary(plan.extra_extension_paths) : "未解析"} />
                    <InfoRow label="自测插件" value={plan ? extensionSummary(plan.selftest_extension_paths) : "未解析"} />
                    <InfoRow label="浏览器" value={plan?.browser_binary ?? "未解析"} mono />
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
                  <summary>启动参数</summary>
                  <code>{[plan?.browser_binary, ...(plan?.argv ?? [])].filter(Boolean).join(" ")}</code>
                </details>
              </div>

              <footer className="detailFooter">
                <div className="actionBar">
                  {selected.trashed ? (
                    <>
                      <ActionButton icon={<ArchiveRestore size={15} />} label="恢复账号" onClick={() => void restoreAccount(selected)} />
                      <ActionButton danger icon={<Trash2 size={15} />} label="彻底删除" onClick={() => setDialog({ kind: "permanentDelete", account: selected })} />
                    </>
                  ) : (
                    <>
                      <ActionButton icon={<Network size={15} />} label="代理" onClick={() => setDialog({ kind: "proxy", account: selected, value: "" })} />
                      <ActionButton icon={<Tag size={15} />} label="区域" onClick={() => setDialog({ kind: "region", account: selected, value: selected.region ?? "" })} />
                      <ActionButton icon={<Folder size={15} />} label="分组" onClick={() => setDialog({ kind: "group", account: selected, value: selected.group ?? "" })} />
                      <ActionButton icon={<Globe2 size={15} />} label={selected.locale_enabled ? "关闭语言" : "开启语言"} onClick={() => void toggleLocale(selected)} />
                      <ActionButton icon={<Pencil size={15} />} label="重命名" onClick={() => setDialog({ kind: "rename", account: selected, value: selected.name })} />
                      <ActionButton danger icon={<Trash2 size={15} />} label="删除" onClick={() => setDialog({ kind: "delete", account: selected })} />
                    </>
                  )}
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
          onConfirmPermanentDelete={confirmPermanentDeleteAccount}
          groupOptions={groupOptions}
          onQuickGroup={(account, value) => void assignAccountGroup(account, value || null, true)}
          onSubmit={submitDialog}
        />
      ) : null}
    </main>
  );
}

function AccountGroupSection({
  canCollapse,
  collapsed,
  dropTarget,
  group,
  selectedName,
  onAllowDrop,
  onDropAccount,
  onLaunchAccount,
  onRestoreAccount,
  onSelectAccount,
  onStartAccountDrag,
  onToggleCollapse,
  setDraggingAccountName,
  setDropTargetGroup,
}: {
  canCollapse: boolean;
  collapsed: boolean;
  dropTarget: boolean;
  group: AccountGroup;
  selectedName: string;
  onAllowDrop: (event: DragEvent<HTMLElement>, groupLabel: string) => void;
  onDropAccount: (event: DragEvent<HTMLElement>, groupLabel: string) => Promise<void>;
  onLaunchAccount: (account: Account) => Promise<void>;
  onRestoreAccount: (account: Account) => Promise<void>;
  onSelectAccount: (name: string) => void;
  onStartAccountDrag: (event: DragEvent<HTMLButtonElement>, account: Account) => void;
  onToggleCollapse: (groupLabel: string) => void;
  setDraggingAccountName: (name: string) => void;
  setDropTargetGroup: (groupLabel: string) => void;
}) {
  return (
    <section
      className={`accountGroup ${dropTarget ? "dropTarget" : ""} ${collapsed ? "collapsed" : ""}`}
      onDragLeave={() => setDropTargetGroup("")}
      onDragOver={(event) => onAllowDrop(event, group.label)}
      onDrop={(event) => void onDropAccount(event, group.label)}
    >
      <div className="accountGroupHeader">
        <button
          className="accountGroupName"
          type="button"
          title={canCollapse ? "点击折叠或展开该分组" : group.label}
          onClick={() => {
            if (canCollapse) onToggleCollapse(group.label);
          }}
        >
          {canCollapse ? (
            collapsed ? (
              <ChevronRight className="collapseIcon" size={13} />
            ) : (
              <ChevronDown className="collapseIcon" size={13} />
            )
          ) : (
            <Folder size={13} />
          )}
          <strong>{middleTruncate(group.label, 28)}</strong>
        </button>
        <span className="accountGroupCount">{group.accounts.length}</span>
      </div>
      {collapsed
        ? null
        : group.accounts.map((account) => (
            <button
              className={`accountRow ${account.name === selectedName ? "selected" : ""}`}
              draggable={!account.trashed}
              key={account.name}
              title={account.trashed ? account.name : `${account.name}｜拖动可调整分组`}
              onClick={() => onSelectAccount(account.name)}
              onDoubleClick={() => {
                if (account.trashed) {
                  void onRestoreAccount(account);
                } else {
                  void onLaunchAccount(account);
                }
              }}
              onDragEnd={() => {
                setDraggingAccountName("");
                setDropTargetGroup("");
              }}
              onDragStart={(event) => onStartAccountDrag(event, account)}
            >
              <span className="accountRail" />
              <span className="accountMain">
                <span className="accountTitle">
                  <GripVertical className="dragHandle" size={14} />
                  <strong title={account.name}>{middleTruncate(account.name, 34)}</strong>
                  <code>{account.seed}</code>
                </span>
              </span>
            </button>
          ))}
    </section>
  );
}

function EditorDialog({
  dialog,
  busy,
  error,
  onChange,
  onClose,
  onConfirmDelete,
  onConfirmPermanentDelete,
  groupOptions,
  onQuickGroup,
  onSubmit,
}: {
  dialog: DialogState;
  busy: boolean;
  error: string;
  onChange: (next: DialogState | null) => void;
  onClose: () => void;
  onConfirmDelete: (account: Account) => void;
  onConfirmPermanentDelete: (account: Account) => void;
  groupOptions: GroupOption[];
  onQuickGroup: (account: Account, value: string) => void;
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
          <p>账号会移入回收站，可恢复；账号目录、登录数据和缓存会保留，不会立即释放磁盘。</p>
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

  if (dialog.kind === "permanentDelete") {
    return (
      <div className="modalBackdrop">
        <div className="modal" role="alertdialog" aria-modal="true">
          <button className="modalClose" type="button" aria-label="关闭" onClick={onClose}>
            <X size={15} />
          </button>
          <h2 title={`彻底删除「${dialog.account.name}」？`}>
            彻底删除「<span className="dialogAccountName">{middleTruncate(dialog.account.name, 28)}</span>」？
          </h2>
          <p>将永久删除该账号目录、登录数据和缓存。此操作不可恢复。</p>
          {error ? <p className="modalError">{error}</p> : null}
          <div className="modalActions">
            <button autoFocus className="secondaryButton" disabled={busy} type="button" onClick={onClose}>
              取消
            </button>
            <button className="dangerButton" disabled={busy} type="button" onClick={() => onConfirmPermanentDelete(dialog.account)}>
              {busy ? "删除中..." : "彻底删除"}
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
        {config.description ? <p>{config.description}</p> : null}
        {dialog.kind === "group" ? (
          <div className="groupPicker" aria-label="可选分组">
            {groupOptions.map((option) => {
              const activeValue = dialog.value.trim();
              const isActive = option.value === activeValue || (!option.value && !activeValue);
              return (
                <button
                  className={`groupOption ${isActive ? "active" : ""}`}
                  disabled={busy}
                  key={option.label}
                  type="button"
                  aria-pressed={isActive}
                  onClick={() => onQuickGroup(dialog.account, option.value)}
                >
                  <Folder size={13} />
                  <span>{option.label}</span>
                </button>
              );
            })}
          </div>
        ) : null}
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

function dialogConfig(dialog: Exclude<DialogState, { kind: "delete" } | { kind: "permanentDelete" }>): {
  title: string;
  label: string;
  placeholder: string;
  action: string;
  description?: string;
} {
  switch (dialog.kind) {
    case "create":
      return { title: "新建账号", label: "名称", placeholder: "work_01", action: "创建" };
    case "rename": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `重命名「${accountName}」`, label: "新名称", placeholder: dialog.account.name, action: "保存" };
    }
    case "proxy": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `代理「${accountName}」`, label: "代理地址", placeholder: "socks5://user:pass@host:1080", action: dialog.account.has_proxy ? "保存 / 清除" : "保存" };
    }
    case "region": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `区域「${accountName}」`, label: "区域代码", placeholder: "US / JP / Tokyo", action: dialog.account.region ? "保存 / 清除" : "保存" };
    }
    case "group": {
      const accountName = middleTruncate(dialog.account.name, 28);
      return { title: `分组「${accountName}」`, label: "分组名称", placeholder: "codex / antigravity / claude", action: dialog.account.group ? "保存 / 清除" : "保存" };
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

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (shouldUseMockTauri()) {
    return mockInvoke<T>(command, args);
  }
  return invoke<T>(command, args);
}

type AccountGroup = {
  label: string;
  accounts: Account[];
};

function groupAccounts(accounts: Account[]): AccountGroup[] {
  const groups: AccountGroup[] = [];
  const indexes = new Map<string, number>();
  for (const account of accounts) {
    const label = accountGroupLabel(account);
    const existing = indexes.get(label);
    if (existing === undefined) {
      indexes.set(label, groups.length);
      groups.push({ label, accounts: [account] });
    } else {
      groups[existing].accounts.push(account);
    }
  }
  return groups;
}

function buildGroupOptions(accounts: Account[]): GroupOption[] {
  const options: GroupOption[] = [{ label: ungroupedLabel, value: "" }];
  const seen = new Set<string>([ungroupedLabel]);
  for (const account of accounts) {
    const label = account.group?.trim();
    if (!label || seen.has(label)) continue;
    seen.add(label);
    options.push({ label, value: label });
  }
  for (const label of commonGroups) {
    if (seen.has(label)) continue;
    seen.add(label);
    options.push({ label, value: label });
  }
  return options;
}

function orderAccountGroups(groups: AccountGroup[], groupOrder: string[]): AccountGroup[] {
  const labels = orderGroupLabels(
    groups.map((group) => group.label),
    groupOrder,
  );
  const groupsByLabel = new Map(groups.map((group) => [group.label, group]));
  return labels.map((label) => groupsByLabel.get(label)).filter((group): group is AccountGroup => Boolean(group));
}

function buildGroupFilters(accounts: Account[], groupOrder: string[]): GroupFilter[] {
  const groups = groupAccounts(accounts);
  const counts = new Map(groups.map((group) => [group.label, group.accounts.length]));
  for (const label of commonGroups) {
    if (!counts.has(label)) counts.set(label, 0);
  }
  const labels = orderGroupLabels([...counts.keys()], groupOrder);
  const filters: GroupFilter[] = [{ label: allGroupsLabel, value: allGroupsValue, count: accounts.length }];
  for (const label of labels) {
    filters.push({ label, value: label, count: counts.get(label) ?? 0 });
  }
  return filters;
}

function orderGroupLabels(labels: string[], groupOrder: string[]): string[] {
  const known = new Set(labels);
  const ordered = groupOrder.filter((label) => known.has(label));
  const remaining = labels.filter((label) => !ordered.includes(label));
  return [...ordered, ...remaining];
}

function reorderGroupLabels(currentOrder: string[], filters: GroupFilter[], source: string, target: string): string[] {
  if (!source || source === target || target === allGroupsLabel) return currentOrder;
  const labels = orderGroupLabels(
    filters.filter((group) => group.value !== allGroupsValue).map((group) => group.label),
    currentOrder,
  ).filter((label) => label !== source);
  const targetIndex = labels.indexOf(target);
  labels.splice(targetIndex >= 0 ? targetIndex : labels.length, 0, source);
  return labels;
}

function moveGroupLabel(
  currentOrder: string[],
  filters: GroupFilter[],
  source: string,
  direction: -1 | 1,
): string[] {
  if (!source || source === allGroupsLabel) return currentOrder;
  const labels = orderGroupLabels(
    filters.filter((group) => group.value !== allGroupsValue).map((group) => group.label),
    currentOrder,
  );
  const sourceIndex = labels.indexOf(source);
  const targetIndex = sourceIndex + direction;
  if (sourceIndex < 0 || targetIndex < 0 || targetIndex >= labels.length) return currentOrder;
  const next = [...labels];
  const [moved] = next.splice(sourceIndex, 1);
  next.splice(targetIndex, 0, moved);
  return next;
}

function toggleStringInArray(values: string[], value: string): string[] {
  return values.includes(value) ? values.filter((item) => item !== value) : [...values, value];
}

function readStoredStringArray(key: string): string[] {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
  } catch {
    return [];
  }
}

function writeStoredStringArray(key: string, values: string[]) {
  try {
    window.localStorage.setItem(key, JSON.stringify(values));
  } catch {
    // Ignore storage failures; grouping still works for the current session.
  }
}

function accountGroupLabel(account: Account) {
  return account.group?.trim() || ungroupedLabel;
}

function shouldUseMockTauri() {
  return import.meta.env.DEV && !("__TAURI_INTERNALS__" in window);
}

async function mockInvoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  await new Promise((resolve) => window.setTimeout(resolve, 80));
  const accounts = mockAccounts();
  if (command === "list_accounts") return accounts.filter((account) => !account.archived && !account.trashed) as T;
  if (command === "list_trashed_accounts") return accounts.filter((account) => account.trashed || account.archived) as T;
  if (command === "launch_dry_run" || command === "launch_preflight") {
    const name = String(args?.name ?? accounts[0].name);
    const account = accounts.find((item) => item.name === name) ?? accounts[0];
    return mockLaunchPlan(account, command === "launch_preflight") as T;
  }
  if (command === "create_account") {
    return { ...accounts[0], name: String(args?.name ?? "new"), created_at: Date.now() * 1000, archived: false, trashed: false, seed: "68122", group: null } as T;
  }
  if (command === "rename_account") return { ...accounts[0], name: String(args?.newName ?? "renamed") } as T;
  if (command === "restore_account") return { ...accounts[0], name: String(args?.name ?? accounts[0].name), archived: false, trashed: false } as T;
  if (command === "permanently_delete_account") return undefined as T;
  if (command === "set_group") {
    return { ...accounts[0], name: String(args?.name ?? accounts[0].name), group: (args?.value as string | null | undefined) ?? null } as T;
  }
  if (command === "set_proxy" || command === "set_region" || command === "toggle_locale") return accounts[0] as T;
  return undefined as T;
}

function mockAccounts(): Account[] {
  return [
    {
      name: "demo-alpha@example.test",
      profile_path: "/Users/example/Library/Application Support/ChatGPT Cloak/Accounts/demo-alpha@example.test",
      created_at: 1_700_000_001_000_000,
      archived: false,
      trashed: false,
      seed: "48366",
      group: "codex",
      region: null,
      locale_enabled: false,
      proxy_display: "关",
      has_proxy: false,
    },
    {
      name: "demo-beta",
      profile_path: "/Users/example/Library/Application Support/ChatGPT Cloak/Accounts/demo-beta",
      created_at: 1_700_000_002_000_000,
      archived: false,
      trashed: false,
      seed: "77296",
      group: "claude",
      region: "JP",
      locale_enabled: true,
      proxy_display: "关",
      has_proxy: false,
    },
    {
      name: "demo-gamma",
      profile_path: "/Users/example/Library/Application Support/ChatGPT Cloak/Accounts/demo-gamma",
      created_at: 1_700_000_003_000_000,
      archived: true,
      trashed: false,
      seed: "68098",
      group: "codex",
      region: "US",
      locale_enabled: false,
      proxy_display: "socks5://proxy.example.net:1080（经本机 SOCKS5 中继）",
      has_proxy: true,
    },
    {
      name: "old-lab",
      profile_path: "/Users/example/Library/Application Support/ChatGPT Cloak/Accounts/old-lab",
      created_at: 1_700_000_004_000_000,
      archived: false,
      trashed: true,
      seed: "51024",
      group: null,
      region: "NL",
      locale_enabled: false,
      proxy_display: "关",
      has_proxy: false,
    },
  ];
}

function mockLaunchPlan(account: Account, full: boolean): LaunchPlan {
  return {
    account: account.name,
    seed: account.seed,
    profile_path: account.profile_path,
    extension_runtime_path: `${account.profile_path}/.cloak-companion`,
    load_extension_paths: [
      `${account.profile_path}/.cloak-companion`,
      "/Users/example/Library/Application Support/ChatGPT Cloak/Default Extensions/Chromium Web Store 插件",
      "/Users/example/Library/Application Support/ChatGPT Cloak/Default Extensions/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    extra_extension_paths: [
      "/Users/example/Library/Application Support/ChatGPT Cloak/Default Extensions/Chromium Web Store 插件",
      "/Users/example/Library/Application Support/ChatGPT Cloak/Default Extensions/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    selftest_extension_paths: [
      "/Users/example/Library/Application Support/ChatGPT Cloak/Default Extensions/get-cookies.txt-locally_v0.7.2_chrome",
      `${account.profile_path}/.cloak-extra-extensions/Cookies.crx`,
    ],
    browser_binary: "/Users/example/.cloakbrowser/current/Chromium.app/Contents/MacOS/Chromium",
    proxy: {
      mode: account.has_proxy ? "relay" : "none",
      display: account.proxy_display,
      browser_arg: account.has_proxy ? "socks5://127.0.0.1:<relay-port>" : null,
      relay_needed: account.has_proxy,
      raw_url: null,
    },
    geo: full
      ? { exit_ip: "185.200.65.192", country: account.region, timezone: account.region === "JP" ? "Asia/Tokyo" : "America/Los_Angeles" }
      : { exit_ip: null, country: null, timezone: null },
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

function formatCreatedAt(createdAtMicros: number) {
  if (!Number.isFinite(createdAtMicros) || createdAtMicros <= 0) return "未知";
  return new Intl.DateTimeFormat(undefined, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(Math.floor(createdAtMicros / 1000)));
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
  const trashedPrefix = "account is in trash: ";
  const notTrashedPrefix = "account is not in trash: ";
  if (raw.startsWith(alreadyExistsPrefix)) {
    return `账号已存在：${raw.slice(alreadyExistsPrefix.length)}`;
  }
  if (raw.startsWith(doesNotExistPrefix)) {
    return `账号不存在：${raw.slice(doesNotExistPrefix.length)}`;
  }
  if (raw.startsWith(runningPrefix)) {
    return `账号正在运行：${raw.slice(runningPrefix.length)}。请先关闭这个浏览器窗口，再删除、恢复或彻底删除。`;
  }
  if (raw.startsWith(trashedPrefix)) {
    return `账号已在回收站：${raw.slice(trashedPrefix.length)}。请先恢复再启动。`;
  }
  if (raw.startsWith(notTrashedPrefix)) {
    return `账号不在回收站：${raw.slice(notTrashedPrefix.length)}。请先删除到回收站，再彻底删除。`;
  }
  if (raw.includes("account name is invalid")) {
    return "名字无效：可用字母、数字、.、@、+、-、_；不能叫 main，不能以 . 开头/结尾，不能含 /、\\ 或连续 ..。";
  }
  if (raw.includes("unsupported proxy URL")) {
    return "代理须以 socks5://、http:// 或 https:// 开头。";
  }
  return raw;
}
