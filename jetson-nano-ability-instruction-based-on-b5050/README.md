# Jetson Nano build for llama.cpp b9006

Adaptation of the b5050 Jetson Nano procedure (original at [`llama.cpp-jetson/README.md`](llama.cpp-jetson/README.md)) to release **b9006** (commit `c5a3bc39b`). Branch: `jetson-nano-b9006`. Original brief: [`TASK.md`](TASK.md).

The b5050 procedure targeted commit `23106f94e` (April 2025). Between that and b9006 the CUDA backend was reorganized and `bf16` became a first-class type across many kernels, so the patches were re-derived rather than applied verbatim.

## What was already done (steps 2–6 from the original procedure)

### Step 2 — limit `CMAKE_CUDA_ARCHITECTURES` to `50 61`

Same `if(NOT DEFINED ...)` block as b5050, inserted in `CMakeLists.txt` right after the build-type setup.

### Step 3 — link `stdc++fs`, pass `-Wl,--copy-dt-needed-entries`

Same two lines as b5050, added in `ggml/CMakeLists.txt` after `set_target_properties(ggml PROPERTIES PUBLIC_HEADER ...)`. That target line is now at line 342 (was 274 in b5050).

### Step 4 — remove `constexpr` from `kvalues_iq4nl` in `common.cuh`

**Skipped.** The declaration was moved to `ggml/src/ggml-common.h:1110` as `GGML_TABLE_BEGIN(int8_t, kvalues_iq4nl, 16)`, which expands to `static const __device__ int8_t ...` for CUDA — no `constexpr`. Other `static constexpr` uses in `common.cuh` are valid C++14 and compile under `-DCMAKE_CUDA_STANDARD=14`.

### Step 5 — comment direct `__builtin_assume(...)` calls

Two direct call sites in b9006:

- `ggml/src/ggml-cuda/fattn-common.cuh:890`
- `ggml/src/ggml-cuda/fattn-vec.cuh:111`

Both commented out. `fattn-vec-f16.cuh` and `fattn-vec-f32.cuh` were merged into `fattn-vec.cuh` between b5050 and b9006, so the original three-file fix collapses to two files. The `GGML_CUDA_ASSUME(x)` macro at `common.cuh:222` is already a no-op for `CUDART_VERSION < 11010`, so it stays untouched.

### Step 6 — bf16 stub headers (extended Option A)

The minimal b5050 stub (`typedef half nv_bfloat16;`) is no longer enough. b9006 references `nv_bfloat16` and `nv_bfloat162`, plus the intrinsics `__float2bfloat16`, `__bfloat162float`, `__bfloat1622float2`, `__low2bfloat16`, `__high2bfloat16`, `__float22bfloat162_rn` across 13+ translation units. Option B (commenting all bf16 references in source files) is impractical at this point.

The stubs at `../jetson-nano-b9006-patch/files/cuda_bf16.h` and `../jetson-nano-b9006-patch/files/cuda_bf16.hpp` typedef the types onto `__half` / `__half2` and forward the intrinsics to their `__half` equivalents. They are not a faithful bf16 implementation — kernels actually instantiated on `sm_50`/`sm_61` end up doing fp16 arithmetic. Code paths gated by `__CUDA_ARCH__ >= 800` (Ampere+) are not instantiated for the Jetson Nano targets and are therefore unaffected.

## On the Jetson

After `git pull` (run from the repo root), install the `bf16` stubs into the CUDA include tree:

```sh
sudo cp jetson-nano-b9006-patch/files/cuda_bf16.h   /usr/local/cuda/include/
sudo cp jetson-nano-b9006-patch/files/cuda_bf16.hpp /usr/local/cuda/include/
```

Then run step 7 from the b5050 procedure (this is the one step still left for the human):

```sh
cmake -B build -DGGML_CUDA=ON -DLLAMA_CURL=ON \
  -DCMAKE_CUDA_STANDARD=14 -DCMAKE_CUDA_STANDARD_REQUIRED=true \
  -DGGML_CPU_ARM_ARCH=armv8-a -DGGML_NATIVE=off
cmake --build build --config Release
```

## Known risk areas

Not pre-emptively patched because they should be inert for `sm_50` / `sm_61`, but these are the most likely to bite during compile:

- **`ggml/src/ggml-cuda/mma.cuh`** — class-template members initialized as `nv_bfloat162 x[ne] = {{0.0f, 0.0f}};`. Whether `__half2{0.0f, 0.0f}` brace-init compiles under nvcc 10.2 depends on the constructor set in that toolkit's `<cuda_fp16.h>`. The bf16 MMA tile is gated by `TURING_MMA_AVAILABLE` / `__CUDA_ARCH__ >= 800` and should not be instantiated for Maxwell / Pascal — but if a non-MMA template references the same `tile<I,J,nv_bfloat162,...>` specialization, those brace-inits become the failing lines.
- **`ggml/src/ggml-cuda/common.cuh:786`** — `__nv_cvt_e8m0_to_bf16raw` is gated by `#if CUDART_VERSION >= 12080`; CUDA 10.2 takes the fallback. Safe.
- **`static constexpr __device__` functions** (e.g. `ggml_cuda_get_physical_warp_size` at `common.cuh:339`) — valid C++14, should compile under the configure flags above.

If `cmake --build` fails, the diagnostic line is usually enough to decide whether to extend the bf16 stub, comment another `__builtin_assume`, or relax a `constexpr`.