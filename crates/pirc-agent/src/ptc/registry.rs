//! The capability registry behind `ptc` and `ptc_docs`
//! (`agent/ptc/registry.ts`).
//!
//! Capabilities are the agent's existing tools under their existing names.
//! Availability is the agent's own calculation; discovery and execution use
//! the same list, and every operation is still authorized when it runs. The
//! metadata below describes capabilities for documentation and scheduling;
//! it never grants anything.

use std::rc::Rc;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use indexmap::IndexMap;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::contracts::{CONTRACT_VERSION, PtcError, WRAPPER_NAMES, budgets, is_capability_name};
use super::signatures::summary_of;
use crate::tools::Tool;
use crate::tools::js;

/// `Meta`: what a capability does, for docs and scheduling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Meta {
    pub category: &'static str,
    pub effects: &'static [&'static str],
    /// `read` runs concurrently; `exclusive-write` takes the single write slot.
    pub concurrency: &'static str,
    /// Actions of an action-dependent capability that only read.
    pub read_actions: Option<&'static [&'static str]>,
    pub approval: &'static str,
    pub suspension: &'static [&'static str],
    /// Returns web content: what a script returns is fenced as untrusted.
    pub untrusted: bool,
    /// Returns text other sessions or agents wrote (memory notes, other
    /// results, team messages): what a script returns is fenced as data.
    pub agent_data: bool,
}

const fn meta(
    category: &'static str,
    effects: &'static [&'static str],
    concurrency: &'static str,
    approval: &'static str,
    suspension: &'static [&'static str],
) -> Meta {
    Meta {
        category,
        effects,
        concurrency,
        read_actions: None,
        approval,
        suspension,
        untrusted: false,
        agent_data: false,
    }
}

const fn read(category: &'static str, effects: &'static [&'static str]) -> Meta {
    meta(category, effects, "read", "none", &[])
}

const fn write(category: &'static str, effects: &'static [&'static str]) -> Meta {
    meta(category, effects, "exclusive-write", "none", &[])
}

const fn with_reads(mut info: Meta, actions: &'static [&'static str]) -> Meta {
    info.read_actions = Some(actions);
    info
}

const fn untrusted(mut info: Meta) -> Meta {
    info.untrusted = true;
    info
}

const fn agent_data(mut info: Meta) -> Meta {
    info.agent_data = true;
    info
}

/// Anything unknown is documented conservatively as an exclusive write.
const FALLBACK: Meta = meta(
    "other",
    &["write"],
    "exclusive-write",
    "operation-policy",
    &[],
);

/// `capabilityMeta(name)`.
pub fn capability_meta(name: &str) -> Meta {
    match name {
        "read" | "ls" | "find" | "grep" => read("files", &["read"]),
        "write" | "edit" => meta(
            "files",
            &["write"],
            "exclusive-write",
            "operation-policy",
            &[],
        ),
        // Commands may write anything: conservatively one at a time.
        "bash" => meta(
            "shell",
            &["process", "write"],
            "exclusive-write",
            "operation-policy",
            &["approval"],
        ),
        "background_task" => with_reads(
            meta(
                "shell",
                &["process", "write"],
                "exclusive-write",
                "action-dependent",
                &["approval", "job"],
            ),
            &["list", "output", "wait"],
        ),
        "unsandboxed_bash" => meta(
            "sandbox",
            &["process", "write", "external"],
            "exclusive-write",
            "always-confirm",
            &["approval"],
        ),
        "sandbox_allow_domains" => meta(
            "sandbox",
            &["external"],
            "exclusive-write",
            "always-confirm",
            &["approval"],
        ),
        "web_fetch" | "web_search" => untrusted(read("web", &["external"])),
        "browser_snapshot" | "browser_screenshot" => untrusted(read("browser", &["external"])),
        "browser_tabs" => untrusted(with_reads(write("browser", &["external"]), &["list"])),
        "browser_handoff" => untrusted(meta(
            "browser",
            &["interaction", "external"],
            "exclusive-write",
            "none",
            &["user"],
        )),
        "ask_user_question" => meta(
            "interaction",
            &["interaction"],
            "exclusive-write",
            "none",
            &["user"],
        ),
        "todo" => with_reads(write("planning", &["write"]), &["list"]),
        "get_goal" => read("planning", &["read"]),
        "create_goal" | "update_goal" => write("planning", &["write"]),
        "recall" | "history_search" | "history_read" => agent_data(read("memory", &["read"])),
        "memory_search" => agent_data(read("memory", &["read", "external"])),
        "memory_note" => write("memory", &["write"]),
        "memory_propose_user" => meta(
            "memory",
            &["write", "interaction"],
            "exclusive-write",
            "always-confirm",
            &["approval"],
        ),
        "schedule" => with_reads(
            meta(
                "schedule",
                &["external", "write"],
                "exclusive-write",
                "action-dependent",
                &["approval"],
            ),
            &["list", "result"],
        ),
        "agent_inbox" | "board_read" => agent_data(read("team", &["read"])),
        "agent_list" | "task_list" | "task_get" => read("team", &["read"]),
        "agent_wait" => meta("team", &["read"], "read", "none", &["child"]),
        "subagent" | "agent_spawn" => meta(
            "team",
            &["process", "write"],
            "exclusive-write",
            "none",
            &["child"],
        ),
        "agent_ask" => meta(
            "team",
            &["interaction", "write"],
            "exclusive-write",
            "none",
            &["user"],
        ),
        "browser_navigate" | "browser_click" | "browser_type" | "browser_select"
        | "browser_press" | "browser_wait_for" => {
            untrusted(write("browser", &["external", "write"]))
        }
        "browser_record" => write("browser", &["external", "write"]),
        "agent_send" | "agent_reply" | "agent_stop" | "board_post" | "task_create"
        | "task_update" => write("team", &["write"]),
        _ => FALLBACK,
    }
}

/// `isWriteCall`: whether this call takes the execution's write slot.
pub fn is_write_call(name: &str, args: &Map<String, Value>) -> bool {
    let info = capability_meta(name);
    if info.concurrency == "read" {
        return false;
    }
    !matches!(
        (info.read_actions, args.get("action")),
        (Some(actions), Some(Value::String(action))) if actions.contains(&action.as_str())
    )
}

fn images_schema() -> Value {
    json!({
        "type": "array",
        "description": "Images the operation returned, kept by the host: pass one to attachments.add() to show it to the model with the ptc result",
        "items": {
            "type": "object",
            "properties": {
                "handle": { "type": "string", "description": "Opaque attachment handle" },
                "mimeType": { "type": "string" },
                "bytes": { "type": "integer" },
            },
            "required": ["handle", "mimeType", "bytes"],
            "additionalProperties": false,
        },
    })
}

/// One alternative of a result schema: `text`, optional `images`, then the
/// capability's fields.
fn result_branch(typed: &Value) -> Value {
    let mut properties = Map::new();
    properties.insert(
        "text".to_owned(),
        json!({
            "type": "string",
            "description": "The formatted output (what a person reading the result would see)",
        }),
    );
    properties.insert("images".to_owned(), images_schema());
    if let Some(Value::Object(own)) = typed.get("properties") {
        for (key, value) in own {
            properties.insert(key.clone(), value.clone());
        }
    }
    let mut required = vec![json!("text")];
    if let Some(Value::Array(own)) = typed.get("required") {
        required.extend(own.iter().cloned());
    }
    let mut out = Map::new();
    out.insert("type".to_owned(), json!("object"));
    if let Some(Value::String(description)) = typed.get("description") {
        out.insert("description".to_owned(), json!(description));
    }
    out.insert("properties".to_owned(), Value::Object(properties));
    out.insert("required".to_owned(), Value::Array(required));
    // Closed unless the capability documents an open record.
    out.insert(
        "additionalProperties".to_owned(),
        json!(typed.get("additionalProperties") == Some(&Value::Bool(true))),
    );
    Value::Object(out)
}

/// `resultSchemaOf(tool)`: the declared typed fields plus `text` and
/// `images`; `{ text }` only without a declaration.
pub fn result_schema_of(tool: &dyn Tool) -> Value {
    let fallback = json!({ "type": "object", "properties": {} });
    let typed = tool.result_schema().unwrap_or(&fallback);
    if let Some(Value::Array(branches)) = typed.get("oneOf") {
        return json!({ "oneOf": branches.iter().map(result_branch).collect::<Vec<_>>() });
    }
    result_branch(typed)
}

const ERRORS: [&str; 7] = [
    "ApprovalDenied",
    "CapabilityUnavailable",
    "InvalidArguments",
    "QuotaExceeded",
    "Cancelled",
    "Timeout",
    "OperationFailed",
];

/// `Capability`.
#[derive(Clone)]
pub struct Capability {
    pub name: String,
    pub category: &'static str,
    pub tool: Rc<dyn Tool>,
    pub meta: Meta,
}

/// Available capabilities by name, in the agent's order.
pub type Available = IndexMap<String, Capability>;

/// `available()`: every tool except the wrappers and invalid names.
pub fn available(tools: &[Rc<dyn Tool>]) -> Available {
    let mut out = Available::new();
    for tool in tools {
        let name = tool.name();
        if WRAPPER_NAMES.contains(&name) || !is_capability_name(name) {
            continue;
        }
        let info = capability_meta(name);
        out.insert(
            name.to_owned(),
            Capability {
                name: name.to_owned(),
                category: info.category,
                tool: tool.clone(),
                meta: info,
            },
        );
    }
    out
}

/// `label(name)`: `browser_tabs` → `Browser tabs`.
fn label(name: &str) -> String {
    let words = name.replace('_', " ");
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// `example(name, parameters)`.
fn example(name: &str, parameters: &Map<String, Value>) -> String {
    let empty = Map::new();
    let properties = match parameters.get("properties") {
        Some(Value::Object(properties)) => properties,
        _ => &empty,
    };
    let required: Vec<String> = match parameters.get("required") {
        Some(Value::Array(items)) => items.iter().map(js::string_of).collect(),
        _ => Vec::new(),
    };
    let args = required
        .iter()
        .take(3)
        .map(|key| {
            let value = match properties.get(key).and_then(|p| p.get("type")) {
                Some(Value::String(kind)) if kind == "number" || kind == "integer" => "1",
                Some(Value::String(kind)) if kind == "boolean" => "true",
                Some(Value::String(kind)) if kind == "array" => "[]",
                Some(Value::String(kind)) if kind == "object" => "{}",
                _ => "\"…\"",
            };
            format!("{key}: {value}")
        })
        .collect::<Vec<_>>()
        .join(", ");
    if args.is_empty() {
        format!("const result = await tools.{name}({{}});")
    } else {
        format!("const result = await tools.{name}({{ {args} }});")
    }
}

fn strs(items: &[&str]) -> Value {
    json!(items)
}

/// `contract(capability)`: the full documentation of one capability.
pub fn contract(capability: &Capability) -> Value {
    let tool = &capability.tool;
    let info = &capability.meta;
    let mut out = Map::new();
    out.insert("name".to_owned(), json!(tool.name()));
    out.insert("category".to_owned(), json!(info.category));
    out.insert("uiLabel".to_owned(), json!(label(tool.name())));
    out.insert("contractVersion".to_owned(), json!(CONTRACT_VERSION));
    out.insert("description".to_owned(), json!(tool.description()));
    out.insert(
        "inputSchema".to_owned(),
        Value::Object(tool.parameters().clone()),
    );
    out.insert("resultSchema".to_owned(), result_schema_of(tool.as_ref()));
    out.insert("errors".to_owned(), strs(&ERRORS));
    out.insert("effects".to_owned(), strs(info.effects));
    out.insert("concurrency".to_owned(), json!(info.concurrency));
    if let Some(actions) = info.read_actions {
        out.insert("readActions".to_owned(), strs(actions));
    }
    out.insert("approval".to_owned(), json!(info.approval));
    out.insert("suspension".to_owned(), strs(info.suspension));
    if info.untrusted {
        out.insert("untrustedContent".to_owned(), json!(true));
    }
    if info.agent_data {
        out.insert("agentData".to_owned(), json!(true));
    }
    out.insert(
        "examples".to_owned(),
        json!([example(tool.name(), tool.parameters())]),
    );
    Value::Object(out)
}

/// `version()`: content hash of the available contracts.
pub fn version(available: &Available) -> String {
    let mut names: Vec<&String> = available.keys().collect();
    names.sort();
    let mut hash = Sha256::new();
    for name in names {
        hash.update(js::stringify(&contract(&available[name])).as_bytes());
        hash.update(b"\0");
    }
    let digest = hash.finalize();
    digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>()[..16]
        .to_owned()
}

/// `index()`: category → capability names, for the prompt and the docs.
pub fn index(available: &Available) -> Vec<(String, Vec<String>)> {
    let mut groups: IndexMap<&str, Vec<String>> = IndexMap::new();
    for capability in available.values() {
        groups
            .entry(capability.category)
            .or_default()
            .push(capability.name.clone());
    }
    let mut out: Vec<(String, Vec<String>)> = groups
        .into_iter()
        .map(|(category, mut names)| {
            names.sort();
            (category.to_owned(), names)
        })
        .collect();
    out.sort_by(|a, b| js::name_order(&a.0, &b.0));
    out
}

fn byte_length(value: &Value) -> usize {
    js::stringify(value).len()
}

type HmacSha256 = Hmac<Sha256>;

/// `CapabilityRegistry`: one per agent. The tool list is read fresh on every
/// use, so a capability that becomes unavailable disappears from docs and
/// execution alike.
pub struct CapabilityRegistry {
    pub session_id: String,
    /// Cursor authentication; per process, so cursors never outlive the agent.
    key: [u8; 32],
}

impl CapabilityRegistry {
    pub fn new(session_id: String) -> Self {
        let mut key = [0u8; 32];
        getrandom::fill(&mut key).expect("the system random number generator");
        Self { session_id, key }
    }

    /// `summaries()`: what the context snapshot lists, without schemas.
    pub fn summaries(&self, tools: &[Rc<dyn Tool>]) -> Value {
        let mut list: Vec<Capability> = available(tools).into_values().collect();
        list.sort_by(|a, b| {
            js::name_order(a.category, b.category).then_with(|| js::name_order(&a.name, &b.name))
        });
        Value::Array(
            list.iter()
                .map(|capability| {
                    json!({
                        "name": capability.name,
                        "category": capability.category,
                        "uiLabel": label(&capability.name),
                        "effects": capability.meta.effects,
                        "approval": capability.meta.approval,
                    })
                })
                .collect(),
        )
    }

    fn sign(&self, payload: &str) -> String {
        let mut mac = HmacSha256::new_from_slice(&self.key).expect("an HMAC key");
        mac.update(payload.as_bytes());
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    }

    fn cursor(&self, category: &str, offset: usize, version: &str) -> String {
        let payload = URL_SAFE_NO_PAD.encode(js::stringify(&json!({
            "s": self.session_id,
            "v": version,
            "c": category,
            "o": offset,
        })));
        let signature = self.sign(&payload);
        format!("{payload}.{signature}")
    }

    fn read_cursor(&self, cursor: &str, category: &str, version: &str) -> Result<f64, PtcError> {
        let invalid = || PtcError::new("InvalidArguments", "Invalid cursor");
        let mut parts = cursor.split('.');
        let payload = parts.next().unwrap_or("");
        let signature = parts.next().unwrap_or("");
        if payload.is_empty() || signature.is_empty() || signature != self.sign(payload) {
            return Err(invalid());
        }
        let data: Value = URL_SAFE_NO_PAD
            .decode(payload)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .ok_or_else(invalid)?;
        if data.get("s") != Some(&json!(self.session_id)) || data.get("c") != Some(&json!(category))
        {
            return Err(PtcError::new(
                "InvalidArguments",
                "The cursor belongs to a different query",
            ));
        }
        if data.get("v") != Some(&json!(version)) {
            return Err(PtcError::stale(
                "Capabilities changed since this cursor was issued; query the category again",
                Vec::new(),
                version,
            ));
        }
        Ok(data.get("o").and_then(Value::as_f64).unwrap_or(f64::NAN))
    }

    /// `docs(request)`: bounded, read-only discovery (`ptc_docs`).
    pub fn docs(
        &self,
        request: &Map<String, Value>,
        tools: &[Rc<dyn Tool>],
    ) -> Result<Value, PtcError> {
        let bad = |message: &str| PtcError::new("InvalidArguments", message);
        for key in request.keys() {
            if !["names", "category", "cursor", "registryVersion"].contains(&key.as_str()) {
                return Err(bad(&format!("Unknown argument: {key}")));
            }
        }
        let names = request.get("names");
        let category = request.get("category");
        let cursor = request.get("cursor");
        let registry_version = request.get("registryVersion");
        if names.is_some() && (category.is_some() || cursor.is_some()) {
            return Err(bad("names cannot be combined with category or cursor"));
        }
        if cursor.is_some() && category.is_none() {
            return Err(bad("cursor needs the category it was issued for"));
        }
        if registry_version.is_some_and(|v| !v.is_string()) {
            return Err(bad("registryVersion must be a string"));
        }
        if cursor.is_some_and(|v| !v.is_string()) {
            return Err(bad("cursor must be a string"));
        }
        if let Some(category) = category {
            let valid = category.as_str().is_some_and(|name| {
                let mut chars = name.chars();
                chars.next().is_some_and(|c| c.is_ascii_lowercase())
                    && chars.all(|c| {
                        c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-'
                    })
            });
            if !valid {
                return Err(bad("category must be a category name from the index"));
            }
        }
        if let Some(names) = names {
            let valid = names.as_array().is_some_and(|list| {
                !list.is_empty()
                    && list.len() <= budgets::DOCS_NAMES
                    && list
                        .iter()
                        .all(|name| name.as_str().is_some_and(is_capability_name))
            });
            if !valid {
                return Err(bad(&format!(
                    "names must be 1–{} capability names",
                    budgets::DOCS_NAMES
                )));
            }
        }
        let available = available(tools);
        let version = version(&available);
        let mut base = Map::new();
        base.insert("registryVersion".to_owned(), json!(version));
        base.insert("contractVersion".to_owned(), json!(CONTRACT_VERSION));
        let with = |extra: Vec<(&str, Value)>| {
            let mut out = base.clone();
            for (key, value) in extra {
                out.insert(key.to_owned(), value);
            }
            Value::Object(out)
        };
        if let Some(Value::String(given)) = registry_version
            && *given != version
        {
            let listed = names
                .and_then(Value::as_array)
                .map(|list| list.iter().map(js::string_of).collect())
                .unwrap_or_default();
            return Err(PtcError::stale(
                format!("Capabilities changed (registry {version}); fetch the docs you need again"),
                listed,
                &version,
            ));
        }

        if let Some(Value::Array(list)) = names {
            let mut requested: Vec<String> = Vec::new();
            for name in list {
                let name = js::string_of(name);
                if !requested.contains(&name) {
                    requested.push(name);
                }
            }
            let missing: Vec<&str> = requested
                .iter()
                .filter(|name| !available.contains_key(*name))
                .map(String::as_str)
                .collect();
            if !missing.is_empty() {
                return Err(PtcError::new(
                    "CapabilityUnavailable",
                    format!(
                        "Not available in this session: {}. ptc_docs({{}}) lists what is.",
                        missing.join(", ")
                    ),
                ));
            }
            let mut items = Vec::new();
            let mut remaining: Vec<String> = Vec::new();
            let mut size = byte_length(&with(vec![
                ("items", json!([])),
                ("truncated", json!(true)),
                ("nextCursor", Value::Null),
                ("remaining", json!(requested)),
            ]));
            for name in &requested {
                let item = contract(&available[name]);
                let item_size = byte_length(&item) + 1;
                if remaining.is_empty() && size + item_size <= budgets::DOCS_OUTPUT_BYTES {
                    items.push(item);
                    size += item_size;
                } else {
                    remaining.push(name.clone());
                }
            }
            if items.is_empty() {
                return Err(PtcError::new(
                    "QuotaExceeded",
                    format!(
                        "The contract of {} is larger than {} bytes",
                        requested[0],
                        budgets::DOCS_OUTPUT_BYTES
                    ),
                ));
            }
            let mut extra = vec![
                ("items", Value::Array(items)),
                ("truncated", json!(!remaining.is_empty())),
                ("nextCursor", Value::Null),
            ];
            if !remaining.is_empty() {
                extra.push(("remaining", json!(remaining)));
            }
            return Ok(with(extra));
        }

        if let Some(Value::String(category)) = category {
            let mut all: Vec<&Capability> = available
                .values()
                .filter(|capability| capability.category == category)
                .collect();
            all.sort_by(|a, b| js::name_order(&a.name, &b.name));
            if all.is_empty() {
                return Err(PtcError::new(
                    "CapabilityUnavailable",
                    format!(
                        "No available capabilities in category {category}. ptc_docs({{}}) lists the categories."
                    ),
                ));
            }
            let offset = match cursor {
                Some(Value::String(cursor)) => self.read_cursor(cursor, category, &version)?,
                _ => 0.0,
            };
            if offset.fract() != 0.0 || offset < 0.0 || offset >= all.len() as f64 {
                return Err(bad("Invalid cursor"));
            }
            let mut items = Vec::new();
            let mut size = byte_length(&with(vec![
                ("category", json!(category)),
                ("items", json!([])),
                ("truncated", json!(true)),
                ("nextCursor", json!("x".repeat(200))),
            ]));
            let mut index = offset as usize;
            while index < all.len() && items.len() < budgets::DOCS_PAGE_ITEMS {
                let capability = all[index];
                let item = json!({
                    "name": capability.name,
                    "uiLabel": label(&capability.name),
                    "summary": summary_of(capability.tool.description(), 160),
                    "effects": capability.meta.effects,
                    "approval": capability.meta.approval,
                });
                let item_size = byte_length(&item) + 1;
                if size + item_size > budgets::DOCS_OUTPUT_BYTES {
                    break;
                }
                items.push(item);
                size += item_size;
                index += 1;
            }
            let more = index < all.len();
            return Ok(with(vec![
                ("category", json!(category)),
                ("items", Value::Array(items)),
                ("truncated", json!(more)),
                (
                    "nextCursor",
                    if more {
                        json!(self.cursor(category, index, &version))
                    } else {
                        Value::Null
                    },
                ),
            ]));
        }

        let categories: Vec<(String, Vec<String>)> = index(&available);
        let listed: Vec<Value> = categories
            .iter()
            .map(|(category, names)| {
                json!({ "category": category, "count": names.len(), "names": names })
            })
            .collect();
        let full = with(vec![
            ("categories", Value::Array(listed)),
            ("truncated", json!(false)),
            ("nextCursor", Value::Null),
        ]);
        if byte_length(&full) <= budgets::DOCS_OUTPUT_BYTES {
            return Ok(full);
        }
        // Too many names for one response: counts only.
        let counts: Vec<Value> = categories
            .iter()
            .map(|(category, names)| json!({ "category": category, "count": names.len() }))
            .collect();
        Ok(with(vec![
            ("categories", Value::Array(counts)),
            ("truncated", json!(true)),
            ("nextCursor", Value::Null),
        ]))
    }
}
