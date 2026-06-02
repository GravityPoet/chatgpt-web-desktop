use std::{
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    thread,
    time::Duration,
};

use tauri::{
    webview::{NewWindowFeatures, NewWindowResponse},
    AppHandle, Manager, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder, Wry,
};

use crate::{
    fingerprint, menu, privacy,
    profile::{ProfileStore, DEFAULT_PROFILE_ID},
    CHATGPT_WEBVIEW_SCRIPT,
};

pub const MAIN_WINDOW_LABEL: &str = "main";
const REBUILD_KEEPER_WINDOW_LABEL: &str = "__profile-rebuild-keeper";
const MAIN_REBUILD_RETRY_DELAY_MS: u64 = 120;
const MAIN_REBUILD_MAX_ATTEMPTS: u8 = 10;
const DEFAULT_MACOS_SAFARI_USER_AGENT: &str =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15";

/// State held in Tauri's managed state for browser operations.
pub struct BrowserState {
    pub popup_counter: AtomicUsize,
    pub main_rebuild_in_progress: AtomicBool,
}

impl BrowserState {
    pub fn new() -> Self {
        Self {
            popup_counter: AtomicUsize::new(0),
            main_rebuild_in_progress: AtomicBool::new(false),
        }
    }
}

/// Convert a profile ID (UUID string) to `[u8; 16]` for `data_store_identifier`.
/// Returns `None` for non-UUID IDs (e.g. "default").
pub fn profile_id_to_uuid_bytes(profile_id: &str) -> Option<[u8; 16]> {
    uuid::Uuid::parse_str(profile_id)
        .ok()
        .map(|u| *u.as_bytes())
}

/// Apply macOS profile isolation using `data_store_identifier`.
/// On macOS, WKWebView uses `WKWebsiteDataStore(forIdentifier:)` for isolation.
/// On other platforms, this is a no-op (they use `data_directory` instead).
#[cfg(target_os = "macos")]
fn apply_macos_isolation<'a, M: Manager<Wry>>(
    builder: WebviewWindowBuilder<'a, Wry, M>,
    profile_id: &str,
) -> WebviewWindowBuilder<'a, Wry, M> {
    if profile_id == DEFAULT_PROFILE_ID {
        return builder;
    }
    if let Some(uuid_bytes) = profile_id_to_uuid_bytes(profile_id) {
        builder.data_store_identifier(uuid_bytes)
    } else {
        builder
    }
}

/// Apply Windows/Linux profile isolation using `data_directory`.
#[cfg(not(target_os = "macos"))]
fn apply_platform_isolation<'a, M: Manager<Wry>>(
    builder: WebviewWindowBuilder<'a, Wry, M>,
    profile_store: &ProfileStore,
    profile_id: &str,
) -> WebviewWindowBuilder<'a, Wry, M> {
    if profile_id == DEFAULT_PROFILE_ID {
        return builder;
    }
    let data_dir = profile_store.webview_data_dir(profile_id);
    builder.data_directory(data_dir)
}

/// Build the initial main window for the current profile.
pub fn build_main_window(
    app: &AppHandle<Wry>,
    profile_store: &ProfileStore,
) -> Result<WebviewWindow<Wry>, String> {
    let profile = profile_store.current_profile();
    let homepage = profile_store.homepage_url(&profile.id);

    let window_config = app
        .config()
        .app
        .windows
        .iter()
        .find(|w| w.label == MAIN_WINDOW_LABEL)
        .cloned()
        .ok_or_else(|| "missing main window configuration".to_string())?;

    let title = main_window_title(&profile.name, &profile.id);
    let user_agent = profile_user_agent(&profile_store, &profile.id);
    let init_scripts = build_init_scripts(&profile_store, &profile.id);

    let app_for_nav = app.clone();
    let app_for_popup = app.clone();
    let app_for_download = app.clone();

    let builder = WebviewWindowBuilder::from_config(app, &window_config)
        .map_err(|e| format!("failed to create window from config: {e}"))?
        .title(&title)
        .user_agent(&user_agent)
        .on_navigation(move |url| crate::handle_navigation(&app_for_nav, url))
        .on_new_window(move |url, features| {
            handle_new_window(&app_for_popup, url, features)
        })
        .on_download(move |_webview, event| {
            crate::handle_download_event(&app_for_download, event)
        });

    // Apply platform-specific profile isolation
    #[cfg(target_os = "macos")]
    let builder = apply_macos_isolation(builder, &profile.id);
    #[cfg(not(target_os = "macos"))]
    let builder = apply_platform_isolation(builder, profile_store, &profile.id);

    // Add initialization scripts
    let mut builder = builder;
    for script in &init_scripts {
        builder = builder.initialization_script(script);
    }

    let webview = builder
        .build()
        .map_err(|e| format!("failed to build main webview: {e}"))?;
    if let Err(error) = crate::apply_pending_cookies(app, &webview) {
        eprintln!("failed to apply pending cookies: {error}");
    }
    let _ = crate::prune_oversized_chatgpt_cookies(&webview);

    // Load the homepage
    if let Ok(url) = Url::parse(&homepage) {
        webview
            .navigate(url)
            .map_err(|e| format!("failed to navigate to homepage: {e}"))?;
    }

    Ok(webview)
}

/// Rebuild the main window for a new profile.
pub fn rebuild_main_window(
    app: &AppHandle<Wry>,
    _profile_store: &ProfileStore,
    initial_url: Option<String>,
) -> Result<(), String> {
    let _ = build_rebuild_keeper_window(app);
    let browser_state = app.state::<BrowserState>();
    if browser_state
        .main_rebuild_in_progress
        .swap(true, Ordering::SeqCst)
    {
        return Ok(());
    }

    close_auth_popups(app);

    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        window
            .destroy()
            .map_err(|e| format!("failed to destroy main window: {e}"))?;
    }

    schedule_main_window_rebuild(app.clone(), initial_url, MAIN_REBUILD_MAX_ATTEMPTS);
    Ok(())
}

fn build_rebuild_keeper_window(app: &AppHandle<Wry>) -> Option<WebviewWindow<Wry>> {
    if app.get_webview_window(REBUILD_KEEPER_WINDOW_LABEL).is_some() {
        return None;
    }
    WebviewWindowBuilder::new(
        app,
        REBUILD_KEEPER_WINDOW_LABEL,
        WebviewUrl::External("about:blank".parse().ok()?),
    )
    .title("ChatGPT Rust")
    .visible(false)
    .focused(false)
    .decorations(false)
    .skip_taskbar(true)
    .position(-10000.0, -10000.0)
    .inner_size(1.0, 1.0)
    .build()
    .ok()
}

fn destroy_rebuild_keeper_window(app: &AppHandle<Wry>) {
    if let Some(window) = app.get_webview_window(REBUILD_KEEPER_WINDOW_LABEL) {
        let _ = window.destroy();
    }
}

fn schedule_main_window_rebuild(
    app: AppHandle<Wry>,
    initial_url: Option<String>,
    attempts_left: u8,
) {
    tauri::async_runtime::spawn_blocking(move || {
        thread::sleep(Duration::from_millis(MAIN_REBUILD_RETRY_DELAY_MS));
        let app_for_main = app.clone();
        let result = app.run_on_main_thread(move || {
            if app_for_main.get_webview_window(MAIN_WINDOW_LABEL).is_some() {
                if attempts_left > 0 {
                    schedule_main_window_rebuild(app_for_main, initial_url, attempts_left - 1);
                } else {
                    finish_failed_main_rebuild(&app_for_main, "旧主窗口仍未释放，已保留当前窗口。");
                }
                return;
            }

            let result = finish_main_window_rebuild(&app_for_main, initial_url);
            let browser_state = app_for_main.state::<BrowserState>();
            browser_state
                .main_rebuild_in_progress
                .store(false, Ordering::SeqCst);
            if let Err(error) = result {
                finish_failed_main_rebuild(
                    &app_for_main,
                    &format!("新主窗口创建失败，已停止本次重建：{error}"),
                );
            }
        });

        if result.is_err() {
            let browser_state = app.state::<BrowserState>();
            browser_state
                .main_rebuild_in_progress
                .store(false, Ordering::SeqCst);
        }
    });
}

fn finish_failed_main_rebuild(app: &AppHandle<Wry>, message: &str) {
    let browser_state = app.state::<BrowserState>();
    browser_state
        .main_rebuild_in_progress
        .store(false, Ordering::SeqCst);
    eprintln!("failed to rebuild main window: {message}");
    crate::show_menu_error(message);
    destroy_rebuild_keeper_window(app);
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

fn finish_main_window_rebuild(
    app: &AppHandle<Wry>,
    initial_url: Option<String>,
) -> Result<(), String> {
    if app.get_webview_window(MAIN_WINDOW_LABEL).is_some() {
        return Err("main webview label is still in use".to_string());
    }

    let profile_store = app.state::<ProfileStore>();
    let profile = profile_store.current_profile();
    let homepage = initial_url.unwrap_or_else(|| profile_store.homepage_url(&profile.id));

    let window_config = app
        .config()
        .app
        .windows
        .iter()
        .find(|w| w.label == MAIN_WINDOW_LABEL)
        .cloned()
        .ok_or_else(|| "missing main window configuration".to_string())?;

    let title = main_window_title(&profile.name, &profile.id);
    let user_agent = profile_user_agent(&profile_store, &profile.id);
    let init_scripts = build_init_scripts(&profile_store, &profile.id);

    let app_for_nav = app.clone();
    let app_for_popup = app.clone();
    let app_for_download = app.clone();

    let builder = WebviewWindowBuilder::from_config(app, &window_config)
        .map_err(|e| format!("failed to create window from config: {e}"))?
        .title(&title)
        .user_agent(&user_agent)
        .on_navigation(move |url| crate::handle_navigation(&app_for_nav, url))
        .on_new_window(move |url, features| {
            handle_new_window(&app_for_popup, url, features)
        })
        .on_download(move |_webview, event| {
            crate::handle_download_event(&app_for_download, event)
        });

    // Apply platform-specific profile isolation
    #[cfg(target_os = "macos")]
    let builder = apply_macos_isolation(builder, &profile.id);
    #[cfg(not(target_os = "macos"))]
    let builder = apply_platform_isolation(builder, profile_store, &profile.id);

    let mut builder = builder;
    for script in &init_scripts {
        builder = builder.initialization_script(script);
    }

    let webview = builder
        .build()
        .map_err(|e| format!("failed to rebuild main webview: {e}"))?;
    if let Err(error) = crate::apply_pending_cookies(app, &webview) {
        eprintln!("failed to apply pending cookies: {error}");
    }
    let _ = crate::prune_oversized_chatgpt_cookies(&webview);

    if let Ok(url) = Url::parse(&homepage) {
        let _ = webview.navigate(url);
    }

    // Rebuild menu
    let new_menu = menu::build_app_menu(app, &profile_store);
    app.set_menu(new_menu)
        .map_err(|e| format!("failed to set menu: {e}"))?;

    destroy_rebuild_keeper_window(app);

    Ok(())
}

/// Close all auth popup windows (using destroy to bypass close handler).
pub fn close_auth_popups(app: &AppHandle<Wry>) {
    for (label, window) in app.webview_windows() {
        if label.starts_with("auth-") {
            let _ = window.destroy();
        }
    }
}

/// Build initialization scripts for a profile.
pub fn build_init_scripts(profile_store: &ProfileStore, profile_id: &str) -> Vec<String> {
    let meta = profile_store.get_meta(profile_id);
    let fingerprint_enabled = meta.fingerprint.is_some() && !meta.fingerprint_disabled;
    let privacy_mutation_enabled =
        fingerprint_enabled || meta.enhanced_privacy || meta.webrtc_enabled;

    let mut scripts: Vec<String> = vec![CHATGPT_WEBVIEW_SCRIPT.to_string()];
    if privacy_mutation_enabled {
        scripts.push(privacy::NATIVE_SHIM_SCRIPT.to_string());
    }

    // Fingerprint override
    if fingerprint_enabled {
        if let Some(ref fp) = meta.fingerprint {
            scripts.push(fingerprint::fingerprint_script(fp));
        }
    }

    // Enhanced privacy (Canvas/WebGL/Audio noise, GPC, etc.)
    if meta.enhanced_privacy {
        scripts.push(privacy::PRIVACY_SIGNALS_SCRIPT.to_string());
        scripts.push(fingerprint::enhanced_privacy_script(
            profile_id,
            meta.fingerprint.as_ref(),
        ));
    }

    // WebRTC blocker — only inject if the profile has it enabled
    if meta.webrtc_enabled {
        scripts.push(privacy::WEBRTC_BLOCKER_SCRIPT.to_string());
    }

    scripts
}

/// Native HTTP user agent for the WebView.
/// Keep the default close to Safari/WKWebView so Cloudflare sees a coherent browser surface.
pub(crate) fn profile_user_agent(profile_store: &ProfileStore, profile_id: &str) -> String {
    let meta = profile_store.get_meta(profile_id);
    if !meta.fingerprint_disabled {
        if let Some(fingerprint) = meta.fingerprint {
            return fingerprint.user_agent;
        }
    }
    DEFAULT_MACOS_SAFARI_USER_AGENT.to_string()
}

/// Handle new window requests (auth popups).
/// Auth popups share the current profile's data store.
fn handle_new_window(
    app: &AppHandle<Wry>,
    target_url: Url,
    features: NewWindowFeatures,
) -> NewWindowResponse<Wry> {
    if !crate::should_stay_inside_app(&target_url) {
        if crate::should_open_in_app_root(&target_url) {
            if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = window.navigate(target_url);
            }
        } else {
            crate::open_external_url(&target_url);
        }
        return NewWindowResponse::Deny;
    }

    let browser_state = app.state::<BrowserState>();
    let label = format!(
        "auth-{}",
        browser_state
            .popup_counter
            .fetch_add(1, Ordering::Relaxed)
            + 1
    );
    let title = target_url
        .host_str()
        .map_or_else(|| "ChatGPT Login".to_string(), ToString::to_string);

    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();
    let user_agent = profile_user_agent(&profile_store, &current_id);

    let app_for_nav = app.clone();
    let app_for_download = app.clone();

    let builder = WebviewWindowBuilder::new(
        app,
        label,
        WebviewUrl::External("about:blank".parse().expect("about:blank is valid")),
    )
    .title(title)
    .inner_size(1200.0, 800.0)
    .min_inner_size(720.0, 480.0)
    .resizable(true)
    .center()
    .focused(true)
    .user_agent(&user_agent)
    .window_features(features)
    .on_navigation(move |url| crate::handle_navigation(&app_for_nav, url))
    .on_download(move |_webview, event| {
        crate::handle_download_event(&app_for_download, event)
    });

    // Apply the same profile isolation to auth popups
    #[cfg(target_os = "macos")]
    let builder = apply_macos_isolation(builder, &current_id);
    #[cfg(not(target_os = "macos"))]
    let builder = apply_platform_isolation(builder, &profile_store, &current_id);

    match builder.build() {
        Ok(window) => NewWindowResponse::Create { window },
        Err(error) => {
            eprintln!("failed to create managed auth window: {error}");
            NewWindowResponse::Deny
        }
    }
}

/// Get the main window title based on profile name.
pub fn main_window_title(profile_name: &str, profile_id: &str) -> String {
    if profile_id == DEFAULT_PROFILE_ID && profile_name == "默认" {
        "ChatGPT Rust".to_string()
    } else {
        format!("ChatGPT Rust · {profile_name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::ProfileMeta;

    #[test]
    fn default_profile_uses_minimal_init_scripts() {
        let temp = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(temp.path()).unwrap();

        let scripts = build_init_scripts(&store, DEFAULT_PROFILE_ID);

        assert_eq!(scripts.len(), 1);
        assert!(scripts[0].contains("looksLikeCloudflareChallenge"));
        assert!(scripts[0].contains("installNativeZoomShortcuts"));
        assert!(!scripts[0].contains("__wkNativeShim"));
        assert!(!scripts[0].contains("__wkEnhancedPrivacy"));
    }

    #[test]
    fn default_profile_uses_safari_user_agent() {
        let temp = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(temp.path()).unwrap();

        let user_agent = profile_user_agent(&store, DEFAULT_PROFILE_ID);

        assert!(user_agent.contains("Version/26.5 Safari/605.1.15"));
        assert!(!user_agent.to_ascii_lowercase().contains("tauri"));
        assert!(!user_agent.to_ascii_lowercase().contains("wry"));
    }

    #[test]
    fn enhanced_privacy_opts_into_privacy_mutation_scripts() {
        let temp = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(temp.path()).unwrap();
        let meta = ProfileMeta {
            enhanced_privacy: true,
            ..Default::default()
        };
        store.set_meta(DEFAULT_PROFILE_ID, &meta).unwrap();

        let scripts = build_init_scripts(&store, DEFAULT_PROFILE_ID);
        let combined = scripts.join("\n");

        assert!(combined.contains("__wkNativeShim"));
        assert!(combined.contains("__wkPrivacySignals"));
        assert!(combined.contains("__wkEnhancedPrivacy"));
    }
}
