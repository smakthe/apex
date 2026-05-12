#include <stddef.h>
#include <math.h>

void apex_aggregate_f64_fallback(
    const double * restrict data,
    size_t n,
    double *out_sum,
    double *out_min,
    double *out_max
) {
    double sum = 0.0;
    double min_val = INFINITY;
    double max_val = -INFINITY;

    for (size_t i = 0; i < n; i++) {
        sum += data[i];
        if (data[i] < min_val) min_val = data[i];
        if (data[i] > max_val) max_val = data[i];
    }

    *out_sum = sum;
    *out_min = min_val;
    *out_max = max_val;
}
