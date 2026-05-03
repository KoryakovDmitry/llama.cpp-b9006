use std::sync::Arc;

use base64::Engine;
use chrono::Local;
use rmcp::{
    ErrorData as McpError,
    model::{CallToolResult, Content, Role},
    tool, tool_router,
};

use crate::capture::CaptureSource;
use crate::config::Config;

/// MCP server state — config + an injected capture backend (mock in Phase 1,
/// gstreamer in Phase 3). The `Arc<dyn CaptureSource>` is what makes the
/// server fully agnostic of how frames are produced.
#[derive(Clone)]
pub struct CameraServer {
    config: Config,
    capture: Arc<dyn CaptureSource>,
}

impl CameraServer {
    pub fn new(config: Config, capture: Arc<dyn CaptureSource>) -> Self {
        Self { config, capture }
    }
}

#[tool_router(server_handler)]
impl CameraServer {
    #[tool(
        description = "View the scene through your camera — your first-person, ground-truth view of the physical world around you. The camera is mounted on the same device that runs you, so it sees exactly what is directly in front of you right now — not a remote feed, not a stored image. Call this whenever you need visual context about your immediate surroundings: an object the user is holding up to you, text or labels on a physical item, the state of the room or scene you are in, anything the user gestures at, or anything else you cannot infer from text alone. Each call captures a fresh frame at the moment of invocation. No parameters — the camera viewpoint and orientation are fixed at server startup."
    )]
    async fn view_scene(&self) -> Result<CallToolResult, McpError> {
        tracing::info!("view_scene called");

        let bytes = self.capture.capture().map_err(|e| {
            tracing::error!(error = %e, "capture failed");
            McpError::internal_error(format!("capture failed: {e:#}"), None)
        })?;

        // Optional debug write — only when --output-dir was set on startup.
        // A failed disk write is logged at warn but does NOT fail the tool
        // call: the response still carries the base64 payload, and disk save
        // is purely a debug aid.
        if let Some(ref dir) = self.config.output_dir {
            let ts = Local::now().format("%Y%m%d-%H%M%S%3f");
            let path = dir.join(format!("capture-{ts}.jpg"));
            match std::fs::write(&path, &bytes) {
                Ok(()) => tracing::info!(path = %path.display(), "debug-saved capture"),
                Err(e) => tracing::warn!(
                    error = %e,
                    path = %path.display(),
                    "debug-save to --output-dir failed",
                ),
            }
        }

        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);

        tracing::info!(bytes = bytes.len(), b64_len = b64.len(), "view_scene ok");

        Ok(CallToolResult::success(vec![
            Content::image(b64, "image/jpeg")
                .with_audience(vec![Role::User])
                .with_priority(0.9),
        ]))
    }
}
