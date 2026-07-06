// SPM build shim: compile the canonical SDRplay backend (repo-root tuner/)
// into CMPXTuner. The body is gated by FM_TUNER_HAS_SDRPLAY (set in Package.swift
// only when the SDRplay SDK headers are present), so it builds anywhere.
#include "../../../tuner/src/sdrplay_device.cpp"
