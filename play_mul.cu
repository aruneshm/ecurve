#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <cuda.h>
#include <gmp.h>
#include <cassert>
#include "cgbn/cgbn.h"
#include "utility/support.h"

// #define TPI 32
#define TPI  32 

#define BITS 1024 

#define TPB 128    // the number of threads per block to launch (must be divisible by 32

typedef struct {
  cgbn_mem_t<BITS> x;
  cgbn_mem_t<BITS> y;
  cgbn_mem_t<BITS> m;
  cgbn_mem_t<BITS> mul_lo;
  cgbn_mem_t<BITS> mul_hi;
  cgbn_mem_t<BITS> r;
} my_instance_t;

typedef cgbn_context_t<TPI>         context_t;
typedef cgbn_env_t<context_t, BITS> env1024_t;
//typedef cgbn_env_t<context_t, 753> env753_t;

const uint64_t MNT4_INV = 0xf2044cfbe45e7fff;
const uint64_t MNT6_INV = 0xc90776e23fffffff;

__device__ 
void my_redc(uint32_t inv, uint32_t* lo, uint32_t* high, int num_limbs) {
  __shared__ uint32_t result[24];

  if (threadIdx.x > num_limbs) return;  // no use for those threads.
  int threadId = threadIdx.x % num_limbs;
}

__global__ void my_mont_mul_kernel(my_instance_t *problem_instances, uint32_t instance_count) {
  context_t         bn_context;                                 // create a CGBN context
  env1024_t         bn1024_env(bn_context);                     // construct a bn environment for 1024 bit math
  env1024_t::cgbn_t a, b, m;                      // three 1024-bit values (spread across a warp)
  env1024_t::cgbn_wide_t mul_wide;
  // uint32_t np0;
  
  int32_t my_instance=(blockIdx.x*blockDim.x + threadIdx.x)/TPI;  // determine my instance number
  
  if(my_instance>=instance_count) return;                         // return if my_instance is not valid
  
  cgbn_load(bn1024_env, a, &(problem_instances[my_instance]).x);
  cgbn_load(bn1024_env, b, &(problem_instances[my_instance]).y);
  cgbn_load(bn1024_env, m, &(problem_instances[my_instance]).m);

  // np0 = -cgbn_binary_inverse_ui32(bn1024_env, cgbn_get_ui32(bn1024_env, m));

  cgbn_mul_wide(bn1024_env, mul_wide, a, b);

  cgbn_store(bn1024_env, &(problem_instances[my_instance].mul_lo), mul_wide._low);
  cgbn_store(bn1024_env, &(problem_instances[my_instance].mul_hi), mul_wide._high);

}

__global__ void mont_mul_kernel(my_instance_t *problem_instances, uint32_t instance_count) {
  context_t         bn_context, bn_context1;                                 // create a CGBN context
  env1024_t         bn1024_env(bn_context);                     // construct a bn environment for 1024 bit math
  env1024_t::cgbn_t a, b, m, r;                      // three 1024-bit values (spread across a warp)
  uint32_t np0, np1;

  int32_t my_instance=(blockIdx.x*blockDim.x + threadIdx.x)/TPI;  // determine my instance number
  
  if(my_instance>=instance_count) return;                         // return if my_instance is not valid
  
  cgbn_load(bn1024_env, a, &(problem_instances[my_instance]).x);
  cgbn_load(bn1024_env, b, &(problem_instances[my_instance]).y);
  cgbn_load(bn1024_env, m, &(problem_instances[my_instance]).m);

  np1 = -cgbn_binary_inverse_ui32(bn1024_env, cgbn_get_ui32(bn1024_env, m));
  np0 = 0xe45e7fff;
  printf("\n %08X, computed: %08X\n", np0, np1);

  cgbn_mont_mul(bn1024_env, r, a, b, m, np0);
  cgbn_mont2bn(bn1024_env, r, r, m, np0);

  cgbn_store(bn1024_env, &(problem_instances[my_instance].r), r);
  //cgbn_store(bn1024_env, &(problem_instances[my_instance].mul_lo), mul_wide._low);
  //cgbn_store(bn1024_env, &(problem_instances[my_instance].mul_hi), mul_wide._high);
}

std::vector<uint8_t*>* compute_mont_mulcuda(std::vector<uint8_t*> a, std::vector<uint8_t*> b, uint8_t* input_m_base, int num_bytes) {
  int num_elements = a.size();

  my_instance_t *gpuInstances;
  my_instance_t* instance_array = (my_instance_t*) malloc(sizeof(my_instance_t) * num_elements);
  cgbn_error_report_t *report;

  // create a cgbn_error_report for CGBN to report back errors
  NEW_CUDA_CHECK(cgbn_error_report_alloc(&report));

  for (int i = 0; i < num_elements; i ++) {
    std::memcpy((void*)instance_array[i].x._limbs, (const void*) a[i], num_bytes);
    std::memcpy((void*)instance_array[i].y._limbs, (const void*) b[i], num_bytes);
    std::memcpy((void*)instance_array[i].m._limbs, (const void*) input_m_base, num_bytes);
  }

  NEW_CUDA_CHECK(cudaSetDevice(0));
  NEW_CUDA_CHECK(cudaMalloc((void **)&gpuInstances, sizeof(my_instance_t)*num_elements));
  NEW_CUDA_CHECK(cudaMemcpy(gpuInstances, instance_array, sizeof(my_instance_t)*num_elements, cudaMemcpyHostToDevice));
  
  int tpb = TPB;
  // printf("\n Threads per block =%d", tpb);
  int IPB = TPB/TPI;
  int tpi = TPI;
  // printf("\n Threads per instance = %d", tpi);
  // printf("\n Instances per block = %d", IPB);

  uint32_t num_blocks = (num_elements+IPB-1)/IPB;
  // printf("\n Number of blocks = %d", num_blocks);

  mont_mul_kernel<<<8192, TPB>>>(gpuInstances, num_elements);
  NEW_CUDA_CHECK(cudaDeviceSynchronize());
  CGBN_CHECK(report);

  // copy the instances back from gpuMemory
  NEW_CUDA_CHECK(cudaMemcpy(instance_array, gpuInstances, sizeof(my_instance_t)*num_elements, cudaMemcpyDeviceToHost));

  std::vector<uint8_t*>* res_vector = new std::vector<uint8_t*>();
  for (int i = 0; i < num_elements; i ++) {
     uint8_t* result = (uint8_t*) malloc(num_bytes * sizeof(uint8_t));
     std::memcpy((void*)result, (const void*)instance_array[i].r._limbs, num_bytes);
     res_vector->emplace_back(result);
  }

  free(instance_array);
  cudaFree(gpuInstances);
  return res_vector;
}
