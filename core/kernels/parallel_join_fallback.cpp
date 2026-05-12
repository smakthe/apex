#include <cstdint>
#include <unordered_map>
#include <vector>

struct JoinTuple {
    int64_t key;
    int64_t payload;
};

extern "C" void apex_hash_join_fallback(
    const JoinTuple* probe_input,
    size_t probe_sz,
    const JoinTuple* build_input,
    size_t build_sz,
    JoinTuple* output,
    uint32_t* output_count
) {
    std::unordered_map<int64_t, int64_t> ht;
    ht.reserve(build_sz);
    for (size_t i = 0; i < build_sz; ++i) {
        ht[build_input[i].key] = build_input[i].payload;
    }

    uint32_t count = 0;
    for (size_t i = 0; i < probe_sz; ++i) {
        auto it = ht.find(probe_input[i].key);
        if (it != ht.end()) {
            output[count].key = probe_input[i].key;
            output[count].payload = probe_input[i].payload ^ it->second;
            count++;
        }
    }
    *output_count = count;
}
