use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use std::time::Duration;

use crate::config::Config;
use crate::state::SharedState;
use crate::types::*;

#[derive(Clone)]
struct AppState {
    shared: SharedState,
    config: Config,
}

pub async fn serve(config: Config, state: SharedState) -> anyhow::Result<()> {
    let app_state = AppState {
        shared: state,
        config: config.clone(),
    };

    let app = Router::new()
        .route("/register", post(handle_register))
        .route("/pull", get(handle_pull))
        .route("/push", post(handle_push))
        .route("/health", get(handle_health))
        .route("/status", get(handle_status))
        .with_state(app_state);

    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], config.port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("HTTP bridge listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

// ─── Auth ─────────────────────────────────────────────────────

fn check_auth(headers: &HeaderMap, config: &Config) -> Result<(), (StatusCode, String)> {
    let token = match &config.token {
        Some(t) => t,
        None => return Ok(()), // Auth disabled — allow all requests
    };

    let auth = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let expected = format!("Bearer {token}");
    if auth != expected {
        return Err((
            StatusCode::UNAUTHORIZED,
            "Invalid or missing Authorization header".into(),
        ));
    }
    Ok(())
}

// ─── POST /register ───────────────────────────────────────────

async fn handle_register(
    State(app): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<BridgeRegisterRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    check_auth(&headers, &app.config)?;

    let client_id = uuid::Uuid::new_v4().to_string();
    let version = if body.plugin_version.is_empty() {
        "unknown".to_string()
    } else {
        body.plugin_version
    };

    tracing::info!(client_id = %client_id, plugin_version = %version, "Plugin registered");
    app.shared.register_client(client_id.clone(), version).await;

    Ok(Json(BridgeRegisterResponse {
        client_id,
        server_version: env!("CARGO_PKG_VERSION").to_string(),
    }))
}

// ─── GET /pull?clientId=... ───────────────────────────────────

#[derive(Deserialize)]
struct PullParams {
    #[serde(rename = "clientId")]
    client_id: String,
}

async fn handle_pull(
    State(app): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<PullParams>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    check_auth(&headers, &app.config)?;

    let client_id = &params.client_id;

    // Try immediate drain
    let requests = app.shared.drain_outbound(client_id).await;
    if !requests.is_empty() {
        return Ok(Json(requests));
    }

    // Long-poll: wait up to 25 seconds for new requests
    let notify = app.shared.get_notify(client_id).await;
    if let Some(notify) = notify {
        match tokio::time::timeout(Duration::from_secs(25), notify.notified()).await {
            Ok(_) => {
                let requests = app.shared.drain_outbound(client_id).await;
                Ok(Json(requests))
            }
            Err(_) => {
                // Timeout — return empty
                Ok(Json(vec![]))
            }
        }
    } else {
        Err((StatusCode::NOT_FOUND, "Unknown clientId".into()))
    }
}

// ─── POST /push?clientId=... ──────────────────────────────────

#[derive(Deserialize)]
struct PushParams {
    #[serde(rename = "clientId")]
    client_id: String,
}

async fn handle_push(
    State(app): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<PushParams>,
    Json(body): Json<BridgePushPayload>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    check_auth(&headers, &app.config)?;

    let client_id = &params.client_id;
    tracing::debug!(
        client_id = %client_id,
        responses = body.responses.len(),
        events = body.events.len(),
        "Push received"
    );

    // Resolve pending tool calls
    for response in body.responses {
        let resolved = app
            .shared
            .resolve_pending(&response.request_id, response.clone())
            .await;
        if !resolved {
            tracing::warn!(
                request_id = %response.request_id,
                "No pending call found for response"
            );
        }
    }

    // Process events
    for event in body.events {
        handle_event(&app.shared, &event).await;
    }

    Ok(Json(json!({ "ok": true })))
}

async fn handle_event(state: &SharedState, event: &BridgeEvent) {
    match event.event_type.as_str() {
        "studio.log" => {
            let level = event.data.get("level").and_then(|v| v.as_str()).unwrap_or("output");
            let message = event.data.get("message").and_then(|v| v.as_str()).unwrap_or("");
            let session_id = event.data.get("sessionId").and_then(|v| v.as_str()).map(String::from);
            state.push_log(level.to_string(), message.to_string(), session_id).await;
        }
        "studio.playtest_state" => {
            let active = event.data.get("active").and_then(|v| v.as_bool()).unwrap_or(false);
            let session_id = event.data.get("sessionId").and_then(|v| v.as_str()).map(String::from);
            let mode = event.data.get("mode").and_then(|v| v.as_str()).map(String::from);
            state.update_playtest(active, session_id, mode).await;
        }
        "studio.capture" => {
            tracing::info!(data = ?event.data, "Capture event received");
            // Capture metadata is handled by the captures module when the
            // MCP layer processes the tool result
        }
        other => {
            tracing::debug!(event_type = %other, "Unknown event type");
        }
    }
}

// ─── GET /health ──────────────────────────────────────────────

async fn handle_health() -> &'static str {
    "ok"
}

// ─── GET /status ──────────────────────────────────────────────

async fn handle_status(
    State(app): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    check_auth(&headers, &app.config)?;

    let status = BridgeStatusResponse {
        connected_clients: app.shared.connected_client_count().await,
        pending_calls: app.shared.pending_call_count().await,
        log_buffer_size: app.shared.log_buffer_size().await,
        playtest_active: app.shared.is_playtest_active().await,
    };

    Ok(Json(status))
}
