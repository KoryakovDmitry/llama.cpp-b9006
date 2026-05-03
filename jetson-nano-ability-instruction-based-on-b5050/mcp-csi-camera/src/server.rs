use std::sync::Arc;

use base64::Engine;
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
        description = "Capture a single frame from the CSI camera and return it as a base64-encoded JPEG (mimeType image/jpeg). Takes no parameters."
    )]
    async fn capture_frame(&self) -> Result<CallToolResult, McpError> {
        tracing::info!(
            output_dir = %self.config.output_dir.display(),
            "capture_frame called",
        );

        let path = self
            .capture
            .capture(&self.config.output_dir)
            .map_err(|e| {
                tracing::error!(error = %e, "capture failed");
                McpError::internal_error(format!("capture failed: {e:#}"), None)
            })?;

        let bytes = std::fs::read(&path).map_err(|e| {
            tracing::error!(error = %e, path = %path.display(), "read-back of captured JPEG failed");
            McpError::internal_error(format!("read {}: {e:#}", path.display()), None)
        })?;

        let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);

        tracing::info!(
            path = %path.display(),
            bytes = bytes.len(),
            b64_len = b64.len(),
            "capture_frame ok",
        );

        Ok(CallToolResult::success(vec![
            Content::image(b64, "image/jpeg")
                .with_audience(vec![Role::User])
                .with_priority(0.9),
        ]))
    }
}
