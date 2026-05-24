#include "MPXPrimeNative.h"

#if defined(__x86_64__)
#include <xmmintrin.h>
#include <pmmintrin.h>
#endif

#include <stdint.h>

void mpx_enable_flush_to_zero(void) {
#if defined(__x86_64__)
    // SSE control: bit 15 of MXCSR = FTZ (Flush-To-Zero), bit 6 = DAZ
    // (Denormals-Are-Zero). _MM_SET_*_MODE macros set them via the
    // platform headers.
    _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
    _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#elif defined(__arm64__) || defined(__aarch64__)
    // ARM64 FPCR bit 24 = FZ (Flush-to-Zero for scalar + NEON). Apple
    // Silicon handles denormals at full speed so this is defensive,
    // not performance-critical, but matches behaviour across arches.
    uint64_t fpcr;
    __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1ULL << 24);
    __asm__ volatile("msr fpcr, %0" : : "r"(fpcr));
#else
    // Other architectures: no-op. Denormal handling is implementation-
    // defined; if MPX Prime ever ports beyond x86_64 / arm64 this
    // function needs a per-arch implementation.
#endif
}
