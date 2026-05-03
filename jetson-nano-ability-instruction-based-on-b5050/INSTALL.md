# Build llama.cpp b9006 on Jetson Nano — quick install

End-to-end procedure for the **2019 Jetson Nano Devkit** (Tegra X1, compute 5.3, 4 GB unified memory) running JetPack 4.6.x with CUDA 10.2. Everything code-side is already patched on branch `jetson-nano-b9006`; this is just the runbook.

For the *why* and the chronology of patches see [`HISTORY.md`](HISTORY.md). The original (now superseded) procedure is at [`llama.cpp-jetson/README.md`](llama.cpp-jetson/README.md).

## 0. Prerequisites — install once

Skip a sub-step if you already have it.

### 0.1 Toolchain — gcc 8.5 and cmake ≥ 3.27

These are the *only* toolchain combinations confirmed to work with nvcc 10.2 + this branch. Both are described in detail in the [original b5050 README](llama.cpp-jetson/README.md) (`Install prerequisites`, `Choosing the right compiler`).

- gcc / g++ **8.5.0** — built from source, ~3 hours on the Nano. Faster alternative: gcc 9.4 from `ppa:ubuntu-toolchain-r/test`, ~4 minutes; if you go that route also patch line 136 of `/usr/local/cuda/targets/aarch64-linux/include/crt/host_config.h` (change `8` to `9`).
- cmake **3.27** — ~38 minutes (bootstrap + make).

After install:

```sh
gcc --version    # gcc (Ubuntu …) 8.5.0
nvcc --version   # release 10.2, V10.2.300
cmake --version  # cmake version 3.27.x
```

### 0.2 System packages

```sh
sudo apt-get update
sudo apt-get install -y nano curl libcurl4-openssl-dev libssl-dev python3-pip ca-certificates
sudo update-ca-certificates
pip3 install -U jetson-stats   # optional — provides `jtop`
```

### 0.3 (One-time) Add swap

The Jetson Nano has 4 GB RAM. `llama-model.cpp` and `tools/server/server.cpp` each peak around 2–2.5 GB during compile; without swap, parallel builds OOM. Add 4 GB swap once:

```sh
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 1. Clone and check out the patched branch

```sh
cd ~
git clone https://github.com/KoryakovDmitry/llama.cpp-b9006.git
cd llama.cpp-b9006
git checkout jetson-nano-b9006
```

## 2. Install the bf16 stub headers into the CUDA include tree

CUDA 10.2 doesn't ship `<cuda_bf16.h>`. b9006 needs both that header and `<cuda_bf16.hpp>`. Stubs are in the repo:

```sh
sudo cp jetson-nano-b9006-patch/files/cuda_bf16.h   /usr/local/cuda/include/
sudo cp jetson-nano-b9006-patch/files/cuda_bf16.hpp /usr/local/cuda/include/
```

(They typedef `nv_bfloat16`/`nv_bfloat162` onto `__half`/`__half2` and forward the bf16 intrinsics to their `__half` equivalents. Numerics for code paths actually instantiated on sm_50/sm_61 end up in fp16; Ampere+/HIP-only paths are not instantiated. See [`HISTORY.md`](HISTORY.md) for details.)

## 3. Configure cmake

```sh
cmake -B build \
  -DGGML_CUDA=ON \
  -DLLAMA_BUILD_LIBRESSL=ON \
  -DCMAKE_CUDA_STANDARD=14 \
  -DCMAKE_CUDA_STANDARD_REQUIRED=true \
  -DGGML_CPU_ARM_ARCH=armv8-a \
  -DGGML_NATIVE=off
```

What each flag does:

| Flag | Why |
|---|---|
| `-DGGML_CUDA=ON` | Enable the CUDA backend (the whole point). |
| `-DLLAMA_BUILD_LIBRESSL=ON` | Ubuntu 18.04 has OpenSSL 1.1.1; cpp-httplib in b9006 wants ≥ 3.0. CMake fetches and builds LibreSSL inline; otherwise `-hf` gives `HTTPS is not supported`. |
| `-DCMAKE_CUDA_STANDARD=14` | nvcc 10.2 maxes out at C++14. The branch has all needed C++17 features back-ported to C++14. |
| `-DGGML_CPU_ARM_ARCH=armv8-a` | Tegra X1 is armv8-a, no SVE / dotprod / matmul-int8 / FP16-vector / SME. |
| `-DGGML_NATIVE=off` | Don't probe extra ARM extensions on top of armv8-a. |

Expected output landmarks:

```
-- The CUDA compiler identification is NVIDIA 10.2.300
-- CUDA host compiler is GNU 8.5.0
-- Using CMAKE_CUDA_ARCHITECTURES=50;61 CMAKE_CUDA_ARCHITECTURES_NATIVE=53-real
-- ggml commit:  <short SHA matching tip of jetson-nano-b9006>
```

Three warnings are expected and harmless:

- `LLAMA_CURL is deprecated and will be ignored` — the b5050 flag was folded into the default build.
- `Could NOT find NCCL …` — multi-GPU collective comms; Jetson is single-GPU.
- `Performing Test OPENSSL_VERSION_SUPPORTED - Failed` — the system OpenSSL test fails (we use LibreSSL anyway).

## 4. Build

The repo includes a small wrapper that captures stdout+stderr to a log while still streaming to the terminal, preserves cmake's exit code (not `tee`'s), and forwards extra args to `cmake --build` after `--`:

```sh
./jetson-nano-b9006-patch/scripts/build_with_log.sh -- -j2
```

Time on a stock SD-card-backed Jetson Nano: **roughly 90–120 minutes** for a clean build with `-j2` (CUDA backend dominates; everything after `[23%] Built target ggml-cuda` is fast). USB-SSD storage roughly halves that. Don't go above `-j2` unless `free -h` shows headroom.

If you skip the wrapper:

```sh
cmake --build build --config Release -j2
```

The build will spend most of its time in `ggml/src/ggml-cuda/CMakeFiles/ggml-cuda.dir/` — that's normal. Constant `constexpr if statements are a C++17 feature` warnings from nvcc are expected and harmless. A single `iteration … invokes undefined behavior [-Waggressive-loop-optimizations]` warning in `ggml-cpu/simd-gemm.h` is gcc heuristic noise, also harmless.

## 5. Run

The binaries land in `build/bin/`. From the repo root:

```sh
cd build/bin
./llama-cli -hf ggml-org/gemma-3-1b-it-GGUF --n-gpu-layers 99
```

Expected first-time-load behaviour:
- Initial download of the GGUF from HuggingFace via the LibreSSL-backed httplib client.
- A long pause on `main: load model the model and apply lora adapter, if any` — about **6:30** on first load (cache is cold). Subsequent loads ≈ 12 s.
- Steady-state inference: **~7 t/s generation** on Q4_K_M, slightly faster prompt processing depending on prompt length.

To start an OpenAI-compatible HTTP server instead:

```sh
./llama-server -m ~/.cache/llama.cpp/<filename>.gguf --host 0.0.0.0 --n-gpu-layers 99
```

### What works on a Jetson Nano (4 GB unified)

Numbers below are from this build (`b9061-7b27754cc` and similar) on a stock SD-card-backed Jetson Nano with `--n-gpu-layers 99`.

| Model | Modality | Quant | t/s gen | Notes |
|---|---|---|---|---|
| `ggml-org/gemma-3-1b-it-GGUF` | text | Q4_K_M | ~7.4 | Reference text baseline. |
| `unsloth/Qwen3.5-0.8B-GGUF:Q8_0` | text + vision | Q8_0 | ~6.2 | Vision encoder runs through the bf16-decode patch from Phase 5c. |
| `unsloth/Qwen3.5-0.8B-GGUF:UD-Q4_K_XL` | text + vision | UD-Q4_K_XL | TBD | Smaller dynamic quant; should be similar or slightly faster. |

Larger models (≥ 2B parameters, especially multimodal) are at or past the 4 GB ceiling and will OOM at load. Try Q3_K / IQ2_M variants if you need bigger, or live with `--n-gpu-layers 20`-style partial offload.

### Vision: cap the patch count for big photos

Modern vision encoders fall into two camps with very different reactions to large inputs:

- **Fixed-resolution** (CLIP / SigLIP — used by LLaVA-1.5, Phi-Vision, Gemma 3 vision, etc.) always downsample to a hard-coded square (224×224, 336×336, 896×896). GPU work is **constant** regardless of input size.
- **Dynamic-resolution** (Qwen2-VL, Qwen3-VL, InternVL, etc.) preserve the input aspect ratio and emit a number of 14×14 patches **proportional to input area**, capped only by the model's `max_pixels`. GPU work scales **linearly with megapixels**.

`unsloth/Qwen3.5-*-GGUF` is the second kind. A 12 MP phone photo on the Tegra X1 produces tens of thousands of patches; the resulting vision-encoder kernels run for many seconds and trip the Jetson's ~2 s GPU watchdog → `the launch timed out and was terminated`.

#### How the math works for Qwen-VL

The numbers below come directly from this build's source of truth — `tools/mtmd/clip.cpp:1352-1369` (the Qwen2VL/2.5VL/3VL projector setup) and `tools/mtmd/clip-model.h:112-118` (token-budget → pixel-budget conversion). Crucially, **`patch_size` is read from the GGUF metadata per-model** and differs between Qwen-VL generations:

| Family | `patch_size` | `n_merge` | Snap unit (`patch × n_merge`) | Pixels per LLM token (`(snap)²`) |
|---|---|---|---|---|
| Qwen2-VL / Qwen2.5-VL | 14 | 2 | 28 | 784 |
| **Qwen3-VL / Qwen3.5** | **16** | **2** | **32** | **1024** |

The numbers in the rest of this section refer to **Qwen3.5** (`patch_size = 16`), since that's the model used in the runs documented here. To verify what your model actually reports, look for these lines in the server log on startup:

```
load_hparams: patch_size:         16
load_hparams: n_merge:            2
load_hparams: image_max_pixels:   588800 (custom value)
```

The math:

- The image is **rescaled to a multiple of `patch_size × n_merge`** on each side, preserving aspect ratio.
- `patches = (W'/patch_size) × (H'/patch_size)` over the rescaled image.
- `LLM_tokens = patches / (n_merge × n_merge) = patches / 4`.
- The default token budget for the Qwen-VL family in `clip.cpp` is `set_limit_image_tokens(8, 4096)`. For Qwen3.5 that means `image_max_pixels = 4096 × 1024 ≈ 4.2 MP` out of the box. Anything bigger is auto-downsampled before patching.

`--image-max-tokens N` overrides that upper bound — it caps `image_max_pixels` to `N × pixels-per-token` (1024 for Qwen3.5). The vision encoder does self-attention over **patches** (not LLM tokens), so its GPU cost scales as `patches² = (4 × LLM_tokens)²`.

**Subtle pitfall**: the *same* `--image-max-tokens N` produces a different actual token count depending on the input image aspect ratio, because both sides have to land on a multiple of the snap unit. **Square (1:1) is the worst-case aspect** — it can pack the budget perfectly when `√N` is an integer (and that's exactly when the watchdog edge sits, at `N = 24² = 576`). Other aspects waste 5–15 % of the budget on the integer-snap on each side.

Concrete examples for Qwen3.5 with `--image-max-tokens 575`:

- 4:3 input → snaps to `864×672` → `54×42 = 2268` patches → **567 LLM tokens** (~98 % of budget used).
- Square input → `768×768 = 589824` > budget (`588800`); falls back to `736×736` → `46² = 2116` patches → **529 LLM tokens** (~92 % of budget used).

So a budget of 575 doesn't actually cost 575 tokens of encoder work — it costs whatever the largest aspect-preserving grid that fits is. The flag is a *cap*, not a target. This is why the table below shows the *actual* tokens used per aspect, not the budget.

#### Patches and tokens at common image sizes (Qwen3.5, patch_size=16)

The "Actual encoder grid" column is what the preprocessor lands on for the listed input — multiple budget values can land on the same grid. The "Verdict" reflects the actual GPU work, not the budget you asked for.

| Input / budget | Aspect | Actual encoder grid (W'×H') | Patches `(side/16)²` | LLM tokens `(/4)` | Encoder work `∝ patches²` | Verdict on Jetson Nano |
|---|---|---|---|---|---|---|
| 224×224 fixed | 1:1 | 224×224 | 14² = 196 | 49 | ~0.6× | trivially OK |
| 512×512 fixed | 1:1 | 512×512 | 32² = 1024 | 256 | ~16× | OK |
| `--image-max-tokens 256` | square | 512×512 | 32² = 1024 | 256 | ~16× | ✅ safe with margin |
| `--image-max-tokens 324` | 4:3 | ~672×496 | 42×31 = 1302 | 326 | ~26× | ✅ matches 512×512 baseline |
| **`--image-max-tokens 529`, any aspect** | **any** | **square→736×736, 4:3→832×640, 16:9→960×544** | **23² = 529 / 52×40 = 2080 / 60×34 = 2040** | **529 / 520 / 510** | **~64–68×** | **✅ recommended for server (uniform across aspects, ≤529 always)** |
| `--image-max-tokens 540`, 4:3 input | 4:3 | 864×640 | 54×40 = 2160 | 540 | ~71× | ✅ tested (~6.0 t/s gen) |
| `--image-max-tokens 540…575`, 4:3 input | 4:3 | 864×640 → 864×672 | 54×40 → 54×42 | 540 → 567 | ~71–78× | ✅ tested at multiple budgets in this range (~6.0–6.2 t/s) |
| `--image-max-tokens 540…575`, square input | 1:1 | 736×736 (locked, can't reach 768²) | 46² = 2116 | 529 | ~68× | ✅ — square actual is the same 529 across this whole budget range |
| `--image-max-tokens 576`, square input | 1:1 | 768×768 (now allowed!) | 48² = 2304 | 576 | ~81× | ❌ tested — `the launch timed out and was terminated` |
| `--image-max-tokens 579`, square input | 1:1 | 768×768 | 48² = 2304 | 576 | ~81× | ❌ tested — same 24² square trips the watchdog |
| 768×768 fixed input, no `--image-max-tokens` | 1:1 | 768×768 | 48² = 2304 | 576 | ~81× | ❌ same as above |
| 1024×1024 | 1:1 | 1024×1024 | 64² = 4096 | 1024 | ~256× | always fails |
| 4032×3024 (12 MP, no flags) | 4:3 | clamped by default cap to ~2336×1760 | 146×110 = 16060 | 4015 | ~4000× | fails — even the default cap (4096 LLM tokens for Qwen-VL family) is way over budget for Tegra X1 |

Empirical Tegra X1 stock-clock ceiling, in *actual* encoder tokens (not budget), sits **between 540 and 576 LLM tokens** (~71–81× baseline encoder cost). The exact-square `768×768 = 48² = 2304 patches → 576 tokens` consistently trips the GPU watchdog; everything below it (529 square / 540–567 wide) consistently passes. The hop between 567 and 576 is exactly one `n_merge`-sized step on each axis of a square — there's no fine-tuning room in between.

#### Recommended values for Qwen3.5 on a Jetson Nano

The right `--image-max-tokens` depends on whether your inputs are *known* aspect ratio or arbitrary:

- **`--image-max-tokens 529`** — **the principled default** (recommended for `llama-server` and any setup where input aspect varies). `529 = 23²` is the largest safe square grid; for any budget in `[529, 575]` square inputs *always* snap to this same `23² = 529` grid, while non-square inputs use even less. So 529 gives you the same square ceiling as 575 with a wider safety margin to the 576-watchdog edge (8.2 % vs 6.3 %), and predictable behaviour across aspects.
- **`--image-max-tokens 540`** — slightly more detail on **4:3 inputs only** (540 actual tokens vs 520 at budget 529). Same safety as 529 for square inputs (still 529 actual). Useful in CLI when you know the input is landscape phone-photo aspect.
- **`--image-max-tokens 324`** — match the 512×512 baseline (~26× cost). Conservative, useful if power-mode is restricted or other GPU contention is around (X11 still running, multi-slot server traffic, etc.).
- **`--image-max-tokens 256`** — substantial margin. Use as a defensive fallback when you've already seen a watchdog timeout at higher values.

What about budgets in `[541, 575]`? They give 4:3 inputs slightly more detail (up to `54×42 = 567` at budget 575) but offer **zero benefit on square** (still locked to 529) while reducing margin to 576. So they only make sense in CLI with known-wide inputs — never in server mode.

`--image-max-tokens ≥ 576` is **forbidden** on Tegra X1 stock-clocks: it lets the preprocessor pick the `48² = 768×768` square grid that consistently trips the GPU watchdog. Don't go there without `nvpmodel -m 0 && jetson_clocks` (and even then, expect occasional jitter at the edge).

The 12 MP row is the punchline of why "but llama.cpp already resizes" doesn't save you: Qwen-VL's default `image_max_pixels` is **4096 LLM tokens**, which downsamples a 12 MP phone photo to ~2072×1540 — but 4070 tokens is still ~12× the 512×512 baseline in token count and ~150× in encoder work. The model's idea of a sensible cap and the Tegra X1's idea of a survivable workload disagree by two orders of magnitude.

#### Caveat with `--reasoning-budget-message`

When the sampler hits the budget and injects the message before `</think>`, it does so **at the exact next token boundary** — it doesn't wait for the model to finish a word. So the message can be concatenated to a half-written word, e.g.:

```
- It looks like aTime to summarize and answer.    # ← no space
```

The model still produces a clean answer afterwards, this is just cosmetic. If it bothers you, prepend a punctuation/whitespace separator to the message so the seam is invisible:

```sh
--reasoning-budget-message ". Time to summarize and answer."
# or
--reasoning-budget-message $'\nTime to summarize and answer.'
```

The principled fix is to ask llama.cpp to bound the LLM-token count itself, via the multimodal preprocessor flag:

```sh
rllama-cli -hf unsloth/Qwen3.5-0.8B-GGUF:Q8_0 \
    --n-gpu-layers 99 --reasoning-budget 0 \
    --image-max-tokens 256
# > /image /home/diikorr/IMG_20260503_022544_883.jpg
```

Tested working budgets on Tegra X1 (no `jetson_clocks`, 4:3 phone-photo input): **324**, **529**, **540**, **560**, **570**, **575** all pass at ~6.0–6.2 t/s gen. Tested failing budgets: **576**, **579** (square or near-square input picks `48² = 768×768 = 576` actual tokens, trips watchdog). For diverse-aspect inputs (server mode, public endpoint), use **`--image-max-tokens 529`** — the budget headroom past 529 is wasted on square inputs anyway, and 529 keeps the largest watchdog margin. For known-wide CLI inputs you can push to 540–575 to squeeze a bit more 4:3 detail. The flag overrides whatever default the model's metadata declares, so the same number applies regardless of input image size.

For fixed-resolution vision encoders the flag is a no-op (they downsample internally to their fixed input regardless), so it's safe to leave on.

If you would rather not pass an extra CLI flag every time, ImageMagick still works:

```sh
sudo apt install -y imagemagick
convert IMG_in.jpg -resize 512x512\> -strip IMG_resized.jpg
# > /image /home/diikorr/IMG_resized.jpg
```

ImageMagick + `--image-max-tokens` are independent; either alone is sufficient on a Jetson Nano. `--image-max-tokens` is recommended because it works for any input you point at the model without a separate preprocessing step.

#### Tuning per request via the server API

The CLI flags above are read once at startup and frozen afterwards: `tools/cli/cli.cpp:228-235` only registers seven slash-commands (`/audio /clear /exit /glob /image /read /regen`) — **no `/reasoning` or `/image-max-tokens`** — and `tools/server/server-context.cpp:819-820` bakes `image_min_tokens` / `image_max_tokens` into the multimodal context at model load time. So the **image cap stays fixed for the lifetime of the process**, both in CLI and in server mode.

The reasoning-related knobs *can* be overridden per-request through `llama-server`, by a body field that wins over the server-startup default — but only when the server was started without that flag (so its default stays at the unset sentinel). Example (`tools/server/server-common.cpp:1132-1145`):

```cpp
int reasoning_budget = opt.reasoning_budget;
if (reasoning_budget == -1 && body.contains("thinking_budget_tokens")) {
    reasoning_budget = json_value(body, "thinking_budget_tokens", -1);
}
```

So a useful runtime-tunable server setup looks like this:

```sh
# Start the server with the image cap fixed and the reasoning budget left
# at the default (-1 = unrestricted), so each request can override it:
rllama-server -hf unsloth/Qwen3.5-0.8B-GGUF:Q8_0 \
    --n-gpu-layers 99 \
    --image-max-tokens 529 \
    --host 0.0.0.0 --port 8080
```

Then per request, hit `POST /v1/chat/completions` (OpenAI-compatible) with extra fields in the body:

```jsonc
{
  "model": "qwen3.5",
  "messages": [
    {"role": "user", "content": [
      {"type": "text",      "text": "describe the image"},
      {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
    ]}
  ],

  // Per-request reasoning controls
  "thinking_budget_tokens": 128,         // -1 unlimited, 0 = no thinking, N = budget
  "chat_template_kwargs": {
    "enable_thinking": false             // or "true" — overrides --reasoning at the template level
  }
}
```

What can and can't be overridden per-request:

| Knob | Per-request override | Notes |
|---|---|---|
| reasoning budget (token count) | ✅ `thinking_budget_tokens` | Only effective if server started without `--reasoning-budget`. |
| reasoning on/off (template) | ✅ `chat_template_kwargs.enable_thinking` | Hits the Jinja template; useful when `--reasoning auto` was the startup default. |
| `--reasoning-budget-message` | ❌ | Set once at server startup, baked into the sampler. |
| `--image-max-tokens` / `--image-min-tokens` | ❌ | Baked into the multimodal context at model load. |

Practical pattern on a Jetson Nano: pin **`--image-max-tokens 529`** at startup — this is the largest *square*-aligned grid (23²) that fits below the 576-token watchdog edge, so all input aspects (square, portrait, landscape, 4:3, 16:9) consistently produce ≤ 529 actual tokens. Let `thinking_budget_tokens` vary per request — large for tasks that benefit from chain-of-thought, `0` for "just answer" requests where you don't want to wait through ~30 s of thinking.

> **Server-mode caveat seen in practice**: when you start `rllama-server` with `--image-max-tokens 575` and clients POST images of varying aspect ratio, the preprocessor *can* pick a grid up to `46² = 529` for square inputs and `54×42 = 567` for 4:3 inputs — both safe. But at any budget `≥ 576`, square / near-square inputs snap to the `48² = 768×768` grid (576 actual tokens) which consistently crashes the server with `the launch timed out and was terminated` from the multimodal `process_chunks` path. CLI runs with budget 575 against a 4:3 photo never hit this because the snap lands on `54×42 = 567`, but in a public server endpoint you can't predict what aspect ratio clients will send. **Use 529 for any server deployment.**

## 6. (Optional) Run from anywhere via prefixed symlinks

If you want `llama-cli` / `llama-server` / etc. callable from any directory, but you also have an older system-wide install (e.g. the b5050 binaries that kreier's `install.sh` drops into `/usr/local/bin`) that you don't want to overwrite, install symlinks with a prefix into `~/.local/bin`:

```sh
./jetson-nano-b9006-patch/scripts/install_symlinks.sh
```

Default behaviour: every `llama-*` binary in `build/bin/` gets a symlink at `~/.local/bin/r<name>` (e.g. `rllama-cli`, `rllama-server`, `rllama-bench`). Then:

```sh
llama-cli --version    # old b5050 (still in /usr/local/bin, untouched)
rllama-cli --version   # new b9006
```

`~/.local/bin` is in PATH on default Ubuntu setups; if not, the script prints the line to add to `~/.bashrc`. RPATH stays valid because the linker resolves it from the binary's real path, not the symlink. Re-run the script after rebuilds — it's idempotent (`ln -sfn`). Use `--prefix ""` and `--target /usr/local/bin` if you want unprefixed system-wide install instead.

## 7. (Optional) CSI camera for live vision input

If you have a Raspberry Pi Camera v2.1 (Sony IMX219) connected to the J13 / J49 CSI connector and want to feed live frames to the multimodal `rllama-server` from §5, see [`CSI_CAMERA.md`](CSI_CAMERA.md). It covers:

- Physical install (ribbon orientation and latching on the dev kit B01).
- The device-tree overlay step (`jetson-io.py` → `Camera IMX219 Dual` → reboot).
- The verification ladder (`dmesg`, `i2cdetect`, `/dev/video*`).
- A validated `nvarguscamerasrc → nvvidconv → nvjpegenc → filesink` capture pipeline at sensor-mode 3 (1640×1232 @ 30 fps, 4:3, 2×2 binned) — the same pipeline that the upcoming MCP server (branch `mcp-csi-camera-jetson-nano`) will hold open as a long-lived gstreamer graph.
- The IMX219 sensor-mode and `flip-method` reference tables.
- The recovery procedure for the common `-121 EREMOTEIO` ribbon-oxidation failure mode that bites after an OS reflash or long downtime — software / DT looks clean, but the gold-plated ribbon contacts have oxidized passively and need a soft-eraser pass on both ends.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `HTTPS is not supported. Please rebuild with -DLLAMA_BUILD_LIBRESSL=ON` | LibreSSL flag was missed at configure time | Reconfigure with the flag from §3, rebuild |
| `HTTPLIB failed: SSL server verification failed` | CA bundle not loaded by LibreSSL | Confirm `/etc/ssl/certs/ca-certificates.crt` exists and `ca-certificates` package is installed; the patched `common/http.h` should pick it up automatically |
| OOM / killed builder | Too high `-j` | Drop to `-j2` or `-j1`; verify swap is on (`swapon --show`) |
| `cuda_bf16.h: No such file or directory` while building CUDA backend | Stubs not copied to `/usr/local/cuda/include/` | Re-run §2 |
| `error: gcc versions later than 8 are not supported!` | Toolchain mismatch — nvcc 10.2 forbids gcc ≥ 9 unless the host_config.h hack is applied | Either install gcc 8.5, or edit `/usr/local/cuda/targets/aarch64-linux/include/crt/host_config.h` line 136 (change 8 → 9) |
| Inference much slower than ~7 t/s | Forgot `--n-gpu-layers 99`, or model didn't fit in unified memory | Verify with `jtop` that the GPU is actually loaded |
| Vision: `the launch timed out and was terminated` after `/image …` or on first server image POST | Dynamic-resolution vision encoder (Qwen-VL etc.) emitted too many patches → vision encoder kernel ran past the Jetson's ~2 s GPU watchdog. With Qwen3.5 (`patch_size=16`) the trip-wire is 48×48 = 2304 patches = 576 LLM tokens, which the preprocessor picks for square inputs at any `--image-max-tokens ≥ 576`. | Pass **`--image-max-tokens 529`** (the largest 23² square-aligned grid; safe across any input aspect — square→529, 4:3→520, 16:9→510 actual tokens) |
| CSI camera: `dmesg` shows `imx219 ...: imx219_board_setup: error during i2c read probe (-121)` after a fresh OS install or long downtime; `i2cdetect -y -r 7` empty on row `10:`; `/dev/video*` absent | DT overlay missing **and / or** ribbon contact oxidation (gold plating develops surface oxide passively). | (1) Apply `Camera IMX219 Dual` overlay via `sudo /opt/nvidia/jetson-io/jetson-io.py` (DT side). (2) Power off, clean ribbon's golden contacts with a soft white eraser on **both** ends along the contact-strip direction (electrical side). Full procedure in [`CSI_CAMERA.md`](CSI_CAMERA.md). |
| Vision: model emits `??????…` instead of describing the image | The bit-correct BF16 → fp16/fp32 conversion in `convert.cu` was reverted/lost | Confirm `bf16_bits_to_fp{16,32}_cuda` exist in `ggml/src/ggml-cuda/convert.cu` and the `GGML_TYPE_BF16` cases in `ggml_get_to_fp{16,32}_cuda` route to them under `CUDART_VERSION < 11000` |
| Vision: `CUBLAS_STATUS_NOT_SUPPORTED` from `cublasGemmEx ... CUDA_R_16BF` | `supports_bf16` not gated on `CUDART_VERSION` | Confirm the `#if CUDART_VERSION < 11000` guard around `supports_bf16` in `ggml/src/ggml-cuda/ggml-cuda.cu` is intact |

## What was changed in the source tree

For the curious — see [`HISTORY.md`](HISTORY.md) for the full chronology with commit hashes. Touched files (all on this branch):

```
CMakeLists.txt                                 # CUDA arch limit
ggml/CMakeLists.txt                            # stdc++fs link
ggml/src/ggml-cuda/common.cuh                  # is_same_v shim, is_any rewrite, structured bindings, drop inline,
                                                 #   sm_53 in fast_fp16_hardware_available
ggml/src/ggml-cuda/fattn-common.cuh            # comment __builtin_assume
ggml/src/ggml-cuda/fattn-vec.cuh               # comment __builtin_assume
ggml/src/ggml-cuda/mma.cuh                     # guard nv_bfloat162 specs/overloads
ggml/src/ggml-cuda/mmf.cuh                     # bf16 instantiation helpers
ggml/src/ggml-cuda/binbcast.cu                 # comma-fold rewrite
ggml/src/ggml-cuda/softmax.cu                  # cg/reduce guard, cg-body stub
ggml/src/ggml-cuda/convert.cu                  # bit-correct BF16 -> fp16/fp32 kernels (CUDA<11)
ggml/src/ggml-cuda/ggml-cuda.cu                # structured bindings, if-init, inline-static traits,
                                                 #   cudaStreamWaitEvent, supports_bf16, use_fp16+=BF16
common/http.h                                  # explicit CA bundle loading
jetson-nano-b9006-patch/files/cuda_bf16.h            # stub for /usr/local/cuda/include/
jetson-nano-b9006-patch/files/cuda_bf16.hpp          # companion stub
jetson-nano-b9006-patch/scripts/build_with_log.sh    # build wrapper that captures stdout+stderr to a log
jetson-nano-b9006-patch/scripts/install_symlinks.sh  # install r-prefixed symlinks into ~/.local/bin
jetson-nano-b9006-patch/scripts/mem_watch.sh         # periodic memory/swap snapshotting for diagnosis
```

If/when you want to merge upstream changes from `master`, expect conflicts in most of those files — the patches are deliberate adaptations, not generic improvements.