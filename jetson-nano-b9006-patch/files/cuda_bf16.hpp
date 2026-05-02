#ifndef CUDA_BF16_HPP
#define CUDA_BF16_HPP

// Companion to the cuda_bf16.h stub. Mirrors the b5050 patch layout
// (which created both files at /usr/local/cuda/include/) and provides
// a tiny BFloat16 wrapper. Nothing in llama.cpp b9006 actually
// references cuda::BFloat16, but cuda_bf16.h in the official toolkit
// pulls in cuda_bf16.hpp, so we keep both files for parity.

#include "cuda_bf16.h"

namespace cuda {

    class BFloat16 {
    public:
        nv_bfloat16 value;

        __host__ __device__ BFloat16()              : value(0) {}
        __host__ __device__ BFloat16(float f)       { value = __float2half(f); }
        __host__ __device__ operator float() const  { return __half2float(value); }
    };

} // namespace cuda

#endif // CUDA_BF16_HPP