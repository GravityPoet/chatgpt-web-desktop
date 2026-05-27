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
    #[serde(default, rename = "httpOnly", alias = "http_only")]
    pub http_only: Option<bool>,
    #[serde(default)]
    pub session: Option<bool>,
    #[serde(default, rename = "hostOnly", alias = "host_only")]
    pub host_only: Option<bool>,
    #[serde(
        default,
        rename = "expirationDate",
        alias = "expiration_date",
        alias = "expires",
        alias = "expiry"
    )]
    pub expiration_date: Option<f64>,
    #[serde(default, rename = "sameSite", alias = "same_site")]
    pub same_site: Option<String>,
}

fn default_path() -> String {
    "/".to_string()
}

const MAX_COOKIE_IMPORT_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_HEADER_COOKIE_IMPORT_DOMAIN: &str = ".chatgpt.com";

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

/// Parse and validate a cookie import string.
/// Supports JSON, Netscape cookies.txt, Cookie headers, and Set-Cookie headers.
pub fn parse_cookie_import(input: &str) -> Result<Vec<ExportedCookie>, String> {
    if input.len() > MAX_COOKIE_IMPORT_BYTES {
        return Err("Cookie 文件过大，超过 2 MB 限制".to_string());
    }

    let trimmed = input.trim_start_matches('\u{feff}').trim();
    if trimmed.is_empty() {
        return Err("没有可导入的 cookie".to_string());
    }

    if trimmed.starts_with('[') || trimmed.starts_with('{') {
        return parse_cookie_json(trimmed);
    }

    let cookies = if looks_like_netscape_cookie_text(trimmed) {
        parse_netscape_cookie_text(trimmed)?
    } else {
        parse_header_cookie_text(trimmed)?
    };

    validate_cookies(&cookies)?;
    Ok(cookies)
}

/// Parse and validate a cookie JSON import string.
/// Returns the validated list of cookies or a descriptive error.
pub fn parse_cookie_json(json_str: &str) -> Result<Vec<ExportedCookie>, String> {
    if json_str.len() > MAX_COOKIE_IMPORT_BYTES {
        return Err("JSON 文件过大，超过 2 MB 限制".to_string());
    }

    let value: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| format!("JSON 解析失败: {e}"))?;
    let cookies = cookies_from_json_value(value)?;
    validate_cookies(&cookies)?;
    Ok(cookies)
}

fn cookies_from_json_value(value: serde_json::Value) -> Result<Vec<ExportedCookie>, String> {
    match value {
        serde_json::Value::Array(_) => {
            serde_json::from_value(value).map_err(|e| format!("JSON 解析失败: {e}"))
        }
        serde_json::Value::Object(mut object) => {
            if let Some(cookies) = object.remove("cookies") {
                serde_json::from_value(cookies).map_err(|e| format!("JSON 解析失败: {e}"))
            } else {
                serde_json::from_value(serde_json::Value::Array(vec![serde_json::Value::Object(
                    object,
                )]))
                .map_err(|e| format!("JSON 解析失败: {e}"))
            }
        }
        _ => Err(
            "JSON 顶层必须是 cookie 数组、单个 cookie 对象或 {\"cookies\": [...]}"
                .to_string(),
        ),
    }
}

fn validate_cookies(cookies: &[ExportedCookie]) -> Result<(), String> {
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

    Ok(())
}

fn looks_like_netscape_cookie_text(text: &str) -> bool {
    if text.to_lowercase().contains("netscape http cookie file") {
        return true;
    }

    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('#') && !line.starts_with("#HttpOnly_") {
            continue;
        }

        let mut candidate = line;
        if let Some(stripped) = candidate.strip_prefix("#HttpOnly_") {
            candidate = stripped;
        }
        let fields: Vec<&str> = candidate.split_whitespace().collect();
        return fields.len() >= 7
            && is_netscape_boolean(fields[1])
            && is_netscape_boolean(fields[3])
            && fields[4].parse::<i64>().is_ok();
    }

    false
}

fn parse_netscape_cookie_text(text: &str) -> Result<Vec<ExportedCookie>, String> {
    let mut cookies = Vec::new();

    for (line_index, raw_line) in text.lines().enumerate() {
        let mut line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        let mut http_only = false;
        if let Some(stripped) = line.strip_prefix("#HttpOnly_") {
            http_only = true;
            line = stripped;
        } else if line.starts_with('#') {
            continue;
        }

        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 7 {
            return Err(format!("Netscape 第 {} 行字段不足", line_index + 1));
        }

        let include_subdomains = parse_netscape_boolean(fields[1]).ok_or_else(|| {
            format!(
                "Netscape 第 {} 行 includeSubdomains 无效",
                line_index + 1
            )
        })?;
        let secure = parse_netscape_boolean(fields[3])
            .ok_or_else(|| format!("Netscape 第 {} 行 secure 无效", line_index + 1))?;
        let expires = fields[4]
            .parse::<f64>()
            .map_err(|_| format!("Netscape 第 {} 行 expires 无效", line_index + 1))?;
        let value = fields[6..].join(" ");
        let session = expires <= 0.0;

        cookies.push(ExportedCookie {
            domain: fields[0].to_string(),
            name: fields[5].to_string(),
            value,
            path: if fields[2].is_empty() {
                "/".to_string()
            } else {
                fields[2].to_string()
            },
            secure: Some(secure),
            http_only: Some(http_only),
            session: Some(session),
            host_only: Some(!include_subdomains),
            expiration_date: if session { None } else { Some(expires) },
            same_site: None,
        });
    }

    if cookies.is_empty() {
        return Err("没有可导入的 cookie".to_string());
    }

    Ok(cookies)
}

fn parse_header_cookie_text(text: &str) -> Result<Vec<ExportedCookie>, String> {
    let mut cookies = Vec::new();

    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            continue;
        }

        if let Some(value) = strip_header_prefix(line, "Set-Cookie:") {
            cookies.push(parse_set_cookie_line(value)?);
        } else if let Some(value) = strip_header_prefix(line, "Cookie:") {
            cookies.extend(parse_cookie_header_pairs(value)?);
        } else if looks_like_set_cookie_line(line) {
            cookies.push(parse_set_cookie_line(line)?);
        } else {
            cookies.extend(parse_cookie_header_pairs(line)?);
        }
    }

    if cookies.is_empty() {
        return Err("没有可导入的 cookie".to_string());
    }

    Ok(cookies)
}

fn parse_cookie_header_pairs(header: &str) -> Result<Vec<ExportedCookie>, String> {
    let mut cookies = Vec::new();

    for segment in header.split(';') {
        let pair = segment.trim();
        let Some((name, value)) = pair.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if name.is_empty() || is_set_cookie_attribute_name(name) {
            continue;
        }

        cookies.push(header_cookie(name, value.trim()));
    }

    if cookies.is_empty() {
        return Err("Header String 没有可导入的 cookie".to_string());
    }

    Ok(cookies)
}

fn parse_set_cookie_line(line: &str) -> Result<ExportedCookie, String> {
    let segments: Vec<&str> = line
        .split(';')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
        .collect();
    let Some(first) = segments.first() else {
        return Err("Set-Cookie Header 无效".to_string());
    };
    let Some((name, value)) = first.split_once('=') else {
        return Err("Set-Cookie Header 无效".to_string());
    };
    let name = name.trim();
    if name.is_empty() {
        return Err("Set-Cookie Header cookie 名称为空".to_string());
    }

    let mut domain = DEFAULT_HEADER_COOKIE_IMPORT_DOMAIN.to_string();
    let mut path = "/".to_string();
    let mut secure = false;
    let mut http_only = false;
    let mut same_site = None;
    let mut session = true;
    let mut expiration_date = None;

    for attribute in segments.iter().skip(1) {
        let lower = attribute.to_lowercase();
        if lower == "secure" {
            secure = true;
            continue;
        }
        if lower == "httponly" {
            http_only = true;
            continue;
        }

        let Some((key, value)) = attribute.split_once('=') else {
            continue;
        };
        let key = key.trim().to_lowercase();
        let value = value.trim();
        match key.as_str() {
            "domain" => domain = value.to_string(),
            "path" => {
                path = if value.is_empty() {
                    "/".to_string()
                } else {
                    value.to_string()
                };
            }
            "max-age" => {
                if let Ok(max_age) = value.parse::<f64>() {
                    if max_age > 0.0 {
                        expiration_date = Some(current_unix_time() + max_age);
                        session = false;
                    }
                }
            }
            "expires" => {
                if let Ok(expires) = value.parse::<f64>() {
                    expiration_date = Some(expires);
                    session = false;
                }
            }
            "samesite" => same_site = Some(value.to_string()),
            _ => {}
        }
    }

    Ok(ExportedCookie {
        domain: domain.clone(),
        name: name.to_string(),
        value: value.trim().to_string(),
        path,
        secure: Some(secure),
        http_only: Some(http_only),
        session: Some(session),
        host_only: Some(!domain.starts_with('.')),
        expiration_date,
        same_site,
    })
}

fn header_cookie(name: &str, value: &str) -> ExportedCookie {
    ExportedCookie {
        domain: DEFAULT_HEADER_COOKIE_IMPORT_DOMAIN.to_string(),
        name: name.to_string(),
        value: value.to_string(),
        path: "/".to_string(),
        secure: Some(true),
        http_only: Some(false),
        session: Some(true),
        host_only: Some(false),
        expiration_date: None,
        same_site: None,
    }
}

fn strip_header_prefix<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    line.get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))
        .map(|_| line[prefix.len()..].trim())
}

fn looks_like_set_cookie_line(line: &str) -> bool {
    let segments: Vec<String> = line
        .split(';')
        .map(|segment| segment.trim().to_lowercase())
        .collect();
    segments.len() > 1
        && segments.first().is_some_and(|first| first.contains('='))
        && segments
            .iter()
            .skip(1)
            .any(|segment| is_set_cookie_attribute_segment(segment))
}

fn is_set_cookie_attribute_segment(segment: &str) -> bool {
    segment == "secure"
        || segment == "httponly"
        || segment.starts_with("domain=")
        || segment.starts_with("path=")
        || segment.starts_with("expires=")
        || segment.starts_with("max-age=")
        || segment.starts_with("samesite=")
}

fn is_set_cookie_attribute_name(name: &str) -> bool {
    matches!(
        name.to_lowercase().as_str(),
        "domain" | "path" | "expires" | "max-age" | "samesite" | "secure" | "httponly"
    )
}

fn is_netscape_boolean(value: &str) -> bool {
    parse_netscape_boolean(value).is_some()
}

fn parse_netscape_boolean(value: &str) -> Option<bool> {
    match value.to_uppercase().as_str() {
        "TRUE" => Some(true),
        "FALSE" => Some(false),
        _ => None,
    }
}

fn current_unix_time() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
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

    #[test]
    fn parse_json_wrapper() {
        let json = r#"{"cookies":[{"domain":".chatgpt.com","name":"sid","value":"abc"}]}"#;
        let cookies = parse_cookie_import(json).unwrap();
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].path, "/");
    }

    #[test]
    fn parse_netscape_cookie_text() {
        let text = "# Netscape HTTP Cookie File\n#HttpOnly_.chatgpt.com\tTRUE\t/\tTRUE\t1735689600\t__Secure-next-auth.session-token\tabc";
        let cookies = parse_cookie_import(text).unwrap();
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].domain, ".chatgpt.com");
        assert_eq!(cookies[0].name, "__Secure-next-auth.session-token");
        assert_eq!(cookies[0].http_only, Some(true));
        assert_eq!(cookies[0].secure, Some(true));
        assert_eq!(cookies[0].expiration_date, Some(1735689600.0));
    }

    #[test]
    fn parse_cookie_header_string() {
        let text = "Cookie: __Secure-next-auth.session-token=abc; cf_clearance=xyz";
        let cookies = parse_cookie_import(text).unwrap();
        assert_eq!(cookies.len(), 2);
        assert_eq!(cookies[0].domain, ".chatgpt.com");
        assert_eq!(cookies[0].secure, Some(true));
        assert_eq!(cookies[1].name, "cf_clearance");
    }

    #[test]
    fn parse_set_cookie_header_string() {
        let text = "Set-Cookie: session=abc; Domain=.chatgpt.com; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=3600";
        let cookies = parse_cookie_import(text).unwrap();
        assert_eq!(cookies.len(), 1);
        assert_eq!(cookies[0].domain, ".chatgpt.com");
        assert_eq!(cookies[0].path, "/");
        assert_eq!(cookies[0].secure, Some(true));
        assert_eq!(cookies[0].http_only, Some(true));
        assert_eq!(cookies[0].same_site.as_deref(), Some("Lax"));
        assert_eq!(cookies[0].session, Some(false));
        assert!(cookies[0].expiration_date.is_some());
    }
}
