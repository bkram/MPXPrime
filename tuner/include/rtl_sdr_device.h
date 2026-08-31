#ifndef RTL_SDR_DEVICE_H
#define RTL_SDR_DEVICE_H

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class RTLSDRDevice {
public:
  explicit RTLSDRDevice(uint32_t deviceIndex);
  ~RTLSDRDevice();

  bool connect();
  /// `skipDeviceClose` skips the register-writing rtlsdr_close entirely
  /// (process-termination path: a dead USB handle SEGVs in libusb).
  void disconnect(bool skipDeviceClose = false);
  uint32_t deviceIndex() const { return m_deviceIndex; }

  bool setFrequency(uint32_t freqHz);
  bool setSampleRate(uint32_t rate);
  /// Tuner gain actually in effect, in dB (librtlsdr reports tenths). This is
  /// the TUNER stage only -- an RTL dongle has no calibrated total-gain model,
  /// so an absolute power reading from it needs a user calibration offset.
  /// -1000 when unknown / not connected.
  double currentGainDb() const;
  bool setFrequencyCorrection(int ppm);
  bool setGainMode(bool manual);
  bool setGain(uint32_t gainTenthsDb);
  bool setAGC(bool enable);
  bool setTunerBandwidth(uint32_t hz);
  bool setBiasTee(bool enable);
  void setLowLatencyMode(bool enable);
  size_t readIQ(uint8_t *buffer, size_t maxSamples);

  /// True once the async USB read thread has failed (device unplugged / lost).
  bool failed() const { return m_asyncFailed.load(std::memory_order_relaxed); }

  /// Tuner chip name (e.g. "R820T", "E4000"); valid after connect().
  const char *tunerName() const { return m_tunerName.c_str(); }

  /// IQ samples lost since start (ring overwrite + low-latency skip-to-newest).
  /// Non-zero means a gap is baked into every accumulated measurement.
  uint64_t droppedIQSamples() const {
    return m_droppedIQSamples.load(std::memory_order_relaxed);
  }

private:
  static void asyncCallback(unsigned char *buf, uint32_t len, void *ctx);
  void asyncReadLoop();
  size_t availableBytesLocked() const;

  uint32_t m_deviceIndex;
  // USB serial of the opened unit (captured at connect); used to verify the
  // same physical device is still enumerable before a register-writing close.
  char m_serial[64] = {0};
  std::string m_tunerName = "RTL-SDR";
  std::atomic<bool> m_connected;
  void *m_deviceHandle;
  std::vector<int> m_supportedGains;
  std::thread m_asyncThread;
  std::atomic<bool> m_asyncRunning;
  std::atomic<bool> m_asyncFailed;
  std::mutex m_bufferMutex;
  std::condition_variable m_bufferCv;
  std::vector<uint8_t> m_iqRing;
  size_t m_ringReadPos;
  size_t m_ringWritePos;
  bool m_ringFull;
  std::atomic<bool> m_lowLatencyMode;
  std::atomic<uint32_t> m_lowLatencyDropEvents;
  // IQ samples lost since start: ring overwrite (the demod thread fell behind)
  // plus the deliberate low-latency skip-to-newest. Reported through
  // mpxtuner_iq_drops() so the Meter can invalidate accumulated readings --
  // this used to be a function-local static that nothing could read.
  std::atomic<uint64_t> m_droppedIQSamples{0};
  std::atomic<uint32_t> m_lowLatencyDeadlineEvents;
  std::atomic<uint32_t> m_lowLatencyShortReads;
};

#endif
