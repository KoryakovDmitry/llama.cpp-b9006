use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use clap::Parser;
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService,
    session::local::LocalSessionManager,
};
use tower_http::cors::{Any, CorsLayer};
use tracing_subscriber::EnvFilter;

use mcp_csi_camera::capture::{
    CaptureSource, GstreamerCapture, GstreamerConfig, MockCapture,
};
use mcp_csi_camera::config::Config;
use mcp_csi_camera::server::CameraServer;

/// Frame source. `mock` returns either `--mock-image` bytes or a sentinel —
/// useful for transport-only tests without camera hardware. `gstreamer`
/// opens a real CSI pipeline and warms up the IMX219 ISP before serving
/// any MCP request, so the very first `capture_frame` call already gets a
/// 3A-converged frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, clap::ValueEnum)]
enum Source {
    Mock,
    Gstreamer,
}

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

    /// Where to get frames from. `mock` returns `--mock-image` bytes (or a
    /// sentinel); `gstreamer` opens a real CSI pipeline. The remaining
    /// `--sensor-*`, `--flip-method`, `--width`, `--height`, `--framerate`,
    /// `--warmup-frames`, `--pull-timeout-secs` flags are read only when
    /// `--source gstreamer`.
    #[arg(long, value_enum, default_value_t = Source::Mock)]
    source: Source,

    /// `--source gstreamer` only: IMX219 sensor ID (cam0=0, cam1=1).
    #[arg(long, default_value_t = 0)]
    sensor_id: u32,

    /// `--source gstreamer` only: IMX219 sensor mode. 3 = 1640×1232 @ 30 fps
    /// 4:3 (validated in CSI_CAMERA.md).
    #[arg(long, default_value_t = 3)]
    sensor_mode: u32,

    /// `--source gstreamer` only: `nvvidconv flip-method`. 2 = 180° rotation
    /// (validated for J13 mounting); 0 = identity, 1 = 90° CCW, 3 = 90° CW,
    /// 4 = horizontal flip, 6 = vertical flip.
    #[arg(long, default_value_t = 2)]
    flip_method: u32,

    /// `--source gstreamer` only: frame width.
    #[arg(long, default_value_t = 1640)]
    width: u32,

    /// `--source gstreamer` only: frame height.
    #[arg(long, default_value_t = 1232)]
    height: u32,

    /// `--source gstreamer` only: frame rate (numerator; denominator = 1).
    #[arg(long, default_value_t = 30)]
    framerate: u32,

    /// `--source gstreamer` only: drop this many frames during startup so
    /// the IMX219 ISP's 3A (auto-exposure, auto-white-balance) converges
    /// before the first MCP request is served. 30 ≈ 1 s at 30 fps.
    #[arg(long, default_value_t = 30)]
    warmup_frames: u32,

    /// `--source gstreamer` only: hard cap on `pull_sample` wait. Beyond
    /// this `capture_frame` returns an error instead of blocking the MCP
    /// request forever.
    #[arg(long, default_value_t = 10)]
    pull_timeout_secs: u64,

    /// `--source gstreamer` only: timeout for the `/healthz` liveness probe
    /// in milliseconds. Kept much smaller than `--pull-timeout-secs` because
    /// the watchdog timer fires every 30 s and a slow probe would itself
    /// block the recovery loop. Default 500 ms is comfortably above one
    /// frame interval at 30 fps even with concurrent capture requests.
    #[arg(long, default_value_t = 500)]
    health_probe_timeout_ms: u64,
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

    let config = Config { output_dir: cli.output_dir.clone() };
    let capture: Arc<dyn CaptureSource> = match cli.source {
        Source::Mock => {
            if let Some(ref src) = cli.mock_image {
                anyhow::ensure!(
                    src.exists(),
                    "--mock-image {} does not exist",
                    src.display(),
                );
            }
            Arc::new(MockCapture::new(cli.mock_image.clone()))
        }
        Source::Gstreamer => {
            // GstreamerCapture::new blocks for ~1 s while the ISP warms up.
            // Doing it here means `capture_frame` is hot from the very first
            // MCP request, and a busted camera fails server startup instead
            // of surprising the client mid-session.
            let gst_cfg = GstreamerConfig {
                sensor_id: cli.sensor_id,
                sensor_mode: cli.sensor_mode,
                flip_method: cli.flip_method,
                width: cli.width,
                height: cli.height,
                framerate: cli.framerate,
                pull_timeout_secs: cli.pull_timeout_secs,
                warmup_frames: cli.warmup_frames,
                health_probe_timeout_ms: cli.health_probe_timeout_ms,
            };
            Arc::new(
                GstreamerCapture::new(gst_cfg)
                    .context("initialise GstreamerCapture")?,
            )
        }
    };

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

    // Permissive CORS so browser-based MCP clients (e.g. the Inspector running
    // at http://localhost:6274) can POST to /mcp from a different origin.
    // `expose_headers(Any)` is what lets the JS client read `Mcp-Session-Id`
    // back from the initialize response — without it the browser hides it
    // and every subsequent request looks unauthenticated. Suitable for a LAN
    // dev tool; tighten if this server ever faces the public internet.
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any)
        .expose_headers(Any);

    // Liveness endpoint for the systemd watchdog timer. Cheap by design:
    // does a pipeline-state check + a single short-timeout `try_pull_sample`
    // (see `GstreamerCapture::is_healthy`). Returns 200 when a frame can be
    // produced right now, 503 when the pipeline is stuck — which is how the
    // watchdog distinguishes "process alive but camera dead" from "process
    // happy" without having to call the full MCP `view_scene` tool.
    let healthz_capture = capture.clone();
    let healthz =
        axum::routing::get(move || {
            let capture = healthz_capture.clone();
            async move {
                if capture.is_healthy() {
                    (axum::http::StatusCode::OK, "ok\n")
                } else {
                    (axum::http::StatusCode::SERVICE_UNAVAILABLE, "stuck\n")
                }
            }
        });

    let router = axum::Router::new()
        .nest_service("/mcp", service)
        .route("/healthz", healthz)
        .layer(cors);

    let listener = tokio::net::TcpListener::bind(&cli.listen)
        .await
        .with_context(|| format!("bind to {}", cli.listen))?;

    tracing::info!(
        listen = %cli.listen,
        endpoint = "/mcp",
        source = ?cli.source,
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
