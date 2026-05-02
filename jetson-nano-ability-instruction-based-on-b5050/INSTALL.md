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
./jetson-nano-b9006-patch/build_with_log.sh -- -j2
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

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `HTTPS is not supported. Please rebuild with -DLLAMA_BUILD_LIBRESSL=ON` | LibreSSL flag was missed at configure time | Reconfigure with the flag from §3, rebuild |
| `HTTPLIB failed: SSL server verification failed` | CA bundle not loaded by LibreSSL | Confirm `/etc/ssl/certs/ca-certificates.crt` exists and `ca-certificates` package is installed; the patched `common/http.h` should pick it up automatically |
| OOM / killed builder | Too high `-j` | Drop to `-j2` or `-j1`; verify swap is on (`swapon --show`) |
| `cuda_bf16.h: No such file or directory` while building CUDA backend | Stubs not copied to `/usr/local/cuda/include/` | Re-run §2 |
| `error: gcc versions later than 8 are not supported!` | Toolchain mismatch — nvcc 10.2 forbids gcc ≥ 9 unless the host_config.h hack is applied | Either install gcc 8.5, or edit `/usr/local/cuda/targets/aarch64-linux/include/crt/host_config.h` line 136 (change 8 → 9) |
| Inference much slower than ~7 t/s | Forgot `--n-gpu-layers 99`, or model didn't fit in unified memory | Verify with `jtop` that the GPU is actually loaded |

## What was changed in the source tree

For the curious — see [`HISTORY.md`](HISTORY.md) for the full chronology with commit hashes. Touched files (all on this branch):

```
CMakeLists.txt                                 # CUDA arch limit
ggml/CMakeLists.txt                            # stdc++fs link
ggml/src/ggml-cuda/common.cuh                  # is_same_v shim, is_any rewrite, structured bindings, drop inline
ggml/src/ggml-cuda/fattn-common.cuh            # comment __builtin_assume
ggml/src/ggml-cuda/fattn-vec.cuh               # comment __builtin_assume
ggml/src/ggml-cuda/mma.cuh                     # guard nv_bfloat162 specs/overloads
ggml/src/ggml-cuda/mmf.cuh                     # bf16 instantiation helpers
ggml/src/ggml-cuda/binbcast.cu                 # comma-fold rewrite
ggml/src/ggml-cuda/softmax.cu                  # cg/reduce guard, cg-body stub
ggml/src/ggml-cuda/ggml-cuda.cu                # structured bindings, if-init, inline-static traits, cudaStreamWaitEvent
common/http.h                                  # explicit CA bundle loading
jetson-nano-b9006-patch/files/cuda_bf16.h      # stub for /usr/local/cuda/include/
jetson-nano-b9006-patch/files/cuda_bf16.hpp    # companion stub
jetson-nano-b9006-patch/build_with_log.sh      # build wrapper helper
```

If/when you want to merge upstream changes from `master`, expect conflicts in most of those files — the patches are deliberate adaptations, not generic improvements.