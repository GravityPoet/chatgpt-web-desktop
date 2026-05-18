use serde::{Deserialize, Serialize};

/// Cookie JSON schema — compatible with Swift's ExportedBrowserCookie.
/// Used for import/export between Swift and Rust/Tauri versions.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportedCookie {
    pub domain: String,
    pub name: String,
    pub value: String,
    #[serde(default = "default_path")]
    pub path: String,
    #[serde(default)]
    pub secure: Option<bool>,
    #[serde(default, rename = "httpOnly")]
    pub http_only: Option<bool>,
    #[serde(default)]
    pub session: Option<bool>,
    #[serde(default, rename = "hostOnly")]
    pub host_only: Option<bool>,
    #[serde(default, rename = "expirationDate")]
    pub expiration_date: Option<f64>,
    #[serde(default, rename = "sameSite")]
    pub same_site: Option<String>,
}

fn default_path() -> String {
    "/".to_string()
}

const MAX_COOKIE_IMPORT_BYTES: usize = 2 * 1024 * 1024;

/// Allowed cookie domains for import (ChatGPT/OpenAI related).
const ALLOWED_DOMAINS: &[&str] = &[
    "chatgpt.com",
    ".chatgpt.com",
    "chat.openai.com",
    ".chat.openai.com",
    "openai.com",
    ".openai.com",
    "auth.openai.com",
    ".auth.openai.com",
    "auth0.openai.com",
    ".auth0.openai.com",
    "login.openai.com",
    ".login.openai.com",
];

/// Check if a cookie domain is in the allowed list.
/// Uses proper boundary matching: `evilopenai.com` must NOT match `openai.com`.
fn is_domain_allowed(domain: &str) -> bool {
    let lower = domain.to_lowercase();
    ALLOWED_DOMAINS.iter().any(|allowed| {
        let allowed_lower = allowed.to_lowercase();
        if lower == allowed_lower {
            return true;
        }
        // For domains like ".chatgpt.com", also allow "chatgpt.com" (without leading dot)
        if let Some(without_dot) = allowed_lower.strip_prefix('.') {
            if lower == without_dot {
                return true;
            }
            // Subdomain match: "sub.chatgpt.com" matches ".chatgpt.com"
            if lower.ends_with(without_dot) && lower.ends_with(&format!(".{without_dot}")) {
                return true;
            }
        }
        false
    })
}

/// Parse and validate a cookie JSON import string.
/// Returns the validated list of cookies or a descriptive error.
pub fn parse_cookie_json(json_str: &str) -> Result<Vec<ExportedCookie>, String> {
    if json_str.len() > MAX_COOKIE_IMPORT_BYTES {
        return Err("JSON 文件过大，超过 2 MB 限制".to_string());
    }

    let cookies: Vec<ExportedCookie> =
        serde_json::from_str(json_str).map_err(|e| format!("JSON 解析失败: {e}"))?;

    if cookies.is_empty() {
        return Err("没有可导入的 cookie".to_string());
    }

    // Validate each cookie
    for (i, cookie) in cookies.iter().enumerate() {
        let name = cookie.name.trim();
        let domain = cookie.domain.trim().to_lowercase();
        let path = if cookie.path.is_empty() {
            "/"
        } else {
            &cookie.path
        };

        if name.is_empty() {
            return Err(format!("第 {} 个 cookie 名称为空", i + 1));
        }
        if domain.is_empty() {
            return Err(format!("第 {} 个 cookie 域名为空", i + 1));
        }
        if !path.starts_with('/') {
            return Err(format!("第 {} 个 cookie path 无效: {}", i + 1, path));
        }
        if !is_domain_allowed(&domain) {
            return Err(format!(
                "第 {} 个 cookie 域名不在白名单中: {}（仅允许 ChatGPT/OpenAI 相关域名）",
                i + 1, domain
            ));
        }
    }

    Ok(cookies)
}

/// Serialize cookies to JSON for export.
pub fn export_cookies_json(cookies: &[ExportedCookie]) -> Result<String, String> {
    serde_json::to_string_pretty(cookies).map_err(|e| format!("JSON 序列化失败: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_cookies() {
        let json = r#"[
          {
            "domain": ".chatgpt.com",
            "name": "session",
            "value": "abc123",
            "path": "/",
            "secure": true,
            "httpOnly": true
          }
        ]"#;
        let cookies = parse_cookie_json(json).unwrap();
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].name, "session");
        assert_eq!(cookies[0].domain, ".chatgpt.com");
    }

    #[test]
    fn reject_empty_cookies() {
        let json = "[]";
        let err = parse_cookie_json(json).unwrap_err();
        assert!(err.contains("没有可导入的 cookie"));
    }

    #[test]
    fn reject_empty_name() {
        let json = r#"[{"domain": ".example.com", "name": "", "value": "x"}]"#;
        let err = parse_cookie_json(json).unwrap_err();
        assert!(err.contains("名称为空"));
    }

    #[test]
    fn reject_empty_domain() {
        let json = r#"[{"domain": "", "name": "test", "value": "x"}]"#;
        let err = parse_cookie_json(json).unwrap_err();
        assert!(err.contains("域名为空"));
    }

    #[test]
    fn reject_invalid_path() {
        let json = r#"[{"domain": ".chatgpt.com", "name": "test", "value": "x", "path": "no-slash"}]"#;
        let err = parse_cookie_json(json).unwrap_err();
        assert!(err.contains("path 无效"));
    }

    #[test]
    fn default_path_is_slash() {
        let json = r#"[{"domain": ".chatgpt.com", "name": "test", "value": "x"}]"#;
        let cookies = parse_cookie_json(json).unwrap();
        assert_eq!(cookies[0].path, "/");
    }

    #[test]
    fn export_roundtrip() {
        let cookies = vec![ExportedCookie {
            domain: ".chatgpt.com".into(),
            name: "sid".into(),
            value: "val".into(),
            path: "/".into(),
            secure: Some(true),
            http_only: Some(false),
            session: Some(true),
            host_only: Some(false),
            expiration_date: None,
            same_site: Some("lax".into()),
        }];
        let json = export_cookies_json(&cookies).unwrap();
        let parsed = parse_cookie_json(&json).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].name, "sid");
    }

    #[test]
    fn reject_non_allowed_domain() {
        let json = r#"[{"domain": ".evil.com", "name": "test", "value": "x"}]"#;
        let err = parse_cookie_json(json).unwrap_err();
        assert!(err.contains("不在白名单中"));
    }

    #[test]
    fn domain_boundary_matching() {
        // Should match
        assert!(is_domain_allowed("chatgpt.com"));
        assert!(is_domain_allowed(".chatgpt.com"));
        assert!(is_domain_allowed("sub.chatgpt.com"));
        assert!(is_domain_allowed("openai.com"));
        assert!(is_domain_allowed(".openai.com"));
        assert!(is_domain_allowed("auth.openai.com"));

        // Should NOT match (boundary attack)
        assert!(!is_domain_allowed("evilopenai.com"));
        assert!(!is_domain_allowed("notevilchatgpt.com"));
        assert!(!is_domain_allowed("xopenai.com"));
        assert!(!is_domain_allowed("notchatgpt.com"));
    }

    #[test]
    fn swift_compatible_schema() {
        // Verify the JSON schema matches what Swift produces
        let json = r#"
        [
          {
            "domain": ".chatgpt.com",
            "expirationDate": 1735689600.0,
            "hostOnly": false,
            "httpOnly": true,
            "name": "__Secure-next-auth.session-token",
            "path": "/",
            "sameSite": "lax",
            "secure": true,
            "session": false,
            "value": "eyJhbGciOiJkaXIi..."
          }
        ]
        "#;
        let cookies = parse_cookie_json(json).unwrap();
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].same_site.as_deref(), Some("lax"));
        assert_eq!(cookies[0].expiration_date, Some(1735689600.0));
    }
}
