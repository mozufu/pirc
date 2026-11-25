//! What the agent's parts need of the agent itself, so they can be built
//! apart from it: auto mode takes the write lease and asks the human, the
//! PTC surface lists the session's capabilities.

use std::rc::Rc;

use pirc_policy::PathGuard;

use pirc_protocol::Message;

use crate::LocalBoxFuture;
use crate::agent::ResolvedModel;
use crate::auto_mode::{ApprovalMode, default_approval_mode};
use crate::config::AgentConfig;
use crate::session_store::SessionEntry;
use crate::signal::AbortSignal;
use crate::stream::StreamFn;
use crate::tools::Tool;
use crate::ui::Ui;

pub trait AgentHost {
    fn config(&self) -> Rc<AgentConfig>;
    fn guard(&self) -> Rc<PathGuard>;
    fn ui(&self) -> Rc<dyn Ui>;
    fn has_ui(&self) -> bool;
    fn session_id(&self) -> String;
    /// `acquireWrite(file, signal)`: the lease for the root containing it.
    fn acquire_write<'a>(
        &'a self,
        file: &'a str,
        signal: &'a AbortSignal,
    ) -> LocalBoxFuture<'a, Result<(), String>>;
    /// Available internal capabilities (`toolList`).
    fn tool_list(&self) -> Vec<Rc<dyn Tool>>;
    /// Core capabilities the model may also call directly (`directToolList`).
    fn direct_tool_list(&self) -> Vec<Rc<dyn Tool>>;
    /// `resolveModel(ref)`: `None` is the session model. (The defaults
    /// here and below are a host without models or a session, which auto
    /// mode's classifier treats as no model available.)
    fn resolve_model(&self, _reference: Option<(String, String)>) -> Result<ResolvedModel, String> {
        Err("No model configured. Add providers to the gateway models.json".to_owned())
    }
    /// `streamFunction(provider)`: the gateway's inference.
    fn stream_function(&self) -> Option<Rc<dyn StreamFn>> {
        None
    }
    /// `store.contextEntries()`: what the model sees, with entry ids.
    fn context_entries(&self) -> Vec<(String, Message)> {
        Vec::new()
    }
    /// `store.branch()`.
    fn branch(&self) -> Vec<SessionEntry> {
        Vec::new()
    }
    /// The session's approval mode: its own choice, else the node's default.
    fn approval_mode(&self) -> ApprovalMode {
        default_approval_mode(&self.config().features)
    }
}
