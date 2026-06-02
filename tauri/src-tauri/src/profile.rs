use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::fingerprint::FingerprintProfile;

pub const DEFAULT_PROFILE_ID: &str = "default";
const PROFILES_DIR: &str = "profiles";
const PROFILES_JSON: &str = "profiles.json";
const META_JSON: &str = "meta.json";
const WEBVIEW_DATA_DIR: &str = "webview-data";
const CURRENT_META_VERSION: u32 = 2;

/// Persisted list of profiles and current selection.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfilesManifest {
    pub profiles: Vec<WebProfile>,
    pub current_profile_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_profile_id: Option<String>,
}

/// A single account space.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WebProfile {
    pub id: String,
    pub name: String,
    pub created_at: u64,
}

/// Per-profile metadata stored in `meta.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileMeta {
    #[serde(default)]
    pub meta_version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<FingerprintProfile>,
    #[serde(default)]
    pub fingerprint_disabled: bool,
    #[serde(default)]
    pub enhanced_privacy: bool,
    /// Whether WebRTC blocker is enabled for this profile.
    #[serde(default)]
    pub webrtc_enabled: bool,
}

impl Default for ProfileMeta {
    fn default() -> Self {
        Self {
            meta_version: CURRENT_META_VERSION,
            homepage: None,
            fingerprint: None,
            fingerprint_disabled: false,
            enhanced_privacy: false,
            webrtc_enabled: false,
        }
    }
}

/// Thread-safe profile store backed by filesystem.
pub struct ProfileStore {
    base_dir: PathBuf,
    inner: Mutex<ProfilesManifest>,
}

impl ProfileStore {
    /// Initialize the profile store from the Tauri app data directory.
    /// Creates the default profile if it doesn't exist.
    pub fn new(app_data_dir: &Path) -> Result<Self, String> {
        let base_dir = app_data_dir.join(PROFILES_DIR);
        fs::create_dir_all(&base_dir)
            .map_err(|e| format!("failed to create profiles directory: {e}"))?;

        let manifest_path = base_dir.join(PROFILES_JSON);
        let manifest = if manifest_path.exists() {
            let data = fs::read_to_string(&manifest_path)
                .map_err(|e| format!("failed to read profiles.json: {e}"))?;
            let mut m: ProfilesManifest =
                serde_json::from_str(&data).unwrap_or_else(|_| Self::default_manifest());
            // Ensure default profile always exists
            if !m.profiles.iter().any(|p| p.id == DEFAULT_PROFILE_ID) {
                m.profiles.insert(0, Self::default_profile());
            }
            // Ensure current_profile_id points to a valid profile
            if !m.profiles.iter().any(|p| p.id == m.current_profile_id) {
                m.current_profile_id = DEFAULT_PROFILE_ID.to_string();
            }
            if let Some(default_id) = m.default_profile_id.clone() {
                if m.profiles.iter().any(|p| p.id == default_id) {
                    m.current_profile_id = default_id;
                } else {
                    m.default_profile_id = None;
                }
            }
            m
        } else {
            let m = Self::default_manifest();
            Self::persist_manifest(&base_dir, &m)?;
            m
        };

        // Ensure default profile directory exists
        let default_dir = base_dir.join(DEFAULT_PROFILE_ID);
        fs::create_dir_all(default_dir.join(WEBVIEW_DATA_DIR))
            .map_err(|e| format!("failed to create default profile directory: {e}"))?;
        Self::migrate_profile_meta_defaults(&base_dir, &manifest.profiles)?;

        Ok(Self {
            base_dir,
            inner: Mutex::new(manifest),
        })
    }

    /// List all profiles.
    pub fn list_profiles(&self) -> Vec<WebProfile> {
        let m = self.inner.lock().unwrap();
        m.profiles.clone()
    }

    /// Get the current profile.
    pub fn current_profile(&self) -> WebProfile {
        let m = self.inner.lock().unwrap();
        let id = &m.current_profile_id;
        m.profiles
            .iter()
            .find(|p| &p.id == id)
            .cloned()
            .unwrap_or_else(|| Self::default_profile())
    }

    /// Get the current profile ID.
    pub fn current_profile_id(&self) -> String {
        let m = self.inner.lock().unwrap();
        m.current_profile_id.clone()
    }

    /// Get the user-selected startup profile ID. Falls back to the built-in default profile.
    pub fn default_profile_id(&self) -> String {
        let m = self.inner.lock().unwrap();
        m.default_profile_id
            .as_ref()
            .filter(|id| m.profiles.iter().any(|p| &p.id == *id))
            .cloned()
            .unwrap_or_else(|| DEFAULT_PROFILE_ID.to_string())
    }

    /// Mark a profile as the startup default and move it to the first menu position.
    pub fn set_default_profile(&self, id: &str) -> Result<WebProfile, String> {
        let mut m = self.inner.lock().unwrap();
        let idx = m
            .profiles
            .iter()
            .position(|p| p.id == id)
            .ok_or_else(|| format!("profile '{id}' not found"))?;
        let profile = m.profiles.remove(idx);
        m.profiles.insert(0, profile.clone());
        m.default_profile_id = Some(id.to_string());
        m.current_profile_id = id.to_string();
        Self::persist_manifest(&self.base_dir, &m)?;
        Ok(profile)
    }

    /// Switch to a different profile. Returns the new profile.
    pub fn switch_profile(&self, id: &str) -> Result<WebProfile, String> {
        let mut m = self.inner.lock().unwrap();
        let profile = m
            .profiles
            .iter()
            .find(|p| p.id == id)
            .cloned()
            .ok_or_else(|| format!("profile '{id}' not found"))?;
        m.current_profile_id = id.to_string();
        Self::persist_manifest(&self.base_dir, &m)?;
        Ok(profile)
    }

    /// Create a new profile. Returns the created profile.
    pub fn create_profile(&self, name: &str) -> Result<WebProfile, String> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err("profile name cannot be empty".to_string());
        }

        let mut m = self.inner.lock().unwrap();

        // Check name uniqueness (case-insensitive)
        let lower = name.to_lowercase();
        if m.profiles.iter().any(|p| p.name.to_lowercase() == lower) {
            return Err(format!("profile '{name}' already exists"));
        }

        let id = Uuid::new_v4().to_string();
        let profile = WebProfile {
            id: id.clone(),
            name,
            created_at: now_secs(),
        };

        // Create profile directory
        let profile_dir = self.base_dir.join(&id);
        fs::create_dir_all(profile_dir.join(WEBVIEW_DATA_DIR))
            .map_err(|e| format!("failed to create profile directory: {e}"))?;

        // Write default meta.json with native WebKit/Safari fingerprinting.
        let meta = ProfileMeta {
            fingerprint: None,
            fingerprint_disabled: true,
            enhanced_privacy: false,
            webrtc_enabled: false,
            ..Default::default()
        };
        Self::write_meta(&profile_dir, &meta)?;

        m.profiles.push(profile.clone());
        Self::persist_manifest(&self.base_dir, &m)?;

        Ok(profile)
    }

    /// Rename a profile.
    pub fn rename_profile(&self, id: &str, new_name: &str) -> Result<(), String> {
        let new_name = new_name.trim().to_string();
        if new_name.is_empty() {
            return Err("profile name cannot be empty".to_string());
        }

        let mut m = self.inner.lock().unwrap();
        let lower = new_name.to_lowercase();
        if m.profiles.iter().any(|p| p.id != id && p.name.to_lowercase() == lower) {
            return Err(format!("profile '{new_name}' already exists"));
        }

        let profile = m
            .profiles
            .iter_mut()
            .find(|p| p.id == id)
            .ok_or_else(|| format!("profile '{id}' not found"))?;
        profile.name = new_name;
        Self::persist_manifest(&self.base_dir, &m)?;
        Ok(())
    }

    /// Delete a profile and its data directory. Cannot delete the default profile.
    pub fn delete_profile(&self, id: &str) -> Result<(), String> {
        if id == DEFAULT_PROFILE_ID {
            return Err("cannot delete the default profile".to_string());
        }

        let mut m = self.inner.lock().unwrap();
        let idx = m
            .profiles
            .iter()
            .position(|p| p.id == id)
            .ok_or_else(|| format!("profile '{id}' not found"))?;
        m.profiles.remove(idx);

        // If we just deleted the current profile, fall back to default
        if m.current_profile_id == id {
            m.current_profile_id = DEFAULT_PROFILE_ID.to_string();
        }
        if m.default_profile_id.as_deref() == Some(id) {
            m.default_profile_id = None;
        }

        Self::persist_manifest(&self.base_dir, &m)?;

        // Remove profile directory (best-effort)
        let profile_dir = self.base_dir.join(id);
        let _ = fs::remove_dir_all(profile_dir);

        Ok(())
    }

    /// Get profile metadata.
    pub fn get_meta(&self, profile_id: &str) -> ProfileMeta {
        let profile_dir = self.base_dir.join(profile_id);
        let meta_path = profile_dir.join(META_JSON);
        if meta_path.exists() {
            Self::read_meta(&profile_dir).unwrap_or_default()
        } else {
            ProfileMeta::default()
        }
    }

    /// Update profile metadata.
    pub fn set_meta(&self, profile_id: &str, meta: &ProfileMeta) -> Result<(), String> {
        let profile_dir = self.base_dir.join(profile_id);
        Self::write_meta(&profile_dir, meta)
    }

    /// Get the homepage URL for a profile. Falls back to ChatGPT default.
    pub fn homepage_url(&self, profile_id: &str) -> String {
        let meta = self.get_meta(profile_id);
        meta.homepage
            .filter(|h| h.starts_with("https://"))
            .unwrap_or_else(|| "https://chatgpt.com/".to_string())
    }

    /// Set the homepage for a profile.
    pub fn set_homepage(&self, profile_id: &str, url: &str) -> Result<(), String> {
        let mut meta = self.get_meta(profile_id);
        if url.is_empty() {
            meta.homepage = None;
        } else {
            // Validate URL: must be https, have a valid host, no control characters
            let parsed = tauri::Url::parse(url)
                .map_err(|_| format!("invalid URL: {url}"))?;
            if parsed.scheme() != "https" {
                return Err("only https:// URLs are supported".to_string());
            }
            let host = parsed.host_str()
                .ok_or_else(|| "URL must have a host".to_string())?;
            if host.is_empty() || !host.contains('.') {
                return Err("URL must have a valid host".to_string());
            }
            // Reject URLs with control characters
            if url.chars().any(|c| c.is_control()) {
                return Err("URL contains invalid characters".to_string());
            }
            meta.homepage = Some(url.to_string());
        }
        self.set_meta(profile_id, &meta)
    }

    /// Get the webview data directory for a profile.
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    pub fn webview_data_dir(&self, profile_id: &str) -> PathBuf {
        self.base_dir.join(profile_id).join(WEBVIEW_DATA_DIR)
    }

    /// Clone a profile: copies name base, homepage, enhanced privacy, webrtc setting.
    /// Fingerprint spoofing stays disabled for the clone unless the user enables it later.
    /// Returns (new_profile, source_meta) so caller can optionally copy cookies.
    pub fn clone_profile(&self, source_id: &str, new_name: &str) -> Result<(WebProfile, ProfileMeta), String> {
        let source_meta = self.get_meta(source_id);
        let source_name = {
            let m = self.inner.lock().unwrap();
            m.profiles
                .iter()
                .find(|p| p.id == source_id)
                .map(|p| p.name.clone())
                .unwrap_or_else(|| "空间".to_string())
        };

        let name = if new_name.trim().is_empty() {
            self.unique_name(&format!("{source_name} 副本"))
        } else {
            let trimmed = new_name.trim().to_string();
            // Check uniqueness
            let m = self.inner.lock().unwrap();
            let lower = trimmed.to_lowercase();
            if m.profiles.iter().any(|p| p.name.to_lowercase() == lower) {
                self.unique_name(&trimmed)
            } else {
                trimmed
            }
        };

        let profile = self.create_profile(&name)?;

        // Copy homepage, enhanced privacy, webrtc from source. Keep native fingerprinting.
        let mut new_meta = self.get_meta(&profile.id);
        new_meta.homepage = source_meta.homepage.clone();
        new_meta.fingerprint = None;
        new_meta.fingerprint_disabled = true;
        new_meta.enhanced_privacy = source_meta.enhanced_privacy;
        new_meta.webrtc_enabled = source_meta.webrtc_enabled;
        self.set_meta(&profile.id, &new_meta)?;

        Ok((profile, source_meta))
    }

    /// Generate a unique profile name by appending a number suffix.
    fn unique_name(&self, base: &str) -> String {
        let m = self.inner.lock().unwrap();
        let lower_base = base.to_lowercase();
        if !m.profiles.iter().any(|p| p.name.to_lowercase() == lower_base) {
            return base.to_string();
        }
        for i in 2..1000 {
            let candidate = format!("{base} {i}");
            let lower = candidate.to_lowercase();
            if !m.profiles.iter().any(|p| p.name.to_lowercase() == lower) {
                return candidate;
            }
        }
        format!("{base} {}", now_secs())
    }

    // --- private helpers ---

    fn default_profile() -> WebProfile {
        WebProfile {
            id: DEFAULT_PROFILE_ID.to_string(),
            name: "默认".to_string(),
            created_at: 0,
        }
    }

    fn default_manifest() -> ProfilesManifest {
        ProfilesManifest {
            profiles: vec![Self::default_profile()],
            current_profile_id: DEFAULT_PROFILE_ID.to_string(),
            default_profile_id: None,
        }
    }

    fn persist_manifest(base_dir: &Path, manifest: &ProfilesManifest) -> Result<(), String> {
        let path = base_dir.join(PROFILES_JSON);
        let json = serde_json::to_string_pretty(manifest)
            .map_err(|e| format!("failed to serialize profiles: {e}"))?;
        Self::atomic_write_string(&path, &json)
            .map_err(|e| format!("failed to write profiles.json: {e}"))
    }

    fn read_meta(profile_dir: &Path) -> Option<ProfileMeta> {
        let path = profile_dir.join(META_JSON);
        fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
    }

    fn write_meta(profile_dir: &Path, meta: &ProfileMeta) -> Result<(), String> {
        fs::create_dir_all(profile_dir)
            .map_err(|e| format!("failed to create profile directory: {e}"))?;
        let path = profile_dir.join(META_JSON);
        let json = serde_json::to_string_pretty(meta)
            .map_err(|e| format!("failed to serialize meta: {e}"))?;
        Self::atomic_write_string(&path, &json)
            .map_err(|e| format!("failed to write meta.json: {e}"))
    }

    fn atomic_write_string(path: &Path, contents: &str) -> std::io::Result<()> {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        let filename = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("profile-data");
        let temp_path = parent.join(format!(".{filename}.{}.tmp", Uuid::new_v4()));
        fs::write(&temp_path, contents)?;
        fs::rename(&temp_path, path).or_else(|error| {
            let _ = fs::remove_file(&temp_path);
            Err(error)
        })
    }

    fn migrate_profile_meta_defaults(
        base_dir: &Path,
        profiles: &[WebProfile],
    ) -> Result<(), String> {
        for profile in profiles {
            let profile_dir = base_dir.join(&profile.id);
            let meta_path = profile_dir.join(META_JSON);
            if !meta_path.exists() {
                continue;
            }
            let Some(mut meta) = Self::read_meta(&profile_dir) else {
                continue;
            };
            if meta.meta_version >= CURRENT_META_VERSION {
                continue;
            }
            meta.webrtc_enabled = false;
            meta.meta_version = CURRENT_META_VERSION;
            Self::write_meta(&profile_dir, &meta)?;
        }
        Ok(())
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Exported profile configuration (for import/export JSON).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileExportDocument {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u32,
    #[serde(rename = "exportedAt")]
    pub exported_at: String,
    #[serde(rename = "sourceProfileID")]
    pub source_profile_id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fingerprint: Option<FingerprintProfile>,
    #[serde(rename = "fingerprintDisabled", skip_serializing_if = "Option::is_none")]
    pub fingerprint_disabled: Option<bool>,
    #[serde(rename = "enhancedPrivacyEnabled", default)]
    pub enhanced_privacy_enabled: bool,
    #[serde(rename = "webrtcEnabled", default, skip_serializing_if = "Option::is_none")]
    pub webrtc_enabled: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_store() -> (ProfileStore, TempDir) {
        let dir = TempDir::new().unwrap();
        let store = ProfileStore::new(dir.path()).unwrap();
        (store, dir)
    }

    #[test]
    fn default_profile_always_exists() {
        let (store, _dir) = make_store();
        let profiles = store.list_profiles();
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].id, DEFAULT_PROFILE_ID);
        assert_eq!(profiles[0].name, "默认");
    }

    #[test]
    fn current_profile_defaults_to_default() {
        let (store, _dir) = make_store();
        assert_eq!(store.current_profile_id(), DEFAULT_PROFILE_ID);
    }

    #[test]
    fn create_and_switch_profile() {
        let (store, _dir) = make_store();
        let p = store.create_profile("工作号").unwrap();
        assert_eq!(p.name, "工作号");
        assert_ne!(p.id, DEFAULT_PROFILE_ID);

        store.switch_profile(&p.id).unwrap();
        assert_eq!(store.current_profile_id(), p.id);
    }

    #[test]
    fn reject_duplicate_name() {
        let (store, _dir) = make_store();
        store.create_profile("Test").unwrap();
        let err = store.create_profile("test").unwrap_err();
        assert!(err.contains("already exists"));
    }

    #[test]
    fn rename_profile() {
        let (store, _dir) = make_store();
        let p = store.create_profile("Old").unwrap();
        store.rename_profile(&p.id, "New").unwrap();
        let profiles = store.list_profiles();
        let renamed = profiles.iter().find(|pp| pp.id == p.id).unwrap();
        assert_eq!(renamed.name, "New");
    }

    #[test]
    fn can_rename_default_but_not_delete_it() {
        let (store, _dir) = make_store();
        store.rename_profile(DEFAULT_PROFILE_ID, "主空间").unwrap();
        let profiles = store.list_profiles();
        let default_profile = profiles
            .iter()
            .find(|pp| pp.id == DEFAULT_PROFILE_ID)
            .unwrap();
        assert_eq!(default_profile.name, "主空间");
        assert!(store.delete_profile(DEFAULT_PROFILE_ID).is_err());
    }

    #[test]
    fn delete_profile_falls_back_to_default() {
        let (store, _dir) = make_store();
        let p = store.create_profile("Temp").unwrap();
        store.switch_profile(&p.id).unwrap();
        store.delete_profile(&p.id).unwrap();
        assert_eq!(store.current_profile_id(), DEFAULT_PROFILE_ID);
    }

    #[test]
    fn delete_profile_removes_only_requested_profile() {
        let (store, _dir) = make_store();
        let first = store.create_profile("First").unwrap();
        let second = store.create_profile("Second").unwrap();

        store.delete_profile(&first.id).unwrap();
        let profiles = store.list_profiles();
        assert!(!profiles.iter().any(|profile| profile.id == first.id));
        assert!(profiles.iter().any(|profile| profile.id == second.id));

        store.delete_profile(&second.id).unwrap();
        let profiles = store.list_profiles();
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].id, DEFAULT_PROFILE_ID);
    }

    #[test]
    fn set_default_profile_reorders_and_reopens_as_current() {
        let dir = TempDir::new().unwrap();
        let store = ProfileStore::new(dir.path()).unwrap();
        let first = store.create_profile("First").unwrap();
        let second = store.create_profile("Second").unwrap();

        store.set_default_profile(&second.id).unwrap();
        let profiles = store.list_profiles();
        assert_eq!(profiles[0].id, second.id);
        assert_eq!(store.default_profile_id(), second.id);
        drop(store);

        let reopened = ProfileStore::new(dir.path()).unwrap();
        assert_eq!(reopened.current_profile_id(), second.id);
        assert_eq!(reopened.list_profiles()[0].id, second.id);
        assert!(reopened.delete_profile(&first.id).is_ok());
    }

    #[test]
    fn homepage_roundtrip() {
        let (store, _dir) = make_store();
        let p = store.create_profile("HP").unwrap();
        assert_eq!(store.homepage_url(&p.id), "https://chatgpt.com/");
        store.set_homepage(&p.id, "https://example.com/").unwrap();
        assert_eq!(store.homepage_url(&p.id), "https://example.com/");
        store.set_homepage(&p.id, "").unwrap();
        assert_eq!(store.homepage_url(&p.id), "https://chatgpt.com/");
    }

    #[test]
    fn reject_non_https_homepage() {
        let (store, _dir) = make_store();
        assert!(store.set_homepage(DEFAULT_PROFILE_ID, "http://example.com").is_err());
    }

    #[test]
    fn meta_enhanced_privacy_defaults_false() {
        let (store, _dir) = make_store();
        let meta = store.get_meta(DEFAULT_PROFILE_ID);
        assert!(!meta.enhanced_privacy);
    }

    #[test]
    fn clone_profile_copies_settings() {
        let (store, _dir) = make_store();
        store.set_homepage(DEFAULT_PROFILE_ID, "https://example.com/").unwrap();
        let mut meta = store.get_meta(DEFAULT_PROFILE_ID);
        meta.enhanced_privacy = false;
        store.set_meta(DEFAULT_PROFILE_ID, &meta).unwrap();

        let (clone, _) = store.clone_profile(DEFAULT_PROFILE_ID, "").unwrap();
        let clone_meta = store.get_meta(&clone.id);
        assert_eq!(clone_meta.homepage, Some("https://example.com/".to_string()));
        assert!(!clone_meta.enhanced_privacy);
        assert_ne!(clone.id, DEFAULT_PROFILE_ID);
    }

    #[test]
    fn new_profile_defaults_to_native_fingerprint() {
        let (store, _dir) = make_store();
        let p = store.create_profile("FP Test").unwrap();
        let meta = store.get_meta(&p.id);
        assert!(meta.fingerprint.is_none());
        assert!(meta.fingerprint_disabled);
    }

    #[test]
    fn clone_defaults_to_native_fingerprint() {
        let (store, _dir) = make_store();
        let source_meta = store.get_meta(DEFAULT_PROFILE_ID);
        // Ensure source has a fingerprint
        let mut meta = source_meta.clone();
        meta.fingerprint = Some(crate::fingerprint::random_fingerprint());
        store.set_meta(DEFAULT_PROFILE_ID, &meta).unwrap();

        let (clone, _) = store.clone_profile(DEFAULT_PROFILE_ID, "").unwrap();
        let clone_meta = store.get_meta(&clone.id);
        assert!(store.get_meta(DEFAULT_PROFILE_ID).fingerprint.is_some());
        assert!(clone_meta.fingerprint.is_none());
        assert!(clone_meta.fingerprint_disabled);
    }

    #[test]
    fn webrtc_defaults_to_disabled() {
        let (store, _dir) = make_store();
        let meta = store.get_meta(DEFAULT_PROFILE_ID);
        assert!(!meta.webrtc_enabled);
        let p = store.create_profile("No RTC").unwrap();
        let new_meta = store.get_meta(&p.id);
        assert!(!new_meta.webrtc_enabled);
    }

    #[test]
    fn legacy_webrtc_default_migrates_to_disabled_once() {
        let dir = TempDir::new().unwrap();
        let store = ProfileStore::new(dir.path()).unwrap();
        let p = store.create_profile("Legacy RTC").unwrap();
        drop(store);

        let meta_path = dir
            .path()
            .join(PROFILES_DIR)
            .join(&p.id)
            .join(META_JSON);
        std::fs::write(
            &meta_path,
            r#"{"enhanced_privacy":false,"webrtc_enabled":true}"#,
        )
        .unwrap();

        let reopened = ProfileStore::new(dir.path()).unwrap();
        let meta = reopened.get_meta(&p.id);
        assert!(!meta.webrtc_enabled);
        assert_eq!(meta.meta_version, CURRENT_META_VERSION);

        let mut meta = reopened.get_meta(&p.id);
        meta.webrtc_enabled = true;
        reopened.set_meta(&p.id, &meta).unwrap();
        drop(reopened);

        let reopened = ProfileStore::new(dir.path()).unwrap();
        let meta = reopened.get_meta(&p.id);
        assert!(meta.webrtc_enabled);
        assert_eq!(meta.meta_version, CURRENT_META_VERSION);
    }

    #[test]
    fn profile_export_document_allows_missing_privacy_fields() {
        let json = r#"{
          "schemaVersion": 1,
          "exportedAt": "0",
          "sourceProfileID": "default",
          "name": "导入空间"
        }"#;
        let doc: ProfileExportDocument = serde_json::from_str(json).unwrap();
        assert!(!doc.enhanced_privacy_enabled);
        assert_eq!(doc.webrtc_enabled, None);
    }

    #[test]
    fn persists_across_reopen() {
        let dir = TempDir::new().unwrap();
        let store = ProfileStore::new(dir.path()).unwrap();
        let p = store.create_profile("Persist").unwrap();
        drop(store);

        let store2 = ProfileStore::new(dir.path()).unwrap();
        let profiles = store2.list_profiles();
        assert!(profiles.iter().any(|pp| pp.id == p.id));
    }
}
