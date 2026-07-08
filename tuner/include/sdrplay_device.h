#ifndef SDRPLAY_DEVICE_H
#define SDRPLAY_DEVICE_H

#include <atomic>
#include <complex>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

// SDRplay RSP backend. The SDRplay API (sdrplay_api) is a proprietary library
// the user installs separately; we dlopen it at runtime (no build-time link, no
// bundling) so the app stays GPL-clean and falls back to RTL-SDR when SDRplay
// is absent. Streams 16-bit IQ via the API callback into a ring; the demod
// reads it as complex<float> (processSplitComplex).
//
// When the SDRplay SDK headers are not present at build time
// (FM_TUNER_HAS_SDRPLAY undefined), this compiles to a stub that reports
// "unavailable" so the rest of the tuner builds anywhere.
class SDRplayDevice {
public:
  SDRplayDevice();
  ~SDRplayDevice();

  /// True if the SDRplay API library can be loaded (built with the SDK and the
  /// runtime library present).
  static bool apiAvailable();
  /// Number of attached RSP devices (0 if API unavailable).
  static int deviceCount();

  /// Attached-RSP inventory entry (model name + serial).
  struct Info {
    char name[64];
    char serial[64];
  };
  /// Fill `out` with up to `max` attached RSPs. Returns the count written.
  static int listDevices(Info *out, int max);

  /// Connect; when `serial` is non-null/non-empty, select the RSP with that
  /// serial number (fails if absent). Null/empty selects the first device.
  bool connect(uint32_t freqHz, const char *serial = nullptr);
  void disconnect();

  bool setFrequency(uint32_t freqHz);
  bool setGain(double gainDb);     // manual gain (disables AGC)
  bool setGainAuto(bool enable);   // AGC on/off
  bool setBandwidthHz(int hz);     // IF channel bandwidth (maps to RSP bw steps)
  bool setAntenna(int index);      // RSP antenna input (model-specific)
  bool setBiasTee(bool enable);    // RSP bias tee (model-specific)
  bool setLnaState(int state);     // front-end LNA gain-reduction step (0 = most gain)

  /// Number of selectable antenna inputs for the connected model (1 if none).
  int antennaCount() const;
  /// hardware model id (SDRPLAY_*_ID); 0 until connected.
  int hwVer() const { return m_hwVer; }
  /// Human model name ("RSPdx", "RSP1A", ...); "RSP" if unknown.
  const char *modelName() const;
  /// Serial of the connected RSP ("" until connected).
  const char *serialNumber() const;

  /// Effective IQ sample rate delivered to the demod (after RSP decimation).
  int inputRate() const { return m_inputRate; }
  /// True after a fatal streaming error / device loss.
  bool failed() const { return m_failed.load(std::memory_order_relaxed); }

  /// Drain up to maxSamples complex IQ samples. Returns the count copied.
  size_t readIQ(std::complex<float> *out, size_t maxSamples);

  // Called from the SDRplay stream callback (file-local in the .cpp).
  void ingest(const short *xi, const short *xq, unsigned int n, bool reset = false);
  void markFailed() { m_failed.store(true, std::memory_order_relaxed); }

private:
  int m_inputRate = 250000;
  int m_hwVer = 0;
  std::atomic<bool> m_connected{false};
  std::atomic<bool> m_failed{false};

  // IQ ring (complex<float>).
  std::mutex m_mutex;
  std::condition_variable m_cv;
  std::vector<std::complex<float>> m_ring;
  size_t m_readPos = 0, m_writePos = 0;
  bool m_full = false;

  void *m_handle = nullptr;   // current sdrplay device handle (opaque)
};

#endif  // SDRPLAY_DEVICE_H
