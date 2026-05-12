use std::{
    fs,
    io,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
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

#[tauri::command]
fn save_blob_download(
    app: AppHandle<Wry>,
    filename: String,
    bytes: Vec<u8>,
) -> Result<String, String> {
    if bytes.is_empty() {
        return Err("download payload is empty".to_string());
    }

    if bytes.len() > MAX_BLOB_DOWNLOAD_BYTES {
        return Err("download payload is too large".to_string());
    }

    let downloads_dir = download_dir(&app)?;
    fs::create_dir_all(&downloads_dir)
        .map_err(|error| format!("failed to create Downloads directory: {error}"))?;

    let output_path = unique_download_path(&downloads_dir, &sanitize_filename(&filename));
    fs::write(&output_path, bytes)
        .map_err(|error| format!("failed to write download file: {error}"))?;

    Ok(output_path.to_string_lossy().into_owned())
}

#[tauri::command]
fn set_native_webview_zoom(window: WebviewWindow<Wry>, scale: f64) -> Result<f64, String> {
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
        .invoke_handler(tauri::generate_handler![
            save_blob_download,
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
        "http" | "https" => {}
        "about" | "blob" | "data" => return true,
        _ => return false,
    }

    let Some(host) = url.host_str().map(|host| host.to_ascii_lowercase()) else {
        return false;
    };

    if is_chatgpt_host(&host) || is_openai_auth_host(&host) || is_oauth_host(&host, url.path()) {
        return true;
    }

    host == "localhost" || host == "127.0.0.1"
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
    let known_provider = host == "accounts.google.com"
        || host.starts_with("accounts.google.")
        || host == "login.microsoftonline.com"
        || host == "login.live.com"
        || host == "appleid.apple.com"
        || host == "github.com"
        || host == "facebook.com"
        || host.ends_with(".facebook.com")
        || host == "twitter.com"
        || host == "x.com";

    if !known_provider {
        return false;
    }

    let path = path.to_ascii_lowercase();
    path.contains("oauth")
        || path.contains("auth")
        || path.contains("authorize")
        || path.contains("login")
        || path.contains("signin")
        || path == "/"
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
            "https://github.com/tw93/Pake",
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
}
