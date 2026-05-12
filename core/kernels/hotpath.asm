; APEX Hot Path: AVX-512 vectorized SUM/MIN/MAX aggregation
; ABI: System V AMD64. Arguments: rdi=ptr, rsi=len (elements), rdx=out
; Requires: AVX-512F + AVX-512BW + AVX-512DQ + BMI2

section .text
global apex_aggregate_f64_avx512

; void apex_aggregate_f64_avx512(
;     const double * __restrict__ data,   ; rdi
;     size_t                      n,      ; rsi
;     double                     *out_sum,; rdx
;     double                     *out_min,; rcx
;     double                     *out_max ; r8
; )

apex_aggregate_f64_avx512:
    push        rbp
    mov         rbp, rsp
    and         rsp, -64                  ; align to 64-byte (zmm boundary)

    ; Initialize accumulators — 8 zmm registers in parallel (unrolled ×4)
    vpxorq      zmm0,  zmm0,  zmm0       ; sum[0..7]
    vpxorq      zmm1,  zmm1,  zmm1       ; sum[8..15]
    vpxorq      zmm2,  zmm2,  zmm2       ; sum[16..23]
    vpxorq      zmm3,  zmm3,  zmm3       ; sum[24..31]

    ; Broadcast +∞ / -∞ for min / max init
    mov         rax,   0x7FF0000000000000 ; +inf
    vpbroadcastq zmm16, rax
    mov         rax,   0xFFF0000000000000 ; -inf
    vpbroadcastq zmm20, rax
    vmovapd     zmm17, zmm16              ; min accumulators ×4
    vmovapd     zmm18, zmm16
    vmovapd     zmm19, zmm16
    vmovapd     zmm21, zmm20
    vmovapd     zmm22, zmm20
    vmovapd     zmm23, zmm20

    ; Pre-divide by 32 (elements per iteration)
    mov         r10,  rsi
    shr         r10,  5                  ; r10 = n / 32
    and         rsi,  31                 ; rsi = tail count

.loop:
    test        r10,  r10
    jz          .tail

    ; 4× non-temporal prefetch (4 cache-lines ahead)
    prefetchnta [rdi + 256]
    prefetchnta [rdi + 320]
    prefetchnta [rdi + 384]
    prefetchnta [rdi + 448]

    ; Load 4 zmm registers (32 × f64 = 256 bytes)
    vmovapd     zmm4,  [rdi + 0]
    vmovapd     zmm5,  [rdi + 64]
    vmovapd     zmm6,  [rdi + 128]
    vmovapd     zmm7,  [rdi + 192]

    ; Fused multiply-add accumulate (latency-hiding via 4 accumulators)
    vaddpd      zmm0,  zmm0,  zmm4
    vaddpd      zmm1,  zmm1,  zmm5
    vaddpd      zmm2,  zmm2,  zmm6
    vaddpd      zmm3,  zmm3,  zmm7

    ; Min / Max tracking via mask-blend
    vminpd      zmm17, zmm17, zmm4
    vminpd      zmm18, zmm18, zmm5
    vminpd      zmm19, zmm19, zmm6
    vmaxpd      zmm21, zmm21, zmm4
    vmaxpd      zmm22, zmm22, zmm5
    vmaxpd      zmm23, zmm23, zmm6

    add         rdi,   256
    dec         r10
    jnz         .loop

.tail:
    ; Scalar tail for remainder elements
    test        rsi,  rsi
    jz          .reduce

    vxorpd      xmm8,  xmm8,  xmm8      ; tail sum
    vmovsd      xmm9,  [rip + .pos_inf]  ; tail min
    vmovsd      xmm10, [rip + .neg_inf]  ; tail max

.tail_loop:
    vmovsd      xmm11, [rdi]
    vaddsd      xmm8,  xmm8,  xmm11
    vminsd      xmm9,  xmm9,  xmm11
    vmaxsd      xmm10, xmm10, xmm11
    add         rdi,   8
    dec         rsi
    jnz         .tail_loop

.reduce:
    ; Horizontal sum: collapse 4 zmm accumulators
    vaddpd      zmm0,  zmm0,  zmm1
    vaddpd      zmm2,  zmm2,  zmm3
    vaddpd      zmm0,  zmm0,  zmm2

    ; Reduce zmm0 to scalar via butterfly
    vextractf64x4 ymm1, zmm0, 1
    vaddpd      ymm0,  ymm0,  ymm1
    vextractf128  xmm1, ymm0, 1
    vaddpd      xmm0,  xmm0,  xmm1
    vhaddpd     xmm0,  xmm0,  xmm0

    ; Add scalar tail
    vaddsd      xmm0,  xmm0,  xmm8
    vmovsd      [rdx], xmm0

    ; Reduce min accumulators
    vminpd      zmm17, zmm17, zmm18
    vminpd      zmm17, zmm17, zmm19
    vextractf64x4 ymm1, zmm17, 1
    vminpd      ymm17, ymm17, ymm1
    vextractf128  xmm1, ymm17, 1
    vperm2f128  xmm2,  xmm1,  xmm1, 1   ; fold pairs
    vminpd      xmm17, xmm17, xmm1
    vminsd      xmm17, xmm17, xmm9
    vmovsd      [rcx], xmm17

    ; Reduce max accumulators
    vmaxpd      zmm21, zmm21, zmm22
    vmaxpd      zmm21, zmm21, zmm23
    vextractf64x4 ymm1, zmm21, 1
    vmaxpd      ymm21, ymm21, ymm1
    vextractf128  xmm1, ymm21, 1
    vmaxpd      xmm21, xmm21, xmm1
    vunpckhpd   xmm2,  xmm21, xmm21
    vmaxsd      xmm21, xmm21, xmm2
    vmaxsd      xmm21, xmm21, xmm10
    vmovsd      [r8],  xmm21

    vzeroupper
    mov         rsp,   rbp
    pop         rbp
    ret

.pos_inf: dq 0x7FF0000000000000
.neg_inf: dq 0xFFF0000000000000
