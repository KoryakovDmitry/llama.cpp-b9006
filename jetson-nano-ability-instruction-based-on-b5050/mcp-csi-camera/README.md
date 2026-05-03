# mcp-csi-camera

MCP server exposing the Jetson Nano CSI camera as a single `capture_frame` tool. Speaks **MCP Streamable HTTP** (the 2025-11-25 spec transport — POST-based with SSE for server-pushed messages).

For background see [`../CSI_CAMERA.md`](../CSI_CAMERA.md) and [`../HISTORY.md` § Phase 6](../HISTORY.md#phase-6--csi-camera-bring-up-branch-mcp-csi-camera-jetson-nano).

## Status

Phased delivery. Each phase is independently testable on the Jetson.

| Phase | What it does | State |
|---|---|---|
| 1 | MCP server with `MockCapture` (writes a placeholder file or copies a real JPEG, picked by `--mock-image`). Validates rmcp + Streamable HTTP wiring without gstreamer. | **current** |
| 2 | Standalone `capture-test` binary that exercises `gstreamer-rs` against the real CSI pipeline (no MCP). | next |
| 3 | Wire `GstreamerCapture` into the MCP server behind a CLI flag. | upcoming |

## Build

Native build on the Jetson (faster than cross-compile for the first iteration; ~15–25 min for first build, incremental seconds after that):

```sh
cd jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera
cargo build --release
```

The binary lands at `target/release/mcp-csi-camera`.

## Run

```sh
RUST_LOG=info ./target/release/mcp-csi-camera \
    --listen 0.0.0.0:8777 \
    --output-dir /tmp/mcp-csi \
    --mock-image /tmp/csi-mode3.jpg
```

The MCP endpoint is at `http://<host>:8777/mcp`. Defaults bind on `0.0.0.0:8777` so the server is reachable from other machines on the LAN — pass `--listen 127.0.0.1:8777` to bind localhost-only.

Logs default to stdout (no longer competing with stdio JSON-RPC — the Streamable HTTP transport uses HTTP, so `println!` is safe again, though we still use `tracing` for structured output). With `RUST_LOG=info` you see one line per `capture_frame` call.

To exit, send `Ctrl-C` — the server completes any in-flight request, cancels its session manager, and shuts down cleanly.

### `--mock-image` (Phase-1 only)

Without `--mock-image`, every `capture_frame` writes a sentinel byte sequence — useful to confirm an MCP client gets a path it can stat, useless for a vision LLM that tries to decode the file. With `--mock-image PATH`, MockCapture copies that file into each output path, so integration tests against a real multimodal client see a decodable JPEG.

The path is checked at startup; the server fails fast if the file doesn't exist.

## Tools

### `capture_frame`

Captures one frame from the configured CSI camera, writes it as a JPEG into `--output-dir`, returns the absolute path as text content.

- Parameters: none (in Phase 1).
- Return: `text` content with the absolute path string, e.g. `/tmp/mcp-csi/mock-20260503-164715-000003.jpg`.

In Phase 1 the file content depends on `--mock-image` — see the section above. Phase 3 replaces this with a real frame from the gstreamer pipeline at sensor-mode 3 (1640×1232 @ 30 fps, 4:3, 2×2 binned, flip-method 2).

## File cleanup

Captured files accumulate in `--output-dir` indefinitely (no TTL, no ring buffer). On a Jetson where `/tmp` is tmpfs, this means RAM consumption grows with capture count. For a long-running session manually clean the directory or restart the server (which by itself doesn't wipe — `/tmp` only clears on reboot).

A `--keep-history N` flag for ring-buffer cleanup is on the TODO list; not in Phase 1.

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
4. **Tools** tab → `capture_frame` → **Run Tool** → see the JPEG path in the response.

The mock-file (or real JPEG via `--mock-image`) appears in the configured `--output-dir` as expected.

### Quick `curl` smoke check

For a one-liner sanity ping (just `initialize`, no full session) — the server should respond with its info / capabilities:

```sh
curl -s -X POST http://localhost:8777/mcp \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
```

A successful initialize comes back as a `text/event-stream` (SSE) chunk with the JSON-RPC `result`. Full multi-step flow (initialize → notifications/initialized → tools/call) requires session-ID tracking via the `Mcp-Session-Id` response header — practical to do in Inspector or a real MCP client, tedious in raw curl.
