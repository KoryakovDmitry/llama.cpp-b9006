use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService,
    session::local::LocalSessionManager,
};
use tracing_subscriber::EnvFilter;

mod capture;
mod config;
mod server;

use capture::{CaptureSource, MockCapture};
use config::Config;
use server::CameraServer;

#[derive(Parser, Debug)]
#[command(name = "mcp-csi-camera", version, about, long_about = None)]
struct Cli {
    /// TCP address to bind on. The MCP endpoint is mounted at /mcp.
    #[arg(long, default_value = "0.0.0.0:8777")]
    listen: String,

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
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
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
    let capture: Arc<dyn CaptureSource> =
        Arc::new(MockCapture::new(cli.mock_image.clone()));

    // Streamable HTTP creates a fresh server instance per MCP session via this
    // factory. We share the underlying capture backend (Arc<dyn CaptureSource>)
    // and config across sessions — multiple MCP clients can connect, but they
    // all hit the same physical camera.
    let factory_config = config.clone();
    let factory_capture = capture.clone();
    let factory = move || -> Result<CameraServer, std::io::Error> {
        Ok(CameraServer::new(
            factory_config.clone(),
            factory_capture.clone(),
        ))
    };

    let ct = tokio_util::sync::CancellationToken::new();

    let service = StreamableHttpService::new(
        factory,
        LocalSessionManager::default().into(),
        StreamableHttpServerConfig::default().with_cancellation_token(ct.child_token()),
    );

    let router = axum::Router::new().nest_service("/mcp", service);

    let listener = tokio::net::TcpListener::bind(&cli.listen)
        .await
        .with_context(|| format!("bind to {}", cli.listen))?;

    tracing::info!(
        listen = %cli.listen,
        endpoint = "/mcp",
        output_dir = %cli.output_dir.display(),
        mock_image = ?cli.mock_image.as_ref().map(|p| p.display().to_string()),
        "starting MCP server (Streamable HTTP)",
    );

    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            tokio::signal::ctrl_c().await.ok();
            tracing::info!("Ctrl-C received, shutting down");
            ct.cancel();
        })
        .await
        .context("axum serve loop")?;

    tracing::info!("MCP server stopped");
    Ok(())
}
