use anyhow::Result;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    pub token: String,
    pub capture_dir: PathBuf,
}

pub fn load() -> Result<Config> {
    let port: u16 = std::env::var("YIPPIE_PORT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3333);

    let token = std::env::var("YIPPIE_TOKEN").unwrap_or_else(|_| {
        let generated = uuid::Uuid::new_v4().to_string();
        eprintln!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        eprintln!("  No YIPPIE_TOKEN set. Generated token:");
        eprintln!("  {generated}");
        eprintln!("  Paste this into the Studio plugin's Auth Token field.");
        eprintln!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        generated
    });

    let capture_dir = std::env::var("YIPPIE_CAPTURE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(".roblox-captures")
        });

    Ok(Config {
        port,
        token,
        capture_dir,
    })
}
