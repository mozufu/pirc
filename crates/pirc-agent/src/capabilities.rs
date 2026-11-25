//! Gateway-owned chat policy (`agent/capabilities.ts`): not a process or
//! filesystem sandbox. Missing flags allow.

use serde_json::{Map, Value, json};

pub const CAPABILITY_NAMES: [&str; 4] =
    ["memory_search", "remote_recall", "schedules", "web_search"];

/// `Capabilities`: every flag, `false` only when the gateway said so.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capabilities(Vec<(&'static str, bool)>);

impl Default for Capabilities {
    fn default() -> Self {
        Self::from_value(&Value::Null)
    }
}

impl Capabilities {
    /// `capabilities(value)`.
    pub fn from_value(value: &Value) -> Self {
        let flags = value.as_object();
        Self(
            CAPABILITY_NAMES
                .iter()
                .map(|name| {
                    let allowed = flags.and_then(|f| f.get(*name)) != Some(&Value::Bool(false));
                    (*name, allowed)
                })
                .collect(),
        )
    }

    /// A refresh may update explicit booleans; absent or malformed fields retain policy.
    /// Initial decoding keeps its historical missing-flags-allow contract.
    pub fn refreshed(&self, value: &Value) -> Self {
        Self(
            self.0
                .iter()
                .map(|(name, allowed)| {
                    (
                        *name,
                        value
                            .get(*name)
                            .and_then(Value::as_bool)
                            .unwrap_or(*allowed),
                    )
                })
                .collect(),
        )
    }

    pub fn allows(&self, capability: &str) -> bool {
        self.0
            .iter()
            .find(|(name, _)| *name == capability)
            .is_none_or(|(_, allowed)| *allowed)
    }

    pub fn to_value(&self) -> Value {
        let mut out = Map::new();
        out.insert("version".to_owned(), json!(1));
        for (name, allowed) in &self.0 {
            out.insert((*name).to_owned(), json!(allowed));
        }
        Value::Object(out)
    }
}

/// `capabilityForTool`.
pub fn capability_for_tool(name: &str) -> Option<&'static str> {
    match name {
        "memory_search" => Some("memory_search"),
        "schedule" => Some("schedules"),
        "web_search" => Some("web_search"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_flags_allow() {
        let caps = Capabilities::from_value(&json!({ "web_search": false, "memory_search": "no" }));
        assert!(!caps.allows("web_search"));
        assert!(caps.allows("memory_search"));
        assert_eq!(
            caps.to_value(),
            json!({ "version": 1, "memory_search": true,
                "remote_recall": true, "schedules": true, "web_search": false })
        );
        assert_eq!(capability_for_tool("schedule"), Some("schedules"));
        assert_eq!(capability_for_tool("read"), None);
    }
}

#[cfg(test)]
mod refresh_tests {
    use super::*;
    #[test]
    fn incomplete_refresh_retains_denials_and_accepts_only_explicit_booleans() {
        let old = Capabilities::from_value(&json!({"remote_recall":false,"memory_search":false}));
        for reply in [
            Value::Null,
            json!({}),
            json!({"remote_recall":"true","memory_search":null}),
        ] {
            let next = old.refreshed(&reply);
            assert!(!next.allows("remote_recall") && !next.allows("memory_search"));
            assert!(next.allows("web_search"));
        }
        let next = old.refreshed(&json!({"remote_recall":true,"web_search":false}));
        assert!(next.allows("remote_recall"));
        assert!(!next.allows("memory_search") && !next.allows("web_search"));
    }
}
