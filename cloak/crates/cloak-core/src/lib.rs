mod relay;

use rand::Rng;
use regex::Regex;
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io;
use std::io::Cursor;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream as StdTcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use url::Url;
use walkdir::WalkDir;

const CHATGPT_URL: &str = "https://chatgpt.com/";
const RELAY_PLACEHOLDER: &str = "socks5://127.0.0.1:<relay-port>";
const CLOAK_CHROME_MAJOR_FALLBACK: &str = "145";
const CLOAK_MAC_UA_VERSION: &str = "10_15_7";
const CLOAK_MAC_PLATFORM_VERSION: &str = "15.5.0";

/// Apple Silicon GPU renderer pool — base chips only, coherent with 8-core hardwareConcurrency.
/// Pro/Max/Ultra variants excluded to avoid "M4 Max + 8 cores" inconsistency.
/// Format is the exact ANGLE/Metal string a real Apple-Silicon Chrome reports via
/// UNMASKED_RENDERER_WEBGL (verified against the live binary). Apple Silicon always
/// uses the Metal backend, never OpenGL — an "OpenGL 4.1" suffix here would be an
/// impossible/fake string that CreepJS and BrowserScan flag instantly.
const CLOAK_GPU_RENDERERS: &[&str] = &[
    "ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)",
    "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)",
    "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)",
    "ANGLE (Apple, ANGLE Metal Renderer: Apple M4, Unspecified Version)",
];

/// Deterministic GPU renderer selection from seed. Sha256("gpu:"+seed) mod pool len.
fn gpu_renderer_for_seed(seed: &str) -> &'static str {
    let digest = Sha256::digest(format!("gpu:{seed}").as_bytes());
    let idx = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]) as usize;
    CLOAK_GPU_RENDERERS[idx % CLOAK_GPU_RENDERERS.len()]
}

/// Detected engine version from the actual CloakBrowser binary.
#[derive(Debug, Clone)]
struct EngineVersion {
    major: String,
    full: String,
}

impl EngineVersion {
    fn fallback() -> Self {
        Self {
            major: CLOAK_CHROME_MAJOR_FALLBACK.to_string(),
            full: format!("{CLOAK_CHROME_MAJOR_FALLBACK}.0.0.0"),
        }
    }
}

/// Detect the Chrome major version from the actual CloakBrowser binary.
/// Runs `Chromium --version`, parses "Chromium 145.0.7632.109" → major="145", full="145.0.7632.109".
/// Falls back to path-based detection (directory name like `chromium-145`), then to the compile-time constant.
fn detect_engine_version(browser_binary: &Path) -> EngineVersion {
    // Strategy 1: run --version
    if let Ok(output) = Command::new(browser_binary)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        if let Some(version) = parse_chromium_version(&stdout) {
            return version;
        }
    }
    // Strategy 2: extract from binary path (e.g. .../chromium-145/...)
    if let Some(version) = extract_version_from_path(browser_binary) {
        return version;
    }
    // Strategy 3: fallback constant
    EngineVersion::fallback()
}

/// Parse "Chromium 145.0.7632.109" or "Chromium.app ... 145.0.7632.109" → EngineVersion
fn parse_chromium_version(output: &str) -> Option<EngineVersion> {
    let re = Regex::new(r"(\d+)\.(\d+)\.(\d+)\.(\d+)").ok()?;
    let caps = re.captures(output)?;
    let major = caps.get(1)?.as_str().to_string();
    let full = format!("{}.{}.{}.{}", &caps[1], &caps[2], &caps[3], &caps[4]);
    Some(EngineVersion { major, full })
}

/// Try to extract major version from binary path components like `chromium-145`
fn extract_version_from_path(path: &Path) -> Option<EngineVersion> {
    let re = Regex::new(r"chromium[-_](\d+)").ok()?;
    for ancestor in path.ancestors() {
        let name = ancestor.file_name()?.to_string_lossy();
        if let Some(caps) = re.captures(&name) {
            let major = caps.get(1)?.as_str().to_string();
            let full = format!("{major}.0.0.0");
            return Some(EngineVersion { major, full });
        }
    }
    None
}

#[derive(Debug, Error)]
pub enum CloakError {
    #[error("account name is invalid; use letters, digits, ., @, +, - or _, and do not use main")]
    InvalidAccountName,
    #[error("account already exists: {0}")]
    AccountExists(String),
    #[error("account does not exist: {0}")]
    AccountMissing(String),
    #[error("account is running: {0}")]
    AccountRunning(String),
    #[error("unsupported proxy URL; use socks5://, http://, or https://")]
    InvalidProxy,
    #[error("CloakBrowser binary not found")]
    BrowserMissing,
    #[error("companion extension not found: {0}")]
    ExtensionMissing(PathBuf),
    #[error("privacy gate failed: {0}")]
    PrivacyGate(String),
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("url: {0}")]
    Url(#[from] url::ParseError),
    #[error("http: {0}")]
    Http(#[from] reqwest::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("relay: {0}")]
    Relay(String),
}

pub type Result<T> = std::result::Result<T, CloakError>;

#[derive(Debug, Clone)]
pub struct CloakConfig {
    pub repo_root: PathBuf,
    pub account_base: PathBuf,
    pub extension_source: PathBuf,
    pub cloakbrowser_root: PathBuf,
}

impl CloakConfig {
    pub fn from_env() -> Result<Self> {
        let home = home_dir()?;
        let repo_root = env::var_os("CLOAK_REPO_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(default_repo_root);
        let account_base = env::var_os("CLOAK_ACCOUNT_BASE")
            .map(PathBuf::from)
            .unwrap_or_else(|| default_account_base(&home));
        let extension_source = env::var_os("CLOAK_EXTENSION_SOURCE")
            .map(PathBuf::from)
            .unwrap_or_else(|| repo_root.join("extension/cloak-companion"));
        let cloakbrowser_root = env::var_os("CLOAK_BROWSER_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".cloakbrowser"));

        Ok(Self {
            repo_root,
            account_base,
            extension_source,
            cloakbrowser_root,
        })
    }

    pub fn profile_dir(&self, name: &str) -> PathBuf {
        self.account_base.join(name)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub name: String,
    pub profile_path: PathBuf,
    pub created_at: u64,
    pub archived: bool,
    pub seed: String,
    pub region: Option<String>,
    pub locale_enabled: bool,
    pub proxy_display: String,
    pub has_proxy: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyPlan {
    pub mode: ProxyMode,
    pub display: String,
    pub browser_arg: Option<String>,
    pub relay_needed: bool,
    pub raw_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ProxyMode {
    None,
    Direct,
    Relay,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeoPlan {
    pub exit_ip: Option<String>,
    pub country: Option<String>,
    pub timezone: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchPlan {
    pub account: String,
    pub seed: String,
    pub profile_path: PathBuf,
    pub extension_runtime_path: PathBuf,
    pub load_extension_paths: Vec<PathBuf>,
    pub extra_extension_paths: Vec<PathBuf>,
    pub selftest_extension_paths: Vec<PathBuf>,
    pub browser_binary: PathBuf,
    pub proxy: ProxyPlan,
    pub geo: GeoPlan,
    pub locale: Option<String>,
    pub browser_identity: Value,
    pub argv: Vec<String>,
    pub privacy_failures: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct LaunchOptions {
    pub dry_run: bool,
    pub skip_geo: bool,
    pub locale_override: Option<bool>,
    pub allow_privacy_fail: bool,
    pub preflight: PreflightMode,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PreflightMode {
    Off,
    Strict,
    #[default]
    Async,
}

impl LaunchOptions {
    pub fn from_env(dry_run: bool) -> Self {
        let allow_privacy_fail = truthy_env("CLOAK_ALLOW_PRIVACY_FAIL");
        let skip_geo = truthy_env("CLOAK_SKIP_GEO");
        let locale_override = env::var("LOCALE").ok().map(|v| truthy(&v));
        let preflight = match env::var("CLOAK_PREFLIGHT").unwrap_or_else(|_| "async".to_string()).as_str() {
            "0" | "off" | "false" => PreflightMode::Off,
            "strict" => PreflightMode::Strict,
            _ => PreflightMode::Async,
        };
        Self {
            dry_run,
            skip_geo,
            locale_override,
            allow_privacy_fail,
            preflight,
        }
    }
}

#[derive(Debug, Clone)]
struct ProxyConfig {
    raw_url: Option<String>,
    mode: ProxyMode,
    display: String,
    browser_arg: Option<String>,
    relay_needed: bool,
    reqwest_proxy_url: Option<String>,
}

struct ExtraExtensionPlan {
    load_extension_paths: Vec<PathBuf>,
    extra_extension_paths: Vec<PathBuf>,
    selftest_extension_paths: Vec<PathBuf>,
}

struct ExtraExtensionItem {
    source_path: PathBuf,
    load_path: PathBuf,
    include_in_selftest: bool,
    kind: ExtraExtensionKind,
}

#[derive(Debug, Serialize, Deserialize)]
struct RelayRequest {
    upstream_url: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct RelayState {
    upstream_hash: String,
    port: u16,
    pid: u32,
}

#[derive(PartialEq, Eq)]
enum ExtraExtensionKind {
    Directory,
    Crx,
}

pub fn validate_account_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name == "main"
        || name.starts_with('.')
        || name.ends_with('.')
        || name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'@' | b'+' | b'-' | b'_'))
    {
        return Err(CloakError::InvalidAccountName);
    }
    Ok(())
}

pub fn legacy_seed(name: &str) -> String {
    let digest = Sha256::digest(name.as_bytes());
    let prefix = u32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]]);
    (prefix % 90_000 + 10_000).to_string()
}

pub fn list_accounts(config: &CloakConfig) -> Result<Vec<Account>> {
    list_accounts_by_archive_state(config, false)
}

pub fn list_archived_accounts(config: &CloakConfig) -> Result<Vec<Account>> {
    list_accounts_by_archive_state(config, true)
}

fn list_accounts_by_archive_state(config: &CloakConfig, archived: bool) -> Result<Vec<Account>> {
    fs::create_dir_all(&config.account_base)?;
    secure_dir(&config.account_base)?;

    let mut accounts = Vec::new();
    for entry in fs::read_dir(&config.account_base)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        if name == "main" || name.starts_with('.') {
            continue;
        }
        let account = read_account(config, &name)?;
        if account.archived == archived {
            accounts.push(account);
        }
    }
    accounts.sort_by(|a, b| {
        b.created_at
            .cmp(&a.created_at)
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(accounts)
}

pub fn read_account(config: &CloakConfig, name: &str) -> Result<Account> {
    validate_account_name(name)?;
    let profile_path = config.profile_dir(name);
    if profile_path.exists() {
        secure_account_dir(&profile_path)?;
    }
    let seed = pinned_seed(&profile_path)?.unwrap_or_else(|| legacy_seed(name));
    let region = read_first_line(&profile_path.join(".cloak-region"))?;
    let locale_enabled = profile_path.join(".cloak-locale").exists();
    let proxy_raw = read_first_line(&profile_path.join(".cloak-proxy"))?;
    let proxy_display = proxy_raw
        .as_deref()
        .and_then(|raw| proxy_config(raw).ok())
        .map(|p| p.display)
        .unwrap_or_else(|| "关".to_string());
    let created_at = account_created_at(&profile_path)?;
    let archived = profile_path.join(".cloak-archived").exists();

    Ok(Account {
        name: name.to_string(),
        profile_path,
        created_at,
        archived,
        seed,
        region: region.filter(|s| !s.is_empty()),
        locale_enabled,
        proxy_display,
        has_proxy: proxy_raw.is_some(),
    })
}

pub fn create_account(config: &CloakConfig, name: &str) -> Result<Account> {
    validate_account_name(name)?;
    let profile = config.profile_dir(name);
    if profile.exists() {
        return Err(CloakError::AccountExists(name.to_string()));
    }
    secure_account_dir(&profile)?;
    let seed = rand::thread_rng().gen_range(10_000..100_000).to_string();
    write_secret_atomic(&profile.join(".cloak-seed"), &seed)?;
    write_secret_atomic(
        &profile.join(".cloak-created-at"),
        &current_created_at().to_string(),
    )?;
    read_account(config, name)
}

pub fn rename_account(config: &CloakConfig, old_name: &str, new_name: &str) -> Result<Account> {
    validate_account_name(old_name)?;
    validate_account_name(new_name)?;
    let old_path = config.profile_dir(old_name);
    let new_path = config.profile_dir(new_name);
    if !old_path.exists() {
        return Err(CloakError::AccountMissing(old_name.to_string()));
    }
    if new_path.exists() {
        return Err(CloakError::AccountExists(new_name.to_string()));
    }
    secure_account_dir(&old_path)?;
    let seed = pinned_seed(&old_path)?.unwrap_or_else(|| legacy_seed(old_name));
    write_secret_atomic(&old_path.join(".cloak-seed"), &seed)?;
    fs::rename(&old_path, &new_path)?;
    secure_account_dir(&new_path)?;
    read_account(config, new_name)
}

pub fn delete_account(config: &CloakConfig, name: &str) -> Result<()> {
    validate_account_name(name)?;
    let path = config.profile_dir(name);
    if path.exists() {
        if account_profile_is_running(&path)? {
            return Err(CloakError::AccountRunning(name.to_string()));
        }
        fs::remove_dir_all(path)?;
    }
    Ok(())
}

pub fn set_account_archived(config: &CloakConfig, name: &str, archived: bool) -> Result<Account> {
    let profile = ensure_profile(config, name)?;
    let path = profile.join(".cloak-archived");
    if archived {
        write_secret_atomic(&path, "")?;
    } else {
        remove_if_present(&path)?;
    }
    read_account(config, name)
}

pub fn set_proxy(config: &CloakConfig, name: &str, value: Option<&str>) -> Result<Account> {
    let profile = ensure_profile(config, name)?;
    let path = profile.join(".cloak-proxy");
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        Some(raw) => {
            let _ = proxy_config(raw)?;
            write_secret_atomic(&path, raw)?;
        }
        None => remove_if_present(&path)?,
    }
    read_account(config, name)
}

pub fn set_region(config: &CloakConfig, name: &str, value: Option<&str>) -> Result<Account> {
    let profile = ensure_profile(config, name)?;
    let path = profile.join(".cloak-region");
    match value.map(str::trim).filter(|v| !v.is_empty()) {
        Some(raw) => write_secret_atomic(&path, raw)?,
        None => remove_if_present(&path)?,
    }
    read_account(config, name)
}

pub fn toggle_locale(config: &CloakConfig, name: &str) -> Result<Account> {
    let profile = ensure_profile(config, name)?;
    let path = profile.join(".cloak-locale");
    if path.exists() {
        fs::remove_file(&path)?;
    } else {
        write_secret_atomic(&path, "")?;
    }
    read_account(config, name)
}

pub fn build_launch_plan(config: &CloakConfig, name: &str, options: &LaunchOptions) -> Result<LaunchPlan> {
    validate_account_name(name)?;
    if !config.extension_source.is_dir() {
        return Err(CloakError::ExtensionMissing(config.extension_source.clone()));
    }

    let profile_path = config.profile_dir(name);
    let seed = pinned_seed(&profile_path)?.unwrap_or_else(|| legacy_seed(name));
    let extension_runtime_path = profile_path.join(".cloak-companion");
    let extension_plan = discover_extra_extensions(config, &profile_path, &extension_runtime_path)?;
    let browser_binary = resolve_browser_binary(config)?;
    let engine = detect_engine_version(&browser_binary);

    let region = read_first_line(&profile_path.join(".cloak-region"))?;
    let proxy_raw = read_first_line(&profile_path.join(".cloak-proxy"))?;
    let proxy_config = proxy_raw
        .as_deref()
        .map(proxy_config)
        .transpose()?
        .unwrap_or_else(no_proxy_config);

    let mut privacy_failures = Vec::new();
    let geo = if options.skip_geo {
        GeoPlan {
            exit_ip: None,
            country: None,
            timezone: env::var("TZ").ok(),
        }
    } else {
        match lookup_geo(&proxy_config) {
            Ok(geo) => geo,
            Err(err) => {
                privacy_failures.push(format!(
                    "无法通过账号出口解析公网 IP/timezone（proxy={}，error={}）。",
                    proxy_config.display, err
                ));
                GeoPlan {
                    exit_ip: None,
                    country: None,
                    timezone: env::var("TZ").ok(),
                }
            }
        }
    };

    if geo.exit_ip.is_none() && !options.skip_geo {
        privacy_failures.push(format!("无法通过账号出口获取公网 IP（proxy={}）。", proxy_config.display));
    }
    if let Some(tz) = geo.timezone.as_deref() {
        if !valid_tz(tz) {
            privacy_failures.push(format!("无法通过账号出口解析有效 timezone（got={}）。", tz));
        }
    } else if !options.skip_geo {
        privacy_failures.push("无法通过账号出口解析有效 timezone（got=empty）。".to_string());
    }
    if let Some(label) = region.as_deref() {
        if !region_matches(label, geo.country.as_deref().unwrap_or(""), geo.timezone.as_deref().unwrap_or("")) {
            privacy_failures.push(format!(
                "区域标签「{}」与出口 country/timezone 不一致（country={}, timezone={}）。",
                label,
                geo.country.as_deref().unwrap_or("unknown"),
                geo.timezone.as_deref().unwrap_or("unknown")
            ));
        }
    }

    let locale_enabled = options
        .locale_override
        .unwrap_or_else(|| profile_path.join(".cloak-locale").exists());
    let locale = if locale_enabled {
        if let Some(country) = geo.country.as_deref().filter(|value| !value.is_empty()) {
            let primary = language_for_country(country);
            Some(accept_language(&primary))
        } else {
            if !options.skip_geo {
                privacy_failures.push(
                    "语言跟随已开启，但无法由账号出口国家码解析 Accept-Language（country=unknown）。"
                        .to_string(),
                );
            }
            None
        }
    } else {
        None
    };

    let browser_identity = browser_identity_plan(&engine);

    // C5: Privacy gate — version consistency assertion (UA major == engine major)
    let ua_major = browser_identity
        .get("userAgent")
        .and_then(Value::as_str)
        .and_then(|ua| {
            let re = Regex::new(r"Chrome/(\d+)").ok()?;
            let caps = re.captures(ua)?;
            Some(caps.get(1)?.as_str().to_string())
        });
    if let Some(ref major) = ua_major {
        if *major != engine.major {
            privacy_failures.push(format!(
                "版本不一致：UA major={} 但引擎 major={}。这会导致 TLS/JA3 vs UA 矛盾。",
                major, engine.major
            ));
        }
    }

    let user_agent = browser_identity
        .get("userAgent")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let load_extensions = join_extension_paths(&extension_plan.load_extension_paths);
    let mut argv = vec![
        format!("--user-data-dir={}", profile_path.display()),
        format!("--fingerprint={seed}"),
        format!("--fingerprint-platform={}", fingerprint_platform()),
        format!("--user-agent={user_agent}"),
        format!("--load-extension={load_extensions}"),
        format!("--disable-extensions-except={load_extensions}"),
        "--no-first-run".to_string(),
        "--no-default-browser-check".to_string(),
        "--ignore-gpu-blocklist".to_string(),
        "--disable-blink-features=AutomationControlled".to_string(),
    ];
    append_native_fingerprint_args(&mut argv, &geo, locale.as_deref(), &engine, &seed);
    if let Some(proxy_arg) = &proxy_config.browser_arg {
        argv.push(format!("--proxy-server={proxy_arg}"));
    }
    argv.push("--new-window".to_string());
    argv.push(CHATGPT_URL.to_string());

    Ok(LaunchPlan {
        account: name.to_string(),
        seed,
        profile_path,
        extension_runtime_path,
        load_extension_paths: extension_plan.load_extension_paths,
        extra_extension_paths: extension_plan.extra_extension_paths,
        selftest_extension_paths: extension_plan.selftest_extension_paths,
        browser_binary,
        proxy: ProxyPlan {
            mode: proxy_config.mode,
            display: proxy_config.display,
            browser_arg: proxy_config.browser_arg,
            relay_needed: proxy_config.relay_needed,
            raw_url: proxy_config.raw_url,
        },
        geo,
        locale,
        browser_identity,
        argv,
        privacy_failures,
    })
}

pub fn launch_account(config: &CloakConfig, name: &str, options: &LaunchOptions) -> Result<()> {
    let plan = build_launch_plan(config, name, options)?;
    if !plan.privacy_failures.is_empty() && !options.allow_privacy_fail {
        return Err(CloakError::PrivacyGate(plan.privacy_failures.join("\n")));
    }

    secure_account_dir(&plan.profile_path)?;
    prepare_account_extension(config, &plan)?;

    let mut argv = plan.argv.clone();
    if plan.proxy.relay_needed {
        let raw = plan.proxy.raw_url.as_deref().ok_or_else(|| CloakError::Relay("missing relay upstream".to_string()))?;
        let relay_port = ensure_supervised_relay(&plan.profile_path, raw)?;
        let relay_arg = format!("socks5://127.0.0.1:{relay_port}");
        for arg in &mut argv {
            if arg == &format!("--proxy-server={RELAY_PLACEHOLDER}") {
                *arg = format!("--proxy-server={relay_arg}");
            }
        }
    }

    if options.preflight == PreflightMode::Strict {
        run_selftest(config, &plan, &argv, true)?;
    }

    let mut command = Command::new(&plan.browser_binary);
    command.args(&argv);
    if let Some(tz) = plan.geo.timezone.as_deref() {
        command.env("TZ", tz);
    }
    command.stdin(Stdio::null());
    command.stdout(Stdio::null());
    command.stderr(Stdio::null());
    command.spawn()?;

    if options.preflight == PreflightMode::Async {
        let _ = run_selftest(config, &plan, &argv, false);
    }

    Ok(())
}

pub fn maybe_run_relay_supervisor() -> Result<bool> {
    let mut args = env::args_os();
    let _program = args.next();
    let Some(mode) = args.next() else {
        return Ok(false);
    };
    if mode.as_os_str() != OsStr::new("--cloak-relay-supervisor") {
        return Ok(false);
    }
    let request_path = args
        .next()
        .ok_or_else(|| CloakError::Relay("missing relay request path".to_string()))?;
    let state_path = args
        .next()
        .ok_or_else(|| CloakError::Relay("missing relay state path".to_string()))?;
    if args.next().is_some() {
        return Err(CloakError::Relay("unexpected relay supervisor arguments".to_string()));
    }
    run_relay_supervisor(&PathBuf::from(request_path), &PathBuf::from(state_path))?;
    Ok(true)
}

fn ensure_supervised_relay(profile_path: &Path, upstream_url: &str) -> Result<u16> {
    let relay_dir = profile_path.join(".cloak-relay");
    fs::create_dir_all(&relay_dir)?;
    secure_dir(&relay_dir)?;

    let upstream_hash = relay_hash(upstream_url);
    let request_path = relay_dir.join(format!("{upstream_hash}.request.json"));
    let state_path = relay_dir.join(format!("{upstream_hash}.state.json"));

    if let Some(port) = live_supervised_relay_port(&state_path, &upstream_hash)? {
        return Ok(port);
    }

    let request = RelayRequest {
        upstream_url: upstream_url.to_string(),
    };
    write_secret_atomic(&request_path, &serde_json::to_string(&request)?)?;

    let supervisor_bin = env::var_os("CLOAK_RELAY_SUPERVISOR_BIN")
        .map(PathBuf::from)
        .unwrap_or(env::current_exe()?);
    let mut command = Command::new(supervisor_bin);
    command
        .arg("--cloak-relay-supervisor")
        .arg(&request_path)
        .arg(&state_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command.spawn()?;

    let started_at = Instant::now();
    while started_at.elapsed() < Duration::from_secs(5) {
        if let Some(port) = live_supervised_relay_port(&state_path, &upstream_hash)? {
            return Ok(port);
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    Err(CloakError::Relay(
        "background relay supervisor did not become ready".to_string(),
    ))
}

fn run_relay_supervisor(request_path: &Path, state_path: &Path) -> Result<()> {
    let body = fs::read_to_string(request_path)?;
    let request: RelayRequest = serde_json::from_str(&body)?;
    let upstream_hash = relay_hash(&request.upstream_url);
    if let Some(parent) = state_path.parent() {
        fs::create_dir_all(parent)?;
        secure_dir(parent)?;
    }

    relay::serve_forever(&request.upstream_url, |port| {
        let state = RelayState {
            upstream_hash,
            port,
            pid: std::process::id(),
        };
        let encoded = serde_json::to_string(&state).map_err(|err| err.to_string())?;
        write_secret_atomic(state_path, &encoded).map_err(|err| err.to_string())?;
        let _ = fs::remove_file(request_path);
        Ok(())
    })
    .map_err(CloakError::Relay)
}

fn live_supervised_relay_port(state_path: &Path, expected_hash: &str) -> Result<Option<u16>> {
    if !state_path.exists() {
        return Ok(None);
    }

    let Ok(body) = fs::read_to_string(state_path) else {
        return Ok(None);
    };
    let Ok(state) = serde_json::from_str::<RelayState>(&body) else {
        let _ = fs::remove_file(state_path);
        return Ok(None);
    };
    if state.upstream_hash != expected_hash || state.port == 0 {
        return Ok(None);
    }
    if local_socks5_ready(state.port) {
        Ok(Some(state.port))
    } else {
        let _ = fs::remove_file(state_path);
        Ok(None)
    }
}

fn local_socks5_ready(port: u16) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = StdTcpStream::connect_timeout(&addr, Duration::from_millis(250)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    if stream.write_all(&[0x05, 0x01, 0x00]).is_err() {
        return false;
    }
    let mut response = [0u8; 2];
    stream.read_exact(&mut response).is_ok() && response == [0x05, 0x00]
}

fn relay_hash(upstream_url: &str) -> String {
    let digest = Sha256::digest(upstream_url.as_bytes());
    hex_digest(&digest)
}

fn account_profile_is_running(profile_path: &Path) -> Result<bool> {
    let needle = user_data_dir_needle(profile_path);
    running_process_command_lines().map(|commands| {
        commands
            .lines()
            .any(|command| command_line_mentions_user_data_dir(command, &needle))
    })
}

fn user_data_dir_needle(profile_path: &Path) -> String {
    format!("--user-data-dir={}", profile_path.display())
}

fn command_line_mentions_user_data_dir(command: &str, needle: &str) -> bool {
    let Some(index) = command.find(needle) else {
        return false;
    };
    let rest = &command[index + needle.len()..];
    rest.is_empty()
        || rest
            .chars()
            .next()
            .map(|ch| ch.is_whitespace() || matches!(ch, '"' | '\''))
            .unwrap_or(true)
}

#[cfg(target_os = "windows")]
fn running_process_command_lines() -> Result<String> {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "Get-CimInstance Win32_Process | ForEach-Object { $_.CommandLine }",
        ])
        .output()?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

#[cfg(not(target_os = "windows"))]
fn running_process_command_lines() -> Result<String> {
    let output = Command::new("ps")
        .args(["axww", "-o", "command="])
        .output()?;
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn hex_digest(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

pub fn prepare_account_extension(config: &CloakConfig, plan: &LaunchPlan) -> Result<()> {
    prepare_companion_extension(config, plan, companion_page_spoof_enabled())?;
    prepare_crx_extensions(config, &plan.profile_path)?;
    Ok(())
}

fn prepare_companion_extension(
    config: &CloakConfig,
    plan: &LaunchPlan,
    page_spoof_enabled: bool,
) -> Result<()> {
    if plan.extension_runtime_path.exists() {
        fs::remove_dir_all(&plan.extension_runtime_path)?;
    }
    copy_dir(&config.extension_source, &plan.extension_runtime_path)?;
    secure_dir_recursive(&plan.extension_runtime_path)?;
    let seed_script = if page_spoof_enabled {
        format!("window.__cloakAccountSeed = \"{}\";\n", plan.seed)
    } else {
        "window.__cloakAccountSeed = \"\";\n".to_string()
    };
    let identity_script = format!(
        "window.__cloakBrowserIdentity = {};\n",
        serde_json::to_string(&plan.browser_identity)?
    );
    let worker_identity_script = format!(
        "self.__cloakBrowserIdentity = {};\n",
        serde_json::to_string(&plan.browser_identity)?
    );
    let header_rules = format!(
        "{}\n",
        serde_json::to_string_pretty(&browser_identity_header_rules(&plan.browser_identity))?
    );
    write_secret_atomic(
        &plan.extension_runtime_path.join("account-seed-main.js"),
        &seed_script,
    )?;
    write_secret_atomic(
        &plan.extension_runtime_path.join("browser-identity-main.js"),
        &identity_script,
    )?;
    write_secret_atomic(
        &plan.extension_runtime_path.join("browser-identity-worker.js"),
        &worker_identity_script,
    )?;
    write_secret_atomic(
        &plan
            .extension_runtime_path
            .join("rules/browser-identity-headers.json"),
        &header_rules,
    )?;
    if !page_spoof_enabled {
        strip_companion_page_scripts(&plan.extension_runtime_path.join("manifest.json"))?;
    }
    Ok(())
}

pub fn self_check(config: &CloakConfig) -> Result<String> {
    let accounts = list_accounts(config)?;
    let browser = resolve_browser_binary(config)?;
    if !config.extension_source.is_dir() {
        return Err(CloakError::ExtensionMissing(config.extension_source.clone()));
    }
    Ok(format!(
        "cloak: ok ({} account(s)); browser={}; extension={}",
        accounts.len(),
        browser.display(),
        config.extension_source.display()
    ))
}

fn ensure_profile(config: &CloakConfig, name: &str) -> Result<PathBuf> {
    validate_account_name(name)?;
    let profile = config.profile_dir(name);
    secure_account_dir(&profile)?;
    Ok(profile)
}

fn pinned_seed(profile_path: &Path) -> Result<Option<String>> {
    let Some(seed) = read_first_line(&profile_path.join(".cloak-seed"))? else {
        return Ok(None);
    };
    if seed.len() >= 4 && seed.len() <= 5 && seed.bytes().all(|b| b.is_ascii_digit()) {
        Ok(Some(seed))
    } else {
        Ok(None)
    }
}

fn account_created_at(profile_path: &Path) -> Result<u64> {
    if let Some(raw) = read_first_line(&profile_path.join(".cloak-created-at"))? {
        if let Ok(created_at) = raw.parse::<u64>() {
            return Ok(created_at);
        }
    }

    let metadata = fs::metadata(profile_path)?;
    let created_at = metadata.created().or_else(|_| metadata.modified()).ok();
    Ok(created_at.map(system_time_micros).unwrap_or(0))
}

fn current_created_at() -> u64 {
    system_time_micros(SystemTime::now())
}

fn system_time_micros(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|duration| {
            duration
                .as_secs()
                .saturating_mul(1_000_000)
                .saturating_add(u64::from(duration.subsec_micros()))
        })
        .unwrap_or(0)
}

fn proxy_config(raw: &str) -> Result<ProxyConfig> {
    let url = Url::parse(raw)?;
    let scheme = url.scheme();
    if !matches!(scheme, "socks5" | "http" | "https") {
        return Err(CloakError::InvalidProxy);
    }
    let host = url.host_str().ok_or(CloakError::InvalidProxy)?;
    let port = url.port().ok_or(CloakError::InvalidProxy)?;
    let hostport = format!("{host}:{port}");
    let has_auth = !url.username().is_empty();
    let mode = match scheme {
        "socks5" => ProxyMode::Relay,
        "http" | "https" if has_auth => ProxyMode::Relay,
        "http" | "https" => ProxyMode::Direct,
        _ => return Err(CloakError::InvalidProxy),
    };
    let relay_needed = mode == ProxyMode::Relay;
    let browser_arg = match mode {
        ProxyMode::None => None,
        ProxyMode::Direct => Some(raw.to_string()),
        ProxyMode::Relay => Some(RELAY_PLACEHOLDER.to_string()),
    };
    let reqwest_proxy_url = if scheme == "socks5" {
        Some(raw.replacen("socks5://", "socks5h://", 1))
    } else {
        Some(raw.to_string())
    };
    let display = if relay_needed {
        format!("{scheme}://{hostport}  (via local SOCKS5 relay)")
    } else {
        format!("{scheme}://{hostport}")
    };
    Ok(ProxyConfig {
        raw_url: Some(raw.to_string()),
        mode,
        display,
        browser_arg,
        relay_needed,
        reqwest_proxy_url,
    })
}

fn no_proxy_config() -> ProxyConfig {
    ProxyConfig {
        raw_url: None,
        mode: ProxyMode::None,
        display: "off (system VPN / direct)".to_string(),
        browser_arg: None,
        relay_needed: false,
        reqwest_proxy_url: None,
    }
}

fn discover_extra_extensions(
    _config: &CloakConfig,
    profile_path: &Path,
    extension_runtime_path: &Path,
) -> Result<ExtraExtensionPlan> {
    let mut load_extension_paths = vec![extension_runtime_path.to_path_buf()];
    let mut extra_extension_paths = Vec::new();
    let mut selftest_extension_paths = Vec::new();

    for item in extra_extension_items(profile_path)? {
        extra_extension_paths.push(item.load_path.clone());
        load_extension_paths.push(item.load_path.clone());
        if item.include_in_selftest {
            selftest_extension_paths.push(item.load_path);
        }
    }

    Ok(ExtraExtensionPlan {
        load_extension_paths,
        extra_extension_paths,
        selftest_extension_paths,
    })
}

fn extra_extension_items(profile_path: &Path) -> Result<Vec<ExtraExtensionItem>> {
    if !extra_extensions_enabled() {
        return Ok(Vec::new());
    }

    let root = extra_extensions_root()?;
    if !root.is_dir() {
        return Ok(Vec::new());
    }

    let mut items = Vec::new();
    let root_entries = extra_extension_root_entries(&root)?;
    let mut manifest_paths = Vec::new();
    for path in &root_entries {
        if path.is_dir() {
            let manifest = path.join("manifest.json");
            if manifest.is_file() {
                manifest_paths.push(manifest);
            }
        }
    }
    manifest_paths.sort();
    for manifest in manifest_paths {
        let Some(dir) = manifest.parent().map(Path::to_path_buf) else {
            continue;
        };
        let base = dir
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();
        if base == "cloak-companion" || path_contains_comma(&dir) {
            continue;
        }
        items.push(ExtraExtensionItem {
            source_path: dir.clone(),
            load_path: dir,
            include_in_selftest: base != "Chromium Web Store 插件",
            kind: ExtraExtensionKind::Directory,
        });
    }

    let extra_runtime = profile_path.join(".cloak-extra-extensions");
    let mut crx_paths = Vec::new();
    for path in &root_entries {
        if path.is_file() && path.extension().and_then(OsStr::to_str) == Some("crx") {
            crx_paths.push(path.clone());
        }
    }
    crx_paths.sort();
    for crx in crx_paths {
        if path_contains_comma(&crx) {
            continue;
        }
        if crx.to_string_lossy().contains("沉浸式翻译") {
            continue;
        }
        let slug = slug_for_path(&crx);
        if slug.is_empty() {
            continue;
        }
        items.push(ExtraExtensionItem {
            source_path: crx.clone(),
            load_path: extra_runtime.join(slug),
            include_in_selftest: true,
            kind: ExtraExtensionKind::Crx,
        });
    }

    Ok(items)
}

fn extra_extension_root_entries(root: &Path) -> Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(err) if optional_extra_extension_io_error(&err) => {
            eprintln!(
                "warn: default extra extension directory is not readable; skipping optional extensions: {} ({})",
                root.display(),
                err
            );
            return Ok(Vec::new());
        }
        Err(err) => return Err(err.into()),
    };

    let mut paths = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => paths.push(entry.path()),
            Err(err) if optional_extra_extension_io_error(&err) => {
                eprintln!(
                    "warn: failed to inspect an optional extension entry under {} ({})",
                    root.display(),
                    err
                );
            }
            Err(err) => return Err(err.into()),
        }
    }
    Ok(paths)
}

fn optional_extra_extension_io_error(err: &io::Error) -> bool {
    matches!(err.kind(), io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied)
}

fn prepare_crx_extensions(_config: &CloakConfig, profile_path: &Path) -> Result<()> {
    for item in extra_extension_items(profile_path)? {
        if item.kind != ExtraExtensionKind::Crx {
            continue;
        }
        if let Err(err) = unpack_crx_extension(&item.source_path, &item.load_path) {
            eprintln!(
                "warn: failed to unpack CRX extension: {} ({})",
                item.source_path.display(),
                err
            );
            continue;
        }
        secure_dir_recursive(&item.load_path)?;
    }
    Ok(())
}

fn unpack_crx_extension(crx: &Path, dest: &Path) -> Result<()> {
    if dest.exists() {
        fs::remove_dir_all(dest)?;
    }
    fs::create_dir_all(dest)?;

    let data = fs::read(crx)?;
    if data.len() < 12 || &data[0..4] != b"Cr24" {
        return Err(invalid_data("not a CRX file"));
    }
    let version = read_le_u32(&data[4..8])?;
    let start = match version {
        2 => {
            if data.len() < 16 {
                return Err(invalid_data("truncated CRX v2 header"));
            }
            let public_key_len = read_le_u32(&data[8..12])? as usize;
            let signature_len = read_le_u32(&data[12..16])? as usize;
            16usize
                .checked_add(public_key_len)
                .and_then(|offset| offset.checked_add(signature_len))
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "CRX v2 header overflow"))?
        }
        3 => {
            let header_len = read_le_u32(&data[8..12])? as usize;
            12usize
                .checked_add(header_len)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "CRX v3 header overflow"))?
        }
        _ => return Err(invalid_data("unsupported CRX version")),
    };
    if start >= data.len() {
        return Err(invalid_data("CRX zip payload missing"));
    }

    let reader = Cursor::new(&data[start..]);
    let mut archive = zip::ZipArchive::new(reader).map_err(zip_error)?;
    for index in 0..archive.len() {
        let mut file = archive.by_index(index).map_err(zip_error)?;
        let Some(name) = file.enclosed_name() else {
            return Err(invalid_data("unsafe path in CRX"));
        };
        let target = dest.join(name);
        if file.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut output = fs::File::create(&target)?;
        io::copy(&mut file, &mut output)?;
    }

    if !dest.join("manifest.json").is_file() {
        let _ = fs::remove_dir_all(dest);
        return Err(invalid_data("manifest.json missing after CRX unpack"));
    }
    Ok(())
}

fn join_extension_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(",")
}

fn extra_extensions_enabled() -> bool {
    !matches!(
        env::var("CLOAK_EXTRA_EXTENSIONS").ok().as_deref(),
        Some("0" | "off" | "false" | "no" | "NO" | "FALSE" | "OFF")
    )
}

fn extra_extensions_root() -> Result<PathBuf> {
    if let Some(path) = env::var_os("CLOAK_EXTRA_EXTENSIONS_DIR") {
        return Ok(PathBuf::from(path));
    }
    let home = home_dir()?;
    let local_cache = home.join("Library/Application Support/ChatGPT Cloak/Default Extensions");
    if local_cache.is_dir() {
        return Ok(local_cache);
    }
    Ok(home.join("Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件"))
}

fn slug_for_path(path: &Path) -> String {
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy())
        .unwrap_or_default();
    let mut out = String::new();
    let mut last_was_replacement = false;
    for ch in name.chars() {
        if ch == '_' {
            if !last_was_replacement {
                out.push('_');
                last_was_replacement = true;
            }
        } else if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-') {
            out.push(ch);
            last_was_replacement = false;
        } else if !last_was_replacement {
            out.push('_');
            last_was_replacement = true;
        }
    }
    out.trim_matches('_').to_string()
}

fn path_contains_comma(path: &Path) -> bool {
    path.to_string_lossy().contains(',')
}

fn read_le_u32(bytes: &[u8]) -> Result<u32> {
    if bytes.len() < 4 {
        return Err(invalid_data("not enough bytes for u32"));
    }
    Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn invalid_data(message: &str) -> CloakError {
    io::Error::new(io::ErrorKind::InvalidData, message).into()
}

fn zip_error(err: zip::result::ZipError) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err)
}

fn lookup_geo(proxy: &ProxyConfig) -> Result<GeoPlan> {
    let mut builder = Client::builder().timeout(Duration::from_secs(12));
    if let Some(proxy_url) = &proxy.reqwest_proxy_url {
        builder = builder.proxy(reqwest::Proxy::all(proxy_url)?);
    }
    let client = builder.build()?;
    let sources = [
        ("https://ipwho.is/", "ipwho"),
        ("https://ipinfo.io/json", "ipinfo"),
        ("http://ip-api.com/json/?fields=status,message,countryCode,timezone,query", "ip-api"),
    ];
    for (url, source) in sources {
        if let Ok(response) = client.get(url).send() {
            if let Ok(text) = response.error_for_status().and_then(|r| r.text()) {
                if let Some(geo) = parse_geo_json(source, &text) {
                    return Ok(geo);
                }
            }
        }
    }
    let ip = client
        .get("https://api.ipify.org")
        .send()?
        .error_for_status()?
        .text()?;
    Ok(GeoPlan {
        exit_ip: Some(ip.trim().to_string()).filter(|s| !s.is_empty()),
        country: None,
        timezone: env::var("TZ").ok(),
    })
}

fn parse_geo_json(source: &str, body: &str) -> Option<GeoPlan> {
    let value: Value = serde_json::from_str(body).ok()?;
    let (ip, country, timezone) = match source {
        "ipwho" => {
            if value.get("success")?.as_bool()? != true {
                return None;
            }
            (
                value.get("ip")?.as_str()?,
                value.get("country_code")?.as_str().unwrap_or(""),
                value.get("timezone")?.get("id")?.as_str()?,
            )
        }
        "ipinfo" => {
            if value.get("error").is_some() {
                return None;
            }
            (
                value.get("ip")?.as_str()?,
                value.get("country").and_then(Value::as_str).unwrap_or(""),
                value.get("timezone")?.as_str()?,
            )
        }
        "ip-api" => {
            if value.get("status")?.as_str()? != "success" {
                return None;
            }
            (
                value.get("query")?.as_str()?,
                value.get("countryCode").and_then(Value::as_str).unwrap_or(""),
                value.get("timezone")?.as_str()?,
            )
        }
        _ => return None,
    };
    if ip.is_empty() || timezone.is_empty() {
        return None;
    }
    Some(GeoPlan {
        exit_ip: Some(ip.to_string()),
        country: Some(country.to_string()).filter(|s| !s.is_empty()),
        timezone: Some(timezone.to_string()),
    })
}

fn run_selftest(config: &CloakConfig, plan: &LaunchPlan, argv: &[String], strict: bool) -> Result<()> {
    let selftest = config.repo_root.join("selftest/run-selftest.mjs");
    if !selftest.exists() {
        return Ok(());
    }
    let Some(tz) = plan.geo.timezone.as_deref() else {
        return Ok(());
    };
    let report_file = plan.profile_path.join(".cloak-selftest-last.json");
    let mut args = vec![
        selftest.as_os_str().to_owned(),
        OsStr::new("--seed").to_owned(),
        OsStr::new(&plan.seed).to_owned(),
        OsStr::new("--tz").to_owned(),
        OsStr::new(tz).to_owned(),
        OsStr::new("--expect-timezone").to_owned(),
        OsStr::new(tz).to_owned(),
        OsStr::new("--pair").to_owned(),
        OsStr::new("--headless").to_owned(),
        OsStr::new("--quiet").to_owned(),
        OsStr::new("--result-file").to_owned(),
        report_file.as_os_str().to_owned(),
    ];
    if let Some(ip) = plan.geo.exit_ip.as_deref() {
        args.push(OsStr::new("--expect-ip").to_owned());
        args.push(OsStr::new(ip).to_owned());
    }
    if let Some(proxy_arg) = argv
        .iter()
        .find_map(|arg| arg.strip_prefix("--proxy-server=").map(str::to_string))
    {
        args.push(OsStr::new("--proxy-server").to_owned());
        args.push(OsStr::new(&proxy_arg).to_owned());
    }
    if let Some(locale) = plan.locale.as_deref() {
        args.push(OsStr::new("--accept-lang").to_owned());
        args.push(OsStr::new(locale).to_owned());
    }
    for ext in &plan.selftest_extension_paths {
        args.push(OsStr::new("--extra-extension").to_owned());
        args.push(ext.as_os_str().to_owned());
    }

    let mut cmd = Command::new("node");
    cmd.args(args);
    cmd.stdout(Stdio::null());
    cmd.stderr(if strict { Stdio::piped() } else { Stdio::null() });
    if strict {
        let output = cmd.output()?;
        if !output.status.success() {
            return Err(CloakError::PrivacyGate(
                String::from_utf8_lossy(&output.stderr).to_string(),
            ));
        }
    } else {
        let _ = cmd.spawn();
    }
    Ok(())
}

fn resolve_browser_binary(config: &CloakConfig) -> Result<PathBuf> {
    if let Some(path) = env::var_os("CLOAK_BROWSER_BIN").map(PathBuf::from) {
        if is_executable(&path) {
            return Ok(path);
        }
    }
    let current = config.cloakbrowser_root.join(current_browser_relative_path());
    if is_executable(&current) {
        return Ok(current);
    }
    let mut candidates = Vec::new();
    if let Ok(entries) = fs::read_dir(&config.cloakbrowser_root) {
        for entry in entries.flatten() {
            let path = entry.path().join(browser_relative_in_version_dir());
            if is_executable(&path) {
                candidates.push(path);
            }
        }
    }
    candidates.sort();
    candidates.pop().ok_or(CloakError::BrowserMissing)
}

#[cfg(target_os = "macos")]
fn current_browser_relative_path() -> &'static str {
    "current/Chromium.app/Contents/MacOS/Chromium"
}

#[cfg(target_os = "windows")]
fn current_browser_relative_path() -> &'static str {
    r"current\Chromium\Application\chrome.exe"
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn current_browser_relative_path() -> &'static str {
    "current/chrome"
}

#[cfg(target_os = "macos")]
fn browser_relative_in_version_dir() -> &'static str {
    "Chromium.app/Contents/MacOS/Chromium"
}

#[cfg(target_os = "windows")]
fn browser_relative_in_version_dir() -> &'static str {
    r"Chromium\Application\chrome.exe"
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn browser_relative_in_version_dir() -> &'static str {
    "chrome"
}

#[cfg(target_os = "macos")]
fn fingerprint_platform() -> &'static str {
    "macos"
}

#[cfg(target_os = "windows")]
fn fingerprint_platform() -> &'static str {
    "windows"
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn fingerprint_platform() -> &'static str {
    "linux"
}

fn language_for_country(country: &str) -> String {
    match country.to_ascii_uppercase().as_str() {
        "JP" => "ja-JP",
        "CN" => "zh-CN",
        "TW" => "zh-TW",
        "HK" => "zh-HK",
        "KR" => "ko-KR",
        "FR" => "fr-FR",
        "DE" => "de-DE",
        "NL" => "nl-NL",
        "GB" | "UK" => "en-GB",
        "US" => "en-US",
        "CA" => "en-CA",
        "AU" => "en-AU",
        "SG" => "en-SG",
        "TH" => "th-TH",
        "VN" => "vi-VN",
        "ID" => "id-ID",
        "MY" => "ms-MY",
        "PH" => "en-PH",
        "IN" => "en-IN",
        "BR" => "pt-BR",
        "ES" => "es-ES",
        "IT" => "it-IT",
        "TR" => "tr-TR",
        "RU" => "ru-RU",
        _ => "en-US",
    }
    .to_string()
}

fn accept_language(primary: &str) -> String {
    let base = primary.split('-').next().unwrap_or(primary);
    if base == "en" {
        format!("{primary},en;q=0.9")
    } else {
        format!("{primary},{base};q=0.9,en-US;q=0.8,en;q=0.7")
    }
}

fn primary_locale_from_accept_language(accept_language: &str) -> &str {
    accept_language
        .split(',')
        .next()
        .unwrap_or(accept_language)
        .trim()
}

fn append_native_fingerprint_args(argv: &mut Vec<String>, geo: &GeoPlan, locale: Option<&str>, engine: &EngineVersion, seed: &str) {
    // Existing: timezone + locale + webrtc
    if let Some(tz) = geo.timezone.as_deref().filter(|value| !value.is_empty()) {
        argv.push(format!("--fingerprint-timezone={tz}"));
    }
    if let Some(locale) = locale {
        let primary_locale = primary_locale_from_accept_language(locale);
        argv.push(format!("--lang={primary_locale}"));
        argv.push(format!("--fingerprint-locale={primary_locale}"));
        argv.push(format!("--accept-lang={locale}"));
    }
    if let Some(exit_ip) = geo.exit_ip.as_deref().filter(|value| !value.is_empty()) {
        argv.push(format!("--fingerprint-webrtc-ip={exit_ip}"));
    }
    // New: brand-version, platform-version, GPU vendor/renderer (C2+C3)
    argv.push(format!("--fingerprint-brand-version={full}", full = engine.full));
    argv.push(format!("--fingerprint-platform-version={pv}", pv = CLOAK_MAC_PLATFORM_VERSION));
    argv.push("--fingerprint-gpu-vendor=Google Inc. (Apple)".to_string());
    argv.push(format!("--fingerprint-gpu-renderer={renderer}", renderer = gpu_renderer_for_seed(seed)));
}

fn valid_tz(tz: &str) -> bool {
    Regex::new(r"^[A-Za-z]+/[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)?$")
        .expect("timezone regex")
        .is_match(tz)
}

fn browser_identity_plan(engine: &EngineVersion) -> Value {
    serde_json::json!({
        "userAgent": format!(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X {CLOAK_MAC_UA_VERSION}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{major}.0.0.0 Safari/537.36",
            major = engine.major
        ),
        "platform": "MacIntel",
        "uaData": {
            "brands": [
                { "brand": "Google Chrome", "version": &engine.major },
                { "brand": "Chromium", "version": &engine.major },
                { "brand": "Not)A;Brand", "version": "24" }
            ],
            "mobile": false,
            "platform": "macOS",
            "fullVersionList": [
                { "brand": "Google Chrome", "version": &engine.full },
                { "brand": "Chromium", "version": &engine.full },
                { "brand": "Not)A;Brand", "version": "24.0.0.0" }
            ],
            "uaFullVersion": &engine.full,
            "platformVersion": CLOAK_MAC_PLATFORM_VERSION,
            "architecture": "arm",
            "bitness": "64",
            "model": ""
        }
    })
}

fn browser_identity_header_rules(identity: &Value) -> Value {
    let Some(user_agent) = identity.get("userAgent").and_then(Value::as_str) else {
        return Value::Array(vec![]);
    };
    let ua_data = identity.get("uaData").unwrap_or(&Value::Null);
    let mut headers = vec![serde_json::json!({
        "header": "User-Agent",
        "operation": "set",
        "value": user_agent,
    })];
    if let Some(brands) = format_header_brands(ua_data.get("brands")) {
        headers.push(serde_json::json!({
            "header": "Sec-CH-UA",
            "operation": "set",
            "value": brands,
        }));
    }
    headers.push(serde_json::json!({
        "header": "Sec-CH-UA-Mobile",
        "operation": "set",
        "value": if ua_data.get("mobile").and_then(Value::as_bool).unwrap_or(false) { "?1" } else { "?0" },
    }));
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Platform",
        ua_data.get("platform").and_then(Value::as_str),
    );
    if let Some(full_version_list) = format_header_brands(ua_data.get("fullVersionList")) {
        headers.push(serde_json::json!({
            "header": "Sec-CH-UA-Full-Version-List",
            "operation": "set",
            "value": full_version_list,
        }));
    }
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Full-Version",
        ua_data.get("uaFullVersion").and_then(Value::as_str),
    );
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Platform-Version",
        ua_data.get("platformVersion").and_then(Value::as_str),
    );
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Arch",
        ua_data.get("architecture").and_then(Value::as_str),
    );
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Bitness",
        ua_data.get("bitness").and_then(Value::as_str),
    );
    push_header_if_string(
        &mut headers,
        "Sec-CH-UA-Model",
        ua_data.get("model").and_then(Value::as_str),
    );
    serde_json::json!([{
        "id": 91001,
        "priority": 1,
        "action": {
            "type": "modifyHeaders",
            "requestHeaders": headers,
        },
        "condition": {
            "regexFilter": "^https?://",
            "resourceTypes": [
                "main_frame",
                "sub_frame",
                "stylesheet",
                "script",
                "image",
                "font",
                "xmlhttprequest",
                "media",
                "other"
            ],
        },
    }])
}

fn push_header_if_string(headers: &mut Vec<Value>, name: &str, value: Option<&str>) {
    if let Some(value) = value {
        headers.push(serde_json::json!({
            "header": name,
            "operation": "set",
            "value": quote_header(value),
        }));
    }
}

fn quote_header(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn format_header_brands(value: Option<&Value>) -> Option<String> {
    let brands = value?.as_array()?;
    let items = brands
        .iter()
        .filter_map(|item| {
            Some(format!(
                "{};v={}",
                quote_header(item.get("brand")?.as_str()?),
                quote_header(item.get("version")?.as_str()?)
            ))
        })
        .collect::<Vec<_>>();
    if items.is_empty() {
        None
    } else {
        Some(items.join(", "))
    }
}

fn region_matches(label: &str, country: &str, tz: &str) -> bool {
    if label.is_empty() {
        return true;
    }
    let hay = format!("{country} {tz}")
        .to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let mut checked = false;
    for token in label
        .to_ascii_lowercase()
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| s.len() >= 2)
    {
        checked = true;
        if !hay.contains(token) {
            return false;
        }
    }
    !checked || checked
}

fn copy_dir(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst)?;
    for entry in WalkDir::new(src) {
        let entry = entry.map_err(|err| io::Error::new(io::ErrorKind::Other, err))?;
        let rel = entry
            .path()
            .strip_prefix(src)
            .map_err(|err| io::Error::new(io::ErrorKind::Other, err))?;
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn strip_companion_page_scripts(manifest_path: &Path) -> Result<()> {
    if !manifest_path.exists() {
        return Ok(());
    }

    let body = fs::read_to_string(manifest_path)?;
    let mut manifest: Value = serde_json::from_str(&body)?;
    if let Some(object) = manifest.as_object_mut() {
        object.remove("content_scripts");
        object.remove("host_permissions");
        object.remove("background");
        object.remove("declarative_net_request");
        object.insert(
            "permissions".to_string(),
            Value::Array(vec![Value::String("storage".to_string())]),
        );
    }
    write_secret_atomic(
        manifest_path,
        &format!("{}\n", serde_json::to_string_pretty(&manifest)?),
    )?;
    Ok(())
}

fn read_first_line(path: &Path) -> Result<Option<String>> {
    if !path.exists() {
        return Ok(None);
    }
    let content = fs::read_to_string(path)?;
    Ok(content.lines().next().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()))
}

fn write_secret_atomic(path: &Path, value: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        secure_dir(parent)?;
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, if value.ends_with('\n') { value.to_string() } else { format!("{value}\n") })?;
    secure_file(&tmp)?;
    fs::rename(tmp, path)?;
    secure_file(path)?;
    Ok(())
}

fn remove_if_present(path: &Path) -> Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn secure_account_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    secure_dir(path)?;
    for file in [
        ".cloak-seed",
        ".cloak-created-at",
        ".cloak-archived",
        ".cloak-proxy",
        ".cloak-locale",
        ".cloak-region",
    ] {
        let path = path.join(file);
        if path.exists() {
            secure_file(&path)?;
        }
    }
    Ok(())
}

fn secure_dir_recursive(path: &Path) -> Result<()> {
    for entry in WalkDir::new(path) {
        let entry = entry.map_err(|err| io::Error::new(io::ErrorKind::Other, err))?;
        if entry.file_type().is_dir() {
            secure_dir(entry.path())?;
        } else if entry.file_type().is_file() {
            secure_file(entry.path())?;
        }
    }
    Ok(())
}

#[cfg(unix)]
fn secure_dir(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

#[cfg(not(unix))]
fn secure_dir(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn secure_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn secure_file(_path: &Path) -> Result<()> {
    Ok(())
}

fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn home_dir() -> Result<PathBuf> {
    dirs::home_dir().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "home directory").into())
}

fn default_repo_root() -> PathBuf {
    env::current_dir()
        .ok()
        .and_then(find_repo_root)
        .or_else(|| env::current_exe().ok().and_then(find_repo_root))
        .or_else(|| find_repo_root(PathBuf::from(env!("CARGO_MANIFEST_DIR"))))
        .unwrap_or_else(|| PathBuf::from("."))
}

fn find_repo_root(start: PathBuf) -> Option<PathBuf> {
    let start = if start.is_file() {
        start.parent()?.to_path_buf()
    } else {
        start
    };
    start.ancestors().find_map(|candidate| {
        let has_launcher = candidate.join("packaging/launch-account.sh").is_file();
        let has_extension = candidate.join("extension/cloak-companion").is_dir();
        (has_launcher && has_extension).then(|| candidate.to_path_buf())
    })
}

#[cfg(target_os = "macos")]
fn default_account_base(home: &Path) -> PathBuf {
    home.join("Library/Application Support/ChatGPT Cloak/Accounts")
}

#[cfg(target_os = "windows")]
fn default_account_base(_home: &Path) -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from(r"C:\Users\Default\AppData\Roaming"))
        .join("ChatGPT Cloak/Accounts")
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn default_account_base(home: &Path) -> PathBuf {
    home.join(".config/ChatGPT Cloak/Accounts")
}

fn truthy_env(key: &str) -> bool {
    env::var(key).map(|v| truthy(&v)).unwrap_or(false)
}

fn truthy(value: &str) -> bool {
    matches!(value, "1" | "on" | "true" | "yes" | "YES" | "TRUE" | "ON")
}

fn falsy(value: &str) -> bool {
    matches!(value, "0" | "off" | "false" | "no" | "NO" | "FALSE" | "OFF")
}

fn companion_page_spoof_enabled() -> bool {
    companion_page_spoof_enabled_from(
        env::var("CLOAK_COMPANION_PAGE_SPOOF").ok().as_deref(),
        env::var("CLOAK_JS_FINGERPRINT").ok().as_deref(),
    )
}

fn companion_page_spoof_enabled_from(primary: Option<&str>, legacy: Option<&str>) -> bool {
    if let Some(value) = primary {
        return !falsy(value);
    }
    if let Some(value) = legacy {
        return !falsy(value);
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_seed_matches_bash_contract() {
        assert_eq!(legacy_seed("demo-profile-88"), "90584");
        assert_eq!(legacy_seed("demo-alt-88"), "99363");
    }

    #[test]
    fn account_name_validation_matches_picker_rules() {
        assert!(validate_account_name("work_01").is_ok());
        assert!(validate_account_name("poet-quench-9i@example.test").is_ok());
        assert!(validate_account_name("poet+quench@example.test").is_ok());
        assert!(validate_account_name("main").is_err());
        assert!(validate_account_name("../x").is_err());
        assert!(validate_account_name("x\\y").is_err());
        assert!(validate_account_name("name.").is_err());
        assert!(validate_account_name("has space").is_err());
        assert!(validate_account_name(".hidden").is_err());
        assert!(validate_account_name("中文").is_err());
    }

    #[test]
    fn proxy_masking_and_mode_match_current_contract() {
        let socks = proxy_config("socks5://user:pass@example.net:1080").unwrap();
        assert_eq!(socks.mode, ProxyMode::Relay);
        assert_eq!(socks.display, "socks5://example.net:1080  (via local SOCKS5 relay)");
        assert_eq!(socks.browser_arg.as_deref(), Some(RELAY_PLACEHOLDER));

        let http = proxy_config("http://example.net:8080").unwrap();
        assert_eq!(http.mode, ProxyMode::Direct);
        assert_eq!(http.display, "http://example.net:8080");
    }

    #[test]
    fn create_and_rename_keep_seed() {
        let dir = tempfile::tempdir().unwrap();
        let config = CloakConfig {
            repo_root: dir.path().to_path_buf(),
            account_base: dir.path().join("accounts"),
            extension_source: dir.path().join("extension"),
            cloakbrowser_root: dir.path().join("browser"),
        };
        fs::create_dir_all(&config.extension_source).unwrap();
        let account = create_account(&config, "work").unwrap();
        let renamed = rename_account(&config, "work", "work2").unwrap();
        assert_eq!(account.seed, renamed.seed);
        assert_eq!(account.created_at, renamed.created_at);
        assert!(renamed.profile_path.join(".cloak-seed").exists());
        assert!(renamed.profile_path.join(".cloak-created-at").exists());
    }

    #[test]
    fn list_accounts_orders_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        let config = CloakConfig {
            repo_root: dir.path().to_path_buf(),
            account_base: dir.path().join("accounts"),
            extension_source: dir.path().join("extension"),
            cloakbrowser_root: dir.path().join("browser"),
        };
        fs::create_dir_all(&config.extension_source).unwrap();

        create_account(&config, "older").unwrap();
        create_account(&config, "newer").unwrap();
        write_secret_atomic(
            &config.profile_dir("older").join(".cloak-created-at"),
            "1000",
        )
        .unwrap();
        write_secret_atomic(
            &config.profile_dir("newer").join(".cloak-created-at"),
            "2000",
        )
        .unwrap();

        let accounts = list_accounts(&config).unwrap();
        assert_eq!(accounts[0].name, "newer");
        assert_eq!(accounts[1].name, "older");
    }

    #[test]
    fn archived_accounts_are_hidden_until_restored() {
        let dir = tempfile::tempdir().unwrap();
        let config = CloakConfig {
            repo_root: dir.path().to_path_buf(),
            account_base: dir.path().join("accounts"),
            extension_source: dir.path().join("extension"),
            cloakbrowser_root: dir.path().join("browser"),
        };
        fs::create_dir_all(&config.extension_source).unwrap();

        create_account(&config, "active").unwrap();
        create_account(&config, "parked").unwrap();
        let archived = set_account_archived(&config, "parked", true).unwrap();
        assert!(archived.archived);

        let active_accounts = list_accounts(&config).unwrap();
        assert_eq!(active_accounts.len(), 1);
        assert_eq!(active_accounts[0].name, "active");

        let archived_accounts = list_archived_accounts(&config).unwrap();
        assert_eq!(archived_accounts.len(), 1);
        assert_eq!(archived_accounts[0].name, "parked");

        let restored = set_account_archived(&config, "parked", false).unwrap();
        assert!(!restored.archived);
        assert_eq!(list_archived_accounts(&config).unwrap().len(), 0);
        assert_eq!(list_accounts(&config).unwrap().len(), 2);
    }

    #[test]
    fn locale_mapping_matches_script_table() {
        assert_eq!(language_for_country("JP"), "ja-JP");
        assert_eq!(accept_language("ja-JP"), "ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7");
        assert_eq!(accept_language("en-US"), "en-US,en;q=0.9");
    }

    #[test]
    fn native_fingerprint_args_follow_cloakbrowser_wrapper_contract() {
        let mut argv = Vec::new();
        let engine = EngineVersion::fallback();
        append_native_fingerprint_args(
            &mut argv,
            &GeoPlan {
                exit_ip: Some("203.0.113.24".to_string()),
                country: Some("JP".to_string()),
                timezone: Some("Asia/Tokyo".to_string()),
            },
            Some("ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7"),
            &engine,
            "54321",
        );

        let expected: Vec<String> = vec![
            "--fingerprint-timezone=Asia/Tokyo",
            "--lang=ja-JP",
            "--fingerprint-locale=ja-JP",
            "--accept-lang=ja-JP,ja;q=0.9,en-US;q=0.8,en;q=0.7",
            "--fingerprint-webrtc-ip=203.0.113.24",
            "--fingerprint-brand-version=145.0.0.0",
            "--fingerprint-platform-version=15.5.0",
            "--fingerprint-gpu-vendor=Google Inc. (Apple)",
        ]
        .into_iter()
        .map(String::from)
        .chain(std::iter::once(format!(
            "--fingerprint-gpu-renderer={}",
            gpu_renderer_for_seed("54321")
        )))
        .collect::<Vec<_>>();
        assert_eq!(argv, expected);
    }

    #[test]
    fn skip_geo_locale_does_not_invent_accept_language() {
        let dir = tempfile::tempdir().unwrap();
        let config = CloakConfig {
            repo_root: dir.path().to_path_buf(),
            account_base: dir.path().join("accounts"),
            extension_source: dir.path().join("extension"),
            cloakbrowser_root: dir.path().join("browser"),
        };
        fs::create_dir_all(&config.extension_source).unwrap();
        let browser = config
            .cloakbrowser_root
            .join(current_browser_relative_path());
        fs::create_dir_all(browser.parent().unwrap()).unwrap();
        fs::write(&browser, "").unwrap();
        let profile = config.profile_dir("work");
        fs::create_dir_all(&profile).unwrap();
        fs::write(profile.join(".cloak-locale"), "").unwrap();

        let plan = build_launch_plan(
            &config,
            "work",
            &LaunchOptions {
                dry_run: true,
                skip_geo: true,
                ..LaunchOptions::default()
            },
        )
        .unwrap();

        assert_eq!(plan.locale, None);
        assert!(plan
            .argv
            .iter()
            .any(|arg| arg.starts_with("--load-extension=")));
        assert!(plan
            .argv
            .iter()
            .any(|arg| arg.starts_with("--disable-extensions-except=")));
        assert!(plan.argv.iter().any(|arg| arg == "--ignore-gpu-blocklist"));
        assert!(!plan
            .argv
            .iter()
            .any(|arg| arg.starts_with("--accept-lang=")));
        assert!(plan.privacy_failures.is_empty());
    }

    #[test]
    fn running_profile_detection_uses_exact_user_data_dir_arg() {
        let profile = Path::new("/tmp/Cloak Accounts/work");
        let needle = user_data_dir_needle(profile);
        assert!(command_line_mentions_user_data_dir(
            "/Applications/Chromium --user-data-dir=/tmp/Cloak Accounts/work --fingerprint=12345",
            &needle,
        ));
        assert!(!command_line_mentions_user_data_dir(
            "/Applications/Chromium --user-data-dir=/tmp/Cloak Accounts/work2 --fingerprint=12345",
            &needle,
        ));
    }

    #[test]
    fn extra_extension_slug_matches_bash_contract() {
        assert_eq!(slug_for_path(Path::new("删除Cookies.crx")), "Cookies.crx");
        assert_eq!(
            slug_for_path(Path::new("沉浸式翻译 - AI 双语网页翻译 _ PDF翻译 _ 视频翻译 _ 漫画翻译 1.30.1.crx")),
            "-_AI_PDF_1.30.1.crx"
        );
    }

    #[test]
    fn companion_page_spoof_is_enabled_by_default_for_current_binary() {
        assert!(companion_page_spoof_enabled_from(None, None));
        assert!(companion_page_spoof_enabled_from(Some("1"), None));
        assert!(companion_page_spoof_enabled_from(None, Some("1")));
        assert!(!companion_page_spoof_enabled_from(Some("0"), None));
        assert!(!companion_page_spoof_enabled_from(None, Some("false")));
        assert!(!companion_page_spoof_enabled_from(Some("OFF"), Some("1")));
    }

    #[test]
    fn chromium_version_parsing_handles_standard_output() {
        let v = parse_chromium_version("Chromium 145.0.7632.109").unwrap();
        assert_eq!(v.major, "145");
        assert_eq!(v.full, "145.0.7632.109");

        let v2 = parse_chromium_version("Chromium.app 149.0.7700.0 Something").unwrap();
        assert_eq!(v2.major, "149");
        assert_eq!(v2.full, "149.0.7700.0");
    }

    #[test]
    fn chromium_version_parsing_returns_none_for_no_version() {
        assert!(parse_chromium_version("no version here").is_none());
        assert!(parse_chromium_version("").is_none());
    }

    #[test]
    fn extract_version_from_path_finds_chromium_dir() {
        let path = Path::new("/home/user/.cloakbrowser/chromium-145/Chromium.app/Contents/MacOS/Chromium");
        let v = extract_version_from_path(path).unwrap();
        assert_eq!(v.major, "145");

        let path2 = Path::new("/home/user/.cloakbrowser/chromium-149/chrome");
        let v2 = extract_version_from_path(path2).unwrap();
        assert_eq!(v2.major, "149");
    }

    #[test]
    fn gpu_renderer_pool_is_deterministic_and_diverse() {
        // Same seed → same renderer
        let r1 = gpu_renderer_for_seed("54321");
        let r2 = gpu_renderer_for_seed("54321");
        assert_eq!(r1, r2);

        // Different seeds should hit different renderers (with 4 slots, 5 tries should get ≥2)
        let mut seen = std::collections::HashSet::new();
        for seed in &["11111", "22222", "33333", "44444", "54321"] {
            seen.insert(gpu_renderer_for_seed(seed));
        }
        assert!(seen.len() >= 2, "GPU pool collision too high: only {} unique from 5 seeds", seen.len());

        // All renderers use the real Apple-Silicon Metal format (not the Intel-Mac
        // OpenGL backend) — matching what the live binary actually reports.
        for seed in &["10000", "50000", "99999", "12345"] {
            let r = gpu_renderer_for_seed(seed);
            assert!(
                r.starts_with("ANGLE (Apple, ANGLE Metal Renderer: Apple M")
                    && r.ends_with(", Unspecified Version)"),
                "unexpected renderer format: {r}"
            );
        }
    }

    #[test]
    fn companion_prepare_writes_seed_and_keeps_page_scripts_when_enabled() {
        let dir = tempfile::tempdir().unwrap();
        let extension_source = dir.path().join("extension");
        fs::create_dir_all(&extension_source).unwrap();
        fs::write(
            extension_source.join("manifest.json"),
            r#"{
              "manifest_version": 3,
              "permissions": ["storage", "scripting", "tabs"],
              "host_permissions": ["<all_urls>"],
              "background": { "service_worker": "background.js" },
              "content_scripts": [{ "matches": ["https://*/*"], "js": ["account-seed-main.js", "spoof.js"] }]
            }"#,
        )
        .unwrap();

        let config = CloakConfig {
            repo_root: dir.path().to_path_buf(),
            account_base: dir.path().join("accounts"),
            extension_source,
            cloakbrowser_root: dir.path().join("browser"),
        };
        let profile_path = config.profile_dir("work");
        let plan = LaunchPlan {
            account: "work".to_string(),
            seed: "28041".to_string(),
            profile_path: profile_path.clone(),
            extension_runtime_path: profile_path.join(".cloak-companion"),
            load_extension_paths: Vec::new(),
            extra_extension_paths: Vec::new(),
            selftest_extension_paths: Vec::new(),
            browser_binary: dir.path().join("browser/Chromium"),
            proxy: ProxyPlan {
                mode: ProxyMode::None,
                display: "off".to_string(),
                browser_arg: None,
                relay_needed: false,
                raw_url: None,
            },
            geo: GeoPlan {
                exit_ip: None,
                country: None,
                timezone: None,
            },
            locale: None,
            browser_identity: browser_identity_plan(&EngineVersion::fallback()),
            argv: Vec::new(),
            privacy_failures: Vec::new(),
        };

        prepare_companion_extension(&config, &plan, true).unwrap();

        assert_eq!(
            fs::read_to_string(plan.extension_runtime_path.join("account-seed-main.js")).unwrap(),
            "window.__cloakAccountSeed = \"28041\";\n"
        );
        assert!(fs::read_to_string(plan.extension_runtime_path.join("browser-identity-main.js"))
            .unwrap()
            .contains("Chrome/145.0.0.0"));
        let header_rules: Value = serde_json::from_str(
            &fs::read_to_string(
                plan.extension_runtime_path
                    .join("rules/browser-identity-headers.json"),
            )
            .unwrap(),
        )
        .unwrap();
        assert!(header_rules.to_string().contains("Sec-CH-UA"));
        let manifest: Value =
            serde_json::from_str(&fs::read_to_string(plan.extension_runtime_path.join("manifest.json")).unwrap())
                .unwrap();
        assert!(manifest.get("content_scripts").is_some());
        assert!(manifest.get("host_permissions").is_some());
        assert!(manifest.get("background").is_some());
    }

    #[test]
    fn companion_manifest_strips_page_scripts_when_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = dir.path().join("manifest.json");
        fs::write(
            &manifest,
            r#"{
              "manifest_version": 3,
	              "permissions": ["storage", "scripting", "tabs"],
	              "host_permissions": ["<all_urls>"],
	              "background": { "service_worker": "background.js" },
	              "declarative_net_request": { "rule_resources": [] },
	              "content_scripts": [{ "matches": ["https://*/*"], "js": ["spoof.js"] }]
	            }"#,
        )
        .unwrap();

        strip_companion_page_scripts(&manifest).unwrap();
        let stripped: Value = serde_json::from_str(&fs::read_to_string(&manifest).unwrap()).unwrap();
        assert!(stripped.get("content_scripts").is_none());
        assert!(stripped.get("host_permissions").is_none());
        assert!(stripped.get("background").is_none());
        assert!(stripped.get("declarative_net_request").is_none());
        assert_eq!(stripped.get("permissions").unwrap(), &Value::Array(vec![Value::String("storage".to_string())]));
    }

    #[test]
    fn extra_extension_plan_skips_immersive_translate_default() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("plugins");
        fs::create_dir_all(root.join("Chromium Web Store 插件")).unwrap();
        fs::write(root.join("Chromium Web Store 插件/manifest.json"), "{}").unwrap();
        fs::create_dir_all(root.join("get-cookies.txt-locally_v0.7.2_chrome")).unwrap();
        fs::write(root.join("get-cookies.txt-locally_v0.7.2_chrome/manifest.json"), "{}").unwrap();
        fs::write(root.join("删除Cookies.crx"), "placeholder").unwrap();
        fs::write(
            root.join("沉浸式翻译 - AI 双语网页翻译 _ PDF翻译 _ 视频翻译 _ 漫画翻译 1.30.1.crx"),
            "placeholder",
        )
        .unwrap();

        let old_root = env::var_os("CLOAK_EXTRA_EXTENSIONS_DIR");
        let old_enabled = env::var_os("CLOAK_EXTRA_EXTENSIONS");
        env::set_var("CLOAK_EXTRA_EXTENSIONS_DIR", &root);
        env::remove_var("CLOAK_EXTRA_EXTENSIONS");

        let profile = dir.path().join("account");
        let companion = profile.join(".cloak-companion");
        let plan = discover_extra_extensions(
            &CloakConfig {
                repo_root: dir.path().to_path_buf(),
                account_base: dir.path().join("accounts"),
                extension_source: dir.path().join("extension"),
                cloakbrowser_root: dir.path().join("browser"),
            },
            &profile,
            &companion,
        )
        .unwrap();

        if let Some(value) = old_root {
            env::set_var("CLOAK_EXTRA_EXTENSIONS_DIR", value);
        } else {
            env::remove_var("CLOAK_EXTRA_EXTENSIONS_DIR");
        }
        if let Some(value) = old_enabled {
            env::set_var("CLOAK_EXTRA_EXTENSIONS", value);
        } else {
            env::remove_var("CLOAK_EXTRA_EXTENSIONS");
        }

        assert_eq!(plan.load_extension_paths.len(), 4);
        assert_eq!(plan.extra_extension_paths.len(), 3);
        assert_eq!(plan.selftest_extension_paths.len(), 2);
        let load_extensions = join_extension_paths(&plan.load_extension_paths);
        assert!(!load_extensions.contains("-_AI_PDF_1.30.1.crx"));
        let selftest = join_extension_paths(&plan.selftest_extension_paths);
        assert!(selftest.contains("get-cookies.txt-locally_v0.7.2_chrome"));
        assert!(selftest.contains("Cookies.crx"));
        assert!(!selftest.contains("Chromium Web Store"));
        assert!(!selftest.contains("-_AI_PDF_1.30.1.crx"));
    }
}
