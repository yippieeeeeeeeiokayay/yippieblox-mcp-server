mod bridge_http;
mod captures;
mod config;
mod mcp_stdio;
mod state;
mod types;

use anyhow::Result;
use clap::Parser;

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

    // Log to stderr (visible in Claude Desktop logs and terminal).
    // stdout is reserved for MCP JSON-RPC protocol messages.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

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
