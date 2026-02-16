mod bridge_http;
mod captures;
mod config;
mod mcp_stdio;
mod state;
mod types;

use anyhow::Result;
use clap::Parser;
use std::fs::OpenOptions;

#[derive(Parser)]
#[command(name = "roblox-studio-yippieblox-mcp-server")]
#[command(about = "MCP server bridging AI coding assistants with Roblox Studio")]
struct Cli {
    /// Run in STDIO mode (required for MCP clients like Claude Code / Claude Desktop)
    #[arg(long)]
    stdio: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let _cli = Cli::parse();

    // Log to both stderr AND a file so logs are always accessible.
    // tail -f ~/.yippieblox-mcp.log to watch live.
    let log_path = std::env::var("HOME")
        .map(|h| format!("{h}/.yippieblox-mcp.log"))
        .unwrap_or_else(|_| "/tmp/yippieblox-mcp.log".into());

    let log_file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .expect("Failed to open log file");

    tracing_subscriber::fmt()
        .with_writer(std::sync::Mutex::new(log_file))
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_ansi(false)
        .init();

    eprintln!("Logs: {log_path}");

    let config = config::load()?;
    tracing::info!(
        port = config.port,
        capture_dir = %config.capture_dir.display(),
        "YippieBlox MCP Server starting"
    );

    let state = state::SharedState::new(config.capture_dir.clone());

    // Ensure capture directory exists
    captures::CaptureManager::new(&config.capture_dir)?;

    let http_config = config.clone();
    let http_state = state.clone();
    let http_handle = tokio::spawn(async move {
        // Retry binding the HTTP bridge with backoff
        loop {
            match bridge_http::serve(http_config.clone(), http_state.clone()).await {
                Ok(()) => break,
                Err(e) => {
                    tracing::warn!("HTTP bridge failed: {e}. Retrying in 3s...");
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                }
            }
        }
    });

    let stdio_state = state.clone();
    let stdio_handle = tokio::spawn(async move {
        mcp_stdio::run(stdio_state).await
    });

    // Exit when STDIO closes (client disconnected). HTTP bridge runs in background.
    tokio::select! {
        _ = http_handle => {
            tracing::info!("HTTP bridge task ended");
        }
        result = stdio_handle => {
            tracing::info!("MCP STDIO loop exited (client disconnected)");
            if let Err(e) = result {
                tracing::error!("STDIO task error: {e}");
            }
        }
    }

    Ok(())
}
