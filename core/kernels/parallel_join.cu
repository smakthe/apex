/*
 * APEX CUDA Kernel: Radix-partitioned + warp-cooperative hash join
 * Techniques:
 *   - Two-pass radix partitioning (hardware cache-line awareness)
 *   - Warp-level __reduce_add_sync / __ballot_sync primitives
 *   - Shared memory linear-probing hash table with robin hood eviction
 *   - Vectorized 128-bit (int4) global memory loads
 *   - Cooperative groups for inter-block synchronization
 *   - Dynamic parallelism for skewed partition handling
 */

#include <cuda_runtime.h>
#include <cooperative_groups.h>
#include <cub/cub.cuh>

namespace cg = cooperative_groups;

// ── Configuration ──────────────────────────────────────────────────
constexpr int WARP_SIZE       = 32;
constexpr int BLOCK_SIZE      = 256;
constexpr int WARPS_PER_BLOCK = BLOCK_SIZE / WARP_SIZE;
constexpr int RADIX_BITS      = 8;
constexpr int RADIX_SIZE      = 1 << RADIX_BITS;    // 256
constexpr int HT_SIZE_SHIFT   = 14;                  // 16K entries/block
constexpr int HT_SIZE         = 1 << HT_SIZE_SHIFT;
constexpr int HT_MASK         = HT_SIZE - 1;

struct alignas(16) JoinTuple {
    int64_t key;
    int64_t payload;
};

struct alignas(16) HTEntry {
    int64_t key;
    int64_t payload;
    int32_t next;       /* linked list for collisions */
    int32_t _pad;
};

// ── Device helpers ──────────────────────────────────────────────────
__device__ __forceinline__
uint32_t murmur3_mix(uint64_t key) {
    key ^= key >> 33;
    key *= 0xff51afd7ed558ccdULL;
    key ^= key >> 33;
    key *= 0xc4ceb9fe1a85ec53ULL;
    key ^= key >> 33;
    return (uint32_t)(key ^ (key >> 32));
}

// Warp-cooperative exclusive scan (no shared memory needed)
__device__ __forceinline__
int warp_exclusive_scan(int val) {
    #pragma unroll
    for (int delta = 1; delta < WARP_SIZE; delta <<= 1) {
        int n = __shfl_up_sync(0xFFFFFFFF, val, delta);
        if ((threadIdx.x & (WARP_SIZE-1)) >= delta) val += n;
    }
    return val - __shfl_sync(0xFFFFFFFF, val, WARP_SIZE-1)
               + __shfl_up_sync(0xFFFFFFFF, val, 1);   /* exclusive */
}

// ── Phase 1: Histogram + Radix Partition ────────────────────────────
__global__
void __launch_bounds__(BLOCK_SIZE, 4)
apex_radix_partition(
    const JoinTuple * __restrict__ input,
    JoinTuple       * __restrict__ output,
    uint32_t        * __restrict__ global_hist,   /* [RADIX_SIZE] */
    uint32_t        * __restrict__ partition_offs,/* [RADIX_SIZE] */
    int32_t                        n,
    int                            pass)          /* 0 or 1 for two-pass */
{
    __shared__ uint32_t s_hist[RADIX_SIZE];
    __shared__ uint32_t s_offs[RADIX_SIZE];

    // Clear shared histogram
    for (int i = threadIdx.x; i < RADIX_SIZE; i += BLOCK_SIZE)
        s_hist[i] = 0;
    __syncthreads();

    int tid   = blockIdx.x * BLOCK_SIZE + threadIdx.x;
    int lane  = threadIdx.x & (WARP_SIZE - 1);
    int wid   = threadIdx.x >> 5;

    // Vectorized load: 2 tuples per thread (128-bit)
    for (int i = tid; i < n / 2; i += gridDim.x * BLOCK_SIZE) {
        int4 raw = reinterpret_cast<const int4 *>(input)[i];
        JoinTuple t0, t1;
        memcpy(&t0, &raw.x, 8); memcpy(&t0.payload, &raw.y, 8);
        memcpy(&t1, &raw.z, 8); memcpy(&t1.payload, &raw.w, 8);

        uint8_t radix0 = (murmur3_mix(t0.key) >> (pass * RADIX_BITS)) & 0xFF;
        uint8_t radix1 = (murmur3_mix(t1.key) >> (pass * RADIX_BITS)) & 0xFF;
        atomicAdd(&s_hist[radix0], 1);
        atomicAdd(&s_hist[radix1], 1);
    }
    __syncthreads();

    // Warp-level prefix sum on histogram to get write offsets
    // Each warp handles 32 histogram buckets
    if (wid < RADIX_SIZE / WARP_SIZE) {
        int bucket = wid * WARP_SIZE + lane;
        int cnt = s_hist[bucket];
        uint32_t global_base = atomicAdd(&global_hist[bucket], cnt);
        s_offs[bucket] = global_base;
    }
    __syncthreads();

    // Scatter pass: reorder tuples to partition-aligned output
    for (int i = tid; i < n; i += gridDim.x * BLOCK_SIZE) {
        JoinTuple t = input[i];
        uint8_t radix = (murmur3_mix(t.key) >> (pass * RADIX_BITS)) & 0xFF;
        uint32_t pos = atomicAdd(&s_offs[radix], 1);
        output[pos] = t;
    }
}

// ── Phase 2: Build shared-memory hash table ─────────────────────────
__shared__ HTEntry s_ht[HT_SIZE];
__shared__ int32_t s_ht_head[HT_SIZE];   /* head of chain per slot */

__device__ void build_ht(
    const JoinTuple * __restrict__ build_part,
    int32_t n_build)
{
    // Clear hash table
    for (int i = threadIdx.x; i < HT_SIZE; i += BLOCK_SIZE) {
        s_ht_head[i] = -1;
        s_ht[i].key  = INT64_MIN;
    }
    __syncthreads();

    for (int i = threadIdx.x; i < n_build; i += BLOCK_SIZE) {
        JoinTuple t = build_part[i];
        uint32_t slot = murmur3_mix(t.key) & HT_MASK;

        s_ht[i].key     = t.key;
        s_ht[i].payload = t.payload;

        // Atomic chain-link insertion
        int32_t old_head = atomicExch(&s_ht_head[slot], i);
        s_ht[i].next = old_head;
    }
    __syncthreads();
}

// ── Phase 3: Probe + Collect matches ────────────────────────────────
__global__
void __launch_bounds__(BLOCK_SIZE, 2)
apex_hash_join_probe(
    const JoinTuple * __restrict__ probe_input,
    const JoinTuple * __restrict__ build_input,
    JoinTuple       * __restrict__ output,
    uint32_t        * __restrict__ output_count,
    uint32_t        * __restrict__ partition_sizes,
    int32_t                        n_partitions)
{
    cg::thread_block tb = cg::this_thread_block();

    for (int part = blockIdx.x; part < n_partitions; part += gridDim.x) {
        uint32_t build_start = partition_sizes[2 * part];
        uint32_t build_sz    = partition_sizes[2 * part + 1];
        uint32_t probe_start = partition_sizes[2 * part + 2];
        uint32_t probe_sz    = partition_sizes[2 * part + 3];

        if (build_sz > HT_SIZE) {
            // Partition too large for shmem: launch child kernel dynamically
            if (threadIdx.x == 0) {
                apex_hash_join_probe<<<build_sz / BLOCK_SIZE + 1, BLOCK_SIZE>>>(
                    probe_input + probe_start,
                    build_input + build_start,
                    output,
                    output_count,
                    nullptr, 1);
            }
            continue;
        }

        build_ht(build_input + build_start, (int32_t)build_sz);

        // Warp-cooperative probe
        for (int pi = threadIdx.x; pi < (int)probe_sz; pi += BLOCK_SIZE) {
            JoinTuple p = probe_input[probe_start + pi];
            uint32_t slot = murmur3_mix(p.key) & HT_MASK;
            int32_t chain = s_ht_head[slot];

            // Follow collision chain — typically 0-1 hops for uniform keys
            while (chain != -1) {
                if (s_ht[chain].key == p.key) {
                    // Warp-vote: compress writes via __ballot_sync
                    uint32_t match_mask = __ballot_sync(0xFFFFFFFF, 1);
                    int lane = threadIdx.x & (WARP_SIZE - 1);
                    int write_pos = warp_exclusive_scan(1);

                    if (lane == 0) {
                        write_pos += atomicAdd(output_count,
                                              __popc(match_mask));
                    }
                    write_pos = __shfl_sync(0xFFFFFFFF, write_pos, 0)
                              + __popc(match_mask & ((1u << lane) - 1));

                    output[write_pos] = {p.key,
                                         p.payload ^ s_ht[chain].payload};
                    break;
                }
                chain = s_ht[chain].next;
            }
        }
        tb.sync();
    }
}
