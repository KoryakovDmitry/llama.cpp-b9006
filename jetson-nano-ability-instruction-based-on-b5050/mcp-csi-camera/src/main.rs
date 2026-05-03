use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use rmcp::ServiceExt;
use rmcp::transport::stdio;
use tracing_subscriber::EnvFilter;

mod capture;
mod config;
mod server;

use capture::MockCapture;
use config::Config;
use server::CameraServer;

#[derive(Parser, Debug)]
#[command(name = "mcp-csi-camera", version, about, long_about = None)]
struct Cli {
    /// Directory where captured JPEGs are written.
    #[arg(long, default_value = "/tmp/mcp-csi")]
    output_dir: PathBuf,

    /// Phase-1 mock: optional source JPEG to copy on each capture. If set,
    /// every `capture_frame` call produces a decodable JPEG (copy of this
    /// file). If unset, the mock writes a short sentinel byte sequence
    /// instead — fine for plumbing tests, useless to a vision LLM.
    #[arg(long)]
    mock_image: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    // Logs go to STDERR. STDOUT is reserved for MCP JSON-RPC — any println!
    // would corrupt the protocol stream.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();

    std::fs::create_dir_all(&cli.output_dir)
        .with_context(|| format!("create output dir {}", cli.output_dir.display()))?;

    if let Some(ref src) = cli.mock_image {
        anyhow::ensure!(
            src.exists(),
            "--mock-image {} does not exist",
            src.display(),
        );
    }

    let config = Config { output_dir: cli.output_dir.clone() };

    // Phase 1: MockCapture only. Phase 3 wires GstreamerCapture in behind a flag.
    let capture = Arc::new(MockCapture::new(cli.mock_image.clone()));

    let server = CameraServer::new(config, capture);

    tracing::info!(
        output_dir = %cli.output_dir.display(),
        mock_image = ?cli.mock_image.as_ref().map(|p| p.display().to_string()),
        "starting MCP server on stdio",
    );

    let service = server.serve(stdio()).await
        .context("MCP server initialization failed")?;
    let quit_reason = service.waiting().await
        .context("MCP server loop terminated with error")?;

    tracing::info!(?quit_reason, "MCP server stopped");
    Ok(())
}
