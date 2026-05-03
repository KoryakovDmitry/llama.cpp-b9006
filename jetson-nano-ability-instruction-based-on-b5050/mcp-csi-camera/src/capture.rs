use std::path::PathBuf;

use anyhow::{Context, Result};

/// Source of camera frames. Implementations return raw JPEG bytes; the server
/// layer is responsible for any disk I/O (the optional `--output-dir`
/// debug-save) and for base64-wrapping the result for the MCP response.
pub trait CaptureSource: Send + Sync {
    fn capture(&self) -> Result<Vec<u8>>;
}

/// Phase-1 stand-in. Returns either the bytes of `source_image` (when set —
/// gives integration tests a real, decodable JPEG) or a short sentinel byte
/// sequence (when unset — fine for plumbing tests, useless to a vision LLM).
///
/// Phase 3 replaces this with a `GstreamerCapture` impl that pulls frames
/// from a persistent gstreamer pipeline via `appsink`.
pub struct MockCapture {
    source_image: Option<PathBuf>,
}

impl MockCapture {
    pub fn new(source_image: Option<PathBuf>) -> Self {
        Self { source_image }
    }
}

impl CaptureSource for MockCapture {
    fn capture(&self) -> Result<Vec<u8>> {
        match &self.source_image {
            Some(src) => std::fs::read(src)
                .with_context(|| format!("read mock source {}", src.display())),
            None => Ok(b"MOCK JPEG -- mcp-csi-camera placeholder.\n".to_vec()),
        }
    }
}
