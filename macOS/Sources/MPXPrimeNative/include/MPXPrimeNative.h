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
/// once at the top of every render-callback entry — the cost is
/// ~1 ns and ensures the flags are set even if CoreAudio swaps in
/// a new audio thread on device events.
void mpx_enable_flush_to_zero(void);

#ifdef __cplusplus
}
#endif

#endif
