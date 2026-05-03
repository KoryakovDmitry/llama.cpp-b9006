# Jetson Nano CSI camera bring-up

End-to-end procedure for a Raspberry Pi Camera v2.1 (Sony IMX219, 8 MP) on a 2019 Jetson Nano Developer Kit (B01 — two CSI ports; A02 has one and the steps are otherwise identical), running JetPack 4.6.x. For the diagnostic chronology that arrived at this procedure see [`HISTORY.md` § Phase 6](HISTORY.md#phase-6--csi-camera-bring-up-branch-mcp-csi-camera-jetson-nano).

The endpoint is a working `gst-launch-1.0` pipeline that captures a single JPEG through the NVIDIA hardware ISP. This is the same pipeline that the upcoming MCP server (branch `mcp-csi-camera-jetson-nano`) will hold open as a long-lived gstreamer graph.

## What you should have

- Jetson Nano Devkit B01 (or A02).
- Raspberry Pi Camera v2.1 — or any IMX219-based equivalent (NOIR, Waveshare, ArduCam clone). HQ Camera (IMX477) needs a different overlay; this doc is IMX219-only.
- 15 cm CSI ribbon (ships with most Pi Cams).
- JetPack 4.6.x already installed (this build was tested on `R32.7.6`, kernel built `Tue Nov  5 07:46:14 UTC 2024`).

## 1. Physical install

Powered off, barrel jack disconnected:

1. Identify CSI connectors — on dev kit B01 they're labeled **J13** (cam0) and **J49** (cam1) on the silkscreen.
2. Lift the black plastic latch of the chosen CSI port ~2 mm. It's spring-loaded and doesn't fully detach — don't force it.
3. Insert the ribbon **golden contacts toward the SoC / heatsink**, blue plastic toward the board edge. Push to fully seated.
4. Lower the latch back down evenly. A gentle tug shouldn't pull the ribbon out.
5. Same on the camera side — golden contacts toward the camera PCB.

If the camera previously worked on this Jetson but stopped after a reflash or extended downtime, **before doing anything software-side** see § "Recovery: oxidized ribbon contacts" below. Gold-plated CSI ribbon contacts oxidize passively over months in humid storage; the link won't come up even though "nothing was touched".

## 2. Apply the IMX219 device-tree overlay

JetPack 4.6 ships with a generic `imx219` DT placeholder, but Pi Cam v2.1 specifically needs the `rbpcv2_imx219_*` overlay — it carries the right pin / regulator / reset-line configuration for the Raspberry Pi camera module. Without this overlay the kernel will load the imx219 driver, attempt i2c probe, and fail with `error during i2c read probe (-121)` because the sensor isn't powered/clocked correctly.

### Interactive (recommended)

```sh
sudo /opt/nvidia/jetson-io/jetson-io.py
```

Navigate: `Configure Jetson Nano CSI Connector` → `Camera IMX219 Dual` → `Save and reboot to reconfigure pins`. The script reboots the Nano automatically.

### CLI (if scripting)

```sh
sudo /opt/nvidia/jetson-io/config-by-hardware.py -l
sudo /opt/nvidia/jetson-io/config-by-hardware.py -n "Camera IMX219 Dual"
sudo reboot
```

Caveat: `config-by-hardware.py` on JetPack 4.6 has no `-i` / `--header` flag and defaults to scanning the 40-pin header first. If the hardware name `Camera IMX219 Dual` is ambiguous (or matches a 40-pin header entry first) the CLI fails with `No configuration found for Camera IMX219 Dual on Jetson 40pin Header!`. Fall back to the interactive `jetson-io.py` in that case.

### What got applied

After reboot, `/boot/extlinux/extlinux.conf` should have a `JetsonIO` label set as `DEFAULT`:

```
LABEL JetsonIO
    MENU LABEL Custom Header Config: <CSI Camera IMX219 Dual>
    LINUX /boot/Image
    FDT /boot/kernel_tegra210-p3448-0000-p3449-0000-b00-user-custom.dtb
    INITRD /boot/initrd
    APPEND ${cbootargs} ...
```

And the runtime DT now has the camera nodes:

```sh
ls /proc/device-tree/cam_i2cmux/i2c@0/   # cam0 / J13
# rbpcv2_imx219_a@10  rbpcv3_imx477_a@1a  ...

ls /proc/device-tree/cam_i2cmux/i2c@1/   # cam1 / J49
# rbpcv2_imx219_e@10  rbpcv3_imx477_e@1a  ...
```

`rbpcv2_imx219_*` is the Raspberry Pi Camera v2 binding; `rbpcv3_imx477_*` are present in the same overlay but `status = "disabled"` for the dual-IMX219 variant.

## 3. Verify the camera is alive

```sh
sudo dmesg | grep -E 'imx219.*(7-0010|8-0010)' | head
sudo i2cdetect -y -r 7    # i2c bus for J13 / cam0
ls /dev/video*
```

Expected output for a camera in J13:

- `dmesg`:
  ```
  imx219 7-0010: tegracam sensor driver:imx219_v2.0.6
  vi 54080000.vi: subdev imx219 7-0010 bound
  ```
  Crucially, **no** `imx219_board_setup: error during i2c read probe (-121)` line.

- `i2cdetect -y -r 7` shows `UU` on row `10:` (driver claimed sensor at i2c address 0x10):
  ```
  10: UU -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
  ```

- `/dev/video0` exists.

(For a camera in J49 substitute `imx219 8-0010` and `i2cdetect -y -r 8`. With one camera in one port, the unused port's bus will report `-121` errors at boot — that's normal, the imx219 driver probes both buses.)

If you see `-121` errors and an empty `0x10` in i2cdetect, with the DT overlay confirmed applied — the software is fine, the issue is hardware/contact. See § "Recovery: oxidized ribbon contacts".

## 4. Capture a JPEG

End-to-end pipeline through NVIDIA argus + hardware JPEG encoder, no CPU work:

```sh
time gst-launch-1.0 -e nvarguscamerasrc num-buffers=1 sensor-id=0 sensor-mode=3 \
    ! 'video/x-raw(memory:NVMM),width=1640,height=1232,framerate=30/1' \
    ! nvvidconv flip-method=2 \
    ! nvjpegenc \
    ! filesink location=/tmp/csi-mode3.jpg
ls -lh /tmp/csi-mode3.jpg
file /tmp/csi-mode3.jpg
```

Expected: ~150–300 KB JPEG, total wall time 1–2 s on first invocation (mostly argus/ISP cold-start). Each subsequent run of the same `gst-launch-1.0` invocation is also ~700 ms because each invocation re-launches the gstreamer process. In a long-lived pipeline (the planned MCP server below) the same pipeline is built once and held in `PLAYING`; per-capture latency drops to ~50 ms.

### IMX219 sensor modes

| `sensor-mode` | resolution | fps | binning | use case |
|---|---|---|---|---|
| 0 | 3264 × 2464 | 21 | none | full-res 8 MP |
| 1 | 3264 × 1848 | 28 | crop | 16:9 high-res |
| 2 | 1920 × 1080 | 30 | crop | 1080p |
| **3** | **1640 × 1232** | **30** | **2×2** | **balanced 4:3 — recommended for vision LLM input** |
| 4 | 1280 × 720 | 60 | binned | 720p high-fps |
| 5 | 1280 × 720 | 120 | binned | 720p slow-mo |

Why **mode 3** for vision LLM inference:

- 4:3 aspect aligns with the `--image-max-tokens 529` ceiling baked into the rllama-server defaults — see [`INSTALL.md` § "Vision: cap the patch count for big photos"](INSTALL.md#vision-cap-the-patch-count-for-big-photos).
- 2×2 binning lowers per-pixel noise in indoor lighting and reduces ISP work.
- The ~2 MP source is comfortably above what Qwen3.5-VL preprocesses to (`688 × 512` at 529 tokens, with `patch_size = 16` and `n_merge = 2`), so there's no upsample artefact and no oversampling penalty.
- Full-sensor `sensor-mode=0` (8 MP) would emit way more pixels than the encoder consumes — fine for offline use, wasteful for a live pipeline.

### `flip-method` reference

Captured frames can be rotated/flipped by `nvvidconv` — hardware-accelerated through the Tegra ISP, no CPU work:

| value | effect |
|---|---|
| 0 | none (default) |
| 1 | rotate 90° CCW |
| **2** | **rotate 180°** |
| 3 | rotate 90° CW |
| 4 | horizontal flip |
| 5 | upper-right diagonal flip |
| 6 | vertical flip |
| 7 | upper-left diagonal flip |

`flip-method=2` matches a typical desk-arm-mounted camera (camera ribbon entering from the bottom, sensor effectively upside-down) — adjust per your physical setup. It can be omitted if the camera is in natural orientation, but the cost of running through `nvvidconv` is paid either way once a sensor-format conversion is present in the pipeline.

## Recovery: oxidized ribbon contacts

If the camera previously worked on this Jetson, has not been touched physically, and now fails with `-121` after a reflash or long downtime — the most likely cause is **passive oxidation of the gold-plated ribbon contacts**. The plating is thin (≤ 0.5 µm), and over months in humid storage develops a surface oxide / sulfide layer that is visually invisible but raises contact resistance enough to break the i2c handshake.

### Symptoms (typically all four together)

- `dmesg | grep imx219`: `imx219_board_setup: error during i2c read probe (-121)` (`-121 = EREMOTEIO`, "no ACK from slave on i2c").
- `i2cdetect -y -r 7` (or `-r 8`): row `10:` shows `--` everywhere — sensor electrically silent.
- `gst-launch-1.0 ... nvarguscamerasrc`: `No cameras available`.
- DT overlay confirmed correct (`/proc/device-tree/cam_i2cmux/i2c@0/rbpcv2_imx219_a@10/` exists with `compatible = "nvidia,imx219"`), regulators present (`vdd-3v3-sys` enabled in `regulator_summary`), and a direct `sudo i2cget -y 7 0x10 0x00 b` returns `Error: Read failed`.

### Procedure

1. Power off completely (`sudo shutdown -h now`, then disconnect the barrel jack — CSI rails hold residual charge for a few seconds after software shutdown).
2. Lift the CSI latches on Nano *and* on the camera; remove the ribbon entirely.
3. Take a **clean white soft eraser** (a vinyl/plastic eraser for graphite — Faber-Castell, Staedtler, or any generic white office eraser. **Not** a rough sand-impregnated "ink eraser"). Lightly rub the ribbon's golden contacts **along the contact strip direction** (not across), 5–10 light passes per side. The eraser mechanically lifts the oxide layer without leaving liquid residue.
4. Repeat on **both ends** of the ribbon — Nano-side and camera-side. **Both** have to be clean for the link to come up; cleaning only one end is the most common cause of "I cleaned it and it still doesn't work".
5. Blow off eraser crumbs (don't push the ribbon back in with crumbs on the contacts — they'll get into the connector and cause new contact issues).
6. Reseat the ribbon, lower latches, power on.
7. Verify with the procedure in § 3.

### What **not** to use

- **Acetone** — attacks the polyimide ribbon film and the adhesive holding the contact pads.
- **Tap water, vodka, isopropyl < 91 %** — high water content leaves mineral residue / accelerates re-oxidation.
- **Screen cleaners with anionic surfactants** (Qilive Cleaning Gel, generic monitor wipes, etc.) — designed to leave a thin antistatic film on screens; on contacts that film changes contact resistance and traps moisture.
- **Regular WD-40** — leaves an oily film that becomes an insulator under contact pressure. (`WD-40 Specialist Contact Cleaner` is a different product and is fine.)

### Acceptable wet alternatives if eraser alone doesn't restore contact

- **99 %+ isopropyl alcohol (IPA)** — pharmacy or electronics shop. Apply with a cotton swab to the contacts, allow full evaporation (~2 min) before reseating.
- **DeoxIT D5** or **Kontakt 60 / 61** contact-cleaner sprays — designed for exactly this case, evaporate cleanly without residue.

In practice, a soft-eraser pass is sufficient ~95 % of the time on dry oxidation. Reach for a wet alternative only if a pure eraser pass leaves the i2c link still down.

## Next: MCP server

The capture pipeline above is the foundation; the next step is wrapping it in an MCP server so an agent (Claude Code, or anything speaking MCP) can request a camera frame and feed it to the local `rllama-server` for vision inference. Tracked on branch `mcp-csi-camera-jetson-nano`.

Design decisions made during this bring-up (to be implemented):

- **Language**: Rust. Floor of ~25–40 MB resident persistent vs ~100–150 MB for Python + PyGObject + gstreamer-python. Matters on a 4 GB Jetson where `rllama-server` already eats ~3 GB.
- **Pipeline lifetime**: persistent (`PAUSED ↔ PLAYING`), not lazy-build / idle-teardown. Predictable latency, simpler code, the constant ~30 MB cost is noise next to the LLM process.
- **Transport**: Streamable HTTP (the 2025-11-25 MCP spec transport). Listens on a local TCP port (default `0.0.0.0:8777`, endpoint `/mcp`) — lets us test with MCP Inspector by URL, run the camera server on the Jetson and call from a Mac, and plug the same endpoint into any MCP client (Claude Desktop, agent frameworks) by URL config. Pure stdio was the initial plan but rmcp 1.6 doesn't expose a standalone SSE-server transport (SSE is now an internal detail of Streamable HTTP), and the network endpoint is better for development anyway.
- **Tool surface**: a single `capture_frame` returning a path to a JPEG written to `/tmp/mcp-csi/<timestamp>.jpg`. tmpfs is RAM-backed on JetPack 4.6, so file path = effective pointer-into-RAM with zero base64 overhead vs returning the JPEG inline as MCP `image` content.
- **Default capture parameters**: `sensor-id=0` (J13), `sensor-mode=3` (1640×1232 @ 30 fps, 4:3, 2×2 binned), `flip-method=2` (configurable per deployment).

This section will be filled in once the server is implemented.
