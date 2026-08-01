// In-process SDR -> FM demod -> MPX composite library (C ABI).
// See capi-include/mpx_tuner_capi.h. Wraps a device backend (RTL-SDR or, when
// the SDRplay SDK is present, an SDRplay RSP), an FMDemod, and a capture thread.
// Live control setters enqueue commands applied on the capture thread (so all
// device calls stay on one thread). Backend is auto-selected: SDRplay if an RSP
// is attached, else RTL-SDR.

#include "mpx_tuner_capi.h"

#include "dsp/liquid_primitives.h"
#include "fm_demod.h"
#include "rtl_sdr_device.h"
#include "sdrplay_device.h"

#if defined(FM_TUNER_HAS_RTLSDR)
#include <rtl-sdr.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace {
constexpr int kRtlDemodRate = 256000;   // rate the RTL FM demod chain runs at
constexpr int kSDRplayDemodRate = 250000;  // ditto for the SDRplay backend

// RF spectrum: FFT size and how often a frame is produced. The capture thread
// is not the audio render thread (it already allocates), but there is no point
// transforming faster than a 25 Hz display consumes -- one frame per 50 ms is
// plenty and keeps the cost invisible next to the demod.
constexpr int kSpectrumFFT = 1024;
constexpr double kSpectrumFramesPerSecond = 20.0;

enum Backend { BackendRTL, BackendSDRplay };

enum CmdType { CmdFreq, CmdGain, CmdGainAuto, CmdBandwidth, CmdBias, CmdPPM, CmdRtlAgc, CmdAntenna, CmdLna };
struct Cmd {
  CmdType type;
  double value;
};
}  // namespace

struct MpxTuner {
  Backend backend = BackendRTL;
  RTLSDRDevice rtl;
  SDRplayDevice sdrplay;
  std::unique_ptr<FMDemod> demod;
  fm_tuner::dsp::liquid::Resampler resampler;  // demodRate -> mpx_rate
  // Two rates, deliberately decoupled. `captureRate` is what the device
  // delivers and it sets ONLY the RF spectrum's span; `demodRate` is what the
  // FM demod chain runs at and stays at the historical 250/256 kHz whatever
  // the capture rate is, so widening the span cannot perturb the MPX
  // measurements. `iqDecim` bridges them.
  int captureRate = kRtlDemodRate;
  int inputRate = kRtlDemodRate;  // == demod rate (name kept: used widely below)
  fm_tuner::dsp::liquid::ComplexDecimator iqDecim;
  std::vector<std::complex<float>> iqWide;      // captureRate IQ for the FFT
  std::vector<std::complex<float>> iqNarrow;    // decimated to demod rate

  // RF spectrum (complex FFT of the wide IQ), published as a snapshot.
  fftplan specPlan = nullptr;
  std::vector<std::complex<float>> specIn;
  std::vector<std::complex<float>> specOut;
  std::vector<float> specWindow;
  std::vector<float> specAccum;    // smoothed, fftshifted dB bins
  std::vector<float> specPublish;  // guarded copy handed to the reader
  int specFill = 0;
  int specSkip = 0;               // samples still to drop before the next frame
  bool specPrimed = false;
  std::mutex specMutex;

  MpxTunerSampleCallback cb = nullptr;
  void *ctx = nullptr;
  float mpxGain = 1.0f;
  uint32_t mpxRate;

  std::thread thread;
  std::atomic<bool> running{false};
  std::atomic<bool> alive{false};
  std::atomic<double> signalDbfs{-120.0};

  std::mutex cmdMutex;
  std::vector<Cmd> cmds;

  explicit MpxTuner(uint32_t devIndex, uint32_t rate) : rtl(devIndex), mpxRate(rate) {}

  ~MpxTuner() {
    // The capture thread is already joined by both close paths before the
    // object is deleted, so nothing can be mid-transform here.
    if (specPlan) { fft_destroy_plan(specPlan); specPlan = nullptr; }
  }

  void enqueue(const Cmd &c) {
    std::lock_guard<std::mutex> lk(cmdMutex);
    cmds.push_back(c);
  }

  void apply(const Cmd &c) {
    const bool sp = (backend == BackendSDRplay);
    switch (c.type) {
      case CmdFreq:
        if (c.value > 0) {
          const uint32_t hz = static_cast<uint32_t>(c.value * 1000.0);
          if (sp) sdrplay.setFrequency(hz); else rtl.setFrequency(hz);
        }
        break;
      case CmdGain:
        if (sp) {
          sdrplay.setGain(c.value);
        } else {
          rtl.setGainMode(true);
          rtl.setGain(static_cast<uint32_t>(std::lround(c.value * 10.0)));
        }
        break;
      case CmdGainAuto:
        if (sp) sdrplay.setGainAuto(c.value != 0.0);
        else rtl.setGainMode(c.value == 0.0);  // auto => manual mode false
        break;
      case CmdBandwidth: {
        const int hz = static_cast<int>(std::lround(c.value * 1000.0));
        if (demod) demod->setBandwidthHz(hz);   // software channel FIR (both backends)
        if (sp) sdrplay.setBandwidthHz(hz);
        else rtl.setTunerBandwidth(static_cast<uint32_t>(hz < 0 ? 0 : hz));
        break;
      }
      case CmdBias:
        if (sp) sdrplay.setBiasTee(c.value != 0.0); else rtl.setBiasTee(c.value != 0.0);
        break;
      case CmdPPM:     if (!sp) rtl.setFrequencyCorrection(static_cast<int>(std::lround(c.value))); break;
      case CmdRtlAgc:  if (!sp) rtl.setAGC(c.value != 0.0); break;             // RTL only
      case CmdAntenna: if (sp) sdrplay.setAntenna(static_cast<int>(c.value)); break;
      case CmdLna:     if (sp) sdrplay.setLnaState(static_cast<int>(c.value)); break;
    }
  }

  void drain() {
    std::vector<Cmd> local;
    {
      std::lock_guard<std::mutex> lk(cmdMutex);
      local.swap(cmds);
    }
    // Coalesce a burst: keep only the last command of each type (every command
    // is an idempotent "set to value", so earlier duplicates are dead). A
    // scroll/drag on the frequency or gain field thus issues ONE SDRplay
    // Update per drain instead of dozens -- the async SDRplay update path drops
    // or stalls retunes when hit with a rapid burst (RTL's synchronous USB
    // control transfer does not). Last-occurrence order is preserved so the
    // GainAuto/Gain disable-AGC interaction still applies in submitted order.
    std::vector<Cmd> coalesced;
    for (auto it = local.rbegin(); it != local.rend(); ++it) {
      bool seen = false;
      for (const auto &k : coalesced) if (k.type == it->type) { seen = true; break; }
      if (!seen) coalesced.push_back(*it);
    }
    for (auto it = coalesced.rbegin(); it != coalesced.rend(); ++it) apply(*it);
  }

  /// Build the FFT plan, window and buffers for the RF spectrum. Called once
  /// at open, after the capture rate is known.
  void initSpectrum() {
    specIn.assign(kSpectrumFFT, std::complex<float>(0.0f, 0.0f));
    specOut.assign(kSpectrumFFT, std::complex<float>(0.0f, 0.0f));
    specAccum.assign(kSpectrumFFT, -140.0f);
    specPublish.assign(kSpectrumFFT, -140.0f);
    specWindow.assign(kSpectrumFFT, 0.0f);
    for (int i = 0; i < kSpectrumFFT; i++) {
      // Hann: adequate sidelobes for a display, and cheap.
      specWindow[i] = 0.5f - 0.5f * std::cos(2.0f * static_cast<float>(M_PI) *
                                             static_cast<float>(i) /
                                             static_cast<float>(kSpectrumFFT - 1));
    }
    specPlan = fft_create_plan(kSpectrumFFT,
                               reinterpret_cast<liquid_float_complex *>(specIn.data()),
                               reinterpret_cast<liquid_float_complex *>(specOut.data()),
                               LIQUID_FFT_FORWARD, 0);
    specFill = 0;
    specSkip = 0;
    specPrimed = false;
  }

  /// Feed wide IQ to the spectrum. Fills one FFT frame, transforms it, then
  /// skips ahead so frames arrive at ~kSpectrumFramesPerSecond rather than as
  /// fast as the buffer refills.
  void feedSpectrum(const std::complex<float> *iq, size_t n) {
    if (!specPlan) return;
    size_t i = 0;
    while (i < n) {
      if (specSkip > 0) {
        const size_t drop = std::min(static_cast<size_t>(specSkip), n - i);
        specSkip -= static_cast<int>(drop);
        i += drop;
        continue;
      }
      const size_t take = std::min(static_cast<size_t>(kSpectrumFFT - specFill), n - i);
      for (size_t k = 0; k < take; k++) specIn[specFill + k] = iq[i + k];
      specFill += static_cast<int>(take);
      i += take;
      if (specFill < kSpectrumFFT) break;

      for (int k = 0; k < kSpectrumFFT; k++) specIn[k] *= specWindow[k];
      fft_execute(specPlan);
      // Magnitude in dB, fftshifted so bin 0 is the low edge of the span and
      // the centre bin is the tuned frequency.
      const float norm = 1.0f / static_cast<float>(kSpectrumFFT);
      const int half = kSpectrumFFT / 2;
      for (int k = 0; k < kSpectrumFFT; k++) {
        const int src = (k < half) ? (k + half) : (k - half);
        const std::complex<float> v = specOut[src] * norm;
        const float mag2 = v.real() * v.real() + v.imag() * v.imag();
        const float db = 10.0f * std::log10(mag2 + 1e-20f);
        specAccum[k] = specPrimed ? (specAccum[k] + 0.45f * (db - specAccum[k])) : db;
      }
      specPrimed = true;
      {
        std::lock_guard<std::mutex> lk(specMutex);
        specPublish = specAccum;
      }
      specFill = 0;
      specSkip = std::max(0, static_cast<int>(static_cast<double>(captureRate) /
                                              kSpectrumFramesPerSecond) - kSpectrumFFT);
    }
  }

  void loop() {
    const size_t kBlock = 8192;
    std::vector<uint8_t> iq(kBlock * 2);
    std::vector<std::complex<float>> iqc(kBlock);
    std::vector<float> mpx(kBlock);
    std::vector<float> out;
    out.reserve(kBlock);
    std::array<float, fm_tuner::dsp::liquid::Resampler::kMaxOutput> tmp{};
    iqWide.assign(kBlock, std::complex<float>(0.0f, 0.0f));
    iqNarrow.assign(kBlock, std::complex<float>(0.0f, 0.0f));

    while (running.load(std::memory_order_relaxed)) {
      drain();
      const bool sp = (backend == BackendSDRplay);
      if ((sp && sdrplay.failed()) || (!sp && rtl.failed())) {
        alive.store(false, std::memory_order_relaxed);
        break;
      }
      size_t n = 0;       // demod-rate sample count
      if (sp) {
        const size_t got = sdrplay.readIQ(iqWide.data(), kBlock);
        if (got == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        feedSpectrum(iqWide.data(), got);
        n = iqDecim.executeComplexIn(iqWide.data(), got, iqNarrow.data(), iqNarrow.size());
        if (n == 0) continue;
        demod->processSplitComplex(iqNarrow.data(), mpx.data(), nullptr, n);
      } else {
        const size_t got = rtl.readIQ(iq.data(), kBlock);
        if (got == 0) { std::this_thread::sleep_for(std::chrono::milliseconds(2)); continue; }
        if (iqDecim.factor() == 1) {
          // Not capturing wide: keep the ORIGINAL packed-byte demod path
          // byte-for-byte. It normalizes through its own LUT and detects
          // saturation on the raw bytes, neither of which the complex path
          // reproduces exactly -- and this is the default configuration, so it
          // must stay untouched. The spectrum still gets its own unpack.
          for (size_t k = 0; k < got; k++) {
            iqWide[k] = std::complex<float>(
                (static_cast<float>(iq[k * 2]) - 127.5f) / 127.5f,
                (static_cast<float>(iq[k * 2 + 1]) - 127.5f) / 127.5f);
          }
          feedSpectrum(iqWide.data(), got);
          n = got;
          demod->processSplit(iq.data(), mpx.data(), nullptr, n);
        } else {
          // Wide capture: unpack once and reuse for both the spectrum and the
          // decimation (the packed-uint8 decimator would unpack a second time).
          for (size_t k = 0; k < got; k++) {
            iqWide[k] = std::complex<float>(
                (static_cast<float>(iq[k * 2]) - 127.5f) / 127.5f,
                (static_cast<float>(iq[k * 2 + 1]) - 127.5f) / 127.5f);
          }
          feedSpectrum(iqWide.data(), got);
          n = iqDecim.executeComplexIn(iqWide.data(), got, iqNarrow.data(), iqNarrow.size());
          if (n == 0) continue;
          demod->processSplitComplex(iqNarrow.data(), mpx.data(), nullptr, n);
        }
      }
      signalDbfs.store(demod->getFilteredChannelPowerDbfs(), std::memory_order_relaxed);
      out.clear();
      for (size_t i = 0; i < n; i++) {
        const std::uint32_t produced = resampler.execute(mpx[i] * mpxGain, tmp);
        for (std::uint32_t p = 0; p < produced; p++) out.push_back(tmp[p]);
      }
      if (!out.empty() && cb) cb(out.data(), out.size(), ctx);
    }
    alive.store(false, std::memory_order_relaxed);
  }
};

extern "C" {

int mpxtuner_device_count(void) {
  int n = 0;
#if defined(FM_TUNER_HAS_RTLSDR)
  n += static_cast<int>(rtlsdr_get_device_count());
#endif
  n += SDRplayDevice::deviceCount();
  return n;
}

int mpxtuner_sdrplay_present(void) {
  return SDRplayDevice::deviceCount() > 0 ? 1 : 0;
}

int mpxtuner_list_devices(MpxTunerDeviceInfo *out, int max) {
  if (!out || max <= 0) return 0;
  int n = 0;
  SDRplayDevice::Info rsp[8];
  const int nr = SDRplayDevice::listDevices(rsp, 8);
  for (int i = 0; i < nr && n < max; ++i, ++n) {
    out[n].backend = 2;
    out[n].index = static_cast<uint32_t>(i);
    std::snprintf(out[n].name, sizeof(out[n].name), "%s", rsp[i].name);
    std::snprintf(out[n].serial, sizeof(out[n].serial), "%s", rsp[i].serial);
  }
#if defined(FM_TUNER_HAS_RTLSDR)
  const uint32_t nrtl = rtlsdr_get_device_count();
  for (uint32_t i = 0; i < nrtl && n < max; ++i, ++n) {
    char manufact[256] = {0}, product[256] = {0}, serial[256] = {0};
    rtlsdr_get_device_usb_strings(i, manufact, product, serial);
    const char *name = product[0] ? product : rtlsdr_get_device_name(i);
    out[n].backend = 1;
    out[n].index = i;
    std::snprintf(out[n].name, sizeof(out[n].name), "%s",
                  (name && name[0]) ? name : "RTL-SDR");
    std::snprintf(out[n].serial, sizeof(out[n].serial), "%s", serial);
  }
#endif
  return n;
}

MpxTuner *mpxtuner_open(const MpxTunerConfig *cfg, MpxTunerSampleCallback cb,
                        void *ctx, char *err, size_t err_len) {
  auto setErr = [&](const char *m) {
    if (err && err_len) { std::strncpy(err, m, err_len - 1); err[err_len - 1] = '\0'; }
  };
  if (!cfg) { setErr("null config"); return nullptr; }
  const uint32_t rate = cfg->mpx_rate ? cfg->mpx_rate : 192000;

  // Backend: explicit from the config, or auto (SDRplay preferred).
  int backend = cfg->backend;
  if (backend != 1 && backend != 2) {
    backend = SDRplayDevice::deviceCount() > 0 ? 2 : 1;
  }
  const bool useSDRplay = (backend == 2);

  // RTL device index: explicit, or resolved from the requested serial.
  uint32_t rtlIndex = cfg->device_index;
#if defined(FM_TUNER_HAS_RTLSDR)
  if (!useSDRplay && cfg->device_serial[0] != '\0') {
    const uint32_t nrtl = rtlsdr_get_device_count();
    bool found = false;
    for (uint32_t i = 0; i < nrtl; ++i) {
      char manufact[256] = {0}, product[256] = {0}, serial[256] = {0};
      rtlsdr_get_device_usb_strings(i, manufact, product, serial);
      if (std::strncmp(serial, cfg->device_serial, sizeof(serial)) == 0) {
        rtlIndex = i;
        found = true;
        break;
      }
    }
    if (!found) { setErr("requested RTL-SDR serial not attached"); return nullptr; }
  }
#endif

  MpxTuner *t = new (std::nothrow) MpxTuner(rtlIndex, rate);
  if (!t) { setErr("out of memory"); return nullptr; }
  t->cb = cb;
  t->ctx = ctx;

  if (useSDRplay) {
    t->backend = BackendSDRplay;
    const char *serial = cfg->device_serial[0] ? cfg->device_serial : nullptr;
    if (!t->sdrplay.connect(cfg->freq_khz * 1000, serial,
                            static_cast<int>(cfg->iq_rate_khz) * 1000)) {
      setErr(serial ? "requested SDRplay serial not attached (or open failed)"
                    : "SDRplay device open failed");
      delete t; return nullptr;
    }
    t->captureRate = t->sdrplay.inputRate();
    t->inputRate = kSDRplayDemodRate;
  } else {
    t->backend = BackendRTL;
    if (!t->rtl.connect()) { setErr("no SDR device found"); delete t; return nullptr; }
    t->inputRate = kRtlDemodRate;
    // Capture wider than the demod needs only to widen the RF spectrum; must
    // be an integer multiple of the demod rate so one decimator bridges them.
    t->captureRate = kRtlDemodRate;
    if (cfg->iq_rate_khz > 0) {
      const int mult = std::max(1, static_cast<int>(std::lround(
          static_cast<double>(cfg->iq_rate_khz) * 1000.0 / kRtlDemodRate)));
      t->captureRate = kRtlDemodRate * mult;
    }
    if (!t->rtl.setSampleRate(static_cast<uint32_t>(t->captureRate))) {
      // Dongle refused the wide rate -- fall back rather than fail the open.
      t->captureRate = kRtlDemodRate;
      t->rtl.setSampleRate(kRtlDemodRate);
    }
    t->rtl.setFrequency(cfg->freq_khz * 1000);
    if (cfg->ppm != 0) t->rtl.setFrequencyCorrection(cfg->ppm);
    if (cfg->auto_gain) {
      t->rtl.setGainMode(false);
    } else {
      t->rtl.setGainMode(true);
      t->rtl.setGain(static_cast<uint32_t>(std::lround(cfg->gain_db * 10.0)));
    }
    t->rtl.setAGC(cfg->rtl_agc != 0);
    t->rtl.setBiasTee(cfg->bias_tee != 0);
  }

  // The demod ALWAYS runs at inputRate (250/256 kHz). When the device is
  // capturing wider, a polyphase decimator brings the IQ down first, so the
  // MPX measurements see the same rate and the same channel filtering they
  // always have -- widening the spectrum span cannot move them.
  if (t->captureRate < t->inputRate) t->captureRate = t->inputRate;
  const int decim = std::max(1, t->captureRate / t->inputRate);
  t->captureRate = t->inputRate * decim;
  try {
    t->iqDecim.init(static_cast<std::uint32_t>(decim));
  } catch (...) {
    setErr("failed to build the IQ decimator"); delete t; return nullptr;
  }
  t->demod = std::make_unique<FMDemod>(t->inputRate, static_cast<int>(rate));
  t->resampler.init(static_cast<float>(rate) / static_cast<float>(t->inputRate));
  t->initSpectrum();
  t->mpxGain = static_cast<float>(std::pow(10.0, cfg->mpx_gain_db / 20.0));

  if (cfg->bandwidth_khz > 0) {
    t->demod->setBandwidthHz(cfg->bandwidth_khz * 1000);
    if (useSDRplay) t->sdrplay.setBandwidthHz(cfg->bandwidth_khz * 1000);
    else t->rtl.setTunerBandwidth(static_cast<uint32_t>(cfg->bandwidth_khz * 1000));
  } else if (!useSDRplay) {
    t->rtl.setTunerBandwidth(0);
  }
  if (useSDRplay) {
    t->sdrplay.setLnaState(cfg->lna);   // front-end gain (overload control)
    if (!cfg->auto_gain) t->sdrplay.setGain(cfg->gain_db);  // manual IF gain
    if (cfg->antenna > 0) t->sdrplay.setAntenna(cfg->antenna);
    if (cfg->bias_tee) t->sdrplay.setBiasTee(true);
  }

  t->running.store(true, std::memory_order_relaxed);
  t->alive.store(true, std::memory_order_relaxed);
  t->thread = std::thread([t] { t->loop(); });
  return t;
}

void mpxtuner_close(MpxTuner *t) {
  if (!t) return;
  t->running.store(false, std::memory_order_relaxed);
  if (t->thread.joinable()) t->thread.join();
  if (t->backend == BackendSDRplay) t->sdrplay.disconnect();
  else t->rtl.disconnect();
  delete t;
}

void mpxtuner_close_fast(MpxTuner *t) {
  if (!t) return;
  t->running.store(false, std::memory_order_relaxed);
  if (t->thread.joinable()) t->thread.join();
  if (t->backend == BackendSDRplay) t->sdrplay.disconnect();
  else t->rtl.disconnect(true /*skipDeviceClose*/);
  delete t;
}

int mpxtuner_is_alive(const MpxTuner *t) {
  return (t && t->alive.load(std::memory_order_relaxed)) ? 1 : 0;
}

double mpxtuner_signal_dbfs(const MpxTuner *t) {
  return t ? t->signalDbfs.load(std::memory_order_relaxed) : -120.0;
}

int mpxtuner_rf_spectrum(MpxTuner *t, float *out, int max_bins, double *span_hz) {
  if (!t || !out || max_bins <= 0) return 0;
  if (span_hz) *span_hz = static_cast<double>(t->captureRate);
  std::lock_guard<std::mutex> lk(t->specMutex);
  if (!t->specPrimed || t->specPublish.empty()) return 0;
  const int n = std::min(max_bins, static_cast<int>(t->specPublish.size()));
  for (int i = 0; i < n; i++) out[i] = t->specPublish[i];
  return n;
}

int mpxtuner_capture_rate(const MpxTuner *t) { return t ? t->captureRate : 0; }

double mpxtuner_system_gain_db(const MpxTuner *t) {
  if (!t) return -1000.0;
  if (t->backend == BackendSDRplay) return t->sdrplay.systemGainDb();
  return t->rtl.currentGainDb();
}

int mpxtuner_backend(const MpxTuner *t) {
  return (t && t->backend == BackendSDRplay) ? 1 : 0;
}

int mpxtuner_antenna_count(const MpxTuner *t) {
  if (!t) return 1;
  return (t->backend == BackendSDRplay) ? t->sdrplay.antennaCount() : 1;
}

void mpxtuner_device_name(const MpxTuner *t, char *buf, size_t len) {
  if (!buf || len == 0) return;
  if (!t) { std::strncpy(buf, "SDR", len - 1); buf[len - 1] = '\0'; return; }
  std::string name = (t->backend == BackendSDRplay)
      ? std::string("SDRplay ") + t->sdrplay.modelName()
      : std::string("RTL-SDR ") + t->rtl.tunerName();
  std::strncpy(buf, name.c_str(), len - 1);
  buf[len - 1] = '\0';
}

void mpxtuner_device_serial(const MpxTuner *t, char *buf, size_t len) {
  if (!buf || len == 0) return;
  buf[0] = '\0';
  if (!t) return;
  if (t->backend == BackendSDRplay) {
    std::strncpy(buf, t->sdrplay.serialNumber(), len - 1);
    buf[len - 1] = '\0';
    return;
  }
#if defined(FM_TUNER_HAS_RTLSDR)
  char manufact[256] = {0}, product[256] = {0}, serial[256] = {0};
  if (rtlsdr_get_device_usb_strings(t->rtl.deviceIndex(), manufact, product,
                                    serial) == 0) {
    std::strncpy(buf, serial, len - 1);
    buf[len - 1] = '\0';
  }
#endif
}

void mpxtuner_set_frequency_khz(MpxTuner *t, uint32_t khz) {
  if (t) t->enqueue({CmdFreq, static_cast<double>(khz)});
}
void mpxtuner_set_gain_db(MpxTuner *t, double db) {
  if (t) t->enqueue({CmdGain, db});
}
void mpxtuner_set_gain_auto(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdGainAuto, on ? 1.0 : 0.0});
}
void mpxtuner_set_bandwidth_khz(MpxTuner *t, int khz) {
  if (t) t->enqueue({CmdBandwidth, static_cast<double>(khz)});
}
void mpxtuner_set_bias_tee(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdBias, on ? 1.0 : 0.0});
}
void mpxtuner_set_ppm(MpxTuner *t, int ppm) {
  if (t) t->enqueue({CmdPPM, static_cast<double>(ppm)});
}
void mpxtuner_set_rtl_agc(MpxTuner *t, int on) {
  if (t) t->enqueue({CmdRtlAgc, on ? 1.0 : 0.0});
}
void mpxtuner_set_antenna(MpxTuner *t, int index) {
  if (t) t->enqueue({CmdAntenna, static_cast<double>(index)});
}
void mpxtuner_set_lna(MpxTuner *t, int state) {
  if (t) t->enqueue({CmdLna, static_cast<double>(state)});
}

}  // extern "C"
