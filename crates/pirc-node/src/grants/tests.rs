use super::*;
use crate::store::ModeId;
use pirc_protocol::{HttpMethod, NodeHttpRequest};

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    node: Node,
    router: crate::router::Router,
    session: String,
    generation: i64,
}
impl Fixture {
    async fn new(grants: bool) -> Self {
        let (dir, node) = crate::app::tests::workspace_test_node_grants(grants).await;
        let root = dir.path().canonicalize().unwrap();
        for path in ["repo/secrets", "grant-root/shared/inner", "outside"] {
            std::fs::create_dir_all(root.join(path)).unwrap();
        }
        node.db
            .lock()
            .add_workspace(
                "repo",
                "test-node",
                "repo",
                root.join("repo").to_str().unwrap(),
                ModeId::new("directory").unwrap(),
            )
            .unwrap();
        let session = node
            .db
            .lock()
            .create_session("repo", "/private/session", "test-user")
            .unwrap()
            .id;
        let generation = node
            .db
            .lock()
            .acquire_lease(&session, "phone", false, 60_000)
            .unwrap()
            .generation;
        let router = crate::router::Router::new(crate::app::routes(&node.config));
        Self {
            _dir: dir,
            root,
            node,
            router,
            session,
            generation,
        }
    }
    async fn call(&self, method: HttpMethod, path: &str, body: Option<Value>) -> (u16, Value) {
        let response = self
            .router
            .handle(
                &self.node,
                NodeHttpRequest {
                    method,
                    url: format!("/api/sessions/{}/grants{path}", self.session),
                    user: "test-user".into(),
                    payload: body,
                    body_base64: None,
                    content_type: None,
                },
            )
            .await;
        (response.status, response.body.unwrap_or(Value::Null))
    }
    async fn grant(&self, path: &str, access: &str) -> (u16, Value) {
        let path = self.root.join(path);
        self.call(
            HttpMethod::Post,
            "",
            Some(json!({"clientId":"phone","generation":self.generation,"path":path,"access":access})),
        )
        .await
    }
    fn epoch(&self) -> i64 {
        self.node
            .db
            .lock()
            .get_session(&self.session)
            .unwrap()
            .runner_epoch
    }
}

#[tokio::test]
async fn grants_need_configured_roots_and_stay_inside_them() {
    let none = Fixture::new(false).await;
    let (status, refused) = none.grant("grant-root/shared", "write").await;
    assert_eq!(
        (status, refused["error"]["code"].clone()),
        (409, json!("folder_grants_unavailable"))
    );
    none.node.close().await;

    let f = Fixture::new(true).await;
    let (status, outside) = f.grant("outside", "write").await;
    assert_eq!(
        (status, outside["error"]["code"].clone()),
        (403, json!("folder_outside_grant_roots"))
    );
    let (status, missing) = f.grant("grant-root/absent", "read").await;
    assert_eq!(
        (status, missing["error"]["code"].clone()),
        (404, json!("folder_not_found"))
    );
    let (status, private) = f.grant("state", "deny").await;
    assert_ne!(status, 200, "{private}");
    // A deny may target the workspace itself, outside any grant root.
    let (status, deny) = f.grant("repo/secrets", "deny").await;
    assert_eq!(status, 200, "{deny}");
    // Without current control nothing changes.
    let (status, _) = f
        .call(HttpMethod::Post, "", Some(json!({"clientId":"tablet","generation":99,"path":f.root.join("grant-root/shared"),"access":"write"})))
        .await;
    assert_ne!(status, 200);
    f.node.close().await;
}

#[tokio::test]
async fn deny_overrides_grants_revocation_fences_and_host_execution_is_refused() {
    let f = Fixture::new(true).await;
    let before = f.epoch();
    let (status, write) = f.grant("grant-root/shared", "write").await;
    assert_eq!(status, 200, "{write}");
    assert_eq!(f.epoch(), before + 1);
    assert_eq!(write["fence"]["runnerWasLive"], false);
    let (_, read) = f.grant("grant-root/shared/inner", "read").await;
    let inner = read["effectiveAccess"]["grants"]
        .as_array()
        .unwrap()
        .iter()
        .find(|g| g["access"] == "read")
        .unwrap()
        .clone();
    // A read alias under a write grant discloses the effective write.
    assert_eq!(inner["effective"], "write");
    assert!(inner["writableVia"].is_string());
    let (_, denied) = f.grant("grant-root/shared", "deny").await;
    let grants = denied["effectiveAccess"]["grants"]
        .as_array()
        .unwrap()
        .clone();
    assert!(
        grants
            .iter()
            .filter(|g| g["access"] != "deny")
            .all(|g| g["effective"] == "deny")
    );
    assert_eq!(denied["effectiveAccess"]["hostExecutionRefused"], true);
    // Host management cannot enforce the deny, so it is refused.
    let host = crate::terminals::host::handle(
        &f.node,
        "test-user",
        &f.session,
        &f.root.join("repo"),
        &json!({"requestId":"h1","action":"review","executionPath":"host_management"}),
        ("phone", f.generation),
        (None, None),
    );
    assert_eq!(host.unwrap_err().code, "folder_deny_unenforceable_on_host");
    // Revoking the deny lifts the refusal and fences again.
    let deny_id = grants.iter().find(|g| g["access"] == "deny").unwrap()["grantId"]
        .as_str()
        .unwrap()
        .to_owned();
    let epoch = f.epoch();
    let (status, revoked) = f
        .call(
            HttpMethod::Post,
            &format!("/{deny_id}/revoke"),
            Some(json!({"clientId":"phone","generation":f.generation})),
        )
        .await;
    assert_eq!(status, 200, "{revoked}");
    assert_eq!(f.epoch(), epoch + 1);
    assert_eq!(revoked["effectiveAccess"]["hostExecutionRefused"], false);
    assert!(require_no_deny(&f.node.db.lock(), &f.session).is_ok());
    let (_, listed) = f.call(HttpMethod::Get, "", None).await;
    assert_eq!(listed["grantsEnabled"], true);
    assert_eq!(
        listed["effectiveAccess"]["grants"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(
        f.node
            .db
            .lock()
            .execute("UPDATE folder_grants SET access='write'", [])
            .is_err()
    );
    f.node.close().await;
}
