use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    process::Command,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex,
    },
};

use tauri::{
    webview::{DownloadEvent, NewWindowFeatures, NewWindowResponse},
    AppHandle, Manager, RunEvent, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
    WindowEvent, Wry,
};
use tauri_plugin_window_state::{Builder as WindowStateBuilder, StateFlags};

const MAIN_WINDOW_LABEL: &str = "main";
const CHATGPT_WEBVIEW_SCRIPT: &str = include_str!("chatgpt_webview.js");
const MAX_BLOB_DOWNLOAD_BYTES: usize = 200 * 1024 * 1024;
const MIN_WEBVIEW_ZOOM: f64 = 0.85;
const MAX_WEBVIEW_ZOOM: f64 = 1.40;
static BLOB_DOWNLOAD_COUNTER: AtomicUsize = AtomicUsize::new(0);

#[derive(Default)]
struct BlobDownloadSessions(Mutex<HashMap<String, BlobDownloadSession>>);

struct BlobDownloadSession {
    path: PathBuf,
    expected_size: usize,
    bytes_written: usize,
}

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

pub fn run() {
    let popup_counter = Arc::new(AtomicUsize::new(0));
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
        .invoke_handler(tauri::generate_handler![
            start_blob_download,
            append_blob_download,
            finish_blob_download,
            cancel_blob_download,
            set_native_webview_zoom
        ])
        .setup(move |app| {
            let window_config = app
                .config()
                .app
                .windows
                .iter()
                .find(|window| window.label == MAIN_WINDOW_LABEL)
                .expect("missing main window configuration");

            let app_for_navigation = app.handle().clone();
            let app_for_download = app.handle().clone();
            let app_for_popup = app.handle().clone();
            let popup_counter = Arc::clone(&popup_counter);

            WebviewWindowBuilder::from_config(app.handle(), window_config)?
                .on_navigation(move |url| handle_navigation(&app_for_navigation, url))
                .on_new_window(move |target_url, features| {
                    handle_new_window(&app_for_popup, &popup_counter, target_url, features)
                })
                .on_download(move |_webview, event| handle_download_event(&app_for_download, event))
                .initialization_script(CHATGPT_WEBVIEW_SCRIPT)
                .build()?;

            Ok(())
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

fn handle_new_window(
    app: &AppHandle<Wry>,
    popup_counter: &AtomicUsize,
    target_url: Url,
    features: NewWindowFeatures,
) -> NewWindowResponse<Wry> {
    if !should_stay_inside_app(&target_url) {
        open_external_url(&target_url);
        return NewWindowResponse::Deny;
    }

    let label = format!(
        "auth-{}",
        popup_counter.fetch_add(1, Ordering::Relaxed) + 1
    );
    let title = target_url
        .host_str()
        .map_or_else(|| "ChatGPT Login".to_string(), ToString::to_string);
    let app_for_navigation = app.clone();
    let app_for_download = app.clone();

    match WebviewWindowBuilder::new(
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
    .window_features(features)
    .on_navigation(move |url| handle_navigation(&app_for_navigation, url))
    .on_download(move |_webview, event| handle_download_event(&app_for_download, event))
    .build()
    {
        Ok(window) => NewWindowResponse::Create { window },
        Err(error) => {
            eprintln!("failed to create managed auth window: {error}");
            NewWindowResponse::Deny
        }
    }
}

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
        let auth_page = Url::parse("https://accounts.google.com/o/oauth2/v2/auth").expect("test URL should parse");
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
}
