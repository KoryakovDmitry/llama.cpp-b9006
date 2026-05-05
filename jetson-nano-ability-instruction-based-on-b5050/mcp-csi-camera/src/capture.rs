use std::path::PathBuf;

use anyhow::{Context, Result, anyhow};
use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;

/// Source of camera frames. Implementations return raw JPEG bytes; the server
/// layer is responsible for any disk I/O (the optional `--output-dir`
/// debug-save) and for base64-wrapping the result for the MCP response.
pub trait CaptureSource: Send + Sync {
    fn capture(&self) -> Result<Vec<u8>>;

    /// Liveness probe used by the `/healthz` HTTP endpoint and the watchdog
    /// timer. Must answer in well under a second — the watchdog fires every
    /// 30 s and a slow probe would itself become a stall. The contract is
    /// "right now, can this source produce a frame": for `GstreamerCapture`
    /// that means a real `try_pull_sample` with a small timeout (catches the
    /// `dmabuf_fd -1` host1x-stuck case where the pipeline reports `Playing`
    /// but no buffers flow); for `MockCapture` it is trivially true.
    fn is_healthy(&self) -> bool;
}

/// Phase-1 stand-in. Returns either the bytes of `source_image` (when set —
/// gives integration tests a real, decodable JPEG) or a short sentinel byte
/// sequence (when unset — fine for plumbing tests, useless to a vision LLM).
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

    fn is_healthy(&self) -> bool {
        true
    }
}

/// Knobs for the gstreamer pipeline. Defaults match the validated 1640×1232
/// @ 30 fps mode on IMX219 (sensor-mode 3, 2×2 binned, 4:3) with 180° flip —
/// the only configuration confirmed working on J13 in `CSI_CAMERA.md`.
#[derive(Clone, Debug)]
pub struct GstreamerConfig {
    pub sensor_id: u32,
    pub sensor_mode: u32,
    pub flip_method: u32,
    pub width: u32,
    pub height: u32,
    pub framerate: u32,
    /// Hard cap on `pull_sample` wait. Beyond this `capture()` returns an
    /// error instead of blocking forever — the common failure mode is the
    /// pipeline reaching PLAYING but `nvarguscamerasrc` never producing a
    /// buffer (oxidised ribbon, wrong sensor-mode, missing DT overlay).
    pub pull_timeout_secs: u64,
    /// Number of frames to pull-and-drop in `new()` before the capturer is
    /// considered ready. The IMX219 ISP's 3A algorithms (auto-exposure,
    /// auto-white-balance) need a ~1 s warm-up — without it the very first
    /// frame comes out yellow/green-tinted and underexposed. 30 frames at
    /// 30 fps ≈ 1 s, which empirically lets AE/AWB converge.
    pub warmup_frames: u32,
    /// Timeout for the `/healthz` liveness probe — much tighter than
    /// `pull_timeout_secs` because the watchdog fires every 30 s and a slow
    /// probe is itself a stall. At 30 fps a fresh frame arrives every ~33 ms,
    /// so 500 ms is comfortably above the worst-case wait when contending
    /// with a concurrent `capture()` call (appsink has `max-buffers=1`).
    pub health_probe_timeout_ms: u64,
}

impl Default for GstreamerConfig {
    fn default() -> Self {
        Self {
            sensor_id: 0,
            sensor_mode: 3,
            flip_method: 2,
            width: 1640,
            height: 1232,
            framerate: 30,
            pull_timeout_secs: 10,
            warmup_frames: 30,
            health_probe_timeout_ms: 500,
        }
    }
}

/// Real CSI capture using a persistent gstreamer pipeline:
/// `nvarguscamerasrc → nvvidconv → nvjpegenc → appsink`. The pipeline is
/// brought up to PLAYING in `new()` and stays there for the lifetime of the
/// value; `capture()` just pulls the latest sample from the appsink. The
/// appsink is configured with `max-buffers=1 drop=true` so we always serve
/// a fresh frame instead of a stale one queued during idle.
pub struct GstreamerCapture {
    pipeline: gst::Pipeline,
    appsink: gst_app::AppSink,
    pull_timeout: gst::ClockTime,
    health_probe_timeout: gst::ClockTime,
}

impl GstreamerCapture {
    pub fn new(cfg: GstreamerConfig) -> Result<Self> {
        gst::init().context("gst::init")?;

        let pipeline_str = format!(
            "nvarguscamerasrc sensor-id={sid} sensor-mode={smode} \
             ! video/x-raw(memory:NVMM),width={w},height={h},framerate={fps}/1 \
             ! nvvidconv flip-method={flip} \
             ! video/x-raw,format=I420 \
             ! nvjpegenc \
             ! appsink name=sink max-buffers=1 drop=true sync=false",
            sid = cfg.sensor_id,
            smode = cfg.sensor_mode,
            w = cfg.width,
            h = cfg.height,
            fps = cfg.framerate,
            flip = cfg.flip_method,
        );

        tracing::info!(pipeline = %pipeline_str, "building gstreamer pipeline");

        let pipeline = gst::parse_launch(&pipeline_str)
            .with_context(|| format!("parse_launch failed for: {pipeline_str}"))?
            .downcast::<gst::Pipeline>()
            .map_err(|_| anyhow!("parse_launch did not return a Pipeline"))?;

        let appsink = pipeline
            .by_name("sink")
            .ok_or_else(|| anyhow!("appsink named 'sink' not found in pipeline"))?
            .downcast::<gst_app::AppSink>()
            .map_err(|_| anyhow!("'sink' element is not an AppSink"))?;

        pipeline
            .set_state(gst::State::Playing)
            .context("set pipeline state to Playing")?;

        let pull_timeout = gst::ClockTime::from_seconds(cfg.pull_timeout_secs);
        let health_probe_timeout =
            gst::ClockTime::from_mseconds(cfg.health_probe_timeout_ms);

        // Warm up: drain the first N frames so the IMX219 ISP's 3A
        // (auto-exposure, auto-white-balance) has time to converge. Without
        // this the first sample comes out yellow/green-tinted and we'd hand
        // it back to the LLM as the "real" frame.
        for i in 0..cfg.warmup_frames {
            appsink
                .try_pull_sample(pull_timeout)
                .ok_or_else(|| {
                    anyhow!(
                        "timed out waiting for warm-up frame {i}/{} — camera not producing buffers \
                         (check ribbon contact, `dmesg | grep imx219`, sensor-mode validity)",
                        cfg.warmup_frames,
                    )
                })?;
        }
        tracing::info!(
            frames = cfg.warmup_frames,
            "warm-up complete, 3A should be converged",
        );

        Ok(Self {
            pipeline,
            appsink,
            pull_timeout,
            health_probe_timeout,
        })
    }
}

impl Drop for GstreamerCapture {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

impl CaptureSource for GstreamerCapture {
    fn capture(&self) -> Result<Vec<u8>> {
        let sample = self.appsink.try_pull_sample(self.pull_timeout).ok_or_else(|| {
            anyhow!(
                "no sample within {:?} — camera not producing frames \
                 (check ribbon contact, `dmesg | grep imx219`, sensor-mode validity)",
                self.pull_timeout,
            )
        })?;

        let buffer = sample
            .buffer()
            .ok_or_else(|| anyhow!("gstreamer sample carries no buffer"))?;
        let map = buffer
            .map_readable()
            .map_err(|_| anyhow!("buffer.map_readable failed"))?;

        Ok(map.as_slice().to_vec())
    }

    fn is_healthy(&self) -> bool {
        // Two-step probe. First, quick check that the pipeline at least
        // claims to be PLAYING — if not, there is no point waiting on the
        // appsink. `state(0)` is non-blocking (zero timeout): we are asking
        // for the *cached* current state, not driving a state change.
        let (_, current, _) = self.pipeline.state(gst::ClockTime::ZERO);
        if current != gst::State::Playing {
            tracing::warn!(?current, "healthz: pipeline not Playing");
            return false;
        }

        // Then the active probe — pulls one real frame from the appsink with
        // a tight timeout. Catches the host1x/NVMM stuck case where the
        // pipeline reports `Playing` but no buffers ever arrive (the
        // `nvbuf_utils: dmabuf_fd -1` failure mode). Steals one frame from
        // any concurrent `capture()`, but at 30 fps the next one arrives in
        // ~33 ms, so the cost is negligible.
        match self.appsink.try_pull_sample(self.health_probe_timeout) {
            Some(_) => true,
            None => {
                tracing::warn!(
                    timeout_ms = self.health_probe_timeout.mseconds(),
                    "healthz: no sample within probe timeout — pipeline stuck",
                );
                false
            }
        }
    }
}
