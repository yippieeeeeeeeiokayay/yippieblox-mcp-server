use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{Mutex, Notify, oneshot};

use crate::types::{BridgeToolRequest, BridgeToolResponse, LogEntry};

#[derive(Clone)]
pub struct SharedState(Arc<Inner>);

struct Inner {
    clients: Mutex<HashMap<String, ClientState>>,
    pending_calls: Mutex<HashMap<String, oneshot::Sender<BridgeToolResponse>>>,
    log_buffer: Mutex<VecDeque<LogEntry>>,
    log_seq: Mutex<u64>,
    playtest_state: Mutex<PlaytestState>,
    capture_dir: PathBuf,
}

struct ClientState {
    #[allow(dead_code)]
    plugin_version: String,
    outbound_queue: VecDeque<BridgeToolRequest>,
    notify: Arc<Notify>,
    #[allow(dead_code)]
    last_poll: chrono::DateTime<chrono::Utc>,
}

#[derive(Default)]
pub struct PlaytestState {
    pub active: bool,
    pub session_id: Option<String>,
    pub mode: Option<String>,
}

const MAX_LOG_BUFFER: usize = 500;

impl SharedState {
    pub fn new(capture_dir: PathBuf) -> Self {
        Self(Arc::new(Inner {
            clients: Mutex::new(HashMap::new()),
            pending_calls: Mutex::new(HashMap::new()),
            log_buffer: Mutex::new(VecDeque::with_capacity(MAX_LOG_BUFFER)),
            log_seq: Mutex::new(0),
            playtest_state: Mutex::new(PlaytestState::default()),
            capture_dir,
        }))
    }

    pub fn capture_dir(&self) -> &PathBuf {
        &self.0.capture_dir
    }

    // ─── Client Management ────────────────────────────────────

    pub async fn register_client(&self, client_id: String, plugin_version: String) {
        let mut clients = self.0.clients.lock().await;
        clients.insert(
            client_id,
            ClientState {
                plugin_version,
                outbound_queue: VecDeque::new(),
                notify: Arc::new(Notify::new()),
                last_poll: chrono::Utc::now(),
            },
        );
    }

    pub async fn remove_client(&self, client_id: &str) {
        self.0.clients.lock().await.remove(client_id);
    }

    pub async fn has_connected_client(&self) -> bool {
        !self.0.clients.lock().await.is_empty()
    }

    pub async fn connected_client_count(&self) -> usize {
        self.0.clients.lock().await.len()
    }

    pub async fn first_client_id(&self) -> Option<String> {
        self.0.clients.lock().await.keys().next().cloned()
    }

    // ─── Tool Request Queuing ─────────────────────────────────

    /// Enqueue a tool request for the most recently active client (by last poll time).
    /// This ensures requests go to the playtest bridge during playtest (it polls actively)
    /// rather than the paused plugin client.
    /// Returns false if no client is connected.
    pub async fn enqueue_tool_request(&self, request: BridgeToolRequest) -> bool {
        let mut clients = self.0.clients.lock().await;
        if let Some(client) = clients.values_mut().max_by_key(|c| c.last_poll) {
            client.outbound_queue.push_back(request);
            client.notify.notify_one();
            true
        } else {
            false
        }
    }

    /// Drain all pending outbound requests for a client.
    pub async fn drain_outbound(&self, client_id: &str) -> Vec<BridgeToolRequest> {
        let mut clients = self.0.clients.lock().await;
        if let Some(client) = clients.get_mut(client_id) {
            client.last_poll = chrono::Utc::now();
            client.outbound_queue.drain(..).collect()
        } else {
            vec![]
        }
    }

    /// Get the Notify handle for long-poll wakeup.
    pub async fn get_notify(&self, client_id: &str) -> Option<Arc<Notify>> {
        let clients = self.0.clients.lock().await;
        clients.get(client_id).map(|c| c.notify.clone())
    }

    // ─── Pending Calls ────────────────────────────────────────

    pub async fn register_pending(
        &self,
        request_id: String,
        sender: oneshot::Sender<BridgeToolResponse>,
    ) {
        self.0
            .pending_calls
            .lock()
            .await
            .insert(request_id, sender);
    }

    /// Resolve a pending call. Returns true if the call was found and resolved.
    pub async fn resolve_pending(&self, request_id: &str, response: BridgeToolResponse) -> bool {
        if let Some(sender) = self.0.pending_calls.lock().await.remove(request_id) {
            let _ = sender.send(response);
            true
        } else {
            false
        }
    }

    pub async fn pending_call_count(&self) -> usize {
        self.0.pending_calls.lock().await.len()
    }

    // ─── Log Buffer ───────────────────────────────────────────

    pub async fn push_log(&self, level: String, message: String, session_id: Option<String>) {
        let mut seq = self.0.log_seq.lock().await;
        *seq += 1;
        let entry = LogEntry {
            seq: *seq,
            ts: chrono::Utc::now().timestamp_millis() as f64 / 1000.0,
            level,
            message,
            session_id,
        };
        drop(seq);

        let mut buf = self.0.log_buffer.lock().await;
        if buf.len() >= MAX_LOG_BUFFER {
            buf.pop_front();
        }
        buf.push_back(entry);
    }

    pub async fn get_logs(&self, since_seq: u64, limit: usize) -> Vec<LogEntry> {
        let buf = self.0.log_buffer.lock().await;
        buf.iter()
            .filter(|e| e.seq > since_seq)
            .take(limit)
            .cloned()
            .collect()
    }

    pub async fn log_buffer_size(&self) -> usize {
        self.0.log_buffer.lock().await.len()
    }

    // ─── Playtest State ───────────────────────────────────────

    pub async fn update_playtest(&self, active: bool, session_id: Option<String>, mode: Option<String>) {
        let mut state = self.0.playtest_state.lock().await;
        state.active = active;
        state.session_id = session_id;
        state.mode = mode;
    }

    pub async fn is_playtest_active(&self) -> bool {
        self.0.playtest_state.lock().await.active
    }

    pub async fn playtest_info(&self) -> (bool, Option<String>, Option<String>) {
        let state = self.0.playtest_state.lock().await;
        (state.active, state.session_id.clone(), state.mode.clone())
    }
}
