use tauri::{
    menu::{Menu, MenuBuilder, MenuItemBuilder, PredefinedMenuItem, Submenu, SubmenuBuilder},
    AppHandle, Wry,
};

use crate::fingerprint;
use crate::profile::ProfileStore;

/// Menu event identifiers — emitted as menu item IDs.
pub mod event_id {
    pub const IMPORT_COOKIES: &str = "menu:import-cookies";
    pub const EXPORT_COOKIES: &str = "menu:export-cookies";
    pub const BURN_CURRENT_PROFILE: &str = "menu:burn-current-profile";
    pub const GO_TO_URL: &str = "menu:go-to-url";
    pub const NEW_INCOGNITO: &str = "menu:new-incognito";
    pub const SWITCH_PROFILE_PREFIX: &str = "menu:switch-profile:";
    pub const FP_PRESET_PREFIX: &str = "menu:fp-preset:";
    pub const FP_RANDOMIZE: &str = "menu:fp-randomize";
    pub const FP_ABOUT: &str = "menu:fp-about";
    pub const TOGGLE_ENHANCED_PRIVACY: &str = "menu:toggle-enhanced-privacy";
    pub const OPEN_FINGERPRINT_TEST: &str = "menu:open-fingerprint-test";
    pub const SET_HOMEPAGE: &str = "menu:set-homepage";
    pub const RESET_HOMEPAGE: &str = "menu:reset-homepage";
    pub const ADD_PROFILE: &str = "menu:add-profile";
    pub const CLONE_PROFILE: &str = "menu:clone-profile";
    pub const EXPORT_PROFILE: &str = "menu:export-profile";
    pub const IMPORT_PROFILE: &str = "menu:import-profile";
    pub const RENAME_PROFILE: &str = "menu:rename-profile";
    pub const DELETE_PROFILE: &str = "menu:delete-profile";
    pub const TOGGLE_WEBRTC: &str = "menu:toggle-webrtc";
    pub const PRIVACY_STATUS: &str = "menu:privacy-status";
    pub const NAV_BACK: &str = "menu:nav-back";
    pub const NAV_FORWARD: &str = "menu:nav-forward";
    pub const NAV_HOME: &str = "menu:nav-home";
    pub const NAV_RELOAD: &str = "menu:nav-reload";
    pub const ZOOM_IN: &str = "menu:zoom-in";
    pub const ZOOM_OUT: &str = "menu:zoom-out";
    pub const ZOOM_RESET: &str = "menu:zoom-reset";
}

/// Build the full application menu.
pub fn build_app_menu(app: &AppHandle<Wry>, profile_store: &ProfileStore) -> Menu<Wry> {
    // --- File menu ---
    let import_cookies = MenuItemBuilder::with_id(event_id::IMPORT_COOKIES, "导入 Cookies...")
        .build(app)
        .unwrap();
    let export_cookies = MenuItemBuilder::with_id(event_id::EXPORT_COOKIES, "导出 Cookies...")
        .build(app)
        .unwrap();
    let burn = MenuItemBuilder::with_id(event_id::BURN_CURRENT_PROFILE, "焚烧当前空间...")
        .build(app)
        .unwrap();
    let go_to_url = MenuItemBuilder::with_id(event_id::GO_TO_URL, "前往网址...")
        .accelerator("CmdOrCtrl+L")
        .build(app)
        .unwrap();
    let new_incognito = MenuItemBuilder::with_id(event_id::NEW_INCOGNITO, "新建无痕窗口")
        .accelerator("CmdOrCtrl+Shift+N")
        .build(app)
        .unwrap();

    let profiles_submenu = build_profiles_submenu(app, profile_store);

    let file_menu = SubmenuBuilder::with_id(app, "file-menu", "文件")
        .item(&import_cookies)
        .item(&export_cookies)
        .item(&burn)
        .separator()
        .item(&go_to_url)
        .separator()
        .item(&profiles_submenu)
        .item(&new_incognito)
        .separator()
        .item(&PredefinedMenuItem::close_window(app, Some("关闭窗口")).unwrap())
        .build()
        .unwrap();

    // --- View menu ---
    let back = MenuItemBuilder::with_id(event_id::NAV_BACK, "后退")
        .accelerator("CmdOrCtrl+[")
        .build(app)
        .unwrap();
    let forward = MenuItemBuilder::with_id(event_id::NAV_FORWARD, "前进")
        .accelerator("CmdOrCtrl+]")
        .build(app)
        .unwrap();
    let home = MenuItemBuilder::with_id(event_id::NAV_HOME, "回到首页")
        .accelerator("CmdOrCtrl+Shift+H")
        .build(app)
        .unwrap();
    let reload = MenuItemBuilder::with_id(event_id::NAV_RELOAD, "重新加载")
        .accelerator("CmdOrCtrl+R")
        .build(app)
        .unwrap();
    let zoom_in = MenuItemBuilder::with_id(event_id::ZOOM_IN, "放大")
        .accelerator("CmdOrCtrl+=")
        .build(app)
        .unwrap();
    let zoom_out = MenuItemBuilder::with_id(event_id::ZOOM_OUT, "缩小")
        .accelerator("CmdOrCtrl+-")
        .build(app)
        .unwrap();
    let zoom_reset = MenuItemBuilder::with_id(event_id::ZOOM_RESET, "实际大小")
        .accelerator("CmdOrCtrl+0")
        .build(app)
        .unwrap();

    let view_menu = SubmenuBuilder::with_id(app, "view-menu", "视图")
        .item(&back)
        .item(&forward)
        .item(&home)
        .separator()
        .item(&reload)
        .separator()
        .item(&zoom_in)
        .item(&zoom_out)
        .item(&zoom_reset)
        .build()
        .unwrap();

    // --- Privacy menu ---
    let webrtc = MenuItemBuilder::with_id(event_id::TOGGLE_WEBRTC, "启用 WebRTC 防护")
        .build(app)
        .unwrap();
    let privacy_status = MenuItemBuilder::with_id(event_id::PRIVACY_STATUS, "隐私状态...")
        .build(app)
        .unwrap();
    let fp_test = MenuItemBuilder::with_id(event_id::OPEN_FINGERPRINT_TEST, "打开指纹检测页")
        .build(app)
        .unwrap();

    let privacy_menu = SubmenuBuilder::with_id(app, "privacy-menu", "隐私")
        .item(&webrtc)
        .separator()
        .item(&privacy_status)
        .item(&fp_test)
        .build()
        .unwrap();

    // --- Assemble ---
    MenuBuilder::new(app)
        .item(&file_menu)
        .item(&view_menu)
        .item(&privacy_menu)
        .build()
        .unwrap()
}

/// Build the "账号空间" submenu nested inside File.
fn build_profiles_submenu(
    app: &AppHandle<Wry>,
    profile_store: &ProfileStore,
) -> Submenu<Wry> {
    let profiles = profile_store.list_profiles();
    let current_id = profile_store.current_profile_id();
    let current_meta = profile_store.get_meta(&current_id);

    let mut builder = SubmenuBuilder::with_id(app, "profiles-submenu", "账号空间");

    for profile in &profiles {
        let id = format!("{}{}", event_id::SWITCH_PROFILE_PREFIX, profile.id);
        let title = if profile.id == current_id {
            format!("● {}", profile.name)
        } else {
            format!("  {}", profile.name)
        };
        let item = MenuItemBuilder::with_id(id, title).build(app).unwrap();
        builder = builder.item(&item);
    }

    builder = builder.separator();

    // Fingerprint presets submenu
    let fp_submenu = build_fingerprint_submenu(app, profile_store);
    builder = builder.item(&fp_submenu);

    // Enhanced privacy toggle
    let ep_title = if current_meta.enhanced_privacy {
        "● 增强隐私模式（当前空间）"
    } else {
        "  增强隐私模式（当前空间）"
    };
    let ep_item = MenuItemBuilder::with_id(event_id::TOGGLE_ENHANCED_PRIVACY, ep_title)
        .build(app)
        .unwrap();
    builder = builder.item(&ep_item);

    let fp_test = MenuItemBuilder::with_id(event_id::OPEN_FINGERPRINT_TEST, "打开指纹检测页")
        .build(app)
        .unwrap();
    builder = builder.item(&fp_test);

    builder = builder.separator();

    let set_home = MenuItemBuilder::with_id(event_id::SET_HOMEPAGE, "设置当前空间首页…")
        .build(app)
        .unwrap();
    builder = builder.item(&set_home);
    let reset_home = MenuItemBuilder::with_id(event_id::RESET_HOMEPAGE, "恢复默认首页并打开")
        .build(app)
        .unwrap();
    builder = builder.item(&reset_home);

    builder = builder.separator();

    let add = MenuItemBuilder::with_id(event_id::ADD_PROFILE, "新建账号空间…")
        .build(app)
        .unwrap();
    let clone = MenuItemBuilder::with_id(event_id::CLONE_PROFILE, "克隆当前空间…")
        .build(app)
        .unwrap();
    let export = MenuItemBuilder::with_id(event_id::EXPORT_PROFILE, "导出当前空间配置…")
        .build(app)
        .unwrap();
    let import = MenuItemBuilder::with_id(event_id::IMPORT_PROFILE, "导入空间配置…")
        .build(app)
        .unwrap();
    let is_default = current_id == crate::profile::DEFAULT_PROFILE_ID;

    let rename = MenuItemBuilder::with_id(event_id::RENAME_PROFILE, "重命名当前空间…")
        .enabled(!is_default)
        .build(app)
        .unwrap();
    let delete = MenuItemBuilder::with_id(event_id::DELETE_PROFILE, "删除当前空间…")
        .enabled(!is_default)
        .build(app)
        .unwrap();

    builder = builder
        .item(&add)
        .item(&clone)
        .item(&export)
        .item(&import)
        .item(&rename)
        .item(&delete);

    builder.build().unwrap()
}

/// Build the fingerprint presets submenu.
fn build_fingerprint_submenu(
    app: &AppHandle<Wry>,
    profile_store: &ProfileStore,
) -> Submenu<Wry> {
    let current_id = profile_store.current_profile_id();
    let meta = profile_store.get_meta(&current_id);
    let current_preset_id = meta
        .fingerprint
        .as_ref()
        .map(|f| f.preset_id.as_str())
        .unwrap_or(fingerprint::OFF_PRESET_ID);
    let is_off = meta.fingerprint.is_none() || meta.fingerprint_disabled;

    let mut builder = SubmenuBuilder::with_id(app, "fp-submenu", "指纹预设");

    // Off option
    let off_title = if is_off {
        "● 默认（不混淆）"
    } else {
        "  默认（不混淆）"
    };
    let off_item = MenuItemBuilder::with_id(
        format!("{}{}", event_id::FP_PRESET_PREFIX, fingerprint::OFF_PRESET_ID),
        off_title,
    )
    .build(app)
    .unwrap();
    builder = builder.item(&off_item);

    // Platform presets
    for preset in fingerprint::platform_presets() {
        let selected = current_preset_id == preset.preset_id;
        let title = if selected {
            format!("● {}", preset.display_name)
        } else {
            format!("  {}", preset.display_name)
        };
        let item = MenuItemBuilder::with_id(
            format!("{}{}", event_id::FP_PRESET_PREFIX, preset.preset_id),
            title,
        )
        .build(app)
        .unwrap();
        builder = builder.item(&item);
    }

    // Show current random fingerprint if applicable
    if let Some(ref fp) = meta.fingerprint {
        if fp.preset_id.starts_with("random-") {
            builder = builder.separator();
            let item = MenuItemBuilder::with_id(
                "fp-current-random",
                format!("● {}", fp.display_name),
            )
            .enabled(false)
            .build(app)
            .unwrap();
            builder = builder.item(&item);
        }
    }

    builder = builder.separator();
    let randomize = MenuItemBuilder::with_id(event_id::FP_RANDOMIZE, "重新随机化（当前空间）")
        .build(app)
        .unwrap();
    builder = builder.item(&randomize);
    builder = builder.separator();
    let about = MenuItemBuilder::with_id(event_id::FP_ABOUT, "关于指纹混淆…")
        .build(app)
        .unwrap();
    builder = builder.item(&about);

    builder.build().unwrap()
}

/// Helper to extract profile ID from a switch-profile menu event ID.
pub fn extract_profile_id(event_id: &str) -> Option<&str> {
    event_id.strip_prefix(event_id::SWITCH_PROFILE_PREFIX)
}

/// Helper to extract preset ID from a fingerprint preset menu event ID.
pub fn extract_preset_id(event_id: &str) -> Option<&str> {
    event_id.strip_prefix(event_id::FP_PRESET_PREFIX)
}
