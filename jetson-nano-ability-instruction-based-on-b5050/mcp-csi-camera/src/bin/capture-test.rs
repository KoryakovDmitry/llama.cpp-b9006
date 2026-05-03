use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use mcp_csi_camera::capture::{CaptureSource, GstreamerCapture, GstreamerConfig};
use tracing_subscriber::EnvFilter;

/// Standalone smoke test for the gstreamer pipeline. Pulls one frame from
/// the CSI camera via `GstreamerCapture` and writes it to disk. No MCP, no
/// network — purely to confirm gstreamer-rs is wired up correctly against
/// the Jetson's libgstreamer 1.14 before we plug it into the MCP server in
/// Phase 3.
#[derive(Parser, Debug)]
#[command(name = "capture-test", version, about, long_about = None)]
struct Cli {
    /// Output JPEG path.
    #[arg(long, default_value = "/tmp/csi-test.jpg")]
    output: PathBuf,

    /// IMX219 sensor ID (cam0=0, cam1=1).
    #[arg(long, default_value_t = 0)]
    sensor_id: u32,

    /// IMX219 sensor mode. Mode 3 = 1640×1232 @ 30 fps (validated).
    #[arg(long, default_value_t = 3)]
    sensor_mode: u32,

    /// `nvvidconv flip-method`. 2 = 180° rotation (validated for J13 mount).
    #[arg(long, default_value_t = 2)]
    flip_method: u32,

    /// Frame width.
    #[arg(long, default_value_t = 1640)]
    width: u32,

    /// Frame height.
    #[arg(long, default_value_t = 1232)]
    height: u32,

    /// Frame rate (numerator; denominator is hardcoded to 1).
    #[arg(long, default_value_t = 30)]
    framerate: u32,

    /// Hard timeout on `pull_sample` (seconds).
    #[arg(long, default_value_t = 10)]
    pull_timeout_secs: u64,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    let cfg = GstreamerConfig {
        sensor_id: cli.sensor_id,
        sensor_mode: cli.sensor_mode,
        flip_method: cli.flip_method,
        width: cli.width,
        height: cli.height,
        framerate: cli.framerate,
        pull_timeout_secs: cli.pull_timeout_secs,
    };

    tracing::info!(?cfg, output = %cli.output.display(), "starting capture-test");

    let cap = GstreamerCapture::new(cfg).context("create GstreamerCapture")?;

    tracing::info!("pipeline running, pulling one sample");

    let bytes = cap.capture().context("capture frame")?;

    let preview_len = bytes.len().min(4);
    let preview: String = bytes[..preview_len]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(" ");

    let looks_like_jpeg = bytes.starts_with(&[0xFF, 0xD8, 0xFF]);
    if looks_like_jpeg {
        tracing::info!(bytes = bytes.len(), first_bytes = %preview, "captured JPEG frame");
    } else {
        tracing::warn!(
            bytes = bytes.len(),
            first_bytes = %preview,
            "payload does not start with JPEG SOI marker (FF D8 FF) — output may not be a valid JPEG",
        );
    }

    std::fs::write(&cli.output, &bytes)
        .with_context(|| format!("write {}", cli.output.display()))?;

    tracing::info!(path = %cli.output.display(), bytes = bytes.len(), "saved");

    Ok(())
}
