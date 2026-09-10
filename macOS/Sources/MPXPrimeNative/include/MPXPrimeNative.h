#ifndef MPX_PRIME_NATIVE_H
#define MPX_PRIME_NATIVE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Enable FTZ (Flush-to-Zero) + DAZ (Denormals-Are-Zero) on the
/// current thread's floating-point control register. Standard real-
/// time-DSP defense against denormal accumulation in long-running
/// envelope followers, exponential integrators, and biquad filter
/// states.
///
/// Why this matters on Intel: x86 default FP behaviour processes
/// denormal (subnormal) floats at 10-100x slower than normal-range
/// math. Long-running audio chains slowly drift toward zero in their
/// envelope state (AGC release, multiband compressor release, BS.412
/// rolling window, biquad allpass states) and eventually cross into
/// denormal territory. Once the audio thread hits a denormal-heavy
/// region, it can no longer meet the real-time deadline, CoreAudio
/// drops samples, and the output goes to garbage that a receiver
/// hears as broadband noise / no-signal hiss. Setting FTZ + DAZ
/// makes denormal arithmetic flush to zero in hardware, eliminating
/// the slow path. Standard practice on every x86 audio DSP project.
///
/// On Apple Silicon (ARM64) NEON handles denormals at full speed so
/// the issue is invisible there, but setting FPCR's FZ bit is still
/// defensive and matches the behaviour across architectures.
///
/// MXCSR (x86) and FPCR (ARM) are PER-THREAD state. CoreAudio runs
/// the render callback on a high-priority audio thread. Call this
/// once at the top of every render-callback entry -- the cost is
/// ~1 ns and ensures the flags are set even if CoreAudio swaps in
/// a new audio thread on device events.
void mpx_enable_flush_to_zero(void);

/// SIMD kernels behind the Linux Accelerate shim (MPXPrimeSIMD.c). On
/// Linux/x86_64 each is compiled twice -- an AVX2 clone and the SSE2
/// baseline -- and the dynamic linker picks one per CPU at load time
/// (clang `target_clones` + glibc ifunc), so ONE binary serves the Celeron
/// rig and an AVX2 machine. Numerics are bit-identical across the clones
/// and to the shim's portable Swift references: same 8-lane vectors, same
/// accumulation and reduction order, and FMA contraction is disabled --
/// which is what keeps the Linux strict baseline valid on every CPU.
/// Unused on macOS (the DSP links real Accelerate there).

/// sum(a[i] * b[i]) for i < n, unit stride.
float mpx_simd_dot(const float *a, const float *b, int n);

/// y[i] = tanh(x[i]) for i < n (Cephes-style SIMD expf; see the shim).
void mpx_simd_tanh(float *y, const float *x, int n);

/// Which kernel variant this CPU runs: "avx2", "sse2", "neon" or "scalar".
const char *mpx_simd_kernel_variant(void);

/// 1 when the CPU has AVX2 and the dispatch picked the AVX2 variants.
int mpx_simd_has_avx2(void);

#if defined(__x86_64__) && defined(__linux__)
/// The two variants by name, for tests: both must equal the shim's Swift
/// reference bit for bit on the same machine. Call the AVX2 pair only when
/// `mpx_simd_has_avx2()` says so.
float mpx_simd_dot_sse2(const float *a, const float *b, int n);
float mpx_simd_dot_avx2(const float *a, const float *b, int n);
void mpx_simd_tanh_sse2(float *y, const float *x, int n);
void mpx_simd_tanh_avx2(float *y, const float *x, int n);
#endif

#ifdef __cplusplus
}
#endif

#endif
