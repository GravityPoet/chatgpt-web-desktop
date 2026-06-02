mod browser;
mod cookies;
mod fingerprint;
mod menu;
mod privacy;
mod profile;

use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{atomic::Ordering, Mutex},
};

use tauri::{
    webview::DownloadEvent,
    AppHandle, Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
    WindowEvent, Wry,
};
use tauri_plugin_window_state::{Builder as WindowStateBuilder, StateFlags};
use browser::{BrowserState, MAIN_WINDOW_LABEL};
use profile::{ProfileExportDocument, ProfileStore};

const MAX_BLOB_DOWNLOAD_BYTES: usize = 200 * 1024 * 1024;
const CHATGPT_WEBVIEW_SCRIPT: &str = include_str!("chatgpt_webview.js");
const MAX_CHATGPT_COOKIE_HEADER_BYTES: usize = 6 * 1024;
const MIN_WEBVIEW_ZOOM: f64 = 0.85;
const MAX_WEBVIEW_ZOOM: f64 = 1.40;
const WEBVIEW_ZOOM_STORAGE_KEY: &str = "chatgptWebviewZoom";

// --- Download session management ---

#[derive(Default)]
struct BlobDownloadSessions(Mutex<HashMap<String, BlobDownloadSession>>);

struct BlobDownloadSession {
    path: PathBuf,
    expected_size: usize,
    bytes_written: usize,
}

/// In-memory storage for cookies pending injection during profile clone.
/// Avoids writing session cookies to disk.
#[derive(Default)]
struct PendingCookies(Mutex<Option<Vec<serde_json::Value>>>);

#[derive(Default)]
struct NativeZoomState(Mutex<f64>);

#[tauri::command]
fn start_blob_download(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    sessions: tauri::State<'_, BlobDownloadSessions>,
    filename: String,
    expected_size: usize,
) -> Result<String, String> {
    ensure_trusted_command_window(&window)?;
    validate_blob_download_size(expected_size)?;

    let downloads_dir = download_dir(&app)?;
    fs::create_dir_all(&downloads_dir)
        .map_err(|error| format!("failed to create Downloads directory: {error}"))?;

    let output_path = unique_download_path(&downloads_dir, &sanitize_filename(&filename));
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&output_path)
        .map_err(|error| format!("failed to create download file: {error}"))?;

    let session_id = uuid::Uuid::new_v4().to_string();
    let mut sessions = sessions
        .0
        .lock()
        .map_err(|_| "download session lock is poisoned".to_string())?;
    sessions.insert(
        session_id.clone(),
        BlobDownloadSession {
            path: output_path,
            expected_size,
            bytes_written: 0,
        },
    );

    Ok(session_id)
}

#[tauri::command]
fn append_blob_download(
    window: WebviewWindow<Wry>,
    sessions: tauri::State<'_, BlobDownloadSessions>,
    session_id: String,
    bytes: Vec<u8>,
) -> Result<usize, String> {
    ensure_trusted_command_window(&window)?;
    if bytes.is_empty() {
        return Err("download chunk is empty".to_string());
    }

    let mut sessions = sessions
        .0
        .lock()
        .map_err(|_| "download session lock is poisoned".to_string())?;
    let session = sessions
        .get_mut(&session_id)
        .ok_or_else(|| "download session does not exist".to_string())?;
    let next_size = session
        .bytes_written
        .checked_add(bytes.len())
        .ok_or_else(|| "download payload is too large".to_string())?;
    if next_size > session.expected_size || next_size > MAX_BLOB_DOWNLOAD_BYTES {
        return Err("download payload is too large".to_string());
    }

    OpenOptions::new()
        .append(true)
        .open(&session.path)
        .and_then(|mut file| file.write_all(&bytes))
        .map_err(|error| format!("failed to write download chunk: {error}"))?;
    session.bytes_written = next_size;

    Ok(session.bytes_written)
}

#[tauri::command]
fn finish_blob_download(
    window: WebviewWindow<Wry>,
    sessions: tauri::State<'_, BlobDownloadSessions>,
    session_id: String,
) -> Result<String, String> {
    ensure_trusted_command_window(&window)?;
    let mut sessions = sessions
        .0
        .lock()
        .map_err(|_| "download session lock is poisoned".to_string())?;
    let session = sessions
        .remove(&session_id)
        .ok_or_else(|| "download session does not exist".to_string())?;
    if session.bytes_written != session.expected_size {
        let _ = fs::remove_file(&session.path);
        return Err("download ended before all bytes were written".to_string());
    }

    Ok(session.path.to_string_lossy().into_owned())
}

#[tauri::command]
fn cancel_blob_download(
    window: WebviewWindow<Wry>,
    sessions: tauri::State<'_, BlobDownloadSessions>,
    session_id: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    let mut sessions = sessions
        .0
        .lock()
        .map_err(|_| "download session lock is poisoned".to_string())?;
    if let Some(session) = sessions.remove(&session_id) {
        let _ = fs::remove_file(session.path);
    }
    Ok(())
}

#[tauri::command]
fn set_native_webview_zoom(window: WebviewWindow<Wry>, scale: f64) -> Result<f64, String> {
    ensure_trusted_command_window(&window)?;

    let clamped = clamp_webview_zoom(scale);
    window
        .set_zoom(clamped)
        .map_err(|error| format!("failed to set native webview zoom: {error}"))?;
    Ok(clamped)
}

fn applescript_string_literal(value: &str) -> String {
    let escaped: String = value
        .chars()
        .filter(|char| !matches!(char, '\0' | '\r'))
        .flat_map(|char| match char {
            '\\' => "\\\\".chars().collect::<Vec<_>>(),
            '"' => "\\\"".chars().collect::<Vec<_>>(),
            _ => vec![char],
        })
        .collect();
    format!("\"{}\"", escaped)
}

fn applescript_text_expr(value: &str) -> String {
    let parts: Vec<String> = value.split('\n').map(applescript_string_literal).collect();
    if parts.is_empty() {
        "\"\"".to_string()
    } else {
        parts.join(" & return & ")
    }
}

fn run_osascript(script: &str) -> Result<String, String> {
    let output = Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .map_err(|error| format!("failed to run osascript: {error}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout)
            .trim_end_matches(['\r', '\n'])
            .to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

fn native_alert(title: &str, message: &str) {
    let script = format!(
        "display dialog {} with title {} buttons {{\"知道了\"}} default button \"知道了\"",
        applescript_text_expr(message),
        applescript_text_expr(title)
    );
    let _ = run_osascript(&script);
}

fn native_confirm(title: &str, message: &str) -> bool {
    let script = format!(
        "button returned of (display dialog {} with title {} buttons {{\"取消\", \"确定\"}} default button \"确定\" cancel button \"取消\")",
        applescript_text_expr(message),
        applescript_text_expr(title)
    );
    run_osascript(&script)
        .map(|button| button.trim() == "确定")
        .unwrap_or(false)
}

fn native_prompt(title: &str, message: &str, default_answer: &str) -> Option<String> {
    let script = format!(
        "set dialogResult to display dialog {} default answer {} with title {} buttons {{\"取消\", \"确定\"}} default button \"确定\" cancel button \"取消\"\ntext returned of dialogResult",
        applescript_text_expr(message),
        applescript_text_expr(default_answer),
        applescript_text_expr(title)
    );
    run_osascript(&script).ok()
}

fn native_choose_file(prompt: &str) -> Option<PathBuf> {
    let script = format!(
        "POSIX path of (choose file with prompt {} without invisibles)",
        applescript_text_expr(prompt)
    );
    run_osascript(&script).ok().map(PathBuf::from)
}

pub(crate) fn show_menu_error(message: impl AsRef<str>) {
    native_alert("ChatGPT Rust", message.as_ref());
}

fn startup_error(message: impl Into<String>) -> Box<dyn std::error::Error> {
    let message = message.into();
    native_alert("ChatGPT Rust 启动失败", &message);
    io::Error::new(io::ErrorKind::Other, message).into()
}

fn current_main_window(app: &AppHandle<Wry>) -> Option<WebviewWindow<Wry>> {
    app.get_webview_window(MAIN_WINDOW_LABEL)
}

fn queue_pending_cookies(
    app: &AppHandle<Wry>,
    cookie_values: Vec<serde_json::Value>,
) -> Result<(), String> {
    let pending_state = app.state::<PendingCookies>();
    let mut pending = pending_state
        .0
        .lock()
        .map_err(|_| "pending cookie lock is poisoned".to_string())?;
    *pending = Some(cookie_values);
    Ok(())
}

fn clear_pending_cookies(app: &AppHandle<Wry>) {
    let pending_state = app.state::<PendingCookies>();
    let Ok(mut pending) = pending_state.0.lock() else {
        return;
    };
    *pending = None;
}

pub(crate) fn apply_pending_cookies(
    app: &AppHandle<Wry>,
    window: &WebviewWindow<Wry>,
) -> Result<usize, String> {
    let pending_state = app.state::<PendingCookies>();
    let cookie_values = pending_state
        .0
        .lock()
        .map_err(|_| "pending cookie lock is poisoned".to_string())?
        .take();
    let Some(cookie_values) = cookie_values else {
        return Ok(0);
    };

    let mut applied = 0;
    let mut failed_names = Vec::new();
    for cv in &cookie_values {
        let name = cv["name"].as_str().unwrap_or("");
        if name.is_empty() {
            continue;
        }
        let value = cv["value"].as_str().unwrap_or("");
        let domain = cv["domain"].as_str().unwrap_or("");
        let path = cv["path"].as_str().unwrap_or("/");
        let secure = cv["secure"].as_bool().unwrap_or(false);
        let http_only = cv["http_only"].as_bool().unwrap_or(false);
        let host_only = cv["host_only"].as_bool().unwrap_or(false);
        let mut cookie =
            build_webview_cookie(name, value, domain, path, secure, http_only, host_only);
        if let Some(expires) = cv["expires"].as_f64() {
            if expires > 0.0 {
                use tauri::webview::cookie::time;
                if let Ok(dt) = time::OffsetDateTime::from_unix_timestamp(expires as i64) {
                    cookie = cookie.expires(dt);
                }
            }
        }
        match window.set_cookie(cookie.build()) {
            Ok(()) => applied += 1,
            Err(_) => failed_names.push(name.to_string()),
        }
    }

    if failed_names.is_empty() {
        Ok(applied)
    } else {
        failed_names.sort();
        failed_names.dedup();
        Err(format!("failed to copy cookies: {}", failed_names.join(", ")))
    }
}

fn stop_main_window_loading(app: &AppHandle<Wry>) {
    if let Some(window) = current_main_window(app) {
        let _ = window.eval("try { window.stop(); } catch (_) {}");
    }
}

fn current_homepage(profile_store: &ProfileStore) -> String {
    let profile = profile_store.current_profile();
    profile_store.homepage_url(&profile.id)
}

fn current_reload_target(app: &AppHandle<Wry>, profile_store: &ProfileStore) -> String {
    current_main_window(app)
        .and_then(|window| window.url().ok())
        .map(|url| url.to_string())
        .filter(|url| !url.is_empty() && url != "about:blank")
        .unwrap_or_else(|| current_homepage(profile_store))
}

fn rebuild_main_window_to(app: &AppHandle<Wry>, target_url: String, failure_label: &str) {
    stop_main_window_loading(app);
    let profile_store = app.state::<ProfileStore>();
    if let Err(error) = browser::rebuild_main_window(app, &profile_store, Some(target_url)) {
        show_menu_error(format!("{failure_label}：{error}"));
    }
}

fn parse_https_url(raw: &str) -> Result<Url, String> {
    let trimmed = raw.trim();
    if !trimmed.starts_with("https://") {
        return Err("仅支持 https:// 网址。".to_string());
    }
    let url = Url::parse(trimmed).map_err(|_| "网址无效。".to_string())?;
    if url.host_str().is_none_or(|host| host.is_empty()) {
        return Err("网址缺少有效域名。".to_string());
    }
    Ok(url)
}

fn percent_encode_data_url(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len());
    for byte in input.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn rebuild_menu(app: &AppHandle<Wry>, profile_store: &ProfileStore) {
    let menu = menu::build_app_menu(app, profile_store);
    if let Err(error) = app.set_menu(menu) {
        eprintln!("failed to rebuild menu: {error}");
    }
}

fn clamp_webview_zoom(scale: f64) -> f64 {
    if scale.is_finite() {
        scale.clamp(MIN_WEBVIEW_ZOOM, MAX_WEBVIEW_ZOOM)
    } else {
        1.0
    }
}

fn webview_zoom_persistence_script(scale: f64) -> String {
    format!(
        "try {{ window.localStorage.setItem({key:?}, {value:?}); }} catch (_) {{}}",
        key = WEBVIEW_ZOOM_STORAGE_KEY,
        value = format!("{:.2}", clamp_webview_zoom(scale)),
    )
}

fn set_menu_zoom(app: &AppHandle<Wry>, next: f64) {
    let clamped = clamp_webview_zoom(next);
    if let Some(window) = current_main_window(app) {
        if let Err(error) = window.set_zoom(clamped) {
            show_menu_error(format!("缩放失败：{error}"));
            return;
        }
        let _ = window.eval(&webview_zoom_persistence_script(clamped));
    }
    if let Ok(mut zoom) = app.state::<NativeZoomState>().0.lock() {
        *zoom = clamped;
    }
}

fn adjust_menu_zoom(app: &AppHandle<Wry>, delta: f64) {
    let current = app
        .state::<NativeZoomState>()
        .0
        .lock()
        .map(|zoom| *zoom)
        .unwrap_or(1.0);
    set_menu_zoom(app, current + delta);
}

#[cfg(target_os = "macos")]
fn remove_profile_data_store(app: &AppHandle<Wry>, profile_id: &str) {
    let Some(uuid_bytes) = browser::profile_id_to_uuid_bytes(profile_id) else {
        return;
    };
    let app = app.clone();
    let profile_id = profile_id.to_string();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = app.remove_data_store(uuid_bytes).await {
            eprintln!("failed to remove data store for profile '{profile_id}': {error}");
        }
    });
}

#[cfg(not(target_os = "macos"))]
fn remove_profile_data_store(_app: &AppHandle<Wry>, _profile_id: &str) {}

#[derive(Debug, Eq, Hash, PartialEq)]
struct CookieIdentity {
    domain: String,
    name: String,
    path: String,
}

impl CookieIdentity {
    fn imported(cookie: &cookies::ExportedCookie) -> Self {
        Self {
            domain: normalize_cookie_domain(&cookie.domain),
            name: cookie.name.trim().to_string(),
            path: if cookie.path.is_empty() {
                "/".to_string()
            } else {
                cookie.path.clone()
            },
        }
    }

    fn stored(cookie: &tauri::webview::cookie::Cookie<'_>) -> Self {
        Self {
            domain: normalize_cookie_domain(cookie.domain().unwrap_or("")),
            name: cookie.name().to_string(),
            path: cookie.path().unwrap_or("/").to_string(),
        }
    }
}

fn normalize_cookie_domain(domain: &str) -> String {
    domain.trim().trim_start_matches('.').to_ascii_lowercase()
}

fn cookie_same_site(value: Option<&str>) -> Option<tauri::webview::cookie::SameSite> {
    match value.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("lax") => Some(tauri::webview::cookie::SameSite::Lax),
        Some("strict") => Some(tauri::webview::cookie::SameSite::Strict),
        Some("none") | Some("no_restriction") => Some(tauri::webview::cookie::SameSite::None),
        _ => None,
    }
}

fn set_imported_cookie(
    window: &WebviewWindow<Wry>,
    cookie: &cookies::ExportedCookie,
) -> Result<(), String> {
    let domain = cookie.domain.trim();
    let name = cookie.name.trim();
    let path = if cookie.path.is_empty() {
        "/"
    } else {
        &cookie.path
    };
    let mut builder = build_webview_cookie(
        name,
        cookie.value.as_str(),
        domain,
        path,
        cookie.secure.unwrap_or(false),
        cookie.http_only.unwrap_or(false),
        cookie.host_only.unwrap_or(false),
    );
    if let Some(same_site) = cookie_same_site(cookie.same_site.as_deref()) {
        builder = builder.same_site(same_site);
    }
    if cookie.session != Some(true) {
        if let Some(exp) = cookie.expiration_date {
            use tauri::webview::cookie::time;
            if let Ok(dt) = time::OffsetDateTime::from_unix_timestamp(exp as i64) {
                builder = builder.expires(dt);
            }
        }
    }
    window
        .set_cookie(builder.build())
        .map_err(|error| format!("设置 cookie「{}」失败：{error}", cookie.name))
}

fn cookie_domain_is_chatgpt_related(domain: &str) -> bool {
    let domain = normalize_cookie_domain(domain);
    domain == "chatgpt.com"
        || domain.ends_with(".chatgpt.com")
        || domain == "chat.openai.com"
        || domain.ends_with(".chat.openai.com")
        || domain == "openai.com"
        || domain.ends_with(".openai.com")
        || domain == "auth.openai.com"
        || domain.ends_with(".auth.openai.com")
        || domain == "auth0.openai.com"
        || domain.ends_with(".auth0.openai.com")
        || domain == "login.openai.com"
        || domain.ends_with(".login.openai.com")
}

fn stored_cookie_is_chatgpt_related(cookie: &tauri::webview::cookie::Cookie<'_>) -> bool {
    cookie
        .domain()
        .map(cookie_domain_is_chatgpt_related)
        .unwrap_or(false)
}

fn approximate_chatgpt_cookie_header_bytes(
    cookies: &[tauri::webview::cookie::Cookie<'static>],
) -> usize {
    cookies
        .iter()
        .filter(|cookie| stored_cookie_is_chatgpt_related(cookie))
        .map(|cookie| cookie.name().len() + cookie.value().len() + 2)
        .sum()
}

fn delete_stored_cookie(
    window: &WebviewWindow<Wry>,
    cookie: &tauri::webview::cookie::Cookie<'_>,
) -> Result<(), String> {
    let mut builder = tauri::webview::cookie::Cookie::build((cookie.name().to_string(), ""));
    if let Some(path) = cookie.path() {
        builder = builder.path(path.to_string());
    }
    if let Some(domain) = cookie.domain() {
        builder = builder.domain(domain.to_string());
    }
    window
        .delete_cookie(builder.build())
        .map_err(|error| format!("删除 cookie「{}」失败：{error}", cookie.name()))
}

pub(crate) fn prune_oversized_chatgpt_cookies(window: &WebviewWindow<Wry>) -> Result<usize, String> {
    let stored = window
        .cookies()
        .map_err(|error| format!("读取 cookies 失败：{error}"))?;
    let header_bytes = approximate_chatgpt_cookie_header_bytes(&stored);
    if header_bytes <= MAX_CHATGPT_COOKIE_HEADER_BYTES {
        return Ok(0);
    }

    let mut deleted = 0;
    for cookie in stored
        .iter()
        .filter(|cookie| stored_cookie_is_chatgpt_related(cookie))
        .filter(|cookie| !cookies::is_chatgpt_essential_cookie_name(cookie.name()))
    {
        if delete_stored_cookie(window, cookie).is_ok() {
            deleted += 1;
        }
    }
    Ok(deleted)
}

fn filter_essential_chatgpt_import_cookies(
    cookies: Vec<cookies::ExportedCookie>,
) -> (Vec<cookies::ExportedCookie>, usize) {
    let original_count = cookies.len();
    let filtered: Vec<cookies::ExportedCookie> = cookies
        .into_iter()
        .filter(|cookie| cookies::is_chatgpt_essential_cookie_name(cookie.name.trim()))
        .collect();
    let skipped_count = original_count.saturating_sub(filtered.len());
    (filtered, skipped_count)
}

fn import_cookies_into_current_window(
    app: &AppHandle<Wry>,
    raw: &str,
    source_label: &str,
) -> Result<(), String> {
    let parsed_all = cookies::parse_cookie_import(raw)?;
    let parsed_all_count = parsed_all.len();
    let (parsed, skipped_count) = filter_essential_chatgpt_import_cookies(parsed_all);
    if parsed.is_empty() {
        return Err(
            "未发现关键 ChatGPT 登录 cookie。为避免请求头过大导致白屏，已拒绝导入低价值 cookie。"
                .to_string(),
        );
    }
    let window = current_main_window(app).ok_or_else(|| "未找到主窗口。".to_string())?;

    for cookie in &parsed {
        set_imported_cookie(&window, cookie)?;
    }
    let _ = prune_oversized_chatgpt_cookies(&window);

    let stored = window
        .cookies()
        .map_err(|error| format!("导入后读取 cookies 失败：{error}"))?;
    let imported_identities: std::collections::HashSet<CookieIdentity> =
        parsed.iter().map(CookieIdentity::imported).collect();
    let stored_identities: std::collections::HashSet<CookieIdentity> =
        stored.iter().map(CookieIdentity::stored).collect();
    let stored_count = imported_identities
        .intersection(&stored_identities)
        .count();
    let imported_login_names: std::collections::HashSet<String> = parsed
        .iter()
        .map(|cookie| cookie.name.trim().to_string())
        .filter(|name| cookies::is_chatgpt_essential_cookie_name(name))
        .collect();
    let stored_login_names: std::collections::HashSet<String> = stored
        .iter()
        .map(|cookie| cookie.name().to_string())
        .filter(|name| imported_login_names.contains(name))
        .collect();
    let missing_login_names: Vec<String> = imported_login_names
        .difference(&stored_login_names)
        .cloned()
        .collect();

    let profile_store = app.state::<ProfileStore>();
    let profile_name = profile_store.current_profile().name;
    let mut lines = vec![
        format!("来源：{source_label}"),
        format!("当前空间：{profile_name}"),
        format!(
            "已解析 {} 个 cookie，导入 {} 个关键 cookie，跳过 {skipped_count} 个低价值 cookie；WebKit 当前可读到 {stored_count}/{} 个目标 cookie。",
            parsed_all_count,
            parsed.len(),
            imported_identities.len()
        ),
    ];

    let has_session_cookie = imported_login_names
        .iter()
        .any(|name| cookies::is_chatgpt_session_cookie_name(name));

    if !has_session_cookie {
        lines.push("提示：本次内容没有 ChatGPT session-token，通常不能直接免登录。".to_string());
    } else if missing_login_names.is_empty() {
        let mut names: Vec<String> = imported_login_names.into_iter().collect();
        names.sort();
        lines.push(format!("关键登录 cookie 已写入：{}", names.join(", ")));
    } else {
        let mut names = missing_login_names;
        names.sort();
        lines.push(format!("缺失关键登录 cookie：{}", names.join(", ")));
    }

    if stored_count < imported_identities.len() {
        let missing_names: Vec<String> = imported_identities
            .difference(&stored_identities)
            .take(8)
            .map(|identity| identity.name.clone())
            .collect();
        if !missing_names.is_empty() {
            lines.push(format!("未写入或不可读：{}", missing_names.join(", ")));
        }
    }

    lines.push("正在刷新页面。".to_string());
    let _ = window.reload();
    native_alert("Cookie 导入结果", &lines.join("\n"));
    Ok(())
}

fn set_default_profile_by_id(app: &AppHandle<Wry>, profile_id: &str) {
    let profile_store = app.state::<ProfileStore>();
    let previous_current_id = profile_store.current_profile_id();
    let profile = match profile_store.set_default_profile(profile_id) {
        Ok(profile) => profile,
        Err(error) => {
            show_menu_error(format!("设置默认空间失败：{error}"));
            return;
        }
    };

    rebuild_menu(app, &profile_store);
    if previous_current_id != profile.id {
        if let Err(error) = browser::rebuild_main_window(app, &profile_store, None) {
            show_menu_error(format!("重建窗口失败：{error}"));
            return;
        }
    }
    native_alert("ChatGPT Rust", &format!("已将「{}」设为默认空间。", profile.name));
}

fn delete_profile_by_id(app: &AppHandle<Wry>, profile_id: &str) {
    if profile_id == profile::DEFAULT_PROFILE_ID {
        show_menu_error("默认内置空间不能删除。");
        return;
    }

    let profile_store = app.state::<ProfileStore>();
    let Some(target) = profile_store
        .list_profiles()
        .into_iter()
        .find(|profile| profile.id == profile_id)
    else {
        show_menu_error("要删除的空间不存在。");
        return;
    };

    if !native_confirm(
        "删除账号空间",
        &format!(
            "删除账号空间「{}」？\n\n本空间的所有 cookie、登录态、缓存与本地存储将被永久删除。其他空间不受影响。",
            target.name
        ),
    ) {
        return;
    }

    let deleting_current = profile_store.current_profile_id() == target.id;
    if let Err(error) = profile_store.delete_profile(&target.id) {
        show_menu_error(format!("删除空间失败：{error}"));
        return;
    }

    rebuild_menu(app, &profile_store);

    let mut can_remove_data_store = true;
    if deleting_current {
        browser::close_auth_popups(app);
        if let Err(error) = browser::rebuild_main_window(app, &profile_store, None) {
            can_remove_data_store = false;
            show_menu_error(format!("重建窗口失败：{error}"));
        }
    } else {
        native_alert("ChatGPT Rust", &format!("已删除账号空间「{}」。", target.name));
    }

    if can_remove_data_store {
        remove_profile_data_store(app, &target.id);
    }
}

// --- Menu event handler ---

fn handle_menu_event(app: &AppHandle<Wry>, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref();

    if let Some(profile_id) = menu::extract_delete_profile_id(id) {
        delete_profile_by_id(app, profile_id);
        return;
    }

    if let Some(profile_id) = menu::extract_set_default_profile_id(id) {
        set_default_profile_by_id(app, profile_id);
        return;
    }

    // Profile switching
    if let Some(profile_id) = menu::extract_profile_id(id) {
        let profile_store = app.state::<ProfileStore>();
        if profile_store.current_profile_id() == profile_id {
            return; // Already on this profile
        }
        if let Err(e) = profile_store.switch_profile(profile_id) {
            show_menu_error(format!("切换空间失败：{e}"));
            return;
        }
        rebuild_menu(app, &profile_store);
        if let Err(e) = browser::rebuild_main_window(app, &profile_store, None) {
            show_menu_error(format!("重建窗口失败：{e}"));
        }
        return;
    }

    // Fingerprint preset selection
    if let Some(preset_id) = menu::extract_preset_id(id) {
        let profile_store = app.state::<ProfileStore>();
        let current_id = profile_store.current_profile_id();
        let mut meta = profile_store.get_meta(&current_id);

        if preset_id == fingerprint::OFF_PRESET_ID {
            meta.fingerprint = None;
            meta.fingerprint_disabled = true;
        } else if let Some(fp) = fingerprint::preset_by_id(preset_id) {
            meta.fingerprint = Some(fp);
            meta.fingerprint_disabled = false;
        }
        if let Err(error) = profile_store.set_meta(&current_id, &meta) {
            show_menu_error(format!("保存指纹设置失败：{error}"));
            return;
        }
        rebuild_menu(app, &profile_store);
        let current_url = app
            .get_webview_window(MAIN_WINDOW_LABEL)
            .and_then(|w| w.url().ok())
            .map(|u| u.to_string());
        if let Err(error) = browser::rebuild_main_window(app, &profile_store, current_url) {
            show_menu_error(format!("重建窗口失败：{error}"));
        }
        return;
    }

    match id {
        menu::event_id::NAV_BACK => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval("history.back()");
            }
        }
        menu::event_id::NAV_FORWARD => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval("history.forward()");
            }
        }
        menu::event_id::NAV_HOME => {
            let profile_store = app.state::<ProfileStore>();
            let homepage = current_homepage(&profile_store);
            rebuild_main_window_to(app, homepage, "回到首页失败");
        }
        menu::event_id::NAV_RELOAD => {
            let profile_store = app.state::<ProfileStore>();
            let target_url = current_reload_target(app, &profile_store);
            rebuild_main_window_to(app, target_url, "重新加载失败");
        }
        menu::event_id::ZOOM_IN => {
            adjust_menu_zoom(app, 0.05);
        }
        menu::event_id::ZOOM_OUT => {
            adjust_menu_zoom(app, -0.05);
        }
        menu::event_id::ZOOM_RESET => {
            set_menu_zoom(app, 1.0);
        }
        menu::event_id::OPEN_FINGERPRINT_TEST => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let meta = profile_store.get_meta(&current_id);
            let engine_label = match meta.fingerprint.as_ref().map(|f| f.engine.as_str()) {
                Some("chromium") => "Chromium",
                Some("webkitgtk") => "WebKitGTK",
                _ => "Safari/WebKit",
            };
            let html = privacy::fingerprint_test_page_html(engine_label);
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let data_url = format!(
                    "data:text/html;charset=utf-8,{}",
                    percent_encode_data_url(&html)
                );
                if let Ok(url) = Url::parse(&data_url) {
                    let _ = w.navigate(url);
                }
            }
        }
        menu::event_id::TOGGLE_WEBRTC => {
            // Toggle WebRTC protection and rebuild
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.webrtc_enabled = !meta.webrtc_enabled;
            if let Err(error) = profile_store.set_meta(&current_id, &meta) {
                show_menu_error(format!("保存 WebRTC 设置失败：{error}"));
                return;
            }
            rebuild_menu(app, &profile_store);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            if let Err(error) = browser::rebuild_main_window(app, &profile_store, current_url) {
                show_menu_error(format!("重建窗口失败：{error}"));
            }
        }
        menu::event_id::PRIVACY_STATUS => {
            let profile_store = app.state::<ProfileStore>();
            let profile = profile_store.current_profile();
            let meta = profile_store.get_meta(&profile.id);
            let fp_text = meta
                .fingerprint
                .as_ref()
                .map(|f| f.display_name.as_str())
                .unwrap_or("默认（不混淆）");
            let ep_text = if meta.enhanced_privacy { "开启" } else { "关闭" };
            let webrtc_text = if meta.webrtc_enabled { "开启" } else { "关闭" };
            let isolation_text = if profile.id == profile::DEFAULT_PROFILE_ID {
                "默认空间使用应用默认 WebView 数据存储"
            } else {
                "当前空间使用独立 WebView 数据存储"
            };
            let msg = format!(
                "当前空间：{name}\n数据隔离：{isolation}\n指纹预设：{fp}\n增强隐私：{ep}\nWebRTC 防护：{webrtc}\nGPC：JS 信号开启",
                name = profile.name,
                isolation = isolation_text,
                fp = fp_text,
                ep = ep_text,
                webrtc = webrtc_text,
            );
            native_alert("隐私状态", &msg);
        }
        menu::event_id::FP_RANDOMIZE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.fingerprint = Some(fingerprint::random_fingerprint());
            meta.fingerprint_disabled = false;
            if let Err(error) = profile_store.set_meta(&current_id, &meta) {
                show_menu_error(format!("保存随机指纹失败：{error}"));
                return;
            }
            rebuild_menu(app, &profile_store);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            if let Err(error) = browser::rebuild_main_window(app, &profile_store, current_url) {
                show_menu_error(format!("重建窗口失败：{error}"));
            }
        }
        menu::event_id::FP_ABOUT => {
            let msg = "默认：使用系统 WebKit/Safari 指纹，不做混淆。\n\n可选混淆：每个空间固定一套指纹，覆盖 UA、navigator、screen、Canvas、WebGL、AudioContext 等。\n\n挡不住：TLS 指纹、HTTP/2 帧顺序、Worker/字体/GPU/IP/行为模式。\n\n建议：日常保持默认 Safari 指纹；只有明确需要隔离特征时，再手动选择或随机化当前空间指纹。";
            native_alert("关于指纹混淆", msg);
        }
        menu::event_id::TOGGLE_ENHANCED_PRIVACY => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.enhanced_privacy = !meta.enhanced_privacy;
            if let Err(error) = profile_store.set_meta(&current_id, &meta) {
                show_menu_error(format!("保存增强隐私设置失败：{error}"));
                return;
            }
            rebuild_menu(app, &profile_store);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            if let Err(error) = browser::rebuild_main_window(app, &profile_store, current_url) {
                show_menu_error(format!("重建窗口失败：{error}"));
            }
        }
        menu::event_id::SET_DEFAULT_PROFILE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            set_default_profile_by_id(app, &current_id);
        }
        menu::event_id::GO_TO_URL => {
            let current = current_main_window(app)
                .and_then(|window| window.url().ok())
                .map(|url| url.to_string())
                .unwrap_or_else(|| "https://chatgpt.com/".to_string());
            let Some(raw) = native_prompt("前往网址", "输入 https:// 开头的网址：", &current) else {
                return;
            };
            match parse_https_url(&raw) {
                Ok(url) => {
                    rebuild_main_window_to(app, url.to_string(), "前往网址失败");
                }
                Err(error) => show_menu_error(error),
            }
        }
        menu::event_id::ADD_PROFILE => {
            let Some(name) = native_prompt("新建账号空间", "输入空间名称：", "") else {
                return;
            };
            let name = name.trim();
            if name.is_empty() {
                return;
            }
            let profile_store = app.state::<ProfileStore>();
            match profile_store.create_profile(name) {
                Ok(profile) => {
                    if let Err(error) = profile_store.switch_profile(&profile.id) {
                        show_menu_error(format!("切换空间失败：{error}"));
                        return;
                    }
                    rebuild_menu(app, &profile_store);
                    if let Err(error) = browser::rebuild_main_window(app, &profile_store, None) {
                        show_menu_error(format!("重建窗口失败：{error}"));
                    }
                }
                Err(error) => show_menu_error(format!("新建空间失败：{error}")),
            }
        }
        menu::event_id::CLONE_PROFILE => {
            let profile_store = app.state::<ProfileStore>();
            let current = profile_store.current_profile();
            let default_name = format!("{} 副本", current.name);
            let Some(name) =
                native_prompt("克隆当前空间", "输入新空间名称（留空自动生成）：", &default_name)
            else {
                return;
            };
            let copy_cookies = native_confirm(
                "克隆当前空间",
                "是否同时复制 cookies？\n\n点“确定”会复制当前空间的 cookies 到新空间。",
            );
            let current_id = profile_store.current_profile_id();
            match profile_store.clone_profile(&current_id, name.trim()) {
                Ok((profile, _source_meta)) => {
                    clear_pending_cookies(app);
                    if copy_cookies {
                        match current_main_window(app) {
                            Some(source_window) => match source_window.cookies() {
                                Ok(cookies) if cookies.is_empty() => {
                                    native_alert(
                                        "克隆当前空间",
                                        "当前空间没有可复制的 cookies，将只克隆配置。",
                                    );
                                }
                                Ok(cookies) => {
                                    let cookie_values: Vec<serde_json::Value> = cookies
                                        .iter()
                                        .map(|c| {
                                            serde_json::json!({
                                                "name": c.name(),
                                                "value": c.value(),
                                                "domain": c.domain().unwrap_or(""),
                                                "path": c.path().unwrap_or("/"),
                                                "secure": c.secure().unwrap_or(false),
                                                "http_only": c.http_only().unwrap_or(false),
                                                "host_only": !c.domain().unwrap_or("").starts_with('.'),
                                                "expires": c.expires_datetime().map(|dt| dt.unix_timestamp() as f64),
                                            })
                                        })
                                        .collect();
                                    if let Err(error) = queue_pending_cookies(app, cookie_values) {
                                        show_menu_error(format!(
                                            "准备复制 cookies 失败，将只克隆配置：{error}"
                                        ));
                                    }
                                }
                                Err(error) => show_menu_error(format!(
                                    "读取源 cookies 失败，将只克隆配置：{error}"
                                )),
                            },
                            None => show_menu_error("未找到源窗口，将只克隆配置。"),
                        }
                    }

                    if let Err(error) = profile_store.switch_profile(&profile.id) {
                        clear_pending_cookies(app);
                        show_menu_error(format!("切换空间失败：{error}"));
                        return;
                    }
                    rebuild_menu(app, &profile_store);
                    if let Err(error) = browser::rebuild_main_window(app, &profile_store, None) {
                        clear_pending_cookies(app);
                        show_menu_error(format!("重建窗口失败：{error}"));
                        return;
                    }
                }
                Err(error) => show_menu_error(format!("克隆空间失败：{error}")),
            }
        }
        menu::event_id::RENAME_PROFILE => {
            let profile_store = app.state::<ProfileStore>();
            let current = profile_store.current_profile();
            let Some(name) = native_prompt("重命名当前空间", "输入新名称：", &current.name) else {
                return;
            };
            let name = name.trim();
            if name.is_empty() {
                return;
            }
            match profile_store.rename_profile(&current.id, name) {
                Ok(()) => {
                    rebuild_menu(app, &profile_store);
                    if let Some(window) = current_main_window(app) {
                        let title = browser::main_window_title(name, &current.id);
                        let _ = window.set_title(&title);
                    }
                }
                Err(error) => show_menu_error(format!("重命名失败：{error}")),
            }
        }
        menu::event_id::DELETE_PROFILE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            delete_profile_by_id(app, &current_id);
        }
        menu::event_id::SET_HOMEPAGE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let current_url = current_main_window(app)
                .and_then(|window| window.url().ok())
                .map(|url| url.to_string())
                .unwrap_or_else(|| profile_store.homepage_url(&current_id));
            let Some(raw) =
                native_prompt("设置当前空间首页", "输入 https:// 网址：", &current_url)
            else {
                return;
            };
            match parse_https_url(&raw) {
                Ok(url) => {
                    if let Err(error) = profile_store.set_homepage(&current_id, url.as_str()) {
                        show_menu_error(format!("设置首页失败：{error}"));
                        return;
                    }
                    rebuild_main_window_to(app, url.to_string(), "加载新首页失败");
                }
                Err(error) => show_menu_error(error),
            }
        }
        menu::event_id::RESET_HOMEPAGE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            if let Err(error) = profile_store.set_homepage(&current_id, "") {
                show_menu_error(format!("恢复默认首页失败：{error}"));
                return;
            }
            let homepage = profile_store.homepage_url(&current_id);
            rebuild_main_window_to(app, homepage, "恢复首页失败");
        }
        menu::event_id::EXPORT_PROFILE => {
            let profile_store = app.state::<ProfileStore>();
            let profile = profile_store.current_profile();
            let meta = profile_store.get_meta(&profile.id);
            let doc = ProfileExportDocument {
                schema_version: 1,
                exported_at: chrono_now(),
                source_profile_id: profile.id.clone(),
                name: profile.name.clone(),
                homepage: meta.homepage.clone(),
                fingerprint: meta.fingerprint.clone(),
                fingerprint_disabled: Some(meta.fingerprint_disabled),
                enhanced_privacy_enabled: meta.enhanced_privacy,
                webrtc_enabled: Some(meta.webrtc_enabled),
            };
            match serde_json::to_string_pretty(&doc) {
                Ok(json) => {
                    match arboard::Clipboard::new() {
                        Ok(mut clipboard) => {
                            if let Err(e) = clipboard.set_text(&json) {
                                show_menu_error(format!("写入剪贴板失败：{e}"));
                            } else {
                                native_alert("ChatGPT Rust", "已复制当前空间配置到剪贴板。");
                            }
                        }
                        Err(e) => show_menu_error(format!("访问剪贴板失败：{e}")),
                    }
                }
                Err(e) => show_menu_error(format!("导出失败：{e}")),
            }
        }
        menu::event_id::IMPORT_PROFILE => {
            if !native_confirm(
                "导入空间配置",
                "将从剪贴板读取之前导出的空间 JSON，并导入为新空间。",
            ) {
                return;
            }
            let json = match arboard::Clipboard::new().and_then(|mut clipboard| clipboard.get_text()) {
                Ok(text) => text,
                Err(error) => {
                    show_menu_error(format!("读取剪贴板失败：{error}"));
                    return;
                }
            };
            let doc: ProfileExportDocument = match serde_json::from_str(&json) {
                Ok(doc) => doc,
                Err(error) => {
                    show_menu_error(format!("Profile JSON 解析失败：{error}"));
                    return;
                }
            };
            if doc.schema_version != 1 {
                show_menu_error("Profile JSON 版本不支持。");
                return;
            }
            let profile_store = app.state::<ProfileStore>();
            let name = if doc.name.trim().is_empty() {
                "导入空间".to_string()
            } else {
                doc.name.clone()
            };
            let profile = match profile_store.create_profile(&name) {
                Ok(profile) => profile,
                Err(error) => {
                    show_menu_error(format!("创建导入空间失败：{error}"));
                    return;
                }
            };
            if let Some(ref homepage) = doc.homepage {
                if homepage.starts_with("https://") {
                    if let Err(error) = profile_store.set_homepage(&profile.id, homepage) {
                        show_menu_error(format!("导入首页失败：{error}"));
                        let _ = profile_store.delete_profile(&profile.id);
                        return;
                    }
                }
            }
            let mut meta = profile_store.get_meta(&profile.id);
            if let Some(fp) = doc.fingerprint {
                meta.fingerprint = Some(fp);
                meta.fingerprint_disabled = false;
            } else if doc.fingerprint_disabled == Some(true) {
                meta.fingerprint_disabled = true;
            }
            meta.enhanced_privacy = doc.enhanced_privacy_enabled;
            if let Some(webrtc_enabled) = doc.webrtc_enabled {
                meta.webrtc_enabled = webrtc_enabled;
            }
            if let Err(error) = profile_store.set_meta(&profile.id, &meta) {
                show_menu_error(format!("导入空间设置失败：{error}"));
                let _ = profile_store.delete_profile(&profile.id);
                return;
            }
            if let Err(error) = profile_store.switch_profile(&profile.id) {
                show_menu_error(format!("切换导入空间失败：{error}"));
                return;
            }
            rebuild_menu(app, &profile_store);
            if let Err(error) = browser::rebuild_main_window(app, &profile_store, None) {
                show_menu_error(format!("重建窗口失败：{error}"));
            }
        }
        menu::event_id::IMPORT_COOKIES => {
            let Some(path) = native_choose_file(
                "选择 cookie 文件。支持 JSON、Netscape cookies.txt、Cookie/Header String 文本。将导入到当前账号空间。",
            ) else {
                return;
            };
            let raw = match fs::read_to_string(&path) {
                Ok(text) => text,
                Err(error) => {
                    show_menu_error(format!("读取 cookie 文件失败：{error}"));
                    return;
                }
            };
            let label = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("cookie 文件");
            if let Err(error) = import_cookies_into_current_window(app, &raw, label) {
                show_menu_error(format!("Cookie 导入失败：{error}"));
            }
        }
        menu::event_id::PASTE_COOKIES => {
            if !native_confirm(
                "粘贴 Cookies",
                "将从剪贴板读取 Cookies 文本。支持 JSON、Netscape cookies.txt、Cookie/Header String。内容会导入到当前账号空间。",
            ) {
                return;
            }
            let raw = match arboard::Clipboard::new().and_then(|mut clipboard| clipboard.get_text()) {
                Ok(text) => text,
                Err(error) => {
                    show_menu_error(format!("读取剪贴板失败：{error}"));
                    return;
                }
            };
            if let Err(error) = import_cookies_into_current_window(app, &raw, "剪贴板") {
                show_menu_error(format!("Cookie 导入失败：{error}"));
            }
        }
        menu::event_id::EXPORT_COOKIES => {
            let Some(window) = current_main_window(app) else {
                show_menu_error("未找到主窗口。");
                return;
            };
            let cookies = match window.cookies() {
                Ok(cookies) => cookies,
                Err(error) => {
                    show_menu_error(format!("读取 cookies 失败：{error}"));
                    return;
                }
            };
            if cookies.is_empty() {
                show_menu_error("当前空间没有可导出的 cookie。");
                return;
            }
            let exported: Vec<serde_json::Value> = cookies
                .iter()
                .map(|c| {
                    serde_json::json!({
                        "domain": c.domain().unwrap_or(""),
                        "name": c.name(),
                        "value": c.value(),
                        "path": c.path().unwrap_or("/"),
                        "secure": c.secure().unwrap_or(false),
                        "httpOnly": c.http_only().unwrap_or(false),
                        "session": c.expires().is_none(),
                        "hostOnly": !c.domain().unwrap_or("").starts_with('.'),
                        "expirationDate": c.expires_datetime().map(|dt| dt.unix_timestamp() as f64),
                        "sameSite": match c.same_site() {
                            Some(tauri::webview::cookie::SameSite::Lax) => "lax",
                            Some(tauri::webview::cookie::SameSite::Strict) => "strict",
                            Some(tauri::webview::cookie::SameSite::None) => "none",
                            _ => "unspecified",
                        },
                    })
                })
                .collect();
            let json = match serde_json::to_string_pretty(&exported) {
                Ok(json) => json,
                Err(error) => {
                    show_menu_error(format!("JSON 序列化失败：{error}"));
                    return;
                }
            };
            match arboard::Clipboard::new().and_then(|mut clipboard| clipboard.set_text(&json)) {
                Ok(()) => native_alert(
                    "ChatGPT Rust",
                    &format!("已复制 {} 个 cookie 到剪贴板（含 HttpOnly）。", cookies.len()),
                ),
                Err(error) => show_menu_error(format!("写入剪贴板失败：{error}")),
            }
        }
        menu::event_id::BURN_CURRENT_PROFILE => {
            if !native_confirm(
                "焚烧当前空间",
                "会删除当前空间所有 cookies、缓存、localStorage、IndexedDB、Service Worker 等网站数据，关闭弹窗，清空页面历史，重建浏览器视图，并恢复默认 Safari 指纹。\n\n保留：空间名称、首页、增强隐私设置。其他空间不受影响。",
            ) {
                return;
            }
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let Some(window) = current_main_window(app) else {
                show_menu_error("未找到主窗口，无法清理当前空间。");
                return;
            };
            if let Err(error) = window.clear_all_browsing_data() {
                show_menu_error(format!("清理浏览数据失败：{error}"));
                return;
            }
            browser::close_auth_popups(app);
            let mut meta = profile_store.get_meta(&current_id);
            meta.fingerprint = None;
            meta.fingerprint_disabled = true;
            if let Err(error) = profile_store.set_meta(&current_id, &meta) {
                show_menu_error(format!("恢复默认指纹失败：{error}"));
                return;
            }
            let homepage = profile_store.homepage_url(&current_id);
            if let Err(error) = browser::rebuild_main_window(app, &profile_store, Some(homepage)) {
                show_menu_error(format!("重建窗口失败：{error}"));
            } else {
                native_alert("ChatGPT Rust", "已焚烧当前空间浏览现场，并恢复默认 Safari 指纹。");
            }
        }
        menu::event_id::NEW_INCOGNITO => {
            // Open a non-persistent incognito window
            let browser_state = app.state::<BrowserState>();
            let label = format!(
                "incognito-{}",
                browser_state.popup_counter.fetch_add(1, Ordering::Relaxed) + 1
            );
            let app_for_nav = app.clone();
            let app_for_download = app.clone();
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let init_scripts = browser::build_init_scripts(&profile_store, &current_id);
            let user_agent = browser::profile_user_agent(&profile_store, &current_id);
            let mut builder = WebviewWindowBuilder::new(
                app,
                label,
                WebviewUrl::External("about:blank".parse().unwrap()),
            )
            .title("ChatGPT Rust · 无痕")
            .inner_size(1200.0, 800.0)
            .min_inner_size(720.0, 480.0)
            .resizable(true)
            .center()
            .focused(true)
            .incognito(true)
            .user_agent(&user_agent)
            .on_navigation(move |url| handle_navigation(&app_for_nav, url))
            .on_download(move |_webview, event| handle_download_event(&app_for_download, event));
            for script in &init_scripts {
                builder = builder.initialization_script(script);
            }
            match builder.build() {
                Ok(window) => {
                    if let Ok(url) = Url::parse("https://chatgpt.com/") {
                        if let Err(error) = window.navigate(url) {
                            show_menu_error(format!("打开无痕窗口失败：{error}"));
                        }
                    }
                }
                Err(error) => show_menu_error(format!("新建无痕窗口失败：{error}")),
            }
        }
        _ => {
            eprintln!("unhandled menu event: {id}");
        }
    }
}

fn build_webview_cookie<'a>(
    name: &'a str,
    value: &'a str,
    domain: &'a str,
    path: &'a str,
    secure: bool,
    http_only: bool,
    host_only: bool,
) -> tauri::webview::cookie::CookieBuilder<'a> {
    let mut cookie = tauri::webview::cookie::Cookie::build((name, value))
        .path(path)
        .secure(secure)
        .http_only(http_only);

    if !host_only {
        cookie = cookie.domain(domain);
    }

    cookie
}

// --- Main entry point ---

pub fn run() {
    let window_state_plugin = WindowStateBuilder::default()
        .with_state_flags(
            StateFlags::POSITION
                | StateFlags::SIZE
                | StateFlags::MAXIMIZED
                | StateFlags::FULLSCREEN,
        )
        .build();

    tauri::Builder::default()
        .plugin(window_state_plugin)
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            show_main_window(app);
        }))
        .manage(BlobDownloadSessions::default())
        .manage(BrowserState::new())
        .manage(PendingCookies::default())
        .manage(NativeZoomState::default())
        .invoke_handler(tauri::generate_handler![
            start_blob_download,
            append_blob_download,
            finish_blob_download,
            cancel_blob_download,
            set_native_webview_zoom,
        ])
        .setup(move |app| {
            let app_data_dir = match app.path().app_data_dir() {
                Ok(path) => path,
                Err(error) => {
                    return Err(startup_error(format!(
                        "无法解析应用数据目录，暂时不能启动。\n\n错误：{error}"
                    )));
                }
            };

            let profile_store = match ProfileStore::new(&app_data_dir) {
                Ok(store) => store,
                Err(error) => {
                    return Err(startup_error(format!(
                        "无法初始化账号空间。\n\n数据目录：{}\n错误：{error}",
                        app_data_dir.display()
                    )));
                }
            };

            let app_menu = menu::build_app_menu(app.handle(), &profile_store);
            if let Err(error) = app.set_menu(app_menu) {
                return Err(startup_error(format!("无法创建应用菜单：{error}")));
            }

            let _main_window = match browser::build_main_window(app.handle(), &profile_store) {
                Ok(window) => window,
                Err(error) => {
                    return Err(startup_error(format!(
                        "无法创建 ChatGPT 主窗口。\n\n错误：{error}"
                    )));
                }
            };

            app.manage(profile_store);

            Ok(())
        })
        .on_menu_event(|app, event| {
            handle_menu_event(app, event);
        })
        .on_window_event(|window, event| {
            if window.label() != MAIN_WINDOW_LABEL {
                return;
            }

            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .build(tauri::generate_context!())
        .expect("failed to build ChatGPT Rust Tauri app")
        .run(|app, event| {
            match event {
                RunEvent::ExitRequested { api, .. } => {
                    let browser_state = app.state::<BrowserState>();
                    if browser_state
                        .main_rebuild_in_progress
                        .load(Ordering::SeqCst)
                    {
                        api.prevent_exit();
                    }
                }
                RunEvent::Reopen {
                    ..
                } => {
                    show_main_window(app);
                }
                _ => {}
            }
        });
}

// --- Navigation and URL routing ---

fn handle_navigation(app: &AppHandle<Wry>, url: &Url) -> bool {
    if should_stay_inside_app(url) {
        return true;
    }

    if should_open_in_app_root(url) {
        return true;
    }

    open_external_url(url);
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.set_focus();
    }
    false
}

pub(crate) fn should_stay_inside_app(url: &Url) -> bool {
    match url.scheme() {
        "https" => {}
        "about" => return url.as_str() == "about:blank",
        "blob" | "data" => return true,
        "http" => {
            let Some(host) = url.host_str().map(|host| host.to_ascii_lowercase()) else {
                return false;
            };
            return host == "localhost" || host == "127.0.0.1";
        }
        _ => return false,
    }

    let Some(host) = url.host_str().map(|host| host.to_ascii_lowercase()) else {
        return false;
    };

    if is_chatgpt_host(&host)
        || is_openai_auth_host(&host)
        || is_openai_sentinel_host(&host)
        || is_oauth_host(&host, url.path())
        || is_cloudflare_challenge_url(&host, url.path())
    {
        return true;
    }

    false
}

pub(crate) fn should_open_in_app_root(url: &Url) -> bool {
    url.scheme() == "https"
        && url
            .host_str()
            .map(|host| host.eq_ignore_ascii_case("challenges.cloudflare.com"))
            .unwrap_or(false)
}

fn is_chatgpt_host(host: &str) -> bool {
    host == "chatgpt.com"
        || host.ends_with(".chatgpt.com")
        || host == "chat.openai.com"
        || host.ends_with(".chat.openai.com")
}

fn is_openai_auth_host(host: &str) -> bool {
    host == "auth.openai.com"
        || host == "auth0.openai.com"
        || host == "login.openai.com"
        || host.ends_with(".auth.openai.com")
}

fn is_openai_sentinel_host(host: &str) -> bool {
    host == "sentinel.openai.com"
}

fn is_oauth_host(host: &str, path: &str) -> bool {
    let path = path.to_ascii_lowercase();
    let path = path.trim_end_matches('/');

    match host {
        "accounts.google.com" => is_google_auth_path(path),
        host if host.starts_with("accounts.google.") => is_google_auth_path(path),
        "login.microsoftonline.com" => path.contains("/oauth2/")
            || path.ends_with("/oauth2")
            || path.starts_with("/common/login")
            || path.starts_with("/organizations/login")
            || path.starts_with("/consumers/login"),
        "login.live.com" => path.starts_with("/oauth20_"),
        "appleid.apple.com" => path.starts_with("/auth/"),
        "github.com" => path == "/login/oauth/authorize",
        "facebook.com" | "www.facebook.com" => {
            path == "/dialog/oauth" || path == "/v2.0/dialog/oauth"
        }
        "twitter.com" | "x.com" => path.starts_with("/i/oauth2/"),
        _ => false,
    }
}

fn is_google_auth_path(path: &str) -> bool {
    path.starts_with("/o/oauth2/")
        || path == "/signin/oauth"
        || path.starts_with("/signin/oauth/")
        || path == "/accountchooser"
        || path.starts_with("/signin/v2/")
        || path.starts_with("/signin/challenge/")
        || path.starts_with("/signin/identifier")
        || path.starts_with("/signin/chooser")
}

fn is_cloudflare_challenge_url(host: &str, path: &str) -> bool {
    host == "challenges.cloudflare.com" && path.starts_with("/cdn-cgi/challenge-platform/")
}

// --- Download handling ---

fn handle_download_event(app: &AppHandle<Wry>, event: DownloadEvent<'_>) -> bool {
    match event {
        DownloadEvent::Requested { url, destination } => {
            let Ok(downloads_dir) = download_dir(app) else {
                return true;
            };
            let filename = filename_from_url(&url);
            *destination = unique_download_path(&downloads_dir, &filename);
            true
        }
        DownloadEvent::Finished { url, path, success } => {
            if !success {
                eprintln!("download failed: {url} -> {path:?}");
            }
            true
        }
        _ => true,
    }
}

// --- Utility functions ---

fn show_main_window(app: &AppHandle<Wry>) {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

pub(crate) fn open_external_url(url: &Url) {
    if let Err(error) = open_url_with_system_browser(url.as_str()) {
        eprintln!("failed to open external URL in browser: {error}");
    }
}

#[cfg(target_os = "macos")]
fn open_url_with_system_browser(url: &str) -> io::Result<()> {
    Command::new("open").arg(url).spawn().map(|_| ())
}

#[cfg(target_os = "windows")]
fn open_url_with_system_browser(url: &str) -> io::Result<()> {
    Command::new("rundll32")
        .args(["url.dll,FileProtocolHandler", url])
        .spawn()
        .map(|_| ())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn open_url_with_system_browser(url: &str) -> io::Result<()> {
    let candidates = [("xdg-open", vec![url]), ("gio", vec!["open", url])];
    let mut last_error = None;

    for (program, args) in candidates {
        match Command::new(program).args(args).spawn() {
            Ok(_) => return Ok(()),
            Err(error) => last_error = Some(error),
        }
    }

    Err(last_error.unwrap_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no URL opener found")))
}

fn download_dir(app: &AppHandle<Wry>) -> Result<PathBuf, String> {
    app.path().download_dir().or_else(|_| {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join("Downloads"))
            .ok_or_else(|| tauri::Error::UnknownPath)
    })
    .map_err(|error| format!("failed to resolve Downloads directory: {error}"))
}

fn filename_from_url(url: &Url) -> String {
    let filename = url
        .path_segments()
        .and_then(|segments| {
            segments
                .filter(|segment| !segment.is_empty())
                .next_back()
                .map(ToString::to_string)
        })
        .unwrap_or_else(|| "chatgpt-download".to_string());

    sanitize_filename(&filename)
}

fn sanitize_filename(filename: &str) -> String {
    let mut sanitized: String = filename
        .chars()
        .map(|char| {
            if char.is_control()
                || is_bidi_control_char(char)
                || matches!(char, '/' | '\\' | ':' | '"' | '*' | '?' | '<' | '>' | '|' | '\0')
            {
                '_'
            } else {
                char
            }
        })
        .collect();

    sanitized = sanitized
        .trim_matches(|char: char| char == '.' || char.is_whitespace())
        .to_string();

    if sanitized.is_empty() {
        sanitized = "chatgpt-download".to_string();
    }

    if is_windows_reserved_filename(&sanitized) {
        sanitized = format!("_{sanitized}");
    }

    if sanitized.chars().count() > 180 {
        sanitized = sanitized.chars().take(180).collect();
    }

    sanitized
}

fn is_bidi_control_char(char: char) -> bool {
    matches!(
        char,
        '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'
    )
}

fn is_windows_reserved_filename(filename: &str) -> bool {
    let stem = Path::new(filename)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or(filename)
        .trim_end_matches('.');
    let upper = stem.to_ascii_uppercase();
    matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    )
}

fn unique_download_path(downloads_dir: &Path, filename: &str) -> PathBuf {
    let filename = sanitize_filename(filename);
    let initial_path = downloads_dir.join(&filename);
    if !initial_path.exists() {
        return initial_path;
    }

    let path = Path::new(&filename);
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("chatgpt-download");
    let extension = path.extension().and_then(|extension| extension.to_str());

    for index in 1..1000 {
        let candidate = match extension {
            Some(extension) if !extension.is_empty() => {
                downloads_dir.join(format!("{stem} {index}.{extension}"))
            }
            _ => downloads_dir.join(format!("{stem} {index}")),
        };

        if !candidate.exists() {
            return candidate;
        }
    }

    downloads_dir.join(format!("{stem} {}", chrono_like_timestamp()))
}

fn chrono_like_timestamp() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_else(|_| "download".to_string())
}

fn chrono_now() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| {
            let secs = d.as_secs();
            // Simple ISO-like format
            format!("{secs}")
        })
        .unwrap_or_default()
}

fn validate_blob_download_size(size: usize) -> Result<(), String> {
    if size == 0 {
        return Err("download payload is empty".to_string());
    }
    if size > MAX_BLOB_DOWNLOAD_BYTES {
        return Err("download payload is too large".to_string());
    }
    Ok(())
}

fn ensure_trusted_command_window(window: &WebviewWindow<Wry>) -> Result<(), String> {
    let url = window
        .url()
        .map_err(|error| format!("failed to read webview URL: {error}"))?;
    if is_trusted_command_url(&url) {
        Ok(())
    } else {
        Err("native bridge is only available on ChatGPT pages".to_string())
    }
}

fn is_trusted_command_url(url: &Url) -> bool {
    if url.scheme() != "https" {
        return false;
    }

    url.host_str()
        .map(|host| is_chatgpt_host(&host.to_ascii_lowercase()))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_exported_cookie(name: &str) -> cookies::ExportedCookie {
        cookies::ExportedCookie {
            domain: ".chatgpt.com".to_string(),
            name: name.to_string(),
            value: "value".to_string(),
            path: "/".to_string(),
            secure: Some(true),
            http_only: Some(true),
            session: Some(false),
            host_only: Some(false),
            expiration_date: None,
            same_site: None,
        }
    }

    #[test]
    fn keeps_chatgpt_and_auth_flows_inside_app() {
        let urls = [
            "https://chatgpt.com/",
            "https://chat.openai.com/",
            "https://auth.openai.com/authorize",
            "https://sentinel.openai.com/sentinel/sdk.js",
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://accounts.google.com/accountchooser",
            "https://accounts.google.com/signin/v2/challenge/pwd",
            "https://accounts.google.com/signin/identifier",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://appleid.apple.com/auth/authorize",
            "https://github.com/login/oauth/authorize",
            "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/f/ov2/av0/rch/ni8ux/0x4AAAAAAADnPIDROrmt1Wwj/light/fbE/new/normal?lang=auto",
            "about:blank",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(should_stay_inside_app(&parsed), "{url}");
        }
    }

    #[test]
    fn opens_cloudflare_roots_in_app_as_challenge_recovery() {
        let urls = [
            "https://challenges.cloudflare.com/",
            "https://challenges.cloudflare.com/turnstile/v0/api.js",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(!should_stay_inside_app(&parsed), "{url}");
            assert!(should_open_in_app_root(&parsed), "{url}");
        }
    }

    #[test]
    fn opens_unrelated_external_links_outside_app() {
        let urls = [
            "https://example.com/",
            "https://help.openai.com/",
            "https://github.com/",
            "https://github.com/tw93/Pake",
            "https://accounts.google.com/ServiceLogin",
            "https://x.com/account/settings",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(!should_stay_inside_app(&parsed), "{url}");
            assert!(!should_open_in_app_root(&parsed), "{url}");
        }
    }

    #[test]
    fn blocks_unsafe_root_fallback_schemes() {
        let urls = [
            "http://chatgpt.com/",
            "about:config",
            "mailto:test@example.com",
            "file:///tmp/test.html",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(!should_stay_inside_app(&parsed), "{url}");
            assert!(!should_open_in_app_root(&parsed), "{url}");
        }
    }

    #[test]
    fn sanitizes_download_filenames() {
        assert_eq!(sanitize_filename("../a:b\\c.txt"), "_a_b_c.txt");
        assert_eq!(sanitize_filename("..."), "chatgpt-download");
        assert_eq!(sanitize_filename(" report.csv "), "report.csv");
        assert_eq!(sanitize_filename("CON.txt"), "_CON.txt");
        assert_eq!(sanitize_filename("a\u{202E}txt.exe"), "a_txt.exe");
        assert_eq!(sanitize_filename("a*?<>|.txt"), "a_____.txt");
    }

    #[test]
    fn applescript_string_literal_filters_control_boundaries() {
        assert_eq!(
            applescript_string_literal("a\"b\\c\rd\0e"),
            "\"a\\\"b\\\\cde\""
        );
    }

    #[test]
    fn native_bridge_is_limited_to_chatgpt_pages() {
        let trusted = Url::parse("https://chatgpt.com/c/123").expect("test URL should parse");
        let auth_page =
            Url::parse("https://accounts.google.com/o/oauth2/v2/auth").expect("test URL should parse");
        let external = Url::parse("https://example.com/").expect("test URL should parse");

        assert!(is_trusted_command_url(&trusted));
        assert!(!is_trusted_command_url(&auth_page));
        assert!(!is_trusted_command_url(&external));
    }

    #[test]
    fn validates_blob_download_size_limits() {
        assert!(validate_blob_download_size(1).is_ok());
        assert!(validate_blob_download_size(MAX_BLOB_DOWNLOAD_BYTES).is_ok());
        assert!(validate_blob_download_size(0).is_err());
        assert!(validate_blob_download_size(MAX_BLOB_DOWNLOAD_BYTES + 1).is_err());
    }

    #[test]
    fn clamps_webview_zoom_to_supported_range() {
        assert_eq!(clamp_webview_zoom(0.5), MIN_WEBVIEW_ZOOM);
        assert_eq!(clamp_webview_zoom(2.0), MAX_WEBVIEW_ZOOM);
        assert_eq!(clamp_webview_zoom(f64::NAN), 1.0);
    }

    #[test]
    fn menu_zoom_persists_to_webview_zoom_storage_key() {
        let script = webview_zoom_persistence_script(1.2);
        assert!(script.contains(WEBVIEW_ZOOM_STORAGE_KEY));
        assert!(script.contains("1.20"));
        assert!(CHATGPT_WEBVIEW_SCRIPT.contains(WEBVIEW_ZOOM_STORAGE_KEY));
    }

    #[test]
    fn chatgpt_cookie_header_estimate_ignores_unrelated_domains() {
        let cookies = vec![
            tauri::webview::cookie::Cookie::build(("sid", "x".repeat(10)))
                .domain(".chatgpt.com")
                .path("/")
                .build(),
            tauri::webview::cookie::Cookie::build(("external", "x".repeat(10_000)))
                .domain(".example.com")
                .path("/")
                .build(),
        ];
        assert_eq!(approximate_chatgpt_cookie_header_bytes(&cookies), 15);
    }

    #[test]
    fn chatgpt_cookie_domain_matching_uses_boundaries() {
        assert!(cookie_domain_is_chatgpt_related(".chatgpt.com"));
        assert!(cookie_domain_is_chatgpt_related("openai.com"));
        assert!(cookie_domain_is_chatgpt_related("platform.openai.com"));
        assert!(cookie_domain_is_chatgpt_related("auth.openai.com"));
        assert!(!cookie_domain_is_chatgpt_related("evilchatgpt.com"));
        assert!(!cookie_domain_is_chatgpt_related("openai.com.evil.test"));
    }

    #[test]
    fn cookie_import_filter_keeps_only_chatgpt_login_essentials() {
        let (filtered, skipped_count) = filter_essential_chatgpt_import_cookies(vec![
            test_exported_cookie("consent"),
            test_exported_cookie("__Secure-next-auth.session-token"),
            test_exported_cookie("cf_clearance"),
            test_exported_cookie("__Host-next-auth.csrf-token"),
        ]);

        let names: Vec<String> = filtered.into_iter().map(|cookie| cookie.name).collect();
        assert_eq!(
            names,
            vec![
                "__Secure-next-auth.session-token".to_string(),
                "cf_clearance".to_string()
            ]
        );
        assert_eq!(skipped_count, 2);
    }

    #[test]
    fn webview_script_keeps_hot_click_path_narrow() {
        assert!(CHATGPT_WEBVIEW_SCRIPT.contains("revokeObjectURL"));
        assert!(CHATGPT_WEBVIEW_SCRIPT.contains(r#"a[href^="blob:"],a[href^="data:"]"#));
        assert!(CHATGPT_WEBVIEW_SCRIPT.contains("installStopTooltipGuard"));
        assert!(CHATGPT_WEBVIEW_SCRIPT.contains("showDownloadNotice"));
        assert!(!CHATGPT_WEBVIEW_SCRIPT.contains(r#"event.key === "Process""#));
    }

}
