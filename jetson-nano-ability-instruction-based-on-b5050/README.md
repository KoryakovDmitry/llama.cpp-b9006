# Jetson Nano build for llama.cpp b9006

Adaptation of the b5050 Jetson Nano procedure (original at [`llama.cpp-jetson/README.md`](llama.cpp-jetson/README.md)) to release **b9006** (commit `c5a3bc39b`). Branch: `jetson-nano-b9006`.

## Where to start

| If you want to… | Read |
|---|---|
| **Build it on a fresh Jetson Nano right now** | [`INSTALL.md`](INSTALL.md) — 5-step runbook (prereqs → clone → bf16 stubs → cmake → run) |
| Understand *why* each patch exists, with commit hashes and the actual error messages we hit | [`HISTORY.md`](HISTORY.md) — chronology in 5 phases |
| See the original task brief | [`TASK.md`](TASK.md) |
| Read the original (now-superseded) b5050 procedure | [`llama.cpp-jetson/README.md`](llama.cpp-jetson/README.md) |

The rest of *this* file is a per-step rationale of the patches: useful as a code-review companion, redundant if you just want to build.

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

### Beyond the b5050 procedure — issues found during the first `cmake --build`

#### C++17 → C++14 backports

nvcc 10.2 caps the CUDA dialect at C++14. b9006's CUDA back-end has picked up several C++17 idioms that b5050 didn't have, and `cmake --build` failed on the first run with errors like `namespace "std" has no member "is_same_v"` and `expected an identifier` on structured bindings. Patches applied:

- **`ggml/src/ggml-cuda/common.cuh`**
  - `std::is_same_v` shim defined as a C++14 variable template under `#if __cplusplus < 201703L`. Every CUDA TU includes `common.cuh`, so this single shim covers every `std::is_same_v` usage in the back-end without per-file edits.
  - `is_any` rewritten without the C++17 fold expression `(... || ...)`, using a recursive `constexpr` helper.
  - `inline` dropped from two variable-template definitions (`inline` on variables/variable-templates is C++17; `constexpr` alone is fine in C++14).
  - 4 structured-binding range-for loops (`for (const auto & [a, b] : map)`) unfolded to explicit `__pair.first` / `__pair.second`.
- **`ggml/src/ggml-cuda/ggml-cuda.cu`** — 4 more structured-binding range-for loops unfolded the same way.
- **`ggml/src/ggml-cuda/softmax.cu`** — the `(launch_kernel(std::integral_constant<int, Ns>{}) || ...)` fold expression replaced with the C++14 initializer-list-expander idiom. Short-circuit semantics are preserved by accumulating into a `bool` instead of OR-ing eagerly.

`if constexpr` is left in place across the back-end — nvcc 10.2 accepts it as an extension and just emits the `constexpr if statements are a C++17 feature` warning that the b5050 README already documented as harmless.

#### bf16 stub: host/device qualifiers had to match `<cuda_fp16.h>`

The next `cmake --build` failed inside our own `cuda_bf16.h` stub with:

```
/usr/local/cuda/include/cuda_bf16.h(29): error: calling a __device__ function("__low2half") from
    a __host__ __device__ function("__low2bfloat16") is not allowed
/usr/local/cuda/include/cuda_bf16.h(30): error: calling a __device__ function("__high2half") from
    a __host__ __device__ function("__high2bfloat16") is not allowed
```

Cause: the initial stub declared every wrapper `__host__ __device__`, but several of the underlying `__half` intrinsics in CUDA 10.2's `<cuda_fp16.h>` are `__device__`-only. nvcc parses the wrapper body in both passes and the host pass cannot resolve the device-only callee.

Fix: narrow the wrapper qualifiers to mirror the underlying intrinsics:

- `__bfloat162float`, `__float2bfloat16` stay `__host__ __device__` (their backing `__half2float` / `__float2half` are HD).
- `__bfloat1622float2`, `__float22bfloat162_rn`, `__low2bfloat16`, `__high2bfloat16` become `__device__`-only (their backing `__half22float2` / `__float22half2_rn` / `__low2half` / `__high2half` are device-only).

The device-only wrappers are still safe at runtime because their call sites in `ggml/src/ggml-cuda/convert.cuh` are gated by `GGML_USE_HIP` or `__CUDA_ARCH__ >= 800`, neither of which fires on `sm_50`/`sm_61`. The definitions only need to *parse*.

After pulling, re-copy the updated header on the Jetson:

```sh
sudo cp jetson-nano-b9006-patch/files/cuda_bf16.h /usr/local/cuda/include/
```

(The `.hpp` companion is unchanged.)

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

To use all four cores during the build, append `-j$(nproc)`. Expect roughly 60–85 minutes on an SD-card-backed Jetson Nano (faster on USB SSD); watch RAM — at 4 GB the Nano will swap heavily under `-j4`.

#### Capture the build log to a file

When iterating on compile errors it is convenient to keep both the live terminal output *and* a saved log (especially since errors and warnings are easy to lose in a long stream). The repo ships a tiny helper script that does both:

```sh
# default log: jetson-nano-ability-instruction-based-on-b5050/compile_logs/build_log.txt
./jetson-nano-b9006-patch/build_with_log.sh

# only override the filename (default dir is preserved)
./jetson-nano-b9006-patch/build_with_log.sh -f failed_logs_round_4.txt

# override directory and filename separately
./jetson-nano-b9006-patch/build_with_log.sh -d logs -f round5.txt

# full path override
./jetson-nano-b9006-patch/build_with_log.sh -o some/where/full.log

# backwards-compatible positional form (treated as --output)
./jetson-nano-b9006-patch/build_with_log.sh jetson-nano-ability-instruction-based-on-b5050/failed_logs_round_4.txt

# print usage
./jetson-nano-b9006-patch/build_with_log.sh --help
```

Flags:

- `-o, --output PATH` — full log path, overrides `-d`/`-f`.
- `-d, --dir DIR` — directory to write the log into.
- `-f, --file NAME` — filename (combined with `-d` or the default dir).

Default directory is `jetson-nano-ability-instruction-based-on-b5050/compile_logs` and default filename is `build_log.txt`. The script uses `set -o pipefail` so the exit code from `cmake` is preserved through the `tee` pipe (otherwise `tee` always succeeds and the build "looks fine" even when it failed).

Equivalent one-liner if you'd rather not use the script:

```sh
set -o pipefail
cmake --build build --config Release 2>&1 | tee jetson-nano-ability-instruction-based-on-b5050/compile_logs/build_log.txt
```

### Configure output — what's normal

A successful configure run on the Jetson should report, among other lines:

- `Using CMAKE_CUDA_ARCHITECTURES=50;61` (proves the step 2 patch took effect; the `CMAKE_CUDA_ARCHITECTURES_NATIVE=53-real` line is detection of the Tegra X1 itself and is informational)
- `CUDAToolkit ... 10.2.300` and `CUDA host compiler is GNU 8.5.0`
- `ggml commit: <short SHA>` matching the tip of `jetson-nano-b9006` you've pulled

Three warnings are expected and **not blockers**:

- `LLAMA_CURL is deprecated and will be ignored` — the flag was renamed/folded between b5050 and b9006. cURL support is now selected via a different mechanism. The b5050 README's `-DLLAMA_CURL=ON` is now redundant; you can drop it on future configures.
- `Could NOT find NCCL ...` — multi-GPU collective comms library; the Jetson is single-GPU, so it is irrelevant.
- `Performing Test OPENSSL_VERSION_SUPPORTED - Failed` — the OpenSSL on Ubuntu 18.04 (1.1.1) doesn't pass a min-version check, so HTTPS in the embedded server may be disabled. `llama-cli -hf ...` uses libcurl's own TLS rather than this OpenSSL path, so model downloads still work.

## Known risk areas

Not pre-emptively patched because they should be inert for `sm_50` / `sm_61`, but these are the most likely to bite as the build progresses:

- **`ggml/src/ggml-cuda/mma.cuh`** — class-template members initialized as `nv_bfloat162 x[ne] = {{0.0f, 0.0f}};`. Whether `__half2{0.0f, 0.0f}` brace-init compiles under nvcc 10.2 depends on the constructor set in that toolkit's `<cuda_fp16.h>`. The bf16 MMA tile is gated by `TURING_MMA_AVAILABLE` / `__CUDA_ARCH__ >= 800` and should not be instantiated for Maxwell / Pascal — but if a non-MMA template references the same `tile<I,J,nv_bfloat162,...>` specialization, those brace-inits become the failing lines.
- **More C++17 idioms in untouched TUs** — the shim covers `std::is_same_v` everywhere, but a `_t` alias, another fold expression, or another structured binding hiding in a less-frequently-built file would still surface as a fresh `cmake --build` error. The fix pattern is the same as the backports above.
- **`ggml/src/ggml-cuda/common.cuh:786`** — `__nv_cvt_e8m0_to_bf16raw` is gated by `#if CUDART_VERSION >= 12080`; CUDA 10.2 takes the fallback. Safe.

If `cmake --build` fails, the first diagnostic line is usually enough to decide whether to extend the bf16 stub, add another C++17 backport, or comment another `__builtin_assume`.