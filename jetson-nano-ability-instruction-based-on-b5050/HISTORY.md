# Build journey: llama.cpp b5050 → b9006 on Jetson Nano

Chronology of porting the [b5050 procedure](llama.cpp-jetson/README.md) to b9006 (commit `c5a3bc39b`) on a 2019 Jetson Nano Devkit (Tegra X1, sm_53, 4 GB unified memory, JetPack 4.6.x, CUDA 10.2, gcc 8.5). Branch: `jetson-nano-b9006`. Final result: `llama-cli -hf ggml-org/gemma-3-1b-it-GGUF --n-gpu-layers 99` runs at ~7 t/s.

The whole arc breaks down into five phases. Each phase ends with a build that gets a bit further than the previous one.

## Phase 0 — Setup (`c9bd434cf`, `06f4d5d42`)

Branch checked out from b9006 release. Task brief written into [`TASK.md`](TASK.md): apply b5050's steps 2–6 to b9006, leave step 7 (the actual `cmake -B build`) for the human.

## Phase 1 — Mechanical port of the b5050 patches (`97d68f2ba`)

Five concrete edits, mostly 1-to-1 with what the b5050 README said but adjusted to where things now live in b9006:

| b5050 step | What changed in b9006 | Concrete edit |
|---|---|---|
| 2. Limit `CMAKE_CUDA_ARCHITECTURES` | Same place, line 14 | `CMakeLists.txt`: add `if(NOT DEFINED ${CMAKE_CUDA_ARCHITECTURES}) set(... 50 61) endif()` |
| 3. Link `stdc++fs`, pass `--copy-dt-needed-entries` | `set_target_properties(ggml ... PUBLIC_HEADER)` moved from line 274 to **342** | `ggml/CMakeLists.txt`: insert two lines after the moved target_properties call |
| 4. Remove `constexpr` from `kvalues_iq4nl` | Declaration moved out of `common.cuh` into `ggml-common.h:1110` and **lost its `constexpr`** along the way | **Skipped** |
| 5. Comment `__builtin_assume(...)` | Three sites became two: `fattn-vec-f16.cuh` + `fattn-vec-f32.cuh` were merged into a single `fattn-vec.cuh` | Comment two `__builtin_assume(tid<…)` calls in `fattn-common.cuh:890` and `fattn-vec.cuh:111` |
| 6. bf16 stub | `nv_bfloat16` / `nv_bfloat162` now used in **13+ TUs** with intrinsics (`__float2bfloat16`, `__bfloat162float`, `__bfloat1622float2`, `__low2bfloat16`, `__high2bfloat16`, `__float22bfloat162_rn`). The b5050 minimal stub (`typedef half nv_bfloat16;`) is no longer enough | Extended Option A: typedef both types onto `__half`/`__half2`, forward all intrinsics to `__half` equivalents — at `jetson-nano-b9006-patch/files/cuda_bf16.{h,hpp}` |

Documentation iterated in: `e89706251`, `902a1b360`, `93d62dbc7`.

## Phase 2 — `cmake -B build` runs cleanly. `cmake --build` does not.

The C++17 surface that the b9006 CUDA backend has organically picked up (and that nvcc 10.2 explicitly does not support) needs to come out, layer by layer.

### Round 1 — bulk C++17 → C++14 backports (`3b79451f3`, doc `ef45fcaa6`)

`acc.cu.o` failed at parse time with `namespace "std" has no member "is_same_v"` and `expected an identifier` on structured bindings. Patches in three files:

- `common.cuh`: shim `std::is_same_v` as a C++14 variable template under `__cplusplus < 201703L` (covers all 30+ usages in the backend transitively); rewrite `is_any` without the C++17 fold expression `(... || ...)`; drop `inline` from two variable-template definitions.
- `common.cuh` and `ggml-cuda.cu`: 8 structured-binding range-for loops (`for (const auto & [a, b] : map)`) unfolded to explicit `__pair.first` / `__pair.second`.
- `softmax.cu`: the `(launch_kernel(...) || ...)` fold expression replaced with the C++14 initializer-list-expander idiom.
- `ggml-cuda.cu`: `if (const bool x = …; x)` C++17 if-init split into a separate statement (`6bd95b3aa`).

`if constexpr` is left in place across the backend — nvcc 10.2 accepts it as an extension and emits the `constexpr if statements are a C++17 feature` warning that the b5050 README documented as harmless.

### Round 2 — bf16 stub host/device qualifier (`7d021ba8b`, doc `c077c245b`)

Build now fails *inside our own* `cuda_bf16.h`:

```
cuda_bf16.h(29): error: calling a __device__ function("__low2half") from
    a __host__ __device__ function("__low2bfloat16") is not allowed
```

In CUDA 10.2's `<cuda_fp16.h>`, `__half2float` / `__float2half` are `__host__ __device__` but `__low2half` / `__high2half` / `__half22float2` / `__float22half2_rn` are `__device__`-only. Mirror those qualifiers on the bf16 wrappers.

### Round 2 — comma fold in binbcast.cu (`cccae9c44`)

`binbcast.cu:80` and `:146` used another C++17 fold expression flavour:
```cpp
result = (..., (result = bin_op(result, (float)src1s[…])));
```
Rewritten with the C++14 initializer-list-expander idiom (preserves left-to-right side-effect ordering on the parameter pack).

### Round 3 — three CUDA-11+ idioms in one file (`8ba442a7b`)

`ggml-cuda.cu` failed with three classes of errors:

1. **`static inline const` data members** in `batched_mul_mat_traits<*>` (C++17). For F32 / BF16 specs (enums and floats) → `static constexpr`. For the F16 spec the `half` ctor is not `constexpr` in CUDA 10.2, so the alpha/beta data members are dropped and the literals inlined into `get_alpha`/`get_beta`.
2. **`CUDA_R_16BF`** undefined (added in CUDA 11.0) → `#define CUDA_R_16BF ((cudaDataType_t) 14)` in `cuda_bf16.h`. cuBLAS 10.2 will reject the value at runtime, but the BF16 cuBLAS branch is not exercised on sm_50/sm_61 in practice.
3. **`cudaStreamWaitEvent(stream, event)`** — CUDA 10.2 needs the explicit `flags` argument; added `, 0` to the two new fork/join call sites.

### Round 5–7 — cooperative_groups (`190d8e439`, `52fd44276`, `0136b810d`)

Three iterations on the same file (`softmax.cu`):

1. **`cooperative_groups/reduce.h: No such file or directory`** — `<cooperative_groups/reduce.h>` was added in CUDA 11.0; nvcc 10.2 doesn't ship it. The reduce helpers (`cg::reduce`, `cg::plus`, …) aren't actually used here, so wrap the include in `#if CUDART_VERSION >= 11000`.
2. **`namespace "cooperative_groups" has no member "grid_group" / "this_grid"`** for the sm_50 device pass — CUDA 10.2's cooperative_groups.h gates `grid_group`/`this_grid()` behind `__CUDA_ARCH__ >= 600`. First attempt: wrap the cg-using kernel body in `#if __CUDA_ARCH__ < 600` with a `NO_DEVICE_CODE` stub.
3. **`ptxas fatal: Unresolved extern function 'cudaCGGetIntrinsicHandle'`** for the sm_61 device pass — cooperative-groups device-runtime symbol that requires `--relocatable-device-code=true` plus linking `cudadevrt`. Switch the guard from `__CUDA_ARCH__ < 600` to `CUDART_VERSION < 11000` so the entire CUDA-10.2 build (both archs) takes the stub path. Host launch is runtime-gated by `supports_cooperative_launch` (false on Jetson Nano), so functionality is preserved.

### Round 9 — mmf bf16 explicit-instantiation duplicates (`3fb6459ba`)

`template-instances/mmf-instance-ncols_*.cu` failed with:

```
function "mul_mat_f_cuda<T, rows_per_block, cols_per_block>(...)" 
    [with T=half2, rows_per_block=32, cols_per_block=1] 
    explicitly instantiated more than once
```

Same root cause as `mma.cuh` (dealt with in `dd9b79cc7`): under our `nv_bfloat162 == __half2` typedef, the bf16 explicit instantiations literally duplicate the half2 ones. Fix in `mmf.cuh`: define `DECL_MMF_CASE_BF16_HELPER` / `DECL_MMF_CASE_BF16_EXTERN_HELPER` macros that expand to the original instantiation under non-stubbed builds and to a no-op under `GGML_CUDA_BF16_IS_HALF2`. All 16 `mmf-instance-ncols_*.cu` files automatically skip the bf16 lines.

### Round 2.5 — also for mma.cuh (`dd9b79cc7`)

Class-template specializations `tile<*,nv_bfloat162,*>` and `mma()` overloads taking `nv_bfloat162` collide with their `half2` counterparts under the typedef. Add a sentinel `GGML_CUDA_BF16_IS_HALF2` to `cuda_bf16.h`, wrap the four bf16 sites in `mma.cuh` with `#ifndef GGML_CUDA_BF16_IS_HALF2`. Callers of `tile<*,*,nv_bfloat162,*>` resolve to the `half2` specialization through the typedef; behaviour on sm_50/sm_61 is identical (those code paths went through `half2` regardless).

### Cosmetic — cudafe warnings (`1fdaf28c7`, rolled back `557ff5c82`, then `b6bccb3bd`)

A `--diag_suppress=20012` flag was tried to silence the high-volume `host variable "ggml_cuda_dependent_false_v" cannot be directly read in a device function` warning, but nvcc 10.2 doesn't recognize `--diag_suppress=20012` and itself errors on it. Rolled back.

## Phase 3 — `libggml-cuda.so` links! Then the rest of the project compiles.

After `3fb6459ba` the CUDA backend successfully linked into `libggml-cuda.so`. The CPU backend (`ggml-cpu`), the unified `ggml` shared library, the `llama` library, `common`, `tools`, and `examples` all built without further patches — they're plain C++17 host code, and g++ 8.5 handles C++17 natively.

The only blip in Phase 3 was a `-Waggressive-loop-optimizations` warning in `ggml/src/ggml-cpu/simd-gemm.h:79` (gcc heuristic about a giant iteration count, not an actual bug). Since `LLAMA_FATAL_WARNINGS` is OFF by default, it didn't escalate.

## Phase 4 — Runtime: HTTPS doesn't work

Build done, `llama-cli -hf` fails immediately with:

```
HTTPS is not supported. Please rebuild with one of:
  -DLLAMA_BUILD_BORINGSSL=ON
  -DLLAMA_BUILD_LIBRESSL=ON
  -DLLAMA_OPENSSL=ON (default, requires OpenSSL dev files installed)
```

Root cause: `vendor/cpp-httplib/CMakeLists.txt:132` requires **OpenSSL ≥ 3.0.0** (or LibreSSL/BoringSSL ≥ 1.1.1g). Ubuntu 18.04 ships OpenSSL 1.1.1, which fails the version check and disables the HTTPS path. Upgrading the system OpenSSL on 18.04 is out of scope.

Reconfigured with `-DLLAMA_BUILD_LIBRESSL=ON`. CMake fetches and builds LibreSSL itself; ~30 min on the Jetson. After that:

```
get_repo_commit: error: HTTPLIB failed: SSL server verification failed
```

Progress! The TLS stack is now linked. The handshake gets started. Verification fails because the freshly-built LibreSSL doesn't know where the system CA bundle is — its compiled-in `OPENSSLDIR` points to a path that doesn't exist on the Jetson, and `SSL_CERT_FILE` / `SSL_CERT_DIR` env vars don't help (cpp-httplib relies on `SSL_CTX_set_default_verify_paths()`, which doesn't reliably honour them in this configuration).

### Final fix — explicit CA bundle loading (`a65ad6999`)

Patched `common/http.h::common_http_client()` to, for HTTPS scheme:

1. Check `SSL_CERT_FILE` env var, use it if set & exists.
2. Otherwise probe a list of standard locations: `/etc/ssl/certs/ca-certificates.crt` (Debian/Ubuntu), `/etc/pki/tls/certs/ca-bundle.crt` (RHEL/Fedora), `/etc/ssl/cert.pem` (BSD-style).
3. Pass the first existing one to `cli.set_ca_cert_path(...)` — explicit instead of relying on default verify paths.

Wrapped in `#ifdef CPPHTTPLIB_OPENSSL_SUPPORT`, so it's a no-op when llama.cpp is built without TLS.

## Phase 5 — Runtime BF16 cuBLAS path (`1fe748ab6`)

Spotted later when running a multimodal model (`unsloth/Qwen3.5-0.8B-GGUF:Q8_0`) with a BF16 vision projector (`mmproj-BF16.gguf` is the multimodal projector and it ships in BF16). Text generation worked fine, but on `/image` followed by a question:

```
CUDA error: CUBLAS_STATUS_NOT_SUPPORTED
  in function ggml_cuda_op_mul_mat_cublas at ggml-cuda.cu:1531
  cublasGemmEx(... ((cudaDataType_t) 14), ...
               CUBLAS_COMPUTE_32F, CUBLAS_GEMM_DEFAULT_TENSOR_OP)
```

The Round-3 fix (`#define CUDA_R_16BF ((cudaDataType_t) 14)` in `cuda_bf16.h`) made the source *compile*, but `cublasGemmEx` in CUDA 10.2 was released before `CUDA_R_16BF` existed and rejects the value at runtime. The note from Round 3 ("BF16 cuBLAS branch is not exercised on sm_50/sm_61 in practice") held until a multimodal model was actually loaded.

Fix: `ggml-cuda.cu` — gate `supports_bf16` on `CUDART_VERSION >= 11000`. On CUDA 10.2 the runtime check now reports false, the `if (supports_bf16 && src0->type == GGML_TYPE_BF16 …)` branch is skipped, and BF16 src0 falls through to the fp32 path (`ggml_get_to_fp32_cuda(GGML_TYPE_BF16)` → `convert_unary_cont_cuda<nv_bfloat16>` → which under our `GGML_CUDA_BF16_IS_HALF2` typedef is just half→float, then `cublasSgemm`). Slower than dedicated BF16 tensor cores, but correct, and Tegra X1 doesn't have BF16 tensor cores anyway. The companion `use_batched_cublas_bf16` path is already gated by `bf16_mma_hardware_available(cc)` which requires Ampere — never true on Tegra X1 (CC 5.3) — so it needs no patch.

## Result

```
$ ./llama-cli -hf ggml-org/gemma-3-1b-it-GGUF:Q4_K_M --n-gpu-layers 99
ggml_cuda_init: found 1 CUDA devices (Total VRAM: 3963 MiB):
  Device 0: NVIDIA Tegra X1, compute capability 5.3, VMM: no, VRAM: 3963 MiB
Downloading gemma-3-1b-it-Q4_K_M.gguf ──────────────────────────── 100%

build      : b9041-a65ad6999
model      : ggml-org/gemma-3-1b-it-GGUF
modalities : text
…
[ Prompt: 11.1 t/s | Generation: 7.4 t/s ]
```

CUDA acceleration on, model loaded into VRAM via the unified-memory pool, generation at expected speed for the device.

## Helper / tooling commits (out of band)

- `8626c3f35`, `e1083b8bc`, `2e8ed5925`, `0cc455dc2` — `jetson-nano-b9006-patch/scripts/build_with_log.sh`. Wrapper around `cmake --build` that tees stdout+stderr to a log file, preserves cmake's exit code (not tee's), and forwards extra args after `--` (e.g. `-j2`) to cmake.
- Compile logs landed at `compile_logs/failed_logs_round_*.txt` along the way.

## Files modified end-to-end

In source tree:

- `CMakeLists.txt` — limit `CMAKE_CUDA_ARCHITECTURES`.
- `ggml/CMakeLists.txt` — link `stdc++fs`, pass `--copy-dt-needed-entries`.
- `ggml/src/ggml-cuda/common.cuh` — `is_same_v` shim, `is_any` rewrite, drop `inline`, structured bindings unfolded.
- `ggml/src/ggml-cuda/fattn-common.cuh` — comment `__builtin_assume`.
- `ggml/src/ggml-cuda/fattn-vec.cuh` — comment `__builtin_assume`.
- `ggml/src/ggml-cuda/mma.cuh` — guard four bf16 sites with `GGML_CUDA_BF16_IS_HALF2`.
- `ggml/src/ggml-cuda/mmf.cuh` — bf16 instantiation helpers.
- `ggml/src/ggml-cuda/binbcast.cu` — comma-fold rewrite.
- `ggml/src/ggml-cuda/softmax.cu` — `cooperative_groups/reduce.h` guard, cg-body stub.
- `ggml/src/ggml-cuda/ggml-cuda.cu` — structured bindings, if-init, inline-static traits, `cudaStreamWaitEvent` arity.
- `common/http.h` — explicit CA bundle loading.

Out-of-tree, on the Jetson:

- `/usr/local/cuda/include/cuda_bf16.h` ← `jetson-nano-b9006-patch/files/cuda_bf16.h`
- `/usr/local/cuda/include/cuda_bf16.hpp` ← `jetson-nano-b9006-patch/files/cuda_bf16.hpp`