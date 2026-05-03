# mcp-csi-camera

MCP server exposing the Jetson Nano CSI camera as a single `capture_frame` tool. Speaks MCP over stdio.

For background see [`../CSI_CAMERA.md`](../CSI_CAMERA.md) and [`../HISTORY.md` § Phase 6](../HISTORY.md#phase-6--csi-camera-bring-up-branch-mcp-csi-camera-jetson-nano).

## Status

Phased delivery. Each phase is independently testable on the Jetson.

| Phase | What it does | State |
|---|---|---|
| 1 | MCP server scaffold with `MockCapture` (writes a placeholder file). Validates rmcp wiring without gstreamer. | **current** |
| 2 | Standalone `capture-test` binary that exercises `gstreamer-rs` against the real CSI pipeline (no MCP). | next |
| 3 | Wire `GstreamerCapture` into the MCP server behind a CLI flag. | upcoming |

In Phase 1 the server returns a path to a sentinel file (`MOCK JPEG -- mcp-csi-camera placeholder.\n`) — useful for testing that the MCP client can talk to the server and receive a tool response, but not a real image yet.

## Build

Native build on the Jetson (faster than cross-compile for the first iteration; ~15–25 min for first build, incremental seconds after that):

```sh
cd jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera
cargo build --release
```

The binary lands at `target/release/mcp-csi-camera`.

## Run

```sh
RUST_LOG=info ./target/release/mcp-csi-camera --output-dir /tmp/mcp-csi
```

The server reads MCP JSON-RPC from **stdin** and writes responses to **stdout**. Logs go to **stderr** (stdout is reserved for the protocol; any `println!` would corrupt JSON-RPC). With `RUST_LOG=info` you see one line per `capture_frame` call.

To exit, send EOF on stdin (Ctrl-D) or terminate the process.

## Tools

### `capture_frame`

Captures one frame from the configured CSI camera, writes it as a JPEG into `--output-dir`, returns the absolute path as text content.

- Parameters: none (in Phase 1).
- Return: `text` content with the absolute path string, e.g. `/tmp/mcp-csi/mock-20260503-164715-000003.jpg`.

In Phase 1 the file written is **not** a valid JPEG — it's a sentinel byte sequence so downstream tooling that just reads the path and forwards it works end-to-end without needing a working camera. Phase 3 replaces this with a real JPEG from the gstreamer pipeline at sensor-mode 3 (1640×1232 @ 30 fps, 4:3, 2×2 binned, flip-method 2).

## File cleanup

Captured files accumulate in `--output-dir` indefinitely (no TTL, no ring buffer). On a Jetson where `/tmp` is tmpfs, this means RAM consumption grows with capture count. For a long-running session manually clean the directory or restart the server (which by itself doesn't wipe — `/tmp` only clears on reboot).

A `--keep-history N` flag for ring-buffer cleanup is on the TODO list; not in Phase 1.

## Test from the command line (without an MCP client)

The MCP `initialize` + `tools/call` JSON-RPC handshake can be driven by hand for smoke-testing. Quick recipe:

```sh
# Send an `initialize` then `tools/call capture_frame` over stdio.
# (one-line JSON, server replies one JSON line per request)
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_frame","arguments":{}}}'
} | ./target/release/mcp-csi-camera --output-dir /tmp/mcp-csi
```

Expected: two JSON responses on stdout (one for `initialize`, one for `tools/call`); a file appears in `/tmp/mcp-csi/`.
