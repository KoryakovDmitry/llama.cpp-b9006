# mcp-csi-camera

MCP server exposing the Jetson Nano CSI camera as a single `capture_frame` tool. Speaks **MCP Streamable HTTP** (the 2025-11-25 spec transport — POST-based with SSE for server-pushed messages). Returns each frame as a base64-encoded JPEG inline in the tool response (no file paths, no disk involvement by default).

For background see [`../CSI_CAMERA.md`](../CSI_CAMERA.md) and [`../HISTORY.md` § Phase 6](../HISTORY.md#phase-6--csi-camera-bring-up-branch-mcp-csi-camera-jetson-nano).

## Status

Phased delivery. Each phase is independently testable on the Jetson.

| Phase | What it does | State |
|---|---|---|
| 1 | MCP server with `MockCapture` (returns the bytes of `--mock-image` if set, else a sentinel). Validates the rmcp + Streamable HTTP wiring without gstreamer. End-to-end tested via MCP Inspector over LAN. | done |
| 2 | Standalone `capture-test` binary that exercises `gstreamer-rs` against the real CSI pipeline (no MCP). Pulls one frame and writes it to disk. Includes a 30-frame ISP warm-up so AE/AWB converge before the first sample. | done |
| 3 | Wire `GstreamerCapture` into the MCP server behind `--source mock\|gstreamer`. With `--source gstreamer` the server warms the camera at startup, so the very first `capture_frame` MCP call already returns a 3A-converged frame. | **current** |

## Build

Native build on the Jetson (faster than cross-compile for the first iteration; ~15–25 min for first build, incremental seconds after that):

```sh
cd jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera
cargo build --release
```

This produces two binaries:

| Binary | Purpose |
|---|---|
| `target/release/mcp-csi-camera` | The MCP server itself (Phase 1+). |
| `target/release/capture-test` | Phase-2 smoke test for the gstreamer pipeline — pulls one frame from the CSI camera and writes it to disk. No MCP. |

The gstreamer crates link against the system `libgstreamer-1.0` / `libgstreamer-app-1.0`. On a fresh Jetson install you may need:

```sh
sudo apt install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev pkg-config
```

To build only the smoke-test binary (faster — skips axum/rmcp link):

```sh
cargo build --release --bin capture-test
```

## Phase 2 — capture-test

Standalone binary that builds a persistent gstreamer pipeline (`nvarguscamerasrc → nvvidconv → nvjpegenc → appsink`), pulls a single frame and writes it to disk. Use it to confirm the pipeline works on this Jetson before plugging it into the MCP server in Phase 3.

```sh
RUST_LOG=info ./target/release/capture-test --output /tmp/csi-test.jpg
file /tmp/csi-test.jpg   # expect: JPEG image data ...
```

Defaults match the validated 1640×1232 @ 30 fps mode (sensor-mode 3, flip-method 2). Override per-flag if you need a different mode — see `--help`.

## Run

Minimal — no disk involvement, frame lives only in the MCP response:

```sh
RUST_LOG=info ./target/release/mcp-csi-camera --listen 0.0.0.0:8777
```

The MCP endpoint is at `http://<host>:8777/mcp`. Default binds on `0.0.0.0:8777` so the server is reachable from other machines on the LAN — pass `--listen 127.0.0.1:8777` to bind localhost-only.

To exit, send `Ctrl-C` — the server completes any in-flight request, cancels its session manager, and shuts down cleanly.

### CLI flags

| Flag | Default | Effect |
|---|---|---|
| `--listen <addr>` | `0.0.0.0:8777` | TCP bind address. MCP endpoint is mounted at `/mcp`. |
| `--source <kind>` | `mock` | Frame source. `mock` returns `--mock-image` bytes (or a sentinel); `gstreamer` opens a real CSI pipeline. The `--sensor-*`, `--flip-method`, `--width`, `--height`, `--framerate`, `--warmup-frames`, `--pull-timeout-secs` flags below are read only when `--source gstreamer`. |
| `--mock-image <path>` | unset | `--source mock` only. If set, the mock returns the bytes of this file on every capture (gives integration tests a decodable JPEG). If unset, the mock returns a short sentinel byte sequence. The path is checked at startup; the server fails fast if the file doesn't exist. |
| `--output-dir <dir>` | unset | Optional debug aid. If set, every capture is also written to the directory as `capture-<timestamp>.jpg`. If unset, **nothing is written to disk** — frames exist only inside the MCP response payload. |
| `--allowed-host <host>` | (none — defaults below kept) | Repeatable. Additional `Host` header values accepted by the Streamable HTTP transport, on top of the built-in defaults (`localhost`, `127.0.0.1`, `::1`). Required when MCP clients dial this server by LAN IP — rmcp's DNS-rebinding protection otherwise rejects them. Use the IP clients actually dial (e.g. the Jetson's `192.168.178.59`); no `:port` suffix matches any port, `host:port` pins the port. |
| `--sensor-id <n>` | `0` | `--source gstreamer` only. IMX219 sensor ID (cam0=0, cam1=1). |
| `--sensor-mode <n>` | `3` | `--source gstreamer` only. IMX219 sensor mode. 3 = 1640×1232 @ 30 fps 4:3 (validated). |
| `--flip-method <n>` | `2` | `--source gstreamer` only. `nvvidconv flip-method`. 0 = identity, 1 = 90° CCW, **2 = 180°** (validated for J13 mount), 3 = 90° CW, 4 = horizontal flip, 6 = vertical flip. |
| `--width <px>` | `1640` | `--source gstreamer` only. |
| `--height <px>` | `1232` | `--source gstreamer` only. |
| `--framerate <fps>` | `30` | `--source gstreamer` only. Numerator; denominator is hardcoded to 1. |
| `--warmup-frames <n>` | `30` | `--source gstreamer` only. Frames to pull-and-drop at startup so AE/AWB converge before the first MCP request is served. ~1 s at 30 fps. Bump if `capture_frame` still returns tinted output. |
| `--pull-timeout-secs <n>` | `10` | `--source gstreamer` only. Hard cap on each frame fetch; `capture_frame` errors out instead of blocking the MCP request forever if the camera stops producing buffers. |

### Useful invocations

```sh
# Default — pure in-memory, base64 only, no disk side-effects.
./target/release/mcp-csi-camera --listen 127.0.0.1:8777

# With a real source JPEG so the mock returns decodable images.
./target/release/mcp-csi-camera \
    --listen 127.0.0.1:8777 \
    --mock-image /tmp/csi-mode3.jpg

# Plus disk debug-save so you can also inspect the saved frames after the fact.
./target/release/mcp-csi-camera \
    --listen 127.0.0.1:8777 \
    --mock-image /tmp/csi-mode3.jpg \
    --output-dir /tmp/mcp-csi

# LAN access — Inspector on a Mac dials the Jetson directly. Without the
# allowlist entry rmcp rejects the request with
# `disallowed Host header (possible DNS rebinding attempt)`.
./target/release/mcp-csi-camera \
    --listen 0.0.0.0:8777 \
    --mock-image /home/diikorr/IMG_resized.jpg \
    --allowed-host 192.168.178.59

# Phase 3 — real CSI camera. Server blocks ~1 s at startup while the
# IMX219 ISP warms up, then `capture_frame` returns a 3A-converged JPEG
# on every call. Switch `--flip-method` if you remount the camera.
./target/release/mcp-csi-camera \
    --listen 0.0.0.0:8777 \
    --source gstreamer \
    --allowed-host 192.168.178.59
```

## Tools

### `capture_frame`

Captures one frame from the configured camera source and returns it as a base64-encoded JPEG inline.

- **Parameters**: none (in Phase 1).
- **Return**: a single `CallToolResult.content` entry of type `image`, with `mimeType: image/jpeg` and `data` set to the base64-encoded JPEG bytes. Annotations: `audience: ["user"]`, `priority: 0.9`.
- **Side effect (optional)**: with `--output-dir <dir>` set, every capture is also written to `<dir>/capture-<timestamp>.jpg`. The path is **not** included in the MCP response — the disk save is purely a debug aid for inspecting captured frames after the fact. Without `--output-dir`, no files are written. A failed disk write is logged at `warn` but does not fail the tool call.

In Phase 1 the bytes that get base64-encoded come from `--mock-image` (if set) or from a sentinel placeholder. Phase 3 replaces the source with a real frame from the gstreamer pipeline at sensor-mode 3 (1640×1232 @ 30 fps, 4:3, 2×2 binned, flip-method 2); the response shape stays the same.

## Test the server

The easiest way to drive the server interactively is the **MCP Inspector** — Anthropic's official web UI for testing any MCP server:

```sh
# Launch Inspector (requires Node.js)
npx @modelcontextprotocol/inspector
```

Inspector opens at `http://localhost:5173`. In its UI:
1. **Transport type**: pick "Streamable HTTP".
2. **URL**: `http://<host>:8777/mcp` (e.g. `http://nano:8777/mcp` from a Mac, `http://localhost:8777/mcp` if Inspector and server are on the same box).
3. Click **Connect**.
4. **Tools** tab → `capture_frame` → **Run Tool** → see the JPEG rendered as an inline image preview in the response.

### Quick `curl` smoke check

For a one-liner sanity ping (just `initialize`, no full session) — the server should respond with its info / capabilities:

```sh
curl -s -X POST http://localhost:8777/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
```

A successful initialize comes back as a `text/event-stream` (SSE) chunk with the JSON-RPC `result`. Full multi-step flow (initialize → notifications/initialized → tools/call) requires session-ID tracking via the `Mcp-Session-Id` response header — practical to do in Inspector or a real MCP client, tedious in raw curl.
