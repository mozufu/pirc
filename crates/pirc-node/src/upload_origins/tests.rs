use super::*;
use crate::store::{Db, ModeId, UploadKind};
fn setup(db: &Connection) -> (String, String) {
    for (id, path) in [("repo", "/repo"), ("other", "/other")] {
        db.add_workspace(id, "node", id, path, ModeId::new("directory").unwrap())
            .unwrap();
    }
    (
        db.create_session("repo", "/session-a", "alice").unwrap().id,
        db.create_session("repo", "/session-b", "alice").unwrap().id,
    )
}
fn upload(session: &str) -> UploadRow {
    UploadRow {
        id: "file".into(),
        owner_user: "alice".into(),
        mime_type: "text/plain".into(),
        byte_size: 4,
        storage_name: "saved.bin".into(),
        sha256: crate::util::sha256_hex(b"test"),
        kind: UploadKind::File,
        filename: Some("input.txt".into()),
        workspace_id: Some("repo".into()),
        session_id: Some(session.into()),
    }
}
fn first(db: &Connection, upload: &UploadRow) {
    db.execute("INSERT INTO creation_uploads(owner_user,operation_id,attachment_id,session_id,upload_id,request_hash,upload_json,state,created_at) VALUES('alice','op','a',?1,?2,?3,?4,'ready',1)",rusqlite::params![upload.session_id,upload.id,"a".repeat(64),serde_json::to_string(upload).unwrap()]).unwrap();
}
#[test]
fn origin_survives_moving_the_source_session_and_restarting_without_relabelling() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("db");
    let (a, b, u, saved) = {
        let db = Db::open(&path).unwrap();
        let db = db.lock();
        let (a, b) = setup(&db);
        let u = upload(&a);
        db.create_upload(&u).unwrap();
        let saved = reference(&db, &b, "alice", "file").unwrap();
        db.execute("UPDATE sessions SET workspace_id='other' WHERE id=?", [&a])
            .unwrap();
        assert!(authorize(&db, &a, "alice", "file").is_err());
        assert_eq!(reference(&db, &b, "alice", "file").unwrap(), saved);
        (a, b, u, saved)
    };
    let db = Db::open(&path).unwrap();
    let db = db.lock();
    assert_eq!(origin(&db, "file").unwrap().unwrap().upload, u);
    assert_eq!(reference(&db, &b, "alice", "file").unwrap(), saved);
    assert!(authorize(&db, &a, "alice", "file").is_err());
    assert_eq!(saved["origin"]["workspaceId"], "repo");
    assert_eq!(saved["origin"]["modeId"], "directory");
    assert_eq!(saved["scope"], "workspace");
}
#[test]
fn first_send_scope_survives_loss_of_the_transfer_index_and_never_broadens() {
    let db = Db::memory();
    let db = db.lock();
    let (a, b) = setup(&db);
    let u = upload(&a);
    first(&db, &u);
    db.create_upload(&u).unwrap();
    assert_eq!(
        reference(&db, &a, "alice", "file").unwrap()["scope"],
        "conversation"
    );
    assert!(authorize(&db, &b, "alice", "file").is_err());
    db.execute("DELETE FROM creation_uploads", []).unwrap();
    assert!(authorize(&db, &b, "alice", "file").is_err());
    assert!(authorize(&db, &a, "alice", "file").is_ok());
    assert!(authorize(&db, &a, "bob", "file").is_err());
    db.begin_session_deletion(&a, "alice").unwrap();
    assert!(authorize(&db, &a, "alice", "file").is_err());
}
#[test]
fn immutable_origin_and_upload_cascade_preserve_existing_deletion_rules() {
    let db = Db::memory();
    let db = db.lock();
    let (a, _) = setup(&db);
    db.create_upload(&upload(&a)).unwrap();
    for sql in [
        "UPDATE uploads SET workspace_id='other'",
        "UPDATE uploads SET sha256='changed'",
        "UPDATE upload_origins SET scope='legacy_owner'",
        "DELETE FROM upload_origins",
    ] {
        assert!(db.execute(sql, []).is_err(), "{sql}");
    }
    db.execute("DELETE FROM uploads WHERE id='file'", [])
        .unwrap();
    assert!(origin(&db, "file").unwrap().is_none());
}
#[test]
fn metadata_failure_rolls_back_the_original_upload_insert() {
    let db = Db::memory();
    let db = db.lock();
    let (a, _) = setup(&db);
    db.execute_batch("CREATE TRIGGER fail_origin BEFORE INSERT ON upload_origins BEGIN SELECT RAISE(ABORT,'disk full'); END;").unwrap();
    assert!(db.create_upload(&upload(&a)).is_err());
    assert!(db.get_upload("file").is_err());
}
#[test]
fn saved_bytes_refuse_same_length_changes_symlinks_and_unexpected_size() {
    let dir = tempfile::tempdir().unwrap();
    let u = upload("a");
    let file = dir.path().join(&u.storage_name);
    std::fs::write(&file, b"test").unwrap();
    assert_eq!(read_verified(dir.path(), &u).unwrap(), b"test");
    std::fs::write(&file, b"evil").unwrap();
    assert!(read_verified(dir.path(), &u).is_err());
    std::fs::write(&file, b"test-later").unwrap();
    assert!(read_verified(dir.path(), &u).is_err());
    std::fs::remove_file(&file).unwrap();
    let outside = dir.path().join("outside");
    std::fs::write(&outside, b"test").unwrap();
    std::os::unix::fs::symlink(&outside, &file).unwrap();
    assert!(read_verified(dir.path(), &u).is_err());
    let mut escape = u.clone();
    escape.storage_name = "../outside".into();
    assert!(read_verified(dir.path(), &escape).is_err());
    assert_eq!(std::fs::read(&outside).unwrap(), b"test");
}
