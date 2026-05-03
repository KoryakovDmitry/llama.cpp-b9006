use std::sync::Arc;

use rmcp::{ErrorData as McpError, tool, tool_router};

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
        description = "Capture a single frame from the CSI camera, save it as a JPEG, and return the absolute path to the file. Takes no parameters."
    )]
    async fn capture_frame(&self) -> Result<String, McpError> {
        tracing::info!(
            output_dir = %self.config.output_dir.display(),
            "capture_frame called",
        );

        let path = self
            .capture
            .capture(&self.config.output_dir)
            .map_err(|e| {
                tracing::error!(error = %e, "capture_frame failed");
                McpError::internal_error(format!("capture failed: {e:#}"), None)
            })?;

        tracing::info!(path = %path.display(), "capture_frame ok");
        Ok(path.display().to_string())
    }
}
