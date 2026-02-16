use clap::{Parser, Subcommand};
use serde_json::Value;

#[derive(Parser)]
#[command(name = "mcpctl", about = "Debug CLI for YippieBlox MCP Server")]
struct Cli {
    /// Server port
    #[arg(long, default_value = "3334", env = "YIPPIE_PORT")]
    port: u16,

    /// Auth token
    #[arg(long, env = "YIPPIE_TOKEN")]
    token: Option<String>,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Check if the server is running
    Health,
    /// Show connection status
    Status,
    /// List captures in the capture directory
    Captures {
        /// Path to capture directory
        #[arg(long, default_value = ".roblox-captures")]
        dir: String,
    },
    /// Send a test tool call through the bridge
    Call {
        /// Tool name (e.g. studio-status)
        tool: String,
        /// JSON arguments
        #[arg(long, default_value = "{}")]
        args: String,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    let base_url = format!("http://127.0.0.1:{}", cli.port);
    let client = reqwest::Client::new();

    match cli.command {
        Commands::Health => {
            let resp = client
                .get(format!("{base_url}/health"))
                .send()
                .await?;
            println!("Server: {}", resp.text().await?);
        }
        Commands::Status => {
            let token = cli.token.unwrap_or_default();
            let resp = client
                .get(format!("{base_url}/status"))
                .header("Authorization", format!("Bearer {token}"))
                .send()
                .await?;
            if resp.status().is_success() {
                let body: Value = resp.json().await?;
                println!("{}", serde_json::to_string_pretty(&body)?);
            } else {
                eprintln!("Error: {} {}", resp.status(), resp.text().await?);
            }
        }
        Commands::Captures { dir } => {
            let index_path = std::path::Path::new(&dir).join("index.json");
            if !index_path.exists() {
                println!("No captures found (no index.json in {dir})");
                return Ok(());
            }
            let data = std::fs::read_to_string(&index_path)?;
            let entries: Vec<Value> = serde_json::from_str(&data)?;
            if entries.is_empty() {
                println!("No captures recorded.");
            } else {
                for (i, entry) in entries.iter().enumerate() {
                    println!(
                        "{}. [{}] {} - {}",
                        i + 1,
                        entry["capture_type"].as_str().unwrap_or("?"),
                        entry["timestamp"].as_str().unwrap_or("?"),
                        entry["tag"].as_str().unwrap_or("(no tag)")
                    );
                    if let Some(path) = entry["file_path"].as_str() {
                        println!("   {path}");
                    }
                }
            }
        }
        Commands::Call { tool, args } => {
            let token = cli.token.unwrap_or_default();
            let args_json: Value = serde_json::from_str(&args)?;
            println!("Calling {tool} with {args_json}");
            println!("(This sends via HTTP bridge, requires a registered plugin to handle it)");

            // Register as a synthetic plugin
            let resp = client
                .post(format!("{base_url}/register"))
                .header("Authorization", format!("Bearer {token}"))
                .json(&serde_json::json!({ "plugin_version": "mcpctl" }))
                .send()
                .await?;
            let reg: Value = resp.json().await?;
            let client_id = reg["client_id"].as_str().unwrap_or("");
            println!("Registered as clientId: {client_id}");
            println!("Waiting for tool request on /pull (send the tool call from the MCP client)...");

            // Pull for requests
            let resp = client
                .get(format!("{base_url}/pull?clientId={client_id}"))
                .header("Authorization", format!("Bearer {token}"))
                .send()
                .await?;
            let requests: Vec<Value> = resp.json().await?;
            println!("Received {} request(s):", requests.len());
            for req in &requests {
                println!("{}", serde_json::to_string_pretty(req)?);
            }
        }
    }

    Ok(())
}
