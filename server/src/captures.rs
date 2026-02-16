use anyhow::Result;
use std::path::{Path, PathBuf};

use crate::types::CaptureMetadata;

pub struct CaptureManager {
    capture_dir: PathBuf,
}

impl CaptureManager {
    pub fn new(capture_dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(capture_dir)?;
        tracing::info!(path = %capture_dir.display(), "Capture directory ready");
        Ok(Self {
            capture_dir: capture_dir.to_path_buf(),
        })
    }

    pub fn record_capture(&self, metadata: CaptureMetadata) -> Result<()> {
        let index_path = self.capture_dir.join("index.json");
        let mut entries = self.load_index()?;
        entries.push(metadata);
        let json = serde_json::to_string_pretty(&entries)?;
        std::fs::write(&index_path, json)?;
        Ok(())
    }

    pub fn list_captures(&self) -> Result<Vec<CaptureMetadata>> {
        self.load_index()
    }

    fn load_index(&self) -> Result<Vec<CaptureMetadata>> {
        let index_path = self.capture_dir.join("index.json");
        if !index_path.exists() {
            return Ok(vec![]);
        }
        let data = std::fs::read_to_string(&index_path)?;
        let entries: Vec<CaptureMetadata> = serde_json::from_str(&data)?;
        Ok(entries)
    }

    /// Take an OS-level screenshot and save it to the capture directory.
    /// Returns the absolute path to the saved file.
    pub async fn os_screenshot(&self, tag: Option<&str>) -> Result<PathBuf> {
        let timestamp = chrono::Utc::now().format("%Y%m%d_%H%M%S");
        let tag_suffix = tag
            .map(|t| format!("_{t}"))
            .unwrap_or_default();
        let filename = format!("screenshot_{timestamp}{tag_suffix}.png");
        let path = self.capture_dir.join(&filename);

        #[cfg(target_os = "macos")]
        {
            let status = tokio::process::Command::new("screencapture")
                .args(["-x", path.to_str().unwrap()])
                .status()
                .await?;
            if !status.success() {
                anyhow::bail!("screencapture command failed with status {status}");
            }
        }

        #[cfg(target_os = "windows")]
        {
            // PowerShell screenshot via .NET
            let ps_script = format!(
                r#"Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::PrimaryScreen | ForEach-Object {{ $bmp = New-Object System.Drawing.Bitmap($_.Bounds.Width, $_.Bounds.Height); $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($_.Bounds.Location, [System.Drawing.Point]::Empty, $_.Bounds.Size); $bmp.Save('{}') }}"#,
                path.display()
            );
            let status = tokio::process::Command::new("powershell")
                .args(["-Command", &ps_script])
                .status()
                .await?;
            if !status.success() {
                anyhow::bail!("PowerShell screenshot failed with status {status}");
            }
        }

        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            anyhow::bail!("OS-level screenshots not supported on this platform");
        }

        // Record in index
        let metadata = CaptureMetadata {
            id: uuid::Uuid::new_v4().to_string(),
            capture_type: "screenshot".into(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            file_path: Some(path.to_string_lossy().to_string()),
            tag: tag.map(String::from),
            session_id: None,
            content_id: None,
            note: Some("OS-level screenshot".into()),
        };
        self.record_capture(metadata)?;

        Ok(path)
    }
}
