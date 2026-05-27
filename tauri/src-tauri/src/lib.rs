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
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
};

use tauri::{
    webview::DownloadEvent,
    AppHandle, Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
    WindowEvent, Wry,
};
use tauri_plugin_window_state::{Builder as WindowStateBuilder, StateFlags};
use uuid::Uuid;

use browser::{BrowserState, MAIN_WINDOW_LABEL};
use profile::{ProfileExportDocument, ProfileStore};

const CHATGPT_WEBVIEW_SCRIPT: &str = include_str!("chatgpt_webview.js");
const MAX_BLOB_DOWNLOAD_BYTES: usize = 200 * 1024 * 1024;
const MIN_WEBVIEW_ZOOM: f64 = 0.85;
const MAX_WEBVIEW_ZOOM: f64 = 1.40;
static BLOB_DOWNLOAD_COUNTER: AtomicUsize = AtomicUsize::new(0);

const MENU_CREATE_PROFILE: &str = "create_profile";
const MENU_CLONE_PROFILE: &str = "clone_profile";
const MENU_RENAME_PROFILE: &str = "rename_profile";
const MENU_DELETE_PROFILE: &str = "delete_profile";
const MENU_SET_HOMEPAGE: &str = "set_homepage";
const MENU_IMPORT_PROFILE: &str = "import_profile";
const MENU_IMPORT_COOKIES: &str = "import_cookies";
const MENU_EXPORT_COOKIES: &str = "export_cookies";
const MENU_BURN_CURRENT_PROFILE: &str = "burn_current_profile";

// --- Download session management ---

#[derive(Default)]
struct BlobDownloadSessions(Mutex<HashMap<String, BlobDownloadSession>>);

struct BlobDownloadSession {
    path: PathBuf,
    expected_size: usize,
    bytes_written: usize,
}

/// One-time tokens minted by native menu handlers for sensitive commands.
/// Remote ChatGPT pages may invoke these commands, but only immediately after
/// a user menu gesture has minted the matching action token.
#[derive(Default)]
struct MenuCommandTokens(Mutex<HashMap<String, &'static str>>);

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

    let session_id = format!(
        "{}-{}",
        std::process::id(),
        BLOB_DOWNLOAD_COUNTER.fetch_add(1, Ordering::Relaxed) + 1
    );
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

    let clamped = scale.clamp(MIN_WEBVIEW_ZOOM, MAX_WEBVIEW_ZOOM);
    window
        .set_zoom(clamped)
        .map_err(|error| format!("failed to set native webview zoom: {error}"))?;
    Ok(clamped)
}

// --- Menu event handler ---

fn handle_menu_event(app: &AppHandle<Wry>, event: tauri::menu::MenuEvent) {
    let id = event.id().as_ref();

    // Profile switching
    if let Some(profile_id) = menu::extract_profile_id(id) {
        let profile_store = app.state::<ProfileStore>();
        if profile_store.current_profile_id() == profile_id {
            return; // Already on this profile
        }
        if let Err(e) = profile_store.switch_profile(profile_id) {
            eprintln!("failed to switch profile: {e}");
            return;
        }
        if let Err(e) = browser::rebuild_main_window(app, &profile_store, None) {
            eprintln!("failed to rebuild main window: {e}");
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
        let _ = profile_store.set_meta(&current_id, &meta);
        let current_url = app
            .get_webview_window(MAIN_WINDOW_LABEL)
            .and_then(|w| w.url().ok())
            .map(|u| u.to_string());
        let _ = browser::rebuild_main_window(app, &profile_store, current_url);
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
            let profile = profile_store.current_profile();
            let homepage = profile_store.homepage_url(&profile.id);
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(url) = Url::parse(&homepage) {
                    let _ = w.navigate(url);
                }
            }
        }
        menu::event_id::NAV_RELOAD => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval("location.reload()");
            }
        }
        menu::event_id::ZOOM_IN => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval(
                    r#"
                    try {
                      const step = 0.05;
                      const current = parseFloat(localStorage.getItem('chatgptWebviewZoom') || '1');
                      const next = Math.min(1.4, current + step);
                      localStorage.setItem('chatgptWebviewZoom', String(next));
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('set_native_webview_zoom', { scale: next });
                      }
                    } catch (_) {}
                    "#,
                );
            }
        }
        menu::event_id::ZOOM_OUT => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval(
                    r#"
                    try {
                      const step = 0.05;
                      const current = parseFloat(localStorage.getItem('chatgptWebviewZoom') || '1');
                      const next = Math.max(0.85, current - step);
                      localStorage.setItem('chatgptWebviewZoom', String(next));
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('set_native_webview_zoom', { scale: next });
                      }
                    } catch (_) {}
                    "#,
                );
            }
        }
        menu::event_id::ZOOM_RESET => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval(
                    r#"
                    try {
                      localStorage.removeItem('chatgptWebviewZoom');
                      localStorage.removeItem('htmlZoom');
                      document.documentElement.style.zoom = '';
                      if (document.body) document.body.style.zoom = '';
                      window.dispatchEvent(new Event('resize'));
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('set_native_webview_zoom', { scale: 1.0 });
                      }
                    } catch (_) {}
                    "#,
                );
            }
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
                let _ = w.eval(&format!(
                    "document.open(); document.write({}); document.close();",
                    serde_json::to_string(&html).unwrap_or_default()
                ));
            }
        }
        menu::event_id::TOGGLE_WEBRTC => {
            // Toggle WebRTC protection and rebuild
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.webrtc_enabled = !meta.webrtc_enabled;
            let _ = profile_store.set_meta(&current_id, &meta);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            let _ = browser::rebuild_main_window(app, &profile_store, current_url);
        }
        menu::event_id::PRIVACY_STATUS => {
            // Show privacy status dialog via JS alert
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
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let escaped = msg.replace('\\', "\\\\").replace('\'', "\\'").replace('\n', "\\n");
                let _ = w.eval(&format!("alert('{escaped}')"));
            }
        }
        menu::event_id::FP_RANDOMIZE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.fingerprint = Some(fingerprint::random_fingerprint());
            meta.fingerprint_disabled = false;
            let _ = profile_store.set_meta(&current_id, &meta);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            let _ = browser::rebuild_main_window(app, &profile_store, current_url);
        }
        menu::event_id::FP_ABOUT => {
            let msg = "能加强：每个空间固定一套指纹，覆盖 UA、navigator、screen、Canvas、WebGL、AudioContext 等。\n\n挡不住：TLS 指纹、HTTP/2 帧顺序、Worker/字体/GPU/IP/行为模式。\n\n本 App 只做一致性隐私指纹，不做跨引擎伪装。";
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let escaped = msg.replace('\\', "\\\\").replace('\'', "\\'").replace('\n', "\\n");
                let _ = w.eval(&format!("alert('{escaped}')"));
            }
        }
        menu::event_id::TOGGLE_ENHANCED_PRIVACY => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let mut meta = profile_store.get_meta(&current_id);
            meta.enhanced_privacy = !meta.enhanced_privacy;
            let _ = profile_store.set_meta(&current_id, &meta);
            let current_url = app
                .get_webview_window(MAIN_WINDOW_LABEL)
                .and_then(|w| w.url().ok())
                .map(|u| u.to_string());
            let _ = browser::rebuild_main_window(app, &profile_store, current_url);
        }
        menu::event_id::GO_TO_URL => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = w.eval(
                    r#"
                    (() => {
                      const raw = prompt('前往网址\n输入 https:// 开头的网址：', location.href);
                      if (!raw) return;
                      const trimmed = raw.trim();
                      if (!trimmed.startsWith('https://')) {
                        alert('仅支持 https:// 网址');
                        return;
                      }
                      try {
                        const url = new URL(trimmed);
                        if (url.hostname) location.href = trimmed;
                      } catch (_) {
                        alert('网址无效');
                      }
                    })()
                    "#,
                );
            }
        }
        menu::event_id::ADD_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_CREATE_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const name = prompt('新建账号空间\n输入空间名称：');
                      if (!name || !name.trim()) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_create_profile', { token, name: name.trim() });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::CLONE_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_CLONE_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const name = prompt('克隆当前空间\n输入新空间名称（留空自动生成）：');
                      if (name === null) return;
                      const copyCookies = confirm('是否同时复制 cookies？\n\n选"确定"会复制当前空间的 cookies 到新空间。');
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_clone_profile', { token, name: name.trim(), copyCookies });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::RENAME_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_RENAME_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const name = prompt('重命名当前空间\n输入新名称：');
                      if (!name || !name.trim()) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_rename_profile', { token, name: name.trim() });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::DELETE_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_DELETE_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      if (!confirm('删除当前空间？\n本空间的所有 cookie、登录态、缓存将被永久删除。其他空间不受影响。')) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_delete_profile', { token });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::SET_HOMEPAGE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_SET_HOMEPAGE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const url = prompt('设置当前空间首页\n输入 https:// 网址：', location.href);
                      if (url === null) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_set_homepage', { token, url: url.trim() });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::RESET_HOMEPAGE => {
            let profile_store = app.state::<ProfileStore>();
            let current_id = profile_store.current_profile_id();
            let _ = profile_store.set_homepage(&current_id, "");
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let homepage = profile_store.homepage_url(&current_id);
                if let Ok(url) = Url::parse(&homepage) {
                    let _ = w.navigate(url);
                }
            }
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
            };
            match serde_json::to_string_pretty(&doc) {
                Ok(json) => {
                    // Copy to clipboard using native API
                    match arboard::Clipboard::new() {
                        Ok(mut clipboard) => {
                            if let Err(e) = clipboard.set_text(&json) {
                                eprintln!("failed to write to clipboard: {e}");
                            }
                        }
                        Err(e) => eprintln!("failed to access clipboard: {e}"),
                    }
                }
                Err(e) => eprintln!("export failed: {e}"),
            }
        }
        menu::event_id::IMPORT_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_IMPORT_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const json = prompt('导入空间配置\n粘贴之前导出的 JSON：');
                      if (!json) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_import_profile', { token, json });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::IMPORT_COOKIES => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_IMPORT_COOKIES) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      const json = prompt('导入 Cookies\n支持 JSON、Netscape cookies.txt、Cookie/Header String。请粘贴内容：');
                      if (!json) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_import_cookies', { token, json });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::EXPORT_COOKIES => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_EXPORT_COOKIES) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_export_cookies', { token });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
            }
        }
        menu::event_id::BURN_CURRENT_PROFILE => {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(token) = mint_menu_token(app, MENU_BURN_CURRENT_PROFILE) {
                    let script = menu_token_script(
                        r#"
                    (() => {
                      const token = __MENU_TOKEN__;
                      if (!confirm('焚烧当前空间？\n\n会删除当前空间所有 cookies、缓存、localStorage、IndexedDB、Service Worker 等网站数据，关闭弹窗，清空页面历史，重建浏览器视图，并重新随机化指纹。\n\n保留：空间名称、首页、增强隐私设置。其他空间不受影响。')) return;
                      if (window.__TAURI__ && window.__TAURI__.core) {
                        window.__TAURI__.core.invoke('cmd_burn_current_profile', { token });
                      }
                    })()
                    "#,
                        &token,
                    );
                    let _ = w.eval(&script);
                }
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
            let result = WebviewWindowBuilder::new(
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
            .on_navigation(move |url| handle_navigation(&app_for_nav, url))
            .on_download(move |_webview, event| handle_download_event(&app_for_download, event))
            .initialization_script(privacy::NATIVE_SHIM_SCRIPT)
            .initialization_script(privacy::PRIVACY_SIGNALS_SCRIPT)
            .initialization_script(CHATGPT_WEBVIEW_SCRIPT)
            .build();
            if let Ok(window) = result {
                let _ = window.navigate(Url::parse("https://chatgpt.com/").unwrap());
            }
        }
        _ => {
            eprintln!("unhandled menu event: {id}");
        }
    }
}

// --- Tauri commands for JS-invoked operations ---

#[tauri::command]
fn cmd_create_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    name: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_CREATE_PROFILE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let profile = profile_store.create_profile(&name)?;
    profile_store.switch_profile(&profile.id)?;
    let menu = menu::build_app_menu(&app, &profile_store);
    app.set_menu(menu).map_err(|e| e.to_string())?;
    browser::rebuild_main_window(&app, &profile_store, None)?;
    Ok(())
}

/// In-memory storage for cookies pending injection during profile clone.
/// Avoids writing session cookies to disk.
#[derive(Default)]
struct PendingCookies(Mutex<Option<Vec<serde_json::Value>>>);

#[tauri::command]
fn cmd_clone_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    name: String,
    copy_cookies: bool,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_CLONE_PROFILE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();
    let (profile, _source_meta) = profile_store.clone_profile(&current_id, &name)?;

    // Optionally copy cookies from source profile using native API
    if copy_cookies {
        if let Some(source_window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
            match source_window.cookies() {
                Ok(cookies) => {
                    // Store cookies in memory for later injection
                    let cookie_values: Vec<serde_json::Value> = cookies.iter().map(|c| {
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
                    }).collect();

                    let state = app.state::<PendingCookies>();
                    let mut pending = state.0.lock().map_err(|_| "lock poisoned".to_string())?;
                    *pending = Some(cookie_values);
                }
                Err(e) => eprintln!("failed to read source cookies: {e}"),
            }
        }
    }

    profile_store.switch_profile(&profile.id)?;
    let menu = menu::build_app_menu(&app, &profile_store);
    app.set_menu(menu).map_err(|e| e.to_string())?;
    browser::rebuild_main_window(&app, &profile_store, None)?;

    // If cookies were copied, inject them into the new WebView from memory
    if copy_cookies {
        let cookie_values = {
            let state = app.state::<PendingCookies>();
            let mut pending = state.0.lock().map_err(|_| "lock poisoned".to_string())?;
            pending.take()
        };

        if let Some(values) = cookie_values {
            if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                for cv in &values {
                    let name = cv["name"].as_str().unwrap_or("");
                    let value = cv["value"].as_str().unwrap_or("");
                    let domain = cv["domain"].as_str().unwrap_or("");
                    let path = cv["path"].as_str().unwrap_or("/");
                    let secure = cv["secure"].as_bool().unwrap_or(false);
                    let http_only = cv["http_only"].as_bool().unwrap_or(false);
                    let host_only = cv["host_only"].as_bool().unwrap_or(false);

                    let url_domain = domain.strip_prefix('.').unwrap_or(domain);
                    let scheme = if secure { "https" } else { "http" };
                    let url_str = format!("{scheme}://{url_domain}{path}");
                    if tauri::Url::parse(&url_str).is_ok() {
                        let mut cookie = build_webview_cookie(
                            name,
                            value,
                            domain,
                            path,
                            secure,
                            http_only,
                            host_only,
                        );
                        if let Some(expires) = cv["expires"].as_f64() {
                            if expires > 0.0 {
                                use tauri::webview::cookie::time;
                                if let Ok(dt) = time::OffsetDateTime::from_unix_timestamp(expires as i64) {
                                    cookie = cookie.expires(dt);
                                }
                            }
                        }
                        let _ = w.set_cookie(cookie.build());
                    }
                }
            }
        }
    }

    Ok(())
}

#[tauri::command]
fn cmd_rename_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    name: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_RENAME_PROFILE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();

    // Cannot rename the default profile
    if current_id == profile::DEFAULT_PROFILE_ID {
        return Err("cannot rename the default profile".to_string());
    }

    profile_store.rename_profile(&current_id, &name)?;
    let menu = menu::build_app_menu(&app, &profile_store);
    app.set_menu(menu).map_err(|e| e.to_string())?;
    // Update window title
    if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let title = browser::main_window_title(&name, &current_id);
        let _ = w.set_title(&title);
    }
    Ok(())
}

#[tauri::command]
async fn cmd_delete_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_DELETE_PROFILE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();

    // Cannot delete the default profile
    if current_id == profile::DEFAULT_PROFILE_ID {
        return Err("cannot delete the default profile".to_string());
    }

    // Step 1: Destroy main window and auth popups to release the data store
    browser::close_auth_popups(&app);
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        window
            .destroy()
            .map_err(|e| format!("failed to destroy main window: {e}"))?;
    }

    // Step 2: On macOS, remove the WKWebsiteDataStore now that no window uses it
    #[cfg(target_os = "macos")]
    {
        if let Some(uuid_bytes) = browser::profile_id_to_uuid_bytes(&current_id) {
            if let Err(e) = app.remove_data_store(uuid_bytes).await {
                eprintln!("failed to remove data store for profile '{current_id}': {e}");
            }
        }
    }

    // Step 3: Delete profile metadata
    profile_store.delete_profile(&current_id)?;

    // Step 4: Rebuild menu and default window
    let menu = menu::build_app_menu(&app, &profile_store);
    app.set_menu(menu).map_err(|e| e.to_string())?;
    browser::rebuild_main_window(&app, &profile_store, None)?;
    Ok(())
}

#[tauri::command]
fn cmd_set_homepage(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    url: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_SET_HOMEPAGE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();
    profile_store.set_homepage(&current_id, &url)?;
    Ok(())
}

#[tauri::command]
fn cmd_import_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    json: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_IMPORT_PROFILE, &token)?;
    let doc: ProfileExportDocument =
        serde_json::from_str(&json).map_err(|e| format!("JSON 解析失败: {e}"))?;
    if doc.schema_version != 1 {
        return Err("Profile JSON 版本不支持".to_string());
    }

    let profile_store = app.state::<ProfileStore>();
    let name = if doc.name.trim().is_empty() {
        "导入空间".to_string()
    } else {
        doc.name.clone()
    };
    let profile = profile_store.create_profile(&name)?;

    if let Some(ref homepage) = doc.homepage {
        if homepage.starts_with("https://") {
            let _ = profile_store.set_homepage(&profile.id, homepage);
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
    let _ = profile_store.set_meta(&profile.id, &meta);

    profile_store.switch_profile(&profile.id)?;
    let menu = menu::build_app_menu(&app, &profile_store);
    app.set_menu(menu).map_err(|e| e.to_string())?;
    browser::rebuild_main_window(&app, &profile_store, None)?;
    Ok(())
}

#[tauri::command]
fn cmd_import_cookies(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
    json: String,
) -> Result<String, String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_IMPORT_COOKIES, &token)?;
    let cookies = cookies::parse_cookie_import(&json)?;
    let count = cookies.len();

    for c in &cookies {
        let domain = c.domain.trim();
        let name = c.name.trim();
        let path = if c.path.is_empty() { "/" } else { &c.path };
        let secure = c.secure.unwrap_or(false);
        let http_only = c.http_only.unwrap_or(false);
        let host_only = c.host_only.unwrap_or(false);

        let mut cookie = build_webview_cookie(
            name,
            c.value.as_str(),
            domain,
            path,
            secure,
            http_only,
            host_only,
        );

        // Set same_site
        cookie = match c.same_site.as_deref() {
            Some("lax") => cookie.same_site(tauri::webview::cookie::SameSite::Lax),
            Some("strict") => cookie.same_site(tauri::webview::cookie::SameSite::Strict),
            Some("none") | Some("no_restriction") => {
                cookie.same_site(tauri::webview::cookie::SameSite::None)
            }
            _ => cookie,
        };

        // Set expiration
        if c.session != Some(true) {
            if let Some(exp) = c.expiration_date {
                use tauri::webview::cookie::time;
                if let Ok(dt) = time::OffsetDateTime::from_unix_timestamp(exp as i64) {
                    cookie = cookie.expires(dt);
                }
            }
        }

        window
            .set_cookie(cookie.build())
            .map_err(|e| format!("failed to set cookie '{}': {e}", c.name))?;
    }

    // Reload to pick up new cookies
    let _ = window.eval("location.reload()");

    Ok(format!("已导入 {count} 个 cookie"))
}

#[tauri::command]
fn cmd_export_cookies(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
) -> Result<String, String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_EXPORT_COOKIES, &token)?;
    // Use native cookie API to read all cookies (including HttpOnly)
    let cookies = window
        .cookies()
        .map_err(|e| format!("failed to read cookies: {e}"))?;

    if cookies.is_empty() {
        return Err("当前空间没有可导出的 cookie".to_string());
    }

    // Convert to our export format
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

    let json = serde_json::to_string_pretty(&exported)
        .map_err(|e| format!("JSON 序列化失败: {e}"))?;

    // Copy to clipboard using native API (no JS injection back into page)
    let count = cookies.len();
    let mut clipboard = arboard::Clipboard::new()
        .map_err(|e| format!("failed to access clipboard: {e}"))?;
    clipboard
        .set_text(&json)
        .map_err(|e| format!("failed to write to clipboard: {e}"))?;

    Ok(format!("已复制 {count} 个 cookie 到剪贴板（含 HttpOnly）"))
}

#[tauri::command]
fn cmd_burn_current_profile(
    app: AppHandle<Wry>,
    window: WebviewWindow<Wry>,
    token: String,
) -> Result<(), String> {
    ensure_trusted_command_window(&window)?;
    consume_menu_token(&app, MENU_BURN_CURRENT_PROFILE, &token)?;
    let profile_store = app.state::<ProfileStore>();
    let current_id = profile_store.current_profile_id();

    // Use native API to clear all browsing data (cookies, cache, localStorage, etc.)
    if let Some(w) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        // Clear native browsing data first (cookies, cache, Service Workers, etc.)
        if let Err(e) = w.clear_all_browsing_data() {
            eprintln!("failed to clear browsing data: {e}");
        }

        // Also clear JS-accessible storage as a belt-and-suspenders measure
        let _ = w.eval(
            r#"
            try {
              localStorage.clear();
              sessionStorage.clear();
            } catch (_) {}
            "#,
        );
    }

    // Close auth popups
    browser::close_auth_popups(&app);

    // Re-randomize fingerprint
    let mut meta = profile_store.get_meta(&current_id);
    meta.fingerprint = Some(fingerprint::random_fingerprint());
    meta.fingerprint_disabled = false;
    let _ = profile_store.set_meta(&current_id, &meta);

    // Rebuild with homepage
    let homepage = profile_store.homepage_url(&current_id);
    browser::rebuild_main_window(&app, &profile_store, Some(homepage))?;

    Ok(())
}

fn mint_menu_token(app: &AppHandle<Wry>, action: &'static str) -> Result<String, String> {
    let token = format!("{action}:{}", Uuid::new_v4());
    let state = app.state::<MenuCommandTokens>();
    let mut tokens = state
        .0
        .lock()
        .map_err(|_| "menu token lock is poisoned".to_string())?;
    insert_menu_token(&mut tokens, &token, action);
    Ok(token)
}

fn consume_menu_token(app: &AppHandle<Wry>, action: &'static str, token: &str) -> Result<(), String> {
    let state = app.state::<MenuCommandTokens>();
    let mut tokens = state
        .0
        .lock()
        .map_err(|_| "menu token lock is poisoned".to_string())?;

    consume_menu_token_from_map(&mut tokens, action, token)
}

fn insert_menu_token(tokens: &mut HashMap<String, &'static str>, token: &str, action: &'static str) {
    tokens.insert(token.to_string(), action);
}

fn consume_menu_token_from_map(
    tokens: &mut HashMap<String, &'static str>,
    action: &'static str,
    token: &str,
) -> Result<(), String> {
    match tokens.remove(token) {
        Some(stored_action) if stored_action == action => Ok(()),
        Some(_) => Err("menu command token does not match this action".to_string()),
        None => Err("sensitive command requires a fresh native menu token".to_string()),
    }
}

fn menu_token_script(script: &str, token: &str) -> String {
    let token = serde_json::to_string(token).unwrap_or_else(|_| "\"\"".to_string());
    script.replace("__MENU_TOKEN__", &token)
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
        .manage(MenuCommandTokens::default())
        .invoke_handler(tauri::generate_handler![
            start_blob_download,
            append_blob_download,
            finish_blob_download,
            cancel_blob_download,
            set_native_webview_zoom,
            cmd_create_profile,
            cmd_clone_profile,
            cmd_rename_profile,
            cmd_delete_profile,
            cmd_set_homepage,
            cmd_import_profile,
            cmd_import_cookies,
            cmd_export_cookies,
            cmd_burn_current_profile,
        ])
        .setup(move |app| {
            // Initialize profile store
            let app_data_dir = app
                .path()
                .app_data_dir()
                .expect("failed to resolve app data directory — cannot start without it");

            let profile_store = ProfileStore::new(&app_data_dir)
                .expect("failed to initialize profile store");

            // Build and set menu
            let app_menu = menu::build_app_menu(app.handle(), &profile_store);
            app.set_menu(app_menu)?;

            // Build main window
            let _main_window = browser::build_main_window(app.handle(), &profile_store)
                .expect("failed to build main window");

            // Store profile store in managed state
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
            if let RunEvent::Reopen {
                has_visible_windows,
                ..
            } = event
            {
                if !has_visible_windows {
                    show_main_window(app);
                }
            }
        });
}

// --- Navigation and URL routing ---

fn handle_navigation(app: &AppHandle<Wry>, url: &Url) -> bool {
    if should_stay_inside_app(url) {
        return true;
    }

    open_external_url(url);
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        let _ = window.set_focus();
    }
    false
}

fn should_stay_inside_app(url: &Url) -> bool {
    match url.scheme() {
        "https" => {}
        "about" | "blob" | "data" => return true,
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

    if is_chatgpt_host(&host) || is_openai_auth_host(&host) || is_oauth_host(&host, url.path()) {
        return true;
    }

    false
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

fn is_oauth_host(host: &str, path: &str) -> bool {
    let path = path.to_ascii_lowercase();
    let path = path.trim_end_matches('/');

    match host {
        "accounts.google.com" => path.starts_with("/o/oauth2/")
            || path == "/signin/oauth"
            || path.starts_with("/signin/oauth/"),
        host if host.starts_with("accounts.google.") => {
            path.starts_with("/o/oauth2/") || path.starts_with("/signin/oauth")
        }
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

fn open_external_url(url: &Url) {
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
    Command::new("cmd")
        .args(["/C", "start", "", url])
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
            if char.is_control() || matches!(char, '/' | '\\' | ':' | '\0') {
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

    if sanitized.chars().count() > 180 {
        sanitized = sanitized.chars().take(180).collect();
    }

    sanitized
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

    #[test]
    fn keeps_chatgpt_and_auth_flows_inside_app() {
        let urls = [
            "https://chatgpt.com/",
            "https://chat.openai.com/",
            "https://auth.openai.com/authorize",
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            "https://appleid.apple.com/auth/authorize",
            "https://github.com/login/oauth/authorize",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(should_stay_inside_app(&parsed), "{url}");
        }
    }

    #[test]
    fn opens_unrelated_external_links_outside_app() {
        let urls = [
            "https://example.com/",
            "https://help.openai.com/",
            "http://chatgpt.com/",
            "https://github.com/",
            "https://github.com/tw93/Pake",
            "https://accounts.google.com/accountchooser",
            "https://accounts.google.com/signin/v2/challenge/pwd",
            "https://x.com/account/settings",
        ];

        for url in urls {
            let parsed = Url::parse(url).expect("test URL should parse");
            assert!(!should_stay_inside_app(&parsed), "{url}");
        }
    }

    #[test]
    fn sanitizes_download_filenames() {
        assert_eq!(sanitize_filename("../a:b\\c.txt"), "_a_b_c.txt");
        assert_eq!(sanitize_filename("..."), "chatgpt-download");
        assert_eq!(sanitize_filename(" report.csv "), "report.csv");
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
    fn menu_tokens_are_one_time_and_action_bound() {
        let mut tokens = HashMap::new();

        insert_menu_token(&mut tokens, "token-1", MENU_EXPORT_COOKIES);
        assert!(consume_menu_token_from_map(&mut tokens, MENU_IMPORT_COOKIES, "token-1").is_err());
        assert!(consume_menu_token_from_map(&mut tokens, MENU_EXPORT_COOKIES, "token-1").is_err());

        insert_menu_token(&mut tokens, "token-2", MENU_EXPORT_COOKIES);
        assert!(consume_menu_token_from_map(&mut tokens, MENU_EXPORT_COOKIES, "token-2").is_ok());
        assert!(consume_menu_token_from_map(&mut tokens, MENU_EXPORT_COOKIES, "token-2").is_err());
    }

    #[test]
    fn menu_token_script_escapes_token_as_js_literal() {
        let script = menu_token_script("const token = __MENU_TOKEN__;", "a\"b\\c");
        assert_eq!(script, r#"const token = "a\"b\\c";"#);
    }
}
