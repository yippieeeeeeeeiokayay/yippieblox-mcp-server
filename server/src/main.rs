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

    // Init tracing to STDERR only (stdout is reserved for MCP protocol)
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
        bridge_http::serve(http_config, http_state).await
    });

    let stdio_state = state.clone();
    let stdio_handle = tokio::spawn(async move {
        mcp_stdio::run(stdio_state).await
    });

    // Exit when either task finishes
    tokio::select! {
        result = http_handle => {
            tracing::error!("HTTP bridge exited");
            result??;
        }
        result = stdio_handle => {
            tracing::info!("MCP STDIO loop exited (client disconnected)");
            result??;
        }
    }

    Ok(())
}
