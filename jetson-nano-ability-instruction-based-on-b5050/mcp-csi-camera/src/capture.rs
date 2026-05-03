use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result};
use chrono::Local;

/// Source of camera frames. Implementations capture a single JPEG and write it
/// into the given output directory, returning the path. Synchronous on
/// purpose — capture work is short (~milliseconds for mock, ~50 ms for
/// gstreamer with a persistent pipeline) and not worth the overhead of
/// pushing through `tokio::task::spawn_blocking` at our load (one MCP call
/// at a time on stdio).
pub trait CaptureSource: Send + Sync {
    fn capture(&self, output_dir: &Path) -> Result<PathBuf>;
}

/// Phase-1 stand-in. On each capture writes a JPEG to a timestamped path in
/// `output_dir` and returns it. Lets us validate the MCP wiring end to end
/// without depending on gstreamer or a working CSI camera.
///
/// Two modes, picked by the `source_image` constructor arg:
/// - `Some(path)` — copy that file's bytes to every capture path. Use a real
///   JPEG here when integration-testing with a vision LLM client; the mock
///   then produces decodable images.
/// - `None` — write a short sentinel byte sequence. Not a valid JPEG, but
///   enough to validate that an MCP client receives a path it can stat.
///
/// Phase 3 replaces this implementation with a real frame from gstreamer.
pub struct MockCapture {
    counter: AtomicU64,
    source_image: Option<PathBuf>,
}

impl MockCapture {
    pub fn new(source_image: Option<PathBuf>) -> Self {
        Self { counter: AtomicU64::new(0), source_image }
    }
}

impl Default for MockCapture {
    fn default() -> Self {
        Self::new(None)
    }
}

impl CaptureSource for MockCapture {
    fn capture(&self, output_dir: &Path) -> Result<PathBuf> {
        let n = self.counter.fetch_add(1, Ordering::Relaxed);
        let ts = Local::now().format("%Y%m%d-%H%M%S");
        let filename = format!("mock-{ts}-{n:06}.jpg");
        let path = output_dir.join(filename);

        match &self.source_image {
            Some(src) => {
                std::fs::copy(src, &path).with_context(|| {
                    format!("copy {} to {}", src.display(), path.display())
                })?;
            }
            None => {
                std::fs::write(&path, b"MOCK JPEG -- mcp-csi-camera placeholder.\n")
                    .with_context(|| format!("write mock capture to {}", path.display()))?;
            }
        }

        Ok(path)
    }
}
