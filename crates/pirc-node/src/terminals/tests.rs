//! TS has no tests of the PTY side; these cover its rules: sizes, limits,
//! output, replay, exit codes, closing and the scrollback.

use std::sync::Weak;

use tokio::sync::mpsc::UnboundedReceiver;

use super::*;

fn env() -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("PATH".to_owned(), std::env::var("PATH").unwrap_or_default());
    // No user profile: `-l` reads $HOME/.profile only for some shells.
    env.insert("HOME".to_owned(), "/nonexistent".to_owned());
    env.insert("PS1".to_owned(), "$ ".to_owned());
    env
}

fn terminals() -> Terminals {
    Terminals::new(Weak::new())
}

fn open(terminals: &Terminals, session: &str, cols: f64, rows: f64) -> ApiResult<TerminalInfo> {
    terminals.spawn(
        session,
        Path::new("/"),
        cols,
        rows,
        "/bin/sh",
        Environment {
            host: None,
            work: None,
            vars: env(),
            binding: None,
            journal: None,
        },
    )
}

/// Attach and collect events in a channel.
fn watch(
    terminals: &Terminals,
    session: &str,
    id: &str,
) -> (Attached, UnboundedReceiver<TerminalEvent>) {
    let (sender, receiver) = mpsc::unbounded_channel();
    let listener: Listener = Arc::new(move |event: &TerminalEvent| {
        let _ = sender.send(event.clone());
    });
    let attached = terminals.attach(session, id, listener, |_, _| {}).unwrap();
    (attached, receiver)
}

/// Output until it holds `marker`; panics on an exit or after 10 s.
async fn until(events: &mut UnboundedReceiver<TerminalEvent>, marker: &str) -> String {
    let mut output = String::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !output.contains(marker) {
            match events.recv().await {
                Some(TerminalEvent::Output(data)) => output.push_str(&data),
                other => panic!("{other:?} before {marker}; output {output:?}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no {marker}; output {output:?}"));
    output
}

async fn exit_of(events: &mut UnboundedReceiver<TerminalEvent>) -> Option<i32> {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match events.recv().await {
                Some(TerminalEvent::Exit(code)) => return code,
                Some(TerminalEvent::Output(_)) => {}
                None => panic!("no exit"),
            }
        }
    })
    .await
    .expect("an exit")
}

#[test]
fn clamps_sizes_and_picks_shells() {
    assert_eq!(clamp(5.0, 20, 500, 80), 20);
    assert_eq!(clamp(10_000.0, 20, 500, 80), 500);
    assert_eq!(clamp(100.9, 20, 500, 80), 100);
    assert_eq!(clamp(f64::NAN, 20, 500, 80), 80);
    assert_eq!(clamp(0.0, 5, 200, 24), 5);
    assert_eq!(
        default_shell(Some("/bin/zsh"), Some("/bin/bash")),
        "/bin/zsh"
    );
    assert_eq!(default_shell(Some("zsh"), Some("/bin/bash")), "/bin/bash");
    assert_eq!(default_shell(None, Some("bash")), "/bin/sh");
}

#[test]
fn decodes_utf8_streams_as_text_decoder() {
    let mut stream = Utf8Stream::default();
    assert_eq!(stream.decode(b"\xef\xbb\xbfa\xc3"), "a");
    assert_eq!(stream.decode(b"\xa9\xff b"), "é\u{FFFD} b");
    // The BOM is dropped once, at the start only.
    assert_eq!(stream.decode("\u{FEFF}".as_bytes()), "\u{FEFF}");
    assert_eq!(stream.decode(b"\xe2\x9c"), "");
    assert_eq!(stream.finish(), "\u{FFFD}");
    let mut replay = Utf8Stream::default();
    assert_eq!(replay.decode(b"\xa9ok"), "\u{FFFD}ok");
}

#[test]
fn scrollback_drops_whole_chunks_but_never_the_last() {
    let (pty, _) = mpsc::unbounded_channel();
    let (_, exited) = watch::channel(None);
    let entry = Entry {
        host_management: false,
        record: None,
        binding: None,
        stopping: watch::channel(false).0,
        state: Mutex::new(EntryState {
            closing: false,
            info: TerminalInfo {
                execution_path: None,
                id: "t".into(),
                session_id: "s".into(),
                title: "sh".into(),
                cwd: "/".into(),
                cols: 80,
                rows: 24,
                created_at: 0,
                exit_code: None,
                exited: false,
            },
            scrollback: VecDeque::new(),
            scrollback_bytes: 0,
            listeners: Vec::new(),
            decoder: Utf8Stream::default(),
        }),
        pty,
        exited,
    };
    output(&entry, &vec![b'a'; 200 * 1024]);
    output(&entry, &vec![b'b'; 100 * 1024]);
    assert_eq!(entry.state().scrollback.len(), 1);
    assert_eq!(entry.state().scrollback_bytes, 100 * 1024);
    output(&entry, &vec![b'c'; 300 * 1024]);
    // Over the limit alone, it stays.
    assert_eq!(entry.state().scrollback.len(), 1);
    assert_eq!(entry.state().scrollback_bytes, 300 * 1024);
}

#[tokio::test(flavor = "multi_thread")]
async fn runs_a_login_shell_in_a_pty() {
    let terminals = terminals();
    let info = open(&terminals, "s", 100.0, 30.0).unwrap();
    assert_eq!(info.id.len(), 8);
    assert_eq!((info.cols, info.rows, info.title.as_str()), (100, 30, "sh"));
    assert!(!info.exited);
    let (attached, mut events) = watch(&terminals, "s", &info.id);
    assert_eq!(attached.info, info);

    terminals
        .input("s", &info.id, "printf 'MARK-%s\\n' $((6*7))\n")
        .unwrap();
    until(&mut events, "MARK-42").await;
    terminals
        .input(
            "s",
            &info.id,
            "printf 'TERM-%s-%s\\n' \"$TERM\" \"$PIRC_TERMINAL\"\n",
        )
        .unwrap();
    until(&mut events, "TERM-xterm-256color-1").await;
    terminals.resize("s", &info.id, 120.0, 40.0).unwrap();
    terminals
        .input(
            "s",
            &info.id,
            "printf 'SIZE-%s\\n' \"$(stty size | tr ' ' x)\"\n",
        )
        .unwrap();
    until(&mut events, "SIZE-40x120").await;
    // Over the input limit: dropped.
    let mut big = String::from("printf 'OVER-%s\\n' $((2+2))\n:");
    big.push_str(&"x".repeat(INPUT_MAX_UNITS - big.len()));
    big.push('\n');
    terminals.input("s", &info.id, &big).unwrap();
    terminals
        .input("s", &info.id, "printf 'AFTER-%s\\n' $((3+3))\n")
        .unwrap();
    let output = until(&mut events, "AFTER-6").await;
    assert!(!output.contains("OVER-4"));

    // A second attach replays the scrollback.
    let (again, mut second) = watch(&terminals, "s", &info.id);
    assert!(again.replay.contains("MARK-42"));
    assert_eq!((again.info.cols, again.info.rows), (120, 40));

    terminals.input("s", &info.id, "exit 3\n").unwrap();
    assert_eq!(exit_of(&mut events).await, Some(3));
    assert_eq!(exit_of(&mut second).await, Some(3));
    let listed = terminals.list("s");
    assert_eq!(listed.len(), 1);
    assert!(listed[0].exited);
    assert_eq!(listed[0].exit_code, Some(3));
    // Exited: input and resize are ignored.
    terminals.input("s", &info.id, "echo x\n").unwrap();
    terminals.resize("s", &info.id, 50.0, 10.0).unwrap();
    assert_eq!(terminals.list("s")[0].cols, 120);
    assert!(terminals.list("other").is_empty());
    assert_eq!(
        terminals
            .attach("other", &info.id, Arc::new(|_| {}), |_, _| {})
            .err(),
        Some(ApiError::not_found("Terminal not found"))
    );
}

/// The shell leads its own session with the PTY as its controlling
/// terminal (`/dev/tty` opens; Linux: its session id is its pid) and job
/// control on, as with pty-process's `setsid` and `TIOCSCTTY`.
#[tokio::test(flavor = "multi_thread")]
async fn the_shell_leads_a_session_on_its_terminal() {
    let terminals = terminals();
    let info = open(&terminals, "s", 80.0, 24.0).unwrap();
    let (_, mut events) = watch(&terminals, "s", &info.id);
    // Markers are quoted apart so the echoed input never matches them.
    terminals
        .input(
            "s",
            &info.id,
            "if : </dev/tty; then echo CT\"\"TY-yes; else echo CT\"\"TY-no; fi\n",
        )
        .unwrap();
    until(&mut events, "CTTY-yes").await;
    terminals
        .input(
            "s",
            &info.id,
            "case $- in *m*) echo JO\"\"BS-on;; *) echo JO\"\"BS-off;; esac\n",
        )
        .unwrap();
    until(&mut events, "JOBS-on").await;
    if cfg!(target_os = "linux") {
        terminals
            .input(
                "s",
                &info.id,
                "set -- $(cut -d' ' -f5,6 /proc/$$/stat); echo \"S\"\"ID=$1:$2:$$=E\"\"ND\"\n",
            )
            .unwrap();
        let output = until(&mut events, "=END").await;
        let ids = output.rsplit("SID=").next().unwrap();
        let ids: Vec<&str> = ids.split("=END").next().unwrap().split(':').collect();
        // Process group, session and pid are one.
        assert!(
            ids.len() == 3 && ids[0] == ids[2] && ids[1] == ids[2],
            "{output:?}"
        );
    }
    terminals.close("s", &info.id).unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn limits_and_closing() {
    let terminals = terminals();
    let first = open(&terminals, "s", f64::NAN, f64::NAN).unwrap();
    assert_eq!((first.cols, first.rows), (80, 24));
    let (_, mut events) = watch(&terminals, "s", &first.id);
    for _ in 0..3 {
        open(&terminals, "s", 5.0, 1000.0).unwrap();
    }
    assert_eq!(
        open(&terminals, "s", 80.0, 24.0).err(),
        Some(ApiError::conflict("At most 4 terminals per session"))
    );
    // Another session still has room.
    let other = open(&terminals, "t", 80.0, 24.0).unwrap();

    // Closing tells listeners immediately; the quota frees only after settling.
    let first_entry = terminals.lookup("s", &first.id).unwrap();
    terminals.close("s", &first.id).unwrap();
    assert_eq!(exit_of(&mut events).await, None);
    assert_eq!(
        terminals.close("s", &first.id).err(),
        Some(ApiError::not_found("Terminal not found"))
    );
    assert_eq!(terminals.list("s").len(), 3);
    supervision::settle(vec![first_entry]).await.unwrap();
    open(&terminals, "s", 80.0, 24.0).unwrap();

    // An exited terminal does not count, and the next open drops it.
    let (_, mut other_events) = watch(&terminals, "t", &other.id);
    terminals.input("t", &other.id, "kill -9 $$\n").unwrap();
    assert_eq!(exit_of(&mut other_events).await, None);
    assert_eq!(terminals.list("t").len(), 1);
    open(&terminals, "t", 80.0, 24.0).unwrap();
    assert_eq!(terminals.list("t").len(), 1);

    tokio::time::timeout(Duration::from_secs(10), terminals.dispose_session("s"))
        .await
        .expect("the shells exit on SIGHUP")
        .unwrap();
    assert!(terminals.list("s").is_empty());
    terminals.shutdown().await;
    assert!(terminals.list("t").is_empty());
    assert_eq!(
        open(&terminals, "t", 80.0, 24.0).err(),
        Some(ApiError::runner_unavailable("Gateway is shutting down"))
    );
}
