// SIMD kernels for the Linux Accelerate shim, with per-CPU dispatch.
//
// The shim's hot paths (FIR dot products behind vDSP_dotpr / vDSP_conv, and
// vvtanhf) used to be portable Swift SIMD8 -- which the compiler can only
// lower to the build's baseline ISA, SSE2, because AVX cannot be assumed on
// every x86 box. Swift has no per-function target attributes, C does: each kernel is
// compiled as an AVX2 variant plus the SSE2 baseline, and a glibc ifunc
// picks one at load time from CPUID. One binary, both machines.
//
// BIT-IDENTITY IS THE CONTRACT. The Linux strict baseline
// (verifier_baselines/default-linux-x86_64.json) was captured with the Swift
// SSE2 numerics; these kernels reproduce them exactly on every clone:
//   - the same 8-lane vectors, the same four accumulators unrolled by 32,
//     the same (acc0 + acc1) + (acc2 + acc3) then lane 0..7 reduction, the
//     same scalar tail;
//   - FMA contraction OFF (the pragma below): a fused multiply-add rounds
//     once where the reference rounds twice, and AVX2 machines have FMA;
//   - the tanh path is the same Cephes expf, operation for operation.
// AccelerateShimTests pins C against the Swift references with exact
// equality, and --verify --baseline-strict on the AVX2 box is the proof on
// the real chain. If FMA is ever wanted, it is a new baseline per ISA, not a
// flag flip here.
#include "MPXPrimeNative.h"
#include <string.h>

#pragma clang fp contract(off)

typedef float    v8f __attribute__((vector_size(32)));
typedef unsigned v8u __attribute__((vector_size(32)));
typedef int      v8i __attribute__((vector_size(32)));

// Per-CPU dispatch (Linux/x86_64): both variants exist under their own
// names so tests can hold the SSE2 and the AVX2 code to the reference on the
// SAME machine -- clang's target_clones would hide them behind the ifunc and
// the SSE2 variant would then only ever run on a non-AVX box, never in CI.
// The public symbol is an ifunc whose resolver picks once at load time.
#if defined(__x86_64__) && defined(__linux__) && defined(__clang__)
#define MPX_X86_DISPATCH 1
#define MPX_INLINE static inline __attribute__((always_inline))
#else
#define MPX_X86_DISPATCH 0
#define MPX_INLINE static inline
#endif

// Helpers pass vectors by POINTER, never by value: a function that takes or
// returns a 256-bit vector is an ABI error in the SSE2 clone ("AVX vector
// return ... without 'avx' enabled changes the ABI"). Inlined, the pointer
// costs nothing.
MPX_INLINE void load8(v8f *v, const float *p) {
    memcpy(v, p, sizeof *v);   // unaligned load; lowers to (v)movups
}

MPX_INLINE void store8(float *p, const v8f *v) {
    memcpy(p, v, sizeof *v);
}

MPX_INLINE float dot_impl(const float *a, const float *b, int n) {
    v8f acc0 = {0}, acc1 = {0}, acc2 = {0}, acc3 = {0};
    v8f x0, y0, x1, y1, x2, y2, x3, y3;
    int i = 0;
    for (; i + 32 <= n; i += 32) {
        load8(&x0, a + i);      load8(&y0, b + i);
        load8(&x1, a + i + 8);  load8(&y1, b + i + 8);
        load8(&x2, a + i + 16); load8(&y2, b + i + 16);
        load8(&x3, a + i + 24); load8(&y3, b + i + 24);
        acc0 += x0 * y0;
        acc1 += x1 * y1;
        acc2 += x2 * y2;
        acc3 += x3 * y3;
    }
    for (; i + 8 <= n; i += 8) {
        load8(&x0, a + i); load8(&y0, b + i);
        acc0 += x0 * y0;
    }
    v8f s = (acc0 + acc1) + (acc2 + acc3);
    // Swift's SIMD8.sum(): sequential over the lanes from zero.
    float acc = 0.0f;
    for (int l = 0; l < 8; l++) acc += s[l];
    for (; i < n; i++) acc += a[i] * b[i];
    return acc;
}

// e^x for x in [0, ~88]: Cody-Waite range reduction + degree-5 minimax
// polynomial, 2^k assembled into the exponent field. Constants and operation
// order match exp8 in AccelerateShim.swift.
MPX_INLINE void exp8(v8f *out, const v8f *xp) {
    v8f x = *xp;
    const v8f log2e = {1.442695040888963f, 1.442695040888963f, 1.442695040888963f, 1.442695040888963f,
                       1.442695040888963f, 1.442695040888963f, 1.442695040888963f, 1.442695040888963f};
    const v8f magic = {12582912.0f, 12582912.0f, 12582912.0f, 12582912.0f,
                       12582912.0f, 12582912.0f, 12582912.0f, 12582912.0f};   // 1.5 * 2^23
    v8f k = (x * log2e + magic) - magic;
    const v8f ln2Hi = {0.693359375f, 0.693359375f, 0.693359375f, 0.693359375f,
                       0.693359375f, 0.693359375f, 0.693359375f, 0.693359375f};
    const v8f ln2Lo = {-2.12194440e-4f, -2.12194440e-4f, -2.12194440e-4f, -2.12194440e-4f,
                       -2.12194440e-4f, -2.12194440e-4f, -2.12194440e-4f, -2.12194440e-4f};
    v8f f = (x - k * ln2Hi) - k * ln2Lo;
#define C8(c) {c, c, c, c, c, c, c, c}
    const v8f c0 = C8(1.9875691500e-4f), c1 = C8(1.3981999507e-3f), c2 = C8(8.3334519073e-3f),
              c3 = C8(4.1665795894e-2f), c4 = C8(1.6666665459e-1f), c5 = C8(5.0000001201e-1f),
              one = C8(1.0f);
#undef C8
    v8f p = c0;
    p = p * f + c1;
    p = p * f + c2;
    p = p * f + c3;
    p = p * f + c4;
    p = p * f + c5;
    p = ((p * f) * f + f) + one;
    v8i ki = __builtin_convertvector(k, v8i);          // truncation, as SIMD8<Int32>(k)
    const v8i bias = {127, 127, 127, 127, 127, 127, 127, 127};
    v8f twoK = (v8f)((ki + bias) << 23);
    *out = p * twoK;
}

MPX_INLINE void tanh8(v8f *out, const v8f *vp) {
    v8u bits = (v8u)*vp;
    const v8u signMask = {0x80000000u, 0x80000000u, 0x80000000u, 0x80000000u,
                          0x80000000u, 0x80000000u, 0x80000000u, 0x80000000u};
    const v8u absMask = {0x7FFFFFFFu, 0x7FFFFFFFu, 0x7FFFFFFFu, 0x7FFFFFFFu,
                         0x7FFFFFFFu, 0x7FFFFFFFu, 0x7FFFFFFFu, 0x7FFFFFFFu};
    v8u signBits = bits & signMask;
    v8f ax = (v8f)(bits & absMask);
    // Clamp |x| at 9.1 (Float tanh saturates to 1.0 by ~9.01; keeps exp in range).
    const v8f clampAt = {9.1f, 9.1f, 9.1f, 9.1f, 9.1f, 9.1f, 9.1f, 9.1f};
    v8i over = ax > clampAt;                            // lanes of all-ones where true
    ax = (v8f)(((v8i)ax & ~over) | ((v8i)clampAt & over));
    v8f twice = ax + ax;
    v8f e;
    exp8(&e, &twice);
    const v8f one = {1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f};
    v8f t = (e - one) / (e + one);
    *out = (v8f)(((v8u)t) | signBits);
}

MPX_INLINE void tanh_impl(float *y, const float *x, int n) {
    v8f in, res;
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        load8(&in, x + i);
        tanh8(&res, &in);
        store8(y + i, &res);
    }
    if (i < n) {
        // Remainder through a zero-padded lane so every element takes the
        // identical code path regardless of batch length (as the shim did).
        float pad[8] = {0};
        for (int j = i; j < n; j++) pad[j - i] = x[j];
        float out[8];
        load8(&in, pad);
        tanh8(&res, &in);
        store8(out, &res);
        for (int j = i; j < n; j++) y[j] = out[j - i];
    }
}

#if MPX_X86_DISPATCH
float mpx_simd_dot_sse2(const float *a, const float *b, int n) { return dot_impl(a, b, n); }
__attribute__((target("avx2")))
float mpx_simd_dot_avx2(const float *a, const float *b, int n) { return dot_impl(a, b, n); }
void mpx_simd_tanh_sse2(float *y, const float *x, int n) { tanh_impl(y, x, n); }
__attribute__((target("avx2")))
void mpx_simd_tanh_avx2(float *y, const float *x, int n) { tanh_impl(y, x, n); }

int mpx_simd_has_avx2(void) {
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") ? 1 : 0;
}

static void *resolve_dot(void) {
    return mpx_simd_has_avx2() ? (void *)mpx_simd_dot_avx2 : (void *)mpx_simd_dot_sse2;
}
static void *resolve_tanh(void) {
    return mpx_simd_has_avx2() ? (void *)mpx_simd_tanh_avx2 : (void *)mpx_simd_tanh_sse2;
}
float mpx_simd_dot(const float *a, const float *b, int n) __attribute__((ifunc("resolve_dot")));
void mpx_simd_tanh(float *y, const float *x, int n) __attribute__((ifunc("resolve_tanh")));
#else
float mpx_simd_dot(const float *a, const float *b, int n) { return dot_impl(a, b, n); }
void mpx_simd_tanh(float *y, const float *x, int n) { tanh_impl(y, x, n); }
int mpx_simd_has_avx2(void) { return 0; }
#endif

const char *mpx_simd_kernel_variant(void) {
#if MPX_X86_DISPATCH
    return mpx_simd_has_avx2() ? "avx2" : "sse2";
#elif defined(__x86_64__)
    return "sse2";
#elif defined(__aarch64__) || defined(__arm64__)
    return "neon";
#else
    return "scalar";
#endif
}
