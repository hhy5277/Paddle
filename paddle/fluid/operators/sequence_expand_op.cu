/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#define EIGEN_USE_GPU
#include <stdio.h>
#include <algorithm>
#include "paddle/fluid/operators/sequence_expand_op.h"
#include "paddle/fluid/platform/cuda_helper.h"

namespace paddle {
namespace operators {

using LoDTensor = framework::LoDTensor;

template <typename T>
__global__ void sequence_expand_kernel(const T* x_data, const size_t* x_lod,
                                       const size_t* ref_lod,
                                       const size_t lod_size,
                                       /* default=1,
                                          the instance length*/
                                       const int x_item_length, T* out_data) {
  constexpr int N = 1024;
  __shared__ int mem[N];
  int offset = 0;
  for (int i = 0; i < lod_size; ++i) {
    mem[i] = offset;
    if (i < lod_size - 1) {
      offset += (ref_lod[i + 1] - ref_lod[i]) * (x_lod[i + 1] - x_lod[i]);
    }
  }
  __syncthreads();

  int bid = blockIdx.x;
  if (bid >= lod_size - 1) return;

  int x_item_count = x_lod[bid + 1] - x_lod[bid];
  int repeats = ref_lod[bid + 1] - ref_lod[bid];
  int out_offset = mem[bid];
  int x_offset = x_lod[bid];
  for (int tid_z = threadIdx.z; tid_z < repeats; tid_z += blockDim.z) {
    for (int tid_y = threadIdx.y; tid_y < x_item_count; tid_y += blockDim.y) {
      for (int tid_x = threadIdx.x; tid_x < x_item_length;
           tid_x += blockDim.x) {
        out_data[(out_offset + tid_z * x_item_count + tid_y) * x_item_length +
                 tid_x] = x_data[(x_offset + tid_y) * x_item_length + tid_x];
      }
    }
  }
}

template <typename T>
__global__ void sequence_expand_grad_kernel(const T* dout_data,
                                            const size_t* ref_lod,
                                            const size_t* dx_lod,
                                            const size_t lod_size,
                                            /* default=1,
                                               the instance length*/
                                            const int x_item_length,
                                            T* dx_data) {
  // TODO(dzhwinter) : too many atomicAdd
  // use shared memory to reduce memory visits
  constexpr int N = 1024;
  __shared__ int mem[N];
  int offset = 0;
  for (int i = 0; i < lod_size; ++i) {
    mem[i] = offset;
    if (i < lod_size - 1) {
      offset += (ref_lod[i + 1] - ref_lod[i]) * (dx_lod[i + 1] - dx_lod[i]);
    }
  }
  __syncthreads();

  int bid = blockIdx.x;
  if (bid >= lod_size - 1) return;
  int x_item_count = dx_lod[bid + 1] - dx_lod[bid];
  int repeats = ref_lod[bid + 1] - ref_lod[bid];
  int out_offset = mem[bid];
  int x_offset = dx_lod[bid];

  for (int tid_z = threadIdx.z; tid_z < repeats; tid_z += blockDim.z) {
    for (int tid_y = threadIdx.y; tid_y < x_item_count; tid_y += blockDim.y) {
      for (int tid_x = threadIdx.x; tid_x < x_item_length;
           tid_x += blockDim.x) {
        platform::CudaAtomicAdd(
            &dx_data[(x_offset + tid_y) * x_item_length + tid_x],
            dout_data[(out_offset + tid_z * x_item_count + tid_y) *
                          x_item_length +
                      tid_x]);
      }
    }
  }
}

template <typename T>
struct SequenceExpandFunctor<platform::CUDADeviceContext, T> {
  void operator()(
      const platform::CUDADeviceContext& context, const LoDTensor& x,
      const framework::Vector<size_t>& x_lod,   /*expand source lod*/
      const framework::Vector<size_t>& ref_lod, /*expand referenced lod*/
      LoDTensor* out) {
    int x_item_length = 1;
    x_item_length = x.numel() / x.dims()[0];
    VLOG(0) << "x_item_length" << x_item_length;
    int thread_x = std::max(static_cast<int>(ref_lod.size()), 32);
    int thread_y = std::max(1024 / thread_x, 16);
    int thread_z = std::min(1024 / thread_x / thread_y, 16);
    int block_x = static_cast<int>(ref_lod.size());
    dim3 block_size(thread_x, thread_y, thread_z);
    dim3 grid_size(block_x, 1);

    sequence_expand_kernel<<<grid_size, block_size, 0, context.stream()>>>(
        x.data<T>(), x_lod.CUDAData(context.GetPlace()),
        ref_lod.CUDAData(context.GetPlace()), x_lod.size(), x_item_length,
        out->mutable_data<T>(context.GetPlace()));
  }
};

template <typename T>
struct SequenceExpandGradFunctor<platform::CUDADeviceContext, T> {
  void operator()(const platform::CUDADeviceContext& context,
                  const LoDTensor& dout,
                  const framework::Vector<size_t>& x_lod, /*expand source lod*/
                  const framework::Vector<size_t>& ref_lod, /*expand based lod*/
                  LoDTensor* dx) {
    int x_item_length = 1;
    x_item_length = framework::product(dx->dims()) / dx->dims()[0];

    int thread_x = std::max(static_cast<int>(ref_lod.size()), 32);
    int thread_y = std::max(1024 / thread_x, 16);
    int thread_z = std::min(1024 / thread_x / thread_y, 16);
    int block_x = static_cast<int>(ref_lod.size());
    dim3 block_size(thread_x, thread_y, thread_z);
    dim3 grid_size(block_x, 1);
    sequence_expand_grad_kernel<<<grid_size, block_size, 0, context.stream()>>>(
        dout.data<T>(), ref_lod.CUDAData(context.GetPlace()),
        x_lod.CUDAData(context.GetPlace()), ref_lod.size(), x_item_length,
        dx->mutable_data<T>(context.GetPlace()));
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
REGISTER_OP_CUDA_KERNEL(
    sequence_expand,
    ops::SequenceExpandKernel<paddle::platform::CUDADeviceContext, float>,
    ops::SequenceExpandKernel<paddle::platform::CUDADeviceContext, double>,
    ops::SequenceExpandKernel<paddle::platform::CUDADeviceContext, int>,
    ops::SequenceExpandKernel<paddle::platform::CUDADeviceContext, int64_t>);
REGISTER_OP_CUDA_KERNEL(
    sequence_expand_grad,
    ops::SequenceExpandGradKernel<paddle::platform::CUDADeviceContext, float>,
    ops::SequenceExpandGradKernel<paddle::platform::CUDADeviceContext, double>,
    ops::SequenceExpandGradKernel<paddle::platform::CUDADeviceContext, int>,
    ops::SequenceExpandGradKernel<paddle::platform::CUDADeviceContext,
                                  int64_t>);
