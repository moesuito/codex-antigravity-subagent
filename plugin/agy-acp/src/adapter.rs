use fs2::FileExt;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

use crate::types::*;

pub struct Adapter {
    pub sessions: HashMap<String, Session>,
    pub working_dir: String,
    pub conversations_dir: PathBuf,
    pub state_file: PathBuf,
    pub available_models: Option<Vec<String>>,
}
impl Adapter {
    pub fn new() -> Self {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| "/tmp".to_string());
        let state_dir = PathBuf::from(&home).join(".openab/agy-acp");
        Self {
            sessions: HashMap::new(),
            working_dir: std::env::current_dir()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| "/tmp".to_string()),
            conversations_dir: PathBuf::from(&home).join(".gemini/antigravity-cli/conversations"),
            state_file: state_dir.join("sessions.json"),
            available_models: None,
        }
    }

    // --- Model cache ---

    pub fn models_cache_path(&self) -> PathBuf {
        self.state_file.with_file_name("models_cache.json")
    }

    pub fn load_cached_models(&self) -> Option<Vec<String>> {
        let path = self.models_cache_path();
        let content = fs::read_to_string(&path).ok()?;
        serde_json::from_str::<Vec<String>>(&content).ok().filter(|v| !v.is_empty())
    }

    pub fn save_models_cache(&self, models: &[String]) {
        if let Some(parent) = self.models_cache_path().parent() {
            let _ = fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string(models) {
            let tmp = self.models_cache_path().with_extension("tmp");
            if fs::write(&tmp, &json).is_ok() {
                let _ = fs::rename(&tmp, self.models_cache_path());
            }
        }
    }

    pub fn static_fallback_models() -> Vec<String> {
        // agy 1.1.5+ slugs (base models without effort; effort is set via --effort).
        vec![
            "gemini-3.6-flash".to_string(),
            "gemini-3.5-flash".to_string(),
            "gemini-3.1-pro".to_string(),
            "claude-sonnet-4-6".to_string(),
            "claude-opus-4-6".to_string(),
            "gpt-oss-120b".to_string(),
        ]
    }

    /// Effort levels supported by `agy --effort` (1.1.5+).
    pub fn effort_levels() -> &'static [&'static str] {
        &["low", "medium", "high"]
    }

    /// Normalize a model identifier so it works across agy versions.
    ///
    /// Pre-1.1.5 `agy models` returned friendly names with effort in
    /// parentheses, e.g. `Gemini 3.5 Flash (High)`. 1.1.5 replaced those with
    /// stable slugs (`gemini-3.5-flash`) and moved effort into `--effort`.
    /// If `raw` looks like a legacy name, this returns the base slug with the
    /// effort split out; otherwise it returns the slug unchanged with no
    /// effort.
    pub fn normalize_model(raw: &str) -> (String, Option<String>) {
        if let Some(open) = raw.rfind('(') {
            if let Some(close) = raw[open..].find(')') {
                let inside = raw[open + 1..open + close].trim().to_lowercase();
                let name = raw[..open].trim();
                if Self::effort_levels().contains(&inside.as_str()) && !name.is_empty() {
                    let slug = legacy_name_to_slug(name);
                    return (slug, Some(inside));
                }
            }
        }
        (raw.to_string(), None)
    }

    /// Resolve the `agy` binary path.
    pub fn agy_bin() -> &'static str {
        if cfg!(windows) { "agy.exe" } else { "/usr/local/bin/agy" }
    }

    /// Build PATH with common agent binary locations prepended.
    pub fn augmented_path() -> String {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| "/home/agent".to_string());
        let base = std::env::var("PATH").unwrap_or_default();
        if cfg!(windows) {
            format!(r"{}\bin;{}\.local\bin;{}", home, home, base)
        } else {
            format!("{home}/bin:{home}/.local/bin:{home}/.local/share/fnm/aliases/default/bin:{base}")
        }
    }

    pub fn fetch_available_models() -> Vec<String> {
        std::process::Command::new(Self::agy_bin())
            .arg("models")
            .env("PATH", Self::augmented_path())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .map(|l| l.trim().to_string())
                    .filter(|l| !l.is_empty())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn get_available_models(&mut self) -> &[String] {
        if self.available_models.is_none() {
            let models = Self::fetch_available_models();
            if !models.is_empty() {
                eprintln!("[agy-acp] fetched {} models from `agy models`, updating cache", models.len());
                self.save_models_cache(&models);
                self.available_models = Some(models);
            } else if let Some(cached) = self.load_cached_models() {
                eprintln!("[agy-acp] `agy models` failed, using cached model list ({} models)", cached.len());
                self.available_models = Some(cached);
            } else {
                eprintln!("[agy-acp] `agy models` failed and no cache found, using hardcoded fallback");
                self.available_models = Some(Self::static_fallback_models());
            }
        }
        self.available_models.as_ref().unwrap()
    }

    pub fn config_options_json(&mut self, model_id: Option<&str>, effort: Option<&str>) -> Value {
        let models = self.get_available_models();
        if models.is_empty() {
            return json!([]);
        }
        let current_model = model_id
            .or_else(|| models.first().map(|s| s.as_str()))
            .unwrap_or("");
        let model_options: Vec<Value> = models
            .iter()
            .map(|name| json!({ "value": name, "name": name }))
            .collect();

        let efforts = Self::effort_levels();
        let current_effort = effort
            .or_else(|| efforts.last().copied())
            .unwrap_or("");
        let effort_options: Vec<Value> = efforts
            .iter()
            .map(|level| json!({ "value": level, "name": level }))
            .collect();

        json!([
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": current_model,
                "options": model_options,
            },
            {
                "id": "effort",
                "name": "Effort",
                "category": "model",
                "type": "select",
                "currentValue": current_effort,
                "options": effort_options,
            },
        ])
    }

    // --- State persistence ---

    fn lock_state_file(&self) -> Option<fs::File> {
        if let Some(parent) = self.state_file.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let lock_path = self.state_file.with_extension("lock");
        let lock_file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(&lock_path)
            .ok()?;
        lock_file.lock_exclusive().ok()?;
        Some(lock_file)
    }

    fn load_store_inner(&self) -> SessionStore {
        let Some(file) = fs::File::open(&self.state_file).ok() else {
            return SessionStore::default();
        };
        serde_json::from_reader(&file).unwrap_or_default()
    }

    pub fn load_store(&self) -> SessionStore {
        let _lock = self.lock_state_file();
        self.load_store_inner()
    }

    pub fn restore_session(&self, session_id: &str) -> Option<(String, i64, Option<String>, Option<String>)> {
        let store = self.load_store();
        store.sessions.get(session_id).and_then(|s| {
            s.conversation_id.clone().map(|cid| {
                // Migrate any legacy "Friendly (Effort)" model_id persisted under
                // pre-1.1.5 `agy models` to a 1.1.5 slug + separate effort before
                // re-spawning agy. Otherwise agy 1.1.5's stricter `--model`
                // resolution would reject the value and silently end the turn
                // without writing to the SQLite conversation, which looks to the
                // client like the adapter "lost" the conversation ID.
                let (slug, effort_from_model) = s.model_id
                    .as_deref()
                    .map(Adapter::normalize_model)
                    .unwrap_or((String::new(), None));
                let model_id = if slug.is_empty() { s.model_id.clone() } else { Some(slug) };
                let effort = s.effort.clone().or(effort_from_model);
                (cid, s.last_step_idx, model_id, effort)
            })
        })
    }

    pub fn persist_session(
        &self,
        session_id: &str,
        conversation_id: Option<&str>,
        last_step_idx: i64,
        model_id: Option<&str>,
        effort: Option<&str>,
    ) {
        let Some(_lock) = self.lock_state_file() else { return; };
        let mut store = self.load_store_inner();
        // Preserve the previous model/effort if the caller passes None, so a
        // continuation turn that only updates `last_step_idx` and `conversation_id`
        // does not wipe the client's previously-selected model/effort (which would
        // silently drop `--model`/`--effort` from the next spawn).
        let prev = store.sessions.get(session_id);
        let model = model_id
            .map(String::from)
            .or_else(|| prev.and_then(|p| p.model_id.clone()));
        let effort = effort
            .map(String::from)
            .or_else(|| prev.and_then(|p| p.effort.clone()));
        store.sessions.insert(
            session_id.to_string(),
            StoredSession {
                conversation_id: conversation_id.map(String::from),
                last_step_idx,
                model_id: model,
                effort,
            },
        );
        let tmp = self.state_file.with_extension("tmp");
        if let Ok(file) = fs::File::create(&tmp) {
            if serde_json::to_writer_pretty(&file, &store).is_ok() {
                let _ = fs::rename(&tmp, &self.state_file);
            }
        }
    }

    // --- Conversation snapshot ---

    pub fn conversation_snapshot(&self) -> HashSet<String> {
        let Ok(entries) = fs::read_dir(&self.conversations_dir) else {
            return HashSet::new();
        };
        entries
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let path = e.path();
                if path.extension().map(|x| x == "db").unwrap_or(false) {
                    path.file_stem().map(|s| s.to_string_lossy().to_string())
                } else {
                    None
                }
            })
            .collect()
    }

    pub fn new_conversation_id(&self, before: &HashSet<String>) -> Option<String> {
        let after = self.conversation_snapshot();
        let mut created: Vec<_> = after.difference(before).collect();
        if created.is_empty() { return None; }
        if created.len() > 1 {
            eprintln!("[agy-acp] WARN: multiple new agy conversation files appeared; refusing to bind");
            return None;
        }
        Some(created.remove(0).clone())
    }

    // --- Session management ---

    pub fn evict_if_needed(&mut self) {
        const MAX_SESSIONS: usize = 64;
        while self.sessions.len() >= MAX_SESSIONS {
            if let Some(key) = self.sessions.keys().next().cloned() {
                self.sessions.remove(&key);
            }
        }
    }

    pub fn restore_session_state(&mut self, session_id: &str) -> bool {
        let Some((conversation_id, last_step_idx, model_id, effort)) = self.restore_session(session_id) else {
            return false;
        };
        if !self.sessions.contains_key(session_id) {
            self.evict_if_needed();
        }
        self.sessions.insert(
            session_id.to_string(),
            Session { conversation_id: Some(conversation_id), last_step_idx, model_id, effort },
        );
        true
    }

    // --- JSON-RPC handlers ---

    pub fn handle_initialize(&self, id: Value) -> JsonRpcResponse {
        JsonRpcResponse {
            jsonrpc: "2.0",
            id,
            result: Some(json!({
                "protocolVersion": 1,
                "agentInfo": { "name": "agy", "version": env!("CARGO_PKG_VERSION") },
                "agentCapabilities": { "streaming": true, "loadSession": true },
            })),
            error: None,
        }
    }

    pub fn handle_session_new(&mut self, id: Value) -> JsonRpcResponse {
        let session_id = Uuid::new_v4().to_string();
        self.evict_if_needed();
        self.sessions.insert(session_id.clone(), Session {
            conversation_id: None, last_step_idx: -1, model_id: None, effort: None,
        });
        let config_options = self.config_options_json(None, None);
        JsonRpcResponse {
            jsonrpc: "2.0",
            id,
            result: Some(json!({ "sessionId": session_id, "configOptions": config_options })),
            error: None,
        }
    }

    pub fn handle_session_load(&mut self, id: Value, params: &Value) -> JsonRpcResponse {
        let session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("");
        if session_id.is_empty() {
            return JsonRpcResponse { jsonrpc: "2.0", id, result: None,
                error: Some(json!({"code":-32602,"message":"missing sessionId"})) };
        }
        if self.restore_session_state(session_id) {
            let model_id = self.sessions.get(session_id).and_then(|s| s.model_id.clone());
            let effort = self.sessions.get(session_id).and_then(|s| s.effort.clone());
            let config_options = self.config_options_json(model_id.as_deref(), effort.as_deref());
            return JsonRpcResponse { jsonrpc: "2.0", id,
                result: Some(json!({ "sessionId": session_id, "configOptions": config_options })), error: None };
        }
        JsonRpcResponse { jsonrpc: "2.0", id, result: None,
            error: Some(json!({"code":-32000,"message":format!("unknown sessionId: {session_id}")})) }
    }

    pub fn handle_session_set_config_option(&mut self, id: Value, params: &Value) -> JsonRpcResponse {
        let session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("");
        let config_id = params.get("configId").and_then(|v| v.as_str()).unwrap_or("");
        let value = params.get("value").and_then(|v| v.as_str()).unwrap_or("");

        if session_id.is_empty() || value.is_empty() || !matches!(config_id, "model" | "effort") {
            return JsonRpcResponse { jsonrpc: "2.0", id, result: None,
                error: Some(json!({"code":-32602,"message":"missing sessionId, unsupported configId, or value"})) };
        }
        if !Self::effort_levels().contains(&value)
            && config_id == "effort"
        {
            return JsonRpcResponse { jsonrpc: "2.0", id, result: None,
                error: Some(json!({"code":-32602,"message":format!("invalid effort: {value}")})) };
        }
        if !self.sessions.contains_key(session_id) {
            let _ = self.restore_session_state(session_id);
        }
        let Some(session) = self.sessions.get_mut(session_id) else {
            return JsonRpcResponse { jsonrpc: "2.0", id, result: None,
                error: Some(json!({"code":-32000,"message":format!("unknown sessionId: {session_id}")})) };
        };
        match config_id {
            "model" => session.model_id = Some(value.to_string()),
            "effort" => session.effort = Some(value.to_string()),
            _ => unreachable!(),
        }
        let conv_id = session.conversation_id.clone();
        let last_step_idx = session.last_step_idx;
        let cur_model = session.model_id.clone();
        let cur_effort = session.effort.clone();
        self.persist_session(
            session_id,
            conv_id.as_deref(),
            last_step_idx,
            cur_model.as_deref(),
            cur_effort.as_deref(),
        );
        let config_options = self.config_options_json(cur_model.as_deref(), cur_effort.as_deref());
        JsonRpcResponse { jsonrpc: "2.0", id, result: Some(json!({ "configOptions": config_options })), error: None }
    }

    /// Gather session state needed for prompt execution (under lock).
    pub fn prepare_prompt_state(
        &mut self,
        params: &Value,
    ) -> (String, String, Vec<String>, Option<HashSet<String>>, Option<String>, i64) {
        let session_id = params.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();

        if !session_id.is_empty() && !self.sessions.contains_key(&session_id) {
            let _ = self.restore_session_state(&session_id);
        }

        let prompt_text = params
            .get("prompt")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|b| b.get("text").and_then(|t| t.as_str())).collect::<Vec<_>>().join("\n"))
            .unwrap_or_default();
        let clean_prompt = prompt_text.trim().to_string();

        let snapshot = if self.sessions.get(&session_id).map(|s| s.conversation_id.is_none()).unwrap_or(false) {
            Some(self.conversation_snapshot())
        } else {
            None
        };

        let mut args: Vec<String> = Vec::new();
        args.push("--add-dir".to_string());
        args.push(self.working_dir.clone());
        if let Ok(extra) = std::env::var("AGY_EXTRA_ARGS") {
            if let Ok(parsed) = shell_words::split(&extra) {
                args.extend(parsed);
            } else {
                eprintln!("[agy-acp] WARN: failed to parse AGY_EXTRA_ARGS, ignoring");
            }
        }
        if let Some(session) = self.sessions.get(&session_id) {
            if let Some(conv_id) = &session.conversation_id {
                args.push("--conversation".to_string());
                args.push(conv_id.clone());
            }
            if let Some(model_id) = &session.model_id {
                args.push("--model".to_string());
                args.push(model_id.clone());
            }
            if let Some(effort) = &session.effort {
                args.push("--effort".to_string());
                args.push(effort.clone());
            }
        }
        args.push("-p".to_string());
        args.push(clean_prompt.clone());

        let initial_conv_id = self.sessions.get(&session_id).and_then(|s| s.conversation_id.clone());
        let initial_step_idx = self.sessions.get(&session_id).map(|s| s.last_step_idx).unwrap_or(-1);

        (session_id, clean_prompt, args, snapshot, initial_conv_id, initial_step_idx)
    }
}

/// Best-effort mapping from a pre-1.1.5 friendly model name to its 1.1.5 slug.
/// Used only when restoring a session persisted under an older `agy models`
/// output (`Gemini 3.5 Flash (High)` → `gemini-3.5-flash`). Unknown names are
/// returned as a lowercase, dash-collapsed slug so the user can recover by
/// re-selecting the model in the client.
fn legacy_name_to_slug(name: &str) -> String {
    let canon = name
        .trim()
        .to_lowercase()
        .replace(['(', ')', ',', '.', '/'], " ");
    let mut slug = String::with_capacity(canon.len());
    let mut prev_dash = true; // collapse leading dashes
    for ch in canon.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch);
            prev_dash = false;
        } else if !prev_dash {
            slug.push('-');
            prev_dash = true;
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    slug
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_legacy_name_with_effort_splits_slug_and_effort() {
        let (slug, effort) = Adapter::normalize_model("Gemini 3.5 Flash (High)");
        assert_eq!(slug, "gemini-3-5-flash");
        assert_eq!(effort.as_deref(), Some("high"));
    }

    #[test]
    fn normalize_slug_without_effort_keeps_slug_and_returns_none() {
        let (slug, effort) = Adapter::normalize_model("gemini-3.5-flash");
        assert_eq!(slug, "gemini-3.5-flash");
        assert_eq!(effort, None);
    }

    #[test]
    fn normalize_slug_with_inline_effort_suffix_keeps_suffix_as_slug() {
        // 1.1.5 `agy models` lists per-effort slugs like `gemini-3.5-flash-high`
        // alongside base slugs; both are valid --model inputs. Adaptive clients
        // should keep the full slug and not split on the trailing `-high`.
        let (slug, effort) = Adapter::normalize_model("gemini-3.5-flash-high");
        assert_eq!(slug, "gemini-3.5-flash-high");
        assert_eq!(effort, None);
    }

    #[test]
    fn normalize_legacy_name_with_unrecognized_effort_keeps_full_name_as_slug() {
        // `gpt-oss-120b-medium` is one of the 1.1.5 slugs; legacy `agy models`
        // never returned a `GPT-OSS 120B (Medium)`-style alias, so a "name"
        // with a non-effort parenthetical should round-trip unchanged as a slug.
        let (slug, effort) = Adapter::normalize_model("Bespoke Model (Preview)");
        assert_eq!(effort, None);
        assert!(!slug.is_empty());
    }
}
