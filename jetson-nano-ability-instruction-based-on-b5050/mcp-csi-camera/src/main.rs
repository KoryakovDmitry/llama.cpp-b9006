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

    let config = Config { output_dir: cli.output_dir.clone() };

    // Phase 1: MockCapture only. Phase 3 wires GstreamerCapture in behind a flag.
    let capture = Arc::new(MockCapture::new());

    let server = CameraServer::new(config, capture);

    tracing::info!(output_dir = %cli.output_dir.display(), "starting MCP server on stdio");

    let service = server.serve(stdio()).await
        .context("MCP server initialization failed")?;
    let quit_reason = service.waiting().await
        .context("MCP server loop terminated with error")?;

    tracing::info!(?quit_reason, "MCP server stopped");
    Ok(())
}
