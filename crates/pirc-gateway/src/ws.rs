//! A WebSocket's sending half as the TS gateway used the `ws` library: sends
//! never wait, the bytes not yet written are counted (`bufferedAmount`), and
//! a close frame ends the queue.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::{Notify, mpsc};

pub(crate) enum Outgoing {
    Text(String),
    Close(u16, String),
}

pub struct Outbox {
    queue: mpsc::UnboundedSender<Outgoing>,
    buffered: AtomicUsize,
    open: AtomicBool,
    closed: Notify,
}

impl Outbox {
    /// Split `socket`: the returned outbox sends (from a writer task), the
    /// stream receives.
    pub fn start(socket: WebSocket) -> (Arc<Self>, SplitStream<WebSocket>) {
        let (sink, stream) = socket.split();
        let (queue, receiver) = mpsc::unbounded_channel();
        let outbox = Arc::new(Self {
            queue,
            buffered: AtomicUsize::new(0),
            open: AtomicBool::new(true),
            closed: Notify::new(),
        });
        tokio::spawn(write(outbox.clone(), sink, receiver));
        (outbox, stream)
    }

    /// An outbox with no socket behind it: what it is asked to send queues
    /// in the returned receiver, where a test can count it.
    #[cfg(test)]
    pub(crate) fn detached() -> (Arc<Self>, mpsc::UnboundedReceiver<Outgoing>) {
        let (queue, receiver) = mpsc::unbounded_channel();
        let outbox = Arc::new(Self {
            queue,
            buffered: AtomicUsize::new(0),
            open: AtomicBool::new(true),
            closed: Notify::new(),
        });
        (outbox, receiver)
    }

    /// Count `bytes` as queued and unwritten (a stalled link).
    #[cfg(test)]
    pub(crate) fn pretend_buffered(&self, bytes: usize) {
        self.buffered.fetch_add(bytes, Ordering::AcqRel);
    }

    pub fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    /// Bytes queued and not yet written.
    pub fn buffered(&self) -> usize {
        self.buffered.load(Ordering::Acquire)
    }

    /// Queue a text frame; `false` once the socket is closing.
    pub fn send(&self, text: String) -> bool {
        if !self.is_open() {
            return false;
        }
        self.buffered.fetch_add(text.len(), Ordering::AcqRel);
        if self.queue.send(Outgoing::Text(text)).is_err() {
            self.mark_closed();
            return false;
        }
        true
    }

    /// Send a close frame after what is queued; later sends are dropped.
    /// The reason is cut to 123 bytes (the protocol's limit).
    pub fn close(&self, code: u16, reason: &str) {
        if self.open.swap(false, Ordering::AcqRel) {
            let mut end = reason.len().min(123);
            while !reason.is_char_boundary(end) {
                end -= 1;
            }
            let _ = self
                .queue
                .send(Outgoing::Close(code, reason[..end].to_owned()));
            self.closed.notify_waiters();
        }
    }

    fn mark_closed(&self) {
        self.open.store(false, Ordering::Release);
        self.closed.notify_waiters();
    }

    /// Resolves once the socket is closing.
    pub async fn closing(&self) {
        let notified = self.closed.notified();
        if !self.is_open() {
            return;
        }
        notified.await;
    }
}

async fn write(
    outbox: Arc<Outbox>,
    mut sink: SplitSink<WebSocket, Message>,
    mut receiver: mpsc::UnboundedReceiver<Outgoing>,
) {
    while let Some(item) = receiver.recv().await {
        match item {
            Outgoing::Text(text) => {
                let length = text.len();
                let sent = sink.send(Message::Text(text.into())).await;
                outbox.buffered.fetch_sub(length, Ordering::AcqRel);
                if sent.is_err() {
                    break;
                }
            }
            Outgoing::Close(code, reason) => {
                let _ = sink
                    .send(Message::Close(Some(CloseFrame {
                        code,
                        reason: reason.into(),
                    })))
                    .await;
                break;
            }
        }
    }
    outbox.mark_closed();
}

/// How long a closing socket waits for the peer's close frame.
const CLOSE_GRACE: Duration = Duration::from_secs(5);

/// What the receive loop saw.
pub enum Received {
    Text(String),
    Binary(Vec<u8>),
    /// Larger than the socket's message limit.
    TooLarge,
}

/// Run `on_message` for each message until the socket ends (the peer's
/// close, an error, or our own close and then the peer's answer).
pub async fn receive(
    outbox: &Outbox,
    stream: &mut SplitStream<WebSocket>,
    mut on_message: impl FnMut(Received),
) {
    loop {
        let next = tokio::select! {
            next = stream.next() => next,
            () = outbox.closing() => break,
        };
        match next {
            Some(Ok(Message::Text(text))) => on_message(Received::Text(text.to_string())),
            Some(Ok(Message::Binary(bytes))) => on_message(Received::Binary(bytes.to_vec())),
            Some(Ok(Message::Close(_))) | None => {
                outbox.mark_closed();
                return;
            }
            Some(Ok(_)) => {}
            // tungstenite's `CapacityError`, which axum does not expose.
            Some(Err(error)) if error.to_string().contains("Space limit exceeded") => {
                on_message(Received::TooLarge);
                break;
            }
            Some(Err(_)) => {
                outbox.mark_closed();
                return;
            }
        }
    }
    // Our close: wait (a little) for the peer's.
    let _ = tokio::time::timeout(CLOSE_GRACE, async {
        while let Some(Ok(message)) = stream.next().await {
            if matches!(message, Message::Close(_)) {
                break;
            }
        }
    })
    .await;
}
