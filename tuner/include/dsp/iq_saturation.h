#ifndef FM_TUNER_DSP_IQ_SATURATION_H
#define FM_TUNER_DSP_IQ_SATURATION_H

#include <cstdint>

namespace fm_tuner::dsp {

// RTL-SDR delivers 8-bit unsigned I/Q. The literal min/max (0/255) are the
// only values that are *certainly* clipped, but the second-from-edge codes
// behave indistinguishably under any post-ADC rounding/dithering, so we treat
// them as saturated for both clip-ratio metering and demod-side overload
// detection. Keep this in one place so the meter and the demod can't drift
// to different thresholds.
inline constexpr std::uint8_t kRtlSdrIqLowSaturated = 1;
inline constexpr std::uint8_t kRtlSdrIqHighSaturated = 254;

inline constexpr bool isRtlSdrIqByteSaturated(std::uint8_t b) {
  return b <= kRtlSdrIqLowSaturated || b >= kRtlSdrIqHighSaturated;
}

// The same threshold for a path that has already normalized to float (the
// complex/wide capture path, and the SDRplay backend). The packed path maps a
// byte to (b - 127) / 127.5, so the innermost code this predicate treats as
// saturated -- byte 1 -- normalizes to -0.98824; anything of that magnitude or
// beyond is the same overload the byte test reports. The complex path used a
// hard-coded 0.995f, which is ASYMMETRIC against the byte mapping (it caught
// bytes 0, 254 and 255 but not byte 1), so the two paths disagreed about
// whether the front end was clipping.
inline constexpr float kIqSaturatedMagnitude = 0.98824f;

inline constexpr bool isIqSampleSaturated(float i, float q) {
  return (i <= -kIqSaturatedMagnitude) || (i >= kIqSaturatedMagnitude)
      || (q <= -kIqSaturatedMagnitude) || (q >= kIqSaturatedMagnitude);
}

} // namespace fm_tuner::dsp

#endif
