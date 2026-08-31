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
  ///
  /// `captureRateHz` is the IQ rate delivered to `readIQ` -- the RSP always
  /// samples at 2 MHz and the driver decimates, so this must be 2 MHz divided
  /// by an integer (2000/1000/500/250 kHz). It sets the RF spectrum's span;
  /// the demod chain downsamples to its own rate independently. 0 keeps the
  /// historical 250 kHz.
  bool connect(uint32_t freqHz, const char *serial = nullptr,
               int captureRateHz = 0);
  void disconnect();

  bool setFrequency(uint32_t freqHz);
  bool setGain(double gainDb);     // manual gain (disables AGC)
  bool setGainAuto(bool enable);   // AGC on/off
  bool setBandwidthHz(int hz);     // IF channel bandwidth (maps to RSP bw steps)
  bool setAntenna(int index);      // RSP antenna input (model-specific)
  bool setBiasTee(bool enable);    // RSP bias tee (model-specific)
  bool setLnaState(int state);     // front-end LNA gain-reduction step (0 = most gain)

  /// Total system gain in dB as the SDRplay API reports it (`currGain`) --
  /// the same figure SDRuno shows as "System Gain". Tracks AGC and LNA
  /// changes, which is what makes an absolute power reading possible.
  /// Negative sentinel (-1000) until the API has reported one.
  double systemGainDb() const { return m_systemGainDb.load(std::memory_order_relaxed); }
  void setSystemGainDb(double db) { m_systemGainDb.store(db, std::memory_order_relaxed); }

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

  /// IQ samples lost to ring overwrite since connect (the demod thread fell
  /// behind). Non-zero means a gap is baked into every accumulated
  /// measurement downstream.
  uint64_t droppedIQSamples() const {
    return m_droppedIQ.load(std::memory_order_relaxed);
  }
  std::atomic<double> m_systemGainDb{-1000.0};

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
  // IQ samples the ring overwrote before the demod thread read them (the
  // consumer fell behind). Reported through mpxtuner_iq_drops() so the Meter
  // can invalidate its accumulated readings -- a gap poisons peak-hold,
  // BS.412 and the SM.1268 exceedance count. Retune flushes are NOT counted.
  std::atomic<uint64_t> m_droppedIQ{0};

  void *m_handle = nullptr;   // current sdrplay device handle (opaque)
};

#endif  // SDRPLAY_DEVICE_H
