use serde::{Deserialize, Serialize};
use serde_json::Value;

// ─── JSON-RPC 2.0 ────────────────────────────────────────────

/// Incoming JSON-RPC message (request or notification).
/// If `id` is None, it's a notification.
#[derive(Debug, Deserialize)]
pub struct JsonRpcMessage {
    pub jsonrpc: String,
    pub id: Option<Value>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
pub struct JsonRpcError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct JsonRpcNotification {
    pub jsonrpc: String,
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

// ─── MCP Types ────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct McpToolDef {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(rename = "inputSchema")]
    pub input_schema: Value,
}

#[derive(Debug, Serialize)]
pub struct McpToolResult {
    pub content: Vec<McpContent>,
    #[serde(rename = "isError")]
    pub is_error: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "type")]
pub enum McpContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image {
        data: String,
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
}

// ─── Bridge Types (Rust ↔ Studio Plugin) ──────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BridgeToolRequest {
    pub request_id: String,
    pub tool_name: String,
    pub arguments: Value,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BridgeToolResponse {
    pub request_id: String,
    pub success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct BridgeRegisterRequest {
    #[serde(default)]
    pub plugin_version: String,
}

#[derive(Debug, Serialize)]
pub struct BridgeRegisterResponse {
    pub client_id: String,
    pub server_version: String,
}

#[derive(Debug, Deserialize)]
pub struct BridgePushPayload {
    #[serde(default)]
    pub responses: Vec<BridgeToolResponse>,
    #[serde(default)]
    pub events: Vec<BridgeEvent>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BridgeEvent {
    pub event_type: String,
    pub data: Value,
}

#[derive(Debug, Serialize)]
pub struct BridgeStatusResponse {
    pub connected_clients: usize,
    pub pending_calls: usize,
    pub log_buffer_size: usize,
    pub playtest_active: bool,
}

// ─── Domain Types ─────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct LogEntry {
    pub seq: u64,
    pub ts: f64,
    pub level: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CaptureMetadata {
    pub id: String,
    pub capture_type: String,
    pub timestamp: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
}

// ─── Helpers ──────────────────────────────────────────────────

impl JsonRpcResponse {
    pub fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Value, code: i64, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: "2.0".into(),
            id,
            result: None,
            error: Some(JsonRpcError {
                code,
                message: message.into(),
                data: None,
            }),
        }
    }
}

impl McpToolResult {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![McpContent::Text { text: text.into() }],
            is_error: false,
        }
    }

    pub fn error_text(text: impl Into<String>) -> Self {
        Self {
            content: vec![McpContent::Text { text: text.into() }],
            is_error: true,
        }
    }

    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}
