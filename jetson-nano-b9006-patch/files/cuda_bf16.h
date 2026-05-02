#ifndef CUDA_BF16_H
#define CUDA_BF16_H

// Stub <cuda_bf16.h> for nvcc 10.2 on the Jetson Nano (compute 5.3, sm_53).
// nvcc 10.2 does not ship cuda_bf16.h. b9006 of llama.cpp uses nv_bfloat16,
// nv_bfloat162 and a handful of bf16 intrinsics in 13+ TUs. Mapping the
// types onto __half / __half2 lets the type-system / templates compile;
// the conversion intrinsics are forwarded to their __half equivalents.
//
// Note: this is *not* a faithful bf16 implementation. Numerical results
// for code paths that are actually instantiated on sm_50/sm_61 are produced
// in fp16 precision. Code paths gated by __CUDA_ARCH__ >= 800 (Ampere+)
// are not instantiated for the Jetson Nano targets and so are unaffected.

#include <cuda_fp16.h>

typedef __half  nv_bfloat16;
typedef __half2 nv_bfloat162;

// Scalar conversions
__host__ __device__ __forceinline__ float       __bfloat162float(nv_bfloat16 x) { return __half2float(x); }
__host__ __device__ __forceinline__ nv_bfloat16 __float2bfloat16(float x)        { return __float2half(x); }

// half2-style packed conversions
__host__ __device__ __forceinline__ float2       __bfloat1622float2(nv_bfloat162 x) { return __half22float2(x); }
__host__ __device__ __forceinline__ nv_bfloat162 __float22bfloat162_rn(float2 x)    { return __float22half2_rn(x); }

// Lane extractors (low / high)
__host__ __device__ __forceinline__ nv_bfloat16 __low2bfloat16 (nv_bfloat162 x) { return __low2half(x); }
__host__ __device__ __forceinline__ nv_bfloat16 __high2bfloat16(nv_bfloat162 x) { return __high2half(x); }

#endif // CUDA_BF16_H