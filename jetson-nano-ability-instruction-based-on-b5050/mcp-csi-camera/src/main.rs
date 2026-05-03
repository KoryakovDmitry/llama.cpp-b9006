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

    /// Optional debug aid: save every captured JPEG to this directory as
    /// `capture-<timestamp>.jpg`. If unset, frames live only in the inline
    /// base64 image content of the MCP response — nothing is written to disk.
    #[arg(long)]
    output_dir: Option<PathBuf>,

    /// Phase-1 mock: optional source JPEG whose bytes the server returns on
    /// each capture. If unset, the mock returns a short sentinel byte
    /// sequence — fine for plumbing tests, useless to a vision LLM.
    #[arg(long)]
    mock_image: Option<PathBuf>,

    /// Additional hosts accepted by the Streamable HTTP transport, on top of
    /// the default allowlist (`localhost`, `127.0.0.1`, `::1`). rmcp's DNS-
    /// rebinding protection rejects requests whose `Host` header is not in
    /// the list — pass the IP/hostname that clients actually dial, e.g.
    /// `--allowed-host 192.168.178.59` for LAN access. Repeatable. Without a
    /// `:port` suffix any port matches; with `:8777` the port is pinned too.
    #[arg(long)]
    allowed_host: Vec<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let cli = Cli::parse();

    if let Some(ref dir) = cli.output_dir {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("create output dir {}", dir.display()))?;
    }

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

    // Defaults (loopback only) + whatever LAN hosts the user passed in.
    // `with_allowed_hosts` replaces the list, so we must include the defaults
    // explicitly or `localhost` access stops working.
    let mut allowed_hosts: Vec<String> = vec![
        "localhost".into(),
        "127.0.0.1".into(),
        "::1".into(),
    ];
    allowed_hosts.extend(cli.allowed_host.iter().cloned());

    let service = StreamableHttpService::new(
        factory,
        LocalSessionManager::default().into(),
        StreamableHttpServerConfig::default()
            .with_cancellation_token(ct.child_token())
            .with_allowed_hosts(allowed_hosts.clone()),
    );

    let router = axum::Router::new().nest_service("/mcp", service);

    let listener = tokio::net::TcpListener::bind(&cli.listen)
        .await
        .with_context(|| format!("bind to {}", cli.listen))?;

    tracing::info!(
        listen = %cli.listen,
        endpoint = "/mcp",
        output_dir = ?cli.output_dir,
        mock_image = ?cli.mock_image,
        allowed_hosts = ?allowed_hosts,
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
